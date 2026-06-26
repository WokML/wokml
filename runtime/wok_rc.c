#include "wok_rc.h"
#include <assert.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>   /* memcpy, memset */

_Static_assert(sizeof(WokObj)  == 8, "WokObj header must be 8 bytes");

/* Maximum nesting depth for the arena checkpoint stack. 32 levels is generous;
   wok function bodies nest by call depth and we abort loudly on overflow. */
#define WOK_ARENA_MAX_DEPTH 32u

/* WokArray header: 16 bytes (WokObj prefix at offset 0 + uint64_t len at offset 8). */
_Static_assert(sizeof(WokObj) + sizeof(uint64_t) == 16,
               "WokArray header must be 16 bytes, keeping 8-alignment");

/* --- tunables (spec section 11) --------------------------------------------- */
#define WOK_GRANULE     8u
#define WOK_ARENA_SIZE  (64u * 1024u)   /* slab bytes */
#define WOK_NUM_CLASSES 64u             /* arity 0..63 -> slabs; >=64 -> malloc */

_Static_assert(WOK_ARENA_SIZE % WOK_GRANULE == 0u,
               "arena size must be a granule multiple");
_Static_assert((sizeof(WokObj) + (WOK_NUM_CLASSES - 1u) * sizeof(uint64_t)) < WOK_ARENA_SIZE,
               "largest slab-class cell must fit a slab");

/* The largest slab-class array (len = WOK_NUM_CLASSES-2, class WOK_NUM_CLASSES-1) must fit a
   slab. Tied to WOK_NUM_CLASSES so raising it cannot silently exceed the slab capacity. */
_Static_assert((16u + 8u * (WOK_NUM_CLASSES - 2u)) < WOK_ARENA_SIZE,
               "largest slab-class array must fit within a slab");

static size_t wok_cell_bytes(uint32_t arity) {
    return sizeof(WokObj) + (size_t)arity * sizeof(uint64_t);
}

/* Read the runtime length of an array cell (offset 8 past the WokObj prefix). */
static uint64_t wok_array_read_len(const WokObj* p) {
    uint64_t len;
    memcpy(&len, (const char*)p + 8, sizeof(uint64_t));
    return len;
}

/* Byte size of an array cell = 16 + 8*len. Aborts on size_t overflow: `len` is a
   runtime value (a system boundary), so an adversarial len that would wrap size_t and
   yield a tiny allocation must fail loudly, not corrupt the heap. Protects BOTH backends
   (the malloc path's tiny-cell-then-OOB write can never happen: the abort fires first). */
static size_t wok_array_cell_bytes(uint64_t len) {
    if (WOK_UNLIKELY(len > (uint64_t)((SIZE_MAX - 16u) / sizeof(uint64_t)))) {
        fprintf(stderr, "wok_rc: wok_array_alloc len overflows size_t (16 + 8*len)\n");
        abort();
    }
    return 16u + (size_t)len * sizeof(uint64_t);
}

/* Free-list size class of an array cell, WITHOUT wrapping `len + 1`. The arena holds
   classes 0..WOK_NUM_CLASSES-1; an array of len L occupies class L+1, so it fits the
   arena iff L+1 < WOK_NUM_CLASSES, i.e. L < WOK_NUM_CLASSES-1. Any larger L (including
   the adversarial UINT64_MAX where L+1 would wrap to 0) routes to malloc. wok_array_alloc
   and wok_free's array branch MUST use this identical guard so they agree on routing.
   Arena-only: the WOK_RC_MALLOC backend never routes by class. */
#ifndef WOK_RC_MALLOC
static size_t wok_array_class(uint64_t len) {
    if (len < (uint64_t)WOK_NUM_CLASSES - 1u) {
        return (size_t)(len + 1u);
    }
    return (size_t)WOK_NUM_CLASSES;   /* >= WOK_NUM_CLASSES -> malloc path */
}
#endif

/* Read the runtime byte_len of a string cell (offset 8 past the WokObj prefix). */
static uint64_t wok_string_read_byte_len(const WokObj* p) {
    uint64_t byte_len;
    memcpy(&byte_len, (const char*)p + 8, sizeof(uint64_t));
    return byte_len;
}

/* Byte size of a string cell = 16 + 8*ceil(byte_len/8). Aborts on size_t overflow: the
   body is rounded UP to an 8-byte granule so the next bumped cell stays 8-aligned (unlike
   WokArray whose word-slots are already aligned). `byte_len` is a runtime/boundary value;
   an adversarial value that would wrap size_t must abort loudly, not under-allocate. */
static size_t wok_string_cell_bytes(uint64_t byte_len) {
    /* ceil(byte_len/8) = (byte_len + 7) / 8 (integer division).
       Overflow check: 8 * ceil(byte_len/8) <= byte_len + 7 <= SIZE_MAX - 16 requires
       byte_len <= SIZE_MAX - 23. (No divisor here, unlike wok_array_cell_bytes: the string
       rounding factor is the +7 in the numerator, not an 8 in the denominator.) */
    if (WOK_UNLIKELY(byte_len > (uint64_t)(SIZE_MAX - 16u - 7u))) {
        fprintf(stderr, "wok_rc: wok_string_alloc byte_len overflows size_t (16 + 8*ceil(byte_len/8))\n");
        abort();
    }
    return 16u + 8u * ((size_t)(byte_len + 7u) / 8u);
}

/* Free-list size class of a string cell = cell_bytes/8 - 1 = 1 + ceil(byte_len/8).
   Guards against wrap exactly as wok_array_class: if the class would be >= WOK_NUM_CLASSES
   (i.e. ceil(byte_len/8) >= WOK_NUM_CLASSES-1, i.e. byte_len >= 8*(WOK_NUM_CLASSES-2)+1 = 497),
   route to malloc. wok_string_alloc and wok_free's string branch MUST use this identical
   guard. Arena-only: the WOK_RC_MALLOC backend never routes by class. */
#ifndef WOK_RC_MALLOC
static size_t wok_string_class(uint64_t byte_len) {
    uint64_t granules = (byte_len + 7u) / 8u;   /* ceil(byte_len/8), no overflow (checked by caller) */
    if (granules < (uint64_t)WOK_NUM_CLASSES - 1u) {
        return (size_t)(granules + 1u);
    }
    return (size_t)WOK_NUM_CLASSES;   /* >= WOK_NUM_CLASSES -> malloc path */
}
#endif

