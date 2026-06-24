# Array Slice C — in-place `Array.set` under `rc == 1` — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers-extended-cc:subagent-driven-development (recommended) or superpowers-extended-cc:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give `Array.set` a fast path that mutates the array's slot in place when the array is uniquely owned (`rc == 1`) and the new element is encodable, falling back to the existing copy-on-write otherwise — `0 array alloc` in the unique case, same observable semantics.

**Architecture:** A non-destructive refcount peek (`wok_rc` in C, `cRc` on the abstract heap) feeds a single shared decision `arrayUnique`; when it (plus a pure `encodeSlotC v` check) holds, `arraySetSlotInPlace` overwrites the slot (C: `wok_array_slot_set`; abstract: node-replace at the same address, no `recordAlloc`/`recordFree`) and returns the old element for `arraySet` to drop. The `rc == 1` decision is identical on both backends (lockstep refcount + pure encode check), so the differential oracle stays bit-for-bit green.

**Tech Stack:** Haskell (GHC, Strict/StrictData), C runtime (`wok_rc.c`) via FFI, tasty + Hspec + QuickCheck, differential oracle, ASan/UBSan runtime tests.

**User decisions (already made):**
- "agree with 1" — uniqueness probe is the non-destructive peek (not dec-restore, not FBIP tokens).
- "good with general wok_rc" — the C peek reads the shared prefix and works on any cell.
- "Don't touch FBIP code and resize here" — FBIP untouched, arrays stay FBIP-excluded; `resize` stays copy-only; only `set` gets the fast path.
- "run it autonomously" — subagent-driven execution in this session; no merge to main (user runs `/code-review` before merge per the review-before-merge rule).

**Spec:** `docs/superpowers/specs/2026-06-24-array-slice-c-inplace-set-design.md`. **Companion:** `docs/array-slice-c-inplace-set.html`.

---

## File Structure

- `runtime/wok_rc.h` — declare `wok_rc` (general shared-prefix refcount peek).
- `runtime/wok_rc.c` — define `wok_rc`; placed beside `wok_tag`/`wok_arity` (~line 387).
- `runtime/test/wok_rc_test.c` — a new assertion block for the non-destructive peek.
- `src/Wok/Interp/RC/Heap.hs` — the `wokRc` FFI import + export.
- `src/Wok/Interp/RC/Value.hs` — `arrayUnique` + `arraySetSlotInPlace` + exports.
- `src/Wok/Interp/RC/Prim.hs` — gate `arraySet`.
- `test/Spec.hs` — update the `set` store-algebra unit test; add the writer/decision unit tests.
- `test/rc-array/09-set-shared.wok` — the copy-path (shared-input) corpus program.
- `runtime/README.md`, `docs/superpowers/2026-06-24-array-region-valuemodel-arc.md`, memory note — docs.

---

### Task 1: `wok_rc` non-destructive peek (C function + ABI + FFI binding)

**Goal:** Add a general `wok_rc` that returns a cell's refcount without modifying it, with a C unit test proving it is non-destructive, plus the Haskell FFI binding.

**Files:**
- Modify: `runtime/wok_rc.h` (after `wok_arity` decl, ~line 42)
- Modify: `runtime/wok_rc.c` (beside `wok_tag`/`wok_arity`, ~line 387-388)
- Modify: `runtime/test/wok_rc_test.c` (new assertion block before `printf("OK\n")`)
- Modify: `src/Wok/Interp/RC/Heap.hs` (export list + a new `foreign import`)

**Acceptance Criteria:**
- [ ] `wok_rc(p)` returns `p->rc` and does not mutate it (verified across two peeks and around `wok_dup`/`wok_dec`).
- [ ] Works on both an `NCon` cell (`wok_alloc`) and a `WokArray` cell (`wok_array_alloc`).
- [ ] `scripts/asan-runtime.sh` prints `OK` and is ASan/UBSan/LSan clean.
- [ ] `cabal build` succeeds with the new `wokRc` FFI binding exported (unused-but-exported, no warning-as-error).

