# C runtime arena allocator — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers-extended-cc:subagent-driven-development (recommended) or superpowers-extended-cc:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace slice-1's plain `malloc`/`free` behind the frozen `wok_rc` ABI with a per-run slab arena (bump alloc + arity-exact free-list reuse + O(slabs) bulk teardown), with no change to the cell representation or the Haskell interpreter core.

**Architecture:** Everything lives in `runtime/wok_rc.{c,h}`. `wok_alloc` reuses a same-arity freed cell (LIFO) or bumps within a 64 KiB slab; `arity ≥ 64` falls back to direct `malloc`. `wok_free` recycles to `freelist[arity]` (or `free`s the large path). `wok_heap_free` walks the slab list. The slice-1 `malloc` allocator is retained behind `#ifdef WOK_RC_MALLOC` as a UAF/perf oracle; poison-on-free behind `#ifdef WOK_RC_POISON`. Logical stats are unchanged, so the existing abstract ⟷ C differential oracle validates the arena with no harness change.

**Tech Stack:** C17 (`-std=c17 -O3 -Werror -Wall -Wextra -Wpedantic -Wconversion …` under cabal `c-sources`); ASan/UBSan/LSan via `scripts/asan-runtime.sh`; Haskell/tasty differential oracle in `test/Spec.hs`.

**User decisions (already made):**
- "(a) for sure" — the allocator slice ships before layout-compaction.
- No collector; "low latency due to the nursery" = the **bump-arena** reading, not a traced young generation.
- Cell granularity = **arity-exact size classes**; **no block bitmap**; **no splitting/coalescing** (exact-fit whole-object reuse).
- **No pointer-masking / no slab alignment** this slice.
- The slice-1 `malloc` allocator is **retained behind `WOK_RC_MALLOC`** (UAF oracle + perf baseline), not in the Haskell path.
- Cell representation stays **16 B header + 16 B slots** (compaction is the next slice).
- `WOK_ARENA_SIZE` = 64 KiB, `WOK_NUM_CLASSES` = 64 (tunable constants).
- "Run it autonomously."

---

## File structure

| File | Responsibility | Change |
| ---- | -------------- | ------ |
| `runtime/wok_rc.h` | the frozen ABI + additive stat readers | **modify** (add 3 stat-reader decls only; no existing signature changes) |
| `runtime/wok_rc.c` | the allocator (arena default, malloc behind `WOK_RC_MALLOC`, poison behind `WOK_RC_POISON`) | **modify** (replace allocator internals; `wok_dup`/`wok_dec`/`wok_slot_*`/`wok_tag`/`wok_arity` unchanged) |
| `runtime/test/wok_rc_test.c` | standalone C contract test | **modify** (add arena assertions: reuse, slab-boundary, large path, bulk teardown) |
| `runtime/test/wok_rc_bench.c` | standalone alloc/free microbench (arena vs malloc) | **create** |
| `scripts/asan-runtime.sh` | sanitizer build/run | **modify** (build+run arena, `WOK_RC_MALLOC`, and `WOK_RC_POISON` variants) |
| `runtime/README.md` | the pinned ABI / allocator contract | **modify** (allocator section: now a slab arena) |
| `docs/superpowers/specs/2026-06-21-c-runtime-arena-allocator-design.md` | the spec | **modify** (status → IMPLEMENTED) |
| `docs/superpowers/specs/2026-06-21-c-runtime-allocator-ncon-design.md` | slice-1 spec | **modify** (mark §9 "Language-specific allocator" done) |
| `~/.claude/projects/-Users-zy-wokml/memory/c-runtime-ncon-allocator.md` + `MEMORY.md` | memory note | **modify** |

No cabal change: `c-sources: runtime/wok_rc.c` and the `cc-options` wall are unchanged.

---

### Task 1: The slab arena in `wok_rc.{c,h}`

