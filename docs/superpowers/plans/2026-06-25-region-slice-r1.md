# Region Slice R1 — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers-extended-cc:subagent-driven-development (recommended) or superpowers-extended-cc:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build an uncounted, per-activation **arena tier** (C runtime + abstract-heap mirror) plus a backend-agnostic **R+escape routing annotation**, so that a function body's non-escaping, mutation-free, continuation-free local allocations are born uncounted in the activation's arena (bulk-freed O(1) on return, after scanning out counted children) — dropping counted `allocs`/`frees`, proven bit-for-bit on both backends.

**Architecture:** A new compile-time pass `Wok.IR.Region` tags each allocation `Arena | Heap` from `Wok.IR.Escape` (Go-style escape analysis). The interpreter routes `alloc` on the tag; arena cells are uncounted (`isUncounted`), reclaimed wholesale by a C checkpoint-stack ABI (`wok_arena_open/alloc/close`) mirrored on the abstract heap. The routing annotation + the shared-runtime arena are the only artifacts a future codegen reuses (where the arena becomes a stack frame).

**Tech Stack:** Haskell (the wok compiler/interpreter), C (`runtime/wok_rc.c`), Tasty (Hspec + QuickCheck), `cabal test wok-tests`, the C `runtime/test` harness under ASan/UBSan via `scripts/asan-runtime.sh`. The correctness oracle is the existing RC differential oracle (abstract heap vs C heap, bit-for-bit `allocs`/`frees`/`peak`/`peak_bytes` + leak-freedom) extended with arena stats.

**User decisions (already made):**
- Anchor **A** — invisible/inferred regions at **function-body** granularity (Go-style escape analysis). Not the opt-in `with…in` form.
- **No new surface grammar** (permanent constraint).
- **Biggest measurable win** — route *every* sound local allocation into the uncounted arena (maximise the counted `allocs`/`frees` drop), with scan-out of counted children at close.
- **Region cells are uncounted** (the only way the win is oracle-visible pre-codegen).
- **Codegen transferability is a first-class invariant** — routing stays a backend-agnostic IR annotation; the arena stays in the shared C runtime.

Full design: `docs/superpowers/specs/2026-06-25-region-slice-r1-design.md`. Read it before implementing — every task references its sections.

---

## File structure (decomposition)

| File | Responsibility | Tasks |
|---|---|---|
| `runtime/wok_rc.{c,h}` | the uncounted arena ABI (checkpoint stack, arena alloc, bulk reset, arena stats) | 1 |
| `runtime/test/*`, `scripts/asan-runtime.sh` | C arena unit tests under sanitizers | 1 |
| `src/Wok/Interp/RC/Heap.hs` | FFI imports for `wok_arena_*` | 2 |
| `src/Wok/IR/Region.hs` (**new**) | the `Arena|Heap` routing pass from `Wok.IR.Escape` + the three fences | 3 |
| `src/Wok/IR/Escape.hs` | reuse only; export a small per-binder non-escape helper if needed | 3 |
| `src/Wok/Interp/RC/Value.hs` | the abstract arena mirror (`stArena`, `isUncounted` arena case, `arenaOpen`/`arenaClose` + scan-out), arena stats, FBIP exclusion | 4 |
| `src/Wok/Interp/RC/Machine.hs` | read the tag at `alloc`; bracket the function body with arena open/close on every exit path | 5 |
| the differential-oracle harness (`test/Spec.hs`) | arena-stat parity + arena-leak invariant | 6 |
| `test/rc-region/*.wok` (**new**) | the four-shape corpus | 6 |
| `runtime/README.md`, memory | docs | 7 |

**Sequencing:** 1 → 2 → 3 → 4 → 5 → 6 → 7. Each ships green (builds + existing suite stays green). The arena ABI (1–2) is fully testable before any routing; the routing pass (3) is a pure analysis testable in isolation; the interpreter wiring (4–5) is where the cross-backend oracle (6) becomes the validation method.

---

### Task 1: C uncounted-arena ABI + checkpoint stack + sanitizer tests

**Goal:** Add a per-activation arena to the C runtime — a LIFO checkpoint stack over the existing bump allocator, with uncounted allocation and O(1) bulk reset — without touching the counted path.

