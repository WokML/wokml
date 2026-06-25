-- | FBIP reuse-pairing post-pass (spec 2026-06-23-fbip-reuse-design §6).
--
-- This pass runs IMMEDIATELY AFTER 'Wok.IR.Perceus.insertRC' (and after
-- 'balanceLint') on the RC-instrumented module, in the run/oracle/stats pipeline
-- everywhere @insertRC@ output is EXECUTED. It recognizes the single-path FBIP
-- shape the Perceus 'Case' rule already emits --- a unique boxed scrutinee dropped
-- at the match (@let _ = __rc_drop p@) paired with a downstream constructor
-- allocation of matching slot-kind signature on the alt's straight-line tail ---
-- and rewrites it into the runtime-conditional in-place reuse pair:
--
--   * @let _   = __rc_drop p@        -> @let tok = __rc_drop_reuse p@  (fresh @tok@)
--   * @let r   = RCon c' fields@     -> @let r   = RReuseCon tok c' fields@
--
-- The token is structurally affine (§6.4): the pass introduces exactly one
-- producer (@__rc_drop_reuse@) and one consumer ('RReuseCon') on the single
-- straight-line path, and no earlier pass (Perceus / multiplicity / escape /
-- balanceLint, all of which run BEFORE this one) ever observes the token. So
-- 'balanceLint' validates the pre-FBIP IR unchanged and this rewrite cannot
-- unbalance it.
--
-- SOUNDNESS (§6.5). The pass fires only where @insertRC@ proved @p@ dead at the
-- match (the parent drop is present), and the runtime @rc == 1@ gate re-checks
-- uniqueness dynamically: a shared sublist yields a NULL token and @alloc_at@
-- falls back to a fresh allocation. Correctness never depends on the pairing being
-- right about uniqueness --- a wrong guess costs an allocation, never a wrong
-- answer. The static slot-kind signature guard (§6.3) additionally guarantees the
-- matched and target constructors decode through the SAME tag-keyed C descriptor
-- (so a C re-stamp cannot mis-decode a payload) AND both backends place old/new on
-- the same heap.
--
-- SCOPE (S2). The target rule is deliberately the FIRST slot-kind-compatible
-- 'RCon' on the straight-line tail; a branchy @filter@ alt (a 'Case' / 'LetJoin'
-- between the drop and the RCon) is simply not matched, deferred to S3 with no
-- special-casing.
module Wok.IR.ReusePairing
  ( reusePairing
    -- * Slot-kind compatibility (exported for tests)
  , SlotClass (..)
  , slotClassOf
  , conSlotSig
    -- * Fresh-Unique supply seeding (exported for tests, review finding F2)
  , exprMaxU
  ) where

import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as Tx
import Wok.IR.Anf
  ( Alt (..), Atom (..), Binder (..), CoreModule (..), Expr (..), Handler (..)
  , Lit (..), Mult (..), OpArm (..), Rhs (..), TopBind (..), binderUnique
  , hParamBinders )
import Wok.IR.Name (Name (..), Unique (..), nameHint, nameUniq)
import qualified Wok.IR.PrimNames as PN
import Wok.TypeChecking.Types (CType (..), TyCon (..))

-- ---------------------------------------------------------------------------
-- Slot-kind signature (§6.3) --- the correctness guard.

-- | The storage class of a single constructor field, derived statically from its
-- 'CType'. Two constructors are reuse-compatible iff they have the SAME arity AND
-- an equal class at every position (see 'conSlotSig').
--
-- The C runtime decodes a cell's slots through a descriptor keyed by constructor
-- tag (recorded first-write-wins). Re-stamping a @Cons@-of-@Int@ cell (descriptor
-- @[KLitInt, KPointer]@) with a @Char@ payload would decode the codepoint as an
-- @Int@ on readback --- silent wrong output under the C backend. So reuse is
-- admitted only across identical signatures.
--
-- 'NonEncodable' covers the statically non-encodable field types (a @String@
-- field forces the whole cell onto the abstract heap). A high-bit @U64@ (>= 2^63)
-- is NOT a static distinction --- its type is still @U64@ (=> 'KLitInt'); that
-- integer-width flip is a RUNTIME eligibility concern handled by the
-- 'Wok.Interp.RC.Value.ReuseSlot' eligibility bit and the free-fallback, not by
-- this static guard (§4.3).
data SlotClass = KLitInt | KLitChar | KLitUnit | KPointer | NonEncodable
  deriving (Eq, Show)

