# C runtime arena allocator (slab + arity-exact free lists)

- **Date:** 2026-06-21
- **Status:** IMPLEMENTED (branch feat/c-runtime-arena-allocator)
- **One line:** Replace slice-1's plain `malloc`/`free` behind the (frozen) `wok_rc`
  ABI with a per-run **slab arena**: bump-pointer allocation, **arity-exact size-class
  free lists** for O(1) cache-warm reuse (the FBIP substrate), and O(slabs) bulk teardown —
  the codegen-ready allocator the slice-1 spec deferred (§9 "Language-specific
  allocator"), validated against the slice-1 malloc run as oracle.

---

## 1. Goal and non-goals

### Goal

Slice 1 put constructor cells (`NCon`) on a real C heap but deliberately used plain
`malloc`/`free` per cell — to isolate the RC *cascade* as the variable under test
(`2026-06-21-c-runtime-allocator-ncon-design.md` §4, Decision 1). That cascade is now
proven (1278 green, abstract ⟷ C parity). This slice swaps the trusted-but-slow
allocator for the **real one a codegen backend wants**, *without changing the ABI* and
*without touching the Haskell interpreter core*.

The allocator delivers the two properties the user named — **throughput** and **very low
latency** — as *structural design properties*, not interpreter wall-clock claims:

- **Throughput:** allocation is O(1) — a free-list **pop** when a same-arity cell is
  available (the common FBIP case, preferred), else a pointer **bump**; neither path
  searches. Reclamation is a free-list **push** (no `free()` syscall on the hot path),
  LIFO so the just-freed, cache-warm cell is handed straight back.
- **Low latency:** there is **no collector** (see §3). Reclamation is Perceus RC, eager
  and incremental — there is no mark phase, no sweep, no GC thread, and therefore **no
  stop-the-world pause, ever**. The arena adds only O(1) bump/push on the hot path and
  one `malloc` per *slab* (~one per thousands of cells), not per cell.

The artifact is the durable allocator a future codegen path emits against. The cell
*representation* (16 B header + 16 B slots) is unchanged here — shrinking it is the
separately-designed layout-compaction slice.

### Why this, why now

The user selected this over layout-compaction because: (1) it is behind a **frozen ABI**,
so the blast radius on the 1278-green oracle is the smallest of the available slices;
(2) it delivers the throughput/latency substrate without touching the value
representation; and (3) compaction then lands cleanly on top. Studying LuaJIT's New-GC
arena confirmed the shape (cell-granular, variable-size objects packed consecutively,
bump + segregated free lists) and — importantly — let us *drop* the parts that don't
apply to an RC runtime (the mark/sweep bitmaps; see §3 and §10).

### Non-goals (explicitly out of scope)

- **Layout compaction.** Header/slot stay 16 B. The 8 B-header + tagged/raw-word-slot
  + nullary-as-immediate work is the next, separately-designed slice.
- **Pointer-tagging / immediates / full-`U64` raw slots.** Same — that is compaction.
- **Pointer-masking to find arena metadata.** Not needed here: free-list routing uses the
  `arity` already in the header plus the `WokHeap*` already passed to `wok_free`. Aligned
  slabs + masking are a *future* enabler (a block bitmap, per-arena reclaim) and are
  explicitly deferred (§10). We do **not** pay for alignment speculatively.
- **A block/mark bitmap.** wok stores `arity` in the header, so an object's size is
  already known at free time — LuaJIT's "size = distance to next block bit" trick buys us
  nothing here. Deferred until heap-walking or cycle collection actually needs it (§10).
- **A collector.** wok is reference-counted; there is nothing to collect (§3). A cycle
  collector is out of scope and currently unnecessary (cycles are *prevented*, see the
  `m3-stored-continuations` memory note).
- **mimalloc / first-class heaps.** The hand-rolled slab arena is deliberately chosen over
  mimalloc (whose v2 thread-bound-alloc rule races silently under GHC's migrating RTS —
  `2026-06-21-mimalloc-koka-allocator-research.md`). mimalloc v3 / a bound-thread heap
  remains a possible *future* swap behind this same ABI.
- **Speed claims under the interpreter.** A real allocator under a tree-walker is still a
  tree-walker; no end-to-end wall-clock claim is made (as in slice 1). The honest
  allocator-level signal is a *standalone* C microbenchmark (§6) and the reuse/resident
  stats (§5) — not interpreter timings.

---

## 2. Background: what exists today (the frozen ABI)

`runtime/wok_rc.{c,h}` exposes (this is the **contract**, unchanged by this slice):

```c
WokHeap* wok_heap_new(void);                 // per-run context
void     wok_heap_free(WokHeap* h);          // teardown; warns on residual live
WokObj*  wok_alloc(WokHeap* h, uint32_t tag, uint32_t arity);  // rc=1, slots undef
void     wok_dup(WokObj* p);                 // rc++
uint64_t wok_dec(WokObj* p);                 // rc--, returns NEW rc; no free
void     wok_free(WokHeap* h, WokObj* p);    // caller has read slots first
void     wok_slot_set/get(...); uint32_t wok_tag/arity(...);
uint64_t wok_stat_allocs/frees(const WokHeap*); int64_t wok_stat_live/peak(const WokHeap*);
```

A cell is `WokObj{ uint64 rc; uint32 tag; uint32 arity; WokSlot slots[]; }` with
`WokSlot{ uint64 tag; uint64 payload; }`. Total size `16 + 16*arity` bytes — always a
multiple of 16. Today `wok_alloc` is `malloc`, `wok_free` is `free`, and `wok_heap_free`
asserts `live == 0` and frees nothing.

The **stats are logical**: `wok_alloc` does `allocs++; live++; peak = max(peak,live)`,
`wok_free` does `frees++; live--`. They count *constructor* allocs/frees, not `malloc`
calls. The differential oracle (`AbstractHeap` ⟷ `CHeap`) checks these match exactly and
that rendered results are byte-identical. **This slice keeps the logical-stat semantics
identical, which is why the oracle keeps working unchanged.**

The Haskell side reaches C only through the FFI in `Wok.Interp.RC.Heap`; the `CHeap`
backend in `Wok.Interp.RC.Value` calls `wokAlloc`/`wokFree`/… It never inspects how memory
is obtained. **So the Haskell interpreter core needs no change.**

---

## 3. Do we need a collector? No — and that absence *is* the latency story

Two words kept apart:

- **Allocator** — hands memory out (bump) and takes it back (free list). This slice.
- **Collector** — *decides what is garbage* (tracing/marking, a sweep, a GC thread).

wok decides garbage **incrementally, by the refcount reaching zero** (Perceus,
compiler-inserted). There is no trace, no mark, no sweep, no GC thread — so there is **no
collector**, and the arena never acquires one. `wok_free` is *triggered by* RC
(`wok_dec` returning 0, then the Haskell-driven cascade), and all the arena does at that
moment is push the cell onto a free list. That absence is exactly where "very low latency"
comes from: no collector ⇒ no pauses.

The only thing that could reintroduce a collector is reclaiming **reference cycles** (RC
alone cannot). wok currently *prevents* cycles by construction rather than collecting them
(`m3-stored-continuations` note: "cycle PREVENTED-not-collected"). If that ever changed,
the minimal addition is a Bacon-Rajan trial-deletion collector or an LXR-style backup
trace (RC + an Immix-style bitmap sweep, PLDI 2022) — and *that* is the single place a
block/mark bitmap would return. It is out of scope and unnecessary now.

---

## 4. The arena allocator (design)

### Cell granularity = arity-exact size classes

Every cell is `16 + 16*arity` bytes — a multiple of the 16-byte granule. So an object of
arity `a` is exactly `1 + a` granules, and **`arity` itself is the size class**. A freed
arity-`a` cell goes on `freelist[a]`; an alloc of arity `a` pops from `freelist[a]`.
Because the class is the exact arity, reuse is **exact-fit with zero internal
fragmentation** — strictly cleaner than a rounded size-class allocator, and it needs no
bitmap to recover a cell's size (the header already has `arity`).

This realizes the slice-1 spec's deferred goal verbatim: "exact arity-keyed size classes
(`16 + 16*arity` → 16/32/48/64…, zero rounding waste, few hot classes) … LIFO same-class
reuse (the FBIP substrate)."

**Relationship to LuaJIT — granule-span yes, splitting no.** Like LuaJIT, the 16-byte
granule is the unit and a bigger node is **multiple contiguous granules** (`1 + arity` of
them), bump-placed consecutively. We diverge from LuaJIT's *general* allocator on the reuse
policy: we keep **whole-object, exact-fit free lists keyed by `arity`** and do **no
splitting and no coalescing** (a freed arity-2 block returns whole to `freelist[2]`; we
never carve a 6-granule run into a 3-granule object + leftover, nor merge adjacent free
runs). Two reasons: Perceus/FBIP reuse is almost always **same-shape** (drop a `Cons`,
build a `Cons`), so exact-fit per arity hits the case that matters; and skipping
split/coalesce is exactly what lets us **avoid the block bitmap** (size comes from the
header `arity`, not from scanning object boundaries). The accepted cost is **cross-class
fragmentation** — freed arity-2 granules sit in `freelist[2]` and cannot serve an arity-5
burst, which bumps fresh. Benign for shape-stable RC/FBIP allocation; if profiling ever
shows real waste, the upgrade is LuaJIT-style split/coalesce, which reintroduces the bitmap
(§10).

### Slabs, bump, free lists, large fallback

The per-run `WokHeap` owns:

```c
#define WOK_GRANULE     16
#define WOK_ARENA_SIZE  (64 * 1024)   /* slab bytes; tunable (§11) */
#define WOK_NUM_CLASSES 64            /* arities 0..63 use slabs; >=64 -> large path */

typedef struct WokSlab { struct WokSlab* next; } WokSlab;  /* cells follow, 16-aligned */

struct WokHeap {
    uint64_t allocs, frees;          /* logical stats, semantics unchanged */
    int64_t  live, peak;
    WokSlab* slabs;                  /* linked list, for O(slabs) bulk teardown (no object walk) */
    char*    bump_ptr, *bump_end;    /* cursor within the current slab */
    WokObj*  freelist[WOK_NUM_CLASSES];  /* per-arity LIFO; NULL = empty */
};
```

**Allocate** `wok_alloc(h, tag, arity)`:

1. `sz = 16 + 16*arity`.
2. If `arity < WOK_NUM_CLASSES`:
   - **reuse** (preferred — cache-warm): if `freelist[arity]` non-empty, pop its head.
   - else **bump**: if the current slab can't fit `sz`, allocate a fresh slab
     (`malloc(WOK_ARENA_SIZE)`, link it on `slabs`, reset `bump_ptr/end`); then take
     `p = bump_ptr; bump_ptr += sz`. (`arity < 64 ⇒ sz ≤ 1024 ≪ 64 KiB`, so a fresh slab
     always fits — no object ever exceeds a slab.)
3. Else (**large**, `arity ≥ 64`): `p = malloc(sz)` directly (a real, individually
   `free`-able pointer — never a slab interior).
4. Init `p->rc=1; p->tag=tag; p->arity=arity`. `allocs++; live++; peak=max(peak,live)`.

**Free** `wok_free(h, p)`:

1. Guard `p->rc != 0 ⇒ abort()` (premature-free, unchanged).
2. `frees++; live--`.
3. If `p->arity < WOK_NUM_CLASSES`: push `p` onto `freelist[p->arity]` (LIFO). The freed
   cell's own first 8 bytes hold the free-list `next` link (see below).
4. Else: `free(p)` (the large path's cells are real `malloc` pointers).

`p->arity` deterministically selects the same path the cell was allocated through, so no
per-cell "where did I come from" flag is needed.

**Teardown** `wok_heap_free(h)`: warn if `live != 0` (logical leak, unchanged), then walk
`slabs` and `free` each (**O(1)-per-slab bulk teardown**), then free `h`. Large-path cells
are freed individually on drop; a *leaked* large cell remains a real `malloc` leak
(LeakSanitizer-visible — a useful asymmetry, §6).

### Strict-aliasing-safe free-list link

The freed cell is dead, so its bytes store the `next` pointer. Writing a pointer through
the `uint64 rc` field would violate `-fstrict-aliasing`; instead use `memcpy` into/out of
the cell's first 8 bytes:

```c
static inline WokObj* fl_next(WokObj* p)            { WokObj* n; memcpy(&n, p, sizeof n); return n; }
static inline void    fl_set_next(WokObj* p, WokObj* n) { memcpy(p, &n, sizeof n); }
```

On pop, the full header is re-initialised, so clobbering it on the free list is fine.

### Alignment, NULL-arithmetic, invariants

- `malloc` returns ≥16-byte-aligned memory on LP64; cells start at `slab + align16(sizeof
  WokSlab)` (= `slab + 16`), and `sz` is a multiple of 16, so every cell stays 16-aligned.
- The empty heap has `bump_ptr == bump_end == NULL`. The capacity check is written to
  avoid UB pointer arithmetic on `NULL`:
  `if (bump_ptr == NULL || sz > (size_t)(bump_end - bump_ptr)) new_slab(h);`
- `_Static_assert(WOK_ARENA_SIZE % WOK_GRANULE == 0, ...)` and
  `_Static_assert((16 + 16*(WOK_NUM_CLASSES-1)) < WOK_ARENA_SIZE, ...)` (every slab class
  fits a slab), alongside the existing `sizeof(WokSlot)==16` / `sizeof(WokObj)==16` asserts.

### Thread safety

A `WokHeap` is touched by exactly one run's single-threaded interpreter. GHC may migrate
that run across OS threads but never runs it concurrently, and there is **no global
state** — so the arena needs no locks. (This is precisely why the hand-rolled arena is
*safer* under GHC than mimalloc v2's thread-bound heaps.)

---

## 5. Stats: identical logical totals, plus optional observability

The logical counters (`allocs/frees/live/peak`) are bumped exactly as today, so **abstract
⟷ C stat parity holds with no change**. Reuse and bulk teardown change *how many
`malloc`s happen*, not the logical alloc/free counts — which is the whole point of the
oracle being defined on logical stats.

Optional, **ABI-additive** observability readers (new functions, not a break) substantiate
the throughput/latency design without an interpreter wall-clock claim:

- `wok_stat_reused(h)` — free-list pops (FBIP reuse hits).
- `wok_stat_slabs(h)` — slabs `malloc`'d (allocation-syscalls, vs logical `allocs`).

These are *not* oracle-checked (they legitimately differ from the abstract heap), and they
are read by the standalone microbench/test (C-side), so they need **no Haskell binding**
(keeping §7's "near-zero Haskell change" intact). They are for the perf narrative and a
sanity check that reuse is actually happening.

---

## 6. Verification — making the *allocator* the variable under test

Slice 1 trusted the allocator and tested the cascade. This slice **inverts that**: the
cascade is fixed and proven; the hand-rolled allocator is now the risk. The cascade being
unchanged means *any new divergence after this slice is an allocator bug* — git history
isolates it. Validation, in proportion to a memory-safety surface:

1. **Abstract ⟷ C-arena parity over the whole corpus (primary).** The existing differential
   harness now exercises the arena (the `CHeap` default becomes the arena). Byte-identical
   rendered results + exact `allocs/frees/peak` match + `live == baseline` at clean end.
   This catches logical errors *and* the memory bugs that change a result: a double
   hand-out (two live cells aliasing) corrupts a slot write and diverges; a wrong-size
   block overflows into a neighbour and diverges; a missing recycle shows up as a stat or
   `live` mismatch. Strong end-to-end signal, free (methodology unchanged).

2. **Standalone C test exercising the arena, under ASan/UBSan + poison-on-free (memory
   safety).** `runtime/test` drives the arena directly: bump across slab boundaries,
   free-list reuse, exact-fit per class, the large path (`arity ≥ 64`), interleaved
   alloc/free churn, and bulk teardown. Compiled at `-O1 -fsanitize=address,undefined` with
   LeakSanitizer (`scripts/asan-runtime.sh`). ASan catches slab-overflow (a bump past a
   slab's malloc'd extent hits ASan's redzone) and slab leaks at teardown; UBSan catches
   the pointer-arithmetic and shift UB. **Poison-on-free** (a debug `memset(p, 0xDE, sz)`
   *before* relinking, so the link bytes survive) makes a use-after-free of a *recycled*
   cell read `0xDE` garbage — which ASan cannot see inside a still-live slab, but which then
   diverges under the parity harness. Defense-in-depth, not load-bearing.

3. **Retain slice-1's `malloc`/`free` behind `#ifdef WOK_RC_MALLOC` (UAF oracle + perf
   baseline).** Kept *only* for the standalone test/microbench, not in the Haskell path. A
   `WOK_RC_MALLOC` build does one `malloc` per cell and a real `free` per drop, so ASan/LSan
   see *every* use-after-free and leak — the strongest memory-safety oracle for the
   cascade-shaped access pattern. The same flag gives the microbench its baseline.

4. **Standalone allocator microbenchmark (honest perf signal).** A C-level loop
   (N allocs/frees/reuses across the class distribution) timed `WOK_RC_MALLOC` vs arena.
   This measures the *allocator*, not the interpreter, so it is a fair wall-clock
   comparison and substantiates the throughput claim without overclaiming on the
   tree-walker. Reported, not gated.

5. **Targeted assertions** — the memory/reuse ones are assertions *inside* the standalone C
   test of (2) (pointer identity is naturally C-side); only stats-invariance is the tasty
   differential of (1), so there is **no new Haskell test home**: exact-fit reuse (free
   arity-2, next arity-2 alloc returns the *same* address; an arity-3 alloc does **not**);
   slab-boundary bump (force a new slab, results still correct); the large path
   (`arity ≥ 64` round-trips and frees); bulk teardown frees all slabs with no leak (LSan);
   stats invariance (arena `allocs/frees/peak` equal the abstract heap's over a fixed
   program).

**Leak-signal note (important):** with bulk teardown, a *logical* leak of a small cell is
no longer a real `malloc` leak (the slab is bulk-freed), so LSan can't see it — the
stat-based `live == baseline` check is THE leak detector for slab cells (it always was, per
slice 1). Large-path leaks stay LSan-visible. The spec calls this out so the stat check is
understood as load-bearing.

---

## 7. The Haskell side: essentially nothing

The arena lives entirely in `runtime/wok_rc.c`. The FFI signatures in
`Wok.Interp.RC.Heap`, the `CHeap` backend in `Wok.Interp.RC.Value`, `deref`, the cascade,
`recordAlloc`/`recordFree`, and every test that runs the RC interpreter are **unchanged** —
they call the same ABI and observe the same logical stats. `app/Main.hs` keeps calling
`wok_heap_new()` (now arena). The only optional Haskell touch is *test-side*: if we want the
microbench/UAF baseline reachable from Haskell we add a test-only `wokHeapNewMalloc`
binding — but the recommendation (§6) keeps `WOK_RC_MALLOC` in the standalone C test, so
even that is unnecessary. This near-zero Haskell footprint is the core of the de-risking.

---

## 8. Task breakdown (each ships green)

> Native tasks are created at the writing-plans step, after this spec is approved.

- **Task 1 — the arena in `wok_rc.c`.** `WokHeap` fields, slabs, bump, arity free lists,
  large path, strict-aliasing free-list link, NULL-safe capacity check, the new
  `_Static_assert`s, `wok_heap_free` bulk teardown, poison-on-free under a debug flag, and
  the optional observability stat readers. ABI header `wok_rc.h` gains only the additive
  stat readers; no existing signature changes. The standalone C test (`runtime/test`) and
  `scripts/asan-runtime.sh` are extended to exercise the arena (and the `WOK_RC_MALLOC`
  baseline). Ships green: the C standalone + ASan pass; the Haskell side still calls
  `wok_heap_new()` and behaves identically.
- **Task 2 — oracle + targeted tests.** Confirm abstract ⟷ C-arena parity over the whole
  corpus (now exercising the arena); add the §6 item-5 targeted assertions (exact-fit reuse,
  slab-boundary, large path, bulk teardown, stats invariance); wire the microbench as a
  reported (non-gated) check.
- **Task 3 — docs + memory.** Update `runtime/README.md` (the allocator section: now a slab
  arena, ABI unchanged, `malloc` retained behind `WOK_RC_MALLOC` for the oracle/baseline);
  mark the slice-1 spec §9 "Language-specific allocator" implemented; update the
  `c-runtime-ncon-allocator` memory note; clean up scaffolding.

---

## 9. Risks and mitigations

| Risk | Mitigation |
| ---- | ---------- |
| Hand-rolled allocator hands out an aliasing/overlapping block | Abstract ⟷ C-arena result parity diverges on any corruption; exact-fit unit test; ASan slab-overflow redzone. |
| Use-after-free of a *recycled* cell is invisible to ASan (slab still live) | `WOK_RC_MALLOC` standalone build gives real per-cell free (ASan sees all UAF); poison-on-free makes recycled-UAF diverge under parity. |
| Bulk teardown masks a logical leak (LSan blind) | Stat-based `live == baseline` is the load-bearing leak detector (documented §6); large-path leaks stay LSan-visible. |
| Strict-aliasing UB in the free-list link | `memcpy` link helpers, never a pointer-through-`uint64` cast; UBSan in CI. |
| NULL pointer-arithmetic on the empty heap | Explicit `bump_ptr == NULL` short-circuit before any `bump_end - bump_ptr`. |
| `arity ≥ WOK_NUM_CLASSES` cell wrongly slab-allocated then `free()`d (slab-interior free) | The `arity < WOK_NUM_CLASSES` test gates *both* alloc and free identically; large cells are always real `malloc` pointers; unit test on the boundary. |
| Stats drift breaks the oracle | Logical `allocs/frees/live/peak` bumped exactly as slice 1; new stats are additive and not oracle-checked. |
| GHC RTS thread migration races the allocator | No global state, one `WokHeap` per single-threaded run, no locks needed (unlike mimalloc v2). |

---

## 10. Explicitly deferred

- **Aligned slabs + pointer-masking + block bitmap.** The enablers for a future
  descriptor-driven C cascade, heap-walking, and (if ever) cycle collection. Not needed for
  arity-keyed free-list routing; not paid for now.
- **Layout compaction** (8 B header, tagged/raw-word slots, full-`U64` raw fields via a
  per-constructor descriptor, nullary-as-immediate). The next slice; lands behind this same
  ABI on top of this allocator.
- **mimalloc v3 / bound-thread heaps.** A possible later swap behind `wok_alloc`/`wok_free`
  with no ABI change; this hand-rolled arena is the slice-1-validated oracle for it.
- **Oversized-cell reuse.** The large path (`arity ≥ 64`) does not free-list-recycle; it is
  a rare correctness fallback (real corpora keep arity well under 64). Add a size-keyed large
  free list only if a workload ever needs it.
- **Splitting / coalescing free blocks (the LuaJIT-general-allocator upgrade).** This slice
  does whole-object exact-fit reuse with no splitting/coalescing (§4). If profiling shows
  cross-class fragmentation hurting resident memory, the upgrade is to split larger free
  runs and coalesce adjacent free granules — which needs a block bitmap (or equivalent
  boundary map) to find neighbours, the one mechanism this slice deliberately omits.
- **A cycle collector** (Bacon-Rajan trial deletion / LXR backup trace). Only if cycles ever
  need *collecting* rather than *preventing* — the one path that reintroduces a bitmap.

---

## 11. Decisions resolved (override if needed)

Settled during brainstorming (2026-06-21), validated against the LuaJIT New-GC arena and
the mimalloc/Koka research:

1. **Allocator-slice first**, layout-compaction next — lowest blast radius (frozen ABI,
   near-zero Haskell change), delivers the throughput/latency substrate directly.
2. **No collector; no nursery in the generational sense.** "Low latency due to the nursery"
   resolves to the **bump-arena** reading (fast bump + eager RC reclaim + LIFO reuse), not a
   traced young generation (Ulterior RC), which would reintroduce a collector and break pure
   Perceus.
3. **Cell granularity = arity-exact size classes** (`freelist[arity]`), zero internal
   fragmentation, no bitmap (size is the header `arity`). LuaJIT's "size from block bitmap"
   trick is therefore not adopted.
4. **No pointer-masking / no slab alignment** this slice (free-list routing uses header
   `arity` + the passed `WokHeap*`). Deferred as a future enabler.
5. **`malloc` retained behind `WOK_RC_MALLOC`** for the standalone UAF oracle and the perf
   baseline — not in the Haskell path.

**Genuinely flaggable:** `WOK_ARENA_SIZE` (default 64 KiB — LuaJIT parity; tune against the
corpus's resident-bytes histogram) and `WOK_NUM_CLASSES` (default 64; raise only if a real
constructor/record exceeds arity 63). Both are one-line constants.
