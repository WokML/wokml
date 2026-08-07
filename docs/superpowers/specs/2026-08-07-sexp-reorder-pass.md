# Sexp reorder pass: precedence-resolved chains in the dump

2026-08-07. Branch: feat/sexp-ingestion-oracle (continues the sexp ingestion
work; see 2026-08-06-sexp-ingestion-oracle.md).

## Goal

`wokparse` gains a reorder pass so the dumped sexp carries
precedence-RESOLVED operator chains instead of flat ones. The future C
typechecker then consumes a sexp in which grouping is already decided, and
never touches the fixity table. The contract that the pass is correct:
Haskell's existing `Wok.Reordering` produces the SAME tree from the flat
dump. Haskell's reordered result is the reference by decision, not by
adjudication -- the redesign spec (docs/redesign/spec.md) does not cover
fixity, and the user accepted the check-mode divergences as-is.

## Non-goals

- Cross-module fixity tables -- in THIS slice. The intended endgame IS a
  globally merged table (the user's requirement): when the C typechecker
  epic grows a loader over sexp files, it overlays the imports' tables the
  way Haskell's `Pipeline` does and hands the merge to this same pass. To
  keep that a drop-in, the pass MUST take the fixity table as an explicit
  parameter (mirroring `reorderModuleWith externalTable`) rather than
  reaching into resolve's state. Slice 1 constructs that parameter from
  the file alone, because `wokparse` is a one-file tool and there is
  nothing to merge from yet; the external-table future is F5 (already
  named in the `check_chain` comment). The Haskell side of the
  differential therefore uses `reorderModule` (the file-own path), NOT
  the loader's `overlayFixities` merge -- both sides must always be fed
  the same table, whatever it contains. Note the tables differ only in
  ERROR sets, not algorithm: an imported operator with no in-file
  `fixity` errors under the file-own table and reorders under a merged
  one.
- Changing `wokfmt` or the plain `-sexp` dump. The formatter needs
  source-faithful flat chains; reordering before printing would rewrite the
  author's brackets (2026-08-06-fixity-front-end.md already rules this out).
- Touching check mode. `-check-only` keeps its graces (unknown operators
  skipped, unknown occurrences count as shields). Reorder mode is stricter;
  the two modes answering differently on partially-declared files is
  accepted, not a bug.

## Surface

    wokparse -sexp -reorder FILE

`-reorder` is a modifier: it is an error to pass it without `-sexp`. The
pipeline becomes parse -> resolve -> reorder -> dump. Resolve already builds
the fixity table (bitset + Warshall closure) and runs its checks; the
reorder pass runs after it, on the same table. Any reorder diagnostic
suppresses the dump and exits non-zero, same as a parse fault does today.

## The pass

A transliteration of Haskell's `reorderChain`/`findLoosest`
(src/Wok/Reordering.hs), so that agreement is by construction and the
differential guards it. Walk every expression bottom-up; at each `E_Chain`
with ops:

1. The table must be PLACEHOLDER-FREE before any chain is consulted: a
   whole-table scan at pass entry diagnoses every entry that exists only
   as somebody's neighbour (`decl_off == UINT32_MAX`), mirroring
   Haskell's `checkNeighbors`, which rejects the module even when the
   name never occurs in a chain -- even when the file has no chains at
   all. Then, per occurrence: an operator with no table entry at all is
   a diagnostic; reorder cannot skip what check mode may. Together these
   make the two known check-mode/Haskell divergences unreachable:
   neighbour-only names error out (as `UnresolvedNeighbor` does), and
   every surviving operator carries a declared associativity, so the
   no-assoc tie case cannot arise. HISTORY: the first cut scoped the
   placeholder check to occurrences, and the QuickCheck differential
   found the gap within ~15 cases (a neighbour name declared but never
   used: C accepted, Haskell rejected) -- the whole-table scan is the
   fix, and the episode is why the generator is the load-bearing test.
2. Greedy loosest scan, left to right, mirroring `findLoosest`: keep the
   loosest occurrence so far; `Tighter` keeps the best, `Looser` replaces
   it, `Equal` (same name -- the partial order has no cross-operator
   equivalence classes) resolves by associativity (left-assoc takes the
   rightmost occurrence, right-assoc the leftmost), `Incomparable` is a
   diagnostic quoting both occurrences (reuse the E-FIXITY wording shape
   from `check_chain`).
3. Split at the loosest, recurse into both halves, rebuild.

Output encoding: a resolved chain is a nested `E_Chain` whose ops seq has
exactly ONE `H_ChainOp` -- precisely the shape Haskell's `combineInfix`
produces, so no new sexp node kinds and no `Surface.hs` mapper changes.
Synthesized `E_Chain` nodes are arena-allocated; the original flat node is
abandoned in the arena (no mutation of shared nodes). A synthesized node's
span covers its operands (leftmost start to rightmost end) so diagnostics
downstream still point somewhere sane.

Performance: per chain of k operators the greedy split is O(k^2) worst
case with O(1) bitset order lookups; k is the length of one source line's
operator run, so this is noise. No hashing, no extra passes over the file,
no allocation beyond the rebuilt nodes.

Relationship to `check_chain`: in reorder mode the greedy scan's
incomparable diagnostic subsumes the shield check on the chains it visits
(the shield rule is the split rule's well-formedness condition,
2026-08-06-fixity-shield-rule.md). `check_chain` still runs -- resolve is
shared -- but a chain can at most produce one fixity diagnostic per mode's
walk; if double-reporting shows up in practice, reorder mode suppresses
the check-mode walk. Decide by looking at actual output, not up front.

## The differential contract (Haskell side)

For each corpus file, two pipelines into the existing normalized
structural diff (test/Spec.hs sexp suite):

    A: wokparse -sexp -reorder FILE  -> Sexp.Read -> Surface -> Abs
    B: wokparse -sexp FILE           -> Sexp.Read -> Surface -> Abs
                                     -> Wok.Reordering.reorderModule

Assert A == B (normalized). Error side: files where reorder mode
diagnoses must be exactly the files where `reorderModule` returns Left
(chain-level agreement on the message is NOT required, only the verdict).

Properties, cheap and load-bearing:

- Error-set agreement, as above, over the whole corpus including
  generated inputs.
- Idempotence: `wokparse -sexp -reorder` on a file, printed back to
  source? No -- the dump is sexp, not source, and C has no sexp reader.
  Idempotence is tested on the Haskell side instead: `reorderModule` on
  tree A is the identity (a resolved chain contains only singleton ops
  seqs, and `reorderChain` on a singleton returns it unchanged).
- QuickCheck generator: random fixity partial orders (small DAGs, then
  closed) x random chains over the declared and some undeclared
  operators, printed as wok SOURCE text, fed through both pipelines.
  This is the load-bearing test: the 77 scheme goldens use Base
  operators with no in-file `fixity`, so they exercise the error path
  only. Shrinkage matters more than volume; keep chains short (<= 8 ops)
  and orders small (<= 6 operators).

New fixture directory: test/sexp-reorder-fixtures/ with purpose-built
files -- the shield examples from the fixity specs (`2 * 3 + 8 / 4` fine,
`2 * 3 / 4 + 8` error), left/right assoc ties, a neighbour-only name, an
undeclared operator, a nested chain under a lambda and inside a case arm.

## Order of work

1. C: the reorder pass in wok_resolve.c (or a small wok_reorder.c if
   resolve grows past taste), the `-reorder` flag, diagnostics. The pass
   signature takes the fixity table as a parameter (see Non-goals: the
   loader-merged table must drop in later without touching the pass).
2. Haskell: the differential runner in test/Spec.hs against the fixture
   directory, then the QuickCheck generator.
3. Review the divergence inventory the generator produces; fix C to match
   Haskell (Haskell is the reference; C only wins if Haskell's behavior
   is a demonstrable bug, which gets its own fix + test first).
