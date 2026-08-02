# wok v2 — hand-written tokeniser and parser

A small, dependency-free Go front end for the **v2 surface**
(`docs/redesign/spec.md`, `docs/redesign/surface.md`). It exists to make the
grammar checkable by eye: one function per production, named after it, no
generator, no tables, no post-generation patches.

It is a design instrument, not the shipping front end. Nothing here type-checks
or elaborates; `src/Wok/Parsing.hs` and the BNFC grammar still drive the
compiler.

```
go test ./...                                    # tokeniser, parser, corpus, goldens
go run ./cmd/wokparse FILE.wok                   # print the AST as an s-expression
go run ./cmd/wokparse -tokens FILE.wok           # print the token stream with positions
go run ./cmd/wokparse -fmt FILE.wok              # print the file in canonical form
go run ./cmd/wokparse -check FILE.wok            # is it canonical? (the linter)
go run ./cmd/wokparse -read FILE.sexp            # rebuild source from a dump
go test -run Golden -update                      # refresh testdata/golden/*
```

| File | What it holds |
|------|---------------|
| `token.go` | token kinds, the named-spelling (`Word`) table, the symbol charset |
| `tokeniser.go` | the scanner: positions, line-start flags, comments, literals, maximal-munch operators |
| `parser.go` | error reporting, **the layout core**, declarations |
| `type.go` | types and capability rows |
| `pattern.go` | patterns |
| `expr.go` | statements, expressions, handler clauses |
| `ast.go` | the node types |
| `sexpr.go` | the dump: tree → s-expression |
| `sexpr_read.go` | the reader: s-expression → tree |
| `print.go` | the printer: tree → canonical source |
| `errors.go` | `Error`, `ErrorList`, and the cascade-suppressing collector |

## What the tokeniser decides, and what the parser decides

The division is deliberate: **the tokeniser resolves everything that depends on
the source text; the parser only ever looks at fields of a token.**

Every token therefore carries three decided facts beyond its position:

| Field | Decided by the scanner | Why not the parser |
|---|---|---|
| `Kind` | the lexical class | — |
| `Word` | the interned identity of a *named spelling* — a reserved word (`KwLet`), a contextual word (`CwRow`), or an operator run a production reads by name (`OpPlus`); `NoWord` otherwise | the parser compares one integer instead of a string, and `p.atWord(KwHanlde)` fails to **compile**, where `p.atKw("hanlde")` compiled, ran, and was simply never true |
| `First` | this token opens its line | the offside rule asks it for every argument and every block item; the scanner already tracks it for the tab check, so the parser never looks backwards |

No production in `parser.go`, `expr.go`, `type.go` or `pattern.go` reads
`Token.Text` for a decision. Text is only ever *carried into the AST* (a name,
a literal) or quoted in a diagnostic.

The three registers of named spelling stay apart without a second roster,
because `words` records the kind each is emitted as: `Keyword` means reserved
(never a variable), `VarId` means contextual (an ordinary identifier that
carries its tag), `VarSym` means a user operator that one production happens to
name — `+` and `-` remain freely redefinable.

## The layout core

There is no layout pre-pass and there are no virtual `{ ; }` tokens — v2 has
no such characters to insert. The parser keeps a stack of block columns and
answers three questions, using `Token.First` and `Token.Col`:

| Question | Rule |
|---|---|
| does this token continue the item being parsed? | same line (`!First`), **or** column > block column |
| is it the next item? | new line, column **==** block column |
| is the block over? | column **<** block column |

`(`, `[` and `{` push a *bracket* context that suspends the rule until the
closer, so a bracketed expression may be laid out freely. `where` never starts an item,
so it closes the block it follows and attaches to the enclosing equation. A tab
in a line's indentation is an error: under an offside rule a tab's width is an
invisible disagreement between editors.

Blocks open where the parser knows one is due — after `of`, `where`, `=`, `->`,
and after an `effect` / `class` / `instance` / `foreign module` / `handler`
head. Nothing guesses.