**Files:**
- Modify: `runtime/wok_rc.h` (declare the `wok_arena_*` ABI + arena stat getters)
- Modify: `runtime/wok_rc.c` (the checkpoint stack on `WokHeap`, the four functions, arena stats)
- Test: `runtime/test/` (a new standalone test; wire into `scripts/asan-runtime.sh`)

**Acceptance Criteria:**
- [ ] `wok_arena_open/alloc/close` round-trip: open → N `wok_arena_alloc` → close reclaims all N (pointer-identity reuse of the bump region after close).
- [ ] LIFO nesting (open A, open B, close B, close A) works; a `close` with a mismatched handle is a loud `abort`/assert.
- [ ] `wok_arena_alloc` does NOT change `allocs`/`frees`/`live`/`peak`; it updates a separate `arena_bytes`/`arena_peak` (new getters `wok_stat_arena_bytes`/`wok_stat_arena_peak`).
- [ ] After `close`, `arena_bytes` returns to its pre-open value.
- [ ] ASan/UBSan/LeakSanitizer clean; the counted slab path, `wok_free`, `wok_array_*`, FBIP `wok_alloc_at` are byte-for-byte unchanged in behaviour.

**Verify:** `bash scripts/asan-runtime.sh` → all C tests PASS, sanitizers clean.

**Steps:**

- [ ] **Step 1: Read** the design §3.1 and the existing slab allocator in `runtime/wok_rc.c` (`wok_alloc`, the `slabs`/`bump_ptr`/`freelist` fields, `wok_cell_bytes`, `wok_heap_free`). The arena is a *checkpoint into the same bump region*, plus a separate byte counter — not a new heap.

- [ ] **Step 2: Declare the ABI** in `runtime/wok_rc.h` (additive):

```c
/* ---- Uncounted per-activation arena (Region Slice R1) -----------------------------
   A LIFO checkpoint over the bump allocator. wok_arena_alloc returns an UNCOUNTED cell
   (its rc field is unused; wok_dup/wok_dec are never meaningfully called on it). The
   whole arena is reclaimed in O(1) by wok_arena_close (reset the bump frontier). The
   caller drops any counted children BEFORE close (the Haskell scan-out). Arena bytes are
   tracked separately from the counted allocs/frees/live/peak counters. */
uint32_t wok_arena_open(WokHeap* h);                              /* push frontier; returns depth handle */
WokObj*  wok_arena_alloc(WokHeap* h, uint32_t tag, uint32_t arity);/* uncounted bump alloc in innermost arena */
void     wok_arena_close(WokHeap* h, uint32_t handle);            /* assert top==handle; reset frontier */
WOK_PURE uint64_t wok_stat_arena_bytes(const WokHeap* h);
WOK_PURE uint64_t wok_stat_arena_peak(const WokHeap* h);
```

- [ ] **Step 3: Implement** in `runtime/wok_rc.c`. Add to `WokHeap`: a small fixed-or-growable stack of saved frontiers (`{ WokSlab* slab; char* bump_ptr; uint64_t arena_bytes_at_open; }`), a `uint32_t arena_depth`, and `uint64_t arena_bytes`/`arena_peak`. `wok_arena_open` pushes the current `(current_slab, bump_ptr, arena_bytes)` and returns `arena_depth++`. `wok_arena_alloc` bump-allocates exactly like the slab path of `wok_alloc` (grow a slab if needed) but: does NOT bump `allocs`/`live`/`peak`/`cur_bytes`; instead bumps `arena_bytes += wok_cell_bytes(arity)` and updates `arena_peak`; sets `rc`/`tag`/`arity`/`scan` in the header as `wok_alloc` does (so deref/cascade read it normally). `wok_arena_close(h, handle)`: assert `handle == arena_depth-1` (else `abort()`); pop the saved frontier, restoring `current_slab`/`bump_ptr` and `arena_bytes`; return any slabs grown past the checkpoint to the free-slab list (or simply keep them and reset `bump_ptr` within the saved slab — pick the approach matching the existing slab lifecycle; document it). Decrement `arena_depth`.

- [ ] **Step 4: Write the standalone test** (`runtime/test/`, mirroring the existing array/`wok_rc` tests). Assert each acceptance criterion: round-trip reclaim with pointer-identity reuse after close; LIFO nesting; mismatched-handle abort (in a death-test or guarded path); arena stats isolated from counted stats; `arena_bytes` back to baseline after close; a counted `wok_alloc` interleaved with arena allocs keeps its own stats intact.

