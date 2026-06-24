# Array Slice B — `Array a` on a real C `WokArray` cell — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers-extended-cc:subagent-driven-development (recommended) or superpowers-extended-cc:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give the existing polymorphic `Array a` a real C allocator cell (`WokArray`), replacing its interpreter-resident representation on the CHeap backend, with byte-size-class placement and `peak_bytes` as a bit-for-bit differential-oracle invariant.

**Architecture:** A new C cell (16-byte header `{rc, tag=WOK_ARRAY_TAG, elemkind, len}` + 8-byte slots reusing the existing `NCon` inline-or-pointer encoding) allocated through the existing `WokHeap*` arena (byte-size class = `bytes/8 - 1`, shared free-list with same-size `NCon`s, large → `malloc`). The CHeap backend routes `NArray` allocation to this cell; the AbstractHeap keeps `NArray` only as the differential-oracle reference. `peak_bytes` is elevated to a shared invariant via byte tracking on the abstract `Stats`.

**Tech Stack:** C17 (`runtime/wok_rc.{c,h}`), Haskell GHC (RC interpreter in `src/Wok/Interp/RC/`), tasty/Hspec/QuickCheck (`test/Spec.hs`), ASan/UBSan (`scripts/asan-runtime.sh`).

**Spec:** `docs/superpowers/specs/2026-06-24-array-slice-b-c-cell-design.md` — the authoritative design. Every task references its sections. Read the spec before any task.

