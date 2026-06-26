# String Slice E4 Implementation Plan — zero-copy slices + borrow-passing

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers-extended-cc:subagent-driven-development (recommended) or superpowers-extended-cc:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a zero-copy substring (`slice`/`byteSlice`) that windows into a parent `String`'s byte buffer, with borrow-vs-own chosen by escape analysis (no surface lifetimes), and a five-layer soundness suite proving no use-after-free.

**Architecture:** A new isolated `NStringView !Addr !Int !Int` node (parent, byte offset, byte len) + paired `WokStringView` C cell. Windowing happens in the `stringBytes` prim funnel (O(1) `ByteString` slice), so every existing op works unchanged. The interpreter *always counts* the parent (unconditional soundness); `SliceRep = Window | Counted | Copy` is a backend-agnostic routing annotation (the no-refcount `Window` win is codegen-era). Parent-drop is Haskell-driven, mirroring `WokArray` (the C `scan` field stays dead).

**Tech Stack:** Haskell (GHC, `-Werror`), C runtime (`runtime/wok_rc.{c,h}`), tasty/hspec/QuickCheck, the 3-way differential oracle (RC AbstractHeap / RC CHeap / `Data.Text`).

**User decisions (already made):**
- "view and borrow does work" → views first (this slice); iterator/fusion → E5, Unicode → E6.
- Borrow-passing without surface changes → router-not-gate (`SliceRep`), confirmed.
- "make the tests stronger on this slice because this has to be safe and sound" → five-layer suite with a death-test that has teeth.
- Dedicated isolated `NStringView` node (safety over minimalism); general routing in `Escape`/`Region`; no general buffer-view node (YAGNI).
- "Run it autonomously" → subagent-per-task, model-tier routed, no per-task user gate except the final soundness verification.

**Spec:** `docs/superpowers/specs/2026-06-26-string-slice-e4-design.md` (read it — it carries the full rationale, the D6 decision procedure, and every file:line touch-point).

**Common commands:**
- Build: `cabal build wok 2>&1 | tail -5`
- Focused test: `cabal test wok-tests --test-options='-p "<pattern>"' 2>&1 | tail -30`
- Full test: `cabal test wok-tests 2>&1 | tail -20`
- Lint: `hlint src/Wok/Interp/RC src/Wok/IR --ignore-glob=src-generated`
- Sanitizers: `scripts/asan-runtime.sh`

---

### Task 1: `NStringView` node + abstract-heap rep + `stringBytes` windowing

**Goal:** Add the `NStringView` constructor and make a view work end-to-end on the AbstractHeap backend (alloc, deref pass-through, windowed byte read, counted drop of the parent).

**Files:**
- Modify: `src/Wok/Interp/RC/Value.hs` — `data Node` (`:643`), `nodeValues` (`:2127`), `nodeCEligible` (`:1662`), `wouldBeCBytes` (`:1684`), `deref`/`derefPure` (`:1790`/`:1888`), `allocNStringView` (new, beside `allocNString` `:1607`), `dropAddr`/`dropAddrStep` abstract path (`:1955`).
- Modify: `src/Wok/Interp/RC/Prim.hs` — `stringBytes` (`:707`) gains the `NStringView` arm.
- Test: `test/Spec.hs` — new `rcStringViewNodeTests` block (model on `rcStringNodeTests`).

**Acceptance Criteria:**
- [ ] `data Node` has `| NStringView !Addr !Int !Int` (parent addr, byte offset, byte len); the project builds under `-Werror` (every non-exhaustive site handled).
- [ ] `nodeValues (NStringView p _ _) = [RVBox p]`; the generic `cascadeChildren` therefore drops the parent (no special arm).
- [ ] `stringBytes` on an `NStringView` returns `BS.take len (BS.drop off parentBytes)` (O(1) BS slice).
- [ ] On AbstractHeap: alloc a view over an `NString`, read its bytes == the BS window, drop it, and the parent's logical refcount returns to baseline (no leak, no early free).
- [ ] `nodeCEligible (NStringView{}) = False`; `wouldBeCBytes (NStringView{}) = 32`.

