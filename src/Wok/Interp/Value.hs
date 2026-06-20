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
  , resolveAtom
  , bindBinder
  , bindBinders
  , renderValue
  ) where

import Control.Exception (Exception)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as Tx
import Wok.IR.Anf (Atom (..), Binder (..), Expr, Handler (..), Lit (..))
import Wok.IR.Name (JoinId, Name (..), Unique, nameHint, nameUniq)

-- | Environment: identity (Unique) -> runtime value.
type Env = Map Unique Value

-- | Join points in scope (local labelled continuations).
type JoinEnv = Map JoinId JoinPoint

-- | Primitive lookup table, keyed by the bodyless global's hint text.
type PrimTable = Map Text Prim

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
  | VCont (Kont -> Kont)   -- a captured deep continuation; arg is the post-resume kont
  | VContP (Value -> Kont -> Kont)   -- parameter-aware resume: \newParam after -> kont
  | VInst Unique !Int      -- a named effect-instance handle. Identity = the
                           -- handler self-binder Unique (the install SITE) paired
                           -- with a per-ACTIVATION tag (the Kont depth at install).
                           -- The tag distinguishes two activations of the SAME
                           -- runner site that coexist (nested), so two same-typed
                           -- instances minted by one prelude runner route apart.

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
  deriving (Eq, Show)

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
resolveAtom prims _  (APrim (_, name)) =
  case Map.lookup name prims of
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
