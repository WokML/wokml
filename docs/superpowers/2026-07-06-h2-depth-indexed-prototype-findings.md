# H2 depth-indexed dischargeability — Phase B prototype gate findings (2026-07-06)

Branch `feat/resume-launders-loadbearing`. Executes Phase B of
`2026-07-05-effect-safety-holes-fix-plan.md` under its locked decisions D-B
(depth-indexed classifier, classifier change only) and D-C (prototype gate;
STOP on a false positive the depth rule cannot express). The prototype was
built, gated, and **reverted**; the tree is back to the pre-B1 classifier and
the full suite is green. The prototype diff (162 lines, classifier + arity
threading through `finalizeGroup`/`finalizeGroupTyped`) is reproducible from
§2 below.

## Verdict: D-B's depth-indexed thesis is FALSIFIED — D-C STOP invoked.

The depth rule (a spine effect-row tail is a channel iff its arrow depth ==
the equation's parameter count) correctly rejects the H2 staged launder and
correctly keeps `mkOk` accepting, but it ALSO rejects the honest
returned-lambda forms — including one of the plan's own three must-stay-
accepting controls and two shipped corpus fixtures. The false positive is
structural: by the time the classifier's rigid skolem meets the inferred type
at reconciliation, inference has already erased the very distinction
(performed-at-activation vs performed-inside-the-returned-closure) the rule
needs. No classifier-only refinement can express it.

## 1. Gate results (all against the built compiler)

Reproducers (scratchpad, shapes from the plan's appendix):

| probe | shape | expected | got |
|---|---|---|---|
| `mk` (H2 staged) | `mk g = let r = run g 0 in \ x -> r + x` | reject | reject `UndischargedEffect` ✓ |
| `mkOk` | `mkOk g x = run g x` (channel at depth == arity) | accept | accept ✓ |
| `mkLam` | `mkLam g = \ x -> run g x` (honest control) | accept | **reject** ✗ FALSE POSITIVE |
| `mkPure` | `mkPure g = \ x -> x` (pure lambda, same sig) | accept | **reject** ✗ FALSE POSITIVE |
| `hold` | no `with` row, never runs `g` | accept | accept ✓ |

`mkPure` is the sharpest datum: the body performs NOTHING anywhere, and it
still rejects — the false positive does not require a perform at all, only
"polymorphic channel deeper than the equation arity".

Full suite: 4 of 2165 failed, two distinct fixtures, both false positives:

- `poly-fp1-open-return-arrow` (accept fixture; 3 of the 4 failures via its
  anf/typed-anf goldens): `foo n = \ g -> run g 0` with the channel on the
  RETURNED arrow. This is FP-1 — the fixture the C1 investigation added
  specifically to pin that this idiom must stay accepting. The depth rule
  rejects the exact false-positive class whose removal motivated the shipped
  scoped design.
- `conc-producer-capture` (death test): still rejects, but as
  `UndischargedEffect` instead of its intended `CarrierEscape (Just (10,1))
  "leak"` — the depth rule re-masks the soundness-guard-ordering regression
  test (the same masking class D4 reclassified six tests to escape).

## 2. The prototype (what was built, for reproducibility)

`dischargeableRowVars` gained an `Int` arity and collapsed to a spine walk —
collect `effTail` only at spine arrow depth == arity (1-indexed, the same
arrow `effRowAtDepth` reads as the ambient seed); parameter-position arrows,
tycon-arg arrows, and other spine depths contribute nothing.
`freezeSigSkolems` took the arity; `finalizeGroupTyped` passed its existing
per-group `arity`; `finalizeGroup` (inner let-groups) got it from the typed
equations' param lists — inner groups have no arity-agreement check, so a
mixed-arity group took the minimum. Build clean; no other code touched.

## 3. Why the false positive is structural (the mechanism, traced)

Three pre-existing inference behaviors combine so that the honest and staged
forms reach reconciliation with IDENTICAL inferred types:

1. **Every application closes the callee's row.** `inferNormalApp`
   (`Infer.hs:2492-2494`) unifies the callee arrow against a fresh row var,
   then `closeRow`s it. Applying `run g x` binds the row var SHARED with
   `g`'s `Suspension … (row e)` argument to `{}`. (This is Finding 3 of the
   C1 findings doc — the app-site `closeRow` is the actual laundering site —
   now shown to also defeat reconciliation-time depth-indexing.)
2. **A bare residual row contributes nothing to the ambient.** `emitRow`'s
   open-tail arm is `pure ()` (`Infer.hs:3051`), so a polymorphic perform
   leaves no trace in whichever ambient was active (the plan's A4 corner is
   the same arm).
3. **A lambda's row is closed-by-default.** `Abs.ELam` inference installs a
   fresh sub-ambient and `closeRow`s it (`Infer.hs:2187-2191`), so a returned
   closure's inferred row is `{}` no matter what it performed.

Consequence: for BOTH `mk` (staged) and `mkLam` (honest), the inferred type
at reconciliation is `Suspension … {} -> (U64 -> U64 with {})`. The declared
side under the depth rule has rigid `E` in both slots. Both clash; the
classifier cannot tell them apart because the discriminating fact — WHICH
ambient was active when `run` was applied — is not in either type. Rigid
skolemization judges reconciled TYPES; the staged/honest distinction is a
property of the inference TRACE. That is emit-site territory, and D-B
explicitly (and rightly) forbids resurrecting rung-1 emit-site recording as
a "classifier change".

Note `mk` and `mkLam` even share surface shape (both return lambdas); no
syntactic refinement of the classifier separates them either.

## 4. What this falsifies, precisely

- Plan D-B's "verified reasoning" that `mk g = \ x -> run g x` still accepts
  "because the lambda row unifies with the rigid at reconciliation" — wrong:
  the lambda row is closed to `{}` before reconciliation (mechanism 3), and
  the Susp slot is closed by mechanism 1. Nothing polymorphic survives to
  unify.
- Rung-3 spec F3's "candidate fix: depth-indexed dischargeability … the
  honest forms stay accepting (the returned lambda's row reconciles
  separately)" — the returned lambda's row does reconcile separately, but as
  `{}`, not as the declared var.

H2 therefore remains OPEN, in the same state the plan recorded: a
type-honesty hole, dynamically backstopped (eager `start` demands the
residual at its own site; second-class carriers keep resumes inside the
discharging handler — the exploiting caller is rejected at the `start` site).

## 5. Directions for a future slice (recorded, not attempted — per D-C)

- **Emit-site closed-ambient check for bare residuals.** Make `emitRow`'s
  bare-tail arm reject (or record) when the ACTIVE ambient is closed and
  cannot reach the residual var — the H1 finding already noted "the deleted
  rung-1 recording (closed ambient + bare residual) would have caught it",
  and it would also close the A4 corner. This is a positioned emit-site
  check, i.e. exactly what D-B excluded from Phase B's scope; it needs its
  own false-positive analysis (handler-discharged residuals, open sub-
  ambients) and a fresh decision to re-litigate D-B.
- **Row-plumbing rework.** Stop erasing residual tails: unify callee tails
  into the ambient instead of `closeRow`-ing at each application (C1 Finding
  3's "re-plumbing" option). Largest change, would make reconciliation-time
  classification honest, interacts with everything the flexible-absorption
  path currently carries.
- **Accept the dynamic backstop as the design position.** Second-class
  carriers + eager `start` make the hole unexploitable at `--run` today; the
  cost is only signature honesty for staged partial applications. Cheapest,
  and consistent with how the trilemma was resolved for chaining generators.