**Goal:** Replace the allocator internals with the slab arena (malloc retained behind `WOK_RC_MALLOC`, poison behind `WOK_RC_POISON`, additive stat readers), proven by an extended standalone C test and the full Haskell differential oracle.

**Files:**
- Modify: `runtime/wok_rc.h`
- Modify: `runtime/wok_rc.c`
- Test: `runtime/test/wok_rc_test.c`

**Acceptance Criteria:**
- [ ] `runtime/wok_rc.c` compiles `-Werror`-clean under the full cabal `cc-options` wall.
- [ ] The standalone test asserts: exact-fit reuse returns the freed cell (`b == a`, arena only) and bumps `wok_stat_reused`; a different arity does **not** reuse; a multi-slab run keeps headers intact and `wok_stat_slabs >= 2`; the large path (`arity ≥ 64`) round-trips and frees; bulk teardown frees all slabs (LSan-clean).
- [ ] The whole existing Haskell suite is green (the abstract ⟷ C-arena differential oracle now exercises the arena), with `live == baseline` balance preserved.
- [ ] `wok_dup`/`wok_dec`/`wok_slot_set`/`wok_slot_get`/`wok_tag`/`wok_arity` and the four original stat readers are byte-for-byte behaviourally unchanged.

**Verify:**
- `bash scripts/asan-runtime.sh` → prints `OK` (the standalone test), ASan/UBSan-clean.
- `cabal test 2>&1 | tail -5` → all tests pass (≥ 1278), no failures.

**Steps:**

- [ ] **Step 1: Add the three additive stat-reader declarations to the header.** Edit `runtime/wok_rc.h`, immediately after the existing `wok_stat_peak` declaration (before `#endif`):

```c
/* additive observability (arena-only; the WOK_RC_MALLOC backend reports 0).
   Consumed C-side by the standalone test / microbench; no Haskell binding. */
WOK_PURE uint64_t wok_stat_reused(const WokHeap* h);
WOK_PURE uint64_t wok_stat_slabs(const WokHeap* h);
WOK_PURE int64_t  wok_stat_bytes_resident(const WokHeap* h);
```

- [ ] **Step 2: Write the failing standalone test additions.** Replace the body of `runtime/test/wok_rc_test.c` with the existing round-trip plus the arena contract assertions:

