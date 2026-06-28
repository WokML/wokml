# FFI bytes-in (Slice 1) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers-extended-cc:subagent-driven-development (recommended) or superpowers-extended-cc:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Bring a genuinely foreign byte buffer into the reference-counted runtime as `Bytes` via two ownership tiers — copy-in (Tier 1) and zero-copy adopt (Tier 2, freed by libc `free` at refcount-zero) — feeding the existing E6 `fromBytes` gate, with no user-facing FFI surface.

**Architecture:** A new fixed-24B C cell `WokForeignBytes` (tag `0xFFFB`) holds a foreign data pointer + length, modeled after `WokStringView` (Haskell-driven drop, `scan=0`). A new RC node `NForeignBytes` mirrors it on the abstract heap, charging a fixed 24B handle (the foreign buffer is off-heap, untracked) so the differential oracle *pins* the zero-copy saving. Two host-blessed deterministic producer prims drive both tiers; copy-in reuses the existing `allocNBytes` path.

**Tech Stack:** C (runtime/wok_rc.c), Haskell GHC FFI (Foreign.Marshal), the wok RC interpreter, Hspec/tasty (`wok-tests`), QuickCheck, ASan/UBSan/LSan via `scripts/asan-runtime.sh`.

**User decisions (already made):**
- "execute autonomously now" — subagent-driven, this session.
- Slice 1 = Tier 1 + Tier 2, host-blessed producer, no surface syntax. ("Yes" to the gist.)
- Copy-vs-adopt is a declared contract (in the host binding here), never type-inferred.
- Path-C `foreign module` surface + `IO` effect + `using free` = deferred Slice 2. The borrow/"reference" tier = future. Optimal call (dlopen/codegen) = parked "cash".
- Spec: `docs/superpowers/specs/2026-06-28-ffi-bytes-in-design.md` (approved; alignment-reviewed).

---

## File structure

- `runtime/wok_rc.h` — declare `WOK_FOREIGN_BYTES_TAG` + 3 accessors; extend reserved-tag comments.
- `runtime/wok_rc.c` — `wok_foreign_bytes_alloc`/`_ptr`/`_len`; a `wok_free` arm for `0xFFFB`.
- `runtime/test/wok_rc_test.c` — C lifecycle test + negative control (already linked by the ASan script).
- `src/Wok/Interp/RC/Heap.hs` — 3 `foreign import`s for the new C functions.
- `src/Wok/Interp/RC/Value.hs` — `NForeignBytes` node + every Node-matcher arm; `wokForeignBytesTag`; `internTag` skip; `allocForeignBytes` + `alloc` dispatch; `dropAddr` arms.
- `src/Wok/Interp/RC/Prim.hs` — the two producer prims; `bytesBytes`/`bytesViaDeref` arms; prim table entries.
- `src/Wok/Interp/Prim.hs`, `src/Wok/Interp/Value.hs` — reference-interpreter producer prims (reuse `VBytes`).
- `src/Wok/IR/PrimNames.hs` — names for the two producers (if any analysis keys on them; else table-only).
- `prelude/Std/Bytes.wok` — two `__`-prefixed intrinsic `extern` decls.
- `test/Spec.hs`, `test/rc-ffi-bytes/` — corpus + oracle wiring + properties + soundness tests.

---

## Task 1: C runtime — WokForeignBytes cell + C lifecycle test

**Goal:** A fixed-24B `WokForeignBytes` C cell (tag `0xFFFB`) holding a foreign pointer + length, with allocator, accessors, a `wok_free` arm that runs before the arity fallback, and an ASan-clean C lifecycle test with a negative control.

**Files:**
- Modify: `runtime/wok_rc.h` (after the `WOK_STRING_VIEW_TAG` block ~line 158-164; and the reserved-tag comments ~85-86, ~109-110, ~130-131, ~156)
- Modify: `runtime/wok_rc.c` (`wok_free` dispatch ~703-716; new functions near `wok_bytes_alloc` ~847-879)
- Modify: `runtime/test/wok_rc_test.c` (new test fn + register it)

**Acceptance Criteria:**
- [ ] `wok_foreign_bytes_alloc(h, ptr, len)` returns a 24B cell tagged `0xFFFB`, `rc=1`, charging exactly 24 to `cur_bytes` (size class 2).
- [ ] `wok_foreign_bytes_ptr`/`_len` read back the stored pointer and length unchanged.
- [ ] `wok_free` on a `0xFFFB` cell dispatches BEFORE the arity fallback, recycles a 24B class-2 cell, and does NOT touch the foreign pointer.
- [ ] A C lifecycle test (malloc a buffer, adopt, read back, free buffer + free cell) is ASan/UBSan/LSan-clean and asserts `cur_bytes` 24→0.
- [ ] A negative control (skip the buffer `free`) makes LSan report a leak — proving the test detects an un-freed foreign buffer.

**Verify:** `bash scripts/asan-runtime.sh` → all labels pass, no ASan/LSan errors; the negative-control variant (run under its own define) reports a leak.

**Steps:**