**Verify:** `cabal test wok-tests --test-options='-p "/rcStringView/"' 2>&1 | tail -30` → all green; `cabal build wok 2>&1 | tail -5` → no `-Wincomplete-patterns` warnings.

**Steps:**

- [ ] **Step 1: Write the failing test.** In `test/Spec.hs`, add `rcStringViewNodeTests` (wire it into the suite tree next to `rcStringNodeTests`). On the AbstractHeap store: alloc `NString "hello world"`, build `NStringView parent 6 5` ("world"), assert `stringBytes` over it `== "world"`, then drop the view and assert the store's live-cell count returns to the pre-view baseline.

```haskell
rcStringViewNodeTests :: TestTree
rcStringViewNodeTests = testGroup "rcStringViewNode"
  [ testCase "windowed bytes on abstract heap" $ do
      let (parent, s0) = allocPure (NString "hello world") emptyAbstractStore
          (viewA, s1) = runAllocView parent 6 5 s0   -- helper around allocNStringView
      bytesOf viewA s1 @?= "world"
  , testCase "drop of view decrefs parent" $ do
      let (parent, s0) = allocPure (NString "hello world") emptyAbstractStore
          (viewA, s1) = runAllocView parent 6 5 s0
          s2          = runDrop viewA s1
      liveCellCount s2 @?= liveCellCount s0   -- parent freed exactly once
  ]
```
(Use the existing test helpers in the `rcString*` blocks for store construction / `bytesOf` / `liveCellCount`; name them to match what those blocks already use.)

- [ ] **Step 2: Run test to verify it fails.** `cabal test wok-tests --test-options='-p "/rcStringView/"'` → FAIL (constructor `NStringView` not in scope).

- [ ] **Step 3: Add the constructor and its arms.** In `Value.hs`:
  - `data Node = … | NStringView !Addr !Int !Int` with a haddock note (parent addr; **byte** offset; **byte** length).
  - `nodeValues (NStringView p _ _) = [RVBox p]`.
  - `nodeCEligible (NStringView{}) = False`  (own dedicated alloc path, like `NString`).
  - `wouldBeCBytes (NStringView{}) = 32`  (header 8 + parent ptr 8 + offset 8 + len 8).
  - `deref`/`derefPure`: a view is a real cell; the existing `HAddr`/`CAddr` cell-lookup paths return the cell whose `cNode` is the `NStringView` unchanged. Add no special synthesis (contrast `InlineStr`).
  - `allocNStringView :: Addr -> Int -> Int -> Store -> RC (Addr, Store)` — AbstractHeap path: `incref` the parent, then `allocPure (NStringView parent off len)`. (The CHeap path is Task 2; for now `error "allocNStringView CHeap: Task 2"` on `CHeap`, never hit by abstract tests.)
  - `dropAddr`/`dropAddrStep`: the abstract path already cascades via `nodeValues`; confirm the generic path drops `[RVBox parent]`. Add the `NStringView` case only where `-Werror` demands an explicit arm.
  - Fix every other newly-non-exhaustive site `-Werror` flags by mirroring the nearest existing `NString`/`NArray` arm (the spec §4.1 enumerates them).

- [ ] **Step 4: Add the `stringBytes` windowing arm.** In `Prim.hs:707`:

```haskell
stringBytes (RVBox a) s = do
  c <- deref a s
  case cNode c of
    NString bs            -> pure bs
    NStringView p off len -> do
      pb <- stringBytes (RVBox p) s        -- read parent bytes (deref parent -> NString)
      pure (BS.take len (BS.drop off pb))  -- O(1) BS slice; no copy
    _                     -> throwE (PrimError "String: not a string")
```

- [ ] **Step 5: Run tests to verify they pass.** `cabal test wok-tests --test-options='-p "/rcStringView/"'` → PASS. `cabal build wok` → no incomplete-pattern warnings.

- [ ] **Step 6: Commit.**