```c
#include "wok_rc.h"
#include <assert.h>
#include <stdint.h>
#include <stdlib.h>
#include <stdio.h>

int main(void) {
    /* --- existing round-trip + stats (must stay green under the arena) --- */
    {
        WokHeap* h = wok_heap_new();
        WokObj* p = wok_alloc(h, 7u, 2u);
        wok_slot_set(p, 0u, 0u /*WS_LIT_INT*/, 42u);
        wok_slot_set(p, 1u, 2u /*WS_LIT_UNIT*/, 0u);
        assert(wok_tag(p) == 7u);
        assert(wok_arity(p) == 2u);
        uint64_t t, v;
        wok_slot_get(p, 0u, &t, &v);
        assert(t == 0u && v == 42u);
        wok_dup(p);
        assert(wok_dec(p) == 1u);
        assert(wok_dec(p) == 0u);
        wok_free(h, p);
        assert(wok_stat_allocs(h) == 1u);
        assert(wok_stat_frees(h) == 1u);
        assert(wok_stat_live(h) == 0);
        assert(wok_stat_peak(h) == 1);
        wok_heap_free(h);
    }

    /* --- arena: exact-fit reuse returns the freed cell; other arity does not --- */
    {
        WokHeap* h = wok_heap_new();
        WokObj* a = wok_alloc(h, 1u, 2u);
        assert(wok_dec(a) == 0u);
        wok_free(h, a);                 /* recycles to freelist[2] */
        WokObj* b = wok_alloc(h, 1u, 2u);
        WokObj* c = wok_alloc(h, 1u, 3u);
#ifndef WOK_RC_MALLOC
        assert(b == a);                 /* arena LIFO reuse: same cell back */
        assert(c != a);
        assert(wok_stat_reused(h) == 1u);
#else
        (void)b; (void)c;               /* malloc backend makes no reuse promise */
#endif
        assert(wok_dec(b) == 0u); wok_free(h, b);
        assert(wok_dec(c) == 0u); wok_free(h, c);
        wok_heap_free(h);
    }

    /* --- large path: arity >= 64 round-trips and frees --- */
    {
        WokHeap* h = wok_heap_new();
        WokObj* big = wok_alloc(h, 5u, 100u);
        assert(wok_arity(big) == 100u);
        wok_slot_set(big, 99u, 0u, 7u);
        uint64_t t, v; wok_slot_get(big, 99u, &t, &v);
        assert(v == 7u);
        assert(wok_dec(big) == 0u);
        wok_free(h, big);
        assert(wok_stat_live(h) == 0);
        wok_heap_free(h);
    }

    /* --- multi-slab bump: headers intact across a slab boundary; bulk teardown --- */
    {
        WokHeap* h = wok_heap_new();
        enum { N = 5000 };              /* 5000 * 16 B > 64 KiB -> spills a 2nd slab */
        WokObj** ptrs = (WokObj**)malloc((size_t)N * sizeof(WokObj*));
        assert(ptrs != NULL);
        for (int i = 0; i < N; i++) {
            ptrs[i] = wok_alloc(h, (uint32_t)i, 0u);
            assert(wok_tag(ptrs[i]) == (uint32_t)i);
        }
#ifndef WOK_RC_MALLOC
        assert(wok_stat_slabs(h) >= 2u);
#endif
        assert(wok_stat_live(h) == (int64_t)N);
        for (int i = 0; i < N; i++) {
            assert(wok_dec(ptrs[i]) == 0u);
            wok_free(h, ptrs[i]);
        }
        assert(wok_stat_live(h) == 0);
        free(ptrs);
        wok_heap_free(h);               /* arena: frees all slabs (LSan-clean) */
    }

    printf("OK\n");
    return 0;
}
```

- [ ] **Step 3: Run the test to confirm it fails before the arena exists.**

Run: `cc -std=c17 -O1 -g -Wall -Wextra -Wpedantic -Iruntime runtime/wok_rc.c runtime/test/wok_rc_test.c -o /tmp/wok_rc_test && /tmp/wok_rc_test`
Expected: compile error — `wok_stat_reused`/`wok_stat_slabs` are declared (Step 1) but **not defined** in the current `wok_rc.c` → link failure. (This is the red state; Step 4 defines them.)

- [ ] **Step 4: Implement the arena (full `wok_rc.c`).** Replace the entire contents of `runtime/wok_rc.c` with:

