// wok_sexpr -- see wok_sexpr.h for the format and the out_src contract.
//
// Every traversal here walks wok_node_desc[]; the only per-node-CLASS code
// is the seven-way switch on WokFieldClass (NODE/OPT/SEQ/NAME/TEXT/INT/FLAG),
// which is exactly the "generic" part of "generic dump and reader" -- adding
// a wok AST node never touches this file, only adding a new field CLASS
// would.

// This include a string buffer here.

#include "wok_sexpr.h"

#include <inttypes.h>
#include <stdint.h>
#include <string.h>

#include "wok_base.h"

// Real C call-stack depth, in both directions, is bounded by this: a node
// recurses into its NODE/OPT/SEQ fields, which recurse into their nodes, and
// so on. Past this depth we report rather than risk overflowing the stack.
#define WOK_SEXPR_MAX_DEPTH 256

// =========================================================================
// dump
// =========================================================================

// Both public dump entry points write through this so they are, by
// construction, the same algorithm: one to a FILE (stdio does its own
// buffering), one to an arena-backed growable buffer (doubling, like
// WokNodeBuf in wok_ast.c -- there is no realloc in an arena, so old copies
// are simply abandoned garbage, which is what an arena is for).
typedef struct {
  bool to_file;
  FILE *file;
  WokArena *arena;
  char *buf;
  usize len, cap;
} WokSexprSink;

static void sink_reserve(WokSexprSink *s, usize extra) {
  if (s->to_file) return;
  if (s->len + extra <= s->cap) return;
  usize new_cap = s->cap ? s->cap * 2 : 128;
  while (new_cap < s->len + extra) new_cap *= 2;
  char *grown = WOK_NEW_N(s->arena, char, new_cap);
  if (s->len) memcpy(grown, s->buf, s->len);
  s->buf = grown;
  s->cap = new_cap;
}

static void sink_put_char(WokSexprSink *s, char c) {
  if (s->to_file) {
    (void)fputc(c, s->file);
    return;
  }
  sink_reserve(s, 1);
  s->buf[s->len++] = c;
}

static void sink_put_str(WokSexprSink *s, const char *str, usize n) {
  if (s->to_file) {
    (void)fwrite(str, 1, n, s->file);
    return;
  }
  sink_reserve(s, n);
  memcpy(s->buf + s->len, str, n);
  s->len += n;
}

static void render_node(WokSexprSink *sink, const char *src, const WokNode *n,
                        u32 depth);

static bool tag_is_block(WokTag t) {
  const WokNodeDesc *d = &wok_node_desc[t];
  for (u16 i = 0; i < d->nfields; i++) {
    WokFieldClass c = d->fields[i].cls;
    if (c == WFC_NODE || c == WFC_OPT || c == WFC_SEQ) return true;
  }
  return false;
}

static void emit_indent(WokSexprSink *sink, u32 depth) {
  for (u32 i = 0; i < depth; i++) sink_put_str(sink, "  ", 2);
}

static void render_string(WokSexprSink *sink, const char *src, WokSpan span) {
  sink_put_char(sink, '"');
  for (u32 i = 0; i < span.len; i++) {
    unsigned char c = (unsigned char)src[span.off + i];
    switch (c) {
      case '\\':
        sink_put_str(sink, "\\\\", 2);
        break;
      case '"':
        sink_put_str(sink, "\\\"", 2);
        break;
      case '\n':
        sink_put_str(sink, "\\n", 2);
        break;
      case '\t':
        sink_put_str(sink, "\\t", 2);
        break;
      case '\r':
        sink_put_str(sink, "\\r", 2);
        break;
      default:
        if (c < 0x20) {
          char buf[5];
          (void)snprintf(buf, sizeof buf, "\\x%02X", (unsigned)c);
          sink_put_str(sink, buf, 4);
        } else {
          sink_put_char(sink, (char)c);
        }
        break;
    }
  }
  sink_put_char(sink, '"');
}

static void render_uint(WokSexprSink *sink, u64 v) {
  char buf[32];
  int len = snprintf(buf, sizeof buf, "%" PRIu64, v);
  sink_put_str(sink, buf, (usize)len);
}

// The one place a schema violation (a required NODE field left null) is
// caught: it cannot be dumped correctly, so this reports it and emits a
// placeholder that will, correctly, fail to read back.
static void render_node_or_null(WokSexprSink *sink, const char *src,
                                const char *parent_tag, const char *field,
                                const WokNode *child, u32 depth) {
  if (child == nullptr) {
    (void)fprintf(stderr,
                  "wok_sexpr: dump error: %s.%s is a null NODE field\n",
                  parent_tag, field);
    sink_put_str(sink, "(!null)", 7);
    return;
  }
  render_node(sink, src, child, depth);
}

