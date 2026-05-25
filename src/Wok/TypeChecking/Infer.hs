-- | Type inference for the wok HM core. This module starts by exporting
-- the freeze-and-quantify @generalize@ pass and its dual @instantiate@.
-- Later tasks build out the full inferrer on top of these.
module Wok.TypeChecking.Infer
  ( generalize
  , instantiate
  , translateSig
  , processDataDecls
  , inferPat
  , inferExpr
  , inferProgram
  , TypedDecl (..)
  , prettyScheme
  , prettyCType
  ) where

import qualified Control.Monad.ST
import Control.Monad (foldM, forM, when)
import Control.Monad.Except (throwError)
import qualified Data.List
import qualified Data.Map.Strict as Map
import Data.STRef (STRef, newSTRef, readSTRef, writeSTRef)
import qualified Data.Text as Tx
import Data.Text (Text)
import qualified GeneratedParser.Wok.Abs as Abs
import qualified Wok.TypeChecking.Builtins as Builtins
import Wok.TypeChecking.Env
  ( ConInfo (..), Env, TyConInfo (..)
  , extendCon, extendTyCon, extendVar, lookupCon, lookupTyCon, lookupVar )
import Wok.TypeChecking.Error (TypeError (..))
import Wok.TypeChecking.Monad (TC, currentEnv, currentLevel, enterLevel, extendVarTC, freshTVar, freshUniq, liftST, runTC, withEnv)
import Wok.TypeChecking.Unify (force, forceRow, unify)
import Wok.TypeChecking.Types
  ( CRow (..), CType (..), Kind (..), Level (..), RVar (..), Row (..)
  , Scheme (..), TyCon (..), TVar (..), Type (..) )

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
    pure (Scheme (reverse pairs) body)

-- Internal: walk a Type s, replacing unbound vars at level > outer with
-- CTGens, sharing slots by uniq via 'seen'. Pure-ST so we don't pay
-- TC monad overhead per node.
freezeQuantify
  :: Int                              -- ^ outer level
  -> STRef s Int                      -- ^ next CTGen index
  -> STRef s (Map.Map Int Int)        -- ^ uniq -> CTGen index
  -> STRef s [(Int, Kind)]            -- ^ accumulator (reversed)
  -> Type s
  -> Control.Monad.ST.ST s CType
freezeQuantify outer nextRef seenRef kindsRef = goT
  where
    goT ty = do
      ty' <- forceST ty
      case ty' of
        TCon c ts -> CTCon c <$> mapM goT ts
        TArr a r b -> CTArr <$> goT a <*> goR r <*> goT b
        TVar ref -> do
          tv <- readSTRef ref
          case tv of
            Link _ -> error "freezeQuantify: TVar was Link after forceST (caller invariant violation)"
            Rigid u _ -> error
              ("freezeQuantify: unexpected Rigid (uniq " ++ show u
              ++ "); skolems should never leak into stored schemes")
            Unbound u (Level l) k
              | l > outer -> do
                  seen <- readSTRef seenRef
                  case Map.lookup u seen of
                    Just idx -> pure (CTGen idx)
                    Nothing -> do
                      idx <- readSTRef nextRef
                      writeSTRef nextRef (idx + 1)
                      writeSTRef seenRef (Map.insert u idx seen)
                      prior <- readSTRef kindsRef
                      writeSTRef kindsRef ((idx, k) : prior)
                      pure (CTGen idx)
              | otherwise -> error
                  ("freezeQuantify: unexpected level-" ++ show l
                  ++ " var (uniq " ++ show u
                  ++ "); finalizeGroup should have routed this as a mono binding")

    goR row = do
      row' <- forceRowST row
      case row' of
        RowEmpty -> pure CREmpty
        RowExtend l ty rest -> CRExtend l <$> goT ty <*> goR rest
        RowVar ref -> do
          rv <- readSTRef ref
          case rv of
            RLink _ -> error "freezeQuantify (goR): RowVar was RLink after forceRowST (caller invariant violation)"
            RUnbound u _ -> pure (CRGen u)

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
  pure (substInCType subst body)
  where
    substInCType :: Map.Map Int (Type s) -> CType -> Type s
    substInCType m = goT
      where
        goT (CTCon c ts) = TCon c (map goT ts)
        goT (CTArr a r b) = TArr (goT a) (goR r) (goT b)
        goT (CTGen i) = case Map.lookup i m of
          Just t -> t
          Nothing -> error ("instantiate: dangling CTGen " ++ show i)
        goR CREmpty = RowEmpty
        goR (CRExtend l ty rest) = RowExtend l (goT ty) (goR rest)
        goR (CRGen _) = error "instantiate: CRGen in scheme not supported in v1"

