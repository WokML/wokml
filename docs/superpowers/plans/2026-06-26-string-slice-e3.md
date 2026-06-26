# String Slice E3 (small-string optimization) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers-extended-cc:subagent-driven-development (recommended) or superpowers-extended-cc:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make short strings (≤ 7 UTF-8 bytes) live inline in the one-word value with zero heap allocation, a faithful continuation of the slice-2 nullary-immediate mechanism.

**Architecture:** A new `Addr` variant `InlineStr !ByteString` (uncounted), intercepted at the shared `alloc (NString bs)` chokepoint and synthesized back to an `NString` node at `deref` — so every existing string operation keeps working unchanged. A short string that is a constructor field packs into one 64-bit slot via a sub-tag stolen inside the existing `11` `Inline` slot class (a paired `encodeSlotC`/`decodeSlotC` change). The C runtime is unchanged.

**Tech Stack:** Haskell (GHC, `-Wall -Werror -Wincomplete-patterns`), the RC interpreter (`src/Wok/Interp/RC/`), tasty + Hspec + QuickCheck, the three-way differential oracle.

**User decisions (already made):**
- "7 bytes is a bit smaller but I am okay with it as long as it composes well" → `maxInlineStr = 7`, fixed, documented.
- Fold short string literals into immediates (owning-position automatic; static-CAF seeding optional).
- StringZilla's 22-byte `sz_string_t` is explicitly out of scope (it would widen the value model and fight RC sharing).
- Autonomous execution authorized; subagent-driven in this session.

**Spec:** `docs/superpowers/specs/2026-06-26-string-slice-e3-design.md`

---

### Task 1: The inline short-string value model

**Goal:** Short strings (≤ 7 bytes) become uncounted inline `Addr` values with zero allocation; `deref` synthesizes them back so all string operations keep working; dup/drop are no-ops.

**Files:**
- Modify: `src/Wok/Interp/RC/Value.hs` (the `Addr` type at :159; `alloc (NString …)` at :1427; `deref`/`derefPure` at :1741/:1837; `isInline`/`isStaticAddr`/`isArenaAddr`/`isUncounted`; and the no-op/error arms at the sites listed below)
- Test: `test/Spec.hs` (a new inline-allocation unit; the spec calls it `rcInlineStringTests`)

**Acceptance Criteria:**
- [ ] `Addr` has a fourth constructor `InlineStr !ByteString`.
- [ ] `alloc (NString bs)` returns `(InlineStr bs, s)` with NO `recordAlloc` when `BS.length bs <= maxInlineStr`, on BOTH backends; the heap path is unchanged for longer strings.
- [ ] `deref (InlineStr bs)` and `derefPure (InlineStr bs)` return `Cell 0 (NString bs) 0`.
- [ ] `isInline (InlineStr _) = True` (so `isUncounted` covers it); `incref`/`dropAddr`/`dropReuse` are no-ops on it.
- [ ] The project compiles under `-Werror -Wincomplete-patterns` (every `Addr`-matching site has an `InlineStr` arm).
- [ ] A program building a ≤ 7-byte string allocates 0 wok cells on both backends; an 8-byte string allocates exactly 1.
- [ ] The full existing test suite stays green.

**Verify:** `cabal test 2>&1 | tail -20` → all suites pass; `cabal test --test-options='-p "InlineString"'` → the new unit passes.

**Steps:**

- [ ] **Step 1: Write the failing test** in `test/Spec.hs` (add `rcInlineStringTests` and wire it into the RC-string test tree). It drives a tiny program through both backends and asserts the cell-count delta.

```haskell
-- A <=7-byte string allocates 0 cells; an 8-byte string allocates 1.
-- Uses the existing RC harness helpers (onBothBackends / runRCProgram / stAllocs);
-- match the surrounding tests' helper names exactly when wiring this in.
rcInlineStringTests :: TestTree
rcInlineStringTests = testGroup "InlineString"
  [ testCase "<=7-byte string allocates no cell (both backends)" $
      onBothBackends $ \backend -> do
        stats <- statsOf backend "main = \"abcdefg\""      -- 7 bytes
        stAllocs stats @?= 0
  , testCase "8-byte string allocates one WokString cell (both backends)" $
      onBothBackends $ \backend -> do
        stats <- statsOf backend "main = \"abcdefgh\""     -- 8 bytes
        stAllocs stats @?= 1
  , testCase "inline string round-trips through deref" $
      onBothBackends $ \backend -> do
        out <- runProg backend "main = \"hi\""
        out @?= "hi"
  ]
```

