# HM Core Typechecker — Design

**Date:** 2026-05-25
**Status:** Draft for review
**Module root:** `Wok.TypeChecking`

A Hindley-Milner core typechecker for the current wok v1 surface (the post-`Wok.Reordering` AST). Algorithm J with level-based generalization, implemented over `ST` with mtl-style transformers. Designed so the future row/effects spec is additive: the type AST reserves slots for effect rows on arrows and for row variables, but the v1 inferrer always produces and consumes the empty closed row.

The design philosophy follows `docs/koka.md` (scoped-label rows, semantic value restriction, no subtyping). Tagless-final replaces GADTs for users who want typed DSLs; a refinement-types layer (Liquid-Haskell style, SMT-discharged) is a feasible future addition that consumes the typed AST without modifying the inferrer.

---

## 1. Goals and non-goals

### In scope

- Complete HM-core typechecker for the v1 wok surface that's already parsable.
- Algorithm J, level-based generalization, in `ST`. Mutable type-variable cells, in-place unification.
- ADT declarations populate a constructor/type environment. Parametric polymorphism over `*`-kinded type variables only.
- Pattern matching for every pattern form the grammar admits today: var, wildcard, literal (Int/String/Char), constructor application (with arity check), tuple, cons (`::`), list literal.
- User-written type signatures (single-name and multi-name forms) checked against inferred types via standard instance/subsumption.
- Let-polymorphism with the **semantic value restriction** rule the koka doc commits us to (generalize iff effect is the empty row). In v1, with no effects yet, that degenerates to "always generalize at let" — but the check is in place, so v2 (effects) doesn't have to refactor it.
- `where` clauses, nested `let`, `if/then/else`, lambdas, operator sections (operators are just functions after the `Reordering` pass).
- Tuples and lists as built-in type constructors with hardcoded inference rules.
- Source-located error messages: every unification failure carries the surface span(s) that produced it.

### Reserved but not implemented (slot exists in AST, ignored by v1)

- The arrow constructor is internally `t1 -> e t2` with `e` always being the empty closed row in v1. The unifier handles it. Adding effect rows later is additive.
- The open/close transform at let-instantiation is a no-op in v1 (closed row stays closed) but the call site exists so v2 only swaps the body.
- Kind discipline: type vars carry kinds, with `*` and `effect` reserved as kinds even though only `*` is used in v1.

### Explicit non-goals (deferred to later specs)

- Records and row polymorphism.
- Effect rows on arrows beyond the reserved AST slot.
- Type classes / qualified types (Mark Jones / THIH style is the planned approach).
- Modules and cross-file resolution. v1 typecheck operates on a single resolved compilation unit.
- Refinement types — future SMT-based pass over the typed AST.
- GADTs, type families, dependent types.
- Exhaustiveness / coverage checking of `case` — separate pass after typecheck, consuming the typed AST.
- Termination checking, totality.
- Polymorphic recursion.
- Higher-rank polymorphism.

### Decisions locked in by prior brainstorm

- **No subtyping.** Pure functions usable where effectful expected via row-polymorphic openness at instantiation (degenerate in v1).
- **Semantic value restriction**, not syntactic.
- **No GADTs, no type families.** Tagless-final is the user's escape hatch for typed DSLs.
- Refinement-type layer is feasible later as a post-typecheck SMT pass.

---

## 2. Type AST

### 2.1 Kinds

```haskell
data Kind
  = KStar
  | KEffect
  | KArrow Kind Kind
```

v1 uses only `KStar`. `KEffect` and `KArrow` are parsed into the kind AST but no v1 user-facing syntax produces them. The unifier accepts kind-tagged variables and refuses to unify across kinds.

### 2.2 Inference-time types

Two representations: `Type s` with mutable cells used during inference, `CType` closed used for storage in environments and final output.

```haskell
data Type s
  = TCon TyCon [Type s]
  | TArr (Type s) (Row s) (Type s)
  | TVar (STRef s (TVar s))

data TVar s
  = Unbound { uniq :: Int, level :: Level, kind :: Kind }
  | Link    (Type s)

data TyCon
  = TcInt | TcChar | TcString | TcBool
  | TcUnit
  | TcTuple Int
  | TcList
  | TcUser Text

newtype Level = Level Int
  deriving (Eq, Ord, Show)
```

