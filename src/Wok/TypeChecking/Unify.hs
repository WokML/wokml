-- | Unification, occurs check + level adjustment, and the freeze pass
-- that converts inference-time @Type s@ into closed @CType@.
--
-- Implements the Leijen 2005 scoped-label row unifier. 'unifyRow' handles
-- the full algorithm: RowEmpty ~ RowEmpty, row-var-to-row, row-var-to-row-var,
-- and RowExtend ~ row via 'rewriteRow'. 'rewriteRowStrict' is the variant
-- used by field access (Task 6) that refuses to extend a row variable.
module Wok.TypeChecking.Unify
  ( unify
  , unifyVar
  , rigidUnify
  , unifyRow
  , rewriteRow
  , rewriteRowStrict
  , bindRowVar
  , force
  , forceRow
  , freeze
  , freezeTolerant
  , freezeRow
  , occursAdjust
  , occursAdjustRow
  ) where

import Control.Monad (when, zipWithM_)
import Control.Monad.Except (throwError)
import Data.STRef (STRef, readSTRef, writeSTRef)
import Data.Text (Text)
import qualified Data.Map.Strict as Map
import qualified Data.Text as Tx
import Wok.TypeChecking.Error (SourceSpan, TypeError (..), Warning (..))
import Wok.TypeChecking.Monad (TC, addWarning, freshRVar, freshTVar, liftST)
import Wok.TypeChecking.Types
  ( CRow (..), CType (..), Kind (..), Level (..), RVar (..), Row (..), TVar (..), Type (..) )

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
force t@(TRecord _ _) = pure t
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
    TRecord tag row -> CTRecord tag <$> freezeRow row
    TVar ref -> do
      tv <- liftST $ readSTRef ref
      case tv of
        Unbound u _ _ -> pure (CTGen u)
        Link _ -> error "freeze: TVar was Link after force (caller invariant violation)"
        Rigid u _ -> error ("freeze: unexpected Rigid (uniq " ++ show u ++ ")")

