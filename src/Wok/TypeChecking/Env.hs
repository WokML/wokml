-- | Typing environment: variables, data constructors, type constructors.
module Wok.TypeChecking.Env
  ( Env (..)
  , ConInfo (..)
  , TyConInfo (..)
  , RecordConInfo (..)
  , EffectInfo (..)
  , ClassInfo (..)
  , InstanceInfo (..)
  , ForeignModuleInfo (..)
  , ForeignMemberInfo (..)
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
  , lookupForeignModule
  , lookupQualifier
  , extendVar
  , extendCon
  , extendTyCon
  , extendRecordCon
  , extendEffect
  , extendClass
  , extendInstance
  , extendForeignModule
  ) where

import Data.List (nub)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified GeneratedParser.Wok.Abs as Abs
import Wok.FFI.Blessed (ArgTransfer)
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
  , tcCarrier :: Bool
    -- ^ True iff declared by an @extern data@/@extern type@ (Embedded-only). A
    -- carrier tycon is second-class (no escape); the Carrier analyses consult
    -- this flag, not a TyCon tag.
  , tcAffine :: Bool
    -- ^ True iff this carrier is consume-once (affine) -- e.g. 'Suspension'/
    -- 'Step'/'ContCell' may be used at most once in a consuming position.
    -- False marks a carrier that stays second-class (no escape) but may be
    -- read any number of times, e.g. 'Borrow' (FFI Slice 3). Meaningless when
    -- 'tcCarrier' is False; defaults to True everywhere so every carrier
    -- declared before this flag existed is unchanged.
  , tcParamKinds :: [Kind]
    -- ^ Kind of each parameter, in order (KStar for bare, KEffect for @(row e)@);
    -- slice B. Length matches 'tcArity'.
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

-- | One declared member of a foreign module.
-- The 'fmiScheme' is translated from the member's declared type just as
-- a top-level signature is ('translateSig'), so it may carry an effect row
-- (e.g. @U64 -> U64 with IO@ becomes @CTArr CTU64 (CRExtend "IO" ...) CTU64@).
data ForeignMemberInfo = ForeignMemberInfo
  { fmiScheme      :: Scheme   -- ^ The member's declared type scheme.
  , fmiSymbol      :: Text     -- ^ The C symbol name (FSName override or the member name).
  , fmiOwned       :: Bool     -- ^ True iff declared with the @owned@ keyword.
  , fmiArgTransfer :: [ArgTransfer]
    -- ^ Per-parameter transfer marker (FFI Slice 4), one entry per parameter
    -- in declaration order: 'Wok.FFI.Blessed.MoveOut' where the surface
    -- parameter type was @owned T@, 'Wok.FFI.Blessed.TransferNone'
    -- otherwise. Carried but not yet acted on at runtime (Task 1); mirrors
    -- the blessed table's 'Wok.FFI.Blessed.bsArgTransfer'.
  }
  deriving (Eq, Show)

-- | A declared @foreign module@ binding: a C library mapped to a wok namespace.
data ForeignModuleInfo = ForeignModuleInfo
  { fmLib     :: Text                    -- ^ Library tag (e.g. @"c"@).
  , fmFree    :: Maybe Text              -- ^ Optional free-function symbol (e.g. @"free"@).
  , fmMembers :: Map Text ForeignMemberInfo  -- ^ Member name -> member info.
  }
  deriving (Eq, Show)