`TArr` is a separate constructor (not `TCon "->" [a, b]`) because the function constructor has the effect-row slot in the middle position — kind `(*, effect, *) -> *` rather than `(*, *) -> *`. Special-casing it now means v2 doesn't have to migrate every `TCon "->"` site.

### 2.3 Rows — the reserved slot

```haskell
data Row s
  = RowEmpty
  | RowExtend Text (Type s) (Row s)
  | RowVar    (STRef s (RVar s))

data RVar s
  = RUnbound { rUniq :: Int, rLevel :: Level }
  | RLink    (Row s)
```

v1 always produces `RowEmpty` in the middle of every `TArr` and the row unifier handles only the `RowEmpty ~ RowEmpty` case (trivial). The `RowExtend` and `RowVar` constructors exist; the scoped-label unification rules from the koka doc will live in `Unify.hs` from day one, but in v1 no call site ever creates a non-empty row.

### 2.4 Closed types and schemes

When a type leaves the inferrer (gets stored in the env, printed, generalized into a scheme), all mutable cells get walked-and-frozen into a closed representation:

```haskell
data CType
  = CTCon TyCon [CType]
  | CTArr CType CRow CType
  | CTGen Int

data CRow
  = CREmpty
  | CRExtend Text CType CRow
  | CRGen Int

data Scheme = Scheme
  { schemeVars :: [(Int, Kind)]
  , schemeBody :: CType
  }
```

Two operations bridge `Type s` and `CType`:

- **`freeze :: Type s -> ST s CType`** — walks the type, dereferencing every `Link`, replacing unbound vars at level > current with quantified `CTGen` slots when called during generalization. (See section 3.5.)
- **`instantiate :: Scheme -> TC s (Type s)`** — replaces each `CTGen i` with a fresh `TVar` at the current level. Runs at every use of a let-bound name.

### 2.5 Environment

```haskell
data ConInfo = ConInfo
  { conScheme :: Scheme
  , conArity  :: Int
  , conTyCon  :: Text
  }

data TyConInfo = TyConInfo
  { tcKind  :: Kind
  , tcArity :: Int
  , tcCons  :: [Text]
  }

data Env = Env
  { envVars   :: Map Text Scheme
  , envCons   :: Map Text ConInfo
  , envTyCons :: Map Text TyConInfo
  }
```

The env is plain immutable Maps — we use `local` (Reader pattern) to extend in scopes. Mutable state (level counter, fresh-unique counter) lives separately in the monad's context, not in `Env`.

### 2.5.1 Initial env (builtins)

`Wok.TypeChecking.Builtins` supplies the starting `Env` value that `inferProgram` extends with user declarations:

- **`envTyCons`** — `Int`, `Char`, `String`, `Bool`, `()` (each with `tcKind = KStar`, `tcArity = 0`); `[_]` (`KStar -> KStar`, arity 1); tuple constructors `(_,_)`, `(_,_,_)`, etc. up to a reasonable arity (e.g. 16). `Bool`'s `tcCons` is `["True","False"]`.
- **`envCons`** — `True : Bool`, `False : Bool`. Lists and tuples are built without named user-level constructors; `[]`/`::` and `(_,_,_)` are special-cased in inference (sections 4.4-4.5). User-defined data types add to this env on top of the builtins.
- **`envVars`** — primitive operator schemes: `(+), (-), (*), (/), div, mod : Int -> Int -> Int`; `(==), (/=) : Int -> Int -> Bool` (monomorphic in v1 since no classes); `(&&), (||) : Bool -> Bool -> Bool`; `(++) : [a] -> [a] -> [a]`; `($) : (a -> b) -> a -> b`. Concrete list comes from the fixity decls in the standard test corpus; expand as needed.

If user source contains `data Bool = True | False`, the second registration **errors** with a duplicate-tycon / duplicate-constructor message. v1 does not try to reconcile user redefinitions of builtins. (The developer-facing tour `examples/hehe.wok` includes such a declaration for parser exercise; it is not part of the v1 typecheck test corpus.)

### 2.6 Typed output AST

After successful inference, every expression and binding in the source is decorated with its inferred (closed) type:

