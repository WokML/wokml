module Wok.IR.Elaborate
  ( elaborateExprForTest      -- test seam: Env -> TExpr -> Expr
  , elaborateModule           -- full module elaboration: entryModule -> Env -> [TypedDecl] -> CoreModule
  , elaborateModulesShared    -- whole-program: [(moduleName, Env, [TypedDecl])] -> CoreModule
  ) where

import Control.Monad.Reader
import Control.Monad.State.Strict (State)
import Data.Foldable (foldrM)
import qualified Data.Graph as Graph
import Data.Graph (SCC (..))
import Data.List (elemIndex)
import qualified Data.Map.Strict as Map
import Data.Set (Set)
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as Tx
import Wok.IR.Anf
import Wok.IR.Name
import Wok.FFI.Blessed (lookupBlessed, bsReturn)
import Wok.TypeChecking.Env
  ( Env, envVars, envVarOrigin, lookupCon, conArity, conTyCon, lookupRecordCon, rcFields
  , lookupTyCon, TyConInfo (..)
  , classOfMethod, lookupClass, ClassInfo (..)
  , lookupForeignModule, ForeignModuleInfo (..), ForeignMemberInfo (..) )
import Wok.TypeChecking.Carrier (freeVars)
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
  , ecPrims       :: Map.Map Name (Text, Text)
    -- ^ canonical 'Name' of each value-level prelude @extern@ -> its qualified
    -- @(definingModule, name)@ key. A resolved GLOBAL whose 'Name' is in here is
    -- emitted as 'APrim'; locals are never routed here.
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
    Just n  -> pure (AVar n)           -- locals are NEVER routed to APrim
    Nothing -> case Map.lookup t (ecGlobals ctx) of
      Just n  -> case Map.lookup n (ecPrims ctx) of
                   Just qkey -> pure (APrim qkey)   -- a prelude extern, by identity
                   Nothing   -> pure (AVar n)
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
isCompound (TWithNamedH{}) = True
isCompound _           = False

-- | Elaborate an expression and name any non-trivial computation with a fresh
-- let-binder, passing the resulting Atom to the continuation.  Trivial
-- RAtom results pass the atom straight through without a Let.
--
-- For TLet in value position, emit its bindings and then normalize the body.
-- For compound expressions (TIf / TCase / THandle) in value position, introduce
-- a join so that all branches jump to a single merge point.
normName :: TExpr -> (Atom -> Elab Expr) -> Elab Expr
normName (Texp ty (TLet decls body)) k = do
  -- TLet in value position: the let's local bindings must scope ONLY over the
  -- let's own body, NOT over the continuation `k` that consumes the let result
  -- (which also normalizes later sibling arguments). Route the body through a
  -- join: `k` runs in the OUTER scope (as the join body), while the bindings +
  -- body deliver the result to the join from INSIDE the local scope.
  j     <- lift freshJoin
  r     <- bindFresh (Tx.pack "r")
  jbody <- k (AVar r)
  comp  <- elabLocalDecls decls (elabK (TJump j) body)
  pure (LetJoin j [Binder r Unrestricted ty] jbody comp)
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

-- Effect-operation reference or foreign-member reference (zero arguments).
-- If the head is a declared foreign module, partial application (zero args here)
-- is not supported; raise an elaboration error. Effect ops still route to ROp.
elabRhsF _ (TProjCon modOrEffect op) k = do
  env <- asks ecEnv
  case lookupForeignModule modOrEffect env of
    Just _ ->
      error ("elaborate: foreign module member '" <> Tx.unpack modOrEffect
             <> "." <> Tx.unpack op
             <> "' used without arguments (partial application not supported)")
    Nothing -> k (ROp Nothing modOrEffect op [])

-- Named perform `instance.op` (zero-argument). Normalize the instance node to
-- an atom and route the op through it: `ROp (Just instanceAtom) effect op []`.
-- Mirrors the ambient `TProjCon` case, but with the routing instance.
elabRhsF _ (TPerformOn inst effect op) k =
  normName inst $ \ia -> k (ROp (Just ia) effect op [])

