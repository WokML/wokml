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
  , elaborateCheckedFull
  ) where

import Control.Monad (foldM)
import Data.Bifunctor (first)
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import qualified Data.Text as Tx

import Wok.IR.Anf (CoreModule)
import Wok.IR.Multiplicity (analyzeModule, renderMultiplicityError)
import Wok.IR.PrimNames (onceSinkNames)
import Wok.IR.Elaborate
  ( elaborateModule
  , elaborateModulesShared
  )
import Wok.Loader (LoadedModule (..), ImportSpec (..), ModuleName)
import qualified GeneratedParser.Wok.Abs as Abs
import Wok.Reordering
  ( emptyFixityTable
  , overlayFixities
  , reorderModuleWith
  )
import qualified Wok.TypeChecking as TC
import qualified Wok.TypeChecking.Builtins as B
import Wok.TypeChecking.Env
  ( emptyEnv, overlayEnvs, envVars, envVarOrigin, envQualifiers
  , envEffects, envForeignModules, envRecordCons )
import qualified Wok.TypeChecking.Error as TErr

-- | Filter an imported env's VAR namespace per the 'Abs.ImportMod' modifier.
-- Non-var namespaces (cons, tycons, effects, classes, etc.) are ALWAYS
-- imported wholesale regardless of the modifier (D3: vars-only filter).
-- * 'Abs.IMPlain'      — full env (today's whole-module behavior)
-- * 'Abs.IMList names' — only the listed vars
-- * 'Abs.IMAs _'       — no vars (alias-only; bare names NOT in scope)
filterImportEnv :: Abs.ImportMod -> TC.Env -> TC.Env
filterImportEnv Abs.IMPlain        env = env
filterImportEnv (Abs.IMList names) env =
  env { envVars = Map.filterWithKey (\k _ -> k `Set.member` nameSet) (envVars env) }
  where nameSet = Set.fromList [ n | Abs.INVar (Abs.VarId (_, n)) <- names ]
filterImportEnv (Abs.IMAs _)       env = env { envVars = Map.empty }

-- | Names listed in an explicit @import M (..)@ that M does not actually
-- export (as a value). Checked against the source module's transitive var
-- env (the same env 'filterImportEnv' filters), so re-exported names count.
-- Returns one human-readable message per offending entry; the pipeline fails
-- on the first. Non-list modifiers ('IMPlain' / 'IMAs') contribute nothing.
importListErrors :: Map.Map ModuleName TC.Env -> [ImportSpec] -> [String]
importListErrors envsByMod specs =
  [ "module `" ++ Tx.unpack (isModule s) ++ "` has no exported value `"
      ++ Tx.unpack n ++ "` (referenced in its import list)"
  | s <- specs
  , Abs.IMList names <- [isMod s]
  , Abs.INVar (Abs.VarId (_, n)) <- names
  , not (Map.member n (envVars (envsByMod Map.! isModule s)))
  ]

-- | Build the qualifier registry for this module's OWN imports (non-
-- transitive — only direct imports register qualifiers; 'overlayEnvs'
-- discards the right side's qualifiers so diamond merges don't leak them).
--
-- The qualifier exposes ALL of the source module's vars (the list filters
-- only the UNQUALIFIED scope, per "the rest should be qualified").
--
-- Qualifier name:
-- * 'Abs.IMAs' (ConId alias) — the alias (e.g. @Base@ from @import Std.Base as Base@)
-- * 'Abs.IMPlain' / 'Abs.IMList' — the module's own name, but ONLY if
--   single-segment (no dots). Multi-seg plain imports register nothing
--   (D2: single-seg qualifier only; @Std.Base.x@ doesn't parse).
buildQualifierMap
  :: [ImportSpec]
  -> Map.Map ModuleName TC.Env
  -> Map.Map Tx.Text (Tx.Text, Map.Map Tx.Text TC.Scheme)
buildQualifierMap specs envsByMod =
  Map.fromList
    [ (qual, (srcMod, envVars srcEnv))
    | spec <- specs
    , let srcMod = isModule spec
    , Just qual <- [qualifierName spec]
    , Just srcEnv <- [Map.lookup srcMod envsByMod]
    ]
  where
    qualifierName :: ImportSpec -> Maybe Tx.Text
    qualifierName (ImportSpec modTxt imod) =
      case imod of
        Abs.IMAs (Abs.ConId (_, a)) -> Just a
        _                           -> singleSeg modTxt
    singleSeg t
      | Tx.elem '.' t = Nothing
      | otherwise     = Just t

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
      let specs       = lmImports m
          ctx s   = s ++ " in " ++ Tx.unpack (lmName m) ++ ": "
      -- Reject any explicit `import M (..)` list entry that M does not actually
      -- export; a silent drop would turn a typo into a confusing UnknownVar at
      -- the use site (or worse, a fallthrough to some unrelated binding).
      case importListErrors envsByMod specs of
        (err : _) -> Left (ctx "import list" ++ err)
        []        -> pure ()
      let importedFixs = [ fixByMod  Map.! isModule s | s <- specs ]
          -- Filter each imported env's vars per its ImportMod before merging.
          importedEnvs = [ filterImportEnv (isMod s) (envsByMod Map.! isModule s)
                         | s <- specs ]
          envSeed = if null importedEnvs then B.initialEnv else emptyEnv
      importsFix <- first ((ctx "fixity merge" ++) . show)
                      (foldM overlayFixities emptyFixityTable importedFixs)
      mergedEnv  <- first ((ctx "env merge" ++) . show)
                      (foldM overlayEnvs envSeed importedEnvs)
      -- Build the qualifier registry FRESHLY from this module's own imports.
      -- overlayEnvs discards imported qualifiers (left-biased), so this
      -- overwrite is the sole source of qualifiers for this module's typecheck.
      let quals       = buildQualifierMap specs envsByMod
          mergedEnvQ  = mergedEnv { envQualifiers = quals }
          -- Shadow warning (Q2): a qualifier name that collides with an
          -- existing effect / foreign-module / record-constructor name.
          -- The qualifier still wins (arm order); this is informational.
          shadowWarns =
            [ TErr.QualifierShadowsExisting q src desc
            | (q, (src, _)) <- Map.toList quals
            , desc <- shadowedNamespaces q mergedEnvQ ]
      ast        <- first ((ctx "reorder" ++) . show)
                      (reorderModuleWith importsFix (lmAst m))
      exportFix  <- first ((ctx "fixity merge" ++) . show)
                      (overlayFixities importsFix (lmFixities m))
      (envOut0, decls, ws) <- first ((ctx "typecheck" ++) . show)
                      (TC.inferProgramWith mergedEnvQ (lmOrigin m) ast)
      let newVarNames = Map.keysSet (envVars envOut0)
                          `Set.difference` Map.keysSet (envVars mergedEnvQ)
          origins'    = Map.union (envVarOrigin mergedEnvQ)
                                  (Map.fromSet (const (lmName m)) newVarNames)
          envOut      = envOut0 { envVarOrigin = origins' }
          mr = ModResult decls envOut
      go (Map.insert (lmName m) mr         resultMap)
         (Map.insert (lmName m) envOut     envsByMod)
         (Map.insert (lmName m) exportFix  fixByMod)
         (reverse ws ++ shadowWarns ++ warns)
         rest

-- | Namespaces a qualifier name might shadow. Returns a description string
-- for each collision (empty list if no shadow).
shadowedNamespaces :: Tx.Text -> TC.Env -> [Tx.Text]
shadowedNamespaces q env =
  [ Tx.pack "effect"             | Map.member q (envEffects env) ]
  ++ [ Tx.pack "foreign module"  | Map.member q (envForeignModules env) ]
  ++ [ Tx.pack "record constructor" | Map.member q (envRecordCons env) ]

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
  -- Every value-level prelude @extern@ across all loaded modules, keyed by its
  -- defining @(module, name)@ identity. 'elaborateModule' uses this to build the
  -- entry module's 'ecPrims' so builtins are routed to 'APrim' (the same as the
  -- whole-program path), not emitted as 'AVar' relying on a by-hint fallback.
  let externKeys = Set.fromList
        [ (modName, TC.tdName td)
        | (modName, mr) <- Map.toList resultMap
        , td <- mrDecls mr, TC.tdIsExtern td ]
  case Map.lookup entryName resultMap of
    Nothing -> Left ("elaborateProgram: entry module not found: " ++ Tx.unpack entryName)
    Just mr ->
      Right (elaborateModule entryName externKeys (mrEnvOut mr) (mrDecls mr))

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

-- | Whole-program elaboration plus the one-shot multiplicity law: a multi-shot
-- handler is rejected here as a compile error (stringified, like other v1
-- pipeline errors). The trusted once-sink identities are the static
-- 'Wok.IR.PrimNames.onceSinkNames' (qualified @(module, name)@ keys, matched
-- against the 'APrim' heads the elaborator emits); a user binding merely hinted a
-- sink name resolves to an 'AVar' and is correctly NOT trusted.
elaborateCheckedFull
  :: ModuleName
  -> [LoadedModule]
  -> Either String CoreModule
elaborateCheckedFull entryName ms = do
  cm <- elaborateProgramFull entryName ms
  case analyzeModule onceSinkNames cm of
    []   -> Right cm
    errs -> Left (Tx.unpack
                    (Tx.intercalate (Tx.pack "\n")
                       (map renderMultiplicityError errs)))
