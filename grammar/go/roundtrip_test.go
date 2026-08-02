package wok

import (
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

// The s-expression is the CANONICAL IDENTITY of a program, and `Format` is its
// canonical spelling. Four properties make that a claim a test can settle
// rather than a design intention, and each one fails for a different reason:
//
//	Dump(Read(Dump(t))) == Dump(t)        the dump is FAITHFUL: nothing the
//	                                      parser recorded is lost by writing it
//	Dump(Parse(Format(t))) == Dump(t)     printing is SOUND: the source it
//	                                      prints parses back to the same tree
//	Format(Parse(Format(t))) == Format(t) printing is a FIXED POINT: running
//	                                      the formatter twice changes nothing
//	every node is exercised                the three above only prove something
//	                                      about nodes some corpus file reaches
//
// The first is what makes the dump an interchange form. The second is what
// makes the printer safe to run over a file: a break in the wrong place under
// an offside rule does not produce a syntax error, it produces a DIFFERENT
// PROGRAM, and only comparing trees catches that. The third is what "canonical"
// means operationally, and is the linter's whole contract.

func parseCorpusFile(t *testing.T, path string) *File {
	t.Helper()
	src, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	f, err := Parse(path, string(src))
	if err != nil {
		t.Fatalf("%v", err)
	}
	return f
}

// TestDumpReadsBack pins that the dump loses nothing. A field the dump forgets
// -- a `once` continuation, whether a label was capitalized, whether a record
// pattern was open -- reappears here as a diff, where it would otherwise only
// show up as a wrong program much later.
func TestDumpReadsBack(t *testing.T) {
	for name, path := range corpus(t) {
		t.Run(name, func(t *testing.T) {
			want := Dump(parseCorpusFile(t, path))
			back, err := Read(name+".sexp", want)
			if err != nil {
				t.Fatalf("reading the dump back: %v", err)
			}
			if got := Dump(back); got != want {
				t.Errorf("dump -> read -> dump differs.\n--- got ---\n%s\n--- want ---\n%s", got, want)
			}
		})
	}
}

// TestFormatPreservesTheTree is the safety property for the printer. Under an
// offside rule a misplaced line break is not a syntax error: it silently makes
// a block out of an expression, or ends one early. Comparing the TREES is the
// only way to see that; comparing the text would pass.
func TestFormatPreservesTheTree(t *testing.T) {
	for name, path := range corpus(t) {
		t.Run(name, func(t *testing.T) {
			f := parseCorpusFile(t, path)
			want := Dump(f)
			out := Format(f)

			back, err := Parse(name+".fmt.wok", out)
			if err != nil {
				t.Fatalf("formatted output does not parse: %v\n--- output ---\n%s", err, out)
			}
			if got := Dump(back); got != want {
				t.Errorf("formatting changed the tree.\n--- output ---\n%s\n--- got ---\n%s\n--- want ---\n%s",
					out, got, want)
			}
		})
	}
}

// TestFormatIsIdempotent is what "canonical" means: one program, one spelling.
// It is also the linter's contract -- `Format(src) != src` may only mean "not
// yet formatted", never "formatted differently this time".
func TestFormatIsIdempotent(t *testing.T) {
	for name, path := range corpus(t) {
		t.Run(name, func(t *testing.T) {
			once := Format(parseCorpusFile(t, path))
			f, err := Parse(name+".fmt.wok", once)
			if err != nil {
				t.Fatalf("formatted output does not parse: %v", err)
			}
			if twice := Format(f); twice != once {
				t.Errorf("formatting is not a fixed point.\n--- once ---\n%s\n--- twice ---\n%s", once, twice)
			}
		})
	}
}

// TestFormatRoundTripsThroughTheDump is the whole pipeline in one line:
// source -> tree -> s-expression -> tree -> source. It is the path a tool that
// rewrites the IR actually takes, and it is not implied by the parts -- each
// half could lose a different field and the halves still pass alone.
func TestFormatRoundTripsThroughTheDump(t *testing.T) {
	for name, path := range corpus(t) {
		t.Run(name, func(t *testing.T) {
			want := Format(parseCorpusFile(t, path))
			back, err := Read(name+".sexp", Dump(parseCorpusFile(t, path)))
			if err != nil {
				t.Fatal(err)
			}
			if got := Format(back); got != want {
				t.Errorf("source rebuilt from the dump differs.\n--- got ---\n%s\n--- want ---\n%s", got, want)
			}
		})
	}
}

// TestGoldenFormat pins what the formatter actually chooses, so a change in
// layout is reviewed rather than discovered. Refresh with
//
//	go test -run Golden -update
func TestGoldenFormat(t *testing.T) {
	for name, path := range corpus(t) {
		t.Run(name, func(t *testing.T) {
			got := Format(parseCorpusFile(t, path))
			gold := filepath.Join("testdata", "golden", name+".fmt.wok")
			if *update {
				if err := os.WriteFile(gold, []byte(got), 0o644); err != nil {
					t.Fatal(err)
				}
				return
			}
			want, err := os.ReadFile(gold)
			if err != nil {
				t.Fatalf("%v (run: go test -run Golden -update)", err)
			}
			if got != string(want) {
				t.Errorf("formatting changed.\n--- got ---\n%s\n--- want ---\n%s", got, want)
			}
		})
	}
}

// TestCorpusExercisesEveryNode is what gives the properties above their reach.
// They only say something about nodes some corpus file actually contains, and
// nothing in Go reports a node type that is never constructed -- so the check
// is made against the trees themselves, by reflection, rather than against a
// list somebody has to remember to extend.
//
// A failure here is not a bug in the printer: it means testdata/surface-tour.wok
// stopped covering a form, and every property above is silent about it.
func TestCorpusExercisesEveryNode(t *testing.T) {
	seen := map[string]bool{}
	for _, path := range corpus(t) {
		walkNodes(reflect.ValueOf(parseCorpusFile(t, path)), seen)
	}

	declared := markerMethods(sourceFile(t, "ast.go"))
	all := map[string]bool{}
	for _, family := range declared {
		for name := range family {
			all[name] = true
		}
	}
	if missing := diff(all, seen); len(missing) > 0 {
		t.Errorf("no corpus file contains these nodes, so nothing round-trips them: %v\n"+
			"add the form to testdata/surface-tour.wok", missing)
	}
}

// walkNodes records the concrete type name of every AST node reachable from v.
// It walks values rather than source, so a node counts only once some file
// really produced it.
func walkNodes(v reflect.Value, seen map[string]bool) {
	switch v.Kind() {
	case reflect.Interface:
		if !v.IsNil() {
			walkNodes(v.Elem(), seen)
		}
	case reflect.Pointer:
		if v.IsNil() {
			return
		}
		if name := v.Type().Elem().Name(); name != "" {
			seen[name] = true
		}
		walkNodes(v.Elem(), seen)
	case reflect.Slice:
		for i := range v.Len() {
			walkNodes(v.Index(i), seen)
		}
	case reflect.Struct:
		for i := range v.NumField() {
			walkNodes(v.Field(i), seen)
		}
	}
}

// TestReadRejectsAMalformedDump pins that the reader FAILS on a dump it does
// not understand. Reading is the one place a guess would be invisible: a
// silently dropped element becomes a different program with no diagnostic, and
// the round-trip tests above would still pass on every dump the dumper writes.
func TestReadRejectsAMalformedDump(t *testing.T) {
	cases := []struct{ name, sexp, want string }{
		{"unknown declaration", "(fun main (params) 1)", "unknown declaration `fun`"},
		{"unknown expression", "(def f (params) (frobnicate 1))", "unknown expression `frobnicate`"},
		{"unknown pattern", "(def f (params (pvar x)) 1)", "unknown pattern `pvar`"},
		{"unknown type", "(sig (names f) (fn a b))", "unknown type `fn`"},
		{"missing element", "(def f (params))", "needs at least 3"},
		{"wrong tag", "(def f (args) 1)", "expected a `(params ...)` list"},
		{"untagged label", "(def f (params) (block (handle st h)))", "expected a label"},
		{"unterminated list", "(def f (params) 1", "unterminated list"},
		{"stray close", "(def f (params) 1))", "unexpected `)`"},
		{"quoted head", `("def" f (params) 1)`, "must begin with a bare head atom"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			_, err := Read("bad.sexp", c.sexp)
			if err == nil {
				t.Fatalf("Read accepted %q", c.sexp)
			}
			if !strings.Contains(err.Error(), c.want) {
				t.Errorf("Read(%q) = %v, want a message containing %q", c.sexp, err, c.want)
			}
		})
	}
}

