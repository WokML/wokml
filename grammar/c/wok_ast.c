// Everything in this file is derived from the schema in wok_ast.h. If you are
// adding a node, you are in the wrong file.

#include "wok_ast.h"

#include <string.h>

// A sentinel keeps the array non-empty for nodes with no fields; nfields comes
// from the slot-index enum, so the sentinel is never visited.
#define WOK_FIELD_DESC(T, cls, name) {#name, WFC_##cls},
#define WOK_DECLARE_FIELDS(T)                             \
  static const WokFieldDesc T##_field_desc[] = {          \
      T##_FIELDS(WOK_FIELD_DESC, T){nullptr, WFC_NODE}};
WOK_NODES(WOK_DECLARE_FIELDS)
#undef WOK_DECLARE_FIELDS

const WokNodeDesc wok_node_desc[WOK_TAG_COUNT] = {
#define WOK_NODE_DESC(T) [T] = {#T, T##_field_desc, T##__NSLOTS},
    WOK_NODES(WOK_NODE_DESC)
#undef WOK_NODE_DESC
};

static const u16 node_slots[WOK_TAG_COUNT] = {
#define WOK_NODE_SLOTS(T) [T] = T##__NSLOTS,
    WOK_NODES(WOK_NODE_SLOTS)
#undef WOK_NODE_SLOTS
};

WokNode *wok_node(WokArena *a, WokTag tag, u32 off, u32 len) {
  u16 n = node_slots[tag];
  usize bytes = sizeof(WokNode) + (usize)n * sizeof(WokSlot);
  WokNode *node = wok_arena_alloc(a, bytes, alignof(WokNode));
  memset(node, 0, bytes);
  node->tag = (u16)tag;
  node->nslots = n;
  node->trivia = 0;  // no comments until wok_trivia_attach says otherwise
  node->off = off;
  node->len = len;
  return node;
}

WokSeq wok_seq(WokArena *a, WokNode *const *restrict items, u32 n) {
  if (n == 0) return wok_seq_empty();
  WokNode **base = WOK_NEW_N(a, WokNode *, (usize)n + 1);
  base[0] = (WokNode *)(uptr)n;  // the inline count; never dereferenced
  memcpy(base + 1, items, (usize)n * sizeof *base);
  return (WokSeq){.items = base + 1, .n = n};
}

void wok_buf_init(WokNodeBuf *b, WokArena *a) {
  *b = (WokNodeBuf){.raw = nullptr, .raw_n = 0, .cap = 0, .arena = a};
}

void wok_buf_push(WokNodeBuf *b, WokNode *node) {
  if (b->raw_n == 0) b->raw_n = 1;  // index 0 is the inline count
  if (b->raw_n >= b->cap) {
    u32 next = b->cap ? b->cap * 2 : 8;
    WokNode **grown = WOK_NEW_N(b->arena, WokNode *, next);
    if (b->raw_n > 1) memcpy(grown, b->raw, (usize)b->raw_n * sizeof *grown);
    b->raw = grown;
    b->cap = next;
  }
  b->raw[b->raw_n++] = node;
}

WokSeq wok_buf_seq(WokNodeBuf *b) {
  // Zero copy: the buffer already lives in the arena and index 0 was reserved
  // by the first push, so it becomes the inline count in place.
  u32 count = wok_buf_count(b);
  if (count == 0) return wok_seq_empty();
  b->raw[0] = (WokNode *)(uptr)count;
  return (WokSeq){.items = b->raw + 1, .n = count};
}

// ---------------------------------------------------------------- coverage
//
// Single-threaded by design: this is a test instrument, and a batch parse
// does not enable it. Making it atomic would buy nothing and cost the hot
// path.

static bool cover[WOK_TAG_COUNT];
static WokTag cover_missing_buf[WOK_TAG_COUNT];

void wok_cover_mark(WokTag t) { cover[t] = true; }
void wok_cover_reset(void) { memset(cover, 0, sizeof cover); }
bool wok_cover_seen(WokTag t) { return cover[t]; }

usize wok_cover_missing(const WokTag **out) {
  usize n = 0;
  for (int t = 0; t < WOK_TAG_COUNT; t++)
    if (!cover[t]) cover_missing_buf[n++] = (WokTag)t;
  *out = cover_missing_buf;
  return n;
}
