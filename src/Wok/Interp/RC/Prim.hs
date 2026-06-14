module Wok.Interp.RC.Prim
  ( rcPrimTable
  ) where

import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as Tx
import Wok.IR.Anf (Lit (..))
import Wok.Interp.RC.Value
  ( RCPrim (..), RCPrimResult (..), RCPrimTable, RCValue (..)
  , Node (..), Cell (..), Store, alloc, deref, incref, dropAddr )
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
  ]

-- ---------------------------------------------------------------------------
-- The RC intrinsics

-- | @__rc_dup x@ increfs the handle and returns the SAME handle; a no-op on a
-- literal (literals are never counted). Threads the store.
rcDup :: RCPrim
rcDup = RCPrim (Tx.pack "__rc_dup") 1 [] $ \args s -> case args of
  [v@(RVBox a)] -> do s' <- incref a s; Right (PRDone v, s')
  [v@(RVLit _)] -> Right (PRDone v, s)
  _             -> Left (ArityError (Tx.pack "__rc_dup"))

-- | @__rc_drop x@ decrefs the handle (freeing at zero, recursively) and returns
-- unit; a no-op on a literal. Threads the store.
rcDrop :: RCPrim
rcDrop = RCPrim (Tx.pack "__rc_drop") 1 [] $ \args s -> case args of
  [RVBox a]   -> do s' <- dropAddr a s; Right (PRDone (RVLit LUnit), s')
  [RVLit _]   -> Right (PRDone (RVLit LUnit), s)
  _           -> Left (ArityError (Tx.pack "__rc_drop"))

-- ---------------------------------------------------------------------------
-- Pure value prims (store-passthrough)

mkPrim :: Text -> Int -> ([RCValue] -> Either RuntimeError RCPrimResult) -> RCPrim
mkPrim name arity fn = RCPrim name arity [] (\args s -> (\r -> (r, s)) <$> fn args)

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

-- | Deref a boxed boolean argument to a Haskell 'Bool'.
asBool :: RCValue -> Store -> Either RuntimeError Bool
asBool (RVBox a) s = do
  c <- deref a s
  case cNode c of
    NCon t [] | t == Tx.pack "True"  -> Right True
              | t == Tx.pack "False" -> Right False
    _ -> Left (PrimError (Tx.pack "expected Bool"))
asBool (RVLit _) _ = Left (PrimError (Tx.pack "expected Bool, got a literal"))

-- | Allocate a boxed boolean constructor and return its handle.
allocBool :: Bool -> Store -> (RCValue, Store)
allocBool b s =
  let tag = if b then Tx.pack "True" else Tx.pack "False"
      (a, s') = alloc (NCon tag []) s
  in (RVBox a, s')

-- | Comparison: U64 operands, freshly-allocated boxed Bool result.
cmp :: Text -> (Integer -> Integer -> Bool) -> RCPrim
cmp name op = RCPrim name 2 [] $ \args s -> case args of
  [a, b] -> do
    x <- asInt a; y <- asInt b
    let (v, s') = allocBool (op x y) s
    Right (PRDone v, s')
  _ -> Left (ArityError name)

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
    let (v, s3) = allocBool (op x y) s2
    Right (PRDone v, s3)
  _ -> Left (ArityError name)

-- | Drop a moved-in operand: decref a boxed handle (freeing recursively at
-- zero); a no-op on a literal (literals are never counted). Threads the store.
dropBoxed :: RCValue -> Store -> Either RuntimeError Store
dropBoxed (RVBox a) s = dropAddr a s
dropBoxed (RVLit _) s = Right s
