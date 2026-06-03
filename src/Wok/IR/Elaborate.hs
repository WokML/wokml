module Wok.IR.Elaborate
  ( elaborateExprForTest   -- test seam: Env -> Abs.Exp -> Expr
  , elaborateModule        -- full module elaboration: Env -> Abs.Module -> CoreModule
  ) where

import Control.Monad.Reader
import Control.Monad.State.Strict (State)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as Tx
import qualified GeneratedParser.Wok.Abs as Abs
import Wok.IR.Anf
import Wok.IR.Name
import Wok.TypeChecking.Env (Env, envVars, lookupCon, conArity, lookupRecordCon, rcFields,
                             lookupEffect, EffectInfo(..))

-- ---------------------------------------------------------------------------
-- Context and monad

data ElabCtx = ElabCtx
  { ecEnv     :: Env                 -- carried for record and effect elaboration
  , ecScope   :: Map.Map Text Name   -- local binders in scope
  , ecGlobals :: Map.Map Text Name   -- top-level/builtin names (Task 7 fills this)
  }

-- | Elab is a reader over the elaboration context, built on top of Fresh.
type Elab = ReaderT ElabCtx (State Int)

-- | Mint a fresh Name with the given hint.
bindFresh :: Text -> Elab Name
bindFresh t = lift (freshName t)

-- ---------------------------------------------------------------------------
-- Scope helpers

-- | Extend the local scope with one binding for the duration of the action.
withLocal :: Text -> Name -> Elab a -> Elab a
withLocal t n = local (\ctx -> ctx { ecScope = Map.insert t n (ecScope ctx) })

-- | Extend the local scope with many bindings simultaneously.
withLocals :: [(Text, Name)] -> Elab a -> Elab a
withLocals bindings action =
  foldr (\(t, n) acc -> withLocal t n acc) action bindings

-- ---------------------------------------------------------------------------
-- Variable resolution

-- | Look up a variable name: local scope first, then globals, then mint fresh.
-- The fresh fallback is a Task-3 isolation seam; Task 7 pre-registers all real
-- globals so this fallback is never hit in the real pipeline.
resolveVar :: Text -> Elab Atom
resolveVar t = do
  ctx <- ask
  case Map.lookup t (ecScope ctx) of
    Just n  -> pure (AVar n)
    Nothing -> case Map.lookup t (ecGlobals ctx) of
      Just n  -> pure (AVar n)
      Nothing -> AVar <$> bindFresh t

-- ---------------------------------------------------------------------------
-- TailK: thread a tail target through branching control flow

data TailK = TRet | TJump JoinId

-- | Deliver an atom under the given tail continuation.
deliverAtom :: TailK -> Atom -> Expr
deliverAtom TRet      a = Ret a
deliverAtom (TJump j) a = Jump j [a]

-- | Deliver a Rhs under the given tail continuation: if the Rhs is a plain
-- atom, deliver directly; otherwise bind it fresh and deliver the variable.
deliverRhs :: TailK -> Rhs -> Elab Expr
deliverRhs tk (RAtom a) = pure (deliverAtom tk a)
deliverRhs tk rhs = do
  n <- bindFresh (Tx.pack "t")
  pure (Let (Binder n Unrestricted) rhs (deliverAtom tk (AVar n)))

-- ---------------------------------------------------------------------------
-- ANF normalization combinators

-- | Test whether an expression is a "compound" (branching control flow) that
-- requires a join point when it appears in value position.
isCompound :: Abs.Exp -> Bool
isCompound (Abs.EIf{})     = True
isCompound (Abs.ECase{})   = True
isCompound (Abs.EHandle{}) = True
isCompound _               = False

-- | Elaborate an expression and name any non-trivial computation with a fresh
-- let-binder, passing the resulting Atom to the continuation.  Trivial
-- RAtom results pass the atom straight through without a Let.
--
-- For ELet in value position, emit its bindings and then normalize the body.
-- For compound expressions (EIf / ECase) in value position, introduce a join
-- so that both branches jump to a single merge point.
normName :: Abs.Exp -> (Atom -> Elab Expr) -> Elab Expr
normName (Abs.ELet decls body) k =
  -- ELet in value position: emit the bindings, then normalize the body.
  elabLocalDecls decls (normName body k)
normName e k
  | isCompound e = do
      j <- lift freshJoin
      r <- bindFresh (Tx.pack "r")
      jbody <- k (AVar r)
      comp  <- elabK (TJump j) e
      pure (LetJoin j [Binder r Unrestricted] jbody comp)
  | otherwise =
      elabRhs e $ \rhs ->
        case rhs of
          RAtom a -> k a
          _       -> do
            n <- bindFresh (Tx.pack "t")
            body <- k (AVar n)
            pure (Let (Binder n Unrestricted) rhs body)

-- | Thread normName left-to-right over a list of expressions, preserving
-- evaluation order, then pass all resulting atoms to the continuation.
normAll :: [Abs.Exp] -> ([Atom] -> Elab Expr) -> Elab Expr
normAll []     k = k []
normAll (e:es) k = normName e $ \a -> normAll es $ \as -> k (a : as)