```bash
git add src/Wok/Interp/RC/Value.hs src/Wok/Interp/RC/Prim.hs test/Spec.hs
git commit -m "feat(string): NStringView node + abstract-heap windowing (E4 Task 1)"
```

---

### Task 2: `WokStringView` C cell + CHeap alloc/deref/drop

**Goal:** Give the view a real C cell so the differential oracle can run it on both backends with matching counts; parent-drop is Haskell-driven (mirror `WokArray`).

**Files:**
- Modify: `runtime/wok_rc.h` — `WOK_STRING_VIEW_TAG`, `wok_string_view_alloc` + accessor decls.
- Modify: `runtime/wok_rc.c` — alloc (malloc backend `~:712` + arena backend `~:417`), accessors, `wok_free` size arm (`:271`).
- Modify: `src/Wok/Interp/RC/Value.hs` — `allocNStringView` CHeap path; `deref` CAddr reads the three fields; `dropAddr` CAddr **third tag branch**.
- Modify: `src/Wok/Runtime/*` (the FFI module that binds `wok_string_*`) — foreign imports for the new C functions.
- Test: `test/Spec.hs` — extend `rcStringViewNodeTests` to run `onBothBackends`; the differential oracle now covers a view.

**Acceptance Criteria:**
- [ ] A `WokStringView` C cell is 32 bytes: 8-byte header (`rc`/`tag`/`reserved`/`scan=0`) + `parent` ptr (8) + `offset` (8) + `len` (8).
- [ ] `wok_string_view_alloc(heap, parentPtr, off, len)` allocates on both the malloc and arena backends; accessors read parent/offset/len.
- [ ] `deref` of a CAddr view reconstructs `NStringView parentCAddr off len`; `stringBytes` over it returns the correct window.
- [ ] `dropAddr` of a CAddr view: reads the parent ptr, `dropAddr`s the parent, then `wok_free`s the 32-byte cell — ASan/LSan clean.
- [ ] The view round-trips identically on AbstractHeap and CHeap (same bytes, same `allocs`/`frees`/`peak`/`peak_bytes`).

**Verify:** `cabal test wok-tests --test-options='-p "/rcStringView/"' 2>&1 | tail -30` → green on both backends; `scripts/asan-runtime.sh 2>&1 | tail -20` → no leaks/UAF.

**Steps:**

- [ ] **Step 1: Write the failing test.** Extend `rcStringViewNodeTests` to drive the windowed-bytes + drop-balance assertions through `onBothBackends` (the helper E1–E3 use), so the CHeap path is exercised and compared to AbstractHeap.

- [ ] **Step 2: Run to verify it fails.** CHeap path hits `error "allocNStringView CHeap: Task 2"`.

- [ ] **Step 3: Add the C cell.** In `wok_rc.h`: `#define WOK_STRING_VIEW_TAG 0xFFFDu` (next free tag below `WOK_STRING_TAG 0xFFFE`); declare `WokObj *wok_string_view_alloc(WokHeap *h, WokObj *parent, uint64_t off, uint64_t len);` and `WokObj *wok_string_view_parent(const WokObj*);` `uint64_t wok_string_view_offset(const WokObj*);` `uint64_t wok_string_view_len(const WokObj*);`. In `wok_rc.c`: implement alloc on both backends (fixed 32-byte body; set `rc=1`, `tag=WOK_STRING_VIEW_TAG`, `scan=0`; store parent/off/len), the accessors, and a `WOK_STRING_VIEW_TAG` arm in `wok_free` returning size 32. **Do NOT drop the parent in `wok_free`** (Haskell-driven, per spec D8).

- [ ] **Step 4: Bind the FFI + wire the Haskell paths.** Add foreign imports (mirror `wok_string_alloc`/`wok_string_data`). In `Value.hs`: `allocNStringView` CHeap branch calls `wok_string_view_alloc` (parent must be a CAddr; `incref` parent first); `deref` CAddr branch dispatches on tag — for `WOK_STRING_VIEW_TAG`, read parent/off/len → `NStringView (CAddr parentPtr) off len`; `dropAddr` CAddr dispatch gains a third branch after array/string tags: read parent ptr, recursively `dropAddr (CAddr parentPtr)`, compute 32-byte size, `wok_free`.

