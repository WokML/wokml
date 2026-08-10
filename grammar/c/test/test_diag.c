// The diagnostic sink, and specifically the JSON Lines renderer.
//
// Hand-writing JSON output is the right call -- we only ever WRITE, and the
// hard half of a JSON library is the parser. But it has one failure mode that
// produces INVALID output rather than ugly output, and that failure is
// reachable from ordinary source: a message may quote a RAW byte from the
// file. The scanner formats "unknown escape `\%c`", so a file containing
// `"\xFF"` puts 0xFF into the message, and a JSON string must be well-formed
// UTF-8. Found by feeding the CLI hostile files; pinned here.

// First, and deliberately: this suite uses fmemopen, and wok_base.h carries
// the POSIX feature-test macros that a system header would otherwise settle
// before we got a say. See the ordering rule there.
#include "wok_base.h"

#include <stdio.h>
#include <string.h>

#include "../wok_arena.h"
#include "../wok_diag.h"
#include "../wok_parse.h"
#include "check.h"

// Renders to memory so the bytes can be inspected.
static char *render_json(WokDiagSink *s, usize *n) {
  static char buf[8192];
  FILE *f = fmemopen(buf, sizeof buf, "w");
  if (!f) return nullptr;
  wok_diag_render_jsonl(s, f);
  fflush(f);
  long pos = ftell(f);
  fclose(f);
  if (pos < 0) return nullptr;
  *n = (usize)pos;
  buf[*n] = '\0';
  return buf;
}

// Is every byte part of a well-formed UTF-8 sequence?
static bool valid_utf8(const char *p, usize n) {
  usize i = 0;
  while (i < n) {
    unsigned char c = (unsigned char)p[i];
    usize need;
    if (c < 0x80) { i++; continue; }
    else if ((c & 0xE0) == 0xC0) need = 1;
    else if ((c & 0xF0) == 0xE0) need = 2;
    else if ((c & 0xF8) == 0xF0) need = 3;
    else return false;
    if (i + need >= n) return false;
    for (usize k = 1; k <= need; k++)
      if (((unsigned char)p[i + k] & 0xC0) != 0x80) return false;
    i += need + 1;
  }
  return true;
}

// A raw control byte INSIDE a record is a bug; the newline BETWEEN records is
// the format. So the check is per line.
static bool has_raw_control(const char *p, usize n) {
  for (usize i = 0; i < n; i++)
    if ((unsigned char)p[i] < 0x20 && p[i] != '\n') return true;
  return false;
}

// Every line must be a complete, self-contained record -- that is the whole
// promise of JSON Lines, and what makes truncation safe.
static bool every_line_is_a_record(const char *p, usize n) {
  usize i = 0;
  while (i < n) {
    usize j = i;
    while (j < n && p[j] != '\n') j++;
    if (j == i) return false;                       // no empty lines
    if (p[i] != '{' || p[j - 1] != '}') return false;
    if (p[i] == '[' ) return false;                 // never an array wrapper
    i = j + 1;
  }
  return true;
}

