module Wok.Interp.RC.Machine
  ( RCConfig (..)
  , RCStep (..)
  , stepRC
  , runRC
  , runExprRC
  , runModuleRC
  , runModuleRCUnchecked
  , RCRun (..)
  , renderRcStats
  ) where

import Control.Monad (foldM)
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as Tx
import Wok.IR.Anf
  ( Alt (..), Atom (..), Binder (..), CoreModule (..), Expr (..), Handler (..)
  , Lit (..), OpArm (..), Rhs (..), TopBind (..), binderUnique, bndName
  , freeVarsExpr, hAnswerJoin )
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
-- OWNED: a 'KAppRC' over-application continuation holds an ANONYMOUS intermediate
-- function value (the result of saturating the previous application) with no IR
-- binder. The application is its sole owner, so it CONSUMES it (no Perceus drop
-- can reach an unnamed intermediate). See 'enterRC'.
returnToRC prims v (KAppRC args k)        s = enterRC False prims v args k s
-- DEFERRED CONSUME (M2a-2): the unnamed-intermediate closure cell whose body just
-- produced @v@ is now dropped --- its captures are no longer borrowed by the
-- (completed) body, so the cascade is safe. Thread @v@ onward to the saved
-- continuation. (See 'KDropCellRC' and the deferred-consume note in 'enterRC'.)
returnToRC _     v (KDropCellRC addr k)   s = do
  s' <- dropAddr addr s
  Right (RReturn v k s')
-- Normal completion of a handled computation (M2b-1 Task 3): run the return arm,
-- binding the produced value to the return binder in the frame's captured scope.
-- Mirrors the reference 'Wok.Interp.Machine.returnTo' 'KHandle' arm. The frame
-- captured 'hsc' by reference (no incref on install), so there is nothing to drop
-- here: the value 'v' is delivered into the return-arm body, which the Perceus
-- pass instruments for its own last-use drops.
returnToRC _     v (KHandleRC h _ hsc k)  s =
  let (rb, rbody) = hReturn h
  in Right (REval rbody hsc { rscEnv = bindRCBinder rb v (rscEnv hsc) } k s)

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
    -- SHARED-ENV + CODE-POINTER representation (M2a-2 Task 3). A local group of
    -- mutually-recursive closures is evaluated as ONE static code label (the
    -- 'NGroupCode' table, installed at an immortal negative address, never
    -- counted) plus AT MOST ONE shared dynamic 'NEnv' cell holding the group's
    -- enclosing captures. Each group binder maps to an 'RVRecMember groupAddr i
    -- envAddr': a member handle that names its code by index and shares the one
    -- env. The intra-group knot is implicit --- a sibling call reconstructs the
    -- sibling handles inline at entry (see the 'RVRecMember' arm of 'enterRC') ---
    -- so there is no counted cycle to break and no per-member region cell.
    --
    --   * CAPTURES are the union of each member-body's free vars, minus the
    --     members' own parameters and minus the group's own binders (siblings are
    --     NOT captured; they are reconstructed at entry).
    --   * A CAPTURE-FREE group uses the static empty-env sentinel as its envAddr
    --     and allocates NO dynamic cell.
    --   * A CAPTURING group allocates exactly ONE 'NEnv' cell (counted); the
    --     single counted child of every member handle, freed once when the last
    --     member handle is dropped (see 'valueChildren'/'countedChildren').
    let (gAddr, sg) = allocStatic (NGroupCode defs) s
        groupU      = Set.fromList [ binderUnique b | (b, _, _) <- defs ]
        -- Captures = the union of each member body's free vars, minus the members'
        -- own parameters and the group's own binders (siblings are reconstructed,
        -- not captured). Restricted to names actually BOUND in the enclosing scope:
        -- a free 'Unique' that is a prim/global name resolved at the call head (not
        -- present in 'rscEnv') is NOT a capture and must not seed an 'NEnv' field.
        --
        -- COUNTED-ENV PREDICATE (M2a-2 BLOCKER 2). The shared 'NEnv' exists (counted)
        -- iff the group captures ANY bound enclosing local --- BOXED OR UNBOXED. An
        -- unboxed capture (e.g. corpus 36's @u : U64@) must be STORED in the env so
        -- the member body can resolve it (the body reads it from 'envFields'), and a
        -- single counted 'NEnv' cell then holds it; the cell needs exactly one drop
        -- regardless of field boxedness. The pass agrees through the SAME plumbing,
        -- NOT a duplicated predicate: it represents the env by the group's member-0
        -- unit and unconditionally inserts one @__rc_dup@/@__rc_drop@ of it per
        -- escape/scope-exit; the runtime resolves those to @incref@/@dropAddr envAddr@,
        -- which are NO-OPS on the static empty-env sentinel (capture-free) and exactly
        -- one ref op on a real cell. So "capture-free => zero cells, sentinel" and
        -- "any capture => one counted cell" hold identically on both sides without the
        -- pass re-deriving boxedness. (The pass's boxed-only 'memberCaps' filter is for
        -- the capture-MOVE accounting --- which enclosing owned units are moved into
        -- the env and dup-planned --- NOT for env existence; unboxed locals are not
        -- reference-counted, so they need no move/dup, only storage for evaluation.)
        caps        = Set.unions
                        [ (freeVarsExpr bdy `Set.difference`
                            Set.fromList (map binderUnique ps)) `Set.difference` groupU
                        | (_, ps, bdy) <- defs ]
        capList     = [ u | u <- Set.toList caps, Map.member u (rscEnv sc) ]
        (envAddr, sEnv)
          | null capList = (emptyEnvSentinelAddr, sg)
          | otherwise    =
              let fields = Map.fromList
                    [ (u, v) | u <- capList, Just v <- [Map.lookup u (rscEnv sc)] ]
              in alloc (NEnv fields) sg
        groupEnv = foldl' (\e ((b, _, _), i) ->
                             bindRCBinder b (RVRecMember gAddr i envAddr) e)
                          (rscEnv sc) (zip defs [0 ..])
    in Right (REval body sc { rscEnv = groupEnv } k sEnv)

  Handle e h ->
    -- Install the counted handler frame (M2b-1 Task 3), mirroring the reference
    -- 'Wok.Interp.Machine.evalExpr' 'Handle' arm. A NAMED handler binds its
    -- self-instance binder to an 'RVInst' carrying the binder's 'Unique' (the
    -- install SITE) and this activation's tag (the 'kontDepth' here); the same tag
    -- is stored in the frame so named dispatch (Task 4) can match it. 'RVInst' is
    -- UNBOXED, so binding 'self' adds nothing to the reference count.
    --
    -- RC DISCIPLINE: the 'KHandleRC' frame captures 'sc'' BY REFERENCE, exactly
    -- like the 'KLetRC b body sc k' frame captures its 'sc' WITHOUT increfing ---
    -- the scope's values are owned by their binders and dropped by the Perceus
    -- pass at last use. We do NOT incref the scope's values on install.
    let tag = kontDepth k
        sc' = case hSelf h of
                Just sb -> sc { rscEnv = bindRCBinder sb (RVInst (nameUniq (bndName sb)) tag) (rscEnv sc) }
                Nothing -> sc
    in Right (REval e sc' (KHandleRC h tag sc' k) s)

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
        (a, s') = alloc (mkClosure cenv ps e) s
    in cont (RVBox a) s'

  RProj l a -> do
    v <- resolveRCAtom sc a
    case v of
      RVBox addr -> do
        c <- deref addr s
        case cNode c of
          NRecord _ m | Just fv <- Map.lookup l m -> cont fv s
          _ -> Left (BadProjection l)
      RVLit _           -> Left (BadProjection l)
      RVRecMember{} -> Left (BadProjection l)
      RVInst _ _    -> Left (BadProjection l)

  RApp f as -> do
    vs <- mapM (resolveRCAtom sc) as
    callFn prims sc f vs (KLetRC b body sc k) s

  -- An effect OPERATION (M2b-1 Task 4): the RC analogue of the reference
  -- 'Wok.Interp.Machine' 'ROp' arm. Resolve the args and the optional named-
  -- instance handle, then dispatch via 'rcDispatchOp' with the OP-SITE
  -- continuation 'KLetRC b body sc k' (so the captured @above@ prefix includes
  -- this 'Let' frame).
  ROp minst lbl op as -> do
    vs      <- mapM (resolveRCAtom sc) as
    mTarget <- resolveInstRC sc minst
    rcDispatchOp mTarget lbl op vs (KLetRC b body sc k) s
  where
    cont v s' = Right (REval body sc { rscEnv = bindRCBinder b v (rscEnv sc) } k s')

