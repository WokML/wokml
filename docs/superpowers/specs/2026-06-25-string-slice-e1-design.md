# String Slice E1: Simple String (flat UTF-8 bytes) — Design Spec

**Date:** 2026-06-25
**Status:** Approved for planning (brainstorm converged; alignment review passed — 10/10 code refs real, 12/12 decisions present)
**Predecessors:** Array Slice B (`docs/.../array-slice-b`, the C-cell framework this reuses), Region Slice R1 (`2026-06-25-region-slice-r1-design.md`, the escape/region machinery String now participates in)
**Companion (closed):** `docs/string-architecture.html`

---

## 1. Goal & scope

Build wok's real `String` type: a flat UTF-8 byte buffer living on a dedicated C cell, with a small first-order operation surface and the differential oracle that proves the two interpreter backends agree bit-for-bit.

**In scope (E1):** the `WokString` C cell, the abstract-heap mirror node, the FFI bindings, six operations (`length`, `index`, `byteLength`, `byteAt`, `append`, and `Eq String`), string-literal allocation, value rendering, and the oracle + property tests.

**Out of scope (named so the boundary is explicit):**
- **E2 — StringZilla**: vendor the Apache-2.0 header; add SIMD byte-range ops (`find`/`indexOf`, `contains`, `count`, `hash`, `editDistance`); add the list bridge `chars`/`fromChars` and the non-allocating `foldChars` (needs prim-calls-closure machinery). StringZilla does runtime SIMD hardware dispatch (one build holds SWAR/AVX2/AVX-512/NEON/SVE kernels, picks the best via CPUID at load); results are invariant across kernels, so the oracle stays hardware-independent. Hash-determinism-across-backends is an E2 verify item. (`append` stays a plain alloc+copy even in E2 — `sz_copy`, StringZilla's SIMD `memcpy`, is the only place it could touch concat, and it is deliberately not used: copy is bandwidth-bound and StringZilla's value is search/hash/edit-distance.)
- **E3 — small-string optimization**: inline short strings (needs its own wider `Addr` variant; the existing `Inline Word32` at `Value.hs:152` is only 4 bytes, too small to reuse).
- **E4 — views + heavy Unicode**: zero-copy substrings (share the buffer; ties to the region/borrow work) and table-driven ops (case-fold, normalize, graphemes).

---

## 2. Background — where `String` is today

`String` is a placeholder, not a real value:
- The type-checker tycon `TcString` exists (`src/Wok/TypeChecking/Types.hs:48`) and `String` is registered in Builtins (`src/Wok/TypeChecking/Builtins.hs:34`, `TyConInfo KStar 0 [] False []`).
- The IR literal `LStr Text` (`src/Wok/IR/Anf.hs:43`, `data Lit = LInt Integer | LStr Text | LChar Char | LUnit`). A string literal elaborates to `RAtom (ALit (LStr s))`.
- At runtime in the RC interpreter it is `RVLit (LStr Text)` — an **inline Haskell `Text`**, not a heap cell, not C-encodable. `isBoxedType (CTCon TcString []) = False` (`src/Wok/IR/Escape.hs:123`); `slotClassOf (CTCon TcString []) = NonEncodable` (`src/Wok/IR/ReusePairing.hs:92`). There is no `Std.String` module. Strings are only ever produced as literals and rendered for debug output (`renderLit (LStr str)`, `Value.hs:2348`).

E1 replaces the placeholder with a real cell. Because strings are barely used in existing programs (literals + rendering only), the migration surface is small but must be enumerated (§6).

---

## 3. Decisions (converged in brainstorm 2026-06-25)

