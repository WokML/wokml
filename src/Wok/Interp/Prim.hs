module Wok.Interp.Prim
  ( primTable
  ) where

import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as Tx
import Wok.IR.Anf (Lit (..))
import qualified Wok.IR.PrimNames as PN
import Wok.Interp.Value
  ( Prim (..), PrimResult (..), PrimTable, RuntimeError (..), Value (..), renderValue )

primTable :: PrimTable
primTable = Map.fromList [ (primName p, p) | p <- prims ]

prims :: [Prim]
prims =
  [ arith (Tx.pack "+")   (+)
  , arith (Tx.pack "-")   (-)
  , arith (Tx.pack "*")   (*)
  , divLike (Tx.pack "/")
  , divLike (Tx.pack "div")
  , modLike (Tx.pack "mod")
  , cmp (Tx.pack "eqU64") (==)
  , cmp (Tx.pack "eqU32") (==)
  , u32Conv
  , boolOp (Tx.pack "&&") (&&)
  , boolOp (Tx.pack "||") (||)
  , appendP
  , dollarP
  , coroSuspP
  , coroUnwrapP
  , coroResumeP
  , coroDoneP
  , coroCancelP
  , coerceP
  , driveConcP
  , contCellNewP
  , contStoreP
  , contTakeP
  ]

-- | `__coro_susp x k` packs the yielded value `x` and
-- the captured resume continuation `k` (a VCont, held below the boundary) into a
-- `Suspended` future. The host shim exists only to ERASE the continuation's wok
-- type (in the suspend arm `k : b -> answer`, but the Suspended field wants
-- `b -> r`); at runtime it is a plain two-field constructor build. `resume`/
-- `value` are ordinary wok projections over the resulting VCon, and applying the
-- stored VCont re-installs the Coro handler via dispatchOp (deep re-install).
coroSuspP :: Prim
coroSuspP = mkPrim (Tx.pack "__coro_susp") 2 $ \args -> case args of
  [x, k] -> Right (PRDone (VCon (Tx.pack "Suspended") [x, k]))
  _      -> Left (ArityError (Tx.pack "__coro_susp"))

-- | Resuming the stored continuation re-installs the Coro
-- handler's value arm (`v -> Completed v`), so `k v` returns `Completed r`. This
-- peels that one layer to the raw `r`; anything else passes through unchanged
-- (so a producer that resumes without suspending again still returns its value).
coroUnwrapP :: Prim
coroUnwrapP = mkPrim (Tx.pack "__coro_unwrap") 1 $ \args -> case args of
  [VCon t [r]] | t == Tx.pack "Completed" -> Right (PRDone r)
  -- A `Suspended` shape means the producer re-suspended; `run` assumes completion,
  -- so peeling it as `r` would smuggle a Step through where a result is expected.
  -- Error instead of silently passing it through.
  [VCon t _] | t == Tx.pack "Suspended" ->
    Left (PrimError (Tx.pack "__coro_unwrap: producer re-suspended; use step, not run"))
  [v]                                     -> Right (PRDone v)
  _ -> Left (ArityError (Tx.pack "__coro_unwrap"))

-- | `__coro_resume s v` applies the captured continuation `k` (stored in the
-- `Suspended` future) to the resume payload `v` under the current kont. This
-- re-installs the Coro handler via dispatchOp's deep re-install, so the
-- producer's tail runs and returns through the value arm, ultimately producing
-- a `Completed` future. Errors on any non-Suspended shape.
coroResumeP :: Prim
coroResumeP = mkPrim (Tx.pack "__coro_resume") 2 $ \args -> case args of
  -- New Step surface: a `Suspension` is the parked continuation itself (the slot-2
  -- value bound by a `Suspended x g` arm of a `Step`). Apply it directly.
  [k@VCont{},  v] -> Right (PRApply k [v])
  -- Currently unreachable: a parameterized continuation (VContP) only arises from
  -- parameterized handlers, which the non-parameterized `Coro` effect never builds.
  -- Kept for forward-compatibility with a future parameterized producer surface.
  [k@VContP{}, v] -> Right (PRApply k [v])
  -- Legacy/defensive: a whole `Suspended [x, k]` VCon (the pre-Step rep) — extract
  -- the continuation and apply it.
  [VCon t [_, k], v] | t == Tx.pack "Suspended" -> Right (PRApply k [v])
  [s, _] -> Left (PrimError (Tx.pack "__coro_resume: not a suspension: " <> renderValue s))
  _      -> Left (ArityError (Tx.pack "__coro_resume"))

