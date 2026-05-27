-- | Typing environment: variables, data constructors, type constructors.
module Wok.TypeChecking.Env
  ( Env (..)
  , ConInfo (..)
  , TyConInfo (..)
  , RecordConInfo (..)
  , EnvNs (..)
  , emptyEnv
  , overlayEnvs
  , lookupVar
  , lookupCon
  , lookupTyCon
  , lookupRecordCon
  , extendVar
  , extendCon
  , extendTyCon
  , extendRecordCon
  ) where

import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import Wok.TypeChecking.Types (CType, Kind, Scheme)

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

-- | Descriptor for a record-form constructor
-- (e.g., @Point@ in @data Point = Point { x : U64, y : U64 }@).
--
-- Distinct from 'ConInfo' (positional constructors), which has a curried
-- function scheme. Record constructors are NOT first-class functions --
-- they exist only in record-literal and record-pattern positions. Lookup
-- of a record constructor name in the value namespace produces a
-- 'RecordConstructorNotAValue' error.
data RecordConInfo = RecordConInfo
  { rcTag    :: Text               -- ^ Nominal tag (the constructor name).
  , rcFields :: [(Text, CType)]    -- ^ Declared fields, in declaration order.
  , rcParams :: [(Int, Kind)]      -- ^ Universally-quantified type params.
  }
  deriving (Eq, Show)

data Env = Env
  { envVars       :: Map Text Scheme
  , envCons       :: Map Text ConInfo
  , envTyCons     :: Map Text TyConInfo
  , envRecordCons :: Map Text RecordConInfo
  }
  deriving (Eq, Show)

emptyEnv :: Env
emptyEnv = Env Map.empty Map.empty Map.empty Map.empty

-- | Tag for which of the four Env namespaces a name lives in.
-- Used by 'overlayEnvs' to attribute collisions.
data EnvNs = NsVar | NsCon | NsTyCon | NsRecordCon
  deriving (Eq, Ord, Show)

-- | Left-biased union of two 'Env's. On any name collision in any of
-- the four namespaces, returns 'Left' with one (namespace, name) pair
-- per offending name. The order of pairs in the result is: envVars
-- collisions first (in Map order), then envCons, then envTyCons, then
-- envRecordCons.
--
-- "Left-biased" means that on disjoint inputs the result is the
-- straightforward union; the bias only matters at the API contract
-- level since we reject any actual overlap rather than silently picking
-- a side.
overlayEnvs :: Env -> Env -> Either [(EnvNs, Text)] Env
overlayEnvs (Env v1 c1 tc1 rc1) (Env v2 c2 tc2 rc2) =
  let varClash = Map.keys (Map.intersection v1 v2)
      conClash = Map.keys (Map.intersection c1 c2)
      tcClash  = Map.keys (Map.intersection tc1 tc2)
      rcClash  = Map.keys (Map.intersection rc1 rc2)
      clashes  =  [ (NsVar,       k) | k <- varClash ]
               ++ [ (NsCon,       k) | k <- conClash ]
               ++ [ (NsTyCon,     k) | k <- tcClash  ]
               ++ [ (NsRecordCon, k) | k <- rcClash  ]
  in case clashes of
       [] -> Right (Env (Map.union v1 v2) (Map.union c1 c2) (Map.union tc1 tc2) (Map.union rc1 rc2))
       _  -> Left clashes

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

lookupRecordCon :: Text -> Env -> Maybe RecordConInfo
lookupRecordCon k = Map.lookup k . envRecordCons

extendRecordCon :: Text -> RecordConInfo -> Env -> Env
extendRecordCon k v e = e { envRecordCons = Map.insert k v (envRecordCons e) }
