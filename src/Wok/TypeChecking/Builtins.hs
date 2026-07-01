-- | The irreducible pre-environment. Everything spellable in Wok lives
-- in Std.Base (loaded by Wok.Loader before user code). Only the tycons
-- that cannot be expressed in surface Wok stay here:
--
--   * U64                  -- opaque machine integer
--   * ()                   -- unit; parens aren't a ConId
--   * []                   -- cons list; brackets aren't a ConId
--   * (,), (,,), ... (16-tuple) -- parens aren't a ConId
--
-- No constructors, no operator schemes, no helpers.
--
-- The built-in ground effect:
--
--   * IO -- the ground effect: no ops, never handled, discharged by the runtime.
module Wok.TypeChecking.Builtins
  ( initialEnv
  ) where

import qualified Data.Map.Strict as Map
import qualified Data.Text
import Data.Text (Text)
import Wok.TypeChecking.Env (Env (..), TyConInfo (..), ConInfo, EffectInfo (..), emptyEnv)
import Wok.TypeChecking.Types (Kind (..))

initialEnv :: Env
initialEnv = emptyEnv
  { envTyCons   = Map.fromList tyConEntries
  , envCons     = Map.fromList conEntries
  , envEffects  = Map.fromList effectEntries
  }
  where
    listKind :: Kind
    listKind = KArrow KStar KStar

    tyConEntries :: [(Text, TyConInfo)]
    tyConEntries =
      [ ("U64",    TyConInfo KStar 0 [] False True [])
      , ("U32",    TyConInfo KStar 0 [] False True [])
      , ("String", TyConInfo KStar 0 [] False True [])
      , ("Bytes",  TyConInfo KStar 0 [] False True [])
      , ("Never",  TyConInfo KStar 0 [] False True [])
      , ("Char",   TyConInfo KStar 0 [] False True [])
      , ("()",     TyConInfo KStar 0 [] False True [])
      , ("[]",     TyConInfo listKind 1 [] False True [KStar])
      , ("Array",  TyConInfo listKind 1 [] False True [KStar])
      ] ++ [ (tupleName n, TyConInfo (tupleKind n) n [] False True (replicate n KStar)) | n <- [2 .. 16] ]

    conEntries :: [(Text, ConInfo)]
    conEntries = []

    -- IO -- the ground effect: no ops, never handled, discharged by the runtime.
    effectEntries :: [(Text, EffectInfo)]
    effectEntries =
      [ ("IO", EffectInfo { eiParams = [], eiOps = Map.empty })
      ]

    tupleName :: Int -> Text
    tupleName n = "(" <> Data.Text.replicate (n - 1) "," <> ")"

    tupleKind :: Int -> Kind
    tupleKind n = foldr KArrow KStar (replicate n KStar)
