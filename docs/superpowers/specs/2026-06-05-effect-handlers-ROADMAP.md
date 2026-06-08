# Effect handlers — design index & implementation roadmap

Date: 2026-06-05
Status: Living index. The single reference a slice plan points to for the big picture.

This is a thin index over the effect-handler design. It does NOT restate the
design (the linked specs do that); it ties the pieces together, owns the slice
roadmap, and records cross-cutting invariants. When starting a slice: read this +
the linked spec sections, then write a plan in `docs/superpowers/plans/` that
references this roadmap and contains that slice's bite-sized tasks.

## Status board

| Slice | Scope | State |
|---|---|---|
| 1 | Value ops + `with`-prefix handler, auto-resume default / binder-control, drop `handle`/`return` | DONE — merged to `main` (542 tests green) |
| 2 | Optional effect header + forgotten-resume lint + `Never` | DONE — merged to `main` (562 tests green) |
| 3 | Bounded `(with H e)` handler scope | DONE — merged to `main` (572 tests green) |
| 4a | Parameterized handlers + `with … in` runner sugar + `Std.Control` (mtl quartet) | DONE — feat/effects-slice-4a-parameterized-handlers (585 tests green) |
| 4b | Scheduler / `spawn` / `par` / `Future` / `Std.Control` concurrency half | deferred |
| X (analysis) | One-shot multiplicity = **affine (no-dup) analysis** on continuation binders; multi-shot handler = compile error | DONE — feat/one-shot-multiplicity (652 tests green); see `2026-06-09-one-shot-multiplicity-analysis-design.md` |
| X (rest) | ~~value restriction~~ (DROPPED as unnecessary under one-shot-as-law); cancellation (discontinue) as the no-drop second consumer | deferred |

## Design sources (read in this order)

1. `docs/koka.md` — foundations: row theory (scoped labels), handler typing rule,
   `resume : T -> R` outer-effect typing, deep handlers, value restriction. The
   "why the type system works" layer.
2. `docs/superpowers/specs/2026-06-05-effect-handler-surface-syntax.md` — the
   **surface** (final): value ops, `with`-prefix + scope rule, auto-resume default
   / bind-to-control, optional value arms, async-as-operations, the lint, goal
   alignment, deferred list, slice breakdown.
3. `docs/superpowers/specs/2026-06-05-effect-handlers-unified-case-design.md`
   §"Compilation and runtime model" — **lowering/runtime**: CEK machine is
   defunctionalized CPS (stackless), contify-vs-reify, selective CPS not fibers,
   evidence passing, OPEN/CLOSE, duplication bound. (That doc's surface design is
   superseded by source 2; only its compilation section is current.)

Rejected alternatives and the reasoning are in the `effect-surface-syntax-final`
memory — consult before relitigating `fun`/`ctl`, magic `resume`, the `case`-merge,
or do-notation.

## Slice roadmap

### Slice 1 — value ops + `with`-prefix + auto-resume/binder (plan next)

- **Goal:** the core surface runs on the existing CEK interpreter.
- **Delivers:** exceptions (0x), multi-shot (Nx), and the async *shape* (deferred
  resume) — all without a runtime/scheduler.
- **Touches:** grammar (`grammar/Wok.cf`: `with { arms } rest`, value-op decls,
  optional binder; regen BNFC parser), elaboration (`Elaborate.hs:486-518`: no
  binder -> keep auto-wrap; binder -> bind name, stop wrapping, body is R),
  typecheck (`Infer.hs:1652+ inferHandler`: body-type T-vs-R by binder, value-op
  typing, `resume : T -> R with eps` against the outer row), runtime
  (`Machine.hs`: mostly unchanged — `dispatchOp` already binds resume; `with`
  lowers to existing `Handle`), migration of `handle`/`return` examples + goldens.
- **Riskiest task (front-load):** handler type inference — the body-type mode and
  resume's outer-row typing. This is the one open question flagged in the surface
  spec.
