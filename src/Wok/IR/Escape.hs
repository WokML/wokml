-- | Escape / borrowership analysis over wok ANF --- the SINGLE source of truth
-- for the M1.5/M2a-1 closure-and-region escape predicates.
--
-- The notion of an ESCAPING position (a tracked variable occurring as an atom in
-- a NON-CALL-HEAD position) was previously encoded in several places that had to
-- be kept in sync (the per-RHS non-head occurrence collector, the alias-following
-- escape walker, and the boundary guard's @rhsCapturesSibling@). Two prior
-- use-after-free bugs traced to those sites drifting apart. This module
-- CONSOLIDATES them: every escape decision flows from one position-enumeration
-- function, 'escapingAtomsRhs' (see the comment there). Adding a new 'Rhs' form
-- requires editing exactly that one function.
--
-- The TWO alias-following walkers --- the general 'escapesFrom' (any non-call-head
-- occurrence escapes) and the return-value-only 'captureEscapesBody' (only a value
-- flowing OUT as the member's result escapes) --- formerly each hand-rolled their own
-- per-'Rhs' case table, re-opening exactly that drift (and 'captureEscapesBody'
-- silently defaulted a missed form to "does not escape", gating an unsound consume
-- admit). They now BOTH derive from one shared traversal, 'escapeWalk', parameterised
-- by a per-'Let'-'Rhs' policy ('RhsStep') and a 'Case'-scrutinee-escapes flag. The
-- policies are the ONLY place the two walkers differ; a new 'Rhs' form is handled in
-- 'escapingAtomsRhs' (which 'escapesFrom' reuses) and, where the return-value
-- restriction needs it, in 'captureEscapesBody's policy --- the traversal itself is
-- never duplicated.
--
-- This module depends only on 'Wok.IR.Anf' (and base/containers), so both
-- 'Wok.IR.Perceus' and 'Wok.IR.Reachable' import it with no cycle.
module Wok.IR.Escape
  ( -- * Boxed-ness (the reference-counting predicate, used by the escape rules)
    isBoxedType
  , boxedBinder
    -- * The single source of truth for escaping (non-call-head) positions
  , escapingAtomsRhs
  , nonHeadOccsRhs
  , nonHeadOccs
  , dropTargets
    -- * LetRec / closure escape + consume predicate family
  , escapesFrom
  , rlamSiblingCaptureEscapes
  , letRecCapturesEnclosing
  , letRecEnclosingCaptures
  , letRecMemberEscapes
  , letRecEnclosingCaptureEscapes
  , letRecMemberConsumesCaptureNonEscaping
  , captureEscapesBody
  , consumingOccs
  , rawEnclosingFv
    -- * M2b-1 handler-fragment predicates
  , m2bResumeEscapes
  , m2bHandlerInFragment
  ) where

import Data.Set (Set)
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as Tx
import Wok.IR.Anf
  ( Alt (..), Atom (..), Binder (..), Expr (..), Handler (..), OpArm (..)
  , Rhs (..)
  , freeVarsExpr, atomVars, binderUnique, bndType )
import Wok.IR.Name (Name (..), Unique)
import Wok.TypeChecking.Types (CType (..), TyCon (..))

-- ---------------------------------------------------------------------------
-- The RC intrinsic names
--
-- The escape rules treat an inserted RC intrinsic call (@__rc_dup x@ /
-- @__rc_drop x@) as NON-escaping, so they may run on an already-instrumented
-- module. These MUST match the hint keys used by 'Wok.IR.Perceus'
-- (and 'Wok.Interp.RC.Prim.rcPrimTable').

dupHint, dropHint :: Text
dupHint  = Tx.pack "__rc_dup"
dropHint = Tx.pack "__rc_drop"

-- ---------------------------------------------------------------------------
-- Boxed-ness
--
-- A value is reference-counted iff its type is BOXED. Unboxed scalars live
-- inline and are never counted.

-- | True iff a value of this type is heap-allocated (and so reference-counted).
isBoxedType :: CType -> Bool
-- UNBOXED iff the value is an 'RVLit' in the RC interpreter -- i.e. exactly the
-- literal types: U64/U32/Char/Unit/String/Never. These live inline and are
-- never reference-counted (a literal resolves to 'RVLit', and __rc_dup/__rc_drop
-- are no-ops on it).
isBoxedType (CTCon TcU64    []) = False
isBoxedType (CTCon TcU32    []) = False
isBoxedType (CTCon TcChar   []) = False
isBoxedType (CTCon TcUnit   []) = False
isBoxedType (CTCon TcString []) = False
isBoxedType (CTCon TcNever  []) = False
-- Bool is BOXED: the RC interpreter has no scalar boolean -- it allocates a
-- nullary constructor cell (NCon True/False, an RVBox) for every Bool (see
-- 'Wok.Interp.RC.Prim' allocBool/cmp/boolOp). The pass MUST agree with that
-- value rep, so a Bool is reference-counted like any other constructor.
isBoxedType (CTCon TcBool   []) = True
-- Lists, tuples, user constructors/records, functions/closures, and type
-- variables are all boxed.
isBoxedType _                   = True

-- | True iff this binder names a boxed (reference-counted) value.
boxedBinder :: Binder -> Bool
boxedBinder = isBoxedType . bndType

-- ---------------------------------------------------------------------------
-- The single source of truth for ESCAPING (non-call-head) positions
--
-- An atom occurrence ESCAPES iff it is NOT the head @f@ of a saturated call
-- @RApp f as@. Everything else (operands/fields/captures/results/scrutinees/
-- arguments) escapes. This ONE function enumerates those positions; every escape
-- predicate below derives from it (per-RHS step), so there is a single place to
-- maintain.

-- | SINGLE SOURCE OF TRUTH FOR ESCAPING POSITIONS --- add new RHS forms here only.
--
-- The atoms of a RHS that sit in an ESCAPING (non-call-head) position. The head
-- @f@ of @RApp f as@ is the ONLY exempt position (a saturated call does not move
-- the value out of the callee); every other operand/field/argument occurrence
-- escapes. An 'RLam' contributes its captures as synthetic @AVar@s (free vars of
-- the body minus the lambda's own params), because a value captured into a
-- closure cell outlives the build site.
--
-- ONE exception: an inserted RC intrinsic call (@__rc_dup x@ / @__rc_drop x@)
-- contributes NO escaping atom. The predicates may be evaluated on an ALREADY-
-- instrumented module (the RC interpreter gates on the instrumented IR), where a
-- group's scope-exit @__rc_drop f@ would otherwise read the member @f@ as an
-- RApp argument and falsely flag it as escaping --- but that drop is exactly the
-- unit-scope release that proves the value does NOT escape.
escapingAtomsRhs :: Rhs -> [Atom]
escapingAtomsRhs (RAtom a)        = [a]
escapingAtomsRhs (RApp (AVar h) _)
  | nameHint h == dupHint || nameHint h == dropHint = []
escapingAtomsRhs (RApp _ as)      = as                          -- head EXEMPT
escapingAtomsRhs (RCon _ as)      = as
escapingAtomsRhs (RRecord _ flds) = map snd flds
escapingAtomsRhs (RProj _ a)      = [a]
escapingAtomsRhs (ROp m _ _ as)   = maybe as (: as) m
escapingAtomsRhs (RLam ps e)      =
  -- A value captured into a nested lambda ESCAPES (it outlives the build site
  -- inside the closure cell). EVERY free occurrence in the body counts --- even a
  -- bare call head: a var used only as a call head inside the nested lambda still
  -- rides out in the cell, so we must NOT recurse for in-body non-head occs. The
  -- lambda's own params shadow nothing of the outer scope (fresh Uniques).
  [ AVar (Name (Tx.pack "") u)
  | u <- Set.toList (freeVarsExpr e
                       `Set.difference` Set.fromList (map binderUnique ps)) ]

-- | The watched 'Unique's that appear in an ESCAPING position in a RHS. Derived
-- from 'escapingAtomsRhs' (the single source of truth) --- @watched@ filters the
-- escaping atoms to the tracked set.
nonHeadOccsRhs :: Set Unique -> Rhs -> Set Unique
nonHeadOccsRhs _ = Set.unions . map atomVars . escapingAtomsRhs

-- | The 'Unique's that appear in a NON-CALL-HEAD position anywhere in an
-- expression --- every escaping operand/field/result/scrutinee/argument
-- occurrence (via 'escapingAtomsRhs' at each RHS), but NOT a saturated call head.
-- @g@ is unused by the recursion's pruning (every group member 'Unique' is
-- globally distinct from fresh nested binders); callers intersect the result with
-- their group set to select escapes.
nonHeadOccs :: Set Unique -> Expr -> Set Unique
nonHeadOccs _ (Ret a)              = atomVars a
nonHeadOccs g (Let _ r e)          = nonHeadOccsRhs g r `Set.union` nonHeadOccs g e
nonHeadOccs g (LetRec defs e)      =
  Set.unions (nonHeadOccs g e : [ nonHeadOccs g d | (_, _, d) <- defs ])
nonHeadOccs g (Case a alts)        =
  atomVars a `Set.union` Set.unions (map (nonHeadOccsAlt g) alts)
nonHeadOccs g (LetJoin _ _ jb e)   = nonHeadOccs g jb `Set.union` nonHeadOccs g e
nonHeadOccs _ (Jump _ as)          = Set.unions (map atomVars as)
nonHeadOccs g (Handle e _)         = nonHeadOccs g e

nonHeadOccsAlt :: Set Unique -> Alt -> Set Unique
nonHeadOccsAlt g (AltCon _ _ e) = nonHeadOccs g e
nonHeadOccsAlt g (AltLit _ e)   = nonHeadOccs g e
nonHeadOccsAlt g (AltDefault e) = nonHeadOccs g e

-- ---------------------------------------------------------------------------
-- The __rc_drop targets of a continuation (M2b-1 owned-set, the crux)
--
-- A value that is BORROWED then DROPPED (a call head under uniform borrow-on-call
-- that the pass drops at its last use) appears in NEITHER 'nonHeadOccs' (the head
-- is exempt) NOR 'escapingAtomsRhs' --- only in an inserted @__rc_drop x@. The
-- M2b-1 owned-set ('continuationOwned' in "Wok.Interp.RC.Value") needs it: such a
-- borrowed-then-dropped value (e.g. the handler-runner's @c@ in
-- @let r = c(self) in __rc_drop c; r@) is OWNED by the continuation and must be
-- freed on abort, so its '__rc_drop' target is part of the owned set.

-- | The set of 'Unique's that an inserted @__rc_drop x@ targets directly in @e@
-- (its continuation structure). Scans for @Let _ (RApp (AVar h) [AVar x]) e@ with
-- @nameHint h == __rc_drop@, collecting @x@. Recurses through the continuation
-- structure ('Let' bodies, 'Case' alts, 'LetJoin'/'Jump', 'LetRec' defs + body,
-- 'Handle' return/op arms) but NOT into nested 'RLam' bodies: a drop inside a
-- lambda fires on the lambda's future CALL, not on this continuation's abort, so it
-- is not part of THIS continuation's owned set.
dropTargets :: Expr -> Set Unique
dropTargets = goE
  where
    goE (Ret _)               = Set.empty
    goE (Let _ r e)           = goR r `Set.union` dropOf r `Set.union` goE e
    -- A 'LetRec' member body fires on the member's CALL, not as part of THIS linear
    -- continuation, so its drops are NOT this continuation's owned set (same reason
    -- the RLam body is excluded via 'goR'). Recurse only into the group BODY.
    goE (LetRec _ e)          = goE e
    goE (Case _ alts)         = Set.unions (map goAlt alts)
    goE (LetJoin _ _ jb e)    = goE jb `Set.union` goE e
    goE (Jump _ _)            = Set.empty
    -- A nested handler's ARMS fire only when that handler's op fires (dynamic), not as
    -- part of this linear continuation, so their drops are NOT this continuation's owned
    -- set (and attributing them would over-free). Recurse only into the handled expr,
    -- which DOES run linearly. This matches 'escapeWalk'/'nonHeadOccs', which also stop
    -- at handler arms.
    goE (Handle e _)          = goE e

    goAlt (AltCon _ _ e) = goE e
    goAlt (AltLit _ e)   = goE e
    goAlt (AltDefault e) = goE e

    -- Recurse into the RHS's own sub-expressions EXCEPT a nested 'RLam' body.
    goR _ = Set.empty

    -- The drop target named by THIS RHS, if it is exactly @__rc_drop x@.
    dropOf (RApp (AVar h) [AVar x])
      | nameHint h == dropHint = Set.singleton (nameUniq x)
    dropOf _ = Set.empty

-- ---------------------------------------------------------------------------
-- The LetRec enclosing-capture ESCAPE predicate (M1.5 Phase 2)
--
-- SHARED single source of truth, used in BOTH places that must agree:
--   * the Perceus pass coverage condition ('coveredExpr (LetRec ...)'), and
--   * the RC boundary guard ('Wok.IR.Reachable.exprScopeFeatures').
--
-- Spec sections 5.1/5.7: the borrow-model multiset accounting (5.2) balances ONLY
-- when the group drops as a UNIT at scope exit, firing each member's cascade
-- exactly once. A member that ESCAPES the 'LetRec' body (its binder flows out as a
-- VALUE --- returned in the result, or moved into a constructor/record/closure/
-- call ARGUMENT that escapes) is NOT dropped at scope exit, so its captured
-- enclosing local leaks (and, symmetrically, a sibling dropped at scope exit
-- dangles under the escaped member's still-live knot). We cannot instrument that
-- soundly yet (it needs region-lifetime extension, deferred per 5.7). So a group
-- that BOTH captures an enclosing boxed local AND has an escaping member must be
-- REFUSED (Part B), never instrumented (excluded from coverage, Part A).
--
-- A group that captures NO enclosing boxed local is UNAFFECTED by this predicate
-- (e.g. a group that merely returns a member: the existing
-- '23-letrec-return-member' shape stays covered exactly as before).

-- | True iff some member of the group captures an enclosing BOXED local (a free
-- var of a member body, minus the member's params and the group binders, that is
-- in @bsc@ --- the in-scope boxed-local Uniques).
letRecCapturesEnclosing :: [(Binder, [Binder], Expr)] -> Set Unique -> Bool
letRecCapturesEnclosing defs bsc =
  not (Set.null (letRecEnclosingCaptures defs bsc))

-- | The set of enclosing boxed locals captured by ANY member of the group: the
-- union over members of @(freeVarsExpr body \\ params \\ groupBinders) ∩ bsc@.
letRecEnclosingCaptures :: [(Binder, [Binder], Expr)] -> Set Unique -> Set Unique
letRecEnclosingCaptures defs bsc =
  let groupU = Set.fromList [ binderUnique b | (b, _, _) <- defs ]
  in Set.unions
       [ ((freeVarsExpr body `Set.difference` Set.fromList (map binderUnique ps))
            `Set.difference` groupU)
           `Set.intersection` bsc
       | (_, ps, body) <- defs ]

-- | True iff some group member BINDER escapes the 'LetRec' body: it appears
-- anywhere in @body@ as an atom in a NON-CALL-HEAD position --- i.e. anything
-- except the head @f@ of an @RApp f as@. A member used ONLY as the head of
-- saturated calls does NOT escape. This is a conservative SOUND over-approximation
-- (over-rejecting is safe; under-rejecting is a soundness hole).
letRecMemberEscapes :: [(Binder, [Binder], Expr)] -> Expr -> Bool
letRecMemberEscapes defs body =
  let groupU = Set.fromList [ binderUnique b | (b, _, _) <- defs ]
  in not (Set.null (nonHeadOccs groupU body `Set.intersection` groupU))

-- | The shared ESCAPE predicate (Part A coverage condition AND Part B boundary
-- reject): True iff some member captures an enclosing boxed local (in @bsc@) AND
-- some group member binder escapes @body@. When False, either the group captures
-- nothing enclosing (the unit-scope accounting is unaffected) or no member escapes
-- (the group drops as a unit and the borrow model balances).
letRecEnclosingCaptureEscapes :: [(Binder, [Binder], Expr)] -> Expr -> Set Unique -> Bool
letRecEnclosingCaptureEscapes defs body bsc =
  letRecCapturesEnclosing defs bsc && letRecMemberEscapes defs body

-- | The ESCAPE predicate for a standalone closure ('RLam') that captures an
-- in-scope 'LetRec' GROUP SIBLING (M2a-1 case #4; shared with the boundary
-- guard, reused by M2a-2). Given the closure's own BINDER and the ENCLOSING
-- scope expression into which it was let-bound, True iff the closure value flows
-- to a position that OUTLIVES the 'LetRec' region --- i.e. the binder appears
-- anywhere in @encl@ as an atom in a NON-CALL-HEAD position (returned in the
-- result, stored into a constructor/record/another closure, jumped out, aliased,
-- or projected). A binder used ONLY as the head of a saturated call does NOT
-- escape; a binder NOT mentioned at all (dropped unused, the @34@ reproducer)
-- does not escape either.
--
-- Soundness over precision (CONSERVATIVE): this reuses the same escaping-position
-- machinery as 'letRecMemberEscapes', which treats EVERY non-call-head atom
-- occurrence as an escape. If the closure cannot be proven to stay local it is
-- reported as escaping (REJECT). It is precise enough to ACCEPT the non-escaping
-- reproducer (the closure is bound and never used, so it is dropped).
--
-- WHY this is the right region. The closure was let-bound in @encl@ (the body
-- following its 'Let'), which is nested INSIDE the enclosing 'LetRec' (the
-- sibling group is in scope). If the closure does not escape @encl@ it is
-- dropped at @encl@'s scope exit, still inside the 'LetRec' region's lifetime,
-- so the borrowed sibling never has to outlive the region. If it escapes @encl@
-- it outlives the region --- region-lifetime extension (M2a-2).
rlamSiblingCaptureEscapes :: Binder -> Expr -> Bool
rlamSiblingCaptureEscapes b = escapesFrom (Set.singleton (binderUnique b))

-- ---------------------------------------------------------------------------
-- The SHARED alias-following escape-walk skeleton
--
-- 'escapesFrom' (the M1.5/M2a-1 general escape walker) and 'captureEscapesBody'
-- (the M2a-2 return-value-only specialisation) used to be TWO hand-rolled walkers
-- with their own per-'Rhs' case tables --- the exact drift this module was built to
-- prevent (a new 'Rhs' form had to be classified in both, and a missed update in
-- 'captureEscapesBody' silently defaulted to "does not escape", gating an unsound
-- consume admit). They are now both expressed as the ONE 'escapeWalk' skeleton
-- below, parameterised by a per-'Let'-'Rhs' policy ('RhsStep') and a flag for
-- whether a 'Case' scrutinee counts as an escape. Adding a new 'Rhs' form is a
-- one-place edit IN EACH POLICY (and the policies are the only place the two
-- walkers are allowed to differ); the traversal/alias-following is shared.

-- | The per-'Let'-'Rhs' decision a walker makes when it reaches @let bd = r@ and
-- the alias closure so far is @tracked@:
--
--   * 'StepEscape'   --- @r@ flows a tracked value OUT (the walk answers True);
--   * 'StepTrack'    --- @r@ carries a tracked value onward into @bd@ (an alias
--                        rename or a container store): @bd@ joins @tracked@ and
--                        the walk continues into the body;
--   * 'StepContinue' --- @r@ neither escapes nor carries onward: continue into the
--                        body with @tracked@ unchanged.
data RhsStep = StepEscape | StepTrack | StepContinue

-- | The shared alias-following escape walk. @scrutEscapes@ says whether a 'Case'
-- scrutinee naming a tracked value counts as an escape (True for the general
-- 'escapesFrom'; False for the return-value-only 'captureEscapesBody', where a
-- matched scrutinee is consumed in place, not flowed out). @step@ is the per-'Let'-
-- 'Rhs' policy (see 'RhsStep'). The traversal of every other 'Expr' form --- 'Ret'
-- and 'Jump' (terminal escapes), 'LetRec', 'Case' alts, 'LetJoin', 'Handle' --- is
-- identical for both callers and lives here.
escapeWalk :: Bool -> (Set Unique -> Binder -> Rhs -> RhsStep) -> Set Unique -> Expr -> Bool
escapeWalk scrutEscapes step = goE
  where
    goE tracked e =
      let hit a = case a of
            AVar n -> nameUniq n `Set.member` tracked
            ALit _ -> False
      in case e of
        Ret a               -> hit a                     -- terminal escape
        Jump _ as           -> any hit as                -- terminal escape
        Let bd r body       -> case step tracked bd r of
          StepEscape   -> True
          StepTrack    -> goE (Set.insert (binderUnique bd) tracked) body
          StepContinue -> goE tracked body
        LetRec ds body      -> any (\(_, _, d) -> goE tracked d) ds || goE tracked body
        Case a alts         -> (scrutEscapes && hit a) || any (goAlt tracked) alts
        LetJoin _ _ jb body -> goE tracked jb || goE tracked body
        Handle e' _         -> goE tracked e'
    goAlt tracked (AltCon _ _ e) = goE tracked e
    goAlt tracked (AltLit _ e)   = goE tracked e
    goAlt tracked (AltDefault e) = goE tracked e

-- | The alias-following escape walker. @tracked@ is the set of binders that ALIAS
-- the value (an original binder plus every @let x = AVar u@ rename of a tracked
-- @u@). The value ESCAPES iff a tracked binder appears in a NON-CALL-HEAD position
-- that is not itself a pure alias-rename. An alias-rename is NOT an escape: it
-- just extends @tracked@ and the question recurses on the new name.
--
-- Expressed as the shared 'escapeWalk' (a 'Case' scrutinee DOES escape here). The
-- per-'Rhs' escape step uses the SAME 'escapingAtomsRhs' (the single source of
-- truth) as 'nonHeadOccsRhs', keeping only this walker's alias-rename special case
-- (a tracked-to-tracked 'RAtom' rename is FOLLOWED, not counted).
escapesFrom :: Set Unique -> Expr -> Bool
escapesFrom = escapeWalk True step
  where
    hit tracked a = case a of
      AVar n -> nameUniq n `Set.member` tracked
      ALit _ -> False
    step tracked _ r = case r of
      -- Pure alias rename of a tracked value: follow it, do not count the
      -- occurrence as an escape. The new binder joins the tracked set.
      RAtom (AVar n)
        | nameUniq n `Set.member` tracked -> StepTrack
      -- A tracked value occurs in an escaping position iff one of the RHS's
      -- escaping atoms (single source of truth) names it. The alias-rename case is
      -- matched FIRST, so it never double-counts.
      _ | any (hit tracked) (escapingAtomsRhs r) -> StepEscape
        | otherwise                              -> StepContinue

-- ---------------------------------------------------------------------------
-- FINDING 1 (consuming captures, DEFERRED)
--
-- FINDING 1 (Phase 2 full-branch review, verified DOUBLE-FREE). The borrow model
-- (spec 5.3) exempts a member's enclosing captures: it neither moves them into the
-- member cell nor drops them inside the body. That is sound ONLY when every use of
-- a capture is a BORROWED READ. But a member can reference a capture in a CONSUMING
-- position --- pass it by value to a call, store it in a constructor/record, return
-- it, alias it, capture it into a nested lambda, or project it. At runtime that is a
-- MOVE (the callee / cell takes ownership and drops it), AND the group-drop cascade
-- ALSO frees the (still region-owned) capture --- a double-free.
--
-- DEFERRED. A dup-per-consuming-use scheme was prototyped (M2a-1) but a property
-- generator (Suite G) proved it unsound at scale, so consuming-capture support is
-- DEFERRED --- it needs proper borrow-passing, not a build-site dup. Until then a
-- group with a consuming capture stays UNCOVERED (pass) and is REJECTED at the
-- boundary ('Wok.IR.Reachable.firstOrderNoHandlerViolations',
-- 'letRecMemberConsumesCaptureNonEscaping') --- never miscompiled. Only BORROWED
-- reads of an enclosing capture (and admissible escapes) are supported.
--
-- BORROW-SAFE vs CONSUMING (the precise rule). An occurrence of a capture @u@ in a
-- member body is BORROW-SAFE iff it is the SCRUTINEE of a 'Case' that keeps no boxed
-- child of @u@ (no boxed 'AltCon' binder of that 'Case' is free in its alt body ---
-- so @case b of Box v -> v@ keeps only the unboxed @v@: SAFE). EVERY OTHER occurrence
-- is CONSUMING. When in doubt, treat as CONSUMING --- over-rejection is sound.

-- | The subset of the watched capture set @caps@ that appears in a CONSUMING
-- position anywhere in @e@. Two positions are EXEMPT (a borrow, not a move):
--   * a 'Case' scrutinee @AVar u@ with @u ∈ caps@ WHEN no boxed 'AltCon' binder of
--     that 'Case' is free in its alt body (a borrowed read);
--   * an 'RApp' call HEAD (uniform borrow-on-call --- aligned with
--     'escapingAtomsRhs' and 'moveOperandUniques', which both exempt the head).
-- Every other atom occurrence of a watched capture is consuming (a move).
consumingOccs :: Set Unique -> Expr -> Set Unique
consumingOccs caps = goE
  where
    watched a = atomVars a `Set.intersection` caps
    goE (Ret a)              = watched a
    goE (Let _ r e)          = goR r `Set.union` goE e
    goE (LetRec ds e)        =
      Set.unions (goE e : [ goE d | (_, _, d) <- ds ])
    goE (Case a alts)        =
      let altOccs = Set.unions (map goAlt alts)
          -- The scrutinee is a BORROWED READ only when it is a bare captured var
          -- and the Case keeps no boxed child of it. Otherwise the scrutinee atom
          -- is a consuming occurrence.
          scrutOcc
            | scrutineeBorrowed a alts = Set.empty
            | otherwise                = watched a
      in scrutOcc `Set.union` altOccs
    goE (LetJoin _ _ jb e)   = goE jb `Set.union` goE e
    goE (Jump _ as)          = Set.unions (map watched as)
    goE (Handle e _)         = goE e

    goAlt (AltCon _ _ e) = goE e
    goAlt (AltLit _ e)   = goE e
    goAlt (AltDefault e) = goE e

    goR (RAtom a)        = watched a
    goR (RApp _ as)      = Set.unions (map watched as)         -- head EXEMPT (borrow), args consume
    goR (RCon _ as)      = Set.unions (map watched as)
    goR (RRecord _ flds) = Set.unions (map (watched . snd) flds)
    -- RProj BORROWS the parent at runtime: 'moveOperandUniques' (Perceus) returns
    -- no move for it and the RC RProj does NOT decref the parent --- the projected
    -- CHILD is the one increfed, via 'projDupFor'. So a projected parent is NOT a
    -- runtime move. The THREE walkers therefore disagree on RProj by design:
    --   * 'escapingAtomsRhs'   counts the parent as ESCAPING (the projected field
    --                          aliases out, so the read-out value rides past the build);
    --   * 'moveOperandUniques' treats it as a BORROW (no move --- the truth at runtime);
    --   * 'consumingOccs'      (here) counts the parent as CONSUMING.
    -- The consume verdict here is a deliberate CONSERVATIVE OVER-REJECT: it is SAFE
    -- (over-rejecting never admits an unsound consume) and currently LOAD-BEARING for
    -- the deferred #1 consuming-capture class --- 'captureEscapesBody' does NOT count
    -- an RProj parent as an admissible return-value escape, so a member that projects a
    -- capture stays rejected. Do NOT relax this to a borrow without re-proving #1 sound.
    goR (RProj _ a)      = watched a
    goR (ROp m _ _ as)   = Set.unions (map watched (maybe as (: as) m))
    goR (RLam ps e)      =
      -- A capture referenced inside a nested lambda body is moved into that
      -- closure cell (it outlives the build) --- consuming. The lambda's own
      -- params shadow nothing of the watched captures (fresh Uniques).
      consumingOccs (caps `Set.difference` Set.fromList (map binderUnique ps)) e

    -- A 'Case' scrutinee is a borrowed read iff it is a bare @AVar@ AND no alt
    -- keeps a boxed child binder live (none of its boxed 'AltCon' binders is free
    -- in that alt's body).
    scrutineeBorrowed (AVar _) alts = all altKeepsNoBoxedChild alts
    scrutineeBorrowed _        _    = False
    altKeepsNoBoxedChild (AltCon _ bs e) =
      let fvs = freeVarsExpr e
      in not (any (\b -> boxedBinder b && binderUnique b `Set.member` fvs) bs)
    altKeepsNoBoxedChild _ = True

-- ---------------------------------------------------------------------------
-- CONSUMING CAPTURES: ESCAPES are admitted, LOCAL consumes stay deferred (M2a-2)
--
-- The pass DUP-BALANCES a borrowed value (a 'LetRec' member or a member-body
-- enclosing capture, both in 'ctxBorrow') that ESCAPES the member body: a returned
-- / jumped value, or one sealed into a con/record/list that itself escapes, or
-- passed as a non-head call argument, gets a single @__rc_dup@ at the escape site
-- (the generalised 'Ret'/'Jump' rule, plus 'moveOperandUniques' for cells/args).
-- The dup runs ONCE PER EXECUTION of that use, so the escaped handle increfs the
-- captured cell and the env's capture-field cascade frees the env-owned unit exactly
-- once at scope exit --- the M2a-2 borrow-from-E discipline (design §3.7).
--
-- A capture that is CONSUMED LOCALLY (moved into a con/record that is then
-- destructured and dropped WITHIN the same member body, projected, or matched by a
-- child-keeping 'Case') stays REJECTED: that is the genuinely-deferred #1 class
-- ('test/rc-m2a1/33', the two-member-both-base-consume counterexample). A build-site
-- dup for a local consume is sound on the path TAKEN but the broader borrow-passing
-- that admits it for ALL call patterns is deferred --- so we admit ONLY a capture
-- whose every consuming occurrence is a TRUE ESCAPE (flows OUT of the member body).
-- A capture used only as a borrowed READ (a 'Case' scrutinee keeping no boxed child)
-- or a call HEAD (saturated OR partial --- a borrow under uniform borrow-on-call)
-- was never unsound and is unaffected ('consumingOccs' exempts the head).

-- | True iff SOME member references SOME enclosing boxed capture in a consuming
-- position that is NOT a TRUE ESCAPE (it is consumed locally --- sealed into a
-- con/record destructured-and-dropped in the body, projected, or matched by a
-- child-keeping 'Case'). A capture every one of whose consuming occurrences flows
-- OUT of the member body (returned, jumped, sealed into an escaping cell, or passed
-- as a non-head call argument) is dup-balanced by the pass and so NOT flagged.
letRecMemberConsumesCaptureNonEscaping :: [(Binder, [Binder], Expr)] -> Set Unique -> Bool
letRecMemberConsumesCaptureNonEscaping defs bsc = any memberConsumes defs
  where
    groupU = Set.fromList [ binderUnique b | (b, _, _) <- defs ]
    memberConsumes (_, ps, body) =
      let params = Set.fromList (map binderUnique ps)
          caps   = ((freeVarsExpr body `Set.difference` params)
                      `Set.difference` groupU)
                     `Set.intersection` bsc
      in any (\u -> not (captureEscapesBody u body)) (Set.toList (consumingOccs caps body))

-- | True iff the captured value @u@ flows OUT of the member body AS (part of) its
-- RETURN VALUE --- it (or a con/record container holding it, or an alias) reaches a
-- 'Ret' or a 'Jump' argument. This is the ONLY admissible capture escape: the pass
-- balances it with a single @__rc_dup@ at the 'Ret'/'Jump' (a bare capture) or at
-- the con-move ('moveOperandUniques', a sealed capture), and the returned container's
-- drop cascades the capture once. A capture sealed into a con/record that is
-- destructured-and-dropped INSIDE the body, passed as a CALL ARGUMENT (consumed by
-- the callee), re-captured into a nested closure, or projected does NOT escape this
-- way and stays in the deferred consuming-capture class. UNDER-approximating here is
-- SAFE (it defers a sound shape); OVER-approximating would admit a deferred consume.
--
-- @tracked@ is the alias/return-containment closure of @u@: the capture itself,
-- every @let a = AVar t@ rename of a tracked @t@, and every @let c = Con/Record
-- [.. t ..]@ container that stores a tracked @t@ (so a later return of the container
-- counts; a later local destructure-and-drop does not).
captureEscapesBody :: Unique -> Expr -> Bool
captureEscapesBody u0 = escapeWalk False step (Set.singleton u0)
  where
    hit tracked a = case a of
      AVar n -> nameUniq n `Set.member` tracked
      ALit _ -> False
    anyHit tracked = any (hit tracked)
    step tracked _ r = case r of
      -- Alias rename of a tracked value: the new binder carries @u@ onward.
      RAtom (AVar n)
        | nameUniq n `Set.member` tracked -> StepTrack
      -- A con/record/list cell that STORES a tracked value carries @u@ onward: the
      -- cell binder joins the tracked set (so a later return of the cell, or a nested
      -- seal, is an escape; a later local destructure-and-drop is not).
      RCon _ as
        | anyHit tracked as -> StepTrack
      RRecord _ flds
        | anyHit tracked (map snd flds) -> StepTrack
      -- Every OTHER RHS that NAMES a tracked value is a CONSUME that does NOT carry
      -- @u@ onward as part of the member's RETURN VALUE, so it is NOT an admissible
      -- escape (it stays in the deferred consuming-capture class):
      --   * a non-head call ARGUMENT moves @u@ into a callee that consumes it
      --     (the capture does not flow out as the result --- rc-m2a1/33, /37);
      --   * re-capture into a nested 'RLam' cell (rc-m2a1/39);
      --   * an 'RProj' parent / an 'ROp' argument.
      -- Only RETURN-VALUE flow (Ret / Jump / a returned con-or-record container ---
      -- handled by the shared 'escapeWalk' terminals and the StepTrack closure here)
      -- is an admissible escape: that is exactly the dup-on-Ret/Jump and the
      -- dup-on-con-move the pass balances, with the container's drop cascading the
      -- capture once. A value named only in a non-escape RHS continues into the body.
      -- A 'Case' scrutinee is matched (consumed) HERE, not flowed out --- never an
      -- escape (the @scrutEscapes = False@ flag to 'escapeWalk' encodes that).
      _ -> StepContinue

-- | The raw enclosing free vars of a group: the union over members of
-- @freeVarsExpr body \\ params \\ groupBinders@ (NOT yet intersected with any
-- scope). Used to detect a captured outer REGION member (cross-region deferral).
rawEnclosingFv :: [(Binder, [Binder], Expr)] -> Set Unique
rawEnclosingFv defs =
  let groupU = Set.fromList [ binderUnique b | (b, _, _) <- defs ]
  in Set.unions
       [ (freeVarsExpr body `Set.difference` Set.fromList (map binderUnique ps))
           `Set.difference` groupU
       | (_, ps, body) <- defs ]

-- ---------------------------------------------------------------------------
-- M2b-1 handler-fragment predicates
--
-- The M2b-1 RC-supported fragment admits handlers that are TAIL-POSITION,
-- have NO handler parameter, and whose every op-arm resume binder does NOT
-- escape its body (it is only used as a saturated call head). 'm2bHandlerInFragment'
-- is the CONTEXT-FREE part of the predicate (it needs only the 'Handler'); the
-- Perceus pass ('coveredExpr') uses it directly.
--
-- IMPORTANT: this is NOT the whole admission test. The boundary guard
-- ('Wok.IR.Reachable.firstOrderNoHandlerViolations') ALSO rejects a handler whose
-- arm captures an enclosing BOXED local --- a CONTEXT-DEPENDENT check (it needs the
-- enclosing boxed-local set) that cannot live in this context-free predicate, so
-- 'coveredExpr' is deliberately MORE PERMISSIVE than the guard on that one case. That
-- is sound because the production entry ('runModuleRC') always runs the guard first,
-- and the test entries that bypass it (the rc-m2b corpus differential, the generative
-- property) are themselves guard-checked or guard-gated. Do not "reconcile" the two by
-- deleting the guard's extra check.

-- | True iff the op-arm's resume binder occurs anywhere in @body@ in a position
-- OTHER than the head of a saturated call. A resume used only as a direct saturated
-- call head (tail / auto resume) or never used (abort) does NOT escape; anything else
-- (stored into a con/record, returned, jumped, projected, captured into a closure, a
-- pure alias-rename @let k2 = resume@, or a 'Case' scrutinee) is an escape that the
-- one-shot move-out runtime cannot account, so the handler is refused.
--
-- This deliberately does NOT use 'escapesFrom': that walker (a) FOLLOWS pure alias
-- renames (so @let k2 = resume in k2 x@ would be missed, while the move-out tracking
-- 'ctxResume' is keyed on the original binder only and would treat @k2 x@ as a borrow
-- --- a leak of the 'NCont'), and (b) like the shared 'escapeWalk', SKIPS nested
-- handler arms (so a resume stored inside a NESTED handler's arm would be missed). This
-- walker reuses the per-'Rhs' single source of truth ('escapingAtomsRhs', which exempts
-- the call head and the @__rc_dup@/@__rc_drop@ intrinsics) but does its OWN traversal
-- that descends into handler arms and treats an alias-rename as an escape.
m2bResumeEscapes :: Binder -> Expr -> Bool
m2bResumeEscapes resume = go
  where
    u = binderUnique resume
    inAtoms as = u `Set.member` Set.unions (map atomVars as)
    go e = case e of
      Ret a               -> u `Set.member` atomVars a
      Jump _ as           -> inAtoms as
      Let _ r body        -> inAtoms (escapingAtomsRhs r) || go body
      LetRec defs body    -> any (\(_, _, d) -> go d) defs || go body
      Case a alts         -> u `Set.member` atomVars a || any goAlt alts
      LetJoin _ _ jb body -> go jb || go body
      Handle e' h         ->
        go e' || go (snd (hReturn h)) || any (go . oaBody) (hOps h)
    goAlt (AltCon _ _ e) = go e
    goAlt (AltLit _ e)   = go e
    goAlt (AltDefault e) = go e

-- | True iff a handler is in the M2b RC-supported fragment: no op-arm resume
-- escapes its body. Handler parameters ('hParam') are admitted as of M2b-2
-- Task 2 (the baton model). Value-position handlers ('hAnswerJoin = Just')
-- are admitted as of M2b-2 Task 5 (answerRebindRC). This is the AUTHORITATIVE
-- coverage predicate shared by the boundary guard ('Wok.IR.Reachable') and
-- the Perceus pass.
m2bHandlerInFragment :: Handler -> Bool
m2bHandlerInFragment h =
  all (\oa -> not (m2bResumeEscapes (oaResume oa) (oaBody oa))) (hOps h)
