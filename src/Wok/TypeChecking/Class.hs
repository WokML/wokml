-- | Translate @class@ / @instance@ declarations into the 'ClassInfo' /
-- 'InstanceInfo' registry entries that the constraint solver and elaborator
-- consume. Registration is PURE (@Either TypeError Env@): it builds the
-- constrained method schemes, validates decidability (termination,
-- coherence, completeness), and mints dictionary names. It does NOT
-- typecheck method or instance bodies -- that is the inferrer's job.
--
-- Single-parameter classes only (the v1 Eq slice). The single class
-- parameter is canonically 'CTGen' 0 throughout a class body, and an
-- instance's free type variables are numbered 'CTGen' 0, 1, ... in
-- first-occurrence order over the instance head and context.
module Wok.TypeChecking.Class
  ( processClassDecl
  , processInstanceDecl
  , dictName
  , tyConKey
  , renderCType
  , dictDataDecl
  , instanceBindings
  , instanceDictName
  ) where

import           Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import           Data.Text (Text)
import qualified Data.Text as Tx
import qualified GeneratedParser.Wok.Abs as Abs
import           Wok.TypeChecking.Env
  ( ClassInfo (..), Env, InstanceInfo (..)
  , ciDefaults, ciMethodNames, envInstances
  , extendClass, extendInstance, extendVar, lookupClass )
import           Wok.TypeChecking.Error (TypeError (..))
import           Wok.TypeChecking.Types
  ( CRow (..), CType (..), Constraint (..), Kind (..), Scheme (..), TyCon (..) )

-- ---------------------------------------------------------------------------
-- Class declarations
-- ---------------------------------------------------------------------------

-- | Register a class declaration: build a 'ClassInfo', inject each method's
-- full constrained scheme (@forall a. (C a) => <sig>@) into 'envVars' so that
-- use-sites resolve and instantiate the method, store the class defaults,
-- and register the 'ClassInfo'. Non-'Abs.DClass' decls return the env
-- unchanged.
processClassDecl :: Env -> Abs.Decl -> Either TypeError Env
processClassDecl env (Abs.DClass (Abs.ConId (_, cname)) params entries) = do
  -- Single-parameter classes only.
  pvar <- case params of
            [Abs.VarId (_, p)] -> Right p
            _                  -> Left (MalformedClassDecl
                                    (Tx.concat [ Tx.pack "class "
                                               , cname
                                               , Tx.pack " must have exactly one type parameter" ]))
  -- The class parameter is CTGen 0 throughout the class body.
  let paramMap = Map.singleton pvar 0
  methodSigs <- sequence
    [ do (vs, body) <- schemeOfType paramMap ty
         let sch = Scheme (ensureParam vs) [Constraint cname (CTGen 0)] body
         Right (methodNameText mn, sch)
    | Abs.CESig mn ty <- entries ]
  let defaults = Map.fromList
        [ (funLhsName lhs, body) | Abs.CEDefault lhs body <- entries ]
      methodMap   = Map.fromList methodSigs
      methodNames = map fst methodSigs
      dictCon     = cname <> Tx.pack "$Dict"
      ci   = ClassInfo (0, KStar) methodMap defaults methodNames dictCon
      env1 = extendClass cname ci env
      env2 = foldl' (\e (m, s) -> extendVar m s e) env1 methodSigs
  Right env2
processClassDecl env _ = Right env

-- | Ensure the class parameter slot (CTGen 0) is among the quantified vars.
-- For a method whose signature does not itself mention the parameter we
-- still quantify it (so the @C a@ constraint is well-formed). For Eq this
-- is always already present.
ensureParam :: [(Int, Kind)] -> [(Int, Kind)]
ensureParam vs
  | any ((== 0) . fst) vs = vs
  | otherwise             = (0, KStar) : vs

-- ---------------------------------------------------------------------------
-- Instance declarations
-- ---------------------------------------------------------------------------

