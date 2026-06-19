# M2b resume-binder-type RC leak — design

Date: 2026-06-19
Status: design, pending user review
Branch: off `main` (M3 merged at `56a6a8e`)
Supersedes the characterization in `2026-06-18-m3-stored-continuations-design.md` §10 item 6.

---

## 0. Summary

A handler operation arm that **discards** its `resume` binder (an "abort" arm) silently
leaks the captured continuation's owned set — but **only when the handler's answer type
is an unboxed scalar** (`U64`/`U32`/`Char`/`Unit`/`String`/`Never`; `Bool` is boxed).
The program returns the correct value; only the reference-counted heap leaks
(`allocs > frees`).

The leak is **not** about `Never`-vs-resumable operations (the framing in the M3 spec
§10 item 6). It is about the **boxedness of the answer type**, and the root cause is a
**mistyped binder in elaboration**: the `resume` binder is annotated with the handler's
*answer type* `R` instead of the *continuation type* `T -> R`. When `R` is unboxed, the
RC pass concludes "nothing to free" and omits the drop — even though `resume` is always a
boxed heap object (`NCont`) at runtime.

The fix is at the **source of truth**: the typechecker already computes the correct
`resume : T -> R` and then discards it; thread it onto the typed arm node and have the
elaborator use it for the binder. The reference-counting pass (`Wok.IR.Perceus`) is
**not modified** — the corrected type flows through its existing, already-audited path.
The second line of defense lives in the **oracle / generative test layer**, not in new
Perceus code.

---

## 1. The bug (verified ground truth, `main` @ `56a6a8e`)

### 1.1 Symptom

Run a program whose handler has an op arm that binds but never applies `resume`, with a
boxed value live across the op, under `--dump-rc-stats`. When the answer type is unboxed,
`allocs > frees` and `peakLive > baseline`. The differential value oracle passes (the
program computes the right answer); only the heap-stats harness catches the leak.

### 1.2 Empirical evidence (six minimal programs)

Each program is an abort arm (discards `resume`) with a boxed list live across the op.
Only the **answer type** and the op signature vary:

| program | op signature | answer type | arm body | stats |
|---|---|---|---|---|
| `test/rc-m2b/03` (existing) | `throw : U64 -> Never` | `Option a` (boxed) | `None` | 6 / 6 balanced |
| choose-abort | `choose : U64 -> U64` | `Option a` (boxed) | `None` | 6 / 6 balanced |
| choose-tail-list | `choose : U64 -> U64` | `[U64]` (boxed) | `[9,9]` | 8 / 8 balanced |
| throw-tail-list | `throw : U64 -> Never` | `[U64]` (boxed) | `[9,9]` | 8 / 8 balanced |
| **choose-tail** | `choose : U64 -> U64` | **`U64` (unboxed)** | `88` | **5 / 0 LEAK** |
| **throw-tail** | `throw : U64 -> Never` | **`U64` (unboxed)** | `88` | **5 / 0 LEAK** |

A decisive control (`split-TR`): op result `[U64]` (boxed) but answer `U64` (unboxed) →
**still leaks**, proving it is the **answer** type, not the op result type, that drives
it.

### 1.3 The exact divergence in drop placement (`--dump-perceus`)

In every **balanced** case the op arm carries `let _drop = __rc_drop(resume)`. In the
**leaking** case the arm is uninstrumented:

```
Choose.choose(n, resume) -> 88          -- no __rc_drop(resume): leak
```

vs.

```
Choose.choose(n, resume) ->             -- boxed answer: drop is present
  let _drop = __rc_drop(resume)
  ...
```

With no `__rc_drop(resume)`, the runtime never runs
`dropAddr → cascadeChildren(NCont) → continuationOwned`, so the captured value (and the
continuation shell) are never freed. `frees = 0` because the only drops that would free
the captured value live inside the continuation, which an abort never runs.

---

## 2. Refutation of the original characterization

