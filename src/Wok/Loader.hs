-- | Multi-module loader: parse + build fixity tables for the Std.Base
-- prelude + every -I file + the entry, build a module map, validate
-- the import dep graph, and return modules in topo order. Expression
-- reordering and typechecking happen downstream (in the caller, per
-- the design spec) using the per-module fixity tables this loader
-- produces.
module Wok.Loader
  ( ModuleName
  , LoadedModule (..)
  , ModuleMap
  , LoaderError (..)
  , loadProgram
  ) where

import Control.Exception (IOException, try)
import Control.Monad.Except (ExceptT (..), liftEither, runExceptT)
import Control.Monad.IO.Class (liftIO)
import Data.Bifunctor (first)
import qualified Data.Graph as G
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text.IO as TIO
import System.IO.Error (isDoesNotExistError)

import GeneratedParser.Wok.Abs
import Wok.Parsing (parse)
import qualified Wok.Prelude as Prelude
import Wok.Reordering
  ( FixityError, FixityTable, ReorderError, buildFixityTable )
import Wok.SourceOrigin (Origin (..), originPath)
import qualified Wok.TypeChecking.Infer as I

type ModuleName = Text
type ModuleMap  = Map ModuleName LoadedModule

data LoadedModule = LoadedModule
  { lmName     :: ModuleName
  , lmOrigin   :: Origin
  , lmAst      :: Module       -- post-parse, PRE-reorder
  , lmImports  :: [ModuleName] -- deduped, source order
  , lmFixities :: FixityTable
  }
  deriving (Show)

data LoaderError
  = LoadFileMissing               FilePath
  | LoadFileError                 FilePath String -- non-"does not exist" IO errors
  | LoadParseError                FilePath String
  | LoadFixityError               FilePath [FixityError]
  | LoadReorderError              ModuleName [ReorderError]
  | LoadCrossModuleFixityConflict Text ModuleName ModuleName
  | LoadCrossModuleNameConflict   Text ModuleName ModuleName
  | LoadNoModuleHeader            FilePath
  | LoadDuplicateModule           ModuleName FilePath FilePath
  | LoadImportUnknown             ModuleName ModuleName       -- (importer, missing-target)
  | LoadImportCycle               [ModuleName]
  deriving (Show)

-- | Load the Std.Base prelude + each user file in [extras] + the entry,
-- validate, dep-sort, return in topo order (Std.Base first, entry last by
-- convention — but callers MUST consume the explicit entry ModuleName
-- returned alongside the module list, not infer it from list position).
-- The prelude source is read at runtime via the cabal-generated
-- Paths_wok.getDataFileName path; the synthetic display tag "<Std.Base>"
-- stands in for the actual on-disk data-file location so user-facing
-- diagnostics don't leak the install-time path.
loadProgram
  :: FilePath          -- entry file
  -> [FilePath]        -- additional -I files (order preserved)
  -> IO (Either LoaderError (ModuleName, [LoadedModule]))
loadProgram entry extras = runExceptT $ do
  preludeText <- liftIO Prelude.preludeSource
  preludeLM   <- liftEither (parseAndPrep "<Std.Base>" Embedded preludeText)
  extraLMs    <- traverse (ExceptT . loadOne) extras
  entryLM     <- ExceptT (loadOne entry)
  mm          <- liftEither (buildMap (preludeLM : extraLMs ++ [entryLM]))
  ms          <- liftEither (topoSort mm)
  pure (lmName entryLM, ms)

-- ---------------------------------------------------------------
-- Reading + parsing one file
-- ---------------------------------------------------------------

loadOne :: FilePath -> IO (Either LoaderError LoadedModule)
loadOne path = do
  bytes <- try (TIO.readFile path) :: IO (Either IOException Text)
  case bytes of
    Left ioe
      | isDoesNotExistError ioe -> pure (Left (LoadFileMissing path))
      | otherwise               -> pure (Left (LoadFileError path (show ioe)))
    Right tx -> pure (parseAndPrep path (UserFile path) tx)

parseAndPrep :: FilePath -> Origin -> Text -> Either LoaderError LoadedModule
parseAndPrep path origin src = do
  ast      <- first (LoadParseError path)  (parse src)
  name     <- maybe (Left (LoadNoModuleHeader path)) Right (extractModuleName ast)
  fixities <- first (LoadFixityError path) (buildFixityTable ast)
  pure LoadedModule
    { lmName     = name
    , lmOrigin   = origin
    , lmAst      = ast
    , lmImports  = extractImports ast
    , lmFixities = fixities
    }

-- v1 expects the module header as the first decl; later semantic-pass
-- relaxation can allow it anywhere as long as it's unique.
extractModuleName :: Module -> Maybe ModuleName
extractModuleName (Module (DModule mp : _)) = Just (I.modPathText mp)
extractModuleName _                          = Nothing

extractImports :: Module -> [ModuleName]
extractImports (Module decls) =
  let names = [ I.modPathText mp | DImport mp <- decls ]
  in dedupe names
  where
    dedupe = go Set.empty
    go _ [] = []
    go seen (x : xs)
      | Set.member x seen = go seen xs
      | otherwise         = x : go (Set.insert x seen) xs

-- ---------------------------------------------------------------
-- Map + topo sort
-- ---------------------------------------------------------------

-- Use foldl' (not foldr) so the FIRST module declaring a given name in
-- CLI argument order is the "original" and any subsequent collision is
-- the "duplicate". foldr would process right-to-left and swap that
-- attribution in the error.
buildMap :: [LoadedModule] -> Either LoaderError ModuleMap
buildMap = foldl' step (Right Map.empty)
  where
    step acc lm = do
      m <- acc
      case Map.lookup (lmName lm) m of
        Just prev -> Left $ LoadDuplicateModule
                       (lmName lm)
                       (originPath (lmOrigin prev))
                       (originPath (lmOrigin lm))
        Nothing -> Right (Map.insert (lmName lm) lm m)

-- Topo-sort with cycle and unknown-import detection.
-- Returns modules in dependency order (a module appears after every
-- module it depends on).
topoSort :: ModuleMap -> Either LoaderError [LoadedModule]
topoSort mm = do
  let missing =
        [ (lmName lm, target)
        | lm <- Map.elems mm
        , target <- lmImports lm
        , not (Map.member target mm)
        ]
  case missing of
    ((importer, target) : _) -> Left (LoadImportUnknown importer target)
    [] -> do
      let nodes = [ (lm, lmName lm, lmImports lm) | lm <- Map.elems mm ]
          sccs  = G.stronglyConnComp nodes
      -- Look for cyclic SCCs (including a single self-imported module).
      case [cyclic | scc <- sccs, Just cyclic <- [asCycle scc]] of
        (cycleMods : _) -> Left (LoadImportCycle (map lmName cycleMods))
        -- stronglyConnComp returns SCCs in reverse topological order:
        -- a node with NO outgoing edges (a "leaf" — a module nothing
        -- depends on) comes last; a node that everything depends on
        -- (like Std.Base) comes first. That is exactly the
        -- dependencies-first order we want.
        -- No cyclic SCCs at this point, so flattenSCC just unwraps each
        -- AcyclicSCC to its singleton; equivalent to a pattern-binder
        -- filter, but the unwrap is explicit instead of incidental.
        [] -> Right (concatMap G.flattenSCC sccs)
  where
    asCycle (G.CyclicSCC ms) = Just ms
    asCycle (G.AcyclicSCC lm)
      | lmName lm `elem` lmImports lm = Just [lm]  -- self-import
      | otherwise = Nothing
