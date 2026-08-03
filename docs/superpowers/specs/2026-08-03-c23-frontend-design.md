---
spec: c23-frontend
status: awaiting review
supersedes: grammar/c/PLAN.md (deleted -- it planned a Go port with Go as the oracle)
---

# A C23 front end for wok v2: scanner, layout filter, parser

Three stages, not two. The middle stage is a pure function over token streams,
which is what makes the offside rule testable instead of merely careful.

The surface is **v2** (`docs/redesign/spec.md`, `docs/redesign/surface.md`), and
the language definition is taken from those two documents plus the 21-file `.wok`
corpus. `grammar/go` is not an oracle, not a reference implementation, and is not
consulted for behaviour.

## 1. Goals, in the order they settle arguments

1. **Layout is decided once, in one pure function.** No parse-error(t), no
   feedback edge from the parser back into layout. The layout filter's whole
   world is token columns, bracket nesting, and one lexical predicate.
2. **Every rule is harnessed by something that is not a person reading it.** A
   compile-time check, an invariant on every emitted stream, an exhaustive
   sweep, a metamorphic property, or a fuzzer.
3. **A batch of faults, not the first one.** One run yields a work list. Layout
   faults never reach the parser.
4. **Memory-safe under an adversary, and fast enough to parse a tree of files
   at once.** Arena per job, no shared mutable state, bounded recursion,
   checked integer conversion.

Non-goal: replacing `src/Wok/Parsing.hs` in this bundle. Whether it eventually
does is question Q3 below and changes nothing before S6.

## 2. Verified foundations

Everything in this section was executed on this machine before the spec was
written, not assumed.

**C23 availability** (Apple clang 21.0.0, `-std=c23 -Wall -Wextra -Wpedantic
-Wconversion -Wstrict-prototypes -Werror`):

| Feature | Status | Consequence |
|---|---|---|
| `__STDC_VERSION__ == 202311` | yes | -- |
| `enum : unsigned char` | yes | token kind is 1 byte |
| `constexpr` objects, binary literals, `'` digit separators | yes | character-class bitmaps are true constants |
| `<stdckdint.h>` (`ckd_mul`, `ckd_add`) | yes | literal overflow is a diagnostic, not UB |
| `unreachable()` | yes | behind `WOK_UNREACHABLE` (see 6.3) |
| **`[[unsequenced]]`** | **NO** -- `__has_c_attribute(unsequenced)` is 0 | needs the `WOK_PURE` fallback (see 6.3) |

**The layout rule was prototyped and measured.** A C23 probe implementing the
scanner-to-layout path was run over the whole v2 corpus:

```
21 files (9 accept + 11 reject + surface-tour)
  layout faults ......... 0
  hanging indents ....... 0
```

Three results, each load-bearing below:

- **Zero faults** -- the rule in section 5 accepts the corpus as written,
  including `surface-tour.wok:55-58`, whose hanging `in` sits at a column
  matching no open level. It survives because `in` leads a *continuation*, and
  continuations are exempt from dedent matching (rule L5).
- **Zero hanging indents** -- every INDENT in the corpus opens a block that the
  grammar already owed. Nothing in the corpus is a deeper line continuing an
  expression. This retires an entire mechanism: the parser needs no
  transparent-continuation handling, and an unexpected INDENT is simply an
  error (D-LAY-3).
- **The filter agrees with an independent model.** The C filter and a reference
  model written separately in awk were run over **all 1024 column sequences of
  length 5 over columns 1..4**; they agree on every one, including the 502 that
  are layout faults. This is the differential test that replaces the Go oracle
  for the stage where an oracle matters most, and it is exhaustive rather than
  sampled.

**Adversarial probes** (`bad/*.wok`): misaligned dedent, tab in indentation,
unclosed bracket at EOF, unclosed bracket mid-file, hanging continuation, and a
legally bracket-continued file. All behave as section 5 specifies. The
mid-file unclosed bracket is the case that forced rule L7 into its final shape:
a strict `col < block_col` test **missed it** and let a stray `(` swallow the
remaining three declarations, which is exactly the collapse the rule exists to
prevent.