static void render_opt(WokSexprSink *sink, const char *src,
                       const WokNode *child, u32 depth) {
  if (child == nullptr) {
    sink_put_str(sink, "(none)", 6);
    return;
  }
  sink_put_str(sink, "(some", 5);
  sink_put_char(sink, '\n');
  emit_indent(sink, depth + 1);
  render_node(sink, src, child, depth + 1);
  sink_put_char(sink, ')');
}

static void render_seq(WokSexprSink *sink, const char *src, WokSeq seq,
                       u32 depth) {
  if (seq.n == 0) {
    sink_put_str(sink, "(seq)", 5);
    return;
  }
  sink_put_str(sink, "(seq", 4);
  for (u32 i = 0; i < seq.n; i++) {
    sink_put_char(sink, '\n');
    emit_indent(sink, depth + 1);
    render_node(sink, src, seq.items[i], depth + 1);
  }
  sink_put_char(sink, ')');
}

static void render_field(WokSexprSink *sink, const char *src,
                         const char *parent_tag, const char *field_name,
                         WokFieldClass cls, WokSlot slot, u32 depth) {
  switch (cls) {
    case WFC_NODE:
      render_node_or_null(sink, src, parent_tag, field_name, slot.node,
                          depth);
      return;
    case WFC_OPT:
      render_opt(sink, src, slot.node, depth);
      return;
    case WFC_SEQ:
      render_seq(sink, src, wok_seq_unpack(slot.seq), depth);
      return;
    case WFC_NAME:
    case WFC_TEXT:
      render_string(sink, src, slot.span);
      return;
    case WFC_INT:
      render_uint(sink, slot.num);
      return;
    case WFC_FLAG:
      sink_put_str(sink, slot.flag ? "#t" : "#f", 2);
      return;
    case WOK_FIELD_CLASS_COUNT:
      break;
  }
  WOK_UNREACHABLE();
}

static void render_node(WokSexprSink *sink, const char *src, const WokNode *n,
                        u32 depth) {
  if (depth > WOK_SEXPR_MAX_DEPTH) {
    (void)fprintf(stderr,
                  "wok_sexpr: dump error: nesting exceeds %d at tag %s\n",
                  WOK_SEXPR_MAX_DEPTH, wok_node_desc[n->tag].tag);
    sink_put_str(sink, "(!depth)", 8);
    return;
  }

  const WokNodeDesc *d = &wok_node_desc[n->tag];
  sink_put_char(sink, '(');
  sink_put_str(sink, d->tag, strlen(d->tag));

  if (d->nfields == 0) {
    sink_put_char(sink, ')');
    return;
  }

  if (!tag_is_block(n->tag)) {
    for (u16 i = 0; i < d->nfields; i++) {
      sink_put_char(sink, ' ');
      render_field(sink, src, d->tag, d->fields[i].name, d->fields[i].cls,
                  n->slot[i], depth);
    }
    sink_put_char(sink, ')');
    return;
  }

  for (u16 i = 0; i < d->nfields; i++) {
    sink_put_char(sink, '\n');
    emit_indent(sink, depth + 1);
    render_field(sink, src, d->tag, d->fields[i].name, d->fields[i].cls,
                n->slot[i], depth + 1);
  }
  sink_put_char(sink, ')');
}

void wok_sexpr_dump(const WokNode *node, const char *src, FILE *out) {
  WokSexprSink sink = {.to_file = true, .file = out};
  render_node(&sink, src, node, 1);
  (void)fputc('\n', out);
}

char *wok_sexpr_dump_string(const WokNode *node, const char *src,
                            WokArena *arena) {
  WokSexprSink sink = {.to_file = false, .arena = arena};
  render_node(&sink, src, node, 1);
  sink_put_char(&sink, '\n');
  sink_reserve(&sink, 1);
  sink.buf[sink.len] = '\0';
  return sink.buf;
}

// =========================================================================
// read
// =========================================================================

// The decoded-text pool: NAME/TEXT spans in the returned tree index this,
// not the dump text (see wok_sexpr.h). Same doubling-in-the-arena growth as
// the dump-side sink above; kept separate because it holds decoded bytes
// under a different lifetime story (it outlives the read, the sink does
// not).
typedef struct {
  WokArena *arena;
  char *data;
  usize len, cap;
} WokByteBuf;

