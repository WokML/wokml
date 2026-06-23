module Wok.Interp.RC.Value
  ( -- * Interpreter monad
    RC
  , liftRC
    -- * Address
  , Addr (..)
  , HeapBackend (..)
    -- * Runtime values
  , RCValue (..)
  , ReuseSlot (..)
  , REnv
  , valueChildren
  , countedRefs
    -- * Lexical scope
  , RCScope (..)
  , emptyRCScope
  , RCJoin (..)
    -- * Continuation stack
  , RCKont (..)
  , kontDepth
  , continuationOwned
  , moveOutCont
  , moveOutContPure
  , spliceKont
    -- * Heap nodes
  , Node (..)
  , CaptureMode (..)
  , nodeValues
  , cascadeChildren
    -- * Store cells
  , Cell (..)
    -- * Allocation statistics
  , Stats (..)
    -- * The owned heap
  , Store (..)
  , emptyStore
  , alloc
  , allocPure
  , allocAt
  , nodeCEligible
  , dropReuse
  , allocStatic
  , writeStatic
  , writeNode
  , writeNodePure
  , isStaticAddr
  , isInline
  , isUncounted
  , deref
  , derefPure
  , mkClosure
  , closureOwnedBoxed
    -- * Static sentinel
  , emptyEnvSentinelAddr
  , initSentinel
    -- * Reference-count operations
  , incref
  , increfPure
  , dropAddr
  , dropAddrPure
    -- * Primitives
  , RCPrim (..)
  , RCPrimResult (..)
  , RCPrimTable
    -- * Atom resolution and binder helpers
  , resolveRCAtom
  , bindRCBinder
  , bindRCBinders
    -- * Rendering
  , renderRCValue
  , renderRCValueRC
    -- * Slot encoding (C-heap NCon field packing)
  , SlotKind (..)
  , encodeSlotC
  , decodeSlotC
  ) where

import Control.Monad (foldM)
import Control.Monad.IO.Class (liftIO)
import Control.Monad.Trans.Except (ExceptT, except)
import Data.Bits (shiftL, shiftR, toIntegralSized, (.&.), (.|.))
import Data.Int (Int64)
import Data.IntMap.Strict (IntMap)
import qualified Data.IntMap.Strict as IM
import Data.IntSet (IntSet)
import qualified Data.IntSet as IS
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Maybe (isJust)
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as Tx
import Data.Word (Word32, Word64)
import Foreign.Ptr (Ptr, ptrToWordPtr, wordPtrToPtr, WordPtr (..))
import Wok.Interp.RC.Heap (WokObj, WokHeap)
import qualified Wok.Interp.RC.Heap as H
import Wok.Interp.Value (RuntimeError (..))
import Wok.IR.Anf
  ( Atom (..), Binder (..), Expr, Handler (..), Lit (..), binderUnique, freeVarsExpr )
import Wok.IR.Escape (dropTargets, nonHeadOccs)
import Wok.IR.Name (JoinId, Unique, nameHint, nameUniq)

-- ---------------------------------------------------------------------------
-- Interpreter monad

-- | The RC interpreter monad: explicit error over IO. The heap is still the pure
-- 'IntMap' inside 'Store'; the 'IO' base is the home a later task's FFI calls
-- (constructor cells on a real malloc-backed C heap) will live in. Today every
-- store op is a pure computation lifted into this monad with 'liftRC' or 'pure',
-- so there is no behaviour change.
type RC a = ExceptT RuntimeError IO a

-- | Lift a pure-store result (the @Either RuntimeError@ shape the underlying
-- algebra still produces) into the interpreter monad.
liftRC :: Either RuntimeError a -> RC a
liftRC = except

-- ---------------------------------------------------------------------------
-- Addresses and values

-- | A heap address. Either an index into the abstract 'IntMap' heap ('HAddr',
-- the long-standing pure store --- non-negative for the dynamic heap, negative
-- for the static immortal region) OR a raw pointer to a cell in the C runtime
-- heap ('CAddr', allocated by 'Wok.Interp.RC.Heap.wokAlloc' when the backend is
-- 'CHeap' and an 'NCon's fields are all encodable).
--
-- A 'CAddr' never enters the 'IntMap'/'IntSet' of the abstract store; the C
-- runtime owns its lifetime (refcount, free). Cross-heap edges are possible (a C
-- cell may hold an 'HAddr' child via the @HBOX@ slot tag, and an abstract cell
-- may hold a 'CAddr' child via 'RVBox'); the drop cascade routes each child by
-- its 'Addr' kind, so the two heaps interoperate.
data Addr = HAddr Int | CAddr (Ptr WokObj) | Inline Word32
  deriving (Eq, Ord, Show)

-- | Runtime values in the RC interpreter. Either an unboxed literal, a
-- boxed pointer to a heap 'Node', or a member handle into a shared-env
-- recursive closure group.
--
-- 'RVRecMember' @groupAddr@ @index@ @envAddr@:
--   * @groupAddr@  — a STATIC (negative, immortal, uncounted) address holding
--     the group's 'NGroupCode' node.  It is never increfed or dropped.
--   * @index@      — which member of the group this handle names.
--   * @envAddr@    — a DYNAMIC address holding the shared 'NEnv' cell.  This
--     is the ONLY counted child of an 'RVRecMember'; see 'valueChildren'.
data RCValue
  = RVLit Lit
  | RVBox Addr
  | RVRecMember Addr Int Addr
    -- ^ groupAddr (static, uncounted), index, envAddr (counted)
  | RVInst Unique Int
    -- ^ A named effect-instance handle (the RC analogue of
    -- 'Wok.Interp.Value.VInst'): the handler self-binder 'Unique' (the install
    -- SITE) paired with the per-activation tag (the 'kontDepth' at install). It
    -- is an UNBOXED IDENTITY pair --- it owns no counted heap cell, so
    -- 'valueChildren' is empty and dup/drop of it are inert (no counted ref to
    -- acquire or release).
  | RVReuse (Maybe ReuseSlot)
    -- ^ An affine in-place-reuse ticket (FBIP, spec §4.1): a one-use token
    -- produced by 'dropReuse' and consumed by 'allocAt'. 'RVReuse Nothing' is
    -- NULL (the donor cell was shared or uncounted, nothing to reuse);
    -- 'RVReuse (Just slot)' carries a reserved shell of a recorded arity.
    --
    -- The token is AFFINE (produced once, consumed once) and owns no counted
    -- child: 'valueChildren (RVReuse _) = []'. Its reserved shell's children
    -- were already released at 'dropReuse'; the shell is owned solely by the
    -- token until 'allocAt' either revives or frees it, so dup/drop of an
    -- 'RVReuse' are inert (no counted ref to acquire or release).
  deriving (Eq, Show)

-- | A reserved shell carried by a reuse token (FBIP, spec §4.1). Recorded at
-- 'dropReuse' time so 'allocAt' can decide reuse-vs-fresh from backend-independent
-- data (arity + the C-eligibility bit), keeping the abstract and C backends in
-- lockstep.
data ReuseSlot = ReuseSlot
  { rsAddr      :: Addr     -- ^ the reserved shell ('HAddr' index or 'CAddr' pointer)
  , rsArity     :: Word32   -- ^ the shell's physical arity (= byte size)
  , rsCEligible :: Bool     -- ^ whether the OLD node was C-heap-eligible ('nodeCEligible')
  }
  deriving (Eq, Show)

-- | The counted heap addresses reachable from an 'RCValue'. This is the single
-- source of truth used by dup and drop cascades.
--
--   * 'RVLit'       — no boxed children.
--   * 'RVBox'       — one counted address: the node pointer.
--   * 'RVRecMember' — one counted address: the shared env cell (@envAddr@).
--     The @groupAddr@ is static/immortal and therefore UNCOUNTED; it is
--     deliberately excluded.
--   * 'RVInst'      — no counted children (an unboxed identity pair).
--   * 'RVReuse'     — no counted children (an affine reuse ticket; its reserved
--     shell's children were already released at 'dropReuse', so the token is
--     inert to dup/drop).
valueChildren :: RCValue -> [Addr]
valueChildren (RVLit _)          = []
valueChildren (RVBox a)          = [a]
valueChildren (RVRecMember _ _ e) = [e]
valueChildren (RVInst _ _)        = []
valueChildren (RVReuse _)         = []

-- | The counted addresses a set of values references (skip static). The SINGLE
-- unit of both capture-incref and free-cascade, via 'valueChildren' --- so every
-- value shape ('RVBox', 'RVRecMember', and any future variant) is retained
-- EXACTLY as it is released. There is no parallel borrowed-set to drift.
countedRefs :: [RCValue] -> [Addr]
countedRefs = concatMap (filter (not . isUncounted) . valueChildren)

-- | Variable environment: identity (Unique) -> RC runtime value.
type REnv = Map Unique RCValue

-- ---------------------------------------------------------------------------
-- Lexical scope

-- | A lexical scope: term bindings plus join points. The RC analogue of
-- 'Wok.Interp.Value.Scope'. M1 is the no-handler fragment, so there are no
-- effect-handler frames; only term bindings and join points appear.
data RCScope = RCScope { rscEnv :: REnv, rscJoins :: Map JoinId RCJoin }
  deriving (Eq, Show)

-- | The empty scope: no term bindings, no join points.
emptyRCScope :: RCScope
emptyRCScope = RCScope Map.empty Map.empty

-- | A labelled local continuation: the scope captured where the join was
-- defined, its parameters, its body, and the continuation to run after it.
-- The RC analogue of 'Wok.Interp.Value.JoinPoint'.
data RCJoin = RCJoin RCScope [Binder] Expr RCKont
  deriving (Eq, Show)

-- ---------------------------------------------------------------------------
-- Continuation stack

