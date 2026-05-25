# HM Core Typechecker Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers-extended-cc:subagent-driven-development (recommended) or superpowers-extended-cc:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement `Wok.TypeChecking`, a Hindley-Milner core typechecker for the v1 wok surface, following the spec at `docs/superpowers/specs/2026-05-25-hm-core-design.md`.

**Architecture:** Algorithm J (mutable type-variable cells in `ST`) with Rémy-style level-based generalization. Type AST reserves an effect-row slot on the function arrow so the future rows/effects spec is additive. mtl-style `ReaderT/ExceptT` over `ST`. Output is a typed AST plus the final environment, consumed by a future coverage pass.

**Tech Stack:** GHC 9.10 (GHC2024), `mtl`, `transformers`, `containers`, `text`, `tasty` + `tasty-golden` for tests. `Strict` + `StrictData` + `-funbox-strict-fields` for the new code.

---

## Task 0: Bootstrap — cabal changes and module skeletons

**Goal:** Establish the new module hierarchy and dependency declarations so subsequent tasks have a buildable shell to fill in.

**Files:**
- Modify: `wok.cabal`
- Create: `src/Wok/TypeChecking.hs` (facade, empty re-exports)
- Create: `src/Wok/TypeChecking/Types.hs` (empty module)
- Create: `src/Wok/TypeChecking/Env.hs` (empty module)
- Create: `src/Wok/TypeChecking/Error.hs` (empty module)
- Create: `src/Wok/TypeChecking/Monad.hs` (empty module)
- Create: `src/Wok/TypeChecking/Unify.hs` (empty module)
- Create: `src/Wok/TypeChecking/Builtins.hs` (empty module)
- Create: `src/Wok/TypeChecking/Infer.hs` (empty module)

**Acceptance Criteria:**
- [ ] `cabal build` succeeds.
- [ ] All new modules are listed in `wok.cabal`.
- [ ] `Strict`, `StrictData` extensions and `-funbox-strict-fields` apply to the library.
- [ ] `mtl` and `transformers` are in `build-depends`.

**Verify:** `cabal build 2>&1 | tail -20` → no errors.

**Steps:**

- [ ] **Step 1: Update `wok.cabal`** — replace the `library` stanza with:

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
        Wok.TypeChecking.Error
        Wok.TypeChecking.Monad
        Wok.TypeChecking.Unify
        Wok.TypeChecking.Builtins
        Wok.TypeChecking.Infer
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
    -- NOTE: cabal auto-invokes alex (.x) and happy (.y) but NOT bnfc (.cf).
    -- BNFC is listed so `cabal install --only-dependencies` pulls it in; the
    -- grammar must still be regenerated manually after editing grammar/Wok.cf:
    --   bnfc --haskell -d --text-token -o src grammar/Wok.cf
    build-tool-depends:
        BNFC:bnfc,
        alex:alex,
        happy:happy
```

- [ ] **Step 2: Create the facade `src/Wok/TypeChecking.hs`**:

```haskell
module Wok.TypeChecking
  ( -- placeholder; populated in later tasks
  ) where
```

- [ ] **Step 3: Create all sub-modules as empty stubs** — each file contains only:

```haskell
module Wok.TypeChecking.Types where
```

(adjust module name per file: `Env`, `Error`, `Monad`, `Unify`, `Builtins`, `Infer`)

- [ ] **Step 4: Verify build**

Run: `cabal build`
Expected: builds cleanly, no errors. The `Strict`/`StrictData` extensions apply but the empty modules have nothing to be affected.

- [ ] **Step 5: Commit**

```bash
git add wok.cabal src/Wok/TypeChecking.hs src/Wok/TypeChecking/
git commit -m "$(cat <<'EOF'
feat(typecheck): bootstrap Wok.TypeChecking module skeleton

Adds the empty module hierarchy under Wok.TypeChecking, declares
mtl + transformers as new deps, and enables Strict / StrictData /
-funbox-strict-fields for the library so subsequent tasks can drop
field bangs and UNPACK pragmas.
EOF
)"
```

---

## Task 1: Type AST — Types module

**Goal:** Define every data type the inferrer operates on: `Kind`, `Type s` (inference-time), `CType` (closed), `Row`/`CRow`, `Scheme`, `TyCon`, `Level`.

**Files:**
- Modify: `src/Wok/TypeChecking/Types.hs`
- Create: `test/Wok/TypeChecking/TypesSpec.hs` (HUnit smoke tests)
- Modify: `wok.cabal` (add `Wok.TypeChecking.TypesSpec` reference into test-suite or use ad-hoc test for now; see Step 4)
- Modify: `test/Spec.hs` (add the smoke test to tasty)

**Acceptance Criteria:**
- [ ] `Type s` has constructors `TCon`, `TArr`, `TVar`; no `TGen`.
- [ ] `CType` has `CTCon`, `CTArr`, `CTGen`.
- [ ] `Row s` and `CRow` mirror per the spec.
- [ ] `Scheme` holds quantifier list + closed body.
- [ ] All types build under `Strict`/`StrictData`.
- [ ] Smoke tests construct and pattern-match values for each constructor.

**Verify:** `cabal test --test-options="-p Types"` → all smoke tests pass.

**Steps:**

- [ ] **Step 1: Write the failing smoke test** — create `test/Spec.hs` additions. Open `test/Spec.hs` and at the top add the import, then near the existing `testGroup` add the types test group.

In `test/Spec.hs`, add to the imports:

```haskell
import qualified Wok.TypeChecking.Types as T
```

Add the test group function:

```haskell
typesSmokeTests :: TestTree
typesSmokeTests = testGroup "Wok.TypeChecking.Types"
  [ testCase "TyCon equality" $
      T.TcInt @?= T.TcInt
  , testCase "CType construction round-trips" $
      let t = T.CTArr (T.CTGen 0) T.CREmpty (T.CTGen 0)
      in case t of
           T.CTArr (T.CTGen i) T.CREmpty (T.CTGen j) -> (i, j) @?= (0, 0)
           _ -> assertFailure "shape mismatch"
  , testCase "Scheme stores quantifiers and body" $
      let s = T.Scheme [(0, T.KStar)] (T.CTArr (T.CTGen 0) T.CREmpty (T.CTGen 0))
      in T.schemeVars s @?= [(0, T.KStar)]
  , testCase "Level is comparable" $
      compare (T.Level 1) (T.Level 2) @?= LT
  ]
```

Add `typesSmokeTests` to the list passed to `defaultMain $ testGroup "wok"`.

- [ ] **Step 2: Run test to verify it fails**

Run: `cabal test --test-options="-p Types"`
Expected: FAIL — `Wok.TypeChecking.Types` exports nothing yet, compile error.

- [ ] **Step 3: Implement `src/Wok/TypeChecking/Types.hs`**

```haskell
-- | Inference-time and closed type representations for the HM core checker.
--
-- The function arrow 'TArr' / 'CTArr' carries an effect-row slot in the
-- middle position (always 'RowEmpty' / 'CREmpty' in v1). This shape is
-- preserved so the future rows-and-effects spec can fill in the row case
-- without rewriting v1 call sites.
module Wok.TypeChecking.Types
  ( -- * Kinds
    Kind (..)
    -- * Inference-time types (carry mutable cells via STRef)
  , Type (..)
  , TVar (..)
    -- * Effect rows
  , Row (..)
  , RVar (..)
    -- * Closed (post-freeze) types and rows
  , CType (..)
  , CRow (..)
    -- * Type schemes (generalised types)
  , Scheme (..)
    -- * Type-constructor tags
  , TyCon (..)
    -- * Generalisation levels
  , Level (..)
  ) where

import Data.STRef (STRef)
import Data.Text (Text)

data Kind
  = KStar
  | KEffect
  | KArrow Kind Kind
  deriving (Eq, Show)

newtype Level = Level Int
  deriving (Eq, Ord, Show)

data TyCon
  = TcInt
  | TcChar
  | TcString
  | TcBool
  | TcUnit
  | TcTuple Int
  | TcList
  | TcUser Text
  deriving (Eq, Ord, Show)

data Type s
  = TCon TyCon [Type s]
  | TArr (Type s) (Row s) (Type s)
  | TVar (STRef s (TVar s))

data TVar s
  = Unbound { uniq :: Int, level :: Level, kind :: Kind }
  | Link (Type s)

data Row s
  = RowEmpty
  | RowExtend Text (Type s) (Row s)
  | RowVar (STRef s (RVar s))

data RVar s
  = RUnbound { rUniq :: Int, rLevel :: Level }
  | RLink (Row s)

data CType
  = CTCon TyCon [CType]
  | CTArr CType CRow CType
  | CTGen Int
  deriving (Eq, Show)

data CRow
  = CREmpty
  | CRExtend Text CType CRow
  | CRGen Int
  deriving (Eq, Show)

data Scheme = Scheme
  { schemeVars :: [(Int, Kind)]
  , schemeBody :: CType
  }
  deriving (Eq, Show)
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cabal test --test-options="-p Types"`
Expected: PASS — all four smoke tests succeed.

- [ ] **Step 5: Commit**

```bash
git add src/Wok/TypeChecking/Types.hs test/Spec.hs
git commit -m "$(cat <<'EOF'
feat(typecheck): define core type AST

Kinds, inference-time Type/Row with STRef cells, closed CType/CRow,
Scheme, TyCon, Level. TArr threads an effect-row slot through every
arrow (always empty in v1) so the future rows spec is additive.
EOF
)"
```

---

## Task 2: Environment + Error modules

**Goal:** Define `Env`, `ConInfo`, `TyConInfo` with lookup/extend helpers, and the `TypeError` data type with the `SourceSpan` alias.

**Files:**
- Modify: `src/Wok/TypeChecking/Env.hs`
- Modify: `src/Wok/TypeChecking/Error.hs`
- Modify: `test/Spec.hs` (add env smoke test)

**Acceptance Criteria:**
- [ ] `Env` has `envVars`, `envCons`, `envTyCons` as `Map Text _`.
- [ ] `emptyEnv` constructs an env with all-empty maps.
- [ ] `lookupVar`, `lookupCon`, `lookupTyCon` return `Maybe`.
- [ ] `extendVar`, `extendCon`, `extendTyCon` insert into the appropriate map.
- [ ] `TypeError` covers all variants from the spec.
- [ ] `SourceSpan` is an alias for `BNFC'Position`.

**Verify:** `cabal test --test-options="-p Env"` → smoke tests pass; `cabal build` succeeds.

**Steps:**

- [ ] **Step 1: Implement `src/Wok/TypeChecking/Error.hs`**

```haskell
-- | Type errors emitted by the HM core checker.
module Wok.TypeChecking.Error
  ( SourceSpan
  , TypeError (..)
  ) where

import Data.Text (Text)
import GeneratedParser.Wok.Abs (BNFC'Position)
import Wok.TypeChecking.Types (CRow, CType)

-- | A source location. Currently the start position of the offending
-- token (BNFC only records token starts, not full spans).
type SourceSpan = BNFC'Position

data TypeError
  = Mismatch SourceSpan CType CType
  | OccursCheck SourceSpan Int CType
  | UnknownVar SourceSpan Text
  | UnknownCon SourceSpan Text
  | UnknownTyCon SourceSpan Text
  | ArityMismatch SourceSpan Text Int Int
    -- ^ name, expected, got
  | RowMismatch SourceSpan CRow CRow
  | SigMismatch SourceSpan Text CType CType
    -- ^ binding name, declared, inferred
  | EscapedTyVar SourceSpan Int
  | DuplicateTyCon SourceSpan Text
  | DuplicateCon SourceSpan Text
  | DuplicateBinding SourceSpan Text
  | UnsupportedFeature SourceSpan Text
    -- ^ for module access (EProj/EProjC) in v1
  deriving (Show)
```

- [ ] **Step 2: Implement `src/Wok/TypeChecking/Env.hs`**

```haskell
-- | Typing environment: variables, data constructors, type constructors.
module Wok.TypeChecking.Env
  ( Env (..)
  , ConInfo (..)
  , TyConInfo (..)
  , emptyEnv
  , lookupVar
  , lookupCon
  , lookupTyCon
  , extendVar
  , extendCon
  , extendTyCon
  ) where

import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import Wok.TypeChecking.Types (Kind, Scheme)

data ConInfo = ConInfo
  { conScheme :: Scheme
  , conArity :: Int
  , conTyCon :: Text
  }
  deriving (Eq, Show)

data TyConInfo = TyConInfo
  { tcKind :: Kind
  , tcArity :: Int
  , tcCons :: [Text]
  }
  deriving (Eq, Show)

data Env = Env
  { envVars :: Map Text Scheme
  , envCons :: Map Text ConInfo
  , envTyCons :: Map Text TyConInfo
  }
  deriving (Eq, Show)

emptyEnv :: Env
emptyEnv = Env Map.empty Map.empty Map.empty

lookupVar :: Text -> Env -> Maybe Scheme
lookupVar k = Map.lookup k . envVars

lookupCon :: Text -> Env -> Maybe ConInfo
lookupCon k = Map.lookup k . envCons

lookupTyCon :: Text -> Env -> Maybe TyConInfo
lookupTyCon k = Map.lookup k . envTyCons

extendVar :: Text -> Scheme -> Env -> Env
extendVar k v e = e { envVars = Map.insert k v (envVars e) }

extendCon :: Text -> ConInfo -> Env -> Env
extendCon k v e = e { envCons = Map.insert k v (envCons e) }

extendTyCon :: Text -> TyConInfo -> Env -> Env
extendTyCon k v e = e { envTyCons = Map.insert k v (envTyCons e) }
```

- [ ] **Step 3: Add an env smoke test to `test/Spec.hs`**

Add imports:

```haskell
import qualified Wok.TypeChecking.Env as TE
import qualified Data.Text as Tx
```

Add test group:

```haskell
envSmokeTests :: TestTree
envSmokeTests = testGroup "Wok.TypeChecking.Env"
  [ testCase "emptyEnv has no entries" $ do
      TE.lookupVar (Tx.pack "x") TE.emptyEnv @?= Nothing
      TE.lookupCon (Tx.pack "Just") TE.emptyEnv @?= Nothing
      TE.lookupTyCon (Tx.pack "Maybe") TE.emptyEnv @?= Nothing
  , testCase "extendVar then lookupVar finds it" $
      let s = T.Scheme [] (T.CTCon T.TcInt [])
          e = TE.extendVar (Tx.pack "x") s TE.emptyEnv
      in TE.lookupVar (Tx.pack "x") e @?= Just s
  ]
```

Add `envSmokeTests` to the top-level `testGroup "wok"` list.

- [ ] **Step 4: Verify**

Run: `cabal test --test-options="-p Env"`
Expected: PASS.

Run: `cabal build`
Expected: clean.

- [ ] **Step 5: Commit**

```bash
git add src/Wok/TypeChecking/Env.hs src/Wok/TypeChecking/Error.hs test/Spec.hs
git commit -m "$(cat <<'EOF'
feat(typecheck): add Env and Error modules

Env (variables, constructors, tycons) with lookup/extend helpers.
TypeError covers unification mismatches, occurs check, unknown names,
arity errors, signature mismatches, duplicate bindings, and a catch-all
UnsupportedFeature for the v1-unsupported EProj/EProjC module access.
SourceSpan is a Wok.TypeChecking-local alias for BNFC'Position.
EOF
)"
```

---

## Task 3: TC monad

**Goal:** Implement the `TC s` monad over `ReaderT (TCCtx s) (ExceptT TypeError (ST s))`, plus `freshUniq`, `freshTVar`, `enterLevel`, `liftST`, and `runTC`.

**Files:**
- Modify: `src/Wok/TypeChecking/Monad.hs`
- Modify: `test/Spec.hs` (monad tests)

