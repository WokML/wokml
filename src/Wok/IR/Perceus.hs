-- | Perceus-style reference-count insertion (Reinking et al., PLDI 2021,
-- ownership-passing, Section 3.4), adapted to wok ANF.
--
-- M1 scope (Tasks 5+6+7): straight-line code (@'Ret'@ / @'Let'@ over
-- @'RAtom'@ / @'RApp'@ / @'RCon'@ / @'RRecord'@ / @'RProj'@), @'Case'@,
-- @'LetJoin'@/@'Jump'@ (join-point ownership reconciliation), and @'LetRec'@
-- (local mutual recursion as an uncounted region). The only remaining
-- out-of-fragment forms are @'Handle'@/@'ROp'@ (effects, the M2 milestone) and a
-- standalone @'RLam'@ that is NOT a @'LetRec'@ closure (captures-as-consume is
-- unmodelled); a top-level bind whose body contains any of those is left
-- UNCHANGED by 'insertRC', and 'balanceLint' only audits binds within the
-- covered fragment.
--
-- TASK 7 --- @'LetJoin'@/@'Jump'@: join-point ownership reconciliation. A join
-- @j(ps) = jbody@ is a non-recursive, lexically-nested label (the interpreter
-- runs @jbody@ in the scope captured at the @'LetJoin'@, NOT at the jump site).
-- Each join has a fixed EXPECTED owned set: its boxed params @ps@ (delivered by
-- the jump arguments) PLUS its CAPTURED owned set @cap j@ = the boxed owned outer
-- locals free in @jbody@ (delivered implicitly through the definition scope and
-- consumed inside @jbody@). The pass reserves @cap j@ for the join while
-- instrumenting the delivering body, and at each @'Jump' j as@ MOVES the boxed
-- args, LEAVES @cap j@ untouched (the join consumes it), and DROPS every other
-- owned var (@delta \\ moved \\ cap j@) before the jump. Differing owned sets
-- across jump sites are reconciled by these per-site drops --- no fixpoint is
-- needed because joins are non-recursive.
--
-- TASK 7 --- @'LetRec'@: local mutual recursion is ONE uncounted region (design
-- invariant 4). The group binders are boxed closures allocated @rc = 1@ each with
-- intra-group edges UNCOUNTED, so a reference to a sibling (a recursive call head)
-- emits NO dup/drop and is never counted as a move; the group binders are instead
-- dropped, one each, as the region is released at the @'LetRec'@ scope exit. The
-- group's closure bodies are instrumented like top-level binds (their params
-- owned, siblings RC-exempt), so a closure consumes the arguments handed to it.
--
-- TASK 6 --- @'Case'@: own-children / drop-parent. In each 'AltCon', the boxed
-- matched-out children the alt KEEPS are @__rc_dup@'d (taking an independent
-- ownership unit), then the OWNED parent scrutinee shell is @__rc_drop@'d at the
-- match (the recursive parent-drop releasing the shell, the unkept children, and
-- one unit of each kept child --- balanced by the dups). Every alt must consume
-- the SAME outer owned set: an owned var dead in a particular alt is dropped at
-- that alt (drop-on-the-dead-branch), which falls out of running the per-alt
-- body under the reconciled delta. The scrutinee is dropped only when it is
-- itself an owned boxed local (a borrowed/global/unboxed scrutinee is not).
--
-- The pass inserts calls to two compiler-internal RC intrinsics, resolved by
-- HINT by the RC interpreter's prim table ('Wok.Interp.RC.Prim.rcPrimTable'):
--
--   * @__rc_dup x@  : incref @x@'s handle (no-op on a literal), returns @x@.
--   * @__rc_drop x@ : decref @x@'s handle (freeing at zero), returns @()@.
--
-- Only BOXED locals are reference-counted. Boxed-ness is read from the binder
-- type ('Binder' carries a 'CType'): @U64@/@U32@/@Char@/@()@/@Bool@/@Never@ are
-- unboxed scalars (never counted); everything else (constructors, records,
-- lists, tuples, strings, closures, type variables) is boxed.
--
-- Globals (top-level binds) and primitive/constructor names are RC-EXEMPT: the
-- owned set tracked by the pass only ever contains binders introduced LOCALLY
-- (let-bindings and parameters) within the current top-level bind, so a
-- reference to a global, prim, or constructor is never increfed or dropped.
-- @'LetRec'@-group sibling references are likewise RC-exempt (uncounted region):
-- a dedicated @exempt@ set masks them out of every move/dup site (see 'Ctx').
module Wok.IR.Perceus
  ( insertRC
  , prettyPerceus
  , balanceLint
    -- * Names of the RC intrinsics (exported for tests / the RC prim table)
  , dupHint
  , dropHint
    -- * Boxed-ness predicate (exported for tests)
  , isBoxedType
    -- * LetRec enclosing-capture predicates (shared with the boundary guard)
  , letRecEnclosingCaptureEscapes
  , letRecMemberConsumesCapture
  , rawEnclosingFv
    -- * Fault injection (Suite C --- oracle-has-teeth; TESTS ONLY)
  , Mutation (..)
  , insertRCMutated
  , lintInstrumented
  ) where

import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Set (Set)
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as Tx
import Wok.IR.Anf
  ( Alt (..), Atom (..), Binder (..), CoreModule (..), Expr (..), Mult (..)
  , Rhs (..), TopBind (..), prettyModule
  , freeVarsExpr, freeVarsAlt, atomVars, binderUnique )
import Wok.IR.Name (JoinId, Name (..), Unique (..))
import Wok.TypeChecking.Types (CType (..), TyCon (..))

-- ---------------------------------------------------------------------------
-- The RC intrinsic names
--
-- These MUST match the hint keys in 'Wok.Interp.RC.Prim.rcPrimTable'.

dupHint, dropHint :: Text
dupHint  = Tx.pack "__rc_dup"
dropHint = Tx.pack "__rc_drop"

-- ---------------------------------------------------------------------------
-- Fresh-Unique supply
--
-- 'insertRC' mints fresh result binders for each inserted dup/drop. To stay a
-- pure 'CoreModule -> CoreModule' function we thread a monotonic counter seeded
-- ABOVE every 'Unique' already in the module, so a minted Unique can never
-- collide with an existing one (Uniques carry no contiguity meaning; only
-- distinctness matters).

newtype Supply = Supply Int

-- | A fresh 'Unique' and the advanced supply.
freshU :: Supply -> (Unique, Supply)
freshU (Supply n) = (Unique n, Supply (n + 1))

-- | Seed a supply strictly above the largest 'Unique' anywhere in the module.
seedSupply :: CoreModule -> Supply
seedSupply (CoreModule bs) = Supply (1 + foldr (max . topMaxU) (-1) bs)

topMaxU :: TopBind -> Int
topMaxU (TopBind n ps e) =
  maximum (uOf n : map (uOf . bndName) ps ++ [exprMaxU e])

uOf :: Name -> Int
uOf n = let Unique i = nameUniq n in i

exprMaxU :: Expr -> Int
exprMaxU = go
  where
    go (Ret a)             = atomMaxU a
    go (Let b r e)         = maximum [uOf (bndName b), rhsMaxU r, go e]
    go (LetRec defs e)     =
      maximum (go e : concatMap (\(b, ps, body) ->
                 uOf (bndName b) : map (uOf . bndName) ps ++ [go body]) defs)
    go (Case a alts)       = maximum (atomMaxU a : map altMaxU alts)
    go (LetJoin _ ps jb e) = maximum (go jb : go e : map (uOf . bndName) ps)
    go (Jump _ as)         = foldr (max . atomMaxU) (-1) as
    go (Handle e _)        = go e   -- Handle bodies are never instrumented in M1

altMaxU :: Alt -> Int
altMaxU (AltCon _ bs e) = maximum (exprMaxU e : map (uOf . bndName) bs)
altMaxU (AltLit _ e)    = exprMaxU e
altMaxU (AltDefault e)  = exprMaxU e

rhsMaxU :: Rhs -> Int
rhsMaxU (RAtom a)        = atomMaxU a
rhsMaxU (RApp f as)      = foldr (max . atomMaxU) (atomMaxU f) as
rhsMaxU (RCon _ as)      = foldr (max . atomMaxU) (-1) as
rhsMaxU (RLam ps e)      = maximum (exprMaxU e : map (uOf . bndName) ps)
rhsMaxU (ROp m _ _ as)   = foldr (max . atomMaxU) (maybe (-1) atomMaxU m) as
rhsMaxU (RRecord _ flds) = foldr (max . atomMaxU . snd) (-1) flds
rhsMaxU (RProj _ a)      = atomMaxU a

atomMaxU :: Atom -> Int
atomMaxU (AVar n) = uOf n
atomMaxU (ALit _) = -1

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
-- Free variables (Unique sets) over ANF
--
-- Imported from 'Wok.IR.Anf': 'freeVarsExpr', 'freeVarsAlt', 'atomVars',
-- 'binderUnique'. ('Wok.IR.Anf' also exports 'freeVarsRhs' for downstream
-- consumers; this pass reaches it transitively through 'freeVarsExpr'.)

-- | Every 'JoinId' reachable from an alt body via a 'Jump' ANYWHERE in it --- a
-- FULL recursive walk through 'Let' / 'Case' / 'LetJoin' / 'LetRec', not merely the
-- leading-'Let' tail. Used by the Case rule to seed the transitive-reachability
-- closure that decides whether the scrutinee is captured (and so kept alive) by a
-- jumped-to join, INCLUDING joins reached only through a join-to-join chain or
-- through a nested 'Case'/'LetJoin' inside an alt (the F1 use-after-free).
altJumpTargets :: [Alt] -> [JoinId]
altJumpTargets = Set.toList . Set.unions . map (jumpTargets . altBody)
  where
    altBody (AltCon _ _ e) = e
    altBody (AltLit _ e)   = e
    altBody (AltDefault e) = e

-- | All 'JoinId's an expression jumps to anywhere within it (a join nested in the
-- expression contributes the targets of its OWN body too --- it may be jumped to
-- from a sibling subexpression).
jumpTargets :: Expr -> Set JoinId
jumpTargets (Ret _)            = Set.empty
jumpTargets (Jump j _)         = Set.singleton j
jumpTargets (Let _ _ e)        = jumpTargets e
jumpTargets (Case _ alts)      = Set.unions (map (jumpTargets . altE) alts)
  where altE (AltCon _ _ e) = e
        altE (AltLit _ e)   = e
        altE (AltDefault e) = e
jumpTargets (LetJoin _ _ jb e) = jumpTargets jb `Set.union` jumpTargets e
jumpTargets (LetRec _ e)       = jumpTargets e   -- def bodies are own scopes
jumpTargets (Handle e _)       = jumpTargets e