-- | Like 'instantiate', but each quantifier becomes a rigid skolem instead
-- of a fresh inference variable. Used to check user-supplied type signatures
-- against inferred bodies: skolems cannot be linked to anything except
-- themselves (or an Unbound inference variable), so a body that is more
-- specific than the sig will fail to unify and raise 'RigidEscape'.
skolemize :: Scheme -> TC s (Type s)
skolemize (Scheme vars body) = do
  skolems <- mapM (\(i, k) -> do
                     u <- freshUniq
                     ref <- liftST $ newSTRef (Rigid u k)
                     pure (i, TVar ref)
                  ) vars
  let subst = Map.fromList skolems
  pure (substInCType subst body)
  where
    substInCType :: Map.Map Int (Type s) -> CType -> Type s
    substInCType m = goT
      where
        goT (CTCon c ts) = TCon c (map goT ts)
        goT (CTArr a r b) = TArr (goT a) (goR r) (goT b)
        goT (CTGen i) = case Map.lookup i m of
          Just t -> t
          Nothing -> error ("skolemize: dangling CTGen " ++ show i)
        goR CREmpty = RowEmpty
        goR (CRExtend l ty rest) = RowExtend l (goT ty) (goR rest)
        goR (CRGen _) = RowEmpty  -- v1: no row vars in schemes

-- | Translate a parsed Abs.Type into a Scheme. Free VarIds in the
-- type become universally quantified CTGen slots (in first-occurrence
-- order). Validates tycon arity. Built-in tycon names (Int, Char,
-- String, Bool, Unit, list) map to specialised TyCon tags; user
-- names become TcUser.
translateSig :: Env -> Abs.Type -> TC s Scheme
translateSig env ty = do
  seenRef <- liftST $ newSTRef (Map.empty :: Map.Map Text Int)
  nextRef <- liftST $ newSTRef (0 :: Int)
  body <- walk env seenRef nextRef ty
  slots <- liftST $ readSTRef seenRef
  let pairs = Data.List.sortBy (\a b -> compare (snd a) (snd b)) (Map.toList slots)
      qs = map (\(_, i) -> (i, KStar)) pairs
  pure (Scheme qs body)
  where
    walk :: Env
         -> STRef s (Map.Map Text Int)
         -> STRef s Int
         -> Abs.Type
         -> TC s CType
    walk env' seenRef nextRef = goT
      where
        goT (Abs.TFun a b) = CTArr <$> goT a <*> pure CREmpty <*> goT b
        goT (Abs.TVar (Abs.VarId (_, name))) = do
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
        goT (Abs.TCon modPath) = do
          let (name, pos) = modPathHead modPath
          case lookupTyCon name env' of
            Just info
              | tcArity info == 0 -> pure (CTCon (resolveTyCon name) [])
              | otherwise -> throwError
                  (ArityMismatch (Just pos) name (tcArity info) 0)
            Nothing -> throwError (UnknownTyCon (Just pos) name)
        goT (Abs.TApp f x) = do
          let (h, args) = collectApp f x
          case h of
            Abs.TCon modPath -> do
              let (name, pos) = modPathHead modPath
              case lookupTyCon name env' of
                Just info
                  | tcArity info == length args ->
                      CTCon (resolveTyCon name) <$> mapM goT args
                  | otherwise -> throwError
                      (ArityMismatch (Just pos) name (tcArity info) (length args))
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

-- ---------------------------------------------------------------------------
-- Module-level helpers shared by translateSig and processDataDecls
-- ---------------------------------------------------------------------------

collectApp :: Abs.Type -> Abs.Type -> (Abs.Type, [Abs.Type])
collectApp (Abs.TApp f x) y = let (h, xs) = collectApp f x in (h, xs ++ [y])
collectApp other y = (other, [y])

modPathHead :: Abs.ModPath -> (Text, (Int, Int))
modPathHead (Abs.MPName (Abs.ConId (pos, name))) = (name, pos)
modPathHead (Abs.MPDot _ _) =
  error "modPathHead: qualified names (Data.X.Y form) not supported in v1"

