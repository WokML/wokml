# Layout compaction Slice 1 — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers-extended-cc:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) tracking.

**Goal:** Halve the C constructor cell — 16B header + 16B `{tag,payload}` slots → **8B header + 8B raw slots** — by hoisting the per-slot kind into a shared per-constructor descriptor, keeping the int encoding semantics identical so the differential oracle stays bit-for-bit.

**Architecture:** The 8B `WokObj` (`rc32|tag16|arity8|scan8`) + one `uint64` per slot lives behind the private accessor ABI (slot accessors migrate to one word — small FFI change). A Haskell `ConDescriptor` (per-slot `SlotKind`, derived from the `RCValue` kinds at first intern, keyed by `tag`) replaces the per-slot tag word: `encodeSlotC`/`decodeSlotC` marshal one word; `readCCell`/`readCSlots`/`allocNCon`/`dropAddr` become descriptor-driven. Encoding semantics are unchanged (a high-bit `U64` still falls back to the abstract heap — no promotion).

**Tech Stack:** C17 (the existing `runtime/wok_rc.{c,h}` + arena, under the `-Werror -Wconversion` wall); Haskell `Wok.Interp.RC.{Heap,Value}`; the tasty differential oracle + `scripts/asan-runtime.sh`.

**User decisions (already made):**
- "(b) ... I don't want promotion. If it has no promotion I can still consider it" — **Option B**: struct shrink first, keep today's int encoding; high-bit `U64` falls back (alloc-site selection, **never runtime promotion**). Full-range-`U64`-inline deferred.
- Descriptor regime (raw slots, no tagged words); 8B header; descriptor reached by `tag` index.
- The **C-driven `wok_drop` cascade is deferred** — Slice-1 cascade stays Haskell-driven but descriptor-based (spec §10(c)).
- One-word slot accessors (spec §10(b)).
- "run it autonomously."

---

## File structure

| File | Responsibility | Change |
| ---- | -------------- | ------ |
| `runtime/wok_rc.h` | 8B `WokObj` + one-word slot accessor signatures | **modify** |
| `runtime/wok_rc.c` | header pack/unpack, one-word slots, arena cell size `8+8*arity` | **modify** |
| `runtime/test/wok_rc_test.c` | standalone test → 8B layout | **modify** |
| `src/Wok/Interp/RC/Heap.hs` | FFI: one-word `wokSlotSet`/`wokSlotGet`; drop the `ws*` slot-tag constants | **modify** |
| `src/Wok/Interp/RC/Value.hs` | `SlotKind`, `ConDescriptor` (in `Store`), `encodeSlotC`/`decodeSlotC`, rework `readCCell`/`readCSlots`/`allocNCon`/`dropAddr` | **modify** |
| `test/Spec.hs` | round-trip property; high-bit-`U64`-falls-back test; `wok-rc-heap` one-word update | **modify** |
| `scripts/asan-runtime.sh` / docs | 8B `_Static_assert`; README/spec/memory | **modify** |

No cabal change.

---

### Task 1: Compacted 8B `WokObj` + one-word slots (C + FFI)

**Goal:** Replace the 16B/16B cell with an 8B header + 8B slots in `runtime/wok_rc.{c,h}` and the arena, migrate the slot accessors to one word, and update the FFI — proven by the standalone C test and the full suite.

**Files:**
- Modify: `runtime/wok_rc.h`, `runtime/wok_rc.c`, `runtime/test/wok_rc_test.c`, `src/Wok/Interp/RC/Heap.hs`

**Acceptance Criteria:**
- [ ] `_Static_assert(sizeof(WokObj) == 8)` holds; the standalone test passes under `scripts/asan-runtime.sh`.
- [ ] `wok_slot_set(p,i,word)` / `wok_slot_get(p,i)->word` are one-word; `wok_tag`/`wok_arity` keep their `uint32` returns (read the packed fields); `wok_alloc(h,tag,arity)` truncates into the packed header with `assert(tag < 65536 && arity < 256)`.
- [ ] The arena cell size is `8 + 8*arity`; `wok_cell_bytes` and the `_Static_assert`s updated; sanitizer matrix green.
- [ ] The full `cabal test` suite stays green after the Heap.hs FFI + the (mechanical) Value.hs slot-call updates needed to compile (the descriptor rework is Task 2 — for Task 1, keep the Haskell side compiling by passing the existing payload word and a temporary kind, OR land Task 1+2 together; see Step 5).