-- | Register an instance declaration: validate the class exists, translate
-- the head and context, run the termination + coherence + completeness
-- checks, mint the dictionary name, and register an 'InstanceInfo'.
-- Non-'Abs.DInstance' decls return the env unchanged.
processInstanceDecl :: Env -> Abs.Decl -> Either TypeError Env
processInstanceDecl env (Abs.DInstance ihead entries) = do
  let (ctxC, cname, targs) = splitHead ihead
  ci <- maybe (Left (UnknownClass cname)) Right (lookupClass cname env)
  -- Single-parameter class: exactly one head argument.
  argTy <- case targs of
             [t] -> Right t
             _   -> Left (MalformedInstance
                      (Tx.concat [ Tx.pack "instance "
                                 , cname
                                 , Tx.pack " must apply the class to exactly one type argument" ]))
  -- Number the instance's free type variables in first-occurrence order
  -- across the head argument and the context, so head/context CTGen slots
  -- agree (required for the solver to instantiate the context).
  let varMap = collectVars (collectVarsT Map.empty argTy) ctxC
  headTy  <- typeArgToCType varMap argTy
  context <- mapM (constraintToC varMap) ctxC
  -- Termination: each context constraint's argument must be a proper
  -- structural subterm of the instance head.
  mapM_
    (\c -> if smaller (conArg c) headTy
             then Right ()
             else Left (InstanceNotSmaller cname (renderCType headTy)))
    context
  -- Coherence: reject a second instance for the same (class, head tycon).
  -- The dict-assembly binding name MUST equal this 'dictName cname hc'
  -- (see 'instanceDictName', which reproduces it from the raw syntax).
  hc <- maybe (Left (MalformedInstance
                 (Tx.concat [ Tx.pack "instance "
                            , cname
                            , Tx.pack " head must be a type-constructor application" ])))
              Right (headCon headTy)
  let clash = any
        (\i -> iiClass i == cname && headCon (iiHead i) == Just hc)
        (envInstances env)
  if clash
    then Left (OverlappingInstance cname (tyConKey hc))
    else Right ()
  -- Completeness: every class method must be implemented or have a default.
  let impls = Map.fromList [ (funLhsName lhs, body) | Abs.IEImpl lhs body <- entries ]
  mapM_
    (\m -> if Map.member m impls || Map.member m (ciDefaults ci)
             then Right ()
             else Left (MissingMethod (renderCType headTy) m))
    (ciMethodNames ci)
  let ii = InstanceInfo cname headTy context (dictName cname hc) impls
  Right (extendInstance ii env)
processInstanceDecl env _ = Right env

-- | Destructure an 'Abs.InstHead' into (context constraints, class name,
-- head type arguments).
splitHead :: Abs.InstHead -> ([Abs.Constraint], Text, [Abs.Type])
splitHead (Abs.IHPlain (Abs.ConId (_, cn)) args)     = ([],  cn, args)
splitHead (Abs.IHCtx ctx (Abs.ConId (_, cn)) args)   = (ctx, cn, args)

-- | A type is "smaller" than the head iff it is a PROPER structural subterm
-- of the head (used for instance termination). E.g. @CTGen 0@ is smaller
-- than @Option (CTGen 0)@, but @[CTGen 0]@ is not smaller than @CTGen 0@.
smaller :: CType -> CType -> Bool
smaller x parent = x /= parent && elemSub x parent
  where
    elemSub t (CTCon _ ts)  = any (\u -> t == u || elemSub t u) ts
    elemSub t (CTArr a r b) = t == a || t == b
                              || elemSub t a || elemSub t b || elemSubR t r
    elemSub t (CTRecord _ r) = elemSubR t r
    elemSub _ (CTGen _)     = False
    elemSubR t (CRExtend _ ty rest) = t == ty || elemSub t ty || elemSubR t rest
    elemSubR _ _ = False

-- | The head type constructor of an instance head, if the head is a
-- constructor application (which it always is for a registered instance).
headCon :: CType -> Maybe TyCon
headCon (CTCon c _) = Just c
headCon _           = Nothing

