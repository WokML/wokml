package wok

import (
	"strings"
	"testing"
	"unicode/utf8"
	"unsafe"
)

// kinds renders a token stream as "kind:text" pairs, EOF dropped.
func kinds(t *testing.T, src string) []string {
	t.Helper()
	toks, err := Tokenise("t.wok", src)
	if err != nil {
		t.Fatalf("tokenise: %v", err)
	}
	var out []string
	for _, tk := range toks {
		if tk.Kind == EOF {
			break
		}
		out = append(out, tk.Kind.String()+" "+tk.Text)
	}
	return out
}

func eq(t *testing.T, got []string, want ...string) {
	t.Helper()
	if len(got) != len(want) {
		t.Fatalf("got %v\nwant %v", got, want)
	}
	for i := range got {
		if got[i] != want[i] {
			t.Fatalf("token %d: got %q, want %q\n(full: %v)", i, got[i], want[i], got)
		}
	}
}

func TestOperatorsAreMaximalMunch(t *testing.T) {
	// A run of symbol characters is ONE token; the reserved table then decides
	// whether it gets a dedicated kind.
	eq(t, kinds(t, "a >>= b"), "varid a", "varsym >>=", "varid b")
	eq(t, kinds(t, "x :: xs"), "varid x", ":: ::", "varid xs")
	eq(t, kinds(t, "cur := x"), "varid cur", ":= :=", "varid x")
	eq(t, kinds(t, "s -> t"), "varid s", "-> ->", "varid t")
	eq(t, kinds(t, "a --> b"), "varid a", "varsym -->", "varid b")
}

func TestSubtractionIsNotAnIdentifier(t *testing.T) {
	// grammar/Wok.cf allows `-` inside identifiers, which is why `1-2` lexes
	// there as [1, -2]. Here `-` is always an operator.
	eq(t, kinds(t, "1-2"), "int 1", "varsym -", "int 2")
	eq(t, kinds(t, "a-b"), "varid a", "varsym -", "varid b")
}

func TestComments(t *testing.T) {
	eq(t, kinds(t, "a -- trailing\nb"), "varid a", "varid b")
	eq(t, kinds(t, "a {- one {- nested -} still -} b"), "varid a", "varid b")
	// Two dashes followed by a symbol character stay an operator.
	eq(t, kinds(t, "a --| b"), "varid a", "varsym --|", "varid b")
}

func TestKeywordsAndContextualWords(t *testing.T) {
	eq(t, kinds(t, "handle State = h"), "keyword handle", "conid State", "= =", "varid h")
	// own/lend/copy/eff/row are NOT reserved: `Bytes.copy` must survive.
	eq(t, kinds(t, "Bytes.copy b"), "conid Bytes", ". .", "varid copy", "varid b")
	eq(t, kinds(t, "row eff own"), "varid row", "varid eff", "varid own")
}

// The parser matches spellings by Word, so the tokeniser must attach one to
// every lexeme the grammar names -- and to nothing else. A contextual word
// keeps its kind (VarId) and carries the tag; an ordinary name carries NoWord.
func TestWordsAreInternedByTheTokeniser(t *testing.T) {
	for _, tc := range []struct {
		src  string
		kind Kind
		word Word
	}{
		{"handle", Keyword, KwHandle},
		{"where", Keyword, KwWhere},
		{"row", VarId, CwRow},
		{"copy", VarId, CwCopy},
		{"rows", VarId, NoWord},   // a longer name is not the word
		{"Row", ConId, NoWord},    // nor is its capitalisation
		{"-", VarSym, OpMinus},    // named, but still a user operator
		{"+", VarSym, OpPlus},     //
		{"-->", VarSym, NoWord},   // maximal munch first: this is one operator
		{"::", Cons, NoWord},      // a reserved symbol has its own kind instead
		{"xs", VarId, NoWord},     //
		{"_", Under, NoWord},      //
		{`"row"`, StrLit, NoWord}, // a spelling inside a literal is not a word
	} {
		toks, err := Tokenise("t.wok", tc.src)
		if err != nil {
			t.Errorf("tokenise %q: %v", tc.src, err)
			continue
		}
		if toks[0].Kind != tc.kind || toks[0].Word != tc.word {
			t.Errorf("%q lexed as %s/%s, want %s/%s",
				tc.src, toks[0].Kind, toks[0].Word, tc.kind, tc.word)
		}
	}
}

// The offside rule asks "does this token open its line?" for every argument
// and every block item, so the tokeniser answers it once, at scan time.
func TestFirstOnLineIsFlagged(t *testing.T) {
	src := "f x =\n  g y\n\n    z\n"
	toks, err := Tokenise("t.wok", src)
	if err != nil {
		t.Fatal(err)
	}
	want := []bool{true, false, false, true, false, true, true} // f x = / g y / z / EOF
	if len(toks) != len(want) {
		t.Fatalf("got %d tokens, want %d: %v", len(toks), len(want), toks)
	}
	for i, w := range want {
		if toks[i].First != w {
			t.Errorf("token %d (%s) First = %v, want %v", i, toks[i], toks[i].First, w)
		}
	}
	// The flag must agree with the positions it is derived from, on every
	// token: it is what the parser trusts instead of looking backwards.
	for i, tk := range toks {
		back := i == 0 || toks[i-1].Line != tk.Line
		if tk.First != back {
			t.Errorf("token %d (%s) First = %v but its line %s the previous token's",
				i, tk, tk.First, map[bool]string{true: "differs from", false: "equals"}[back])
		}
	}
}

