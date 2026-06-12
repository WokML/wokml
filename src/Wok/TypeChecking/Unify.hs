-- | Unification, occurs check + level adjustment, and the freeze pass
-- that converts inference-time @Type s@ into closed @CType@.
--
-- Implements the Leijen 2005 scoped-label row unifier inline in 'unify':
-- RowEmpty ~ RowEmpty, row-var-to-row, row-var-to-row-var, and
-- RowExtend ~ row via 'rewriteRow'. 'rewriteRowStrict' is the variant
-- used by field access (Task 6) that refuses to extend a row variable.
--
-- After the kinded-Ty merge, rows are just 'Type' nodes of kind 'KEffect':
-- a row variable is a 'TVar' whose cell has @kind = KEffect@. The single
-- traversal here handles both ordinary types and rows.
module Wok.TypeChecking.Unify
  ( unify
  , unifyVar
  , rigidUnify
  , unifyRow
  , rewriteRow
  , rewriteRowStrict
  , force
  , freeze
  , freezeTolerant
  , occursAdjust
  , kindOf
  ) where

import Control.Monad (when, zipWithM_)
import Control.Monad.Except (catchError, throwError)
import Data.STRef (STRef, readSTRef, writeSTRef)
import Data.Text (Text)
import qualified Data.Map.Strict as Map
import qualified Data.Text as Tx
import Wok.TypeChecking.Error (SourceSpan, TypeError (..), Warning (..))
import Wok.TypeChecking.Monad (TC, addWarning, freshRVar, freshTVar, liftST)
import Wok.TypeChecking.Types
  ( CType (..), Kind (..), Level (..), Row, TVar (..), Type (..) )

-- | Chase a chain of 'Link' refs to the head, path-compressing along the way.
-- Works for ordinary types and rows alike (a row variable is just a 'TVar').
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

-- | Convert an inference-time type to a closed type. Unbound variables
-- become @CTGen@ slots indexed by their uniq. The caller is responsible
-- for ensuring the chosen scheme makes sense (in v1, only 'generalize'
-- in Task 6 inspects the structure of these CTGens). Row nodes (kind
-- 'KEffect') become @CREmpty@/@CRExtend@.
freeze :: Type s -> TC s CType
freeze t = do
  t' <- force t
  case t' of
    TCon c ts -> CTCon c <$> mapM freeze ts
    TArr a r b -> CTArr <$> freeze a <*> freeze r <*> freeze b
    TRecord tag row -> CTRecord tag <$> freeze row
    RowEmpty -> pure CREmpty
    RowExtend l p r -> CRExtend l <$> freeze p <*> freeze r
    TVar ref -> do
      tv <- liftST $ readSTRef ref
      case tv of
        Unbound u _ _ -> pure (CTGen u)
        Link _ -> error "freeze: TVar was Link after force (caller invariant violation)"
        Rigid u _ _ -> error ("freeze: unexpected Rigid (uniq " ++ show u ++ ")")

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
    TArr a r b -> CTArr <$> freezeTolerant a <*> freezeTolerant r <*> freezeTolerant b
    TRecord tag row -> CTRecord tag <$> freezeTolerant row
    RowEmpty -> pure CREmpty
    RowExtend l p r -> CRExtend l <$> freezeTolerant p <*> freezeTolerant r
    TVar ref -> do
      tv <- liftST $ readSTRef ref
      case tv of
        Unbound u _ _ -> pure (CTGen u)
        Rigid u _ _ -> pure (CTGen u)
        Link _ -> error "freezeTolerant: TVar was Link after force (caller invariant violation)"