-- ---------------------------------------------------------------------------
-- Spine collection for left-associative application

-- | Unwind nested EApp to (head, args in left-to-right order).
collectSpine :: Abs.Exp -> (Abs.Exp, [Abs.Exp])
collectSpine e = go e []
  where
    go (Abs.EApp f x) acc = go f (x : acc)
    go hd             acc = (hd, acc)

-- ---------------------------------------------------------------------------
-- Helpers

readInt :: Text -> Integer
readInt t = read (Tx.unpack t)

tupleTag :: Int -> Text
tupleTag n = Tx.pack ("Tuple" ++ show n)

-- | Look up the arity of a data constructor. Returns 0 for unknown constructors
-- (which are treated as nullary, matching the existing behaviour for un-registered names).
conArityOf :: Text -> Elab Int
conArityOf c = do
  env <- asks ecEnv
  pure (maybe 0 conArity (lookupCon c env))

-- | Check whether `op` is a declared operation of effect `en`.
isEffectOp :: Text -> Text -> Elab Bool
isEffectOp en op = do
  env <- asks ecEnv
  pure $ case lookupEffect en env of
    Just ei -> Map.member op (eiOps ei)
    Nothing -> False

-- | Build a saturated or eta-expanded Rhs for a constructor application.
-- If the applied atoms already equal (or exceed) the declared arity, emit RCon.
-- If under-applied, wrap in an RLam that takes the remaining args.
saturateCon :: Text -> [Atom] -> Int -> Elab Rhs
saturateCon c applied arity
  | length applied >= arity = pure (RCon c applied)
  | otherwise = do
      let missing = arity - length applied
      extra <- mapM (\_ -> bindFresh (Tx.pack "a")) [1 .. missing]
      let allAtoms = applied ++ map AVar extra
      r <- bindFresh (Tx.pack "c")
      pure (RLam (map (`Binder` Unrestricted) extra)
                 (Let (Binder r Unrestricted) (RCon c allAtoms) (Ret (AVar r))))

-- | Extract the final ConId text from a ModPath (the rightmost segment).
-- For patterns like `Just` (MPName) this is "Just".
-- For qualified paths like `Std.Base.Foo` (MPDot ... "Foo") this is "Foo".
modPathFinal :: Abs.ModPath -> Text
modPathFinal (Abs.MPName (Abs.ConId (_, t))) = t
modPathFinal (Abs.MPDot _ (Abs.ConId (_, t))) = t

-- ---------------------------------------------------------------------------
-- Desugar EList into nested Cons / Nil

-- | Desugar a list of already-normalized atoms into a chain of Cons/Nil Rhs
-- values, building ANF let-bindings for all but the outermost.
-- The outermost Rhs is handed to the continuation.
consChain :: [Atom] -> (Rhs -> Elab Expr) -> Elab Expr
consChain []     k = k (RCon (Tx.pack "Nil") [])
consChain [a]    k = do
  -- Nil cell: bind it, then build the outermost Cons
  nilName <- bindFresh (Tx.pack "t")
  body <- k (RCon (Tx.pack "Cons") [a, AVar nilName])
  pure (Let (Binder nilName Unrestricted) (RCon (Tx.pack "Nil") []) body)
consChain (a:as) k = do
  -- build tail first via recursion, bind it, then hand Cons to k
  tailName <- bindFresh (Tx.pack "t")
  consChain as $ \tailRhs -> do
    body <- k (RCon (Tx.pack "Cons") [a, AVar tailName])
    pure (Let (Binder tailName Unrestricted) tailRhs body)

-- ---------------------------------------------------------------------------
-- Lambda parameter elaboration

-- | Elaborate a single AtomPat lambda parameter: returns (Binder, extender).
-- The extender wraps an Elab action to add the binder to scope.
elabLamParam :: Abs.AtomPat -> Elab (Binder, Elab Expr -> Elab Expr)
elabLamParam (Abs.APVar (Abs.VarId (_, t))) = do
  n <- bindFresh t
  pure (Binder n Unrestricted, withLocal t n)
elabLamParam Abs.APWild = do
  n <- bindFresh (Tx.pack "_")
  pure (Binder n Unrestricted, id)
elabLamParam Abs.PUnit = do
  -- unit is irrefutable and binds nothing
  n <- bindFresh (Tx.pack "_")
  pure (Binder n Unrestricted, id)
elabLamParam ap = do
  -- general atom-pattern parameter: bind a fresh param, destructure in the body
  n <- bindFresh (Tx.pack "p")
  let extender inner = do
        alt <- elabPat TRet (AVar n) (Abs.PAtom ap) inner
        pure (Case (AVar n) [alt])
  pure (Binder n Unrestricted, extender)

