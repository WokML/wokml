---
spec: generative-testing
status: awaiting review
depends: 2026-08-03-c23-frontend-design.md
---

# Generative testing: build trees, not text

## 1. Why trees, and not source

The fuzzers generate SOURCE. That is the right shape for testing the error
path, and it is measurably inefficient for testing the happy one: of 14,000
mutated inputs, 5,688 parsed cleanly, so more than half the work re-tests
recovery, which is already covered.

Generating ASTs inverts it. Every generated tree is valid by construction, so
every case exercises the printer and the parser against each other:

```
parse(print(t))              is t
print(parse(print(t)))       is print(t)
```

That is what `test_metamorphic` already checks -- over 25 files somebody
thought to write. Generation runs it over the SPACE those 25 files are drawn
from. It is the difference between "every node was built once" (which
production coverage already asserts) and "every COMBINATION was tried", which
nothing asserts today.

Concretely, it is what would have found the printer's `where`-placement rule
and its continuation-lead cases without a human first inventing a file that
exhibits them.

## 2. The prerequisite the schema does not currently meet

`wok_ast.h` declares a field's CLASS -- `NODE`, `OPT`, `SEQ`, `NAME`, `INT` --
but not its expected FAMILY. `E_App.fn` is a `NODE`, and nothing records that
it must be an EXPRESSION rather than a type or a pattern.

The tag names encode the family of a NODE (`E_`, `P_`, `T_`, `D_`, `S_`, `L_`,
`N_`, `H_`, `W_`), but that is the family a node HAS, not the family a FIELD
demands. A generator needs the second.

Two ways to get it, and they differ in ambition rather than in difficulty:

**(a) A generator-local table.** One line per NODE/OPT/SEQ field naming the
family it accepts. Contained, no schema change, and duplicates knowledge that
lives in `wok_parse.c`.

**(b) A family in the schema:** `F(T, NODE, fn, EXPR)`. 156 mechanical edits,
and it pays for itself TWICE -- the generator gets its table for free, and the
s-expression READER becomes strict. Today the reader will happily accept a
type node in an expression slot, so a corrupted dump round-trips into a
different program without complaint.

**Recommendation: (a) for slice 1, (b) once the approach has proved it finds
things.** The point of slice 1 is to learn whether generation surfaces
anything at all; paying 156 edits before knowing that is backwards. If slice 1
finds nothing, (b) is still worth doing for the reader alone, on its own
merits.

## 3. Properties

For every generated tree `t`:

| property | fails when |
|---|---|
| `dump(parse(print(t))) == dump(t)` | the printer and the parser disagree about a shape |
| `print(parse(print(t))) == print(t)` | the formatter is not a fixed point on that shape |
| `print(t)` parses with ZERO diagnostics | the printer emitted something the parser rejects |
| `print(t)` satisfies the layout invariants | the printer emitted layout the filter would repair |
| the printer's safety assertion never fires | a generated shape provokes a tree-changing line break |

The first is load-bearing and the reason to compare dumps rather than text:
under an offside rule a misplaced break is not a syntax error, so the output
still parses and only the tree shows the damage.

## 4. Two things that decide whether this is usable

**Determinism.** The generator is seeded, and a failure prints the seed. A
property-based test that cannot reproduce its own counterexample is a rumour.

**Shrinking.** A 200-node counterexample is unreadable and nobody will act on
it. On failure, minimise before reporting: replace a subtree with a leaf of
the same family, drop an element from a sequence, retry, and keep the smallest
tree that still fails. Most real counterexamples shrink to under ten nodes,
and that is the difference between a bug report and a puzzle.

Shrinking is deliberately NOT in slice 1 -- see the staging below -- but the
generator must be written so it can be added, which mainly means: no global
state, and generation is a pure function of (seed, depth budget).

## 5. Staging

| # | Slice | Gate | Tier |
|---|---|---|---|
| G1 | schema-driven generator for EXPRESSIONS and TYPES only, family table local to the test, properties 1-5, seeded, no shrinking | 5,000 trees per run, all properties hold; a deliberately corrupted printer is caught | standard |
| G2 | shrinking | an injected fault reports a tree under 10 nodes | standard |
| G3 | patterns, declarations, statements, handler clauses | 100% tag coverage from generation alone, with no corpus | standard |
| G4 | promote the family table into the schema (option b) and make the sexpr reader strict | a type node in an expression slot is REJECTED by the reader | **frontier** |

G1 is scoped small on purpose: expressions and types are where the printer's
precedence and line-filling logic lives, so they are where a disagreement is
most likely, and the family table for them is about forty entries rather than
156.

The G1 gate includes "a deliberately corrupted printer is caught" because a
generative test that passes against a broken implementation is worse than no
test -- it is the same trap the exhaustive UTF-8 sweep caught when the first
DFA table returned 0 for ASCII and fourteen suites stayed green.

## 6. What this does NOT replace

- The corpus. Generated trees are valid but not IDIOMATIC; the corpus is what
  says the output is readable.
- The fuzzers. They test the error path, which generation never reaches.
- Production coverage. It asserts every node is built at least once, which
  generation would satisfy accidentally rather than by design.

## 7. Open questions

1. **Should generated trees be printed as a corpus artefact when they find a
   bug?** A minimised counterexample is a natural `testdata/` fixture, and
   promoting it automatically would grow the corpus with exactly the shapes
   nobody thought of. It also risks a fixture directory nobody understands.
2. **How much of the schema's implicit invariants must the generator know?**
   A `once` clause needs its `k` binder; `D_Sig` needs at least one name; an
   `E_Chain` with zero ops should have been collapsed to its head by the
   parser. Each is a rule that lives in `wok_parse.c` and would be restated in
   the generator. Slice 1 is small enough to enumerate them; G3 is where this
   becomes the main cost.
3. **Is `print` total over the generated space?** The printer refuses some
   things (depth beyond 256, an unbreakable overflow). Those are legitimate
   refusals, and the generator must either avoid producing them or the
   properties must exempt them explicitly rather than by accident.
