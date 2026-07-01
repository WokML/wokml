#include "wok_rc.h"
#include <assert.h>
#include <stdint.h>
#include <stdlib.h>
#include <stdio.h>

static void test_wok_bytes_cell(void);
static void test_foreign_bytes_cell(void);
static void test_borrow_view_cell(void);
static void test_borrow_demo_lend_close(void);

static void test_wok_validate_utf8(void) {
    /* Valid: empty buffer */
    assert(wok_validate_utf8((const uint8_t*)"", 0) == 1);

    /* Valid: single ASCII byte */
    assert(wok_validate_utf8((const uint8_t*)"A", 1) == 1);

    /* Valid: two-byte UTF-8 sequence (é = U+00E9 = C3 A9) */
    assert(wok_validate_utf8((const uint8_t*)"\xC3\xA9", 2) == 1);

    /* Invalid: overlong encoding (U+0000 as 2-byte) */
    assert(wok_validate_utf8((const uint8_t*)"\xC0\x80", 2) == 0);

    /* Invalid: lone continuation byte */
    assert(wok_validate_utf8((const uint8_t*)"\x80", 1) == 0);

    /* Invalid: > U+10FFFF (0xF7BFBFBF encodes U+1FFFFF, outside valid range) */
    assert(wok_validate_utf8((const uint8_t*)"\xF7\xBF\xBF\xBF", 4) == 0);

    /* Invalid: lone surrogate (0xED A0 80 = U+D800, surrogate) */
    assert(wok_validate_utf8((const uint8_t*)"\xED\xA0\x80", 3) == 0);

    /* Invalid: truncated multibyte sequence (incomplete 3-byte) */
    assert(wok_validate_utf8((const uint8_t*)"\xE2\x82", 2) == 0);
}