1. **Byte-first storage.** A dedicated flat UTF-8 byte buffer (1-byte stride, opaque body, no slot encoding, **no RC cascade** — bytes hold no pointers).
2. **Reuse the Array Slice B framework, do not reuse `Array`.** `WokString` is a *new* C cell that reuses the allocator / byte-size-class / 8-byte RC prefix / FFI binding pattern / `PrimNames` + prelude module template. It is **not** `Array Char` and **not** a `WokArray` (own tag, no `elemkind`/`scan`, byte body not word slots).
3. **Unicode-first operations at the codepoint level.** A "character" = a Unicode scalar = wok's existing `Char` (the Rust/Go model, **not** grapheme clusters). No Unicode tables in E1 (UTF-8↔codepoint is pure bit-shifting; tables for case/normalize/grapheme are E4).
4. **Byte-native escape hatch via differently-named functions.** Qualified imports are a deferred slice (`[[qualified-imports-deferred]]`), so everything lives in one `Std.String` module and naming carries the view distinction (`length`/`index` = codepoints; `byteLength`/`byteAt` = bytes).
5. **`String` = valid UTF-8 only.** Enforced by choosing `Data.Text.Text` as the reference model (Text cannot hold invalid Unicode). An arbitrary byte bag would be a separate `Bytes`/flat-`Array U8` type (Slice-D territory), not this.
6. **`append`, not `(++)`, for concat.** `(++) : [a] -> [a] -> [a]` is a monomorphic list extern (`Std.Base:27`); wok has no `Append`/`Semigroup` class, no type-directed resolution, and no cross-module instances, so overloading `(++)` is its own future slice. E1 uses `append : String -> String -> String`.
7. **Lean A — first-order E1.** No bulk codepoint iteration in E1 (only random `index`/`length`). `chars`/`fromChars` + the non-allocating `foldChars` land in E2.
8. **Differential oracle over the two RC backends** (output + allocs/frees/peak/peak_bytes), with the reference interpreter using `Text` for semantics.

---

## 4. Architecture

### 4.1 Two interpreters and the oracle (no change to the existing topology)

- **Reference interpreter** (`Wok.Interp.Prim`, `Wok.Interp.Value`): no RC store; values are `VLit`/`VCon`. **String stays `VLit (LStr Text)`** here — this is where the `Text` reference semantics live (`length` = `Text.length`, `index` = codepoint index, byte ops via `Data.Text.Encoding.encodeUtf8`). No change to the String representation in this backend.
- **RC interpreter** (`Wok.Interp.RC.*`): has the RC store with two heap backends — **AbstractHeap** (IntMap mirror) and **CHeap** (real C runtime). String becomes a new heap node `NString` (§4.3) routed to a real `WokString` cell on CHeap and to an IntMap entry (with mirrored byte accounting) on AbstractHeap.
- **Oracle:** the existing differential harness compares the two RC backends for output + allocs/frees/peak/peak_bytes parity, and compares output against the reference interpreter. String reuses it unchanged (the harness is representation-agnostic; it only needs `NString` to render identically — §6).

### 4.2 The `WokString` C cell (`runtime/wok_rc.{h,c}`)

Mirrors the `WokArray` cell (`wok_rc.h:73-93`) but with a **byte body**:

```
Layout (8-aligned):
  offset  0  uint32 rc        \
  offset  4  uint16 tag        |  8-byte WokObj-compatible prefix (wok_dup/wok_dec/wok_tag/wok_rc
  offset  6  uint8  reserved   |  read offsets 0-7 unchanged); tag == WOK_STRING_TAG marks a string.
  offset  7  uint8  scan       /  reserved=0 (no elemkind needed); scan=0 (strings never cascade).
  offset  8  uint64 byte_len   <- runtime BYTE count (not codepoints, not words)
  offset 16  uint8  bytes[byte_len]   <- packed UTF-8, 1-byte stride, opaque
Cell byte size = 16 + 8*ceil(byte_len/8)  (the body rounds UP to an 8-byte granule so the next
bumped cell stays 8-aligned). cur_bytes / peak_bytes charge this ROUNDED size on BOTH backends,
exactly as the array charges its (already-8-aligned) 16 + 8*len.
Size class = (cell_bytes / 8) - 1 = 1 + ceil(byte_len/8)  (shares the free-list with an NCon of
that arity / a WokArray of that len -- identical byte size, shape-agnostic recycling).
class < WOK_NUM_CLASSES (64) -> arena free-list; else -> malloc.

#define WOK_STRING_TAG 0xFFFEu   /* a SECOND reserved tag beside WOK_ARRAY_TAG 0xFFFF */
```