static void bytebuf_reserve(WokByteBuf *b, usize extra) {
  if (b->len + extra <= b->cap) return;
  usize new_cap = b->cap ? b->cap * 2 : 128;
  while (new_cap < b->len + extra) new_cap *= 2;
  char *grown = WOK_NEW_N(b->arena, char, new_cap);
  if (b->len) memcpy(grown, b->data, b->len);
  b->data = grown;
  b->cap = new_cap;
}

static void bytebuf_put(WokByteBuf *b, char c) {
  bytebuf_reserve(b, 1);
  b->data[b->len++] = c;
}

typedef struct {
  const char *text;
  usize n;
  usize pos;
  WokDiagSink *diag;
  WokArena *arena;
  WokByteBuf pool;
} WokReader;

static bool at_eof(const WokReader *r) { return r->pos >= r->n; }
static bool is_ws(char c) { return c == ' ' || c == '\t' || c == '\n' || c == '\r'; }
static bool is_delim(char c) { return c == '(' || c == ')' || c == '"' || is_ws(c); }

static void skip_ws(WokReader *r) {
  while (!at_eof(r) && is_ws(r->text[r->pos])) r->pos++;
}

static bool peek_is(WokReader *r, char c) {
  skip_ws(r);
  return !at_eof(r) && r->text[r->pos] == c;
}

static bool expect_char(WokReader *r, char c, const char *what) {
  skip_ws(r);
  if (at_eof(r)) {
    wok_diag_add(r->diag, WOK_E_LEX_UNTERMINATED, (u32)r->pos, 0,
                "unterminated %s: expected `%c`, found end of input", what,
                c);
    return false;
  }
  if (r->text[r->pos] != c) {
    wok_diag_add(r->diag, WOK_E_PARSE, (u32)r->pos, 0,
                "expected `%c`, found `%c`", c, r->text[r->pos]);
    return false;
  }
  r->pos++;
  return true;
}

// A maximal run of non-delimiter characters: a tag, `#t`/`#f`, `seq`,
// `some`, `none`, or a decimal literal. Returns false (no diagnostic) when
// the next character is itself a delimiter or EOF -- the caller knows the
// context and reports accordingly.
static bool read_word(WokReader *r, usize *out_off, usize *out_len) {
  skip_ws(r);
  usize start = r->pos;
  while (!at_eof(r) && !is_delim(r->text[r->pos])) r->pos++;
  usize len = r->pos - start;
  if (len == 0) return false;
  *out_off = start;
  *out_len = len;
  return true;
}

static bool word_eq(const WokReader *r, usize off, usize len,
                    const char *lit) {
  usize litlen = strlen(lit);
  return len == litlen && memcmp(r->text + off, lit, litlen) == 0;
}

static int hex_digit(char c) {
  if (c >= '0' && c <= '9') return c - '0';
  if (c >= 'a' && c <= 'f') return c - 'a' + 10;
  if (c >= 'A' && c <= 'F') return c - 'A' + 10;
  return -1;
}

// Decodes one quoted string literal at the current position, inverting
// render_string exactly. When pool is non-null the decoded bytes are
// appended there and *out_off/*out_len give the span into it; when pool is
// null the literal is only validated and skipped (used to count extra
// fields for a wrong-field-count diagnostic, where the decoded value is
// thrown away).
static bool read_string_lit(WokReader *r, WokByteBuf *pool, u32 *out_off,
                            u32 *out_len) {
  skip_ws(r);
  usize start = r->pos;
  if (!expect_char(r, '"', "string literal")) return false;

  usize pool_start = pool ? pool->len : 0;
  for (;;) {
    if (at_eof(r)) {
      wok_diag_add(r->diag, WOK_E_LEX_UNTERMINATED, (u32)start, 0,
                  "unterminated string literal");
      return false;
    }
    char c = r->text[r->pos];
    if (c == '"') {
      r->pos++;
      break;
    }
    if (c == '\\') {
      r->pos++;
      if (at_eof(r)) {
        wok_diag_add(r->diag, WOK_E_LEX_UNTERMINATED, (u32)start, 0,
                    "unterminated string literal");
        return false;
      }
      char e = r->text[r->pos];
      char decoded;
      switch (e) {
        case '\\':
          decoded = '\\';
          r->pos++;
          break;
        case '"':
          decoded = '"';
          r->pos++;
          break;
        case 'n':
          decoded = '\n';
          r->pos++;
          break;
        case 't':
          decoded = '\t';
          r->pos++;
          break;
        case 'r':
          decoded = '\r';
          r->pos++;
          break;
        case 'x': {
          r->pos++;
          if (r->pos + 2 > r->n) {
            wok_diag_add(r->diag, WOK_E_LEX_UNTERMINATED, (u32)start, 0,
                        "unterminated \\x escape in string literal");
            return false;
          }
          int hi = hex_digit(r->text[r->pos]);
          int lo = hex_digit(r->text[r->pos + 1]);
          if (hi < 0 || lo < 0) {
            wok_diag_add(r->diag, WOK_E_PARSE, (u32)r->pos, 0,
                        "invalid \\x escape in string literal");
            return false;
          }
          decoded = (char)((hi << 4) | lo);
          r->pos += 2;
          break;
        }
        default:
          wok_diag_add(r->diag, WOK_E_PARSE, (u32)r->pos, 0,
                      "unknown escape `\\%c` in string literal", e);
          return false;
      }
      if (pool) bytebuf_put(pool, decoded);
      continue;
    }
    if (pool) bytebuf_put(pool, c);
    r->pos++;
  }

  if (out_off) *out_off = (u32)pool_start;
  if (out_len) *out_len = pool ? (u32)(pool->len - pool_start) : 0;
  return true;
}