-- | Combined occurs check + level adjustment. Walks the type being
-- assigned, failing if the target ref appears, and lowering the level
-- of any other unbound variable whose level exceeds the target's.
-- Row nodes (kind 'KEffect') are walked via the 'RowEmpty'/'RowExtend' arms.
occursAdjust :: SourceSpan -> STRef s (TVar s) -> Level -> Type s -> TC s ()
occursAdjust sp target lvl = go
  where
    go (TVar r)
      | r == target = do
          tv <- liftST $ readSTRef target
          case tv of
            -- A row variable (kind 'KEffect') cycling on itself is a
            -- RowOccursCheck; a type variable (kind 'KStar') is OccursCheck.
            Unbound u _ KEffect ->
              throwError (RowOccursCheck sp u (CTGen u))
            Unbound u _ _ ->
              throwError (OccursCheck sp u (CTGen u))
            Link _ ->
              -- Invariant: unifyVar reads target as Unbound before calling
              -- occursAdjust, and nothing writes to target in between. If
              -- target is Link here, a caller forgot to force first.
              error "occursAdjust: target was Link after force"
            Rigid u _ _ ->
              throwError (OccursCheck sp u (CTGen u))
      | otherwise = do
          tv <- liftST $ readSTRef r
          case tv of
            Link t' -> go t'
            Unbound u l k ->
              when (l > lvl) $
                liftST $ writeSTRef r (Unbound u lvl k)
            Rigid _ _ _ -> pure ()  -- skolems have no mutable level
    go (TCon _ ts) = mapM_ go ts
    go (TArr a r b) = go a >> go r >> go b
    go (TRecord _ row) = go row
    go RowEmpty = pure ()
    go (RowExtend _ ty rest) = go ty >> go rest

