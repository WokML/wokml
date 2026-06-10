# Slice 4b″ — residual-row `Suspension`/`Step` (on the kinded-Ty IR)

Date: 2026-06-10
Status: **Design converged** (brainstorming 2026-06-10). The implementable form of the 2026-06-09
4b″ sketch (`2026-06-09-slice-4b-dprime-residual-row-future-design.md`), re-grounded on the
kinded-Ty foundation now on `main`. That sketch's load-bearing PREREQUISITE — row-kinded type
parameters — is **DONE**: Slice A (kinded-Ty merge) + Slice B (`(row e)` row-kinded tycon params)
shipped exactly it. So 4b″ is no longer a kind-system slice; it is **threading a residual-row
parameter `e` through the coroutine prelude**, riding the Slice B facility, plus fixtures + golden
migration. Implementing session: writing-plans → subagent-driven-development. TDD. Full-branch review
before merge.

Reads with: `2026-06-09-slice-4b-dprime-residual-row-future-design.md` (the motivation/soundness gap),
`2026-06-10-slice-b-row-kinded-params-design.md` (the facility this consumes), memory
`kinded-ty-representation` (foundation + 4b″ backlog), `effects-slice-4b-one-shot-escape` /
`effects-slice-4c-step-adt` (the coroutine surface), `wok-constructor-naming-convention`.
Grounding code: `prelude/Std/Control.wok` (the surface to change), `src/Wok/Interp/Prim.hs`
(the `__coro_*` prims — UNCHANGED), `src/Wok/TypeChecking/Infer.hs` (effect-row printing, the
producer-exemption, handler elaboration).

## 1. Summary

Slice 4b shipped a one-shot escapable coroutine (`Suspension`/`Step`), but the types do NOT record
the **effect row the parked continuation performs on resume**. So `step`/`run` run the tail, which
re-performs effects, while the type system tracks nothing — and the "bounded handler escaped" case
(a handler live when the suspension was created but gone by resume time) **crashes a well-typed
program**. 4b″ row-indexes the coroutine types — `Suspension a b r e` / `Step a b r e`, where `e`
is the residual effect row — and threads `e` into `step`/`run`'s own effect row, so the **resume
site must handle `e`**. The crash becomes a compile-time type error, via the *existing* effect-row
discipline (no new analysis). Runtime is unchanged (`e` is phantom — effects erase).

## 2. The types (Slice B `(row e)` facility)

`prelude/Std/Control.wok`:

```wok
extern type Suspension a b r (row e)
extern data Step a b r (row e) = Completed r | Suspended a (Suspension a b r (row e))
```

`Suspension`/`Step` go from arity 3 to "3 + a row param". The `Suspended` field
`Suspension a b r (row e)` is a constructor field passing `(row e)` as a tycon argument — exactly
the Slice B field-tycon-application facility (binding-aware kind-check), already shipped. Same-name
constructors (`Completed`/`Suspended`) unchanged.

## 3. The operations + prims (thread `e`)

```wok
start  : (() -> r with Coro a b + eff e) -> Step a b r (row e) with eff e
step   : Suspension a b r (row e) -> b -> Step a b r (row e) with eff e
run    : Suspension a b r (row e) -> b -> r with eff e
cancel : Suspension a b r (row e) -> ()                       -- NO row (see §6)

extern __coro_susp   : a -> (b -> s with eff e) -> Step a b r (row e)   -- k performs e on resume
extern __coro_resume : Suspension a b r (row e) -> b -> Step a b r (row e) with eff e
extern __coro_unwrap : Step a b r (row e) -> r                          -- pure projection; partial (see §7)
extern __coro_done   : r -> Step a b r (row e)
extern __coro_cancel : Suspension a b r (row e) -> ()
```

The bodies of `start`/`step`/`run`/`cancel` are unchanged from 4c; only the *types* gain `e`. The
`__coro_*` prim **implementations in `Prim.hs` are untouched** — `e` is a phantom type parameter
(effects are erased at runtime; the VCon tags `Completed`/`Suspended` and the bare-continuation
representation are exactly as today).

**How `e` gets in.** `start`'s producer is `() -> r with Coro a b + eff e`: the `Coro` handler in
`start` discharges `Coro`; the producer's NON-`Coro` residual `e` (a) flows to `start`'s own row
(the *before-suspend* effects happen during `start`) AND (b) is captured into the `Step`/`Suspension`
via the prim signatures — the suspend arm's continuation `k : b -> Step a b r (row e) with eff e`
carries `e` (resuming runs the tail, which performs `e`). The `__coro_susp` slot keeps `k`'s answer
type decoupled (`b -> s`) so the suspend arm unifies without an occurs-check (as in 4c), now with `e`
on `k`'s row.

## 4. Why it closes the gap (no new analysis)

