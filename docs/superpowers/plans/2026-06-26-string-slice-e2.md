# String Slice E2 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers-extended-cc:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add StringZilla-backed substring search, hashing, and byte-level edit distance to wok's `String`, plus a dogfooded wok layer (`indexOf`/`contains`/`count`) over the one search primitive, validated by the existing three-way differential oracle.

**Architecture:** StringZilla v3.12.5 is vendored as a single header and called through three thin C wrappers (`runtime/wok_str_ops.c`) over raw byte ranges; a small Haskell module (`Wok.Runtime.StringZilla`) exposes pure FFI wrappers used by both interpreter backends. The three FFI primitives each return `U64` (no ADT construction in C); the `Option`/`Bool` derivations are ordinary wok functions. The reference backend cross-validates `indexOf`/`editDistance` with independent pure-Haskell implementations; `hash` is computed by the same `sz_hash` everywhere and pinned by a golden corpus.

**Tech Stack:** C17 + StringZilla v3.12.5 (vendored, Apache-2.0); GHC/Haskell FFI; cabal; wok prelude; tasty/Hspec/QuickCheck.

**Spec:** `docs/superpowers/specs/2026-06-26-string-slice-e2-design.md`

**User decisions (already made):**
- "run it autonomously" — execute via subagent-driven-development this session, model-tier routed.
- "string ops we definitely should use stringzilla, but some of the really basic one, I prefer it dogfood" — FFI for the SIMD-irreducible ops; `indexOf`/`contains`/`count` dogfooded in wok over `indexOfFromRaw`.
- "I can include hash now" — `hash` is in E2, via StringZilla `sz_hash`.
- Iteration (`chars`/`fromChars`/`foldChars`), TRMC, chunked/RRB lists, ordering comparison `<` — all deferred (recorded in spec §1 / `docs/trmc-and-list-representation.html`).

**Already done (by the coordinator, de-risking the network dependency):** StringZilla v3.12.5 is vendored at `runtime/vendor/stringzilla/{stringzilla.h,LICENSE,PROVENANCE.txt}`. Tasks below assume these files exist.

---

### Task 1: FFI bridge — C wrappers, cabal wiring, Haskell module

**Goal:** Compile-and-link three StringZilla wrappers callable from Haskell as pure functions.

**Files:**
- Create: `runtime/wok_str_ops.c`
- Create: `src/Wok/Runtime/StringZilla.hs`
- Modify: `wok.cabal` (the library stanza around lines 116-118, and the module list)

**Acceptance Criteria:**
- [ ] `cabal build` succeeds (C TU compiles against the vendored header; Haskell module links the three C symbols).
- [ ] `Wok.Runtime.StringZilla` exports `szFind`, `szHash`, `szEditDistance`.

**Verify:** `cabal build 2>&1 | tail -5` → ends with successful build (no errors).

**Steps:**

- [ ] **Step 1: Create `runtime/wok_str_ops.c`** (StringZilla symbols verified against the vendored header: `sz_cptr_t = char const*`; `sz_find` returns a pointer or NULL; `sz_edit_distance(a,la,b,lb,bound,alloc)` with `bound=0` meaning unbounded and `alloc=NULL` meaning default libc allocator; `sz_hash(text,len)` unseeded):

