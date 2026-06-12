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
  , elaborateProgramFullTrusted
  , elaborateCheckedFull
  ) where

import Control.Monad (foldM)
import Data.Bifunctor (first)
import Data.Maybe (mapMaybe)
import qualified Data.Map.Strict as Map
import Data.Set (Set)
import qualified Data.Set as Set
import qualified Data.Text as Tx

import Wok.IR.Anf (CoreModule)
import Wok.IR.Multiplicity (analyzeModule, renderMultiplicityError)
import Wok.IR.Name (Name, Unique, nameUniq)
import Wok.IR.Elaborate
  ( elaborateModule
  , elaborateModulesShared
  , elaborateModulesSharedWithGlobals
  )
import Wok.Loader (LoadedModule (..), ModuleName)
import Wok.Reordering
  ( emptyFixityTable
  , overlayFixities
  , reorderModuleWith
  )
import qualified Wok.TypeChecking as TC
import qualified Wok.TypeChecking.Builtins as B
import Wok.TypeChecking.Env (emptyEnv, overlayEnvs, envVars, envVarOrigin)

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
      -- The fixity table this module EXPORTS is the transitive closure: the
      -- fixities it imported (importsFix) overlaid with the ones it declares
      -- itself (lmFixities m). Storing this -- rather than lmFixities m alone --
      -- threads operators defined 2+ levels down the import chain through every
      -- importer, mirroring how envOut (a transitive env) is stored below. The
      -- overlay also re-detects any redeclaration the importer makes of an
      -- imported operator (the same check reorderModuleWith already performs).
      exportFix  <- first ((ctx "fixity merge" ++) . show)
                      (overlayFixities importsFix (lmFixities m))
      (envOut0, decls, ws) <- first ((ctx "typecheck" ++) . show)
                      (TC.inferProgramWith mergedEnv (lmOrigin m) ast)
      -- Tag binding provenance for the var namespace: every var introduced
      -- by THIS module (present in envOut0 but not in mergedEnv) gets origin
      -- (lmName m); inherited names keep mergedEnv's origins. inferProgramWith
      -- does not carry the origin field, so we recompute it explicitly here.
      let newVarNames = Map.keysSet (envVars envOut0)
                          `Set.difference` Map.keysSet (envVars mergedEnv)
          origins'    = Map.union (envVarOrigin mergedEnv)
                                  (Map.fromSet (const (lmName m)) newVarNames)
          envOut      = envOut0 { envVarOrigin = origins' }
          mr = ModResult decls envOut
      go (Map.insert (lmName m) mr         resultMap)
         (Map.insert (lmName m) envOut     envsByMod)
         (Map.insert (lmName m) exportFix  fixByMod)
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
  let mods = [ (modName, mrEnvOut mr, mrDecls mr)
             | (modName, mr) <- Map.toList resultMap ]
  Right (elaborateModulesShared mods)

-- | Whole-program elaboration, also returning the trusted ONCE-SINK identities:
-- the set of canonical 'Unique's of the GENUINE prelude once-sink @extern@ prims
-- (currently @(Std.Control, "__coro_susp")@), resolved from the elaborated
-- global-name map by DEFINING MODULE + name (extern identity), NOT by hint text.
-- A user binding merely hinted @__coro_susp@ lives in a different module and so
-- has a distinct identity — it is NOT in the set, hence NOT trusted (C2). The set
-- is empty when Std.Control is not loaded (no genuine escape exists).
elaborateProgramFullTrusted
  :: ModuleName
  -> [LoadedModule]
  -> Either String (CoreModule, Set Unique)
elaborateProgramFullTrusted entryName ms = do
  (resultMap, _warns) <- runPipelineFold entryName ms
  let mods = [ (modName, mrEnvOut mr, mrDecls mr)
             | (modName, mr) <- Map.toList resultMap ]
      (cm, globalByKey) = elaborateModulesSharedWithGlobals mods
      onceSinks = resolveTrusted globalByKey onceSinkKeys
  Right (cm, onceSinks)

-- | The defining module of the genuine prelude coro prims.
stdControlModule :: Tx.Text
stdControlModule = Tx.pack "Std.Control"

-- | The trusted once-sink @extern@ prims, by @(definingModule, name)@: an
-- @extern@ whose semantics is to resume its continuation argument at most once.
-- Currently just @__coro_susp@ (the escape sink @start@ desugars to). This is the
-- C2 registry — a fixed set of prelude extern identities, resolved to 'Unique's.
onceSinkKeys :: [(Tx.Text, Tx.Text)]
onceSinkKeys = [ (stdControlModule, Tx.pack "__coro_susp") ]

-- | Resolve a set of @(module, name)@ extern keys to the canonical 'Unique's they
-- map to in the elaborated global map (silently dropping any not present, e.g.
-- when Std.Control is not loaded).
resolveTrusted :: Map.Map (Tx.Text, Tx.Text) Name -> [(Tx.Text, Tx.Text)] -> Set Unique
resolveTrusted globalByKey keys =
  Set.fromList (mapMaybe (\k -> nameUniq <$> Map.lookup k globalByKey) keys)

-- | Whole-program elaboration plus the one-shot multiplicity law: a multi-shot
-- handler is rejected here as a compile error (stringified, like other v1
-- pipeline errors).
elaborateCheckedFull
  :: ModuleName
  -> [LoadedModule]
  -> Either String CoreModule
elaborateCheckedFull entryName ms = do
  (cm, trusted) <- elaborateProgramFullTrusted entryName ms
  case analyzeModule trusted cm of
    []   -> Right cm
    errs -> Left (Tx.unpack
                    (Tx.intercalate (Tx.pack "\n")
                       (map renderMultiplicityError errs)))
