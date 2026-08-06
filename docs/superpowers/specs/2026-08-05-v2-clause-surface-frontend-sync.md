---
spec: grammar/c — v2 clause surface sync
status: V1, V2 and V3 IMPLEMENTED; five diagnostic codes await a registry decision
depends: 2026-08-03-c23-frontend-design.md, docs/redesign/spec-min.md (through D28)
---

# Syncing the C front end to the 2026-08-04 clause surface

The front end was written on 2026-08-03. Every decision from D24 onward
landed after it, so its clause grammar is the v1 one: `once` is a keyword,
the continuation is the LAST binder of a keyword-headed clause, and there is
no `abort`. This spec is the delta and the slicing, not a rewrite: the
scanner/layout/parser/printer split, the rosters, and the harness all stand.

## 0. What was measured first

`wokparse -check-only` over the 26-file conformance corpus, on the tree as it
stands:

| file | fault today |
|---|---|
| accept/04, accept/08, accept/12, reject/03, reject/08, reject/10, reject/13, reject/14 | `expected \`->\` after the clause's patterns, found \`,\`` |
| accept/10, reject/12 | **parses silently and WRONG** — `abort throw e -> Err e` reads as a plain clause named `abort` with patterns `throw e` |
| reject/13, spec-min §6 `race` | `unexpected indentation` — see delta C |

The second row is the dangerous one: the surface the spec calls a new clause
kind is, today, a legal plain clause with a two-argument head. Nothing fails;
the tree is simply a different program. That is the class of defect the
schema and the generative harness exist to catch, and neither can catch it,
because both are downstream of the grammar being right.

## 1. The delta, against spec-min §1–3

### A. Word roster (spec-min §1)

- **A1** `once` moves `WT_KEYWORD` → `WT_VARID`. Per D25 it is "NOT a
  keyword; reserved at clause-head position only". It joins the contextual
  register beside `own`/`lend`/`copy` — the register exists exactly for a
  word one production reads and every other sees as a name.
- **A2** `abort` is added as `WT_KEYWORD` (spec-min §1 lists it among the law
  words). It is a clause head, so it is not a continuation lead.

Nothing else in spec-min §1 is missing from the roster.

### B. Clause grammar (spec-min §2–3)

The classification becomes exactly spec-min §3, in order, and reads nothing
but token kinds and words:

1. `var` / `return` / `abort` at the head → that kind.
2. `once` at the head → migration diagnostic, then parse on as an op clause.
3. otherwise an op clause; a `,` at clause-head depth before `->` makes it
   CONTROL, no comma makes it PLAIN.
4. in a control head, exactly one bare lowercase varid follows the comma.

- **B1** `WOK_CLAUSE_ONCE` → `WOK_CLAUSE_CONTROL`. The `k` field survives
  unchanged; only how it is FOUND changes — the comma delimits it instead of
  "last of the binder run". This is what makes D14's arity comparison direct
  for control clauses and is why the field was split in the first place.
- **B2** New `WOK_CLAUSE_ABORT = 4`: `abort varid pattern* -> body`, `k`
  empty. The kind roster becomes five, closed under D24.
- **B3** Parse-time E-ARITY, the two forms spec-min §4 names: a comma
  followed by a non-varid, and more than one name after the comma. Both are
  `perr_form` (report, do not panic): the clause is otherwise complete and
  keeping its node is worth more than discarding it.
- **B4** `WOK_E_ONCE_BINDER` is retired. Its rule — "the last binder must be
  a plain lowercase name" — is not a rule any more; the comma decides where
  the binders end, so nothing has to be re-read as a continuation. Its
  fixture is replaced, not deleted (§4).

**Why a comma at clause-head depth is unambiguous.** Clause-head binders are
atom patterns, and every atom pattern that can contain a comma is bracketed —
`parse_atompat` consumes the brackets whole. So a `WT_COMMA` visible to
`parse_clause` after the binder run is at head depth by construction. No
lookahead, no depth counter, no backtracking.

### C. Hanging body blocks — a delta NOT on the boot list

Found by probe, not by reading. Both of these are rejected today with
`E-LAY-INDENT`:

```
add x, k -> let t = t + x        -- reject/13, verbatim
            t := 9
            k ()

False -> budget := budget - 1    -- spec-min §6 `race`, verbatim
         k (lookup q)
```

