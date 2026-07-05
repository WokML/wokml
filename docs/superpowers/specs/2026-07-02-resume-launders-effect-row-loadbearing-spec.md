# Resume-launders-effects slice — make the residual effect row load-bearing (Option B)

> **SUPERSEDED END-STATE (added 2026-07-05).** The rung-1/2/3 emitter/provenance
> apparatus this epic built was DELETED (2026-07-03) and replaced by scoped rigid
> skolemization of trapped effect vars — see
> `2026-07-03-rung3-rework-scoped-rigid-trapped-effect-skolemization-spec.md`.
> This doc is retained as design history (problem statement + rung-1 scope).

Status: **IMPLEMENTED as RUNG 1 (2026-07-02)** — scope narrower than this spec
originally claimed; see the boldface Scope-Reality note below. Direction LOCKED.
Supersedes the GIST (`…-loadbearing-GIST.md`). Two open questions resolved by the
user (see §11).

> **SCOPE REALITY (added post-implementation).** This spec's original framing —
> "one localized emitter change closes the hole" (§3, §4) — was **empirically
> disproved during review** and is CORRECTED here. The single emitter change closes
> the hole only for the positions where the residual reaches the enclosing declared
> ambient DIRECTLY: top-level resume driver bodies (`drive g = run g 0`) and resume
> calls hosted in handler ARM bodies. Residuals routed through a handler's
> sub-ambient DISCHARGE site still launder — three positions remain open
> (handled-expression, nested handlers, runner-sugar), because effect-row variables
> carry no provenance to distinguish a benign handler leftover from a laundered
> obligation. Those are RUNG 2:
> `docs/superpowers/specs/2026-07-02-resume-launders-rung2-provenance.md`. A
> separate, pre-existing lambda-laundering hole is noted in
> `docs/superpowers/2026-07-02-lambda-effect-laundering-note.md`. What shipped is
> SOUND (it only adds rejections; the remaining leaks pre-date this slice), just
> narrower than "resume laundering — closed." Read §3/§4/§7 below as
> **rung-1 scope**, bounded by this note.

Provenance / locked precursors:
- Architecture: `2026-06-11-resume-site-control-and-heap-continuations-design.md`
  (§3 "The load-bearing row", §4).
- Write-vs-infer decision: `2026-07-02-resume-launders-effect-row-explicitness-decision.md`
  (EXPLICIT, not inferred).
- Explainer: `docs/effect-handlers-explainer.html` item 1 (+ §1a).
- Memory: `[[explicit-resume-effect-laundering]]`, `[[conc-phantom-residual-fix]]`,
  `[[handler-block-var-and-block-scope]]`.

---

## 1. Problem

wok's sole effect-safety net is the **declaration-site check**: performing an
effect you did not declare is a compile error (`UndischargedEffect`), and the
effect propagates up to `main` (typed pure), the de-facto boundary. There is no
separate entry/`main` discharge gate.

That net has exactly one hole. When a function performs a **bare row variable**
`e` — which is what a generic resume/step/run/await driver does when it resumes a
coroutine whose residual effects are the polymorphic tail `(row e)` — the row
variable carries no concrete effect labels, so it is silently **absorbed** into
the caller's type scheme instead of obligating the caller's declared row. The
canonical case:

```
replay : Suspension U64 U64 U64 (row e) -> U64     -- NO `with eff e`
replay g = run g 0                                  -- performs the tail's effects e
```

`run : Suspension a b r (row e) -> b -> r with eff e` genuinely performs `e`, yet
`replay` type-checks as effect-polymorphic (`forall a. Suspension … a -> U64`).
**The type lies:** a generic resume driver hides the resumed tail's effects from
its own signature. This is sound *today* (eager `start` demands the full residual
at the lifecycle root, and second-class carriers keep every resume dynamically
inside that scope), but it is an effect-laundering hole in the type surface and
blocks a sound EXPLICIT layer-3 scheduler (a scheduler is the ultimate generic
resume driver).

## 2. Goal — the uniform law

Extend the existing declaration-site discipline to its one loophole: **performing
a residual effect row `e` — even a bare row variable — obligates the enclosing
function's declared effect row.** After the slice:

> Every effect you perform — concrete OR polymorphic — must appear in your
> signature. One rule, no "is this the inferred case or the pure case?" ambiguity.

So `replay` must be written `replay : … -> U64 with eff e`, and a scheduler's
`runNext : Queue (row e) -> () with eff e` can no longer claim purity while
running effectful tasks.

## 3. Scope & non-goals

**In scope:** a type-checker change that makes a leftover bare residual row
variable obligate the enclosing declared row, plus the test-suite fallout and one
new death test.

