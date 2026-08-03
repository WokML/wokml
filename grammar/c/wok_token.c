// wok_token -- the scanner.
//
// Scanning allocates the token vector and the comment vector and nothing else:
// a token's text is a view into the source, never a copy.

#include "wok_token.h"

#include "wok_utf8.h"

#include <string.h>

// ------------------------------------------------------------- rosters

static const char *const kind_names[] = {
#define WOK_X(name) #name,
    WOK_KINDS(WOK_X)
#undef WOK_X
};
static_assert(sizeof kind_names / sizeof *kind_names == WOK_KIND_COUNT,
              "every Kind needs a name");

WOK_READONLY const char *wok_kind_name(WokKind k) {
  return (unsigned)k < WOK_KIND_COUNT ? kind_names[k] : "<bad kind>";
}

static const struct {
  const char *text;
  unsigned char kind;
} word_tab[] = {
    [WW_NONE] = {"", WT_BAD},
#define WOK_X(name, text, kind) [name] = {text, kind},
    WOK_WORDS(WOK_X)
#undef WOK_X
};
static_assert(sizeof word_tab / sizeof *word_tab == WOK_WORD_COUNT,
              "every Word needs a spelling and an emitted kind");

WOK_READONLY const char *wok_word_text(WokWord w) {
  return (unsigned)w < WOK_WORD_COUNT ? word_tab[w].text : "";
}

WOK_READONLY WokKind wok_word_kind(WokWord w) {
  return (unsigned)w < WOK_WORD_COUNT ? (WokKind)word_tab[w].kind : WT_BAD;
}

// Identifier spellings, bucketed by length. Thirty-one words: a length switch
// resolves to one or two memcmps, which beats a hash table that would need
// mutable global state and therefore a lock in a parallel batch.
static WokWord word_of_ident(const char *s, u32 len) {
#define EQ(lit, w) \
  if (memcmp(s, lit, sizeof lit - 1) == 0) return w
  switch (len) {
    case 2:
      EQ("as", WW_AS);
      EQ("in", WW_IN);
      EQ("if", WW_IF);
      EQ("of", WW_OF);
      return WW_NONE;
    case 3:
      EQ("let", WW_LET);
      EQ("var", WW_VAR);
      EQ("use", WW_USE);
      EQ("own", WW_OWN);
      EQ("eff", WW_EFF);
      EQ("row", WW_ROW);
      return WW_NONE;
    case 4:
      EQ("type", WW_TYPE);
      EQ("case", WW_CASE);
      EQ("then", WW_THEN);
      EQ("else", WW_ELSE);
      EQ("with", WW_WITH);
      EQ("once", WW_ONCE);
      EQ("copy", WW_COPY);
      EQ("lend", WW_LEND);
      return WW_NONE;
    case 5:
      EQ("alias", WW_ALIAS);
      EQ("class", WW_CLASS);
      EQ("where", WW_WHERE);
      return WW_NONE;
    case 6:
      EQ("module", WW_MODULE);
      EQ("import", WW_IMPORT);
      EQ("effect", WW_EFFECT);
      EQ("handle", WW_HANDLE);
      EQ("return", WW_RETURN);
      EQ("extern", WW_EXTERN);
      return WW_NONE;
    case 7:
      EQ("foreign", WW_FOREIGN);
      EQ("handler", WW_HANDLER);
      return WW_NONE;
    case 8:
      EQ("instance", WW_INSTANCE);
      return WW_NONE;
    default:
      return WW_NONE;
  }
#undef EQ
}

// ------------------------------------------------- character classes
//
// The symbol charset is written ONCE, here, as a bitmap. Writing it a second
// time -- as the negated character class of a line-comment regexp, say -- is
// how `-->` silently becomes a comment when a character is added to one copy
// and not the other. The line-comment rule below takes the maximal run first
// and then asks whether it is all dashes, so there is no second copy.

#define BIT(c) (UINT64_C(1) << ((c) & 63))

static constexpr u64 CC_SYM_LO =  // bytes 0..63
    BIT('!') | BIT('#') | BIT('$') | BIT('%') | BIT('&') | BIT('*') |
    BIT('+') | BIT('-') | BIT('/') | BIT(':') | BIT('<') | BIT('=') |
    BIT('>') | BIT('?');
static constexpr u64 CC_SYM_HI =  // bytes 64..127
    BIT('@') | BIT('^') | BIT('|') | BIT('~');