```c
#include "wok_rc.h"
#include <assert.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>   /* memcpy, memset */

_Static_assert(sizeof(WokSlot) == 16, "WokSlot must be 16 bytes");
_Static_assert(sizeof(WokObj)  == 16, "WokObj header must be 16 bytes");

/* --- tunables (spec section 11) --------------------------------------------- */
#define WOK_GRANULE     16u
#define WOK_ARENA_SIZE  (64u * 1024u)   /* slab bytes */
#define WOK_NUM_CLASSES 64u             /* arity 0..63 -> slabs; >=64 -> malloc */

_Static_assert(WOK_ARENA_SIZE % WOK_GRANULE == 0u,
               "arena size must be a granule multiple");
_Static_assert((sizeof(WokObj) + (WOK_NUM_CLASSES - 1u) * sizeof(WokSlot)) < WOK_ARENA_SIZE,
               "largest slab-class cell must fit a slab");

static size_t wok_cell_bytes(uint32_t arity) {
    return sizeof(WokObj) + (size_t)arity * sizeof(WokSlot);
}

#ifdef WOK_RC_MALLOC
/* ---- retained slice-1 allocator: one malloc per cell (UAF oracle + bench baseline) ---- */
struct WokHeap { uint64_t allocs; uint64_t frees; int64_t live; int64_t peak; };

WokHeap* wok_heap_new(void) {
    WokHeap* h = (WokHeap*)calloc(1, sizeof(WokHeap));
    if (WOK_UNLIKELY(h == NULL)) { abort(); }
    return h;
}
void wok_heap_free(WokHeap* h) {
    if (WOK_UNLIKELY(h->live != 0)) {
        fprintf(stderr, "wok_rc: heap freed with %lld live cells (leak)\n", (long long)h->live);
    }
    free(h);
}
WokObj* wok_alloc(WokHeap* h, uint32_t tag, uint32_t arity) {
    WokObj* p = (WokObj*)malloc(wok_cell_bytes(arity));
    if (WOK_UNLIKELY(p == NULL)) { abort(); }
    p->rc = 1u; p->tag = tag; p->arity = arity;
    h->allocs += 1u; h->live += 1;
    if (h->live > h->peak) { h->peak = h->live; }
    return p;
}
void wok_free(WokHeap* h, WokObj* p) {
    if (WOK_UNLIKELY(p->rc != 0u)) { fprintf(stderr, "wok_rc: wok_free on rc!=0 (premature free)\n"); abort(); }
    h->frees += 1u; h->live -= 1;
    free(p);
}
uint64_t wok_stat_reused(const WokHeap* h)         { (void)h; return 0u; }
uint64_t wok_stat_slabs(const WokHeap* h)          { (void)h; return 0u; }
int64_t  wok_stat_bytes_resident(const WokHeap* h) { (void)h; return 0; }

#else
/* ---- the slab arena (default) ------------------------------------------------------- */
typedef struct WokSlab { struct WokSlab* next; } WokSlab;

struct WokHeap {
    uint64_t allocs;
    uint64_t frees;
    int64_t  live;
    int64_t  peak;
    uint64_t reused;                 /* free-list pops */
    uint64_t nslabs;                 /* slabs malloc'd */
    WokSlab* slabs;                  /* linked list, for O(slabs) bulk teardown */
    char*    bump_ptr;
    char*    bump_end;
    WokObj*  freelist[WOK_NUM_CLASSES];
};

/* strict-aliasing-safe free-list link: store/load the next ptr in the dead cell's bytes. */
static WokObj* fl_next(WokObj* p)                { WokObj* n; memcpy(&n, p, sizeof n); return n; }
static void    fl_set_next(WokObj* p, WokObj* n) { memcpy(p, &n, sizeof n); }

static void wok_new_slab(WokHeap* h) {
    WokSlab* s = (WokSlab*)malloc(WOK_ARENA_SIZE);
    if (WOK_UNLIKELY(s == NULL)) { abort(); }
    s->next = h->slabs;
    h->slabs = s;
    h->nslabs += 1u;
    /* cells start one granule in (sizeof(WokSlab) <= 16), preserving 16-alignment. */
    h->bump_ptr = (char*)s + WOK_GRANULE;
    h->bump_end = (char*)s + WOK_ARENA_SIZE;
}

WokHeap* wok_heap_new(void) {
    WokHeap* h = (WokHeap*)calloc(1, sizeof(WokHeap));   /* zeros stats, freelist, slabs, bump */
    if (WOK_UNLIKELY(h == NULL)) { abort(); }
    return h;
}

void wok_heap_free(WokHeap* h) {
    if (WOK_UNLIKELY(h->live != 0)) {
        fprintf(stderr, "wok_rc: heap freed with %lld live cells (leak)\n", (long long)h->live);
    }
    WokSlab* s = h->slabs;
    while (s != NULL) { WokSlab* n = s->next; free(s); s = n; }
    free(h);
}

WokObj* wok_alloc(WokHeap* h, uint32_t tag, uint32_t arity) {
    size_t  sz = wok_cell_bytes(arity);
    WokObj* p;
    if (arity < WOK_NUM_CLASSES) {
        WokObj* head = h->freelist[arity];
        if (head != NULL) {                       /* reuse (LIFO, cache-warm) */
            h->freelist[arity] = fl_next(head);
            p = head;
            h->reused += 1u;
        } else {                                  /* bump */
            if (h->bump_ptr == NULL || sz > (size_t)(h->bump_end - h->bump_ptr)) {
                wok_new_slab(h);
            }
            p = (WokObj*)h->bump_ptr;
            h->bump_ptr += sz;
        }
    } else {                                      /* large: direct malloc */
        p = (WokObj*)malloc(sz);
        if (WOK_UNLIKELY(p == NULL)) { abort(); }
    }
    p->rc = 1u; p->tag = tag; p->arity = arity;
    h->allocs += 1u; h->live += 1;
    if (h->live > h->peak) { h->peak = h->live; }
    return p;
}

void wok_free(WokHeap* h, WokObj* p) {
    if (WOK_UNLIKELY(p->rc != 0u)) { fprintf(stderr, "wok_rc: wok_free on rc!=0 (premature free)\n"); abort(); }
    uint32_t arity = p->arity;
    h->frees += 1u; h->live -= 1;
#ifdef WOK_RC_POISON
    memset(p, 0xDE, wok_cell_bytes(arity));       /* poison BEFORE relink so the link survives */
#endif
    if (arity < WOK_NUM_CLASSES) {
        fl_set_next(p, h->freelist[arity]);
        h->freelist[arity] = p;
    } else {
        free(p);
    }
}

uint64_t wok_stat_reused(const WokHeap* h)         { return h->reused; }
uint64_t wok_stat_slabs(const WokHeap* h)          { return h->nslabs; }
int64_t  wok_stat_bytes_resident(const WokHeap* h) {
    return (int64_t)((uint64_t)h->nslabs * (uint64_t)WOK_ARENA_SIZE);
}

#endif /* WOK_RC_MALLOC */

/* ---- shared across both backends (unchanged from slice 1) --------------------------- */
void wok_dup(WokObj* p) { p->rc += 1u; }

uint64_t wok_dec(WokObj* p) {
    if (WOK_UNLIKELY(p->rc == 0u)) {
        fprintf(stderr, "wok_rc: wok_dec on rc==0 (double-free)\n");
        abort();
    }
    p->rc -= 1u;
    return p->rc;
}

void wok_slot_set(WokObj* p, uint32_t i, uint64_t tag, uint64_t payload) {
    assert(i < p->arity);
    p->slots[i].tag = tag;
    p->slots[i].payload = payload;
}

void wok_slot_get(const WokObj* p, uint32_t i, uint64_t* restrict tag, uint64_t* restrict payload) {
    assert(i < p->arity);
    *tag = p->slots[i].tag;
    *payload = p->slots[i].payload;
}

uint32_t wok_tag(const WokObj* p)   { return p->tag; }
uint32_t wok_arity(const WokObj* p) { return p->arity; }

uint64_t wok_stat_allocs(const WokHeap* h) { return h->allocs; }
uint64_t wok_stat_frees(const WokHeap* h)  { return h->frees; }
int64_t  wok_stat_live(const WokHeap* h)   { return h->live; }
int64_t  wok_stat_peak(const WokHeap* h)   { return h->peak; }
```