- [ ] **Step 5: Run sanitizers and the existing suite**

Run: `bash scripts/asan-runtime.sh`
Expected: PASS, sanitizers clean.
Run: `cabal test wok-tests` (Haskell unchanged; must still build + pass)
Expected: PASS (no regressions).

- [ ] **Step 6: Commit**

```bash
git add runtime/wok_rc.c runtime/wok_rc.h runtime/test scripts/asan-runtime.sh
git commit -m "feat(runtime): uncounted per-activation arena ABI (Region R1 task 1)"
```

```json:metadata
{"files": ["runtime/wok_rc.c", "runtime/wok_rc.h", "runtime/test", "scripts/asan-runtime.sh"], "verifyCommand": "bash scripts/asan-runtime.sh && cabal test wok-tests", "acceptanceCriteria": ["arena open/alloc/close round-trip with pointer-identity reuse", "LIFO nesting + mismatched-handle abort", "arena stats isolated from counted stats; arena_bytes back to baseline after close", "ASan/UBSan/LSan clean; counted path unchanged"], "modelTier": "standard"}
```

---

### Task 2: FFI bindings for the arena ABI

**Goal:** Bind the four `wok_arena_*` functions (and the two arena stat getters) into Haskell.

**Files:**
- Modify: `src/Wok/Interp/RC/Heap.hs` (FFI imports + export list)

**Acceptance Criteria:**
- [ ] `wokArenaOpen :: Ptr WokHeap -> IO Word32`, `wokArenaAlloc :: Ptr WokHeap -> Word32 -> Word32 -> IO (Ptr WokObj)`, `wokArenaClose :: Ptr WokHeap -> Word32 -> IO ()`, `wokStatArenaBytes`/`wokStatArenaPeak :: Ptr WokHeap -> IO Word64` are imported and exported.
- [ ] The module builds; existing FFI imports unchanged.

**Verify:** `cabal build wok` → builds clean.

**Steps:**

- [ ] **Step 1: Add the imports** next to the existing `wok_alloc`/`wok_array_alloc` foreign imports in `Heap.hs`, matching their `foreign import ccall unsafe` style:

```haskell
foreign import ccall unsafe "wok_arena_open"  wokArenaOpen  :: Ptr WokHeap -> IO Word32
foreign import ccall unsafe "wok_arena_alloc" wokArenaAlloc :: Ptr WokHeap -> Word32 -> Word32 -> IO (Ptr WokObj)
foreign import ccall unsafe "wok_arena_close" wokArenaClose :: Ptr WokHeap -> Word32 -> IO ()
foreign import ccall unsafe "wok_stat_arena_bytes" wokStatArenaBytes :: Ptr WokHeap -> IO Word64
foreign import ccall unsafe "wok_stat_arena_peak"  wokStatArenaPeak  :: Ptr WokHeap -> IO Word64
```

- [ ] **Step 2: Export** all five from the module export list.

- [ ] **Step 3: Build + commit**

Run: `cabal build wok` → clean.
```bash
git add src/Wok/Interp/RC/Heap.hs
git commit -m "feat(rc): FFI bindings for wok_arena_* (Region R1 task 2)"
```

```json:metadata
{"files": ["src/Wok/Interp/RC/Heap.hs"], "verifyCommand": "cabal build wok", "acceptanceCriteria": ["five wok_arena_* / arena-stat FFI imports added + exported", "module builds clean"], "modelTier": "mechanical"}
```

---

### Task 3: `Wok.IR.Region` — the R+escape routing annotation

**Goal:** A pure pass that tags each function-body allocation `Arena` or `Heap` from `Wok.IR.Escape`, under the three R1 fences (non-escaping, mutation-free, continuation-free), and brackets each routing function body with an arena scope marker. This is the backend-agnostic artifact codegen reuses (design §4.1, §7).

**Files:**
- Create: `src/Wok/IR/Region.hs`
- Modify: `src/Wok/IR/Escape.hs` (export a per-binder non-escape helper if the existing exports are insufficient — reuse `escapesFrom`/`nonHeadOccs`; do NOT change the analysis)
- Test: `test/Spec.hs` (a `Wok.IR.Region` unit group)

