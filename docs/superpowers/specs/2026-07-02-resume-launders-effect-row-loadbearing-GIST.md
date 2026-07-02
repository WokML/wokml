# Resume-launders-effects slice — SPEC GIST (outline, not the full spec)

Status: **GIST / for steering** (2026-07-02). Direction LOCKED (Option B, explicit).
Precursors: `2026-06-11-resume-site-control-and-heap-continuations-design.md` (§3 the
load-bearing row), `2026-07-02-resume-launders-effect-row-explicitness-decision.md`
(write-vs-infer = explicit), explainer `docs/effect-handlers-explainer.html` §5-7.
Memory: [[explicit-resume-effect-laundering]], [[conc-phantom-residual-fix]],
[[handler-block-var-and-block-scope]].

## 1. One-liner

Make the residual effect row **load-bearing**: performing a bare row variable `e`
(as a resume/step/run/await driver does) must **obligate** the enclosing function
to declare `with eff e`, instead of the row variable being silently absorbed into
the caller's scheme. This closes the "resume launders effects" type hole so a
generic resume driver can no longer claim purity while running effectful tails.

Uniform law after the slice: **every effect you perform — concrete OR polymorphic
— must appear in your signature.** One rule, no "is this the inferred or the pure
case?" ambiguity.

## 2. Scope

- **Type-only.** No runtime / Perceus / interpreter / IR change. The prelude
  drivers already declare `with eff e` honestly; this slice makes the type checker
  *enforce* that callers must too.
- **Unbundled from first-class carriers** (the June §5 runtime plan). The
  honest-types fix stands alone — it does not need heap stacklets or the carrier
  trio. NOTE: this **overrides** the design doc's own stated timing
  (`2026-06-11-…-design.md` §3/§8: "the row is redundant under second-class
  today … lands together with first-class carriers"). The supersession is
  deliberate, sourced from memory `[[handler-block-var-and-block-scope]]`
  ("Unbundle it from the June runtime plan — the honest-types fix stands alone")
  and echoed by the explainer's "self-contained type-only slice" framing. The
  full spec should not re-litigate this.

### Non-goals (explicitly out)

- No effect inference (explicit decided; missing `with` = pure = compile error).
- No `with eff _` opt-in placeholder (designed, DEFERRED to a non-breaking
  fast-follow — add only if the audit shows real verbosity pain).
- No before/after-suspend row split (Option C — coro-specific, rejected).
- No first-class carriers, no scheduler capability change.

## 3. The change (single site)

The emitter step in `src/Wok/TypeChecking/Infer.hs`: a **leftover bare row
variable** in a callee's performed row must be made to obligate the enclosing
function's declared row (unify it into the ambient / raise `UndischargedEffect`
if the ambient is closed), exactly as a leftover concrete effect label already
does. Stop the path that lets a leftover row variable get generalized into the
caller's scheme for free.

### PRECISE CHANGE SITE (from emitter mapping)

The loophole is a **two-place cooperation**, but there is a single primary edit:

- **PRIMARY — `emitRow` catch-all, `Infer.hs:2932-2939`.** A callee's effect row
  is fed to the ambient one concrete label at a time via `emitEffect`. When the
  callee's performed row is a **bare row variable** (an open tail), `emitRow`
  hits its `_` catch-all and returns `pure ()` — it never calls `emitEffect`, so
  it never reaches the closed-ambient check that throws `UndischargedEffect`.
  THE fix: when the forced tail is an unbound `KEffect` `TVar`, obligate the
  enclosing ambient (unify the tail into the ambient / require the ambient to
  carry a matching open tail) instead of silently returning.
- **Coordinate with:** `inferNormalApp` (the per-application call to `emitRow`
  then `closeRow`, `Infer.hs:2384-2394`) and the handler residual re-emit
  (`Infer.hs:2681-2682`). The rejection itself already exists in `emitEffect`'s
  closed-ambient branch (`Infer.hs:2911-2913`); the change just routes the bare
  tail there.
- **SECONDARY (consequence, no separate edit expected):** once the tail is no
  longer dropped, it stops surviving as an unbound `KEffect` metavar that
  `freezeQuantify` generalizes into the scheme (`Infer.hs:185-190`) — which is
  what currently prints `replay : forall a. Suspension U64 U64 U64 a -> U64`.
- **IMPLEMENTATION CAVEAT (flagged by the mapping, verify empirically):**
  `inferNormalApp` already calls `closeRow effRow` at `Infer.hs:2394`, which
  writes `Link RowEmpty` into a bare tail. Static reading could not fully
  reconcile why the tail is nonetheless generalized (the golden is authoritative:
  it IS absorbed). So the implementer must confirm at which point the tail
  escapes closure and intercept `emitRow` *before* generalization — not assume
  the static story. This is why the emitter edit is a **frontier** task.

