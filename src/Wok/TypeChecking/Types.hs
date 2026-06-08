-- | Inference-time and closed type representations for the HM core checker.
--
-- The function arrow 'TArr' / 'CTArr' carries an effect-row slot in the
-- middle position (always 'RowEmpty' / 'CREmpty' in v1). This shape is
-- preserved so the future rows-and-effects spec can fill in the row case
-- without rewriting v1 call sites.
module Wok.TypeChecking.Types
  ( -- * Kinds
    Kind (..)
    -- * Inference-time types (carry mutable cells via STRef)
  , Type (..)
  , TVar (..)
    -- * Effect rows
  , Row (..)
  , RVar (..)
    -- * Closed (post-freeze) types and rows
  , CType (..)
  , CRow (..)
    -- * Type schemes (generalised types)
  , Scheme (..)
  , mkScheme
    -- * Class constraints and evidence
  , Constraint (..)
  , Evidence (..)
    -- * Type-constructor tags
  , TyCon (..)
    -- * Generalisation levels
  , Level (..)
  ) where

import Data.STRef (STRef)
import Data.Text (Text)

data Kind
  = KStar
  | KEffect
  | KArrow Kind Kind
  deriving (Eq, Show)

newtype Level = Level Int
  deriving (Eq, Ord, Show)

data TyCon
  = TcU64
  | TcU32
  | TcChar
  | TcString
  | TcNever
  | TcBool
  | TcUnit
  | TcTuple Int
  | TcList
  | TcUser Text
  -- | An effect-instance HANDLE type. @TcEffect "State"@ applied to args
  -- (e.g. @TCon (TcEffect "State") [U64]@) is the type of a named effect
  -- instance bound by a named @with@ form (@with s = state 0 in ...@). The
  -- dot accessor dispatches a named perform off such a value (see
  -- 'Wok.TypeChecking.Infer.inferProjection'). Distinct from 'TcUser', which
  -- tags ordinary (data) type constructors.
  | TcEffect Text
  deriving (Eq, Ord, Show)

data Type s
  = TCon TyCon [Type s]
  | TArr (Type s) (Row s) (Type s)
  -- | Nominal-tagged record type. The 'Text' is the constructor tag
  -- (e.g., \"Point\") and is load-bearing for nominal identity.
  -- Unification of two 'TRecord's requires tag equality; see
  -- 'Wok.TypeChecking.Unify'.
  | TRecord Text (Row s)
  | TVar (STRef s (TVar s))

data TVar s
  = Unbound { uniq :: Int, level :: Level, kind :: Kind }
  | Rigid   { uniq :: Int, kind :: Kind }
    -- ^ Rigid (frozen) type introduced by freezeSig. Represents a rigid
    -- type — an opaque constant the unifier can only equate with itself.
    -- See freezeSig in Wok.TypeChecking.Infer for the over-promising
    -- motivation.
  | Link (Type s)

data Row s
  = RowEmpty
  | RowExtend Text (Type s) (Row s)
  | RowVar (STRef s (RVar s))

data RVar s
  = RUnbound { rUniq :: Int, rLevel :: Level }
  | RLink (Row s)

data CType
  = CTCon TyCon [CType]
  | CTArr CType CRow CType
  | CTRecord Text CRow          -- ^ Nominal-tagged record type, closed form.
  | CTGen Int
  deriving (Eq, Show)

data CRow
  = CREmpty
  | CRExtend Text CType CRow
  | CRGen Int
  deriving (Eq, Show)

data Scheme = Scheme
  { schemeVars        :: [(Int, Kind)]
  , schemeConstraints :: [Constraint]   -- ^ qualified prefix, e.g. [Eq (CTGen 0)]
  , schemeBody        :: CType
  }
  deriving (Eq, Show)

-- | A scheme with no class constraints (the overwhelmingly common case).
mkScheme :: [(Int, Kind)] -> CType -> Scheme
mkScheme vs body = Scheme vs [] body

-- | A single class constraint, e.g. @Eq a@ (single-parameter classes only).
data Constraint = Constraint
  { conClass :: Text   -- ^ class name, e.g. "Eq"
  , conArg   :: CType  -- ^ the (closed) argument type
  }
  deriving (Eq, Show)

-- | A dictionary-passing witness for a discharged constraint.
data Evidence
  = EvGlobal Text             -- ^ a ground instance dict, e.g. "dict$Eq$U64"
  | EvParam  Text             -- ^ an in-scope dictionary parameter, e.g. "d$Eq$0"
  | EvApp    Text [Evidence]  -- ^ a dict-builder applied to sub-evidence
  deriving (Eq, Show)
