-- | Type inference for the wok HM core. This module starts by exporting
-- the freeze-and-quantify @generalize@ pass and its dual @instantiate@.
-- Later tasks build out the full inferrer on top of these.
module Wok.TypeChecking.Infer
  ( generalize
  , generalizeTyped
  , instantiate
  , translateSig
  , processDataDecls
  , processEffectDecls
  , processForeignDecls
  , inferPat
  , inferExpr
  , inferExprW
  , inferProgram
  , inferProgramWith
  , modPathText
  , modPathPos
  , TypedDecl (..)
  , prettyScheme
  , prettyCType
  ) where

import qualified Control.Monad.ST
import Control.Monad (foldM, forM, forM_, msum, unless, when)
import Control.Monad.Except (catchError, throwError)
import Data.Maybe (catMaybes, fromMaybe, isNothing, listToMaybe, mapMaybe)
import Data.List (foldl', nub)
import qualified Data.List
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import Data.STRef (STRef, modifySTRef', newSTRef, readSTRef, writeSTRef)
import qualified Data.Text as Tx
import Data.Text (Text)
import qualified GeneratedParser.Wok.Abs as Abs
import GeneratedParser.Wok.Abs (BNFC'Position)
import Wok.SourceOrigin (Origin (..))
import qualified Wok.TypeChecking.Builtins as Builtins
import Wok.TypeChecking.Env
  ( ConInfo (..), Env, EffectInfo (..), ForeignMemberInfo (..)
  , ForeignModuleInfo (..), RecordConInfo (..), TyConInfo (..)
  , envTyCons
  , extendCon, extendEffect, extendForeignModule
  , extendRecordCon, extendTyCon, extendVar
  , lookupCon, lookupEffect, lookupForeignModule
  , lookupQualifier
  , lookupRecordCon, lookupTyCon, lookupVar )
import qualified Wok.FFI.Blessed as Blessed
import Wok.TypeChecking.Error (SourceSpan, TypeError (..), Warning (..))
import Wok.TypeChecking.Monad (TC, ConstraintS (..), addConstraint, addWarning, currentEffRow, currentEnv, currentLevel, enterLevel, extendVarTC, freshRVar, freshTVar, freshUniq, liftST, runTC, takeConstraints, withEffRow, withEnv)
import Wok.TypeChecking.Unify (force, freeze, freezeTolerant, rewriteRow, unify, unifyRow, rewriteRowStrict)
import Wok.TypeChecking.Types
  ( CRow, CType (..), Constraint (..), Kind (..), Level (..), Row
  , Scheme (..), mkScheme, TyCon (..), TVar (..), Type (..) )
import Wok.TypeChecking.Typed (TExprS, TExpr, TPatS, TPat)
import qualified Wok.TypeChecking.Typed as Ty
import Wok.TypeChecking.Carrier
  (CarrierTys (..), AffineCarrierTys (..), checkCarriers, checkFutureAffine)
import Wok.IR.Match
  ( ConOracle (..), Coverage (..), MPat (..), MPatF (..)
  , matchCoverage, tupleTag )
import qualified Wok.IR.Match as Match
import Wok.IR.Anf (Lit (..))
import Wok.IR.Name (JoinId (..), Unique (..))
import qualified Wok.TypeChecking.Class as Class
import qualified Wok.TypeChecking.Solve as Solve

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
    body <- freezeQuantify outer nextRef seenRef kindsRef t
    pairs <- readSTRef kindsRef
    pure (mkScheme (reverse pairs) body)

-- | Like 'generalize', but additionally freezes a whole typed-AST tree
-- with the SAME quantification mapping that produces the scheme. Using one
-- shared ref-set means a polymorphic binding's per-node annotations reuse
-- the scheme's 'CTGen' numbering. Quantifiers found only inside node
-- annotations still register in the scheme because 'kindsRef' is read LAST.
generalizeTyped :: Type s -> TExprS s -> [ConstraintS s] -> TC s (Scheme, TExpr, [Constraint])
generalizeTyped t tree cs = do
  Level outer <- currentLevel
  liftST $ do
    nextRef  <- newSTRef 0
    seenRef  <- newSTRef (Map.empty :: Map.Map Int Int)
    kindsRef <- newSTRef ([] :: [(Int, Kind)])
    -- The principal type is frozen STRICTLY: a skolem in the scheme body is a
    -- real bug. Node annotations are frozen TOLERANTLY: a typed body may carry
    -- skolems from inner signed (where-)bindings, which are valid node-level
    -- slots but must not become quantifiers of THIS binding's scheme.
    -- The scheme is determined SOLELY by the principal type: goBody records
    -- quantifiers, goNode does NOT (it only interns vars to shared CTGen indices
    -- so node annotations stay consistent with the scheme's numbering for shared
    -- vars and get fresh, non-recorded CTGens for node-only vars).
    let goBody = freezeQuantify              outer nextRef seenRef kindsRef
        goNode = freezeQuantifyG  True False outer nextRef seenRef kindsRef
    body  <- goBody t                    -- principal type first (strict, records)
    tree' <- traverse goNode tree        -- then every node annotation (no record)
    -- Freeze each accumulated constraint's argument with the NON-RECORDING
    -- walker (goNode), sharing the same refs. A residual constraint whose arg is
    -- a quantified var already recorded by goBody reuses that same CTGen (so it
    -- lands in the scheme's quantifier set). A constraint whose arg is a var that
    -- does NOT appear in the principal type gets a fresh CTGen that is NOT
    -- recorded -- so it is absent from schemeVars and the discharge step flags it
    -- as ambiguous. A concrete arg freezes to its CType. Using goNode (not
    -- goBody) is essential: goBody would RECORD a constraint-only var as a
    -- spurious quantifier, masking the ambiguity.
    fcs <- mapM (\(ConstraintS cls arg) -> Constraint cls <$> goNode arg) cs
    pairs <- readSTRef kindsRef          -- read quantifiers (from goBody only)
    pure (mkScheme (reverse pairs) body, tree', fcs)

-- Internal: walk a Type s, replacing unbound vars at level > outer with
-- CTGens, sharing slots by uniq via 'seen'. Pure-ST so we don't pay
-- TC monad overhead per node.
--
-- This is the STRICT walker used to build a stored scheme: a 'Rigid' skolem is
-- a hard error (skolems must never leak into a scheme). Freezing typed-AST
-- trees -- which may legitimately carry skolems from inner signed bindings --
-- goes through a tolerant, non-recording 'freezeQuantifyG' instead.
freezeQuantify
  :: Int                              -- ^ outer level
  -> STRef s Int                      -- ^ next CTGen index
  -> STRef s (Map.Map Int Int)        -- ^ uniq -> CTGen index
  -> STRef s [(Int, Kind)]            -- ^ accumulator (reversed)
  -> Type s
  -> Control.Monad.ST.ST s CType
freezeQuantify = freezeQuantifyG False True

-- Like 'freezeQuantify' but parameterised on whether 'Rigid' skolems are
-- tolerated and whether generalizable unbound vars are RECORDED as scheme
-- quantifiers. With @tolerateRigid = True@ a skolem is interned to a fresh CTGen
-- (shared by uniq via 'seen') WITHOUT being recorded in the kind accumulator,
-- so it never becomes a scheme quantifier -- it is just a node-annotation slot
-- standing for some inner binding's polymorphic variable. With
-- @recordQuant = False@ a generalizable unbound var (level > outer) is likewise
-- interned to a shared CTGen but NOT recorded, so node-only polymorphic vars do
-- not leak into the scheme; vars already seen in the principal type still reuse
-- their recorded index. The strict scheme path ('freezeQuantify') passes
-- @False@/@True@ and keeps erroring on skolems while recording quantifiers.
freezeQuantifyG
  :: Bool                             -- ^ tolerate Rigid skolems?
  -> Bool                             -- ^ record generalizable vars as quantifiers?
  -> Int                              -- ^ outer level
  -> STRef s Int                      -- ^ next CTGen index
  -> STRef s (Map.Map Int Int)        -- ^ uniq -> CTGen index
  -> STRef s [(Int, Kind)]            -- ^ accumulator (reversed)
  -> Type s
  -> Control.Monad.ST.ST s CType
freezeQuantifyG tolerateRigid recordQuant outer nextRef seenRef kindsRef = goT
  where
    -- Intern a uniq to a shared CTGen index; record its kind only when asked
    -- (scheme quantifiers are recorded, tolerated skolems are not).
    intern u mKind = do
      seen <- readSTRef seenRef
      case Map.lookup u seen of
        Just idx -> pure (CTGen idx)
        Nothing -> do
          idx <- readSTRef nextRef
          writeSTRef nextRef (idx + 1)
          writeSTRef seenRef (Map.insert u idx seen)
          case mKind of
            Just k -> do
              prior <- readSTRef kindsRef
              writeSTRef kindsRef ((idx, k) : prior)
            Nothing -> pure ()
          pure (CTGen idx)
    goT ty = do
      ty' <- forceST ty
      case ty' of
        TCon c ts -> CTCon c <$> mapM goT ts
        TArr a r b -> CTArr <$> goT a <*> goT r <*> goT b
        TRecord tag row -> CTRecord tag <$> goT row
        RowEmpty -> pure CREmpty
        RowExtend l ty2 rest -> CRExtend l <$> goT ty2 <*> goT rest
        TVar ref -> do
          tv <- readSTRef ref
          case tv of
            Link _ -> error "freezeQuantify: TVar was Link after forceST (caller invariant violation)"
            -- A GENERALIZABLE row variable (KEffect, level > outer) is interned
            -- and -- on the scheme-body path ('recordQuant') -- RECORDED as a
            -- KEffect quantifier, exactly like a generalizable type var. Freezing
            -- it to its RAW global uniq instead (the old goR shortcut) left it out
            -- of the scheme's quantifier list, so a later (cross-module)
            -- instantiation panicked `dangling CTGen u`, and the raw uniq could
            -- collide with a small KStar quantifier index -- silently confusing
            -- kinds (bug #5). 'instantiateQ' already allocates a fresh row var for
            -- each recorded KEffect quantifier, so recording closes the hole.
            --
            -- A NON-generalizable row var (level <= outer) only ever reaches here
            -- on the tolerant NODE-annotation path (the scheme-body path is gated
            -- by 'hasOuterScopeVar', which walks rows): the ambient/residual row
            -- pinned by an enclosing scope. It freezes to its uniq for the node
            -- annotation as before -- harmless, because node CTypes are never
            -- instantiated as schemes.
            Unbound u (Level l) KEffect
              | l > outer -> intern u (if recordQuant then Just KEffect else Nothing)
              | otherwise -> pure (CTGen u)
            Rigid u _ _
              | tolerateRigid -> intern u Nothing
              | otherwise -> error
                  ("freezeQuantify: unexpected Rigid (uniq " ++ show u
                  ++ "); skolems should never leak into stored schemes")
            Unbound u (Level l) k
              | l > outer -> intern u (if recordQuant then Just k else Nothing)
              | otherwise -> error
                  ("freezeQuantify: unexpected level-" ++ show l
                  ++ " var (uniq " ++ show u
                  ++ "); finalizeGroup should have routed this as a mono binding")

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

-- | Freeze a typed-AST tree for a SIGNED binding. Unlike 'generalizeTyped',
-- this produces no scheme (the binding's scheme is its DECLARED signature) and
-- it tolerates 'Rigid' skolems: a signed body is checked against a skolemised
-- instantiation of its sig ('freezeSig'), so its node annotations reference the
-- skolems standing for the sig's quantified variables. Each distinct skolem
-- uniq -- and any genuinely-polymorphic unbound var at level > outer -- maps to
-- a fresh 'CTGen', shared across the whole tree so params and body agree. The
-- resulting numbering is self-consistent within the tree; it need not match the
-- declared scheme's quantifier indices (callers keep the declared scheme).
-- It also freezes any accumulated constraints under the SAME tolerant refs so
-- their CTGen numbering agrees with the node annotations (used only to VALIDATE
-- dischargeability against the declared context, not to build the scheme).
freezeTypedTreeSig :: TExprS s -> [ConstraintS s] -> TC s (TExpr, [Constraint])
freezeTypedTreeSig tree cs = do
  Level outer <- currentLevel
  liftST $ do
    nextRef  <- newSTRef 0
    seenRef  <- newSTRef (Map.empty :: Map.Map Int Int)
    kindsRef <- newSTRef ([] :: [(Int, Kind)])   -- discarded: no scheme built
    let goNode = freezeQuantifyG True False outer nextRef seenRef kindsRef
    tree' <- traverse goNode tree
    fcs   <- mapM (\(ConstraintS cls arg) -> Constraint cls <$> goNode arg) cs
    pure (tree', fcs)

-- | Instantiate a scheme: each quantifier becomes a fresh TVar (KStar) or
-- fresh RowVar (KEffect) at the current level; the body is rebuilt with
-- those fresh refs substituted. Defined in terms of 'instantiateQ' so that
-- every existing caller is unchanged (it just drops the constraints).
instantiate :: Scheme -> TC s (Type s)
instantiate s = fst <$> instantiateQ s

-- | Like 'instantiate', but also returns the scheme's constraint arguments
-- instantiated through the SAME fresh substitution: each @Constraint cls arg@
-- becomes @(cls, arg')@ where @arg'@ is @arg@ with the scheme's CTGen slots
-- replaced by the same fresh vars used for the body. Use-sites feed these back
-- into the constraint accumulator and into the 'TQVar' typed node.
instantiateQ :: Scheme -> TC s (Type s, [(Text, Type s)])
instantiateQ (Scheme vars constraints body) = do
  tySubst  <- Map.fromList <$>
    mapM (\(i, k) -> do { t <- freshTVar k; pure (i, t) })
         [ (i, k) | (i, k) <- vars, k /= KEffect ]
  rowSubst <- Map.fromList <$>
    mapM (\(i, _) -> do { r <- freshRVar; pure (i, r) })
         [ (i, k) | (i, k) <- vars, k == KEffect ]
  let body' = substInCType tySubst rowSubst body
      cs'   = [ (conClass c, substInCType tySubst rowSubst (conArg c))
              | c <- constraints ]
  pure (body', cs')
  where
    -- One walk over the folded CType. Row nodes (CREmpty/CRExtend) and the
    -- type nodes share the case split; a gen index is looked up in the type
    -- subst first, then the row subst (the two index sets are disjoint).
    substInCType :: Map.Map Int (Type s) -> Map.Map Int (Row s) -> CType -> Type s
    substInCType m rm = goT
      where
        goT (CTCon c ts) = TCon c (map goT ts)
        goT (CTArr a r b) = TArr (goT a) (goT r) (goT b)
        goT (CTRecord tag row) = TRecord tag (goT row)
        goT CREmpty = RowEmpty
        goT (CRExtend l ty rest) = RowExtend l (goT ty) (goT rest)
        goT (CTGen i) = case Map.lookup i m of
          Just t -> t
          Nothing -> case Map.lookup i rm of
            Just r -> r
            Nothing -> error ("instantiate: dangling CTGen " ++ show i)

-- | Allocate a fresh TVar (or RowVar for KEffect) for each param slot in
-- @rcParams@. Returns a map from CTGen index to fresh Type.
instantiateParamSubst :: [(Int, Kind)] -> TC s (Map.Map Int (Type s))
instantiateParamSubst params = do
  pairs <- forM params $ \(i, k) -> do
    t <- freshTVar k
    pure (i, t)
  pure (Map.fromList pairs)

-- | The type an effect's row label carries for a given parameter
-- instantiation: @()@ for a zero-param effect, the single param's type, or a
-- tuple of them. The SINGLE source of truth for this shape: the perform site
-- (the @E.op@ arm of 'inferExprW') and the handler-value install site
-- ('inferHandleValue') must build it identically, or install-site payload
-- tying would silently never unify.
effectPayloadTy :: [(Int, Kind)] -> Map.Map Int (Type s) -> Type s
effectPayloadTy ps subst = case ps of
  []       -> TCon TcUnit []
  [(i, _)] -> Map.findWithDefault (TCon TcUnit []) i subst
  _        -> TCon (TcTuple (length ps))
                [ Map.findWithDefault (TCon TcUnit []) i subst | (i, _) <- ps ]

-- | Substitute CTGen slots in a CType using the given index->Type map.
-- Used when instantiating field types of a record constructor whose
-- declaration carries type parameters.
substCTypeWith :: Map.Map Int (Type s) -> CType -> Type s
substCTypeWith m = goT
  where
    goT (CTCon c ts)       = TCon c (map goT ts)
    goT (CTArr a r b)      = TArr (goT a) (goT r) (goT b)
    goT (CTRecord tag row) = TRecord tag (goT row)
    goT CREmpty            = RowEmpty
    goT (CRExtend l t rst) = RowExtend l (goT t) (goT rst)
    goT (CTGen i)          = case Map.lookup i m of
      Just t  -> t
      -- Not-in-subst fallback. Pre-merge this was two arms:
      --   * a row-kinded gen (former CRGen) -> RowEmpty, because row
      --     params are not supported in this record-field context (v1);
      --   * a type-kinded gen -> error "substCTypeWith: dangling CTGen",
      --     an internal invariant violation.
      -- The kinded-Ty merge collapsed CRGen/CTGen into a single CTGen, so
      -- the two cases are no longer distinguishable here without threading
      -- param kinds through every caller. We keep the RowEmpty fallback: it
      -- is correct for the row-param case, and a dangling *type* gen is
      -- unreachable for valid programs (callers build paramSubst from the
      -- complete rcParams / scheme quantifier list, so every type-kinded
      -- gen is present in the map).
      Nothing -> RowEmpty

-- | Replace each forall-bound type variable in a user's signature with
-- a fresh Rigid type — one the unifier treats as an opaque constant.
-- Catches signatures that over-promise: in
--
--     double : a -> a
--     double n = n + n
--
-- the body forces a = u64 (because (+) is u64 -> u64 -> u64), so the
-- body's inferred type is u64 -> u64. Without freezing, unifying
-- (a -> a) with (u64 -> u64) silently weakens the sig to (u64 -> u64).
-- With freezing, the sig becomes (rigid_1 -> rigid_1); unification
-- with (u64 -> u64) fails, and the over-promise surfaces as a type
-- error rather than disappearing.
--
-- Row variables (KEffect slots, CTGen) become fresh RowVars rather than
-- being dropped as RowEmpty. This ensures two uses of the same row variable
-- in a sig (e.g. `Point + row r -> Point + row r`) share the same RowVar.
--
-- Also returns the mapping from each declared scheme variable index to the
-- @uniq@ of the 'Rigid' skolem minted for it. The signed
-- path needs this to entail a body's accumulated class constraints BY ARGUMENT
-- (not merely by class name): a declared @Eq a@ promises a dictionary for the
-- skolem standing for @a@, so a body constraint on a DIFFERENT skolem (or an
-- unbound metavar) is under-entailed and must be rejected. Type (KStar) vars
-- only; row (KEffect) vars do not carry class constraints.

-- | The terminal row var of an effect-row slot, if any. Shared by BOTH
-- classifiers below -- 'freezeSigSkolems' rigidifies a var iff it is
-- effect-relevant AND not dischargeable, so the two must agree on what a
-- row's tail is; one definition keeps them from drifting.
effTailVar :: CType -> Set.Set Int
effTailVar (CRExtend _ _ r) = effTailVar r
effTailVar (CTGen i)        = Set.singleton i
effTailVar _                = Set.empty

-- | The KEffect quantifier indices that appear as an arrow's effect-row tail in a
-- POSITIVE (result-side) position of a signature -- i.e. the function has its OWN
-- declared channel to perform them (`... -> R with eff e`, including returned
-- functions). A var NOT in this set is "trapped": it occurs in the signature (e.g.
-- inside a `Suspension a b r (row e)` argument, or as a `with eff e` on a
-- PARAMETER arrow -- which is the CALLER's promise, not this function's channel)
-- but the function itself never declares it can perform it, so performing it is a
-- leak. Polarity flips at each arrow domain. Used by 'freezeSigSkolems' to
-- rigidify only trapped effect-row vars.
dischargeableRowVars :: CType -> Set.Set Int
dischargeableRowVars = pos
  where
    -- Positive position: an arrow's effect-row tail here IS a discharge channel.
    pos (CTArr a eff b)  = Set.unions [effTailVar eff, neg a, pos b]
    pos (CTCon _ ts)     = Set.unions (map pos ts)
    pos (CTRecord _ row) = pos row
    pos (CRExtend _ p r) = Set.union (pos p) (pos r)
    pos CREmpty          = Set.empty
    pos (CTGen _)        = Set.empty
    -- Negative position (a parameter): an arrow's effect-row tail here is the
    -- caller's obligation, NOT a channel -- do not collect it. The domain flips
    -- back to positive; the codomain stays negative.
    neg (CTArr a _ b)    = Set.union (pos a) (neg b)
    neg (CTCon _ ts)     = Set.unions (map neg ts)
    neg (CTRecord _ row) = neg row
    neg (CRExtend _ p r) = Set.union (neg p) (neg r)
    neg CREmpty          = Set.empty
    neg (CTGen _)        = Set.empty

-- | The KEffect quantifier indices that are genuinely EFFECT-relevant: a var
-- appearing as an arrow effect-row tail (EITHER polarity) or as a row-arg of a
-- CARRIER type constructor (Suspension/Step/ContCell/... -- identified by the
-- 'tcCarrier' env marker, NOT a name string). After the kinded-Ty merge, record
-- rows and DATA row params are ALSO KEffect, so a var occurring only as a record
-- row tail (@Point + row r@) or as a row param of a NON-carrier user data type
-- (@Box (row e)@) is ordinary row-polymorphism, NOT an effect, and must NEVER be
-- rigidified. 'freezeSigSkolems' rigidifies a var iff it is effect-relevant AND
-- not dischargeable ('dischargeableRowVars') -- so record/data row polymorphism
-- is untouched while a genuine trapped effect residual is caught.
effectRelevantRowVars :: (Text -> Bool) -> CType -> Set.Set Int
effectRelevantRowVars isCarrier = go
  where
    go (CTArr a eff b)  = Set.unions [effTailVar eff, go a, go eff, go b]
    go (CTCon tc ts)    = Set.union (Set.unions (map go ts)) (carrierArgs tc ts)
    go (CTRecord _ row) = go row
    go (CRExtend _ p r) = Set.union (go p) (go r)
    go CREmpty          = Set.empty
    go (CTGen _)        = Set.empty
    -- A carrier tycon's row-args ARE effect residuals; a non-carrier's are not.
    carrierArgs (TcUser n) ts | isCarrier n = Set.unions (map effTailVar ts)
    carrierArgs _          _                = Set.empty

-- | The third component is the set of 'Rigid' skolem uniqs minted for
-- TRAPPED KEffect (row) variables -- i.e. those that occur in the signature
-- but have no dischargeable arrow effect-row channel (see
-- 'dischargeableRowVars'). A 'RigidEscape' whose uniq is in this set is a
-- laundering leak (the body performs an effect the sig never declared),
-- remapped to 'UndischargedEffect' at the two reconciliation call sites.
freezeSigSkolems :: Scheme -> TC s (Type s, Map.Map Int Int, Set.Set Int)
freezeSigSkolems (Scheme vars _ body) = do
  -- Mint each skolem at the CURRENT level: it stands for a variable universally
  -- quantified by this signature, introduced at the scope where the signature is
  -- frozen. A metavar from a SHALLOWER (outer) scope must not be pinned to it
  -- (that would let the rigid escape its binding's scope) -- 'rigidUnify'
  -- enforces this by comparing the metavar's level against this recorded level.
  lvl <- currentLevel
  skolems <- mapM (\(i, k) -> do
                     u <- freshUniq
                     ref <- liftST $ newSTRef (Rigid u lvl k)
                     pure (i, (u, TVar ref))
                  ) [ (i, k) | (i, k) <- vars, k /= KEffect ]
  -- Rigid-residual skolemization (2026-07-03): mint a KEffect
  -- (effect-row) signature var as a RIGID skolem ONLY when it is TRAPPED -- it
  -- occurs in the signature but never as a dischargeable arrow effect-row tail
  -- (`with eff e`), so the function has no declared channel to perform it. A
  -- trapped var performed by the body launders to `{}`; the rigid declared skolem
  -- then clashes with `{}` at reconciliation (`RigidEscape`) = the leak.
  -- Dischargeable (open-tail) vars stay flexible so open-sig runners
  -- (reader/state/run/start ...) are unaffected. Record/data row polymorphism is
  -- untouched: a var is rigidified only when it is EFFECT-RELEVANT (an arrow
  -- eff-slot tail or a carrier row-arg) AND not dischargeable, so a record tail
  -- (`Point + row r`) or a non-carrier data row param (`Box (row e)`) stays
  -- flexible ('effectRelevantRowVars').
  env <- currentEnv
  let isCarrier n = maybe False tcCarrier (lookupTyCon n env)
      discharg    = dischargeableRowVars body
      effRel      = effectRelevantRowVars isCarrier body
  rowVars <- mapM (\(i, _) -> do
                     if Set.member i effRel && not (Set.member i discharg)
                       then do
                         u   <- freshUniq
                         ref <- liftST $ newSTRef (Rigid u lvl KEffect)
                         pure (i, TVar ref, Just u)
                       else do
                         r <- freshRVar
                         pure (i, r, Nothing)
                  ) [ (i, k) | (i, k) <- vars, k == KEffect ]
  let tySubst      = Map.fromList [ (i, t) | (i, (_, t)) <- skolems ]
      rowSubst     = Map.fromList [ (i, t) | (i, t, _) <- rowVars ]
      uniqOfVar    = Map.fromList [ (i, u) | (i, (u, _)) <- skolems ]
      trappedUniqs = Set.fromList [ u | (_, _, Just u) <- rowVars ]
  pure (substInCType tySubst rowSubst body, uniqOfVar, trappedUniqs)
  where
    -- One walk over the folded CType. A gen index is a type skolem (looked up
    -- in m) or a row var (looked up in rm); a row index missing from rm maps to
    -- RowEmpty (preserving the old goR fallback).
    substInCType :: Map.Map Int (Type s) -> Map.Map Int (Row s) -> CType -> Type s
    substInCType m rm = goT
      where
        goT (CTCon c ts) = TCon c (map goT ts)
        goT (CTArr a r b) = TArr (goT a) (goT r) (goT b)
        goT (CTRecord tag row) = TRecord tag (goT row)
        goT CREmpty = RowEmpty
        goT (CRExtend l ty rest) = RowExtend l (goT ty) (goT rest)
        -- A type gen resolves in the skolem map `m`; a row gen in the row-var
        -- map `rm`. The merge kept both maps, so we preserve the pre-merge
        -- safety net: a gen in NEITHER is a genuine dangling-CTGen invariant
        -- violation (unreachable for valid schemes — every body gen comes from
        -- the quantifier list these maps are built from).
        goT (CTGen i) = case Map.lookup i m of
          Just t -> t
          Nothing -> case Map.lookup i rm of
            Just r  -> r
            Nothing -> error ("freezeSig: dangling CTGen " ++ show i)

-- | Translate a parsed Abs.Type into a Scheme. Free VarIds in the
-- type become universally quantified CTGen slots (in first-occurrence
-- order). Row variables (introduced via @row r@ in RowContrib) become
-- universally quantified CTGen slots with KEffect kind. Validates tycon
-- arity. Built-in tycon names (U64, Char, String, Bool, Unit, list) map
-- to specialised TyCon tags; user names become TcUser.
-- Record-form TyCons (registered in envRecordCons with matching name)
-- produce CTRecord with the closed row of declared fields.
-- | An anonymous @..@ row tail (effect 'Abs.ERWildOnly' or record 'Abs.RCWild')
-- is a fresh, single-use variable, so it cannot thread between positions. It is
-- therefore allowed only in COVARIANT (result) positions of a signature, and
-- rejected in CONTRAVARIANT (parameter) positions, where a consumed callback's
-- effects (or a consumed record's extra fields) could only be dropped. Named
-- tails (@eff e@ / @row r@) thread and are allowed in any position. Polarity
-- flips on the domain of each arrow. This is the spec's "@..@ cannot thread"
-- rule (e.g. @mapEff : (a -> b with ..) -> [a] -> [b] with ..@ is rejected),
-- enforced structurally on the signature.
-- The error is anchored at @sp@ (the enclosing signature's name position): the
-- @..@ token itself is nullary in the AST and carries no position.
checkAnonTailPolarity :: BNFC'Position -> Abs.Type -> TC s ()
checkAnonTailPolarity sp = goT True
  where
    -- @pos@ True = covariant (.. allowed); False = contravariant (.. rejected).
    goT :: Bool -> Abs.Type -> TC s ()
    goT pos t = case t of
      -- Qualified type `(C a) => T` (Eq slice, Task 0): parse-only. The
      -- constraint context carries no anonymous-row tails, so just descend
      -- into the qualified body. Real constraint handling lands in a later task.
      Abs.TQual _ body      -> goT pos body
      Abs.TFun a b         -> goT (not pos) a >> goT pos b
      Abs.TWith a b eff     -> goT (not pos) a >> goT pos b >> goRow pos eff
      Abs.TExtend lhs _ rc  -> goT pos lhs >> goRC pos rc
      Abs.TApp f x          -> goT pos f >> goT pos x
      Abs.TList inner       -> goT pos inner
      Abs.TTuple a others   -> mapM_ (goT pos) (a : others)
      Abs.TParen t'         -> goT pos t'
      Abs.TCon _            -> pure ()
      Abs.TVar _            -> pure ()
      Abs.TRowArg _         -> pure ()   -- row var arg: leaf, no anon `..` tail
      Abs.TOwned t'         -> goT pos t'
      Abs.TUnit             -> pure ()

    goRow :: Bool -> Abs.EffectRow -> TC s ()
    goRow pos r = case r of
      Abs.EROne atom         -> goAtom pos atom
      Abs.ERPlus atom _ rest -> goAtom pos atom >> goRow pos rest
      Abs.ERVarOnly _        -> pure ()                  -- named eff var: threads
      Abs.ERWildOnly         -> unless pos $ throwError (AnonRowTailInParam sp)

    goAtom :: Bool -> Abs.EffectAtom -> TC s ()
    goAtom pos (Abs.ERAtom _ typeArgs) = mapM_ (goT pos) typeArgs

    goRC :: Bool -> Abs.RowContrib -> TC s ()
    goRC pos rc = case rc of
      Abs.RCAnon fields -> mapM_ (\(Abs.RFType _ fty) -> goT pos fty) fields
      Abs.RCVar _       -> pure ()                       -- named row var: threads
      Abs.RCWild        -> unless pos $ throwError (AnonRowTailInParam sp)

-- | Reinterpret the LHS of a qualified type `(...) => T` -- which the grammar
-- encodes AS a 'Abs.Type' -- into a list of (class name, argument type) pairs.
-- A single constraint parses as `TParen (TApp (TCon C) arg)`; several parse as
-- `TTuple c1 [c2, ...]` of such applications (no enclosing paren). Each element
-- must be a saturated single-argument class application `TApp (TCon C) arg`;
-- any other shape is malformed and rejected. The argument type is returned raw
-- so the caller can translate it through the shared slot map.
-- | Split a constraint context (the LHS of @=>@) into its individual class
-- applications. A well-formed element is @Right (class, arg)@; a malformed one
-- (not of the shape @C arg@) is @Left t@, which 'translateSig' surfaces as an
-- error rather than silently dropping (dropping would let an ill-formed context
-- typecheck as if unconstrained).
constraintsOfType :: Abs.Type -> [Either Abs.Type (Text, Abs.Type)]
constraintsOfType = goCtx
  where
    goCtx (Abs.TParen t)        = goCtx t
    goCtx (Abs.TTuple a others) = concatMap one (a : others)
    goCtx t                     = one t

    one t = case classApp t of
      Just pair -> [Right pair]
      Nothing   -> [Left t]

    -- A single-parameter class application `C arg`.
    classApp (Abs.TParen t)             = classApp t
    classApp (Abs.TApp (Abs.TCon mp) a) = Just (modPathText mp, a)
    classApp _                          = Nothing

translateSig :: Env -> Abs.Type -> TC s Scheme
translateSig env ty = do
  seenRef    <- liftST $ newSTRef (Map.empty :: Map.Map Text Int)
  nextRef    <- liftST $ newSTRef (0 :: Int)
  rowSeenRef <- liftST $ newSTRef (Map.empty :: Map.Map Text Int)
  -- A qualified type `(C a, ...) => T` is split into its constraint context
  -- (the LHS, encoded by the grammar AS a type: `TParen`/`TTuple` of
  -- `TApp (TCon Class) arg`) and the body T. The body is translated FIRST so
  -- that each type variable's CTGen slot is allocated by first occurrence in
  -- the body; each constraint argument is then translated through the SAME
  -- `walk` (sharing `seenRef`/`nextRef`) so e.g. `a` in `(Eq a)` reuses the
  -- body's slot. A non-qualified sig carries no constraints (empty context).
  let (ctxElems, bodyTy) = case ty of
        Abs.TQual lhs b -> (constraintsOfType lhs, b)
        _               -> ([], ty)
  -- A malformed context element (not of the shape `C arg`) is rejected here
  -- rather than dropped, so an ill-formed context cannot masquerade as the
  -- empty (unconstrained) one.
  ctxTys <- forM ctxElems $ \case
    Right pair -> pure pair
    Left _     -> throwError (UnknownClass (Tx.pack "<malformed constraint context>"))
  body <- walk env seenRef nextRef rowSeenRef bodyTy
  constraints <- forM ctxTys $ \(cls, argTy) -> do
    argCT <- walk env seenRef nextRef rowSeenRef argTy
    pure (Constraint cls argCT)
  slots    <- liftST $ readSTRef seenRef
  rowSlots <- liftST $ readSTRef rowSeenRef
  -- Type vars use KStar, row vars use KEffect.
  let tyPairs  = Data.List.sortBy (\a b -> compare (snd a) (snd b)) (Map.toList slots)
      rowPairs = Data.List.sortBy (\a b -> compare (snd a) (snd b)) (Map.toList rowSlots)
      qs = map (\(_, i) -> (i, KStar)) tyPairs
        ++ map (\(_, i) -> (i, KEffect)) rowPairs
  pure (Scheme qs constraints body)
  where
    walk :: Env
         -> STRef s (Map.Map Text Int)
         -> STRef s Int
         -> STRef s (Map.Map Text Int)
         -> Abs.Type
         -> TC s CType
    walk env' seenRef nextRef rowSeenRef = goT
      where
        -- Allocate a fresh slot index in the shared nextRef counter,
        -- inserting the name into the given seen map.
        allocSlot ref name = liftST $ do
          n <- readSTRef nextRef
          writeSTRef nextRef (n + 1)
          modifySTRef' ref (Map.insert name n)
          pure n

        -- Top-level qualified types `(C a) => T` are peeled by 'translateSig'
        -- before 'walk' runs; reaching this arm means a constraint context
        -- appeared in a nested (non-prenex) position, which is unsupported.
        goT (Abs.TQual _ _) =
          throwError (UnsupportedFeature Nothing
            (Tx.pack "nested qualified type (constraint context) not supported"))
        -- `owned Type2` (FFI Slice 4) is boundary METADATA on a `Bytes`
        -- PARAMETER of a `foreign module` member, not part of the checked
        -- type: the transfer-full marker is captured separately, per
        -- parameter, by 'Wok.TypeChecking.Infer.registerMember's
        -- `classifyOwnedParams` walk over the surface `Abs.Type` (into
        -- 'Wok.FFI.Blessed.ArgTransfer' / 'Wok.TypeChecking.Env.fmiArgTransfer'),
        -- which STRIPS `owned` from valid parameter-head positions before the
        -- resulting type ever reaches this `walk`. So any `TOwned` this arm
        -- still sees is misplaced: either ordinary (non-foreign) code, where
        -- `owned` is never boundary metadata at all, or a foreign member's
        -- return type / a nested position (`Array (owned Bytes)`), neither of
        -- which `classifyOwnedParams` strips. Reject rather than silently
        -- discard -- silently discarding is exactly the bug this guards
        -- against (see 'ForeignOwnedArgNotBytes' & co. for the sibling
        -- parameter-position coherence checks).
        goT (Abs.TOwned _) =
          throwError (OwnedModifierMisplaced Nothing
            (Tx.pack "`owned` is only allowed on a `Bytes` parameter of a \
                     \foreign-module member"))
        goT (Abs.TFun a b) = CTArr <$> goT a <*> pure CREmpty <*> goT b
        goT (Abs.TVar (Abs.VarId (_, name))) = do
          seen <- liftST (readSTRef seenRef)
          case Map.lookup name seen of
            Just i  -> pure (CTGen i)
            Nothing -> CTGen <$> allocSlot seenRef name
        goT (Abs.TCon modPath) = do
          let name = modPathText modPath
              pos  = modPathPos modPath
          -- Check record-form first: if this TyCon name is also registered
          -- as a record constructor (data Foo = Foo { ... }), produce
          -- CTRecord with the closed row of declared fields.
          case lookupRecordCon name env' of
            Just rcInfo
              | rcTag rcInfo == name -> do
                  -- Zero-arity record type: no CTGen substitution needed.
                  -- (Parameterised record types are a v2 concern.)
                  let fields = rcFields rcInfo
                  case lookupTyCon name env' of
                    Just info | tcArity info /= 0 ->
                      throwError (UnsupportedFeature (Just pos)
                        (Tx.pack ("parameterised record type in sig not yet supported: " <> Tx.unpack name)))
                    _ -> pure ()
                  cRow <- buildCRowFromFields fields
                  pure (CTRecord name cRow)
            _ ->
              -- Regular TyCon path. An effect name in type position denotes an
              -- instance-handle type @TcEffect E@ (named effect instances).
              case lookupTyCon name env' of
                Just info
                  | tcArity info == 0 -> pure (CTCon (resolveTyCon name) [])
                  | otherwise -> throwError
                      (ArityMismatch (Just pos) name (tcArity info) 0)
                Nothing -> case lookupEffect name env' of
                  Just eInfo
                    | length (eiParams eInfo) == 0 -> pure (CTCon (TcEffect name) [])
                    | otherwise -> throwError
                        (ArityMismatch (Just pos) name (length (eiParams eInfo)) 0)
                  Nothing -> throwError (UnknownTyCon (Just pos) name)
        goT (Abs.TApp f x) = do
          let (h, args) = collectApp f x
          case h of
            Abs.TCon modPath -> do
              let name = modPathText modPath
                  pos  = modPathPos modPath
              case lookupTyCon name env' of
                Just info
                  | tcArity info == length args -> do
                      checkArgKinds pos name args (tcParamKinds info)
                      argCTs <- mapM goT args
                      -- Payload restriction (spec §3.3): a concurrency carrier
                      -- (`Promise a` / `Chan a`) must transport only effect-free,
                      -- first-order data. Reject a payload that contains a
                      -- function arrow anywhere (a closure/thunk that could smuggle
                      -- an effect across the carrier). A bare polymorphic payload
                      -- (an unresolved quantified slot, CTGen) stays allowed.
                      when (name `elem` concCarrierTys) $
                        forM_ argCTs (checkConcPayload env' (Just pos))
                      pure (CTCon (resolveTyCon name) argCTs)
                  | otherwise -> throwError
                      (ArityMismatch (Just pos) name (tcArity info) (length args))
                Nothing -> case lookupEffect name env' of
                  -- Saturated effect application `State U64` -> a handle type.
                  Just eInfo
                    | length (eiParams eInfo) == length args -> do
                        checkArgKinds pos name args (map snd (eiParams eInfo))
                        CTCon (TcEffect name) <$> mapM goT args
                    | otherwise -> throwError
                        (ArityMismatch (Just pos) name (length (eiParams eInfo)) (length args))
                  Nothing -> throwError (UnknownTyCon (Just pos) name)
            _ -> throwError
                  (UnsupportedFeature Nothing
                    (Tx.pack "non-tycon type application"))
        goT (Abs.TList inner) = do
          c <- goT inner
          pure (CTCon TcList [c])
        goT (Abs.TTuple a others) = do
          ts <- mapM goT (a : others)
          pure (CTCon (TcTuple (1 + length others)) ts)
        goT (Abs.TParen t') = goT t'
        goT Abs.TUnit = pure (CTCon TcUnit [])
        -- `(row e)` as a type argument (slice B). Elaborates to a KEffect-kinded
        -- row variable, allocated in `rowSeenRef` (so the scheme records it with
        -- kind KEffect). Shares its slot with an effect-row variable `eff e` of
        -- the same name (keyed under "eff:") so `(row e)` and `eff e` in one
        -- scheme refer to the same row.
        goT (Abs.TRowArg (Abs.VarId (_, name))) = do
          let key = Tx.pack "eff:" <> name
          rowSeen <- liftST (readSTRef rowSeenRef)
          case Map.lookup key rowSeen of
            Just i  -> pure (CTGen i)
            Nothing -> CTGen <$> allocSlot rowSeenRef key
        -- `a -> b with E`: the effect row E rides the arrow's row slot.
        -- `with` binds looser than `->`, so for a chain `A -> B -> C with E`
        -- the parse is `TFun A (TWith B C E)` -- E attaches to the INNERMOST
        -- arrow (`B -> C`), which is where a fully-applied curried function
        -- actually performs its effects.
        goT (Abs.TWith a b effRow) =
          CTArr <$> goT a <*> goEffectRow effRow <*> goT b
        -- Type-level extension: `T + { fields }` or `T + row r`.
        -- Only `+` is accepted as the type-level operator; anything else
        -- is rejected with NonPlusTypeOp.
        goT (Abs.TExtend lhs (Abs.VarSym (pos, sym)) rc) = do
          unless (sym == Tx.pack "+") $
            throwError (NonPlusTypeOp (Just pos) sym)
          lhsCT <- goT lhs
          case lhsCT of
            CTRecord tag lhsRow -> do
              extRow <- goRC rc
              let merged = appendCRow extRow lhsRow
              pure (CTRecord tag merged)
            _ -> throwError (UnsupportedFeature Nothing
                  (Tx.pack "left of `+` in a type sig must be a nominal record type"))

        -- Translate a RowContrib to a CRow.
        goRC (Abs.RCAnon fieldDefs) = do
          cts <- forM fieldDefs $ \(Abs.RFType (Abs.VarId (_, fname)) fty) -> do
            ct <- goT fty
            pure (fname, ct)
          pure (foldr (\(l, t) acc -> CRExtend l t acc) CREmpty cts)
        goRC (Abs.RCVar (Abs.VarId (_, rname))) = do
          rowSeen <- liftST (readSTRef rowSeenRef)
          case Map.lookup rname rowSeen of
            Just i  -> pure (CTGen i)
            Nothing -> CTGen <$> allocSlot rowSeenRef rname
        -- Anonymous record tail `Point + ..`: a fresh, single-use row var.
        goRC Abs.RCWild = CTGen <$> freshAnonRowSlot

        -- Translate a `with` clause's effect row into a CRow. An effect label
        -- is the effect's nominal name; the label's field type carries the
        -- effect's type argument(s) (unit when none).
        -- (No local type signature: like its sibling helpers it must share the
        -- enclosing `walk`'s `s`; an explicit sig would bind a fresh rigid `s`.)
        goEffectRow (Abs.EROne atom) = do
          (lbl, fieldCT) <- goEffectAtom atom
          pure (CRExtend lbl fieldCT CREmpty)
        -- The VarSym between atoms is the literal `+` (grammar reuses VarSym
        -- exactly as TExtend does); only `+` is meaningful and the rest of the
        -- row continues after it.
        goEffectRow (Abs.ERPlus atom (Abs.VarSym (pos, sym)) rest) = do
          unless (sym == Tx.pack "+") $ throwError (NonPlusTypeOp (Just pos) sym)
          (lbl, fieldCT) <- goEffectAtom atom
          restRow <- goEffectRow rest
          pure (CRExtend lbl fieldCT restRow)
        -- Named open effect tail `eff e`: a shared KEffect row variable. Keyed
        -- under an "eff:"-prefixed name so that `eff e` and a signature-position
        -- `(row e)` of the same spelling SHARE one slot (both use this prefix; see
        -- `goT (Abs.TRowArg …)`), while the record `+`-tail row var `row e`
        -- (`goRC RCVar`, bare name) stays separate.
        goEffectRow (Abs.ERVarOnly (Abs.VarId (_, name))) = do
          let key = Tx.pack "eff:" <> name
          rowSeen <- liftST (readSTRef rowSeenRef)
          case Map.lookup key rowSeen of
            Just i  -> pure (CTGen i)
            Nothing -> CTGen <$> allocSlot rowSeenRef key
        -- Anonymous open effect tail `..`: a fresh, single-use row var.
        goEffectRow Abs.ERWildOnly = CTGen <$> freshAnonRowSlot

        -- An effect atom `E t1..tn` -> (label "E", field type). The field type
        -- is unit for a no-arg effect, the single arg for one, a tuple for
        -- several. The effect name must already be declared.
        goEffectAtom (Abs.ERAtom (Abs.ConId (pos, name)) typeArgs) =
          case lookupEffect name env' of
            Nothing -> throwError (MissingEffectDecl (Just pos) name)
            Just eInfo  -> do
              checkArgKinds pos name typeArgs (map snd (eiParams eInfo))
              argCTs <- mapM goT typeArgs
              let fieldCT = case argCTs of
                    []  -> CTCon TcUnit []
                    [t] -> t
                    ts  -> CTCon (TcTuple (length ts)) ts
              pure (name, fieldCT)

        -- Allocate a fresh anonymous row-variable slot. Each call mints a
        -- distinct index and records it in rowSeenRef under a unique synthetic
        -- key (so it is quantified as a KEffect var like any row var) that no
        -- source name can collide with. Two `..` tails get distinct keys, so
        -- they are unrelated -- they cannot thread like a named `eff e`/`row r`.
        freshAnonRowSlot = liftST $ do
          n <- readSTRef nextRef
          writeSTRef nextRef (n + 1)
          modifySTRef' rowSeenRef (Map.insert (Tx.pack (".." <> show n)) n)
          pure n

        -- Build a CRow from a list of (field name, CType) pairs
        -- (in declaration order, outermost label first).
        buildCRowFromFields fields =
          pure (foldr (\(l, t) acc -> CRExtend l t acc) CREmpty fields)

        -- Merge two CRows for type-level extension.
        -- Labels from `ext` are prepended before `base`'s labels.
        -- The terminal element of `ext` (CREmpty or CTGen) replaces the
        -- terminal CREmpty of `base`, making row variables in `ext` the
        -- open tail of the merged row.
        --
        -- `Point + { score }`:  ext = CRExtend "score" t CREmpty
        --                       base = CRExtend "x" t (CRExtend "y" t CREmpty)
        --                       result = CRExtend "score" t (CRExtend "x" t (CRExtend "y" t CREmpty))
        --
        -- `Point + row r`:     ext = CTGen i
        --                      base = CRExtend "x" t (CRExtend "y" t CREmpty)
        --                      result = CRExtend "x" t (CRExtend "y" t (CTGen i))
        appendCRow :: CRow -> CRow -> CRow
        appendCRow ext base =
          let newTail = cRowTail ext
              base'   = replaceCREmpty newTail base
          in  prependLabels ext base'

        -- Extract the terminal (CREmpty or CTGen) of a CRow.
        cRowTail :: CRow -> CRow
        cRowTail CREmpty = CREmpty
        cRowTail (CTGen i) = CTGen i
        cRowTail (CRExtend _ _ rest) = cRowTail rest
        cRowTail _ = error "cRowTail: expected a row"

        -- Replace the terminal CREmpty of a CRow with a new tail.
        replaceCREmpty :: CRow -> CRow -> CRow
        replaceCREmpty newTail CREmpty = newTail
        replaceCREmpty _ (CTGen i) = CTGen i  -- already open; preserve it
        replaceCREmpty newTail (CRExtend l t rest) =
          CRExtend l t (replaceCREmpty newTail rest)
        replaceCREmpty _ _ = error "replaceCREmpty: expected a row"

        -- Prepend the labels from `ext` before `base`, stopping at ext's terminal.
        prependLabels :: CRow -> CRow -> CRow
        prependLabels CREmpty base = base
        prependLabels (CTGen _) base = base  -- terminal: labels exhausted
        prependLabels (CRExtend l t rest) base =
          CRExtend l t (prependLabels rest base)
        prependLabels _ _ = error "prependLabels: expected a row"

-- ---------------------------------------------------------------------------
-- Module-level helpers shared by translateSig and processDataDecls
-- ---------------------------------------------------------------------------

collectApp :: Abs.Type -> Abs.Type -> (Abs.Type, [Abs.Type])
collectApp (Abs.TApp f x) y = let (h, xs) = collectApp f x in (h, xs ++ [y])
collectApp other y = (other, [y])

-- | Peel the left-recursive 'EApp' spine of an expression, returning the
-- innermost non-EApp head and the list of arguments in left-to-right order.
-- For @EApp (EApp (EApp h a1) a2) a3@ this returns @(h, [a1, a2, a3])@.
collectExprSpine :: Abs.Exp -> (Abs.Exp, [Abs.Exp])
collectExprSpine (Abs.EApp f x) =
  let (h, xs) = collectExprSpine f in (h, xs ++ [x])
collectExprSpine other = (other, [])

-- | Strip one or more layers of 'EParen' from an expression.
stripEParen :: Abs.Exp -> Abs.Exp
stripEParen (Abs.EParen e) = stripEParen e
stripEParen other          = other

-- | The KIND of a surface type argument, syntax-directed (slice B). A `(row e)`
-- argument is KEffect; every other type is KStar. Used to kind-check tycon
-- applications against 'tcParamKinds' at translation time, so an ill-kinded
-- application (a row in a `*` slot, or a `*` type in a row slot) is rejected at
-- the application site with a clear 'TyConArgKind' error -- preempting the
-- cryptic downstream unification 'KindMismatch'.
argKind :: Abs.Type -> Kind
argKind (Abs.TRowArg _) = KEffect
argKind _               = KStar

-- | Kind-check a SATURATED tycon application's arguments against the tycon's
-- declared per-parameter kinds ('tcParamKinds'). The caller must have already
-- verified @length args == tcArity info@; since @tcArity info == length
-- (tcParamKinds info)@ holds by construction ('registerTyCons'), the 'zip3'
-- pairs every argument with its parameter's kind (the @[0..]@ index list is
-- infinite, so it truncates to that equal-length pair). A mismatch -- a row in a
-- `*` slot, or a `*` type in a row slot -- is a 'TyConArgKind' at the
-- application site (slice B), preempting the cryptic downstream unification
-- 'KindMismatch'. Shared by the signature ('goT') and constructor-field
-- ('walkArg') translators.
checkArgKinds :: (Int, Int) -> Text -> [Abs.Type] -> [Kind] -> TC s ()
checkArgKinds pos name args paramKinds =
  sequence_ [ when (argKind a /= pk) $
                throwError (TyConArgKind (Just pos) name i pk (argKind a))
            | (i, a, pk) <- zip3 [0 ..] args paramKinds ]

-- | Flatten a dotted ModPath into its text key, e.g. Foo.Bar -> "Foo.Bar".
-- Used by the module loader for module-name keys and by the typechecker
-- for tycon/constructor lookup against env keys.
modPathText :: Abs.ModPath -> Text
modPathText (Abs.MPName (Abs.ConId (_, n))) = n
modPathText (Abs.MPDot p (Abs.ConId (_, n))) =
  modPathText p <> Tx.pack "." <> n

-- | Position of the leftmost (first) ConId in a ModPath, used for
-- error reporting.
modPathPos :: Abs.ModPath -> (Int, Int)
modPathPos (Abs.MPName (Abs.ConId (pos, _))) = pos
modPathPos (Abs.MPDot p _)                   = modPathPos p

-- | Extract the text name of a SigName (LHS of a DSig/LDSig).
-- A SigName is either a bare VarId (`foo`) or a parenthesised VarSym (`(+)`).
sigNameText :: Abs.SigName -> Text
sigNameText (Abs.SNBare  (Abs.VarId  (_, n))) = n
sigNameText (Abs.SNParen (Abs.VarSym (_, n))) = n

-- | Position of a SigName for error reporting.
sigNamePos :: Abs.SigName -> (Int, Int)
sigNamePos (Abs.SNBare  (Abs.VarId  (p, _))) = p
sigNamePos (Abs.SNParen (Abs.VarSym (p, _))) = p

resolveTyCon :: Text -> TyCon
resolveTyCon name
  | name == Tx.pack "U64"    = TcU64
  | name == Tx.pack "U32"    = TcU32
  | name == Tx.pack "Bytes"  = TcBytes
  | name == Tx.pack "Char"   = TcChar
  | name == Tx.pack "String" = TcString
  | name == Tx.pack "Never"  = TcNever
  | name == Tx.pack "Bool"   = TcBool
  | name == Tx.pack "()"     = TcUnit
  | name == Tx.pack "[]"     = TcList
  | name == Tx.pack "Array"  = TcArray
  | otherwise                       = TcUser name

-- | The concurrency carriers (spec §3.3) whose payload type is restricted to
-- effect-free, first-order data: 'Promise' and 'Chan' from @Control@.
concCarrierTys :: [Text]
concCarrierTys = [Tx.pack "Promise", Tx.pack "Chan"]

-- | Payload restriction for a concurrency carrier's type argument (spec §3.3).
-- A @Promise a@ / @Chan a@ must transport only effect-free, first-order data, so
-- the payload @a@ may not contain a function arrow anywhere: an arrow is a
-- closure/thunk that could smuggle an effect (or a captured handle) across the
-- carrier, defeating the load-bearing-row avoidance. We walk the RESOLVED type:
--
--   * 'CTArr'    -- a function type (with ANY effect row, including pure) is
--                   rejected outright; this is the load-bearing case.
--   * 'CTCon'    -- recurse into the data-type arguments, so a nested arrow
--                   (e.g. @Pair (() -> U64) Bool@) is caught too. For a USER
--                   tycon we ALSO look up its data constructors in the env and
--                   walk each constructor's declared field types, so an arrow
--                   hidden inside a wrapper (@data Box = Box (() -> U64)@,
--                   @Chan Box@) cannot smuggle past the check. Field types are
--                   walked RAW (no parameter substitution): a 'CTGen' parameter
--                   slot carries no arrow itself, and any arrow instantiated AT
--                   a parameter (@Chan (Wrap (() -> U64))@) appears in @args@,
--                   which are walked anyway. A visited set of tycon names keeps
--                   recursive data types (@data Tree = Node Tree Tree@) from
--                   looping.
--   * 'CTRecord' -- recurse into the record's field types (its row payloads).
--   * 'CTGen'    -- a quantified slot: a bare polymorphic payload @Promise a@ is
--                   ALLOWED (the prelude's generic combinators depend on this).
--   * rows/other -- nothing arrow-shaped to reject.
checkConcPayload :: Env -> SourceSpan -> CType -> TC s ()
checkConcPayload env sp = go Set.empty
  where
    go _    t@CTArr{}            = throwError (ConcPayloadEffectful sp (prettyCType t))
    go seen t@(CTCon tc args)    = do
      -- An affine coro carrier (`Step`/`Suspension`, the extern-marked
      -- tcCarrier tycons) is a captured one-shot continuation: caching it in a
      -- promise cell / channel buffer would let it be resumed more than once.
      -- Reject the tycon itself, anywhere in the payload, before recursing.
      case tc of
        TcUser n | maybe False tcCarrier (lookupTyCon n env) ->
          throwError (ConcPayloadEffectful sp (prettyCType t))
        _ -> pure ()
      mapM_ (go seen) args
      case tc of
        TcUser n | not (Set.member n seen) -> goConFields (Set.insert n seen) n
        _ -> pure ()
    go seen (CTRecord _ row)     = goRow seen row
    go _    (CTGen _)            = pure ()
    go _    CREmpty              = pure ()
    go seen (CRExtend _ ft rs)   = go seen ft >> goRow seen rs
    -- A row's spine: CRExtend/CREmpty are handled above; a CTGen tail is the
    -- only other shape and carries no payload to inspect.
    goRow = go

    -- Walk every data constructor's declared field types for a user tycon.
    -- Positional constructors store their fields as the arrow spine of the
    -- constructor scheme (field1 -> ... -> fieldN -> T); record constructors
    -- store them directly. An extern tycon (Promise/Chan/Fiber/Transport
    -- themselves) has no registered constructors -- nothing to walk.
    goConFields seen n = case lookupTyCon n env of
      Nothing   -> pure ()
      Just info -> forM_ (tcCons info) $ \cn ->
        case lookupCon cn env of
          Just ci -> mapM_ (go seen)
            (conFieldTys (conArity ci) (schemeBody (conScheme ci)))
          Nothing -> case lookupRecordCon cn env of
            Just rc -> mapM_ (go seen . snd) (rcFields rc)
            Nothing -> pure ()

    -- Peel exactly `arity` domains off a constructor scheme's arrow spine.
    conFieldTys :: Int -> CType -> [CType]
    conFieldTys k (CTArr d _ c) | k > 0 = d : conFieldTys (k - 1) c
    conFieldTys _ _                     = []

-- | Bottom elimination: if an operation's result type is @Never@, replace it
-- with a fresh type variable so each perform of a non-returning operation is
-- usable at any type (ex-falso). Non-@Never@ results are returned unchanged.
freshenNeverResult :: Type s -> TC s (Type s)
freshenNeverResult ty = do
  ty' <- force ty
  case ty' of
    TArr a r b -> TArr a r <$> freshenNeverResult b
    TCon TcNever [] -> freshTVar KStar
    _ -> pure ty'

-- ---------------------------------------------------------------------------
-- Data declaration processing
-- ---------------------------------------------------------------------------

-- | Normalize @ConDefRecElide@ into @ConDefRec@ by filling in the data-type
-- name as the constructor tag. Rejects the elided form when the decl has
-- more than one constructor (the tag would be ambiguous or misleading).
normalizeElision
  :: BNFC'Position
  -> Text
  -> [Abs.ConDef]
  -> TC s [Abs.ConDef]
normalizeElision pos typeName cons = case cons of
  [Abs.ConDefRecElide fields] ->
    let rawPos = fromMaybe (1, 1) pos
    in  pure [Abs.ConDefRec (Abs.ConId (rawPos, typeName)) fields]
  _ | any isElided cons ->
        throwError (UnsupportedFeature pos
          (Tx.pack "name-elided constructor `{ ... }` is only valid in single-constructor record decls"))
  _ -> pure cons
  where
    isElided (Abs.ConDefRecElide _) = True
    isElided _                      = False

-- | Verify that no two constructors of the same data decl declare a field
-- with the same name. Positional constructors (ConDef) carry no field names
-- and therefore do not participate in the check.
checkFieldNameUniqueness :: BNFC'Position -> [Abs.ConDef] -> TC s ()
checkFieldNameUniqueness pos cons = do
  let allNames = concatMap fieldNamesOf cons
      dups     = findDups allNames
  case dups of
    []        -> pure ()
    (name : _) -> throwError (UnsupportedFeature pos
      (Tx.pack ("field `" <> Tx.unpack name <> "` is declared in multiple constructors of this type")))
  where
    fieldNamesOf (Abs.ConDefRec _ rfs) =
      [ fname | Abs.RFType (Abs.VarId (_, fname)) _ <- rfs ]
    fieldNamesOf (Abs.ConDefRecElide rfs) =
      [ fname | Abs.RFType (Abs.VarId (_, fname)) _ <- rfs ]
    fieldNamesOf (Abs.ConDef _ _) = []

    findDups :: [Text] -> [Text]
    findDups xs =
      Map.keys (Map.filter (> 1) (foldr (\x m -> Map.insertWith (+) x (1 :: Int) m) Map.empty xs))

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
    -- MINIMAL slice-B fix: extract the bound name from a tycon parameter.
    -- The `(row e)` kind annotation (TPRow) is IGNORED here; per-param kinds
    -- are Task 2. Both forms bind a single VarId name.
    tyParamName :: Abs.TyParam -> Tx.Text
    tyParamName (Abs.TPPlain (Abs.VarId (_, n))) = n
    tyParamName (Abs.TPRow   (Abs.VarId (_, n))) = n

    -- The kind a tycon parameter binds at: a bare `a` is KStar, a `(row e)`
    -- annotation binds a row variable at KEffect (slice B).
    paramKind :: Abs.TyParam -> Kind
    paramKind (Abs.TPPlain _) = KStar
    paramKind (Abs.TPRow   _) = KEffect

    dataDecls = filter isDataLike decls

    isDataLike Abs.DData{}       = True
    isDataLike Abs.DExternData{} = True
    isDataLike Abs.DExternType{} = True
    isDataLike _                 = False

    -- (pos, name, params, isCarrier) for the tycon-registration pass.
    dataLikeHead (Abs.DData (Abs.ConId (pos, n)) ps _)       = (pos, n, ps, False)
    dataLikeHead (Abs.DExternData (Abs.ConId (pos, n)) ps _) = (pos, n, ps, True)
    dataLikeHead (Abs.DExternType (Abs.ConId (pos, n)) ps)   = (pos, n, ps, True)
    dataLikeHead _ = error "processDataDecls.dataLikeHead: non-data-like (input pre-filtered)"

    -- The constructor defs to register, if any. extern type has none.
    conDefsOf (Abs.DData (Abs.ConId (pos, n)) ps cs)       = Just (pos, n, ps, cs)
    conDefsOf (Abs.DExternData (Abs.ConId (pos, n)) ps cs) = Just (pos, n, ps, cs)
    conDefsOf Abs.DExternType{}                            = Nothing
    conDefsOf _ = error "processDataDecls.conDefsOf: non-data-like (input pre-filtered)"

    registerTyCons env [] = pure env
    registerTyCons env (d : ds) =
      let (pos, name, params, carrier) = dataLikeHead d
      in case lookupTyCon name env of
        Just _  -> throwError (DuplicateTyCon (Just pos) name)
        Nothing -> do
          let pks  = map paramKind params
              k    = foldr KArrow KStar pks
              -- tcAffine: False ONLY for the prelude's 'Borrow' carrier (FFI
              -- Slice 3 Task 1) -- second-class but readable any number of
              -- times. True for every other carrier (and for non-carriers,
              -- where the flag is unconsulted), so 'Suspension'/'Step'/
              -- 'ContCell' stay consume-once unchanged.
              -- (Flagged repeatedly as "safe but not principled": it is safe
              -- because 'extern' is prelude-only and tycon names are
              -- globally unique, so no user-defined type can shadow
              -- 'Borrow' here; a marker mechanism is over-engineering for
              -- one consumer, so this literal-name gate is deliberate, not
              -- an oversight. A future second non-affine carrier extends
              -- this check.)
              affine = name /= Tx.pack "Borrow"
              info = TyConInfo k (length params) [] carrier affine pks
          registerTyCons (extendTyCon name info env) ds

    registerCons env [] = pure env
    registerCons env (d : ds) = case conDefsOf d of
      Nothing -> registerCons env ds   -- extern type: opaque, no constructors
      Just (pos, tcName, params, conDefs) -> do
        let paramNames = map tyParamName params
            paramMap = Map.fromList (zip paramNames [0 ..])
            pks      = map paramKind params
        -- Normalize elision (ConDefRecElide -> ConDefRec) and reject
        -- elision in multi-constructor decls.
        conDefs' <- normalizeElision (Just pos) tcName conDefs
        -- Reject same field name across constructors of this decl.
        checkFieldNameUniqueness (Just pos) conDefs'
        env' <- foldM (registerCon tcName paramMap pks) env conDefs'
        -- Collect positional constructor names for tcCons (record constructors
        -- are NOT included in tcCons because they don't appear in pattern
        -- applications via the positional namespace).
        let cons = [ cn | Abs.ConDef (Abs.ConId (_, cn)) _ <- conDefs' ]
            tcInfo = case lookupTyCon tcName env' of
              Just t  -> t { tcCons = cons }
              Nothing -> error "registerCons: tycon vanished"
            env'' = extendTyCon tcName tcInfo env'
        registerCons env'' ds

    registerCon tcName paramMap pks env (Abs.ConDef (Abs.ConId (pos, cname)) argTys) =
      case lookupCon cname env of
        Just _ -> throwError (DuplicateCon (Just pos) cname)
        Nothing -> do
          argCTypes <- mapM (translateConArg env paramMap pks) argTys
          let arity = length argTys
              paramCount = Map.size paramMap
              resultTy = CTCon (resolveTyCon tcName)
                           [ CTGen i | i <- [0 .. paramCount - 1] ]
              body = foldr (\arg acc -> CTArr arg CREmpty acc) resultTy argCTypes
              -- Per-param kinds (slice B): a `(row e)` param quantifies at KEffect.
              quantifiers = zip [0 ..] pks
              scheme = mkScheme quantifiers body
              info = ConInfo scheme arity tcName
          pure (extendCon cname info env)

    registerCon _tcName paramMap pks env (Abs.ConDefRec (Abs.ConId (pos, cname)) fields) =
      case lookupRecordCon cname env of
        Just _ -> throwError (DuplicateCon (Just pos) cname)
        Nothing -> do
          fieldsCT <- forM fields $ \(Abs.RFType (Abs.VarId (_, fname)) ty) -> do
            ct <- translateConArg env paramMap pks ty
            pure (fname, ct)
          let quantifiers = zip [0 ..] pks
              info = RecordConInfo
                { rcTag    = cname
                , rcFields = fieldsCT
                , rcParams = quantifiers
                }
          pure (extendRecordCon cname info env)

    registerCon _ _ _ _ (Abs.ConDefRecElide _) =
      error "registerCon: ConDefRecElide should have been normalized away by normalizeElision"

-- | Translate a constructor-argument, record-field, or effect-operation type
-- into a closed 'CType'. The user's declared type parameters resolve (via
-- @paramMap@) to 'CTGen' slots; other names resolve to in-scope type
-- constructors. Shared by 'processDataDecls' and 'processEffectDecls'.
--
-- A @with@ clause on the type (effect-carrying field/op types) is NOT handled
-- here; such types are a later feature and reach the non-exhaustive fall through.
translateConArg :: Env -> Map.Map Text Int -> [Kind] -> Abs.Type -> TC s CType
translateConArg env paramMap pks ty = do
  -- Apply the same `..`-polarity rule signatures get (spec 145/142), so an
  -- anonymous tail can never reach a parameter position via a data-field or
  -- operation type either. Today 'walkArg' rejects `with`/`+` wholesale, but
  -- routing through this check keeps the rule enforced uniformly and closes the
  -- loophole that would open if 'walkArg' later supported those forms.
  checkAnonTailPolarity Nothing ty
  -- B4: a constructor field's OWN type must have kind `*`. A bare row-param
  -- field (`Box e` with `e:KEffect`) or a `(row e)` field has kind KEffect and
  -- is rejected here, before it can leak a cryptic downstream KindMismatch.
  when (fieldArgKind ty /= KStar) $
    throwError (FieldKindError (fieldKindPos ty) (fieldArgKind ty))
  walkArg ty
  where
    -- Binding-aware kind of a field-position type (slice B). A bare variable
    -- resolves to its enclosing declaration's declared param kind (`(row e)`
    -- params are KEffect); anything else -- a concrete type, tycon application,
    -- or arrow -- is KStar. This differs from the syntactic `argKind`, which
    -- cannot see param bindings and is correct only in signature context.
    fieldArgKind :: Abs.Type -> Kind
    fieldArgKind (Abs.TVar (Abs.VarId (_, n)))    = maybe KStar (pks !!) (Map.lookup n paramMap)
    fieldArgKind (Abs.TRowArg (Abs.VarId (_, n))) = maybe KStar (pks !!) (Map.lookup n paramMap)
    fieldArgKind _                                = KStar

    -- Position of a field type, for the B4 error (when available).
    fieldKindPos :: Abs.Type -> BNFC'Position
    fieldKindPos (Abs.TVar (Abs.VarId (p, _)))    = Just p
    fieldKindPos (Abs.TRowArg (Abs.VarId (p, _))) = Just p
    fieldKindPos _                                = Nothing
    walkArg (Abs.TVar (Abs.VarId (pos, name))) =
      case Map.lookup name paramMap of
        Just i -> pure (CTGen i)
        Nothing -> throwError (UnknownTyCon (Just pos) name)
    -- `(row e)` as a field-type argument (slice B): resolves to the decl's own
    -- row-kinded param slot. The slot's KEffect kind comes from the tycon's
    -- per-param kinds (registerTyCons/registerCon). A field may only reference a
    -- row variable bound by the enclosing declaration's parameters.
    walkArg (Abs.TRowArg (Abs.VarId (pos, name))) =
      case Map.lookup name paramMap of
        Just i -> pure (CTGen i)
        Nothing -> throwError (UnknownTyCon (Just pos) name)
    walkArg (Abs.TFun a b) =
      CTArr <$> walkArg a <*> pure CREmpty <*> walkArg b
    walkArg (Abs.TCon mp) = do
      let n = modPathText mp
          p = modPathPos mp
      case lookupTyCon n env of
        Just info
          | tcArity info == 0 -> pure (CTCon (resolveTyCon n) [])
          | otherwise -> throwError (ArityMismatch (Just p) n (tcArity info) 0)
        Nothing -> throwError (UnknownTyCon (Just p) n)
    walkArg (Abs.TApp f x) = do
      let (h, args) = collectApp f x
      case h of
        Abs.TCon mp -> do
          let n = modPathText mp
              p = modPathPos mp
          case lookupTyCon n env of
            Just info
              | tcArity info == length args -> do
                  -- B1: kind-check field tycon-args by their BINDING-AWARE kind
                  -- (`fieldArgKind`), not the syntactic `argKind`. A bare param
                  -- variable contributes its declared param kind, so a KEffect
                  -- param in a `*` slot (`Option e`) is rejected and a KEffect
                  -- param in a row slot (`Box e`) is accepted -- consistently
                  -- with the explicit `(row e)` form.
                  sequence_ [ when (fieldArgKind a /= pk) $
                                throwError (TyConArgKind (Just p) n i pk (fieldArgKind a))
                            | (i, a, pk) <- zip3 [0 ..] args (tcParamKinds info) ]
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
    walkArg Abs.TUnit = pure (CTCon TcUnit [])
    walkArg other = throwError (UnsupportedFeature Nothing
      (Tx.pack ("unsupported type in constructor/operation: " <> show other)))

-- ---------------------------------------------------------------------------
-- Effect declaration processing
-- ---------------------------------------------------------------------------

-- | The ground IO: the effect named @IO@ with no declared operations (seeded
-- in 'Builtins.initialEnv'). It is discharged by running the program, never by
-- a handler, and so cannot be handled and may be overridden once by a user
-- @effect IO = { ... }@ declaration. A user-declared IO carries ops, so this
-- predicate is False for it and the special-casing does not fire.
isGroundIO :: Text -> EffectInfo -> Bool
isGroundIO n ei = n == Tx.pack "IO" && Map.null (eiOps ei)

-- | Register @effect@ declarations into the env's effect namespace.
-- @effect E p1..pn = { op1 : T1, ... }@ becomes an 'EffectInfo' whose
-- operations are schemes quantified over the effect's type parameters. An
-- operation's type is translated like a record-field type ('translateConArg'),
-- so it may mention the effect's parameters and in-scope type constructors.
-- (Operation types carrying their own @with@ clause are a later feature.)
processEffectDecls :: Env -> [Abs.Decl] -> TC s Env
processEffectDecls env0 decls = foldM registerEffect env0 effectDecls
  where
    effectDecls = [ d | d@(Abs.DEffect{}) <- decls ]

    registerEffect env (Abs.DEffect (Abs.ConId (pos, name)) params fields) =
      case lookupEffect name env of
        -- The ground IO may be overridden ONCE by a user `effect IO = { ... }`.
        -- Any other already-present effect (a prelude effect inherited via
        -- imports, a same-pass duplicate, or an already-overridden IO that now
        -- has ops) is a duplicate.
        --
        -- The override must declare at least one operation: override-ONCE
        -- depends on the override NOT satisfying 'isGroundIO' afterwards, and
        -- an empty `effect IO = {}` still would -- letting a SECOND override
        -- slip past the duplicate check below. The zero-op effect is also
        -- unusable by construction (nothing to perform; unhandleable via the
        -- ground-IO gate), so rejecting it costs nothing.
        Just ei
          | isGroundIO name ei ->
              if null fields
                then throwError (UnsupportedFeature (Just pos)
                       (Tx.pack "an `effect IO` override must declare at least \
                                \one operation; the ground IO cannot be \
                                \re-declared empty"))
                else register
          | otherwise          -> throwError (DuplicateTyCon (Just pos) name)
        Nothing -> register
      where
        register = do
          let paramNames  = [ n | Abs.VarId (_, n) <- params ]
              paramMap    = Map.fromList (zip paramNames [0 ..])
              paramCount  = length paramNames
              quantifiers = [ (i, KStar) | i <- [0 .. paramCount - 1] ]
          opMap <- foldM (registerOp env paramMap (Just pos) quantifiers name)
                         Map.empty fields
          pure (extendEffect name (EffectInfo quantifiers opMap) env)
    registerEffect _ _ =
      error "processEffectDecls: non-DEffect reached (input should be pre-filtered)"

    registerOp env paramMap pos quantifiers ename acc
               (Abs.RFType (Abs.VarId (_, opName)) ty) =
      case Map.lookup opName acc of
        Just _  -> throwError (DuplicateOperation pos ename opName)
        Nothing -> do
          ct <- translateConArg env paramMap (map snd quantifiers) ty
          pure (Map.insert opName (mkScheme quantifiers ct) acc)

-- ---------------------------------------------------------------------------
-- Foreign module declaration processing
-- ---------------------------------------------------------------------------

-- | Register @foreign module@ declarations into the env's foreign-module
-- namespace.  For each member the declared type is checked via 'translateSig'
-- (same path as a top-level signature), so @with IO@ in a member type resolves
-- to the CRExtend row.  The blessed allow-list honesty check gates every
-- (lib, C-symbol) pair; unknown pairs produce 'ForeignSymbolNotBlessed'.
processForeignDecls :: Env -> [Abs.Decl] -> TC s Env
processForeignDecls env0 decls = foldM registerForeign env0 foreignDecls
  where
    foreignDecls = [ d | d@(Abs.DForeign{}) <- decls ]

    registerForeign env (Abs.DForeign (Abs.ConId (pos, name)) lib ffree mems) = do
      -- Ambiguity check: reject a ConId that is already a declared effect.
      case lookupEffect name env of
        Just _  -> throwError (AmbiguousProjectionHead (Just pos) name)
        Nothing -> pure ()
      -- Duplicate check: reject a ConId that is already a declared foreign module.
      case lookupForeignModule name env of
        Just _  -> throwError (DuplicateForeignModule (Just pos) name)
        Nothing -> pure ()
      -- Parse the free-function symbol, if any.
      let mFreeSymbol = case ffree of
            Abs.FFNone   -> Nothing
            Abs.FFSym fs -> Just (Tx.pack fs)
          libText = Tx.pack lib
      -- Register each member, checking the blessed table.
      memberMap <- foldM (registerMember env name libText mFreeSymbol)
                         Map.empty mems
      let info = ForeignModuleInfo
                   { fmLib     = libText
                   , fmFree    = mFreeSymbol
                   , fmMembers = memberMap
                   }
      pure (extendForeignModule name info env)
    registerForeign _ _ =
      error "processForeignDecls: non-DForeign reached (input should be pre-filtered)"

    registerMember env modName libText mFreeSymbol acc mem = do
      let (varId, fsym, ty, isOwned) = case mem of
            Abs.FMPlain  v s t -> (v, s, t, False)
            Abs.FMOwned  v s t -> (v, s, t, True)
          Abs.VarId (mpos, memberName) = varId
          memberPos = Just mpos
          -- C symbol: FSName override, else the member name.
          cSymbol = case fsym of
            Abs.FSNone     -> memberName
            Abs.FSName str -> Tx.pack str
      -- Honesty check: (lib, C-symbol) must be in the blessed table.
      bsig <- case Blessed.lookupBlessed libText cSymbol of
        Nothing   -> throwError (ForeignSymbolNotBlessed memberPos libText cSymbol)
        Just bsig -> pure bsig
      -- owned members require a free clause.
      when (isOwned && isNothing mFreeSymbol) $
        throwError (ForeignOwnedNeedsFree memberPos modName memberName)
      -- Disposition coherence: `owned` must agree with the blessed ReturnDisp.
      -- DispAdopt  <=> owned must be True  (caller takes ownership, needs free).
      -- DispScalar <=> owned must be False (plain scalar, no heap transfer).
      -- DispCopy   <=> owned must be False (transfer-none copy; wok manages it).
      -- DispBorrow <=> owned must be False (the BORROW disposition has its own
      --   keyword-free coherence check below -- the member's declared return
      --   TYPE, not `owned`, is what must agree with DispBorrow).
      let expectedOwned = Blessed.bsReturn bsig == Blessed.DispAdopt
      when (isOwned /= expectedOwned) $
        let msg = if expectedOwned
                    then "foreign member '" <> memberName <>
                         "' returns an owned buffer; declare it `owned` and" <>
                         " give the module a `free` clause"
                    else case Blessed.bsReturn bsig of
                           Blessed.DispCopy   -> "foreign member '" <> memberName <>
                                                 "' returns a copy-managed buffer; remove `owned`"
                           Blessed.DispBorrow -> "foreign member '" <> memberName <>
                                                 "' returns a borrowed view; remove `owned`"
                           _                  -> "foreign member '" <> memberName <>
                                                 "' returns a scalar; remove `owned`"
        in throwError (ForeignDispositionMismatch memberPos memberName msg)
      -- Free-symbol coherence for DispAdopt: the RC runtime hardwires libc
      -- 'free' as the destructor for the 0xFFFB adopt cell. Any other free
      -- symbol would type-check but crash at runtime. Reject non-"free"
      -- destructors at compile time with a clear diagnostic.
      when (Blessed.bsReturn bsig == Blessed.DispAdopt
            && mFreeSymbol /= Just (Tx.pack "free")) $
        let sym = case mFreeSymbol of
                    Just s  -> "\"" <> s <> "\""
                    Nothing -> "<none>"
            msg = "foreign member '" <> memberName <>
                  "' is adopt-return; the module's `free` clause must be" <>
                  " \"free\" (the only supported destructor), got " <> sym
        in throwError (ForeignDispositionMismatch memberPos memberName msg)
      -- Per-argument transfer marker (FFI Slice 4): walk the surface `owned`
      -- modifiers, recording one 'Blessed.ArgTransfer' per parameter in
      -- declaration order AND stripping `owned` from the (only) positions
      -- where it is valid -- a parameter head. Any `owned` left standing
      -- after this strip (a return type, or nested inside a compound
      -- parameter type) is therefore, BY CONSTRUCTION, misplaced, and
      -- 'translateSig' below rejects it with 'OwnedModifierMisplaced'.
      let (transfers, tyStripped) = classifyOwnedParams ty
      -- Translate the (owned-stripped) declared type as a full top-level
      -- signature (supporting `with E` rows and polymorphism).
      scheme <- translateSig env tyStripped
      -- `classifyOwnedParams` and `translateSig`'s arrow-spine walk (`goT`)
      -- classify every `Abs.Type` shape identically (advance on `TFun`/
      -- `TWith`, transparently unwrap `TParen`/prenex-`TQual`, terminate on
      -- everything else -- see `classifyOwnedParams`'s doc), so `transfers`
      -- and `paramCTys` are STRUCTURALLY the same length: no runtime
      -- assertion is needed to keep them in sync.
      let paramCTys = paramCTypesOf (schemeBody scheme)
      -- Argument-transfer coherence (a): `owned` is boundary metadata scoped
      -- to `Bytes` parameters only in this slice -- there is no blessed sink
      -- for any other owned-INTO-C payload shape (spec §6.1).
      sequence_
        [ throwError (ForeignOwnedArgNotBytes memberPos memberName
            ("foreign member '" <> memberName <>
             "' declares an `owned` parameter of type " <>
             prettyCType paramCTy <>
             "; `owned` is only supported on `Bytes` parameters"))
        | (transfer, paramCTy) <- zip transfers paramCTys
        , transfer == Blessed.MoveOut
        , paramCTy /= CTCon TcBytes []
        ]
      -- Argument-transfer coherence (b), BIDIRECTIONAL: the surface `owned`
      -- markers and the blessed table's per-argument `MoveOut` markers must
      -- AGREE at every position. Out-of-range/absent positions on either side
      -- default to `TransferNone` (mirroring `[]` meaning "all borrow-out").
      -- The blessed table is authoritative for what the runtime router (FFI
      -- Slice 4 Task 4) actually does with an argument, so BOTH mismatch
      -- directions are unsound:
      --   * surface `owned` but no blessed `MoveOut` -> the signature promises
      --     a transfer-full handoff nothing performs (ForeignOwnedArgNotBlessed);
      --   * blessed `MoveOut` but no surface `owned` -> the runtime moves/frees
      --     the buffer while the checker treated it as a still-usable borrow,
      --     a latent use-after-move (ForeignBlessedMoveOutNeedsOwned).
      -- INVARIANT (relied on by Task 2/4): for any member that passes this
      -- check, the surface-derived `fmiArgTransfer` equals the blessed
      -- `bsArgTransfer` at every parameter position, so either list may be
      -- threaded into `RForeignCall` / the router interchangeably.
      let transferAt xs i = case drop i xs of
            (t : _) -> t
            []      -> Blessed.TransferNone
          blessedTransfers = Blessed.bsArgTransfer bsig
      sequence_
        [ throwError (ForeignOwnedArgNotBlessed memberPos memberName
            ("foreign member '" <> memberName <>
             "' declares an `owned` parameter at position " <> Tx.pack (show i) <>
             ", but " <> libText <> "." <> cSymbol <>
             " is not blessed with a matching `MoveOut` there"))
        | (i, transfer) <- zip [0 :: Int ..] transfers
        , transfer == Blessed.MoveOut
        , transferAt blessedTransfers i /= Blessed.MoveOut
        ]
      sequence_
        [ throwError (ForeignBlessedMoveOutNeedsOwned memberPos memberName
            ("foreign member '" <> memberName <>
             "' is blessed to take ownership of parameter " <> Tx.pack (show i) <>
             " (" <> libText <> "." <> cSymbol <>
             " is a transfer-full sink there); declare it as `owned " <>
             prettyCType paramTy <> "`"))
        | (i, blessedT, paramTy)
            -- The `++ repeat Bytes` tail is a best-effort MESSAGE hint only:
            -- it supplies a default `Bytes` type to render if the blessed table
            -- ever over-declares `MoveOut` at a position past the member's
            -- declared arity. The rejection itself fires correctly regardless
            -- (it keys on `blessedT`/`transfers`, not `paramTy`); only the
            -- shown type would be the default in that (currently unreachable)
            -- over-declaration case.
            <- zip3 [0 :: Int ..] blessedTransfers
                    (paramCTys ++ repeat (CTCon TcBytes []))
        , blessedT == Blessed.MoveOut
        , transferAt transfers i /= Blessed.MoveOut
        ]
      -- Borrow-disposition coherence (FFI Slice 3 Task 4): unlike `owned`,
      -- the borrow disposition is carried by the member's declared RETURN
      -- TYPE, not a keyword -- a member blessed DispBorrow must declare its
      -- final (post-application) return type as exactly `Borrow`. Without
      -- this check a blessed-DispBorrow member could declare a different
      -- return type (e.g. `U64`); the elaborator would still wrap the call's
      -- result as a 0xFFFA borrow view (the blessed table is authoritative
      -- for the runtime disposition), producing a value whose runtime
      -- representation disagrees with its checked type -- a soundness hole.
      when (Blessed.bsReturn bsig == Blessed.DispBorrow
            && finalReturnCType (schemeBody scheme) /= CTCon (TcUser (Tx.pack "Borrow")) []) $
        throwError (ForeignDispositionMismatch memberPos memberName
          ("foreign member '" <> memberName <>
           "' is blessed as a borrow-disposition producer; its declared" <>
           " return type must be `Borrow`"))
      let minfo = ForeignMemberInfo
                    { fmiScheme      = scheme
                    , fmiSymbol      = cSymbol
                    , fmiOwned       = isOwned
                    , fmiArgTransfer = transfers
                    }
      pure (Map.insert memberName minfo acc)

    -- Walk the surface signature's arrow spine ONCE, doing double duty:
    --   (1) extract one ArgTransfer per parameter (`owned T` at a parameter
    --       HEAD -> MoveOut, else TransferNone), in declaration order;
    --   (2) strip the `owned` wrapper from exactly those parameter-head
    --       positions, leaving every other `TOwned` (a return type, or one
    --       nested inside a compound parameter type like `Array (owned
    --       Bytes)`) untouched.
    -- The returned, owned-stripped type is what 'translateSig' then
    -- translates -- so `translateSig`'s `goT` only ever sees a leftover
    -- `TOwned` that is genuinely misplaced, and rejects it with
    -- 'OwnedModifierMisplaced'.
    --
    -- `go` (the spine walk) and `translateSig`'s own arrow walk (`goT`,
    -- Infer.hs:~539-652) MUST classify every `Abs.Type` shape identically,
    -- because the two lists this produces (the `ArgTransfer`s and, via the
    -- stripped type, `paramCTypesOf (schemeBody scheme)`) are zipped
    -- position-by-position by the coherence checks below:
    --   * ADVANCE the spine (emit a param, recurse on the tail): `TFun`,
    --     `TWith` (`goT` maps both to `CTArr <param> _ <tail>`).
    --   * TRANSPARENT continuation (unwrap in place, position-preserving):
    --     `TParen` (`goT (TParen t') = goT t'`) and a prenex `TQual ctx body`
    --     (peeled to `body` at `translateSig`'s entry; a NON-prenex `TQual`
    --     is rejected by `goT` before this walk runs).
    --   * TERMINATE (a leaf, no further params): everything else -- `TApp`,
    --     `TVar`, `TCon`, `TList`, `TTuple`, `TUnit`, `TRowArg`, `TExtend`,
    --     and (deliberately, UNLIKE the old design) a bare `TOwned` reached
    --     outside a parameter head, which is a non-parameter position and
    --     so is left as a leaf for `goT` to reject (`paramCTypesOf` stops on
    --     the resulting non-`CTArr`, and `go`'s `_` arm stops here too).
    -- `argOf` classifies exactly one parameter HEAD: `owned T` (through a
    -- `TParen`) strips to `T` and reports `MoveOut`; anything else is left
    -- as-is with `TransferNone`.
    -- Keep this correspondence exact: a missing transparent case truncates
    -- the transfer list (dropping a later parameter's `owned`, bypassing the
    -- gate) and desyncs it from `paramCTys`'s length.
    classifyOwnedParams :: Abs.Type -> ([Blessed.ArgTransfer], Abs.Type)
    classifyOwnedParams = go
      where
        go (Abs.TFun a rest) =
          let (transfer, a')      = argOf a
              (transfers, rest')  = go rest
          in (transfer : transfers, Abs.TFun a' rest')
        go (Abs.TWith a rest eff) =
          let (transfer, a')      = argOf a
              (transfers, rest')  = go rest
          in (transfer : transfers, Abs.TWith a' rest' eff)
        go (Abs.TParen t) =
          let (transfers, t') = go t
          in (transfers, Abs.TParen t')
        go (Abs.TQual ctx body) =
          let (transfers, body') = go body
          in (transfers, Abs.TQual ctx body')
        go t = ([], t)

        argOf (Abs.TOwned t) = (Blessed.MoveOut, t)
        argOf (Abs.TParen t) =
          let (transfer, t') = argOf t
          in (transfer, Abs.TParen t')
        argOf t = (Blessed.TransferNone, t)

    -- Peel a CType's arrow chain down to its parameter types, in order.
    paramCTypesOf :: CType -> [CType]
    paramCTypesOf (CTArr a _ b) = a : paramCTypesOf b
    paramCTypesOf _             = []

    -- Peel a CType's arrow chain down to its final (non-arrow) result type.
    finalReturnCType :: CType -> CType
    finalReturnCType (CTArr _ _ b) = finalReturnCType b
    finalReturnCType t             = t

-- ---------------------------------------------------------------------------
-- Pattern inference
-- ---------------------------------------------------------------------------

-- | Infer a pattern's type and the bindings it introduces.
-- Returns (the type the pattern matches, variable bindings introduced).
inferPat :: Abs.Pat -> TC s (Type s, [(Text, Type s)], TPatS s)
inferPat (Abs.PAtom ap) = inferAtomPat ap
inferPat (Abs.PApp modPath ap aps) = do
  let name  = modPathText modPath
      pos   = modPathPos modPath
      atoms = ap : aps
  env <- currentEnv
  case lookupCon name env of
    Nothing -> throwError (UnknownCon (Just pos) name)
    Just info -> do
      when (conArity info /= length atoms) $
        throwError (ArityMismatch (Just pos) name (conArity info) (length atoms))
      conTy <- instantiate (conScheme info)
      (argTys, resultTy) <- splitConType conTy (length atoms)
      subResults <- mapM inferAtomPat atoms
      let subTys = map (\(t, _, _) -> t) subResults
          subBinds = concatMap (\(_, b, _) -> b) subResults
          subNodes = map (\(_, _, n) -> n) subResults
      mapM_ (\(a, b) -> unify (Just pos) a b) (zip argTys subTys)
      pure (resultTy, subBinds, Ty.Tpat resultTy (Ty.TPCon name subNodes))
inferPat (Abs.PCons headPat tailPat) = do
  (hT, hBinds, hNode) <- inferAtomPat headPat
  (tT, tBinds, tNode) <- inferPat tailPat
  unify (patPos tailPat) tT (TCon TcList [hT])
  let ty = TCon TcList [hT]
  pure (ty, hBinds ++ tBinds, Ty.Tpat ty (Ty.TPCons hNode tNode))

inferAtomPat :: Abs.AtomPat -> TC s (Type s, [(Text, Type s)], TPatS s)
inferAtomPat (Abs.APVar (Abs.VarId (_, name))) = do
  t <- freshTVar KStar
  pure (t, [(name, t)], Ty.Tpat t (Ty.TPVar name))
inferAtomPat Abs.APWild = do
  t <- freshTVar KStar
  pure (t, [], Ty.Tpat t Ty.TPWild)
inferAtomPat Abs.PUnit = let ty = TCon TcUnit [] in pure (ty, [], Ty.Tpat ty Ty.TPUnit)
inferAtomPat (Abs.APLitI (Abs.WokInt (_, t))) =
  let ty = TCon TcU64 [] in pure (ty, [], Ty.Tpat ty (Ty.TPLitI (readInt t)))
inferAtomPat (Abs.APLitS s) =
  let ty = TCon TcString [] in pure (ty, [], Ty.Tpat ty (Ty.TPLitS (Tx.pack s)))
inferAtomPat (Abs.APLitC c) =
  let ty = TCon TcChar [] in pure (ty, [], Ty.Tpat ty (Ty.TPLitC c))
inferAtomPat (Abs.APCon modPath) = do
  let name = modPathText modPath
      pos  = modPathPos modPath
  env <- currentEnv
  case lookupCon name env of
    Nothing -> throwError (UnknownCon (Just pos) name)
    Just info -> do
      when (conArity info /= 0) $
        throwError (ArityMismatch (Just pos) name (conArity info) 0)
      ty <- instantiate (conScheme info)
      pure (ty, [], Ty.Tpat ty (Ty.TPCon name []))
inferAtomPat (Abs.APTuple p1 ps) = do
  results <- mapM inferPat (p1 : ps)
  let ts = map (\(t, _, _) -> t) results
      bs = concatMap (\(_, b, _) -> b) results
      ns = map (\(_, _, n) -> n) results
      ty = TCon (TcTuple (length results)) ts
  pure (ty, bs, Ty.Tpat ty (Ty.TPTuple ns))
inferAtomPat (Abs.APList []) = do
  e <- freshTVar KStar
  let ty = TCon TcList [e]
  pure (ty, [], Ty.Tpat ty (Ty.TPList []))
inferAtomPat (Abs.APList (p : ps)) = do
  (firstT, firstBinds, firstNode) <- inferPat p
  restResults <- mapM inferPat ps
  let restBinds = concatMap (\(_, b, _) -> b) restResults
      restNodes = map (\(_, _, n) -> n) restResults
  mapM_ (\(q, (t, _, _)) -> unify (patPos q) firstT t) (zip ps restResults)
  let ty = TCon TcList [firstT]
  pure (ty, firstBinds ++ restBinds, Ty.Tpat ty (Ty.TPList (firstNode : restNodes)))
inferAtomPat (Abs.APParen p) = inferPat p
-- As-pattern (`pat as name`): match via the inner pattern; bind `name` to the
-- whole matched value, which has the inner pattern's type. Recurse into the
-- inner AtomPat and wrap its node in TPAs; no new unification.
inferAtomPat (Abs.APAs inner (Abs.VarId (_, name))) = do
  -- `pat as name`: the inner pattern drives the match; `name` binds the WHOLE
  -- matched value, so it has the inner pattern's type. No new unification.
  (ty, innerBinds, innerNode) <- inferAtomPat inner
  pure (ty, (name, ty) : innerBinds, Ty.Tpat ty (Ty.TPAs name innerNode))

-- Strict record pattern: PRecord T { f1 = p1, ..., fn = pn }
-- All declared fields must be present; no extras; produces a closed row.
inferAtomPat (Abs.PRecord (Abs.ConId (pos, conName)) fieldPats) = do
  env <- currentEnv
  conInfo <- case lookupRecordCon conName env of
    Just info -> pure info
    Nothing -> case lookupCon conName env of
      Just _  -> throwError (RecordConstructorNeedsBraces (Just pos) conName)
      Nothing -> throwError (UnknownCon (Just pos) conName)
  let declaredMap    = Map.fromList (rcFields conInfo)
      declaredNames  = Set.fromList (Map.keys declaredMap)
      providedFields = [ (fname, fpat)
                       | Abs.RFPat (Abs.VarId (_, fname)) fpat <- fieldPats ]
      providedNames  = Set.fromList (map fst providedFields)
      extras         = Set.difference providedNames declaredNames
      missing        = Set.difference declaredNames providedNames
  unless (Set.null extras) $
    throwError (UnknownField (Just pos) conName (Set.findMin extras))
  unless (Set.null missing) $
    throwError (UnknownField (Just pos) conName (Set.findMin missing))
  paramSubst <- instantiateParamSubst (rcParams conInfo)
  rowEntries <- forM (rcFields conInfo) $ \(fname, fcty) -> do
    let declaredFieldT = substCTypeWith paramSubst fcty
    case lookup fname providedFields of
      Just p -> do
        (patT, patBinds, patNode) <- inferPat p
        unify (Just pos) patT declaredFieldT
        pure (fname, declaredFieldT, patBinds, patNode)
      Nothing -> error "PRecord: missing field not caught above (impossible)"
  let row   = foldr (\(n, t, _, _) acc -> RowExtend n t acc) RowEmpty rowEntries
      patT  = TRecord conName row
      binds = concatMap (\(_, _, b, _) -> b) rowEntries
      nodes = map (\(_, _, _, n) -> n) rowEntries
  pure (patT, binds, Ty.Tpat patT (Ty.TPCon conName nodes))

-- Open record pattern with anonymous row tail: PRecordOpen T { fs, .. }
-- Provided fields must be a subset of declared; produces an open row (fresh RowVar tail).
inferAtomPat (Abs.PRecordOpen (Abs.ConId (pos, conName)) fieldPats Abs.PRTAnon) = do
  env <- currentEnv
  conInfo <- case lookupRecordCon conName env of
    Just info -> pure info
    Nothing -> case lookupCon conName env of
      Just _  -> throwError (RecordConstructorNeedsBraces (Just pos) conName)
      Nothing -> throwError (UnknownCon (Just pos) conName)
  let declaredNames  = Set.fromList (map fst (rcFields conInfo))
      providedFields = [ (fname, fpat)
                       | Abs.RFPat (Abs.VarId (_, fname)) fpat <- fieldPats ]
      providedNames  = Set.fromList (map fst providedFields)
      extras         = Set.difference providedNames declaredNames
  unless (Set.null extras) $
    throwError (UnknownField (Just pos) conName (Set.findMin extras))
  paramSubst <- instantiateParamSubst (rcParams conInfo)
  rowEntries <- forM (rcFields conInfo) $ \(fname, fcty) -> do
    let declaredFieldT = substCTypeWith paramSubst fcty
    case lookup fname providedFields of
      Just p -> do
        (patT, patBinds, patNode) <- inferPat p
        unify (Just pos) patT declaredFieldT
        pure (fname, declaredFieldT, patBinds, patNode)
      Nothing -> pure (fname, declaredFieldT, [], Ty.Tpat declaredFieldT Ty.TPWild)
  rowVarTail <- freshRVar
  let row   = foldr (\(n, t, _, _) acc -> RowExtend n t acc) rowVarTail rowEntries
      patT  = TRecord conName row
      binds = concatMap (\(_, _, b, _) -> b) rowEntries
      nodes = map (\(_, _, _, n) -> n) rowEntries
  pure (patT, binds, Ty.Tpat patT (Ty.TPCon conName nodes))

-- Open record pattern with named row tail: deferred to v2.
inferAtomPat (Abs.PRecordOpen (Abs.ConId (pos, _)) _ (Abs.PRTNamed (Abs.VarId (_, binder)))) =
  throwError (NamedRowTailCaptureDeferred (Just pos) binder)

-- Wild record pattern with anonymous row tail: PRecordWild T { .. }
-- No fields are bound; produces an open row with fresh RowVar tail.
inferAtomPat (Abs.PRecordWild (Abs.ConId (pos, conName)) Abs.PRTAnon) = do
  env <- currentEnv
  conInfo <- case lookupRecordCon conName env of
    Just info -> pure info
    Nothing -> case lookupCon conName env of
      Just _  -> throwError (RecordConstructorNeedsBraces (Just pos) conName)
      Nothing -> throwError (UnknownCon (Just pos) conName)
  paramSubst <- instantiateParamSubst (rcParams conInfo)
  declaredEntries <- forM (rcFields conInfo) $ \(fname, fcty) -> do
    fieldT <- pure (substCTypeWith paramSubst fcty)
    pure (fname, fieldT)
  rowVarTail <- freshRVar
  let row  = foldr (\(n, t) acc -> RowExtend n t acc) rowVarTail declaredEntries
      patT = TRecord conName row
      nodes = map (\(_, t) -> Ty.Tpat t Ty.TPWild) declaredEntries
  pure (patT, [], Ty.Tpat patT (Ty.TPCon conName nodes))

-- Wild record pattern with named row tail: deferred to v2.
inferAtomPat (Abs.PRecordWild (Abs.ConId (pos, _)) (Abs.PRTNamed (Abs.VarId (_, binder)))) =
  throwError (NamedRowTailCaptureDeferred (Just pos) binder)

-- | Peel n argument types off a constructor function type, returning
-- (arg types, result type). The constructor type must have at least n arrows.
splitConType :: Type s -> Int -> TC s ([Type s], Type s)
splitConType ty 0 = pure ([], ty)
splitConType ty n = do
  ty' <- force ty
  case ty' of
    TArr a _ b -> do
      (args, res) <- splitConType b (n - 1)
      pure (a : args, res)
    _ -> error "splitConType: constructor type not deep enough"

-- ---------------------------------------------------------------------------
-- Expression inference
-- ---------------------------------------------------------------------------

-- | Parse an integer literal's textual form into its 'Integer' value.
readInt :: Text -> Integer
readInt t = read (Tx.unpack t)

-- | Infer the type of an expression. Returns the inferred Type s, discarding
-- the typed node (callers that need the typed AST use 'inferExprW' directly).
inferExpr :: Abs.Exp -> TC s (Type s)
inferExpr e = fst <$> inferExprW Map.empty e

-- | Type-infer an expression with an optional expected type. The expected
-- type informs bidirectional record construction: ERecord and ERecordExt
-- consult it to allow extra fields that match the expected row extension.
-- All other AST shapes fall back to pure inferExprW and ignore the hint.
inferExprWChecked :: Map.Map Text (Type s) -> Maybe (Type s) -> Abs.Exp -> TC s (Type s, TExprS s)
inferExprWChecked mono Nothing e = inferExprW mono e

-- ERecord with expected type: allow extra fields matching the expected
-- extension row (fields beyond the declared record fields).
inferExprWChecked mono (Just expected) (Abs.ERecord (Abs.ConId (pos, conName)) fieldExprs) = do
  env <- currentEnv
  conInfo <- case lookupRecordCon conName env of
    Just info -> pure info
    Nothing -> throwError (UnknownCon (Just pos) conName)
  -- Force the expected type; check if it's a TRecord with the same tag.
  expected' <- force expected
  case expected' of
    TRecord expTag expRow | expTag == conName -> do
      -- Collect extension labels: labels in the expected row beyond the
      -- declared fields. These are the extras the caller advertises.
      let declaredFields = rcFields conInfo
          declaredNames  = Set.fromList (map fst declaredFields)
      extLabels <- collectRowLabels expRow
      let extSet = Set.fromList extLabels `Set.difference` declaredNames
      -- Run the extended record inference.
      inferERecordWithExt pos conName conInfo fieldExprs extSet (Just expRow)
    _ ->
      -- Expected type is not a compatible TRecord: fall back to strict.
      inferExprW mono (Abs.ERecord (Abs.ConId (pos, conName)) fieldExprs)
  where
    inferERecordWithExt pos' conName' conInfo' fieldExprs' extSet mExpRow = do
      let declaredFields = rcFields conInfo'
          declaredNames  = Set.fromList (map fst declaredFields)
          allowedNames   = Set.union declaredNames extSet
          providedPairs  = [ (fname, fexp)
                           | Abs.RFExpr (Abs.VarId (_, fname)) fexp <- fieldExprs' ]
          providedNames  = Set.fromList (map fst providedPairs)
      -- Check: no extra fields beyond declared + extension.
      let extras = Set.difference providedNames allowedNames
      unless (Set.null extras) $
        throwError (UnknownField (Just pos') conName' (Set.findMin extras))
      -- Check: all declared fields provided.
      let missing = Set.difference declaredNames providedNames
      unless (Set.null missing) $
        throwError (UnknownField (Just pos') conName'
          (Tx.pack ("missing field: " <> Tx.unpack (Set.findMin missing))))
      -- Instantiate record type parameters.
      paramSubst <- instantiateParamSubst (rcParams conInfo')
      -- Infer + unify declared fields.
      declaredRowEntries <- forM declaredFields $ \(fname, fcty) -> do
        fieldT <- pure (substCTypeWith paramSubst fcty)
        let mExpr = lookup fname providedPairs
        case mExpr of
          Just e -> do
            (actualT, actualNode) <- inferExprW mono e
            unify (Just pos') actualT fieldT
            pure (fname, fieldT, actualNode)
          Nothing -> error "inferERecordWithExt: missing declared field not caught above"
      -- Infer + unify extension fields against the expected row.
      extRowEntries <- forM (filter (\(n, _) -> Set.member n extSet) providedPairs) $ \(fname, fexp) -> do
        extFieldT <- case mExpRow of
          Just expRow -> do
            -- Look up the expected type of this extension field from the
            -- expected row. If not found (shouldn't happen given extSet), use a fresh TVar.
            mft <- lookupRowLabel fname expRow
            case mft of
              Just ft -> pure ft
              Nothing -> freshTVar KStar
          Nothing -> freshTVar KStar
        (actualT, actualNode) <- inferExprW mono fexp
        unify (Just pos') actualT extFieldT
        pure (fname, extFieldT, actualNode)
      -- Build the result row: declared fields + extension fields.
      let allEntries = declaredRowEntries ++ extRowEntries
          row = foldr (\(l, t, _) acc -> RowExtend l t acc) RowEmpty allEntries
          fieldNodes = map (\(l, _, n) -> (l, n)) allEntries
          ty = TRecord conName' row
      pure (ty, Ty.Texp ty (Ty.TRecord conName' fieldNodes))

-- ERecordExt with expected type: allow trailing fields matching the expected
-- extension (beyond the spread source's declared row).
inferExprWChecked mono (Just expected) (Abs.ERecordExt (Abs.ConId (pos, conName)) spreadExpr mTrailing) = do
  env <- currentEnv
  conInfo <- case lookupRecordCon conName env of
    Nothing -> throwError (UnknownCon (Just pos) conName)
    Just ci -> pure ci
  -- Force expected type; if it's a TRecord with matching tag, extract its row.
  expected' <- force expected
  case expected' of
    TRecord expTag expRow | expTag == conName -> do
      -- Infer the spread type.
      (spreadT, spreadNode) <- inferExprW mono spreadExpr
      -- Constrain the spread to be TRecord conName with a fresh open row.
      -- This handles the case where the spread is still a TVar (e.g., a
      -- function parameter whose type is being inferred from the sig).
      spreadRowVar <- freshRVar
      let expectedSpreadT = TRecord conName spreadRowVar
      unify (Just pos) spreadT expectedSpreadT
      spreadT' <- force spreadT
      -- After unification, check nominal tag consistency.
      case spreadT' of
        TRecord tag _
          | tag == conName -> pure ()
          | otherwise -> throwError (NominalMismatch (Just pos) conName tag)
        _ -> do
          ct <- freeze spreadT'
          throwError (NotARecord (Just pos) ct)
      let spreadRow = case spreadT' of
            TRecord _ row -> row
            _             -> error "ERecordExt hint: spreadT' shape changed (impossible)"
      -- Use the declared fields from conInfo as the known "base" spread set.
      -- The spread must have at least these fields (nominally). Any trailing
      -- field that matches a declared field is an override; extras come from
      -- the expected extension row.
      let declaredNames = Set.fromList (map fst (rcFields conInfo))
      -- Collect extension labels from the expected row beyond declared fields.
      expLabels <- collectRowLabels expRow
      let extSet = Set.fromList expLabels `Set.difference` declaredNames
      -- Process trailing fields.
      let trailingPairs = case mTrailing of
            Abs.TFNone -> []
            Abs.TFSome rfs ->
              [ (fname, fexp)
              | Abs.RFExpr (Abs.VarId (_, fname)) fexp <- rfs ]
      -- Partition trailing into overrides (in spread/declared) and additions (in ext).
      (overrides, additions) <- partitionTrailing declaredNames extSet pos conName trailingPairs
      -- Verify overrides match the spread's row type.
      overrideNodes <- forM overrides $ \(fname, fexp) -> do
        (declaredT, _rest) <- rewriteRowStrict (Just pos) fname spreadRow
        (actualT, actualNode) <- inferExprW mono fexp
        unify (Just pos) actualT declaredT
        pure (fname, actualNode)
      -- Infer + unify additions against the expected extension row.
      extEntries <- forM additions $ \(fname, fexp) -> do
        extFieldT <- do
          mft <- lookupRowLabel fname expRow
          case mft of
            Just ft -> pure ft
            Nothing -> freshTVar KStar
        (actualT, actualNode) <- inferExprW mono fexp
        unify (Just pos) actualT extFieldT
        pure (fname, extFieldT, actualNode)
      -- Build result: spread row + extension fields appended.
      let resultRow = foldr (\(l, t, _) acc -> RowExtend l t acc) spreadRow extEntries
          extNodes = map (\(l, _, n) -> (l, n)) extEntries
          ty = TRecord conName resultRow
      pure (ty, Ty.Texp ty (Ty.TRecordExt conName spreadNode (overrideNodes ++ extNodes)))
    _ ->
      -- Not a compatible expected type: fall back to strict spread.
      inferExprW mono (Abs.ERecordExt (Abs.ConId (pos, conName)) spreadExpr mTrailing)

-- All other shapes: ignore the hint.
inferExprWChecked mono (Just _) e = inferExprW mono e

-- | Collect all label names from a (possibly open) row, stopping at RowEmpty
-- or RowVar. Used for extension-field detection.
collectRowLabels :: Row s -> TC s [Text]
collectRowLabels row = do
  row' <- force row
  case row' of
    RowExtend l _ r -> do
      rest <- collectRowLabels r
      pure (l : rest)
    _               -> pure []  -- RowEmpty or open tail (row var): no more labels

-- | Look up a single label in a row, returning its type if found.
lookupRowLabel :: Text -> Row s -> TC s (Maybe (Type s))
lookupRowLabel label row = do
  row' <- force row
  case row' of
    RowExtend l t r
      | l == label -> pure (Just t)
      | otherwise  -> lookupRowLabel label r
    _               -> pure Nothing  -- RowEmpty or open tail (row var)

-- | Split trailing fields into overrides (present in spread) and additions
-- (in extension set). Fields in neither produce UnknownField.
partitionTrailing
  :: Set.Set Text
  -> Set.Set Text
  -> (Int, Int)
  -> Text
  -> [(Text, Abs.Exp)]
  -> TC s ([(Text, Abs.Exp)], [(Text, Abs.Exp)])
partitionTrailing spreadSet extSet pos conName pairs =
  foldM step ([], []) pairs
  where
    step (ovs, adds) (fname, fexp)
      | Set.member fname spreadSet = pure ((fname, fexp) : ovs, adds)
      | Set.member fname extSet    = pure (ovs, (fname, fexp) : adds)
      | otherwise = throwError (UnknownField (Just pos) conName fname)

-- | Emit accumulator constraints for an instantiated identifier and choose the
-- typed node form. With no constraints, the node is the PLAIN form (@TVar@ /
-- @TParenOp@) -- byte-identical to non-class code. With constraints, every one
-- is recorded in the accumulator (for top-level discharge) and the node becomes
-- a 'TQVar' carrying the per-constraint class-argument types, which elaboration
-- lowers to dictionary passing.
emitQVar :: Text -> Ty.TexpF (Type s) -> [(Text, Type s)] -> TC s (Ty.TexpF (Type s))
emitQVar _    plain [] = pure plain
emitQVar name _     cs = do
  mapM_ (uncurry addConstraint) cs
  pure (Ty.TQVar name cs)

-- | 'emitQVar' specialised to the @TVar@ plain form (ordinary identifier).
emitQVarNode :: Text -> [(Text, Type s)] -> TC s (Ty.TexpF (Type s))
emitQVarNode name = emitQVar name (Ty.TVar name)

-- | 'emitQVar' specialised to the @TParenOp@ plain form (operator as value).
emitQParenOpNode :: Text -> [(Text, Type s)] -> TC s (Ty.TexpF (Type s))
emitQParenOpNode name = emitQVar name (Ty.TParenOp name)

-- Worker that carries a map of monomorphic (lambda/pattern) bindings.
-- These are looked up directly without instantiation, preserving the
-- identity of the mutable TVar across all uses in the expression.
inferExprW :: Map.Map Text (Type s) -> Abs.Exp -> TC s (Type s, TExprS s)
inferExprW _ (Abs.ELitI (Abs.WokInt (_, t))) =
  let ty = TCon TcU64 [] in pure (ty, Ty.Texp ty (Ty.TLitI (readInt t)))
inferExprW _ (Abs.ELitS s) =
  let ty = TCon TcString [] in pure (ty, Ty.Texp ty (Ty.TLitS (Tx.pack s)))
inferExprW _ (Abs.ELitC c) =
  let ty = TCon TcChar [] in pure (ty, Ty.Texp ty (Ty.TLitC c))
inferExprW _ Abs.EUnit =
  let ty = TCon TcUnit [] in pure (ty, Ty.Texp ty Ty.TUnit)
inferExprW mono (Abs.EVar (Abs.VarId (pos, name))) =
  case Map.lookup name mono of
    Just t -> pure (t, Ty.Texp t (Ty.TVar name))
    Nothing -> do
      env <- currentEnv
      case lookupVar name env of
        Just s -> do
          (t, cs) <- instantiateQ s
          node <- emitQVarNode name cs
          pure (t, Ty.Texp t node)
        Nothing -> throwError (UnknownVar (Just pos) name)
inferExprW _ (Abs.ECon (Abs.ConId (pos, name))) = do
  env <- currentEnv
  case lookupCon name env of
    Just info -> do
      t <- instantiate (conScheme info)
      pure (t, Ty.Texp t (Ty.TCon name))
    Nothing -> case lookupRecordCon name env of
      Just _  -> throwError (RecordConstructorNotAValue (Just pos) name)
      Nothing -> throwError (UnknownCon (Just pos) name)
inferExprW mono (Abs.EParen e) = inferExprW mono e
inferExprW mono (Abs.EParenOp (Abs.VarSym (pos, name))) =
  case Map.lookup name mono of
    Just t -> pure (t, Ty.Texp t (Ty.TParenOp name))
    Nothing -> do
      env <- currentEnv
      case lookupVar name env of
        Just s -> do
          (t, cs) <- instantiateQ s
          node <- emitQParenOpNode name cs
          pure (t, Ty.Texp t node)
        Nothing -> throwError (UnknownVar (Just pos) name)
inferExprW mono (Abs.EApp f x) = do
  -- Detect record constructor used in positional application and reject it.
  case f of
    Abs.ECon (Abs.ConId (pos, name)) -> do
      env <- currentEnv
      case lookupRecordCon name env of
        Just _  -> throwError (RecordConstructorNeedsBraces (Just pos) name)
        Nothing -> pure ()
    _ -> pure ()
  -- Collect the full application spine from this EApp.  Strip any surrounding
  -- EParen from the head.  If the head is a foreign-module projection, apply
  -- the saturation discipline HERE (at the outermost application node):
  --
  --   * under-saturated (length args < arity) => ForeignMemberPartialApp
  --     (compile error instead of a runtime crash).
  --   * exactly saturated (length args == arity) => type-check all args
  --     directly against the member's parameter types and return the result
  --     type + TProjCon node, bypassing per-step recursive descent so that
  --     intermediate EApp nodes are never passed to inferExprW individually
  --     (which would falsely re-trigger the arity check at each step).
  --   * over-applied (length args > arity) => fall through to the normal
  --     step-by-step path; the member's result type is never a function, so
  --     the surplus application becomes a unification type error.
  --
  -- For paren-wrapped heads like @(Libc.memchr) buf 65 3@, 'stripEParen'
  -- normalises the head before the pattern match.
  let (rawHead, allArgs) = collectExprSpine (Abs.EApp f x)
      strippedHead       = stripEParen rawHead
  case strippedHead of
    Abs.EProj (Abs.ECon (Abs.ConId (_, modName))) (Abs.VarId (mpos, label)) -> do
      env <- currentEnv
      -- Qualified-value access wins over foreign-module member resolution, so
      -- the `qualifier-wins` rule holds in application position exactly as it
      -- does for a bare projection (the EProj arm checks `lookupQualifier`
      -- first). When `modName` is a registered qualifier, skip the
      -- foreign-module interception and fall through to normal application;
      -- the head `modName.label` then resolves via the EProj qualifier arm.
      case lookupQualifier modName env of
        Just _  -> inferNormalApp mono f x
        Nothing ->
          case lookupForeignModule modName env of
            Just fmi ->
              case Map.lookup label (fmMembers fmi) of
                Nothing -> throwError (ForeignModuleMemberUnknown (Just mpos) modName label)
                Just minfo -> do
                  memberTy <- instantiate (fmiScheme minfo)
                  arity    <- arrowArity memberTy
                  let nArgs = length allArgs
                  case compare nArgs arity of
                    LT -> throwError (ForeignMemberPartialApp (Just mpos) modName label)
                    EQ -> inferForeignSaturatedCall mono modName label memberTy allArgs
                    GT ->
                      -- Over-applied: fall through to the normal per-step logic.
                      -- The member's return type is never a function, so the extra
                      -- application will produce a normal unification type error.
                      inferNormalApp mono f x
            Nothing -> inferNormalApp mono f x
    _ -> inferNormalApp mono f x
inferExprW mono (Abs.EIf c a b) = do
  (cT, cNode) <- inferExprW mono c
  (aT, aNode) <- inferExprW mono a
  (bT, bNode) <- inferExprW mono b
  unify (expPos c) cT (TCon TcBool [])
  unify (msum [expPos b, expPos a, expPos c]) aT bT
  pure (aT, Ty.Texp aT (Ty.TIf cNode aNode bNode))
inferExprW mono (Abs.ETuple a others) = do
  results <- mapM (inferExprW mono) (a : others)
  let ts = map fst results
      ns = map snd results
      ty = TCon (TcTuple (length ts)) ts
  pure (ty, Ty.Texp ty (Ty.TTuple ns))
inferExprW _ (Abs.EList []) = do
  e <- freshTVar KStar
  let ty = TCon TcList [e]
  pure (ty, Ty.Texp ty (Ty.TList []))
inferExprW mono (Abs.EList (x : xs)) = do
  (firstT, firstNode) <- inferExprW mono x
  restNodes <- mapM (\e -> do { (t, n) <- inferExprW mono e; unify (msum [expPos e, expPos x]) firstT t; pure n }) xs
  let ty = TCon TcList [firstT]
  pure (ty, Ty.Texp ty (Ty.TList (firstNode : restNodes)))
inferExprW mono (Abs.ELam atomPats body) = do
  patResults <- mapM inferAtomPat atomPats
  let paramTys = map (\(t, _, _) -> t) patResults
      patNodes = map (\(_, _, n) -> n) patResults
      binds = concatMap (\(_, b, _) -> b) patResults
      mono' = foldl' (\m (n, t) -> Map.insert n t m) mono binds
  -- A lambda is a function: the effects its body performs happen when the
  -- lambda is APPLIED, so they belong to the lambda's own (innermost) arrow,
  -- NOT to the enclosing equation. Install a fresh ambient, collect the body's
  -- effects there, close it (closed-by-default, like an equation), and ride it
  -- on the lambda's innermost arrow via 'arrowsWithEffect'. Without this the
  -- body's operation calls would leak into the enclosing equation's row and the
  -- lambda value would be typed as a pure arrow.
  ambient0 <- freshRVar
  effRef <- liftST (newSTRef ambient0)
  (bodyT, bodyNode) <- withEffRow effRef (inferExprW mono' body)
  ambient <- liftST (readSTRef effRef)
  closeRow ambient
  let ty = arrowsWithEffect paramTys bodyT ambient
  pure (ty, Ty.Texp ty (Ty.TLam patNodes bodyNode))
inferExprW mono (Abs.EExpr head_ tails) = do
  (hT, hNode) <- inferExprW mono head_
  applyTails hT hNode tails
  where
    applyTails t node [] = pure (t, node)
    applyTails fT lhsNode (Abs.ITail op rhs : rest) = do
      (opTy, opName, opCs) <- inferInfixOpW mono op
      (rhsT, rhsNode) <- inferExprW mono rhs
      r1 <- freshTVar KStar
      -- Carry the operator token's own position so a mismatched operand (e.g.
      -- @1 + "a"@) reports AT the operator rather than as a positionless
      -- 'Mismatch Nothing' (bug #13).
      unify (Just (infixOpPos op)) opTy (TArr fT RowEmpty (TArr rhsT RowEmpty r1))
      -- Mirror the resolved application `op lhs rhs` as a nested TApp whose
      -- head is the operator used as a value. r1 is the result type at this
      -- step; the running lhs node carries the accumulated chain. A constrained
      -- operator (e.g. `==`) emits its constraints and uses a 'TQVar' head; an
      -- unconstrained one keeps the byte-identical 'TVar' head.
      opNode <- emitQVar opName (Ty.TVar opName) opCs
      let appNode = Ty.Texp r1 (Ty.TApp (Ty.Texp opTy opNode) [lhsNode, rhsNode])
      applyTails r1 appNode rest
-- Operation invocation `E.op`: when the head is a constructor naming a
-- declared effect and @op@ is one of its operations, this is an operation
-- reference, not record-field access. Its type is the operation's scheme; it
-- contributes the effect @E@ to the enclosing equation's ambient row.
-- Foreign-module member access `M.mem` resolves via the foreign-module table
-- when the head is a declared foreign module (checked AFTER the effect arm so
-- effects take priority for unambiguous names; the ambiguity gate in
-- 'processForeignDecls' ensures a ConId cannot be both).
inferExprW mono (Abs.EProj headE@(Abs.ECon (Abs.ConId (_, ename))) (Abs.VarId (pos, label))) = do
  env <- currentEnv
  -- Qualified-value access: if `ename` is a registered import qualifier
  -- (e.g. `B` from `import Foo as B`, or `Foo` from a plain
  -- single-seg `import Foo`), resolve `label` against the source module's
  -- var schemes. Checked FIRST so the user's explicit qualifier registration
  -- wins over any same-named effect or foreign module (Q2: qualifier-wins,
  -- shadow warning emitted at pipeline time).
  case lookupQualifier ename env of
    Just (_srcMod, varSchemes) ->
      case Map.lookup label varSchemes of
        Just s -> do
          (t, cs) <- instantiateQ s
          node <- emitQVarNode (ename <> Tx.pack "." <> label) cs
          pure (t, Ty.Texp t node)
        Nothing -> throwError (UnknownVar (Just pos) (ename <> Tx.pack "." <> label))
    Nothing ->
      -- Operation invocation `E.op`: when the head is a constructor naming a
      -- declared effect and @op@ is one of its operations, this is an operation
      -- reference, not record-field access. Its type is the operation's scheme;
      -- it contributes the effect @E@ to the enclosing equation's ambient row.
      -- Foreign-module member access `M.mem` resolves via the foreign-module
      -- table when the head is a declared foreign module (checked AFTER the
      -- effect arm so effects take priority for unambiguous names; the
      -- ambiguity gate in 'processForeignDecls' ensures a ConId cannot be both).
      case lookupEffect ename env of
        Just eInfo
          | Just opScheme <- Map.lookup label (eiOps eInfo) -> do
              -- Instantiate the effect's parameters once; reuse the same
              -- substitution for the op's type AND the effect-row label's carried
              -- type, so e.g. `State a`'s `get : () -> a` ties `a` to the `State a`
              -- in the row.
              paramSubst <- instantiateParamSubst (eiParams eInfo)
              opTy <- freshenNeverResult (substCTypeWith paramSubst (schemeBody opScheme))
              let labelTy = effectPayloadTy (eiParams eInfo) paramSubst
              emitEffect (Just pos) ename labelTy
              pure (opTy, Ty.Texp opTy (Ty.TProjCon ename label))
          | otherwise -> throwError (UnknownOperation (Just pos) ename label)
        Nothing ->
          -- Not an effect: check the foreign-module table before falling through to
          -- the generic projection (record-field / named-perform) path.
          --
          -- NOTE: a bare foreign-member projection (not the direct function of an
          -- EApp) is REJECTED here. Foreign members are not closures; they must be
          -- used as the direct head of a saturated call. The EApp arm above
          -- intercepts `M.mem arg` and resolves the member type inline, bypassing
          -- this arm. Any other use (bare reference, let-binding, passing as an
          -- argument) reaches this arm and produces a clean typecheck error.
          case lookupForeignModule ename env of
            Just fmi ->
              case Map.lookup label (fmMembers fmi) of
                Nothing -> throwError (ForeignModuleMemberUnknown (Just pos) ename label)
                Just _  -> throwError (ForeignMemberPartialApp (Just pos) ename label)
            Nothing -> inferProjection mono headE pos label
inferExprW mono (Abs.EProj e (Abs.VarId (pos, label))) =
  inferProjection mono e pos label
inferExprW _ (Abs.EProjC _ (Abs.ConId (pos, _))) =
  throwError (UnsupportedFeature (Just pos)
    (Tx.pack "x.Y projection/module access not supported in v1"))

-- | Record construction: Point { x = 1, y = 2 }
-- Pure inference mode: strict — extra fields (not in the declared row) are
-- rejected. All declared fields must be provided.
inferExprW mono (Abs.ERecord (Abs.ConId (pos, conName)) fieldExprs) = do
  env <- currentEnv
  conInfo <- case lookupRecordCon conName env of
    Just info -> pure info
    Nothing -> throwError (UnknownCon (Just pos) conName)
  let declaredFields = rcFields conInfo
      declaredNames  = Set.fromList (map fst declaredFields)
      providedPairs  = [ (fname, fexp)
                       | Abs.RFExpr (Abs.VarId (_, fname)) fexp <- fieldExprs ]
      providedNames  = Set.fromList (map fst providedPairs)
  -- Check: no extra fields provided that are not in the declared row.
  let extras = Set.difference providedNames declaredNames
  unless (Set.null extras) $
    throwError (UnknownField (Just pos) conName (Set.findMin extras))
  -- Check: all declared fields provided.
  let missing = Set.difference declaredNames providedNames
  unless (Set.null missing) $
    throwError (UnknownField (Just pos) conName
      (Tx.pack ("missing field: " <> Tx.unpack (Set.findMin missing))))
  -- Instantiate the record's type parameters: each rcParams CTGen index
  -- maps to a fresh TVar.
  paramSubst <- instantiateParamSubst (rcParams conInfo)
  -- For each declared field: instantiate its CType, infer the provided
  -- expression, unify, and collect the row entry.
  rowEntries <- forM declaredFields $ \(fname, fcty) -> do
    fieldT <- pure (substCTypeWith paramSubst fcty)
    let mExpr = lookup fname providedPairs
    case mExpr of
      Just e -> do
        (actualT, actualNode) <- inferExprW mono e
        unify (Just pos) actualT fieldT
        pure (fname, fieldT, actualNode)
      Nothing -> error "ERecord: missing field not caught above (invariant violation)"
  let row = foldr (\(l, t, _) acc -> RowExtend l t acc) RowEmpty rowEntries
      fieldNodes = map (\(l, _, n) -> (l, n)) rowEntries
      ty = TRecord conName row
  pure (ty, Ty.Texp ty (Ty.TRecord conName fieldNodes))

-- | Record spread construction: Point { ..p } or Point { ..p, x = 99 }
-- The spread expression must be a TRecord with the same nominal tag.
-- Trailing fields override the corresponding fields from the spread.
-- In v1 (all spread sources have concrete rows), we look up each trailing
-- field in the spread's row via rewriteRowStrict and unify the types.
inferExprW mono (Abs.ERecordExt (Abs.ConId (pos, conName)) spreadExpr mTrailing) = do
  env <- currentEnv
  -- Validate the constructor is known as a record constructor.
  case lookupRecordCon conName env of
    Nothing -> throwError (UnknownCon (Just pos) conName)
    Just _  -> pure ()
  -- Infer the spread expression type.
  (spreadT, spreadNode) <- inferExprW mono spreadExpr
  spreadT' <- force spreadT
  -- The spread must be a TRecord with the same nominal tag.
  case spreadT' of
    TRecord tag _
      | tag == conName -> pure ()
      | otherwise -> throwError (NominalMismatch (Just pos) conName tag)
    _ -> do
      ct <- freeze spreadT'
      throwError (NotARecord (Just pos) ct)
  -- Extract trailing fields (if any).
  let trailingPairs = case mTrailing of
        Abs.TFNone -> []
        Abs.TFSome rfs ->
          [ (fname, fexp)
          | Abs.RFExpr (Abs.VarId (_, fname)) fexp <- rfs ]
  -- For each trailing field: look it up in the spread's row via
  -- rewriteRowStrict (concrete-row path, Task 4 guarantee), infer the
  -- provided expression's type, and unify against the declared field type.
  -- We use rewriteRowStrict so that any field not in the spread's row
  -- surfaces as UnknownField (strict override semantics).
  -- Extract the spread's row for field lookup.
  let spreadRow = case spreadT' of
        TRecord _ row -> row
        _             -> error "ERecordExt: spreadT' shape changed (impossible)"
  fieldNodes <- forM trailingPairs $ \(fname, fexp) -> do
    (declaredT, _rest) <- rewriteRowStrict (Just pos) fname spreadRow
    (actualT, actualNode) <- inferExprW mono fexp
    unify (Just pos) actualT declaredT
    pure (fname, actualNode)
  -- The result type is the spread's type: overrides don't change the
  -- nominal row for concrete-row spreads (all overriding fields must match
  -- the declared types, which we have just verified via unify above).
  pure (spreadT', Ty.Texp spreadT' (Ty.TRecordExt conName spreadNode fieldNodes))

inferExprW mono (Abs.ELet localDecls body) =
  -- A tuple/wildcard pattern bind `let (a, b) = e in ...` is non-recursive and
  -- has no place in the mutually-recursive named-group model. Desugar it to a
  -- `case` at the surface level, preserving source order: every decl before the
  -- first pattern bind forms a named let group; the pattern bind becomes a
  -- single-alternative case whose body is the let of the remaining decls + body.
  -- This reuses ALL existing case typing + elaboration machinery.
  case splitAtPatBind localDecls of
    Nothing ->
      inferLetGroup mono localDecls $ \m declNodes -> do
        (bodyT, bodyNode) <- inferExprW m body
        pure (bodyT, Ty.Texp bodyT (Ty.TLet declNodes bodyNode))
    Just (before, headPat, tailPats, rhs, after) -> do
      mapM_ checkComponentPat (headPat : tailPats)
      let tuplePat = Abs.APTuple headPat tailPats
          inner = case after of
                    [] -> body
                    _  -> Abs.ELet after body
          caseE = Abs.ECase rhs [Abs.AltC (Abs.PAtom tuplePat) inner Abs.NoWhere]
          -- Splitting `before` into its own outer (non-recursive) ELet is sound
          -- because this branch does not support mutual recursion across
          -- sequential `let ... in let ...`: a `before` decl can only refer
          -- forward to a later decl via nesting, which the split preserves, so
          -- partitioning the group around the (non-recursive) pat-bind does not
          -- change scoping.
          rebuilt = case before of
                      [] -> caseE
                      _  -> Abs.ELet before caseE
      inferExprW mono rebuilt
inferExprW mono (Abs.ECase scrutinee alts) = do
  (sT, sNode) <- inferExprW mono scrutinee
  rT <- freshTVar KStar
  -- Check coverage BEFORE inferring alts: the strict-pattern alts will
  -- unify the scrutinee's row variable to RowEmpty, destroying the open-tail
  -- information we need for the non-exhaustive warning.
  checkRecordPatternCoverage (expPos scrutinee) sT alts
  altNodes <- mapM (inferAlt mono sT rT) alts
  pure (rT, Ty.Texp rT (Ty.TCase sNode altNodes))
-- Handler: `with { E.op args -> body ... ; v -> r } EXPR`.
-- v1 (transparent operations, no resume): infer EXPR under a fresh sub-ambient
-- effect row; the handled effects are those named by the arm heads; every
-- operation of each handled effect must have an arm (coverage); each arm body
-- has the operation's RESULT type and is checked under the OUTER ambient (so an
-- arm may itself perform effects -- effect translation); the optional value
-- arm (a bare pattern `v -> r`) transforms the final value. The result effect
-- row is EXPR's effects minus the handled ones, joined into the enclosing
-- ambient.
inferExprW mono (Abs.EWith arms e) = inferHandler mono [] Nothing e arms
inferExprW mono (Abs.EWithH (Abs.ConId (hpos, h)) hs arms e) =
  inferHandler mono (h : [ n | Abs.ConId (_, n) <- hs ]) (Just hpos) e arms
-- Runner sugar `with <runner> <args> in <body>` (slice 4a). This is a pure
-- desugar: `with f a b in body` ≡ `f a b (\_ -> body)`. We build the surface
-- application and elaborate it via the existing application/lambda path so all
-- typing and elaboration is reused.
inferExprW mono (Abs.EWithRun fVar wargs body) =
  let runner = foldl (\acc warg -> Abs.EApp acc (withArgExp warg)) (Abs.EVar fVar) wargs
      thunk  = Abs.ELam [Abs.APWild] body
  in inferExprW mono (Abs.EApp runner thunk)
  where withArgExp (Abs.WRArg e) = e
-- Named-instance introduction forms (named effect instances feature). The
-- grammar (Task 1) parses these into EWithNamed / EWithNamedH; their type
-- checking, elaboration, and runtime are added in later tasks. Until then,
-- reject them explicitly so the surface parses but does not silently mistype.
-- Named-instance runner sugar: `with name = fVar wargs in body`. Like
-- 'EWithRun' (`with f a b in body ≡ f a b (\_ -> body)`) but binds the runner's
-- thunk parameter to NAME instead of `_`. The runner's thunk parameter is the
-- effect-instance handle (e.g. `State s`), so `name.op` in the body dispatches
-- as a named perform (see 'inferProjection').
inferExprW mono (Abs.EWithNamed (Abs.VarId (npos, name)) fVar wargs body) = do
  -- Build and infer the runner application `fVar wargs` (NOT yet applied to a
  -- thunk). We must NOT desugar to a raw `runner (\name -> body)` and re-infer
  -- bottom-up: that leaves `name`'s type an unsolved metavar while `name.op` is
  -- dispatched, so the type-directed dot ('inferProjection') reports
  -- 'AmbiguousAccessor'. Instead we drive checking-mode by hand: read the
  -- runner's thunk parameter type to learn the instance HANDLE type, bind
  -- `name : handleTy` BEFORE inferring the body, then rebuild the typed node as
  -- the application `runner (\name -> body)` so elaboration is unchanged.
  let withArgExp (Abs.WRArg ex) = ex
      runnerE = foldl (\acc warg -> Abs.EApp acc (withArgExp warg)) (Abs.EVar fVar) wargs
  (runnerT, runnerNode) <- inferExprW mono runnerE
  runnerT' <- force runnerT
  case runnerT' of
    TArr thunkTy appRow resultTy -> do
      thunkTy' <- force thunkTy
      case thunkTy' of
        TArr handleTy bodyRow bodyResultTy -> do
          -- Bind the instance handle and infer the body under a fresh sub-ambient
          -- (mirroring 'ELam'): the body's performed effects must flow into the
          -- runner's declared thunk row (`bodyRow`, e.g. `State s + eff e`),
          -- NOT into the enclosing equation. We unify the collected sub-ambient
          -- with `bodyRow` rather than closing it to empty, so the runner's
          -- declared effects (the handled effect + the residual `eff e`) are
          -- honoured.
          let mono' = Map.insert name handleTy mono
          ambient0 <- freshRVar
          effRef <- liftST (newSTRef ambient0)
          (bodyT, bodyNode) <- withEffRow effRef (inferExprW mono' body)
          bodyAmbient <- liftST (readSTRef effRef)
          unifyRow Nothing bodyAmbient bodyRow
          unify Nothing bodyT bodyResultTy
          -- The runner's own effects (whatever calling `runner` performs, e.g.
          -- the residual `eff e`) propagate into the enclosing ambient, mirroring
          -- the application path ('EApp'). Any CONCRETE label still records via
          -- 'emitEffect'; appRow's own bare TAIL is the runner-thunk's sub-ambient
          -- leftover (unified into `bodyRow` above, a fresh var that closes with
          -- the runner) -- an open tail carries no concrete label, so 'emitRow'
          -- drops it.
          emitRow Nothing appRow
          -- Rebuild the typed node as `runner (\name -> body)` so Task 4's
          -- TApp/TLam lowering is reused verbatim; the lambda binder carries
          -- `name : handleTy`, and `bodyNode` already holds the correctly
          -- dispatched 'TPerformOn' nodes.
          let nameBinder = Ty.Tpat handleTy (Ty.TPVar name)
              lamNode    = Ty.Texp thunkTy (Ty.TLam [nameBinder] bodyNode)
              node       = Ty.Texp resultTy (Ty.TApp runnerNode [lamNode])
          pure (resultTy, node)
        _ -> throwError (UnsupportedFeature (Just npos)
               ("`with " <> name <> " = ...`: runner's thunk parameter is not a function (expected a thunk taking the instance handle)"))
    _ -> throwError (UnsupportedFeature (Just npos)
           ("`with " <> name <> " = ...`: runner is not a function (it must take a thunk)"))
-- Named primitive handler: `with self = Effect { arms } in body`. This is the
-- handler machinery of 'inferHandler' PLUS binding `self` to the effect-handle
-- type in the body's scope, so `self.op` performs on this handler instance.
inferExprW mono (Abs.EWithNamedH selfV effCon arms body) =
  inferNamedHandler mono selfV effCon arms body
inferExprW mono (Abs.EHandlerV effCon arms) =
  inferHandlerValue mono effCon arms
-- Both install forms carry the handler as HEAD + ATOM ARGS (the EWithRun
-- application sugar); rebuild the plain application before inferring.
inferExprW mono (Abs.EHandleV hExpr wargs body) =
  inferHandleValue mono (rebuildWithArgs hExpr wargs) body
inferExprW mono (Abs.EHandleN selfV hExpr wargs body) =
  inferHandleNamedValue mono selfV (rebuildWithArgs hExpr wargs) body

-- | Type-check a single-step application @f x@ using the standard arrow
-- unification path. Extracted from 'inferExprW (EApp f x)' so that the
-- foreign-call spine intercept can delegate here for non-foreign heads and
-- over-applied foreign heads.
inferNormalApp :: Map.Map Text (Type s) -> Abs.Exp -> Abs.Exp -> TC s (Type s, TExprS s)
inferNormalApp mono f x = do
  (fT, fNode) <- inferExprW mono f
  (xT, xNode) <- inferExprW mono x
  rT     <- freshTVar KStar
  effRow <- freshRVar
  unify (expPos (Abs.EApp f x)) fT (TArr xT effRow rT)
  emitRow Nothing effRow
  closeRow effRow
  let node = case fNode of
        Ty.Texp _ (Ty.TApp h args) -> Ty.TApp h (args ++ [xNode])
        _                          -> Ty.TApp fNode [xNode]
  pure (rT, Ty.Texp rT node)

-- | Type-check a foreign member call where the full arg list is exactly
-- saturated (length args == arity of the member type). Each arg is inferred
-- and unified against the corresponding parameter type; the effect row of
-- each arrow slot is emitted into the ambient row (so @with IO@ propagates).
-- Returns the member's result type and a @TApp (TProjCon modName label) argNodes@
-- typed node, matching the shape the elaborator's 'elabRhsF (TApp hd args)' arm
-- expects.
inferForeignSaturatedCall
  :: Map.Map Text (Type s)
  -> Text -> Text
  -> Type s
  -> [Abs.Exp]
  -> TC s (Type s, TExprS s)
inferForeignSaturatedCall mono modName label memberTy args = do
  let headNode = Ty.Texp memberTy (Ty.TProjCon modName label)
  (resultTy, argNodes) <- go memberTy args
  let appNode = Ty.Texp resultTy (Ty.TApp headNode argNodes)
  pure (resultTy, appNode)
  where
    go ty [] = pure (ty, [])
    go ty (arg : rest) = do
      (argT, argNode) <- inferExprW mono arg
      rT     <- freshTVar KStar
      effRow <- freshRVar
      unify (expPos arg) ty (TArr argT effRow rT)
      emitRow Nothing effRow
      closeRow effRow
      (finalTy, restNodes) <- go rT rest
      pure (finalTy, argNode : restNodes)

-- | Classification of a single handler arm against the (possibly empty) header.
-- An unqualified arm is resolved to either an operation arm (when its head names
-- an operation of a header effect) or a value/return arm (when it has no
-- arguments and matches no operation name).
data ArmClass
  = OpArmC Bool Text Text [Abs.AtomPat] Abs.Exp (Int, Int)
      -- ^ Bool: DECLARED control arm (`once`); the last binder is the
      -- continuation. Plain arms auto-resume and bind exactly the op's arity.
  | ValArmC Text Abs.Exp (Int, Int)
  | ParamArmC Text Abs.Exp (Int, Int)   -- slice 4a: handler-local param `name = init`

classifyArm :: Env -> [Text] -> Abs.HandlerArm -> TC s ArmClass
classifyArm env header arm = case arm of
  Abs.HArm (Abs.ConId (pos, en)) (Abs.VarId (_, op)) ps body -> do
    unless (null header || en `elem` header) $
      throwError (HandlerEffectNotInHeader (Just pos) en)
    pure (OpArmC False en op ps body pos)
  -- `once` control arm (retrofit): the clause kind is DECLARED, not counted.
  Abs.HOnceArm (Abs.ConId (pos, en)) (Abs.VarId (_, op)) ps body -> do
    unless (null header || en `elem` header) $
      throwError (HandlerEffectNotInHeader (Just pos) en)
    pure (OpArmC True en op ps body pos)
  Abs.HUArm (Abs.VarId (pos, name)) ps body ->
    -- Resolve an unqualified arm against the header effects. A bare
    -- `name -> e` that names no operation is NO LONGER a value arm: value
    -- arms are written with the `return` keyword (HRetArm). The old silent
    -- classification is the S-collapse family this retrofit closes.
    case [ en | en <- header, declaresOp env en name ] of
      [en] -> pure (OpArmC False en name ps body pos)
      []   -> if null ps
                then throwError (ValueArmNeedsReturn (Just pos) name)
                else throwError (UnknownUnqualifiedOp (Just pos) name)
      ens  -> throwError (HandlerOpAmbiguous (Just pos) name ens)
  Abs.HOnceUArm (Abs.VarId (pos, name)) ps body ->
    case [ en | en <- header, declaresOp env en name ] of
      [en] -> pure (OpArmC True en name ps body pos)
      []   -> throwError (UnknownUnqualifiedOp (Just pos) name)
      ens  -> throwError (HandlerOpAmbiguous (Just pos) name ens)
  -- `return` value arm: binder must be a plain variable (patterns in return
  -- position are v2's D14, not carried by this retrofit).
  Abs.HRetArm bpat body -> case bpat of
    Abs.APVar (Abs.VarId (pos, v)) -> pure (ValArmC v body pos)
    _                              -> throwError (ReturnArmBinderNotVar (atomPatPos bpat))
  -- Handler-local parameter `name = init` (slice 4a). Bind `name` at a fresh
  -- type sigma in scope of every arm and the value arm; `init` is checked at
  -- sigma; control arms see `resume : sigma -> T -> R`.
  -- Bare `name = init` handler state is rejected: it must be written `var name
  -- = init`. (`initExp` is ignored — the binder never reaches elaboration.)
  Abs.HParam (Abs.VarId (pos, name)) _initExp ->
    throwError (BareHandlerParam (Just pos) name)
  -- `var name = init`: the accepted handler-local state form.
  Abs.HParamV (Abs.VarId (pos, name)) initExp ->
    pure (ParamArmC name initExp pos)
  where
    declaresOp e en op = case lookupEffect en e of
      Just eInfo -> Map.member op (eiOps eInfo)
      Nothing    -> False

-- | E-SHADOW (strict; once/return retrofit): the first position at which the
-- given name is RE-BOUND inside an expression -- by a lambda binder, a
-- let-local equation head or argument pattern, a case/let-pattern binder, an
-- as-pattern, a named-instance binder, a nested handler's arm binders, or a
-- nested handler param. Deliberately stricter than liveness ("shadowed while
-- unconsumed"): ANY rebinding of a continuation's name inside its arm is an
-- error, delimited or not -- `(let k = f in k (k 1))` is the S2 silence with
-- parentheses. Every constructor is matched without a catch-all so grammar
-- growth surfaces here as an incomplete-pattern warning.
shadowsName :: Text -> Abs.Exp -> Maybe (Int, Int)
shadowsName nm = goE
  where
    goE e = case e of
      Abs.EExpr e0 tails    -> goE e0 `orElse` firstJust [ goE t | Abs.ITail _ t <- tails ]
      Abs.EApp f a          -> goE f `orElse` goE a
      Abs.EVar _            -> Nothing
      Abs.ECon _            -> Nothing
      Abs.EProj e0 _        -> goE e0
      Abs.EProjC e0 _       -> goE e0
      Abs.ERecord _ fs      -> firstJust [ goE x | Abs.RFExpr _ x <- fs ]
      Abs.ERecordExt _ e0 t -> goE e0 `orElse` goTrail t
      Abs.ELitI _           -> Nothing
      Abs.ELitS _           -> Nothing
      Abs.ELitC _           -> Nothing
      Abs.EParen e0         -> goE e0
      Abs.EParenOp _        -> Nothing
      Abs.EUnit             -> Nothing
      Abs.EList es          -> firstJust (map goE es)
      Abs.ETuple e0 es      -> goE e0 `orElse` firstJust (map goE es)
      Abs.ELam ps e0        -> firstJust (map goAP ps) `orElse` goE e0
      Abs.ELet ds e0        -> firstJust (map goLD ds) `orElse` goE e0
      Abs.ECase e0 alts     -> goE e0 `orElse` firstJust (map goAlt alts)
      Abs.EIf a b c         -> goE a `orElse` goE b `orElse` goE c
      Abs.EWith arms e0           -> firstJust (map goArm arms) `orElse` goE e0
      Abs.EWithH _ _ arms e0      -> firstJust (map goArm arms) `orElse` goE e0
      Abs.EWithRun _ args e0      -> firstJust [ goE x | Abs.WRArg x <- args ] `orElse` goE e0
      Abs.EWithNamed v _ args e0  -> goV v `orElse` firstJust [ goE x | Abs.WRArg x <- args ] `orElse` goE e0
      Abs.EWithNamedH v _ arms e0 -> goV v `orElse` firstJust (map goArm arms) `orElse` goE e0
      Abs.EHandlerV _ arms        -> firstJust (map goArm arms)
      Abs.EHandleV h args e0      -> goE h `orElse` firstJust [ goE x | Abs.WRArg x <- args ] `orElse` goE e0
      Abs.EHandleN v h args e0    -> goV v `orElse` goE h `orElse` firstJust [ goE x | Abs.WRArg x <- args ] `orElse` goE e0
    goTrail t = case t of
      Abs.TFNone    -> Nothing
      Abs.TFSome fs -> firstJust [ goE x | Abs.RFExpr _ x <- fs ]
    goArm a = case a of
      Abs.HArm _ _ ps b     -> firstJust (map goAP ps) `orElse` goE b
      Abs.HUArm _ ps b      -> firstJust (map goAP ps) `orElse` goE b
      Abs.HOnceArm _ _ ps b -> firstJust (map goAP ps) `orElse` goE b
      Abs.HOnceUArm _ ps b  -> firstJust (map goAP ps) `orElse` goE b
      Abs.HRetArm p b       -> goAP p `orElse` goE b
      Abs.HParam v e0       -> goV v `orElse` goE e0
      Abs.HParamV v e0      -> goV v `orElse` goE e0
    goAlt (Abs.AltC p b wh) = goP p `orElse` goE b `orElse` goWh wh
    goWh w = case w of
      Abs.NoWhere   -> Nothing
      Abs.WithWh ds -> firstJust (map goLD ds)
    goLD d = case d of
      Abs.LDEqn lhs e0 wh -> goLHS lhs `orElse` goE e0 `orElse` goWh wh
      Abs.LDSig {}        -> Nothing
      Abs.LDPat p ps e0   -> goP p `orElse` firstJust (map goP ps) `orElse` goE e0
    goLHS l = case l of
      Abs.LHSPre fn ps    -> goFN fn `orElse` firstJust (map goAP ps)
      Abs.LHSInfSym a _ b -> goAP a `orElse` goAP b
      Abs.LHSInfBT a v b  -> goAP a `orElse` goV v `orElse` goAP b
    goFN f = case f of
      Abs.FNBare v -> goV v
      Abs.FNBareSym _ -> Nothing
      Abs.FNParen _   -> Nothing
    goP p = case p of
      Abs.PApp _ a as -> goAP a `orElse` firstJust (map goAP as)
      Abs.PCons a p2  -> goAP a `orElse` goP p2
      Abs.PAtom a     -> goAP a
    goAP ap = case ap of
      Abs.APVar v            -> goV v
      Abs.APCon _            -> Nothing
      Abs.APWild             -> Nothing
      Abs.APLitI _           -> Nothing
      Abs.APLitS _           -> Nothing
      Abs.APLitC _           -> Nothing
      Abs.APTuple p ps       -> goP p `orElse` firstJust (map goP ps)
      Abs.APList ps          -> firstJust (map goP ps)
      Abs.APParen p          -> goP p
      Abs.PUnit              -> Nothing
      Abs.APAs a v           -> goAP a `orElse` goV v
      Abs.PRecord _ fs       -> firstJust [ goP q | Abs.RFPat _ q <- fs ]
      Abs.PRecordOpen _ fs t -> firstJust [ goP q | Abs.RFPat _ q <- fs ] `orElse` goTail t
      Abs.PRecordWild _ t    -> goTail t
    goTail t = case t of
      Abs.PRTNamed v -> goV v
      Abs.PRTAnon    -> Nothing
    goV (Abs.VarId (p, n)) = if n == nm then Just p else Nothing
    orElse (Just x) _ = Just x
    orElse Nothing  y = y

-- | Does the typed expression reference the given (surface) variable name?
-- Conservative (shadowing ignored -> only ever suppresses the lint, never a
-- false positive). Used by the forgotten-resume lint. Example of the accepted
-- false negative: `State.get k -> \k -> k 0` reports k as referenced (the inner
-- lambda's k matches), suppressing a warning the outer k arguably deserves. That
-- trade is deliberate: we prefer a missed warning to nagging valid code.
texpMentions :: Text -> Ty.Texp a -> Bool
texpMentions name = goE
  where
    goE (Ty.Texp _ f) = goF f
    goF f = case f of
      Ty.TVar n            -> n == name
      Ty.TQVar n _         -> n == name
      Ty.TParenOp _        -> False
      Ty.TLitI _           -> False
      Ty.TLitS _           -> False
      Ty.TLitC _           -> False
      Ty.TUnit             -> False
      Ty.TCon _            -> False
      Ty.TProjCon _ _      -> False
      Ty.TApp h xs         -> goE h || any goE xs
      Ty.TLam _ b          -> goE b
      Ty.TIf a b c         -> goE a || goE b || goE c
      Ty.TTuple xs         -> any goE xs
      Ty.TList xs          -> any goE xs
      Ty.TProj e _         -> goE e
      Ty.TPerformOn e _ _  -> goE e
      Ty.TRecord _ fs      -> any (goE . snd) fs
      Ty.TRecordExt _ e fs -> goE e || any (goE . snd) fs
      Ty.TLet ds b         -> any goD ds || goE b
      Ty.TCase e alts      -> goE e || any goA alts
      Ty.THandle e arms    -> goE e || any goArm arms
      Ty.TWithNamedH _ arms e -> any goArm arms || goE e
      Ty.THandlerV _ arms  -> any goArm arms
      Ty.THandleV h b      -> goE h || goE b
      Ty.THandleNV _ h b   -> goE h || goE b
    goD (Ty.TLocalDecl _ _ b)   = goE b
    goA (Ty.TAlt _ ds b)        = any goD ds || goE b
    goArm (Ty.TReturnArm _ b)   = goE b
    goArm (Ty.TOpArm _ _ _ _ _ b) = goE b
    goArm (Ty.TParamArm _ b)    = goE b

-- | The continuation type for an op-arm @resume@ binder: @T -> R@, or
-- @sigma -> T -> R@ for a parameterized handler (@sigma@ = parameter type, @T@ =
-- op result, @R@ = handler answer). Each arrow carries a fresh OPEN effect row so
-- that applying @resume@ in the body flows its effects into the outer ambient
-- (mirroring ordinary application; see EApp). The leading @paramRow@ is allocated
-- ONLY for a parameterized handler (no wasted metavar otherwise).
--
-- Threaded onto 'Ty.TOpArm' (every arm shape, both handler forms) so the
-- elaborator types @resume@ as the (always-boxed) arrow it is rather than the
-- answer type R; an unboxed R would mis-mark the continuation as unboxed and the
-- Perceus pass would omit its drop on a discard arm, leaking the captured owned
-- set (spec docs/superpowers/specs/2026-06-19-m2b-resume-binder-type-leak-fix).
-- Shared by 'inferHandler' (ambient) and 'inferNamedHandler' (named).
-- The continuation's effect rows (the resume row, plus the param row for a
-- two-arg parameterized resume) are minted as fresh OPEN vars: an arm body
-- that invokes @resume@ performs whatever the resumed tail performs, and the
-- open rows absorb it during arm checking. No emit-site bookkeeping guards
-- these rows any more -- the rung-era plumbing-exempt set was deleted with
-- the rest of that apparatus (b1e3a26); a residual laundered through a
-- TRAPPED signature var is now caught later, at reconciliation, by the
-- rigid-skolem clash ('freezeSigSkolems'/'reconcileDeclared').
resumeContTyFor :: Maybe (Type s) -> Type s -> Type s -> TC s (Type s)
resumeContTyFor mParamTy resultTy answerT = do
  resumeRow <- freshRVar
  case mParamTy of
    Just paramTy -> do
      paramRow <- freshRVar
      pure (arrowT paramTy paramRow (arrowT resultTy resumeRow answerT))
    Nothing -> pure (arrowT resultTy resumeRow answerT)

inferHandler :: Map.Map Text (Type s) -> [Text] -> Maybe (Int, Int) -> Abs.Exp -> [Abs.HandlerArm] -> TC s (Type s, TExprS s)
inferHandler mono header headerPos e arms = do
  env <- currentEnv
  -- A handler with no arms handles nothing; reject rather than silently
  -- producing an identity handler.
  when (null arms) $ throwError (EmptyHandler headerPos)
  -- An UNDECLARED header effect must be reported here, at the header, BEFORE
  -- any arm is classified. Classification resolves an unqualified arm head by
  -- asking each header effect whether it declares that operation; an effect
  -- that is not declared at all answers "no" to everything, so a perfectly
  -- ordinary arm like `ask -> 0` under `with Bogus { ... }` would be blamed as
  -- a value arm needing `return` -- the header's fault reported against the
  -- arm. 'inferNamedHandler' already resolves its single effect before
  -- classifying; this is the headed-ambient path catching up.
  forM_ header $ \en ->
    case lookupEffect en env of
      Nothing -> throwError (MissingEffectDecl headerPos en)
      Just _  -> pure ()
  -- Classify each arm against the header into an operation arm or a value arm.
  classified <- mapM (classifyArm env header) arms
  let opArms    = [ (isO, en, op, ps, body, pos) | OpArmC isO en op ps body pos <- classified ]
      retArms   = [ (pos, v, body)               | ValArmC v body pos           <- classified ]
      paramArms = [ (name, initE, pos)           | ParamArmC name initE pos     <- classified ]
  -- At most one `return` arm is allowed; reject a second rather than silently
  -- ignoring it.
  case retArms of
    (_ : (pos2, _, _) : _) -> throwError (DuplicateReturnArm (Just pos2))
    _                      -> pure ()
  rejectDuplicateOpArms opArms
  -- Infer the handled expression under a fresh sub-ambient row so we can see
  -- exactly which effects it performs.
  subAmbient0 <- freshRVar
  subRef <- liftST (newSTRef subAmbient0)
  (exprT, exprNode) <- withEffRow subRef (inferExprW mono e)
  -- Allocate the handler answer type R up front: binder arms type their bodies
  -- at R and bind `resume : T -> R`, and the value/return arm produces R. A
  -- single shared metavar ties all of them together.
  answerT <- freshTVar KStar
  -- Handler-local parameter (slice 4a): at most one `name = init` entry. Bind
  -- `name` at a fresh type sigma; check `init : sigma`. The init seed is typed
  -- under `mono` (it does NOT see the parameter name). The parameter name is
  -- threaded via `monoP` into every op arm and the value arm.
  mParam <- case paramArms of
    []                 -> pure Nothing
    [(name, initE, _)] -> do
      paramTy <- freshTVar KStar
      (initT, initNode) <- inferExprW mono initE
      unify Nothing initT paramTy
      pure (Just (name, paramTy, initNode))
    (_ : (_, _, p2) : _) -> throwError (DuplicateHandlerParam (Just p2))
  let monoP = case mParam of
        Just (name, ty, _) -> Map.insert name ty mono
        Nothing            -> mono
  -- The handled effects: when a header is present it is the authoritative
  -- "exactly these effects" set (so missing arms are coverage errors); without
  -- a header, the distinct effect names mentioned by arm heads.
  let handledEffects = if null header
                         then Data.List.nub [ en | (_, en, _, _, _, _) <- opArms ]
                         else header
  -- Coverage: every operation of each handled effect must have an arm.
  forM_ handledEffects $ \en ->
    case lookupEffect en env of
      Nothing -> do
        let armPos = case opArms of ((_, _, _, _, _, p) : _) -> Just p; [] -> Nothing
        throwError (MissingEffectDecl (maybe armPos Just headerPos) en)
      Just eInfo -> do
        when (isGroundIO en eInfo) $
          throwError (IOEffectNotHandleable headerPos)
        let declaredOps = Map.keys (eiOps eInfo)
            handledOps  = [ op | (_, en', op, _, _, _) <- opArms, en' == en ]
            missing     = [ op | op <- declaredOps, op `notElem` handledOps ]
        unless (null missing) $ do
          -- Prefer a matching op-arm position; for a header effect with no arm
          -- at all, fall back to the header position.
          let pos = case [ p | (_, en', _, _, _, p) <- opArms, en' == en ] of
                      (p : _) -> Just p
                      []      -> headerPos
          throwError (HandlerCoverage pos en missing)
  -- Type each operation arm: bind its argument patterns to the op's argument
  -- types and check its body against the op's RESULT type. Arm bodies run under
  -- the OUTER ambient (the current one), so effects performed inside an arm
  -- (effect translation) flow to the enclosing computation.
  -- The arm-typing loop itself is 'inferOpArmNode' -- the SINGLE source shared
  -- with the named and value paths (review round: it existed three times).
  -- What stays here is this ambient path's own discipline: resolve the
  -- effect PER ARM (multi-effect headers) and instantiate its params PER ARM
  -- (fresh, not shared -- the named/value paths share one substitution
  -- instead, tying arms to an exposed handle/Handler type).
  opArmNodes <- forM opArms $ \arm@(_, en, _, _, _, pos) ->
    case lookupEffect en env of
      Nothing -> throwError (MissingEffectDecl (Just pos) en)
      Just eInfo -> do
        paramSubst <- instantiateParamSubst (eiParams eInfo)
        inferOpArmNode eInfo paramSubst monoP
          (fmap (\(_, paramTy, _) -> paramTy) mParam) answerT arm
  -- Discharge the handled effects from the handled expression's row, leaving
  -- the residual effects to flow outward. Any CONCRETE unhandled label still
  -- surfaces via 'emitEffect' as normal; the residual's own bare TAIL is the
  -- handler's sub-ambient leftover -- a fresh var that closes with the handler --
  -- and, being an open tail with no concrete label, is dropped by 'emitRow'.
  subRow <- liftST (readSTRef subRef)
  residual <- dischargeEffects subRow handledEffects
  emitRow Nothing residual
  -- A parameter arm, when present, is emitted into the typed arm list so the
  -- elaborator (Task 4) can see the seed. It is inert at the type level here.
  let paramArmNodes = case mParam of
        Just (name, _, initNode) -> [Ty.TParamArm name initNode]
        Nothing                  -> []
  -- Apply the optional value arm to compute the handler's answer type R.
  case retArms of
    []               -> do
      -- No value arm: the return clause is the identity, so the answer type is
      -- exactly the handled value's type.
      unify Nothing answerT exprT
      pure (answerT, Ty.Texp answerT (Ty.THandle exprNode (paramArmNodes ++ opArmNodes)))
    ((_, v, rb) : _) -> do
      let mono' = Map.insert v exprT monoP
      (rT, rNode) <- inferExprW mono' rb
      -- The value arm binds the handled value @v@ (type exprT) and transforms
      -- it to the answer type R; represent the binder as a variable pattern
      -- annotated with exprT.
      unify Nothing rT answerT
      let retArm = Ty.TReturnArm (Ty.Tpat exprT (Ty.TPVar v)) rNode
      pure (answerT, Ty.Texp answerT (Ty.THandle exprNode (paramArmNodes ++ opArmNodes ++ [retArm])))

-- | Infer a named primitive handler `with self = Effect { arms } in body`.
--
-- This is the operation-arm machinery of 'inferHandler' specialised to a SINGLE
-- effect, PLUS binding @self@ to that effect's instance-handle type in the
-- body's scope. Two differences from 'inferHandler' make the param-tying sound:
--
--   * ONE shared parameter substitution. 'inferHandler' instantiates the
--     effect's params freshly per op arm; here we instantiate ONCE and reuse it
--     for every arm AND for the handle type @self : TcEffect Effect <params>@,
--     so @self.op@ (a named perform; see 'inferProjection') ties to the same
--     @s@ the arms handle. A wrong tie here would silently mis-thread the state
--     type, so the substitution must be shared, not re-minted.
--
--   * NO ambient-row discharge. Named performs are routed to @self@ and never
--     reach the ambient row (the 'TPerformOn' path does not 'emitEffect'), so
--     there is nothing to discharge. The body is inferred under the CURRENT
--     ambient, so any OTHER (ambient) effects it performs flow outward normally.
inferNamedHandler
  :: Map.Map Text (Type s)
  -> Abs.VarId -> Abs.ConId -> [Abs.HandlerArm] -> Abs.Exp
  -> TC s (Type s, TExprS s)
inferNamedHandler mono (Abs.VarId (_, self)) (Abs.ConId (epos, effName)) arms body = do
  env <- currentEnv
  when (null arms) $ throwError (EmptyHandler (Just epos))
  eInfo <- case lookupEffect effName env of
    Nothing -> throwError (MissingEffectDecl (Just epos) effName)
    Just i  -> pure i
  when (isGroundIO effName eInfo) $
    throwError (IOEffectNotHandleable (Just epos))
  -- Classify each arm against the single-effect header.
  classified <- mapM (classifyArm env [effName]) arms
  let opArms    = [ (isO, en, op, ps, b, pos) | OpArmC isO en op ps b pos <- classified ]
      retArms   = [ (pos, v, b)               | ValArmC v b pos           <- classified ]
      paramArms = [ (name, initE, pos)        | ParamArmC name initE pos  <- classified ]
  case retArms of
    (_ : (pos2, _, _) : _) -> throwError (DuplicateReturnArm (Just pos2))
    _                      -> pure ()
  rejectDuplicateOpArms opArms
  -- Coverage: every operation of the handled effect must have an arm.
  let declaredOps = Map.keys (eiOps eInfo)
      handledOps  = [ op | (_, _, op, _, _, _) <- opArms ]
      missing     = [ op | op <- declaredOps, op `notElem` handledOps ]
  unless (null missing) $
    throwError (HandlerCoverage (Just epos) effName missing)
  -- ONE shared parameter substitution (fresh metavars), reused for the handle
  -- type and every arm.
  paramSubst <- instantiateParamSubst (eiParams eInfo)
  let handleArgs = [ Map.findWithDefault (TCon TcUnit []) i paramSubst
                   | (i, _) <- eiParams eInfo ]
      handleTy   = TCon (TcEffect effName) handleArgs
  answerT <- freshTVar KStar
  -- Handler-local parameter (slice 4a): at most one `name = init`.
  mParam <- case paramArms of
    []                 -> pure Nothing
    [(name, initE, _)] -> do
      paramTy <- freshTVar KStar
      (initT, initNode) <- inferExprW mono initE
      unify Nothing initT paramTy
      pure (Just (name, paramTy, initNode))
    (_ : (_, _, p2) : _) -> throwError (DuplicateHandlerParam (Just p2))
  let monoP = case mParam of
        Just (name, ty, _) -> Map.insert name ty mono
        Nothing            -> mono
  -- Type each operation arm via 'inferOpArmNode' (the single shared loop),
  -- passing the SHARED paramSubst (no per-arm re-instantiation) so the op
  -- types tie to @handleTy@.
  opArmNodes <- mapM
    (inferOpArmNode eInfo paramSubst monoP
      (fmap (\(_, paramTy, _) -> paramTy) mParam) answerT)
    opArms
  -- The body sees @self : handleTy@. Ambient effects of the body flow outward
  -- unchanged (we do NOT open a sub-ambient -- named performs never touch it).
  let monoSelf = Map.insert self handleTy monoP
  (bodyT, bodyNode) <- inferExprW monoSelf body
  let paramArmNodes = case mParam of
        Just (name, _, initNode) -> [Ty.TParamArm name initNode]
        Nothing                  -> []
  case retArms of
    []               -> do
      -- No value arm: the answer type is exactly the body's type.
      unify Nothing answerT bodyT
      pure (answerT, Ty.Texp answerT (Ty.TWithNamedH self (paramArmNodes ++ opArmNodes) bodyNode))
    ((_, v, rb) : _) -> do
      let monoRet = Map.insert v bodyT monoP
      (rT, rNode) <- inferExprW monoRet rb
      unify Nothing rT answerT
      let retArm = Ty.TReturnArm (Ty.Tpat bodyT (Ty.TPVar v)) rNode
      pure (answerT, Ty.Texp answerT (Ty.TWithNamedH self (paramArmNodes ++ opArmNodes ++ [retArm]) bodyNode))

-- ---------------------------------------------------------------------------
-- First-class handler values (proto/handler-values)
-- ---------------------------------------------------------------------------

-- | Type ONE operation arm against a given answer type, with no body coupling.
-- The SINGLE arm-typing loop, used by all three handler paths ('inferHandler',
-- 'inferNamedHandler', 'inferHandlerValue'); the caller decides the
-- substitution discipline -- 'inferHandler' passes a fresh per-arm
-- @paramSubst@, the named/value paths pass ONE shared instantiation so every
-- arm's op type ties to the same effect-param metavars the exposed
-- handle/@Handler@ type carries. @mParamTy@ is the handler-local parameter's
-- type when present; @answerT@ is the handler's answer type R; @monoP@ already
-- has the param/self names in scope.
--
-- NOTE: unlike the perform site (the `EProj` op-reference case), this
-- handler-arm path deliberately does NOT call `freshenNeverResult`. A `Never`
-- result must stay `Never` here so the arm's continuation is typed
-- `k : Never -> R` (uncallable -> a non-returning op cannot resume) and an
-- auto-resume arm body is forced to `Never` (unconstructable). Freshening
-- here would wrongly let an abort op resume. Bottom elimination belongs only
-- at the perform site.
inferOpArmNode
  :: EffectInfo
  -> Map.Map Int (Type s)
  -> Map.Map Text (Type s)
  -> Maybe (Type s)
  -> Type s
  -> (Bool, Text, Text, [Abs.AtomPat], Abs.Exp, (Int, Int))
  -> TC s (Ty.THandlerArm (Type s))
inferOpArmNode eInfo paramSubst monoP mParamTy answerT (isOnce, en, op, ps, body, pos) =
  case Map.lookup op (eiOps eInfo) of
      Nothing -> throwError (UnknownOperation (Just pos) en op)
      Just opScheme -> do
        let opTy = substCTypeWith paramSubst (schemeBody opScheme)
        arity <- arrowArity opTy
        let got      = length ps
            expected = if isOnce then arity + 1 else arity
        unless (got == expected) $
          throwError (ArmArityMismatch (Just pos) en op isOnce expected got)
        let (argPs, binderPs) = splitAt arity ps
        patResults <- mapM inferAtomPat argPs
        let pTys  = map (\(t, _, _) -> t) patResults
            binds = concatMap (\(_, b, _) -> b) patResults
            argPatNodes = map (\(_, _, n) -> n) patResults
            mono1 = foldr (\(n, t) m -> Map.insert n t m) monoP binds
        mResult <- peelArrowsWithArgUnify opTy pTys
        resultTy <- case mResult of
          Just r  -> pure r
          Nothing -> throwError (UnknownOperation (Just pos) en op)
        resumeContTy <- resumeContTyFor mParamTy resultTy answerT
        case binderPs of
          [] -> do
            (bodyT, bodyNode) <- inferExprW mono1 body
            unify (Just pos) bodyT resultTy
            pure (Ty.TOpArm en op argPatNodes Tx.empty resumeContTy bodyNode)
          [Abs.APWild] -> do
            (bodyT, bodyNode) <- inferExprW mono1 body
            unify (Just pos) bodyT answerT
            pure (Ty.TOpArm en op argPatNodes (Tx.pack "_") resumeContTy bodyNode)
          [Abs.APVar (Abs.VarId (_, kname))] -> do
            case shadowsName kname body of
              Just spos -> throwError (ContinuationShadowed (Just spos) kname)
              Nothing   -> pure ()
            let mono2 = Map.insert kname resumeContTy mono1
            (bodyT, bodyNode) <- inferExprW mono2 body
            unify (Just pos) bodyT answerT
            resultTy' <- force resultTy
            let isNever = case resultTy' of TCon TcNever [] -> True; _ -> False
            unless (isNever || texpMentions kname bodyNode) $
              addWarning (ForgottenResume (Just pos) en op)
            pure (Ty.TOpArm en op argPatNodes kname resumeContTy bodyNode)
          _ -> throwError (MalformedHandlerArm (Just pos) en op)

-- | Infer a first-class handler VALUE @handler E { arms }@. No body: the arms
-- are typed against fresh input (@a@) and answer (@b@) types, and the result is
-- @Handler (E params) a b@ = @TCon (TcHandler E) (params ++ [a, b])@. The
-- effect's params are instantiated ONCE and shared by every arm (the
-- 'inferNamedHandler' discipline), then EXPOSED in the handler's type so the
-- install site can tie the body's performs to this handler's instantiation --
-- without the exposure, @handle (state "s") in State.get + 1@ would typecheck.
-- The input @a@ is what a later @handle@'s body must produce; @b@ is what
-- installing it yields. Unlike 'inferHandler' there is no sub-ambient row and
-- no effect discharge -- those happen at the install site ('inferHandleValue').
inferHandlerValue
  :: Map.Map Text (Type s) -> Abs.ConId -> [Abs.HandlerArm] -> TC s (Type s, TExprS s)
inferHandlerValue mono (Abs.ConId (epos, effName)) arms = do
  env <- currentEnv
  when (null arms) $ throwError (EmptyHandler (Just epos))
  eInfo <- case lookupEffect effName env of
    Nothing -> throwError (MissingEffectDecl (Just epos) effName)
    Just i  -> pure i
  when (isGroundIO effName eInfo) $
    throwError (IOEffectNotHandleable (Just epos))
  classified <- mapM (classifyArm env [effName]) arms
  let opArms  = [ (isO, en, op, ps, b, pos) | OpArmC isO en op ps b pos <- classified ]
      retArms = [ (pos, v, b)               | ValArmC v b pos           <- classified ]
      paramArms = [ (name, initE, pos)      | ParamArmC name initE pos  <- classified ]
  case retArms of
    (_ : (pos2, _, _) : _) -> throwError (DuplicateReturnArm (Just pos2))
    _                      -> pure ()
  rejectDuplicateOpArms opArms
  -- Coverage: every operation of the effect must have an arm. A handler value
  -- missing an op would otherwise be caught only at runtime dispatch; the
  -- fused install forms all enforce this statically, so the value form must too.
  let declaredOps = Map.keys (eiOps eInfo)
      handledOps  = [ op | (_, _, op, _, _, _) <- opArms ]
      missing     = [ op | op <- declaredOps, op `notElem` handledOps ]
  unless (null missing) $
    throwError (HandlerCoverage (Just epos) effName missing)
  -- Handler-local parameter `var name = init` (the baton). Typed exactly as
  -- the fused forms type it: `name` at a fresh sigma, `init : sigma` checked
  -- under the CONSTRUCTION scope `mono` (the init does not see the param).
  -- Seeding semantics for a VALUE: the init is EVALUATED AT CONSTRUCTION --
  -- typing charges the init's effects to the construction site, so this is the
  -- type-consistent choice -- and each install starts a fresh activation from
  -- that captured seed (accept/09 per-install independence).
  mParam <- case paramArms of
    []                 -> pure Nothing
    [(name, initE, _)] -> do
      paramTy <- freshTVar KStar
      (initT, initNode) <- inferExprW mono initE
      unify Nothing initT paramTy
      pure (Just (name, paramTy, initNode))
    (_ : (_, _, p2) : _) -> throwError (DuplicateHandlerParam (Just p2))
  let monoP = case mParam of
        Just (name, ty, _) -> Map.insert name ty mono
        Nothing            -> mono
      mParamTy = fmap (\(_, ty, _) -> ty) mParam
  -- ONE shared parameter substitution across every arm AND the exposed type.
  paramSubst <- instantiateParamSubst (eiParams eInfo)
  let handlerParams = [ Map.findWithDefault (TCon TcUnit []) i paramSubst
                      | (i, _) <- eiParams eInfo ]
  answerT <- freshTVar KStar   -- b: the output answer
  inputT  <- freshTVar KStar   -- a: the value the handled body produces
  opArmNodes <- mapM (inferOpArmNode eInfo paramSubst monoP mParamTy answerT) opArms
  retArmNodes <- case retArms of
    [] -> do
      -- No value arm: return clause is the identity, so a = b.
      unify (Just epos) inputT answerT
      pure []
    ((_, v, rb) : _) -> do
      let mono' = Map.insert v inputT monoP
      (rT, rNode) <- inferExprW mono' rb
      unify (Just epos) rT answerT
      pure [Ty.TReturnArm (Ty.Tpat inputT (Ty.TPVar v)) rNode]
  let paramArmNodes = case mParam of
        Just (name, _, initNode) -> [Ty.TParamArm name initNode]
        Nothing                  -> []
      hTy = TCon (TcHandler effName) (handlerParams ++ [inputT, answerT])
  pure (hTy, Ty.Texp hTy (Ty.THandlerV effName (paramArmNodes ++ opArmNodes ++ retArmNodes)))

-- | Infer @handle h in body@: install a first-class handler value. @h@ must
-- have type @Handler E a b@; the body is typed under a fresh sub-ambient,
-- constrained to produce @a@ and to perform @E@ (discharged here), and the
-- whole expression has type @b@. Mirrors 'inferHandler''s discharge, taking the
-- effect and answer types from @h@'s type instead of from arms.
inferHandleValue
  :: Map.Map Text (Type s) -> Abs.Exp -> Abs.Exp -> TC s (Type s, TExprS s)
inferHandleValue mono hExpr body = do
  -- The handler expression is inferred FIRST (source order). When its type is
  -- already a concrete @Handler E ...@ -- every direct install of a runner
  -- application, e.g. @handle (state 0) in ...@ -- the handled effect is read
  -- off the TYPE, and the body may perform any number of OTHER effects; they
  -- flow out as residual exactly as with the fused forms. Only a POLYMORPHIC
  -- @h@ (@run f = handle f in E.ask@) falls back to reading the effect off the
  -- body's row, which still demands exactly one performed effect -- we UNIFY
  -- @f@ to a handler type, we do not inspect it.
  (hTy, hNode) <- inferExprW mono hExpr
  subAmbient0 <- freshRVar
  subRef <- liftST (newSTRef subAmbient0)
  (bodyT, bodyNode) <- withEffRow subRef (inferExprW mono body)
  subRow <- liftST (readSTRef subRef)
  hTy' <- force hTy
  en <- case hTy' of
    TCon (TcHandler e) _ -> pure e
    _ -> do
      labels <- concreteRowLabels subRow
      case labels of
        [l] -> pure l
        []  -> throwError (UnsupportedFeature Nothing
                 (Tx.pack "handle: cannot determine the handled effect (the \
                          \handler is polymorphic and the body performs no \
                          \effect)"))
        _   -> throwError (UnsupportedFeature Nothing
                 (Tx.pack "handle: cannot determine the handled effect (the \
                          \handler is polymorphic and the body performs more \
                          \than one effect)"))
  -- The handler value must be @Handler (E params) a b@ with @a@ = the body's
  -- result and @b@ a fresh answer. Unify (do not match) so a polymorphic @h@ is
  -- solved. The effect's params are instantiated fresh here and tied BOTH ways:
  -- to the handler value's exposed params (via the 'unify' below) and to the
  -- payload each of the body's performs carried into the row (via
  -- 'effectPayloadTy' against the row payloads). Without the payload tie,
  -- discharging would drop the payload unforced and a mistyped handler
  -- (@handle (state "s") in State.get + 1@) would slip through.
  env <- currentEnv
  eInfo <- case lookupEffect en env of
    Nothing -> throwError (MissingEffectDecl Nothing en)
    Just i  -> pure i
  paramSubst <- instantiateParamSubst (eiParams eInfo)
  let handlerParams = [ Map.findWithDefault (TCon TcUnit []) i paramSubst
                      | (i, _) <- eiParams eInfo ]
      payloadTy = effectPayloadTy (eiParams eInfo) paramSubst
  payloads <- rowPayloadsFor en subRow
  mapM_ (unify Nothing payloadTy) payloads
  answerT <- freshTVar KStar
  unify Nothing hTy (TCon (TcHandler en) (handlerParams ++ [bodyT, answerT]))
  residual <- dischargeEffects subRow [en]
  emitRow Nothing residual
  pure (answerT, Ty.Texp answerT (Ty.THandleV hNode bodyNode))

-- | Rebuild the plain application an install form's HEAD + ATOM ARGS sugar
-- denotes (shared by 'EHandleV'/'EHandleN'; the same fold 'EWithRun' uses).
rebuildWithArgs :: Abs.Exp -> [Abs.WithArg] -> Abs.Exp
rebuildWithArgs = foldl (\acc (Abs.WRArg e) -> Abs.EApp acc e)

-- | Infer a NAMED install @handle name = h in body@ (item-4 D5): like
-- 'inferHandleValue', but the activation is introduced as a named instance --
-- @name@ is bound to the effect's instance-handle type in the body's scope,
-- and @name.op@ performs on exactly this activation ('inferProjection's named
-- perform, 'TPerformOn'). Mirrors 'inferNamedHandler's typing discipline:
--
--   * the handle type and the handler's exposed params share ONE
--     instantiation, so @name.op@ ties to the same effect params the handler
--     value carries;
--   * NO ambient-row discharge -- named performs never reach the ambient row,
--     and the body is inferred under the CURRENT ambient, so its OTHER
--     (ambient) effects flow outward normally.
--
-- The handler's effect must be readable off its TYPE: a named instance needs
-- the effect statically (the dot dispatch is type-directed), so a polymorphic
-- @h@ is rejected rather than guessed from the body.
inferHandleNamedValue
  :: Map.Map Text (Type s) -> Abs.VarId -> Abs.Exp -> Abs.Exp -> TC s (Type s, TExprS s)
inferHandleNamedValue mono (Abs.VarId (npos, self)) hExpr body = do
  (hTy, hNode) <- inferExprW mono hExpr
  hTy' <- force hTy
  en <- case hTy' of
    TCon (TcHandler e) _ -> pure e
    _ -> throwError (UnsupportedFeature (Just npos)
           (Tx.pack "handle " <> self <> Tx.pack " = ...: the handler's effect \
                    \must be statically known (a concrete Handler type); a \
                    \polymorphic handler cannot introduce a named instance"))
  env <- currentEnv
  eInfo <- case lookupEffect en env of
    Nothing -> throwError (MissingEffectDecl (Just npos) en)
    Just i  -> pure i
  paramSubst <- instantiateParamSubst (eiParams eInfo)
  let handlerParams = [ Map.findWithDefault (TCon TcUnit []) i paramSubst
                      | (i, _) <- eiParams eInfo ]
      handleTy = TCon (TcEffect en) handlerParams
  inputT  <- freshTVar KStar
  answerT <- freshTVar KStar
  unify Nothing hTy (TCon (TcHandler en) (handlerParams ++ [inputT, answerT]))
  let mono' = Map.insert self handleTy mono
  (bodyT, bodyNode) <- inferExprW mono' body
  unify Nothing bodyT inputT
  pure (answerT, Ty.Texp answerT (Ty.THandleNV self hNode bodyNode))

-- | Reject a handler declaring two arms for one operation. Runtime dispatch
-- first-matches ('lookupOpArm'), so a later duplicate arm would be silent
-- dead code -- the dual of the coverage check. Shared by all three handler
-- paths (ambient, named, value).
rejectDuplicateOpArms
  :: [(Bool, Text, Text, [Abs.AtomPat], Abs.Exp, (Int, Int))] -> TC s ()
rejectDuplicateOpArms = go Set.empty
  where
    go _ [] = pure ()
    go seen ((_, en, op, _, _, pos) : rest)
      | (en, op) `Set.member` seen = throwError (DuplicateOpArm (Just pos) en op)
      | otherwise                  = go (Set.insert (en, op) seen) rest

-- | The concrete (named) effect labels of a row, ignoring its open tail.
concreteRowLabels :: Row s -> TC s [Text]
concreteRowLabels row = do
  row' <- force row
  case row' of
    RowExtend l _ rest -> (l :) <$> concreteRowLabels rest
    _                  -> pure []

-- | The payload types carried by every occurrence of the given label in a row
-- (ignoring the open tail). Companion to 'concreteRowLabels'.
rowPayloadsFor :: Text -> Row s -> TC s [Type s]
rowPayloadsFor label row = do
  row' <- force row
  case row' of
    RowExtend l t rest
      | l == label -> (t :) <$> rowPayloadsFor label rest
      | otherwise  -> rowPayloadsFor label rest
    _              -> pure []

-- | Remove the given effect labels from a row (each label dropped once per
-- occurrence is unnecessary in v1 -- effects are not duplicated by inference --
-- so we drop ALL occurrences of each handled label). Returns the residual row
-- of effects that were not handled.
dischargeEffects :: Row s -> [Text] -> TC s (Row s)
dischargeEffects row handled = do
  row' <- force row
  case row' of
    RowExtend l t rest  -> do
      rest' <- dischargeEffects rest handled
      if l `elem` handled
        then pure rest'
        else pure (RowExtend l t rest')
    _                   -> pure row'  -- RowEmpty or open tail: nothing concrete to drop

-- | Ordinary record field projection `e.label`: the original (pre-effects)
-- 'EProj' behaviour, factored out so the operation-call case can fall back to
-- it when the head constructor is not a declared effect.
inferProjection :: Map.Map Text (Type s) -> Abs.Exp -> (Int, Int) -> Text -> TC s (Type s, TExprS s)
inferProjection mono e pos label = do
  env <- currentEnv
  (eT, eNode) <- inferExprW mono e
  eT' <- force eT
  case eT' of
    -- Record field projection (today's behaviour).
    TRecord _ row -> do
      (fieldT, _rest) <- rewriteRowStrict (Just pos) label row
      pure (fieldT, Ty.Texp fieldT (Ty.TProj eNode label))
    -- Named perform: the receiver is an effect-instance handle `E args`. The
    -- accessor `e.op` performs `op` on THIS instance (off the ambient row, so
    -- NO emitEffect). The op is instantiated against the handle's OWN type
    -- args, so e.g. `(c : State U64).get : U64` ties the result to the U64 in
    -- the handle (rather than a fresh metavar).
    TCon (TcEffect en) params ->
      case lookupEffect en env of
        Nothing -> throwError (MissingEffectDecl (Just pos) en)
        Just eInfo -> case Map.lookup label (eiOps eInfo) of
          Nothing -> throwError (UnknownOperation (Just pos) en label)
          Just opScheme -> do
            -- Tie the op's param substitution to the handle's type args (in
            -- eiParams order) instead of fresh metavars.
            let paramSubst = Map.fromList (zip (map fst (eiParams eInfo)) params)
            opTy <- freshenNeverResult (substCTypeWith paramSubst (schemeBody opScheme))
            pure (opTy, Ty.Texp opTy (Ty.TPerformOn eNode en label))
    -- Anything else (incl. an unsolved metavar after force): the receiver's
    -- type is neither a record nor an effect handle. Because the accessor is
    -- type-directed, an unannotated receiver is ambiguous -- annotate it.
    TVar _ -> throwError (AmbiguousAccessor (Just pos) label)
    _ -> do
      cT <- freeze eT'
      throwError (NotARecord (Just pos) cT)

-- ---------------------------------------------------------------------------
-- Effect flow (Task 6)
-- ---------------------------------------------------------------------------

-- | Add one effect label to the ambient effect row of the enclosing equation.
--
-- Uses 'rewriteRow', which on an OPEN row (the usual case during inference)
-- grows the row by the label, and on a closed row demands the label be present
-- already. So:
--   * an inferred function's ambient stays open and accumulates exactly the
--     effects it uses, then is closed at the binding boundary;
--   * a function whose declared sig fixed a closed effect row rejects any
--     operation/effect not in that row -- surfaced as 'UndischargedEffect'.
-- Effects emitted outside any equation body (ambient = Nothing) are ignored;
-- that only happens where no row is meaningful (top-level value sigs, etc.).
emitEffect :: BNFC'Position -> Text -> Type s -> TC s ()
emitEffect sp label argTy = do
  mref <- currentEffRow
  case mref of
    Nothing  -> pure ()
    Just ref -> do
      ambient <- liftST (readSTRef ref)
      reachable <- effectReachable label ambient
      if reachable
        then do
          -- Present already, or the ambient has an open tail we may grow.
          -- 'rewriteRow' bubbles @label@ to the head (growing an open tail in
          -- place); unify the label's carried type so a parameterised effect
          -- (e.g. State a) stays consistent across its uses.
          (labelTy, _rest) <- rewriteRow sp label ambient
          unify sp labelTy argTy
        else
          -- Closed ambient (from a declared sig) that does not list this effect
          -- and has no open tail to grow: the operation's effect is undischarged
          -- by the signature.
          throwError (UndischargedEffect sp label)

-- | Is effect @label@ reachable in @row@ -- either already present, or the row
-- ends in an open variable that could be grown to include it? A closed row
-- (terminating in 'RowEmpty') that lacks the label is NOT reachable.
effectReachable :: Text -> Row s -> TC s Bool
effectReachable label row = do
  row' <- force row
  case row' of
    RowEmpty            -> pure False
    RowExtend l _ rest
      | l == label      -> pure True
      | otherwise       -> effectReachable label rest
    _                   -> pure True  -- open tail (row var): can grow to include label

-- | Add a whole (concrete) effect row into the ambient row -- used when an
-- application calls a function whose own effect row carries labels. Open tails
-- contribute nothing (they unify into the ambient's open tail); each concrete
-- label is emitted via 'emitEffect'.
emitRow :: BNFC'Position -> Row s -> TC s ()
emitRow sp row = do
  row' <- force row
  case row' of
    RowExtend l t rest -> do
      emitEffect sp l t
      emitRow sp rest
    RowEmpty           -> pure ()  -- closed callee row: nothing more to add
    _                  -> pure ()  -- open tail / non-row / bound var: nothing to add

-- | Look up an infix operator; monomorphic bindings are checked first.
-- Returns the operator's type and its name (for building the typed node).
-- Returns the operator's instantiated type, its name, AND the per-constraint
-- class-argument types it carries (empty for non-constrained operators, e.g.
-- the builtin @(+)@). The constraints are NOT emitted here: 'applyTails' decides
-- the head node form (plain @TVar@ vs 'TQVar') and emits via 'emitQVar', so the
-- accumulator gets exactly one entry per constrained use.
inferInfixOpW :: Map.Map Text (Type s) -> Abs.InfixOp -> TC s (Type s, Text, [(Text, Type s)])
inferInfixOpW mono (Abs.IOSym (Abs.VarSym (pos, name))) =
  lookupOpNameW mono pos name
inferInfixOpW mono (Abs.IOBT (Abs.VarId (pos, name))) =
  lookupOpNameW mono pos name

-- | The source position of an infix operator token (the @VarSym@/backtick
-- @VarId@ it was written as). Used to position operand-mismatch errors.
infixOpPos :: Abs.InfixOp -> (Int, Int)
infixOpPos (Abs.IOSym (Abs.VarSym (pos, _))) = pos
infixOpPos (Abs.IOBT  (Abs.VarId (pos, _)))  = pos

lookupOpNameW :: Map.Map Text (Type s) -> (Int, Int) -> Text -> TC s (Type s, Text, [(Text, Type s)])
lookupOpNameW mono pos name =
  case Map.lookup name mono of
    Just t -> pure (t, name, [])
    Nothing -> do
      env <- currentEnv
      case lookupVar name env of
        Just s -> do
          (t, cs) <- instantiateQ s
          pure (t, name, cs)
        Nothing -> throwError (UnknownVar (Just pos) name)

-- ---------------------------------------------------------------------------
-- Pattern coverage check
-- ---------------------------------------------------------------------------

-- | Emit 'NonExhaustiveRecordPattern' when a case expression scrutinises a
-- record whose row is open (has a row-variable tail) but every arm is a
-- strict pattern (no '..' / wildcard arm).  The strict arms remain reachable
-- because the row variable can be instantiated to RowEmpty; only the
-- non-exhaustive warning is emitted.
checkRecordPatternCoverage
  :: Abs.BNFC'Position -> Type s -> [Abs.Alt] -> TC s ()
checkRecordPatternCoverage sp scrutT alts = do
  scrutT' <- force scrutT
  case scrutT' of
    TRecord conTag row -> do
      open <- hasRowVarTail row
      when open $ do
        let allStrict = all isStrictAlt alts
        when allStrict $
          addWarning (NonExhaustiveRecordPattern sp conTag)
    _ -> pure ()
  where
    -- Walk the row spine to its tail; return True if the tail is a RowVar.
    hasRowVarTail :: Row s -> TC s Bool
    hasRowVarTail RowEmpty = pure False
    hasRowVarTail (RowExtend _ _ rest) = do
      rest' <- force rest
      hasRowVarTail rest'
    hasRowVarTail _ = pure True  -- open tail (row var)

    -- Return True iff the arm's outermost pattern is a strict record pattern.
    -- Open arms (PRecordOpen with '..'), wild arms (PRecordWild), and any
    -- other non-record pattern break the all-strict condition and satisfy
    -- coverage.
    isStrictAlt :: Abs.Alt -> Bool
    isStrictAlt (Abs.AltC pat _ _) = isStrictPat pat

    isStrictPat :: Abs.Pat -> Bool
    isStrictPat (Abs.PAtom ap) = isStrictAtomPat ap
    isStrictPat _              = False

    isStrictAtomPat :: Abs.AtomPat -> Bool
    isStrictAtomPat (Abs.PRecord _ _) = True
    isStrictAtomPat _                 = False

-- | Extract a best-effort source position from a scrutinee expression.
-- Returns Nothing when the expression has no recoverable position.
expPos :: Abs.Exp -> Abs.BNFC'Position
expPos (Abs.EVar (Abs.VarId (p, _)))     = Just p
expPos (Abs.EApp e _)                    = expPos e
expPos (Abs.EProj e _)                   = expPos e
expPos (Abs.EProjC e _)                  = expPos e
expPos (Abs.ELitI (Abs.WokInt (p, _)))   = Just p
expPos (Abs.EParen e)                    = expPos e
expPos (Abs.ECon (Abs.ConId (p, _)))     = Just p
expPos (Abs.EIf c _ _)                   = expPos c
expPos (Abs.EList (x : _))               = expPos x
expPos (Abs.ETuple a _)                  = expPos a
expPos _                                 = Nothing

-- ---------------------------------------------------------------------------
-- Let/where inference helpers
-- ---------------------------------------------------------------------------

-- | Infer a single case alternative, returning its typed form.
inferAlt :: Map.Map Text (Type s) -> Type s -> Type s -> Abs.Alt -> TC s (Ty.TAlt (Type s))
inferAlt mono sT rT (Abs.AltC pat body mw) = do
  (pT, binds, patNode) <- inferPat pat
  unify (patPos pat) sT pT
  let mono' = foldr (\(n, t) m -> Map.insert n t m) mono binds
  let withWhere k = case mw of
        Abs.NoWhere -> k mono' []
        Abs.WithWh ds -> inferLetGroup mono' ds k
  (bodyT, bodyNode, whereNodes) <- withWhere $ \m declNodes -> do
    (t, n) <- inferExprW m body
    pure (t, n, declNodes)
  unify (msum [expPos body, patPos pat]) rT bodyT
  pure (Ty.TAlt patNode whereNodes bodyNode)

-- | Process a local-decl group as a single mutually-recursive let.
-- Each binding's placeholder TVar lives in the mono-map during RHS typing
-- so recursive calls see it without going through instantiate. After typing
-- at level+1, we exit the level and generalize (so only inner TVars are
-- quantified). Then extend env for the continuation.
inferLetGroup
  :: Map.Map Text (Type s)
  -> [Abs.LocalDecl]
  -> (Map.Map Text (Type s) -> [Ty.TLocalDecl (Type s)] -> TC s a)
  -> TC s a
inferLetGroup mono decls k = do
  -- Tuple pattern binds are desugared at the `ELet` surface site. If one reaches
  -- a named group (i.e. it appears in a `where` block, which is not desugared),
  -- reject it with a clear directive rather than silently dropping it.
  case [ () | Abs.LDPat{} <- decls ] of
    (_ : _) -> throwError
      (UnsupportedFeature Nothing
        (Tx.pack "tuple pattern binding is only supported in `let ... in`, not \
                 \in a `where` block; use `let` or `case`"))
    [] -> pure ()
  let (sigs, eqns) = partitionLocalDecls decls
  sigMap <- buildSigMap sigs
  let groups = groupEquations eqns
      -- A binding WITH a declared signature is visible via that signature, so
      -- every reference to it -- recursive self-references and uses by group
      -- mates alike -- instantiates the scheme polymorphically. Only UNSIGNED
      -- bindings are referenced through their monomorphic placeholder. (Routing
      -- a signed binding through the placeholder let its signature's
      -- skolemised variable escape into a group-mate's use; see RigidEscape.)
      extendSig e = foldr (\(n, s) e' -> extendVar n s e') e (Map.toList sigMap)
  -- Phase 1: inside level+1, allocate placeholders and unify all equation
  -- types. Returns (name, placeholderTVar, hasSig) after unification.
  unified <- withEnv extendSig $ enterLevel $ do
    placeholders <- mapM (allocatePlaceholderTVar sigMap) groups
    let monoRec = foldr (\(n, tv, _) m -> if Map.member n sigMap
                                            then m
                                            else Map.insert n tv m)
                        mono placeholders
    mapM (\ph@(_, _, phEqns) -> do
            (n, tv, ds) <- unifyGroupWith monoRec sigMap ph
            pure (n, tv, ds, eqnDefnSpan phEqns))
         placeholders
  -- The typed local decls for every equation across all groups, in source
  -- order, available to the continuation for building TLet/where nodes.
  let declNodes = concatMap (\(_, _, ds, _) -> ds) unified
  -- Phase 2: back at outer level, generalize or check sig; the definition
  -- span rides along to anchor the trapped-effect diagnostic.
  results <- withEnv extendSig $
    mapM (\(n, tv, _, sp) -> finalizeGroup sigMap (n, tv, sp)) unified
  -- Bodyless sigs in this let block become visible bindings with the
  -- declared scheme verbatim (NO freezeSig). Warnings are NOT emitted
  -- here in v1 -- let-block bodyless diagnostics are deferred to a
  -- future warning-pass task.
  let monoBindings = [ (n, tv) | Left  (n, tv) <- results ]
      polyBindings = [ (n, s)  | Right (n, s)  <- results ]
      coveredEqn   = Set.fromList (map fst groups)
      sigOnlyBindings = [ (n, sigMap Map.! n)
                        | n <- sigNamesInOrder sigs
                        , Map.member n sigMap
                        , not (Set.member n coveredEqn) ]
      mono'   = foldr (\(n, tv) m -> Map.insert n tv m) mono monoBindings
      extend2 = foldr (.) id [ extendVarTC n s
                             | (n, s) <- polyBindings ++ sigOnlyBindings ]
  extend2 (k mono' declNodes)

partitionLocalDecls :: [Abs.LocalDecl] -> ([Abs.LocalDecl], [Abs.LocalDecl])
partitionLocalDecls = foldr step ([], [])
  where
    step d@Abs.LDSig{} (ss, es) = (d : ss, es)
    step d@Abs.LDEqn{} (ss, es) = (ss, d : es)
    -- Pattern binds are desugared to `case` at the `ELet` surface site before
    -- reaching here. If one survives (e.g. inside a `where` block), it is
    -- dropped from the named-group partition; inferLetGroup rejects it.
    step Abs.LDPat{}   acc       = acc

-- | Split a local-decl list at the first tuple pattern bind, returning the decls
-- before it, the tuple's head and tail component patterns, its RHS, and the
-- decls after it. Returns Nothing if there is no pattern bind in the list. The
-- grammar guarantees a pattern bind's LHS is a 2-or-more tuple, so the head and
-- tail components reconstruct an `APTuple`.
splitAtPatBind
  :: [Abs.LocalDecl]
  -> Maybe ([Abs.LocalDecl], Abs.Pat, [Abs.Pat], Abs.Exp, [Abs.LocalDecl])
splitAtPatBind = go []
  where
    go _ [] = Nothing
    go acc (Abs.LDPat headPat tailPats rhs : rest) =
      Just (reverse acc, headPat, tailPats, rhs, rest)
    go acc (d : rest) = go (d : acc) rest

-- | A tuple-component pattern must be a variable or `_` (the case-compiler
-- elaboration only binds those). Anything richer -- a nested tuple,
-- constructor, list, or literal -- is rejected and must use `case`. (A nested
-- tuple type-checks but is NOT bound by elaboration, which would silently
-- miscompile into a runtime UnboundVar; rejecting it here makes that a clear
-- compile-time error.)
checkComponentPat :: Abs.Pat -> TC s ()
checkComponentPat (Abs.PAtom ap) = case ap of
  Abs.APVar{}   -> pure ()
  Abs.APWild    -> pure ()
  Abs.APParen p -> checkComponentPat p
  _ -> throwError
    (UnsupportedFeature (atomPatPos ap)
      (Tx.pack "pattern binding component must be a variable or `_`; \
               \for richer patterns use `case`"))
checkComponentPat _ = throwError
  (UnsupportedFeature Nothing
    (Tx.pack "pattern binding component must be a variable or `_`; \
             \for richer patterns use `case`"))

atomPatPos :: Abs.AtomPat -> Abs.BNFC'Position
atomPatPos (Abs.APVar (Abs.VarId (p, _)))      = Just p
atomPatPos (Abs.APLitI (Abs.WokInt (p, _)))    = Just p
atomPatPos (Abs.APCon modPath)                 = Just (modPathPos modPath)
atomPatPos (Abs.APList (p : _))                = patPos p
atomPatPos (Abs.APTuple p _)                   = patPos p
atomPatPos (Abs.APParen p)                     = patPos p
atomPatPos (Abs.APAs inner _)                  = atomPatPos inner
atomPatPos (Abs.PRecord (Abs.ConId (p, _)) _)  = Just p
atomPatPos (Abs.PRecordOpen (Abs.ConId (p, _)) _ _) = Just p
atomPatPos (Abs.PRecordWild (Abs.ConId (p, _)) _)   = Just p
atomPatPos _                                   = Nothing

-- | Best-effort source position for a pattern, drilling to the first
-- position-carrying atom. Mirrors 'atomPatPos' for the nested case.
patPos :: Abs.Pat -> Abs.BNFC'Position
patPos (Abs.PAtom ap)     = atomPatPos ap
patPos (Abs.PApp mp _ _)  = Just (modPathPos mp)
patPos (Abs.PCons ap _)   = atomPatPos ap

buildSigMap :: [Abs.LocalDecl] -> TC s (Map.Map Text Scheme)
buildSigMap [] = pure Map.empty
buildSigMap (Abs.LDSig sn extras ty : rest) = do
  env <- currentEnv
  -- Reject anonymous `..` tails in parameter positions (spec 145/142),
  -- anchored at the signature name since `..` carries no position itself.
  checkAnonTailPolarity (Just (sigNamePos sn)) ty
  s <- translateSig env ty
  let names = sigNameText sn : [ sigNameText x | Abs.SNCons x <- extras ]
  m <- buildSigMap rest
  pure (foldr (\nm acc -> Map.insert nm s acc) m names)
buildSigMap (_ : rest) = buildSigMap rest

-- Walks the decl list left-to-right (source order); groups appear in the
-- order their first equation appears, equations within a group preserve
-- source order.
groupEquations :: [Abs.LocalDecl] -> [(Text, [Abs.LocalDecl])]
groupEquations = Data.List.foldl' step []
  where
    step acc d =
      let n = eqName d
      in case lookup n acc of
           Just _  -> map (\(k, xs) -> if k == n then (k, xs ++ [d]) else (k, xs)) acc
           Nothing -> acc ++ [(n, [d])]

eqName :: Abs.LocalDecl -> Text
eqName (Abs.LDEqn lhs _ _) = funLHSName lhs
eqName (Abs.LDSig sn _ _) = sigNameText sn
-- Pattern binds carry no name and are partitioned out before grouping.
eqName Abs.LDPat{} = Tx.pack "<pattern-bind>"

funLHSName :: Abs.FunLHS -> Text
funLHSName (Abs.LHSPre fn _) = funNameText fn
funLHSName (Abs.LHSInfSym _ (Abs.VarSym (_, n)) _) = n
funLHSName (Abs.LHSInfBT _ (Abs.VarId (_, n)) _) = n

funNameText :: Abs.FunName -> Text
funNameText (Abs.FNBare (Abs.VarId (_, n))) = n
funNameText (Abs.FNBareSym (Abs.VarSym (_, n))) = n
funNameText (Abs.FNParen (Abs.VarSym (_, n))) = n

-- | Allocate a fresh placeholder TVar for one binding group.
-- Returns (name, placeholderTVar, equations).
allocatePlaceholderTVar
  :: Map.Map Text Scheme
  -> (Text, [Abs.LocalDecl])
  -> TC s (Text, Type s, [Abs.LocalDecl])
allocatePlaceholderTVar _sigMap (name, eqns) = do
  tv <- freshTVar KStar
  pure (name, tv, eqns)

-- | Inside level+1: type all equations, unify with the placeholder TVar.
-- Returns (name, placeholderTVar) ready for generalization.
-- The sigMap is threaded so that sig-driven bidirectional checking can be
-- applied to the bodies (e.g., ERecord with an extension row).
unifyGroupWith
  :: Map.Map Text (Type s)
  -> Map.Map Text Scheme
  -> (Text, Type s, [Abs.LocalDecl])
  -> TC s (Text, Type s, [Ty.TLocalDecl (Type s)])
unifyGroupWith monoRec sigMap (name, tv, eqns) = do
  let mSig = Map.lookup name sigMap
  eqResults <- mapM (typeEquationWith monoRec mSig) eqns
  let eqTypes = map fst eqResults
      eqDecls = map snd eqResults
  case eqTypes of
    [] -> error ("unifyGroupWith: no equations for " ++ show name)
    (t : ts) -> do
      mapM_ (unify Nothing t) ts
      unify Nothing tv t
      pure (name, tv, eqDecls)

-- | Walk a forced type and return the uniq of an unbound TVar with level <=
-- outer (or a 'Rigid' skolem), if any. A 'Just' means the binding is pinned by
-- an enclosing scope (or captured a skolem) and must not be generalized; the
-- uniq lets a caller name the escaping variable in a diagnostic.
hasOuterScopeVar :: Int -> Type s -> TC s (Maybe Int)
hasOuterScopeVar outer = go
  where
    go ty = do
      ty' <- force ty
      case ty' of
        TCon _ ts -> firstM (map go ts)
        TArr a r b -> firstM [go a, go r, go b]
        TRecord _ row -> go row
        RowEmpty -> pure Nothing
        RowExtend _ ty2 rest -> firstM [go ty2, go rest]
        TVar ref -> do
          tv <- liftST $ readSTRef ref
          case tv of
            Unbound u (Level l) _ -> pure (if l <= outer then Just u else Nothing)
            Rigid u _ _ -> pure (Just u)
              -- A Rigid IS an outer-scope constant (it represents a skolem
              -- from an enclosing sig), so any binding that references one
              -- must stay monomorphic.
            Link _ -> error "hasOuterScopeVar: TVar was Link after force (caller invariant violation)"
    firstM = foldr (\m acc -> do { r <- m; maybe acc (pure . Just) r }) (pure Nothing)

-- | Verify a declared sig against the inferred type. A 'RigidEscape' on a
-- skolem minted for a TRAPPED effect-row var ('freezeSigSkolems') is a
-- laundering leak -- the body performs an effect the sig never declared --
-- surfaced as an 'UndischargedEffect' POSITIONED at the binding's
-- definition site (rung-3 spec D3). Other escapes (KStar over-promises)
-- pass through unchanged. Shared by 'finalizeGroup'/'finalizeGroupTyped' so
-- the two finalization paths cannot drift.
reconcileDeclared :: BNFC'Position -> Type s -> Type s -> Set.Set Int -> TC s ()
reconcileDeclared defnSp declT tv trappedUniqs =
  unify Nothing declT tv `catchError` \e -> case e of
    RigidEscape _ u | Set.member u trappedUniqs ->
      throwError (UndischargedEffect defnSp (Tx.pack "e"))
    _ -> throwError e

-- | The definition span of a binding group: the first equation's LHS
-- position, used to anchor reconciliation diagnostics ('reconcileDeclared').
eqnDefnSpan :: [Abs.LocalDecl] -> BNFC'Position
eqnDefnSpan decls = case [ lhs | Abs.LDEqn lhs _ _ <- decls ] of
  lhs : _ -> lhsPos lhs
  []      -> Nothing

-- | Back at outer level: generalize an inferred type or verify a sig.
-- Returns Left (name, tv) for monomorphic bindings (escape detected),
-- Right (name, scheme) for genuinely polymorphic ones. @defnSp@ anchors
-- the trapped-effect diagnostic at the binding's definition site.
finalizeGroup
  :: Map.Map Text Scheme
  -> (Text, Type s, BNFC'Position)
  -> TC s (Either (Text, Type s) (Text, Scheme))
finalizeGroup sigMap (name, tv, defnSp) =
  case Map.lookup name sigMap of
    Just declared -> do
      (declT, _, trappedUniqs) <- freezeSigSkolems declared
      reconcileDeclared defnSp declT tv trappedUniqs
      pure (Right (name, declared))
    Nothing -> do
      Level outer <- currentLevel
      mEscape <- hasOuterScopeVar outer tv
      case mEscape of
        Just _  -> pure (Left (name, tv))
        Nothing -> do
          gen <- generalize tv
          pure (Right (name, gen))

-- | Top-level variant of 'finalizeGroup': in addition to producing the
-- binding's scheme, it FREEZES the binding's typed parameter patterns and
-- body into a 'TypedDecl'. Freezing happens here, at the top level, in a
-- single 'generalizeTyped' call so that the params and body share one
-- quantification mapping (consistent 'CTGen' numbering) and so that no var at
-- level <= outer can reach the freeze -- the top level has no enclosing
-- scope, so every quantifiable var sits above it. Inner let-groups keep using
-- the plain 'finalizeGroup' (schemes only); their unfrozen sub-trees are
-- folded into the enclosing body and frozen as part of THIS top-level tree.
--
-- The typed equations come from 'unifyGroupWith'. A binding may have several
-- equations (one 'TLocalDecl' each); EVERY clause is carried on the 'TypedDecl'
-- as @(params, body)@. All clauses are frozen together under ONE quantification
-- mapping (by wrapping them in a synthetic @TLam (TList ...)@) so that per-node
-- 'CTGen' numbering stays consistent across clause bodies. The scheme covers all
-- clauses (their types were unified), so 'tdScheme' is the same regardless.
--
-- The top level never reports escape (no outer scope), so unlike
-- 'finalizeGroup' this returns a 'TypedDecl' directly.
finalizeGroupTyped
  :: Map.Map Text Scheme
  -> (Text, Type s, [Ty.TLocalDecl (Type s)], [ConstraintS s], BNFC'Position)
  -> TC s TypedDecl
finalizeGroupTyped sigMap (name, tv, eqDecls, accCs, defnSp) = do
  (arity, clauseList) <- case eqDecls of
    [] -> error ("finalizeGroupTyped: no typed equations for " ++ Tx.unpack name)
    (Ty.TLocalDecl _ firstParamsS _ : _) ->
      pure ( length firstParamsS
           , [ (ps, b) | Ty.TLocalDecl _ ps b <- eqDecls ] )
  -- Freeze ALL clauses together under one mapping by wrapping every clause's
  -- params and body in a single synthetic TLam (params concatenated) whose own
  -- body is a TList of all clause bodies. Freezing is a structural traversal
  -- ('generalizeTyped'/'freezeTypedTreeSig' use 'traverse'), so this wrapper
  -- survives intact and 'unClauses' re-splits it using the uniform arity.
  let allParamsS = concatMap fst clauseList
      allBodiesS = map snd clauseList
      synthetic  = Ty.Texp tv (Ty.TLam allParamsS (Ty.Texp tv (Ty.TList allBodiesS)))
  case Map.lookup name sigMap of
    Just declared -> do
      -- A user signature pins the scheme. Verify it (as 'finalizeGroup'
      -- does), then freeze the inferred tree for its node types while keeping
      -- the DECLARED scheme as 'tdScheme'. The body was checked against a
      -- skolemised instantiation of the sig, so its annotations carry Rigid
      -- skolems; 'freezeTypedTreeSig' folds those into CTGens (it does not
      -- error on Rigids the way 'generalizeTyped'/'freezeQuantify' do).
      -- Skolemise the declared scheme and capture each declared var index's
      -- skolem identity (uniq). Unifying the skolemised sig with 'tv' links the
      -- body's metavars to these skolems, so an accumulated constraint's
      -- argument -- once forced -- resolves to the very skolem standing for the
      -- declared var it constrains (or to a different skolem / metavar, which is
      -- exactly the under-entailed case we must reject).
      (declT, varUniq, trappedUniqs) <- freezeSigSkolems declared
      reconcileDeclared defnSp declT tv trappedUniqs
      -- Freeze the inferred tree for its node types. The accumulated constraints
      -- are validated below against the still-mutable 'accCs' (whose arguments
      -- are the skolems/metavars above), NOT against any re-folded CTGen copy:
      -- entailment must be checked by ARGUMENT, and the tree's independent CTGen
      -- numbering would lose that identity. The scheme stays the declared one.
      (frozen, _) <- freezeTypedTreeSig synthetic accCs
      let clauses = unClauses name arity frozen
      let declared' = nubConstraints (schemeConstraints declared)
          -- The skolem uniqs the declared context PROMISES a dictionary for: a
          -- declared `Eq a` provides a dictionary for the skolem standing for
          -- `a`. Used as the in-scope param set for 'Solve.resolve': a residual
          -- @CTGen u@ with @u@ in this set resolves to 'EvParam' (entailed);
          -- otherwise it is 'Ambiguous' (under-entailed). 'freezeTolerant' maps
          -- @Rigid u@ to @CTGen u@ identically, so these uniqs line up with the
          -- frozen constraint arguments -- including skolems nested under a type
          -- constructor (e.g. `Eq (Option a)`), which 'Solve.resolve' reaches by
          -- recursing through the matching instance head.
          promisedSet = Set.fromList
            [ u
            | c <- declared', CTGen i <- [conArg c]
            , Just u <- [Map.lookup i varUniq] ]
          -- Ambiguity: a declared constraint over a variable that does not occur
          -- in the declared body type can never be resolved at a call site
          -- (e.g. `amb : (Eq a) => Bool`). Concrete-arg constraints (none in the
          -- Eq slice) are validated by resolve below, not here.
          bodyVars = ctGenVars (schemeBody declared)
      forM_ declared' $ \c -> case conArg c of
        CTGen i | not (i `Set.member` bodyVars) ->
                    throwError (AmbiguousConstraint (conClass c))
        _       -> pure ()
      env <- currentEnv
      -- Validate every accumulated constraint by its ARGUMENT against the
      -- declared context. Freeze the argument with a Rigid-TOLERANT walker that
      -- maps each skolem @Rigid u@ to the sentinel @CTGen u@ (and any unbound
      -- metavar likewise), then resolve against the PROMISED skolem uniqs:
      --   * bare promised skolem  (@CTGen u@, u in promisedSet) -> 'EvParam';
      --   * skolem UNDER a tycon  (@Eq (Option (CTGen u))@) -> recurses through
      --     the @instance (Eq a)=>Eq (Option a)@ head to @Eq (CTGen u)@, then
      --     'EvParam' since u is promised -- this is the case a bare-skolem-only
      --     check missed (and that previously CRASHED in 'freeze' on the Rigid);
      --   * concrete head -> must resolve to an instance, else 'NoInstance';
      --   * unpromised skolem / unbound metavar -> 'Ambiguous' (under-entailed).
      forM_ accCs $ \(ConstraintS cls argS) -> do
        argC <- freezeTolerant argS
        case Solve.resolve env promisedSet cls argC of
          Right _                    -> pure ()
          Left (Solve.NoInst cl a)   -> throwError (NoInstance cl (prettyCType a))
          Left (Solve.Ambiguous cl)  -> throwError (AmbiguousConstraint cl)
      -- Evidence parameters come from the DECLARED context, ordered by the
      -- CTGen index of each constraint's var (so `isEq`'s `(Eq a)=>` yields
      -- `[("d$Eq$0", Eq (CTGen 0))]`). Concrete declared constraints (none in
      -- the slice) carry no parameter.
      let evParams = [ (Solve.paramName (conClass c) i, c)
                     | c <- declared', CTGen i <- [conArg c] ]
      pure TypedDecl { tdName = name, tdScheme = declared
                     , tdClauses = clauses, tdEvidence = evParams
                     , tdIsExtern = False }
    Nothing -> do
      Level outer <- currentLevel
      mEscape <- hasOuterScopeVar outer tv
      -- A top-level UNSIGNED binding whose inferred type still references an
      -- outer-scope variable or a skolem is over-general: this happens when a
      -- nested signed helper's skolem leaks out (e.g. `outer u = let helper :
      -- a -> a; helper y = if .. then y else u in ..` -- the helper's `a` is
      -- forced equal to `outer`'s parameter and escapes). Surface a positioned
      -- 'EscapedTyVar' rather than the old `finalizeGroupTyped: unexpected
      -- escape` internal panic (bug #4, layout-dependent path).
      forM_ mEscape $ \u -> throwError (EscapedTyVar Nothing u)
      (gen, frozen, fcs) <- generalizeTyped tv synthetic accCs
      let clauses = unClauses name arity frozen
      -- Discharge the frozen constraints against the generalized scheme:
      --   * arg = CTGen i quantified by the scheme -> residual (kept on the
      --     scheme + minted as an evidence parameter);
      --   * arg = CTGen i NOT quantified -> ambiguous (constraint var absent
      --     from the inferred type);
      --   * concrete arg -> must resolve to an instance, else NoInstance.
      let qs = Set.fromList (map fst (schemeVars gen))
      env <- currentEnv
      residual <- fmap concat $ forM (nubConstraints fcs) $ \c -> case conArg c of
        CTGen i
          | i `Set.member` qs -> pure [c]
          | otherwise         -> throwError (AmbiguousConstraint (conClass c))
        arg -> case Solve.resolve env Set.empty (conClass c) arg of
          Right _                    -> pure []
          Left (Solve.NoInst cls a)  -> throwError (NoInstance cls (prettyCType a))
          Left (Solve.Ambiguous cls) -> throwError (AmbiguousConstraint cls)
      let evParams = [ (Solve.paramName (conClass c) i, c)
                     | c <- residual, CTGen i <- [conArg c] ]
          gen' = gen { schemeConstraints = residual }
      pure TypedDecl { tdName = name, tdScheme = gen'
                     , tdClauses = clauses, tdEvidence = evParams
                     , tdIsExtern = False }
  where
    sameConstraint a b = conClass a == conClass b && conArg a == conArg b
    nubConstraints = Data.List.nubBy sameConstraint
    -- The set of CTGen indices occurring anywhere in a (frozen) CType.
    ctGenVars :: CType -> Set.Set Int
    ctGenVars (CTGen i)       = Set.singleton i
    ctGenVars (CTCon _ ts)    = Set.unions (map ctGenVars ts)
    ctGenVars (CTArr a _ b)   = ctGenVars a `Set.union` ctGenVars b
    ctGenVars (CTRecord _ _)  = Set.empty
    -- Row nodes (kind KEffect): constraints never range over row vars.
    ctGenVars CREmpty         = Set.empty
    ctGenVars (CRExtend{})    = Set.empty

-- | Recover the per-clause @(params, body)@ list from the synthetic wrapper that
-- 'finalizeGroupTyped' froze: a 'TLam' over all clauses' params concatenated,
-- whose body is a 'TList' of all clauses' bodies. 'arity' (the uniform column
-- count, guaranteed equal across equations by the arity-agreement check) re-
-- splits the concatenated params. The wrapper shape is preserved by freezing (a
-- structural traversal), so this never fails unless the wrapper was built wrong.
--
-- The @arity == 0@ case is special: zero-param bindings (top-level values,
-- @main@) concatenate no params, so 'zip'ping a chunked param list against the
-- bodies would yield no clauses and LOSE the body. Handle it directly by pairing
-- each body with an empty param list.
unClauses :: Text -> Int -> TExpr -> [([TPat], TExpr)]
unClauses _ 0 (Ty.Texp _ (Ty.TLam [] (Ty.Texp _ (Ty.TList bodies)))) =
  [ ([], b) | b <- bodies ]
unClauses _ arity (Ty.Texp _ (Ty.TLam allParams (Ty.Texp _ (Ty.TList bodies)))) =
  zip (chunk arity allParams) bodies
  where
    chunk _ [] = []
    chunk n xs = take n xs : chunk n (drop n xs)
unClauses name _ _ = error
  ("finalizeGroupTyped: synthetic clause wrapper lost its shape for "
  ++ Tx.unpack name)

-- | Type one equation, using the given recursive mono-map as the base
-- (so mutually-recursive names are visible). Pattern bindings extend it.
-- The optional sig scheme is used for bidirectional checking: when the
-- equation has no parameters, the sig is instantiated and threaded as a
-- hint to the body so that ERecord/ERecordExt can accept extension fields.
typeEquationWith
  :: Map.Map Text (Type s)
  -> Maybe Scheme
  -> Abs.LocalDecl
  -> TC s (Type s, Ty.TLocalDecl (Type s))
typeEquationWith monoRec mSig (Abs.LDEqn lhs body mw) = do
  let atoms = lhsAtomPats lhs
      name  = funLHSName lhs
  patResults <- mapM inferAtomPat atoms
  let pTys  = map (\(t, _, _) -> t) patResults
      patNodes = map (\(_, _, n) -> n) patResults
      binds = concatMap (\(_, b, _) -> b) patResults
      mono  = foldr (\(n, t) m -> Map.insert n t m) monoRec binds
  -- Instantiate the sig once (shared by the body hint and the effect-row seed).
  -- Derive the expected body type by peeling off one arrow per pattern
  -- parameter, unifying each argument's sig type with the pattern TVar so field
  -- access inside the body sees the record type. Also capture the effect row on
  -- the INNERMOST arrow -- the n-th, where n is the number of pattern parameters
  -- -- which is where a fully-applied curried function performs its effects and
  -- where the parser attaches a trailing `with E`. Used as the ambient seed.
  (mBodyHint, mSigEffRow) <- case mSig of
    Nothing -> pure (Nothing, Nothing)
    Just sig -> do
      sigT <- instantiate sig
      effRow <- effRowAtDepth (length pTys) sigT
      mResult <- peelArrowsWithArgUnify sigT pTys
      pure (mResult, effRow)
  let withWhere k = case mw of
        Abs.NoWhere -> k mono []
        Abs.WithWh ds -> inferLetGroup mono ds k
      -- Run the body under the where-bindings, returning the body type and a
      -- node. A non-empty `where` becomes a `TLet` wrapping the body so the
      -- typed binding's single body field carries the where group.
      runBody = withWhere $ \m declNodes -> do
        (t, n) <- inferExprWChecked m mBodyHint body
        let n' = case declNodes of
                   [] -> n
                   _  -> Ty.Texp t (Ty.TLet declNodes n)
        pure (t, n')
      mkDecl = Ty.TLocalDecl name patNodes
  -- Effect-row discipline depends on whether this equation has parameters:
  --
  --   * WITH parameters: it is a function. Its effects happen when it is
  --     applied, so they ride its OUTERMOST arrow (`A -> B -> C with E` = the
  --     whole chain performs E). Install a fresh ambient that the body extends,
  --     then close it (open tail -> RowEmpty) so an inferred function commits
  --     to exactly the effects it uses -- the (A) "closed by default" rule.
  --
  --   * WITHOUT parameters: it is a value that evaluates in place, so any
  --     effects it performs belong to the ENCLOSING computation. Inherit the
  --     enclosing ambient (if any) rather than installing/closing a new one;
  --     this is what lets `both u = let a = useIO () in useLog ()` collect both
  --     IO (from the let-bound value) and Logger.
  case pTys of
    [] -> do
      menc <- currentEffRow
      case menc of
        Just _  -> do
          (bodyT, bodyNode) <- runBody
          pure (bodyT, mkDecl bodyNode)
        Nothing -> do
          -- Top-level zero-arg binding: no enclosing ambient, and no arrow to
          -- carry a `with` row, so its contract is the ENTRY ambient -- the
          -- closed row containing exactly the ground IO effect, which is
          -- discharged by running the program (see 'isGroundIO'), never by a
          -- handler. Any other effect a top-level value performs has nowhere
          -- to be discharged and is rejected at the emit site
          -- (UndischargedEffect), exactly as a no-`with` function sig rejects
          -- one. Previously this seeded a fresh OPEN row that was closed but
          -- never reconciled against anything, so top-level values (main
          -- included) silently bypassed the effect discipline entirely and
          -- crashed at run time (NoMatchingHandler).
          --
          -- The IO entry is included ONLY while the IO in scope is the GROUND
          -- one: 'emitEffect' discharges by label, and a user `effect IO =
          -- { ... }` override (permitted once, 'processEffectDecls') is an
          -- ordinary handleable effect that the entry ambient cannot
          -- discharge -- seeding its label here would re-open the CAF bypass
          -- for exactly that effect (typechecks, then NoMatchingHandler at
          -- run time; found by the 2026-07-06 whole-branch review). With IO
          -- overridden the entry ambient is the closed EMPTY row.
          env <- currentEnv
          let ioIsGround =
                maybe False (isGroundIO (Tx.pack "IO"))
                            (lookupEffect (Tx.pack "IO") env)
              entryAmbient
                | ioIsGround = RowExtend (Tx.pack "IO") (TCon TcUnit []) RowEmpty
                | otherwise  = RowEmpty
          effRef <- liftST (newSTRef entryAmbient)
          (bodyT, bodyNode) <- withEffRow effRef runBody
          pure (bodyT, mkDecl bodyNode)
    _ -> do
      -- Seed the ambient from the declared sig's effect row when there is one,
      -- so the body is checked AGAINST the declared effects: a closed sig row
      -- (e.g. `with IO`, or no `with` => empty) rejects any operation it does
      -- not list, at the call site, as UndischargedEffect. With no sig, start
      -- open and infer the effects.
      --
      -- `closeRow ambient` below runs unconditionally. When the sig row is open
      -- (`+ eff e` / `..`) this closes only THIS instantiation's tail; the
      -- binding's stored/printed scheme is the declared sig, whose open tail is
      -- preserved, and the closed instance still validates as an instantiation
      -- of it. So row polymorphism survives -- closing here only commits the
      -- throwaway body-checking copy.
      ambient0 <- case mSigEffRow of
        Just r  -> pure r
        Nothing -> freshRVar
      effRef <- liftST (newSTRef ambient0)
      (bodyT, bodyNode) <- withEffRow effRef runBody
      ambient <- liftST (readSTRef effRef)
      closeRow ambient
      pure (arrowsWithEffect pTys bodyT ambient, mkDecl bodyNode)
typeEquationWith _ _ Abs.LDSig{} = error "typeEquationWith: signature in equation list"
typeEquationWith _ _ Abs.LDPat{} = error "typeEquationWith: pattern bind in equation list"

-- | The effect row on the @n@-th arrow (1-indexed) of an instantiated sig type.
-- A curried equation @f x y = body@ performs its effects only when fully
-- applied, so the effect row sits on the INNERMOST arrow -- the @n@-th, where
-- @n@ is the number of pattern parameters -- which is also where the parser
-- attaches a trailing @with E@. 'Nothing' when there are fewer than @n@ arrows
-- (a zero-parameter value, or @n <= 0@).
effRowAtDepth :: Int -> Type s -> TC s (Maybe (Row s))
effRowAtDepth n ty
  | n <= 0    = pure Nothing
  | otherwise = do
      ty' <- force ty
      case ty' of
        TArr _ row rest
          | n == 1    -> pure (Just row)
          | otherwise -> effRowAtDepth (n - 1) rest
        _ -> pure Nothing

-- | Close an effect row: force it and, if it ends in an open row variable,
-- bind that tail to 'RowEmpty'. Concrete labels are preserved.
closeRow :: Row s -> TC s ()
closeRow row = do
  row' <- force row
  case row' of
    RowEmpty            -> pure ()
    RowExtend _ _ rest  -> closeRow rest
    TVar ref            -> liftST $ writeSTRef ref (Link RowEmpty)  -- open tail (row var)
    _                   -> pure ()  -- non-row (cannot occur)

-- | Build the curried function type for an equation, placing the equation's
-- ambient effect row on the INNERMOST arrow -- the one crossed when the
-- function is fully applied, where a curried `f x y = body` performs its
-- effects and where the parser attaches a trailing `with E`. Intermediate
-- arrows carry an empty row. A zero-parameter binding has no arrow to carry a
-- row; effects there flow through the body's own type instead.
arrowsWithEffect :: [Type s] -> Type s -> Row s -> Type s
arrowsWithEffect []         body _   = body
arrowsWithEffect [p]        body row = TArr p row body
arrowsWithEffect (p : rest) body row = TArr p RowEmpty (arrowsWithEffect rest body row)

-- | Peel one arrow type per element of @pTys@ off a Type, returning the
-- result type, and unify each peeled argument type with the corresponding
-- element of @pTys@. This ensures that pattern-bound variables
-- carry the concrete type from the signature before the body is checked,
-- enabling field access (p.x) and other type-directed operations to see the
-- record structure without waiting for the post-body unification pass.
-- Returns Nothing when sig arity does not match, just like 'peelArrows'.
peelArrowsWithArgUnify :: Type s -> [Type s] -> TC s (Maybe (Type s))
peelArrowsWithArgUnify ty [] = pure (Just ty)
peelArrowsWithArgUnify ty (pTy : rest) = do
  ty' <- force ty
  case ty' of
    TArr a _ b -> do
      unify Nothing pTy a
      peelArrowsWithArgUnify b rest
    _ -> pure Nothing  -- sig arity does not match pattern count

-- | Count the leading arrows of an operation type -- its arity. This must agree
-- with how 'peelArrowsWithArgUnify' consumes arguments (one 'TArr' per arg,
-- ignoring the effect-row slot), so the args/continuation split point is right.
-- A value op (e.g. @ask : U64@) has arity 0. The op type comes straight from a
-- freshly-instantiated scheme body, but force through any links to be safe.
arrowArity :: Type s -> TC s Int
arrowArity ty = do
  ty' <- force ty
  case ty' of
    TArr _ _ b -> (1 +) <$> arrowArity b
    _          -> pure 0

-- | Build a single-argument function type @T -> R@ riding the given effect row.
-- 'TArr' carries an effect-row slot (this is a Koka-style effect language), so
-- the row must be supplied; callers pass a fresh open row var, mirroring how
-- ordinary application allocates a per-call row (see 'inferExprW' EApp).
arrowT :: Type s -> Row s -> Type s -> Type s
arrowT a row b = TArr a row b

lhsAtomPats :: Abs.FunLHS -> [Abs.AtomPat]
lhsAtomPats (Abs.LHSPre _ aps) = aps
lhsAtomPats (Abs.LHSInfSym a _ b) = [a, b]
lhsAtomPats (Abs.LHSInfBT a _ b) = [a, b]

-- | The source position of a function's left-hand side, taken from the bound
-- name's token (the head 'FunName' for a prefix LHS, the operator token for an
-- infix LHS). Used to point arity-disagreement errors at the offending equation.
lhsPos :: Abs.FunLHS -> BNFC'Position
lhsPos (Abs.LHSPre fn _)                     = Just (funNamePos fn)
lhsPos (Abs.LHSInfSym _ (Abs.VarSym (p, _)) _) = Just p
lhsPos (Abs.LHSInfBT  _ (Abs.VarId  (p, _)) _) = Just p

funNamePos :: Abs.FunName -> (Int, Int)
funNamePos (Abs.FNBare    (Abs.VarId  (p, _))) = p
funNamePos (Abs.FNBareSym (Abs.VarSym (p, _))) = p
funNamePos (Abs.FNParen   (Abs.VarSym (p, _))) = p

-- ---------------------------------------------------------------------------
-- Top-level program inference
-- ---------------------------------------------------------------------------

-- | The typed-AST output: one entry per top-level binding, carrying its
-- generalised scheme together with the binding's typed clauses. Each clause is
-- a @(params, body)@ pair; a single-equation binding has exactly one clause and
-- a multi-equation function carries one clause per equation (all sharing the
-- same arity). The params and bodies are frozen ('CType' annotations) under the
-- SAME quantification mapping as the scheme, so their per-node 'CTGen'
-- numbering agrees with the scheme's quantifiers across every clause. Each
-- clause body already folds in any @where@ clause as a leading 'Ty.TLet' (see
-- 'typeEquationWith'), so a single body field per clause carries the whole RHS.
--
-- No 'Eq' instance: 'TExpr'/'Tpat' are not 'Eq'.
data TypedDecl = TypedDecl
  { tdName     :: Text
  , tdScheme   :: Scheme
  , tdClauses  :: [([TPat], TExpr)]
  , tdEvidence :: [(Text, Constraint)]   -- evidence params (name, constraint)
  , tdIsExtern :: Bool                   -- True iff a prelude @extern@ (no body)
  }
  deriving (Show)

-- | Pipeline entry parameterised by the seed env and module origin.
-- The seed env is the irreducible pre-env (from Builtins) overlaid with
-- every imported module's exported env, as composed by the module loader.
-- Origin gates bodyless-sig warnings: silent for Embedded (Base),
-- emitted for UserFile.
inferProgramWith
  :: Env -> Origin -> Abs.Module
  -> Either TypeError (Env, [TypedDecl], [Warning])
inferProgramWith seedEnv origin (Abs.Module decls) =
  case runTC seedEnv (inferProgramTC seedEnv origin decls) of
    Left err              -> Left err
    Right ((env, tds), ws) -> Right (env, tds, ws)

-- | Back-compat: keep the v1 signature so existing direct callers
-- (test harness, smoke tests) continue to work. Uses the hand-coded
-- initialEnv as the seed; discards warnings; tags the file as UserFile.
inferProgram :: Abs.Module -> Either TypeError (Env, [TypedDecl])
inferProgram m =
  case inferProgramWith Builtins.initialEnv (UserFile "<unknown>") m of
    Left err -> Left err
    Right (env, decls, _warnings) -> Right (env, decls)

inferProgramTC
  :: Env -> Origin -> [Abs.Decl] -> TC s (Env, [TypedDecl])
inferProgramTC seedEnv origin decls = do
  -- Synthetic dict data types: each class registers a one-constructor dict
  -- data type (data Eq a = Eq$Dict (a->a->Bool) (a->a->Bool)). These cons
  -- must register BEFORE the synthetic instance bindings infer (the dict
  -- assembly applies the dict con). Non-class modules yield no dictData, so
  -- this is a no-op for all existing programs.
  let dictData = mapMaybe Class.dictDataDecl decls
  -- Pass 1: register data declarations against the seed env (which is
  -- the irreducible pre-env overlaid with imports for the loader path,
  -- or just Builtins.initialEnv for the back-compat path).
  env1  <- processDataDecls seedEnv (decls ++ dictData)
  env1e <- processEffectDecls env1 decls
  -- Register foreign module declarations. Runs after effects so that `with IO`
  -- in a member's declared type resolves correctly (IO is in the env from the
  -- effect pass or the seed env).
  env1f <- processForeignDecls env1e decls
  -- Register class then instance declarations (pure registrars from the Class
  -- module). Classes inject each method's constrained scheme into envVars, so
  -- equation bodies that use `==` resolve it; instances populate the solver's
  -- registry consulted at top-level discharge. Order matters: an instance head
  -- references its class. class/instance decls are NOT value bindings
  -- (toLocalDecl drops them), so they never enter localDecls.
  env1c <- either throwError pure
             (foldM Class.processClassDecl env1f [ d | d@Abs.DClass{} <- decls ])
  env1i <- either throwError pure
             (foldM Class.processInstanceDecl env1c [ d | d@Abs.DInstance{} <- decls ])
  -- Desugar each instance into synthetic typed top-level bindings (its method
  -- impls/defaults + the dict assembly) that flow through the existing
  -- inference pipeline. Non-class modules have no DInstance, so instB is [].
  instB <- either throwError (pure . concat)
             (mapM (Class.instanceBindings [ d | d@Abs.DClass{} <- decls ])
                   [ d | d@Abs.DInstance{} <- decls ])
  -- Convert top-level decls to LocalDecl form for reuse of inferLetGroup.
  -- `extern` decls normalize to bodyless LDSigs here; their names are collected
  -- separately so the bodyless-sig lint is suppressed for them (extern is
  -- explicit intent, not an accidental missing body).
  let localDecls = concatMap toLocalDecl (decls ++ instB)
      externs    = externNames decls
  -- Pass 2 + 3: collect sigs and infer equations via inferTopLetGroup.
  -- Warnings (BodylessBinding, RowShadow, …) are emitted into the TC
  -- monad's warning channel via addWarning; they are collected by runTC.
  withEnv (const env1i) $ do
    tds <- inferTopLetGroup origin externs localDecls
    env2 <- currentEnv
    -- Names of marked carrier tycons (extern data/type), read off the env's
    -- tcCarrier flags. Threaded into both post-inference soundness passes so
    -- carrier-ness rides the marker, not a TyCon tag (slice 4d).
    let carrierTys = Set.fromList
          [ n | (n, info) <- Map.toList (envTyCons env2), tcCarrier info ]
        -- The AFFINE subset of 'carrierTys' -- carriers flagged 'tcAffine'
        -- (consume-once). Fed ONLY to 'checkFutureAffine' below, so that
        -- check's consume-once bound applies to 'Suspension'/'Step'/
        -- 'ContCell' but not to a non-affine carrier such as 'Borrow' (FFI
        -- Slice 3 Task 1), which stays second-class via the escape check
        -- (still driven by the full, unfiltered 'carrierTys') without being
        -- consume-once.
        affineCarrierTys = Set.fromList
          [ n | (n, info) <- Map.toList (envTyCons env2), tcCarrier info, tcAffine info ]
    -- Part 1 gate: `extern` is the trust anchor for the soundness analyses (the
    -- one-shot relaxation's escape sink and the affine check's non-consuming
    -- reader are recognised by EXTERN IDENTITY — see C2/C3). Only the standard
    -- prelude (Embedded origin) may mint an `extern`; a UserFile that declared
    -- one could forge that trusted identity. Reject any `extern` in a UserFile.
    case origin of
      Embedded   -> pure ()
      UserFile _ -> do
        forM_ (externDecls decls) $ \(n, pos) ->
          throwError (ExternNotAllowed (Just pos) n)
        forM_ (externTypeDecls decls) $ \(n, pos) ->
          throwError (ExternNotAllowed (Just pos) n)
    -- Carrier rule (named effect instances, §4.3): a second-class escape check
    -- over the frozen typed AST. A handle (or a closure capturing one) may not
    -- escape its scope. Runs after inference because handle-ness is read off
    -- types. Surfaces here so a violating program fails type-checking. The
    -- resolver reads a callee's DECLARED parameter types off its scheme (env
    -- vars + constructors + the just-inferred locals), so a polymorphic param a
    -- handle merely flowed into is NOT mistaken for a genuine handle slot.
    let localSchemes = Map.fromList [ (tdName td, tdScheme td) | td <- tds ]
        resolveParams n =
          case Map.lookup n localSchemes of
            Just s  -> Just (schemeParamTypes s)
            Nothing -> case lookupVar n env2 of
              Just s  -> Just (schemeParamTypes s)
              Nothing -> case lookupCon n env2 of
                Just ci -> Just (schemeParamTypes (conScheme ci))
                Nothing -> Nothing
    -- A carrier PRODUCER exemption is granted ONLY to the standard prelude
    -- (Embedded origin): @Control@'s @start@/@step@ are the blessed
    -- constructors of a 'Step'. It covers TWO shapes, both origin-gated by the
    -- same boundary (the same trust boundary the Part 1 `extern` gate uses):
    --   * the clause-tail exemption: the tail of a clause body may be an
    --     inline-produced 'Step'/'Suspension' matching the declared result type
    --     (gated additionally on the declared result being a carrier); and
    --   * the producer-THUNK exemption: a @\\() -> Completed n@ fresh-carrier
    --     factory thunk (the @driveConc@ starter-thunk shape).
    -- A UserFile returning a carrier (e.g. @leak n = Completed n@) or wrapping one
    -- in a thunk (e.g. @leak n = \\() -> Completed n@) must still be rejected with
    -- 'CarrierEscape' — both are escapes in user code.
    let producerExempt = case origin of Embedded -> True; UserFile _ -> False
        -- Each top-level binding's source position (its LHS name token), so a
        -- carrier/affine violation is reported AT the offending definition
        -- instead of positionlessly (bug #13). TypedDecl carries no span, so we
        -- recover it from the original decls by name.
        declPosMap = Map.fromList
          [ (funLHSName lhs, lhsPos lhs) | Abs.DEqn lhs _ _ <- decls ]
        declSpan td = Map.findWithDefault Nothing (tdName td) declPosMap
    forM_ tds $ \td ->
      let arity = case tdClauses td of
                    ((pats, _) : _) -> length pats
                    []              -> 0
      in either throwError pure
           (checkCarriers (CarrierTys carrierTys) resolveParams
                          producerExempt
                          (producerExempt && resultIsAffineCarrier carrierTys arity (tdScheme td))
                          (declSpan td) (tdName td) (tdClauses td))
    -- Affine consumption bound on Futures (slice 4b, Task 5): beside the carrier
    -- rule, a second LOCAL post-inference pass rejecting a coroutine Future
    -- consumed more than once (resume XOR cancel; value reads do not count).
    -- Reader names this module REDEFINES with a regular (non-extern) top-level
    -- binding: such a name is the module's own function, NOT the prelude extern
    -- reader, so the affine check must not trust it. An `extern` reader (the
    -- prelude's own `value`) is excluded — it IS the trusted identity. UserFiles
    -- have no externs (Part 1 gate), so every reader-named UserFile def lands here.
    let ownNonExtern = Set.fromList [ tdName td | td <- tds
                                    , not (Set.member (tdName td) externs) ]
    forM_ tds $ \td ->
      either throwError pure
        (checkFutureAffine (AffineCarrierTys affineCarrierTys) ownNonExtern (declSpan td) (tdName td) (tdClauses td))
    let finalEnv = foldr (\td e -> extendVar (tdName td) (tdScheme td) e) env2 tds
    pure (finalEnv, tds)

-- | The @extern@ declarations in a module, as (name, position) pairs (one entry
-- per name, expanding comma-separated names). Used by the Part 1 gate to reject
-- any @extern@ in a UserFile module.
externDecls :: [Abs.Decl] -> [(Text, (Int, Int))]
externDecls = concatMap go
  where
    go (Abs.DExtern sn extras _) =
      (sigNameText sn, sigNamePos sn)
        : [ (sigNameText x, sigNamePos x) | Abs.SNCons x <- extras ]
    go (Abs.DLocal d) = go d
    go _              = []

-- | The @extern data@/@extern type@ declarations, as (tycon-name, position)
-- pairs. Used by the Part-1 gate to reject either in a UserFile: a marked
-- carrier tycon is a trust anchor, mintable only by the standard prelude.
externTypeDecls :: [Abs.Decl] -> [(Text, (Int, Int))]
externTypeDecls = concatMap go
  where
    go (Abs.DExternData (Abs.ConId (pos, n)) _ _) = [(n, pos)]
    go (Abs.DExternType (Abs.ConId (pos, n)) _)   = [(n, pos)]
    go (Abs.DLocal d)                             = go d
    go _                                          = []

-- | The declared parameter types of a scheme, in order, by peeling its body's
-- arrows. Polymorphic positions remain 'CTGen' — this is exactly the property
-- the carrier rule relies on to distinguish a genuine handle-typed parameter
-- from a polymorphic slot a handle merely flowed into.
schemeParamTypes :: Scheme -> [CType]
schemeParamTypes = go . schemeBody
  where
    go (CTArr a _ b) = a : go b
    go _             = []

-- | Is a binding's DECLARED result type (after applying its @arity@ value params)
-- a CARRIER? (The @Affine@ in the name is legacy: this is fed the FULL carrier set,
-- so it answers for any carrier — a coroutine 'Step'/'Suspension' AND the non-affine
-- 'Borrow'.) Such a binding is a carrier PRODUCER (e.g. @start@/@step@ in
-- @Control@ return a 'Step'; a 'Borrow'-returning prelude equation returns a
-- fresh borrow), so the carrier rule permits the flat tail of its body to be an
-- inline-produced carrier of that type (see 'checkCarriers' @resultIsCarrier@).
-- It MUST use the full carrier set: it is the tail-position complement of
-- 'isInlineFutureApp', which also consults the full set, so filtering to the affine
-- subset would over-reject (every 'Borrow'-returning prelude equation would become
-- un-writable). Escape and consume-once are orthogonal — the affine subset gates
-- only 'checkFutureAffine', never this escape-exemption. Peels exactly @arity@
-- arrows, so a function that RETURNS a function (a partial-application producer)
-- is judged on its true result, not an intermediate arrow.
resultIsAffineCarrier :: Set.Set Text -> Int -> Scheme -> Bool
resultIsAffineCarrier carrierTys arity = isCarrier . peel arity . schemeBody
  where
    peel 0 t              = t
    peel n (CTArr _ _ b)  = peel (n - 1) b
    peel _ t              = t
    isCarrier (CTCon (TcUser n) _) = Set.member n carrierTys
    isCarrier _                    = False

-- | Convert a top-level Decl to zero or more LocalDecls so we can reuse
-- the existing inferLetGroup machinery.
toLocalDecl :: Abs.Decl -> [Abs.LocalDecl]
toLocalDecl (Abs.DEqn lhs body mw) = [Abs.LDEqn lhs body mw]
toLocalDecl (Abs.DSig sn extras ty) = [Abs.LDSig sn extras ty]
-- An `extern` decl is a compiler-hole primitive: same shape as a bodyless
-- DSig (prim by name, sentinel TypedDecl), so it normalizes to an LDSig and
-- flows through the identical inference path. The ONLY difference is that the
-- bodyless-sig lint is suppressed for these names (see 'externNames' /
-- 'inferTopLetGroup'), since `extern` is explicit intent.
toLocalDecl (Abs.DExtern sn extras ty) = [Abs.LDSig sn extras ty]
toLocalDecl _ = []

-- | The set of names declared by `extern` decls. The bodyless-sig warning must
-- not fire for these (extern is an explicit primitive marker, not an accidental
-- missing body). DLocal-wrapped externs are unwrapped so `local extern f : T`
-- is recognised too.
externNames :: [Abs.Decl] -> Set.Set Text
externNames = Set.fromList . concatMap go
  where
    go (Abs.DExtern sn extras _) = sigNameText sn : map commaName extras
    go (Abs.DLocal d)            = go d
    go _                         = []
    commaName (Abs.SNCons sn) = sigNameText sn

-- | Type the top-level declarations as one big mutually-recursive let,
-- returning one 'TypedDecl' per binding in binding order. Each binding with a
-- body carries its frozen typed params + body (see 'finalizeGroupTyped');
-- bodyless sigs carry their declared scheme with empty params and a sentinel
-- body (the bound name at its declared type), since they have no RHS. Non-fatal
-- warnings (e.g. bodyless top-level sigs in UserFile origin) are emitted into
-- the TC monad's warning channel via 'addWarning' and collected by 'runTC'.
inferTopLetGroup
  :: Origin -> Set.Set Text -> [Abs.LocalDecl] -> TC s [TypedDecl]
inferTopLetGroup origin externs localDecls = do
  let (sigs, eqns) = partitionLocalDecls localDecls
  sigMap <- buildSigMap sigs
  let groups        = groupEquations eqns
      coveredEqn    = Set.fromList (map fst groups)
  -- Arity-agreement check: every equation for a given name must take the same
  -- number of arguments. Disagreement (e.g. `f 0 = 0` then `f x y = y`) is a
  -- malformed function definition and is rejected up front, before inference.
  forM_ groups $ \(gname, eqs) -> do
    let arities = [ (length (lhsAtomPats lhs), lhsPos lhs)
                  | Abs.LDEqn lhs _ _ <- eqs ]
    case arities of
      []              -> pure ()
      ((a0, _) : rest) -> forM_ rest $ \(a, pos) ->
        when (a /= a0) $ throwError (ClauseArityMismatch pos gname a0 a)
  let
      -- Walk `sigs` in source order so warnings + bindings appear in the
      -- order names were declared, not Map order (alphabetical).
      sigOnlyNames    = [ n | n <- sigNamesInOrder sigs
                            , Map.member n sigMap
                            , not (Set.member n coveredEqn) ]
      -- Bodyless sigs have no RHS, so they carry the declared scheme with no
      -- params and a sentinel body: the bound name at its scheme body type.
      sigOnlyBindings =
        [ let s = sigMap Map.! n
          in TypedDecl { tdName = n, tdScheme = s
                       , tdClauses = [([], Ty.Texp (schemeBody s) (Ty.TVar n))]
                       , tdEvidence = []
                       , tdIsExtern = Set.member n externs }
        | n <- sigOnlyNames ]
  -- Every binding that has a declared signature -- bodyless OR with a body --
  -- is in scope as its declared scheme while peer equations are typechecked, so
  -- references instantiate it polymorphically. Two reasons: (1) a bodyless sig
  -- like `(+) : U64 -> U64 -> U64` must be visible to `add x y = x + y`;
  -- (2) routing a SIGNED-with-body binding through its monomorphic placeholder
  -- instead let its signature's skolemised variable escape into a group-mate's
  -- use (RigidEscape) -- so signed bindings are referenced via the scheme, and
  -- only UNSIGNED bindings use the placeholder.
  let extendSig env = foldr (\(n, s) e -> extendVar n s e) env (Map.toList sigMap)
  unified <- withEnv extendSig $ enterLevel $ do
    placeholders <- mapM (allocatePlaceholderTVar sigMap) groups
    let monoRec = foldr (\(n, tv, _) m -> if Map.member n sigMap
                                            then m
                                            else Map.insert n tv m)
                        Map.empty placeholders
    -- Infer each binding's equations, then DRAIN the constraint accumulator
    -- immediately so each binding owns exactly the constraints raised by its own
    -- body (including any inner let/where bodies, which do not drain). The
    -- drained args are mutable Type s refs that keep being resolved by later
    -- group-mates' unification; they are frozen at outer level in
    -- 'finalizeGroupTyped'. (Bindings with no constrained use drain [], so the
    -- non-class path is byte-identical.)
    forM placeholders $ \ph@(_, _, phEqns) -> do
      (n, tv, ds) <- unifyGroupWith monoRec sigMap ph
      cs <- takeConstraints
      pure (n, tv, ds, cs, eqnDefnSpan phEqns)
  -- Finalize each binding at the top level: generalize (or verify its sig) AND
  -- freeze its typed params + body into a TypedDecl under one quantification
  -- mapping (so node CTGens agree with the scheme). The top level has no outer
  -- scope, so freezing the whole tree here is safe and 'finalizeGroupTyped'
  -- never reports escape. Each binding carries its own drained constraints.
  topResults <- withEnv extendSig $ mapM (finalizeGroupTyped sigMap) unified
  -- Emit a warning only for UserFile origin so Base (Embedded) primitive
  -- schemes stay silent.
  case origin of
    Embedded   -> pure ()
    UserFile _ -> forM_ sigOnlyNames $ \n ->
      -- `extern` decls are explicit primitive markers; their bodyless-ness is
      -- intentional, so they are exempt from the bodyless-sig lint.
      when (not (Set.member n externs)) $
        addWarning (BodylessBinding n (sigPos sigs n))
  -- Reject head-pattern shapes the match compiler cannot lower BEFORE the
  -- coverage check runs, so no bogus RedundantClause/NonExhaustiveMatch warning
  -- precedes the error and elaboration never reaches its raw `error`. This is a
  -- hard compiler limitation, NOT origin-gated. A group only needs rejecting if
  -- it ROUTES THROUGH the match compiler; the cheap elabParams projection path
  -- (mirrored from 'Elaborate.irrefutableHead' / 'elabTopBind') handles
  -- single-clause irrefutable/record top-level heads fine, so it is exempt.
  do
    rejectEnv <- currentEnv
    let resultMap0 = Map.fromList [ (tdName td, td) | td <- topResults ]
    forM_ groups $ \(gname, eqs) ->
      case Map.lookup gname resultMap0 of
        Nothing -> pure ()
        Just td
          | isBodylessSentinel td -> pure ()
          | otherwise -> do
              let clauses = tdClauses td
                  cheapHead (Ty.Tpat _ pnode) = case pnode of
                    Ty.TPVar _   -> True
                    Ty.TPWild    -> True
                    Ty.TPUnit    -> True
                    Ty.TPCon c _ -> case lookupRecordCon c rejectEnv of
                      Just _  -> True
                      Nothing -> False
                    Ty.TPAs _ inner -> cheapHead inner
                    _            -> False
                  cheapPath = case clauses of
                    [(ps, _)] -> all cheapHead ps
                    _         -> False
                  routesToMatch = not cheapPath
                  unsupported =
                    firstJust [ unsupportedHeadPat rejectEnv p
                              | (ps, _) <- clauses, p <- ps ]
                  pos = case eqs of (Abs.LDEqn lhs _ _ : _) -> lhsPos lhs; _ -> Nothing
              when routesToMatch $
                case unsupported of
                  Just desc -> throwError (UnsupportedHeadPattern pos gname desc)
                  Nothing   -> pure ()
  -- Exhaustiveness + redundancy check over each group's clause HEADS (not body
  -- `case` exprs). A group with a single variable head (e.g. `f x = case x of`)
  -- yields a one-row all-wildcard matrix -> exhaustive, no warning, which limits
  -- false positives. Warnings flow through the same channel as BodylessBinding.
  -- Gated on UserFile origin: Embedded (Base) modules are curated and must
  -- not trigger coverage warnings.
  case origin of
    Embedded   -> pure ()
    UserFile _ -> do
      cenv <- currentEnv
      let oracle    = buildMatchOracle cenv
          resultMap = Map.fromList [ (tdName td, td) | td <- topResults ]
      forM_ groups $ \(gname, eqs) ->
        case Map.lookup gname resultMap of
          Nothing -> pure ()
          Just td -> case tdClauses td of
            []      -> pure ()
            clauses@((firstPats, _) : _)
              | isBodylessSentinel td -> pure ()
              | otherwise -> do
                  let arity = length firstPats
                      rows  = [ Match.Row { Match.rowPats  = map (typedPatToMPat cenv) ps
                                          , Match.rowSubst = []
                                          , Match.rowJoin  = JoinId (Unique 0)  -- unused by coverage
                                          , Match.rowOrder = []
                                          , Match.rowIndex = ix }
                              | (ix, (ps, _)) <- zip [0 ..] clauses ]
                      cov = matchCoverage oracle arity rows
                      pos = case eqs of (Abs.LDEqn lhs _ _ : _) -> lhsPos lhs; _ -> Nothing
                  unless (covExhaustive cov) $
                    addWarning (NonExhaustiveMatch pos gname)
                  forM_ (covRedundant cov) $ \ix ->
                    addWarning (RedundantClause pos gname ix)
  pure (topResults ++ sigOnlyBindings)

-- | A bodyless top-level signature surfaces as a sentinel 'TypedDecl' (no
-- params, body just the bound name referencing itself). Coverage must not warn
-- on these -- they have no real clause head. (Mirrors 'isBodylessSig' in
-- Elaborate; duplicated here because Infer cannot import Elaborate -- Elaborate
-- imports Infer, so sharing would form a cycle.)
isBodylessSentinel :: TypedDecl -> Bool
isBodylessSentinel td = case tdClauses td of
  [([], Ty.Texp _ (Ty.TVar v))] -> v == tdName td
  _                             -> False

-- | Build the constructor oracle the match compiler needs from the type env.
-- DELIBERATE DUPLICATION of 'Wok.IR.Elaborate.buildOracle': Infer cannot import
-- Elaborate (Elaborate imports Infer -> import cycle), so the oracle-building
-- logic is copied here. Keep the two in sync if either changes.
buildMatchOracle :: Env -> ConOracle
buildMatchOracle env = ConOracle
  { coArity = \c ->
      case tupleArity c of
        Just n  -> n
        Nothing
          | c == Tx.pack "Nil"  -> 0
          | c == Tx.pack "Cons" -> 2
          | Just ci <- lookupCon c env -> conArity ci
          | otherwise -> 0
  , coSiblings = \c ->
      case tupleArity c of
        Just n  -> Just [tupleTag n]
        Nothing
          | c `elem` [Tx.pack "Nil", Tx.pack "Cons"] -> Just [Tx.pack "Nil", Tx.pack "Cons"]
          | Just ci <- lookupCon c env
          , Just ti <- lookupTyCon (conTyCon ci) env -> Just (tcCons ti)
          | otherwise -> Nothing
  }
  where
    tupleArity t
      | Tx.isPrefixOf (Tx.pack "Tuple") t
      , [(n, "")] <- reads (Tx.unpack (Tx.drop 5 t)) = Just n
      | otherwise = Nothing

-- | Scan a head pattern (recursively, including nested inside tuples / cons /
-- constructor args) for a shape the match compiler cannot lower. Returns a
-- human-readable description of the first such shape, or Nothing if the pattern
-- is fully supported. Used only for groups that ROUTE THROUGH the match
-- compiler (see 'inferTopLetGroup'); single-clause cheap-path heads are exempt.
unsupportedHeadPat :: Env -> TPat -> Maybe Tx.Text
unsupportedHeadPat env = go
  where
    go (Ty.Tpat _ pnode) = case pnode of
      Ty.TPList []      -> Nothing
      Ty.TPList _       -> Just (Tx.pack "non-empty list literal pattern (use h :: t)")
      Ty.TPTuple ps     -> firstJust (map go ps)
      Ty.TPCons h t     -> firstJust [go h, go t]
      Ty.TPCon c ps     -> case lookupRecordCon c env of
        Just _  -> Just (Tx.pack "record-constructor pattern in a multi-clause/refutable head")
        Nothing -> firstJust (map go ps)
      Ty.TPAs _ inner   -> go inner
      _                 -> Nothing

-- | First 'Just' in a list, or 'Nothing' if all are 'Nothing'.
firstJust :: [Maybe a] -> Maybe a
firstJust = listToMaybe . catMaybes

-- | Translate a typed pattern into a match-compiler 'MPat' for COVERAGE only.
-- DELIBERATE DUPLICATION of 'Wok.IR.Elaborate.toMPat' (cycle prevents sharing),
-- with two differences so coverage never crashes and never alters typecheck
-- success/failure:
--   * a record-constructor pattern is treated as an irrefutable 'MVar Nothing'
--     (records are single-constructor: one record clause counts as total);
--   * a NON-EMPTY list-literal pattern is treated as 'MVar Nothing' (opaque /
--     irrefutable for coverage). Elaboration still rejects these later; coverage
--     must not crash type-checking, which currently succeeds for such programs.
typedPatToMPat :: Env -> TPat -> MPat
typedPatToMPat env (Ty.Tpat ty pnode) = MPat ty (go pnode)
  where
    go (Ty.TPVar v)    = MVar (Just v)
    go Ty.TPWild       = MVar Nothing
    go Ty.TPUnit       = MVar Nothing
    go (Ty.TPLitI i)   = MLit (LInt i)
    go (Ty.TPLitS s)   = MLit (LStr s)
    go (Ty.TPLitC c)   = MLit (LChar c)
    go (Ty.TPTuple ps) = MCon (tupleTag (length ps)) (map (typedPatToMPat env) ps)
    go (Ty.TPList [])  = MCon (Tx.pack "Nil") []
    go (Ty.TPList _)   = MVar Nothing   -- non-empty list literal: opaque for coverage
    go (Ty.TPCons h t) = MCon (Tx.pack "Cons") [typedPatToMPat env h, typedPatToMPat env t]
    go (Ty.TPCon c ps) = case lookupRecordCon c env of
      Just _  -> MVar Nothing           -- record con: single-constructor, irrefutable
      Nothing -> MCon c (map (typedPatToMPat env) ps)
    go (Ty.TPAs _ inner) = let MPat _ m = typedPatToMPat env inner in m
      -- `inner as name`: as-name is irrelevant to coverage; mirror the inner pattern

-- | Find the BNFC'Position of the LDSig that declared @name@. Multi-name
-- sigs share the head LDSig's position.
sigPos :: [Abs.LocalDecl] -> Text -> BNFC'Position
sigPos sigs name = go sigs
  where
    go [] = error
      ("sigPos: name " ++ Tx.unpack name
        ++ " absent from sigs (broken invariant: callers must filter to known sig names)")
    go (Abs.LDSig sn extras _ : rest)
      | sigNameText sn == name = Just (sigNamePos sn)
      | any (\(Abs.SNCons x) -> sigNameText x == name) extras
          = Just (sigNamePos sn)
      | otherwise = go rest
    go (_ : rest) = go rest

-- | Flatten LDSig decls into the source-order sequence of names they declare,
-- preserving multi-name fan-out (`a, b, c : T` -> ["a", "b", "c"]).
sigNamesInOrder :: [Abs.LocalDecl] -> [Text]
sigNamesInOrder = concatMap one
  where
    one (Abs.LDSig sn extras _) =
      sigNameText sn : [ sigNameText x | Abs.SNCons x <- extras ]
    one _ = []

-- ---------------------------------------------------------------------------
-- Pretty-printing closed types and schemes
-- ---------------------------------------------------------------------------

-- | Render a Scheme as a single line: "forall a b. (a -> b) -> [a] -> [b]"
prettyScheme :: Scheme -> Text
prettyScheme (Scheme [] _ body) = prettyCType body
prettyScheme (Scheme vars _ body) =
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
prettyCType (CTCon TcU64    []) = Tx.pack "U64"
prettyCType (CTCon TcU32    []) = Tx.pack "U32"
prettyCType (CTCon TcBytes  []) = Tx.pack "Bytes"
prettyCType (CTCon TcChar   []) = Tx.pack "Char"
prettyCType (CTCon TcString []) = Tx.pack "String"
prettyCType (CTCon TcNever  []) = Tx.pack "Never"
prettyCType (CTCon TcBool   []) = Tx.pack "Bool"
prettyCType (CTCon TcUnit   []) = Tx.pack "()"
prettyCType (CTCon TcList [x]) =
  Tx.concat [Tx.pack "[", prettyCType x, Tx.pack "]"]
prettyCType (CTCon TcArray [x]) =
  Tx.concat [Tx.pack "Array ", prettyCTypeAtom x]
prettyCType (CTCon (TcTuple _) xs) =
  Tx.concat
    [ Tx.pack "("
    , Tx.intercalate (Tx.pack ", ") (map prettyCType xs)
    , Tx.pack ")"
    ]
prettyCType (CTCon (TcUser n) []) = n
prettyCType (CTCon (TcUser n) xs0) =
  case filter (/= CREmpty) xs0 of
    []  -> n
    xs  -> Tx.concat [n, Tx.pack " ", Tx.intercalate (Tx.pack " ") (map prettyCTypeAtom xs)]
prettyCType (CTCon (TcEffect n) []) = n
prettyCType (CTCon (TcEffect n) xs0) =
  case filter (/= CREmpty) xs0 of
    []  -> n
    xs  -> Tx.concat [n, Tx.pack " ", Tx.intercalate (Tx.pack " ") (map prettyCTypeAtom xs)]
-- @Handler (E params) a b@: the trailing two args are input/answer; anything
-- before them is the effect's own parameter list, rendered as an effect
-- application. (An under-applied TcHandler cannot be written or inferred, so
-- the fallback 'show' arm below covers any malformed remainder.)
prettyCType (CTCon (TcHandler n) xs) | length xs >= 2 =
  let (ps, io) = splitAt (length xs - 2) xs
      effTxt = case ps of
        [] -> n
        _  -> Tx.concat [Tx.pack "(", n, Tx.pack " ",
                         Tx.intercalate (Tx.pack " ") (map prettyCTypeAtom ps), Tx.pack ")"]
  in Tx.concat (Tx.pack "Handler " : effTxt : concat [ [Tx.pack " ", prettyCTypeAtom t] | t <- io ])
prettyCType (CTCon c xs) =
  Tx.concat [Tx.pack (show c), Tx.pack " ",
             Tx.intercalate (Tx.pack " ") (map prettyCTypeAtom xs)]
prettyCType (CTRecord tag row) =
  Tx.concat [tag, Tx.pack " { ", prettyCRow row, Tx.pack " }"]
prettyCType (CTArr a CREmpty b) =
  Tx.concat [prettyCTypeArg a, Tx.pack " -> ", prettyCType b]
prettyCType (CTArr a r b) =
  Tx.concat
    [ prettyCTypeArg a
    , Tx.pack " -> "
    , prettyCType b
    , Tx.pack " with "
    , prettyEffectRow r
    ]
-- Row nodes (kind KEffect) are normally rendered via 'prettyCRow' (record rows)
-- or 'prettyEffectRow' (arrow rows); these arms only keep 'prettyCType' total.
-- Defensive: a row node reaching 'prettyCType' as a standalone type. In slice B
-- row arguments are row VARIABLES ('CTGen'), which print as a var name, so a
-- concrete row node should not surface here -- these arms render it readably
-- (deliberately the nested `{l | rest}` form, distinct from 'prettyCRow's flat
-- comma list used for the arrow `with`-clause path) rather than the old
-- empty-string delegation.
prettyCType CREmpty             = Tx.pack "{}"
prettyCType (CRExtend l _ rest) = Tx.concat [Tx.pack "{", l, Tx.pack " | ", prettyCType rest, Tx.pack "}"]

prettyCTypeArg :: CType -> Text
prettyCTypeArg t@CTArr{} = Tx.concat [Tx.pack "(", prettyCType t, Tx.pack ")"]
prettyCTypeArg t = prettyCType t

prettyCTypeAtom :: CType -> Text
prettyCTypeAtom t@CTArr{} = Tx.concat [Tx.pack "(", prettyCType t, Tx.pack ")"]
prettyCTypeAtom t@(CTCon (TcUser _) (_:_)) =
  Tx.concat [Tx.pack "(", prettyCType t, Tx.pack ")"]
prettyCTypeAtom t@(CTCon (TcEffect _) (_:_)) =
  Tx.concat [Tx.pack "(", prettyCType t, Tx.pack ")"]
prettyCTypeAtom t = prettyCType t

prettyCRow :: CRow -> Text
prettyCRow CREmpty = Tx.empty
prettyCRow (CRExtend l _ rest) = Tx.concat [l, Tx.pack ",", prettyCRow rest]
prettyCRow (CTGen i) = Tx.concat [Tx.pack "r", Tx.pack (show i)]
prettyCRow _ = error "prettyCRow: expected a row"

-- | Render an arrow's effect row in surface @with@ form: effect labels joined
-- by @ + @, with an open tail printed as @eff <var>@. The arrow's row slot only
-- ever carries effects (record rows are printed by 'prettyCRow' within
-- 'CTRecord'); the row-variable name uses the same 'varName' scheme as the
-- enclosing scheme's quantifiers so the two agree.
prettyEffectRow :: CRow -> Text
prettyEffectRow = go True
  where
    go _ CREmpty = Tx.empty
    go first (CRExtend l _ rest) = Tx.concat [lead first, l, go False rest]
    go first (CTGen i) = Tx.concat [lead first, Tx.pack "eff ", varName i]
    go _ _ = error "prettyEffectRow: expected a row"
    lead first = if first then Tx.empty else Tx.pack " + "