- [ ] **Step 2: Run the test, watch it fail to compile** (`InlineStr` does not exist yet).

Run: `cabal test --test-options='-p "InlineString"' 2>&1 | tail -20`
Expected: build error (`Data constructor not in scope: InlineStr`) or assertion failure (allocs == 1, not 0).

- [ ] **Step 3: Add the `InlineStr` constructor + `maxInlineStr`.**

In `src/Wok/Interp/RC/Value.hs`, extend the `Addr` type (keep the existing deriving):

```haskell
data Addr = HAddr Int | CAddr (Ptr WokObj) | Inline Word32 | InlineStr !ByteString
  deriving (Eq, Ord, Show)
```

Add the constant near the other allocation helpers:

```haskell
-- | Max UTF-8 byte length stored inline in the one-word value (slice E3). The
-- one-machine-word bit-layout maximum: 62 payload bits - 3-bit length = 7 bytes.
-- Fixed, not tunable; a longer string keeps its WokString cell.
maxInlineStr :: Int
maxInlineStr = 7
```

- [ ] **Step 4: Intercept at the `alloc (NString …)` chokepoint.**

Replace the existing `alloc (NString bs)` clause (around :1427) with the length-gated form:

```haskell
alloc (NString bs) s
  | BS.length bs <= maxInlineStr = pure (InlineStr bs, s)   -- inline: no cell, no recordAlloc, both backends
  | otherwise = case stBackend s of
      CHeap hp     -> allocNString hp bs s
      AbstractHeap -> pure (allocPure (NString bs) s)
```

- [ ] **Step 5: Synthesize at deref.**

Add arms beside the existing `Inline` arms (`deref` :1741, `derefPure` :1837):

```haskell
deref (InlineStr bs) _ = pure (Cell 0 (NString bs) 0)
-- and:
derefPure (InlineStr bs) _ = Right (Cell 0 (NString bs) 0)
```

- [ ] **Step 6: Mark it inline/uncounted + add every required `Addr` arm.**

Add `InlineStr` arms that PARALLEL the existing `Inline` arm at each site. The behavioral ones:

```haskell
isInline (InlineStr _)    = True                       -- :1092 (isUncounted then covers it)
isStaticAddr (InlineStr _) = False                     -- :1086
isArenaAddr (InlineStr _) _ = False                    -- :1120
incref (InlineStr _) s     = pure s                    -- :1872
increfPure (InlineStr _) s = Right s                   -- :1879
dropAddrStepPure (InlineStr _) s = Right (Nothing, s)  -- :2027
dropReuse (InlineStr _) s  = pure (RVReuse Nothing, s) -- :2136
freeReservation (InlineStr _, _) s = pure s            -- :553
moveOutContPure (InlineStr _) _ = Left (PrimError (Tx.pack "resume: inline string is not a continuation"))  -- :600
writeStatic (InlineStr _) _ _   = error "writeStatic: an inline string has no cell to overwrite"             -- :1673
writeNodePure (InlineStr _) _ _ = Left (PrimError (Tx.pack "writeNode: inline string has no cell"))          -- :1690
```

In `dropAddr`'s `go` loop (:1903), add beside `go (Inline _ : rest)`:

```haskell
    go (InlineStr _ : rest) s = go rest s
```

For `allocAt` (:2237), `arrayUnique` (:2526), and `arraySetSlotInPlace` (:2566): read the existing `Inline _` arm at each site and add an `InlineStr _` arm with the SAME behavior (an inline string is never a reuse shell or a mutable array, so these mirror `Inline`: an error/`Left` for `allocAt`/`arraySetSlotInPlace`, `pure False` for `arrayUnique`). Then rely on `-Werror -Wincomplete-patterns`: build, and add an arm anywhere the compiler reports a non-exhaustive `Addr` match until it is clean.

- [ ] **Step 7: Confirm `encodeSlotC` falls back safely (no field-slot work yet).**

Do NOT touch `encodeSlotC`/`decodeSlotC` in this task. `encodeSlotC (RVBox (InlineStr _))` hits the existing `encodeSlotC _ = Nothing` catch-all, so a constructor holding a short-string field simply falls the whole `NCon` back to the abstract heap (correct, just not yet C-encoded). Task 2 adds the slot encoding.