## 3. Architecture

```
bytes ──scan──▶ Token[]  ──layout──▶ Token[]  ──parse──▶ AST
                (no layout tokens)   (+ NEWLINE INDENT DEDENT)
                       │                   │                │
                       └───────────────────┴────────────────┴──▶ DiagSink
```

```
grammar/c/
  wok_arena.h .c     bump arena, Slice
  wok_diag.h  .c     Diag, DiagSink, cascade suppression, cap
  wok_token.h .c     Kind + Word rosters, the scanner
  wok_layout.h .c    THE FILTER -- pure, ~200 lines, its own test binary
  wok_ast.h          the node schema (X-macro)
  wok_parse.c        blocks, declarations, types, patterns, expressions
  wok_print.c        the canonical printer (enables the round-trip oracle)
  wok_sexpr.c        dump / read, both generic over the schema
  cmd/wokparse.c     -tokens -layout -sexp -fmt -check -json
  test/              reference model, sweeps, properties, fuzzers
  testdata/tour/     the syntax tour that production coverage forces to grow
```

Each stage is a separate translation unit with a single entry point taking
`(input, Arena*, DiagSink*)`. `wok_layout.c` includes `wok_token.h` and nothing
else -- it must not be able to name a keyword or an AST node.

## 4. Stage 1 -- the scanner

### 4.1 Token

```c
typedef struct {              // 16 bytes, one cache line per 4 tokens
  uint32_t off;               // byte offset into the source
  uint32_t len;
  uint32_t col;               // 1-based; tabs are rejected, so col is exact
  uint8_t  kind;              // enum wok_kind : unsigned char
  uint8_t  word;              // interned named spelling, or WORD_NONE
  uint16_t flags;             // FIRST_ON_LINE, HAS_ESCAPE, ...
} WokToken;
static_assert(sizeof(WokToken) == 16);
```

- **Line numbers are not stored.** A `uint32_t` line-start table is built during
  the scan; line and column are recovered by binary search only when a
  diagnostic is actually rendered. Diagnostics are rare; tokens are the hot
  array.
