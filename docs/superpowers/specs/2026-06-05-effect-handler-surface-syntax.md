# Effect handler surface syntax: `with`-prefix handlers, auto-resume default, value operations

Date: 2026-06-05
Status: Design converged (from extended design conversation). Ready for slice planning.
Supersedes: the surface design in `2026-06-05-effect-handlers-unified-case-design.md`
  (which explored merging handlers into `case` with a mandatory continuation binder;
  both were rejected). The **Compilation and runtime model** section of that document
  remains current and is the lowering reference for this spec.
Related: `docs/koka.md`, `docs/superpowers/specs/2026-06-05-multi-clause-match-compiler-design.md`
Future module: `Control.Wok` (effect/handler prelude)

## Goals this design serves

- **Decidable** type inference, **deterministic** semantics (all nondeterminism is
  reflected in the effect row, so "deterministic" stays checkable), **algebraic
  effect handlers** as the single control mechanism.
- Keyword-light surface: no `fun`/`ctl`; the tail-resumptive vs control distinction
  is read off the arm shape. Analysis over annotation.
- **Flat** handler stacking -- no nesting pyramids.
- Async/await, concurrency, generators are ordinary effects, not new syntax.

## 1. Effect declarations, with value operations

An operation that takes a real argument keeps its arrow; a nullary operation is
declared as a **value operation** (no arrow) so its use site needs no `()`.

```
effect Ask    = { ask : U64 }                  -- value op: referenced as `Ask.ask`
effect State s = { get : s, set : s -> () }      -- get is a value op; set takes an arg
effect Exn    = { throw : String -> a }          -- result `a` (op-quantified, result-only)
                                                 --   marks throw as NON-RETURNING
effect Choice = { flip : Bool }
effect Async  = { await : Future a -> a }
```

Note: wok is strict. `() -> U64` is not a thunk; it was only a unit-encoding of a
nullary operation. Value operations remove that encoding. Referencing a value
operation (`Ask.ask`) **performs the effect** each time it is evaluated (it is a
request to the handler, like Koka's `val` operations, not a stored value).

An operation whose declared result type is a type variable bound by the operation
and occurring only in result position (e.g. `throw : String -> a`) is a
**non-returning** operation; this is used by the lint in section 8.

## 2. Effect rows in types (unchanged)

```
useAsk : () -> U64 with Ask
both   : () -> U64 with Ask + State U64
runIO  : (() -> a with IO + eff e) -> a with eff e     -- `eff e` is the polymorphic tail
```

A handler discharges its effect label(s) from this row; the `eff e` tail rides
through unchanged.

## 3. Performing effects: direct, flat, no ceremony

Operation calls are ordinary expressions; value operations are bare references.
The row tracks effects automatically. There is **no** do-notation and no `await`
keyword -- effects are not monads, so nothing needs `<-` sequencing.

```
useAsk u = Ask.ask + 1                    -- : U64 with Ask
both u    = Ask.ask + State.get           -- : U64 with Ask + State U64
fetch url = Async.await (httpGet url)     -- : String with Async
```

Evaluation is left-to-right and **sequential**. Effects do not parallelize
themselves; overlap is requested explicitly (section 7).

## 4. Handling effects: the `with` prefix

`with` is the **only** handler construct. `handle`/`return` do not exist. A
`with` installs a handler over the rest of the enclosing block:

```
main =
  with { Ask.ask -> 41 }      -- handler block
  useAsk ()                   -- the handled computation (rest of block) -> 42
```

### 4.1 Scope rule (load-bearing)

> A `with` handler scopes from its line to the **end of the enclosing block**.
> **Function bodies and lambda bodies are blocks.** A `with` scopes the executed
> expression sequence of the block, not lazy `where`/`let`-rec definitions. A
> `with` that is the last element of a block (no following computation) is an error.

The lambda clause is what makes per-region handling work without a dedicated
bounded form:

```
serveAll reqs =
  forEach reqs (\req ->
    with { Exn.throw msg k -> logError msg }   -- scoped to THIS lambda; one failure stays local
    handleRequest req)
```

To bound a handler to less than a whole body today, extract a helper function (or
a lambda) whose body is the handled computation. The dedicated bounded form
`(with H ; e)` is a deferred, purely additive follow-up (section 10).

### 4.2 Stacking is flat

```
main =
  with { Ask.ask   -> 41 }
  with { State.get -> 0  }
  prog ()
```

Ordering rule:

> Handlers listed top-to-bottom are outermost-to-innermost. `with A ; with B ; e`
> means `B` is the inner (nearer) handler. An operation resolves to the **nearest**
> (lowest) matching handler; effects bubble upward. Reordering `with` lines changes
> nesting and therefore meaning.

A single `with` block may carry arms for several effects and discharges all of
them in one frame (no nesting needed for co-handled effects).

### 4.3 Optional effect header

Arms are dot-qualified by default. An optional header names the handled effects
and lets arms in that block drop the qualification:

```
with State { get   -> 0           -- unqualified: header says State
             set s -> () }
prog ()
```

> Within `with E1 E2 ... { ... }`, an unqualified operation name resolves to
> whichever listed effect declares it; an ambiguous name is an error (re-qualify
> to fix). The header is also a coverage contract: it asserts the block handles
> exactly those effects.

The header is optional sugar; headerless dot-qualified arms are always valid and
are the form to use for multi-effect blocks with name collisions.

## 5. Operation arms: auto-resume by default, bind to take control

This is the core rule.

> **No continuation binder -> the arm auto-resumes (tail-resumptive).** The body
> has the **operation's result type** and is implicitly resumed. This is the
> common case and cannot accidentally abort.
>
> **A continuation binder present (`Op.x args k -> ...`) -> the arm takes
> control.** The body has the **handler's answer type** `R`, and the body decides
> resumption by calling the binder zero times (abort), once, or many (multi-shot).
> The binder is an ordinary name you choose; `resume` is merely a conventional
> choice. There is no magic in-scope `resume`.

```
-- DEFAULT (no binder): auto-resumed; body is the operation's result type
IO.read p  -> p
State.get  -> currentState

-- OTHERWISE (bind the continuation): body is the answer type R
Exn.throw msg k -> None                          -- bind, never call  = abort (0x)
Ask.ask k       -> k 41                           -- call once         (rare; only if non-tail)
Choice.flip k   -> append (k True) (k False)      -- call twice        = multi-shot (Nx)
Async.await fut k -> Blocked fut k                -- hand off, resume LATER = async (deferred 1x)
```

The body-type mode is cued locally and visibly by the presence of the binder, so
there is no invisible rule and no silent mode mismatch.

Whether an operation needs a binder is a property of the **handler**, not the
operation: the same `await` can have a blocking handler (`Async.await fut ->
forceNow fut`, no binder, auto-resumed) or an async handler (binds and defers).

## 6. Value arms: optional, identity by default

Value arms say what to do with the computation's final value (the old "return"
clause). They are ordinary patterns. The `return` keyword does not exist.

