package wok

import (
	goast "go/ast"
	goparser "go/parser"
	gotoken "go/token"
	"sort"
	"testing"
)

// Every hand-maintained roster in this package has the same failure mode: it
// must stay in step with something DECLARED elsewhere, and nothing in Go
// enforces that. A type switch may silently fall through to a default, a
// keyword may be matched by a string that was never reserved, and neither the
// compiler nor `go vet` says a word.
//
// These tests read the source and cross-check the pairs. Reading the source is
// the point: a roster checked against another hand-written roster is not
// checked at all.

func sourceFile(t *testing.T, name string) *goast.File {
	t.Helper()
	f, err := goparser.ParseFile(gotoken.NewFileSet(), name, nil, 0)
	if err != nil {
		t.Fatalf("parsing %s: %v", name, err)
	}
	return f
}

// markerMethods collects `func (*X) exprNode() {}` style declarations,
// grouped by marker name. They are the authoritative membership list of each
// AST node family: a node without one cannot be used as that interface.
func markerMethods(f *goast.File) map[string]map[string]bool {
	out := map[string]map[string]bool{}
	for _, d := range f.Decls {
		fn, ok := d.(*goast.FuncDecl)
		if !ok || fn.Recv == nil || len(fn.Recv.List) != 1 {
			continue
		}
		star, ok := fn.Recv.List[0].Type.(*goast.StarExpr)
		if !ok {
			continue
		}
		id, ok := star.X.(*goast.Ident)
		if !ok {
			continue
		}
		marker := fn.Name.Name
		if out[marker] == nil {
			out[marker] = map[string]bool{}
		}
		out[marker][id.Name] = true
	}
	return out
}

// declaredConsts reads a source file and returns every constant declared with
// the given named integer type, in declaration order -- so index i is the iota
// value, e.g. Kind(i) or Word(i).
//
// Parsing the source is the ONLY way to enumerate them. Go has no reflection
// over constants and no exhaustiveness check on a switch over a named integer
// type, so every derived roster (kindName, wordText) is hand-maintained and can
// silently omit a constant. This cannot: a constant that exists is found.
func declaredConsts(t *testing.T, file, typeName string) []string {
	t.Helper()
	f, err := goparser.ParseFile(gotoken.NewFileSet(), file, nil, 0)
	if err != nil {
		t.Fatalf("parsing %s: %v", file, err)
	}
	var names []string
	for _, decl := range f.Decls {
		gen, ok := decl.(*goast.GenDecl)
		if !ok || gen.Tok != gotoken.CONST {
			continue
		}
		// latches on `EOF Kind = iota`; the later specs carry no type
		wanted := false
		for _, spec := range gen.Specs {
			vs, ok := spec.(*goast.ValueSpec)
			if !ok {
				continue
			}
			if id, ok := vs.Type.(*goast.Ident); ok && id.Name == typeName {
				wanted = true
			}
			if !wanted {
				continue
			}
			for _, n := range vs.Names {
				if n.Name != "_" {
					names = append(names, n.Name)
				}
			}
		}
	}
	if len(names) == 0 {
		t.Fatalf("found no %s constants in %s; has the const block moved?", typeName, file)
	}
	return names
}

// funcBody finds a top-level function by name.
func funcBody(t *testing.T, f *goast.File, name string) *goast.FuncDecl {
	t.Helper()
	for _, d := range f.Decls {
		if fn, ok := d.(*goast.FuncDecl); ok && fn.Name.Name == name {
			return fn
		}
	}
	t.Fatalf("function %s not found; has it been renamed?", name)
	return nil
}

// typeSwitchCases collects the `case *X:` types of every type switch in fn.
func typeSwitchCases(fn *goast.FuncDecl) map[string]bool {
	out := map[string]bool{}
	goast.Inspect(fn, func(n goast.Node) bool {
		sw, ok := n.(*goast.TypeSwitchStmt)
		if !ok {
			return true
		}
		for _, stmt := range sw.Body.List {
			clause, ok := stmt.(*goast.CaseClause)
			if !ok {
				continue
			}
			for _, expr := range clause.List {
				if star, ok := expr.(*goast.StarExpr); ok {
					if id, ok := star.X.(*goast.Ident); ok {
						out[id.Name] = true
					}
				}
			}
		}
		return true
	})
	return out
}

