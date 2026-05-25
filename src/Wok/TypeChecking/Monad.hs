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
import Control.Monad.Reader (MonadReader, ReaderT, asks, local, runReaderT)
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
withEnv f = local $ \c -> c { ctxEnv = f (ctxEnv c) }

extendVarTC :: Text -> Scheme -> TC s a -> TC s a
extendVarTC name sch = withEnv (extendVar name sch)