**Acceptance Criteria:**
- [ ] `TC s a` derives `Functor`, `Applicative`, `Monad`, `MonadReader (TCCtx s)`, `MonadError TypeError`.
- [ ] `runTC :: Env -> (forall s. TC s a) -> Either TypeError a`.
- [ ] `freshUniq` returns monotonically increasing integers.
- [ ] `freshTVar k` returns a fresh `TVar` at the current level with kind `k`.
- [ ] `enterLevel` bumps the level for the duration of a sub-computation.
- [ ] `throwError` propagates as `Left`.

**Verify:** `cabal test --test-options="-p Monad"` → all monad tests pass.

**Steps:**

- [ ] **Step 1: Implement `src/Wok/TypeChecking/Monad.hs`**

```haskell
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE RankNTypes #-}

-- | The type-checker monad: ReaderT for environment + current level,
-- ExceptT for fail-fast errors, ST for mutable type-variable cells.
module Wok.TypeChecking.Monad
  ( TC
  , TCCtx (..)
  , runTC
  , liftST
  , currentLevel
  , currentEnv
  , freshUniq
  , freshTVar
  , freshRVar
  , enterLevel
  , withEnv
  , extendVarTC
  ) where

import Control.Monad.Except (ExceptT, MonadError, runExceptT)
import Control.Monad.Reader (MonadReader, ReaderT, ask, asks, local, runReaderT)
import Control.Monad.Trans (lift)
import Control.Monad.ST (ST, runST)
import Data.STRef (STRef, newSTRef, readSTRef, writeSTRef)
import Data.Text (Text)
import Wok.TypeChecking.Env (Env, extendVar)
import Wok.TypeChecking.Error (TypeError)
import Wok.TypeChecking.Types
  ( Kind, Level (..), RVar (..), Row (..), Scheme, TVar (..), Type (..) )

data TCCtx s = TCCtx
  { ctxFresh :: STRef s Int
  , ctxLevel :: Level
  , ctxEnv :: Env
  }

newtype TC s a = TC { unTC :: ReaderT (TCCtx s) (ExceptT TypeError (ST s)) a }
  deriving
    ( Functor, Applicative, Monad
    , MonadReader (TCCtx s)
    , MonadError TypeError
    )

liftST :: ST s a -> TC s a
liftST = TC . lift . lift

runTC :: Env -> (forall s. TC s a) -> Either TypeError a
runTC env action = runST $ do
  freshRef <- newSTRef 0
  let ctx = TCCtx freshRef (Level 0) env
  runExceptT (runReaderT (unTC action) ctx)

currentLevel :: TC s Level
currentLevel = asks ctxLevel

currentEnv :: TC s Env
currentEnv = asks ctxEnv

freshUniq :: TC s Int
freshUniq = do
  ref <- asks ctxFresh
  liftST $ do
    n <- readSTRef ref
    writeSTRef ref (n + 1)
    pure n

freshTVar :: Kind -> TC s (Type s)
freshTVar k = do
  lvl <- currentLevel
  u <- freshUniq
  ref <- liftST $ newSTRef (Unbound u lvl k)
  pure (TVar ref)

freshRVar :: TC s (Row s)
freshRVar = do
  lvl <- currentLevel
  u <- freshUniq
  ref <- liftST $ newSTRef (RUnbound u lvl)
  pure (RowVar ref)

enterLevel :: TC s a -> TC s a
enterLevel = local
  (\c -> c { ctxLevel = let Level l = ctxLevel c in Level (l + 1) })

withEnv :: (Env -> Env) -> TC s a -> TC s a
withEnv f = local (\c -> c { ctxEnv = f (ctxEnv c) })

extendVarTC :: Text -> Scheme -> TC s a -> TC s a
extendVarTC name sch = withEnv (extendVar name sch)
```

- [ ] **Step 2: Add monad tests to `test/Spec.hs`**

Add imports:

```haskell
import qualified Wok.TypeChecking.Monad as TM
import Control.Monad.Except (throwError)
import qualified Wok.TypeChecking.Error as TErr
```

Add the test group:

```haskell
monadSmokeTests :: TestTree
monadSmokeTests = testGroup "Wok.TypeChecking.Monad"
  [ testCase "freshUniq returns increasing values" $
      let result = TM.runTC TE.emptyEnv $ do
            a <- TM.freshUniq
            b <- TM.freshUniq
            c <- TM.freshUniq
            pure (a, b, c)
      in result @?= Right (0, 1, 2)
  , testCase "enterLevel bumps then restores" $
      let result = TM.runTC TE.emptyEnv $ do
            l0 <- TM.currentLevel
            l1 <- TM.enterLevel TM.currentLevel
            l2 <- TM.currentLevel
            pure (l0, l1, l2)
      in result @?= Right (T.Level 0, T.Level 1, T.Level 0)
  , testCase "freshTVar carries current level" $
      let result = TM.runTC TE.emptyEnv $ do
            t <- TM.enterLevel (TM.enterLevel TM.freshTVar')
            pure t
          TM.freshTVar' = TM.freshTVar T.KStar
      in case result of
           Right _ -> pure ()
           Left e -> assertFailure (show e)
  , testCase "throwError caught as Left" $
      let result = TM.runTC TE.emptyEnv $
            throwError (TErr.UnknownVar Nothing (Tx.pack "x"))
            :: Either TErr.TypeError ()
      in case result of
           Left (TErr.UnknownVar _ _) -> pure ()
           _ -> assertFailure "expected UnknownVar"
  ]
```

Add `monadSmokeTests` to the top-level tasty group.

- [ ] **Step 3: Verify**

Run: `cabal test --test-options="-p Monad"`
Expected: PASS — four tests succeed.

- [ ] **Step 4: Commit**

```bash
git add src/Wok/TypeChecking/Monad.hs test/Spec.hs
git commit -m "$(cat <<'EOF'
feat(typecheck): add TC monad

ReaderT (TCCtx s) (ExceptT TypeError (ST s)) with mtl deriving.
Level lives in Reader (stack discipline via local); unique counter
lives in an STRef. Helpers: freshUniq, freshTVar, freshRVar,
enterLevel, withEnv, extendVarTC.
EOF
)"
```

---

## Task 4: Unify part 1 — force, freeze, occurs/level adjust

**Goal:** Implement the three foundational walks: `force` (path-compressing dereference), `freeze` (Type s → CType), `occursAdjust` (fused occurs check + level lowering).

**Files:**
- Modify: `src/Wok/TypeChecking/Unify.hs`
- Modify: `test/Spec.hs` (unify-walks test group)

**Acceptance Criteria:**
- [ ] `force` chases `Link` chains and path-compresses.
- [ ] `freeze` converts `Type s` with no unbound vars into a `CType`; unbound vars become `CTGen` based on uniq.
- [ ] `occursAdjust` throws `OccursCheck` when the target appears in the type being assigned.
- [ ] `occursAdjust` lowers the level of any other unbound variable whose level exceeds the target's.

**Verify:** `cabal test --test-options="-p UnifyWalks"` → tests pass.

**Steps:**

- [ ] **Step 1: Implement `src/Wok/TypeChecking/Unify.hs`** (partial — unify itself in Task 5)

```haskell
-- | Unification, occurs check + level adjustment, and the freeze pass
-- that converts inference-time @Type s@ into closed @CType@.
module Wok.TypeChecking.Unify
  ( force
  , forceRow
  , freeze
  , freezeRow
  , freezeScheme
  , occursAdjust
  , occursAdjustRow
  ) where

import Control.Monad (when)
import Control.Monad.Except (throwError)
import Data.IORef ()  -- intentionally empty; we use STRef
import Data.STRef (STRef, readSTRef, writeSTRef)
import qualified Data.Map.Strict as Map
import Wok.TypeChecking.Error (SourceSpan, TypeError (..))
import Wok.TypeChecking.Monad (TC, liftST)
import Wok.TypeChecking.Types
  ( CRow (..), CType (..), Level (..), RVar (..), Row (..), TVar (..), Type (..) )

-- | Chase a chain of 'Link' refs to the head, path-compressing along the way.
force :: Type s -> TC s (Type s)
force t@(TVar r) = do
  tv <- liftST $ readSTRef r
  case tv of
    Link t' -> do
      t'' <- force t'
      liftST $ writeSTRef r (Link t'')
      pure t''
    Unbound {} -> pure t
force t = pure t

forceRow :: Row s -> TC s (Row s)
forceRow r@(RowVar ref) = do
  rv <- liftST $ readSTRef ref
  case rv of
    RLink r' -> do
      r'' <- forceRow r'
      liftST $ writeSTRef ref (RLink r'')
      pure r''
    RUnbound {} -> pure r
forceRow r = pure r

-- | Convert an inference-time type to a closed type. Unbound variables
-- become @CTGen@s using their uniq as the slot id (the caller is
-- responsible for ensuring the chosen scheme makes sense).
freeze :: Type s -> TC s CType
freeze t = do
  t' <- force t
  case t' of
    TCon c ts -> CTCon c <$> mapM freeze ts
    TArr a r b -> CTArr <$> freeze a <*> freezeRow r <*> freeze b
    TVar ref -> do
      tv <- liftST $ readSTRef ref
      case tv of
        Unbound u _ _ -> pure (CTGen u)
        Link _ -> freeze t'  -- unreachable: force resolved any link

freezeRow :: Row s -> TC s CRow
freezeRow r = do
  r' <- forceRow r
  case r' of
    RowEmpty -> pure CREmpty
    RowExtend l ty rest -> CRExtend l <$> freeze ty <*> freezeRow rest
    RowVar ref -> do
      rv <- liftST $ readSTRef ref
      case rv of
        RUnbound u _ -> pure (CRGen u)
        RLink _ -> freezeRow r'

freezeScheme :: ([(Int, Wok.TypeChecking.Types.Kind)], Type s) -> TC s (Int, [(Int, Wok.TypeChecking.Types.Kind)], CType)
freezeScheme = error "freezeScheme: built in Task 6 (generalize)"
{-# WARNING freezeScheme "freezeScheme stub; implemented in Task 6" #-}

-- | Combined occurs check + level adjustment. Walks the type being
-- assigned, failing if the target ref appears, and lowering the level
-- of any other unbound variable whose level exceeds the target's.
occursAdjust :: SourceSpan -> STRef s (TVar s) -> Level -> Type s -> TC s ()
occursAdjust sp target lvl = go
  where
    go (TVar r)
      | r == target = do
          Unbound u _ _ <- liftST $ readSTRef target
          throwError (OccursCheck sp u (CTGen u))
      | otherwise = do
          tv <- liftST $ readSTRef r
          case tv of
            Link t' -> go t'
            Unbound u l k ->
              when (l > lvl) $
                liftST $ writeSTRef r (Unbound u lvl k)
    go (TCon _ ts) = mapM_ go ts
    go (TArr a r b) = go a >> occursAdjustRow lvl r >> go b

occursAdjustRow :: Level -> Row s -> TC s ()
occursAdjustRow _ RowEmpty = pure ()
occursAdjustRow lvl (RowExtend _ ty rest) = do
  -- we don't have a target ref to check for rows in v1 (no row vars produced),
  -- but lower levels of any nested type vars
  _ <- pure ty
  occursAdjustRow lvl rest
occursAdjustRow lvl (RowVar ref) = do
  rv <- liftST $ readSTRef ref
  case rv of
    RLink r' -> occursAdjustRow lvl r'
    RUnbound u l ->
      when (l > lvl) $
        liftST $ writeSTRef ref (RUnbound u lvl)
```

Note: the `freezeScheme` stub above will be replaced in Task 6; left as a typed placeholder so this module compiles in isolation.

Actually, on reflection: remove the `freezeScheme` stub from this task — it doesn't belong here. Simpler to just not include it until Task 6. Remove that block.

The corrected module ends after `occursAdjustRow`. The opening `import` block needs `Wok.TypeChecking.Types (Kind)` removed since we no longer use it. Final correct imports:

```haskell
import Control.Monad (when)
import Control.Monad.Except (throwError)
import Data.STRef (STRef, readSTRef, writeSTRef)
import Wok.TypeChecking.Error (SourceSpan, TypeError (..))
import Wok.TypeChecking.Monad (TC, liftST)
import Wok.TypeChecking.Types
  ( CRow (..), CType (..), Level (..), RVar (..), Row (..), TVar (..), Type (..) )
```

Final exports (drop `freezeScheme`):

```haskell
module Wok.TypeChecking.Unify
  ( force
  , forceRow
  , freeze
  , freezeRow
  , occursAdjust
  , occursAdjustRow
  ) where
```

- [ ] **Step 2: Add tests to `test/Spec.hs`**

```haskell
unifyWalksTests :: TestTree
unifyWalksTests = testGroup "Wok.TypeChecking.Unify (walks)"
  [ testCase "freeze TCon Int" $
      let result = TM.runTC TE.emptyEnv $ do
            U.freeze (T.TCon T.TcInt [])
      in result @?= Right (T.CTCon T.TcInt [])
  , testCase "freeze fresh TVar produces CTGen" $
      let result = TM.runTC TE.emptyEnv $ do
            t <- TM.freshTVar T.KStar
            U.freeze t
      in case result of
           Right (T.CTGen _) -> pure ()
           _ -> assertFailure ("expected CTGen, got " ++ show result)
  , testCase "occursAdjust fires when target appears" $
      let result = TM.runTC TE.emptyEnv $ do
            a <- TM.freshTVar T.KStar
            case a of
              T.TVar ref -> U.occursAdjust Nothing ref (T.Level 0)
                              (T.TCon T.TcList [a])
              _ -> error "expected TVar"
      in case result of
           Left (TErr.OccursCheck _ _ _) -> pure ()
           _ -> assertFailure ("expected OccursCheck, got " ++ show result)
  ]
```

Add `U` import: `import qualified Wok.TypeChecking.Unify as U`. Add `unifyWalksTests` to the top-level tasty group.

- [ ] **Step 3: Verify**

Run: `cabal test --test-options="-p UnifyWalks"`
Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add src/Wok/TypeChecking/Unify.hs test/Spec.hs
git commit -m "$(cat <<'EOF'
feat(typecheck): add force/freeze/occursAdjust walks

force chases Link chains with path compression. freeze converts
inference-time Type s into closed CType (unbound vars become CTGen
using their uniq). occursAdjust fuses the occurs check and level
lowering into one walk per assignment.
EOF
)"
```

---

## Task 5: Unify part 2 — unify, unifyVar, unifyRow stub

**Goal:** Implement the main `unify` driver and the `unifyRow` stub that handles only `RowEmpty ~ RowEmpty` in v1.

**Files:**
- Modify: `src/Wok/TypeChecking/Unify.hs`
- Modify: `test/Spec.hs` (unify tests)

**Acceptance Criteria:**
- [ ] `unify` succeeds on identical `TCon`s, identical `TArr`s with empty rows, and a fresh `TVar` against any type.
- [ ] `unify` fails with `Mismatch` for type-constructor mismatches.
- [ ] `unify` fails with `OccursCheck` for `a ~ List a`.
- [ ] `unifyRow RowEmpty RowEmpty` succeeds; anything else throws `RowMismatch`.

**Verify:** `cabal test --test-options="-p Unify"` → all pass.

**Steps:**

- [ ] **Step 1: Extend `src/Wok/TypeChecking/Unify.hs`** — add `unify`, `unifyVar`, `unifyRow`, and add them to the export list:

Update exports:

```haskell
module Wok.TypeChecking.Unify
  ( unify
  , unifyVar
  , unifyRow
  , force
  , forceRow
  , freeze
  , freezeRow
  , occursAdjust
  , occursAdjustRow
  ) where