data Env = Env
  { envVars           :: Map Text Scheme
  , envCons           :: Map Text ConInfo
  , envTyCons         :: Map Text TyConInfo
  , envRecordCons     :: Map Text RecordConInfo
  , envEffects        :: Map Text EffectInfo
  , envClasses        :: Map Text ClassInfo
  , envInstances      :: [InstanceInfo]
  , envForeignModules :: Map Text ForeignModuleInfo
    -- ^ Foreign-module namespace: ConId -> ForeignModuleInfo.
  , -- | Binding provenance for the VAR namespace: var name -> defining
    -- module name. Populated by the pipeline (each new var gets its
    -- defining module's name) and unioned through 'overlayEnvs'. Lets
    -- 'overlayEnvs' tell a benign diamond re-export (same origin) apart
    -- from a genuine cross-module redefinition (different origin), even
    -- when the two share an identical 'Scheme'. A var may have no recorded
    -- origin (e.g. envs built directly via 'extendVar' in unit tests); in
    -- that case 'overlayEnvs' falls back to comparing 'Scheme's.
    envVarOrigin  :: Map Text Text
  , -- | Qualified-value access: qualifier name -> (source module name,
    -- var-name -> scheme snapshot). Built FRESHLY per module by the
    -- pipeline from that module's own 'import' declarations (non-
    -- transitive: 'overlayEnvs' does NOT merge this field -- qualifiers
    -- don't propagate through diamond merges). A bare 'import Foo'
    -- (single-segment) registers Foo; 'import M as A' registers A;
    -- 'import Foo.Bar' (multi-seg plain) registers nothing (single-seg
    -- qualifier only). The typechecker consults this map at the
    -- 'EProj (ECon q) label' arm before falling through to effect /
    -- foreign-module / record projection.
    envQualifiers :: Map Text (Text, Map Text Scheme)
  }
  deriving (Eq, Show)

emptyEnv :: Env
emptyEnv = Env Map.empty Map.empty Map.empty Map.empty Map.empty Map.empty [] Map.empty Map.empty Map.empty

-- | Tag for which of the Env namespaces a name lives in.
-- Used by 'overlayEnvs' to attribute collisions.
data EnvNs = NsVar | NsCon | NsTyCon | NsRecordCon | NsEffect | NsClass
           | NsForeignModule
  deriving (Eq, Ord, Show)

-- | Left-biased union of two 'Env's. On a name collision in any of
-- the namespaces, returns 'Left' with one (namespace, name) pair
-- per offending name. The order of pairs in the result is: envVars
-- collisions first (in Map order), then envCons, then envTyCons, then
-- envRecordCons, then envEffects, then envClasses.
--
-- A name present in BOTH inputs is flagged as a collision only when the two
-- stored entries DIFFER. When both sides carry the identical entry the
-- overlap is benign and merges silently. This is what makes diamond
-- imports work: if @Main@ imports both @Base@ and a module that
-- itself re-exports @Base@ (e.g. @Control@), every shared
-- @Base@ name appears in both per-module envs with the same value, so
-- it must not be reported as a conflict.
--
-- BINDING PROVENANCE (var namespace). For the var namespace the stored
-- entry is only the 'Scheme' (the type), NOT the binding's body, so two
-- genuinely different definitions sharing a name AND an identical type
-- signature would be indistinguishable by value alone. To catch those we
-- carry 'envVarOrigin' (var name -> defining module name), populated by the
-- pipeline. A var present in both inputs is a clash iff its recorded
-- origins are known on both sides and DIFFER (a genuine cross-module
-- redefinition), or -- defensively, when an origin is missing -- its
-- 'Scheme's differ. Same-origin overlaps are the diamond case (@Base@
-- re-exported through @Control@ keeps origin @"Base"@ on both
-- sides) and merge silently. The two origin maps are unioned into the
-- result.
--
-- Instances are concatenated and de-duplicated (a diamond would otherwise
-- replay the same @Eq U64@ instance twice).
--
-- "Left-biased" means that on disjoint inputs the result is the
-- straightforward union; the bias only matters at the API contract
-- level since we reject any actual differing overlap rather than silently
-- picking a side.
overlayEnvs :: Env -> Env -> Either [(EnvNs, Text)] Env
overlayEnvs (Env v1 c1 tc1 rc1 ef1 cl1 ii1 fm1 o1 q1)
            (Env v2 c2 tc2 rc2 ef2 cl2 ii2 fm2 o2 _q2) =
  let differing m1 m2 =
        Map.keys (Map.filter id (Map.intersectionWith (/=) m1 m2))
      -- A shared var clashes when its origins are known and differ (a
      -- genuine cross-module redefinition), or -- as a fallback when an
      -- origin is missing -- when its stored 'Scheme's differ.
      originDiffers k = case (Map.lookup k o1, Map.lookup k o2) of
                          (Just a, Just b) -> a /= b
                          _                -> False
      schemeDiffers k = case (Map.lookup k v1, Map.lookup k v2) of
                          (Just a, Just b) -> a /= b
                          _                -> False
      varClash = [ k | k <- Map.keys (Map.intersectionWith (\_ _ -> ()) v1 v2)
                     , originDiffers k || schemeDiffers k ]
      conClash = differing c1 c2
      tcClash  = differing tc1 tc2
      rcClash  = differing rc1 rc2
      efClash  = differing ef1 ef2
      clClash  = differing cl1 cl2
      fmClash  = differing fm1 fm2
      clashes  =  [ (NsVar,           k) | k <- varClash ]
               ++ [ (NsCon,           k) | k <- conClash ]
               ++ [ (NsTyCon,         k) | k <- tcClash  ]
               ++ [ (NsRecordCon,     k) | k <- rcClash  ]
               ++ [ (NsEffect,        k) | k <- efClash  ]
               ++ [ (NsClass,         k) | k <- clClash  ]
               ++ [ (NsForeignModule, k) | k <- fmClash  ]
  in case clashes of
       [] -> Right (Env (Map.union v1 v2) (Map.union c1 c2) (Map.union tc1 tc2)
                         (Map.union rc1 rc2) (Map.union ef1 ef2)
                         (Map.union cl1 cl2) (nub (ii1 ++ ii2))
                         (Map.union fm1 fm2)
                         (Map.union o1 o2)
                         q1)
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

lookupForeignModule :: Text -> Env -> Maybe ForeignModuleInfo
lookupForeignModule k = Map.lookup k . envForeignModules

extendForeignModule :: Text -> ForeignModuleInfo -> Env -> Env
extendForeignModule k v e = e { envForeignModules = Map.insert k v (envForeignModules e) }

-- | Look up a registered qualifier. Returns the source module name and the
-- var-scheme snapshot for qualified-value resolution (e.g. @A.x@ after
-- @import M as A@).
lookupQualifier :: Text -> Env -> Maybe (Text, Map Text Scheme)
lookupQualifier k = Map.lookup k . envQualifiers
