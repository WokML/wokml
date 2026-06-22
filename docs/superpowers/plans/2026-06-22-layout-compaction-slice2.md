# Layout Compaction Slice 2 — Nullary Constructors as Inline Immediates — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers-extended-cc:subagent-driven-development (recommended) or superpowers-extended-cc:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make every zero-field constructor (`Nil`/`None`/`True`/`False`/`Leaf`/any `data T = A`) an inline immediate carried in the slot/binding word, with zero heap cells, validated bit-for-bit by the differential oracle.

**Architecture:** Add a third `Addr` case `Inline Word32` (the interned con tag). Intercept nullary `NCon` at the shared `alloc` chokepoint (no allocation, no stat bump, both backends); synthesize it back in `deref`. Immediates are uncounted (reuse the static-cell precedent), so dup/drop are no-ops. A 2-bit low slot tag (`00` CAddr / `01` HAddr / `11` Inline) lets an immediate live inside a C cell's slot. The C runtime is unchanged except an additive `wok_stat_peak_bytes` counter for the benchmark.

**Tech Stack:** Haskell (RC interpreter, `Wok.Interp.RC.*`), C (`runtime/wok_rc.{c,h}` via cabal `c-sources`), tasty + tasty-golden + QuickCheck (`test/Spec.hs`, test-suite `wok-tests`).

**User decisions (already made):**
- Scope = nullary-as-immediate only; rc/immortal unification and phantom-`Addr` deferred to their own slices. ("I think it is good to run autonomously" approving the spec whose §1/§10 fix this scope.)
- The new `Addr` case is named `Inline` (not `AImm`/`Unboxed`/`Nullary`). ("inline is good")
- 2-bit low slot tag, Koka-style bit0 = pointer-vs-value. (spec §3/§10)
- Benchmark is a first-class deliverable with an additive `wok_stat_peak_bytes` counter; no interpreter wall-clock claim. ("yes I think this makes much more sense")
- `isUncounted` is a distinct predicate (`isStaticAddr ∨ isInline`), keeping `isStaticAddr` precise. (spec §10 flaggable lean)

**Note on task order vs spec §8:** the benchmark corpus + baseline capture is pulled to **Task 1** (before any behavior change) so the BEFORE alloc/free/peak numbers are measured on the genuine pre-Slice-2 interpreter; the spec's value-model/slot/oracle/bench/docs content is otherwise unchanged.

**Spec:** `docs/superpowers/specs/2026-06-22-layout-compaction-slice2-design.md`

---

### Task 1: Benchmark corpus + pre-Slice-2 baseline capture

**Goal:** Add the four benchmark `.wok` programs and record the genuine pre-change `--dump-rc-stats` numbers, so the slice's win is measured against a real baseline rather than guessed.

**Files:**
- Create: `bench/tree.wok`, `bench/bools.wok`, `bench/maybes.wok`, `bench/list.wok`
- Create: `bench/baseline.txt`
- Create: `scripts/rc-bench.sh`

**Acceptance Criteria:**
- [ ] Each of the four programs runs under `--dump-rc-stats` and prints `allocs / frees / peakLive / baseline` without error.
- [ ] `bench/baseline.txt` records the four programs' stats verbatim from this (pre-Slice-2) tree.
- [ ] `scripts/rc-bench.sh` runs `--dump-rc-stats` over the four programs and prints a labelled table.
- [ ] No source under `src/` or `runtime/` changed (this task is purely additive).

**Verify:** `bash scripts/rc-bench.sh` → prints four rows (tree/bools/maybes/list) of stats; `cat bench/baseline.txt` shows the same numbers.

**Steps:**

- [ ] **Step 1: Write the four benchmark programs.**

`bench/tree.wok` — build + fold a depth-d binary tree with empty `Leaf`s (the resident + cell-count case):
```
data Tree = Leaf | Node(Tree, U64, Tree)

build : U64 -> Tree
build d = if d == 0 then Leaf else Node(build(d - 1), d, build(d - 1))

sum : Tree -> U64
sum t = case t of
  Leaf -> 0
  Node(l, v, r) -> sum(l) + v + sum(r)

main = sum(build(8))
```