resolveTyCon :: Text -> TyCon
resolveTyCon name
  | name == Tx.pack "Int"    = TcInt
  | name == Tx.pack "Char"   = TcChar
  | name == Tx.pack "String" = TcString
  | name == Tx.pack "Bool"   = TcBool
  | name == Tx.pack "()"     = TcUnit
  | name == Tx.pack "[]"     = TcList
  | otherwise                       = TcUser name

-- ---------------------------------------------------------------------------
-- Data declaration processing
-- ---------------------------------------------------------------------------

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
    dataDecls = [ d | d@(Abs.DData{}) <- decls ]

    registerTyCons env [] = pure env
    registerTyCons env (Abs.DData (Abs.ConId (pos, name)) params _ : ds) =
      case lookupTyCon name env of
        Just _ -> throwError (DuplicateTyCon (Just pos) name)
        Nothing -> do
          let k = foldr KArrow KStar (replicate (length params) KStar)
              info = TyConInfo k (length params) []
              env' = extendTyCon name info env
          registerTyCons env' ds
    registerTyCons _ (_ : _) = error "registerTyCons: non-DData reached (input should be pre-filtered)"

    registerCons env [] = pure env
    registerCons env (Abs.DData (Abs.ConId (_, tcName)) params conDefs : ds) = do
      let paramNames = [ n | Abs.VarId (_, n) <- params ]
          paramMap = Map.fromList (zip paramNames [0 ..])
      env' <- foldM (registerCon tcName paramMap) env conDefs
      let cons = [ cn | Abs.ConDef (Abs.ConId (_, cn)) _ <- conDefs ]
          tcInfo = case lookupTyCon tcName env' of
            Just t  -> t { tcCons = cons }
            Nothing -> error "registerCons: tycon vanished"
          env'' = extendTyCon tcName tcInfo env'
      registerCons env'' ds
    registerCons _ (_ : _) = error "registerCons: non-DData reached (input should be pre-filtered)"

    registerCon tcName paramMap env (Abs.ConDef (Abs.ConId (pos, cname)) argTys) =
      case lookupCon cname env of
        Just _ -> throwError (DuplicateCon (Just pos) cname)
        Nothing -> do
          argCTypes <- mapM (translateConArg env paramMap) argTys
          let arity = length argTys
              paramCount = Map.size paramMap
              resultTy = CTCon (resolveTyCon tcName)
                           [ CTGen i | i <- [0 .. paramCount - 1] ]
              body = foldr (\arg acc -> CTArr arg CREmpty acc) resultTy argCTypes
              quantifiers = [ (i, KStar) | i <- [0 .. paramCount - 1] ]
              scheme = Scheme quantifiers body
              info = ConInfo scheme arity tcName
          pure (extendCon cname info env)

    translateConArg env paramMap = walkArg
      where
        walkArg (Abs.TVar (Abs.VarId (pos, name))) =
          case Map.lookup name paramMap of
            Just i -> pure (CTGen i)
            Nothing -> throwError (UnknownTyCon (Just pos) name)
        walkArg (Abs.TFun a b) =
          CTArr <$> walkArg a <*> pure CREmpty <*> walkArg b
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

-- ---------------------------------------------------------------------------
-- Pattern inference
-- ---------------------------------------------------------------------------

-- | Infer a pattern's type and the bindings it introduces.
-- Returns (the type the pattern matches, variable bindings introduced).
inferPat :: Abs.Pat -> TC s (Type s, [(Text, Type s)])
inferPat (Abs.PAtom ap) = inferAtomPat ap
inferPat (Abs.PApp modPath ap aps) = do
  let (name, pos) = modPathHead modPath
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
      let subTys = map fst subResults
          subBinds = concatMap snd subResults
      mapM_ (\(a, b) -> unify (Just pos) a b) (zip argTys subTys)
      pure (resultTy, subBinds)
inferPat (Abs.PCons headPat tailPat) = do
  (hT, hBinds) <- inferAtomPat headPat
  (tT, tBinds) <- inferPat tailPat
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
  let (name, pos) = modPathHead modPath
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

-- | Infer the type of an expression. Returns the inferred Type s.
-- v1 does not yet thread a typed AST result; that comes later.
inferExpr :: Abs.Exp -> TC s (Type s)
inferExpr e = inferExprW Map.empty e