int main(void) {
  const char *src = "module M\n";

  // Escaping, on messages the code actually constructs.
  struct {
    const char *msg;
    const char *why;
  } nasty[] = {
      {"plain message", "the ordinary case"},
      {"has \"quotes\" in it", "a quote must be escaped"},
      {"has a \\ backslash", "a backslash must be escaped"},
      {"has\na newline", "a newline must not appear raw"},
      {"has\ta tab", "a tab must not appear raw"},
      {"valid caf\xC3\xA9 and \xE2\x9C\x93", "valid UTF-8 passes through"},
  };

  for (usize i = 0; i < sizeof nasty / sizeof *nasty; i++) {
    WokArena *a = wok_arena_new(1 << 14);
    WokDiagSink *d = wok_diag_new(a, "f.wok", src, strlen(src));
    wok_diag_add(d, WOK_E_PARSE, 0, 1, "%s", nasty[i].msg);
    usize n = 0;
    char *out = render_json(d, &n);
    CHECK(out != nullptr, "%s: render failed", nasty[i].why);
    if (out) {
      CHECK(valid_utf8(out, n), "%s: output is not valid UTF-8:\n    %s",
            nasty[i].why, out);
      CHECK(!has_raw_control(out, n),
            "%s: a record contains a raw control byte:\n    %s",
            nasty[i].why, out);
      CHECK(every_line_is_a_record(out, n),
            "%s: output is not well-formed JSON Lines:\n    %s",
            nasty[i].why, out);
    }
    wok_arena_free(a);
  }

  // THE INVARIANT, end to end. The writer no longer validates UTF-8 -- that
  // happens once, on read -- so what must hold is that no diagnostic message
  // ever carries a raw source byte. Both places that broke it are fixed at
  // the source: the scanner spelled an unknown escape with the offending
  // byte, and the parser truncated a quoted token on a BYTE boundary, which
  // cut characters in half ON VALID INPUT. These drive the real pipeline.
  {
    struct {
      const char *source;
      const char *why;
    } files[] = {
        {"module M\nf = \"\\\xFF\"\n", "an unknown escape whose byte is not ASCII"},
        {"module M\nf = \"\xC3\x28\"\n", "an invalid UTF-8 sequence in a literal"},
        {"module M\nf : \"\xCE\xB1\xCE\xB1\xCE\xB1\xCE\xB1\xCE\xB1\xCE\xB1\xCE\xB1"
         "\xCE\xB1\xCE\xB1\xCE\xB1\xCE\xB1\xCE\xB1\xCE\xB1\xCE\xB1\xCE\xB1\xCE\xB1"
         "\xCE\xB1\xCE\xB1\xCE\xB1\xCE\xB1\xCE\xB1\xCE\xB1\"\n",
         "a VALID non-ASCII token past the 40-byte quote cap"},
        {"module M\nf = 1 ; g = 2\n", "an ordinary lexical fault"},
        {"module M\n\tf = 1\n", "a tab in indentation"},
    };
    for (usize i = 0; i < sizeof files / sizeof *files; i++) {
      WokArena *a = wok_arena_new(1 << 16);
      usize sn = strlen(files[i].source);
      WokDiagSink *d = wok_diag_new(a, "f.wok", files[i].source, sn);
      wok_parse_source(files[i].source, sn, a, d);
      usize n = 0;
      char *out = render_json(d, &n);
      CHECK(out != nullptr, "%s: render failed", files[i].why);
      if (out) {
        CHECK(valid_utf8(out, n),
              "%s: a message carried a raw source byte:\n    %s",
              files[i].why, out);
        CHECK(every_line_is_a_record(out, n),
              "%s: not well-formed JSON Lines:\n    %s", files[i].why, out);
      }
      wok_arena_free(a);
    }
  }

  // Valid UTF-8 must pass through as ITSELF, not as \u escapes -- escaping
  // every byte >= 0x80 individually would turn one `e-acute` into two
  // mojibake escapes, which is worse than the bug it would be fixing.
  {
    WokArena *a = wok_arena_new(1 << 14);
    WokDiagSink *d = wok_diag_new(a, "f.wok", src, strlen(src));
    wok_diag_add(d, WOK_E_PARSE, 0, 1, "caf\xC3\xA9");
    usize n = 0;
    char *out = render_json(d, &n);
    CHECK(out && strstr(out, "caf\xC3\xA9") != nullptr,
          "valid UTF-8 was mangled instead of passed through:\n    %s",
          out ? out : "(null)");
    wok_arena_free(a);
  }

  // The cap, and cascade suppression, both reachable from the JSON path.
  {
    WokArena *a = wok_arena_new(1 << 14);
    WokDiagSink *d = wok_diag_new(a, "f.wok", src, strlen(src));
    for (u32 i = 0; i < 100; i++)
      wok_diag_add(d, WOK_E_PARSE, i, 1, "fault %u", i);
    CHECK(wok_diag_count(d) == WOK_DIAG_CAP + 1,
          "the cap must hold: %zu stored", wok_diag_count(d));
    CHECK(wok_diag_at(d, wok_diag_count(d) - 1)->code == WOK_E_TOO_MANY,
          "the last diagnostic past the cap must be E-TOO-MANY");
    usize n = 0;
    char *out = render_json(d, &n);
    CHECK(out && valid_utf8(out, n), "capped output must still be valid");
    CHECK(out && every_line_is_a_record(out, n),
          "21 capped records must still be 21 well-formed lines");
    wok_arena_free(a);
  }
  {
    WokArena *a = wok_arena_new(1 << 14);
    WokDiagSink *d = wok_diag_new(a, "f.wok", src, strlen(src));
    wok_diag_add(d, WOK_E_PARSE, 3, 1, "first");
    wok_diag_add(d, WOK_E_PARSE, 3, 1, "second at the same position");
    CHECK(wok_diag_count(d) == 1,
          "a cascade at one position must be suppressed: %zu stored",
          wok_diag_count(d));
    wok_arena_free(a);
  }

  TEST_DONE();
}
