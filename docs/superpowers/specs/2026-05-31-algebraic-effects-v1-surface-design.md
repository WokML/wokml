# Algebraic effects v1 — surface language design

Status: draft (rev 1)
Owner: zy
Date: 2026-05-31

> **Supersedes the surface-language portions of `2026-05-27-effects-spec.md`.**
> That spec (rev 2) captured the broad vision; this document captures the
> *v1 surface and type-checker* design as settled in the 2026-05-31 design
> session. Where the two disagree, this document wins for v1. Notable
> changes from rev 2:
> - Effect-row variables use the **`eff`** keyword (`+ eff e`), not bare `e`,
>   to distinguish effect rows from record rows (`+ row r`).
> - Handlers use **`handle e of { … }`** (reuse the layout-enabled `of`),
>   not `handle e with { … }`.
> - Closed-by-default rows, consistent with records; **auto-open deferred**.
> - **`ctl` / `resume` / exceptions deferred**; v1 ops are all transparent
>   (auto-resume). Runtime semantics remain deferred (this is type-checking
>   only).

## Motivation

Wok's HM core pre-wired the type system for row-polymorphic effects: the
arrow carries an effect-row slot (`TArr (Type s) (Row s) (Type s)` /
`CTArr CType CRow CType`, always empty in practice today), `KEffect` is a
real kind, and `Wok.TypeChecking.Unify.unifyRow` is the full Leijen 2005
scoped-label unifier — already exercised by records. None of this is
reachable from surface syntax. Records shipped and stabilised the row
machinery; this spec lights up the same machinery for effects.

The design rejects monads at the language level: no `Monad` class, no
`do`-notation, no `>>=`, no `return`/`pure`. Sequential effectful code is
ordinary `let`/expression sequencing plus direct operation calls. Effects
are tracked in function types via a trailing `with` clause and discharged
by handlers.

This is **type-checking only**. v1 makes effectful programs typecheck and
propagates/discharges effects through inference; it does **not** run them.
Operation invocation and handler semantics (continuation capture,
`resume`) are a separate runtime spec.

## Settled decisions (and why)

1. **Closed-by-default rows, consistent with records.** A row is exactly
   what is written; openness is explicit. This is the records model
   (`Point` is strict; `Point + row r` opts into a tail; a bare row var is
   the `BareRowVar` error). One row mental model across the language.

2. **`eff` vs `row` keyword split.** Record rows carry labelled fields;
   effect rows carry effect labels. They share the `unifyRow` machinery but
   are different domains, so the surface marks them differently: `Point +
   row r` (records), `… with IO + eff e` (effects). This matches koka.md's
   "per-effect kind discipline" recommendation. The anonymous form `..` is
   domain-neutral (`Point + ..`, `with IO + ..`); only the *named* form
   takes a domain keyword.

3. **Auto-open deferred.** Koka opens let-bound function types at each use
   site so concrete effects compose without annotation. That is the
   ergonomic default for effects (it is effectively required for two
   functions with different concrete effects to be called in one body — see
   "Composition cost" below), but it contradicts the closed-by-default
   promise (`with IO` would no longer mean *exactly* IO at use sites). v1
   ships explicit `+ ..` / `+ eff e` instead; auto-open is a later,
   non-breaking opt-in pass (it only ever removes required annotations).

4. **`ctl` / `resume` / exceptions deferred.** v1 operations are all
   transparent (`fun`): a handler arm's body *is* the resume value, and the
   computation always resumes exactly once. This covers IO/State/Reader/
   Logger-style effects and the full dependency-injection pattern. It does
   **not** cover early-exit/exceptions (a handler that declines to resume).
   Because every op is transparent, the `fun` marker is also redundant in
   v1; ops are bare `name : Type`. `fun`, `ctl`, `resume` are reserved (so
   adding control operations later is non-breaking).

