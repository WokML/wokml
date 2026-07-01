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
  | DispBorrow   -- ^ Wrap the returned pointer in an uncounted @0xFFFA@ borrow
                 -- view (FFI Slice 3 Task 4). Transfer-none: the host keeps
                 -- ownership; wok never frees it. Unlike 'DispAdopt'/'DispCopy',
                 -- this disposition is carried by the member's declared return
                 -- TYPE (@Borrow@) rather than the @owned@ keyword -- a member
                 -- blessed 'DispBorrow' must declare its return type as @Borrow@
                 -- (checked in 'Wok.TypeChecking.Infer.processForeignDecls').
  deriving (Eq, Show)

-- | The statically-known part of a blessed symbol's calling contract.
newtype BlessedSig = BlessedSig { bsReturn :: ReturnDisp }
  deriving (Eq, Show)

-- | The complete allow-list of (lib, symbol) pairs the interpreter accepts.
-- Key: (library-name, C-symbol-name), both as the TEXT the user wrote in the
-- foreign-module declaration (lower-cased library tag + C identifier).
--
-- @("wok", "lendBuffer")@ is NOT a real C library symbol: it is the FFI
-- Slice 3 Task 4 deterministic borrow producer, a host function the wok
-- runtime itself provides (not @dlopen@'d, not linked against any real
-- library) so the borrow tier has a blessed, deterministic, non-libc source
-- to lend from. The @"wok"@ library tag deliberately does not claim to be
-- @"c"@, so a reader of a @foreign module@ header can tell at a glance that
-- @lendBuffer@ is a wok-internal fixture, not a real libc call.
blessedTable :: Map.Map (Text, Text) BlessedSig
blessedTable = Map.fromList
  [ ((Tx.pack "c", Tx.pack "memchr"),  BlessedSig DispScalar)
  , ((Tx.pack "c", Tx.pack "strndup"), BlessedSig DispAdopt)
  , ((Tx.pack "wok", Tx.pack "lendBuffer"), BlessedSig DispBorrow)
  ]

-- | Look up a (lib, symbol) pair in the blessed table.
lookupBlessed :: Text -> Text -> Maybe BlessedSig
lookupBlessed lib sym = Map.lookup (lib, sym) blessedTable
