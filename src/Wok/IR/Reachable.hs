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
  ) where

import Data.List (find, nub)
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as Tx

import qualified Wok.IR.Anf as Anf
import qualified Wok.IR.Name as Name
import Wok.IR.Name (Unique)
import Wok.IR.Perceus
  ( isBoxedType, letRecEnclosingCaptureEscapes, letRecMemberConsumesCapture
  , rawEnclosingFv )

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
-- handler), 'ROp' (effect operation), and one closure/region interaction (see
-- the loud TODO below). Returns a de-duplicated list of feature names. An
-- ordinary 'RLam' (first-class closure) is in scope as of M1.5 and is no longer
-- reported; its body is still recursed into so a 'Handle'/'ROp' nested inside a
-- lambda body is still surfaced.
--
-- ============================ TODO(M1.5 Phase 2) ============================
-- A STANDALONE 'RLam' that captures a 'LetRec' GROUP SIBLING is REJECTED here
-- rather than miscompiled. The hazard (found by the Phase 1 full-branch review,
-- verified double-free):
--
--   * the Perceus pass treats a sibling capture as EXEMPT (the uncounted region
--     owns it; the group drop releases it once), so it moves nothing into the
--     closure cell; but
--   * the RC interpreter captures the sibling's region handle into the closure's
--     env, so the cell's drop-cascade ALSO decrefs it. 'enterRC's incref-on-call
--     cancels that cascade ONLY when the closure is actually CALLED; on the
--     drop-without-call path there is no incref, so the sibling is freed twice
--     (cell cascade + group drop) => double-free.
--
-- A correct fix needs the closure representation to distinguish OWNED captures
-- (cascade-free) from BORROWED region-sibling captures (do not), AND must handle
-- the ESCAPING case (a closure that outlives its 'LetRec' scope forces the
-- sibling to leave the uncounted region and become genuinely counted). That is
-- region/closure co-design --- Phase 2 (LetRec enclosing-capture) territory and
-- beyond. Until then we REFUSE (sound) rather than compile it wrong. See
-- docs/superpowers/specs/2026-06-14-m1.5-closures-perceus-design.md (Phase 2).
--
-- ============================ TODO(M1.5 Phase 2) ============================
-- PART B (the ESCAPING enclosing-capture). A 'LetRec' group that BOTH captures an
-- enclosing BOXED LOCAL and has a member that ESCAPES the group body (its binder
-- flows out as a VALUE --- the result, or a field/arg/closure-capture that escapes)
-- is REJECTED here rather than miscompiled. The Perceus pass's borrow-model
-- accounting (spec 5.2) balances only when the group drops as a UNIT at scope exit;
-- an escaped member is NOT dropped at scope exit, so its captured enclosing local
-- LEAKS (and a sibling dropped at scope exit dangles under the escaped member's
-- still-live knot). Proper support (region-lifetime extension past scope exit) is
-- deferred with the 5.7 representation work. The escape predicate is SHARED with
-- the pass's coverage condition ('Wok.IR.Perceus.letRecEnclosingCaptureEscapes'),
-- so the boundary refuses EXACTLY the groups the pass excludes from coverage. See
-- spec sections 5.1 and 5.7.
-- ===========================================================================
exprScopeFeatures :: Anf.Expr -> [Text]
exprScopeFeatures = exprScopeFeaturesWith Set.empty

-- | As 'exprScopeFeatures', but with the enclosing BOXED-LOCAL 'Unique's already
-- in scope on entry (the bind's boxed params) so a 'LetRec' capturing-and-escaping
-- a top-level param is also caught (Part B).
exprScopeFeaturesWith :: Set.Set Unique -> Anf.Expr -> [Text]
exprScopeFeaturesWith bsc0 = nub . go Set.empty bsc0
  where
    boxedBs bs = [ Anf.binderUnique b | b <- bs, isBoxedType (Anf.bndType b) ]
    -- @lr@  = the 'LetRec' group-binder Uniques currently in scope (sibling-capture
    --         rejection, Part A precedent).
    -- @bsc@ = the enclosing BOXED-LOCAL Uniques in scope (Part B escape check).
    rhs lr bsc r = case r of
      Anf.RLam ps b ->
        let caps = Anf.freeVarsExpr b
                     `Set.difference` Set.fromList (map Anf.binderUnique ps)
        in (if Set.null (Set.intersection caps lr)
              then []
              else [Tx.pack "RLam capturing a LetRec sibling \
                            \(closure-over-local-recursive-group RC deferred to M1.5 Phase 2)"])
           ++ go lr bsc b
      Anf.ROp{}            -> [Tx.pack "ROp (effect operation)"]
      Anf.RApp _ _         -> []
      Anf.RAtom _          -> []
      Anf.RCon _ _         -> []
      Anf.RRecord _ _      -> []
      Anf.RProj _ _        -> []
    alt lr bsc a = case a of
      Anf.AltCon _ bs b -> go lr (Set.union bsc (Set.fromList (boxedBs bs))) b
      Anf.AltLit _ b    -> go lr bsc b
      Anf.AltDefault b  -> go lr bsc b
    go lr bsc x = case x of
      Anf.Ret _               -> []
      Anf.Let b r body        ->
        let bsc' = if isBoxedType (Anf.bndType b)
                     then Set.insert (Anf.binderUnique b) bsc else bsc
        in rhs lr bsc r ++ go lr bsc' body
      Anf.LetRec defs body    ->
        let lr' = Set.union lr (Set.fromList [ Anf.binderUnique b | (b, _, _) <- defs ])
            -- PART B: refuse a group that captures an enclosing boxed local AND has
            -- an escaping member (shared predicate with the pass's coverage).
            escapeViol
              | letRecEnclosingCaptureEscapes defs body bsc =
                  [Tx.pack "LetRec member captures an enclosing local AND escapes \
                           \(region-lifetime extension deferred to M1.5 Phase 2)"]
              | otherwise = []
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
            -- FINDING 1 (Phase 2 review, verified DOUBLE-FREE): a member that
            -- CONSUMES (moves) an enclosing capture is EXCLUDED from coverage by the
            -- pass ('consumes', spec 5.3) but was passed through un-instrumented and
            -- double-freed at the group drop. Reject it (only borrowed reads are
            -- supported). Shared predicate with the pass's coverage condition.
            consumeViol
              | letRecMemberConsumesCapture defs bsc =
                  [Tx.pack "LetRec member consumes (moves) an enclosing capture; only \
                           \borrowed reads are supported (dup-per-consuming-use \
                           \deferred to a later slice)"]
              | otherwise = []
        in escapeViol ++ crossRegionViol ++ consumeViol
             ++ concat [ go lr' bsc d | (_, _, d) <- defs ]
             ++ go lr' bsc body
      Anf.Case _ alts         -> concatMap (alt lr bsc) alts
      Anf.LetJoin _ ps jb body ->
        let bsc' = Set.union bsc (Set.fromList (boxedBs ps))
        in go lr bsc' jb ++ go lr bsc body
      Anf.Jump _ _            -> []
      Anf.Handle _ _          -> [Tx.pack "Handle (effect handler)"]