- [ ] **Step 1: Declare the tag, accessors, and extend reserved-tag comments in `runtime/wok_rc.h`.**

Add after the `WokStringView` block (~line 164):

```c
/* ---- WokForeignBytes: an ADOPTED foreign byte buffer C cell (FFI Slice 1) ----------
   A 24-byte handle that POINTS AT memory allocated OUTSIDE the wok allocator (libc
   malloc / a C function). wok does NOT own the buffer's storage layout; it owns the
   obligation to free it. Modeled on WokStringView (fixed cell, scan=0, Haskell-driven
   drop): at refcount-zero the Haskell host reads data_ptr and runs the foreign free
   (libc free), THEN wok_free recycles this 24B cell. wok_free never dereferences data_ptr.
   Layout (always 8-aligned, fixed 24 bytes):
     offset  0  uint32 rc / uint16 tag / uint8 reserved / uint8 scan  (WokObj prefix)
     offset  8  uint64 data_ptr  <- raw pointer to the FOREIGN buffer
     offset 16  uint64 byte_len  <- buffer length in bytes
   Size class = 24/8 - 1 = 2 (shares the free-list with NCon arity=2).
   The foreign buffer's bytes are NOT counted in cur_bytes (they are foreign); only the
   24B handle is charged. WOK_FOREIGN_BYTES_TAG is reserved Haskell-side: internTag never
   returns 0xFFFB/0xFFFC/0xFFFD/0xFFFE/0xFFFF (all five special tags reserved). */

#define WOK_FOREIGN_BYTES_TAG 0xFFFBu

WokObj*  wok_foreign_bytes_alloc(WokHeap* h, uint8_t* data_ptr, uint64_t byte_len);
WOK_PURE uint8_t* wok_foreign_bytes_ptr(const WokObj* p);  /* raw foreign pointer at offset 8 */
WOK_PURE uint64_t wok_foreign_bytes_len(const WokObj* p);  /* byte length at offset 16 */
```

In each of the four reserved-tag comment lists (search for `0xFFFC`, e.g. lines ~86, ~110, ~131, ~156), add `0xFFFB=WOK_FOREIGN_BYTES_TAG` so all five tags are listed.

- [ ] **Step 2: Implement the allocator and accessors in `runtime/wok_rc.c`** (place after `wok_bytes_alloc`, ~line 879):

```c
WokObj* wok_foreign_bytes_alloc(WokHeap* h, uint8_t* data_ptr, uint64_t byte_len) {
    /* Fixed 24-byte handle, size class 2 (24/8 - 1). Always < WOK_NUM_CLASSES, so no
       large-malloc path. Charges its real 24B to cur_bytes -- the foreign buffer is
       off-heap and intentionally not counted. */
    size_t  sz  = 24u;
    size_t  cls = 2u;
    WokObj* head = h->freelist[cls];
    WokObj* p;
    if (head != NULL) {                       /* reuse from shared class-2 free-list */
        h->freelist[cls] = fl_next(head);
        p = head;
        h->reused += 1u;
    } else {                                  /* bump */
        if (h->bump_ptr == NULL || sz > (size_t)(h->bump_end - h->bump_ptr)) {
            wok_new_slab(h);
        }
        p = (WokObj*)h->bump_ptr;
        h->bump_ptr += sz;
    }
    p->rc = 1u; p->tag = (uint16_t)WOK_FOREIGN_BYTES_TAG; p->arity = 0u; p->scan = 0u;
    uint64_t ptr_word = (uint64_t)(uintptr_t)data_ptr;
    memcpy((char*)p + 8,  &ptr_word, sizeof(uint64_t));
    memcpy((char*)p + 16, &byte_len, sizeof(uint64_t));
    h->allocs += 1u; h->live += 1;
    if (h->live > h->peak) { h->peak = h->live; }
    h->cur_bytes += (uint64_t)sz;
    if (h->cur_bytes > h->peak_bytes) { h->peak_bytes = h->cur_bytes; }
    WOK_LOGICAL_MARK(h);
    return p;
}

uint8_t* wok_foreign_bytes_ptr(const WokObj* p) {
    assert((uint32_t)p->tag == WOK_FOREIGN_BYTES_TAG);
    uint64_t w; memcpy(&w, (const char*)p + 8, sizeof(uint64_t));
    return (uint8_t*)(uintptr_t)w;
}

uint64_t wok_foreign_bytes_len(const WokObj* p) {
    assert((uint32_t)p->tag == WOK_FOREIGN_BYTES_TAG);
    uint64_t w; memcpy(&w, (const char*)p + 16, sizeof(uint64_t));
    return w;
}
```

- [ ] **Step 3: Add the `wok_free` arm BEFORE the arity fallback** in `runtime/wok_rc.c` (inside `wok_free`, after the `WOK_STRING_VIEW_TAG` branch ~711, before the `else { arity }` ~712):

