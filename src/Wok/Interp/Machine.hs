module Wok.Interp.Machine
  ( step
  , run
  , enter
  , evalExprWith
  , runModule
  ) where

import qualified Data.Map.Strict as Map
import qualified Data.Map.Lazy as MapL
import Data.Text (Text)
import qualified Data.Text as Tx
import Wok.IR.Anf
  ( Alt (..), Atom (..), Binder (..), CoreModule (..), Expr (..), Handler (..)
  , OpArm (..), Rhs (..), TopBind (..) )
import Wok.IR.Name (JoinId (..), Unique (..), nameHint, nameUniq)
import Wok.Interp.Prim (primTable)
import Wok.Interp.Value

-- | Single small-step. Halts on Return into KDone.
step :: PrimTable -> Config -> Either RuntimeError Step
step _     (Return v KDone) = Right (Done v)
step prims cfg              = More <$> transition prims cfg

-- | The non-halting transition: always yields the next Config.
transition :: PrimTable -> Config -> Either RuntimeError Config
transition prims (Return v k)      = returnTo prims v k
transition prims (Eval expr sc k)  = evalExpr prims expr sc k

-- | Deliver a value to a continuation frame.
returnTo :: PrimTable -> Value -> Kont -> Either RuntimeError Config
returnTo _     _ KDone               = Left (PrimError (Tx.pack "internal: returnTo KDone"))
returnTo _     v (KLet b body sc k)  =
  Right (Eval body sc { scEnv = bindBinder b v (scEnv sc) } k)
returnTo prims v (KApp args k)       = enter prims v args k
returnTo _     v (KHandle h _ hsc k) =
  -- Normal completion of a handled computation: run the return arm.
  let (rb, rbody) = hReturn h
  in Right (Eval rbody hsc { scEnv = bindBinder rb v (scEnv hsc) } k)

