-- | Unification, occurs check + level adjustment, and the freeze pass
-- that converts inference-time @Type s@ into closed @CType@.
--
-- v1 only implements the parts of this module needed before the actual
-- 'unify' driver lands (Task 5). The row unifier is also v1-stubbed:
-- 'unifyRow' will only accept @RowEmpty ~ RowEmpty@. The scoped-label
-- algorithm replaces it in the rows-and-effects spec.
module Wok.TypeChecking.Unify
  ( unify
  , unifyVar
  , rigidUnify
  , unifyRow
  , force
  , forceRow
  , freeze
  , freezeRow
  , occursAdjust
  , occursAdjustRow
  ) where

import Control.Monad (when, zipWithM_)
import Control.Monad.Except (throwError)
import Data.STRef (STRef, readSTRef, writeSTRef)
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
    Rigid {} -> pure t
force t = pure t

-- | Chase a chain of 'RLink' refs in a row, path-compressing.
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
-- become @CTGen@ slots indexed by their uniq. The caller is responsible
-- for ensuring the chosen scheme makes sense (in v1, only 'generalize'
-- in Task 6 inspects the structure of these CTGens).
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
        Link _ -> error "freeze: TVar was Link after force (caller invariant violation)"
        Rigid u _ -> error ("freeze: unexpected Rigid (uniq " ++ show u ++ ")")

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
        RLink _ -> error "freezeRow: RowVar was RLink after forceRow (caller invariant violation)"

-- | Combined occurs check + level adjustment. Walks the type being
-- assigned, failing if the target ref appears, and lowering the level
-- of any other unbound variable whose level exceeds the target's.
occursAdjust :: SourceSpan -> STRef s (TVar s) -> Level -> Type s -> TC s ()
occursAdjust sp target lvl = go
  where
    go (TVar r)
      | r == target = do
          tv <- liftST $ readSTRef target
          case tv of
            Unbound u _ _ ->
              throwError (OccursCheck sp u (CTGen u))
            Link _ ->
              -- Invariant: unifyVar reads target as Unbound before calling
              -- occursAdjust, and nothing writes to target in between. If
              -- target is Link here, a caller forgot to force first.
              error "occursAdjust: target was Link after force"
            Rigid u _ ->
              throwError (OccursCheck sp u (CTGen u))
      | otherwise = do
          tv <- liftST $ readSTRef r
          case tv of
            Link t' -> go t'
            Unbound u l k ->
              when (l > lvl) $
                liftST $ writeSTRef r (Unbound u lvl k)
            Rigid _ _ -> pure ()  -- skolems have no mutable level
    go (TCon _ ts) = mapM_ go ts
    go (TArr a r b) = go a >> occursAdjustRow lvl r >> go b

occursAdjustRow :: Level -> Row s -> TC s ()
occursAdjustRow _ RowEmpty = pure ()
occursAdjustRow lvl (RowExtend _ _ rest) = occursAdjustRow lvl rest
  -- v1 produces no nested types in rows (all rows are empty); when
  -- the rows spec lands, recurse into the type at each label too.
occursAdjustRow lvl (RowVar ref) = do
  rv <- liftST $ readSTRef ref
  case rv of
    RLink r' -> occursAdjustRow lvl r'
    RUnbound u l ->
      when (l > lvl) $
        liftST $ writeSTRef ref (RUnbound u lvl)

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
    Rigid u _ -> rigidUnify sp ref u t
    Unbound _ lvl _ -> do
      -- TODO(v2-rows): check kinds before linking. The TVar's kind field
      -- is ignored in v1 because every type is KStar; once KEffect / KArrow
      -- row variables ship, we need to verify the target's kind matches the
      -- kind of `t` and emit a KindMismatch error if not.
      occursAdjust sp ref lvl t
      liftST $ writeSTRef ref (Link t)

-- | A rigid skolem only unifies with itself (same STRef) or with an Unbound
-- inference variable (which gets pinned to the rigid). Any other combination
-- raises 'RigidEscape', because it means the body is less general than the
-- declared signature.
rigidUnify :: SourceSpan -> STRef s (TVar s) -> Int -> Type s -> TC s ()
rigidUnify sp ref u t = case t of
  TVar r' | r' == ref -> pure ()
  TVar r' -> do
    tv' <- liftST $ readSTRef r'
    case tv' of
      Link _ -> error "rigidUnify: t must have been forced"
      Unbound _ _ _ ->
        -- Pin the Unbound side to the Rigid (flip direction).
        liftST $ writeSTRef r' (Link (TVar ref))
      Rigid _ _ ->
        -- Two distinct rigids can't unify.
        throwError (RigidEscape sp u)
  _ -> throwError (RigidEscape sp u)

unifyRow :: SourceSpan -> Row s -> Row s -> TC s ()
unifyRow _ RowEmpty RowEmpty = pure ()
unifyRow sp r1 r2 = do
  cr1 <- freezeRow r1
  cr2 <- freezeRow r2
  throwError (RowMismatch sp cr1 cr2)