-- | The continuation stack for the RC machine. Mirrors
-- 'Wok.Interp.Value.Kont'. The M2b-1 'KHandleRC' frame brings reference
-- counting to effect handlers (the counted analogue of 'KHandle').
data RCKont
  = KDoneRC
  | KLetRC Binder Expr RCScope RCKont
    -- ^ bind the produced value to the 'Binder', then run the 'Expr' in scope.
  | KAppRC [RCValue] RCKont
    -- ^ over-application: apply the produced value to these extra args.
  | KHandleRC Handler Int RCScope RCKont
    -- ^ effect delimiter (the counted analogue of 'Wok.Interp.Value.KHandle').
    -- The 'Int' is the activation tag (the 'kontDepth' at install) that, with the
    -- handler's self-binder 'Unique', identifies this activation for named
    -- dispatch; ambient dispatch ignores it.
    --
    -- RC DISCIPLINE: the frame captures its 'RCScope' BY REFERENCE, exactly like
    -- 'KLetRC' --- it does NOT incref the scope's values on install. The scope's
    -- values are owned by their binders and released by the Perceus pass at last
    -- use; the frame holds them only so the return arm resolves consistently.
  | KDropCellRC Addr RCKont
    -- ^ DEFERRED CONSUME of an unnamed-intermediate closure cell (M2a-2). When an
    -- application CONSUMES an anonymous function value (an over-application
    -- intermediate, or a 'PRApply'/'KAppRC' result with no IR binder), the cell's
    -- drop must run AFTER its body returns, not before: the body BORROWS the cell's
    -- captures (a 'LetRec' member's shared env is reached through an 'RVRecMember'
    -- capture and is cascade-eligible on the cell's drop), so dropping the cell up
    -- front would free the env mid-call --- a use-after-free. This frame holds the
    -- cell address; when the body's result returns it runs 'dropAddr' on the cell
    -- (cascading the cell's OWN owned captures, now that the body is done borrowing
    -- them) and threads the value onward. The cell is alive throughout its own call,
    -- exactly as the named-head borrow case keeps it alive via its binder.
  deriving (Eq, Show)

-- | Number of frames in a continuation (the RC analogue of
-- 'Wok.Interp.Value.kontDepth'). Used as the per-activation tag when a named
-- handler is installed: distinct COEXISTING (nested) activations of one runner
-- site sit at strictly different depths, so the tag tells them apart. Counts
-- 'KLetRC'/'KAppRC'/'KHandleRC'/'KDropCellRC' frames; 'KDoneRC' is depth 0.
kontDepth :: RCKont -> Int
kontDepth = go 0
  where
    go n KDoneRC             = n
    go n (KLetRC _ _ _ k)    = go (n + 1) k
    go n (KAppRC _ k)        = go (n + 1) k
    go n (KHandleRC _ _ _ k) = go (n + 1) k
    go n (KDropCellRC _ k)   = go (n + 1) k

-- | The OWNED SET of a captured continuation prefix (M2b-1, the crux; spec §4.2):
-- the addresses the continuation's own pending drop/move instructions would free
-- if it ran. This is NOT all the values in the captured scopes --- a runtime scope
-- mixes OWNED, BORROWED, MOVED-AWAY (stale), and GLOBAL bindings, and cascading
-- all of them double-frees the latter three. The abort path ('cascadeChildren' for
-- 'NCont') frees EXACTLY this set, then the shell; resume (Task 5) frees neither
-- (the spliced frames' own instructions fire as they run).
--
-- Deduped by binder 'Unique': a value live across several frames is owned by ONE
-- binder and freed once; two DISTINCT aliasing binders (a @let a = x@ the pass
-- dup'd) are owned separately and freed twice, matching the refcount. 'KAppRC' /
-- 'KDropCellRC' contribute RAW owned addresses (no 'Unique', never deduped against
-- vars). For each 'KLetRC r body sc' frame the owned binders are:
--
--   * @nonHeadOccs body@ --- the MOVE/consuming occurrences (the 'Wok.IR.Escape'
--     single source of truth: it already excludes a saturated call HEAD = borrow-
--     on-call, and the @__rc_dup@/@__rc_drop@ args);
--   * UNION @dropTargets body@ --- a value BORROWED then DROPPED (a call head the
--     pass drops at last use) is in NEITHER 'nonHeadOccs' NOR the escaping atoms,
--     only here (e.g. @c@ in @let r = c(self) in __rc_drop c; r@). ESSENTIAL;
--   * INTERSECT @freeVarsExpr body@ --- only values LIVE at the op site (bound
--     before it) count. This EXCLUDES a MOVED-AWAY value (its last use preceded the
--     op, so it is not free here --- not double-freed);
--   * MINUS the frame binder @r@ (the pending result; does not exist yet).
--
-- 'countedRefs [v]' resolves a binding to its counted (non-static) addresses, so
-- globals/static are skipped and an unboxed 'RVInst' contributes nothing.
continuationOwned :: RCKont -> [Addr]
continuationOwned = dedup . go
  where
    -- (Maybe Unique, Addr): scope-resolved vars carry their Unique for dedup;
    -- KAppRC/KDropCellRC contribute raw owned addresses (no Unique).
    go :: RCKont -> [(Maybe Unique, Addr)]
    go KDoneRC                = []
    go (KLetRC r body sc k)   = frameOwned r body sc ++ go k
    go (KAppRC vs k)          = [ (Nothing, a) | a <- countedRefs vs ] ++ go k
    go (KDropCellRC a k)      = [ (Nothing, a) | not (isUncounted a) ] ++ go k
    -- A nested handler frame in the captured prefix owns its PARAMETER value (if
    -- any).  Only the parameter slot is owned by the frame itself; the rest of
    -- hsc is the captured enclosing scope, whose binders are owned by their own
    -- KLetRC frames elsewhere in the prefix (freeing them here would double-free).
    --
    -- LOAD-BEARING INVARIANT: a dispatched handler's own KHandleRC frame is OFF
    -- the live Kont while its arm runs (the arm executes under kBelow, not under
    -- the handler's own frame). Therefore a KHandleRC frame appearing here is
    -- always a PASSIVE NESTED handler -- one that is in the captured continuation
    -- prefix above an op dispatch, not the currently-running handler. The nested
    -- handler's param is owned exactly once (the frame holds the one live reference),
    -- and 'dropAddr's 'stDead' guard would catch a violation loudly.
    --
    -- The parameter entry is keyed by the Binder's Unique so the dedup logic
    -- collapses aliased live-across-frames entries to one, matching the refcount.
    --
    -- RAW-VS-NAMED NON-DEDUP (code-review #5/#7): a raw (Nothing, a) entry is NOT
    -- deduped against a named (Just u, a) entry. This is CORRECT-BY-RC-ACCOUNTING,
    -- not a latent double-free; see the 'dedup' note below for the invariant.
    go (KHandleRC h _ hsc k)  =
      [ (Just (binderUnique pb), a)
      | Just pb <- [hParam h]
      , Just v  <- [Map.lookup (binderUnique pb) (rscEnv hsc)]
      , a       <- countedRefs [v] ]
      ++ go k
    frameOwned r body sc =
      let owned = (nonHeadOccs Set.empty body `Set.union` dropTargets body)
                    `Set.intersection` freeVarsExpr body
          owned' = Set.delete (binderUnique r) owned
      in [ (Just u, a)
         | u <- Set.toList owned'
         , Just v <- [Map.lookup u (rscEnv sc)]
         , a <- countedRefs [v] ]
    -- Dedup the named-binder entries by (Unique, Addr) pair: a value live across
    -- several frames is owned once (same binder, same address -> single free); two
    -- DISTINCT aliasing binders stay separate, matching refcount.  Keying on the
    -- full (Unique, Addr) pair -- rather than Unique alone -- handles the
    -- parameterized-handler 'set' scenario: after a two-arg resume the param binder
    -- 'pb' appears in the KHandleRC frame (new value) AND in the KLetRC arm frame
    -- (old value in env2); both share the same Unique but carry DIFFERENT addresses,
    -- so both must be freed.  Keying on Unique alone would collapse them and leak
    -- the older value.
    --
    -- Raw-address entries (KAppRC over-args, KDropCellRC) carry no Unique and are
    -- emitted verbatim.
    --
    -- RAW-VS-NAMED NON-DEDUP IS CORRECT BY RC-ACCOUNTING (code-review #5/#7). A
    -- (Nothing, a) raw entry is deliberately NEVER compared against a (Just u, a)
    -- named entry, so when the SAME cell @a@ is owned BOTH through a named frame
    -- binder AND through a raw KAppRC/KDropCellRC frame, @a@ appears in the owned set
    -- TWICE and is freed twice. This is the RIGHT count, not a double-free:
    --
    --   THE INVARIANT: the owned set's MULTIPLICITY of @a@ equals @a@'s REFCOUNT.
    --   Both the named occurrence (a MOVE binder) and the raw occurrence (a MOVE
    --   over-arg / a moved-in closure cell) are CONSUMING positions, so the Perceus
    --   pass inserts a @__rc_dup@ on the shared value at the second move position ---
    --   @a@ genuinely has rc = 2, and freeing it twice (rc 2 -> 0) is exactly
    --   balanced. DEDUPING here would emit @[a]@ and free @a@ ONCE (rc 2 -> 1), a
    --   LEAK. (Empirically verified: with a KAppRC over-arg coinciding with a KLetRC
    --   named binder at rc 2, the real per-entry free returns stLive to baseline
    --   whereas a distinct-address dedup leaks one cell --- see the #5 dedup
    --   experiment and 'rcM3RawVsNamedOwnedSetTests'.)
    --
    --   This is the SAME accounting that licenses keying the named dedup on the full
    --   (Unique, Addr) pair rather than Unique alone: entries are collapsed ONLY when
    --   they denote the SAME owner edge (same binder, same address); every DISTINCT
    --   consuming edge (a second binder, OR a raw move position) is its own +1 the
    --   Perceus dup already paid for, so it must be its own free.
    --
    -- INVARIANT, PRECISELY (code-review #5). For every cell @a@:
    --   (owned-set multiplicity of @a@) == (refcount of @a@),
    -- and this equality is MAINTAINED by the Perceus dups: each distinct consuming
    -- owner edge of @a@ (a named binder OR a raw move position) is one +1 the pass
    -- paid for with a @__rc_dup@, so it is one entry in the owned set AND one unit of
    -- rc. Per-entry free (no raw/named dedup) therefore frees @a@ exactly rc-many
    -- times: balanced, never a leak, never a double-free.
    --
    -- LOUD-ON-VIOLATION, NOT SILENT-CORRUPTION; the 'stDead' guard is the real net.
    -- If the multiplicity ever EXCEEDED the refcount (a genuine Perceus
    -- dup/drop-placement bug --- an over-count the dups did NOT pay for), the SURPLUS
    -- free would hit 'dropAddr's 'stDead' double-free guard and raise a LOUD
    -- "double-free: addr a" error, not silently corrupt the heap. So a desync is
    -- caught at the exact violating free, by the universal allocator-level net ---
    -- never a quiet wrong answer.
    --
    -- UNIT-PINNED, NOT CORPUS-REACHED. The raw+named coincidence (KAppRC/KDropCellRC
    -- inside a captured continuation prefix at the SAME address as a named frame
    -- binder) does NOT arise in the current language fragment, so this accounting is
    -- pinned by the hand-built 'rcM3RawVsNamedOwnedSetTests' unit, NOT exercised
    -- end-to-end by an elaboration->Perceus->run corpus program. The unit pins the
    -- per-entry-free-vs-dedup distinction at the owned-set level; the 'stDead'
    -- tripwire above is the end-to-end backstop that would catch any real desync if
    -- the fragment ever grows to reach this path. (No cheap heap-balanced corpus
    -- program reaches a raw+named coincidence today, so we do not force one.)
    dedup = goD Set.empty
      where
        goD _ [] = []
        goD seen ((Just u, a) : rest)
          | (u, a) `Set.member` seen = goD seen rest
          | otherwise                = a : goD (Set.insert (u, a) seen) rest
        goD seen ((Nothing, a) : rest) = a : goD seen rest

-- | Resume move-out (M2b-1 Task 5; spec §4.3 RESUME, §4.5.0): free the 'NCont'
-- shell WITHOUT cascading its children, and return the captured frame prefix +
-- handler-reinstall info. One-shot guarantees @rc == 1@ (the single owner is
-- consumed here); the children's refcounts are LEFT UNTOUCHED because ownership
-- transfers to the re-prepended live frames (the move) --- their own pending
-- @__rc_drop@/move instructions fire as the spliced frames run. Contrast
-- 'dropAddr'/'cascadeChildren', which frees the owned set ('continuationOwned').
-- A defensive @rc /= 1@ check turns a slipped multi-shot into a loud error rather
-- than a silent use-after-free. The interpreter monad form; 'moveOutContPure' is
-- the pure core.
moveOutCont :: Addr -> Store -> RC (RCKont, (Handler, Int, RCScope), Store)
moveOutCont a s = liftRC (moveOutContPure a s)

-- | The pure core of 'moveOutCont'. An 'NCont' cell is never C-eligible (it is
-- not an 'NCon'), so it always lives on the abstract heap; a 'CAddr' here is an
-- internal routing error.
moveOutContPure :: Addr -> Store -> Either RuntimeError (RCKont, (Handler, Int, RCScope), Store)
moveOutContPure (CAddr _)   _ = Left (PrimError (Tx.pack "resume: continuation cannot live on the C heap"))
moveOutContPure (Inline _)  _ = Left (PrimError (Tx.pack "resume: inline immediate is not a continuation"))
moveOutContPure a@(HAddr i) s = do
  c <- derefPure a s
  case cNode c of
    NCont prefix hinfo
      | cRc c == 1 ->
          let s' = s { stCells = IM.delete i (stCells s)
                     , stDead  = IS.insert i (stDead s)
                     , stStats = recordFree (stStats s) }
          in Right (prefix, hinfo, s')
      | otherwise ->
          Left (PrimError (Tx.pack ("internal: resume of a continuation with rc=" <> show (cRc c)
                                     <> " (one-shot violation); addr " <> show i)))
    _ -> Left (PrimError (Tx.pack ("resume of non-continuation addr " <> show i)))

-- | Splice (M2b-1 Task 5): replace the innermost 'KDoneRC' marker of a captured
-- prefix with the given tail. The prefix (built by @rcDispatchOp@ as @above
-- KDoneRC@) is a linear chain of 'KLetRC'/'KAppRC'/'KHandleRC'/'KDropCellRC'
-- frames terminated by exactly one 'KDoneRC' (the op site is always below a
-- handler, so the walk that built it never reached a real 'KDoneRC'). This
-- mirrors the reference @enter@ 'VCont' arm's @kb k@ frame re-prepend; the tail
-- @tl@ is the re-installed handler over the post-resume continuation.
spliceKont :: RCKont -> RCKont -> RCKont
spliceKont prefix tl = go prefix
  where
    go KDoneRC                = tl
    go (KLetRC b e sc k)      = KLetRC b e sc (go k)
    go (KAppRC vs k)          = KAppRC vs (go k)
    go (KHandleRC h tag sc k) = KHandleRC h tag sc (go k)
    go (KDropCellRC a k)      = KDropCellRC a (go k)

-- ---------------------------------------------------------------------------
-- Heap nodes

-- | A heap-allocated node. Each constructor corresponds to one of the
-- storable wok value kinds.
data Node
  = NCon Text [RCValue]
  | NRecord Text (Map Text RCValue)
  | NClosure REnv [Binder] Expr CaptureMode
  -- ^ The 'REnv' captures live RC values. Compare 'VClosure' in
  -- "Wok.Interp.Value" which uses a lazy @~Env@. We keep a strict counted
  -- env here; recursive groups share their captured env via a single 'NEnv'
  -- cell rather than introducing a lazy field.
  --
  -- RETAIN/RELEASE. The cell OWNS one counted ref to each of its DYNAMIC captures,
  -- acquired where the capture enters the cell and released by the drop cascade
  -- ('countedRefs' over the env) exactly once --- one source of truth for the free.
  -- The 'CaptureMode' records the SEPARATE question of whether the closure BODY
  -- receives ownership of its captures on entry (see 'closureOwnedBoxed' and
  -- @enterRC@'s @increfOwned@); it does NOT affect the drop cascade.
  | NGroupCode [(Binder, [Binder], Expr)]
  -- ^ The code table for a shared-env recursive closure group. Installed at a
  -- STATIC (negative, immortal) address via 'allocStatic'; it is never
  -- reference-counted, dropped, or cascaded. Each element is
  -- @(selfBinder, params, body)@ for one member of the group.
  | NEnv (Map Unique RCValue)
  -- ^ The shared captured-environment cell for a recursive closure group.
  -- Allocated on the DYNAMIC heap (counted). All members of the group share a
  -- single 'NEnv' node; when the last member handle is dropped the env cell
  -- is freed and its owned children are cascaded via 'nodeValues'.
  | NCont RCKont (Handler, Int, RCScope)
  -- ^ A REIFIED DELIMITED CONTINUATION (M2b-1 Task 4): the captured frame prefix
  -- (the @above@ frames between an op site and its handler, stored CONCRETELY as
  -- an 'RCKont' terminated by 'KDoneRC' --- the splice marker for resume) plus the
  -- matching handler's @(handler, activation tag, captured scope)@ for re-install
  -- on resume (Task 5). Reached via an ordinary 'RVBox' handle bound to the op-arm
  -- @resume@ binder.
  --
  -- RC DISCIPLINE (the crux). An 'NCont's free does NOT route through the generic
  -- 'nodeValues' cascade ('nodeValues (NCont _ _) = []'): cascading every value in
  -- the captured scopes would double-free borrowed/moved/global bindings. Instead
  -- its OWNED SET --- the addresses the continuation's own pending drop/move
  -- instructions would consume --- is computed by 'continuationOwned' and freed by
  -- 'cascadeChildren' (the single free path in 'dropAddr'). Capture increfs nothing
  -- (the frames are MOVED in, still owned by their binders); abort frees the owned
  -- set once; resume (Task 5) discards the shell WITHOUT freeing the owned set.
  | NContCell (Maybe Addr)
  -- ^ An AFFINE ONE-SHOT continuation slot (M3-b, spec §4.1): empty ('Nothing')
  -- or holding exactly one continuation addr ('Just a'). The cell goes empty ->
  -- holding -> empty (filled once by @__cont_store@, emptied once by
  -- @__cont_take@), never overwriting a live value, so it forges no cycle.
  --
  -- RC DISCIPLINE. Unlike 'NCont', a cell uses the GENERIC cascade: the held
  -- continuation is an ORDINARY COUNTED CHILD of the cell ('nodeValues' returns
  -- it as a single 'RVBox', and 'cascadeChildren' falls through to the
  -- 'countedRefs . nodeValues' default). So dropping a full cell at rc 0
  -- decrements the held continuation, whose own drop then runs its owned-set free
  -- once (the 'NCont' abort path) -- one free path, no double-free, no leak.
  -- @__cont_store@ moves the addr in WITHOUT an incref (the binder is consumed),
  -- so the cell holds the one counted edge the binder used to.
  deriving (Eq, Show)

-- | Whether a closure BODY receives ownership of its captures on entry. This is
-- about the BODY's Perceus instrumentation, NOT the cell's drop (which always
-- cascades the cell's counted captures via 'countedRefs').
--
--   * 'OwnCaptures' --- an ordinary 'RLam' body (or a partial application of an
--     ordinary closure). Perceus seeds each boxed capture at @+1@ in the body and
--     drops it at its last use, so @enterRC@ must hand the body that ownership
--     (incref the body-owned 'RVBox' captures on entry; see 'closureOwnedBoxed').
--   * 'BorrowCaptures' --- a partial application of a shared-env recursive MEMBER
--     ('RVRecMember'). The cell's body is the member body, which BORROWS its
--     siblings and captured locals (a member never CONSUMES a capture --- #1 is
--     deferred/boundary-rejected) and emits no drops for them. So @enterRC@ must
--     incref NOTHING on entry; the cell already owns one ref to each capture
--     (acquired at the partial-application build) which its drop cascade releases.
--     Increfing on entry here would leak the shared env (the unmatched-incref bug).
data CaptureMode = OwnCaptures | BorrowCaptures
  deriving (Eq, Show)

-- ---------------------------------------------------------------------------
-- Store cells

-- | A single heap cell: a reference count and the node payload.
data Cell = Cell { cRc :: Int, cNode :: Node }
  deriving (Eq, Show)

-- ---------------------------------------------------------------------------
-- Allocation statistics

-- | Monotonic counters maintained by 'alloc' and (in later tasks) by drop.
data Stats = Stats
  { stAllocs :: Int   -- ^ total allocations since emptyStore
  , stFrees  :: Int   -- ^ total frees since emptyStore (unused until dup/drop)
  , stLive   :: Int   -- ^ current live-cell count
  , stPeak   :: Int   -- ^ high-water mark of live-cell count
  }
  deriving (Eq, Show)

-- | Record one allocation: bump total allocs and the live count, raising the
-- high-water peak. The single source of truth for alloc-stat math (shared by
-- the abstract and C heap paths so their totals stay byte-identical).
recordAlloc :: Stats -> Stats
recordAlloc g = let live = stLive g + 1
                in g { stAllocs = stAllocs g + 1, stLive = live, stPeak = max (stPeak g) live }

-- | Record one free: bump total frees and drop the live count. Shared by the
-- abstract and C heap free paths.
recordFree :: Stats -> Stats
recordFree g = g { stFrees = stFrees g + 1, stLive = stLive g - 1 }

-- ---------------------------------------------------------------------------
-- The owned heap

-- | The explicit owned heap: a map from addresses to cells, a free list of
-- addresses whose reference count dropped to zero, a monotonic allocator
-- counter, and allocation statistics.
--
-- ADDRESS LAYOUT. The dynamic heap uses NON-NEGATIVE addresses (@>= 0@),
-- handed out by 'alloc' from 'stNext'. The STATIC immortal region (top-level
-- binds; see 'allocStatic' and 'runModuleRC') uses NEGATIVE addresses
-- (@< 0@), handed out from 'stNextStatic' going downward. Both live in the
-- same 'stCells' map, so 'deref' is uniform, but the sign of an address tells
-- the reference-count operations whether the cell is counted: 'incref' and
-- 'dropAddr' are NO-OPS on static (negative) addresses, and 'allocStatic'
-- never touches 'stStats', so static cells are "never counted, never dropped,
-- excluded from stLive" exactly as the design spec requires.
data Store = Store
  { stCells      :: IntMap Cell
  , stNext       :: Int         -- ^ next dynamic abstract address (>= 0), counts upward
  , stNextStatic :: Int         -- ^ next static abstract address (< 0), counts downward
  , stDead       :: IntSet
  , stStats      :: Stats
  , stBackend    :: HeapBackend
    -- ^ the heap an 'NCon' allocates into (see 'alloc'). 'AbstractHeap' (the
    -- default) keeps everything in the 'IntMap'; 'CHeap' routes encodable 'NCon's
    -- to the C runtime ('CAddr'). All OTHER node kinds always use the abstract heap.
  , stTagFwd     :: Map Text Word32
    -- ^ constructor-name -> tag-id, the forward half of the interning bijection
    -- used to give each constructor a stable small integer for the C 'wokAlloc'
    -- tag word (which the C runtime stores verbatim and 'deref' reverses).
  , stTagRev     :: IntMap Text
    -- ^ tag-id -> constructor-name, the reverse half (keyed by the id as 'Int').
  , stConDesc    :: IntMap [SlotKind]
    -- ^ tag-id -> per-slot kind descriptor, recorded by 'allocNCon' on first
    -- intern. 'readCCell' and the 'CAddr' arm of 'dropAddr' consult this to
    -- decode raw slot words back into 'RCValue's without a per-slot tag word.
  }

-- | Which heap an 'NCon' is allocated into. 'AbstractHeap' is the default and is
-- the only backend the test suite and the differential oracle's reference side
-- use; 'CHeap' carries the live C runtime context pointer that an encodable
-- 'NCon' allocates into.
data HeapBackend = AbstractHeap | CHeap (Ptr WokHeap)

-- ---------------------------------------------------------------------------
-- Static empty-env sentinel

-- | The fixed static address that holds the empty-env sentinel cell. This is a
-- well-known NEGATIVE address (static, immortal, uncounted). A capture-free
-- recursive group can use this as its @envAddr@; dup and drop on it are
-- no-ops because 'incref'/'dropAddr' skip static addresses.
--
-- The address -1 is reserved at definition time; 'emptyStore' installs
-- the sentinel there via 'initSentinel'. Any subsequent 'allocStatic' call
-- starts from -2, so the sentinel address is stable.
emptyEnvSentinelAddr :: Addr
emptyEnvSentinelAddr = HAddr (-1)

-- | Install the empty-env sentinel into a store. Call this on 'emptyStore'
-- before use (e.g. in @runModuleRC@). Writes 'NEnv Map.empty' at
-- 'emptyEnvSentinelAddr' using 'allocStatic'; the resulting store's
-- 'stNextStatic' is then -2.
initSentinel :: Store -> Store
initSentinel s =
  let (a, s') = allocStatic (NEnv Map.empty) s
  in if a == emptyEnvSentinelAddr
       then s'
       else error ("initSentinel: expected sentinel at " <> show emptyEnvSentinelAddr
                     <> " but got " <> show a)

-- | The empty store: no cells allocated, all counters at zero. Dynamic
-- addresses start at 0 (upward); static addresses start at -1 (downward).
--
-- Note: the SENTINEL for the empty env is installed separately by
-- 'initSentinel', because 'emptyStore' is also used in unit tests that do
-- not need or expect the sentinel to be present. Tests that exercise
-- 'RVRecMember'/'NEnv' should call @initSentinel emptyStore@ instead.
emptyStore :: Store
emptyStore = Store
  { stCells      = IM.empty
  , stNext       = 0
  , stNextStatic = -1
  , stDead       = IS.empty
  , stStats      = Stats 0 0 0 0
  , stBackend    = AbstractHeap
  , stTagFwd     = Map.empty
  , stTagRev     = IM.empty
  , stConDesc    = IM.empty
  }

-- | Intern a constructor name to its stable tag-id, allocating a fresh id on
-- first sight. Returns the id and the (possibly extended) store. The bijection
-- is monotonic and total over every constructor that has ever been allocated in
-- the C heap, so 'tagName' can always reverse a live cell's tag.
internTag :: Text -> Store -> (Word32, Store)
internTag con s = case Map.lookup con (stTagFwd s) of
  Just w  -> (w, s)
  Nothing ->
    let w = fromIntegral (Map.size (stTagFwd s))
    in ( w
       , s { stTagFwd  = Map.insert con w (stTagFwd s)
           , stTagRev  = IM.insert (fromIntegral w) con (stTagRev s)
           } )

-- | Reverse the interning bijection: tag-id -> constructor name. A 'CAddr' cell
-- can only have been allocated through 'internTag' (which records the reverse
-- entry), so a live C cell's tag is always present; an absent id is an internal
-- corruption and fails loudly rather than fabricating a name.
tagName :: Word32 -> Store -> Text
tagName w s = IM.findWithDefault (error "tagName: unknown tag id") (fromIntegral w) (stTagRev s)

-- ---------------------------------------------------------------------------
-- C-heap slot kind descriptor
--
-- Each C-eligible 'NCon' field has a 'SlotKind' that records its type without
-- consuming a per-slot tag word in the cell.  The descriptor is hoisted into
-- 'stConDesc' (keyed by the constructor's interned tag-id) when the constructor
-- is first allocated, and consulted on every decode ('readCCell', 'dropAddr').

-- | The kind of a single raw slot word in a compact C cell.
data SlotKind = KLitInt | KLitChar | KLitUnit | KPointer
  deriving (Eq, Show)

-- ---------------------------------------------------------------------------
-- C-heap slot encode/decode (the §5 encoding; the single source of truth that
-- decides whether an 'NCon' field is C-eligible).
--
-- 'encodeSlotC' returns 'Nothing' for any value that cannot be packed into a
-- single raw 'Word64' slot, which makes the whole 'NCon' fall back to the
-- abstract heap (see 'allocNCon'). 'decodeSlotC' is its exact inverse on the
-- encodable shapes, driven by the 'SlotKind' from the stored descriptor.

-- | Pack an 'RCValue' into a raw slot @('SlotKind', 'Word64')@, or 'Nothing' if
-- the value is not C-encodable (a string literal, a bignum 'LInt' too wide for
-- 'Int64', a closure-member handle, or an instance handle).
--
-- The 'Int64'-fit check on 'LInt' is load-bearing: a high-bit 'U64' (a natural
-- number >= 2^63) returns 'Nothing' via 'toIntegralSized', causing the whole
-- 'NCon' to fall back to the abstract heap.  This preserves the encoding
-- semantics exactly: NO value is promoted or widened.
--
-- The @KPointer@ class uses the low 2 bits to discriminate three pointer-classes:
--
--   * @..0@ (bit0 = 0): 'CAddr' bare 8-aligned pointer.  'CAddr' pointers are
--     aligned to at least 8 bytes so their low three bits are always 0; no shift
--     needed.
--   * @01@ (bits 1:0 = 01): 'HAddr' abstract index, stored as
--     @(i << 2) .|. 1@.  Negative static indices round-trip correctly because
--     the arithmetic right-shift in 'decodeSlotC' sign-extends the high bit.
--   * @11@ (bits 1:0 = 11): 'Inline' nullary constructor tag, stored as
--     @(tag << 2) .|. 3@.  The slot round-trips the full 'Word32' tag (62 bits of
--     headroom after the 2-bit shift). (The @tid >= 65536@ fallback in 'allocNCon'
--     is a SEPARATE constraint on the C PARENT cell's @uint16@ header tag, not on an
--     'Inline' slot child.)
encodeSlotC :: RCValue -> Maybe (SlotKind, Word64)
encodeSlotC (RVLit (LInt n))    = (\w -> (KLitInt, fromIntegral (w :: Int64))) <$> toIntegralSized n
encodeSlotC (RVLit (LChar c))   = Just (KLitChar, fromIntegral (fromEnum c))
encodeSlotC (RVLit LUnit)       = Just (KLitUnit, 0)
encodeSlotC (RVBox (CAddr p))   = Just (KPointer, fromIntegral (ptrToWordPtr p))
-- HAddr round-trip: low 2 bits = 01.  Negative static indices are sign-preserved
-- because we use Int64 arithmetic shift right on decode.
encodeSlotC (RVBox (HAddr i))   = Just (KPointer, fromIntegral ((i `shiftL` 2) .|. 1))
-- Inline round-trip: low 2 bits = 11.  The full Word32 tag fits after << 2 (62 bits
-- of headroom); even Word32 maxBound (0xFFFFFFFF << 2) stays well within 64 bits.
encodeSlotC (RVBox (Inline t))  = Just (KPointer, (fromIntegral t `shiftL` 2) .|. 3)
encodeSlotC _                   = Nothing

-- | The exact inverse of 'encodeSlotC' on the encodable shapes, driven by the
-- 'SlotKind' from the stored per-constructor descriptor.
--
-- The @KPointer@ low-2-bit discriminant:
--
--   * @..0@ (bit0 = 0): 'CAddr' bare pointer (read as-is).
--   * @01@ (bits 1:0 = 01): 'HAddr' index (arithmetic @>> 2@, sign-extends).
--   * @11@ (bits 1:0 = 11): 'Inline' tag (@>> 2@, unsigned).
decodeSlotC :: SlotKind -> Word64 -> RCValue
decodeSlotC KLitInt  w = RVLit (LInt (fromIntegral (fromIntegral w :: Int64)))
decodeSlotC KLitChar w = RVLit (LChar (decodeChar w))
decodeSlotC KLitUnit _ = RVLit LUnit
decodeSlotC KPointer w
  | w .&. 1 == 0 = RVBox (CAddr (wordPtrToPtr (WordPtr (fromIntegral w))))                   -- 00
  | w .&. 2 == 0 = RVBox (HAddr (fromIntegral ((fromIntegral w :: Int64) `shiftR` 2)))        -- 01
  | otherwise    = RVBox (Inline (fromIntegral (w `shiftR` 2)))                               -- 11

-- | Guard the codepoint so an out-of-range payload yields a clear invariant error.
-- The encoder never emits an out-of-range char, so this can't happen on real data.
decodeChar :: Word64 -> Char
decodeChar w
  | w <= 0x10FFFF && not (w >= 0xD800 && w <= 0xDFFF) = toEnum (fromIntegral w)
  | otherwise = error "decodeSlotC: KLitChar payload out of Char range"

-- | True for a static (immortal, uncounted) address. Static cells are
-- allocated by 'allocStatic' at negative abstract-heap addresses; the dynamic
-- abstract heap uses non-negative addresses. A C-heap cell ('CAddr') is always
-- dynamic (the C runtime has no static region), so it is never static.
isStaticAddr :: Addr -> Bool
isStaticAddr (HAddr i) = i < 0
isStaticAddr (CAddr _) = False
isStaticAddr (Inline _) = False

-- | True for an inline immediate (a nullary constructor with no cell).
isInline :: Addr -> Bool
isInline (Inline _) = True
isInline _          = False

-- | True for an address that owns no counted cell: a static (immortal) address
-- OR an inline immediate. The single filter the counted-ref / owned-set / CAF
-- paths use, so dup/drop and the free cascade skip both uniformly.
isUncounted :: Addr -> Bool
isUncounted a = isStaticAddr a || isInline a

-- | Allocate a fresh node on the heap. Returns the new 'Addr' and the updated
-- 'Store'. The cell is initialised with a reference count of 1.
--
-- BACKEND DISPATCH. Only an 'NCon' is ever C-eligible: under a 'CHeap' backend,
-- an 'NCon' whose every field is encodable allocates in the C runtime ('CAddr');
-- a non-encodable field, or any other node kind, falls back to the abstract
-- 'IntMap' heap ('HAddr', via 'allocPure'). The abstract path is unchanged from
-- the Task-0 pure core, so store-algebra unit tests that call 'allocPure'
-- directly keep working.
alloc :: Node -> Store -> RC (Addr, Store)
alloc (NCon con []) s = pure (allocInline con s)
alloc (NCon con vs) s = allocNCon con vs s
alloc n             s = pure (allocPure n s)

-- | A nullary constructor becomes an inline immediate carrying the interned
-- tag. No 'recordAlloc': an immediate lives on no heap. Interns on BOTH backends
-- so 'deref' can reverse the tag via 'tagName' (stat-invisible: touches only
-- stTagFwd/stTagRev).
allocInline :: Text -> Store -> (Addr, Store)
allocInline con s = let (tid, s') = internTag con s in (Inline tid, s')

-- | Allocate an 'NCon', routing to the C heap when the backend is 'CHeap' and
-- every field is encodable; otherwise the abstract heap. The C path's
-- statistics bump MIRRORS 'allocPure' EXACTLY (one alloc, live + 1, peak
-- high-water) so the abstract-vs-C totals match in the differential oracle.
allocNCon :: Text -> [RCValue] -> Store -> RC (Addr, Store)
allocNCon con vs s = case stBackend s of
  AbstractHeap -> pure (allocPure (NCon con vs) s)
  CHeap hp
    -- The C @arity@ field is a 'uint8' (0..255); a wider constructor cannot be
    -- represented, so route it to the unbounded abstract heap. Checked BEFORE the
    -- encode (which would otherwise be wasted on a cell that must fall back).
    | length vs > 255 -> pure (allocPure (NCon con vs) s)
    | otherwise -> case traverse encodeSlotC vs of
        Nothing -> pure (allocPure (NCon con vs) s)
        Just encoded ->
          let (tid, s1)  = internTag con s
              newKinds   = map fst encoded
              doAlloc st = do
                p <- liftIO (H.wokAlloc hp tid (fromIntegral (length vs)))
                liftIO $ mapM_ (\(i, (_, w)) -> H.wokSlotSet p (fromIntegral i) w)
                               (zip [0 :: Int ..] encoded)
                pure (CAddr p, st { stStats = recordAlloc (stStats st) })
          -- The C @tag@ field is a 'uint16'; beyond 65535 distinct interned
          -- constructors a 'CAddr' would truncate the tag and collide. Fall back.
          in if tid >= 65536
               then pure (allocPure (NCon con vs) s1)
               else case IM.lookup (fromIntegral tid) (stConDesc s1) of
                 -- A nominal/polymorphic constructor (e.g. Tuple2) can appear at
                 -- different instantiations with different slot kinds. The FIRST kind
                 -- seen for a tag wins the C heap; a later mismatch falls back, so the
                 -- recorded descriptor stays correct for every C cell of that tag.
                 -- (Here @s1 == s@: a recorded descriptor implies the tag was already
                 -- interned, so 'internTag' left the store unchanged.)
                 Just existing
                   | existing == newKinds -> doAlloc s1                        -- known: no re-insert
                   | otherwise            -> pure (allocPure (NCon con vs) s1)  -- kind mismatch
                 Nothing -> doAlloc (s1 { stConDesc = IM.insert (fromIntegral tid) newKinds (stConDesc s1) })

-- | The pure core of 'alloc': always allocates on the abstract 'IntMap' heap,
-- returning an 'HAddr'. The backend-aware 'alloc' wrapper decides whether an
-- 'NCon' goes to C instead.
allocPure :: Node -> Store -> (Addr, Store)
allocPure n s =
  let a = stNext s
  in ( HAddr a
     , s { stCells = IM.insert a (Cell 1 n) (stCells s)
         , stNext  = a + 1
         , stStats = recordAlloc (stStats s)
         }
     )

-- | The pure, VALUE-ONLY half of 'allocNCon's C-eligibility decision (FBIP,
-- spec §4.3): 'True' iff the node is an 'NCon' of arity <= 255 whose every field
-- is encodable ('encodeSlotC'). A function of the node's VALUES ONLY --- no
-- 'Store', no descriptor lookup, no @tag < 65536@ check.
--
-- It deliberately OMITS 'allocNCon's descriptor-mismatch and tag-bound checks
-- (spec §4.3/§6.3): those depend on store state that differs between backends,
-- and the pairing post-pass's static slot-kind guard already guarantees no
-- descriptor mismatch can arise at a reuse site, so the tag bound is unreachable
-- there. Restricting to the value-only check is what keeps the abstract and C
-- backends' reuse decisions identical; the only residual runtime difference it
-- captures is integer width within @KLitInt@ (a small int encodes, a @>= 2^63@
-- natural does not).
nodeCEligible :: Node -> Bool
nodeCEligible (NCon _ vs) = length vs <= 255 && all (isJust . encodeSlotC) vs
nodeCEligible _           = False

-- | The field count of a node (FBIP placement match). Only an 'NCon' has a
-- meaningful physical arity for reuse; every other node kind reports 0 (it is
-- never C-eligible and never a reuse donor/target in this slice).
nodeArity :: Node -> Word32
nodeArity (NCon _ vs) = fromIntegral (length vs)
nodeArity _           = 0

-- | Allocate a node into the STATIC immortal region. Returns a NEGATIVE 'Addr'
-- and the updated 'Store'. Unlike 'alloc', this does NOT touch 'stStats': a
-- static cell is never counted in 'stLive'/'stAllocs', is never increfed or
-- dropped (see 'incref'/'dropAddr'), and never appears in 'stDead'. Used by
-- 'runModuleRC' to install top-level binds (the global static region) without
-- perturbing the dynamic-heap accounting that the heap-empty oracle measures.
--
-- The cell's reference count is irrelevant (static cells are uncounted); it is
-- recorded as 1 only so 'deref' returns a well-formed 'Cell'.
allocStatic :: Node -> Store -> (Addr, Store)
allocStatic n s =
  let a = stNextStatic s
  in ( HAddr a
     , s { stCells       = IM.insert a (Cell 1 n) (stCells s)
         , stNextStatic  = a - 1
         }
     )

-- | Overwrite the node at an EXISTING static address (preserving its negative
-- address; does not touch 'stStats'). Used to install a top-level bind's real
-- node after its address was reserved with a placeholder (the two-phase static
-- knot in 'runModuleRC'). It is a programmer error to call this on a dynamic
-- (non-negative) address; doing so silently overwrites a counted cell, so the
-- caller ('runModuleRC') only ever passes reserved static addresses.
writeStatic :: Addr -> Node -> Store -> Store
writeStatic (HAddr i) n s = s { stCells = IM.insert i (Cell 1 n) (stCells s) }
writeStatic (CAddr _) _ _ = error "writeStatic: a C-heap address is never static"
writeStatic (Inline _) _ _ = error "writeStatic: an inline immediate has no cell to overwrite"

-- | Overwrite the NODE payload of an existing cell while PRESERVING its reference
-- count (and statistics). Used by the M3 continuation-cell move primitives
-- (@__cont_store@/@__cont_take@) to transition an 'NContCell' between
-- @Nothing@ (empty) and @Just a@ (holding) in place, since those are MOVES, not
-- allocations: the cell keeps its identity and its refcount across the fill/empty.
-- 'Left'/'throwE' if the address is dead or dangling (the cell must already
-- exist). The interpreter monad form; 'writeNodePure' is the pure core.
writeNode :: Addr -> Node -> Store -> RC Store
writeNode a n s = liftRC (writeNodePure a n s)

-- | The pure core of 'writeNode'. Operates on the abstract heap only: the M3
-- continuation-cell ('NContCell') moves it serves are never C-eligible (an
-- 'NContCell' is not an 'NCon'), so a 'CAddr' here is an internal error.
writeNodePure :: Addr -> Node -> Store -> Either RuntimeError Store
writeNodePure (CAddr _)   _ _ = Left (PrimError (Tx.pack "writeNode: unexpected C-heap address"))
writeNodePure (Inline _)  _ _ = Left (PrimError (Tx.pack "writeNode: inline immediate has no cell"))
writeNodePure a@(HAddr i) n s = do
  c <- derefPure a s
  Right s { stCells = IM.insert i c { cNode = n } (stCells s) }

-- ---------------------------------------------------------------------------
-- Closure construction

-- | Build an ordinary 'NClosure' node (an 'RLam', or a partial application of an
-- ordinary closure): its body OWNS its captures ('OwnCaptures'). The member-body
-- partial-application closure ('BorrowCaptures') is constructed directly in
-- @enterRC@. No precomputed borrowed-set is stored: the cell's drop cascade and
-- the body-seed both derive from the env at use time ('countedRefs' /
-- 'closureOwnedBoxed'), so there is nothing to drift.
mkClosure :: REnv -> [Binder] -> Expr -> Node
mkClosure env ps body = NClosure env ps body OwnCaptures

-- | The BODY-OWNED boxed-capture addresses of an 'NClosure' (empty for any other
-- node): the DYNAMIC 'RVBox' env handles. These are the captures whose ownership
-- the closure BODY receives on entry (the Perceus body-seed) and releases at its
-- own last use --- the @increfOwned@ set in @enterRC@.
--
-- This is INTENTIONALLY NARROWER than the cell's drop cascade
-- ('countedRefs' over the env). A captured 'RVRecMember' (a borrowed group
-- sibling, or a member captured by an escaping closure) is BORROWED BY THE BODY:
-- the body reads/calls it without an incref and emits no drop for it (the LetRec
-- member-body / RLam @capsBorrow@ rule in "Wok.IR.Perceus"). So the body-seed must
-- NOT incref it --- otherwise the unmatched incref leaks the shared env. The CELL
-- nonetheless OWNS one counted ref to that 'RVRecMember' env, acquired where the
-- capture ENTERS the cell (a Perceus @__rc_dup@ at an escaping capture, or the
-- build-time incref in @enterRC@'s 'RVRecMember' partial-application branch) and
-- released by the cascade ('countedRefs') on the cell's drop. Acquire-on-entry to
-- the cell and release-on-drop are the matched pair; the body-seed is a SEPARATE
-- matched pair (incref here, body last-use drop) that covers only body-owned
-- 'RVBox' captures.
closureOwnedBoxed :: Node -> [Addr]
closureOwnedBoxed (NClosure env _ _ OwnCaptures) =
  [ a | RVBox a <- Map.elems env, not (isUncounted a) ]
closureOwnedBoxed (NClosure _ _ _ BorrowCaptures) = []
closureOwnedBoxed _ = []

-- | Dereference an address. Errors ('throwE') if an abstract address has been
-- freed (use-after-free) or was never allocated (dangling pointer). A 'CAddr'
-- reconstructs an @NCon Text [RCValue]@ by reading the C cell's tag, arity, and
-- slots (the @rc@ field is set to 0 because readers never consult it for a C
-- cell --- its real count lives in the C runtime). The interpreter monad form;
-- 'derefPure' is the abstract-heap pure core used by the store-aware renderers
-- and the store-algebra unit tests.
deref :: Addr -> Store -> RC Cell
deref (CAddr p)    s = liftIO (readCCell p s)
deref a@(HAddr _)  s = liftRC (derefPure a s)
deref (Inline tid) s = pure (Cell 0 (NCon (tagName tid s) []))

-- | Reconstruct the 'Cell' of a C-heap 'NCon' from its tag/arity/slots. Shared
-- by 'deref' and the C-cell free cascade in 'dropAddr'.
--
-- THE @cRc@ FIELD IS A MEANINGLESS PLACEHOLDER (always 0) for a C cell: the real
-- reference count lives in the C runtime (the @rc@ word of the @WokObj@). NO
-- reader may consult the @cRc@ of a 'CAddr'-derived 'Cell' --- it would read the
-- fixed 0, not the true count. The abstract-only consumers that DO read @cRc@
-- ('moveOutContPure', 'increfPure', 'dropAddrStepPure') all reject a 'CAddr'
-- BEFORE reaching the @cRc@ read, so the placeholder is never observed.
readCCell :: Ptr WokObj -> Store -> IO Cell
readCCell p s = do
  tid <- H.wokTag p
  vs  <- readCConValues p s
  pure (Cell 0 (NCon (tagName tid s) vs))

-- | Decode a C cell's slots back to @[RCValue]@ via its per-constructor
-- descriptor --- the single @tag -> kinds -> decode@ path shared by 'readCCell'
-- and the 'dropAddr' free cascade. The descriptor length equals the cell's arity
-- by construction ('allocNCon' records exactly the cell's kinds and routes any
-- kind/arity mismatch to the abstract heap), so a length disagreement is an
-- invariant violation and fails loudly rather than silently truncating the list
-- --- in the cascade a silent truncation would drop counted children (an RC leak).
readCConValues :: Ptr WokObj -> Store -> IO [RCValue]
readCConValues p s = do
  tid <- H.wokTag p
  ws  <- readCWords p
  let kinds = IM.findWithDefault (error "readCConValues: no descriptor for tag")
                                 (fromIntegral tid) (stConDesc s)
  if length kinds == length ws
    then pure (zipWith decodeSlotC kinds ws)
    else error ("readCConValues: descriptor arity " <> show (length kinds)
                  <> " /= cell arity " <> show (length ws) <> " for tag " <> show tid)

-- | Read every raw slot word of a C cell. Uses an explicit @take@ over the arity
-- rather than @[0 .. ar - 1]@: 'wokArity' is a 'Word32', so a nullary constructor
-- (@ar == 0@) would make @ar - 1@ underflow to 'maxBound' and enumerate four
-- billion slots --- a hang. @take 0@ is correctly empty.
readCWords :: Ptr WokObj -> IO [Word64]
readCWords p = do
  ar <- H.wokArity p
  mapM (H.wokSlotGet p) (take (fromIntegral ar) [0 ..])

-- | The pure core of 'deref' over the ABSTRACT heap. A 'CAddr' is reconstructed
-- by the IO 'deref' wrapper (the C runtime is read in 'IO'); reaching this pure
-- core with a 'CAddr' is an internal routing error. An 'Inline' immediate is
-- synthesized to its nullary 'NCon' here directly --- 'tagName' is pure, so
-- reading an immediate's value is a meaningful pure operation (like the no-op
-- 'increfPure'/'dropAddrStepPure' on an 'Inline'), and the IO 'deref' produces
-- the identical cell. This is why the renderers need no inline special-case.
derefPure :: Addr -> Store -> Either RuntimeError Cell
derefPure (CAddr _)   _ = Left (PrimError (Tx.pack "deref: C-heap address has no pure reconstruction"))
derefPure (Inline tid) s = Right (Cell 0 (NCon (tagName tid s) []))
derefPure (HAddr i)  s
  | IS.member i (stDead s) =
      Left (PrimError (Tx.pack ("use-after-free: addr " <> show i)))
  | otherwise =
      case IM.lookup i (stCells s) of
        Just c  -> Right c
        Nothing -> Left (PrimError (Tx.pack ("dangling addr " <> show i)))

-- ---------------------------------------------------------------------------
-- Reference-count operations

-- | Increment the reference count of a live cell. Errors ('throwE') if an
-- abstract address is dead or dangling. A NO-OP on static (negative) abstract
-- addresses: immortal cells are uncounted, so dup/drop of a global handle is
-- inert. A 'CAddr' increfs directly in the C runtime (@wok_dup@), leaving the
-- store unchanged. The interpreter monad form; 'increfPure' is the abstract-heap
-- pure core.
incref :: Addr -> Store -> RC Store
incref (CAddr p)   s = liftIO (H.wokDup p) >> pure s
incref a@(HAddr _) s = liftRC (increfPure a s)
incref (Inline _)  s = pure s

-- | The pure core of 'incref' over the ABSTRACT heap. A 'CAddr' is increfed by
-- the IO 'incref' wrapper (a direct @wok_dup@); reaching this pure core with one
-- is an internal routing error.
increfPure :: Addr -> Store -> Either RuntimeError Store
increfPure (CAddr _)  _ = Left (PrimError (Tx.pack "incref: C-heap address has no pure incref"))
increfPure (Inline _) s = Right s
increfPure a@(HAddr i) s
  | isStaticAddr a = Right s
  | otherwise = do
      c <- derefPure a s
      Right s { stCells = IM.insert i c { cRc = cRc c + 1 } (stCells s) }

-- | Decrement the reference count of a cell. When the count reaches zero the
-- cell is freed and its boxed children are recursively decremented.
--
-- The traversal is ITERATIVE (worklist), not host-recursive, so arbitrarily
-- deep structures do not cause a stack overflow. The worklist genuinely MIXES
-- 'Addr' kinds: a C cell can hold an 'HAddr' child and an abstract cell can hold
-- a 'CAddr' child (cross-heap edges), so the RC monad owns the loop and
-- dispatches each address by its kind --- 'HAddr' through the pure one-step
-- helper 'dropAddrStepPure' (which preserves the exact abstract dec/free/stats/
-- 'stDead'/cascade semantics), 'CAddr' through the C runtime (@wok_dec@, then on
-- reaching zero, decode its slots for the cascade children and @wok_free@). A
-- freed C cell's children are found by the SAME 'countedRefs' the abstract path
-- uses, so cross-heap edges route themselves.
dropAddr :: Addr -> Store -> RC Store
dropAddr a0 s0 = go [a0] s0
  where
    go [] s = pure s
    go (Inline _ : rest) s = go rest s
    go (CAddr p : rest) s = do
      newrc <- liftIO (H.wokDec p)
      if newrc /= 0
        then go rest s
        else do
          -- About to free: decode the children for the cascade BEFORE freeing,
          -- then return the C cell to the runtime. The children are an ordinary
          -- 'countedRefs' set (CAddr + non-static HAddr), routed by 'go'.
          --
          -- WHY 'countedRefs' HERE IS THE CORRECT CASCADE (and 'cascadeChildren' is
          -- not needed). A 'CAddr' is ALWAYS an 'NCon' ('allocNCon' is the only
          -- 'CAddr' producer), and for an 'NCon',
          --   cascadeChildren (NCon _ vs) == countedRefs (nodeValues (NCon _ vs))
          --                               == countedRefs vs,
          -- so 'countedRefs' over the decoded slots IS the cascade for the only
          -- C-eligible node. The special routing 'cascadeChildren' adds (the 'NCont'
          -- owned-set path) never applies to a 'CAddr'. If some OTHER node kind ever
          -- becomes C-eligible AND needs that special routing, this branch must be
          -- revisited to call 'cascadeChildren' on a reconstructed node instead.
          kids <- countedRefs <$> liftIO (readCConValues p s)
          hp <- heapPtr s
          liftIO (H.wokFree hp p)
          go (kids ++ rest) (bumpFreeStats s)
    go (a@(HAddr _) : rest) s = do
      (mkids, s') <- liftRC (dropAddrStepPure a s)
      case mkids of
        Nothing   -> go rest s'         -- just decremented (rc > 1) or static no-op
        Just kids -> go (kids ++ rest) s'

-- | The C-heap free-stats bump, mirroring the abstract path's free accounting in
-- 'dropAddrStepPure' (frees + 1, live - 1). The C runtime keeps its own
-- independent stat counters; this keeps the store-level 'Stats' identical to the
-- abstract path so the differential oracle can diff abstract-vs-C totals.
bumpFreeStats :: Store -> Store
bumpFreeStats s = s { stStats = recordFree (stStats s) }

-- | Extract the live C heap context from the store, or fail if the backend is
-- 'AbstractHeap'. A 'CAddr' can only have been produced under a 'CHeap' backend,
-- so reaching here with 'AbstractHeap' is an internal invariant break.
heapPtr :: Store -> RC (Ptr WokHeap)
heapPtr s = case stBackend s of
  CHeap hp     -> pure hp
  AbstractHeap -> liftRC (Left (PrimError (Tx.pack "internal: CAddr freed under AbstractHeap backend")))

-- | One step of the abstract-heap drop worklist. Given a single 'HAddr',
-- returns @Nothing@ if it only decremented (rc > 1) or was a static no-op, or
-- @Just kids@ if it freed the cell and these are its cascade children (which may
-- include 'CAddr's, e.g. an abstract cell holding a C child). Preserves the
-- exact dec/free/stats/'stDead'/cascade semantics of the original
-- 'dropAddrPure'; the unified 'dropAddr' loop and the pure 'dropAddrPure' loop
-- both drive it.
dropAddrStepPure :: Addr -> Store -> Either RuntimeError (Maybe [Addr], Store)
dropAddrStepPure (CAddr _)   _ = Left (PrimError (Tx.pack "dropAddrStepPure: C-heap address is not an abstract step"))
dropAddrStepPure (Inline _)  s = Right (Nothing, s)
dropAddrStepPure a@(HAddr i) s
  -- Static (immortal) cells are uncounted: a drop of a global handle, or of a
  -- dynamic field that points at a global, is inert. Skip it (no cascade).
  | isStaticAddr a = Right (Nothing, s)
  | IS.member i (stDead s) =
      Left (PrimError (Tx.pack ("double-free: addr " <> show i)))
  | otherwise =
      case IM.lookup i (stCells s) of
        Nothing -> Left (PrimError (Tx.pack ("drop of dangling addr " <> show i)))
        Just c
          | cRc c <= 1 ->  -- rc about to reach 0 -> free
              let kids = cascadeChildren (cNode c)
                  s'   = s { stCells = IM.delete i (stCells s)
                           , stDead  = IS.insert i (stDead s)
                           , stStats = recordFree (stStats s) }
              in Right (Just kids, s')
          | otherwise ->
              Right (Nothing, s { stCells = IM.insert i c { cRc = cRc c - 1 } (stCells s) })

-- | The pure core of 'dropAddr' for an ALL-'HAddr' worklist (no C-heap children
-- reachable). Drives 'dropAddrStepPure' in a pure loop. Used by the store-algebra
-- unit tests, which run on the abstract heap exclusively. A 'CAddr' encountered
-- here (only possible if an abstract cell held a C child, which never arises in
-- the pure-test fragment) is an internal error.
dropAddrPure :: Addr -> Store -> Either RuntimeError Store
dropAddrPure a0 s0 = go [a0] s0
  where
    go [] s = Right s
    go (a : rest) s = do
      (mkids, s') <- dropAddrStepPure a s
      case mkids of
        Nothing   -> go rest s'
        Just kids -> go (kids ++ rest) s'

-- | Flatten all 'RCValue' fields of a 'Node' into a list. The drop cascade
-- ('dropAddr') and the capture-incref ('closureOwnedBoxed') both route through
-- 'countedRefs' over these values, so the static-skip is applied identically on
-- release and acquire --- no container-kind special cases and no borrowed-set.
nodeValues :: Node -> [RCValue]
nodeValues (NCon _ vs)          = vs
nodeValues (NRecord _ m)        = Map.elems m
nodeValues (NClosure env _ _ _) = Map.elems env
nodeValues (NGroupCode _)       = []
nodeValues (NEnv m)             = Map.elems m
-- An 'NCont's free does NOT cascade through 'nodeValues' --- see 'cascadeChildren'.
nodeValues (NCont _ _)          = []
-- The held continuation is an ordinary counted child of the cell (one 'RVBox');
-- an empty cell has none. 'cascadeChildren' falls through to the generic
-- 'countedRefs . nodeValues' default, so the cell's drop cascades to it once.
nodeValues (NContCell mb)       = [ RVBox a | Just a <- [mb] ]

-- | The addresses to free when a node's cell is freed (the single free path,
-- consumed by 'dropAddr'). For every node EXCEPT 'NCont' this is the counted refs
-- of its 'nodeValues' (the generic cascade). For 'NCont' it is the continuation's
-- OWNED SET ('continuationOwned'), NOT a blind cascade of every captured-scope
-- value: that would double-free borrowed/moved/global bindings (spec §4.2). So
-- @__rc_drop resume@ on an aborting continuation frees its owned set then the shell
-- --- one place, the single free path.
cascadeChildren :: Node -> [Addr]
cascadeChildren (NCont prefix _) = continuationOwned prefix
cascadeChildren other            = countedRefs (nodeValues other)

-- ---------------------------------------------------------------------------
-- FBIP in-place reuse (spec §4.2, §4.3): drop_reuse / alloc_at on the abstract
-- heap. The counted analogue of the last step of 'dropAddr', minus the shell
-- free: release a dying cell's children but RETAIN its shell as a reuse token,
-- then either revive that shell at the next same-shaped allocation (0 alloc / 0
-- free) or free it for real and allocate fresh.

-- | Release a cell's children but RETAIN its shell as a reuse token (spec §4.2).
-- The counted analogue of 'dropAddr's free branch with the shell free removed:
--
--   * 'Inline' / static 'HAddr' (uncounted): never a donor --- a decrement is a
--     no-op on an uncounted address, exactly as today --- so '(RVReuse Nothing, s)'.
--   * dynamic 'HAddr i', @rc > 1@: decrement in place (NO 'recordFree', mirroring
--     'dropAddrStepPure's decrement branch), return '(RVReuse Nothing, s')'.
--   * dynamic 'HAddr i', @rc == 1@ (unique, 'NCon' only for now): compute the
--     arity, the C-eligibility bit ('nodeCEligible'), and the cascade children
--     ('cascadeChildren'); REMOVE @i@ from 'stCells' WITHOUT adding it to 'stDead'
--     and WITHOUT 'recordFree' (the shell is reserved, still counted in 'stLive');
--     drop every child via the existing 'dropAddr' worklist; return the token.
--
-- ORDERING (the M2b/M3 discipline, spec §4.2): collect children -> reserve the
-- shell (remove from 'stCells', skip the free) -> process the children. The shell
-- is held by the token; its bytes stay intact until 'allocAt'.
--
-- A 'CAddr' donor mirrors 'dropAddr's free branch MINUS the 'wokFree' and the
-- 'bumpFreeStats': @wok_dec@; if the new rc /= 0 the cell is still shared -> NULL
-- token; if it hits 0 the cell is unique, so decode the children (the same
-- 'countedRefs'-over-decoded-slots cascade 'dropAddr' uses --- a 'CAddr' is always
-- an 'NCon'), retain the shell as the token WITHOUT returning it to the runtime
-- (no free list push, no stat bump), then drop the children via the worklist. A
-- live 'CAddr' was C-eligible by construction, so @rsCEligible = True@.
dropReuse :: Addr -> Store -> RC (RCValue, Store)
dropReuse (Inline _) s = pure (RVReuse Nothing, s)              -- uncounted: never a donor
dropReuse (CAddr p)  s = do
  newrc <- liftIO (H.wokDec p)
  if newrc /= 0
    then pure (RVReuse Nothing, s)                             -- shared: NULL token
    else do
      arity <- liftIO (H.wokArity p)
      kids  <- countedRefs <$> liftIO (readCConValues p s)     -- decode children BEFORE reserving
      -- reserve the shell: do NOT wokFree, do NOT bumpFreeStats.
      s'    <- foldM (flip dropAddr) s kids
      pure (RVReuse (Just (ReuseSlot (CAddr p) arity True)), s')
dropReuse a@(HAddr i) s
  | isStaticAddr a = pure (RVReuse Nothing, s)                  -- uncounted: never a donor
  | otherwise = do
      c <- liftRC (derefPure a s)
      if cRc c <= 1
        then do
          -- unique: reserve the shell, then cascade the children (collect-before-free).
          let node  = cNode c
              arity = nodeArity node
              elig  = nodeCEligible node
              kids  = cascadeChildren node
              s'    = s { stCells = IM.delete i (stCells s) }
          s'' <- foldM (flip dropAddr) s' kids
          pure (RVReuse (Just (ReuseSlot (HAddr i) arity elig)), s'')
        else
          -- shared: decrement in place, NO recordFree, NULL token.
          let s' = s { stCells = IM.insert i c { cRc = cRc c - 1 } (stCells s) }
          in pure (RVReuse Nothing, s')

-- | Consume a reuse token, writing the new node into the reserved shell when its
-- placement matches, else freeing the shell and allocating fresh (spec §4.3).
--
--   * 'RVReuse Nothing' (NULL): 'alloc' fresh (the existing chokepoint; normal
--     'recordAlloc'). The shared-cell / uncounted-donor path.
--   * 'RVReuse (Just (ReuseSlot a ar oldElig))': reuse-eligible iff
--     @nodeArity newNode == ar && nodeCEligible newNode == oldElig@ (both backends
--     compute this from the same value-only data -> identical decision).
--       - eligible, @a == HAddr i@: write @Cell 1 newNode@ at @i@, NO 'recordAlloc',
--         'stNext' untouched; return @(HAddr i, s')@. 0 alloc / 0 free.
--       - eligible, @a == CAddr p@: re-stamp the shell in place ('reuseCConAt':
--         @wok_alloc_at@ + per-slot @wok_slot_set@, mirroring 'allocNCon's
--         'doAlloc' minus the alloc and minus 'recordAlloc'); return @(CAddr p, s')@.
--         0 alloc / 0 free.
--       - NOT eligible, @a == HAddr i@: free @i@ for real ('stDead' + 'recordFree'),
--         then 'alloc' fresh. +1 alloc / +1 free.
--       - NOT eligible, @a == CAddr p@: 'wokFree' + 'bumpFreeStats', then 'alloc'
--         fresh. +1 alloc / +1 free. (Only an integer-width flip --- an encodable
--         input crossing @>= 2^63@ --- reaches this on a 'CAddr', spec §4.3.)
--
-- A non-'RVReuse' first argument is an internal error (loud 'Left').
allocAt :: RCValue -> Node -> Store -> RC (Addr, Store)
allocAt (RVReuse Nothing)               newNode s = alloc newNode s
allocAt (RVReuse (Just (ReuseSlot a ar oldElig))) newNode s = case a of
  HAddr i
    | nodeArity newNode == ar && nodeCEligible newNode == oldElig ->
        pure (HAddr i, s { stCells = IM.insert i (Cell 1 newNode) (stCells s) })
    | otherwise ->
        alloc newNode (s { stDead  = IS.insert i (stDead s)
                         , stStats = recordFree (stStats s) })
  CAddr p
    | nodeArity newNode == ar && nodeCEligible newNode == oldElig ->
        reuseCConAt p newNode s
    | otherwise -> do
        hp <- heapPtr s
        liftIO (H.wokFree hp p)
        alloc newNode (bumpFreeStats s)
  Inline _ -> liftRC (Left (PrimError (Tx.pack "alloc_at: reuse token shell is an inline immediate")))
allocAt v _ _ =
  liftRC (Left (PrimError (Tx.pack ("alloc_at: expected a reuse token, got " <> show v))))

-- | Re-stamp a reserved C shell in place with a new 'NCon' (FBIP, spec §4.3). The
-- exact 'allocNCon' 'CHeap' 'doAlloc' path MINUS the 'wokAlloc' (replaced by
-- 'wokAllocAt' on the donor pointer) and MINUS 'recordAlloc' (a reused cell records
-- no allocation). The caller has already established reuse-eligibility
-- (@nodeArity == rsArity && nodeCEligible == True@), so every field encodes; the
-- descriptor handling mirrors 'allocNCon' faithfully (intern, first-kind-wins). By
-- the pairing post-pass's static slot-kind guard (spec §6.3) the new node shares the
-- old cell's slot-kind signature, so the tag-keyed descriptor stays valid on a
-- cross-constructor re-stamp; recording it here keeps this path self-contained when
-- exercised directly (the standalone C test / Task 5 corpus) rather than only after
-- an 'allocNCon' of the same tag.
reuseCConAt :: Ptr WokObj -> Node -> Store -> RC (Addr, Store)
reuseCConAt p (NCon con vs) s = do
  hp <- heapPtr s
  case traverse encodeSlotC vs of
    Nothing -> liftRC (Left (PrimError (Tx.pack "reuseCConAt: reuse-eligible node failed to encode")))
    Just encoded -> do
      let (tid, s1) = internTag con s
          newKinds  = map fst encoded
      -- DEFENSIVE DESCRIPTOR CHECK (review finding). 'allocNCon' falls BACK to the
      -- abstract heap on a descriptor mismatch (first-kind-wins for a nominal /
      -- polymorphic constructor); 'reuseCConAt' instead re-stamps the EXISTING C
      -- shell, so a stale tag-keyed descriptor would silently MIS-DECODE the payload
      -- on readback. The F1 same-constructor restriction + the §6.3 static slot-kind
      -- guard make a mismatch UNREACHABLE here (the matched and target constructors
      -- share a signature, so the new kinds equal the recorded ones). Rather than a
      -- silent fallback, this is a LOUD tripwire (the repo's loud-on-violation
      -- convention): should a future relaxation (cross-constructor reuse) break the
      -- invariant, it fails clearly instead of mis-decoding. The matching path is
      -- behaviourally identical to before.
      case IM.lookup (fromIntegral tid) (stConDesc s1) of
        Just existing
          | existing /= newKinds ->
              liftRC (Left (PrimError (Tx.pack
                "reuseCConAt: descriptor mismatch (cross-constructor reuse must be unreachable)")))
        _ -> pure ()
      let s2 = case IM.lookup (fromIntegral tid) (stConDesc s1) of
                 Just _  -> s1   -- known tag: descriptor already recorded (and verified equal above)
                 Nothing -> s1 { stConDesc = IM.insert (fromIntegral tid) newKinds (stConDesc s1) }
      _ <- liftIO (H.wokAllocAt hp tid (fromIntegral (length vs)) p)
      liftIO $ mapM_ (\(i, (_, w)) -> H.wokSlotSet p (fromIntegral i) w)
                     (zip [0 :: Int ..] encoded)
      pure (CAddr p, s2)
reuseCConAt _ n _ =
  liftRC (Left (PrimError (Tx.pack ("reuseCConAt: expected an NCon, got " <> show n))))

-- ---------------------------------------------------------------------------
-- Primitives
--
-- The RC analogue of 'Wok.Interp.Value.Prim'. The crucial difference is that
-- 'rpFn' THREADS THE STORE: the saturated implementation reads and writes the
-- owned heap, returning the updated 'Store'. This is how @__rc_dup@/@__rc_drop@
-- reach the heap without a separate 'PRStore' constructor (the store is folded
-- into the result tuple instead, which is simpler than the reference's
-- 'PRDrive' seam).

-- | A primitive: name (= hint), arity, args accumulated so far (for currying),
-- and the store-threading saturated implementation.
data RCPrim = RCPrim
  { rpName  :: Text
  , rpArity :: Int
  , rpArgs  :: [RCValue]
  , rpFn    :: [RCValue] -> Store -> RC (RCPrimResult, Store)
  }

-- | A saturated primitive either produces a value or asks the machine to apply
-- one value to others (how @($)@ is expressed without host recursion). There is
-- no @PRDrive@ analogue: the no-handler fragment has no scheduler.
data RCPrimResult = PRDone RCValue | PRApply RCValue [RCValue]

-- | Primitive lookup table, keyed by the bodyless global's hint text.
type RCPrimTable = Map Text RCPrim

-- ---------------------------------------------------------------------------
-- Atom resolution and binder helpers

-- | Resolve an atom: literal -> value; variable -> env by 'Unique', else
-- 'UnboundVar'.
--
-- Unlike the reference 'Wok.Interp.Value.resolveAtom', this does NOT fall back
-- to the prim table: 'RCValue' has only 'RVLit'/'RVBox', so a primitive cannot
-- be a stored value. Primitive NAMES are resolved at the application head (see
-- @callFn@ in "Wok.Interp.RC.Machine"), which consults the prim table directly.
-- In the M1 no-handler first-order corpus a bare prim name never appears in an
-- operand/scrutinee/field position, so reaching the 'UnboundVar' fallthrough for
-- those positions signals a genuinely unbound variable.
resolveRCAtom :: RCScope -> Atom -> Either RuntimeError RCValue
resolveRCAtom _  (ALit l) = Right (RVLit l)
resolveRCAtom _  (APrim (_, name)) = Left (UnboundPrim name)  -- bare prim-as-value unsupported in RC M1
resolveRCAtom sc (AVar n) =
  case Map.lookup (nameUniq n) (rscEnv sc) of
    Just v  -> Right v
    Nothing -> Left (UnboundVar (nameHint n))

bindRCBinder :: Binder -> RCValue -> REnv -> REnv
bindRCBinder b v = Map.insert (nameUniq (bndName b)) v

bindRCBinders :: [Binder] -> [RCValue] -> REnv -> REnv
bindRCBinders bs vs env = foldl' (\e (b, v) -> bindRCBinder b v e) env (zip bs vs)

-- ---------------------------------------------------------------------------
-- Rendering (store-aware)
--
-- Derefs handles so the rendered text reproduces 'Wok.Interp.Value.renderValue'
-- EXACTLY (required for the differential oracle). A dangling/dead handle
-- surfaces as a 'Left' rather than silently rendering garbage.

-- | Render a value, threading a deref action so the same logic serves both the
-- pure abstract path ('derefPure', @Either RuntimeError@) and the IO C-aware path
-- ('deref', 'RC'). The two public renderers below are thin instantiations of this
-- one; keeping a single body means the abstract and C-backed outputs cannot drift
-- (the @rc-c-backend-parity@ output assertions would catch any divergence).
renderValueWith :: Monad m => (Addr -> Store -> m Cell) -> Store -> RCValue -> m Text
renderValueWith drf = goVal
  where
    goVal _ (RVLit l)              = pure (renderLit l)
    -- 'RVBox a' covers an 'Inline' immediate too: both 'deref' and 'derefPure'
    -- synthesize its nullary 'NCon', so no inline special-case is needed.
    goVal s (RVBox a)              = do
      c <- drf a s
      goNode s (cNode c)
    goVal _ RVRecMember{}          = pure (Tx.pack "<closure>")
    goVal _ (RVInst _ _)           = pure (Tx.pack "<instance>")
    goVal _ (RVReuse _)            = pure (Tx.pack "<reuse-token>")

    goNode _ (NCon t []) | t == Tx.pack "Nil" = pure (Tx.pack "[]")
    goNode s (NCon t [h, tl]) | t == Tx.pack "Cons" = goList s h tl
    goNode s (NCon tag vs)
      | Just n <- tupleArity tag, length vs == n = do
          parts <- mapM (goVal s) vs
          pure (Tx.pack "(" <> Tx.intercalate (Tx.pack ", ") parts <> Tx.pack ")")
    goNode _ (NCon c []) = pure c
    goNode s (NCon c vs) = do
      parts <- mapM (goVal s) vs
      pure (c <> Tx.pack "(" <> Tx.intercalate (Tx.pack ", ") parts <> Tx.pack ")")
    goNode s (NRecord t m) = do
      parts <- mapM (\(l, fv) -> do tv <- goVal s fv
                                    pure (l <> Tx.pack " = " <> tv)) (Map.toList m)
      pure (t <> Tx.pack " { " <> Tx.intercalate (Tx.pack ", ") parts <> Tx.pack " }")
    goNode _ NClosure{}      = pure (Tx.pack "<closure>")
    goNode _ (NGroupCode _)  = pure (Tx.pack "<closure>")
    goNode _ (NEnv _)        = pure (Tx.pack "<env>")
    goNode _ (NCont _ _)     = pure (Tx.pack "<continuation>")
    goNode _ (NContCell _)   = pure (Tx.pack "<cont-cell>")

    -- Render a proper Cons/Nil list as @[a, b, c]@. An improper tail renders the
    -- remainder after a @|@ so malformed lists are still total and visible.
    goList s h0 tl0 = do
      hd <- goVal s h0
      spine [hd] tl0
      where
        spine acc v = case v of
          -- 'RVBox a' covers the 'Inline' Nil terminator: 'drf' synthesizes its
          -- 'NCon "Nil" []', which the @t == "Nil"@ guard below closes the list on.
          RVBox a -> do
            c <- drf a s
            case cNode c of
              NCon t [] | t == Tx.pack "Nil" ->
                pure (Tx.pack "[" <> Tx.intercalate (Tx.pack ", ") (reverse acc) <> Tx.pack "]")
              NCon t [h, tl] | t == Tx.pack "Cons" -> do
                hd <- goVal s h
                spine (hd : acc) tl
              _ -> improper acc v
          RVLit _       -> improper acc v
          RVRecMember{} -> improper acc v
          RVInst _ _    -> improper acc v
          RVReuse _     -> improper acc v
        improper acc v = do
          rest <- goVal s v
          pure (Tx.pack "[" <> Tx.intercalate (Tx.pack ", ") (reverse acc)
                   <> Tx.pack " | " <> rest <> Tx.pack "]")

-- | Render a value over the ABSTRACT heap (pure, @Either RuntimeError@). Retained
-- with this exact type for the store-algebra unit tests, which run on the abstract
-- heap exclusively.
renderRCValue :: Store -> RCValue -> Either RuntimeError Text
renderRCValue = renderValueWith derefPure

-- | Render a value in the interpreter monad, using the IO 'deref' so it can
-- reconstruct a 'CAddr' (C-heap) cell. 'runModuleRC' uses this so a C-backed run
-- renders byte-identical output to the abstract run.
renderRCValueRC :: Store -> RCValue -> RC Text
renderRCValueRC = renderValueWith deref

renderLit :: Lit -> Text
renderLit (LInt n)  = Tx.pack (show n)
renderLit (LStr str) = Tx.pack (show str)
renderLit (LChar c) = Tx.pack (show c)
renderLit LUnit     = Tx.pack "()"

-- | If the tag is @TupleN@, return N.
tupleArity :: Text -> Maybe Int
tupleArity t = case Tx.stripPrefix (Tx.pack "Tuple") t of
  Just rest | not (Tx.null rest), Tx.all (`elem` ['0' .. '9']) rest -> Just (read (Tx.unpack rest))
  _ -> Nothing
