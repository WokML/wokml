package wok

import (
	"strings"
	"testing"
)

// faults parses src and returns its diagnostics as `line:col message` strings.
func faults(t *testing.T, src string) []string {
	t.Helper()
	_, err := Parse("t.wok", src)
	if err == nil {
		return nil
	}
	list, ok := err.(ErrorList)
	if !ok {
		t.Fatalf("error is %T, want ErrorList: %v", err, err)
	}
	out := make([]string, 0, len(list))
	for _, e := range list {
		out = append(out, strings.TrimPrefix(e.Error(), "t.wok:"))
	}
	return out
}

func wantFaults(t *testing.T, src string, want ...string) []string {
	t.Helper()
	got := faults(t, src)
	if len(got) != len(want) {
		t.Fatalf("got %d faults, want %d:\n  %s", len(got), len(want), strings.Join(got, "\n  "))
	}
	for i := range got {
		if !strings.HasPrefix(got[i], want[i]) {
			t.Errorf("fault %d:\n got  %s\n want %s...", i, got[i], want[i])
		}
	}
	return got
}

// One run must yield a whole work list, not the first mistake: that is what
// makes report-fix-test one round instead of N.
func TestFaultsAreReportedAsABatch(t *testing.T) {
	src := "" +
		"module Main\n" +
		"a = 1\n" +
		"b x := 2\n" + // `:=` where `=` belongs
		"c = 3\n" +
		"d =\n" +
		"  handle noLabel\n" + // a statement handle must write its label
		"  0\n" +
		"e = 4\n"
	wantFaults(t, src,
		"3:5: expected `=`",
		"6:3: a `handle` statement must write its label")
}

// The point of recovering at item granularity: everything AROUND the fault is
// still parsed, so the batch is complete and later declarations are not lost.
func TestRecoveryKeepsTheGoodDeclarations(t *testing.T) {
	src := "" +
		"a = 1\n" +
		"b x := 2\n" +
		"c = 3\n"
	f, err := Parse("t.wok", src)
	if err == nil {
		t.Fatal("expected a fault")
	}
	if f == nil {
		t.Fatal("no partial tree returned")
	}
	got := Dump(f)
	for _, want := range []string{"(def a (params) 1)", "(def c (params) 3)"} {
		if !strings.Contains(got, want) {
			t.Errorf("recovery lost %q:\n%s", want, got)
		}
	}
}

// Recovery works inside any layout block, not just at top level, because
// every block goes through the same items() loop.
func TestRecoveryInsideNestedBlocks(t *testing.T) {
	src := "" +
		"f xs = case xs of\n" +
		"  A -> 1\n" +
		"  B -> _\n" + // `_` is not an expression
		"  C -> 3\n" +
		"g = 2\n"
	wantFaults(t, src, "3:8: `_` is a pattern")

	f, _ := Parse("t.wok", src)
	got := Dump(f)
	for _, want := range []string{"(alt (pcon A) 1)", "(alt (pcon C) 3)", "(def g (params) 2)"} {
		if !strings.Contains(got, want) {
			t.Errorf("recovery lost %q:\n%s", want, got)
		}
	}
}

// One mistake must produce ONE message. A second complaint about the same
// position is always a cascade, never new information.
func TestCascadesAreSuppressed(t *testing.T) {
	got := faults(t, "a = 1\nb x := 2\nc = 3\n")
	if len(got) != 1 {
		t.Fatalf("one mistake produced %d messages:\n  %s", len(got), strings.Join(got, "\n  "))
	}
}

// Past the cap a report stops being a work list: the file is misindented or
// truncated and only the early faults are trustworthy.
func TestErrorCap(t *testing.T) {
	var b strings.Builder
	for range maxErrors * 3 {
		b.WriteString("x y := 1\n")
	}
	got := faults(t, b.String())
	if len(got) != maxErrors+1 {
		t.Fatalf("got %d faults, want %d plus the stop line", len(got), maxErrors)
	}
	if last := got[len(got)-1]; !strings.Contains(last, "too many errors") {
		t.Errorf("last line is %q, want the stop line", last)
	}
}

// Lexical faults batch too, and short-circuit parsing: a damaged token stream
// makes parse errors guesswork.
func TestLexicalFaultsBatch(t *testing.T) {
	wantFaults(t, "a = 1 ; b = 2 ; c = 3\n",
		"1:7: `;` is not part of wok v2",
		"1:15: `;` is not part of wok v2")
}