```c
/* StringZilla wrappers for wok String Slice E2. Raw-byte-range entry points so the
   same functions serve a C cell, a Haskell ByteString, and an encodeUtf8 buffer.
   Compiled as the single TU that instantiates StringZilla's dynamic-dispatch impls. */
#define SZ_DYNAMIC_DISPATCH 1
#include "stringzilla/stringzilla.h"
#include <stdint.h>
#include <stddef.h>

#define WOK_SZ_NOT_FOUND UINT64_MAX

/* First occurrence of needle in hay at or after byte offset `from`.
   Returns the absolute byte position, or WOK_SZ_NOT_FOUND. */
uint64_t wok_sz_find(const char *hay, size_t hay_len,
                     const char *needle, size_t needle_len, size_t from) {
    if (from > hay_len) return WOK_SZ_NOT_FOUND;
    if (needle_len == 0) return (uint64_t)from;                 /* empty needle at cursor */
    if (needle_len > hay_len - from) return WOK_SZ_NOT_FOUND;
    sz_cptr_t base = (sz_cptr_t)(hay + from);
    sz_cptr_t m = sz_find(base, (sz_size_t)(hay_len - from),
                          (sz_cptr_t)needle, (sz_size_t)needle_len);
    if (m == NULL) return WOK_SZ_NOT_FOUND;
    return (uint64_t)from + (uint64_t)(m - base);
}

uint64_t wok_sz_hash(const char *data, size_t len) {
    return (uint64_t)sz_hash((sz_cptr_t)data, (sz_size_t)len);
}

/* Byte-level unit-cost Levenshtein. bound=0 -> unbounded; NULL alloc -> default libc
   scratch (invisible to wok's wok_rc counters, by design). */
uint64_t wok_sz_edit_distance(const char *a, size_t a_len,
                              const char *b, size_t b_len) {
    return (uint64_t)sz_edit_distance((sz_cptr_t)a, (sz_size_t)a_len,
                                      (sz_cptr_t)b, (sz_size_t)b_len,
                                      (sz_size_t)0, NULL);
}
```

- [ ] **Step 2: Wire the C TU + include dir into `wok.cabal`.** In the library stanza (currently `c-sources: runtime/wok_rc.c`, `include-dirs: runtime`, around line 116):

```
    c-sources:        runtime/wok_rc.c
                      runtime/wok_str_ops.c
    include-dirs:     runtime
                      runtime/vendor
```

(Leave `cc-options` unchanged; they apply to both TUs. There is no `-Werror`, so any vendored-header warnings are non-fatal. If a specific warning is noisy, wrap the `#include "stringzilla/stringzilla.h"` in `#pragma GCC diagnostic push` / `ignored "-W..."` / `pop`.)

- [ ] **Step 3: Create `src/Wok/Runtime/StringZilla.hs`:**

```haskell
{-# LANGUAGE ForeignFunctionInterface #-}

-- | Pure Haskell wrappers over the StringZilla C entry points (`runtime/wok_str_ops.c`).
-- The C functions are pure byte->value computations that never touch the wok_rc heap,
-- so 'unsafeDupablePerformIO' over 'BSU.unsafeUseAsCStringLen' is sound and copy-free.
module Wok.Runtime.StringZilla
  ( szFind
  , szHash
  , szEditDistance
  ) where

import qualified Data.ByteString as BS
import qualified Data.ByteString.Unsafe as BSU
import Data.Word (Word64)
import Foreign.C.Types (CChar, CSize (..))
import Foreign.Ptr (Ptr)
import System.IO.Unsafe (unsafeDupablePerformIO)

foreign import ccall unsafe "wok_sz_find"
  c_wok_sz_find :: Ptr CChar -> CSize -> Ptr CChar -> CSize -> CSize -> IO Word64

foreign import ccall unsafe "wok_sz_hash"
  c_wok_sz_hash :: Ptr CChar -> CSize -> IO Word64

foreign import ccall unsafe "wok_sz_edit_distance"
  c_wok_sz_edit_distance :: Ptr CChar -> CSize -> Ptr CChar -> CSize -> IO Word64

-- | First occurrence of @needle@ in @hay@ at/after byte offset @from@;
--   absolute byte position, or 'maxBound' (== @WOK_SZ_NOT_FOUND@) if absent.
szFind :: BS.ByteString -> BS.ByteString -> Int -> Word64
szFind hay needle from = unsafeDupablePerformIO $
  BSU.unsafeUseAsCStringLen hay $ \(hp, hl) ->
    BSU.unsafeUseAsCStringLen needle $ \(np, nl) ->
      c_wok_sz_find hp (fromIntegral hl) np (fromIntegral nl) (fromIntegral from)

szHash :: BS.ByteString -> Word64
szHash s = unsafeDupablePerformIO $
  BSU.unsafeUseAsCStringLen s $ \(p, l) ->
    c_wok_sz_hash p (fromIntegral l)

szEditDistance :: BS.ByteString -> BS.ByteString -> Word64
szEditDistance a b = unsafeDupablePerformIO $
  BSU.unsafeUseAsCStringLen a $ \(ap, al) ->
    BSU.unsafeUseAsCStringLen b $ \(bp, bl) ->
      c_wok_sz_edit_distance ap (fromIntegral al) bp (fromIntegral bl)
```

