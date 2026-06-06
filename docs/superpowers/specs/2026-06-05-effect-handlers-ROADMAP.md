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
| 4 | Parameterized handlers -> scheduler / `spawn` / `par` / `Future` / `Control.Wok` | deferred |
| X | One-shot multiplicity check + value restriction; cancellation (discontinue) | deferred, gated on ANF analysis |

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

### Slice 4 — parameterized handlers, then the runtime

- **Goal:** clean stateful `State`, then real concurrency.
- **Delivers (in order):** parameterized handlers; then scheduler / `spawn` / `par`
  / a `Future` primitive (hides the existential for heterogeneous parked
  continuations) / `Control.Wok` standard effects.
- **Plan file(s):** _to be written, just-in-time._

### Cross-cutting (slice X) — checked properties

- One-shot `resume` multiplicity check (declared-one-shot + witnessed second resume
  = compile error; also gates one-shot stack-switch vs copyable-multishot codegen).
- Value restriction: generalize only at `<>` — required before shipping multi-shot
  + mutable state soundly.
- Cancellation (discontinue) as the SECOND consumer of a one-shot continuation;
  design the multiplicity analysis for "resumed XOR cancelled," not resume-only.
- Gated on the ANF analysis substrate (see [higher-ir-direction]); not part of
  slice 1.

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
