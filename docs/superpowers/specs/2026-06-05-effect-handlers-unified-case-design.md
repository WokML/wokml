# Effect handlers: first-class resume, unified `case`, multi-shot

Date: 2026-06-05
Status: SURFACE DESIGN SUPERSEDED by `2026-06-05-effect-handler-surface-syntax.md`.
  The `handle`/`return` keywords and the `case`-merge proposed here were rejected
  in favor of a single `with`-prefix handler form (see the successor). The
  "Compilation and runtime model" section below remains current and is referenced
  by the successor.
Related: `docs/koka.md`, `docs/superpowers/specs/2026-06-05-multi-clause-match-compiler-design.md`, `docs/superpowers/specs/2026-06-05-effect-handler-surface-syntax.md`
Future module: `Control.Wok` (effect/handler prelude)

## Problem

wok's effect system is row-typed and Koka-aligned, and the runtime is already a
deep, delimited, **multi-shot** continuation machine. But the front end only
exposes a thin slice of it:

1. **Operations are forced tail-resumptive ("everything is `fun`").**
   `elabOpArm` (`src/Wok/IR/Elaborate.hs:510-518`) rewrites every handler arm
   `<body>` into `let res = resume(<body>) in deliver res`. The user never names
   `resume`, so cannot resume zero times (exceptions) or many times
   (nondeterminism/backtracking) -- even though `dispatchOp`
   (`src/Wok/Interp/Machine.hs:137-150`) already binds a reusable
   `VCont (\after -> above (KHandle h hsc after))` that supports all of it.
2. **`handle` and `return` are separate keywords** from `case`, despite being the
   same shape (`<kw> e of { arms }`) and despite the "return" clause being just
   "what to do with the final value" -- which is what a value pattern is.
3. **No `fun`/`ctl` distinction and no way to add one ergonomically.** We do not
   want Koka's `fun`/`ctl` keywords (user preference).

## Goals

- Make `resume` a first-class value bound in operation arms; the arm body decides
  whether/how often to call it. This unlocks exceptions (0x), transparent effects
  (1x), and multi-shot (Nx) with no runtime change.
- Fold effect handling into `case`: one construct dispatches on how a computation
  finishes -- a value (value arms) or an operation (operation arms). Remove the
  `handle` and `return` keywords.
- Keep the surface keyword-free: the **presence of a continuation binder** on an
  operation arm is the `fun`/`ctl` switch, not a keyword. The `fun`-style
  optimization (skip continuation capture for provably tail-resumptive arms) is a
  later *analysis*, consistent with the project's "analysis, not annotation"
  stance.

## Non-goals (explicitly deferred)

- **Parameterized handlers** (`handler(s){...}`) -- needed for the clean State
  encoding. Additive follow-up.
- **Scoped / higher-order operations** (`catch`, `local`, `mask`, `listen`).
  These are non-algebraic and must be handlers or a dedicated scoped-effect
  construct, NOT operations. Designing them is separate (and is where a naive
  "make it an operation" encoding goes wrong).
- **The `fun` fast-path optimization** (compile tail-resumptive arms without
  capturing a continuation). Correctness does not need it; it is a perf pass.
- **Standard effect library** in `Control.Wok` (State/Reader/Writer/Exn). Lands
  after first-class resume + parameterized handlers.
- **Effect masking / aliases / `inject`.**

## Design

### 1. Surface syntax: operation arms with an explicit resume binder

Operation arms gain an optional trailing continuation binder; value arms are
ordinary patterns. The grammar already distinguishes the two by the case of the
segment after the dot (`EProj` = dot-lowercase = operation; `EProjC`/`ModPath`
= dot-uppercase = constructor), so NO marker keyword is needed for parsing.

```
case (compute ()) of
  Ask.ask () resume -> resume 21      -- operation arm, binds resume (ctl-style)
  State.get ()      -> currentState   -- operation arm, NO binder (tail-resumptive)
  Exn.throw msg k   -> "err: " ++ msg -- binds k, never calls it (exception, 0x)
  Choice.flip () k  -> k True ++ k False -- binds k, calls twice (multi-shot)
  v                 -> Just v         -- value arm (the old `return` clause)
```