int main(void) {
    /* --- UTF-8 validator sanity tests (Task 2, Slice E6) ----- */
    test_wok_validate_utf8();
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

    /* --- FBIP reuse round-trip: drop_reuse -> alloc_at re-stamps in place ----------- */
    {
        WokHeap* h = wok_heap_new();
        WokObj* p = wok_alloc(h, 3u, 2u);   /* the donor cell, arity 2 */
        wok_slot_set(p, 0u, 10u);
        wok_slot_set(p, 1u, 20u);
        uint64_t allocs_before = wok_stat_allocs(h);
        uint64_t frees_before  = wok_stat_frees(h);
        int64_t  live_before   = wok_stat_live(h);

        assert(wok_dec(p) == 0u);           /* unique drop: rc 1 -> 0, do NOT free */
        WokObj* q = wok_alloc_at(h, 9u, 2u, p);   /* re-stamp the same shell */

        assert(q == p);                                  /* reuse: same physical cell */
        assert(wok_tag(q) == 9u);                        /* new tag */
        assert(wok_arity(q) == 2u);                      /* same arity */
        assert(wok_stat_allocs(h) == allocs_before);     /* NO alloc recorded */
        assert(wok_stat_frees(h)  == frees_before);      /* NO free recorded */
        assert(wok_stat_live(h)   == live_before);       /* live unchanged (reserved -> revived) */
#ifndef WOK_RC_MALLOC
        assert(wok_stat_reused_inplace(h) == 1u);        /* arena: one in-place reuse */
#else
        assert(wok_stat_reused_inplace(h) == 0u);        /* malloc backend: always 0 */
#endif

        /* fresh slots write+read correctly into the re-stamped shell */
        wok_slot_set(q, 0u, 100u);
        wok_slot_set(q, 1u, 200u);
        assert(wok_slot_get(q, 0u) == 100u);
        assert(wok_slot_get(q, 1u) == 200u);

        /* clean teardown: rc 1 -> 0, then real free */
        assert(wok_dec(q) == 0u);
        wok_free(h, q);
        assert(wok_stat_live(h) == 0);
        wok_heap_free(h);
    }

    /* --- FBIP not-eligible fallback: reserve a shell, allocate over it, free it ------
       The alloc_at "not eligible" branch (spec section 4.3) does NOT re-stamp the
       reserved shell -- it frees it for real and allocates fresh. This exercises that
       free path AND the reserve-window-vs-allocation discipline: while the shell is
       reserved (rc==0, NOT on the free list, NOT handed back), an intervening
       wok_alloc must return a DIFFERENT pointer -- the reserved shell is never handed
       out. Then wok_free on the reserved shell (the not-eligible fallback) tears down
       cleanly. Under WOK_RC_MALLOC + -fsanitize=address this closes the oracle hole
       over the new reserved-shell free path: no UAF, no double-free. */
    {
        WokHeap* h = wok_heap_new();
        WokObj* p = wok_alloc(h, 3u, 2u);         /* the would-be donor shell, arity 2 */
        wok_slot_set(p, 0u, 11u);
        wok_slot_set(p, 1u, 22u);
        assert(wok_dec(p) == 0u);                 /* unique drop: rc 1 -> 0, RESERVE (no free) */

        /* Intervening allocation: the reserved shell is NOT on the free list and must
           not be handed back. (Same arity, to prove it is the RESERVATION -- not an
           arity-class miss -- that keeps the shell out of circulation.) */
        WokObj* other = wok_alloc(h, 4u, 2u);
        assert(other != p);                       /* reserved shell never handed out */

        /* The not-eligible fallback: free the reserved shell for real. rc is already 0
           (reserved), exactly the state wok_free expects, so this is the genuine
           reserve-then-free path. */
        wok_free(h, p);

        /* `other` lives on independently; clean teardown. */
        assert(wok_dec(other) == 0u);
        wok_free(h, other);
        assert(wok_stat_live(h) == 0);
        wok_heap_free(h);
    }

    /* --- WokArray: alloc/len/elemkind/slot round-trip --------------------------------- */
    {
        WokHeap* h = wok_heap_new();

        /* Basic round-trip: len=3, elemkind=0 */
        WokObj* arr = wok_array_alloc(h, 3u, 0u);
        assert(wok_tag(arr)              == WOK_ARRAY_TAG);
        assert(wok_array_len(arr)        == 3u);
        assert(wok_array_elemkind(arr)   == 0u);

        wok_array_slot_set(arr, 0u, 11u);
        wok_array_slot_set(arr, 1u, 22u);
        wok_array_slot_set(arr, 2u, 33u);
        assert(wok_array_slot_get(arr, 0u) == 11u);
        assert(wok_array_slot_get(arr, 1u) == 22u);
        assert(wok_array_slot_get(arr, 2u) == 33u);

        /* peak_bytes: 16 + 8*3 = 40 bytes */
        assert(wok_stat_peak_bytes(h) == 40u);

        assert(wok_dec(arr) == 0u);
        wok_free(h, arr);
        assert(wok_stat_live(h) == 0);

        /* Shared free-list with NCon arity=4: len=3 -> class=4, NCon arity=4 -> class=4.
           After freeing the array, a wok_alloc for arity=4 must return the SAME pointer
           (arena only; malloc backend makes no reuse promise). */
        WokObj* ncon = wok_alloc(h, 7u, 4u);
#ifndef WOK_RC_MALLOC
        assert(ncon == arr);              /* pointer-identity reuse: cross-shape, same size class */
        assert(wok_stat_reused(h) == 1u); /* a freelist pop, not a fresh bump */
#else
        (void)arr;
#endif
        assert(wok_tag(ncon)   == 7u);
        assert(wok_arity(ncon) == 4u);
        assert(wok_dec(ncon) == 0u);
        wok_free(h, ncon);
        wok_heap_free(h);
    }

    /* --- WokArray: len=0 (smallest array, 16 bytes, class 1) -------------------------- */
    {
        WokHeap* h = wok_heap_new();
        WokObj* empty = wok_array_alloc(h, 0u, 0u);
        assert(wok_tag(empty)          == WOK_ARRAY_TAG);
        assert(wok_array_len(empty)    == 0u);
        /* peak_bytes: 16 + 8*0 = 16 bytes (the smallest array cell) */
        assert(wok_stat_peak_bytes(h) == 16u);
        assert(wok_dec(empty) == 0u);
        wok_free(h, empty);
        assert(wok_stat_live(h) == 0);

        /* class = len+1 = 1, shared with NCon arity 1 (also 16 bytes). The freed empty
           array recycles into freelist[1]; an arity-1 NCon reuses the same cell (arena). */
        WokObj* ncon = wok_alloc(h, 9u, 1u);
#ifndef WOK_RC_MALLOC
        assert(ncon == empty);            /* arena: routed to freelist[1], not malloc */
        assert(wok_stat_reused(h) == 1u);
#else
        (void)empty;
#endif
        assert(wok_dec(ncon) == 0u);
        wok_free(h, ncon);
        assert(wok_stat_live(h) == 0);
        wok_heap_free(h);
    }

    /* --- WokArray: large path (len >= 63 -> malloc) ----------------------------------- */
    {
        WokHeap* h = wok_heap_new();
        WokObj* big = wok_array_alloc(h, 100u, 1u);
        assert(wok_tag(big)            == WOK_ARRAY_TAG);
        assert(wok_array_len(big)      == 100u);
        assert(wok_array_elemkind(big) == 1u);

        wok_array_slot_set(big, 0u,  0xABCDu);
        wok_array_slot_set(big, 99u, 0xDEADu);
        assert(wok_array_slot_get(big, 0u)  == 0xABCDu);
        assert(wok_array_slot_get(big, 99u) == 0xDEADu);

        /* peak_bytes: 16 + 8*100 = 816 bytes */
        assert(wok_stat_peak_bytes(h) == 816u);

        assert(wok_dec(big) == 0u);
        wok_free(h, big);
        assert(wok_stat_live(h) == 0);
        wok_heap_free(h);
    }

    /* --- wok_free tag-first dispatch: no misroute on array freed after NCon ----------- */
    {
        /* Allocate an NCon (arity=2, class=2, bytes=24) then an array (len=1, class=2,
           bytes=24). They share the same free-list class. Free both; verify live==0 and
           no abort (a misroute would read elemkind as arity -> wrong byte size -> corrupt
           cur_bytes -> live check would see a bad value). */
        WokHeap* h = wok_heap_new();
        WokObj* ncon = wok_alloc(h, 5u, 2u);
        WokObj* arr  = wok_array_alloc(h, 1u, 0u);
        assert(wok_dec(ncon) == 0u);
        wok_free(h, ncon);
        assert(wok_dec(arr) == 0u);
        wok_free(h, arr);
        assert(wok_stat_live(h) == 0);
        wok_heap_free(h);
    }

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

    /* --- WokString: alloc/len/data/byte_get round-trip (Task 1, Slice E1) ------------- */
    /* Test byte_len in {0, 1, 7, 8, 9, 500}: write bytes via wok_string_data, read via
       wok_string_byte_get, check wok_string_len, free, assert live==0 and allocs==frees. */
    {
        static const uint64_t byte_lens[] = {0u, 1u, 7u, 8u, 9u, 500u};
        static const size_t   nlens = sizeof(byte_lens) / sizeof(byte_lens[0]);
        for (size_t li = 0; li < nlens; li++) {
            uint64_t byte_len = byte_lens[li];
            WokHeap* h = wok_heap_new();

            WokObj* s = wok_string_alloc(h, byte_len);
            assert(s != NULL);
            assert(wok_tag(s)        == WOK_STRING_TAG);
            assert(wok_string_len(s) == byte_len);
            assert(wok_rc(s)         == 1u);

            /* Write known bytes, read them back. */
            uint8_t* body = wok_string_data(s);
            for (uint64_t i = 0u; i < byte_len; i++) {
                body[i] = (uint8_t)((i * 37u + 13u) & 0xFFu);
            }
            for (uint64_t i = 0u; i < byte_len; i++) {
                uint64_t got = wok_string_byte_get(s, i);
                assert(got == (uint64_t)((i * 37u + 13u) & 0xFFu));
            }

            /* peak_bytes must be the rounded cell size: 16 + 8*ceil(byte_len/8) */
            uint64_t expected_bytes = 16u + 8u * ((byte_len + 7u) / 8u);
            assert(wok_stat_peak_bytes(h) == expected_bytes);

            assert(wok_dec(s) == 0u);
            wok_free(h, s);
            assert(wok_stat_live(h)   == 0);
            assert(wok_stat_allocs(h) == wok_stat_frees(h));
            wok_heap_free(h);
        }
    }

    /* --- WokString: size-class sharing with WokArray of the same byte size ------------ */
    /* A WokString of byte_len=7 has cell size 16+8*1=24 bytes -> class 2.
       A WokArray of len=1 also has cell size 16+8*1=24 bytes -> class 2.
       After freeing the string, allocating an array of the same byte size must reuse it
       (arena: pointer identity; both cases: reused count increments). */
    {
        WokHeap* h = wok_heap_new();
        /* byte_len=7 -> ceil(7/8)=1 -> class = 1+1 = 2, same as WokArray len=1 (class=1+1=2) */
        WokObj* str = wok_string_alloc(h, 7u);
        assert(wok_string_len(str) == 7u);
#ifndef WOK_RC_MALLOC
        uint64_t reused_before = wok_stat_reused(h);
#endif
        assert(wok_dec(str) == 0u);
        wok_free(h, str);

        WokObj* arr = wok_array_alloc(h, 1u, 0u);
#ifndef WOK_RC_MALLOC
        assert(arr == str);                           /* arena: pointer-identity reuse */
        assert(wok_stat_reused(h) == reused_before + 1u);
#else
        (void)str;
#endif
        assert(wok_tag(arr)          == WOK_ARRAY_TAG);
        assert(wok_array_len(arr)    == 1u);
        assert(wok_dec(arr) == 0u);
        wok_free(h, arr);
        assert(wok_stat_live(h) == 0);
        wok_heap_free(h);
    }

    /* --- WokString: wok_free tag dispatch does not misroute a string as an NCon ------- */
    /* Alloc an NCon (arity=2, 24 bytes) then a WokString (byte_len=7 -> 24 bytes, class 2).
       They share the same class. Free both; verify live==0 (misroute would compute wrong
       byte size via arity and corrupt cur_bytes). */
    {
        WokHeap* h = wok_heap_new();
        WokObj* ncon = wok_alloc(h, 5u, 2u);
        WokObj* str  = wok_string_alloc(h, 7u);
        assert(wok_dec(ncon) == 0u);
        wok_free(h, ncon);
        assert(wok_dec(str) == 0u);
        wok_free(h, str);
        assert(wok_stat_live(h) == 0);
        assert(wok_stat_allocs(h) == wok_stat_frees(h));
        wok_heap_free(h);
    }

    /* --- WokString: large path (byte_len >= 8*(WOK_NUM_CLASSES-2)+1 = 497 -> class >= 64 -> malloc) ---- */
    /* byte_len=500 -> ceil(500/8)=63 -> class=64 >= WOK_NUM_CLASSES -> large/malloc path */
    {
        WokHeap* h = wok_heap_new();
        WokObj* s = wok_string_alloc(h, 500u);
        assert(wok_string_len(s) == 500u);
        uint8_t* body = wok_string_data(s);
        for (uint64_t i = 0u; i < 500u; i++) {
            body[i] = (uint8_t)(i & 0xFFu);
        }
        for (uint64_t i = 0u; i < 500u; i++) {
            assert(wok_string_byte_get(s, i) == (uint64_t)(i & 0xFFu));
        }
        /* peak_bytes: 16 + 8*ceil(500/8) = 16 + 8*63 = 16 + 504 = 520 bytes */
        assert(wok_stat_peak_bytes(h) == 520u);
        assert(wok_dec(s) == 0u);
        wok_free(h, s);
        assert(wok_stat_live(h) == 0);
        wok_heap_free(h);
    }

    /* --- WokBytes: alloc/len/data/byte_get lifecycle (Slice E6) ----------------------- */
    test_wok_bytes_cell();

    /* --- WokForeignBytes: adopted foreign buffer lifecycle (FFI Slice 1) -------------- */
    test_foreign_bytes_cell();

    /* --- WokBorrowView: uncounted-ownership borrowed buffer lifecycle (FFI Slice 3) --- */
    test_borrow_view_cell();

    /* --- Demo borrow producer: malloc'd lend-THEN-free pair (FFI Slice 3 Task 5) ------ */
    test_borrow_demo_lend_close();

    printf("OK\n");
    return 0;
}

