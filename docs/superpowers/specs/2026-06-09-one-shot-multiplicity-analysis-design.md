# One-shot multiplicity: an affine (no-dup) analysis on continuation binders

Date: 2026-06-09
Status: Design converged (extended brainstorming + empirical corpus pressure-testing on the
live compiler). Implements the **analysis half of cross-cutting slice X** of
`docs/superpowers/specs/2026-06-05-effect-handlers-ROADMAP.md`, but **re-anchors** that
row — see §11 (Divergences) before reading the roadmap's slice-X description, which this
spec supersedes.
Reads with: `higher-ir-direction` memory ("multiplicity as analysis, *no linear types*,
no-dup first"), `effect-compilation-strategy` memory (contify-vs-reify by multiplicity),
`effect-surface-syntax-final` memory (auto-resume vs bind-to-control; the forgotten-resume
lint this generalizes), `src/Wok/IR/Anf.hs` (the substrate), `src/Wok/IR/Elaborate.hs`
(`elabOpArm`, the resume desugaring), `src/Wok/Interp/Machine.hs` (`dispatchOp`).

## 1. Summary

This slice adds a single static pass: an **affine (no-dup) analysis on continuation
binders**. For each effect-handler operation arm, it computes an upper bound in the
three-point cardinality lattice `{0, 1, ω}` on how many times that arm invokes its captured
continuation (`resume` / the bound `k`) **per performance of the operation**, and it
**rejects the `ω` (multi-shot) case as a compile error**.

The decisive framing, settled during brainstorming: **wok makes one-shot the law.** Every
effect handler resumes its continuation *at most once*. A handler proven to resume more than
once does not compile. This is *no-dup* (affine), computed as an *analysis* — not a linear
or affine *type system*: the user writes no annotations, HM + row inference is untouched, and
"resumes twice" is caught by a downstream pass the way an exhaustiveness check is.

Three things ship:

1. **The analysis** — a type-free structural walk over `Wok.IR.Anf.Expr`, keyed on the
   resume binder's `Name`, computing `{0,1,ω}` with sequencing = `+`, branching = `⊔`, and a
   single sound escape rule (any occurrence of the binder that is *not* the head of a
   saturated call → `ω`).
2. **The consumer** — `ω` ⇒ a `MultishotResume` compile error ("resumes its continuation more
   than once; one-shot handlers only"). The existing slice-2 forgotten-resume lint (the `0`
   case) is left exactly where it is.
3. **The proof harness** — a `--dump-multiplicity` golden artifact printing the inferred
   `0 | 1 | ω` per arm, plus synthetic `typecheck-fail` examples that the law must reject.

## 2. Why this, why now, what it buys

- **Soundness without a value restriction.** (Argument tightened 2026-07-05; the
  conclusion is unchanged.) The classic ML+callcc counterexample (Harper–Lillibridge)
  breaks polymorphism with a continuation thrown exactly ONCE — the hazard is not
  duplicate *invocation* but the generalization CONTEXT being entered twice: undelimited
  callcc RETURNS NORMALLY at capture and can later be re-entered by the throw, so the
  polymorphic `let` binds twice at two types. wok is safe because delimited `perform`
  has NO normal-return path separate from resume: it returns exactly as many times as
  the arm resumes. With resume ≤ 1 (this law), every let-generalization context
  evaluates at most once, so no polymorphic re-binding can occur. (M3 stored
  continuations DELAY the resume but cannot add a second one — the store/take/one-shot
  guards keep the total at ≤ 1.) Hence **the value restriction becomes unnecessary**
  and is dropped from the roadmap rather than deferred.
- **A simpler compiled backend (future).** One-shot-as-law means every continuation
  *contifies* (stack-switch / join-point jump, consumed once); the *reified, copyable*
  multi-shot representation is **never built**. The elimination lands as an *absence* in the
  future codegen, not a change to today's interpreter (§9).
- **It is self-contained.** A static pass over an IR that already exists, with no runtime,
  scheduler, or type-system change. It can land cleanly and first.

## 3. The stance, stated precisely (affine, not linear; analysis, not types)

A **one-shot continuation is an affine continuation** — used at most once. The mapping:

| Cardinality | Substructural reading | Under the law |
|---|---|---|
| `0` (dropped)  | affine permits drop      | legal (abort / `throw`) |
| `1`            | linear (exactly once)    | legal |
| `{0,1}`        | **affine** (no-dup, ≤1)  | **the law** |
| `ω`            | unrestricted (duplicated)| **rejected** |

So **"passes the one-shot law" ≡ "the resume binder is affine."** Deliberately:

- **No-dup, not no-drop.** We enforce *affine* (≤1: both `0` and `1` pass), not *linear*
  (exactly-1) and not *relevant* (≥1). `throw e k -> Err e` drops `k` and must stay legal.
  The soundness payoff comes entirely from no-dup; no-drop is unnecessary and would ban
  exceptions. The forgotten-resume lint is a soft nudge toward no-drop, non-fatal and
  `Never`-exempt.
- **Analysis, not a type discipline.** Same property an affine type system would track, but
  computed as a pass over already-typechecked IR — no surface multiplicity annotations, no
  per-variable use-counts threaded through inference, no user-written linearity. This is the
  recorded `higher-ir-direction`: "multiplicity as analysis (no linear types), no-dup first."

This affine framing is the spec's working vocabulary and the intended populator of the
currently-dead `Anf.Mult.Affine` placeholder (§8).

## 4. Scope

**IN**
- The affine analysis over `Wok.IR.Anf` (the lattice, the walk, the escape rule, the
  join/letrec/handle/recursion treatment).
- The `MultishotResume` compile error (the `ω` consumer).
- `--dump-multiplicity` and a `multiplicity-golden` test group.
- A synthetic `typecheck-fail` corpus (multi-shot, recursion-through-`k`, escaping-`k`) that
  the law must reject, plus golden dumps over the existing `{0,1}` handlers.

**OUT (deferred, with the slice that owns each)**
- **The value restriction** — *dropped as unnecessary* (no multi-shot → no hazard). Not
  merely deferred.
- **`opMultiplicity` table / `once` surface marker** — deferred to **slice 4b** (§7). No
  continuation escapes into a runtime op in this slice, so the table has no consumer yet.
- **Cancellation (discontinue)** — later. The affine framing (resume *xor* cancel, both ≤1)
  is the groundwork; `0`-detection here is the first piece.
- **Compiled-backend continuation representation** — codegen, much later.
- **Interprocedural argument-usage summaries** — not needed (corpus is exact under the
  conservative rule; §10). Add only when a real example demands precision.

## 5. The analysis

A new module `Wok.IR.Multiplicity`. Type-free; operates only on the structure of
`Wok.IR.Anf.Expr`; keyed on the resume binder's `Name`, matched by `nameUniq` (shadowing-robust).

### 5.1 The lattice

```haskell
data Card = Zero | One | Many          -- the {0,1,ω} cardinality; Zero <= One <= Many

joinC :: Card -> Card -> Card           -- branch: only one path runs (max on the chain)
joinC = \a b -> ...                     --   Zero⊔One = One, One⊔One = One, _⊔Many = Many

addC :: Card -> Card -> Card            -- sequence: both run (saturating)
addC Zero x = x
addC x Zero = x
addC One One = Many                     --   two resumes = multi-shot
addC _ _    = Many
```

`joinC` is the branch combinator (`⊔`); `addC` is the sequence combinator (`+`). The lattice
has height 2, so any fixpoint terminates in ≤2 steps.

### 5.2 The core rule

**Every occurrence of the resume binder `r` that is not the head of a saturated application
is an escape → `Many`.** This single rule is what makes the analysis sound without an
interprocedural oracle: the instant we cannot see exactly how often `r` is invoked, we report
`Many` (which the law turns into an error). A helper `mentions r :: a -> Bool` checks for any
occurrence of `r` in an `Atom`/`Rhs`/arg-list.

### 5.3 The walk `cardOf r :: Expr -> Card`

- `Ret a` → `Many` if `a` is `AVar r` (continuation returned as a value = escape), else `Zero`.
- `Let b rhs e` → `addC (cardOfRhs r rhs) (cardOf r e)` (rhs evaluates, then the body —
  sequence). (`b` is a fresh binder; it never rebinds `r`.)
- `cardOfRhs r`:
  - `RApp f args`, `f == r`  → `addC One (if any arg `mentions` r then Many else Zero)`
    — one resume here, plus `Many` if `r` also leaks through an argument.
  - `RApp f args`, `f /= r`  → `Many` if any arg `mentions` r (escapes into an unsummarized
    callee), else `Zero`.
  - `RLam ps body`           → `Many` if `r` is free in `body` (`r` not shadowed by `ps`):
    captured by a closure invokable any number of times. Else `Zero`.
  - `ROp minst _ _ args`     → `Many` if `r` `mentions` in `minst`/`args` (escapes into an
    effect op — the slice-4b case, conservatively rejected now). Else `Zero`.
  - `RCon`/`RRecord`/`RProj`/`RAtom` → `Many` if `r` appears (escape into data), else `Zero`.
- `Case a alts` → `Many` if `a == AVar r` (defensive); else
  `foldr joinC Zero (map (cardOf r . altBody) alts)` — **branch = join** over arm bodies.
- `LetJoin j ps jb e` → compute `cj = cardOf r jb` (resumes per jump to `j`); walk `e` under
  an environment `j ↦ cj`. `Jump j args → addC (env j) (if any arg `mentions` r then Many else Zero)`.
  Two jumps in sequence `addC`; two in different `Case` arms `joinC` — falls out of the
  combinators. A self/mutually-recursive join with `r` inside resolves to `Many` (height-2
  fixpoint, or detect the self-jump).
- `LetRec defs e` → `addC (if r free in any def body then Many else Zero) (cardOf r e)`:
  `r` captured inside a recursive group is invoked an unknown number of times.
- `Handle e h` → `addC (cardOf r e) (if r occurs in any op-arm body of h then Many else Zero)`:
  a nested arm may run many times across its op's performances — conservative.

**Termination:** structural recursion; the only cycles (recursive `LetJoin`/`LetRec`) resolve
to `Many`. **Soundness:** every uncertainty collapses to `Many`; the analysis never
under-counts. False-`Many` rejects valid code (the user rewrites); false-`One` is impossible
by construction (the escape rule has no gap that yields `One` for an `≥2` use).

### 5.4 Auto-resume falls out as `One`

The elaborator desugars an auto-resume arm to `Let res (RApp (AVar resume) [v])` (or
`[param, v]` for a parameterized handler) followed by delivering `res` to a join
(`Elaborate.hs:573-588`). `cardOf resume` sees one head-position application of `resume`
(args are values, not `resume`) → `One`, then the delivery mentions `res` not `resume` →
`Zero`. Total `One`. Auto-resume arms pass for free; no special case.

## 6. The consumer

For each `OpArm oa` in each `Handler`, let `c = cardOf (bndName (oaResume oa)) (oaBody oa)`:

- `c == Many` → **compile error** `MultishotResume <label> <op>`:
  "the `<label>.<op>` arm resumes its continuation more than once; handlers are one-shot."
- `c == One`  → fine. (Auto-resume arms are structurally `One`.)
- `c == Zero` → **left to the existing slice-2 forgotten-resume lint** in `Infer.hs:2001-2007`
  (which already has the `Never`/wildcard information). This pass does **not** move that
  warning — keeping it where the type info lives avoids re-plumbing warnings from typecheck to
  the ANF pass. The full `{0,1,ω}` is still computed internally (`Zero` vs `One` is needed for
  the `addC` identity and the dump); only `ω` is consumed here.

### 6.1 Where it runs

A pass over `CoreModule` after `Pipeline.elaborateProgram`. The error must surface on the
same path that elaboration errors do (the `typecheck-fail` harness captures
`elaborateProgram`'s `Left`, `test/Spec.hs:243-245`), so the analysis is invoked as a
post-elaboration check whose failure is reported as a `Left` from a pipeline entry point
(e.g. a new `Pipeline.checkMultiplicity` folded into `elaborateProgramFull`, or a dedicated
analysed-elaboration entry). Exact wiring is a plan task; the constraint is only that a
`MultishotResume` becomes a `Left`/non-zero exit visible to the golden harness.

### 6.2 `--dump-multiplicity`

A new CLI mode (`app/Main.hs`) and a `prettyMultiplicity :: CoreModule -> Text` printing, per
handler arm, `<label>.<op> : 0 | 1 | ω`. This is the **test artifact**, not a user feature —
it makes the inferred number assertable on a golden corpus.

## 7. FFI / runtime effects and the deferred `opMultiplicity` table

Runtime/FFI effects have no walkable body, so their resumption multiplicity cannot be
*inferred* — it would be *declared and trusted* (an axiom, like an FFI type signature). The
earlier design carried a per-op `opMultiplicity` table (default `ω`, override `once → 1`) and
a flow rule routing an *escaping* `k` through it. **Both are deferred**, because under
one-shot-as-law plus the pull model **no continuation escapes into a runtime op in this
slice**:

- A user arm either resumes `k` in its body (analyzed directly) or aborts — it does not hand
  `k` to the runtime. That handoff is the async/escaping shape (`await fut k -> Blocked fut k`),
  which is (a) modeled as one-shot *pull* + user recursion (events/streams/generators absorb
  the OS's multi-shot push into a runtime-owned queue, below the effect boundary) and
  (b) deferred to slice 4b regardless.
- Therefore the `opMultiplicity` table has **zero call sites** here. Building it now is
  speculative generality, designed before 4b fixes the escaping semantics it must serve.

**When it returns:** slice 4b, exactly when `await`-style ops let a one-shot continuation
*escape* into the runtime and the analysis must certify "the runtime resumes this once." That
trusted per-op multiplicity — and any user-facing `once` marker — is designed against 4b's
real semantics. (Note: a per-op surface marker forks the shared `RecordFieldType` production,
`grammar/Wok.cf:303`, used by records and data too; an effect-level `once effect …` prefix is
the cheaper option. Both are 4b's problem.)

**Landed (2026-06-09, `feat/one-shot-escape`):** as the narrow trusted-once relaxation for
`__coro_susp` (the escape sink) in `Wok.IR.Multiplicity`. Rather than a general
`opMultiplicity` table, the shipped form is a targeted check: the `__coro_susp` builtin is
certified `One` by a trusted-once case in `cardOf`'s `ROp` branch, restoring
`elaborateCheckedFull`. No user-facing `once` marker was needed for this slice.

The FFI shape is uniform regardless: every FFI op is one-shot (perform → suspend one
continuation → runtime resumes it once); whether it resumes *immediately* (sync) or *later,
parked* (async) is the **escape/representation axis** (slice 4b), not the **count axis** (this
slice). This slice only certifies the count is `1`. Pure foreign callbacks (`qsort`'s
comparator) are ordinary function application, not continuations — no multiplicity question.

## 8. Relationship to the dead `Anf.Mult` placeholder

`Anf.Mult = Unrestricted | Affine` (`Anf.hs:27-31`) and `bndMult` are **currently dead**:
every `Binder` is constructed `Unrestricted` (37 sites in `Elaborate.hs`/`Match.hs`),
`Affine` has **zero producers**. The memory reserved `Affine` as "the future no-dup hook" —
which is exactly this analysis's verdict (`{Zero,One} → Affine`, `Many → Unrestricted`).

For this slice the error needs only the verdict, not a binder annotation, so populating
`bndMult` is **optional and deferred**: the natural time to stamp `bndMult = Affine` on a
proven-one-shot resume binder is when codegen wants the fact on the IR. Recorded here so the
placeholder's purpose is unambiguous.

## 9. The interpreter is unchanged (the law is a reversible frontend gate)

The CEK machine's `Kont` is immutable and `VCont` is a closure, so multi-shot is "free" (resume
= re-apply). There is no separate multi-shot machinery to remove; the immutability that enables
multi-shot is the same immutability that keeps the interpreter simple. So:

- **The interpreter keeps its multi-shot capability** — the law is enforced at the frontend.
  If multi-shot is ever wanted back, delete the check; the runtime already handles it. Not a
  runtime amputation.
- The deep-handler re-installation in `dispatchOp` (`Machine.hs:178-201`) is *deep*-handler
  machinery (resume re-enters the handler scope — `sumList`'s repeated `set` depends on it),
  **not** multi-shot machinery; it stays regardless.
- **Consequence for testing:** because the interpreter tolerates multi-shot, it will *not*
  crash on a multi-shot handler the analysis wrongly admits (a false-`One` bug) — it runs it
  and yields a coincidentally-correct result, masking the bug. So the analysis must be tested
  **directly** via the golden dump, never via "does it run."
- **Optional safety net (recommended, low cost):** add a single-use guard to `VCont` (assert
  on a second resume) as a runtime **oracle** that crashes on any multi-shot the static law
  missed. Cheap differential cross-check on the analysis's soundness; gated behind a debug/test
  flag so production runs keep the free multi-shot capability.
  *(Status 2026-07-06: SHIPPED as Phase D of
  `docs/superpowers/2026-07-05-effect-safety-holes-fix-plan.md`. `VCont`/`VContP` carry a
  per-capture used-flag (`OneShotFlag`, minted in `dispatchOp`, asserted in `enter` →
  `OneShotViolation`), gated by `WOK_DEBUG_ONESHOT=1` read once per process — default off, so
  production keeps the free multi-shot capability above. `scripts/oneshot-oracle.sh` re-runs
  the FULL suite under the flag as the differential check. First-run verdict: the law-ADMITTED
  corpus is violation-free; exactly the six run-golden `*multishot*` fixtures abort — they are
  law-REJECTED programs the run-golden harness runs through the UNCHECKED elaborator precisely
  to pin the free multi-shot capability above (the masking this section warned about, made
  visible). The script asserts set-equality on those six as end-to-end negative controls, and
  the hand-built-IR machine test "multi-shot: resume invoked twice" self-adapts to expect
  `OneShotViolation` under the flag — genuine multi-shot arms with the frontend check bypassed
  must abort, satisfying the repo's mutation-confirmation convention. The RC machine needs no
  oracle: its `moveOutCont` already frees the `NCont` shell at first resume, so a second
  resume faults structurally.)*

## 10. Corpus findings (empirical, on the live repo)

Every handler-arm body in the repo, with its resume count:

| Handler (source) | Arm | Count |
|---|---|---|
| `Std.Control` reader | `ask -> e` (auto) | 1 |
| `Std.Control` state  | `get -> s` (auto) | 1 |
| `Std.Control` state  | `set x k -> k x ()` | 1 |
| `Std.Control` writer | `tell w k -> k (log ++ w) ()` | 1 |
| `Std.Control` except | `throw e k -> Err e` | 0 (`Never`-typed, lint-exempt) |
| `test/examples/26-with-handler` | `Ask.ask -> 41` (auto) | 1 |
| `test/examples/20-effects-syntax` | `IO.read`, `IO.write` (auto) | 1 |

Three conclusions that lock the open sub-decisions:

1. **Zero multi-shot handlers exist → a hard `ω`-error is non-breaking; no migration.** So:
   **hard error, not warn-first.**
2. **Zero resume-through-helper cases → conservative-local `ω` is fully precise; no
   interprocedural summaries needed.** Every control arm applies `k` directly. The cheap
   "k-into-a-call → `ω`" rule rejects nothing real.
3. **The corpus's abundant recursion is all *performer* recursion, never recursion-through-`k`.**
   `mtl-machine.run`, `state-accumulate.sumList`, `expr-eval.eval`, `named-instances.sumProd`
   recurse, but they *perform* effects; the `set` arm resumes once *per performance*, and the
   loop just produces many one-shot performances. This empirically validates the **k-directed**
   design: the analysis walks only arm bodies (all `{0,1}`); surrounding recursion never
   enters it.

Because no `ω`/escaping/recursive-resume case exists naturally, the failing corpus must be
**written synthetically**.

## 11. Divergences this spec introduces (roadmap reshaping)

This re-anchors the roadmap's slice-X row and contradicts parts of two memories. Surfaced
deliberately (the slice prompt required flagging reshaping rather than absorbing it):

- **From the slice prompt / roadmap:** payoff #1 was framed as *building toward the value
  restriction*; we **drop** the value restriction as unnecessary. The prompt assumed multi-shot
  stays and the analysis *feeds* a restriction; we **forbid** multi-shot and the analysis
  *enforces* a law.
- **From `effect-surface-syntax-final` / `effect-compilation-strategy`:** both assume
  multi-shot handlers (`amb`, reified continuations) exist. One-shot-as-law **reverses** the
  backtracking-as-handler part. Two mitigations narrow the blast radius: (a) `ndet` for
  *concurrency* (racy scheduling) is untouched — only `amb`/backtracking-*as-handler* moves to
  explicit `List`; (b) the interpreter retains the capability (§9).

**Memory/roadmap updates required once this lands:** update the slice-X row in the ROADMAP;
add/append a memory recording "one-shot is the law, value restriction dropped, multi-shot →
`List`, `ndet`-for-concurrency unaffected, interpreter capability retained"; cross-link from
`effect-surface-syntax-final` and `effect-compilation-strategy`.

## 12. Testing strategy

- **Golden dumps (`multiplicity-golden`):** a new test group mirroring `anf-golden`
  (`test/Spec.hs:159-165`), asserting `--dump-multiplicity` over the existing `{0,1}` handlers
  (`Std.Control`-using examples, `26-with-handler`, `20-effects-syntax`) — pins `0`/`1`.
- **Synthetic `typecheck-fail` examples** (new `test/typecheck-fail-examples/`):
  - multi-shot: `flip k -> k True ++ k False` (and a sequenced `let _ = k a in k b`) → must
    error `MultishotResume`.
  - recursion-through-`k`: a `LetRec`/recursive-join arm that resumes inside the cycle → `ω`.
  - escaping-`k`: an arm returning/storing `k` (`Ret (AVar k)`, `RCon … k`) → `ω`.
  - higher-order-`k`: an arm passing `k` to a helper → `ω` (documents the conservative rule).
  with `typecheck-fail-golden` `.expected` capturing the error text.
- **Unit tests** on `cardOf`/`joinC`/`addC` over hand-built `Expr` (the lattice laws; the
  join/letrec/handle/escape rules) — TDD anchor, since the analysis is the substance.
- Regenerate goldens with `cabal run wok-tests -- --accept` (read diffs before accepting).
  No grammar change → no BNFC regen; the 32 shift/reduce conflicts are untouched.

## 13. Rejected alternatives (with reasons, for deliberate re-litigation)

- **Multi-shot as a legal property (ω feeds value restriction + reify), consumer = dump only.**
  Rejected in favor of one-shot-as-law: the law deletes the value restriction *and* the
  copyable-continuation backend, is non-breaking on the corpus (§10), and yields a stronger
  consumer (a real error, not just a number). The dump is retained as the *test* artifact.
- **`once` surface marker / `opMultiplicity` table now.** Rejected for this slice: no escaping
  `k` into runtime ops exists here, so the table has no consumer; building it is speculative
  generality before 4b fixes the semantics (§7).
- **Interprocedural argument-usage summaries.** Rejected for this slice: the conservative
  "k-into-a-call → ω" rule is *exact* on the entire real corpus (§10.2). Add only on evidence.
- **Move the `0` forgotten-resume warning into the ANF pass.** Rejected: it has the
  `Never`/wildcard type info in `Infer.hs`; moving it re-plumbs warnings for no gain. The two
  passes coexist — `Infer` owns `0`, the new pass owns `ω`.
- **Make the interpreter one-shot-only (linear `Kont`).** Rejected: adds enforcement machinery
  to a non-perf-critical runtime for no benefit; the law is a frontend gate (§9). (A debug-only
  single-use *assertion* is the kept, opt-in form.)
- **Affine/linear *types* on the surface.** Rejected by standing direction: this is an
  inferred analysis, not a typing discipline (§3); HM + row inference stays untouched.

## 14. Build / verify

- `cabal build`; `cabal test` (629 green at branch start — must stay green plus the new
  multiplicity/`typecheck-fail` goldens).
- `cabal run -v0 wok -- <file.wok> --dump-multiplicity` for the new dump.
- No grammar change this slice; if that ever changes, regen BNFC, reapply the three manual
  patches (`grammar/Wok.cf:13-69`), and confirm the shift/reduce count stays 32.
- Full-branch review before any merge to `main` (per-task reviews do not substitute).
