# Handoff prompt: generative testing for the wok C front end (slice G1)

Paste everything below the line into a fresh session.

---

Implement slice **G1** of generative testing for the wok C23 front end, in
`/Users/zy/wokml/grammar/c/`.

## Read these first, in this order

1. `docs/superpowers/specs/2026-08-03-generative-testing-design.md` — THE SPEC.
   Read all of it. Section 2 (the family prerequisite), section 4
   (determinism and shrinking) and section 5 (why G1 is scoped to expressions
   and types) are the parts that decide the shape of the work.
2. `grammar/c/wok_ast.h` — the schema. 82 node tags, generated accessors
   `TAG_field(n)` and setters `TAG_set_field(n, v)`, and the descriptor table
   `wok_node_desc[]` that every generic walk uses.
3. `grammar/c/test/test_metamorphic.c` — the round-trip properties you are
   generalising from 25 corpus files to a generated space.
4. `grammar/c/test/test_layout_sweep.c` — the closest existing model: it
   synthesises inputs rather than reading them, and cross-checks against an
   independent implementation. Follow its shape.
5. `grammar/c/wok_print.c` and `wok_parse.c` — what you are testing against
   each other.

## What to build

`grammar/c/test/test_generative.c`, and nothing else. Do not modify the
schema, the parser, the printer, or any header. If you believe one of them is
wrong, STOP and report it rather than changing it — a generative test that
alters the thing it tests proves nothing.

A schema-driven generator that builds well-formed **expression** and **type**
trees, prints them, re-parses, and checks the five properties in spec
section 3.

Requirements that are not negotiable:

- **Seeded and deterministic.** A failure must print the seed and the
  minimised tree's dump. A property test that cannot reproduce its own
  counterexample is a rumour.
- **No global mutable state in the generator.** Generation is a pure function
  of (seed, depth budget). Slice G2 adds shrinking and will need this.
- **Arena only.** No malloc, no VLA, no alloca.
- **C23**, clean under the full warning set in `grammar/c/Makefile`:
  `-std=c23 -Wall -Wextra -Wpedantic -Wconversion -Wstrict-prototypes -Wshadow
  -Wswitch -Wvla -Werror`. No `default:` label in a switch over `WokTag` or
  `WokKind`.
- Use the short type names from `include/wok_base.h` (`u32`, `usize`, …), not
  `uint32_t`. Use `WOK_PURE` / `WOK_READONLY` / `restrict` where they are
  TRUE — read the comments in that header, they say exactly what each promises.
- No emoji. Comment WHY, not WHAT.

## The family table

The schema records a field's CLASS but not the FAMILY it expects: `E_App.fn`
is a `NODE`, and nothing says it must be an expression. For G1 keep that table
**local to the test file** — roughly forty entries covering the `E_*` and `T_*`
tags. Do not promote it into the schema; that is slice G4 and it is deliberately
deferred until this slice has shown generation finds anything.

## The gate

```
cd /Users/zy/wokml/grammar/c
make clean && make all && make test        # 18 suites, all ok
make sanitize                              # clean over the corpus
```

Your test must run **5,000 trees per invocation** and finish in a second or
two, so it can live in `make test` rather than in a soak target.

**And it must be proved to work.** Deliberately corrupt the printer — e.g.
make it drop parentheses it should emit, or place a `where` one column off —
confirm your test FAILS and names the property, then revert. Report both the
corruption you used and the failure output.

That last step is not optional. The exhaustive UTF-8 sweep in this repo caught
a completely broken DFA table that fourteen existing suites passed with,
because the fast path bypassed it. A generative test that passes against a
broken implementation is worse than no test.

## Report

- the file written and the gate output;
- the corruption you injected and the failure it produced;
- **anything the generator found** — with the seed and the minimal reproducer,
  even if you believe it is a generator bug rather than a front-end bug;
- every implicit schema invariant you had to encode (spec section 7 question 2
  lists some: a `once` clause needs its `k`, `D_Sig` needs a name, `E_Chain`
  with zero ops should be its bare head). This list is the real output of the
  slice — it is the knowledge that currently lives only in `wok_parse.c`.
