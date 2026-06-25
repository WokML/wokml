/* wok_arena_test.c -- standalone tests for the per-activation arena ABI (R1)
 *
 * TDD: write these tests first (red), then implement to make them green.
 *
 * Coverage:
 *   T1 - basic open/alloc/close round-trip: pointer-identity reuse after close (Case A)
 *   T2 - LIFO nesting: open A, open B, close B, close A
 *   T3 - arena stats isolated from counted stats
 *   T4 - arena_bytes back to baseline after close (arena-leak invariant)
 *   T5 - counted allocs coexist with arena scope (before/after); stats independent
 *   T6 - arena alloc across slab boundary (multi-slab); Case B free-list reuse (no malloc churn)
 *   T7 - interleaved arena+counted allocs: arena close must NOT clobber counted cells (UAF regression)
 *   T8 - leaked (never-closed) arena scope is drained at heap free (LSan-clean)
 *   T9 - mismatch-handle abort (death test, must run under a sub-process guard)
 *   T10 - bounded arena-slab lifecycle: many grow/close cycles keep total slabs ~peak, not O(cycles)
 *   T11 - PHYSICAL-invariant negative control (death test): orphaning slabs trips the self-policing
 *         abort (only with WOK_RC_CHECK_PHYSICAL + WOK_RC_PHYSICAL_TEST_HOOK compiled in)
 *   T12 - PHYSICAL-invariant positive control: a grow-heavy-then-free workload (T10-shaped) keeps
 *         peak_physical bounded and never trips the abort
 *
 * T9 and T11 are disabled in the normal test run (they call abort); run them with the env
 * variable WOK_TEST_DEATH=1 to exercise the abort paths explicitly.
 */

#include "wok_rc.h"
#include <assert.h>
#include <stdint.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>

/* ---- T1: basic round-trip + pointer-identity reuse after close --------------------- */
static void test_arena_basic_roundtrip(void) {
    WokHeap* h = wok_heap_new();

    /* Baseline: counted stats are all zero before any alloc. */
    assert(wok_stat_allocs(h) == 0u);
    assert(wok_stat_arena_bytes(h) == 0u);
    assert(wok_stat_arena_peak(h)  == 0u);

    uint32_t depth = wok_arena_open(h);
    assert(depth == 0u);   /* first open -> depth handle 0 */

    /* Allocate three cells in the arena. */
    WokObj* a = wok_arena_alloc(h, 1u, 0u);   /*  8 bytes */
    WokObj* b = wok_arena_alloc(h, 2u, 2u);   /* 24 bytes */
    WokObj* c = wok_arena_alloc(h, 3u, 1u);   /* 16 bytes */

    assert(wok_tag(a) == 1u);
    assert(wok_tag(b) == 2u);
    assert(wok_tag(c) == 3u);
    assert(wok_arity(a) == 0u);
    assert(wok_arity(b) == 2u);
    assert(wok_arity(c) == 1u);

    /* arena_bytes must reflect the three cells (8+24+16 = 48). */
    assert(wok_stat_arena_bytes(h) == 48u);
    assert(wok_stat_arena_peak(h)  == 48u);

    /* counted stats are untouched. */
    assert(wok_stat_allocs(h) == 0u);
    assert(wok_stat_frees(h)  == 0u);
    assert(wok_stat_live(h)   == 0);
    assert(wok_stat_peak(h)   == 0);

    wok_arena_close(h, depth);

    /* After close: arena_bytes back to 0; peak stays. */
    assert(wok_stat_arena_bytes(h) == 0u);
    assert(wok_stat_arena_peak(h)  == 48u);   /* high-water preserved */

    /* The counted stats are still untouched. */
    assert(wok_stat_allocs(h) == 0u);
    assert(wok_stat_frees(h)  == 0u);
    assert(wok_stat_live(h)   == 0);

    /* Pointer-identity reuse: the next arena open+alloc must reuse the same bump region.
       We only verify the first cell: after close, a fresh open restores the frontier, so
       the first allocation in the new scope must land at the same address as `a` did. */
    uint32_t d2 = wok_arena_open(h);
#ifndef WOK_RC_MALLOC
    WokObj* a2 = wok_arena_alloc(h, 9u, 0u);
    assert(a2 == a);   /* bump frontier was reset: same address */
    (void)b; (void)c;
#else
    (void)a; (void)b; (void)c;
    wok_arena_alloc(h, 9u, 0u);   /* just exercise the path */
#endif
    wok_arena_close(h, d2);

    assert(wok_stat_arena_bytes(h) == 0u);
    wok_heap_free(h);
    printf("T1 PASS: basic round-trip + pointer-identity reuse after close\n");
}