**Verify:** `bash scripts/asan-runtime.sh` → prints `OK`; `cabal build` → succeeds.

**Steps:**

- [ ] **Step 1: Declare `wok_rc` in the header.** In `runtime/wok_rc.h`, immediately after the `wok_arity` declaration (`WOK_PURE uint32_t wok_arity(const WokObj* p);`), add:

```c
/* Non-destructive refcount peek. General (the shared WokObj prefix at offset 0,
   so it works on any cell including WokArray). The read-only sibling of
   wok_dup/wok_dec. Used by the rc==1 in-place Array.set gate (Slice C). */
WOK_PURE uint32_t wok_rc(const WokObj* p);
```

- [ ] **Step 2: Define `wok_rc` in the C source.** In `runtime/wok_rc.c`, beside `wok_tag`/`wok_arity` (~line 387-388), add:

```c
uint32_t wok_rc(const WokObj* p) { return p->rc; }
```

- [ ] **Step 3: Add the non-destructive C unit test.** In `runtime/test/wok_rc_test.c`, just before the final `printf("OK\n");`, add this block:

```c
    /* --- wok_rc: non-destructive refcount peek (Slice C) ----------------------------- */
    {
        WokHeap* h = wok_heap_new();

        /* NCon cell: peek tracks rc and never mutates it */
        WokObj* p = wok_alloc(h, 3u, 2u);
        assert(wok_rc(p) == 1u);          /* fresh: rc 1 */
        assert(wok_rc(p) == 1u);          /* idempotent: a peek does not change rc */
        wok_dup(p);
        assert(wok_rc(p) == 2u);          /* after dup */
        assert(wok_dec(p) == 1u);
        assert(wok_rc(p) == 1u);          /* after dec */
        assert(wok_dec(p) == 0u);
        wok_free(h, p);

        /* WokArray cell: same shared-prefix rc field */
        WokObj* arr = wok_array_alloc(h, 2u, 0u);
        assert(wok_rc(arr) == 1u);
        wok_dup(arr);
        assert(wok_rc(arr) == 2u);
        assert(wok_dec(arr) == 1u);
        assert(wok_rc(arr) == 1u);
        assert(wok_dec(arr) == 0u);
        wok_free(h, arr);

        assert(wok_stat_live(h) == 0);
        wok_heap_free(h);
    }
```

- [ ] **Step 4: Run the C test under sanitizers.** Run: `bash scripts/asan-runtime.sh`. Expected: prints `OK`, no ASan/UBSan/LSan diagnostics.

- [ ] **Step 5: Add the FFI binding.** In `src/Wok/Interp/RC/Heap.hs`, add `wokRc` to the module export list (next to `wokDup, wokDec`) and add the import beside `wok_dec` (~line 24):

```haskell
foreign import ccall unsafe "wok_rc"        wokRc       :: Ptr WokObj -> IO Word32
```

- [ ] **Step 6: Build.** Run: `cabal build`. Expected: succeeds (the binding is exported, so no unused warning).

- [ ] **Step 7: Commit.**

```bash
git add runtime/wok_rc.h runtime/wok_rc.c runtime/test/wok_rc_test.c src/Wok/Interp/RC/Heap.hs
git commit -m "feat(array): wok_rc non-destructive refcount peek + FFI (Slice C task 1)"
```

---

### Task 2: `arrayUnique` decision + `arraySetSlotInPlace` writer (Value.hs)

**Goal:** Add the shared uniqueness decision and the address-dispatched in-place slot writer to `Value.hs`, each covered by store-algebra unit tests, with no change to `arraySet` yet (ships green: nothing calls them in production, so existing behaviour and tests are unchanged).

**Files:**
- Modify: `src/Wok/Interp/RC/Value.hs` (new defs + export list)
- Modify: `test/Spec.hs` (new store-algebra unit tests)

