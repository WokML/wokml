# Design spec: named effect instances (type-directed dot)

Date: 2026-06-08
Status: **Design converged, ready for an implementation plan.** Branch `feat/named-capabilities`.

Supersedes the `&`-sigil iteration of this design (same branch, earlier commits) and the `@`-tag
surface of `docs/superpowers/specs/2026-06-07-tagged-effects-as-patterns-num.md` §1.

Reads with:
- Memories: `effect-naming-design-2` (the named-instance direction this refines),
  `effect-surface-syntax-final`, `effect-compilation-strategy`,
  `effects-slice-4a-parameterized-handlers`, `diamond-import-env-merge-coarseness`,
  `at-token-reserved-type-application` (note: this slice spends **no** new token).
- `docs/koka.md` §"Nested handlers of the same effect" — duplicate/scoped-label theory.
- `docs/superpowers/specs/2026-06-07-as-patterns-design.md` — the slice-process model.

---

## 1. Problem

Today a computation can hold only **one reachable instance** of a given effect. `findHandler`
(`src/Wok/Interp/Machine.hs`) routes an operation to the **nearest** handler covering
`(effect, op)`, so two stacked `State` handlers give one reachable cell, not two:

```
with state 0 in        -- a counter?
with state 0 in        -- a total?   both are just "State"; State.get hits the inner one
prog ()                -- the outer cell can never be reached
```