/* ---- T2: LIFO nesting ------------------------------------------------------------- */
static void test_arena_lifo_nesting(void) {
    WokHeap* h = wok_heap_new();

    uint32_t dA = wok_arena_open(h);   /* depth 0 */
    assert(dA == 0u);

    WokObj* x = wok_arena_alloc(h, 10u, 1u);   /* 16 bytes in A */
    assert(wok_stat_arena_bytes(h) == 16u);

    uint32_t dB = wok_arena_open(h);   /* depth 1 */
    assert(dB == 1u);

    WokObj* y = wok_arena_alloc(h, 20u, 2u);   /* 24 bytes in B */
    assert(wok_stat_arena_bytes(h) == 40u);     /* 16 + 24 */
    assert(wok_stat_arena_peak(h)  == 40u);

    /* Close B: arena_bytes drops back by 24 (B's cells). */
    wok_arena_close(h, dB);
    assert(wok_stat_arena_bytes(h) == 16u);   /* A's cells remain */

    /* A's cell `x` still readable (its bump region is within A's scope). */
    assert(wok_tag(x) == 10u);

    /* Re-open a new inner arena (C at depth 1) and allocate. */
    uint32_t dC = wok_arena_open(h);
    assert(dC == 1u);   /* same depth as B was */
    WokObj* z = wok_arena_alloc(h, 30u, 0u);   /* 8 bytes */
    assert(wok_stat_arena_bytes(h) == 24u);    /* 16 (A) + 8 (C) */
    assert(wok_tag(z) == 30u);
    wok_arena_close(h, dC);
    assert(wok_stat_arena_bytes(h) == 16u);

    /* Close A: arena_bytes back to 0. */
    wok_arena_close(h, dA);
    assert(wok_stat_arena_bytes(h) == 0u);

    /* Counted stats untouched throughout. */
    assert(wok_stat_allocs(h) == 0u);
    assert(wok_stat_live(h)   == 0);

    (void)y;

    wok_heap_free(h);
    printf("T2 PASS: LIFO nesting\n");
}

/* ---- T3: arena stats isolated from counted stats ---------------------------------- */
static void test_arena_stats_isolated(void) {
    WokHeap* h = wok_heap_new();

    /* A counted alloc sets the counted baseline. */
    WokObj* counted = wok_alloc(h, 5u, 1u);   /* 16 bytes */
    assert(wok_stat_allocs(h) == 1u);
    assert(wok_stat_live(h)   == 1);

    /* Open arena and alloc: counted stats must not move. */
    uint32_t d = wok_arena_open(h);
    wok_arena_alloc(h, 6u, 2u);   /* 24 bytes */
    assert(wok_stat_allocs(h) == 1u);   /* unchanged */
    assert(wok_stat_frees(h)  == 0u);
    assert(wok_stat_live(h)   == 1);
    assert(wok_stat_peak(h)   == 1);
    assert(wok_stat_arena_bytes(h) == 24u);

    wok_arena_close(h, d);
    assert(wok_stat_arena_bytes(h) == 0u);

    /* Counted cell unchanged. */
    assert(wok_stat_allocs(h) == 1u);
    assert(wok_stat_live(h)   == 1);

    assert(wok_dec(counted) == 0u);
    wok_free(h, counted);
    assert(wok_stat_live(h) == 0);

    wok_heap_free(h);
    printf("T3 PASS: arena stats isolated from counted stats\n");
}

