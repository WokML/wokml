// wok_arena -- bump allocator for one parse job.
//
// Nodes are immutable, built once, and die together, which is an arena's exact
// shape. One job owns one arena; teardown frees the block list and there is
// nothing else to run. This is a SEPARATE, simpler allocator from
// runtime/wok_rc.c's arena -- no refcounts, no free lists, no cascade --
// because coupling a front end to the shipping runtime's ABI buys nothing.

#pragma once

#include <stddef.h>
#include <stdint.h>

#include "wok_base.h"

typedef struct WokArena WokArena;

// first_block is a hint in bytes; 0 selects the default (64 KiB).
WokArena *wok_arena_new(usize first_block);
void wok_arena_free(WokArena *);

// Never returns NULL: allocation failure aborts. A front end that cannot get
// memory has nothing useful to report, and every caller would otherwise carry
// a branch that is never taken and never tested.
void *wok_arena_alloc(WokArena *, usize size, usize align);

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