`internTag` must never return `0xFFFE` or `0xFFFF` (reserve both). C API:

```c
WokObj*  wok_string_alloc(WokHeap* h, uint64_t byte_len);  /* rc=1, tag=WOK_STRING_TAG, body undef */
WOK_PURE uint64_t  wok_string_len(const WokObj* p);         /* byte_len */
         uint8_t*  wok_string_data(WokObj* p);              /* pointer to body: bulk fill + FFI (E2 StringZilla) */
WOK_PURE uint64_t  wok_string_byte_get(const WokObj* p, uint64_t i);  /* one byte, zero-extended */
```

`wok_string_alloc` charges `cur_bytes`/`peak_bytes += 16 + 8*ceil(byte_len/8)` (the rounded cell size, exactly as `wok_array_alloc` charges its 8-aligned `16 + 8*len`). `wok_dup`/`wok_dec`/`wok_free`/`wok_rc` work unchanged (shared prefix). `wok_string_data` is the bulk channel: Haskell `memcpy`s the literal/result bytes in once, and E2 hands the same pointer to StringZilla.

### 4.3 The abstract node `NString` (`src/Wok/Interp/RC/Value.hs`)

```haskell
NString ByteString          -- alongside NArray (Value.hs:633); strict UTF-8 bytes
```

