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
module Wok.TypeChecking.Builtins
  ( initialEnv
  ) where

import qualified Data.Map.Strict as Map
import qualified Data.Text
import Data.Text (Text)
import Wok.TypeChecking.Env (Env (..), TyConInfo (..), emptyEnv)
import Wok.TypeChecking.Types (Kind (..))

initialEnv :: Env
initialEnv = emptyEnv
  { envTyCons = Map.fromList tyConEntries
  }
  where
    listKind :: Kind
    listKind = KArrow KStar KStar

    tyConEntries :: [(Text, TyConInfo)]
    tyConEntries =
      [ ("U64",    TyConInfo KStar 0 [])
      , ("String", TyConInfo KStar 0 [])
      , ("Char",   TyConInfo KStar 0 [])
      , ("()",     TyConInfo KStar 0 [])
      , ("[]",     TyConInfo listKind 1 [])
      ] ++ [ (tupleName n, TyConInfo (tupleKind n) n []) | n <- [2 .. 16] ]

    tupleName :: Int -> Text
    tupleName n = "(" <> Data.Text.replicate (n - 1) "," <> ")"

    tupleKind :: Int -> Kind
    tupleKind n = foldr KArrow KStar (replicate n KStar)