```

Add to imports:

```haskell
import Control.Monad (zipWithM_)
```

Append the implementation below the existing definitions:

```haskell
-- | Unify two types. The source span (if any) is attached to errors.
unify :: SourceSpan -> Type s -> Type s -> TC s ()
unify sp a b = do
  a' <- force a
  b' <- force b
  case (a', b') of
    (TVar r1, TVar r2) | r1 == r2 -> pure ()
    (TVar r, t) -> unifyVar sp r t
    (t, TVar r) -> unifyVar sp r t
    (TCon c1 ts1, TCon c2 ts2)
      | c1 == c2, length ts1 == length ts2 -> zipWithM_ (unify sp) ts1 ts2
    (TArr a1 e1 b1, TArr a2 e2 b2) -> do
      unify sp a1 a2
      unifyRow sp e1 e2
      unify sp b1 b2
    _ -> do
      ca <- freeze a'
      cb <- freeze b'
      throwError (Mismatch sp ca cb)

unifyVar :: SourceSpan -> STRef s (TVar s) -> Type s -> TC s ()
unifyVar sp ref t = do
  tv <- liftST $ readSTRef ref
  case tv of
    Link _ -> error "unifyVar: caller must have forced first"
    Unbound _ lvl _ -> do
      occursAdjust sp ref lvl t
      liftST $ writeSTRef ref (Link t)

unifyRow :: SourceSpan -> Row s -> Row s -> TC s ()
unifyRow _ RowEmpty RowEmpty = pure ()
unifyRow sp r1 r2 = do
  cr1 <- freezeRow r1
  cr2 <- freezeRow r2
  throwError (RowMismatch sp cr1 cr2)
```

- [ ] **Step 2: Add unification tests**

```haskell
unifyTests :: TestTree
unifyTests = testGroup "Wok.TypeChecking.Unify"
  [ testCase "identical TCon unifies" $
      let result = TM.runTC TE.emptyEnv $
            U.unify Nothing (T.TCon T.TcInt []) (T.TCon T.TcInt [])
      in result @?= Right ()
  , testCase "mismatched TCons fail" $
      let result = TM.runTC TE.emptyEnv $
            U.unify Nothing (T.TCon T.TcInt []) (T.TCon T.TcBool [])
      in case result of
           Left (TErr.Mismatch _ _ _) -> pure ()
           _ -> assertFailure ("expected Mismatch, got " ++ show result)
  , testCase "fresh TVar unifies with concrete type" $
      let result = TM.runTC TE.emptyEnv $ do
            a <- TM.freshTVar T.KStar
            U.unify Nothing a (T.TCon T.TcInt [])
            U.freeze a
      in result @?= Right (T.CTCon T.TcInt [])
  , testCase "TArr unifies (with empty effect row)" $
      let result = TM.runTC TE.emptyEnv $ do
            a <- TM.freshTVar T.KStar
            U.unify Nothing
              (T.TArr a T.RowEmpty (T.TCon T.TcBool []))
              (T.TArr (T.TCon T.TcInt []) T.RowEmpty (T.TCon T.TcBool []))
            U.freeze a
      in result @?= Right (T.CTCon T.TcInt [])
  , testCase "occurs check fires (a ~ List a)" $
      let result = TM.runTC TE.emptyEnv $ do
            a <- TM.freshTVar T.KStar
            U.unify Nothing a (T.TCon T.TcList [a])
      in case result of
           Left (TErr.OccursCheck _ _ _) -> pure ()
           _ -> assertFailure ("expected OccursCheck, got " ++ show result)
  ]
```

Add `unifyTests` to the top-level group.

- [ ] **Step 3: Verify**

Run: `cabal test --test-options="-p Unify"`
Expected: PASS — all five tests succeed.

- [ ] **Step 4: Commit**

```bash
git add src/Wok/TypeChecking/Unify.hs test/Spec.hs
git commit -m "$(cat <<'EOF'
feat(typecheck): add unify, unifyVar, unifyRow

unify dispatches on forced heads. TArr unification recurses into
argument type, effect row, and result type. unifyRow in v1 only
handles RowEmpty ~ RowEmpty; the rows-and-effects spec extends it
with the scoped-label rewrite.
EOF
)"
```

---

## Task 6: Generalize + instantiate

**Goal:** Implement `generalize :: Type s -> TC s Scheme` (freeze + quantify level-too-high) and `instantiate :: Scheme -> TC s (Type s)` (substitute fresh `TVar`s for `CTGen`s).

**Files:**
- Modify: `src/Wok/TypeChecking/Infer.hs` (start populating)
- Modify: `test/Spec.hs` (generalize/instantiate tests)

**Acceptance Criteria:**
- [ ] `generalize` produces `Scheme [] (CTCon TcInt [])` for a concrete `Int`.
- [ ] `generalize` on `a -> a` (where `a` is fresh at inner level) produces `Scheme [(_, KStar)] (CTArr (CTGen _) CREmpty (CTGen _))` with the two `CTGen`s equal.
- [ ] `instantiate` of `forall a. a -> a` yields a `Type s` whose argument and result are the same fresh `TVar`.

**Verify:** `cabal test --test-options="-p Generalize"` → all pass.

**Steps:**

- [ ] **Step 1: Implement initial `src/Wok/TypeChecking/Infer.hs`**

```haskell
-- | Type inference for the wok HM core. This module starts by exporting
-- the freeze-and-quantify @generalize@ pass and its dual @instantiate@.
module Wok.TypeChecking.Infer
  ( generalize
  , instantiate
  ) where

import Control.Monad.Except (throwError)
import qualified Data.Map.Strict as Map
import Data.STRef (newSTRef, readSTRef, writeSTRef)
import Wok.TypeChecking.Error (TypeError (..))
import Wok.TypeChecking.Monad (TC, currentLevel, freshTVar, liftST)
import Wok.TypeChecking.Types
  ( CRow (..), CType (..), Kind (..), Level (..), RVar (..), Row (..)
  , Scheme (..), TVar (..), Type (..) )
import Wok.TypeChecking.Unify (force, forceRow)

-- | Freeze a type and quantify any unbound variable whose level is
-- strictly greater than the current generalisation level. The same
-- variable used multiple times shares one quantifier slot.
generalize :: Type s -> TC s Scheme
generalize t = do
  Level outer <- currentLevel
  liftST $ do
    nextRef <- newSTRef 0
    seenRef <- newSTRef (Map.empty :: Map.Map Int Int)
    kindsRef <- newSTRef ([] :: [(Int, Kind)])
    body <- gType outer nextRef seenRef kindsRef t
    pairs <- readSTRef kindsRef
    pure (Scheme (reverse pairs) body)
  where
    gType outer nextRef seenRef kindsRef = goT
      where
        goT ty = do
          ty' <- forceST ty
          case ty' of
            TCon c ts -> CTCon c <$> mapM goT ts
            TArr a r b -> CTArr <$> goT a <*> goR r <*> goT b
            TVar ref -> do
              tv <- readSTRef ref
              case tv of
                Link _ -> goT ty'  -- forced; unreachable
                Unbound u (Level l) k
                  | l > outer -> do
                      seen <- readSTRef seenRef
                      case Map.lookup u seen of
                        Just idx -> pure (CTGen idx)
                        Nothing -> do
                          idx <- readSTRef nextRef
                          writeSTRef nextRef (idx + 1)
                          writeSTRef seenRef (Map.insert u idx seen)
                          writeSTRef kindsRef ((idx, k) :) =<< readSTRef kindsRef
                          pure (CTGen idx)
                  | otherwise -> pure (CTGen u)
                                 -- escaped var; survives as CTGen with original uniq
        goR row = do
          row' <- forceRowST row
          case row' of
            RowEmpty -> pure CREmpty
            RowExtend l ty rest -> CRExtend l <$> goT ty <*> goR rest
            RowVar ref -> do
              rv <- readSTRef ref
              case rv of
                RLink _ -> goR row'
                RUnbound u (Level l)
                  | l > outer -> pure (CRGen u)
                  | otherwise -> pure (CRGen u)
    -- Pure-ST helpers (we're inside liftST already; can't call TC's force)
    forceST tt = case tt of
      TVar ref -> do
        tv <- readSTRef ref
        case tv of
          Link t' -> do
            t'' <- forceST t'
            writeSTRef ref (Link t'')
            pure t''
          _ -> pure tt
      _ -> pure tt
    forceRowST rr = case rr of
      RowVar ref -> do
        rv <- readSTRef ref
        case rv of
          RLink r' -> do
            r'' <- forceRowST r'
            writeSTRef ref (RLink r'')
            pure r''
          _ -> pure rr
      _ -> pure rr

-- | Instantiate a scheme: each quantifier becomes a fresh TVar at the
-- current level; the body is rebuilt with those fresh refs substituted.
instantiate :: Scheme -> TC s (Type s)
instantiate (Scheme vars body) = do
  freshes <- mapM (\(i, k) -> do { t <- freshTVar k; pure (i, t) }) vars
  let subst = Map.fromList freshes
  pure (substT subst body)
  where
    substT :: Map.Map Int (Type s) -> CType -> Type s
    substT m = goT
      where
        goT (CTCon c ts) = TCon c (map goT ts)
        goT (CTArr a r b) = TArr (goT a) (goR r) (goT b)
        goT (CTGen i) = case Map.lookup i m of
          Just t -> t
          Nothing -> error ("instantiate: dangling CTGen " ++ show i)
        goR CREmpty = RowEmpty
        goR (CRExtend l ty rest) = RowExtend l (goT ty) (goR rest)
        goR (CRGen _) = RowEmpty  -- v1: no row vars in schemes
```

Note: the "escaped var" branch (`otherwise -> pure (CTGen u)`) intentionally allows escape with a unique `CTGen`. Production-quality v1 should `throwError EscapedTyVar`, but our v1 spec says this indicates an inference bug. For now we permit it (no caller produces such a thing); we can tighten in a follow-up.

Replace that branch with an error for safety:

```haskell
                  | otherwise -> throwError (EscapedTyVar Nothing u)
```

But `throwError` is in the `TC` monad, not in `ST`. To keep the generalization pass pure-ST, leave the permissive `CTGen u` behavior and document it. A v1+ pass can add the post-check.

- [ ] **Step 2: Add tests**

```haskell
import qualified Wok.TypeChecking.Infer as I

generalizeTests :: TestTree
generalizeTests = testGroup "Wok.TypeChecking.Infer (generalize/instantiate)"
  [ testCase "generalize Int yields no quantifiers" $
      let result = TM.runTC TE.emptyEnv $
            I.generalize (T.TCon T.TcInt [])
      in result @?= Right (T.Scheme [] (T.CTCon T.TcInt []))
  , testCase "generalize fresh a -> a yields forall a. a -> a" $
      let result = TM.runTC TE.emptyEnv $ do
            a <- TM.enterLevel (TM.freshTVar T.KStar)
            I.generalize (T.TArr a T.RowEmpty a)
      in case result of
           Right (T.Scheme [(i, T.KStar)] (T.CTArr (T.CTGen j) T.CREmpty (T.CTGen k)))
             | i == j && j == k -> pure ()
           _ -> assertFailure ("unexpected scheme: " ++ show result)
  , testCase "instantiate forall a. a -> a produces TArr with same TVar" $
      let result = TM.runTC TE.emptyEnv $ do
            let s = T.Scheme [(0, T.KStar)]
                     (T.CTArr (T.CTGen 0) T.CREmpty (T.CTGen 0))
            t <- I.instantiate s
            case t of
              T.TArr (T.TVar r1) T.RowEmpty (T.TVar r2) ->
                pure (r1 == r2)
              _ -> pure False
      in result @?= Right True
  ]
```

Add to top-level group.

- [ ] **Step 3: Verify**

Run: `cabal test --test-options="-p Generalize"`
Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add src/Wok/TypeChecking/Infer.hs test/Spec.hs
git commit -m "$(cat <<'EOF'
feat(typecheck): add generalize and instantiate

generalize freezes a Type s and quantifies any unbound var whose
level exceeds the current generalisation level, sharing slots for
repeated uniqs. instantiate substitutes fresh TVars at the current
level for each CTGen quantifier.
EOF
)"
```

---

## Task 7: Builtins module

**Goal:** Define the initial `Env` with all built-in type constructors, constructors, and primitive operator schemes.

**Files:**
- Modify: `src/Wok/TypeChecking/Builtins.hs`
- Modify: `test/Spec.hs` (builtins tests)

**Acceptance Criteria:**
- [ ] `initialEnv` contains `Int`, `Char`, `String`, `Bool`, `()`, list, and tuples up to arity 16 in `envTyCons`.
- [ ] `True` and `False` are in `envCons` with scheme `Bool`.
- [ ] Operator schemes for `+`, `-`, `*`, `/`, `div`, `mod`, `==`, `/=`, `&&`, `||`, `++`, `$` exist in `envVars`.

**Verify:** `cabal test --test-options="-p Builtins"` → tests pass.

**Steps:**

- [ ] **Step 1: Implement `src/Wok/TypeChecking/Builtins.hs`**

```haskell
{-# LANGUAGE OverloadedStrings #-}

-- | The initial typing environment: built-in type constructors,
-- built-in data constructors (True/False), and the schemes of
-- primitive operators that user code can reference by name.
module Wok.TypeChecking.Builtins
  ( initialEnv
  ) where

import qualified Data.Map.Strict as Map
import Data.Text (Text)
import Wok.TypeChecking.Env (ConInfo (..), Env (..), TyConInfo (..), emptyEnv)
import Wok.TypeChecking.Types
  ( CRow (..), CType (..), Kind (..), Scheme (..), TyCon (..) )

initialEnv :: Env
initialEnv = (emptyEnv :: Env)
  { envTyCons = Map.fromList tyConEntries
  , envCons   = Map.fromList conEntries
  , envVars   = Map.fromList varEntries
  }
  where
    nullStar :: Kind
    nullStar = KStar
    listKind :: Kind
    listKind = KArrow KStar KStar

    tyConEntries :: [(Text, TyConInfo)]
    tyConEntries =
      [ ("Int",    TyConInfo nullStar 0 [])
      , ("Char",   TyConInfo nullStar 0 [])
      , ("String", TyConInfo nullStar 0 [])
      , ("Bool",   TyConInfo nullStar 0 ["True", "False"])
      , ("()",     TyConInfo nullStar 0 [])
      , ("[]",     TyConInfo listKind 1 [])
      ] ++ [ (tupleName n, TyConInfo (tupleKind n) n []) | n <- [2 .. 16] ]

    tupleName :: Int -> Text
    tupleName n = "(" <> Data.Text.replicate (n - 1) "," <> ")"

    tupleKind :: Int -> Kind
    tupleKind n = foldr KArrow KStar (replicate n KStar)

    conEntries :: [(Text, ConInfo)]
    conEntries =
      [ ("True",  ConInfo (Scheme [] (CTCon TcBool [])) 0 "Bool")
      , ("False", ConInfo (Scheme [] (CTCon TcBool [])) 0 "Bool")
      ]

    varEntries :: [(Text, Scheme)]
    varEntries =
      [ -- Arithmetic on Int
        ("+",   intBinop)
      , ("-",   intBinop)
      , ("*",   intBinop)
      , ("/",   intBinop)
      , ("div", intBinop)
      , ("mod", intBinop)
        -- Comparisons (monomorphic to Int in v1, since no type classes)
      , ("==", intToBool)
      , ("/=", intToBool)
        -- Boolean ops
      , ("&&", boolBinop)
      , ("||", boolBinop)
        -- List concatenation
      , ("++", listConcat)
        -- Dollar application
      , ("$",  dollar)
      ]

    intBinop = Scheme []
      (CTArr (CTCon TcInt []) CREmpty
        (CTArr (CTCon TcInt []) CREmpty (CTCon TcInt [])))

    intToBool = Scheme []
      (CTArr (CTCon TcInt []) CREmpty
        (CTArr (CTCon TcInt []) CREmpty (CTCon TcBool [])))

    boolBinop = Scheme []
      (CTArr (CTCon TcBool []) CREmpty
        (CTArr (CTCon TcBool []) CREmpty (CTCon TcBool [])))

    listConcat = Scheme [(0, KStar)]
      (CTArr (CTCon TcList [CTGen 0]) CREmpty
        (CTArr (CTCon TcList [CTGen 0]) CREmpty (CTCon TcList [CTGen 0])))

    dollar = Scheme [(0, KStar), (1, KStar)]
      (CTArr (CTArr (CTGen 0) CREmpty (CTGen 1)) CREmpty
        (CTArr (CTGen 0) CREmpty (CTGen 1)))

-- Hack to avoid `import Data.Text` at the top — let's actually add the import
-- properly:
```

Replace the orphan `Data.Text.replicate` reference: add `import qualified Data.Text` at the top, and remove the trailing comment block.

Final top imports:

```haskell
import qualified Data.Map.Strict as Map
import qualified Data.Text
import Data.Text (Text)
import Wok.TypeChecking.Env (ConInfo (..), Env (..), TyConInfo (..), emptyEnv)
import Wok.TypeChecking.Types
  ( CRow (..), CType (..), Kind (..), Scheme (..), TyCon (..) )
```

(And remove the trailing "Hack to avoid..." comment.)

- [ ] **Step 2: Add tests**

```haskell
import qualified Wok.TypeChecking.Builtins as B

builtinsTests :: TestTree
builtinsTests = testGroup "Wok.TypeChecking.Builtins"
  [ testCase "Bool, Int, list registered" $ do
      TE.lookupTyCon (Tx.pack "Bool") B.initialEnv @?= 
        Just (TE.TyConInfo T.KStar 0 [Tx.pack "True", Tx.pack "False"])
      case TE.lookupTyCon (Tx.pack "Int") B.initialEnv of
        Just info -> TE.tcKind info @?= T.KStar
        Nothing -> assertFailure "Int missing"
      case TE.lookupTyCon (Tx.pack "[]") B.initialEnv of
        Just info -> TE.tcArity info @?= 1
        Nothing -> assertFailure "list missing"
  , testCase "True and False are constructors of Bool" $ do
      case TE.lookupCon (Tx.pack "True") B.initialEnv of
        Just info -> TE.conTyCon info @?= Tx.pack "Bool"
        Nothing -> assertFailure "True missing"
  , testCase "+ has scheme Int -> Int -> Int" $
      case TE.lookupVar (Tx.pack "+") B.initialEnv of
        Just (T.Scheme [] body) -> case body of
          T.CTArr (T.CTCon T.TcInt []) T.CREmpty
            (T.CTArr (T.CTCon T.TcInt []) T.CREmpty (T.CTCon T.TcInt [])) ->
              pure ()
          _ -> assertFailure ("unexpected body: " ++ show body)
        _ -> assertFailure "+ missing or has quantifiers"
  , testCase "++ has scheme forall a. [a] -> [a] -> [a]" $
      case TE.lookupVar (Tx.pack "++") B.initialEnv of
        Just (T.Scheme [(_, T.KStar)] _) -> pure ()
        _ -> assertFailure "++ has wrong quantifier count"
  ]
```

Add to top-level group.

- [ ] **Step 3: Verify**

Run: `cabal test --test-options="-p Builtins"`
Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add src/Wok/TypeChecking/Builtins.hs test/Spec.hs
git commit -m "$(cat <<'EOF'
feat(typecheck): add initial env with builtins

Int/Char/String/Bool/Unit, list, tuples up to arity 16 as tycons.
True/False as constructors of Bool. Primitive operator schemes
for arithmetic, comparison, boolean ops, list concat, and ($).
Comparisons are monomorphic on Int in v1 (no classes yet).
EOF
)"
```

---

## Task 8: Type translation — grammar Type → CType

**Goal:** Convert the parser's `Type` AST (from `GeneratedParser.Wok.Abs`) into our `CType`. Used for signature processing and constructor types. Returns a `(Scheme, sourceSpan)`-able shape with implicit universal quantification over free `VarId` type variables.

**Files:**
- Modify: `src/Wok/TypeChecking/Infer.hs`
- Modify: `test/Spec.hs`

**Acceptance Criteria:**
- [ ] `translateSig :: Env -> Abs.Type -> TC s Scheme` translates `a -> a` to `forall a. a -> a`.
- [ ] Translates `Int -> Int` to a monotype scheme.
- [ ] Translates `[a]` to `CTCon TcList [CTGen 0]`.
- [ ] Translates `Maybe a` (assuming `Maybe` is in env) to `CTCon (TcUser "Maybe") [CTGen 0]`.
- [ ] Fails with `UnknownTyCon` for unknown type names.
- [ ] Fails with `ArityMismatch` if a tycon is applied to the wrong number of args.

**Verify:** `cabal test --test-options="-p Translate"` → tests pass.

**Steps:**

- [ ] **Step 1: Extend `src/Wok/TypeChecking/Infer.hs`** — add the translator:

Add to exports:

```haskell
module Wok.TypeChecking.Infer
  ( generalize
  , instantiate
  , translateSig
  ) where