-- Worker that carries a map of monomorphic (lambda/pattern) bindings.
-- These are looked up directly without instantiation, preserving the
-- identity of the mutable TVar across all uses in the expression.
inferExprW :: Map.Map Text (Type s) -> Abs.Exp -> TC s (Type s)
inferExprW _ (Abs.ELitI _) = pure (TCon TcInt [])
inferExprW _ (Abs.ELitS _) = pure (TCon TcString [])
inferExprW _ (Abs.ELitC _) = pure (TCon TcChar [])
inferExprW mono (Abs.EVar (Abs.VarId (pos, name))) =
  case Map.lookup name mono of
    Just t -> pure t
    Nothing -> do
      env <- currentEnv
      case lookupVar name env of
        Just s -> instantiate s
        Nothing -> throwError (UnknownVar (Just pos) name)
inferExprW _ (Abs.ECon (Abs.ConId (pos, name))) = do
  env <- currentEnv
  case lookupCon name env of
    Just info -> instantiate (conScheme info)
    Nothing -> throwError (UnknownCon (Just pos) name)
inferExprW mono (Abs.EParen e) = inferExprW mono e
inferExprW mono (Abs.EParenOp (Abs.VarSym (pos, name))) =
  case Map.lookup name mono of
    Just t -> pure t
    Nothing -> do
      env <- currentEnv
      case lookupVar name env of
        Just s -> instantiate s
        Nothing -> throwError (UnknownVar (Just pos) name)
inferExprW mono (Abs.EApp f x) = do
  fT <- inferExprW mono f
  xT <- inferExprW mono x
  rT <- freshTVar KStar
  unify Nothing fT (TArr xT RowEmpty rT)
  pure rT
inferExprW mono (Abs.EIf c a b) = do
  cT <- inferExprW mono c
  aT <- inferExprW mono a
  bT <- inferExprW mono b
  unify Nothing cT (TCon TcBool [])
  unify Nothing aT bT
  pure aT
inferExprW mono (Abs.ETuple a others) = do
  ts <- mapM (inferExprW mono) (a : others)
  pure (TCon (TcTuple (length ts)) ts)
inferExprW _ (Abs.EList []) = do
  e <- freshTVar KStar
  pure (TCon TcList [e])
inferExprW mono (Abs.EList (x : xs)) = do
  firstT <- inferExprW mono x
  mapM_ (\e -> do { t <- inferExprW mono e; unify Nothing firstT t }) xs
  pure (TCon TcList [firstT])
inferExprW mono (Abs.ELam atomPats body) = do
  patResults <- mapM inferAtomPat atomPats
  let paramTys = map fst patResults
      binds = concatMap snd patResults
      mono' = foldl (\m (n, t) -> Map.insert n t m) mono binds
  bodyT <- inferExprW mono' body
  pure (foldr (\pT acc -> TArr pT RowEmpty acc) bodyT paramTys)
inferExprW mono (Abs.EExpr head_ tails) = do
  hT <- inferExprW mono head_
  applyTails hT tails
  where
    applyTails t [] = pure t
    applyTails fT (Abs.ITail op rhs : rest) = do
      opTy <- inferInfixOpW mono op
      rhsT <- inferExprW mono rhs
      r1 <- freshTVar KStar
      unify Nothing opTy (TArr fT RowEmpty (TArr rhsT RowEmpty r1))
      applyTails r1 rest
inferExprW _ (Abs.EProj _ (Abs.VarId (pos, _))) =
  throwError (UnsupportedFeature (Just pos)
    (Tx.pack "x.y projection/module access not supported in v1"))
inferExprW _ (Abs.EProjC _ (Abs.ConId (pos, _))) =
  throwError (UnsupportedFeature (Just pos)
    (Tx.pack "x.Y projection/module access not supported in v1"))
inferExprW mono (Abs.ELet localDecls body) =
  inferLetGroup mono localDecls (\m -> inferExprW m body)
inferExprW mono (Abs.ECase scrutinee alts) = do
  sT <- inferExprW mono scrutinee
  rT <- freshTVar KStar
  mapM_ (inferAlt mono sT rT) alts
  pure rT

