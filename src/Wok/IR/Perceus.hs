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
    -- * Boxed-ness predicate (re-exported from "Wok.IR.Escape" for tests)
  , isBoxedType
    -- * LetRec enclosing-capture predicates (re-exported from "Wok.IR.Escape";
    -- the single source of truth lives there, shared with the boundary guard)
  , letRecEnclosingCaptureEscapes
  , letRecMemberEscapes
  , rlamSiblingCaptureEscapes
  , nonHeadOccsRhs
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
  , Handler (..), OpArm (..)
  , Rhs (..), TopBind (..), prettyModule
  , freeVarsExpr, freeVarsAlt, atomVars, binderUnique, hParamBinders )
import Wok.IR.Escape
  ( isBoxedType, boxedBinder
  , nonHeadOccsRhs
  , rlamSiblingCaptureEscapes, letRecEnclosingCaptureEscapes
  , letRecMemberEscapes
  , rawEnclosingFv
  , m2bHandlerInFragmentStore )
import Wok.IR.Name (JoinId, Name (..), Unique (..))
import qualified Wok.IR.PrimNames as PN
import Wok.TypeChecking.Types (CType (..), TyCon (..))

-- ---------------------------------------------------------------------------
-- The RC intrinsic names
--
-- These MUST match the hint keys in 'Wok.Interp.RC.Prim.rcPrimTable'.

dupHint, dropHint :: Text
dupHint  = PN.rcDupName
dropHint = PN.rcDropName

