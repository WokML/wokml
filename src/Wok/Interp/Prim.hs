module Wok.Interp.Prim
  ( primTable
  ) where

import Data.Bits ((.&.))
import qualified Data.ByteString as BS
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as Tx
import qualified Data.Text.Encoding as TxEnc
import Data.Word (Word64, Word8)
import Wok.IR.Anf (Lit (..))
import qualified Wok.IR.PrimNames as PN
import Wok.Interp.Value
  ( Prim (..), PrimResult (..), PrimTable, RuntimeError (..), Value (..), renderValue )
import qualified Wok.Interp.Utf8 as Utf8
import Wok.Runtime.StringZilla (szHash)


-- | Primitive lookup table, keyed by @(module, name)@.  Using the full
-- qualified pair prevents silent shadowing when two modules export the same
-- bare name (e.g., @length@ in both @Std.Array@ and @Std.String@).
primTable :: PrimTable
primTable = Map.fromList [ ((mn, primName p), p) | (mn, p) <- taggedPrims ]

-- | All primitives tagged with their defining module.
taggedPrims :: [(Text, Prim)]
taggedPrims =
  map (PN.stdBaseModule,)    basePrims
  ++ map (PN.stdControlModule,) controlPrims
  ++ map (PN.stdArrayModule,)   arrayPrims
  ++ map (PN.stdStringModule,)  stringPrims
  ++ map (PN.stdBytesModule,)   bytesPrims
  ++ map (PN.stdBaseModule,)    bytesBasePrims

basePrims :: [Prim]
basePrims =
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
  , eqStringP
  ]