-- | The canonical dictionary name for a (class, head tycon) pair, e.g.
-- @dict$Eq$U64@ or @dict$Eq$Option@.
dictName :: Text -> TyCon -> Text
dictName cls c = Tx.pack "dict$" <> cls <> Tx.pack "$" <> tyConKey c

-- | A short stable key for a type constructor, used in dictionary names
-- and overlap diagnostics.
tyConKey :: TyCon -> Text
tyConKey TcU64        = Tx.pack "U64"
tyConKey TcU32        = Tx.pack "U32"
tyConKey TcChar       = Tx.pack "Char"
tyConKey TcString     = Tx.pack "String"
tyConKey TcNever      = Tx.pack "Never"
tyConKey TcBool       = Tx.pack "Bool"
tyConKey TcUnit       = Tx.pack "Unit"
tyConKey TcList       = Tx.pack "List"
tyConKey (TcTuple n)  = Tx.pack "Tuple" <> Tx.pack (show n)
tyConKey (TcUser t)   = t

-- ---------------------------------------------------------------------------
-- Pure Abs.Type -> CType translation
-- ---------------------------------------------------------------------------
--
-- Self-contained translator covering the shapes that class methods and
-- instance heads use (arrows, base/user tycons, list, tuples, type vars).
-- It is intentionally separate from 'Infer.translateSig' (which is in the
-- 'TC s' monad and allocates fresh slots imperatively): this keeps the
-- inferrer's behaviour identical while giving registration a pure path.
-- Free type variables are mapped to 'CTGen' slots via a supplied
-- name->index map; no arity/record validation is performed here (that
-- happens during inference of the actual bodies).

-- | Translate a method signature over a known parameter map (e.g.
-- @{"a" -> 0}@) into its quantified-vars list and body type.
schemeOfType :: Map Text Int -> Abs.Type -> Either TypeError ([(Int, Kind)], CType)
schemeOfType pmap ty = do
  body <- typeArgToCType vmap ty
  let qs = [ (i, KStar) | i <- Map.elems vmap ]
  Right (qs, body)
  where
    vmap = collectVarsT pmap ty

-- | Translate a single 'Abs.Type' to a 'CType' over a fixed var->index map.
-- Any type variable not present in the map is an error (it has no slot).
typeArgToCType :: Map Text Int -> Abs.Type -> Either TypeError CType
typeArgToCType vmap = go
  where
    go t = case t of
      Abs.TQual _ body  -> go body
      Abs.TFun a b      -> CTArr <$> go a <*> pure CREmpty <*> go b
      Abs.TWith a b _   -> CTArr <$> go a <*> pure CREmpty <*> go b
      Abs.TParen t'     -> go t'
      Abs.TList inner   -> (\c -> CTCon TcList [c]) <$> go inner
      Abs.TTuple a others -> do
        ts <- mapM go (a : others)
        Right (CTCon (TcTuple (1 + length others)) ts)
      Abs.TUnit         -> Right (CTCon TcUnit [])
      Abs.TVar (Abs.VarId (_, n)) ->
        case Map.lookup n vmap of
          Just i  -> Right (CTGen i)
          Nothing -> Left (MalformedInstance
                       (Tx.concat [ Tx.pack "unbound type variable '"
                                  , n
                                  , Tx.pack "' in class/instance head" ]))
      Abs.TCon mp       -> Right (CTCon (resolveTyConName (modPathLeaf mp)) [])
      Abs.TApp f x      ->
        let (h, args) = collectApp f x
        in case h of
             Abs.TCon mp -> CTCon (resolveTyConName (modPathLeaf mp)) <$> mapM go args
             _           -> Left (MalformedInstance
                              (Tx.pack "non-tycon type application in class/instance head"))
      Abs.TExtend{}     -> Left (MalformedInstance
                             (Tx.pack "type-level extension in class/instance head"))