-- | Look up an infix operator; monomorphic bindings are checked first.
inferInfixOpW :: Map.Map Text (Type s) -> Abs.InfixOp -> TC s (Type s)
inferInfixOpW mono (Abs.IOSym (Abs.VarSym (pos, name))) =
  lookupOpNameW mono pos name
inferInfixOpW mono (Abs.IOBT (Abs.VarId (pos, name))) =
  lookupOpNameW mono pos name

lookupOpNameW :: Map.Map Text (Type s) -> (Int, Int) -> Text -> TC s (Type s)
lookupOpNameW mono pos name =
  case Map.lookup name mono of
    Just t -> pure t
    Nothing -> do
      env <- currentEnv
      case lookupVar name env of
        Just s -> instantiate s
        Nothing -> throwError (UnknownVar (Just pos) name)

-- ---------------------------------------------------------------------------
-- Let/where inference helpers
-- ---------------------------------------------------------------------------

-- | Infer a single case alternative.
inferAlt :: Map.Map Text (Type s) -> Type s -> Type s -> Abs.Alt -> TC s ()
inferAlt mono sT rT (Abs.AltC pat body mw) = do
  (pT, binds) <- inferPat pat
  unify Nothing sT pT
  let mono' = foldr (\(n, t) m -> Map.insert n t m) mono binds
  let withWhere k = case mw of
        Abs.NoWhere -> k mono'
        Abs.WithWh ds -> inferLetGroup mono' ds k
  bodyT <- withWhere (\m -> inferExprW m body)
  unify Nothing rT bodyT

-- | Process a local-decl group as a single mutually-recursive let.
-- Each binding's placeholder TVar lives in the mono-map during RHS typing
-- so recursive calls see it without going through instantiate. After typing
-- at level+1, we exit the level and generalize (so only inner TVars are
-- quantified). Then extend env for the continuation.
inferLetGroup
  :: Map.Map Text (Type s)
  -> [Abs.LocalDecl]
  -> (Map.Map Text (Type s) -> TC s a)
  -> TC s a