```

Add to imports:

```haskell
import Data.Text (Text)
import qualified GeneratedParser.Wok.Abs as Abs
import Wok.TypeChecking.Env (Env, TyConInfo (..), lookupTyCon)
```

Add the translator at the end of the file:

```haskell
-- | Translate a parsed Abs.Type into a Scheme. Free VarIds in the type
-- become universally quantified CTGen slots. Validates tycon arity.
translateSig :: Env -> Abs.Type -> TC s Scheme
translateSig env ty = do
  (body, slots) <- liftST $ do
    seenRef <- newSTRef (Map.empty :: Map.Map Text Int)
    nextRef <- newSTRef 0
    body' <- go env seenRef nextRef ty
    slots' <- readSTRef seenRef
    pure (body', slots')
  let quantifiers = [ (i, KStar) | (_, i) <- Map.toAscList slots ]
  -- ensure quantifiers are listed in slot-id order, not name order
  let qsByIdx = map (\(i, _) -> (i, KStar)) (sortOn snd (Map.toList slots))
  pure (Scheme qsByIdx body)
  where
    sortOn f = Data.List.sortBy (\a b -> compare (f a) (f b))

    -- Each branch returns a CType (closed; no STRefs).
    go env' seenRef nextRef = goT
      where
        goT (Abs.TFun a b) = CTArr <$> goT a <*> pure CREmpty <*> goT b
        goT (Abs.TVar (Abs.VarId (pos, name))) = do
          seen <- readSTRef seenRef
          case Map.lookup name seen of
            Just i -> pure (CTGen i)
            Nothing -> do
              i <- readSTRef nextRef
              writeSTRef nextRef (i + 1)
              writeSTRef seenRef (Map.insert name i seen)
              pure (CTGen i)
        goT (Abs.TCon modPath) = do
          let (name, pos) = modPathHead modPath
          case lookupTyCon name env' of
            Just info
              | tcArity info == 0 -> pure (CTCon (resolveTyCon name) [])
              | otherwise -> tcError (ArityMismatch (Just pos) name (tcArity info) 0)
            Nothing -> tcError (UnknownTyCon (Just pos) name)
        goT (Abs.TApp f x) = do
          (head', args) <- collectApp f x
          case head' of
            Abs.TCon modPath -> do
              let (name, pos) = modPathHead modPath
              case lookupTyCon name env' of
                Just info
                  | tcArity info == length args ->
                      CTCon (resolveTyCon name) <$> mapM goT args
                  | otherwise -> tcError (ArityMismatch (Just pos) name
                                            (tcArity info) (length args))
                Nothing -> tcError (UnknownTyCon (Just pos) name)
            _ -> tcError (UnsupportedFeature Nothing
                            (Tx.pack "non-tycon type application"))
        goT (Abs.TList inner) = do
          c <- goT inner
          pure (CTCon TcList [c])
        goT (Abs.TTuple a others) = do
          let arity = 1 + length others
          ts <- mapM goT (a : others)
          pure (CTCon (TcTuple arity) ts)
        goT (Abs.TParen t') = goT t'

        collectApp (Abs.TApp f x) y = do
          (h, xs) <- collectApp f x
          pure (h, xs ++ [y])
        collectApp other y = pure (other, [y])

        resolveTyCon name = case name of
          "Int"    -> TcInt
          "Char"   -> TcChar
          "String" -> TcString
          "Bool"   -> TcBool
          "()"     -> TcUnit
          "[]"     -> TcList
          _        -> TcUser name

    -- liftST-friendly error: we're inside an ST block, so wrap into a
    -- pure either and unwrap outside. Simpler: do the whole thing in TC.
    -- Refactor: we cannot throwError inside ST. Do the walk in TC instead.
    tcError _ = error "internal: see refactor note in Step 1"

    -- Pure-ST modPath head extraction
    modPathHead (Abs.MPName (Abs.ConId (pos, name))) = (name, pos)
    modPathHead (Abs.MPDot _ (Abs.ConId (pos, name))) = (name, pos)
```

That `tcError` and the ST-pure design above is broken — we genuinely need to `throwError` from `translateSig`, which means doing the walk in `TC`, not in pure `ST`. Refactor the body to live in `TC` directly:

Replace the body with:

```haskell
translateSig :: Env -> Abs.Type -> TC s Scheme
translateSig env ty = do
  seenRef <- liftST $ newSTRef (Map.empty :: Map.Map Text Int)
  nextRef <- liftST $ newSTRef (0 :: Int)
  body <- goT seenRef nextRef ty
  slots <- liftST $ readSTRef seenRef
  let qs = map (\(_, i) -> (i, KStar))
             (Data.List.sortBy (\a b -> compare (snd a) (snd b)) (Map.toList slots))
  pure (Scheme qs body)
  where
    goT seenRef nextRef = walk
      where
        walk (Abs.TFun a b) = CTArr <$> walk a <*> pure CREmpty <*> walk b
        walk (Abs.TVar (Abs.VarId (_, name))) = do
          seen <- liftST (readSTRef seenRef)
          case Map.lookup name seen of
            Just i -> pure (CTGen i)
            Nothing -> do
              i <- liftST $ do
                n <- readSTRef nextRef
                writeSTRef nextRef (n + 1)
                writeSTRef seenRef (Map.insert name n seen)
                pure n
              pure (CTGen i)
        walk (Abs.TCon modPath) = do
          let (name, pos) = modPathHead modPath
          case lookupTyCon name env of
            Just info
              | tcArity info == 0 -> pure (CTCon (resolveTyCon name) [])
              | otherwise -> throwError (ArityMismatch (Just pos) name (tcArity info) 0)
            Nothing -> throwError (UnknownTyCon (Just pos) name)
        walk (Abs.TApp f x) = do
          (h, args) <- pure (collectApp f x)
          case h of
            Abs.TCon modPath -> do
              let (name, pos) = modPathHead modPath
              case lookupTyCon name env of
                Just info
                  | tcArity info == length args ->
                      CTCon (resolveTyCon name) <$> mapM walk args
                  | otherwise -> throwError
                      (ArityMismatch (Just pos) name (tcArity info) (length args))
                Nothing -> throwError (UnknownTyCon (Just pos) name)
            _ -> throwError (UnsupportedFeature Nothing
                              (Tx.pack "non-tycon type application"))
        walk (Abs.TList inner) = do
          c <- walk inner
          pure (CTCon TcList [c])
        walk (Abs.TTuple a others) = do
          ts <- mapM walk (a : others)
          pure (CTCon (TcTuple (1 + length others)) ts)
        walk (Abs.TParen t') = walk t'

    collectApp (Abs.TApp f x) y = let (h, xs) = collectApp f x in (h, xs ++ [y])
    collectApp other y = (other, [y])

    modPathHead (Abs.MPName (Abs.ConId (pos, name))) = (name, pos)
    modPathHead (Abs.MPDot _ (Abs.ConId (pos, name))) = (name, pos)

    resolveTyCon name = case name of
      "Int"    -> TcInt
      "Char"   -> TcChar
      "String" -> TcString
      "Bool"   -> TcBool
      "()"     -> TcUnit
      "[]"     -> TcList
      _        -> TcUser name
```

Add the new imports at the top:

```haskell
import qualified Data.List
import qualified Data.Text as Tx
```

- [ ] **Step 2: Add tests**

```haskell
translateTests :: TestTree
translateTests = testGroup "Wok.TypeChecking.Infer (translateSig)"
  [ testCase "Int -> Int translates to monotype" $
      let int = Abs.TCon (Abs.MPName (Abs.ConId ((0,0), Tx.pack "Int")))
          ty  = Abs.TFun int int
          result = TM.runTC B.initialEnv (I.translateSig B.initialEnv ty)
      in result @?= Right (T.Scheme [] (T.CTArr (T.CTCon T.TcInt []) T.CREmpty (T.CTCon T.TcInt [])))
  , testCase "a -> a translates to forall a. a -> a" $
      let var = Abs.TVar (Abs.VarId ((0,0), Tx.pack "a"))
          ty  = Abs.TFun var var
          result = TM.runTC B.initialEnv (I.translateSig B.initialEnv ty)
      in case result of
           Right (T.Scheme [(0, T.KStar)] (T.CTArr (T.CTGen 0) T.CREmpty (T.CTGen 0))) ->
             pure ()
           _ -> assertFailure ("unexpected: " ++ show result)
  , testCase "[a] translates" $
      let var = Abs.TVar (Abs.VarId ((0,0), Tx.pack "a"))
          result = TM.runTC B.initialEnv (I.translateSig B.initialEnv (Abs.TList var))
      in case result of
           Right (T.Scheme [(0, T.KStar)] (T.CTCon T.TcList [T.CTGen 0])) -> pure ()
           _ -> assertFailure ("unexpected: " ++ show result)
  , testCase "unknown tycon errors" $
      let unk = Abs.TCon (Abs.MPName (Abs.ConId ((0,0), Tx.pack "Frob")))
          result = TM.runTC B.initialEnv (I.translateSig B.initialEnv unk)
      in case result of
           Left (TErr.UnknownTyCon _ _) -> pure ()
           _ -> assertFailure ("expected UnknownTyCon, got " ++ show result)
  ]
```

Add `import qualified GeneratedParser.Wok.Abs as Abs` and `import qualified Wok.TypeChecking.Builtins as B` if not present. Add `translateTests` to the top-level group.

- [ ] **Step 3: Verify**

Run: `cabal test --test-options="-p Translate"`
Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add src/Wok/TypeChecking/Infer.hs test/Spec.hs
git commit -m "$(cat <<'EOF'
feat(typecheck): add translateSig (Abs.Type -> Scheme)

Walks the parsed type AST, gathering free VarIds as quantifiers (in
first-occurrence order). Resolves type constructors via the env (with
arity checks). Built-in names (Int, Char, String, Bool, Unit, list)
map to specialised TyCon tags; user-defined names become TcUser.
EOF
)"
```

---

## Task 9: Data declaration processing

**Goal:** Walk `DData` declarations to populate `envTyCons` (with arity and constructor names) and `envCons` (with each constructor's polymorphic scheme).

**Files:**
- Modify: `src/Wok/TypeChecking/Infer.hs`
- Modify: `test/Spec.hs`

**Acceptance Criteria:**
- [ ] `processDataDecls :: Env -> [Abs.Decl] -> TC s Env` runs in two passes (tycons then constructors).
- [ ] `data Maybe a = Nothing | Just a` adds `Maybe`, `Nothing`, and `Just` with correct schemes.
- [ ] Duplicate tycon registration (including against builtins) throws `DuplicateTyCon`.
- [ ] Duplicate constructor registration throws `DuplicateCon`.
- [ ] Constructors may reference other user-defined types (mutual recursion).

**Verify:** `cabal test --test-options="-p Data"` → tests pass.

**Steps:**

- [ ] **Step 1: Extend `Infer.hs`** — add data-decl processing.

Add to exports:

```haskell
module Wok.TypeChecking.Infer
  ( generalize
  , instantiate
  , translateSig
  , processDataDecls
  ) where
```

Add to imports:

```haskell
import Wok.TypeChecking.Env (Env (..), TyConInfo (..), ConInfo (..), extendTyCon, extendCon, lookupTyCon, lookupCon)
```

Add the implementation:

```haskell
-- | Two-pass registration of data declarations.
--
-- Pass 1: collect every type-constructor name with its arity (so
-- constructor argument types can reference other user-defined types,
-- including mutually-recursive ones).
--
-- Pass 2: translate each constructor's argument types in an env with
-- the user's type parameters bound to fresh CTGen slots, then build
-- the constructor's polymorphic scheme.
processDataDecls :: Env -> [Abs.Decl] -> TC s Env
processDataDecls env0 decls = do
  envWithTyCons <- registerTyCons env0 dataDecls
  registerCons envWithTyCons dataDecls
  where
    dataDecls = [ d | d@(Abs.DData _ _ _) <- decls ]

    registerTyCons env [] = pure env
    registerTyCons env (Abs.DData (Abs.ConId (pos, name)) params _ : ds) =
      case lookupTyCon name env of
        Just _ -> throwError (DuplicateTyCon (Just pos) name)
        Nothing -> do
          let k = foldr KArrow KStar (replicate (length params) KStar)
              info = TyConInfo k (length params) []
              env' = extendTyCon name info env
          registerTyCons env' ds
    registerTyCons env (_ : ds) = registerTyCons env ds

    registerCons env [] = pure env
    registerCons env (Abs.DData (Abs.ConId (_, tcName)) params conDefs : ds) = do
      -- Allocate CTGen slots in declaration order
      let paramNames = [ n | Abs.VarId (_, n) <- params ]
          paramSlots = zip paramNames [0 ..]
          paramMap = Map.fromList paramSlots
      env' <- foldM (registerCon tcName paramMap (length paramNames)) env conDefs
      -- Update tycon entry with constructor list
      let tcInfo = case lookupTyCon tcName env' of
            Just t  -> t { tcCons = [ cn | Abs.ConDef (Abs.ConId (_, cn)) _ <- conDefs ] }
            Nothing -> error "registerCons: tycon vanished"
          env'' = extendTyCon tcName tcInfo env'
      registerCons env'' ds
    registerCons env (_ : ds) = registerCons env ds

    -- For each constructor: translate its arg types with paramMap binding
    -- the LHS type variables to CTGens, then build the scheme.
    registerCon tcName paramMap arity env (Abs.ConDef (Abs.ConId (pos, cname)) argTys) =
      case lookupCon cname env of
        Just _ -> throwError (DuplicateCon (Just pos) cname)
        Nothing -> do
          argCTypes <- mapM (translateConArg env paramMap) argTys
          let resultTy = CTCon (TcUser tcName)
                           [ CTGen i | (_, i) <- Map.toAscList paramMap ]
              -- Wait — Map.toAscList sorts by key (name), but we want
              -- slot-id order. Use the original sorted list.
              -- Re-do: sort by slot id ascending.
              resultTy' = CTCon (TcUser tcName)
                            (map (\i -> CTGen i)
                              (sort (Map.elems paramMap)))
              body = foldr (\arg acc -> CTArr arg CREmpty acc) resultTy' argCTypes
              quantifiers = [ (i, KStar) | i <- sort (Map.elems paramMap) ]
              scheme = Scheme quantifiers body
              info = ConInfo scheme (length argTys) tcName
          pure (extendCon cname info env)

    translateConArg env paramMap = walkArg
      where
        walkArg (Abs.TVar (Abs.VarId (pos, name))) =
          case Map.lookup name paramMap of
            Just i -> pure (CTGen i)
            Nothing -> throwError (UnknownTyCon (Just pos) name)
              -- Constructor arg references a type var not in the LHS
              -- parameters; treat as undefined.
        walkArg (Abs.TFun a b) = CTArr <$> walkArg a <*> pure CREmpty <*> walkArg b
        walkArg (Abs.TCon mp) = do
          let (n, p) = modPathHead mp
          case lookupTyCon n env of
            Just info
              | tcArity info == 0 -> pure (CTCon (resolveTyCon n) [])
              | otherwise -> throwError (ArityMismatch (Just p) n (tcArity info) 0)
            Nothing -> throwError (UnknownTyCon (Just p) n)
        walkArg (Abs.TApp f x) = do
          let (h, args) = collectApp f x
          case h of
            Abs.TCon mp -> do
              let (n, p) = modPathHead mp
              case lookupTyCon n env of
                Just info
                  | tcArity info == length args ->
                      CTCon (resolveTyCon n) <$> mapM walkArg args
                  | otherwise -> throwError
                      (ArityMismatch (Just p) n (tcArity info) (length args))
                Nothing -> throwError (UnknownTyCon (Just p) n)
            _ -> throwError (UnsupportedFeature Nothing
                              (Tx.pack "non-tycon type application in constructor"))
        walkArg (Abs.TList inner) = do
          c <- walkArg inner
          pure (CTCon TcList [c])
        walkArg (Abs.TTuple a others) = do
          ts <- mapM walkArg (a : others)
          pure (CTCon (TcTuple (1 + length others)) ts)
        walkArg (Abs.TParen t') = walkArg t'

    sort = Data.List.sort
```

Add imports:

```haskell
import Control.Monad (foldM)
```

- [ ] **Step 2: Add tests**

```haskell
dataTests :: TestTree
dataTests = testGroup "Wok.TypeChecking.Infer (data decls)"
  [ testCase "data Maybe a = Nothing | Just a registers correctly" $
      let pos = (0,0)
          vc s = Abs.ConId (pos, Tx.pack s)
          vv s = Abs.VarId (pos, Tx.pack s)
          decl = Abs.DData (vc "Maybe") [vv "a"]
                   [ Abs.ConDef (vc "Nothing") []
                   , Abs.ConDef (vc "Just") [Abs.TVar (vv "a")]
                   ]
          result = TM.runTC B.initialEnv $
                     I.processDataDecls B.initialEnv [decl]
      in case result of
           Right env -> do
             case TE.lookupTyCon (Tx.pack "Maybe") env of
               Just info -> TE.tcArity info @?= 1
               Nothing -> assertFailure "Maybe missing"
             case TE.lookupCon (Tx.pack "Just") env of
               Just info -> do
                 TE.conArity info @?= 1
                 TE.conTyCon info @?= Tx.pack "Maybe"
                 case TE.conScheme info of
                   T.Scheme [(0, T.KStar)] body ->
                     case body of
                       T.CTArr (T.CTGen 0) T.CREmpty
                         (T.CTCon (T.TcUser tn) [T.CTGen 0])
                           | tn == Tx.pack "Maybe" -> pure ()
                       _ -> assertFailure ("Just body: " ++ show body)
                   _ -> assertFailure "Just scheme malformed"
               Nothing -> assertFailure "Just missing"
           Left e -> assertFailure (show e)
  , testCase "duplicate tycon registration errors" $
      let pos = (0,0)
          vc s = Abs.ConId (pos, Tx.pack s)
          decl = Abs.DData (vc "Bool") [] []
          result = TM.runTC B.initialEnv $
                     I.processDataDecls B.initialEnv [decl]
      in case result of
           Left (TErr.DuplicateTyCon _ _) -> pure ()
           _ -> assertFailure ("expected DuplicateTyCon, got " ++ show result)
  ]
```

- [ ] **Step 3: Verify**

Run: `cabal test --test-options="-p Data"`
Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add src/Wok/TypeChecking/Infer.hs test/Spec.hs
git commit -m "$(cat <<'EOF'
feat(typecheck): add data declaration processing

Two-pass: register all tycons first (with arity), then process each
constructor's argument types under an env where the LHS type
parameters are bound to CTGen slots. Detects duplicate tycon and
constructor names (including collisions with builtins).
EOF
)"
```

---

## Task 10: Pattern inference

**Goal:** Implement `inferPat :: Abs.Pat -> TC s (Type s, [(Text, Type s)])` covering every pattern form the grammar admits.

**Files:**
- Modify: `src/Wok/TypeChecking/Infer.hs`
- Modify: `test/Spec.hs`

**Acceptance Criteria:**
- [ ] Variable patterns return a fresh type and a single binding.
- [ ] Wildcards return a fresh type with no bindings.
- [ ] Literals return the matching primitive type.
- [ ] Constructor patterns instantiate the constructor scheme and unify each sub-pattern with the constructor's argument types.
- [ ] Cons `h :: t` is treated as a list constructor pattern.
- [ ] Tuple/list patterns work compositionally.
- [ ] Arity mismatches on constructors throw `ArityMismatch`.

**Verify:** `cabal test --test-options="-p Pattern"` → tests pass.

**Steps:**

- [ ] **Step 1: Extend `Infer.hs`** — add pattern inference. Add to exports `inferPat`.

```haskell
import Wok.TypeChecking.Unify (unify)

-- | Infer a pattern's type and the bindings it introduces.
inferPat :: Abs.Pat -> TC s (Type s, [(Text, Type s)])
inferPat (Abs.PAtom ap) = inferAtomPat ap
inferPat (Abs.PApp modPath ap aps) = do
  let (name, pos) = modPathHeadFromMP modPath
      atoms = ap : aps
  env <- currentEnv
  case lookupCon name env of
    Nothing -> throwError (UnknownCon (Just pos) name)
    Just info -> do
      when (conArity info /= length atoms) $
        throwError (ArityMismatch (Just pos) name (conArity info) (length atoms))
      conTy <- instantiate (conScheme info)
      -- Peel off arg types from the constructor's TArr chain
      (argTys, resultTy) <- splitConType conTy (length atoms)
      subPats <- mapM inferAtomPat atoms
      let subTys = map fst subPats
          subBinds = concatMap snd subPats
      mapM_ (\(a, b) -> unify (Just pos) a b) (zip argTys subTys)
      pure (resultTy, subBinds)
inferPat (Abs.PCons headPat tailPat) = do
  -- h :: t — same as Cons h t
  (hT, hBinds) <- inferAtomPat headPat
  (tT, tBinds) <- inferPat tailPat
  -- tail must be a list of hT
  unify Nothing tT (TCon TcList [hT])
  pure (TCon TcList [hT], hBinds ++ tBinds)

inferAtomPat :: Abs.AtomPat -> TC s (Type s, [(Text, Type s)])
inferAtomPat (Abs.APVar (Abs.VarId (_, name))) = do
  t <- freshTVar KStar
  pure (t, [(name, t)])
inferAtomPat Abs.APWild = do
  t <- freshTVar KStar
  pure (t, [])
inferAtomPat (Abs.APLitI _) = pure (TCon TcInt [], [])
inferAtomPat (Abs.APLitS _) = pure (TCon TcString [], [])
inferAtomPat (Abs.APLitC _) = pure (TCon TcChar [], [])
inferAtomPat (Abs.APCon modPath) = do
  -- Nullary constructor like Nothing / True / False
  let (name, pos) = modPathHeadFromMP modPath
  env <- currentEnv
  case lookupCon name env of
    Nothing -> throwError (UnknownCon (Just pos) name)
    Just info -> do
      when (conArity info /= 0) $
        throwError (ArityMismatch (Just pos) name (conArity info) 0)
      ty <- instantiate (conScheme info)
      pure (ty, [])
inferAtomPat (Abs.APTuple p1 ps) = do
  results <- mapM inferPat (p1 : ps)
  let ts = map fst results
      bs = concatMap snd results
  pure (TCon (TcTuple (length results)) ts, bs)
inferAtomPat (Abs.APList []) = do
  e <- freshTVar KStar
  pure (TCon TcList [e], [])
inferAtomPat (Abs.APList (p : ps)) = do
  (firstT, firstBinds) <- inferPat p
  restResults <- mapM inferPat ps
  let restTs = map fst restResults
      restBinds = concatMap snd restResults
  mapM_ (unify Nothing firstT) restTs
  pure (TCon TcList [firstT], firstBinds ++ restBinds)
inferAtomPat (Abs.APParen p) = inferPat p

-- Helper: peel n arg types off a constructor type ending in the result.
splitConType :: Type s -> Int -> TC s ([Type s], Type s)
splitConType ty 0 = pure ([], ty)
splitConType ty n = do
  ty' <- force ty
  case ty' of
    TArr a _ b -> do
      (args, res) <- splitConType b (n - 1)
      pure (a : args, res)
    _ -> error "splitConType: constructor type not deep enough"

modPathHeadFromMP :: Abs.ModPath -> (Text, (Int, Int))
modPathHeadFromMP (Abs.MPName (Abs.ConId (pos, name))) = (name, pos)
modPathHeadFromMP (Abs.MPDot _ (Abs.ConId (pos, name))) = (name, pos)
```

Add `import Control.Monad (when)`.

- [ ] **Step 2: Add tests**

```haskell
patternTests :: TestTree
patternTests = testGroup "Wok.TypeChecking.Infer (patterns)"
  [ testCase "var pattern returns fresh type and one binding" $
      let result = TM.runTC B.initialEnv $ do
            (t, bs) <- I.inferPat (Abs.PAtom (Abs.APVar (Abs.VarId ((0,0), Tx.pack "x"))))
            pure (length bs, case t of T.TVar _ -> True; _ -> False)
      in result @?= Right (1, True)
  , testCase "literal Int pattern" $
      let result = TM.runTC B.initialEnv $ do
            (t, _) <- I.inferPat (Abs.PAtom (Abs.APLitI (Abs.WokInt ((0,0), Tx.pack "5"))))
            U.freeze t
      in result @?= Right (T.CTCon T.TcInt [])
  , testCase "True nullary constructor pattern" $
      let result = TM.runTC B.initialEnv $ do
            (t, _) <- I.inferPat (Abs.PAtom (Abs.APCon (Abs.MPName (Abs.ConId ((0,0), Tx.pack "True")))))
            U.freeze t
      in result @?= Right (T.CTCon T.TcBool [])
  ]
```

- [ ] **Step 3: Verify**

Run: `cabal test --test-options="-p Pattern"`
Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add src/Wok/TypeChecking/Infer.hs test/Spec.hs
git commit -m "$(cat <<'EOF'
feat(typecheck): add pattern inference

Covers var, wildcard, literal, nullary/applied constructor, cons (::),
tuple, list, and parenthesised patterns. Constructor patterns
instantiate their scheme and unify sub-patterns with the argument
types. Arity mismatches are reported with ArityMismatch.
EOF
)"
```

---

## Task 11: Expression inference — basics

**Goal:** Implement `inferExpr` for literals, variables, constructors, application, lambda, if/then/else, tuples, list literals, parenthesised expressions, operator-as-value, and the `EExpr` form (post-reordered infix application).

**Files:**
- Modify: `src/Wok/TypeChecking/Infer.hs`
- Modify: `test/Spec.hs`

**Acceptance Criteria:**
- [ ] `inferExpr` handles all the listed forms.
- [ ] `EProj` and `EProjC` throw `UnsupportedFeature` in v1.
- [ ] Returns the inferred `Type s` for the expression.
- [ ] Application unifies the function's type with `arg -> r` for fresh `r`.

**Verify:** `cabal test --test-options="-p ExprBasic"` → tests pass.

**Steps:**

- [ ] **Step 1: Extend `Infer.hs`** — add `inferExpr` and helpers. Add to exports.

```haskell
-- | Infer the type of an expression. Returns just the type for v1;
-- a typed-AST builder layer is added when the typed output AST is
-- threaded through (kept separate for now to minimise file size).
inferExpr :: Abs.Exp -> TC s (Type s)
inferExpr (Abs.ELitI _) = pure (TCon TcInt [])
inferExpr (Abs.ELitS _) = pure (TCon TcString [])
inferExpr (Abs.ELitC _) = pure (TCon TcChar [])
inferExpr (Abs.EVar (Abs.VarId (pos, name))) = do
  env <- currentEnv
  case lookupVar name env of
    Just s  -> instantiate s
    Nothing -> throwError (UnknownVar (Just pos) name)
inferExpr (Abs.ECon (Abs.ConId (pos, name))) = do
  env <- currentEnv
  case lookupCon name env of
    Just info -> instantiate (conScheme info)
    Nothing   -> throwError (UnknownCon (Just pos) name)
inferExpr (Abs.EParen e) = inferExpr e
inferExpr (Abs.EParenOp (Abs.VarSym (pos, name))) = do
  -- (+) as a value — look up like a regular variable
  env <- currentEnv
  case lookupVar name env of
    Just s  -> instantiate s
    Nothing -> throwError (UnknownVar (Just pos) name)
inferExpr (Abs.EApp f x) = do
  fT <- inferExpr f
  xT <- inferExpr x
  rT <- freshTVar KStar
  unify Nothing fT (TArr xT RowEmpty rT)
  pure rT
inferExpr (Abs.EIf c a b) = do
  cT <- inferExpr c
  aT <- inferExpr a
  bT <- inferExpr b
  unify Nothing cT (TCon TcBool [])
  unify Nothing aT bT
  pure aT
inferExpr (Abs.ETuple a others) = do
  ts <- mapM inferExpr (a : others)
  pure (TCon (TcTuple (length ts)) ts)
inferExpr (Abs.EList []) = do
  e <- freshTVar KStar
  pure (TCon TcList [e])
inferExpr (Abs.EList (x : xs)) = do
  firstT <- inferExpr x
  mapM_ (\e -> do { t <- inferExpr e; unify Nothing firstT t }) xs
  pure (TCon TcList [firstT])
inferExpr (Abs.ELam atomPats body) = do
  -- Build types and bindings for each parameter, then infer body
  patResults <- mapM inferAtomPat atomPats
  let paramTys = map fst patResults
      binds = concatMap snd patResults
  bodyT <- extendBinds binds (inferExpr body)
  pure (foldr (\pT acc -> TArr pT RowEmpty acc) bodyT paramTys)
inferExpr (Abs.EExpr head_ tails) = do
  -- After Wok.Reordering, tails is either empty or a single ITail.
  hT <- inferExpr head_
  applyTails hT tails
  where
    applyTails t [] = pure t
    applyTails fT (Abs.ITail op rhs : rest) = do
      opTy <- inferInfixOp op
      rhsT <- inferExpr rhs
      r1 <- freshTVar KStar
      r2 <- freshTVar KStar
      -- opTy : a -> b -> c   ; we apply to (lhs=fT) and (rhs=rhsT)
      unify Nothing opTy (TArr fT RowEmpty (TArr rhsT RowEmpty r1))
      -- continue chain with r1 as new head; r2 unused in single-ITail case
      _ <- pure r2
      applyTails r1 rest
inferExpr (Abs.EProj _ (Abs.VarId (pos, _))) =
  throwError (UnsupportedFeature (Just pos)
    (Tx.pack "x.y projection/module access not supported in v1"))
inferExpr (Abs.EProjC _ (Abs.ConId (pos, _))) =
  throwError (UnsupportedFeature (Just pos)
    (Tx.pack "x.Y projection/module access not supported in v1"))
inferExpr (Abs.ELet _ _) = throwError (UnsupportedFeature Nothing
  (Tx.pack "let-in is implemented in Task 12"))
inferExpr (Abs.ECase _ _) = throwError (UnsupportedFeature Nothing
  (Tx.pack "case-of is implemented in Task 12"))

-- Look up an infix operator's scheme by name.
inferInfixOp :: Abs.InfixOp -> TC s (Type s)
inferInfixOp (Abs.IOSym (Abs.VarSym (pos, name))) = lookupOpName pos name
inferInfixOp (Abs.IOBT  (Abs.VarId (pos, name))) = lookupOpName pos name

lookupOpName :: (Int, Int) -> Text -> TC s (Type s)
lookupOpName pos name = do
  env <- currentEnv
  case lookupVar name env of
    Just s  -> instantiate s
    Nothing -> throwError (UnknownVar (Just pos) name)

-- Extend env with a list of monomorphic bindings.
extendBinds :: [(Text, Type s)] -> TC s a -> TC s a
extendBinds [] m = m
extendBinds ((n, t) : rest) m = do
  ct <- freeze t
  extendVarTC n (Scheme [] ct) (extendBinds rest m)
```

Add imports:

```haskell
import Wok.TypeChecking.Env (lookupVar)
import Wok.TypeChecking.Monad (extendVarTC)
```

- [ ] **Step 2: Add tests**

```haskell
exprBasicTests :: TestTree
exprBasicTests = testGroup "Wok.TypeChecking.Infer (expr basics)"
  [ testCase "literal Int" $
      let result = TM.runTC B.initialEnv $ do
            t <- I.inferExpr (Abs.ELitI (Abs.WokInt ((0,0), Tx.pack "42")))
            U.freeze t
      in result @?= Right (T.CTCon T.TcInt [])
  , testCase "if True then 1 else 2 : Int" $
      let true = Abs.ECon (Abs.ConId ((0,0), Tx.pack "True"))
          mkI s = Abs.ELitI (Abs.WokInt ((0,0), Tx.pack s))
          result = TM.runTC B.initialEnv $ do
            t <- I.inferExpr (Abs.EIf true (mkI "1") (mkI "2"))
            U.freeze t
      in result @?= Right (T.CTCon T.TcInt [])
  , testCase "(+) applied to two Ints : Int" $
      let plus = Abs.EParenOp (Abs.VarSym ((0,0), Tx.pack "+"))
          mkI s = Abs.ELitI (Abs.WokInt ((0,0), Tx.pack s))
          result = TM.runTC B.initialEnv $ do
            t <- I.inferExpr (Abs.EApp (Abs.EApp plus (mkI "1")) (mkI "2"))
            U.freeze t
      in result @?= Right (T.CTCon T.TcInt [])
  , testCase "\\x -> x : a -> a" $
      let lam = Abs.ELam [Abs.APVar (Abs.VarId ((0,0), Tx.pack "x"))]
                  (Abs.EVar (Abs.VarId ((0,0), Tx.pack "x")))
          result = TM.runTC B.initialEnv $ do
            t <- I.inferExpr lam
            U.freeze t
      in case result of
           Right (T.CTArr (T.CTGen i) T.CREmpty (T.CTGen j)) | i == j -> pure ()
           _ -> assertFailure ("unexpected: " ++ show result)
  , testCase "EProj fails as unsupported" $
      let proj = Abs.EProj (Abs.EVar (Abs.VarId ((0,0), Tx.pack "x")))
                   (Abs.VarId ((0,0), Tx.pack "y"))
          result = TM.runTC B.initialEnv (I.inferExpr proj)
      in case result of
           Left (TErr.UnsupportedFeature _ _) -> pure ()
           _ -> assertFailure ("expected UnsupportedFeature, got " ++ show result)
  ]
```

- [ ] **Step 3: Verify**

Run: `cabal test --test-options="-p ExprBasic"`
Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add src/Wok/TypeChecking/Infer.hs test/Spec.hs
git commit -m "$(cat <<'EOF'
feat(typecheck): add expression inference (basics)

Literals, variables, constructors, application, lambda, if/then/else,
tuples, list literals, parens, operator-as-value, infix tail (EExpr).
EProj/EProjC reject as unsupported in v1. let-in and case-of throw
a placeholder error until Task 12 implements them.
EOF
)"
```

---

## Task 12: Expression inference — let, where, case

**Goal:** Extend `inferExpr` with `ELet` (mutually-recursive local bindings with generalization), `ECase` (pattern matching with branch-type unification), and the `MaybeWhere` desugaring on equations (handled in Task 13's top-level pass via the same mechanism).

**Files:**
- Modify: `src/Wok/TypeChecking/Infer.hs`
- Modify: `test/Spec.hs`

**Acceptance Criteria:**
- [ ] `let id = \x -> x in (id 1, id True)` typechecks to `(Int, Bool)`.
- [ ] `case Nothing of Nothing -> 0; Just x -> x` typechecks to `Int`.
- [ ] Where-bound types from `WithWh` are processed via the same local-let path.
- [ ] Mutual recursion in a let-group is supported (all bindings get fresh placeholders before any body is typed).

**Verify:** `cabal test --test-options="-p ExprLet"` → tests pass.

**Steps:**

- [ ] **Step 1: Replace the stub `ELet`/`ECase` cases in `inferExpr`** with:

```haskell
inferExpr (Abs.ELet localDecls body) = inferLetGroup localDecls (inferExpr body)
inferExpr (Abs.ECase scrutinee alts) = do
  sT <- inferExpr scrutinee
  -- For each alt, infer pattern and body, unify pattern with scrutinee
  -- and unify all body types together.
  rT <- freshTVar KStar
  mapM_ (inferAlt sT rT) alts
  pure rT
```

Add helper functions at the bottom of the module:

```haskell
-- | Infer a single case alternative.
inferAlt :: Type s -> Type s -> Abs.Alt -> TC s ()
inferAlt sT rT (Abs.AltC pat body mw) = do
  (pT, binds) <- inferPat pat
  unify Nothing sT pT
  let withWhere k = case mw of
        Abs.NoWhere   -> k
        Abs.WithWh ds -> inferLetGroup' ds k
  bodyT <- extendBinds binds (withWhere (inferExpr body))
  unify Nothing rT bodyT

-- | Process a local-decl group as a single mutually-recursive let:
-- (1) split signatures from equations, (2) group equations by name,
-- (3) allocate fresh placeholders for each name (and replace with sig
-- when one exists), (4) type each binding's body at level+1,
-- (5) generalize each, (6) extend env and run continuation.
inferLetGroup :: [Abs.LocalDecl] -> TC s a -> TC s a
inferLetGroup = inferLetGroup'

inferLetGroup' :: [Abs.LocalDecl] -> TC s a -> TC s a
inferLetGroup' decls k = do
  -- Split signatures and equations
  let (sigs, eqns) = partitionLocalDecls decls
  sigMap <- buildSigMap sigs    -- :: Map Text Scheme
  -- Group equations by name
  let groups = groupEquations eqns  -- [(Text, [(FunLHS, Exp, MaybeWhere)])]
  -- Allocate fresh TVar placeholders or use sig scheme directly
  initialBindings <- mapM (allocatePlaceholder sigMap) groups
  -- Extend env with placeholders (as monotypes if no sig; as the
  -- declared scheme if a sig is present)
  let extend = foldr (.) id
        [ extendVarTC name placeholder
        | (name, placeholder, _) <- initialBindings ]
  -- Type each group's body at level+1
  schemes <- extend $ enterLevel $ mapM typeOneGroup initialBindings
  -- Update env with the finalised schemes and run continuation
  let extend2 = foldr (.) id [ extendVarTC n s | (n, s) <- schemes ]
  extend2 k

partitionLocalDecls :: [Abs.LocalDecl] -> ([Abs.LocalDecl], [Abs.LocalDecl])
partitionLocalDecls = foldr step ([], [])
  where
    step d@(Abs.LDSig {}) (sigs, eqns) = (d : sigs, eqns)
    step d@(Abs.LDEqn {}) (sigs, eqns) = (sigs, d : eqns)

-- Build a Map from variable name to its declared scheme.
buildSigMap :: [Abs.LocalDecl] -> TC s (Map.Map Text Scheme)
buildSigMap [] = pure Map.empty
buildSigMap (Abs.LDSig (Abs.VarId (_, n)) extras ty : rest) = do
  env <- currentEnv
  s <- translateSig env ty
  let names = n : [ x | Abs.VICons (Abs.VarId (_, x)) <- extras ]
  m <- buildSigMap rest
  pure (foldr (\nm acc -> Map.insert nm s acc) m names)
buildSigMap (_ : rest) = buildSigMap rest

-- Group equations by binding name.
groupEquations :: [Abs.LocalDecl] -> [(Text, [Abs.LocalDecl])]
groupEquations decls =
  let pairs = [ (eqName d, d) | d <- decls ]
      grouped = foldr addToGroup [] pairs
  in grouped
  where
    addToGroup (n, d) acc = case lookup n acc of
      Just _  -> map (\(k, ds) -> if k == n then (k, ds ++ [d]) else (k, ds)) acc
      Nothing -> acc ++ [(n, [d])]

eqName :: Abs.LocalDecl -> Text
eqName (Abs.LDEqn lhs _ _) = funLHSName lhs
eqName (Abs.LDSig (Abs.VarId (_, n)) _ _) = n

funLHSName :: Abs.FunLHS -> Text
funLHSName (Abs.LHSPre fn _) = funNameText fn
funLHSName (Abs.LHSInfSym _ (Abs.VarSym (_, n)) _) = n
funLHSName (Abs.LHSInfBT _ (Abs.VarId (_, n)) _) = n

funNameText :: Abs.FunName -> Text
funNameText (Abs.FNBare (Abs.VarId (_, n))) = n
funNameText (Abs.FNBareSym (Abs.VarSym (_, n))) = n
funNameText (Abs.FNParen (Abs.VarSym (_, n))) = n

-- Allocate a placeholder scheme: signature if present, else monomorphic fresh.
allocatePlaceholder
  :: Map.Map Text Scheme
  -> (Text, [Abs.LocalDecl])
  -> TC s (Text, Scheme, [Abs.LocalDecl])
allocatePlaceholder sigMap (name, eqns) =
  case Map.lookup name sigMap of
    Just s -> pure (name, s, eqns)
    Nothing -> do
      t <- freshTVar KStar
      ct <- freeze t
      pure (name, Scheme [] ct, eqns)

-- Type one binding group: infer body type from each equation, unify
-- all equations' types, then either check against signature or
-- generalize.
typeOneGroup :: (Text, Scheme, [Abs.LocalDecl]) -> TC s (Text, Scheme)
typeOneGroup (name, declared, eqns) = do
  -- Type each equation as a (params -> body) chain
  eqTypes <- mapM typeEquation eqns
  -- Unify all equation types
  case eqTypes of
    []     -> error ("typeOneGroup: no equations for " ++ show name)
    (t : ts) -> do
      mapM_ (unify Nothing t) ts
      -- If declared scheme is more than just a fresh monotype, check against
      -- it; otherwise generalize the inferred type.
      case schemeVars declared of
        [] | isFreshMono declared -> do
          gen <- generalize t
          pure (name, gen)
        _ -> do
          -- Check: instantiate declared, unify with inferred, accept declared.
          declT <- instantiate declared
          unify Nothing declT t
          pure (name, declared)
  where
    isFreshMono (Scheme [] (CTGen _)) = True
    isFreshMono _ = False

-- Type one equation: parameters bind types, body inferred under them.
typeEquation :: Abs.LocalDecl -> TC s (Type s)
typeEquation (Abs.LDEqn lhs body mw) = do
  let atoms = lhsAtomPats lhs
  patResults <- mapM inferAtomPat atoms
  let pTys = map fst patResults
      binds = concatMap snd patResults
  let withWhere k = case mw of
        Abs.NoWhere   -> k
        Abs.WithWh ds -> inferLetGroup' ds k
  bodyT <- extendBinds binds (withWhere (inferExpr body))
  pure (foldr (\pT acc -> TArr pT RowEmpty acc) bodyT pTys)
typeEquation (Abs.LDSig {}) = error "typeEquation: signature passed in equation list"

lhsAtomPats :: Abs.FunLHS -> [Abs.AtomPat]
lhsAtomPats (Abs.LHSPre _ aps) = aps
lhsAtomPats (Abs.LHSInfSym a _ b) = [a, b]
lhsAtomPats (Abs.LHSInfBT  a _ b) = [a, b]
```

Add imports:

```haskell
import Wok.TypeChecking.Monad (enterLevel)
```

- [ ] **Step 2: Add tests**

```haskell
exprLetTests :: TestTree
exprLetTests = testGroup "Wok.TypeChecking.Infer (let/case)"
  [ testCase "let id = \\x -> x in (id 1, id True) : (Int, Bool)" $
      let v s = Abs.VarId ((0,0), Tx.pack s)
          c s = Abs.ConId ((0,0), Tx.pack s)
          ldId = Abs.LDEqn (Abs.LHSPre (Abs.FNBare (v "id")) [Abs.APVar (v "x")])
                            (Abs.EVar (v "x")) Abs.NoWhere
          one  = Abs.ELitI (Abs.WokInt ((0,0), Tx.pack "1"))
          true = Abs.ECon (c "True")
          body = Abs.ETuple
                   (Abs.EApp (Abs.EVar (v "id")) one)
                   [Abs.EApp (Abs.EVar (v "id")) true]
          result = TM.runTC B.initialEnv $ do
            t <- I.inferExpr (Abs.ELet [ldId] body)
            U.freeze t
      in result @?= Right
           (T.CTCon (T.TcTuple 2) [T.CTCon T.TcInt [], T.CTCon T.TcBool []])
  ]
```

(Case-of test deferred to integration in Task 13 — easier to write end-to-end via a parsed source string.)

- [ ] **Step 3: Verify**

Run: `cabal test --test-options="-p ExprLet"`
Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add src/Wok/TypeChecking/Infer.hs test/Spec.hs
git commit -m "$(cat <<'EOF'
feat(typecheck): add let, where, and case inference

inferLetGroup handles mutually-recursive local bindings: split sigs
from equations, group equations by name, allocate fresh placeholders
(or use declared scheme), type bodies at level+1, generalize. Where
clauses on equations and case alternatives reuse the same path.
ECase unifies the scrutinee with every pattern and unifies all
branch result types.
EOF
)"
```

---

## Task 13: Top-level program inference (inferProgram)

**Goal:** Wire the three-pass top-level processing: collect tycons, collect constructors + signatures, then type the top-level mutual-rec function group.

**Files:**
- Modify: `src/Wok/TypeChecking/Infer.hs`
- Modify: `src/Wok/TypeChecking.hs` (facade)
- Modify: `test/Spec.hs`

**Acceptance Criteria:**
- [ ] `inferProgram :: Abs.Module -> Either TypeError (Env, [TypedDecl])` returns the final env on success.
- [ ] A typed AST list is returned (for v1 the `TypedDecl` payload is just `(name, Scheme)`).
- [ ] Top-level equations are typed as a single mutually-recursive group.
- [ ] Source files with `Maybe`, `id`, and a few function definitions typecheck end-to-end.

**Verify:** `cabal test --test-options="-p Program"` → tests pass.

**Steps:**

- [ ] **Step 1: Add `inferProgram` and a small `TypedDecl` type to `Infer.hs`**

Add exports `inferProgram`, `TypedDecl(..)`.

```haskell
-- | The v1 typed-AST output: one entry per top-level binding,
-- carrying its generalised scheme. The expression-level typed AST
-- is omitted from v1; future coverage / eval passes will get it
-- when those features land.
data TypedDecl = TypedDecl
  { tdName   :: Text
  , tdScheme :: Scheme
  }
  deriving (Eq, Show)

-- | The pipeline entry point.
inferProgram :: Abs.Module -> Either TypeError (Env, [TypedDecl])
inferProgram (Abs.Module decls) = TM.runTC initialEnv $ do
  -- Pass 1: register tycons (and a stub for constructors)
  env1 <- processDataDecls Builtins.initialEnv decls
  -- Pass 2: collect standalone signatures
  sigDecls <- collectTopSigs env1 decls
  let env2 = foldr (\(n, s) e -> extendVar n s e) env1 sigDecls
  -- Pass 3: type the function-equation group
  let eqns = [ d | d@(Abs.DEqn {}) <- decls ]
  results <- inferTopGroup env2 sigDecls eqns
  let finalEnv = foldr (\(n, s) e -> extendVar n s e) env2 results
  pure (finalEnv, [ TypedDecl n s | (n, s) <- results ])
  where
    -- workaround for inner forall: we can't directly call runTC inside a
    -- function-shape that returns Either; restructure.
    pass = ()
```

Replace the broken `pass` shape with a properly threaded version. The right shape:

```haskell
inferProgram :: Abs.Module -> Either TypeError (Env, [TypedDecl])
inferProgram (Abs.Module decls) =
  TM.runTC Builtins.initialEnv (inferProgramTC decls)

inferProgramTC :: [Abs.Decl] -> TC s (Env, [TypedDecl])
inferProgramTC decls = do
  env1 <- processDataDecls Builtins.initialEnv decls
  sigBindings <- collectTopSigs env1 decls
  let env2 = foldr (\(n, s) e -> extendVar n s e) env1 sigBindings
  let eqns = [ d | d@(Abs.DEqn {}) <- decls ]
  results <- withEnv (const env2) (inferTopGroup sigBindings eqns)
  let finalEnv = foldr (\(n, s) e -> extendVar n s e) env2 results
  pure (finalEnv, [ TypedDecl n s | (n, s) <- results ])

collectTopSigs :: Env -> [Abs.Decl] -> TC s [(Text, Scheme)]
collectTopSigs env decls = concat <$> mapM go decls
  where
    go (Abs.DSig (Abs.VarId (_, n)) extras ty) = do
      s <- translateSig env ty
      let names = n : [ x | Abs.VICons (Abs.VarId (_, x)) <- extras ]
      pure [ (nm, s) | nm <- names ]
    go _ = pure []

-- Treat the top-level eqns as one big local-decl group.
inferTopGroup :: [(Text, Scheme)] -> [Abs.Decl] -> TC s [(Text, Scheme)]
inferTopGroup sigBindings eqns = do
  let sigMap = Map.fromList sigBindings
  -- Build LocalDecl-shaped list so we can reuse inferLetGroup machinery
  let localEqns = [ Abs.LDEqn lhs body mw | Abs.DEqn lhs body mw <- eqns ]
  let groups = groupEquations localEqns
  initial <- mapM (allocatePlaceholder sigMap) groups
  -- Extend env with placeholders during inference
  let extend = foldr (.) id
        [ extendVarTC name placeholder
        | (name, placeholder, _) <- initial ]
  schemes <- extend $ enterLevel $ mapM typeOneGroup initial
  pure schemes
```

Add imports:

```haskell
import qualified Wok.TypeChecking.Builtins as Builtins
import qualified Wok.TypeChecking.Monad as TM
import Wok.TypeChecking.Env (extendVar)
```

- [ ] **Step 2: Expose the facade in `src/Wok/TypeChecking.hs`**

```haskell
-- | Public API of the wok HM core typechecker.
module Wok.TypeChecking
  ( inferProgram
  , TypedDecl (..)
  , TypeError (..)
  , Env (..)
  , Scheme (..)
  , CType (..)
  , CRow (..)
  , Kind (..)
  , TyCon (..)
  ) where

import Wok.TypeChecking.Env (Env (..))
import Wok.TypeChecking.Error (TypeError (..))
import Wok.TypeChecking.Infer (TypedDecl (..), inferProgram)
import Wok.TypeChecking.Types
  ( CRow (..), CType (..), Kind (..), Scheme (..), TyCon (..) )
```

- [ ] **Step 3: Add end-to-end tests**

```haskell
import qualified Wok.TypeChecking as TC

programTests :: TestTree
programTests = testGroup "Wok.TypeChecking (program)"
  [ testCase "id : forall a. a -> a end-to-end" $
      let src = "id x = x\n"
          result = do
            parsed <- TC.first ("parse: " ++) (Wok.Parsing.parse (Tx.pack src))
            reord  <- TC.first (("reorder: " ++) . show) (Wok.Reordering.reorderModule parsed)
            TC.first (("typecheck: " ++) . show)
              (TC.inferProgram (Wok.Reordering.reorderedAst reord))
      in case result of
           Right (_, [td]) ->
             case TC.tdScheme td of
               T.Scheme [(0, T.KStar)] (T.CTArr (T.CTGen 0) T.CREmpty (T.CTGen 0)) -> pure ()
               other -> assertFailure ("got: " ++ show other)
           other -> assertFailure ("expected single id scheme, got " ++ show other)
  ]
```

Where `TC.first` is `Data.Bifunctor.first` from `base`. Add import for `Bifunctor.first`:

```haskell
import Data.Bifunctor (first)
```

And use `first` directly in the test. The `Wok.TypeChecking` facade does not need to re-export it.

- [ ] **Step 4: Verify**

Run: `cabal test --test-options="-p Program"`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/Wok/TypeChecking/Infer.hs src/Wok/TypeChecking.hs test/Spec.hs
git commit -m "$(cat <<'EOF'
feat(typecheck): wire inferProgram (three-pass top-level)

Pass 1: register all data type constructors (and constructors via
processDataDecls). Pass 2: collect standalone signatures from DSig
into the env. Pass 3: type the top-level function-equation group
as one mutually-recursive let. Facade Wok.TypeChecking re-exports
the public API: inferProgram, TypedDecl, TypeError, Env, Scheme,
CType, CRow, Kind, TyCon.
EOF
)"
```

---

## Task 14: Pipeline integration in app/Main.hs

**Goal:** Wire `inferProgram` into the executable pipeline so `wok <file>` prints inferred top-level schemes.

**Files:**
- Modify: `app/Main.hs`
- Add: `examples/types-tour.wok` (a working sample to demo)

**Acceptance Criteria:**
- [ ] `wok examples/types-tour.wok` prints one scheme per top-level binding.
- [ ] Type errors print to stderr with `typecheck:` prefix and exit non-zero.

**Verify:**
- `cabal build` succeeds.
- `cabal run wok -- examples/types-tour.wok` prints schemes (verified visually for now; golden later).

**Steps:**

- [ ] **Step 1: Add a tiny scheme pretty-printer to `Wok.TypeChecking.Infer`**

Add to exports `prettyScheme`:

```haskell
import Data.Text (Text)
import qualified Data.Text as Tx

-- | Render a Scheme into a wok-flavoured surface notation:
--   forall a b. (a -> b) -> [a] -> [b]
prettyScheme :: Scheme -> Text
prettyScheme (Scheme [] body) = prettyCType body
prettyScheme (Scheme vars body) =
  Tx.concat
    [ Tx.pack "forall "
    , Tx.intercalate (Tx.pack " ") (map (varName . fst) vars)
    , Tx.pack ". "
    , prettyCType body
    ]

varName :: Int -> Text
varName i
  | i < 26    = Tx.singleton (toEnum (fromEnum 'a' + i))
  | otherwise = Tx.pack ('t' : show i)

prettyCType :: CType -> Text
prettyCType (CTGen i) = varName i
prettyCType (CTCon TcInt    []) = Tx.pack "Int"
prettyCType (CTCon TcChar   []) = Tx.pack "Char"
prettyCType (CTCon TcString []) = Tx.pack "String"
prettyCType (CTCon TcBool   []) = Tx.pack "Bool"
prettyCType (CTCon TcUnit   []) = Tx.pack "()"
prettyCType (CTCon TcList [x])  = Tx.concat [Tx.pack "[", prettyCType x, Tx.pack "]"]
prettyCType (CTCon (TcTuple _) xs) =
  Tx.concat
    [ Tx.pack "("
    , Tx.intercalate (Tx.pack ", ") (map prettyCType xs)
    , Tx.pack ")"
    ]
prettyCType (CTCon (TcUser n) []) = n
prettyCType (CTCon (TcUser n) xs) =
  Tx.concat [n, Tx.pack " ", Tx.intercalate (Tx.pack " ") (map prettyCTypeAtom xs)]
prettyCType (CTCon c xs) =
  Tx.concat [Tx.pack (show c), Tx.pack " ", Tx.intercalate (Tx.pack " ") (map prettyCTypeAtom xs)]
prettyCType (CTArr a CREmpty b) =
  Tx.concat [prettyCTypeArg a, Tx.pack " -> ", prettyCType b]
prettyCType (CTArr a r b) =
  Tx.concat
    [ prettyCTypeArg a, Tx.pack " -<", prettyCRow r, Tx.pack ">- ", prettyCType b ]

prettyCTypeArg :: CType -> Text
prettyCTypeArg t@(CTArr {}) = Tx.concat [Tx.pack "(", prettyCType t, Tx.pack ")"]
prettyCTypeArg t = prettyCType t

prettyCTypeAtom :: CType -> Text
prettyCTypeAtom t@(CTArr {}) = Tx.concat [Tx.pack "(", prettyCType t, Tx.pack ")"]
prettyCTypeAtom t@(CTCon (TcUser _) (_:_)) =
  Tx.concat [Tx.pack "(", prettyCType t, Tx.pack ")"]
prettyCTypeAtom t = prettyCType t

prettyCRow :: CRow -> Text
prettyCRow CREmpty = Tx.empty
prettyCRow (CRExtend l _ rest) = Tx.concat [l, Tx.pack ",", prettyCRow rest]
prettyCRow (CRGen i) = Tx.concat [Tx.pack "r", Tx.pack (show i)]
```

Re-export from the facade `Wok.TypeChecking`:

```haskell
module Wok.TypeChecking
  ( inferProgram
  , prettyScheme
  , TypedDecl (..)
  , TypeError (..)
  , Env (..)
  , Scheme (..)
  , CType (..)
  , CRow (..)
  , Kind (..)
  , TyCon (..)
  ) where

import Wok.TypeChecking.Infer (TypedDecl (..), inferProgram, prettyScheme)
```

- [ ] **Step 2: Update `app/Main.hs`**

```haskell
module Main where

import Data.Bifunctor (first)
import qualified Data.Text.IO as TIO
import qualified Data.Text as Tx
import System.Environment (getArgs)
import System.Exit (exitFailure)
import Wok.Parsing (parse)
import Wok.Reordering (reorderModule, reorderedAst)
import qualified Wok.TypeChecking as TC

main :: IO ()
main = do
  args <- getArgs
  case args of
    [path] -> runApp path
    _      -> do
      putStrLn "usage: wok <file.wok>"
      exitFailure

runApp :: FilePath -> IO ()
runApp path = do
  src <- TIO.readFile path
  case pipeline src of
    Left err -> do
      putStrLn err
      exitFailure
    Right (_env, decls) ->
      mapM_ (\(TC.TypedDecl n s) ->
              TIO.putStrLn (n <> Tx.pack " : " <> TC.prettyScheme s)) decls
  where
    pipeline src = do
      parsed    <- first    ("parse: " ++)        (parse src)
      reordered <- first    (("reorder: " ++) . show) (reorderModule parsed)
      first  (("typecheck: " ++) . show) (TC.inferProgram (reorderedAst reordered))
```

- [ ] **Step 3: Add `examples/types-tour.wok`** — small sample that should typecheck:

```
data Maybe a = Nothing | Just a
data List a = Nil | Cons a (List a)

id : a -> a
id x = x

const : a -> b -> a
const x y = x

mapMaybe : (a -> b) -> Maybe a -> Maybe b
mapMaybe f m = case m of
  Nothing -> Nothing
  Just x  -> Just (f x)

length : List a -> Int
length xs = case xs of
  Nil       -> 0
  Cons _ ys -> 1 + length ys
```

- [ ] **Step 4: Verify**

Run: `cabal build && cabal run wok -- examples/types-tour.wok`
Expected: prints schemes for `id`, `const`, `mapMaybe`, `length`. No type errors.

- [ ] **Step 5: Commit**

```bash
git add src/Wok/TypeChecking/Infer.hs src/Wok/TypeChecking.hs app/Main.hs examples/types-tour.wok
git commit -m "$(cat <<'EOF'
feat(typecheck): wire pipeline into wok executable

app/Main.hs chains parse -> reorder -> infer through Either's monad
and prints inferred top-level schemes. Adds prettyScheme renderer
and a small examples/types-tour.wok sample that exercises ADTs,
polymorphism, pattern matching, and recursion.
EOF
)"
```

---

## Task 15: Golden test infrastructure

**Goal:** Wire the new typecheck golden test groups into `test/Spec.hs` mirroring the existing parser-golden setup.

**Files:**
- Modify: `test/Spec.hs`
- Create: `test/typecheck-examples/` (directory)
- Create: `test/typecheck-golden/` (directory)
- Create: `test/typecheck-fail-examples/`
- Create: `test/typecheck-fail-golden/`

**Acceptance Criteria:**
- [ ] Two new test groups appear in tasty output: `typecheck success golden` and `typecheck fail golden`.
- [ ] Goldens are produced via `cabal test --test-options=--accept` when missing.

**Verify:** `cabal test --test-options="-p typecheck"` discovers the new groups (may report 0 tests if dirs are empty).

**Steps:**

- [ ] **Step 1: Create empty test directories**

Run:

```bash
mkdir -p test/typecheck-examples test/typecheck-golden test/typecheck-fail-examples test/typecheck-fail-golden
```

- [ ] **Step 2: Extend `test/Spec.hs`** — append to imports:

```haskell
import qualified Wok.TypeChecking as TC
import Data.List (sortBy)
import Data.Ord (comparing)
import qualified Data.Text.Lazy as TL
import qualified Data.Text.Lazy.Encoding as TLE
```

Add to imports if not present:

```haskell
import Data.Bifunctor (first)
```

Add new test groups:

```haskell
typecheckTests :: TestTree
typecheckTests = testGroup "typecheck"
  [ testGroup "typecheck success golden" []     -- populated dynamically
  , testGroup "typecheck fail golden"    []
  ]

