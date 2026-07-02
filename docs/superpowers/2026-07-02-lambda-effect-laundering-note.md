# Note: lambda effect-laundering (pre-existing, separate from the resume-launders epic)

Status: **OBSERVED, not scheduled** (2026-07-02). Surfaced during the rung-1 review
of the "resume launders effects" slice (Gate 3, position iv). Recorded so it is not
lost; it is NOT part of the resume-launders epic and would not be fixed by that
epic's rung-2 provenance analysis.

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