/* FFI Slice 3 Task 5: the malloc'd Demo borrow producer's lend/close lifecycle. lend mallocs
   a real buffer (the deterministic i&0xFF pattern); close frees it. A balanced lend/close pair
   is LSan-clean (Linux) and ASan-clean everywhere (no double-free, no UAF); the deterministic
   contents are what the interpreter reads through the 0xFFFA view. The capacity clamp and the
   0-length (still-freeable) edge are exercised too. */
static void test_borrow_demo_lend_close(void) {
    /* normal lend: 8 bytes of i&0xFF, then close (the only owner frees it once). */
    uint8_t* b = wok_borrow_demo_lend(8u);
    assert(b != NULL);
    for (unsigned i = 0u; i < 8u; i++) { assert(b[i] == (uint8_t)(i & 0xFFu)); }
    wok_borrow_demo_close(b);

    /* capacity clamp: an over-large n saturates to WOK_BORROW_DEMO_CAPACITY (no overrun). */
    uint8_t* big = wok_borrow_demo_lend(WOK_BORROW_DEMO_CAPACITY + 4096u);
    assert(big != NULL);
    assert(big[WOK_BORROW_DEMO_CAPACITY - 1u] == (uint8_t)((WOK_BORROW_DEMO_CAPACITY - 1u) & 0xFFu));
    wok_borrow_demo_close(big);

    /* 0-length lend still returns a distinct, freeable pointer (malloc(0) is impl-defined). */
    uint8_t* empty = wok_borrow_demo_lend(0u);
    assert(empty != NULL);
    wok_borrow_demo_close(empty);

    /* free(NULL) is a no-op (the AbstractHeap sentinel analogue at the C boundary). */
    wok_borrow_demo_close(NULL);

    printf("ok test_borrow_demo_lend_close\n");
}

