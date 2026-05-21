module Main where

import qualified Data.Text.IO as TIO
import qualified GeneratedParser.Wok.Print as Pr
import Wok.Parsing (parse)

import System.Environment (getArgs)
import System.Exit (exitFailure)

main :: IO ()
main = do
  args <- getArgs
  case args of
    [path] -> do
      src <- TIO.readFile path
      case parse src of
        Right ast -> do
          putStrLn "-- AST --"
          putStrLn (Pr.printTree ast)
        Left err -> do
          putStrLn ("Parse error: " ++ err)
          exitFailure
    _ -> do
      putStrLn "usage: wok <file.wok>"
      exitFailure
