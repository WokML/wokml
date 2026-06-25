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
  , continuationReservations
  , freeReservation
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
  , wouldBeCBytes
  , dropReuse
  , allocStatic
  , writeStatic
  , writeNode
  , writeNodePure
  , isStaticAddr
  , isInline
  , isUncounted
  , isArenaAddr
    -- * Uncounted arena tier (Region Slice R1)
  , arenaOpen
  , arenaOpenRC
  , arenaAllocPure
  , arenaAlloc
  , arenaClose
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
  , resolveRCAtomAlloc
  , bindRCBinder
  , bindRCBinders
    -- * Rendering
  , renderRCValue
  , renderRCValueRC
    -- * Slot encoding (C-heap NCon field packing)
  , SlotKind (..)
  , encodeSlotC
  , decodeSlotC
    -- * Array C-cell support
  , wokArrayTag
  , slotKindToElemKind
  , elemKindToSlotKind
    -- * String C-cell support
  , wokStringTag
    -- * Array in-place mutation helpers (Slice C)
  , atIndex
  , setAt
  , arrayLenOf
  , arrayUnique
  , arraySetSlotInPlace
  ) where

import Control.Monad (foldM)
import Control.Monad.IO.Class (liftIO)
import Control.Monad.Trans.Except (ExceptT, except)
import Data.Bits (shiftL, shiftR, toIntegralSized, (.&.), (.|.))
import qualified Data.ByteString as BS
import Data.ByteString (ByteString)
import qualified Data.Text.Encoding as TxEnc
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
import Data.Word (Word8, Word32, Word64)
import Foreign.Marshal.Utils (copyBytes)
import Foreign.Ptr (Ptr, castPtr, ptrToWordPtr, wordPtrToPtr, WordPtr (..))
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
  , rsBytes     :: Int      -- ^ bytes charged to 'stCurBytes' at the original alloc
                            --   (the 'cBytes' of the reserved cell, preserved here so
                            --   'allocAt' can restore it in the revived cell and
                            --   'freeReservation' can balance 'recordFree' correctly)
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
  | KArenaCloseRC RCKont
    -- ^ The PER-ACTIVATION ARENA BRACKET (Region Slice R1, spec §4.2). Pushed ABOVE
    -- a function/CAF/lambda body's continuation when that body opens an arena
    -- ('arenaOpen' fired on entry, see 'Wok.Interp.RC.Machine'). When the body's
    -- final value returns into this frame, it runs 'arenaClose' (the scan-out +
    -- O(1) bulk reset) and threads the value onward to the saved continuation. The
    -- frame fires on EVERY exit path of the body STRUCTURALLY --- normal return, a
    -- tail call (the close runs after the callee returns, which is sound because an
    -- arena-local is never a CONSUMING call argument, only borrowed), and a 'Jump'
    -- out of a body-local join (whose saved continuation includes this frame). It
    -- is DEPTH-INVISIBLE ('kontDepth' does not count it) so it never perturbs a
    -- named handler's activation tag.
    --
    -- SOUNDNESS / CAPTURE-FREEDOM. This frame can NEVER appear inside a captured
    -- continuation prefix (an 'NCont'): arena-opening bodies are continuation-free
    -- (the §5.3 fence), and the only fragment that reaches 'runModuleRC' is
    -- handler-/effect-op-free ('firstOrderNoHandlerViolations'), so no
    -- continuation is ever reified in a run that opens an arena. The pass-through
    -- cases in 'continuationOwned'/'continuationReservations'/'spliceKont'/
    -- 'rcFindHandler' are therefore TOTALITY cases, never exercised by an
    -- arena-opening run.
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
    -- The arena bracket is DEPTH-INVISIBLE: it is bookkeeping, not a real
    -- continuation frame, so it must not shift a named handler's activation tag.
    go n (KArenaCloseRC k)   = go n k

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
    -- The arena bracket owns no continuation values (totality only; an
    -- arena-opening body is never reified into a captured prefix).
    go (KArenaCloseRC k)      = go k
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

-- | The IN-FLIGHT FBIP RESERVATIONS trapped in a captured continuation prefix
-- (FBIP effect-safety, spec §3.2). The sibling of 'continuationOwned': it walks
-- the SAME frames, but instead of resolving owned bindings it scans every runtime
-- value the frames carry for a live reuse token whose reserved shell has not yet
-- been consumed.
--
-- For each frame, every value in scope is examined: an 'RVReuse (Just (ReuseSlot
-- a _ _))' contributes @a@ IFF @a@ is still in the supplied 'stReserved' set. That
-- membership test is the IN-FLIGHT FILTER (spec §3.1, §4): a SPENT token (its
-- 'allocAt' already ran, so 'allocAt' deleted @a@ from 'stReserved') still has its
-- 'RVReuse (Just …)' value lingering in the env, but its shell is now LIVE
-- (revived) or already freed --- freeing it would corrupt the heap. The filter
-- excludes exactly those.
--
-- DEDUP. A token live across several frames (e.g. captured in several scopes)
-- yields its address from each; the result is deduped by address so the shell is
-- reclaimed exactly once.
--
-- WHERE THE VALUES LIVE. 'KLetRC' and 'KHandleRC' carry an 'RCScope' (the values
-- are 'rscEnv'); 'KAppRC' carries a list of over-application argument values. A
-- reuse token reaches a captured prefix as one of those values. 'KDropCellRC'
-- carries only a bare 'Addr' (a closure cell to drop), never a value, so it holds
-- no token. 'KDoneRC' is the terminator.
--
-- This is a VALUE-DIRECTED scan --- simpler than 'continuationOwned's body
-- analysis (no 'nonHeadOccs'/'dropTargets'/'freeVarsExpr'), because a reservation
-- is identified by its value shape, not by a Perceus move/drop position. It runs
-- ONLY on abort (an 'NCont' drop).
continuationReservations :: RCKont -> Set.Set Addr -> [(Addr, Int)]
continuationReservations k0 reserved = dedup (go k0)
  where
    go :: RCKont -> [(Addr, Int)]
    go KDoneRC               = []
    go (KLetRC _ _ sc k)     = fromValues (Map.elems (rscEnv sc)) ++ go k
    go (KAppRC vs k)         = fromValues vs ++ go k
    go (KArenaCloseRC k)     = go k  -- totality only (never reified, see KArenaCloseRC)
    -- PARAM-ONLY, mirroring 'continuationOwned's KHandleRC arm: a nested handler
    -- frame in the captured prefix OWNS only its parameter slot; the rest of its
    -- 'hsc' is the captured ENCLOSING scope (a DIFFERENT continuation's bindings).
    -- Scanning the whole 'rscEnv' here could surface an enclosing/foreign
    -- reservation. An in-flight reservation of THIS continuation is always reached
    -- via its own 'KLetRC' frame (where the donor binding lives), so restricting to
    -- the 'hParam' binder loses nothing AND avoids reclaiming a foreign reservation
    -- (robust against a future ROp-relaxation that lets reservations escape an arm).
    go (KHandleRC h _ sc k)  =
      [ (a, b)
      | Just pb <- [hParam h]
      , Just v  <- [Map.lookup (binderUnique pb) (rscEnv sc)]
      , RVReuse (Just (ReuseSlot a _ _ b)) <- [v]
      , Set.member a reserved ]
      ++ go k
    go (KDropCellRC _ k)     = go k
    fromValues vs = [ (a, b) | RVReuse (Just (ReuseSlot a _ _ b)) <- vs, Set.member a reserved ]
    dedup = goD Set.empty
      where
        goD _ [] = []
        goD seen ((a, b) : rest)
          | Set.member a seen = goD seen rest
          | otherwise         = (a, b) : goD (Set.insert a seen) rest

-- | The SPECIAL-FREE for a reclaimed FBIP reservation (FBIP effect-safety, spec
-- §3.3). Called on each address 'continuationReservations' returns when an
-- 'NCont' is dropped (abort). A reserved shell is OFF-BOOKS --- 'dropReuse' removed
-- it from the live cell map without a 'recordFree' and without returning it to the
-- runtime --- so the generic 'dropAddr' cascade cannot find it; this is its sole
-- free path on the abort branch.
--
--   * 'HAddr i': the shell is absent from 'stCells' (reserved off-books). Mark it
--     dead ('stDead'), 'recordFree' it (it was still counted in 'stLive' while
--     reserved), and drop it from 'stReserved'. DEFENSIVE: if @i@ is ALREADY in
--     'stDead' this is an internal double-reclaim (a reservation freed twice) ---
--     fail loudly rather than silently corrupt the accounting.
--   * 'CAddr p': the C shell's rc is 0 (decremented to 0 by 'dropReuse' but not
--     returned). 'wok_free' it (NO child cascade --- its children were released at
--     'dropReuse'), 'recordFree', drop from 'stReserved'.
--   * 'Inline': an immediate is never reserved (uncounted, never a donor), so this
--     is a no-op for totality.
freeReservation :: (Addr, Int) -> Store -> RC Store
freeReservation (Inline _, _) s = pure s  -- immediate: never reserved (uncounted donor), no-op for totality
freeReservation (a, _) s
  -- UNIFORM double-reclaim guard (applies to BOTH HAddr and CAddr arms): a legit
  -- reclaim always has @a ∈ stReserved@ ('continuationReservations' only yields
  -- in-stReserved addrs), so an address ABSENT from 'stReserved' has already been
  -- consumed/reclaimed --- fail loudly rather than silently corrupt the accounting.
  -- (HAddr alone previously caught this via 'stDead'; CAddr had no analogue.)
  | not (Set.member a (stReserved s)) =
      liftRC (Left (PrimError (Tx.pack
        ("internal: double-reclaim of reservation addr " <> show a
          <> " (not in stReserved)"))))
freeReservation (a@(HAddr i), bytes) s =
  -- Charge the same bytes that were charged at allocation ('rsBytes', forwarded by
  -- 'continuationReservations'). This is 0 for descriptor-mismatch fallbacks and
  -- the full cell cost for genuine C-eligible first-kind NCons allocated on the
  -- abstract heap.
  pure s { stDead     = IS.insert i (stDead s)
         , stStats    = recordFree bytes (stStats s)
         , stReserved = Set.delete a (stReserved s) }
