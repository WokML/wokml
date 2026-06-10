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
import Wok.TypeChecking.Env (Env (..), TyConInfo (..), ConInfo, emptyEnv)
import Wok.TypeChecking.Types (Kind (..))

initialEnv :: Env
initialEnv = emptyEnv
  { envTyCons = Map.fromList tyConEntries
  , envCons   = Map.fromList conEntries
  }
  where
    listKind :: Kind
    listKind = KArrow KStar KStar

    tyConEntries :: [(Text, TyConInfo)]
    tyConEntries =
      [ ("U64",    TyConInfo KStar 0 [] False [])
      , ("U32",    TyConInfo KStar 0 [] False [])
      , ("String", TyConInfo KStar 0 [] False [])
      , ("Never",  TyConInfo KStar 0 [] False [])
      , ("Char",   TyConInfo KStar 0 [] False [])
      , ("()",     TyConInfo KStar 0 [] False [])
      , ("[]",     TyConInfo listKind 1 [] False [KStar])
      ] ++ [ (tupleName n, TyConInfo (tupleKind n) n [] False (replicate n KStar)) | n <- [2 .. 16] ]

    conEntries :: [(Text, ConInfo)]
    conEntries = []

    tupleName :: Int -> Text
    tupleName n = "(" <> Data.Text.replicate (n - 1) "," <> ")"

    tupleKind :: Int -> Kind
    tupleKind n = foldr KArrow KStar (replicate n KStar)