**Acceptance Criteria:**
- [ ] `arrayUnique :: Addr -> Store -> RC Bool` returns `True` for a fresh (rc 1) dynamic array, `False` after a `dup` (rc 2), and `False` for a static/immortal (negative `HAddr`) array — on the abstract backend.
- [ ] `arraySetSlotInPlace :: Addr -> Int -> RCValue -> Store -> RC (RCValue, Store)` overwrites slot `i`, returns the old element, leaves length/`rc`/`cBytes` unchanged, and records no alloc/free — on the abstract backend, for an inline-element array (`U64`) and a boxed-element array (`String`).
- [ ] After `arraySetSlotInPlace` + `dropValue oldEl`, `stLive` returns to baseline (old element released, survivors untouched).
- [ ] Both symbols are exported; `cabal build` succeeds; the full existing suite still passes (no behaviour change yet).

**Verify:** `cabal test wok-tests` → passes (the suite includes the new unit tests).

**Steps:**

- [ ] **Step 1: Write the failing unit tests.** In `test/Spec.hs`, near the existing array store-algebra tests, add a test group `arrayUnique / in-place` mirroring the existing store-algebra test setup (same `emptyStore`/`alloc`/`runRC` helpers the current `set` test uses ~line 17020). Cover:

```haskell
-- arrayUnique: fresh unique array is unique; dup'd is not.
-- (build a Store, alloc (NArray [RVLit (LInt 0), RVLit (LInt 0)]) -> (RVBox a, s)
--  assert: arrayUnique a s == True
--  incref a -> s' ; assert: arrayUnique a s' == False)
--
-- arraySetSlotInPlace on an inline-element array (Array U64):
--  alloc (NArray [RVLit (LInt 1), RVLit (LInt 2), RVLit (LInt 3)]) -> (RVBox a, s)
--  (oldEl, s1) <- arraySetSlotInPlace a 1 (RVLit (LInt 99)) s
--  assert: oldEl == RVLit (LInt 2)
--  assert: deref a s1 has node NArray [LInt 1, LInt 99, LInt 3]
--  assert: stAllocs/stFrees unchanged from before the call (0 alloc / 0 free)
--  s2 <- dropValue oldEl s1   -- inline drop is a no-op
--  assert: stLive s2 == baseline
--
-- arraySetSlotInPlace on a boxed-element array (Array String / a boxed con):
--  build three boxed elements e0,e1,e2 (alloc small NCons), arr = NArray [e0,e1,e2]
--  (oldEl, s1) <- arraySetSlotInPlace a 1 newBoxed s   -- newBoxed owned
--  assert: slot 1 now == newBoxed, oldEl == e1
--  s2 <- dropValue oldEl s1   -- releases e1 (its rc hits 0, freed)
--  assert: stLive returns to baseline (e1 gone, e0/e2/newBoxed accounted)
```

Use the exact assertion style of the surrounding tests (`@?=`, `HUnit`). Run: `cabal test wok-tests` → FAIL (`arrayUnique`/`arraySetSlotInPlace` not in scope).

- [ ] **Step 2: Add `arrayUnique` to Value.hs.** Add to the export list and define (place near `dropReuse`/`isStaticAddr`):

```haskell
-- | True iff the array at 'a' is safe to mutate in place: a dynamic, counted cell
-- whose refcount is exactly 1 (the caller's owned reference is the only one).
-- Static/immortal addresses (negative HAddr, uncounted) read "rc 1" but are shared
-- for the program's lifetime, so they are NEVER unique here -- guarded FIRST, exactly
-- as 'dropReuse' guards its donor. The 'CAddr' arm peeks the C cell's rc
-- non-destructively ('wokRc'); the 'HAddr' arm reads 'cRc' via 'derefPure' (which
-- rejects 'CAddr', so it is reached only for a dynamic HAddr). The decision is
-- identical on both backends because the refcount is maintained in lockstep.
arrayUnique :: Addr -> Store -> RC Bool
arrayUnique a _ | isStaticAddr a = pure False
arrayUnique (CAddr p) _          = (== 1) <$> liftIO (H.wokRc p)
arrayUnique a@(HAddr _) s        = do
  c <- liftRC (derefPure a s)
  pure (cRc c == 1)
arrayUnique (Inline _) _         = pure False   -- an array handle is never Inline; defensive
```