- **Depends on:** the multi-clause match compiler (landed) for value-arm lowering.
- **Plan file:** `docs/superpowers/plans/2026-06-05-effects-slice-1-with-resume.md` (executed; 5 tasks, all reviewed).
- **Follow-ups discovered during implementation** (non-blocking; carry into slice 2 or a printer/layout pass):
  1. **`with`-printer round-trip.** BNFC's layout-unaware `printTree` dedents the trailing `with`-body to column 0, so print->reparse fails; `test/golden/{20-effects-syntax,26-with-handler}.expected` pin a `ROUND-TRIP PARSE ERROR` (source parses + runs fine). Fix: emit a re-parseable layout for the `EWith` body.
  2. **Malformed-arm error label.** ~~A too-many-patterns / non-variable continuation binder throws `UnknownOperation` (misleading — the op IS known). Add a dedicated `MalformedHandlerArm`/arity error before the feature is user-facing.~~ **RESOLVED (slice 2):** dedicated `MalformedHandlerArm SourceSpan Text Text` replaces the `UnknownOperation` throw at the malformed-arm fallthrough.
  3. **Resume-name sentinel.** `TOpArm` uses `Tx.empty` to mean "auto-resume"; consider `Maybe Text` to make the auto-resume-vs-control distinction total (cross-cutting: `Typed.hs` + `Infer.hs` + `Elaborate.hs`).
  4. **Non-returning ops need an effect param.** ~~`effect Exn = { throw : String -> a }` is rejected (op result vars must be effect params); the working form is `effect Exn a = { throw : String -> a }`. This affects the slice-2 forgotten-resume lint discriminator (the "non-returning op" check) — revisit when building the lint.~~ **RESOLVED (slice 2):** non-returning is encoded as an uninhabited bottom type `Never` (built-in `TcNever`), not an effect param — `effect Exn = { throw : String -> Never }`. The lint discriminator is "result type is `Never`" (sound; no false positive on a `Reader r = { ask : r }`-style output-only param). Performing a `Never`-result op freshens its result to a type variable (ex-falso) so it is usable at any type. See `2026-06-05-effects-slice-2-design.md` §2.
  5. **Resume binder IR type annotation.** In `Elaborate.elabOpArm` the resume binder is annotated `teType body` — the op result type `T` in auto-resume (correct) but the answer type `R` in the control branch (imprecise; the continuation is `T -> R`). Latent today (field unused by the untyped interpreter). Fix when the typed-Core pass needs a precise resume type: thread `T` onto `TOpArm`. Commented at the site.

### Slice 2 — effect header + forgotten-resume lint

- **Goal:** ergonomics + safety net for the binder-control case.
- **Delivers:** `with E1 E2 { ... }` unqualified arms (strict coverage contract;
  ambiguity / out-of-header / empty-handler errors); the "named binder unreferenced
  on a returning op" lint with the `_` (wildcard) suppressor; the `Never` bottom
  type + `MalformedHandlerArm` error.
- **Depends on:** slice 1.
- **Plan file:** `docs/superpowers/plans/2026-06-05-effects-slice-2-header-lint.md` (executed; 6 tasks, all reviewed).
- **Design file:** `docs/superpowers/specs/2026-06-05-effects-slice-2-design.md`.

### Slice 3 — bounded `(with H e)`

- **Goal:** nice syntax for partial handler scope.
- **Surface:** `(with H e)` (parenthesized prefix; no separator — `;` would
  overload the arm separator, and a dedicated paren production conflicts with
  `EParen`+`EWith`). The form already parses and routes through the existing
  typechecker/elaborator/runtime, so there is no grammar/parser/typecheck change.
- **Substance:** a runtime fix. A resuming handler in non-tail position did not
  delimit its continuation; `resume` now rebinds the handler's answer-join to the
  resume call site. Design: `2026-06-06-effects-slice-3-bounded-handlers-design.md`.
- **Plan file:** `docs/superpowers/plans/2026-06-06-effects-slice-3-bounded-handlers.md`.

### Slice 4a — parameterized handlers + `with … in` sugar + `Std.Control` (mtl)

- **Status: implemented (585 green)** — `feat/effects-slice-4a-parameterized-handlers`.
- **Goal:** clean, composable stateful `State`, and the mtl workhorse stack as flat
  handlers.
- **Delivers:** (1) parameterized handlers — a handler carries a local parameter
  threaded through a **two-argument resume** `resume(newParam, result)`; auto-resume
  threads it unchanged, a parameter change takes control. (2) the `with <runner> in
  <body>` runner sugar (≡ `<runner> (\_ -> <body>)`), coherent with `let … in`,
  stacked for multiple handlers. (3) `Std.Control` as a second embedded prelude with
  `Reader`/`Writer`/`State`/`Except` + terse runners.
