# Algebraic effects and handlers — surface design

Status: draft (rev 2 — surface-language focus; implementation deferred)
Owner: zy
Date: 2026-05-27 (rev 2: 2026-05-27)

> **Scope note (rev 2):** this spec captures the SURFACE LANGUAGE design for effects. Implementation work (runtime semantics, continuation capture, compilation strategy) is deferred until row polymorphism for records is correct and validated. The phased plan in this spec remains accurate, but Phase 1 (typechecker) and Phase 2 (runtime) should not be started until the records spec ships and stabilizes.
>
> The reason for this ordering: records and effects share row machinery. Validating Leijen 2005 unification in the simpler records context first — where the operational semantics is trivial (immutable allocation) — surfaces any issues before they propagate to the harder effects context (continuation-passing runtime).

## Motivation

Wok's HM core (`docs/superpowers/specs/2026-05-25-hm-core-design.md`) pre-wired the type system for row-polymorphic effects: `TArr (Type s) (Row s) (Type s)` carries an effect-row slot, `KEffect` kind is reserved, `unifyRow` exists as a stub, `Row`/`RVar` AST nodes are in place. None of this is reachable from surface syntax; it has been sitting dormant waiting for an effects spec.

This spec lights up that machinery. It defines:
- **Effect declarations** (`effect IO = { ... }`).
- **Effect-annotated arrows** (`A -> B with E`).
- **Effect handlers** (`handle expr with arms`).
- **Operation invocation** via qualified syntax (`IO.read path`).
- **Row-polymorphic effect inference** using Leijen 2005's scoped-label unification (shared with the records spec).

The design rejects monads at the language level. Wok with effects has no `Monad` class, no `do`-notation, no `>>=` operator, no `return`/`pure`. Sequential side-effecting code is written with `let` chains and direct operation calls. This is a significant simplification — Wok avoids the entire MTL/transformer ecosystem complexity.

