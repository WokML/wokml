-- | Type errors emitted by the HM core checker.
module Wok.TypeChecking.Error
  ( SourceSpan
  , TypeError (..)
  ) where

import Data.Text (Text)
import GeneratedParser.Wok.Abs (BNFC'Position)
import Wok.TypeChecking.Types (CRow, CType)

-- | A source location. Currently the start position of the offending
-- token (BNFC only records token starts, not full spans).
type SourceSpan = BNFC'Position

data TypeError
  = Mismatch SourceSpan CType CType
  | OccursCheck SourceSpan Int CType
  | UnknownVar SourceSpan Text
  | UnknownCon SourceSpan Text
  | UnknownTyCon SourceSpan Text
  | ArityMismatch SourceSpan Text Int Int
    -- ^ name, expected, got
  | RowMismatch SourceSpan CRow CRow
  | SigMismatch SourceSpan Text CType CType
    -- ^ binding name, declared, inferred
  | EscapedTyVar SourceSpan Int
  | RigidEscape SourceSpan Int
    -- ^ A skolem (rigid) type variable from a user-supplied signature was
    -- unified with something other than itself. The Int is the skolem's uniq.
    -- This means the declared signature is more general than what the body
    -- actually delivers.
  | DuplicateTyCon SourceSpan Text
  | DuplicateCon SourceSpan Text
  | DuplicateBinding SourceSpan Text
  | UnsupportedFeature SourceSpan Text
    -- ^ for module access (EProj/EProjC) in v1
  deriving (Show)