static void test_wok_bytes_cell(void) {
    /* Basic lifecycle: alloc N=5, write bytes, read back, check len, free, stats. */
    enum { N = 5 };
    WokHeap* h = wok_heap_new();

    WokObj* p = wok_bytes_alloc(h, (uint64_t)N);
    assert(p != NULL);
    assert(wok_tag(p)     == WOK_BYTES_TAG);
    assert(wok_bytes_len(p) == (uint64_t)N);
    assert(wok_rc(p)      == 1u);

    /* Write N bytes via wok_bytes_data; include 255 to confirm no sign extension. */
    uint8_t* body = wok_bytes_data(p);
    body[0] = 10u;
    body[1] = 20u;
    body[2] = 30u;
    body[3] = 40u;
    body[4] = 255u;

    /* Read back via wok_bytes_byte_get (zero-extended to uint64_t). */
    assert(wok_bytes_byte_get(p, 0u) == 10u);
    assert(wok_bytes_byte_get(p, 1u) == 20u);
    assert(wok_bytes_byte_get(p, 2u) == 30u);
    assert(wok_bytes_byte_get(p, 3u) == 40u);
    assert(wok_bytes_byte_get(p, 4u) == 255u);

    /* peak_bytes: same formula as WokString -- 16 + 8*ceil(N/8) */
    uint64_t expected_bytes = 16u + 8u * (((uint64_t)N + 7u) / 8u);
    assert(wok_stat_peak_bytes(h) == expected_bytes);

    /* Decrement to zero and free; verify heap returns to baseline. */
    assert(wok_dec(p) == 0u);
    wok_free(h, p);
    assert(wok_stat_live(h)   == 0);
    assert(wok_stat_allocs(h) == wok_stat_frees(h));

    wok_heap_free(h);
}

