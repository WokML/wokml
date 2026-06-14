module Wok.Interp.RC.Value
  ( -- * Address
    Addr
    -- * Runtime values
  , RCValue (..)
  , REnv
    -- * Lexical scope
  , RCScope (..)
  , emptyRCScope
  , RCJoin (..)
    -- * Continuation stack
  , RCKont (..)
    -- * Heap nodes
  , Node (..)
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
  , isStaticAddr
  , allocLetRecGroup
  , writeRegionCell
  , deref
  , isRegionAddr
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
import Data.Text (Text)
import qualified Data.Text as Tx
import Wok.Interp.Value (RuntimeError (..))
import Wok.IR.Anf (Atom (..), Binder (..), Expr, Lit (..))
import Wok.IR.Name (JoinId, Unique, nameHint, nameUniq)

-- ---------------------------------------------------------------------------
-- Addresses and values

-- | A heap address: a monotonically-assigned integer index into the 'Store'.
type Addr = Int

-- | Runtime values in the RC interpreter. Either an unboxed literal or a
-- boxed pointer to a heap 'Node'.
data RCValue
  = RVLit Lit
  | RVBox Addr
  deriving (Eq, Show)

-- | Variable environment: identity (Unique) -> RC runtime value.
type REnv = Map Unique RCValue

-- ---------------------------------------------------------------------------
-- Lexical scope

-- | A lexical scope: term bindings plus join points. The RC analogue of
-- 'Wok.Interp.Value.Scope'. M1 is the no-handler fragment, so there are no
-- effect-handler frames; only term bindings and join points appear.
data RCScope = RCScope { rscEnv :: REnv, rscJoins :: Map JoinId RCJoin }

-- | The empty scope: no term bindings, no join points.
emptyRCScope :: RCScope
emptyRCScope = RCScope Map.empty Map.empty

-- | A labelled local continuation: the scope captured where the join was
-- defined, its parameters, its body, and the continuation to run after it.
-- The RC analogue of 'Wok.Interp.Value.JoinPoint'.
data RCJoin = RCJoin RCScope [Binder] Expr RCKont

-- ---------------------------------------------------------------------------
-- Continuation stack

-- | The continuation stack for the RC machine. Mirrors
-- 'Wok.Interp.Value.Kont' but for the no-handler fragment: there are no
-- effect-handler frames, so 'KHandle' has no analogue.
data RCKont
  = KDoneRC
  | KLetRC Binder Expr RCScope RCKont
    -- ^ bind the produced value to the 'Binder', then run the 'Expr' in scope.
  | KAppRC [RCValue] RCKont
    -- ^ over-application: apply the produced value to these extra args.

-- ---------------------------------------------------------------------------
-- Heap nodes

-- | A heap-allocated node. Each constructor corresponds to one of the three
-- kinds of storable wok value: a data constructor application, a record, or a
-- captured closure.
data Node
  = NCon Text [RCValue]
  | NRecord Text (Map Text RCValue)
  | NClosure REnv [Binder] Expr
  -- ^ The 'REnv' captures live RC values. Compare 'VClosure' in
  -- "Wok.Interp.Value" which uses a lazy @~Env@. We keep a strict counted
  -- env here; a future LetRec pass (Task 4) plans to handle recursive knots
  -- via an uncounted region rather than introducing a lazy field.
  deriving (Eq, Show)

-- ---------------------------------------------------------------------------
-- Store cells

-- | A single heap cell: a reference count and the node payload.
--
-- Region membership (the LetRec uncounted region, design invariant 4) is NOT
-- stored here but in the store-level 'stRegionOf' map, so it survives a cell's
-- free (a freed sibling's region must still be discoverable; see 'dropAddr').
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
  , stNextRegion :: Int         -- ^ next LetRec region id (>= 1)
  , stRegionOf   :: IntMap Int
    -- ^ address -> LetRec region id, for every region member. PERSISTENT: an
    -- entry is never removed (not even on free), because 'dropAddr' must still
    -- recognise an already-freed sibling as same-region to avoid double-freeing
    -- it. An address absent from this map belongs to no region.
  , stDead       :: IntSet
  , stStats      :: Stats
  }

-- | The empty store: no cells allocated, all counters at zero. Dynamic
-- addresses start at 0 (upward); static addresses start at -1 (downward);
-- region ids start at 1.
emptyStore :: Store
emptyStore = Store IM.empty 0 (-1) 1 IM.empty IS.empty (Stats 0 0 0 0)

-- | True for a static (immortal, uncounted) address. Static cells are
-- allocated by 'allocStatic' at negative addresses; the dynamic heap uses
-- non-negative addresses.
isStaticAddr :: Addr -> Bool
isStaticAddr a = a < 0

-- | True for an address that belongs to a 'LetRec' uncounted region. Such a cell
-- is owned by its group and released only by the group's single drop at scope
-- exit (see 'dropAddr' and the 'ctxExempt' note in "Wok.IR.Perceus"); it must
-- therefore NOT be consumed by application (a reference to a group member is
-- never a counted move). Region membership is read from the PERSISTENT
-- 'stRegionOf', so an already-freed sibling is still recognised.
isRegionAddr :: Addr -> Store -> Bool
isRegionAddr a s = IM.member a (stRegionOf s)

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

-- ---------------------------------------------------------------------------
-- LetRec uncounted region (design invariant 4)

-- | Allocate a local 'LetRec' group of @n@ mutually-recursive cells as one
-- UNCOUNTED REGION. Returns the @n@ reserved addresses (in order) and the
-- updated 'Store'. Each cell is allocated counted (rc = 1, bumps
-- 'stAllocs'/'stLive'/'stPeak' -- region members ARE part of the dynamic heap)
-- and tagged with a single fresh, shared, non-zero region id.
--
-- Two-phase by necessity: the closure ENVS of a mutually-recursive group
-- reference each other's addresses (the knot), which do not exist until the
-- cells are allocated. The caller therefore reserves the addresses here (with
-- placeholder nodes), builds each member's real node referencing the reserved
-- addresses, then installs them with 'writeRegionCell'. Because the intra-group
-- edges all point inside the shared region, 'dropAddr' never traverses them, so
-- the knot is uncounted and the group is dropped as a unit.
--
-- The placeholder node is overwritten by 'writeRegionCell' before the group is
-- ever observed; it exists only so 'deref' on a reserved address is well-formed.
allocLetRecGroup :: Int -> Store -> ([Addr], Store)
allocLetRecGroup n s0 =
  let region = stNextRegion s0
      s1     = s0 { stNextRegion = region + 1 }
  in go region n [] s1
  where
    go _      0 addrs s = (reverse addrs, s)
    go region k addrs s =
      let a    = stNext s
          st   = stStats s
          live = stLive st + 1
          st'  = st { stAllocs = stAllocs st + 1
                    , stLive   = live
                    , stPeak   = max (stPeak st) live }
          s'   = s { stCells    = IM.insert a (Cell 1 regionPlaceholder) (stCells s)
                   , stRegionOf = IM.insert a region (stRegionOf s)
                   , stNext     = a + 1
                   , stStats    = st' }
      in go region (k - 1) (a : addrs) s'