-- ---------------------------------------------------------------------------
-- The 'LetRec' enclosing-capture ESCAPE predicate (M1.5 Phase 2)
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

-- ============================ TODO(M1.5 Phase 2+) ============================
-- FINDING 1 (Phase 2 full-branch review, verified DOUBLE-FREE). The borrow model
-- (spec 5.3) exempts a member's enclosing captures: it neither moves them into the
-- member cell nor drops them inside the body. That is sound ONLY when every use of
-- a capture is a BORROWED READ. But a member can reference a capture in a CONSUMING
-- position --- pass it by value to a call, store it in a constructor/record, return
-- it, alias it, capture it into a nested lambda, or project it. At runtime that is a
-- MOVE (the callee / cell takes ownership and drops it), AND the group-drop cascade
-- ALSO frees the (still region-owned) capture --- a double-free. Reproducer:
--
--   peek p = 0
--   main = let b = Box 6
--          in letrec go k = case k of 0 -> peek b ; _ -> 1 + go (k-1)
--          in go 3                                  -- peek b MOVES b => double-free
--
-- Proper support (dup the capture at the build site, once per consuming use, so the
-- region keeps its owning unit) is deferred with the spec 5.7 representation work.
-- Until then a group with a consuming capture stays UNCOVERED (pass) and is REJECTED
-- at the boundary --- never miscompiled.
--
-- BORROW-SAFE vs CONSUMING (the precise rule). An occurrence of a capture @u@ in a
-- member body is BORROW-SAFE iff it is the SCRUTINEE of a 'Case' that keeps no boxed
-- child of @u@ (no boxed 'AltCon' binder of that 'Case' is free in its alt body ---
-- so @case b of Box v -> v@ keeps only the unboxed @v@: SAFE). EVERY OTHER occurrence
-- is CONSUMING: an 'RApp' head or argument, an 'RCon'/'RRecord' field, a 'Ret'/'Jump'
-- atom, an 'RAtom' alias, a free var inside a nested 'RLam', an 'RProj' parent. When
-- in doubt, treat as CONSUMING --- over-rejection is sound, under-rejection is a hole.
-- =============================================================================

-- | True iff SOME member of the group references SOME enclosing BOXED capture (a
-- free var of that member body minus its params and the group binders, intersected
-- with @bsc@) in a CONSUMING position within that member's body. The ONLY
-- non-consuming position is "a 'Case' scrutinee keeping no boxed child of the
-- capture"; every other occurrence consumes (moves) the capture. See the loud
-- TODO above (FINDING 1, spec 5.3/5.7).
letRecMemberConsumesCapture :: [(Binder, [Binder], Expr)] -> Set Unique -> Bool
letRecMemberConsumesCapture defs bsc = any memberConsumes defs
  where
    groupU = Set.fromList [ binderUnique b | (b, _, _) <- defs ]
    memberConsumes (_, ps, body) =
      let params = Set.fromList (map binderUnique ps)
          caps   = ((freeVarsExpr body `Set.difference` params)
                      `Set.difference` groupU)
                     `Set.intersection` bsc
      in not (Set.null (consumingOccs caps body))

-- | The subset of the watched capture set @caps@ that appears in a CONSUMING
-- position anywhere in @e@. A 'Case' scrutinee @AVar u@ with @u ∈ caps@ is exempt
-- (borrowed read) WHEN no boxed 'AltCon' binder of that 'Case' is free in its alt
-- body; every other atom occurrence of a watched capture is consuming. (Conservative:
-- when in doubt, consuming.)
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
    goR (RApp f as)      = Set.unions (map watched (f : as))   -- head AND args consume
    goR (RCon _ as)      = Set.unions (map watched as)
    goR (RRecord _ flds) = Set.unions (map (watched . snd) flds)
    goR (RProj _ a)      = watched a                           -- projected parent moves
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

-- | The 'Unique's that appear as an atom in a NON-CALL-HEAD position anywhere in
-- an expression --- every operand/field/result/scrutinee/argument occurrence, but
-- NOT the head @f@ of an @RApp f as@. (A member binder appearing only as a call
-- head is a recursive/dispatch call, which does not move the value out; any other
-- occurrence conservatively escapes.) @ignore@ are binders LOCAL to a nested scope
-- (a nested lambda's params, a nested LetRec's own binders) whose shadowing
-- references are not the outer group members --- but since group member Uniques
-- are globally distinct from fresh nested binders, @ignore@ only prunes the walk;
-- the final '∩ groupU' is what selects escapes.
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

-- | Non-call-head atom occurrences in a RHS. The head @f@ of @RApp f as@ is the
-- ONLY exempt position (a saturated call does not escape the callee); every other
-- operand/field/capture/lambda-body occurrence escapes.
--
-- ONE exception: an inserted RC intrinsic call (@__rc_dup x@ / @__rc_drop x@)
-- contributes NO escape. The predicate may be evaluated on an ALREADY-instrumented
-- module ('runModuleRC' gates on the instrumented IR), where the group's scope-exit
-- @__rc_drop f@ would otherwise read the member @f@ as an RApp argument and falsely
-- flag it as escaping --- but that drop is exactly the unit-scope release that
-- proves the group does NOT escape. So an RC-intrinsic argument is exempt.
nonHeadOccsRhs :: Set Unique -> Rhs -> Set Unique
nonHeadOccsRhs _ (RAtom a)        = atomVars a
nonHeadOccsRhs _ (RApp (AVar h) _)
  | nameHint h == dupHint || nameHint h == dropHint = Set.empty
nonHeadOccsRhs _ (RApp _ as)      = Set.unions (map atomVars as)   -- head EXEMPT
nonHeadOccsRhs _ (RCon _ as)      = Set.unions (map atomVars as)
nonHeadOccsRhs _ (RRecord _ flds) = Set.unions (map (atomVars . snd) flds)
nonHeadOccsRhs _ (RProj _ a)      = atomVars a
nonHeadOccsRhs _ (ROp m _ _ as)   = Set.unions (map atomVars (maybe as (: as) m))
nonHeadOccsRhs g (RLam ps e)      =
  -- A member captured into a nested lambda ESCAPES (it outlives the build site
  -- inside the closure cell). The lambda's own params shadow nothing of the group
  -- (fresh Uniques), so we simply union its body's non-head occurrences.
  nonHeadOccs g e `Set.difference` Set.fromList (map binderUnique ps)

-- ---------------------------------------------------------------------------
-- The covered-fragment predicate
--
-- A bind is instrumented only if its body is within the fragment the pass
-- covers: straight-line code, 'Case', 'LetJoin'/'Jump', 'LetRec', and a
-- standalone 'RLam' (an ordinary closure) whose body is ITSELF covered. The
-- forms still OUT of coverage are 'Handle' / 'ROp' (effects, M2): a body that
-- contains either of them --- even nested inside a 'Case' alt, a join body, or a
-- lambda body --- is passed through unchanged ('coveredRhsIn' rejects an 'RLam'
-- whose body is not covered).
--
-- 'RLam' (an ordinary closure) is covered as a heap allocation whose fields are
-- its free captures (M1.5). 'ownedOccs' / 'moveAtoms' count each free owned boxed
-- capture as a MOVE into the closure cell, exactly like an 'RCon' field; the
-- lambda body is instrumented as its own owned scope (its boxed params AND
-- captures owned on entry, since 'enterRC' increfs the captures on application).
-- Dropping the closure cell cascades into the captures, so a capture is released
-- when the cell dies --- the runtime image of "consumed when the closure runs."
-- The prelude's ordinary closures ('raceSpawn'/'runConc'/...) are therefore now
-- instrumented and certified balanced by 'balanceLint'.
--
-- A 'LetRec' group's closures DO appear in coverage --- but only when the group
-- captures NO enclosing dynamic boxed local. This is the SAME unmodelled-capture
-- hazard as the standalone 'RLam', sharpened by an interpreter detail: the RC
-- machine captures the WHOLE enclosing scope into each group closure cell and, on
-- drop, recursively frees every captured non-sibling boxed cell (see
-- 'Wok.Interp.RC.Value.countedChildren'). So if any boxed local is live in the
-- enclosing scope at the 'LetRec', dropping the group at scope exit would free
-- that local a SECOND time (the body already consumed it) --- a double-free. A
-- group whose enclosing scope holds only unboxed locals, globals, and its own
-- siblings is cascade-safe and is instrumented; otherwise the whole enclosing
-- bind is passed through. 'boxedScope' threads the enclosing BOXED local Uniques
-- so this guard can be checked; a top-level bind seeds it with its boxed params.

-- @region@ threads the 'Unique's of ENCLOSING 'LetRec' GROUP BINDERS (uncounted
-- region members). They are tracked SEPARATELY from @bsc@ (ordinary boxed locals)
-- so the LetRec case can reject a nested group that captures one of them: a
-- region-to-region counted edge is the §5.5 deferral (the cascade would have to
-- decref an outer region member across a region boundary, which 'countedChildren'
-- does not skip). Ordinary enclosing boxed locals (in @bsc@) ARE brought into
-- coverage (Phase 2, non-escaping case); region members (in @region@) are not.
coveredExpr :: Set Unique -> Set Unique -> Expr -> Bool
coveredExpr region bsc (Let b r e) =
  let bsc' = if boxedBinder b then Set.insert (binderUnique b) bsc else bsc
  in coveredRhsIn region bsc r && coveredExpr region bsc' e
coveredExpr _      _   (Ret _)        = True
coveredExpr region bsc (Case _ alts)  = all (coveredAlt region bsc) alts
coveredExpr region bsc (LetJoin _ ps jb e) =
  let bsc' = foldr (\p -> if boxedBinder p then Set.insert (binderUnique p) else id) bsc ps
  in coveredExpr region bsc' jb && coveredExpr region bsc e
coveredExpr _      _   Jump{}         = True
coveredExpr region bsc (LetRec defs e) =
  -- Phase 2 (M1.5): a group may capture ENCLOSING boxed locals (in @bsc@) so long
  -- as no member ESCAPES the body (the borrow-model accounting balances only when
  -- the group drops as a unit; see 'letRecEnclosingCaptureEscapes', spec 5.1/5.7).
  -- STILL REJECTED (passed through): a group capturing an enclosing REGION member
  -- (in @region@ --- a binder of a DIFFERENT, outer group): a region-to-region
  -- counted cascade edge is deferred (spec 5.5). Each def body is its own scope,
  -- seeded with its own boxed params (siblings are exempt). The group binders are
  -- added to @region@ for @e@ (so a nested inner group capturing them is caught),
  -- NOT to @bsc@ (a member is never a counted enclosing capture of a sibling/body).
  let groupU = Set.fromList [ binderUnique b | (b, _, _) <- defs ]
      -- The enclosing captures (in @bsc@) of this group; if any is a region member
      -- (in @region@) this is the deferred cross-region case (rejected below). By
      -- construction @bsc@ and @region@ are disjoint, so a captured region member is
      -- never in @bsc@ --- instead detect it directly against the raw member fvs.
      capturesRegion =
        not (Set.null (Set.intersection region (rawEnclosingFv defs)))
      escapes = letRecEnclosingCaptureEscapes defs e bsc
      -- FINDING 1 (Phase 2 review): a member that CONSUMES (moves) an enclosing
      -- capture is NOT covered by the borrow model (it would double-free at the
      -- group drop). Stays uncovered (pass) and is rejected at the boundary.
      consumes = letRecMemberConsumesCapture defs bsc
      defOK (_, ps, body) =
        coveredExpr region (Set.fromList [ binderUnique p | p <- ps, boxedBinder p ]) body
  in not capturesRegion
       && not escapes
       && not consumes
       && all defOK defs
       && coveredExpr (region `Set.union` groupU) bsc e
