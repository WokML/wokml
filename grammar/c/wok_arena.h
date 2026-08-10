// wok_arena -- bump allocator for one parse job.
//
// Nodes are immutable, built once, and die together, which is an arena's exact
// shape. One job owns one arena; teardown frees the block list and there is
// nothing else to run. This is a SEPARATE, simpler allocator from
// runtime/wok_rc.c's arena -- no refcounts, no free lists, no cascade --
// because coupling a front end to the shipping runtime's ABI buys nothing.

#pragma once

// The prelude comes FIRST: it carries the POSIX feature-test macros, which
// have no effect once a system header has been read. wok_base.h hard-errors
// if it is reached too late.
#include "wok_base.h"

#include <assert.h>
#include <stddef.h>
#include <stdint.h>

// The layouts live HERE, not behind an opaque pointer, for one reason: the
// allocation fast path below must inline. Every WOK_NEW site knows size and
// align at compile time, and an out-of-line call throws that knowledge away
// -- inlined, the align-up folds to a constant mask, the power-of-two assert
// folds to nothing, and the whole hot path is a compare and two adds
// (profiled at ~8% of a parse as a call). Nothing else may touch these
// fields; the API below is still the whole contract.
typedef struct WokArenaBlock {
  struct WokArenaBlock *next;
  usize capacity;
  usize used;
  alignas(max_align_t) unsigned char payload[];
} WokArenaBlock;

struct WokArena {
  WokArenaBlock *head;
  usize block_count;
  usize bytes_out;        // bytes handed to callers, excluding alignment pad
  usize growth_capacity;  // capacity of the last *normal* growth block
};
typedef struct WokArena WokArena;

// first_block is a hint in bytes; 0 selects the default (64 KiB).
WokArena *wok_arena_new(usize first_block);
void wok_arena_free(WokArena *);

// The GROWTH path: the current block cannot hold the request, so a new block
// is chained on. Out of line and cold -- it runs once per block, not once
// per allocation. Never returns NULL: allocation failure aborts, because a
// front end that cannot get memory has nothing useful to report.
[[gnu::cold, gnu::malloc, gnu::alloc_size(2), gnu::alloc_align(3),
  gnu::returns_nonnull]]
void *wok_arena_grow(WokArena *, usize size, usize align);

// The allocation fast path. The attributes are the STATIC INFORMATION the
// call sites act on: the pointer is fresh (no aliasing), `size` bytes big,
// and `align` aligned -- which is what lets a following memset compile to
// aligned stores and a caller drop its null paths.
[[gnu::malloc, gnu::alloc_size(2), gnu::alloc_align(3), gnu::returns_nonnull]]
static inline void *wok_arena_alloc(WokArena *a, usize size, usize align) {
  assert(align != 0 && (align & (align - 1)) == 0);

  // Zero-size requests still consume (and bump past) one byte so that two
  // successive zero-size allocations do not alias the same address.
  usize footprint = size == 0 ? (usize)1 : size;

  WokArenaBlock *blk = a->head;
  uptr cur = (uptr)blk->payload + (uptr)blk->used;
  uptr aligned = (cur + (uptr)align - 1) & ~((uptr)align - 1);
  usize pad = (usize)(aligned - cur);
  usize remaining = blk->capacity - blk->used;

  if (pad <= remaining && footprint <= remaining - pad) {
    blk->used += pad + footprint;
    a->bytes_out += size;
    return (void *)aligned;
  }
  return wok_arena_grow(a, size, align);
}

// Copies n bytes and NUL-terminates. Used for diagnostic text only; token text
// is always a view into the source buffer.
char *wok_arena_copy(WokArena *, const char *src, usize n);

// Live bytes handed out, and blocks reserved. Used by the leak invariant:
// arena bytes must return to baseline after every job.
usize wok_arena_bytes(const WokArena *);
usize wok_arena_blocks(const WokArena *);

#define WOK_NEW(a, T) ((T *)wok_arena_alloc((a), sizeof(T), alignof(T)))
#define WOK_NEW_N(a, T, n) \
  ((T *)wok_arena_alloc((a), sizeof(T) * (usize)(n), alignof(T)))
