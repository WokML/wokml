module Wok.Interp.RC.Value
  ( -- * Address
    Addr
    -- * Runtime values
  , RCValue (..)
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
  , allocStatic
  , writeStatic
  , writeNode
  , isStaticAddr
  , deref
  , mkClosure
  , closureOwnedBoxed
    -- * Static sentinel
  , emptyEnvSentinelAddr
  , initSentinel
    -- * Reference-count operations
  , incref
  , dropAddr
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
  ) where

import Data.IntMap.Strict (IntMap)
import qualified Data.IntMap.Strict as IM
import Data.IntSet (IntSet)
import qualified Data.IntSet as IS
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as Tx
import Wok.Interp.Value (RuntimeError (..))
import Wok.IR.Anf
  ( Atom (..), Binder (..), Expr, Handler (..), Lit (..), binderUnique, freeVarsExpr )
import Wok.IR.Escape (dropTargets, nonHeadOccs)
import Wok.IR.Name (JoinId, Unique, nameHint, nameUniq)

-- ---------------------------------------------------------------------------
-- Addresses and values

-- | A heap address: a monotonically-assigned integer index into the 'Store'.
type Addr = Int

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
valueChildren :: RCValue -> [Addr]
valueChildren (RVLit _)          = []
valueChildren (RVBox a)          = [a]
valueChildren (RVRecMember _ _ e) = [e]
valueChildren (RVInst _ _)        = []

-- | The counted addresses a set of values references (skip static). The SINGLE
-- unit of both capture-incref and free-cascade, via 'valueChildren' --- so every
-- value shape ('RVBox', 'RVRecMember', and any future variant) is retained
-- EXACTLY as it is released. There is no parallel borrowed-set to drift.
countedRefs :: [RCValue] -> [Addr]
countedRefs = concatMap (filter (not . isStaticAddr) . valueChildren)

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
    go (KDropCellRC a k)      = [ (Nothing, a) | not (isStaticAddr a) ] ++ go k
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
-- than a silent use-after-free.
moveOutCont :: Addr -> Store -> Either RuntimeError (RCKont, (Handler, Int, RCScope), Store)
moveOutCont a s = do
  c <- deref a s
  case cNode c of
    NCont prefix hinfo
      | cRc c == 1 ->
          let st = stStats s
              s' = s { stCells = IM.delete a (stCells s)
                     , stDead  = IS.insert a (stDead s)
                     , stStats = st { stFrees = stFrees st + 1, stLive = stLive st - 1 } }
          in Right (prefix, hinfo, s')
      | otherwise ->
          Left (PrimError (Tx.pack ("internal: resume of a continuation with rc=" <> show (cRc c)
                                     <> " (one-shot violation); addr " <> show a)))
    _ -> Left (PrimError (Tx.pack ("resume of non-continuation addr " <> show a)))

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
  , stNext       :: Addr        -- ^ next dynamic address (>= 0), counts upward
  , stNextStatic :: Addr        -- ^ next static address (< 0), counts downward
  , stDead       :: IntSet
  , stStats      :: Stats
  }

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
emptyEnvSentinelAddr = -1

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
emptyStore = Store IM.empty 0 (-1) IS.empty (Stats 0 0 0 0)

-- | True for a static (immortal, uncounted) address. Static cells are
-- allocated by 'allocStatic' at negative addresses; the dynamic heap uses
-- non-negative addresses.
isStaticAddr :: Addr -> Bool
isStaticAddr a = a < 0

-- | Allocate a fresh node on the heap. Returns the new 'Addr' and the updated
-- 'Store'. The cell is initialised with a reference count of 1.
alloc :: Node -> Store -> (Addr, Store)
alloc n s =
  let a    = stNext s
      st   = stStats s
      live = stLive st + 1
      st'  = st { stAllocs = stAllocs st + 1
                , stLive   = live
                , stPeak   = max (stPeak st) live }
  in ( a
     , s { stCells = IM.insert a (Cell 1 n) (stCells s)
         , stNext  = a + 1
         , stStats = st'
         }
     )

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
  in ( a
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
writeStatic a n s = s { stCells = IM.insert a (Cell 1 n) (stCells s) }

-- | Overwrite the NODE payload of an existing cell while PRESERVING its reference
-- count (and statistics). Used by the M3 continuation-cell move primitives
-- (@__cont_store@/@__cont_take@) to transition an 'NContCell' between
-- @Nothing@ (empty) and @Just a@ (holding) in place, since those are MOVES, not
-- allocations: the cell keeps its identity and its refcount across the fill/empty.
-- 'Left' if the address is dead or dangling (the cell must already exist).
writeNode :: Addr -> Node -> Store -> Either RuntimeError Store
writeNode a n s = do
  c <- deref a s
  Right s { stCells = IM.insert a c { cNode = n } (stCells s) }

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
  [ a | RVBox a <- Map.elems env, not (isStaticAddr a) ]
closureOwnedBoxed (NClosure _ _ _ BorrowCaptures) = []
closureOwnedBoxed _ = []

-- | Dereference an address. Returns 'Left' if the address has been freed
-- (use-after-free) or was never allocated (dangling pointer).
deref :: Addr -> Store -> Either RuntimeError Cell
deref a s
  | IS.member a (stDead s) =
      Left (PrimError (Tx.pack ("use-after-free: addr " <> show a)))
  | otherwise =
      case IM.lookup a (stCells s) of
        Just c  -> Right c
        Nothing -> Left (PrimError (Tx.pack ("dangling addr " <> show a)))

-- ---------------------------------------------------------------------------
-- Reference-count operations

-- | Increment the reference count of a live cell. Returns 'Left' if the
-- address is dead or dangling. A NO-OP on static (negative) addresses: cells in
-- the immortal region are uncounted, so dup/drop of a global handle is inert.
incref :: Addr -> Store -> Either RuntimeError Store
incref a s
  | isStaticAddr a = Right s
  | otherwise = do
      c <- deref a s
      Right s { stCells = IM.insert a c { cRc = cRc c + 1 } (stCells s) }

-- | Decrement the reference count of a cell. When the count reaches zero the
-- cell is freed and its boxed children are recursively decremented.
--
-- The traversal is ITERATIVE (worklist), not host-recursive, so arbitrarily
-- deep structures do not cause a stack overflow.
dropAddr :: Addr -> Store -> Either RuntimeError Store
dropAddr a0 s0 = go [a0] s0
  where
    go [] s = Right s
    go (a : rest) s
      -- Static (immortal) cells are uncounted: a drop of a global handle, or of
      -- a dynamic field that points at a global, is inert. Skip it.
      | isStaticAddr a = go rest s
      | IS.member a (stDead s) =
          Left (PrimError (Tx.pack ("double-free: addr " <> show a)))
      | otherwise =
          case IM.lookup a (stCells s) of
            Nothing -> Left (PrimError (Tx.pack ("drop of dangling addr " <> show a)))
            Just c
              | cRc c <= 1 ->  -- rc about to reach 0 -> free
                  let kids = cascadeChildren (cNode c)
                      st   = stStats s
                      s'   = s { stCells = IM.delete a (stCells s)
                               , stDead  = IS.insert a (stDead s)
                               , stStats = st { stFrees = stFrees st + 1
                                              , stLive  = stLive  st - 1 } }
                  in go (kids ++ rest) s'
              | otherwise ->
                  go rest s { stCells = IM.insert a c { cRc = cRc c - 1 } (stCells s) }

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
  , rpFn    :: [RCValue] -> Store -> Either RuntimeError (RCPrimResult, Store)
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