**Type-only, no runtime change.** See §6 for the airtight argument. The prelude
drivers already declare `with eff e` honestly; this slice makes the checker
*enforce* that callers must too.

**Unbundled from first-class carriers.** This **overrides** the design doc's own
timing (§3/§8: "redundant under second-class today … lands together with
first-class carriers"). The supersession is deliberate, sourced from memory
`[[handler-block-var-and-block-scope]]` ("the honest-types fix stands alone") and
echoed by the explainer's "self-contained type-only slice." The full spec does not
re-litigate it: the honest-types fix needs no heap stacklets and no carrier trio.

**Non-goals (explicitly out):**
- No effect inference (missing `with` stays = pure = compile error).
- No `with eff _` opt-in placeholder (designed, DEFERRED to a non-breaking
  fast-follow; add only if this audit shows real verbosity pain).
- No before/after-suspend row split (Option C — coro-specific, rejected).
- No first-class carriers, no scheduler capability, no `runConc` widening.
- No new error variant — reuse `UndischargedEffect` (user decision, §11).

## 4. Design — recording + deferred verdict

The naive design ("make `emitRow`'s catch-all throw") is **wrong** because of
error-ordering (§5): `emitRow` fires during body inference, which runs *before*
the multiplicity/carrier post-passes, so an eager throw would preempt
`FutureConsumedTwice`/`CarrierEscape`. The user chose "residual check runs after
multiplicity." Therefore the obligation is a **deferred per-module check**:

### 4.1 Recording (during inference)

Modify `emitRow`'s open-tail catch-all (`Infer.hs:2932-2939`). When the callee's
performed row forces to an **unbound `KEffect` row variable** (a bare residual
tail), inspect the current ambient (the enclosing definition's effect row, read
from the `withEffRow` `effRef`, as `emitEffect` already does at `Infer.hs:2903`):

- **Ambient is OPEN** (sig declared `with eff e` / `+ eff e`, or a still-open
  inferred row): **unify** the residual tail into the ambient's open tail. The
  obligation is satisfied — the residual flows into the declared row exactly as a
  concrete label would. No pending record. (Row unification already handles this,
  `Unify.hs:226-320`.)
- **Ambient is CLOSED** (`CREmpty` — a no-`with` sig, per `Infer.hs:561`
  `TFun → CTArr … CREmpty …`; or an explicitly closed row): **record** a pending
  obligation `(span, defName, residualDescription)` into a new per-module
  accumulator in TC state. Do **NOT** throw here, and do **NOT** unify (leaving
  the decision to the post-pass; recording the verdict-at-emit avoids depending on
  row-var state that `closeRow` later mutates).

Recording (not throwing) is what lets inference of every definition complete so
the post-passes can run first. Recording happens inside `emitRow`, which is
invoked before the per-application `closeRow` at `Infer.hs:2394` and before the
definition-level `closeRow` at `Infer.hs:3571`, so the ambient's open/closed
status is read while still accurate.

### 4.2 Verdict (new post-pass, after multiplicity)

Add a fourth module-level post-pass in `inferProgramWith`, **after**
`checkFutureAffine` (`Infer.hs:3842-3844`) and thus after `checkCarriers`
(`Infer.hs:3823-3831`): if any pending residual obligations were recorded, throw
the first as `UndischargedEffect span label`. Because `checkCarriers` /
`checkFutureAffine` run first and short-circuit on their first offending
definition, any multiplicity/carrier error in the module preempts any residual
error — satisfying "multiplicity wins" (§5).

### 4.3 Why this is still localized

Two edits plus a scrap of state:
1. `emitRow` catch-all: decide open→unify / closed→record. (`Infer.hs:2932-2939`)
2. A new `pendingResidual :: STRef s [(SourceSpan, Text)]` (or equivalent) in the
   TC state (`TypeChecking/Monad.hs`), appended in (1).
3. A new post-pass reading it after `Infer.hs:3844`, throwing `UndischargedEffect`.

No IR node, no grammar, no runtime, no new error constructor.

## 5. Error-ordering with the multiplicity/carrier checks

User decision: **run the residual check after multiplicity checks; reuse
`UndischargedEffect`.** Rationale and mechanism:

- `checkCarriers` (raises `CarrierEscape`, `FutureConsumedTwice` —
  `Carrier.hs:107,688,739`) and `checkFutureAffine` are **module-level
  post-passes** at `Infer.hs:3823-3844`, running after all body inference.
- The residual verdict (§4.2) is a NEW post-pass sequenced *after* those. So for a
  definition that violates BOTH (e.g. `future-recursive-consume`'s `loop`, which
  both consumes a Future twice AND performs an undeclared residual), the existing
  `FutureConsumedTwice` fires first and its golden is preserved unchanged.
- Granularity is module-wide (any multiplicity error anywhere preempts any
  residual error anywhere) — simpler and predictable, and sufficient for the
  fail-example set.

## 6. Compile-time guarantee (no runtime change)

The strongest claim, verified against source:

1. **All checks live in the type checker.** `emitRow`, `emitEffect`, `closeRow`,
   `dischargeEffects` (`TypeChecking/Infer.hs`), `checkCarriers`,
   `checkFutureAffine` (`TypeChecking/Carrier.hs`), invoked by `inferProgramWith`
   → `typecheckProgram` (`Pipeline.hs`). **Zero** of these are referenced anywhere
   under `src/Wok/Interp/` (grep = 0).
2. **The interpreter never inspects effect rows.** `e` is a phantom type
   parameter at runtime (matches `[[conc-phantom-residual-fix]]`: "the `(row e)`
   on Step is phantom"). No `RowExtend`/`RowEmpty`/`KEffect` logic in `Interp/`.
3. **Option B only ADDS type-check rejections.** It rejects strictly more
   programs; it changes nothing about *how* an accepted program elaborates. Effect
   rows on arrows are erased to `CREmpty` at elaboration (`Anf.hs`; rows survive
   only as phantom type *arguments*, never inspected). Therefore any program that
   still type-checks after the slice elaborates to byte-identical Core/ANF —
   concretely proven by the `run-golden/coro-step-{range,zip}.expected` staying
   unchanged after their signatures gain `with eff e`.

Conclusion: the slice is type-only. The interpreter, ANF, elaboration, Perceus,
and codegen are untouched.

## 7. Blast radius & migration

**Prelude: 0 signature changes.** `run`/`step`/`start`/`drainOne`/`parBoth`/
`asCoro`/`par`/`race` in `prelude/Std/Control.wok:74,78,85,109,114,140,146,171`
already declare `with eff e`; `runConc`/`__drive_conc` (`:231,251`) are already
tightened (conc-phantom fix). Nothing to migrate.

**Tests that FLIP pass → add `with eff e` (3, + goldens):**
| File | Fix | Goldens |
|------|-----|---------|
| `typecheck-examples/coro-resume-driver.wok` (`replay`) — the CONSCIOUS marker | add `with eff e` | regen `typecheck-golden/`, `anf-golden/`, `typed-anf-golden/coro-resume-driver.expected` (scheme now carries residual) |
| `run-examples/coro-step-range.wok` (`sumGen`) | add `with eff e` | `run-golden/coro-step-range.expected` UNCHANGED (still runs to same result — residual unifies empty at `main`) |
| `run-examples/coro-step-zip.wok` (`zipSum`) | add `with eff e` | `run-golden/coro-step-zip.expected` UNCHANGED |

**Fail-examples — two sets:**
- **5 exercise the resume-obligation path** (call `run`/`step` on a residual
  `(row e)`); already fail, and per §5 keep their existing first-error. Verify
  each still rejects for its original reason; regen a golden ONLY if the
  first-fired error legitimately changes (should not, given §5):
  `future-recursive-consume`, `future-resume-then-cancel`, `future-await-twice`,
  `future-helper-double-consume`, `conc-producer-capture`.
- **2 must stay UNAFFECTED** (no bare polymorphic residual is ever performed):
  `future-reperform-unhandled` (`main = start producer`; producer's row is closed,
  `start`'s `e` unifies empty) and `producer-thunk-userfile` (no `run`/`step`/
  `start` call). Their `CarrierEscape` goldens must NOT change — any change is a
  red flag, not an expected regen.

**No other consumers.** Swept `rc-*`, `multiplicity-*`, `examples/`, `golden/`;
spot-confirmed `coro-residual-handled.wok` (residual resolves to `Log`, discharged
inside `with Log {…}`) and `conc-carrier-transport-rejected.wok` (`feed` already
declares `with eff e`) as correctly unaffected.

## 8. New test — the death test (proves the hole is closed)

Add a `typecheck-fail-examples/` case (+ `typecheck-fail-golden/`): a resume
driver that OMITS `with eff e` while calling `run`/`step` on a `(row e)`
suspension, with NO other error present (so the residual check is what fires).
Pre-slice it type-checks (the laundering hole); post-slice it must fail with
`UndischargedEffect`. Suggested shape:

```
module Main
import Std.Base
import Std.Control
-- resume driver that performs the parked tail's effects but declares none.
-- Post-slice: rejected with UndischargedEffect (the load-bearing row).
drive : Suspension U64 U64 U64 (row e) -> U64      -- MISSING `with eff e`
drive g = run g 0
main : U64
main = 0
```

Positive coverage is already provided by `coro-step-{range,zip}` (declare
`with eff e`, still run) and `coro-resume-driver` (declared form type-checks).

## 9. Error identity & message

Reuse `UndischargedEffect SourceSpan Text` (`Error.hs`) — user decision. The
`Text` payload should identify the laundered residual (the row-variable name, e.g.
`"e"`, or a residual descriptor) so the message reads consistently with the
concrete-label case. TCErrors render via derived `Show`; no prose pretty-printer
is added.

## 10. Risks & implementation caveats

- **`closeRow` interaction (flagged by the emitter mapping).** `inferNormalApp`
  calls `closeRow effRow` at `Infer.hs:2394` and `typeEquationWith` at
  `Infer.hs:3571`; static reading could not fully reconcile why the residual tail
  is generalized despite these closures (the golden is authoritative: it IS
  absorbed today). The recording-at-emit design (§4.1) sidesteps this by deciding
  the verdict while the ambient is still accurate, rather than reconstructing it
  after `closeRow`. The implementer must still confirm empirically that recording
  fires at the right moment (before any `closeRow` mutates the ambient) — this is
  why the emitter task is **frontier**.
- **Open-inferred ambient (no sig).** A binding with no signature starts with an
  open inferred row (`freshRVar`); a performed residual should unify into it and
  be reflected in the inferred scheme — i.e. inference still works, the residual
  just becomes part of the inferred effect row. Confirm a no-sig driver infers
  `with eff e` rather than being rejected.
- **False positives.** Ensure a residual that IS covered (ambient open, or the
  callee's row already resolved to concrete handled labels) never records a
  pending obligation — guard on "forces to an unbound `KEffect` var" precisely.

## 11. User decisions (resolved)

1. **Error identity:** reuse `UndischargedEffect` (no new variant). [RESOLVED]
2. **Error-ordering:** residual check runs AFTER the multiplicity/carrier checks;
   multiplicity errors win. [RESOLVED]
3. `with eff _` opt-in stays DEFERRED. [RESOLVED]

## 12. Task breakdown preview (for the Phase-5 plan)

- **T1 (frontier):** `emitRow` recording + TC-state accumulator + post-pass
  verdict; the type-system core. Judgment required (the `closeRow` caveat).
- **T2 (mechanical):** migrate the 3 flipping `.wok` (add `with eff e`) + regen
  the 3 `coro-resume-driver` goldens; confirm the 2 run-goldens unchanged.
- **T3 (mechanical):** add the death test + its `typecheck-fail-golden`.
- **T4 (standard):** error-ordering triage over the 5 driver-calling
  fail-examples; regen goldens only where §5 legitimately changes the first error;
  assert the 2 unaffected files are byte-identical.
- **Reviewers (standard):** per-task spec + code-quality. **Final (session
  model):** whole-branch deep review + `/code-review` high, test-soundness on Opus.

## 13. Success criteria

- The death test (§8) is rejected with `UndischargedEffect`; pre-slice it passed.
- `coro-resume-driver` golden consciously flips to carry the residual.
- `coro-step-{range,zip}` run-goldens unchanged (compile-time-only proof).
- The 5 driver fail-examples keep their original first-error (multiplicity wins).
- The 2 unaffected fail-examples are byte-identical.
- Full suite green; `hlint` clean (excluding `src-generated`); ASan not required
  (no runtime touch).

## 14. References

- `src/Wok/TypeChecking/Infer.hs`: `emitRow` (2932-2939), `emitEffect` (2893-2913),
  `dischargeEffects` (2830-2837), handler residual re-emit (2681-2682),
  `inferNormalApp` (2384-2394), `typeEquationWith` (3540-3572), `closeRow`
  (3593-3601), `TFun→CREmpty` (561), carrier post-passes (3823-3844),
  `freezeQuantify` KEffect generalization (185-190).
- `src/Wok/TypeChecking/Carrier.hs`: `checkCarriers`/`checkFutureAffine`
  (107, 688, 739). `src/Wok/TypeChecking/Types.hs`: row rep (69-96).
  `src/Wok/TypeChecking/Unify.hs`: row unify (143-171, 226-320).
  `src/Wok/TypeChecking/Error.hs`: `UndischargedEffect` (~161-175).
- `prelude/Std/Control.wok`: driver signatures (74-171, 231, 251).
