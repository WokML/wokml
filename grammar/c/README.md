# wok v2 front end in C23

Three stages, not two:

```
bytes ──scan──▶ Token[]  ──layout──▶ Token[]  ──parse──▶ AST
                                (+ NEWLINE INDENT DEDENT)
```

The middle stage is a **pure function over token streams**. That is the single
architectural decision the rest of this package is built around, and it is what
makes the offside rule testable rather than merely written carefully.

Design contract: `docs/superpowers/specs/2026-08-03-c23-frontend-design.md`.
Surface: `docs/redesign/spec.md` and `docs/redesign/surface.md` (v2).

```
make            build the library and the CLI
make test       every test binary
make sanitize   the same, under ASan + UBSan, plus the corpus
make sweep      the exhaustive layout sweep
make fuzz       the libFuzzer targets (needs a full LLVM; see below)
```

## Why the layout filter is its own stage

Haskell's `parse-error(t)` rule requires the parser to feed back into the layout
algorithm. That is genuine context-sensitivity, and it is why no two Haskell
implementations agree on edge cases. Here there is no feedback edge: the filter
sees columns, bracket nesting, and one lexical predicate. It cannot name a
keyword.

The payoff is that the whole input space can be *enumerated*. `test_layout_sweep`
synthesises token streams directly — no source files — and checks 36,864 of them
against an independently written reference model, token for token.

### The rule

**The first token of a line decides whether that line is a new item or a
continuation of the previous one.**

A token that can never *begin* a block item — `where`, `in`, `then`, `else`,
`of`, `as`, `with`, and every operator lead — marks its line as a continuation:
the filter emits the DEDENTs needed to close deeper regions and **suppresses the
item-separator NEWLINE**. Strict dedent matching then applies only to lines that
genuinely start an item.

This is what admits the shapes wok actually uses, all of which strict
Python-style layout rejects:

```
staged =                type Cmd            tick : Cmd -> U64
  let n =                 = Inc U64                with Reader U64
        seed ()           | Snapshot             + State U64
        bump 1            | Boom
    in n * 2
```

Each is **one logical line** with no layout tokens inside it. The hanging `in`
lands on a column matching no open level and is legal precisely because a
continuation is not claiming to start anything at a level.

Measured over the 21-file v2 corpus: **zero layout faults, and zero "hanging
indents"** — every INDENT opens a block the grammar already owed. So the parser
needs no transparent-continuation machinery at all, and an INDENT where no block
is due is simply an error.

### Bracket abandonment (L7)

Layout is suspended inside brackets, so an unclosed `(` would otherwise swallow
the rest of the file into one logical line. Indentation is an independent
witness that survives: a line **starting an item** at or left of the block column
that was current when the bracket opened cannot be inside it. The filter reports
the unclosed bracket at its *opening* position, force-closes, and resumes.