## Grammar

Written as EBNF over the token kinds. `{x}` is zero or more, `[x]` optional,
`x|y` alternatives. `BLOCK(x)` is a layout block of `x`: a single `x` on the
current line, or an indented sequence of them. There is no item separator --
v2 has no `;` (D22), so items are delimited by columns and nothing else.

```ebnf
file        = BLOCK(decl) ;

decl        = "module" modpath
            | "import" modpath [ "(" name {"," name} ")" ] [ "as" ConId ]
            | "type"  ConId {typaram} "=" condef {"|" condef}
            | "alias" ConId {typaram} "=" type
            | "effect" ConId {typaram} BLOCK(VarId ":" type)
            | "class" ConId {typaram} BLOCK(sig | equation)
            | "instance" [ "(" type ")" "=>" ] ConId {atomtype} BLOCK(sig | equation)
            | "foreign" "module" ConId String BLOCK(VarId [String] ":" type)
            | "extern" "type" ConId {typaram}
            | "extern" sig
            | sig | equation ;

typaram     = VarId | "(" "row" VarId ")" ;
condef      = ConId {atomtype} | ConId "{" fields "}" | "{" fields "}" ;
sig         = signame {"," signame} ":" type ;
signame     = VarId | "(" VarSym ")" ;
equation    = lhs "=" body [ "where" BLOCK(sig | equation) ] ;
lhs         = VarId {atompat}                (* add x y   *)
            | "(" VarSym ")" {atompat}       (* (+) x y   *)
            | atompat (VarSym | "`" VarId "`") atompat ;

(* --- types: `with` looser than `->`, `->` right-associative --------------- *)
type        = arrow "=>" type | arrow "with" row | arrow ;
arrow       = typeapp [ "->" arrow ] ;
typeapp     = [transfer] atomtype {atomtype} ;     (* transfer: foreign only *)
transfer    = "own" | "lend" | "copy" ;
atomtype    = VarId | ConId {"." ConId} | "[" type "]"
            | "(" ")" | "(" "row" VarId ")" | "(" type {"," type} ")" ;
row         = rowentry {"+" rowentry} ;
rowentry    = "(" VarId ":" type ")"     (* role obligation, D20            *)
            | "eff" VarId                (* row variable                    *)
            | typeapp ;                  (* designation-slot obligation, P2 *)

(* --- a block is a SEQUENCE (D11) ----------------------------------------- *)
body        = expr | BLOCK(stmt) ;
stmt        = "let" bind
            | "handle" label "=" expr
            | "use" usebinds
            | "_" "=" body
            | expr ;
bind        = VarId {atompat} "=" body | pat "=" body ;
usebinds    = name "as" name {"," name "as" name} ;

(* --- expressions --------------------------------------------------------- *)
expr        = "\\" {atompat} "->" body
            | "let" bind "in" body
            | "handle" [label "="] expr "in" body
            | "use" usebinds "in" body
            | "if" expr "then" body "else" body
            | "case" expr "of" BLOCK(pat "->" body ["where" BLOCK(decl)])
            | "handler" ConId BLOCK(clause)
            | chain [":=" body] ;
chain       = app {infixop app} ;                 (* FLAT: no precedence here *)
infixop     = VarSym | "::" | "`" VarId "`" ;
app         = "-" app | atom {atom} ;
atom        = VarId | ConId | Int | String | Char
            | "(" ")" | "(" VarSym ")" | "(" expr {"," expr} ")"
            | "[" [expr {"," expr}] "]"
            | atom "." (VarId | ConId)
            | conatom "{" ["..", expr [","]] [field {"," field}] "}" ;

clause      = "var" VarId "=" body
            | "return" pat "->" body
            | "once" VarId {atompat} "->" body    (* last binder = the k *)
            | VarId {atompat} "->" body ;

(* --- patterns ------------------------------------------------------------ *)
pat         = patapp ["::" pat] ;
patapp      = ConId {atompat} | atompat ;
atompat     = (VarId | "_" | Int | "-" Int | String | Char
              | ConId {"." ConId} ["{" fieldpats "}"]
              | "(" ")" | "(" pat {"," pat} ")" | "[" [pat {"," pat}] "]")
              {"as" VarId} ;
```

