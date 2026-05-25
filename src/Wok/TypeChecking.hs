-- | Public API of the wok HM core typechecker.
module Wok.TypeChecking
  ( -- Pipeline
    inferProgram
    -- Pretty
  , prettyScheme
    -- Typed AST (v1)
  , TypedDecl (..)
    -- Errors
  , TypeError (..)
    -- Environment
  , Env (..)
  , ConInfo (..)
  , TyConInfo (..)
    -- Types
  , Scheme (..)
  , CType (..)
  , CRow (..)
  , Kind (..)
  , TyCon (..)
  ) where

import Wok.TypeChecking.Env (Env (..), ConInfo (..), TyConInfo (..))
import Wok.TypeChecking.Error (TypeError (..))
import Wok.TypeChecking.Infer (TypedDecl (..), inferProgram, prettyScheme)
import Wok.TypeChecking.Types
  ( CRow (..), CType (..), Kind (..), Scheme (..), TyCon (..) )
