-- | The blessed allow-list of foreign symbols the interpreter trusts.
--
-- Only (lib, symbol) pairs in this table are accepted by the typechecker's
-- honesty check; everything else is a clean 'ForeignSymbolNotBlessed' error.
-- The interpreter and later the codegen backend share this table so the
-- trusted-surface contract is enforced at one site.
module Wok.FFI.Blessed
  ( BlessedSig (..)
  , ReturnDisp (..)
  , ArgTransfer (..)
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

-- | How an ARGUMENT's ownership is handed from wok to the callee.
data ArgTransfer
  = TransferNone  -- ^ The callee does not take ownership; wok keeps the value.
  | MoveOut       -- ^ Transfer-full: the callee takes ownership of the argument
                  -- (FFI Slice 4). Carried by the surface @owned@ modifier on
                  -- a parameter type (e.g. @owned Bytes@); wok must not touch
                  -- the value again after the call.
  deriving (Eq, Show)

-- | The statically-known part of a blessed symbol's calling contract.
data BlessedSig = BlessedSig
  { bsReturn      :: ReturnDisp
  , bsArgTransfer :: [ArgTransfer]
    -- ^ One entry per parameter, in declaration order. Threaded onto
    -- 'Wok.IR.Anf.RForeignCall' (FFI Slice 4 Task 1) for the CODEGEN backend to
    -- dispatch on at each argument. The REFERENCE INTERPRETER does NOT consult
    -- this field at runtime: its router dispatches move-vs-copy per blessed
    -- (lib, sym) pair (see 'Wok.Interp.RC.Machine's @symConsume@ arm), not by
    -- reading the tag. Generalizing the interpreter's router to read this list
    -- would be premature for the single 'MoveOut' symbol it currently serves.
  }
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
-- @("wok", "consume")@ is likewise a wok-internal fixture (not a real C
-- library symbol): the FFI Slice 4 deterministic transfer-full sink, the
-- dual of @lendBuffer@'s borrow-in tier -- a host function the wok runtime
-- accepts an owned @Bytes@ argument through, so the owned-INTO-C tier has a
-- blessed, deterministic sink to move into.
blessedTable :: Map.Map (Text, Text) BlessedSig
blessedTable = Map.fromList
  [ ((Tx.pack "c", Tx.pack "memchr"),  BlessedSig DispScalar [])
  , ((Tx.pack "c", Tx.pack "strndup"), BlessedSig DispAdopt [])
  , ((Tx.pack "wok", Tx.pack "lendBuffer"), BlessedSig DispBorrow [])
  , ((Tx.pack "wok", Tx.pack "consume"), BlessedSig DispScalar [MoveOut])
  ]

-- | Look up a (lib, symbol) pair in the blessed table.
lookupBlessed :: Text -> Text -> Maybe BlessedSig
lookupBlessed lib sym = Map.lookup (lib, sym) blessedTable
