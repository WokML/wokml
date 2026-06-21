# Allocator research: mimalloc + Koka `kklib` (for the wok C runtime)

- **Date:** 2026-06-21
- **Why:** validate the §4 `WokObj`/ABI design of
  `specs/2026-06-21-c-runtime-allocator-ncon-design.md` against the *production* RC runtime
  it most resembles. mimalloc and Perceus share an author (Daan Leijen); Koka's `kklib` is
  the reference Perceus runtime and uses mimalloc — so this is the proven version of what wok
  is building.
- **Sources:** shallow clones studied read-only — mimalloc v2.3.2 (MIT, C11) and koka `kklib`.
  Findings below cite `file:line` from those clones.

## Koka `kklib` — the proven RC object model

- **Header is a single 64-bit word** (`kklib.h:136-141`):
  `uint8 scan_fsize; uint8 _field_idx; uint16 tag; int32 refcount`. **8 bytes total.**
- **Refcount is 32-bit** (`kklib.h:106`) with sign/saturation folding three roles into one
  field (`refcount.c:97-175`): `0` = unique, `1..INT32_MAX` = thread-local count, negatives =
  thread-shared (atomic) or **sticky**, `INT32_MIN` = **immortal/static**. Static objects are
  *not* a separate flag — they are a stuck negative refcount (`KK_HEADER_STATIC`, `kklib.h:147`).
- **Fields are one 8-byte tagged word each** (pointer tagging, not a tag+payload pair):
  low bit `0` = heap pointer, `1` = inline value (`kklib.h:987-998`); small ints are `4n+1`
  (`integer.h:12-39`); bigints are boxed pointers. Blocks are pointer-aligned so the low bits
  are free.
- **The free cascade runs in C, driven by the header `scan_fsize`** + the per-field low-bit
  tag (`kklib.h:834-886`, `box.h:169-171`). Convention: **pointer-bearing fields come first**,
  so one count bounds the scan. The production path is *stackless* — it threads the parent
  through field 0 and stores the field cursor in the header's `_field_idx` byte
  (`refcount.c:366-450`), with fast specializations for `scan_fsize == 1` and `== 2`. There is
  **no per-constructor descriptor table** — the header scan-count is the entire mechanism.
- **In-place reuse (FBIP)** = `drop_reuse` + `alloc_at` (`refcount.c:213-231`, `kklib.h:654-667`):
  on `rc==0` & unique, drop the children but **return the block** instead of freeing it; a
  later constructor reuses that exact pointer and re-stamps the header (any tag/scan-count that
  physically fits). The reuse token is just a block pointer (`kklib.h:650`). **Size-class fit
  is the compiler's responsibility, trusted by the runtime** (`// TODO: check usable size`,
  `kklib.h:662`).

## mimalloc — the allocator under it

- **First-class heaps give O(pages) bulk teardown.** `mi_heap_destroy` frees every block of a
  heap without per-object `mi_free` and without walking the object graph (`src/heap.c:362-388`).
  `mi_heap_new()` sets `no_reclaim`, making `new`/`destroy` the supported pairing
  (`src/heap.c:258-261`). `mi_heap_visit_blocks` (`src/heap.c:738`) enumerates live blocks =
  a per-run leak audit. (`mi_heap_delete` instead *absorbs* live pages into the backing heap.)
- **THE CONSTRAINT (v2):** a heap may only **allocate** from the thread that created it
  (`include/mimalloc.h:206-207`; `thread_id` bind at `src/heap.c:222`; debug-only asserts at
  `src/alloc.c:134,186`). Cross-thread *frees* are safe (atomic delayed-free, `src/free.c:281`)
  — only allocs must stay on-thread. Under GHC's RTS (green threads migrate across OS threads)
  this races **silently in release builds**. Mitigation: confine each run's allocs to one OS
  thread (`runInBoundThread`). **mimalloc v3 removes this restriction** (`readme.md:84`).
- **Metadata is out-of-band**; the returned pointer is the block start (`internal.h:528`), so a
  `WokObj` header sits at offset 0 with **zero release-build overhead** (`types.h:547`). Default
  alignment 16 B; objects ≤64 KiB aligned to their own size (`types.h:37-38,217`).
- **73 size-class bins, ~12.5% spacing** (`src/page-queue.c:60-92`), per-page sharded free
  lists (`free`/`local_free`/atomic `xthread_free`, `types.h:292-356`), O(1) small-class
  alloc/free fast paths (`src/alloc.c:31-44`, `src/free.c:31-54`). No dedicated FBIP hook —
  reuse is implicit LIFO same-size-class; Perceus reuse is a *compiler/runtime* concern that
  rides on top.
- **Integration:** `src/static.c` amalgamation drops into `c-sources` (one TU, no CMake); MIT;
  C11; init is automatic/lazy (no `mi_process_init` call needed).

## What this means for wok (decisions)

1. **Slice-1 allocator: plain `malloc`/`free`.** mimalloc's v2 single-thread-alloc rule is a
   silent-release-race footgun under GHC, slice 1 is correctness-not-speed, and we already get
   per-run leak detection from `stStats` (live-count == 0 at end). mimalloc is deferred to the
   perf pass (bound-thread or v3), and swaps in behind `wok_alloc` with no ABI change.
2. **Provision a `scan_count` in the header now (zero extra bytes).** Re-slice the existing
   header to `uint32 tag; uint16 arity; uint16 scan_count` and adopt Koka's **pointer-fields-
   first** convention. This is the *entire* enabler of the deferred descriptor-driven C cascade
   (Koka proves a header scan-count needs no per-constructor table). Latent in slice 1 (our
   self-describing tagged slots already let the Haskell cascade work), but free to add and it
   keeps the durable ABI aligned with the proven design. Especially pays off once unboxed
   arrays / raw fields arrive (no per-element tag).
3. **Slot width validated.** Our 16-byte `{tag,payload}` slot is 2x Koka's 8-byte tagged word
   — a pure performance tax, fully behind the ABI. Correctness-first now; compact to a single
   tagged word in the deferred slot-compaction pass. (This is also the real answer to "uniform
   size for cache": the cache win lives in slot compaction + size classes, both deferred.)
4. **Static/immortal C objects (future): use a saturating refcount sentinel** (Koka:
   `INT32_MIN`), not a separate flag. Not needed in slice 1 (C-heap statics don't exist yet).
5. **FBIP milestone scope (deferred):** header scan-count + `drop_reuse`(returns block) +
   `alloc_at`(token) + compiler-guaranteed size-class fit + a size-class allocator (mimalloc).
   The only piece worth provisioning early is the scan-count (item 2).

Our roadmap is *confirmed correct*: "Haskell drives the cascade now, C drives it via a header
scan-count later" is exactly Koka's production design path.
