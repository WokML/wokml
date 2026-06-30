-- | The blessed allow-list of foreign symbols the interpreter trusts.
--
-- Only (lib, symbol) pairs in this table are accepted by the typechecker's
-- honesty check; everything else is a clean 'ForeignSymbolNotBlessed' error.
-- The interpreter and later the codegen backend share this table so the
-- trusted-surface contract is enforced at one site.
module Wok.FFI.Blessed
  ( BlessedSig (..)
  , ReturnDisp (..)
  , blessedTable
  , lookupBlessed
  ) where

import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as Tx

-- | How the callee's return value is handed to the runtime.
data ReturnDisp
  = DispScalar   -- ^ A plain scalar (no heap allocation involved in the return).
  | DispCopy     -- ^ Copy the returned bytes buffer into a new RC cell.
                 -- Reserved for transfer-none buffer returns; no blessed symbol
                 -- uses it yet (no clean deterministic copy-return libc fn).
  | DispAdopt    -- ^ Adopt the returned pointer (free via the module's free clause).
  deriving (Eq, Show)

-- | The statically-known part of a blessed symbol's calling contract.
newtype BlessedSig = BlessedSig { bsReturn :: ReturnDisp }
  deriving (Eq, Show)

-- | The complete allow-list of (lib, symbol) pairs the interpreter accepts.
-- Key: (library-name, C-symbol-name), both as the TEXT the user wrote in the
-- foreign-module declaration (lower-cased library tag + C identifier).
blessedTable :: Map.Map (Text, Text) BlessedSig
blessedTable = Map.fromList
  [ ((Tx.pack "c", Tx.pack "memchr"),  BlessedSig DispScalar)
  , ((Tx.pack "c", Tx.pack "strndup"), BlessedSig DispAdopt)
  ]

-- | Look up a (lib, symbol) pair in the blessed table.
lookupBlessed :: Text -> Text -> Maybe BlessedSig
lookupBlessed lib sym = Map.lookup (lib, sym) blessedTable
