module Main where

import qualified Control.Exception
import Data.List (sortBy)
import Data.Ord (comparing)
import qualified Data.Text as Tx
import qualified Data.Text.IO as TIO
import System.Environment (getArgs)
import System.Exit (exitFailure)
import System.IO (hPutStrLn, stderr)

import Wok.IR.Anf (prettyModuleTyped)
import Wok.IR.Multiplicity (prettyMultiplicity)
import Wok.IR.PrimNames (onceSinkNames)
import qualified Wok.IR.Perceus as Perceus
import Wok.IR.Reachable (pruneToReachable)
import qualified Wok.Interp as Interp
import qualified Wok.Interp.RC.Heap as Heap
import qualified Wok.Interp.RC.Machine as RCM
import Wok.Interp.RC.Value (HeapBackend (..))
import Wok.Loader (LoaderError (..), loadProgram)
import qualified Wok.Pipeline as Pipeline
import qualified Wok.TypeChecking as TC

-- ----------------------------------------------------------------
-- CLI parsing
-- ----------------------------------------------------------------

usage :: String
usage = "usage: wok <entry.wok> [-I <file.wok>]... [--dump-anf | --dump-perceus | --dump-multiplicity | --dump-rc-stats | --run]"

data CliMode
  = ModePrintSchemes
  | ModeDumpAnf
  | ModeDumpPerceus
  | ModeDumpMultiplicity
  | ModeDumpRcStats
  | ModeRun

main :: IO ()
main = do
  args <- getArgs
  case parseCli args of
    Left msg              -> hPutStrLn stderr msg >> exitFailure
    Right (e, extras, md) -> runApp e extras md

parseCli :: [String] -> Either String (FilePath, [FilePath], CliMode)
parseCli = go Nothing [] ModePrintSchemes
  where
    go (Just e) xs md []                   = Right (e, reverse xs, md)
    go Nothing  _  _  []                   = Left usage
    go _        _  _  ["-I"]               = Left ("-I requires an argument\n" ++ usage)
    go e        xs md ("-I" : f : rest)    = go e (f : xs) md rest
    go e        xs _  ("--dump-anf" : rest) = go e xs ModeDumpAnf rest
    go e        xs _  ("--dump-perceus" : rest) = go e xs ModeDumpPerceus rest
    go e        xs _  ("--dump-multiplicity" : rest) = go e xs ModeDumpMultiplicity rest
    go e        xs _  ("--dump-rc-stats" : rest) = go e xs ModeDumpRcStats rest
    go e        xs _  ("--run" : rest)      = go e xs ModeRun rest
    go Nothing  xs md (a : rest)           = go (Just a) xs md rest
    go (Just _) _  _  (a : _)             =
      Left ("unexpected extra positional: " ++ a ++ "\n" ++ usage)

-- ----------------------------------------------------------------
-- App
-- ----------------------------------------------------------------

runApp :: FilePath -> [FilePath] -> CliMode -> IO ()
runApp entry extras mode = do
  loaded <- loadProgram entry extras
  case loaded of
    Left lerr -> hPutStrLn stderr (prettyLoaderError lerr) >> exitFailure
    Right (entryName, ms) -> case mode of
      ModeDumpAnf -> case Pipeline.elaborateProgram entryName ms of
        Left msg  -> hPutStrLn stderr msg >> exitFailure
        Right cm  -> TIO.putStrLn (prettyModuleTyped cm)
      -- Whole-program elaboration so the dump includes prelude binds (matches
      -- the `perceus golden` harness), then run the Perceus dup/drop pass.
      ModeDumpPerceus -> case Pipeline.elaborateProgramFull entryName ms of
        Left msg  -> hPutStrLn stderr msg >> exitFailure
        Right cm  -> TIO.putStrLn (Perceus.prettyPerceus cm)
      -- Whole-program elaboration: the proof artifact must include handler arms
      -- defined in imported modules (e.g. the prelude `Coro.suspend` arm that
      -- desugars to the genuine `__coro_susp` escape sink), so the dump agrees
      -- with what the one-shot law (`elaborateCheckedFull`) accepts. The trusted
      -- escape-sink identity is resolved by the pipeline.
      ModeDumpMultiplicity -> case Pipeline.elaborateProgramFull entryName ms of
        Left msg -> hPutStrLn stderr msg >> exitFailure
        Right cm -> TIO.putStrLn (prettyMultiplicity onceSinkNames cm)
      -- Whole-program elaboration, then prune to the binds reachable from 'main'
      -- (a semantics-preserving dead-bind elimination: 'elaborateProgramFull'
      -- inlines the whole prelude, but only the reachable first-order corpus
      -- actually runs on the RC store). Then run the Perceus pass and the RC
      -- interpreter, and dump the dynamic-heap accounting. Mirrors the Suite B
      -- golden harness so the CLI output and the golden agree byte-for-byte.
      ModeDumpRcStats -> case Pipeline.elaborateProgramFull entryName ms of
        Left msg  -> hPutStrLn stderr msg >> exitFailure
        Right cm  -> do
          -- Bracket the C heap so a thrown exception between new and free does
          -- not leak it; the free still runs after the run on the normal path.
          rcResult <- Control.Exception.bracket
            Heap.wokHeapNew
            Heap.wokHeapFree
            (\hp -> RCM.runModuleRCWith (CHeap hp) (Perceus.insertRC (pruneToReachable cm)))
          case rcResult of
            Left rerr -> hPutStrLn stderr ("runtime error: " <> show rerr) >> exitFailure
            Right run -> TIO.putStr (RCM.renderRcStats run)
      ModeRun -> case Pipeline.elaborateCheckedFull entryName ms of
        Left msg -> hPutStrLn stderr msg >> exitFailure
        Right cm -> case Interp.runModule cm of
          Left rerr -> hPutStrLn stderr ("runtime error: " <> show rerr) >> exitFailure
          Right v   -> TIO.putStrLn (Interp.renderValue v)
      ModePrintSchemes -> case Pipeline.typecheckProgram entryName ms of
        Left msg -> hPutStrLn stderr msg >> exitFailure
        Right (decls, warnings) -> do
          mapM_ (hPutStrLn stderr . prettyWarning) warnings
          mapM_ printDecl (sortBy (comparing TC.tdName) decls)
  where
    printDecl td =
      TIO.putStrLn (TC.tdName td <> Tx.pack " : " <> TC.prettyScheme (TC.tdScheme td))

