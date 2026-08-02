package wok

import (
	"strings"
	"testing"
)

// dump parses src and returns its s-expression, failing the test on error.
func dump(t *testing.T, src string) string {
	t.Helper()
	f, err := Parse("t.wok", src)
	if err != nil {
		t.Fatalf("parse: %v\nsource:\n%s", err, src)
	}
	return strings.TrimSpace(Dump(f))
}

// wants asserts the dump contains each fragment, so a test states the shape it
// cares about rather than a whole tree.
func wants(t *testing.T, src string, fragments ...string) {
	t.Helper()
	got := dump(t, src)
	for _, want := range fragments {
		if !strings.Contains(got, want) {
			t.Errorf("missing %q in:\n%s", want, got)
		}
	}
}

// failsAt asserts the parse fails at line:col with a message fragment.
func failsAt(t *testing.T, src, at, fragment string) {
	t.Helper()
	_, err := Parse("t.wok", src)
	if err == nil {
		t.Fatalf("expected an error at %s, got a successful parse of:\n%s", at, src)
	}
	msg := err.Error()
	if !strings.HasPrefix(msg, "t.wok:"+at+":") {
		t.Errorf("error at wrong position: %s (want t.wok:%s)", msg, at)
	}
	if !strings.Contains(msg, fragment) {
		t.Errorf("error %q does not mention %q", msg, fragment)
	}
}

// ------------------------------------------------------------------- layout

func TestBlockIsASequence(t *testing.T) {
	// Two statements, NOT one application spanning both lines: the offside
	// rule stops the argument loop at the block column.
	wants(t, "main =\n  f 1\n  g 2\n",
		"(block (app f 1) (app g 2))")
}

func TestIndentedContinuationStaysInTheItem(t *testing.T) {
	// Deeper indentation continues the item rather than starting a new one.
	wants(t, "main =\n  f 1\n    2\n  g 3\n",
		"(block (app f 1 2) (app g 3))")
}

func TestDedentClosesEveryOpenBlock(t *testing.T) {
	src := "" +
		"f xs = case xs of\n" +
		"  [] ->\n" +
		"    a\n" +
		"    b\n" +
		"g = 1\n"
	wants(t, src, "(alt (list) (block a b))", "(def g (params) 1)")
}

// v2 has no `;`: item boundaries are columns and nothing else. The character
// carries a targeted diagnostic because it is legal v1 wok that a port hits.
func TestSemicolonIsRemoved(t *testing.T) {
	failsAt(t, "h = handler E\n  get -> 1 ; set x -> 2\n", "2:12", "separates statements by layout")
}

// Braces are confined to records; `{- -}` is a comment the grammar never sees.
func TestRecords(t *testing.T) {
	wants(t, "type Point = { x : U64, y : U64 }\n",
		"(con-record _ (fields (field x U64) (field y U64)))")
	wants(t, "main = Point { x = 1 }\n", "(record Point (field x 1))")
	wants(t, "main = Point { ..p, x = 9 }\n", "(record Point (.. p) (field x 9))")
	wants(t, "f p = case p of\n  Point { x = a, .. } -> a\n", "(precord Point (field x a) ..)")
	wants(t, "f p = case p of\n  Point {} -> 0\n", "(precord Point)")
	wants(t, "main {- a {- nested -} comment -} = 1\n", "(def main (params) 1)")
}

// A single clause may still share the head's line; more than one needs the
// block, since there is no separator any more.
func TestSingleClauseOnTheHeadLine(t *testing.T) {
	wants(t, "h = handler E tick x -> x * 2\n", "(handler E (clause tick (args x)")
}

func TestLayoutIsSuspendedInsideBrackets(t *testing.T) {
	// A bracketed expression may be laid out freely: columns mean nothing
	// until the closer.
	wants(t, "main =\n  f (a,\n b,\n     c)\n", "(app f (tuple a b c))")
}

func TestStrayIndentationIsAnError(t *testing.T) {
	failsAt(t, "main =\n  a\n b\n", "3:2", "unexpected indentation")
}

func TestWhereAttachesToACaseAlternative(t *testing.T) {
	src := "" +
		"f x = case x of\n" +
		"  A ->\n" +
		"    g 1\n" +
		"    where\n" +
		"      g y = y\n" +
		"  B -> 2\n"
	wants(t, src,
		"(alt (pcon A) (block (app g 1)) (where (def g (params y) y)))",
		"(alt (pcon B) 2)")
}

func TestHeadParametersStopAtEndOfLine(t *testing.T) {
	// A head followed by a layout block must not read the block's first line
	// as another parameter: `effect State s` / `get : s`.
	wants(t, "effect State s\n  get : s\n", "(effect State (params s) (op get s))")
	wants(t, "class Eq a\n  (==) : a -> a -> Bool\n", "(class Eq (params a) (sig (names ==)")
}

