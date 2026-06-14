# Join-reconciliation — what to pay attention to (review focus)

Companion to `2026-06-14-join-reconciliation-walkthrough.md`. These are the four
spots where the logic is subtle enough that "tests pass" is necessary but **not
sufficient**. Each item: the concern, where to look, the exact question, and how
to check it yourself.

**Why this list exists:** F1 took three iterations (Task 7 → `4dc99de` →
`0be47d3`), each green-on-then-current-tests but harboring a deeper bug found only
by the *next* review. The bug class is "a var consumed somewhere the placement
didn't see." All four items below are variants of that.

**How to check anything here, concretely**
```
cabal build exe:wok
cabal run -v0 wok -- <file>.wok --dump-perceus     # see inserted __rc_dup/__rc_drop
cabal run -v0 wok -- <file>.wok --dump-rc-stats    # allocs/frees/stLive/baseline
```
A correct program ends `stLive == baseline` and `allocs == frees`; a leak shows
`stLive > baseline`; a misplacement trips `PrimError "use-after-free"` /
`"double-free"`. Also: `Wok.IR.Perceus.balanceLint cm` should be `[]`.
`::`-cons is pattern-only — use a user-defined boxed data type to build list-like
shapes in expression position.

---

## 1. Exactly-once when a var is BOTH used directly in a join body AND forwarded onward

**Concern.** The symmetry argument assumes each reserved var is consumed once:
forwarded along the chaining arm, or dropped on a non-forwarding arm. But what if
one join body **uses `w` directly AND also jumps to a downstream join that also
uses `w`**? Then `w` must be **dup'd** (two consumers), not moved once.

**Where.** `cap` (L530–532) and `jDelta = psBoxed ∪ transCap` (L553–558); the
`Let`/`Jump` consume sites inside the join body.

**The question.** When `w ∈ cap(j1)` (used directly in `jbody1`) **and**
`w ∈ cap(j2)` with `j1` onward-jumping to `j2`: does the pass insert a `dup w`
before the direct use so the forwarded copy survives — or does it move `w` once
and then the second consumer hits a freed/over-consumed cell?

**How to check.** Build `j1`'s body as `let u = f w in jump j2(...)` where `f w`
uses `w` (direct consume) and `j2`'s body also uses `w`. `--dump-perceus` should
show a `__rc_dup(w)`; `--dump-rc-stats` should balance. If no dup appears →
double-consume (UAF or over-free). I traced the simple chain/diamond as
single-consume; this "direct + forward of the same var" is the case I'm least
certain the `Let`/`ownedOccs` dup-planning covers, because `w` arrives via `cap`
(implicit), not as a syntactic operand the dup-planner counts.

**OUTCOME (2026-06-14 review) — REAL BUG, fixed.** Confirmed a genuine
double-consume on hand-built IR: a join body `let u = f w in jump j2(...)` where
`j2` also uses `w` emitted **no `__rc_dup(w)`** — `w` was moved into `f w` and then
consumed again inside `j2` (`balanceLint`: `over-consume of u<w>`; at runtime a
use-after-free / double-free). Root cause: the `Let` dup-planner (`dupPlan`,
`consumedHere`) keyed only on `later = freeVarsExpr body`, which does **not** see a
var forwarded *implicitly* through a downstream join's `cap`. `keepInBody` (the
prompt-drop) already consulted `bodyReservedCap`, but the dup-planner was not kept
symmetric with it. **Fix** (`src/Wok/IR/Perceus.hs`): compute
`neededLater = later ∪ bodyReservedCap` and drive both `dupPlan` and `consumedHere`
from it — so a var that is both moved in `rhs` and reserved for a downstream join
is dup'd (one unit for the move, one to forward) and not relinquished early.
Guarded by the IR regression `review #1: join body moving an outer var AND
forwarding it dups` in `test/Spec.hs` (asserts `balanceLint == []` **and**
`stLive == baseline`; reverting the fix reproduces the over-consume). Latent under
the current elaborator — the corpus `--dump-perceus` goldens are unchanged by the
fix, so no surface program emits this shape today.

---

## 2. `reservedCapForBody` on a body whose branches disagree about forwarding

**Concern.** `reservedCapForBody` uses `jumpTargets body`, which unions **all**
branches (L236). So `w` is held live across a `Let` if **any** branch forwards to
a join capturing `w`. On a branch that does **not** forward `w`, `w` must instead
be **dropped** at that branch's own terminal — or it leaks on that path.

**Where.** `Let` prompt-drop `keepInBody` (L451–455); the downstream
`Jump`/`Ret` reconciliation (`dead`, L578 / L413).

**The question.** After `keepInBody` keeps `w` in `deltaBody`, is `w` still in
`delta` at the **non-forwarding** branch's terminal so that terminal's `dead`
set drops it? (It should be: kept in `deltaBody` ⇒ in scope downstream ⇒ in that
terminal's `delta` ⇒ in `dead` since it's neither moved nor in that terminal's
`cap`.)

**How to check.** Body shaped `let x = g w in case b of { A -> jump j(args) ;
B -> Ret 0 }` where `w ∈ cap(j)` only. `--dump-perceus`: arm A forwards `w` (no
drop), arm B emits `__rc_drop(w)`. `--dump-rc-stats` must balance on **both**
runtime branches (test with a `b` that takes A, and one that takes B).

**OUTCOME.** The benign reading — where the `let` rhs does **not** touch `w`
(e.g. `let x = g b`), so `w` flows only through the join cap — is **confirmed
correct**: arm A forwards `w`, arm B emits `__rc_drop(w)`, `balanceLint == []`.
But beware: the example **as literally written** (`let x = g w`, where `g w`
*moves* `w`) is itself the §1 bug — the same "move-in-rhs + forward" root cause —
and is closed by the same `neededLater` fix.

