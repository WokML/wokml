#include "wok_rc.h"
#include <assert.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>   /* memcpy, memset */

_Static_assert(sizeof(WokObj)  == 8, "WokObj header must be 8 bytes");

/* --- tunables (spec section 11) --------------------------------------------- */
#define WOK_GRANULE     8u
#define WOK_ARENA_SIZE  (64u * 1024u)   /* slab bytes */
#define WOK_NUM_CLASSES 64u             /* arity 0..63 -> slabs; >=64 -> malloc */

_Static_assert(WOK_ARENA_SIZE % WOK_GRANULE == 0u,
               "arena size must be a granule multiple");
_Static_assert((sizeof(WokObj) + (WOK_NUM_CLASSES - 1u) * sizeof(uint64_t)) < WOK_ARENA_SIZE,
               "largest slab-class cell must fit a slab");

static size_t wok_cell_bytes(uint32_t arity) {
    return sizeof(WokObj) + (size_t)arity * sizeof(uint64_t);
}

/* INVARIANT: both `struct WokHeap` definitions below begin with the same four fields
   (allocs, frees, live, peak) in the same order; the shared wok_stat_allocs/frees/live/
   peak accessors read them by layout. Keep the prefix in sync. Drift is caught by the
   stat assertions in both builds (the arena via the Haskell differential oracle, the
   WOK_RC_MALLOC build via the standalone test). */
#ifdef WOK_RC_MALLOC
/* ---- retained slice-1 allocator: one malloc per cell (UAF oracle + bench baseline) ---- */
struct WokHeap { uint64_t allocs; uint64_t frees; int64_t live; int64_t peak; uint64_t cur_bytes; uint64_t peak_bytes; };

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
    assert(tag < 65536u && arity < 256u);
    WokObj* p = (WokObj*)malloc(wok_cell_bytes(arity));
    if (WOK_UNLIKELY(p == NULL)) { abort(); }
    p->rc = 1u; p->tag = (uint16_t)tag; p->arity = (uint8_t)arity; p->scan = 0u;
    h->allocs += 1u; h->live += 1;
    if (h->live > h->peak) { h->peak = h->live; }
    h->cur_bytes += (uint64_t)wok_cell_bytes(arity);
    if (h->cur_bytes > h->peak_bytes) { h->peak_bytes = h->cur_bytes; }
    return p;
}
void wok_free(WokHeap* h, WokObj* p) {
    if (WOK_UNLIKELY(p->rc != 0u)) { fprintf(stderr, "wok_rc: wok_free on rc!=0 (premature free)\n"); abort(); }
    uint32_t arity = (uint32_t)p->arity;
    h->frees += 1u; h->live -= 1;
    h->cur_bytes -= (uint64_t)wok_cell_bytes(arity);
    free(p);
}
/* FBIP in-place reuse: re-stamp a just-decremented cell's header without touching
   the allocator or any byte-accounting stat. The new tag re-uses the EXACT same
   shell (same arity, same byte size), so live/peak/cur_bytes are unchanged. No
   reuse counter on the malloc backend (mirrors wok_stat_reused). */
WokObj* wok_alloc_at(WokHeap* h, uint32_t tag, uint32_t arity, WokObj* p) {
    (void)h;
    assert(tag < 65536u && arity < 256u);
    /* The arity-match and rc==0 invariants are ALWAYS-ON (mirroring wok_free's
       premature-free guard): a mispaired reuse token (wrong-arity re-stamp, or a
       still-live shell) must abort LOUDLY in release builds too, not be stripped
       under NDEBUG. */
    if (WOK_UNLIKELY((uint32_t)p->arity != arity)) {
        fprintf(stderr, "wok_rc: wok_alloc_at arity mismatch (token arity != new node arity)\n");
        abort();
    }
    if (WOK_UNLIKELY(p->rc != 0u)) {
        fprintf(stderr, "wok_rc: wok_alloc_at on rc!=0 (drop_reuse must decrement the shell to 0 before re-stamp)\n");
        abort();
    }
    p->rc = 1u; p->tag = (uint16_t)tag; p->arity = (uint8_t)arity; p->scan = 0u;
    return p;
}
uint64_t wok_stat_reused(const WokHeap* h)         { (void)h; return 0u; }
uint64_t wok_stat_reused_inplace(const WokHeap* h) { (void)h; return 0u; }
uint64_t wok_stat_slabs(const WokHeap* h)          { (void)h; return 0u; }

#else
/* ---- the slab arena (default) ------------------------------------------------------- */
typedef struct WokSlab { struct WokSlab* next; } WokSlab;
/* Cells start at `slab + WOK_GRANULE`, so the slab header must fit in one granule;
   otherwise the first bumped cell would overlap (and corrupt) the slab link. */
_Static_assert(sizeof(WokSlab) <= WOK_GRANULE, "WokSlab header must fit in one granule");

struct WokHeap {
    uint64_t allocs;
    uint64_t frees;
    int64_t  live;
    int64_t  peak;
    uint64_t cur_bytes;              /* current live bytes: Σ(8 + 8*arity) */
    uint64_t peak_bytes;             /* high-water mark of cur_bytes */
    uint64_t reused;                 /* free-list pops */
    uint64_t reused_inplace;         /* FBIP wok_alloc_at hits */
    uint64_t nslabs;                 /* slabs malloc'd */
    WokSlab* slabs;                  /* linked list, for O(slabs) bulk teardown */
    char*    bump_ptr;
    char*    bump_end;
    WokObj*  freelist[WOK_NUM_CLASSES];
};