freeReservation (a@(CAddr p), bytes) s = do
  -- Charge the same bytes that were charged at allocation ('rsBytes', forwarded by
  -- 'continuationReservations'). For a C-eligible NCon this is provably 8 + 8*arity
  -- (the wok_alloc layout), and arity is immutable, so using the stored delta
  -- avoids a redundant 'H.wokArity' FFI read while staying behavior-identical.
  hp <- heapPtr s
  liftIO (H.wokFree hp p)
  pure (bumpFreeStats bytes s) { stReserved = Set.delete a (stReserved s) }

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
          -- NCont is abstract-only; cBytes c == 0 (wouldBeCBytes NCont = 0).
          let s' = s { stCells = IM.delete i (stCells s)
                     , stDead  = IS.insert i (stDead s)
                     , stStats = recordFree (cBytes c) (stStats s) }
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
    go (KArenaCloseRC k)      = KArenaCloseRC (go k)  -- totality only (never reified)

-- ---------------------------------------------------------------------------
-- Heap nodes

-- | A heap-allocated node. Each constructor corresponds to one of the
-- storable wok value kinds.
data Node
  = NCon Text [RCValue]
  | NArray [RCValue]
  -- ^ A fixed-size, homogeneous, BOXED array (Array Slice A): a contiguous run of
  -- element slots, each an ordinary counted child. Lives on the abstract 'IntMap'
  -- heap on BOTH backends (it is not an 'NCon', so 'alloc' routes it to 'allocPure'
  -- and it is never C-eligible). The array's length is @length vs@.
  --
  -- RC DISCIPLINE. The cell OWNS one ref to each COUNTED element; uncounted slots
  -- (inline immediates, literals, static handles) contribute nothing. Release
  -- routes through the GENERIC cascade ('cascadeChildren' falls through to
  -- 'countedRefs . nodeValues'), so freeing an array drops each counted element
  -- exactly once -- no special 'NCont'-style routing. 'dup' bumps only the array
  -- cell (elements shared via the cell, identical to 'NCon').
  | NString ByteString
  -- INVARIANT: bytes are always valid UTF-8 (literals via encodeUtf8, append concatenates
  -- valid sequences); strict decodeUtf8 on them cannot throw. E2 slicing must preserve this.
  -- ^ A flat UTF-8 byte buffer (String Slice E1): a 'WokString' C cell on the C
  -- backend, mirrored on the abstract heap. Bytes are opaque: the cell has NO
  -- child refs, so the drop cascade is empty ('nodeValues' returns @[]@, and
  -- 'dropAddr' on the C cell simply calls 'wok_free' with no child iteration).
  -- 'alloc (NString bs)' on 'CHeap' calls 'wokStringAlloc' then memcpys the bytes
  -- in via 'wokStringData'; on 'AbstractHeap' it uses 'allocPure'.
  -- 'nodeCEligible (NString _) = False': the string has its own dedicated alloc
  -- path (not the generic 'NCon' slot encoding).
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

-- | A single heap cell: a reference count, the node payload, and the byte
-- count charged to 'stCurBytes' at allocation time. 'cBytes' mirrors the
-- value passed to 'recordAlloc' so 'dropAddrStepPure' can pass the SAME
-- delta to 'recordFree' — keeping 'stCurBytes' balanced even when a
-- descriptor-mismatch or fallback allocation charged 0 instead of
-- 'wouldBeCBytes'.
data Cell = Cell { cRc :: Int, cNode :: Node, cBytes :: Int }
  deriving (Eq, Show)

-- ---------------------------------------------------------------------------
-- Allocation statistics

-- | Monotonic counters maintained by 'alloc' and (in later tasks) by drop.
data Stats = Stats
  { stAllocs    :: Int   -- ^ total allocations since emptyStore
  , stFrees     :: Int   -- ^ total frees since emptyStore (unused until dup/drop)
  , stLive      :: Int   -- ^ current live-cell count
  , stPeak      :: Int   -- ^ high-water mark of live-cell count
  , stCurBytes  :: Int   -- ^ current live bytes (C cells only; abstract-only nodes = 0)
  , stPeakBytes :: Int   -- ^ high-water mark of live bytes (mirrors C 'peak_bytes')
  , stArenaBytes :: Int  -- ^ current uncounted ARENA bytes (Region Slice R1): a
                         --   SEPARATE set of books from the counted 'stCurBytes'.
                         --   Bumped by 'arenaAllocPure' (by 'wouldBeCBytes'), reduced
                         --   by 'arenaClose'. Arena cells never enter 'stCurBytes'/
                         --   'stLive'/'stPeak', mirroring the C runtime's distinct
                         --   @arena_bytes@ region (spec §3.1, §6).
  , stArenaPeak :: Int   -- ^ high-water mark of 'stArenaBytes' (mirrors C
                         --   @arena_peak@). Never reset by 'arenaClose'.
  }
  deriving (Eq, Show)

-- | Record one allocation: bump total allocs and the live count, raising the
-- high-water peak. The 'Int' is the byte delta from 'wouldBeCBytes' for the
-- node being allocated (0 for abstract-only nodes). The single source of truth
-- for alloc-stat math (shared by the abstract and C heap paths so their totals
-- stay byte-identical).
recordAlloc :: Int -> Stats -> Stats
recordAlloc bytes g =
  let live = stLive g + 1
      cur  = stCurBytes g + bytes
  in g { stAllocs    = stAllocs g + 1
       , stLive      = live
       , stPeak      = max (stPeak g) live
       , stCurBytes  = cur
       , stPeakBytes = max (stPeakBytes g) cur
       }

-- | Record one free: bump total frees and drop the live count. The 'Int' is
-- the byte delta from 'wouldBeCBytes' for the node being freed (0 for
-- abstract-only nodes). Shared by the abstract and C heap free paths.
recordFree :: Int -> Stats -> Stats
recordFree bytes g =
  g { stFrees    = stFrees g + 1
    , stLive     = stLive g - 1
    , stCurBytes = stCurBytes g - bytes
    }

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
  , stReserved   :: Set.Set Addr
    -- ^ addresses currently reserved by a live (in-flight) FBIP reuse token: a
    -- shell whose 'dropReuse' has run but whose paired 'allocAt' has not yet
    -- consumed it (FBIP effect-safety, spec §3.1). 'dropReuse' inserts the
    -- reserved 'rsAddr'; 'allocAt' removes it on every consume path. A spent
    -- token's value may linger in an env, but its address is no longer here ---
    -- which is what keeps the abort-reclaim collector from freeing a revived or
    -- already-freed cell.
  , stArena      :: [IntSet]
    -- ^ the per-activation UNCOUNTED ARENA stack (Region Slice R1, spec §3.2): a
    -- STACK of arena-address sets, head = the innermost open scope. 'arenaOpen'
    -- pushes an empty frame; 'arenaAllocPure' records a fresh 'HAddr' index in the
    -- innermost frame; 'arenaClose' scans out the top frame's counted children then
    -- bulk-removes the frame. An 'HAddr' index present in ANY frame is UNCOUNTED
    -- ('isUncounted'), so dup/drop of it are inert (no cascade) -- bit-for-bit
    -- mirroring the C runtime's distinct arena region.
    --
    -- On the 'CHeap' backend this frame stack still records the NON-C-eligible
    -- arena cells (an arity > 255 or non-encodable arena 'NCon', which falls back
    -- to the abstract arena exactly as 'allocNCon' falls a non-eligible counted
    -- 'NCon' back to the abstract heap). C-eligible arena cells live as 'CAddr's
    -- in 'stArenaC' (below). The two frame stacks are pushed/popped in lockstep by
    -- 'arenaOpen'/'arenaClose' so the depths never diverge.
  , stArenaC     :: [Set.Set (Ptr WokObj)]
    -- ^ the C-arena frame stack (Region Slice R1): the per-scope set of C-eligible
    -- arena cells ('CAddr's allocated by 'wok_arena_alloc'), head = the innermost
    -- open scope. Populated ONLY under the 'CHeap' backend; always empty frames
    -- under 'AbstractHeap'. A 'CAddr' present in ANY frame is an UNCOUNTED arena
    -- cell ('isArenaAddr'), so 'incref'/'dropAddr' on it are inert (no @wok_dup@/
    -- @wok_dec@), exactly mirroring the abstract 'stArena' membership test. The
    -- cell is reclaimed by 'wok_arena_close' (a bulk free of the scope's chain),
    -- not by an rc reaching zero. 'arenaClose' scans out each cell's counted
    -- children (read from its C slots) before the bulk reset, the C analogue of
    -- the abstract scan-out.
  , stArenaHandles :: [Word32]
    -- ^ the stack of handles returned by 'wok_arena_open' (CHeap backend only),
    -- head = the innermost open scope, so 'arenaClose' can pass the matching
    -- handle to 'wok_arena_close' (which asserts @handle == arena_depth - 1@).
    -- Empty under 'AbstractHeap'. Pushed/popped in lockstep with 'stArena'/
    -- 'stArenaC'.
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
  , stStats      = Stats 0 0 0 0 0 0 0 0
  , stBackend    = AbstractHeap
  , stTagFwd     = Map.empty
  , stTagRev     = IM.empty
  , stConDesc    = IM.empty
  , stReserved   = Set.empty
  , stArena      = []
  , stArenaC     = []
  , stArenaHandles = []
  }