```haskell
data TypedExpr
  = TEVar   CType Text
  | TELit   CType Literal
  | TEApp   CType TypedExpr TypedExpr
  | TELam   CType Text TypedExpr
  | TELet   CType Text Scheme TypedExpr TypedExpr
  | TECase  CType TypedExpr [(TypedPat, TypedExpr)]
  | TEIf    CType TypedExpr TypedExpr TypedExpr
  | TETuple CType [TypedExpr]
  | TEList  CType [TypedExpr]

data TypedPat = ...
data TypedDecl = ...
```

Two properties:

- The `CType` at every node is **closed** — the typed AST is pure data that survives outside the `runST` boundary.
- The `Scheme` on each let-binding is what subsequent passes use; the inner expression's annotations are the *instantiated* uses.

### 2.7 Module layout

```
src/Wok/TypeChecking.hs              -- public API facade
src/Wok/TypeChecking/Types.hs        -- Kind, Type, Row, TVar, RVar, Scheme, CType, CRow
src/Wok/TypeChecking/Env.hs          -- Env, ConInfo, TyConInfo, lookup/extend helpers
src/Wok/TypeChecking/Monad.hs        -- TC monad, fresh, withLevel, lookupVar, etc.
src/Wok/TypeChecking/Builtins.hs     -- primops, built-in type constructors
src/Wok/TypeChecking/Unify.hs        -- unify, unifyRow, occursAdjust, freeze
src/Wok/TypeChecking/Infer.hs        -- inferExpr, inferPat, inferDecl, generalize, instantiate
src/Wok/TypeChecking/Error.hs        -- TypeError
```

---

## 3. Inference: algorithm and monad

### 3.1 The TC monad

```haskell
data TCCtx s = TCCtx
  { ctxFresh :: STRef s Int
  , ctxLevel :: Level
  , ctxEnv   :: Env
  }

newtype TC s a = TC { unTC :: ReaderT (TCCtx s) (ExceptT TypeError (ST s)) a }
  deriving (Functor, Applicative, Monad,
            MonadReader (TCCtx s),
            MonadError TypeError)

liftST :: ST s a -> TC s a
liftST = TC . lift . lift

runTC :: Env -> (forall s. TC s a) -> Either TypeError a
runTC env tc = runST $ do
  freshRef <- newSTRef 0
  let ctx = TCCtx freshRef (Level 0) env
  runExceptT (runReaderT (unTC tc) ctx)
```

Two deliberate choices:

- **Level lives in Reader, not in an `STRef`.** `enterLevel = local (\c -> c { ctxLevel = bump (ctxLevel c) })` gives stack discipline automatically — exception-safe, no manual save/restore.
- **Unique counter lives in an `STRef`.** It's monotonic; no scope discipline needed. Reading and bumping is two cheap operations.

### 3.2 Fresh variables and level scoping

```haskell
freshUniq :: TC s Int
freshUniq = do
  r <- asks ctxFresh
  liftST $ do n <- readSTRef r; writeSTRef r (n + 1); pure n

freshTVar :: Kind -> TC s (Type s)
freshTVar k = do
  Level l <- asks ctxLevel
  u <- freshUniq
  ref <- liftST $ newSTRef (Unbound u (Level l) k)
  pure (TVar ref)

enterLevel :: TC s a -> TC s a
enterLevel = local (\c -> c { ctxLevel = let Level l = ctxLevel c in Level (l + 1) })

extendEnvVar :: Text -> Scheme -> TC s a -> TC s a
extendEnvVar x s = local (\c -> c { ctxEnv = (ctxEnv c) { envVars = Map.insert x s (envVars (ctxEnv c)) } })
```

Every let-binding wraps its right-hand-side inference in `enterLevel`; the generalization pass then quantifies vars whose level > the outer (post-decrement) level.

### 3.3 Unification

`force` chases `Link` chains with path compression so subsequent reads are O(1).