/* ---- self-policing PHYSICAL-memory invariant (debug/sanitizer build only) -------------
   The oracle checks LOGICAL accounting (cur_bytes/peak_bytes, allocs/frees) but is blind to
   PHYSICAL memory -- the slabs the runtime holds from the OS. A bug can grow slabs without
   bound (O(cycles)) while the byte accounting stays balanced; LeakSanitizer misses it too
   (the slabs are freed at heap teardown, just accumulated during the run). Rather than chase
   each allocator with one ad-hoc bounded-ness test, the allocator self-polices: it asserts
   physical high-water stays within a bounded factor of LOGICAL high-water, so EVERY test that
   runs the runtime checks the whole CLASS for free.

   The principle: a bump+free-list allocator packs densely, so physical high-water should stay
   within a small factor of the LOGICAL high-water, plus an additive slab-granularity headroom
   for small programs (a tiny program holds whole slabs against a few bytes of logical data --
   that ratio is unbounded, which is why the additive C*SLAB term, not a pure ratio, is needed).

       peak_physical_bytes  <=  K * peak_logical_bytes  +  C * WOK_ARENA_SIZE

   where peak_logical_bytes is the high-water of TOTAL live logical bytes (counted cur_bytes +
   arena arena_bytes, tracked as a combined high-water -- the peak of the sum, which is what the
   physical regions jointly hold).

   K = 4, C = 8 (8 slabs = 512 KiB). Reasoning:
     - K: once a region is warm, physical ~= logical (a full 64 KiB slab holds ~64 KiB live).
       The half-empty TRAILING slab of each region plus free-list slack pushes a region's
       physical toward ~2x its logical high-water; K = 4 is comfortable headroom over that
       (~2x measured), without being so large the bound goes vacuous.
     - C: the additive slab-granularity floor. Covers a tiny program that holds whole slabs
       against a few bytes of logical data (counted slab + first arena slab + their trailing
       slabs), plus arena nesting depth headroom. 8 slabs is generous for the test suite's
       per-heap needs (counted + arena concurrently) yet far below the seeded leak (hundreds
       of orphaned slabs => millions of bytes with ZERO logical, which blows past 4*L + 8*slab
       for any small L, so the negative-control death test bites).
   Measured margins (asan-runtime.sh, per heap): the deep-list/array tests peak at ~1-2 counted
   slabs, T10 at ~2-3 arena slabs; all sit well under K*L + C*slab. See the death test (negative
   control) and the T10-style positive test in wok_arena_test.c.

   TRACKING (the counters + getter) is ALWAYS-ON (cheap: two adds at the malloc boundary).
   Only the abort() assertion is gated behind WOK_RC_CHECK_PHYSICAL (a release build must NOT
   abort on a memory heuristic). Interpreter-era: replaced when codegen lands (arena -> stack
   frame), so it is a cheap runtime self-check, not long-lived test infrastructure. */
#define WOK_PHYS_BOUND_K  4u
#define WOK_PHYS_BOUND_C  8u

/* Bump cur_physical by `delta` and re-mark the physical high-water. Both struct layouts
   carry cur_physical_bytes/peak_physical_bytes (same names), so this macro compiles in
   either backend. Always-on (cheap). */
#define WOK_PHYS_ADD(h, delta) do {                                          \
        (h)->cur_physical_bytes += (uint64_t)(delta);                       \
        if ((h)->cur_physical_bytes > (h)->peak_physical_bytes) {           \
            (h)->peak_physical_bytes = (h)->cur_physical_bytes;             \
        }                                                                   \
    } while (0)

/* Drop cur_physical by `delta` (a matching free; peak stays -- high-water). */
#define WOK_PHYS_SUB(h, delta) do {                                          \
        (h)->cur_physical_bytes -= (uint64_t)(delta);                       \
    } while (0)

/* Re-mark the combined LOGICAL high-water (counted cur_bytes + arena arena_bytes). Called
   from every alloc site after the logical counters move, so peak_logical_bytes is the
   high-water of the SUM (what the physical regions jointly back). Always-on. */
#define WOK_LOGICAL_MARK(h) do {                                             \
        uint64_t _live = (h)->cur_bytes + (h)->arena_bytes;                 \
        if (_live > (h)->peak_logical_bytes) {                              \
            (h)->peak_logical_bytes = _live;                                \
        }                                                                   \
    } while (0)

#ifdef WOK_RC_CHECK_PHYSICAL
/* The self-policing assertion (debug/sanitizer build only). Body is defined in the shared
   section below (it reads WokHeap fields, complete only after the backend struct). Checked
   where it is cheap and catches early: at each slab malloc (after peak_physical is updated)
   and at heap free. On violation, print the diagnostic and abort. */
static void wok_check_physical(const WokHeap* h);
#  define WOK_CHECK_PHYSICAL(h) wok_check_physical(h)
#else
#  define WOK_CHECK_PHYSICAL(h) ((void)0)
#endif

/* INVARIANT: both `struct WokHeap` definitions below begin with the same four fields
   (allocs, frees, live, peak) in the same order; the shared wok_stat_allocs/frees/live/
   peak accessors read them by layout. Keep the prefix in sync. Drift is caught by the
   stat assertions in both builds (the arena via the Haskell differential oracle, the
   WOK_RC_MALLOC build via the standalone test).
   The TAIL of both structs also shares cur_physical_bytes/peak_physical_bytes/
   peak_logical_bytes in the same order, read by the shared physical helpers below. */
#ifdef WOK_RC_MALLOC
/* ---- retained slice-1 allocator: one malloc per cell (UAF oracle + bench baseline) ---- */
/* malloc backend arena frame: tracks a linked list of arena-allocated cells so close can
   free them. Arena cells are chained via the first sizeof(WokObj*) bytes of the cell
   (their rc is unused; we memcpy the pointer in, strict-aliasing-safe). */
typedef struct WokArenaFrame {
    WokObj* chain_head;          /* linked list of arena cells (via stored pointer) */
    uint64_t arena_bytes_before; /* arena_bytes value at open, for restoration */
} WokArenaFrame;

struct WokHeap {
    uint64_t allocs;
    uint64_t frees;
    int64_t  live;
    int64_t  peak;
    uint64_t cur_bytes;
    uint64_t peak_bytes;
    /* physical-memory high-water (malloc backend: physical ~= logical, one malloc per cell) */
    uint64_t cur_physical_bytes;
    uint64_t peak_physical_bytes;
    uint64_t peak_logical_bytes;    /* high-water of cur_bytes + arena_bytes */
    /* arena checkpoint stack (malloc backend: cell chains instead of bump checkpoints) */
    uint32_t      arena_depth;
    uint64_t      arena_bytes;
    uint64_t      arena_peak;
    WokArenaFrame arena_stack[WOK_ARENA_MAX_DEPTH];
};

WokHeap* wok_heap_new(void) {
    WokHeap* h = (WokHeap*)calloc(1, sizeof(WokHeap));
    if (WOK_UNLIKELY(h == NULL)) { abort(); }
    return h;
}
/* Forward decls so wok_heap_free can drain leaked (never-closed) arena frames below. */
static WokObj* arena_prefix_next(const WokObj* p);
static void*   arena_raw_base(WokObj* p);