/* ---- WokForeignBytes: adopted foreign buffer lifecycle (FFI Slice 1) ----------------
   Lifecycle: malloc a genuinely foreign buffer, adopt into a WokForeignBytes cell, verify
   tag/ptr/len/cur_bytes, then execute the host-driven drop protocol (libc free FIRST, then
   wok_free to recycle the 24B handle). Checks wok_stat_live returns to 0.
   Negative control: omit the libc free and LSan reports a leak. Gated under
   WOK_FOREIGN_BYTES_LEAK_TEST so the default suite stays leak-free; scripts/asan-runtime.sh
   runs a separate invocation with -DWOK_FOREIGN_BYTES_LEAK_TEST to verify LSan fires.
   On Darwin, LSan is unsupported by Apple's ASan runtime, so the negative control is
   documented but not mechanically verified in CI (same policy as WOK_RC_PHYSICAL_TEST_HOOK). */
static void test_foreign_bytes_cell(void) {
    WokHeap* h = wok_heap_new();
    uint64_t base_peak = wok_stat_peak_bytes(h);

    /* genuinely foreign: libc malloc, outside wok allocator */
    uint8_t* buf = (uint8_t*)malloc(5);
    assert(buf != NULL);
    for (int i = 0; i < 5; i++) buf[i] = (uint8_t)i;

    WokObj* p = wok_foreign_bytes_alloc(h, buf, 5);
    assert(p != NULL);
    assert(wok_tag(p)               == WOK_FOREIGN_BYTES_TAG);
    assert(wok_rc(p)                == 1u);
    assert(wok_foreign_bytes_ptr(p) == buf);
    assert(wok_foreign_bytes_len(p) == 5u);
    /* the 24B handle is charged; the foreign buffer is NOT counted */
    assert(wok_stat_peak_bytes(h) >= base_peak + 24u);

#ifndef WOK_FOREIGN_BYTES_LEAK_TEST
    free(buf);   /* host-driven foreign free FIRST (libc) */
#endif
    /* host decremented rc to 0; now recycle the 24B handle */
    assert(wok_dec(p) == 0u);
    wok_free(h, p);
    assert(wok_stat_live(h) == 0);
    assert(wok_stat_allocs(h) == wok_stat_frees(h));

    wok_heap_free(h);
    printf("ok test_foreign_bytes_cell\n");
}