```c
    } else if (WOK_UNLIKELY((uint32_t)p->tag == WOK_FOREIGN_BYTES_TAG)) {
        /* Fixed 24-byte handle, size class 2. The foreign buffer at data_ptr is NOT
           freed here -- the Haskell host frees it (libc free) BEFORE calling wok_free,
           mirroring the WokStringView Haskell-driven drop (scan=0). */
        bytes = 24u;
        cls   = 2u;
```

- [ ] **Step 4: Write the C lifecycle test** in `runtime/test/wok_rc_test.c` (add a function and register it in the test runner alongside the existing `wok_bytes`/`wok_string_view` tests — follow the existing test-registration pattern in that file):

```c
static void test_foreign_bytes_cell(void) {
    WokHeap* h = wok_heap_new();
    uint64_t base = wok_stat_peak_bytes(h);
    /* A genuinely foreign buffer: libc malloc, outside the wok allocator. */
    uint8_t* buf = (uint8_t*)malloc(5);
    for (int i = 0; i < 5; i++) buf[i] = (uint8_t)i;
    WokObj* p = wok_foreign_bytes_alloc(h, buf, 5);
    assert(wok_tag(p) == WOK_FOREIGN_BYTES_TAG);
    assert(wok_foreign_bytes_ptr(p) == buf);
    assert(wok_foreign_bytes_len(p) == 5);
    assert(wok_stat_peak_bytes(h) >= base + 24);          /* the 24B handle is charged */
    /* Drop sequence the Haskell host performs: foreign free FIRST, then wok_free. */
    free(buf);                                            /* the foreign free (libc) */
    p->rc = 0u;                                           /* host decremented to 0 */
    wok_free(h, p);                                       /* recycle the 24B handle */
    assert(wok_stat_live(h) == 0);
    wok_heap_free(h);
    printf("ok test_foreign_bytes_cell\n");
}
```

For the negative control, gate a leaking variant behind a define (mirroring `WOK_RC_PHYSICAL_TEST_HOOK`): a copy of the test that omits `free(buf)`; running it under LSan must report the 5-byte buffer as leaked. Add the define to a dedicated `run` line in `scripts/asan-runtime.sh` if a separate invocation is the cleanest way to assert the leak, OR document running it manually. (Keep the default test suite leak-free.)

- [ ] **Step 5: Run the C sanitizer gate.**

Run: `bash scripts/asan-runtime.sh`
Expected: every label passes; `test_foreign_bytes_cell` prints `ok`; no ASan/UBSan/LSan errors.

- [ ] **Step 6: Commit.**

```bash
git add runtime/wok_rc.h runtime/wok_rc.c runtime/test/wok_rc_test.c scripts/asan-runtime.sh
git commit -m "feat(ffi): WokForeignBytes C cell (tag 0xFFFB) + ASan lifecycle test"
```

---

## Task 2: RC interpreter — NForeignBytes node, adopt alloc, foreign-free drop

**Goal:** The RC interpreter can allocate an adopted foreign-bytes value (real libc buffer on CHeap, abstract node charging a 24B handle), read its bytes through the existing accessor, and drop it by running the libc free at refcount-zero — with a store-level unit test proving stats balance and no double-free.

**Files:**
- Modify: `src/Wok/Interp/RC/Heap.hs` (3 imports, after line 58)
- Modify: `src/Wok/Interp/RC/Value.hs` (node, tag constant, internTag, alloc, dropAddr, every Node matcher)
- Modify: `src/Wok/Interp/RC/Prim.hs` (`bytesBytes`/`bytesViaDeref` arms)
- Test: `test/Spec.hs` (a store-algebra unit test group)

**Acceptance Criteria:**
- [ ] `NForeignBytes` is a Node variant; `wouldBeCBytes (NForeignBytes _) = 24`, `nodeValues (NForeignBytes _) = []`, `nodeCEligible (NForeignBytes _) = False`; all Node matchers compile under `-Werror` (exhaustiveness).
- [ ] `0xFFFB` is in the `internTag` skip set; `wokForeignBytesTag = 0xFFFB` exists.
- [ ] On CHeap, `alloc (NForeignBytes bs)` libc-`malloc`s a real buffer, copies `bs`, adopts it via `wok_foreign_bytes_alloc`, charges 24.
- [ ] `bytesBytes` returns the correct bytes for a `0xFFFB` cell (reads `data_ptr`/`len`); `bytesViaDeref` handles abstract `NForeignBytes`.
- [ ] `dropAddr` on a `0xFFFB` cell frees the foreign buffer (libc free) before `wok_free`, charges back 24, and double-drop after dup is balanced and crash-free.
- [ ] A store-level unit test (both backends) covers alloc→read→drop with stats returning to baseline.

**Verify:** `cabal test wok-tests --test-options='-p "foreign bytes store"'` → PASS; `cabal build` clean under `-Werror`.

**Steps:**

- [ ] **Step 1: Add the FFI imports** in `src/Wok/Interp/RC/Heap.hs` after line 58:

```haskell
foreign import ccall unsafe "wok_foreign_bytes_alloc" wokForeignBytesAlloc :: Ptr WokHeap -> Ptr Word8 -> Word64 -> IO (Ptr WokObj)
foreign import ccall unsafe "wok_foreign_bytes_ptr"   wokForeignBytesPtr   :: Ptr WokObj -> IO (Ptr Word8)
foreign import ccall unsafe "wok_foreign_bytes_len"   wokForeignBytesLen   :: Ptr WokObj -> IO Word64
```

- [ ] **Step 2: Add the node, the tag constant, and the internTag skip** in `src/Wok/Interp/RC/Value.hs`.

Node (next to `NBytes`, ~line 695) — export it in the module header's `Node(..)` if listed:

```haskell
  | NForeignBytes ByteString
  -- ^ An ADOPTED foreign byte buffer (FFI Slice 1). On 'CHeap' this is a
  -- 'WokForeignBytes' cell (tag 0xFFFB) pointing at a libc-malloc'd buffer that
  -- wok frees (libc free) at refcount-zero. On 'AbstractHeap' it holds the bytes
  -- for op/output faithfulness but charges a FIXED 24 B handle ('wouldBeCBytes'),
  -- modeling that the buffer is off-heap -- so the oracle pins the zero-copy
  -- saving vs a copy-in 'NBytes'. No child refs ('nodeValues' = []), like 'NBytes'.
```

Tag constant (next to `wokBytesTag`, ~line 1064):

```haskell
-- | The reserved C tag for adopted foreign-bytes cells (WOK_FOREIGN_BYTES_TAG).
-- 'internTag' never assigns this to a constructor.
wokForeignBytesTag :: Word32
wokForeignBytesTag = 0xFFFB
```

internTag skip (lines 1034-1037) — add `0xFFFB` FIRST (it is the lowest reserved value, and the bumps must run in ascending order):

```haskell
        wF  = if raw >= wokForeignBytesTag then raw + 1 else raw
        w0  = if wF  >= wokBytesTag        then wF  + 1 else wF
        w1  = if w0  >= wokStringViewTag   then w0  + 1 else w0
        w2  = if w1  >= wokStringTag       then w1  + 1 else w1
        w   = if w2  >= wokArrayTag        then w2  + 1 else w2
```

(Update the reserved-tag comment block at ~1030 to list `0xFFFB`.)

- [ ] **Step 3: Add every Node-matcher arm** (the `-Werror` exhaustiveness sweep). At minimum:

```haskell
-- nodeValues (~2395): no counted children (foreign buffer is not a wok value)
nodeValues (NForeignBytes _)    = []

-- wouldBeCBytes (~1908): fixed 24B handle (NOT the buffer length)
wouldBeCBytes (NForeignBytes _) = 24

-- nodeCEligible (~1873): own dedicated path, not NCon slot encoding
nodeCEligible (NForeignBytes _) = False
```

Then `cabal build` and fix every remaining non-exhaustive-pattern warning (`-Werror`): search for other `NBytes`/`NString` matchers (`deref`/`derefPure` synthesis, `renderNode`/`show`, any `cascadeChildren` special-arm — none needed since `nodeValues=[]` makes the generic cascade empty). Mirror the `NBytes` arm for each.

- [ ] **Step 4: Add the CHeap adopt allocator and `alloc` dispatch** in `src/Wok/Interp/RC/Value.hs`.

Dispatch (next to the `NBytes` arm, ~1633):

```haskell
alloc (NForeignBytes bs) s = case stBackend s of
  CHeap hp     -> allocForeignBytes hp bs s
  AbstractHeap -> pure (allocPure (NForeignBytes bs) s)
```

The allocator (next to `allocNBytes`, ~1782) — uses `Foreign.Marshal.Alloc.mallocBytes` (libc malloc, off the wok heap) + `copyBytes`; charges the 24B handle:

```haskell
-- | Adopt a foreign byte buffer into a 'WokForeignBytes' cell. The buffer is
-- libc-malloc'd HERE (off the wok heap) to model a genuine C->RC handoff; the
-- cell stores the raw pointer and wok frees it (libc free) at refcount-zero in
-- 'dropAddr'. Charges the fixed 24 B handle, NOT the buffer (foreign memory).
allocForeignBytes :: Ptr WokHeap -> ByteString -> Store -> RC (Addr, Store)
allocForeignBytes hp bs s = do
  let byteLen = fromIntegral (BS.length bs) :: Word64
  dptr <- liftIO (mallocBytes (BS.length bs))     -- Foreign.Marshal.Alloc: libc malloc
  liftIO $ BS.useAsCStringLen bs (\(src, len) -> copyBytes dptr (castPtr src) len)
  p    <- liftIO (H.wokForeignBytesAlloc hp dptr byteLen)
  pure (CAddr p, s { stStats = recordAlloc 24 (stStats s) })
```

Add `import Foreign.Marshal.Alloc (mallocBytes, free)` (and ensure `copyBytes`/`castPtr` are imported — they already are for `allocNBytes`).

- [ ] **Step 5: Add the `dropAddr` foreign-free arm** in `src/Wok/Interp/RC/Value.hs` (the CHeap free path ~2245-2279). In the `bytes` tag dispatch add a `wokForeignBytesTag -> pure 24` branch; in the `kids` dispatch add the foreign-free branch (read the pointer, libc-free it, return no cascade children):

