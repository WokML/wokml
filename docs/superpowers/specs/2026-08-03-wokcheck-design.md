---
spec: wokfmt
status: awaiting review
supersedes: the daemon-and-cache design previously in this file, killed by measurement (section 1)
depends: 2026-08-03-c23-frontend-design.md
---

# `wok fmt` — a one-shot formatter and linter that defines the surface standard

The primary value of the C front end is not speed of compilation. It is that
**one program has one text**, mechanically enforced. The formatter is the
standard; the linter is the formatter asking whether a file already agrees with
it.

## 1. Measurement first: there is no daemon and no cache

The previous version of this spec designed a file watcher, a content-addressed
object store, Merkle cache keys, and an interface-hash cutoff so that editing a
body would not retypecheck importers. All of it was deleted after measuring the
thing it was meant to avoid.

`-O2`, warm page cache, `fork`+`exec`+dyld included, 400 runs each:

| | per invocation | attributable to the tool |
|---|---|---|
| empty C binary (`int main(){return 0;}`) | 1.463 ms | — macOS process creation |
| `wokparse`, no args, does no work | 1.468 ms | **+0.005 ms** |
| `wokparse`, 1 file (76 lines) | 1.528 ms | +0.065 ms |
| `wokparse`, 750 files (25,890 lines) | 11.677 ms | +10.2 ms, ~13.6 us/file |

Steady-state, in memory, excluding process creation and I/O: **143.9 MB/s,
6.6 us/file, 5.2M lines/s**.

Conclusions that decide the architecture:

- **The tool's own startup is unmeasurable** — 5 microseconds above an empty
  binary. There are no static initializers and no tables built at runtime; the
  character-class bitmaps and rosters are `constexpr` and live in `.rodata`.
- **A whole 750-file project checks in 11.7 ms.** A project ten times larger
  would be roughly 100 ms.
- **For a single file, ~95% of the wall time is the operating system creating a
  process.** No cache can remove that, and no cache is needed: the work being
  cached costs 65 microseconds.

So: a one-shot process, invoked per save or per commit. No watcher, no `.wok/`
cache directory, no invalidation, no daemon lifecycle, no staleness bugs. The
simplest thing is also the fastest thing available.

The Merkle hash was kept briefly as a safety interlock and then deleted too;
section 3 records what replaced it.

## 2. What the tool is

```
wok fmt FILE...            rewrite each file in canonical form
wok fmt --check FILE...    the LINTER: exit non-zero if any file is not canonical
wok fmt --stdout FILE      print the canonical form, leave the file alone
wok fmt --diff FILE...     show what would change
```

`--check` is the whole of the linter. "This file differs from its own
formatting" is a complete, mechanical, arguable-with-nobody standard, and it
subsumes every rule about indentation, spacing, bracket style and block layout
that a project would otherwise litigate in review.

With ONE deliberate exception, in section 4a: the formatter aligns arrows, and
the checker does not care whether you did.

Exit codes: 0 clean, 1 a file is not canonical (or, in `fmt` mode, a file could
not be formatted), 2 the tool failed.

## 3. Two interlocks, for two different failures

A formatter rewrites source in place. Two distinct things can go wrong, and
they need different checks. Conflating them was the first design's mistake.

**A — did formatting change the PROGRAM?** Compare the TREES:

```
dump(parse(original))  ==  dump(parse(formatted))
```

The dump is already the canonical, position-free identity of a program and is
round-trip tested, so this needs no separate hash function. A structural Merkle
hash was built for this and then DELETED: it was only ever a fingerprint of the
dump, and the dump costs 7.7 us per file in a path that is about to do file
I/O — while giving a diff on failure instead of "two numbers differ".

Note that a hash of the FILE BYTES cannot answer A. Formatting deliberately
changes the bytes; that is its job.

**B — did the file change on disk while we worked?** Compare the BYTES:

```
byte_hash(at read)  ==  byte_hash(re-read immediately before write)
```

Someone saving in their editor mid-run must never be clobbered by a rewrite of
the version we read. Their edit wins and the file is not written.

