#ifndef WOK_RC_H
#define WOK_RC_H
#include <stdint.h>
#include <stddef.h>

#if defined(__GNUC__) || defined(__clang__)
#  define WOK_UNLIKELY(x) __builtin_expect(!!(x), 0)
#else
#  define WOK_UNLIKELY(x) (x)
#endif

#if defined(__GNUC__) || defined(__clang__)
#  define WOK_PURE __attribute__((pure))
#else
#  define WOK_PURE
#endif

typedef struct WokSlot { uint64_t tag; uint64_t payload; } WokSlot;

typedef struct WokObj {
    uint64_t rc;
    uint32_t tag;
    uint32_t arity;
    WokSlot  slots[];   /* flexible array member, `arity` entries */
} WokObj;

typedef struct WokHeap WokHeap;   /* opaque per-run context */

WokHeap* wok_heap_new(void);
void     wok_heap_free(WokHeap* h);
WokObj*  wok_alloc(WokHeap* h, uint32_t tag, uint32_t arity);
void     wok_dup(WokObj* p);
uint64_t wok_dec(WokObj* p);                        /* rc--, returns NEW rc; no free */
void     wok_free(WokHeap* h, WokObj* p);
void     wok_slot_set(WokObj* p, uint32_t i, uint64_t tag, uint64_t payload);
void     wok_slot_get(const WokObj* p, uint32_t i, uint64_t* restrict tag, uint64_t* restrict payload);
WOK_PURE uint32_t wok_tag(const WokObj* p);
WOK_PURE uint32_t wok_arity(const WokObj* p);

WOK_PURE uint64_t wok_stat_allocs(const WokHeap* h);
WOK_PURE uint64_t wok_stat_frees(const WokHeap* h);
WOK_PURE int64_t  wok_stat_live(const WokHeap* h);
WOK_PURE int64_t  wok_stat_peak(const WokHeap* h);

/* additive observability (arena-only; the WOK_RC_MALLOC backend reports 0).
   Consumed C-side by the standalone test / microbench; no Haskell binding. */
WOK_PURE uint64_t wok_stat_reused(const WokHeap* h);
WOK_PURE uint64_t wok_stat_slabs(const WokHeap* h);

#endif /* WOK_RC_H */
