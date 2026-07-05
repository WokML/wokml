---
spec: rung3-rework-scoped-rigid-trapped-effect-skolemization
status: implemented (feat/resume-launders-loadbearing, 2026-07-04; whole-branch review SHIP)
supersedes: 2026-07-03-rung3-rework-rigid-residual-skolemization-spec.md
---

> **POST-SHIP AMENDMENTS (2026-07-05, adversarial pressure-test).** Three
> corrections against the shipped code, without changing the verdicts above:
> (1) D1 as written names ONE classifier; the shipped rule (commit 1c75751) is
> TWO: rigidify iff `effectRelevantRowVars isCarrier` (arrow eff-tail either
> polarity, or a row-arg of a tcCarrier-marked tycon) AND NOT
> `dischargeableRowVars` — record/data row polymorphism must never rigidify.
> Line refs drifted: classifier `Infer.hs:364`, `effectRelevantRowVars :398`,
> `freezeSigSkolems :420`, reconciliation `:3390`/`:3456`.
> (2) C2/AS3 are scoped, not absolute: completeness holds for vars with no
> positive channel ANYWHERE in the signature. A var whose only channel sits on
> an arrow BELOW the equation's activation depth still launders (F3 below);
> the deleted rung-1 recording caught that shape, so §6's "stricter than the
> old apparatus" is really "incomparable; stricter on the tested corpus."
> (3) F2's root cause was pinned empirically and is FIXED — see the rewritten
> F2 below.

# Rung-3 rework: scoped rigid skolemization of TRAPPED effect-row signature vars

> Layman one-liner: a function that receives an effect as a parameter can secretly
> perform it while its signature still claims to be pure ("effect laundering"). We
> fix it by checking a function's declared effect-polymorphism the same way the
> compiler already checks its declared type-polymorphism: freeze the declared
> variable into an unbreakable constant and check the body against it. The one new
> idea is scope — we only freeze an effect variable the function has no declared
> channel (`with eff e`) to perform. That single, principled change deletes the
> entire ~300-line hand-rolled laundering detector (rungs 1-3).

## 1. Why this spec exists (supersedes the naive rigid thesis)

The predecessor spec (`2026-07-03-rung3-rework-rigid-residual-skolemization-spec.md`)
proposed "one honest change at `freezeSigSkolems`": mint EVERY KEffect signature var
as a rigid skolem. Its C1 prototype gate FALSIFIED that thesis — the un-scoped flip
breaks the prelude (open-sig runners `reader`/`state`/`run`/`start` fail at
reconciliation because a rigid open tail cannot absorb a still-present concrete
label). Full C1 findings, with runnable evidence, are in
`docs/superpowers/2026-07-03-rung3-rework-C1-prototype-findings.md`.

The C1 investigation then found the correct formulation, which C1 had never tested:
**SCOPE the rigidity to TRAPPED effect variables** — those the signature never grants
a channel to perform. This is sound + complete on the entire corpus and the adversarial
hunt (see §8), and it achieves the predecessor's actual goal (delete the apparatus)
which the fallback NG2 post-hoc pass could not.

## 2. The mechanism (single site, ~30 lines)