- [ ] **Step 5: Run the standalone test (green).**

Run: `bash scripts/asan-runtime.sh`
Expected: `OK` printed, exit 0 (ASan/UBSan clean — the script currently builds the arena/default variant).

- [ ] **Step 6: Run the full Haskell suite (the differential oracle now exercises the arena).**

Run: `cabal test 2>&1 | tail -8`
Expected: all groups pass (≥ 1278), including `rc-c-backend-parity` and `wok-rc-heap`; no failures, no balance/`live` mismatch.

- [ ] **Step 7: Commit.**

```bash
git add runtime/wok_rc.h runtime/wok_rc.c runtime/test/wok_rc_test.c
git commit -m "feat(rc): slab arena allocator behind the wok_rc ABI

Bump alloc + arity-exact LIFO free-list reuse + O(slabs) bulk teardown;
arity>=64 falls back to direct malloc. Slice-1 malloc retained behind
WOK_RC_MALLOC; poison-on-free behind WOK_RC_POISON. Additive reuse/slabs/
resident stats (C-side only). Logical stats unchanged -> abstract<->C-arena
differential oracle stays green.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: Sanitizer matrix + UAF oracle + microbench

**Goal:** Run the standalone test under ASan/UBSan(+LSan) across the arena, `WOK_RC_MALLOC` (real per-cell free → every UAF/leak visible), and `WOK_RC_POISON` variants; add an alloc/free microbench comparing arena vs malloc.

**Files:**
- Create: `runtime/test/wok_rc_bench.c`
- Modify: `scripts/asan-runtime.sh`

**Acceptance Criteria:**
- [ ] `scripts/asan-runtime.sh` builds and runs the test under three variants (arena, `WOK_RC_MALLOC`, `WOK_RC_POISON`); each prints `OK` and is sanitizer-clean; the script exits 0.
- [ ] LeakSanitizer is requested only where supported (the existing Darwin guard is preserved).
- [ ] The microbench builds both arena and `WOK_RC_MALLOC` variants and prints ns/op for each; it is a reported signal, not a gate.

**Verify:**
- `bash scripts/asan-runtime.sh` → three `OK` lines, exit 0.
- `bash scripts/asan-runtime.sh bench` (or the documented bench command) → prints two ns/op numbers (arena vs malloc).

**Steps:**

- [ ] **Step 1: Create the microbench.** Write `runtime/test/wok_rc_bench.c`:

```c
#include "wok_rc.h"
#include <stdint.h>
#include <stdio.h>
#include <time.h>