- [ ] **Step 8: Run the test + full suite.**

Run: `cabal build 2>&1 | tail -5 && cabal test 2>&1 | tail -20`
Expected: build clean under `-Werror`; the `InlineString` unit passes; all existing suites green.

- [ ] **Step 9: Commit.**

```bash
git add src/Wok/Interp/RC/Value.hs test/Spec.hs
git commit -m "feat(string): inline short strings (<=7B) as uncounted Addr (E3 Task 1)"
```

---

### Task 2: Slot encoding for inline-string constructor fields

**Goal:** A short string stored as a field of a C-heap constructor packs into one 64-bit slot via a sub-tag inside the existing `11` `Inline` slot class, so such constructors stay C-eligible and round-trip.

**Files:**
- Modify: `src/Wok/Interp/RC/Value.hs` (`encodeSlotC` at :1045, `decodeSlotC` at :1066)
- Test: `test/Spec.hs` (add `rcInlineStringSlotTests`)

**Acceptance Criteria:**
- [ ] The existing nullary `Inline` encoding moves from `(tid << 2) | 0b11` to `(tid << 3) | 0b011` (bit 2 = 0), and `decodeSlotC` reverses it with `>> 3`.
- [ ] A new inline-string encoding packs as `0b111 | (len << 3) | (bytesWord << 6)` with `len = BS.length bs` (0..7) and `bytesWord` the ≤ 7 bytes little-endian.
- [ ] `decodeSlotC`'s `KPointer` `11`-class branch tests bit 2: 0 → nullary `Inline`, 1 → `InlineStr`.
- [ ] A constructor with a short-string field AND a nullary-immediate sibling field is C-eligible on `CHeap`, and both fields round-trip (no cross-talk).
- [ ] `decodeSlotC` is total over all four `KPointer` cases (`00`/`01`/`11`+bit2=0/`11`+bit2=1).
- [ ] Full suite green; the three-way oracle agrees on a constructor-with-short-string-field corpus program.

**Verify:** `cabal test --test-options='-p "InlineStringSlot"'` → passes; `cabal test 2>&1 | tail -20` → all green.

**Steps:**

- [ ] **Step 1: Write the failing slot round-trip test** in `test/Spec.hs`.

```haskell
rcInlineStringSlotTests :: TestTree
rcInlineStringSlotTests = testGroup "InlineStringSlot"
  [ testCase "constructor with a short-string field round-trips on CHeap" $
      onBothBackends $ \backend -> do
        -- Pair couples a short string with a nullary immediate (True) as a sibling
        -- field, proving the bit-2 split does not cross-talk.
        out <- runProg backend
                 "data Pair = Pair String Bool\n\
                 \main = case Pair \"hi\" True of Pair s b -> s"
        out @?= "hi"
  ]
```

- [ ] **Step 2: Run it, watch it fail** (on `CHeap` the field currently forces an abstract-heap fallback; with the bit-2 change absent, the new encode path does not exist).

Run: `cabal test --test-options='-p "InlineStringSlot"' 2>&1 | tail -20`
Expected: FAIL or fallback-driven oracle mismatch.

- [ ] **Step 3: Change the nullary `Inline` encode/decode to free bit 2.**

In `encodeSlotC` (:1055), change the `Inline` arm:

```haskell
encodeSlotC (RVBox (Inline t))  = Just (KPointer, (fromIntegral t `shiftL` 3) .|. 0x3)   -- 0b011: bit2 = 0
```

Add the inline-string arm just below it (before the `encodeSlotC _ = Nothing` catch-all):

```haskell
encodeSlotC (RVBox (InlineStr bs)) = Just (KPointer, packInlineStr bs)
```

Add the packer helper near the slot functions:

```haskell
-- | Pack a <=7-byte string into a 'KPointer' slot word: low bits 0b111, then a
-- 3-bit length, then the bytes little-endian. Inverse of 'unpackInlineStr'.
packInlineStr :: ByteString -> Word64
packInlineStr bs =
  let len      = BS.length bs                                   -- 0..7 (invariant)
      bytesW   = BS.foldr (\b acc -> (acc `shiftL` 8) .|. fromIntegral b) 0 bs :: Word64
  in 0x7 .|. (fromIntegral len `shiftL` 3) .|. (bytesW `shiftL` 6)
```

- [ ] **Step 4: Split the `decodeSlotC` `11`-class branch on bit 2.**

