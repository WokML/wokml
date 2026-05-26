{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

module Main where

import Data.List (sortBy)
import Data.Ord (comparing)
import qualified Data.Text as Tx
import qualified Data.Text.IO as TIO
import System.Environment (getArgs)
import System.Exit (exitFailure)
import System.IO (hPutStrLn, stderr)

import Wok.Loader (LoaderError (..), loadProgram)
import qualified Wok.Pipeline as Pipeline
import qualified Wok.TypeChecking as TC

-- ----------------------------------------------------------------
-- CLI parsing
-- ----------------------------------------------------------------

usage :: String
usage = "usage: wok <entry.wok> [-I <file.wok>]..."

main :: IO ()
main = do
  args <- getArgs
  case parseCli args of
    Left msg          -> hPutStrLn stderr msg >> exitFailure
    Right (e, extras) -> runApp e extras

parseCli :: [String] -> Either String (FilePath, [FilePath])
parseCli = go Nothing []
  where
    go (Just e) xs []                = Right (e, reverse xs)
    go Nothing  _  []                = Left usage
    go _        _  ["-I"]            = Left ("-I requires an argument\n" ++ usage)
    go e        xs ("-I" : f : rest) = go e (f : xs) rest
    go Nothing  xs (a : rest)        = go (Just a) xs rest
    go (Just _) _  (a : _)           =
      Left ("unexpected extra positional: " ++ a ++ "\n" ++ usage)

-- ----------------------------------------------------------------
-- App
-- ----------------------------------------------------------------

runApp :: FilePath -> [FilePath] -> IO ()
runApp entry extras = do
  loaded <- loadProgram entry extras
  case loaded of
    Left lerr -> hPutStrLn stderr (prettyLoaderError lerr) >> exitFailure
    Right (entryName, ms) -> case Pipeline.typecheckProgram entryName ms of
      Left msg -> hPutStrLn stderr msg >> exitFailure
      Right (decls, warnings) -> do
        mapM_ (hPutStrLn stderr . prettyWarning) warnings
        mapM_ printDecl (sortBy (comparing TC.tdName) decls)
  where
    printDecl (TC.TypedDecl n s) =
      TIO.putStrLn (n <> Tx.pack " : " <> TC.prettyScheme s)

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
  where
    showPos (Just (l, c)) = " at line " <> show l <> ", col " <> show c
    showPos Nothing       = ""
