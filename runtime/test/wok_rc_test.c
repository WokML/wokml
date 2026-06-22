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
        wok_slot_set(p, 0u, 42u);
        wok_slot_set(p, 1u, 0u);
        assert(wok_tag(p) == 7u);
        assert(wok_arity(p) == 2u);
        uint64_t w = wok_slot_get(p, 0u);
        assert(w == 42u);
        wok_dup(p);
        assert(wok_dec(p) == 1u);
        assert(wok_dec(p) == 0u);
        wok_free(h, p);
        assert(wok_stat_allocs(h) == 1u);
        assert(wok_stat_frees(h) == 1u);
        assert(wok_stat_live(h) == 0);
        assert(wok_stat_peak(h) == 1);
        /* peak_bytes: arity 2 -> 8 + 2*8 = 24 bytes; cell freed so cur=0, peak stays */
        assert(wok_stat_peak_bytes(h) == 24u);
        wok_heap_free(h);
    }

    /* --- peak_bytes high-water: allocate two cells, peak captured at two-cell mark --- */
    {
        WokHeap* h = wok_heap_new();
        /* arity 0: 8 bytes; arity 1: 16 bytes */
        WokObj* a = wok_alloc(h, 1u, 0u);   /* +8  -> cur=8,  peak=8  */
        WokObj* b = wok_alloc(h, 2u, 1u);   /* +16 -> cur=24, peak=24 */
        assert(wok_stat_peak_bytes(h) == 24u);
        assert(wok_dec(a) == 0u); wok_free(h, a);  /* cur=16, peak stays 24 */
        assert(wok_stat_peak_bytes(h) == 24u);
        assert(wok_dec(b) == 0u); wok_free(h, b);  /* cur=0,  peak stays 24 */
        assert(wok_stat_peak_bytes(h) == 24u);
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
        wok_slot_set(big, 99u, 7u);
        uint64_t w = wok_slot_get(big, 99u);
        assert(w == 7u);
        assert(wok_dec(big) == 0u);
        wok_free(h, big);
        assert(wok_stat_live(h) == 0);
        wok_heap_free(h);
    }

    /* --- multi-slab bump: headers intact across a slab boundary; bulk teardown --- */
    {
        WokHeap* h = wok_heap_new();
        enum { N = 9000 };              /* 9000 * 8 B > 64 KiB -> spills a 2nd slab */
        WokObj** ptrs = (WokObj**)malloc((size_t)N * sizeof(WokObj*));
        assert(ptrs != NULL);
        for (int i = 0; i < N; i++) {
            ptrs[i] = wok_alloc(h, (uint32_t)i % 65536u, 0u);
            assert(wok_tag(ptrs[i]) == (uint32_t)i % 65536u);
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
