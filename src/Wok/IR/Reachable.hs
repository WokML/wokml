-- | Reachable-bind pruning over the typed Core/ANF module.
--
-- 'elaborateProgramFull' inlines the whole prelude; the RC interpreter
-- force-evaluates every value-CAF at load time, including dictionary CAFs that
-- bottom out in prims the RC store does not bind. Keeping only the binds
-- reachable from 'main' is a semantics-preserving dead-bind elimination (a bind
-- never reached from 'main' cannot influence its result) and lets the RC
-- interpreter run the handler-free corpus cleanly.
--
-- This is the SINGLE source of truth shared by the @wok@ CLI
-- (@--dump-rc-stats@ / @--dump-perceus@) and the Suite A/B test harness, so the
-- bytes they produce cannot silently drift.
module Wok.IR.Reachable
  ( pruneToReachable
  , reachableBinds
  , bindReferencedUniques
  , exprUniques
  , firstOrderNoHandlerViolations
  , exprScopeFeatures
  , m2bHandlerViolations
  ) where

import Data.List (find, nub)
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as Tx

import qualified Wok.IR.Anf as Anf
import qualified Wok.IR.Name as Name
import Wok.IR.Name (Unique)
import Data.Maybe (isNothing)
import Wok.IR.Escape
  ( isBoxedType, letRecMemberConsumesCaptureNonEscaping
  , rawEnclosingFv, m2bResumeEscapes )

-- | Semantics-preserving dead-bind elimination: keep only the binds reachable
-- from 'main' (preserving bind order). A bind never reached from 'main' cannot
-- influence main's result, so dropping it leaves observable behaviour unchanged.
pruneToReachable :: Anf.CoreModule -> Anf.CoreModule
pruneToReachable cm@(Anf.CoreModule binds) =
  let keep = Set.fromList (map (Name.nameUniq . Anf.tbName) (reachableBinds cm))
  in Anf.CoreModule
       [ tb | tb <- binds, Name.nameUniq (Anf.tbName tb) `Set.member` keep ]

-- | The set of top-level binds reachable from 'main' through the call graph
-- (variable references in bodies, treated as edges). Conservative: any
-- referenced 'Unique' that names a top-level bind is followed.
reachableBinds :: Anf.CoreModule -> [Anf.TopBind]
reachableBinds (Anf.CoreModule binds) =
  case find (\tb -> Name.nameHint (Anf.tbName tb) == Tx.pack "main") binds of
    Nothing       -> []   -- no main: nothing to reach
    Just mainBind ->
      let byUniq = Map.fromList [ (Name.nameUniq (Anf.tbName tb), tb) | tb <- binds ]
          go seen [] = seen
          go seen (u : rest)
            | u `Set.member` seen = go seen rest
            | otherwise =
                case Map.lookup u byUniq of
                  Nothing -> go seen rest   -- a local/prim Unique, not a bind
                  Just tb ->
                    let refs  = bindReferencedUniques tb
                        seen' = Set.insert u seen
                    in go seen' (Set.toList refs ++ rest)
          reached = go Set.empty [Name.nameUniq (Anf.tbName mainBind)]
      in [ tb | tb <- binds, Name.nameUniq (Anf.tbName tb) `Set.member` reached ]

-- | Every 'Unique' that appears as a variable reference inside a bind's body.
bindReferencedUniques :: Anf.TopBind -> Set.Set Unique
bindReferencedUniques tb = exprUniques (Anf.tbBody tb)