`bench/bools.wok` — comparison-heavy, producing many transient booleans (the alloc-churn case):
```
count : U64 -> U64 -> U64
count i acc = if i == 0 then acc
              else count(i - 1, if i < 500 then acc + 1 else acc)

main = count(1000, 0)
```

`bench/maybes.wok` — a list with many `None` (the mixed pointer/immediate field case):
```
data Opt = None | Some(U64)

build : U64 -> List(Opt)
build n = if n == 0 then []
          else (if n < 2 then Some(n) else None) :: build(n - 1)

len : List(Opt) -> U64
len xs = case xs of
  [] -> 0
  _ :: rest -> 1 + len(rest)

main = len(build(64))
```

`bench/list.wok` — a long plain list (the control; the `Nil` win is one cell):
```
build : U64 -> List(U64)
build n = if n == 0 then [] else n :: build(n - 1)

len : List(U64) -> U64
len xs = case xs of
  [] -> 0
  _ :: rest -> 1 + len(rest)

main = len(build(100))
```

> If the surface syntax of any program is rejected by the parser, adapt it to the nearest accepted form in `examples/*.wok` (e.g. `collatz.wok`, `expr-eval.wok`) — the *shape* (tree with empty leaves; comparison loop; list of options with many `None`; plain list) is what matters, not the exact tokens.

- [ ] **Step 2: Write the bench driver.**

`scripts/rc-bench.sh`:
```bash
#!/usr/bin/env bash
# Runs --dump-rc-stats over the Slice-2 benchmark corpus and prints a table.
set -euo pipefail
cd "$(dirname "$0")/.."
progs=(tree bools maybes list)
printf '%-10s %s\n' "program" "allocs / frees / peakLive / baseline (+ peakBytes once wired)"
for p in "${progs[@]}"; do
  out=$(cabal run -v0 wok -- --dump-rc-stats "bench/${p}.wok")
  printf '%-10s %s\n' "$p" "$(echo "$out" | tr '\n' ' ')"
done
```
Make it executable: `chmod +x scripts/rc-bench.sh`.

- [ ] **Step 3: Run and capture the baseline.**

Run: `bash scripts/rc-bench.sh | tee bench/baseline.txt`
Expected: four rows print, each with numeric stats, and `bench/baseline.txt` holds them.

- [ ] **Step 4: Commit.**
```bash
git add bench/ scripts/rc-bench.sh
git commit -m "bench(rc): Slice 2 benchmark corpus + pre-change baseline"
```

---

### Task 2: Value model + chokepoints (`Inline`, alloc/deref/incref/drop, uncounted)

**Goal:** A nullary constructor becomes `RVBox (Inline tag)` with zero allocations on both backends, synthesized back by `deref`, inert under dup/drop — with every existing machine site untouched.

**Files:**
- Modify: `src/Wok/Interp/RC/Value.hs` (`Addr`, `alloc`, `allocInline`, `deref`, `incref`, `dropAddr`, `isInline`, `isUncounted`, `countedRefs`, `closureOwnedBoxed`, export list)
- Modify: `src/Wok/Interp/RC/Machine.hs` (the one `runModuleRC` CAF guard, ~line 961)
- Modify: `test/Spec.hs` (add a targeted "nullary is inline" case to the C-backend group)
- Regenerate: `test/rc-stats-golden/*.expected` (the bool/arith goldens that shift)

**Acceptance Criteria:**
- [ ] `Addr` has the `Inline Word32` case; `isInline`/`isUncounted` exported.
- [ ] A bare nullary constructor (e.g. `main = []` / `main = None`) produces `allocs == frees == 0`, `peakLive == 0` on BOTH backends and renders identically (`[]`, `None`, `True`).
- [ ] A program mixing present and empty variants renders identically and ends `live == baseline` on both backends.
- [ ] `--dump-rc-stats` goldens regenerated for the programs whose nullary allocations vanished; the diff is justified (fewer allocs/frees, same output).
- [ ] Full suite green.