-- | Resolve the optional named-instance handle of an 'ROp' to its @(Unique, tag)@
-- routing pair. 'Nothing' is ambient dispatch (route to the nearest covering
-- handler); a 'Just' must resolve to an 'RVInst' (an unboxed identity pair). Any
-- other value is an internal IR/elaboration error. Mirrors the reference
-- 'Wok.Interp.Machine' 'ROp' instance-handle resolution.
resolveInstRC :: RCScope -> Maybe Atom -> Either RuntimeError (Maybe (Unique, Int))
resolveInstRC _  Nothing  = Right Nothing
resolveInstRC sc (Just a) = do
  v <- resolveRCAtom sc a
  case v of
    RVInst u tag -> Right (Just (u, tag))
    _            -> Left (PrimError (Tx.pack "internal: instance handle not an RVInst"))

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
      -- BORROW: the function value sits at a NAMED call head, owned by its binder;
      -- the application reads it and Perceus drops it at its last use.
      Just fv -> enterRC True prims fv args k s
      Nothing ->
        case Map.lookup (nameHint n) prims of
          Just p  -> enterPrim prims p args k s
          Nothing -> Left (UnboundVar (nameHint n))

-- | Apply a runtime value (a boxed closure) to args, continuing with @k@.
-- Handles currying and over-application (over-application chains via 'KAppRC').
-- A prim handle never reaches here as a value in M1 (prims are resolved by name
-- at 'callFn'); the only first-class function values are 'NClosure' cells.
-- The 'Bool' is @borrowHead@: 'True' when the function value sits at a NAMED call
-- head (from 'callFn'), where the application BORROWS it and Perceus drops it at
-- its last use; 'False' when it is an ANONYMOUS runtime intermediate (a 'KAppRC'
-- over-application continuation, a prim's over-application result, or a 'PRApply'
-- function value) that the application OWNS and must consume, since no IR binder
-- (and therefore no Perceus drop) can reach it.
enterRC :: Bool -> RCPrimTable -> RCValue -> [RCValue] -> RCKont -> Store
        -> Either RuntimeError RCConfig
