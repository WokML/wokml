module Wok.Interp.Machine
  ( step
  , run
  , enter
  , evalExprWith
  , runModule
  ) where

import Control.Exception (throw, try, evaluate)
import qualified Data.Map.Strict as Map
import qualified Data.Map.Lazy as MapL
import Data.Text (Text)
import qualified Data.Text as Tx
import System.IO.Unsafe (unsafePerformIO)
import Wok.IR.Anf
  ( Alt (..), Atom (..), Binder (..), CoreModule (..), Expr (..), Handler (..)
  , OpArm (..), Rhs (..), TopBind (..) )
import Wok.IR.Name (JoinId (..), Unique (..), nameHint, nameUniq)
import Wok.Interp.Prim (primTable)
import qualified Wok.Interp.Sched as Sched
import Wok.Interp.Value

-- | Single small-step. Halts on Return into KDone.
step :: PrimTable -> IdSupply -> Config -> Either RuntimeError (Step, IdSupply)
step _     sup (Return v KDone) = Right (Done v, sup)
step prims sup cfg              = do
  (c, sup') <- transition prims sup cfg
  Right (More c, sup')

-- | The non-halting transition: always yields the next Config.
transition :: PrimTable -> IdSupply -> Config -> Either RuntimeError (Config, IdSupply)
transition prims sup (Return v k)      = returnTo prims sup v k
transition prims sup (Eval expr sc k)  = evalExpr prims sup expr sc k

-- | Deliver a value to a continuation frame.
returnTo :: PrimTable -> IdSupply -> Value -> Kont -> Either RuntimeError (Config, IdSupply)
returnTo _     _   _ KDone               = Left (PrimError (Tx.pack "internal: returnTo KDone"))
returnTo _     sup v (KLet b body sc k)  =
  Right (Eval body sc { scEnv = bindBinder b v (scEnv sc) } k, sup)
returnTo prims sup v (KApp args k)       = enter prims sup v args k
returnTo _     sup v (KHandle h _ hsc k) =
  -- Normal completion of a handled computation: run the return arm.
  let (rb, rbody) = hReturn h
  in Right (Eval rbody hsc { scEnv = bindBinder rb v (scEnv hsc) } k, sup)

evalExpr :: PrimTable -> IdSupply -> Expr -> Scope -> Kont -> Either RuntimeError (Config, IdSupply)
evalExpr prims sup expr sc k = case expr of
  Ret a -> do
    v <- resolveAtom prims sc a
    Right (Return v k, sup)

  Let b rhs body -> evalRhs prims sup b rhs body sc k

  Case a alts -> do
    v <- resolveAtom prims sc a
    cfg <- matchAlts v alts sc k
    Right (cfg, sup)

  LetRec defs body ->
    -- Tie the recursive knot: each closure captures the post-binding env'.
    -- env' is self-referential; VClosure's lazy env field keeps this productive.
    let env' = foldr addDef (scEnv sc) defs
        addDef (b, ps, bdy) e = Map.insert (nameUniq (bndName b)) (VClosure env' ps bdy) e
    in Right (Eval body sc { scEnv = env' } k, sup)

  LetJoin j ps jb body ->
    let jp = JoinPoint sc ps jb k
    in Right (Eval body sc { scJoins = Map.insert j jp (scJoins sc) } k, sup)

  Jump j args -> do
    vs <- mapM (resolveAtom prims sc) args
    case Map.lookup j (scJoins sc) of
      Nothing -> Left (UnboundVar (renderJoin j))
      Just (JoinPoint jsc ps jbody jk)
        -- A join point's arity is fixed at its definition; a Jump supplying a
        -- different number of arguments is an IR/compiler bug. Raise a loud
        -- ArityError rather than letting bindBinders' `zip` silently truncate
        -- (which would leave params unbound or drop extra args) -- converting a
        -- structural bug into a silently wrong answer.
        | length vs /= length ps ->
            Left (ArityError
              (Tx.pack "jump to " <> renderJoin j <> Tx.pack ": expected "
                <> Tx.pack (show (length ps)) <> Tx.pack " argument(s), got "
                <> Tx.pack (show (length vs))))
        | otherwise ->
            Right (Eval jbody jsc { scEnv = bindBinders ps vs (scEnv jsc) } jk, sup)

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
    in Right (Eval e sc' (KHandle h tag sc' k), sup)

evalRhs :: PrimTable -> IdSupply -> Binder -> Rhs -> Expr -> Scope -> Kont -> Either RuntimeError (Config, IdSupply)
evalRhs prims sup b rhs body sc k = case rhs of
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
  -- The FBIP reuse form is produced ONLY by the RC reuse-pairing post-pass and
  -- only ever executed by the RC machine; the reference interpreter never runs
  -- on post-pass output, so reaching it here is an internal pipeline error.
  RReuseCon{} -> error "RReuseCon: produced only by reusePairing post-pass (never reaches the reference machine)"
  RApp f as -> do
    fv <- resolveAtom prims sc f
    vs <- mapM (resolveAtom prims sc) as
    enter prims sup fv vs (KLet b body sc k)
  ROp minst lbl op as -> do
    vs <- mapM (resolveAtom prims sc) as
    mTargetVal <- traverse (resolveAtom prims sc) minst
    mTarget <- case mTargetVal of
      Nothing            -> Right Nothing
      Just (VInst u tag) -> Right (Just (u, tag))
      Just other         -> Left (PrimError (Tx.pack ("internal: instance handle not a VInst: " <> show other)))
    cfg <- dispatchOp mTarget lbl op vs (KLet b body sc k)
    Right (cfg, sup)
  where
    cont v = Right (Eval body sc { scEnv = bindBinder b v (scEnv sc) } k, sup)

-- | Apply a value to args, continuing with k. Handles currying for closures
-- and accumulation for prims; over-application chains via KApp.
enter :: PrimTable -> IdSupply -> Value -> [Value] -> Kont -> Either RuntimeError (Config, IdSupply)
enter prims sup fv args k = case fv of
  VClosure cenv ps body ->
    let np = length ps; na = length args in
    case compare na np of
      EQ -> Right (Eval body (Scope (bindBinders ps args cenv) Map.empty) k, sup)
      LT -> Right (Return (VClosure (bindBinders (take na ps) args cenv) (drop na ps) body) k, sup)
      GT -> let (use, over) = splitAt np args
            in Right (Eval body (Scope (bindBinders ps use cenv) Map.empty) (KApp over k), sup)
  VPrim p ->
    let combined = primArgs p ++ args in
    if length combined < primArity p
      then Right (Return (VPrim p { primArgs = combined }) k, sup)
      else let (use, over) = splitAt (primArity p) combined in do
        r <- primFn p use
        case r of
          PRDone v        -> if null over then Right (Return v k, sup) else enter prims sup v over k
          PRApply g gargs -> enter prims sup g (gargs ++ over) k
          PRDrive thunk   -> do
            (v, sup') <- Sched.driveConc enter run prims sup thunk
            if null over then Right (Return v k, sup') else enter prims sup' v over k
  VCont kb -> case args of
    [v] -> Right (Return v (kb k), sup)
    _   -> Left (ArityError (Tx.pack "continuation expects exactly one argument"))
  VContP f -> case args of
    [param, result] -> Right (Return result (f param k), sup)
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

-- | Run a configuration to a final value, threading the Conc handle-id supply.
--
-- REGION INVARIANT: the 'IdSupply' seed identifies an interpreter ENTRY (see
-- 'runModule'). Any NEW call site that starts a fresh run which could be live
-- against the same program's handle ids alongside another run MUST seed a
-- DISTINCT region (a multiple of 'idRegionBound'), or its Conc handles collide
-- with that other run's same-numbered handles -- silently, with no type error.
-- Today the only entries are 'runModule' (main = region 0; each forced CAF =
-- region k) and 'evalExprWith' (region 0, a standalone test seam never live
-- beside a 'runModule'). Do not copy a bare @run prims 0@ into a new concurrent
-- entry without allocating it its own region.
run :: PrimTable -> IdSupply -> Config -> Either RuntimeError (Value, IdSupply)
run prims sup0 cfg0 = loop sup0 cfg0
  where
    loop sup cfg = do
      (s, sup') <- step prims sup cfg
      case s of
        Done v -> Right (v, sup')
        More c -> loop sup' c

-- | Pure test seam: evaluate an Expr in a given environment.
evalExprWith :: Env -> Expr -> Either RuntimeError Value
evalExprWith env e = fst <$> run primTable 0 (Eval e (Scope env Map.empty) KDone)

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
--
-- Region scheme: each lazily-forced CAF is its own interpreter entry that the
-- id supply cannot thread through (the thunk boundary is opaque to the
-- threading). Each CAF therefore seeds its 'run' from a disjoint region so that
-- Conc handle ids minted inside CAF bodies never collide with each other or with
-- main's ids. main uses region 0; CAFs use regions 1, 2, ... in bind order.
-- 'idRegionBound' (2^48) is the number of ids per region. Note: 'main', being
-- itself a 0-arity bind, also gets a (never-demanded) CAF region index in
-- 'cafSeed' — allocated but unused; its explicit run below uses region 0.
runModule :: CoreModule -> Either RuntimeError Value
runModule (CoreModule binds)
  | toInteger (length cafUniqs) > maxIdRegion =
      Left (PrimError (Tx.pack ("too many top-level constants for the conc handle id-region scheme (max " <> show maxIdRegion <> ")")))
  | otherwise =
      let gEnv = MapL.fromList (map entry binds)
          entry (TopBind n ps body)
            | null ps   = (nameUniq n, forceTop (cafSeed Map.! nameUniq n) body)
            | otherwise = (nameUniq n, VClosure gEnv ps body)
          -- A 0-arity bind evaluates to a Value once. Forcing a dictionary record
          -- only evaluates its spine to a VRecord (field closures capture gEnv
          -- lazily), so this does not recurse into other CAFs at force time.
          --
          -- A 'Left' here is a genuine RuntimeError from THIS CAF's body. Because the
          -- CAF lives in the lazy 'gEnv' as a pure 'Value' thunk, it cannot be
          -- returned as a 'Left' from here; it is thrown as 'CafFailure' carrying the
          -- ORIGINAL RuntimeError and re-caught at the 'runModule' boundary, where it
          -- becomes the user's real 'Left RuntimeError' (no panic, no relabelling).
          -- Compiler-generated CAFs (dictionaries) never fail, so the throw path is
          -- only ever taken for a real user runtime error in a 0-arity binding.
          forceTop seed body =
            case run primTable seed (Eval body (Scope gEnv Map.empty) KDone) of
              Right (v, _) -> v
              Left err     -> throw (CafFailure err)
      in case [ tb | tb@(TopBind n _ _) <- binds, nameHint n == Tx.pack "main" ] of
           (TopBind _ [] body : _) ->
             -- 'main' may force CAF thunks lazily; a 'CafFailure' thrown by one of
             -- them is caught here and unwrapped to its original RuntimeError.
             catchCaf (\() -> fst <$> run primTable 0 (Eval body (Scope gEnv Map.empty) KDone))
           (TopBind{}         : _) -> Left (ArityError (Tx.pack "main must take no arguments"))
           []                      -> Left (UnboundVar (Tx.pack "main"))
  where
    -- Zero-arity (CAF) uniques, in bind order. This includes prelude instance
    -- dictionaries, so region indices are NOT predictable from the user file alone.
    cafUniqs = [ nameUniq n | TopBind n ps _ <- binds, null ps ]
    -- Map each CAF unique to its region base: region k => k * idRegionBound.
    -- 'Map' here is Data.Map.Strict (already imported as Map). The Map.! lookup
    -- in 'entry' is total: cafSeed is built from exactly the zero-arity binds
    -- that 'entry' consults it for (null ps in both guards match identically).
    cafSeed  = Map.fromList (zip cafUniqs (map (* idRegionBound) [1 ..]))

-- | Run a thunk producing the program result, catching a 'CafFailure' thrown
-- while forcing a lazy CAF thunk and turning it back into the original
-- 'Left RuntimeError'.
--
-- The argument is a THUNK (@() -> ...@), not the 'Either' itself: were it the
-- 'Either', GHC's strictness analysis would force it at the CALL site (this
-- function is strict in its result), so the 'CafFailure' would be thrown OUTSIDE
-- the 'try' and escape uncaught. Hiding the computation behind a lambda keeps the
-- forcing inside the 'try'.
--
-- The 'Right' value is forced DEEPLY (the data spine 'renderValue' will later
-- traverse -- 'VCon'/'VRecord' fields, recursively), not merely to WHNF, so a
-- failing CAF embedded in a returned structure (e.g. @main = Some bad@) is caught
-- here rather than later when the driver renders the value. 'unsafePerformIO' is
-- sound: the action is pure (its only effect is the imprecise exception we
-- ourselves threw and immediately catch) and deterministic.
catchCaf :: (() -> Either RuntimeError Value) -> Either RuntimeError Value
catchCaf k = unsafePerformIO $ do
  res <- try (evaluate (forceResult (k ())))
  pure $ case res of
    Left (CafFailure err) -> Left err
    Right ok              -> ok
  where
    forceResult e@(Left _) = e
    forceResult (Right v)  = deepForceValue v `seq` Right v
{-# NOINLINE catchCaf #-}

-- | Force the renderable data spine of a 'Value': 'VCon'/'VRecord' fields are
-- forced recursively (these are what 'renderValue' traverses, so a 'CafFailure'
-- reachable from the output surfaces while we are inside 'catchCaf's 'try').
-- Functional/opaque values ('VClosure'/'VPrim'/'VCont'/'VContP'/'VInst') and
-- literals render without forcing their contents, so WHNF suffices for them.
deepForceValue :: Value -> ()
deepForceValue v = case v of
  VLit l       -> l `seq` ()
  VCon _ vs    -> foldr (\x acc -> deepForceValue x `seq` acc) () vs
  VRecord _ m  -> foldr (\x acc -> deepForceValue x `seq` acc) () (Map.elems m)
  _            -> v `seq` ()