```haskell
force :: Type s -> TC s (Type s)
force t@(TVar r) = do
  tv <- liftST $ readSTRef r
  case tv of
    Link t' -> do
      t'' <- force t'
      liftST $ writeSTRef r (Link t'')
      pure t''
    Unbound{} -> pure t
force t = pure t

unify :: Type s -> Type s -> TC s ()
unify a b = do
  a' <- force a
  b' <- force b
  case (a', b') of
    (TVar r1, TVar r2) | r1 == r2 -> pure ()
    (TVar r, t)  -> unifyVar r t
    (t, TVar r)  -> unifyVar r t
    (TCon c1 ts1, TCon c2 ts2)
      | c1 == c2, length ts1 == length ts2 -> zipWithM_ unify ts1 ts2
    (TArr a1 e1 b1, TArr a2 e2 b2) -> do
      unify a1 a2
      unifyRow e1 e2
      unify b1 b2
    _ -> throwError (mismatchOf a' b')

unifyVar :: STRef s (TVar s) -> Type s -> TC s ()
unifyVar r t = do
  Unbound _ lvl _ <- liftST $ readSTRef r
  occursAdjust r lvl t
  liftST $ writeSTRef r (Link t)
```

### 3.4 Occurs check + level adjustment (fused)

Combined into one pass: walk the type being assigned, fail if it contains the target, lower the level of any other unbound variable whose level is higher.

```haskell
occursAdjust :: STRef s (TVar s) -> Level -> Type s -> TC s ()
occursAdjust target lvl = go
  where
    go (TVar r)
      | r == target = throwError (occursOf target)
      | otherwise = do
          tv <- liftST $ readSTRef r
          case tv of
            Link t' -> go t'
            Unbound u l k ->
              when (l > lvl) $
                liftST $ writeSTRef r (Unbound u lvl k)
    go (TCon _ ts) = mapM_ go ts
    go (TArr a r b) = go a >> goRow r >> go b
    goRow RowEmpty = pure ()
    goRow (RowExtend _ ty rest) = go ty >> goRow rest
    goRow (RowVar _) = pure ()
```

### 3.5 Freeze and generalize

Generalizing after a let-binding's RHS is typed:

1. **Freeze** the type: walk it, dereferencing every `Link`. Produces a closed `CType`.
2. **Quantify**: any unbound var whose level is strictly greater than the outer level becomes a `CTGen i` slot. Collect those (id, kind) pairs as the scheme's quantifier list.

```haskell
generalize :: Type s -> TC s Scheme
generalize t = do
  Level outer <- asks ctxLevel
  liftST $ do
    counter <- newSTRef 0
    seen    <- newSTRef Map.empty
    kinds   <- newSTRef []
    body    <- freezeQuantify outer counter seen kinds t
    pairs   <- readSTRef kinds
    pure (Scheme (reverse pairs) body)
```

Two subtleties:

- **`seen`** keeps the mapping from `uniq -> CTGen idx` so the same variable used twice in the type becomes the same `CTGen` (not two different ones). Forgetting this loses sharing and produces wrong principal types.
- A variable whose level is `<= outer` is *not* quantified — it survives as a `TVar` ref. v1 raises `EscapedTyVar` if such a variable would leak into the closed `CType` output, since that indicates an inference bug.

### 3.6 Instantiation

```haskell
instantiate :: Scheme -> TC s (Type s)
instantiate (Scheme vars body) = do
  freshes <- mapM (\(_, k) -> freshTVar k) vars
  let subst = Map.fromList (zip (map fst vars) freshes)
  pure (substInCType subst body)
```

### 3.7 The row case in v1

```haskell
unifyRow :: Row s -> Row s -> TC s ()
unifyRow RowEmpty RowEmpty = pure ()
unifyRow r1 r2             = throwError (rowMismatchOf r1 r2)
```

v2 replaces this body with the scoped-label rewrite algorithm. The dispatch from `unify` already calls into it, so v2 is genuinely additive.

### 3.8 Inference engine spine

`inferExpr` returns `(TypedExpr, Type s)`. The core primitives:

- Literal: constant `TCon`.
- Variable: look up scheme, `instantiate` at current level.
- Application `f x`: infer `fT`, `xT`, allocate fresh `rT`, `unify fT (TArr xT RowEmpty rT)`, return `rT`.
- Lambda `\x -> e`: fresh `xT`, infer `e` under env extended with `x : Scheme [] xT`, return `TArr xT RowEmpty eT`.
- `let x = e in b`: `enterLevel` to type `e`, generalize, extend env with the scheme, infer `b`.
- Case, if, tuple, list, where — reuse these primitives.