- [ ] **Step 4: Add the module to `wok.cabal`** under the library `other-modules:` (or `exposed-modules:`) list — alongside the other `Wok.*` modules — as `Wok.Runtime.StringZilla`.

- [ ] **Step 5: Build.** Run `cabal build`. Expected: success. If the vendored header errors (not just warns), wrap its include per Step 2's pragma note and rebuild.

- [ ] **Step 6: Commit.**

```bash
git add runtime/wok_str_ops.c src/Wok/Runtime/StringZilla.hs wok.cabal runtime/vendor/stringzilla
git commit -m "feat(string): vendor StringZilla v3.12.5 + FFI bridge (E2 Task 1)"
```

```json:metadata
{"files": ["runtime/wok_str_ops.c", "src/Wok/Runtime/StringZilla.hs", "wok.cabal"], "verifyCommand": "cabal build", "acceptanceCriteria": ["cabal build succeeds", "Wok.Runtime.StringZilla exports szFind/szHash/szEditDistance"], "modelTier": "standard"}
```

---

### Task 2: Prim layer — PrimNames + reference + RC backends

**Goal:** Expose `indexOfFromRaw`, `hash`, `editDistance` as prims in both interpreter backends, with the reference backend cross-validating via independent pure-Haskell implementations.

**Files:**
- Modify: `src/Wok/IR/PrimNames.hs` (add three name constants + exports, under `stdStringModule`)
- Modify: `src/Wok/Interp/Prim.hs` (`stringPrims`: reference impls)
- Modify: `src/Wok/Interp/RC/Prim.hs` (`rcStringPrims`: FFI impls)

**Acceptance Criteria:**
- [ ] `cabal build` succeeds.
- [ ] Both prim tables contain `indexOfFromRaw` (arity 3), `hash` (arity 1), `editDistance` (arity 2), keyed under `stdStringModule`.
- [ ] Reference `indexOfFromRaw`/`editDistance` use pure Haskell (`Data.ByteString.breakSubstring`; two-row Levenshtein); reference `hash` and both RC impls use `Wok.Runtime.StringZilla`.
- [ ] RC impls allocate 0 wok cells (return a `U64` literal); follow the E1 args-consuming convention (drop input strings).

**Verify:** `cabal build` → success. (Behavior is exercised end-to-end in Task 4.)

**Steps:**

- [ ] **Step 1: Add names to `src/Wok/IR/PrimNames.hs`** (follow the existing `stringIndexName`/`stringAppendName` pattern; export each in the module header list):

```haskell
-- | @indexOfFromRaw hay needle from@: first byte offset of needle in hay at/after
-- `from`, or the maxBound sentinel if absent. (StringZilla find; the search primitive.)
stringIndexOfFromRawName :: Text
stringIndexOfFromRawName = Tx.pack "indexOfFromRaw"

-- | @hash s@: StringZilla sz_hash of the UTF-8 bytes (unseeded, deterministic).
stringHashName :: Text
stringHashName = Tx.pack "hash"

-- | @editDistance a b@: byte-level unit-cost Levenshtein (StringZilla sz_edit_distance).
stringEditDistanceName :: Text
stringEditDistanceName = Tx.pack "editDistance"
```

- [ ] **Step 2: Reference impls in `src/Wok/Interp/Prim.hs` `stringPrims`.** Read the existing `stringPrims` (the E1 `byteAt`/`byteLength`/`eqString` entries) to match `mkPrim`/result/`VLit (LStr _)`/`VLit (LInt _)` conventions exactly, then add three prims keyed on the PrimNames constants. Use these pure helpers (add them near `stringPrims`):