enterRC borrowHead _ fv args k s = case fv of
  RVBox addr -> do
    c <- deref addr s
    case cNode c of
      cl@(NClosure cenv ps body capMode) -> do
        -- BORROW-ON-CALL (M2a-2 Task 1). Applying a function value at a NAMED call
        -- head BORROWS it: the call is a pure READ of the closure cell and NEVER
        -- drops it. The Perceus pass treats the head @f@ of an @RApp f as@ as a
        -- BORROW (see 'ownedOccs' / 'moveAtoms' in "Wok.IR.Perceus"): @f@ stays
        -- owned by its binder and is dropped at its real LAST USE by the standard
        -- last-use machinery, exactly like any other value. A closure called N times
        -- is therefore dup'd 0 times and dropped exactly once (at last use), when
        -- its cell's drop cascades into the owned captures (see 'countedChildren').
        --
        -- The closure/region representation is UNCHANGED here (the shared-env
        -- representation is a later task): the cell still OWNS its boxed captures,
        -- and the body is still instrumented as a scope that OWNS those captures on
        -- entry (see 'ownRhs'). To keep that body model valid we INCREF each owned
        -- boxed capture on entry (handing the body its own ownership, which the body
        -- consumes/drops). On a BORROWED head we do NOT drop the cell --- it keeps
        -- its own ref to each capture, released once by the cascade when the cell is
        -- finally dropped at the caller's last use.
        --
        -- An ANONYMOUS runtime intermediate (@borrowHead == False@: a 'KAppRC' over-
        -- application continuation, a prim over-application result, or a 'PRApply'
        -- value) has NO IR binder, so Perceus cannot place its drop. The application
        -- is its sole owner and CONSUMES it: after increfing the captures (the body
        -- still owns its copies) we DROP the cell, whose cascade releases its own
        -- capture refs --- exactly the historical consume-on-call accounting, now
        -- confined to the unnamed-intermediate case.
        --
        -- A captured handle is either OWNED (this closure holds a counted ref) or
        -- BORROWED (it points at a static cell, owned by its static lifetime). The
        -- SAME 'countedRefs' enumeration ('closureOwnedBoxed' here, the drop cascade
        -- on free) skips static (borrowed) captures and retains dynamic (owned) ones,
        -- so a capture is increfed on application EXACTLY iff it is released on drop
        -- --- one source of truth, no parallel borrowed-set.
        let np = length ps; na = length args
            ownedCaptured = closureOwnedBoxed cl
            -- BORROW-ONLY cells are a static (global) closure: their captures are
            -- owned by the static lifetime, so a call neither increfs them (as
            -- before) nor cascades them, and they are never consumed by the call.
            borrowOnly      = isStaticAddr addr
            increfOwned st  = if borrowOnly then Right st
                              else foldM (flip incref) st ownedCaptured
            -- This call CONSUMES the cell iff it is an unnamed intermediate (not a
            -- borrowed named head) and not a borrow-only cell.
            consumes        = not borrowHead && not borrowOnly
            -- IMMEDIATE consume: drop the cell now. Used ONLY where the cell's body
            -- does NOT run on this step (the LT partial-application path), so the
            -- cascade cannot race a still-borrowing body.
            consumeCellNow st = if consumes then dropAddr addr st else Right st
            -- DEFERRED consume: keep the cell alive THROUGH its own call, dropping it
            -- only when the body's result returns. The body borrows the cell's
            -- captures (an 'RVRecMember' capture's shared env is cascade-eligible on
            -- the cell's drop), so an eager drop would free the env mid-call --- a
            -- use-after-free. 'KDropCellRC' threads the drop past the body. A
            -- borrowed/borrow-only head is left alive (its binder / lifetime owns it).
            deferConsume kont = if consumes then KDropCellRC addr kont else kont
        case compare na np of
          EQ -> do
            s'  <- increfOwned s
            Right (REval body (RCScope (bindRCBinders ps args cenv) Map.empty) (deferConsume k) s')
          LT -> do
            -- Partial application: allocate a fresh closure that SHARES the original's
            -- captures plus the supplied args (moved in from the caller). It keeps the
            -- original's 'CaptureMode' (the body --- and so its borrow-vs-own capture
            -- discipline --- is unchanged), so a partial-of-a-partial of a member
            -- closure stays 'BorrowCaptures'.
            --
            -- ACQUIRE/RELEASE (uniform). The new cell OWNS one ref to each capture it
            -- SHARES with the original --- ALL of them, 'RVBox' and 'RVRecMember'-env
            -- alike, via 'countedRefs' over the original's @cenv@ (the same enumeration
            -- its drop cascade releases). So we ALWAYS incref the shared captures here,
            -- handing the new cell its own ownership. The supplied @args@ are MOVED in
            -- (no incref; consumed by the new cell's drop). Independently, if the
            -- original is an UNNAMED intermediate we CONSUME it ('consumeCellNow'),
            -- which releases the ORIGINAL's refs to those captures --- leaving the
            -- new cell's freshly-acquired refs as the surviving owners. A borrowed
            -- named head is left alive (dropped at its last use by the pass), keeping
            -- its own refs. Either way the new cell's acquire is matched by its own
            -- drop, and the original's refs are matched by the original's drop --- two
            -- balanced pairs, no transfer-by-omission. The body does NOT run here, so
            -- an IMMEDIATE consume is safe.
            let cenv' = bindRCBinders (take na ps) args cenv
                (a', s') = alloc (NClosure cenv' (drop na ps) body capMode) s
                sharedCaptureRefs = countedRefs (Map.elems cenv)
            s''  <- foldM (flip incref) s' sharedCaptureRefs
            s''' <- consumeCellNow s''
            Right (RReturn (RVBox a') k s''')
          GT -> do
            let (use, over) = splitAt np args
            s'  <- increfOwned s
            Right (REval body (RCScope (bindRCBinders ps use cenv) Map.empty)
                     (KAppRC over (deferConsume k)) s')
      -- RESUME of a reified continuation (M2b-1 Task 5; spec §4.3 RESUME). Applying
      -- the boxed 'NCont' handle (the op-arm @resume@ binder) MOVES the captured
      -- frames back onto the live 'Kont': 'spliceKont' re-prepends the prefix and
      -- re-installs the matching handler ('KHandleRC') over the post-resume
      -- continuation @k@ (= the reference's @after@), then the resume argument is
      -- delivered into it. 'moveOutCont' frees the 'NCont' SHELL ONLY (one-shot
      -- guarantees rc == 1) WITHOUT cascading its children --- their refcounts are
      -- untouched because ownership transfers to the now-live spliced frames; their
      -- own pending @__rc_drop@/move instructions fire as those frames run. Mirrors
      -- the reference @enter@ 'VCont'/'VContP' arms.
      --
      -- M2b-2 two-arg path (hParam = Just pb): @resume newParam result@ re-installs
      -- the handler with the parameter slot REBOUND to @newParam@ (own-new: the
      -- previous slot binding was handed to the arm at dispatch and is stale, so
      -- NO drop here), and delivers @result@ to the resume call site. Mirrors
      -- the reference @enter@ 'VContP' arm: @Return result (f newParam k)@.
      --
      -- DO NOT add a 'dropAddr' of the old param here. The old @hsc[pb]@ binding is
      -- overwritten by 'bindRCBinder'; the value was moved to the arm at dispatch and
      -- is already stale. A drop here would double-free against the arm's Perceus
      -- compiler-placed drop.
      --
      -- M2b-2 Task 5: 'answerRebindRC' re-points the handler's ANSWER JOIN (if any)
      -- to @k@ (the resume call site) so that a value-position resumed sub-run's
      -- answer is delivered here, not to the static post-handler continuation. A
      -- tail-position handler has 'hAnswerJoin = Nothing', making it a no-op.
      NCont{} -> do
        (prefix, (h, hTag, hsc), s') <- moveOutCont addr s
        case (hParam h, args) of
          (Nothing, [v]) ->
            let hsc' = answerRebindRC h k hsc
            in Right (RReturn v (spliceKont prefix (KHandleRC h hTag hsc' k)) s')
          (Just pb, [newParam, result]) ->
            let hsc'  = hsc { rscEnv = bindRCBinder pb newParam (rscEnv hsc) }
                hsc'' = answerRebindRC h k hsc'
                k'    = spliceKont prefix (KHandleRC h hTag hsc'' k)
            in Right (RReturn result k' s')
          _ -> Left (ArityError (Tx.pack "resume arity does not match handler parameter"))
      _ -> Left (NotAFunction (Tx.pack "applied a non-closure heap node"))
  RVLit _ -> Left (NotAFunction (Tx.pack "applied a literal"))
  RVRecMember gAddr i envAddr -> do
    -- BORROW-ON-CALL of a shared-env recursive member (M2a-2 Task 3). Calling an
    -- 'RVRecMember' is a pure READ: the member handle is never consumed and its
    -- shared 'NEnv' is never increfed/dropped by the call (it is owned by the
    -- handle's lifetime, released once when the last handle is dropped). The
    -- sibling scope is reconstructed INLINE at entry --- every group binder maps
    -- to its own 'RVRecMember' over the SAME group code label and env --- so the
    -- mutual-recursion knot is re-tied without a counted cycle.
    gc <- deref gAddr s
    case cNode gc of
      NGroupCode defs -> do
        let (_, ps, body) = defs !! i
            np = length ps; na = length args
        -- The shared captured env. A capture-free group points at the static
        -- empty-env sentinel, which legitimately degrades to the empty env (it is
        -- uncounted and always reconstructible). A NON-sentinel env addr that fails
        -- to deref is a genuine use-after-free / dangling pointer: surface it as a
        -- 'Left' rather than laundering it into 'Map.empty' (which would turn a
        -- freed-env UAF into a silent wrong value via a spurious 'UnboundVar').
        envFields <- case deref envAddr s of
                       Right c | NEnv m <- cNode c -> Right m
                       _ | envAddr == emptyEnvSentinelAddr -> Right Map.empty
                       Left e                              -> Left e
                       Right _ -> Left (PrimError (Tx.pack
                                    ("RVRecMember env addr is not NEnv: " <> show envAddr)))
        let -- Reconstruct the sibling handles (all members of THIS group, over the
            -- same code label and env). These are BORROWS --- no incref.
            sibs = Map.fromList
                     [ (binderUnique b, RVRecMember gAddr j envAddr)
                     | ((b, _, _), j) <- zip defs [0 ..] ]
            -- The full call environment: bound params (left-to-right), then the
            -- siblings, then the shared captures. Earlier maps win on key clash.
            callEnv extra =
              Map.unions [ Map.fromList (zip (map binderUnique ps) extra), sibs, envFields ]
            -- DEFERRED ENV-DROP (M2a-2 Stage B). When an 'RVRecMember' is applied as
            -- an UNNAMED INTERMEDIATE (@borrowHead == False@: the result of an
            -- over-applied call, e.g. @(mk 0) 2@ where @mk 0@ returned the member),
            -- there is no IR binder for the member handle, so Perceus cannot place
            -- its drop, and the shared env it carries out would LEAK. Calling a member
            -- never consumes it (borrow-on-call), so we drop its env AFTER the body
            -- returns via 'KDropCellRC' (a no-op on the static empty-env sentinel;
            -- one decref of a real 'NEnv'). A NAMED head is a borrow whose env is
            -- owned by its binder and dropped at its last use by the pass, so it is
            -- left untouched here.
            deferEnv kont = if borrowHead then kont else KDropCellRC envAddr kont
        case compare na np of
          EQ -> Right (REval body (RCScope (callEnv args) Map.empty) (deferEnv k) s)
          GT -> let (use, over) = splitAt np args
                in Right (REval body (RCScope (callEnv use) Map.empty) (KAppRC over (deferEnv k)) s)
          LT -> do
            -- Partial application: allocate an ordinary closure that captures the
            -- already-supplied args (bound to the consumed params), the siblings,
            -- and the shared captures. Its body is the member body; its remaining
            -- params are the unsupplied ones. A later full application re-enters
            -- the member through the standard 'NClosure' path, so the recursion is
            -- preserved.
            --
            -- RETAIN/RELEASE SYMMETRY (the M2a-2 fix). The new cell OWNS one ref to
            -- each of its CAPTURES --- the sibling handles (each carrying the shared
            -- @envAddr@) and the captured locals @envFields@ --- so we INCREF those
            -- captures here, exactly the set the cell's eventual drop releases via
            -- 'countedRefs' over the cell's env. The supplied @args@ are MOVED in
            -- (their ref transfers from the caller); they are NOT increfed on build
            -- but ARE released by the cell's drop, which is how the move is consumed.
            --
            -- The cell is built 'BorrowCaptures': its body is the member body, which
            -- BORROWS its siblings and captured locals (a member never consumes a
            -- capture --- #1 is deferred). So when this cell is later re-entered (the
            -- standard 'NClosure' path), @increfOwned@ must hand the body NOTHING
            -- ('closureOwnedBoxed' is empty for 'BorrowCaptures'); the cell's single
            -- acquired ref is released only by its drop. Increfing on re-entry would
            -- leak the shared env --- the unmatched-incref half of the original bug.
            --
            -- FLOATING ENV-HANDLE RELEASE. When the member handle is an UNNAMED
            -- INTERMEDIATE (@borrowHead == False@: e.g. @mk 0@ returned the member,
            -- which is then under-applied), there is no IR binder for it, so Perceus
            -- cannot place its drop and the @envAddr@ it carried out would LEAK
            -- (a NAMED head's env is owned by its binder and dropped at its last use
            -- by the pass). Calling a member never consumes it, so we drop that
            -- floating env ref here --- a no-op on the static empty-env sentinel, one
            -- decref of a real 'NEnv'. The body does NOT run on this step, so an
            -- IMMEDIATE drop is safe (no still-borrowing body to race). ORDER: incref
            -- the captures FIRST, then drop the floating ref, so the cell's own
            -- env ownership is established before the member handle's is released.
            let cenv = Map.unions
                         [ Map.fromList (zip (map binderUnique (take na ps)) args)
                         , sibs, envFields ]
                (a', s') = alloc (NClosure cenv (drop na ps) body BorrowCaptures) s
                capRefs  = countedRefs (Map.elems sibs ++ Map.elems envFields)
            s''  <- foldM (flip incref) s' capRefs
            s''' <- if borrowHead then Right s'' else dropAddr envAddr s''
            Right (RReturn (RVBox a') k s''')
      _ -> Left (NotAFunction (Tx.pack "RVRecMember group addr is not NGroupCode"))
  RVInst _ _ -> Left (NotAFunction (Tx.pack "applied an instance handle"))

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
          -- OWNED: the prim returned a function value we now over-apply; it is an
          -- anonymous intermediate the application consumes (no Perceus drop).
          | otherwise -> enterRC False prims v over k s'
        PRApply g gargs ->
          -- The function being applied (e.g. ($)'s first arg) is a value handle,
          -- not a prim name, so dispatch via 'enterRC'. It is an OWNED intermediate
          -- delivered by the prim, consumed by the application.
          enterRC False prims g (gargs ++ over) k s'

-- ---------------------------------------------------------------------------
-- Case matching (deref the scrutinee handle, match over the NCon node)

matchAltsRC :: RCValue -> [Alt] -> RCScope -> RCKont -> Store
            -> Either RuntimeError RCConfig
matchAltsRC v alts sc k s = case v of
  RVBox addr -> do
    c <- deref addr s
    goNode (cNode c)
  RVLit l -> goLit l
  RVRecMember{} -> Left (NonExhaustiveCase (Tx.pack "<closure>"))
  RVInst _ _    -> Left (NonExhaustiveCase (Tx.pack "<instance>"))
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
nodeTag (NGroupCode _) = Tx.pack "<closure>"
nodeTag (NEnv _)       = Tx.pack "<env>"
nodeTag (NCont _ _)    = Tx.pack "<continuation>"
nodeTag (NContCell _)  = Tx.pack "<cont-cell>"

litText :: Lit -> Text
litText (LInt n)  = Tx.pack (show n)
litText (LStr str) = Tx.pack (show str)
litText (LChar c) = Tx.pack (show c)
litText LUnit     = Tx.pack "()"

renderJoin :: JoinId -> Text
renderJoin (JoinId (Unique i)) = Tx.pack "j" <> Tx.pack (show i)

-- ---------------------------------------------------------------------------
-- Answer-rebind (M2b-2 Task 5): the RC analogue of the reference
-- 'Wok.Interp.Machine.dispatchOp' 'answerRebind' local function.
--
-- When a handler sits in VALUE position ('hAnswerJoin = Just j'), its arms
-- deliver their results via 'jump j', so 'j' is the STATIC post-handler join.
-- On RESUME, the sub-run's answer must reach the RESUME CALL SITE (the @after@
-- continuation), not that static join. 'answerRebindRC' re-points @j@'s entry
-- so that, when the resumed sub-run completes and its return arm jumps to @j@,
-- the join body is now @Ret (AVar pb0)@ (identity: forward the single param)
-- and the join's own continuation is @after@ (the resume call site). The TOP-
-- LEVEL op arm keeps the ORIGINAL @hsc@ so the real post-handler work runs
-- once on the final answer.
--
-- INVARIANT: an answer-join is the single-result merge join that elaboration
-- creates for a value-position handler, so @ps@ is exactly one binder. The
-- @(pb0 : _)@ guard takes that binder; if a future change ever pointed
-- @hAnswerJoin@ at a many-param join the rebind is silently skipped rather
-- than misbinding (escape bug returns) --- keep answer-joins single-param.
--
-- RC ACCOUNTING: 'answerRebindRC' allocates NOTHING and frees NOTHING. It
-- only rewrites one 'RCJoin' value in the existing @rscJoins@ map. The new
-- 'RCJoin sc ...' captures the SAME @sc@ scope by reference (the same as the
-- original 'LetJoin' install did), so no incref is needed; the values in @sc@
-- are owned by their binders and released by the Perceus pass at last use.
answerRebindRC :: Handler -> RCKont -> RCScope -> RCScope
answerRebindRC h after sc =
  case hAnswerJoin h of
    Just j
      | Just (RCJoin _ ps _ _) <- Map.lookup j (rscJoins sc)
      , (pb0 : _) <- ps ->
          sc { rscJoins = Map.insert j
                 (RCJoin sc ps (Ret (AVar (bndName pb0))) after)
                 (rscJoins sc) }
    -- Intentional fallthrough: mirrors the reference 'answerRebind' (same silent
    -- no-op on hAnswerJoin = Nothing or a missing/empty-ps join). The empty-ps case
    -- is unreachable in elaborated code (the single-param answer-join invariant),
    -- and a missing join means the handler is tail-position (hAnswerJoin = Nothing),
    -- which is a correct no-op. Making this 'error' would diverge from the reference
    -- and break the differential oracle.
    _ -> sc

-- ---------------------------------------------------------------------------
-- Effect dispatch (M2b-1 Task 4): the RC analogue of the reference
-- 'Wok.Interp.Machine.dispatchOp'/'findHandler', threading the 'Store'.

-- | Walk outward from the operation's continuation to the nearest 'KHandleRC'
-- that covers @(label, op)@. Returns: a builder that re-prepends the frames ABOVE
-- the handler (the captured prefix), the matched handler, its activation tag, its
-- captured scope @hsc@, and the continuation BELOW the handler. Mirrors the
-- reference 'findHandler' over 'RCKont' (same ambient-vs-named 'instOk' routing).
rcFindHandler
  :: Maybe (Unique, Int) -> Text -> Text -> RCKont
  -> Maybe (RCKont -> RCKont, Handler, Int, RCScope, RCKont)
rcFindHandler mTarget lbl op = go id
  where
    go _   KDoneRC               = Nothing
    go acc (KLetRC b e sc k)     = go (acc . KLetRC b e sc) k
    go acc (KAppRC vs k)         = go (acc . KAppRC vs) k
    go acc (KDropCellRC a k)     = go (acc . KDropCellRC a) k
    go acc (KHandleRC h tag sc k)
      | matches h                = Just (acc, h, tag, sc, k)
      | otherwise                = go (acc . KHandleRC h tag sc) k
      where
        matches hh   = coversOp hh && instOk hh
        coversOp hh  = any (\a -> oaLabel a == lbl && oaOp a == op) (hOps hh)
        -- Ambient (Nothing) matches any covering handler; a named target matches
        -- only the handler whose self-binder Unique = u AND whose activation tag =
        -- t (so two activations of one runner site are told apart).
        instOk hh = case mTarget of
          Nothing     -> True
          Just (u, t) -> (nameUniq . bndName <$> hSelf hh) == Just u && tag == t

-- | The op arm of a handler matching @(label, op)@, if any. Mirrors the reference
-- 'Wok.Interp.Machine.lookupOpArm'.
lookupOpArmRC :: Text -> Text -> Handler -> Maybe OpArm
lookupOpArmRC lbl op h =
  case [ a | a <- hOps h, oaLabel a == lbl, oaOp a == op ] of
    (a : _) -> Just a
    []      -> Nothing

-- | An effect operation: find the nearest matching handler, CAPTURE the delimited
-- continuation above it CONCRETELY into a fresh 'NCont' cell, bind the op args and
-- the (boxed 'NCont') resume, and run the arm under the handler's below-
-- continuation. The RC analogue of the reference 'dispatchOp', threading the
-- 'Store'. Handler parameters and value-position handlers are admitted as of
-- M2b-2 Tasks 2-5; the answer-rebind for value-position handlers fires at RESUME
-- time in 'enterRC' ('answerRebindRC'), not here at dispatch.
--
-- CAPTURE ACCOUNTING (spec §4.3): the @above@ frames are MOVED into the 'NCont'
-- (rc = 1); NO incref of their children --- the values stay owned by their binders
-- inside the captured frames. On ABORT the op arm drops @resume@ and the 'NCont's
-- free runs its owned set ('cascadeChildren'); on RESUME the frames splice back and
-- the shell is discarded WITHOUT freeing the owned set.
rcDispatchOp
  :: Maybe (Unique, Int) -> Text -> Text -> [RCValue] -> RCKont -> Store
  -> Either RuntimeError RCConfig
rcDispatchOp mTarget lbl op vs kCur s =
  case rcFindHandler mTarget lbl op kCur of
    Nothing -> Left (NoMatchingHandler lbl op)
    Just (above, h, hTag, hsc, kBelow) ->
      case lookupOpArmRC lbl op h of
        Nothing -> Left (NoMatchingHandler lbl op)
        Just oa ->
          let prefix      = above KDoneRC
              (cAddr, s') = alloc (NCont prefix (h, hTag, hsc)) s
              env1 = bindRCBinders (oaArgs oa) vs (rscEnv hsc)
              env2 = bindRCBinder (oaResume oa) (RVBox cAddr) env1
          in Right (REval (oaBody oa) (RCScope env2 (rscJoins hsc)) kBelow s')

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
runModuleRC cm = do
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
  runModuleRCUnchecked cm

-- | The post-guard whole-module runner: identical to 'runModuleRC' but WITHOUT
-- the 'firstOrderNoHandlerViolations' boundary guard. 'runModuleRC' is exactly
-- @guard >> runModuleRCUnchecked@, so the two share one implementation and can
-- never drift. This is exposed so a TEST can drive an already-instrumented
-- module --- e.g. a consuming-capture group still refused by the boundary until
-- the escape-narrowing slice --- through the RC store and assert runtime
-- accounting (heap-empty oracle) directly. It is NOT a production entry point;
-- nothing in the compiler calls it. Callers are responsible for ensuring the
-- module is in the supported fragment.
runModuleRCUnchecked :: CoreModule -> Either RuntimeError RCRun
runModuleRCUnchecked (CoreModule binds) = do
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
      -- 5. Drop the result via its COUNTED children ('valueChildren'): an 'RVBox'
      --    releases its node, an 'RVRecMember' releases its shared 'NEnv', and a
      --    literal has none. 'dropAddr' no-ops on static/immortal addresses, so a
      --    static handle and a value-CAF result need no special-casing. Then read
      --    the final dynamic-heap stats.
      s3 <- foldM (flip dropAddr) s2 (valueChildren v)
      Right (RCRun txt (stStats s3) baseline)
    (TopBind{} : _) -> Left (ArityError (Tx.pack "main must take no arguments"))
    []              -> Left (UnboundVar (Tx.pack "main"))

-- | Pre-assign a static address to every top-level bind, returning: the knotted
-- env that maps each bind's 'Unique' to its static handle, the per-bind address
-- list (in bind order), and a store pre-loaded with one placeholder static cell
-- per bind. The placeholders are overwritten by 'installBinds' before 'main'
-- runs, so they are never observed.
reserveStatic :: [TopBind] -> (REnv, [Addr], Store)
reserveStatic = go (initSentinel emptyStore) Map.empty []
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
          let s' = writeStatic a (mkClosure knotEnv ps body) s
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
