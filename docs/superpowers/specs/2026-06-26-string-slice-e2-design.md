# String Slice E2: StringZilla byte-ops + dogfooded search layer — Design Spec

**Date:** 2026-06-26
**Status:** Approved for planning (brainstorm converged; alignment review passed — references confirmed real, hash-oracle strategy and Option encoding resolved below)
**Predecessor:** String Slice E1 (`2026-06-25-string-slice-e1-design.md`, the `WokString` C cell + `Std.String` + three-way oracle this builds on)
**Companions:** `docs/string-architecture.html` (closed), `docs/trmc-and-list-representation.html` (list-representation research that produced the deferral decisions below)

---

## 1. Goal & scope

Add fast substring search, hashing, and edit distance over the UTF-8 bytes that E1 already stores on the `WokString` C cell, by vendoring **StringZilla** (Apache-2.0, single header, runtime SIMD dispatch) and calling it over FFI. On top of the irreducible SIMD primitives, build a thin **dogfooded** layer of derived search ops written in wok itself. Extend the existing three-way differential oracle to cover everything.

**In scope (E2):**
- Vendor StringZilla (header + LICENSE) and a dedicated C translation unit of thin wrappers.
- Three FFI primitives, each `… -> U64` (trivial C/Haskell surface): `indexOfFromRaw` (byte find-from-offset, sentinel for not-found), `hash`, `editDistance` (byte-level Levenshtein).
- A dogfooded wok layer over `indexOfFromRaw`: `indexOf`, `indexOfFrom`, `contains`, `count` — ordinary `Std.String` functions, no new prim, no FFI.
- The per-op backend-agreement strategy (the reference backend cross-validates StringZilla with an independent pure-Haskell implementation where one exists; uses the same FFI where none does — `hash`).
- Hash determinism: identical output across all three backends (by construction) plus a golden `(string -> hash)` corpus that pins it; a fixed hash seed for reproducibility.
- Oracle + QuickCheck property extensions for every new op.

**Out of scope (named so the boundary is explicit):**
- **Codepoint iteration** — `chars : String -> [Char]`, `fromChars : [Char] -> String`, and the non-allocating `foldChars` (which needs the prim-calls-closure machine frame). Deferred to a later slice; the frame edits the interpreter's machine core and is the heavy, risky piece, with no consumer forcing it into E2.
- **TRMC** (tail-recursion-modulo-cons for list producers), **chunked/unrolled or RRB list representations**, and an **`Array` amortized push-back builder** — future list-performance slices captured in `docs/trmc-and-list-representation.html`. The chunked list is recorded with the caveat that it fights reference-counting promptness, so it would land (if ever) as a *builder* or in a non-RC context, not as `[]`'s representation.
- **Ordering comparison (`<`, `<=`, …) for the language** — not needed by E2's dogfooded ops (they require only `Option` + pattern matching + `eqU64`/`+`). A worthwhile future Std.Base addition, but not an E2 blocker.
- **`append` via `sz_copy`** — deliberately not used; copy is bandwidth-bound and StringZilla's value is search/hash/edit-distance. E1's plain alloc+copy `append` stays.
- **StringZilla as a codegen-time call on the C cell pointer (zero-copy)** — E2 calls it on the byte buffer extracted via the existing `stringBytes` helper, uniform across RC backends. The zero-copy native call is a codegen-era refinement (§9).
- **E3** (small-string optimization), **E4** (zero-copy views + table-driven Unicode).

---

## 2. Background — where E1 left things

E1 made `String` a real value: a flat UTF-8 byte buffer on a dedicated `WokString` C cell (tag `0xFFFE`), mirrored on the pure backend as an `NString ByteString` node, with six ops (`length`, `index`, `byteLength`, `byteAt`, `append`, `Eq String`) and a three-way differential oracle (RC AbstractHeap vs RC CHeap vs the `Data.Text` reference) over output + `allocs`/`frees`/`peak`/`peak_bytes`.

