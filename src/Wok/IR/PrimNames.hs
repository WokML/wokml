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
    -- * Canonical prelude module names
  , baseModule
  , controlModule
    -- * Array prim names
  , arrayModule
  , arrayNewName
  , arrayFromListName
  , arrayToListName
  , arrayIndexName
  , arrayLengthName
  , arraySetName
  , arrayResizeName
    -- * String prim names
  , stringModule
  , stringLengthName
  , stringIndexName
  , stringByteLengthName
  , stringByteAtName
  , stringAppendName
  , eqStringName
  , stringIndexOfFromRawName
  , stringHashName
  , stringEditDistanceName
  , stringSliceName
  , stringByteSliceName
  , decodeCharAtName
  , charWidthAtName
  , singletonName
    -- * Bytes prim names
  , bytesModule
  , bytesFromListName
  , bytesToListName
  , bytesLengthName
  , bytesIndexName
  , bytesFromBytesName
  , bytesToBytesName
  , eqBytesName
    -- * FFI bytes-in Slice 1: host-blessed deterministic producers
  , ffiDemoCopyName
  , ffiDemoAdoptName
    -- * Borrow prim names (FFI Slice 3 Task 3)
  , borrowModule
  , borrowLengthName
  , borrowByteAtName
  , borrowSliceName
  , borrowMemchrName
  , borrowCopyName
  , borrowDemoName
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
contStoreModule = Tx.pack "Control"

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

-- ---------------------------------------------------------------------------
-- Canonical prelude module names

-- | The defining module of the core/base prelude prims (arithmetic, comparison,
-- @++@, @eqString@, ...).
baseModule :: Text
baseModule = Tx.pack "Base"

-- | The defining module of the control/effect prims (coroutine and
-- stored-continuation sinks). Same string as 'contStoreModule', which keeps the
-- narrower once-sink trust-anchor name for the Multiplicity/Escape recognizers.
controlModule :: Text
controlModule = Tx.pack "Control"

-- ---------------------------------------------------------------------------
-- Array prim names

-- | The defining module of the Array prelude externs.
arrayModule :: Text
arrayModule = Tx.pack "Array"

-- | @new k v@: allocate an array of length k filled with v (Array Slice A).
arrayNewName :: Text
arrayNewName = Tx.pack "new"

-- | @fromList xs@: build an array from a wok list.
arrayFromListName :: Text
arrayFromListName = Tx.pack "fromList"

-- | @toList arr@: convert an array to a wok list.
arrayToListName :: Text
arrayToListName = Tx.pack "toList"

-- | @index arr i@: look up element at index i (bounds-checked).
arrayIndexName :: Text
arrayIndexName = Tx.pack "index"

-- | @length arr@: return the number of elements.
arrayLengthName :: Text
arrayLengthName = Tx.pack "length"

-- | @set arr i v@: copy-on-write slot update.
arraySetName :: Text
arraySetName = Tx.pack "set"

-- | @resize arr m fill@: copy-on-write resize to length m with fill for new slots.
arrayResizeName :: Text
arrayResizeName = Tx.pack "resize"

-- ---------------------------------------------------------------------------
-- String prim names

-- | The defining module of the String prelude externs.
stringModule :: Text
stringModule = Tx.pack "String"

-- | @length s@: codepoint count (O(n), UTF-8 decode).
stringLengthName :: Text
stringLengthName = Tx.pack "length"

-- | @index s i@: the i-th codepoint as a Char (O(n), OOB -> PrimError).
stringIndexName :: Text
stringIndexName = Tx.pack "index"

-- | @byteLength s@: byte count (O(1)).
stringByteLengthName :: Text
stringByteLengthName = Tx.pack "byteLength"

-- | @byteAt s i@: the i-th UTF-8 byte as U64 (O(1), OOB -> PrimError).
stringByteAtName :: Text
stringByteAtName = Tx.pack "byteAt"

-- | @append a b@: concatenate two strings; allocates a new cell.
stringAppendName :: Text
stringAppendName = Tx.pack "append"

-- | @eqString a b@: byte-equality comparison; defining module is 'Base'.
eqStringName :: Text
eqStringName = Tx.pack "eqString"

-- | @indexOfFromRaw hay needle from@: first byte offset of needle in hay at/after
-- @from@, or the maxBound sentinel if absent. (StringZilla find; the search primitive.)
stringIndexOfFromRawName :: Text
stringIndexOfFromRawName = Tx.pack "indexOfFromRaw"

-- | @hash s@: StringZilla sz_hash of the UTF-8 bytes (unseeded, deterministic).
stringHashName :: Text
stringHashName = Tx.pack "hash"

-- | @editDistance a b@: byte-level unit-cost Levenshtein (StringZilla sz_edit_distance).
stringEditDistanceName :: Text
stringEditDistanceName = Tx.pack "editDistance"

-- | @slice s start len@: codepoint window [start, start+len), saturating bounds.
stringSliceName :: Text
stringSliceName = Tx.pack "slice"

