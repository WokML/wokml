# String Slice E6 — `Bytes` type + validated `String` construction

Date: 2026-06-28
Status: DRAFT (pending user review)
Branch (target): `feat/string-slice-e6-bytes` off `main` (E1–E5 merged, local FF at `4c44196`)
Predecessor: [[string-architecture-slice-e]] — E1–E5 all on main (local FF, not pushed).

---

## 0. Scope

This slice delivers a **raw byte buffer type** (`Bytes`) and a **checked gate** that
turns raw bytes into a `String` only when they are well-formed UTF-8. It is the
validated-construction *boundary* that foreign-byte sources (files, sockets, C
buffers) will later plug into. It is the Rust `Vec<u8>` ↔ `String::from_utf8`
relationship, transplanted to wok.

**In scope (the entire surface added):**

- A new opaque builtin type `Bytes` — a flat, packed buffer of arbitrary,
  **unverified** bytes (not necessarily valid UTF-8).
- `fromList : [U64] -> Bytes` — pack a list of byte values into a `Bytes` (the
  MVP construction source; see §4.2 and §11-D for why `[U64]`).
- `toList : Bytes -> [U64]` — unpack to a list of byte values (round-trip /
  inspection).
- `length : Bytes -> U64` — number of bytes.
- `index : Bytes -> U64 -> U64` — the byte (0–255) at a byte offset.
- `eqBytes : Bytes -> Bytes -> Bool` + `instance Eq Bytes` — byte-wise equality
  (needed for tests and to make `Bytes` a usable first-class value; trivial).
- `fromBytes : Bytes -> Option String` — `Some s` iff the bytes are well-formed
  UTF-8, else `None`. **The heart of the slice.**
- `toBytes : String -> Bytes` — total; every `String`'s bytes are valid by the
  global invariant.
- **A full-buffer UTF-8 validator**, in two cross-checked implementations
  (§5): a Haskell one (`Data.Text.Encoding.decodeUtf8'`, the oracle anchor) and a
  C one (the Höhrmann DFA in a new `runtime/wok_utf8.c`, for the C-heap path).

**Explicitly NOT in scope (deferred, with the reasons):**

- **Real FFI byte producers** (`extern "lib" "sym"` returning bytes) and the
  **C→RC ownership handoff** (who allocates, who adopts the refcount). This is the
  *real consumer* the boundary exists for, but it is its own soundness surface
  (ownership transfer across the FFI boundary) and must not be entangled with the
  validator. The gate is producer-agnostic; FFI plugs into an already-proven gate
  in a later slice. See [[extern-primitive-declarations]].
- **A byte-string literal** (`b"\xC0\x80"`). Authoring arbitrary bytes (including
  invalid UTF-8) is done in this slice via `fromList [...]`. A literal needs work
  in the generated BNFC grammar — a separate slice.
- **`append` / `empty` / `slice` on `Bytes`.** Not needed for the boundary story.
  `empty` is just `fromList []`. Easy follow-ons.
- **The rc==1 in-place retag optimization** for `toBytes`/`fromBytes`. Because
  `WokBytes` and `WokString` share an identical layout (differing only by tag), a
  conversion of a uniquely-owned value can later become an O(1) tag flip (reusing
  the rc==1 gate from [[array-slice-c-inplace-set]] / [[fbip-reuse-slice1]]). MVP
  copies. See §6 and §11-E.
- **A `U8` type and `[U8] -> Bytes`.** Type-honestly a byte is a `U8`, but wok has
  no `U8` (only `U64`/`U32`), all numeric literals are hardwired to `U64`
  (`prelude/Std/Base.wok:38`: *"we hardcoded all number literal to U64 sorry"*),
  and `u32`-style narrowing is identity with no range enforcement
  (`Prim.hs:178`; a future `u8` would inherit this). So `[U8]` today would mean
  `fromList [u8 0xC0, u8 0x80]` (worse
  ergonomics) **and still** need the runtime range guard (no real safety). The
  correct fix is a future **sized-integers + `Num` typeclass** slice (§10): a real
  `U8` plus polymorphic literals (`fromInteger` over a `Num` dict, exactly how `Eq`
  already works — [[typed-core-next-eq-dictionaries]]) plus *enforced* narrowing.
  Once that lands, `fromList`/`index` *and* String's `byteAt`/`byteLength` migrate
  to `U8` coherently. The reserved `@` type-application token is the runway for
  this ([[at-token-reserved-type-application]]).