-- | Translate an 'Abs.Constraint' (grammar form) to a 'Types.Constraint'
-- over the given var map.
constraintToC :: Map Text Int -> Abs.Constraint -> Either TypeError Constraint
constraintToC vmap (Abs.Constraint (Abs.ConId (_, cn)) args) =
  case args of
    [a] -> Constraint cn <$> typeArgToCType vmap a
    _   -> Left (MalformedInstance
             (Tx.concat [ Tx.pack "constraint "
                        , cn
                        , Tx.pack " must apply to exactly one type argument" ]))

-- ---------------------------------------------------------------------------
-- Free-variable numbering and small Abs helpers
-- ---------------------------------------------------------------------------

-- | Accumulate free type-variable names from a type into the map, assigning
-- the next free index (in first-occurrence order) to each new name.
collectVarsT :: Map Text Int -> Abs.Type -> Map Text Int
collectVarsT = go
  where
    go m t = case t of
      Abs.TQual _ b      -> go m b
      Abs.TFun a b       -> go (go m a) b
      Abs.TWith a b _    -> go (go m a) b
      Abs.TParen t'      -> go m t'
      Abs.TList inner    -> go m inner
      Abs.TTuple a others -> foldl' go m (a : others)
      Abs.TUnit          -> m
      Abs.TApp f x       -> go (go m f) x
      Abs.TExtend a _ _  -> go m a
      Abs.TCon _         -> m
      Abs.TVar (Abs.VarId (_, n)) ->
        if Map.member n m then m else Map.insert n (Map.size m) m

-- | Accumulate free type-variable names across a context's constraints.
collectVars :: Map Text Int -> [Abs.Constraint] -> Map Text Int
collectVars = foldl' (\m (Abs.Constraint _ args) -> foldl' collectVarsT m args)

-- | The leaf name of a (possibly dotted) ModPath, e.g. @Std.Base.Option@
-- -> @Option@. Built-in base names round-trip through 'resolveTyConName'.
modPathLeaf :: Abs.ModPath -> Text
modPathLeaf (Abs.MPName (Abs.ConId (_, n))) = n
modPathLeaf (Abs.MPDot _ (Abs.ConId (_, n))) = n

-- | Map a base type-constructor name to its 'TyCon' tag (mirrors
-- 'Infer.resolveTyCon'); unknown names become 'TcUser'.
resolveTyConName :: Text -> TyCon
resolveTyConName name
  | name == Tx.pack "U64"    = TcU64
  | name == Tx.pack "U32"    = TcU32
  | name == Tx.pack "Char"   = TcChar
  | name == Tx.pack "String" = TcString
  | name == Tx.pack "Never"  = TcNever
  | name == Tx.pack "Bool"   = TcBool
  | name == Tx.pack "()"     = TcUnit
  | name == Tx.pack "[]"     = TcList
  | otherwise                = TcUser name

-- | Flatten a left-nested type application into its head and argument list.
collectApp :: Abs.Type -> Abs.Type -> (Abs.Type, [Abs.Type])
collectApp (Abs.TApp f x) y = let (h, xs) = collectApp f x in (h, xs ++ [y])
collectApp other y          = (other, [y])

-- | Extract a method name from a class-method 'Abs.MethodName'.
methodNameText :: Abs.MethodName -> Text
methodNameText (Abs.MNBare  (Abs.VarId  (_, n))) = n
methodNameText (Abs.MNParen (Abs.VarSym (_, n))) = n

-- | Extract the bound name from a function LHS (for defaults / impls).
funLhsName :: Abs.FunLHS -> Text
funLhsName (Abs.LHSPre fn _)                  = funNameText fn
funLhsName (Abs.LHSInfSym _ (Abs.VarSym (_, n)) _) = n
funLhsName (Abs.LHSInfBT  _ (Abs.VarId  (_, n)) _) = n