5. **Effect bodies parse exactly like record `data` bodies.** An op entry
   `name : Type` is structurally a `RecordFieldType`, so effect bodies reuse
   `[RecordFieldType]` and the block-form layout machinery
   (`Wok.RecordLayout`): comma-separated, or newline-separated with a
   newline after `{`, or mixed, with trailing comma allowed.

6. **Handlers use `handle e of { … }`.** `of` is already layout-enabled, so
   handler arms get indentation for free and read like `case … of`. `with`
   stays meaning exactly one thing (effect annotation on arrows) and avoids
   a layout conflict (it is inline in signatures, so it cannot also be a
   block opener).

7. **Operation calls reuse `EProj`.** `IO.read path` already parses as
   `EProj (ECon "IO") (VarId "read")`; no grammar change. The renamer/
   typechecker recognises `IO` as an effect name and `read` as one of its
   operations.

## Surface language reference

### Effect declarations

```
effect IO = { read : String -> String, write : String -> () }

effect Logger = {
  log : String -> ()
}

effect State a = {       -- effects may take type parameters
  get : () -> a
  set : a -> ()
}
```

- `effect ConId [VarId] = "{" [op] "}"`, where each `op` is `name : Type`.
- Body parses like a record `data` body (comma / newline / mixed / trailing
  comma), via the shared block-form pre-pass.
- All ops are transparent in v1 (no `fun`/`ctl` marker).

### Effect annotations on arrows

```
double : U64 -> U64                                 -- no `with` = pure / total
greet  : String -> () with IO                       -- closed: exactly IO
logIt  : () -> () with IO + ..                       -- anonymous open tail
runIO  : (() -> a with IO + eff e) -> a with eff e   -- named open tail (threads)
multi  : () -> () with IO + Logger                   -- multiple effects
stateful : () -> a with State U64 + eff e             -- effect with a type argument
```

- `with` binds **looser than `->`**: `A -> B with E` parses as `(A -> B) with E`.
- `+` composes effects, left-associative. Effect atoms are `ConId`, optionally
  applied to type arguments (`State U64`).
- Row-tail forms:
  - closed: omit, or `with E` with no `+ tail`;
  - **named open**: `+ eff e` (threads the same tail across positions);
  - **anonymous open**: `+ ..` (fresh single-use tail; cannot thread).
- `eff`/`row` variables are kind-checked: an `eff` variable may appear only
  in a `with` clause; a `row` variable only in a record extension. Crossing
  domains is an error.

#### Anonymous vs named (the threading rule)

`..` desugars to a freshly-generated, single-use row variable, so two `..`
in one signature are unrelated:

```
preserveExtras : Point + .. -> Point + ..            -- REJECTED (input tail ≠ output tail)
preserveExtras : Point + row r -> Point + row r      -- OK (same tail)

mapEff : (a -> b with ..) -> [a] -> [b] with ..      -- REJECTED (callback effects not tied to result)
mapEff : (a -> b with eff e) -> [a] -> [b] with eff e -- OK (threads)
```

Rule, identical for records and effects: **`..` = "open here, don't care";
`eff e` / `row r` = "open here, and it is the same tail as the other one
with this name".**

#### Composition cost (consequence of deferring auto-open)

In a function body, every effectful call must unify to one effect row.
Two functions with different *closed* concrete effects cannot be called in
the same body (`⟨Exn⟩ = ⟨Div⟩` fails). To be composable, an effectful
function must carry an open tail:

```
foo1 : () -> () with Exn + ..    -- ⟨Exn | _⟩, composes
foo2 : () -> () with Div + ..    -- ⟨Div | _⟩, composes
```

So in practice most effectful, composable functions end their `with` clause
with `+ ..` (or `+ eff e` when threading). Closed `with E` is for leaves,
restriction boundaries, and handler results. This friction is the explicit
price of deferring auto-open and is the main signal for revisiting it.

### Operation invocation

```
greet : String -> () with IO + Logger
greet name =
  Logger.log ("greeting " ++ name)
  IO.write ("hi " ++ name)
```

Qualified `Effect.op`. Each call requires that effect's label in the
enclosing function's row; the requirement is unified into the ambient
effect row during inference.

