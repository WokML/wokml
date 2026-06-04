-- | Typing environment: variables, data constructors, type constructors.
module Wok.TypeChecking.Env
  ( Env (..)
  , ConInfo (..)
  , TyConInfo (..)
  , RecordConInfo (..)
  , EffectInfo (..)
  , ClassInfo (..)
  , InstanceInfo (..)
  , EnvNs (..)
  , emptyEnv
  , overlayEnvs
  , lookupVar
  , lookupCon
  , lookupTyCon
  , lookupRecordCon
  , lookupEffect
  , lookupClass
  , lookupInstances
  , classOfMethod
  , extendVar
  , extendCon
  , extendTyCon
  , extendRecordCon
  , extendEffect
  , extendClass
  , extendInstance
  ) where

import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified GeneratedParser.Wok.Abs as Abs
import Wok.TypeChecking.Types (CType, Constraint, Kind, Scheme)

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

-- | A declared algebraic effect: its type parameters and its operations.
-- Operations are transparent (auto-resume) in v1; an op's 'Scheme' is its
-- declared type (e.g. @read : String -> String@).
data EffectInfo = EffectInfo
  { eiParams :: [(Int, Kind)]      -- ^ universally-quantified params (e.g. @State a@)
  , eiOps    :: Map Text Scheme    -- ^ operation name -> operation type scheme
  }
  deriving (Eq, Show)

-- | A declared type class: its single class parameter, method schemes,
-- default-method bodies, and the declared method names in source order.
data ClassInfo = ClassInfo
  { ciParam       :: (Int, Kind)        -- ^ the single class parameter (CTGen idx, kind)
  , ciMethods     :: Map Text Scheme    -- ^ method name -> its full scheme (incl. the class constraint)
  , ciDefaults    :: Map Text Abs.Exp   -- ^ default-method bodies, keyed by method name
  , ciMethodNames :: [Text]             -- ^ declared methods, in source order
  , ciDictCon     :: Text               -- ^ the dict data constructor name, e.g. "Eq$Dict"
  }
  deriving (Eq, Show)

-- | A declared class instance: which class, the head type, any context
-- constraints, the dictionary name, and the per-method implementations.
data InstanceInfo = InstanceInfo
  { iiClass    :: Text                  -- ^ class name, e.g. "Eq"
  , iiHead     :: CType                 -- ^ instance type, e.g. CTCon TcU64 []
  , iiContext  :: [Constraint]          -- ^ e.g. [Eq (CTGen 0)] for Eq (Option a)
  , iiDictName :: Text                  -- ^ "dict$Eq$U64" / "dict$Eq$Option"
  , iiImpls    :: Map Text Abs.Exp      -- ^ method name -> impl body
  }
  deriving (Eq, Show)

data Env = Env
  { envVars       :: Map Text Scheme
  , envCons       :: Map Text ConInfo
  , envTyCons     :: Map Text TyConInfo
  , envRecordCons :: Map Text RecordConInfo
  , envEffects    :: Map Text EffectInfo
  , envClasses    :: Map Text ClassInfo
  , envInstances  :: [InstanceInfo]
  }
  deriving (Eq, Show)

emptyEnv :: Env
emptyEnv = Env Map.empty Map.empty Map.empty Map.empty Map.empty Map.empty []

-- | Tag for which of the six Env namespaces a name lives in.
-- Used by 'overlayEnvs' to attribute collisions.
data EnvNs = NsVar | NsCon | NsTyCon | NsRecordCon | NsEffect | NsClass
  deriving (Eq, Ord, Show)

-- | Left-biased union of two 'Env's. On any name collision in any of
-- the namespaces, returns 'Left' with one (namespace, name) pair
-- per offending name. The order of pairs in the result is: envVars
-- collisions first (in Map order), then envCons, then envTyCons, then
-- envRecordCons, then envEffects, then envClasses. Instances are
-- concatenated (no collision possible by name).
--
-- "Left-biased" means that on disjoint inputs the result is the
-- straightforward union; the bias only matters at the API contract
-- level since we reject any actual overlap rather than silently picking
-- a side.
overlayEnvs :: Env -> Env -> Either [(EnvNs, Text)] Env
overlayEnvs (Env v1 c1 tc1 rc1 ef1 cl1 ii1) (Env v2 c2 tc2 rc2 ef2 cl2 ii2) =
  let varClash = Map.keys (Map.intersection v1 v2)
      conClash = Map.keys (Map.intersection c1 c2)
      tcClash  = Map.keys (Map.intersection tc1 tc2)
      rcClash  = Map.keys (Map.intersection rc1 rc2)
      efClash  = Map.keys (Map.intersection ef1 ef2)
      clClash  = Map.keys (Map.intersection cl1 cl2)
      clashes  =  [ (NsVar,       k) | k <- varClash ]
               ++ [ (NsCon,       k) | k <- conClash ]
               ++ [ (NsTyCon,     k) | k <- tcClash  ]
               ++ [ (NsRecordCon, k) | k <- rcClash  ]
               ++ [ (NsEffect,    k) | k <- efClash  ]
               ++ [ (NsClass,     k) | k <- clClash  ]
  in case clashes of
       [] -> Right (Env (Map.union v1 v2) (Map.union c1 c2) (Map.union tc1 tc2)
                        (Map.union rc1 rc2) (Map.union ef1 ef2)
                        (Map.union cl1 cl2) (ii1 ++ ii2))
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

lookupEffect :: Text -> Env -> Maybe EffectInfo
lookupEffect k = Map.lookup k . envEffects

extendEffect :: Text -> EffectInfo -> Env -> Env
extendEffect k v e = e { envEffects = Map.insert k v (envEffects e) }

lookupClass :: Text -> Env -> Maybe ClassInfo
lookupClass k = Map.lookup k . envClasses

lookupInstances :: Text -> Env -> [InstanceInfo]
lookupInstances cls e = [ i | i <- envInstances e, iiClass i == cls ]

-- | If a name is a method of some class, return that class name.
classOfMethod :: Text -> Env -> Maybe Text
classOfMethod m e =
  case [ cn | (cn, ci) <- Map.toList (envClasses e), m `elem` ciMethodNames ci ] of
    (cn : _) -> Just cn
    []       -> Nothing

extendClass :: Text -> ClassInfo -> Env -> Env
extendClass k v e = e { envClasses = Map.insert k v (envClasses e) }

extendInstance :: InstanceInfo -> Env -> Env
extendInstance i e = e { envInstances = i : envInstances e }