-- | Elaborate a list of AtomPat parameters, accumulating binders and scope
-- extension.
elabLamParams :: [Abs.AtomPat] -> Elab ([Binder], Elab Expr -> Elab Expr)
elabLamParams [] = pure ([], id)
elabLamParams (p:ps) = do
  (b, ext)   <- elabLamParam p
  (bs, exts) <- elabLamParams ps
  pure (b : bs, ext . exts)

-- ---------------------------------------------------------------------------
-- Core elaboration

-- | Elaborate to a single Rhs (naming sub-parts first), then continue.
elabRhs :: Abs.Exp -> (Rhs -> Elab Expr) -> Elab Expr

-- Literals
elabRhs (Abs.ELitI (Abs.WokInt (_, t))) k = k (RAtom (ALit (LInt (readInt t))))
elabRhs (Abs.ELitS s)                   k = k (RAtom (ALit (LStr (Tx.pack s))))
elabRhs (Abs.ELitC c)                   k = k (RAtom (ALit (LChar c)))
elabRhs Abs.EUnit                       k = k (RAtom (ALit LUnit))

-- Parenthesised expression: transparent
elabRhs (Abs.EParen e) k = elabRhs e k

-- Variable
elabRhs (Abs.EVar (Abs.VarId (_, t))) k = do
  a <- resolveVar t
  k (RAtom a)

-- Constructor: eta-expand if arity > 0, emit RCon [] if nullary
elabRhs (Abs.ECon (Abs.ConId (_, c))) k = do
  a <- conArityOf c
  rhs <- saturateCon c [] a
  k rhs

-- Application: collect spine, normalize args, build RApp / RCon / ROp.
elabRhs e@(Abs.EApp _ _) k =
  let (hd, args) = collectSpine e
  in normAll args $ \atoms ->
       case hd of
         Abs.ECon (Abs.ConId (_, c)) -> do
           a <- conArityOf c
           rhs <- saturateCon c atoms a
           k rhs
         Abs.EProj (Abs.ECon (Abs.ConId (_, en))) (Abs.VarId (_, op)) -> do
           isOp <- isEffectOp en op
           if isOp
             then k (ROp en op atoms)
             else normName hd $ \h -> k (RApp h atoms)
         _ -> normName hd $ \h -> k (RApp h atoms)

-- Lambda
elabRhs (Abs.ELam pats body) k = do
  (binders, extender) <- elabLamParams pats
  bodyExpr <- extender (elabTail body)
  k (RLam binders bodyExpr)

-- Tuple: elaborate all elements, emit RCon "TupleN"
elabRhs (Abs.ETuple first rest) k =
  let elems = first : rest
  in normAll elems $ \atoms -> k (RCon (tupleTag (length elems)) atoms)

-- List
elabRhs (Abs.EList []) k = k (RCon (Tx.pack "Nil") [])
elabRhs (Abs.EList xs) k =
  normAll xs $ \atoms -> consChain atoms k

-- Record construction: normalize field exprs, reorder to declared field order
elabRhs (Abs.ERecord (Abs.ConId (_, t)) fieldExprs) k =
  let labels = [ l | Abs.RFExpr (Abs.VarId (_, l)) _ <- fieldExprs ]
      exprs  = [ e | Abs.RFExpr _ e               <- fieldExprs ]
  in normAll exprs $ \atoms -> do
       let sourcePairs = zip labels atoms
       env <- asks ecEnv
       let orderedLabels = case lookupRecordCon t env of
             Just rci -> map fst (rcFields rci)
             Nothing  -> labels   -- fallback: source order
           -- build (label, atom) in declared order
           ordered = [ (lbl, atom)
                     | lbl <- orderedLabels
                     , Just atom <- [lookup lbl sourcePairs]
                     ]
           -- if reordering succeeded for all fields, use it; else source order
           finalPairs = if length ordered == length orderedLabels
                          then ordered
                          else sourcePairs
       k (RRecord t finalPairs)

-- Record extension: spread + per-field overrides, reordered by declaration
elabRhs (Abs.ERecordExt (Abs.ConId (_, t)) spreadExpr mTrailing) k =
  normName spreadExpr $ \spreadAtom -> do
    let overrideFieldExprs = case mTrailing of
          Abs.TFNone      -> []
          Abs.TFSome fes  -> fes
        overrideLabels = [ l | Abs.RFExpr (Abs.VarId (_, l)) _ <- overrideFieldExprs ]
        overrideExprs  = [ e | Abs.RFExpr _ e               <- overrideFieldExprs ]
    normAll overrideExprs $ \overrideAtoms -> do
      let overrides = zip overrideLabels overrideAtoms
      env <- asks ecEnv
      let declaredFields = case lookupRecordCon t env of
            Just rci -> map fst (rcFields rci)
            Nothing  -> overrideLabels  -- fallback
      -- For each declared field: use override if present, else project from spread
      buildFieldLets declaredFields overrides spreadAtom [] $ \finalPairs ->
        k (RRecord t finalPairs)
  where
    buildFieldLets :: [Text] -> [(Text, Atom)] -> Atom -> [(Text, Atom)]
                   -> ([(Text, Atom)] -> Elab Expr) -> Elab Expr
    buildFieldLets []          _         _       acc cont = cont (reverse acc)
    buildFieldLets (lbl:lbls) overrides spread acc cont =
      case lookup lbl overrides of
        Just atom -> buildFieldLets lbls overrides spread ((lbl, atom) : acc) cont
        Nothing   -> do
          p <- bindFresh (Tx.pack "p")
          body <- buildFieldLets lbls overrides spread ((lbl, AVar p) : acc) cont
          pure (Let (Binder p Unrestricted) (RProj lbl spread) body)