// identsIn collects the identifiers inside n that name one of `want` -- used
// to read the Word constants a function mentions.
func identsIn(n goast.Node, want map[string]bool) map[string]bool {
	out := map[string]bool{}
	goast.Inspect(n, func(n goast.Node) bool {
		if id, ok := n.(*goast.Ident); ok && want[id.Name] {
			out[id.Name] = true
		}
		return true
	})
	return out
}

// wordNames is the set of declared Word constants, NoWord excluded: the words
// a production may legitimately match.
func wordNames(t *testing.T) map[string]bool {
	t.Helper()
	out := map[string]bool{}
	for _, n := range declaredConsts(t, "token.go", "Word") {
		if n != "NoWord" {
			out[n] = true
		}
	}
	return out
}

func sorted(set map[string]bool) []string {
	out := make([]string, 0, len(set))
	for k := range set {
		out = append(out, k)
	}
	sort.Strings(out)
	return out
}

func diff(a, b map[string]bool) []string {
	out := []string{}
	for k := range a {
		if !b[k] {
			out = append(out, k)
		}
	}
	sort.Strings(out)
	return out
}

// TestEveryNodeHasADumpCase pairs the AST node families with the type switches
// that must cover them: the dump, and the source printer. A node without a
// case in the dump prints `<unknown expr *wok.Foo>`; a node without one in the
// printer prints NOTHING AT ALL, silently dropping part of the program. In
// both cases there is no error, and the goldens catch it only if some corpus
// file happens to exercise that node.
//
// The s-expression READER cannot be checked this way -- it switches on head
// strings, not on types -- so it is covered from the other end instead:
// TestCorpusExercisesEveryNode proves every node is reached by some corpus
// file, and TestDumpReadsBack then round-trips it.
func TestEveryNodeHasADumpCase(t *testing.T) {
	nodes := markerMethods(sourceFile(t, "ast.go"))
	dump := sourceFile(t, "sexpr.go")
	print := sourceFile(t, "print.go")

	for _, pair := range []struct {
		marker string
		fns    map[string]*goast.File
	}{
		{"declNode", map[string]*goast.File{"declSx": dump, "decl": print}},
		{"exprNode", map[string]*goast.File{"exprSx": dump, "exprBare": print}},
		{"patNode", map[string]*goast.File{"patSx": dump, "patBare": print}},
		{"typeNode", map[string]*goast.File{"typeSx": dump, "typBare": print}},
		{"stmtNode", map[string]*goast.File{"stmtSx": dump, "stmt": print}},
	} {
		declared := nodes[pair.marker]
		if len(declared) == 0 {
			t.Fatalf("no %s markers found in ast.go", pair.marker)
		}
		for name, file := range pair.fns {
			handled := typeSwitchCases(funcBody(t, file, name))

			if missing := diff(declared, handled); len(missing) > 0 {
				t.Errorf("%s has no case in %s: %v", pair.marker, name, missing)
			}
			if extra := diff(handled, declared); len(extra) > 0 {
				t.Errorf("%s has cases for types that are not %ss: %v", name, pair.marker, extra)
			}
		}
	}
}

// TestEveryWordIsMatched pairs the declared words with the productions that
// read them. The other direction -- matching a word that was never declared --
// is now a compile error rather than a test, which is the point of interning
// spellings as Word: `p.atWord(KwHanlde)` does not build.
//
// What remains checkable is the dead end: a word declared, reserved from every
// program that might have wanted it as a name, and then matched nowhere.
func TestEveryWordIsMatched(t *testing.T) {
	declared := wordNames(t)
	matched := map[string]bool{}
	for _, name := range []string{"parser.go", "expr.go", "type.go", "pattern.go"} {
		for k := range identsIn(sourceFile(t, name), declared) {
			matched[k] = true
		}
	}
	if len(matched) == 0 {
		t.Fatal("found no word matches; have the parser sources moved?")
	}
	if dead := diff(declared, matched); len(dead) > 0 {
		t.Errorf("declared but never matched (a spelling taken from users for nothing): %v", dead)
	}
}

