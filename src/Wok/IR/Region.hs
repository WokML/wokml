-- | R+escape region routing --- the backend-agnostic placement annotation
-- (Region Slice R1, spec @docs/superpowers/specs/2026-06-25-region-slice-r1-design.md@).
--
-- A PURE compile-time pass over the elaborated ANF that, per top-level function
-- body, tags every allocation 'Arena' or 'Heap' and records which function
-- bodies open an arena. This is the ONLY artifact the interpreter (Task 5) and a
-- future codegen consume to decide placement (spec §2, §7): it is a function of
-- the IR alone (no heap state), so both backends and codegen read identical tags.
--
-- An allocation is born in the activation's UNCOUNTED arena (bulk-freed in O(1)
-- on return) iff the escape analysis proves it NON-ESCAPING, MUTATION-FREE, and
-- the body is CONTINUATION-FREE (the three R1 fences, §5.1--5.3). Everything else
-- is born 'Heap' (the counted path, unchanged).
--
-- SOUNDNESS DIRECTION (spec §5.1, the load-bearing asymmetry): over-tagging
-- 'Heap' is always SAFE --- it merely forgoes the optimization. Over-tagging
-- 'Arena' for a value that actually escapes is a USE-AFTER-FREE (it would be
-- bulk-freed while still referenced). Every fence below therefore answers 'Heap'
-- whenever it cannot PROVE the value arena-safe.
--
-- ESCAPE LOGIC IS NOT REINVENTED HERE. The non-escape check reuses
-- 'Wok.IR.Escape.escapesFrom' (the single source of truth for escaping
-- positions) verbatim; the continuation fence reuses
-- 'Wok.IR.Escape.m2bResumeEscapes' (the M2b boundary resume-escape predicate).
-- This module only COMPOSES those verdicts into a per-allocation placement; it
-- adds no new notion of "escapes" (spec §4.1, §5.3).
module Wok.IR.Region
  ( Placement (..)
  , RegionPlan (..)
  , planRegions
  ) where

import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Set (Set)
import qualified Data.Set as Set
import Data.Text (Text)
import Wok.IR.Anf
  ( Alt (..), Atom (..), Binder (..), Expr (..), Handler (..), OpArm (..)
  , Rhs (..), TopBind (..), CoreModule (..)
  , binderUnique, bndType )
import Wok.IR.Escape (boxedBinder, arenaEscapes, m2bResumeEscapes)
import Wok.IR.Name (Unique, nameUniq)
import qualified Wok.IR.PrimNames as PN
import Wok.TypeChecking.Types (CType (..), TyCon (..))

-- | Where an allocation is born. 'Arena' = the uncounted per-activation arena
-- (bulk-freed at scope close); 'Heap' = the counted RC heap (the existing path).
data Placement = Arena | Heap
  deriving (Eq, Show)

-- | The routing plan for a whole module: the per-allocation-binder placement and
-- the set of function-binder 'Unique's whose body opens an arena (routes at least
-- one 'Arena' allocation). Keyed by 'Unique' so it composes with both backends
-- and codegen without re-deciding placement (spec §6).
data RegionPlan = RegionPlan
  { rpPlacement :: Map Unique Placement
    -- ^ placement for each allocation-binder 'Unique' in the module.
  , rpArenaBodies :: Set Unique
    -- ^ the function-binder 'Unique's whose body routes >= 1 'Arena' allocation.
  } deriving (Eq, Show)

-- | The empty plan (identity of the per-body merge below).
emptyPlan :: RegionPlan
emptyPlan = RegionPlan Map.empty Set.empty