-- Application: head + args. Head being a constructor or effect op is visible.
-- A foreign-module projection head (M.member) emits 'RForeignCall' instead
-- of 'ROp'. Saturation: the typechecker already enforced arity via the arrow
-- type, so arriving here with a saturated arg list is the only case we need.
-- If the head is a foreign member AND the arg list is empty, this should only
-- be reachable via the zero-arg arm above (which errors), so we do not need
-- to handle that here.
elabRhsF ty (TApp hd args) k =
  normAll args $ \atoms ->
    case hd of
      Texp _ (TCon c) -> do
        a <- conArityOf c
        rhs <- saturateCon ty c atoms a
        k rhs
      Texp _ (TProjCon modOrEffect op) -> do
        env <- asks ecEnv
        case lookupForeignModule modOrEffect env of
          Just fmi ->
            case Map.lookup op (fmMembers fmi) of
              Nothing ->
                error ("elaborate: foreign member '" <> Tx.unpack op
                       <> "' not in module '" <> Tx.unpack modOrEffect <> "'")
              Just minfo ->
                -- The blessed table is the contract of record: use its ReturnDisp.
                -- 'lookupBlessed' validated this pair at typecheck time; if it is
                -- absent here it is a compiler bug (the honesty gate was bypassed).
                case lookupBlessed (fmLib fmi) (fmiSymbol minfo) of
                  Nothing ->
                    error ("elaborate: unblessed foreign symbol reached elaborator: "
                           <> Tx.unpack (fmLib fmi) <> "." <> Tx.unpack (fmiSymbol minfo))
                  Just bsig ->
                    k (RForeignCall (fmLib fmi) (fmiSymbol minfo) (bsReturn bsig)
                                    (fmFree fmi) atoms)
          Nothing -> k (ROp Nothing modOrEffect op atoms)
      -- Named perform applied (e.g. `count.set x`): normalize the receiver
      -- instance to an atom, route through it: `ROp (Just ia) effect op atoms`.
      Texp _ (TPerformOn inst effect op) ->
        normName inst $ \ia -> k (ROp (Just ia) effect op atoms)
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
elabRhsF ty node@(TWithNamedH{}) k = elabCompoundRhs ty node k

