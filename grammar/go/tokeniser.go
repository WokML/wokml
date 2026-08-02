package wok

import (
	"strings"
	"unicode/utf8"
)

// Tokenise turns source text into a token stream ending in EOF, reporting
// EVERY lexical fault rather than stopping at the first: three stray `;` in a
// file are three lines of report, not three runs.
//
// Recovery is the crudest rule available, which is what keeps the messages
// trustworthy: skip the offending character, or the rest of the line for a
// literal that never closes. Nothing is guessed.
//
// Layout is NOT handled here: no virtual braces or semicolons are inserted.
// What IS decided here is everything that depends on the source text, so the
// parser only ever reads fields of a token: its position, whether it opens its
// line (Token.First, which the offside rule in parser.go reads), and the
// interned identity of its spelling when the grammar names one (Token.Word).
func Tokenise(file, src string) ([]Token, error) {
	s := &scanner{collector: collector{file: file}, src: src, line: 1, col: 1}
	// One token per four bytes is the shape of real wok source; the slice then
	// grows at most once or twice on top of that.
	s.toks = make([]Token, 0, len(src)/4+1)
	s.run()
	return s.toks, s.errs.err()
}

type scanner struct {
	collector
	src  string
	off  int // byte offset of the next rune
	line int
	col  int

	lineHasToken bool // has a real token been emitted on this line yet?
	toks         []Token
}

func (s *scanner) fail(line, col int, format string, args ...any) {
	s.record(s.errorf(line, col, format, args...))
}

// skipLine drops the rest of the current line: the recovery for a literal
// that never closes.
func (s *scanner) skipLine() {
	for !s.atEOF() && s.peek(0) != '\n' {
		s.advance()
	}
}

func (s *scanner) atEOF() bool { return s.off >= len(s.src) }

// peek returns the rune n positions ahead (0 = the next rune), or 0 at EOF.
// Source is overwhelmingly ASCII, so the common byte is taken without a decode.
func (s *scanner) peek(n int) rune {
	off := s.off
	for ; n > 0; n-- {
		if off >= len(s.src) {
			return 0
		}
		if s.src[off] < utf8.RuneSelf {
			off++
			continue
		}
		_, w := utf8.DecodeRuneInString(s.src[off:])
		off += w
	}
	if off >= len(s.src) {
		return 0
	}
	if b := s.src[off]; b < utf8.RuneSelf {
		return rune(b)
	}
	r, _ := utf8.DecodeRuneInString(s.src[off:])
	return r
}

func (s *scanner) advance() rune {
	if s.atEOF() {
		return 0
	}
	r := rune(s.src[s.off])
	if r < utf8.RuneSelf {
		s.off++
	} else {
		var w int
		r, w = utf8.DecodeRuneInString(s.src[s.off:])
		s.off += w
	}
	if r == '\n' {
		s.line++
		s.col = 1
		s.lineHasToken = false
	} else {
		s.col++
	}
	return r
}

// mark records where the token about to be scanned BEGINS, including whether
// it opens its line. The scanner already tracks that (it is the tab check's
// flag), so recording it costs nothing here and saves the parser from looking
// back at the previous token for every layout decision.
func (s *scanner) mark() Token {
	return Token{Line: s.line, Col: s.col, First: !s.lineHasToken}
}

// emit completes a marked token. The Word is the interned spelling for the
// lexemes the grammar names, so the parser never has to compare Text.
func (s *scanner) emit(k Kind, text string, at Token) {
	at.Kind, at.Text = k, text
	s.toks = append(s.toks, at)
	s.lineHasToken = true
}

func (s *scanner) emitWord(k Kind, text string, w Word, at Token) {
	at.Word = w
	s.emit(k, text, at)
}

// takeWhile consumes the maximal run of characters satisfying pred, which must
// be an ASCII-ONLY predicate -- identRune, isSymChar and isDigit all are, and
// TestRunPredicatesAreASCII pins that. A byte >= 0x80 then always ends the run,
// so it can be measured in bytes with no decoding, and since none of the
// predicates accepts a newline the column advances by the byte count.
func (s *scanner) takeWhile(pred func(rune) bool) string {
	start := s.off
	for s.off < len(s.src) && s.src[s.off] < utf8.RuneSelf && pred(rune(s.src[s.off])) {
		s.off++
	}
	s.col += s.off - start
	return s.src[start:s.off]
}