### Handlers

```
handle EXPR of
  Effect.op args -> body
  ...
  return v -> body            -- optional; default `return v -> v`
```

- `handle e of { arms }` — region-scoped; handles exactly `EXPR`. The
  nearest enclosing handler wins for a given operation.
- Discharges the handled effect(s) from `EXPR`'s row.
- v1 (transparent ops): an arm body **is** the resume value. Its type is the
  operation's *result* type. Arms may themselves invoke other effects
  (effect translation / DI) — those effects join the handler's result row.
- `return v -> body` reshapes the final value (`v : EXPR`'s result type;
  `body : handle`'s result type). Default is identity.
- No `resume` binding and no abort path in v1.

```
runIO : (() -> a with IO + eff e) -> a with eff e
runIO comp =
  handle (comp ()) of
    IO.read p  -> readDisk p          -- auto-resumes with the String
    IO.write m -> printStdout m       -- auto-resumes with ()
    return v   -> v
```

Whole-computation handling is the handler-as-function pattern above
(`comp` is a thunk applied inside the handler). Finer regions are written by
placing `handle` around any sub-expression.

### Dependency injection (blessed pattern)

```
greet : () -> () with Logger + eff e         -- depends on a capability, not a backend
greet () = Logger.log "hello"

logToFile : (() -> a with Logger + eff e) -> a with IO + eff e
logToFile c = handle (c ()) of
  Logger.log m -> IO.write ("LOG: " ++ m)    -- discharges Logger, introduces IO
  return v     -> v

main () = runIO (\() -> logToFile (\() -> greet ()))
```

A handler discharges one effect and may introduce others; the residual row
is tracked in the type. `main` must reduce to an empty effect row — the
compiler rejects a program with an unwired capability.

## Type-system integration

### Effect environment

Extend `Wok.TypeChecking.Env.Env` with declared effects:

```haskell
data Env = Env
  { ...
  , envEffects :: Map Text EffectInfo
  }

data EffectInfo = EffectInfo
  { eiParams :: [(Int, Kind)]          -- type params of the effect (e.g. State a)
  , eiOps    :: Map Text Scheme         -- operation name -> operation type
  }
```

`overlayEnvs` gains an `envEffects` namespace (and an `EnvNs` tag) so effect
names collide cleanly across modules like the other namespaces.

### Translating the `with` clause

When sig translation meets an effect-annotated arrow, the `with` clause
becomes the arrow's `Row` slot (closed labels + optional `eff`/`..` tail):

- `with IO` → `RowExtend "IO" <arg-or-unit> RowEmpty`
- `with IO + Logger` → nested `RowExtend`s ending in `RowEmpty`
- `with IO + eff e` → labels ending in a shared `RowVar` for `e`
- `with IO + ..` → labels ending in a fresh single-use `RowVar`

Effect labels with type arguments (`State U64`) carry the argument as the
`RowExtend` field type. `eff`/`row` variables are tracked with `KEffect`
kind; sig translation already partitions `KStar` from `KEffect` quantifier
slots, and shares a `RowVar` across repeated `eff e` occurrences.

### Operation-call typing

For `EProj (ECon E) (VarId op)` where `E ∈ envEffects` and `op ∈ eiOps`:

1. Instantiate the operation's scheme to a function type `A₁..Aₙ -> B`.
2. The application's result is `B`.
3. Require `E`'s label in the ambient effect row: unify the ambient row to
   contain `E` (via `rewriteRow`), introducing it if the tail is open.

A `with`-annotated function whose body calls `E.op` but whose declared row
lacks `E` is an `UndischargedEffect`/`MissingEffect` error.

### Handler typing (transparent ops)

For `handle e of { E.opᵢ argsᵢ -> bodyᵢ ; return v -> r }`:

1. Infer `e : τ` with ambient effect `ρ`.
2. Each handled effect `E` (collected from the arm heads) must be present in
   `ρ`; discharge each `E`'s labels from `ρ`, giving `ρ'`.
3. Coverage: every operation of each handled effect `E` must have an arm
   (exhaustive). Missing arms are a `HandlerCoverage` error.
4. Each arm `E.op args -> body`: bind `args` to the op's argument types;
   check `body` against the op's *result* type `B`. `body` may add effects;
   those join `ρ'`.
5. `return v -> r`: bind `v : τ`; the result type of the whole `handle` is
   the type of `r` (default `r = v`, so result type `τ`).
6. Result: the `handle` expression has the result type from step 5 and
   effect row `ρ'` (remaining effects ∪ arm-body effects ∪ `return`-body
   effects).

### Output / pretty-printing

`prettyCType` already has a dormant non-empty-row arrow branch (`a -< … >- b`)
and prints row variables as `rN`. v1 replaces this with the `with` surface
form so signatures round-trip and golden output reads like source:

- `CTArr a CREmpty b` → `a -> b`
- `CTArr a r b` (non-empty) → `a -> b with <row>` rendered as
  `L1 + L2 + eff eN` (and `+ row rN` for record rows). Single-use tails may
  print as `..` later (cosmetic; not required for v1).

This also fixes the existing `forall a … r0` naming split by routing effect/
row variable names through the same naming scheme as the scheme quantifier.

## Grammar additions

```bnfc
-- Effect declarations (body reuses RecordFieldType + block-form pre-pass)
DEffect.  Decl ::= "effect" ConId [VarId] "=" "{" [RecordFieldType] "}" ;

-- Effect-annotated arrow. `with` binds looser than `->`, so a with-clause
-- wraps a whole arrow chain: `A -> B -> C with E` = `(A -> B -> C) with E`.
-- This refactors the existing `TFun. Type ::= Type1 "->" Type` into an
-- ArrowChain layer with `with` applied above it.
TWith.    Type ::= ArrowChain "with" EffectRow ;
_.        Type ::= ArrowChain ;
TFun.     ArrowChain ::= Type1 "->" ArrowChain ;
_.        ArrowChain ::= Type1 ;

-- Effect row: labels joined by `+`, optional eff/anonymous open tail.
-- A bare `eff e` / `..` (no leading atom) is the fully effect-polymorphic
-- row, needed for callbacks like `(a -> b with eff e)`.
ERAtom.     EffectAtom ::= ConId [Type2] ;
EROne.      EffectRow ::= EffectAtom ;                 -- closed
ERPlus.     EffectRow ::= EffectAtom "+" EffectRow ;   -- atom + more (tail may be eff/..)
ERVarOnly.  EffectRow ::= "eff" VarId ;                -- named open tail (also bare)
ERWildOnly. EffectRow ::= ".." ;                       -- anonymous open tail (also bare)

-- Anonymous record tail (symmetry with records; new)
RCWild.   RowContrib ::= ".." ;

-- Handlers (of is already layout-enabled)
EHandle.  Exp2 ::= "handle" Exp "of" "{" [HandlerArm] "}" ;
HArm.     HandlerArm ::= ConId "." VarId [AtomPat] "->" Exp ;
HReturn.  HandlerArm ::= "return" VarId "->" Exp ;
separator HandlerArm ";" ;
```

- New reserved keywords, implemented in v1: `effect`, `with`, `handle`,
  `eff`, and `return` (as a handler-arm head). Reserved but unimplemented
  (forward-compat): `fun`, `ctl`, `resume`. (`of`, `row` already reserved.)
- `Wok.RecordLayout` extends its brace-context recogniser to treat the
  effect-decl `{` (after `effect ConId [VarId] =`) as a comma-context brace,
  exactly as it treats the name-elided record `data X = { … }` brace.
- Precedence: each new form opens with a distinct keyword, keeping LALR(1)
  disambiguation clean.

## Implementation scope

**Type-checking only. No runtime.** Effectful programs typecheck and effects
are tracked/discharged; operations and handlers have no runtime behaviour.

### Milestone 1 — declarations, annotations, operation calls

1. Grammar: `DEffect`, `TFunEff`, effect-row productions, `RCWild`; new
   keywords. Regenerate parser; apply layout patches.
2. `Wok.RecordLayout`: recognise the effect-decl brace as comma-context.
3. `Env`: add `envEffects` / `EffectInfo` and the new `EnvNs` tag.
4. `Infer`: `processEffectDecls`; translate `with` clauses to the arrow row
   slot; operation-call typing (ambient-row constraint); `eff`/`row` kind
   enforcement.
5. `Error`: `MissingEffectDecl`, `UndischargedEffect`, `UnknownOperation`.

After M1 you can declare effects, annotate functions, call operations, and
watch effects propagate through inference.

### Milestone 2 — handlers

1. Grammar: `EHandle`, `HArm`, `HReturn`.
2. `Infer`: `inferHandler` — discharge handled effects, exhaustive-coverage
   check, transparent-op arm typing (`body : op result type`), `return` arm,
   arm-body effects join the result row.
3. `Error`: `HandlerCoverage`.
4. `prettyCType`/`prettyCRow`: render effect rows in `with` form.

### Deferred (all non-breaking to add later)

Runtime semantics (continuation capture, real `resume`); `ctl`/`resume`/
exceptions; auto-open; multi-shot; effect masking; effect aliases;
`Lacks`-style row constraints; named row-tail capture.

## Soundness and decidability

- **Rows**: Leijen 2005 scoped labels — `unifyRow` is proven sound, complete,
  and terminating (the `tail(r) ∉ dom(θ)` side condition; implemented via
  `rewriteRow` + `occursAdjustRowVar`). Shared with records.
- **Decidable + principal**: HM + scoped-label rows, rank-1, no subtyping,
  no qualified types in v1 → squarely in the decidable-with-principal-types
  fragment. The same unifier already terminates for records.
- **Handlers**: Leijen 2017 establishes Progress + Preservation for the
  effect-row + handler system; Wok's constraints (no subtyping, immutable
  values, rank-1, scoped labels) match its preconditions.

