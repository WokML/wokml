-- | The carrier rule: a second-class escape check for named effect instances
-- (design §4.3). It runs AFTER inference, over the frozen typed AST, because
-- handle-ness is read off types.
--
-- A /handle binder/ is any binder whose type is an effect-instance handle type
-- @CTCon (TcEffect _) _@ (introduced by Task 3). A /carrier/ is any expression
-- whose free variables include an in-scope handle binder (the handle itself, or
-- a closure / value that captures one).
--
-- Rule: a carrier may appear ONLY as
--   1. the receiver of a named perform (@x.op@ — the 'TPerformOn' instance), or
--   2. an argument passed into an application slot whose corresponding parameter
--      type is itself a handle type @CTCon (TcEffect _) _@, or a runner
--      /continuation/ slot @Handle -> a@ (see 'isHandleSlot').
-- Anywhere else — returned, stored in a constructor/record/tuple, put in a list,
-- or captured by a closure that itself escapes — is an error.
--
-- Soundness note. Checking "is it an application argument" is not enough: a
-- handle passed to a /polymorphic/ parameter escapes (@id count : State U64@
-- returns the handle). So condition 2 verifies the callee's DECLARED parameter
-- type at that position is a concrete handle type, never a type variable
-- (see 'headParamTypes' for the top-level-vs-local treatment). The rule is
-- deliberately conservative (it may reject some safe programs) but never accepts
-- an escape; the one documented permissiveness is the runner-continuation slot
-- ('isHandleSlot'), needed so a NESTED named @with@ desugar type-checks.
--
-- The analysis is a single bounded pass: free-variable computation is one finite
-- recursion; the in-scope handle-binder set is finite and lexically scoped; no
-- fixpoint.
module Wok.TypeChecking.Carrier
  ( checkCarriers
  ) where

import Data.Text (Text)
import qualified Data.Set as Set
import Data.Set (Set)

import Wok.TypeChecking.Error (TypeError (..), SourceSpan)
import Wok.TypeChecking.Types (CType (..), TyCon (..))
import Wok.TypeChecking.Typed
  ( Texp (..), TexpF (..)
  , Tpat (..), TpatF (..)
  , TAlt (..), THandlerArm (..), TLocalDecl (..)
  , TExpr, TPat
  )

-- | Resolve a CALLEE name (the head of an application) to its DECLARED parameter
-- types — the param types from the callee's generalised scheme, where a
-- polymorphic parameter is a @CTGen@, NOT a concrete type. This is the
-- load-bearing distinction for soundness on TOP-LEVEL callees: at a call site the
-- frozen typed AST has monomorphised every type, so a polymorphic @id : a -> a@
-- applied to a handle reads (at that site) as @State U64 -> State U64@ — its
-- instantiated param looks like a handle even though it is really a type
-- variable. Reading the DECLARED (generic) param off the scheme distinguishes a
-- genuine handle-typed parameter (a concrete @CTCon (TcEffect _) _@) from a
-- polymorphic slot a handle merely flowed into (a @CTGen@). 'Nothing' for an
-- unknown name; the check then treats that callee's slots conservatively.
type ParamResolver = Text -> Maybe [CType]

-- | The invariant context threaded through the walk.
data Ctx = Ctx
  { ctxResolve :: ParamResolver
  , ctxSpan    :: SourceSpan
  , ctxName    :: Text
  }

-- | The per-position mutable state threaded through the walk.
data Env = Env
  { envCarriers :: Set Text   -- ^ in-scope carrier binders (handles + aliases)
  , envLocals   :: Set Text   -- ^ in-scope LOCAL binder names (params/let/lambda)
  }

err :: Ctx -> Either TypeError a
err c = Left (CarrierEscape (ctxSpan c) (ctxName c))