/* Allocate then free a churn of small cells, exercising the reuse fast path.
   Build once as the arena (default) and once with -DWOK_RC_MALLOC to compare. */
int main(void) {
    enum { ROUNDS = 2000000 };
    WokHeap* h = wok_heap_new();
    clock_t t0 = clock();
    for (long i = 0; i < ROUNDS; i++) {
        WokObj* p = wok_alloc(h, 1u, 2u);   /* arity 2: the common Cons shape */
        p->rc = 0u;                          /* simulate drop-to-zero */
        wok_free(h, p);
    }
    clock_t t1 = clock();
    double ns = (double)(t1 - t0) / (double)CLOCKS_PER_SEC * 1e9 / (double)ROUNDS;
#ifdef WOK_RC_MALLOC
    const char* which = "malloc";
#else
    const char* which = "arena ";
#endif
    printf("%s  %.2f ns/alloc+free  (reused=%llu, slabs=%llu)\n",
           which, ns,
           (unsigned long long)wok_stat_reused(h),
           (unsigned long long)wok_stat_slabs(h));
    wok_heap_free(h);
    return 0;
}
```

- [ ] **Step 2: Extend the sanitizer script to the variant matrix.** Replace `scripts/asan-runtime.sh` with:

```bash
#!/usr/bin/env bash
set -euo pipefail

CC="${CC:-cc}"
SAN="-fsanitize=address,undefined -fno-omit-frame-pointer"
WARN="-Wall -Wextra -Wpedantic"
BASE="-std=c17 -O1 -g $WARN -Iruntime"

run() { # $1 = label, $2.. = extra defines
  local label="$1"; shift
  $CC $BASE $SAN "$@" runtime/wok_rc.c runtime/test/wok_rc_test.c -o /tmp/wok_rc_test
  echo "== $label =="
  if [ "$(uname -s)" = "Darwin" ]; then
    /tmp/wok_rc_test                          # LSan unsupported on Apple's ASan runtime
  else
    ASAN_OPTIONS=detect_leaks=1 /tmp/wok_rc_test
  fi
}