**Verify:** `cabal test wok-tests --test-options='-p "rc"' 2>&1 | tail -15` → all RC groups pass (parity + targeted + stats golden).

**Steps:**

- [ ] **Step 1: Add a failing targeted test** (a nullary constructor allocates nothing). In `test/Spec.hs`, in the C-backend targeted group (alongside the existing `rcCBackendTargeted` cases — follow their exact pattern, which runs a `.wok` program under both `AbstractHeap` and `CHeap` and asserts identical rendered output, identical `allocs`/`frees`/`peak`, and `live == baseline`), add a program whose result is a bare nullary constructor and assert `allocs == 0`:

Create `test/rc-cbackend/nullary-zero-alloc.wok`:
```
main = []
```
Add a case asserting the run's `stAllocs == 0 && stFrees == 0 && stPeak == 0` and the rendered output is `[]`, under both backends. (Use the same run helper the neighbouring targeted cases use.)

- [ ] **Step 2: Run it; watch it fail.**

Run: `cabal test wok-tests --test-options='-p "nullary-zero-alloc"' 2>&1 | tail -15`
Expected: FAIL — today `main = []` allocates one `Nil` cell, so `stAllocs == 1`, not 0.

- [ ] **Step 3: Add the `Inline` case and the uncounted predicates.** In `Value.hs`:
```haskell
data Addr = HAddr Int | CAddr (Ptr WokObj) | Inline Word32
  deriving (Eq, Ord, Show)
```
Add (near `isStaticAddr`):
```haskell
-- | True for an inline immediate (a nullary constructor with no cell).
isInline :: Addr -> Bool
isInline (Inline _) = True
isInline _          = False

-- | True for an address that owns no counted cell: a static (immortal) address
-- OR an inline immediate. The single filter the counted-ref / owned-set / CAF
-- paths use, so dup/drop and the free cascade skip both uniformly.
isUncounted :: Addr -> Bool
isUncounted a = isStaticAddr a || isInline a
```
Export `isInline` and `isUncounted` from the module header.

- [ ] **Step 4: Intercept nullary at `alloc`; synthesize at `deref`.** In `Value.hs`:
```haskell
alloc :: Node -> Store -> RC (Addr, Store)
alloc (NCon con []) s = pure (allocInline con s)   -- nullary: inline, both backends, no stat bump
alloc (NCon con vs) s = allocNCon con vs s
alloc n             s = pure (allocPure n s)

-- | A nullary constructor becomes an inline immediate carrying the interned tag.
-- No 'recordAlloc': an immediate lives on no heap.
allocInline :: Text -> Store -> (Addr, Store)
allocInline con s = let (tid, s') = internTag con s in (Inline tid, s')
```
```haskell
deref :: Addr -> Store -> RC Cell
deref (CAddr p)    s = liftIO (readCCell p s)
deref a@(HAddr _)  s = liftRC (derefPure a s)
deref (Inline tid) s = pure (Cell 0 (NCon (tagName tid s) []))   -- synthesize; rc placeholder 0
```

- [ ] **Step 5: Make dup/drop inert on `Inline`; filter it as uncounted.** In `Value.hs`:
```haskell
incref :: Addr -> Store -> RC Store
incref (CAddr p)   s = liftIO (H.wokDup p) >> pure s
incref a@(HAddr _) s = liftRC (increfPure a s)
incref (Inline _)  s = pure s
```
In `dropAddr`'s worklist `go`, add an arm (no cascade, no stats):
```haskell
    go (Inline _ : rest) s = go rest s
```
Switch the two filter sites from `isStaticAddr` to `isUncounted`:
```haskell
countedRefs = concatMap (filter (not . isUncounted) . valueChildren)
```
```haskell
closureOwnedBoxed (NClosure env _ _ OwnCaptures) =
  [ a | RVBox a <- Map.elems env, not (isUncounted a) ]
```

