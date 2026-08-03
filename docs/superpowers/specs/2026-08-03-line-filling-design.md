---
spec: line-filling
status: awaiting review
depends: 2026-08-03-wokcheck-design.md (section 4 defers this explicitly)
---

# Line filling in the canonical printer

Today a statement prints on one line however long. The first user with a long
capability row gets a line that runs off the screen and stays there.

## 1. The constraint that decides the whole design

In a brace language you may break a line anywhere and re-indent freely. **Under
an offside rule a line break changes the parse.** Given the layout rules
(`wok_layout.h`), a break followed by:

| the next line begins with | what the filter does | result |
|---|---|---|
| an ITEM lead, deeper column | `NEWLINE INDENT` | `E-LAY-INDENT` — the printer emitted something the parser rejects |
| an ITEM lead, same column | `NEWLINE` | **a new item — the tree silently changed** |
| a CONTINUATION lead | `DEDENT`s only, no separator | safe: the logical line continues |
| anything, inside brackets | nothing | safe: layout is suspended (L2) |

So the printer has exactly **two** ways to break a line, and they are the only
two it may ever use:

1. **before a continuation lead** — an operator, `+`, `|`, `->`, `::`, or one
   of `where` / `in` / `then` / `else`;
2. **anywhere inside a bracket group**.

That is a gift, not a limitation: the legal break points are a small,
enumerable set, which makes the feature checkable rather than merely careful.

### The corollary that has to be said out loud

**Application juxtaposition cannot be broken.** `foo aaa bbb ccc` has no
operator between its arguments, so any break leaves the next line starting with
an item lead, which is either an error or a tree change. A long application
stays long.

The escape hatch — wrapping it in parentheses, which the tree does not record
and the parser drops — is deliberately NOT taken: adding punctuation the author
did not write, to solve a width problem, is a worse trade than one long line.
Recorded here so nobody re-derives it as a clever idea later.

### The second corollary: continuation lines must be indented

A continuation lead at a column shallower than the enclosing block emits DEDENTs
(L4) and therefore **closes the block** before continuing the item. That is
exactly how the hanging `in` works, and it is wrong for a wrapped chain. So a
wrapped line must be strictly deeper than the enclosing block column, even
though the filter itself does not demand it.

## 2. Width: 80

Measured over the v2 corpus plus the tour, comments excluded:

```
p50 = 18   p90 = 33   p95 = 39   p99 = 44   max = 78
lines over 80 columns: 0
```

80 costs nothing today and is the convention every reviewer already has. The
three longest lines are all capability rows, e.g.

```
walk : [Cmd] -> U64 with Reader U64 + Writer [U64] + State U64 + Except String
```

which is exactly the construct the `+` separator makes safe to break.

**Not configurable.** A formatter that defines a standard has one width, for
the same reason it has one indent. A `--width` flag turns "this file is
canonical" into "canonical under whose settings?", and the linter's whole value
is that the question has one answer.

## 3. The algorithm

The printer already measures: `Pr` carries `count_only` and `quiet`, so a
subtree's flat width can be computed without emitting. Line filling is
therefore measure-then-emit, not a rewrite.

For each construct that owns break opportunities:

1. measure its flat width;
2. if it fits in the columns remaining, emit flat;
3. otherwise break at **every** opportunity in that group, and recurse into
   the children.

**All-or-nothing per group** (the Wadler/prettier rule). Breaking some
separators of one chain and not others produces output that is harder to read
than either extreme, and it makes the fixed-point argument harder to state.

```
tick : Cmd -> U64 with Reader U64 + Writer [U64] + State U64 + Except String
```
becomes

```
tick : Cmd -> U64
       with Reader U64
          + Writer [U64]
          + State U64
          + Except String
```

### Break opportunities in scope

| construct | break before | node |
|---|---|---|
| infix chain | each operator | `E_Chain` / `H_ChainOp` |
| capability row | each `+` | `T_With` row entries |
| function type | each `->` | `T_Fun` spine |
| type alternatives | each `|` | `D_Type` condefs |
| list / tuple / record | BEFORE each `,` (leading separator) | bracketed, so free (L2) |

Out of scope: application juxtaposition (unbreakable, above), and `where` /
`in` / `then` / `else`, which the printer already places by `opens_block()`.

### Continuation indent

Per decision 1 (section 7):

- a wrapped **capability row** ALIGNS under its `with`, and its `+` entries
  align under each other;
- every other wrapped construct takes a fixed **item indent + 2**.

Alignment is non-local, but `with` is a fixed anchor that does not move when a
row entry is renamed, so the reflow is bounded. Section 7a records what that
costs `--check` and how it is resolved.

## 4. Why the fixed point survives

`Format` is a pure function of the tree and the width. If property 1 holds
(`Dump(Parse(Format(t))) == Dump(t)`), then `Format(Parse(Format(t)))` is
`Format` applied to the same tree, hence equal to `Format(t)`. The fixed point
is a corollary, not a separate risk — PROVIDED break decisions depend only on
the tree, never on the text being produced. Any lookahead at already-emitted
output would break that and must not be introduced.

## 5. Properties

All six existing printer properties must continue to hold. Two are added:

