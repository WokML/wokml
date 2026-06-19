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
  , checkFutureAffine
  , isHandleType         -- exported for the slice-4d marker anchor test
  , isAffineCarrierType  -- exported for the slice-4d marker anchor test
  , freeVars             -- exported for IR.Elaborate's local-decl dependency sort
  ) where

import Data.Text (Text)
import qualified Data.Set as Set
import Data.Set (Set)

import Wok.IR.Multiplicity (Card (..), joinC, addC)
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
  { ctxResolve    :: ParamResolver
  , ctxSpan       :: SourceSpan
  , ctxName       :: Text
  , ctxHandlerArm :: Bool
    -- ^ True ONLY for the IMMEDIATE top-level check of (a) a handler arm body (the
    -- arm's answer expression), or (b) the tail of a clause body whose binding is
    -- a carrier PRODUCER (its declared result type is a 'Step'/'Suspension'; see
    -- 'checkCarriers' @resultIsCarrier@). Reset to False when 'check' recurses
    -- into children via 'recurse', so nested sub-expressions receive the normal
    -- check. This single-level flag exempts the DIRECT producer expression
    -- (e.g. @__coro_done v@ / @__coro_susp x k@ inside a Coro handler arm, or
    -- @__coro_resume s v@ as the body of @step@) from the inline-carrier escape
    -- rule: those saturated calls are the structural carrier constructors for the
    -- answer type, not propagations of an existing handle. Any deeper escapes
    -- (e.g. storing a carrier in a list) are still caught because the flag is
    -- False by the time 'recurse' reaches them.
  , ctxCarrierTys :: Set Text
    -- ^ Names of marked carrier tycons (@extern data@/@extern type@); the marker
    -- set consulted by 'isHandleType'/'isAffineCarrierType' (slice 4d).
  , ctxProducerExempt :: Bool
    -- ^ Whether the PRODUCER-THUNK exemption ('isProducerThunk' in 'check') is in
    -- effect. Origin-gated by the caller exactly like the clause-tail producer
    -- exemption ('resultIsCarrier'/@producerExempt@ in 'Infer.hs'): True only for
    -- Embedded (prelude) code, False for a UserFile. A user file therefore cannot
    -- write a bare @\\() -> Completed n@ fresh-carrier factory (rejected as a
    -- carrier escape, consistent with the direct @Completed n@ form); the
    -- prelude's @runConc@/@spawn@/@async@ producer thunks remain exempt.
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
--
-- @resultIsCarrier@ is True when the binding's DECLARED result type is itself an
-- affine carrier (a 'Step' or 'Suspension'): such a binding is a carrier
-- PRODUCER (e.g. @start@/@step@ return a 'Step'), so the TAIL of its clause body
-- is permitted to be an inline-produced carrier of that type. This is the
-- producer analogue of the handler-arm exemption ('ctxHandlerArm'): the carrier
-- is the function's structural answer, not a propagation of a captured handle.
-- The exemption is single-level — it is reset before descending into children
-- (via 'recurse'), so a carrier escaping into a list/tuple inside the body is
-- still caught.
checkCarriers
  :: Set Text -> ParamResolver -> Bool -> Bool -> SourceSpan -> Text
  -> [([TPat], TExpr)] -> Either TypeError ()
checkCarriers carrierTys resolve producerThunkExempt resultIsCarrier sp name clauses =
  mapM_ checkClause clauses
  where
    ctx = Ctx { ctxResolve = resolve, ctxSpan = sp, ctxName = name
              , ctxHandlerArm = False, ctxCarrierTys = carrierTys
              , ctxProducerExempt = producerThunkExempt }
    checkClause (pats, body) =
      let env0 = Env (Set.unions (map (handleBindersOfPat carrierTys) pats))
                     (Set.unions (map patVars pats))
      in check (ctx { ctxHandlerArm = resultIsCarrier }) env0 False body

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
  -- An INLINE-PRODUCED Future (a saturated call whose result type is a Future,
  -- e.g. @start producer@) is a second-class carrier that must not escape even
  -- when there are no carrier variables in scope. This fires in any non-allowed
  -- position EXCEPT the immediate top-level body of a handler arm (where the
  -- call IS the structural answer-type constructor for the handler, e.g.
  -- @__coro_done v@ / @__coro_susp x k@ inside 'start'). The 'ctxHandlerArm'
  -- flag is set to True only for that single level and is reset to False
  -- (via 'recurse') before any child expressions are checked, so nested
  -- escapes (e.g. @[start producer]@ inside an arm) are still caught.
  | isInlineFutureApp (ctxCarrierTys ctx) e, not allowed, not (ctxHandlerArm ctx) = err ctx
  -- A PRODUCER THUNK: a lambda whose result type is itself an affine carrier
  -- (e.g. @\\() -> start (asConc c)@ of type @() -> Step …@). Such a lambda is the
  -- structural carrier constructor demanded by a driver that must call @start@
  -- itself (the Haskell scheduler @driveConc@ has no global env, so the wok side
  -- hands it @start@-wrapped starter thunks). The lambda's IMMEDIATE body is the
  -- inline-produced carrier — the producer analogue of a handler arm / a
  -- Step-result clause tail — so it is exempted exactly like those. The exemption
  -- is single-level: 'recurse' (via the TLam case) checks the body with
  -- 'ctxHandlerArm' set so only the flat top of the body is exempt; nested
  -- escapes (a carrier stored in a list inside the body) still fire.
  | ctxProducerExempt ctx, isProducerThunk (ctxCarrierTys ctx) e =
      recurse (ctx { ctxHandlerArm = True }) env node
  | otherwise = recurse (ctx { ctxHandlerArm = False }) env node

-- | The value forms that carry a handle out of their position: a bare carrier
-- variable, a closure (lambda) whose free variables capture a handle, or a
-- /partial application/ whose result is itself a function (an arrow type) and
-- which captures a handle (a free variable in the carrier set). The last is a
-- closure just like a lambda — @peek c@ (with @peek : State U64 -> () -> U64@)
-- is a @() -> U64@ value that has closed over the handle @c@ — so it escapes for
-- the same reason and must be flagged identically.
--
-- Inline-produced Futures (saturated @TApp@ with Future result type) are NOT
-- handled here; they are caught by the separate 'isInlineFutureApp' guard in
-- 'check', which threads the 'ctxHandlerArm' flag to exempt the immediate bodies
-- of handler arms (the structural Future constructors).
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

-- | Is this a saturated call (@TApp@) whose result type is a Future? Such an
-- expression is an INLINE-PRODUCED Future — it is a second-class carrier value
-- even though it was never bound to a name and does not appear in the carrier
-- variable set. Typical example: @start producer@ at a return / list / tuple
-- position. This check is used alongside 'directlyEscapes' in 'check' to cover
-- the gap where no carrier variable is in scope (the Future is brand-new).
--
-- The @TApp@ restriction is intentional: handler-installation forms (@THandle@,
-- @TWithNamedH@) are the STRUCTURAL constructors of Futures and are never
-- carriers themselves; they are handled by the @_ -> False@ fallthrough in
-- 'directlyEscapes'. A @TVar@ / @TQVar@ bare reference to a Future variable is
-- already caught by 'directlyEscapes' via the carrier set. Only a saturated
-- call (a non-arrow @TApp@) needs this additional check.
isInlineFutureApp :: Set Text -> TExpr -> Bool
isInlineFutureApp carrierTys (Texp ty (TApp _ _)) = isAffineCarrierType carrierTys ty
isInlineFutureApp _          _                    = False

-- | Is this a PRODUCER THUNK — a lambda whose result type (after peeling its
-- parameters) is an affine carrier (a 'Step'/'Suspension')? Such a lambda is a
-- structural carrier constructor: a deferred @start@ that a driver must apply
-- itself. Its immediate body is therefore exempted from the inline-carrier
-- escape rule (see 'check'), the producer analogue of the handler-arm and
-- Step-result-clause exemptions. (A lambda that CAPTURES an in-scope handle is
-- still flagged separately by 'directlyEscapes' at its own position, so this
-- exemption does not loosen the handle-escape rule.)
--
-- ORIGIN-GATED. The 'check' caller consults this exemption ONLY when
-- 'ctxProducerExempt' is set, which the inference driver gates on Embedded
-- (prelude) origin — the same trust boundary as the clause-tail producer
-- exemption. A UserFile @\\() -> Completed n@ is therefore rejected as a carrier
-- escape (consistent with the direct @Completed n@ form), while the prelude's
-- @runConc@/@spawn@/@async@ starter thunks stay exempt.
isProducerThunk :: Set Text -> TExpr -> Bool
isProducerThunk carrierTys (Texp ty (TLam pats _)) =
  isAffineCarrierType carrierTys (peelArrowResults (length pats) ty)
isProducerThunk _ _ = False

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
          (pt : _) -> isHandleSlot (ctxCarrierTys ctx) pt
          []       -> False
    in do go True h
          sequence_ [ go (argAllowed i) a | (i, a) <- zip [0 ..] args ]

  -- A lambda: its params become local binders (handle-typed ones also carriers);
  -- the body is a non-allowed position. (A lambda VALUE that captures a handle
  -- and escapes is caught at the lambda's own position by its parent.)
  TLam pats body -> check ctx (bindPats (ctxCarrierTys ctx) env pats) False body

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
    let env' = bindDecls (ctxCarrierTys ctx) env decls
    in do mapM_ (checkDecl ctx env') decls
          check ctx env' False body

  -- The scrutinee is an ALLOWED position: scrutinizing is how a transparent
  -- affine carrier (a 'Step') is ELIMINATED. The carrier is consumed here, not
  -- carried outward; the alts are checked non-allowed, so nothing escapes
  -- through the arm bodies. (A bare 'Suspension' is never cased, so this does
  -- not loosen the suspension rule.) The affine consume-once accounting for the
  -- scrutiny lives in 'consumeCard' (the @TCase@ One rule).
  TCase scrut alts -> do
    go True scrut
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
  check ctx (bindPats (ctxCarrierTys ctx) env pats) True rhs

-- | Check a case alternative: the pattern's binders and any where-decl carriers
-- extend the environment; the body is non-allowed.
checkAlt :: Ctx -> Env -> TAlt CType -> Either TypeError ()
checkAlt ctx env (TAlt pat decls body) =
  let env0 = bindPats (ctxCarrierTys ctx) env [pat]
      env' = bindDecls (ctxCarrierTys ctx) env0 decls
  in do mapM_ (checkDecl ctx env') decls
        check ctx env' False body

-- | Check a handler arm. Op-arm patterns and the resume binder bind ordinary
-- values; the arm body is a non-allowed position.
--
-- The arm body is the STRUCTURAL answer-type constructor of the handler. For a
-- @Coro@ handler the arm bodies are @__coro_done v@ and @__coro_susp x k@, both
-- saturated @TApp@s that produce a @Future@ — but they ARE the answer, not an
-- escape. We set 'ctxHandlerArm' to @True@ for the immediate body check only.
-- 'check' resets it to @False@ before entering 'recurse', so only the flat top
-- level of the arm body is exempted; any nested escapes (e.g. @[start p]@ inside
-- an arm) still fire the inline-Future error.
checkArm :: Ctx -> Env -> THandlerArm CType -> Either TypeError ()
checkArm ctx env arm = case arm of
  TReturnArm pat body    -> check (ctx { ctxHandlerArm = True }) (bindPats (ctxCarrierTys ctx) env [pat]) False body
  TOpArm _ _ pats _ _ body -> check (ctx { ctxHandlerArm = True }) (bindPats (ctxCarrierTys ctx) env pats) False body
  TParamArm _ initE      -> check ctx env False initE

-- | Extend the environment with a pattern's binders: all names join @locals@;
-- handle-typed names also join @carriers@.
bindPats :: Set Text -> Env -> [TPat] -> Env
bindPats carrierTys env pats = env
  { envCarriers = Set.union (envCarriers env) (Set.unions (map (handleBindersOfPat carrierTys) pats))
  , envLocals   = Set.union (envLocals env)   (Set.unions (map patVars pats))
  }

-- | Extend the environment with a let/where group's binders: every bound name
-- joins @locals@; a name joins @carriers@ only when it actually carries a handle
-- outward, so a later escape THROUGH the name is caught. That is precisely:
--
--   * its (peeled) RESULT TYPE is a handle (@let c2 = cell@ — a handle alias), or
--   * its RHS is itself a direct-escape form: a bare carrier, or a handle-
--     capturing closure (@let f = \\x -> cell.set x@ — the closure is a carrier
--     even though its result type is a function, not a handle), or
--   * it is an EQUATION-FORM local function (a binding WITH parameters) whose
--     clause body closes over an in-scope carrier (@let f x = cell.set x@ — the
--     same closure as the lambda form, but its RHS is the body 'TPerformOn' and
--     its peeled result type is Unit, so neither of the two tests above catches
--     it). See 'functionCapturesHandle'.
--
-- It must NOT use a free-variable over-approximation for a NULLARY binding:
-- @let old = cell.get@ binds a plain @U64@ (a perform CONSUMES the handle and
-- returns a value), and @old@ references @cell@ in its RHS, so a free-var test
-- would wrongly mark @old@ a carrier and reject a later innocent use of @old@ in
-- a non-handle slot. The equation-form test is therefore restricted to bindings
-- that actually take parameters (closure values), leaving the nullary case to the
-- two precise tests above.
bindDecls :: Set Text -> Env -> [TLocalDecl CType] -> Env
bindDecls carrierTys env decls = env
  { envCarriers = Set.union (envCarriers env) (Set.fromList carrierNames)
  , envLocals   = Set.union (envLocals env)   (Set.fromList allNames)
  }
  where
    allNames = [ n | TLocalDecl n _ _ <- decls ]
    carrierNames =
      [ n
      | TLocalDecl n pats rhs <- decls
      , let inner = Set.union (envCarriers env)
                              (Set.unions (map (handleBindersOfPat carrierTys) pats))
      , directlyEscapes inner rhs
          || isHandleType carrierTys (peelArrowResults (length pats) (typeOf rhs))
          || functionCapturesHandle inner pats rhs
      ]
    typeOf (Texp t _) = t
    -- An equation-form local function (params present) whose clause body closes
    -- over an in-scope carrier: it is a handle-capturing closure value, the
    -- equation-form analogue of 'directlyEscapes's 'TLam' case (remove the params,
    -- intersect the body's free vars with the carriers). Nullary bindings are
    -- excluded so the @let old = cell.get@ over-approximation is NOT reintroduced.
    functionCapturesHandle carriers pats rhs =
      not (null pats)
        && let bound = Set.unions (map patVars pats)
               fvs   = freeVars rhs `Set.difference` bound
           in not (Set.null (Set.intersection fvs carriers))

-- | Is this a second-class HANDLE type — an effect-instance handle
-- @CTCon (TcEffect _) _@, or a MARKED carrier tycon (an @extern data@/@extern
-- type@, whose name is in @carrierTys@)? Both must not escape their scope.
isHandleType :: Set Text -> CType -> Bool
isHandleType _          (CTCon (TcEffect _) _) = True
isHandleType carrierTys (CTCon (TcUser n)   _) = Set.member n carrierTys
isHandleType _          _                       = False

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
isHandleSlot :: Set Text -> CType -> Bool
isHandleSlot carrierTys pt = isHandleType carrierTys pt || isHandleContinuation pt
  where
    isHandleContinuation (CTArr dom _ _) = isHandleType carrierTys dom
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
handleBindersOfPat :: Set Text -> TPat -> Set Text
handleBindersOfPat carrierTys (Tpat ty p) = case p of
  TPVar n
    | isHandleType carrierTys ty -> Set.singleton n
    | otherwise       -> Set.empty
  TPWild      -> Set.empty
  TPLitI _    -> Set.empty
  TPLitS _    -> Set.empty
  TPLitC _    -> Set.empty
  TPUnit      -> Set.empty
  TPTuple ps  -> Set.unions (map (handleBindersOfPat carrierTys) ps)
  TPList ps   -> Set.unions (map (handleBindersOfPat carrierTys) ps)
  TPCon _ ps  -> Set.unions (map (handleBindersOfPat carrierTys) ps)
  TPCons h t  -> Set.union (handleBindersOfPat carrierTys h) (handleBindersOfPat carrierTys t)
  TPAs n inner ->
    let rest = handleBindersOfPat carrierTys inner
    in if isHandleType carrierTys ty then Set.insert n rest else rest

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
  TOpArm _ _ pats res _ body ->
    (freeVars body `Set.difference` Set.unions (map patVars pats))
      `Set.difference` Set.singleton res
  TParamArm _ initE        -> freeVars initE

-- ---------------------------------------------------------------------------
-- Affine consumption bound on Futures (slice 4b, Task 5).
--
-- A coroutine 'Future' is consumed AT MOST ONCE, by @resume@ XOR @cancel@.
-- Reading it via @value@ is non-consuming (any number of times). Futures are
-- second-class (the carrier rule keeps them syntactically local), so this is a
-- LOCAL, post-inference analysis over the same frozen typed AST as
-- 'checkCarriers'.
--
-- It is a SIBLING pass to the carrier walk rather than an extension of it: the
-- carrier walk's job (and its @allowed@/positional plumbing) is escape, an
-- orthogonal concern; counting consuming uses with the {0,1,ω} cardinality
-- lattice reads far more clearly on its own, and reuses only the Suspension-binder
-- identification ('handleBindersOfPat' already classifies a marked-carrier binder).
-- We reuse the 'Card' lattice from "Wok.IR.Multiplicity" (@joinC@ for branch =
-- max, @addC@ for sequence = saturating sum) rather than reinventing it; that
-- pass is over ANF 'Expr', so we replicate ONLY the sequence/branch combination
-- here over the typed 'TExpr'.
--
-- For each Future-typed binding in a clause body, we compute the consuming-use
-- cardinality of that binding over the expression in whose SCOPE it lives, and
-- reject any binding that reaches 'Many'. Conservative: a consuming use whose
-- future argument is anything other than a bare reference to the binding (an
-- alias, a computed future, etc.) over-approximates to 'Many' (see
-- 'consumeCard'), so unanalyzable flow is rejected, consistent with the carrier
-- rule's locality.
-- ---------------------------------------------------------------------------

-- | The non-consuming reader registry, resolved by EXTERN IDENTITY. A Future
-- passed as an argument to a trusted reader is provably NOT consumed (it is only
-- read), so it contributes 'Zero'; everything else that takes a Future argument
-- is treated as a consumer (it MIGHT consume it), contributing 'One' — see
-- 'consumeApp'.
--
-- The registry is the set of prelude @extern@ reader prims (currently @value@).
-- Trust is by EXTERN IDENTITY, not by
-- name text: a callee is trusted only when the name is a reader AND it resolves,
-- at THIS module's scope, to the prelude extern — i.e. it is neither locally
-- shadowed (a @let value = …@) NOR redefined by this module at the top level (a
-- user @value : Future … -> …@). The Part 1 gate guarantees only the prelude can
-- mint an @extern@, so "imported reader name, not own-module-defined, not locally
-- bound" is exactly the prelude reader's identity. A user binding named @value@
-- is a regular (non-extern) function and is NOT trusted — it is treated as a
-- consumer.
--
-- @rdrShadows@ is the set of reader names this module REDEFINES at the top level
-- (passed in from inference); such a name is the module's own binding, not the
-- prelude extern, so it must not be trusted even at a free occurrence.
data ReaderTrust = ReaderTrust
  { rtReaders    :: Set Text   -- ^ the prelude extern reader names
  , rtShadows    :: Set Text   -- ^ reader names this module redefines at top level
  }

-- | The prelude extern reader names. The Step surface removed the @value@ reader
-- (you obtain a Suspension only by matching @Suspended x g@), so there are no
-- trusted prelude readers. The ReaderTrust machinery is retained (it is cheap and
-- the row plumbing still flows through it) but the trusted set is now empty.
preludeReaderNames :: Set Text
preludeReaderNames = Set.empty

-- | Check the affine consumption bound for one binding's clauses. Mirrors
-- 'checkCarriers': the clause params may themselves bind futures (a parameter of
-- Future type), so they seed the in-scope future set; the body is then walked,
-- and each future binding is checked against its scope as it is introduced.
--
-- @ownTopLevel@ is the set of names this module DEFINES at the top level; any
-- reader name in it is a user redefinition (not the prelude extern) and is NOT
-- trusted (it is treated as a consumer).
checkFutureAffine
  :: Set Text -> Set Text -> SourceSpan -> Text
  -> [([TPat], TExpr)] -> Either TypeError ()
checkFutureAffine carrierTys ownTopLevel sp name clauses = mapM_ checkClause clauses
  where
    trust = ReaderTrust preludeReaderNames
                        (Set.intersection preludeReaderNames ownTopLevel)
    checkClause (pats, body) =
      let seeded = Set.unions (map (futureBindersOfPat carrierTys) pats)
      in do
        -- Param-bound futures: their scope is the whole body.
        mapM_ (checkBinder body) (Set.toList seeded)
        walk carrierTys trust sp name body

    checkBinder scope fut
      | consumeCard trust fut scope == Many = Left (FutureConsumedTwice sp fut)
      | otherwise                            = Right ()

-- | Walk an expression looking for Future-binder INTRODUCTIONS. At each
-- introduction, the future's consumption over its scope is checked; the walk
-- then descends into all sub-expressions so nested introductions are reached.
-- (The per-binder card is computed independently over its scope, so this walk
-- only needs to FIND introductions, not thread any count.)
walk :: Set Text -> ReaderTrust -> SourceSpan -> Text -> TExpr -> Either TypeError ()
walk carrierTys trust sp name (Texp _ node) = case node of
  TLitI _      -> ok
  TLitS _      -> ok
  TLitC _      -> ok
  TUnit        -> ok
  TVar _       -> ok
  TCon _       -> ok
  TParenOp _   -> ok
  TQVar _ _    -> ok
  TProjCon _ _ -> ok

  TApp h args         -> walk carrierTys trust sp name h >> mapM_ (walk carrierTys trust sp name) args
  TLam pats body      -> introducedBy (Set.unions (map (futureBindersOfPat carrierTys) pats)) body
                           >> walk carrierTys trust sp name body
  TIf c a b           -> mapM_ (walk carrierTys trust sp name) [c, a, b]
  TTuple xs           -> mapM_ (walk carrierTys trust sp name) xs
  TList xs            -> mapM_ (walk carrierTys trust sp name) xs
  TProj e _           -> walk carrierTys trust sp name e
  TPerformOn recv _ _ -> walk carrierTys trust sp name recv
  TRecord _ fs        -> mapM_ (walk carrierTys trust sp name . snd) fs
  TRecordExt _ e fs   -> walk carrierTys trust sp name e >> mapM_ (walk carrierTys trust sp name . snd) fs

  -- A let group introduces futures: each Future-typed binding's scope is the
  -- (potentially mutually recursive) group body plus the RHSs of the group. We
  -- check consumption over the group body (where the binder is used downstream);
  -- then descend into RHSs and the body for nested introductions.
  TLet decls body ->
    let futs = futureBindersOfDecls carrierTys decls
    in do mapM_ (checkBinder body) (Set.toList futs)
          mapM_ (\(TLocalDecl _ _ rhs) -> walk carrierTys trust sp name rhs) decls
          walk carrierTys trust sp name body

  TCase scrut alts -> walk carrierTys trust sp name scrut >> mapM_ walkAlt alts

  THandle e arms ->
    walk carrierTys trust sp name e >> mapM_ walkArm arms

  TWithNamedH _ arms body ->
    mapM_ walkArm arms >> walk carrierTys trust sp name body
  where
    ok = Right ()
    checkBinder scope fut
      | consumeCard trust fut scope == Many = Left (FutureConsumedTwice sp fut)
      | otherwise                            = Right ()
    introducedBy futs scope =
      mapM_ (checkBinder scope) (Set.toList futs)
    walkAlt (TAlt pat decls altBody) =
      let futs = Set.union (futureBindersOfPat carrierTys pat) (futureBindersOfDecls carrierTys decls)
      in do mapM_ (checkBinder altBody) (Set.toList futs)
            mapM_ (\(TLocalDecl _ _ rhs) -> walk carrierTys trust sp name rhs) decls
            walk carrierTys trust sp name altBody
    walkArm arm = case arm of
      TReturnArm pat body    -> introducedBy (futureBindersOfPat carrierTys pat) body >> walk carrierTys trust sp name body
      TOpArm _ _ pats _ _ body -> introducedBy (Set.unions (map (futureBindersOfPat carrierTys) pats)) body
                                  >> walk carrierTys trust sp name body
      TParamArm _ initE      -> walk carrierTys trust sp name initE

-- | Consuming-use cardinality of the Future binding @s@ in an expression. Reuses
-- the {0,1,ω} lattice: 'addC' for sequence (both run), 'joinC' for branch (one
-- arm runs).
--
-- THE RULE (conservative, inter-procedurally sound without summaries). A Future
-- that appears as an ARGUMENT to ANY application contributes 'One' consumption,
-- EXCEPT when the callee is the trusted NON-consuming reader (@value@, by extern
-- identity), where it contributes 'Zero'. Rationale: the carrier rule lets
-- a future flow into a Future-typed parameter slot, so a helper @useit f =
-- resume f n@ called twice double-resumes; counting the future-as-argument as a
-- consumption catches that without an inter-procedural summary. Only @value@ is
-- provably non-consuming, so only it is whitelisted. @resume@/@cancel@ are
-- consumers like any other callee — they need no special case under this rule.
-- (Precise inter-procedural consumption — threading a future through a
-- non-consuming helper more than once, or recursion for chaining — is DEFERRED
-- with chaining, 4b′/4b″.)
--
-- ALIASING. A future is second-class, so the only way to make a second name for
-- it is @let t = s@ (or a case-decl binding @t = s@) — a binding whose RHS is a
-- bare reference to an in-scope alias of @s@. Such a @t@ joins the alias set for
-- that binding's scope, so a consuming use of @t@ counts against @s@. This is the
-- conservative closure the carrier rule's locality guarantees is sufficient:
-- the carrier rule already forbids a future flowing into any non-handle slot, so
-- it cannot be aliased through an arbitrary function — only through a direct
-- let/case rebinding, which is exactly what we track here.
--
-- CAPTURE. A future captured by a closure ('TLam') whose body mentions it is
-- over-approximated to 'Many' (it could be consumed any number of times when the
-- closure runs), unless a parameter shadows it.
consumeCard :: ReaderTrust -> Text -> TExpr -> Card
consumeCard trust s = go (Set.singleton s) Set.empty
  where
    -- @aliases@: the set of names currently referring to the same future as @s@.
    -- @locals@: the LOCAL binders (params/let/lambda/case/arm) in scope at this
    -- point. It is part of the reader's identity check: a @value@ that is locally
    -- bound (a shadow) is NOT the prelude extern reader, so it must count as a
    -- consumer (see 'isNonConsumingReader'). Combined with the not-redefined-at-
    -- top-level check ('rtShadows', threaded in from inference) and the Part 1
    -- gate (only the prelude can mint an @extern@), a FREE, non-redefined reader
    -- name resolves to the prelude extern reader by identity.
    go :: Set Text -> Set Text -> TExpr -> Card
    go aliases locals (Texp _ node) = case node of
      TLitI _      -> Zero
      TLitS _      -> Zero
      TLitC _      -> Zero
      TUnit        -> Zero
      TCon _       -> Zero
      TParenOp _   -> Zero
      TProjCon _ _ -> Zero

      -- A bare reference, NOT the first arg of a consuming call (that is handled
      -- in TApp): a non-consuming occurrence (a value read, an alias RHS already
      -- accounted for at its binding, etc.). Scores Zero.
      TVar _       -> Zero
      TQVar _ _    -> Zero

      TApp h args -> consumeApp aliases locals h args

      TLam pats body
        | not (Set.null (Set.intersection aliases (Set.unions (map patVars pats)))) -> Zero
        | not (Set.null (Set.intersection aliases (freeVars body)))                 -> Many
        | otherwise                                                                  -> Zero

      TIf c a b   -> addC (go aliases locals c) (joinC (go aliases locals a) (go aliases locals b))
      TTuple xs   -> foldr (addC . go aliases locals) Zero xs
      TList xs    -> foldr (addC . go aliases locals) Zero xs
      TProj e _   -> go aliases locals e
      TPerformOn recv _ _ -> go aliases locals recv
      TRecord _ fs        -> foldr (addC . go aliases locals . snd) Zero fs
      TRecordExt _ e fs   -> addC (go aliases locals e) (foldr (addC . go aliases locals . snd) Zero fs)

      -- A let group may bind new aliases of the future (a binding @t = <alias>@).
      -- The new aliases are in scope of the body (and, conservatively, of the
      -- group's RHSs, since the group is potentially recursive). Shadowing
      -- removes a name from the alias set; every bound name joins @locals@ (so a
      -- locally-bound @value@ is no longer the trusted reader).
      TLet decls body ->
        let aliases' = extendAliases aliases decls
            locals'  = Set.union locals (Set.fromList [ n | TLocalDecl n _ _ <- decls ])
            rhss = foldr (addC . declCard aliases' locals') Zero decls
        in addC rhss (go aliases' locals' body)

      -- A @case@ CONSUMES its scrutinee when the scrutinee is a bare alias of
      -- the tracked affine carrier. This is how a 'Step' is eliminated:
      -- scrutinizing it once is fine (One); scrutinizing the same binder in two
      -- @case@s is a double-consume (Many, via addC across the two cases at
      -- their common parent). A non-bare scrutinee recurses ordinarily (its
      -- uses are counted as before).
      TCase scrut alts ->
        let scrutCard
              | bareAlias aliases scrut = One
              | otherwise               = go aliases locals scrut
        in addC scrutCard (foldr (joinC . altCard aliases locals) Zero alts)

      THandle e arms ->
        addC (go aliases locals e) (foldr (addC . armCard aliases locals) Zero arms)

      TWithNamedH _ arms body ->
        addC (foldr (addC . armCard aliases locals) Zero arms) (go aliases locals body)

    -- An application @h a1 .. an@. Each argument that is a bare reference to an
    -- alias of the future is a CONSUMPTION (One) — UNLESS the callee is the
    -- trusted non-consuming reader (the prelude @extern value@, by identity: a
    -- free reader name not redefined by this module), where it contributes Zero.
    -- Arguments that are not bare future aliases recurse ordinarily (they may
    -- contain further uses), and so does the head.
    consumeApp aliases locals h args =
      let headCard = go aliases locals h
          reader   = isNonConsumingReader locals h
          argCard a
            | bareAlias aliases a = if reader then Zero else One
            | otherwise           = go aliases locals a
      in addC headCard (foldr (addC . argCard) Zero args)

    -- Is the callee the prelude extern reader, by IDENTITY? The name must be a
    -- reader name ('rtReaders'), AND not locally bound (a @let value = …@ shadow
    -- is the local binding, not the extern), AND not redefined by this module at
    -- the top level (@rtShadows@ — a user @value : Future … -> …@ is a regular,
    -- non-extern binding). The Part 1 gate guarantees only the prelude can mint an
    -- @extern@, so a reader name that survives both checks resolves to the prelude
    -- extern reader. Anything else falls through to the default consumer treatment.
    isNonConsumingReader locals (Texp _ hf) = case hf of
      TVar n     -> trusted n locals
      TQVar n _  -> trusted n locals
      TParenOp n -> trusted n locals
      _          -> False
    trusted n locals =
      Set.member n (rtReaders trust)
        && not (Set.member n locals)
        && not (Set.member n (rtShadows trust))

    -- A bare reference to an alias of the future (used to detect @let t = s@).
    bareAlias aliases (Texp _ a) = case a of
      TVar n    -> Set.member n aliases
      TQVar n _ -> Set.member n aliases
      _         -> False

    -- Extend the alias set with any nullary binding whose RHS is a bare alias.
    extendAliases aliases decls = foldr add aliases decls
      where add (TLocalDecl n pats rhs) acc
              | null pats && bareAlias aliases rhs = Set.insert n acc
              | otherwise                          = acc

    declCard aliases locals (TLocalDecl _ pats rhs)
      | not (Set.null (Set.intersection aliases (Set.unions (map patVars pats)))) = Zero
      | otherwise = go aliases (Set.union locals (Set.unions (map patVars pats))) rhs

    altCard aliases locals (TAlt pat decls body)
      | not (Set.null (Set.intersection aliases (patVars pat))) = Zero
      | otherwise =
          let aliases' = extendAliases aliases decls
              locals'  = Set.unions [ locals, patVars pat
                                    , Set.fromList [ n | TLocalDecl n _ _ <- decls ] ]
              rhss = foldr (addC . declCard aliases' locals') Zero decls
          in addC rhss (go aliases' locals' body)

    armCard aliases locals arm = case arm of
      TReturnArm pat body
        | not (Set.null (Set.intersection aliases (patVars pat))) -> Zero
        | otherwise -> go aliases (Set.union locals (patVars pat)) body
      TOpArm _ _ pats _ _ body
        | not (Set.null (Set.intersection aliases (Set.unions (map patVars pats)))) -> Zero
        | otherwise -> go aliases (Set.union locals (Set.unions (map patVars pats))) body
      TParamArm _ initE -> go aliases locals initE

-- | The affine-carrier-typed binders introduced by a pattern (a marked carrier
-- tycon binder), reusing the same type predicate ('isAffineCarrierType') the
-- carrier rule uses. Any marked carrier tycon qualifies (the prelude's
-- 'Suspension'/'Step' are the canonical instances).
futureBindersOfPat :: Set Text -> TPat -> Set Text
futureBindersOfPat carrierTys (Tpat ty p) = case p of
  TPVar n
    | isAffineCarrierType carrierTys ty -> Set.singleton n
    | otherwise       -> Set.empty
  TPWild      -> Set.empty
  TPLitI _    -> Set.empty
  TPLitS _    -> Set.empty
  TPLitC _    -> Set.empty
  TPUnit      -> Set.empty
  TPTuple ps  -> Set.unions (map (futureBindersOfPat carrierTys) ps)
  TPList ps   -> Set.unions (map (futureBindersOfPat carrierTys) ps)
  TPCon _ ps  -> Set.unions (map (futureBindersOfPat carrierTys) ps)
  TPCons h t  -> Set.union (futureBindersOfPat carrierTys h) (futureBindersOfPat carrierTys t)
  TPAs n inner ->
    let rest = futureBindersOfPat carrierTys inner
    in if isAffineCarrierType carrierTys ty then Set.insert n rest else rest

-- | The affine-carrier-typed binders introduced by a let/where group: a binding
-- whose (peeled) result type is a marked carrier tycon, or whose pattern binds
-- one.
futureBindersOfDecls :: Set Text -> [TLocalDecl CType] -> Set Text
futureBindersOfDecls carrierTys decls = Set.unions
  [ binders
  | TLocalDecl n pats rhs <- decls
  , let resultIsFuture = null pats && isAffineCarrierType carrierTys (typeOf rhs)
        patFuts = Set.unions (map (futureBindersOfPat carrierTys) pats)
        binders = (if resultIsFuture then Set.singleton n else Set.empty)
                    `Set.union` patFuts
  ]
  where typeOf (Texp t _) = t

-- | Is this an AFFINE carrier type — a MARKED carrier tycon (consume-once)?
-- A 'Suspension' is consumed when passed as an argument; a 'Step' is consumed
-- when it is the SCRUTINEE of a @case@. Effect-instance handles are carriers but
-- are NOT subject to the consumption bound, so they are excluded here.
isAffineCarrierType :: Set Text -> CType -> Bool
isAffineCarrierType carrierTys (CTCon (TcUser n) _) = Set.member n carrierTys
isAffineCarrierType _          _                     = False