Either check failing means the file is NOT written and the tool reports it.
Together they convert "the formatter ate my code" from a class of silent
corruption into a refusal. `--check` never writes, so it pays for neither.

Under an offside rule interlock A is not paranoia. A misplaced line break is
NOT a syntax error: it turns an expression into a block, or ends one early. The
output still parses. Only the tree shows the damage, and comparing text would
pass.

## 4. Canonical form

The decisions, and the principle behind each. Where two spellings of one tree
exist, the formatter picks one — the same refusal of redundancy that D20 makes
for row entries.

| Decision | |
|---|---|
| indent | 2 spaces per level, never tabs (the filter rejects tabs in indentation anyway) |
| blocks | ALWAYS the indented form, one item per line; never the inline single-item form |
| line filling | NONE in this slice. A statement is one line however long, unless the tree says it is a block |
| parentheses | re-derived from precedence; emitted only where the tree would otherwise re-parse differently |
| backticks | re-derived from the operator's spelling: alphabetic implies `` `add` ``, symbolic implies bare |
| `(+) x y` | the same fact, the other way round |
| spacing | one space around every infix operator, `=`, `->`, `=>`, `:`, `:=`, `\|`; one after `,`, none before; one inside record braces; none inside `()` or `[]` |
| blank lines | exactly one between top-level declarations; at most one between block items, and only where the author had one; none leading, one trailing newline at EOF |
| `where` | its own line at the parent item's indentation, bindings indented one level under |

## 4a. Arrow alignment: the formatter produces it, the checker ignores it

Within one block, **all arrow-headed items pad their heads to the widest head,
so the arrows line up**:

```
state init = handler State
  var cur = init
  get      -> cur
  set x    -> cur := x
  return v -> (v, cur)
```

Applies to handler clause blocks and case-alternative blocks. A `var` clause is
headed by `=`, not `->`, so it is not a member of the group. Items whose bodies
are indented blocks still participate, contributing their head width — this is
one rule with no run-detection and no special cases, which is what a standard
wants. Guard: if the widest head exceeds 32 columns, alignment is skipped for
that block and every item gets a single space, so one long pattern cannot push
a whole block off the screen.

**The checker must not enforce it.** Alignment is NON-LOCAL: renaming one op
reflows the padding of every sibling, so enforcing it would turn a one-token
rename into a multi-line diff and a CI failure over something semantically
irrelevant. The readability is worth having; the churn is not.

That makes `--check` something other than text equality. It compares the SHAPE
of the two texts:

```
shape(text) := for each line: (leading indent width,
                               token texts with inter-token gaps clamped to min(gap, 1))
```

`f` is canonical iff `shape(f) == shape(Format(f))`.

Computed over TOKENS AND COMMENTS, never raw bytes, for two reasons. A string
literal containing two spaces can never be mistaken for padding. And a comment
is an ITEM in the shape, not whitespace -- otherwise `--check` would call a
file canonical after the formatter had deleted every comment in it, which was
a real defect in the first implementation and was caught by writing the unit
test rather than by using the tool. Clamping to `min(gap, 1)`
rather than collapsing all whitespace is what keeps the rest of the standard
enforced: `a+b` (gap 0) still differs from `a + b` (gap 1), so operator spacing
is checked, while `get      ->` and `get ->` are the same shape, so alignment is
not. Indentation width is compared exactly, so a three-space indent is still a
violation.

Rejected alternative: accept a file if it equals EITHER the aligned or the
unaligned rendering. It fails on the corpus — `accept/03` aligns `walk`'s
alternatives and leaves `tick`'s unaligned, so it matches neither rendering
whole-file, and a mixed file is exactly the case this exception exists to
tolerate.

**Line filling is deliberately out of scope** for this slice. It can be added
later without changing the tree contract, and leaving it out makes the
fixed-point property much easier to guarantee. When it does arrive, the layout
rules already accommodate it: a break before an operator is legal because
operators are continuation leads (L4), so a long chain wraps as

```
total = alpha
      + beta
      + gamma
```

with no brackets and no INDENT emitted at all.

## 5. Trivia: comments are not optional for this tool