| property | fails when |
|---|---|
| **no emitted line exceeds 80 columns, except one containing an unbreakable run** | the filler gave up silently |
| **every unbreakable overflow is REPORTED**, with file, line and the construct | a long line looks like a formatter bug rather than a stated limitation |
| **no emitted line begins with an item lead at a column deeper than its block** | a break changed the tree — the specific hazard of this feature |

The third is the safety property. It is checkable directly on the output token
stream: for every line, if its first token is not a continuation lead, its
column must equal an open block column. It should be asserted on every file the
printer emits, in every build, not only in tests.

## 6. Slices

| # | Slice | Gate | Tier |
|---|---|---|---|
| L1 | width plumbing + flat measurement of a group | measurement agrees with the emitted width on every corpus file | mechanical |
| L2 | break infix chains and capability rows | the three long corpus lines wrap; all 6 properties hold | standard |
| L3 | break `->` spines and `\|` alternatives | `testdata/fill/` cases wrap | standard |
| L4 | the safety property, asserted on every emit | a deliberately corrupted break is caught | **frontier** |
| L5 | overflow reporting for unbreakable runs | a long application reports rather than silently overflowing | mechanical |

L4 is frontier because it is the check that makes the rest safe to trust, and
because a wrong assertion here would either mask the hazard or reject valid
output.

`testdata/fill/` must contain, for each breakable construct, one case just
under the width and one just over — the boundary is where an off-by-one in the
measurement shows up.

## 7. Decisions (owner, 2026-08-03)

1. **A wrapped capability row ALIGNS under its `with`.** Non-local, but `with`
   is a fixed anchor that does not move when an entry is renamed, so the churn
   is bounded in a way arrow alignment's is not.
2. **`--check` ENFORCES width.** Width is local and deterministic, unlike
   alignment, so one program keeps one text.
3. **Nested groups break INDEPENDENTLY.** Breaking an outer chain does not
   force a list inside it to break.

### 7a. Derived, and the one place this bites

Arrow alignment is INTERIOR whitespace, which `wok_shape` clamps to one space,
so the formatter produces it and `--check` ignores it. A wrapped line's indent
is LEADING whitespace, which `shape` compares EXACTLY. Under decision 1 that
makes a rename shift the `with` column, reflow every continuation line, and
fail `--check` until reformatted -- precisely the churn decision (4a) exempted
arrows to avoid.

Resolution, by the same principle: **`wok_shape` clamps the indentation of a
line whose first token is a CONTINUATION LEAD, and compares it exactly
otherwise.** Where the breaks fall is still enforced (decision 2 holds, since
that is line structure, not indentation); only the non-local alignment is
exempt. Item-line indentation -- the three-space-indent case -- is untouched.

This is one condition in `wok_shape`. Removing it enforces wrapped indentation
too, if the churn turns out to be tolerable in practice.

## 8. Amendments from implementation (2026-08-03)

Three changes made while building it, each one a case the spec as written got
wrong or left open.

**8.1 Leading separators, not trailing.** The table above originally said
"after each `,`". That contradicts the safety property: a trailing comma leaves
the next line starting with an ITEM lead, which forces bracket-depth tracking
into both the safety checker and `wok_shape`, and whose non-local column would
fail `--check` on a rename. With the separator LEADING its line

```
xs = [ aaaaaaaaaa
     , bbbbbbbbbb
     ]
```

**every wrapped line the filler emits begins with a continuation lead** --
verified over `testdata/fill`: only `->`, `,`, `)`, `]`, `}`, `+`, `|`, `with`
ever appear. That makes the safety property checkable with no bracket tracking,
gives 7a's clamp list wrapping for free, and means L7 bracket abandonment can
never fire on a wrapped element.

**8.2 A group must measure what FOLLOWS it, not just itself.** "if it fits in
the columns remaining" left open: remaining before what? A wide record pattern
fits, and then a trailing ` -> a` pushes the line to 81. A reserve is threaded
through the UNBREAKABLE constructs only (juxtaposition, `.`, `::`, `as`, `=>`,
arrow heads, `let...in`, `if...else`); a group's children get a reserve of
zero, which is exact rather than merely safe -- if the group fit, everything
inside it fit.

**8.3 Row alignment needs the guard arrow alignment already has.** Decision 1
aligns a wrapped row under its `with`, but a long function name pushes that
column right and carries the row off-screen. A row falls back to the fixed
item indent when alignment would not leave the widest entry room -- the same
rule as the 32-column arrow guard in the wokfmt spec.

### Breaks that looked legal and change the tree

Recorded because each is the obvious thing to write:

- **after an operator** (`a +` / newline / `b`) -- symmetrical with the legal
  form, but the new line starts with an item lead: `E-LAY-INDENT` at a deeper
  column, a silent new block item at the same one;
- **before the first alternative of a `type`** -- the natural counterpart to a
  leading `|`, and a tree change. The first condef must stay on the `=` line;
- **a nested `T_Fun` deciding for itself** -- not a tree change, but the arrow
  spine must be walked as ONE group, or the inner node measures itself against
  the width the outer break just freed and stays flat, violating
  all-or-nothing.