inferLetGroup mono decls k = do
  let (sigs, eqns) = partitionLocalDecls decls
  sigMap <- buildSigMap sigs
  let groups = groupEquations eqns
  -- Phase 1: inside level+1, allocate placeholders and unify all equation
  -- types. Returns (name, placeholderTVar, hasSig) after unification.
  unified <- enterLevel $ do
    placeholders <- mapM (allocatePlaceholderTVar sigMap) groups
    let monoRec = foldr (\(n, tv, _) m -> Map.insert n tv m) mono placeholders
    mapM (unifyGroupWith monoRec) placeholders
  -- Phase 2: back at outer level, generalize or check sig.
  results <- mapM (finalizeGroup sigMap) unified
  let monoBindings = [ (n, tv) | Left  (n, tv) <- results ]
      polyBindings = [ (n, s)  | Right (n, s)  <- results ]
      mono'   = foldr (\(n, tv) m -> Map.insert n tv m) mono monoBindings
      extend2 = foldr (.) id [ extendVarTC n s | (n, s) <- polyBindings ]
  extend2 (k mono')

partitionLocalDecls :: [Abs.LocalDecl] -> ([Abs.LocalDecl], [Abs.LocalDecl])
partitionLocalDecls = foldr step ([], [])
  where
    step d@Abs.LDSig{} (ss, es) = (d : ss, es)
    step d@Abs.LDEqn{} (ss, es) = (ss, d : es)

buildSigMap :: [Abs.LocalDecl] -> TC s (Map.Map Text Scheme)
buildSigMap [] = pure Map.empty
buildSigMap (Abs.LDSig (Abs.VarId (_, n)) extras ty : rest) = do
  env <- currentEnv
  s <- translateSig env ty
  let names = n : [ x | Abs.VICons (Abs.VarId (_, x)) <- extras ]
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
eqName (Abs.LDSig (Abs.VarId (_, n)) _ _) = n

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
unifyGroupWith
  :: Map.Map Text (Type s)
  -> (Text, Type s, [Abs.LocalDecl])
  -> TC s (Text, Type s)
unifyGroupWith monoRec (name, tv, eqns) = do
  eqTypes <- mapM (typeEquationWith monoRec) eqns
  case eqTypes of
    [] -> error ("unifyGroupWith: no equations for " ++ show name)
    (t : ts) -> do
      mapM_ (unify Nothing t) ts
      unify Nothing tv t
      pure (name, tv)

-- | Walk a forced type and report whether any unbound TVar has level <= outer.
-- When this is true the binding is monomorphic (its type is pinned by an
-- enclosing lambda or outer let) and must not be generalized.
hasOuterScopeVar :: Int -> Type s -> TC s Bool
hasOuterScopeVar outer = go
  where
    go ty = do
      ty' <- force ty
      case ty' of
        TCon _ ts -> orM (map go ts)
        TArr a r b -> do
          a' <- go a
          if a' then pure True else do
            r' <- goR r
            if r' then pure True else go b
        TVar ref -> do
          tv <- liftST $ readSTRef ref
          case tv of
            Unbound _ (Level l) _ -> pure (l <= outer)
            Rigid _ _ -> pure True
              -- A Rigid IS an outer-scope constant (it represents a skolem
              -- from an enclosing sig), so any binding that references one
              -- must stay monomorphic.
            Link _ -> error "hasOuterScopeVar: TVar was Link after force (caller invariant violation)"
    goR row = do
      row' <- forceRow row
      case row' of
        RowEmpty -> pure False
        RowExtend _ ty rest -> do
          a <- go ty
          if a then pure True else goR rest
        RowVar ref -> do
          rv <- liftST $ readSTRef ref
          case rv of
            RUnbound _ (Level l) -> pure (l <= outer)
            RLink _ -> error "hasOuterScopeVar: RowVar was RLink after forceRow (caller invariant violation)"
    orM = foldM (\acc m -> if acc then pure True else m) False

-- | Back at outer level: generalize an inferred type or verify a sig.
-- Returns Left (name, tv) for monomorphic bindings (escape detected),
-- Right (name, scheme) for genuinely polymorphic ones.
finalizeGroup
  :: Map.Map Text Scheme
  -> (Text, Type s)
  -> TC s (Either (Text, Type s) (Text, Scheme))
finalizeGroup sigMap (name, tv) =
  case Map.lookup name sigMap of
    Just declared -> do
      declT <- skolemize declared
      unify Nothing declT tv
      pure (Right (name, declared))
    Nothing -> do
      Level outer <- currentLevel
      hasEscape <- hasOuterScopeVar outer tv
      if hasEscape
        then pure (Left (name, tv))
        else do
          gen <- generalize tv
          pure (Right (name, gen))

-- | Type one equation, using the given recursive mono-map as the base
-- (so mutually-recursive names are visible). Pattern bindings extend it.
typeEquationWith :: Map.Map Text (Type s) -> Abs.LocalDecl -> TC s (Type s)
typeEquationWith monoRec (Abs.LDEqn lhs body mw) = do
  let atoms = lhsAtomPats lhs
  patResults <- mapM inferAtomPat atoms
  let pTys  = map fst patResults
      binds = concatMap snd patResults
      mono  = foldr (\(n, t) m -> Map.insert n t m) monoRec binds
  let withWhere k = case mw of
        Abs.NoWhere -> k mono
        Abs.WithWh ds -> inferLetGroup mono ds k
  bodyT <- withWhere (\m -> inferExprW m body)
  pure (foldr (\pT acc -> TArr pT RowEmpty acc) bodyT pTys)
typeEquationWith _ Abs.LDSig{} = error "typeEquationWith: signature in equation list"

lhsAtomPats :: Abs.FunLHS -> [Abs.AtomPat]
lhsAtomPats (Abs.LHSPre _ aps) = aps
lhsAtomPats (Abs.LHSInfSym a _ b) = [a, b]
lhsAtomPats (Abs.LHSInfBT a _ b) = [a, b]

-- ---------------------------------------------------------------------------
-- Top-level program inference
-- ---------------------------------------------------------------------------

-- | The v1 typed-AST output: one entry per top-level binding, carrying
-- its generalised scheme. The expression-level typed AST is omitted
-- from v1; future coverage / eval passes will get it when those
-- features land.
data TypedDecl = TypedDecl
  { tdName :: Text
  , tdScheme :: Scheme
  }
  deriving (Eq, Show)

-- | The pipeline entry point. Three passes:
-- 1) processDataDecls (tycons + constructors).
-- 2) Collect standalone signatures into the env.
-- 3) Type the top-level function-equation group as one mutually-recursive let.
inferProgram :: Abs.Module -> Either TypeError (Env, [TypedDecl])
inferProgram (Abs.Module decls) =
  runTC Builtins.initialEnv (inferProgramTC decls)