- [ ] **Step 6: Update the CAF guard.** In `Machine.hs` (~line 961), an `Inline` top-level result is already immortal — bind it as-is, never `writeStatic`-copy it:
```haskell
          (s'', envV) <- case v of
            RVBox dynAddr | not (isUncounted dynAddr) ->
              (\c -> (writeStatic a (cNode c) s', RVBox a)) <$> deref dynAddr s'
            _ -> pure (s', v)
```
(`isUncounted` is already in scope via the existing `Wok.Interp.RC.Value` import; add it to the import list if explicit.)

- [ ] **Step 7: Run the targeted test; watch it pass.**

Run: `cabal test wok-tests --test-options='-p "nullary-zero-alloc"' 2>&1 | tail -15`
Expected: PASS — `main = []` now allocates nothing on both backends, renders `[]`.

- [ ] **Step 8: Regenerate the shifted stats goldens.** The bool/arith programs now allocate fewer cells (booleans → immediates). Regenerate with tasty-golden accept, scoped to the stats group:

Run: `cabal test wok-tests --test-options='--accept -p "rc differential"'`
Then inspect the diff: `git diff test/rc-stats-golden/` — confirm every change is a *reduction* in allocs/frees (e.g. `17-bool-ops`, `19-shared-bool`, `02-arith`) with identical program output, and nothing else shifted.

- [ ] **Step 9: Full suite green.**

Run: `cabal test wok-tests 2>&1 | tail -15`
Expected: all groups pass (parity unaffected — both backends shifted identically).

- [ ] **Step 10: Commit.**
```bash
git add src/Wok/Interp/RC/Value.hs src/Wok/Interp/RC/Machine.hs test/Spec.hs test/rc-cbackend/ test/rc-stats-golden/
git commit -m "feat(rc): nullary constructors as inline immediates (Addr Inline, alloc/deref chokepoints)"
```

---

### Task 3: Slot encoding — the 2-bit low tag

**Goal:** An immediate can live INSIDE a C cell's slot (e.g. `Cons 2 Nil`'s tail) via a 2-bit low tag, so an immediate-bearing constructor stays C-resident instead of falling back to the abstract heap.

**Files:**
- Modify: `src/Wok/Interp/RC/Value.hs` (`encodeSlotC`, `decodeSlotC`)
- Modify: `test/Spec.hs` (`rcCBackendSlotProperty`: refresh the round-trip property; `rcCBackendTargeted`: add the mixed pointer/immediate cascade case)
- Create: `test/rc-cbackend/mixed-maybe-list.wok`

**Acceptance Criteria:**
- [ ] `encodeSlotC`/`decodeSlotC` round-trip is identity over `Int64`-fit ints, char, unit, `CAddr`, `HAddr` (incl. negative/static indices through the new `<< 2` shift), and `Inline` tags.
- [ ] The three pointer-class low tags are mutually exclusive (a `CAddr` decodes to `CAddr`, never to `HAddr`/`Inline`, etc.).
- [ ] A `Maybe`/list with both `Some`/`Cons` (pointers) and `None`/`Nil` (immediates) runs C-resident, renders identically to the abstract backend, and ends `live == baseline` (the cascade skips the immediate slots — no double-free, no leak).
- [ ] Full suite green.

**Verify:** `cabal test wok-tests --test-options='-p "c-backend"' 2>&1 | tail -15` → slot property + parity + targeted all pass.

**Steps:**

- [ ] **Step 1: Update the round-trip property to fail first.** In `test/Spec.hs` `rcCBackendSlotProperty`, extend the generator to also produce `RVBox (Inline tag)` values and negative `HAddr` indices, and keep the `decodeSlotC . encodeSlotC == id` assertion plus a new "low tags mutually exclusive" assertion. With the encoder still on the 1-bit scheme, the `Inline` generator case has no encoding (hits the catch-all `Nothing`), so the property fails to round-trip.

