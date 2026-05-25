-- | Typing environment: variables, data constructors, type constructors.
module Wok.TypeChecking.Env
  ( Env (..)
  , ConInfo (..)
  , TyConInfo (..)
  , emptyEnv
  , lookupVar
  , lookupCon
  , lookupTyCon
  , extendVar
  , extendCon
  , extendTyCon
  ) where

import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import Wok.TypeChecking.Types (Kind, Scheme)

data ConInfo = ConInfo
  { conScheme :: Scheme
  , conArity :: Int
  , conTyCon :: Text
  }
  deriving (Eq, Show)

data TyConInfo = TyConInfo
  { tcKind :: Kind
  , tcArity :: Int
  , tcCons :: [Text]
  }
  deriving (Eq, Show)

data Env = Env
  { envVars :: Map Text Scheme
  , envCons :: Map Text ConInfo
  , envTyCons :: Map Text TyConInfo
  }
  deriving (Eq, Show)

emptyEnv :: Env
emptyEnv = Env Map.empty Map.empty Map.empty

lookupVar :: Text -> Env -> Maybe Scheme
lookupVar k = Map.lookup k . envVars

lookupCon :: Text -> Env -> Maybe ConInfo
lookupCon k = Map.lookup k . envCons

lookupTyCon :: Text -> Env -> Maybe TyConInfo
lookupTyCon k = Map.lookup k . envTyCons

extendVar :: Text -> Scheme -> Env -> Env
extendVar k v e = e { envVars = Map.insert k v (envVars e) }

extendCon :: Text -> ConInfo -> Env -> Env
extendCon k v e = e { envCons = Map.insert k v (envCons e) }

extendTyCon :: Text -> TyConInfo -> Env -> Env
extendTyCon k v e = e { envTyCons = Map.insert k v (envTyCons e) }