-- | Like 'freeze', but TOLERATES 'Rigid' skolems by mapping each @Rigid u@ to
-- @CTGen u@ (the skolem's uniq used directly as the generic index), instead of
-- erroring. Used by the signed-path constraint validator to freeze a constraint
-- argument that may embed signature skolems UNDER type constructors (e.g.
-- @Eq (Option a)@ where @a@ is a declared skolem). Because the mapping is the
-- identity on uniqs, a caller that knows the set of PROMISED skolem uniqs can
-- feed it directly to 'Solve.resolve' as the in-scope param set, so a residual
-- @CTGen u@ for a promised skolem resolves to 'EvParam' (entailed) rather than
-- 'Ambiguous'. Unbound metavars still become @CTGen u@ (never promised, so they
-- resolve to 'Ambiguous' -- the under-entailed case).
freezeTolerant :: Type s -> TC s CType
freezeTolerant t = do
  t' <- force t
  case t' of
    TCon c ts -> CTCon c <$> mapM freezeTolerant ts
    TArr a r b -> CTArr <$> freezeTolerant a <*> freezeRow r <*> freezeTolerant b
    TRecord tag row -> CTRecord tag <$> freezeRow row
    TVar ref -> do
      tv <- liftST $ readSTRef ref
      case tv of
        Unbound u _ _ -> pure (CTGen u)
        Rigid u _ -> pure (CTGen u)
        Link _ -> error "freezeTolerant: TVar was Link after force (caller invariant violation)"

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
    go (TArr a r b) = go a >> occursAdjustRow sp target lvl r >> go b
    go (TRecord _ row) = occursAdjustRow sp target lvl row

occursAdjustRow :: SourceSpan -> STRef s (TVar s) -> Level -> Row s -> TC s ()
occursAdjustRow _ _ _ RowEmpty = pure ()
occursAdjustRow sp target lvl (RowExtend _ ty rest) = do
  occursAdjust sp target lvl ty
  occursAdjustRow sp target lvl rest
occursAdjustRow sp target lvl (RowVar ref) = do
  rv <- liftST $ readSTRef ref
  case rv of
    RLink r' -> occursAdjustRow sp target lvl r'
    RUnbound u l ->
      when (l > lvl) $
        liftST $ writeSTRef ref (RUnbound u lvl)

-- | Walk a 'Row', adjusting the levels of unbound row variables that
-- exceed @lvl@, and recursing into each field's type via 'adjustLevels'.
-- Used by 'occursAdjustRowVar' to lower levels of type variables encountered
-- in the row's field types.
adjustLevelsRow :: Level -> Row s -> TC s ()
adjustLevelsRow lvl = go
  where
    go RowEmpty = pure ()
    go (RowExtend _ ty rest) = do
      adjustLevels lvl ty
      go rest
    go (RowVar ref) = do
      rv <- liftST $ readSTRef ref
      case rv of
        RLink r' -> go r'
        RUnbound u l ->
          when (l > lvl) $
            liftST $ writeSTRef ref (RUnbound u lvl)

-- | Walk a 'Type', adjusting levels of unbound type variables that exceed
-- @lvl@. Does not check for any specific target (no occurs check).
adjustLevels :: Level -> Type s -> TC s ()
adjustLevels lvl = go
  where
    go (TVar r) = do
      tv <- liftST $ readSTRef r
      case tv of
        Link t' -> go t'
        Unbound u l k ->
          when (l > lvl) $
            liftST $ writeSTRef r (Unbound u lvl k)
        Rigid _ _ -> pure ()
    go (TCon _ ts) = mapM_ go ts
    go (TArr a r b) = go a >> adjustLevelsRow lvl r >> go b
    go (TRecord _ row) = adjustLevelsRow lvl row

-- | Combined occurs check + level adjustment for row variables. Mirrors the
-- shape of 'occursAdjust' but walks a 'Row', refusing to write the target ref.
-- Throws 'RowOccursCheck' on a cycle (row variable occurs in its own binding).
occursAdjustRowVar :: SourceSpan -> STRef s (RVar s) -> Level -> Row s -> TC s ()
occursAdjustRowVar sp target lvl = go
  where
    go RowEmpty = pure ()
    go (RowExtend _ ty rest) = do
      -- Adjust levels of type-level vars inside the field type; the target
      -- is a row ref so there is no type-level occurrence to check.
      adjustLevels lvl ty
      go rest
    go (RowVar r)
      | r == target = do
          -- Capture the uniq and a frozen snapshot of the cyclic row.
          rv <- liftST $ readSTRef target
          case rv of
            RUnbound u _ -> do
              bound <- freezeRow (RowVar target)
              throwError (RowOccursCheck sp u bound)
            RLink _ ->
              error "occursAdjustRowVar: target was RLink (caller must force first)"
      | otherwise = do
          rv <- liftST $ readSTRef r
          case rv of
            RLink r' -> go r'
            RUnbound u l ->
              when (l > lvl) $
                liftST $ writeSTRef r (RUnbound u lvl)

-- | Bind a row variable to a row. Performs occurs check + level adjustment.
-- The caller must have forced the ref and confirmed it is 'RUnbound'.
bindRowVar :: SourceSpan -> STRef s (RVar s) -> Row s -> TC s ()
bindRowVar sp ref row = do
  rv <- liftST $ readSTRef ref
  case rv of
    RUnbound _ lvl -> do
      occursAdjustRowVar sp ref lvl row
      liftST $ writeSTRef ref (RLink row)
    RLink _ -> error "bindRowVar: caller must have forced first"

-- | Bubble label @l@ to the head of @row@. On 'RowVar', allocates a fresh
-- type and tail variable, and binds the variable to
-- @RowExtend l freshTy freshTail@.  Returns the type of the label and the
-- remaining row (the row with @l@ removed).
--
-- Implements the head-bubbling step of the Leijen 2005 scoped-label algorithm.
-- Same-name labels coexist in a row; this function returns the OUTERMOST one.
rewriteRow :: SourceSpan -> Text -> Row s -> TC s (Type s, Row s)
rewriteRow sp l row = do
  row' <- forceRow row
  case row' of
    RowExtend l' t rest
      | l == l'   -> pure (t, rest)
      | otherwise -> do
          (t', rest') <- rewriteRow sp l rest
          pure (t', RowExtend l' t rest')
    RowVar ref -> do
      tFresh    <- freshTVar KStar
      restFresh <- freshRVar
      bindRowVar sp ref (RowExtend l tFresh restFresh)
      pure (tFresh, restFresh)
    RowEmpty ->
      throwError (UnknownField sp (Tx.pack "<row>") l)

-- | Like 'rewriteRow' but REFUSES to extend a row variable. Used for field
-- access (@p.x@, Task 6): we want a clean error rather than silently
-- inferring the label into an unknown row.
rewriteRowStrict :: SourceSpan -> Text -> Row s -> TC s (Type s, Row s)
rewriteRowStrict sp l row = do
  row' <- forceRow row
  case row' of
    RowExtend l' t rest
      | l == l'   -> pure (t, rest)
      | otherwise -> do
          (t', rest') <- rewriteRowStrict sp l rest
          pure (t', RowExtend l' t rest')
    RowVar _ ->
      throwError (UnknownField sp (Tx.pack "<row>") l)
    RowEmpty ->
      throwError (UnknownField sp (Tx.pack "<row>") l)

-- | Unify two types. The source span (if any) is attached to errors.
unify :: SourceSpan -> Type s -> Type s -> TC s ()
unify sp a b = do
  a' <- force a
  b' <- force b
  case (a', b') of
    (TVar r1, TVar r2) | r1 == r2 -> pure ()
    (TVar r, t) -> unifyVar sp r t >> warnIfRecordShadow sp t
    (t, TVar r) -> unifyVar sp r t >> warnIfRecordShadow sp t
    (TCon c1 ts1, TCon c2 ts2)
      | c1 == c2, length ts1 == length ts2 -> zipWithM_ (unify sp) ts1 ts2
    (TArr a1 e1 b1, TArr a2 e2 b2) -> do
      unify sp a1 a2
      unifyRow sp e1 e2
      unify sp b1 b2
    (TRecord tag1 row1, TRecord tag2 row2) -> do
      when (tag1 /= tag2) $
        throwError (NominalMismatch sp tag1 tag2)
      unifyRow sp row1 row2
      -- After successful row unification, warn on any label that appears
      -- more than once in the resulting row (scoped-label shadow).
      warnOnShadow sp row1
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

-- | Unify two rows using the Leijen 2005 scoped-label algorithm.
--
-- Cases:
--   - RowEmpty ~ RowEmpty: trivially succeed.
--   - RowVar v1 ~ RowVar v2 (same ref): succeed.
--   - RowVar v ~ row (or row ~ RowVar v): bind via 'bindRowVar'.
--   - RowExtend l t rest ~ row2: bubble @l@ to the head of @row2@ via
--     'rewriteRow', then unify the field types and recurse on the tails.
--   - RowEmpty ~ RowExtend: mismatch.
unifyRow :: SourceSpan -> Row s -> Row s -> TC s ()
unifyRow sp r1 r2 = do
  r1' <- forceRow r1
  r2' <- forceRow r2
  case (r1', r2') of
    (RowEmpty, RowEmpty) -> pure ()

    (RowVar v1, RowVar v2)
      | v1 == v2  -> pure ()
      | otherwise -> bindRowVar sp v1 (RowVar v2)

    (RowVar v, row) -> bindRowVar sp v row
    (row, RowVar v) -> bindRowVar sp v row

    (RowExtend l1 t1 rest1, row2) -> do
      (t2, rest2') <- rewriteRow sp l1 row2
      unify sp t1 t2
      unifyRow sp rest1 rest2'

    (RowEmpty, RowExtend _ _ _) -> do
      cr1 <- freezeRow r1'
      cr2 <- freezeRow r2'
      throwError (RowMismatch sp cr1 cr2)

-- | When a type variable is bound to a record type, scan that record's row for
-- shadowed labels. This catches collisions introduced indirectly -- e.g. a
-- row-polymorphic function applied to an argument that already carries a label
-- the function adds, where the duplicate ends up in a result record that is
-- never itself unified against another 'TRecord' (so the 'unify' TRecord~TRecord
-- path would miss it). No-op for non-records and for records without duplicates.
warnIfRecordShadow :: SourceSpan -> Type s -> TC s ()
warnIfRecordShadow sp t = do
  t' <- force t
  case t' of
    TRecord _ row -> warnOnShadow sp row
    _             -> pure ()

-- | After row unification, walk the (now-resolved) row and emit a
-- 'RowShadow' warning for each label that appears more than once.
-- Scoped labels are valid Leijen 2005 semantics, but the outer label
-- silently shadows the inner one — the warning informs the user.
warnOnShadow :: SourceSpan -> Row s -> TC s ()
warnOnShadow sp row = do
  pairs <- collectRowPairs row
  -- Group by label; any label with >1 entry is a shadow.
  let grouped = Map.fromListWith (++) [ (l, [t]) | (l, t) <- pairs ]
  mapM_ (checkGroup sp) (Map.toList grouped)
  where
    checkGroup sp' (label, types) =
      case types of
        (t1 : t2 : _) -> do
          c1 <- freeze t1
          c2 <- freeze t2
          addWarning (RowShadow sp' label c1 c2)
        _ -> pure ()

-- | Walk a row (forcing at each step) and collect all (label, Type) pairs
-- encountered. Stops at RowEmpty or RowVar (open tail).
collectRowPairs :: Row s -> TC s [(Text, Type s)]
collectRowPairs row = do
  row' <- forceRow row
  case row' of
    RowEmpty          -> pure []
    RowVar _          -> pure []
    RowExtend l t rest -> do
      rest' <- collectRowPairs rest
      pure ((l, t) : rest')