Run: `cabal test wok-tests --test-options='-p "slot"' 2>&1 | tail -15`
Expected: FAIL — `Inline` not yet encodable / `HAddr` shift mismatch.

- [ ] **Step 2: Adopt the 2-bit scheme.** In `Value.hs`:
```haskell
encodeSlotC :: RCValue -> Maybe (SlotKind, Word64)
encodeSlotC (RVLit (LInt n))   = (\w -> (KLitInt, fromIntegral (w :: Int64))) <$> toIntegralSized n
encodeSlotC (RVLit (LChar c))  = Just (KLitChar, fromIntegral (fromEnum c))
encodeSlotC (RVLit LUnit)      = Just (KLitUnit, 0)
encodeSlotC (RVBox (CAddr p))  = Just (KPointer, fromIntegral (ptrToWordPtr p))            -- low bits 00
encodeSlotC (RVBox (HAddr i))  = Just (KPointer, fromIntegral ((i `shiftL` 2) .|. 1))      -- 01, was << 1
encodeSlotC (RVBox (Inline t)) = Just (KPointer, (fromIntegral t `shiftL` 2) .|. 3)        -- 11, NEW
encodeSlotC _                  = Nothing
```
```haskell
decodeSlotC :: SlotKind -> Word64 -> RCValue
decodeSlotC KLitInt  w = RVLit (LInt (fromIntegral (fromIntegral w :: Int64)))
decodeSlotC KLitChar w = RVLit (LChar (decodeChar w))
decodeSlotC KLitUnit _ = RVLit LUnit
decodeSlotC KPointer w
  | w .&. 1 == 0 = RVBox (CAddr (wordPtrToPtr (WordPtr (fromIntegral w))))                    -- 00
  | w .&. 2 == 0 = RVBox (HAddr (fromIntegral ((fromIntegral w :: Int64) `shiftR` 2)))        -- 01
  | otherwise    = RVBox (Inline (fromIntegral (w `shiftR` 2)))                                -- 11
```
Update the Haddock above these functions to describe three pointer-classes via the low 2 bits.

- [ ] **Step 3: Run the property; watch it pass.**

Run: `cabal test wok-tests --test-options='-p "slot"' 2>&1 | tail -15`
Expected: PASS — round-trip identity over all classes incl. `Inline` and negative `HAddr`.

- [ ] **Step 4: Add the mixed pointer/immediate cascade test.** Create `test/rc-cbackend/mixed-maybe-list.wok`:
```
data Opt = None | Some(U64)

main = [Some(1), None, Some(3), None]
```
Add it to the C-backend targeted group with the standard assertion (identical render on both backends; `live == baseline` at end). This exercises an immediate (`None`) inside a C `Cons` slot and the cascade skipping it.

- [ ] **Step 5: Full suite green.**

Run: `cabal test wok-tests 2>&1 | tail -15`
Expected: all groups pass; no `--dump-rc-stats` golden shifts (Task 3 changes the heap a parent lands on, not alloc counts).

- [ ] **Step 6: Commit.**
```bash
git add src/Wok/Interp/RC/Value.hs test/Spec.hs test/rc-cbackend/mixed-maybe-list.wok
git commit -m "feat(rc): 2-bit low slot tag (CAddr/HAddr/Inline) so immediates live in C cells"
```

---

### Task 4: `wok_stat_peak_bytes` counter + benchmark report + whole-corpus parity

**Goal:** Track high-water live bytes in the C runtime, surface it in `--dump-rc-stats`, produce the before/after benchmark report, and confirm the whole-corpus differential oracle is still green.

**Files:**
- Modify: `runtime/wok_rc.h` (declare `wok_stat_peak_bytes`)
- Modify: `runtime/wok_rc.c` (track `cur_bytes`/`peak_bytes` in both builds)
- Modify: `src/Wok/Interp/RC/Heap.hs` (FFI import + export)
- Modify: `app/Main.hs` and/or `src/Wok/Interp/RC/Machine.hs` (`--dump-rc-stats` output — only where a C heap is live)
- Modify: `runtime/test/wok_rc_bench.c` (optional: an arity-0 alloc/free microbench arm)
- Create: `bench/RESULTS.md`

