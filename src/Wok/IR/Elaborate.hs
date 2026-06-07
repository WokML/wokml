module Wok.IR.Elaborate
  ( elaborateExprForTest      -- test seam: Env -> TExpr -> Expr
  , elaborateModule           -- full module elaboration: Env -> [TypedDecl] -> CoreModule
  , elaborateModulesShared    -- whole-program: [(Env, [TypedDecl])] -> CoreModule
  ) where

import Control.Monad.Reader
import Control.Monad.State.Strict (State)
import Data.List (elemIndex)
import qualified Data.Map.Strict as Map
import Data.Set (Set)
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as Tx
import Wok.IR.Anf
import Wok.IR.Name
import Wok.TypeChecking.Env
  ( Env, envVars, lookupCon, conArity, conTyCon, lookupRecordCon, rcFields
  , lookupTyCon, TyConInfo (..)
  , classOfMethod, lookupClass, ClassInfo (..) )
import Wok.TypeChecking.Infer (TypedDecl (..))
import Wok.TypeChecking.Typed
  ( Texp (..), TexpF (..), Tpat (..), TpatF (..)
  , TAlt (..), THandlerArm (..), TLocalDecl (..)
  , TExpr, TPat )
import Wok.TypeChecking.Types
  ( CType (..), TyCon (..), Constraint (..), Evidence (..) )
import Wok.IR.Match
  ( MPat (..), MPatF (..), Row (..), ConOracle (..), compileMatch, tupleTag )
import qualified Wok.TypeChecking.Solve as Solve

-- ---------------------------------------------------------------------------
-- Annotation accessors

-- | The CType annotation on a typed expression node.
teType :: TExpr -> CType
teType (Texp ty _) = ty

-- ---------------------------------------------------------------------------
-- Context and monad

