/// [TODO]: Is there a way to use an dependency to make json output instead we do it ourself?
/// [TODO]: Is using json the best here? Or we can use msgpack here?

// wok_diag -- batching diagnostic sink implementation. See wok_diag.h for
// the contract: item granularity, cascade suppression at an already-reported
// offset, and a hard cap with a single trailing E-TOO-MANY.

#include "wok_diag.h"

#include <stdarg.h>
#include <stdbool.h>
#include <string.h>

// One entry per WokDiagCode, in declaration order (the enum is generated
// from the same X-macro, so the indices line up).
#define WOK_X(name, text) [name] = text,
static const char *const wok_diag_text_table[] = {WOK_DIAG_CODES(WOK_X)};
#undef WOK_X

static_assert(sizeof(wok_diag_text_table) / sizeof(wok_diag_text_table[0]) ==
                  WOK_DIAG_CODE_COUNT,
              "wok_diag text table must have one entry per WokDiagCode");

WOK_READONLY const char *wok_diag_code_text(WokDiagCode code) {
  return wok_diag_text_table[code];
}

struct WokDiagSink {
  WokArena *arena;
  const char *path;
  const char *src;
  usize src_len;

  WokDiag *diags;
  usize count;
  usize capacity;

  bool has_last_off;
  u32 last_off;

  bool too_many_emitted;

  u32 *line_starts;  // lazily built; nullptr until first use
  usize line_count;
};

WokDiagSink *wok_diag_new(WokArena *arena, const char *path, const char *src,
                          usize src_len) {
  WokDiagSink *s = WOK_NEW(arena, WokDiagSink);
  s->arena = arena;
  s->path = path;
  s->src = src;
  s->src_len = src_len;
  s->diags = nullptr;
  s->count = 0;
  s->capacity = 0;
  s->has_last_off = false;
  s->last_off = 0;
  s->too_many_emitted = false;
  s->line_starts = nullptr;
  s->line_count = 0;
  return s;
}

static void wok_diag_grow(WokDiagSink *s) {
  if (s->count < s->capacity) return;

  usize new_capacity = s->capacity == 0 ? (usize)4 : s->capacity * 2;
  WokDiag *grown = WOK_NEW_N(s->arena, WokDiag, new_capacity);
  if (s->count > 0) memcpy(grown, s->diags, s->count * sizeof(WokDiag));
  s->diags = grown;
  s->capacity = new_capacity;
}

static void wok_diag_append(WokDiagSink *s, WokDiagCode code, u32 off,
                            u32 len, const char *msg) {
  wok_diag_grow(s);

  char *owned = wok_arena_copy(s->arena, msg, strlen(msg));
  s->diags[s->count] = (WokDiag){.code = code, .off = off, .len = len, .msg = owned};
  s->count += 1;
  s->has_last_off = true;
  s->last_off = off;
}

void wok_diag_add_text(WokDiagSink *s, WokDiagCode code, u32 off, u32 len,
                       const char *msg) {
  if (s->too_many_emitted) return;

  if (s->count >= WOK_DIAG_CAP) {
    s->too_many_emitted = true;
    wok_diag_append(s, WOK_E_TOO_MANY, off, 0, "too many errors; stopping here");
    return;
  }

  if (s->has_last_off && off == s->last_off) return;

  wok_diag_append(s, code, off, len, msg);
}

void wok_diag_add(WokDiagSink *s, WokDiagCode code, u32 off, u32 len,
                  const char *fmt, ...) {
  char buf[512];
  va_list ap;
  va_start(ap, fmt);
  (void)vsnprintf(buf, sizeof buf, fmt, ap);
  va_end(ap);

  wok_diag_add_text(s, code, off, len, buf);
}

usize wok_diag_count(const WokDiagSink *s) { return s->count; }

const WokDiag *wok_diag_at(const WokDiagSink *s, usize i) { return &s->diags[i]; }

bool wok_diag_full(const WokDiagSink *s) { return s->too_many_emitted; }