Rules:
- **Operation arm WITHOUT a continuation binder** -> tail-resumptive: the body
  has type `T` (the operation's result type) and is implicitly resumed
  (`resume(body)`). This is exactly today's behavior.
- **Operation arm that binds a continuation** -> the body has type `R` (the
  answer type), and the body controls resumption; `resume : T -> R ! eps`.
- **Value arms** are the return clause. Omitting all value arms means an identity
  return (requires `A = R`, where `A` is the handled computation's result type).
- Calling the continuation is ordinary application (`resume v` / `k v`); no
  special syntax. In ANF it is `RApp k [v]`; the machine handles it via `enter`
  on a `VCont`.

### 2. The unifying type rule

For a handled computation producing `A` with effect row `<L | eps>`, an operation
`op : S -> T`:

```
case (e : A ! <L | eps>) of
   L.op (x : S) k  ->  body : R ! eps      where k : T -> R ! eps
   (v : A)         ->  ret  : R ! eps
   : R ! eps
```

Key fact (the thing Koka docs never state plainly): `k : T -> R`, NOT `T -> A`.
Resuming continues the computation to a leaf value of `A`, which flows through the
value arms (turning `A` into `R`) before `k` returns. This matches the runtime:
`resume` re-installs the handler (`KHandle`) in its continuation, so completion
runs `hReturn` (= the value arms) and that is what `resume` yields.

### 3. Merge `handle` into `case`; drop `return`

- Remove `EHandle` / `HArm` / `HReturn` productions; extend `ECase`'s `Alt` to
  admit operation arms (dot-lowercase head + optional trailing binder).
- A `case` whose scrutinee is run under interception (it has >=1 operation arm)
  evaluates the scrutinee **under a handler frame** (install `KHandle` before
  evaluating it), unlike a plain `case` which evaluates the scrutinee to a value
  first. The elaborator selects `Handle` vs `Case` lowering by arm kind.
- The `return` keyword is gone; value arms are the return clause and may be a full
  pattern match on the result.

### 4. Lowering

`case` with operation arms lowers to the existing ANF:

```
case e of { <valueArms> ; <opArms> }
  ==>
Handle e (Handler
   retArm = (r_fresh, Case r_fresh [ <valueArms compiled> ])
   opArms = [ <opArms> ])
```

`Handle` and `Case` stay distinct ANF nodes. The value arms reuse the
match-compiler (`Wok.IR.Match`) inside `hReturn` -- so this design depends on, and
composes with, the multi-clause match-compiler work. A `case` with no operation
arms lowers to a plain `Case` exactly as today.

### 5. Elaboration change for resume

`elabOpArm` (`src/Wok/IR/Elaborate.hs:510-518`) changes from "always wrap
`resume(body)`" to:
- if the surface arm binds a continuation name `k`: bind `oaResume` to `k`
  (`withLocal`), and elaborate the body as-is (it already has type `R`);
- else (no binder): keep the current `let res = resume(body) in deliver res`
  wrap (tail-resumptive).

`OpArm.oaResume :: Binder` already exists in the ANF and is rendered by
`renderOpArm`, so the plumbing is present; the change is which surface name (if
any) maps to it and whether to auto-wrap.

### 6. Runtime: no change

`dispatchOp` already binds a deep, reusable `VCont` and runs the arm body under
`kBelow` without auto-resuming. Multi-shot works because the continuation is
reified immutable data (`\after -> above (KHandle h hsc after)`), re-runnable any
number of times. Zero runtime changes for first-class / multi-shot resume.

## Coverage

The unified `case` runs two existing checks side by side: value arms exhaustive
over `A` (the match-compiler usefulness pass), and operation arms cover every op
of each handled effect (`HandlerCoverage`). They coexist on one construct.

## Compilation and runtime model

This section records the agreed *compiled* target. It does not alter the surface
design above, and it is deferred behind the interpreter: the CEK ANF interpreter
is the near-term run target and the reference-semantics oracle, and it uses one
uniform reified representation, so none of the duplication concerns below affect
it. This is the eventual codegen story, not a prerequisite for first-class
resume.

### The machine is already stackless

The CEK ANF interpreter is defunctionalized CPS. The `Kont` ADT
(`KLet`/`KApp`/`KHandle`/`KDone`) reifies the user program's call stack as
immutable heap data, and `run` is a constant-host-stack trampoline; user call
depth lives in `Kont`, not in host frames. So evaluation is stackless by
construction, and concurrency is just scheduling several `Config`s through the
one trampoline -- a fiber is a parked `Config` (or the delimited `VCont` from
`dispatchOp`), and a scheduler is a queue plus the existing `step`. Capture is
delimited (`findHandler` walks out only to the nearest `KHandle`), so a fiber
parks itself without disturbing the scheduler above it.

### Contify vs reify (the central compile decision)

A join point is the direct-style compilation of a continuation that is
**one-shot, tail-called, and non-escaping**. Classify each captured continuation
and compile accordingly:

| resume usage | reify? | target |
|---|---|---|
| 0-shot (abortive / exception) | no | non-local jump to the handler's join point, dropping the suspended frames (+ unwinding if they hold resources) |
| 1-shot, tail, non-escaping (today's auto-resume) | no | a `jump` to a join point -- free |
| 1-shot, non-tail, non-escaping | partial | a one-shot call/return (a real return edge, not a pure join point) |
| 1-shot, escaping (async `await`, generator `yield`) | yes | a reified one-shot continuation handed to a scheduler -- the parked fiber |
| N-shot (multi-shot / `amb`) | yes | a reified immutable/copyable continuation (selective CPS) |

Everything wok compiles *today* (tail-resumptive auto-resume) is in the
contifiable row; reification is needed only for escaping/multi-shot features not
yet built. This realizes the `fun` fast-path listed as a non-goal above: correctness
uses the reified path first, contification is the later perf pass.

The decision is driven by two analyses already on the roadmap: **escape
analysis** (does `resume` outlive the arm?) and **multiplicity/cardinality** (is
it resumed more than once?). Policy: **second-class (contified, direct) by
default; promoted to first-class (reified, selective CPS) only where escape or
multi-shot is proven** -- a fast default, analysis upgrades the rare case, never
an annotation. This is Effekt's second-class-handlers idea made conditional via
the analysis.

### Why stackless selective CPS, not stackful fibers

OCaml 5 chose stackful fibers; wok should choose stackless selective CPS:

- wok's continuations are immutable (the persistent `Kont`), so multi-shot is a
  re-apply, not a stack copy.
- selective CPS needs effect *types* to decide which functions touch a handled
  effect; wok's row-typed effects provide exactly that. OCaml lacks effect types
  -- which is *why* it went stackful. Our row types are the enabling asset.
- it is continuous with the CEK machine already built.

### Dispatch: evidence passing

The interpreter's `findHandler` walks the `Kont` at runtime -- fine for the
interpreter, too slow compiled. The compiled target replaces it with evidence
passing (Koka): thread an evidence vector so an operation is an indexed direct
call rather than a stack walk, which also makes the contify target statically
known.

### Duplication and OPEN/CLOSE

Selective CPS forces effect-polymorphic functions that *might* carry a
controlling effect into a dual (CPS + direct) compilation. This is contagious up
the call graph and acts as an inlining barrier, and it lands on the most-reused
generic combinators (`map`/`fold`/`traverse`). The bound is **OPEN/CLOSE** type
simplification (store let-bound types in closed/total form, open a fresh effect
tail at each use site): it proves that most functions which only *looked*
effect-polymorphic carry no handled effect and drops them from the CPS set (>80%
in Koka's core library). The residual cost is the genuinely higher-order
effect-passing spine, which is irreducible. wok's row types are what make this
pruning possible at all.

### Concurrency and capabilities

A default scheduler handler installed at `main` gives "dispatch to runtime" with
no ceremony; being a handler, it is replaceable (e.g. a deterministic,
simulated-time test scheduler -- the same user code under a different outer
handler). Distinguish **capabilities** = required effects in the row (must be
handled; dependency injection) from **hints** = ignorable effects/attributes the
default handler may treat as no-ops (correctness must survive dropping every
hint). Real OS-level async needs one readiness primitive (an event loop) as a
runtime addition; the park/unpark control flow itself is all in-language.

## Disambiguation and readability

Parsing needs no marker (dot-lowercase = operation). For human readability the
open question is whether to keep a lightweight optional marker on intercepting
arms; default proposal is convention-only (dot-lowercase + trailing binder),
matching OCaml's minimal `effect ... , k` spirit without its keyword.

## Risks / open questions

- **Readability of `case`'s dual evaluation mode.** A `case` silently runs its
  scrutinee under a handler when an operation arm is present. Acceptable (OCaml
  does the same) but worth confirming we do not want an explicit cue.
- **Type inference for resume's `T -> R ! eps`.** `inferHandler` must type the
  bound continuation with the *outer* effect row; verify this composes with the
  current row-discharge logic in `Infer.hs`.
- **Value restriction.** First-class multi-shot + mutable state is exactly where
  unsound let-generalization bites; confirm the generalize-only-at-`<>` rule is
  enforced before shipping multi-shot examples.
- **Sequencing vs the match-compiler.** The value-arm half depends on
  `Wok.IR.Match`; this work should land after (or alongside) that.

## Suggested slices (for a future plan)

1. First-class resume in the EXISTING `handle` syntax (bind `oaResume` to a
   surface name; stop auto-wrapping when bound; type `resume`). Smallest unit;
   unlocks exceptions + multi-shot. No grammar merge yet.
2. Merge `handle`/`return` into `case` (grammar + elaboration routing).
3. Parameterized handlers.
4. `Control.Wok` standard effects.