**User decisions (already made):**
- "replace the slice A because it lives in interpreter … through C flat cell … get a real allocator layout" — `Array a` becomes a real C cell.
- "keep it [the abstract NArray] and do spec" — the abstract `NArray` is retained ONLY as the differential-oracle reference.
- "use Array because it is the most simplest and it is not resizable" → later superseded by the findings: ONE polymorphic `Array a`, **no `Array→Vector` rename, no new type, no allowlist** (the flat-vs-boxed split dissolves under wok's current types).
- "I can defer it" — length-indexed `ArrayOf n a` is deferred (the runtime `len` here founds it).
- "keep it [the differential oracle] (bit-for-bit incl peak_bytes)" — `peak_bytes` elevated to an oracle invariant.
- "run it autonomously" — execute via subagent-driven-development in this session, routed by model tier.

**Build/test commands:**
- Build: `cabal build all`
- Haskell tests: `cabal test wok-tests` (tasty; filter with `--test-options='-p "<pattern>"'`)
- C standalone + sanitizers: `bash scripts/asan-runtime.sh` (arena + `WOK_RC_MALLOC` + poison builds)
- C microbench (optional): `bash scripts/asan-runtime.sh bench`

---

## File structure

- `runtime/wok_rc.h` — additive `WokArray` ABI (`WOK_ARRAY_TAG`, `wok_array_alloc/len/elemkind/slot_get/slot_set`).
- `runtime/wok_rc.c` — the `WokArray` cell, byte-size-class routing, `wok_free` tag-first dispatch, `peak_bytes` for arrays.
- `runtime/test/wok_rc_test.c` — C standalone unit tests for the array cell (extended).
- `src/Wok/Interp/RC/Heap.hs` — FFI imports for the new ABI.
- `src/Wok/Interp/RC/Value.hs` — CHeap `NArray` routing, `internTag` reservation, array `CAddr` cascade/deref/decode/render, `Stats` byte tracking + `wouldBeCBytes` + byte-aware `recordAlloc`/`recordFree`.
- `src/Wok/Interp/RC/Prim.hs` — the seven array prims read/write C-cell slots on the CHeap backend.
- `test/Spec.hs` — `peak_bytes` oracle assertion; array corpus run on the C backend incl. boxed-element arrays; store-algebra C-cell assertions.
- `docs/` + memory — docs and notes.

---

### Task 1: C `WokArray` cell + ABI + standalone sanitizer tests

**Goal:** A real C array cell with byte-size-class placement and a `wok_array_*` ABI, validated under ASan/UBSan, with the Haskell side still building unchanged.

**Files:**
- Modify: `runtime/wok_rc.h` (additive ABI)
- Modify: `runtime/wok_rc.c` (the cell, routing, free dispatch, byte accounting)
- Modify: `runtime/test/wok_rc_test.c` (C unit tests)

**Acceptance Criteria:**
- [ ] `wok_array_alloc(h, len, elemkind)` returns a cell with `rc=1`, `tag=WOK_ARRAY_TAG`, `len` at offset 8, `elemkind` in the arity byte; slots at offset 16; byte size `16 + 8*len`.
- [ ] Placement by byte size: `class = bytes/8 - 1 = len + 1`; `len <= 62` (≤512 B) uses the arena free-list, `len >= 63` uses `malloc`. A freed `len=L` array and a freed `arity=(L+1)` `NCon` reuse the same `freelist[L+1]` slot (pointer identity).
- [ ] `wok_free` reads `tag` first: `WOK_ARRAY_TAG ⇒ bytes = 16 + 8*len`, else `8 + 8*arity`. No misroute.
- [ ] `cur_bytes`/`peak_bytes` updated by `16 + 8*len` on array alloc/free.
- [ ] `wok_array_len`/`wok_array_elemkind`/`wok_array_slot_get`/`wok_array_slot_set` round-trip; slot accessors use offset 16 (NOT `wok_slot_get/set`, which assert on `arity` and read offset 8).
- [ ] `bash scripts/asan-runtime.sh` passes for arena, `WOK_RC_MALLOC`, and poison builds (no leak, no UB, no overflow).

**Verify:** `bash scripts/asan-runtime.sh` → all three builds print their `== label ==` and exit 0.

**Steps:**

- [ ] **Step 1: Add the ABI to `runtime/wok_rc.h`** (after the existing `wok_slot_*` declarations):

```c
#define WOK_ARRAY_TAG 0xFFFFu   /* reserved tag marking an array cell (also reserved Haskell-side) */

WokObj*  wok_array_alloc(WokHeap* h, uint64_t len, uint8_t elemkind); /* rc=1, tag=ARRAY, slots undef */
WOK_PURE uint64_t wok_array_len(const WokObj* p);
WOK_PURE uint32_t wok_array_elemkind(const WokObj* p);
void     wok_array_slot_set(WokObj* p, uint64_t i, uint64_t word);
WOK_PURE uint64_t wok_array_slot_get(const WokObj* p, uint64_t i);
```

- [ ] **Step 2: Write failing C tests in `runtime/test/wok_rc_test.c`** (add a function, call it from `main`). Test: alloc len=3 elemkind=0, check `wok_array_len==3`, `wok_tag==WOK_ARRAY_TAG`, slot round-trip; free it then alloc an `NCon` of arity 4 and assert the SAME pointer is returned (shared `freelist[4]`); alloc len=100 (>62) and confirm it round-trips and frees (malloc path); check `wok_stat_peak_bytes` reflects `16+8*len`.

```c
static void test_array_cell(void) {
    WokHeap* h = wok_heap_new();
    WokObj* a = wok_array_alloc(h, 3, 0);
    assert(wok_tag(a) == WOK_ARRAY_TAG);
    assert(wok_array_len(a) == 3);
    assert(wok_array_elemkind(a) == 0);
    wok_array_slot_set(a, 0, 111); wok_array_slot_set(a, 2, 333);
    assert(wok_array_slot_get(a, 0) == 111 && wok_array_slot_get(a, 2) == 333);
    /* byte size 16 + 8*3 = 40 -> class 4, shared with NCon arity 4 */
    wok_dec(a); wok_free(h, a);
    WokObj* c = wok_alloc(h, 7, 4);          /* arity 4 -> freelist[4] -> same block */
    assert((void*)c == (void*)a);            /* exact-fit recycle across shapes */
    wok_dec(c); wok_free(h, c);
    /* large path: len 100 -> class 101 >= 64 -> malloc */
    WokObj* big = wok_array_alloc(h, 100, 0);
    assert(wok_array_len(big) == 100);
    wok_dec(big); wok_free(h, big);
    wok_heap_free(h);
}
```

- [ ] **Step 3: Run the C tests, expect failure** (undefined `wok_array_*`). Run: `bash scripts/asan-runtime.sh` → expect compile/link error.

- [ ] **Step 4: Implement in `runtime/wok_rc.c`.** Add a `wok_cell_bytes`-style helper and the array functions. Key points: the array header is 16 bytes (the 8-byte `WokObj` prefix + a `uint64 len` at offset 8); slots start at offset 16; `elemkind` is stored in the `arity` byte (`p->arity`). Reuse the arena bump/free-list path keyed by `class = bytes/8 - 1`. Implement under BOTH `#ifdef WOK_RC_MALLOC` and the arena branch (mirror the existing `wok_alloc` structure). Generalize the alloc/free class computation: add a static `static size_t arr_bytes(uint64_t len){ return 16u + 8u*(size_t)len; }` and a `static uint32_t class_of_bytes(size_t b){ return (uint32_t)(b/8u) - 1u; }`. In `wok_free`, branch on `tag == WOK_ARRAY_TAG` to compute bytes from `len`. Update `cur_bytes`/`peak_bytes` with `arr_bytes(len)`. The array slot accessors compute `((uint64_t*)((char*)p + 16))[i]`. Follow spec §3 exactly.

- [ ] **Step 5: Run the C tests, expect pass.** Run: `bash scripts/asan-runtime.sh` → all three builds exit 0. Confirm `cabal build all` still succeeds (Haskell untouched).

- [ ] **Step 6: Commit.**

```bash
git add runtime/wok_rc.h runtime/wok_rc.c runtime/test/wok_rc_test.c
git commit -m "feat(array): C WokArray cell + byte-size-class placement (Slice B task 1)"
```

```json:metadata
{"files": ["runtime/wok_rc.h", "runtime/wok_rc.c", "runtime/test/wok_rc_test.c"], "verifyCommand": "bash scripts/asan-runtime.sh", "acceptanceCriteria": ["wok_array_alloc/len/elemkind/slot round-trip", "class = bytes/8-1, shared freelist with NCon, len>=63 malloc", "wok_free tag-first dispatch", "peak_bytes by 16+8*len", "ASan/UBSan clean (arena, malloc, poison)"], "modelTier": "standard"}
```

---

### Task 2: FFI bindings for the `wok_array_*` ABI

**Goal:** Haskell can call the new C array ABI.

**Files:**
- Modify: `src/Wok/Interp/RC/Heap.hs` (foreign imports, alongside the existing `wokAlloc`/`wokSlotGet`/… imports)

**Acceptance Criteria:**
- [ ] Foreign imports exist and are exported: `wokArrayAlloc :: Ptr WokHeap -> Word64 -> Word8 -> IO (Ptr WokObj)`, `wokArrayLen :: Ptr WokObj -> IO Word64`, `wokArrayElemKind :: Ptr WokObj -> IO Word32`, `wokArraySlotGet :: Ptr WokObj -> Word64 -> IO Word64`, `wokArraySlotSet :: Ptr WokObj -> Word64 -> Word64 -> IO ()`.
- [ ] `cabal build all` succeeds.

**Verify:** `cabal build all` → success.

**Steps:**

- [ ] **Step 1: Add the foreign imports** to `src/Wok/Interp/RC/Heap.hs`, mirroring the existing `foreign import ccall unsafe "wok_alloc" …` style, and add the names to the module export list:

```haskell
foreign import ccall unsafe "wok_array_alloc"     wokArrayAlloc    :: Ptr WokHeap -> Word64 -> Word8 -> IO (Ptr WokObj)
foreign import ccall unsafe "wok_array_len"        wokArrayLen      :: Ptr WokObj -> IO Word64
foreign import ccall unsafe "wok_array_elemkind"   wokArrayElemKind :: Ptr WokObj -> IO Word32
foreign import ccall unsafe "wok_array_slot_get"   wokArraySlotGet  :: Ptr WokObj -> Word64 -> IO Word64
foreign import ccall unsafe "wok_array_slot_set"   wokArraySlotSet  :: Ptr WokObj -> Word64 -> Word64 -> IO ()
```

- [ ] **Step 2: Build, expect success.** Run: `cabal build all`.

- [ ] **Step 3: Commit.**

```bash
git add src/Wok/Interp/RC/Heap.hs
git commit -m "feat(array): FFI bindings for wok_array_* ABI (Slice B task 2)"
```

```json:metadata
{"files": ["src/Wok/Interp/RC/Heap.hs"], "verifyCommand": "cabal build all", "acceptanceCriteria": ["five wok_array_* foreign imports exported", "cabal build all succeeds"], "modelTier": "mechanical"}
```

---

### Task 3: Route CHeap `NArray` to the C cell — alloc, cascade, deref, render

**Goal:** On the CHeap backend, `NArray` is allocated as a real `WokArray` cell and correctly torn down / read back; the abstract `NArray` is unchanged. This is the soundness-critical RC integration.

**Files:**
- Modify: `src/Wok/Interp/RC/Value.hs` — read these first: `alloc`/`allocNCon`/`allocPure` (~918-996), `nodeCEligible`/`nodeArity` (~994-1003), `internTag` (~792-800), `encodeSlotC`/slot decode (~852-863), `readCConValues` (~1111-1142), `dropAddr` CAddr arm (~1213-1228), `dropReuse` CAddr arm (~1383-1390), the renderers.

**Acceptance Criteria:**
- [ ] `internTag` never returns `0xFFFF` (reserved for `WOK_ARRAY_TAG`); a guard keeps the constructor count below `0xFFFF`.
- [ ] On the CHeap backend, `alloc (NArray vs)` allocates a `WokArray` via `wokArrayAlloc len elemkind`, encodes each element into its slot (reusing `encodeSlotC`), and returns a `CAddr`. `elemkind` is the uniform element `SlotKind` (raw-lit vs pointer-scheme) per spec §3/§6.
- [ ] On the AbstractHeap backend, `alloc (NArray vs)` stays on the abstract heap (Slice A behaviour, unchanged).
- [ ] `dropAddr`/`deref`/`readCCell` get a `WOK_ARRAY_TAG` branch: read `len` + `elemkind`; raw-lit ⇒ no child drops; pointer-scheme ⇒ drop counted slots; then `wok_free`. The "CAddr is always NCon" comment is updated.
- [ ] `nodeCEligible (NArray _) = False` and `nodeArity _ = 0` UNCHANGED (arrays stay FBIP-excluded; `dropReuse` never sees an array `CAddr`).
- [ ] A `CAddr` array renders byte-identically to the abstract `NArray` renderer (`[a, b, c]`).

**Verify:** `cabal test wok-tests --test-options='-p "Array"'` → existing array tests pass on both backends (no regression; full C-backed behaviour validated in Task 6).

**Steps:**

- [ ] **Step 1: Read the cited functions** in `Value.hs` to learn the exact shapes of `alloc`, `encodeSlotC`/decode, `readCConValues`, the `dropAddr` CAddr arm, and `internTag`. Follow spec §3 and §6.

- [ ] **Step 2: Reserve the tag.** In `internTag`, skip `0xFFFF` (e.g. if the next id would be `0xFFFF`, error or bump past it) and keep the existing `tid >= 65536` fallback consistent (`>= 0xFFFF` reserves the array slot). Add a unit assertion that interning never yields `0xFFFF`.

- [ ] **Step 3: Add a CHeap `NArray` alloc branch.** A new `allocNArray :: [RCValue] -> Store -> RC (Addr, Store)` for the CHeap backend: compute `elemkind` from the elements' uniform `SlotKind` (raw-lit if the slot encoding is a `KLit*`, else pointer-scheme); `wokArrayAlloc (length vs) elemkind`; `wokArraySlotSet` each encoded element; `recordAlloc` (Task 4 makes it byte-aware — until then, count one cell). Wire it into `alloc`: `alloc (NArray vs) s = case stBackend s of CHeap hp -> allocNArray vs s; AbstractHeap -> pure (allocPure (NArray vs) s)`.

- [ ] **Step 4: Add the array branch to the C-decode/cascade paths.** In `deref`/`readCCell` and `dropAddr`'s `CAddr` arm, branch when `wokTag p == WOK_ARRAY_TAG`: read `len`/`elemkind`, decode `len` slots (raw-lit → reconstruct the `RVLit`; pointer-scheme → decode each slot's 2-bit tag); for the cascade, drop the counted slots then `wok_free`. Update the "CAddr is always NCon" comment. Do NOT touch `dropReuse` (arrays are FBIP-excluded; add an assertion/comment that an array `CAddr` is unreachable there).