- [ ] **Step 5: Run tests + ASan.** `cabal test wok-tests --test-options='-p "/rcStringView/"'` → PASS both backends. `scripts/asan-runtime.sh` → clean.

- [ ] **Step 6: Commit.**

```bash
git add runtime/wok_rc.h runtime/wok_rc.c src/Wok/Interp/RC/Value.hs src/Wok/Runtime/*.hs test/Spec.hs
git commit -m "feat(string): WokStringView C cell + CHeap alloc/deref/Haskell-driven drop (E4 Task 2)"
```

---

### Task 3: `slice`/`byteSlice` prims + `Std.String` surface + D6 decision procedure

**Goal:** Expose `slice`/`byteSlice` (and library `take`/`drop`), implementing the spec D6 decision procedure (≤7→`InlineStr`; `InlineStr` parent→`InlineStr`; else `NStringView`+`incref`; flatten-on-construction). Routing is not wired yet — every cell-backed view is `Counted` (always increfs).

**Files:**
- Modify: `src/Wok/Interp/RC/Prim.hs` — `stringSlice`, `stringByteSlice`; register in `rcStringPrims` (`:97`).
- Modify: `src/Wok/Interp/RC/PrimNames.hs` (or wherever string prim names map to `(module,name)`) — add `slice`/`byteSlice`.
- Modify: `prelude/Std/String.wok` — externs (`:25` region) + `take`/`drop` library fns.
- Test: `test/rc-string/` corpus programs + `test/Spec.hs` `rcStringPrimTests` extension.

**Acceptance Criteria:**
- [ ] `slice s start len` returns the codepoint window `[start, start+len)`, saturating bounds, always valid UTF-8; matches the `Data.Text` reference on all 3 backends.
- [ ] `byteSlice s start len` returns the byte window, saturating bounds, and **`PrimError`** if a boundary splits a codepoint (2/3/4-byte cases).
- [ ] A window result ≤ 7 bytes is an `InlineStr` (0 cells); a window of an `InlineStr` parent is an `InlineStr` (never an `NStringView`); a > 7-byte window of a cell parent is an `NStringView` that increfs the parent.
- [ ] `slice (slice s a b) c d` is a single `NStringView` over the **root** (flattened; assert no view→view chain), bytes == reference double-slice.
- [ ] `take`/`drop` behave as `slice s 0 n` / `slice s n (length s)`.

**Verify:** `cabal test wok-tests --test-options='-p "/rcStringPrim/ || /rcStringView/"' 2>&1 | tail -30` → green; corpus programs match the reference on all backends.

**Steps:**

- [ ] **Step 1: Write failing oracle corpus + unit tests.** Add `test/rc-string/` programs: `30-slice-basic.wok` (codepoint slice of a long ASCII string), `31-slice-multibyte.wok` (slice across 2/3/4-byte UTF-8), `32-byteslice-split.wok` (expects a runtime error on a split codepoint), `33-slice-of-slice.wok` (nested → flatten), `34-take-drop.wok`, `35-slice-short-inline.wok` (≤7-byte result = 0 cells). Add `rcStringPrimTests` cases asserting the InlineStr-vs-view representation counts.

- [ ] **Step 2: Run to verify failure.** Prims `slice`/`byteSlice` unbound.

- [ ] **Step 3: Implement the prims.** In `Prim.hs`, `stringSlice`:

```haskell
stringSlice :: RCPrim
stringSlice = mkPrim3 $ \sv startV lenV s -> do
  pb <- stringBytes sv s
  let start = fromIntegral (asU64 startV); len = fromIntegral (asU64 lenV)
      -- codepoint indices -> byte offsets via UTF-8 decode (Data.Text)
      t          = TxEnc.decodeUtf8 pb
      cpLen      = Tx.length t
      start'     = min start cpLen
      end'       = min (start + len) cpLen
      offB       = utf8ByteOffset t start'        -- bytes before codepoint start'
      endB       = utf8ByteOffset t end'
      wb         = BS.take (endB - offB) (BS.drop offB pb)
  buildSlice sv pb offB (endB - offB) wb s        -- D6 decision procedure (shared)

stringByteSlice :: RCPrim
stringByteSlice = mkPrim3 $ \sv startV lenV s -> do
  pb <- stringBytes sv s
  let blen = BS.length pb
      start = min (fromIntegral (asU64 startV)) blen
      end   = min (start + fromIntegral (asU64 lenV)) blen
  when (splitsCodepoint pb start || splitsCodepoint pb end) $
    throwE (PrimError "byteSlice: boundary splits a UTF-8 codepoint")
  buildSlice sv pb start (end - start) (BS.take (end-start) (BS.drop start pb)) s
```

  Shared `buildSlice` is the D6 procedure: if `BS.length wb <= maxInlineStr` → `(RVBox (InlineStr wb), s)`; else inspect the parent address behind `sv` — if it is itself an `NStringView root o _` (flatten: parent := root, offset := o + thisOffset) or a cell addr → `allocNStringView parentRoot absOffset (BS.length wb) s` (which increfs the parent); then drop the input `sv`'s address per the standard prim convention. `splitsCodepoint bs i = i > 0 && i < BS.length bs && isContinuationByte (BS.index bs i)`; `isContinuationByte b = b .&. 0xC0 == 0x80`.

- [ ] **Step 4: Surface + names.** `prelude/Std/String.wok`: `extern slice : String -> U64 -> U64 -> String`, `extern byteSlice : String -> U64 -> U64 -> String`, and `take s n = slice s 0 n`, `drop s n = slice s n (length s)`. Register `slice`/`byteSlice` in the `(module,name)` prim-name map and `rcStringPrims`.

- [ ] **Step 5: Run tests.** `cabal test wok-tests --test-options='-p "/rcStringPrim/ || /rcStringView/"'` → PASS; corpus matches reference on all backends.

- [ ] **Step 6: Commit.**

```bash
git add src/Wok/Interp/RC/Prim.hs src/Wok/Interp/RC/PrimNames.hs prelude/Std/String.wok test/rc-string/ test/Spec.hs
git commit -m "feat(string): slice/byteSlice prims + Std.String surface + D6 decision (E4 Task 3)"
```

---

### Task 4: `SliceRep` routing in Escape/Region + routing oracle (test layer 2)

**Goal:** Add the backend-agnostic `SliceRep = Window | Counted | Copy` annotation, derived per view binder from the existing escape analysis, and an independent oracle asserting the planner's decision per slice site. The interpreter still always counts (D2) — this task makes routing *observable and tested*, not yet performance-realized.

**Files:**
- Modify: `src/Wok/IR/Region.hs` — `data SliceRep`, surface it in `RegionPlan` keyed by the view binder's `Unique` (mirror `Placement`).
- Modify: `src/Wok/IR/Escape.hs` — expose the per-binder classification helper if needed (reuse `arenaEscapes`/`escapesFrom`; do not change their granularity).
- Test: `test/Spec.hs` — `rcSliceRoutingTests`: programs whose slice binders are knowingly non-escaping / escaping / arena-parent, asserting `Window` / `Counted` / `Copy` against an independent re-derivation.

**Acceptance Criteria:**
- [ ] `SliceRep` is derived per `let v = slice …` binder: non-escaping + referenceable parent → `Window`; escaping → `Counted`; arena-born parent + escaping view → `Copy`.
- [ ] The annotation is in `RegionPlan` and is backend-independent (AbstractHeap and CHeap agree).
- [ ] An independent routing oracle re-derives the expected `SliceRep` for each site in a corpus and matches the planner exactly.
- [ ] `Copy` is unconditionally safe (a `Copy` slice is a fresh `NString`, no parent reference); a targeted test exercises the arena-parent `Copy` case.