```
f = (a + b        ->  one diagnostic at the `(`, and g/h still parse
g : U64
g = 1
h = 2
```

A strict `col <` test was tried first and **missed exactly this case**, which is
why the rule uses `col <=` with an item lead.

## What each stage decides

| Stage | Decides | Cannot see |
|---|---|---|
| scanner | everything that depends on source TEXT: kind, interned word, line-start flag | — |
| layout | columns, brackets, one predicate | keywords, grammar |
| parser | grammar; reads only token FIELDS | source bytes |

No production reads a token's text to make a decision. `at_word(WW_HANLDE)`
fails to *compile*; `at_kw("hanlde")` would have compiled, run, and simply never
been true.

## The harness

| Layer | What it is | Status |
|---|---|---|
| H1 compile time | X-macro rosters, `static_assert` on every keyed table, no `default:` label so a missing enumerator is `-Werror=switch`; every field declares the FAMILY it demands, and the s-expression reader enforces it | live |
| H2 layout | 36,864-sequence exhaustive sweep vs a reference model; invariants on every emitted stream | live |
| H3 metamorphic | re-indentation invariance, `Dump(Parse(Format(t))) == Dump(t)`, formatter fixed point, dump round-trip | partial |
| H7 generation | the same properties over 5,000 **built** trees per run, reaching 80 of the schema's 82 tags with no corpus; failures are minimised before they are reported | live |
| H4 production coverage | a bitmap indexed by node tag; the corpus must reach 100% | wired |
| H5 sanitisers | ASan + UBSan over corpus and fuzz corpus; arena returns to baseline | live |
| H6 fuzzing | properties under mutation: invariants, **conservation**, **purity** | live |

Line coverage is nearly worthless for a parser. Production coverage plus
differential testing is worth more than any coverage number.

### Fuzzing without libFuzzer

Apple's Command Line Tools ship no libFuzzer runtime, so the properties would
otherwise run only on a machine with a full LLVM — which is to say, rarely. The
properties therefore live in `test/layout_props.h` and have two drivers:
`test/fuzz_layout.c` (libFuzzer) and `test/test_fuzz_layout.c` (a deterministic,
fixed-seed mutation driver that runs in `make test` everywhere).

The properties are stronger than "did not crash":

- **invariants** — the stream is well formed even for input full of faults;
- **conservation** — every non-layout token in the output is a scanner token,
  unaltered and in order. A filter that invented or dropped a token would still
  satisfy the structural invariants;
- **purity** — running the filter twice on the same tokens gives an identical
  stream. This is the property the whole three-stage split exists to make true,
  and the one a stray static or a reused buffer would break.

This driver has already paid: it found that invariant 4 ("no layout token inside
a bracket group") is **false** once L7 fires, because `f = (a` / `g = 1)`
abandons a bracket that a later closer still balances. Inferring the exception
from the diagnostic sink was tried and is unsound — the cap can swallow the
bracket fault — so the invariant is now an explicit opt-in for input known to be
well formed.

### Generating trees, not source

The fuzzers generate SOURCE, which is the right shape for the error path and a
measurably poor one for the happy path: more than half of a mutated corpus
parses cleanly and so re-tests recovery, which is already covered.
`test/test_generative.c` inverts it. Every tree is BUILT from the schema, so it
is valid by construction and every case exercises the printer and the parser
against each other — the difference between "every node was built once", which
H4 already asserts, and "every COMBINATION was tried", which nothing else does.

It found a printer bug on its first run — `(-a) b` was printed as `-a b`, which
reads back as `-(a b)` — now closed by the `EP_NEG` rung in `wok_print.c`. It
found a second of the same class once patterns arrived: `f (-1) = 2` printed as
`f -1 = 2` and read back as the infix equation `f - 1 = 2`, now closed by
guarding an equation's first argument. And it is the only suite that catches that class of thing: with a negated
negation deliberately left unbracketed, so that `- -x` is emitted and scans as
a comment, seventeen suites stay green and this one fails.

A counterexample is MINIMISED before it is reported, on the tree and never on
the text — dropping a bracket does not make a program smaller, it makes it a
different program. A hundred-node tree reduces to under ten in a few dozen
candidates, and what is printed is the reduced tree's dump, which
`wok_sexpr_read` reads straight back.

## C23, and what it actually bought

Probed on this machine (Apple clang 21) before anything was written:

| Feature | Where it is used |
|---|---|
| `enum : unsigned char` | token kind is one byte; a `WokToken` is 16 |
| `constexpr` + binary literals + `'` separators | the symbol charset is a bitmap written once, readably, as `BIT('!') \| BIT('#') \| ...` |
| `<stdckdint.h>` | `ckd_mul`/`ckd_add` in the digit loop. Literal conversion is where parsers get CVEs; this is a defect-class elimination |
| `unreachable()` | exhaustive dispatch, behind `WOK_UNREACHABLE` which aborts in debug — it is UB if reached, so it never appears raw |
| `[[fallthrough]]` | `_` is the wildcard, `_foo` is a name: one deliberate fallthrough, now stated |
| **`[[unsequenced]]`** | **not available** — `WOK_PURE` falls back to `__attribute__((const))`, which is the same contract and does the hoisting today |

The other CVE class, unbounded recursion, is not covered by any of these: the
parser carries an explicit depth cap.

## Memory

One arena per job; a job is `{source, arena, diag sink}`. Nodes are immutable,
built once, and die together — an arena's exact shape. Teardown frees a block
list. No shared mutable state, so *N* files parse on *N* threads with no
locking; the only shared data is the reserved-word table, which is read-only.

Token text is never copied — `off`/`len` view the source. Line numbers are not
stored: a line table resolves them only when a diagnostic is actually rendered.

## Diagnostics

A batch, not the first fault. `file:line:col: message`, plus `-json`. Item
granularity, resynchronisation at anchors, cascade suppression at an
already-reported position, and a cap of 20.

Layout faults are **repaired in the filter and never forwarded**. An
inconsistent dedent is not a grammar error and has no business being reported as
one.

## Limits

- Comments are collected into a side list but not yet attached to nodes, so
  `-fmt` must not be run over a file a human wrote and kept. Closing this needs
  trivia in the schema; the side list is there so that does not mean re-opening
  the scanner.
- `fixity` declarations are not parsed — surface.md's palette drops them. Flat
  operator chains will need a fixity source eventually.
- Columns are counted in bytes. Identifiers are ASCII, and indentation is
  spaces, so this only affects a diagnostic column after non-ASCII text on the
  same line.