- [ ] **Step 5: Renderer.** Extend the store-aware renderer so a `WOK_ARRAY_TAG` `CAddr` renders identically to the abstract `NArray`.

- [ ] **Step 6: Verify.** Run: `cabal build all` then `cabal test wok-tests --test-options='-p "Array"'`. Existing array tests must pass.

- [ ] **Step 7: Commit.**

```bash
git add src/Wok/Interp/RC/Value.hs
git commit -m "feat(array): route CHeap NArray to the C WokArray cell + cascade/deref (Slice B task 3)"
```

```json:metadata
{"files": ["src/Wok/Interp/RC/Value.hs"], "verifyCommand": "cabal test wok-tests --test-options='-p \"Array\"'", "acceptanceCriteria": ["internTag reserves 0xFFFF", "CHeap NArray -> WokArray via wokArrayAlloc with elemkind", "AbstractHeap NArray unchanged", "dropAddr/deref/readCCell WOK_ARRAY_TAG branch keyed on elemkind", "nodeCEligible/nodeArity unchanged (FBIP-excluded)", "CAddr array renders identically to abstract NArray"], "modelTier": "standard"}
```

---

### Task 4: `peak_bytes` as a shared differential-oracle invariant

**Goal:** The abstract heap tracks live bytes identically to the C runtime, and the oracle asserts `peak_bytes` equality.