**Verify:** `cabal test wok-tests --test-options='-p "/rcSliceRouting/"' 2>&1 | tail -30` → green; planner-vs-oracle mismatch count == 0.

**Steps:**

- [ ] **Step 1: Write the failing routing oracle.** In `test/Spec.hs`, `rcSliceRoutingTests`: a handful of small wok programs (as source strings compiled through the front end) with a slice binder in each of the three situations; an independent `expectedSliceRep :: CoreExpr -> Map Unique SliceRep` (a simple re-walk asserting the same escape facts) compared to `planRegions`'s slice annotations.

- [ ] **Step 2: Run to verify failure.** `SliceRep` undefined.

- [ ] **Step 3: Implement the routing.** In `Region.hs`: `data SliceRep = Window | Counted | Copy deriving (Eq, Show)`; extend `RegionPlan` with `rpSliceRep :: Map Unique SliceRep`; when collecting placements, for a binder bound to a `slice`/`byteSlice` call, compute: `escapes = arenaEscapes {bd} cont` (reuse, do not fork); `parentArena = placement of the parent binder == Arena`; then `Window` iff `not escapes && not parentArena`, `Copy` iff `escapes && parentArena`, else `Counted`. Thread it through `planRegions` (and the handler-disabled all-`Heap`/all-`Counted` short-circuit: when arenas are module-wide disabled, every slice is `Counted`).

- [ ] **Step 4: Run tests.** `cabal test wok-tests --test-options='-p "/rcSliceRouting/"'` → PASS, mismatch == 0.

- [ ] **Step 5: Commit.**

```bash
git add src/Wok/IR/Region.hs src/Wok/IR/Escape.hs test/Spec.hs
git commit -m "feat(string): SliceRep routing in Escape/Region + routing oracle (E4 Task 4)"
```

---

### Task 5: Death-test build with teeth + negative control (test layer 1)

**Goal:** A build-flagged mode in which `Window`-routed slices are realized *genuinely uncounted* and a runtime invariant fires (a caught UAF) if a `Window` view's parent is freed while the view is read; a permanent negative-control program must trip it, proving the teeth.