-- TLet where a single Rhs is expected: scope the local bindings ONLY over the
-- let body (see normName's TLet note). Route through normName so the body's
-- result atom is handed to `k` in the OUTER scope.
elabRhsF ty (TLet decls body) k =
  normName (Texp ty (TLet decls body)) (k . RAtom)

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
--
-- The flat one-'Alt'-per-clause path ('elabCaseAlt') commits to the first
-- alternative whose TOP constructor matches and cannot backtrack to a later
-- alternative with the SAME head -- so overlapping heads with refutable
-- sub-patterns mis-dispatch (e.g. `Some 1 -> ..; Some n -> ..` on `Some 2`
-- wrongly hits NonExhaustiveCase, bug #7). When two alternatives share a
-- constructor head, route through the 'Wok.IR.Match' decision-tree compiler
-- (the same one top-level multi-clause functions use), which backtracks
-- correctly. The flat path is kept for the non-overlapping case so its ANF stays
-- byte-identical, and as the fallback for patterns the match compiler does not
-- accept (record-constructor heads, non-empty list literals).
elabKF tk _ (TCase scrut alts) =
  normName scrut $ \sa -> do
    env <- asks ecEnv
    if caseNeedsMatch env alts
      then elabCaseAltsMatch tk sa alts
      else Case sa <$> mapM (elabCaseAlt tk sa) alts

-- let ... in body: emit bindings then elaborate body in same tail position
elabKF tk _ (TLet decls body) =
  elabLocalDecls decls (elabK tk body)

-- with { E.op ps -> body ; v -> body } EXPR  (ambient handler: hSelf = Nothing)
elabKF tk _ (THandle e arms) = elabHandle tk e arms Nothing

-- with self = Effect { arms } in body  (named primitive handler). The self
-- binder's Unique IS the runtime instance id (Task 2: `Handle` binds
-- `self -> VInst (nameUniq selfBinder)`), so the SAME binder must be `hSelf`
-- AND in scope for the body — that way a `self.op` perform inside the body
-- routes to this frame. The self binder's type is erased at runtime; the
-- effect-as-type isn't a Core type, so reuse the body's Core type as a
-- well-formed stand-in (mirrors how other binders here borrow `teType`).
elabKF tk _ (TWithNamedH self arms body) = do
  selfN <- bindFresh self
  let selfBinder = Binder selfN Unrestricted (teType body)
  withLocal self selfN (elabHandle tk body arms (Just selfBinder))

-- Non-compound: name the result and deliver under tk
elabKF tk ty node = elabRhsF ty node (deliverRhs tk ty)

-- | Shared lowering for both ambient (`THandle`) and named (`TWithNamedH`)
-- handlers. `mSelf` is the self-instance binder for a named handler (set as
-- `hSelf`) or `Nothing` for an ambient one; the caller is responsible for
-- putting a named handler's self binder in scope for `e` before calling.
elabHandle :: TailK -> TExpr -> [THandlerArm CType] -> Maybe Binder -> Elab Expr
elabHandle tk e arms mSelf = do
  let opArmsSrc  = [ (effect, op, ps, resume, resumeTy, body)
                   | TOpArm effect op ps resume resumeTy body <- arms ]
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
      core    = Handle handledBody (Handler retArm opArms answerJoin hParamB mSelf)
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

    elabOpArm :: TailK -> Maybe (Name, Text, TExpr) -> (Text, Text, [TPat], Text, CType, TExpr) -> Elab OpArm
    elabOpArm tk2 mParam (effect, op, ps, resumeName, resumeContTy, body) = do
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
      -- The resume binder is typed with the threaded continuation type `T -> R`
      -- (the type the checker bound `k` to when checking this arm body), NOT
      -- `teType body` (the answer type R). An arrow is ALWAYS boxed, so the
      -- Perceus pass counts `resume` in the arm's owned set and drops it on a
      -- discard arm; typing it with an unboxed answer R would silently drop it
      -- from the owned set and leak the captured continuation (spec
      -- docs/superpowers/specs/2026-06-19-m2b-resume-binder-type-leak-fix).
      pure (OpArm effect op argBinders (Binder resumeN Unrestricted resumeContTy) armBody)

-- ---------------------------------------------------------------------------
-- Tail position elaboration

-- | Elaborate in tail position (the outermost tail continuation is TRet).
elabTail :: TExpr -> Elab Expr
elabTail = elabK TRet

-- ---------------------------------------------------------------------------
-- Local declarations (let / where)

-- | Elaborate a group of local declarations, wrapping the given continuation.
--
-- Bindings are emitted in DEPENDENCY (topological) order: a binding's
-- strongly-connected component is bound OUTSIDE every component that references
-- it. FUNCTION bindings (those with params) go in a 'LetRec' -- lazy closures
-- over the recursive env, so they see anything bound in an enclosing component;
-- VALUE bindings (no params) are strict 'Let's evaluated in that same enclosing
-- env. Because order follows the dependency graph, BOTH reference directions
-- work: a function referencing a sibling value AND a value referencing a sibling
-- function (bug #6 -- a fixed value-outside/functions-inside order regressed the
-- latter). The only shape that cannot be expressed is a genuine value<->function
-- CYCLE (a value and a function mutually recursive): such a component emits the
-- functions in a LetRec wrapping the values, so the values see the functions but
-- a function forcing the cyclic value at evaluation time would observe it unbound
-- (ill-defined in a strict language, like @x = x@).
elabLocalDecls :: [TLocalDecl CType] -> Elab Expr -> Elab Expr
elabLocalDecls decls cont = do
  -- Mint a fresh Name for every bound name up front, extending ecScope with ALL
  -- of them so mutual/forward references resolve during elaboration.
  let allNames = [ fn | TLocalDecl fn _ _ <- decls ]
      binderSet = Set.fromList allNames
  freshPairs <- mapM (\t -> (,) t <$> bindFresh t) allNames
  withLocals freshPairs $ do
    -- Intra-group dependency edges: a binding -> the sibling binders its RHS
    -- references (free vars minus its own params, restricted to the group).
    let depsOf (TLocalDecl _ params body) =
          let pvs = Set.fromList (map fst (clauseVars params))
              fvs = freeVars body `Set.difference` pvs
          in Set.toList (fvs `Set.intersection` binderSet)
        nodes = [ (d, declNameOf d, depsOf d) | d <- decls ]
        -- 'stronglyConnComp' yields SCCs with dependencies FIRST, so a left
        -- 'foldr' makes the first (dependency) component the OUTERMOST binder.
        sccs = Graph.stronglyConnComp nodes
    body <- cont
    foldrM (emitSCC freshPairs) body sccs

  where
    declNameOf (TLocalDecl fn _ _) = fn

    emitSCC :: [(Text, Name)] -> SCC (TLocalDecl CType) -> Expr -> Elab Expr
    emitSCC freshPairs (AcyclicSCC d) rest = case d of
      TLocalDecl fn [] body -> emitValue freshPairs fn body rest
      TLocalDecl fn ps body -> do
        def <- elabFuncBnd freshPairs (fn, ps, body)
        pure (LetRec [def] rest)
    emitSCC freshPairs (CyclicSCC ds) rest = do
      -- Mutually-recursive component: every function in ONE LetRec (so they may
      -- recurse), wrapping any values as inner Lets (so the values see the
      -- functions). A pure-function cycle is the common mutual-recursion case.
      let isValue (TLocalDecl _ ps _) = null ps
          (valueDs, funcDs) = (filter isValue ds, filter (not . isValue) ds)
      funcDefs <- mapM (\(TLocalDecl fn ps body) -> elabFuncBnd freshPairs (fn, ps, body)) funcDs
      inner <- foldrM (\(TLocalDecl fn _ body) acc -> emitValue freshPairs fn body acc) rest valueDs
      pure (if null funcDefs then inner else LetRec funcDefs inner)

    emitValue :: [(Text, Name)] -> Text -> TExpr -> Expr -> Elab Expr
    emitValue freshPairs fn body rest =
      case lookup fn freshPairs of
        Nothing -> error ("elabLocalDecls: internal: name not found: " <> Tx.unpack fn)
        Just n  -> normName body $ \atom ->
          pure (Let (Binder n Unrestricted (teType body)) (RAtom atom) rest)

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
      -- USER constructors are authoritative: consult the env FIRST so a user
      -- data type declaring a con named `Nil`/`Cons`/`TupleN` gets its own
      -- arity, not the built-in structural one (bug #8). Built-in tags answer
      -- only when the name is NOT a user constructor.
      case lookupCon c env of
        Just ci -> conArity ci
        Nothing -> case tupleArity c of
          Just n -> n
          Nothing
            | c == Tx.pack "Nil"  -> 0
            | c == Tx.pack "Cons" -> 2
            | otherwise -> 0
  , coSiblings = \c ->
      -- Same precedence: a user constructor's sibling set is its data type's
      -- full constructor list; only fall back to the built-in list/tuple
      -- signature for genuinely built-in literals.
      case lookupCon c env of
        Just ci
          | Just ti <- lookupTyCon (conTyCon ci) env -> Just (tcCons ti)
          | otherwise -> Nothing
        Nothing -> case tupleArity c of
          Just n -> Just [tupleTag n]
          Nothing
            | c `elem` [Tx.pack "Nil", Tx.pack "Cons"] -> Just [Tx.pack "Nil", Tx.pack "Cons"]
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

-- | Does this body-position @case@ need the decision-tree compiler? True when
-- some alternative has a REFUTABLE sub-pattern nested under a constructor/cons/
-- tuple head -- the configuration the flat one-'Alt'-per-clause path
-- mis-dispatches: it commits to the top tag, then a failing inner match (a
-- literal like @Some 0@, or a nested constructor) cannot backtrack to a later
-- alternative (a same-head sibling OR a wildcard catch-all). Bug #7. This
-- subsumes the duplicate-head case (@Some 1 -> ..; Some n -> ..@) and the
-- catch-all case (@Some 0 -> ..; _ -> ..@) alike. Distinct constructor heads with
-- only irrefutable (var/wildcard) sub-patterns stay on the flat path (its ANF is
-- byte-identical there). Kept off the match path when an alternative uses a
-- pattern 'toMPat' cannot lower (a record-constructor head or a non-empty list
-- literal); the flat path handles record heads via field projection.
caseNeedsMatch :: Env -> [TAlt CType] -> Bool
caseNeedsMatch env alts =
  not (any altHasUnsupported alts) && any armNeedsBacktrack alts
  where
    -- An arm whose top head (constructor / cons / tuple / list), once committed
    -- to by the flat path, leaves a REFUTABLE sub-obligation that could fail with
    -- a later alternative able to match -- i.e. it has a refutable sub-pattern.
    armNeedsBacktrack (TAlt pat _ _) = headHasRefutableSub pat
    headHasRefutableSub (Tpat _ p) = case p of
      TPCon _ ps   -> any isRefutable ps
      TPCons h t   -> isRefutable h || isRefutable t
      TPTuple ps   -> any isRefutable ps
      TPList ps    -> any isRefutable ps
      TPAs _ inner -> headHasRefutableSub inner
      _            -> False
    -- A pattern that can fail to match some value of its type.
    isRefutable (Tpat _ p) = case p of
      TPVar _      -> False
      TPWild       -> False
      TPUnit       -> False
      TPTuple ps   -> any isRefutable ps   -- single-con; refutable iff a field is
      TPAs _ inner -> isRefutable inner
      _            -> True                  -- literal / constructor / cons / list
    -- A pattern the match compiler cannot lower: a record-constructor head, or a
    -- non-empty list literal (both error in 'toMPat'). Checked recursively.
    altHasUnsupported (TAlt pat _ _) = patUnsupported pat
    patUnsupported (Tpat _ p) = case p of
      TPCon c ps  -> isRecordConName env c || any patUnsupported ps
      TPList []   -> False
      TPList _    -> True
      TPCons h t  -> patUnsupported h || patUnsupported t
      TPTuple ps  -> any patUnsupported ps
      TPAs _ inner -> patUnsupported inner
      _           -> False

-- | Is @c@ a record constructor in scope? (The match compiler's 'toMPat' has no
-- way to project record fields, so such heads stay on the flat path.)
isRecordConName :: Env -> Text -> Bool
isRecordConName env c = case lookupRecordCon c env of
  Just _  -> True
  Nothing -> False

-- | Compile a body-position @case@ whose alternatives share a constructor head
-- through the decision-tree compiler, matching directly on the existing
-- scrutinee atom (no fresh parameter). Each alternative becomes a join point
-- whose parameters are its bound variables (left-to-right); its @where@ decls and
-- body are elaborated under the SAME tail continuation @tk@ as the flat path.
elabCaseAltsMatch :: TailK -> Atom -> [TAlt CType] -> Elab Expr
elabCaseAltsMatch tk scrut alts = do
  env <- asks ecEnv
  built <- mapM buildAltJoin alts   -- [(JoinId, [(Text,CType,Name)], Expr)]
  let rows = [ Row { rowPats  = [toMPat env pat]
                   , rowSubst = []
                   , rowJoin  = jid
                   , rowOrder = [ v | (v, _, _) <- vars ]
                   , rowIndex = ix }
             | (ix, TAlt pat _ _, (jid, vars, _)) <- zip3 [0 ..] alts built ]
  tree <- lift (compileMatch (buildOracle env) [scrut] rows)
  pure $ foldr
    (\(jid, vars, jbody) acc ->
        LetJoin jid [ Binder n Unrestricted t | (_, t, n) <- vars ] jbody acc)
    tree built
  where
    buildAltJoin (TAlt pat wh body) = do
      jid <- lift freshJoin
      triples <- mapM (\(v, t) -> do n <- bindFresh v; pure (v, t, n)) (clauseVars [pat])
      jbody <- withLocals [ (v, n) | (v, _, n) <- triples ]
                          (elabLocalDecls wh (elabK tk body))
      pure (jid, triples, jbody)

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
-- @entryModule@ is the entry module's name, used as the 'externKeyOf' default
-- for any global with no recorded origin.
-- @externKeys@ is the set of @(definingModule, name)@ keys of every value-level
-- prelude @extern@ in scope; each matching global is routed to 'APrim' (built
-- into 'ecPrims'), mirroring the whole-program 'elaborateModulesShared' path.
elaborateModule :: Text -> Set (Text, Text) -> Env -> [TypedDecl] -> CoreModule
elaborateModule entryModule externKeys env tds =
  runFresh $ do
    gpairs <- mapM (\t -> (,) t <$> freshName t) (Map.keys (envVars env))
    let globals = Map.fromList gpairs
        -- Each global whose @(definingModule, name)@ key is a known prelude
        -- @extern@ -> its canonical 'Name', so 'resolveVar' routes it to 'APrim'.
        -- The defining module comes from 'envVarOrigin', which DOES record the
        -- entry module's OWN names too (the loader keys them under the entry
        -- module). So a prelude-as-entry @extern@ keys correctly; the
        -- @entryModule@ default only fires for a name with no recorded origin,
        -- which the identity-derivation helper 'externKeyOf' then treats as
        -- entry-module-defined (in practice never, since the loader records
        -- own-module origins).
        ecPrims = Map.fromList
          [ (freshN, key)
          | (name, freshN) <- Map.toList globals
          , let key = externKeyOf entryModule env name
          , Set.member key externKeys ]
    binds <- mapM (\td -> runReaderT (elabTopBind globals td)
                                     (ElabCtx env Map.empty globals Map.empty Set.empty ecPrims))
                  (filter (not . isBodylessSig) tds)
    pure (CoreModule binds)

-- | Elaborate several modules into one CoreModule. Each top-level value-level
-- global is identified by its DEFINING module, keyed @(definingModule, name)@,
-- and given ONE canonical 'Name'. A module that defines a name shadowing one it
-- also imports (e.g. a user @state@ over @Std.Control.state@) therefore gets a
-- DISTINCT runtime binding from the imported one: each module's own references
-- resolve to its own definition, and cross-module references resolve to the
-- importee's. Without this, two modules defining the same bare name would
-- collapse onto a single 'Name' and the last 'TopBind' would silently win in
-- 'runModule's @gEnv@.
--
-- Each entry is @(definingModule, env, tds)@; @env@ is the module's own
-- post-import environment and @envVarOrigin env@ maps each visible name to the
-- module that defined it.
elaborateModulesShared :: [(Text, Env, [TypedDecl])] -> CoreModule
elaborateModulesShared mods =
  runFresh $ do
    -- Every (definingModule, name) pair across all modules. A name is keyed by
    -- the module that DEFINES it (via envVarOrigin), defaulting to the module
    -- whose env we are reading when no origin is recorded (a module's own
    -- freshly introduced names).
    let qualifiedKeys =
          [ externKeyOf modName env name
          | (modName, env, _) <- mods
          , name <- Map.keys (envVars env)
          ]
    -- Mint one Name per distinct (origin, name) key.
    gpairs <- mapM (\k -> (,) k <$> freshName (snd k))
                   (dedup qualifiedKeys)
    let globalByKey = Map.fromList gpairs
        -- Invert the extern resolution: each value-level prelude @extern@'s
        -- canonical 'Name' -> its @(definingModule, name)@ key. Built from the
        -- 'tdIsExtern'-marked decls (the typechecker's authority on what is an
        -- extern), keyed through 'globalByKey' by extern IDENTITY. A user binding
        -- merely HINTED an extern name has a distinct (origin, name) key, so it is
        -- never in this map and is never routed to 'APrim'.
        ecPrimsAll = Map.fromList
          [ (globalByKey Map.! k, k)
          | (modName, env, tds) <- mods, td <- tds, tdIsExtern td
          , let k = externKeyOf modName env (tdName td)
          , Map.member k globalByKey ]
    binds <- concat <$> mapM (elabOne globalByKey ecPrimsAll) mods
    pure (CoreModule binds)
  where
    dedup = Map.keys . Map.fromList . map (\k -> (k, ()))
    -- A module's view: each name it can see resolves to the canonical Name for
    -- (definingModule, name).
    elabOne globalByKey ecPrimsAll (modName, env, tds) =
      let globals = Map.fromList
            [ (name, globalByKey Map.! key)
            | name <- Map.keys (envVars env)
            , let key = externKeyOf modName env name
            ]
      in mapM (\td -> runReaderT (elabTopBind globals td)
                                 (ElabCtx env Map.empty globals Map.empty Set.empty ecPrimsAll))
              (filter (not . isBodylessSig) tds)

-- | The @(definingModule, name)@ identity key for a value-level global. The
-- defining module comes from 'envVarOrigin'; when no origin is recorded the
-- @defaultModule@ is used (the entry module for the single-module path, or the
-- module whose env we are reading for the whole-program path). This is the ONE
-- rule for deriving a global's identity key; all extern routing keys through it.
externKeyOf :: Text -> Env -> Text -> (Text, Text)
externKeyOf defaultModule env name =
  (Map.findWithDefault defaultModule name (envVarOrigin env), name)

-- ---------------------------------------------------------------------------
-- Public test seam

elaborateExprForTest :: Env -> TExpr -> Expr
elaborateExprForTest env e =
  runFresh (runReaderT (elabTail e) (ElabCtx env Map.empty Map.empty Map.empty Set.empty Map.empty))