## Deliberate deviations from `grammar/Wok.cf`

1. **`-` is not an identifier character.** `Wok.cf:518-522` allows dashes in
   names, which is why its lexer must glue `-5` into a single literal and why
   `1-2` lexes there as `[1, -2]` (its own documented wart). Here `-` is always
   an operator and negation is a prefix form in operand position, so `1-2` is
   subtraction. No `.wok` file in the repo uses a dashed identifier.

2. **Identifiers are ASCII**, matching BNFC's `lower` / `upper`.
   `unicode.IsLower` would silently admit `é` and `λ` as identifier heads and
   `unicode.IsDigit` would admit digits `strconv` then rejects. Widening the
   language is a decision, not a cleanup — it is three lines in `token.go`.

3. **Contextual keywords.** `own`, `lend`, `copy` are read as transfer modes
   only inside a foreign member signature; `eff` only inside a `with` row;
   `row` only inside `( row e )`. Reserving them would break `Bytes.copy`,
   which the spec itself uses (section 2). The reserved set is exactly
   surface.md's palette. They are scanned as ordinary `VarId` tokens tagged
   with their `Word`, so the one production that wants them matches an integer
   and every other production sees a plain name.

4. **Nested block comments.** `{- a {- b -} c -}` closes correctly.

5. **Flat operator chains.** `a + b * c` parses to one chain; precedence and
   associativity are a later pass's job, as `src/Wok/Reordering.hs` already
   does. No fixity table lives in the parser.

6. **One `Dot` node** for `M.f`, `st.get` and `p.x`. Spec 1.5 resolves
   qualifier / label / projection, and its collision rule (E-LABEL) needs them
   undistinguished at parse time.

7. **No `;` (D22).** A block's items are delimited by columns and nothing
   else, so there is one layout rule rather than a rule plus an escape hatch.
   A single handler clause may still share its head's line; more than one
   needs the block. `;` carries a targeted diagnostic rather than "unexpected
   character", since it is legal v1 wok that a port will hit. Braces remain,
   confined to records.

8. **`once` splits its binders.** The last binder of a `once` clause is stored
   as the continuation `K` and the rest as `Pats`, so E-ARITY can compare
   pattern count against op arity directly (D14). A non-name in that position
   is rejected here, since D14 makes it unwritable.

9. **Tabs in indentation are rejected**, rather than assigned a width.

## Diagnostics: a batch, not the first fault

The goal is a fast report-fix-test loop for both a human and a tool, so one
run yields a whole work list rather than the first mistake.

```
$ wokparse bad.wok
bad.wok:3:5: expected `=` after the left-hand side, found `:=`
bad.wok:6:3: a `handle` statement must write its label: `handle <label> = <handler>`

$ wokparse -json bad.wok        # same faults, structured
[{"file":"bad.wok","line":3,"col":5,"message":"expected `=` ..."}, ...]
```

Human form is `file:line:col: message`, which every editor and CI log already
jumps to. `-json` emits the same records with exported fields. `Parse` returns
an `ErrorList` (the shape `go/scanner` uses); printing it alone gives the
first fault plus a count, so a caller that ignores the list still sees the
most important line.

**Recovery happens in exactly one place**: `items()`, the layout-block loop.
Layout is what makes that reliable — the block already knows the column its
next item starts at, so a failed item is abandoned and the next is picked up
there. No hunting for a `;` or `}` that might mean anything; in a
brace-and-semicolon language this is guesswork, and here it is arithmetic.

Four rules keep the batch trustworthy:

1. **Item granularity only** — one message per declaration, statement,
   alternative or clause. Resynchronising mid-expression is where parsers
   start inventing faults that were never in the source.
1. **Skipping stops at an anchor, not at a column.** A declaration block
   resynchronises only where a declaration could *begin* — a declaration
   keyword, a signature, or an equation head — so a `)` or a `->` sitting at
   column 1 is wreckage to walk over, not a fresh start. A dedent always ends
   the skip, so a damaged item can never swallow the block containing it. This
   is what collapses a misindented region into one fault instead of one per
   line. Statements, alternatives and clauses pass no anchor: their columns
   are already unambiguous. Forward-only declarations (D23) are what make a
   signature the strongest anchor available.
2. **State is restored before resuming.** A failed item may have been inside
   a bracket or a foreign signature; `items` rewinds the layout stack and the
   `foreign` flag, or every column comparison after the fault is measured
   against a stale context and recovery silently corrupts the rest of the parse.
3. **Cascades are suppressed.** A second complaint at a position already
   reported is dropped: one mistake, one message.
4. **A cap (20) ends the run.** Past it the file is misindented or truncated
   and only the early faults are trustworthy, so the batch ends with
   `too many errors; stopping here`.

Lexical faults batch the same way (three stray `;` are three lines), with the
crudest possible recovery — skip the character, or the rest of the line for a
literal that never closed. They short-circuit parsing: a damaged token stream
makes parse errors guesswork.

**No `Bad*` AST nodes.** A file that failed to parse should not be
type-checked, so a placeholder node has no consumer today; the partial tree
is returned for inspection but `err != nil` means do not trust it. This is
the one thing to add if the parser ever backs an editor, where analysing a
half-typed file is the whole point.

## The dump reads back, and the tree prints

The s-expression is not only a debug print. `Read` turns it back into the tree
it came from and `Format` prints that tree as source, so the three directions
close into a loop:

```
      Parse            Dump
.wok ------->  tree  --------> .sexp
      <-------       <--------
      Format           Read
```

That makes one artifact do three jobs. The dump is the **canonical identity**
of a program — two files that differ only in layout have the same dump, since
positions are not in it. `Format` is the **canonical spelling** — one program,
one text. And "this file differs from its own formatting" is the whole of the
**linter** (`-check`).

### What the tree does not record, and why that is fine

The tree has no parentheses, no line breaks and no source columns, so the
printer re-derives all three. That is the point rather than a compromise: a
fact that can be *computed* cannot go stale.

| Not recorded | Recovered from |
|---|---|
| parentheses | precedence — `prec*` in `print.go` mirrors the productions in `expr.go` exactly |
| line breaks | the two facts the tree *does* record: a `Block` is an indented statement sequence, and a layout block is one item per line |
| backticks on an infix operator | its spelling: an alphabetic operator can only have been written `` `add` ``, a symbolic one only bare |
| brackets on `(+) x y` | the same fact, the other way round |
| whether a dotted name was a `ConId` | its first character — the tokeniser decided it there and nothing can undo that |

Redundant parentheses, the author's line breaks and blank lines are **dropped**,
which is what canonicalising means. What must never change is the tree.

### The dump had to become faithful first

As an eyeball artifact the dump could be lossy; as an interchange form it
cannot. Two rules were added, each costing a pair of parentheses:

- **a nullary form is a list, never a bare word** — `(unit)`, not `unit`, which
  is indistinguishable from a variable of that name;
- **a heterogeneous sequence is tagged** — `(params …)`, `(args …)` — rather
  than left for the reader to tell apart by shape.

The reader is correspondingly strict: an unknown head or an unexpected arity is
an error naming the position in the dump. A reader that guessed would turn a
typo in the IR into a different program, silently.

### Four properties, and what each one alone would miss

`roundtrip_test.go` runs these over the whole corpus.

