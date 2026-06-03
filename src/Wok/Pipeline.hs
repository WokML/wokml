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
  , elaborateProgram
  , elaborateProgramFull
  ) where

import Control.Monad (foldM)
import Data.Bifunctor (first)
import qualified Data.Map.Strict as Map
import qualified Data.Text as Tx

import Wok.IR.Anf (CoreModule)
import Wok.IR.Elaborate (elaborateModule, elaborateModulesShared)
import Wok.Loader (LoadedModule (..), ModuleName)
import Wok.Reordering
  ( emptyFixityTable
  , overlayFixities
  , reorderModuleWith
  )
import qualified Wok.TypeChecking as TC
import qualified Wok.TypeChecking.Builtins as B
import Wok.TypeChecking.Env (emptyEnv, overlayEnvs)

-- | Per-module result of the typecheck fold, carrying only what is needed
-- for both typecheckProgram and elaborateProgram.
data ModResult = ModResult
  { mrDecls  :: [TC.TypedDecl]
  , mrEnvOut :: TC.Env
  }

-- | Run the shared typecheck fold over all modules in topo order.
-- Returns a map from module name to its ModResult, plus all warnings.
runPipelineFold
  :: ModuleName
  -> [LoadedModule]
  -> Either String (Map.Map ModuleName ModResult, [TC.Warning])
runPipelineFold _entryName = go Map.empty Map.empty Map.empty []
  where
    go resultMap _envsByMod _fixByMod warns [] =
      Right (resultMap, reverse warns)
    go resultMap envsByMod fixByMod warns (m : rest) = do
      let importedFixs = [ fixByMod  Map.! n | n <- lmImports m ]
          importedEnvs = [ envsByMod Map.! n | n <- lmImports m ]
          envSeed = if null importedEnvs then B.initialEnv else emptyEnv
          ctx s   = s ++ " in " ++ Tx.unpack (lmName m) ++ ": "
      importsFix <- first ((ctx "fixity merge" ++) . show)
                      (foldM overlayFixities emptyFixityTable importedFixs)
      mergedEnv  <- first ((ctx "env merge" ++) . show)
                      (foldM overlayEnvs envSeed importedEnvs)
      ast        <- first ((ctx "reorder" ++) . show)
                      (reorderModuleWith importsFix (lmAst m))
      (envOut, decls, ws) <- first ((ctx "typecheck" ++) . show)
                      (TC.inferProgramWith mergedEnv (lmOrigin m) ast)
      let mr = ModResult decls envOut
      go (Map.insert (lmName m) mr         resultMap)
         (Map.insert (lmName m) envOut     envsByMod)
         (Map.insert (lmName m) (lmFixities m) fixByMod)
         (reverse ws ++ warns)
         rest

typecheckProgram
  :: ModuleName     -- entry module name (from Loader)
  -> [LoadedModule] -- modules in topo order
  -> Either String ([TC.TypedDecl], [TC.Warning])
typecheckProgram entryName ms = do
  (resultMap, warns) <- runPipelineFold entryName ms
  let decls = maybe [] mrDecls (Map.lookup entryName resultMap)
  Right (decls, warns)

-- | Run the full typecheck pipeline and elaborate the entry module into ANF.
-- The entry module is identified by `entryName == lmName m`.
elaborateProgram
  :: ModuleName
  -> [LoadedModule]
  -> Either String CoreModule
elaborateProgram entryName ms = do
  (resultMap, _warns) <- runPipelineFold entryName ms
  case Map.lookup entryName resultMap of
    Nothing -> Left ("elaborateProgram: entry module not found: " ++ Tx.unpack entryName)
    Just mr ->
      Right (elaborateModule (mrEnvOut mr) (mrDecls mr))

-- | Elaborate ALL loaded modules into one whole-program CoreModule, sharing a
-- single global-name map so cross-module references resolve consistently.
elaborateProgramFull
  :: ModuleName
  -> [LoadedModule]
  -> Either String CoreModule
elaborateProgramFull entryName ms = do
  (resultMap, _warns) <- runPipelineFold entryName ms
  let mods = [ (mrEnvOut mr, mrDecls mr) | mr <- Map.elems resultMap ]
  Right (elaborateModulesShared mods)