- `nodeCEligible (NString _) = False` — like `NArray`, it has its **own dedicated alloc path**, not the generic `NCon` slot encoding.
- `wouldBeCBytes (NString bs) = 16 + 8 * ((BS.length bs + 7) ediv 8)` (where `ediv` is integer division — i.e. `16 + roundUp8 (BS.length bs)`) — the **rounded** cell size, mirroring the C `wok_string_alloc` charge so AbstractHeap and CHeap agree on `peak_bytes` (the array's `16 + 8*length vs` needs no rounding only because its body is already word-aligned).
- `alloc (NString bs)`: CHeap routes to a new `allocNString` (calls `wok_string_alloc` then `memcpy`s `bs` into `wok_string_data`); AbstractHeap uses `allocPure` (IntMap), mirroring the `alloc (NArray vs)` two-path dispatch at `Value.hs:1397`.
- **Drop cascade is empty.** Bytes are opaque (no child refs), so `dropAddr` on an `NString` just frees the cell at rc 0 — strictly simpler than `NArray`, which releases element refs.
- Rendering: a matching `NString` case in the RC renderer and a `VLit (LStr ...)` path in the reference renderer must produce **byte-identical** output (the oracle depends on it when `main` returns a string).

### 4.4 FFI bindings (`src/Wok/Interp/RC/Heap.hs`)

Mirror the `wokArray*` block (`Heap.hs:38-42`):

```haskell
foreign import ccall unsafe "wok_string_alloc"     wokStringAlloc   :: Ptr WokHeap -> Word64 -> IO (Ptr WokObj)
foreign import ccall unsafe "wok_string_len"        wokStringLen     :: Ptr WokObj -> IO Word64
foreign import ccall unsafe "wok_string_data"       wokStringData    :: Ptr WokObj -> IO (Ptr Word8)
foreign import ccall unsafe "wok_string_byte_get"   wokStringByteGet :: Ptr WokObj -> Word64 -> IO Word64
```

---

## 5. The E1 surface

### 5.1 Prelude (`prelude/Std/String.wok`, new)

```
module Std.String
import Std.Base

extern length     : String -> U64          -- codepoint count   (O(n), cacheable later)
extern index      : String -> U64 -> Char  -- Nth codepoint     (O(n))
extern byteLength : String -> U64          -- byte count        (O(1))
extern byteAt     : String -> U64 -> U64   -- Nth byte (U64-valued; wok has no U8)  (O(1))
extern append     : String -> String -> String   -- concat
```

### 5.2 `Eq String` (in `Std.Base`, to dodge the no-cross-module-instances limit)

```
-- in prelude/Std/Base.wok, beside the other Eq instances:
extern eqString : String -> String -> Bool
instance Eq String where
  (==) = eqString
```

(`String`/`Char` are builtin tycons, so `Std.Base` can name them. The instance must co-locate with the `Eq` class — `[[typed-core-next-eq-dictionaries]]` has no cross-module instances yet.)

### 5.3 Semantics & RC accounting (per prim; both backends)

Each prim is implemented twice: reference (`Wok.Interp.Prim`, over `VLit (LStr Text)`) and RC (`Wok.Interp.RC.Prim`, over `NString` / the C cell). The args-consuming convention follows the Array prims (`RC/Prim.hs:471-590`).

| prim | reference (Text) | RC backend | alloc |
|------|------------------|-----------|-------|
| `length` | `Text.length` (codepoints) | decode cell bytes → codepoint count; drop input | 0 |
| `index s i` | i-th codepoint (`Text.index`); OOB → `PrimError` | decode bytes, bounds-check, return `Char`; drop input | 0 |
| `byteLength` | `BS.length (encodeUtf8 t)` | `wok_string_len` / `BS.length`; drop input | 0 |
| `byteAt s i` | i-th UTF-8 byte; OOB → `PrimError` | `wok_string_byte_get`; bounds-check; drop input | 0 |
| `append a b` | `Text.append` | alloc new cell of `len a + len b`, `memcpy` both bodies; drop both inputs | +1 |
| `eqString a b` | `t1 == t2` | compare `byte_len` then bytes; drop both inputs | 0 |

Notes:
- `length`/`index` decode UTF-8 → codepoints with no Unicode tables (pure bit-shifting). For valid UTF-8 (the invariant), codepoint equality = byte equality, so `eqString` is a byte compare.
- `index`-in-a-loop is O(n²) and documented as such; bulk iteration is an E2 capability (`foldChars`).
- All bounds errors raise `PrimError` (terminates `--run`), matching Array; error-path leak behaviour is unobservable, as for Array Slice A.

### 5.4 `PrimNames` additions (`src/Wok/IR/PrimNames.hs`)

Add `stdStringModule = "Std.String"` and name constants `stringLengthName`, `stringIndexName`, `stringByteLengthName`, `stringByteAtName`, `stringAppendName`, plus `eqStringName` (defining module `Std.Base`). Export them; the reference and RC prim tables key on them, exactly as the Array names do.

### 5.5 Literals & rendering

- **Literal allocation:** evaluating `ALit (LStr s)` in the RC interpreter now **allocates an `NString` cell** (UTF-8-encode `s`, alloc, fill) instead of producing an inline `RVLit (LStr s)`. This regresses the zero-alloc inline literal — the accepted E1 cost, reclaimed by E3 SSO. The reference interpreter keeps `VLit (LStr s)` (no cell there).
- **Rendering:** `--run` output and debug rendering must print an `NString` cell identically to the reference `VLit (LStr …)`. The existing `show`-quoted debug form is retained for rendering; there is **no separate `show : String -> String` prim** in E1 (it would be near-identity and ambiguous) — strings are observed through the normal output path, `byteAt`/`index`/`length`, and `==` against literals.

---

## 6. Integration / migration touch-points (the real work)

1. **`isBoxedType (CTCon TcString []) = True`** (`Escape.hs:123`, flip from `False`). Required so Perceus ref-counts String binders (they are counted cells now) and Reachable tracks them as boxed locals. Ripple to audit explicitly:
   - **Perceus** (`Wok.IR.Perceus`, `boxedBinder` gating, ~8 sites): String binders now get `__rc_dup`/`__rc_drop`. Correct and required.
   - **Reachable** (`Wok.IR.Reachable`): String params now tracked as boxed locals by the boundary guard. Verify no existing handler-module program regresses (run the full suite; strings are barely used, so practical risk is low but must be checked).
   - **Region** (`Wok.IR.Region`): see item 2.
2. **String is always Heap-allocated in E1 (no arena strings).** The arena bump path `wok_arena_alloc(tag, arity)` is `(tag, arity)`-shaped and cannot hold a variable-length byte cell. So the Region pass must route every `NString` allocation to **Heap**, never Arena. Confirm Region R1's handler-free-module gating is unaffected (strings don't participate in arena candidacy). Arena-allocating short-lived strings (a byte-aware `wok_arena_string_alloc`) is a later optimization, explicitly deferred.
3. **`slotClassOf (CTCon TcString []) = KPointer`** (`ReusePairing.hs:92`, flip from `NonEncodable`). A String value is now a counted C-heap pointer, so an `NCon` with a `String` field stays C-eligible (the String `Addr` stored as a pointer word).
4. **`PrimNames` + prelude module + `Eq String` instance** (§5).
5. **Literal evaluation + rendering** (§5.5).