-- | Bubble label @l@ to the head of @row@. On a row variable (a 'TVar' of
-- kind 'KEffect'), allocates a fresh type and tail variable, and binds the
-- variable to @RowExtend l freshTy freshTail@.  Returns the type of the label
-- and the remaining row (the row with @l@ removed).
--
-- Implements the head-bubbling step of the Leijen 2005 scoped-label algorithm.
-- Same-name labels coexist in a row; this function returns the OUTERMOST one.
rewriteRow :: SourceSpan -> Text -> Row s -> TC s (Type s, Row s)
rewriteRow sp l row = do
  row' <- force row
  case row' of
    RowExtend l' t rest
      | l == l'   -> pure (t, rest)
      | otherwise -> do
          (t', rest') <- rewriteRow sp l rest
          pure (t', RowExtend l' t rest')
    TVar ref -> do
      tFresh    <- freshTVar KStar
      restFresh <- freshRVar
      unifyVar sp ref (RowExtend l tFresh restFresh)
      pure (tFresh, restFresh)
    RowEmpty ->
      throwError (UnknownField sp (Tx.pack "<row>") l)
    _ -> error "rewriteRow: expected a row"

-- | The open-tail row variable of a row, if any: walk the (forced) row to its
-- end and return the 'STRef' of a trailing row variable, or 'Nothing' for a
-- closed row ('RowEmpty') or non-row. Used by 'unify' to detect the shared-tail
-- case before bubbling a label, preventing 'rewriteRow' from looping.
rowTailRef :: Row s -> TC s (Maybe (STRef s (TVar s)))
rowTailRef row = do
  row' <- force row
  case row' of
    RowExtend _ _ rest -> rowTailRef rest
    TVar ref           -> pure (Just ref)
    _                  -> pure Nothing

-- | Like 'rewriteRow', but FAILS (with 'UnknownField', rewritten to a row error
-- by the caller) instead of extending the row variable @forbidden@. This is the
-- Leijen/Gaster-Jones side condition: bubbling a label must not extend the very
-- tail variable shared with the other row, which would otherwise diverge.
rewriteRowGuarded
  :: SourceSpan
  -> Maybe (STRef s (TVar s))  -- ^ the forbidden (shared) tail variable
  -> Text
  -> Row s
  -> TC s (Type s, Row s)
rewriteRowGuarded sp forbidden l row = do
  row' <- force row
  case row' of
    RowExtend l' t rest
      | l == l'   -> pure (t, rest)
      | otherwise -> do
          (t', rest') <- rewriteRowGuarded sp forbidden l rest
          pure (t', RowExtend l' t rest')
    TVar ref
      | Just ref == forbidden ->
          -- Extending the shared tail would loop; treat as label-not-found so
          -- the caller surfaces a positioned RowMismatch.
          throwError (UnknownField sp (Tx.pack "<row>") l)
      | otherwise -> do
          tFresh    <- freshTVar KStar
          restFresh <- freshRVar
          unifyVar sp ref (RowExtend l tFresh restFresh)
          pure (tFresh, restFresh)
    RowEmpty ->
      throwError (UnknownField sp (Tx.pack "<row>") l)
    _ -> error "rewriteRowGuarded: expected a row"

-- | Like 'rewriteRow' but REFUSES to extend a row variable. Used for field
-- access (@p.x@, Task 6): we want a clean error rather than silently
-- inferring the label into an unknown row.
rewriteRowStrict :: SourceSpan -> Text -> Row s -> TC s (Type s, Row s)
rewriteRowStrict sp l row = do
  row' <- force row
  case row' of
    RowExtend l' t rest
      | l == l'   -> pure (t, rest)
      | otherwise -> do
          (t', rest') <- rewriteRowStrict sp l rest
          pure (t', RowExtend l' t rest')
    TVar _ ->
      throwError (UnknownField sp (Tx.pack "<row>") l)
    RowEmpty ->
      throwError (UnknownField sp (Tx.pack "<row>") l)
    _ -> error "rewriteRowStrict: expected a row"

-- | Unify two types. The source span (if any) is attached to errors.
-- Rows (kind 'KEffect') are unified inline using the Leijen 2005 scoped-label
-- algorithm via the 'RowEmpty'/'RowExtend' arms below.
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
      unify sp e1 e2
      unify sp b1 b2
    (TRecord tag1 row1, TRecord tag2 row2) -> do
      when (tag1 /= tag2) $
        throwError (NominalMismatch sp tag1 tag2)
      unify sp row1 row2
      -- After successful row unification, warn on any label that appears
      -- more than once in the resulting row (scoped-label shadow).
      warnOnShadow sp row1
    (RowEmpty, RowEmpty) -> pure ()
    (RowExtend l1 t1 rest1, _) -> do
      -- Leijen/Gaster-Jones SHARED-TAIL side condition (prevents divergence).
      -- Bubbling @l1@ through @b'@ may reach @b'@'s open tail variable and want
      -- to extend it with a fresh @RowExtend l1 _ _@. If that tail is the SAME
      -- variable as @a'@'s own open tail (e.g. unifying @{A | e0} ~ {B | e0}@,
      -- two distinct-head rows over one shared row var), extending it makes the
      -- subsequent @unify rest1 rest2'@ re-encounter the identical shape one
      -- level deeper -- forever. Detect the shared tail up front and fail with a
      -- positioned row error instead of looping.
      --
      -- Bubble label @l1@ through @b'@. A label-not-found failure (genuine
      -- absence OR the shared-tail guard firing) surfaces as an
      -- 'UnknownField sp "<row>" l1' placeholder; rewrite it into a positioned
      -- 'RowMismatch' showing BOTH full rows (the same shape as the
      -- 'RowEmpty'/'RowExtend' arm below). Any other error (KindMismatch,
      -- OccursCheck, NominalMismatch from the recursive unifies, ...) is rethrown
      -- unchanged so we do not mask genuine failures.
      sharedTail <- rowTailRef rest1
      (t2, rest2') <- rewriteRowGuarded sp sharedTail l1 b' `catchError` \case
        UnknownField{} -> do
          ca <- freeze a'
          cb <- freeze b'
          throwError (RowMismatch sp ca cb)
        e -> throwError e
      unify sp t1 t2
      unify sp rest1 rest2'
    (RowEmpty, RowExtend{}) -> do
      ca <- freeze a'
      cb <- freeze b'
      throwError (RowMismatch sp ca cb)
    _ -> do
      ca <- freeze a'
      cb <- freeze b'
      throwError (Mismatch sp ca cb)

-- | Backwards-compatible alias: rows are now ordinary types, so unifying two
-- rows is just 'unify'.
unifyRow :: SourceSpan -> Row s -> Row s -> TC s ()
unifyRow = unify

-- | The kind of a type expression. Forces first, then reads off the kind:
-- row nodes are 'KEffect'; ordinary type constructors / arrows / records are
-- 'KStar'; a variable reports its cell's declared kind (recursing through Link).
kindOf :: Type s -> TC s Kind
kindOf t = do
  t' <- force t
  case t' of
    RowEmpty -> pure KEffect
    RowExtend{} -> pure KEffect
    TCon{} -> pure KStar
    TArr{} -> pure KStar
    TRecord{} -> pure KStar
    TVar ref -> do
      tv <- liftST $ readSTRef ref
      case tv of
        Unbound _ _ k -> pure k
        Rigid _ _ k -> pure k
        Link u -> kindOf u

unifyVar :: SourceSpan -> STRef s (TVar s) -> Type s -> TC s ()
unifyVar sp ref t = do
  tv <- liftST $ readSTRef ref
  case tv of
    Link _ -> error "unifyVar: caller must have forced first"
    Rigid u rlvl rk -> rigidUnify sp ref u rlvl rk t
    Unbound _ lvl k -> do
      tk <- kindOf t
      when (k /= tk) $ do
        ca <- freeze (TVar ref)
        cb <- freeze t
        throwError (KindMismatch sp ca cb)
      occursAdjust sp ref lvl t
      liftST $ writeSTRef ref (Link t)

-- | A rigid skolem only unifies with itself (same STRef) or with an Unbound
-- inference variable (which gets pinned to the rigid) -- and then only when that
-- metavar is SAME-KIND and lives at the skolem's level or DEEPER. Any other
-- combination raises 'RigidEscape', because it means the body is less general
-- than the declared signature.
--
-- The level guard is the crux of the fix for the @finalizeGroupTyped: unexpected
-- escape@ panic: a metavar from a SHALLOWER (outer, older) scope than the skolem,
-- once linked to it, would carry the rigid out into that enclosing scope where it
-- is not in scope (e.g. a local @helper : a -> a@ whose body forces @a@ to equal
-- an outer parameter). Reject it here as a positioned 'RigidEscape' rather than
-- letting it surface later as an internal panic. This mirrors the level
-- discipline 'occursAdjust' applies to ordinary unbound variables.
rigidUnify :: SourceSpan -> STRef s (TVar s) -> Int -> Level -> Kind -> Type s -> TC s ()
rigidUnify sp ref u (Level rlvl) rk t = case t of
  TVar r' | r' == ref -> pure ()
  TVar r' -> do
    tv' <- liftST $ readSTRef r'
    case tv' of
      Link _ -> error "rigidUnify: t must have been forced"
      Unbound _ (Level mlvl) mk -> do
        -- A row (KEffect) metavar must never pin to a type (KStar) skolem or
        -- vice versa; skolems are KStar-only today, but guard both ways.
        when (mk /= rk) $ do
          ca <- freezeTolerant (TVar ref)
          cb <- freezeTolerant t
          throwError (KindMismatch sp ca cb)
        -- Outer-scope metavar pinned to a deeper skolem => the skolem escapes.
        when (mlvl < rlvl) $ throwError (RigidEscape sp u)
        -- Pin the Unbound side to the Rigid (flip direction).
        liftST $ writeSTRef r' (Link (TVar ref))
      Rigid _ _ _ ->
        -- Two distinct rigids can't unify.
        throwError (RigidEscape sp u)
  _ -> throwError (RigidEscape sp u)

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
-- encountered. Stops at RowEmpty or an open tail (row variable).
collectRowPairs :: Row s -> TC s [(Text, Type s)]
collectRowPairs row = do
  row' <- force row
  case row' of
    RowEmpty           -> pure []
    RowExtend l t rest -> do
      rest' <- collectRowPairs rest
      pure ((l, t) : rest')
    _                  -> pure []  -- open tail (row variable) or non-row
