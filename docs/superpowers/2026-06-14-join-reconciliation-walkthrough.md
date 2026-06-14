# Perceus join-point reconciliation — review walkthrough

Scope: `src/Wok/IR/Perceus.hs`, the `ownExpr` Case / LetJoin / Jump rules plus
`closeJoins` and `reservedCapForBody` (lines ~393–665). This is the thrice-fixed,
highest-risk region. Read this alongside the code.

---

## 1. The one invariant

`insertRC` is an ownership-passing pass. It threads an **owned set**
`delta :: Set Unique` — the boxed locals the current context owns and must each
consume **exactly once on every execution path**. "Consume" = one of:

- **move** it (pass as a call/constructor operand, a jump arg, or the `Ret` result), or
- **drop** it (`__rc_drop`), or
- **forward** it implicitly into a join that will consume it.

`dup` is inserted only when a value is needed more than once (sharing). The whole
pass is correct iff every owned var hits **exactly one** consume per path — no
path drops it twice (double-free), none uses-after-drop (UAF), none forgets it
(leak).

Only **boxed** values are owned: `isBoxedType` (L162–180) — unboxed iff the type
is `U64/U32/Char/Unit/String/Never` (the `RVLit` literal types); every
constructor/record/closure type (incl. `Bool`, L177) is boxed. `delta` only ever
holds boxed-binder Uniques.

`ctxExempt` holds **uncounted-region** members (LetRec siblings, L581–612):
referencing one is *not* a counted move; the whole group is released by one
drop at the group's scope exit.

---

## 2. Joins: `cap` and `onward`

A join (`LetJoin j ps jbody body`) is a labelled continuation that several
control-flow arms `Jump j` into. Two facts about each join are recorded in the
context map:

```haskell
ctxJoins :: Map JoinId (Set Unique, Set JoinId)
--                       ^cap         ^onward
```

- **`cap`** (L530–532) = the owned outer locals the join body uses *besides its
  params* (and not exempt). These are delivered **implicitly** through the
  definition scope — not passed as jump args — and consumed inside `jbody`.
- **`onward`** (L536) = `jumpTargets jbody`: the joins this join's body itself
  jumps to. Lets the Case/Jump rules follow **join-to-join chains**.

`closeJoins` (L625–635) transitively closes a seed set over `onward` edges
(seen-set fixpoint → terminates even if joins were cyclic).

The elaborator's canonical value-position shape is:

```
LetJoin j(r) = <continuation k, which may use the scrutinee xs>
Case xs [ arm1 -> Jump j(..) ; arm2 -> Jump j(..) ; ... ]
```

so `xs` ends up in `cap(j)` but is **not free in any arm body** — the trap the
Case rule must not fall into.

---

## 3. Rule-by-rule