Estimated engine size: 600-800 LOC across `Monad.hs`, `Unify.hs`, `Infer.hs`.

---

## 4. Source coverage

### 4.1 Top-level processing

Three passes over the post-`Reordering` declarations:

1. **Collect type constructors.** Walk all `data` decls, register each `TyConInfo` in `envTyCons` with its arity and constructor names. Done first so constructors can reference each other and themselves.
2. **Collect constructors and signatures.** Walk all `data` decls again to build `ConInfo` entries. Walk all standalone type signatures and register them. Multi-name signatures `x, y, z : Int` expand into three separate scheme entries.
3. **Type function equations.** Single mutually recursive let-group: every binding gets a fresh placeholder `TVar` first, then each body is typed in the env that has all the placeholders, then each is generalized.

Order of declarations in the source does not affect typing.

### 4.2 Data declarations

`data Maybe a = Nothing | Just a` produces:

- `envTyCons["Maybe"] = TyConInfo { tcKind = KStar `KArrow` KStar, tcArity = 1, tcCons = ["Nothing","Just"] }`
- `envCons["Nothing"] = ConInfo { conScheme = forall a. Maybe a,        conArity = 0, conTyCon = "Maybe" }`
- `envCons["Just"]    = ConInfo { conScheme = forall a. a -> Maybe a,   conArity = 1, conTyCon = "Maybe" }`

Type parameters on the LHS are implicitly universally quantified — they appear in the constructor schemes as `CTGen`s. Constructor arguments may reference other user types (mutual recursion works because tycons are registered first).

Kind checking in v1 is trivial: every type parameter is `KStar`, every constructor must apply tycons to the right arity. Higher-kinded parameters (e.g. `data Foo f a = Foo (f a)`) produce a kind error.

### 4.3 Function equations and signatures

Multi-clause definitions:

```
length : [a] -> Int
length []        = 0
length (_ :: xs) = 1 + length xs
```

The typechecker groups equations sharing a name into a single binding and types them together. Each equation must have the same arity. The inferred type is unified across all equations.

When a signature is present:

- The user-written type is freshly instantiated for each equation.
- The inferred body type must unify with the instantiated signature.
- The final scheme stored in the env is the user's **declared** scheme, not the inferred one — so the user controls the principal type when they want to.

Multi-name signatures `zero, one, two : Int` expand to three entries during collection.

### 4.4 Expression inference (summary)

| Construct | Rule |
|---|---|
| Literal | matching primitive `TCon`. |
| Variable | look up scheme, `instantiate` at current level. |
| Constructor in expression | look up `ConInfo`, instantiate the scheme. |
| Application `f x` | infer `fT`, `xT`; fresh `rT`; `unify fT (TArr xT RowEmpty rT)`. |
| Lambda `\x -> e` | fresh `xT`; extend env; infer body. |
| Multi-arg lambda | curry left-to-right. |
| `let x = e in b` | `enterLevel`, infer, freeze-and-generalize, extend env, infer body. |
| `if c then a else b` | unify `cT` with `Bool`; unify branch types. |
| Tuple | `TCon (TcTuple n) [...]`. |
| List literal | fresh element type, unify all elements; empty is `TCon TcList [fresh]`. |
| `case e of alts` | for each alt: infer pattern, unify with scrutinee, infer body, unify all body types. |
| `where` | sugar for nested `let`. |

### 4.5 Pattern inference

```haskell
inferPat :: Pat -> TC s (Type s, [(Text, Type s)])
```

| Pattern | Rule |
|---|---|
| Variable `x` | fresh `xT`; bind `x : xT`. |
| Wildcard `_` | fresh type; no binding. |
| Literal | matching primitive `TCon`; no binding. |
| Constructor `Just x`, `Cons h t` | look up `ConInfo`; check arity; instantiate scheme; sub-patterns unified against constructor's argument types. |
| Nullary constructor | as above with zero sub-patterns. |
| Cons `h :: t` | same as `Cons h t`; built-in. |
| Tuple | sub-patterns inferred, type is tuple constructor applied. |
| List literal | fresh element type, unify all sub-patterns. |