coveredExpr _      _   Handle{}       = False

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

coveredAlt :: Set Unique -> Set Unique -> Alt -> Bool
coveredAlt region bsc (AltCon _ bs e) =
  coveredExpr region (foldr (\b -> if boxedBinder b then Set.insert (binderUnique b) else id) bsc bs) e
coveredAlt region bsc (AltLit _ e)    = coveredExpr region bsc e
coveredAlt region bsc (AltDefault e)  = coveredExpr region bsc e

-- | Scope-aware RHS coverage. A standalone 'RLam' is covered iff its body is
-- covered under the lambda's own boxed param scope (its captures are counted as
-- moves at the build site --- see 'ownedOccs' --- and the body is instrumented
-- as its own owned scope --- see 'ownRhs'). An 'ROp' is never covered.
coveredRhsIn :: Set Unique -> Set Unique -> Rhs -> Bool
coveredRhsIn region bsc (RLam ps e) =
  coveredExpr region (foldr (\p -> if boxedBinder p then Set.insert (binderUnique p) else id) bsc ps) e
coveredRhsIn _      _   ROp{} = False
coveredRhsIn _      _   _     = True

-- ---------------------------------------------------------------------------
-- The pass
--
-- 'ownExpr' rewrites an expression so that every binder in the owned set
-- @delta@ is consumed EXACTLY ONCE on the (single) path through it. @delta@ only
-- ever contains LOCALLY-bound BOXED Uniques (parameters and let-binders of the
-- current top-level bind); references to globals/prims/constructors are not in
-- @delta@, so they are never dup/drop'd.
--
-- The ownership discipline (per boxed local @v@):
--   * acquisitions: 1 (the binding/parameter) + one per inserted @__rc_dup v@;
--   * relinquishments: one per MOVE of @v@ (an operand of RApp/RCon/RRecord, or
--     the 'Ret' result) + one per inserted @__rc_drop v@.
-- 'ownExpr' maintains acquisitions == relinquishments, which 'balanceLint'
-- independently re-checks.

insertRC :: CoreModule -> CoreModule
insertRC cm@(CoreModule bs) =
  let sup0 = seedSupply cm
  in CoreModule (snd (foldr step (sup0, []) bs))
  where
    -- foldr threads the supply right-to-left; order of binds is preserved by
    -- prepending in the accumulator.
    step tb (sup, acc) =
      let (sup', tb') = onBind sup tb
      in (sup', tb' : acc)

onBind :: Supply -> TopBind -> (Supply, TopBind)
onBind sup tb@(TopBind _ ps body)
  | coveredExpr Set.empty (Set.fromList [ binderUnique b | b <- ps, boxedBinder b ]) body =
      let delta0      = Set.fromList [ binderUnique b | b <- ps, boxedBinder b ]
          env0        = Map.fromList [ (binderUnique b, b) | b <- ps ]
          (sup', body') = ownExpr (ctx0 env0) sup delta0 body
      in (sup', tb { tbBody = body' })
  | otherwise = (sup, tb)   -- deferred to a later task; leave unchanged

-- | The pass-local context threaded alongside the owned set @delta@.
--
--   * 'ctxEnv'    --- each in-scope binder's 'Unique' to its 'Binder', so an
--     inserted dup/drop references the variable by its REAL name and the result
--     binder carries the dup'd variable's real type.
--   * 'ctxJoins'  --- each in-scope join's EXPECTED CAPTURED owned set (the boxed
--     owned outer locals its body consumes, beside its params) PAIRED with the set
--     of 'JoinId's its body jumps onward to, so a 'Jump' knows which owned vars to
--     LEAVE for the join versus drop AND the Case rule can transitively close over
--     join-to-join chains when deciding whether the scrutinee is captured.
--   * 'ctxExempt' --- the 'LetRec'-group sibling 'Unique's currently in scope (the
--     uncounted region): a reference to one is never a move and never dup'd, and
--     such a binder is released only by the group drop at scope exit.
data Ctx = Ctx
  { ctxEnv    :: Map Unique Binder
  , ctxJoins  :: Map JoinId (Set Unique, Set JoinId)
  , ctxExempt :: Set Unique
  }

ctx0 :: Map Unique Binder -> Ctx
ctx0 env = Ctx env Map.empty Set.empty

ctxBind :: Binder -> Ctx -> Ctx
ctxBind b c = c { ctxEnv = Map.insert (binderUnique b) b (ctxEnv c) }

ctxBinds :: [Binder] -> Ctx -> Ctx
ctxBinds bs c = foldr ctxBind c bs