WOK_PURE static bool is_sym(unsigned char c) {
  if (c < 64) return ((CC_SYM_LO >> c) & 1u) != 0;
  if (c < 128) return ((CC_SYM_HI >> (c - 64)) & 1u) != 0;
  return false;
}

// ASCII by decision, not by accident: `unicode.IsLower` would silently admit
// `e-acute` and `lambda` as identifier heads. Widening is three lines here and
// is a language decision, not a cleanup.
WOK_PURE static bool is_lower(unsigned char c) { return c >= 'a' && c <= 'z'; }
WOK_PURE static bool is_upper(unsigned char c) { return c >= 'A' && c <= 'Z'; }
WOK_PURE static bool is_digit(unsigned char c) { return c >= '0' && c <= '9'; }
WOK_PURE static bool is_ident_start(unsigned char c) {
  return is_lower(c) || is_upper(c) || c == '_';
}
WOK_PURE static bool is_ident_cont(unsigned char c) {
  return is_ident_start(c) || is_digit(c) || c == '\'';
}

// Exposed so test/test_charclass.c can check all 256 bytes against the
// readable definitions rather than trusting the bitmap.
bool wok_test_is_sym(unsigned char c) { return is_sym(c); }
bool wok_test_is_ident_start(unsigned char c) { return is_ident_start(c); }
bool wok_test_is_ident_cont(unsigned char c) { return is_ident_cont(c); }

WOK_PURE bool wok_kind_is_open_bracket(WokKind k) {
  return k == WT_LPAREN || k == WT_LBRACKET || k == WT_LBRACE;
}
WOK_PURE bool wok_kind_is_close_bracket(WokKind k) {
  return k == WT_RPAREN || k == WT_RBRACKET || k == WT_RBRACE;
}

WOK_READONLY bool wok_token_is_continuation_lead(const WokToken *t) {
  switch ((WokKind)t->kind) {
    // Every operator lead. No prefix operator exists except `-`, and a line
    // beginning with `-` is subtraction continuing the previous line -- the
    // same call v2 already made when it decided `1-2` is subtraction.
    case WT_VARSYM:
    case WT_ARROW:
    case WT_FATARROW:
    case WT_EQUALS:
    case WT_COLON:
    case WT_COLONCOLON:
    case WT_ASSIGN:
    case WT_BAR:
    case WT_COMMA:
    case WT_DOT:
    case WT_DOTDOT:
    case WT_BACKTICK:
    case WT_RPAREN:
    case WT_RBRACKET:
    case WT_RBRACE:
      return true;
    // Words that can never begin a block item.
    case WT_KEYWORD:
      switch ((WokWord)t->word) {
        case WW_WHERE:
        case WW_IN:
        case WW_THEN:
        case WW_ELSE:
        case WW_OF:
        case WW_AS:
        case WW_WITH:
          return true;
        case WW_NONE:
        case WW_MODULE:
        case WW_IMPORT:
        case WW_TYPE:
        case WW_ALIAS:
        case WW_CLASS:
        case WW_INSTANCE:
        case WW_LET:
        case WW_CASE:
        case WW_IF:
        case WW_EFFECT:
        case WW_HANDLER:
        case WW_HANDLE:
        case WW_USE:
        case WW_ONCE:
        case WW_RETURN:
        case WW_VAR:
        case WW_FOREIGN:
        case WW_EXTERN:
        case WW_OWN:
        case WW_LEND:
        case WW_COPY:
        case WW_ROW:
        case WW_EFF:
        case WW_PLUS:
        case WOK_WORD_COUNT:
          return false;
      }
      WOK_UNREACHABLE();
    case WT_EOF:
    case WT_NEWLINE:
    case WT_INDENT:
    case WT_DEDENT:
    case WT_VARID:
    case WT_CONID:
    case WT_INT:
    case WT_STRING:
    case WT_CHAR:
    case WT_LPAREN:
    case WT_LBRACKET:
    case WT_LBRACE:
    case WT_UNDERSCORE:
    case WT_LAMBDA:
    case WT_SEMI:
    case WT_BAD:
    case WOK_KIND_COUNT:
      return false;
  }
  WOK_UNREACHABLE();
}

// ------------------------------------------------------------- scanning

typedef struct {
  const char *src;
  usize n, i;
  u32 col;
  bool line_pending;
  bool tab_reported_this_line;
  WokToken *tok;
  usize ntok, captok;
  WokComment *com;
  usize ncom, capcom;
  WokArena *arena;
  WokDiagSink *diag;
} Scanner;

