# Inner-abstraction effect-laundering (rung 3) — design

> **SUPERSEDED END-STATE (added 2026-07-05).** The rung-1/2/3 apparatus this doc
> describes was DELETED (2026-07-03) and replaced by scoped rigid skolemization of
> trapped effect vars — see
> `2026-07-03-rung3-rework-scoped-rigid-trapped-effect-skolemization-spec.md`.
> Retained as design history.
Status: **IMPLEMENTED + validated** (2026-07-03) on `feat/resume-launders-loadbearing`.
The final laundering family after rungs 1+2 of "resume launders effects". Memory:
`[[explicit-resume-effect-laundering]]`. Note (superseded by this doc):
`docs/superpowers/2026-07-02-lambda-effect-laundering-note.md`.

## 1. The gap

An INNER ABSTRACTION (a lambda or a sigless local function) with its own open
ambient can absorb a residual before the enclosing declared-CLOSED row ever sees
it, so the residual is laundered under a pure (lying) type. Three shapes were pinned
as characterization tests:

- **Applied redex:** `driver g = (\h -> run h 0) g` — residual on the lambda's OWN
  parameter `h`.
- **Sigless local:** `drive g = let go u = run g 0 in go ()` — residual is the OUTER
  caller-root (captured `g`), performed under `go`'s inferred-open ambient.
- **Point-free:** `helper = \g -> run g 0` against a closed row-arrow sig.

Adversarial review then showed the *family* is broader than these three: any lambda
that performs a residual on its own parameter, reached through **indirection**, also
launders — a dummy parameter (`(\a b -> run b 0) 0 g`), a `let` binding
(`let k = \h -> run h 0 in k g`), a combinator wrapper (`(\f -> f) (\h -> run h 0)`),
or a sigless local returning a lambda. The fix must close the family, not the three
named points.

## 2. Root cause (verified)

Rung 2 catches a residual at its PERFORM site: `emitResidualTail` records an
obligation iff the residual's tail representative is a caller-root
(`ctxCallerResidualRoots`). That works for a SIGNED equation because its parameters
are sig-refined up front, so a parameter's residual row variable already exists and
is already a root when the body performs it.

Inner abstractions break both preconditions:

- A **lambda / sigless local has no signature**, so its parameters are un-refined
  fresh variables when the body is checked. A residual performed on its own
  parameter (`run h 0`) has a fresh tail that is not yet a root; and
  `inferNormalApp` closes each application's effect row right after emitting it, so
  the residual is closed to empty at the perform site, before the abstraction is
  ever applied. There is no later point where the residual is both a root and alive.
- A **sigless local resets the caller-roots to `[]`**, so an OUTER caller-root
  performed inside it is not in scope as a root.

### Refuted hypothesis (recorded on purpose)

The pre-slice note proposed making inner abstractions PRESERVE (ride) the residual on
their arrow, catching it at a later use. **A spike refuted this:** `inferNormalApp`'s
post-emit `closeRow` deletes the residual at the perform site, so nothing survives to
ride; and routing residuals broadly broke the prelude open-sig runners
(`state`/`reader`/`writer`) and de-synced handler discharge. Riding is the wrong
mechanism.

## 3. Mechanism (implemented) — three composing rules over rung-2's perform-site check

No riding, no residual routing, no `closeRow` surgery. Each rule reuses
`emitResidualTail`'s existing record-if-root logic; they differ only in HOW the
residual becomes recognisable as a root at the perform site.

### 3a. Inherit enclosing caller-roots into inner scopes

`typeEquationWith` (parameterized branch): `roots = if openSig then [] else nub
(ownRoots ++ inherited)`. An open sig discharges through its own tail (reset to
`[]`); a closed sig or a sigless local UNIONS its own roots with the enclosing ones.
A sigless local's `ownRoots` is empty, so it simply inherits — catching the
**sigless-local** leak (`go` sees the outer root `e` at `run g 0`).

### 3b. Checking-mode lambda inference

New `inferExprWChecked (Just expected) (ELam …)` arm (with `peelLamArrows`): when a
lambda is checked against an expected arrow, refine each parameter from the expected
DOMAIN before the body, and — when the expected arrow is closed — treat the lambda's
own parameter row variables as roots. Driven from two sites:

- `inferNormalApp` checks a beta-redex `(\h -> …) g` against `arg_type -> result`,
  refining `h` from `g` → catches the **applied redex** precisely (a lambda applied
  to a *concrete* suspension is refined to that concrete residual and treated as a
  normal handled effect, so no false flag).
- The `typeEquationWith` 0-param branch already checks a point-free binding's body
  against its sig, so `helper = \g -> run g 0` refines `g` from `Suspension … (row
  e)` and (closed arrow) makes `e` a root → catches **point-free**.

### 3c. Enclosing-parameter carrier (`ctxLambdaParams`)