func TestWhereClosesTheBodyBlock(t *testing.T) {
	src := "" +
		"f x =\n" +
		"  g x\n" +
		"  where\n" +
		"    g y = y\n"
	wants(t, src, "(block (app g x))", "(where (def g (params y) y))")
}

// --------------------------------------------------------------- statements

func TestStatementFormsAndTheirInlineTwins(t *testing.T) {
	// D11: the statement scopes over the rest of the block; the inline twin
	// ends in `in` and is delimited.
	wants(t, "main =\n  let x = 1\n  handle State = h\n  use c as State\n  _ = drop ()\n  x\n",
		"(let (bind x 1))",
		"(handle (slot State) h)",
		"(use (as c (slot State)))",
		"(discard (app drop (unit)))")

	wants(t, "main = let x = 1 in x\n", "(let-in (bind x 1) x)")
	wants(t, "main = handle st = h in body\n", "(handle-in (role st) h body)")
	wants(t, "main = use c as State in body\n", "(use-in (binds (as c (slot State))) body)")
}

func TestInlineHandleMayElideItsLabel(t *testing.T) {
	// D13 two-tier: the delimited form derives the label from the handler's
	// type, the statement form must write it.
	wants(t, "main = handle collect in count 1 7\n", "(handle-in (elided) collect")
	// The fault is blamed on the `handle` itself, not on the line after it:
	// the handler expression is consumed before the label can be missed.
	failsAt(t, "main =\n  handle collect\n  0\n", "2:3", "must write its label")
}

func TestAssignmentIsABatonUpdate(t *testing.T) {
	wants(t, "h = handler E\n  set x -> cur := x\n", "(:= cur x)")
	failsAt(t, "main = f x := 1\n", "1:8", "plain name")
}

// -------------------------------------------------------------- expressions

func TestOperatorChainsStayFlat(t *testing.T) {
	// No precedence table in the parser: `a + b * c` is one flat chain and a
	// later reordering pass shapes it.
	wants(t, "main = a + b * c\n", "(infix a (+ b) (* c))")
	wants(t, "main = x `plus` y\n", "(infix x (plus y))")
}

func TestNegationVersusSubtraction(t *testing.T) {
	wants(t, "main = a - b\n", "(infix a (- b))")
	wants(t, "main = f (-1)\n", "(app f (neg 1))")
	wants(t, "main = -n + 1\n", "(infix (neg n) (+ 1))")
}

func TestDotsAllLandInOneNode(t *testing.T) {
	// spec 1.5 resolves qualifier / label / projection later; the parser must
	// not pre-judge, or the E-LABEL collision rule has nothing to see.
	wants(t, "main = M.f\n", "(dot M f)")
	wants(t, "main = st.get\n", "(dot st get)")
	wants(t, "main = p.x\n", "(dot p x)")
}

func TestOnceClauseSplitsOffTheContinuation(t *testing.T) {
	// E-ARITY counts op arguments, so the continuation is kept separate.
	wants(t, "h = handler E\n  once req (Ping n) k -> k n\n",
		"(once req (args (pcon Ping n)) (k k) (app k n))")
	// D14: the continuation binder is never a pattern.
	failsAt(t, "h = handler E\n  once req (a, b) -> 1\n", "2:19", "must be a plain name")
	failsAt(t, "h = handler E\n  once req -> 1\n", "2:12", "must bind the continuation")
}

func TestUnderscoreIsNotAnExpression(t *testing.T) {
	failsAt(t, "main = _\n", "1:8", "`_` is a pattern")
}

// -------------------------------------------------------------------- types

func TestRowEntryKinds(t *testing.T) {
	// A bare entry is a DESIGNATION SLOT obligation; a parenthesised one is a
	// ROLE (D20); `eff e` is a row variable.
	wants(t, "f : () -> () with State U64 + (to : State U64) + eff e\n",
		"(row (slot (app State U64)) (role to (app State U64)) (eff e))")
	// A capital inside a parenthesised entry is E-LABEL; the parser records it
	// for the checker rather than rejecting it.
	wants(t, "f : () -> () with (To : State U64)\n", "role-CAPITAL To")
}

func TestRowBindsLooserThanTheArrow(t *testing.T) {
	wants(t, "f : A -> B -> C with E\n", "(with (-> A (-> B C)) (row (slot E)))")
}

func TestTransferModesAreForeignOnly(t *testing.T) {
	wants(t, "foreign module Libc \"c\"\n  free : own Bytes -> ()\n",
		"(member free (-> (own Bytes) (unit)))")
	// Outside a foreign signature `own` is an ordinary name.
	wants(t, "f : own Bytes -> ()\n", "(-> (app own Bytes) (unit))")
}