**Files:**
- Modify: `src/Wok/Interp/RC/Value.hs` — `Stats` (~669-674), `recordAlloc`/`recordFree` (~680-687) and their ~10 call sites (`allocNCon`, `allocPure`, `dropAddrStepPure`, `freeReservation`, `moveOutContPure`, `allocAt`, the `CAddr` drop path via `bumpFreeStats`).
- Modify: `test/Spec.hs` — the parity harness (`rcParityHarness`, ~10969-10991) to read + compare `peak_bytes`.

**Acceptance Criteria:**
- [ ] `Stats` gains `stCurBytes` and `stPeakBytes`.
- [ ] `wouldBeCBytes :: Node -> Int`: C-eligible `NCon` ⇒ `8 + 8*arity`; `NArray` ⇒ `16 + 8*len`; every abstract-only node ⇒ `0`. Mirrors C exactly.
- [ ] `recordAlloc :: Int -> Stats -> Stats` and `recordFree :: Int -> Stats -> Stats` maintain `stCurBytes` (±) and `stPeakBytes` (high-water); all ~10 call sites pass the node's `wouldBeCBytes`.
- [ ] The oracle reads `wokStatPeakBytes` from the C heap BEFORE `wok_heap_free` and compares it to the AbstractHeap's `stPeakBytes`; they are equal on every corpus program.
- [ ] `cabal test wok-tests` passes (existing + the new `peak_bytes` assertion green).