-- | Every 'Unique' appearing as a variable reference anywhere in an expression.
-- Binder introductions are included too; they cannot create spurious bind edges
-- because top-level bind Uniques are globally unique.
exprUniques :: Anf.Expr -> Set.Set Unique
exprUniques = goE
  where
    av (Anf.AVar n) = Set.singleton (Name.nameUniq n)
    av (Anf.ALit _) = Set.empty
    avs = Set.unions . map av
    goR r = case r of
      Anf.RAtom a          -> av a
      Anf.RApp f xs        -> Set.union (av f) (avs xs)
      Anf.RCon _ xs        -> avs xs
      Anf.RLam _ e         -> goE e
      Anf.ROp minst _ _ xs -> Set.union (maybe Set.empty av minst) (avs xs)
      Anf.RRecord _ flds   -> avs (map snd flds)
      Anf.RProj _ a        -> av a
    goA a = case a of
      Anf.AltCon _ _ e -> goE e
      Anf.AltLit _ e   -> goE e
      Anf.AltDefault e -> goE e
    goE e = case e of
      Anf.Ret a               -> av a
      Anf.Let _ r body        -> Set.union (goR r) (goE body)
      Anf.LetRec defs body    -> Set.unions (goE body : [ goE d | (_, _, d) <- defs ])
      Anf.Case a alts         -> Set.union (av a) (Set.unions (map goA alts))
      Anf.LetJoin _ _ jb body -> Set.union (goE jb) (goE body)
      Anf.Jump _ xs           -> avs xs
      Anf.Handle inner h      ->
        Set.union (goE inner)
          (Set.unions
             ( goE (snd (Anf.hReturn h))
             : [ goE (Anf.oaBody op) | op <- Anf.hOps h ] ))

-- | Handler-free scope guard. Returns a (possibly empty) list of human-readable
-- violations: a program is in scope for the RC interpreter iff every top-level
-- bind REACHABLE FROM 'main' is handler-free (no 'Handle'/'ROp'). Closures
-- ('RLam') are permitted as of M1.5. Effect handlers are deferred to a later
-- milestone. Scoping the check to the reachable call graph (not the whole
-- elaborated module) is deliberate: 'elaborateProgramFull' inlines the entire
-- prelude (which DOES contain handlers and lambdas), but none of it is reached
-- by a handler-free corpus 'main', so it never executes on the RC store.
firstOrderNoHandlerViolations :: Anf.CoreModule -> [Text]
firstOrderNoHandlerViolations cm =
  [ describe tb feature
  | tb <- reachableBinds cm
    -- Seed the enclosing boxed-local scope with the bind's boxed PARAMS so a
    -- LetRec capturing-and-escaping a top-level param is also rejected (Part B).
  , feature <- exprScopeFeaturesWith
                 (Set.fromList [ Anf.binderUnique b
                               | b <- Anf.tbParams tb, isBoxedType (Anf.bndType b) ])
                 (Anf.tbBody tb)
  ]
  where
    describe tb feature =
      Tx.pack "  bind '" <> Name.nameHint (Anf.tbName tb)
        <> Tx.pack "' uses " <> feature