```haskell
-- in the `bytes` computation (next to the wokBytesTag branch ~2245):
                           else if tid == wokForeignBytesTag
                             then pure 24
                             else do { ar <- liftIO (H.wokArity p); pure (8 + 8 * fromIntegral (ar :: Word32)) }

-- in the `kids` computation (next to the wokBytesTag branch ~2277):
                          else if tid == wokForeignBytesTag
                            then do
                              dptr <- liftIO (H.wokForeignBytesPtr p)  -- read BEFORE wok_free
                              liftIO (Foreign.Marshal.Alloc.free dptr) -- the foreign free (libc)
                              pure []                                   -- buffer is not a wok child
                            else countedRefs <$> liftIO (readCConValues p s)
```

(`wok_free` is then called by the existing line ~2281; it recycles the 24B cell and never touches `dptr`.)

- [ ] **Step 6: Tag-dispatch the byte accessor** in `src/Wok/Interp/RC/Prim.hs` (`bytesBytes` ~1075 and `bytesViaDeref` ~1089):

```haskell
bytesBytes (RVBox a@(CAddr p)) s = case stBackend s of
  CHeap _ -> do
    tid <- liftIO (H.wokTag p)
    if tid == wokBytesTag
      then do
        blen    <- liftIO (H.wokBytesLen p)
        dataPtr <- liftIO (H.wokBytesData p)
        liftIO (BS.packCStringLen (castPtr dataPtr, fromIntegral blen))
      else if tid == wokForeignBytesTag
        then do
          blen    <- liftIO (H.wokForeignBytesLen p)
          dataPtr <- liftIO (H.wokForeignBytesPtr p)
          liftIO (BS.packCStringLen (castPtr dataPtr, fromIntegral blen))
        else bytesViaDeref (RVBox a) s
  AbstractHeap -> bytesViaDeref (RVBox a) s
bytesBytes v s = bytesViaDeref v s

-- bytesViaDeref (~1092): add the abstract NForeignBytes arm
    NBytes bs        -> pure bs
    NForeignBytes bs -> pure bs
    _                -> throwE (PrimError (Tx.pack "Bytes: not a Bytes cell"))
```

(Import `wokForeignBytesTag` from `Wok.Interp.RC.Value`.)

- [ ] **Step 7: Write a store-level unit test** in `test/Spec.hs` (a new group, modeled on the existing `wouldBeCBytes`/rc-bytes store tests). Run on BOTH backends via the existing store-test harness:

```haskell
-- Group "foreign bytes store":
-- 1. alloc (NForeignBytes (BS.pack [0..4])); deref/bytesBytes == the 5 bytes.
-- 2. peak_bytes delta == 24 (handle), NOT wouldBeCBytes 5.
-- 3. dup then drop twice: live returns to baseline, no double-free error.
-- 4. wouldBeCBytes (NForeignBytes anything) == 24.
```

(Use the same store-construction helpers the existing E6 `NBytes` store tests use; assert on `stCurBytes`/`stLive` after alloc and after drop.)

- [ ] **Step 8: Build and test.**

Run: `cabal build` (must be clean under `-Werror`), then `cabal test wok-tests --test-options='-p "foreign bytes store"'`
Expected: build clean; the store tests PASS.

- [ ] **Step 9: Commit.**

```bash
git add src/Wok/Interp/RC/Heap.hs src/Wok/Interp/RC/Value.hs src/Wok/Interp/RC/Prim.hs test/Spec.hs
git commit -m "feat(ffi): NForeignBytes adopt path (libc-free at rc-0, 24B handle accounting)"
```

---

## Task 3: Host-blessed producer prims + prelude + registration

**Goal:** Two deterministic producer prims — `__ffi_demo_copy` (Tier 1 copy-in) and `__ffi_demo_adopt` (Tier 2 adopt) — usable from wok, in both interpreters, feeding `fromBytes`.

**Files:**
- Modify: `src/Wok/Interp/RC/Prim.hs` (two `RCPrim`s + table entries)
- Modify: `src/Wok/Interp/Prim.hs` (two reference `Prim`s + table entries)
- Modify: `src/Wok/IR/PrimNames.hs` (two names, only if an analysis keys on them — see Step 1)
- Modify: `prelude/Std/Bytes.wok` (two `extern` decls)

**Acceptance Criteria:**
- [ ] `__ffi_demo_copy n` and `__ffi_demo_adopt n` return a `Bytes` of `n` bytes with the deterministic pattern `byte i = i mod 256`, on the reference interpreter and both RC backends.
- [ ] Copy uses `alloc (NBytes ...)`; adopt uses `alloc (NForeignBytes ...)`.
- [ ] Both are callable from a wok program and compose with `fromBytes`/`length`/`index`/`toList`.
- [ ] Registered following the exact E6 `fromBytes`/`toBytes` pattern (no `extern`-gate or analysis regressions).