-- | Check one binding's clauses. The clause params bind handle binders (a param
-- of handle type), so they seed the in-scope carrier set; the body is then
-- walked. The 'SourceSpan' (the binding's position) and name carry the
-- diagnostic, since the typed AST has no per-node spans. Returns the first
-- violation, if any.
checkCarriers
  :: ParamResolver -> SourceSpan -> Text -> [([TPat], TExpr)] -> Either TypeError ()
checkCarriers resolve sp name clauses = mapM_ checkClause clauses
  where
    ctx = Ctx resolve sp name
    checkClause (pats, body) =
      let env0 = Env (Set.unions (map handleBindersOfPat pats))
                     (Set.unions (map patVars pats))
      in check ctx env0 False body

-- | Walk an expression. @allowed@ says whether THIS position may host an escaping
-- carrier (a perform receiver, a handle-typed argument slot, an application head,
-- or a tracked binding RHS).
check :: Ctx -> Env -> Bool -> TExpr -> Either TypeError ()
check ctx env allowed e@(Texp _ node)
  -- A node DIRECTLY escapes a handle when it is itself a value form that carries
  -- a handle outward: a bare carrier variable (the handle, or a name aliasing
  -- one), or a closure that captures a handle. Structural/compound nodes (App,
  -- Let, If, Case, Tuple, List, Record, perform, ...) never escape a handle by
  -- themselves — their problematic CHILDREN are caught positionally by the
  -- recursion below. So only the direct-escape forms are checked against
  -- @allowed@; everything else simply recurses.
  | directlyEscapes (envCarriers env) e, not allowed = err ctx
  | otherwise = recurse ctx env node

-- | The value forms that carry a handle out of their position: a bare carrier
-- variable, a closure (lambda) whose free variables capture a handle, or a
-- /partial application/ whose result is itself a function (an arrow type) and
-- which captures a handle (a free variable in the carrier set). The last is a
-- closure just like a lambda — @peek c@ (with @peek : State U64 -> () -> U64@)
-- is a @() -> U64@ value that has closed over the handle @c@ — so it escapes for
-- the same reason and must be flagged identically.
directlyEscapes :: Set Text -> TExpr -> Bool
directlyEscapes carriers e@(Texp ty node) = case node of
  TVar n     -> Set.member n carriers
  TQVar n _  -> Set.member n carriers
  TParenOp n -> Set.member n carriers
  TLam pats body ->
    let bound = Set.unions (map patVars pats)
        fvs   = freeVars body `Set.difference` bound
    in not (Set.null (Set.intersection fvs carriers))
  -- A partial application capturing a handle: its (per-node) result type is an
  -- arrow, so it is an uncalled closure, and it references an in-scope handle.
  TApp _ _ -> capturesHandleClosure carriers ty e
  _ -> False

-- | Is this node a handle-capturing closure VALUE — i.e. a partial application
-- whose per-node type is an arrow and whose free variables include an in-scope
-- handle? Such a value can be returned/stored and CALLED after the handler is
-- gone, exactly like an escaping lambda. (A non-arrow application is a saturated
-- call that has consumed the handle and produced a value — not a carrier.)
capturesHandleClosure :: Set Text -> CType -> TExpr -> Bool
capturesHandleClosure carriers ty e = case ty of
  CTArr {} -> not (Set.null (Set.intersection (freeVars e) carriers))
  _        -> False

-- | Recurse into a node's children, setting each child's @allowed@ flag and
-- extending the environment where a binder is introduced.
recurse :: Ctx -> Env -> TexpF CType -> Either TypeError ()
recurse ctx env node = case node of
  TLitI _      -> ok
  TLitS _      -> ok
  TLitC _      -> ok
  TUnit        -> ok
  TVar _       -> ok
  TCon _       -> ok
  TParenOp _   -> ok
  TQVar _ _    -> ok
  TProjCon _ _ -> ok

  -- Perform receiver (condition 1): the receiver slot permits a carrier.
  TPerformOn recv _ _ -> go True recv

  -- Application: the head is consumed (allowed); each argument's allowance is
  -- condition 2 — the callee's parameter type at that position is a concrete
  -- handle type. We read the param types differently for top-level vs local
  -- callees (see 'headParamTypes') so a polymorphic top-level slot a handle
  -- merely flowed into is NOT mistaken for a handle slot.
  TApp h args ->
    let paramTys = headParamTypes ctx env h
        argAllowed i = case drop i paramTys of
          (pt : _) -> isHandleSlot pt
          []       -> False
    in do go True h
          sequence_ [ go (argAllowed i) a | (i, a) <- zip [0 ..] args ]

  -- A lambda: its params become local binders (handle-typed ones also carriers);
  -- the body is a non-allowed position. (A lambda VALUE that captures a handle
  -- and escapes is caught at the lambda's own position by its parent.)
  TLam pats body -> check ctx (bindPats env pats) False body

  TIf c a b -> mapM_ (go False) [c, a, b]
  TTuple xs -> mapM_ (go False) xs
  TList xs  -> mapM_ (go False) xs
  TProj e _ -> go False e

  TRecord _ fs        -> mapM_ (go False . snd) fs
  TRecordExt _ e fs   -> go False e >> mapM_ (go False . snd) fs

  -- let: a binding RHS is a tracked position (allowed) — binding a carrier to a
  -- name does not let it escape; instead the name joins the carrier set, so any
  -- later escape THROUGH the name is caught. Then the body is checked.
  TLet decls body ->
    let env' = bindDecls env decls
    in do mapM_ (checkDecl ctx env') decls
          check ctx env' False body

  TCase scrut alts -> do
    go False scrut
    mapM_ (checkAlt ctx env) alts

  -- A handler installation: the body and arms are non-allowed positions.
  THandle e arms ->
    go False e >> mapM_ (checkArm ctx env) arms

  -- Named primitive handler: @self@ is the instance handle this handler mints,
  -- so it is a handle binder in the body's (and arms') scope.
  TWithNamedH self arms body ->
    let env' = env { envCarriers = Set.insert self (envCarriers env)
                   , envLocals   = Set.insert self (envLocals env) }
    in mapM_ (checkArm ctx env') arms >> check ctx env' False body
  where
    ok     = Right ()
    go a e = check ctx env a e

-- | The parameter types to consult for an application's head.
--
-- For a TOP-LEVEL / constructor head (a name NOT in the local scope), read the
-- DECLARED params off its scheme (via the resolver): a polymorphic slot is a
-- @CTGen@, never a handle, so @id count@ is correctly rejected.
--
-- For a LOCAL head (a binder of THIS binding — a parameter, let-, lambda-, or
-- case-bound name), read the param types off the head node's monomorphised arrow
-- type. This is sound because a local callee's body is checked in the SAME pass:
-- if it returned a handle it received, the carrier rule would already have fired
-- at that local's definition. It is what lets a runner @state i c = … c self@
-- pass @self@ into @c : State s -> a@ (a genuine handle-typed continuation).
headParamTypes :: Ctx -> Env -> TExpr -> [CType]
headParamTypes ctx env (Texp hTy hf) = case hf of
  TVar n     -> pick n
  TQVar n _  -> pick n
  TParenOp n -> pick n
  TCon n     -> maybe [] id (ctxResolve ctx n)
  _          -> arrowParamTypes hTy   -- a computed callee: use the call-site arrow
  where
    pick n
      | Set.member n (envLocals env) = arrowParamTypes hTy
      | otherwise                    = maybe [] id (ctxResolve ctx n)

-- | Check a local decl. Its params bind handle binders for the RHS; the RHS is a
-- tracked (allowed) position.
checkDecl :: Ctx -> Env -> TLocalDecl CType -> Either TypeError ()
checkDecl ctx env (TLocalDecl _ pats rhs) =
  check ctx (bindPats env pats) True rhs

-- | Check a case alternative: the pattern's binders and any where-decl carriers
-- extend the environment; the body is non-allowed.
checkAlt :: Ctx -> Env -> TAlt CType -> Either TypeError ()
checkAlt ctx env (TAlt pat decls body) =
  let env0 = bindPats env [pat]
      env' = bindDecls env0 decls
  in do mapM_ (checkDecl ctx env') decls
        check ctx env' False body

-- | Check a handler arm. Op-arm patterns and the resume binder bind ordinary
-- values; the arm body is a non-allowed position.
checkArm :: Ctx -> Env -> THandlerArm CType -> Either TypeError ()
checkArm ctx env arm = case arm of
  TReturnArm pat body    -> check ctx (bindPats env [pat]) False body
  TOpArm _ _ pats _ body -> check ctx (bindPats env pats) False body
  TParamArm _ initE      -> check ctx env False initE

-- | Extend the environment with a pattern's binders: all names join @locals@;
-- handle-typed names also join @carriers@.
bindPats :: Env -> [TPat] -> Env
bindPats env pats = env
  { envCarriers = Set.union (envCarriers env) (Set.unions (map handleBindersOfPat pats))
  , envLocals   = Set.union (envLocals env)   (Set.unions (map patVars pats))
  }

-- | Extend the environment with a let/where group's binders: every bound name
-- joins @locals@; a name joins @carriers@ only when it actually carries a handle
-- outward, so a later escape THROUGH the name is caught. That is precisely:
--
--   * its (peeled) RESULT TYPE is a handle (@let c2 = cell@ — a handle alias), or
--   * its RHS is itself a direct-escape form: a bare carrier, or a handle-
--     capturing closure (@let f = \\x -> cell.set x@ — the closure is a carrier
--     even though its result type is a function, not a handle).
--
-- It must NOT use a free-variable over-approximation: @let old = cell.get@ binds
-- a plain @U64@ (a perform CONSUMES the handle and returns a value), and @old@
-- references @cell@ in its RHS, so a free-var test would wrongly mark @old@ a
-- carrier and reject a later innocent use of @old@ in a non-handle slot.
bindDecls :: Env -> [TLocalDecl CType] -> Env
bindDecls env decls = env
  { envCarriers = Set.union (envCarriers env) (Set.fromList carrierNames)
  , envLocals   = Set.union (envLocals env)   (Set.fromList allNames)
  }
  where
    allNames = [ n | TLocalDecl n _ _ <- decls ]
    carrierNames =
      [ n
      | TLocalDecl n pats rhs <- decls
      , let inner = Set.union (envCarriers env)
                              (Set.unions (map handleBindersOfPat pats))
      , directlyEscapes inner rhs
          || isHandleType (peelArrowResults (length pats) (typeOf rhs))
      ]
    typeOf (Texp t _) = t

-- | Is this an effect-instance handle type?
isHandleType :: CType -> Bool
isHandleType (CTCon (TcEffect _) _) = True
isHandleType _                       = False

-- | A parameter slot into which a carrier may be passed (condition 2, extended):
--
--   * a concrete handle type @State U64@ — pass a handle to a handle-typed
--     parameter (the @prog count total@ case); or
--   * a /handler continuation/ — an arrow whose DOMAIN is a handle type, e.g. a
--     runner's thunk @State s -> a@. A closure that captures enclosing handles
--     may be passed here: this is exactly the desugar of a NESTED named @with@
--     (@with count … with total … body@ becomes @state 0 (\\count -> state 0
--     (\\total -> body))@, where the inner continuation captures @count@). The
--     runner invokes its continuation locally and returns its (generic) result,
--     so the captured handle does not escape through it. This is a deliberate,
--     documented allowance for the runner-continuation shape (slightly
--     permissive: a contrived callee of type @(Handle -> a) -> (Handle -> a)@
--     that returned its argument is not separately re-checked here).
isHandleSlot :: CType -> Bool
isHandleSlot pt = isHandleType pt || isHandleContinuation pt
  where
    isHandleContinuation (CTArr dom _ _) = isHandleType dom
    isHandleContinuation _               = False

-- | The parameter types of a (curried) arrow type, in order. A non-arrow is [].
arrowParamTypes :: CType -> [CType]
arrowParamTypes (CTArr a _ b) = a : arrowParamTypes b
arrowParamTypes _             = []

-- | Peel @n@ arrow results off a type (the result type after applying @n@ args).
peelArrowResults :: Int -> CType -> CType
peelArrowResults 0 t = t
peelArrowResults n (CTArr _ _ b) = peelArrowResults (n - 1) b
peelArrowResults _ t = t

-- | The handle binders introduced by a pattern: any binder (a @TPVar@ or the
-- whole-value name of a @TPAs@) whose annotated type is a handle type.
handleBindersOfPat :: TPat -> Set Text
handleBindersOfPat (Tpat ty p) = case p of
  TPVar n
    | isHandleType ty -> Set.singleton n
    | otherwise       -> Set.empty
  TPWild      -> Set.empty
  TPLitI _    -> Set.empty
  TPLitS _    -> Set.empty
  TPLitC _    -> Set.empty
  TPUnit      -> Set.empty
  TPTuple ps  -> Set.unions (map handleBindersOfPat ps)
  TPList ps   -> Set.unions (map handleBindersOfPat ps)
  TPCon _ ps  -> Set.unions (map handleBindersOfPat ps)
  TPCons h t  -> Set.union (handleBindersOfPat h) (handleBindersOfPat t)
  TPAs n inner ->
    let rest = handleBindersOfPat inner
    in if isHandleType ty then Set.insert n rest else rest

-- | The names bound by a pattern (all of them, regardless of type), for the
-- free-variable computation's binder removal.
patVars :: TPat -> Set Text
patVars (Tpat _ p) = case p of
  TPVar n      -> Set.singleton n
  TPWild       -> Set.empty
  TPLitI _     -> Set.empty
  TPLitS _     -> Set.empty
  TPLitC _     -> Set.empty
  TPUnit       -> Set.empty
  TPTuple ps   -> Set.unions (map patVars ps)
  TPList ps    -> Set.unions (map patVars ps)
  TPCon _ ps   -> Set.unions (map patVars ps)
  TPCons h t   -> Set.union (patVars h) (patVars t)
  TPAs n inner -> Set.insert n (patVars inner)

-- | Free term variables of a typed expression. A standard finite recursion that
-- removes binders introduced by lambdas, lets, cases, and handler arms.
freeVars :: TExpr -> Set Text
freeVars (Texp _ node) = case node of
  TLitI _      -> Set.empty
  TLitS _      -> Set.empty
  TLitC _      -> Set.empty
  TUnit        -> Set.empty
  TVar n       -> Set.singleton n
  TCon _       -> Set.empty
  TParenOp _   -> Set.empty
  TQVar n _    -> Set.singleton n
  TProjCon _ _ -> Set.empty
  TApp h xs    -> Set.unions (freeVars h : map freeVars xs)
  TLam pats b  -> freeVars b `Set.difference` Set.unions (map patVars pats)
  TIf a b c    -> Set.unions [freeVars a, freeVars b, freeVars c]
  TTuple xs    -> Set.unions (map freeVars xs)
  TList xs     -> Set.unions (map freeVars xs)
  TProj e _    -> freeVars e
  TPerformOn recv _ _ -> freeVars recv
  TRecord _ fs        -> Set.unions (map (freeVars . snd) fs)
  TRecordExt _ e fs   -> Set.unions (freeVars e : map (freeVars . snd) fs)
  TLet decls body     ->
    -- A let group is (potentially) mutually recursive: every bound name is in
    -- scope of every RHS and the body. Remove the whole bound set.
    let bound = Set.fromList [ n | TLocalDecl n _ _ <- decls ]
        rhsFvs = Set.unions [ freeVars rhs `Set.difference` Set.unions (map patVars ps)
                            | TLocalDecl _ ps rhs <- decls ]
    in (Set.union rhsFvs (freeVars body)) `Set.difference` bound
  TCase scrut alts ->
    Set.union (freeVars scrut) (Set.unions (map freeVarsAlt alts))
  THandle e arms ->
    Set.union (freeVars e) (Set.unions (map freeVarsArm arms))
  TWithNamedH self arms body ->
    let inner = Set.union (freeVars body) (Set.unions (map freeVarsArm arms))
    in Set.delete self inner

freeVarsAlt :: TAlt CType -> Set Text
freeVarsAlt (TAlt pat decls body) =
  let bound = Set.union (patVars pat)
                        (Set.fromList [ n | TLocalDecl n _ _ <- decls ])
      rhsFvs = Set.unions [ freeVars rhs `Set.difference` Set.unions (map patVars ps)
                          | TLocalDecl _ ps rhs <- decls ]
  in Set.union rhsFvs (freeVars body) `Set.difference` bound

freeVarsArm :: THandlerArm CType -> Set Text
freeVarsArm arm = case arm of
  TReturnArm pat body      -> freeVars body `Set.difference` patVars pat
  TOpArm _ _ pats res body ->
    (freeVars body `Set.difference` Set.unions (map patVars pats))
      `Set.difference` Set.singleton res
  TParamArm _ initE        -> freeVars initE