The M3 spec §10 item 6 said: "a *resumable* (non-`Never`) op-arm that discards `resume`
leaks; a `Never`-typed `throw` abort with the same owned set is heap-balanced." The
empirical table refutes both halves:

- A **`Never`-typed** `throw` abort **also leaks** when its answer type is unboxed
  (`throw-tail`).
- A **resumable** `choose` discard **balances fine** when its answer type is boxed
  (`choose-abort`, `choose-tail-list`).

The existing M2b abort tests (e.g. `02`, `03`, `25`) survived only because their answer
type is `Option a` (boxed). The `Never` typing was incidental — a red herring. The real
axis is **boxed vs unboxed answer type** of any discard-resume arm.

Consequently the M3 spec's fix direction ("place the drop for every card-0 arm regardless
of *op result type*") is aimed at the wrong knob: it is not about card-0 detection or the
op result type. It is that `resume` is classified as unboxed and so never enters the arm's
owned set.

---

## 3. Root cause (the precise locus)

`src/Wok/IR/Elaborate.hs` `elabOpArm` builds the resume binder as:

```haskell
pure (OpArm effect op argBinders (Binder resumeN Unrestricted (teType body)) armBody)
```

`teType body` is the **answer type `R`** in the explicit-resume ("control") and
wildcard-discard branches (the body produces the answer). The binder is therefore
annotated with `R`, not the continuation type `T -> R`. The code's own comment flags this
as imprecise but claims it is "currently unused ... no typed pass reads it." That is
**false**: `src/Wok/IR/Perceus.hs` `ownOpArm` computes the arm's owned set via

```haskell
armDelta = Set.fromList [ binderUnique b | b <- bs, boxedBinder b ]
```

and `boxedBinder = isBoxedType . bndType` (`Wok.IR.Escape`). `isBoxedType` returns `False`
for the unboxed scalars, so when `R` is unboxed, `resume` is excluded from `armDelta`, the
dead-binder drop machinery never emits `__rc_drop(resume)`, and the `NCont` (with its
owned set) is never freed. At runtime `resume` is **always** a boxed handle
(`RVBox cAddr → NCont`), so the static "unboxed, skip it" decision is the bug.

### The corrected type already exists and is discarded

`src/Wok/TypeChecking/Infer.hs` (the op-arm inference, control branch) already computes
the exact continuation type and uses it to typecheck the arm body:

```haskell
resumeRow <- freshRVar
paramRow  <- freshRVar
let resumeTy = case mParam of
      Just (_, paramTy, _) -> arrowT paramTy paramRow (arrowT resultTy resumeRow answerT)
      Nothing              -> arrowT resultTy resumeRow answerT   -- T -> R
    mono2 = Map.insert kname resumeTy mono1
```

`resumeTy` (= `T -> R`, or `sigma -> T -> R` for a parameterized handler) is bound into
the body's environment so `k` typechecks as a function — and then thrown away: it is not
recorded on the `Ty.TOpArm` node, so the elaborator cannot see it and falls back to
`teType body`. For a `Never`-typed op, `resultTy = Never`, so the checker's `resumeTy`
is `Never -> R` (boxed) — correct — but the elaborator's `teType body = R` clobbers it.

"Give `resume` the function type" is therefore **not inventing a type** — it is keeping
the one the typechecker already worked out.

---

## 4. The fix (decisions locked during the brainstorm)

### 4.1 Locus: the typechecker (root cause); Perceus is untouched

Fix where the bug is — the type. The typechecker is the source of truth from which
`boxedBinder` (and any future typed pass) derives its decisions; correcting the type makes
every derived decision correct automatically, rather than patching each derived decision.

A `Wok.IR.Perceus` backstop (force `resume` into `armDelta` regardless of type) was
**considered and rejected**: (a) it is unnecessary once the type is correct, and (b)
`Perceus` was heavily audited the week prior (M3 H1–H5, two `xhigh` reviews), and adding
"safety" code to a freshly-hardened soundness module is itself risky — the M3 H5 pass
found two of the pins H1–H4 had just added were buggy (a dead tautology, an over-narrowed
check). Reopening that surface buys no soundness here.