**Verify:** `bash scripts/asan-runtime.sh` → `OK`; `cabal build` clean under `-Werror`.

**Steps:**

- [ ] **Step 1: Rewrite `runtime/wok_rc.h`'s structs + slot accessor signatures.**

```c
typedef struct WokObj {
    uint32_t rc;       /* plain counter */
    uint16_t tag;      /* interned constructor id -> indexes the Haskell descriptor */
    uint8_t  arity;    /* 0..255 */
    uint8_t  scan;     /* pointer-slot count; provisioned for the future C cascade (set 0 now) */
    uint64_t slots[];  /* `arity` raw 8-byte words */
} WokObj;

/* slot accessors are now ONE word (no per-slot tag): */
void     wok_slot_set(WokObj* p, uint32_t i, uint64_t word);
WOK_PURE uint64_t wok_slot_get(const WokObj* p, uint32_t i);
```

Keep `wok_tag`/`wok_arity` returning `uint32_t`. (Remove the old two-out-param `wok_slot_get`.)

- [ ] **Step 2: Update `runtime/wok_rc.c`** — the `_Static_assert(sizeof(WokObj)==8)`; `wok_alloc` packs the header (`p->rc=1; p->tag=(uint16_t)tag; p->arity=(uint8_t)arity; p->scan=0;` with `assert(tag < 65536u && arity < 256u)`); `wok_cell_bytes(arity)` returns `sizeof(WokObj) + (size_t)arity * sizeof(uint64_t)`; the one-word `wok_slot_set`/`wok_slot_get` (`p->slots[i] = word;` / `return p->slots[i];` with the `assert(i < p->arity)`); update the slab-fit `_Static_assert` to the new cell size. The arena free-list / bump logic is otherwise unchanged (the link still fits — min cell is 8 bytes).

- [ ] **Step 3: Update `runtime/test/wok_rc_test.c`** to the one-word slot API (`wok_slot_set(p,i,word)`; `uint64_t w = wok_slot_get(p,i)`), keep the reuse/slab/large/teardown assertions, and add `assert(sizeof(WokObj) == 8)` via the static assert in the header (compile-checked).

- [ ] **Step 4: Update `src/Wok/Interp/RC/Heap.hs` FFI** — `wokSlotSet :: Ptr WokObj -> Word32 -> Word64 -> IO ()` (one word); `wokSlotGet :: Ptr WokObj -> Word32 -> IO Word64` (single return, no `alloca` pair); delete the `wsLitInt..wsHBox` slot-tag constants (the descriptor replaces them).

- [ ] **Step 5: Sequence with Task 2.** The Value.hs callers of `wokSlotSet`/`wokSlotGet`/`encodeSlot`/`decodeSlot` will not compile until Task 2's descriptor rework. **Land Task 1 and Task 2 as one green commit** (the C+FFI change and the Haskell marshalling change are co-dependent). Run `bash scripts/asan-runtime.sh` after Step 2-3 (C compiles+passes standalone); defer `cabal test` to the end of Task 2.

- [ ] **Step 6: Commit** (with Task 2 — see Task 2 Step 7).

---

### Task 2: Descriptor + descriptor-driven Haskell marshalling

**Goal:** Add `SlotKind`/`ConDescriptor` and rework `encodeSlotC`/`decodeSlotC`/`readCCell`/`readCSlots`/`allocNCon`/`dropAddr` to one-word descriptor-driven marshalling, encoding semantics unchanged — proven green by the differential oracle.

**Files:**
- Modify: `src/Wok/Interp/RC/Value.hs`