> The value arm is **optional**. Omitting it means an identity return, which
> requires the computation's result type `A` to equal the answer type `R`. Write
> a value arm only to **reshape** the result (`A != R`).

```
-- forwarding handler: A = R, no value arm needed
runIO comp =
  with { IO.read p  -> p
         IO.write m -> () }
  comp ()

-- reshaping handlers: A != R, value arm required
toOption comp =
  with { Exn.throw msg k -> None
         v               -> Some v }     -- A = a, R = Option a
  comp ()

search comp =
  with { Choice.flip k -> append (k True) (k False)
         v             -> [v] }          -- A = a, R = List a
  comp ()
```

Value arms may be full patterns (multiple value arms, first-match), so a handler
can pattern-match the result directly. Operation arms fire on **perform**, value
arms fire on **return** -- disjoint events sharing one block; ordering between the
two kinds is irrelevant, only ordering among value arms matters.

## 7. Async, concurrency, parallelism

`await`/`spawn`/`par` are ordinary operations written in direct style; there is no
function coloring (async-ness is just `Async` in the row, composed by row
polymorphism, not a viral keyword).

```
prog u    = fetch "/x" ++ fetch "/y"                       -- SEQUENTIAL
parProg u =
  (x, y) = Async.par (\_ -> fetch "/x") (\_ -> fetch "/y")  -- overlap is EXPLICIT
  x ++ y
```

- Sequencing is sequential; concurrency/parallelism is opt-in via `spawn`/`par`.
- Concurrency and parallelism share the same surface; the difference is which
  scheduler handler is installed (single-thread interleave, multi-core, or a
  deterministic test scheduler).
- A scheduler whose result can depend on completion order performs the **`ndet`**
  effect, so it shows in the row and "deterministic" remains checkable.
- The async/generator pattern (`Op.x args k -> hand k off`) is the deferred-resume
  case of section 5: bind the continuation, do not call it in the arm, let the
  scheduler resume it later. It composes with the `with`-prefix because the
  captured continuation re-installs its handler on resume (deep handlers).