funNameText :: Abs.FunName -> Text
funNameText (Abs.FNBare    (Abs.VarId  (_, n))) = n
funNameText (Abs.FNBareSym (Abs.VarSym (_, n))) = n
funNameText (Abs.FNParen   (Abs.VarSym (_, n))) = n

-- ---------------------------------------------------------------------------
-- Dict-name consistency (Step 2)
-- ---------------------------------------------------------------------------
--
-- 'instanceDictName' reproduces the EXACT string that 'processInstanceDecl'
-- registers as 'iiDictName' (= 'dictName cname hc'), but starting from the
-- raw 'Abs.DInstance' syntax. It performs the same head translation:
-- number the free type vars in first-occurrence order across head + context,
-- translate the single head argument to a 'CType', take its head 'TyCon',
-- and mint the name. Using this both for registration and for the synthetic
-- dict-assembly binding guarantees the 'Solve' resolver's 'EvGlobal'/'EvApp'
-- names match the actual global binding.

-- | The canonical dict-assembly binding name for a 'DInstance', e.g.
-- @dict$Eq$U64@ / @dict$Eq$Option@. Non-'DInstance' decls are an error.
instanceDictName :: Abs.Decl -> Either TypeError Text
instanceDictName (Abs.DInstance ihead _) = do
  let (ctxC, cname, targs) = splitHead ihead
  argTy <- case targs of
             [t] -> Right t
             _   -> Left (MalformedInstance
                      (Tx.concat [ Tx.pack "instance "
                                 , cname
                                 , Tx.pack " must apply the class to exactly one type argument" ]))
  let varMap = collectVars (collectVarsT Map.empty argTy) ctxC
  headTy <- typeArgToCType varMap argTy
  hc     <- maybe (Left (MalformedInstance
                    (Tx.concat [ Tx.pack "instance "
                               , cname
                               , Tx.pack " head must be a type-constructor application" ])))
                  Right (headCon headTy)
  Right (dictName cname hc)
instanceDictName _ = Left (MalformedInstance (Tx.pack "instanceDictName: not an instance declaration"))

-- ---------------------------------------------------------------------------
-- Dict data type generation (Step 3)
-- ---------------------------------------------------------------------------

-- | Generate the dictionary data type for a class declaration:
--
-- > class Eq a where (==) : a -> a -> Bool ; (/=) : a -> a -> Bool
--
-- becomes
--
-- > data Eq a = Eq$Dict (a -> a -> Bool) (a -> a -> Bool)
--
-- The tycon is the class name, the single constructor is @<Class>$Dict@,
-- and its positional fields are the method signature types in declaration
-- order. Non-'DClass' decls produce 'Nothing'.
dictDataDecl :: Abs.Decl -> Maybe Abs.Decl
dictDataDecl (Abs.DClass cid@(Abs.ConId (_, cidText)) params entries) =
  Just (Abs.DData cid params
          [Abs.ConDef (mkConId (cidText <> Tx.pack "$Dict")) methodTypes])
  where
    methodTypes = [ ty | Abs.CESig _ ty <- entries ]
dictDataDecl _ = Nothing

-- ---------------------------------------------------------------------------
-- Instance binding generation (Step 4)
-- ---------------------------------------------------------------------------

