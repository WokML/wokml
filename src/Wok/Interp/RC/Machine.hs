module Wok.Interp.RC.Machine
  ( RCConfig (..)
  , RCStep (..)
  , stepRC
  , runRC
  , runExprRC
  , runModuleRC
  , RCRun (..)
  , renderRcStats
  ) where

import Control.Monad (foldM)
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as Tx
import Wok.IR.Anf
  ( Alt (..), Atom (..), Binder (..), CoreModule (..), Expr (..), Lit (..)
  , Rhs (..), TopBind (..), binderUnique, freeVarsExpr )
import Wok.IR.Name (JoinId (..), Unique (..), nameHint, nameUniq)
import Wok.IR.Reachable (firstOrderNoHandlerViolations)
import Wok.Interp.RC.Prim (rcPrimTable)
import Wok.Interp.RC.Value
import Wok.Interp.Value (RuntimeError (..))

-- ---------------------------------------------------------------------------
-- Configuration
--
-- The RC analogue of 'Wok.Interp.Value.Config', extended to carry the owned
-- 'Store' through every step (like the reference threads 'IdSupply', except the
-- store is the central piece of state here rather than an aside).

data RCConfig
  = REval Expr RCScope RCKont Store
  | RReturn RCValue RCKont Store

-- | One small-step result.
data RCStep = RMore RCConfig | RDone RCValue Store

-- | A single small-step. Halts on a return into the empty continuation.
stepRC :: RCPrimTable -> RCConfig -> Either RuntimeError RCStep
stepRC _     (RReturn v KDoneRC s) = Right (RDone v s)
stepRC prims cfg                   = RMore <$> transition prims cfg

transition :: RCPrimTable -> RCConfig -> Either RuntimeError RCConfig
transition prims (RReturn v k s)    = returnToRC prims v k s
transition prims (REval expr sc k s) = evalExprRC prims expr sc k s

-- ---------------------------------------------------------------------------
-- Return: deliver a value to a continuation frame.

returnToRC :: RCPrimTable -> RCValue -> RCKont -> Store -> Either RuntimeError RCConfig
returnToRC _     _ KDoneRC                _ = Left (PrimError (Tx.pack "internal: returnToRC KDoneRC"))
returnToRC _     v (KLetRC b body sc k)   s =
  Right (REval body sc { rscEnv = bindRCBinder b v (rscEnv sc) } k s)
returnToRC prims v (KAppRC args k)        s = enterRC prims v args k s

-- ---------------------------------------------------------------------------
-- Eval

evalExprRC :: RCPrimTable -> Expr -> RCScope -> RCKont -> Store
           -> Either RuntimeError RCConfig