- [ ] **Step 3: Add `arraySetSlotInPlace` to Value.hs.** Add to the export list and define:

```haskell
-- | Overwrite slot 'i' of the array at 'a' with 'v', in place, returning the OLD
-- element for the caller to drop. The cell's rc / length / cBytes are unchanged and
-- NO recordAlloc/recordFree is performed (0 alloc / 0 free). Order: read old -> write
-- new -> return (caller drops old). Precondition (the caller's gate): the array is
-- unique ('arrayUnique') and 'v' is encodable ('isJust (encodeSlotC v)').
arraySetSlotInPlace :: Addr -> Int -> RCValue -> Store -> RC (RCValue, Store)
arraySetSlotInPlace (CAddr p) i v s = do
  kind <- elemKindToSlotKind <$> liftIO (H.wokArrayElemKind p)
  oldW <- liftIO (H.wokArraySlotGet p (fromIntegral i))
  let oldEl = decodeSlotC kind oldW
  case encodeSlotC v of
    Just (_, w) -> do
      liftIO (H.wokArraySlotSet p (fromIntegral i) w)
      pure (oldEl, s)
    Nothing ->
      liftRC (Left (PrimError (Tx.pack
        "arraySetSlotInPlace: non-encodable value reached the in-place path")))
arraySetSlotInPlace a@(HAddr idx) i v s = do
  c <- liftRC (derefPure a s)
  case cNode c of
    NArray vs -> case atIndexV i vs of
      Just oldEl ->
        let newVs = [ if j == i then v else el | (j, el) <- zip [0 :: Int ..] vs ]
            c'    = c { cNode = NArray newVs }
        in pure (oldEl, s { stCells = IM.insert idx c' (stCells s) })
      Nothing ->
        liftRC (Left (PrimError (Tx.pack "arraySetSlotInPlace: index out of range")))
    _ -> liftRC (Left (PrimError (Tx.pack "arraySetSlotInPlace: address is not an array")))
arraySetSlotInPlace (Inline _) _ _ _ =
  liftRC (Left (PrimError (Tx.pack "arraySetSlotInPlace: inline handle is not an array")))
```

Note: `atIndexV` is the total safe list indexer. If `Value.hs` has no such helper, inline it locally (`atIndexV n xs = case drop n xs of { (x:_) -> Just x; [] -> Nothing }`) — do NOT use `(!!)`. (`Prim.hs` already has the identical `atIndex`; it cannot be imported here because `Prim` imports `Value`, so define a private copy in `Value.hs`.)

- [ ] **Step 4: Build and run the tests.** Run: `cabal test wok-tests`. Expected: PASS (the new unit tests are green; all pre-existing tests still pass since `arraySet` is unchanged).

- [ ] **Step 5: Commit.**

```bash
git add src/Wok/Interp/RC/Value.hs test/Spec.hs
git commit -m "feat(array): arrayUnique decision + arraySetSlotInPlace writer + unit tests (Slice C task 2)"
```

---

### Task 3: Gate `arraySet` on the in-place fast path + behavioural/oracle tests

**Goal:** Wire the gate into `arraySet` (in-place when `arrayUnique && isJust (encodeSlotC v)`, else the existing copy path verbatim), update the existing `set` unit test to the new accounting, add a shared-input corpus program, and keep the QuickCheck properties and the differential oracle green on both backends.

**Files:**
- Modify: `src/Wok/Interp/RC/Prim.hs` (`arraySet` + imports)
- Modify: `test/Spec.hs` (update the existing `set` `+1 alloc` test; add a shared-array `+1 alloc` sibling)
- Create: `test/rc-array/09-set-shared.wok`

**Acceptance Criteria:**
- [ ] A unique-input `set` allocates `0` arrays (in-place); a shared-input `set` allocates `+1` (copy) and leaves the original array's value at `i` unchanged.
- [ ] QuickCheck properties hold on both backends: `index (set a i v) i == v`; `j /= i ==> index (set a i v) j == index a j`; `length (set a i v) == length a`.
- [ ] The differential oracle (abstract == C) is byte-identical and matches `alloc`/`frees`/`peak`/`peak_bytes` for the whole `test/rc-array` corpus, including the new `09-set-shared.wok`; heap returns to baseline.
- [ ] `cabal test wok-tests` passes; `bash scripts/asan-runtime.sh` prints `OK`.