The two facts E2 leans on:
- **The C cell already exposes its bytes.** `uint8_t* wok_string_data(WokObj*)` (`runtime/wok_rc.h:115`, `runtime/wok_rc.c:907`) returns a raw pointer to the packed UTF-8 body — exactly what StringZilla reads. `wok_string_len` gives the byte count.
- **Prim identity is `(module, name)`-keyed** in both prim tables (reference `src/Wok/Interp/Prim.hs:28`, RC `src/Wok/Interp/RC/Prim.hs:49`), with a `Std.String` section (`stringPrims` / `rcStringPrims`) and name constants in `src/Wok/IR/PrimNames.hs` (`stdStringModule:196`). Adding ops is additive in the established pattern.

E2 adds **no new heap node and no boxedness change** — `String` is already a counted, boxed, heap-only value from E1. The new prims are pure byte->value functions; the dogfooded ops are plain wok functions. The migration surface is therefore far smaller than E1's.

---

## 3. Decisions (converged in brainstorm 2026-06-26)

1. **StringZilla over FFI for the SIMD-irreducible ops.** SIMD kernels + CPUID dispatch are inexpressible in wok; this is the legitimate "really cannot be dogfooded" case. (The interpreter does not yet *cash in* the SIMD speed — that lands at codegen, §9 — but the FFI win is banked now and the quality/correctness is available immediately.)
2. **Dogfood the derived search ops in wok.** The only irreducible search primitive is "find a substring from a byte offset." Expose that one primitive (`indexOfFromRaw`) and write `indexOf`, `indexOfFrom`, `contains`, `count` as wok functions over it. This proves the FFI primitives compose in wok and keeps the FFI/prim surface to three trivial `… -> U64` functions.
3. **All three FFI primitives return `U64`.** No prim constructs an ADT. `indexOfFromRaw` returns the absolute byte position or a `maxU64` sentinel for "not found"; the `Option`-wrapping is dogfooded in wok. (Strings cannot reach `2^64-1` bytes — the E1 cell-size overflow guard caps length far below — so the sentinel is unambiguous.)
4. **`editDistance` is byte-level.** It matches StringZilla's `sz_edit_distance` (unit-cost Levenshtein over bytes) and E1's byte-native escape-hatch philosophy. For multi-byte codepoints, byte-level differs from codepoint-level; this is declared, not hidden. (Codepoint-level edit distance would need the deferred iteration layer.)
5. **Per-op backend agreement (the oracle strategy).**
   - `indexOfFromRaw`, `editDistance`: the **RC backends call StringZilla**; the **reference backend uses an independent pure-Haskell implementation** (`Data.ByteString.breakSubstring`-based find; pure unit-cost byte Levenshtein). The RC-vs-reference differential thus genuinely cross-validates StringZilla against a separate implementation.
   - `hash`: no independent equivalent exists (it is StringZilla's own algorithm), so **all three backends call the same `sz_hash`**. They agree by construction; real correctness comes from properties + a golden corpus (§7).
6. **Deterministic hash.** v3 `sz_hash(text, length)` takes no seed, so output is reproducible by construction (stable golden corpus, stable across runs). Seed-randomized hashing (hash-flooding DoS resistance) is not offered by this entry point and is deferred to a future `HashMap` slice that would actually consume it.
7. **Hash's consumer is acknowledged-absent.** wok has no `HashMap`/`HashSet` yet; `hash` is included now to bank the primitive and have a quality hash ready, accepted as a primitive slightly ahead of its consumer.

---

## 4. Architecture

### 4.1 Vendoring + build (`runtime/`)

- **Vendored header (DONE):** `runtime/vendor/stringzilla/stringzilla.h` — **StringZilla v3.12.5**, a single self-contained ~343 KB header carrying the full C API (`sz_find`, `sz_hash`, `sz_edit_distance`, plus `*_serial` kernels) — already vendored alongside `LICENSE` (Apache-2.0) and `PROVENANCE.txt`. **v3 not v4 by deliberate choice:** StringZilla v4 is a multi-header library (umbrella `#include`s `find.h`/`hash.h`/… ) and dropped edit-distance from its core C API; v3.12.5 is the last line with a single drop-in header carrying all three ops.
- **Wrapper TU:** a new `runtime/wok_str_ops.c` is the *single* translation unit that includes StringZilla's implementation (defining its single-header implementation/dynamic-dispatch macro before the `#include`), enabling runtime SIMD dispatch. It defines thin wrappers over **raw byte ranges** (not `WokObj*`), so the same entry points serve a C-cell pointer, a Haskell `ByteString`, and an `encodeUtf8` buffer uniformly:

```c
/* runtime/wok_str_ops.c */
/* NB: v3.12.5 guards the SZ_DYNAMIC function *definitions* behind `#if !SZ_DYNAMIC_DISPATCH`,
   so DO NOT set SZ_DYNAMIC_DISPATCH=1 in a single-header drop-in (it would leave sz_find /
   sz_edit_distance undefined -> link/SIGSEGV). Left at its default 0: the impls compile
   inline-static into this TU with COMPILE-TIME SIMD selection (NEON on this arm64 host).
   Runtime CPUID dispatch is a codegen-era refinement (spec section 9), not needed here. */
#include "stringzilla/stringzilla.h"
#include <stdint.h>
#include <stddef.h>

#define WOK_SZ_NOT_FOUND UINT64_MAX

/* first occurrence of needle in hay at or after byte offset `from`;
   absolute byte position, or WOK_SZ_NOT_FOUND. */
uint64_t wok_sz_find(const char* hay, size_t hay_len,
                     const char* needle, size_t needle_len, size_t from);
uint64_t wok_sz_hash(const char* data, size_t len);            /* fixed seed inside */
uint64_t wok_sz_edit_distance(const char* a, size_t a_len,
                              const char* b, size_t b_len);     /* unit-cost byte Levenshtein */
```

  - Wrappers cast the `wok_string_data` result to `const char*` explicitly (StringZilla never writes through it; keeps strict-aliasing well-defined).
  - `wok_sz_find` handles `from >= hay_len` (-> not found) and empty needle (-> returns `from`, "the empty string occurs at the cursor").
  - **Underlying v3 calls:** `wok_sz_find` -> `sz_find(hay+from, hay_len-from, needle, needle_len)` which returns a `sz_cptr_t` (pointer, or `SZ_NULL`); the wrapper converts to the absolute offset `from + (match - (hay+from))` or `WOK_SZ_NOT_FOUND`. `wok_sz_edit_distance` -> `sz_edit_distance(a, la, b, lb, SZ_SIZE_MAX, SZ_NULL)` (unbounded; `SZ_NULL` allocator -> default libc scratch, so it stays invisible to wok counters). `wok_sz_hash` -> `sz_hash(data, len)` (no seed parameter -> deterministic by construction).
- **Cabal:** extend the C stanza (`wok.cabal:116-118`): add `runtime/wok_str_ops.c` to `c-sources` and `runtime/vendor` to `include-dirs`. `cc-options` apply per-component (not per-file), so the existing `-std=c17 -O3 -fstrict-aliasing -Wstrict-aliasing=2 -fwrapv` also cover `wok_str_ops.c`; there is no `-Werror`, so any warnings from the vendored header are non-fatal. The separate TU still buys hygiene (StringZilla's bulk does not bloat `wok_rc.c`); if a specific warning is noisy, wrap the `#include` in `#pragma GCC diagnostic push/ignored/pop`.

### 4.2 Haskell FFI bindings (new module `Wok.Runtime.StringZilla`)

A small shared module both prim tables import, exposing **pure** wrappers (the C functions are pure byte->value, so `unsafeDupablePerformIO` + `BS.unsafeUseAsCStringLen` is sound and avoids copying):

```haskell
module Wok.Runtime.StringZilla (szFind, szHash, szEditDistance) where
-- ...
foreign import ccall unsafe "wok_sz_find"
  c_wok_sz_find :: Ptr CChar -> CSize -> Ptr CChar -> CSize -> CSize -> IO Word64
foreign import ccall unsafe "wok_sz_hash"
  c_wok_sz_hash :: Ptr CChar -> CSize -> IO Word64
foreign import ccall unsafe "wok_sz_edit_distance"
  c_wok_sz_edit_distance :: Ptr CChar -> CSize -> Ptr CChar -> CSize -> IO Word64

szFind        :: ByteString -> ByteString -> Int -> Word64   -- pos or maxBound
szHash        :: ByteString -> Word64
szEditDistance:: ByteString -> ByteString -> Word64
```

Placed under `Wok.Runtime` (not `Wok.Interp.RC.Heap`) because these are pure computations independent of the RC heap; both the reference interpreter and the RC interpreter use them. AbstractHeap calling them is sound — they touch no `wok_rc` allocator state (they do not allocate wok cells; StringZilla's own internal scratch is libc `malloc`, §7).

### 4.3 The prim layer

Three new externs in `Std.String`, named in `PrimNames` (`indexOfFromRawName`, `hashName`, `editDistanceName` under `stdStringModule`), implemented in both tables. Each consumes its `String` args following the E1 args-consuming convention. RC accounting: `indexOfFromRaw`/`hash`/`editDistance` allocate **0** wok cells (they return a `U64` literal).

| prim | reference backend (`VLit (LStr Text)`) | RC backend (`NString` via `stringBytes`) |
|------|----------------------------------------|------------------------------------------|
| `indexOfFromRaw s n from` | independent: `BS.breakSubstring` on `BS.drop from (encodeUtf8 s)`, return absolute pos or `maxBound` | `szFind (bytes s) (bytes n) from` |
| `editDistance a b` | independent: pure unit-cost byte Levenshtein over `encodeUtf8` | `szEditDistance (bytes a) (bytes b)` |
| `hash s` | `szHash (encodeUtf8 s)` (same FFI — no independent equivalent) | `szHash (bytes s)` |

`bytes` = the existing `stringBytes` helper (`RC/Prim.hs:703`), which yields the `ByteString` from either RC backend, so AbstractHeap and CHeap run identical code and agree trivially. Pure-prim Haskell calls `szFind`/`szEditDistance`/`szHash` via the pure wrappers.

### 4.4 The dogfooded wok layer (`prelude/Std/String.wok`)

```
-- StringZilla FFI primitives
extern indexOfFromRaw : String -> String -> U64 -> U64   -- byte pos, or `notFound` if absent
extern hash           : String -> U64
extern editDistance   : String -> String -> U64          -- byte-level (unit-cost Levenshtein)

-- "not found" sentinel for indexOfFromRaw. (If the lexer rejects a 20-digit U64
-- literal, replace with `extern maxU64 : U64`; trivial.)
notFound : U64
notFound = 18446744073709551615

indexOfFrom : String -> String -> U64 -> Option U64
indexOfFrom s n from =
  let r = indexOfFromRaw s n from in
  case eqU64 r notFound of
    True  -> None
    False -> Some r

indexOf : String -> String -> Option U64
indexOf s n = indexOfFrom s n 0

contains : String -> String -> Bool
contains s n = case indexOf s n of
  Some _ -> True
  None   -> False

-- count of NON-OVERLAPPING occurrences. Empty needle -> 0 (avoids the degenerate
-- loop), declared as a deliberate simplification.
count : String -> String -> U64
count s n = case eqU64 (byteLength n) 0 of
  True  -> 0
  False -> countFrom s n 0 0

countFrom : String -> String -> U64 -> U64 -> U64
countFrom s n from acc = case indexOfFrom s n from of
  None   -> acc
  Some i -> countFrom s n (i + byteLength n) (acc + 1)
```

These are ordinary wok functions: they run identically on all three backends (they bottom out in `indexOfFromRaw` + `Option`/`Bool` constructors + `eqU64`/`+`), so the oracle covers them for free with no extra prim wiring.

---

## 5. The E2 surface

`Std.String` gains: three externs (`indexOfFromRaw`, `hash`, `editDistance`) and five dogfooded functions (`notFound`, `indexOfFrom`, `indexOf`, `contains`, `count`, plus the helper `countFrom`). No `Std.Base` change. The E1 `length`/`index` name-collision caveat with `Std.Array` (spec E1 §10) is unchanged — E2 adds no colliding names.

---

## 6. Integration / touch-points

1. `runtime/vendor/stringzilla/{stringzilla.h,LICENSE}` (new, vendored, version-pinned).
2. `runtime/wok_str_ops.c` (new TU; thin raw-buffer wrappers + fixed-seed hash).
3. `wok.cabal` (add the TU to `c-sources`, `runtime/vendor` to `include-dirs`).
4. `src/Wok/Runtime/StringZilla.hs` (new; pure FFI wrappers).
5. `src/Wok/IR/PrimNames.hs` (`indexOfFromRawName`, `hashName`, `editDistanceName`, exported).
6. `src/Wok/Interp/Prim.hs` `stringPrims` (reference: independent `breakSubstring`/Levenshtein; `hash` via `szHash`).
7. `src/Wok/Interp/RC/Prim.hs` `rcStringPrims` (RC: `szFind`/`szHash`/`szEditDistance` over `stringBytes`).
8. `prelude/Std/String.wok` (externs + dogfooded layer).
9. `test/rc-string`, `test/rc-string-oob`, and `rcStringPropertyTests` in `test/Spec.hs` (extend), plus a new golden hash corpus.

No change to `Escape`/`Reachable`/`Region`/`ReusePairing`/Perceus (E1 already made `String` boxed/counted; E2 adds no node and no boxedness change).

---

## 7. The differential oracle

Reuses the existing harness; new ops slot into the three-way comparison (RC AbstractHeap vs RC CHeap vs reference) over output + `allocs`/`frees`/`peak`/`peak_bytes`.

- **`indexOf*`/`contains`/`count`/`editDistance` — output parity = real cross-validation.** RC runs StringZilla; the reference runs an independent pure-Haskell implementation; a mismatch means a genuine bug in one side. Memory parity holds trivially (`indexOfFromRaw`/`editDistance` allocate 0 wok cells; `Some` allocates one 1-slot `Option` cell symmetrically on both RC backends, `None` is the nullary immediate).
- **`hash` — agreement by construction + golden corpus + properties.** All three backends call the same fixed-seed `sz_hash`, so they agree by construction; the *correctness* check is (a) QuickCheck properties (`s == t  ==>  hash s == hash t`; sanity on distribution / no trivial constant), and (b) a **golden corpus** `test/golden/string-hash.expected` mapping a fixed set of strings (ASCII, multi-byte, empty, long) to their `U64` hashes. The golden corpus simultaneously (i) verifies cross-backend identity, (ii) pins the value so an accidental seed/algorithm/version change is caught, and (iii) would catch any kernel non-invariance on the build machine. Regenerating the golden corpus on a deliberate StringZilla version bump is expected and documented.
- **StringZilla scratch allocation is intentionally invisible.** `sz_edit_distance` allocates its DP buffer via libc `malloc`, not `wok_alloc`, so it never reaches the `WokHeap` counters (`wok_rc.c` `allocs`/`peak_bytes`) or their Haskell mirror. The oracle's alloc/peak assertions remain valid because they count wok-owned cells only. Documented so it reads as intentional, not a leak.
- **Physical invariant:** the R1 self-policing `peak_physical_bytes <= K·peak_logical + C·arena` assertion (sanitizer build) is unaffected (no new wok allocation paths).

---

## 8. Testing strategy

- **Oracle corpus** (`test/rc-string/`): programs exercising each op on ASCII and multi-byte text — `indexOf`/`indexOfFrom` (present/absent/at-boundary/from-offset), `contains`, `count` (zero/one/many/adjacent/overlapping-but-counted-non-overlapping/empty-needle), `editDistance` (equal/insert/delete/substitute/multi-byte), `hash` (rendered) — each run through all three backends.
- **QuickCheck properties:**
  - `indexOf`: if `Some i = indexOf s n`, then `n` occurs at byte `i` (sub-bytes equal) and at no earlier offset; `indexOf s n == None` iff `n` is not a byte-substring of `s`; agrees with `Data.ByteString.breakSubstring`.
  - `contains s n == (indexOf s n /= None)`; `contains s s == True`; `contains s "" == True`.
  - `count`: equals the number of non-overlapping occurrences from a reference; `count s n == 0` iff `not (contains s n)` (for non-empty `n`); `count s "" == 0`.
  - `editDistance`: identity (`editDistance s s == 0`), symmetry (`editDistance a b == editDistance b a`), triangle inequality, and equality with a pure reference byte Levenshtein; bounded by `max (byteLength a) (byteLength b)`.
  - `hash`: `s == t ==> hash s == hash t`; matches the golden corpus; determinism across repeated calls.
- **Backends:** every property driven on AbstractHeap and CHeap (via the existing `onBothBackends`) and compared to the reference, exactly as E1.
- **Sanitizers:** ASan/LSan clean (`scripts/asan-runtime.sh`), including the physical invariant. (StringZilla's own allocations are libc and ASan-visible; confirm no leak in `editDistance`.)

---

## 9. Codegen transfer

The durable artifacts are backend-agnostic: the vendored StringZilla and `wok_str_ops.c` live in the shared C runtime; the dogfooded wok layer is ordinary source. At codegen the interpreter's "extract a `ByteString` then call StringZilla" path is replaced by a **zero-copy** call on the C cell's `wok_string_data` pointer directly — where the SIMD speed actually cashes in. The dogfooded `indexOf`/`contains`/`count` compile like any other wok functions; `hash`/`editDistance` lower to the same FFI symbols. Nothing in E2 needs redoing for codegen.

---

## 10. Risks & known limitations

- **`hash` has no consumer yet.** wok lacks a `HashMap`/`HashSet`; `hash` is a primitive ahead of its consumer (accepted, §3.7). Its quality matters only once a map relies on it; `sz_hash` is unseeded/reproducible-first, and seed randomization for DoS resistance would be revisited when that map lands.
- **`editDistance` is byte-level, not codepoint-level.** Correct and declared; differs from codepoint distance for multi-byte text. Codepoint-level requires the deferred iteration layer.
- **SIMD speed is not realized in the interpreter.** Per-element interpreter dispatch dominates; StringZilla's win is a codegen-era benefit banked early (§9). E2's immediate value is correctness, quality, and the FFI/oracle scaffolding.
- **Reference uses independent Haskell for `indexOf`/`editDistance`.** A bug in that reference could surface as an oracle mismatch that is the reference's fault, not StringZilla's; properties disambiguate. This is the intended cost of independent cross-validation (more valuable than a same-FFI no-op check).
- **Vendored-header version drift.** A StringZilla version bump can change hash output (golden corpus) and must be a deliberate, documented step (pin the version; regenerate goldens).
- **`maxU64` sentinel for not-found.** Safe because strings cannot approach `2^64-1` bytes (E1 cell-size overflow guard); documented as the convention bridging the `… -> U64` FFI to the wok `Option`.
- **Empty-needle `count == 0`** is a deliberate simplification (avoids the degenerate infinite loop) rather than the `byteLength + 1` some libraries use.
- **Theoretical-unreachable, documented not guarded** (matching E1's `2^63` Int-overflow / `uint16` tag precedents; CLAUDE.md says do not add handling for impossible inputs): (a) the reference `indexOfFromRaw` does a bare `fromIntegral` on the `from` offset while the RC side clamps via `asStringIndex`, so a `from > 2^63-1` (an 8-exabyte offset) would diverge — unreachable. (b) `sz_edit_distance` returns `SZ_SIZE_MAX` if its internal libc scratch `malloc` fails, which `wok_sz_edit_distance` would surface as a giant "distance"; a tiny-buffer malloc failure is effectively can't-happen, and if it ever did the independent reference (`refLevenshtein`) would make the oracle diverge rather than silently agree.
- **`hash` correctness is anchored by a golden pin, not the differential.** Because `sz_hash` has no independent pure-Haskell equivalent, the three-way differential and P12 are `szHash`-vs-`szHash` tautologies; the concrete distinct-value golden (P13a–e, `test/Spec.hs`) is the real anchor — it rejects a degenerate/constant hash and catches a StringZilla version/algorithm change. Regenerate P13 values only on a deliberate bump.