data ElabCtx = ElabCtx
  { ecEnv         :: Env                 -- carried for record and effect elaboration
  , ecScope       :: Map.Map Text Name   -- local binders in scope
  , ecGlobals     :: Map.Map Text Name   -- top-level/builtin names
  , ecEvidence    :: Map.Map Text Name   -- evidence-param name -> its dict binder
  , ecEvidenceIdx :: Set Int             -- in-scope quantified-constraint indices
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
-- The fresh fallback is an isolation seam; the real pipeline pre-registers all
-- globals so this fallback is never hit.
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
-- The fresh binder carries the supplied type.
deliverRhs :: TailK -> CType -> Rhs -> Elab Expr
deliverRhs tk _  (RAtom a) = pure (deliverAtom tk a)
deliverRhs tk ty rhs = do
  n <- bindFresh (Tx.pack "t")
  pure (Let (Binder n Unrestricted ty) rhs (deliverAtom tk (AVar n)))

-- ---------------------------------------------------------------------------
-- ANF normalization combinators

-- | Test whether a node is a "compound" (branching control flow) that requires
-- a join point when it appears in value position.
isCompound :: TexpF CType -> Bool
isCompound (TIf{})     = True
isCompound (TCase{})   = True
isCompound (THandle{}) = True
isCompound _           = False

-- | Elaborate an expression and name any non-trivial computation with a fresh
-- let-binder, passing the resulting Atom to the continuation.  Trivial
-- RAtom results pass the atom straight through without a Let.
--
-- For TLet in value position, emit its bindings and then normalize the body.
-- For compound expressions (TIf / TCase / THandle) in value position, introduce
-- a join so that all branches jump to a single merge point.
normName :: TExpr -> (Atom -> Elab Expr) -> Elab Expr
normName (Texp _ (TLet decls body)) k =
  -- TLet in value position: emit the bindings, then normalize the body.
  elabLocalDecls decls (normName body k)
normName e@(Texp ty node) k
  | isCompound node = do
      j <- lift freshJoin
      r <- bindFresh (Tx.pack "r")
      jbody <- k (AVar r)
      comp  <- elabK (TJump j) e
      pure (LetJoin j [Binder r Unrestricted ty] jbody comp)
  | otherwise =
      elabRhs e $ \rhs ->
        case rhs of
          RAtom a -> k a
          _       -> do
            n <- bindFresh (Tx.pack "t")
            body <- k (AVar n)
            pure (Let (Binder n Unrestricted ty) rhs body)

-- | Thread normName left-to-right over a list of expressions, preserving
-- evaluation order, then pass all resulting atoms to the continuation.
normAll :: [TExpr] -> ([Atom] -> Elab Expr) -> Elab Expr
normAll []     k = k []
normAll (e:es) k = normName e $ \a -> normAll es $ \as -> k (a : as)

-- ---------------------------------------------------------------------------
-- Helpers

-- | Look up the arity of a data constructor. Returns 0 for unknown constructors
-- (treated as nullary, matching the existing behaviour for un-registered names).
conArityOf :: Text -> Elab Int
conArityOf c = do
  env <- asks ecEnv
  pure (maybe 0 conArity (lookupCon c env))

-- | Build a saturated or eta-expanded Rhs for a constructor application.
-- If the applied atoms already equal (or exceed) the declared arity, emit RCon.
-- If under-applied, wrap in an RLam that takes the remaining args.
--
-- The eta-expansion binders carry the result CType -- this is only reached for
-- partially-applied constructors; the placeholder it replaces was likewise a
-- single uniform type per binder, and the erased printer/runtime ignore types.
saturateCon :: CType -> Text -> [Atom] -> Int -> Elab Rhs
saturateCon ty c applied arity
  | length applied >= arity = pure (RCon c applied)
  | otherwise = do
      let missing = arity - length applied
      extra <- mapM (\_ -> bindFresh (Tx.pack "a")) [1 .. missing]
      let allAtoms = applied ++ map AVar extra
      r <- bindFresh (Tx.pack "c")
      pure (RLam (map (\n -> Binder n Unrestricted ty) extra)
                 (Let (Binder r Unrestricted ty) (RCon c allAtoms) (Ret (AVar r))))

-- ---------------------------------------------------------------------------
-- Desugar TList into nested Cons / Nil

-- | Desugar a list of already-normalized atoms into a chain of Cons/Nil Rhs
-- values, building ANF let-bindings for all but the outermost.
-- The outermost Rhs is handed to the continuation. The list element/cell type
-- comes from the overall list node's CType.
consChain :: CType -> [Atom] -> (Rhs -> Elab Expr) -> Elab Expr
consChain _  []     k = k (RCon (Tx.pack "Nil") [])
consChain ty [a]    k = do
  -- Nil cell: bind it, then build the outermost Cons
  nilName <- bindFresh (Tx.pack "t")
  body <- k (RCon (Tx.pack "Cons") [a, AVar nilName])
  pure (Let (Binder nilName Unrestricted ty) (RCon (Tx.pack "Nil") []) body)
consChain ty (a:as) k = do
  -- build tail first via recursion, bind it, then hand Cons to k
  tailName <- bindFresh (Tx.pack "t")
  consChain ty as $ \tailRhs -> do
    body <- k (RCon (Tx.pack "Cons") [a, AVar tailName])
    pure (Let (Binder tailName Unrestricted ty) tailRhs body)

-- ---------------------------------------------------------------------------
-- Lambda / function parameter elaboration

-- | Elaborate a single pattern parameter: returns (Binder, extender).
-- The extender wraps an Elab action to add the binder(s) to scope. The binder
-- carries the pattern's CType.
elabParam :: TPat -> Elab (Binder, Elab Expr -> Elab Expr)
elabParam (Tpat ty (TPVar t)) = do
  n <- bindFresh t
  pure (Binder n Unrestricted ty, withLocal t n)
elabParam (Tpat ty TPWild) = do
  n <- bindFresh (Tx.pack "_")
  pure (Binder n Unrestricted ty, id)
elabParam (Tpat ty TPUnit) = do
  -- unit is irrefutable and binds nothing
  n <- bindFresh (Tx.pack "_")
  pure (Binder n Unrestricted ty, id)
elabParam p@(Tpat ty _) = do
  -- general pattern parameter: bind a fresh param, destructure in the body
  n <- bindFresh (Tx.pack "p")
  let extender inner = do
        alt <- elabPat TRet (AVar n) p inner
        pure (Case (AVar n) [alt])
  pure (Binder n Unrestricted ty, extender)

-- | Elaborate a list of pattern parameters, accumulating binders and scope
-- extension.
elabParams :: [TPat] -> Elab ([Binder], Elab Expr -> Elab Expr)
elabParams [] = pure ([], id)
elabParams (p:ps) = do
  (b, ext)   <- elabParam p
  (bs, exts) <- elabParams ps
  pure (b : bs, ext . exts)

-- ---------------------------------------------------------------------------
-- Core elaboration

-- ---------------------------------------------------------------------------
-- Evidence / dictionary lowering (Task 10)

-- | Build the dictionary atom witnessing a single class constraint, then pass
-- it to the continuation. 'Solve.resolve' is total here by construction: the
-- type-checker already proved the constraint dischargeable, so a 'Left' is an
-- internal invariant violation (panic, mirroring elaboration's other panics).
evidenceAtom :: (Text, CType) -> (Atom -> Elab Expr) -> Elab Expr
evidenceAtom (cls, argTy) k = do
  ctx <- ask
  case Solve.resolve (ecEnv ctx) (ecEvidenceIdx ctx) cls argTy of
    Left e   -> error ("elaborate: unresolvable constraint "
                        <> Tx.unpack cls <> " (" <> show argTy <> "): " <> show e)
    Right ev -> lowerEvidence ev k

-- | Lower an 'Evidence' term into a dictionary 'Atom', emitting let-bindings
-- for any 'EvApp' dict-builder applications, then continue.
lowerEvidence :: Evidence -> (Atom -> Elab Expr) -> Elab Expr
lowerEvidence (EvGlobal d) k = resolveVar d >>= k
lowerEvidence (EvParam p)  k = do
  ctx <- ask
  case Map.lookup p (ecEvidence ctx) of
    Just n  -> k (AVar n)
    Nothing -> resolveVar p >>= k   -- defensive: fall back to a global/fresh
lowerEvidence (EvApp d evs) k =
  lowerEvidenceAll evs $ \subAtoms -> do
    dA <- resolveVar d
    n  <- bindFresh (Tx.pack "dict")
    -- The dict-builder result type is erased; a nullary user con stands in.
    let dictTy = CTCon (TcUser d) []
    Let (Binder n Unrestricted dictTy) (RApp dA subAtoms) <$> k (AVar n)

-- | Lower a list of evidence terms left-to-right, collecting the atoms.
lowerEvidenceAll :: [Evidence] -> ([Atom] -> Elab Expr) -> Elab Expr
lowerEvidenceAll []       k = k []
lowerEvidenceAll (e:es)   k =
  lowerEvidence e $ \a -> lowerEvidenceAll es $ \as -> k (a : as)

-- | Lower a 'TQVar' use (a constrained-identifier reference), given the already
-- normalized argument atoms (empty for a bare value use), and a continuation
-- expecting the resulting 'Rhs'.
--
-- Two cases, distinguished by whether the name is a class method:
--
-- * Class method: project the method out of its dictionary via a single-alt
--   'Case' over the dict, then apply it to the args INSIDE the alt (so the
--   projected field stays in scope). The continuation runs inside the alt.
--
-- * Ordinary constrained function: resolve each constraint to a dict atom and
--   pass the dicts as LEADING arguments to the function.
lowerTQVar :: CType -> Text -> [(Text, CType)] -> [Atom]
           -> (Rhs -> Elab Expr) -> Elab Expr
lowerTQVar ty name cs args k = do
  ctx <- ask
  case classOfMethod name (ecEnv ctx) of
    Just cls ->
      -- Class method: cs is exactly the single constraint for this method.
      let argTy = case lookup cls cs of
            Just t  -> t
            Nothing -> case cs of
              ((_, t) : _) -> t
              []           -> error ("elaborate: TQVar class method "
                                      <> Tx.unpack name <> " has no constraint")
      in case lookupClass cls (ecEnv ctx) of
           Nothing -> error ("elaborate: unknown class " <> Tx.unpack cls)
           Just ci ->
             case elemIndex name (ciMethodNames ci) of
               Nothing -> error ("elaborate: method " <> Tx.unpack name
                                  <> " not in class " <> Tx.unpack cls)
               Just idx ->
                 evidenceAtom (cls, argTy) $ \dAtom -> do
                   -- One field binder per declared method; project field `idx`.
                   -- Field binder types are erased; the use-site type stands in.
                   fns <- mapM (const (bindFresh (Tx.pack "f"))) (ciMethodNames ci)
                   let dictCon      = ciDictCon ci
                       fieldBinders = map (\n -> Binder n Unrestricted ty) fns
                       methodAt     = AVar (fns !! idx)
                   altBody <-
                     if null args
                       then k (RAtom methodAt)
                       else k (RApp methodAt args)
                   pure (Case dAtom [AltCon dictCon fieldBinders altBody])
    Nothing ->
      -- Ordinary constrained function: dicts become leading arguments.
      lowerEvidenceAtoms cs $ \evs -> do
        fA <- resolveVar name
        k (RApp fA (evs ++ args))

-- | Lower each constraint of a 'TQVar' to a dict atom, left-to-right.
lowerEvidenceAtoms :: [(Text, CType)] -> ([Atom] -> Elab Expr) -> Elab Expr
lowerEvidenceAtoms []       k = k []
lowerEvidenceAtoms (c:cs)   k =
  evidenceAtom c $ \a -> lowerEvidenceAtoms cs $ \as -> k (a : as)

-- ---------------------------------------------------------------------------

-- | Elaborate to a single Rhs (naming sub-parts first), then continue.
elabRhs :: TExpr -> (Rhs -> Elab Expr) -> Elab Expr
elabRhs (Texp ty node) = elabRhsF ty node

elabRhsF :: CType -> TexpF CType -> (Rhs -> Elab Expr) -> Elab Expr

-- Literals
elabRhsF _ (TLitI i) k = k (RAtom (ALit (LInt i)))
elabRhsF _ (TLitS s) k = k (RAtom (ALit (LStr s)))
elabRhsF _ (TLitC c) k = k (RAtom (ALit (LChar c)))
elabRhsF _ TUnit     k = k (RAtom (ALit LUnit))

-- Variable
elabRhsF _ (TVar t) k = do
  a <- resolveVar t
  k (RAtom a)

-- Operator as a value, e.g. (+)
elabRhsF _ (TParenOp s) k = do
  a <- resolveVar s
  k (RAtom a)

-- Constrained-identifier use as a BARE value (no args): lower the evidence
-- and either project the method out of its dict, or partially apply the
-- constrained function to its leading dict arguments.
elabRhsF ty (TQVar n cs) k = lowerTQVar ty n cs [] k

-- Constructor: eta-expand if arity > 0, emit RCon [] if nullary
elabRhsF ty (TCon c) k = do
  a <- conArityOf c
  rhs <- saturateCon ty c [] a
  k rhs

-- Effect-operation reference (zero-argument): E.op
elabRhsF _ (TProjCon effect op) k = k (ROp effect op [])

-- Application: head + args. Head being a constructor or effect op is visible.
elabRhsF ty (TApp hd args) k =
  normAll args $ \atoms ->
    case hd of
      Texp _ (TCon c) -> do
        a <- conArityOf c
        rhs <- saturateCon ty c atoms a
        k rhs
      Texp _ (TProjCon effect op) -> k (ROp effect op atoms)
      -- Constrained-identifier as APP head: lower with the arg atoms, so a
      -- class method is case-projected then applied inside its alt, and an
      -- ordinary constrained function gets its dicts as leading args.
      Texp hty (TQVar n cs) -> lowerTQVar hty n cs atoms k
      _ -> normName hd $ \h -> k (RApp h atoms)

-- Lambda
elabRhsF _ (TLam pats body) k = do
  (binders, extender) <- elabParams pats
  bodyExpr <- extender (elabTail body)
  k (RLam binders bodyExpr)

-- Tuple: elaborate all elements, emit RCon "TupleN"
elabRhsF _ (TTuple elems) k =
  normAll elems $ \atoms -> k (RCon (tupleTag (length elems)) atoms)

-- List
elabRhsF _  (TList []) k = k (RCon (Tx.pack "Nil") [])
elabRhsF ty (TList xs) k =
  normAll xs $ \atoms -> consChain ty atoms k

-- Record projection
elabRhsF _ (TProj e l) k = normName e $ \a -> k (RProj l a)

-- Record construction: normalize field exprs, reorder to declared field order
elabRhsF _ (TRecord t fields) k =
  let labels = map fst fields
      exprs  = map snd fields
  in normAll exprs $ \atoms -> do
       let sourcePairs = zip labels atoms
       env <- asks ecEnv
       let orderedLabels = case lookupRecordCon t env of
             Just rci -> map fst (rcFields rci)
             Nothing  -> labels   -- fallback: source order
           ordered = [ (lbl, atom)
                     | lbl <- orderedLabels
                     , Just atom <- [lookup lbl sourcePairs]
                     ]
           finalPairs = if length ordered == length orderedLabels
                          then ordered
                          else sourcePairs
       k (RRecord t finalPairs)

-- Record extension: spread + per-field overrides, processed in declared field
-- order. For each declared field: if overridden, evaluate the override
-- expression and bind its result; otherwise project the field from the spread.
elabRhsF _ (TRecordExt t spreadExpr overrideFields) k =
  normName spreadExpr $ \spreadAtom -> do
    -- the spread record type stands in as the projected-field binder type
    -- (binder types are erased in output and ignored by the runtime).
    let fieldTy = teType spreadExpr
        overrides = Map.fromList overrideFields
    env <- asks ecEnv
    let declaredFields = case lookupRecordCon t env of
          Just rci -> map fst (rcFields rci)
          Nothing  -> map fst overrideFields  -- fallback: source order
    buildFieldLets fieldTy overrides declaredFields spreadAtom [] $ \finalPairs ->
      k (RRecord t finalPairs)
  where
    buildFieldLets :: CType -> Map.Map Text TExpr -> [Text] -> Atom
                   -> [(Text, Atom)] -> ([(Text, Atom)] -> Elab Expr) -> Elab Expr
    buildFieldLets _   _         []         _      acc cont = cont (reverse acc)
    buildFieldLets fty overrides (lbl:lbls) spread acc cont =
      case Map.lookup lbl overrides of
        Just oe -> normName oe $ \atom ->
          buildFieldLets fty overrides lbls spread ((lbl, atom) : acc) cont
        Nothing -> do
          p <- bindFresh (Tx.pack "p")
          body <- buildFieldLets fty overrides lbls spread ((lbl, AVar p) : acc) cont
          pure (Let (Binder p Unrestricted fty) (RProj lbl spread) body)

-- Compound forms reach elabRhs only via normName's non-compound guard never
-- firing; handle them by going through a join so a value-position result exists.
elabRhsF ty node@(TIf{}) k = elabCompoundRhs ty node k
elabRhsF ty node@(TCase{}) k = elabCompoundRhs ty node k
elabRhsF ty node@(THandle{}) k = elabCompoundRhs ty node k

elabRhsF _ (TLet decls body) k = elabLocalDecls decls (elabRhs body k)

-- | A compound expression appearing where a single Rhs is expected: route it
-- through normName (which introduces the join) and hand the resulting atom to k.
elabCompoundRhs :: CType -> TexpF CType -> (Rhs -> Elab Expr) -> Elab Expr
elabCompoundRhs ty node k = normName (Texp ty node) (k . RAtom)

-- ---------------------------------------------------------------------------
-- Position-aware tail elaborator (handles branching control flow)

-- | Elaborate an expression in tail position with an explicit tail continuation.
-- Compound forms (TIf, TCase, TLet, THandle) branch/recurse with the same tk.
-- Non-compound forms fall through to elabRhs + deliverRhs.
elabK :: TailK -> TExpr -> Elab Expr
elabK tk (Texp ty node) = elabKF tk ty node

elabKF :: TailK -> CType -> TexpF CType -> Elab Expr

-- if-then-else: desugar to Case over True / False constructors.
elabKF tk _ (TIf c a b) =
  normName c $ \ca -> do
    ta <- elabK tk a
    tb <- elabK tk b
    pure (Case ca [ AltCon (Tx.pack "True") [] ta
                  , AltCon (Tx.pack "False") [] tb ])

-- case scrutinee of alts
elabKF tk _ (TCase scrut alts) =
  normName scrut $ \sa -> Case sa <$> mapM (elabCaseAlt tk sa) alts

-- let ... in body: emit bindings then elaborate body in same tail position
elabKF tk _ (TLet decls body) =
  elabLocalDecls decls (elabK tk body)

-- with { E.op ps -> body ; v -> body } EXPR
elabKF tk _ (THandle e arms) = do
  let opArmsSrc  = [ (effect, op, ps, resume, body)
                   | TOpArm effect op ps resume body <- arms ]
      retArmsSrc = [ (pat, body) | TReturnArm pat body <- arms ]
      paramSrc   = [ (name, initE) | TParamArm name initE <- arms ]
  handledBody <- elabK TRet e
  -- Allocate the handler-local parameter binder up front (slice 4a). The SAME
  -- `pn` flows into: withLocal (so arm bodies see the param), hParamB (so the
  -- runtime re-installs it on resume), and the wrapping `let pn = init`.
  mParam <- case paramSrc of
    []                -> pure Nothing
    ((name, initE):_) -> do
      pn <- bindFresh name
      pure (Just (pn, name, initE))
  opArms <- mapM (elabOpArm tk mParam) opArmsSrc
  retArm <- case retArmsSrc of
    ((pat, rb) : _) -> elabReturnArm tk mParam pat rb
    [] -> do
      vN <- bindFresh (Tx.pack "v")
      pure (Binder vN Unrestricted (teType e), deliverAtom tk (AVar vN))
  let answerJoin = case tk of
        TJump j -> Just j   -- value position: arms deliver via `jump j`
        TRet    -> Nothing  -- tail position: arms tail-return; nothing to rebind
      hParamB = fmap (\(pn, _, initE) -> Binder pn Unrestricted (teType initE)) mParam
      core    = Handle handledBody (Handler retArm opArms answerJoin hParamB)
  case mParam of
    Nothing             -> pure core
    Just (pn, _, initE) ->
      -- Seed the handler-local param: `let pn = init in Handle …`. The let wraps
      -- the WHOLE Handle so `pn` is in scope when the handler is captured.
      normName initE $ \a ->
        pure (Let (Binder pn Unrestricted (teType initE)) (RAtom a) core)
  where
    elabReturnArm :: TailK -> Maybe (Name, Text, TExpr) -> TPat -> TExpr -> Elab (Binder, Expr)
    elabReturnArm tk2 mParam (Tpat pty (TPVar v)) rb = do
      vN <- bindFresh v
      rbE <- paramWrap mParam (withLocal v vN (elabK tk2 rb))
      pure (Binder vN Unrestricted pty, rbE)
    elabReturnArm tk2 mParam (Tpat pty _) rb = do
      vN <- bindFresh (Tx.pack "v")
      rbE <- paramWrap mParam (elabK tk2 rb)
      pure (Binder vN Unrestricted pty, rbE)

    -- Make the handler-local param name resolve to its binder inside an arm.
    paramWrap :: Maybe (Name, Text, TExpr) -> Elab a -> Elab a
    paramWrap (Just (pn, nm, _)) = withLocal nm pn
    paramWrap Nothing            = id

    elabOpArm :: TailK -> Maybe (Name, Text, TExpr) -> (Text, Text, [TPat], Text, TExpr) -> Elab OpArm
    elabOpArm tk2 mParam (effect, op, ps, resumeName, body) = do
      (argBinders, extender) <- elabParams ps
      resumeN <- bindFresh (Tx.pack "resume")
      armBody <-
        if Tx.null resumeName
          then
            -- AUTO-RESUME: let res = resume(param, body) in deliver res. In a
            -- parameterized handler the current param is the FIRST resume arg.
            paramWrap mParam $ extender $ normName body $ \v -> do
              res <- bindFresh (Tx.pack "res")
              let call = case mParam of
                    Just (pn, _, _) -> RApp (AVar resumeN) [AVar pn, v]
                    Nothing         -> RApp (AVar resumeN) [v]
              pure (Let (Binder res Unrestricted (teType body))
                        call
                        (deliverAtom tk2 (AVar res)))
          else
            -- CONTROL: bind the surface name to the resume binder; elaborate the
            -- body as-is (it already has the answer type R).
            paramWrap mParam $ extender $ withLocal resumeName resumeN (elabK tk2 body)
      -- NOTE: the resume binder is annotated with `teType body`, which is the op
      -- RESULT type T in the auto-resume branch (correct) but the ANSWER type R in
      -- the control branch (imprecise: the continuation is T -> R). This field is
      -- currently unused (the interpreter keys resume by name; no typed pass reads
      -- it), so it is a latent placeholder. Fix when the typed-Core pass needs a
      -- precise resume type -- it will need T threaded onto TOpArm (roadmap follow-up).
      pure (OpArm effect op argBinders (Binder resumeN Unrestricted (teType body)) armBody)

-- Non-compound: name the result and deliver under tk
elabKF tk ty node = elabRhsF ty node (deliverRhs tk ty)

-- ---------------------------------------------------------------------------
-- Tail position elaboration

-- | Elaborate in tail position (the outermost tail continuation is TRet).
elabTail :: TExpr -> Elab Expr
elabTail = elabK TRet

-- ---------------------------------------------------------------------------
-- Local declarations (let / where)

-- | Elaborate a group of local declarations, wrapping the given continuation.
--
-- Layout: a single LetRec for all function bindings (those with params), then
-- value Let-bindings (in source order), then the continuation body. Functions
-- see each other and all value bindings are in scope everywhere in the group.
elabLocalDecls :: [TLocalDecl CType] -> Elab Expr -> Elab Expr
elabLocalDecls decls cont = do
  -- Partition into value bindings (no params) and function bindings (params).
  let (valueBnds, funcBnds) = foldr classify ([], []) decls
        where
          classify (TLocalDecl fn [] body) (vs, fs) = ((fn, body) : vs, fs)
          classify (TLocalDecl fn ps body) (vs, fs) = (vs, (fn, ps, body) : fs)

  -- Mint a fresh Name for every bound name up front, extending ecScope with ALL
  -- of them so mutual/forward references resolve.
  let allNames = map fst valueBnds ++ map (\(fn, _, _) -> fn) funcBnds
  freshPairs <- mapM (\t -> (,) t <$> bindFresh t) allNames
  withLocals freshPairs $ do
    funcDefs <- mapM (elabFuncBnd freshPairs) funcBnds
    inner <- buildValueLets freshPairs valueBnds cont
    case funcDefs of
      [] -> pure inner
      _  -> pure (LetRec funcDefs inner)

  where
    elabFuncBnd :: [(Text, Name)] -> (Text, [TPat], TExpr)
                -> Elab (Binder, [Binder], Expr)
    elabFuncBnd freshPairs (fn, params, body) =
      case lookup fn freshPairs of
        Nothing -> error ("elabLocalDecls: internal: name not found: " <> Tx.unpack fn)
        Just n  -> do
          (paramBinders, extender) <- elabParams params
          bodyExpr <- extender (elabK TRet body)
          -- The function binder's type is the overall binding type; use the
          -- body type as a stand-in (erased printer/runtime ignore it).
          pure (Binder n Unrestricted (teType body), paramBinders, bodyExpr)

    buildValueLets :: [(Text, Name)] -> [(Text, TExpr)] -> Elab Expr -> Elab Expr
    buildValueLets _ [] cont0 = cont0
    buildValueLets freshPairs ((fn, body) : rest) cont0 =
      case lookup fn freshPairs of
        Nothing -> error ("elabLocalDecls: internal: name not found: " <> Tx.unpack fn)
        Just n  -> do
          inner <- buildValueLets freshPairs rest cont0
          normName body $ \atom ->
            pure (Let (Binder n Unrestricted (teType body)) (RAtom atom) inner)

-- ---------------------------------------------------------------------------
-- Pattern compilation

-- | Compile one typed case-alternative to one target Alt. The where-clause is
-- already folded into the body as a leading TLet by inference.
elabCaseAlt :: TailK -> Atom -> TAlt CType -> Elab Alt
elabCaseAlt tk scrut (TAlt pat wh body) =
  elabPat tk scrut pat (elabLocalDecls wh (elabK tk body))

-- | Compile a Tpat into an Alt, given the scrutinee atom and the body action.
elabPat :: TailK -> Atom -> TPat -> Elab Expr -> Elab Alt
elabPat tk scrut (Tpat ty pnode) = elabPatF tk ty scrut pnode

elabPatF :: TailK -> CType -> Atom -> TpatF CType -> Elab Expr -> Elab Alt
elabPatF _  _  _     TPWild     body = AltDefault <$> body
elabPatF _  _  _     TPUnit     body = AltDefault <$> body   -- unit is irrefutable
elabPatF _  ty scrut (TPVar v)  body = do
  n <- bindFresh v
  bodyExpr <- withLocal v n body
  pure (AltDefault (Let (Binder n Unrestricted ty) (RAtom scrut) bodyExpr))
elabPatF _  _  _     (TPLitI i) body = AltLit (LInt i)  <$> body
elabPatF _  _  _     (TPLitS s) body = AltLit (LStr s)  <$> body
elabPatF _  _  _     (TPLitC c) body = AltLit (LChar c) <$> body
elabPatF tk _  _     (TPTuple subPats) body = do
  let n   = length subPats
      tag = tupleTag n
  (fieldBinders, wrapBody) <- buildSubPats tk subPats
  wrappedBody <- wrapBody body
  pure (AltCon tag fieldBinders wrappedBody)
elabPatF _  _  _     (TPList []) body = AltCon (Tx.pack "Nil") [] <$> body
elabPatF _  _  _     (TPList _)  _    =
  -- Non-empty list literal patterns require EXACT-length matching, which in
  -- turn needs a pattern-match compiler that can backtrack from a failed
  -- inner Nil/Cons test to the enclosing alternatives. The flat one-Alt-per-
  -- clause model here cannot express that without silently committing to the
  -- first Cons arm (matching ANY non-empty list). Rather than ship wrong
  -- semantics, reject these the way main did. Use @h :: t@ cons patterns.
  error "pattern not yet supported: non-empty list literal pattern (use h :: t)"
elabPatF tk _  _     (TPCons headP tailP) body = do
  -- If the head/tail are trivial vars/wilds, avoid nested cases.
  (headBinders, headWrap) <- buildSubPats tk [headP]
  (tailBinders, tailWrap) <- buildSubPatFromPat tk tailP
  wrappedBody <- headWrap (tailWrap body)
  pure (AltCon (Tx.pack "Cons") (headBinders ++ tailBinders) wrappedBody)
elabPatF tk _  scrut (TPCon conName subPats) body = do
  env <- asks ecEnv
  case lookupRecordCon conName env of
    Just rci -> do
      -- Record constructor: compile to label-keyed field binding, in the
      -- declared field order. Subpatterns are positional in declared order.
      let labels = map fst (rcFields rci)
      innerBody <- buildRecordFieldBindings tk scrut (zip labels subPats) body
      pure (AltCon conName [] innerBody)
    Nothing -> do
      -- Ordinary data constructor: positional field binders.
      (fieldBinders, wrapBody) <- buildSubPats tk subPats
      wrappedBody <- wrapBody body
      pure (AltCon conName fieldBinders wrappedBody)
elabPatF tk ty scrut (TPAs name inner) body = do
  -- `inner as name`: bind `name` to the WHOLE scrutinee (irrefutable Let), with
  -- `name` in scope in the body, then match the inner pattern against the SAME
  -- scrutinee. Refutability is the inner pattern's.
  n <- bindFresh name
  let body' = do
        b <- withLocal name n body
        pure (Let (Binder n Unrestricted ty) (RAtom scrut) b)
  elabPat tk scrut inner body'

-- | Build the field-projection let-chain for a list of (label, subPat) record
-- field bindings, in declared order. Fields whose sub-pattern is a wildcard are
-- SKIPPED (not projected) to preserve the original ANF: open and wild record
-- patterns leave absent fields unprojected.
buildRecordFieldBindings :: TailK -> Atom -> [(Text, TPat)] -> Elab Expr -> Elab Expr
buildRecordFieldBindings _  _     []                   cont = cont
buildRecordFieldBindings tk scrut ((l, subPat) : rest) cont = do
  let innerCont = buildRecordFieldBindings tk scrut rest cont
  case subPat of
    Tpat _ TPWild ->
      -- absent / wildcard field: do not project, do not bind
      innerCont
    Tpat fty (TPVar tv) -> do
      n <- bindFresh l
      body <- withLocal tv n innerCont
      pure (Let (Binder n Unrestricted fty) (RProj l scrut) body)
    Tpat fty _ -> do
      n <- bindFresh l
      body <- do
        alt <- elabPat tk (AVar n) subPat innerCont
        pure (Case (AVar n) [alt])
      pure (Let (Binder n Unrestricted fty) (RProj l scrut) body)

-- | Build field binders and a body wrapper from a list of sub-patterns (used by
-- constructor and tuple patterns). Each binder carries its sub-pattern's type.
buildSubPats :: TailK -> [TPat] -> Elab ([Binder], Elab Expr -> Elab Expr)
buildSubPats _  [] = pure ([], id)
buildSubPats tk (p:ps) = do
  (bs, wraps) <- buildSubPats tk ps
  case p of
    Tpat fty (TPVar tv) ->
      do n <- bindFresh tv
         pure (Binder n Unrestricted fty : bs, withLocal tv n . wraps)
    Tpat fty TPWild ->
      do n <- bindFresh (Tx.pack "_")
         pure (Binder n Unrestricted fty : bs, wraps)
    Tpat fty TPUnit ->
      do n <- bindFresh (Tx.pack "_")
         pure (Binder n Unrestricted fty : bs, wraps)
    Tpat fty _ ->
      do n <- bindFresh (Tx.pack "t")
         let b = Binder n Unrestricted fty
             wrapNested inner = do
               alt <- elabPat tk (AVar n) p (wraps inner)
               pure (Case (AVar n) [alt])
         pure (b : bs, wrapNested)

-- | Build a single binder + wrapper for a Cons tail pattern. Trivial var/wild
-- tails avoid a nested case.
buildSubPatFromPat :: TailK -> TPat -> Elab ([Binder], Elab Expr -> Elab Expr)
buildSubPatFromPat tk p = case p of
  Tpat fty TPWild -> do
    n <- bindFresh (Tx.pack "_")
    pure ([Binder n Unrestricted fty], id)
  Tpat fty (TPVar tv) -> do
    n <- bindFresh tv
    pure ([Binder n Unrestricted fty], withLocal tv n)
  Tpat fty _ -> do
    n <- bindFresh (Tx.pack "t")
    let b = Binder n Unrestricted fty
        wrap inner = do
          alt <- elabPat tk (AVar n) p inner
          pure (Case (AVar n) [alt])
    pure ([b], wrap)

-- ---------------------------------------------------------------------------
-- Top-level module elaboration

-- | A bodyless top-level signature surfaces as a sentinel 'TypedDecl': no
-- params and a body that is just the bound name referencing itself
-- (@Texp _ (TVar name)@ with @name == tdName@). Such decls have no RHS and must
-- NOT produce a 'TopBind' -- the original elaboration only emitted binds for
-- equations, never for bare signatures.
isBodylessSig :: TypedDecl -> Bool
isBodylessSig td = case tdClauses td of
  [([], Texp _ (TVar v))] -> v == tdName td
  _                       -> False

-- ---------------------------------------------------------------------------
-- Multi-clause function heads (via the pure match compiler)

-- | Build the constructor oracle the match compiler needs from the type env.
-- Built-in structural tags (TupleN, Nil/Cons) are answered directly; user data
-- constructors come from envCons/envTyCons.
buildOracle :: Env -> ConOracle
buildOracle env = ConOracle
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

-- | Translate a typed pattern into a match-compiler 'MPat'. Record-constructor
-- patterns are rejected: the flat decision-tree leaves cannot project record
-- fields, so multi-clause / refutable record heads are a documented limitation.
toMPat :: Env -> TPat -> MPat
toMPat env (Tpat ty pnode) = MPat ty (go pnode)
  where
    go (TPVar v)    = MVar (Just v)
    go TPWild       = MVar Nothing
    go TPUnit       = MVar Nothing
    go (TPLitI i)   = MLit (LInt i)
    go (TPLitS s)   = MLit (LStr s)
    go (TPLitC c)   = MLit (LChar c)
    go (TPTuple ps) = MCon (tupleTag (length ps)) (map (toMPat env) ps)
    go (TPList [])  = MCon (Tx.pack "Nil") []
    go (TPList _)   = error "match: non-empty list literal pattern (use h :: t)"
    go (TPCons h t) = MCon (Tx.pack "Cons") [toMPat env h, toMPat env t]
    go (TPCon c ps) = case lookupRecordCon c env of
      Just _  -> error ("match: record-constructor pattern not supported in a "
                        <> "multi-clause / refutable head: " <> Tx.unpack c)
      Nothing -> MCon c (map (toMPat env) ps)
    go (TPAs name inner) = MAs name (toMPat env inner)

-- | The variables a clause head binds, in left-to-right order. This order is the
-- contract between a clause's join-point parameters and the positional atoms the
-- decision-tree leaf 'Jump's with.
clauseVars :: [TPat] -> [(Text, CType)]
clauseVars = concatMap patVars
  where
    patVars (Tpat ty (TPVar v))    = [(v, ty)]
    patVars (Tpat _  (TPTuple ps)) = concatMap patVars ps
    patVars (Tpat _  (TPList ps))  = concatMap patVars ps
    patVars (Tpat _  (TPCons h t)) = patVars h ++ patVars t
    patVars (Tpat _  (TPCon _ ps)) = concatMap patVars ps
    patVars (Tpat ty (TPAs name inner)) = (name, ty) : patVars inner
    patVars _                      = []   -- wildcard / unit / literal bind nothing

-- | Compile a clause group into fresh argument binders plus a decision-tree body
-- wrapped in one 'LetJoin' per clause. Each clause's body becomes a join point
-- whose parameters are exactly its bound variables (left-to-right); the decision
-- tree's leaves 'Jump' to the matching join with the captured atoms in order.
compileClauses :: [([TPat], TExpr)] -> Elab ([Binder], Expr)
compileClauses [] = error "compileClauses: empty clause group"
compileClauses clauses@((firstPats, _) : _) = do
  env <- asks ecEnv
  let colTypes = map (\(Tpat ty _) -> ty) firstPats
      arity    = length colTypes
  paramNames <- mapM (const (bindFresh (Tx.pack "p"))) [1 .. arity]
  let paramBinders = zipWith (`Binder` Unrestricted) paramNames colTypes
      scruts       = map AVar paramNames
  built <- mapM buildClauseJoin clauses     -- [(JoinId, [(Text,CType,Name)], Expr)]
  let rows = [ Row { rowPats  = map (toMPat env) ps
                   , rowSubst = []
                   , rowJoin  = jid
                   , rowOrder = [ v | (v, _, _) <- vars ]
                   , rowIndex = ix }
             | (ix, (ps, _), (jid, vars, _)) <- zip3 [0 ..] clauses built ]
  tree <- lift (compileMatch (buildOracle env) scruts rows)
  let wrapped = foldr
        (\(jid, vars, jbody) acc ->
            LetJoin jid [ Binder n Unrestricted t | (_, t, n) <- vars ] jbody acc)
        tree built
  pure (paramBinders, wrapped)
  where
    buildClauseJoin (ps, body) = do
      jid <- lift freshJoin
      triples <- mapM (\(v, t) -> do n <- bindFresh v; pure (v, t, n)) (clauseVars ps)
      jbody <- withLocals [ (v, n) | (v, _, n) <- triples ] (elabTail body)
      pure (jid, triples, jbody)

-- | A head pattern that always matches (no decision needed). Single-clause heads
-- composed entirely of irrefutable patterns keep the cheap 'elabParams' path so
-- existing single-clause ANF is byte-identical. Record-constructor patterns are
-- irrefutable (one constructor) and stay on that path too.
irrefutableHead :: Env -> TPat -> Bool
irrefutableHead env (Tpat _ pnode) = case pnode of
  TPVar _   -> True
  TPWild    -> True
  TPUnit    -> True
  TPCon c _ -> case lookupRecordCon c env of Just _ -> True; Nothing -> False
  TPAs _ inner -> irrefutableHead env inner
  _         -> False

-- | Elaborate one TypedDecl into a 'TopBind', given the resolved global Name.
--
-- For a constrained binding, the declared evidence parameters ('tdEvidence')
-- are lowered into dictionary binders prepended BEFORE the value parameters,
-- and an evidence scope (paramName -> binder, plus the in-scope quantified
-- indices for 'Solve') is threaded through the body. Unconstrained bindings
-- ('tdEvidence' empty) elaborate byte-identically to before.
elabTopBind :: Map.Map Text Name -> TypedDecl -> Elab TopBind
elabTopBind globals td = do
  let fname = tdName td
      name  = Map.findWithDefault (errName fname) fname globals
  -- Lower the evidence parameters into dict binders.
  evBinders <- mapM mintEvidenceBinder (tdEvidence td)
  let evScope = Map.fromList
        [ (pName, bndName b) | ((pName, _), b) <- zip (tdEvidence td) evBinders ]
      evIdx = Set.fromList [ i | (_, Constraint _ (CTGen i)) <- tdEvidence td ]
  local (\ctx -> ctx { ecEvidence = evScope, ecEvidenceIdx = evIdx }) $ do
    env <- asks ecEnv
    -- Single-clause irrefutable heads (plain variables / wildcards / unit, and
    -- single-clause record-constructor heads) keep the cheap elabParams path so
    -- existing ANF stays byte-identical. Any group of >1 clause, or a refutable
    -- single-clause head, goes through the decision-tree match compiler.
    (paramBinders, bodyExpr) <- case tdClauses td of
      [(params, body)]
        | all (irrefutableHead env) params -> do
            (pbs, extender) <- elabParams params
            be <- extender (elabTail body)
            pure (pbs, be)
      []      -> error ("elaborateModule: no clauses for " <> Tx.unpack (tdName td))
      clauses -> compileClauses clauses
    pure (TopBind name (evBinders ++ paramBinders) bodyExpr)
  where
    errName t = error ("elaborateModule: top-level name not in env: " <> Tx.unpack t)
    -- Mint a dict binder for one evidence parameter. The binder type is the
    -- dict data type (annotation only; erased at runtime).
    mintEvidenceBinder (pName, Constraint cls argTy) = do
      n <- bindFresh pName
      let dictTy = case argTy of
            CTGen i -> CTCon (TcUser cls) [CTGen i]
            _       -> CTCon (TcUser cls) [argTy]
      pure (Binder n Unrestricted dictTy)

-- | Elaborate every top-level binding in a module into a 'TopBind'.
-- One canonical 'Name' is minted for every value-level global (from 'envVars'),
-- so that the binding site and every reference share the same identity.
elaborateModule :: Env -> [TypedDecl] -> CoreModule
elaborateModule env tds =
  runFresh $ do
    gpairs <- mapM (\t -> (,) t <$> freshName t) (Map.keys (envVars env))
    let globals = Map.fromList gpairs
    binds <- mapM (\td -> runReaderT (elabTopBind globals td)
                                     (ElabCtx env Map.empty globals Map.empty Set.empty))
                  (filter (not . isBodylessSig) tds)
    pure (CoreModule binds)

-- | Elaborate several modules into one CoreModule, minting global names ONCE
-- from the union of all modules' value-level vars so cross-module references
-- share identity. Each module elaborates with its OWN env but the SHARED
-- globals map.
elaborateModulesShared :: [(Env, [TypedDecl])] -> CoreModule
elaborateModulesShared mods =
  runFresh $ do
    let allVarNames = Map.keys (Map.unions [ envVars env | (env, _) <- mods ])
    gpairs <- mapM (\t -> (,) t <$> freshName t) allVarNames
    let globals = Map.fromList gpairs
    binds <- concat <$> mapM (elabOne globals) mods
    pure (CoreModule binds)
  where
    elabOne globals (env, tds) =
      mapM (\td -> runReaderT (elabTopBind globals td)
                              (ElabCtx env Map.empty globals Map.empty Set.empty))
           (filter (not . isBodylessSig) tds)

-- ---------------------------------------------------------------------------
-- Public test seam

elaborateExprForTest :: Env -> TExpr -> Expr
elaborateExprForTest env e =
  runFresh (runReaderT (elabTail e) (ElabCtx env Map.empty Map.empty Map.empty Set.empty))