func TestUnterminatedLiteralRecoversAtEndOfLine(t *testing.T) {
	// The next line must still be scanned, or one bad quote hides the file.
	wantFaults(t, "a = \"open\nb = 'x\nc = 1\n",
		"1:5: unterminated string literal",
		"2:5: unterminated character literal")
}

// ErrorList's own message leads with the first fault, so a caller that prints
// only `err` still gets the most important line.
func TestErrorListMessage(t *testing.T) {
	_, err := Parse("t.wok", "a = 1\nb x := 2\nc y := 3\n")
	msg := err.Error()
	if !strings.HasPrefix(msg, "t.wok:2:5:") {
		t.Errorf("message does not lead with the first fault: %s", msg)
	}
	if !strings.Contains(msg, "and 1 more") {
		t.Errorf("message does not say how many more: %s", msg)
	}
}

// The anchor turns a damaged REGION into one fault. Without it, every line of
// wreckage at or past the block column looks like a fresh item and earns its
// own message -- the noise the error cap exists to stop.
func TestAnchorCollapsesAWreckedRegion(t *testing.T) {
	src := "" +
		"a : U64\n" +
		"a = 1\n" +
		"b =\n" +
		"  let x = 1\n" +
		"     ) broken\n" +
		"   -> more wreckage\n" +
		"  x\n" +
		"c : U64\n" +
		"c = 3\n"
	wantFaults(t, src, "5:6: unexpected indentation")

	// and the declarations on the far side of the wreckage survive
	f, _ := Parse("t.wok", src)
	got := Dump(f)
	for _, want := range []string{"(def a (params) 1)", "(sig (names c) U64)", "(def c (params) 3)"} {
		if !strings.Contains(got, want) {
			t.Errorf("recovery lost %q:\n%s", want, got)
		}
	}
}

// Resynchronisation stops only where a declaration could BEGIN, so wreckage
// that merely sits at the block column is skipped rather than parsed.
func TestAnchorRejectsNonDeclarationStarts(t *testing.T) {
	if p := (&parser{}); p != nil {
		// guard: the anchor set is the decl keywords plus a name or `(`
		for _, src := range []string{"module M\n", "type T = A\n", "f : U64\n", "(+) a b = a\n"} {
			toks, _ := Tokenise("t.wok", src)
			q := &parser{collector: collector{file: "t.wok"}, toks: toks}
			if !q.startsDecl() {
				t.Errorf("%q should start a declaration", src)
			}
		}
		for _, src := range []string{"Con x\n", "-> e\n", ") x\n", "3\n", "where x = 1\n"} {
			toks, _ := Tokenise("t.wok", src)
			q := &parser{collector: collector{file: "t.wok"}, toks: toks}
			if q.startsDecl() {
				t.Errorf("%q should NOT start a declaration", src)
			}
		}
	}
}

// D23: a signature must precede the equation it describes. v2 reads forward
// only -- no scanning back for a type that might appear later.
func TestSignatureMustPrecedeItsEquation(t *testing.T) {
	wantFaults(t, "good = 1\ngood : U64\n",
		"2:1: signature for `good` comes after its definition at 1:1")

	// the ordinary order is silent
	if got := faults(t, "good : U64\ngood = 1\n"); got != nil {
		t.Errorf("sig-before-body must be clean, got: %v", got)
	}
	// unrelated names in any order are fine
	if got := faults(t, "a = 1\nb : U64\nb = 2\n"); got != nil {
		t.Errorf("unrelated names must be clean, got: %v", got)
	}
}

// The rule is per declaration BLOCK: a `where` binding carries its own
// signature independently of the top level.
func TestForwardOrderIsPerBlock(t *testing.T) {
	src := "" +
		"f : U64\n" +
		"f = g\n" +
		"  where\n" +
		"    g : U64\n" +
		"    g = 1\n"
	if got := faults(t, src); got != nil {
		t.Errorf("local signature must be clean, got: %v", got)
	}
	bad := "" +
		"f = g\n" +
		"  where\n" +
		"    g = 1\n" +
		"    g : U64\n"
	wantFaults(t, bad, "4:5: signature for `g` comes after its definition at 3:5")
}
