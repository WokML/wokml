-- | Where a module's source came from. Used to tag every LoadedModule
-- and to gate origin-sensitive typechecker behavior (e.g. bodyless-sig
-- warnings are silent for Embedded but emitted for UserFile).
--
-- Lives in its own leaf module so both Wok.Loader and
-- Wok.TypeChecking.Infer can depend on it without a cyclic import.
module Wok.SourceOrigin
  ( Origin (..)
  , originPath
  ) where

data Origin = Embedded | UserFile FilePath
  deriving (Eq, Show)

originPath :: Origin -> String
originPath Embedded        = "<Base>"
originPath (UserFile path) = path