**Verify:** `cabal test wok-tests` → all green, including `peak_bytes` parity over the array corpus.

**Steps:**

- [ ] **Step 1: Extend `Stats`** with `stCurBytes :: Int` and `stPeakBytes :: Int` (init 0 in `emptyStore`).

- [ ] **Step 2: Add `wouldBeCBytes`** per spec §7 (C-eligible `NCon` → `8 + 8*arity`; `NArray` → `16 + 8*len`; else 0).

- [ ] **Step 3: Make `recordAlloc`/`recordFree` byte-aware** (`Int -> Stats -> Stats`); update all ~10 call sites to compute and pass the delta from the node being allocated/freed.

- [ ] **Step 4: Add the oracle assertion** in `rcParityHarness`: read `wokStatPeakBytes hp` before the `finally`/`wokHeapFree`, and assert it equals the AbstractHeap run's `stPeakBytes`. Extend `RCRun`/the comparison as needed (read before free — see spec §8).

- [ ] **Step 5: Verify.** Run: `cabal test wok-tests`. All green.

- [ ] **Step 6: Commit.**

```bash
git add src/Wok/Interp/RC/Value.hs test/Spec.hs
git commit -m "feat(array): elevate peak_bytes to a shared oracle invariant (Slice B task 4)"
```

```json:metadata
{"files": ["src/Wok/Interp/RC/Value.hs", "test/Spec.hs"], "verifyCommand": "cabal test wok-tests", "acceptanceCriteria": ["Stats gains stCurBytes/stPeakBytes", "wouldBeCBytes mirrors C (NCon 8+8a, NArray 16+8len, else 0)", "recordAlloc/recordFree byte-aware at all call sites", "oracle reads wokStatPeakBytes before heap free and asserts equality", "cabal test wok-tests green"], "modelTier": "standard"}
```

---

### Task 5: The seven prims backed by the C cell

