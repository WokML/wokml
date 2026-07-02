{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE RankNTypes #-}

-- | The type-checker monad: ReaderT for environment + current level,
-- ExceptT for fail-fast errors, ST for mutable type-variable cells.
module Wok.TypeChecking.Monad
  ( TC
  , TCCtx (..)
  , RowRef
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
  , withCallerRoots
  , currentCallerResidualRoots
  , recordPendingResidual
  , takePendingResiduals
  ) where

import Control.Monad.Except (ExceptT, MonadError, runExceptT)
import Control.Monad.Reader (MonadReader, ReaderT, asks, local, runReaderT)
import Control.Monad.Trans (lift)
import Control.Monad.ST (ST, runST)
import Data.List (nubBy)
import Data.STRef (STRef, modifySTRef', newSTRef, readSTRef, writeSTRef)
import Data.Text (Text)
import Wok.TypeChecking.Env (Env, extendVar)
import Wok.TypeChecking.Error (SourceSpan, TypeError, Warning (RowShadow))
import Wok.TypeChecking.Types
  ( Kind (..), Level (..), Row, Scheme, TVar (..), Type (..) )

-- | A mutable effect-row-variable cell (the 'STRef' inside a 'TVar' of kind
-- 'KEffect'). Used to identify the caller-supplied residual roots (the row
-- variables occurring in the enclosing equation's declared parameter and result
-- types) so a bare residual tail can be matched against them by representative
-- identity -- see 'ctxCallerResidualRoots'.
type RowRef s = STRef s (TVar s)

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
  , ctxCallerResidualRoots :: [RowRef s]
    -- ^ The representative cells of every 'KEffect' row VARIABLE occurring in the
    -- enclosing equation's DECLARED parameter and result types -- its
    -- "caller-supplied roots" -- OR the empty list when that equation's declared
    -- effect row is OPEN (an open row discharges any residual through its own open
    -- tail, so nothing is an obligation). A bare residual effect-row tail is an
    -- undischarged obligation IFF its representative is one of these (a
    -- caller-supplied polymorphic row cannot be handled internally). Every OTHER
    -- bare tail (a handler sub-ambient leftover, a resume-continuation row, a
    -- runner thunk's leftover) is internal, not a root, and closes to empty --
    -- benign. Set per equation by 'withCallerRoots' (SETTING, not accumulating:
    -- each equation gets its own params/result, and a nested sub-ambient does NOT
    -- reset the set -- so a root performed under an open handler sub-ambient is
    -- still recognised, which is what makes the handler-discharge leaks visible).
  , ctxConstraints :: STRef s [ConstraintS s]
    -- ^ Constraints accumulated during inference. Prepended in emission order;
    -- 'takeConstraints' reverses to restore insertion order.
  , ctxPendingResiduals :: STRef s [(SourceSpan, Text)]
    -- ^ Undischarged residual-effect-row obligations recorded during inference.
    -- When a callee performs a bare residual effect-row variable that is one of
    -- the enclosing equation's caller-supplied roots ('ctxCallerResidualRoots'),
    -- the verdict is recorded HERE rather than thrown immediately, so the module-level
    -- carrier/affine post-passes report first. Drained by 'takePendingResiduals'
    -- after those passes; the first entry is the reported obligation. Prepended
    -- in emission order; 'takePendingResiduals' reverses.
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
  residRef <- newSTRef []
  let ctx = TCCtx freshRef (Level 0) env warnsRef Nothing [] consRef residRef
  result <- runExceptT (runReaderT (unTC action) ctx)
  case result of
    Left err -> pure (Left err)
    Right a  -> do
      ws <- readSTRef warnsRef
      -- Dedup structurally-identical warnings: the same shadow can be reached
      -- through more than one unification (e.g. a record value unified against
      -- a placeholder and again against its declared sig), and each path may
      -- re-emit the identical 'RowShadow'. For 'RowShadow' we dedup on
      -- (label, outer type, inner type) only, IGNORING the 'SourceSpan': the
      -- same shadow can now arrive with different positions (one path carries a
      -- 'Just p' application span, another 'Nothing'), and we must not splinter
      -- it into two warnings. All other warning constructors keep full
      -- structural equality. Keeps the first occurrence, preserving source order.
      pure (Right (a, nubBy warnEqIgnoringShadowPos (reverse ws)))

-- | Warning equality for deduplication that ignores the 'SourceSpan' of
-- 'RowShadow' (comparing only label + the two types); every other constructor
-- compares by full structural equality.
warnEqIgnoringShadowPos :: Warning -> Warning -> Bool
warnEqIgnoringShadowPos (RowShadow _ l1 a1 b1) (RowShadow _ l2 a2 b2) =
  l1 == l2 && a1 == a2 && b1 == b2
warnEqIgnoringShadowPos w1 w2 = w1 == w2

currentLevel :: TC s Level
currentLevel = asks ctxLevel

currentEnv :: TC s Env
currentEnv = asks ctxEnv

-- | The ambient effect row of the equation being checked, if any.
currentEffRow :: TC s (Maybe (STRef s (Row s)))
currentEffRow = asks ctxEffRow

-- | Run an action with the given ambient effect-row cell installed. Operation
-- calls and effectful applications inside the action extend that cell. Whether a
-- residual performed here is an obligation is decided by the caller-supplied
-- roots ('ctxCallerResidualRoots'), which are installed once per equation by
-- 'withCallerRoots' and are NOT reset by a freshly-installed sub-ambient.
withEffRow :: STRef s (Row s) -> TC s a -> TC s a
withEffRow ref = local (\c -> c { ctxEffRow = Just ref })

-- | Run an action with the given caller-supplied residual roots installed (see
-- 'ctxCallerResidualRoots'). SETS the set (does not accumulate): each equation
-- installs exactly the roots of its OWN declared parameter and result types.
withCallerRoots :: [RowRef s] -> TC s a -> TC s a
withCallerRoots refs = local (\c -> c { ctxCallerResidualRoots = refs })

-- | The caller-supplied residual roots currently in scope.
currentCallerResidualRoots :: TC s [RowRef s]
currentCallerResidualRoots = asks ctxCallerResidualRoots

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
  ref <- liftST $ newSTRef (Unbound u lvl KEffect)
  pure (TVar ref)

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

-- | Record an undischarged residual-effect-row obligation (position, label).
recordPendingResidual :: SourceSpan -> Text -> TC s ()
recordPendingResidual sp label = do
  ref <- asks ctxPendingResiduals
  liftST $ modifySTRef' ref ((sp, label) :)

-- | Read and clear all recorded residual obligations, in insertion order (so
-- the head is the first one recorded during inference).
takePendingResiduals :: TC s [(SourceSpan, Text)]
takePendingResiduals = do
  ref <- asks ctxPendingResiduals
  liftST $ do
    xs <- readSTRef ref
    writeSTRef ref []
    pure (reverse xs)