static void emit(Scanner *s, WokKind k, WokWord w, u32 off, u32 len,
                 u32 col, u16 extra) {
  if (s->ntok == s->captok) {
    usize next = s->captok ? s->captok * 2 : 256;
    WokToken *grown = WOK_NEW_N(s->arena, WokToken, next);
    if (s->ntok) memcpy(grown, s->tok, s->ntok * sizeof *grown);
    s->tok = grown;
    s->captok = next;
  }
  u16 flags = extra;
  if (s->line_pending) flags |= WOK_TF_FIRST_ON_LINE;
  s->tok[s->ntok++] = (WokToken){.off = off,
                                 .len = len,
                                 .col = col,
                                 .kind = (u8)k,
                                 .word = (u8)w,
                                 .flags = flags};
  s->line_pending = false;
}

static void add_comment(Scanner *s, u32 off, u32 len, bool block) {
  if (s->ncom == s->capcom) {
    usize next = s->capcom ? s->capcom * 2 : 32;
    WokComment *grown = WOK_NEW_N(s->arena, WokComment, next);
    if (s->ncom) memcpy(grown, s->com, s->ncom * sizeof *grown);
    s->com = grown;
    s->capcom = next;
  }
  s->com[s->ncom++] = (WokComment){.off = off, .len = len, .block = block};
}

static void advance(Scanner *s) {
  if (s->src[s->i] == '\n') {
    s->col = 1;
    s->line_pending = true;
    s->tab_reported_this_line = false;
  } else {
    s->col++;
  }
  s->i++;
}

static void advance_by(Scanner *s, usize k) {
  for (usize j = 0; j < k && s->i < s->n; j++) advance(s);
}

// Whole-buffer UTF-8 validation, once, up front. wok's String is flat
// valid-only UTF-8 (the Slice E design), so admitting an ill-formed literal
// here would push the fault all the way to the runtime.
// Validation happens HERE and only here: once, when the file is read.
// Everything downstream is UTF-8 clean by construction.
static void validate_utf8(const char *src, usize n, WokDiagSink *d) {
  const unsigned char *p = (const unsigned char *)src;
  usize i = 0;
  while (i < n) {
    usize bad = i + wok_utf8_find_invalid(p + i, n - i);
    if (bad >= n) break;
    wok_diag_add(d, WOK_E_LEX_UTF8, (u32)bad, 1,
                 "invalid UTF-8 at byte 0x%02x", p[bad]);
    i = bad + 1;  // resync one byte at a time
  }
}

// A nested block comment. `{- a {- b -} c -}` closes correctly.
static void skip_block_comment(Scanner *s) {
  u32 off = (u32)s->i;
  u32 depth = 0;
  while (s->i < s->n) {
    if (s->i + 1 < s->n && s->src[s->i] == '{' && s->src[s->i + 1] == '-') {
      depth++;
      advance_by(s, 2);
    } else if (s->i + 1 < s->n && s->src[s->i] == '-' &&
               s->src[s->i + 1] == '}') {
      depth--;
      advance_by(s, 2);
      if (depth == 0) break;
    } else {
      advance(s);
    }
  }
  if (depth != 0)
    wok_diag_add(s->diag, WOK_E_LEX_UNTERMINATED, off, 2,
                 "unterminated block comment");
  add_comment(s, off, (u32)s->i - off, true);
}

static void scan_literal(Scanner *s, char quote) {
  u32 off = (u32)s->i, col = s->col;
  u16 extra = 0;
  advance(s);
  bool closed = false;
  while (s->i < s->n && s->src[s->i] != '\n') {
    char c = s->src[s->i];
    if (c == '\\') {
      extra |= WOK_TF_HAS_ESCAPE;
      u32 esc = (u32)s->i;
      advance(s);
      if (s->i >= s->n) break;
      char e = s->src[s->i];
      if (e == '\\' || e == '"' || e == '\'' || e == 'n' || e == 't' ||
          e == 'r' || e == '0') {
        advance(s);
      } else if (e == 'x') {
        advance(s);
        int hex = 0;
        while (hex < 2 && s->i < s->n &&
               ((s->src[s->i] >= '0' && s->src[s->i] <= '9') ||
                (s->src[s->i] >= 'a' && s->src[s->i] <= 'f') ||
                (s->src[s->i] >= 'A' && s->src[s->i] <= 'F'))) {
          advance(s);
          hex++;
        }
        if (hex != 2)
          wok_diag_add(s->diag, WOK_E_LEX_STRAY, esc, 2,
                       "`\\x` needs exactly two hex digits");
      } else {
        // HEX, never the raw byte: a diagnostic message must not smuggle
        // source bytes into a UTF-8 context downstream.
        if ((unsigned char)e < 0x80 && e > 0x20)
          wok_diag_add(s->diag, WOK_E_LEX_STRAY, esc, 2,
                       "unknown escape `\\%c`", e);
        else
          wok_diag_add(s->diag, WOK_E_LEX_STRAY, esc, 2,
                       "unknown escape `\\x%02x`", (unsigned char)e);
        advance(s);
      }
      continue;
    }
    if (c == quote) {
      advance(s);
      closed = true;
      break;
    }
    advance(s);
  }
  if (!closed)
    wok_diag_add(s->diag, WOK_E_LEX_UNTERMINATED, off, 1,
                 "unterminated %s literal",
                 quote == '"' ? "string" : "character");
  emit(s, quote == '"' ? WT_STRING : WT_CHAR, WW_NONE, off,
       (u32)s->i - off, col, extra);
}