**Verify:** `cabal test wok-tests` → passes; `bash scripts/asan-runtime.sh` → `OK`.

**Steps:**

- [ ] **Step 1: Update the existing `set` unit test (red first).** In `test/Spec.hs`, the existing "set: replaces slot, +1 alloc" test (~line 17020-17042) asserts `St.stAllocs (St.stStats s6) - allocsBefore @?= 1` on a freshly-allocated (unique) array. Change that assertion to `@?= 0` (in-place: no array alloc) and keep the value-correctness assertions (slot `i` is the new value, others unchanged). Add a **sibling** test for the shared case: before the `set`, `incref` the array address once (rc 2), then assert the `set` allocates `@?= 1` (copy) AND the original array still reads its old value at `i`. Run: `cabal test wok-tests` → FAIL (the unique case still allocates 1 with the current copy-only `arraySet`).

- [ ] **Step 2: Gate `arraySet`.** In `src/Wok/Interp/RC/Prim.hs`, ensure the imports from `Value` include `arrayUnique`, `arraySetSlotInPlace`, `encodeSlotC` (add to the existing `import ... RC.Value` list) and `isJust` from `Data.Maybe` (add if absent). Replace the body of `arraySet` with:

```haskell
arraySet :: RCPrim
arraySet = RCPrim PN.arraySetName 3 [] $ \args s -> case args of
  [arr@(RVBox a), iv, v] -> do
    i  <- liftRC (asIndex iv)
    vs <- arrayElems arr s
    if i >= length vs
      then throwE (PrimError (Tx.pack "Array.set: out of bounds"))
      else do
        unique <- arrayUnique a s
        if unique && isJust (encodeSlotC v)
          then do
            -- in-place fast path: 0 array alloc, survivors untouched.
            (oldEl, s1) <- arraySetSlotInPlace a i v s
            s2          <- dropValue oldEl s1
            pure (PRDone (RVBox a), s2)
          else do
            -- copy-on-write (the existing path, verbatim).
            let newVs = [ if j == i then v else el | (j, el) <- zip [0 ..] vs ]
            s1 <- foldM
                    (\st (j, el) -> if j == i then pure st else dupValue el st)
                    s
                    (zip [0 :: Int ..] vs)
            (na, s2) <- alloc (NArray newVs) s1
            s3 <- dropAddr a s2
            pure (PRDone (RVBox na), s3)
  _ -> throwE (ArityError (Tx.pack "Array.set"))
```

- [ ] **Step 3: Run the unit tests.** Run: `cabal test wok-tests`. Expected: the updated unique-case (`0 alloc`) and shared-case (`+1 alloc`) tests PASS; QuickCheck `set` properties PASS on both backends.

- [ ] **Step 4: Add the shared-input corpus program.** Create `test/rc-array/09-set-shared.wok`:

```
module Main
import Std.Base
import Std.Array

-- Shared-input set: arr0 is used by BOTH `set` and a later `index`, so Perceus dups
-- it and `set` sees rc > 1 -> copy-on-write fallback (NOT in-place). The original
-- arr0 must still read its OLD value (proving no in-place mutation of a shared
-- array); the returned copy carries the new value.
--
--   arr0 = new 4 0          -- [0,0,0,0]; shared (used twice below)
--   arr1 = set arr0 0 100   -- copy path: arr1 = [100,0,0,0]; arr0 untouched
--   orig = index arr0 0     -- 0   (original unchanged)
--   upd  = index arr1 0     -- 100 (copy updated)
--   main = orig + upd        -- 100

main : U64
main =
  let arr0 = new 4 0 in
  let arr1 = set arr0 0 100 in
  let orig = index arr0 0 in
  let upd  = index arr1 0 in
  orig + upd
```