static void wok_diag_build_lines(WokDiagSink *s) {
  if (s->line_starts != nullptr) return;

  usize line_count = 1;
  for (usize i = 0; i < s->src_len; i++) {
    if (s->src[i] == '\n') line_count += 1;
  }

  u32 *starts = WOK_NEW_N(s->arena, u32, line_count);
  starts[0] = 0;
  usize idx = 1;
  for (usize i = 0; i < s->src_len; i++) {
    if (s->src[i] == '\n') {
      starts[idx] = (u32)(i + 1);
      idx += 1;
    }
  }

  s->line_starts = starts;
  s->line_count = line_count;
}

void wok_diag_position(const WokDiagSink *sink, u32 off, u32 *line,
                       u32 *col) {
  // The line table is a cache: build it on first use even though the sink
  // is observed through a const pointer here.
  WokDiagSink *s = (WokDiagSink *)sink;
  wok_diag_build_lines(s);

  // Rightmost line whose start is <= off. line_starts[0] == 0 always
  // satisfies this, so the search invariant holds from the first iteration;
  // an off past the end of the source simply resolves to the last line.
  usize lo = 0;
  usize hi = s->line_count;
  while (lo + 1 < hi) {
    usize mid = lo + (hi - lo) / 2;
    if (s->line_starts[mid] <= off) {
      lo = mid;
    } else {
      hi = mid;
    }
  }

  *line = (u32)(lo + 1);
  *col = off - s->line_starts[lo] + 1;
}

void wok_diag_render(const WokDiagSink *s, FILE *out) {
  for (usize i = 0; i < s->count; i++) {
    const WokDiag *d = &s->diags[i];
    u32 line;
    u32 col;
    wok_diag_position(s, d->off, &line, &col);
    // No code here, deliberately. The human-facing line stays
    // `file:line:col: message`, which is what an editor's error regex and a
    // reader both want; the machine-readable code is in the JSON Lines
    // renderer below, which is where a tool should be looking for it.
    (void)fprintf(out, "%s:%u:%u: %s\n", s->path, line, col, d->msg);
  }
}

// Emits a JSON string. It does NOT validate UTF-8: that happens once, when
// the source file is read, and every diagnostic message is built from ASCII
// literals plus text the scanner already validated. Two places used to break
// that invariant and both were fixed at the source rather than patched here --
// the scanner spelled an unknown escape with the raw byte, and the parser
// truncated a quoted token on a BYTE boundary, cutting characters in half on
// valid input. test/test_diag.c pins the invariant end to end.
static void wok_diag_json_string(FILE *out, const char *text) {
  (void)fputc('"', out);
  for (const unsigned char *p = (const unsigned char *)text; *p != 0; p++) {
    unsigned char c = *p;
    switch (c) {
      case '"': (void)fputs("\\\"", out); break;
      case '\\': (void)fputs("\\\\", out); break;
      case '\n': (void)fputs("\\n", out); break;
      case '\t': (void)fputs("\\t", out); break;
      case '\r': (void)fputs("\\r", out); break;
      default:
        if (c < 0x20) (void)fprintf(out, "\\u%04x", (unsigned int)c);
        else (void)fputc(c, out);
        break;
    }
  }
  (void)fputc('"', out);
}

void wok_diag_render_jsonl(const WokDiagSink *s, FILE *out) {
  for (usize i = 0; i < s->count; i++) {
    const WokDiag *d = &s->diags[i];
    u32 line;
    u32 col;
    wok_diag_position(s, d->off, &line, &col);

    (void)fputs("{\"file\":", out);
    wok_diag_json_string(out, s->path);
    (void)fprintf(out, ",\"line\":%u,\"col\":%u,\"code\":", line, col);
    wok_diag_json_string(out, wok_diag_code_text(d->code));
    (void)fputs(",\"message\":", out);
    wok_diag_json_string(out, d->msg);
    (void)fputs("}\n", out);  // one record per line: that is the format
  }
}