if [ "${1:-}" = "bench" ]; then
  $CC -std=c17 -O3 $WARN -Iruntime runtime/wok_rc.c runtime/test/wok_rc_bench.c -o /tmp/wok_rc_bench_arena
  $CC -std=c17 -O3 $WARN -DWOK_RC_MALLOC -Iruntime runtime/wok_rc.c runtime/test/wok_rc_bench.c -o /tmp/wok_rc_bench_malloc
  /tmp/wok_rc_bench_arena
  /tmp/wok_rc_bench_malloc
  exit 0
fi

run "arena (default)"
run "malloc backend (UAF oracle)" -DWOK_RC_MALLOC
run "poison-on-free"              -DWOK_RC_POISON
```

- [ ] **Step 3: Run the sanitizer matrix (green).**

Run: `bash scripts/asan-runtime.sh`
Expected: three sections each printing `OK`, exit 0, no ASan/UBSan/LSan report.

- [ ] **Step 4: Run the microbench (reported).**

Run: `bash scripts/asan-runtime.sh bench`
Expected: two lines, e.g. `arena   ~5 ns/alloc+free (reused=1999999, slabs=1)` and `malloc  ~25 ns/...`; arena reuse count near `ROUNDS`.

- [ ] **Step 5: Commit.**

```bash
git add runtime/test/wok_rc_bench.c scripts/asan-runtime.sh
git commit -m "test(rc): sanitizer matrix (arena/malloc/poison) + alloc microbench

asan-runtime.sh now exercises the arena, the WOK_RC_MALLOC UAF oracle (real
per-cell free -> ASan/LSan see every use-after-free/leak), and WOK_RC_POISON.
A standalone bench compares arena vs malloc alloc+free ns/op.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 3: Docs + memory

**Goal:** Record the arena as the live allocator (ABI unchanged), mark the deferred slice done, and update the memory note.

**Files:**
- Modify: `runtime/README.md`
- Modify: `docs/superpowers/specs/2026-06-21-c-runtime-arena-allocator-design.md`
- Modify: `docs/superpowers/specs/2026-06-21-c-runtime-allocator-ncon-design.md`
- Modify: `~/.claude/projects/-Users-zy-wokml/memory/c-runtime-ncon-allocator.md` and `~/.claude/projects/-Users-zy-wokml/memory/MEMORY.md`

**Acceptance Criteria:**
- [ ] `runtime/README.md`'s "The allocator is plain `malloc`/`free` for now" bullet is rewritten to describe the slab arena (bump + arity-exact free lists + bulk teardown), states the ABI is unchanged, and notes `malloc` is retained behind `WOK_RC_MALLOC` for the oracle/baseline.
- [ ] The arena spec's status line becomes `IMPLEMENTED` with the merge/branch note.
- [ ] The slice-1 spec §9 "Language-specific allocator" bullet is marked implemented (one-line pointer to the arena spec).
- [ ] The `c-runtime-ncon-allocator` memory note records the arena slice; `MEMORY.md` has a one-line pointer.

**Verify:**
- `grep -n "slab arena" runtime/README.md` → matches; `grep -n "IMPLEMENTED" docs/superpowers/specs/2026-06-21-c-runtime-arena-allocator-design.md` → matches.

**Steps:**

- [ ] **Step 1: Rewrite the `runtime/README.md` allocator bullet.** Replace the "The allocator is plain `malloc` / `free` for now" bullet under "The byte-dumb contract" with:

```markdown
- **The allocator is a per-run slab arena.** `wok_alloc` reuses a same-arity freed
  cell from a LIFO free list (the FBIP fast path) or bump-allocates within a 64 KiB
  slab; constructors of `arity >= 64` fall back to a direct `malloc`. `wok_free`
  recycles the cell to `freelist[arity]` (or `free`s the large path). `wok_heap_free`
  walks the slab list (O(slabs) bulk teardown). The cell representation and the entire
  function ABI above are unchanged — only the bytes' provenance changed. The slice-1
  one-`malloc`-per-cell allocator is retained behind `-DWOK_RC_MALLOC` purely as a
  use-after-free oracle and microbench baseline (not in the Haskell path); poison-on-
  free is `-DWOK_RC_POISON`. **Swapping the allocator does not change the ABI.**
```

