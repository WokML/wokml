-- | The Base Prelude source, loaded at runtime.
--
-- The text of prelude/Base.wok is shipped as a cabal data-file and
-- read from disk at runtime via Paths_wok.getDataFileName. The compiler's
-- loader unconditionally inserts a LoadedModule keyed "Base" into the
-- module map before processing any user files, using this Text as the
-- module's source. The .wok file remains the single editable source of
-- truth; no rebuild is required to pick up content changes once installed
-- (cabal locates the file via the package's data directory).
module Wok.Prelude
  ( preludeName
  , preludeSource
  , controlName
  , controlSource
  , arrayName
  , arraySource
  , stringName
  , stringSource
  , bytesName
  , bytesSource
  , borrowName
  , borrowSource
  ) where

import Data.Text (Text)
import qualified Data.Text as Tx
import qualified Data.Text.IO as TIO
import qualified Paths_wok

preludeName :: Text
preludeName = Tx.pack "Base"

-- | Read the Base prelude source from the installed data-files location.
-- The lookup is performed by cabal-generated Paths_wok.getDataFileName, which
-- consults Cabal's package data directory at runtime.
preludeSource :: IO Text
preludeSource = do
  path <- Paths_wok.getDataFileName "prelude/Base.wok"
  TIO.readFile path

controlName :: Text
controlName = Tx.pack "Control"

-- | Read the Control embedded prelude source from the installed
-- data-files location. Like Base, the .wok file is the editable source
-- of truth and is located at runtime via Paths_wok.getDataFileName.
controlSource :: IO Text
controlSource = do
  path <- Paths_wok.getDataFileName "prelude/Control.wok"
  TIO.readFile path

arrayName :: Text
arrayName = Tx.pack "Array"

-- | Read the Array embedded prelude source from the installed
-- data-files location. Like Base and Control, the .wok file is the
-- editable source of truth and is located at runtime via
-- Paths_wok.getDataFileName.
arraySource :: IO Text
arraySource = do
  path <- Paths_wok.getDataFileName "prelude/Array.wok"
  TIO.readFile path

stringName :: Text
stringName = Tx.pack "String"

-- | Read the String embedded prelude source from the installed
-- data-files location. Like Base and Array, the .wok file is the
-- editable source of truth and is located at runtime via
-- Paths_wok.getDataFileName.
stringSource :: IO Text
stringSource = do
  path <- Paths_wok.getDataFileName "prelude/String.wok"
  TIO.readFile path

bytesName :: Text
bytesName = Tx.pack "Bytes"

-- | Read the Bytes embedded prelude source from the installed
-- data-files location. Like String, the .wok file is the editable
-- source of truth and is located at runtime via Paths_wok.getDataFileName.
bytesSource :: IO Text
bytesSource = do
  path <- Paths_wok.getDataFileName "prelude/Bytes.wok"
  TIO.readFile path

borrowName :: Text
borrowName = Tx.pack "Borrow"

-- | Read the Borrow embedded prelude source from the installed
-- data-files location. Like Bytes, the .wok file is the editable
-- source of truth and is located at runtime via Paths_wok.getDataFileName.
borrowSource :: IO Text
borrowSource = do
  path <- Paths_wok.getDataFileName "prelude/Borrow.wok"
  TIO.readFile path
