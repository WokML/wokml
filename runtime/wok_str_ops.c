/* NOTE ON THE PRAGMA SPELLING BELOW: it must be `GCC`, not `clang`. GCC
   ignores `#pragma clang diagnostic` outright, so with the clang spelling none
   of these suppressions reached GCC and the vendored header failed the build
   on -Wunused-function. Clang honours the GCC spelling too, so one spelling
   covers both compilers; the clang spelling covers only one. */
/* StringZilla wrappers for wok String Slice E2. Raw-byte-range entry points so the
   same functions serve a C cell, a Haskell ByteString, and an encodeUtf8 buffer.
   All StringZilla entry points are compiled as inline-static into this single TU
   (SZ_DYNAMIC_DISPATCH=0, the default): the definitions live inside the header's
   #if !SZ_DYNAMIC_DISPATCH guard, so do NOT set SZ_DYNAMIC_DISPATCH=1 here. */
#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wpedantic"
#pragma GCC diagnostic ignored "-Wconversion"
#pragma GCC diagnostic ignored "-Wdouble-promotion"
#pragma GCC diagnostic ignored "-Wsign-conversion"
#pragma GCC diagnostic ignored "-Wunused-parameter"
#pragma GCC diagnostic ignored "-Wunused-function"
#pragma GCC diagnostic ignored "-Wextra"
#pragma GCC diagnostic ignored "-Wstrict-aliasing"
#pragma GCC diagnostic ignored "-Wstrict-prototypes"
#pragma GCC diagnostic ignored "-Wunknown-pragmas"
#pragma GCC diagnostic ignored "-Wformat-security"
#include "stringzilla/stringzilla.h"
#pragma GCC diagnostic pop
#include <stdint.h>
#include <stddef.h>

#define WOK_SZ_NOT_FOUND UINT64_MAX

/* First occurrence of needle in hay at or after byte offset `from`.
   Returns the absolute byte position, or WOK_SZ_NOT_FOUND. */
uint64_t wok_sz_find(const char *hay, size_t hay_len,
                     const char *needle, size_t needle_len, size_t from) {
    if (from > hay_len) return WOK_SZ_NOT_FOUND;
    if (needle_len == 0) return (uint64_t)from;
    if (needle_len > hay_len - from) return WOK_SZ_NOT_FOUND;
    sz_cptr_t base = (sz_cptr_t)(hay + from);
    sz_cptr_t m = sz_find(base, (sz_size_t)(hay_len - from),
                          (sz_cptr_t)needle, (sz_size_t)needle_len);
    if (m == NULL) return WOK_SZ_NOT_FOUND;
    return (uint64_t)from + (uint64_t)(m - base);
}

uint64_t wok_sz_hash(const char *data, size_t len) {
    return (uint64_t)sz_hash((sz_cptr_t)data, (sz_size_t)len);
}

/* Byte-level unit-cost Levenshtein. bound=0 -> unbounded; NULL alloc -> default libc
   scratch (invisible to wok's wok_rc counters, by design). */
uint64_t wok_sz_edit_distance(const char *a, size_t a_len,
                              const char *b, size_t b_len) {
    return (uint64_t)sz_edit_distance((sz_cptr_t)a, (sz_size_t)a_len,
                                      (sz_cptr_t)b, (sz_size_t)b_len,
                                      (sz_size_t)0, NULL);
}
