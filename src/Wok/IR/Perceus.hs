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
  , Rhs (..), TopBind (..), prettyModule )
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
-- The standard ANF free-var walk: a binder removes its own Unique from the
-- free set of its scope. Only term variables ('AVar') contribute; literals,
-- constructor tags, effect labels, and join ids do not.

freeVarsExpr :: Expr -> Set Unique
freeVarsExpr (Ret a)            = atomVars a
freeVarsExpr (Let b r e)        =
  freeVarsRhs r `Set.union` Set.delete (bndU b) (freeVarsExpr e)
freeVarsExpr (LetRec defs body) =
  let groupU = Set.fromList (map (\(b, _, _) -> bndU b) defs)
      bodyFv = freeVarsExpr body
      defFv  = Set.unions
                 [ freeVarsExpr d `Set.difference` Set.fromList (map bndU ps)
                 | (_, ps, d) <- defs ]
  in (bodyFv `Set.union` defFv) `Set.difference` groupU
freeVarsExpr (Case a alts)      = atomVars a `Set.union` Set.unions (map freeVarsAlt alts)
freeVarsExpr (LetJoin _ ps jb e) =
  let psU = Set.fromList (map bndU ps)
  in (freeVarsExpr jb `Set.difference` psU) `Set.union` freeVarsExpr e
freeVarsExpr (Jump _ as)        = Set.unions (map atomVars as)
freeVarsExpr (Handle e _)       = freeVarsExpr e

freeVarsAlt :: Alt -> Set Unique
freeVarsAlt (AltCon _ bs e) = freeVarsExpr e `Set.difference` Set.fromList (map bndU bs)
freeVarsAlt (AltLit _ e)    = freeVarsExpr e
freeVarsAlt (AltDefault e)  = freeVarsExpr e

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

freeVarsRhs :: Rhs -> Set Unique
freeVarsRhs (RAtom a)        = atomVars a
freeVarsRhs (RApp f as)      = Set.unions (map atomVars (f : as))
freeVarsRhs (RCon _ as)      = Set.unions (map atomVars as)
freeVarsRhs (RLam ps e)      = freeVarsExpr e `Set.difference` Set.fromList (map bndU ps)
freeVarsRhs (ROp m _ _ as)   = Set.unions (map atomVars (maybe as (: as) m))
freeVarsRhs (RRecord _ flds) = Set.unions (map (atomVars . snd) flds)
freeVarsRhs (RProj _ a)      = atomVars a

atomVars :: Atom -> Set Unique
atomVars (AVar n) = Set.singleton (nameUniq n)
atomVars (ALit _) = Set.empty

bndU :: Binder -> Unique
bndU = nameUniq . bndName

-- ---------------------------------------------------------------------------
-- The covered-fragment predicate
--
-- A bind is instrumented only if its body is within the fragment the pass
-- covers: straight-line code (Task 5), 'Case' (Task 6), 'LetJoin'/'Jump' and
-- 'LetRec' (Task 7). The remaining forms --- 'Handle' / 'ROp' (effects, M2) and
-- a STANDALONE 'RLam' (a non-'LetRec' closure) --- are out of coverage, so a body
-- that contains any of them (even nested inside a 'Case' alt or a join body) is
-- passed through unchanged.
--
-- 'RLam' (a standalone closure) is out of coverage because a closure CAPTURES its
-- free owned locals: those captures are consumed when the closure RUNS, not at the
-- syntactic point where the lambda is built. The pass does not model
-- capture-as-consume --- 'ownedOccs' and 'moveAtoms' treat an 'RLam' operand as a
-- borrow --- so instrumenting it would drop a captured owned var BEFORE the
-- closure that still references it runs (a use-after-free). This keeps the safe
-- pass-through for the prelude closures ('raceSpawn'/'spawn'/'async'/'runConc').
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

coveredExpr :: Set Unique -> Expr -> Bool
coveredExpr bsc (Let b r e) =
  let bsc' = if boxedBinder b then Set.insert (bndU b) bsc else bsc
  in coveredRhs r && coveredExpr bsc' e
coveredExpr _   (Ret _)        = True
coveredExpr bsc (Case _ alts)  = all (coveredAlt bsc) alts
coveredExpr bsc (LetJoin _ ps jb e) =
  let bsc' = foldr (\p -> if boxedBinder p then Set.insert (bndU p) else id) bsc ps
  in coveredExpr bsc' jb && coveredExpr bsc e