Effect-row representation: a `Row s = Type s` of kind `KEffect`
(`Types.hs:69-96`); **closed** ends in `RowEmpty`, **open** ends in a `TVar` cell
of `Kind KEffect` (the row-variable tail). Row unification of a bare row var just
links the two tail vars (`Unify.hs:226-320`) — no label to bubble, which is
exactly why `emitRow` short-circuits today.

Design anchor (design doc §3): "performing a residual row `e` — even a bare row
variable — must obligate the enclosing function's effect row to be `>= e` (stop
silently absorbing bare row variables; treat the residual exactly like any other
effect row, which the existing sound row-unification already handles)."

## 4. Blast radius (from the audit scan)

- **Prelude: 0 signature changes.** `run`/`step`/`start`/`par`/`race`/`asCoro`/…
  in `prelude/Std/Control.wok` already carry `with eff e`. `runConc`/`__drive_conc`
  are already tightened (conc-phantom-residual-fix). Nothing to migrate.
- **Emitter: 1 site** (above).
- **Tests that FLIP pass -> need `with eff e` added (3 + goldens):**
  - `test/typecheck-examples/coro-resume-driver.wok` — the CONSCIOUS marker
    (`replay g = run g 0`). Goldens: `typecheck-golden/`, `anf-golden/`,
    `typed-anf-golden/coro-resume-driver.expected` all regen (scheme now carries
    the residual).
  - `test/run-examples/coro-step-range.wok` — `sumGen : Step … (row e) -> U64`
    calls `step`; add `with eff e`. `run-golden/coro-step-range.expected`
    UNCHANGED (still runs to same result — residual unifies empty at `main`).
  - `test/run-examples/coro-step-zip.wok` — `zipSum` calls `step`; add
    `with eff e`. `run-golden/coro-step-zip.expected` UNCHANGED.
- **Fail-examples: split into two sets (corrected after review).**
  - **5 exercise the resume-obligation path — review error-ordering.** These
    already fail (e.g. `FutureConsumedTwice`) but DO call `run`/`step` on a
    residual `(row e)`, so the new `UndischargedEffect` may now fire FIRST and
    change the golden message: `future-recursive-consume`,
    `future-resume-then-cancel`, `future-await-twice`,
    `future-helper-double-consume`, `conc-producer-capture`. Action: re-run,
    regen goldens where the first-fired error legitimately changes; confirm each
    still rejects for a sound reason.
  - **2 should stay UNAFFECTED** (no bare polymorphic residual is ever
    performed): `future-reperform-unhandled` (`main = start producer`; the
    producer's row is closed, `start`'s `e` unifies empty) and
    `producer-thunk-userfile` (no `run`/`step`/`start` call at all). Their
    `CarrierEscape` goldens should NOT change — treat any change as a red flag,
    not an expected regen.
- **No other consumers.** Swept `rc-*`, `multiplicity-*`, `examples/`, `golden/`,
  plus spot-confirmed `coro-residual-handled.wok` (residual resolves concretely to
  `Log`, fully discharged inside `with Log {…}`) and
  `conc-carrier-transport-rejected.wok` (`feed` already declares `with eff e`) as
  correctly unaffected — none launder.

## 5. New tests (the death test that proves the hole is closed)

- **NEW negative** (`typecheck-fail-examples/`): a resume driver that OMITS
  `with eff e` while calling `run`/`step` on a `(row e)` suspension is now REJECTED
  with `UndischargedEffect`. This is the load-bearing proof — pre-slice it
  type-checks (the laundering hole), post-slice it must fail.
- **Positive** already covered by `coro-step-range`/`coro-step-zip` (declare
  `with eff e`, still run) + `coro-resume-driver` (declared form type-checks).

## 6. Open questions for the reviewer / user

1. **Error identity/rendering:** reuse `UndischargedEffect` for a leftover bare
   row variable, or a distinct variant with a message that names the laundered
   residual? (Codebase renders TCErrors via derived Show.)
2. **Error-ordering** vs the multiplicity/carrier checks in the 5 driver-calling
   fail-examples — which error should win, and is regenning those goldens
   acceptable?
3. Confirm `with eff _` stays DEFERRED for this slice (yes per decision doc).

## 7. Phase plan (per CLAUDE.md workflow)

Gist (this) -> reviewer subagent checks alignment (Phase 3) -> gate on full spec
(Phase 4) -> resumable plan + per-task dispatch (Phase 5) -> lint + deep review +
`/code-review` high (Phase 6) -> handoff (Phase 7). Expected task tiers: the
emitter edit is **frontier** (type-system judgment); the prelude/test migration
and golden regen are **mechanical**; error-ordering triage is **standard**.