**This is the blocking slice.** The scanner already collects comments into a
side list (`WokComment{off, len, block}`), but they are not in the tree, so a
formatter would silently delete every comment in the file. As a round-trip test
oracle that is tolerable; as the tool that defines the surface standard it is
disqualifying.

### Where they live

`WokNode` currently has four bytes of padding between `nslots` and the slot
array (header is `hash` 8, `off` 4, `len` 4, `tag` 2, `nslots` 2, padded to 24
for slot alignment). A `uint32_t trivia` index costs **nothing**: 0 means none,
otherwise it indexes a side array of `{lead_first, lead_n, trail_first,
trail_n, blank_before}`.

### Attachment rules

Item granularity — the same granularity as error recovery, which is not a
coincidence: it is the unit a reader thinks in.

1. **Own-line comment** (first non-whitespace on its line) becomes LEADING
   trivia of the next block item that begins after it — declaration, statement,
   clause or alternative.
2. **Trailing comment** (something precedes it on the line) becomes TRAILING
   trivia of the item on that line.
3. **A comment with no following item** — end of a block or end of file —
   becomes trailing trivia of the enclosing block node.
4. **Blank lines** are recorded as a capped count (0 or 1) on the following
   item, so an author's paragraph breaks survive. Everything above one is
   collapsed.

### Comments are NOT in the dump, and NOT in the hash

Two files differing only in comments are the SAME PROGRAM. The dump is the
canonical identity of a program and the hash is taken over it, so putting
comments in either would make the safety interlock assert something false —
that reformatting must preserve the text of comments *as part of meaning*.

Comment preservation is therefore its own property, checked separately:

```
comments(Format(t))  ==  comments(t)     -- same texts, same order
```

That is the second half of the interlock in section 3.

## 6. Properties

Over every corpus file, plus every file in the tour:

| Property | Fails when |
|---|---|
| `Dump(Parse(Format(t))) == Dump(t)` | printing changed the program. THE load-bearing one |
| `Format(Parse(Format(t))) == Format(t)` | the formatter is not a fixed point, so `--check` would flag a file it just wrote |
| `comments(Format(t)) == comments(t)` | a comment was dropped, reordered or reflowed |
| `shape(f) == shape(Format(f))` iff `f` is canonical | the linter's normal form drifted from the formatter |
| `Format(t)` parses with zero diagnostics | the formatter emits something the parser rejects |
| `Format(t)` satisfies the layout invariants | the formatter emits layout the filter would repair |
| `--check` accepts BOTH the aligned and the unaligned rendering of one tree | the alignment exception (4a) regressed into an enforced rule |
| `--check` still rejects a 3-space indent and `a+b` | the shape comparison was loosened too far and stopped enforcing the rest |

The second is what makes `--check` trustworthy. The first is what makes `fmt`
safe. Both are necessary; neither implies the other.

## 7. Slices

| # | Slice | Gate | Tier |
|---|---|---|---|
| P1 | `wok_print.c`, canonical form per section 4 | properties 1, 2, 3, 5, 6 over the corpus | standard |
| P2 | **trivia**: attachment pass, `uint32_t trivia` on the node, printer emits | property 4; a commented corpus file survives a format round trip | standard |
| P3 | `wok fmt` CLI: `--check`, `--stdout`, `--diff`, in-place write with the interlock | a deliberately corrupted printer is CAUGHT by the interlock rather than writing | standard |
| P4 | comment corpus: files whose comments sit in every position rule 1-4 names | 100% of the attachment rules exercised | mechanical |

P2 is the one that decides whether this ships to humans.

## 8. Open questions

1. **Doc comments.** Should `---` or `{-| -}` be distinguished as attached
   documentation, with stricter placement rules? Cheap now, awkward later.
2. **Alignment.** The corpus aligns handler clause arrows (`get      -> cur`).
   That is a second spelling of one tree, so canonical form as specified
   destroys it. Accept, or add an alignment rule for clause blocks?
3. **`--diff` output format.** Unified diff, or the tool's own format naming the
   rule violated? The latter teaches the standard; the former pipes into
   existing tools.