typecheckHarness :: FilePath -> IO BL.ByteString
typecheckHarness path = do
  src <- TIO.readFile path
  case pipeline src of
    Left err -> pure (BL.pack err)
    Right (_, decls) -> do
      let sorted = sortBy (comparing TC.tdName) decls
          lines' = [ Tx.unpack (TC.tdName d <> Tx.pack " : " <> TC.prettyScheme (TC.tdScheme d))
                   | d <- sorted ]
      pure $ BL.pack (unlines lines')
  where
    pipeline src = do
      p <- first    ("parse: " ++) (parse src)
      r <- first    (("reorder: " ++) . show) (reorderModule p)
      first  (("typecheck: " ++) . show) (TC.inferProgram (reorderedAst r))

typecheckFailHarness :: FilePath -> IO BL.ByteString
typecheckFailHarness path = do
  src <- TIO.readFile path
  case pipeline src of
    Left err -> pure (BL.pack err)
    Right _  -> pure (BL.pack "UNEXPECTED SUCCESS\n")
  where
    pipeline src = do
      p <- first    ("parse: " ++) (parse src)
      r <- first    (("reorder: " ++) . show) (reorderModule p)
      first  (("typecheck: " ++) . show) (TC.inferProgram (reorderedAst r))
```

Replace the static `typecheckTests` definition with a dynamic discovery hooked into `main`:

```haskell
main :: IO ()
main = do
  exampleFiles    <- findByExtension [".wok"] "test/examples"
  resolveFiles    <- findByExtension [".wok"] "test/resolve-examples"
  typecheckFiles  <- findByExtension [".wok"] "test/typecheck-examples"
  typecheckBadFiles <- findByExtension [".wok"] "test/typecheck-fail-examples"
  defaultMain $ testGroup "wok"
    [ testGroup "parse golden"
        [ goldenVsString (takeBaseName f) (goldenFor f) (parseToBS f)
        | f <- exampleFiles ]
    , fixityTests
    , resolveTests
    , testGroup "resolve golden"
        [ goldenVsString (takeBaseName f) (resolveGoldenFor f) (resolveToBS f)
        | f <- resolveFiles ]
    , typesSmokeTests
    , envSmokeTests
    , monadSmokeTests
    , unifyWalksTests
    , unifyTests
    , generalizeTests
    , builtinsTests
    , translateTests
    , dataTests
    , patternTests
    , exprBasicTests
    , exprLetTests
    , programTests
    , testGroup "typecheck success golden"
        [ goldenVsString (takeBaseName f) (typecheckGoldenFor f) (typecheckHarness f)
        | f <- typecheckFiles ]
    , testGroup "typecheck fail golden"
        [ goldenVsString (takeBaseName f) (typecheckFailGoldenFor f) (typecheckFailHarness f)
        | f <- typecheckBadFiles ]
    ]

typecheckGoldenFor :: FilePath -> FilePath
typecheckGoldenFor f =
  replaceDirectory (replaceExtension f ".expected") "test/typecheck-golden"

typecheckFailGoldenFor :: FilePath -> FilePath
typecheckFailGoldenFor f =
  replaceDirectory (replaceExtension f ".expected") "test/typecheck-fail-golden"
```

- [ ] **Step 3: Verify**

Run: `cabal test --test-options="-p typecheck"`
Expected: builds, may report 0 golden tests since directories are empty. No errors.

- [ ] **Step 4: Commit**

```bash
git add test/Spec.hs test/typecheck-examples/.gitkeep test/typecheck-golden/.gitkeep test/typecheck-fail-examples/.gitkeep test/typecheck-fail-golden/.gitkeep
```

(create `.gitkeep` files so the empty dirs are tracked: `touch test/typecheck-examples/.gitkeep` etc.)

```bash
git commit -m "$(cat <<'EOF'
test(typecheck): add golden test infrastructure

Two new tasty groups discover .wok files in test/typecheck-examples/
and test/typecheck-fail-examples/, run the full pipeline, and compare
output to test/typecheck-golden/ and test/typecheck-fail-golden/.
Success output is sorted top-level schemes; failure output is the
error string from the pipeline.
EOF
)"
```

---

## Task 16: Initial test corpus — success cases

**Goal:** Populate `test/typecheck-examples/` with .wok files exercising the main language features, then accept goldens.

**Files:**
- Create: `test/typecheck-examples/01-identity.wok`
- Create: `test/typecheck-examples/02-arithmetic.wok`
- Create: `test/typecheck-examples/03-lists.wok`
- Create: `test/typecheck-examples/04-maybe.wok`
- Create: `test/typecheck-examples/05-either.wok`
- Create: `test/typecheck-examples/06-mutual-rec.wok`
- Create: `test/typecheck-examples/07-where.wok`
- Create: `test/typecheck-examples/08-patterns.wok`
- Create: `test/typecheck-examples/09-higher-order.wok`
- Create: `test/typecheck-examples/10-multi-sig.wok`
- The corresponding `.expected` files in `test/typecheck-golden/`

**Acceptance Criteria:**
- [ ] All success cases typecheck.
- [ ] Golden files exist and match.

**Verify:** `cabal test --test-options="-p 'typecheck success'"` → all green.

**Steps:**

- [ ] **Step 1: Write the example files**

`test/typecheck-examples/01-identity.wok`:

```
id : a -> a
id x = x