static bool read_uint_field(WokReader *r, u64 *out) {
  usize off, len;
  if (!read_word(r, &off, &len)) {
    if (at_eof(r)) {
      wok_diag_add(r->diag, WOK_E_LEX_UNTERMINATED, (u32)r->pos, 0,
                  "unterminated node: expected an integer field");
    } else {
      wok_diag_add(r->diag, WOK_E_PARSE, (u32)r->pos, 0,
                  "expected an integer field, found `%c`", r->text[r->pos]);
    }
    return false;
  }
  u64 v = 0;
  for (usize i = 0; i < len; i++) {
    char c = r->text[off + i];
    if (c < '0' || c > '9') {
      wok_diag_add(r->diag, WOK_E_PARSE, (u32)off, (u32)len,
                  "expected a decimal integer, found `%.*s`", (int)len,
                  r->text + off);
      return false;
    }
    u64 d = (u64)(c - '0');
    if (v > (UINT64_MAX - d) / 10) {
      wok_diag_add(r->diag, WOK_E_LEX_INT_RANGE, (u32)off, (u32)len,
                  "integer literal `%.*s` out of range", (int)len,
                  r->text + off);
      return false;
    }
    v = v * 10 + d;
  }
  *out = v;
  return true;
}

static bool read_flag_field(WokReader *r, bool *out) {
  usize off, len;
  if (!read_word(r, &off, &len)) {
    if (at_eof(r)) {
      wok_diag_add(r->diag, WOK_E_LEX_UNTERMINATED, (u32)r->pos, 0,
                  "unterminated node: expected `#t` or `#f`");
    } else {
      wok_diag_add(r->diag, WOK_E_PARSE, (u32)r->pos, 0,
                  "expected `#t` or `#f`, found `%c`", r->text[r->pos]);
    }
    return false;
  }
  if (word_eq(r, off, len, "#t")) {
    *out = true;
    return true;
  }
  if (word_eq(r, off, len, "#f")) {
    *out = false;
    return true;
  }
  wok_diag_add(r->diag, WOK_E_PARSE, (u32)off, (u32)len,
              "expected `#t` or `#f`, found `%.*s`", (int)len, r->text + off);
  return false;
}

static bool lookup_tag(const WokReader *r, usize off, usize len,
                       WokTag *out) {
  for (int t = 0; t < WOK_TAG_COUNT; t++) {
    const char *name = wok_node_desc[t].tag;
    usize nl = strlen(name);
    if (nl == len && memcmp(r->text + off, name, len) == 0) {
      *out = (WokTag)t;
      return true;
    }
  }
  return false;
}

static WokNode *parse_node(WokReader *r, u32 depth);