/* ---- WokBorrowView: uncounted-ownership borrowed buffer lifecycle (FFI Slice 3) -----
   Positive: alloc a view over a STACK buffer (never libc-malloc'd, never libc-freed -- a
   genuine borrow, not an adopt), verify tag/ptr/len/cur_bytes, drop it, and confirm the
   handle is reclaimed (wok_stat_live back to 0; LSan-clean -- no separate free obligation
   exists for a stack buffer).
   Negative control: the buffer is on the stack, so if wok_free ever called free() on
   `ptr` (the WOK_FOREIGN_BYTES_TAG mistake), this would crash immediately under ASan
   (free of a non-heap pointer) -- the mutation this test is designed to catch. We also
   re-check the buffer's contents AFTER the drop to confirm it was never touched/poisoned. */
static void test_borrow_view_cell(void) {
    WokHeap* h = wok_heap_new();
    uint64_t base_peak = wok_stat_peak_bytes(h);

    /* genuinely foreign-shaped but actually a STACK buffer: wok must NEVER free this */
    uint8_t buf[4] = {1u, 2u, 3u, 4u};

    WokObj* v = wok_borrow_view_alloc(h, buf, 4);
    assert(v != NULL);
    assert(wok_tag(v)            == WOK_BORROW_VIEW_TAG);
    assert(wok_rc(v)             == 1u);
    assert(wok_borrow_view_ptr(v) == buf);
    assert(wok_borrow_view_len(v) == 4u);
    /* the 24B handle is charged; the borrowed buffer is NOT counted */
    assert(wok_stat_peak_bytes(h) >= base_peak + 24u);

    /* drop: decrement to zero and recycle the 24B handle. NO free(buf) anywhere --
       that is the entire point (contrast test_foreign_bytes_cell's libc free). */
    assert(wok_dec(v) == 0u);
    wok_free(h, v);
    assert(wok_stat_live(h)   == 0);
    assert(wok_stat_allocs(h) == wok_stat_frees(h));

    /* negative control: the buffer must be untouched (no bad-free, no poison-through) */
    assert(buf[0] == 1u && buf[1] == 2u && buf[2] == 3u && buf[3] == 4u);

    wok_heap_free(h);
    printf("ok test_borrow_view_cell\n");
}