- **Unicode tables** (case folding / normalization / grapheme segmentation). This
  slice reorders ahead of that work, which becomes **E7**.

---

## 1. Background & motivation

### 1.1 The string invariant today

wok's `String` is flat UTF-8 with an **enforced** valid-UTF-8 invariant (reference
model = `Data.Text`). Runtime representations, all funnelled through `stringBytes`
in `src/Wok/Interp/RC/Prim.hs`:

- `NString ByteString` — flat valid UTF-8 (E1), `RC/Value.hs:681`.
- `InlineStr ByteString` — SSO, ≤7 bytes, no heap cell (E3), `RC/Value.hs:168`.
- `NStringView Addr Int Int` — zero-copy window into a parent (E4).

The invariant is **load-bearing**: `length`, `index`, `decodeCharAt`,
`charWidthAt`, and view slicing all *trust* that a string decodes cleanly. The
`NString` doc comment (`RC/Value.hs:681`) states it outright: strict `decodeUtf8`
on these bytes cannot throw.

### 1.2 The gap

There is **no way to construct a `String` from untrusted bytes**, and — verified —
**no full-buffer UTF-8 validator anywhere in the tree**. E5 added single-codepoint
decode (`decodeCharAt`, `charWidthAt` in `src/Wok/Interp/Utf8.hs`), but those
*assume* a valid boundary. The four ill-formedness classes (overlong encodings,
lone continuation bytes, code points > U+10FFFF, lone surrogates) are currently
**unreachable and untested** because nothing can introduce them.

This slice closes the gap and, in doing so, finally makes those rejection paths
reachable and testable.

### 1.3 Why a separate `Bytes` type (not "just validate at the FFI call")

The boundary needs a *type* for "bytes that have not been checked yet," so the
type system can distinguish "raw, possibly-invalid" from "validated `String`." That
is exactly `Bytes`. It is the staging area between the outside world and the
invariant-bearing `String`.

---

## 2. Architectural rationale: reuse the String framework, not `Array`

**Claim (confirmed in the brainstorm):** `Bytes` is monomorphic flat bytes — "a
`String` without the UTF-8 invariant" — so it reuses the existing
`WokString` / Array-Slice-B C-cell framework, and does **not** reopen the deferred
polymorphic flat/unboxed-array problem ([[array-slice-d-deferred-regions-pivot]]).

**Why this holds:**