-- | Out-of-scope features used directly in an expression: 'Handle' (effect
-- handler), 'ROp' (effect operation), and the two residual 'LetRec' deferrals
-- (consuming captures #1, cross-region #3; see the block below). Returns a
-- de-duplicated list of feature names. An ordinary 'RLam' (first-class closure) is
-- in scope as of M1.5 and is no longer reported; its body is still recursed into so
-- a 'Handle'/'ROp' nested inside a lambda body is still surfaced.
--
-- =================== M2a-2 (LetRec escape now ADMITTED) =====================
-- A 'LetRec' group member that ESCAPES its scope --- captured into a standalone
-- closure ('RLam'), moved into a constructor/record/list, passed as a non-head
-- call argument, aliased, or returned directly --- is now ADMITTED and soundly
-- instrumented, EVEN when the group also captures an enclosing boxed local. The
-- group is one shared 'NEnv' cell plus inline @RVRecMember@ handles (M2a-2 runtime,
-- 'Wok.Interp.RC.{Value,Machine}'); the Perceus pass dup-balances EVERY escaping
-- member occurrence (a build-site @__rc_dup@ of the shared env on a move into a
-- cell/closure; a single-handle transfer-out on a bare alias / direct return, via
-- env-alias propagation), and the interpreter keeps an unnamed-intermediate handle
-- alive through its own call (deferred env-drop, 'KDropCellRC'). So the captured
-- enclosing local is freed exactly once via the env cascade when the last escaped
-- reference drops --- no leak, no double-free. The earlier M1.5/M2a-1 sibling-escape
-- and Part-B enclosing-capture-escape rejections are therefore RETIRED.
--
-- The ONLY 'LetRec' rejections that remain are the genuinely-deferred classes:
--   * CONSUMING captures (#1, 'letRecMemberConsumesCaptureNonEscaping'): a member that MOVES
--     (rather than borrows) an enclosing capture --- still needs borrow-passing.
--   * CROSS-REGION (#3, 'rawEnclosingFv' ∩ outer group): a member that captures an
--     OUTER 'LetRec' group's member.
--   * NESTED CAPTURING GROUP: a group nested inside an enclosing 'LetRec' member
--     body that captures a boxed local bound OUTSIDE that enclosing member (the
--     "member-outer boxed set", 'rawEnclosingFv' ∩ @mob@). That local then lives in
--     BOTH the outer member's 'NEnv' and the inner group's 'NEnv' --- two cascades,
--     one incref --- a double-free. A FLAT (non-nested) group capturing an enclosing
--     local is sound (one env, one cascade) and stays admitted; so are a nested group
--     that captures only a PER-ENTRY local bound inside the enclosing member body, and
--     a nested group sitting inside a lambda body (a fresh frame). See @mob@ below.
-- Both are checked at the 'LetRec' node ('go' below); see the design doc
-- docs/superpowers/specs/2026-06-15-m2a-2-shared-env-recursive-closures-design.md.
-- ===========================================================================
exprScopeFeatures :: Anf.Expr -> [Text]
exprScopeFeatures = exprScopeFeaturesWith Set.empty

-- | As 'exprScopeFeatures', but with the enclosing BOXED-LOCAL 'Unique's already
-- in scope on entry (the bind's boxed params) so a 'LetRec' capturing-and-escaping
-- a top-level param is also caught (Part B).
exprScopeFeaturesWith :: Set.Set Unique -> Anf.Expr -> [Text]
exprScopeFeaturesWith bsc0 = nub . go Set.empty Set.empty bsc0
  where
    boxedBs bs = [ Anf.binderUnique b | b <- bs, isBoxedType (Anf.bndType b) ]
    -- @mob@ = the MEMBER-OUTER BOXED SET: a SNAPSHOT of the boxed locals that were
    --         in scope at the boundary of the enclosing 'LetRec' MEMBER BODY we are
    --         currently inside --- i.e. the boxed locals bound OUTSIDE that member.
    --         A group nested in the member body that captures one of these locals
    --         double-frees it: the local then lives in BOTH the outer member's 'NEnv'
    --         and the inner group's 'NEnv' (two cascades, one incref). @mob@ is set to
    --         the then-current @bsc@ when descending into a def RHS, and is EMPTY
    --         outside any member body. Boxed locals bound INSIDE the member body
    --         (subsequent 'Let's, alt binders, join-point params) are added to @bsc@
    --         but NOT to @mob@, so capturing a PER-ENTRY local does not trip the guard
    --         (it is rebuilt per entry alongside the inner env --- one cascade, sound).
    --         Crossing an 'RLam' body RESETS @mob@ to empty: a lambda body is a fresh
    --         frame (like a call frame), so a group nested inside a lambda that sits in
    --         a member body is sound (the same group is sound at top level).
    -- @lr@  = the 'LetRec' group-binder Uniques currently in scope.
    -- @bsc@ = the enclosing BOXED-LOCAL Uniques in scope (kept threaded for the
    --         cross-region / consuming-capture / nested-capture checks at the
    --         'LetRec' node).
    -- M2a-2 Stage B retired the sibling-escape / Part-B enclosing-capture-escape
    -- rejections (every escaping member occurrence is now dup-balanced by the pass),
    -- so the 'Let' case carries no sibling-escape violation; only the 'LetRec' node's
    -- cross-region (#3), consuming-capture (#1), and nested-capture rejections remain.
    rhs _mob lr bsc r = case r of
      -- A lambda body is a fresh frame: reset the member-outer set to empty so a
      -- nested group inside it is treated like one at top level (it is sound).
      Anf.RLam _ b         -> go Set.empty lr bsc b
      Anf.ROp{}            -> []
      Anf.RApp _ _         -> []
      Anf.RAtom _          -> []
      Anf.RCon _ _         -> []
      Anf.RRecord _ _      -> []
      Anf.RProj _ _        -> []
    alt mob lr bsc a = case a of
      Anf.AltCon _ bs b -> go mob lr (Set.union bsc (Set.fromList (boxedBs bs))) b
      Anf.AltLit _ b    -> go mob lr bsc b
      Anf.AltDefault b  -> go mob lr bsc b
    go mob lr bsc x = case x of
      Anf.Ret _               -> []
      Anf.Let b r body        ->
        let bsc' = if isBoxedType (Anf.bndType b)
                     then Set.insert (Anf.binderUnique b) bsc else bsc
            -- ALIAS-RENAME of a member-outer local is STILL member-outer. A pure
            -- rename @let ba = b@ does NOT allocate a fresh cell --- @ba@ names the
            -- SAME cell as the outside-bound @b@. A nested group capturing @ba@ would
            -- double-free exactly as one capturing @b@. So the new binder JOINS @mob@
            -- whenever its RHS aliases a name already in @mob@. (A 'RCon'/'RProj'/
            -- 'RApp' RHS allocates / yields a fresh per-entry cell --- sound --- so it
            -- does NOT propagate @mob@; only the same-cell 'RAtom' rename does.)
            mob' = case r of
              Anf.RAtom (Anf.AVar n)
                | Name.nameUniq n `Set.member` mob ->
                    Set.insert (Anf.binderUnique b) mob
              _ -> mob
            -- M2a-2 STAGE B (widened): a 'Let'-RHS that captures a 'LetRec' group
            -- sibling in an escaping position --- a standalone closure ('RLam'), a
            -- constructor/record/list field, a non-head call argument, a projection
            -- parent, or a bare alias --- is now ADMITTED whether it escapes or stays
            -- local. The pass dup-balances EVERY escaping member occurrence: a
            -- closure/con/record/list/call-arg move emits a build-site @__rc_dup@ of
            -- the shared env (dup-on-consume), and an escaping bare alias / direct
            -- member return transfers the single env handle out (the scope's env-alive
            -- handle is then NOT also dropped; env-alias propagation, 'Wok.IR.Perceus').
            -- The interpreter keeps an unnamed-intermediate handle's env alive through
            -- its own call (deferred env-drop, 'KDropCellRC'). So a sibling-capture
            -- escape is sound regardless of mechanism, and the 'Let' case raises no
            -- violation. Only CONSUMING captures (#1) and CROSS-REGION (#3) remain
            -- rejected, at the 'LetRec' node below.
        in rhs mob lr bsc r ++ go mob' lr bsc' body
      Anf.LetRec defs body    ->
        let lr' = Set.union lr (Set.fromList [ Anf.binderUnique b | (b, _, _) <- defs ])
            -- PART B retired (M2a-2 Stage B). A group that captures an enclosing
            -- boxed local AND has an escaping member --- by ANY mechanism (closure,
            -- con/record/list, call argument, bare alias, or direct return) --- is now
            -- ADMITTED. The pass dup-balances every escaping member occurrence against
            -- the shared env (dup-on-consume for moves into cells/closures; single-
            -- handle transfer for bare returns), and the interpreter keeps an
            -- unnamed-intermediate handle's env alive through its own call. The escape
            -- is therefore sound; the group's captured enclosing local is freed exactly
            -- once via the env cascade when the last escaped reference drops. The ONLY
            -- residual 'LetRec' rejections are CONSUMING captures (#1, 'consumeViol')
            -- and CROSS-REGION (#3, 'crossRegionViol') below.
            -- FINDING 2 (Phase 2 review, verified LEAK): a member that captures an
            -- OUTER LetRec region member (cross-region counted edge) is EXCLUDED
            -- from coverage by the pass ('capturesRegion', spec 5.5) but was passed
            -- through UN-instrumented => leak. Reject it (use the pre-group @lr@:
            -- the OUTER region binders, not this group's own).
            crossRegionViol
              | not (Set.null (Set.intersection (rawEnclosingFv defs) lr)) =
                  [Tx.pack "LetRec member captures an outer LetRec region member \
                           \(cross-region, spec 5.5, deferred to a later slice)"]
              | otherwise = []
            -- NESTED CAPTURING GROUP (M2a-2, verified DOUBLE-FREE). A 'LetRec'
            -- group that is NESTED inside an enclosing 'LetRec' MEMBER BODY AND
            -- captures a boxed local bound OUTSIDE that enclosing member --- a boxed
            -- free var in the MEMBER-OUTER BOXED SET @mob@ (@rawEnclosingFv defs ∩
            -- mob@, NOT @∩ lr@ which is the cross-region #3 check above, and NOT @∩
            -- bsc@ which would also catch SOUND per-entry locals bound inside the
            -- member). Such a local lives in BOTH the enclosing member's 'NEnv' and
            -- the inner group's 'NEnv' --- two cascades on drop, but only one incref
            -- backing the capture (it is treated as borrowed/moved-once), so it is
            -- freed twice. THREE shapes are correctly ADMITTED because they are NOT
            -- in @mob@: a FLAT group (top-level / non-member scope, @mob@ empty)
            -- capturing an enclosing local (one env, one cascade); a nested group
            -- capturing only a PER-ENTRY local bound INSIDE the enclosing member body
            -- (rebuilt per entry alongside the inner env --- one cascade); and a
            -- nested group inside a lambda body (a fresh frame resets @mob@).
            nestedCaptureViol
              | not (Set.null (Set.intersection (rawEnclosingFv defs) mob)) =
                  [Tx.pack "nested LetRec group captures a local bound outside the \
                           \enclosing LetRec member; the local lives in both the \
                           \member's env and the inner group's env (two cascades, one \
                           \incref) --- nested capturing groups deferred"]
              | otherwise = []
            -- CONSUMING captures (M2a-2 capture-escape generalised). The pass now
            -- DUP-BALANCES every move of a borrowed enclosing capture: a build-site
            -- @__rc_dup@ on a move into a con/record/list field, a non-head call
            -- argument, or a closure cell ('moveOperandUniques'), AND a @__rc_dup@ on
            -- a return / jump that ESCAPES the capture (the generalised 'Ret'/'Jump'
            -- escape-dup, 'Wok.IR.Perceus'). So a member body that ESCAPES a borrowed
            -- capture (returns it, seals it into a con/record/list, or passes it as a
            -- non-head call argument) is ADMITTED and sound --- the escaped handle
            -- increfs the captured cell, and the env's capture-field cascade frees the
            -- env-owned unit exactly once at scope exit.
            --
            -- The residual consuming-capture rejection is a capture consumed LOCALLY
            -- ('letRecMemberConsumesCaptureNonEscaping'): sealed into a con/record that
            -- is destructured-and-dropped within the body, projected, or matched by a
            -- child-keeping 'Case'. That is the genuinely-deferred #1 class (the
            -- two-member-both-base-consume counterexample); the broader borrow-passing
            -- that admits it for all call patterns is deferred. A capture used only as a
            -- borrowed read or a call head (saturated OR partial --- a borrow under
            -- uniform borrow-on-call) is unaffected (it was never unsound).
            consumeViol
              | letRecMemberConsumesCaptureNonEscaping defs bsc =
                  [Tx.pack "LetRec member consumes an enclosing capture LOCALLY (sealed \
                           \into a destructured-and-dropped cell, projected, or matched \
                           \by a child-keeping case); only borrowed reads and escapes are \
                           \supported (local consume deferred --- needs borrow-passing)"]
              | otherwise = []
        in crossRegionViol ++ consumeViol ++ nestedCaptureViol
             -- A def RHS is a MEMBER BODY: SNAPSHOT the current @bsc@ as the
             -- member-outer boxed set so a 'LetRec' nested inside it that captures a
             -- local bound OUTSIDE this member is rejected. Locals bound INSIDE the
             -- member body extend @bsc@ but not this snapshot, so a per-entry capture
             -- is sound. The continuation BODY is NOT a member body: it inherits @mob@
             -- unchanged (a group there runs once, so a re-capture is sound).
             ++ concat [ go bsc lr' bsc d | (_, _, d) <- defs ]
             ++ go mob lr' bsc body
      Anf.Case _ alts         -> concatMap (alt mob lr bsc) alts
      Anf.LetJoin _ ps jb body ->
        let bsc' = Set.union bsc (Set.fromList (boxedBs ps))
        in go mob lr bsc' jb ++ go mob lr bsc body
      Anf.Jump _ _            -> []
      Anf.Handle inner h      ->
        m2bHandlerViolations h
          -- M2b-1 (verified UAF, full-branch review): a handler whose return/op arm
          -- references an enclosing BOXED LOCAL is DEFERRED and must be rejected. The
          -- arm is instrumented as a fresh owned scope (it does NOT account the enclosing
          -- capture), while the enclosing handler-body still drops that local --- so when
          -- an op fires and the arm consumes the local (moves it into a con, returns it,
          -- or passes it to resume), it is freed twice (the arm's flow through 'kBelow'
          -- hits the handler-body drop). 'continuationOwned' processes only the captured
          -- ABOVE frames, not the handler scope (spec 4.2), so the abort path UAFs too;
          -- both abort and tail-resume miscompile. Reject conservatively. @bsc@ is the
          -- enclosing boxed-local set; 'Anf.freeVarsHandler' is the arms' free vars minus
          -- their own binders and hParam/hSelf, so the intersection is exactly the captured
          -- boxed enclosing locals. (Unboxed captures like a 'Reader U64' constant are NOT
          -- in @bsc@, so Reader/Tick/Except stay admitted.)
          ++ [ Tx.pack "effect handler whose arm captures an enclosing boxed local \
                       \(handler scope not owned-set-processed; double-frees on abort and \
                       \tail-resume) --- deferred to M2b-2/M3"
             | not (Set.null (Anf.freeVarsHandler h `Set.intersection` bsc)) ]
          ++ go mob lr bsc inner
          ++ go Set.empty lr bsc (snd (Anf.hReturn h))
          ++ concat [ go Set.empty lr bsc (Anf.oaBody op) | op <- Anf.hOps h ]

-- | Precise violation messages for a handler that is OUTSIDE the M2b-1
-- fragment.  Derived from the SAME conditions as 'm2bHandlerInFragment' so
-- guard emptiness and the predicate agree.
m2bHandlerViolations :: Anf.Handler -> [Text]
m2bHandlerViolations h =
  [ Tx.pack "effect handler with a handler-parameter (M2b-2; not yet on the RC store)"
  | not (isNothing (Anf.hParam h)) ]
  ++ [ Tx.pack "effect handler in value (non-tail) position (M2b-2)"
     | not (isNothing (Anf.hAnswerJoin h)) ]
  ++ [ Tx.pack "effect op arm whose resume ESCAPES its body (first-class/stored continuation; M3)"
     | oa <- Anf.hOps h, m2bResumeEscapes (Anf.oaResume oa) (Anf.oaBody oa) ]
