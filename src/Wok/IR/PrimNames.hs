-- | The single source of truth for the names of the compiler-placed RC and M3
-- intrinsic prims. These names are SPELLED in two roles that must stay in sync:
--
--   * the IR recognizers ('Wok.IR.Escape', 'Wok.IR.Perceus',
--     'Wok.IR.Reachable') identify a compiler-internal call from these names: the
--     @__rc_dup@/@__rc_drop@ insertions by name HINT (Perceus-synthesized), the
--     @__cont_store@/@__cont_take@/@__cont_cell_new@ moves by QUALIFIED
--     @(module, name)@ extern identity on the 'APrim' head, and
--   * the interpreter prim tables ('Wok.Interp.RC.Prim',
--     'Wok.Interp.Prim') key their entries on them.
--
-- Re-spelling each literal independently in those places meant a rename could
-- desync silently (the recognizer would stop matching while the prim table still
-- registered the old name, or vice versa). Centralizing them here makes a rename
-- a single edit and a compile error at every stale call site.
--
-- NOTE on the recognition convention. TWO categories live here:
--
--   * @__rc_dup@/@__rc_drop@ are matched by HINT TEXT --- the established
--     convention for compiler-SYNTHESIZED intrinsics, since the Perceus pass is
--     the only producer of these calls in the IR these passes see (no user
--     binding can forge them).
--   * the prelude continuation @extern@s (@__coro_susp@, @__cont_store@,
--     @__cont_take@, @__cont_cell_new@) are matched by QUALIFIED @(module, name)@
--     extern IDENTITY, because a user binding hinted the same is surface-plausible.
--     The elaborator routes those externs to an 'Wok.IR.Anf.APrim' carrying the
--     @(module, name)@ key, so the recognizers match the 'APrim' head (the
--     once-shot trust set 'onceSinkNames' covers @__coro_susp@/@__cont_store@; the
--     cell move/take recognizers carry their own keys); a hinted user binding
--     resolves to an 'AVar' and is never matched.
module Wok.IR.PrimNames
  ( -- * RC intrinsics (Perceus-inserted)
    rcDupName
  , rcDropName
  , rcDropReuseName
    -- * M3 stored-continuation cell prims
  , contCellNewName
  , contStoreName
  , contTakeName
    -- * Trusted once-sink prelude externs
  , contStoreModule
  , coroSuspName
  , onceSinkNames
    -- * Qualified @(module, name)@ identity keys
  , contCellNewKey
  , contStoreKey
  , contTakeKey
  , coroSuspKey
  ) where

import Data.Set (Set)
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as Tx

-- | @__rc_dup x@: incref @x@'s handle (no-op on a literal), returns @x@.
rcDupName :: Text
rcDupName = Tx.pack "__rc_dup"

-- | @__rc_drop x@: decref @x@'s handle (freeing at zero), returns @()@.
rcDropName :: Text
rcDropName = Tx.pack "__rc_drop"

-- | @__rc_drop_reuse x@: the FBIP @drop_reuse@ intrinsic. Like @__rc_drop@ it
-- decrefs @x@'s handle, but when the decrement hits zero (the cell is unique) it
-- RETAINS the freed shell and returns it as an affine reuse token
-- ('Wok.Interp.RC.Value.RVReuse') instead of unit; a shared or uncounted handle
-- yields a NULL token. Synthesized ONLY by the FBIP reuse-pairing post-pass and,
-- like @__rc_dup@/@__rc_drop@, recognized by HINT TEXT (no user binding can forge
-- it); its sole consumer is an 'Wok.IR.Anf.RReuseCon' on the same straight-line
-- path. See spec 2026-06-23-fbip-reuse-design §5.2.
rcDropReuseName :: Text
rcDropReuseName = Tx.pack "__rc_drop_reuse"

-- | @__cont_cell_new ()@: allocate a fresh EMPTY continuation cell (M3 §4.1).
contCellNewName :: Text
contCellNewName = Tx.pack "__cont_cell_new"

-- | @__cont_store cell k@: MOVE the continuation @k@ into @cell@ (M3 §4.1).
contStoreName :: Text
contStoreName = Tx.pack "__cont_store"

-- | @__cont_take cell@: MOVE the continuation OUT of @cell@ (M3 §4.1).
contTakeName :: Text
contTakeName = Tx.pack "__cont_take"

-- | The defining module of the genuine prelude continuation-sink @extern@s.
contStoreModule :: Text
contStoreModule = Tx.pack "Std.Control"

-- | @__coro_susp x k@: the coroutine escape sink (@start@ desugars to it). A
-- genuine once-sink: it resumes its continuation argument at most once.
coroSuspName :: Text
coroSuspName = Tx.pack "__coro_susp"

-- | The trusted once-sink prelude @extern@s, by qualified @(module, name)@
-- identity. An op-arm handing its @resume@ DIRECTLY to one of these is certified
-- one-shot. This single set drives BOTH the Multiplicity once-shot trust
-- ('Wok.IR.Multiplicity') and the Escape/Reachable @__cont_store@ move-in
-- recognizer ('Wok.IR.Escape.contStoreCell'). Because an 'APrim' carries the
-- qualified identity and is emitted ONLY for a genuine prelude @extern@, a user
-- binding hinted the same name resolves to an 'AVar' and is never matched here.
onceSinkNames :: Set (Text, Text)
onceSinkNames = Set.fromList [coroSuspKey, contStoreKey]

-- | Qualified @(module, name)@ identity key for @__cont_cell_new@.
contCellNewKey :: (Text, Text)
contCellNewKey = (contStoreModule, contCellNewName)

-- | Qualified @(module, name)@ identity key for @__cont_store@.
contStoreKey :: (Text, Text)
contStoreKey = (contStoreModule, contStoreName)

-- | Qualified @(module, name)@ identity key for @__cont_take@.
contTakeKey :: (Text, Text)
contTakeKey = (contStoreModule, contTakeName)

-- | Qualified @(module, name)@ identity key for @__coro_susp@.
coroSuspKey :: (Text, Text)
coroSuspKey = (contStoreModule, coroSuspName)