**Verify:** `cabal test wok-tests --test-options='-p "rc ffi bytes"'` → PASS (after Task 4 adds the corpus); for this task, a smoke wok program in `test/rc-ffi-bytes/00-smoke.wok` runs identically on all three backends.

**Steps:**

- [ ] **Step 1: Decide registration shape.** Inspect how E6 registered `fromBytes`/`toBytes`: `rg -n "bytesFromBytesName|bytesFromBytesRC|bytesPrims" src/Wok/IR/PrimNames.hs src/Wok/Interp/RC/Prim.hs src/Wok/Interp/Prim.hs`. Mirror it exactly: add `ffiDemoCopyName = "__ffi_demo_copy"` and `ffiDemoAdoptName = "__ffi_demo_adopt"` in `PrimNames.hs` next to `bytesFromBytesName`, and add the prims to the `bytesPrims`/`bytesPrimsRC` lists keyed under `stdBytesModule`.

- [ ] **Step 2: Reference-interpreter prims** in `src/Wok/Interp/Prim.hs` (next to `bytesFromBytesP` ~734). The deterministic pattern is shared; both tiers produce identical `VBytes` (ownership is not observable in the pure model):

```haskell
demoPattern :: Int -> BS.ByteString
demoPattern n = BS.pack [ fromIntegral (i `mod` 256) | i <- [0 .. n - 1] ]

ffiDemoCopyP :: Prim
ffiDemoCopyP = mkPrim PN.ffiDemoCopyName 1 $ \args -> case args of
  [VLit (LInt n)] -> Right (PRDone (VBytes (demoPattern (fromIntegral n))))
  _               -> Left (ArityError PN.ffiDemoCopyName)

ffiDemoAdoptP :: Prim
ffiDemoAdoptP = mkPrim PN.ffiDemoAdoptName 1 $ \args -> case args of
  [VLit (LInt n)] -> Right (PRDone (VBytes (demoPattern (fromIntegral n))))
  _               -> Left (ArityError PN.ffiDemoAdoptName)
```