```haskell
-- byte-level "find from offset"; absolute position or maxBound (== WOK_SZ_NOT_FOUND).
refFindFrom :: BS.ByteString -> BS.ByteString -> Int -> Word64
refFindFrom hay needle from
  | from > BS.length hay = maxBound
  | BS.null needle       = fromIntegral from
  | BS.null post         = maxBound
  | otherwise            = fromIntegral (from + BS.length pre)
  where (pre, post) = BS.breakSubstring needle (BS.drop from hay)

-- byte-level unit-cost Levenshtein (two-row DP). d[i][j] = dist(a[0..i), b[0..j)).
refLevenshtein :: BS.ByteString -> BS.ByteString -> Word64
refLevenshtein sa sb = fromIntegral (last (foldl' nextRow [0 .. length bb] (BS.unpack sa)))
  where
    bb = BS.unpack sb
    nextRow prev ca = head prev + 1 : build (head prev + 1) (zip3 prev (tail prev) bb)
      where
        build _ [] = []
        build left ((diag, up, cb) : rest) =
          let cost = if ca == cb then 0 else 1
              cell = min (up + 1) (min (left + 1) (diag + cost)) :: Int
          in cell : build cell rest
```

The three reference prims (the `string`-domain names): `indexOfFromRaw s n from` -> `VLit (LInt (toInteger (refFindFrom (encodeUtf8 s) (encodeUtf8 n) (fromIntegral from))))`; `hash s` -> `VLit (LInt (toInteger (szHash (encodeUtf8 s))))`; `editDistance a b` -> `VLit (LInt (toInteger (refLevenshtein (encodeUtf8 a) (encodeUtf8 b))))`. Imports needed: `Data.List (foldl')`, `Data.Word (Word64)`, `Wok.Runtime.StringZilla (szHash)`, the existing `BS`/`encodeUtf8`.

- [ ] **Step 3: RC impls in `src/Wok/Interp/RC/Prim.hs` `rcStringPrims`.** Read the existing E1 RC string prims (`stringByteAt`/`stringByteLength`, the `stringBytes`/`asStringIndex` helpers, the args-consuming `dropAddr` convention) to match exactly, then add three prims keyed on the PrimNames constants, each calling `Wok.Runtime.StringZilla` on the bytes from `stringBytes`:
  - `indexOfFromRaw hay needle from`: `bh <- stringBytes hay s; bn <- stringBytes needle s; i <- asStringIndex from; pure (PRDone (RVLit (LInt (toInteger (szFind bh bn i)))), s')` after dropping the two string inputs (mirror how `stringByteAt` drops its input).
  - `hash str`: `b <- stringBytes str s; ... PRDone (RVLit (LInt (toInteger (szHash b))))`, drop input.
  - `editDistance a b`: `ba <- stringBytes a s; bb <- stringBytes b s; ... PRDone (RVLit (LInt (toInteger (szEditDistance ba bb))))`, drop both inputs.

  All three allocate 0 wok cells. Import `Wok.Runtime.StringZilla (szFind, szHash, szEditDistance)`.

- [ ] **Step 4: Build.** `cabal build`. Expected: success. Fix type mismatches (e.g. `Word64`/`Integer` conversions) until clean.

- [ ] **Step 5: Commit.**

```bash
git add src/Wok/IR/PrimNames.hs src/Wok/Interp/Prim.hs src/Wok/Interp/RC/Prim.hs
git commit -m "feat(string): indexOfFromRaw/hash/editDistance prims in both backends (E2 Task 2)"
```

```json:metadata
{"files": ["src/Wok/IR/PrimNames.hs", "src/Wok/Interp/Prim.hs", "src/Wok/Interp/RC/Prim.hs"], "verifyCommand": "cabal build", "acceptanceCriteria": ["both prim tables expose indexOfFromRaw/hash/editDistance", "reference uses pure Haskell for find/editDistance, FFI for hash", "RC uses FFI over stringBytes, 0 wok allocs"], "modelTier": "standard"}
```

---

