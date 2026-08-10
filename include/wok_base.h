// wok_base -- the shared C prelude: fixed-width type names, and the compiler
// facts every wok C translation unit wants stated once.
//
// HEADER ONLY, and deliberately so: adopting it anywhere in the repo is one
// `-I`, with no translation unit to add to a build system.
//
// C23 ONLY. `runtime/` still builds with `-std=c17` (wok.cabal), so it cannot
// include this header until that flag moves to c23 -- a one-line change, but
// one that recompiles the shipping runtime and belongs in its own review.

#pragma once

#if !defined(__STDC_VERSION__) || __STDC_VERSION__ < 202311L
#error "wok requires C23 (-std=c23)"
#endif

// ------------------------------------------------------- feature tests
//
// SELF-POLICING FIRST. glibc's features.h defines _FEATURES_H as soon as it
// has settled which declarations exist. Arriving here after that, with no
// _POSIX_C_SOURCE in hand, means a system header won the race and everything
// below is decoration. Left undetected it surfaces hundreds of lines later as
// "struct stat has no member st_mtim", which names neither the cause nor the
// file that caused it -- so say it here, where the fix is.
#if defined(_FEATURES_H) && !defined(_POSIX_C_SOURCE)
#error "wok_base.h must be included BEFORE any system header (see the ordering rule below)"
#endif
//
// -std=c23 is strict ISO: it defines __STRICT_ANSI__, and glibc then withholds
// every POSIX declaration -- fmemopen, popen, opendir, dup2, and struct stat's
// st_mtim among them. This build wants strict ISO for the LANGUAGE and POSIX
// for the LIBRARY, which is not a contradiction, just something that has to be
// asked for. Asked for once, here, instead of in each file that trips over it.
//
// ORDERING RULE -- the reason this sits above every #include below: a
// feature-test macro has effect only if it precedes the first system header.
// So wok_base.h must be reached before <stdio.h> in every translation unit.
// The house style already delivers that, because each .c opens with its own
// header and the project headers include this one. A .c that opens with a
// system header instead silently gets the strict-ISO configuration and will
// fail to see POSIX -- if that happens, include "wok_base.h" first, explicitly.
//
// The Apple clause is not symmetry for its own sake: asking for POSIX on
// Darwin HIDES the Darwin extensions (st_mtimespec, which wok_write.c needs on
// that platform), so the two have to be requested together.
#if !defined(_POSIX_C_SOURCE)
#  define _POSIX_C_SOURCE 200809L
#endif
#if defined(__APPLE__) && !defined(_DARWIN_C_SOURCE)
#  define _DARWIN_C_SOURCE 1
#endif

#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

// --------------------------------------------------------------- types
//
// One spelling per width. `uint32_t` and `u32` are the same type; having both
// in one codebase is a coin flip at every declaration, which is exactly the
// redundancy the surface design refuses elsewhere.

typedef uint8_t u8;
typedef uint16_t u16;
typedef uint32_t u32;
typedef uint64_t u64;

typedef int8_t i8;
typedef int16_t i16;
typedef int32_t i32;
typedef int64_t i64;

typedef size_t usize;
typedef ptrdiff_t isize;
typedef uintptr_t uptr;

// Bare `int` is not banned, but it is not a DOMAIN type either. Pick by what
// the value is: u32 for a depth, a precedence level, an indent or a column;
// usize for a size or an index; i32 only where a negative is a real value,
// such as a -1 sentinel.
//
// `int` survives in exactly two places, both forced:
//   - `main`, which the standard requires;
//   - the precision argument of printf's `%.*s`, which varargs requires --
//     every remaining (int) cast in the front end is one of these.
// Banning it outright would mean casting at every libc boundary (fprintf,
// memcmp, snprintf, access, stat, rename all return int) under -Wconversion,
// which trains people to sprinkle casts and loses more safety than it wins.
// Mapping it to i64 would be worse still: these are counters bounded by 256.

// --------------------------------------------------- compiler facts
//
// Each is a promise the compiler acts on, and each is undefined behaviour if
// made falsely. The comments say what the promise IS, so it can be checked at
// a call site rather than copied.
//
// The guards below are CAPABILITY checks, not standard-version checks: C23 is
// already required above, but a conforming C23 compiler need not implement
// [[unsequenced]] -- Apple clang 21 does not, measured -- and the GNU
// attributes are not ISO at all.

// WOK_PURE: the result depends only on the arguments and NO memory is read,
// including globals. Character-class predicates over a constexpr bitmap
// qualify. Anything that dereferences a pointer, or reads a static table,
// DOES NOT -- use WOK_READONLY for those.
// GNU spelling FIRST, deliberately. C23 requires [[unsequenced]] and
// [[reproducible]] to appertain to the function DECLARATOR -- they must follow
// the parameter list -- but all 63 uses in this repo are prefixes, ahead of the
// return type. GCC 15 implements the attribute and rejects that placement
// ("can only be applied to function declarators"); clang 19 does not implement
// it at all, so __has_c_attribute was false there and the GNU branch was taken,
// which is why only GCC ever complained.
//
// __attribute__((const)) is valid in prefix position on both, and carries the
// same optimisation licence. To use the standard spelling instead, all 63 sites
// have to move to suffix position -- a separate, mechanical change.
#if defined(__GNUC__)
#  define WOK_PURE __attribute__((const))
#elif defined(__has_c_attribute) && __has_c_attribute(unsequenced)
#  define WOK_PURE [[unsequenced]]
#else
#  define WOK_PURE
#endif

// WOK_READONLY: reads memory through its arguments or from static data, but
// writes none and has no other effects. The right one for a table lookup.
// GNU spelling first, for the placement reason documented on WOK_PURE above.
#if defined(__GNUC__)
#  define WOK_READONLY __attribute__((pure))
#elif defined(__has_c_attribute) && __has_c_attribute(reproducible)
#  define WOK_READONLY [[reproducible]]
#else
#  define WOK_READONLY
#endif

#if defined(__GNUC__)
#  define WOK_PRINTF(fmt_idx, arg_idx) \
    __attribute__((format(printf, fmt_idx, arg_idx)))
#else
#  define WOK_PRINTF(fmt_idx, arg_idx)
#endif

// unreachable() is UB if reached, so it never appears raw: a debug build
// aborts loudly instead. In release the optimiser drops the bounds check and
// coverage tools mark the region excluded rather than permanently uncovered.
[[noreturn]] static inline void wok_abort_unreachable(const char *file,
                                                      int line) {
  (void)fprintf(stderr, "wok: unreachable reached at %s:%d\n", file, line);
  abort();
}

#ifdef NDEBUG
#  define WOK_UNREACHABLE() unreachable()
#else
#  define WOK_UNREACHABLE() wok_abort_unreachable(__FILE__, __LINE__)
#endif

// Checked integer conversion. Guarded because a hosted implementation may lag
// on this header even at C23.
#if defined(__has_include) && __has_include(<stdckdint.h>)
#  include <stdckdint.h>
#  define WOK_HAVE_CKDINT 1
#else
#  define WOK_HAVE_CKDINT 0
#endif