-- | Desugar an instance into synthetic typed top-level bindings: one
-- @<dictName>$m<k>@ binding per method (from the instance impl, or from the
-- class default with class-method references rewritten to the sibling synth
-- names), followed by the dict-assembly binding @<dictName> = <Class>$Dict
-- <m0> <m1> ...@. The first argument is ALL 'DClass' decls (to find the
-- matching class for method order + defaults); the second is the 'DInstance'.
instanceBindings :: [Abs.Decl] -> Abs.Decl -> Either TypeError [Abs.Decl]
instanceBindings classDecls instDecl@(Abs.DInstance ihead instEntries) = do
  let (ctxC, cls, targs) = splitHead ihead
  -- Find the matching class declaration (for method order + defaults + sigs).
  (classParam, classEntries) <-
    case [ (ps, es) | Abs.DClass (Abs.ConId (_, cn)) ps es <- classDecls, cn == cls ] of
      ((ps, es) : _) ->
        case ps of
          [Abs.VarId (_, p)] -> Right (p, es)
          _                  -> Left (UnknownClass cls)  -- single-param only
      []             -> Left (UnknownClass cls)
  -- The instance head's single type argument (single-parameter classes).
  headArg <- case targs of
               [t] -> Right t
               _   -> Left (UnknownClass cls)
  dictNm <- instanceDictName instDecl
  let dictCon     = cls <> Tx.pack "$Dict"
      methodSigs  = [ (methodNameText mn, ty) | Abs.CESig mn ty <- classEntries ]
      methodNames = map fst methodSigs
      classMethodSet = methodNames
      defaults    = [ (funLhsName lhs, (lhs, body)) | Abs.CEDefault lhs body <- classEntries ]
      impls       = [ (funLhsName lhs, (lhs, body)) | Abs.IEImpl lhs body <- instEntries ]
      -- Index of each class method (for the sibling-rewrite).
      methodIndex = Map.fromList (zip methodNames [0 ..])
      synthName k = dictNm <> Tx.pack "$m" <> Tx.pack (show (k :: Int))
      -- The synthetic signature for method index k: the class method type with
      -- the class parameter substituted by the instance head argument, prefixed
      -- by the instance context (if any) as a qualified type. Signing the
      -- method synths makes them visible POLYMORPHICALLY to sibling bindings
      -- (the dict assembly + default impls), so each constrained method
      -- re-emits its `Eq a` constraint at every use site, which is what lets
      -- the (unsigned) dict-assembly collect the instance context as evidence.
      methodSig k mty =
        let body = substTyVar classParam headArg mty
            qty  = case ctxC of
                     []  -> body
                     _   -> Abs.TQual (contextType ctxC) body
        in Abs.DSig (Abs.SNBare (mkVarId (synthName k))) [] qty
  bindings <- sequence
    [ do let eqn = case lookup m impls of
                Just (lhs, body) ->
                  -- Impl body is left verbatim (genuine element-level method
                  -- uses such as `a == b` in the Option impl are NOT rewritten).
                  Right (Abs.LHSPre (Abs.FNBare (mkVarId (synthName k))) (lhsAtomPats lhs), body)
                Nothing ->
                  case lookup m defaults of
                    Just (lhs, body) ->
                      -- Default body: rewrite this-class method refs to the
                      -- sibling synth names so the default closes over the
                      -- instance's impls.
                      Right ( Abs.LHSPre (Abs.FNBare (mkVarId (synthName k))) (lhsAtomPats lhs)
                            , rewriteMethodRefs classMethodSet dictNm methodIndex body )
                    Nothing -> Left (MissingMethod dictNm m)  -- defensive (Task 5)
         (lhs', body') <- eqn
         Right [ methodSig k mty
               , Abs.DEqn lhs' body' Abs.NoWhere ]
    | (k, (m, mty)) <- zip [0 ..] methodSigs ]
  let n = length methodNames
      assemblyBody = foldl' Abs.EApp (Abs.ECon (mkConId dictCon))
                       [ Abs.EVar (mkVarId (synthName k)) | k <- [0 .. n - 1] ]
      -- The dict assembly is intentionally UNSIGNED: it goes through the
      -- unsigned-discharge path, generalizing the instance context it collects
      -- (from the constrained method synths) into its scheme + evidence params.
      assembly = Abs.DEqn (Abs.LHSPre (Abs.FNBare (mkVarId dictNm)) [])
                   assemblyBody Abs.NoWhere
  Right (concat bindings ++ [assembly])
instanceBindings _ _ = Right []