---

## 7. The differential oracle

Reuse the existing harness (the one that validates Array). For a corpus of string programs:
- **Output parity:** RC AbstractHeap vs RC CHeap vs reference interpreter all produce byte-identical `main` output.
- **Memory parity:** RC AbstractHeap and RC CHeap agree on `allocs`, `frees`, `peak`, `peak_bytes`. (`peak_bytes` charges the rounded cell size `16 + 8*ceil(byte_len/8)` per live string; the AbstractHeap mirror charges the identical `wouldBeCBytes (NString bs)`.)
- **Physical invariant:** the R1 self-policing `peak_physical_bytes <= K·peak_logical + C·arena` assertion (sanitizer build) covers strings for free.
This same harness will validate the StringZilla FFI in E2 with no new machinery.

---

## 8. Testing strategy

- **Oracle corpus:** programs exercising each prim and combinations (literals, `append` chains, `length`/`byteLength` on ASCII and multi-byte text, `index`/`byteAt` at boundaries, `==`), each run through all three backends.
- **QuickCheck properties:**
  - `byteLength s >= length s`, with `==` iff `s` is all-ASCII.
  - `append` associativity; `length (append a b) == length a + length b`; `byteLength (append a b) == byteLength a + byteLength b`.
  - `eqString` reflexivity/symmetry; equal-iff-same-codepoints (UTF-8 boundary correctness — generate multi-byte scalars).
  - `index s i` and `byteAt s i` agree with the `Text` reference at sampled in-bounds offsets; OOB raises `PrimError` on every backend.
  - literal `"…"` and the same text built via `append` of single-scalar pieces render identically.
- **Sanitizers:** ASan/LSan clean (`scripts/asan-runtime.sh`), including the physical invariant.

---

## 9. Codegen transfer

The two durable artifacts are backend-agnostic: the `WokString` cell lives in the shared C runtime, and the region/escape routing is an IR annotation. Codegen reuses both. `wok_string_data` is already the channel a native StringZilla call (E2) uses, so that win lands even in the interpreter. The interpreter measures the alloc-count proxy; the cache/SIMD win is codegen/E2-era.

---

## 10. Risks & known limitations

- **`length`/`index` name-collision with `Std.Array`.** `Std.Array` also exports `length`/`index`. With qualified imports deferred, a program importing **both** `Std.Array` and `Std.String` unqualified will hit wok's cross-module same-name conflict (`[[diamond-import-env-merge-coarseness]]`). This is a documented consequence of the deferred qualified-imports slice — **not** worked around by renaming (which would leave legacy cruft once `String.length` / `Array.length` qualification lands). E1 test programs use them in separate modules. Flag for user awareness.
- **Literal allocation regression.** Every string literal now allocates a cell (was inline). Accepted; reclaimed by E3 SSO.
- **No arena strings in E1** (item §6.2) — strings are always counted. Deferred optimization.
- **`isBoxedType` flip blast radius** (§6.1) — mitigated by the full suite + the audit; low practical risk because strings are barely used today.
```