Variables introduced by patterns are **monomorphic** in the alternative's body — `Scheme [] xT` (no quantifiers), standard HM.

### 4.6 Where clauses and local signatures

`where` desugars to a `let`-group wrapping the equation's RHS. Same mutual-recursion and generalization machinery. Local signatures inside `where` are collected like top-level sigs and used to constrain the corresponding local bindings.

### 4.7 Explicit non-coverage in v1

- No exhaustiveness check on `case` — that's a separate pass that consumes the typed AST.
- No overlapping/redundant pattern detection.
- No polymorphic recursion detection. A recursive function whose recursive call uses a different instantiation than its definition will fail to unify.
- No higher-rank polymorphism.
- No type-class constraint generation.
- No occurrence-of-undefined-name diagnostics from the typechecker — that's the renamer's job (the typechecker assumes input is name-resolved; lookup failures become typechecker errors but the error message reflects that).

---

## 5. Integration

### 5.1 Public API

`Wok.TypeChecking` is the only module downstream consumers import:

```haskell
module Wok.TypeChecking
  ( inferProgram
  , TypedExpr (..)
  , TypedPat  (..)
  , TypedDecl (..)
  , CType     (..)
  , CRow      (..)
  , Scheme    (..)
  , Kind      (..)
  , TyCon     (..)
  , Env       (..)
  , ConInfo   (..)
  , TyConInfo (..)
  , TypeError (..)
  )

inferProgram :: ReorderedProgram -> Either TypeError (Env, [TypedDecl])
```

The env in the output exists so downstream passes (coverage, future refinement layer, an evaluator) have constructor and type-constructor info without re-walking source.

### 5.2 Pipeline integration in `app/Main.hs`

```haskell
main :: IO ()
main = do
  args <- getArgs
  case args of
    [path] -> runApp path
    _      -> die "usage: wok <file.wok>"

runApp :: FilePath -> IO ()
runApp path = do
  src <- readFile path
  case pipeline src of
    Left err               -> die err
    Right (_env, decls)    -> mapM_ (putStrLn . prettyTypedDecl) decls
  where
    pipeline src = do
      parsed    <- first ("parse: "      <>) (parse src)
      reordered <- first ("reorder: "    <>) (reorder parsed)
      first    (("typecheck: " <>) . show)   (inferProgram reordered)
```

`first` from `Data.Bifunctor` (already in `base`) maps over the `Left` side; the three passes chain through `Either`'s monad.

### 5.3 cabal file changes

```cabal
library
    import:           warnings
    exposed-modules:
        GeneratedParser.Wok.Abs
        GeneratedParser.Wok.Lex
        GeneratedParser.Wok.Par
        GeneratedParser.Wok.Print
        GeneratedParser.Wok.Layout
        GeneratedParser.Wok.ErrM
        Wok.Parsing
        Wok.Reordering
        Wok.TypeChecking
    other-modules:
        Wok.TypeChecking.Types
        Wok.TypeChecking.Env
        Wok.TypeChecking.Monad
        Wok.TypeChecking.Builtins
        Wok.TypeChecking.Unify
        Wok.TypeChecking.Infer
        Wok.TypeChecking.Error
    build-depends:
        base         ^>=4.20,
        array        ^>=0.5,
        containers,
        mtl,
        text,
        transformers
    hs-source-dirs:   src
    default-language: GHC2024
    default-extensions:
        Strict
        StrictData
    ghc-options:
        -funbox-strict-fields
    build-tool-depends:
        BNFC:bnfc,
        alex:alex,
        happy:happy
```

`Strict` makes function arguments and let-bindings strict by default. Lazy fields/bindings inside `Wok.TypeChecking` require explicit `~`. The typechecker is fundamentally strict (no thunk would buy anything in recursive descent, mutual recursion, ADT processing, output construction, or env lookups), so no `~` opt-outs are needed in the inferrer.

If multi-error reporting is added later, switching from fail-fast `ExceptT` to `Validation` / `Either [e]` plumbing will be a deliberate change rather than relying on lazy list cons.

### 5.4 Wired-but-not-implemented hooks

Two pieces deliberately exist as stubs that future specs replace:

- **`Wok.TypeChecking.Unify.unifyRow`** — handles only `RowEmpty ~ RowEmpty`. The rows-and-effects spec implements the scoped-label algorithm.
- **No coverage check** yet, but the typed AST output is the input that `Wok.Coverage` will eventually consume.

Module-header comments mark both sites.

---

## 6. Errors

```haskell
data TypeError
  = Mismatch       SourceSpan CType CType
  | OccursCheck    SourceSpan Int CType
  | UnknownVar     SourceSpan Text
  | UnknownCon     SourceSpan Text
  | UnknownTyCon   SourceSpan Text
  | ArityMismatch  SourceSpan Text Int Int
  | RowMismatch    SourceSpan CRow CRow
  | SigMismatch    SourceSpan Text CType CType
  | EscapedTyVar   SourceSpan Int
  deriving (Show)
```

- Every error carries a `SourceSpan` (reusing the type from `Wok.Parsing`).
- When raising, the relevant inference types are frozen to `CType` so the error structure is `STRef`-free and survives the `runST` boundary.
- Derived `Show` is the only formatter for v1. A `Wok.TypeChecking.Pretty` module gets added later without touching the inferrer.

---

## 7. Testing

### 7.1 Layout

```
test/
  Spec.hs                          (existing tasty entry; gains a new test group)
  examples/                        (existing parser golden inputs, unchanged)
  golden/                          (existing parser golden outputs)
  resolve-examples/                (existing reorder golden inputs)
  resolve-golden/
  typecheck-examples/              (NEW: .wok files that typecheck)
  typecheck-golden/                (NEW: one .out per .wok, success format)
  typecheck-fail-examples/         (NEW: .wok files that should fail typecheck)
  typecheck-fail-golden/           (NEW: one .out per .wok, show TypeError)
```

### 7.2 Golden output format

For success cases, top-level binding schemes one per line, sorted by name:

```
-- typecheck-golden/01-identity.out
const'  : forall a b. a -> b -> a
flip'   : forall a b c. (a -> b -> c) -> b -> a -> c
id      : forall a. a -> a
```

Stable, human-readable, easy to update via `cabal test --test-options=--accept`.

For failure cases, the show-rendered `TypeError`. Ugly but stable; re-accept goldens once a pretty formatter lands.

### 7.3 Test corpus

`typecheck-examples/`:

- Identity, const, flip — basic polymorphism
- Arithmetic on `Int` — primitive types
- Lists: cons, append, map, foldr — `[a]` polymorphism
- `Maybe`, `Either` — user ADTs
- Mutual recursion (`even`/`odd`)
- Where clauses, nested let
- Pattern matching: every pattern form from the grammar at least once
- Higher-order: `twice`, `compose`, `($)`
- Multi-name signatures
- Local sigs inside `where`

`typecheck-fail-examples/`:

- Apply `+` to a string — unification mismatch
- Occurs check: `\x -> x x`
- Polymorphic recursion attempted without annotation
- Unknown constructor / unknown variable
- Constructor arity mismatch in pattern
- Signature contradicts inferred type
- Wrong constructor pattern type in case

### 7.4 Test driver

```haskell
typecheckTests :: TestTree
typecheckTests = testGroup "typecheck"
  [ goldenTests "typecheck-examples"      "typecheck-golden"      successHarness
  , goldenTests "typecheck-fail-examples" "typecheck-fail-golden" failureHarness
  ]
```

`cabal test --test-options=--accept` updates goldens after intentional changes.

### 7.5 Explicit non-tests in v1

- No property tests (QuickCheck).
- No performance benchmarks.
- No typed-AST round-trip (no typed pretty-printer yet).

---

## 8. Open hooks for future specs

Three named extension points the v1 design preserves:

1. **`unifyRow`** in `Unify.hs` — gets the scoped-label algorithm in the rows-and-effects spec.
2. **Generalization rule** in `Infer.hs` — currently "always generalize at let" because the row in `TArr` is always empty. The check `effect == empty row` is already the gating condition; the rows-and-effects spec just makes it discriminate.
3. **Typed AST consumers** — `Wok.Coverage` and a future `Wok.Refinement` both walk the `TypedDecl`/`TypedExpr`/`TypedPat` output. The AST shape is the stable interface.