/* ---- T4: arena_bytes back to baseline after each close (arena-leak invariant) ----- */
static void test_arena_bytes_baseline(void) {
    WokHeap* h = wok_heap_new();

    /* Multiple open/close cycles: arena_bytes returns to 0 each time. */
    for (int i = 0; i < 5; i++) {
        assert(wok_stat_arena_bytes(h) == 0u);
        uint32_t d = wok_arena_open(h);
        wok_arena_alloc(h, (uint32_t)i, 0u);
        wok_arena_alloc(h, (uint32_t)i, 1u);
        assert(wok_stat_arena_bytes(h) == 24u);   /* 8 + 16 */
        wok_arena_close(h, d);
        assert(wok_stat_arena_bytes(h) == 0u);    /* invariant: back to 0 */
    }

    wok_heap_free(h);
    printf("T4 PASS: arena_bytes baseline invariant\n");
}

/* ---- T5: counted allocs before and after arena scope; stats stay independent ------- */
/* NOTE: Counted allocs and arena allocs draw from SEPARATE bump regions, so they coexist
   freely -- they may interleave in any order (T7 exercises full interleaving). This test
   covers the simpler before/after-scope arrangement and checks that the counted and arena
   stat tiers stay independent across an arena open/close. */
static void test_arena_counted_coexistence(void) {
    WokHeap* h = wok_heap_new();

    /* Counted alloc before arena open. */
    WokObj* c1 = wok_alloc(h, 1u, 0u);   /* counted: 8 bytes */
    assert(wok_stat_allocs(h) == 1u);
    assert(wok_stat_live(h)   == 1);

    /* Open arena, alloc arena cells only within the scope. */
    uint32_t d = wok_arena_open(h);
    WokObj* a1 = wok_arena_alloc(h, 2u, 1u);   /* arena: 16 bytes */
    WokObj* a2 = wok_arena_alloc(h, 4u, 0u);   /* arena:  8 bytes */

    assert(wok_stat_allocs(h)      == 1u);    /* only c1 */
    assert(wok_stat_live(h)        == 1);
    assert(wok_stat_arena_bytes(h) == 24u);   /* a1 + a2 = 16 + 8 */

    /* slots work on arena cells */
    wok_slot_set(a1, 0u, 0xBEEFu);
    assert(wok_slot_get(a1, 0u) == 0xBEEFu);

    wok_arena_close(h, d);
    assert(wok_stat_arena_bytes(h) == 0u);
    assert(wok_stat_allocs(h)      == 1u);   /* counted unchanged */
    assert(wok_stat_live(h)        == 1);

    /* Counted alloc after arena close: must not be disturbed. */
    WokObj* c2 = wok_alloc(h, 3u, 2u);
    assert(wok_stat_allocs(h) == 2u);
    assert(wok_stat_live(h)   == 2);

    /* Clean up counted cells. */
    assert(wok_dec(c1) == 0u); wok_free(h, c1);
    assert(wok_dec(c2) == 0u); wok_free(h, c2);
    assert(wok_stat_live(h) == 0);

    (void)a2;

    wok_heap_free(h);
    printf("T5 PASS: counted allocs coexist with arena scope; stats stay independent\n");
}