-- | A never-observed placeholder for a reserved region cell, overwritten by
-- 'writeRegionCell' before the group runs.
regionPlaceholder :: Node
regionPlaceholder = NCon (Tx.pack "<uninstalled-letrec>") []

-- | Overwrite the node at a reserved region address, PRESERVING the cell's
-- reference count (and, implicitly, its 'stRegionOf' membership). Used to
-- install a group member's real closure node after the group's addresses were
-- reserved. It is a programmer error to call this on an address not produced by
-- 'allocLetRecGroup'; doing so would clobber an ordinary cell's rc.
writeRegionCell :: Addr -> Node -> Store -> Store
writeRegionCell a n s =
  case IM.lookup a (stCells s) of
    Just c  -> s { stCells = IM.insert a c { cNode = n } (stCells s) }
    Nothing -> s   -- unreachable for a freshly-reserved region addr; leave intact

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
                  -- Intra-region edges are UNCOUNTED: when freeing a LetRec
                  -- group member, do NOT enqueue a boxed child that points at a
                  -- sibling in the SAME region. That sibling is freed by its own
                  -- external drop (the group is dropped as a unit); traversing
                  -- the edge here would double-free it. Region membership is read
                  -- from the persistent 'stRegionOf', so an already-freed sibling
                  -- is still recognised.
                  let kids = countedChildren a (cNode c) s
                      st   = stStats s
                      s'   = s { stCells = IM.delete a (stCells s)
                               , stDead  = IS.insert a (stDead s)
                               , stStats = st { stFrees = stFrees st + 1
                                              , stLive  = stLive  st - 1 } }
                  in go (kids ++ rest) s'
              | otherwise ->
                  go rest s { stCells = IM.insert a c { cRc = cRc c - 1 } (stCells s) }

-- | The boxed children to recurse into when freeing the cell at @parent@. A
-- child edge is skipped (uncounted) when @parent@ is a region member AND the
-- child's target is in the SAME region: that is an intra-group recursive
-- reference (the closure-env knot). All other edges (to a non-region cell, a
-- different region, a static cell, or a literal) are counted and recursed into
-- as usual.
--
-- Region membership is read from the PERSISTENT 'stRegionOf', so an
-- already-freed sibling is still recognised as same-region and correctly
-- skipped (its cell is gone, but its region entry remains). A child whose target
-- is not a same-region sibling is left in the list, so an absent/dead non-region
-- target still surfaces the dangling/double-free trap rather than being silently
-- dropped.
countedChildren :: Addr -> Node -> Store -> [Addr]
countedChildren parent n s =
  case IM.lookup parent (stRegionOf s) of
    Nothing     -> boxedChildren n   -- parent belongs to no region: count all edges
    Just region -> filter (not . sameRegionSibling region) (boxedChildren n)
  where
    sameRegionSibling region a = IM.lookup a (stRegionOf s) == Just region

-- | Collect all 'Addr' values directly reachable from a 'Node' via 'RVBox'.
boxedChildren :: Node -> [Addr]
boxedChildren n = [ a | RVBox a <- nodeValues n ]

-- | Flatten all 'RCValue' fields of a 'Node' into a list.
nodeValues :: Node -> [RCValue]
nodeValues (NCon _ vs)        = vs
nodeValues (NRecord _ m)      = Map.elems m
nodeValues (NClosure env _ _) = Map.elems env

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
renderRCValue _ (RVLit l) = Right (renderLit l)
renderRCValue s (RVBox a) = do
  c <- deref a s
  renderNode s (cNode c)

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
renderNode _ NClosure{} = Right (Tx.pack "<closure>")

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
      RVLit _ -> improper acc v
    improper acc v = do
      rest <- renderRCValue s v
      Right (Tx.pack "[" <> Tx.intercalate (Tx.pack ", ") (reverse acc)
               <> Tx.pack " | " <> rest <> Tx.pack "]")

-- | If the tag is @TupleN@, return N.
tupleArity :: Text -> Maybe Int
tupleArity t = case Tx.stripPrefix (Tx.pack "Tuple") t of
  Just rest | not (Tx.null rest), Tx.all (`elem` ['0' .. '9']) rest -> Just (read (Tx.unpack rest))
  _ -> Nothing