-- | Intern a constructor name to its stable tag-id, allocating a fresh id on
-- first sight. Returns the id and the (possibly extended) store. The bijection
-- is monotonic and total over every constructor that has ever been allocated in
-- the C heap, so 'tagName' can always reverse a live cell's tag.
--
-- RESERVATION GUARD: 'wokArrayTag' (0xFFFF) is reserved for the C WokArray
-- discriminator; it is never assigned to a constructor. When the sequential
-- counter would land on 0xFFFF the next id is bumped to 0x10000, skipping
-- the reserved slot. 'allocNCon's @tid >= 65536@ guard then routes any
-- 0x10000+ constructor to the abstract heap, so no C cell ever carries the
-- reserved tag. The bijection stays injective (0xFFFF is simply never a
-- constructor tag).
internTag :: Text -> Store -> (Word32, Store)
internTag con s = case Map.lookup con (stTagFwd s) of
  Just w  -> (w, s)
  Nothing ->
    let raw = fromIntegral (Map.size (stTagFwd s))
        -- Skip the reserved WOK_ARRAY_TAG (0xFFFF) and WOK_STRING_TAG (0xFFFE)
        -- so no constructor tag ever collides with the C array or string
        -- discriminators. Apply the bumps in descending order so the first
        -- reserved tag encountered shifts raw past the second too.
        w0  = if raw >= wokStringTag then raw + 1 else raw
        w   = if w0  >= wokArrayTag  then w0  + 1 else w0
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

-- | The reserved C tag value for array cells. 'internTag' is guarded to never
-- assign this value to a constructor, so a 'CAddr' cell with this tag is always
-- a 'WokArray', never an 'NCon'.
wokArrayTag :: Word32
wokArrayTag = 0xFFFF

-- | The reserved C tag value for string cells (WOK_STRING_TAG). 'internTag' is
-- guarded to never assign this value (or 'wokArrayTag') to a constructor, so a
-- 'CAddr' cell with this tag is always a 'WokString', never an 'NCon'.
wokStringTag :: Word32
wokStringTag = 0xFFFE

-- | The kind of a single raw slot word in a compact C cell.
data SlotKind = KLitInt | KLitChar | KLitUnit | KPointer
  deriving (Eq, Show)

-- | Encode a 'SlotKind' as the @elemkind@ byte stored in the C array header.
-- This is the single source of truth for the mapping; 'elemKindToSlotKind'
-- is its exact inverse.
--
-- Encoding:
--   0  -> KLitInt    (raw Int64 word, uncounted)
--   1  -> KLitChar   (raw codepoint word, uncounted)
--   2  -> KLitUnit   (raw zero word, uncounted)
--   3  -> KPointer   (2-bit-tagged pointer word, counted)
slotKindToElemKind :: SlotKind -> Word8
slotKindToElemKind KLitInt  = 0
slotKindToElemKind KLitChar = 1
slotKindToElemKind KLitUnit = 2
slotKindToElemKind KPointer = 3

-- | Inverse of 'slotKindToElemKind'. An out-of-range byte is a C-heap invariant
-- violation (only the four values above are ever written by 'allocNArray'); fail
-- loudly rather than silently decoding as the wrong kind and corrupting the cascade.
elemKindToSlotKind :: Word32 -> SlotKind
elemKindToSlotKind 0 = KLitInt
elemKindToSlotKind 1 = KLitChar
elemKindToSlotKind 2 = KLitUnit
elemKindToSlotKind 3 = KPointer
elemKindToSlotKind w = error ("elemKindToSlotKind: unknown elemkind byte " <> show w)

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
--
-- ARENA CELLS ARE ALSO UNCOUNTED, but NOT recognised here (this predicate is pure
-- 'Addr -> Bool', and arena membership lives in the 'Store'). The store-aware
-- 'isArenaAddr' is the arena half; 'incref'/'dropAddr'/'dropReuse' (which all hold
-- the store) short-circuit on it BEFORE dispatching to the pure helpers, so dup/
-- drop of an arena cell are inert and an arena cell is never an FBIP donor. The
-- pure-context callers of 'isUncounted' ('countedRefs', 'closureOwnedBoxed',
-- 'continuationOwned', 'arrayUnique') never need the arena case: by the R+escape
-- invariant (spec §5.1) a counted child of an arena cell is itself counted, never
-- an arena address, so no arena address ever flows through those value-children
-- filters during counted operation.
isUncounted :: Addr -> Bool
isUncounted a = isStaticAddr a || isInline a

-- | True for an 'HAddr' currently recorded in ANY open arena frame (Region Slice
-- R1, spec §3.2). The store-aware half of "uncounted": an arena cell, like a
-- static cell or an inline immediate, owns no counted books, so 'incref'/
-- 'dropAddr'/'dropReuse' treat it as inert. A 'CAddr'/'Inline' is never an arena
-- cell (the abstract mirror records only 'HAddr' indices). A FLATTENED membership
-- check across the whole frame stack is correct (an address lives in exactly one
-- frame; closing pops that frame, after which the address is no longer arena).
isArenaAddr :: Addr -> Store -> Bool
isArenaAddr (HAddr i) s = any (IS.member i) (stArena s)
-- A 'CAddr' is an arena cell iff it lives in a C-arena frame ('stArenaC', CHeap
-- backend only). Recognising it here is what makes 'incref'/'dropAddr' inert on a
-- C-eligible arena cell -- the C analogue of the 'stArena' HAddr membership test.
isArenaAddr (CAddr p) s = any (Set.member p) (stArenaC s)
isArenaAddr (Inline _) _ = False

-- ---------------------------------------------------------------------------
-- Uncounted arena tier (Region Slice R1): the abstract-heap mirror of the C
-- runtime's per-activation arena (spec §3.2, §4.3). An arena cohort is allocated
-- UNCOUNTED ('arenaAllocPure'), dup/drop on it are inert (no cascade), and
-- 'arenaClose' SCANS OUT the cohort's counted children then bulk-removes the
-- cohort in O(1). It feeds a SEPARATE 'stArenaBytes'/'stArenaPeak' pair, never
-- the counted 'stLive'/'stPeak'/'stAllocs'/'stFrees'.

-- | Open an arena scope (the ABSTRACT half): push an empty frame onto both the
-- abstract 'stArena' stack and the C-cell 'stArenaC' stack. LIFO; matched by
-- exactly one 'arenaClose'. (Region Slice R1, spec §4.2.) Does NOT touch
-- 'stArenaHandles' (a CHeap-only concern handled by 'arenaOpenRC'). This is the
-- PURE abstract open used directly by the store-algebra tests and, via
-- 'arenaOpenRC', on the 'AbstractHeap' backend.
arenaOpen :: Store -> Store
arenaOpen s = s { stArena  = IS.empty  : stArena s
                , stArenaC = Set.empty : stArenaC s }

-- | Open an arena scope, dispatching on the backend (Region Slice R1, spec §4.2).
-- On 'AbstractHeap' it is exactly the pure 'arenaOpen'. On 'CHeap' it ALSO calls
-- 'wok_arena_open' (so the C runtime checkpoints its arena region) and records the
-- returned handle on 'stArenaHandles' for the matching 'wok_arena_close'.
arenaOpenRC :: Store -> RC Store
arenaOpenRC s = case stBackend s of
  AbstractHeap -> pure (arenaOpen s)
  CHeap hp     -> do
    handle <- liftIO (H.wokArenaOpen hp)
    pure (arenaOpen s) { stArenaHandles = handle : stArenaHandles s }

-- | Allocate an UNCOUNTED arena cell (Region Slice R1, spec §3.2). Hands out a
-- fresh positive 'HAddr' from 'stNext' (exactly as 'allocPure' does), inserts the
-- node into 'stCells' (the @rc@ value is irrelevant -- the cell is uncounted and
-- reclaimed only by 'arenaClose'), records the index in the INNERMOST 'stArena'
-- frame, and bumps 'stArenaBytes'/'stArenaPeak' by 'wouldBeCBytes' of the node.
--
-- It does NOT call 'recordAlloc': it never touches 'stAllocs'/'stFrees'/'stLive'/
-- 'stPeak'/'stCurBytes'. So the counted accounting is untouched -- the arena lives
-- entirely on its own books.
--
-- PRECONDITION: an arena frame is open. With no open frame ('stArena' empty) the
-- index could not be recorded anywhere and dup/drop would not be inert -- an
-- internal routing error. The RC-layer caller ('arenaAlloc') enforces this
-- precondition and surfaces a catchable 'PrimError' on violation (consistent with
-- 'arenaClose'); reaching the no-frame case HERE is therefore a programmer error
-- in a direct (test-only) call, caught loudly as a pure-function precondition.
arenaAllocPure :: Node -> Store -> (Addr, Store)
arenaAllocPure n = arenaAllocPureBytes (wouldBeCBytes n) n

-- | Like 'arenaAllocPure' but charges 0 arena bytes. Used for 'CHeap' fallback
-- arena allocations (tag overflow, descriptor first-kind-wins mismatch) where the
-- node IS C-eligible ('nodeCEligible': arity + encodable pass, so 'wouldBeCBytes'
-- is nonzero) but NO 'wok_arena_alloc' actually ran -- so the C runtime's
-- @arena_bytes@ charges 0. Charging 'wouldBeCBytes' on the abstract side here would
-- diverge the arena-stat parity oracle (abstract 'stArenaBytes' != C
-- @wok_stat_arena_bytes@). Mirrors 'allocPureFallback's zero-charge of the counted
-- 'allocNCon' fallback, keeping both sides at 0. (Region Slice R1, code-review #2.)
arenaAllocPureFallback :: Node -> Store -> (Addr, Store)
arenaAllocPureFallback = arenaAllocPureBytes 0

-- | The shared core of 'arenaAllocPure'/'arenaAllocPureFallback': record an
-- UNCOUNTED arena cell charging an explicit byte amount (the genuinely-C-eligible
-- path charges 'wouldBeCBytes'; the C-ineligible fallback charges 0). Hands out a
-- fresh positive 'HAddr' from 'stNext', inserts the node into 'stCells' (the @rc@
-- value is irrelevant -- uncounted, reclaimed only by 'arenaClose'), records the
-- index in the INNERMOST 'stArena' frame, and bumps 'stArenaBytes'/'stArenaPeak'.
-- Does NOT call 'recordAlloc': it never touches 'stAllocs'/'stFrees'/'stLive'/
-- 'stPeak'/'stCurBytes', so the counted accounting is untouched.
arenaAllocPureBytes :: Int -> Node -> Store -> (Addr, Store)
arenaAllocPureBytes bytes n s = case stArena s of
  [] -> error "arenaAllocPure: no open arena frame"
  (top : rest) ->
    let i        = stNext s
        g        = stStats s
        cur      = stArenaBytes g + bytes
        g'       = g { stArenaBytes = cur
                     , stArenaPeak  = max (stArenaPeak g) cur }
    in ( HAddr i
         -- The cell's rc is set to 1 as a CONVENTIONAL PLACEHOLDER only (a
         -- well-formed 'Cell' for 'derefPure'); an arena cell is uncounted, so its
         -- rc is never incref'd/decref'd -- 'incref'/'dropAddr' short-circuit on
         -- 'isArenaAddr' before touching it, and 'arenaClose' bulk-removes it
         -- without consulting the rc.
       , s { stCells  = IM.insert i (Cell 1 n bytes) (stCells s)
           , stNext   = i + 1
           , stArena  = IS.insert i top : rest
           , stStats  = g'
           } )