-- | `__coro_done v` tags a normally-returned producer result as a `Completed`
-- future. The Coro handler's value arm (`v -> __coro_done v`) uses this so a
-- producer that runs to completion (after resume) yields a Completed future,
-- which `__coro_unwrap` then peels to the raw `r`.
coroDoneP :: Prim
coroDoneP = mkPrim (Tx.pack "__coro_done") 1 $ \args -> case args of
  [v] -> Right (PRDone (VCon (Tx.pack "Completed") [v]))
  _   -> Left (ArityError (Tx.pack "__coro_done"))

-- | `__coro_cancel s` consumes the future without resuming it: it drops the
-- captured continuation and returns unit. Like `resume`, it is a CONSUMING use
-- (the affine consumption check in 'Wok.TypeChecking.Carrier' forbids a future
-- from being consumed more than once across @resume@ XOR @cancel@). At runtime
-- there is nothing to run down; the continuation is simply discarded. Unit is
-- @VLit LUnit@ (the same value the `()` literal lowers to).
coroCancelP :: Prim
coroCancelP = mkPrim (Tx.pack "__coro_cancel") 1 $ \args -> case args of
  [_] -> Right (PRDone (VLit LUnit))
  _   -> Left (ArityError (Tx.pack "__coro_cancel"))

-- | `__coerce v` is the runtime identity: it recalls a wok type the elaborator
-- erased (e.g. adapting a Conc root's carrier) without storing or changing the
-- value. The host shim exists purely so the type-checker has a hole to hang the
-- recalled type on.
coerceP :: Prim
coerceP = mkPrim (Tx.pack "__coerce") 1 $ \args -> case args of
  [v] -> Right (PRDone v)
  _   -> Left (ArityError (Tx.pack "__coerce"))

-- | `__drive_conc thunk` hands a Conc root thunk to the machine, which dispatches
-- to the scheduler (see "Wok.Interp.Sched"). The thunk is an adapted
-- `() -> a with Coro Request Transport`.
driveConcP :: Prim
driveConcP = mkPrim (Tx.pack "__drive_conc") 1 $ \args -> case args of
  [thunk] -> Right (PRDrive thunk)
  _       -> Left (ArityError (Tx.pack "__drive_conc"))

-- | (u32) : narrow a U64 to U32. v1 models integers as unbounded 'Integer' and
-- does NOT model modular wrapping (consistent with the U64 arithmetic prims), so
-- this is the identity on the underlying value; it exists so U32 values can be
-- constructed. Bounded/wrapping semantics is deferred along with U64's.
u32Conv :: Prim
u32Conv = mkPrim (Tx.pack "u32") 1 $ \args -> case args of
  [a] -> do _ <- asInt a; Right (PRDone a)
  _   -> Left (ArityError (Tx.pack "u32"))

-- ---------------------------------------------------------------------------
-- The M3 stored-continuation cell primitives (spec §4.1), reference side.
--
-- The reference machine is a pure CEK machine with no explicit value store, so
-- the continuation CELL is modelled FUNCTIONALLY as an immutable
-- @VCon "ContCell" [k]@ wrapper (Design A). This is a faithful differential
-- oracle because usage is affine: the cell is filled exactly once
-- (@__cont_store@) and emptied exactly once (@__cont_take@), so no in-place
-- mutation is observable. The continuation @k@ is the op-arm resume binder ---
-- a 'VCont' on this machine --- and resuming the taken @k@ reuses the existing
-- 'enter' 'VCont' apply path (the Coro/scheduler handler is re-installed via the
-- continuation builder, mirroring @__coro_resume@).

-- | @__cont_cell_new ()@ produces a fresh EMPTY cell. The empty slot is the
-- nullary @ContCellEmpty@ con; @__cont_take@ on an empty cell errors loudly.
contCellNewP :: Prim
contCellNewP = mkPrim PN.contCellNewName 1 $ \args -> case args of
  [_] -> Right (PRDone (VCon (Tx.pack "ContCell") [VCon (Tx.pack "ContCellEmpty") []]))
  _   -> Left (ArityError (Tx.pack "__cont_cell_new"))

-- | @__cont_store cell k@ moves @k@ into the cell and RETURNS the filled
-- @VCon "ContCell" [k]@. Immutable: a fresh filled wrapper is returned rather
-- than the argument cell mutated. Design A signature: @store@ returns the filled
-- cell (not @()@) precisely because this immutable model cannot fill a handle in
-- place --- the program threads the returned cell to @__cont_take@. The RC
-- machine mutates in place and returns the same handle, so the two agree.
--
-- ORACLE FAITHFULNESS (code-review #7). This reference is a DIFFERENTIAL ORACLE
-- against the RC machine ('Wok.Interp.RC.Prim'); the two must AGREE on every
-- program that reaches them. Two of the three soundness classes the RC machine
-- guards are filtered UPSTREAM, before EITHER machine runs:
--
--   * the DOUBLE-STORE (one-shot) class is a compile error (the affine
--     Multiplicity analysis rejects storing/resuming a continuation twice), and
--   * the carrier-wall CYCLE class is rejected by the static fresh-local boundary
--     guard ('Wok.IR.Reachable.m3CarrierWallViolations').
--
-- So the differential oracle operates only on ADMITTED programs, and the
-- reference is faithful THERE. We nonetheless mirror the RC machine's ONE-SHOT
-- empty->full check here (it is cheap in this functional cell model: an empty
-- cell wraps the @ContCellEmpty@ sentinel, a full one wraps the continuation), so
-- that IF a double-store ever reached both machines they would AGREE on the
-- rejection rather than diverge (the RC machine errors "cell already holds a
-- continuation"; the reference errors here). We deliberately do NOT replicate the
-- carrier-wall CYCLE check: it is intrinsically RC-specific (it consults the
-- captured continuation's OWNED SET via 'continuationOwned', which exists only on
-- the RC machine --- this reference uses 'VCont', not 'NCont', and has no
-- owned-set), and the cycle class is filtered upstream anyway, so there is nothing
-- for the oracle to compare on it.
contStoreP :: Prim
contStoreP = mkPrim PN.contStoreName 2 $ \args -> case args of
  [VCon t [inner], k] | t == Tx.pack "ContCell" ->
    case inner of
      VCon e [] | e == Tx.pack "ContCellEmpty" ->
        Right (PRDone (VCon (Tx.pack "ContCell") [k]))
      -- A cell already holding a continuation: the one-shot violation the RC
      -- machine rejects loudly. Unreachable on admitted programs (filtered by
      -- Multiplicity upstream), but we mirror it so the oracle never diverges.
      _ ->
        Left (PrimError (Tx.pack "__cont_store: cell already holds a continuation (one-shot violation)"))
  [_cell, _k] -> Left (PrimError (Tx.pack "__cont_store: not a continuation cell"))
  _           -> Left (ArityError (Tx.pack "__cont_store"))

-- | @__cont_take cell@ moves the continuation out of a filled cell. Errors on an
-- empty cell (taken twice / never stored) --- the reference analogue of the RC
-- machine's empty-slot fault.
contTakeP :: Prim
contTakeP = mkPrim PN.contTakeName 1 $ \args -> case args of
  [VCon t [k]] | t == Tx.pack "ContCell" ->
    case k of
      VCon e [] | e == Tx.pack "ContCellEmpty" ->
        Left (PrimError (Tx.pack "__cont_take: cell is empty (taken twice or never stored)"))
      _ -> Right (PRDone k)
  [v] -> Left (PrimError (Tx.pack "__cont_take: not a continuation cell: " <> renderValue v))
  _   -> Left (ArityError (Tx.pack "__cont_take"))

mkPrim :: Text -> Int -> ([Value] -> Either RuntimeError PrimResult) -> Prim
mkPrim name arity = Prim name arity []

asInt :: Value -> Either RuntimeError Integer
asInt (VLit (LInt n)) = Right n
asInt v = Left (PrimError (Tx.pack "expected U64, got " <> renderValue v))

asBool :: Value -> Either RuntimeError Bool
asBool v@(VCon t []) =
  case () of
    _ | t == Tx.pack "True"  -> Right True
      | t == Tx.pack "False" -> Right False
      | otherwise -> Left (PrimError (Tx.pack "expected Bool, got " <> renderValue v))
asBool v = Left (PrimError (Tx.pack "expected Bool, got " <> renderValue v))

boolVal :: Bool -> Value
boolVal True  = VCon (Tx.pack "True") []
boolVal False = VCon (Tx.pack "False") []

arith :: Text -> (Integer -> Integer -> Integer) -> Prim
arith name op = mkPrim name 2 $ \args -> case args of
  [a, b] -> do x <- asInt a; y <- asInt b; Right (PRDone (VLit (LInt (op x y))))
  _      -> Left (ArityError name)

-- Both (/) and div use Haskell's `div`. This is correct for wok's U64, whose
-- domain is non-negative, where floor-division and truncation-toward-zero
-- agree. (v1 models integers as unbounded Integer and does NOT model U64
-- modular wrapping; revisit if/when signed or wrapping integers are added.)
divLike :: Text -> Prim
divLike name = mkPrim name 2 $ \args -> case args of
  [a, b] -> do
    x <- asInt a; y <- asInt b
    if y == 0 then Left (PrimError (name <> Tx.pack ": division by zero"))
              else Right (PRDone (VLit (LInt (x `div` y))))
  _ -> Left (ArityError name)

modLike :: Text -> Prim
modLike name = mkPrim name 2 $ \args -> case args of
  [a, b] -> do
    x <- asInt a; y <- asInt b
    if y == 0 then Left (PrimError (name <> Tx.pack ": modulo by zero"))
              else Right (PRDone (VLit (LInt (x `mod` y))))
  _ -> Left (ArityError name)

cmp :: Text -> (Integer -> Integer -> Bool) -> Prim
cmp name op = mkPrim name 2 $ \args -> case args of
  [a, b] -> do x <- asInt a; y <- asInt b; Right (PRDone (boolVal (op x y)))
  _      -> Left (ArityError name)

boolOp :: Text -> (Bool -> Bool -> Bool) -> Prim
boolOp name op = mkPrim name 2 $ \args -> case args of
  [a, b] -> do x <- asBool a; y <- asBool b; Right (PRDone (boolVal (op x y)))
  _      -> Left (ArityError name)

-- | (++) : append two Cons/Nil lists.
appendP :: Prim
appendP = mkPrim (Tx.pack "++") 2 $ \args -> case args of
  [xs, ys] -> PRDone <$> appendVal xs ys
  _        -> Left (ArityError (Tx.pack "++"))
  where
    appendVal v ys
      | VCon t []      <- v, t == Tx.pack "Nil"  = Right ys
      | VCon t [h, tl] <- v, t == Tx.pack "Cons" = do
          rest <- appendVal tl ys
          Right (VCon (Tx.pack "Cons") [h, rest])
      | otherwise = Left (PrimError (Tx.pack "++: not a list: " <> renderValue v))

-- | ($) : apply the first argument (a function) to the second.
dollarP :: Prim
dollarP = mkPrim (Tx.pack "$") 2 $ \args -> case args of
  [f, x] -> Right (PRApply f [x])
  _      -> Left (ArityError (Tx.pack "$"))
