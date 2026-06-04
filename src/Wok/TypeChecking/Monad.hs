{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE RankNTypes #-}

-- | The type-checker monad: ReaderT for environment + current level,
-- ExceptT for fail-fast errors, ST for mutable type-variable cells.
module Wok.TypeChecking.Monad
  ( TC
  , TCCtx (..)
  , ConstraintS (..)
  , runTC
  , runTC_
  , liftST
  , currentLevel
  , currentEnv
  , freshUniq
  , freshTVar
  , freshRVar
  , enterLevel
  , withEnv
  , extendVarTC
  , addWarning
  , addConstraint
  , takeConstraints
  , currentEffRow
  , withEffRow
  ) where

import Control.Monad.Except (ExceptT, MonadError, runExceptT)
import Control.Monad.Reader (MonadReader, ReaderT, asks, local, runReaderT)
import Control.Monad.Trans (lift)
import Control.Monad.ST (ST, runST)
import Data.List (nub)
import Data.STRef (STRef, modifySTRef', newSTRef, readSTRef, writeSTRef)
import Data.Text (Text)
import Wok.TypeChecking.Env (Env, extendVar)
import Wok.TypeChecking.Error (TypeError, Warning)
import Wok.TypeChecking.Types
  ( Kind, Level (..), RVar (..), Row (..), Scheme, TVar (..), Type (..) )

-- | A constraint collected during inference; its argument is still a mutable
-- 'Type s' and is frozen to 'CType' at the binding's generalization.
data ConstraintS s = ConstraintS
  { csClass :: Text
  , csArg   :: Type s
  }

data TCCtx s = TCCtx
  { ctxFresh       :: STRef s Int
  , ctxLevel       :: Level
  , ctxEnv         :: Env
  , ctxWarnings    :: STRef s [Warning]
    -- ^ Accumulated non-fatal warnings. Prepended in emission order;
    -- 'runTC' reverses to restore source order.
  , ctxEffRow      :: Maybe (STRef s (Row s))
    -- ^ The ambient effect row of the function equation currently being
    -- checked: an open-tailed 'Row' that operation calls and effectful
    -- applications extend. 'Nothing' outside any equation body (e.g. while
    -- translating signatures or at the top level), where effects are ignored.
  , ctxConstraints :: STRef s [ConstraintS s]
    -- ^ Constraints accumulated during inference. Prepended in emission order;
    -- 'takeConstraints' reverses to restore insertion order.
  }

newtype TC s a = TC { unTC :: ReaderT (TCCtx s) (ExceptT TypeError (ST s)) a }
  deriving
    ( Functor, Applicative, Monad
    , MonadReader (TCCtx s)
    , MonadError TypeError
    )

liftST :: ST s a -> TC s a
liftST = TC . lift . lift

-- | Run a TC action. Returns @Right (result, warnings)@ on success,
-- or @Left TypeError@ on the first fatal error. Warnings are returned
-- in emission order (source order).
runTC :: Env -> (forall s. TC s a) -> Either TypeError (a, [Warning])
runTC env action = runST $ do
  freshRef <- newSTRef 0
  warnsRef <- newSTRef []
  consRef  <- newSTRef []
  let ctx = TCCtx freshRef (Level 0) env warnsRef Nothing consRef
  result <- runExceptT (runReaderT (unTC action) ctx)
  case result of
    Left err -> pure (Left err)
    Right a  -> do
      ws <- readSTRef warnsRef
      -- Dedup structurally-identical warnings: the same shadow can be reached
      -- through more than one unification (e.g. a record value unified against
      -- a placeholder and again against its declared sig), and each path may
      -- re-emit the identical 'RowShadow'. 'nub' keeps one per (pos,label,...),
      -- preserving source order; distinct warnings differ in their fields.
      pure (Right (a, nub (reverse ws)))

currentLevel :: TC s Level
currentLevel = asks ctxLevel

currentEnv :: TC s Env
currentEnv = asks ctxEnv

-- | The ambient effect row of the equation being checked, if any.
currentEffRow :: TC s (Maybe (STRef s (Row s)))
currentEffRow = asks ctxEffRow

-- | Run an action with the given ambient effect-row cell installed. Operation
-- calls and effectful applications inside the action extend that cell.
withEffRow :: STRef s (Row s) -> TC s a -> TC s a
withEffRow ref = local (\c -> c { ctxEffRow = Just ref })

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
withEnv f = local $ \c -> c { ctxEnv = f (ctxEnv c) }

extendVarTC :: Text -> Scheme -> TC s a -> TC s a
extendVarTC name sch = withEnv (extendVar name sch)

-- | Like 'runTC' but discards warnings. Convenient for callers that only
-- care about the result or the error (e.g. unit tests for unification).
runTC_ :: Env -> (forall s. TC s a) -> Either TypeError a
runTC_ env action = fmap fst (runTC env action)

-- | Append a non-fatal warning to the accumulated list.
addWarning :: Warning -> TC s ()
addWarning w = do
  ref <- asks ctxWarnings
  liftST $ modifySTRef' ref (w :)

-- | Record an inference-time constraint (class name, type argument).
addConstraint :: Text -> Type s -> TC s ()
addConstraint cls arg = do
  ref <- asks ctxConstraints
  liftST $ modifySTRef' ref (ConstraintS cls arg :)

-- | Read and clear all currently-accumulated constraints (in insertion order).
takeConstraints :: TC s [ConstraintS s]
takeConstraints = do
  ref <- asks ctxConstraints
  liftST $ do
    cs <- readSTRef ref
    writeSTRef ref []
    pure (reverse cs)