-- Record projection / effect-operation reference (zero-argument).
-- If the receiver is a bare constructor and the label is a declared op of that
-- effect, emit ROp; otherwise fall through to ordinary record projection.
elabRhs (Abs.EProj e (Abs.VarId (_, l))) k =
  case e of
    Abs.ECon (Abs.ConId (_, en)) -> do
      isOp <- isEffectOp en l
      if isOp
        then k (ROp en l [])
        else normName e $ \a -> k (RProj l a)
    _ -> normName e $ \a -> k (RProj l a)

-- Operator as a value, e.g. (+)
elabRhs (Abs.EParenOp (Abs.VarSym (_, s))) k = do
  a <- resolveVar s
  k (RAtom a)

-- Infix chain (already in precedence order after the reordering pass).
-- Left-fold: accumulate bindings for each intermediate result.
elabRhs (Abs.EExpr hd [])    k = elabRhs hd k
elabRhs (Abs.EExpr hd tails) k =
  normName hd $ \h0 -> goTails h0 tails
  where
    goTails acc [Abs.ITail op rhs] =
      normName rhs $ \r -> do
        opAtom <- resolveInfixOp op
        k (RApp opAtom [acc, r])
    goTails acc (Abs.ITail op rhs : rest) =
      normName rhs $ \r -> do
        opAtom <- resolveInfixOp op
        n <- bindFresh (Tx.pack "t")
        body <- goTails (AVar n) rest
        pure (Let (Binder n Unrestricted) (RApp opAtom [acc, r]) body)
    goTails acc [] = k (RAtom acc)   -- unreachable when tails non-empty, but total

-- Catch-all: forms not yet implemented (EProjC etc.)
elabRhs other _ =
  error ("elabRhs: not yet implemented (later task): " <> show other)

-- | Resolve an infix operator (symbolic or alpha-backtick) to an Atom.
resolveInfixOp :: Abs.InfixOp -> Elab Atom
resolveInfixOp (Abs.IOSym (Abs.VarSym (_, s))) = resolveVar s
resolveInfixOp (Abs.IOBT  (Abs.VarId  (_, v))) = resolveVar v

-- ---------------------------------------------------------------------------
-- Position-aware tail elaborator (handles branching control flow)

-- | Elaborate an expression in tail position with an explicit tail continuation.
-- Compound forms (EIf, ECase, ELet) branch/recurse with the same tk.
-- Non-compound forms fall through to elabRhs + deliverRhs.
elabK :: TailK -> Abs.Exp -> Elab Expr

-- if-then-else: desugar to Case over True / False constructors.
elabK tk (Abs.EIf c a b) =
  normName c $ \ca -> do
    ta <- elabK tk a
    tb <- elabK tk b
    pure (Case ca [ AltCon (Tx.pack "True") [] ta
                  , AltCon (Tx.pack "False") [] tb ])

-- case scrutinee of alts
elabK tk (Abs.ECase scrut alts) =
  normName scrut $ \sa -> Case sa <$> mapM (elabCaseAlt tk sa) alts

-- let ... in body: emit bindings then elaborate body in same tail position
elabK tk (Abs.ELet decls body) =
  elabLocalDecls decls (elabK tk body)

-- handle ... of { E.op ps -> body ; return v -> body }
-- The handled computation is elaborated with TRet (its value flows to the
-- return arm).  Each op arm auto-resumes: the arm body's value is passed to
-- the resume continuation, and the result of that call is delivered via tk.
elabK tk (Abs.EHandle e arms) = do
  let opArmsSrc  = [ (en, op, ps, body)
                   | Abs.HArm (Abs.ConId (_, en)) (Abs.VarId (_, op)) ps body <- arms ]
      retArmsSrc = [ (v, body)
                   | Abs.HReturn (Abs.VarId (_, v)) body <- arms ]
  handledBody <- elabK TRet e
  opArms <- mapM (elabOpArm tk) opArmsSrc
  retArm <- case retArmsSrc of
    ((v, rb) : _) -> do
      vN <- bindFresh v
      rbE <- withLocal v vN (elabK tk rb)
      pure (Binder vN Unrestricted, rbE)
    [] -> do
      vN <- bindFresh (Tx.pack "v")
      pure (Binder vN Unrestricted, deliverAtom tk (AVar vN))
  pure (Handle handledBody (Handler retArm opArms))
  where
    elabOpArm :: TailK -> (Text, Text, [Abs.AtomPat], Abs.Exp) -> Elab OpArm
    elabOpArm tk2 (en, op, ps, body) = do
      (argBinders, extender) <- elabLamParams ps
      resumeN <- bindFresh (Tx.pack "resume")
      armBody <- extender $ normName body $ \v -> do
        res <- bindFresh (Tx.pack "res")
        pure (Let (Binder res Unrestricted) (RApp (AVar resumeN) [v]) (deliverAtom tk2 (AVar res)))
      pure (OpArm en op argBinders (Binder resumeN Unrestricted) armBody)