-- | Allocate an UNCOUNTED arena cell, dispatching on the backend (Region Slice R1,
-- spec §3.2). This is the arena analogue of 'alloc'/'allocNCon':
--
--   * 'AbstractHeap' -> 'arenaAllocPure' (an 'HAddr' recorded in 'stArena').
--   * 'CHeap' with a C-ELIGIBLE 'NCon' ('nodeCEligible': arity <= 255, every field
--     encodable) AND a tag < 65536 with a matching descriptor -> a real C arena
--     cell ('CAddr') via 'wok_arena_alloc', recorded in 'stArenaC'.
--   * 'CHeap' with any NON-eligible node (a wide/non-encodable 'NCon', or any other
--     node kind) -> falls back to the abstract arena ('arenaAllocPure', 'HAddr'),
--     exactly as 'allocNCon' falls a non-eligible counted 'NCon' back to the
--     abstract heap. Such a node has 'wouldBeCBytes' = 0, so the arena-byte books
--     stay identical to the C runtime's (which never saw it).
--
-- The same descriptor first-kind-wins / tag-bound checks as 'allocNCon' gate the C
-- path so the recorded 'stConDesc' descriptor stays correct for every C cell of a
-- tag (the scan-out at close decodes slots through that descriptor). 'stArenaBytes'/
-- 'stArenaPeak' are bumped by 'wouldBeCBytes' on the C-eligible arena path (matching
-- the C runtime's @arena_bytes@), and by ZERO on the C-INELIGIBLE fallback paths
-- (tag-overflow / descriptor-mismatch), where no @wok_arena_alloc@ runs so the C
-- runtime charges 0 too — mirroring 'allocNCon's zero-charge 'allocPureFallback' so
-- the differential oracle matches on both branches.
arenaAlloc :: Node -> Store -> RC (Addr, Store)
-- PRECONDITION (enforced here, surfaced as a catchable 'PrimError' consistent with
-- 'arenaClose'): an arena frame is open. The interpreter only routes 'Arena'-tagged
-- binders here, whose enclosing body opened a frame on entry, so this never trips in
-- a well-formed run; surfacing it through the RC error channel (rather than the
-- pure 'arenaAllocPure' 'error') keeps the no-frame failure catchable and matches
-- 'arenaClose'. (Region Slice R1, code-review #5.)
arenaAlloc _ s
  | null (stArena s) =
      liftRC (Left (PrimError (Tx.pack "arenaAlloc: no open arena frame")))
arenaAlloc n s = case stBackend s of
  AbstractHeap -> pure (arenaAllocPure n s)
  CHeap hp     -> case n of
    NCon con vs
      | length vs <= 255
      , Just encoded <- traverse encodeSlotC vs ->
          let (tid, s1) = internTag con s
              newKinds  = map fst encoded
          in if tid >= 65536
               -- Tag overflow: the node is C-eligible (wouldBeCBytes nonzero) but no
               -- 'wok_arena_alloc' runs, so charge 0 to match the C arena_bytes.
               then pure (arenaAllocPureFallback n s1)
               else case IM.lookup (fromIntegral tid) (stConDesc s1) of
                 Nothing ->
                   arenaAllocCEligible hp tid encoded (NCon con vs)
                     (s1 { stConDesc = IM.insert (fromIntegral tid) newKinds (stConDesc s1) })
                 Just existing
                   | existing == newKinds -> arenaAllocCEligible hp tid encoded (NCon con vs) s1
                   -- Descriptor first-kind-wins mismatch: C-eligible node, but no
                   -- 'wok_arena_alloc' runs, so charge 0 to match the C arena_bytes.
                   | otherwise            -> pure (arenaAllocPureFallback (NCon con vs) s1)
    -- Non-eligible NCon (wide/non-encodable) or any other node kind: abstract arena.
    -- 'wouldBeCBytes' is already 0 for these, so 'arenaAllocPure' charges 0.
    _ -> pure (arenaAllocPure n s)

-- | Allocate a C-ELIGIBLE arena 'NCon' as a real C arena cell ('CAddr') via
-- 'wok_arena_alloc', writing its encoded slots, recording it in the innermost
-- 'stArenaC' frame, and bumping 'stArenaBytes'/'stArenaPeak' by 'wouldBeCBytes'
-- (the SAME @8 + 8*arity@ the C runtime's @wok_arena_alloc@ charges to its own
-- @arena_bytes@). The cell is UNCOUNTED: it never touches 'recordAlloc'/'stLive',
-- and 'wok_arena_alloc' allocates with @rc@ unused -- it is reclaimed by
-- 'wok_arena_close' at scope close, never by an rc reaching zero.
arenaAllocCEligible :: Ptr WokHeap -> Word32 -> [(SlotKind, Word64)] -> Node -> Store
                    -> RC (Addr, Store)
arenaAllocCEligible hp tid encoded n s = case stArenaC s of
  []          -> liftRC (Left (PrimError (Tx.pack "arenaAlloc: no open C-arena frame")))
  (top : rest) -> do
    p <- liftIO (H.wokArenaAlloc hp tid (fromIntegral (length encoded)))
    liftIO $ mapM_ (\(i, (_, w)) -> H.wokSlotSet p (fromIntegral i) w)
                   (zip [0 :: Int ..] encoded)
    let bytes = wouldBeCBytes n  -- 8 + 8*arity for a C-eligible NCon
        g     = stStats s
        cur   = stArenaBytes g + bytes
        g'    = g { stArenaBytes = cur
                  , stArenaPeak  = max (stArenaPeak g) cur }
    pure ( CAddr p
         , s { stArenaC = Set.insert p top : rest
             , stStats  = g' } )

-- | Close the innermost arena scope: the SCAN-OUT then the O(1) bulk reset (spec
-- §4.3). Fails loudly ('Left') if no arena frame is open.
--
-- THE SCAN-OUT (step 1). For each address in the TOP frame, read its node and
-- compute its COUNTED children ('countedRefs' over 'nodeValues' -- the SAME
-- routine the free cascade uses), and 'dropAddr' each counted child that is NOT
-- itself an address in this top frame. (An arena sibling is skipped: it dies in
-- the bulk reset; dropping it would be wrong since it is uncounted.) Per the
-- R+escape invariant (spec §5.1, already proven) a counted child of an arena cell
-- never points back into the arena, so this cascade only ever touches counted
-- cells -- it NEVER frees an arena cell. The drops run while the arena cells are
-- still readable (BEFORE the bulk reset).
--
-- THE BULK RESET (step 2). Delete every top-frame address from 'stCells' (marking
-- it dead, the normal free path), subtract its 'cBytes' from 'stArenaBytes', and
-- pop the frame. No 'recordFree': arena cells were never on the counted books.
-- 'stArenaPeak' is NOT reset (it is a high-water mark).
arenaClose :: Store -> RC Store
arenaClose s = case stArena s of
  [] -> liftRC (Left (PrimError (Tx.pack "arenaClose: no open arena frame")))
  (top : rest) -> do
    -- Step 1: scan out the counted children of every arena cell in this frame,
    -- while the arena cells are still readable. Skip children that are arena
    -- siblings of this frame (they die in the bulk reset).
    --
    -- DELIBERATELY DEREFS THE ORIGINAL PRE-DROP STORE @s@: collect every arena
    -- cell's counted children from the pre-drop store so EVERY arena cell is still
    -- readable. Do NOT switch this deref to the post-drop store (the @s1@ the fold
    -- below builds) or to a per-child running store -- a child freed by an earlier
    -- sibling's drop would then be unreadable. Collect first (read-only over @s@),
    -- then fold the drops.
    let scanOne acc i = case derefPure (HAddr i) s of
          -- An arena cell is always on the abstract heap (arenaAllocPure inserts
          -- into stCells), so derefPure resolves it; a failure here is an internal
          -- corruption.
          Left e  -> Left e
          Right c ->
            let kids = [ a | a <- countedRefs (nodeValues (cNode c))
                           , not (inFrame a) ]
            in Right (acc ++ kids)
        -- The sibling-skip filters ONLY this TOP frame. The cross-frame case (an
        -- inner arena cell referencing an OUTER frame's arena cell) is impossible
        -- by the R+escape invariant (spec §5.1: a counted child of an arena cell is
        -- never an arena address) AND, were it ever to arise, would ALSO be caught
        -- by 'dropAddr's own 'isArenaAddr' guard (defense-in-depth: a drop of any
        -- arena cell, this frame's or an outer frame's, is inert). So a stale read
        -- of 'inFrame' alone cannot mislead: it is the same-frame fast skip, never
        -- the sole net.
        inFrame (HAddr j) = IS.member j top
        inFrame _         = False
    childAddrs <- liftRC (foldM scanOne [] (IS.toList top))
    s1 <- foldM (flip dropAddr) s childAddrs
    -- Step 2: bulk-remove every (abstract, HAddr) arena cell of this frame. Mark
    -- dead (the normal free path), subtract its bytes from stArenaBytes, and pop the
    -- frame.
    let removeOne st i = case IM.lookup i (stCells st) of
          Nothing -> st  -- already gone (cannot happen: arena cells are not dropped)
          Just c  -> st { stCells      = IM.delete i (stCells st)
                        , stDead       = IS.insert i (stDead st)
                        , stStats      = (stStats st)
                                           { stArenaBytes = stArenaBytes (stStats st) - cBytes c }
                        }
        s2 = (foldl removeOne s1 (IS.toList top)) { stArena = rest }
    -- Step 3 (CHeap only): scan out + bulk-free the C-arena cells of this frame,
    -- popping the C-cell frame and its handle. On AbstractHeap the C stacks carry
    -- only empty frames, so this pops an empty frame and is a no-op past the pop.
    closeCArenaFrame s2

-- | The C-arena half of 'arenaClose' (Region Slice R1): scan out the counted
-- children of every C-arena cell in the innermost 'stArenaC' frame, then call
-- 'wok_arena_close' to bulk-reclaim the frame's chain, popping 'stArenaC' and
-- 'stArenaHandles'.
--
--   * On 'AbstractHeap' (or an empty C frame) this just pops the (empty) C frame:
--     no C cells exist, nothing to scan, no 'wok_arena_close' to call.
--   * On 'CHeap' it mirrors the abstract scan-out: read each C cell's counted
--     children from its slots ('readCConValues' -> 'countedRefs'), skip C siblings
--     of this frame (they die in the bulk reset), and 'dropAddr' the rest -- the
--     SAME relocated-to-close RC the program would have done. The 'dropAddr' inert
--     guards ('isArenaAddr' on both 'CAddr' and 'HAddr') make any sibling reached
--     through a cross-kind edge a no-op too, so the sibling-skip is an optimization,
--     not the sole net. 'stArenaBytes' is reduced by each cell's @8 + 8*arity@,
--     mirroring the C runtime's @arena_bytes@ restoration; 'wok_arena_close' frees
--     the chain in O(slabs).
closeCArenaFrame :: Store -> RC Store
closeCArenaFrame s = case stArenaC s of
  []            -> liftRC (Left (PrimError (Tx.pack "arenaClose: no open C-arena frame")))
  (top : restC) -> case stBackend s of
    AbstractHeap ->
      -- top is empty under AbstractHeap; just pop the C-cell frame.
      pure s { stArenaC = restC }
    CHeap hp -> do
      let cells = Set.toList top
      -- Collect each C cell's counted children from the PRE-DROP store (all cells
      -- still readable), skipping C siblings of this frame.
      childLists <- liftIO $ mapM (`readCConValues` s) cells
      let kids = [ a | vs <- childLists, a <- countedRefs vs, not (inFrameC a) ]
          inFrameC (CAddr q) = Set.member q top
          inFrameC _         = False
      s1 <- foldM (flip dropAddr) s kids
      -- Reduce stArenaBytes by each cell's 8 + 8*arity (mirroring the C runtime's
      -- arena_bytes restoration). Read the arity from each cell while still live.
      bytesEach <- liftIO $ mapM (\p -> (\ar -> 8 + 8 * fromIntegral (ar :: Word32))
                                          <$> H.wokArity p) cells
      let s2 = s1 { stStats = (stStats s1)
                      { stArenaBytes = stArenaBytes (stStats s1) - sum bytesEach } }
      -- Bulk-reclaim the C arena frame and pop its handle.
      case stArenaHandles s2 of
        (handle : restH) -> do
          liftIO (H.wokArenaClose hp handle)
          pure s2 { stArenaC = restC, stArenaHandles = restH }
        [] -> liftRC (Left (PrimError (Tx.pack "arenaClose: C-arena handle stack underflow")))

-- | Allocate a fresh node on the heap. Returns the new 'Addr' and the updated
-- 'Store'. The cell is initialised with a reference count of 1.
--
-- BACKEND DISPATCH. Under the 'CHeap' backend:
--   * a nullary 'NCon' becomes an inline immediate (no cell on either heap);
--   * an 'NCon' with encodable fields allocates in the C runtime ('CAddr');
--   * an 'NArray' allocates a real 'WokArray' C cell via 'allocNArray';
--   * any other node kind, or a non-encodable 'NCon', falls back to the abstract
--     'IntMap' heap ('HAddr', via 'allocPure').
-- Under 'AbstractHeap' the C paths are never taken; all allocation is abstract.
-- The abstract path is unchanged from the Task-0 pure core, so store-algebra
-- unit tests that call 'allocPure' directly keep working.
alloc :: Node -> Store -> RC (Addr, Store)
alloc (NCon con []) s = pure (allocInline con s)
alloc (NCon con vs) s = allocNCon con vs s
alloc (NArray vs)   s = case stBackend s of
  CHeap hp     -> allocNArray hp vs s
  AbstractHeap -> pure (allocPure (NArray vs) s)
alloc (NString bs)  s = case stBackend s of
  CHeap hp     -> allocNString hp bs s
  AbstractHeap -> pure (allocPure (NString bs) s)
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
  -- AbstractHeap: all NCons land on the abstract heap (HAddr via 'allocPure').
  -- To keep 'stPeakBytes' bit-for-bit identical to the C runtime's
  -- 'wok_stat_peak_bytes', the abstract path mirrors EXACTLY which NCons WOULD
  -- land on the C heap vs. fall back to abstract (without actually calling the C
  -- allocator). This requires the SAME eligibility checks as the CHeap path:
  --   * arity > 255 -> fall back (0 bytes)
  --   * any field non-encodable -> fall back (0 bytes)
  --   * tid >= 65536 -> fall back (0 bytes)
  --   * descriptor mismatch (first-kind-wins, polymorphic Tuple2 etc.) -> fall back
  --     (0 bytes): the second instantiation NEVER lands on C, so must not be charged
  -- Only NCons that pass ALL checks charge bytes (8 + 8 * arity), recording the
  -- same descriptor so later descriptor checks match the CHeap run.
  AbstractHeap
    | length vs > 255    -> pure (allocPure (NCon con vs) s)  -- non-C-eligible: wouldBeCBytes=0
    | otherwise -> case traverse encodeSlotC vs of
        Nothing      -> pure (allocPure (NCon con vs) s)       -- non-C-eligible: wouldBeCBytes=0
        Just encoded ->
          let (tid, s1) = internTag con s
              newKinds  = map fst encoded
          in if tid >= 65536
               then pure (allocPureFallback (NCon con vs) s1)  -- tag overflow: non-C-eligible: 0 bytes
               else case IM.lookup (fromIntegral tid) (stConDesc s1) of
                 -- First-kind-wins: record descriptor on first sight. This first
                 -- instantiation WOULD land on C, so 'allocPure' charges its bytes
                 -- (8 + 8 * arity) -- only later mismatching kinds fall back to 0.
                 Nothing   -> pure (allocPure (NCon con vs)
                                     (s1 { stConDesc = IM.insert (fromIntegral tid) newKinds
                                                                  (stConDesc s1) }))
                 -- Descriptor matches: this node WOULD land on C -> charged bytes.
                 Just existing
                   | existing == newKinds -> pure (allocPure (NCon con vs) s1)
                   -- Descriptor mismatch: this node NEVER lands on C -> 0 bytes.
                   | otherwise            -> pure (allocPureFallback (NCon con vs) s1)
  CHeap hp
    -- The C @arity@ field is a 'uint8' (0..255); a wider constructor cannot be
    -- represented, so route it to the unbounded abstract heap. Checked BEFORE the
    -- encode (which would otherwise be wasted on a cell that must fall back).
    -- CHeap fallback: use 'allocPureFallback' (0 bytes) -- this node does NOT
    -- land on the C heap and must not inflate 'stCurBytes'/'stPeakBytes'; the
    -- oracle only reads 'stPeakBytes' from the abstract run, not the CHeap run.
    | length vs > 255 -> pure (allocPureFallback (NCon con vs) s)
    | otherwise -> case traverse encodeSlotC vs of
        Nothing -> pure (allocPureFallback (NCon con vs) s)
        Just encoded ->
          let (tid, s1)  = internTag con s
              newKinds   = map fst encoded
              doAlloc st = do
                p <- liftIO (H.wokAlloc hp tid (fromIntegral (length vs)))
                liftIO $ mapM_ (\(i, (_, w)) -> H.wokSlotSet p (fromIntegral i) w)
                               (zip [0 :: Int ..] encoded)
                pure (CAddr p, st { stStats = recordAlloc (8 + 8 * length vs) (stStats st) })
          -- The C @tag@ field is a 'uint16'; beyond 65535 distinct interned
          -- constructors a 'CAddr' would truncate the tag and collide. Fall back.
          -- CHeap fallback: 0 bytes (same reason as above).
          in if tid >= 65536
               then pure (allocPureFallback (NCon con vs) s1)
               else case IM.lookup (fromIntegral tid) (stConDesc s1) of
                 -- A nominal/polymorphic constructor (e.g. Tuple2) can appear at
                 -- different instantiations with different slot kinds. The FIRST kind
                 -- seen for a tag wins the C heap; a later mismatch falls back, so the
                 -- recorded descriptor stays correct for every C cell of that tag.
                 -- (Here @s1 == s@: a recorded descriptor implies the tag was already
                 -- interned, so 'internTag' left the store unchanged.)
                 -- Descriptor-mismatch CHeap fallback: 0 bytes.
                 Just existing
                   | existing == newKinds -> doAlloc s1                              -- known: no re-insert
                   | otherwise            -> pure (allocPureFallback (NCon con vs) s1) -- kind mismatch
                 Nothing -> doAlloc (s1 { stConDesc = IM.insert (fromIntegral tid) newKinds (stConDesc s1) })

-- | Allocate a 'WokArray' C cell for an 'NArray' node. Called only under the
-- 'CHeap' backend; the 'AbstractHeap' branch in 'alloc' keeps 'NArray' on the
-- 'IntMap'.
--
-- ELEMKIND. All slots of @Array a@ are homogeneous (one element type). The
-- @elemkind@ byte stored in the cell header is derived from the FIRST encoded
-- slot's 'SlotKind'. An empty array has no slots to derive from; the default is
-- 'KLitInt' (raw-lit, uncounted) because:
--   (a) teardown skips every slot regardless of the stored kind when there are no
--       slots (len=0), so the value is inert for teardown;
--   (b) raw-lit is the safer default (no spurious counted-slot drops on a future
--       reuse of the slot).
-- A non-encodable element is not representable in a C slot; this cannot happen
-- today (all non-encodable values return 'Nothing' from 'encodeSlotC', and the
-- alloc entry point pre-checks). 'traverse encodeSlotC' encodes every element
-- ONCE; a 'Nothing' is a loud invariant error rather than a silent fallback.
allocNArray :: Ptr WokHeap -> [RCValue] -> Store -> RC (Addr, Store)
allocNArray hp vs s =
  case traverse encodeSlotC vs of
    Nothing      -> liftRC (Left (PrimError (Tx.pack "allocNArray: non-encodable element in NArray")))
    Just encoded -> do
      let len = fromIntegral (length encoded) :: Word64
          kind = case encoded of
                   []           -> KLitInt   -- empty array: safe default (raw-lit, uncounted)
                   ((k, _) : _) -> k
          ek = slotKindToElemKind kind
      p <- liftIO (H.wokArrayAlloc hp len ek)
      liftIO $ mapM_ (\(i, (_, w)) -> H.wokArraySlotSet p (fromIntegral (i :: Int)) w)
                     (zip [0..] encoded)
      pure (CAddr p, s { stStats = recordAlloc (16 + 8 * length vs) (stStats s) })

-- | Allocate a 'WokString' C cell for an 'NString' node. Called only under the
-- 'CHeap' backend; the 'AbstractHeap' branch in 'alloc' keeps 'NString' on the
-- 'IntMap'.
--
-- BYTES. The cell byte size is '16 + 8*ceil(byte_len/8)' (8-rounded body),
-- matching 'wok_string_alloc' charge and 'wouldBeCBytes (NString bs)' exactly
-- so the differential oracle sees identical 'peak_bytes' on both backends.
--
-- MEMCPY. After allocation, the byte content of 'bs' is bulk-copied into the
-- cell body via 'wokStringData' (a raw pointer to the body) + 'copyBytes'.
-- 'BS.useAsCStringLen' pins the 'ByteString' for the duration of the copy.
-- The cell owns no child refs (bytes are opaque), so no RC work is needed here.
allocNString :: Ptr WokHeap -> ByteString -> Store -> RC (Addr, Store)
allocNString hp bs s = do
  let byteLen = fromIntegral (BS.length bs) :: Word64
      charged  = wouldBeCBytes (NString bs)
  p    <- liftIO (H.wokStringAlloc hp byteLen)
  dest <- liftIO (H.wokStringData p)
  liftIO $ BS.useAsCStringLen bs (\(src, len) ->
             copyBytes dest (castPtr src) len)
  pure (CAddr p, s { stStats = recordAlloc charged (stStats s) })

-- | The pure core of 'alloc': always allocates on the abstract 'IntMap' heap,
-- returning an 'HAddr'. Charges 'wouldBeCBytes n' to 'stCurBytes'/'stPeakBytes'
-- so the abstract run's byte high-water tracks what would land on the C heap.
-- On the 'AbstractHeap' backend this is always the right choice; the 'CHeap'
-- fallback paths use 'allocPureFallback' (charges 0) instead.
allocPure :: Node -> Store -> (Addr, Store)
allocPure n s =
  let a     = stNext s
      bytes = wouldBeCBytes n
  in ( HAddr a
     , s { stCells = IM.insert a (Cell 1 n bytes) (stCells s)
         , stNext  = a + 1
         , stStats = recordAlloc bytes (stStats s)
         }
     )

-- | Like 'allocPure' but charges 0 bytes. Used for 'CHeap' fallback allocations
-- (arity overflow, descriptor mismatch, tag overflow) where the node does NOT
-- land on the C heap. Charging 'wouldBeCBytes' in these cases would inflate the
-- CHeap run's 'stCurBytes' but the node is never freed via 'bumpFreeStats' --
-- the mismatch would corrupt 'stCurBytes'. On the AbstractHeap run this path is
-- never taken (all fallbacks to allocPure go through the public 'allocPure').
allocPureFallback :: Node -> Store -> (Addr, Store)
allocPureFallback n s =
  let a = stNext s
  in ( HAddr a
     , s { stCells = IM.insert a (Cell 1 n 0) (stCells s)
         , stNext  = a + 1
         , stStats = recordAlloc 0 (stStats s)
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
nodeCEligible (NString _) = False  -- has its own dedicated alloc path (not NCon slot encoding)
nodeCEligible _           = False

-- | The field count of a node (FBIP placement match). Only an 'NCon' has a
-- meaningful physical arity for reuse; every other node kind reports 0 (it is
-- never C-eligible and never a reuse donor/target in this slice).
nodeArity :: Node -> Word32
nodeArity (NCon _ vs) = fromIntegral (length vs)
nodeArity _           = 0

-- | The byte size a node occupies AS A C CELL, or 0 if it never becomes one.
-- This mirrors the C runtime exactly:
--   * A C-eligible 'NCon': @8 + 8 * arity@ (matches 'wok_alloc' in the C runtime).
--   * 'NArray': @16 + 8 * len@ (matches 'wok_array_alloc' in the C runtime).
--   * Every abstract-only node ('NClosure', 'NEnv', 'NCont', 'NContCell',
--     non-eligible 'NCon'): 0 (never allocated on the C heap).
--
-- Used to keep 'stCurBytes'/'stPeakBytes' bit-for-bit identical to the C
-- runtime's @cur_bytes@/@peak_bytes@ so the differential oracle can assert
-- 'peak_bytes' equality between both backends.
wouldBeCBytes :: Node -> Int
wouldBeCBytes n@(NCon _ vs)
  | nodeCEligible n = 8 + 8 * length vs
  | otherwise       = 0
wouldBeCBytes (NArray vs)  = 16 + 8 * length vs
-- Cell byte size = 16 + 8*ceil(byte_len/8). The body rounds UP to an 8-byte
-- granule so the next bumped cell stays 8-aligned (contrast NArray, whose body
-- is already word-aligned and needs no rounding). Matches wok_string_alloc
-- charge exactly so AbstractHeap and CHeap agree on peak_bytes.
wouldBeCBytes (NString bs) = 16 + 8 * ((BS.length bs + 7) `div` 8)
wouldBeCBytes _            = 0

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
     , s { stCells       = IM.insert a (Cell 1 n 0) (stCells s)
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
writeStatic (HAddr i) n s = s { stCells = IM.insert i (Cell 1 n 0) (stCells s) }
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
deref (Inline tid) s = pure (Cell 0 (NCon (tagName tid s) []) 0)

-- | Reconstruct the 'Cell' of a C-heap cell from its header. Dispatches on the
-- tag field: 'wokArrayTag' (0xFFFF) produces an 'NArray'; any other tag produces
-- an 'NCon' via 'readCConValues'.
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
  if tid == wokArrayTag
    then do
      vs <- readCArrayValues p
      pure (Cell 0 (NArray vs) 0)
    else if tid == wokStringTag
      then do
        bs <- readCStringBytes p
        pure (Cell 0 (NString bs) 0)
      else do
        vs <- readCConValues p s
        pure (Cell 0 (NCon (tagName tid s) vs) 0)

-- | Decode a C array cell's slots back to @[RCValue]@, reading the header
-- @elemkind@ once. Delegates to 'readCArraySlots' with the decoded kind. Used by
-- 'readCCell' (deref), which has no kind in hand.
readCArrayValues :: Ptr WokObj -> IO [RCValue]
readCArrayValues p = do
  ekWord <- H.wokArrayElemKind p
  readCArraySlots (elemKindToSlotKind ekWord) p

-- | Decode a C array cell's @len@ slots given the ALREADY-DECODED element
-- 'SlotKind' (no redundant @elemkind@ read). Reads each slot via 'wokArraySlotGet'
-- and decodes it with 'decodeSlotC'. The single slot-decode path shared by
-- 'readCArrayValues' (deref) and the 'dropAddr' cascade (which already holds the
-- kind it read to decide raw-lit-vs-pointer).
--
-- NOTE: 'wokArrayLen' returns a 'Word64'; @take (fromIntegral len)@ on the lazy
-- infinite list @[0..]@ avoids the @len - 1@ underflow that the NCon path guards
-- against with 'readCWords'.
readCArraySlots :: SlotKind -> Ptr WokObj -> IO [RCValue]
readCArraySlots kind p = do
  len <- H.wokArrayLen p
  mapM (fmap (decodeSlotC kind) . H.wokArraySlotGet p)
       (take (fromIntegral len) [0 ..])

-- | Read all bytes of a 'WokString' C cell back into a 'ByteString'. Used by
-- 'readCCell' (deref) and the 'dropAddr' cascade (which reads no bytes -- it
-- only needs the byte_len for the free-stats delta, not the content -- but
-- 'deref' on a string CAddr requires this to reconstruct the node faithfully).
readCStringBytes :: Ptr WokObj -> IO ByteString
readCStringBytes p = do
  len  <- H.wokStringLen p
  dataPtr <- H.wokStringData p
  BS.packCStringLen (castPtr dataPtr, fromIntegral len)

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
derefPure (Inline tid) s = Right (Cell 0 (NCon (tagName tid s) []) 0)
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
-- A C-arena cell ('CAddr' in 'stArenaC') is UNCOUNTED (Region Slice R1): a dup is
-- inert -- NO @wok_dup@ -- mirroring the 'HAddr' arena arm below and 'dropAddr's
-- 'CAddr' arena guard. Checked BEFORE the unconditional @wok_dup@ so a Perceus dup
-- on a C-eligible arena binder never touches the arena cell's (unused) rc. (Today
-- unreachable -- the pass never dups a non-escaping arena cell -- but kept
-- symmetric with the drop path, and live once Task 6 routes C-eligible NCons to
-- the arena.)
incref a@(CAddr p) s
  | isArenaAddr a s = pure s
  | otherwise       = liftIO (H.wokDup p) >> pure s
-- Arena cells are uncounted (Region Slice R1): a dup is inert, exactly like a
-- static/'Inline' address. Checked before the abstract dispatch since arena
-- membership lives in the store, not in the address.
incref a@(HAddr _) s
  | isArenaAddr a s = pure s
  | otherwise       = liftRC (increfPure a s)
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
    -- A C-arena cell ('CAddr' in 'stArenaC') is UNCOUNTED (Region Slice R1): a drop
    -- is an inert no-op WITH NO CASCADE, mirroring the HAddr arena case below and
    -- the C runtime's reclamation by 'wok_arena_close' (not by an rc reaching zero).
    -- Checked BEFORE the @wok_dec@ so a Perceus-emitted drop on an arena binder, or
    -- an arena sibling reached via a scan-out cascade, never decrements a cell the
    -- arena owns.
    go (a@(CAddr _) : rest) s
      | isArenaAddr a s = go rest s
    go (CAddr p : rest) s = do
      newrc <- liftIO (H.wokDec p)
      if newrc /= 0
        then go rest s
        else do
          -- About to free: read the tag to dispatch between WokArray and NCon,
          -- decode children BEFORE freeing, then return the cell to the runtime.
          --
          -- CAddr CELLS: 'allocNCon' and 'allocNArray' are the ONLY 'CAddr'
          -- producers. For an 'NCon' (tag /= WOK_ARRAY_TAG):
          --   cascadeChildren (NCon _ vs) == countedRefs vs,
          -- so 'countedRefs' over the decoded slots is the correct cascade.
          -- For a 'WokArray' (tag == WOK_ARRAY_TAG), the cascade depends on the
          -- header's 'elemkind':
          --   * raw-lit kind (KLitInt/KLitChar/KLitUnit): no counted children;
          --     no child drops needed, just free the cell.
          --   * pointer-scheme kind (KPointer): each slot holds a 2-bit-tagged
          --     pointer; 'countedRefs' over decoded values drops the counted ones.
          -- 'cascadeChildren' is not consulted for either C-eligible kind: 'NCont'
          -- owned-set routing never applies to a C cell.
          tid <- liftIO (H.wokTag p)
          -- Compute the byte delta BEFORE freeing: the same formula used at
          -- allocation so stCurBytes stays balanced. Arrays = 16 + 8*len;
          -- Strings = 16 + 8*ceil(byte_len/8) (8-rounded body);
          -- NCons = 8 + 8*arity (both C-eligible, same layout as wok_alloc /
          -- wok_array_alloc / wok_string_alloc charge).
          bytes <- if tid == wokArrayTag
                     then do
                       len <- liftIO (H.wokArrayLen p)
                       pure (16 + 8 * fromIntegral (len :: Word64))
                     else if tid == wokStringTag
                       then do
                         blen <- liftIO (H.wokStringLen p)
                         pure (16 + 8 * fromIntegral ((blen + 7) `div` 8 :: Word64))
                       else do
                         ar <- liftIO (H.wokArity p)
                         pure (8 + 8 * fromIntegral (ar :: Word32))
          -- Strings have no child refs (bytes are opaque): cascade is empty.
          kids <- if tid == wokArrayTag
                    then do
                      kind <- elemKindToSlotKind <$> liftIO (H.wokArrayElemKind p)
                      case kind of
                        -- raw-lit elemkind: teardown skips every slot (uncounted)
                        KLitInt  -> pure []
                        KLitChar -> pure []
                        KLitUnit -> pure []
                        -- pointer-scheme: decode slots (reusing the kind already
                        -- read) and collect counted refs
                        KPointer -> countedRefs <$> liftIO (readCArraySlots kind p)
                    else if tid == wokStringTag
                      -- String bytes are opaque: no child refs, no cascade.
                      then pure []
                      else countedRefs <$> liftIO (readCConValues p s)
          hp <- heapPtr s
          liftIO (H.wokFree hp p)
          go (kids ++ rest) (bumpFreeStats bytes s)
    go (a@(HAddr _) : rest) s
      -- Arena cells are uncounted (Region Slice R1, spec §3.2): a drop is an inert
      -- no-op WITH NO CASCADE -- exactly like the static case in 'dropAddrStepPure'.
      -- The cell is reclaimed only by 'arenaClose'; its counted children are
      -- released by the close scan-out, not by this inert drop. Checked here (the
      -- monad form holds the store) before the abort-reclaim/'dropAddrStepPure' path.
      | isArenaAddr a s = go rest s
    go (a@(HAddr _) : rest) s = do
      -- ABORT RECLAIM (FBIP effect-safety, spec §3.4). If @a@ is an 'NCont' about
      -- to be freed (rc reaching 0 -- a handler discarding a captured continuation),
      -- first reclaim the in-flight FBIP reservations trapped in its prefix. Their
      -- paired 'allocAt' never runs (the continuation is gone), so the abort is
      -- their only free path. This precedes the cell's own free + owned-set cascade
      -- ('dropAddrStepPure' below); the reserved shells are DISJOINT from the owned
      -- set (off-books vs. live captured bindings), so the two frees never conflict.
      sReclaimed <- reclaimIfNCont a s
      (mkids, s') <- liftRC (dropAddrStepPure a sReclaimed)
      case mkids of
        Nothing   -> go rest s'         -- just decremented (rc > 1) or static no-op
        Just kids -> go (kids ++ rest) s'

    -- Peek @a@: if it is an 'NCont' cell at rc <= 1 (about to be freed) and not
    -- already dead, fold 'freeReservation' over the in-flight reservations its
    -- prefix carries. Otherwise the store is unchanged. The double-deref (peek here,
    -- then 'dropAddrStepPure' derefs again) is acceptable: abort is the rare path.
    reclaimIfNCont :: Addr -> Store -> RC Store
    reclaimIfNCont (HAddr i) s =
      case IM.lookup i (stCells s) of
        Just (Cell rc (NCont prefix _) _)
          | rc <= 1 && not (IS.member i (stDead s)) ->
              foldM (flip freeReservation) s (continuationReservations prefix (stReserved s))
        _ -> pure s
    reclaimIfNCont _ s = pure s

-- | The C-heap free-stats bump, mirroring the abstract path's free accounting in
-- 'dropAddrStepPure' (frees + 1, live - 1, stCurBytes - bytes). The C runtime keeps
-- its own independent stat counters; this keeps the store-level 'Stats' identical
-- to the abstract path so the differential oracle can diff abstract-vs-C totals.
-- The 'Int' is the byte delta from 'wouldBeCBytes' for the node being freed.
bumpFreeStats :: Int -> Store -> Store
bumpFreeStats bytes s = s { stStats = recordFree bytes (stStats s) }

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
              let kids  = cascadeChildren (cNode c)
                  -- Use cBytes c (the delta charged at alloc time) so stCurBytes
                  -- stays balanced even when a CHeap descriptor-mismatch fallback
                  -- charged 0 instead of wouldBeCBytes.
                  s'    = s { stCells = IM.delete i (stCells s)
                            , stDead  = IS.insert i (stDead s)
                            , stStats = recordFree (cBytes c) (stStats s) }
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
-- Every element slot is a counted child; the generic cascade frees each counted
-- one exactly once (uncounted slots are skipped by 'countedRefs').
nodeValues (NArray vs)          = vs
-- Bytes are opaque (no child refs). Drop cascade is empty: 'dropAddr' on an
-- 'NString' frees only the cell itself, with no child iteration.
nodeValues (NString _)          = []
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
-- 'countedRefs'-over-decoded-slots cascade 'dropAddr' uses --- a 'CAddr' is an
-- 'NCon' or a 'WokArray'), retain the shell as the token WITHOUT returning it to
-- the runtime (no free list push, no stat bump), then drop the children via the
-- worklist. A live 'CAddr' was C-eligible by construction, so @rsCEligible = True@.
--
-- ARRAYS ARE FBIP-EXCLUDED. 'nodeCEligible (NArray _) = False' and
-- 'nodeArity (NArray _) = 0' ensure Perceus never emits a @drop_reuse@ for an
-- array, so the 'CAddr' arm here NEVER sees a 'WokArray' (WOK_ARRAY_TAG).
-- No WOK_ARRAY_TAG branch is needed; the existing 'readCConValues' path is NCon-only.
dropReuse :: Addr -> Store -> RC (RCValue, Store)
dropReuse (Inline _) s = pure (RVReuse Nothing, s)              -- uncounted: never a donor
-- A C-arena cell is FBIP-excluded (Region Slice R1, spec §5.5): uncounted, never a
-- donor, never reserved -- the NULL-token path, mirroring the HAddr arena guard
-- below and the static/Inline cases. Checked before the @wok_dec@.
dropReuse a@(CAddr _) s
  | isArenaAddr a s = pure (RVReuse Nothing, s)
dropReuse (CAddr p)  s = do
  newrc <- liftIO (H.wokDec p)
  if newrc /= 0
    then pure (RVReuse Nothing, s)                             -- shared: NULL token
    else do
      arity <- liftIO (H.wokArity p)
      -- Arrays are FBIP-excluded (nodeCEligible returns False for NArray), so
      -- Perceus never emits drop_reuse for an array cell. A WOK_ARRAY_TAG CAddr
      -- here is an internal invariant violation: fail loudly through the RC error
      -- channel rather than decoding an array via the NCon descriptor path.
      tid <- liftIO (H.wokTag p)
      ks  <- if tid == wokArrayTag
               then liftRC (Left (PrimError (Tx.pack
                      "dropReuse: WokArray reached CAddr FBIP path (arrays are FBIP-excluded)")))
               else countedRefs <$> liftIO (readCConValues p s)  -- decode children BEFORE reserving
      -- reserve the shell: do NOT wokFree, do NOT bumpFreeStats. Track it as
      -- in-flight so the abort-reclaim collector can find it (spec §3.1).
      s'    <- foldM (flip dropAddr) s ks
      let s'' = s' { stReserved = Set.insert (CAddr p) (stReserved s') }
      let cAddrBytes = 8 + 8 * fromIntegral (arity :: Word32)
      pure (RVReuse (Just (ReuseSlot (CAddr p) arity True cAddrBytes)), s'')
dropReuse a@(HAddr i) s
  | isStaticAddr a    = pure (RVReuse Nothing, s)              -- uncounted: never a donor
  -- Arena cells are FBIP-excluded (Region Slice R1, spec §5.5): an arena cell is
  -- uncounted, so it is never a reuse donor and never enters 'stReserved' -- the
  -- NULL-token path, exactly like a static address. (Arrays are already excluded;
  -- arena cells join them.)
  | isArenaAddr a s   = pure (RVReuse Nothing, s)
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
          -- track the reserved shell as in-flight (spec §3.1).
          let s''' = s'' { stReserved = Set.insert (HAddr i) (stReserved s'') }
          pure (RVReuse (Just (ReuseSlot (HAddr i) arity elig (cBytes c))), s''')
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
allocAt (RVReuse (Just (ReuseSlot a ar oldElig origBytes))) newNode s0 =
  -- Consuming the token: release its in-flight reservation on EVERY consume path
  -- (reuse re-stamp AND not-eligible free+fresh) so the abort-reclaim collector
  -- no longer sees it (spec §3.1).
  let s = s0 { stReserved = Set.delete a (stReserved s0) }
  in case a of
       HAddr i
         | nodeArity newNode == ar && nodeCEligible newNode == oldElig ->
             -- Reuse: no alloc/free accounting change; preserve the original 'cBytes'
             -- in the revived cell so its eventual free restores the right delta.
             pure (HAddr i, s { stCells = IM.insert i (Cell 1 newNode origBytes) (stCells s) })
         | otherwise ->
             -- Shell doesn't fit the new node: free the shell (using the original
             -- byte charge so accounting is balanced) then allocate fresh.
             alloc newNode (s { stDead  = IS.insert i (stDead s)
                              , stStats = recordFree origBytes (stStats s) })
       CAddr p
         | nodeArity newNode == ar && nodeCEligible newNode == oldElig ->
             reuseCConAt p newNode s
         | otherwise -> do
             -- Shell doesn't fit the new node: free the shell (using the original
             -- byte charge so accounting is balanced) then allocate fresh.
             hp <- heapPtr s
             liftIO (H.wokFree hp p)
             alloc newNode (bumpFreeStats origBytes s)
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

