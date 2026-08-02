// Package wok implements a hand-written tokeniser and parser for the wok v2
// surface (docs/redesign/spec.md + docs/redesign/surface.md).
//
// It is deliberately small and readable: no generator, no generated state
// machine, no external dependencies. Fixed lexemes are single-sourced as data
// (see `fixed` below); everything else is a function named after the grammar
// production it implements, citing the spec section that fixes its shape.
package wok

import (
	"fmt"
	"maps"
	"strings"
)

// Kind classifies a token. Reserved symbols get their own kind so the parser
// never compares operator text; user operators stay in VarSym.
type Kind uint8

const (
	EOF Kind = iota

	VarId  // lowercase-or-underscore identifier: xs, sumList, _rest
	ConId  // uppercase identifier: State, U64, Cons
	VarSym // user operator: a run of symbol chars that is not reserved
	IntLit
	StrLit
	CharLit
	Keyword

	LParen
	RParen
	LBrack
	RBrack
	LBrace
	RBrace
	Comma
	Backtick
	Period // .   (named Period, not Dot: `Dot` is the AST node it builds)
	DotDot // ..
	Under

	Arrow    // ->
	FatArrow // =>
	Equals   // =
	Colon    // :
	Cons     // ::
	ColonEq  // :=
	Bar      // |
	Lambda   // backslash
)

