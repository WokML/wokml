-- | The per-module typecheck fold shared by `app/Main.hs` and the test
-- harness. Given a list of LoadedModules in topo order plus the entry
-- module's name (from `Wok.Loader.loadProgram`), thread the per-module
-- work: merge imports' fixities, merge imports' envs, reorder
-- expressions with the merged fixity table, and run `inferProgramWith`
-- with the merged env. Returns the entry module's typed decls plus the
-- accumulated warnings from every module (in source order).
--
-- All error paths are stringified for v1; a typed PipelineError sum
-- can be carved out later if any caller wants to discriminate.
module Wok.Pipeline
  ( typecheckProgram
  ) where

import Control.Monad (foldM)
import Data.Bifunctor (first)
import qualified Data.Map.Strict as Map
import qualified Data.Text as Tx

import Wok.Loader (LoadedModule (..), ModuleName)
import Wok.Reordering
  ( emptyFixityTable
  , overlayFixities
  , reorderModuleWith
  )
import qualified Wok.TypeChecking as TC
import qualified Wok.TypeChecking.Builtins as B
import Wok.TypeChecking.Env (emptyEnv, overlayEnvs)

typecheckProgram
  :: ModuleName     -- entry module name (from Loader)
  -> [LoadedModule] -- modules in topo order
  -> Either String ([TC.TypedDecl], [TC.Warning])
typecheckProgram entryName = go Map.empty Map.empty Map.empty []
  where
    go tdMap _envs _fix warns [] =
      Right (Map.findWithDefault [] entryName tdMap, reverse warns)
    go tdMap envsByMod fixByMod warns (m : rest) = do
      -- Loader topo-sort contract: every import has already been
      -- processed. Map.! on a missing key is a contract-violation panic
      -- by design — better a clear crash than silent wrong output.
      let importedFixs = [ fixByMod  Map.! n | n <- lmImports m ]
          importedEnvs = [ envsByMod Map.! n | n <- lmImports m ]
          -- Seed env-merge with B.initialEnv only for root modules (no
          -- imports — in practice just Std.Base). Modules WITH imports
          -- inherit B.initialEnv transitively through the chain, so
          -- re-seeding would re-collide on U64 / tuples / [].
          envSeed = if null importedEnvs then B.initialEnv else emptyEnv
          ctx s   = s ++ " in " ++ Tx.unpack (lmName m) ++ ": "
      -- importsFix only (NOT overlaid with the module's own fixities),
      -- because reorderModuleWith re-derives and overlays the module's
      -- own table internally. Self-overlay would flag every own fixity
      -- as RedeclaredOp.
      importsFix <- first ((ctx "fixity merge" ++) . show)
                      (foldM overlayFixities emptyFixityTable importedFixs)
      mergedEnv  <- first ((ctx "env merge" ++) . show)
                      (foldM overlayEnvs envSeed importedEnvs)
      ast        <- first ((ctx "reorder" ++) . show)
                      (reorderModuleWith importsFix (lmAst m))
      (envOut, decls, ws) <- first ((ctx "typecheck" ++) . show)
                      (TC.inferProgramWith mergedEnv (lmOrigin m) ast)
      go (Map.insert (lmName m) decls   tdMap)
         (Map.insert (lmName m) envOut  envsByMod)
         (Map.insert (lmName m) (lmFixities m) fixByMod)
         (reverse ws ++ warns)
         rest
