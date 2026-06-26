module Wok.Interp.RC.Prim
  ( rcPrimTable
  , stringBytes
  ) where

import Control.Monad (foldM)
import Control.Monad.IO.Class (liftIO)
import Control.Monad.Trans.Except (throwE)
import Data.Bits ((.&.))
import qualified Data.ByteString as BS
import Data.Word (Word8)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as Tx
import qualified Data.Text.Encoding as TxEnc
import Wok.IR.Anf (Lit (..))
import qualified Wok.IR.PrimNames as PN
import qualified Wok.Interp.RC.Heap as H
import Wok.Interp.RC.Value
  ( RC, liftRC, RCPrim (..), RCPrimResult (..), RCPrimTable, RCValue (..)
  , Addr (..), HeapBackend (..)
  , Node (..), Cell (..), Store (..), alloc, deref, incref, dropAddr, dropReuse, writeNode
  , continuationOwned, valueChildren
  , atIndex, setAt, arrayLenOf, arrayUnique, arraySetSlotInPlace, encodeSlotC
  , maxInlineStr, allocNStringView, wokStringTag )
import Wok.Interp.Value (RuntimeError (..))
import Wok.Runtime.StringZilla (szFind, szHash, szEditDistance)

-- | The RC primitive table. Mirrors the reference 'Wok.Interp.Prim.primTable'
-- (arithmetic, comparison, boolean, apply) operating on 'RVLit'/'RVBox', PLUS
-- the two compiler-internal RC intrinsics @__rc_dup@/@__rc_drop@ that thread the
-- owned 'Store'. Effect/coro/scheduler prims are deliberately absent: M1 is the
-- no-handler fragment.
--
-- Booleans in wok are the boxed nullary constructors @True@/@False@, so a
-- boolean operand arrives as an 'RVBox' to an @NCon "True"/"False" []@ and a
-- boolean RESULT must be allocated on the heap. The comparison/boolean prims are
-- therefore store-threading (not pure), unlike the reference where 'Value'
-- carries the constructor inline.
-- | The RC primitive table, keyed by @(module, name)@. The compiler-SYNTHESIZED
-- RC intrinsics @__rc_dup@/@__rc_drop@/@__rc_drop_reuse@ are dispatched via
-- 'AVar'-with-hint (never 'APrim'), so they are registered under the empty-module
-- sentinel @("", name)@ and looked up via the hint path in the machine.
rcPrimTable :: RCPrimTable
rcPrimTable = Map.fromList [ ((mn, rpName p), p) | (mn, p) <- taggedRcPrims ]

-- | All RC primitives tagged with their defining module.
taggedRcPrims :: [(Text, RCPrim)]
taggedRcPrims =
  map (PN.stdBaseModule,)    rcBasePrims
  ++ map (Tx.pack "",)          rcIntrinsics   -- hint-dispatched; empty module sentinel
  ++ map (PN.stdControlModule,) rcControlPrims
  ++ map (PN.stdArrayModule,)   rcArrayPrims
  ++ map (PN.stdStringModule,)  rcStringPrims

rcBasePrims :: [RCPrim]
rcBasePrims =
  [ arith   (Tx.pack "+")   (+)
  , arith   (Tx.pack "-")   (-)
  , arith   (Tx.pack "*")   (*)
  , divLike (Tx.pack "/")
  , divLike (Tx.pack "div")
  , modLike (Tx.pack "mod")
  , cmp     (Tx.pack "eqU64") (==)
  , cmp     (Tx.pack "eqU32") (==)
  , u32Conv
  , boolOp  (Tx.pack "&&") (&&)
  , boolOp  (Tx.pack "||") (||)
  , dollarP
  , eqString
  ]

-- | Compiler-SYNTHESIZED RC intrinsics. These reach the machine via 'AVar'-with-hint
-- (not 'APrim'), so the dispatch uses an empty-module sentinel as the table key.
rcIntrinsics :: [RCPrim]
rcIntrinsics =
  [ rcDup
  , rcDrop
  , rcDropReuse
  ]

rcControlPrims :: [RCPrim]
rcControlPrims =
  [ contCellNew
  , contStore
  , contTake
  ]

rcArrayPrims :: [RCPrim]
rcArrayPrims =
  [ arrayNew
  , arrayFromList
  , arrayToList
  , arrayIndex
  , arrayLength
  , arraySet
  , arrayResize
  ]

rcStringPrims :: [RCPrim]
rcStringPrims =
  [ stringLength
  , stringIndex
  , stringByteLength
  , stringByteAt
  , stringAppend
  , stringIndexOfFromRaw
  , stringHash
  , stringEditDistance
  , stringSlice
  , stringByteSlice
  ]

-- ---------------------------------------------------------------------------
-- The RC intrinsics

-- | @__rc_dup x@ increfs the handle and returns the SAME handle; a no-op on a
-- literal (literals are never counted). Threads the store.
rcDup :: RCPrim
rcDup = RCPrim PN.rcDupName 1 [] $ \args s -> case args of
  [v@(RVBox a)] -> do s' <- incref a s; pure (PRDone v, s')
  [v@(RVLit _)] -> pure (PRDone v, s)
  -- A shared-env recursive member: its single counted child is the env cell
  -- ('valueChildren'). Dup increfs the env (a no-op on the static empty-env
  -- sentinel); the group code label is static and never counted.
  [v@(RVRecMember _ _ e)] -> do s' <- incref e s; pure (PRDone v, s')
  -- A named effect-instance handle: an UNBOXED identity pair owning no counted
  -- cell ('valueChildren' is empty), so dup is inert (same as 'dropBoxed'). This
  -- fires once resume runs a captured frame that drops/dups the @self@ handle
  -- (M2b-1 Task 5); the abort path never reached it because the arm returned
  -- before the captured frame ran.
  [v@(RVInst _ _)] -> pure (PRDone v, s)
  _             -> throwE (ArityError (Tx.pack "__rc_dup"))

-- | @__rc_drop x@ decrefs the handle (freeing at zero, recursively) and returns
-- unit; a no-op on a literal. Threads the store.
rcDrop :: RCPrim
rcDrop = RCPrim PN.rcDropName 1 [] $ \args s -> case args of
  [RVBox a]   -> do s' <- dropAddr a s; pure (PRDone (RVLit LUnit), s')
  [RVLit _]   -> pure (PRDone (RVLit LUnit), s)
  -- A shared-env recursive member: drop decrefs the env (a no-op on the static
  -- empty-env sentinel), freeing it at zero and cascading its owned captures.
  [RVRecMember _ _ e] -> do s' <- dropAddr e s; pure (PRDone (RVLit LUnit), s')
  -- A named effect-instance handle: an UNBOXED identity pair owning no counted
  -- cell ('valueChildren' is empty), so drop is inert (same as 'dropBoxed'). This
  -- fires once resume runs a captured frame that drops the @self@/instance handle
  -- (M2b-1 Task 5); the abort path never reached it because the arm returned
  -- before the captured frame ran.
  [RVInst _ _] -> pure (PRDone (RVLit LUnit), s)
  _           -> throwE (ArityError (Tx.pack "__rc_drop"))