### 4.2 Why Perceus needs no change

`Perceus` already does the right thing; it trusts the type it is handed. Today:

- boxed-answer arms: `resume` is boxed → enters `armDelta` → dropped on discard /
  moved-out on apply. **This is the audited, working path.**
- unboxed-answer arms: `resume` mislabeled → skipped → leak.

Once the type is `T -> R` (always an arrow; `isBoxedType (CTArr ...) = True`), the
unboxed-answer arms **converge onto the identical audited path**. No code path is added to
`Perceus`; the previously-buggy programs are routed through the one already reviewed. The
only observable change inside `Perceus` is *which binders land in `armDelta`*, and that set
now matches the shape the boxed-answer corpus already exercises. The apply path is
unaffected: applying `resume` consumes it as a call-head move (`ctxResume` →
`moveOutCont`), independent of `armDelta`; an applied binder is not "dead" so no extra drop
is placed (no double-free). A stale comment in `ownOpArm` may be refreshed; no logic
changes.

### 4.3 What to thread, and how

Carry the already-computed continuation type onto the typed arm node and stamp it onto the
binder in elaboration. Apply it in **every** branch that creates a resume binder
(control, wildcard-discard, **and** auto-resume), giving a uniform invariant: *the resume
binder is always an arrow, hence always boxed.* Auto-resume and applied arms do not leak
today, but typing them honestly keeps the invariant total and keeps `boxedBinder`
uniformly correct.

Mechanically:

- `Wok.TypeChecking.Typed`: add a type-annotation field to `TOpArm`:
  `TOpArm Text Text [Tpat a] Text a (Texp a)` (effect, op, args, resume-name,
  **resume-continuation-type**, body). The datatype derives
  `Functor/Foldable/Traversable`; the bare `a` field is mapped by the same traversal that
  zonks the rest of the tree (`generalizeTyped` / `freezeTypedTreeSig` use `traverse`), so
  the field is converted `Type s → CType` with no special handling.
- `Wok.TypeChecking.Infer`: compute the param-aware `resumeTy`
  (`mParam`-aware: `sigma -> T -> R` or `T -> R`) once before `case binderPs`, and pass it
  in all three `Ty.TOpArm` constructions (`resultTy`, `answerT`, `mParam` are all already
  in scope). The control branch already has it.
- `Wok.IR.Elaborate`: extend the `TOpArm` destructuring and `elabOpArm` to receive the
  threaded type, and build the binder as `Binder resumeN Unrestricted resumeContTy`
  instead of `(teType body)`. Remove/replace the now-stale "currently unused" comment.
- `Wok.TypeChecking.Carrier` (4 pattern sites: lines ~371, 554, 704, 868) and
  `Wok.TypeChecking.Infer` `goArm` (~line 2085): widen the `TOpArm` patterns with the new
  field (they ignore it).

### 4.4 The lines of defense live in the test layers, not Perceus

To avoid resting soundness on a single static layer (the project discipline) **without**
touching `Perceus`, put the independent checks in the test layers, which do not depend on
the type fix. Two layers, at the point each is cheapest to catch a regression:

- **Type layer (primary, earliest).** A QuickCheck property over generated well-typed
  handlers asserting the resume binder is always a boxed arrow (§7.7 P1). This catches a
  re-mistyping at the typechecker/elaborator — where the bug lives — before it can ever
  become a leak. The existing Suite-G generator cannot do this: it builds Core directly
  and never runs the typechecker.