- [ ] **Step 2: Flip the arena spec status.** In `docs/superpowers/specs/2026-06-21-c-runtime-arena-allocator-design.md`, change the `**Status:**` line to:

```markdown
- **Status:** IMPLEMENTED (branch feat/c-runtime-arena-allocator)
```

- [ ] **Step 3: Mark the slice-1 deferred item done.** In `docs/superpowers/specs/2026-06-21-c-runtime-allocator-ncon-design.md` §9, prefix the "Language-specific allocator" bullet with `**[IMPLEMENTED — see 2026-06-21-c-runtime-arena-allocator-design.md]**` (keep the existing text).

- [ ] **Step 4: Update the memory note.** Append a paragraph to `~/.claude/projects/-Users-zy-wokml/memory/c-runtime-ncon-allocator.md` recording: the arena slice (slab + arity-exact free lists + bulk teardown, no collector, no bitmap, no split/coalesce), validated by the unchanged differential oracle + the ASan variant matrix; ABI frozen; `malloc` retained behind `WOK_RC_MALLOC`. Add/refresh the `MEMORY.md` one-liner. Convert any relative dates to absolute (2026-06-21).

- [ ] **Step 5: Final full-suite sanity + commit.**

Run: `cabal test 2>&1 | tail -3 && bash scripts/asan-runtime.sh >/dev/null && echo SANITIZERS_OK`
Expected: suite green, `SANITIZERS_OK`.

```bash
git add runtime/README.md docs/superpowers/specs/2026-06-21-c-runtime-arena-allocator-design.md docs/superpowers/specs/2026-06-21-c-runtime-allocator-ncon-design.md
git commit -m "docs(rc): record the slab arena as the live allocator (ABI unchanged)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Self-review

**Spec coverage:**
- Arena (bump + arity free lists + slabs + large path + teardown) → Task 1. ✓
- Strict-aliasing free-list link, NULL-safe capacity check, `_Static_assert`s → Task 1 Step 4. ✓
- `WOK_RC_MALLOC` retention, poison-on-free, additive stats → Task 1. ✓
- Abstract ⟷ C-arena differential (primary oracle) → Task 1 Step 6 (existing harness, now arena). ✓
- ASan/UBSan + UAF oracle + poison + microbench → Task 2. ✓
- Targeted assertions (exact-fit, slab-boundary, large path, bulk teardown) → Task 1 Step 2 (C standalone). ✓
- Stats-invariance → Task 1 Step 6 (the differential asserts arena vs abstract). ✓
- Docs/memory + mark deferred-item done → Task 3. ✓
- Deferred (pointer-masking, bitmap, compaction, mimalloc, splitting, cycle collector) → not implemented, by design. ✓

**Placeholder scan:** every code step shows complete code; no TBD/TODO. ✓

**Type/identity consistency:** `WokHeap`/`WokObj`/`WokSlot` match `wok_rc.h`; `wok_stat_reused`/`wok_stat_slabs`/`wok_stat_bytes_resident` are declared (Task 1 Step 1) and defined in both backends (Step 4); `WOK_NUM_CLASSES`/`WOK_ARENA_SIZE`/`WOK_GRANULE` used consistently; `fl_next`/`fl_set_next`/`wok_new_slab`/`wok_cell_bytes` all defined before use. ✓

**Warning-wall note:** the cabal build is `-Werror -Wconversion -Wstrict-prototypes -Wpedantic`; the Task 1 code uses explicit casts (`(size_t)`, `(uint32_t)`, `(int64_t)`, `(uint64_t)`) and `memcpy`-based aliasing to stay clean. The implementer MUST confirm `cabal test` compiles `-Werror`-clean (Task 1 Step 6 fails loudly otherwise).