- `Array a` was hard to pack flat because its element type `a` is *unknown*: flat
  storage needs either boxing (what we do) or monomorphization (wok deliberately
  doesn't — it is in the Koka/OCaml uniform-representation camp). That is the
  deferred problem.
- `Bytes` has **no type parameter**. Its element is a fixed, known byte. So the
  buffer is a flat run of known stride — *exactly* the shape `WokString` already
  is, and `WokString` already proves a monomorphic flat-byte cell end-to-end (cell
  layout, byte-size-class allocator, FFI fill, prims, differential oracle).

So `Bytes` is a near-clone of `WokString`-minus-the-invariant. Array-Slice-D stays
closed. The intuition "`Bytes` is morally `Array U8`" is honored only at the
**surface** (array-like names `length`/`index`/`fromList`/`toList`) — the
**representation** is the String-family flat cell.

---

## 3. The `Bytes` type & representation

### 3.1 Type-system level

Add `Bytes` as a builtin nullary tycon, beside `String`, in
`src/Wok/TypeChecking/Builtins.hs:34`:

```haskell
("Bytes",  TyConInfo KStar 0 [] False [])
```

It needs the corresponding internal type constructor: add `TcBytes` to the `TyCon`
sum in `src/Wok/TypeChecking/Types.hs:45`, and wire it in the name↔TyCon maps:
`Infer.hs:827`-area (`name == "Bytes" = TcBytes`), `Class.hs:296`-area, and the
pretty-printers `Infer.hs:3771` / `Anf.hs:392` (`prettyCType (CTCon TcBytes [])`).
The IR `Lit` type (`Wok.IR.Anf:43`) is **untouched** — there is no byte literal;
`Bytes` values arise only from prim calls.

### 3.2 Runtime representations

| Path | Carrier | Notes |
|------|---------|-------|
| Reference interpreter | **`VBytes ByteString`** — new `Value` ctor (`src/Wok/Interp/Value.hs:57`) | Strings there are `VLit (LStr Text)` (`Prim.hs`), which *cannot* hold invalid bytes; hence a dedicated raw-bytes value. |
| RC interp, abstract heap | **`NBytes ByteString`** — new `Node` ctor (`src/Wok/Interp/RC/Value.hs:681`, beside `NString`) | Mirrors `NString ByteString`. |
| RC interp, C heap | **`WokBytes` C cell** — new reserved tag `WOK_BYTES_TAG` | Byte-identical layout to `WokString`; shares the size-class allocator. |

`Bytes` gets **no SSO** (no `InlineBytes` `Addr` variant). SSO is a String-specific
optimization tied to the `LStr`/`VLit` fast path; `Bytes` always lives on the heap
(`HAddr`/`CAddr`). State this explicitly so no one "completes the symmetry" later.

### 3.3 The C cell + the reserved-tag plumbing (the load-bearing details)

Existing reserved tags (`runtime/wok_rc.h`, verified): `WOK_ARRAY_TAG = 0xFFFF`
(`:88`), `WOK_STRING_TAG = 0xFFFE` (`:112`), `WOK_STRING_VIEW_TAG = 0xFFFD`
(`:134`). Add the **fourth** reserved tag, numerically one *below* the string-view
tag:

```c
#define WOK_BYTES_TAG 0xFFFCu
```

`WokBytes` has the same struct layout as `WokString` (8-byte header: rc + tag +
reserved + scan; then `byte_len` at offset 8; then the packed bytes), so the
size-class math (`wok_string_cell_bytes` / `wok_string_class`) is reused. The C
side needs:

1. **Allocator + accessors** (mirror `wok_string_*`): `wok_bytes_alloc`,
   `wok_bytes_len`, `wok_bytes_data`, `wok_bytes_byte_get` in `runtime/wok_rc.c`.
   (Layout-identical, so these can share the string helpers internally, but expose
   distinct symbols so the tag stays honest.)
2. **`wok_free` dispatch arm** (`runtime/wok_rc.c:676-693`): add an explicit
   `WOK_BYTES_TAG` case. Without it, a `WokBytes` cell falls through to the NCon
   arity path; that *might* compute the right size class by accident, but it is
   semantically wrong and fragile. **Explicit arm required.**

Haskell side (`src/Wok/Interp/RC/Heap.hs`, mirror the `wok_string_*` block at
`:45-49`): add `foreign import` bindings for the four `wok_bytes_*` symbols and the
validator (§5). Then, in `src/Wok/Interp/RC/Value.hs`:

3. **`internTag` skip** (`:1011-1029`, skip logic at `:1023-1025`): `internTag`
   currently skips `0xFFFD/0xFFFE/0xFFFF` so an interned constructor tag can never
   collide with a reserved cell tag. Add a **fourth** skip step for `0xFFFC`
   (preserving the descending-order invariant — skip the lowest reserved tag
   first), and update the reserved-tag comment block at `wok_rc.h:85-86` to list
   `0xFFFC`. **Omitting this is a latent tag collision.**
4. **`deref` / `derefPure` arms** (`:1966-1992` and the pure mirror ~`:2069`):
   add a `wokBytesTag` arm that reconstructs an `NBytes` from a C cell by reading
   its byte buffer, mirroring the `wokStringTag` arm. Define
   `wokBytesTag :: Word32 = 0xFFFC` beside the existing tag constants.

---

## 4. Surface API (`Std.Bytes`)

New prelude module `prelude/Std/Bytes.wok`:

```wok
module Std.Bytes
import Std.Base

extern fromList : [U64] -> Bytes
extern toList   : Bytes -> [U64]
extern length   : Bytes -> U64
extern index    : Bytes -> U64 -> U64
extern fromBytes : Bytes -> Option String
extern toBytes   : String -> Bytes
```

`eqBytes` lives in `Std.Base` beside `eqString` (the established placement —
`PrimNames.hs:204`, `Prim.hs:499`), with `instance Eq Bytes` in `Std.Base.wok`.

`PrimNames.hs`: add `stdBytesModule = "Std.Bytes"` and a name constant per prim,
mirroring `stdStringModule` and the string-name constants.

### 4.1 Semantics

- `length bs` — byte count. `index bs i` — the byte at offset `i` as a `U64`
  (0–255); **out-of-bounds traps** (`PrimError`), matching `String.byteAt`
  (`asU64Index` in `Prim.hs`). A `PrimError` terminates the program (it is not a
  recoverable value; cf. [[array-slice-a-merged]]).
- `eqBytes a b` — `True` iff the two byte sequences are identical (`ByteString`
  `==`).

### 4.2 Construction: `fromList : [U64] -> Bytes`

Walks the cons spine (the existing `collectList` pattern, `RC/Prim.hs`), reading
each element as a byte and packing into one flat `Bytes`. **An element > 255 traps
(`PrimError`)** — loud beats silent masking, and consistent with OOB `index`.
(`[U64]` is the source because it is the only pure-wok way to author *arbitrary*,
including invalid-UTF-8, byte sequences today; see §11-D.)

`toList : Bytes -> [U64]` — the inverse, building a `Cons`/`Nil` chain
(reference: inline `foldr` over `VCon "Cons"`, cf. `Prim.hs:388`; RC: the
`buildList` helper, `RC/Prim.hs:686`), each byte as a `U64`.

### 4.3 RC discipline

All prims **consume** their boxed operands and `dropAddr`/`dropValue` them after
reading, per the established string/array prim pattern. `fromList` drops the input
list spine; `toBytes`/`fromBytes` drop the input. New cells are allocated at rc==1.

---

## 5. The validator (the heart) — two implementations, one contract

### 5.1 Contract

A byte buffer is **valid** iff it is well-formed UTF-8: it decodes as a sequence of
Unicode scalar values. The validator must **reject** all four ill-formedness
classes and **accept** every valid sequence (including empty):

| Class | Example bytes | Verdict |
|-------|---------------|---------|
| Overlong encoding | `C0 80` (overlong U+0000) | reject |
| Lone continuation | `80` | reject |
| Code point > U+10FFFF | `F7 BF BF BF` | reject |
| Lone surrogate | `ED A0 80` (U+D800) | reject |
| Truncated multibyte | `E2 82` (missing 3rd byte) | reject |
| Valid | `41 C3 A9 E2 82 AC F0 9F 98 80` ("Aé€😀") | accept |

### 5.2 Haskell validator — the oracle anchor

A single shared helper in `src/Wok/Interp/Utf8.hs` (its natural home — it already
holds `utf8Width`/`decodeCharAt`):

```haskell
validateUtf8 :: ByteString -> Bool
validateUtf8 bs = case TxEnc.decodeUtf8' bs of
  Right _ -> True
  Left  _ -> False
```

`Data.Text.Encoding` is already imported across the interpreters (`RC/Prim.hs:15`,
`Prim.hs:10`, `RC/Value.hs:116`), and the installed `text-2.1.3` `decodeUtf8'`
rejects all four classes — so this is **zero new dependency**. It is also
*definitionally* the right gate: it admits exactly the byte sequences for which the
`NString` "strict decode cannot throw" invariant holds. Used by the **reference
interpreter** and the **RC abstract-heap** path, and it is the **oracle anchor**
the C validator must match.

### 5.3 C validator — the Höhrmann DFA

A new `runtime/wok_utf8.c` containing Björn Höhrmann's "Flexible and Economical
UTF-8 Decoder" DFA (public domain / MIT), exposing:

```c
int wok_validate_utf8(const uint8_t *bytes, uint64_t len);  /* 1 = valid, 0 = invalid */
```

~40 lines: a small static state/class table + a per-byte transition loop; valid iff
the machine ends in the accept state. It rejects overlong / surrogate / >U+10FFFF /
bad-continuation **by construction** (the table encodes the valid ranges). Empty
buffer → valid. No C++, no vendored library. Add `runtime/wok_utf8.c` to
`wok.cabal:118` `c-sources` (the existing `-std=c17 -O3` stanza at `:122` covers
it). Used by the **RC C-heap** path: read the `WokBytes` buffer pointer
(`wok_bytes_data`) + length and call `wok_validate_utf8` — validating *where the
bytes physically live*, which is the codegen-honest placement.

> Rejected: **simdutf** (C++ — escalates a pure-C build; SIMD irrelevant at
> interpreter scale) and **StringZilla's** rune machinery (`_sz_extract_utf8_rune`
> is `SZ_INTERNAL` and *trusts* its input — masks continuation bytes without
> checking, no overlong/surrogate/range checks; "result is undefined if corrupted"
> — it would *accept* exactly the four classes we must reject). See §11-C.