A signature effect-row variable `e` is **dischargeable** iff it appears as the tail of
some arrow's effect-row slot in a net-POSITIVE (result-spine) position of the declared
type — i.e. the function declares `... -> R with eff e` (including on a RETURNED
function's arrow). A `with eff e` on a PARAMETER arrow is the CALLER's promise, not
this function's channel; polarity flips at each arrow domain. A var that occurs in the
signature but is NOT dischargeable is **trapped**.

<decision id="D1">
`freezeSigSkolems` (`src/Wok/TypeChecking/Infer.hs:394`) mints a KEffect signature var
as a **rigid skolem** iff it is trapped, and a fresh flexible `freshRVar` otherwise
(the historical path). The classifier is `dischargeableRowVars :: CType -> Set Int`
(`Infer.hs:370`), a polarity-aware walk of the declared `CType`:

```
pos (CTArr a eff b)  = effTail eff ∪ neg a ∪ pos b   -- eff tail here IS a channel
pos (CTCon _ ts)     = ⋃ pos ts                       -- (covariant approx; see §7)
pos (CTRecord _ row) = pos row
pos (CRExtend _ p r) = pos p ∪ pos r
neg (CTArr a _ b)    = pos a ∪ neg b                  -- eff tail here is NOT a channel
neg (CTCon _ ts)     = ⋃ neg ts   ...
effTail (CRExtend _ _ r) = effTail r ; effTail (CTGen i) = {i} ; effTail _ = {}
```

The rigid skolem is minted ONLY at reconciliation (`freezeSigSkolems`, called from
`finalizeGroup`/`finalizeGroupTyped` at `Infer.hs:3540`/`3603`), AFTER body inference.
`closeRow` runs only DURING body inference, so it never touches the rigid skolem — the
C1 "closeRow overwrites a rigid" hazard does not arise for scoped site-2 rigidity.
</decision>

### Why it works (the laundering becomes the detector)

A signed body is inferred against a FLEXIBLE instantiation; when the body performs a
trapped residual, `closeRow` launders it to `{}` (the pre-existing laundering step).
The declared rigid skolem `E` then meets that `{}` at the reconciliation
`unify Nothing declT tv` and `rigidUnify` throws — the erasure that DEFEATS a post-hoc
pass is exactly what MAKES this fire. The anchor is the immutable declared signature,
so there is no erased variable to track (this is why it is complete where the rung-1/2/3
apparatus and the NG2 record-then-judge idea were fragile).

## 3. Soundness and completeness (verified — see §8)

<challenge id="C1" summary="Is scoped rigidity sound (no valid program rejected)?">
Rigid `E` clashes only when the body forces `E`'s slot to a non-polymorphic row —
which happens only if the body PERFORMED the trapped effect (or genuinely committed
that slot to a concrete/empty row, i.e. over-promised polymorphism the way `f : a; f = 5`
does). A function that merely HOLDS a trapped capability without performing it keeps the
slot a flexible var (`E ~ β` binds fine) and is accepted (verified: `cancel`,
ignore-arg, phantom-hold).
</challenge>
<response to="C1" status="resolved">
This makes a trapped effect var behave EXACTLY like an ordinary rigid TYPE var under
the "you promised polymorphism, deliver it" discipline the language already enforces —
completing an asymmetry (`Unify.hs`: "skolems are KStar-only today"), not adding a
special case. Empirically zero false positives across 48 adversarial cases + 51 accept
fixtures + 104 run examples + full prelude.
</response>

<challenge id="C2" summary="Is it complete (every leak caught)?">
Performing a trapped polymorphic residual necessarily collapses the SAME variable
(unification identity) that the signature's trapped slot reconciles against, so the
clash fires. Verified against every performer (`run`/`step`/`start`/`parBoth`/`drainOne`/
`race`/`runRace`), data-wrapper/tuple/list threading, higher-order indirection, helper
routing, mutual recursion, where-locals, and named-effect coexistence.
</challenge>
<response to="C2" status="resolved">
Zero missed leaks across the full corpus + 48 adversarial cases (§8). The
two-distinct-channel case (`leak-two-rows-masked`: trapped `e` performed, only a
different var `f` declared) is correctly rejected — per-variable rigidity does not
conflate distinct channels.
</response>

<challenge id="C5" summary="Could a closed-sig function legitimately perform a polymorphic residual it discharges?">
Same as the predecessor C5.
</challenge>
<response to="C5" status="resolved">
No. Discharging an effect requires a handler, and you cannot write a handler for an
unknown polymorphic var. So a trapped-and-performed var is ALWAYS a genuine leak. A
concrete effect the function fully handles never reaches the wall (the handler discharges
it), and rides the normal `emitEffect` path, not the trapped-var path.
</response>

## 4. What gets deleted (§4 of the predecessor, now unblocked)

With scoped rigidity landing the catch at reconciliation, the entire rung-1/2/3
structural apparatus is removed:

- `Infer.hs`: `emitResidualTail`, `callerRootRefs`, `reprRowRef`, the `emitRow`
  `TVar`/`KEffect` residual arm (revert to `_ -> pure ()`), the checking-mode
  `inferExprWChecked` ELam root logic + `peelLamArrows` + the `inferNormalApp` beta-redex
  special-case, the `typeEquationWith` seed root/underClosed/lambda-param installs, and
  the `inferProgramTC` pending-residual drain.
- `Monad.hs`: `ctxCallerResidualRoots`, `ctxUnderClosedEqn`, `ctxLambdaParams`,
  `ctxPendingResiduals` and every accessor; the `TCCtx` constructor in `runTC` shrinks.
- `isRowClosed`/`rowTerminal`/`peelLamArrows`/`RowRef`: delete if unused after the above
  (Q2).

<decision id="D2">
Remove the C1 prototype scaffolding: the `rigidKEffectSkolems` switch (`Infer.hs:358`)
and the `emitResidualTail _ _ | rigidKEffectSkolems = pure ()` gate (`Infer.hs:3104`)
disappear when the apparatus is deleted — the scoped-rigid arm becomes unconditional.
</decision>

## 5. Diagnostic (C3/Q1)

<decision id="D3">
Map the trapped-skolem reconciliation failure to a POSITIONED laundering error. In
`finalizeGroup`/`finalizeGroupTyped`, wrap the reconciliation `unify Nothing declT tv`
(`Infer.hs:3540`/`3603`) in a `catchError` that, on a `RigidEscape` for a skolem minted
from a TRAPPED KEffect var of THIS signature, rethrows as `UndischargedEffect <defnSpan>
"e"` — reusing the existing variant so the death-test goldens stay stable in shape, and
anchoring the position at the binding's definition site (thread the equation/decl span,
currently `Nothing`, into the reconciliation). Non-trapped rigid escapes (KStar
over-promises) keep their existing `RigidEscape` message.
</decision>