**Acceptance Criteria:**
- [ ] For a function body, an allocation whose binder does NOT escape (`escapesFrom`/`nonHeadOccs` — design §5.1), is NOT an `NArray` alloc (mutation fence, §5.2), and sits in a continuation-free body (`m2bResumeEscapes`-clean + no captured-continuation escape, §5.3) is tagged `Arena`; everything else `Heap`.
- [ ] A body with any captured continuation routes ALL its allocations `Heap` (conservative fence).
- [ ] The tag is a pure function of the elaborated IR (idempotent; no heap/IO).
- [ ] A function body with ≥1 `Arena` tag is marked as opening an arena scope; bodies with none are unmarked (no needless open/close).
- [ ] Unit tests over the four shapes (non-escape→Arena, return-escape→Heap, array→Heap, continuation-capturing→all Heap) assert the tags.

**Verify:** `cabal test wok-tests --test-show-details=direct -k "Region routing"` → PASS.

**Steps:**

- [ ] **Step 1: Read** design §4.1, §5.1–§5.4, and `src/Wok/IR/Escape.hs` (the exported predicates: `escapesFrom`, `nonHeadOccs`, `letRecMemberEscapes`, `m2bResumeEscapes`, `boxedBinder`, `isBoxedType`). The routing reuses these; it must NOT re-implement escape logic (the single-source-of-truth rule in `Escape.hs`'s header).

- [ ] **Step 2: Decide the annotation carrier.** Prefer a side-table `Map Unique Placement` (`data Placement = Arena | Heap`) computed per function, plus a `Set Unique` of function-binders that open an arena — avoids editing the `Rhs`/`Expr` shape and keeps the pass non-invasive. Define the module interface:

```haskell
module Wok.IR.Region
  ( Placement (..)
  , RegionPlan (..)        -- per-module: alloc placement + which bodies open an arena
  , planRegions            -- CoreModule -> RegionPlan   (pure)
  ) where
data Placement = Arena | Heap deriving (Eq, Show)
```

- [ ] **Step 3: Implement `planRegions`** as a pure walk over each top-level function body. For a body `e`: (a) if the body captures/leaks a continuation (any op-arm `resume` escapes via `m2bResumeEscapes`, or a continuation value flows to a non-call-head position) → tag every alloc in `e` `Heap`; (b) else, for each `Let bd (alloc-rhs) …`, tag `Arena` iff `boxedBinder bd` AND the alloc node is not an `NArray`/array-prim result (mutation fence) AND `not (escapesFrom (Set.singleton (binderUnique bd)) bodyAfter)` where `bodyAfter` is the continuation of the `Let` (the scope the binder must not escape) — i.e. reuse the SAME escaping-position machinery `Escape.hs` already exposes; else `Heap`. Record the function-binder in the arena-opening set iff any alloc tagged `Arena`.

- [ ] **Step 4: Write the unit tests** in `test/Spec.hs`. Build (or load+elaborate) the four shapes and assert `planRegions` tags. Concrete shapes (load from tiny `.wok` fixtures or hand-build `CoreModule`s, matching the style of the existing `Wok.IR.*` unit tests):
  - non-escaping scratch: `let t = Pair a b in case t of Pair x y -> x + y` → `t` is `Arena`.
  - return-escape: `let t = Pair a b in t` (returned) → `t` is `Heap`.
  - array: `let a = Array.new 3 0 in length a` → `a` is `Heap` (mutation fence).
  - continuation-capturing body (a handler whose op captures `resume` non-tail) → every alloc `Heap`.

- [ ] **Step 5: Run + commit**

Run: `cabal test wok-tests --test-show-details=direct -k "Region routing"` → PASS.
```bash
git add src/Wok/IR/Region.hs src/Wok/IR/Escape.hs test/Spec.hs
git commit -m "feat(ir): Wok.IR.Region R+escape routing annotation (Region R1 task 3)"
```

```json:metadata
{"files": ["src/Wok/IR/Region.hs", "src/Wok/IR/Escape.hs", "test/Spec.hs"], "verifyCommand": "cabal test wok-tests --test-show-details=direct -k \"Region routing\"", "acceptanceCriteria": ["non-escaping boxed local -> Arena; return-escape -> Heap", "NArray -> Heap (mutation fence); continuation-capturing body -> all Heap", "planRegions is pure/idempotent; reuses Escape.hs, no new escape logic", "arena-opening function set computed"], "modelTier": "frontier"}
```

---

### Task 4: Abstract-heap arena mirror + uncounted semantics + scan-out

**Goal:** Teach the abstract `Store` an arena tier so the differential oracle can cross-check the C arena bit-for-bit: arena addresses are uncounted (`dup`/`drop` inert), `arenaOpen`/`arenaClose` mirror the C checkpoint stack, and `arenaClose` scans out arena cells' counted children before bulk-reset (design §3.2, §4.3, §5.1).

**Files:**
- Modify: `src/Wok/Interp/RC/Value.hs` (`Store`, `isUncounted`, `alloc`/arena alloc, `arenaOpen`/`arenaClose`, arena stats; FBIP exclusion)
- Test: `test/Spec.hs` (store-algebra unit group)

**Acceptance Criteria:**
- [ ] A new `stArena :: [IntSet]` (depth stack of arena addresses) on `Store`; `stArenaBytes`/`stArenaPeak` on `Stats`.
- [ ] `isUncounted` returns `True` for any address in `stArena` (added alongside the static/`Inline` cases), so `dup`/`drop` on an arena cell are no-ops with NO cascade (design §3.1).
- [ ] Arena alloc does NOT touch `stAllocs`/`stFrees`/`stLive`/`stPeak`; it bumps `stArenaBytes`/`stArenaPeak`.
- [ ] `arenaClose` drops exactly each arena cell's COUNTED children once (`countedRefs`), skipping arena-sibling/uncounted children, then bulk-removes the depth's addresses; `stArenaBytes` returns to its pre-open value; `stLive` unaffected.
- [ ] Arena addresses are FBIP-excluded (never `stReserved`, never an `alloc_at`/`dropReuse` donor/target).
- [ ] Store-algebra tests: (a) arena alloc is uncounted; (b) scan-out drops a counted child once and leaves a shared (rc>1) child live; (c) `arenaClose` returns arena bytes to baseline and leaves `stLive == baseline`.

**Verify:** `cabal test wok-tests --test-show-details=direct -k "arena store"` → PASS.

**Steps:**

- [ ] **Step 1: Read** design §3.2, §4.3, §5.1, §5.5 and the current `Value.hs`: `Store` (≈:750), `isUncounted`, `alloc` (≈:1008), `dropAddr`/`cascadeChildren`/`countedRefs`, `recordAlloc`/`recordFree`, the `stReserved` FBIP guard.

- [ ] **Step 2: Extend `Store`/`Stats`.** Add `stArena :: [IntSet]` (head = innermost depth) and `stArenaBytes`/`stArenaPeak :: !Int` to `Stats`. Update the `Store` constructor / `emptyStore` and any record-update sites (the compiler will list them).

- [ ] **Step 3: `isUncounted`.** Add an arena case: an `HAddr i` with `i` in any frame of `stArena` is uncounted. (Keep it O(1)-ish: a flattened `IntSet` cache is acceptable if profiling demands, but correctness first — membership across the stack frames.)

- [ ] **Step 4: Arena alloc + open/close.** Add `arenaAllocPure :: Node -> Store -> (Addr, Store)` (fresh positive `HAddr`, inserted in `stCells`, recorded in the innermost `stArena` frame, `stArenaBytes`/`stArenaPeak` bumped via `wouldBeCBytes`, NO `recordAlloc`). Add `arenaOpen :: Store -> Store` (push empty frame) and `arenaClose :: Store -> RC Store` (the scan-out: for each addr in the top frame, `countedRefs` of its node, `dropAddr` each counted non-arena child; then delete the frame's addrs from `stCells`/mark dead, subtract their bytes from `stArenaBytes`, pop the frame). Loud error on `arenaClose` with no open frame.

- [ ] **Step 5: FBIP exclusion.** Ensure `dropReuse`/`allocAt` never select an arena address (guard on `isUncounted`/arena membership, the same way static addresses are already excluded), and arena cells never enter `stReserved`.

- [ ] **Step 6: Store-algebra tests** in `test/Spec.hs` (mirror the existing direct-store tests): build a counted child `B`, `arenaOpen`, arena-alloc a cell `A` owning `B`, assert `dup A`/`drop A` are no-ops and stats unchanged; `arenaClose` and assert `B` is freed once (and a second, shared child survives); assert `stArenaBytes` and `stLive` return to baseline.

- [ ] **Step 7: Run + commit**

Run: `cabal test wok-tests --test-show-details=direct -k "arena store"` → PASS.
Run: `cabal test wok-tests` → no regressions.
```bash
git add src/Wok/Interp/RC/Value.hs test/Spec.hs
git commit -m "feat(rc): abstract arena mirror + uncounted semantics + scan-out (Region R1 task 4)"
```

```json:metadata
{"files": ["src/Wok/Interp/RC/Value.hs", "test/Spec.hs"], "verifyCommand": "cabal test wok-tests --test-show-details=direct -k \"arena store\"", "acceptanceCriteria": ["stArena depth stack + arena stats; isUncounted arena case (dup/drop inert, no cascade)", "arena alloc bypasses counted stats; arenaClose scans out counted children once then bulk-resets", "arena bytes + stLive return to baseline after close", "arena addresses FBIP-excluded"], "modelTier": "frontier"}
```

---

### Task 5: Interpreter routing + function-body arena bracket

**Goal:** Wire the `Wok.IR.Region` plan into the RC interpreter: route each `alloc` to arena vs heap by the tag, and bracket every arena-opening function body with `arena_open` … scan-out + `arena_close` on EVERY exit path (normal return and tail-call/`Jump`), on both backends (design §4.2, §5.3).

**Files:**
- Modify: `src/Wok/Interp/RC/Machine.hs` (thread the `RegionPlan`; tag-routed alloc; the body bracket)
- Modify: `src/Wok/Interp/RC/Value.hs` (a backend-dispatching `arenaAlloc`/`arenaOpen`/`arenaClose` that calls `wokArena*` on `CHeap` and the pure mirror on `AbstractHeap`)

**Acceptance Criteria:**
- [ ] On both backends, an `Arena`-tagged alloc goes to the arena; a `Heap`-tagged alloc goes to today's path.
- [ ] An arena-opening function body opens on entry and closes (scan-out then reset) on every exit path; a captured-continuation body opens no arena (fence).
- [ ] No double-close / no missed-close: the bracket is placed at the body's CPS boundary (the same delimiter handler open/close uses); a missed close is caught by the oracle arena-leak invariant (Task 6), and the placement is verified to never close while a value that outlives the activation is still arena-resident (escapees are `Heap`).
- [ ] The existing RC suite stays green (non-arena programs unchanged).

**Verify:** `cabal test wok-tests --test-show-details=direct -k "rc"` → PASS (full RC suite; arena corpus added in Task 6).

**Steps:**

- [ ] **Step 1: Read** design §4.2, §5.1, §5.3 and `Machine.hs`: how a function body is entered/evaluated (the CPS continuation structure, the `alloc` call sites ≈:206, the tail-call/`Jump` handling, the handler `open`/`close` delimiter for the model of where to bracket).

- [ ] **Step 2: Backend-dispatching arena ops** in `Value.hs`: `arenaAlloc :: Node -> Store -> RC (Addr, Store)` → `CHeap hp` calls `wokArenaAlloc` (encode the node like `allocNCon` does, but via the arena entry point and recording the address as uncounted on the C side's bookkeeping mirror if any) / `AbstractHeap` calls `arenaAllocPure`. Similarly `arenaOpen`/`arenaClose` dispatch to `wokArenaOpen`/`wokArenaClose` (C) or the pure mirror (abstract). Keep the two backends in lockstep (same sequence of opens/closes/allocs).

- [ ] **Step 3: Thread the `RegionPlan`** from elaboration into `runModuleRC` (compute `planRegions` once, store it in the RC reader/state). At each alloc site, look up the binder's `Placement`; route accordingly.

- [ ] **Step 4: Bracket the body.** For a function whose binder is in the arena-opening set, wrap its evaluation: `arenaOpen` before the body, and on the body's result continuation (the point where the activation's frame is done — normal return AND any tail `Jump` out of the body) run the scan-out + `arenaClose`. Implement the bracket at the same structural point the interpreter already uses to delimit a frame (reuse the handler/continuation delimiter machinery; do NOT scatter closes). A continuation-capturing body (not in the arena-opening set) is never wrapped.

- [ ] **Step 5: Run the full RC suite** (no arena corpus yet — this step proves non-arena programs are unaffected and arena-routed ones don't crash/leak):

Run: `cabal test wok-tests --test-show-details=direct -k "rc"` → PASS.
If BLOCKED on the CPS bracket placement (the subtle part), escalate per the plan and capture the exact failing reproducer.

- [ ] **Step 6: Commit**

```bash
git add src/Wok/Interp/RC/Machine.hs src/Wok/Interp/RC/Value.hs
git commit -m "feat(rc): tag-routed alloc + function-body arena bracket (Region R1 task 5)"
```

```json:metadata
{"files": ["src/Wok/Interp/RC/Machine.hs", "src/Wok/Interp/RC/Value.hs"], "verifyCommand": "cabal test wok-tests --test-show-details=direct -k \"rc\"", "acceptanceCriteria": ["alloc routed by Placement tag on both backends", "arena-opening body brackets open/scan-out+close on every exit path incl tail-call; continuation body opens no arena", "no double/missed close; escapees are Heap so nothing live is arena-resident at close", "existing RC suite green"], "modelTier": "frontier"}
```

---

### Task 6: Differential-oracle extension + region corpus

**Goal:** Extend the RC differential oracle with arena-stat parity and the arena-leak invariant, and add the four-shape `test/rc-region` corpus that exercises both routing branches — making the cross-backend agreement *checked*, not argued (design §6, §8, §9).

**Files:**
- Modify: `test/Spec.hs` (the rc parity/stats harness: add `arena_bytes`/`arena_peak` parity + arena-leak invariant; register the corpus)
- Create: `test/rc-region/01-scratch-cohort.wok`, `02-escape-heap.wok`, `03-pure-fastpath.wok`, `04-counted-scanout.wok`

**Acceptance Criteria:**
- [ ] The parity harness asserts `wokStatArenaBytes`/`wokStatArenaPeak` (C) == `stArenaBytes`/`stArenaPeak` (abstract) for every region corpus program, alongside the existing `allocs`/`frees`/`peak`/`peak_bytes` parity.
- [ ] An arena-leak invariant: arena bytes return to baseline at program end on both backends (and per the design, opens==closes).
- [ ] The corpus exercises: (01) a non-escaping scratch cohort (counted `allocs`/`frees` measurably LOWER than the all-heap baseline), (02) an escaping value (stays counted), (03) a pure-data fast-path cohort (no scan-out), (04) an arena cell owning a counted child (scan-out drops it once).
- [ ] Byte-identical output + all parities + leak-freedom on both backends for all four.
- [ ] A deliberately-mis-tagged value (negative control, in a test-only variant) diverges the stats — proving the oracle has teeth.

**Verify:** `cabal test wok-tests --test-show-details=direct -k "rc"` → PASS (including the new corpus + arena parity).

**Steps:**

- [ ] **Step 1: Read** design §6/§8 and the existing parity harness in `test/Spec.hs` (`rcParityHarness`/`rcStatsHarness` — the `allocs`/`frees`/`peak`/`peak_bytes` assertions, the `live == baseline` check). Add the arena reads alongside.

- [ ] **Step 2: Write the four `.wok` corpus programs** under `test/rc-region/` (small, deterministic, matching `test/rc-array/*` style). Each must produce identical output on both backends and return the heap to baseline. Design the scratch cohort (01) so the counted alloc/free count is *visibly* lower than it would be without routing (e.g. build and consume a few intermediate boxed pairs inside a helper that returns a scalar).

- [ ] **Step 3: Extend the harness** to read `arena_bytes`/`arena_peak` from both backends and assert equality + return-to-baseline, and to register `test/rc-region/*` in the differential corpus group.

- [ ] **Step 4: Add the teeth test** — a unit-level negative control that forces a wrong `Placement` (route an escaping value to the arena) and asserts the differential/leak check fails (so we know the oracle would catch a routing bug). Keep it isolated (not in the shipping corpus).

- [ ] **Step 5: Generate/inspect goldens** (if the corpus feeds any golden group) and run:

Run: `cabal test wok-tests --test-show-details=direct -k "rc"` → PASS.
Run: `cabal test wok-tests` → full suite green.

- [ ] **Step 6: Commit**

```bash
git add test/Spec.hs test/rc-region
git commit -m "test(rc): arena-stat parity + region corpus + teeth (Region R1 task 6)"
```

```json:metadata
{"files": ["test/Spec.hs", "test/rc-region/01-scratch-cohort.wok", "test/rc-region/02-escape-heap.wok", "test/rc-region/03-pure-fastpath.wok", "test/rc-region/04-counted-scanout.wok"], "verifyCommand": "cabal test wok-tests --test-show-details=direct -k \"rc\"", "acceptanceCriteria": ["arena_bytes/arena_peak parity abstract==C + arena-leak invariant", "four-shape corpus: scratch (counts drop), escape (heap), pure fastpath, counted scan-out", "byte-identical output + leak-freedom both backends", "negative-control teeth: mis-tag diverges the oracle"], "modelTier": "standard"}
```

---

### Task 7: Docs + memory + cleanup

**Goal:** Document the arena tier and the routing annotation; record the slice in memory; clean up scaffolding.

**Files:**
- Modify: `runtime/README.md` (the arena ABI + the unified picture)
- Modify: `docs/superpowers/2026-06-24-array-region-valuemodel-arc.md` (mark the regions epic R1 underway/landed)
- Create: a memory note for Region Slice R1

**Acceptance Criteria:**
- [ ] `runtime/README.md` documents `wok_arena_*` + arena stats + the uncounted tier.
- [ ] The arc doc notes R1 (inferred function-local arenas, R+escape, codegen-transfer) landed on the branch.
- [ ] A memory note `region-slice-r1` records: the design, what shipped, the coverage ceiling (L5), the codegen-transfer story, links.
- [ ] No leftover scaffolding/temp files.

**Verify:** `cabal test wok-tests` → green; `git status` → only intended files.

**Steps:**

- [ ] **Step 1: Update `runtime/README.md`** with the arena ABI section.
- [ ] **Step 2: Update the arc doc** Slice-ladder status.
- [ ] **Step 3: Write the memory note** (after a human/Opus review confirms what actually shipped — see the deep-review phase).
- [ ] **Step 4: Commit**

```bash
git add runtime/README.md docs/superpowers/2026-06-24-array-region-valuemodel-arc.md
git commit -m "docs(region): document the arena tier + R1 status (Region R1 task 7)"
```

```json:metadata
{"files": ["runtime/README.md", "docs/superpowers/2026-06-24-array-region-valuemodel-arc.md"], "verifyCommand": "cabal test wok-tests", "acceptanceCriteria": ["runtime/README arena ABI documented", "arc doc R1 status updated", "memory note written", "no leftover scaffolding"], "modelTier": "mechanical"}
```

---

## Self-Review

**Spec coverage:** §3.1 C arena → Task 1; §3.2 abstract mirror → Task 4; §4.1 routing pass → Task 3; §4.2 interpreter routing + §4.3 scan-out → Tasks 4/5; §5 fences → Tasks 3/4/5; §6/§8 oracle → Task 6; §7 codegen-transfer → preserved by construction (routing is an IR annotation in Task 3, arena in the shared runtime in Task 1) — no separate task needed; §9 testing → Tasks 1/3/4/6; §10 files → all tasks; FFI (§10) → Task 2; docs (§10) → Task 7. No gap.

**Placeholder scan:** every code step shows real signatures (the C ABI from §3.1, the FFI imports, the `Placement`/`RegionPlan` interface, the store fields). The RC dup/drop-placement subtleties are deliberately validated by the differential oracle + store-algebra tests (the repo's established TDD-against-the-oracle method, per the m2a-1 plan precedent), not hand-asserted — that is the correct method here, not a placeholder.

**Type consistency:** `Placement`/`RegionPlan`/`planRegions` (Task 3) are consumed in Task 5; `stArena`/`stArenaBytes`/`arenaOpen`/`arenaClose`/`arenaAllocPure` (Task 4) are consumed in Task 5; `wokArenaOpen/Alloc/Close`/`wokStatArenaBytes`/`wokStatArenaPeak` (Task 2) match the C ABI (Task 1) and are used in Tasks 5/6. Names consistent across tasks.

**Risk note for the executor:** Tasks 3 and 5 carry the design judgment (the escape-verdict composition and the CPS bracket placement) and are tiered `frontier`. If Task 5's bracket placement proves intractable on the current CPS structure, the fallback is to narrow R1's first landing to *leaf* (non-tail-calling, effect-free) function bodies — still sound, still measurable — and widen in a follow-up; capture the blocker rather than forcing an unsound close.
