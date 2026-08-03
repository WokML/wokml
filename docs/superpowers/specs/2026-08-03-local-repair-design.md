---
spec: error-batching
status: awaiting review
supersedes: the tier-1 local-repair design previously in this file, REJECTED by
  the owner (section 1)
depends: 2026-08-03-c23-frontend-design.md (section 6.2)
---

# Error batching: report every fault, at the right place, and never stop

## 1. Local repair is rejected, and the reason generalises

The previous version of this file designed tier-1 local repair: at a fault,
apply a bounded single-token edit -- insert, delete or substitute -- and carry
on with the item intact.

**Rejected by the owner: a repair can rewrite the author's meaning.** The
earlier draft already refused to invent a NAME on those grounds; the same
argument applies to structure. `:=` "obviously" meant `=` until it did not, and
a tool whose entire value is that it does not guess should not have a mode
where it guesses and continues.

Recorded because it is a decision, not an omission -- CPCT+ is a well-known
technique and someone will propose it again. What replaces it is not weaker
error handling but better error REPORTING: skip the damaged region, keep
going, and be precise about what and where.

## 2. Measured: it already does not stop at the first fault

A file with three independent errors, in three different declarations:

```
 4  alpha x := 1        <- fault
10  gamma y ?? 3        <- fault
17    B ~~ 2            <- fault, inside a case block
```

reports three faults in one run. The block-item loop already reports,
resynchronises and continues, so "do not block on the first error" is TRUE
today. This section exists so nobody rebuilds it.

## 3. The real defect: two of those three point at the wrong line

```
   4:9   expected `=` after the left-hand side, found `:=`        <- right
  12:1   expected `=` after the left-hand side, found end of line <- fault is on line 10
  18:3   expected `->` after the pattern ..., found end of line   <- fault is on line 17
```

The cause is in `wok_layout.c`. A layout token is synthesised from the token it
PRECEDES:

```c
static void put(Filter *f, WokKind k, const WokToken *at) {
  f->out[f->n++] = (WokToken){.off = at->off, .col = at->col, ...};
}
```

so a `NEWLINE` carries the offset and column of the FIRST TOKEN OF THE NEXT
LINE. Every diagnostic that says "found end of line" is therefore blamed on the
line after the one that is broken -- and it is worse than an off-by-one,
because the next line is usually a perfectly good declaration, so the reader is
sent to correct something that is not wrong.

This matters more, not less, in a batch: a developer scanning twenty faults, or
an agent applying them mechanically, has no way to notice the position is a
lie.

### The fix

**Blame the end of the last REAL token, not the layout token.** When a
diagnostic's token is `NEWLINE`, `INDENT` or `DEDENT`, report at
`prev->off + prev->len` -- the end of the last thing the author actually wrote.
That is where a missing `=` or `->` belongs: at the end of the line that needed
it.

Localised to the diagnostic path (`perr_at` / `perr_expect`), not to the
filter. The filter's choice is right for ITS purposes -- a layout token's
column is what the parser's block logic compares -- so changing `put()` would
fix the message and break the block rule.

## 4. Recovery granularity: confirm, then pin

The owner's model is "skip to the next block -- another indentation scope, or
paragraph of code -- and continue". That is what `resync_to_boundary` intends:
skip to the next `NEWLINE` at the block's level, or its `DEDENT`, whichever
comes first, tracking bracket depth so it cannot stop inside brackets.

Two things about it are asserted nowhere:

1. **A fault in a nested block must not discard its parent.** An error in one
   `case` alternative should cost that alternative, not the enclosing
   equation, and not the declarations after it.
2. **Declaration blocks resynchronise only at an ANCHOR** -- a declaration
   keyword, or `name :` at the block column. This is deliberate (D23 makes a
   signature the strongest anchor available) and it has a KNOWN COST: a damaged
   signature swallows the equation beneath it, because that equation is not an
   anchor. Whether that trade is right is section 7's question; either way it
   should be pinned by a test rather than discovered.

## 5. Properties

| property | fails when |
|---|---|
| **N independent faults in N declarations produce N diagnostics** | recovery is swallowing more than the damaged item |
| **every diagnostic's line is the line the author must edit** | the layout-token blame bug, or a future one like it |
| a fault in a nested block leaves the enclosing item's siblings parsed | recovery escaped its scope |
| declarations AFTER a damaged one still parse | the batch stops early in practice while claiming not to |
| one damaged item yields exactly ONE diagnostic | cascade suppression regressed |
| the corpus produces zero diagnostics | any of the above fires on valid input |

The second is the one this slice exists for, and it is checkable exactly:
every fixture states the line it must be blamed on, and the test compares.

## 6. Slices

| # | Slice | Gate | Tier |
|---|---|---|---|
| E1 | blame the end of the last real token for layout-token faults | the three-fault fixture reports 4, 10, 17 | standard |
| E2 | fixtures for multi-fault files: independent decls, nested block, damaged signature | N faults, N right lines, later decls survive | mechanical |
| E3 | assert one diagnostic per damaged item over the fixtures | no cascades | mechanical |

E1 is small and self-contained. E2 is where the value is: the current
`testdata/parse-bad/` fixtures each contain ONE fault, so nothing today
exercises the batch at all.

## 7. Open questions

1. **Does a damaged signature deserve to swallow its equation?** The anchor
   rule says a signature is the strongest resynchronisation point, so recovery
   runs to the next one and takes the equation with it. The alternative is to
   treat a bare `name = ...` at the block column as a weak anchor too, which
   recovers more but risks resuming inside a damaged construct. Measure on the
   fixtures before choosing.
2. **Should a fault report the enclosing construct?** "expected `->` after the
   pattern of this alternative" names the construct but not which alternative,
   nor which `case`. Adding "in the `case` at 15:15" is cheap and is the kind of
   context an agent cannot recover from the position alone.
3. **Is the 20-fault cap right for a batch tool?** It was chosen when the first
   fault was the interesting one. If the point is a whole work list, a file
   with 40 genuine faults now silently reports half of them.