## 6. Subsumption + test reclassification (the one real interaction)

Scoped rigidity is STRICTER than the old apparatus: it correctly rejects 6 existing
death tests that were written to isolate OTHER checks but that genuinely ALSO leak a
trapped effect — `future-recursive-consume`, `future-await-twice`,
`future-helper-double-consume`, `future-resume-then-cancel` (intended:
`FutureConsumedTwice`), `future-reperform-unhandled`, `conc-producer-capture` (intended:
`CarrierEscape`). RigidEscape fires first and masks the intended error.

<decision id="D4">
Reclassify each of the 6 to ISOLATE its original bug by giving it a `with eff e` channel
so it no longer leaks (e.g. `bad : Step … (row e) -> U64 with eff e`), restoring the
intended `FutureConsumedTwice`/`CarrierEscape`. VERIFIED: adding `with eff e` to
`future-await-twice` restores `FutureConsumedTwice (Just (7,1)) "g"`. Keep the leaking
forms too, as NEW laundering death tests, so coverage of both dimensions grows.
</decision>

## 7. Assumptions and boundaries

<assumption id="AS1">The `dischargeableRowVars` polarity walk approximates user-datatype
field variance as covariant (`pos`/`neg` recurse into `CTCon` args with the SAME
polarity). This is EXACT for the current language: effect vars only ever appear as an
arrow effect-row tail or as a bare `(row e)` type-arg of `Suspension`/`Step`; a bare
type-arg is collected in NEITHER polarity, so it defaults to TRAPPED (the SOUND
direction). Adversarially confirmed user data cons cannot hold `with eff e` arrows, so
the approximation is unreachable-by-exploit. Revisit only if effect vars become
expressible in contravariant datatype fields.</assumption>

<assumption id="AS2">Rank-1 effect polymorphism. Higher-rank effect quantification (effect
vars quantified inside argument types) is not a current wok feature; the trapped/polarity
analysis assumes a rank-1 signature. Revisit if the language grows higher-rank effects.</assumption>

<assumption id="AS3">The launder death-test corpus + the §8 adversarial battery fully
characterize the laundering surface, so "all death tests still reject + zero adversarial
counterexamples" is a sufficient subsumption proof.</assumption>

## 8. Verification already performed (C1 + harder pass)

- 9 reproducers (A-1/FP-1/PROBE-2 accept; FN-1/2/3/4/A-2/PROBE-1 reject): ALL correct.
- 14 launder death tests: all reject.
- Full suite (2135 tests): ZERO verdict regressions; 27 golden-TEXT churn only (21
  death-test error-text -> RigidEscape; 5 typed-ANF cosmetic var renumbering; handled by
  D3 + golden regen).
- typecheck-examples 51/51 accept; typecheck-fail-examples 105/105 reject; run-examples
  104/104 typecheck; prelude compiles.
- Adversarial: 16 hand-built + 32 independent-subagent cases = ZERO false positives, ZERO
  missed leaks, including the polarity boundary (AS1) and named/two-effect coexistence.

## 9. Regression bar (ship gate)

1. All existing rung-1/2/3 launder death tests still REJECT, now via the D3 diagnostic.
2. NEW reject fixtures: FN-1, FN-2, FN-3, FN-4, A-2 (false negatives closed) + the 6
   leaking forms of the reclassified tests (D4).
3. NEW accept fixtures: A-1, FP-1, PROBE-2 (false positives removed).
4. The full accept-corpus + prelude stays accepting.
5. The 6 reclassified tests (D4) reject via their ORIGINAL error (FutureConsumedTwice /
   CarrierEscape), proving those analyses are still guarded.
6. Q3 fixtures: a two-different-named-effect accept AND a leak variant.
7. Full 2135-suite green after golden regen; `hlint` clean (ignore `src-generated`).

## 10. Open questions

<open_question id="Q1">Exact defn-span threading for D3: `finalizeGroup` has the binding
name but the span source is the equation/`TypedDecl`; confirm the cleanest span to
thread. Resolve during D3 implementation.</open_question>

<open_question id="Q2">Delete vs retain `isRowClosed`/`rowTerminal`/`peelLamArrows`/
`RowRef` after §4. Decide during the deletion task (grep for residual uses).</open_question>

## 11. Execution sketch (for the plan)