-- | @__rc_drop_reuse x@ is the FBIP @drop_reuse@ intrinsic (spec §5.2): the
-- counted analogue of @__rc_drop@ that, instead of unit, returns a reuse TOKEN
-- ('RVReuse'). 'dropReuse' releases the cell's children and, when the decrement
-- hits zero (unique), RETAINS the freed shell as the token (else a NULL token).
-- The token is the @rpFn@ result, consumed downstream by an 'RReuseCon'. A
-- literal / uncounted handle is never a donor, so it yields @RVReuse Nothing@.
rcDropReuse :: RCPrim
rcDropReuse = RCPrim PN.rcDropReuseName 1 [] $ \args s -> case args of
  [RVBox a]   -> do (tok, s') <- dropReuse a s; pure (PRDone tok, s')
  [RVLit _]   -> pure (PRDone (RVReuse Nothing), s)
  -- A shared-env recursive member behaves like a boxed handle: drop-reuse its env
  -- (a no-op on the static empty-env sentinel) and surface whatever token results.
  [RVRecMember _ _ e] -> do (tok, s') <- dropReuse e s; pure (PRDone tok, s')
  -- A named effect-instance handle owns no counted cell, so it is never a donor.
  [RVInst _ _] -> pure (PRDone (RVReuse Nothing), s)
  _           -> throwE (ArityError (Tx.pack "__rc_drop_reuse"))