The scheduler, `spawn`/`par`, the `Future` primitive, and `Control.Wok` are
deferred (section 10).

## 8. Coverage and the forgotten-resume lint

Two checks run side by side: value arms exhaustive over `A` (the match-compiler
usefulness pass), and operation arms cover every operation of each handled effect
(`HandlerCoverage`).

The auto-resume default removes the "forgot to resume in a forwarding handler"
footgun entirely (forwarding is the no-binder default and cannot drop the
continuation). A narrow, optional lint remains for the control case:

> **forgotten-resume lint:** if an operation arm binds a continuation `k`, the
> binder is **not referenced anywhere in the body**, and the operation is a
> *returning* operation (section 1), warn: the continuation is discarded -- did
> you mean to resume, or to abort? Suppress an intentional abort with `discard`.

The trigger is binder-**unreferenced**, not binder-never-called: an escaping
continuation (`Async.await fut k -> Blocked fut k`) references `k` and never
warns. A non-returning operation (`throw`) is exempt, so genuine exceptions do not
warn. `discard` is a lint suppressor, not a semantic keyword.

## 9. `case` is unchanged

`case e of { pat -> ... }` remains pure value pattern-matching. It never takes
operation arms and never runs its scrutinee under a handler. No dual mode.

## 10. Lowering (reference) and goal alignment

Lowering is unchanged from the predecessor's **Compilation and runtime model**
section: `with { arms } rest` lowers to the existing `Handle`/`Handler` ANF nodes
with `rest` as the handled computation; value arms reuse `Wok.IR.Match`. The
runtime (`dispatchOp`, deep reusable `VCont`) is unchanged.

The auto-resume default aligns directly with contification: **no-binder arms are
syntactically tail-resumptive and contify to a jump with no analysis**; only
binder arms need the escape + multiplicity analysis to choose contify vs reify.

Goal checks: **decidable** -- handlers are second-class (they appear only in
`with`, are not first-class values), keeping inference HM + row unification.
**Deterministic** -- nondeterminism (incl. racy scheduling) is a row effect.
**Effect handlers** -- the one mechanism for all of the above.

## 11. Deferred (additive, no lock-in) and non-goals

Deferred, each purely additive:

- **Bounded handler scope `(with H ; e)`** -- recover today via helper/lambda
  (their bodies are blocks). Bounded scope already exists semantically via lambda
  bodies; this is only nicer syntax for it.
- **Parameterized handlers** (`handler(s){...}`) for clean stateful `State`. The
  `State` arms above illustrate operation syntax, not yet a state-threading
  handler.
- **Scheduler / `spawn` / `par` runtime**, the `Future` primitive, `Control.Wok`
  standard effects.
- **One-shot multiplicity check + value restriction enforcement** (generalize
  only at `<>`), gated on the ANF analysis phase. The flagship checked property is
  one-shot `resume`; double-resume of a one-shot continuation is a compile error.
- **Cancellation** (discontinue): a continuation is consumed by `resume` XOR
  cancel; the one-shot analysis must be designed for both, not resume-only.

Non-goals (per predecessor): scoped/higher-order operations (`catch`, `local`,
`mask`) as operations; effect masking/aliases/`inject`.

## 12. Known sharp edges (accepted)

- **Layout determines handler scope.** Adding a line at the bottom of a block puts
  it under the `with`s above; reordering `with` lines changes meaning. Needs editor
  support to visualize handler scope.
- **A `with` line can change the block's result type** (a reshaping value arm
  applies to the whole rest of the block). At top level this is intended; combined
  with the deferred bounded form, reshaping handlers that must be unpacked
  mid-function require a helper.
- **Two body-type modes** for operation arms (op-result vs answer type). Mitigated
  by the visible binder cue.
- **Async storage needs existentials** for heterogeneous parked continuations;
  mitigated by making `Future` a runtime primitive (the type is hidden in callback
  registration). A pure-ADT scheduler needs existential support -- deferred with
  the runtime.

## 13. Suggested slices

1. Value operations + the `with`-prefix handler with auto-resume default and
   binder-control (sections 1, 4, 5, 6). Drop `handle`/`return`. Smallest unit
   that unlocks exceptions, multi-shot, and the async *shape* (without a runtime).
2. Optional effect header (section 4.3) and the forgotten-resume lint (section 8).
3. Bounded `(with H ; e)` form (section 11).
4. Parameterized handlers; then the scheduler, `Future`, and `Control.Wok`.