See `docs/koka.md` for the paper summaries.

## Test plan (type-checking golden fixtures)

| Fixture | Asserts |
| --- | --- |
| `20-effects-decl.wok` | `effect E = { … }` parses (inline, block, mixed) and round-trips |
| `21-effects-arrow.wok` | `with E`, `+ eff e`, `+ ..` parse; `with` looser than `->` |
| `22-effects-pure.wok` | no `with` ⇒ empty effect row inferred |
| `23-effects-calls.wok` | calling `E.op` requires `E` in the caller's row; propagation |
| `24-effects-handle.wok` | `handle e of { … }` discharges `E`; result row excludes it |
| `25-effects-di.wok` | effect-translating handler (`Logger` → `IO`); `main` row empty |

Fail fixtures: undeclared `with FooBar`; unhandled effect at `main`;
non-exhaustive handler; `eff` var in a record tail (and vice versa);
anonymous `..` used where threading is required.

## File / module changes summary

| File | Action |
| --- | --- |
| `grammar/Wok.cf` | `DEffect`, `TFunEff`, effect-row productions, `RCWild`, `EHandle`, handler arms; new keywords |
| `src/GeneratedParser/Wok/*` | regenerate via BNFC; reapply layout/Par.y patches |
| `src/Wok/RecordLayout.hs` | recognise effect-decl brace as comma-context |
| `src/Wok/TypeChecking/Env.hs` | `envEffects`, `EffectInfo`, `EnvNs` tag |
| `src/Wok/TypeChecking/Infer.hs` | effect decls, `with` translation, op typing, handler typing, effect-row printing, kind enforcement |
| `src/Wok/TypeChecking/Unify.hs` | reused as-is (`unifyRow`/`rewriteRow`) |
| `src/Wok/TypeChecking/Error.hs` | new effect error variants |
| `test/typecheck-examples/`, `test/typecheck-golden/`, `test/typecheck-fail-*` | new fixtures |
| `test/Spec.hs` | effect-typing unit tests |