/* ---- T6: arena alloc spanning slab boundary --------------------------------------- */
static void test_arena_multi_slab(void) {
    WokHeap* h = wok_heap_new();

    uint32_t d = wok_arena_open(h);

    /* Allocate enough arena cells to exhaust the initial slab (64 KiB = 65536 bytes).
       arity=0 -> 8 bytes each; 65536/8 = 8192 cells.  Allocate 9000 to cross a slab. */
    enum { N = 9000 };
    WokObj* ptrs[N];
    for (int i = 0; i < N; i++) {
        ptrs[i] = wok_arena_alloc(h, (uint32_t)(i % 65536), 0u);
        assert(wok_tag(ptrs[i]) == (uint32_t)(i % 65536));
    }

    /* Counted stats must still be 0. */
    assert(wok_stat_allocs(h) == 0u);
    assert(wok_stat_live(h)   == 0);

    uint64_t expected_bytes = (uint64_t)N * 8u;   /* arity=0 -> 8 bytes each */
    assert(wok_stat_arena_bytes(h) == expected_bytes);

#ifndef WOK_RC_MALLOC
    /* Detect that the scope crossed at least one slab boundary (Case B is genuinely
       exercised): some ptrs[i] is NOT contiguous with its predecessor. Detecting it at
       runtime (rather than hardcoding the slab-fill count) keeps the test robust to the
       slab-size tunable. Slab backend only -- the malloc backend has no slab structure
       (cells are independent mallocs with no contiguity guarantee). ptrs[0] is the start
       of the FIRST-grown arena slab (the scope opened with no arena slab). */
    int crossed_boundary = 0;
    for (int i = 1; i < N; i++) {
        if ((char*)ptrs[i] != (char*)ptrs[i - 1] + 8) {
            crossed_boundary = 1;
        }
    }
    assert(crossed_boundary);   /* >= 2 arena slabs grown -> Case B genuinely hit */
    uint64_t slabs_after_grow = wok_stat_arena_slabs(h);
    assert(slabs_after_grow >= 2u);
#endif

    /* Close: reclaim everything (even across slabs). This is the Case B reset path (new
       arena slabs were grown): the grown slabs are recycled onto the arena free-list and
       the bump frontier is restored to the saved checkpoint (here NULL -- the scope opened
       with no arena slab). */
    wok_arena_close(h, d);
    assert(wok_stat_arena_bytes(h) == 0u);
    assert(wok_stat_allocs(h) == 0u);
    assert(wok_stat_live(h)   == 0);

#ifndef WOK_RC_MALLOC
    /* Case B free-list reuse (slab backend only): a fresh scope must REUSE a recycled slab,
       not malloc a new one -- so wok_stat_arena_slabs (which counts mallocs) must NOT grow.
       The recycled slabs were pushed head-to-tail during the close unwind, so the free-list
       head is the FIRST-grown slab; its start is ptrs[0]. The first alloc of the new scope
       pops that slab, landing at exactly ptrs[0]. This pins both the free-list reuse (no
       malloc churn) and wok_new_arena_slab's granule offset; a bug in either would diverge. */
    uint32_t d2 = wok_arena_open(h);
    WokObj* reuse = wok_arena_alloc(h, 42u, 0u);
    assert(reuse == ptrs[0]);                          /* reused the first-grown slab */
    assert(wok_stat_arena_slabs(h) == slabs_after_grow); /* no new malloc: pure reuse */
    wok_arena_close(h, d2);
    assert(wok_stat_arena_bytes(h) == 0u);
#endif

    wok_heap_free(h);
    printf("T6 PASS: arena alloc spanning slab boundary; Case B free-list reuse\n");
}

/* ---- T7: INTERLEAVED arena + counted allocs; arena close must NOT clobber counted -- */
/* This is the regression test for the use-after-free that a SHARED bump region would
   cause. The routing pass deliberately emits BOTH Arena (non-escaping local) and Heap
   (escaping value) allocations in the SAME function body, in program order. So during an
   open arena scope, counted wok_alloc calls interleave with wok_arena_alloc calls. If the
   arena were a checkpoint into the SHARED counted bump region, resetting the frontier at
   close would reclaim the memory of escaping counted cells that are still referenced after
   the scope -> UAF. With a SEPARATE arena region, the counted cells live in a disjoint
   region and survive the close untouched. */