// TestFormatBreaksLongForms exercises the break paths, which the corpus does
// not reach -- every file in it fits the margin, so `Format` there is one long
// proof that nothing breaks and none that breaking is SAFE.
//
// Safety is the whole question. Under an offside rule a break in the wrong
// place makes a different program rather than a syntax error, so each case
// asserts three things: it really did break, the tree survived, and running
// the formatter again changes nothing.
func TestFormatBreaksLongForms(t *testing.T) {
	long := "aLongEnoughName"
	cases := map[string]string{
		"application": "f = call " + strings.Repeat(long+" ", 6) + "\n",
		"operator chain": "f = " + long + " + " + long + " + " + long +
			" + " + long + " + " + long + "\n",
		"list literal":  "f = [" + strings.Repeat(long+", ", 5) + long + "]\n",
		"tuple":         "f = (" + strings.Repeat(long+", ", 5) + long + ")\n",
		"record":        "f = P { a = " + long + ", b = " + long + ", c = " + long + ", d = " + long + " }\n",
		"constructors":  "type T = " + strings.Repeat("Alternative"+long+" | ", 4) + "Last\n",
		"if":            "f = if " + long + " then " + long + " else " + long + " " + long + " x\n",
		"nested breaks": "f = call [" + strings.Repeat(long+", ", 4) + "g " + strings.Repeat(long+" ", 4) + "]\n",
	}
	for name, src := range cases {
		t.Run(name, func(t *testing.T) {
			f, err := Parse("long.wok", src)
			if err != nil {
				t.Fatal(err)
			}
			out := Format(f)
			if !strings.Contains(strings.TrimSuffix(out, "\n"), "\n") {
				t.Errorf("nothing broke, so this case proves nothing:\n%s", out)
			}
			back, err := Parse("long.fmt.wok", out)
			if err != nil {
				t.Fatalf("broken output does not parse: %v\n%s", err, out)
			}
			if Dump(back) != Dump(f) {
				t.Errorf("breaking changed the tree.\n--- output ---\n%s\n--- got ---\n%s\n--- want ---\n%s",
					out, Dump(back), Dump(f))
			}
			if again := Format(back); again != out {
				t.Errorf("breaking is not a fixed point.\n--- once ---\n%s\n--- twice ---\n%s", out, again)
			}
		})
	}
}

// TestFormatQuotesLiteralsWokWay guards the one place the dump and the source
// disagree on spelling. The dump is Go-quoted (strconv reads it back), but Go
// writes `\x00` and wok's scanner has no such escape -- so a NUL in a string
// would round-trip through the dump and then fail to LEX as source.
func TestFormatQuotesLiteralsWokWay(t *testing.T) {
	src := "module M\n" +
		"f : ()\n" +
		"f = g \"a\\0b\\n\\\"c\\\\\" 'x' '\\t'\n"
	f, err := Parse("q.wok", src)
	if err != nil {
		t.Fatal(err)
	}
	out := Format(f)
	if !strings.Contains(out, `"a\0b\n\"c\\"`) {
		t.Errorf("string literal not quoted the wok way:\n%s", out)
	}
	back, err := Parse("q.fmt.wok", out)
	if err != nil {
		t.Fatalf("formatted literals do not lex: %v\n%s", err, out)
	}
	if Dump(back) != Dump(f) {
		t.Errorf("literals changed:\n--- got ---\n%s\n--- want ---\n%s", Dump(back), Dump(f))
	}
}