// Discards one opaque atom or balanced list, used only to keep counting
// fields after a node has already overrun its declared arity, so the
// "expected N, got M" diagnostic can name a real M instead of guessing.
static bool skip_one_form(WokReader *r) {
  skip_ws(r);
  if (at_eof(r)) {
    wok_diag_add(r->diag, WOK_E_LEX_UNTERMINATED, (u32)r->pos, 0,
                "unterminated list");
    return false;
  }
  char c = r->text[r->pos];
  if (c == '"') return read_string_lit(r, nullptr, nullptr, nullptr);
  if (c == '(') {
    usize start = r->pos;
    r->pos++;
    int nesting = 1;
    while (nesting > 0) {
      if (at_eof(r)) {
        wok_diag_add(r->diag, WOK_E_LEX_UNTERMINATED, (u32)start, 0,
                    "unterminated list");
        return false;
      }
      char cc = r->text[r->pos];
      if (cc == '"') {
        if (!read_string_lit(r, nullptr, nullptr, nullptr)) return false;
        continue;
      }
      if (cc == '(') nesting++;
      else if (cc == ')') nesting--;
      r->pos++;
    }
    return true;
  }
  if (c == ')') return false;
  usize off, len;
  return read_word(r, &off, &len);
}

static bool parse_opt(WokReader *r, u32 depth, WokNode **out) {
  skip_ws(r);
  usize off = r->pos;
  if (!expect_char(r, '(', "OPT field")) return false;

  usize woff, wlen;
  if (!read_word(r, &woff, &wlen)) {
    if (at_eof(r)) {
      wok_diag_add(r->diag, WOK_E_LEX_UNTERMINATED, (u32)off, 0,
                  "unterminated OPT field: expected `none` or `some`");
    } else {
      wok_diag_add(r->diag, WOK_E_PARSE, (u32)r->pos, 0,
                  "expected `none` or `some`");
    }
    return false;
  }
  if (word_eq(r, woff, wlen, "none")) {
    if (!expect_char(r, ')', "none")) return false;
    *out = nullptr;
    return true;
  }
  if (word_eq(r, woff, wlen, "some")) {
    WokNode *child = parse_node(r, depth + 1);
    if (!child) return false;
    if (!expect_char(r, ')', "some")) return false;
    *out = child;
    return true;
  }
  wok_diag_add(r->diag, WOK_E_PARSE, (u32)woff, (u32)wlen,
              "expected `none` or `some`, found `%.*s`", (int)wlen,
              r->text + woff);
  return false;
}

static bool parse_seq(WokReader *r, u32 depth, WokSeq *out) {
  skip_ws(r);
  usize off = r->pos;
  if (!expect_char(r, '(', "SEQ field")) return false;

  usize woff, wlen;
  if (!read_word(r, &woff, &wlen)) {
    if (at_eof(r)) {
      wok_diag_add(r->diag, WOK_E_LEX_UNTERMINATED, (u32)off, 0,
                  "unterminated SEQ field: expected `seq`");
    } else {
      wok_diag_add(r->diag, WOK_E_PARSE, (u32)r->pos, 0,
                  "expected `seq`");
    }
    return false;
  }
  if (!word_eq(r, woff, wlen, "seq")) {
    wok_diag_add(r->diag, WOK_E_PARSE, (u32)woff, (u32)wlen,
                "expected `seq`, found `%.*s`", (int)wlen, r->text + woff);
    return false;
  }

  WokNodeBuf buf;
  wok_buf_init(&buf, r->arena);
  for (;;) {
    if (peek_is(r, ')')) {
      r->pos++;
      break;
    }
    if (at_eof(r)) {
      wok_diag_add(r->diag, WOK_E_LEX_UNTERMINATED, (u32)r->pos, 0,
                  "unterminated seq");
      return false;
    }
    WokNode *child = parse_node(r, depth + 1);
    if (!child) return false;
    wok_buf_push(&buf, child);
  }
  *out = wok_buf_seq(&buf);
  return true;
}

static bool parse_field(WokReader *r, WokNode *node, u16 i,
                        WokFieldClass cls, u32 depth) {
  switch (cls) {
    case WFC_NODE: {
      WokNode *child = parse_node(r, depth + 1);
      if (!child) return false;
      node->slot[i] = WOK_MK_NODE(child);
      return true;
    }
    case WFC_OPT: {
      WokNode *child = nullptr;
      if (!parse_opt(r, depth, &child)) return false;
      node->slot[i] = WOK_MK_OPT(child);
      return true;
    }
    case WFC_SEQ: {
      WokSeq seq;
      if (!parse_seq(r, depth, &seq)) return false;
      node->slot[i] = WOK_MK_SEQ(seq);
      return true;
    }
    case WFC_NAME: {
      u32 off, len;
      if (!read_string_lit(r, &r->pool, &off, &len)) return false;
      node->slot[i] = WOK_MK_NAME(wok_span(off, len));
      return true;
    }
    case WFC_TEXT: {
      u32 off, len;
      if (!read_string_lit(r, &r->pool, &off, &len)) return false;
      node->slot[i] = WOK_MK_TEXT(wok_span(off, len));
      return true;
    }
    case WFC_INT: {
      u64 v;
      if (!read_uint_field(r, &v)) return false;
      node->slot[i] = WOK_MK_INT(v);
      return true;
    }
    case WFC_FLAG: {
      bool v;
      if (!read_flag_field(r, &v)) return false;
      node->slot[i] = WOK_MK_FLAG(v);
      return true;
    }
    case WOK_FIELD_CLASS_COUNT:
      break;
  }
  WOK_UNREACHABLE();
}