evalExprRC prims expr sc k s = case expr of
  Ret a -> do
    v <- resolveRCAtom sc a
    Right (RReturn v k s)

  Let b rhs body -> evalRhsRC prims b rhs body sc k s

  Case a alts -> do
    v <- resolveRCAtom sc a
    matchAltsRC v alts sc k s

  LetJoin j ps jb body ->
    let jp = RCJoin sc ps jb k
    in Right (REval body sc { rscJoins = Map.insert j jp (rscJoins sc) } k s)

  Jump j args -> do
    vs <- mapM (resolveRCAtom sc) args
    case Map.lookup j (rscJoins sc) of
      Nothing -> Left (UnboundVar (renderJoin j))
      Just (RCJoin jsc ps jbody jk)
        -- A join's arity is fixed at definition; a Jump with a different count
        -- is an IR bug. Raise a loud ArityError rather than silently
        -- truncating via zip (mirrors the reference machine).
        | length vs /= length ps ->
            Left (ArityError
              (Tx.pack "jump to " <> renderJoin j <> Tx.pack ": expected "
                <> Tx.pack (show (length ps)) <> Tx.pack " argument(s), got "
                <> Tx.pack (show (length vs))))
        | otherwise ->
            Right (REval jbody jsc { rscEnv = bindRCBinders ps vs (rscEnv jsc) } jk s)

  LetRec defs body ->
    -- LetRec = an UNCOUNTED REGION (design invariant 4). A local group of
    -- mutually-recursive closures must tie a knot (even's env references odd,
    -- and vice versa) WITHOUT that intra-group edge becoming a counted cycle.
    --
    -- We allocate the whole group as one region (counted dynamic cells sharing a
    -- fresh region id), build the knotted env that maps every group binder's
    -- Unique to its reserved handle, install each closure node over that knotted
    -- env, then evaluate the body in the scope extended with the group bindings.
    -- 'dropAddr' skips intra-region sibling edges, so the group is dropped as a
    -- unit (each member freed once by its own external drop -- typically a
    -- Perceus-inserted drop at scope exit, or the result drop).
    let n            = length defs
        (addrs, s')  = allocLetRecGroup n s
        -- The knotted env: every group binder -> its reserved region handle.
        -- Built before any closure node is installed, so each closure captures
        -- references to all siblings (including itself).
        groupEnv     = foldl' (\e ((b, _, _), a) -> bindRCBinder b (RVBox a) e)
                              (rscEnv sc) (zip defs addrs)
        -- Install each member's real closure node. Each member captures only the
        -- free variables of its body (minus its own parameters); the knot still
        -- ties because siblings ARE free vars of a body that calls them, so they
        -- remain in each member's captured env. Enclosing owned locals that NO
        -- member references are excluded, so the group drop's cascade does not
        -- decref cells the group does not own.
        s''          = foldl' (\st ((_, ps, bdy), a) ->
                                 let fvs  = freeVarsExpr bdy
                                              `Set.difference`
                                              Set.fromList (map binderUnique ps)
                                     cenv = Map.restrictKeys groupEnv fvs
                                 in writeRegionCell a (NClosure cenv ps bdy) st)
                              s' (zip defs addrs)
    in Right (REval body sc { rscEnv = groupEnv } k s'')

  Handle _ _ ->
    Left (PrimError (Tx.pack "rc M1: effects not supported (no-handler fragment)"))

evalRhsRC :: RCPrimTable -> Binder -> Rhs -> Expr -> RCScope -> RCKont -> Store
          -> Either RuntimeError RCConfig