evalExpr :: PrimTable -> Expr -> Scope -> Kont -> Either RuntimeError Config
evalExpr prims expr sc k = case expr of
  Ret a -> do
    v <- resolveAtom prims sc a
    Right (Return v k)

  Let b rhs body -> evalRhs prims b rhs body sc k

  Case a alts -> do
    v <- resolveAtom prims sc a
    matchAlts v alts sc k

  LetRec defs body ->
    -- Tie the recursive knot: each closure captures the post-binding env'.
    -- env' is self-referential; VClosure's lazy env field keeps this productive.
    let env' = foldr addDef (scEnv sc) defs
        addDef (b, ps, bdy) e = Map.insert (nameUniq (bndName b)) (VClosure env' ps bdy) e
    in Right (Eval body sc { scEnv = env' } k)

  LetJoin j ps jb body ->
    let jp = JoinPoint sc ps jb k
    in Right (Eval body sc { scJoins = Map.insert j jp (scJoins sc) } k)

  Jump j args -> do
    vs <- mapM (resolveAtom prims sc) args
    case Map.lookup j (scJoins sc) of
      Nothing -> Left (UnboundVar (renderJoin j))
      Just (JoinPoint jsc ps jbody jk) ->
        Right (Eval jbody jsc { scEnv = bindBinders ps vs (scEnv jsc) } jk)

  Handle e h ->
    -- A named handler binds its self-instance binder to a VInst carrying the
    -- binder's Unique (the install SITE) and this activation's tag (the Kont
    -- depth here). Two coexisting activations of one runner site differ in
    -- depth, so two same-typed instances minted by one prelude runner get
    -- distinct VInsts and route apart. The frame stores the same tag so named
    -- dispatch can match it. The scope is shared by the handled expression AND
    -- captured by the KHandle, so the instance handle resolves consistently.
    let tag = kontDepth k
        sc' = case hSelf h of
                Just sb -> sc { scEnv = bindBinder sb (VInst (nameUniq (bndName sb)) tag) (scEnv sc) }
                Nothing -> sc
    in Right (Eval e sc' (KHandle h tag sc' k))

evalRhs :: PrimTable -> Binder -> Rhs -> Expr -> Scope -> Kont -> Either RuntimeError Config
evalRhs prims b rhs body sc k = case rhs of
  RAtom a -> resolveAtom prims sc a >>= cont
  RCon c as -> do vs <- mapM (resolveAtom prims sc) as; cont (VCon c vs)
  RLam ps e -> cont (VClosure (scEnv sc) ps e)
  RRecord t flds -> do
    vs <- mapM (\(l, a) -> (,) l <$> resolveAtom prims sc a) flds
    cont (VRecord t (Map.fromList vs))
  RProj l a -> do
    v <- resolveAtom prims sc a
    case v of
      VRecord _ m -> maybe (Left (BadProjection l)) cont (Map.lookup l m)
      _           -> Left (BadProjection l)
  RApp f as -> do
    fv <- resolveAtom prims sc f
    vs <- mapM (resolveAtom prims sc) as
    enter prims fv vs (KLet b body sc k)
  ROp minst lbl op as -> do
    vs <- mapM (resolveAtom prims sc) as
    mTargetVal <- traverse (resolveAtom prims sc) minst
    mTarget <- case mTargetVal of
      Nothing            -> Right Nothing
      Just (VInst u tag) -> Right (Just (u, tag))
      Just other         -> Left (PrimError (Tx.pack ("internal: instance handle not a VInst: " <> show other)))
    dispatchOp mTarget lbl op vs (KLet b body sc k)
  where
    cont v = Right (Eval body sc { scEnv = bindBinder b v (scEnv sc) } k)

-- | Apply a value to args, continuing with k. Handles currying for closures
-- and accumulation for prims; over-application chains via KApp.
enter :: PrimTable -> Value -> [Value] -> Kont -> Either RuntimeError Config
enter prims fv args k = case fv of
  VClosure cenv ps body ->
    let np = length ps; na = length args in
    case compare na np of
      EQ -> Right (Eval body (Scope (bindBinders ps args cenv) Map.empty) k)
      LT -> Right (Return (VClosure (bindBinders (take na ps) args cenv) (drop na ps) body) k)
      GT -> let (use, over) = splitAt np args
            in Right (Eval body (Scope (bindBinders ps use cenv) Map.empty) (KApp over k))
  VPrim p ->
    let combined = primArgs p ++ args in
    if length combined < primArity p
      then Right (Return (VPrim p { primArgs = combined }) k)
      else let (use, over) = splitAt (primArity p) combined in do
        r <- primFn p use
        case r of
          PRDone v        -> if null over then Right (Return v k) else enter prims v over k
          PRApply g gargs -> enter prims g (gargs ++ over) k
  VCont kb -> case args of
    [v] -> Right (Return v (kb k))
    _   -> Left (ArityError (Tx.pack "continuation expects exactly one argument"))
  VContP f -> case args of
    [param, result] -> Right (Return result (f param k))
    _ -> Left (ArityError (Tx.pack "parameterized continuation expects exactly two arguments"))
  _ -> Left (NotAFunction (renderValue fv))

matchAlts :: Value -> [Alt] -> Scope -> Kont -> Either RuntimeError Config
matchAlts v alts sc k = go alts
  where
    go [] = Left (NonExhaustiveCase (renderValue v))
    go (AltCon c bs e : rest) = case v of
      VCon c' vs | c' == c && length bs == length vs ->
        Right (Eval e sc { scEnv = bindBinders bs vs (scEnv sc) } k)
      _ -> go rest
    go (AltLit l e : rest) = case v of
      VLit l' | l' == l -> Right (Eval e sc k)
      _ -> go rest
    go (AltDefault e : _) = Right (Eval e sc k)

-- | An operation: find the nearest matching handler, capture the delimited
-- continuation above it as a builder, bind the op args and a (deep, multi-shot)
-- resume, and run the arm under the handler's below-continuation.
dispatchOp :: Maybe (Unique, Int) -> Text -> Text -> [Value] -> Kont -> Either RuntimeError Config
dispatchOp mTarget lbl op argVals kCur =
  case findHandler mTarget lbl op kCur of
    Nothing -> Left (NoMatchingHandler lbl op)
    Just (above, h, hTag, hsc, kBelow) ->
      case lookupOpArm lbl op h of
        Nothing -> Left (NoMatchingHandler lbl op)
        Just oa ->
          -- Deep, multishot resume. When the handler is re-installed over the
          -- resume call site `after`, its ANSWER join (the join its arms deliver
          -- to in value position) must also deliver to `after` -- otherwise a
          -- resumed sub-run's answer escapes via the static post-handler
          -- continuation instead of returning to the resume call site. Rebind it
          -- per resume; the TOP-LEVEL op arm below keeps the original `hsc`, so
          -- the real post-handler work runs once on the final answer.
          -- INVARIANT: an answer-join is the single-result merge join
          -- `normName` creates for a value-position handler, so `ps` is
          -- exactly one binder. The `(pb0 : _)` guard takes that binder;
          -- if a future change ever pointed `hAnswerJoin` at a many-param
          -- join, the rebind is skipped (escape bug returns) rather than
          -- misbinding -- keep answer-joins single-param.
          let answerRebind after sc =
                case hAnswerJoin h of
                  Just j
                    | Just (JoinPoint _ ps _ _) <- Map.lookup j (scJoins sc)
                    , (pb0 : _) <- ps ->
                        sc { scJoins =
                               Map.insert j
                                 (JoinPoint sc ps (Ret (AVar (bndName pb0))) after)
                                 (scJoins sc) }
                  _ -> sc
              -- Re-install the handler over the resume site with the ORIGINAL
              -- activation tag (`hTag`), so a handle captured in the resumed
              -- body still id-routes to this same activation.
              resumeVal = case hParam h of
                Nothing ->
                  VCont (\after -> above (KHandle h hTag (answerRebind after hsc) after))
                Just pb ->
                  VContP (\newParam after ->
                    let hsc' = (answerRebind after hsc)
                                 { scEnv = bindBinder pb newParam (scEnv hsc) }
                    in above (KHandle h hTag hsc' after))
              env1 = bindBinders (oaArgs oa) argVals (scEnv hsc)
              env2 = bindBinder (oaResume oa) resumeVal env1
          in Right (Eval (oaBody oa) (Scope env2 (scJoins hsc)) kBelow)

-- | Walk outward from the operation's continuation to the nearest KHandle that
-- covers (label, op). Returns: a builder that re-prepends the frames above the
-- handler, the matched handler, its captured scope, and the continuation below.
findHandler :: Maybe (Unique, Int) -> Text -> Text -> Kont
            -> Maybe (Kont -> Kont, Handler, Int, Scope, Kont)
findHandler mTarget lbl op = go id
  where
    go _   KDone               = Nothing
    go acc (KLet b e sc k)     = go (acc . KLet b e sc) k
    go acc (KApp vs k)         = go (acc . KApp vs) k
    go acc (KHandle h tag sc k)
      | matches h              = Just (acc, h, tag, sc, k)
      | otherwise              = go (acc . KHandle h tag sc) k
      where
        matches hh = coversOp hh && instOk hh
        coversOp hh = any (\a -> oaLabel a == lbl && oaOp a == op) (hOps hh)
        -- Ambient (Nothing) matches any covering handler (today's behaviour).
        -- A named target matches only the handler whose self-binder Unique = u
        -- AND whose activation tag = t (so two activations of one runner site
        -- are told apart; the Unique alone collides across activations).
        instOk hh = case mTarget of
          Nothing      -> True
          Just (u, t)  -> (nameUniq . bndName <$> hSelf hh) == Just u && tag == t

lookupOpArm :: Text -> Text -> Handler -> Maybe OpArm
lookupOpArm lbl op h =
  case [ a | a <- hOps h, oaLabel a == lbl, oaOp a == op ] of
    (a : _) -> Just a
    []      -> Nothing

renderJoin :: JoinId -> Text
renderJoin (JoinId (Unique i)) = Tx.pack "j" <> Tx.pack (show i)

-- | Run a configuration to a final value.
run :: PrimTable -> Config -> Either RuntimeError Value
run prims = loop
  where
    loop cfg = do
      s <- step prims cfg
      case s of
        Done v -> Right v
        More c -> loop c

-- | Pure test seam: evaluate an Expr in a given environment.
evalExprWith :: Env -> Expr -> Either RuntimeError Value
evalExprWith env e = run primTable (Eval e (Scope env Map.empty) KDone)

-- | Whole-module entry.
--
-- Builds a knot-tied global environment: arity-0 top-level binds (CAFs) are
-- EVALUATED once to a 'Value' and shared; arity>0 binds stay 'VClosure's.
-- The env is built with 'Data.Map.Lazy' so each CAF value is a thunk forced on
-- demand, letting a CAF body refer to other globals (knot-tying) without a
-- force-time cycle. Ground instance dictionaries lower to 0-arity record values
-- and rely on this so their fields capture 'gEnv' lazily.
--
-- 'main' is itself a 0-arity bind, so it also gets a forced entry in 'gEnv'.
-- That entry is a lazy thunk that is never demanded (nothing references 'main'),
-- so main's body does NOT run via 'gEnv'. The final 'case' below re-runs main's
-- body explicitly and returns that result, preserving exact prior behavior.
runModule :: CoreModule -> Either RuntimeError Value
runModule (CoreModule binds) =
  let gEnv = MapL.fromList (map entry binds)
      entry (TopBind n ps body)
        | null ps   = (nameUniq n, forceTop body)
        | otherwise = (nameUniq n, VClosure gEnv ps body)
      -- A 0-arity bind evaluates to a Value once. Forcing a dictionary record
      -- only evaluates its spine to a VRecord (field closures capture gEnv
      -- lazily), so this does not recurse into other CAFs at force time.
      -- A Left here means a compiler-generated CAF failed to evaluate, which is
      -- an internal invariant violation (analogous to elaboration's
      -- panic-on-impossible) -- dictionaries never fail to evaluate.
      forceTop body = case run primTable (Eval body (Scope gEnv Map.empty) KDone) of
        Right v  -> v
        Left err -> error ("runModule: CAF evaluation failed: " <> show err)
  in case [ tb | tb@(TopBind n _ _) <- binds, nameHint n == Tx.pack "main" ] of
       (TopBind _ [] body : _) -> run primTable (Eval body (Scope gEnv Map.empty) KDone)
       (TopBind{}         : _) -> Left (ArityError (Tx.pack "main must take no arguments"))
       []                      -> Left (UnboundVar (Tx.pack "main"))