-- ---------------------------------------------------------------------------
-- The M3 stored-continuation cell primitives (spec §4.1)
--
-- A continuation CELL is an affine one-shot park slot ('NContCell'): empty
-- ('Nothing') or holding exactly one continuation addr ('Just a'). The three
-- prims below realise the MOVE discipline that is the soundness floor (spec
-- §4.2): @__cont_store@ moves the continuation IN (no incref --- the cell holds
-- the single counted edge the consumed binder used to), @__cont_take@ moves it
-- OUT (no incref --- the cell is emptied, the addr's rc stays 1), and resuming
-- the taken addr goes through @enterRC@'s 'NCont' arm whose 'moveOutCont'
-- asserts @rc == 1@. NEVER a 'dup' across store/take.
--
-- On the RC machine the cell is genuinely mutable: 'writeNode' transitions it
-- empty -> holding -> empty in place, preserving the cell's identity and
-- refcount across the fill/empty. The reference machine ("Wok.Interp.Prim")
-- mirrors the same observable semantics with an immutable @VCon "ContCell" [k]@
-- wrapper (sound because usage is affine: the cell is filled once and emptied
-- once), so the differential oracle has both sides.

-- | @__cont_cell_new ()@ allocates a fresh EMPTY continuation cell and returns
-- its boxed handle. The cell starts at rc 1 like any allocation; the handle is
-- owned by its binder (the scheduler baton slot) and dropped at last use.
contCellNew :: RCPrim
contCellNew = RCPrim PN.contCellNewName 1 [] $ \args s -> case args of
  -- The argument is the bodyless-extern's single parameter, EXPECTED to be unit; we
  -- ignore its value. It is a MOVE into this prim, so consume it with 'dropBoxed' to
  -- avoid leaking it if it has a counted representation.
  --
  -- ARG-CONSUME (code-review #15). 'dropBoxed' handles ANY representation safely: it
  -- is a no-op on the unboxed 'RVLit' 'LUnit' (today's @()@ rep, so it matches the
  -- reference machine, which ignores the arg) AND correctly frees a boxed nullary
  -- @()@ con should the unit representation ever change. We deliberately do NOT
  -- hard-reject a non-'RVLit'-'LUnit' arg here: that would over-narrow relative to
  -- the reference 'Wok.Interp.Prim' '__cont_cell_new' (which ignores its arg) and
  -- false-reject a boxed unit in the differential oracle. Consuming whatever is
  -- passed is both leak-free and reference-agreeing.
  [u] -> do
    s1 <- dropBoxed u s
    (a, s2) <- alloc (NContCell Nothing) s1
    pure (PRDone (RVBox a), s2)
  _ -> throwE (ArityError (Tx.pack "__cont_cell_new"))

-- | @__cont_store cell k@ MOVES the continuation @k@ into @cell@: it writes
-- @NContCell (Just kAddr)@ at the cell, WITHOUT increfing @kAddr@ (the binder
-- @k@ is consumed; the cell now holds the single counted edge the binder used
-- to hold, so the continuation's rc stays 1) and RETURNS the (now-filled) cell
-- handle. The cell handle is a BORROW here --- the RC cell is mutated in place,
-- so returning the SAME @RVBox cellAddr@ is a re-borrow of the unchanged handle
-- (no incref, no consume).
--
-- WHY @store@ returns the cell (Design A): the reference oracle models the cell
-- as an IMMUTABLE @VCon@ (no in-place fill), so it must thread the FILLED cell
-- forward as a value; for the differential to agree, both machines return the
-- filled cell and the program @__cont_take@s the RETURNED handle. On the RC
-- machine the returned handle is identical to the argument (mutation happened in
-- place), which keeps the move-discipline exact.
--
-- Soundness: storing into a cell that is ALREADY holding a continuation would
-- overwrite (leak/double-own) the previous one; the affine analysis + the
-- one-shot empty->holding->empty discipline make that unreachable, but we reject
-- it LOUDLY rather than silently corrupt the heap.
contStore :: RCPrim
contStore = RCPrim PN.contStoreName 2 [] $ \args s -> case args of
  [RVBox cellAddr, RVBox kAddr] -> do
    c <- deref cellAddr s
    case cNode c of
      NContCell Nothing -> do
        -- M3 carrier-wall (cycle-prevention) check, OPERATIONAL form (spec §4.3
        -- "checked, not assumed"). A counted cycle @cell -> NCont -> cell@ forms
        -- iff the continuation being parked counted-reaches its own cell --- i.e.
        -- @cellAddr@ is in the captured prefix's owned set ('continuationOwned').
        -- Dropping such a cell would re-enter the cell through the cascade and
        -- double-free it (verified: 'continuationOwned' returns the cell, the
        -- cell-drop cascade revisits it, 'dropAddr's 'stDead' guard raises a loud
        -- double-free).
        --
        -- SCOPE OF THIS CHECK (code-review #4, empirically resolved). This is a
        -- SINGLE-LEVEL backstop: it tests only whether THIS cell is in THIS
        -- continuation's OWN owned set (one hop). It does NOT walk transitively, so
        -- it does NOT by itself catch an N-cell cycle (cellA holds contA owning
        -- cellB; cellB holds contB owning cellA): each leg's single-level test
        -- passes (cellA is not in contA's owned set; it is cellB that is) yet the
        -- ring is closed and dropping any cell double-frees. The COMPLETE cycle
        -- wall is therefore NOT this runtime check but the STATIC fresh-local rule
        -- ('Wok.IR.Reachable.m3CarrierWallViolations'): the boundary guard admits a
        -- store ONLY into a cell freshly bound by @__cont_cell_new@ in the store's
        -- OWN arm scope. A fresh-local cell is created INSIDE the op-arm body (below
        -- the op, under @kBelow@), so it can never appear in ANY captured
        -- continuation's owned set (which holds only values live ABOVE the op) ---
        -- and a cell IN an owned set is, by construction, a non-fresh
        -- (enclosing/param/op-arg) cell the static rule REJECTS. So every multi-cell
        -- cycle needs at least one non-fresh cell, which H1 walls statically; no
        -- fresh-local-cell cycle is constructible (verified empirically: a 2-cell
        -- cycle built from fresh-local cells is impossible because the second cell
        -- must be an enclosing value of the first store, which H1 rejects --- see
        -- 'rcM3TwoCellCycleSubsumedTests'). The transitive walk a multi-cell cycle
        -- would otherwise demand is thus DEAD CODE under H1 and deliberately omitted.
        --
        -- This runtime check remains as the operational backstop on the
        -- single-level shape (the M2b-1 nested-param route, 'rcM3CarrierWallTests').
        -- It is NOT one of three independent complete cycle walls: the COMPLETE
        -- wall is the static fresh-local rule above. This is its single-level
        -- operational backstop, and the type checker's OccursCheck (a generic
        -- infinite-type check, NOT an M3-specific carrier check) INCIDENTALLY
        -- blocks the direct surface self-store (the cell's answer type would have
        -- to contain the continuation's own type). Reject LOUDLY rather than
        -- silently corrupt the heap.
        kc <- deref kAddr s
        case cNode kc of
          NCont prefix _
            | cellAddr `elem` continuationOwned prefix ->
                throwE (PrimError (Tx.pack
                  ("__cont_store: stored continuation counted-reaches its own cell \
                   \(would form an RC cycle); carrier-wall violation (M3 §4.3); addr "
                     <> show cellAddr)))
          _ -> pure ()
        -- MOVE-VS-BORROW PIN (code-review #13). The result MUST be the SAME cell
        -- address that was passed in: @__cont_store@ MOVES the continuation into the
        -- existing cell in place ('writeNode' preserves the cell's identity and rc)
        -- and RE-BORROWS the unchanged @cellAddr@ handle WITHOUT an incref, while
        -- Perceus MOVES the @cell@ operand (consumes the binder). Soundness rests on
        -- the returned handle being the sole owner of that one cell edge --- i.e. the
        -- result is the operand's own address, not a fresh allocation.
        --
        -- POST-CONDITION (not a tautology). We do NOT re-assert that @result@ is
        -- @RVBox cellAddr@ (it is, by the @let@ a line above --- a dead guard). The
        -- load-bearing invariant is that the WRITE landed IN PLACE: after 'writeNode',
        -- dereferencing the SAME @cellAddr@ must now yield @NContCell (Just kAddr)@.
        -- This catches a real 'writeNode' regression (wrong addr written, node not
        -- updated, or the move not recorded), which the result-identity check could
        -- never see. The cell's identity and rc are unchanged (the move re-borrows
        -- the operand handle), so returning @RVBox cellAddr@ is sound by construction.
        s' <- writeNode cellAddr (NContCell (Just kAddr)) s
        c' <- deref cellAddr s'
        case cNode c' of
          NContCell (Just a) | a == kAddr -> pure (PRDone (RVBox cellAddr), s')
          other ->
            throwE (PrimError (Tx.pack
              ("__cont_store: in-place store post-condition violated (#13; writeNode did \
               \not land NContCell (Just " <> show kAddr <> ") at cell addr "
               <> show cellAddr <> "); got node " <> show other)))
      NContCell (Just _) ->
        throwE (PrimError (Tx.pack
          ("__cont_store: cell already holds a continuation (one-shot violation); addr "
             <> show cellAddr)))
      _ -> throwE (PrimError (Tx.pack
             ("__cont_store: not a continuation cell; addr " <> show cellAddr)))
  [RVBox _, k] ->
    -- The continuation must be a boxed NCont handle (the op-arm resume binder).
    -- A literal/closure/instance in this slot is an internal IR/elaboration error.
    throwE (PrimError (Tx.pack "__cont_store: continuation argument is not a boxed handle: "
                       <> renderArg k))
  _ -> throwE (ArityError (Tx.pack "__cont_store"))

-- | @__cont_take cell@ MOVES the continuation OUT of @cell@: it reads the held
-- addr, empties the cell (@NContCell Nothing@), and returns the addr boxed,
-- WITHOUT increfing it (the cell no longer counts it; the addr's rc stays 1).
-- Resuming the result goes through @enterRC@'s 'NCont' arm, whose 'moveOutCont'
-- asserts @rc == 1@ (the soundness floor). Taking from an EMPTY cell is a loud
-- error (a take of an already-taken or never-filled cell).
contTake :: RCPrim
contTake = RCPrim PN.contTakeName 1 [] $ \args s -> case args of
  [RVBox cellAddr] -> do
    c <- deref cellAddr s
    case cNode c of
      NContCell (Just kAddr) -> do
        s' <- writeNode cellAddr (NContCell Nothing) s
        pure (PRDone (RVBox kAddr), s')
      NContCell Nothing ->
        throwE (PrimError (Tx.pack
          ("__cont_take: cell is empty (taken twice or never stored); addr " <> show cellAddr)))
      _ -> throwE (PrimError (Tx.pack
             ("__cont_take: not a continuation cell; addr " <> show cellAddr)))
  _ -> throwE (ArityError (Tx.pack "__cont_take"))

-- | Render an unexpected non-box continuation argument for an error message.
renderArg :: RCValue -> Text
renderArg (RVLit _)        = Tx.pack "literal"
renderArg (RVBox _)        = Tx.pack "box"
renderArg RVRecMember{}    = Tx.pack "closure handle"
renderArg (RVInst _ _)     = Tx.pack "instance handle"
renderArg (RVReuse _)      = Tx.pack "reuse token"

-- ---------------------------------------------------------------------------
-- Pure value prims (store-passthrough)

mkPrim :: Text -> Int -> ([RCValue] -> Either RuntimeError RCPrimResult) -> RCPrim
mkPrim name arity fn = RCPrim name arity [] (\args s -> (\r -> (r, s)) <$> liftRC (fn args))

asInt :: RCValue -> Either RuntimeError Integer
asInt (RVLit (LInt n)) = Right n
asInt _ = Left (PrimError (Tx.pack "expected U64"))

arith :: Text -> (Integer -> Integer -> Integer) -> RCPrim
arith name op = mkPrim name 2 $ \args -> case args of
  [a, b] -> do x <- asInt a; y <- asInt b; Right (PRDone (RVLit (LInt (op x y))))
  _      -> Left (ArityError name)

-- Both (/) and div use Haskell's `div` (correct for wok's non-negative U64; v1
-- does not model wrapping). Division/modulo by zero is a 'PrimError'.
divLike :: Text -> RCPrim
divLike name = mkPrim name 2 $ \args -> case args of
  [a, b] -> do
    x <- asInt a; y <- asInt b
    if y == 0 then Left (PrimError (name <> Tx.pack ": division by zero"))
              else Right (PRDone (RVLit (LInt (x `div` y))))
  _ -> Left (ArityError name)

modLike :: Text -> RCPrim
modLike name = mkPrim name 2 $ \args -> case args of
  [a, b] -> do
    x <- asInt a; y <- asInt b
    if y == 0 then Left (PrimError (name <> Tx.pack ": modulo by zero"))
              else Right (PRDone (RVLit (LInt (x `mod` y))))
  _ -> Left (ArityError name)

-- | (u32) : narrow a U64 to U32 (identity in v1; no wrapping modelled).
u32Conv :: RCPrim
u32Conv = mkPrim (Tx.pack "u32") 1 $ \args -> case args of
  [a] -> do _ <- asInt a; Right (PRDone a)
  _   -> Left (ArityError (Tx.pack "u32"))

-- | ($) : apply the first argument (a function handle) to the second.
dollarP :: RCPrim
dollarP = mkPrim (Tx.pack "$") 2 $ \args -> case args of
  [f, x] -> Right (PRApply f [x])
  _      -> Left (ArityError (Tx.pack "$"))

-- ---------------------------------------------------------------------------
-- Boolean prims (store-threading: read boxed Bools, allocate the result)

-- | Deref a boxed boolean argument to a Haskell 'Bool'. Uses the interpreter-
-- monad 'deref' (not the pure 'derefPure') so a boolean cell on the C heap (a
-- @True@/@False@ @NCon@ allocated under the 'CHeap' backend, reached via a
-- 'CAddr') is read correctly. On the abstract heap the behaviour is unchanged.
asBool :: RCValue -> Store -> RC Bool
asBool (RVBox a) s = do
  c <- deref a s
  case cNode c of
    NCon t [] | t == Tx.pack "True"  -> pure True
              | t == Tx.pack "False" -> pure False
    _ -> throwE (PrimError (Tx.pack "expected Bool"))
asBool (RVLit _)           _ = throwE (PrimError (Tx.pack "expected Bool, got a literal"))
asBool RVRecMember{} _ = throwE (PrimError (Tx.pack "expected Bool, got a closure handle"))
asBool (RVInst _ _)  _ = throwE (PrimError (Tx.pack "expected Bool, got an instance handle"))
asBool (RVReuse _)   _ = throwE (PrimError (Tx.pack "expected Bool, got a reuse token"))

-- | Allocate a boxed boolean constructor and return its handle.
allocBool :: Bool -> Store -> RC (RCValue, Store)
allocBool b s = do
  let tag = if b then Tx.pack "True" else Tx.pack "False"
  (a, s') <- alloc (NCon tag []) s
  pure (RVBox a, s')

-- | Comparison: U64 operands, freshly-allocated boxed Bool result.
cmp :: Text -> (Integer -> Integer -> Bool) -> RCPrim
cmp name op = RCPrim name 2 [] $ \args s -> case args of
  [a, b] -> do
    x <- liftRC (asInt a); y <- liftRC (asInt b)
    (v, s') <- allocBool (op x y) s
    pure (PRDone v, s')
  _ -> throwE (ArityError name)

-- | Boolean operator: boxed Bool operands, freshly-allocated boxed Bool result.
--
-- The Perceus pass treats 'RApp' operands as MOVES (ownership is transferred
-- into the callee), so this prim must CONSUME its two operand cells. We read
-- both booleans while they are still live, then 'dropBoxed' each operand
-- (decref, freeing at zero) before allocating the fresh result. Omitting the
-- drops leaks both boxed-Bool operand cells.
boolOp :: Text -> (Bool -> Bool -> Bool) -> RCPrim
boolOp name op = RCPrim name 2 [] $ \args s -> case args of
  [a, b] -> do
    x <- asBool a s; y <- asBool b s
    s1 <- dropBoxed a s
    s2 <- dropBoxed b s1
    (v, s3) <- allocBool (op x y) s2
    pure (PRDone v, s3)
  _ -> throwE (ArityError name)

-- | Drop a moved-in operand: decref a boxed handle (freeing recursively at
-- zero); a no-op on a literal (literals are never counted). Threads the store.
dropBoxed :: RCValue -> Store -> RC Store
dropBoxed (RVBox a)          s = dropAddr a s
dropBoxed (RVLit _)          s = pure s
dropBoxed (RVRecMember _ _ e) s = dropAddr e s
dropBoxed (RVInst _ _)       s = pure s
-- A reuse token owns no counted child ('valueChildren (RVReuse _) = []'), so a
-- drop of one is inert --- consistent with its affine handling everywhere else.
dropBoxed (RVReuse _)        s = pure s

-- ---------------------------------------------------------------------------
-- Array primitives (Slice A, spec §4)
--
-- These seven prims implement the complete RC accounting for the boxed fixed-size
-- array 'NArray'. Each prim OWNS (consumes) its arguments (operands move in) and
-- must drop or transfer them into the result. RC deltas per op:
--   new/fromList/set/resize  = +1 alloc
--   index/length             = 0 alloc
--   toList                   = +N alloc (N Cons cells + 1 Nil)
--
-- Nil is a nullary constructor: 'alloc (NCon "Nil" [])' returns an 'Inline'
-- immediate (no counted cell, no alloc stat bump). The actual delta for toList
-- is +N Cons cells; the Nil is stat-invisible.

-- ---------------------------------------------------------------------------
-- Array prim helpers

-- | Incref all counted children of an 'RCValue' once. Mirrors @__rc_dup@ over a
-- value-level reference: for 'RVBox a' this is 'incref a'; for 'RVLit'/'RVInst'
-- this is a no-op (no counted children). Used to give the array its own ref to
-- each element.
dupValue :: RCValue -> Store -> RC Store
dupValue v s = foldM (flip incref) s (valueChildren v)

-- | Decref all counted children of an 'RCValue' once (freeing at zero). Mirrors
-- @__rc_drop@ over a value-level reference. Used to drop a value that is owned
-- but should not enter the result.
dropValue :: RCValue -> Store -> RC Store
dropValue v s = foldM (flip dropAddr) s (valueChildren v)

-- | Apply 'dupValue' k times; no-op for k <= 0.  Used by 'new' and 'resize' to
-- hand k owned references to a fill value (the prim already holds one; 'dupN
-- (k-1)' supplies the remaining k-1).
dupN :: Int -> RCValue -> Store -> RC Store
dupN k v s
  | k <= 0    = pure s
  | otherwise = foldM (\st _ -> dupValue v st) s [(1 :: Int) .. k]

-- | Extract a non-negative integer index from a 'U64' literal argument.
asIndex :: RCValue -> Either RuntimeError Int
asIndex (RVLit (LInt n))
  | n < 0                           = Left (PrimError (Tx.pack "Array: negative index"))
  | n > toInteger (maxBound :: Int) = Left (PrimError (Tx.pack "Array: index out of range"))
  | otherwise                       = Right (fromInteger n)
asIndex _ = Left (PrimError (Tx.pack "Array: expected U64 index"))

-- | Deref an array handle and return its element list. Fails with 'PrimError'
-- if the value is not a boxed 'NArray'.
arrayElems :: RCValue -> Store -> RC [RCValue]
arrayElems (RVBox a) s = do
  c <- deref a s
  case cNode c of
    NArray vs -> pure vs
    _         -> throwE (PrimError (Tx.pack "Array: not an array"))
arrayElems _ _ = throwE (PrimError (Tx.pack "Array: not an array"))

-- ---------------------------------------------------------------------------
-- The seven Array prims

-- | @new k v@: allocate an array of length k, all slots filled with v. The
-- prim owns one ref to v on entry; it arranges k refs into the result.
-- RC: if k == 0, drop v; else incref v ×(k-1), alloc. Net +1 alloc.
arrayNew :: RCPrim
arrayNew = RCPrim PN.arrayNewName 2 [] $ \args s -> case args of
  [kv, v] -> do
    k <- liftRC (asIndex kv)
    if k <= 0
      then do
        s1 <- dropValue v s
        (a, s2) <- alloc (NArray []) s1
        pure (PRDone (RVBox a), s2)
      else do
        -- We own 1 ref; array needs k; incref k-1 more.
        s1 <- dupN (k - 1) v s
        (a, s2) <- alloc (NArray (replicate k v)) s1
        pure (PRDone (RVBox a), s2)
  _ -> throwE (ArityError (Tx.pack "Array.new"))

-- | @fromList xs@: build an array from a wok Cons/Nil list. Each element is
-- incref'd once into the array (transfer). The list is then dropped; if unique
-- the spine is freed and original element refs released (net zero per element).
-- RC: +1 alloc (the NArray cell).
arrayFromList :: RCPrim
arrayFromList = RCPrim PN.arrayFromListName 1 [] $ \args s -> case args of
  [xs] -> do
    (elems, s1) <- collectList xs s
    (na, s2)    <- alloc (NArray elems) s1
    s3          <- dropValue xs s2
    pure (PRDone (RVBox na), s3)
  _ -> throwE (ArityError (Tx.pack "Array.fromList"))

-- | @toList arr@: convert array to a Cons/Nil list. Each element is incref'd
-- into its Cons cell; the array is dropped (cascade releases arr's element refs
-- and the cell). RC: +N alloc (N Cons cells; Nil is inline, stat-invisible).
arrayToList :: RCPrim
arrayToList = RCPrim PN.arrayToListName 1 [] $ \args s -> case args of
  [arr@(RVBox a)] -> do
    vs        <- arrayElems arr s
    (lst, s1) <- buildList vs s
    s2        <- dropAddr a s1
    pure (PRDone lst, s2)
  _ -> throwE (ArityError (Tx.pack "Array.toList"))

-- | @index arr i@: bounds-checked element lookup. Incref the element (result
-- owns it); drop the array (cascade frees the rest). RC: 0 alloc.
arrayIndex :: RCPrim
arrayIndex = RCPrim PN.arrayIndexName 2 [] $ \args s -> case args of
  [arr@(RVBox a), iv] -> do
    i  <- liftRC (asIndex iv)
    vs <- arrayElems arr s
    case atIndex i vs of
      Nothing -> throwE (PrimError (Tx.pack "Array.index: out of bounds"))
      Just el -> do
        s1 <- dupValue el s
        s2 <- dropAddr a s1
        pure (PRDone el, s2)
  _ -> throwE (ArityError (Tx.pack "Array.index"))

-- | @length arr@: return the element count; consume the array. RC: 0 alloc.
arrayLength :: RCPrim
arrayLength = RCPrim PN.arrayLengthName 1 [] $ \args s -> case args of
  [arr@(RVBox a)] -> do
    vs <- arrayElems arr s
    s1 <- dropAddr a s
    pure (PRDone (RVLit (LInt (toInteger (length vs)))), s1)
  _ -> throwE (ArityError (Tx.pack "Array.length"))

-- | @set arr i v@: in-place update when the array is uniquely owned and the new
-- value is C-encodable; copy-on-write otherwise.
--
-- Fast path (rc == 1 AND 'encodeSlotC' succeeds): mutate slot i in place, return
-- the SAME array handle (0 array alloc). The old element is returned by
-- 'arraySetSlotInPlace' and then dropped by the caller.
--
-- Slow path (shared or non-encodable): build a new element list with slot i
-- replaced by v (moved in) and all other slots incref'd. Alloc a new array.
-- Drop the input (cascade releases old arr[i]; survivors net 0). RC: +1 alloc.
arraySet :: RCPrim
arraySet = RCPrim PN.arraySetName 3 [] $ \args s -> case args of
  [arr@(RVBox a), iv, v] -> do
    i <- liftRC (asIndex iv)
    n <- arrayLenOf a s
    if i >= n
      then throwE (PrimError (Tx.pack "Array.set: out of bounds"))
      else do
        unique <- arrayUnique a s
        -- Shared gate (identical on both backends): in-place only when the array
        -- is uniquely owned AND v is C-encodable. encodeSlotC is pure and computed
        -- exactly once here; a non-encodable v (Int >= 2^63) degrades to copy on
        -- BOTH backends, preserving the oracle invariant.
        case if unique then encodeSlotC v else Nothing of
          Just enc -> do
            -- In-place fast path: 0 array alloc, survivors untouched.
            (oldEl, s1) <- arraySetSlotInPlace enc a i v s
            s2          <- dropValue oldEl s1
            pure (PRDone (RVBox a), s2)
          Nothing -> do
            -- Copy-on-write: decode the elements (only needed here), replace slot
            -- i (v moved in), incref each survivor, alloc the new array, drop input.
            vs <- arrayElems arr s
            let newVs = setAt i v vs
            s1 <- foldM
                    (\st (j, el) -> if j == i then pure st else dupValue el st)
                    s
                    (zip [0 :: Int ..] vs)
            (na, s2) <- alloc (NArray newVs) s1
            s3 <- dropAddr a s2
            pure (PRDone (RVBox na), s3)
  _ -> throwE (ArityError (Tx.pack "Array.set"))

-- | @resize arr m fill@: copy-on-write resize to length m. Kept prefix (length
-- t = min(m,n)) is incref'd; fill gets k = max(0,m-n) refs. Alloc new array.
-- Drop input (cascade: kept prefix nets 0, truncated tail released). RC: +1 alloc.
arrayResize :: RCPrim
arrayResize = RCPrim PN.arrayResizeName 3 [] $ \args s -> case args of
  [arr@(RVBox a), mv, fill] -> do
    m  <- liftRC (asIndex mv)
    vs <- arrayElems arr s
    let n    = length vs
        t    = max 0 (min m n)
        k    = max 0 (m - n)
        kept = take t vs
        newVs = kept ++ replicate k fill
    -- Incref each kept element (one copy into the new array).
    s1 <- foldM (flip dupValue) s kept
    -- fill: we own 1 ref; new array needs k refs total.
    --   k == 0: drop fill (not needed).
    --   k >= 1: incref fill k-1 times (we contribute the last ref by moving in).
    s2 <- if k <= 0
            then dropValue fill s1
            else dupN (k - 1) fill s1
    (na, s3) <- alloc (NArray newVs) s2
    -- Consume input: kept prefix nets 0; truncated tail [t, n) is released.
    s4 <- dropAddr a s3
    pure (PRDone (RVBox na), s4)
  _ -> throwE (ArityError (Tx.pack "Array.resize"))

-- ---------------------------------------------------------------------------
-- List-walking helpers for fromList / toList

-- | Walk a Cons/Nil list, increfing each head element and collecting them.
-- The list spine is consumed separately by the caller ('dropValue xs'). Handles
-- both 'HAddr' Cons cells and 'Inline' Nil immediates (deref synthesizes the
-- NCon for an Inline addr).
collectList :: RCValue -> Store -> RC ([RCValue], Store)
collectList v s = case v of
  RVBox a -> do
    c <- deref a s
    case cNode c of
      NCon con [h, tl]
        | con == Tx.pack "Cons" -> do
            s1          <- dupValue h s
            (rest, s2)  <- collectList tl s1
            pure (h : rest, s2)
      NCon con []
        | con == Tx.pack "Nil" -> pure ([], s)
      _ -> throwE (PrimError (Tx.pack "Array.fromList: not a list"))
  _ -> throwE (PrimError (Tx.pack "Array.fromList: not a list"))

-- | Build a Cons/Nil list from an element vector, increfing each element into
-- its Cons cell. The list is built right-to-left (foldr-style). The Nil
-- terminator is an inline immediate (stat-invisible; no alloc stat bump).
buildList :: [RCValue] -> Store -> RC (RCValue, Store)
buildList vs0 s0 = do
  -- Nil is a nullary NCon; alloc routes it to allocInline (an Inline immediate,
  -- no heap cell, no alloc stat bump).
  (nilAddr, s1) <- alloc (NCon (Tx.pack "Nil") []) s0
  go vs0 (RVBox nilAddr, s1)
  where
    go [] acc = pure acc
    go (x : xs) (tl, st) = do
      (rest, st1) <- go xs (tl, st)
      st2 <- dupValue x st1
      (cell, st3) <- alloc (NCon (Tx.pack "Cons") [x, rest]) st2
      pure (RVBox cell, st3)

-- ---------------------------------------------------------------------------
-- String primitives (Slice E1, spec §5.3)
--
-- Strings are represented as 'NString ByteString' cells on the RC heap.
-- All prims CONSUME their 'RVBox' arguments (ownership moves in) and drop
-- the consumed cell with 'dropAddr' after reading, following the Array
-- convention. RC deltas per op:
--   append   : +1 alloc (new NString cell; both inputs dropped)
--   the rest : 0 alloc  (inputs dropped; no output cell)
--
-- Codepoint ops ('length', 'index') decode the UTF-8 bytes via
-- 'Data.Text.Encoding.decodeUtf8' then use 'Data.Text' operations.
-- Byte ops ('byteLength', 'byteAt') operate directly on the raw bytes.
-- 'eqString' is a byte-equality comparison.

-- | Extract the 'ByteString' from an 'NString' or 'NStringView' boxed handle.
-- For 'NStringView', reads the parent's bytes and returns an O(1)
-- 'BS.take'/'BS.drop' window (no copy). Fails if the value is not a string.
stringBytes :: RCValue -> Store -> RC BS.ByteString
stringBytes (RVBox a) s = do
  c <- deref a s
  case cNode c of
    NString bs           -> pure bs
    NStringView p off len -> do
      pb <- stringBytes (RVBox p) s
      pure (BS.take len (BS.drop off pb))
    _                    -> throwE (PrimError (Tx.pack "String: not a string"))
stringBytes _ _ = throwE (PrimError (Tx.pack "String: not a string"))

-- | Extract a non-negative string index from a U64 literal argument.
-- Mirrors 'asIndex' for Array; message uses the String domain name.
asStringIndex :: RCValue -> RC Int
asStringIndex (RVLit (LInt n))
  | n < 0                           = throwE (PrimError (Tx.pack "String: negative index"))
  | n > toInteger (maxBound :: Int) = throwE (PrimError (Tx.pack "String: index out of range"))
  | otherwise                       = pure (fromInteger n)
asStringIndex _ = throwE (PrimError (Tx.pack "String: expected U64 index"))

-- | @length s@: codepoint count. Decodes UTF-8 bytes to codepoints, counts them.
-- Consumes 's'. RC: 0 alloc.
stringLength :: RCPrim
stringLength = RCPrim PN.stringLengthName 1 [] $ \args s -> case args of
  [sv@(RVBox a)] -> do
    bs <- stringBytes sv s
    let n = Tx.length (TxEnc.decodeUtf8 bs)
    s1 <- dropAddr a s
    pure (PRDone (RVLit (LInt (toInteger n))), s1)
  _ -> throwE (ArityError (Tx.pack "String.length"))

-- | @index s i@: the i-th codepoint as a Char (0-based, bounds-checked).
-- Decodes UTF-8 bytes to codepoints. OOB raises 'PrimError'.
-- Consumes 's'; returns an unboxed 'RVLit (LChar c)'. RC: 0 alloc.
stringIndex :: RCPrim
stringIndex = RCPrim PN.stringIndexName 2 [] $ \args s -> case args of
  [sv@(RVBox a), iv] -> do
    bs <- stringBytes sv s
    i  <- asStringIndex iv
    let t = TxEnc.decodeUtf8 bs
        n = Tx.length t
    if i >= n
      then throwE (PrimError (Tx.pack "String.index: out of bounds"))
      else do
        let c = Tx.index t i
        s1 <- dropAddr a s
        pure (PRDone (RVLit (LChar c)), s1)
  _ -> throwE (ArityError (Tx.pack "String.index"))

-- | @byteLength s@: byte count of the UTF-8 encoding. O(1): just reads
-- 'BS.length' from the 'NString' cell. Consumes 's'. RC: 0 alloc.
stringByteLength :: RCPrim
stringByteLength = RCPrim PN.stringByteLengthName 1 [] $ \args s -> case args of
  [sv@(RVBox a)] -> do
    bs <- stringBytes sv s
    let n = BS.length bs
    s1 <- dropAddr a s
    pure (PRDone (RVLit (LInt (toInteger n))), s1)
  _ -> throwE (ArityError (Tx.pack "String.byteLength"))

-- | @byteAt s i@: the i-th UTF-8 byte as a U64 (0-based, bounds-checked).
-- OOB raises 'PrimError'. Consumes 's'. RC: 0 alloc.
-- On 'CHeap' with a 'CAddr', bounds-checks O(1) via 'wokStringLen' and reads
-- the single byte via 'wokStringByteGet' (no full-body copy). On 'AbstractHeap'
-- (or any 'HAddr') the stored 'ByteString' already lives in Haskell memory so
-- 'BS.index' is O(1) after the 'IntMap' lookup.
--
-- TAG GUARD (E4). A CHeap view is ALSO a 'CAddr', but it points at a
-- 'WokStringView' cell (tag 'wokStringViewTag', layout parent\@8 / offset\@16 /
-- len\@24) -- NOT a 'WokString' (tag 'wokStringTag', byte_len\@8 then inline
-- bytes). 'wokStringLen' / 'wokStringByteGet' assume the WokString layout, so the
-- O(1) fast path is correct ONLY for a genuine WokString. We therefore read the
-- cell tag first and take the fast path only when it is 'wokStringTag'; a view
-- (or any other CAddr cell) falls through to 'stringByteAtViaBytes', which routes
-- through 'stringBytes' -> 'deref' -> 'NStringView' windowing (view-correct).
stringByteAt :: RCPrim
stringByteAt = RCPrim PN.stringByteAtName 2 [] $ \args s -> case args of
  [RVBox a@(CAddr p), iv] -> case stBackend s of
    CHeap _ -> do
      tid <- liftIO (H.wokTag p)
      if tid == wokStringTag
        then do
          i    <- asStringIndex iv
          blen <- liftIO (H.wokStringLen p)
          if i >= fromIntegral blen
            then throwE (PrimError (Tx.pack "String.byteAt: out of bounds"))
            else do
              byte <- liftIO (H.wokStringByteGet p (fromIntegral i))
              s1   <- dropAddr a s
              pure (PRDone (RVLit (LInt (toInteger byte))), s1)
        -- A WokStringView CAddr (or any non-WokString cell): the WokString FFI
        -- would misread the layout, so route through the byte-window path.
        else stringByteAtViaBytes a (RVBox a) iv s
    AbstractHeap -> stringByteAtViaBytes a (RVBox a) iv s
  [RVBox a, iv] -> stringByteAtViaBytes a (RVBox a) iv s
  _ -> throwE (ArityError (Tx.pack "String.byteAt"))

-- | O(1)-after-deref fallback: deref the 'NString' cell (an 'IntMap' lookup on
-- 'AbstractHeap'), then index the already-in-memory 'ByteString'. Used for
-- 'AbstractHeap' addresses and any address shape not handled by the 'CHeap'
-- O(1) fast path.
stringByteAtViaBytes :: Addr -> RCValue -> RCValue -> Store -> RC (RCPrimResult, Store)
stringByteAtViaBytes a sv iv s = do
  bs <- stringBytes sv s
  i  <- asStringIndex iv
  if i >= BS.length bs
    then throwE (PrimError (Tx.pack "String.byteAt: out of bounds"))
    else do
      let byte = BS.index bs i
      s1 <- dropAddr a s
      pure (PRDone (RVLit (LInt (toInteger byte))), s1)

-- | @append a b@: concatenate two strings. Allocates a new 'NString' cell of
-- byte length = len(a) + len(b); drops both inputs. RC: +1 alloc.
stringAppend :: RCPrim
stringAppend = RCPrim PN.stringAppendName 2 [] $ \args s -> case args of
  [av@(RVBox aa), bv@(RVBox ba)] -> do
    bsa <- stringBytes av s
    bsb <- stringBytes bv s
    let cat = bsa <> bsb
    s1        <- dropAddr aa s
    s2        <- dropAddr ba s1
    (na, s3)  <- alloc (NString cat) s2
    pure (PRDone (RVBox na), s3)
  _ -> throwE (ArityError (Tx.pack "String.append"))

-- | @eqString a b@: byte-equality of two strings. Consumes both. RC: 0 alloc.
-- (For valid UTF-8, codepoint equality = byte equality, so this is correct.)
eqString :: RCPrim
eqString = RCPrim PN.eqStringName 2 [] $ \args s -> case args of
  [av@(RVBox aa), bv@(RVBox ba)] -> do
    bsa <- stringBytes av s
    bsb <- stringBytes bv s
    let eq = bsa == bsb
    s1        <- dropAddr aa s
    s2        <- dropAddr ba s1
    (boolV, s3) <- allocBool eq s2
    pure (PRDone boolV, s3)
  _ -> throwE (ArityError (Tx.pack "eqString"))

-- | @indexOfFromRaw hay needle from@: first byte offset of needle in hay at/after
-- @from@, or the maxBound sentinel if absent. Calls the StringZilla FFI
-- ('szFind'). Consumes both string inputs. RC: 0 alloc.
stringIndexOfFromRaw :: RCPrim
stringIndexOfFromRaw = RCPrim PN.stringIndexOfFromRawName 3 [] $ \args s -> case args of
  [hayV@(RVBox ha), needleV@(RVBox na), fromV] -> do
    bh <- stringBytes hayV s
    bn <- stringBytes needleV s
    i  <- asStringIndex fromV
    s1 <- dropAddr ha s
    s2 <- dropAddr na s1
    pure (PRDone (RVLit (LInt (toInteger (szFind bh bn i)))), s2)
  _ -> throwE (ArityError (Tx.pack "String.indexOfFromRaw"))

-- | @hash s@: StringZilla sz_hash of the UTF-8 bytes (unseeded, deterministic).
-- Consumes 's'. RC: 0 alloc.
stringHash :: RCPrim
stringHash = RCPrim PN.stringHashName 1 [] $ \args s -> case args of
  [sv@(RVBox a)] -> do
    b  <- stringBytes sv s
    s1 <- dropAddr a s
    pure (PRDone (RVLit (LInt (toInteger (szHash b)))), s1)
  _ -> throwE (ArityError (Tx.pack "String.hash"))

-- | @editDistance a b@: byte-level unit-cost Levenshtein (StringZilla
-- sz_edit_distance). Consumes both inputs. RC: 0 alloc.
stringEditDistance :: RCPrim
stringEditDistance = RCPrim PN.stringEditDistanceName 2 [] $ \args s -> case args of
  [av@(RVBox aa), bv@(RVBox ba)] -> do
    bsa <- stringBytes av s
    bsb <- stringBytes bv s
    s1  <- dropAddr aa s
    s2  <- dropAddr ba s1
    pure (PRDone (RVLit (LInt (toInteger (szEditDistance bsa bsb)))), s2)
  _ -> throwE (ArityError (Tx.pack "String.editDistance"))

-- ---------------------------------------------------------------------------
-- Slice prims (String Slice E4, Task 3)
-- ---------------------------------------------------------------------------

-- | True if byte @i@ in @bs@ is a UTF-8 continuation byte (0x80..0xBF), i.e.
-- it is not a codepoint boundary. Used by 'stringByteSlice' to detect splits.
-- Position @i@ must be in @[0, BS.length bs)@ (caller responsibility).
splitsCodepoint :: BS.ByteString -> Int -> Bool
splitsCodepoint bs i =
  i > 0 && i < BS.length bs && isContinuationByte (BS.index bs i)
  where
    isContinuationByte :: Word8 -> Bool
    isContinuationByte b = (b .&. 0xC0) == 0x80

-- | D6 decision procedure. Given the parent string value @sv@ (an 'RVBox a')
-- and the raw byte window @wb@ extracted from that parent, return the
-- representation:
--
--   * if @BS.length wb <= maxInlineStr@: an 'InlineStr' (0 new cells), drop @a@.
--   * otherwise: flatten the parent to its root, call 'allocNStringView'
--     (which increfs the root), then drop @a@ (which decrefs the old chain,
--     yielding exactly +1 net ref on the root).
--
-- The 'Int' argument @thisOff@ is the BYTE offset of @wb@ within the parent's
-- byte buffer (needed to compute the absolute offset on the flatten path).
--
-- Ownership: the prim is handed one owned ref to @a@. 'buildSlice' consumes
-- it (dropping it exactly once).
buildSlice :: RCValue -> Int -> BS.ByteString -> Store -> RC (RCPrimResult, Store)
buildSlice (RVBox a) thisOff wb s
  | BS.length wb <= maxInlineStr = do
      -- Short window: InlineStr -- 0 new cells, always cheapest.
      s1 <- dropAddr a s
      pure (PRDone (RVBox (InlineStr wb)), s1)
  | otherwise = do
      -- Window > 7 bytes: must be a counted cell view.
      -- Resolve the ROOT parent by peeking the node:
      --   NStringView root o _ => parent=root, absOff=o+thisOff  (flatten)
      --   NString _             => parent=a,    absOff=thisOff
      c <- deref a s
      (rootAddr, absOff) <- case cNode c of
        NStringView root o _ -> pure (root, o + thisOff)
        NString _            -> pure (a, thisOff)
        _                    -> throwE (PrimError (Tx.pack "buildSlice: not a string cell"))
      -- Alloc the view (increfs rootAddr).
      (va, s1) <- allocNStringView rootAddr absOff (BS.length wb) s
      -- Drop the input (decrefs a; if a was a view its cascade decrefs root,
      -- balancing the incref above; net = 0 on root, +1 from the new view).
      s2 <- dropAddr a s1
      pure (PRDone (RVBox va), s2)
buildSlice _ _ _ _ = throwE (PrimError (Tx.pack "buildSlice: expected RVBox"))

-- | @slice s start len@: codepoint window [start, start+len), saturating bounds.
-- Always valid UTF-8; 'byteSlice' is the O(1) escape hatch. RC: 0 or +1 alloc
-- (0 when result <= maxInlineStr, +1 for NStringView otherwise).
stringSlice :: RCPrim
stringSlice = RCPrim PN.stringSliceName 3 [] $ \args s -> case args of
  [sv@(RVBox _), startV, lenV] -> do
    pb    <- stringBytes sv s
    start <- asStringIndex startV
    len   <- asStringIndex lenV
    -- Codepoint -> byte offset: decode UTF-8, clamp codepoint indices, then
    -- compute byte boundaries by re-encoding the relevant prefix.
    let t          = TxEnc.decodeUtf8 pb      -- NString invariant: valid UTF-8
        cpLen      = Tx.length t
        start'     = min start cpLen
        -- Overflow-safe saturating end: 'start + len' could overflow Int (both are
        -- attacker-controlled U64s up to maxBound). 'start' + min len (cpLen - start')'
        -- never overflows (len>=0, cpLen-start'>=0) and is <= cpLen by construction.
        end'       = start' + min len (cpLen - start')
        -- Byte offset of codepoint k: length of the UTF-8 encoding of the first k chars.
        cpToByteOff k = BS.length (TxEnc.encodeUtf8 (Tx.take k t))
        byteStart  = cpToByteOff start'
        byteEnd    = cpToByteOff end'
        wb         = BS.take (byteEnd - byteStart) (BS.drop byteStart pb)
    buildSlice sv byteStart wb s
  _ -> throwE (ArityError (Tx.pack "String.slice"))

-- | @byteSlice s start len@: byte window [start, start+len), saturating bounds.
-- Raises 'PrimError' if a boundary falls in the middle of a multibyte codepoint.
-- O(1) to locate boundaries (unlike 'stringSlice'). RC: 0 or +1 alloc.
stringByteSlice :: RCPrim
stringByteSlice = RCPrim PN.stringByteSliceName 3 [] $ \args s -> case args of
  [sv@(RVBox _), startV, lenV] -> do
    pb    <- stringBytes sv s
    start <- asStringIndex startV
    len   <- asStringIndex lenV
    let byteLen   = BS.length pb
        start'    = min start byteLen
        -- Overflow-safe saturating end (see 'stringSlice'): 'start + len' could
        -- overflow Int; this form is <= byteLen and never overflows.
        end'      = start' + min len (byteLen - start')
    -- Boundary validity: neither start' nor end' may split a multibyte codepoint.
    if splitsCodepoint pb start'
      then throwE (PrimError (Tx.pack "String.byteSlice: start splits a multibyte codepoint"))
      else if splitsCodepoint pb end'
        then throwE (PrimError (Tx.pack "String.byteSlice: end splits a multibyte codepoint"))
        else do
          let wb = BS.take (end' - start') (BS.drop start' pb)
          buildSlice sv start' wb s
  _ -> throwE (ArityError (Tx.pack "String.byteSlice"))