This is fundamentally about **in-language effects** — `State`, `Reader`, `Writer`, `Except`, and
any effect whose semantics live in a handler. wok is pure: it has no mutable reference, so a
`State` cell *is* its handler — there is no value that represents a mutable cell. Two independent
cells therefore must be two handlers, and the only way to address both is to **name** them. This
is the irreducible need the slice serves, and it has **no data-value alternative** (the closest is
one `State` over a record, which couples the cells — exactly what we're replacing).

> Scope note — what this slice is *not* for. Syscall-style resources (fds, file handles,
> connections) are usually *better* modelled as ordinary first-class data (a handle value) plus
> an ambient `IO` effect — which already works today and, unlike a scoped instance, is
> storable/returnable (good for pools). Reach for a *named effect instance* when you want the
> operations *handled* (mockable, test-doubled, deterministic-tested, scope-closed). See §2.2.

## 2. Decided direction — name the instance; its type is the effect; the dot is type-directed

Name each handler instance at its introduction, perform operations through that name, and let the
type of the name be **the effect itself**. There is **no sigil and no wrapper type**:

```
main =
  with count = state 0 in        -- introduce a named instance of State
  with total = state 0 in        -- a second, independent instance
  prog count total

prog : State U64 -> State U64 -> ()    -- the handle type IS the effect, in type position
prog count total =
  let _ = count.set (count.get + 1) in
  let _ = total.set (total.get + count.get) in
  ()
```

Three pieces make this work, all minimal:

- **`with name = runner … in`** introduces a named instance. The name (`count`) is a **handle**
  to that specific handler.
- **`name.op`** performs `op` through the handle. The dot is **overloaded and type-directed**: if
  the receiver's type is an effect (in type position) it is a *perform*; if a record, a *field
  projection*. This is resolved at **compile time** from the receiver's type.
- **The handle type is the effect application** (`State U64`) used in type position. No `&`, no
  `Cap`. An effect name in type position denotes "a handle to an instance of that effect."

### 2.1 The load-bearing finding: this is NOT duplicate row labels

The original spec assumed per-instance **row labels** (`State@count` as a distinct row atom),
which is the design that forces Koka-style **first-class evidence** + scoped labels + (for safety)
rank-2 — the thing wok forbids. Named instances point the other way:

- A named instance is a **second-class lexical binding**, **not** an atom in the ambient row.
- The **ambient row mechanism is unchanged** (`RowExtend "State" …`, nearest-handler routing). The
  untagged `State.get` / `with state 0 in` path is untouched — back-compat is free.
- A function operating on caller-supplied instances takes them as **ordinary annotated
  parameters** whose type is the effect. Operations through such a parameter **discharge** that
  effect, so it does **not** appear in the function's `with` row.
- Two `State U64` instances are two distinct **bindings/parameters**, trivially distinct, with
  **no duplicate row labels anywhere**. The runtime routes per-instance by a runtime id.

This keeps the type system HM + row-unification decidable and needs no first-class evidence. The
slice is a "named-binding-and-parameter change beside an unchanged row," not a row-system change.

### 2.2 Naming vs. distinct types are orthogonal — you need naming regardless

It is tempting to think "give the two states distinct types (`newtype Count`, `newtype Total`) and
you won't need to name them." **That is wrong, and the slice depends on the distinction.**

- **Naming is how you ROUTE.** It makes two instances *reachable*; without it the nearest-handler
  rule picks one and the other is unaddressable. This is the mechanism this slice builds, and it
  is **required** for multiple instances.
- **Distinct payload types is type SAFETY**, layered on top of naming. It stops you passing a
  count-cell where a total-cell is wanted. It does **nothing** for routing.

You do both: `with count = state (Count 0) in …` names the instance (so `count.get` routes to it)
*and* gives it a meaningful type. The reason types can't replace naming: "route by the effect's
type argument" (type-distinguished routing) doesn't exist (wok routes by effect *name*), still
needs runtime ids (types are erased), is ambiguity-prone (`get` is return-type-dispatched), and is
**incomplete** — two instances that genuinely share a type (two `U64` accumulators) can't be told
apart by type and need names regardless. So naming is the complete, simpler mechanism; type-
distinguished routing is a possible *future, complementary* convenience (§7), never a replacement.

The canonical "naming is the only answer" case — two instances of the *same* type:

```
sumProd : State U64 -> State U64 -> [U64] -> ()
sumProd sum prod xs = case xs of
  []        -> ()
  x :: rest ->
    let _ = sum.set  (sum.get  + x) in
    let _ = prod.set (prod.get * x) in
    sumProd sum prod rest
-- sum and prod are BOTH `State U64`. No distinct type exists for them — they ARE the same type.
-- Only the names tell them apart; routing follows `sum.set` vs `prod.set`, not any type.
```

### 2.3 Terminology and lineage — "named effect instance," not "capability"

Because the handle's type is just the effect, there is no separate "capability" concept to name —
`count` is simply a **named instance of the `State` effect**, and the docs/spec say exactly that:

- `with count = state 0 in …` — **introduce a named instance**.
- `count.get` — perform an operation **on that instance**.
- `State U64` (type position) — the type of an **instance handle**.
- second-class — describe it **directly**: "a handle is *scoped* to its `with` block; it can't be
  returned or stored."

This is, in the literature, a **second-class capability** (Effekt; the Haskell `capability`
package), kept as a one-line lineage note rather than a load-bearing term. The connection is exact
and worth recording: the `capability` package solves the same problem — multiple independent
effects of the same type — by tagging them at the **type level** (`HasState "foo" Int` vs
`HasState "bar" String`, selected with `@"foo"`). wok tags them at the **value level** (`count`
vs `total`, selected by the binder name). Same goal; value-level naming is the natural fit for
second-class effects and needs no `@tag` type machinery. *Named effect instances are the
value-level analogue of capability-style type tags.*

## 3. Surface syntax

### 3.1 Two introduction shapes — no sigil anywhere

```
with state 0 in body            -- UNNAMED: ambient routing, exactly as today
with count = state 0 in body    -- NAMED:   introduces an instance handle `count`
```

The named form binds `count` to the runner's instance handle for `body`. Distinguished from the
unnamed form by the `=` after `with VarId` (`=` cannot start a `WithArg`). There is **no `&`** and
no other marker — the difference is the `name =`.

### 3.2 Perform = type-directed dot

```
count.get          -- perform `get` through the handle `count` (routes to THAT instance)
count.set x        -- perform `set x`
prog count total   -- pass handles by name; plain application
```

`name.op` parses today as `EProj (EVar name) op` (`grammar/Wok.cf:342`) — **no grammar change at
the perform site**. The dot is dispatched by the receiver's type: an effect-in-type-position →
perform; a record → field projection. This is the same type-directed dispatch already used for
`State.get` (`EProj (ECon "State") "get"` is a perform because `State` resolves as an effect,
`Infer.hs:1536`); we generalise it to a receiver *variable* whose type is an effect handle.

### 3.3 The instance-handle type = the effect in type position

A handle's type is written as the bare effect application:

```
State U64          -- a handle to a State U64 instance
Reader U64         -- a handle to a Reader U64 instance
```

An effect name in type position denotes its instance-handle type. No new token, no wrapper. This
is a **pure type-checker interpretation** (`State U64` already parses as a type application; the
checker resolves `State` as an effect → handle type). The cost is a deliberate **dual reading**,
disambiguated by position (compiler-unambiguous, human-noticeable):

```
state : s -> (State s -> a with State s + eff e) -> (a, s) with eff e
--            ^^^^^^^ handle type (arg position)       ^^^^^^^ ambient effect (in the `with` row)
```

Second-class-ness is **not** shown in the syntax; it is surfaced through **diagnostics** (clear
"this is an instance handle and cannot escape its scope" errors), which is the accepted price of
the no-sigil design (see §2.3, §4.3). The common case has no collision — a handle parameter is
usually a *different* effect from the function's row, or the row is empty:

```
logged : State U64 -> () with IO     -- handle of State; ambient effect IO; no same-text clash
logged count =
  let _ = IO.print "bump" in
  count.set (count.get + 1)
```

### 3.4 The named-primitive handler form (library level)

A runner mints its own instance and hands it to the body:

```
with self = State { s = i ; get -> s ; set x k -> k x () ; v -> (v, s) } in c self
```

`with self = Effect { arms } in body` installs the handler, binds the handler's own instance
handle to `self`, and runs `body`.

### 3.5 The runner, in the prelude (ordinary wok)

One change per runner: the thunk receives the instance handle instead of `()`.

```
-- prelude/Std/Control.wok
effect State s = { get : s, set : s -> () }

state : s -> (State s -> a with State s + eff e) -> (a, s) with eff e
--            ^^^^^^^ was `()`; now the thunk receives the instance handle
state i c = with self = State { s = i ; get -> s ; set x k -> k x () ; v -> (v, s) } in c self
```

The same runner serves both forms:

```
with count = state 0 in body   ≡  state 0 (\count -> body)   -- names it
with         state 0 in body   ≡  state 0 (\_     -> body)   -- ignores it -> ambient routing
```

## 4. Type system

### 4.1 Effect-as-type, and the type-directed dot

- **Effect names resolve in type position** to an instance-handle type, represented internally as
  a dedicated type node / a flag on the effect's tycon (NOT a user-namespace data tycon). This node
  is **second-class** (§4.3) and dispatches the dot to a perform.
- **`EProj (EVar x) op` dispatch** (extend `Infer.hs:1557`):
  - if `x`'s type is resolved to an effect handle `E …`: **perform** `op` through `x` — resolve
    `op` to its declaring effect by the unique-op-name rule already used for unqualified handler
    arms (`effect-surface-syntax-final`: 0 matches = error, ≥2 = ambiguity error), constrain the
    op's arg/result types, **emit no ambient row entry** (handle-mediated effects are beside the
    row), and route at runtime by `x`'s instance id (§5).
  - if `x`'s type is a record: **field projection** (today's behaviour).
  - if `x`'s type is unresolved: emit an **`Accessor x op β`** constraint (β = result type) and
    continue; resolve it when `x`'s type is solved. If it would **generalize unresolved**, error
    ("ambiguous accessor on `x`; annotate its type"). Keeping resolution compile-time forbids
    generalizing over an unresolved accessor — otherwise one compiled function would have to serve
    both perform and projection, which needs a runtime dictionary (out of scope; see §7).