-- Non-compound: name the result and deliver under tk
elabK tk e = elabRhs e (deliverRhs tk)

-- ---------------------------------------------------------------------------
-- Tail position elaboration

-- | Elaborate in tail position (the outermost tail continuation is TRet).
elabTail :: Abs.Exp -> Elab Expr
elabTail = elabK TRet

-- ---------------------------------------------------------------------------
-- Where-clause helper

-- | Resolve a MaybeWhere into a list of LocalDecls (empty if NoWhere).
whereDecls :: Abs.MaybeWhere -> [Abs.LocalDecl]
whereDecls Abs.NoWhere          = []
whereDecls (Abs.WithWh decls)   = decls

-- | Extract the text of a FunName.
funNameText :: Abs.FunName -> Text
funNameText (Abs.FNBare   (Abs.VarId  (_, t))) = t
funNameText (Abs.FNBareSym (Abs.VarSym (_, t))) = t
funNameText (Abs.FNParen  (Abs.VarSym (_, t))) = t

-- ---------------------------------------------------------------------------
-- Local declarations (let / where)

-- | Elaborate a group of local declarations (from a let...in or a where clause),
-- wrapping the given continuation.
--
-- Layout: value Let-bindings (in source order, outermost) then a single LetRec
-- for all function bindings, then the continuation body.  This means all
-- functions see each other (valid even if not actually mutually recursive) and
-- all value bindings are in scope everywhere inside the group.
--
-- Ignored: LDSig (type signatures -- types are erased after type checking).
elabLocalDecls :: [Abs.LocalDecl] -> Elab Expr -> Elab Expr
elabLocalDecls decls cont = do
  -- 1. Collect all equation entries, ignoring sigs.
  let eqns = [ (fn, params, body, wh)
             | Abs.LDEqn lhs body wh <- decls
             , (fn, params) <- lhsParts lhs ]

  -- 2. Partition into value bindings (no params) and function bindings (params).
  let (valueBnds, funcBnds) = foldr classify ([], []) eqns
        where
          classify (fn, [], body, wh) (vs, fs) = ((fn, body, wh) : vs, fs)
          classify (fn, ps, body, wh) (vs, fs) = (vs, (fn, ps, body, wh) : fs)

  -- 3. Mint a fresh Name for every bound name in the group up front, extending
  --    ecScope with ALL of them so mutual/forward references resolve.
  let allNames = map (\(fn, _, _) -> fn) valueBnds
               ++ map (\(fn, _, _, _) -> fn) funcBnds
  freshPairs <- mapM (\t -> (,) t <$> bindFresh t) allNames
  withLocals freshPairs $ do
    -- 4. Build the LetRec for all function bindings (functions first so they
    --    are visible to value bindings and the continuation).
    funcDefs <- mapM (elabFuncBnd freshPairs) funcBnds

    -- 5. Build the continuation body (and value bindings around it).
    inner <- buildValueLets freshPairs valueBnds cont

    -- 6. Wrap with LetRec if there are any function bindings.
    case funcDefs of
      [] -> pure inner
      _  -> pure (LetRec funcDefs inner)

  where
    -- Elaborate one function binding into a LetRec entry.
    elabFuncBnd :: [(Text, Name)] -> (Text, [Abs.AtomPat], Abs.Exp, Abs.MaybeWhere)
                -> Elab (Binder, [Binder], Expr)
    elabFuncBnd freshPairs (fn, params, body, wh) =
      case lookup fn freshPairs of
        Nothing -> error ("elabLocalDecls: internal: name not found: " <> Tx.unpack fn)
        Just n  -> do
          (paramBinders, extender) <- elabLamParams params
          bodyExpr <- extender $ elabLocalDecls (whereDecls wh) (elabK TRet body)
          pure (Binder n Unrestricted, paramBinders, bodyExpr)

    -- Wrap the continuation in nested Let-bindings for value equations.
    buildValueLets :: [(Text, Name)] -> [(Text, Abs.Exp, Abs.MaybeWhere)]
                   -> Elab Expr -> Elab Expr
    buildValueLets _ [] cont0 = cont0
    buildValueLets freshPairs ((fn, body, wh) : rest) cont0 =
      case lookup fn freshPairs of
        Nothing -> error ("elabLocalDecls: internal: name not found: " <> Tx.unpack fn)
        Just n  -> do
          -- Elaborate the value RHS in tail position inside any where-bindings,
          -- then extract it as an Rhs.  Because the value may be a compound
          -- expression we use normName to reduce it to an atom-shaped Rhs.
          inner <- buildValueLets freshPairs rest cont0
          -- Use normName on the value body: if it is a compound (if/case) we get a
          -- LetJoin; otherwise we get a plain Let.  Then we wrap in Let n = <atom>.
          elabLocalDecls (whereDecls wh) $
            normName body $ \atom ->
              pure (Let (Binder n Unrestricted) (RAtom atom) inner)