-- | Substitute the class parameter type variable (by name) with a target
-- 'Abs.Type' throughout a method signature type. Used to specialize a class
-- method's declared type to an instance head (e.g. @a -> a -> Bool@ with
-- @a := Option a@ gives @Option a -> Option a -> Bool@).
substTyVar :: Text -> Abs.Type -> Abs.Type -> Abs.Type
substTyVar p target = go
  where
    go t = case t of
      Abs.TVar (Abs.VarId (_, n)) | n == p -> target
      Abs.TVar _          -> t
      Abs.TQual a b       -> Abs.TQual (go a) (go b)
      Abs.TWith a b e     -> Abs.TWith (go a) (go b) e
      Abs.TFun a b        -> Abs.TFun (go a) (go b)
      Abs.TApp a b        -> Abs.TApp (go a) (go b)
      Abs.TList a         -> Abs.TList (go a)
      Abs.TTuple a others -> Abs.TTuple (go a) (map go others)
      Abs.TParen a        -> Abs.TParen (go a)
      Abs.TCon{}          -> t
      Abs.TUnit           -> t
      Abs.TExtend a s rc  -> Abs.TExtend (go a) s rc

-- | Encode an instance context (@[Abs.Constraint]@) as the constraint-context
-- 'Abs.Type' that 'TQual' expects: a single @(C a)@ is parenthesized; multiple
-- become a tuple of @(C a)@ applications. Matches the grammar shape that
-- 'Infer.constraintsOfType' decodes.
contextType :: [Abs.Constraint] -> Abs.Type
contextType cs = case map one cs of
  [t]      -> Abs.TParen t
  (t : ts) -> Abs.TParen (Abs.TTuple t ts)
  []       -> Abs.TUnit  -- unreachable: callers guard on a non-empty context
  where
    one (Abs.Constraint cid args) =
      foldl' Abs.TApp (Abs.TCon (Abs.MPName cid)) args

-- | Rewrite references to THIS class's methods in a default-method body to
-- the corresponding sibling synth names @<dictName>$m<j>@. Handles the
-- expression-position forms in which a method name can appear:
--
--   * @EVar@   (a bare-name use of a method, e.g. a backtick-method ref)
--   * @EParenOp@ (an operator referenced as a value, e.g. @(==)@)
--   * @EExpr@ infix heads (@IOSym@ / @IOBT@) -- the operator in @x == y@
--
-- Only method names of THIS class are rewritten; all other names (locals,
-- constructors, other globals, genuine element-level methods in impls) are
-- untouched. The rewrite is structural over the whole 'Abs.Exp' tree.
rewriteMethodRefs :: [Text] -> Text -> Map Text Int -> Abs.Exp -> Abs.Exp
rewriteMethodRefs classMethods dictNm idx = go
  where
    synthFor m = case Map.lookup m idx of
      Just j  -> Just (dictNm <> Tx.pack "$m" <> Tx.pack (show (j :: Int)))
      Nothing -> Nothing
    isMethod m = m `elem` classMethods

    go e = case e of
      Abs.EVar (Abs.VarId (_, n))
        | isMethod n, Just s <- synthFor n -> Abs.EVar (mkVarId s)
      Abs.EParenOp (Abs.VarSym (_, n))
        | isMethod n, Just s <- synthFor n -> Abs.EVar (mkVarId s)
      Abs.EExpr h tails -> Abs.EExpr (go h) (map goTail tails)
      Abs.EApp a b      -> Abs.EApp (go a) (go b)
      Abs.EProj a v     -> Abs.EProj (go a) v
      Abs.EProjC a c    -> Abs.EProjC (go a) c
      Abs.ERecord c fs  -> Abs.ERecord c (map goField fs)
      Abs.ERecordExt c a mt -> Abs.ERecordExt c (go a) (goTrailing mt)
      Abs.EParen a      -> Abs.EParen (go a)
      Abs.EList xs      -> Abs.EList (map go xs)
      Abs.ETuple a xs   -> Abs.ETuple (go a) (map go xs)
      Abs.ELam ps a     -> Abs.ELam ps (go a)
      Abs.ELet ds a     -> Abs.ELet (map goLocal ds) (go a)
      Abs.ECase a alts  -> Abs.ECase (go a) (map goAlt alts)
      Abs.EIf a b c     -> Abs.EIf (go a) (go b) (go c)
      Abs.EWith arms a  -> Abs.EWith (map goArm arms) (go a)
      Abs.EWithH h hs arms a -> Abs.EWithH h hs (map goArm arms) (go a)
      _                 -> e

    goTail (Abs.ITail op a) = Abs.ITail (goOp op) (go a)

    goOp op@(Abs.IOSym (Abs.VarSym (_, n)))
      | isMethod n, Just s <- synthFor n = Abs.IOBT (mkVarId s)
      | otherwise = op
    goOp op@(Abs.IOBT (Abs.VarId (_, n)))
      | isMethod n, Just s <- synthFor n = Abs.IOBT (mkVarId s)
      | otherwise = op

    goField (Abs.RFExpr v a) = Abs.RFExpr v (go a)
    goTrailing Abs.TFNone       = Abs.TFNone
    goTrailing (Abs.TFSome fs)  = Abs.TFSome (map goField fs)
    goLocal (Abs.LDEqn lhs a mw) = Abs.LDEqn lhs (go a) (goWhere mw)
    goLocal (Abs.LDPat p ps a)   = Abs.LDPat p ps (go a)
    goLocal d@(Abs.LDSig{})      = d
    goWhere Abs.NoWhere     = Abs.NoWhere
    goWhere (Abs.WithWh ds) = Abs.WithWh (map goLocal ds)
    goAlt (Abs.AltC p a mw) = Abs.AltC p (go a) (goWhere mw)
    goArm (Abs.HArm c v ps a) = Abs.HArm c v ps (go a)
    goArm (Abs.HUArm v ps a)  = Abs.HUArm v ps (go a)
    goArm (Abs.HParam v a)    = Abs.HParam v (go a)