### `Ret a` (L394–414) — a consume point
```
owned = atomVars a ∩ delta          -- the (≤1) var being returned
dead  = delta \ owned               -- everything else owned dies here → drop
```
The result `owned` is **moved out** to the caller (never dropped). **F5 fix:**
`owned` is subtracted from `dead` *unconditionally*, so a returned LetRec-group
member (which is in `ctxExempt`) is **not** dropped-then-returned. The old
`(delta \ moved) \ owned` collapsed to this because `moved ⊆ owned` (review #3).

### `Let b rhs body` (L416–468) — binding + prompt-drop
- `dupPlan` (L423–425): a var used `n` times in `rhs` and surviving into `body`
  needs `n-1+1` dups; if it dies here, `n-1`.
- `consumedHere` (L429): operands moved into `rhs` and not needed later leave `delta`.
- **Prompt-drop** (`deadNow`, L452–456): an owned var not live in `body` died at
  or before this point → dropped. `keepInBody` (L453–455) keeps a var iff it is
  **(i)** free later in `body`, **(ii)** an exempt sibling, or **(iii)** in
  `bodyReservedCap`.
- **`bodyReservedCap`** (L451) = `reservedCapForBody (jumpTargets body)` (L643–647):
  vars reserved by any join the body forwards to. This is the **dual** of the
  Jump/`jDelta` reservation, applied to the prompt-drop: a join body like
  `let x = … ; jump jk(…)` must **not** prompt-drop a var that `jk` (or a join it
  chains to) will consume — without this, the symmetric `jDelta` would seed the
  var into the body only for the prompt-drop to free it immediately (the
  double-free the naive #4 fix would have caused).

### `Case a alts` (L500–521) — own-children / drop-parent
- `scr` (L501, `scrutineeParent`): the scrutinee's Unique iff it is an owned
  boxed local (in `delta`, not exempt) — else `Nothing`.
- **`reused`** (L514–517): is the scrutinee still needed after the match? True iff
  it is **free in some alt body** OR in **`capturedByJoins`** — the union of
  `cap` over **every join transitively reachable** from the alts
  (`reachableJoins = closeJoins ctxJoins (altJumpTargets alts)`, L509–513). This
  is the F1 fix: it catches the scrutinee captured by a *chained / nested* join,
  not just a directly-jumped one.
- `parent = if reused then Nothing else scr` (L518): drop the parent at the match
  **only** if it is genuinely dead there. If reused, it stays owned and is
  consumed at its real last use (in an alt body or, via the cap, in the join body).
- `outerDelta` (L519) = `delta` minus the parent; each alt is reconciled against
  the same outer set (`ownAlt`), so a var dead in one branch is dropped there
  (drop-on-the-dead-branch) and the alts all consume the same set by construction.

> **Soundness note in the code (L506–508):** over-approximating `reused = True`
> is *safe* — it keeps the scrutinee owned and the normal Jump/Ret reconciliation
> drops it at its true last use (no leak, no UAF). So the Case side errs toward
> "reused".

### `LetJoin j ps jbody body` (L525–561) — the symmetric seeding
- `cap` (L530–532), `onward` (L536) recorded into `ctxJoins` for `body` (L537).
- `body` is instrumented with the cap **reserved** for the join (jumps leave it).
- **`jDelta`** (L553–558) = `psBoxed ∪ transCap`, where
  `transCap = ⋃ cap(k) for k ∈ closeJoins{j}` — the **transitive** captured set.
  **This is the #4 fix.** The Jump rule reserves the transitive cap; the join
  body must *own* the same set, otherwise a var consumed only in a **downstream**
  chained join is reserved (not dropped) at the jump yet un-owned in this body, so
  a **non-forwarding arm** of this body never drops it → leak. Seeding `jDelta`
  with `transCap` makes this body own it; its own Case/Jump reconciliation then
  **forwards** it on the chaining arm and **drops** it on every non-forwarding arm.

### `Jump j as` (L566–579) — per-site reconciliation
```
moved = (⋃ atomVars as ∩ delta) \ ctxExempt      -- args transferred into j
cap   = ⋃ cap(k) for k ∈ closeJoins{j}           -- TRANSITIVE reserved set
dead  = (delta \ moved) \ cap                      -- drop the rest before the jump
```
The transitive `cap` is why a var consumed in a downstream chained join is **not**
dropped at the upstream jump (the F1 UAF). Dual of the Case `reused` test.

### `LetRec defs body` (L586–612) — uncounted region
Group members are siblings in `ctxExempt`; intra-group references emit no
dup/drop. Each member is **always** a boxed closure cell, so the whole group
enters `delta` and is dropped one-each at scope exit (L610). Each closure body is
instrumented in isolation (fresh context, params owned, **joins reset** — joins
don't cross a lambda, L603).

### `Handle` (L616) — out of coverage, left unchanged (`coveredExpr` rejects it).

---

## 4. The three-way transitive-cap symmetry (the heart)

A var `w` captured only by a downstream join must be treated consistently by all
three rules, or it double-frees / leaks / UAFs:

| Rule | What it does with the transitive cap | Why |
|---|---|---|
| **Jump** (L575) | **reserves** it (excludes from `dead`) | don't drop a var a downstream join consumes |
| **LetJoin / `jDelta`** (L558) | **owns** it (seeds the join body's `delta`) | so the body forwards-or-drops it per arm |
| **Let** prompt-drop (L451–455) | **holds it live** (`keepInBody`) | a `let; jump` body must not pre-drop a forwarded var |

All three compute the **same** `closeJoins` transitive set, so they agree. The
claim to verify: **every reserved `w` is consumed exactly once per path** —
forwarded along the chaining arm into the join that finally drops it, or dropped
on a non-forwarding arm/`Ret`. Arms are mutually exclusive, so the two never
both fire on one path.

---

## 5. Worked examples

**(a) Common value-position case** — `headCons xs = let h = case xs of {…} in Cell h xs`.
Elaborates to `LetJoin j(r)=Cell(h,xs); Case xs [arms -> Jump j(h)]`.
`xs ∈ cap(j)`, not free in arms ⇒ `capturedByJoins ∋ xs` ⇒ `reused=True` ⇒ parent
NOT dropped at the match ⇒ `xs` flows to `j`, consumed once in `Cell(h,xs)`. ✓

**(b) Chained join (F1's original UAF)** — arms jump to `j74` which jumps to `j72`,
and `j72` uses `xs`. `closeJoins{j74} = {j74,j72}` ⇒ `cap` includes `cap(j72) ∋ xs`
⇒ `reused=True`; the upstream Jump reserves `xs`; `j72` owns+consumes it. Pre-fix
`directJumps` saw only `j74` and dropped `xs` at the match → UAF (now fixed). ✓

**(c) Conditional forward (#4's leak)** — `j1`'s body is a Case: arm A → `j2`
(which uses `w`), arm B → `Ret`. `w ∈ cap(j2)`, not in `cap(j1)`.
`jDelta(j1) = psBoxed ∪ transCap ∋ w`, so `j1`'s body owns `w`. Arm A: `Jump j2`
reserves `cap(j2) ∋ w` → forwarded, consumed in `j2`. Arm B: `Ret` → `w ∈ dead` →
dropped. Exactly once per path. Pre-fix `jDelta` had only `cap(j1)` (no `w`) → arm
B leaked (now fixed). ✓

---

## 6. Where to focus your review

1. **The exactly-once claim under multi-var / diamond chains.** I traced chain,
   diamond (`j1→j2`, `j1→j3` both capturing `w`), and forward-vs-`Ret`; each is
   single-consume. The one I flagged for a second pair of eyes — a join whose body
   **both** forwards `w` to a downstream join **and** uses `w` directly — turned
   out to be a **real double-consume bug** (the optimistic note here was wrong: a
   *direct move in a `Let` rhs* is a third consumer beyond forward/drop, and the
   body owning `w` once via `jDelta` is then not enough). The `Let` dup-planner
   keyed on `freeVarsExpr body`, which does not see the implicit downstream-join
   forward, so it emitted no `dup`. **Fixed** in `Wok.IR.Perceus` (`neededLater =
   later ∪ bodyReservedCap` drives `dupPlan`/`consumedHere`); see the review-focus
   doc §1 and the `review #1: …` regression in `test/Spec.hs`.
2. **`reservedCapForBody` vs branchy bodies.** `jumpTargets body` unions **all**
   branches, so a var is held live if **any** branch forwards it. On a branch that
   does **not** forward it, it must be dropped at that branch's terminal
   (`Jump`/`Ret`). Confirm `keepInBody` keeping it in `deltaBody` means the
   downstream terminal's reconciliation actually drops it (it should: still in
   `delta` ⇒ in `dead` there).
3. **`closeJoins` scope.** A join target not in `ctxJoins` (an inner join already
   out of scope) contributes no edges (L633 `maybe Set.empty`). Confirm that's
   the intended "stop" and never silently drops a real reservation.
4. **The over-approximation is validated, not proven.** Correctness rests on
   `balanceLint` (a *second* implementation of the same ownership logic — shared
   blind spots possible in principle) + the runtime store oracle + 973 tests + 500
   property cases. **Correction (review):** the adversarial shapes (b)/(c) *are*
   emitted by the surface elaborator — they are `rc-examples/21-join-chain-scrutinee`
   and `22-join-nested-arms-scrutinee` — and every `rc-examples/*.wok` runs through
   the store oracle (`rcStatsHarness`), not just `balanceLint`. The shape that is
   genuinely not surface-emitted is the "direct-move + forward of the same var"
   case (#1 above); it now has a hand-built IR regression that runs through both
   `balanceLint` and `runModuleRC`. The random property generator still emits only
   first-order data, so value-position chained/nested cases remain thinly covered
   by random programs.

**History to weigh:** F1 took three iterations (Task 7 → `4dc99de` → `0be47d3`),
each green-on-then-current-tests but harboring a deeper bug found by the next
review. Treat "tests pass" here as necessary, not sufficient.