**Acceptance Criteria:**
- [ ] `wok_stat_peak_bytes` is declared and returns the high-water `Σ (8 + 8·arity)` over live cells, in BOTH the arena and `WOK_RC_MALLOC` builds; `_Static_assert`s and the existing stat accessors unchanged.
- [ ] `bench/RESULTS.md` tabulates allocs/frees/peakLive (from `bench/baseline.txt`) vs the post-Slice-2 numbers, with the per-program reduction; tree shows ~50% fewer cells, bools shows boolean allocs → 0, list shows a small constant.
- [ ] The whole-corpus `rcCBackendParity` is green (output + allocs/frees/peak + `live == baseline`).
- [ ] Sanitizer matrix still clean (no `WokObj`/ABI change).

**Verify:** `bash scripts/rc-bench.sh` (now includes peak bytes) and `bash scripts/asan-runtime.sh` → bench table prints; sanitizers clean.

**Steps:**

- [ ] **Step 1: Declare the accessor.** In `runtime/wok_rc.h`, after `wok_stat_slabs`:
```c
WOK_PURE uint64_t wok_stat_peak_bytes(const WokHeap* h);
```

- [ ] **Step 2: Track bytes in both builds.** In `runtime/wok_rc.c`, add `uint64_t cur_bytes; uint64_t peak_bytes;` to BOTH `struct WokHeap` definitions (after the shared `allocs/frees/live/peak` prefix, preserving that prefix). In each build's `wok_alloc`, after the stat bump:
```c
    h->cur_bytes += wok_cell_bytes(arity);
    if (h->cur_bytes > h->peak_bytes) { h->peak_bytes = h->cur_bytes; }
```
In each build's `wok_free`, after computing `arity`:
```c
    h->cur_bytes -= wok_cell_bytes(arity);
```
And once (shared region near the other accessors):
```c
uint64_t wok_stat_peak_bytes(const WokHeap* h) { return h->peak_bytes; }
```
`calloc` already zeroes the new fields. Compiles under the existing `-Werror -Wconversion` wall (`wok_cell_bytes` returns `size_t`; add the `(uint64_t)` cast if the wall flags it).

- [ ] **Step 3: Bind it in Haskell.** In `src/Wok/Interp/RC/Heap.hs` add to the export list `wokStatPeakBytes` and:
```haskell
foreign import ccall unsafe "wok_stat_peak_bytes" wokStatPeakBytes :: Ptr WokHeap -> IO Word64
```

- [ ] **Step 4: Surface it in `--dump-rc-stats`.** In the `--dump-rc-stats` renderer (`app/Main.hs` / the `renderRCStats` path in `Machine.hs`), when the run used a `CHeap` backend, append a `peakBytes <n>` line read from `wokStatPeakBytes`. Guard it so the abstract-only path (no live C heap) is unchanged — do NOT add it to the existing `test/rc-stats-golden` output (those run on the abstract backend; changing their format would re-shift every golden). Bench-only.

- [ ] **Step 5: Run the suite (C path) green.**

Run: `cabal test wok-tests --test-options='-p "c-backend"' 2>&1 | tail -15`
Expected: PASS — parity intact; the new counter does not perturb output/stat parity.

- [ ] **Step 6: Produce the report.** Re-run the bench on the branch and diff against the baseline:

Run: `bash scripts/rc-bench.sh | tee bench/after.txt`
Then write `bench/RESULTS.md` with a table: program | before (allocs/frees/peakLive from `bench/baseline.txt`) | after (from `bench/after.txt`) | Δ and % | peakBytes (after). Add one honest sentence per row (tree: ~50% fewer cells; bools: boolean allocs → 0; maybes: per-`None` cell gone; list: small constant). Remove the scratch `bench/after.txt`.