evalRhsRC prims b rhs body sc k s = case rhs of
  RAtom a -> do
    v <- resolveRCAtom sc a
    cont v s

  RCon c as -> do
    vs <- mapM (resolveRCAtom sc) as
    let (a, s') = alloc (NCon c vs) s
    cont (RVBox a) s'

  RRecord t flds -> do
    vs <- mapM (\(l, a) -> (,) l <$> resolveRCAtom sc a) flds
    let (a, s') = alloc (NRecord t (Map.fromList vs)) s
    cont (RVBox a) s'

  RLam ps e ->
    let fvs     = freeVarsExpr e `Set.difference`
                    Set.fromList (map binderUnique ps)
        cenv    = Map.restrictKeys (rscEnv sc) fvs
        (a, s') = alloc (NClosure cenv ps e) s
    in cont (RVBox a) s'

  RProj l a -> do
    v <- resolveRCAtom sc a
    case v of
      RVBox addr -> do
        c <- deref addr s
        case cNode c of
          NRecord _ m | Just fv <- Map.lookup l m -> cont fv s
          _ -> Left (BadProjection l)
      RVLit _ -> Left (BadProjection l)

  RApp f as -> do
    vs <- mapM (resolveRCAtom sc) as
    callFn prims sc f vs (KLetRC b body sc k) s

  ROp{} ->
    Left (PrimError (Tx.pack "rc M1: effects not supported (no-handler fragment)"))
  where
    cont v s' = Right (REval body sc { rscEnv = bindRCBinder b v (rscEnv sc) } k s')

-- ---------------------------------------------------------------------------
-- Application
--
-- The function atom may resolve to a boxed closure handle (in the env) OR name
-- a primitive (not in the env). 'RCValue' carries no prim constructor, so prim
-- NAMES are resolved here, at the application head, by consulting the table.

-- | Apply the function named by an atom to already-resolved argument values.
callFn :: RCPrimTable -> RCScope -> Atom -> [RCValue] -> RCKont -> Store
       -> Either RuntimeError RCConfig
callFn prims sc f args k s = case f of
  ALit _ -> Left (NotAFunction (Tx.pack "literal"))
  AVar n ->
    case Map.lookup (nameUniq n) (rscEnv sc) of
      Just fv -> enterRC prims fv args k s
      Nothing ->
        case Map.lookup (nameHint n) prims of
          Just p  -> enterPrim prims p args k s
          Nothing -> Left (UnboundVar (nameHint n))

-- | Apply a runtime value (a boxed closure) to args, continuing with @k@.
-- Handles currying and over-application (over-application chains via 'KAppRC').
-- A prim handle never reaches here as a value in M1 (prims are resolved by name
-- at 'callFn'); the only first-class function values are 'NClosure' cells.
enterRC :: RCPrimTable -> RCValue -> [RCValue] -> RCKont -> Store
        -> Either RuntimeError RCConfig
enterRC _ fv args k s = case fv of
  RVBox addr -> do
    c <- deref addr s
    case cNode c of
      NClosure cenv ps body -> do
        -- CONSUME the closure cell. The Perceus pass treats the head @f@ of an
        -- @RApp f as@ as a MOVE (it emits no caller @__rc_drop f@; see
        -- 'ownedOccs'/'moveAtoms' in "Wok.IR.Perceus"), so application owns @f@'s
        -- reference and must release it exactly once. Without this, every
        -- dynamically-allocated closure (a partial application, the LT branch
        -- below) leaks (F4).
        --
        -- The captured env is BORROWED through the new scope by the body / the new
        -- partial closure. To keep refcounts balanced regardless of whether this
        -- closure is shared (rc > 1, dup'd) or unique (rc == 1), we INCREF each
        -- boxed captured handle (handing the body / new closure its OWN ownership
        -- of the captures) and then DROP the closure cell with the normal cascade:
        --   * unique: incref (+1) then dropAddr frees the cell and cascades (-1) ->
        --     net zero on captures, ownership transferred to the consumer;
        --   * shared: incref (+1) then dropAddr only decrements the shell ->
        --     captures gain the consumer's owning ref, the aliases keep theirs.
        --
        -- BORROW-ONLY closures are NEVER consumed (they are not counted moves in
        -- the pass): a static (global) closure and a 'LetRec' region member are
        -- released by the static lifetime / the group drop respectively. For those
        -- we neither incref the captures nor drop the cell.
        let np = length ps; na = length args
            captured = [ a | RVBox a <- Map.elems cenv ]
            consume st
              | isStaticAddr addr     = Right st
              | isRegionAddr addr st  = Right st
              | otherwise = do
                  st' <- foldM (flip incref) st captured
                  dropAddr addr st'
        case compare na np of
          EQ -> do
            s' <- consume s
            Right (REval body (RCScope (bindRCBinders ps args cenv) Map.empty) k s')
          LT -> do
            -- Partial application: allocate a fresh closure that SHARES the
            -- captured handles (increfed by 'consume') plus the supplied args
            -- (moved in from the caller). Then consume the original. (No cell
            -- reuse: M1 has no FBIP.)
            let cenv' = bindRCBinders (take na ps) args cenv
                (a', s') = alloc (NClosure cenv' (drop na ps) body) s
            s'' <- consume s'
            Right (RReturn (RVBox a') k s'')
          GT -> do
            let (use, over) = splitAt np args
            s' <- consume s
            Right (REval body (RCScope (bindRCBinders ps use cenv) Map.empty) (KAppRC over k) s')
      _ -> Left (NotAFunction (Tx.pack "applied a non-closure heap node"))
  RVLit _ -> Left (NotAFunction (Tx.pack "applied a literal"))

-- | Apply a primitive to args, accumulating for currying and threading the
-- store. Mirrors the reference 'enter' prim branch, sans the 'PRDrive'
-- scheduler seam (absent in the no-handler fragment).
enterPrim :: RCPrimTable -> RCPrim -> [RCValue] -> RCKont -> Store
          -> Either RuntimeError RCConfig
enterPrim prims p args k s =
  let combined = rpArgs p ++ args in
  if length combined < rpArity p
    then
      -- Under-saturated: a partially-applied prim. M1's first-order corpus
      -- never partially applies a prim, but support it for parity: there is no
      -- prim value in 'RCValue', so an under-saturated prim cannot be returned
      -- as a value. Raise a loud error rather than silently dropping args.
      Left (ArityError (rpName p <> Tx.pack ": partial application of a primitive is unsupported in rc M1"))
    else do
      let (use, over) = splitAt (rpArity p) combined
      (r, s') <- rpFn p use s
      case r of
        PRDone v
          | null over -> Right (RReturn v k s')
          | otherwise -> enterRC prims v over k s'
        PRApply g gargs ->
          -- The function being applied (e.g. ($)'s first arg) is a value
          -- handle, not a prim name, so dispatch via 'enterRC'.
          enterRC prims g (gargs ++ over) k s'

-- ---------------------------------------------------------------------------
-- Case matching (deref the scrutinee handle, match over the NCon node)

matchAltsRC :: RCValue -> [Alt] -> RCScope -> RCKont -> Store
            -> Either RuntimeError RCConfig
matchAltsRC v alts sc k s = case v of
  RVBox addr -> do
    c <- deref addr s
    goNode (cNode c)
  RVLit l -> goLit l
  where
    -- Boxed scrutinee: match constructor alts against the NCon node; literal
    -- alts and default still apply (a literal alt simply never matches a node).
    goNode node = go alts
      where
        go [] = Left (NonExhaustiveCase (nodeTag node))
        go (AltCon c bs e : rest) = case node of
          NCon c' vs | c' == c && length bs == length vs ->
            Right (REval e sc { rscEnv = bindRCBinders bs vs (rscEnv sc) } k s)
          _ -> go rest
        go (AltLit _ _ : rest) = go rest   -- a boxed node never equals a literal
        go (AltDefault e : _)  = Right (REval e sc k s)

    -- Literal scrutinee: only literal alts and default apply.
    goLit l = go alts
      where
        go [] = Left (NonExhaustiveCase (litText l))
        go (AltLit l' e : rest)
          | l' == l   = Right (REval e sc k s)
          | otherwise = go rest
        go (AltCon{} : rest) = go rest      -- a literal never equals a node
        go (AltDefault e : _) = Right (REval e sc k s)

nodeTag :: Node -> Text
nodeTag (NCon t _)    = t
nodeTag (NRecord t _) = t
nodeTag NClosure{}    = Tx.pack "<closure>"

litText :: Lit -> Text
litText (LInt n)  = Tx.pack (show n)
litText (LStr str) = Tx.pack (show str)
litText (LChar c) = Tx.pack (show c)
litText LUnit     = Tx.pack "()"

renderJoin :: JoinId -> Text
renderJoin (JoinId (Unique i)) = Tx.pack "j" <> Tx.pack (show i)

-- ---------------------------------------------------------------------------
-- Drivers

-- | Run a configuration to a final value, threading the store.
runRC :: RCPrimTable -> RCConfig -> Either RuntimeError (RCValue, Store)
runRC prims = loop
  where
    loop cfg = do
      st <- stepRC prims cfg
      case st of
        RDone v s -> Right (v, s)
        RMore c   -> loop c

-- | Pure test seam: evaluate an Expr in a given environment over a starting
-- store, returning the result value and the final store. The starting store is
-- supplied by the caller (typically 'emptyStore' or a store pre-loaded with a
-- static globals region).
runExprRC :: RCPrimTable -> REnv -> Store -> Expr -> Either RuntimeError (RCValue, Store)
runExprRC prims env s e =
  runRC prims (REval e (RCScope env Map.empty) KDoneRC s)

-- ---------------------------------------------------------------------------
-- Whole-module entry

-- | The result of 'runModuleRC': rendered output, final heap statistics, and
-- the immortal baseline.
--
-- The IMMORTAL BASELINE (@rcBaseline@) is the @stLive@ count immediately after
-- all top-level binds have been installed/forced and BEFORE 'main' runs. It
-- accounts for value-CAFs (0-arity top-level binds other than 'main') whose
-- bodies are forced at load time and whose results live on the dynamic heap for
-- the lifetime of the module. These cells are truly immortal globals; they are
-- not a leak.
--
-- Heap-empty oracle invariant: after rendering and dropping 'main's result,
-- @stLive (rcStats r) == rcBaseline r@.  Equivalently, @main@'s dynamic
-- allocations balance to zero on top of the baseline.  For modules with no
-- value-CAFs @rcBaseline == 0@, so the invariant reduces to @stLive == 0@.
data RCRun = RCRun
  { rcOutput   :: Text
  , rcStats    :: Stats
  , rcBaseline :: Int
  }

-- | The RC analogue of 'Wok.Interp.Machine.runModule'. It mirrors that
-- function's global-environment construction but installs every top-level bind
-- into the STATIC IMMORTAL REGION of the store (negative addresses; see
-- 'allocStatic'):
--
--   * top-level binds are allocated ONCE, before 'main' runs;
--   * references to them are NEVER dup/drop'd ('incref'/'dropAddr' no-op on
--     static addresses), and
--   * they are EXCLUDED from 'stLive' ('allocStatic' does not touch 'stStats'),
--     so the heap-empty measure reflects only the dynamic heap.
--
-- After 'main' returns, the result is RENDERED (a read-only deref) and then
-- DROPPED (if it is a boxed dynamic value).  An 'RCRun' is returned; see its
-- 'rcBaseline' field and the heap-empty oracle invariant documented there.
--
-- Static-env knot. Every top-level bind is assigned its static address up front,
-- so the env passed to closures already maps every global 'Unique' to its
-- handle; this lets top-level functions (including mutually-recursive ones) call
-- one another. Function binds (arity > 0) install an 'NClosure' over that env.
-- Constant binds (arity 0, "CAFs") other than 'main' have their body RUN once,
-- threading the store, and the resulting value bound into the env (eager, in
-- bind order; a CAF may reference earlier globals and any function). 'main'
-- itself is a 0-arity bind but is run explicitly below, not at load time.
runModuleRC :: CoreModule -> Either RuntimeError RCRun
runModuleRC cm@(CoreModule binds) = do
  -- 0. Boundary guard. The RC interpreter supports the handler-free fragment
  --    (closures/'RLam' are admitted as of M1.5; 'Handle'/'ROp' effect features
  --    remain out of scope, as does a standalone closure capturing a 'LetRec'
  --    sibling --- see the TODO in "Wok.IR.Reachable"). A module whose code
  --    reachable from 'main' uses any of these is rejected loudly rather than
  --    running-and-miscompiling. (The differential/stats test harnesses
  --    pre-filter the corpus on the same predicate, so this is a no-op for
  --    in-scope programs.)
  case firstOrderNoHandlerViolations cm of
    []         -> Right ()
    violations ->
      Left (PrimError
        (Tx.pack
           "RC interpreter: code reachable from 'main' uses an unsupported \
           \feature:\n"
          <> Tx.intercalate (Tx.pack "\n") violations))
  -- 1. Reserve a static address for every top-level bind, building the knotted
  --    static env (every global maps to its handle before any body runs) and a
  --    store pre-loaded with placeholder static cells.
  let (knotEnv, addrs, s0) = reserveStatic binds
  -- 2. Install function closures and force constant (CAF) bodies into the store,
  --    threading it left-to-right; the env is refined with CAF result values.
  (staticEnv, s1) <- installBinds rcPrimTable knotEnv binds s0 knotEnv addrs
  -- 3. Snapshot the live-cell count AFTER all top-level binds are installed.
  --    Any cells already live at this point are immortal value-CAF results.
  --    This is the baseline: main's dynamic work should return stLive to exactly
  --    this value, not necessarily to zero.
  let baseline = stLive (stStats s1)
  -- 4. Locate and run 'main' (must be 0-arity), starting from the loaded store.
  case [ tb | tb@(TopBind n _ _) <- binds, nameHint n == Tx.pack "main" ] of
    (TopBind _ [] body : _) -> do
      (v, s2) <- runExprRC rcPrimTable staticEnv s1 body
      txt <- renderRCValue s2 v
      -- 5. Drop the result if it is a (dynamic) boxed value; a static handle and
      --    a literal need no drop. Then read the final dynamic-heap stats.
      s3 <- case v of
        RVBox a | not (isStaticAddr a) -> dropAddr a s2
        _                              -> Right s2
      Right (RCRun txt (stStats s3) baseline)
    (TopBind{} : _) -> Left (ArityError (Tx.pack "main must take no arguments"))
    []              -> Left (UnboundVar (Tx.pack "main"))

-- | Pre-assign a static address to every top-level bind, returning: the knotted
-- env that maps each bind's 'Unique' to its static handle, the per-bind address
-- list (in bind order), and a store pre-loaded with one placeholder static cell
-- per bind. The placeholders are overwritten by 'installBinds' before 'main'
-- runs, so they are never observed.
reserveStatic :: [TopBind] -> (REnv, [Addr], Store)
reserveStatic = go emptyStore Map.empty []
  where
    go s env addrs [] = (env, reverse addrs, s)
    go s env addrs (TopBind n _ _ : rest) =
      let (a, s') = allocStatic placeholderNode s
      in go s' (Map.insert (nameUniq n) (RVBox a) env) (a : addrs) rest

-- | A never-observed placeholder cell occupying a reserved static address until
-- 'installBinds' writes the bind's real node.
placeholderNode :: Node
placeholderNode = NCon (Tx.pack "<uninstalled-global>") []

-- | Install each top-level bind into the static region, threading the store.
-- Function binds (arity > 0) become 'NClosure' cells over the knotted static
-- env; 0-arity binds other than 'main' are RUN once and their result rebound
-- into the env (eager, in bind order). 'main' keeps its placeholder cell (it is
-- run explicitly by 'runModuleRC').
installBinds
  :: RCPrimTable
  -> REnv          -- ^ the full knotted static env (closures capture this)
  -> [TopBind]     -- ^ binds, in order
  -> Store         -- ^ store carrying the reserved placeholder cells
  -> REnv          -- ^ accumulator env (refined with CAF results)
  -> [Addr]        -- ^ static address reserved for each bind, in order
  -> Either RuntimeError (REnv, Store)
installBinds prims knotEnv = go
  where
    go (TopBind n ps body : bs) s env (a : as)
      | not (null ps) =
          let s' = writeStatic a (NClosure knotEnv ps body) s
          in go bs s' env as
      | nameHint n == Tx.pack "main" =
          go bs s env as
      | otherwise = do
          (v, s') <- runExprRC prims env s body
          -- F2: write the forced CAF result back into its RESERVED static cell.
          -- Function binds are installed as 'NClosure' capturing the UNREFINED
          -- 'knotEnv', which maps this CAF's 'Unique' to its static handle
          -- ('RVBox a'). Only refining the accumulator 'env' (as we still do, for
          -- later CAFs that look up through it) leaves the static cell holding the
          -- never-overwritten 'placeholderNode', so a forward-referencing function
          -- closure dereferences "<uninstalled-global>" and crashes (or reads a
          -- wrong value). Copying the forced node into the static cell makes the
          -- knotEnv mapping resolve to the real value for ALL captors.
          --
          -- Accounting is unchanged: the CAF's body already allocated its node and
          -- children on the DYNAMIC heap (counted in 'stLive', hence in the
          -- baseline) when 'runExprRC' ran. 'writeStatic' touches no stats and
          -- never increfs, so the static cell is an UNCOUNTED ALIAS sharing the
          -- same child handles as the dynamic node; it adds nothing to the baseline
          -- and is never dropped. A non-boxed (literal) CAF result has no node to
          -- copy: closures referencing a literal CAF remain unsupported in M1
          -- (there is no 'NLit' node), so we leave the static placeholder for them
          -- and rely on the accumulator env for the boxed-only corpus.
          --
          -- F6: bind the STATIC handle ('RVBox a'), NOT the dynamic one ('v'), into
          -- the accumulator env for a boxed CAF whose node we copied into the static
          -- cell. The CAF is a GLOBAL: every captor must see it as the immortal,
          -- UNCOUNTED static handle so that dup/drop of a CAF reference is inert
          -- ('incref'/'dropAddr' no-op on negative addresses). Previously the env
          -- bound the DYNAMIC counted address, so a captor that captures the whole
          -- enclosing scope and frees its non-sibling boxed children on drop --- a
          -- covered local 'LetRec' group closure (see 'countedChildren') --- would
          -- cascade into the CAF's dynamic cell and decref it once PER member, a
          -- premature free / double-free. Handing back the static handle makes the
          -- CAF region-less AND static, so the cascade skips it (the invariant: a
          -- group drop must never decref a cell the group does not own). Function
          -- closures already captured the static handle via 'knotEnv'; this aligns
          -- the accumulator env (which seeds main's runtime scope) with it.
          let (s'', envV) = case v of
                RVBox dynAddr | not (isStaticAddr dynAddr) ->
                  case deref dynAddr s' of
                    Right c -> (writeStatic a (cNode c) s', RVBox a)
                    Left _  -> (s', v)
                _ -> (s', v)
          go bs s'' (Map.insert (nameUniq n) envV env) as
    go [] s env [] = Right (env, s)
    -- The bind list and address list are built together in 'reserveStatic', so
    -- they always have equal length; a mismatch is an internal invariant break.
    go _ _ _ _ = Left (PrimError (Tx.pack "internal: runModuleRC bind/addr length mismatch"))

-- | A stable, line-oriented dump of an 'RCRun's dynamic-heap accounting, used by
-- the @--dump-rc-stats@ CLI mode and its golden (Suite B, Task 9). Pins the
-- allocation behaviour of a program so that a regression --- e.g. a move
-- silently turning into a @dup@, or a missing @drop@ --- surfaces as a golden
-- diff. The four numbers are the FINAL dynamic-heap stats after 'main' has run
-- and its result has been rendered and dropped, plus the immortal baseline:
--
--   * @allocs@   --- total dynamic allocations over the whole run;
--   * @frees@    --- total dynamic frees over the whole run;
--   * @peakLive@ --- high-water mark of live dynamic cells;
--   * @baseline@ --- immortal live count after globals/CAFs install, before main.
--
-- The heap-empty oracle invariant (asserted by the Suite B HUnit harness, not
-- re-checked here) is @stLive == baseline@ AND @allocs - frees == baseline@.
renderRcStats :: RCRun -> Text
renderRcStats run =
  let st = rcStats run
   in Tx.unlines
        [ Tx.pack "allocs   = " <> Tx.pack (show (stAllocs st))
        , Tx.pack "frees    = " <> Tx.pack (show (stFrees st))
        , Tx.pack "peakLive = " <> Tx.pack (show (stPeak st))
        , Tx.pack "baseline = " <> Tx.pack (show (rcBaseline run))
        ]