-- | Rewrite @e@ so every Unique in @delta@ is consumed exactly once.
ownExpr :: Ctx -> Supply -> Set Unique -> Expr -> (Supply, Expr)
ownExpr ctx sup delta (Ret a) =
  -- The result transfers ownership to the caller (if it is an owned boxed var
  -- that is NOT an uncounted-region sibling); every OTHER owned var is dead and
  -- must be dropped before returning.
  --
  -- F5: the returned result atom is transferred OUT to the caller and must NEVER
  -- be dropped, even when it is a 'ctxExempt' LetRec-group member. 'moved'
  -- excludes exempt siblings because an exempt reference is not a COUNTED move
  -- (it leaves the group's single drop-at-scope-exit to release it); but using
  -- 'moved' alone to compute 'dead' would put a returned group member in 'dead'
  -- and emit '__rc_drop' on the very handle we hand back -> UAF/double-free.
  -- So we additionally protect every owned var the result atom names: such a var
  -- is dead-here only if it is NOT the thing being returned.
  let owned    = atomVars a `Set.intersection` delta
      -- 'dead' = delta \ owned. (Historically '(delta \ moved) \ owned' with
      -- 'moved = owned \ ctxExempt'; since 'moved' is a subset of 'owned' the two
      -- forms are identical, so the intermediate 'moved' binding is dropped.) The
      -- F5 protection is preserved: every owned var the returned atom names is
      -- excluded from 'dead', so a returned LetRec-group member is never dropped.
      dead     = delta `Set.difference` owned
  in dropsFor (ctxEnv ctx) sup dead (Ret a)

ownExpr ctx sup0 delta (Let b rhs body) =
  let -- Instrument an 'RLam' body as its own owned scope FIRST (no-op for every
      -- other rhs form); the captured-var SET is unchanged by body
      -- instrumentation, so all analyses below stay on the ORIGINAL 'rhs' and
      -- only the emitted node uses 'rhs''.
      (sup, rhs') = ownRhs ctx sup0 delta rhs
      env       = ctxEnv ctx
      later     = freeVarsExpr body
      rhsOcc    = ownedOccs ctx delta rhs           -- multiset of owned operands
      rhsSet    = Map.keysSet rhsOcc
      -- A var "survives" this binding iff it is free later in 'body' OR reserved
      -- for a join the body forwards to (delivered IMPLICITLY through the join
      -- 'cap', so NOT syntactically free in 'body'). The reserved set must count
      -- for dup-planning, not just for the prompt-drop ('keepInBody'): a var that
      -- is BOTH moved into 'rhs' AND reserved for a downstream join has TWO
      -- consumers (the move here, and the join body), so it needs a dup --- and it
      -- must not be removed from 'delta' by 'consumedHere', or the downstream Jump
      -- cannot forward it. Keying only on 'later' missed this (the join body then
      -- consumed a var the move had already relinquished -> use-after-free).
      bodyReservedCap = reservedCapForBody (ctxJoins ctx) body
      neededLater = later `Set.union` bodyReservedCap
      -- A boxed owned var referenced in rhs survives into body iff used later.
      -- Dups needed for v: (occurrences - 1) + (1 if it must also survive).
      dupPlan   = [ (v, n - 1 + (if v `Set.member` neededLater then 1 else 0))
                  | (v, n) <- Map.toList rhsOcc ]
      dupPlan'  = [ (v, k) | (v, k) <- dupPlan, k > 0 ]
      -- A referenced (moved) var leaves delta unless it survives into body
      -- (kept alive by an extra dup). Borrowed RProj parents are never in
      -- rhsSet, so they are not consumed here.
      consumedHere = Set.filter (`Set.notMember` neededLater) rhsSet
      bAdded    = if boxedBinder b then Set.singleton (binderUnique b) else Set.empty
      -- Owned set just after the binding installs b and the rhs has consumed
      -- its moved operands.
      afterBind = (delta `Set.difference` consumedHere) `Set.union` bAdded
      -- PROMPT drop: any owned var not free in body has had its last use at or
      -- before this point and dies here. This subsumes both "owned var's last
      -- use is the rhs we just emitted" (e.g. an RProj parent) and "the new
      -- binder b is boxed but never used". Uncounted-region siblings are released
      -- only by the group drop, so they are never dropped here even when dead.
      -- A var RESERVED for a join the body forwards to is NOT dead here even when
      -- it is not syntactically free in 'body': it flows IMPLICITLY into that join
      -- (and any chained downstream join) which consumes it. Such a var is held
      -- live past this prompt-drop and released by the downstream Jump's
      -- reconciliation (it leaves the var for the join) or, on a non-forwarding
      -- path of the join body, by that body's own drop. Without this, a join body
      -- of the form @let x = ... ; jump jk(...)@ --- where @jk@ (or a join it
      -- chains to) captures an owned outer var seeded into this body's delta by the
      -- symmetric 'jDelta' --- would PROMPTLY DROP that captured var here, then the
      -- downstream join would consume it: a use-after-free (or, with the Jump also
      -- leaving it, a double-free). This is the dual of the 'jDelta'/Jump
      -- transitive-cap reservation, applied to the Let prompt-drop.
      deltaBody = Set.filter keepInBody afterBind
      keepInBody v = v `Set.member` later
                       || v `Set.member` ctxExempt ctx
                       || v `Set.member` bodyReservedCap
      deadNow   = afterBind `Set.difference` deltaBody
      ctx'      = ctxBind b ctx
  in
    -- 1. emit the dups the rhs needs (before the rhs runs);
    let (sup1, dups) = mkDupsForVars sup env dupPlan'
    -- 2. an RProj of a BOXED field shares that field with the still-live parent,
    --    so the projected result must be dup'd to own an independent unit;
        (sup2, projDup) = projDupFor sup1 b rhs
    -- 3. promptly drop everything that dies at this point, then recurse;
        (sup3, body')   = ownExpr ctx' sup2 deltaBody body
        (sup4, dropped) = dropsFor (ctxEnv ctx') sup3 deadNow body'
        core            = Let b rhs' (projDup dropped)
    in (sup4, foldr ($) core dups)

-- Case (Task 6): own-children / drop-parent + branch reconciliation.
--
-- The scrutinee is the PARENT. It is owned (and so must be dropped at the match)
-- iff it is an owned boxed local --- i.e. its 'Unique' is in @delta@. (A borrowed
-- parameter, a global, or an unboxed scalar is never in @delta@, so it is not
-- dropped here.)
--
-- The OUTER owned set every alt must consume is @delta@ minus the parent (the
-- parent is consumed by the per-alt drop, not carried into the body). Each alt
-- additionally owns the boxed children it duplicates. Running each alt body under
-- this reconciled delta makes an outer var dead in a branch get dropped there
-- (drop-on-the-dead-branch) while a moved one is moved --- so every alt consumes
-- the same outer set, by construction.
--
-- Robustness guard: the scrutinee is REUSED past the match --- so it is NOT dead
-- at the match and must not be dropped as the parent --- when EITHER it occurs
-- free in some alt body, OR it is captured by a join the alts jump to (its
-- 'Unique' is in that join's 'cap' set, recorded in 'ctxJoins'). The latter is
-- the common ANF shape the elaborator emits for a value-position case whose
-- continuation reuses the scrutinee:
--
--   LetJoin j(r) = <continuation that uses xs>
--   Case xs <alts that each `Jump j(...)` without mentioning xs>
--
-- Here @xs@ is in @j@'s 'cap' but not free in any alt body; dropping it at the
-- alt entry would free it before the join body's use (use-after-free). When the
-- scrutinee is reused it stays in the owned set and 'ownExpr' consumes it at its
-- real last use (in the alt body or, via the captured set, in the join body).
-- The drop-at-match form (the design's reuse-friendly placement) applies only
-- when the scrutinee dies at the match.
ownExpr ctx sup delta (Case a alts) =
  let scr        = scrutineeParent (ctxExempt ctx) delta a
      -- Owned vars captured by ANY join transitively reachable from the alts ---
      -- not just the joins jumped to directly, but every join reached through a
      -- join-to-join chain (or through a nested Case/LetJoin in an alt). The seed
      -- is the full set of jump targets anywhere in each alt; the closure follows
      -- each join's recorded onward targets. Over-approximating here is SAFE:
      -- treating the scrutinee as reused keeps it owned, and the normal Jump
      -- reconciliation drops it at its real last use (no leak, no use-after-free).
      reachableJoins  = closeJoins (ctxJoins ctx) (Set.fromList (altJumpTargets alts))
      capturedByJoins =
        Set.unions [ cap
                   | j <- Set.toList reachableJoins
                   , Just (cap, _) <- [Map.lookup j (ctxJoins ctx)] ]
      reused     = case scr of
                     Just p  -> Set.member p capturedByJoins
                                  || any (Set.member p . freeVarsAlt) alts
                     Nothing -> False
      parent     = if reused then Nothing else scr
      outerDelta = maybe delta (`Set.delete` delta) parent
      (sup', alts') = mapAccumLAlts (ownAlt ctx outerDelta parent) sup alts
  in (sup', Case a alts')

-- LetJoin (Task 7): own the join body under its params + captured owned set; the
-- delivering body reserves that captured set for the join. See the header note.
ownExpr ctx sup delta (LetJoin j ps jbody body) =
  let psU        = Set.fromList (map binderUnique ps)
      -- The join body's CAPTURED owned set: boxed owned outer locals it uses
      -- beside its params (and not uncounted-region siblings). These are
      -- delivered through the definition scope and consumed inside jbody.
      cap        = (freeVarsExpr jbody `Set.difference` psU)
                     `Set.intersection` delta
                     `Set.difference` ctxExempt ctx
      -- Onward jump targets of THIS join's body, so the Case rule can close over
      -- join-to-join chains (a chained merge join that ultimately captures the
      -- scrutinee --- the F1 use-after-free).
      onward     = jumpTargets jbody
      ctxBody    = ctx { ctxJoins = Map.insert j (cap, onward) (ctxJoins ctx) }
      -- Instrument the delivering body: the captured set is reserved for the
      -- join (jumps leave it; it is not dropped in the body).
      (sup1, body') = ownExpr ctxBody sup delta body
      -- Instrument the join body under its boxed params plus the TRANSITIVE
      -- captured set. F1 follow-up: the Jump rule reserves the transitive cap
      -- (union over closeJoins{j}) so an outer var consumed only in a DOWNSTREAM
      -- chained join is not dropped before the jump and flows into this body. The
      -- join body's seeded owned set must be symmetric with that reservation:
      -- seeding with only this join's OWN 'cap' would leave such a transitive var
      -- un-owned here, so a non-forwarding arm of this body (one that does NOT
      -- jump onward to the downstream join) would never drop it -> leak. Seeding
      -- with the transitive cap makes this body own it; its own Case/Jump
      -- reconciliation then forwards it on the chaining arm (the onward Jump
      -- reserves it) and drops it on every non-forwarding arm -> consumed exactly
      -- once per path (arms are mutually exclusive).
      psBoxed    = Set.fromList [ binderUnique b | b <- ps, boxedBinder b ]
      transCap   = Set.unions
                     [ c | k <- Set.toList (closeJoins (ctxJoins ctxBody)
                                                       (Set.singleton j))
                         , Just (c, _) <- [Map.lookup k (ctxJoins ctxBody)] ]
      jDelta     = psBoxed `Set.union` transCap
      ctxJ       = ctxBinds ps ctxBody
      (sup2, jbody') = ownExpr ctxJ sup1 jDelta jbody
  in (sup2, LetJoin j ps jbody' body')

-- Jump (Task 7): transfer ownership of the (boxed) jump arguments into the join,
-- leave the join's captured owned set for the join body to consume, and drop
-- every other owned var before the jump (per-site reconciliation).
ownExpr ctx sup delta (Jump j as) =
  let moved = (Set.unions (map atomVars as) `Set.intersection` delta)
                `Set.difference` ctxExempt ctx
      -- The captured owned set to LEAVE for the destination is the union over EVERY
      -- join transitively reachable from j (j and the chain it jumps onward to): a
      -- chained merge join consumes the captured var in a downstream join body, so
      -- the upstream jump must not drop it (the F1 use-after-free). Reserving the
      -- transitive cap is the dual of the Case rule's transitive 'reused' test.
      reachable = closeJoins (ctxJoins ctx) (Set.singleton j)
      cap   = Set.unions
                [ c | k <- Set.toList reachable
                    , Just (c, _) <- [Map.lookup k (ctxJoins ctx)] ]
      dead  = (delta `Set.difference` moved) `Set.difference` cap
  in dropsFor (ctxEnv ctx) sup dead (Jump j as)

-- LetRec (Task 7 + M1.5 Phase 2): the group is one uncounted region. Sibling
-- references emit no dup/drop (added to 'ctxExempt'); the group binders are owned
-- and dropped, one each, at the LetRec scope exit.
--
-- M1.5 PHASE 2 --- BORROW MODEL for enclosing captures. A group may now close over
-- ENCLOSING owned boxed locals (coverage relaxed; the ESCAPING case is rejected at
-- the boundary, 'letRecEnclosingCaptureEscapes'). A member BORROWS its captures
-- (referenced freely, never moved/dropped inside the body --- matching 'enterRC's
-- region-exempt branch which neither increfs the captures nor drops the shell on a
-- recursive call), and the REGION owns them: the single owning unit per
-- (member, capture) pair is released by that member's drop cascade at scope exit
-- (each member's 'NClosure' is restricted to its free vars, so a freed member
-- decrefs exactly the enclosing captures its body referenced --- siblings stay
-- same-region and are skipped by 'countedChildren').
--
-- MULTISET capture accounting (spec 5.2). A capture @u@ reachable from @k@ members
-- is held by @k@ member cells, so the group drop decrefs @u@ exactly @k@ times. The
-- build must provide @k@ owning units (plus one more if @u@ survives into the body):
--   capOcc[u] = #members whose boxed owned non-exempt captures include @u@
--   need(u)   = capOcc[u] + (1 if u is free in the LetRec body)
--   dups(u)   = need(u) - 1     -- u already carries one owned unit from @delta@
-- Each capture is relinquished from @delta@ (moved into the region) UNLESS it
-- survives into the body. The 'capOcc[u] == #cascades that decref u' equality holds
-- BY CONSTRUCTION: a member's cenv keeps @u@ iff @u@ is free in its body, the same
-- condition that puts @u@ in that member's capture set here.
ownExpr ctx sup delta (LetRec defs body) =
  let groupU     = Set.fromList [ binderUnique b | (b, _, _) <- defs ]
      -- A LetRec member is ALWAYS a boxed closure cell (the interpreter allocates
      -- each member as an 'NClosure' with @rc = 1@), regardless of the member
      -- binder's 'bndType' (elaboration records the member's RESULT type there,
      -- not its arrow type). So the whole group enters the owned set and each
      -- member is dropped, one each, at scope exit.
      groupBoxed = groupU
      env        = ctxEnv ctx
      -- One member's boxed owned non-exempt enclosing captures (borrowed in its
      -- body; moved into the region at build). Boxed-ness is read from the binder
      -- in scope, matching 'ownRhs's 'capsBoxed'.
      memberCaps (_, ps, dbody) =
        let params = Set.fromList (map binderUnique ps)
        in Set.fromList
             [ u
             | u <- Set.toList (freeVarsExpr dbody `Set.difference` params
                                  `Set.difference` groupU)
             , u `Set.member` delta, u `Set.notMember` ctxExempt ctx
             , Just b <- [Map.lookup u env], boxedBinder b ]
      memberCapSets = [ (d, memberCaps d) | d <- defs ]
      -- capOcc[u] = number of members capturing u (the multiset count).
      capOcc     = Map.fromListWith (+)
                     [ (u, 1 :: Int)
                     | (_, cs) <- memberCapSets, u <- Set.toList cs ]
      allCaps    = Map.keysSet capOcc
      laterBody  = freeVarsExpr body
      -- dups(u) = need(u) - 1, emitted only when positive.
      dupPlan    = [ (u, k - 1 + (if u `Set.member` laterBody then 1 else 0))
                   | (u, k) <- Map.toList capOcc ]
      dupPlan'   = [ (u, d) | (u, d) <- dupPlan, d > 0 ]
      -- A capture is relinquished from @delta@ (moved into the region) unless it
      -- survives into the LetRec body (where it keeps its extra owned unit).
      consumedCaps = Set.filter (`Set.notMember` laterBody) allCaps
      ctxIn      = ctx { ctxEnv    = foldr (\(b, _, _) -> Map.insert (binderUnique b) b)
                                           (ctxEnv ctx) defs
                       , ctxExempt = ctxExempt ctx `Set.union` groupU }
      -- Instrument each closure body in isolation: a fresh top-level-like context
      -- (params owned), siblings exempt, AND this member's enclosing captures
      -- exempt (BORROWED --- never moved or dropped inside the body), joins reset
      -- (joins do not cross a lambda).
      onDef sp ((b, ps, dbody), caps) =
        let dEnv   = Map.fromList [ (binderUnique p, p) | p <- ps ]
                       `Map.union` Map.fromList [ (binderUnique g, g) | (g, _, _) <- defs ]
                       `Map.union` ctxEnv ctx
            dCtx   = Ctx dEnv Map.empty
                         (ctxExempt ctx `Set.union` groupU `Set.union` caps)
            dDelta = Set.fromList [ binderUnique p | p <- ps, boxedBinder p ]
            (sp', dbody') = ownExpr dCtx sp dDelta dbody
        in (sp', (b, ps, dbody'))
      (sup1, defs') = mapAccumLPairs onDef sup memberCapSets
      -- Instrument the body; the group binders are owned (so they get dropped at
      -- scope exit) but exempt from moves/dups. A capture moved into the region
      -- leaves the body's delta; a surviving capture stays (its extra dup feeds it).
      bodyDelta     = (delta `Set.difference` consumedCaps) `Set.union` groupBoxed
      (sup2, body') = ownExpr ctxIn sup1 bodyDelta body
      -- Emit the multiset dups BEFORE the LetRec, so each capture carries need(u)
      -- units at the build: capturing-member cascades decref one each at group
      -- drop, and a surviving capture keeps its extra unit for the body.
      (sup3, dups)  = mkDupsForVars sup2 env dupPlan'
  in (sup3, foldr ($) (LetRec defs' body') dups)

-- 'Handle' is out of coverage ('coveredExpr' rejects it), so an instrumented
-- body never reaches here; the total case leaves it unchanged.
ownExpr _ sup _ e@Handle{} = (sup, e)

-- | Transitively close a set of 'JoinId's over the join-to-join edges recorded in
-- 'ctxJoins' (each join maps to its captured set PAIRED with its onward jump
-- targets). The result is every join reachable from the seed set by following
-- onward edges, INCLUDING the seeds themselves. Joins are non-recursive and
-- lexically nested, so this fixpoint terminates; an unknown target (a join not in
-- the map --- e.g. an inner join already out of scope) simply contributes no
-- further edges.
closeJoins :: Map JoinId (Set Unique, Set JoinId) -> Set JoinId -> Set JoinId
closeJoins joins = go Set.empty
  where
    go seen frontier
      | Set.null frontier = seen
      | otherwise =
          let seen'  = seen `Set.union` frontier
              next   = Set.unions
                         [ maybe Set.empty snd (Map.lookup j joins)
                         | j <- Set.toList frontier ]
          in go seen' (next `Set.difference` seen')

-- | The owned captured set RESERVED by every join transitively reachable from a
-- (sub)expression's jump targets: the union of @cap@ over @closeJoins@ of the
-- expression's 'jumpTargets'. A var in this set is delivered IMPLICITLY into a
-- downstream join and consumed there, so a prompt-drop (the Let rule) must hold
-- it live rather than dropping it. The dual of the Jump rule's transitive-cap
-- reservation. Returns the empty set for an expression that forwards to no join.
reservedCapForBody :: Map JoinId (Set Unique, Set JoinId) -> Expr -> Set Unique
reservedCapForBody joins body =
  Set.unions
    [ c | k <- Set.toList (closeJoins joins (jumpTargets body))
        , Just (c, _) <- [Map.lookup k joins] ]

-- | The owned boxed-local 'Unique' of a scrutinee, if any. 'Nothing' for a
-- literal scrutinee, a non-owned (borrowed / global / unboxed) variable, or an
-- uncounted-region sibling (which is never dropped at a match).
scrutineeParent :: Set Unique -> Set Unique -> Atom -> Maybe Unique
scrutineeParent exempt delta (AVar n)
  | nameUniq n `Set.member` delta
  , nameUniq n `Set.notMember` exempt = Just (nameUniq n)
scrutineeParent _ _ _ = Nothing

-- | Thread the supply left-to-right across the alts, preserving their order.
-- A same-type specialisation of 'mapAccumLPairs'.
mapAccumLAlts :: (Supply -> Alt -> (Supply, Alt)) -> Supply -> [Alt] -> (Supply, [Alt])
mapAccumLAlts = mapAccumLPairs

-- | Thread the supply across a list left-to-right, preserving order. The input
-- and output element types may differ (the LetRec instrumentation feeds each def
-- PAIRED with its capture set and emits the bare instrumented def).
mapAccumLPairs :: (Supply -> a -> (Supply, b)) -> Supply -> [a] -> (Supply, [b])
mapAccumLPairs f = go
  where
    go s []       = (s, [])
    go s (x : xs) = let (s', x')   = f s x
                        (s'', xs') = go s' xs
                    in (s'', x' : xs')

-- | Instrument one alt. @outerDelta@ is the reconciled owned set every alt must
-- consume; @parent@ is the owned scrutinee 'Unique' to drop at the match (if any).
ownAlt :: Ctx -> Set Unique -> Maybe Unique -> Supply -> Alt -> (Supply, Alt)
ownAlt ctx outerDelta parent sup (AltCon c bs body) =
  let -- A boxed child that survives into the body is kept: dup it (independent
      -- ownership) and add it to the alt's owned set. An unkept child is freed by
      -- the parent drop, so it is neither dup'd nor owned.
      bodyFv     = freeVarsExpr body
      kept       = [ b | b <- bs, boxedBinder b, binderUnique b `Set.member` bodyFv ]
      ctx'       = ctxBinds bs ctx
      env'       = ctxEnv ctx'
      altDelta   = outerDelta `Set.union` Set.fromList (map binderUnique kept)
      (sup1, dups)    = mkDupsForVars sup env' [ (binderUnique b, 1) | b <- kept ]
      (sup2, dropped) = dropParentThen sup1 env' parent
      (sup3, body')   = ownExpr ctx' sup2 altDelta body
  in (sup3, AltCon c bs (foldr ($) (dropped body') dups))
ownAlt ctx outerDelta parent sup (AltLit l body) =
  let (sup1, dropped) = dropParentThen sup (ctxEnv ctx) parent
      (sup2, body')   = ownExpr ctx sup1 outerDelta body
  in (sup2, AltLit l (dropped body'))
ownAlt ctx outerDelta parent sup (AltDefault body) =
  let (sup1, dropped) = dropParentThen sup (ctxEnv ctx) parent
      (sup2, body')   = ownExpr ctx sup1 outerDelta body
  in (sup2, AltDefault (dropped body'))

-- | Prepend a single @let _ = __rc_drop parent@ when the scrutinee is owned.
-- Identity when there is no owned parent.
dropParentThen :: Supply -> Map Unique Binder -> Maybe Unique -> (Supply, Expr -> Expr)
dropParentThen sup _   Nothing  = (sup, id)
dropParentThen sup env (Just p) = case Map.lookup p env of
  Nothing -> (sup, id)   -- defensive: an owned parent is always in scope
  Just b  -> let (sup', f) = mkDropFn sup b in (sup', f)

-- | Owned-operand occurrence multiset of a RHS: how many times each owned
-- (boxed, locally-bound, non-exempt) variable appears as a MOVE operand.
--
-- 'RProj' is special: reading a field BORROWS the parent (you may project it
-- again), so the parent is NOT counted as a move here --- it stays owned until
-- its real last use elsewhere. Uncounted-region siblings are likewise never
-- moves. All other RHS forms move their (owned, non-exempt) operands.
ownedOccs :: Ctx -> Set Unique -> Rhs -> Map Unique Int
ownedOccs ctx delta rhs = case rhs of
  RAtom a        -> count [a]
  RApp f as      -> count (f : as)
  RCon _ as      -> count as
  RRecord _ flds -> count (map snd flds)
  RProj _ _      -> Map.empty                 -- borrow, not a move
  -- A closure build is a heap allocation whose fields are its free owned boxed
  -- captures, exactly like an 'RCon': each capture is MOVED into the closure cell
  -- (one unit per captured variable). This routes the build through the same
  -- 'Let'-case dup/drop/survival machinery that handles 'RCon'/'RRecord'.
  RLam ps e ->
    let params = Set.fromList (map binderUnique ps)
        caps   = freeVarsExpr e `Set.difference` params
    in Map.fromListWith (+)
         [ (u, 1)
         | u <- Set.toList caps
         , u `Set.member` delta, u `Set.notMember` ctxExempt ctx ]
  ROp _ _ _ as   -> count as
  where
    count atoms =
      Map.fromListWith (+)
        [ (u, 1)
        | AVar n <- atoms, let u = nameUniq n
        , u `Set.member` delta, u `Set.notMember` ctxExempt ctx ]

-- | A RHS that PROJECTS a boxed field needs a @__rc_dup@ of the result binder
-- (the field is shared with the still-live parent record). Returns a body
-- transformer that prepends the dup; identity when the field is unboxed or the
-- RHS is not a projection.
projDupFor :: Supply -> Binder -> Rhs -> (Supply, Expr -> Expr)
projDupFor sup b (RProj _ _)
  | boxedBinder b = let (sup', f) = mkDup sup b in (sup', f)
projDupFor sup _ _ = (sup, id)

-- | Instrument the body of an 'RLam' rhs as its own ownership scope (its boxed
-- params and boxed captures owned on entry, joins/exempt reset) --- mirroring the
-- runtime, where 'enterRC' increfs the captures and binds them with the params
-- into a fresh scope. All other rhs forms are returned unchanged. Takes @delta@
-- so the body's owned captures are restricted to currently-owned vars, matching
-- the move set 'ownedOccs' counts at the build site.
ownRhs :: Ctx -> Supply -> Set Unique -> Rhs -> (Supply, Rhs)
ownRhs ctx sup delta (RLam ps e) =
  let params    = Set.fromList (map binderUnique ps)
      capsBoxed = Set.fromList
                    [ u | u <- Set.toList (freeVarsExpr e `Set.difference` params)
                        , u `Set.member` delta, u `Set.notMember` ctxExempt ctx
                        , Just b <- [Map.lookup u (ctxEnv ctx)], boxedBinder b ]
      psBoxed   = Set.fromList [ binderUnique p | p <- ps, boxedBinder p ]
      dDelta    = psBoxed `Set.union` capsBoxed
      dEnv      = foldr (\p -> Map.insert (binderUnique p) p) (ctxEnv ctx) ps
      dCtx      = Ctx dEnv Map.empty Set.empty
      (sup', e') = ownExpr dCtx sup dDelta e
  in (sup', RLam ps e')
ownRhs _ sup _ r = (sup, r)

-- ---------------------------------------------------------------------------
-- Emitting dup/drop

-- | Build the body transformers that prepend @k@ @__rc_dup@s of each variable.
-- Each dup binds a fresh result of the variable's (boxed) type; the original
-- variable keeps its name (dup returns the same handle), so no operand rewrite
-- is needed --- only the refcount is bumped. A variable absent from @env@ (it
-- should never be, for an owned operand) is skipped defensively.
mkDupsForVars :: Supply -> Map Unique Binder -> [(Unique, Int)] -> (Supply, [Expr -> Expr])
mkDupsForVars sup env plan = go sup (flatten plan) []
  where
    flatten ps = [ v | (v, k) <- ps, _ <- [1 .. k] ]
    go s []       acc = (s, reverse acc)
    go s (v : vs) acc = case Map.lookup v env of
      Just b  -> let (s', f) = mkDup s b in go s' vs (f : acc)
      Nothing -> go s vs acc

-- | A @__rc_dup@ of a known binder: a fresh result of the variable's type, with
-- the variable referenced by its REAL name.
mkDup :: Supply -> Binder -> (Supply, Expr -> Expr)
mkDup sup b =
  let (u, sup') = freshU sup
      resB      = Binder (Name (Tx.pack "_dup") u) Unrestricted (bndType b)
      var       = AVar (bndName b)
  in (sup', \body -> Let resB (RApp (AVar dupName) [var]) body)

-- | Wrap an expression in one @let _ = __rc_drop v@ per dead owned variable.
-- Drops are emitted in ascending-Unique order for a deterministic golden, each
-- referencing the variable by its REAL name with a Unit result.
dropsFor :: Map Unique Binder -> Supply -> Set Unique -> Expr -> (Supply, Expr)
dropsFor env sup dead body = go sup (Set.toAscList dead) body
  where
    go s []       e = (s, e)
    go s (v : vs) e = case Map.lookup v env of
      Nothing -> go s vs e   -- defensive: an owned var is always in scope
      Just b  ->
        let (s', f)   = mkDropFn s b
            (s'', e') = go s' vs e
        in (s'', f e')

-- | A @__rc_drop@ of a known binder: a fresh Unit-typed result with the variable
-- referenced by its REAL name. Returns a body transformer that prepends the drop.
mkDropFn :: Supply -> Binder -> (Supply, Expr -> Expr)
mkDropFn sup b =
  let (u, sup') = freshU sup
      resB      = Binder (Name (Tx.pack "_drop") u) Unrestricted unitTy
      var       = AVar (bndName b)
  in (sup', \body -> Let resB (RApp (AVar dropName) [var]) body)

-- | The intrinsic head names. The 'Unique' is irrelevant: the RC interpreter
-- resolves these by HINT through the prim table, never by identity. We use a
-- sentinel negative Unique that cannot collide with a real binder.
dupName, dropName :: Name
dupName  = Name dupHint  (Unique (-1))
dropName = Name dropHint (Unique (-1))

unitTy :: CType
unitTy = CTCon TcUnit []

-- ---------------------------------------------------------------------------
-- Pretty-printing
--
-- The instrumented module reuses the ordinary ANF pretty-printer; the inserted
-- @__rc_dup@/@__rc_drop@ calls render as ordinary applications.

prettyPerceus :: CoreModule -> Text
prettyPerceus = prettyModule . insertRC

-- ---------------------------------------------------------------------------
-- Fault injection (Suite C --- oracle-has-teeth). TESTS ONLY.
--
-- 'insertRCMutated' runs the ordinary, correct 'insertRC' and then surgically
-- PERTURBS the instrumented module so that exactly ONE RC intrinsic call is
-- wrong. It exists solely to prove the validation oracle is not vacuous: each
-- mutation MUST make the oracle fail loudly on the corpus (a leak, a
-- use-after-free, or a double-free). The default 'insertRC' is never affected ---
-- the perturbation is a separate post-pass, applied only by this entry point.
--
-- Each 'Mutation' rewrites the FIRST matching RC call encountered in a
-- left-to-right pre-order walk and then leaves the rest of the module alone:
--
--   * 'OmitOneDrop' --- delete the first @let _ = __rc_drop x@, splicing in its
--     body. The handle @x@ is now never relinquished, so a dynamic cell it owns
--     leaks: after running, @stLive > rcBaseline@ (Suite B reports a leak).
--   * 'OmitOneDup' --- delete the first @let _dup = __rc_dup x@, splicing in its
--     body. A shared value is now under-counted, so a later consumer drops a cell
--     whose count has already reached zero (or derefs a freed cell): the RC run
--     trips a 'Left' use-after-free / double-free (Suite C), or 'balanceLint'
--     reports an over-consume on the instrumented module.
--   * 'DuplicateOneDrop' --- emit the first @let _ = __rc_drop x@ TWICE in a row.
--     The handle is relinquished one time too many, so the second drop hits a
--     tombstoned cell: the RC run trips a 'Left' double-free (Suite C).
--
-- Because joins are audited inline and bodies are pre-order walked, "first" is a
-- deterministic, stable choice across the corpus. If a mutation finds no matching
-- call in a given module, that module is returned UNCHANGED (the oracle is then
-- vacuously satisfied for it --- tests assert failure over the WHOLE corpus, so at
-- least one program must contain the targeted call).

data Mutation = OmitOneDrop | OmitOneDup | DuplicateOneDrop
  deriving (Eq, Show)

-- | 'insertRC' followed by a single fault injection. TESTS ONLY; never used by
-- the production pipeline (which calls 'insertRC').
insertRCMutated :: Mutation -> CoreModule -> CoreModule
insertRCMutated mut cm =
  let CoreModule bs = insertRC cm
  in CoreModule (snd (mapAccumLBinds (mutBind mut) False bs))

-- | Apply the mutation to the first eligible RC call in a bind's body, flipping
-- the @done@ flag once a mutation has fired so no later call is touched.
mutBind :: Mutation -> Bool -> TopBind -> (Bool, TopBind)
mutBind mut done tb =
  let (done', body') = mutExpr mut done (tbBody tb)
  in (done', tb { tbBody = body' })

-- | Thread the @done@ flag left-to-right across a list of binds.
mapAccumLBinds :: (Bool -> TopBind -> (Bool, TopBind)) -> Bool -> [TopBind] -> (Bool, [TopBind])
mapAccumLBinds f = go
  where
    go d []       = (d, [])
    go d (x : xs) = let (d', x')   = f d x
                        (d'', xs') = go d' xs
                    in (d'', x' : xs')

-- | Pre-order walk applying the mutation to the first matching RC call. Once
-- @done@ is 'True' the expression is returned unchanged.
mutExpr :: Mutation -> Bool -> Expr -> (Bool, Expr)
mutExpr _   True e = (True, e)
mutExpr mut False (Let b rhs body) =
  case rhsCall rhs of
    Just (h, _)
      | mutMatches mut h ->
          -- This is the targeted RC call: mutate it and stop.
          (True, applyMut mut b rhs body)
    _ ->
      -- Not (or not the right) RC call: descend into the rhs (only an 'RLam' nests
      -- an instrumented expression --- its body can hold RC calls) and then, if no
      -- mutation fired there, into the 'Let' body.
      let (d1, rhs')  = mutRhs mut False rhs
          (d2, body') = mutExpr mut d1 body
      in (d2, Let b rhs' body')
mutExpr mut False (Case a alts) =
  let (done', alts') = mapAccumLAltsM (mutAlt mut) False alts
  in (done', Case a alts')
mutExpr mut False (LetJoin j ps jb body) =
  let (d1, jb')   = mutExpr mut False jb
      (d2, body') = mutExpr mut d1 body
  in (d2, LetJoin j ps jb' body')
mutExpr mut False (LetRec defs body) =
  let (d1, defs') = mapAccumLDefsM (mutDef mut) False defs
      (d2, body') = mutExpr mut d1 body
  in (d2, LetRec defs' body')
mutExpr _   False e@(Ret _)    = (False, e)
mutExpr _   False e@(Jump _ _) = (False, e)
mutExpr _   False e@Handle{}   = (False, e)

-- | Descend into an 'RLam' rhs body (the only rhs form that nests an instrumented
-- expression); every other rhs is returned unchanged.
mutRhs :: Mutation -> Bool -> Rhs -> (Bool, Rhs)
mutRhs mut done (RLam ps e) = let (d, e') = mutExpr mut done e in (d, RLam ps e')
mutRhs _   done r           = (done, r)

mutAlt :: Mutation -> Bool -> Alt -> (Bool, Alt)
mutAlt mut done (AltCon c bs e) = let (d, e') = mutExpr mut done e in (d, AltCon c bs e')
mutAlt mut done (AltLit l e)    = let (d, e') = mutExpr mut done e in (d, AltLit l e')
mutAlt mut done (AltDefault e)  = let (d, e') = mutExpr mut done e in (d, AltDefault e')

mutDef :: Mutation -> Bool -> (Binder, [Binder], Expr) -> (Bool, (Binder, [Binder], Expr))
mutDef mut done (b, ps, e) = let (d, e') = mutExpr mut done e in (d, (b, ps, e'))

mapAccumLAltsM :: (Bool -> Alt -> (Bool, Alt)) -> Bool -> [Alt] -> (Bool, [Alt])
mapAccumLAltsM f = go
  where
    go d []       = (d, [])
    go d (x : xs) = let (d', x')   = f d x
                        (d'', xs') = go d' xs
                    in (d'', x' : xs')

mapAccumLDefsM
  :: (Bool -> (Binder, [Binder], Expr) -> (Bool, (Binder, [Binder], Expr)))
  -> Bool -> [(Binder, [Binder], Expr)] -> (Bool, [(Binder, [Binder], Expr)])
mapAccumLDefsM f = go
  where
    go d []       = (d, [])
    go d (x : xs) = let (d', x')   = f d x
                        (d'', xs') = go d' xs
                    in (d'', x' : xs')

-- | Does this RC-intrinsic hint match the call the mutation targets?
mutMatches :: Mutation -> Text -> Bool
mutMatches OmitOneDrop      h = h == dropHint
mutMatches OmitOneDup       h = h == dupHint
mutMatches DuplicateOneDrop h = h == dropHint

-- | Rewrite the matched @Let b rhs body@ per the mutation.
applyMut :: Mutation -> Binder -> Rhs -> Expr -> Expr
applyMut OmitOneDrop      _ _   body = body              -- delete the drop
applyMut OmitOneDup       _ _   body = body              -- delete the dup
applyMut DuplicateOneDrop b rhs body = Let b rhs (Let b rhs body)  -- drop twice

-- ---------------------------------------------------------------------------
-- Balance lint
--
-- An execution-independent check of the invariant: in every instrumented bind,
-- every owned boxed binder reaches exactly one NET consume ON EVERY PATH.
--
-- The lint is a forward walk over the ALREADY-INSTRUMENTED body, carrying a
-- per-'Unique' ownership COUNT (a multiset: a binding or @__rc_dup@ acquires +1,
-- a move or @__rc_drop@ relinquishes -1). It is path-aware: at a 'Case' each alt
-- is a separate path, forked from the same incoming counts and checked
-- independently (summing across alts would mis-count an outer var consumed once
-- per branch). Two violation classes are detected:
--
--   * OVER-CONSUME --- a count would go negative (a move/drop of a value not
--     owned at that point: use-after-move or double-free);
--   * LEAK --- at a path leaf ('Ret'), a still-owned var was never consumed.
--
-- Counts (not a set) are required because @__rc_dup@ legitimately creates a
-- SECOND ownership unit of the same 'Unique'. 'RProj' borrows (no count change).
--
-- Control flow (Task 7). A 'Jump' is a tail transfer into its join: the lint
-- relinquishes the boxed jump arguments, then audits the join body INLINE at the
-- jump site (delivering the join's params, +1 boxed each), modelling the runtime
-- (a join runs in its definition scope, reached from each site). The join's
-- captured owned set rides along in the counts and is consumed inside the body.
-- A 'LetRec' group member is a boxed closure cell that enters the owned set (+1)
-- and is released by its scope-exit @__rc_drop@; a sibling REFERENCE (a recursive
-- call head) is exempt (not a move), so only that explicit drop relinquishes it.
-- Each closure body is audited as its own scope (its params owned, siblings
-- exempt), exactly as the pass instruments it.
--
-- 'balanceLint' is given the RAW (pre-Perceus) module and runs 'insertRC'
-- itself, so the invariant audited is the one the pass establishes. @[]@ means
-- balanced; a non-empty result is a bug in 'insertRC'.
--
-- CLOSURE CAPTURE MODEL. A closure build ('RLam') is a heap allocation whose
-- fields are its free captures, exactly like an 'RCon'. The walk accounts this in
-- two places: 'moveAtoms' returns the captures (free vars minus params) so each
-- is relinquished as a MOVE into the closure cell at the build site, and the
-- 'Let' case of 'checkExpr' descends into the lambda body as a FRESH ownership
-- scope (boxed params + boxed captures owned on entry, joins/exempt reset) via
-- 'lintScope', mirroring the runtime's 'enterRC'. So a capture-then-consume inside
-- a lambda is now visible and audited, and a missing capture drop is reported as a
-- leak --- closures are fully in audit scope.

balanceLint :: CoreModule -> [Text]
balanceLint = lintInstrumented . insertRC

-- | Audit an ALREADY-instrumented module.
lintInstrumented :: CoreModule -> [Text]
lintInstrumented (CoreModule bs) = concatMap lintBind bs

lintBind :: TopBind -> [Text]
lintBind (TopBind n ps body)
  | not (coveredExpr Set.empty (Set.fromList [ binderUnique b | b <- ps, boxedBinder b ]) body) = []
                                         -- not instrumented; nothing to audit
  | otherwise =
      let cnt0 = Map.fromList [ (binderUnique b, 1) | b <- ps, boxedBinder b ]
      in lintScope n Set.empty ps body cnt0

-- | Audit ONE ownership scope (a top-level bind body or a 'LetRec' closure body):
-- build the tracked + exempt sets from the scope's parameters and body, then walk
-- it forward. @exempt0@ carries the enclosing uncounted-region siblings.
lintScope :: Name -> Set Unique -> [Binder] -> Expr -> Counts -> [Text]
lintScope fn = lintScope' fn Set.empty

-- | As 'lintScope', but with an EXTRA tracked set @owned0@ for owned vars that are
-- live on entry but are not introduced by a binder in @body@ --- namely a closure's
-- CAPTURES, which 'enterRC' increfs into the lambda body scope and which the body
-- consumes (drops) inside itself. They must be tracked so those consumes count.
lintScope' :: Name -> Set Unique -> Set Unique -> [Binder] -> Expr -> Counts -> [Text]
lintScope' fn owned0 exempt0 ps body cnt0 =
  let tracked = Set.fromList [ binderUnique b | b <- ps, boxedBinder b ]
                  `Set.union` trackedBinders body
                  `Set.union` owned0
      env     = LintEnv fn tracked exempt0 (collectJoins body)
  in checkExpr env cnt0 body

-- | The lint environment threaded through 'checkExpr'.
--
--   * 'leTracked' --- the boxed locals this scope reference-counts.
--   * 'leExempt'  --- uncounted-region siblings (never moved, dropped by the
--     group drop): a relinquish of one is ignored, and it must not leak.
--   * 'leJoins'   --- each join's @(params, body)@, so a 'Jump' can audit the join
--     body INLINE at the jump site (modelling the runtime tail transfer; the join
--     runs in its definition scope, so this is the faithful per-site check).
data LintEnv = LintEnv
  { leFn      :: Name
  , leTracked :: Set Unique
  , leExempt  :: Set Unique
  , leJoins   :: Map JoinId ([Binder], Expr)
  }

-- | Collect every join definition reachable in the scope's body (joins are
-- lexically nested and non-recursive, so a flat map suffices for inline audit).
collectJoins :: Expr -> Map JoinId ([Binder], Expr)
collectJoins (Ret _)              = Map.empty
collectJoins (Let _ _ e)          = collectJoins e
collectJoins (Case _ alts)        = Map.unions (map collectJoinsAlt alts)
collectJoins (LetJoin j ps jb e)  =
  Map.insert j (ps, jb) (collectJoins jb `Map.union` collectJoins e)
collectJoins (Jump _ _)           = Map.empty
collectJoins (LetRec _ e)         = collectJoins e   -- def bodies are own scopes
collectJoins Handle{}             = Map.empty

collectJoinsAlt :: Alt -> Map JoinId ([Binder], Expr)
collectJoinsAlt (AltCon _ _ e) = collectJoins e
collectJoinsAlt (AltLit _ e)   = collectJoins e
collectJoinsAlt (AltDefault e) = collectJoins e

-- | The boxed local binders introduced anywhere in @e@ that the pass tracks ---
-- boxed let-binders, AltCon children, and join params --- minus the result
-- binders of inserted @__rc_dup@/@__rc_drop@ calls (which alias an existing
-- handle) and minus 'LetRec' def-body binders (audited in their own scope).
trackedBinders :: Expr -> Set Unique
trackedBinders (Ret _)        = Set.empty
trackedBinders (Let b rhs e)
  | isRcCall rhs              = trackedBinders e
  | boxedBinder b            = Set.insert (binderUnique b) (trackedBinders e)
  | otherwise                = trackedBinders e
trackedBinders (Case _ alts) = Set.unions (map trackedAlt alts)
trackedBinders (LetRec defs e) =
  -- Every group binder is owned within this scope (a boxed closure cell dropped at
  -- scope exit; see the pass's LetRec case for why 'boxedBinder' is bypassed);
  -- their closure bodies are separate scopes and contribute no binders here.
  Set.fromList [ binderUnique b | (b, _, _) <- defs ]
    `Set.union` trackedBinders e
trackedBinders (LetJoin _ ps jb e) =
  Set.fromList [ binderUnique b | b <- ps, boxedBinder b ]
    `Set.union` trackedBinders jb `Set.union` trackedBinders e
trackedBinders Jump{}         = Set.empty
trackedBinders Handle{}       = Set.empty

trackedAlt :: Alt -> Set Unique
trackedAlt (AltCon _ bs e) =
  Set.fromList [ binderUnique b | b <- bs, boxedBinder b ] `Set.union` trackedBinders e
trackedAlt (AltLit _ e)    = trackedBinders e
trackedAlt (AltDefault e)  = trackedBinders e

-- | A per-'Unique' net-ownership count along the current path: @count v@ is the
-- number of acquisitions minus relinquishments of @v@ seen so far. Invariant
-- under check: it never goes negative, and it is back to zero for every owned
-- var at each path leaf.
type Counts = Map Unique Int

bumpC :: Unique -> Counts -> Counts
bumpC v = Map.insertWith (+) v 1

-- | Relinquish one unit of @v@ via a MOVE. A non-tracked or exempt @v@ (global /
-- prim / constructor / unboxed local / uncounted-region sibling) is ignored: an
-- uncounted-region sibling reference (a recursive call head) is never a move. A
-- tracked @v@ with count <= 0 is an over-consume (use-after-move / double-free).
relC :: LintEnv -> Text -> Unique -> Counts -> ([Text], Counts)
relC env what v cnt
  | v `Set.member` leExempt env = ([], cnt)   -- sibling reference: not a move
  | otherwise                   = relAny env what v cnt

-- | Relinquish one unit of @v@ via an inserted @__rc_drop@. Unlike a move, an
-- explicit drop DOES count for an uncounted-region sibling: the group binders are
-- released, one each, by exactly such a drop at the LetRec scope exit.
relDrop :: LintEnv -> Unique -> Counts -> ([Text], Counts)
relDrop env = relAny env (Tx.pack "drop")

relAny :: LintEnv -> Text -> Unique -> Counts -> ([Text], Counts)
relAny env what v cnt
  | not (v `Set.member` leTracked env) = ([], cnt)
  | Map.findWithDefault 0 v cnt > 0    = ([], Map.adjust (subtract 1) v cnt)
  | otherwise =
      ( [ nameHint (leFn env) <> Tx.pack ": over-consume of u"
            <> Tx.pack (show (uInt v))
            <> Tx.pack " via " <> what <> Tx.pack " (value not owned here)" ]
      , cnt )

uInt :: Unique -> Int
uInt (Unique i) = i

-- | Walk an instrumented expression forward, accumulating violations.
checkExpr :: LintEnv -> Counts -> Expr -> [Text]
checkExpr env cnt (Ret a) =
  -- F5: the result atom transfers OUT to the caller --- it is consumed here even
  -- when it is a 'leExempt' LetRec-group member (the pass leaves it un-dropped so
  -- the caller gets a live handle). So relinquish the result via 'relRets' (which,
  -- unlike a plain move, counts the exempt sibling too); every OTHER owned var
  -- still held at this leaf is a genuine leak.
  let (vs, cnt') = relRets env (Set.toAscList (atomVars a)) cnt
  in vs ++ leaks env cnt'
checkExpr env cnt (Let b rhs body) =
  case rhsCall rhs of
    -- An inserted dup/drop: the result binder aliases the handle, so it does NOT
    -- enter the owned set; only the refcount of the operand changes.
    Just (h, v)
      | h == dupHint  -> checkExpr env (bumpC v cnt) body
      | h == dropHint -> let (vs, cnt') = relDrop env v cnt
                         in vs ++ checkExpr env cnt' body
    _ ->
      let moves          = [ nameUniq m | AVar m <- moveAtoms rhs ]
          (vs, cntMoved) = relAtoms env (Tx.pack "operand move") moves cnt
          -- A boxed let result enters the owned set with one unit --- UNLESS it is
          -- an 'RProj', which BORROWS the parent: the projected binder owns nothing
          -- on its own and is instead given ownership by the @__rc_dup@ the pass
          -- inserts right after it.
          enters         = boxedBinder b && not (isProj rhs)
          cnt'           = if enters then bumpC (binderUnique b) cntMoved else cntMoved
          -- A closure build also audits its lambda body as its OWN ownership
          -- scope: the boxed params and the boxed captures are owned on entry
          -- (the runtime's 'enterRC' increfs the captures and binds them with the
          -- params), so seed each at +1 and re-walk via 'lintScope'.
          lamViols       = case rhs of
            RLam ps e ->
              let caps  = freeVarsExpr e `Set.difference` Set.fromList (map binderUnique ps)
                  -- The boxed owned captures. Filtering on 'leTracked' agrees with
                  -- 'ownRhs's 'capsBoxed' by the M1 invariant that every boxed owned
                  -- local is tracked (no borrow inference yet); revisit if that changes.
                  capsB = Set.filter (`Set.member` leTracked env) caps
                  cnt0  = Map.fromList $
                            [ (binderUnique p, 1) | p <- ps, boxedBinder p ] ++
                            [ (u, 1) | u <- Set.toList capsB ]
              in lintScope' (leFn env) capsB Set.empty ps e cnt0
            _ -> []
      in vs ++ lamViols ++ checkExpr env cnt' body
checkExpr env cnt (Case _ alts) = concatMap (checkAlt env cnt) alts
checkExpr env cnt (LetRec defs body) =
  -- Each closure body is a SEPARATE ownership scope (its own params owned,
  -- siblings AND this member's enclosing captures exempt); audit each
  -- independently. Then audit the LetRec body with the group binders entering the
  -- owned set (+1 boxed each), to be dropped at scope exit.
  --
  -- M1.5 PHASE 2 BORROW MODEL (spec 5.6). A member may capture an ENCLOSING boxed
  -- owned local; it BORROWS it inside its body (exempt) and the REGION owns it. At
  -- the build the capture is RELINQUISHED 'capOcc[y]' times (one MOVE into the
  -- region per capturing member), mirroring the pass: the build-site @__rc_dup@s
  -- (walked just BEFORE this node) bumped each capture by 'dups(y)', so a capture
  -- carries 'need(y) = capOcc[y] + (1 if free in body)' units here; relinquishing
  -- 'capOcc[y]' of them leaves the body's surviving unit (or zero). The structural
  -- release of the capture by each member's drop-cascade is thus accounted at the
  -- build (like a constructor field move), not re-counted at the scope-exit drop.
  let groupU      = Set.fromList [ binderUnique b | (b, _, _) <- defs ]
      defViols    = concatMap (lintDef env groupU) defs
      -- One member's boxed owned non-exempt enclosing captures (tracked locals free
      -- in its body, minus its params and the group binders). Agrees with the pass's
      -- 'memberCaps' by the M1 invariant that every boxed owned local is tracked.
      memberCaps (_, ps, dbody) =
        Set.fromList
          [ u
          | u <- Set.toList (freeVarsExpr dbody
                               `Set.difference` Set.fromList (map binderUnique ps)
                               `Set.difference` groupU)
          , u `Set.member` leTracked env, u `Set.notMember` leExempt env ]
      -- The multiset of region-moves: each capturing member contributes one move of
      -- its captures into the region.
      capMoves    = concat [ Set.toList (memberCaps d) | d <- defs ]
      (capVs, cnt1) = relAtoms env (Tx.pack "letrec capture move") capMoves cnt
      -- Every group member is a boxed closure cell; each enters the owned set.
      cntGroup    = foldr (\(b, _, _) c -> bumpC (binderUnique b) c) cnt1 defs
      -- In the body, a sibling reference (a recursive call head) is NOT a move:
      -- mark the group exempt so only the explicit scope-exit drop relinquishes it.
      envBody     = env { leExempt = leExempt env `Set.union` groupU }
  in capVs ++ defViols ++ checkExpr envBody cntGroup body
checkExpr env cnt (LetJoin _ _ _ body) =
  -- The join body itself is audited INLINE at each 'Jump' site (see 'leJoins'),
  -- not here; only the delivering body is walked from this point.
  checkExpr env cnt body
checkExpr env cnt (Jump j as) =
  -- Relinquish the boxed jump arguments (moved into the join params), then audit
  -- the join body inline with the params delivered (+1 boxed each). The join's
  -- captured owned set remains in @cnt@ for the join body to consume.
  let (vs, cnt1) = relAtoms env (Tx.pack "jump arg") (atomUniques as) cnt
  in case Map.lookup j (leJoins env) of
       Nothing        -> vs   -- a jump to an outer/unknown join: nothing to audit
       Just (ps, jbody) ->
         let cnt2 = foldr (\b c -> if boxedBinder b then bumpC (binderUnique b) c else c) cnt1 ps
         in vs ++ checkExpr env cnt2 jbody
checkExpr _ _ Handle{} = []   -- out of coverage

-- | Audit one 'LetRec' closure body as a fresh scope. Its params are owned; its
-- siblings, any enclosing siblings carried in @env@, AND this member's enclosing
-- captures (M1.5 Phase 2: BORROWED inside the body, owned by the region) are
-- exempt --- never moved or dropped inside the body, matching the pass.
lintDef :: LintEnv -> Set Unique -> (Binder, [Binder], Expr) -> [Text]
lintDef env groupU (_, ps, dbody) =
  let caps   = Set.fromList
                 [ u
                 | u <- Set.toList (freeVarsExpr dbody
                                      `Set.difference` Set.fromList (map binderUnique ps)
                                      `Set.difference` groupU)
                 , u `Set.member` leTracked env, u `Set.notMember` leExempt env ]
      exempt = leExempt env `Set.union` groupU `Set.union` caps
      cnt0   = Map.fromList [ (binderUnique b, 1) | b <- ps, boxedBinder b ]
  in lintScope (leFn env) exempt ps dbody cnt0

atomUniques :: [Atom] -> [Unique]
atomUniques as = [ nameUniq n | AVar n <- as ]

-- | Check one alt as an independent path forked from the incoming counts.
checkAlt :: LintEnv -> Counts -> Alt -> [Text]
checkAlt env cnt (AltCon _ _ body) = checkExpr env cnt body
checkAlt env cnt (AltLit _ body)   = checkExpr env cnt body
checkAlt env cnt (AltDefault body) = checkExpr env cnt body

-- | Relinquish a list of variables (e.g. the move operands of a RHS).
relAtoms :: LintEnv -> Text -> [Unique] -> Counts -> ([Text], Counts)
relAtoms env what = go
  where
    go []       cnt = ([], cnt)
    go (v : vs) cnt = let (e1, cnt1) = relC env what v cnt
                          (e2, cnt2) = go vs cnt1
                      in (e1 ++ e2, cnt2)

-- | Relinquish the variables NAMED BY A RESULT ATOM ('Ret'). This is a TRANSFER
-- OUT: unlike a plain move ('relC'), it consumes a 'leExempt' uncounted-region
-- sibling too (the pass hands the live handle back to the caller rather than
-- dropping it at scope exit). A non-tracked var is ignored; an exempt member is
-- decremented exactly like a tracked var so it is not falsely reported as a leak.
relRets :: LintEnv -> [Unique] -> Counts -> ([Text], Counts)
relRets env = go
  where
    go []       cnt = ([], cnt)
    go (v : vs) cnt = let (e1, cnt1) = relAny env (Tx.pack "result move") v cnt
                          (e2, cnt2) = go vs cnt1
                      in (e1 ++ e2, cnt2)

-- | Any owned var still held at a path leaf is a leak (never consumed).
leaks :: LintEnv -> Counts -> [Text]
leaks env cnt =
  [ nameHint (leFn env) <> Tx.pack ": leak of u" <> Tx.pack (show (uInt v))
      <> Tx.pack " (" <> Tx.pack (show k) <> Tx.pack " unit(s) never consumed)"
  | (v, k) <- Map.toAscList cnt, k > 0 ]

-- | The MOVE operands of a non-RC RHS (RProj borrows; ROp out of scope).
--
-- An 'RLam' build MOVES each free capture into the closure cell, exactly like an
-- 'RCon' moves its fields. We return the captures (free vars minus params) as
-- synthetic atoms carrying only their 'Unique' --- 'checkExpr'/'relAtoms' read
-- only the 'nameUniq', and 'relC'/'relAny' filter to tracked (boxed owned) vars,
-- so an empty-hint name suffices. The lambda BODY is audited as its own scope by
-- 'checkExpr' (see the 'Let' case), not here.
moveAtoms :: Rhs -> [Atom]
moveAtoms rhs = case rhs of
  RAtom a        -> [a]
  RApp f as      -> f : as
  RCon _ as      -> as
  RRecord _ flds -> map snd flds
  RProj _ _      -> []   -- borrow
  RLam ps e ->
    [ AVar (Name (Tx.pack "") u)
    | u <- Set.toList (freeVarsExpr e `Set.difference` Set.fromList (map binderUnique ps)) ]
  ROp _ _ _ as   -> as

-- | Is this RHS a projection (a borrow, not an owning bind)?
isProj :: Rhs -> Bool
isProj RProj{} = True
isProj _       = False

-- | Is this RHS an inserted RC intrinsic call?
isRcCall :: Rhs -> Bool
isRcCall r = case rhsCall r of
  Just (h, _) -> h == dupHint || h == dropHint
  Nothing     -> False

-- | If the RHS is an application of an RC intrinsic to a single variable,
-- return its hint and that variable's Unique.
rhsCall :: Rhs -> Maybe (Text, Unique)
rhsCall (RApp (AVar h) [AVar x])
  | nameHint h == dupHint || nameHint h == dropHint = Just (nameHint h, nameUniq x)
rhsCall _ = Nothing