-- ----------------------------------------------------------------
-- Pretty-printers
-- ----------------------------------------------------------------

prettyLoaderError :: LoaderError -> String
prettyLoaderError = \case
  LoadFileMissing p ->
    "error: file not found: " <> p
  LoadFileError p msg ->
    "error: cannot read " <> p <> ": " <> msg
  LoadParseError p msg ->
    "parse error in " <> p <> ": " <> msg
  LoadFixityError p errs ->
    "fixity error in " <> p <> ":\n" <> unlines (map (("  " <>) . show) errs)
  LoadReorderError n errs ->
    "reorder error in module " <> Tx.unpack n <> ":\n"
      <> unlines (map (("  " <>) . show) errs)
  LoadCrossModuleFixityConflict op a b ->
    "error: fixity for `" <> Tx.unpack op <> "` declared in both "
      <> Tx.unpack a <> " and " <> Tx.unpack b
  LoadCrossModuleNameConflict name a b ->
    "error: name `" <> Tx.unpack name <> "` exported by both "
      <> Tx.unpack a <> " and " <> Tx.unpack b
  LoadNoModuleHeader p ->
    "error: " <> p
      <> " is missing a `module X.Y` header (must be the first declaration)"
  LoadDuplicateModule n p1 p2 ->
    "error: module " <> Tx.unpack n
      <> " is declared in both " <> p1 <> " and " <> p2
  LoadImportUnknown m target ->
    "error: module " <> Tx.unpack m
      <> " imports unknown module " <> Tx.unpack target
  LoadImportCycle ms ->
    "error: import cycle: " <> intercalate " -> " (map Tx.unpack ms)
  where
    intercalate sep = foldr1 (\x acc -> x <> sep <> acc)

prettyWarning :: TC.Warning -> String
prettyWarning (TC.BodylessBinding name pos) =
  "warning: bodyless binding `" <> Tx.unpack name <> "`" <> showPos pos
    <> "\n  add an equation, or move the declaration into Std.Base if intentional."
prettyWarning (TC.RowShadow pos label outerTy innerTy) =
  "warning: row-shadow" <> showPos pos
    <> ": label `" <> Tx.unpack label <> "` already exists in the row."
    <> "\n  outer type: " <> show outerTy
    <> "\n  inner type (shadowed): " <> show innerTy
    <> "\n  the outer label takes precedence (Leijen scoped-label semantics)."
prettyWarning (TC.NonExhaustiveRecordPattern pos tag) =
  "warning: non-exhaustive patterns" <> showPos pos
    <> "\n  scrutinee of type `" <> Tx.unpack tag <> " + row _` is open (has extensions),"
    <> " but all arms are strict."
    <> "\n  add a `, ..` to one arm to cover the extension case, or use a wildcard arm."
prettyWarning (TC.NonExhaustiveMatch pos name) =
  "warning: non-exhaustive patterns in `" <> Tx.unpack name <> "`" <> showPos pos
    <> "\n  the clause group does not cover all possible inputs."
prettyWarning (TC.RedundantClause pos name idx) =
  "warning: redundant clause #" <> show (idx + 1) <> " in `" <> Tx.unpack name <> "`" <> showPos pos
    <> "\n  this clause can never match (it is shadowed by an earlier clause)."
prettyWarning (TC.ForgottenResume pos eff op) =
  "warning: forgotten resume" <> showPos pos
    <> ": the `" <> Tx.unpack eff <> "." <> Tx.unpack op <> "` arm binds a continuation it never uses."
    <> "\n  the computation will be aborted without resuming the continuation; use `_` to"
    <> "\n  discard intentionally, or reference the continuation to resume."

showPos :: TC.BNFC'Position -> String
showPos (Just (l, c)) = " at line " <> show l <> ", col " <> show c
showPos Nothing       = ""