- **RC layer (end-to-end net).** The `test/rc-m2b/*.wok` file corpus carries the §1.2
  leaking shapes (`choose-tail`, `throw-tail`, `split-TR`) plus boxed-answer balanced
  variants and an apply-path case, auto-run through the existing handler-admitting RC
  heap-balance harness. These are the run-the-exploit + red-check: RED before the fix on
  the unboxed-answer shapes, GREEN after; reverting the fix turns them red again. This
  class is narrow (unboxed-vs-boxed answer × discard) and the type-layer property covers
  its breadth, so a hand-written corpus is sufficient end-to-end coverage here (it is the
  *broad* classes where hand-picked cases miss the class). NOTE: the existing Suite-G
  `genProgram` builds Core **directly** and generates **no handlers**, so it cannot be
  extended to a generative RC handler oracle cheaply; running the §7.7 generator's programs
  through the RC runner is a possible later enhancement, not required for this fix.
- Add the §1.2 leaking shapes as permanent **red-checked** corpus tests: revert the type
  fix ⇒ both the type-layer property and the unboxed-answer corpus test go red.

---

## 5. Implementation surface (files and sites)

| File | Change |
|---|---|
| `src/Wok/TypeChecking/Typed.hs` | Add `a` field to `TOpArm` (resume continuation type). |
| `src/Wok/TypeChecking/Infer.hs` | Compute param-aware `resumeTy`; pass it in all 3 `TOpArm` builds; widen `goArm` pattern. |
| `src/Wok/IR/Elaborate.hs` | Receive the type; build the resume binder with it; drop the stale comment. |
| `src/Wok/TypeChecking/Carrier.hs` | Widen 4 `TOpArm` patterns (field ignored). |
| `src/Wok/IR/Perceus.hs` | **No logic change** (optional stale-comment refresh). |
| `test/rc-m2b/*` + Suite-G | New corpus red-checks + generative dimension (§7). |

---

## 6. Consistency checks to perform during implementation

1. **No other reader of `resume`'s `bndType`.** Confirm `boxedBinder` (via `Perceus`
   `ownOpArm`) is the only consumer of the resume binder's type; the runtime keys `resume`
   by name, and `Multiplicity`/`Escape` key on the binder's `Unique`/occurrences, not its
   type. If another consumer exists, verify an arrow type is correct for it.
2. **Zonk / generalization survival.** Confirm the threaded `resumeTy` (built from
   `freshRVar` rows) survives `traverse`-based zonking into a valid `CType`, and that an
   unsolved row generalizes/closes consistently with the rest of the arm (it is already
   used to typecheck the body, so it is already solved/constrained the same way).
3. **Derived `Foldable`/`Traversable` consumers.** The new bare-`a` field is now visited
   by `toList`/`foldr`/`traverse` over `THandlerArm`/`Texp`. Confirm no consumer
   positionally depends on the element sequence (expected: all such traversals are uniform
   type maps, e.g. zonk, which are unaffected).
4. **Parameterized handlers (M2b-2).** Confirm the `sigma -> T -> R` shape threads
   correctly and the two-arg apply path still consumes `resume` as a move (no new drop on
   the applied path).
5. **`Never` op arms.** Confirm a `Never`-typed op's resume binder becomes `Never -> R`
   (boxed) and is now dropped on a discard arm, and that the existing `Never` abort tests
   (`02`, `03`) stay balanced (no double-free).

---

## 7. Testing and the oracle (run-the-exploit; non-negotiable)

RC leaks are silent and stats-only, so the discipline is run-the-exploit + red-check:

1. **Red state first.** Land the §1.2 leaking programs (`choose-tail`, `throw-tail`, and
   the `split-TR` control) as corpus tests asserting `allocs == frees`; confirm they are
   **RED** on the parent commit (leak reproduced) before the fix.
2. **Green after the fix.** The same tests must be heap-balanced AND reference-matched
   after the fix.
3. **Red-check.** Reverting the type fix must turn a **named** unboxed-answer test red
   (the leak returns).
4. **No regression on the boxed path.** The existing M2b corpus (`01`-`26`) and the M3
   corpus stay green; in particular the `Never` abort tests (`02`, `03`) stay balanced
   (no double-free introduced).