### Task 3: Prelude — externs + dogfooded search layer

**Goal:** Expose the three primitives and the dogfooded `indexOf`/`indexOfFrom`/`contains`/`count` in `Std.String`.

**Files:**
- Modify: `prelude/Std/String.wok`

**Acceptance Criteria:**
- [ ] The three externs and the dogfooded functions are present and well-typed.
- [ ] A wok program that imports `Std.String` and uses `contains`/`count`/`indexOf`/`hash`/`editDistance` compiles and runs on `--run`.

**Verify:** `cabal run wok -- --run test/rc-string/<a new smoke file>.wok` → prints the expected values (see Task 4 corpus). For this task, a minimal inline smoke: a program that prints `count "banana" "an"` etc.

**Steps:**

- [ ] **Step 1: Append to `prelude/Std/String.wok`** (exact code; `case x of True/False` for branching — wok has no `if`; top-level recursive helper for the `count` loop; no `where`):

```
-- StringZilla FFI primitives (Slice E2)
extern indexOfFromRaw : String -> String -> U64 -> U64   -- byte pos, or `notFound` if absent
extern hash           : String -> U64                    -- sz_hash of the UTF-8 bytes (deterministic)
extern editDistance   : String -> String -> U64          -- byte-level unit-cost Levenshtein

-- "not found" sentinel returned by indexOfFromRaw (== C WOK_SZ_NOT_FOUND == UINT64_MAX).
notFound : U64
notFound = 18446744073709551615

-- find from a byte offset, as an Option
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

-- count of NON-OVERLAPPING occurrences. Empty needle -> 0 (avoids the degenerate loop).
count : String -> String -> U64
count s n = case eqU64 (byteLength n) 0 of
  True  -> 0
  False -> countFrom s n 0 0

countFrom : String -> String -> U64 -> U64 -> U64
countFrom s n from acc = case indexOfFrom s n from of
  None   -> acc
  Some i -> countFrom s n (i + byteLength n) (acc + 1)
```

If the 20-digit `notFound` literal is rejected by the lexer, replace `notFound`'s body with an `extern maxU64 : U64` (add a trivial `maxU64` prim returning `maxBound` to both prim tables) — but try the literal first.

- [ ] **Step 2: Smoke test.** Create `test/rc-string/10-search-smoke.wok` whose `main` returns / prints a tuple exercising `contains "banana" "an"`, `count "banana" "an"` (expect 2), `indexOf "banana" "na"` (expect `Some 2`), `editDistance "kitten" "sitting"` (expect 3), and `hash "hello"` (rendered). Run `cabal run wok -- --run test/rc-string/10-search-smoke.wok` and confirm it executes without error and the search/count/distance values match.

- [ ] **Step 3: Commit.**

```bash
git add prelude/Std/String.wok test/rc-string/10-search-smoke.wok
git commit -m "feat(string): Std.String externs + dogfooded indexOf/contains/count (E2 Task 3)"
```

```json:metadata
{"files": ["prelude/Std/String.wok", "test/rc-string/10-search-smoke.wok"], "verifyCommand": "cabal run wok -- --run test/rc-string/10-search-smoke.wok", "acceptanceCriteria": ["externs + dogfooded functions present and typed", "smoke program runs; count/indexOf/editDistance values correct"], "modelTier": "standard"}
```

---

### Task 4: Oracle corpus + QuickCheck properties + golden hash

**Goal:** Validate every new op across all three backends (differential) and against independent references (properties), and pin `hash` with a golden corpus.

**Files:**
- Create: `test/rc-string/11-*.wok` … (corpus programs per op)
- Modify: `test/Spec.hs` (extend `rcStringPropertyTests`; wire the new corpus is automatic via `findByExtension "test/rc-string"`)
- Create: `test/golden/string-hash.expected` (golden `(string -> hash)` lines)

**Acceptance Criteria:**
- [ ] New corpus programs run green through the three-way differential (AbstractHeap vs CHeap vs reference) and the stats oracle.
- [ ] QuickCheck properties pass on both RC backends and agree with the reference.
- [ ] Golden hash corpus matches on the build machine; documented that a StringZilla version bump regenerates it.