- [ ] **Step 7: (Optional) C-level alloc microbench arm.** In `runtime/test/wok_rc_bench.c`, add a loop timing N arity-0 `wok_alloc`/`wok_free` pairs (the allocator work immediates eliminate); print ns/op. Build/run via the existing bench build path. This is the only legitimate real *time* number.

- [ ] **Step 8: Sanitizers.**

Run: `bash scripts/asan-runtime.sh 2>&1 | tail -15`
Expected: ASan/UBSan clean over the standalone C test (incl. the new counter).

- [ ] **Step 9: Commit.**
```bash
git add runtime/wok_rc.h runtime/wok_rc.c src/Wok/Interp/RC/Heap.hs app/Main.hs src/Wok/Interp/RC/Machine.hs runtime/test/wok_rc_bench.c bench/RESULTS.md scripts/rc-bench.sh
git commit -m "bench(rc): wok_stat_peak_bytes counter + Slice 2 before/after report"
```

---

### Task 5: Docs + memory + spec status

**Goal:** Update the durable runtime contract and the design spec to reflect the implemented immediate scheme, and record the memory note.

**Files:**
- Modify: `runtime/README.md` (the slot encoding table; nullary = immediate, no cell)
- Modify: `docs/superpowers/specs/2026-06-22-layout-compaction-slice2-design.md` (Status → IMPLEMENTED, with any implementation findings)
- Modify: `docs/superpowers/runtime-knowledge-base.md` (one line under §6: immediates landed)
- Create/Modify: the auto-memory note `layout-compaction-slice2` + `MEMORY.md` pointer

**Acceptance Criteria:**
- [ ] `runtime/README.md`'s "Slot encoding" section documents the 2-bit low tag (00 CAddr / 01 HAddr / 11 Inline) and states a nullary constructor is an inline immediate with no cell.
- [ ] The spec's Status line reads IMPLEMENTED with the branch name and the final green count, plus any deviation from the plan recorded.
- [ ] A memory note records the slice (what shipped, the `Inline` name, the 2-bit scheme, the benchmark result headline, what's deferred).

**Verify:** `git diff --stat` shows the doc/memory updates; `grep -n "Inline" runtime/README.md` shows the slot-table update.

**Steps:**

- [ ] **Step 1: Update `runtime/README.md`.** In the "Slot encoding (descriptor-driven)" section, change the `KPointer` rows to the three low-tag classes (CAddr `00` / HAddr `01` / Inline `11`) and add a sentence to the object-layout section: a zero-field constructor is an inline immediate (`RVBox (Inline tag)`), allocated as no cell, so the C heap never holds an arity-0 cell.

- [ ] **Step 2: Flip the spec status.** Edit the spec header Status to `IMPLEMENTED (branch feat/layout-compaction-slice2, <N> green)` and add a short "Implementation findings" note if anything diverged (e.g. a bench program reworded for the parser).

- [ ] **Step 3: Knowledge base + memory.** Add one line under runtime-KB §6 ("Immediates (Slice 2, MERGED): nullary cons are inline `Inline tag`, no cell; 2-bit low slot tag adds the immediate class beside C/H"). Write the `layout-compaction-slice2` memory note + its `MEMORY.md` pointer (what shipped, deferred cleanups, the benchmark headline).

- [ ] **Step 4: Commit.**
```bash
git add runtime/README.md docs/superpowers/specs/2026-06-22-layout-compaction-slice2-design.md docs/superpowers/runtime-knowledge-base.md
git commit -m "docs(rc): record Slice 2 immediates (README slot table, spec IMPLEMENTED, KB)"
```

---

## Final verification (before merge review)

- [ ] `cabal test wok-tests 2>&1 | tail -15` → full suite green.
- [ ] `bash scripts/asan-runtime.sh` → sanitizers clean.
- [ ] `bash scripts/rc-bench.sh` matches `bench/RESULTS.md`.
- [ ] Full-branch `/code-review` (per the repo's review-before-merge rule) — NOT a per-task substitute.