const : a -> b -> a
const x y = x

flip : (a -> b -> c) -> b -> a -> c
flip f x y = f y x
```

`test/typecheck-examples/02-arithmetic.wok`:

```
fixity + left
fixity * left tighter than +

add : Int -> Int -> Int
add x y = x + y

double : Int -> Int
double n = n * 2

quad : Int -> Int
quad n = double (double n)
```

`test/typecheck-examples/03-lists.wok`:

```
data List a = Nil | Cons a (List a)

length : List a -> Int
length xs = case xs of
  Nil       -> 0
  Cons _ ys -> 1 + length ys

map : (a -> b) -> List a -> List b
map f xs = case xs of
  Nil       -> Nil
  Cons y ys -> Cons (f y) (map f ys)
```

`test/typecheck-examples/04-maybe.wok`:

```
data Maybe a = Nothing | Just a

fromMaybe : a -> Maybe a -> a
fromMaybe d m = case m of
  Nothing -> d
  Just x  -> x

mapMaybe : (a -> b) -> Maybe a -> Maybe b
mapMaybe f m = case m of
  Nothing -> Nothing
  Just x  -> Just (f x)
```

`test/typecheck-examples/05-either.wok`:

```
data Either a b = Left a | Right b

either : (a -> c) -> (b -> c) -> Either a b -> c
either f g e = case e of
  Left a  -> f a
  Right b -> g b