/* strict-aliasing-safe free-list link: store/load the next ptr in the dead cell's bytes.
   Casts to void* suppress -Wsizeof-pointer-memaccess: we intentionally copy pointer-sized
   bytes, not the full WokObj struct. The minimum cell is 8 bytes (the header alone, for
   arity 0), which is exactly sizeof(WokObj*) on a 64-bit platform -- just enough. */
static WokObj* fl_next(WokObj* p) {
    WokObj* n;
    memcpy(&n, (void*)p, sizeof(WokObj*));
    return n;
}
static void fl_set_next(WokObj* p, WokObj* n) {
    memcpy((void*)p, &n, sizeof(WokObj*));
}

static void wok_new_slab(WokHeap* h) {
    WokSlab* s = (WokSlab*)malloc(WOK_ARENA_SIZE);
    if (WOK_UNLIKELY(s == NULL)) { abort(); }
    s->next = h->slabs;
    h->slabs = s;
    h->nslabs += 1u;
    /* cells start one granule in (sizeof(WokSlab) <= 8), preserving 8-alignment. */
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
    assert(tag < 65536u && arity < 256u);
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
    p->rc = 1u; p->tag = (uint16_t)tag; p->arity = (uint8_t)arity; p->scan = 0u;
    h->allocs += 1u; h->live += 1;
    if (h->live > h->peak) { h->peak = h->live; }
    h->cur_bytes += (uint64_t)wok_cell_bytes(arity);
    if (h->cur_bytes > h->peak_bytes) { h->peak_bytes = h->cur_bytes; }
    return p;
}

/* FBIP in-place reuse (spec section 4.3): re-stamp a just-decremented (rc-0) cell's
   header into the SAME shell, bypassing the free list and the bump pointer. The new
   tag re-uses the exact same arity-sized cell, so allocs/live/peak/cur_bytes/peak_bytes
   and the free list are ALL untouched -- a fired reuse pair nets 0 alloc / 0 free. Only
   the additive reused_inplace counter moves (arena observability for the microbench). */
WokObj* wok_alloc_at(WokHeap* h, uint32_t tag, uint32_t arity, WokObj* p) {
    assert(tag < 65536u && arity < 256u);
    /* The arity-match and rc==0 invariants are ALWAYS-ON (mirroring wok_free's
       premature-free guard): a mispaired reuse token (wrong-arity re-stamp, or a
       still-live shell) must abort LOUDLY in release builds too, not be stripped
       under NDEBUG. */
    if (WOK_UNLIKELY((uint32_t)p->arity != arity)) {
        fprintf(stderr, "wok_rc: wok_alloc_at arity mismatch (token arity != new node arity)\n");
        abort();
    }
    if (WOK_UNLIKELY(p->rc != 0u)) {
        fprintf(stderr, "wok_rc: wok_alloc_at on rc!=0 (drop_reuse must decrement the shell to 0 before re-stamp)\n");
        abort();
    }
    p->rc = 1u; p->tag = (uint16_t)tag; p->arity = (uint8_t)arity; p->scan = 0u;
    h->reused_inplace += 1u;
    return p;
}

void wok_free(WokHeap* h, WokObj* p) {
    if (WOK_UNLIKELY(p->rc != 0u)) { fprintf(stderr, "wok_rc: wok_free on rc!=0 (premature free)\n"); abort(); }
    uint32_t arity = (uint32_t)p->arity;
    h->frees += 1u; h->live -= 1;
    h->cur_bytes -= (uint64_t)wok_cell_bytes(arity);
#ifdef WOK_RC_POISON
    /* Poison is arena-only by design: it forces a reuse-after-free read to see garbage,
       since ASan cannot flag the arena recycling its own live memory. The WOK_RC_MALLOC
       backend needs no poison -- its real free() makes every UAF ASan-visible directly. */
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
uint64_t wok_stat_reused_inplace(const WokHeap* h) { return h->reused_inplace; }
uint64_t wok_stat_slabs(const WokHeap* h)          { return h->nslabs; }

#endif /* WOK_RC_MALLOC */

/* ---- shared across both backends ---------------------------------------------------- */
uint64_t wok_stat_peak_bytes(const WokHeap* h)     { return h->peak_bytes; }

/* ---- shared across both backends (unchanged from slice 1) --------------------------- */
void wok_dup(WokObj* p) { p->rc += 1u; }

uint64_t wok_dec(WokObj* p) {
    if (WOK_UNLIKELY(p->rc == 0u)) {
        fprintf(stderr, "wok_rc: wok_dec on rc==0 (double-free)\n");
        abort();
    }
    p->rc -= 1u;
    return (uint64_t)p->rc;
}

void wok_slot_set(WokObj* p, uint32_t i, uint64_t word) {
    assert(i < (uint32_t)p->arity);
    p->slots[i] = word;
}

uint64_t wok_slot_get(const WokObj* p, uint32_t i) {
    assert(i < (uint32_t)p->arity);
    return p->slots[i];
}

uint32_t wok_tag(const WokObj* p)   { return (uint32_t)p->tag; }
uint32_t wok_arity(const WokObj* p) { return (uint32_t)p->arity; }

uint64_t wok_stat_allocs(const WokHeap* h) { return h->allocs; }
uint64_t wok_stat_frees(const WokHeap* h)  { return h->frees; }
int64_t  wok_stat_live(const WokHeap* h)   { return h->live; }
int64_t  wok_stat_peak(const WokHeap* h)   { return h->peak; }