**Goal:** `new`/`fromList`/`toList`/`index`/`length`/`set`/`resize` read/write the C cell on the CHeap backend with the Slice A RC semantics preserved; the abstract path is unchanged.

**Files:**
- Modify: `src/Wok/Interp/RC/Prim.hs` — the seven array prims (`arrayNew`/`arrayFromList`/`arrayToList`/`arrayIndex`/`arrayLength`/`arraySet`/`arrayResize`, ~461-586) and `arrayElems` (~462-468).

**Acceptance Criteria:**
- [ ] Each prim works on a CHeap `WokArray` (via Task 3's deref/decode + `wokArray*`) AND on the abstract `NArray`, with the exact dup/drop accounting from spec §4 (and Slice A §4).
- [ ] `index`/`set` raise `PrimError` on out-of-bounds; no partial functions.
- [ ] `cabal test wok-tests --test-options='-p "Array"'` passes the behavioural + property tests on both backends.

**Verify:** `cabal test wok-tests --test-options='-p "Array"'` → green.

**Steps:**

- [ ] **Step 1: Read** the seven prims and `arrayElems` in `Prim.hs`. They currently pattern-match the abstract `NArray` via `deref`. Task 3 made `deref` of an array `CAddr` decode the C cell into the same `[RCValue]` shape, so `arrayElems` should work for both backends once it routes a `WOK_ARRAY_TAG` `CAddr` through the array decoder.

- [ ] **Step 2: Make the constructing prims allocate via the backend's `alloc (NArray …)`** (Task 3 routes that to the C cell on CHeap). `new`/`fromList`/`set`/`resize` build `[RCValue]` and call `alloc (NArray new)`; `index`/`length` read via `arrayElems`/`deref`; `toList` reads then builds cons cells. Keep the exact `incref`/`drop`/transfer sequence from spec §4. Bounds-check `index`/`set` before any slot access.

- [ ] **Step 3: Verify.** Run: `cabal test wok-tests --test-options='-p "Array"'`. Behavioural + property tests green on both backends.

- [ ] **Step 4: Commit.**

```bash
git add src/Wok/Interp/RC/Prim.hs
git commit -m "feat(array): seven prims backed by the C WokArray cell (Slice B task 5)"
```

```json:metadata
{"files": ["src/Wok/Interp/RC/Prim.hs"], "verifyCommand": "cabal test wok-tests --test-options='-p \"Array\"'", "acceptanceCriteria": ["seven prims work on CHeap WokArray and abstract NArray", "dup/drop accounting per spec §4", "index/set bounds raise PrimError, no partial functions", "Array tests green on both backends"], "modelTier": "standard"}
```

---

### Task 6: Tests — C-cell coverage, C-backend behaviour, oracle corpus, store-algebra

**Goal:** Prove the C cell is faithful to the abstract reference over the corpus (incl. boxed-element arrays) and that teardown returns to baseline.

**Files:**
- Modify: `test/Spec.hs` — extend the array test groups (store-algebra C-cell assertions; ensure the array corpus runs on the C backend; add boxed-element corpus cases).
- Add (if needed): `test/rc-array/*.wok` programs covering boxed-element arrays (`Array [U64]`, `Array String`) and inline-element arrays (`Array U64`/`U32`).

**Acceptance Criteria:**
- [ ] The differential oracle runs every `test/rc-array` + `test/rc-array-oob` program on both backends: byte-identical output + matching `alloc`/`free`/`peak`/`peak_bytes`; heap returns to baseline (`stLive == baseline`, `wok_stat_live == 0`).
- [ ] Corpus covers inline-element arrays (empty cascade) AND boxed-element arrays (each counted child dropped exactly once).
- [ ] Store-algebra C-cell assertions: `alloc`/`dup`/`dropAddr`/cascade on an array `CAddr` — inline-element ⇒ empty cascade; boxed-element ⇒ children dropped once, no double-free.
- [ ] `cabal test wok-tests` fully green; `bash scripts/asan-runtime.sh` clean.

**Verify:** `cabal test wok-tests` → all green; `bash scripts/asan-runtime.sh` → exit 0.

**Steps:**

- [ ] **Step 1: Audit the existing array corpus** (`test/rc-array/`, `test/rc-array-oob/`) and confirm each runs on BOTH backends in the parity harness (Slice A may have run some on AbstractHeap only). Route them through `rcParityHarness`.

- [ ] **Step 2: Add boxed-element corpus programs** if missing: e.g. `Array String` and `Array [U64]` exercising `fromList`/`index`/`set`/`toList`/`resize` so the counted-slot cascade is covered. Assert baseline return.

- [ ] **Step 3: Add store-algebra C-cell unit assertions** mirroring the abstract `NArray` ones, on an array `CAddr`: build, dup, drop, cascade; assert `stLive`/`wok_stat_live` return to baseline and no double-free.

- [ ] **Step 4: Run the full suite + sanitizers.** Run: `cabal test wok-tests` and `bash scripts/asan-runtime.sh`. All green.

- [ ] **Step 5: Commit.**

```bash
git add test/
git commit -m "test(array): C-cell oracle parity incl boxed elements + store-algebra (Slice B task 6)"
```

```json:metadata
{"files": ["test/Spec.hs", "test/rc-array/"], "verifyCommand": "cabal test wok-tests", "acceptanceCriteria": ["oracle runs array corpus on both backends: output + alloc/free/peak/peak_bytes match", "inline AND boxed element coverage", "store-algebra C-cell cascade assertions", "baseline return; cabal test + asan clean"], "modelTier": "standard"}
```

---

### Task 7: Docs + memory

**Goal:** Document the `WokArray` cell and update the memory/arc records.

**Files:**
- Modify: `runtime/README.md` (the `WokArray` cell + the unified byte-size class).
- Modify: `docs/superpowers/2026-06-24-array-region-valuemodel-arc.md` (mark Slice B implemented).
- Modify: the `array-slice-a-merged` memory note (record Slice B).

**Acceptance Criteria:**
- [ ] `runtime/README.md` documents the array cell layout, the `wok_array_*` ABI, and the shared byte-size class.
- [ ] The arc doc marks Slice B done; the memory note records the outcome.
- [ ] No scaffolding left behind.

**Verify:** `git status` clean except intended docs; `cabal test wok-tests` still green.

**Steps:**

- [ ] **Step 1: Update `runtime/README.md`** with the `WokArray` section (layout, ABI, byte-size class, `peak_bytes`).
- [ ] **Step 2: Update the arc doc** (`docs/superpowers/2026-06-24-array-region-valuemodel-arc.md`) — Slice B implemented.
- [ ] **Step 3: Update the memory note** `array-slice-a-merged` (or add a `array-slice-b-c-cell` note) recording the C cell, byte-size class, and `peak_bytes` invariant.
- [ ] **Step 4: Commit.**

```bash
git add runtime/README.md docs/ ~/.claude/projects/-Users-zy-wokml/memory/
git commit -m "docs(array): document WokArray cell + memory note (Slice B task 7)"
```

```json:metadata
{"files": ["runtime/README.md", "docs/superpowers/2026-06-24-array-region-valuemodel-arc.md"], "verifyCommand": "cabal test wok-tests", "acceptanceCriteria": ["runtime/README.md documents the WokArray cell + ABI + byte-size class", "arc doc marks Slice B done", "memory note recorded", "no scaffolding left"], "modelTier": "mechanical"}
```

---

## Self-review

- **Spec coverage:** §2 architecture → Tasks 3/4; §3 C cell + ABI → Task 1; §4 ops → Task 5; §6 cascade/deref/render → Task 3; §7 peak_bytes → Task 4; §8 oracle → Tasks 4/6; §9 testing → Tasks 1/6; §10 files → all; §11 task breakdown → mirrored; §12-13 decisions/future → header + docs. No gap.
- **Placeholder scan:** no TBD/TODO; each task has concrete files, AC, verify commands; C code is complete; Haskell steps reference exact functions + spec sections (the implementer reads the live code, as the spec is the authoritative design).
- **Type consistency:** `elemkind` (header byte) used consistently across Tasks 1/3/5; `wok_array_*` names match between Task 1 (C) and Task 2 (FFI); `wouldBeCBytes`/`stCurBytes`/`stPeakBytes` consistent in Task 4; `WOK_ARRAY_TAG` consistent across C + Haskell.
- **Dependencies:** 2←1, 3←2, 4←3, 5←3, 6←{4,5}, 7←6.

No user-gate tasks tagged (this is a build-it plan; the user's "run autonomously" directive covers execution).