Each inner abstraction ACCUMULATES its parameter types into the carrier
(`withLambdaParams` appends, does not shadow). Under a closed context
(`ctxUnderClosedEqn`), `emitResidualTail` ALSO records when the residual's tail is a
row variable of ANY enclosing abstraction's parameter — collected at the PERFORM
site, where the body's call (`run h 0`) has already refined the parameter. This
catches every INDIRECT own-parameter shape (let-bound, wrapped, multi-param,
sigless-local-returning-lambda) that 3b's direct-redex path cannot see, and it
generalises beyond coroutines to any effect-polymorphic parameter
(`(() -> b with eff e)`). Accumulation (not shadowing) is REQUIRED: a residual
performed in a DEEP lambda on a NON-innermost enclosing lambda's parameter
(`\f -> (\k -> f ()) 5`, reached indirectly) is equally undischargeable and would
otherwise escape when the value is not an affine future (so `FutureConsumedTwice`
does not fire). `ctxUnderClosedEqn` is set True by a closed sig, False by an open
sig, and inherited by sigless locals / lambdas — so open-sig runners never fire.

Two new context fields (`Monad.hs`): `ctxUnderClosedEqn :: Bool`,
`ctxLambdaParams :: [Type s]`.

## 4. Why it is sound / narrow

- The perform-site obligation rule is UNCHANGED. Rung 3 only makes the residual's
  tail *be* a caller-root at the perform site (param refinement / own-param
  membership) or keeps enclosing roots in scope. It never invents a rejection rule,
  so it cannot over-reject beyond rung 2's discipline.
- The own-parameter rule fires ONLY for a bare polymorphic residual tail under a
  closed context. A lambda performing a CONCRETE effect (handled or not) goes through
  `emitEffect`, never `emitResidualTail`, so legitimate effectful callbacks (e.g. a
  handled-`Log` lambda passed to `foldChars` under a closed sig) still type-check.
- Checking-mode fires only for lambdas checked against an arrow; full-suite goldens
  show it never diverges from ordinary inference.
- No new false-reject: the one candidate — an indirect application of a
  residual-closing lambda to a CONCRETE-residual suspension — already fails on
  baseline with a `RowMismatch` (a residual-closing lambda cannot be applied to a
  concrete-residual suspension), so rung 3 introduces nothing there.

## 5. Scope

**IN:** the three pinned positions AND the general enclosing-parameter / captured-outer
family (direct redex, point-free, sigless local, let-bound, wrapped, multi-param,
effect-poly function parameters, and residuals on NON-innermost enclosing lambda
parameters reached through nested lambdas).

**Also rejected (belt-and-suspenders):** a residual on an OUTER lambda's parameter
performed inside a NESTED closure where the parameter is an affine FUTURE
(`\h -> (\k -> run h 0) 5`) is caught both by 3c (accumulated carrier) and, because
the future `h` is captured by an inner closure, by the pre-existing
`FutureConsumedTwice` / `CarrierEscape` rule.

## 6. Migration & tests

- The 3 `launder-leak-inner-*.wok` characterizations FLIP to rejections: MOVED to
  `test/typecheck-fail-examples/` with `UndischargedEffect "e"` goldens; headers
  rewritten from "KNOWN LEAK" to "rung-3 death test".
- FOUR new completeness death tests pin the review-found bypass shapes:
  `launder-leak-inner-{multiparam,letbound,wrapped,nested-param}.wok` (carrier /
  accumulated-carrier), each with an `UndischargedEffect "e"` golden.
- Regression bar (all HELD): the 3 rung-1 + 3 rung-2 death tests still reject; the
  accept-corpus (`coro-residual-handled`/`multi`, `coro-resume-driver`,
  `coro-pure-tail`, `44-named-instance`, `effect-poly-roundtrip`, `09-higher-order`,
  `11-effect-collect`, `54-reentrant-routing`, the full prelude) stays accepting.
- Type-only, no runtime change. hlint clean (no new hints).

## 7. Success criteria (met)

1. The 3 pinned leaks AND the 4 review-found bypass shapes reject with
   `UndischargedEffect`. ✔
2. Zero regression on the accept-corpus and the rung-1/2 death tests. ✔
3. Full suite green: **2135 tests pass** (+4 completeness death tests), zero golden
   churn. ✔
4. Legitimate effectful (concrete, handled) lambdas and open-sig effect-poly
   parameters still accept — no false positives. ✔

## 8. Implementation footprint (~170 lines)

- `Monad.hs`: two context fields + `with`/`current` accessors
  (`ctxUnderClosedEqn`, `ctxLambdaParams`).
- `Infer.hs`:
  - `emitResidualTail` own-parameter carrier check (3c).
  - `inferExprWChecked` ELam checking-mode arm + `peelLamArrows` + `inferNormalApp`
    beta-redex hook (3b).
  - `typeEquationWith` parameterized-branch root inheritance + `withUnderClosedEqn` /
    `withLambdaParams` install (3a, 3c).
  - plain ELam arm installs `withLambdaParams` (3c).