-- | Primitive lookup table, keyed by the qualified @(module, name)@ of the
-- prelude @extern@. Matches the reference machine's 'PrimTable' convention;
-- prevents collisions when two modules export the same bare name.
type RCPrimTable = Map (Text, Text) RCPrim

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

-- | Resolve an atom in a position that OWNS the resulting value (a 'Let'-bound
-- RHS, a 'Ret'/'Jump' result, a constructor/record field, or a call/op argument
-- the callee consumes). Identical to 'resolveRCAtom' EXCEPT a STRING LITERAL
-- @ALit (LStr s)@ ALLOCATES a fresh counted 'NString' cell (UTF-8-encoding @s@)
-- instead of producing an inline @RVLit (LStr s)@ (String Slice E1, Task 3, spec
-- §5.5). The fresh cell is born at rc 1 and is OWNED by whatever this position
-- binds it to --- the binder Perceus drops, the constructor cascade, or the callee
-- parameter --- so it is reference-counted balanced like any other boxed value.
--
-- ONLY string literals diverge from the pure resolver; every other atom (a
-- variable, a non-string literal, a prim) goes through 'resolveRCAtom' unchanged
-- and threads the store untouched. This is deliberately NOT used at the 'Case'
-- SCRUTINEE / 'RProj' parent / instance-handle positions: those do NOT own the
-- value (a literal scrutinee is matched in place; Perceus's 'scrutineeParent'
-- returns 'Nothing' for a literal, so nothing would drop an allocated cell), so
-- they keep the pure 'resolveRCAtom' (an inline @RVLit (LStr s)@) --- which leaks
-- nothing because it allocates nothing. A VARIABLE scrutinee of String type is
-- already an 'RVBox' in the env (allocated at its own binding site) and resolves
-- through the pure path correctly.
resolveRCAtomAlloc :: RCScope -> Atom -> Store -> RC (RCValue, Store)
resolveRCAtomAlloc _  (ALit (LStr s)) st = do
  (a, st') <- alloc (NString (TxEnc.encodeUtf8 s)) st
  pure (RVBox a, st')
resolveRCAtomAlloc sc a st = do
  v <- liftRC (resolveRCAtom sc a)
  pure (v, st)

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
    -- Render an array as @[a, b, c]@: each slot is rendered in order, elements
    -- comma-separated. An empty array is @[]@.
    goNode s (NArray vs) = do
      parts <- mapM (goVal s) vs
      pure (Tx.pack "[" <> Tx.intercalate (Tx.pack ", ") parts <> Tx.pack "]")
    -- Render a string identically to the reference interpreter's 'renderLit (LStr text)':
    -- decode the bytes as UTF-8 (valid by the 'NString' invariant) and apply Haskell's
    -- 'show', producing a double-quoted escaped string. Byte-identical to the reference so
    -- the differential oracle can compare the two backends' output.
    goNode _ (NString bs) =
      pure (Tx.pack (show (TxEnc.decodeUtf8 bs)))
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

-- ---------------------------------------------------------------------------
-- Array in-place mutation helpers (Array Slice C)

-- | Total safe list index: @atIndex n xs@ is @Just (xs !! n)@ without the partial
-- @(!!)@, or @Nothing@ if @n@ is out of range. Lives here (not Prim.hs) so the
-- array in-place writer can use it without the Prim->Value import cycle; Prim.hs
-- imports it from here.
atIndex :: Int -> [a] -> Maybe a
atIndex n xs = case drop n xs of
  (x : _) -> Just x
  []      -> Nothing

-- | Replace the element at index @i@ with @x@ (others unchanged). Shared by the
-- HAddr in-place writer and the copy-on-write path in 'arraySet'. Out-of-range
-- @i@ leaves the list unchanged (callers bounds-check first).
setAt :: Int -> a -> [a] -> [a]
setAt i x xs = [ if j == i then x else el | (j, el) <- zip [0 :: Int ..] xs ]

-- | Element count of the array at @a@, cheaply: O(1) 'H.wokArrayLen' on the C
-- backend (no per-slot decode), list length on the abstract backend. Used by
-- 'arraySet' for the bounds check so the in-place fast path does not decode every
-- slot just to learn the length.
arrayLenOf :: Addr -> Store -> RC Int
arrayLenOf (CAddr p) _ = fromIntegral <$> liftIO (H.wokArrayLen p)
arrayLenOf a s = do
  c <- liftRC (derefPure a s)
  case cNode c of
    NArray vs -> pure (length vs)
    _         -> liftRC (Left (PrimError (Tx.pack "Array: not an array")))

-- | True iff the array at @a@ is safe to mutate in place: a dynamic, counted
-- cell whose refcount is exactly 1 (the caller's owned reference is the only
-- one).
--
-- Uncounted addresses ('isUncounted': static immortal negatives or inline
-- immediates) are never unique here; 'isUncounted' is checked FIRST, exactly as
-- 'dropReuse' guards its donor.
--
-- The 'CAddr' arm peeks the C cell's rc non-destructively ('H.wokRc');
-- the 'HAddr' arm reads 'cRc' via 'derefPure' (which rejects 'CAddr', so it is
-- reached only for a dynamic 'HAddr'). The decision is identical on both
-- backends because the refcount is maintained in lockstep.
--
-- An array handle is never an 'Inline' immediate (the 'Inline' arm is defensive
-- totality only).
arrayUnique :: Addr -> Store -> RC Bool
arrayUnique a _ | isUncounted a = pure False
arrayUnique (CAddr p) _         = (== 1) <$> liftIO (H.wokRc p)
arrayUnique a@(HAddr _) s       = (== 1) . cRc <$> liftRC (derefPure a s)
arrayUnique (Inline _) _        = pure False   -- isUncounted already covers Inline; kept for exhaustiveness

-- | Overwrite slot @i@ of the array at @a@ with @v@, in place, returning the OLD
-- element for the caller to drop. 0 alloc / 0 free; rc / length / cBytes unchanged.
-- The first argument is @encodeSlotC v@ (precomputed by the caller's gate, which
-- guarantees it is 'Just'): the C backend writes that encoded word, the abstract
-- backend ignores it and stores @v@ directly. ORDER: read old -> write new ->
-- return old (caller drops it). Precondition: the array is unique ('arrayUnique').
arraySetSlotInPlace :: (SlotKind, Word64) -> Addr -> Int -> RCValue -> Store -> RC (RCValue, Store)
arraySetSlotInPlace (newKind, w) (CAddr p) i _v s = do
  -- Bounds-check BEFORE touching raw memory (the C wokArraySlot* carry only a
  -- DEBUG assert; an out-of-range index would corrupt the heap in release).
  len <- liftIO (H.wokArrayLen p)
  if i < 0 || fromIntegral i >= len
    then liftRC (Left (PrimError (Tx.pack "arraySetSlotInPlace: index out of range")))
    else do
      kind <- elemKindToSlotKind <$> liftIO (H.wokArrayElemKind p)
      oldW <- liftIO (H.wokArraySlotGet p (fromIntegral i))
      let oldEl = decodeSlotC kind oldW
      -- v : a, so by monomorphism newKind == kind in well-typed code; we still
      -- check because a mismatch would be a SILENT C-heap corruption (the teardown
      -- cascade decodes every slot with the header elemkind).
      if newKind == kind
        then do
          liftIO (H.wokArraySlotSet p (fromIntegral i) w)
          pure (oldEl, s)
        else liftRC (Left (PrimError (Tx.pack
               "arraySetSlotInPlace: new element SlotKind does not match the array elemkind")))
arraySetSlotInPlace _ (HAddr idx) i v s
  | i < 0     = liftRC (Left (PrimError (Tx.pack "arraySetSlotInPlace: index out of range")))
  | otherwise = do
      c <- liftRC (derefPure (HAddr idx) s)
      case cNode c of
        NArray vs -> case atIndex i vs of
          Just oldEl ->
            let newVs = setAt i v vs
                c'    = c { cNode = NArray newVs }
            in pure (oldEl, s { stCells = IM.insert idx c' (stCells s) })
          Nothing -> liftRC (Left (PrimError (Tx.pack "arraySetSlotInPlace: index out of range")))
        _ -> liftRC (Left (PrimError (Tx.pack "arraySetSlotInPlace: address is not an array")))
arraySetSlotInPlace _ (Inline _) _ _ _ =
  liftRC (Left (PrimError (Tx.pack "arraySetSlotInPlace: inline handle is not an array")))
