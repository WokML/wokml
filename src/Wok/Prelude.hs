-- | The Std.Base Prelude source, loaded at runtime.
--
-- The text of prelude/Std/Base.wok is shipped as a cabal data-file and
-- read from disk at runtime via Paths_wok.getDataFileName. The compiler's
-- loader unconditionally inserts a LoadedModule keyed "Std.Base" into the
-- module map before processing any user files, using this Text as the
-- module's source. The .wok file remains the single editable source of
-- truth; no rebuild is required to pick up content changes once installed
-- (cabal locates the file via the package's data directory).
module Wok.Prelude
  ( preludeName
  , preludeSource
  , stdControlName
  , stdControlSource
  , stdArrayName
  , stdArraySource
  , stdStringName
  , stdStringSource
  , stdBytesName
  , stdBytesSource
  , stdBorrowName
  , stdBorrowSource
  ) where

import Data.Text (Text)
import qualified Data.Text as Tx
import qualified Data.Text.IO as TIO
import qualified Paths_wok

preludeName :: Text
preludeName = Tx.pack "Std.Base"

-- | Read the Std.Base prelude source from the installed data-files location.
-- The lookup is performed by cabal-generated Paths_wok.getDataFileName, which
-- consults Cabal's package data directory at runtime.
preludeSource :: IO Text
preludeSource = do
  path <- Paths_wok.getDataFileName "prelude/Std/Base.wok"
  TIO.readFile path

stdControlName :: Text
stdControlName = Tx.pack "Std.Control"

-- | Read the Std.Control embedded prelude source from the installed
-- data-files location. Like Std.Base, the .wok file is the editable source
-- of truth and is located at runtime via Paths_wok.getDataFileName.
stdControlSource :: IO Text
stdControlSource = do
  path <- Paths_wok.getDataFileName "prelude/Std/Control.wok"
  TIO.readFile path

stdArrayName :: Text
stdArrayName = Tx.pack "Std.Array"

-- | Read the Std.Array embedded prelude source from the installed
-- data-files location. Like Std.Base and Std.Control, the .wok file is the
-- editable source of truth and is located at runtime via
-- Paths_wok.getDataFileName.
stdArraySource :: IO Text
stdArraySource = do
  path <- Paths_wok.getDataFileName "prelude/Std/Array.wok"
  TIO.readFile path

stdStringName :: Text
stdStringName = Tx.pack "Std.String"

-- | Read the Std.String embedded prelude source from the installed
-- data-files location. Like Std.Base and Std.Array, the .wok file is the
-- editable source of truth and is located at runtime via
-- Paths_wok.getDataFileName.
stdStringSource :: IO Text
stdStringSource = do
  path <- Paths_wok.getDataFileName "prelude/Std/String.wok"
  TIO.readFile path

stdBytesName :: Text
stdBytesName = Tx.pack "Std.Bytes"

-- | Read the Std.Bytes embedded prelude source from the installed
-- data-files location. Like Std.String, the .wok file is the editable
-- source of truth and is located at runtime via Paths_wok.getDataFileName.
stdBytesSource :: IO Text
stdBytesSource = do
  path <- Paths_wok.getDataFileName "prelude/Std/Bytes.wok"
  TIO.readFile path

stdBorrowName :: Text
stdBorrowName = Tx.pack "Std.Borrow"

-- | Read the Std.Borrow embedded prelude source from the installed
-- data-files location. Like Std.Bytes, the .wok file is the editable
-- source of truth and is located at runtime via Paths_wok.getDataFileName.
stdBorrowSource :: IO Text
stdBorrowSource = do
  path <- Paths_wok.getDataFileName "prelude/Std/Borrow.wok"
  TIO.readFile path
