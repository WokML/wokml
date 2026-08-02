package wok

import "testing"

// The parser decides "can an argument / element / item start here?" with five
// hand-written FIRST-set predicates. Each is a list of token kinds, and a list
// is exactly the thing that rots when a kind is added: nothing fails to
// compile, the parser just quietly stops accepting something.
//
// These tests close that hole from two directions:
//
//	1. EXHAUSTIVE  every Kind must be classified below, so a new one fails
//	               here until someone decides what it starts
//	2. AGREEMENT   each predicate must agree with what the parser actually
//	               accepts, so a list cannot drift from the code it guards

// kindSample is a minimal COMPLETE snippet whose first token is that kind, so
// the tests drive the predicates with real tokens instead of another list.
var kindSample = map[Kind]string{
	EOF:     "",
	VarId:   "x",
	ConId:   "C",
	VarSym:  "+",
	IntLit:  "1",
	StrLit:  `"s"`,
	CharLit: "'c'",
	Keyword: "let",

	LParen:   "(x)",
	RParen:   ")",
	LBrack:   "[x]",
	RBrack:   "]",
	LBrace:   "{x = 1}",
	RBrace:   "}",
	Comma:    ",",
	Backtick: "`",
	Period:   ".",
	DotDot:   "..",
	Under:    "_",

	Arrow:    "->",
	FatArrow: "=>",
	Equals:   "=",
	Colon:    ":",
	Cons:     "::",
	ColonEq:  ":=",
	Bar:      "|",
	Lambda:   `\`,
}

// firstSets is the SPECIFICATION of what may begin each atom class, stated
// independently of the predicates that implement it.
//
//	expr  an argument in an application    (startsAtom)
//	pat   a binder or constructor argument (startsAtomPat)
//	typ   a type argument                  (startsTypeAtom)
//	decl  an item of a declaration block   (startsDecl)
var firstSets = map[Kind]struct{ expr, pat, typ, decl bool }{
	EOF:     {},
	VarId:   {expr: true, pat: true, typ: true, decl: true},
	ConId:   {expr: true, pat: true, typ: true},
	VarSym:  {}, // `-1` is a pattern by a rule beyond kind membership; see below
	IntLit:  {expr: true, pat: true},
	StrLit:  {expr: true, pat: true},
	CharLit: {expr: true, pat: true},
	Keyword: {decl: true}, // only the declaration keywords; see TestDeclKeywords

	LParen:   {expr: true, pat: true, typ: true, decl: true},
	RParen:   {},
	LBrack:   {expr: true, pat: true, typ: true},
	RBrack:   {},
	LBrace:   {}, // a record literal follows a constructor; it never starts one
	RBrace:   {},
	Comma:    {},
	Backtick: {},
	Period:   {},
	DotDot:   {},
	Under:    {pat: true},

	Arrow:    {},
	FatArrow: {},
	Equals:   {},
	Colon:    {},
	Cons:     {},
	ColonEq:  {},
	Bar:      {},
	Lambda:   {},
}

// probe builds a parser positioned at the start of src.
func probe(t *testing.T, src string) *parser {
	t.Helper()
	toks, err := Tokenise("t.wok", src)
	if err != nil {
		t.Fatalf("tokenise %q: %v", src, err)
	}
	return &parser{collector: collector{file: "t.wok"}, toks: toks}
}

// consumes reports whether parse succeeds AND swallows the whole sample --
// the honest test of "the parser really accepts something starting here".
func consumes(t *testing.T, src string, parse func(*parser)) (ok bool) {
	t.Helper()
	p := probe(t, src)
	defer func() {
		if recover() != nil {
			ok = false
		}
	}()
	parse(p)
	return p.at(EOF) && p.idx > 0
}

// declaredKinds returns every constant declared with type Kind, in declaration
// order -- so index i is Kind(i), the iota value. See declaredConsts for why
// this reads the source rather than a roster.
func declaredKinds(t *testing.T) []string {
	t.Helper()
	return declaredConsts(t, "token.go", "Kind")
}

// TestEveryKindIsClassified is the exhaustiveness gate. It enumerates the
// DECLARED constants, not the registered ones: a kind that was added and then
// registered nowhere is exactly the silent gap this has to catch.
func TestEveryKindIsClassified(t *testing.T) {
	declared := declaredKinds(t)
	for i, name := range declared {
		k := Kind(i)
		if _, ok := kindName[k]; !ok {
			t.Errorf("kind %s (=%d) has no name: add it to `fixed` or `openClassName`", name, i)
		}
		if _, ok := firstSets[k]; !ok {
			t.Errorf("kind %s (=%d) is not classified in firstSets", name, i)
		}
		if _, ok := kindSample[k]; !ok {
			t.Errorf("kind %s (=%d) has no sample in kindSample", name, i)
		}
	}
	// The reverse direction: a table naming a kind that no longer exists.
	for _, n := range []struct {
		what string
		size int
	}{{"kindName", len(kindName)}, {"firstSets", len(firstSets)}, {"kindSample", len(kindSample)}} {
		if n.size != len(declared) {
			t.Errorf("%s has %d entries but %d kinds are declared", n.what, n.size, len(declared))
		}
	}
}

// TestFirstSetPredicatesMatchTheSpec checks the implementations against the
// table, so the two can never drift apart unnoticed.
func TestFirstSetPredicatesMatchTheSpec(t *testing.T) {
	for k, want := range firstSets {
		src := kindSample[k]
		p := probe(t, src)
		if got := p.startsAtom(); got != want.expr {
			t.Errorf("startsAtom(%q) = %v, want %v", k, got, want.expr)
		}
		if got := p.startsAtomPat(); got != want.pat {
			t.Errorf("startsAtomPat(%q) = %v, want %v", k, got, want.pat)
		}
		if got := p.startsTypeAtom(); got != want.typ {
			t.Errorf("startsTypeAtom(%q) = %v, want %v", k, got, want.typ)
		}
		if k != Keyword { // keywords are filtered by text, not kind
			if got := p.startsDecl(); got != want.decl {
				t.Errorf("startsDecl(%q) = %v, want %v", k, got, want.decl)
			}
		}
	}
}

// TestFirstSetsAgreeWithTheParser is the load-bearing one: a predicate that
// says "yes" where the parser then fails produces a confusing error, and one
// that says "no" where the parser would have succeeded silently truncates an
// argument list. Either way the two must agree for EVERY token kind.
func TestFirstSetsAgreeWithTheParser(t *testing.T) {
	for k := range kindName {
		src := kindSample[k]

		if want, got := firstSets[k].expr, consumes(t, src, func(p *parser) { p.parseAtom() }); want != got {
			t.Errorf("kind %q: startsAtom says %v but parseAtom(%q) consumed=%v", k, want, src, got)
		}
		if want, got := firstSets[k].pat, consumes(t, src, func(p *parser) { p.parseAtomPat() }); want != got {
			t.Errorf("kind %q: startsAtomPat says %v but parseAtomPat(%q) consumed=%v", k, want, src, got)
		}
		if want, got := firstSets[k].typ, consumes(t, src, func(p *parser) { p.parseTypeAtom() }); want != got {
			t.Errorf("kind %q: startsTypeAtom says %v but parseTypeAtom(%q) consumed=%v", k, want, src, got)
		}
	}
}

// The rules that reach past kind membership, stated as cases rather than
// hidden in a predicate: a negative literal is a pattern, a bare operator is
// not.
func TestRulesBeyondKindMembership(t *testing.T) {
	for _, tc := range []struct {
		src  string
		want bool
	}{
		{"-1", true},  // a negative literal pattern
		{"-x", false}, // negation is an expression form, never a pattern
		{"+", false},
		{"+1", false},
	} {
		p := probe(t, tc.src)
		if got := p.startsAtomPat(); got != tc.want {
			t.Errorf("startsAtomPat(%q) = %v, want %v", tc.src, got, tc.want)
		}
		if tc.want && !consumes(t, tc.src, func(p *parser) { p.parseAtomPat() }) {
			t.Errorf("startsAtomPat(%q) is true but parseAtomPat does not consume it", tc.src)
		}
	}
}

// startsDecl filters keywords by WORD, so the declaration words are pinned
// here against the parseDecl switch they mirror -- in BOTH directions, driven
// by the reserved words the tokeniser actually emits.
func TestDeclKeywords(t *testing.T) {
	heads := map[Word]bool{
		KwModule: true, KwImport: true, KwType: true, KwAlias: true, KwEffect: true,
		KwClass: true, KwInstance: true, KwForeign: true, KwExtern: true,
	}
	seen := 0
	for _, w := range words {
		if w.Kind != Keyword {
			continue
		}
		seen++
		if got := probe(t, w.Text).startsDecl(); got != heads[w.Word] {
			t.Errorf("startsDecl(`%s`) = %v, want %v", w.Text, got, heads[w.Word])
		}
	}
	if seen == 0 {
		t.Fatal("no reserved words found in `words`")
	}
}