The layout filter is right: it emits `NEWLINE INDENT` before the continuation
line, exactly as it does for any deeper line. The parser is what refuses —
`parse_body` only takes the block arm when the block opens IMMEDIATELY after
the `->`, so a body whose first statement shares the arrow's line and whose
rest is indented under it has nowhere to go.

This shape is normative: spec.md 1.1 says the column-aware arm-body rules
carry over unchanged, spec-min §6 writes it in a canonical example, and
reject/13 must PARSE cleanly (its fault is E-VARSCOPE, not a layout fault).
So `parse_body` gains one arm: after an inline first statement, if the next
tokens are `NEWLINE INDENT`, keep reading items into the same block.

The README's claim "zero hanging indents over the corpus" was true of the
21-file corpus and is false of the 26-file one. It is corrected there.

Limit, stated rather than fixed: the filter opens the continuation block at
the CONTINUATION's column, which need not agree with the column of the first
statement on the arrow line. Aligning them is a style rule the formatter
already enforces by printing the canonical block form; making disagreement an
error would need the parser to compare columns, which is the feedback edge
the three-stage split exists to avoid.

### D. Printer

- **D1** `p_arrow_head`: `once ` disappears; CONTROL prints `op pats, k`;
  ABORT prints `abort op pats`. Arrow alignment is unchanged — every clause
  kind but `var` is arrow-headed, and `head_cols` measures `p_arrow_head`, so
  the `, ` simply becomes part of the measured head.
- **D2** The `c.rest += 1 + k.len` reservation in the ONCE arm becomes
  `2 + k.len` (`, ` is two columns), so a wide binder run still wraps at the
  right place.

### E. Resolution-time checks (spec-min §4, second block)

These need the effect declarations and nothing else — no types, no
inference. They are a new stage, `wok_resolve.c`, run after a CLEAN parse
(running it over a damaged tree would report faults the author never wrote):

- **E1** an effect table: effect name → ops → arity, arity being the arrow
  count of the op's declared type at the top level.
- **E2** `handler E` where `E` is not a declared effect → error at `E`.
- **E3** a clause naming an op the effect does not declare → error at the op
  token.
- **E4** argument-pattern count ≠ op arity, for plain, control AND abort →
  E-ARITY. This is what reject/02 and reject/12 are pinned on.
- **E5** clauses for one op must agree on plain vs {control, abort}.
- **E6** E-RESERVED: an effect declaring an op named `once`, `abort`,
  `return` or `var`. `abort`/`return`/`var` are keywords, so they arrive as a
  parse fault unless caught here by name; `once` is contextual and would
  otherwise be accepted silently.

Coverage (E-COVER) is explicitly NOT here: it needs the argument TYPE's
constructor set, which is a type-checker fact.

### F. Scope checks (D26, D27)

Also resolution-time, also type-free, but a separate walk with an environment,
so a separate slice:

- **F1** a value binding (no parameters) whose RHS references its own binder
  → error with the eta hint. Function equations (with parameters) stay
  recursive and keep grouping.
- **F2** `:=` write-locality, D27's three voices: no handler frame in lexical
  scope; the target resolves to a value rather than a `var` (naming the
  shadow site when a later `let` shadowed the baton); the write's nearest
  enclosing function-forming construct is not the declaring handler's clause
  body. Boundaries: lambdas, local function equations, handler literals. NOT
  boundaries: blocks, `case` arms, `if` branches.
- **F3** clause-body name resolution is args → batons → enclosing scope. This
  is not a diagnostic; it is the environment order F2's second voice reads.

Pinned by reject/07 and reject/13, whose EXPECT lines carry the positions the
messages must quote.

### G. Not in scope, vocabulary reserved

E-ABORT, E-SHADOW, E-AFFINE, E-ESCAPE are later analyses. They stay out of
the code and stay in the diagnostic roster's comments, so the codes cannot be
re-minted with different spellings later.

## 1a. What shipped (2026-08-06)

| slice | commit | state |
|---|---|---|
| V1 the surface | `dac0bc5` | done — comma classification, `abort`, `once` migration, hanging bodies |
| V2 the effect table | `308a72e`, `e697649` | done — arities, kind agreement, E-RESERVED, effect redeclaration |
| V3 scopes | `3af8616` | `:=` write-locality done; D26 self-reference HELD on a code name |