-- | Bytes prims that live under Std.Base (eqBytes mirrors eqString's keying).
bytesBasePrims :: [Prim]
bytesBasePrims = [ eqBytesP ]

controlPrims :: [Prim]
controlPrims =
  [ coroSuspP
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

arrayPrims :: [Prim]
arrayPrims =
  [ arrayNewP
  , arrayFromListP
  , arrayToListP
  , arrayIndexP
  , arrayLengthP
  , arraySetP
  , arrayResizeP
  ]

stringPrims :: [Prim]
stringPrims =
  [ stringLengthP
  , stringIndexP
  , stringByteLengthP
  , stringByteAtP
  , stringAppendP
  , stringIndexOfFromRawP
  , stringHashP
  , stringEditDistanceP
  , stringSliceP
  , stringByteSliceP
  , decodeCharAtP
  , charWidthAtP
  , singletonP
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

-- | Extract a non-negative index/length from a U64 literal, rejecting
-- negatives. Shared by the Array and String prims, so the messages are
-- domain-neutral. This mirrors the RC interpreter's 'asIndex' exactly so the
-- two sides of the differential oracle stay in lockstep on out-of-range inputs
-- (a negative argument must FAIL on both sides, not succeed on one).
asU64Index :: Value -> Either RuntimeError Int
asU64Index (VLit (LInt n))
  | n < 0                           = Left (PrimError (Tx.pack "negative index"))
  | n > toInteger (maxBound :: Int) = Left (PrimError (Tx.pack "index out of range"))
  | otherwise                       = Right (fromInteger n)
asU64Index v = Left (PrimError (Tx.pack "expected U64 index, got " <> renderValue v))

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

-- ---------------------------------------------------------------------------
-- Std.Array prims (reference interpreter side, Slice A).
--
-- Arrays are represented as @VCon "Array" [v1, v2, ...]@, a direct-field
-- constructor holding one 'Value' slot per element. 'renderValue' has a
-- matching special case that renders this as @[v1, v2, ...]@, byte-identical
-- with the RC interpreter's 'NArray' renderer; this keeps the differential
-- oracle honest when the program's 'main' returns an array value.
--
-- There is no reference-side RC accounting (the reference machine has no
-- store), so these prims focus purely on value semantics, matching the
-- observable behaviour described in spec §4.

-- | @new k v@: build an array of length k with every slot filled by v.
arrayNewP :: Prim
arrayNewP = mkPrim PN.arrayNewName 2 $ \args -> case args of
  [k, v] -> do
    n <- asU64Index k
    Right (PRDone (VCon (Tx.pack "Array") (replicate n v)))
  _ -> Left (ArityError PN.arrayNewName)

-- | @fromList xs@: convert a Cons/Nil list to an array.
-- The representation is @VCon "Array" [v1, v2, ...]@.
arrayFromListP :: Prim
arrayFromListP = mkPrim PN.arrayFromListName 1 $ \args -> case args of
  [xs] -> do
    vs <- collectList xs
    Right (PRDone (VCon (Tx.pack "Array") vs))
  _ -> Left (ArityError PN.arrayFromListName)
  where
    collectList (VCon t [])       | t == Tx.pack "Nil"  = Right []
    collectList (VCon t [h, tl])  | t == Tx.pack "Cons" = do
      rest <- collectList tl
      Right (h : rest)
    collectList v = Left (PrimError (Tx.pack "Array.fromList: not a list: " <> renderValue v))

-- | @toList arr@: convert an array to a Cons/Nil list.
arrayToListP :: Prim
arrayToListP = mkPrim PN.arrayToListName 1 $ \args -> case args of
  [VCon t vs] | t == Tx.pack "Array" ->
    Right (PRDone (foldr (\v tl -> VCon (Tx.pack "Cons") [v, tl]) (VCon (Tx.pack "Nil") []) vs))
  [v] -> Left (PrimError (Tx.pack "Array.toList: not an array: " <> renderValue v))
  _   -> Left (ArityError PN.arrayToListName)

-- | @index arr i@: look up the element at position i (0-based, bounds-checked).
arrayIndexP :: Prim
arrayIndexP = mkPrim PN.arrayIndexName 2 $ \args -> case args of
  [VCon t vs, iv] | t == Tx.pack "Array" -> do
    i <- asU64Index iv
    case drop i vs of
      (x : _) -> Right (PRDone x)
      []      -> Left (PrimError (Tx.pack "Array.index: out of bounds"))
  [v, _] -> Left (PrimError (Tx.pack "Array.index: not an array: " <> renderValue v))
  _      -> Left (ArityError PN.arrayIndexName)

-- | @length arr@: return the element count.
arrayLengthP :: Prim
arrayLengthP = mkPrim PN.arrayLengthName 1 $ \args -> case args of
  [VCon t vs] | t == Tx.pack "Array" ->
    Right (PRDone (VLit (LInt (fromIntegral (length vs)))))
  [v] -> Left (PrimError (Tx.pack "Array.length: not an array: " <> renderValue v))
  _   -> Left (ArityError PN.arrayLengthName)

-- | @set arr i v@: copy-on-write slot update (bounds-checked).
arraySetP :: Prim
arraySetP = mkPrim PN.arraySetName 3 $ \args -> case args of
  [VCon t vs, iv, v] | t == Tx.pack "Array" -> do
    i <- asU64Index iv
    if i >= length vs
      then Left (PrimError (Tx.pack "Array.set: out of bounds"))
      else
        let updated = [ if j == i then v else el
                      | (j, el) <- zip [(0 :: Int) ..] vs ]
        in Right (PRDone (VCon (Tx.pack "Array") updated))
  [v, _, _] -> Left (PrimError (Tx.pack "Array.set: not an array: " <> renderValue v))
  _         -> Left (ArityError PN.arraySetName)

-- | @resize arr m fill@: copy-on-write resize to length m, using fill for new slots.
arrayResizeP :: Prim
arrayResizeP = mkPrim PN.arrayResizeName 3 $ \args -> case args of
  [VCon t vs, mv, fill] | t == Tx.pack "Array" -> do
    m <- asU64Index mv
    let n    = length vs
        kept = take m vs
        ext  = replicate (max 0 (m - n)) fill
    Right (PRDone (VCon (Tx.pack "Array") (kept ++ ext)))
  [v, _, _] -> Left (PrimError (Tx.pack "Array.resize: not an array: " <> renderValue v))
  _         -> Left (ArityError PN.arrayResizeName)

-- ---------------------------------------------------------------------------
-- Std.String prims (reference interpreter side, Slice E1).
--
-- Strings are represented as @VLit (LStr Text)@ in the reference machine.
-- The reference 'Text' value provides the semantics; codepoint and byte ops
-- are derived from it via 'Data.Text' and 'Data.Text.Encoding'. No RC
-- accounting exists here (the reference machine has no store).
--
-- The 'mkPrim' shape mirrors 'arrayLengthP'/'arrayIndexP' above.

-- | @length s@: codepoint count. O(n) in text length (UTF-8 decode).
stringLengthP :: Prim
stringLengthP = mkPrim PN.stringLengthName 1 $ \args -> case args of
  [VLit (LStr t)] ->
    Right (PRDone (VLit (LInt (fromIntegral (Tx.length t)))))
  [v] -> Left (PrimError (Tx.pack "String.length: not a string: " <> renderValue v))
  _   -> Left (ArityError PN.stringLengthName)

-- | @index s i@: the i-th codepoint as a Char (0-based, bounds-checked).
-- OOB raises 'PrimError'.
stringIndexP :: Prim
stringIndexP = mkPrim PN.stringIndexName 2 $ \args -> case args of
  [VLit (LStr t), iv] -> do
    i <- asU64Index iv
    let n = Tx.length t
    if i >= n
      then Left (PrimError (Tx.pack "String.index: out of bounds"))
      else Right (PRDone (VLit (LChar (Tx.index t i))))
  [v, _] -> Left (PrimError (Tx.pack "String.index: not a string: " <> renderValue v))
  _      -> Left (ArityError PN.stringIndexName)

-- | @byteLength s@: byte count of the UTF-8 encoding. O(n) here (the reference
-- 'Text' is re-encoded to count bytes); O(1) on the RC side, where the bytes are
-- already materialized in the 'NString' cell.
stringByteLengthP :: Prim
stringByteLengthP = mkPrim PN.stringByteLengthName 1 $ \args -> case args of
  [VLit (LStr t)] ->
    Right (PRDone (VLit (LInt (fromIntegral (BS.length (TxEnc.encodeUtf8 t))))))
  [v] -> Left (PrimError (Tx.pack "String.byteLength: not a string: " <> renderValue v))
  _   -> Left (ArityError PN.stringByteLengthName)

-- | @byteAt s i@: the i-th UTF-8 byte as a U64 (0-based, bounds-checked).
-- OOB raises 'PrimError'.
stringByteAtP :: Prim
stringByteAtP = mkPrim PN.stringByteAtName 2 $ \args -> case args of
  [VLit (LStr t), iv] -> do
    i <- asU64Index iv
    let bs = TxEnc.encodeUtf8 t
    if i >= BS.length bs
      then Left (PrimError (Tx.pack "String.byteAt: out of bounds"))
      else Right (PRDone (VLit (LInt (fromIntegral (BS.index bs i)))))
  [v, _] -> Left (PrimError (Tx.pack "String.byteAt: not a string: " <> renderValue v))
  _      -> Left (ArityError PN.stringByteAtName)

-- | @append a b@: concatenate two strings.
stringAppendP :: Prim
stringAppendP = mkPrim PN.stringAppendName 2 $ \args -> case args of
  [VLit (LStr a), VLit (LStr b)] ->
    Right (PRDone (VLit (LStr (Tx.append a b))))
  [v, _] -> Left (PrimError (Tx.pack "String.append: not a string: " <> renderValue v))
  _      -> Left (ArityError PN.stringAppendName)

-- | @eqString a b@: codepoint equality of two strings (== byte equality for
-- valid UTF-8, since UTF-8 encoding is injective on codepoint sequences).
eqStringP :: Prim
eqStringP = mkPrim PN.eqStringName 2 $ \args -> case args of
  [VLit (LStr a), VLit (LStr b)] ->
    Right (PRDone (boolVal (a == b)))
  [v, _] -> Left (PrimError (Tx.pack "eqString: not a string: " <> renderValue v))
  _      -> Left (ArityError PN.eqStringName)

-- | Byte-level "find from offset"; absolute position or maxBound
-- (== WOK_SZ_NOT_FOUND). Independent pure Haskell implementation used by the
-- reference side to cross-validate the StringZilla FFI result.
refFindFrom :: BS.ByteString -> BS.ByteString -> Int -> Word64
refFindFrom hay needle from
  | from > BS.length hay = maxBound
  | BS.null needle       = fromIntegral from
  | BS.null post         = maxBound
  | otherwise            = fromIntegral (from + BS.length pre)
  where (pre, post) = BS.breakSubstring needle (BS.drop from hay)

-- | Byte-level unit-cost Levenshtein (two-row DP). d[i][j] = dist(a[0..i), b[0..j)).
-- Independent pure Haskell implementation used by the reference side to
-- cross-validate the StringZilla FFI result.
refLevenshtein :: BS.ByteString -> BS.ByteString -> Word64
refLevenshtein sa sb = fromIntegral (last (foldl nextRow [0 .. length bb] (BS.unpack sa)))
  where
    bb = BS.unpack sb
    nextRow [] _ = []
    nextRow (p0 : ps) ca = p0 + 1 : build (p0 + 1) (zip3 (p0 : ps) ps bb)
      where
        build _ [] = []
        build left ((diag, up, cb) : rest) =
          let cost = if ca == cb then 0 else 1
              cell = min (up + 1) (min (left + 1) (diag + cost)) :: Int
          in cell : build cell rest

-- | @indexOfFromRaw hay needle from@: first byte offset of needle in hay at/after
-- @from@, or the maxBound sentinel if absent. Uses the independent pure Haskell
-- 'refFindFrom' (not the StringZilla FFI) to cross-validate the RC side.
stringIndexOfFromRawP :: Prim
stringIndexOfFromRawP = mkPrim PN.stringIndexOfFromRawName 3 $ \args -> case args of
  [VLit (LStr hay), VLit (LStr needle), VLit (LInt from)] ->
    let bh = TxEnc.encodeUtf8 hay
        bn = TxEnc.encodeUtf8 needle
        fi = fromIntegral from
    in Right (PRDone (VLit (LInt (toInteger (refFindFrom bh bn fi)))))
  [v, _, _] -> Left (PrimError (Tx.pack "String.indexOfFromRaw: not a string: " <> renderValue v))
  _         -> Left (ArityError PN.stringIndexOfFromRawName)

-- | @hash s@: StringZilla sz_hash of the UTF-8 bytes (unseeded, deterministic).
stringHashP :: Prim
stringHashP = mkPrim PN.stringHashName 1 $ \args -> case args of
  [VLit (LStr s)] ->
    Right (PRDone (VLit (LInt (toInteger (szHash (TxEnc.encodeUtf8 s))))))
  [v] -> Left (PrimError (Tx.pack "String.hash: not a string: " <> renderValue v))
  _   -> Left (ArityError PN.stringHashName)

-- | @editDistance a b@: byte-level unit-cost Levenshtein. Uses the independent
-- pure Haskell 'refLevenshtein' (not the StringZilla FFI) to cross-validate
-- the RC side.
stringEditDistanceP :: Prim
stringEditDistanceP = mkPrim PN.stringEditDistanceName 2 $ \args -> case args of
  [VLit (LStr a), VLit (LStr b)] ->
    let ba = TxEnc.encodeUtf8 a
        bb = TxEnc.encodeUtf8 b
    in Right (PRDone (VLit (LInt (toInteger (refLevenshtein ba bb)))))
  [v, _] -> Left (PrimError (Tx.pack "String.editDistance: not a string: " <> renderValue v))
  _      -> Left (ArityError PN.stringEditDistanceName)

-- | @slice s start len@: codepoint window [start, start+len), saturating bounds.
-- The reference interpreter uses 'Data.Text' directly (codepoints are the
-- natural unit): 'Tx.take'/'Tx.drop' with clamped indices.
-- Always returns a valid 'Text' (and hence valid UTF-8).
stringSliceP :: Prim
stringSliceP = mkPrim PN.stringSliceName 3 $ \args -> case args of
  [VLit (LStr t), startV, lenV] -> do
    start <- asU64Index startV
    len   <- asU64Index lenV
    let cpLen  = Tx.length t
        start' = min start cpLen
        -- Overflow-safe saturating end (must match the RC peer's expression exactly
        -- so the differential oracle stays meaningful): 'start + len' could overflow
        -- Int; 'start' + min len (cpLen - start')' is <= cpLen and never overflows.
        end'   = start' + min len (cpLen - start')
        window = Tx.take (end' - start') (Tx.drop start' t)
    Right (PRDone (VLit (LStr window)))
  [v, _, _] -> Left (PrimError (Tx.pack "String.slice: not a string: " <> renderValue v))
  _         -> Left (ArityError PN.stringSliceName)

-- | True iff byte @i@ in @bs@ is a UTF-8 continuation byte (0x80..0xBF).
refSplitsCodepoint :: BS.ByteString -> Int -> Bool
refSplitsCodepoint bs i =
  i > 0 && i < BS.length bs && ((BS.index bs i :: Word8) .&. 0xC0 == 0x80)

-- | @byteSlice s start len@: byte window [start, start+len), saturating bounds.
-- Raises 'PrimError' if a boundary falls in the middle of a multibyte codepoint.
-- The reference interpreter re-encodes the 'Text' to 'ByteString', slices, then
-- decodes back (valid UTF-8 invariant maintained by the boundary check).
stringByteSliceP :: Prim
stringByteSliceP = mkPrim PN.stringByteSliceName 3 $ \args -> case args of
  [VLit (LStr t), startV, lenV] -> do
    start <- asU64Index startV
    len   <- asU64Index lenV
    let bs      = TxEnc.encodeUtf8 t
        byteLen = BS.length bs
        start'  = min start byteLen
        -- Overflow-safe saturating end (matches the RC peer): <= byteLen, no overflow.
        end'    = start' + min len (byteLen - start')
    if refSplitsCodepoint bs start'
      then Left (PrimError (Tx.pack "String.byteSlice: start splits a multibyte codepoint"))
      else if refSplitsCodepoint bs end'
        then Left (PrimError (Tx.pack "String.byteSlice: end splits a multibyte codepoint"))
        else let wb = BS.take (end' - start') (BS.drop start' bs)
             in Right (PRDone (VLit (LStr (TxEnc.decodeUtf8 wb))))
  [v, _, _] -> Left (PrimError (Tx.pack "String.byteSlice: not a string: " <> renderValue v))
  _         -> Left (ArityError PN.stringByteSliceName)

-- ---------------------------------------------------------------------------
-- E5 iterator-support prims (String Slice E5, Task 2)
-- ---------------------------------------------------------------------------

-- | @decodeCharAt s i@: decode the UTF-8 codepoint at byte offset @i@.
-- Returns the 'Char' (byte width discarded). Reference: pure 'Either'.
decodeCharAtP :: Prim
decodeCharAtP = mkPrim PN.decodeCharAtName 2 $ \args -> case args of
  [VLit (LStr t), iv] -> do
    i <- asU64Index iv
    let bs = TxEnc.encodeUtf8 t
    if i >= BS.length bs
      then Left (PrimError (Tx.pack "String.decodeCharAt: out of bounds"))
      else do
        (c, _w) <- Utf8.decodeCharAt bs i
        Right (PRDone (VLit (LChar c)))
  [v, _] -> Left (PrimError (Tx.pack "String.decodeCharAt: not a string: " <> renderValue v))
  _      -> Left (ArityError PN.decodeCharAtName)

-- | @charWidthAt s i@: UTF-8 byte width of the codepoint at byte offset @i@
-- (1-4); returns U64. Reference: pure 'Either'.
charWidthAtP :: Prim
charWidthAtP = mkPrim PN.charWidthAtName 2 $ \args -> case args of
  [VLit (LStr t), iv] -> do
    i <- asU64Index iv
    let bs = TxEnc.encodeUtf8 t
    if i >= BS.length bs
      then Left (PrimError (Tx.pack "String.charWidthAt: out of bounds"))
      else do
        w <- Utf8.utf8Width (BS.index bs i)
        Right (PRDone (VLit (LInt (fromIntegral w))))
  [v, _] -> Left (PrimError (Tx.pack "String.charWidthAt: not a string: " <> renderValue v))
  _      -> Left (ArityError PN.charWidthAtName)

-- | @singleton c@: single-codepoint string from a 'Char'. Reference:
-- 'Tx.singleton' (no allocation needed in the pure machine).
singletonP :: Prim
singletonP = mkPrim PN.singletonName 1 $ \args -> case args of
  [VLit (LChar c)] -> Right (PRDone (VLit (LStr (Tx.singleton c))))
  _                -> Left (ArityError PN.singletonName)

-- ---------------------------------------------------------------------------
-- Std.Bytes prims (reference interpreter side, Slice E6).
--
-- Bytes are represented as @VBytes ByteString@ in the reference machine.
-- The 7 prims mirror the Std.Array / Std.String pattern above.
-- 'renderValue (VBytes bs)' uses the format @Bytes[65,195,169]@ (decimal
-- byte list) which Task 7 (RC interpreter) MUST reproduce exactly.

bytesPrims :: [Prim]
bytesPrims =
  [ bytesLengthP
  , bytesIndexP
  , bytesFromListP
  , bytesToListP
  , bytesFromBytesP
  , bytesToBytesP
  ]

-- | @length buf@: number of bytes. O(1).
bytesLengthP :: Prim
bytesLengthP = mkPrim PN.bytesLengthName 1 $ \args -> case args of
  [VBytes bs] ->
    Right (PRDone (VLit (LInt (fromIntegral (BS.length bs)))))
  [v] -> Left (PrimError (Tx.pack "Bytes.length: not a Bytes: " <> renderValue v))
  _   -> Left (ArityError PN.bytesLengthName)

-- | @index buf i@: the i-th byte as a U64 (0-based, bounds-checked).
-- OOB raises 'PrimError'.
bytesIndexP :: Prim
bytesIndexP = mkPrim PN.bytesIndexName 2 $ \args -> case args of
  [VBytes bs, iv] -> do
    i <- asU64Index iv
    if i >= BS.length bs
      then Left (PrimError (Tx.pack "Bytes.index: out of bounds"))
      else Right (PRDone (VLit (LInt (fromIntegral (BS.index bs i)))))
  [v, _] -> Left (PrimError (Tx.pack "Bytes.index: not a Bytes: " <> renderValue v))
  _      -> Left (ArityError PN.bytesIndexName)

-- | @fromList xs@: build a Bytes buffer from a Cons/Nil list of U64 byte
-- values (0-255). Out-of-range element raises 'PrimError'.
bytesFromListP :: Prim
bytesFromListP = mkPrim PN.bytesFromListName 1 $ \args -> case args of
  [xs] -> do
    ws <- collectByteList xs
    Right (PRDone (VBytes (BS.pack ws)))
  _ -> Left (ArityError PN.bytesFromListName)
  where
    collectByteList (VCon t [])      | t == Tx.pack "Nil"  = Right []
    collectByteList (VCon t [h, tl]) | t == Tx.pack "Cons" = do
      w  <- asByteElem h
      rest <- collectByteList tl
      Right (w : rest)
    collectByteList v =
      Left (PrimError (Tx.pack "Bytes.fromList: not a list: " <> renderValue v))

    asByteElem :: Value -> Either RuntimeError Word8
    asByteElem (VLit (LInt n))
      | n >= 0 && n <= 255 = Right (fromIntegral n)
      | otherwise          = Left (PrimError (Tx.pack "Bytes.fromList: byte value out of range (0-255)"))
    asByteElem v = Left (PrimError (Tx.pack "Bytes.fromList: expected U64 byte, got " <> renderValue v))

-- | @toList buf@: convert a Bytes buffer to a Cons/Nil list of U64 byte values.
bytesToListP :: Prim
bytesToListP = mkPrim PN.bytesToListName 1 $ \args -> case args of
  [VBytes bs] ->
    Right (PRDone (foldr (\b acc -> VCon (Tx.pack "Cons") [VLit (LInt (fromIntegral b)), acc])
                         (VCon (Tx.pack "Nil") [])
                         (BS.unpack bs)))
  [v] -> Left (PrimError (Tx.pack "Bytes.toList: not a Bytes: " <> renderValue v))
  _   -> Left (ArityError PN.bytesToListName)

-- | @fromBytes buf@: validate that the bytes are valid UTF-8; return
-- @Some s@ on success, @None@ on failure.
bytesFromBytesP :: Prim
bytesFromBytesP = mkPrim PN.bytesFromBytesName 1 $ \args -> case args of
  [VBytes bs] -> Right (PRDone (case TxEnc.decodeUtf8' bs of
      Right t -> VCon (Tx.pack "Some") [VLit (LStr t)]
      Left _  -> VCon (Tx.pack "None") []))
  [v] -> Left (PrimError (Tx.pack "Bytes.fromBytes: not a Bytes: " <> renderValue v))
  _   -> Left (ArityError PN.bytesFromBytesName)

-- | @toBytes s@: reinterpret a String as a Bytes buffer (always valid UTF-8).
bytesToBytesP :: Prim
bytesToBytesP = mkPrim PN.bytesToBytesName 1 $ \args -> case args of
  [VLit (LStr t)] -> Right (PRDone (VBytes (TxEnc.encodeUtf8 t)))
  [v] -> Left (PrimError (Tx.pack "Bytes.toBytes: not a String: " <> renderValue v))
  _   -> Left (ArityError PN.bytesToBytesName)

-- | @eqBytes a b@: byte-equality of two Bytes buffers. Mirrors 'eqStringP'.
eqBytesP :: Prim
eqBytesP = mkPrim PN.eqBytesName 2 $ \args -> case args of
  [VBytes a, VBytes b] -> Right (PRDone (boolVal (a == b)))
  [v, _] -> Left (PrimError (Tx.pack "eqBytes: not a Bytes: " <> renderValue v))
  _      -> Left (ArityError PN.eqBytesName)