-- | The storage class of a field of the given type.
--
--   * @Int@ / @U64@ / @U32@        -> 'KLitInt'
--   * @Char@                       -> 'KLitChar'
--   * @()@                         -> 'KLitUnit'
--   * @String@                     -> 'KPointer' (Slice E1, Task 3: a String value
--                                      is now a counted 'NString' cell stored as a
--                                      pointer word, exactly like any other boxed
--                                      field; it is no longer an inline literal)
--   * any boxed / encodable-pointer -> 'KPointer' (Bool, lists, tuples, ADTs,
--                                      records, functions, type variables)
slotClassOf :: CType -> SlotClass
slotClassOf (CTCon TcU64    []) = KLitInt
slotClassOf (CTCon TcU32    []) = KLitInt
slotClassOf (CTCon TcChar   []) = KLitChar
slotClassOf (CTCon TcUnit   []) = KLitUnit
slotClassOf (CTCon TcString []) = KPointer
slotClassOf _                   = KPointer

-- | The per-field slot-kind signature of a constructor, given the 'CType' of each
-- field in order. Two signatures are reuse-compatible iff they are EQUAL (same
-- length, equal class at every position).
conSlotSig :: [CType] -> [SlotClass]
conSlotSig = map slotClassOf

-- | The slot class of a literal atom (its obvious type). A string literal now
-- allocates a counted 'NString' cell stored as a pointer ('KPointer'), so its
-- slot class agrees with @slotClassOf String@ (Slice E1, Task 3) and a
-- constructor with a String field stays reuse-compatible with itself.
litSlotClass :: Lit -> SlotClass
litSlotClass (LInt _)  = KLitInt
litSlotClass (LStr _)  = KPointer
litSlotClass (LChar _) = KLitChar
litSlotClass LUnit     = KLitUnit

