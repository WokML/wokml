module Main where

import Data.Bifunctor (first)
import qualified Data.List
import qualified Data.Text.IO as TIO
import qualified Data.Text as Tx
import System.Environment (getArgs)
import System.Exit (exitFailure)
import System.IO (hPutStrLn, stderr)
import Wok.Parsing (parse)
import Wok.Reordering (reorderModule, reorderedAst)
import qualified Wok.TypeChecking as TC

main :: IO ()
main = do
  args <- getArgs
  case args of
    [path] -> runApp path
    _      -> do
      hPutStrLn stderr "usage: wok <file.wok>"
      exitFailure

runApp :: FilePath -> IO ()
runApp path = do
  src <- TIO.readFile path
  case pipeline src of
    Left err -> do
      hPutStrLn stderr err
      exitFailure
    Right (_env, decls) -> do
      let sorted = Data.List.sortBy (\a b -> compare (TC.tdName a) (TC.tdName b)) decls
      mapM_ printDecl sorted
  where
    printDecl (TC.TypedDecl n s) =
      TIO.putStrLn (n <> Tx.pack " : " <> TC.prettyScheme s)
    pipeline src = do
      parsed    <- first ("parse: " ++) (parse src)
      reordered <- first (("reorder: " ++) . show) (reorderModule parsed)
      first (("typecheck: " ++) . show) (TC.inferProgram (reorderedAst reordered))
