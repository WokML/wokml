-- | Public API of the wok HM core typechecker.
module Wok.TypeChecking
  ( -- Pipeline
    inferProgram
  , inferProgramWith
    -- Pretty
  , prettyScheme
    -- Typed AST (v1)
  , TypedDecl (..)
    -- Errors / warnings
  , BNFC'Position
  , TypeError (..)
  , Warning (..)
    -- Environment
  , Env (..)
  , ConInfo (..)
  , TyConInfo (..)
    -- Types
  , Scheme (..)
  , CType (..)
  , CRow
  , Kind (..)
  , TyCon (..)
    -- Origin
  , Origin (..)
  , originPath
  ) where

import GeneratedParser.Wok.Abs (BNFC'Position)
import Wok.SourceOrigin (Origin (..), originPath)
import Wok.TypeChecking.Env (Env (..), ConInfo (..), TyConInfo (..))
import Wok.TypeChecking.Error (TypeError (..), Warning (..))
import Wok.TypeChecking.Infer
  ( TypedDecl (..)
  , inferProgram
  , inferProgramWith
  , prettyScheme
  )
import Wok.TypeChecking.Types
  ( CRow, CType (..), Kind (..), Scheme (..), TyCon (..) )