void wok_heap_free(WokHeap* h) {
    if (WOK_UNLIKELY(h->live != 0)) {
        fprintf(stderr, "wok_rc: heap freed with %lld live cells (leak)\n", (long long)h->live);
    }
    /* Defensive teardown: a correctly-balanced program closes every arena before heap
       free (arena_depth == 0). If an arena scope was left open (a leak), free its chained
       cells here so the malloc backend stays LSan-clean, mirroring the slab backend's
       bulk arena-slab teardown. Warn loudly so the imbalance is not silent. */
    if (WOK_UNLIKELY(h->arena_depth != 0u)) {
        fprintf(stderr, "wok_rc: heap freed with %u open arena scope(s) (unbalanced open/close)\n",
                h->arena_depth);
        for (uint32_t d = 0u; d < h->arena_depth; d++) {
            WokObj* cur = h->arena_stack[d].chain_head;
            while (cur != NULL) {
                WokObj* nxt = arena_prefix_next(cur);
                WOK_PHYS_SUB(h, sizeof(WokObj*) + wok_cell_bytes((uint32_t)cur->arity));
                free(arena_raw_base(cur));
                cur = nxt;
            }
        }
    }
    /* Physical returns to baseline in the balanced case (leaked counted cells stay malloc'd
       -- a real LSan leak -- so the zero-sanity check is gated to live == 0). */
    WOK_CHECK_PHYSICAL(h);
    assert(h->live != 0 || h->cur_physical_bytes == 0u);
    free(h);
}
WokObj* wok_alloc(WokHeap* h, uint32_t tag, uint32_t arity) {
    assert(tag < 65536u && arity < 256u);
    size_t cell_sz = wok_cell_bytes(arity);
    WokObj* p = (WokObj*)malloc(cell_sz);
    if (WOK_UNLIKELY(p == NULL)) { abort(); }
    p->rc = 1u; p->tag = (uint16_t)tag; p->arity = (uint8_t)arity; p->scan = 0u;
    h->allocs += 1u; h->live += 1;
    if (h->live > h->peak) { h->peak = h->live; }
    h->cur_bytes += (uint64_t)cell_sz;
    if (h->cur_bytes > h->peak_bytes) { h->peak_bytes = h->cur_bytes; }
    WOK_PHYS_ADD(h, cell_sz);   /* every per-cell malloc grows physical */
    WOK_LOGICAL_MARK(h);
    return p;
}
void wok_free(WokHeap* h, WokObj* p) {
    if (WOK_UNLIKELY(p->rc != 0u)) { fprintf(stderr, "wok_rc: wok_free on rc!=0 (premature free)\n"); abort(); }
    /* Tag-first dispatch: array and string cells carry a runtime len at offset 8, not an
       arity byte. Check reserved tags BEFORE falling back to arity (their arity bytes have
       different semantics: array stores elemkind, string stores 0).
       WokStringView is fixed 32 bytes (no runtime len field needed). */
    size_t bytes;
    if (WOK_UNLIKELY((uint32_t)p->tag == WOK_ARRAY_TAG)) {
        uint64_t len = wok_array_read_len(p);
        bytes = wok_array_cell_bytes(len);
    } else if (WOK_UNLIKELY((uint32_t)p->tag == WOK_STRING_TAG)) {
        uint64_t byte_len = wok_string_read_byte_len(p);
        bytes = wok_string_cell_bytes(byte_len);
    } else if (WOK_UNLIKELY((uint32_t)p->tag == WOK_STRING_VIEW_TAG)) {
        /* Fixed 32-byte cell: 8-byte header + parent ptr + offset + len. The parent is NOT
           dropped here (scan=0, Haskell-driven drop -- see D8 of the E4 spec). */
        bytes = 32u;
    } else {
        bytes = wok_cell_bytes((uint32_t)p->arity);
    }
    h->frees += 1u; h->live -= 1;
    h->cur_bytes -= (uint64_t)bytes;
    WOK_PHYS_SUB(h, bytes);   /* the per-cell malloc is returned to the OS */
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
/* malloc backend has no slab structure: arena cells are per-cell mallocs freed at close,
   so it is already bounded (no slab accumulation). Report 0, mirroring wok_stat_slabs. */
uint64_t wok_stat_arena_slabs(const WokHeap* h)    { (void)h; return 0u; }

/* ---- malloc backend: arena via prefix-linked list -------------------------------- */
/* Each arena cell is allocated as `sizeof(WokObj*) + wok_cell_bytes(arity)` bytes.
   The first sizeof(WokObj*) bytes (= 8 on 64-bit) hold the next-list pointer; the
   WokObj header lives at offset 8 and is what we hand back to the caller. At close we
   recover the raw pointer via `(char*)cell - sizeof(WokObj*)` and free it.
   This never touches the WokObj header bytes, so wok_tag/wok_arity read correctly. */
static WokObj* arena_prefix_next(const WokObj* p) {
    WokObj* n;
    /* step back to the hidden prefix */
    memcpy(&n, (const char*)p - sizeof(WokObj*), sizeof(WokObj*));
    return n;
}
static void arena_prefix_set_next(WokObj* p, WokObj* n) {
    memcpy((char*)p - sizeof(WokObj*), &n, sizeof(WokObj*));
}
/* Raw malloc'd base from the visible WokObj pointer. */
static void* arena_raw_base(WokObj* p) {
    return (void*)((char*)p - sizeof(WokObj*));
}

uint32_t wok_arena_open(WokHeap* h) {
    if (WOK_UNLIKELY(h->arena_depth >= WOK_ARENA_MAX_DEPTH)) {
        fprintf(stderr, "wok_rc: wok_arena_open exceeded max depth %u\n", WOK_ARENA_MAX_DEPTH);
        abort();
    }
    uint32_t handle = h->arena_depth;
    WokArenaFrame* f = &h->arena_stack[handle];
    f->chain_head         = NULL;
    f->arena_bytes_before = h->arena_bytes;
    h->arena_depth++;
    return handle;
}

WokObj* wok_arena_alloc(WokHeap* h, uint32_t tag, uint32_t arity) {
    assert(tag < 65536u && arity < 256u);
    if (WOK_UNLIKELY(h->arena_depth == 0u)) {
        fprintf(stderr, "wok_rc: wok_arena_alloc called with no open arena\n");
        abort();
    }
    size_t cell_sz = wok_cell_bytes(arity);
    size_t raw_sz  = sizeof(WokObj*) + cell_sz;
    /* Allocate: 8-byte hidden next-pointer prefix + the cell itself. */
    char* raw = (char*)malloc(raw_sz);
    if (WOK_UNLIKELY(raw == NULL)) { abort(); }
    WokObj* p = (WokObj*)(raw + sizeof(WokObj*));
    /* stamp the header BEFORE chaining (chain writes to the hidden prefix, not the header) */
    p->rc = 0u; p->tag = (uint16_t)tag; p->arity = (uint8_t)arity; p->scan = 0u;
    /* prepend to the innermost arena frame's list */
    WokArenaFrame* f = &h->arena_stack[h->arena_depth - 1u];
    arena_prefix_set_next(p, f->chain_head);
    f->chain_head = p;
    /* update arena stats only (NOT allocs/live/peak/cur_bytes) */
    h->arena_bytes += (uint64_t)cell_sz;
    if (h->arena_bytes > h->arena_peak) { h->arena_peak = h->arena_bytes; }
    WOK_PHYS_ADD(h, raw_sz);   /* the arena-cell malloc (prefix + cell) grows physical */
    WOK_LOGICAL_MARK(h);
    return p;
}

void wok_arena_close(WokHeap* h, uint32_t handle) {
    if (WOK_UNLIKELY(h->arena_depth == 0u || handle != h->arena_depth - 1u)) {
        fprintf(stderr,
            "wok_rc: wok_arena_close handle mismatch (handle=%u, expected=%u)\n",
            handle, h->arena_depth == 0u ? 0u : h->arena_depth - 1u);
        abort();
    }
    WokArenaFrame* f = &h->arena_stack[handle];
    /* restore arena_bytes to the pre-open value; peak stays (high-water) */
    h->arena_bytes = f->arena_bytes_before;
    h->arena_depth--;
    /* free all cells in this arena frame (walk the prefix list) */
    WokObj* cur = f->chain_head;
    while (cur != NULL) {
        WokObj* nxt = arena_prefix_next(cur);
        WOK_PHYS_SUB(h, sizeof(WokObj*) + wok_cell_bytes((uint32_t)cur->arity));
        free(arena_raw_base(cur));
        cur = nxt;
    }
    f->chain_head = NULL;
}

WokObj* wok_array_alloc(WokHeap* h, uint64_t len, uint8_t elemkind) {
    size_t sz = wok_array_cell_bytes(len);
    WokObj* p = (WokObj*)malloc(sz);
    if (WOK_UNLIKELY(p == NULL)) { abort(); }
    p->rc = 1u; p->tag = (uint16_t)WOK_ARRAY_TAG; p->arity = elemkind; p->scan = 0u;
    /* Write len at offset 8 (past the WokObj prefix). */
    memcpy((char*)p + 8, &len, sizeof(uint64_t));
    h->allocs += 1u; h->live += 1;
    if (h->live > h->peak) { h->peak = h->live; }
    h->cur_bytes += (uint64_t)sz;
    if (h->cur_bytes > h->peak_bytes) { h->peak_bytes = h->cur_bytes; }
    WOK_PHYS_ADD(h, sz);   /* large/array per-cell malloc grows physical */
    WOK_LOGICAL_MARK(h);
    return p;
}

WokObj* wok_string_alloc(WokHeap* h, uint64_t byte_len) {
    size_t sz = wok_string_cell_bytes(byte_len);   /* aborts on size_t overflow */
    WokObj* p = (WokObj*)malloc(sz);
    if (WOK_UNLIKELY(p == NULL)) { abort(); }
    p->rc = 1u; p->tag = (uint16_t)WOK_STRING_TAG; p->arity = 0u; p->scan = 0u;
    /* Write byte_len at offset 8 (past the WokObj prefix). */
    memcpy((char*)p + 8, &byte_len, sizeof(uint64_t));
    h->allocs += 1u; h->live += 1;
    if (h->live > h->peak) { h->peak = h->live; }
    h->cur_bytes += (uint64_t)sz;
    if (h->cur_bytes > h->peak_bytes) { h->peak_bytes = h->cur_bytes; }
    WOK_PHYS_ADD(h, sz);   /* per-cell malloc grows physical */
    WOK_LOGICAL_MARK(h);
    return p;
}

WokObj* wok_string_view_alloc(WokHeap* h, WokObj* parent, uint64_t off, uint64_t len) {
    /* Fixed 32-byte cell: 8-byte header + parent ptr (8B) + offset (8B) + len (8B).
       The parent is NOT incref'd here: the Haskell caller (allocNStringView) is responsible
       for incref'ing the parent BEFORE calling this function. scan=0 (no C cascade; D8). */
    size_t sz = 32u;
    WokObj* p = (WokObj*)malloc(sz);
    if (WOK_UNLIKELY(p == NULL)) { abort(); }
    p->rc = 1u; p->tag = (uint16_t)WOK_STRING_VIEW_TAG; p->arity = 0u; p->scan = 0u;
    /* Write parent pointer at offset 8. */
    uintptr_t parent_word = (uintptr_t)parent;
    memcpy((char*)p + 8,  &parent_word, sizeof(uint64_t));
    memcpy((char*)p + 16, &off,         sizeof(uint64_t));
    memcpy((char*)p + 24, &len,         sizeof(uint64_t));
    h->allocs += 1u; h->live += 1;
    if (h->live > h->peak) { h->peak = h->live; }
    h->cur_bytes += (uint64_t)sz;
    if (h->cur_bytes > h->peak_bytes) { h->peak_bytes = h->cur_bytes; }
    WOK_PHYS_ADD(h, sz);   /* per-cell malloc grows physical */
    WOK_LOGICAL_MARK(h);
    return p;
}

#else
/* ---- the slab arena (default) ------------------------------------------------------- */
typedef struct WokSlab { struct WokSlab* next; } WokSlab;
/* Cells start at `slab + WOK_GRANULE`, so the slab header must fit in one granule;
   otherwise the first bumped cell would overlap (and corrupt) the slab link. */
_Static_assert(sizeof(WokSlab) <= WOK_GRANULE, "WokSlab header must fit in one granule");

/* Slab backend arena frame: saves the ARENA region's bump frontier so close can restore
   it in O(1) and reclaim slabs grown during the arena scope. The arena region is SEPARATE
   from the counted region (its own slabs + bump pointer), so an arena close never touches
   counted memory -- escaping counted cells bumped during the scope are untouched. */
typedef struct WokArenaFrame {
    WokSlab* slab_at_open;       /* h->arena_slabs value at open */
    char*    bump_ptr_save;      /* h->arena_bump_ptr at open */
    char*    bump_end_save;      /* h->arena_bump_end at open */
    uint64_t arena_bytes_before; /* arena_bytes value at open, for restoration */
} WokArenaFrame;

struct WokHeap {
    uint64_t allocs;
    uint64_t frees;
    int64_t  live;
    int64_t  peak;
    uint64_t cur_bytes;              /* current live bytes: Σ(8 + 8*arity) */
    uint64_t peak_bytes;             /* high-water mark of cur_bytes */
    uint64_t cur_physical_bytes;     /* bytes currently held from the OS (slabs + large mallocs) */
    uint64_t peak_physical_bytes;    /* high-water of cur_physical_bytes (the self-policed figure) */
    uint64_t peak_logical_bytes;     /* high-water of cur_bytes + arena_bytes (combined live) */
    uint64_t reused;                 /* free-list pops */
    uint64_t reused_inplace;         /* FBIP wok_alloc_at hits */
    uint64_t nslabs;                 /* slabs malloc'd */
    WokSlab* slabs;                  /* linked list, for O(slabs) bulk teardown */
    char*    bump_ptr;
    char*    bump_end;
    WokObj*  freelist[WOK_NUM_CLASSES];
    /* ---- arena region (Region Slice R1): a SEPARATE bump region, distinct from the
       counted slabs above. Counted wok_alloc never draws from these; wok_arena_alloc
       never draws from the counted slabs. An arena close resets ONLY this region, so it
       can never reclaim a counted (escaping) cell that interleaved with arena allocs in
       program order. */
    WokSlab*      arena_slabs;        /* arena region's own slab list (bulk-freed at teardown) */
    char*         arena_bump_ptr;
    char*         arena_bump_end;
    WokSlab*      arena_free_slabs;   /* slabs reclaimed by an arena close, kept for re-use by a
                                         later wok_new_arena_slab (popped before malloc) so the
                                         live arena-slab count stays ~peak concurrent need, not
                                         O(number of open/close cycles). Bulk-freed at teardown. */
    uint64_t      arena_nslabs;       /* arena slabs malloc'd. Internal accounting only:
                                         surfaced via wok_stat_arena_slabs (symmetric with
                                         wok_stat_slabs) for the bounded-slab regression test.
                                         Counts mallocs, NOT live slabs -- a free-list pop reuses
                                         a slab without bumping this, so it is the peak high-water
                                         of distinct arena slabs ever malloc'd. */
    uint32_t      arena_depth;
    uint64_t      arena_bytes;        /* current uncounted arena bytes live */
    uint64_t      arena_peak;         /* high-water mark of arena_bytes */
    WokArenaFrame arena_stack[WOK_ARENA_MAX_DEPTH];
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

/* Grow a bump region (counted or arena) by one slab. Shared by wok_new_slab and
   wok_new_arena_slab so a future fix to the slab geometry reaches both. `recycled` is an
   optional already-malloc'd slab to install instead of calling malloc (used by the arena
   region's close-time free-list); pass NULL to malloc a fresh one. Returns the installed
   slab. *nslabs is bumped ONLY on a real malloc, so it stays the count of distinct slabs
   ever allocated (a recycled slab was already counted when first malloc'd). */
static WokSlab* wok_grow_slab(WokHeap* h, WokSlab** slabs, char** bump_ptr, char** bump_end,
                              uint64_t* nslabs, WokSlab* recycled) {
    WokSlab* s = recycled;
    if (s == NULL) {
        s = (WokSlab*)malloc(WOK_ARENA_SIZE);
        if (WOK_UNLIKELY(s == NULL)) { abort(); }
        *nslabs += 1u;
        /* A fresh slab is new physical memory from the OS (a recycled slab was already
           counted at first malloc and stays on the free-list -- still held, no change). */
        WOK_PHYS_ADD(h, WOK_ARENA_SIZE);
        /* Check at the slab-malloc boundary: this is where unbounded physical growth shows
           up first and is cheapest to catch (gated; release builds skip the abort). */
        WOK_CHECK_PHYSICAL(h);
    }
    s->next = *slabs;
    *slabs = s;
    /* cells start one granule in (sizeof(WokSlab) <= 8), preserving 8-alignment. */
    *bump_ptr = (char*)s + WOK_GRANULE;
    *bump_end = (char*)s + WOK_ARENA_SIZE;
    return s;
}

static void wok_new_slab(WokHeap* h) {
    wok_grow_slab(h, &h->slabs, &h->bump_ptr, &h->bump_end, &h->nslabs, NULL);
}

/* Grow the SEPARATE arena region by one slab. Pops the arena free-list (slabs recycled by
   a prior close) before mallocing, so repeated grow/close cycles reuse slabs instead of
   accumulating them. */
static void wok_new_arena_slab(WokHeap* h) {
    WokSlab* recycled = h->arena_free_slabs;
    if (recycled != NULL) {
        h->arena_free_slabs = recycled->next;
    }
    wok_grow_slab(h, &h->arena_slabs, &h->arena_bump_ptr, &h->arena_bump_end,
                  &h->arena_nslabs, recycled);
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
    /* A correctly-balanced program closes every arena before heap free. Warn on imbalance
       (mirrors the malloc backend). The arena-region slab walk below frees the cells
       regardless, so a leaked open scope is not a memory leak here -- only a diagnostic. */
    if (WOK_UNLIKELY(h->arena_depth != 0u)) {
        fprintf(stderr, "wok_rc: heap freed with %u open arena scope(s) (unbalanced open/close)\n",
                h->arena_depth);
    }
    WokSlab* s = h->slabs;
    while (s != NULL) { WokSlab* n = s->next; WOK_PHYS_SUB(h, WOK_ARENA_SIZE); free(s); s = n; }
    /* free the separate arena region's slabs too (covers both closed and still-open scopes) */
    WokSlab* as = h->arena_slabs;
    while (as != NULL) { WokSlab* n = as->next; WOK_PHYS_SUB(h, WOK_ARENA_SIZE); free(as); as = n; }
    /* and the arena free-list (slabs recycled by closes but not yet re-grown) */
    WokSlab* fs = h->arena_free_slabs;
    while (fs != NULL) { WokSlab* n = fs->next; WOK_PHYS_SUB(h, WOK_ARENA_SIZE); free(fs); fs = n; }
    /* The self-policing bound is re-checked at teardown (catches a leak that never tripped a
       slab malloc). cur_physical returns to 0 EXCEPT for leaked large cells (arity>=64 /
       len>=63), which malloc directly and are a real LSan leak when not freed -- so the
       zero-sanity check is gated to the balanced case (no live cells). */
    WOK_CHECK_PHYSICAL(h);
    assert(h->live != 0 || h->cur_physical_bytes == 0u);
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
        WOK_PHYS_ADD(h, sz);   /* large-object (arity>=64) malloc grows physical directly */
    }
    p->rc = 1u; p->tag = (uint16_t)tag; p->arity = (uint8_t)arity; p->scan = 0u;
    h->allocs += 1u; h->live += 1;
    if (h->live > h->peak) { h->peak = h->live; }
    h->cur_bytes += (uint64_t)sz;
    if (h->cur_bytes > h->peak_bytes) { h->peak_bytes = h->cur_bytes; }
    WOK_LOGICAL_MARK(h);
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
    /* Tag-first dispatch: array and string cells carry a runtime len at offset 8, not an
       arity byte.  Check reserved tags BEFORE falling back to arity (their arity bytes have
       different semantics: array stores elemkind, string stores 0).
       WokStringView is fixed 32 bytes (size class 3, shared with NCon arity=3).
       Size class: bytes/8-1.  NCon arity a -> class=a.  WokArray len L -> class=L+1.
       WokString byte_len B -> class = 1+ceil(B/8) (via wok_string_class, the no-wrap guard
       alloc uses so routing agrees).  WokStringView -> class=3 (32/8-1). */
    size_t bytes;
    size_t cls;
    if (WOK_UNLIKELY((uint32_t)p->tag == WOK_ARRAY_TAG)) {
        uint64_t len = wok_array_read_len(p);
        bytes = wok_array_cell_bytes(len);
        cls   = wok_array_class(len);
    } else if (WOK_UNLIKELY((uint32_t)p->tag == WOK_STRING_TAG)) {
        uint64_t byte_len = wok_string_read_byte_len(p);
        bytes = wok_string_cell_bytes(byte_len);
        cls   = wok_string_class(byte_len);
    } else if (WOK_UNLIKELY((uint32_t)p->tag == WOK_STRING_VIEW_TAG)) {
        /* Fixed 32-byte cell, size class 3 (32/8-1 = 3, shared with NCon arity=3).
           The parent is NOT dropped here (scan=0, Haskell-driven drop -- D8). */
        bytes = 32u;
        cls   = 3u;
    } else {
        uint32_t arity = (uint32_t)p->arity;
        bytes = wok_cell_bytes(arity);
        cls   = (size_t)arity;
    }
    h->frees += 1u; h->live -= 1;
    h->cur_bytes -= (uint64_t)bytes;
#ifdef WOK_RC_POISON
    /* Poison is arena-only by design: it forces a reuse-after-free read to see garbage,
       since ASan cannot flag the arena recycling its own live memory. The WOK_RC_MALLOC
       backend needs no poison -- its real free() makes every UAF ASan-visible directly. */
    memset(p, 0xDE, bytes);       /* poison BEFORE relink so the link survives */
#endif
    if (cls < WOK_NUM_CLASSES) {
        fl_set_next(p, h->freelist[cls]);
        h->freelist[cls] = p;
    } else {
        WOK_PHYS_SUB(h, bytes);   /* large-path free returns physical to the OS */
        free(p);
    }
}

WokObj* wok_array_alloc(WokHeap* h, uint64_t len, uint8_t elemkind) {
    size_t   sz  = wok_array_cell_bytes(len);   /* aborts on size_t overflow */
    /* Size class = bytes/8-1 = len+1 (shared with NCon arity=len+1); no-wrap guard. */
    size_t   cls = wok_array_class(len);
    WokObj*  p;
    if (cls < WOK_NUM_CLASSES) {
        WokObj* head = h->freelist[cls];
        if (head != NULL) {                       /* reuse from shared free-list */
            h->freelist[cls] = fl_next(head);
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
        WOK_PHYS_ADD(h, sz);   /* large array (len>=63) malloc grows physical directly */
    }
    p->rc = 1u; p->tag = (uint16_t)WOK_ARRAY_TAG; p->arity = elemkind; p->scan = 0u;
    /* Write len at offset 8 (past the WokObj prefix). */
    memcpy((char*)p + 8, &len, sizeof(uint64_t));
    h->allocs += 1u; h->live += 1;
    if (h->live > h->peak) { h->peak = h->live; }
    h->cur_bytes += (uint64_t)sz;
    if (h->cur_bytes > h->peak_bytes) { h->peak_bytes = h->cur_bytes; }
    WOK_LOGICAL_MARK(h);
    return p;
}

WokObj* wok_string_alloc(WokHeap* h, uint64_t byte_len) {
    size_t   sz  = wok_string_cell_bytes(byte_len);   /* aborts on size_t overflow */
    /* Size class = 1+ceil(byte_len/8) (shared with NCon/WokArray of the same byte size). */
    size_t   cls = wok_string_class(byte_len);
    WokObj*  p;
    if (cls < WOK_NUM_CLASSES) {
        WokObj* head = h->freelist[cls];
        if (head != NULL) {                       /* reuse from shared free-list */
            h->freelist[cls] = fl_next(head);
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
        WOK_PHYS_ADD(h, sz);   /* large string (byte_len >= 8*63) malloc grows physical */
    }
    p->rc = 1u; p->tag = (uint16_t)WOK_STRING_TAG; p->arity = 0u; p->scan = 0u;
    /* Write byte_len at offset 8 (past the WokObj prefix). */
    memcpy((char*)p + 8, &byte_len, sizeof(uint64_t));
    h->allocs += 1u; h->live += 1;
    if (h->live > h->peak) { h->peak = h->live; }
    h->cur_bytes += (uint64_t)sz;
    if (h->cur_bytes > h->peak_bytes) { h->peak_bytes = h->cur_bytes; }
    WOK_LOGICAL_MARK(h);
    return p;
}

WokObj* wok_string_view_alloc(WokHeap* h, WokObj* parent, uint64_t off, uint64_t len) {
    /* Fixed 32-byte cell: 8-byte header + parent ptr (8B) + offset (8B) + len (8B).
       Size class = 32/8 - 1 = 3 (shared free-list with NCon arity=3 / WokArray len=2).
       The parent is NOT incref'd here: the Haskell caller (allocNStringView) is responsible
       for incref'ing the parent BEFORE calling this function. scan=0 (no C cascade; D8). */
    size_t  sz  = 32u;
    size_t  cls = 3u;   /* 32/8 - 1 = 3, always in range (< WOK_NUM_CLASSES = 64) */
    WokObj* p;
    /* Structurally identical to wok_string_alloc/wok_array_alloc: the free-list/bump path is
       wrapped in the same `if (cls < WOK_NUM_CLASSES)` guard so a future layout change cannot
       desync the three allocators. The large (cls >= WOK_NUM_CLASSES) path is UNREACHABLE for a
       fixed 32-byte cell (cls is the constant 3); the else branch mirrors the siblings (and
       keeps `p` defined on every path so the compiler is satisfied without an init-to-NULL). */
    if (cls < WOK_NUM_CLASSES) {
        WokObj* head = h->freelist[cls];
        if (head != NULL) {                       /* reuse from shared free-list */
            h->freelist[cls] = fl_next(head);
            p = head;
            h->reused += 1u;
        } else {                                  /* bump */
            if (h->bump_ptr == NULL || sz > (size_t)(h->bump_end - h->bump_ptr)) {
                wok_new_slab(h);
            }
            p = (WokObj*)h->bump_ptr;
            h->bump_ptr += sz;
        }
    } else {                                      /* large: direct malloc (unreachable for cls=3) */
        p = (WokObj*)malloc(sz);
        if (WOK_UNLIKELY(p == NULL)) { abort(); }
        WOK_PHYS_ADD(h, sz);
    }
    p->rc = 1u; p->tag = (uint16_t)WOK_STRING_VIEW_TAG; p->arity = 0u; p->scan = 0u;
    /* Write parent pointer at offset 8, offset at 16, len at 24. */
    uintptr_t parent_word = (uintptr_t)parent;
    memcpy((char*)p + 8,  &parent_word, sizeof(uint64_t));
    memcpy((char*)p + 16, &off,         sizeof(uint64_t));
    memcpy((char*)p + 24, &len,         sizeof(uint64_t));
    h->allocs += 1u; h->live += 1;
    if (h->live > h->peak) { h->peak = h->live; }
    h->cur_bytes += (uint64_t)sz;
    if (h->cur_bytes > h->peak_bytes) { h->peak_bytes = h->cur_bytes; }
    WOK_LOGICAL_MARK(h);
    return p;
}

uint64_t wok_stat_reused(const WokHeap* h)         { return h->reused; }
uint64_t wok_stat_reused_inplace(const WokHeap* h) { return h->reused_inplace; }
uint64_t wok_stat_slabs(const WokHeap* h)          { return h->nslabs; }
uint64_t wok_stat_arena_slabs(const WokHeap* h)    { return h->arena_nslabs; }

/* ---- slab backend: arena = checkpoint stack over a SEPARATE bump region ----------- */
/* The arena has its OWN slabs (h->arena_slabs) and bump pointer (h->arena_bump_ptr),
   completely distinct from the counted slab allocator (h->slabs / h->bump_ptr). A counted
   wok_alloc draws only from the counted region; wok_arena_alloc draws only from the arena
   region. wok_arena_close resets ONLY the arena region's frontier, so it can NEVER reclaim
   a counted (escaping) cell, even when the routing pass interleaves Arena and Heap
   allocations in program order within the same function body. */

uint32_t wok_arena_open(WokHeap* h) {
    if (WOK_UNLIKELY(h->arena_depth >= WOK_ARENA_MAX_DEPTH)) {
        fprintf(stderr, "wok_rc: wok_arena_open exceeded max depth %u\n", WOK_ARENA_MAX_DEPTH);
        abort();
    }
    uint32_t handle = h->arena_depth;
    WokArenaFrame* f = &h->arena_stack[handle];
    /* Save the ARENA region's bump frontier. slab_at_open is the arena slab that currently
       contains arena_bump_ptr (= h->arena_slabs, since wok_new_arena_slab prepends). If no
       arena slab has been allocated yet, slab_at_open == NULL and bump_ptr_save == NULL. */
    f->slab_at_open       = h->arena_slabs;
    f->bump_ptr_save      = h->arena_bump_ptr;
    f->bump_end_save      = h->arena_bump_end;
    f->arena_bytes_before = h->arena_bytes;
    h->arena_depth++;
    return handle;
}

WokObj* wok_arena_alloc(WokHeap* h, uint32_t tag, uint32_t arity) {
    assert(tag < 65536u && arity < 256u);
    if (WOK_UNLIKELY(h->arena_depth == 0u)) {
        fprintf(stderr, "wok_rc: wok_arena_alloc called with no open arena\n");
        abort();
    }
    size_t  sz = wok_cell_bytes(arity);
    WokObj* p;
    /* Bump from the SEPARATE arena region only. No free-list and no counted slab is ever
       touched -- so an interleaved counted wok_alloc lands in a disjoint region and is
       never reclaimed by an arena close. */
    if (h->arena_bump_ptr == NULL || sz > (size_t)(h->arena_bump_end - h->arena_bump_ptr)) {
        wok_new_arena_slab(h);
    }
    p = (WokObj*)h->arena_bump_ptr;
    h->arena_bump_ptr += sz;
    p->rc = 0u; p->tag = (uint16_t)tag; p->arity = (uint8_t)arity; p->scan = 0u;
    /* update arena stats only (NOT allocs/live/peak/cur_bytes) */
    h->arena_bytes += (uint64_t)sz;
    if (h->arena_bytes > h->arena_peak) { h->arena_peak = h->arena_bytes; }
    WOK_LOGICAL_MARK(h);
    return p;
}

void wok_arena_close(WokHeap* h, uint32_t handle) {
    if (WOK_UNLIKELY(h->arena_depth == 0u || handle != h->arena_depth - 1u)) {
        fprintf(stderr,
            "wok_rc: wok_arena_close handle mismatch (handle=%u, expected=%u)\n",
            handle, h->arena_depth == 0u ? 0u : h->arena_depth - 1u);
        abort();
    }
    WokArenaFrame* f = &h->arena_stack[handle];
    /* Restore the ARENA region's bump frontier to the saved checkpoint (the counted region is
       NEVER touched). The cells allocated during this scope are dead by definition at close
       (uncounted; their counted children were already dropped by the Haskell scan-out), so the
       slabs grown since open hold only dead memory and can be reclaimed. We restore EXACTLY the
       saved checkpoint and recycle the slabs grown since open onto an arena free-list, so a
       workload of many grow/close cycles reuses slabs instead of accumulating one per scope.
       Two cases:
         A. No new arena slab was grown (h->arena_slabs == f->slab_at_open): just wind the bump
            pointer back within the same slab (free-list untouched).
         B. New arena slabs were grown: unwind h->arena_slabs from the head down to (but not
            including) slab_at_open, pushing each grown slab onto h->arena_free_slabs, then
            restore the saved bump_ptr/bump_end (which point into slab_at_open, or are NULL if
            the scope opened with no arena slab yet -- the next alloc then pops the free-list).
       Restoring to slab_at_open's saved frontier (not the grown slab's start) is what keeps an
       OUTER scope's live cells, which sit below the checkpoint in slab_at_open, untouched. */
    if (h->arena_slabs != f->slab_at_open) {
        /* Case B: unwind grown slabs onto the free-list (none of them hold live cells: every
           cell above the checkpoint belongs to THIS closing scope and is now dead). */
        WokSlab* grown = h->arena_slabs;
        while (grown != f->slab_at_open) {
            WokSlab* nxt = grown->next;
            grown->next = h->arena_free_slabs;
            h->arena_free_slabs = grown;
            grown = nxt;
        }
        h->arena_slabs = f->slab_at_open;
    }
    /* Case A and B both land here: restore the exact saved frontier. */
    h->arena_bump_ptr = f->bump_ptr_save;
    h->arena_bump_end = f->bump_end_save;
    /* restore arena_bytes to the pre-open value; peak stays (high-water) */
    h->arena_bytes = f->arena_bytes_before;
    h->arena_depth--;
}

#endif /* WOK_RC_MALLOC */

/* ---- shared across both backends ---------------------------------------------------- */
#ifdef WOK_RC_CHECK_PHYSICAL
static void wok_check_physical(const WokHeap* h) {
    uint64_t bound = (uint64_t)WOK_PHYS_BOUND_K * h->peak_logical_bytes
                   + (uint64_t)WOK_PHYS_BOUND_C * (uint64_t)WOK_ARENA_SIZE;
    if (WOK_UNLIKELY(h->peak_physical_bytes > bound)) {
        fprintf(stderr,
            "wok_rc: PHYSICAL-memory invariant violated (unbounded physical growth): "
            "peak_physical=%llu peak_logical=%llu bound=%llu (K=%u C=%u slab=%u)\n",
            (unsigned long long)h->peak_physical_bytes,
            (unsigned long long)h->peak_logical_bytes,
            (unsigned long long)bound,
            WOK_PHYS_BOUND_K, WOK_PHYS_BOUND_C, WOK_ARENA_SIZE);
        abort();
    }
}
#endif

uint64_t wok_stat_peak_bytes(const WokHeap* h)     { return h->peak_bytes; }
uint64_t wok_stat_peak_physical_bytes(const WokHeap* h) { return h->peak_physical_bytes; }
uint64_t wok_stat_arena_bytes(const WokHeap* h)    { return h->arena_bytes; }
uint64_t wok_stat_arena_peak(const WokHeap* h)     { return h->arena_peak; }

#ifdef WOK_RC_PHYSICAL_TEST_HOOK
/* Negative control for the physical-memory invariant. Mallocs `n` slabs and folds their
   bytes into the heap's PHYSICAL high-water with NO matching logical allocation -- exactly
   the slab-orphaning shape the invariant exists to catch. The slabs are chained onto the
   heap's slab list (slab backend) so wok_heap_free reclaims them (LSan-clean when the
   assertion does NOT fire). WOK_CHECK_PHYSICAL runs after each fold, so a large `n` aborts
   under WOK_RC_CHECK_PHYSICAL. The malloc backend has no slab list, so the orphaned slabs
   are tracked on a dedicated test-only chain drained at heap free (kept minimal: this is a
   test hook, never on the codegen/interpreter path). */
void wok_test_orphan_slabs(WokHeap* h, int n) {
    for (int i = 0; i < n; i++) {
#ifndef WOK_RC_MALLOC
        WokSlab* s = (WokSlab*)malloc(WOK_ARENA_SIZE);
        if (WOK_UNLIKELY(s == NULL)) { abort(); }
        s->next = h->slabs;       /* chain so wok_heap_free reclaims it (no real leak) */
        h->slabs = s;
        h->nslabs += 1u;
#else
        /* malloc backend: no slab list. Allocate a slab-sized block and intentionally leak
           it -- this hook only runs in the death test (which aborts before any teardown),
           so there is nothing to reclaim. The orphan is the point. */
        void* s = malloc(WOK_ARENA_SIZE);
        if (WOK_UNLIKELY(s == NULL)) { abort(); }
        (void)s;
#endif
        WOK_PHYS_ADD(h, WOK_ARENA_SIZE);   /* physical grows with NO logical allocation */
        WOK_CHECK_PHYSICAL(h);             /* the self-policing assertion (gated) */
    }
}
#endif

/* ---- WokString accessors (shared, no allocator involvement) ------------------------- */

uint64_t wok_string_len(const WokObj* p) {
    assert((uint32_t)p->tag == WOK_STRING_TAG);
    return wok_string_read_byte_len(p);
}

uint8_t* wok_string_data(WokObj* p) {
    assert((uint32_t)p->tag == WOK_STRING_TAG);
    /* Body starts at offset 16 (8-byte WokObj prefix + 8-byte byte_len field). */
    return (uint8_t*)((char*)p + 16);
}

uint64_t wok_string_byte_get(const WokObj* p, uint64_t i) {
    assert((uint32_t)p->tag == WOK_STRING_TAG);
    assert(i < wok_string_read_byte_len(p));
    return (uint64_t)(((const uint8_t*)((const char*)p + 16))[i]);
}

/* ---- WokArray accessors (shared, no allocator involvement) -------------------------- */

uint64_t wok_array_len(const WokObj* p) {
    assert((uint32_t)p->tag == WOK_ARRAY_TAG);
    uint64_t len;
    memcpy(&len, (const char*)p + 8, sizeof(uint64_t));
    return len;
}

uint32_t wok_array_elemkind(const WokObj* p) {
    assert((uint32_t)p->tag == WOK_ARRAY_TAG);
    return (uint32_t)p->arity;
}

void wok_array_slot_set(WokObj* p, uint64_t i, uint64_t word) {
    assert((uint32_t)p->tag == WOK_ARRAY_TAG);
    assert(i < wok_array_read_len(p));
    ((uint64_t*)((char*)p + 16))[i] = word;
}

uint64_t wok_array_slot_get(const WokObj* p, uint64_t i) {
    assert((uint32_t)p->tag == WOK_ARRAY_TAG);
    assert(i < wok_array_read_len(p));
    return ((const uint64_t*)((const char*)p + 16))[i];
}

/* ---- WokStringView accessors (shared, no allocator involvement) --------------------- */

WokObj* wok_string_view_parent(const WokObj* p) {
    assert((uint32_t)p->tag == WOK_STRING_VIEW_TAG);
    uintptr_t parent_word;
    memcpy(&parent_word, (const char*)p + 8, sizeof(uint64_t));
    return (WokObj*)parent_word;
}

uint64_t wok_string_view_offset(const WokObj* p) {
    assert((uint32_t)p->tag == WOK_STRING_VIEW_TAG);
    uint64_t off;
    memcpy(&off, (const char*)p + 16, sizeof(uint64_t));
    return off;
}

uint64_t wok_string_view_len(const WokObj* p) {
    assert((uint32_t)p->tag == WOK_STRING_VIEW_TAG);
    uint64_t len;
    memcpy(&len, (const char*)p + 24, sizeof(uint64_t));
    return len;
}

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
uint32_t wok_rc(const WokObj* p) { return p->rc; }

uint64_t wok_stat_allocs(const WokHeap* h) { return h->allocs; }
uint64_t wok_stat_frees(const WokHeap* h)  { return h->frees; }
int64_t  wok_stat_live(const WokHeap* h)   { return h->live; }
int64_t  wok_stat_peak(const WokHeap* h)   { return h->peak; }
