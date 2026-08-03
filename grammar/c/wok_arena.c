// wok_arena -- bump allocator implementation. See wok_arena.h for the
// contract: one growable list of malloc'd blocks, no frees of individual
// allocations, teardown frees the whole list at once.

#include "wok_arena.h"

#include <assert.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define WOK_ARENA_DEFAULT_BLOCK ((usize)(64u * 1024u))
#define WOK_ARENA_MAX_GROWTH ((usize)(8u * 1024u * 1024u))

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

[[noreturn]] static void wok_arena_oom(void) {
  (void)fprintf(stderr, "wok: out of memory allocating arena block\n");
  abort();
}

static WokArenaBlock *wok_arena_new_block(usize capacity) {
  WokArenaBlock *blk = (WokArenaBlock *)malloc(sizeof(WokArenaBlock) + capacity);
  if (blk == nullptr) wok_arena_oom();
  blk->next = nullptr;
  blk->capacity = capacity;
  blk->used = 0;
  return blk;
}

static uptr wok_align_up(uptr value, usize align) {
  uptr a = (uptr)align;
  return (value + a - (uptr)1) & ~(a - (uptr)1);
}

WokArena *wok_arena_new(usize first_block) {
  usize cap = first_block != 0 ? first_block : WOK_ARENA_DEFAULT_BLOCK;

  WokArena *a = (WokArena *)malloc(sizeof(WokArena));
  if (a == nullptr) wok_arena_oom();

  a->head = wok_arena_new_block(cap);
  a->block_count = 1;
  a->bytes_out = 0;
  a->growth_capacity = cap;
  return a;
}

void wok_arena_free(WokArena *a) {
  if (a == nullptr) return;

  WokArenaBlock *blk = a->head;
  while (blk != nullptr) {
    WokArenaBlock *next = blk->next;
    free(blk);
    blk = next;
  }
  free(a);
}

void *wok_arena_alloc(WokArena *a, usize size, usize align) {
  assert(align != 0 && (align & (align - 1)) == 0);

  // Zero-size requests still consume (and bump past) one byte so that two
  // successive zero-size allocations do not alias the same address.
  usize footprint = size == 0 ? (usize)1 : size;

  WokArenaBlock *blk = a->head;
  uptr base = (uptr)blk->payload;
  uptr cur = base + (uptr)blk->used;
  uptr aligned = wok_align_up(cur, align);
  usize pad = (usize)(aligned - cur);
  usize remaining = blk->capacity - blk->used;

  if (pad <= remaining && footprint <= remaining - pad) {
    blk->used += pad + footprint;
    a->bytes_out += size;
    return (void *)aligned;
  }

  // Current block cannot hold this allocation: grow the arena. `needed` is a
  // safe upper bound on what a fresh block must hold, since a brand new
  // block's payload is already max-aligned and align worst-case slop is
  // bounded by `align` itself.
  usize needed = footprint + align;
  bool dedicated = needed > WOK_ARENA_MAX_GROWTH;
  usize new_cap;
  if (dedicated) {
    new_cap = needed;
  } else {
    usize doubled = a->growth_capacity > WOK_ARENA_MAX_GROWTH / 2
                          ? WOK_ARENA_MAX_GROWTH
                          : a->growth_capacity * 2;
    new_cap = doubled > needed ? doubled : needed;
    if (new_cap > WOK_ARENA_MAX_GROWTH) new_cap = WOK_ARENA_MAX_GROWTH;
  }

  WokArenaBlock *nb = wok_arena_new_block(new_cap);
  nb->next = a->head;
  a->head = nb;
  a->block_count += 1;
  if (!dedicated) a->growth_capacity = new_cap;

  uptr nbase = (uptr)nb->payload;
  uptr naligned = wok_align_up(nbase, align);
  usize npad = (usize)(naligned - nbase);
  nb->used = npad + footprint;
  a->bytes_out += size;
  return (void *)naligned;
}

char *wok_arena_copy(WokArena *a, const char *src, usize n) {
  char *dst = (char *)wok_arena_alloc(a, n + 1, alignof(char));
  memcpy(dst, src, n);
  dst[n] = '\0';
  return dst;
}

usize wok_arena_bytes(const WokArena *a) { return a->bytes_out; }

usize wok_arena_blocks(const WokArena *a) { return a->block_count; }