-- | @byteSlice s start len@: byte window [start, start+len), saturating bounds;
-- PrimError if a boundary splits a multibyte codepoint.
stringByteSliceName :: Text
stringByteSliceName = Tx.pack "byteSlice"

-- | @decodeCharAt s i@: decode the UTF-8 codepoint starting at byte offset i;
-- returns the Char (byte width is discarded at the prim level).
decodeCharAtName :: Text
decodeCharAtName = Tx.pack "decodeCharAt"

-- | @charWidthAt s i@: UTF-8 byte width of the codepoint starting at byte offset i
-- (1-4); returns U64.
charWidthAtName :: Text
charWidthAtName = Tx.pack "charWidthAt"

-- | @singleton c@: allocate a single-codepoint string from a Char.
singletonName :: Text
singletonName = Tx.pack "singleton"

-- ---------------------------------------------------------------------------
-- Bytes prim names

-- | The defining module of the Bytes prelude externs.
bytesModule :: Text
bytesModule = Tx.pack "Bytes"

-- | @fromList xs@: build a Bytes buffer from a list of U64 byte values.
bytesFromListName :: Text
bytesFromListName = Tx.pack "fromList"

-- | @toList buf@: convert a Bytes buffer to a list of U64 byte values.
bytesToListName :: Text
bytesToListName = Tx.pack "toList"

-- | @length buf@: return the number of bytes.
bytesLengthName :: Text
bytesLengthName = Tx.pack "length"

-- | @index buf i@: look up the byte at index i (bounds-checked).
bytesIndexName :: Text
bytesIndexName = Tx.pack "index"

-- | @fromBytes buf@: validate UTF-8 and return Some String on success.
bytesFromBytesName :: Text
bytesFromBytesName = Tx.pack "fromBytes"

-- | @toBytes s@: convert a String to a raw Bytes buffer (always valid UTF-8).
bytesToBytesName :: Text
bytesToBytesName = Tx.pack "toBytes"

-- | @eqBytes a b@: byte-equality comparison; defining module is 'Base'.
eqBytesName :: Text
eqBytesName = Tx.pack "eqBytes"

-- ---------------------------------------------------------------------------
-- FFI bytes-in Slice 1: host-blessed deterministic producers

-- | @__ffi_demo_copy n@: copy @n@ deterministic bytes (pattern @i mod 256@)
-- into a wok-owned cell (Tier 1, @NBytes@). Transitional fixture; superseded
-- by the real FFI surface (Slice 2).
ffiDemoCopyName :: Text
ffiDemoCopyName = Tx.pack "__ffi_demo_copy"

-- | @__ffi_demo_adopt n@: adopt @n@ deterministic bytes (pattern @i mod 256@)
-- into an @NForeignBytes@ cell (Tier 2, foreign-buffer path). Transitional
-- fixture; superseded by the real FFI surface (Slice 2).
ffiDemoAdoptName :: Text
ffiDemoAdoptName = Tx.pack "__ffi_demo_adopt"

-- ---------------------------------------------------------------------------
-- Borrow prim names (FFI Slice 3 Task 3)

-- | The defining module of the Borrow prelude externs.
borrowModule :: Text
borrowModule = Tx.pack "Borrow"

-- | @length b@: the borrow's byte length, O(1).
borrowLengthName :: Text
borrowLengthName = Tx.pack "length"

-- | @byteAt b i@: the i-th byte as a U64 (0-based, bounds-checked).
borrowByteAtName :: Text
borrowByteAtName = Tx.pack "byteAt"

-- | @slice b i j@: a NEW Borrow over the SAME buffer, offset @i@, length
-- @j - i@ (saturating: out-of-range @i@/@j@ are clamped, a backward range
-- yields an empty slice). A derived, still second-class, borrow.
borrowSliceName :: Text
borrowSliceName = Tx.pack "slice"

-- | @memchr b byte@: scan @b[0 .. length b)@ for the low 8 bits of @byte@;
-- @Some offset@ on the first match, @None@ if absent.
borrowMemchrName :: Text
borrowMemchrName = Tx.pack "memchr"

-- | @copy b@: materialize an OWNED @Bytes@ copy of the borrowed range. The
-- escape hatch -- unlike @Borrow@, the result may escape its scope freely.
borrowCopyName :: Text
borrowCopyName = Tx.pack "copy"

-- | @__borrow_demo n@: a PERMANENT, prelude-only internal test fixture
-- (Task 3) that returns a Borrow over a STATIC, deterministic buffer
-- (pattern @i mod 256@), valid forever -- no free is ever needed. Exercises
-- the read prims independently of any real foreign producer. Task 4 ADDS
-- @Demo.lendBuffer@, the real lend-then-free foreign-module producer,
-- ALONGSIDE this fixture (NOT a replacement) -- mirroring how Slice 2 kept
-- @__ffi_demo_copy@/@__ffi_demo_adopt@ as permanent internal fixtures.
borrowDemoName :: Text
borrowDemoName = Tx.pack "__borrow_demo"