static void test_arena_interleaved_no_clobber(void) {
    WokHeap* h = wok_heap_new();

    uint32_t d = wok_arena_open(h);

    /* Interleave: arena, counted, arena, counted, ... Keep pointers to the counted cells
       and write distinctive payloads we will re-verify after close. */
    enum { PAIRS = 64 };
    WokObj* counted[PAIRS];
    for (int i = 0; i < PAIRS; i++) {
        WokObj* a = wok_arena_alloc(h, 100u + (uint32_t)i, 1u);   /* arena cell, arity 1 */
        wok_slot_set(a, 0u, 0xA000u + (uint64_t)i);

        WokObj* c = wok_alloc(h, 200u + (uint32_t)i, 2u);         /* counted (escaping) cell */
        wok_slot_set(c, 0u, 0xC000u + (uint64_t)i);
        wok_slot_set(c, 1u, 0xD000u + (uint64_t)i);
        counted[i] = c;
    }

    assert(wok_stat_allocs(h) == (uint64_t)PAIRS);   /* only the counted cells counted */
    assert(wok_stat_live(h)   == (int64_t)PAIRS);
    /* arena cells: PAIRS * (8 + 8*1) = PAIRS*16 bytes */
    assert(wok_stat_arena_bytes(h) == (uint64_t)PAIRS * 16u);

    /* Snapshot the counted region's frontier-affecting stats before close. */
    uint64_t allocs_before    = wok_stat_allocs(h);
    int64_t  live_before      = wok_stat_live(h);
    uint64_t peakbytes_before = wok_stat_peak_bytes(h);

    /* Close the arena: this must reset ONLY the arena region. */
    wok_arena_close(h, d);
    assert(wok_stat_arena_bytes(h) == 0u);

    /* The counted region's stats are untouched by the arena close. */
    assert(wok_stat_allocs(h)     == allocs_before);
    assert(wok_stat_live(h)       == live_before);
    assert(wok_stat_peak_bytes(h) == peakbytes_before);

    /* Reuse the arena region: allocate fresh arena cells (which, with a separate region,
       reuse the just-freed arena slab addresses). If the arena had shared the counted
       region, these writes would land on top of the retained counted cells -> corruption
       caught below. With a separate region, the counted cells are in a disjoint region. */
    uint32_t d2 = wok_arena_open(h);
    for (int i = 0; i < PAIRS; i++) {
        WokObj* a = wok_arena_alloc(h, 300u + (uint32_t)i, 2u);
        wok_slot_set(a, 0u, 0xEEEEu);   /* clobber pattern */
        wok_slot_set(a, 1u, 0xFFFFu);
    }

    /* The retained counted cells must be intact (no overwrite from arena reuse). */
    for (int i = 0; i < PAIRS; i++) {
        WokObj* c = counted[i];
        assert(wok_tag(c)   == 200u + (uint32_t)i);
        assert(wok_arity(c) == 2u);
        assert(wok_slot_get(c, 0u) == 0xC000u + (uint64_t)i);
        assert(wok_slot_get(c, 1u) == 0xD000u + (uint64_t)i);
    }

    wok_arena_close(h, d2);
    assert(wok_stat_arena_bytes(h) == 0u);

    /* Clean teardown of the counted cells (clean under ASan: no UAF, no double-free). */
    for (int i = 0; i < PAIRS; i++) {
        assert(wok_dec(counted[i]) == 0u);
        wok_free(h, counted[i]);
    }
    assert(wok_stat_live(h) == 0);

    wok_heap_free(h);
    printf("T7 PASS: interleaved arena+counted; arena close does not clobber counted cells\n");
}

/* ---- T8: leaked (never-closed) arena scope is drained at heap free (LSan-clean) ----- */
/* A correctly-balanced program closes every arena, but a leaked open scope at teardown
   must NOT leak the arena cells. wok_heap_free walks any open frames (malloc backend) /
   the arena slab region (slab backend) and frees them; it also warns loudly on the
   open/close imbalance. This test deliberately leaves TWO nested arenas open and relies
   on the sanitizers (LSan / ASan) to confirm no cell leaks. */
static void test_arena_leaked_scope_drained(void) {
    WokHeap* h = wok_heap_new();

    uint32_t dA = wok_arena_open(h);
    for (int i = 0; i < 10; i++) {
        wok_arena_alloc(h, 1u + (uint32_t)i, 2u);
    }
    uint32_t dB = wok_arena_open(h);
    for (int i = 0; i < 10; i++) {
        wok_arena_alloc(h, 100u + (uint32_t)i, 1u);
    }
    (void)dA; (void)dB;

    /* Intentionally do NOT close dB or dA. The "unbalanced open/close" warning is expected
       on stderr; the sanitizers must report no leak. */
    fprintf(stderr, "T8: leaving 2 arena scopes open on purpose (expect imbalance warning) ...\n");
    wok_heap_free(h);
    printf("T8 PASS: leaked arena scopes drained at heap free (no leak)\n");
}

/* ---- T10: bounded arena-slab lifecycle across many grow/close cycles --------------- */
/* REGRESSION for the unbounded-arena-slab leak (#1): a workload of many arena scopes that
   each grow PAST one slab must keep the total arena slabs ~the peak CONCURRENT need, not
   O(number of scopes). The pre-fix close kept every grown slab in arena_slabs and reset the
   bump pointer to the newest grown slab's start; each subsequent scope then re-filled that
   slab and grew ANOTHER, so arena_nslabs climbed by ~1 per scope -> O(cycles). The fix
   recycles the grown slabs onto a free-list that the next grow pops, bounding the count.
   The byte accounting (arena_bytes) returns to baseline either way, so only this physical
   slab-count stat catches the leak (the differential oracle is blind to it). Slab backend
   only -- the malloc backend frees arena cells per-close, so it is already bounded (it
   reports arena_slabs == 0 and the bound holds trivially). */