### 5.4 Cross-check

Two layers:
1. The existing **differential oracle** runs each wok program on the reference
   interpreter (Haskell validator) *and* the RC C-heap backend (C validator),
   comparing `Some`/`None` outcomes across the full corpus.
2. A dedicated **Haskell-level agreement test** runs both `validateUtf8` and
   (via FFI) `wok_validate_utf8` over the valid + four-invalid corpus and asserts
   they agree byte-for-byte. This catches divergence directly, not only through
   program output.

---

## 6. Conversions

- `toBytes : String -> Bytes` — **total**. Reads the string's bytes (`stringBytes`,
  which already handles `NString`/`InlineStr`/`NStringView`) and packs them into a
  `Bytes` (a `VBytes`/`NBytes`/`WokBytes`). Always valid; no check.
- `fromBytes : Bytes -> Option String` — read the bytes; run the validator
  (§5.2 on reference/abstract, §5.3 on C-heap); on success build a `String` from
  the same bytes and return `Some`, else `None`.

MVP **copies** on both. The rc==1 in-place tag flip (since layouts are identical)
is deferred (§0, §11-E).

---

## 7. Soundness: the invariant stays global

`fromBytes` is the **only** new way bytes can enter a `String`, and it emits `Some`
only after the validator passes. Existing construction paths all preserve validity:
literals (`encodeUtf8` of valid `Text`), `append` (concatenation of valid UTF-8 is
valid), `slice`/`byteSlice` (E4 boundary checks), `singleton` (E5, one valid
`Char`). And there is **no surface `chr`/`ord`** (verified — absent from prelude
and `PrimNames.hs`), so every `Char` is a valid scalar by construction and
`singleton`/`decodeCharAt` cannot inject invalid bytes.

