# Note: inner-abstraction effect-laundering (pre-existing; the slice after rung 2)

Status: **OBSERVED, scoped as the slice after rung 2** (2026-07-02; broadened
2026-07-03). Surfaced during rung-1 review (Gate 3), broadened by the rung-2
adversarial design check. This is a distinct family from the caller-root provenance
work (rung 2): any INNER ABSTRACTION with its own open ambient — a lambda OR a
sigless local function — absorbs a residual before it reaches the enclosing
declared-closed row, so neither rung 1 nor rung 2's caller-root rule catches it.
Two confirmed members:

- **Lambda-parameter:** `driver g = (\h -> run h 0) g` (below).
- **Sigless local function:** `drive g = let go u = run g 0 in go ()` — performs the
  OUTER function's caller-root residual `e` under `go`'s own inferred-open ambient;
  accepted today as pure `drive : Suspension … (row e) -> U64`, the type lies.
- **Point-free 0-arg binding:** `helper = \g -> run g 0` with a closed row-arrow sig
  `Suspension … (row e) -> U64` — accepted today (`forall a. Suspension … a -> U64`),
  even though the eta-equivalent explicit-param form `helper g = run g 0` is
  correctly REJECTED. Surfaced by the rung-2 line-by-line review: `typeEquationWith`'s
  zero-parameter branch (`Infer.hs`, the `pTys == []` case) never calls
  `callerRootRefs`/`withCallerRoots`, so a function-typed 0-arg binding tracks no
  roots. The inner-abstraction fix must ALSO extend root collection to that branch,
  handling the wrinkle that the effect row that matters sits on the binding's
  declared ARROW, not on the binding's own (pure) evaluation.

Both stem from the same root cause: the inner abstraction does not PROPAGATE its
body's residual effects onto its inferred arrow / into the enclosing ambient. The
fix is effect-propagation, orthogonal to rung 2's provenance rule.

## The observation

`ELam` (anonymous-lambda) inference in `src/Wok/TypeChecking/Infer.hs` (~2081-2100)
installs a plain `withEffRow` ambient for the lambda body and unconditionally
`closeRow`s it afterward, with **no undischarged-effect obligation check**. So a
lambda whose body performs an effect it does not "own", applied under a closed
declared row, can launder that effect:

```
-- f : () -> U64 with eff e in scope; enclosing sig closed:
driveLambda f = (\x -> f ()) 0        -- performs e via f(), accepted (laundered)
```

The review confirmed this reproduces with and without an intervening combinator.

## Scope / why it's separate

- **Different root cause** from the resume-launders hole: that one is about a bare
  residual passing through a handler discharge site (needs provenance —
  `2026-07-02-resume-launders-rung2-provenance.md`); this one is `ELam` simply not
  running the obligation check that `typeEquationWith` runs for named equations.
- **More general:** it is about effectful lambdas, not coroutines/handlers at all.
- **Partially masked today:** the carrier-typed variant is blocked by the existing
  second-class affine carrier discipline (`CarrierEscape` / `FutureConsumedTwice`)
  ONLY when the future is CAPTURED by the closure (`\x -> run g x` closing over an
  outer `g`). When the future is the lambda's own PARAMETER, a carrier `run`
  launders cleanly — e.g. `driver g = (\h -> run h 0) g` under a closed sig
  type-checks with no residual (the lie). So the carrier discipline is not a
  reliable backstop here; both non-carrier `eff e` callbacks and parameter-passed
  carriers leak through the lambda path.

## Candidate direction (for a future brainstorm, not now)

Seed `ELam`'s ambient with the enclosing declared-closed status (as rung 1 did for
`typeEquationWith` via `withEffRowSig`), OR emit the lambda's inferred effect row at
each application site so it flows into the caller's ambient like any other
performed effect. Both need a careful pass over how nested-lambda effect rows
currently propagate (they may be silently dropped rather than attached to the arrow),
plus a corpus check that legitimate higher-order effect-polymorphic code
(`map`/`fold`-likes over effectful callbacks) still type-checks. Not yet scoped.