Replace the `otherwise` line of `decodeSlotC KPointer` (:1073) so the `11` class checks bit 2:

```haskell
decodeSlotC KPointer w
  | w .&. 1 == 0 = RVBox (CAddr (wordPtrToPtr (WordPtr (fromIntegral w))))                 -- 00
  | w .&. 2 == 0 = RVBox (HAddr (fromIntegral ((fromIntegral w :: Int64) `shiftR` 2)))      -- 01
  | w .&. 4 == 0 = RVBox (Inline (fromIntegral (w `shiftR` 3)))                             -- 011 nullary
  | otherwise    = RVBox (InlineStr (unpackInlineStr w))                                    -- 111 inline string
```

Add the unpacker:

```haskell
-- | Inverse of 'packInlineStr': read the 3-bit length then that many bytes.
unpackInlineStr :: Word64 -> ByteString
unpackInlineStr w =
  let len    = fromIntegral ((w `shiftR` 3) .&. 0x7) :: Int
      bytesW = w `shiftR` 6
  in BS.pack [ fromIntegral (bytesW `shiftR` (8 * i)) | i <- [0 .. len - 1] ]
```

- [ ] **Step 5: Run the slot test + full suite.**

Run: `cabal test 2>&1 | tail -20`
Expected: `InlineStringSlot` passes; all existing suites green (the nullary-immediate tests still pass under the `<<3` re-encoding).

- [ ] **Step 6: Commit.**

```bash
git add src/Wok/Interp/RC/Value.hs test/Spec.hs
git commit -m "feat(string): pack inline-string fields into a 11-class slot sub-tag (E3 Task 2)"
```

---

### Task 3: Oracle corpus + QuickCheck properties

**Goal:** Pin the inline savings and cross-representation correctness with corpus programs and QuickCheck properties across all three backends.

**Files:**
- Modify: `test/Spec.hs` (extend the RC-string property group; the spec calls it `rcInlineStringPropertyTests`)
- Create/Modify: `test/rc-string/` corpus entries (follow the existing E1/E2 corpus pattern)

**Acceptance Criteria:**
- [ ] Corpus programs cover: `""`, `"/"`, a 7-byte and an 8-byte string, a short-string constructor field, `append` across the 7↔8 boundary, equality between an inline and a heap string of equal bytes, and a case-match on an inline-backed string variable — each run on all three backends.
- [ ] Property: any `bs` with `BS.length bs <= 7` round-trips (build then read bytes) to `bs`.
- [ ] Property: a ≤ 7-byte string allocates 0 cells; an 8-byte string allocates 1 — both RC backends.
- [ ] Property: an inline string stored as a constructor field and read back equals the original (with a nullary sibling field present).
- [ ] Property: `eqString` agrees with byte equality across mixed inline/heap representations.
- [ ] Property: `append a b` has bytes `a <> b` and is inline iff `BS.length (a<>b) <= 7`; all E1/E2 ops on inline inputs match the reference.
- [ ] ASan/LSan clean (`scripts/asan-runtime.sh`), physical invariant intact.

**Verify:** `cabal test 2>&1 | tail -20` → all green; `scripts/asan-runtime.sh 2>&1 | tail -5` → clean.

**Steps:**

- [ ] **Step 1: Add the properties** to `test/Spec.hs`, reusing the existing `onBothBackends` / reference comparison helpers (match their exact names from the surrounding E1/E2 property group).

```haskell
rcInlineStringPropertyTests :: TestTree
rcInlineStringPropertyTests = testGroup "InlineStringProps"
  [ testProperty "byte round-trip for <=7-byte strings" $
      \(ShortBytes bs) -> ioProperty $ do
        out <- buildThenRenderBytes bs            -- builds a String from bs, reads bytes back
        pure (out === bs)
  , testProperty "<=7 inline (0 cells), 8 heap (1 cell)" $
      \(Utf8 bs) -> ioProperty $ do
        n <- allocCountFor bs
        pure (n === if BS.length bs <= 7 then 0 else expectedHeapCells bs)
  , testProperty "eqString == byte equality across representations" $
      \(Utf8 a) (Utf8 b) -> ioProperty $ do
        r <- runEqString a b
        pure (r === (a == b))
  , testProperty "append: bytes concat, inline iff result <=7" $
      \(Utf8 a) (Utf8 b) -> ioProperty $ do
        (bytes, inline) <- runAppend a b
        pure (bytes === (a <> b) .&&. inline === (BS.length (a <> b) <= 7))
  ]
```