-- | Plan region placement for every top-level function body in a module. PURE,
-- idempotent, and independent of heap state (spec §4.1): re-running on the same
-- module yields the same plan.
--
-- MODULE-LEVEL EFFECT FENCE (spec §5.3, §5.4; the bracket-capture hazard). The
-- per-body continuation fence ('capturesContinuation') stops a body that ITSELF
-- contains a 'Handle' or an 'ROp'. But an EFFECT-FREE body @A@ can still have its
-- arena bracket captured: if @A@ opens an arena and CALLS a function @B@ that fires
-- an op handled by a handler installed ABOVE @A@ (in @A@'s caller chain), the
-- reified continuation includes @A@'s @KArenaCloseRC@ frame; an aborting handler
-- then discards it and @A@'s arena LEAKS (it never closes), with its cells'
-- counted children released by neither the inert abort nor the never-run close.
-- Proving @A@ never sits in such a context is interprocedural; R1 instead takes
-- the simplest SOUND over-approximation: if the module contains ANY 'Handle' at
-- all, no body opens an arena (every allocation is forced 'Heap'). A handler-free
-- module can dispatch no op, so no bracket can ever be captured --- the general
-- bracket is then fully sound. This matches the §5.4 coverage ceiling (R1 captures
-- intra-activation scratch cohorts; effect interaction is a later rung), and costs
-- only the arena routing of effect-free helpers that happen to share a module with
-- a handler (a minor, recoverable coverage loss for a categorical soundness gain).
planRegions :: CoreModule -> RegionPlan
planRegions (CoreModule binds)
  | any (exprHasHandle . tbBody') binds =
      -- All-'Heap': record every allocation as 'Heap' (self-describing), no arena.
      RegionPlan (Map.unions [ collectPlacements (\_ _ _ -> Heap) (tbBody' b) | b <- binds ])
                 Set.empty
  | otherwise = foldr (mergePlan . planTop) emptyPlan binds
  where
    tbBody' (TopBind _ _ body) = body

-- | True iff a 'Handle' appears anywhere in the expression (including nested
-- 'RLam'/'LetRec' member bodies, handler arms, and join bodies). Used by the
-- module-level effect fence in 'planRegions'.
exprHasHandle :: Expr -> Bool
exprHasHandle = go
  where
    go (Ret _)            = False
    go (Let _ r e)        = goRhs r || go e
    go (LetRec defs e)    = any (\(_, _, d) -> go d) defs || go e
    go (Case _ alts)      = any goAlt alts
    go (LetJoin _ _ jb e) = go jb || go e
    go (Jump _ _)         = False
    go (Handle _ _)       = True
    goAlt (AltCon _ _ e)  = go e
    goAlt (AltLit _ e)    = go e
    goAlt (AltDefault e)  = go e
    goRhs (RLam _ e)      = go e
    goRhs _               = False

-- | Union two plans. Placement keys are globally distinct 'Unique's (one per
-- allocation binder), so the maps never conflict.
mergePlan :: RegionPlan -> RegionPlan -> RegionPlan
mergePlan (RegionPlan p1 a1) (RegionPlan p2 a2) =
  RegionPlan (Map.union p1 p2) (Set.union a1 a2)

-- | Plan one top-level function body.
--
-- The CONTINUATION FENCE (spec §5.3) is a whole-body GATE evaluated FIRST: if the
-- body captures a continuation, every allocation is forced 'Heap' and the body
-- opens no arena --- 'collectPlacements' runs with a constant-'Heap' rule (no
-- escape analysis, since the verdict is foregone). Only when the body is provably
-- continuation-free does the per-'Let' rule ('placeLet') route individual
-- allocations. The function-binder joins 'rpArenaBodies' iff >= 1 allocation
-- routes 'Arena'.
planTop :: TopBind -> RegionPlan
planTop (TopBind nm _ body)
  | capturesContinuation body =
      -- Short-circuit: every allocation is 'Heap', no arena. We still RECORD each
      -- alloc as 'Heap' (rather than an empty map) so the plan is self-describing
      -- --- an absent key means "not an allocation", not "a continuation body".
      RegionPlan (collectPlacements (\_ _ _ -> Heap) body) Set.empty
  | otherwise =
      RegionPlan placements
        (if Arena `elem` Map.elems placements
           then Set.singleton (nameUniq nm)
           else Set.empty)
  where
    placements = collectPlacements placeLet body

-- ---------------------------------------------------------------------------
-- The continuation fence (spec §5.3)
--
-- A captured continuation must not resume into a freed arena. R1 routes NOTHING
-- to the arena for a body whose CONTINUATION CAN BE CAPTURED. There are TWO ways
-- that happens; the fence catches BOTH:
--
--   (a) An IN-BODY handler op-arm whose @resume@ escapes its arm body (it stores /
--       returns / jumps / aliases / non-tail-uses the resume): the M2b boundary
--       predicate 'm2bResumeEscapes' (Escape.hs), the single source of truth.
--
--   (b) A FREE EFFECT OPERATION ('ROp') anywhere in the body. An op REIFIES the
--       delimited continuation FROM the op site OUTWARD to its handler. When that
--       handler is OUTSIDE this body (the common case --- e.g. a 'prog' that fires
--       @State.set@ handled by an enclosing @runState@), the captured continuation
--       INCLUDES this body's arena bracket and its arena-resident locals. If the
--       handler ABORTS (discards @resume@), the bracket is discarded with it ---
--       'arenaClose' never runs (the arena LEAKS) and the arena cells' counted
--       children are released by neither the abort (inert on uncounted cells) nor
--       the never-run close. Even a tail-resume re-splices the bracket back, which
--       is subtle to get exactly right. So R1 conservatively fences out ANY body
--       that contains an 'ROp', matching the §5.3/§5.4 scope (intra-activation
--       scratch cohorts only; effect interaction is a later rung). Without this,
--       an admitted M2b/M3 handler program whose op-firing body has a non-escaping
--       boxed local would leak it across an abort.
--
-- Per spec, if continuation-freedom cannot be proven the whole body falls back to
-- the counted path.

-- | True iff the body's continuation can be captured (case (a) OR (b) above), so
-- the body must route nothing to the arena. Walks the whole body --- including
-- nested handler arms, join bodies, 'LetRec' member bodies, and 'RLam' bodies ---
-- because an op or a capturing arm buried anywhere in the activation still makes
-- the continuation reifiable.
capturesContinuation :: Expr -> Bool
capturesContinuation = go
  where
    go (Ret _)               = False
    go (Let _ r e)           = goRhs r || go e
    go (LetRec defs e)       = any (\(_, _, d) -> go d) defs || go e
    go (Case _ alts)         = any goAlt alts
    go (LetJoin _ _ jb e)    = go jb || go e
    go (Jump _ _)            = False
    go (Handle e h)          = go e || goHandler h
    goAlt (AltCon _ _ e)     = go e
    goAlt (AltLit _ e)       = go e
    goAlt (AltDefault e)     = go e
    -- A FREE effect operation reifies this body's continuation outward (case (b)).
    goRhs ROp{}              = True
    goRhs (RLam _ e)         = go e
    goRhs _                  = False
    goHandler h =
      -- Any op-arm whose resume escapes its body is a captured continuation
      -- ('m2bResumeEscapes', the single source of truth). Also recurse into the
      -- return arm and op-arm bodies for a nested capturing handler.
      any (\oa -> m2bResumeEscapes (oaResume oa) (oaBody oa)) (hOps h)
        || go (snd (hReturn h))
        || any (go . oaBody) (hOps h)

-- ---------------------------------------------------------------------------
-- Per-allocation placement (spec §4.1, §5.1, §5.2)

-- | Collect the placement of every allocation-binder in a body. For each
-- @let bd = rhs@ whose @rhs@ is an allocation ('isAlloc'), record the verdict the
-- @place@ rule returns for @(bd, rhs, cont)@; non-allocating lets contribute no
-- entry. Recurses through every 'Expr' form (including nested 'RLam' bodies,
-- handler arms, join bodies, and 'LetRec' members) so an allocation anywhere in
-- the activation is recorded. The @place@ rule is 'placeLet' for a
-- continuation-free body and a constant @\\_ _ _ -> Heap@ under the continuation
-- fence (spec §5.3).
collectPlacements :: (Binder -> Rhs -> Expr -> Placement) -> Expr -> Map Unique Placement
collectPlacements place = go
  where
    go (Ret _)            = Map.empty
    go (Let bd r e)       =
      let here = if isAlloc r
                   then Map.singleton (binderUnique bd) (place bd r e)
                   else Map.empty
      in here `Map.union` goRhs r `Map.union` go e
    go (LetRec defs e)    =
      Map.unions (go e : [ go d | (_, _, d) <- defs ])
    go (Case _ alts)      = Map.unions (map goAlt alts)
    go (LetJoin _ _ jb e) = go jb `Map.union` go e
    go (Jump _ _)         = Map.empty
    go (Handle e h)       =
      go e `Map.union` go (snd (hReturn h))
        `Map.union` Map.unions (map (go . oaBody) (hOps h))
    goAlt (AltCon _ _ e)  = go e
    goAlt (AltLit _ e)    = go e
    goAlt (AltDefault e)  = go e
    -- An allocating RHS may itself contain a sub-expression (only 'RLam'); its
    -- inner allocations are routed too.
    goRhs (RLam _ e)      = go e
    goRhs _               = Map.empty

-- | The placement of a SINGLE allocation @let bd = rhs in cont@. 'Arena' iff ALL
-- three R1 conditions hold (spec §4.1):
--
--   1. 'boxedBinder' bd        --- only boxed/RC values are routable; an unboxed
--                                  scalar lives inline (no cell to route, §4.1);
--   2. @not (isArrayBinder bd)@ --- the MUTATION FENCE (§5.2): a mutable array cell
--                                  ('NArray'/the @Std.Array@ allocators) could later
--                                  have a slot overwritten with a counted ref,
--                                  invalidating the alloc-time escape verdict;
--   3. @not (arenaEscapes {bd} cont)@ --- the §5.1 NON-ESCAPE check, delegated
--                                  WHOLESALE to 'Wok.IR.Escape.arenaEscapes' over the
--                                  REST of the body (@cont@): True iff @bd@ occurs in
--                                  any non-call-head position there OTHER than an
--                                  in-place 'Case' scrutinee (matching @bd@ consumes
--                                  it within the activation; it does not flow out).
--                                  EXCEPTION (the LetRec-capture fence): a use of @bd@
--                                  ANYWHERE inside a 'LetRec' MEMBER body --- INCLUDING
--                                  as a bare call HEAD (@let f x = bd x@) --- IS an
--                                  escape, because the member captures @bd@ into the
--                                  group's shared 'NEnv', which can outlive the
--                                  activation (the group, or a member, may escape).
--                                  'arenaEscapes' tests raw 'freeVarsExpr' membership
--                                  over member bodies for exactly that reason.
--                                  A boxed CHILD extracted and escaped is independently
--                                  'Heap' (it was stored into @bd@ via a con/record
--                                  field = an escaping position), so @bd@ stays
--                                  arena-safe without tracking children (§5.1).
--
-- Otherwise 'Heap'. (The continuation fence is handled at 'planTop'; by the time
-- we reach here the body is already known continuation-free.)
--
-- BOUNDARY-GUARD DEPENDENCY (load-bearing; Task 5 must honour it). 'arenaEscapes'
-- inherits 'escapeWalk's behaviour of NOT descending into handler-arm bodies
-- (@Handle e' _ -> goE tracked e'@). That omission is SOUND only because the
-- boundary guard 'Wok.IR.Reachable.firstOrderNoHandlerViolations' REJECTS any
-- admitted program whose handler arm references an enclosing BOXED local (it
-- fires on @freeVarsHandler h `intersection` bsc@ being non-empty). Therefore no
-- arena-candidate boxed local can ever occur in a handler arm of its OWN body, so
-- there is no escape-through-a-handler-arm for 'arenaEscapes' to miss. Task 5
-- MUST run that guard before opening any arena; without it, a boxed local
-- captured into a handler arm could be mis-routed to the arena and freed while
-- the arm still holds it (use-after-free).
placeLet :: Binder -> Rhs -> Expr -> Placement
placeLet bd _ cont                              -- the 'Rhs' is unused: the mutation
                                                -- fence is binder-TYPE-based ('TcArray'),
                                                -- not RHS-based.
  | boxedBinder bd
  , not (isArrayBinder bd)
  , not (arenaEscapes (Set.singleton (binderUnique bd)) cont)
  = Arena
  | otherwise
  = Heap

-- | True iff this RHS is an ALLOCATION the pass routes: a constructor cell, a
-- record cell, a closure cell, or an array-allocating @Std.Array@ prim. Other
-- RHS forms (a bare atom, a saturated call, a projection, an effect op) allocate
-- nothing the pass places (so they carry no placement entry). 'RReuseCon' is a
-- post-Perceus FBIP form that never reaches this pre-instrumentation pass.
isAlloc :: Rhs -> Bool
isAlloc RCon{}     = True
isAlloc RRecord{}  = True
isAlloc RLam{}     = True
isAlloc r          = isArrayAlloc r

-- | True iff this RHS is an array-allocating @Std.Array@ prim call (@new@,
-- @fromList@, @set@, @resize@ --- the cell-producing prims; @set@/@resize@ are
-- copy-on-write, so they allocate a fresh 'NArray' too). Recognized by the
-- 'APrim' head's QUALIFIED @(module, name)@ identity, the same identity layer the
-- other prim recognizers use ('Wok.IR.PrimNames'). Marking these as allocations
-- lets the pass RECORD their 'Heap' verdict; the mutation fence in 'placeLet'
-- (keyed on the result's 'TcArray' type) is what forces them 'Heap'. Array reads
-- (@index@/@length@/@toList@) allocate no array cell and are not array allocs.
isArrayAlloc :: Rhs -> Bool
isArrayAlloc (RApp (APrim key) _) = key `Set.member` arrayAllocKeys
isArrayAlloc _                    = False

-- | The @(module, name)@ keys of the @Std.Array@ prims that allocate a fresh
-- array cell.
arrayAllocKeys :: Set (Text, Text)
arrayAllocKeys =
  Set.fromList
    [ (PN.stdArrayModule, PN.arrayNewName)
    , (PN.stdArrayModule, PN.arrayFromListName)
    , (PN.stdArrayModule, PN.arraySetName)
    , (PN.stdArrayModule, PN.arrayResizeName)
    ]

-- | True iff the binder names a mutable array value (@Array a@). This is the
-- MUTATION FENCE discriminator (spec §5.2): an array cell is excluded from arena
-- routing regardless of which prim produced it, because its slots can be mutated
-- after allocation. Keyed on the closed type ('TcArray'), the value-rep truth,
-- rather than enumerating prim names.
isArrayBinder :: Binder -> Bool
isArrayBinder = isArrayType . bndType

isArrayType :: CType -> Bool
isArrayType (CTCon TcArray _) = True
isArrayType _                 = False