| Property | Fails when |
|---|---|
| `Dump(Read(Dump(t))) == Dump(t)` | the dump forgot a field — a `once` continuation, a capitalized label, an open record pattern |
| `Dump(Parse(Format(t))) == Dump(t)` | printing changed the program |
| `Format(Parse(Format(t))) == Format(t)` | the formatter is not a fixed point, so `-check` would flag a file it just wrote |
| every node is exercised | the three above are silent about a form no corpus file contains |

The second is the load-bearing one. Under an offside rule a line break in the
wrong place is **not a syntax error** — it turns an expression into a block, or
ends one early — so the output still parses and only the tree shows the damage.
Comparing text would pass.

The fourth is checked by reflection over the parsed corpus rather than a list:
nothing in Go reports a node type that is never constructed, and a roster of
them would be one more thing to forget. A failure there means
`testdata/surface-tour.wok` stopped covering a form. It is also what covers the
reader, which switches on head strings and so cannot be paired with the node
families the way the dump and the printer are.

### Limit: comments are not preserved

The tokeniser discards comments (`skipSpaceAndComments`), so they are not in
the tree and the printer cannot put them back. **`-fmt` must not be run over a
file a human wrote and kept.** Closing this needs comments carried as trivia —
scanned into a side list, attached to nodes by position, and written into the
dump like any other field — which touches the tokeniser's "allocates only the
token slice" property and every node. It is a slice of its own.

## Hand-maintained rosters are cross-checked against the source

Several lists here must stay in step with something declared elsewhere, and
**nothing in Go enforces that**: a type switch falls through to a default, a
keyword is matched by a string that was never reserved, an unused
package-level var is invisible. Neither the compiler nor `go vet` says a word
about any of it.

`roster_test.go` reads the source with `go/ast` and pairs them up. Reading the
source is the point — a roster checked against another hand-written roster is
not checked at all.

| Pair | What drifting costs you | Guard |
|---|---|---|
| AST node families ↔ `sexpr.go` **and `print.go`** type switches | a node dumps as `<unknown expr *wok.Foo>`, or prints as *nothing at all*: wrong output, no error | `TestEveryNodeHasADumpCase` |
| `Word` constants ↔ the productions that match them | a spelling reserved from every program that wanted it as a name, then matched nowhere | `TestEveryWordIsMatched` |
| `Word` constants ↔ `words` ↔ what the scanner emits | a word with no spelling, or one that lexes as another kind: a branch that can never fire | `TestEveryWordIsProducible` |
| `parseDecl` dispatch ↔ `startsDecl` anchor | recovery walks past a declaration it should stop at, losing the rest of the file after one fault | `TestDeclKeywordsMatchTheParser` |
| `fixed` ↔ what the scanner can emit | a lexeme declared but unreachable (`...` lexes as `..` then `.`) | `TestEveryFixedLexemeIsProducible` |
| `Kind` constants ↔ every table keyed by them | a kind classified nowhere, silently accepted or rejected | `TestEveryKindIsClassified` |

Each was mutation-tested. One direction of the old keyword check is gone
because it no longer needs a test: matching a word that was never declared is
now a compile error, which is the point of interning spellings as `Word`. The
reverse direction stayed — a reserved word matched nowhere is a word taken
from users for nothing, and it is what found `clauseKindName`, a roster dead
since the dump started switching on `ClauseKind` directly.

## FIRST sets are checked exhaustively

The parser decides "can an argument, element or item start here?" with five
hand-written predicates — `startsAtom`, `startsAtomPat`, `startsTypeAtom`,
`startsDecl`, `startsSig`. Each is a list of token kinds, and a list is
exactly what rots when a kind is added: nothing fails to compile, the parser
just quietly stops accepting something.

`firstset_test.go` closes that from two independent directions:

1. **Exhaustive** — the test reads `token.go` with `go/ast` and enumerates the
   `Kind` constants *as declared*, then requires each to be named, classified,
   and given a sample. Reading the source is the only way to enumerate them:
   Go has **no** exhaustiveness check on a switch over a named integer type
   (neither the compiler nor `go vet` says a word) and no reflection over
   constants, so every hand-maintained roster — `kindName` included — can
   silently omit one.
