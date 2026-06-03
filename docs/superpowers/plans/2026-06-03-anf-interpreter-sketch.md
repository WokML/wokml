# ANF Interpreter Sketch (Scope C) — for a subsequent session

> **Status:** SKETCH, not an executable plan. Before implementing, re-run the
> `writing-plans` skill to expand each task below into full steps with code,
> once Scope B (`2026-06-03-anf-elaboration.md`) has landed and the ANF shape
> is concrete. This file records the intended decomposition and the known
> hard parts so the next session starts with context, not a blank page.

**Goal:** Execute a `CoreModule` (from Scope B) so a `.wok` program actually runs, with effect handlers working, validated by golden output tests. No codegen.

**Architecture:** A CEK/CESK-style machine over `Wok.IR.Anf.Expr`. Chosen over a naive environment-passing evaluator specifically because algebraic-effect `resume` needs a reified continuation — a CEK kontinuation stack makes capture/restore direct instead of fighting the host call stack. Runtime is refcount-free for now (host GC); Perceus comes with codegen, not the interpreter.

**Tech stack:** Haskell, `Data.Map`/`IntMap` keyed on `Unique` for environments, `tasty`-golden for program-output goldens.

---

## Why CEK (the load-bearing decision)

`ROp E op args` must transfer control to the nearest enclosing handler for `E`, capturing the continuation between the call and that handler. With an explicit kontinuation stack this is "split the stack at the handler frame"; with host recursion it would need exceptions + thunked re-entry and could not express multi-shot `resume`. Deep handlers mean the captured continuation is re-wrapped in the same handler on resume. Get this in an interpreter first — it pins the semantics the eventual codegen strategy (CPS / evidence-passing / stack capture) must match.

## Task outline (to be expanded)

### Task 1: Runtime values + environment
`data Value = VClosure Env [Binder] Expr | VCon Text [Value] | VRecord (Map Text Value) | VLit Lit | VCont Kont | VPrim PrimImpl`. Environment = `Map Unique Value`. Unit tests on constructing/forcing values.

### Task 2: The CEK machine core (no effects yet)
`step :: Config -> Config` where `Config = (Expr, Env, Kont)`. Handle `Ret`, `Let` (push a `KLet` frame), `Case`/`AltCon` matching, `RApp`/`RCon`/`RProj`/`RRecord`/`RLam`, `LetRec`. `LetJoin`/`Jump` as labeled local continuations (a join is a `VCont`-like frame keyed by `JoinId`, invoked without growing the logical call depth). Run-to-`Ret`. Unit tests: arithmetic-free pure programs (identity, pattern match, list build/consume).

### Task 3: Builtins / primitives
Provide native implementations for the operators and constructors that `Wok.TypeChecking.Builtins` registers (`+`, `-`, `==`, `++`, comparisons, `True`/`False`, tuples, list `Cons`/`Nil`, `()`), as `VPrim` entries in the initial runtime env keyed by the same `globalName` the elaborator uses. Unit tests: arithmetic, list append, boolean logic.

### Task 4: Effect operations + handler frames
Extend `Kont` with `KHandle Handler Env`. `ROp E op args`: walk the kont stack to the nearest `KHandle` whose handler covers `(E, op)`, capturing the frames above it as a `VCont` (the delimited continuation); bind op args + `resume := VCont(captured, re-wrapped in this handler)` and run the arm body. `return` arm transforms the final value when the handled computation completes normally. **Deep handlers:** `resume` re-installs the handler frame. Support multi-shot by making `VCont` re-invocable (copy, don't consume). Unit tests: `runIO`-style discharge, a `Logger -> IO` translation, an abort handler (resume never called), a multi-shot handler (resume called twice).

### Task 5: Program entry + output
Resolve an entry binding (`main`), run it, render the result `Value`. Decide the effect story for `main` (e.g. a built-in `IO`-ish handler installed at the top, or require `main` to be pure for v1). Unit test: end-to-end on a small program.

### Task 6: Golden program-output corpus
Run the `test/typecheck-examples/*.wok` that are runnable (and a few new runnable fixtures) through `typecheck -> elaborate -> interpret`, golden the rendered result/stdout. Mirror the Scope B golden harness.

## Known hard parts / open questions for the next session
- **Multi-shot `resume` + host sharing:** `VCont` must be safely re-invocable; ensure captured `Env`s aren't mutated between invocations (they aren't, with persistent `Map`, but watch any added mutable state).
- **`main`'s ambient effects:** what handler(s) are installed at the top, and what `IO`-ish operations exist in v1 (likely a minimal `print`). Coordinate with `Builtins`/effect decls.
- **Tail behavior:** `Jump`/`LetJoin` and self-tail-calls should not grow unbounded host stack for loop-heavy programs; if it bites, trampoline the `step` loop (it's already small-step, so a `while` driver over `Config` suffices).
- **Typed values:** the interpreter is type-erased (matches Scope B). If a future need for runtime type info appears (it shouldn't for v1), revisit the elaborator's erasure decision.
