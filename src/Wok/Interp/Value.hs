module Wok.Interp.Value
  ( Value (..)
  , Env
  , JoinEnv
  , JoinPoint (..)
  , Scope (..)
  , emptyScope
  , Kont (..)
  , kontDepth
  , Config (..)
  , Step (..)
  , IdSupply
  , idRegionBound
  , maxIdRegion
  , Prim (..)
  , PrimResult (..)
  , PrimTable
  , RuntimeError (..)
  , CafFailure (..)
  , OneShotFlag
  , mkOneShotFlag
  , assertOneShot
  , resolveAtom
  , bindBinder
  , bindBinders
  , renderValue
  ) where

import Control.Exception (Exception)
import qualified Data.ByteString as BS
import Data.IORef (IORef, atomicModifyIORef', newIORef)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import System.Environment (lookupEnv)
import System.IO.Unsafe (unsafePerformIO)
import qualified Data.Text as Tx
import Wok.IR.Anf (Atom (..), Binder (..), Expr, Handler (..), Lit (..))
import Wok.IR.Name (JoinId, Name (..), Unique, nameHint, nameUniq)

-- | Environment: identity (Unique) -> runtime value.
type Env = Map Unique Value

-- | Join points in scope (local labelled continuations).
type JoinEnv = Map JoinId JoinPoint

-- | Primitive lookup table, keyed by the qualified @(module, name)@ of the
-- prelude @extern@. Using the full pair prevents name collisions between
-- distinct modules that export identically-named operations (e.g. @length@
-- in both @Array@ and @String@).
type PrimTable = Map (Text, Text) Prim

-- | A lexical scope: term bindings plus join points.
data Scope = Scope { scEnv :: Env, scJoins :: JoinEnv }

emptyScope :: Scope
emptyScope = Scope Map.empty Map.empty

-- | Runtime values. NOTE: the VClosure environment field is LAZY (leading ~)
-- so the recursive knot for top-level mutual recursion and LetRec can be tied
-- under the repo-wide StrictData (Data.Map.Strict.insert forces values to WHNF;
-- a strict env field would make the self-referential insert diverge).
data Value
  = VLit Lit
  | VCon Text [Value]
  | VRecord Text (Map Text Value)
  | VClosure ~Env [Binder] Expr
  | VPrim Prim
  | VCont OneShotFlag (Kont -> Kont)   -- a captured deep continuation; arg is the post-resume kont
  | VContP OneShotFlag (Value -> Kont -> Kont)   -- parameter-aware resume: \newParam after -> kont
  | VInst Unique !Int      -- a named effect-instance handle. Identity = the
                           -- handler self-binder Unique (the install SITE) paired
                           -- with a per-ACTIVATION tag (the Kont depth at install).
                           -- The tag distinguishes two activations of the SAME
                           -- runner site that coexist (nested), so two same-typed
                           -- instances minted by one prelude runner route apart.
  | VBytes BS.ByteString   -- a Bytes buffer: flat UTF-8-or-arbitrary bytes
  | VHandler Handler ~Env  -- a FIRST-CLASS handler value (proto/handler-values).
                           -- Carries the handler arms and the ENV they were
                           -- constructed in (their captured free vars), exactly
                           -- as VClosure captures its defining env. Installing it
                           -- (`InstallHandler`) pushes a KHandle frame whose
                           -- scope is this env, so the arms run where they were
                           -- built, not where installed. Lazy env for the same
                           -- recursive-knot reason as VClosure.

instance Show Value where
  show = Tx.unpack . renderValue

-- | Structural equality on Values. Closures, primitives, and continuations
-- are never equal to anything (function values have no decidable equality).
instance Eq Value where
  VLit a       == VLit b       = a == b
  VCon t1 vs1  == VCon t2 vs2  = t1 == t2 && vs1 == vs2
  VRecord t1 m1 == VRecord t2 m2 = t1 == t2 && m1 == m2
  VClosure{}   == VClosure{}   = False
  VPrim{}      == VPrim{}      = False
  VCont{}      == VCont{}      = False
  VContP{}     == VContP{}     = False
  VInst a ta   == VInst b tb   = a == b && ta == tb
  VBytes a     == VBytes b     = a == b
  _            == _            = False

-- | A primitive: name (= hint), arity, args accumulated so far (for currying),
-- and the saturated implementation.
data Prim = Prim
  { primName  :: Text
  , primArity :: Int
  , primArgs  :: [Value]
  , primFn    :: [Value] -> Either RuntimeError PrimResult
  }

-- | A saturated primitive either produces a value or asks the machine to apply
-- one value to others (this is how ($) is expressed without host recursion).
data PrimResult = PRDone Value | PRApply Value [Value] | PRDrive Value

-- | A labelled local continuation: the scope and continuation captured where
-- the join was defined, plus its parameters and body.
data JoinPoint = JoinPoint Scope [Binder] Expr Kont

-- | The continuation stack.
data Kont
  = KDone
  | KLet Binder Expr Scope Kont   -- bind the produced value to Binder, then run Expr in Scope
  | KApp [Value] Kont             -- over-application: apply the produced value to these args
  | KHandle Handler !Int Scope Kont
      -- effect delimiter. The Int is the activation tag (Kont depth at install)
      -- that, with the handler's self-binder Unique, identifies this activation
      -- for named (id-routed) dispatch. Ambient dispatch ignores it.

-- | Number of frames in a continuation. Used as the per-activation tag when a
-- named handler is installed: distinct COEXISTING (nested) activations of one
-- runner site sit at strictly different depths, so the tag tells them apart.
-- (Sequential activations may reuse a depth, but they never coexist, so the
-- reuse is harmless.)
kontDepth :: Kont -> Int
kontDepth = go 0
  where
    go !n KDone              = n
    go !n (KLet _ _ _ k)     = go (n + 1) k
    go !n (KApp _ k)         = go (n + 1) k
    go !n (KHandle _ _ _ k)  = go (n + 1) k

-- | Machine configuration.
data Config
  = Eval Expr Scope Kont
  | Return Value Kont

-- | One step result.
data Step = More Config | Done Value

-- | Program-wide fresh-id supply for Conc handle ids, threaded through the
-- machine so nested driveConc instances mint disjoint ids. Integer (not Word64)
-- to match LInt; ids stay below 2^64 via the per-entry region scheme.
type IdSupply = Integer

-- | Size of one interpreter-entry id region (main, each forced CAF). Handle
-- id = regionIndex * idRegionBound + localCounter. 16 region bits / 48
-- counter bits inside the wok-visible U64.
idRegionBound :: Integer
idRegionBound = 2 ^ (48 :: Int)

-- | Largest region index whose handles still fit in U64. A handle in region r
-- tops out at @r * idRegionBound + (idRegionBound - 1)@, so r must not exceed
-- @(2^64 - 1) `div` idRegionBound@. Region 0 is main; CAFs take 1..maxIdRegion,
-- so this also bounds the number of top-level constants. Derived from
-- 'idRegionBound' so the two halves of the bit layout cannot silently desync.
maxIdRegion :: Integer
maxIdRegion = (2 ^ (64 :: Int) - 1) `div` idRegionBound

data RuntimeError
  = UnboundVar Text
  | UnboundPrim Text
  | NotAFunction Text
  | NonExhaustiveCase Text
  | NoMatchingHandler Text Text
  | BadProjection Text
  | PrimError Text
  | ArityError Text
  | UnsupportedCaf Text
  | OneShotViolation
      -- the WOK_DEBUG_ONESHOT oracle observed a continuation applied twice
  deriving (Eq, Show)

-- ---------------------------------------------------------------------------
-- One-shot runtime oracle (one-shot spec section 9)

-- | Per-capture used-marker for the one-shot runtime oracle: 'Just' a flag
-- when the oracle is enabled (@WOK_DEBUG_ONESHOT=1@, read once per process),
-- 'Nothing' otherwise. The default-off setting keeps the machine's free
-- multi-shot capability -- the static multiplicity law is production's only
-- guard; the oracle is a differential check on that law, aborting with
-- 'OneShotViolation' if the same captured continuation is ever applied twice
-- at run time.
type OneShotFlag = Maybe (IORef Bool)

{-# NOINLINE oneShotOracleOn #-}
oneShotOracleOn :: Bool
oneShotOracleOn = unsafePerformIO (fmap (== Just "1") (lookupEnv "WOK_DEBUG_ONESHOT"))

-- | Mint a fresh used-flag at continuation capture when the oracle is on.
-- NOINLINE plus the dependence of the allocation on the argument are the
-- documented 'unsafePerformIO' mitigations: they stop GHC floating or CSE'ing
-- one shared 'IORef' across distinct captures, so every dynamic call
-- allocates its own flag.
--
-- The initial value MUST be an expression the simplifier cannot reduce to a
-- constant. @tag `seq` False@ is NOT enough: strictness analysis rewrites it
-- to a case wrapper around the constant @newIORef False@, which full laziness
-- then floats to the top level -- collapsing every capture onto ONE shared
-- process-global flag (observed empirically: 86/2168 failures under
-- WOK_DEBUG_ONESHOT=1, with single-apply programs aborting because unrelated
-- earlier applies had marked the global ref). @tag < 0@ keeps a genuine
-- runtime dependence on @tag@; it always evaluates to False because the tag
-- is a 'kontDepth' (>= 0 by construction).
{-# NOINLINE mkOneShotFlag #-}
mkOneShotFlag :: Int -> OneShotFlag
mkOneShotFlag tag
  | oneShotOracleOn = Just (unsafePerformIO (newIORef (tag < 0)))
  | otherwise       = Nothing

-- | Assert the oracle at a continuation application: flip the used-flag and
-- fail on a second application of the same continuation value. A 'Nothing'
-- flag (oracle off) is free. The IO depends on the ref argument, so it cannot
-- be floated out of the application site.
{-# NOINLINE assertOneShot #-}
assertOneShot :: OneShotFlag -> Either RuntimeError ()
assertOneShot Nothing = Right ()
assertOneShot (Just r) =
  if unsafePerformIO (atomicModifyIORef' r (\used -> (True, used)))
    then Left OneShotViolation
    else Right ()

-- | A user-written 0-arity binding (CAF) whose body raised a 'RuntimeError'
-- when forced. Because a CAF lives in the lazy 'gEnv' 'Map' as a pure 'Value'
-- thunk, an evaluation error cannot be returned as a 'Left' from the point of
-- the force; it is thrown as this imprecise exception and re-caught at the
-- 'runModule' boundary, where it is turned back into the ORIGINAL 'RuntimeError'
-- (no information lost, no internal-invariant relabelling). Compiler-generated
-- CAFs (dictionaries) never fail, so this only ever carries a genuine user
-- runtime error.
newtype CafFailure = CafFailure RuntimeError
  deriving (Show)

instance Exception CafFailure

-- ---------------------------------------------------------------------------
-- Atom resolution and binder helpers

-- | Resolve an atom: literal -> value; prim -> prim table by name; variable ->
-- env by Unique, else UnboundVar. A builtin reaches the interpreter ONLY as an
-- 'APrim' (the elaborator routes prelude @extern@s there by identity); a missing
-- 'AVar' is a genuine unbound binder, NOT a same-named builtin -- there is no
-- by-hint fallback (#12).
resolveAtom :: PrimTable -> Scope -> Atom -> Either RuntimeError Value
resolveAtom _     _  (ALit l) = Right (VLit l)
resolveAtom prims _  (APrim (m, name)) =
  case Map.lookup (m, name) prims of
    Just p  -> Right (VPrim p)
    Nothing -> Left (UnboundPrim name)
resolveAtom _     sc (AVar n) =
  case Map.lookup (nameUniq n) (scEnv sc) of
    Just v  -> Right v
    Nothing -> Left (UnboundVar (nameHint n))

bindBinder :: Binder -> Value -> Env -> Env
bindBinder b v = Map.insert (nameUniq (bndName b)) v

bindBinders :: [Binder] -> [Value] -> Env -> Env
bindBinders bs vs env = foldl' (\e (b, v) -> bindBinder b v e) env (zip bs vs)

-- ---------------------------------------------------------------------------
-- Rendering (deterministic; used by tests and program output)

renderValue :: Value -> Text
renderValue (VLit l) = renderLit l
renderValue (VCon "Nil" [])        = Tx.pack "[]"
renderValue v@(VCon "Cons" [_, _]) = renderList v
-- Arrays are rendered as [a, b, c] to match the RC interpreter's NArray renderer.
renderValue (VCon "Array" vs)      =
  Tx.pack "[" <> Tx.intercalate (Tx.pack ", ") (map renderValue vs) <> Tx.pack "]"
renderValue (VCon tag vs)
  | Just n <- tupleArity tag, length vs == n =
      Tx.pack "(" <> Tx.intercalate (Tx.pack ", ") (map renderValue vs) <> Tx.pack ")"
renderValue (VCon c [])  = c
renderValue (VCon c vs)  =
  c <> Tx.pack "(" <> Tx.intercalate (Tx.pack ", ") (map renderValue vs) <> Tx.pack ")"
renderValue (VRecord t m) =
  t <> Tx.pack " { "
    <> Tx.intercalate (Tx.pack ", ")
         [ l <> Tx.pack " = " <> renderValue fv | (l, fv) <- Map.toList m ]
    <> Tx.pack " }"
renderValue VClosure{} = Tx.pack "<closure>"
renderValue VPrim{}    = Tx.pack "<builtin>"
renderValue VCont{}    = Tx.pack "<continuation>"
renderValue VContP{}   = Tx.pack "<continuation>"
renderValue (VInst _ _) = Tx.pack "<instance>"
renderValue (VHandler _ _) = Tx.pack "<handler>"
renderValue (VBytes bs) = Tx.pack ("Bytes" <> show (BS.unpack bs))

renderLit :: Lit -> Text
renderLit (LInt n)  = Tx.pack (show n)
renderLit (LStr s)  = Tx.pack (show s)
renderLit (LChar c) = Tx.pack (show c)
renderLit LUnit     = Tx.pack "()"

-- | Render a proper Cons/Nil list as [a, b, c]. An improper tail renders the
-- remainder after a '|' so malformed lists are still total and visible.
renderList :: Value -> Text
renderList = go []
  where
    go acc (VCon "Nil" [])        = Tx.pack "[" <> Tx.intercalate (Tx.pack ", ") (reverse acc) <> Tx.pack "]"
    go acc (VCon "Cons" [h, t])   = go (renderValue h : acc) t
    go acc other                  =
      Tx.pack "[" <> Tx.intercalate (Tx.pack ", ") (reverse acc)
        <> Tx.pack " | " <> renderValue other <> Tx.pack "]"

-- | If the tag is "TupleN", return N.
tupleArity :: Text -> Maybe Int
tupleArity t = case Tx.stripPrefix (Tx.pack "Tuple") t of
  Just rest | not (Tx.null rest), Tx.all (`elem` ['0' .. '9']) rest -> Just (read (Tx.unpack rest))
  _ -> Nothing