5. **Generative dimension (type layer).** The §7.7 source-level generator produces
   well-typed handler programs across `{boxed, unboxed}` answer types × arm shape, run
   through the in-memory typechecker; the resume-binder-is-a-boxed-arrow property (§7.7 P1)
   then covers the leak class's *breadth* generatively, not hand-picked. The RC end-to-end
   coverage is the file corpus (item 1). Add `checkCoverage` floors for the boxed/unboxed
   and arm-shape dimensions.
6. **Apply-path safety.** Add a balance test for an **unboxed-answer applying arm**
   (resume now in `armDelta` and applied) to lock that the move-out still prevents a
   double-free.

### 7.7 Typechecker / inference property tests (the type-layer net)

The existing generative oracle (`genProgram :: Gen CoreModule`, Suite-G) builds Core
**directly** and bypasses parse/typecheck/elaborate, so it never exercises the
resume-binder-type threading — the type-layer invariant is currently untested by any
generator. These property tests close that gap at the layer where the bug lives, catching
a re-mistyping **earlier and more locally** than the RC heap oracle (a wrong type fails the
property immediately, before it ever becomes a leak). They are pure-function properties
(parse → infer → elaborate is pure), which the project tests exhaustively.

**Generator.** A well-typed-by-construction generator over a fixed handler skeleton with
type/shape knobs, NOT random text:

- **answer type `R`** drawn from a representative table spanning **unboxed** (`U64`,
  `Unit`, `String`) and **boxed** (`[U64]`, `Option U64`, `(U64, U64)`, `Bool`), each with
  a sample literal expression (e.g. `U64 → 0`, `[U64] → [0]`, `Option U64 → Some 0`);
- **op result type `T`** drawn from the same table (so the arrow is checked on both sides);
- **arm shape** ∈ { discard-named (`op n k -> …`), discard-wildcard (`op n _ -> …`),
  apply (`op n k -> k …`), auto-resume (no binder) };
- **parameterized** ∈ { no, yes (`count = 0` seed + two-arg resume) }.

The skeleton renders a minimal module (`effect E = { op : U64 -> <T> }`, a `prog` that
performs `op` and returns `<R>`, and a `run` handler) and is run through
`Pipeline.elaborateCheckedFull` (and the typed-AST seam used by `inferTypedTests`).
Programs that fail to typecheck are a generator bug, not a `discard` — the skeleton is
constructed to always type. `cover` / `checkCoverage` floors ensure both boxed and unboxed
`R`, and every arm shape, are actually generated.

**Properties.**

- **P1 — boxedness invariant (headline; this property would have caught the bug).** For
  every generated well-typed handler, every elaborated `OpArm`'s resume binder is boxed:
  `boxedBinder (oaResume oa) == True` (equivalently `bndType (oaResume oa)` is a `CTArr`).
  Holds across all answer types and arm shapes.
- **P2 — threading correctness.** The resume binder's type is the continuation type
  `T -> R` (unparameterized) or `sigma -> T -> R` (parameterized), matching the op's
  result type and the handler's answer type — not merely *some* arrow. Catches a
  wrong-but-boxed type (e.g. `R -> R`).
- **P3 — Infer/elaborate agreement.** The arrow recorded on the typed `TOpArm` field
  (Infer layer) equals the type stamped on the elaborated `OpArm` binder (Elaborate
  layer): the type used to *check* the body and the type *recorded* on the binder do not
  drift.
- **P4 — foundational lemma.** `isBoxedType (CTArr a r b) == True` for all generated
  `a, r, b`, and `boxedBinder (Binder n m (CTArr …)) == True`. Trivial but documents and
  locks the assumption the fix rests on (arrows are always boxed).

The generator runs **in memory** via `TC.inferProgramWith B.initialEnv` (the seam
`inferTypedTests` uses) over self-contained modules that use only builtin types (`U64`,
`Unit`, `String`, `[U64]`, `(U64, U64)`) so no `Std.Base`/loader/temp-file is needed; it
walks the resulting typed decls for every `TOpArm` and inspects its resume-type field. RC
end-to-end coverage is the file corpus (§7 item 1), not this generator.