```

`test/typecheck-examples/06-mutual-rec.wok`:

```
even : Int -> Bool
even n = case n of
  0 -> True
  _ -> odd (n - 1)

odd : Int -> Bool
odd n = case n of
  0 -> False
  _ -> even (n - 1)
```

(Note: `==` is monomorphic on Int; pattern matching on `0` is fine; subtraction works.)

`test/typecheck-examples/07-where.wok`:

```
hyp : Int -> Int -> Int
hyp x y = root (sq x + sq y)
  where
    sq n = n * n
    root n = n
```

`test/typecheck-examples/08-patterns.wok`:

```
data Maybe a = Nothing | Just a

first : (a, b) -> a
first p = case p of
  (x, _) -> x

isNothing : Maybe a -> Bool
isNothing m = case m of
  Nothing -> True
  Just _  -> False

headOr : a -> [a] -> a
headOr d xs = case xs of
  []         -> d
  x :: _     -> x
```

(Note: `==`/`/=` are operator names; `headOr` uses cons pattern.)

`test/typecheck-examples/09-higher-order.wok`:

```
twice : (a -> a) -> a -> a
twice f x = f (f x)

compose : (b -> c) -> (a -> b) -> a -> c
compose f g x = f (g x)

apply : (a -> b) -> a -> b
apply f x = f x
```

`test/typecheck-examples/10-multi-sig.wok`:

```
zero, one, two : Int
zero = 0
one = 1
two = 2