- **Text is never copied.** `off`/`len` view the source buffer. A literal
  containing `\` sets `HAS_ESCAPE` and is decoded once, on demand, by the
  parser -- so a file with no escapes allocates nothing beyond the token array.
- `word` interns the named spellings: reserved words, contextual words, and the
  operator runs a production reads by name. `p.at_word(W_HANDLE)` fails to
  *compile* when misspelled, where a string comparison compiles and is silently
  never true.

### 4.2 Lexical rules (derived from surface.md, spec.md, and the corpus)

- **Identifiers are ASCII**, `[A-Za-z_][A-Za-z0-9_']*`. Case of the first
  character decides `ConId` vs `VarId` -- spec 1.6's governing invariant ("a
  capitalized name is never a fresh binder") is a *lexical* fact here.
  `-` is **not** an identifier character (v1's `Wok.cf:518` allows it; v2 needs
  `-` as an operator, and no `.wok` file uses a dashed name).
- **Operators are maximal runs** over ``! # $ % & * + / < = > ? @ ^ | - ~ :``.
  `->` `=>` `=` `:` `::` `:=` `|` are runs that happen to be reserved; they are
  recognised by table lookup *after* the run is taken, never by prefix peeking.
- **A line comment is a maximal run that is all dashes and at least two long.**
  Taking the run first is what stops `-->` from silently becoming a comment;
  the operator charset is then written exactly once.
- **Block comments `{- -}` nest.**
- `\` is its own token (lambda), not an operator character.
- **Negation is never glued.** `-5` is `-` then `5`; `1-2` is subtraction. The
  parser handles prefix `-` in expression and pattern operand position. This
  drops v1's documented wart (`Wok.cf:511-513`).
- **Integer literals use `ckd_mul`/`ckd_add`** in the accumulation loop.
  Overflow past `U64` is `E-LEX-INT-RANGE` at the literal's position. This is a
  defect-class elimination, not a style choice.
- **String and char literals are validated UTF-8.** wok's `String` is flat
  valid-only UTF-8 (the Slice E design); admitting an ill-formed literal here
  would push the fault to the runtime.
- **`;` is scanned and given a targeted diagnostic** ("v2 has no statement
  separator; items are delimited by columns" -- D22). It is legal v1 wok that a
  port will hit, and "unexpected character" would be a bad way to learn that.
- **A tab in a line's indentation is a fault.** Under an offside rule a tab's
  width is an invisible disagreement between editors. Tabs elsewhere are fine.

### 4.3 Contextual words

`own`, `lend`, `copy`, `row`, `eff` are scanned as ordinary `VarId` carrying
their `Word` tag, and are read as keywords only by the production that wants
them. Reserving them would break `Bytes.copy`, which **`spec.md` section 2 uses
itself**. Everything else in surface.md's palette is fully reserved.

## 5. Stage 2 -- the layout filter

```c
WokToken *wok_layout(const WokToken *in, size_t n, WokArena *, WokDiagSink *,
                     size_t *out_n);
```

Pure: same input, same output, no globals, no allocation outside the arena. It
knows three things -- a token's column, whether it opens or closes a bracket,
and one predicate over its kind and word. It cannot name a keyword.

### 5.1 The one predicate

```
CONTINUATION-LEAD(t) :=  t.kind is Operator, Comma, Dot, or any closing bracket
                      |  t.word is one of  where in then else of as with
```

These are exactly the tokens that can never *begin* a block item. The set is
derived from the grammar in section 7 and pinned by test L2-c: for every token
kind and word, `CONTINUATION-LEAD` must agree with whether any production in
`decl`, `stmt`, or `clause` can start with it. Changing the grammar without
changing the set fails the build.

### 5.2 The rules

Let `stack` be a stack of block columns, initially `[1]`, and `bracket` a
bracket-nesting depth with the block column recorded at its outermost opener.

- **L1.** Blank lines and comment-only lines produce nothing and do not affect
  indentation.
- **L2.** While `bracket > 0`, line starts produce nothing. Layout is suspended
  inside brackets so bracketed expressions may be laid out freely.
- **L3 (item line).** At the first token of a line with `bracket == 0` and not
  `CONTINUATION-LEAD`, emit `NEWLINE` (except before the file's first logical
  line), then compare the column `c` with `top`:
  - `c > top` -- emit `INDENT`, push `c`.
  - `c == top` -- nothing further; the `NEWLINE` was the item separator.
  - `c < top` -- pop and emit `DEDENT` while `top > c`; then **`top` must
    equal `c`** or it is `E-LAY-DEDENT` (see L6).
- **L4 (continuation line).** At the first token of a line with `bracket == 0`
  that *is* `CONTINUATION-LEAD`: pop and emit `DEDENT` while `top > c`, and
  emit **no** `NEWLINE`. The logical line continues.
- **L5 (no dedent matching for continuations).** L4 performs no equality check.
  A continuation is not claiming to start anything at a level, so there is no
  level for it to match. This is what makes a hanging `in`, a leading `|` in a
  multi-line `type`, and a leading `+` in a long capability row all legal:
  ```
  staged =                      type Cmd            tick : Cmd -> U64
    let n =                       = Inc U64                with Reader U64
          seed ()                 | Snapshot             + State U64
          bump 1                  | Boom
      in n * 2
  ```
  All three parse as one logical line each, with no layout tokens inside.
- **L6 (faults are repaired here, never forwarded).** `E-LAY-DEDENT` is
  reported and repaired by adopting `c` as a level. A tab in indentation is
  reported by the scanner. Depth beyond `MAXDEPTH` (64) is reported and
  clamped. **In every case the emitted stream stays well formed**, so the
  parser never sees a layout error -- inconsistent dedent is not a grammar
  fault and has no business being reported as one.
- **L7 (bracket abandonment).** While `bracket > 0`, a line whose first token is
  **not** `CONTINUATION-LEAD` and whose column is `<=` the block column recorded
  when the outermost bracket opened cannot be a continuation of anything inside
  that bracket. Report the unclosed bracket **at its opening position**,
  force-close every open bracket, and re-process the line under L3.

  This is the rule the probe forced. An unclosed `(` is the one failure mode
  where suppressed layout destroys the whole file, and indentation is an
  independent witness that survives it. Measured: `f = (a + b` followed by
  `g : U64` now yields **one** diagnostic and three recovered declarations;
  under a strict `<` test it yielded one diagnostic and a swallowed file.
- **L8 (EOF).** Emit `NEWLINE`, then a `DEDENT` per open level. An unclosed
  bracket at EOF is reported at its opening position.

### 5.3 Invariants (asserted on every emitted stream, in every build)

1. `INDENT`/`DEDENT` are balanced and properly nested; the stack is empty at EOF.
2. Pushed columns are strictly increasing.
3. Every `DEDENT` is preceded by a `NEWLINE` (possibly with other `DEDENT`s
   between). The parser may therefore treat `NEWLINE DEDENT` as one boundary.
4. No `NEWLINE`, `INDENT` or `DEDENT` appears between a bracket opener and its
   matching closer.
5. Output length is bounded by `n + 2 * MAXDEPTH + lines`.

These hold **even for input full of layout faults** -- that is the contract that
lets the parser be written without defensive code.

## 6. Stage 3 -- the parser

Recursive descent, one function per production, named after it. Arena-allocated
immutable nodes, child lists as `{ptr, len}` slices.

### 6.1 The block rule (the only place layout tokens are read)

```
BLOCK(x) :=  NEWLINE INDENT x (NEWLINE x)* NEWLINE DEDENT      -- indented
          |  x                                                 -- inline, one item
```

The parser calls `block(...)` **only where the grammar already owes a block**:
after `=`, `of`, `->`, `where`, and after an `effect` / `class` / `instance` /
`foreign module` / `handler` head. Everywhere else:

- **D-LAY-3**: an `INDENT` where no block is due is `E-LAY-INDENT`
  ("unexpected indentation; to continue a line, begin it with an operator, or
  bracket the expression"). The corpus contains zero such cases, so this costs
  nothing and buys a parser with no continuation machinery at all.
- a `NEWLINE` with no `INDENT` where a block is due is `E-LAY-EXPECTED-BLOCK`.

### 6.2 Recovery, in two tiers

Recovery happens in exactly one place: the block-item loop.

- **Tier 0 -- suppression and cap.** A second complaint at an already-reported
  position is dropped. Twenty faults ends the run.
- **Tier 1 -- local repair** (Diekmann & Tratt, CPCT+, with a fixed budget
  rather than a search). At a fault inside an item, try at most three
  single-token edits -- delete the offending token, insert the expected one,
  substitute -- and accept the first that then consumes four further tokens
  without a new fault. One repair per item, no backtracking beyond the item.
- **Tier 2 -- region discard** (de Jonge / Kats / Visser / Soderberg). Abandon
  the item, emit an `ErrNode` in its place so the block skeleton survives, skip
  to the next `NEWLINE` at the block's level or to its `DEDENT`, restore the
  bracket flag, resume. **`DEDENT` is a free synchronisation point** -- it is
  arithmetic from columns, not a guess about what a `}` meant. A damaged item
  can never swallow the block containing it.
- Declaration blocks additionally resynchronise only at an *anchor* -- a
  declaration keyword, or `name :` at the block column. Forward-only
  declarations (D23) are what make a signature the strongest anchor available:
  `name : Type` at a block column can never be the tail of a damaged item.

`ErrNode` exists (unlike in the Go instrument) because tier 2 needs the
skeleton to survive, and because it is what an editor would need later.
`err != nil` still means do not type-check.

### 6.3 Safety mechanics

```c
#if defined(__has_c_attribute) && __has_c_attribute(unsequenced)
#  define WOK_PURE [[unsequenced]]
#elif defined(__GNUC__)
#  define WOK_PURE __attribute__((const))     // same contract, works today
#else
#  define WOK_PURE
#endif

#ifdef NDEBUG
#  define WOK_UNREACHABLE() unreachable()
#else
#  define WOK_UNREACHABLE() wok_abort_unreachable(__FILE__, __LINE__)
#endif
```

`WOK_PURE` goes on the character-classification predicates, which are the
scanner's inner loop and are genuinely stateless. `unreachable()` is UB if
reached, so it never appears raw.

- **No `default:` label in any switch over a token kind or node tag.** A
  missing enumerator is then `-Werror=switch`, which subsumes the whole
  roster-test family. Switches that genuinely need a fallback use
  `-Wswitch-enum`, which warns even with a default present.
- **Bounded recursion.** The parser carries a depth counter with a hard limit
  (200) reported as `E-DEPTH`. `((((((...` blowing the C stack is the second
  classic parser CVE after literal overflow, and `<stdckdint.h>` only covers
  the first.
- No VLAs, no `alloca`, no implementation-defined layout assumptions.

### 6.4 Memory and batch parsing

- **One arena per job**; a job is `{source, arena, diag sink}`. Nodes are
  immutable, built once, and die together, which is an arena's exact shape.
  Teardown frees a block list.
- **No shared mutable state**, so *N* files parse on *N* threads with no
  locking. The only shared data is the reserved-word table, which is
  `constexpr` and read-only.
- Token vector sized from the source length up front; scanning then allocates
  nothing after the first block.
- The filter writes a second token vector rather than editing in place. At
  16 bytes a token this is affordable and keeps stage 2 pure -- which is the
  whole point.

## 7. The grammar, over the post-layout token stream

Derived from `surface.md` sections 3-6, `spec.md` 1.1-1.6, and the corpus.
`{x}` is zero or more, `[x]` optional.

```ebnf
file      = decl {NEWLINE decl} NEWLINE ;

decl      = "module" modpath
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

typaram   = VarId | "(" "row" VarId ")" ;
condef    = ConId {atomtype} | ConId "{" fields "}" | "{" fields "}" ;
sig       = signame {"," signame} ":" type ;
signame   = VarId | "(" VarSym ")" ;
equation  = lhs "=" body [ "where" BLOCK(sig | equation) ] ;
lhs       = VarId {atompat} | "(" VarSym ")" {atompat}
          | atompat (VarSym | "`" VarId "`") atompat ;

type      = arrow "=>" type | arrow [ "with" row ] ;
arrow     = typeapp [ "->" arrow ] ;
typeapp   = [transfer] atomtype {atomtype} ;      (* transfer: foreign sigs only *)
transfer  = "own" | "lend" | "copy" ;
atomtype  = VarId | ConId {"." ConId} | "[" type "]"
          | "(" ")" | "(" "row" VarId ")" | "(" type {"," type} ")" ;
row       = rowentry {"+" rowentry} ;
rowentry  = "(" VarId ":" typeapp ")"      (* role obligation, D20 -- lowercase *)
          | "eff" VarId                    (* row variable                      *)
          | typeapp ;                      (* designation-slot obligation, P2   *)

body      = expr | BLOCK-form of stmt ;
stmt      = "let" bind
          | "handle" label "=" expr        (* statement form: label REQUIRED, D13 *)
          | "use" usebinds
          | "_" "=" body
          | expr ;
bind      = VarId {atompat} "=" body | pat "=" body ;
usebinds  = name "as" name {"," name "as" name} ;

expr      = "\" {atompat} "->" body
          | "let" bind "in" body
          | "handle" [label "="] expr "in" body   (* inline: label elidable, D13 *)
          | "use" usebinds "in" body
          | "if" expr "then" body "else" body
          | "case" expr "of" BLOCK(alt)
          | "handler" ConId BLOCK(clause)
          | chain [":=" body] ;
alt       = pat "->" body [ "where" BLOCK(sig | equation) ] ;
chain     = app {infixop app} ;                   (* FLAT: no precedence here *)
infixop   = VarSym | "::" | "`" VarId "`" ;
app       = "-" app | atom {atom} ;
atom      = VarId | ConId | Int | String | Char
          | "(" ")" | "(" VarSym ")" | "(" expr {"," expr} ")"
          | "[" [expr {"," expr}] "]"
          | atom "." (VarId | ConId)
          | conatom "{" [".." expr [","]] [field {"," field}] "}" ;

clause    = "var" VarId "=" body
          | "return" pat "->" body
          | "once" VarId {atompat} VarId "->" body   (* last binder IS the k, D14 *)
          | VarId {atompat} "->" body ;

pat       = patapp ["::" pat] ;
patapp    = ConId {atompat} | atompat ;
atompat   = ( VarId | "_" | Int | "-" Int | String | Char
            | ConId {"." ConId} ["{" fieldpats "}"]
            | "(" ")" | "(" pat {"," pat} ")" | "[" [pat {"," pat}] "]" )
            {"as" VarId} ;
```

Two rules of FORM are enforced by the parser because they are grammar facts,
not analyses: a `handle` **statement** must write its label (P1/D13), and a
`once` clause's continuation binder must be a plain lowercase name (D14).
Everything with a diagnostic code in spec section 3 belongs to a later pass.
Operator precedence is not in the parser: chains stay flat, exactly as
`src/Wok/Reordering.hs` already expects.

## 8. The harness

Six layers, weakest to strongest. No stage is believed because it was written
carefully.

- **H1 -- compile time.** The `Kind`, `Word` and node-tag rosters are X-macros;
  every table keyed by one carries `static_assert(count == N)`. With no
  `default:` labels, a node added to the schema without a dump, read or print
  case does not build.
- **H2 -- the layout filter, exhaustively.** (a) The reference model and the C
  filter must agree over *all* column sequences up to length 7 over columns
  1..5 -- 78,125 cases, seconds to run, and the strongest guarantee in the
  build. (b) Invariants 5.3.1-5.3.5 are asserted on every stream the filter
  ever emits, including in fuzzing. (c) `CONTINUATION-LEAD` is cross-checked
  against the grammar: for every kind and word, the predicate must agree with
  whether any item production can start with it.
- **H3 -- metamorphic properties** (this is what replaces a second
  implementation). Over the corpus:
  - **re-indentation invariance** -- uniformly widening every indent level in a
    file must yield a byte-identical AST dump. This is the property no
    single-implementation parser usually has, and under an offside rule it is
    the one that matters.
  - `Dump(Parse(Format(t))) == Dump(t)` -- printing did not change the program.
    Load-bearing: under layout, a line break in the wrong place is *not* a
    syntax error, so the output still parses and only the tree shows the damage.
  - `Format(Parse(Format(t))) == Format(t)` -- the formatter is a fixed point,
    so `-check` never flags a file it just wrote.
  - `Dump(Read(Dump(t))) == Dump(t)` -- the dump forgot no field.
- **H4 -- production coverage, not line coverage.** A bitmap indexed by
  production id, set on entry. The corpus must reach 100%; a production no file
  reaches fails the build and names itself. This is what forces
  `testdata/tour/` to grow with the grammar rather than after it.
- **H5 -- sanitisers and arena invariants.** ASan + UBSan over corpus and fuzz
  corpus, wired into `scripts/asan-runtime.sh` beside the existing runtime
  tests. Arena bytes return to baseline after every job.
- **H6 -- fuzzing.** libFuzzer over `#embed`ded corpus seeds. Invariants: no
  crash, no UB, no leak; the filter's output is always balanced (5.3); the
  diagnostic count never exceeds the cap; and on accept, H3's round-trip holds.
  Mutating real corpus files is what finds the offside and bracket cases no
  hand-written test proposes.

## 9. Slices

Each is independently reviewable and leaves the tree green. Tier assigned after
the steps were written, per the routing rule.

| # | Slice | Gate | Tier |
|---|---|---|---|
| S0 | arena, diag sink, Makefile, ASan/UBSan targets, `#embed` wiring | arena leak invariant; builds `-Werror` | mechanical |
| S1 | `wok_token.h` rosters + scanner | token goldens; `ckd` overflow and UTF-8 cases; H1 live | standard |
| S2 | **`wok_layout.c` + reference model** | H2 (a)(b)(c) green; corpus 0 faults; L7 probes | **frontier** |
| S3 | `wok_ast.h` schema + generic dump + generic read | H3 property 4 on hand-built trees | **frontier** |
| S4 | declarations, types, patterns | corpus parses; `testdata/tour` grows to keep H4 at 100% | standard |
| S5 | expressions, statements, handler clauses | whole corpus parses; H4 at 100% | standard |
| S6 | recovery tiers, batch diagnostics, CLI | recovery fixtures; one fault per damaged item | standard |
| S7 | canonical printer | **H3 properties 1-3 green** | standard |
| S8 | H4 harness, H6 fuzzer, CI wiring | fuzzer clean overnight | **frontier** |

S2 is frontier because a subtly wrong layout filter produces a parser that
works on the corpus and is wrong. S3 is frontier because the schema is what
everything else is derived from. S2 starts from the probe already written and
measured, not from zero.

## 10. Decisions this spec makes, and what they cost

| # | Decision | Cost |
|---|---|---|
| D-LAY-1 | The first token of a line decides item vs continuation, purely lexically | the set must track the grammar; pinned by H2(c) |
| D-LAY-2 | Dedent matching is strict for item lines, absent for continuation lines | none measured -- it is what makes the corpus pass as written |
| D-LAY-3 | An INDENT where no block is due is an error, not a continuation | unbracketed hanging continuation is unwritable; corpus uses it zero times |
| D-LAY-4 | Bracket abandonment forces closure at `col <= block col` with an item lead | a continuation line inside brackets starting at or left of the block column, with an item-lead token, is rejected. Pathological formatting; the file it saves is the common case |
| D-LEX-1 | `-` always lexes as an operator; no glued negative literals | `f =` / `a` / `-b` reads as `a - b`. Matches v2's own `1-2` decision (Q1) |
| D-ERR-1 | `ErrNode` exists | a partial tree can be inspected; `err != nil` still means do not trust it |

## 11. Questions for you

1. **`-` as a continuation lead (D-LEX-1).** A block line beginning with `-`
   joins the previous line, so a final block value written `-n` becomes
   subtraction. Workaround is `(-n)`. I recommend accepting: cross-line
   subtraction is far more common than a statement beginning with negation, and
   it is the same call v2 already made for `1-2`.
2. **Comments as trivia.** Discarding them (the Go instrument's limitation)
   means `-fmt` must never touch a file a human kept. Building trivia into the
   schema is much cheaper now than retrofitting after S3. I recommend building
   it in at S3, since the schema is generated and the cost is one field.
3. **Is this a design instrument or the future front end?** The spec assumes
   instrument. If it is meant to replace `src/Wok/Parsing.hs`, S3's dump becomes
   an interchange format with a Haskell reader and that changes S3's shape.
4. **`fixity` declarations.** surface.md's palette drops them, so section 7 does
   not parse them -- but flat operator chains need a fixity source eventually.
   Leave unparsed, or parse them now with `left`/`right`/`tighter`/`than` as
   contextual words?
5. **Corpus size.** 21 files will not reach 100% production coverage.
   `testdata/tour/` has to be written as part of S4/S5, and H4 is what forces
   it. Confirm that growing the corpus is in scope rather than a follow-up.

## 12. Risks

1. **`-Wswitch` is a compiler feature, not an ISO one.** Mitigated by the
   no-`default:` discipline and by both toolchains implementing it. If it
   lapses, H3 and H6 still catch the consequence.
2. **X-macro diagnostics are bad.** An error inside a schema expansion points at
   the macro. Mitigated by keeping the schema flat and per-field macros trivial.
   Judge after S3 rather than argue now.
3. **The printer is the largest hand-written piece with no derivation
   available**, and H3 depends on it. It is scheduled after the parser so its
   oracle is exact when it lands.
4. **`CONTINUATION-LEAD` is a grammar fact living in a grammar-blind stage.**
   H2(c) is the only thing keeping them in step; if that test is ever weakened,
   this design's central claim goes with it.