- **Key finding (load-bearing):** the library-encoding shortcut (answer type `s -> …`,
  no new mechanism) **does not compose** — stacking two parameterized handlers with
  interleaved ops silently loses the outer parameter (proven both directions on the
  live compiler). Parameter-in-the-frame composes; parameter-in-the-answer-type does
  not. So the mechanism must be real (param in `hsc`, re-installed on the slice-3 deep
  resume).
- **Riskiest task (front-load):** the nested different-effect composition case
  (`state` outside, `writer` inside, and the swap) — the exact case the encoding
  failed. TDD anchor. Second: the dangling-`in` layout behaviour of `with … in`.
- **Design file:** `docs/superpowers/specs/2026-06-07-effects-slice-4a-parameterized-handlers-design.md`.
- **Plan file:** _to be written, just-in-time._
- **Follow-ups discovered during implementation** (non-blocking):
  1. **Diamond-import env-merge coarseness.** ~~`overlayEnvs` merges same-name/same-type re-exports silently to support the second embedded prelude; two distinct definitions sharing a name+type are no longer caught.~~ **RESOLVED (772c345):** `overlayEnvs` (`src/Wok/TypeChecking/Env.hs`) keys var-namespace conflict detection on **binding provenance** — `Env.envVarOrigin` (name → defining module), stamped in `Pipeline.hs`. A diamond re-export (same origin) merges; a genuine cross-module redefinition (different origin) errors, even with identical types. `lookupVar`/`extendVar`/inference unchanged.

### Slice 4b — the concurrency runtime

- **Goal:** real concurrency on top of parameterized handlers.
- **Delivers:** scheduler / `spawn` / `par` / a `Future` primitive (hides the
  existential for heterogeneous parked continuations) / the concurrency half of
  `Std.Control`. Needs existential support for parked continuations.
- **Plan file(s):** _to be written, just-in-time, after 4a lands._

### Cross-cutting (slice X) — checked properties

**Re-anchored 2026-06-09** (design: `2026-06-09-one-shot-multiplicity-analysis-design.md`).
wok makes **one-shot the law**: an affine (no-dup) analysis on continuation binders,
NOT a declared-one-shot opt-in and NOT multi-shot-as-a-property.

- **Analysis half — DONE** (`feat/one-shot-multiplicity`): `Wok.IR.Multiplicity` computes a
  `{0,1,ω}` cardinality per handler arm over `Wok.IR.Anf`; a provably multi-shot (`ω`) arm is
  a compile error (`--run` rejects it; `--dump-multiplicity` shows the number). Backtracking is
  reshaped to explicit `List`; events/streams/async to one-shot pull + recursion.
- **Value restriction: DROPPED as unnecessary.** The polymorphic-ref hazard requires
  duplication; no multi-shot → no hazard → no value restriction. (Reverses the earlier "feed a
  value restriction" framing; `ndet`-for-concurrency is unaffected — only `amb`/backtracking-
  as-handler is gone.)
- **Cancellation (discontinue)** = the deferred **no-drop** second consumer of the continuation;
  it upgrades affine → linear once wok grows a resource type needing exactly-once. The `0`-shot
  detection here is the groundwork.
- The interpreter is UNCHANGED — the law is a reversible frontend gate, not a runtime
  amputation (immutable `Kont` keeps multi-shot capability).
- Ran on the existing ANF substrate (see [higher-ir-direction]); no typed-Core prerequisite,
  no grammar change.

## Cross-cutting invariants (hold across all slices)

- **Decidable:** handlers are second-class (not first-class values) -> inference
  stays HM + row unification.
- **Deterministic:** all nondeterminism (incl. racy scheduling) is reflected in the
  effect row (`ndet`); "deterministic program" = its row lacks `ndet`. Not a claim
  about concurrency execution order.
- **Effect handlers are the one control mechanism** — exceptions, state, async,
  generators, backtracking are all handlers, not bespoke features.
- **Analysis over annotation:** tail-resumptive is derived (no-binder arms contify
  for free); the user never writes `fun`/`ctl`.

## How to use this roadmap

1. Pick the next slice from the status board.
2. Read this roadmap + the linked spec sections for that slice.
3. `writing-plans` -> a plan in `docs/superpowers/plans/` that references this
   roadmap, front-loading the riskiest task.
4. Write plans just-in-time (one slice ahead at most): each slice teaches things
   that reshape later ones.