static void test_arena_bounded_slabs(void) {
    WokHeap* h = wok_heap_new();

    /* Cells per slab: a 64 KiB slab minus the granule header, arity-0 (8 bytes) cells.
       ~8191 fit. Allocate strictly more than that per scope so every scope grows a 2nd
       slab (genuine Case B), making the leak accumulate one slab per scope pre-fix. */
    enum { PER_SCOPE = 9000, CYCLES = 200 };

    for (int s = 0; s < CYCLES; s++) {
        uint32_t d = wok_arena_open(h);
        for (int i = 0; i < PER_SCOPE; i++) {
            WokObj* p = wok_arena_alloc(h, (uint32_t)(i % 65536), 0u);
            assert(wok_tag(p) == (uint32_t)(i % 65536));
        }
        /* arena_bytes is at its per-scope high while the scope is open. */
        assert(wok_stat_arena_bytes(h) == (uint64_t)PER_SCOPE * 8u);
        wok_arena_close(h, d);
        assert(wok_stat_arena_bytes(h) == 0u);   /* byte accounting always returns to 0 ... */
    }

    /* Counted stats never moved. */
    assert(wok_stat_allocs(h) == 0u);
    assert(wok_stat_live(h)   == 0);

#ifndef WOK_RC_MALLOC
    /* ... but the PHYSICAL slab count is the discriminator. Each scope needs at most a few
       concurrent slabs (PER_SCOPE*8 / 64KiB ~= 2). With recycling the total malloc'd stays
       a small constant; the pre-fix leak makes it grow ~1 per cycle (>= CYCLES). Assert it
       is bounded by a generous constant far below CYCLES so the test BITES on the old code
       (which would reach ~CYCLES+1) yet has slack against the exact slab geometry. */
    uint64_t slabs = wok_stat_arena_slabs(h);
    enum { PEAK_SLABS_PER_SCOPE = 3 };   /* 9000*8/65536 = 2 slabs; +1 generous headroom */
    assert(slabs <= (uint64_t)PEAK_SLABS_PER_SCOPE);
    printf("T10 PASS: arena slabs bounded at %llu across %d grow/close cycles (not O(cycles))\n",
           (unsigned long long)slabs, CYCLES);
#else
    /* malloc backend: no slab structure; arena cells freed per-close -> already bounded. */
    assert(wok_stat_arena_slabs(h) == 0u);
    printf("T10 PASS: malloc backend frees arena cells per-close (bounded; no slabs)\n");
#endif

    wok_heap_free(h);
}

/* ---- T12: PHYSICAL-invariant positive control ------------------------------------- */
/* A grow-heavy-then-free workload (T10-shaped: many arena scopes each spilling a 2nd slab)
   must keep peak_physical bounded -- the self-policing invariant holds with comfortable
   margin and NEVER trips. This is the green counterpart to the T11 death test: it proves the
   bound does not false-positive on a legitimate grow-heavy run. With WOK_RC_CHECK_PHYSICAL
   active (the sanitizer build), the assertion runs at every slab malloc inside this loop, so
   reaching the end is itself the proof; we additionally assert the reported high-water sits
   under the bound explicitly. */
static void test_physical_invariant_positive(void) {
    WokHeap* h = wok_heap_new();

    enum { PER_SCOPE = 9000, CYCLES = 200 };
    for (int s = 0; s < CYCLES; s++) {
        uint32_t d = wok_arena_open(h);
        for (int i = 0; i < PER_SCOPE; i++) {
            wok_arena_alloc(h, (uint32_t)(i % 65536), 0u);
        }
        wok_arena_close(h, d);
    }

    /* peak_physical is the arena region's concurrent slab need (~2-3 slabs, recycled), NOT
       O(cycles). It must stay far below a generous slab-count ceiling -- the same physical
       bound the gated assertion enforces, restated here as an always-checked positive. */
    uint64_t phys = wok_stat_peak_physical_bytes(h);
    enum { SLAB = 64 * 1024 };
    /* The arena needs ~2 concurrent slabs (9000*8 = 72000 ~= 2 slabs); recycling keeps the
       physical high-water at that, not climbing with the cycle count. 6 slabs is a generous
       ceiling far below the O(cycles) leak (which would reach ~CYCLES slabs). */
    assert(phys <= (uint64_t)6 * SLAB);
    assert(phys >= (uint64_t)2 * SLAB);   /* did genuinely grow past one slab (real Case B) */
    printf("T12 PASS: physical-invariant positive control: peak_physical=%llu bytes (~%llu slabs) "
           "bounded across %d grow/close cycles\n",
           (unsigned long long)phys, (unsigned long long)(phys / SLAB), CYCLES);

    wok_heap_free(h);
}