(`ShortBytes`/`Utf8` are `newtype` generators producing valid UTF-8; `ShortBytes` additionally caps length ≤ 7. Define them beside the existing E2 string generators, reusing whatever valid-UTF-8 generator E2 already added.)

- [ ] **Step 2: Add the corpus entries** under `test/rc-string/` following the E1/E2 file pattern (one program per case listed in the Acceptance Criteria; include the expected output and the asserted alloc counts where the harness supports it).

- [ ] **Step 3: Run the full suite.**

Run: `cabal test 2>&1 | tail -20`
Expected: all green, including the new `InlineStringProps` group and corpus.

- [ ] **Step 4: Run the sanitizers.**

Run: `scripts/asan-runtime.sh 2>&1 | tail -5`
Expected: clean (no new C allocation path; inline strings never reach the C heap).

- [ ] **Step 5: Commit.**

```bash
git add test/Spec.hs test/rc-string
git commit -m "test(string): inline-string oracle corpus + QuickCheck properties (E3 Task 3)"
```

---

### Task 4 (optional): Static seeding of short-literal CAFs

**Goal:** A top-level string-literal CAF of ≤ 7 bytes seeds as a static inline immediate instead of allocating on first evaluation, mirroring nullary CAFs.

**Files:**
- Modify: `src/Wok/Interp/RC/Machine.hs` (`reserveStatic` exclusion at :1087/:1092, and the mirroring eval guard at :1146)
- Test: `test/Spec.hs` (add one case to `rcInlineStringTests`)

**Acceptance Criteria:**
- [ ] The `not (isLStr l)` exclusion in `reserveStatic` is relaxed so a ≤ 7-byte `LStr` CAF is seeded (as the `InlineStr` immediate); a longer `LStr` CAF is still excluded (it allocates a counted cell).
- [ ] A program `foo = "/"` / `main = foo` allocates 0 cells on both backends.
- [ ] Full suite green; no change to longer-literal-CAF behavior.

**Verify:** `cabal test --test-options='-p "InlineString"'` → passes including the CAF case; `cabal test 2>&1 | tail -20` → all green.

**Steps:**

- [ ] **Step 1: Add the failing CAF case** to `rcInlineStringTests`:

```haskell
  , testCase "short string-literal CAF allocates no cell" $
      onBothBackends $ \backend -> do
        stats <- statsOf backend "foo = \"/\"\nmain = foo"
        stAllocs stats @?= 0
```

- [ ] **Step 2: Run it, watch it fail** (currently the CAF is excluded from static seeding, so it allocates 1 cell on first eval — but under E3 that cell is inline, so the count may already be 0 or 1 depending on the eval path; confirm the observed count first).

Run: `cabal test --test-options='-p "InlineString"' 2>&1 | tail -20`
Expected: FAIL (allocs == 1) OR already-0 (if the owning-position interception already covers it — if so, this task is a no-op; mark it done and skip the code change).

- [ ] **Step 3: Relax the `reserveStatic` exclusion** so short literals seed statically. Replace the `isLStr` guard with a length-aware predicate (add a helper `isHeapLStr` that is `True` only for `LStr` longer than `maxInlineStr`):

```haskell
-- | True iff the literal needs a heap NString cell (a String literal longer than
-- the inline budget). Short String literals are inline immediates and CAN be
-- statically seeded, like nullary literals.
isHeapLStr :: Lit -> Bool
isHeapLStr (LStr s) = BS.length (TxEnc.encodeUtf8 s) > maxInlineStr
isHeapLStr _        = False
```

Then change both `not (isLStr l)` guards (`reserveStatic` :1092 and the eval mirror :1146) to `not (isHeapLStr l)`. Confirm the static path materializes the literal via the same `alloc (NString …)` chokepoint (which now returns the `InlineStr` immediate for short literals), so the seeded env entry is `RVBox (InlineStr bs)`.

- [ ] **Step 4: Run the test + full suite.**

Run: `cabal test 2>&1 | tail -20`
Expected: the CAF case passes; longer-literal-CAF tests unchanged; all green.

- [ ] **Step 5: Commit.**

```bash
git add src/Wok/Interp/RC/Machine.hs test/Spec.hs
git commit -m "feat(string): seed short string-literal CAFs as static immediates (E3 Task 4)"
```