**Files:**
- Modify: `src/Wok/Interp/RC/Machine.hs` — the build-flagged `Window`-uncounted path + the parent-liveness invariant on view reads.
- Modify: `src/Wok/Interp/RC/Value.hs` — a liveness check hook on view deref under the flag (e.g. assert the parent cell's `rc > 0` / is still allocated).
- Test: `test/Spec.hs` — `rcSliceDeathTests`: correct programs never trip the invariant; a deliberately mis-routed slice (forced `Window` on an escaping binder) DOES trip it (a negative control, asserted to error).

**Acceptance Criteria:**
- [ ] Under the death-test flag, `Window` slices do not `incref` the parent; reading a view whose parent has been freed raises a distinct, catchable error (not a segfault).
- [ ] All correct corpus programs pass under the death-test flag (invariant never fires on sound code).
- [ ] The negative control (a forced-`Window` escaping slice) trips the invariant — asserted as the expected failure; if it ever stops tripping, the test fails (the teeth are load-bearing).
- [ ] Release/normal build is unchanged (always counts, D2) and never aborts.

**Verify:** `cabal test wok-tests --test-options='-p "/rcSliceDeath/"' 2>&1 | tail -30` → green (incl. the negative control firing as expected).

**Steps:**

- [ ] **Step 1: Write the failing death-tests.** `rcSliceDeathTests`: (a) the sound corpus run under the flag → no invariant trip; (b) a constructed program where an escaping slice is *forced* to `Window` (a test-only override) and its parent dropped before a read → assert a `PrimError`/dedicated `ViewParentFreed` error is raised.

- [ ] **Step 2: Run to verify failure.** No flag/invariant exists yet.

- [ ] **Step 3: Implement the death-test mode.** Behind a CPP flag or a `Store`-level boolean (`stDeathTest`), `buildSlice`'s `Window` path skips the parent `incref`; view deref under the flag checks the parent address is still live (cell present / `rc > 0`) and raises `PrimError "view: parent freed (death-test)"` otherwise. Keep the flag off by default (release always counts).

- [ ] **Step 4: Run tests.** `cabal test wok-tests --test-options='-p "/rcSliceDeath/"'` → PASS (sound clean, negative control fires).

- [ ] **Step 5: Commit.**

```bash
git add src/Wok/Interp/RC/Machine.hs src/Wok/Interp/RC/Value.hs test/Spec.hs
git commit -m "test(string): death-test build with teeth + negative control (E4 Task 5)"
```

---

### Task 6: QuickCheck property suite + cross-type equality + byteSlice boundary corpus (test layer 4)

**Goal:** Property-based coverage of the borrow-passing correctness claims and op-transparency across all three string representations.

**Files:**
- Modify: `test/Spec.hs` — `rcStringViewPropertyTests` (model on `rcStringPropertyTests`).

**Acceptance Criteria:**
- [ ] **Borrow-out survival:** a slice returned from a function and stored in a cons cell reads correct bytes after the parent's original binding is dropped (parent kept alive by the count).
- [ ] **Nested-flatten:** `slice (slice s a b) c d` equals the `Data.Text` double-slice byte-for-byte and is a single root-backed `NStringView`.
- [ ] **Window round-trip:** for arbitrary `s` and in-range `i,n`, `slice s i n` bytes == reference codepoint substring.
- [ ] **UTF-8 validity:** every `slice` result decodes; `byteSlice` errors iff a boundary splits a codepoint.
- [ ] **Op-transparency:** every E1/E2 op on a view == the same op on the materialized copy.
- [ ] **Cross-type equality:** `eqString` agrees with byte equality for every pair from {view, `WokString` cell, `InlineStr`}.

**Verify:** `cabal test wok-tests --test-options='-p "/rcStringViewProperty/"' 2>&1 | tail -30` → green (QuickCheck 100+ cases each).

**Steps:**

- [ ] **Step 1: Write the properties** (all six AC above) as QuickCheck properties driven `onBothBackends` and compared to `Data.Text`. Generators: arbitrary UTF-8 `Text` (reuse the E1/E2 generator), in-range and out-of-range indices, and a representation-tagged generator emitting view / cell / inline strings of equal bytes for the cross-type equality property.

- [ ] **Step 2: Run to verify they fail / then pass** as implementation is already in place (these are regression-locking properties over Tasks 1–4). Fix any genuine failures they surface in the prims.

- [ ] **Step 3: Commit.**

```bash
git add test/Spec.hs
git commit -m "test(string): QuickCheck view properties + cross-type eq + byteSlice boundary (E4 Task 6)"
```

---

### Task 7: Adversarial UAF programs + savings/leak oracle assertions + sanitizer gate (test layer 5)

**Goal:** USER-ORDERED soundness verification — hand-written exploit programs that *try* to create a use-after-free, the exact no-copy savings + leak-balance oracle assertions, and a clean sanitizer + full-suite green run.

> **USER-ORDERED GATE — NON-SKIPPABLE.** This task was requested by the user in the current conversation ("make the tests stronger on this slice because this has to be safe and sound here"). It MUST NOT be closed by walking around it, by declaring it "verified inline", or by substituting a cheaper check. Close only after every item in `acceptanceCriteria` has been re-validated independently, with output captured.

**Files:**
- Create: `test/rc-string/40-adversarial-escape-closure.wok`, `41-adversarial-store-parent-dropped.wok`, `42-adversarial-slice-of-slice-mid-dies.wok`, `43-adversarial-append-outlives.wok`.
- Modify: `test/Spec.hs` — `rcSliceAdversarialTests` (each program sound when counted; caught by the death-test when forced-`Window`); the differential-oracle savings/leak assertions.

**Acceptance Criteria:**
- [ ] Each adversarial program produces the **correct** output on all 3 backends (sound under the always-counts release path).
- [ ] Each adversarial program, run under the death-test flag with its escaping slice forced to `Window`, **trips** the parent-liveness invariant (the exploit is real and the teeth catch it).
- [ ] **No-copy savings:** a `Window`/`Counted` slice of a > 7-byte string raises `peak_bytes` by exactly 32 (one view cell, zero new byte buffer); a `Copy`/materialized of the same raises it by `16 + N`. Pinned on both RC backends.
- [ ] **Leak balance:** after all views and parents drop, `frees == allocs` and `peak` returns to baseline.
- [ ] `scripts/asan-runtime.sh` clean (no leaks/UAF, the `peak_physical_bytes` invariant holds); full `cabal test wok-tests` green.

**Verify:** `scripts/asan-runtime.sh 2>&1 | tail -20` → clean AND `cabal test wok-tests 2>&1 | tail -20` → all green AND `cabal test wok-tests --test-options='-p "/rcSliceAdversarial/"'` → green.

```json:metadata
{"files": ["test/rc-string/40-adversarial-escape-closure.wok","test/rc-string/41-adversarial-store-parent-dropped.wok","test/rc-string/42-adversarial-slice-of-slice-mid-dies.wok","test/rc-string/43-adversarial-append-outlives.wok","test/Spec.hs"], "verifyCommand": "scripts/asan-runtime.sh 2>&1 | tail -20 && cabal test wok-tests 2>&1 | tail -20", "acceptanceCriteria": ["each adversarial program correct on all 3 backends (sound when counted)","each adversarial program trips the death-test parent-liveness invariant when forced-Window","no-copy savings: Window/Counted slice raises peak_bytes by exactly 32; Copy by 16+N, both RC backends","leak balance: frees==allocs and peak returns to baseline","scripts/asan-runtime.sh clean incl. peak_physical_bytes invariant; full wok-tests green"], "modelTier": "standard", "userGate": true, "tags": ["user-gate"], "requireEvidenceTokens": [["counted","window-counted","release-path"],["forced-window","death-test","uncounted"]]}
```

**Steps:**

- [ ] **Step 1: Write the four adversarial programs** (the four shapes in AC) as `test/rc-string/4x-*.wok`, each with a known-correct expected output.

- [ ] **Step 2: Wire `rcSliceAdversarialTests`** — each program asserted (a) correct on all 3 backends under release, and (b) tripping the death-test invariant under forced-`Window`.

- [ ] **Step 3: Add the savings + leak oracle assertions** — exact `peak_bytes` deltas (32 for window, `16+N` for copy) and `frees==allocs` after teardown, both RC backends.

- [ ] **Step 4: Run the full gate.** `scripts/asan-runtime.sh` clean; `cabal test wok-tests` all green; capture the output.

- [ ] **Step 5: Commit.**

```bash
git add test/rc-string/4*.wok test/Spec.hs
git commit -m "test(string): adversarial UAF programs + savings/leak oracle + sanitizer gate (E4 Task 7)"
```

---

## Self-Review (author checklist — completed)

- **Spec coverage:** §3 D1–D8 → Tasks 1 (node/window), 2 (C cell/Haskell-drop), 3 (prims/D6/surface), 4 (routing/D1); §8 layers 1–5 → Tasks 5 (layer 1), 4 (layer 2), 1–3+7 (layer 3 oracle), 6 (layer 4), 7 (layer 5). §5 surface → Task 3. §9 codegen transfer → no task (design invariant, asserted in spec). All spec requirements map to a task.
- **Placeholder scan:** no TBD/TODO; every code step carries concrete signatures/code; test code shown.
- **Type consistency:** `NStringView !Addr !Int !Int`, `SliceRep = Window | Counted | Copy`, `buildSlice`, `splitsCodepoint`, `WOK_STRING_VIEW_TAG`, `wok_string_view_alloc`, `rpSliceRep` used consistently across tasks.
- **Model tiers:** T1/T2/T3/T5/T6/T7 = standard (multi-file C/Haskell/test integration); T4 = frontier (escape-analysis routing is the soundness brain, design judgment beyond the steps). Start each at tier; escalate up if blocked.