static WokNode *parse_node(WokReader *r, u32 depth) {
  if (depth > WOK_SEXPR_MAX_DEPTH) {
    wok_diag_add(r->diag, WOK_E_DEPTH, (u32)r->pos, 0,
                "s-expression nesting exceeds %d levels", WOK_SEXPR_MAX_DEPTH);
    return nullptr;
  }

  skip_ws(r);
  usize open_off = r->pos;
  if (!expect_char(r, '(', "node")) return nullptr;

  usize tag_off, tag_len;
  if (!read_word(r, &tag_off, &tag_len)) {
    if (at_eof(r)) {
      wok_diag_add(r->diag, WOK_E_LEX_UNTERMINATED, (u32)open_off, 0,
                  "unterminated node: missing tag");
    } else {
      wok_diag_add(r->diag, WOK_E_PARSE, (u32)r->pos, 0,
                  "expected a tag name after `(`");
    }
    return nullptr;
  }

  WokTag tag;
  if (!lookup_tag(r, tag_off, tag_len, &tag)) {
    wok_diag_add(r->diag, WOK_E_PARSE, (u32)tag_off, (u32)tag_len,
                "unknown tag `%.*s`", (int)tag_len, r->text + tag_off);
    return nullptr;
  }

  const WokNodeDesc *desc = &wok_node_desc[tag];
  WokNode *node = wok_node(r->arena, tag, 0, 0);

  for (u16 i = 0; i < desc->nfields; i++) {
    if (peek_is(r, ')')) {
      wok_diag_add(r->diag, WOK_E_PARSE, (u32)r->pos, 0,
                  "%s: expected %u fields, got %u", desc->tag,
                  (unsigned)desc->nfields, (unsigned)i);
      return nullptr;
    }
    if (at_eof(r)) {
      wok_diag_add(r->diag, WOK_E_LEX_UNTERMINATED, (u32)r->pos, 0,
                  "unterminated node `%s`", desc->tag);
      return nullptr;
    }
    if (!parse_field(r, node, i, desc->fields[i].cls, depth)) return nullptr;
  }

  if (!peek_is(r, ')')) {
    if (at_eof(r)) {
      wok_diag_add(r->diag, WOK_E_LEX_UNTERMINATED, (u32)r->pos, 0,
                  "unterminated node `%s`: missing `)`", desc->tag);
      return nullptr;
    }
    u16 extra = 0;
    while (!peek_is(r, ')') && !at_eof(r)) {
      if (!skip_one_form(r)) return nullptr;
      extra++;
    }
    if (at_eof(r)) {
      wok_diag_add(r->diag, WOK_E_LEX_UNTERMINATED, (u32)r->pos, 0,
                  "unterminated node `%s`: missing `)`", desc->tag);
      return nullptr;
    }
    wok_diag_add(r->diag, WOK_E_PARSE, (u32)r->pos, 0,
                "%s: expected %u fields, got %u", desc->tag,
                (unsigned)desc->nfields, (unsigned)(desc->nfields + extra));
    return nullptr;
  }
  r->pos++;  // consume ')'
  return node;
}

WokNode *wok_sexpr_read(const char *text, usize n, WokArena *arena,
                        WokDiagSink *diag, const char **out_src) {
  WokReader r = {.text = text,
                .n = n,
                .pos = 0,
                .diag = diag,
                .arena = arena,
                .pool = {.arena = arena}};

  WokNode *root = parse_node(&r, 1);
  if (root) {
    skip_ws(&r);
    if (!at_eof(&r)) {
      wok_diag_add(diag, WOK_E_PARSE, (u32)r.pos, 0,
                  "trailing content after the top-level form");
      root = nullptr;
    }
  }

  if (!root) {
    if (out_src) *out_src = nullptr;
    return nullptr;
  }

  bytebuf_reserve(&r.pool, 1);
  r.pool.data[r.pool.len] = '\0';
  if (out_src) *out_src = r.pool.data;
  return root;
}