-- | Extract the bound name and parameter list from a FunLHS.
-- Returns a single-element list for LHSPre; errors on infix forms (rare).
lhsParts :: Abs.FunLHS -> [(Text, [Abs.AtomPat])]
lhsParts (Abs.LHSPre fn params) = [(funNameText fn, params)]
lhsParts (Abs.LHSInfSym {})  = error "let: infix operator definitions not yet supported (LHSInfSym)"
lhsParts (Abs.LHSInfBT  {})  = error "let: infix operator definitions not yet supported (LHSInfBT)"

-- ---------------------------------------------------------------------------
-- Pattern compilation

-- | Compile one surface case-alternative to one target Alt.
-- Supported patterns: see inline notes below.
-- NOTE: overlapping constructors (two alts with the same head constructor but
-- different nested patterns) are NOT merged; the corpus uses non-overlapping
-- single-level patterns so this is fine.
elabCaseAlt :: TailK -> Atom -> Abs.Alt -> Elab Alt

elabCaseAlt tk scrut (Abs.AltC pat body wh) =
  elabPat tk scrut pat (elabLocalDecls (whereDecls wh) (elabK tk body))

-- | Compile a Pat into an Alt, given the scrutinee atom and the body action.
elabPat :: TailK -> Atom -> Abs.Pat -> Elab Expr -> Elab Alt
elabPat tk scrut (Abs.PAtom ap)          body = elabAtomPatAlt tk scrut ap body
elabPat tk _ (Abs.PApp modpath ap aps) body = do
  let conName = modPathFinal modpath
      subPats = ap : aps
  (fieldBinders, wrapBody) <- buildSubPats tk subPats
  wrappedBody <- wrapBody body
  pure (AltCon conName fieldBinders wrappedBody)
elabPat tk _ (Abs.PCons headAP tailPat) body = do
  (headBinders, headWrap) <- buildSubPats tk [headAP]
  (tailBinders, tailWrap) <- buildSubPatsFromPat tk tailPat
  wrappedBody <- headWrap (tailWrap body)
  pure (AltCon (Tx.pack "Cons") (headBinders ++ tailBinders) wrappedBody)
  where
    buildSubPatsFromPat :: TailK -> Abs.Pat -> Elab ([Binder], Elab Expr -> Elab Expr)
    buildSubPatsFromPat tk2 p =
      -- If it is a trivial tail pattern (just a var or wild), avoid the nested case.
      case trivialPat p of
        Just Nothing  -> do
          n <- bindFresh (Tx.pack "_")
          pure ([Binder n Unrestricted], id)
        Just (Just tv) -> do
          n <- bindFresh tv
          pure ([Binder n Unrestricted], withLocal tv n)
        Nothing -> do
          n <- bindFresh (Tx.pack "t")
          let b = Binder n Unrestricted
              wrap inner = do
                alt <- elabPat tk2 (AVar n) p inner
                pure (Case (AVar n) [alt])
          pure ([b], wrap)

-- | Bind `label` (projected from scrut) under `asName` for the duration of
-- `inner`, wrapping the result in `Let fieldBinder = RProj label scrut`.
withProjField :: Atom -> Text -> Text -> Elab Expr -> Elab Expr
withProjField scrut label asName inner = do
  n <- bindFresh asName
  body <- withLocal asName n inner
  pure (Let (Binder n Unrestricted) (RProj label scrut) body)

-- | Build the field-projection let-chain for a list of RecordFieldPat bindings.
-- For each RFPat (VarId label) subPat: project the field, then bind it. If the
-- sub-pattern is a trivial var/wildcard the projection is directly in scope;
-- otherwise wrap a nested Case on the projected value.
buildRecordFieldBindings :: TailK -> Atom -> [Abs.RecordFieldPat] -> Elab Expr -> Elab Expr
buildRecordFieldBindings _  _     []                                  cont = cont
buildRecordFieldBindings tk scrut (Abs.RFPat (Abs.VarId (_, l)) subPat : rest) cont = do
  let innerCont = buildRecordFieldBindings tk scrut rest cont
  n <- bindFresh l
  case trivialPat subPat of
    Just Nothing ->
      -- wildcard: project + bind without extending scope
      Let (Binder n Unrestricted) (RProj l scrut) <$> innerCont
    Just (Just tv) ->
      -- variable binding: project + bring the source name into scope
      do body <- withLocal tv n innerCont
         pure (Let (Binder n Unrestricted) (RProj l scrut) body)
    Nothing ->
      -- non-trivial sub-pattern: project, then Case on the projection
      do body <- do
           alt <- elabPat tk (AVar n) subPat innerCont
           pure (Case (AVar n) [alt])
         pure (Let (Binder n Unrestricted) (RProj l scrut) body)