// run is the whole scanner: skip layout-irrelevant text, then classify one
// token by its first rune. It never stops at the first fault -- each recovery
// consumes at least one character, so the loop always terminates.
func (s *scanner) run() {
	for !s.full {
		s.skipSpaceAndComments()
		if s.atEOF() {
			break
		}
		start := s.mark()
		r := s.peek(0)
		switch {
		case isLower(r) || r == '_':
			// One lookup answers both registers: a spelling whose word is
			// emitted as a Keyword is reserved, one emitted as a VarId is
			// contextual and stays an identifier carrying its tag, and an
			// unlisted spelling gets NoWord.
			text := s.takeWhile(identRune)
			w := wordOf[text]
			switch {
			case text == "_":
				s.emit(Under, text, start)
			case wordKind[w] == Keyword:
				s.emitWord(Keyword, text, w, start)
			default:
				s.emitWord(VarId, text, w, start)
			}

		case isUpper(r):
			s.emit(ConId, s.takeWhile(identRune), start)

		case isDigit(r):
			// Unsigned only. A leading `-` is a plain operator; negation is a
			// prefix form in the parser (see parseApp).
			s.emit(IntLit, s.takeWhile(isDigit), start)

		case isSymChar(r):
			// Maximal munch, then one table lookup: a run of dashes is a
			// comment, a run in the reserved table gets its own kind, and
			// everything else is a user operator -- tagged with its word when
			// a production names it (`-`, `+`).
			run := s.takeWhile(isSymChar)
			switch k, reserved := reservedSym[run]; {
			case isLineComment(run):
				s.skipLine()
			case reserved:
				s.emit(k, run, start)
			default:
				s.emitWord(VarSym, run, wordOf[run], start)
			}

		case r == '"':
			if text, ok := s.scanString(); ok {
				s.emit(StrLit, text, start)
			}

		case r == '\'':
			if text, ok := s.scanChar(); ok {
				s.emit(CharLit, text, start)
			}

		case r == '.':
			s.advance()
			if s.peek(0) == '.' {
				s.advance()
				s.emit(DotDot, "..", start)
			} else {
				s.emit(Period, ".", start)
			}

		default:
			if p, ok := punctuation[r]; ok {
				s.advance()
				s.emit(p.kind, p.text, start)
				continue
			}
			if hint, gone := removed[r]; gone {
				s.fail(start.Line, start.Col, "`%s` is not part of wok v2: %s", string(r), hint)
			} else {
				s.fail(start.Line, start.Col, "unexpected character %q", string(r))
			}
			s.advance() // recovery: drop the character and keep scanning
		}
	}
	s.emit(EOF, "", s.mark())
}

// skipSpaceAndComments consumes whitespace and nested `{- block -}` comments.
// `{-` is checked before `{` is ever treated as a record brace.
// Line comments are NOT handled here: `--` is a run of symbol characters, so
// the operator branch of run() recognises it (see isLineComment) and the
// symbol charset stays written down exactly once.
//
// A tab in a line's INDENTATION is an error: under an offside rule a tab's
// width is an invisible disagreement between editors.
func (s *scanner) skipSpaceAndComments() {
	for !s.atEOF() {
		r := s.peek(0)
		switch {
		case r == '\t' && !s.lineHasToken:
			s.fail(s.line, s.col, "tab in indentation: layout blocks are measured in spaces")
			s.advance() // recovery: treat it as one space and read on
		case r == ' ' || r == '\t' || r == '\r' || r == '\n':
			s.advance()
		case r == '{' && s.peek(1) == '-':
			s.skipBlockComment()
		default:
			return
		}
	}
}

// isLineComment reports whether a maximal operator run is really a comment:
// two or more dashes and nothing else. `-->` and `--|` are operators because
// their runs are not all dashes -- no second copy of the charset needed.
func isLineComment(run string) bool {
	return len(run) >= 2 && strings.Trim(run, "-") == ""
}

func (s *scanner) skipBlockComment() {
	line, col := s.line, s.col
	depth := 0
	for !s.atEOF() {
		switch {
		case s.peek(0) == '{' && s.peek(1) == '-':
			s.advance()
			s.advance()
			depth++
		case s.peek(0) == '-' && s.peek(1) == '}':
			s.advance()
			s.advance()
			depth--
			if depth == 0 {
				return
			}
		default:
			s.advance()
		}
	}
	s.fail(line, col, "unterminated block comment")
}

// scanString returns the decoded literal, or ok=false when it never closed --
// in which case the rest of the line is dropped and scanning continues on the
// next one.
//
// A literal with no escape in it IS a slice of the source, so it is returned
// as one: the overwhelmingly common case costs no allocation and no copy. The
// builder is reached for only once a `\` proves the text and the source differ.
func (s *scanner) scanString() (string, bool) {
	line, col := s.line, s.col
	s.advance() // opening quote
	start := s.off
	for {
		if s.atEOF() || s.peek(0) == '\n' {
			s.fail(line, col, "unterminated string literal")
			return "", false
		}
		if s.peek(0) == '\\' {
			break
		}
		if s.advance() == '"' {
			return s.src[start : s.off-1], true
		}
	}

	var b strings.Builder
	b.WriteString(s.src[start:s.off]) // everything up to the first escape
	for {
		if s.atEOF() || s.peek(0) == '\n' {
			s.fail(line, col, "unterminated string literal")
			return "", false
		}
		r := s.advance()
		switch r {
		case '"':
			return b.String(), true
		case '\\':
			e, ok := s.scanEscape()
			if !ok {
				s.skipLine()
				return "", false
			}
			b.WriteRune(e)
		default:
			b.WriteRune(r)
		}
	}
}

func (s *scanner) scanChar() (string, bool) {
	line, col := s.line, s.col
	s.advance() // opening quote
	if s.atEOF() || s.peek(0) == '\n' {
		s.fail(line, col, "unterminated character literal")
		return "", false
	}
	start := s.off
	text := ""
	if s.advance() == '\\' {
		e, ok := s.scanEscape()
		if !ok {
			s.skipLine()
			return "", false
		}
		text = string(e)
	} else {
		text = s.src[start:s.off] // an unescaped character is source text
	}
	if s.atEOF() || s.peek(0) == '\n' {
		s.fail(line, col, "unterminated character literal")
		return "", false
	}
	if s.peek(0) != '\'' {
		s.fail(line, col, "character literal must hold exactly one character")
		s.skipLine()
		return "", false
	}
	s.advance()
	return text, true
}

var escapes = map[rune]rune{
	'n': '\n', 't': '\t', 'r': '\r', '0': 0,
	'\\': '\\', '"': '"', '\'': '\'',
}

func (s *scanner) scanEscape() (rune, bool) {
	line, col := s.line, s.col
	r := s.advance()
	e, ok := escapes[r]
	if !ok {
		s.fail(line, col, "unknown escape %q", `\`+string(r))
		return 0, false
	}
	return e, true
}