allZeros : Bool
allZeros = case zero of
  0 -> True
  _ -> False
```

- [ ] **Step 2: Accept goldens**

Run: `cabal test --test-options="-p 'typecheck success' --accept"`
Expected: produces `.expected` files in `test/typecheck-golden/`, all tests then pass.

- [ ] **Step 3: Verify**

Run: `cabal test --test-options="-p 'typecheck success'"`
Expected: all green.

- [ ] **Step 4: Inspect goldens**

Open a few `.expected` files manually and confirm the inferred schemes look right (e.g., `id : forall a. a -> a`). If anything looks wrong, fix the example or the typechecker — do NOT accept incorrect goldens.

- [ ] **Step 5: Commit**

```bash
git add test/typecheck-examples/ test/typecheck-golden/
git commit -m "$(cat <<'EOF'
test(typecheck): add success corpus

Ten example files exercising identity / const / flip, arithmetic with
fixity, lists with map / length, Maybe, Either, mutual recursion,
where clauses, every pattern form, higher-order combinators, and
multi-name signatures. All produce expected schemes in the goldens.
EOF
)"
```

---

## Task 17: Initial test corpus — failure cases

**Goal:** Populate `test/typecheck-fail-examples/` with .wok files designed to fail with specific errors, then accept goldens of the error output.

**Files:**
- Create: `test/typecheck-fail-examples/01-mismatch.wok`
- Create: `test/typecheck-fail-examples/02-occurs.wok`
- Create: `test/typecheck-fail-examples/03-unknown-var.wok`
- Create: `test/typecheck-fail-examples/04-unknown-con.wok`
- Create: `test/typecheck-fail-examples/05-arity.wok`
- Create: `test/typecheck-fail-examples/06-sig-mismatch.wok`
- Create: `test/typecheck-fail-examples/07-duplicate-tycon.wok`
- The corresponding `.expected` files in `test/typecheck-fail-golden/`

**Acceptance Criteria:**
- [ ] Each file fails to typecheck with the expected error variant.
- [ ] Golden files capture the error string (whatever derived `Show` produces — we re-accept later if the formatter changes).

**Verify:** `cabal test --test-options="-p 'typecheck fail'"` → all green.

**Steps:**

- [ ] **Step 1: Write the failure examples**

`test/typecheck-fail-examples/01-mismatch.wok`:

```
bad : Int
bad = "not an int"
```

`test/typecheck-fail-examples/02-occurs.wok`:

```
omega = \x -> x x
```

`test/typecheck-fail-examples/03-unknown-var.wok`:

```
useGhost = ghost + 1
```

`test/typecheck-fail-examples/04-unknown-con.wok`:

```
makeIt = Frobnicate 42
```

`test/typecheck-fail-examples/05-arity.wok`:

```
data Maybe a = Nothing | Just a

bad m = case m of
  Just      -> 0
  Nothing   -> 1
```

(Calling `Just` as nullary when it expects one argument.)

`test/typecheck-fail-examples/06-sig-mismatch.wok`:

```
liesAboutType : Int -> Int
liesAboutType x = "definitely not Int"
```

`test/typecheck-fail-examples/07-duplicate-tycon.wok`:

```
data Bool = Yes | No
```

(Bool is a built-in tycon.)

- [ ] **Step 2: Accept goldens**

Run: `cabal test --test-options="-p 'typecheck fail' --accept"`
Expected: produces `.expected` files in `test/typecheck-fail-golden/`, all tests then pass.

- [ ] **Step 3: Verify**

Run: `cabal test --test-options="-p 'typecheck fail'"`
Expected: all green.

- [ ] **Step 4: Sanity-check goldens**

Inspect each `.expected` file and confirm the error mentions the expected variant. For example, `01-mismatch.expected` should contain `Mismatch`, `02-occurs.expected` should contain `OccursCheck`, etc. If the wrong variant fires, the example or the typechecker has a bug.

- [ ] **Step 5: Commit**

```bash
git add test/typecheck-fail-examples/ test/typecheck-fail-golden/
git commit -m "$(cat <<'EOF'
test(typecheck): add failure corpus

Seven failing example files covering Mismatch, OccursCheck,
UnknownVar, UnknownCon, ArityMismatch, SigMismatch, and
DuplicateTyCon. Goldens capture the Show TypeError output; will
be re-accepted when a pretty formatter is added later.
EOF
)"
```

---

## Self-review

After writing the plan, sanity-check against the spec:

**Coverage check.** Section-by-section:

- Spec §1 (Scope) — covered across all tasks. Reserved-but-not-implemented row slot is in Task 1 (Row in Type AST) and Task 5 (unifyRow stub). Out-of-scope items (records, effects, classes, refinement, GADTs) are explicitly absent.
- Spec §2 (Type AST) — Tasks 1, 2.
- Spec §3 (Inference) — Tasks 3 (monad), 4 (walks), 5 (unify), 6 (generalize/instantiate).
- Spec §4 (Source coverage) — Tasks 9 (data), 10 (patterns), 11+12 (expressions), 13 (top-level).
- Spec §5 (Integration) — Tasks 13 (facade), 14 (Main.hs + cabal already done in Task 0).
- Spec §6 (Errors) — Task 2.
- Spec §7 (Testing) — Tasks 15-17.
- Spec §8 (Open hooks) — `unifyRow` stub (Task 5), generalize "always-empty-row" gating (implicit in Task 6 — there's no other row to check yet), typed AST consumers (TypedDecl in Task 13).

**Placeholder scan.** Searched for "TBD", "TODO", "implement later", "add appropriate error handling" — none present in any task. One refactor note in Task 8 Step 1 (the broken ST-pure attempt) shows the corrected approach inline; this is a guide for the implementer, not a placeholder.

**Type consistency.** `inferProgram` returns `(Env, [TypedDecl])` consistently across Tasks 13, 14, 15. `prettyScheme` introduced in Task 14, used in Tasks 14, 15. `TypedDecl` defined in Task 13, used in Tasks 13, 14, 15. `initialEnv` from Task 7 used in Tasks 8, 9, 11, 13. `force`/`freeze`/`occursAdjust` from Task 4 used in Task 5. `unify` from Task 5 used in Tasks 10, 11, 12.

One mild redundancy: `partitionLocalDecls`/`buildSigMap`/`groupEquations`/etc. defined in Task 12 are reused by `inferTopGroup` in Task 13. Task 13 leans on Task 12's definitions; this is appropriate code reuse, not a duplication.

No further changes.