2. **Agreement** — for every kind, the predicate's answer must match whether
   the corresponding `parse*` function actually consumes that sample. A
   predicate that says yes where the parser then fails produces a confusing
   error; one that says no where the parser would have succeeded silently
   truncates an argument list.

The second is what makes the first more than bookkeeping: changing a
predicate *and* the table together, both wrong, still fails, because the
parser is the third opinion.

Both were mutation-tested rather than assumed:

| Mutation | Caught by |
|---|---|
| drop `CharLit` from `startsAtom` | spec mismatch |
| drop `Under` from `startsAtomPat` | spec mismatch |
| wrongly admit `IntLit` as a type atom | spec mismatch |
| change a predicate *and* the spec table together, both wrong | agreement with the parser |
| declare a `Kind`, register its name, classify it nowhere | exhaustiveness |
| declare a `Kind` and register it **nowhere at all** | exhaustiveness |

The last row is why the roster is parsed out of the source. An earlier version
of this test enumerated `kindName` instead, and that case slipped through
every check in the repository — compiler, vet and test alike.

Rules that reach past kind membership (a negative literal is a pattern; a
bare operator is not) are stated as cases rather than left implicit inside a
predicate.

## Why the scanner is a switch, not a rule table

Rust's [logos](https://logos.maciej.codes) is the reference for declarative
tokenising: token definitions live on one enum, one line each, and a derive
macro compiles them into a DFA. Two of its properties are worth copying and
one does not survive the trip to Go.

**Copied: single-sourced definitions.** `fixed` in `token.go` lists every
fixed lexeme once; `kindName`, `reservedSym` and `punctuation` are derived
from it in `init`. Before, adding `:=` meant editing three tables that could
silently disagree. This is the whole maintainability win, and it cost 18 lines
rather than saving any.

**Not copied: generating the matcher.** Go has no macros, so a rule table
would need either a regexp per rule or a hand-written driver. Logos's real
output is a state machine nobody reads — fine when a macro maintains it, and
exactly the "generated artifact you must not hand-edit" problem this package
exists to escape.

**The measurement.** A regexp rule table was prototyped and rejected on
CORRECTNESS, not size. wok's line comment is "two or more dashes not followed
by another operator character", which as a regexp rule becomes:

```
^--+([^!#$%&*+/<=>?@\\^|~:\n-][^\n]*)?
```

The operator charset now exists twice — once as the operator rule, once
negated inside the comment rule. Add an operator character, forget the second
copy, and `-->` silently becomes a comment. Logos avoids this class of bug by
computing priorities at compile time and *refusing to compile on a tie*
(priority = 2 per literal byte, 1 per character class, alternations counted at
their shortest branch); a hand-maintained Go table has no such check.

The structural fix needs no table at all: take the maximal operator run first,
then ask whether it is all dashes (`isLineComment`). The charset stays written
once, and the 12-line lookahead function it replaced is gone.

The general result: below roughly 30 token classes, a hand-written switch is
shorter *and* safer than a hand-maintained table. wok has 8 open classes and
20 fixed lexemes. What scales badly is not the token count but the number of
places one fact is written down — which is what `fixed` and `words` fix.

## Speed, and where it comes from

`go test -bench .` runs both stages over the whole corpus. The switch stayed a
switch; what changed is that each fact is now computed once, in the place that
already knows it:

| | before | now |
|---|---|---|
| `Tokenise` | 118 MB/s, 544 allocs | **238 MB/s, 21 allocs** (one per file) |
| `Parse` | 81 MB/s, 2804 allocs | **130 MB/s, 2281 allocs** |

Six changes, no clever code:

1. **Runs are measured in bytes.** `identRune`, `isSymChar` and `isDigit` are
   ASCII-only, so a byte ≥ 0x80 always ends the run and `takeWhile` never
   decodes — it counts bytes and advances the column by that count. The
   ASCII-only property is what makes this sound, so it is pinned by a test
   (`TestRunPredicatesAreASCII`) rather than left as a comment.
2. **ASCII fast paths** in `peek` and `advance`, for the same reason: the
   common byte is taken without a decode.
3. **The token slice is sized from the source** (one token per four bytes),
   so a file is scanned without repeated regrowth.
4. **One hash per identifier.** A single `wordOf` lookup answers both
   registers, reserved and contextual; `wordText` and `wordKind` are then
   indexed by the `Word` itself, which is a dense enum — an array index, not
   a hash. There is no second `keywords` table to consult.
5. **`Word` and `First` are free.** The scanner already knew both; the three
   small fields lead the struct so they share one word of padding, and a
   `Token` is the same 40 bytes it was before they existed.
6. **A token's `Text` is a slice of the source, never a copy.** In Go a
   substring shares the original bytes, so scanning a file allocates the token
   slice and *nothing else* — 21 allocations for the 21-file corpus. Keeping
   that property is easy to lose by accident, so it is a test
   (`TestScanningAllocatesOnlyTheTokenSlice`): `string(r)` for a bracket used
   to allocate once per bracket, and a `strings.Builder` allocated once per
   string literal even when the literal held no escape. Punctuation now points
   at the constant text in `fixed`, and a literal is decoded only once a `\`
   proves the text and the source differ.

The parser's share is the string comparisons that are gone: a keyword match
was `Kind == Keyword && Text == "handle"`, two loads and a `memcmp`; it is now
one byte compare.

## What the parser checks, and what it does not

It enforces only what is a matter of FORM. Everything the spec calls a
diagnostic code is left to a later pass, and the AST is shaped to make those
passes easy: labels record whether they were capitalized (P2 slot vs role),
row entries record slot / role / row-variable, `once` keeps its continuation
separate, and statement and inline forms are distinct nodes.

Two rules of form are enforced here because they are grammar facts:

- a `handle` STATEMENT must write its label (P1/D13 — the delimited inline
  form may elide it);
- a `once` clause's continuation binder must be a plain name (D14).

## Open questions for the surface

1. **`fixity` declarations.** surface.md's keyword palette drops them, so they
   are not parsed. Flat operator chains need a fixity source eventually; if
   fixity returns, `left` / `right` / `tighter` / `than` should be contextual
   words, not reserved ones (`left` and `right` are too useful as names).
2. **`foreign module` `free "sym"`.** v1 had a module-level deallocator
   clause; surface.md puts the transfer law in member types
   (`free : own Bytes -> ()`), so the clause is not parsed.
3. **Operator sections.** Only `(+)` is accepted, matching v1; `(+ 1)` and
   `(1 +)` are not sections in either surface.
4. **`local` declarations** (v1 module privacy) are unmentioned in the v2 docs
   and are not parsed.

## Corpus

`go test` parses every file in `docs/redesign/examples/` — all 9 `accept/` and
all 11 `reject/` (those are *semantically* rejected; they are syntactically
valid and exercise the parser just as hard) — plus `testdata/surface-tour.wok`,
which covers the forms the conformance suite never reaches: classes,
instances, foreign modules, records (types, literals, updates, patterns),
`where`, lambdas, `if`, as-patterns, and operator definitions in all three
left-hand-side shapes.

Each one's AST is pinned in `testdata/golden/*.sexp` and its canonical
spelling in `testdata/golden/*.fmt.wok`. Read the dumps beside `surface.md`
(the dump is meant to read back as the surface form it came from), and read the
`.fmt.wok` files beside their sources — that diff *is* what the formatter
decided, so a change in layout is reviewed rather than discovered.

The tour is also load-bearing for the round-trip properties: it is where a form
goes when `TestCorpusExercisesEveryNode` reports that no file reaches it.