Therefore the global "`String` is always valid UTF-8" invariant holds after this
slice, `decodeCharAt`'s precondition remains guaranteed, and the latent `chr`-guard
stays unnecessary. `toBytes` cannot break anything (`Bytes` has no invariant).

---

## 8. Test plan

New `test/rc-bytes/` directory, mirroring `test/rc-string/` and wired into the
harnesses in `test/Spec.hs` (differential `rcDifferentialHarness`, alloc-stats
`rcStatsHarness`, C-backend parity `rcCBackendParity`; output-bearing programs into
`run golden` at `Spec.hs:295`).

**Validator corpus (the centerpiece):**
- Valid → `Some`: empty, ASCII, 2-byte (`é`), 3-byte (`€`/CJK), 4-byte (emoji),
  mixed; boundary scalars U+0000, U+007F/U+0080, U+07FF/U+0800, U+FFFF/U+10000,
  U+10FFFF.
- Invalid → `None`: overlong (`C0 80`, `E0 80 80`, `F0 80 80 80`), lone
  continuation (`80`, `BF`), > U+10FFFF (`F4 90 80 80`, `F7 BF BF BF`), lone
  surrogate (`ED A0 80` … `ED BF BF`), truncated multibyte (`C3`, `E2 82`,
  `F0 9F 98`), stray `F8`–`FF` lead bytes.