-- ---------------------------------------------------------------------------
-- The type environment.
--
-- Maps each in-scope binder's 'Unique' to its declared 'CType'. Seeded from the
-- matched 'AltCon' binders (the matched cell's field types) and extended at each
-- enclosing 'Let'. A target 'RCon''s field types are read from its field atoms by
-- looking up an 'AVar' in this env; a literal atom gets its obvious type.

type TyEnv = Map Unique CType

-- | The slot class of a field atom, or 'Nothing' when its type cannot be
-- determined (an out-of-env variable or a prim head). An undetermined field is
-- CONSERVATIVE: it makes the signature non-matchable, so the pair is refused.
atomSlotClass :: TyEnv -> Atom -> Maybe SlotClass
atomSlotClass _   (ALit l) = Just (litSlotClass l)
atomSlotClass env (AVar n) = slotClassOf <$> Map.lookup (nameUniq n) env
atomSlotClass _   (APrim _) = Nothing

-- | The slot-kind signature of a target 'RCon''s field atoms, or 'Nothing' if any
-- field's type is undetermined (refuse the pair rather than guess).
targetSlotSig :: TyEnv -> [Atom] -> Maybe [SlotClass]
targetSlotSig env = traverse (atomSlotClass env)

-- ---------------------------------------------------------------------------
-- Fresh-Unique supply (mirrors 'Wok.IR.Perceus.Supply'/'seedSupply').
--
-- 'reusePairing' mints a fresh token binder for each rewritten pair. To stay a
-- pure 'CoreModule -> CoreModule' function we thread a monotonic counter seeded
-- strictly ABOVE the largest 'Unique' anywhere in the module, so a minted token
-- can never collide with an existing binder.

newtype Supply = Supply Int

freshU :: Supply -> (Unique, Supply)
freshU (Supply n) = (Unique n, Supply (n + 1))

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

-- | The largest 'Unique' anywhere in a handler --- mirrors
-- 'Wok.IR.Perceus.handlerMaxU'. A handler arm body can bind a 'Unique' larger
-- than anything outside the 'Handle', and 'seedSupply' must account for it so a
-- minted @_tok@ binder cannot collide with an arm binder (review finding F2).
handlerMaxU :: Handler -> Int
handlerMaxU h =
  let (rb, rbody) = hReturn h
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
rhsMaxU (RAtom a)            = atomMaxU a
rhsMaxU (RApp f as)          = foldr (max . atomMaxU) (atomMaxU f) as
rhsMaxU (RCon _ as)          = foldr (max . atomMaxU) (-1) as
rhsMaxU (RLam ps e)          = maximum (exprMaxU e : map (uOf . bndName) ps)
rhsMaxU (ROp m _ _ as)       = foldr (max . atomMaxU) (maybe (-1) atomMaxU m) as
rhsMaxU (RRecord _ flds)     = foldr (max . atomMaxU . snd) (-1) flds
rhsMaxU (RProj _ a)          = atomMaxU a
rhsMaxU (RReuseCon tok _ as) = foldr (max . atomMaxU) (atomMaxU tok) as

atomMaxU :: Atom -> Int
atomMaxU (AVar n)  = uOf n
atomMaxU (ALit _)  = -1
atomMaxU (APrim _) = -1

-- ---------------------------------------------------------------------------
-- The pass.

-- | Rewrite every FBIP-reusable @Case@ alt in the module's top binds. Threads a
-- single fresh-'Unique' supply seeded above the whole module across all binds.
reusePairing :: CoreModule -> CoreModule
reusePairing cm@(CoreModule bs) =
  CoreModule (snd (foldr step (seedSupply cm, []) bs))
  where
    -- foldr threads the supply right-to-left; bind order is preserved by
    -- prepending in the accumulator. The type env is seeded with the bind's
    -- PARAMETERS so a target 'RCon' field that names a parameter (e.g. the
    -- @acc@umulator in @reverse@) resolves to a slot class.
    step (TopBind n ps body) (sup, acc) =
      let env0          = foldr (\p m -> Map.insert (binderUnique p) (bndType p) m) Map.empty ps
          (sup', body') = goExpr env0 sup body
      in (sup', TopBind n ps body' : acc)

-- | Walk an expression, recording binder types in 'TyEnv' as 'Let's are
-- traversed, and rewriting any FBIP-reusable 'Case' alt encountered. The traversal
-- is structural: it descends into the nested forms it supports (the one S2 gap is
-- the 'Handle' handler arms, see its arm below). The LOCAL straight-line target
-- search inside an alt is the part that REFUSES to cross a nested
-- 'Case'/'LetJoin'/'RLam'/'Handle'.
goExpr :: TyEnv -> Supply -> Expr -> (Supply, Expr)
goExpr _   sup e@(Ret _)  = (sup, e)
goExpr _   sup e@Jump{}   = (sup, e)
goExpr env sup (Let b rhs body) =
  let (sup1, rhs')  = goRhs env sup rhs
      env'          = Map.insert (binderUnique b) (bndType b) env
      (sup2, body') = goExpr env' sup1 body
  in (sup2, Let b rhs' body')
goExpr env sup (LetRec defs body) =
  let env'           = foldr (\(b, _, _) m -> Map.insert (binderUnique b) (bndType b) m) env defs
      (sup1, defs')  = mapAccumDefs env' sup defs
      (sup2, body')  = goExpr env' sup1 body
  in (sup2, LetRec defs' body')
goExpr env sup (LetJoin j ps jbody body) =
  let envJ           = foldr (\p m -> Map.insert (binderUnique p) (bndType p) m) env ps
      (sup1, jbody') = goExpr envJ sup jbody
      (sup2, body')  = goExpr env sup1 body
  in (sup2, LetJoin j ps jbody' body')
goExpr env sup (Handle e h) =
  -- Descend only into the handled expr @e@; the handler arm bodies (hReturn/hOps)
  -- are deliberately NOT traversed in S2 (handler arms are M2-effect territory,
  -- out of S2's map/reverse scope). A reusable pair missed there is a forgone
  -- optimization, never wrong behavior.
  let (sup1, e') = goExpr env sup e
  in (sup1, Handle e' h)
goExpr env sup (Case scrut alts) =
  let scrUniq = case scrut of
                  AVar n -> Just (nameUniq n)
                  _      -> Nothing
      (sup', alts') = mapAccumAlts (rewriteAlt env scrUniq) sup alts
  in (sup', Case scrut alts')

-- | Descend into an 'RLam' body (the only RHS that nests an instrumented
-- expression); every other RHS form is a leaf for this pass.
goRhs :: TyEnv -> Supply -> Rhs -> (Supply, Rhs)
goRhs env sup (RLam ps e) =
  let envL       = foldr (\p m -> Map.insert (binderUnique p) (bndType p) m) env ps
      (sup', e') = goExpr envL sup e
  in (sup', RLam ps e')
goRhs _ sup r = (sup, r)

mapAccumAlts :: (Supply -> Alt -> (Supply, Alt)) -> Supply -> [Alt] -> (Supply, [Alt])
mapAccumAlts f = go
  where
    go s []       = (s, [])
    go s (x : xs) = let (s', x')   = f s x
                        (s'', xs') = go s' xs
                    in (s'', x' : xs')

mapAccumDefs
  :: TyEnv -> Supply -> [(Binder, [Binder], Expr)] -> (Supply, [(Binder, [Binder], Expr)])
mapAccumDefs env = go
  where
    go s []                  = (s, [])
    go s ((b, ps, body) : ds) =
      let envP          = foldr (\p m -> Map.insert (binderUnique p) (bndType p) m) env ps
          (s1, body')   = goExpr envP s body
          (s2, ds')     = go s1 ds
      in (s2, (b, ps, body') : ds')

-- | Rewrite one alt if it is FBIP-reusable. First recurse into the body (so a
-- NESTED reusable alt deeper in the body is rewritten too), then attempt the
-- local straight-line rewrite on the (already-recursed) body.
rewriteAlt :: TyEnv -> Maybe Unique -> Supply -> Alt -> (Supply, Alt)
rewriteAlt env scrUniq sup (AltCon c bs body) =
  let envB          = foldr (\b m -> Map.insert (binderUnique b) (bndType b) m) env bs
      (sup1, body') = goExpr envB sup body
      matchedSig    = conSlotSig (map bndType bs)
  in case scrUniq of
       -- A NULLARY match (@bs == []@) binds a nullary constructor, which is an
       -- inline immediate (no heap cell) since the layout-compaction immediates
       -- slice. An immediate is NEVER a donor (@drop_reuse (Inline _) = RVReuse
       -- Nothing@, spec §7), so reuse can never fire there; refuse the pair so a
       -- no-op token round-trip is not emitted. Reuse only makes sense for a
       -- cell-bearing (arity >= 1) match.
       Just p | not (null bs) ->
         let (sup2, body'') = tryRewriteBody envB c p matchedSig sup1 body'
         in (sup2, AltCon c bs body'')
       _ -> (sup1, AltCon c bs body')
rewriteAlt env _ sup (AltLit l body) =
  let (sup', body') = goExpr env sup body
  in (sup', AltLit l body')
rewriteAlt env _ sup (AltDefault body) =
  let (sup', body') = goExpr env sup body
  in (sup', AltDefault body')

-- | The local straight-line rewrite (§6.2). Scan the alt body's straight-line tail
-- (a chain of 'Let's) for @let _ = __rc_drop p@ where @p@ is the scrutinee; once
-- found, scan ONWARD on the same chain for the FIRST @let r = RCon c' fields@ whose
-- slot-kind signature equals @matchedSig@. If both are found, rewrite the drop to
-- @let tok = __rc_drop_reuse p@ (fresh @tok@) and that 'RCon' to
-- @RReuseCon tok c' fields@. The scan REFUSES to cross a nested
-- 'Case'/'LetJoin'/'RLam'/'Handle' (so a branchy @filter@ alt is left unchanged).
--
-- 'TyEnv' is extended as the chain's 'Let's are scanned so a target 'RCon' field
-- that names an EARLIER chain binder resolves to a class.
tryRewriteBody :: TyEnv -> Text -> Unique -> [SlotClass] -> Supply -> Expr -> (Supply, Expr)
tryRewriteBody = findDrop
  where
    -- Phase 1: walk the straight-line tail looking for the parent drop. The chain
    -- is a sequence of 'Let's; anything else (Ret / Jump / Case / ...) ends the
    -- straight line with no drop found.
    findDrop env mc p sig sup (Let b rhs rest)
      | Just v <- dropTargetOf p rhs =
          -- Found the parent drop (@v@ is the dropped variable, == the scrutinee
          -- @p@). Look ONWARD on the same chain for the first slot-kind-compatible
          -- target 'RCon'. The token is born here; mint a fresh 'Unique' for it only
          -- if a target exists (so a refused alt mints nothing, keeping Uniques
          -- stable).
          let env' = Map.insert (binderUnique b) (bndType b) env
          in case findTarget env' mc sig rest of
               Just rebuild ->
                 let (tokU, sup') = freshU sup
                     tokN         = Name tokHint tokU
                     tokB         = Binder tokN Unrestricted unitTy
                     rest'        = rebuild (AVar tokN)
                 in (sup', Let tokB (RApp (AVar dropReuseName) [AVar v]) rest')
               Nothing -> (sup, Let b rhs rest)
      | otherwise =
          let env'          = Map.insert (binderUnique b) (bndType b) env
              (sup', rest') = findDrop env' mc p sig sup rest
          in (sup', Let b rhs rest')
    findDrop _ _ _ _ sup e = (sup, e)

    -- Phase 2: from the point just after the drop, scan the straight-line tail for
    -- the first 'RCon' that is reuse-compatible with the matched cell. Returns a
    -- function that, given the fresh token atom, rebuilds the remainder with that
    -- 'RCon' replaced by an 'RReuseCon'. REFUSES (returns 'Nothing') at any
    -- non-'Let' terminator, so a nested 'Case'/'LetJoin' (which a 'Let' rhs cannot
    -- be in ANF, but a body tail can) or a non-straight-line tail simply yields no
    -- target.
    --
    -- Compatibility (review finding F1) requires BOTH: (1) the target constructor
    -- name equals the matched constructor @mc@, AND (2) the target's slot-kind
    -- signature equals @sig@. SAME-constructor only: the §6.3 backend-lockstep +
    -- descriptor-validity argument holds solely for same-constructor reuse. A
    -- cross-constructor target whose tag was first C-allocated at a different
    -- slot-kind instantiation would re-stamp under a stale tag-keyed descriptor
    -- (silent mis-decode) AND diverge from the abstract heap (which has no
    -- descriptor and reuses unconditionally). Cross-constructor reuse is NOT sound
    -- within the value-only-'nodeCEligible' design, so it is refused here.
    findTarget :: TyEnv -> Text -> [SlotClass] -> Expr -> Maybe (Atom -> Expr)
    findTarget env mc sig (Let b rhs@(RCon c fields) rest)
      | c == mc
      , Just tsig <- targetSlotSig env fields
      , tsig == sig =
          -- The matching target: rebuild THIS Let as an 'RReuseCon' of the token.
          Just (\tok -> Let b (RReuseCon tok c fields) rest)
      | otherwise =
          -- A non-matching 'RCon' (different constructor, mismatched signature, or
          -- undetermined fields): keep scanning onward, threading the env so a later
          -- target sees this binder's type.
          continue env mc b rhs rest sig
    -- An 'RLam'-bound 'Let' REFUSES (spec §6.2: "REFUSE if a nested ... RLam ...
    -- sits between the drop and the RCon"). A closure capture interacts with the
    -- token in ways S2 does not model, so the conservative choice is to stop the
    -- target scan rather than ride the token past a lambda allocation.
    findTarget _ _ _ (Let _ (RLam _ _) _) = Nothing
    -- An 'ROp'-bound 'Let' (an effect operation) REFUSES (review finding, spec §6.2).
    -- An effect op CAPTURES the continuation: it suspends and hands the pending
    -- tail (which would hold the still-unconsumed reuse token, as an 'RReuseCon')
    -- to the handler. If the handler ABORTS, dropping that captured continuation
    -- runs 'Wok.Interp.RC.Value.continuationOwned' over a body containing the
    -- 'RReuseCon'. More fundamentally, the reserved shell has NO finalizer wired
    -- into the M2b/M3 continuation-RC owned set, so a token spanning an effect op
    -- under an aborting handler would leak its reserved shell. S2 forbids the token
    -- from spanning an effect op outright: STOP the target scan here (do NOT ride
    -- past it), so the pair is never formed. (FULL effect-safety --- a Koka-style
    -- reuse-token finalizer in the continuation owned set --- is a deferred
    -- follow-on; the S2 corpus is effect-free, so this is unobservable there.)
    findTarget _ _ _ (Let _ (ROp{}) _) = Nothing
    findTarget env mc sig (Let b rhs rest) =
      -- A non-'RCon', non-'RLam' straight-line 'Let' (an RApp/RAtom/RProj/...): keep
      -- scanning. The token rides past it (e.g. the recursive @map f xx@ call),
      -- exactly as it rides the pending continuation in the worked example.
      continue env mc b rhs rest sig
    findTarget _ _ _ _ = Nothing   -- Ret / Jump / Case / LetJoin / Handle: stop.

    -- Continue the target scan past a non-matching 'Let', threading the binder type
    -- and re-wrapping the matched remainder.
    continue env mc b rhs rest sig =
      (\rebuild tok -> Let b rhs (rebuild tok))
        <$> findTarget (Map.insert (binderUnique b) (bndType b) env) mc sig rest

-- | The dropped variable of @rhs@ iff @rhs@ is a @__rc_drop p@ call (matched by
-- hint text, the compiler-synthesized convention) naming the scrutinee @p@, else
-- 'Nothing'. A single total recognizer: it both decides the shape and yields the
-- dropped 'Name', so the caller never needs a separate partial projection.
dropTargetOf :: Unique -> Rhs -> Maybe Name
dropTargetOf p (RApp (AVar h) [AVar v])
  | nameHint h == PN.rcDropName && nameUniq v == p = Just v
dropTargetOf _ _ = Nothing

-- | The @__rc_drop_reuse@ intrinsic head. As with @__rc_dup@/@__rc_drop@ the
-- 'Unique' is irrelevant (the RC interpreter resolves it by HINT through the prim
-- table); a sentinel negative 'Unique' that cannot collide with a real binder.
dropReuseName :: Name
dropReuseName = Name PN.rcDropReuseName (Unique (-1))

-- | The hint for a minted reuse-token binder.
tokHint :: Text
tokHint = Tx.pack "_tok"

unitTy :: CType
unitTy = CTCon TcUnit []