-- | Compile an AtomPat to a single Alt (for PAtom cases and sub-pattern dispatch).
elabAtomPatAlt :: TailK -> Atom -> Abs.AtomPat -> Elab Expr -> Elab Alt
elabAtomPatAlt _  _      Abs.APWild  body = AltDefault <$> body
elabAtomPatAlt _  _      Abs.PUnit   body = AltDefault <$> body   -- unit is irrefutable
elabAtomPatAlt _  scrut  (Abs.APVar (Abs.VarId (_, v))) body = do
  n <- bindFresh v
  bodyExpr <- withLocal v n body
  pure (AltDefault (Let (Binder n Unrestricted) (RAtom scrut) bodyExpr))
elabAtomPatAlt _  _      (Abs.APLitI (Abs.WokInt (_, t))) body =
  AltLit (LInt (readInt t)) <$> body
elabAtomPatAlt _  _      (Abs.APLitS s)   body = AltLit (LStr (Tx.pack s))  <$> body
elabAtomPatAlt _  _      (Abs.APLitC c)   body = AltLit (LChar c)            <$> body
elabAtomPatAlt _  _      (Abs.APCon modpath) body = do
  let conName = modPathFinal modpath
  AltCon conName [] <$> body
elabAtomPatAlt tk _      (Abs.APTuple p1 ps) body = do
  let subPats = p1 : ps
      n = length subPats
      tag = tupleTag n
  (fieldBinders, wrapBody) <- buildSubPatsFromFullPats tk subPats
  wrappedBody <- wrapBody body
  pure (AltCon tag fieldBinders wrappedBody)
elabAtomPatAlt _  _      (Abs.APList []) body = AltCon (Tx.pack "Nil") [] <$> body
elabAtomPatAlt _  _      (Abs.APList _)  _    =
  error "pattern not yet supported (Task 4 bounded / Task 5): non-empty APList pattern"
elabAtomPatAlt tk scrut  (Abs.APParen p)  body = elabPat tk scrut p body >>= \alt -> pure alt
-- PRecord T [(label, subPat)]: match on tag T, bind each field via RProj
elabAtomPatAlt tk scrut  (Abs.PRecord (Abs.ConId (_, t)) fieldPats) body = do
  innerBody <- buildRecordFieldBindings tk scrut fieldPats body
  pure (AltCon t [] innerBody)

-- PRecordOpen T [(label, subPat)] rowTail: same as PRecord for named fields; tail
-- PRTAnon means ignore the rest. PRTNamed is not supported by the type system.
elabAtomPatAlt tk scrut  (Abs.PRecordOpen (Abs.ConId (_, t)) fieldPats rowTail) body = do
  case rowTail of
    Abs.PRTNamed _ -> error "record pattern: named row-tail capture not supported"
    Abs.PRTAnon    -> pure ()
  innerBody <- buildRecordFieldBindings tk scrut fieldPats body
  pure (AltCon t [] innerBody)

-- PRecordWild T rowTail: bind ALL declared fields by their label name
elabAtomPatAlt _  scrut  (Abs.PRecordWild (Abs.ConId (_, t)) rowTail) body = do
  case rowTail of
    Abs.PRTNamed _ -> error "record pattern: named row-tail capture not supported"
    Abs.PRTAnon    -> pure ()
  env <- asks ecEnv
  let allLabels = case lookupRecordCon t env of
        Just rci -> map fst (rcFields rci)
        Nothing  -> []
  innerBody <- foldr (\lbl acc -> withProjField scrut lbl lbl acc) body allLabels
  pure (AltCon t [] innerBody)

-- | Build field binders and a body wrapper from a list of AtomPat sub-patterns
-- (used by PApp).
buildSubPats :: TailK -> [Abs.AtomPat] -> Elab ([Binder], Elab Expr -> Elab Expr)
buildSubPats _  [] = pure ([], id)
buildSubPats tk (ap:aps) = do
  (b, wrap)   <- atomPatToBinder ap
  (bs, wraps) <- buildSubPats tk aps
  -- If the sub-pattern is nontrivial (nested pattern), we need a nested case.
  case atomPatNested ap of
    Nothing   -> pure (b : bs, wrap . wraps)
    Just fullP -> do
      -- b is the field binder; add a nested Case on AVar (bndName b)
      -- The remaining sub-patterns (wraps) are applied after the nested case.
      let wrapNested inner = do
            -- Elaborate the nested pattern against the field variable.
            -- The remaining sub-patterns wrap the inner body first.
            altBody <- wraps inner
            alt <- elabPat tk (AVar (bndName b)) fullP (pure altBody)
            pure (Case (AVar (bndName b)) [alt])
      pure (b : bs, wrapNested)