inferProgramTC :: [Abs.Decl] -> TC s (Env, [TypedDecl])
inferProgramTC decls = do
  -- Pass 1: register data declarations
  env1 <- processDataDecls Builtins.initialEnv decls
  -- Convert top-level decls to LocalDecl form for reuse of inferLetGroup
  let localDecls = concatMap toLocalDecl decls
  -- Pass 2 + 3: collect sigs and infer equations via inferLetGroup
  withEnv (const env1) $ do
    schemes <- inferTopLetGroup localDecls
    env2 <- currentEnv
    let finalEnv = foldr (\(n, s) e -> extendVar n s e) env2 schemes
    pure (finalEnv, [ TypedDecl n s | (n, s) <- schemes ])

-- | Convert a top-level Decl to zero or more LocalDecls so we can reuse
-- the existing inferLetGroup machinery.
toLocalDecl :: Abs.Decl -> [Abs.LocalDecl]
toLocalDecl (Abs.DEqn lhs body mw) = [Abs.LDEqn lhs body mw]
toLocalDecl (Abs.DSig vid extras ty) = [Abs.LDSig vid extras ty]
toLocalDecl _ = []

-- | Type the top-level declarations as one big mutually-recursive let,
-- returning the list of (name, scheme) pairs in binding order.
inferTopLetGroup :: [Abs.LocalDecl] -> TC s [(Text, Scheme)]
inferTopLetGroup localDecls = do
  let (sigs, eqns) = partitionLocalDecls localDecls
  sigMap <- buildSigMap sigs
  let groups = groupEquations eqns
  unified <- enterLevel $ do
    placeholders <- mapM (allocatePlaceholderTVar sigMap) groups
    let monoRec = foldr (\(n, tv, _) m -> Map.insert n tv m) Map.empty placeholders
    mapM (unifyGroupWith monoRec) placeholders
  results <- mapM (finalizeGroup sigMap) unified
  -- Top level has no outer scope, so finalizeGroup should never report
  -- escape for a top-level binding. If it does, the inferrer's invariants
  -- are violated -- fail loudly rather than silently emitting a Scheme []
  -- whose body references unquantified CTGen slots (the exact dangling
  -- pattern the escape fix was meant to eliminate).
  forM results $ \case
    Right (n, s) -> pure (n, s)
    Left (n, _) -> error
      ("inferTopLetGroup: unexpected escape for top-level binding "
      ++ Tx.unpack n)

-- ---------------------------------------------------------------------------
-- Pretty-printing closed types and schemes
-- ---------------------------------------------------------------------------

-- | Render a Scheme as a single line: "forall a b. (a -> b) -> [a] -> [b]"
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
prettyCType (CTCon TcList [x]) =
  Tx.concat [Tx.pack "[", prettyCType x, Tx.pack "]"]
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
  Tx.concat [Tx.pack (show c), Tx.pack " ",
             Tx.intercalate (Tx.pack " ") (map prettyCTypeAtom xs)]
prettyCType (CTArr a CREmpty b) =
  Tx.concat [prettyCTypeArg a, Tx.pack " -> ", prettyCType b]
prettyCType (CTArr a r b) =
  Tx.concat
    [ prettyCTypeArg a
    , Tx.pack " -<"
    , prettyCRow r
    , Tx.pack ">- "
    , prettyCType b
    ]

prettyCTypeArg :: CType -> Text
prettyCTypeArg t@CTArr{} = Tx.concat [Tx.pack "(", prettyCType t, Tx.pack ")"]
prettyCTypeArg t = prettyCType t

prettyCTypeAtom :: CType -> Text
prettyCTypeAtom t@CTArr{} = Tx.concat [Tx.pack "(", prettyCType t, Tx.pack ")"]
prettyCTypeAtom t@(CTCon (TcUser _) (_:_)) =
  Tx.concat [Tx.pack "(", prettyCType t, Tx.pack ")"]
prettyCTypeAtom t = prettyCType t

prettyCRow :: CRow -> Text
prettyCRow CREmpty = Tx.empty
prettyCRow (CRExtend l _ rest) = Tx.concat [l, Tx.pack ",", prettyCRow rest]
prettyCRow (CRGen i) = Tx.concat [Tx.pack "r", Tx.pack (show i)]