/* ---- T11: PHYSICAL-invariant negative control (death test) ------------------------- */
/* Orphaning slabs (physical bytes with NO logical allocation) is exactly the slab-leak bug
   class the self-policing invariant exists to catch. wok_test_orphan_slabs folds slab bytes
   into the heap's physical high-water without any logical alloc; with WOK_RC_CHECK_PHYSICAL
   active a large n drives peak_physical past K*logical + C*slab and the runtime aborts. This
   MUST NOT run in the normal pass (it calls abort) -- run it via WOK_TEST_DEATH=1.
   Only compiled when the test hook is available; otherwise it is a no-op reported as skipped. */
#if defined(WOK_RC_PHYSICAL_TEST_HOOK)
static void test_physical_invariant_abort(void) {
    WokHeap* h = wok_heap_new();
    fprintf(stderr, "T11: deliberately orphaning slabs to trip the physical-invariant abort ...\n");
    /* 64 slabs = 4 MiB physical vs an all-zero logical high-water -> bound 8*64KiB = 512 KiB.
       The abort fires partway through the loop (at the first slab past the bound). */
    wok_test_orphan_slabs(h, 64);
    /* unreachable if the invariant is active */
    fprintf(stderr, "T11 ERROR: physical-invariant abort did not fire "
                    "(was WOK_RC_CHECK_PHYSICAL compiled in?)\n");
    wok_heap_free(h);
}
#endif

/* ---- T9: mismatch-handle abort (death test) --------------------------------------- */
/* Normal test run skips this; set WOK_TEST_DEATH=1 to invoke abort intentionally.
   This test MUST NOT run in the normal CI pass — it calls abort().
   Document: when handle != arena_depth-1, wok_arena_close aborts immediately. */
static void test_arena_mismatch_abort(void) {
    WokHeap* h = wok_heap_new();
    uint32_t dA = wok_arena_open(h);   /* depth 0 */
    (void)wok_arena_open(h);           /* depth 1 */
    /* Trying to close dA (0) while dB (1) is still open -> abort. */
    fprintf(stderr, "T9: deliberately triggering mismatch abort ...\n");
    wok_arena_close(h, dA);            /* must abort: top is 1, handle is 0 */
    /* unreachable */
    wok_heap_free(h);
}

int main(void) {
    test_arena_basic_roundtrip();
    test_arena_lifo_nesting();
    test_arena_stats_isolated();
    test_arena_bytes_baseline();
    test_arena_counted_coexistence();
    test_arena_multi_slab();
    test_arena_interleaved_no_clobber();
    test_arena_leaked_scope_drained();
    test_arena_bounded_slabs();
    test_physical_invariant_positive();

    /* Death tests (each aborts; never run in the normal pass). Select by env value:
         WOK_TEST_DEATH=physical -> T11 physical-invariant negative control (needs the hook)
         WOK_TEST_DEATH=<other>  -> T9  arena mismatch-handle abort
       Both remain individually exercisable; the asan build runs the physical one. */
    {
        const char* death = getenv("WOK_TEST_DEATH");
        if (death != NULL) {
#if defined(WOK_RC_PHYSICAL_TEST_HOOK)
            if (strcmp(death, "physical") == 0) {
                test_physical_invariant_abort();
                fprintf(stderr, "ERROR: physical-invariant abort did not fire!\n");
                return 1;
            }
#endif
            test_arena_mismatch_abort();
            /* should never reach here */
            fprintf(stderr, "ERROR: mismatch abort did not fire!\n");
            return 1;
        }
    }

    printf("OK (arena)\n");
    return 0;
}