// fixed lists every lexeme whose text is fixed by the language, in ONE place.
// The tables the scanner and the printer need are derived from it below, so
// adding a token means adding a Kind constant and one line here -- never
// three separate edits that can disagree.
//
// This is the part of Rust's logos that transfers to Go: the token
// definitions are data, single-sourced. What does NOT transfer is generating
// the matcher from them (no macros), which is why the scanner still reads as
// a switch rather than a state machine.
var fixed = []struct {
	Kind Kind
	Text string
}{
	{LParen, "("}, {RParen, ")"},
	{LBrack, "["}, {RBrack, "]"},
	{LBrace, "{"}, {RBrace, "}"},
	{Comma, ","}, {Backtick, "`"},
	{Period, "."}, {DotDot, ".."}, {Under, "_"},
	{Arrow, "->"}, {FatArrow, "=>"}, {Equals, "="},
	{Colon, ":"}, {Cons, "::"}, {ColonEq, ":="},
	{Bar, "|"}, {Lambda, `\`},
}

// Word is the interned identity of a lexeme whose SPELLING the grammar names:
// a reserved word, a contextual word, or an operator run that one production
// matches by name. The tokeniser resolves the spelling once, at scan time, so
// the parser compares an integer and never a string.
//
// That is the whole point of the type: `p.atWord(KwHanlde)` does not compile,
// where `p.atKw("hanlde")` compiled, ran, and was simply never true.
type Word uint8

const (
	NoWord Word = iota // the spelling carries no grammatical meaning

	// Reserved words, the ML skeleton. Kind == Keyword.
	KwModule
	KwImport
	KwAs
	KwType
	KwAlias
	KwClass
	KwInstance
	KwLet
	KwIn
	KwCase
	KwOf
	KwIf
	KwThen
	KwElse
	KwWhere

	// Reserved words, the law words. Kind == Keyword.
	KwEffect
	KwHandler
	KwHandle
	KwUse
	KwOnce
	KwReturn
	KwVar
	KwWith
	KwForeign
	KwExtern

	// Contextual words. Kind == VarId: they are ordinary identifiers
	// everywhere except the one production that reads them, which is what
	// lets `Bytes.copy` and a variable named `row` survive.
	CwOwn
	CwLend
	CwCopy
	CwEff
	CwRow

	// Named operator runs. Kind == VarSym: they stay USER operators, freely
	// redefinable, and only the productions below read them as fixed.
	OpMinus // prefix negation (parseApp) and a negative literal (parseAtomPat)
	OpPlus  // the row separator (parseRow)
)

// words is the single source for every named spelling AND for the kind the
// scanner emits it as. Three tables are derived from it below, so adding a
// word is one Word constant and one line here.
//
// The Kind column is what keeps the three registers apart without a second
// roster: Keyword means reserved (never a variable), VarId means contextual,
// VarSym means an operator run that stays a user operator.
var words = []struct {
	Word Word
	Text string
	Kind Kind
}{
	{KwModule, "module", Keyword}, {KwImport, "import", Keyword},
	{KwAs, "as", Keyword}, {KwType, "type", Keyword},
	{KwAlias, "alias", Keyword}, {KwClass, "class", Keyword},
	{KwInstance, "instance", Keyword}, {KwLet, "let", Keyword},
	{KwIn, "in", Keyword}, {KwCase, "case", Keyword},
	{KwOf, "of", Keyword}, {KwIf, "if", Keyword},
	{KwThen, "then", Keyword}, {KwElse, "else", Keyword},
	{KwWhere, "where", Keyword},

	{KwEffect, "effect", Keyword}, {KwHandler, "handler", Keyword},
	{KwHandle, "handle", Keyword}, {KwUse, "use", Keyword},
	{KwOnce, "once", Keyword}, {KwReturn, "return", Keyword},
	{KwVar, "var", Keyword}, {KwWith, "with", Keyword},
	{KwForeign, "foreign", Keyword}, {KwExtern, "extern", Keyword},

	{CwOwn, "own", VarId}, {CwLend, "lend", VarId}, {CwCopy, "copy", VarId},
	{CwEff, "eff", VarId}, {CwRow, "row", VarId},

	{OpMinus, "-", VarSym}, {OpPlus, "+", VarSym},
}

// removed lexemes carry a targeted diagnostic rather than "unexpected
// character": they are legal v1 wok, so a port will hit them.
var removed = map[rune]string{
	';': "v2 separates statements by layout, never by `;`",
}

// The open classes have no fixed text, so they name themselves.
var openClassName = map[Kind]string{
	EOF: "eof", VarId: "varid", ConId: "conid", VarSym: "varsym",
	IntLit: "int", StrLit: "string", CharLit: "char", Keyword: "keyword",
}

// punct is a single-character lexeme with the text to emit for it. The text
// comes from `fixed`, so it is a constant the token can point at -- rebuilding
// it with string(r) would allocate once per bracket in the file.
type punct struct {
	kind Kind
	text string
}

var (
	kindName    = map[Kind]string{} // every kind -> how to print it
	reservedSym = map[string]Kind{} // operator runs that are reserved
	punctuation = map[rune]punct{}  // single-character punctuation

	wordOf = map[string]Word{} // spelling -> its interned identity

	// Indexed BY the Word, which is a dense iota enum: reading a word's
	// spelling or its kind is an array index, never a hash. The scanner does
	// the latter for every identifier it reads.
	wordText []string // identity -> spelling, for diagnostics
	wordKind []Kind   // identity -> the kind it is emitted as
)

func init() {
	maps.Copy(kindName, openClassName)
	for _, f := range fixed {
		kindName[f.Kind] = f.Text
		switch {
		case f.Kind == Under: // `_` is scanned as an identifier, not punctuation
		case isSymChar(rune(f.Text[0])):
			reservedSym[f.Text] = f.Kind
		case len(f.Text) == 1 && f.Text != ".":
			punctuation[rune(f.Text[0])] = punct{kind: f.Kind, text: f.Text}
		}
	}
	last := NoWord
	for _, w := range words {
		if w.Word > last {
			last = w.Word
		}
	}
	wordText = make([]string, last+1)
	wordKind = make([]Kind, last+1)
	for _, w := range words {
		wordOf[w.Text] = w.Word
		wordText[w.Word] = w.Text
		wordKind[w.Word] = w.Kind
	}
}

func (k Kind) String() string {
	if s, ok := kindName[k]; ok {
		return s
	}
	return fmt.Sprintf("kind(%d)", uint8(k))
}

func (w Word) String() string {
	if int(w) < len(wordText) && wordText[w] != "" {
		return wordText[w]
	}
	if w == NoWord {
		return "no-word"
	}
	return fmt.Sprintf("word(%d)", uint8(w))
}

// Token is one lexeme with everything a later pass needs already decided.
//
//	Kind  the lexical class
//	Word  the interned spelling, for the lexemes the grammar names (NoWord
//	      otherwise) -- so the parser never compares Text
//	First the token opens its line: the ONE layout bit the offside rule needs
//	      (see parser.go, "the layout core"), decided here because the scanner
//	      already knows it and the parser would otherwise look backwards
//
// Line and Col are 1-based; Col is counted in runes. The three small fields
// lead so that they share one word of padding: a token stays the size it was
// before Word and First existed.
type Token struct {
	Kind  Kind
	Word  Word
	First bool
	Text  string
	Line  int
	Col   int
}

func (t Token) String() string {
	return fmt.Sprintf("%d:%d\t%s\t%q", t.Line, t.Col, t.Kind, t.Text)
}

// symChars are the characters an operator is built from. `.` is excluded (it
// is projection / qualification) and handled separately, as is `,`.
const symChars = "!#$%&*+/<=>?@\\^|-~:"

func isSymChar(r rune) bool { return strings.ContainsRune(symChars, r) }

// The identifier classes are deliberately ASCII, NOT unicode.IsLower and
// friends. `unicode.IsLower` would make `é` and `λ` legal identifier heads and
// `unicode.IsDigit` would accept Arabic-Indic digits that strconv then
// rejects -- widening the language by accident. grammar/Wok.cf's `lower` and
// `upper` are ASCII too, so this keeps v1 and v2 lexing the same names.
// Switching to Unicode identifiers is a language decision, made here in three
// lines if it is ever wanted.
func isLower(r rune) bool { return r >= 'a' && r <= 'z' }
func isUpper(r rune) bool { return r >= 'A' && r <= 'Z' }
func isDigit(r rune) bool { return r >= '0' && r <= '9' }

// identRune is the CONTINUATION set for identifiers. Note `-` is NOT here
// (unlike grammar/Wok.cf): dashes in names are what forced the v1 lexer to
// glue `-5` into a literal and made `1-2` lex as [1, -2]. Dropping them makes
// `-` a plain operator and negation a parser-level prefix form.
func identRune(r rune) bool {
	return isLower(r) || isUpper(r) || isDigit(r) || r == '_' || r == '\''
}
