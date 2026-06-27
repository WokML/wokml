-- | Inference-time and closed type representations for the HM core checker.
--
-- Types are a single KINDED expression sort: a node of kind 'KStar' is an
-- ordinary type; a node of kind 'KEffect' is an effect/record ROW (built with
-- 'RowEmpty'/'RowExtend', closed 'CREmpty'/'CRExtend'). The function arrow
-- 'TArr' / 'CTArr' carries a row in its middle slot, and the 'Row' / 'CRow'
-- aliases mark row positions. (Slice A merged the formerly separate row sort
-- into this representation.)
module Wok.TypeChecking.Types
  ( -- * Kinds
    Kind (..)
    -- * Inference-time types (carry mutable cells via STRef)
  , Type (..)
  , TVar (..)
    -- * Effect rows (a row is a 'Type' / 'CType' of kind 'KEffect')
  , Row
    -- * Closed (post-freeze) types and rows
  , CType (..)
  , CRow
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
  | TcBytes
  | TcChar
  | TcString
  | TcNever
  | TcBool
  | TcUnit
  | TcTuple Int
  | TcList
  | TcArray
  | TcUser Text
  -- | An effect-instance HANDLE type. @TcEffect "State"@ applied to args
  -- (e.g. @TCon (TcEffect "State") [U64]@) is the type of a named effect
  -- instance bound by a named @with@ form (@with s = state 0 in ...@). The
  -- dot accessor dispatches a named perform off such a value (see
  -- 'Wok.TypeChecking.Infer.inferProjection'). Distinct from 'TcUser', which
  -- tags ordinary (data) type constructors.
  | TcEffect Text
  deriving (Eq, Ord, Show)

-- | A type EXPRESSION. After the merge this spans kinds: a node of kind KStar is
-- an ordinary type; a node of kind KEffect is an effect/record ROW (built with
-- 'RowEmpty'/'RowExtend'). The 'Row' alias marks row positions.
data Type s
  = TCon TyCon [Type s]
  | TArr (Type s) (Row s) (Type s)    -- domain -[row]-> codomain ; MIDDLE is a row (KEffect)
  -- | Nominal-tagged record type. The 'Text' is the constructor tag
  -- (e.g., \"Point\") and is load-bearing for nominal identity.
  -- Unification of two 'TRecord's requires tag equality; see
  -- 'Wok.TypeChecking.Unify'. The child is a row (KEffect).
  | TRecord Text (Row s)
  | RowEmpty                          -- {} : KEffect
  | RowExtend Text (Type s) (Row s)   -- label, payload (KStar), rest (a row)
  | TVar (STRef s (TVar s))

-- | A row is a 'Type' of kind 'KEffect' (alias documents intent).
type Row s = Type s

data TVar s
  = Unbound { uniq :: Int, level :: Level, kind :: Kind }
  | Rigid   { uniq :: Int, rigidLevel :: Level, kind :: Kind }
    -- ^ Rigid (frozen) type introduced by freezeSig. Represents a rigid
    -- type — an opaque constant the unifier can only equate with itself.
    -- See freezeSig in Wok.TypeChecking.Infer for the over-promising
    -- motivation. The 'Level' records the scope at which the skolem was
    -- minted (the level current when 'freezeSigSkolems' created it). Pinning a
    -- metavar from a SHALLOWER (outer) level to this skolem would let the rigid
    -- escape its binding's scope, so 'rigidUnify' rejects it as a 'RigidEscape'
    -- -- the same level discipline 'occursAdjust' applies to ordinary vars.
  | Link (Type s)
-- A row variable is a 'TVar' whose cell has @kind = KEffect@.

data CType
  = CTCon TyCon [CType]
  | CTArr CType CRow CType             -- MIDDLE is a row (KEffect)
  | CTRecord Text CRow                 -- ^ Nominal-tagged record type, closed form.
  | CREmpty                           -- {} : KEffect (closed)
  | CRExtend Text CType CRow          -- label, payload, rest (a row)
  | CTGen Int                         -- quantified var; kind from the Scheme quantifier list
  deriving (Eq, Show)

-- | A closed row is a closed 'CType' of kind 'KEffect' (alias documents intent).
type CRow = CType

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
