#include "wok_rc.h"
#include <assert.h>
#include <stdlib.h>
#include <stdio.h>

_Static_assert(sizeof(WokSlot) == 16, "WokSlot must be 16 bytes");
_Static_assert(sizeof(WokObj)  == 16, "WokObj header must be 16 bytes");

struct WokHeap {
    uint64_t allocs;
    uint64_t frees;
    int64_t  live;
    int64_t  peak;
};

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
    size_t bytes = sizeof(WokObj) + (size_t)arity * sizeof(WokSlot);
    WokObj* p = (WokObj*)malloc(bytes);
    if (WOK_UNLIKELY(p == NULL)) { abort(); }
    p->rc = 1u;
    p->tag = tag;
    p->arity = arity;
    h->allocs += 1u;
    h->live   += 1;
    if (h->live > h->peak) { h->peak = h->live; }
    return p;
}

void wok_dup(WokObj* p) { p->rc += 1u; }

uint64_t wok_dec(WokObj* p) {
    /* DELIBERATE DIVERGENCE from the abstract Haskell heap. The abstract path
       returns a RECOVERABLE Left "double-free" (consumed by the M3 double-resume
       red-checks); the C production path instead fails fast with abort() on a
       detected over-free. This fail-fast on memory corruption is intentional, not
       an oversight: a real over-free in production is unrecoverable. */
    if (WOK_UNLIKELY(p->rc == 0u)) {
        fprintf(stderr, "wok_rc: wok_dec on rc==0 (double-free)\n");
        abort();
    }
    p->rc -= 1u;
    return p->rc;
}

void wok_free(WokHeap* h, WokObj* p) {
    if (WOK_UNLIKELY(p->rc != 0u)) {
        fprintf(stderr, "wok_rc: wok_free on rc!=0 (premature free)\n");
        abort();
    }
    h->frees += 1u;
    h->live  -= 1;
    free(p);
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