1. **Make scoped-rigid permanent** [frontier] — the `dischargeableRowVars` classifier +
   the trapped-only rigid arm become unconditional; remove the switch. (Prototype code
   already exists; this is finalization.)
2. **Diagnostic mapping (D3)** [standard] — positioned `UndischargedEffect` for trapped
   escapes; thread the defn span.
3. **Delete the apparatus (§4)** [frontier] — remove rung-1/2/3 structural code +
   `Monad.hs` fields + prototype gate; AS3 grep for dangling refs; build green.
4. **Reclassify + author tests (D4, §9)** [standard] — add `with eff e` to the 6 subsumed
   tests; move FN-1/2/3/4/A-2 to fail-examples; add A-1/FP-1/PROBE-2 to examples; add the
   6 leaking forms + Q3 fixtures; regenerate all goldens.
5. **Full-branch review + merge** [frontier] — whole-branch adversarial review with
   runnable reproducers + test-soundness pass, then user `/code-review`, then merge per
   the CLAUDE.md workflow.

## 12. Deferred follow-ups (from the whole-branch review, 2026-07-04)

The load-bearing whole-branch review (FEAT-vs-MAIN differential) returned **SHIP**:
zero regressions, zero false positives, +21 leak classes newly caught, sound tests.
Two accepted leaks remain; BOTH accept on main too (not regressions) and are OUTSIDE
this spec's scope (signature-parameter trapped vars). Filed as follow-ups:

<open_question id="F1">**User-data-wrapped carrier (non-transitive classifier).**
`effectRelevantRowVars` flags a row var effect-relevant only when a MARKED CARRIER tycon
appears SYNTACTICALLY in the signature. A user data type that parameterizes over `(row e)`
and wraps a carrier internally hides the residual: `data WS (row e) = WS (Step .. (row e))`;
`runW : WS (row e) -> U64; runW w = case w of WS s -> drainOne s` drives the carrier under a
closed sig and LEAKS (accepts; `--run` -> NoMatchingHandler). The UNWRAPPED control
(`runW : Step .. (row e) -> U64`) is correctly rejected — the wrapper is what launders it.
Option-wrapping IS caught (carrier syntactically visible as Option's arg); only opaque
user-data wrapping hides it. A fix would descend into constructor field types (env) to
propagate carrier-ness transitively, with cycle detection and its own false-positive
analysis (a data type holding a carrier as inert storage) — a separate slice. Adjacent to
the new classifier; the top follow-up.</open_question>

<open_question id="F2" status="resolved-2026-07-05">**Concrete residual from a local
`start` — RESOLVED: it was the 0-arg binding bypass.** The original attribution
("the open tail dropped by `emitRow`") was WRONG: the identical body as a
ONE-parameter function was already rejected (`UndischargedEffect Log`); only the
0-arg form leaked, because `typeEquationWith`'s zero-parameter top-level branch
seeded a fresh open ambient that was closed but never reconciled — top-level
values (`main` included) bypassed the effect discipline entirely (a plain
`bad : U64; bad = let v = Log.emit 1 in 2` typechecked and crashed). FIXED
(2026-07-05): the 0-arg top-level ambient is now the closed ENTRY row `{IO}`
(ground IO is discharged by running the program, never by a handler; every other
effect rejects at the emit site). Death tests `caf-effect-bypass` +
`caf-local-start-residual`; plan
`docs/superpowers/2026-07-05-effect-safety-holes-fix-plan.md` (H1).</open_question>

<open_question id="F3">**Staged perform — channel below the activation depth
(2026-07-05 pressure-test; OPEN).** The classifier is per-signature, not
per-arrow: `mk : Suspension U64 U64 U64 (row e) -> U64 -> U64 with eff e;
mk g = let r = run g 0 in \ x -> r + x` ACCEPTS — `e` counts as dischargeable
via the INNER arrow's channel, but the body performs it at the one-argument
activation whose row is closed. The concrete analogue is correctly rejected, so
polymorphic and concrete effects disagree about staging. Dynamically backstopped
today (eager `start` demands the residual at its own site; second-class carriers
keep resumes inside the discharging handler — verified: the exploiting caller is
rejected at the `start` site, the under-handler form runs correctly), so this is
a type-honesty hole of the F1 class, not a crash. Candidate fix: depth-indexed
dischargeability (a spine eff-tail is a channel iff at arrow depth == equation
arity, where `effRowAtDepth` already reads the ambient seed); the honest forms
`mkOk g x = run g x` and `mk g = \ x -> run g x` stay accepting (the returned
lambda's row reconciles separately). Needs a C1-style prototype gate. Plan:
`docs/superpowers/2026-07-05-effect-safety-holes-fix-plan.md` (H2/Phase B).</open_question>