All 12 accept and all 14 reject files parse clean. The four rejects whose
faults the front end can see now report them — reject/02 and reject/12
`E-ARITY`, reject/07 and reject/13 `E-VARSCOPE` — and the other ten stay
silent. 19 suites green; `make sanitize` clean over 47 corpus files.

Two things landed beyond this spec, both recorded in their own commits: the
hanging-body parser arm (delta C above) and the fixity front end, which has
its own spec at `2026-08-06-fixity-front-end.md`.

## 2. Three gaps in the diagnostic registry — decisions needed

spec.md §3's registry has no code for three checks spec-min §4 requires. I am
not picking silently; the recommendation is stated and the implementation is
parked behind it.

| check | registry says | recommended |
|---|---|---|
| `once` at clause head (D25 migration) | message text only: "v1 clause keyword; drop it" | **E-MIGRATE**, a new code — it is not a violation of anything, it is a port aid, and giving it its own code keeps `--explain` honest and lets a porting script grep for it |
| `handler E`, E undeclared | E-LABEL covers "a capitalized name naming no declared effect = unknown slot" — but that is about a LABEL position, and `handler E` is not one | **E-LABEL**, on the strength of that sentence; the alternative is a second code for the same reader-facing mistake |
| clause op not declared by E; value binding self-reference (D26) | nothing | **E-UNDEFINED**, one code for "this name has no declaration that reaches here", with the D26 eta hint as its hint text |

Two more were minted the same way while V2, V3 and the fixity work landed —
each shipped because the check cannot report without a code, each one rename
away:

| code | raised for |
|---|---|
| **E-DUPLICATE** | an effect declared twice; an operator given two `fixity` lines |
| **E-FIXITY** | the declared order is not an order (a cycle, or an operator tighter than itself), and a chain whose operators have no order between them |

So five spellings in total are waiting on the registry: E-MIGRATE,
E-DUPLICATE and E-FIXITY are in the code and renameable; E-LABEL and
E-UNDEFINED are parked with nothing written behind them. The two parked ones
gate exactly three checks: `handler E` naming no declared effect, a clause
naming an op its effect does not declare, and D26's value self-reference.

## 3. Slicing

**V1 — the surface.** A, B, C, D, and the corpus/testdata migration (§4).
Done when: all 12 accept and all 14 reject files parse with zero
diagnostics; the two new parse-bad fixtures produce exactly one diagnostic
each; formatter round-trip and shape hold; all 17 suites green.

**V2 — the effect table.** E. Done when reject/02 and reject/12 report
E-ARITY with the counts their EXPECT lines quote, and the other twelve reject
files report nothing.

**V3 — scopes.** F. Done when reject/07 and reject/13 report E-VARSCOPE in
the voices their EXPECT lines quote, accept/11's rebind chain stays clean,
and the other twelve reject files still report nothing.

The "reports nothing on the other twelve" clause is the load-bearing half of
V2 and V3: a resolution pass that fires on a file whose fault belongs to a
later analysis is worse than one that stays silent, because the later
analysis is the one that knows the right message.

## 4. Corpus and fixture migration

- `testdata/tour/05-handlers.wok` — the two `once req … k` arms become
  `req …, k`; `once emit x k` becomes `emit x, k`; an `abort` arm is added so
  the tour covers all FIVE clause kinds, which is what makes it a tour.
- `testdata/parse-bad/03-once-binder-not-a-name.wok` is replaced by two
  fixtures: `03-once-clause-keyword.wok` (E-MIGRATE) and
  `11-comma-binds-a-pattern.wok` (E-ARITY, the comma followed by a pattern).
  Both must keep the parse-bad contract: exactly one diagnostic, and the
  declaration after the damaged one still parses clean.
- `test_generative.c` — `SL_ClauseOnce` becomes `SL_ClauseControl`, gains
  `SL_ClauseAbort`; invariant 16's text follows the grammar.
- `test_fuzz_parse.c` seed words — `"once "` out, `"abort "` in.

## 5. What this spec deliberately does not do

- No local repair (tier 1) for the new forms. `once req x k ->` recovers by
  reporting and parsing on as an op clause, which is the same recovery the
  rest of the parser uses and needs no budget.
- No `fixity`, no comment attachment, no change to the layout filter. Delta C
  is a PARSER change; the filter's output for those files is already right,
  which is the three-stage split doing its job.
