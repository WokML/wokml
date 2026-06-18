-- | The single source of truth for the names of the compiler-placed RC and M3
-- intrinsic prims. These names are SPELLED in two roles that must stay in sync:
--
--   * the IR recognizers ('Wok.IR.Escape', 'Wok.IR.Perceus',
--     'Wok.IR.Reachable') match a call head's name HINT against them to identify
--     a compiler-internal call (a @__rc_dup@/@__rc_drop@ insertion, a
--     @__cont_store@/@__cont_take@/@__cont_cell_new@ move), and
--   * the interpreter prim tables ('Wok.Interp.RC.Prim',
--     'Wok.Interp.Prim') key their entries on them.
--
-- Re-spelling each literal independently in those places meant a rename could
-- desync silently (the recognizer would stop matching while the prim table still
-- registered the old name, or vice versa). Centralizing them here makes a rename
-- a single edit and a compile error at every stale call site.
--
-- NOTE on the recognition convention: these are matched by HINT TEXT (the
-- established convention for compiler-placed intrinsics, since the elaborator/
-- Perceus pass is the only producer of these calls in the IR these passes see).
-- The genuine prelude once-sink @extern@s (e.g. @__coro_susp@) are resolved by
-- @(module, name)@ extern IDENTITY instead (see 'Wok.Pipeline.onceSinkKeys') and
-- are deliberately NOT centralized here --- identity resolution does not key on
-- the bare hint, so it cannot desync with these recognizers.
module Wok.IR.PrimNames
  ( -- * RC intrinsics (Perceus-inserted)
    rcDupName
  , rcDropName
    -- * M3 stored-continuation cell prims
  , contCellNewName
  , contStoreName
  , contTakeName
  ) where

import Data.Text (Text)
import qualified Data.Text as Tx

-- | @__rc_dup x@: incref @x@'s handle (no-op on a literal), returns @x@.
rcDupName :: Text
rcDupName = Tx.pack "__rc_dup"

-- | @__rc_drop x@: decref @x@'s handle (freeing at zero), returns @()@.
rcDropName :: Text
rcDropName = Tx.pack "__rc_drop"

-- | @__cont_cell_new ()@: allocate a fresh EMPTY continuation cell (M3 §4.1).
contCellNewName :: Text
contCellNewName = Tx.pack "__cont_cell_new"

-- | @__cont_store cell k@: MOVE the continuation @k@ into @cell@ (M3 §4.1).
contStoreName :: Text
contStoreName = Tx.pack "__cont_store"

-- | @__cont_take cell@: MOVE the continuation OUT of @cell@ (M3 §4.1).
contTakeName :: Text
contTakeName = Tx.pack "__cont_take"
