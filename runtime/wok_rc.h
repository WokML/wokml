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
/* Non-destructive refcount peek. General (the shared WokObj prefix at offset 0,
   so it works on any cell including WokArray). The read-only sibling of
   wok_dup/wok_dec. Used by the rc==1 in-place Array.set gate (Slice C). */
WOK_PURE uint32_t wok_rc(const WokObj* p);

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

/* High-water PHYSICAL bytes held from the OS (slabs + large-object mallocs; the malloc
   backend counts every per-cell malloc). Distinct from peak_bytes (LOGICAL live bytes):
   peak_physical is the structural memory the process retained at its worst, regardless of
   how densely the logical bytes packed into it. A self-policing invariant (debug/sanitizer
   build) asserts peak_physical stays within a bounded factor of the logical high-water --
   catching unbounded physical growth (the slab-orphaning bug class) that balanced byte
   accounting and LeakSanitizer are both blind to. Additive, mirroring wok_stat_peak_bytes.
   Interpreter-era infrastructure: the slab model is replaced at codegen, so this is a cheap
   runtime self-check, not long-lived test infrastructure. */
WOK_PURE uint64_t wok_stat_peak_physical_bytes(const WokHeap* h);

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
   WOK_ARRAY_TAG is reserved Haskell-side: internTag never returns 0xFFFF or 0xFFFE
   (0xFFFE is the WOK_STRING_TAG, also reserved). */

#define WOK_ARRAY_TAG 0xFFFFu

WokObj*  wok_array_alloc(WokHeap* h, uint64_t len, uint8_t elemkind); /* rc=1, tag=WOK_ARRAY_TAG, slots undef */
WOK_PURE uint64_t wok_array_len(const WokObj* p);
WOK_PURE uint32_t wok_array_elemkind(const WokObj* p);
void     wok_array_slot_set(WokObj* p, uint64_t i, uint64_t word);
WOK_PURE uint64_t wok_array_slot_get(const WokObj* p, uint64_t i);

/* ---- WokString: a flat UTF-8 byte buffer C cell (Slice E1) -------------------------
   Layout (always 8-aligned):
     offset  0  uint32 rc       \
     offset  4  uint16 tag       |  8-byte WokObj-compatible prefix: wok_dup/wok_dec/wok_rc
     offset  6  uint8  reserved  |  read offsets 0-7 unchanged; tag == WOK_STRING_TAG marks
     offset  7  uint8  scan      /  a string; reserved=0 (no elemkind); scan=0 (no cascade).
     offset  8  uint64 byte_len  <- runtime BYTE count (not codepoints, not words)
     offset 16  uint8  bytes[byte_len]   <- packed UTF-8, 1-byte stride, opaque
   Cell byte size = 16 + 8*ceil(byte_len/8)  (body rounds UP to an 8-byte granule so the
   next bumped cell stays 8-aligned; contrast WokArray whose body is already word-aligned).
   Size class = (cell_bytes/8) - 1 = 1 + ceil(byte_len/8)  (shares the free-list with an
   NCon of that arity / a WokArray of that word-len -- identical byte size, shape-agnostic
   recycling).  class < WOK_NUM_CLASSES (64) -> arena free-list; else -> malloc.
   WOK_STRING_TAG is reserved Haskell-side: internTag never returns 0xFFFE or 0xFFFF. */

#define WOK_STRING_TAG 0xFFFEu

WokObj*          wok_string_alloc(WokHeap* h, uint64_t byte_len); /* rc=1, tag=WOK_STRING_TAG, body undef */
WOK_PURE uint64_t wok_string_len(const WokObj* p);                /* byte_len */
         uint8_t* wok_string_data(WokObj* p);                     /* pointer to body (bulk fill + FFI) */
WOK_PURE uint64_t wok_string_byte_get(const WokObj* p, uint64_t i); /* one byte, zero-extended */

/* ---- Uncounted per-activation arena (Region Slice R1) -----------------------------
   A LIFO checkpoint over the bump allocator. wok_arena_alloc returns an UNCOUNTED cell
   (rc field unused). The whole arena is reclaimed in O(1) by wok_arena_close (reset the
   bump frontier). The caller drops any counted children BEFORE close (a later Haskell
   task). Arena bytes are tracked separately from allocs/frees/live/peak. */
uint32_t wok_arena_open(WokHeap* h);                                /* push frontier; returns depth handle */
WokObj*  wok_arena_alloc(WokHeap* h, uint32_t tag, uint32_t arity); /* uncounted bump alloc in innermost arena */
void     wok_arena_close(WokHeap* h, uint32_t handle);              /* assert top==handle; reset frontier */
WOK_PURE uint64_t wok_stat_arena_bytes(const WokHeap* h);
WOK_PURE uint64_t wok_stat_arena_peak(const WokHeap* h);
/* High-water count of distinct arena slabs ever malloc'd (slab backend; the malloc backend
   has no slabs and reports 0). Counts mallocs, not live slabs -- a close recycles grown slabs
   onto an internal free-list rather than freeing them, so repeated grow/close cycles reuse
   slabs and this stays ~the peak concurrent need, NOT O(number of cycles). Symmetric with
   wok_stat_slabs; consumed C-side by the standalone bounded-slab regression test. */
WOK_PURE uint64_t wok_stat_arena_slabs(const WokHeap* h);

/* ---- test-only physical-invariant hook (negative control) --------------------------
   Compiled in only under WOK_RC_PHYSICAL_TEST_HOOK. Mallocs `n` slabs and folds their
   bytes into the heap's PHYSICAL high-water WITHOUT any corresponding logical allocation,
   simulating the slab-orphaning bug. With WOK_RC_CHECK_PHYSICAL active, a large `n` drives
   peak_physical past the K*logical + C*slab bound and the self-policing assertion aborts.
   The slabs are tracked so wok_heap_free reclaims them (no real leak under LSan when the
   assertion is NOT firing). Never reachable from the codegen/interpreter path. */
#ifdef WOK_RC_PHYSICAL_TEST_HOOK
void wok_test_orphan_slabs(WokHeap* h, int n);
#endif

#endif /* WOK_RC_H */