**Location.** A new `resumeBinderTypeTests` group in `test/Spec.hs`, beside
`inferTypedTests` / `elaborateEffectsTests`, using `testProperty` + the existing
`Test.QuickCheck` imports and the `elaborateCheckedFull` / typed-AST seams.

**Red-check.** Reverting the type fix must turn P1 red (the unboxed-`R` cases regress to a
non-arrow type).

A full-branch adversarial `/code-review` that **builds exploit programs** before merge is
the user's gate; per-task reviews do not substitute. Budget a review round.

---

## 8. Scope

**In scope.** The resume-binder-type leak: the typechecker→elaborator type threading, the
run-the-exploit reproducer + red-check, the generative dimension, the consistency checks.

**Acceptance.** The §1.2 unboxed-answer repros are heap-balanced; the boxed path and the
`Never` abort path stay balanced (no double-free); the apply path is double-free-free; the
type-layer property (§7.7 P1: resume binder always a boxed arrow) holds across answer
types and arm shapes; the RC generative property covers the discard-resume ×
answer-boxedness shape; the full suite is green; `Perceus` has no logic change.

**Deferred / out of scope.**

- The opaque-carrier (`extern type`) representation of `resume` (a type-level escape wall)
  — rejected for this fix: M3 deliberately keeps `resume` function-typed to avoid a
  coercion, and the escape-into-data wall already exists via the boundary guard
  (`m2bResumeEscapes`).
- A `Perceus` "always-own resume" backstop — rejected (§4.1); the second layer is the
  oracle (§4.4).
- The M3 backlog diagnostics residuals (#12 `APrim` atom form, #13 expression-position
  spans) — diagnostics-only, no soundness impact.
- The answer-decoupling / in-wok-scheduler milestone — separate; this fix de-risks it by
  making the resume binder's type honest.

---

## 9. Risks and open questions

1. **`TOpArm` field addition is broad-but-mechanical.** It touches every `TOpArm` pattern
   (Infer, Elaborate, Carrier). Risk is a missed pattern → compile error, not a silent
   bug. The derived-`Functor` zonk handles the field automatically. Low risk.
2. **Row generalization of the threaded type.** If the resume row generalizes oddly at the
   top level, the stamped `CType` could carry an open row. This does not affect
   boxedness (`CTArr _ _ _` is boxed regardless of the row), so the leak fix holds even in
   the worst case; correctness of the precise row is a §6.2 check, not a soundness gate.
3. **Apply-path double-free (guarded).** Forcing the boxed arrow type means
   unboxed-answer applying arms now place `resume` in `armDelta`. The move-out consumes it
   so no double-free is expected — but this is the one new combination and is explicitly
   tested (§7.6).

---

## 10. Glossary (layman terms)

- **Boxed value:** a value the reference counter tracks and frees — a pointer to a heap
  object (lists, records, closures, continuations). The opposite is **unboxed**: a raw
  inline value (a `U64` number) that lives in place and is never counted.
- **Answer type (R):** what the whole handler finally produces — the type the `return` arm
  and every op arm hand back. Distinct from the **op result type (T)** (what
  `e.op(...)` evaluates to inside the program). The continuation `resume` has type
  `T -> R`: "give me an op result, I'll finish and give you the answer."
- **Discard / abort arm:** a handler arm that never calls `resume` — it stops the paused
  computation instead of continuing it. It must free the captured continuation; if it
  doesn't, the continuation's owned set leaks.
- **Owned set:** exactly the heap values a paused continuation is responsible for freeing.
  Freed once on a discard via the continuation's drop.
- **The bug in one line:** the compiler labeled the continuation with the answer's type
  (sometimes "a plain number, nothing to free") instead of "a continuation, a heap handle
  to free," so it skipped the free.