-- | The parameter 'Abs.AtomPat's of a function LHS, in order. (Duplicated
-- here rather than imported from 'Infer' to avoid an import cycle.)
lhsAtomPats :: Abs.FunLHS -> [Abs.AtomPat]
lhsAtomPats (Abs.LHSPre _ aps)    = aps
lhsAtomPats (Abs.LHSInfSym a _ b) = [a, b]
lhsAtomPats (Abs.LHSInfBT  a _ b) = [a, b]

-- | Build an 'Abs.VarId' wrapper directly (bypassing the lexer) with a dummy
-- position. Synthetic names contain @$@, which is illegal in surface
-- identifiers, so they cannot collide with user names.
mkVarId :: Text -> Abs.VarId
mkVarId t = Abs.VarId ((0, 0), t)

-- | Build an 'Abs.ConId' wrapper directly with a dummy position.
mkConId :: Text -> Abs.ConId
mkConId t = Abs.ConId ((0, 0), t)

-- ---------------------------------------------------------------------------
-- Rendering (for error messages)
-- ---------------------------------------------------------------------------

-- | A simple structural renderer for closed types, used in error messages.
-- Self-contained to avoid an import cycle with 'Infer.prettyCType'.
renderCType :: CType -> Text
renderCType = go
  where
    go (CTCon c [])   = tyConKey c
    go (CTCon TcList [a]) = Tx.pack "[" <> go a <> Tx.pack "]"
    go (CTCon c args) = tyConKey c <> Tx.pack " "
                        <> Tx.intercalate (Tx.pack " ") (map atom args)
    go (CTArr a _ b)  = atom a <> Tx.pack " -> " <> go b
    go (CTRecord t _) = t
    go (CTGen i)      = Tx.pack "t" <> Tx.pack (show i)

    atom t@(CTCon _ (_:_)) = Tx.pack "(" <> go t <> Tx.pack ")"
    atom t@(CTArr{})       = Tx.pack "(" <> go t <> Tx.pack ")"
    atom t                 = go t