-- | Build field binders and body wrapper from full Pat sub-patterns (used by APTuple).
buildSubPatsFromFullPats :: TailK -> [Abs.Pat] -> Elab ([Binder], Elab Expr -> Elab Expr)
buildSubPatsFromFullPats _  [] = pure ([], id)
buildSubPatsFromFullPats tk (p:ps) = do
  (bs, wraps) <- buildSubPatsFromFullPats tk ps
  case trivialPat p of
    Just Nothing ->
      -- wildcard: fresh binder, no scope extension
      do n <- bindFresh (Tx.pack "_")
         pure (Binder n Unrestricted : bs, wraps)
    Just (Just tv) ->
      -- variable binding: use the variable name directly as the binder
      do n <- bindFresh tv
         pure (Binder n Unrestricted : bs, withLocal tv n . wraps)
    Nothing ->
      -- nontrivial: fresh binder + nested case wrapping the continuation
      do n <- bindFresh (Tx.pack "t")
         let b = Binder n Unrestricted
             wrapNested inner = do
               altBody <- wraps inner
               alt <- elabPat tk (AVar n) p (pure altBody)
               pure (Case (AVar n) [alt])
         pure (b : bs, wrapNested)

-- | Convert an AtomPat to a fresh Binder and scope-extension function.
-- For variable patterns, the binder uses the variable's name.
-- For wildcards and other patterns, a fresh "_" binder is minted.
atomPatToBinder :: Abs.AtomPat -> Elab (Binder, Elab Expr -> Elab Expr)
atomPatToBinder (Abs.APVar (Abs.VarId (_, v))) = do
  n <- bindFresh v
  pure (Binder n Unrestricted, withLocal v n)
atomPatToBinder _ = do
  n <- bindFresh (Tx.pack "_")
  pure (Binder n Unrestricted, id)

-- | If a Pat is trivially a wildcard or a variable (no nested pattern matching),
-- return Just Nothing (wildcard) or Just (Just varText) (variable).
-- Otherwise return Nothing (nontrivial: needs nested case).
trivialPat :: Abs.Pat -> Maybe (Maybe Text)
trivialPat (Abs.PAtom Abs.APWild)                  = Just Nothing
trivialPat (Abs.PAtom (Abs.APVar (Abs.VarId(_,v)))) = Just (Just v)
trivialPat (Abs.PAtom (Abs.APParen p))              = trivialPat p
trivialPat _                                       = Nothing

-- | Check if an AtomPat is a "nested" pattern that requires a nested case.
-- Returns Just <the-full-Pat> if nontrivial, Nothing if trivial (var/wild).
atomPatNested :: Abs.AtomPat -> Maybe Abs.Pat
atomPatNested (Abs.APVar _)    = Nothing
atomPatNested Abs.APWild       = Nothing
atomPatNested (Abs.APParen p)  = Just p
atomPatNested ap               = Just (Abs.PAtom ap)

-- ---------------------------------------------------------------------------
-- Top-level module elaboration

-- | Elaborate every top-level equation in a module into a 'TopBind'.
-- One canonical 'Name' is minted for every value-level global (from 'envVars'),
-- so that the binding site and every reference share the same identity.
elaborateModule :: Env -> Abs.Module -> CoreModule
elaborateModule env (Abs.Module decls) =
  runFresh $ do
    gpairs <- mapM (\t -> (,) t <$> freshName t) (Map.keys (envVars env))
    let globals = Map.fromList gpairs
        eqns = [ (lhs, body, mw) | Abs.DEqn lhs body mw <- decls ]
    binds <- mapM (\(lhs, body, mw) ->
                     runReaderT (elabTopBind lhs body mw)
                                (ElabCtx env Map.empty globals)) eqns
    pure (CoreModule binds)

elabTopBind :: Abs.FunLHS -> Abs.Exp -> Abs.MaybeWhere -> Elab TopBind
elabTopBind (Abs.LHSPre fn params) body mw = do
  globals <- asks ecGlobals
  let fname = funNameText fn
      name  = Map.findWithDefault (errName fname) fname globals
  (paramBinders, extender) <- elabLamParams params
  bodyExpr <- extender (elabLocalDecls (whereDecls mw) (elabTail body))
  pure (TopBind name paramBinders bodyExpr)
  where errName t = error ("elaborateModule: top-level name not in env: " <> Tx.unpack t)
elabTopBind (Abs.LHSInfSym{}) _ _ =
  error "elaborateModule: top-level infix operator definitions not supported"
elabTopBind (Abs.LHSInfBT{}) _ _ =
  error "elaborateModule: top-level infix operator definitions not supported"

-- ---------------------------------------------------------------------------
-- Public test seam

elaborateExprForTest :: Env -> Abs.Exp -> Expr
elaborateExprForTest env e =
  runFresh (runReaderT (elabTail e) (ElabCtx env Map.empty Map.empty))