renderRCValue :: Store -> RCValue -> Either RuntimeError Text
renderRCValue _ (RVLit l)           = Right (renderLit l)
renderRCValue s (RVBox a)           = do
  c <- deref a s
  renderNode s (cNode c)
renderRCValue _ RVRecMember{} = Right (Tx.pack "<closure>")
renderRCValue _ (RVInst _ _)  = Right (Tx.pack "<instance>")

renderNode :: Store -> Node -> Either RuntimeError Text
renderNode _ (NCon t []) | t == Tx.pack "Nil" = Right (Tx.pack "[]")
renderNode s (NCon t [h, tl]) | t == Tx.pack "Cons" = renderList s h tl
renderNode s (NCon tag vs)
  | Just n <- tupleArity tag, length vs == n = do
      parts <- mapM (renderRCValue s) vs
      Right (Tx.pack "(" <> Tx.intercalate (Tx.pack ", ") parts <> Tx.pack ")")
renderNode _ (NCon c []) = Right c
renderNode s (NCon c vs) = do
  parts <- mapM (renderRCValue s) vs
  Right (c <> Tx.pack "(" <> Tx.intercalate (Tx.pack ", ") parts <> Tx.pack ")")
renderNode s (NRecord t m) = do
  parts <- mapM (\(l, fv) -> do tv <- renderRCValue s fv
                                Right (l <> Tx.pack " = " <> tv)) (Map.toList m)
  Right (t <> Tx.pack " { " <> Tx.intercalate (Tx.pack ", ") parts <> Tx.pack " }")
renderNode _ NClosure{}      = Right (Tx.pack "<closure>")
renderNode _ (NGroupCode _)  = Right (Tx.pack "<closure>")
renderNode _ (NEnv _)        = Right (Tx.pack "<env>")
renderNode _ (NCont _ _)     = Right (Tx.pack "<continuation>")
renderNode _ (NContCell _)   = Right (Tx.pack "<cont-cell>")

renderLit :: Lit -> Text
renderLit (LInt n)  = Tx.pack (show n)
renderLit (LStr str) = Tx.pack (show str)
renderLit (LChar c) = Tx.pack (show c)
renderLit LUnit     = Tx.pack "()"

-- | Render a proper Cons/Nil list as @[a, b, c]@. An improper tail renders the
-- remainder after a @|@ so malformed lists are still total and visible. Mirrors
-- 'Wok.Interp.Value.renderList', derefing each spine handle.
renderList :: Store -> RCValue -> RCValue -> Either RuntimeError Text
renderList s h0 tl0 = do
  hd <- renderRCValue s h0
  go [hd] tl0
  where
    go acc v = case v of
      RVBox a -> do
        c <- deref a s
        case cNode c of
          NCon t [] | t == Tx.pack "Nil" ->
            Right (Tx.pack "[" <> Tx.intercalate (Tx.pack ", ") (reverse acc) <> Tx.pack "]")
          NCon t [h, tl] | t == Tx.pack "Cons" -> do
            hd <- renderRCValue s h
            go (hd : acc) tl
          _ -> improper acc v
      RVLit _           -> improper acc v
      RVRecMember{} -> improper acc v
      RVInst _ _    -> improper acc v
    improper acc v = do
      rest <- renderRCValue s v
      Right (Tx.pack "[" <> Tx.intercalate (Tx.pack ", ") (reverse acc)
               <> Tx.pack " | " <> rest <> Tx.pack "]")

-- | If the tag is @TupleN@, return N.
tupleArity :: Text -> Maybe Int
tupleArity t = case Tx.stripPrefix (Tx.pack "Tuple") t of
  Just rest | not (Tx.null rest), Tx.all (`elem` ['0' .. '9']) rest -> Just (read (Tx.unpack rest))
  _ -> Nothing