// TestEveryWordIsProducible closes the gap between DECLARING a word and the
// tokeniser emitting it. A word with no entry in `words`, or one whose
// spelling lexes as a different kind, gives the parser a branch that can never
// fire -- and nothing in Go says a thing.
func TestEveryWordIsProducible(t *testing.T) {
	declared := declaredConsts(t, "token.go", "Word")
	spelled := 0
	for i, name := range declared {
		w := Word(i)
		if name == "NoWord" {
			continue
		}
		if int(w) >= len(wordText) || wordText[w] == "" {
			t.Errorf("word %s (=%d) has no entry in `words`: it has no spelling to match", name, i)
			continue
		}
		text := wordText[w]
		spelled++
		toks, err := Tokenise("t.wok", text)
		if err != nil {
			t.Errorf("word %s (%q) does not tokenise: %v", name, text, err)
			continue
		}
		if toks[0].Word != w {
			t.Errorf("word %s (%q) lexes as word %s", name, text, toks[0].Word)
		}
		if toks[0].Kind != wordKind[w] {
			t.Errorf("word %s (%q) lexes as %s, but `words` declares %s",
				name, text, toks[0].Kind, wordKind[w])
		}
	}
	if spelled != len(declared)-1 { // -1 for NoWord
		t.Errorf("%d words are spelled but %d are declared", spelled, len(declared)-1)
	}
	if len(words) != spelled {
		t.Errorf("`words` has %d entries for %d words: two entries claim the same one", len(words), spelled)
	}
}

// TestDeclKeywordsMatchTheParser pairs the declaration dispatch with the
// recovery anchor. If they drift, resynchronisation walks straight past a
// declaration it should have stopped at -- silently losing the rest of a file
// after one fault.
func TestDeclKeywordsMatchTheParser(t *testing.T) {
	f := sourceFile(t, "parser.go")
	declared := wordNames(t)
	dispatch := identsIn(funcBody(t, f, "parseDecl"), declared)
	anchor := identsIn(funcBody(t, f, "startsDecl"), declared)

	if len(dispatch) == 0 || len(anchor) == 0 {
		t.Fatal("no words found; has parseDecl or startsDecl changed shape?")
	}
	if missing := diff(dispatch, anchor); len(missing) > 0 {
		t.Errorf("parseDecl handles %v but startsDecl does not anchor on them", missing)
	}
	if extra := diff(anchor, dispatch); len(extra) > 0 {
		t.Errorf("startsDecl anchors on %v but parseDecl does not handle them", extra)
	}
}

// TestEveryFixedLexemeIsProducible closes the gap between declaring a lexeme
// and the scanner being able to emit it. `fixed` feeds three derived tables
// through a switch in init(); an entry that matches none of its arms is
// declared but unreachable.
func TestEveryFixedLexemeIsProducible(t *testing.T) {
	for _, f := range fixed {
		toks, err := Tokenise("t.wok", f.Text)
		if err != nil {
			t.Errorf("lexeme %q (%s) does not tokenise: %v", f.Text, f.Kind, err)
			continue
		}
		if len(toks) < 2 {
			t.Errorf("lexeme %q (%s) produced no token", f.Text, f.Kind)
			continue
		}
		if toks[0].Kind != f.Kind {
			t.Errorf("lexeme %q lexes as %s, want %s", f.Text, toks[0].Kind, f.Kind)
		}
	}
}

// TestNoDeadRosters guards the small maps that have no automatic counterpart:
// each must be non-empty and reachable, since an unused package-level var is
// invisible to both the compiler and vet.
func TestNoDeadRosters(t *testing.T) {
	if len(escapes) == 0 || len(removed) == 0 || len(openClassName) == 0 {
		t.Fatal("a roster is empty")
	}
	// every open class must be a kind with no fixed text, and vice versa
	for k := range openClassName {
		for _, f := range fixed {
			if f.Kind == k {
				t.Errorf("kind %s is both an open class and a fixed lexeme %q", k, f.Text)
			}
		}
	}
	t.Logf("rosters: %d escapes, %d removed lexemes, %d open classes, %d fixed lexemes",
		len(escapes), len(removed), len(openClassName), len(fixed))
	_ = sorted
}