**Functional:** `fromList`/`toList` round-trip; `length`/`index` incl. OOB trap;
`fromList` out-of-range element trap; `eqBytes` true/false; `fromBytes ∘ toBytes`
content-identity; `toBytes` totality.

**Invariants:** alloc-stat parity (reference vs RC) and C-backend parity on every
program; the §5.4 Haskell↔C validator agreement test.

**Property tests (QuickCheck):** for arbitrary `[Word8]`, `validateUtf8` agrees
with `wok_validate_utf8`; for any `String` value, `fromBytes (toBytes s) == Some
s'` with `s'` content-equal to `s`; `toList ∘ fromList` is identity on `[0..255]`
byte lists.

The `interpPrimTests` enumeration (`test/Spec.hs:4705-4722`) must gain all six
`Std.Bytes` `extern` prims plus `eqBytes` — that test fails otherwise.

---

## 9. File-by-file change plan (basis for the task plan)

1. **`runtime/wok_rc.h`** — `WOK_BYTES_TAG 0xFFFC`; update reserved-tag comment
   (`:85-86`); declare `wok_bytes_alloc/len/data/byte_get`, `wok_validate_utf8`.
2. **`runtime/wok_rc.c`** — implement the four `wok_bytes_*` accessors; add the
   `WOK_BYTES_TAG` arm to `wok_free` (`:676-693`).
3. **`runtime/wok_utf8.c`** (new) — the Höhrmann DFA `wok_validate_utf8`.
4. **`wok.cabal`** — add `runtime/wok_utf8.c` to `c-sources` (`:118`).
5. **`src/Wok/Interp/Utf8.hs`** — `validateUtf8 :: ByteString -> Bool` via
   `decodeUtf8'`.
6. **`src/Wok/TypeChecking/Builtins.hs`** — `Bytes` tycon (`:34`).
7. **`src/Wok/TypeChecking/Types.hs`** — `TcBytes` (`:45`).
8. **`src/Wok/TypeChecking/Infer.hs` / `Class.hs` / `IR/Anf.hs`** — name↔TyCon
   maps + pretty-printers for `TcBytes`.
9. **`src/Wok/IR/PrimNames.hs`** — `stdBytesModule` + per-prim name constants +
   `eqBytesName`.
10. **`prelude/Std/Bytes.wok`** (new) — the six externs.
11. **`prelude/Std/Base.wok`** — `extern eqBytes` + `instance Eq Bytes`.
12. **`src/Wok/Interp/Value.hs`** — `VBytes ByteString` + `renderValue` arm.
13. **`src/Wok/Interp/Prim.hs`** — reference prims (`fromList`/`toList`/`length`/
    `index`/`fromBytes`/`toBytes`/`eqBytes`).
14. **`src/Wok/Interp/RC/Value.hs`** — `NBytes ByteString`; `wokBytesTag`;
    `internTag` skip; `deref`/`derefPure` arms; `renderRCValue` arm.
15. **`src/Wok/Interp/RC/Heap.hs`** — FFI bindings for `wok_bytes_*` +
    `wok_validate_utf8`.
16. **`src/Wok/Interp/RC/Prim.hs`** — RC prims (abstract + C-heap paths; C path
    uses `wok_validate_utf8`).
17. **`test/rc-bytes/`** (new) + **`test/Spec.hs`** — corpus, harness wiring,
    `interpPrimTests` update, agreement + property tests.

(Implementation tiers assigned in the plan; most are mechanical given the exact
anchors above, with the validator wiring and the RC C-heap path as the standard /
judgment tasks.)

---

## 10. Deferred / future

- **Real FFI byte producers** + C→RC ownership handoff (the next slice; the reason
  the boundary exists).