The design borrows from Koka (Leijen's reference implementation) in theory and from production effects languages in pragmatic choices (one-shot continuations, qualified operation names, explicit handlers).

## Goals

- **Effect declarations** that name an effect and list its operations:
  ```wok
  effect IO = 
    { read  : String -> String
    , write : String -> ()
    }
  ```
- **Effect-row annotations on function arrows** using a trailing `with` clause:
  ```wok
  read : String -> String with IO
  ```
- **Effect composition** via `+` (same operator as record extension; different syntactic position):
  ```wok
  process : String -> String with IO + Logger
  ```
- **Row polymorphism** with named row variables for preserving effects across function calls:
  ```wok
  withTrace : (() -> a with Logger + e) -> a with Logger + e
  ```
- **Operation invocation** via qualified syntax — `IO.read path` not `read path`:
  ```wok
  greet name = IO.write ("Hello, " ++ name)
  ```
- **Effect handlers** introduced by `handle ... with` blocks:
  ```wok
  runIO : (() -> a with IO + e) -> a with e
  runIO comp = 
    handle comp with
      IO.read path -> resume (readDisk path)
      IO.write msg -> resume (print msg)
  ```
- **One-shot continuations** as the default semantics for `resume`. Multi-shot deferred.
- **Operation distinction** (`fun` vs `ctl`) for transparent vs control operations. Recommended; not required for v1.
- **Final-value transform via `return` clause** in handlers.
- **Soundness inherited from Leijen 2005 + 2017** — row-typed effects with scoped-label unification are sound under Wok's existing design constraints.

## Non-goals (deferred)

- **Multi-shot continuations** — handlers that resume the captured continuation more than once (needed for non-determinism, backtracking). Operationally expensive; defer to a later spec with explicit `ctl-multi` marker.
- **Effect masking / `mask`** — Koka's mechanism for hiding effects from handlers. Complex; defer.
- **Effect aliases / synonyms** — `effect Net = IO + Sockets`. Useful sugar; defer.
- **Effect inheritance / sub-effects** — beyond simple row union. Not in scope.
- **Anonymous effect declarations** — every effect has a nominal name (declared via `effect`).
- **Dynamic effect dispatch** — first-class effect values that can be runtime-selected. Out of scope; effects are static.
- **Higher-rank effect quantifiers** — `forall e. (... with e)` under arrow positions. Rank-1 only.
- **Effect-row equality constraints** — `e1 ~ e2` constraints in typeclass form. Possible future feature.

## Surface syntax

### Effect declarations

```wok
effect IO = 
  { read  : String -> String
  , write : String -> ()
  }

effect Logger = 
  { log : String -> ()
  }

effect State a = 
  { get : () -> a
  , set : a -> ()
  }

effect Random = 
  { next    : () -> U64
  , bounded : U64 -> U64
  }

effect Exn e = 
  { ctl throw : e -> a              -- ctl = control operation; may not resume
  }
```

**Body syntax:** brace-delimited, comma-separated, parallel to `data` and `class` declarations. Three kinds of entries:
1. **`fun` operations** (default; transparent — handler arm's return value auto-resumes):
   ```wok
   { fun read : String -> String, fun write : String -> () }
   ```
   The `fun` keyword is optional; bare operation sigs default to `fun`.

2. **`ctl` operations** (control — handler arm has access to `resume` explicitly):
   ```wok
   { ctl throw : String -> a }
   ```
   The handler arm body decides whether to call `resume` or not. Calling `resume` continues; not calling it exits the handler with the arm's result as the final value.

3. **Type parameters** on the effect name itself: `effect State a = { ... }` parameterizes by the state type.

### Effect-annotated arrows

```wok
-- Pure (no effects):
add : U64 -> U64 -> U64

-- Single effect:
read : String -> String with IO

-- Multiple effects:
greet : String -> () with IO + Logger

-- Row-polymorphic:
withTrace : (() -> a with Logger + e) -> a with Logger + e

-- Empty effect row (explicit pure; rarely needed):
trivial : U64 -> U64 with {}
```

**Precedence:** `with` binds **looser than `->`**. So `A -> B with E` parses as `(A -> B) with E`. For multi-arrow:

```wok
f : A -> B -> C with IO                 -- parses as: (A -> B -> C) with IO
                                          -- f a b's calls perform IO
g : A -> (B -> C with IO)                -- explicit parens: g a is an IO-effectful function
```

**Empty row `with {}`** — explicit form for documentation when pure-vs-effectful matters at the boundary. Generally omit `with` clause entirely for pure functions.

### Effect composition

`+` composes effects (set union, commutative, idempotent):

```wok
IO + Logger                              -- IO and Logger effects
IO + Logger + Random                     -- three effects
IO + e                                   -- one concrete effect plus row variable
```

The same `+` operator is used for record extension at the type level. Different syntactic position:
- Record extension: `TypeName + RowOrConcrete` in a regular type position.
- Effect composition: inside a `with` clause, between effect names and row variables.

Parser/grammar distinguish via position.

### Operation invocation

Qualified syntax — `EffectName.opName` — using existing `EProj` grammar:

```wok
greet : String -> () with IO + Logger
greet name =
  Logger.log ("greeting " ++ name)
  IO.write ("Hello, " ++ name)
```

The typechecker recognizes `IO` as an effect-type name and `write` as one of its operations. Generates the appropriate effect constraint on the calling context (must be in a function with `IO` in its `with` clause).

**Why qualified:** unqualified `write` would collide with regular functions (and with other effects' operations). Qualified form makes the effect-source explicit.

### Handlers

```wok
runIO : (() -> a with IO + e) -> a with e
runIO comp = 
  handle comp with
    IO.read path -> resume (readFromDisk path)
    IO.write msg -> resume (writeToStdout msg)

runStateInt : (() -> a with State U64 + e) -> a with e
runStateInt comp = 
  var current = 0
  handle comp with
    State.get () -> resume current
    State.set n  -> current := n
                    resume ()
    return v     -> v                        -- optional final-value transform
```

**Handler syntax:**
- `handle expr with arms` — the handle keyword introduces the form. `expr` is the computation to handle (a thunk typically); `arms` are pattern-matched operation handlers.
- Each arm: `EffectName.operationName args -> body`.
- The arm body uses `resume value` to continue the continuation with `value` as the operation's result. Not calling `resume` exits the handler with the arm's return as the final value.
- Optional `return v -> body` arm transforms the final return value.

**Return arm:**
```wok
runCountedIO : (() -> a with IO + e) -> (a, U64) with e
runCountedIO comp = 
  var count = 0
  handle comp with
    IO.read path -> count := count + 1
                    resume (readDisk path)
    IO.write msg -> count := count + 1
                    resume (print msg)
    return v     -> (v, count)
```

The `return` arm wraps the final value (after all operations are handled) with the running count.

### Stacking handlers

```wok
main : () -> () with {}
main () = 
  runIO (\() ->
    runLogger (\() ->
      runStateInt (\() ->
        businessLogic ())))
```

Each `runXxx` discharges one effect; the innermost computation has all the effects, the outermost has none. Handlers compose left-to-right (or innermost-first reading order, depending on style).

## Grammar additions

```bnfc
-- Effect declarations:
DEffect.       Decl ::= "effect" ConId [VarId] "=" "{" [EffectEntry] "}" ;

EEFun.         EffectEntry ::= "fun" VarId ":" Type ;                  -- transparent
EECtl.         EffectEntry ::= "ctl" VarId ":" Type ;                  -- control
EEBare.        EffectEntry ::= VarId ":" Type ;                        -- defaults to fun
separator      EffectEntry "," ;

-- Effect-annotated arrows:
TFunEff.       Type ::= Type1 "->" Type "with" EffectRow ;             -- a -> b with E

-- Effect row syntax (set/union with `+`):
EREmpty.       EffectRow ::= "{" "}" ;                                  -- empty effect set
ERCon.         EffectRow ::= EffectAtom ;
ERPlus.        EffectRow ::= EffectAtom "+" EffectRow ;
ERVar.         EffectRow ::= VarId ;                                    -- row variable alone

EAEffect.      EffectAtom ::= ConId [Type2] ;                           -- effect name with type args (e.g. State U64)

-- Handlers:
EHandle.       Exp2 ::= "handle" Exp "with" "{" [HandlerArm] "}" ;     -- handle expr with { arms }
HandlerArm.    HandlerArm ::= ConId "." VarId [AtomPat] "->" Exp ;     -- IO.read path -> ...
HReturn.       HandlerArm ::= "return" VarId "->" Exp ;                -- return v -> ...
separator      HandlerArm ";" ;
```

**Precedence:**
- `with` (in `TFunEff`) is looser than `->`. `A -> B with E` = `(A -> B) with E`.
- `+` (in effect rows) is left-associative.
- `EAEffect` allows type arguments to effects (e.g. `State U64`, `Reader Config`).

**Token additions:** `effect`, `handle`, `with`, `resume`, `fun`, `ctl`, `return` are new keywords. (`with` is shared with sig position; `fun`/`return` are inside effect/handler bodies only.) `with`/`return` overload with potential future uses — currently free.

LALR(1) safety: each new production starts with a distinct keyword (`effect`, `handle`, `with` after a type) so disambiguation is clean.

## Type system additions

### Effect environment

Extend `Env` to track declared effects:

```haskell
data Env = Env
  { ...
  , envEffects :: Map Text EffectInfo
  }

data EffectInfo = EffectInfo
  { eiParams :: [(Text, Kind)]                                 -- e.g. [("a", KStar)] for State a
  , eiOps    :: Map Text (OpKind, Scheme)                      -- operation -> (Fun|Ctl, operation type)
  }

data OpKind = OpFun | OpCtl
```

### Effect-row representation

Already in `Wok.TypeChecking.Types`:

```haskell
data Row s
  = RowEmpty
  | RowExtend Text (Type s) (Row s)                            -- existing; same as records use
  | RowVar (STRef s (RVar s))
```

For effects, `RowExtend "IO" effectTypeArg rest` represents "the row contains the IO effect, with effectTypeArg as the parameter applied to it (or unit if IO has no type params), and the rest of the row."

Effects are stored in the row by their nominal name. Multiple effects compose as nested `RowExtend`s. Order within the row doesn't matter semantically — Leijen's scoped-label unification handles canonicalization.

### Effect-row construction at sig translation

When `translateSig` encounters a `with` clause:
```haskell
translateSig env (Abs.TFunEff t1 t2 effectRow) = do
  innerT1 <- translateType env t1
  innerT2 <- translateType env t2
  rowCType <- translateEffectRow env effectRow
  pure $ Scheme [] (CTArr innerT1 rowCType innerT2)

translateEffectRow env Abs.EREmpty = pure CREmpty
translateEffectRow env (Abs.ERVar (Abs.VarId (_, name))) = ...  -- row var
translateEffectRow env (Abs.ERPlus atom rest) = ...
translateEffectRow env (Abs.ERCon atom) = ...
```

The result is a `CRow` (closed form) embedded in the `CTArr`'s middle position.

### Effect-row in inference

When `inferExprW` encounters an operation invocation `EProj (ECon "IO") (VarId "read")`:
1. Look up `"IO"` in `envEffects`. If found, this is an operation.
2. Get the operation's scheme from `EffectInfo.eiOps`.
3. Instantiate it as the function's type.
4. **Crucially**, the call site's effect row must contain `IO`. The typechecker adds a constraint: "the current function's effect row must include `IO`."
5. Constraint discharge: at let-generalization, the accumulated effect requirements become the function's `with` clause.

For row-polymorphic preservation:
- If the calling function's sig is `(() -> a with IO + e)`, the row variable `e` is bound at the sig boundary. Operation calls inside this function add to the row variable's known minimum effects.
- The inferred sig (if no explicit sig) would naturally have all the effects called.

### Handler typechecking

`handle expr with arms` introduces a typing context that **discharges** some effects:

- The arms specify which operations are handled. Their operation effects are removed from the inner-computation's effect row.
- The result of `handle expr` has the inner row MINUS the handled effects.

For `runIO : (() -> a with IO + e) -> a with e`:
- Inner computation has effects `IO + e`.
- The `IO.read` and `IO.write` arms discharge `IO`.
- Result has effects `e` (whatever wasn't discharged).

Implementation:
- Typecheck the body's expected type, capturing its effect row.
- Verify all `IO` operations are matched by handler arms (exhaustive: every `IO` operation must have an arm).
- Strip the discharged effects from the row.

### `resume` typing

Inside a handler arm, `resume` is a built-in function with type:
- For `fun` operations: `resume : ReturnType -> ResultOfHandler` (where `ReturnType` is the operation's result type).
- For `ctl` operations: `resume : ReturnType -> ResultOfHandler` (same signature, but calling `resume` is optional).

If the handler arm doesn't call `resume`, the arm body's value becomes the final result of `handle` (used for early-exit semantics like exceptions).

### Soundness — inheritance from Leijen 2005 + 2017

- **Leijen 2005** provides soundness for scoped-label row unification (used for both records and effects' row machinery).
- **Leijen 2017** ("Type Directed Compilation of Row-Typed Algebraic Effects") proves Progress + Preservation for the effect-row + handler system specifically.

Wok's design constraints (no subtyping, immutable values, rank-1 HM, scoped labels for row unification) align with the preconditions of both proofs.

## Implementation strategy — phases

### Phase 1 — Surface + typechecker (no runtime semantics yet)

1. Grammar additions for effect declarations, handlers, effect-annotated arrows. Regenerate parser.
2. Add `envEffects` to the typing environment.
3. Implement `translateEffectRow` and integrate into `translateSig`.
4. Implement operation-invocation typing (recognize `EProj ECon VarId` as a possible operation; constrain effect row).
5. Implement handler typechecking (verify arm coverage; discharge effects from row).
6. Implement effect-row constraint propagation through let-generalization.
7. Replace `unifyRow` stub with Leijen 2005 algorithm (shared with records; can be done as a single step alongside the records spec implementation).

At this phase, effect-typed programs typecheck but don't RUN. Operations and handlers have no runtime behavior. Useful for catching type errors but not yet executable.

### Phase 2 — Runtime semantics

Implementing the actual semantics requires:
1. **Operation invocation** — at the AST level, an operation call needs to capture the current continuation.
2. **Handler stack** — at runtime, the program has a stack of active handlers; operations search the stack for the closest matching handler.
3. **One-shot continuations** — `resume value` re-enters the captured continuation. One-shot means the continuation is consumed and can only be called once.
4. **Compilation strategy** — either:
   - **CPS transformation** — compile effectful programs to continuation-passing style; operations become calls into the active handler.
   - **Algebraic effect compilation** — Leijen 2017's compilation scheme; uses a stack discipline with explicit jumps.

The compilation strategy is a substantial undertaking. v1 might use the simpler CPS approach; production might want the more efficient algebraic-compilation strategy.

This phase is OUT OF SCOPE for the type-system spec. A separate runtime spec will cover it.

### Phase 3 — Standard-library effects

Once Phase 2 ships, populate `Std.Base` (or a separate `Std.Effects` module) with common effects:
- `Std.IO` — read/write, file IO, stdin/stdout
- `Std.State a` — get/set
- `Std.Reader r` — ask
- `Std.Writer w` — tell
- `Std.Exn e` — throw / catch
- `Std.Choice` — non-determinism (defers to multi-shot)
- `Std.Random` — random number generation

Plus handlers for each: `runIO`, `runState`, `runReader`, `runWriter`, `runExn`, etc.

## Test plan

### Phase 1 (typechecker only) tests

| Test | Asserts |
| --- | --- |
| `parseEffectDecl` | `effect IO = { read : ..., write : ... }` parses and round-trips |
| `parseEffectfulArrow` | `String -> String with IO` parses |
| `parseEffectComposition` | `with IO + Logger + e` parses correctly with `+` left-assoc |
| `parseHandlerBlock` | `handle expr with IO.read p -> body; IO.write m -> body2` parses |
| `parseFunCtlOps` | `effect E = { fun foo : ..., ctl bar : ... }` parses |
| `typecheckPureFunction` | `add : U64 -> U64 -> U64` has empty effect row |
| `typecheckEffectfulFunction` | `read : String -> String with IO`'s body must invoke IO; typechecks |
| `typecheckEffectConstraintPropagation` | If `f` calls IO, then any caller of `f` must have IO in its effect row |
| `typecheckRowPolymorphism` | `(() -> a with E + e) -> a with e` properly tracks row variable |
| `typecheckHandlerCoverage` | Handler that omits one operation arm errors (or is rejected) |
| `typecheckHandlerDischarge` | After `handle`, the discharged effects are removed from the row |
| `typecheckOperationQualified` | `IO.read` is recognized as an operation; unqualified `read` not |
| `typecheckMissingEffectDecl` | `with FooBar` where `FooBar` is not declared as an effect → error |
| `typecheckEmptyEffectRow` | `with {}` parses and typechecks as pure |

### Phase 2 (runtime) tests

Defer; covered in a separate runtime spec.

### Golden tests (Phase 1)

- `23-effects-decl.wok` — declaring effects
- `24-effects-sigs.wok` — effect-annotated function sigs
- `25-effects-handlers.wok` — handler block syntax and inference
- `26-effects-polymorphism.wok` — row-polymorphic effects
- `27-effects-multi.wok` — composing multiple effects

## File / module changes summary

### Phase 1 (typechecker)

| File | Action |
| --- | --- |
| `grammar/Wok.cf` | Add `DEffect`, `TFunEff`, `EHandle`, effect-row productions, handler arms; new keywords `effect`, `handle`, `with`, `fun`, `ctl`, `return`, `resume` |
| `src-generated/GeneratedParser/Wok/*` | Regenerate via BNFC |
| `src/Wok/TypeChecking/Types.hs` | Already has `Row`/`RVar`/`CRow`/`CRGen`; no additions needed |
| `src/Wok/TypeChecking/Env.hs` | Add `envEffects :: Map Text EffectInfo`; add `EffectInfo` type |
| `src/Wok/TypeChecking/Infer.hs` | Add `processEffectDecls`, operation-invocation case in `inferExprW`, `inferHandler`, effect-row translation in sig walker; integrate with constraint accumulator |
| `src/Wok/TypeChecking/Unify.hs` | Replace `unifyRow` stub with Leijen algorithm (shared with records spec) |
| `src/Wok/TypeChecking/Error.hs` | Add `MissingEffectDecl`, `UndischargedEffect`, `HandlerCoverage`, `UnknownOperation` error variants |
| `prelude/Std/Base.wok` | Optional: declare basic effects (`IO`); their runtime is Phase 2 |
| `test/typecheck-examples/` | New fixtures per test plan |
| `test/Spec.hs` | Effect-typing unit tests |

### Phase 2 (runtime)

Separate spec; substantial work involving compilation strategy decisions.

## Comparison to Koka

For reference, since Wok's design borrows substantially from Koka:

| Aspect | Koka | Wok |
| --- | --- | --- |
| Effect declaration | `effect Name { ... }` | `effect Name = { ... }` |
| Function type with effects | `fun foo() : <e> a` | `foo : T -> a with E` |
| Effect row syntax | `<io|e>` | `IO + e` |
| Operation invocation | unqualified (`read()`) | qualified (`IO.read ()`) |
| Handler block | `with handler { ... } body` (trailing block) | `handle expr with { arms }` (explicit) |
| `fun`/`ctl` distinction | yes | yes |
| `return` clause | yes | yes |
| One-shot vs multi-shot | one-shot default; `ctl-multi` for multi-shot | one-shot only in v1 |
| Effects on records | none (different system) | shared row machinery via record `+` extension |

The biggest user-facing differences:
- **Wok's qualified operation calls** (`IO.read` vs Koka's `read`). Wok choice is more verbose but immediately discoverable; avoids namespace collisions across effects.
- **Wok's explicit `handle expr with arms`** vs Koka's trailing-block `with handler { ... } body`. Wok is more verbose for stacks but unambiguous at every position.
- **Wok's `+` operator vs Koka's `|`** for row-tail and union. Wok unifies with records' extension operator; Koka uses `|` from Leijen 2005's original paper notation.

## Inheritance from Leijen 2005 + 2017

Soundness (Progress + Preservation):
- **Type-level rows** (records and effects share machinery): Leijen 2005, scoped labels.
- **Effect-handler semantics**: Leijen 2017, "Type Directed Compilation of Row-Typed Algebraic Effects."

Wok's design constraints align with both proofs' preconditions:
- No subtyping → no covariance issues.
- Immutable values → no aliasing-plus-effects soundness loss.
- Rank-1 HM → no higher-rank effect-quantifier issues.
- Scoped labels (vs Wand-style) → no principal-type ambiguity.

See `docs/koka.md` for the paper summaries.

## Open hooks for future work

1. **Multi-shot continuations** — explicit `ctl-multi` keyword; runtime support for continuation duplication. Needed for non-determinism, backtracking, advanced patterns.
2. **Effect masking** (`mask`) — hide effects from outer handlers. Koka's feature; useful for resource scoping. Defer.
3. **First-class effect rows** — pass effect rows as values, e.g. for instance dictionaries. Defer.
4. **Effect-row equality constraints** — `(e1 ~ e2) =>` in typeclass context. Possible after typeclasses ship.
5. **Performance-oriented compilation** — Leijen 2017 algebraic compilation vs naive CPS. v1 likely chooses simpler; production may want efficient.

## Composition with records and typeclasses

The complete picture, combining all three:

```wok
data Request = Request { url : String, method : String }

effect IO = 
  { read : String -> String
  , write : String -> ()
  }

class Persistent p = 
  { type SaveEffects p
  , save : p -> () with SaveEffects p
  }

instance Persistent Request = 
  { type SaveEffects Request = IO + Logger
  , save = \req -> 
      Logger.log ("saving " ++ req.url)
      IO.write (req.url ++ "," ++ req.method)
  }

-- Combined sig: typeclass constraint, record extension, effect row
backupAll 
  : (Persistent p, Eq p) 
  => [p] 
  -> [p] 
  with SaveEffects p + IO + e
backupAll items =
  forEach items save
  IO.write "backup complete"
  items
```

All three spec features (records, typeclasses, effects) interoperate without conflict. The grammar pieces (constraints in parens, `+` for extension, `with` for effects, qualified operations) each have distinct syntactic positions and combine compositionally.

## Pedagogical note

Wok's effects + no monads model has a teaching advantage over Haskell-style monad-first programming:

- **Day-one IO** — students write IO programs immediately, without needing to learn monad theory.
- **Effect tracking is explicit** — `with IO` says exactly what a function does; no hidden monad context.
- **Composition is natural** — `with IO + Logger + e` composes via the same `+` operator users see for records and other type-level concepts.

The downside is that programmers transferring from Haskell may miss `do`-notation and the monad ecosystem. The transition cost is real but is a one-time learning curve; the long-term payoff is clearer code and less abstraction tax.

## TL;DR for implementers

1. **Phase 1 (this spec):** wire up the surface syntax, typecheck programs with effects, but don't actually run effects. Output is a type-checked program with effect tracking.
2. **Phase 2 (separate runtime spec):** implement operation invocation and handler semantics. The hard work is in the compilation strategy.
3. **Phase 3 (stdlib):** populate effect declarations and handlers in `Std`.

The type-system work (Phase 1) is well-defined and inherits from Leijen 2005 + 2017. The runtime work is the substantive engineering challenge ahead.
