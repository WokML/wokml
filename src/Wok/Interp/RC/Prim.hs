module Wok.Interp.RC.Prim
  ( rcPrimTable
  ) where

import Control.Monad.Trans.Except (throwE)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as Tx
import Wok.IR.Anf (Lit (..))
import qualified Wok.IR.PrimNames as PN
import Wok.Interp.RC.Value
  ( RC, liftRC, RCPrim (..), RCPrimResult (..), RCPrimTable, RCValue (..)
  , Node (..), Cell (..), Store, alloc, deref, incref, dropAddr, dropReuse, writeNode
  , continuationOwned )
import Wok.Interp.Value (RuntimeError (..))

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
rcPrimTable :: RCPrimTable
rcPrimTable = Map.fromList [ (rpName p, p) | p <- prims ]

prims :: [RCPrim]
prims =
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
  , rcDup
  , rcDrop
  , rcDropReuse
  , contCellNew
  , contStore
  , contTake
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
