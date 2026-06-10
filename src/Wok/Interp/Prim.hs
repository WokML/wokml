module Wok.Interp.Prim
  ( primTable
  ) where

import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as Tx
import Wok.IR.Anf (Lit (..))
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

-- | (u32) : narrow a U64 to U32. v1 models integers as unbounded 'Integer' and
-- does NOT model modular wrapping (consistent with the U64 arithmetic prims), so
-- this is the identity on the underlying value; it exists so U32 values can be
-- constructed. Bounded/wrapping semantics is deferred along with U64's.
u32Conv :: Prim
u32Conv = mkPrim (Tx.pack "u32") 1 $ \args -> case args of
  [a] -> do _ <- asInt a; Right (PRDone a)
  _   -> Left (ArityError (Tx.pack "u32"))

mkPrim :: Text -> Int -> ([Value] -> Either RuntimeError PrimResult) -> Prim
mkPrim name arity fn = Prim name arity [] fn

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