**Verify:** `cabal test` → all green (string property group + rc differential/stats include the new files).

**Steps:**

- [ ] **Step 1: Corpus.** Add `test/rc-string/` programs exercising: `indexOf`/`indexOfFrom` (present/absent/at-boundary/from-offset, ASCII + multi-byte), `contains`, `count` (zero/one/many/adjacent/empty-needle), `editDistance` (equal/insert/delete/substitute/multi-byte), `hash` (rendered). These auto-wire via `findByExtension [".wok"] "test/rc-string"` (`test/Spec.hs:147`) into the `rc differential` + `rc stats` groups. Run `cabal test` and confirm three-way parity.

- [ ] **Step 2: Properties.** Extend `rcStringPropertyTests` (`test/Spec.hs:19245`) using the existing `onBothBackends` driver + a `Data.Text`/`Data.ByteString` reference:
  - `indexOf`: when `Some i`, `n` is a byte-substring of `s` at `i` and at no earlier offset; `None` iff not a substring; agrees with `BS.breakSubstring`.
  - `contains s n == (indexOf s n /= None)`; `contains s s`; `contains s ""`.
  - `count`: equals a reference non-overlapping count; `count s "" == 0`.
  - `editDistance`: `editDistance s s == 0`; symmetry; triangle inequality; equals `refLevenshtein`; `<= max (byteLength a) (byteLength b)`.
  - `hash`: `s == t ==> hash s == hash t`; determinism across calls.

- [ ] **Step 3: Golden hash corpus.** Create `test/golden/string-hash.expected` with a fixed set (ASCII, multi-byte "héllo", empty, a long string) -> their `hash` values (generate by running `hash` once, paste the values). Add a test that recomputes and compares. Add a comment: regenerate on a deliberate StringZilla version bump.

- [ ] **Step 4: Full suite.** Run `cabal test`. Expected: all green. Run sanitizers if available: `scripts/asan-runtime.sh` (confirm no leak from `sz_edit_distance` scratch).

- [ ] **Step 5: Commit.**

```bash
git add test/rc-string test/golden/string-hash.expected test/Spec.hs
git commit -m "test(string): E2 oracle corpus + QuickCheck properties + golden hash (E2 Task 4)"
```

```json:metadata
{"files": ["test/rc-string", "test/Spec.hs", "test/golden/string-hash.expected"], "verifyCommand": "cabal test", "acceptanceCriteria": ["three-way differential green on new corpus", "QuickCheck properties pass on both RC backends + agree with reference", "golden hash corpus matches"], "modelTier": "standard"}
```

---

## Self-Review

**Spec coverage:** §4.1 vendoring + wrapper TU → Task 1; §4.2 FFI module → Task 1; §4.3 prim layer (reference independent + RC FFI) → Task 2; §4.4 dogfooded wok → Task 3; §5 surface → Task 3; §7 oracle + §8 testing (incl. golden hash, scratch-malloc invisibility check) → Task 4. PrimNames (§6.5) → Task 2. cabal (§6.3) → Task 1. All covered.

**Placeholder scan:** C wrapper, FFI module, `refFindFrom`, `refLevenshtein`, and the entire prelude layer are given as complete code. The prim-table entries (Task 2 Steps 2-3) reference "follow the existing E1 string-prim pattern in the same file" for boilerplate while supplying the complete novel logic (helpers + FFI calls) — appropriate, not a placeholder, because the pattern is present in the file being edited.

**Type consistency:** `notFound`/`WOK_SZ_NOT_FOUND`/`maxBound :: Word64` align across C, Haskell, and wok. `indexOfFromRaw : String -> String -> U64 -> U64` matches `szFind :: ByteString -> ByteString -> Int -> Word64` and `wok_sz_find(...)`. `editDistance`/`hash` return `U64` end to end.

**Deferred decision:** the `notFound` literal-vs-`maxU64`-extern fallback (Task 3 Step 1) is resolved at implementation time by trying the literal first — no user input needed.
