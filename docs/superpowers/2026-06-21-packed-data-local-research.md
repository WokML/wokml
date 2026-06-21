# Packed/serialized data (LoCal, PLDI'19) — research verdict for wok

- **Date:** 2026-06-21
- **Paper:** Vollmer, Koparkar, Rainey, Sakka, Kulkarni, Newton, *"LoCal: A Language for
  Programs Operating on Serialized Data,"* PLDI 2019 (the Gibbon project).
- **Question asked:** is packed/serialized representation relevant to wok's runtime, given we
  are committed to Perceus per-value RC, free sharing, and O(1) random field access?
- **One-line verdict:** A genuinely impressive technique, unusually well-matched to wok's
  *compiler/AST* dogfooding domain — but an **opposing** memory model to our RC heap, not a
  variant of it. Park it as a **far-future, opt-in, sharply-restricted `packed` representation
  for immutable tree types, sitting beside the RC heap, gated behind native codegen.** It does
  **not** touch slice 1.

## What LoCal does (cited from the paper)

- A whole tree is stored as **one flat byte buffer** in preorder: a 1-byte constructor tag,
  then atomic fields inline, then children **inline** right after the parent — recursively.
  **No pointers between nodes, no per-node header word, leaves unboxed** (§2). The paper's
  example: a 5-node tree is 64 bytes boxed (12 bytes "useful") vs a handful of tag bytes +
  inline ints packed — ~4x smaller, and traversal is a linear memory scan (§2, Fig. 1).
- **Random access is the price.** A field that is itself a tree has *data-dependent size*, so
  you cannot index field `i` by arithmetic — you must **scan** past everything before it
  (`rightmost` is O(N) not O(log N), §2). Random access is restored only by inserting
  **offset** bytes or **indirection** pointers per-constructor/per-field (§2, §3.4, §4.2), and
  doing so can pessimize composed traversals (§7.2 `repMax`).
- **Ownership is region-based, not per-value.** Regions are **write-once / immutable**, and
  reference counting is tracked **only at region granularity** ("exiting a `letregion`
  decrements the region's count, freed when no other regions point in," §4.5). A packed node
  has no header and no identity, so **a per-node Perceus refcount is physically impossible**.
- **Sharing is the expensive exception.** "Sharing demands indirections" — `Node x x` becomes
  `Node x (I x)` (§6). DAGs allowed via indirections; **cycles forbidden**. This is the inverse
  of wok, where sharing is the free default.
- **Mutation is unsolved here** and explicitly deferred to future *linear-types* work, not RC
  (§8).
- **Safety** comes from the **location calculus** type system (symbolic locations, `after`/`+1`
  ordering, write-once, end-witness reads) that forces forward, left-to-right access (§3). It's
  load-bearing for *safety*, not for *capability* (raw C buffer code works without it, §2).
- **Numbers:** ~4x smaller footprint; ~2.6x apples-to-apples vs a non-packed pointer rep; up to
  **543x** on reading+traversing Racket ASTs with IO (7.1x even discounting IO) (§7, Table 2,
  §7.4). The flagship win is literally an **AST workload**.

## Why it conflicts with wok's committed pillars

| wok pillar | LoCal |
| --- | --- |
| per-value Perceus RC | region-level RC only; no per-node header to hold a count (§4.5) |
| free sharing via RC | sharing → indirection pointers (the packing benefit is lost there) (§6) |
| O(1) random field access | data-dependent offsets → scan or explicit offset bytes (§2) |
| in-place reuse (FBIP) | regions are write-once/immutable; mutation deferred to linear types (§8) |

So packing is **not** a way to lay out our cells; it is a different runtime for a different
job.

## The defensible adoption path (if ever)

- **Far-future, and downstream of native codegen** — packing's wins are cache locality,
  mmap-without-deserialize, and byte density; a tree-walking interpreter realizes none of them.
- **Opt-in per type:** a `packed data Expr = ...` for immutable, single-owner, forward-traversed
  trees, built in destination-passing style, consumed by fold/map-shaped passes.
- **Forbid the hard cases rather than solve them** (start from the Gibbon1 "fully serialized,
  no offsets/indirections" point the paper describes, not the full location calculus): a shared
  use copies out to the normal RC heap or is rejected; no random access (only forward
  combinators); no mutation. Safety can ride on a **sealed forward-only cursor/fold API** whose
  types enforce the ordering — wok's existing "dangerous capability behind a trusted marker"
  pattern — rather than a whole new IR type system.
- **Sweet spot:** read-mostly AST passes (pretty-print, metrics, single-pass folds, loading a
  cached IR off disk). **Weak spot:** sharing-heavy, random-access, rewrite-with-sharing passes
  — exactly where wok's RC sharing already shines, so the two are complementary, not competing.

## Bearing on the current spec

None for slice 1. This is recorded as a far-future, separate-model direction; the
`specs/2026-06-21-c-runtime-allocator-ncon-design.md` plan stands unchanged.