- [ ] **Step 5: Run the differential oracle + sanitizers.** Run: `cabal test wok-tests` (the differential oracle runs the whole `test/rc-array` corpus on both backends, including `09-set-shared.wok` and the now-in-place `05-set-index.wok`). Then `bash scripts/asan-runtime.sh`. Expected: both green; oracle byte-identical and stat-matched; `OK`.

- [ ] **Step 6: Commit.**

```bash
git add src/Wok/Interp/RC/Prim.hs test/Spec.hs test/rc-array/09-set-shared.wok
git commit -m "feat(array): in-place Array.set under rc==1 + shared-set oracle coverage (Slice C task 3)"
```

---

### Task 4: Docs + memory + arc/roadmap update

**Goal:** Document the `wok_rc` ABI and mark Slice C done in the arc and the memory note; remove any scaffolding.

**Files:**
- Modify: `runtime/README.md` (the ABI list)
- Modify: `docs/superpowers/2026-06-24-array-region-valuemodel-arc.md` (mark Slice C done / shipped)
- Modify: `/Users/zy/.claude/projects/-Users-zy-wokml/memory/array-slice-b-c-cell.md` + `MEMORY.md` pointer (record Slice C shipped)

**Acceptance Criteria:**
- [ ] `runtime/README.md` lists `wok_rc` in the ABI with a one-line description (general non-destructive refcount peek).
- [ ] The arc doc's slice ladder (§1 rung 3) is marked implemented with the commit/branch, mirroring how Slice B was marked.
- [ ] The `array-slice-b-c-cell` memory note records Slice C (in-place set under rc==1, the `wok_rc` peek, `arrayUnique`/`arraySetSlotInPlace`, FBIP untouched).

**Verify:** `git diff --stat` shows only doc/memory files; `cabal test wok-tests` still green (docs-only change).

**Steps:**

- [ ] **Step 1: Update `runtime/README.md`.** Add `wok_rc` to the documented ABI list next to `wok_dup`/`wok_dec`: "`wok_rc(p)` — non-destructive refcount peek (general; the rc==1 in-place `Array.set` gate)."

- [ ] **Step 2: Mark Slice C in the arc doc.** In `docs/superpowers/2026-06-24-array-region-valuemodel-arc.md` §1, annotate rung 3 (Slice C) as IMPLEMENTED with the branch name, mirroring the Slice B annotation style.

- [ ] **Step 3: Update the memory note.** Append Slice C to `array-slice-b-c-cell.md` (the in-place set fast path, `wok_rc`, `arrayUnique`/`arraySetSlotInPlace`, the cross-backend oracle invariant, FBIP untouched, `resize` still copy-only) and refresh the `MEMORY.md` one-line pointer.

- [ ] **Step 4: Commit.**

```bash
git add runtime/README.md docs/superpowers/2026-06-24-array-region-valuemodel-arc.md
git commit -m "docs(array): document wok_rc + mark Slice C in the value-model arc (Slice C task 4)"
```

---

## Self-Review

**Spec coverage:** §3 (probe) → Task 1 (`wok_rc`/`wokRc`) + Task 2 (`arrayUnique`). §5 (writer) → Task 2 (`arraySetSlotInPlace`). §4 (gate) + §6 (accounting) → Task 3 (`arraySet`). §7 (oracle) + §10/§11 (tests) → Task 3 (unit test update, shared corpus, QuickCheck, differential). §9 (ABI) + §12 docs → Task 1 + Task 4. All spec sections covered.

**Placeholder scan:** every code step contains the actual C/Haskell/wok content; test steps give concrete assertions and the existing test to mirror; no TBD/TODO.

**Type consistency:** `arrayUnique :: Addr -> Store -> RC Bool` and `arraySetSlotInPlace :: Addr -> Int -> RCValue -> Store -> RC (RCValue, Store)` are used with those exact signatures in Task 3; `wok_rc`/`wokRc` (`Ptr WokObj -> IO Word32`), `elemKindToSlotKind`, `decodeSlotC`, `encodeSlotC`, `atIndexV` all match their defining tasks / existing code.