-- | The M3 stored-continuation move-out once-sink (@__cont_take cell@). Its CELL
-- argument is a BORROW (the prim reads the cell, empties it in place, and returns
-- the held continuation; it does NOT consume the cell handle), so the cell stays
-- owned by its binder and is dropped at its real last use --- this frees the
-- now-empty 'NContCell' exactly once. Its RESULT is a continuation: a resume
-- binder (added to 'ctxResume' in the 'Let' rule) whose application is a MOVE-OUT
-- (the runtime 'moveOutCont' frees the 'NCont' shell), so NO @__rc_drop@ is placed
-- on the resume path. The elaborator routes a genuine @Std.Control.__cont_take@
-- reference to an 'APrim' carrying this @(module, name)@ key (backlog #12 §2.7),
-- so the recognizers match the 'APrim' head by identity --- a user binding hinted
-- @__cont_take@ resolves to an 'AVar' and is never matched. MUST match the impl
-- name key in "Wok.Interp.RC.Prim"/"Wok.Interp.Prim".

-- | True iff the RHS is a saturated @__cont_take cell@ call (the M3 move-out): its
-- result is a continuation that resumes as a move-out, and its cell argument is a
-- borrow. The result binder is threaded into 'ctxResume'.
isContTakeRhs :: Rhs -> Bool
isContTakeRhs (RApp (APrim k) _) = k == PN.contTakeKey
isContTakeRhs _                  = False

-- | True iff @rhs@ binds a CONTINUATION resume binder, given the resume binders
-- @resume@ already in scope: a @__cont_take cell@ call (M3 move-out) OR a pure
-- alias @let k2 = t@ of an existing resume binder @t@ (the elaborator's split of
-- @let k2 = __cont_take c@ into @let t = __cont_take c ; let k2 = t@). The new
-- binder then joins the resume set. Shared by the pass ('Ctx' 'ctxResume') and the
-- lint ('LintEnv' 'leResume') so both treat the take-result's application as a
-- move-out identically.
aliasesResume :: Set Unique -> Rhs -> Bool
aliasesResume resume r = isContTakeRhs r || case r of
  RAtom (AVar n) -> nameUniq n `Set.member` resume
  _              -> False

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
    go (Handle e h)        = max (go e) (handlerMaxU h)

handlerMaxU :: Handler -> Int
handlerMaxU h =
  let (rb, rbody) = hReturn h
      -- Include the self-instance and handler-parameter binder uniques: a
      -- hand-built or generated handler may carry an 'hSelf'/'hParam' unique
      -- larger than any arm/body unique, and the inserted @_dup@/@_drop@ binders
      -- must not collide with them. (Elaborator output keeps these below the arm
      -- uniques, but seeding defensively costs nothing and removes the footgun.)
      selfParamUs = map (uOf . bndName) (hParamBinders h ++ maybe [] pure (hSelf h))
  in maximum (uOf (bndName rb) : exprMaxU rbody : map opArmMaxU (hOps h) ++ selfParamUs)

opArmMaxU :: OpArm -> Int
opArmMaxU (OpArm _ _ args resume body) =
  maximum (exprMaxU body : uOf (bndName resume) : map (uOf . bndName) args)

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
rhsMaxU (RReuseCon tok _ as) = foldr (max . atomMaxU) (atomMaxU tok) as
rhsMaxU (RForeignCall _ _ _ _ as) = foldr (max . atomMaxU) (-1) as

atomMaxU :: Atom -> Int
atomMaxU (AVar n) = uOf n
atomMaxU (ALit _) = -1
atomMaxU (APrim _) = -1

-- ---------------------------------------------------------------------------
-- Boxed-ness
--
-- 'isBoxedType' / 'boxedBinder' are defined in "Wok.IR.Escape" (the escape rules
-- need them) and imported here.

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
-- Escape / borrowership predicates
--
-- The LetRec/closure escape + consume predicate family ('nonHeadOccs',
-- 'nonHeadOccsRhs', 'escapesFrom', 'rlamSiblingCaptureEscapes',
-- 'letRecMemberEscapes', 'letRecMemberConsumesCaptureNonEscaping', 'consumingOccs',
-- 'letRecCapturesEnclosing', 'letRecEnclosingCaptureEscapes', 'rawEnclosingFv')
-- lives in "Wok.IR.Escape" --- the single source of truth for escaping
-- positions ('escapingAtomsRhs'), shared with the boundary guard
-- ('Wok.IR.Reachable'). Imported above; not redefined here.

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
-- A 'LetRec' group's closures appear in coverage as ORDINARY acyclic RC (M2a-2):
-- the group is one shared 'NEnv' cell plus per-member inline @RVRecMember@ handles
-- (Task 3 runtime), so a group whose member bodies and body are themselves covered
-- is covered --- no region bookkeeping. The escape / cross-region / consuming-capture
-- shapes are NOT rejected HERE; they are gated by the boundary guard ('Reachable',
-- @letRecEnclosingCaptureEscapes@ et al.) BEFORE the pass runs, so a program that
-- reaches 'insertRC' is already non-escaping / non-consuming and is soundly
-- instrumented as a DAG.
coveredExpr :: Expr -> Bool
coveredExpr (Let _ r e)         = coveredRhs r && coveredExpr e
coveredExpr (Ret _)             = True
coveredExpr (Case _ alts)       = all coveredAlt alts
coveredExpr (LetJoin _ _ jb e)  = coveredExpr jb && coveredExpr e
coveredExpr Jump{}              = True
coveredExpr (LetRec defs e)     =
  all (\(_, _, body) -> coveredExpr body) defs && coveredExpr e
-- M2b-1 (Task 2): a 'Handle' is covered iff its handler is in the M2b-1
-- RC-supported fragment ('m2bHandlerInFragmentStore' --- the CONTEXT-FREE part of
-- the admission test, ADMITTING the M3 store route so its arm is instrumented and
-- heap-balanced) AND the handled expr + every arm body are themselves covered. An
-- OUT-of-fragment handler stays 'False', so the pass leaves it untouched.
-- NOTE: the boundary guard ('Wok.IR.Reachable') additionally rejects a handler whose
-- arm captures an enclosing boxed local --- a context-dependent check this context-free
-- predicate cannot make, so 'coveredExpr' is intentionally more permissive there. The
-- guard ALSO still rejects the store route (the non-store form 'm2bHandlerInFragment')
-- until M3 Task 4's carrier-wall check; production runs the guard before the pass, and
-- the M3 oracle bypasses the guard via 'runModuleRCUnchecked'. See
-- 'm2bHandlerInFragmentStore' in "Wok.IR.Escape" for the full rationale.
coveredExpr (Handle e h)        =
  m2bHandlerInFragmentStore h && coveredExpr e && coveredHandler h

coveredAlt :: Alt -> Bool
coveredAlt (AltCon _ _ e) = coveredExpr e
coveredAlt (AltLit _ e)   = coveredExpr e
coveredAlt (AltDefault e) = coveredExpr e

-- | A handler's arm bodies (the return body + every op-arm body) are themselves
-- within the covered fragment.
coveredHandler :: Handler -> Bool
coveredHandler h =
  coveredExpr (snd (hReturn h)) && all (coveredExpr . oaBody) (hOps h)

-- | RHS coverage. A standalone 'RLam' is covered iff its body is covered (its
-- captures are moved into the closure cell at the build site --- see 'ownedOccs' /
-- 'moveOperandUniques' --- and the body is instrumented as its own owned scope ---
-- see 'ownRhs'). An 'ROp' (an effect operation) is covered (M2b-1): its operands
-- MOVE like 'RApp' arguments, routed through the same 'Let'-case machinery; it only
-- ever appears inside an in-fragment 'Handle's instrumented region.
coveredRhs :: Rhs -> Bool
coveredRhs (RLam _ e) = coveredExpr e
coveredRhs _          = True

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
  | coveredExpr body =
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
    -- | M2a-2 (Task 4) --- BORROWED values: 'LetRec' group members (each a borrow
    -- of the shared env via @RVRecMember@) and borrowed captures bound into a
    -- member body. A borrowed var is NOT owned: a call-head occurrence emits
    -- nothing (a known/borrow call), and a CONSUMING occurrence (a move into a
    -- con/record/arg/result) emits a @__rc_dup@ at that use --- DUP-ON-CONSUME ---
    -- so the consumer gets an independent owned unit (an @incref@ of the env), while
    -- the borrow keeps owning nothing. This subsumes the old per-member region
    -- treatment (members no longer own a counted cell; the shared env does) and sets
    -- up #1 consuming-captures (latent here: only borrow-reads occur for now).
  , ctxBorrow :: Set Unique
    -- | M2a-2 (Task 4) --- SYNTHETIC owned env values kept ALIVE to every path leaf.
    -- The shared 'NEnv' of a 'LetRec' group is one owned value, represented by the
    -- group's representative member binder (member 0): it is in @delta@ but is never
    -- free in the body (members are borrows), so the standard last-use machinery
    -- would drop it too early. Membership here suppresses the 'Let'-case prompt-drop
    -- so the env survives until each leaf ('Ret'/'Jump'/'Case' arm), where the
    -- ordinary @delta@-drop fires it exactly once per path --- a single @__rc_drop@
    -- of member 0, which the runtime resolves to @dropAddr envAddr@.
  , ctxEnvAlive :: Set Unique
    -- | M2a-2 (Task 4) --- maps each 'LetRec' group member's 'Unique' to its group's
    -- shared-env owning unit (member 0). Used by the 'Ret' rule: RETURNING a member
    -- transfers that env handle out, so the env unit (member 0) MOVES out rather than
    -- being dropped. (Mirrors the lint's 'leEnvAlias'.)
  , ctxEnvAlias :: Map Unique Unique
    -- | M2b-1 (Task 2) --- the op-arm RESUME binders ('oaResume') in scope. The
    -- continuation is an affine OWNED local of the arm body whose APPLICATION is a
    -- MOVE (the move-out: resuming hands the captured frames back), NOT the ordinary
    -- borrow-on-call a function value gets. So a saturated @resume(x)@ as a call HEAD
    -- consumes @resume@ (no extra drop on that path), while an op arm that never
    -- applies @resume@ (abort) drops it at its last use --- routing to the @NCont@
    -- cascade at runtime. Membership here makes the move helpers count the call head
    -- as a move (see 'ownedOccs' / 'moveOperandUniques'); the lint mirror is
    -- 'leResume'. One-shot (Multiplicity) guarantees at most one application, so the
    -- move never double-consumes.
  , ctxResume :: Set Unique
  }

ctx0 :: Map Unique Binder -> Ctx
ctx0 env = Ctx env Map.empty Set.empty Set.empty Set.empty Map.empty Set.empty

ctxBind :: Binder -> Ctx -> Ctx
ctxBind b c = c { ctxEnv = Map.insert (binderUnique b) b (ctxEnv c) }

ctxBinds :: [Binder] -> Ctx -> Ctx
ctxBinds bs c = foldr ctxBind c bs

-- | ALIAS-OF-EXEMPT (M2a-1 hardening). True iff @rhs@ is @RAtom (AVar n)@ where
-- @n@ is in the supplied exempt set (an uncounted-region sibling). Such a binding
-- is a BORROW of the same region member, not an independent owned cell: it must
-- not enter the owned set, must not be dup'd/dropped, and stays exempt for the
-- rest of the scope. Shared by the pass ('ownExpr', exempt = 'ctxExempt') and the
-- balance lint ('checkExpr', exempt = 'leExempt'), which take different exempt
-- sets but the same shape.
aliasesExemptIn :: Set Unique -> Rhs -> Bool
aliasesExemptIn exempt (RAtom (AVar n)) = nameUniq n `Set.member` exempt
aliasesExemptIn _       _               = False

-- | ALIAS-OF-BORROW (M2a-2). True iff @rhs@ is @RAtom (AVar n)@ where @n@ is a
-- BORROWED value (a 'LetRec' member captured as an inline @RVRecMember@, in
-- @ctxBorrow@). Such a binding is a pure RENAME of a borrow, not an independent
-- owned cell: it owns nothing, so it must NOT enter the owned set, must NOT be
-- dup'd or dropped at the alias site, and stays BORROWED for the rest of the
-- scope (a consuming use of the alias dup-on-consumes the shared env at THAT use;
-- a read / call-head emits nothing). Without this an alias of an escaping member
-- (E4 @let a = f ; h = \\m -> a (m+1)@) is treated as owned, seeded and dropped
-- inside the escaping closure body, and the closure's cascade-drop then
-- double-frees the shared env. The lint mirror is 'aliasesBorrowIn' over
-- 'leBorrow'. Shared shape with 'aliasesExemptIn'; distinct set.
aliasesBorrowIn :: Set Unique -> Rhs -> Bool
aliasesBorrowIn borrow (RAtom (AVar n)) = nameUniq n `Set.member` borrow
aliasesBorrowIn _       _               = False

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
      -- ESCAPE-BY-RETURN (M2a-2 Task 4 + BLOCKER 1, GENERALISED to captures). A
      -- BORROWED value (in 'ctxBorrow' --- a 'LetRec' member OR a member-body
      -- borrowed enclosing CAPTURE) named by the returned atom carries a shared cell
      -- OUT to the caller: a member carries the shared 'NEnv'; a capture carries the
      -- captured box itself ('valueChildren' makes @__rc_dup@ incref the right cell
      -- either way). Two cases, told apart by whether THIS scope OWNS the
      -- corresponding env handle (a member's env unit, member 0, is in 'ctxEnvAlive'):
      --
      --   * TRANSFER (group body): the scope holds the env's single owning handle
      --     (env0 in 'ctxEnvAlive'). Returning a member MOVES that one handle out ---
      --     it must NOT be dropped (a drop would free the env the caller still holds
      --     => UAF) and needs NO dup (the handle simply transfers). Its env unit
      --     joins 'retEnvs' (protected from 'dead'). Only a member with an env-alias
      --     mapping into 'ctxEnvAlive' is a transfer.
      --   * ESCAPE (member body): the body BORROWS the value (no owned scope handle ---
      --     'ctxEnvAlive' is empty here). Returning a sibling creates a NEW counted
      --     reference to the env that escapes; returning a borrowed capture creates a
      --     new counted reference to the captured box that escapes. EITHER must
      --     dup-on-consume (an @incref@), exactly as the 'Let'/'Jump' move-into-operand
      --     paths already do for a moved borrow. Without this dup the escaped handle is
      --     released by the env cascade (a member) / the env's capture-field cascade (a
      --     capture) at scope exit while the caller still holds it --- the verified
      --     member-body sibling-escape double-free, and its CAPTURE analogue (a
      --     member body returning a borrowed capture => use-after-free of that
      --     capture). A returned capture has no env-alias, so it never joins 'retEnvs'.
      retBorrows = [ u | u <- Set.toList (atomVars a), u `Set.member` ctxBorrow ctx ]
      isTransfer u = case Map.lookup u (ctxEnvAlias ctx) of
                       Just e  -> e `Set.member` ctxEnvAlive ctx
                       Nothing -> False
      retEnvs  = Set.fromList [ e | u <- retBorrows, isTransfer u
                                  , Just e <- [Map.lookup u (ctxEnvAlias ctx)] ]
      escBorrows = [ u | u <- retBorrows, not (isTransfer u) ]
      borrowDup  = Map.toList (Map.fromListWith (+) [ (u, 1 :: Int) | u <- escBorrows ])
      dead     = delta `Set.difference` owned `Set.difference` retEnvs
      (sup1, dups)    = mkDupsForVars sup (ctxEnv ctx) borrowDup
      (sup2, dropped) = dropsFor (ctxEnv ctx) sup1 dead (Ret a)
  in (sup2, foldr ($) dropped dups)

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
      -- DUP-ON-CONSUME (M2a-2 Task 4): a BORROWED value (a 'LetRec' member or a
      -- borrowed capture, in 'ctxBorrow') moved into a con/record/non-head arg gets
      -- ONE @__rc_dup@ at this use (an @incref@ of the env it names), so the new
      -- cell owns an independent unit; the borrow keeps owning nothing. A call-head
      -- occurrence is NOT a move (it is excluded by 'moveOperandUniques'), so a
      -- recursive call emits nothing. The dup'd unit is released by the consuming
      -- cell's own drop --- ordinary acyclic accounting.
      -- ALIAS-OF-BORROW (M2a-2): @let a = f@ where @f@ is a borrowed member is a
      -- pure RENAME, NOT a consuming move --- it owns nothing, so emit no
      -- dup-on-consume here (the real escape, e.g. the closure that captures @a@,
      -- dups the shared env at its own use). 'a' is made borrowed in 'ctx'' below.
      aliasesBorrow = aliasesBorrowIn (ctxBorrow ctx) rhs
      -- M3 (Task 3): @rhs@ binds a CONTINUATION resume binder iff it is a
      -- @__cont_take cell@ call OR a pure alias of an existing resume binder
      -- (@let k2 = t@ where @t@ is in 'ctxResume' --- the elaborator's split of
      -- @let k2 = __cont_take c@). Either way the new binder @b@ joins 'ctxResume'.
      -- 'aliasesResume' (the shared helper) is the SAME predicate the lint mirror
      -- uses against 'leResume'.
      bindsResume = aliasesResume (ctxResume ctx) rhs
      borrowMoves
        | aliasesBorrow = []
        | otherwise     = [ u | u <- moveOperandUniques rhs, u `Set.member` ctxBorrow ctx ]
      borrowDup   = Map.toList (Map.fromListWith (+) [ (u, 1 :: Int) | u <- borrowMoves ])
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
      -- ALIAS-OF-EXEMPT (M2a-1 hardening): @let b = AVar s@ where @s@ is an
      -- uncounted-region sibling (in 'ctxExempt'). 'b' is a BORROW of the same
      -- region member, not an independent owned cell: the group drop already
      -- releases the member once. So 'b' must NOT enter the owned set ('bAdded'
      -- empty here) and must be made exempt for the rest of the scope (see
      -- 'ctx''), so the pass emits NO '__rc_dup' (none needed --- 's' is exempt,
      -- already absent from 'rhsOcc') and NO '__rc_drop' (a drop of 'b' would
      -- double-free the member: cell-drop + group-drop). Exempt-ness is
      -- transitive: an alias of an alias is itself exempt, because 'ctx'' carries
      -- 'b' in 'ctxExempt' for 'body'. An ordinary (non-exempt) alias is
      -- unaffected and keeps owning 'b' exactly as before.
      aliasesExempt = aliasesExemptIn (ctxExempt ctx) rhs
      bAdded
        | aliasesExempt          = Set.empty
        | aliasesBorrow          = Set.empty   -- a borrow-alias owns nothing
        | boxedBinder b          = Set.singleton (binderUnique b)
        | otherwise              = Set.empty
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
                       -- A synthetic shared-env value (member 0 of an enclosing
                       -- 'LetRec') is kept alive past every prompt-drop: it is never
                       -- free in 'body' (members are borrows) but must survive to the
                       -- path leaf, where the ordinary 'delta'-drop releases it once.
                       || v `Set.member` ctxEnvAlive ctx
      deadNow   = afterBind `Set.difference` deltaBody
      ctx'      | aliasesExempt =
                    (ctxBind b ctx) { ctxExempt = Set.insert (binderUnique b) (ctxExempt ctx) }
               | aliasesBorrow =
                    -- ALIAS-OF-BORROW (M2a-2): @b@ becomes a borrow of the same value.
                    -- M2a-2 Stage B: PROPAGATE the env-alias too --- if the aliased
                    -- value @n@ maps to a shared-env owning unit (it is a 'LetRec'
                    -- member or a transitive alias of one), then @b@ aliases the SAME
                    -- env unit. This lets the 'Ret' rule recognise an escaping
                    -- ALIAS-of-a-member (e.g. @let ax = f ; let ay = ax ; ay@) as
                    -- carrying the env out, so the scope's env-alive handle is NOT
                    -- ALSO dropped (which double-freed the env the escaped alias
                    -- still holds). Without this the alias's env unit was invisible
                    -- to 'retEnvs'.
                    let inheritedEnv =
                          case rhs of
                            RAtom (AVar n) ->
                              maybe Map.empty
                                    (Map.singleton (binderUnique b))
                                    (Map.lookup (nameUniq n) (ctxEnvAlias ctx))
                            _ -> Map.empty
                    in (ctxBind b ctx)
                         { ctxBorrow   = Set.insert (binderUnique b) (ctxBorrow ctx)
                         , ctxEnvAlias = inheritedEnv `Map.union` ctxEnvAlias ctx }
               -- M3 (Task 3): @let k2 = __cont_take cell@ binds a CONTINUATION, OR
               -- @let k2 = t@ aliases an existing resume binder @t@. Track @k2@ as a
               -- resume binder so applying it (@k2 v@) is treated as a MOVE-OUT (the
               -- head is counted as consumed, no @__rc_drop@ is placed on the resume
               -- path) --- mirroring the runtime, where resuming the taken 'NCont'
               -- runs 'moveOutCont' (frees the shell). Without this, the
               -- borrow-on-call + last-use machinery would place a @__rc_drop k2@
               -- that double-frees the already-resumed shell. The alias case is
               -- needed because the elaborator splits @let k2 = __cont_take c@ into
               -- @let t = __cont_take c ; let k2 = t@. A resume binder is affine
               -- (one-shot), so the alias is a RENAME, not a second owner.
               | bindsResume =
                    (ctxBind b ctx)
                      { ctxResume = Set.insert (binderUnique b) (ctxResume ctx) }
               | otherwise     = ctxBind b ctx
  in
    -- 1. emit the dups the rhs needs (before the rhs runs): the owned-operand dups
    --    AND the borrowed-value dup-on-consume (an env incref per moved borrow);
    let (sup1, dups)    = mkDupsForVars sup env (dupPlan' ++ borrowDup)
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
      -- DUP-ON-CONSUME (M2a-2 Task 4): a borrowed value (a 'LetRec' member / borrowed
      -- capture) passed as a jump arg is a move into the join param --- one env
      -- incref per such arg. Its env-alive owning unit (member 0), if seeded into
      -- this delta, is dead here (never free in the join body) and dropped by the
      -- 'dead' set above; the dup'd unit flows into the join and is dropped there.
      borrowArgs = [ u | u <- atomUniques as, u `Set.member` ctxBorrow ctx ]
      borrowDup  = [ (u, 1 :: Int) | u <- borrowArgs ]
      (sup1, dups)    = mkDupsForVars sup (ctxEnv ctx) borrowDup
      (sup2, dropped) = dropsFor (ctxEnv ctx) sup1 dead (Jump j as)
  in (sup2, foldr ($) dropped dups)

-- LetRec (M2a-2 Task 4): a group is ONE shared environment cell ('NEnv') plus
-- per-member inline @RVRecMember@ handles --- ordinary acyclic refcounting, no
-- region special-casing.
--
-- THE SHARED ENV is a SYNTHETIC owned value (the runtime allocates exactly one
-- 'NEnv' at @rc = 1@, or reuses the static empty-env sentinel when the group
-- captures nothing). It has a single owner: the scope. We represent it by the
-- group's REPRESENTATIVE member binder --- member 0 --- because a @__rc_drop@ of
-- any member resolves to @dropAddr envAddr@ (the env is the member's only counted
-- child). So member 0's 'Unique' rides in @delta@ as the env's owning unit and is
-- dropped EXACTLY ONCE at the group's combined last use: it is added to
-- 'ctxEnvAlive' so it survives every 'Let' prompt-drop and is released by the
-- ordinary @delta@-drop at each path leaf ('Ret'/'Jump'/'Case' arm) --- one
-- @__rc_drop member0@ per path, never N. For a capture-free group @envAddr@ is the
-- static sentinel, so that drop is a runtime no-op (harmless, uniform).
--
-- MEMBERS ARE BORROWED ('ctxBorrow'): a call-head occurrence emits nothing (a
-- known/borrow call); a CONSUMING occurrence (a member moved into a con/record/arg
-- or returned --- an escape) gets a @__rc_dup@ at that use (an @incref@ of the env)
-- so the consumer owns an independent unit, while the borrow keeps owning nothing.
-- This is ordinary Perceus on a DAG; member references are no longer a special
-- uncounted region.
--
-- CAPTURES are the enclosing boxed owned locals the group closes over (member-body
-- free vars minus params minus group binders, restricted to currently-owned boxed
-- non-borrowed locals). Each DISTINCT capture is MOVED into the env ONCE at build
-- (the env owns it, freed once via the 'NEnv' cascade); a capture that also
-- survives into the body keeps one extra unit, so it is dup'd exactly ONCE --- NOT
-- once per member. Inside each member body a capture is BORROWED ('ctxBorrow'):
-- a read emits nothing; a consuming use gets dup-on-consume (the #1 mechanism;
-- latent here --- consuming captures are still boundary-rejected, so only
-- borrow-reads occur, but the wiring is in place for Task 6).
ownExpr ctx sup delta (LetRec defs body) =
  let groupU     = Set.fromList [ binderUnique b | (b, _, _) <- defs ]
      -- The representative member (member 0) IS the shared-env owning unit.
      env0       = case defs of
        ((b, _, _) : _) -> binderUnique b
        []              -> error "ownExpr: empty LetRec group"
      env        = ctxEnv ctx
      -- One member's boxed owned non-borrowed enclosing captures (free vars of its
      -- body minus its params and the group binders, restricted to currently-owned
      -- boxed locals). Borrowed-ness is read from 'ctxBorrow'/'ctxExempt' (an
      -- enclosing capture that is itself a borrow stays a borrow, never moved into
      -- the env). Boxed-ness is read from the binder in scope.
      memberCaps (_, ps, dbody) =
        let params = Set.fromList (map binderUnique ps)
        in Set.fromList
             [ u
             | u <- Set.toList (freeVarsExpr dbody `Set.difference` params
                                  `Set.difference` groupU)
             , u `Set.member` delta
             , u `Set.notMember` ctxExempt ctx, u `Set.notMember` ctxBorrow ctx
             , Just b <- [Map.lookup u env], boxedBinder b ]
      -- The DISTINCT captures of the whole group: each is moved into the single
      -- shared env ONCE (the env's 'NEnv' holds one field per distinct capture, so
      -- the env cascade decrefs each exactly once). No multiset --- one env, not N.
      allCaps    = Set.unions [ memberCaps d | d <- defs ]
      laterBody  = freeVarsExpr body
      -- A surviving capture (still free in the body) needs ONE dup: one unit moved
      -- into the env, one kept for the body. A capture not used in the body is moved
      -- in with its existing owned unit (no dup).
      dupPlan'   = [ (u, 1) | u <- Set.toList allCaps, u `Set.member` laterBody ]
      -- A capture is relinquished from @delta@ (moved into the env) unless it
      -- survives into the body (then it keeps its extra owned unit there).
      consumedCaps = Set.filter (`Set.notMember` laterBody) allCaps
      ctxIn      = ctx { ctxEnv      = foldr (\(b, _, _) -> Map.insert (binderUnique b) b)
                                             (ctxEnv ctx) defs
                       , ctxBorrow   = ctxBorrow ctx `Set.union` groupU
                       , ctxEnvAlive = Set.insert env0 (ctxEnvAlive ctx)
                       , ctxEnvAlias = ctxEnvAlias ctx `Map.union` groupEnvAlias defs }
      -- Instrument each member body in isolation: a fresh scope (its boxed params
      -- owned), siblings borrowed (a recursive call emits nothing), AND this
      -- member's enclosing captures borrowed (a read emits nothing; a consuming use
      -- dups). Joins / env-alive / alias reset (they do not cross a closure boundary).
      onDef sp (b, ps, dbody) =
        let caps   = memberCaps (b, ps, dbody)
            dEnv   = Map.fromList [ (binderUnique p, p) | p <- ps ]
                       `Map.union` Map.fromList [ (binderUnique g, g) | (g, _, _) <- defs ]
                       `Map.union` ctxEnv ctx
            -- MEMBER-BODY SIBLING ESCAPE (M2a-2 BLOCKER 1). A member body that
            -- RETURNS / JUMPS / moves a sibling carries the shared env OUT, but the
            -- member body does NOT own the scope's env-alive handle (the env is
            -- BORROWED here --- it stays alive because the member value being called
            -- is borrowed by its caller for the body's duration). So we propagate the
            -- group env-alias ('groupEnvAlias') --- so 'Ret'/'Jump' can recognise an
            -- escaping sibling and dup-on-consume its env --- but leave 'ctxEnvAlive'
            -- EMPTY: there is no owned env handle to transfer here. The 'Ret' rule
            -- then treats a returned sibling as an ESCAPE (dup the env), not a
            -- transfer (which would skip the dup and double-free the single 'NEnv').
            dCtx   = Ctx dEnv Map.empty (ctxExempt ctx)
                         (ctxBorrow ctx `Set.union` groupU `Set.union` caps)
                         Set.empty (groupEnvAlias defs) Set.empty
            dDelta = Set.fromList [ binderUnique p | p <- ps, boxedBinder p ]
            (sp', dbody') = ownExpr dCtx sp dDelta dbody
        in (sp', (b, ps, dbody'))
      (sup1, defs') = mapAccumLPairs onDef sup defs
      -- Instrument the body. The shared env (member 0) is owned and kept alive to
      -- the leaves (in 'ctxEnvAlive'); the group binders are borrowed (a recursive
      -- call emits nothing). A capture moved into the env leaves the body's delta;
      -- a surviving capture stays (its extra dup feeds it).
      bodyDelta     = (delta `Set.difference` consumedCaps) `Set.union` Set.singleton env0
      (sup2, body') = ownExpr ctxIn sup1 bodyDelta body
      -- Emit the surviving-capture dups BEFORE the LetRec, so each carries its extra
      -- unit at build: one moves into the env, one stays for the body.
      (sup3, dups)  = mkDupsForVars sup2 env dupPlan'
  in (sup3, foldr ($) (LetRec defs' body') dups)

-- Handle (M2b Task 2): an effect handler in the RC-supported fragment
-- ('m2bHandlerInFragment' --- tail position, optional handler parameter, no
-- escaping resume; gated by 'coveredExpr'). Four independent instrumentation
-- regions:
--
--   * THE HANDLED EXPR @e@ runs FIRST, in the enclosing scope, so it is
--     instrumented under the CURRENT owned set @delta@ exactly like the
--     sub-expression of any other covered construct --- it consumes the outer
--     owned vars it uses (and drops the dead ones) on its own paths.
--     BATON: if there is a handler parameter (@hParam = Just pb@), the Handle
--     CONSUMES it (ownership transfers into the arms), so @pb@'s boxed unique is
--     REMOVED from the @delta@ given to @e@ --- @e@ must not also drop it.
--   * THE RETURN ARM @(rb, rbody)@ runs on normal completion: @rbody@ is a body
--     that OWNS its binder @rb@ AND the handler parameter @pb@ (the baton
--     arrives via the @return v -> (v, s)@ path), instrumented as a FRESH owned
--     scope. Last-use placement drops @rb@/@pb@ if boxed and unused.
--   * EACH OP ARM @OpArm _ _ args resume body@ runs when its op fires: @body@
--     OWNS @args ++ [resume] ++ [pb]@ (the boxed ones) on entry, a fresh owned
--     scope. The baton @pb@ is handed to the arm so last-use decides: a @set@
--     arm that replaces the state drops the old @pb@; a @get@ arm that re-uses
--     it passes it to @resume(s, s)@; an abort arm drops it. 'ctxResume' and
--     the resume-move logic are unchanged.
--
-- The arms are instrumented as FRESH scopes (their @delta@ reset to only the
-- arm's own boxed binders + @pb@) rather than inheriting the outer @delta@: @e@
-- has already consumed the outer owned vars on its own paths. The shared 'Ctx'
-- (env, exempt, borrow) is kept; only the owned set is reset. The lint mirror
-- ('checkExpr') resets per-path counts identically.
ownExpr ctx sup delta (Handle e h)
  | m2bHandlerInFragmentStore h =
      let (rb, rbody) = hReturn h
          mParam      = hParam h
          paramBs     = maybe [] pure mParam
          paramBoxedU = Set.fromList [ binderUnique pb | pb <- paramBs, boxedBinder pb ]
          -- Handle CONSUMES the param: subtract from delta so enclosing scope
          -- does not also drop it (the arms own it instead).
          deltaE      = delta `Set.difference` paramBoxedU
          (sup1, e')  = ownExpr ctx sup deltaE e
          -- Return arm: owns its binder AND the handler parameter.
          retCtx      = ctxBinds (rb : paramBs) (armCtxReset ctx)
          retDelta    = Set.fromList [ binderUnique rb | boxedBinder rb ]
                          `Set.union` paramBoxedU
          (sup2, rbody') = ownExpr retCtx sup1 retDelta rbody
          (sup3, ops') = mapAccumLPairs (ownOpArm ctx mParam) sup2 (hOps h)
      in (sup3, Handle e' (h { hReturn = (rb, rbody'), hOps = ops' }))
  | otherwise = (sup, Handle e h)   -- out of fragment: leave unchanged

-- | A fresh ownership scope for a handler arm: a handler arm runs in a NEW control
-- context (the handler's continuation), so the join table, the kept-alive shared-env
-- units, and the env-alias map do NOT cross the handler boundary --- reset them
-- (mirroring 'ownRhs (RLam ...)' / the 'LetRec' member 'dCtx'). The enclosing
-- 'ctxEnv' (name/type resolution), 'ctxExempt', and 'ctxBorrow' are kept; the owned
-- set is reset by the caller to only the arm's own binders.
--
-- NOTE (F3 coverage): clearing 'ctxJoins' means a value-position arm's 'Jump' to the
-- outer answer-join ('hAnswerJoin = Just j') is NOT statically audited by
-- 'lintInstrumented' from the arm's perspective (j is absent from the arm's fresh
-- ctxJoins, so the Jump is treated as a tail transfer to an unknown join). The
-- runtime heap oracle ('mutationCaughtM2b' in the heap-imbalance branch) covers this
-- shape; see 'test/rc-m2b/26-value-shared-local.wok' for a concrete corpus example.
armCtxReset :: Ctx -> Ctx
armCtxReset ctx = ctx
  { ctxJoins    = Map.empty
  , ctxEnvAlive = Set.empty
  , ctxEnvAlias = Map.empty
  , ctxResume   = Set.empty }

-- | Instrument one op arm body as a fresh owned scope (its boxed @args@, the
-- @resume@ binder, AND the handler parameter @mParam@ if present, all owned on
-- entry). The resume binder is added to 'ctxResume' so an application of it
-- counts as the consuming move-out (no extra drop on the resume path); an arm
-- that never applies it (abort) drops it at its last use. The parameter binder
-- is included in @bs@ so last-use machinery handles the baton: a @set@ arm that
-- replaces the state drops the old param; a @get@ arm passes it to @resume@.
ownOpArm :: Ctx -> Maybe Binder -> Supply -> OpArm -> (Supply, OpArm)
ownOpArm ctx mParam sup (OpArm lbl op args resume body) =
  let paramBs  = maybe [] pure mParam
      bs       = args ++ [resume] ++ paramBs
      armCtx   = (ctxBinds bs (armCtxReset ctx))
                   { ctxResume = Set.singleton (binderUnique resume) }
      armDelta = Set.fromList [ binderUnique b | b <- bs, boxedBinder b ]
      (sup', body') = ownExpr armCtx sup armDelta body
  in (sup', OpArm lbl op args resume body')

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
  -- BORROW-ON-CALL (M2a-2 Task 1): applying a function value READS the head @f@
  -- (the call does not move @f@ out of the callee --- 'enterRC' no longer consumes
  -- the closure cell). So the head is NOT a move here; it stays owned by its binder
  -- and is dropped at its real last use by the 'Let'/'Ret' last-use machinery,
  -- exactly like any other value. Only the ARGUMENTS are moves.
  --
  -- M2b-1 EXCEPTION (Task 2): a RESUME binder ('ctxResume') applied as a call head
  -- IS a move (the move-out: resuming hands the captured frames back). So when the
  -- head names a resume binder, count it too --- the application consumes @resume@,
  -- and no extra @__rc_drop@ is placed on that path.
  -- M3 (Task 3): @__cont_take cell@ BORROWS its cell argument (the prim reads and
  -- empties the cell in place, returning the held continuation; it does NOT move
  -- the cell out). So the cell stays owned and is dropped at its last use, which
  -- frees the now-empty cell once. Count nothing here.
  RApp (APrim k) _
    | k == PN.contTakeKey -> Map.empty
  RApp f as      -> count (resumeHead f ++ as)
  RCon _ as      -> count as
  RRecord _ flds -> count (map snd flds)
  RProj _ _      -> Map.empty                 -- borrow, not a move
  -- The FBIP reuse form is introduced by a post-pass that runs AFTER this pass
  -- (and after 'balanceLint'); ownership accounting never sees it.
  RReuseCon{}    -> error "RReuseCon: produced only by reusePairing post-pass (after insertRC/balanceLint)"
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
         , u `Set.member` delta
         , u `Set.notMember` ctxExempt ctx, u `Set.notMember` ctxBorrow ctx ]
  ROp _ _ _ as   -> count as
  -- Foreign call: treat args as owned moves (like 'RApp' arguments). No call-head
  -- borrow because the callee is identified by (lib, sym) text, not an 'Atom'.
  -- Task 6 will refine per-argument borrow semantics; for now, all args are moves.
  RForeignCall _ _ _ _ as -> count as
  where
    -- A BORROWED operand (a 'LetRec' member / borrowed capture, in 'ctxBorrow') is
    -- NEVER an owned move --- even when its 'Unique' also names the shared env's
    -- owning unit (member 0 lives in @delta@ as the env, but a move of member 0 is a
    -- BORROW with dup-on-consume, not a relinquish of the env's scope handle). So
    -- exclude 'ctxBorrow' here; the env unit is released only by its leaf-drop.
    count atoms =
      Map.fromListWith (+)
        [ (u, 1)
        | AVar n <- atoms, let u = nameUniq n
        , u `Set.member` delta
        , u `Set.notMember` ctxExempt ctx, u `Set.notMember` ctxBorrow ctx ]
    -- The call head as a singleton MOVE list iff it names a resume binder
    -- (M2b-1 move-out); empty for an ordinary borrow-on-call head.
    resumeHead (AVar n) | nameUniq n `Set.member` ctxResume ctx = [AVar n]
    resumeHead _ = []

-- | The MOVE-position variable 'Unique's of a RHS, IGNORING ownership (no @delta@
-- filter): every operand that is COPIED into a heap cell or transferred onward ---
-- 'RApp' arguments (NOT the borrowed call head), 'RCon'/'RRecord' fields, an
-- 'RAtom' alias, 'ROp' arguments, and an 'RLam''s free captures. An 'RProj' borrows
-- (no move). Used to find BORROWED values (members / borrowed captures) in a
-- consuming position so the 'Let' rule can emit dup-on-consume; the owned-operand
-- accounting is 'ownedOccs', which filters to @delta@.
moveOperandUniques :: Rhs -> [Unique]
moveOperandUniques rhs = case rhs of
  RAtom a        -> atomUs [a]
  -- M3 (Task 3): @__cont_take cell@ BORROWS its cell argument (see 'ownedOccs').
  RApp (APrim k) _
    | k == PN.contTakeKey -> []
  RApp _ as      -> atomUs as
  RCon _ as      -> atomUs as
  RRecord _ flds -> atomUs (map snd flds)
  RProj _ _      -> []
  RReuseCon{}    -> error "RReuseCon: produced only by reusePairing post-pass (after insertRC/balanceLint)"
  RLam ps e      ->
    Set.toList (freeVarsExpr e `Set.difference` Set.fromList (map binderUnique ps))
  ROp _ _ _ as   -> atomUs as
  RForeignCall _ _ _ _ as -> atomUs as
  where
    atomUs atoms = [ nameUniq n | AVar n <- atoms ]

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
      -- A captured BORROWED value --- a 'LetRec' member (in 'ctxBorrow', captured as
      -- an inline @RVRecMember@) or an uncounted-region sibling (in 'ctxExempt') ---
      -- is owned by its group's shared env / its region, NOT by this closure. The
      -- runtime application binds it from the closure env WITHOUT an incref
      -- ('closureOwnedBoxed' enumerates only boxed @RVBox@ captures, so a captured
      -- @RVRecMember@ is neither increfed on entry nor consumed by the body), and the
      -- closure's own drop cascades into its counted child (the shared env) exactly
      -- once via 'valueChildren'. So a borrowed capture must NOT be seeded at +1 in
      -- the body and must NOT be dropped there: the body BORROWS it. A read / a
      -- recursive call-head emits nothing; a CONSUMING use dup-on-consumes (the env
      -- incref), the same dup-on-consume rule the LetRec member-body scope uses
      -- ('onDef'). Without this the body's last-use machinery would drop the borrowed
      -- member (an extra unbalanced @__rc_drop@ of the shared env), and the closure's
      -- cascade-drop would then double-free it --- the M2a-2 escape-then-call bug.
      borrowed  = ctxBorrow ctx `Set.union` ctxExempt ctx
      capsBoxed = Set.fromList
                    [ u | u <- Set.toList (freeVarsExpr e `Set.difference` params)
                        , u `Set.member` delta, u `Set.notMember` borrowed
                        , Just b <- [Map.lookup u (ctxEnv ctx)], boxedBinder b ]
      -- The borrowed values still free in the lambda body: kept borrowed in the body
      -- scope so a consuming use dup-on-consumes and a read/call emits nothing.
      capsBorrow = (freeVarsExpr e `Set.difference` params) `Set.intersection` borrowed
      psBoxed   = Set.fromList [ binderUnique p | p <- ps, boxedBinder p ]
      dDelta    = psBoxed `Set.union` capsBoxed
      dEnv      = foldr (\p -> Map.insert (binderUnique p) p) (ctxEnv ctx) ps
      dCtx      = Ctx dEnv Map.empty (ctxExempt ctx `Set.intersection` capsBorrow)
                      (ctxBorrow ctx `Set.intersection` capsBorrow)
                      Set.empty Map.empty Set.empty
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
mutExpr mut False (Handle e h) =
  -- M2b-1 (Task 2): the handler arms hold inserted RC calls now, so the
  -- fault-injection walk descends into the handled expr first, then the return
  -- arm, then each op arm (pre-order, left-to-right), threading @done@.
  let (d0, e') = mutExpr mut False e
      (rb, rbody) = hReturn h
      (d1, rbody') = mutExpr mut d0 rbody
      (d2, ops')   = mapAccumLOpsM (mutOp mut) d1 (hOps h)
  in (d2, Handle e' (h { hReturn = (rb, rbody'), hOps = ops' }))

mutOp :: Mutation -> Bool -> OpArm -> (Bool, OpArm)
mutOp mut done (OpArm lbl op args resume body) =
  let (d, body') = mutExpr mut done body in (d, OpArm lbl op args resume body')

mapAccumLOpsM :: (Bool -> OpArm -> (Bool, OpArm)) -> Bool -> [OpArm] -> (Bool, [OpArm])
mapAccumLOpsM f = go
  where
    go d []       = (d, [])
    go d (x : xs) = let (d', x')   = f d x
                        (d'', xs') = go d' xs
                    in (d'', x' : xs')

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
  | not (coveredExpr body) = []          -- not instrumented; nothing to audit
  | otherwise =
      let cnt0 = Map.fromList [ (binderUnique b, 1) | b <- ps, boxedBinder b ]
      in lintScope n Set.empty ps body cnt0

-- | Audit ONE ownership scope (a top-level bind body or a 'LetRec' closure body):
-- build the tracked + exempt sets from the scope's parameters and body, then walk
-- it forward. @exempt0@ carries the enclosing uncounted-region siblings.
lintScope :: Name -> Set Unique -> [Binder] -> Expr -> Counts -> [Text]
lintScope fn exempt0 = lintScope' fn Set.empty exempt0 exempt0

-- | As 'lintScope', but with an EXTRA tracked set @owned0@ for owned vars that are
-- live on entry but are not introduced by a binder in @body@ --- namely a closure's
-- CAPTURES, which 'enterRC' increfs into the lambda body scope and which the body
-- consumes (drops) inside itself. They must be tracked so those consumes count.
-- @borrow0@ carries the borrowed values in scope ('LetRec' members / borrowed
-- captures) so a closure body audited from here does not seed a captured borrow.
lintScope' :: Name -> Set Unique -> Set Unique -> Set Unique -> [Binder] -> Expr -> Counts -> [Text]
lintScope' fn owned0 exempt0 borrow0 ps body cnt0 =
  let tracked = Set.fromList [ binderUnique b | b <- ps, boxedBinder b ]
                  `Set.union` trackedBinders body
                  `Set.union` owned0
      env     = LintEnv fn tracked exempt0 (collectJoins body) borrow0 Map.empty Set.empty
  in checkExpr env cnt0 body

-- | The shared-env owning unit (member 0) for each member of @defs@: every member's
-- 'Unique' maps to member 0's, so the audit counts all members' env operations
-- against the single 'NEnv' cell. A singleton group maps member 0 to itself.
groupEnvAlias :: [(Binder, [Binder], Expr)] -> Map Unique Unique
groupEnvAlias defs = case defs of
  ((b0, _, _) : _) -> Map.fromList [ (binderUnique b, binderUnique b0) | (b, _, _) <- defs ]
  []               -> Map.empty

-- | The lint environment threaded through 'checkExpr'.
--
--   * 'leTracked' --- the boxed locals this scope reference-counts.
--   * 'leExempt'  --- uncounted-region siblings (never moved, dropped by the
--     group drop): a relinquish of one is ignored, and it must not leak.
--   * 'leJoins'   --- each join's @(params, body)@, so a 'Jump' can audit the join
--     body INLINE at the jump site (modelling the runtime tail transfer; the join
--     runs in its definition scope, so this is the faithful per-site check).
--   * 'leBorrow'  --- M2a-2 (Task 4) BORROWED values in scope ('LetRec' members
--     and borrowed captures). A borrowed value captured by a standalone closure is
--     borrowed INSIDE the lambda body too (a call-head read), so it must NOT be
--     seeded as an owned capture there (it would never be consumed -> false leak).
--   * 'leEnvAlias' --- M2a-2 (Task 4) maps each group member's 'Unique' to its
--     group's shared-env owning unit (member 0). Every member's @__rc_dup@/
--     @__rc_drop@ and every member move operates on the SAME 'NEnv' cell at
--     runtime, so the audit CANONICALISES a member's 'Unique' to its env's before
--     counting --- the env's single owned unit then balances across all members.
--   * 'leResume'  --- M2b-1 (Task 2) the op-arm RESUME binders in scope (mirror of
--     the pass's 'ctxResume'). Applying a resume binder as a call head is a MOVE (the
--     move-out), so the lint relinquishes it there ('moveAtoms'); an arm that never
--     applies it drops it (the abort cascade). One-shot guarantees at most one apply.
data LintEnv = LintEnv
  { leFn       :: Name
  , leTracked  :: Set Unique
  , leExempt   :: Set Unique
  , leJoins    :: Map JoinId ([Binder], Expr)
  , leBorrow   :: Set Unique
  , leEnvAlias :: Map Unique Unique
  , leResume   :: Set Unique
  }

-- | Canonicalise a 'Unique' to its group's shared-env owning unit (member 0) when
-- it is a 'LetRec' member; identity otherwise. The audit counts every member
-- @__rc_dup@/@__rc_drop@/move against this single env unit.
canonU :: LintEnv -> Unique -> Unique
canonU env u = Map.findWithDefault u u (leEnvAlias env)

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
-- M2b-1 (Task 2): the handled expr runs in THIS scope, so its joins are collected
-- here; each handler ARM is its own ownership scope (see 'checkExpr'), so its joins
-- are collected when that arm is audited, not here.
collectJoins (Handle e _)         = collectJoins e

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
-- M2b-1 (Task 2): the handled expr's binders are tracked in THIS scope; the
-- handler-arm binders + arm-body binders belong to the arm scopes (audited
-- separately by 'checkExpr'), like 'LetRec' def-body binders, so not here.
trackedBinders (Handle e _)   = trackedBinders e

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
relAny env what v0 cnt
  | not (v `Set.member` leTracked env) = ([], cnt)
  | Map.findWithDefault 0 v cnt > 0    = ([], Map.adjust (subtract 1) v cnt)
  | otherwise =
      ( [ nameHint (leFn env) <> Tx.pack ": over-consume of u"
            <> Tx.pack (show (uInt v))
            <> Tx.pack " via " <> what <> Tx.pack " (value not owned here)" ]
      , cnt )
  where v = canonU env v0   -- a member's env op counts against its env unit

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
      | h == dupHint  -> checkExpr env (bumpC (canonU env v) cnt) body
      | h == dropHint -> let (vs, cnt') = relDrop env v cnt
                         in vs ++ checkExpr env cnt' body
    _ ->
      let -- ALIAS-OF-BORROW (M2a-2): @let b = AVar s@ where @s@ is a borrowed
          -- 'LetRec' member (in 'leBorrow'). Mirror the pass ('aliasesBorrowIn'):
          -- 'b' is a pure RENAME of a borrow, owns nothing, and the alias site is
          -- NOT a consuming move (so do not relinquish 's' here), 'b' does NOT
          -- enter the owned set, and 'b' stays BORROWED in 'body' (a consuming use
          -- dup-on-consumes at THAT use; a read/call-head emits nothing). The pass
          -- emits no '__rc_dup'/'__rc_drop' at the alias site, so the lint must not
          -- relinquish, seed, or expect a drop here.
          aliasesBorrow  = aliasesBorrowIn (leBorrow env) rhs
          -- The alias-of-borrow site moves nothing (a borrow rename); every other
          -- form relinquishes its moved operands as usual.
          moves          = if aliasesBorrow then []
                             else [ nameUniq m | AVar m <- moveAtoms (leResume env) rhs ]
          (vs, cntMoved) = relAtoms env (Tx.pack "operand move") moves cnt
          -- ALIAS-OF-EXEMPT (M2a-1 hardening): @let b = AVar s@ where @s@ is an
          -- uncounted-region sibling (in 'leExempt'). Mirror the pass: 'b' is a
          -- BORROW of the same member, so it does NOT enter the owned set and stays
          -- EXEMPT inside 'body' (a use is not a move; the group drop releases the
          -- member once). The pass emits no '__rc_dup'/'__rc_drop' for it, so the
          -- lint must not seed 'b' at +1 (that would be a false leak) and must not
          -- treat a later move/drop of 'b' as a counted relinquish.
          aliasesExempt  = aliasesExemptIn (leExempt env) rhs
          -- A boxed let result enters the owned set with one unit --- UNLESS it is
          -- an 'RProj', which BORROWS the parent (the projected binder owns nothing
          -- on its own and is instead given ownership by the @__rc_dup@ the pass
          -- inserts right after it), or an ALIAS-OF-EXEMPT / ALIAS-OF-BORROW (a
          -- borrow of a region sibling / a 'LetRec' member; see above).
          enters         = boxedBinder b && not (isProj rhs)
                             && not aliasesExempt && not aliasesBorrow
          cnt'           = if enters then bumpC (binderUnique b) cntMoved else cntMoved
          envBody
            | aliasesExempt = env { leExempt = Set.insert (binderUnique b) (leExempt env) }
            | aliasesBorrow =
                -- Mirror the pass (M2a-2 Stage B): an alias of a borrow that maps to
                -- a shared-env owning unit inherits that env unit, so an escaping
                -- ALIAS-of-a-member return relinquishes the SAME env unit ('relRets'
                -- canonicalises via 'leEnvAlias'), matching the pass's 'retEnvs'
                -- protection (the env-alive handle is not also dropped).
                let inheritedEnv =
                      case rhs of
                        RAtom (AVar n) ->
                          maybe Map.empty
                                (Map.singleton (binderUnique b))
                                (Map.lookup (nameUniq n) (leEnvAlias env))
                        _ -> Map.empty
                in env { leBorrow   = Set.insert (binderUnique b) (leBorrow env)
                       , leEnvAlias = inheritedEnv `Map.union` leEnvAlias env }
            -- M3 (Task 3): @let k2 = __cont_take cell@ binds a CONTINUATION, OR
            -- @let k2 = t@ aliases an existing resume binder @t@ (the elaborator
            -- splits @let k2 = __cont_take c@ into @let t = __cont_take c ; let k2 =
            -- t@). Mirror the pass's 'aliasesResume': track @k2@ in 'leResume' so
            -- applying it (@k2 v@) is a MOVE-OUT ('moveAtoms's 'resumeHead'
            -- relinquishes the head, no extra drop on the resume path). @k2@ is boxed
            -- so it STILL enters the owned set at +1 ('enters'); the move-out at the
            -- application brings it back to 0. Without this the application would not
            -- relinquish @k2@ (borrow-on-call) -> a false leak at the leaf.
            | aliasesResume (leResume env) rhs =
                env { leResume = Set.insert (binderUnique b) (leResume env) }
            | otherwise     = env
          -- A closure build also audits its lambda body as its OWN ownership
          -- scope: the boxed params and the boxed OWNED captures are owned on entry
          -- (the runtime's 'enterRC' increfs the OWNED captures --- see Task 2's
          -- incref-only-owned behaviour --- and binds them with the params), so seed
          -- each at +1 and re-walk via 'lintScope'.
          --
          -- M2a-1 Task 4 (owned/borrowed split). A BORROWED capture --- a 'LetRec'
          -- region sibling (in 'leExempt') or a static cell --- is NOT increfed by
          -- 'enterRC' and NOT cascaded on the closure drop; the owning region / static
          -- lifetime releases it. So a borrowed capture must NOT be seeded at +1 here
          -- (seeding it would leave an unconsumed unit at the body leaf => a false
          -- leak), and it stays EXEMPT inside the body scope (a use is not a move).
          -- This matches the runtime: case #4's @h = \\m -> f (m+1)@ borrows the
          -- sibling @f@, so @f@ is neither seeded nor counted in @h@'s body.
          lamViols       = case rhs of
            RLam ps e ->
              let caps  = freeVarsExpr e `Set.difference` Set.fromList (map binderUnique ps)
                  -- BORROWED captures stay exempt inside the body scope: a 'LetRec'
                  -- region sibling / static cell (in 'leExempt') OR a borrowed value
                  -- (a 'LetRec' member / borrowed capture, in 'leBorrow'). The pass's
                  -- 'enterRC' does not incref them and the closure drop does not
                  -- cascade them, so seeding them would leave an unconsumed unit at
                  -- the body leaf => a false leak. A captured MEMBER is borrowed (a
                  -- call-head read) inside the lambda --- case #4's @\\m -> f (m+1)@.
                  borrowed     = leExempt env `Set.union` leBorrow env
                  -- OWNED boxed captures: tracked AND not borrowed. Agrees with
                  -- 'ownRhs's 'capsBoxed' and the runtime's owned-capture set.
                  capsOwned = Set.filter (`Set.member` leTracked env)
                                (caps `Set.difference` borrowed)
                  capsBorrowed = caps `Set.intersection` borrowed
                  cnt0  = Map.fromList $
                            [ (binderUnique p, 1) | p <- ps, boxedBinder p ] ++
                            [ (u, 1) | u <- Set.toList capsOwned ]
              in lintScope' (leFn env) capsOwned capsBorrowed capsBorrowed ps e cnt0
            _ -> []
      in vs ++ lamViols ++ checkExpr envBody cnt' body
checkExpr env cnt (Case _ alts) = concatMap (checkAlt env cnt) alts
checkExpr env cnt (LetRec defs body) =
  -- M2a-2 (Task 4) SHARED-ENV model. A group is ONE shared 'NEnv' cell plus
  -- per-member inline @RVRecMember@ handles --- ordinary acyclic RC. The audit:
  --
  --   * The shared env is represented by member 0: it ENTERS the owned set (+1, the
  --     scope's handle) and is relinquished by the single @__rc_drop member0@ the
  --     pass emits at each path leaf.
  --   * Members 1..n are BORROWED, NOT owned: they do not enter the owned set. A
  --     recursive call-head is not a move ('moveAtoms' excludes the head, so no
  --     relinquish). A CONSUMING occurrence (a member moved into a con/record/arg/
  --     result) is preceded by a @__rc_dup@ the pass inserts (DUP-ON-CONSUME): the
  --     dup bumps the member's count by +1 and the move relinquishes it back to 0,
  --     so the dup/move pair balances and never over-consumes. Members are therefore
  --     TRACKED (so the pair is checked) but NOT exempt and NOT seeded at +1.
  --   * Each DISTINCT enclosing capture is MOVED into the env ONCE (relinquished once
  --     here); the build-site @__rc_dup@ (walked just before this node) supplies the
  --     extra unit for a capture that also survives into the body.
  --
  -- Each member body is a separate ownership scope (its params owned, siblings AND
  -- its captures borrowed), audited independently by 'lintDef'.
  let groupU      = Set.fromList [ binderUnique b | (b, _, _) <- defs ]
      env0        = case defs of
        ((b, _, _) : _) -> binderUnique b
        []              -> error "checkExpr: empty LetRec group"
      defViols    = concatMap (lintDef env groupU defs) defs
      -- The DISTINCT enclosing captures of the whole group (tracked boxed locals free
      -- in some member body, minus params and group binders, non-borrowed). One move
      -- into the single shared env each. Agrees with the pass's 'memberCaps' union.
      memberCaps (_, ps, dbody) =
        Set.fromList
          [ u
          | u <- Set.toList (freeVarsExpr dbody
                               `Set.difference` Set.fromList (map binderUnique ps)
                               `Set.difference` groupU)
          , u `Set.member` leTracked env
          , u `Set.notMember` leExempt env, u `Set.notMember` leBorrow env ]
      capMoves    = Set.toList (Set.unions [ memberCaps d | d <- defs ])
      (capVs, cnt1) = relAtoms env (Tx.pack "letrec capture move") capMoves cnt
      -- Only member 0 (the shared-env handle) enters the owned set.
      cntGroup    = bumpC env0 cnt1
      -- In the body: members are BORROWED (a call-head is not a move) and every
      -- member's env op counts against member 0 (the alias); they are NOT exempt
      -- (a consuming move IS counted, against the env unit, balanced by its dup).
      envBody     = env { leBorrow   = leBorrow env `Set.union` groupU
                        , leEnvAlias = leEnvAlias env `Map.union` groupEnvAlias defs }
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
checkExpr env cnt (Handle e h) =
  -- M2b Task 2. Four regions, mirroring the pass ('ownExpr (Handle ...)'):
  --
  --   * THE HANDLED EXPR @e@ runs in THIS scope under incoming counts minus the
  --     param's boxed unique (the Handle consumes the param, so @e@ must not also
  --     see it as owned). Its trailing counts are discarded: an arm starts a FRESH
  --     scope (control does not flow from @e@'s leaf into an arm).
  --   * THE RETURN ARM is a fresh scope owning its (boxed) binder AND the param.
  --   * EACH OP ARM is a fresh scope owning its boxed @oaArgs ++ [oaResume] ++
  --     [param]@; the resume binder is in 'leResume'.
  let (rb, rbody) = hReturn h
      paramBoxedU = Set.fromList [ binderUnique pb | pb <- paramBs, boxedBinder pb ]
      -- Mirror deltaE: subtract param from cnt before auditing e.
      cntE        = Map.filterWithKey (\u _ -> u `Set.notMember` paramBoxedU) cnt
      eViols      = checkExpr env cntE e
      retViols    = lintArmScope env Set.empty (rb : paramBs) rbody
      opViols     = concatMap (lintOpArm env) (hOps h)
  in eViols ++ retViols ++ opViols
  where
    paramBs = hParamBinders h
    -- A handler arm body as its own ownership scope: its boxed binders @bs@ owned on
    -- entry (+1 each), @resume0@ the arm's resume binders (move-on-apply). The
    -- enclosing 'leBorrow'/'leExempt' are kept (borrow accounting); 'leJoins' and
    -- 'leEnvAlias' do NOT cross the handler boundary (mirror the pass's 'armCtxReset')
    -- so they reset to this arm's own joins / empty. Tracking is reset to the arm's
    -- own binders + body binders --- an outer var referenced in an arm is NOT owned
    -- here (the handled expr consumed it), so it is borrowed (a read emits nothing); a
    -- MOVE/DROP of such an outer var would be an over-consume, the correct conservative
    -- report for an unsupported arm-capture shape.
    lintArmScope :: LintEnv -> Set Unique -> [Binder] -> Expr -> [Text]
    lintArmScope outer resume0 bs body =
      let tracked = Set.fromList [ binderUnique b | b <- bs, boxedBinder b ]
                      `Set.union` trackedBinders body
          armEnv  = LintEnv (leFn outer) tracked (leExempt outer) (collectJoins body)
                            (leBorrow outer) Map.empty resume0
          cnt0    = Map.fromList [ (binderUnique b, 1) | b <- bs, boxedBinder b ]
      in checkExpr armEnv cnt0 body
    lintOpArm :: LintEnv -> OpArm -> [Text]
    lintOpArm outer (OpArm _ _ args resume body) =
      lintArmScope outer (Set.singleton (binderUnique resume))
                   (args ++ [resume] ++ paramBs) body

-- | Audit one 'LetRec' closure body as a fresh scope. Its params are owned; its
-- enclosing siblings carried in @env@ AND this member's enclosing captures
-- (M1.5 Phase 2: BORROWED inside the body, owned by the region) are exempt ---
-- never moved or dropped inside the body, matching the pass.
--
-- M2a-2 BLOCKER 1: the group's OWN siblings (@groupU@) are BORROWED (not exempt)
-- and env-aliased to member 0 ('groupEnvAlias'), mirroring the pass's 'onDef'. A
-- member body that RETURNS / JUMPS / moves a sibling carries the shared env out
-- and the pass emits a dup-on-consume (@__rc_dup sibling@ = env incref) at that
-- use; that dup bumps the env unit (member 0, via 'canonU') and the escape
-- relinquishes it back, so the pair balances. The env unit is therefore TRACKED
-- in this scope (so the dup/escape pair is audited) but NOT seeded at +1 (the
-- member body does not own the scope's env handle --- 'ctxEnvAlive' is empty in
-- 'onDef' too). Without this the dup-on-escape was an unbalanced +1 => false leak.
lintDef :: LintEnv -> Set Unique -> [(Binder, [Binder], Expr)]
        -> (Binder, [Binder], Expr) -> [Text]
lintDef env groupU defs (_, ps, dbody) =
  let caps   = Set.fromList
                 [ u
                 | u <- Set.toList (freeVarsExpr dbody
                                      `Set.difference` Set.fromList (map binderUnique ps)
                                      `Set.difference` groupU)
                 , u `Set.member` leTracked env, u `Set.notMember` leExempt env ]
      -- Member 0 is the shared-env owning unit; every sibling env op counts against
      -- it via 'canonU'. Tracked here (so the dup/escape pair balances) but not
      -- seeded (the body borrows the env, it does not own a scope handle).
      env0   = case defs of
        ((b0, _, _) : _) -> binderUnique b0
        []               -> error "lintDef: empty LetRec group"
      -- A member-body enclosing CAPTURE is BORROWED (mirroring the pass's 'onDef',
      -- whose 'dCtx' puts 'caps' in 'ctxBorrow', NOT 'ctxExempt'). Borrowed --- not
      -- exempt --- so an ESCAPING capture (returned, sealed into a con/record/list,
      -- or passed as a non-head arg) is dup-on-consumed by the pass and that dup/move
      -- pair is AUDITED (both count against the capture's own 'Unique', which has no
      -- env-alias, so 'canonU' is identity). A capture used only as a borrowed READ
      -- (a 'Case' scrutinee keeping no boxed child) is never bumped or relinquished,
      -- so it stays at 0 and never leaks. Captures are therefore TRACKED + BORROWED
      -- but NOT seeded (the body borrows the captured cell; the shared env owns it).
      exempt = leExempt env
      borrow = groupU `Set.union` caps
      tracked = Set.fromList [ binderUnique b | b <- ps, boxedBinder b ]
                  `Set.union` trackedBinders dbody
                  `Set.union` Set.singleton env0
                  `Set.union` caps
      leEnv  = LintEnv (leFn env) tracked exempt (collectJoins dbody)
                       borrow (groupEnvAlias defs) Set.empty
      cnt0   = Map.fromList [ (binderUnique b, 1) | b <- ps, boxedBinder b ]
  in checkExpr leEnv cnt0 dbody

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
moveAtoms :: Set Unique -> Rhs -> [Atom]
moveAtoms resume rhs = case rhs of
  RAtom a        -> [a]
  -- BORROW-ON-CALL (M2a-2 Task 1): the call head @f@ is READ, not moved (see
  -- 'ownedOccs'); only the arguments are moves. Keeping it consistent here is what
  -- lets 'balanceLint' certify a function value dropped at its last use rather
  -- than flag an over-consume on the (now-borrowed) head.
  --
  -- M2b-1 EXCEPTION (Task 2): a RESUME head (in @resume@) IS a move (the move-out),
  -- so include it; mirror of 'ownedOccs's 'resumeHead'.
  --
  -- M3 (Task 3): @__cont_take cell@ BORROWS its cell argument (the prim reads and
  -- empties the cell in place; the cell stays owned and is dropped at its last use).
  -- 'ownedOccs' / 'moveOperandUniques' both exempt it, so the lint mirror MUST too,
  -- or it counts the cell as moved AT the take and then over-consumes on the pass's
  -- last-use @__rc_drop(cell)@.
  RApp (APrim k) _
    | k == PN.contTakeKey -> []
  RApp f as      -> resumeHead f ++ as
  RCon _ as      -> as
  RRecord _ flds -> map snd flds
  RProj _ _      -> []   -- borrow
  RReuseCon{}              -> error "RReuseCon: produced only by reusePairing post-pass (after insertRC/balanceLint)"
  RLam ps e ->
    [ AVar (Name (Tx.pack "") u)
    | u <- Set.toList (freeVarsExpr e `Set.difference` Set.fromList (map binderUnique ps)) ]
  ROp _ _ _ as             -> as
  -- All args are consuming moves (no call-head exemption; callee is (lib,sym) text).
  RForeignCall _ _ _ _ as  -> as
  where
    resumeHead (AVar n) | nameUniq n `Set.member` resume = [AVar n]
    resumeHead _ = []

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