- **Byte-string literal** `b"..."` (grammar work).
- **`append`/`empty`/`slice` on `Bytes`**; the **rc==1 in-place retag** for
  conversions.
- **Sized integers + `Num` typeclass** (the `[U8]` enabler). Names are sizes
  (`U8`/`U16`/`U32`/`U64`); a `Num` class carrying the integer ops + `fromInteger`
  desugaring gives polymorphic literals (retiring the U64 hardwire) and per-width
  *enforced* narrowing. Built on the existing dictionary-passing machinery
  ([[typed-core-next-eq-dictionaries]]); `@` reserved as the runway
  ([[at-token-reserved-type-application]]). Afterward, `fromList`/`index` and
  String's `byteAt`/`byteLength` migrate `U64 → U8`.
- **E7 = Unicode tables** (case/normalize/grapheme).
- **Strategic fork (unprompted, do not act):** a large pile of value-model wins is
  banked for a codegen backend (QBE / Fable chordal-SSA) that does not yet exist.
  This slice is now-useful + foundational, but after it the "keep banking vs start
  cashing (codegen)" decision is still open. The C validator placement here is a
  small down-payment toward the codegen runtime.

---

## 11. Decision log (incl. rejected alternatives)

- **A — Representation: distinct twin cell, not a shared cell.** A new `WokBytes`
  cell/tag (identical layout to `WokString`) keeps the type distinction backed by a
  representation distinction, so tag-dispatched `wok_free`/`deref` and prim
  tag-guards stay unambiguous and the "`NString` is always valid UTF-8" runtime
  assumption stays crisp. *Rejected:* sharing `WokString`'s cell with a phantom
  type-only distinction — buys zero-copy conversions but makes Bytes and String
  runtime-indistinguishable; the zero-copy win is recoverable later via the rc==1
  retag *without* giving up the distinct tag.
- **B — Validator gate = `decodeUtf8'` (+ C DFA), not a hand-rolled walker.** The
  reference decoder is correct on the exact edge cases (overlong/surrogate/range)
  where hand-rolled validators have bugs, and it matches the reference model. The C
  DFA is the cross-checked second implementation for the C-heap path.
- **C — Rejected simdutf and StringZilla as validators.** simdutf is C++ (toolchain
  escalation into a pure-C build) and SIMD-irrelevant at interpreter scale.
  StringZilla has no validator; its UTF-8 routines *trust* input and would accept
  the four invalid classes.
- **D — `fromList : [U64]`, out-of-range traps.** No `U8` exists; `[U64]` is the
  only pure-wok way to author arbitrary/invalid bytes; trap (not mask) is loud and
  matches OOB `index`. *Rejected:* `[U8]` now (illusory safety + worse ergonomics,
  §0); `Option Bytes` (clunky `Some`-unwrap at every fixture).
- **E — Conversions copy in MVP.** Correct and simple; rc==1 in-place retag is a
  clean follow-on reusing the existing rc==1 gate.
- **F — Surface names `length`/`index` (array-like).** Honors the "bytes are an
  array" intuition at the surface. *Alternative considered:* `byteLength`/`byteAt`
  (String-parallel) — would matter only if a future typeclass unifies them.

---

## 12. Open questions / risks

1. **`text` validity exactness.** Confirm `text-2.1.3` `decodeUtf8'` rejects all
   four classes (expected; verify in the agreement test, which is the guard anyway).
2. **`PrimError` observability.** OOB/out-of-range traps terminate the program;
   ensure the test harness asserts the failure mode the way the string OOB tests do
   (`test/rc-string/*-oob*`).
3. **`renderValue`/`renderRCValue` format for `Bytes`** must be chosen (e.g.
   `Bytes[..]`) and kept identical across both interpreters so golden output and
   differential rendering agree (alignment finding G4).
4. **C-heap `fromBytes` build step.** On success it allocates a `WokString` from the
   validated `WokBytes` bytes; confirm the size-class/copy path matches
   `wok_string_alloc` + `wok_string_data` fill.