(Confirm the U64 literal carrier is `VLit (LInt _)` by checking `bytesFromListP`/`fromList`'s arg handling; match it.)

- [ ] **Step 3: RC-interpreter prims** in `src/Wok/Interp/RC/Prim.hs` (next to `bytesFromBytesRC` ~1178). Copy goes through `alloc (NBytes ..)`, adopt through `alloc (NForeignBytes ..)`:

```haskell
ffiDemoCopyRC :: RCPrim
ffiDemoCopyRC = RCPrim PN.ffiDemoCopyName 1 [] $ \args s -> case args of
  [RVLit (LInt n)] -> do
    (a, s1) <- alloc (NBytes (demoPattern (fromIntegral n))) s
    pure (PRDone (RVBox a), s1)
  _ -> throwE (ArityError PN.ffiDemoCopyName)

ffiDemoAdoptRC :: RCPrim
ffiDemoAdoptRC = RCPrim PN.ffiDemoAdoptName 1 [] $ \args s -> case args of
  [RVLit (LInt n)] -> do
    (a, s1) <- alloc (NForeignBytes (demoPattern (fromIntegral n))) s
    pure (PRDone (RVBox a), s1)
  _ -> throwE (ArityError PN.ffiDemoAdoptName)
```

(Reuse `demoPattern` — define once and import, or duplicate in both prim modules if they don't share a helper module; match the codebase convention. Confirm the RC literal carrier is `RVLit (LInt _)`.)

- [ ] **Step 4: Prelude decls** in `prelude/Std/Bytes.wok` (append):

```wok
-- FFI bytes-in (Slice 1): host-blessed DETERMINISTIC foreign producers that
-- demonstrate the C->RC ownership handoff. __ffi_demo_copy copies the foreign
-- buffer into a wok-owned cell (Tier 1); __ffi_demo_adopt adopts it and frees it
-- at refcount-zero (Tier 2). Transitional fixtures: superseded by the Slice-2
-- `foreign module` surface. Pure-typed (no `IO` effect yet; deterministic).
extern __ffi_demo_copy  : U64 -> Bytes
extern __ffi_demo_adopt : U64 -> Bytes
```

- [ ] **Step 5: Smoke test.** Create `test/rc-ffi-bytes/00-smoke.wok`:

```wok
module Main
import Std.Base
import Std.Bytes

-- both producers yield 5 deterministic ASCII bytes (0..4); fromBytes accepts them
main : U64
main =
  case fromBytes (__ffi_demo_copy 5) of
    Some _ -> case fromBytes (__ffi_demo_adopt 5) of
      Some _ -> length (__ffi_demo_adopt 5)
      None   -> 0
    None -> 0
```

- [ ] **Step 6: Build, then run the smoke program on all three backends** (use the existing differential-run harness the way E6's rc-bytes tests are wired; Task 4 formalizes the corpus). Expected `main = 5` on reference, RC-abstract, RC-CHeap.

Run: `cabal build && cabal test wok-tests --test-options='-p "ffi bytes smoke"'`
Expected: PASS (5 on all backends).

- [ ] **Step 7: Commit.**

```bash
git add src/Wok/Interp/Prim.hs src/Wok/Interp/RC/Prim.hs src/Wok/IR/PrimNames.hs prelude/Std/Bytes.wok test/rc-ffi-bytes/00-smoke.wok
git commit -m "feat(ffi): __ffi_demo_copy / __ffi_demo_adopt host-blessed producers + Std.Bytes decls"
```

---

## Task 4: Differential-oracle corpus, properties, and the zero-copy-saving pin

**Goal:** A `test/rc-ffi-bytes/` corpus and `test/Spec.hs` wiring that runs both producers through the 3-way differential oracle (output + stats), plus the property that adopt's `peak_bytes` is lower than copy's by exactly `wouldBeCBytes(n) - 24`.

**Files:**
- Create: `test/rc-ffi-bytes/*.wok` (corpus)
- Modify: `test/Spec.hs` (wire the corpus into the rc differential + stats + C-heap parity, mirroring `rcBytesFiles`; add the property group)

**Acceptance Criteria:**
- [ ] The corpus runs on reference + RC-abstract + RC-CHeap with identical output.
- [ ] `peak_bytes` agrees between RC-abstract and RC-CHeap for every corpus program (the existing oracle invariant).
- [ ] A test pins: for the SAME `n`, `__ffi_demo_adopt` reports `peak_bytes` lower than `__ffi_demo_copy` by exactly `wouldBeCBytes(n) - 24` (the zero-copy saving), on both RC backends.
- [ ] Corpus covers: valid UTF-8 (small ASCII `n`), invalid UTF-8 (`n >= 129` so high bytes appear → `fromBytes = None`), `length`/`index`/`toList` on adopted buffers, eqBytes across copy vs adopt vs `fromList`.

**Verify:** `cabal test wok-tests --test-options='-p "rc ffi bytes"'` → PASS (all corpus + the saving-pin property).

**Steps:**

- [ ] **Step 1: Author the corpus** in `test/rc-ffi-bytes/` (one concern per file), e.g.:
  - `01-copy-valid.wok` — `fromBytes (__ffi_demo_copy 10)` → `Some` (ASCII 0..9), return `length`.
  - `02-adopt-valid.wok` — same via `__ffi_demo_adopt`.
  - `03-adopt-invalid.wok` — `fromBytes (__ffi_demo_adopt 200)` → `None` (byte 128.. are not valid UTF-8); return 0/1.
  - `04-adopt-index.wok` — `index (__ffi_demo_adopt 10) 3` → 3.
  - `05-adopt-tolist.wok` — `toList (__ffi_demo_adopt 4)` → `[0,1,2,3]`, sum it.
  - `06-eq-copy-adopt.wok` — `eqBytes (__ffi_demo_copy 6) (__ffi_demo_adopt 6)` → True; vs `fromList [0,1,2,3,4,5]` → True.

  Each `module Main; import Std.Base; import Std.Bytes` and a `main : U64`. Use the actual deterministic pattern (`i mod 256`) when writing expected values.

- [ ] **Step 2: Wire the corpus into `test/Spec.hs`.** Find the E6 wiring: `rg -n "rcBytesFiles|rc-bytes" test/Spec.hs`. Add `rcFfiBytesFiles <- findByExtension [".wok"] "test/rc-ffi-bytes"` and feed it through the SAME combinators E6 used (rc differential + rc stats + C-heap parity). Programs are handler-free.

- [ ] **Step 3: Add the zero-copy-saving property** (a `testCase` or `testProperty` in the rc-ffi-bytes group). For a set of `n` values, run `__ffi_demo_copy n` and `__ffi_demo_adopt n` under the RC-CHeap (and abstract) stat harness and assert:
  `peakBytes(adopt n) == peakBytes(copy n) - (wouldBeCBytes (NBytes (demoPattern n)) - 24)`
  i.e. the adopt handle saves exactly the buffer's logical size minus the 24B handle. (Use the existing stat-extraction the rc-bytes peak_bytes oracle uses.)

- [ ] **Step 4: Run.**

Run: `cabal test wok-tests --test-options='-p "rc ffi bytes"'`
Expected: all corpus programs PASS on three backends; the saving-pin property PASSES.

- [ ] **Step 5: Commit.**

```bash
git add test/rc-ffi-bytes test/Spec.hs
git commit -m "test(ffi): rc-ffi-bytes differential corpus + zero-copy peak_bytes saving pin"
```

---

## Task 5: Soundness — leak/double-free death test + region-escape adversarial

**Goal:** Prove the adopt path is leak-free and double-free-free under dup/drop, and that an adopted `Bytes` that escapes its activation is routed to the counted Heap (never the arena).

**Files:**
- Modify: `test/Spec.hs` (a soundness group)
- Create: `test/rc-ffi-bytes/escape-*.wok` (region adversarial programs)
- Reference: `src/Wok/IR/Region.hs:513-514` (verify the `TcBytes` fence covers the adopt path; add a fence-coverage note/test, no code change expected)

**Acceptance Criteria:**
- [ ] A dup-then-drop test on an adopted value: `live`/`cur_bytes` return to baseline, no double-free error, the foreign buffer is freed exactly once (verified by stats balance + the Task-1 C ASan lifecycle test; document the linkage).
- [ ] A region-escape program where an adopted `Bytes` escapes its defining activation runs correctly on all three backends and is NOT routed to the activation arena (it stays counted-Heap) — confirmed because `Region.isStringType` returns True for `TcBytes`.
- [ ] The whole `test/rc-ffi-bytes` corpus is leak-balanced (rc-stats live == 0 at program end) on both RC backends.

**Verify:** `cabal test wok-tests --test-options='-p "ffi bytes soundness"'` → PASS; `bash scripts/asan-runtime.sh` still clean.

**Steps:**

- [ ] **Step 1: Dup/drop balance test** in `test/Spec.hs`. Build an adopt value at the store level, `incref` it (dup), `dropAddr` twice, assert: first drop only decrements (rc 2→1, no free, buffer intact), second drop frees the buffer + recycles the cell, `stLive`/`stCurBytes` return to the pre-alloc baseline, and no `double-free` error is thrown. (Mirror the E6 NBytes drop test; the new assertion is that the foreign-free happens on the final drop only.)

- [ ] **Step 2: Region-escape adversarial programs** in `test/rc-ffi-bytes/`:
  - `escape-return.wok` — a helper that builds `__ffi_demo_adopt 8` and returns it to `main` (escapes the helper's activation); `main` does `length` on it. Expected: correct length, runs on all three backends. (If adopted Bytes were wrongly routed to the helper's arena, it would be freed on the helper's return → a UAF the CHeap/ASan path would surface.)

  Wire these into the differential + (where applicable) the region/arena test harness the way R1's escape tests are wired (`rg -n "arena|escape" test/Spec.hs`).

- [ ] **Step 3: Confirm the fence.** Verify `src/Wok/IR/Region.hs:513-514` (`isStringType (CTCon TcBytes []) = True`) covers the adopt path — `NForeignBytes` is still `TcBytes`-typed, so it inherits the Heap fence; add a short comment at the fence noting it now also guards adopted foreign-bytes, and a focused test that the escape program above does not increment arena bytes for the adopted value (reuse the R1 arena-bytes assertion).

- [ ] **Step 4: Leak-balance sweep.** Confirm every `test/rc-ffi-bytes` program ends with rc-stats `live == 0` on both RC backends (the corpus harness from Task 4 should already assert this; if not, add the assertion).

- [ ] **Step 5: Run both gates.**

Run: `cabal test wok-tests --test-options='-p "ffi bytes"'` and `bash scripts/asan-runtime.sh`
Expected: all PASS; sanitizers clean.

- [ ] **Step 6: Commit.**

```bash
git add test/Spec.hs test/rc-ffi-bytes
git commit -m "test(ffi): adopt dup/drop leak+double-free death test + region-escape adversarial"
```

---

## Self-review

- **Spec coverage:** Tier 1 (Task 3 copy producer + Task 2 reuse of allocNBytes), Tier 2 cell (Task 1) + RC adopt/drop (Task 2) + producer (Task 3); fromBytes integration (Tasks 3-4); accounting/handle-charge + oracle saving pin (Task 2 unit + Task 4 property); soundness invariants — fromBytes-only-door (corpus uses it), Region fence (Task 5 Step 3), no double-free/UAF (Task 1 C ASan + Task 5 dup/drop), no-C-chase (Task 1 `wok_free` arm + comment), allocator-mismatch (libc free, Task 2 Step 5), reserved-tag exclusion (Task 2 Step 2 internTag). All spec sections map to a task.
- **Placeholder scan:** no TBD/TODO; every code step shows code; commands are concrete.
- **Type consistency:** `NForeignBytes`, `wokForeignBytesTag`, `wokForeignBytesAlloc/Ptr/Len`, `allocForeignBytes`, `demoPattern`, `ffiDemo{Copy,Adopt}{Name,P,RC}` used consistently across tasks; the 24B handle charge is uniform (alloc Step 4, drop Step 5, wouldBeCBytes Step 3, property Task 4 Step 3).

## Model-tier routing

- Task 1 (C runtime + ASan test): **standard** — the genuinely-new C mechanism, but fully specified; escalate to frontier if the `wok_free` dispatch / negative control needs judgment.
- Task 2 (RC adopt path): **standard** — multi-file integration + the drop/accounting interplay; the highest-judgment task, escalate to frontier if BLOCKED.
- Task 3 (producers + prelude + registration): **standard** — dual-interpreter + table registration; well-specified.
- Task 4 (corpus + saving pin): **standard** — test design.
- Task 5 (soundness death test + region): **standard** — test design; reviewed hardest at the whole-branch Opus deep review (test soundness).

Per-task spec + code-quality reviewers run at the **standard** tier (Sonnet). The final whole-branch review (after all tasks) stays at session level (Opus), then `/code-review high`.