`step`/`run` carry `with eff e`. At a resume site `step g v : Step a b r e with eff e`, so `e` must
be handled there. If the handler that discharged `e` around `start` has returned (the bounded-escaped
case), `e` is unhandled at the resume site → it propagates to a closed/empty-row boundary → the
**existing** `RowMismatch` fires. The runtime crash becomes a type error, through the ordinary
effect-row discipline applied to the threaded signatures — **no new compiler analysis**. The "no
handler anywhere" case (already a type error in 4b) stays caught, now uniformly through the row.

## 5. Row printing (decided in brainstorming)

Render the residual row exactly as wok already renders an arrow's effect row — **the row variable and
any non-empty concrete row are SHOWN; only a concrete-EMPTY row is suppressed** (consistent with how
`a -> b` already drops its empty arrow row rather than printing `a -> b with {}`):

- polymorphic operations show the variable: `step : Suspension a b r e -> b -> Step a b r e with e`
  (the row param is visible as `e`);
- a concrete residual shows: `Step a b r {Log}`;
- a concrete *empty* residual is absent: a pure-tailed coroutine prints `Step a b r` (and `step …`'s
  result has no `with`) — meaning "resuming is pure", exactly like an effect-free `a -> b`.

This makes the feature visible (the `e` variable in signatures + the `with e` obligation on
`step`/`run`) without `{}`-noise, and it **minimizes golden churn** (pure-tailed coroutines keep
their current `Step a b r` rendering and don't move). Implements the "kind-aware scheme printing"
backlog item (a `KEffect` quantifier prints as a row var; the concrete-empty-row suppression matches
`prettyCType`'s existing empty-arrow-row rule).

## 6. `cancel` — no row, cannot fail (decided)

`cancel s = __coro_cancel s` discards the parked continuation **without resuming it** — the tail
never runs, so `e` never fires and nothing is allocated. So `cancel : Suspension a b r (row e) -> ()`
(no `with e`). This is the sound and useful signature: `cancel` is the escape hatch for a suspension
you *can't* resume (no live handler for `e`), precisely because cancelling performs `e`-nothing.
(When the deferred cancellation/finalizer runtime lands, a finalizer could perform effects → a
*finalizer* row; that is the failure-model slice's concern, not this one.)

## 7. `run`'s fail state (NOTED; deferred to the failure-model slice)

`run = __coro_unwrap (__coro_resume s v)` is **partial**: if the producer re-suspends instead of
completing, `__coro_unwrap` errors — today an unhandleable interpreter crash. **4b″ does NOT fix
this**, and that is intentional: the residual row `e` is about the tail's *effects*, not about
*completion vs re-suspension*, so `run : … -> r with e` reveals the effects but not the re-suspend
partiality. This re-suspend fail state is the **first item for the deferred failure-model slice**
(make `run` total via a re-suspend/totality guard, OR surface it via an `Abort` effect / a
`Result`-returning `run`), alongside other partial prims (division, non-exhaustive match). 4b″ leaves
`run`'s partiality exactly as documented in 4c, adding only the `with e` residual row.

## 8. Conservatism (intended)

`e` = the producer's **full** non-`Coro` residual row. You cannot statically split "effects before
the suspend" from "effects after it" (the suspend point is dynamic), so an effect that only ever
runs *before* the suspend is still required at the resume site. Sound; occasionally over-requires. A
precise before/after split would need control-flow analysis — out of scope.

## 9. Scope

**IN:** row-kinded `Suspension a b r (row e)` / `Step a b r (row e)` (Slice B facility); threading
`e` through `start`/`step`/`run`/`cancel` and the `__coro_*` prim signatures (impls untouched); the
resume-site `with e` obligation (falls out of the existing row discipline); the row-printing rule
(§5, suppress concrete-empty); fixtures (§11).

**OUT (deferred):** `run`'s totality / re-suspend fail state (failure-model slice, §7); the
cancellation/finalizer runtime; concrete-row type arguments (`Box {Log}`); precise before/after-
suspend row splitting (§8); first-class futures / `box`; the layer-3 scheduler.

## 10. Risk to front-load

The one real risk: whether `e` threads cleanly through the `Coro` handler's answer type and the
`__coro_*` prim signatures **without a compiler tweak** (the "capability reconstruction by type" —
4c had a delimiter subtlety for non-tail-resume; 4b″ adds a row on top). Front-load a SPIKE (the
first task): give `Suspension`/`Step` the `(row e)` param + thread `e` through `start`/`step`, and
prove the headline negative (bounded-handler-escaped → type error) and a pure-tailed positive (runs,
`e` empty). If the handler elaboration does NOT thread `e` correctly (e.g. the answer-row/resume-row
unification drops it), surface the needed compiler change before the full migration — do not assume
prelude-only.

## 11. Testing

- **Headline negative:** `let s = (with H in start producer) in case s of Suspended _ g -> step g v`
  where the tail performs `H`'s effect and the `H` handler has returned → a **type error**
  (unhandled `e` / `RowMismatch` at the resume site), NOT a runtime crash.
- **Positive (runs):** resume with the residual handler still live → type-checks and `--run`s; a
  pure-tailed coroutine (`e` empty) type-checks and runs unchanged.
- **Regression:** the coro run-examples stay green (`coro-escape=421`, `coro-step-range=10`,
  `coro-step-zip=52`, `coro-multi-driver=64`); with §5's suppress-empty rule, pure-tailed examples
  keep their `Step a b r` rendering (minimal golden churn). The existing negatives still reject.
- **Residual visible:** a fixture where `step g v : Step … with Log` requires a live `Log` handler at
  the resume site (proves `e` is threaded and obligated).

## 12. Migration

`Suspension`/`Step` go arity 3 → "+ row param". User code that uses `start`/`step`/`case` without
writing the coroutine type explicitly is unchanged (inference fills `e`). With §5's suppress-empty
printing, pure-tailed examples/goldens (the bulk: `coro-escape` etc.) do NOT churn. Examples/negatives
that genuinely involve a residual effect (e.g. a producer performing `Log`) change — review the diff
(it should be only `e`/`with e` additions). Any explicit `Suspension a b r` / `Step a b r` type
annotations in the prelude/fixtures gain the row param.

## 13. Build / verify

`cabal build`; `cabal test`; `cabal run -v0 wok -- <file> --run`. No grammar change (the `(row e)`
syntax shipped in Slice B). Mostly a `prelude/Std/Control.wok` change + the printing rule + fixtures,
with possible small compiler work if §10's spike shows `e`-threading needs it. Full-branch review
before merge to `main`.

## 14. Open questions (settle in planning)

1. **Does `e`-threading need any compiler change?** (§10 spike answers this; the plan front-loads it.)
2. **Empty-residual printing implementation:** confirm the kind-aware printer suppresses a concrete
   `KEffect`-kinded empty row in a tycon-arg position exactly as `prettyCType` suppresses an empty
   arrow row, and prints a `KEffect` quantifier as a row var. (Backlog item folded in.)
3. **`run`'s signature now:** `run : Suspension a b r (row e) -> b -> r with eff e` — the `with e`
   reveals effects; its re-suspend *partiality* stays deferred (§7). Confirm no Result/Abort here.

---

## Kickoff prompt (paste into a fresh session)

```
Work on slice 4b″ — RESIDUAL-ROW Suspension/Step for wok (repo /Users/zy/wokml): thread a residual
effect-row parameter `e` through the coroutine types/operations so the resume site must handle the
tail's effects, turning the bounded-handler-escaped resume crash into a TYPE ERROR. Branch from main
first (feat/slice-4b-dprime). Standing rules: FULL-BRANCH review before any merge to main; clarifying
questions in PROSE. Spec: docs/superpowers/specs/2026-06-10-slice-4b-dprime-residual-row-on-kinded-ty-design.md.

The kind prerequisite is DONE (Slices A+B on main): `(row e)` row-kinded tycon params + kind-checked
applications. So this is mostly a prelude change. Types: `extern type Suspension a b r (row e)` /
`extern data Step a b r (row e) = Completed r | Suspended a (Suspension a b r (row e))`. Operations:
`start : (() -> r with Coro a b + eff e) -> Step a b r (row e) with eff e`; `step`/`run` carry
`with eff e`; `cancel : Suspension a b r (row e) -> ()` (NO row — drops the tail, can't fail). The
`__coro_*` prim IMPLEMENTATIONS are UNCHANGED (e is phantom); only their extern signatures gain e.

FRONT-LOAD A SPIKE (task 1): give the types the (row e) param + thread e through start/step, and prove
the headline negative (bounded-handler-escaped -> type error / RowMismatch) and a pure-tailed positive
(runs, e empty). The one risk is whether e threads through the Coro handler's answer type + prim
signatures WITHOUT a compiler tweak; if it doesn't, surface the compiler change before the full
migration.

ROW PRINTING: suppress only a concrete-EMPTY residual (consistent with how `a -> b` drops its empty
arrow row); SHOW the row variable (`Step a b r e`) and non-empty rows (`Step a b r {Log}`). This keeps
pure-tailed coroutines clean and minimizes golden churn. (Folds in the kind-aware-scheme-printing
backlog item.)

NOTE — `run` gets a fail state here but it is NOT fixed in this slice: run stays PARTIAL (re-suspend ->
__coro_unwrap crash); the residual row is about EFFECTS, not completion. run's re-suspend partiality is
the first item for the deferred FAILURE-MODEL slice (guard total / Abort effect / Result). 4b″ only
adds `with e` to run.

OUT: run's totality; cancellation/finalizer runtime; concrete-row args; before/after-suspend split;
scheduler. CONSERVATISM: e = full non-Coro residual (can't split the dynamic suspend point). Follow the
same-name constructor convention. Migration: Suspension/Step arity grows; pure-tailed examples don't
churn under the suppress-empty rule; coro run-examples stay 421/10/52/64.
```