// A reserved operator run, recognised AFTER the maximal run is taken. Peeking
// at prefixes instead would make `->>` lex as `->` followed by `>`.
static WokKind reserved_sym(const char *s, u32 len) {
  if (len == 1) {
    switch (s[0]) {
      case '=': return WT_EQUALS;
      case ':': return WT_COLON;
      case '|': return WT_BAR;
      default: return WT_VARSYM;
    }
  }
  if (len == 2) {
    if (s[0] == '-' && s[1] == '>') return WT_ARROW;
    if (s[0] == '=' && s[1] == '>') return WT_FATARROW;
    if (s[0] == ':' && s[1] == ':') return WT_COLONCOLON;
    if (s[0] == ':' && s[1] == '=') return WT_ASSIGN;
  }
  return WT_VARSYM;
}

WokScanResult wok_scan(const char *src, usize src_len, WokArena *arena,
                       WokDiagSink *diag) {
  validate_utf8(src, src_len, diag);

  Scanner s = {.src = src,
               .n = src_len,
               .i = 0,
               .col = 1,
               .line_pending = true,
               .arena = arena,
               .diag = diag};
  // One token per four source bytes: a file is scanned without regrowth.
  s.captok = src_len / 4 + 16;
  s.tok = WOK_NEW_N(arena, WokToken, s.captok);

  while (s.i < s.n) {
    unsigned char c = (unsigned char)s.src[s.i];

    if (c == ' ' || c == '\n' || c == '\r') {
      advance(&s);
      continue;
    }
    if (c == '\t') {
      // A tab in indentation is an invisible disagreement between editors and
      // has no defensible width under an offside rule. Elsewhere it is fine.
      if (s.line_pending && !s.tab_reported_this_line) {
        wok_diag_add(diag, WOK_E_LEX_TAB, (u32)s.i, 1,
                     "tab in indentation; use spaces (a tab has no width "
                     "under the offside rule)");
        s.tab_reported_this_line = true;
      }
      advance(&s);
      continue;
    }
    if (c == '{' && s.i + 1 < s.n && s.src[s.i + 1] == '-') {
      skip_block_comment(&s);
      continue;
    }

    u32 off = (u32)s.i, col = s.col;

    if (is_sym(c)) {
      while (s.i < s.n && is_sym((unsigned char)s.src[s.i])) advance(&s);
      u32 len = (u32)s.i - off;
      bool all_dash = true;
      for (u32 k = 0; k < len; k++)
        if (s.src[off + k] != '-') all_dash = false;
      if (all_dash && len >= 2) {
        while (s.i < s.n && s.src[s.i] != '\n') advance(&s);
        add_comment(&s, off, (u32)s.i - off, false);
        continue;
      }
      WokKind k = reserved_sym(s.src + off, len);
      WokWord w = (len == 1 && s.src[off] == '+') ? WW_PLUS : WW_NONE;
      emit(&s, k, w, off, len, col, 0);
      continue;
    }

    switch (c) {
      case '_':
        // `_` alone is the wildcard; `_foo` is an ordinary name. A deliberate
        // fallthrough into the identifier arm, which C23 lets us state.
        if (!(s.i + 1 < s.n && is_ident_cont((unsigned char)s.src[s.i + 1]))) {
          advance(&s);
          emit(&s, WT_UNDERSCORE, WW_NONE, off, 1, col, 0);
          continue;
        }
        [[fallthrough]];
      case 'a': case 'b': case 'c': case 'd': case 'e': case 'f': case 'g':
      case 'h': case 'i': case 'j': case 'k': case 'l': case 'm': case 'n':
      case 'o': case 'p': case 'q': case 'r': case 's': case 't': case 'u':
      case 'v': case 'w': case 'x': case 'y': case 'z':
      case 'A': case 'B': case 'C': case 'D': case 'E': case 'F': case 'G':
      case 'H': case 'I': case 'J': case 'K': case 'L': case 'M': case 'N':
      case 'O': case 'P': case 'Q': case 'R': case 'S': case 'T': case 'U':
      case 'V': case 'W': case 'X': case 'Y': case 'Z': {
        bool upper = is_upper(c);
        while (s.i < s.n && is_ident_cont((unsigned char)s.src[s.i]))
          advance(&s);
        u32 len = (u32)s.i - off;
        // Case of the first character decides ConId vs VarId. spec 1.6's
        // governing invariant -- a capitalized name is never a fresh binder --
        // is a LEXICAL fact here, so no later pass inspects a first character.
        WokWord w = upper ? WW_NONE : word_of_ident(s.src + off, len);
        WokKind k = upper ? WT_CONID : (w ? wok_word_kind(w) : WT_VARID);
        emit(&s, k, w, off, len, col, 0);
        continue;
      }
      case '0': case '1': case '2': case '3': case '4':
      case '5': case '6': case '7': case '8': case '9': {
        while (s.i < s.n && (is_digit((unsigned char)s.src[s.i]) ||
                             s.src[s.i] == '_'))
          advance(&s);
        emit(&s, WT_INT, WW_NONE, off, (u32)s.i - off, col, 0);
        continue;
      }
      case '"':
      case '\'':
        scan_literal(&s, (char)c);
        continue;
      case '.': {
        advance(&s);
        if (s.i < s.n && s.src[s.i] == '.') {
          advance(&s);
          emit(&s, WT_DOTDOT, WW_NONE, off, 2, col, 0);
        } else {
          emit(&s, WT_DOT, WW_NONE, off, 1, col, 0);
        }
        continue;
      }
      case ';':
        advance(&s);
        emit(&s, WT_SEMI, WW_NONE, off, 1, col, 0);
        // Legal v1 wok that a port will hit, so it earns a real message
        // rather than "unexpected character" (D22).
        wok_diag_add(diag, WOK_E_LEX_SEMI, off, 1,
                     "v2 has no `;`: a block's items are delimited by columns "
                     "alone");
        continue;
      default:
        break;
    }

    WokKind k;
    switch (c) {
      case '(': k = WT_LPAREN; break;
      case ')': k = WT_RPAREN; break;
      case '[': k = WT_LBRACKET; break;
      case ']': k = WT_RBRACKET; break;
      case '{': k = WT_LBRACE; break;
      case '}': k = WT_RBRACE; break;
      case ',': k = WT_COMMA; break;
      case '`': k = WT_BACKTICK; break;
      case '\\': k = WT_LAMBDA; break;
      default: k = WT_BAD; break;
    }
    advance(&s);
    emit(&s, k, WW_NONE, off, 1, col, 0);
    if (k == WT_BAD)
      wok_diag_add(diag, WOK_E_LEX_STRAY, off, 1,
                   "stray byte 0x%02x in source", c);
  }

  emit(&s, WT_EOF, WW_NONE, (u32)s.n, 0, s.col, 0);
  return (WokScanResult){.tokens = {.tok = s.tok, .n = s.ntok},
                         .comments = s.com,
                         .ncomments = s.ncom};
}

// ------------------------------------------------------- literal values

bool wok_token_int_value(const char *src, const WokToken *t, WokDiagSink *diag,
                         u64 *out) {
  u64 acc = 0;
  bool overflow = false;
  for (u32 k = 0; k < t->len; k++) {
    char c = src[t->off + k];
    if (c == '_') continue;
#if WOK_HAVE_CKDINT
    // Integer literal conversion is where parsers get CVEs. This is a
    // defect-class elimination, not a stylistic improvement.
    overflow |= ckd_mul(&acc, acc, (u64)10);
    overflow |= ckd_add(&acc, acc, (u64)(c - '0'));
#else
    if (acc > (UINT64_MAX - (u64)(c - '0')) / 10) overflow = true;
    acc = acc * 10 + (u64)(c - '0');
#endif
  }
  if (overflow) {
    wok_diag_add(diag, WOK_E_LEX_INT_RANGE, t->off, t->len,
                 "integer literal does not fit in U64");
    *out = 0;
    return false;
  }
  *out = acc;
  return true;
}