**Acceptance Criteria:**
- [ ] `SlotKind = KLitInt | KLitChar | KLitUnit | KPointer`; `Store` gains `stConDesc :: IntMap [SlotKind]` keyed by tag id.
- [ ] `encodeSlotC :: RCValue -> Maybe (SlotKind, Word64)` and `decodeSlotC :: SlotKind -> Word64 -> RCValue` are exact inverses on the encodable shapes; `LInt` keeps the `Int64`-fit check (a high-bit `U64` returns `Nothing` → fallback); `HAddr i` round-trips via `(i << 1) .|. 1` / arithmetic `>> 1` over negative/static `i`.
- [ ] `allocNCon` records the descriptor on first intern (from the slots' kinds) and writes one word per slot; `readCCell`/`dropAddr` look up the descriptor by tag and `decodeSlotC` each word.
- [ ] The whole `cabal test` suite is green (abstract⟷C-compacted parity, `live==baseline`).

**Verify:** `cabal test 2>&1 | tail -6` → all pass (≥ 1278).

**Steps:**

- [ ] **Step 1: Add the kind type + descriptor store field.** In `Value.hs`:

```haskell
data SlotKind = KLitInt | KLitChar | KLitUnit | KPointer
  deriving (Eq, Show)
```

Add `stConDesc :: IntMap [SlotKind]` to `Store` (init `IM.empty` in `emptyStore`).

- [ ] **Step 2: Replace `encodeSlot`/`decodeSlot` with the one-word descriptor-driven pair.**

```haskell
-- Encoding semantics UNCHANGED from the 16B era: a high-bit U64 / bignum returns
-- Nothing (whole NCon falls back to the abstract heap). Now one word + the kind.
encodeSlotC :: RCValue -> Maybe (SlotKind, Word64)
encodeSlotC (RVLit (LInt n))  = (\w -> (KLitInt, fromIntegral (w :: Int64))) <$> toIntegralSized n
encodeSlotC (RVLit (LChar c)) = Just (KLitChar, fromIntegral (fromEnum c))
encodeSlotC (RVLit LUnit)     = Just (KLitUnit, 0)
encodeSlotC (RVBox (CAddr p)) = Just (KPointer, fromIntegral (ptrToWordPtr p))            -- low bit 0 (16-aligned)
encodeSlotC (RVBox (HAddr i)) = Just (KPointer, fromIntegral ((i `shiftL` 1) .|. 1))      -- low bit 1
encodeSlotC _                 = Nothing

decodeSlotC :: SlotKind -> Word64 -> RCValue
decodeSlotC KLitInt  w = RVLit (LInt (fromIntegral (fromIntegral w :: Int64)))
decodeSlotC KLitChar w = RVLit (LChar (decodeChar w))                                     -- reuse the existing guarded decodeChar
decodeSlotC KLitUnit _ = RVLit LUnit
decodeSlotC KPointer w
  | w .&. 1 == 0 = RVBox (CAddr (wordPtrToPtr (WordPtr w)))
  | otherwise    = RVBox (HAddr (fromIntegral ((fromIntegral w :: Int64) `shiftR` 1)))    -- arithmetic >>; round-trips negatives
```

(Keep `decodeChar` exactly as today.)

- [ ] **Step 3: Rework `allocNCon`** (the `CHeap` branch): `traverse encodeSlotC vs` → on `Just encoded`, `internTag con`, record `stConDesc[tid] = map fst encoded` (idempotent — first sight wins; static typing makes it consistent), `wok_alloc tid (length vs)`, then `wokSlotSet p i (snd (encoded!!i))` per slot; on `Nothing`, `allocPure` fallback (unchanged).

- [ ] **Step 4: Rework `readCSlots`/`readCCell`** to one word + descriptor:

```haskell
readCWords :: Ptr WokObj -> IO [Word64]
readCWords p = do
  ar <- H.wokArity p
  mapM (H.wokSlotGet p) (take (fromIntegral ar) [0 ..])

readCCell :: Ptr WokObj -> Store -> IO Cell
readCCell p s = do
  tid   <- H.wokTag p
  words <- readCWords p
  let kinds = IM.findWithDefault (error "readCCell: no descriptor for tag") (fromIntegral tid) (stConDesc s)
  pure (Cell 0 (NCon (tagName tid s) (zipWith decodeSlotC kinds words)))
```

- [ ] **Step 5: Rework the `CAddr` arm of `dropAddr`** to decode via the descriptor before freeing: `tid <- wokTag p; words <- readCWords p; let kids = countedRefs (zipWith decodeSlotC (descriptorFor tid s) words)` then `wokFree`, recurse on `kids` (unchanged routing). Factor the "tag→kinds→decode" into one helper shared with `readCCell`.

- [ ] **Step 6: Run the full suite.**

Run: `cabal test 2>&1 | tail -6`
Expected: all pass (≥ 1278); the differential oracle confirms the compacted layout is bit-for-bit identical (encoding semantics unchanged).

- [ ] **Step 7: Commit Task 1 + Task 2 together.**

```bash
git add runtime/wok_rc.h runtime/wok_rc.c runtime/test/wok_rc_test.c \
        src/Wok/Interp/RC/Heap.hs src/Wok/Interp/RC/Value.hs
git commit -m "feat(rc): compact the cell to 8B header + 8B descriptor-driven slots

8B WokObj (rc32|tag16|arity8|scan8) + one uint64 per slot; per-slot kind hoisted
into a Haskell ConDescriptor keyed by tag. encodeSlotC/decodeSlotC marshal one
word; encoding semantics unchanged (high-bit U64 still falls back, no promotion).
~50% smaller cells; differential oracle bit-for-bit.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 3: Oracle + tests + sanitizer

**Goal:** Add the round-trip property, the high-bit-`U64`-falls-back test, and extend the sanitizer matrix to the 8B struct.

**Files:** Modify: `test/Spec.hs`, `scripts/asan-runtime.sh` (the `_Static_assert` is compile-checked in `wok_rc.h`)

**Acceptance Criteria:**
- [ ] A QuickCheck/HUnit property: for every encodable `RCValue`, `uncurry decodeSlotC <$> encodeSlotC v == Just v` (incl. negative/static `HAddr`, `LChar`, the `Int64` boundaries `±(2^63-1)`).
- [ ] A test that a constructor with a high-bit `U64` field (≥ 2⁶³) renders identically under the C-compacted and abstract backends (it falls back; no promotion, no divergence).
- [ ] `wok-rc-heap` raw-FFI test updated to the one-word slot API.
- [ ] `bash scripts/asan-runtime.sh` green (arena/malloc/poison) on the 8B struct.

**Verify:** `cabal test 2>&1 | tail -4 && bash scripts/asan-runtime.sh >/dev/null && echo OK`

**Steps:**
- [ ] **Step 1:** Add the round-trip property to `test/Spec.hs` (generator over `RVLit (LInt)` in `Int64` range, `LChar`, `LUnit`, `RVBox (HAddr)` incl. negatives). Run → PASS.
- [ ] **Step 2:** Add the high-bit-`U64` differential test (a hand-instrumented module with a `U64` field = `2^63 + 7`, asserted equal output both backends). Run → PASS.
- [ ] **Step 3:** Update `wokRcHeapTests` to the one-word `wokSlotSet`/`wokSlotGet`. Run → PASS.
- [ ] **Step 4:** `bash scripts/asan-runtime.sh` → three OK. Commit.

---

### Task 4: Docs + memory

**Goal:** Record the compacted layout (ABI's accessor surface noted as changed for slots), mark the spec implemented, update the memory note.

**Files:** Modify: `runtime/README.md`, `docs/superpowers/specs/2026-06-22-layout-compaction-design.md`, memory note + `MEMORY.md`

**Acceptance Criteria:**
- [ ] `runtime/README.md` describes the 8B header + one-word descriptor-driven slots, notes the slot accessors became one word, and that encoding semantics are unchanged (high-bit `U64` falls back).
- [ ] Spec status → IMPLEMENTED.
- [ ] Memory note records Slice 1 (option B), `MEMORY.md` pointer, absolute dates.

**Verify:** `grep -n "8B header" runtime/README.md && grep -n IMPLEMENTED docs/superpowers/specs/2026-06-22-layout-compaction-design.md`

**Steps:**
- [ ] **Step 1:** Rewrite the README layout section. **Step 2:** Flip the spec status. **Step 3:** Memory note + `MEMORY.md`. **Step 4:** Final `cabal test` + `asan-runtime.sh` sanity; commit.

---

## Self-review

**Spec coverage:** 8B header + one-word slots → Task 1; descriptor + encode/decode/deref/cascade rework → Task 2; round-trip + high-bit-fallback + sanitizer → Task 3; docs/memory → Task 4. C-driven cascade + full-`U64`-inline = deferred (spec §9), not in plan. ✓

**Placeholder scan:** the new types/functions (`SlotKind`, `encodeSlotC`, `decodeSlotC`, `readCWords`, `readCCell`) are shown in full; the rework steps name exact functions + the precise transformation. Task 1/2 are explicitly co-landed (Step 5/7) since the C+FFI and Haskell changes are co-dependent. ✓

**Type consistency:** `encodeSlotC :: RCValue -> Maybe (SlotKind, Word64)` and `decodeSlotC :: SlotKind -> Word64 -> RCValue` match across Tasks 2-3; `wokSlotSet`/`wokSlotGet` one-word signatures match between Heap.hs (Task 1 Step 4) and the Value.hs callers (Task 2). `stConDesc :: IntMap [SlotKind]` keyed by `fromIntegral tid`. ✓

**Warning wall:** the C changes (packed `uint16`/`uint8` stores, one-word slots) use explicit casts + `assert` guards to stay `-Werror -Wconversion` clean; Task 2 Step 6 (`cabal test`) compiles the C under the full wall and fails loudly otherwise. ✓