---

## 3. `closeJoins` stopping at an out-of-scope target

**Concern.** `closeJoins` follows only edges present in `ctxJoins`; an unknown
target contributes nothing (`maybe Set.empty snd`, L633). If a `Jump`/`Case` ever
needs the `cap` of a join that is **not in `ctxJoins` at that point**, the
reservation is silently missed → the var is dropped too early → UAF.

**Where.** `closeJoins` (L633); `ctxJoins` lifecycle — joins inserted in
`LetJoin` (L537) for the *delivering body only*, and **reset to empty** inside
each `LetRec` closure body (L603, "joins do not cross a lambda").

**The question.** Is every join a `Jump`/`Case` can reference **always** present
in `ctxJoins` when that rule runs? The elaborator nests `LetJoin j` lexically
*outside* the `Case`/`Jump` that targets `j`, and `ownExpr` processes the
delivering `body` under the augmented `ctxJoins` — so in-scope joins should always
be present. Confirm there is **no** path where a `Jump j` is reached with `j`
absent from `ctxJoins` (which would make `cap` empty and risk an early drop), and
that the `LetRec` join-reset (L603) is correct because a jump truly cannot cross
into a sibling closure body.

**How to check.** Add an internal assertion (temporarily) that every `Jump j`'s
`j` is in `ctxJoins`, run the full suite; or audit `Jump` targets against the
enclosing `LetJoin`s for the corpus via `--dump-anf` + `--dump-perceus`.

**OUTCOME.** Reasoning holds; no defect found. The failure mode (an absent target
→ empty `cap` → early drop → UAF) is **independently covered** by `balanceLint`:
it uses a *flat* `collectJoins` over the whole bind (not the pass's scoped
`ctxJoins`) and inlines join bodies at jump sites, so an early drop surfaces there
as an over-consume. Low risk.

---

## 4. Validated, not proven — and under-exercised by real programs

**Concern (two parts).**
- **`balanceLint` is a second implementation of the same ownership model.** It
  re-derives the cap/transitive/own-children logic to check balance. In principle
  a bug in the *model itself* (e.g. a wrong transitive-closure rule) could be
  present in **both** the pass and the lint → the lint couldn't catch it; the
  genuinely **independent** oracle is the runtime store (`stLive == baseline` +
  UAF/double-free traps), which only fires if a program actually **exercises** the
  shape. **Correction (review):** for the §1 bug this shared-blind-spot worry did
  **not** apply — `balanceLint` *caught* it (it walks the instrumented output with
  a forward count and inlines join bodies, so it does not share the pass's
  dup-planning blind spot). The reason §1 went unnoticed was purely **coverage**:
  no program of that shape existed, so the lint was never run on it.
- **Correction (review): the chained / nested-arm scrutinee shapes (examples
  (b)/(c)) ARE emitted by the surface elaborator** and DO have runtime store-oracle
  coverage — they are `test/rc-examples/21-join-chain-scrutinee.wok` and
  `22-join-nested-arms-scrutinee.wok` (plus `zz-adversarial-nested-cap.wok`), and
  every `rc-examples/*.wok` runs through `rcStatsHarness` (`stLive == baseline`,
  `allocs - frees == baseline`), not just `balanceLint`. What is genuinely **not**
  surface-emitted is the §1 "direct-move + forward of the same var" shape (the
  corpus `--dump-perceus` goldens are unchanged by the §1 fix), so *its* regression
  must be a hand-built IR test. The 500-case property generator still emits only
  first-order data (no chained joins), so value-position nested/chained cases
  remain thinly covered by random programs.

**Where.** `balanceLint` (L987+); the property generator and corpus in
`test/Spec.hs`; `test/rc-examples/`.

**The question.** Do the runtime store oracle tests (not just `balanceLint`)
exercise each tricky shape? Is there at least one **runnable** program per shape
(chained join, nested-arm join, conditional-forward, direct+forward of §1) whose
`--dump-rc-stats` balances — so a model bug shared by pass+lint would still be
caught by the store?

**How to check / strengthen.** For each shape, add a **runnable** program that goes
through `runModuleRC` so the store oracle (independent of `balanceLint`) validates
it. The chained / nested-arm / diamond shapes already have this via the
`rc-examples/*.wok` corpus (21, 22, zz) + the hand-IR `rc letrec` tests. **Done
(review):** the §1 direct-move+forward shape — which the surface elaborator does
not emit — now has a hand-built IR regression (`review #1: …` in `test/Spec.hs`)
that runs through both `balanceLint` and `runModuleRC` (`stLive == baseline`).
Still open: extending the property generator to emit value-position
nested/chained cases, to convert "the lint says balanced" into "the heap actually
emptied at runtime" for randomly-generated programs of those shapes.

---

## Triage

- **#1 — RESOLVED.** It was a real double-consume (UAF) after all: the dup-planner
  ignored the downstream-join reservation. Fixed (`neededLater = later ∪
  bodyReservedCap`) + IR regression added; full suite green (973).
- **#2, #3 — confirmed correct.** #2's benign drop-on-dead-branch holds (but the
  move-in-rhs variant *is* §1); #3's reasoning holds and the failure mode is
  independently caught by `balanceLint`'s flat join inlining.
- **#4 — coverage gap narrowed, not closed.** The (b)/(c) shapes were already
  store-oracle-covered via the corpus; the §1 shape now has a hand-IR store-oracle
  regression. Remaining gap: the random property generator still emits no chained /
  value-position-nested cases.
