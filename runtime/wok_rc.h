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

typedef struct WokObj {
    uint32_t rc;       /* plain counter */
    uint16_t tag;      /* interned constructor id -> indexes the Haskell descriptor */
    uint8_t  arity;    /* 0..255 */
    uint8_t  scan;     /* RESERVED for the future C cascade (pointer-slot count). Currently
                          ALWAYS 0 -- there is NO write path yet. The deferred C-cascade slice
                          MUST populate it (a wok_alloc param or a wok_scan_set) BEFORE reading
                          it, else a descriptor-bounded C free would skip every child (RC leak).
                          Slice 1's cascade is Haskell-driven via the descriptor and ignores scan. */
    uint64_t slots[];  /* `arity` raw 8-byte words */
} WokObj;

typedef struct WokHeap WokHeap;   /* opaque per-run context */

WokHeap* wok_heap_new(void);
void     wok_heap_free(WokHeap* h);
WokObj*  wok_alloc(WokHeap* h, uint32_t tag, uint32_t arity);
WokObj*  wok_alloc_at(WokHeap* h, uint32_t tag, uint32_t arity, WokObj* p);  /* FBIP: re-stamp in place */
void     wok_dup(WokObj* p);
uint64_t wok_dec(WokObj* p);                        /* rc--, returns NEW rc; no free */
void     wok_free(WokHeap* h, WokObj* p);
void     wok_slot_set(WokObj* p, uint32_t i, uint64_t word);
WOK_PURE uint64_t wok_slot_get(const WokObj* p, uint32_t i);
WOK_PURE uint32_t wok_tag(const WokObj* p);
WOK_PURE uint32_t wok_arity(const WokObj* p);

WOK_PURE uint64_t wok_stat_allocs(const WokHeap* h);
WOK_PURE uint64_t wok_stat_frees(const WokHeap* h);
WOK_PURE int64_t  wok_stat_live(const WokHeap* h);
WOK_PURE int64_t  wok_stat_peak(const WokHeap* h);

/* additive observability. reused/slabs are arena-only (the WOK_RC_MALLOC backend
   reports 0) and consumed C-side by the standalone test / microbench (no Haskell binding). */
WOK_PURE uint64_t wok_stat_reused(const WokHeap* h);
WOK_PURE uint64_t wok_stat_reused_inplace(const WokHeap* h);  /* FBIP wok_alloc_at hits (arena only) */
WOK_PURE uint64_t wok_stat_slabs(const WokHeap* h);
/* peak_bytes (high-water Sigma(8 + 8*arity)) is tracked in BOTH backends and returns the
   real figure under WOK_RC_MALLOC; bound in Haskell as wokStatPeakBytes for benchmarking. */
WOK_PURE uint64_t wok_stat_peak_bytes(const WokHeap* h);

/* ---- WokArray: a real C array cell (Slice B) ----------------------------------------
   Layout (always 8-aligned):
     offset  0  uint32 rc       \
     offset  4  uint16 tag       |  8-byte WokObj-compatible prefix: wok_dup/wok_dec/wok_tag
     offset  6  uint8  elemkind  |  read offsets 0-7 unchanged; tag == WOK_ARRAY_TAG marks
     offset  7  uint8  scan      /  an array; elemkind stores the element SlotKind (C: opaque)
     offset  8  uint64 len       <- runtime element count (word 2)
     offset 16  uint64 slots[len] <- len 8-byte slots
   Byte size = 16 + 8*len.  Size class = bytes/8 - 1 = len + 1.
   len <= 62 (class < WOK_NUM_CLASSES 64) -> arena free-list; len >= 63 -> malloc.
   The arena free-list[len+1] is SHARED with NCon arity (len+1): identical byte size,
   shape-agnostic recycling.
   WOK_ARRAY_TAG is reserved Haskell-side: internTag never returns 0xFFFF. */

#define WOK_ARRAY_TAG 0xFFFFu

WokObj*  wok_array_alloc(WokHeap* h, uint64_t len, uint8_t elemkind); /* rc=1, tag=WOK_ARRAY_TAG, slots undef */
WOK_PURE uint64_t wok_array_len(const WokObj* p);
WOK_PURE uint32_t wok_array_elemkind(const WokObj* p);
void     wok_array_slot_set(WokObj* p, uint64_t i, uint64_t word);
WOK_PURE uint64_t wok_array_slot_get(const WokObj* p, uint64_t i);

#endif /* WOK_RC_H */