- **Elaboration** chooses perform-node vs projection-node from `x`'s solved type.

### 4.2 Handle parameters are annotated; they discharge, off-row

A parameter `c : State U64` means "operations through `c` are handled by the caller's instance."
Performs through `c` emit **no** ambient effect, so the function's `with` row omits `State`. Because
the dot is compile-time and not generalized over unresolved accessors (§4.1), a handle-taking
helper whose parameter type isn't otherwise determined **must be annotated**:

```
bump : State U64 -> ()        -- annotation supplies c's type; dot resolves to a perform
bump c = c.set (c.get + 1)

bump c = c.get                -- WITHOUT the annotation: ERROR — ambiguous accessor, annotate c
```

This is the no-sigil trade: instead of a `&` marker on the binder, a handle-taking helper carries a
type signature (commonly present anyway). Everything introduced by `with` needs neither — its type
is already known.

### 4.3 Escape safety — the carrier rule (type-based, bounded, decidable)

Second-class enforcement is a structural pass over **typed** bindings (no brands, no skolem-escape,
no rank-2). Because handles are second-class, scope is **syntactic** (the `in body` subtree / the
function body), so the check is local, modular, and finite — never a dataflow fixpoint.

- A **handle binder** is `with name = runner …` or a parameter/lambda binder whose type is an
  instance-handle type. The set of in-scope handle binders is finite and lexically known.