// takeWhile measures a run in BYTES rather than decoding it, which is only
// sound because every predicate it is called with rejects non-ASCII -- and
// because none of them accepts a newline, which would desynchronise the line
// count. Both are pinned here.
func TestRunPredicatesAreASCII(t *testing.T) {
	preds := map[string]func(rune) bool{
		"identRune": identRune, "isSymChar": isSymChar, "isDigit": isDigit,
	}
	for name, pred := range preds {
		if pred('\n') || pred('\r') {
			t.Errorf("%s accepts a line break: a run may not cross lines", name)
		}
		for r := rune(utf8.RuneSelf); r <= 0x2FFF; r++ {
			if pred(r) {
				t.Fatalf("%s accepts U+%04X: takeWhile would cut the rune in half", name, r)
			}
		}
		for _, r := range []rune{0xFEFF, 0x1F600, 0x10FFFF, 'é', 'λ', '一'} {
			if pred(r) {
				t.Errorf("%s accepts U+%04X", name, r)
			}
		}
	}
}

// A token's Text is a SLICE OF THE SOURCE, not a copy: scanning a file
// allocates the token slice and nothing else, however many tokens it holds.
// That is what makes carrying Text around free, and it is easy to lose --
// `string(r)` for a bracket, or a strings.Builder for a literal that has no
// escape in it, quietly reintroduces one allocation per token.
func TestScanningAllocatesOnlyTheTokenSlice(t *testing.T) {
	for _, tc := range []struct{ what, unit string }{
		{"identifiers", "alpha beta gamma delta "},
		{"keywords", "let in case of if then else "},
		{"operators", "a >>= b <*> c :: d "},
		{"punctuation", "( ) [ ] { } , = : | "},
		{"int literals", "1 22 333 4444 "},
		{"string literals", `"alpha" "beta" `},
		{"char literals", "'a' 'b' "},
	} {
		src := strings.Repeat(tc.unit, 200)
		n := testing.AllocsPerRun(100, func() {
			if _, err := Tokenise("t.wok", src); err != nil {
				t.Fatal(err)
			}
		})
		// The slice is sized from the source length, so it grows at most
		// once or twice; anything beyond that is per-token allocation.
		if n > 4 {
			t.Errorf("%s: %.0f allocations for %d bytes -- the text is being copied, not sliced",
				tc.what, n, len(src))
		}
	}
}

// The escape-free literal is returned as source text; only a `\` forces a
// decoded copy. Both must produce the same string.
func TestLiteralsDecodeOnlyWhenEscaped(t *testing.T) {
	src := `"plain" "a\nb" 'x' '\t'`
	toks, err := Tokenise("t.wok", src)
	if err != nil {
		t.Fatal(err)
	}
	eq(t, kinds(t, src), "string plain", "string a\nb", "char x", "char \t")
	if unsafe.StringData(toks[0].Text) != unsafe.StringData(src[1:]) {
		t.Error("an escape-free string literal was copied instead of sliced")
	}
}

// Non-ASCII text still has to be positioned correctly: the column counts runes,
// so a multi-byte rune advances it by one.
func TestNonASCIIIsPositionedByRune(t *testing.T) {
	toks, err := Tokenise("t.wok", `"héllo" x`)
	if err != nil {
		t.Fatal(err)
	}
	if toks[1].Col != 9 {
		t.Errorf("token after a 5-rune string literal at col %d, want 9 (%v)", toks[1].Col, toks)
	}
}

func TestLiterals(t *testing.T) {
	eq(t, kinds(t, `"a\nb"`), "string a\nb")
	eq(t, kinds(t, `'x' '\n'`), "char x", "char \n")
	eq(t, kinds(t, "x' y'z"), "varid x'", "varid y'z")
}

func TestPositionsAreOneBased(t *testing.T) {
	toks, err := Tokenise("t.wok", "ab\n  cd")
	if err != nil {
		t.Fatal(err)
	}
	if toks[0].Line != 1 || toks[0].Col != 1 {
		t.Errorf("first token at %d:%d, want 1:1", toks[0].Line, toks[0].Col)
	}
	if toks[1].Line != 2 || toks[1].Col != 3 {
		t.Errorf("second token at %d:%d, want 2:3", toks[1].Line, toks[1].Col)
	}
}

func TestTabInIndentationIsRejected(t *testing.T) {
	// Under an offside rule a tab's width is an invisible disagreement.
	if _, err := Tokenise("t.wok", "a\n\tb"); err == nil {
		t.Fatal("expected an error for a tab in indentation")
	}
	if _, err := Tokenise("t.wok", "a\tb"); err != nil {
		t.Fatalf("a tab after a token is fine: %v", err)
	}
}

func TestUnterminatedLiterals(t *testing.T) {
	for _, src := range []string{`"abc`, `'a`, "{- open"} {
		if _, err := Tokenise("t.wok", src); err == nil {
			t.Errorf("expected an error for %q", src)
		}
	}
}