coveredExpr _   Jump{}         = True
coveredExpr bsc (LetRec defs e) =
  -- Cascade-safe iff no enclosing boxed local is captured (see the note above).
  -- A group member is itself a boxed closure but lives in the same uncounted
  -- region, so within THIS group it is not a counted enclosing capture. Each def
  -- body is its own scope, seeded with its own boxed params (siblings are exempt,
  -- not boxed captures); audit each structurally. The group binders ARE added to
  -- the body's boxed-scope: an INNER LetRec nested in this body would capture them
  -- across a region boundary (a counted, cascade-unsafe edge), so such a nested
  -- group is rejected (its enclosing bind is passed through). A member is always a
  -- boxed closure cell regardless of 'bndType' (see the pass's LetRec case).
  let groupU = Set.fromList [ bndU b | (b, _, _) <- defs ]
      defOK (_, ps, body) =
        coveredExpr (Set.fromList [ bndU p | p <- ps, boxedBinder p ]) body
  in Set.null bsc && all defOK defs && coveredExpr (bsc `Set.union` groupU) e
coveredExpr _   Handle{}       = False

coveredAlt :: Set Unique -> Alt -> Bool
coveredAlt bsc (AltCon _ bs e) =
  coveredExpr (foldr (\b -> if boxedBinder b then Set.insert (bndU b) else id) bsc bs) e
coveredAlt bsc (AltLit _ e)    = coveredExpr bsc e
coveredAlt bsc (AltDefault e)  = coveredExpr bsc e

coveredRhs :: Rhs -> Bool
coveredRhs RLam{} = False   -- captures not modeled as consumes: see above
coveredRhs ROp{}  = False
coveredRhs _      = True

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
  | coveredExpr (Set.fromList [ bndU b | b <- ps, boxedBinder b ]) body =
      let delta0      = Set.fromList [ bndU b | b <- ps, boxedBinder b ]
          env0        = Map.fromList [ (bndU b, b) | b <- ps ]
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
ctxBind b c = c { ctxEnv = Map.insert (bndU b) b (ctxEnv c) }

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

ownExpr ctx sup delta (Let b rhs body) =
  let env       = ctxEnv ctx
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
      bAdded    = if boxedBinder b then Set.singleton (bndU b) else Set.empty
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
        core            = Let b rhs (projDup dropped)
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
  let psU        = Set.fromList (map bndU ps)
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
      psBoxed    = Set.fromList [ bndU b | b <- ps, boxedBinder b ]
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

-- LetRec (Task 7): the group is one uncounted region. Sibling references emit no
-- dup/drop (added to 'ctxExempt'); the group binders are owned and dropped, one
-- each, at the LetRec scope exit. Each closure body is instrumented like a
-- top-level bind (its params owned, siblings exempt). Coverage already guaranteed
-- no def body captures an enclosing owned local.
ownExpr ctx sup delta (LetRec defs body) =
  let groupU     = Set.fromList [ bndU b | (b, _, _) <- defs ]
      -- A LetRec member is ALWAYS a boxed closure cell (the interpreter allocates
      -- each member as an 'NClosure' with @rc = 1@), regardless of the member
      -- binder's 'bndType' (elaboration records the member's RESULT type there,
      -- not its arrow type). So the whole group enters the owned set and each
      -- member is dropped, one each, at scope exit.
      groupBoxed = groupU
      ctxIn      = ctx { ctxEnv    = foldr (\(b, _, _) -> Map.insert (bndU b) b)
                                           (ctxEnv ctx) defs
                       , ctxExempt = ctxExempt ctx `Set.union` groupU }
      -- Instrument each closure body in isolation: a fresh top-level-like context
      -- (params owned), siblings exempt, joins reset (joins do not cross a lambda).
      onDef sp (b, ps, dbody) =
        let dEnv   = Map.fromList [ (bndU p, p) | p <- ps ]
                       `Map.union` Map.fromList [ (bndU g, g) | (g, _, _) <- defs ]
                       `Map.union` ctxEnv ctx
            dCtx   = Ctx dEnv Map.empty (ctxExempt ctx `Set.union` groupU)
            dDelta = Set.fromList [ bndU p | p <- ps, boxedBinder p ]
            (sp', dbody') = ownExpr dCtx sp dDelta dbody
        in (sp', (b, ps, dbody'))
      (sup1, defs') = mapAccumLDefs onDef sup defs
      -- Instrument the body; the group binders are owned (so they get dropped at
      -- scope exit) but exempt from moves/dups.
      bodyDelta     = delta `Set.union` groupBoxed
      (sup2, body') = ownExpr ctxIn sup1 bodyDelta body
  in (sup2, LetRec defs' body')

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
mapAccumLAlts :: (Supply -> Alt -> (Supply, Alt)) -> Supply -> [Alt] -> (Supply, [Alt])
mapAccumLAlts f = go
  where
    go s []       = (s, [])
    go s (x : xs) = let (s', x')  = f s x
                        (s'', xs') = go s' xs
                    in (s'', x' : xs')

-- | Thread the supply across LetRec defs, preserving their order.
mapAccumLDefs :: (Supply -> d -> (Supply, d)) -> Supply -> [d] -> (Supply, [d])
mapAccumLDefs f = go
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
      kept       = [ b | b <- bs, boxedBinder b, bndU b `Set.member` bodyFv ]
      ctx'       = ctxBinds bs ctx
      env'       = ctxEnv ctx'
      altDelta   = outerDelta `Set.union` Set.fromList (map bndU kept)
      (sup1, dups)    = mkDupsForVars sup env' [ (bndU b, 1) | b <- kept ]
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
  -- An 'RLam' captures its free owned locals, but a capture is consumed when the
  -- closure RUNS, not where it is built; the pass does not model that yet, so an
  -- 'RLam' RHS is kept OUT of coverage ('coveredRhs'). This 'Map.empty' is the
  -- defensive total case --- an instrumented body never contains an 'RLam' RHS.
  RLam _ _       -> Map.empty
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
      -- Not (or not the right) RC call: descend into the body. RC-call RHSs never
      -- nest an expression, so only 'body' can contain further RC calls here.
      let (done', body') = mutExpr mut False body
      in (done', Let b rhs body')
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
-- KNOWN LIMITATION (audit scope, not soundness of the current pass). The walk
-- accounts a consume only for the RHS forms it understands ('moveAtoms') and the
-- alts of a 'Case'; it does NOT descend into an 'RLam' body and does NOT treat a
-- closure's captures as relinquishments. So if an owned var were captured by a
-- lambda and consumed inside its body, the lint would net that var to zero (the
-- consume is invisible) and pass it as balanced even though the instrumentation
-- is unsound. This blind spot does not bite today because 'coveredRhs' keeps
-- every 'RLam' RHS out of coverage, so an instrumented (hence audited) body never
-- contains a closure --- the case the lint cannot see is the case the pass never
-- produces. As a guard against future widening, 'lintBind' refuses to certify
-- (it emits an out-of-scope diagnostic rather than silently passing) any covered
-- bind whose body nonetheless contains an 'RLam' RHS. Before closures are brought
-- into coverage, this lint must learn to model capture-as-consume.

balanceLint :: CoreModule -> [Text]
balanceLint = lintInstrumented . insertRC

-- | Audit an ALREADY-instrumented module.
lintInstrumented :: CoreModule -> [Text]
lintInstrumented (CoreModule bs) = concatMap lintBind bs

lintBind :: TopBind -> [Text]
lintBind (TopBind n ps body)
  | not (coveredExpr (Set.fromList [ bndU b | b <- ps, boxedBinder b ]) body) = []
                                         -- not instrumented; nothing to audit
  -- A covered body must not contain a STANDALONE closure: the lint cannot see
  -- consumes that happen inside an 'RLam' body, so it cannot certify such a bind.
  -- 'coveredRhs' already keeps standalone closures out of coverage, so this is
  -- unreachable for the current pass --- a guard that fails LOUD if a future
  -- change widens coverage to closures before the lint learns capture-as-consume.
  -- ('LetRec' closures are audited separately by 'lintScope', so they are not an
  -- 'RLam' RHS and never trip this guard.)
  | exprHasLam body =
      [ nameHint n <> Tx.pack ": out of audit scope --- covered bind contains an "
          <> Tx.pack "RLam (closure captures are not modeled by balanceLint)" ]
  | otherwise =
      let cnt0 = Map.fromList [ (bndU b, 1) | b <- ps, boxedBinder b ]
      in lintScope n Set.empty ps body cnt0

-- | Audit ONE ownership scope (a top-level bind body or a 'LetRec' closure body):
-- build the tracked + exempt sets from the scope's parameters and body, then walk
-- it forward. @exempt0@ carries the enclosing uncounted-region siblings.
lintScope :: Name -> Set Unique -> [Binder] -> Expr -> Counts -> [Text]
lintScope fn exempt0 ps body cnt0 =
  let tracked = Set.fromList [ bndU b | b <- ps, boxedBinder b ]
                  `Set.union` trackedBinders body
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

-- | Does @e@ contain a STANDALONE 'RLam' RHS (a closure that is not a 'LetRec'
-- group member)? Used by 'lintBind' to refuse to certify a covered bind whose
-- body has such a closure, whose captured consumes the lint cannot account for.
-- 'LetRec' def bodies are NOT scanned: their closures are audited by 'lintScope'.
exprHasLam :: Expr -> Bool
exprHasLam (Ret _)            = False
exprHasLam (Let _ r e)        = rhsIsLam r || exprHasLam e
exprHasLam (Case _ alts)      = any altHasLam alts
exprHasLam (LetRec _ e)       = exprHasLam e
exprHasLam (LetJoin _ _ jb e) = exprHasLam jb || exprHasLam e
exprHasLam Jump{}             = False
exprHasLam Handle{}           = False

altHasLam :: Alt -> Bool
altHasLam (AltCon _ _ e) = exprHasLam e
altHasLam (AltLit _ e)   = exprHasLam e
altHasLam (AltDefault e) = exprHasLam e

rhsIsLam :: Rhs -> Bool
rhsIsLam RLam{} = True
rhsIsLam _      = False

-- | The boxed local binders introduced anywhere in @e@ that the pass tracks ---
-- boxed let-binders, AltCon children, and join params --- minus the result
-- binders of inserted @__rc_dup@/@__rc_drop@ calls (which alias an existing
-- handle) and minus 'LetRec' def-body binders (audited in their own scope).
trackedBinders :: Expr -> Set Unique
trackedBinders (Ret _)        = Set.empty
trackedBinders (Let b rhs e)
  | isRcCall rhs              = trackedBinders e
  | boxedBinder b            = Set.insert (bndU b) (trackedBinders e)
  | otherwise                = trackedBinders e
trackedBinders (Case _ alts) = Set.unions (map trackedAlt alts)
trackedBinders (LetRec defs e) =
  -- Every group binder is owned within this scope (a boxed closure cell dropped at
  -- scope exit; see the pass's LetRec case for why 'boxedBinder' is bypassed);
  -- their closure bodies are separate scopes and contribute no binders here.
  Set.fromList [ bndU b | (b, _, _) <- defs ]
    `Set.union` trackedBinders e
trackedBinders (LetJoin _ ps jb e) =
  Set.fromList [ bndU b | b <- ps, boxedBinder b ]
    `Set.union` trackedBinders jb `Set.union` trackedBinders e
trackedBinders Jump{}         = Set.empty
trackedBinders Handle{}       = Set.empty

trackedAlt :: Alt -> Set Unique
trackedAlt (AltCon _ bs e) =
  Set.fromList [ bndU b | b <- bs, boxedBinder b ] `Set.union` trackedBinders e
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
          cnt'           = if enters then bumpC (bndU b) cntMoved else cntMoved
      in vs ++ checkExpr env cnt' body
checkExpr env cnt (Case _ alts) = concatMap (checkAlt env cnt) alts
checkExpr env cnt (LetRec defs body) =
  -- Each closure body is a SEPARATE ownership scope (its own params owned,
  -- siblings exempt); audit each independently. Then audit the LetRec body with
  -- the group binders entering the owned set (+1 boxed each), to be dropped at
  -- scope exit. The body's tracked/exempt sets are already in @env@.
  let groupU      = Set.fromList [ bndU b | (b, _, _) <- defs ]
      defViols    = concatMap (lintDef env groupU) defs
      -- Every group member is a boxed closure cell; each enters the owned set.
      cntGroup    = foldr (\(b, _, _) c -> bumpC (bndU b) c) cnt defs
      -- In the body, a sibling reference (a recursive call head) is NOT a move:
      -- mark the group exempt so only the explicit scope-exit drop relinquishes it.
      envBody     = env { leExempt = leExempt env `Set.union` groupU }
  in defViols ++ checkExpr envBody cntGroup body
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
         let cnt2 = foldr (\b c -> if boxedBinder b then bumpC (bndU b) c else c) cnt1 ps
         in vs ++ checkExpr env cnt2 jbody
checkExpr _ _ Handle{} = []   -- out of coverage

-- | Audit one 'LetRec' closure body as a fresh scope. Its params are owned; its
-- siblings (and any enclosing siblings carried in @env@) are exempt.
lintDef :: LintEnv -> Set Unique -> (Binder, [Binder], Expr) -> [Text]
lintDef env groupU (_, ps, dbody) =
  let exempt = leExempt env `Set.union` groupU
      cnt0   = Map.fromList [ (bndU b, 1) | b <- ps, boxedBinder b ]
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

-- | The MOVE operands of a non-RC RHS (RProj borrows; RLam/ROp out of scope).
--
-- 'RLam' returns @[]@: the lint does NOT treat a closure's captures as moves and
-- does NOT descend into the closure body, so a capture-then-consume inside a
-- lambda is invisible to it. This is sound ONLY because 'coveredRhs' keeps every
-- 'RLam' RHS out of coverage, so an instrumented body never contains one. See the
-- out-of-scope guard in 'lintBind' and the note on 'balanceLint'.
moveAtoms :: Rhs -> [Atom]
moveAtoms rhs = case rhs of
  RAtom a        -> [a]
  RApp f as      -> f : as
  RCon _ as      -> as
  RRecord _ flds -> map snd flds
  RProj _ _      -> []   -- borrow
  RLam _ _       -> []   -- capture not modeled; lint does not descend (see above)
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