- A **carrier** is any expression whose free variables include an in-scope handle binder (a handle
  itself, or a closure capturing one).
- Rule: a carrier may appear **only** as the head of a `.op` perform or as an argument passed into
  a handle-typed parameter slot. It may **not** be returned, stored in a constructor/record/tuple,
  put in a list, **passed as a partial application that captures the handle**, or bound where it
  escapes. A partial application is a carrier because it is a closure of arrow type that has closed
  over the handle — `peek c` (with `peek : State U64 -> () -> U64` and `c` a handle) is a `() -> U64`
  value capturing `c`, which would perform `c.get` after the handler is gone; it is rejected exactly
  like an escaping lambda. (Calling it locally is fine — only the value's *escape* is the error.)

```
leaky    = with count = state 0 in count                  -- ERROR: handle escapes (returned)
boxed    = with count = state 0 in Some count             -- ERROR: handle stored in a constructor
escaping = with count = state 0 in \x -> count.set x       -- ERROR: closure capturing a handle escapes
partial  = with c = state 7 in peek c                      -- ERROR: partial app `peek c : () -> U64` captures c
listed   = with c1 = state 0 in
           with c2 = state 0 in [c1, c2]                  -- ERROR: handles can't be collected

ok = with count = state 0 in
  let f = \x -> count.set x in    -- f is a carrier, but stays local
  let _ = f 5 in
  count.get                        -- returns a U64 (not a carrier) -> allowed
```

Bounds/decidability: free-variable computation is one finite AST pass; the in-scope handle-binder
set is finite; functions are checked once against their signatures. Total cost is linear in program
size; HM is untouched. (Because cap-ness is now read off *types*, this pass runs after inference.)

### 4.4 Aliasing is permitted and well-defined (documented decision)

Handles of the same effect/payload share a type (`State U64`). **Instance identity is a runtime
property** (the id carried by the handle value), not a type property — exactly as two `Int`
parameters are distinguished by their values, not their (identical) types. Therefore:

```
add count total    -- two different instances
add count count     -- the SAME instance, aliased: permitted, well-defined (like duplicate `ref` args)
```

Aliasing is **sound** (routing by id is correct whether ids coincide or not); a function simply
cannot *assume* two same-typed handle parameters are distinct — the position ML/Haskell occupy with
mutable references. Forbidding aliasing (uniqueness/linear types) and type-level provenance (brands)
are separable future axes — see §7.

## 5. Runtime

The CEK machine is **purely functional** — `Config` carries no counter and there is no runtime
unique supply (confirmed in `Machine.hs`/`Value.hs`). So the instance id is **the handler's
self-binder `Unique`**, minted per `with self = Effect {…} in` *site* by the elaborator's existing
`State Int` fresh supply. No machine-level counter is added.

- The `Handler` IR node gains `hSelf :: Maybe Binder` (the self-instance binder). When `Handle e h`
  installs the `KHandle` frame, it binds `self` to `VInst (nameUniq selfBinder) tag` in `e`'s scope,
  where `tag = kontDepth k` is the **per-activation** tag (the `Kont` depth at install). The
  `KHandle` frame stores the same `tag` so dispatch can match it.
- A handle-routed op carries the **instance handle as an `Atom`**: `count.get -> ROp (Just (AVar
  count)) "State" "get" []`. At runtime, resolve the atom → `VInst uniq tag` → route by `(uniq, tag)`.
- An ambient op carries no instance: `State.get -> ROp Nothing "State" "get" []` (unchanged).
- `findHandler`: `Nothing` → nearest frame covering `(effect, op)` (today's behaviour);
  `Just (uniq, tag)` → the nearest frame whose `hSelf` `Unique == uniq` AND frame tag `== tag`,
  covering `(effect, op)`. The multishot re-install of a handler over a resume site preserves the
  ORIGINAL activation tag (read off the matched frame), so a handle captured in a resumed body still
  routes to its own activation.
- Dispatch is still one `Kont` walk. Evidence-index O(1) dispatch is the deferred compiled-backend
  optimisation (`effect-compilation-strategy`); `VInst` becomes an evidence index.

**Per-activation routing (Task 6 — the former "known limitation," now fixed).** The site `Unique`
alone collides when one runner site is activated twice and both activations coexist (nested) — e.g.
`with count = state 0 in with total = state 0 in …` mints both `State U64` cells at the prelude
`state`'s single `with self =` site, so a bare site id would route both `count` and `total` to the
nearer (inner) frame. The sound fix (anticipated in the original design) pairs the site `Unique`
with a runtime **`Kont`-depth** disambiguator computed at install: `VInst (uniq, depth)`. Coexisting
(nested) activations sit at strictly different depths, so they are told apart; sequential activations
may reuse a depth but never coexist, so the reuse is harmless. This is what makes the two-same-type
clincher (`sumProd : State U64 -> State U64 -> …`) route correctly through the prelude runner. The
eventual evidence-passing backend gives per-activation evidence for free, subsuming this tag.

> Soundness honesty: the invariant "coexisting same-site activations have distinct depths" rests on a
> *frozen* install-time tag matched against continuations that `findHandler`'s `above` rebuilds — it is
> **empirically** validated (nesting, deep sequential reuse, re-entry with a live outer handle,
> captured-handle-after-non-tail-resume, multishot, and named ≡ ambient under identical structure all
> route correctly), not formally proven. The airtight version is the evidence-passing backend. The
> separate nested-*same-effect* multishot non-enumeration (`test/run-examples/37-…`) is pre-existing and
> affects the unnamed/ambient path identically — named instances do not regress it.

## 6. Grammar

The whole `&`/sigil grammar is **gone**. Two small additions, then the standing BNFC discipline.

1. **Named introduction binder** (runner form), a bare `VarId` binder (never an `AtomPat`):
   ```
   EWithNamed.  Exp2 ::= "with" VarId "=" VarId [WithArg] "in" Exp ;   -- with count = state 0 in …
   ```
2. **Named primitive-handler form** (runner-author level):
   ```
   EWithNamedH. Exp2 ::= "with" VarId "=" ConId "{" [HandlerArm] "}" "in" Exp ;  -- with self = State {…} in …
   ```
   Both disambiguate from the existing unnamed `EWithRun`/`EWithH` by the `=` after `with VarId`.

No token is reserved; no `&`; `name.op` and `State U64`-as-a-type need **no** new productions
(both already parse — the work is in the type checker: resolve effect names in type position to
handle types, and dispatch the dot by receiver type).

Per the project discipline: `bnfc --haskell -d -p GeneratedParser --text-token -o src-generated
grammar/Wok.cf`, reapply the three existing manual patches (`grammar/Wok.cf:13-69`), and **confirm
the shift/reduce conflict count is unchanged**. Regenerate goldens with
`cabal run wok-tests -- --accept` after reading diffs.

## 7. Out of scope / deferred (forward-compatible)

- **Brands / type-level instance provenance** (a scope/region marker on the row, skolem-escape):
  decidable and bounded, but louder and harder; it buys escape-as-a-type-error, instance-documenting
  rows, and is the enabler for static-dispatch. The everyday surface is identical with or without it,
  so it's non-breaking future hardening.
- **Full no-annotation dot via runtime dictionaries** — make the overloaded dot work on *unannotated*
  parameters by passing an accessor dictionary (perform-vs-project chosen at runtime). Drops the
  annotation requirement of §4.2 but is *not* compile-time. A general "overloaded accessor" feature,
  separable from this slice.
- **Type-distinguished instances** (so `State Count` vs `State Total` need no name; §2.2) — routing
  by the effect's type argument. Separate, incomplete on its own, not in this slice.
- **Evidence-passing O(1) dispatch** — the compiled-backend target; `VInst` becomes an index.
- **Alias-freedom** (reject `add count count`) — uniqueness/linear types; a different axis,
  explicitly not wanted (aliasing-for-sharing is a feature).
- **Collections / dynamic pools** — `[State U64]` of handles is rejected (storing handles is escape).
  A collection of *resources* is better as plain first-class data (§1 scope note) or, for handled
  effects, the concurrency model (a fiber per instance) — the deferred scheduler/`Future` work.

### 7.1 `Control.wok` vocabulary to mine from the Haskell `capability` package (future)

`Control.wok` already has `Reader`/`State`/`Writer`/`Except`. Worth porting, in rough priority:
1. **`Throw`/`Catch` split of `Except`** — a throw-only `effect Throw e = { throw : e -> Never }`
   (a function that only fails advertises `Throw`, not catch), with `Catch` layered on.
2. **`Source`/`Sink` (streaming)** — `effect Source a = { await : a }` (pull) and
   `effect Sink a = { yield : a -> () }` (generator/push). These are the coroutine effects; they line
   up with the deferred scheduler/`Future` work (the `yield`/`await` control case).
3. **`local` for `Reader`** — run a sub-computation under a modified environment.
4. **`zoom`/focus runners** — derive a focused sub-instance (`State Field`) from a larger instance
   (`State Big`) via an accessor/lens — the value-level analogue of the package's deriving-via-lens.
   Needs lens/accessor support first; the most powerful idea to borrow for composing big state from
   independently-named sub-states.
5. **General-`Monoid` `Writer`** (already deferred, blocked on a `Monoid` class).

## 8. Testing strategy (TDD)

Unit / type-checker:
- `with count = state 0 in count.get` type-checks; two independent instances route independently.
- `prog : State U64 -> State U64 -> ()` checks; the two-same-type `sumProd` case runs correctly.
- Type-directed dot: a record receiver still projects; an effect-handle receiver performs.
- Annotation requirement: unannotated `bump c = c.get` errors with "ambiguous accessor, annotate";
  with the signature it checks.
- Handle parameter beside the row: `logged` infers/checks `… with IO`, State absent from the row.
- Unqualified-op resolution: ambiguous `op` (declared by ≥2 effects) errors; unique resolves.
- Carrier rule rejects: return, constructor-store, list, escaping closure (one golden each); allows
  local closure capture. Errors mention "instance handle cannot escape its scope."
- Aliasing: `add count count` checks and runs (well-defined).
- Back-compat: every existing effect example (untagged `with state 0 in`, `State.get`) stays green.

Parser / grammar:
- `with count = state 0 in …` and `with self = State {…} in …` parse; the unnamed forms still parse.
- Shift/reduce conflict count recorded and unchanged.

Runtime (`--run` / `--dump-anf`):
- Two `State U64` instances (`count`/`total`) produce two independent results; `sumProd` gives the
  right pair.
- Re-entry soundness: a function taking a handle param of `E` and re-installing its own `E` handler
  at the same source site routes the param to the outer instance (fresh-per-install ids).
- Aliasing: passing one instance as both arguments of a two-instance helper is well-defined.

Start state: 591 tests green (`cabal test`). Build: `cabal build`; run with
`cabal run -v0 wok -- <file.wok> --run | --dump-anf`.

### 8.1 Residual coverage gaps (revisit in a future pass)

The soundness-critical paths are covered (per-activation routing incl. re-entry `54`, 3-nested `55`,
multishot `56`, named-answers-ambient `57`, carrier reject/allow, the `with &x` parse guardrail). A
few lower-risk gaps remain — same machinery, so smoke-tests not new risk — to close later:

- **TWO DIFFERENT named effects coexisting in one scope** (e.g. a named `State` *and* a named `Reader`
  together, routing each op to its own instance). **Flagged for a future pass** — this is the
  cross-effect named-composition case (an mtl-style stack, but named), and it's where the future
  `Control.wok` vocabulary (§7.1) and any named-capability composition work will land. Not yet tested.
- Named `Reader` / `Writer` / `Except` per-effect smoke tests (only `State` is exercised end-to-end).
- Multishot with *two* named cells (only single-cell multishot is pinned by `56`).

## 9. Suggested slice order (decide in planning)

Each step is independently testable:
1. **Runtime instance ids** + the `with self = Effect {…} in` primitive (`EWithNamedH`) +
   `findHandler`/`dispatchOp` id routing. Untagged path unchanged.
2. **Type layer**: effect-names-in-type-position → handle types; type-directed `EProj` dispatch
   (perform off-row vs projection); the `Accessor` constraint + annotation requirement; unqualified-op
   resolution; the type-based carrier rule.
3. **Surface**: `EWithNamed` binder + runner desugar (`runner args (\name -> body)`), the prelude
   runner change.

Full-branch review before any merge to main (per-task reviews do not substitute).
