# Region Slice R1 — spec GIST (outline, not the full spec)

**Date:** 2026-06-25
**Status:** GIST for user review — the full spec is gated on user approval (workflow phase 4).
**Companion visual:** `docs/borrowership-granularity.html` (the coarse→fine borrowership ladder; R1 = lifting L3→L4 with no surface change).
**Context:**
- `docs/superpowers/2026-06-24-array-region-valuemodel-arc.md` §5–6 (the region epic: F / R / R+escape / D; the deep-research "second-class + escape analysis, no lifetime-in-types" verdict).
- `docs/superpowers/specs/2026-06-15-m2-continuation-aware-drop-design.md` §4.2, §7.1–7.5 (region-lifetime promotion; scoped arenas; RAII scope-based; the trilemma).
- `src/Wok/IR/Escape.hs` (the shipped escape/borrowership analysis — `escapesFrom`, the single source of truth).
- Memory: `[[array-slice-d-deferred-regions-pivot]]`, `[[effect-compilation-strategy]]`, `[[m2a-2-shared-env-recursive-closures]]`, `[[c-runtime-arena-allocator]]`, `[[c-runtime-data-vs-state-split]]`.

---

## 0 · How we got here (provenance)

Array Slice D (flat value arrays) was deferred — no consumer, and structurally foreclosed by wok's uniform-representation polymorphism (monomorphization is the dividing line). We pivoted to the **regions epic** and reframed it as climbing one *borrowership granularity ladder*, coarsest→finest: L1 immortal · L2 uniform borrow-on-call · **L3 region cohort** · **L4 escape-driven promotion** · L5 borrow-passing · L6 lifetime-in-types (rejected ceiling). wok is solid through L2, has a baby L3 (the `LetRec` group) and the L4 escape analysis. **Hard constraint from the user: no new surface grammar.** R1 lifts L3→L4 invisibly.

## 1 · Material runtime findings that SHAPE R1 (verified 2026-06-25)

These reshape the slice; the full spec is built on them.

1. **No region runtime exists.** No `stRegionOf`, no region id on cells, no arena checkpoint/reset in `runtime/wok_rc.c` (only per-cell `wok_free` + whole-heap `wok_heap_free`; stats are monotonic). The `LetRec` "region" is one static (uncounted) code cell + at most one counted `NEnv` cell (zero cells when the group is capture-free) — never a cohort, so it is **not** a useful bulk-free target (nothing to pool).
2. **No allocation routing.** Every allocation goes through one `alloc` chokepoint; `escapesFrom` is used only as a *reject/coverage* predicate, never to choose *where* a value is allocated. R+escape routing is genuinely new.
3. **The win is oracle-visible ONLY if region cells are UNCOUNTED.** The cross-backend parity oracle compares `allocs`/`frees`/`peak`/`peak_bytes` (and checks `live == baseline` per-backend for leak-freedom), not dup/drop traffic. If a region cohort is *uncounted* (arena-managed, like immortals — never entering `stAllocs`/`stFrees`/`stLive`), routing it out of the counted pool **drops `allocs` and `frees`** while preserving `allocs − frees == baseline` — measurable in the interpreter today. If region cells stayed counted, the stats would not move and the win would be invisible until codegen (arc §8). **Decision: R1 region cells are uncounted.** (Consequence the full spec must own: uncounted arena cells also never enter `stPeak`, so `stPeak` stops reflecting *total* live data — parity still holds because both backends skip them identically.)
4. **Continuation soundness (O3) is real but fenceable.** A captured continuation must not resume into a freed region. The wall R1 leans on is the **M2b handler boundary guard** — `m2bHandlerViolations` (`Reachable.hs`) via `m2bResumeEscapes`/`m2bResumeEscapesStoreRoute` (`Escape.hs`) — which rejects a handler whose `resume` escapes a non-call-head position. (`Carrier.hs` is a *separate*, type-level second-class check on effect-instance handle carriers — not the `resume`-escape mechanism; the gist must not conflate them.) R1 fences out continuation-capturing scopes entirely (defer to a later rung).

## 2 · R1 goal (one sentence)

Introduce the **uncounted scoped arena** as a real runtime tier (C + abstract heap, bit-for-bit) and the **R+escape allocation-routing seam**, so that a delimited, continuation-free cohort of *fully-uncounted-children* allocations is born in the arena (uncounted, bulk-freed at scope close) while anything that escapes is born in the normal counted RC heap — with the reduced counted `allocs`/`frees` + a new arena-bytes stat proven identical on both backends.

## 3 · Mechanism (the substance)

- **Uncounted arena tier.** A new runtime region scope: `wok_arena_open`/`wok_arena_close` (C) = checkpoint the bump pointer + reset to it on close (O(1) teardown); the abstract heap mirrors it with a region-id set of uncounted addresses reset on close. Arena cells carry no rc; `dup`/`drop` are no-ops on them (exactly the immortal-tier discipline, but scope-bounded instead of program-bounded).
- **R+escape routing at the alloc site.** A compile-time, pure escape verdict (from `Escape.hs`) tags each allocation in a region scope as **local** (→ arena, uncounted) or **escaping** (→ counted RC heap, born counted — no copy-out, no promotion walker). Because the verdict is a pure function of the IR, both backends route identically.
- **Close = scan-out then reset.** At scope close, any outbound *counted* reference held by an arena cell is dropped (so a borrowed counted child isn't leaked), then the arena is reset O(1). **R1 fence (keeps close truly O(1)): arena-route only cohorts whose transitive children are all uncounted** (arena/immortal/inline) — i.e. pure-data cohorts — so there are no outbound counted refs to scan. Mixed cohorts stay counted in R1; the scan-out generalization is R2.
  - **Mutation precondition (review catch):** the fence must hold *transitively and over time*, not just at the alloc site — `Array.set`-in-place could overwrite an arena cell's slot with a counted ref after allocation. R1 therefore additionally requires the cohort be **mutation-free** (no in-place `set` into an arena cell), or excludes mutable cells (arrays) from arena routing. The full spec pins which.

## 4 · The crux: the cross-backend oracle invariant

Same flavor as Slice C. In-arena vs in-heap produce different `allocs`/`frees`/arena-bytes, so the routing decision must be **identical on both backends** — it is, because the escape verdict is a pure compile-time function of the IR (not heap state). The oracle gains: (a) reduced counted `allocs`/`frees` for arena-routed cohorts, matched on both backends; (b) a new **arena-bytes / arena-peak** stat, matched on both backends; (c) the arena returns to baseline after each scope close (no arena leak), alongside the existing counted `live == baseline`.

## 5 · The R1 scope anchor — THE decision for you (see §7)

The arena needs a scope boundary. Two no-grammar options:
- **(A) Invisible / inferred** (recommended, matches "lifetime as analysis"): the compiler infers a region around a lexical scope where `escapesFrom` proves a local, continuation-free, uncounted-children cohort. No programmer marking at all. Heavier analysis; the most wok-native.
- **(B) Opt-in via the existing `with…in` effect syntax**: a built-in op-less `region` handler whose dynamic extent is the boundary (reuses the handler open/close hooks for arena open/close). No new grammar, explicit boundary (easier to implement), a clear consumer (the programmer wraps alloc-heavy code), but visible and it entangles with the handler/continuation machinery.

## 6 · Out of scope for R1 (deferred up the ladder)

- Scan-out of outbound counted refs / mixed cohorts (R2).
- Continuation-capturing region scopes; any M2b/M3 interaction (later rung).
- General region inference across the whole program (the L4 north star).
- Borrow-passing (L5); lifetime-in-types (L6, rejected).
- Any new surface grammar (permanent constraint).

## 7 · Decisions for your review (ratify before the full spec)

1. **Anchor: (A) invisible/inferred vs (B) opt-in via existing `with…in`.** My lean: **A** (no surface, most "lifetime as analysis"), accepting the heavier inference — but B is the more tractable first build. Your call.
2. **Uncounted region cells (§1.3).** Confirm: R1 makes the win measurable by making region cohorts *uncounted* (so `allocs`/`frees` drop), rather than a foundation-only slice with no oracle-visible change.
3. **Honest framing.** R1's interpreter win is the *alloc/free-count + arena-footprint* reduction (real, oracle-visible) plus O(1) teardown; the *cache/SIMD* win remains codegen-era (arc §8). Are you content building R1 as the measurable foundation of the epic on that basis?

## 8 · Rough task shape (tiers assigned at plan time)

1. C uncounted-arena ABI (`wok_arena_open`/`close` = checkpoint/reset) + ASan tests.
2. Abstract-heap arena mirror (region-id uncounted set + reset) + arena stats.
3. The escape-verdict → alloc-routing seam (pure, compile-time; both backends).
4. The scope anchor (A or B) + the uncounted-children fence.
5. Oracle extension: reduced counted allocs/frees + arena-bytes parity; arena-returns-to-baseline.
6. Corpus (a region-using program with a local uncounted cohort + an escaping value) + soundness tests; docs + memory.

## 9 · Full-spec obligations (surfaced by the alignment review)

The gist is an outline; the full spec must resolve each of these (all flagged by the reviewer subagent):

1. **Arena vs `WokHeap`.** `wok_arena_open`/`close` is a *separate* bump region, not a checkpoint into the existing `WokHeap` slab bump pointer. Pin the C API + FFI shape and where the arena's storage lives.
2. **Abstract-heap arena cell representation.** `isUncounted` today only matches static (negative `HAddr`) or `Inline`. Arena cells need an explicit representation (a new `Addr`/`ArenaAddr` variant, or an `IntSet` of arena addresses), and the touch-points: `dropAddr`, `cascadeChildren`, `isUncounted`, the `stReserved` guard.
3. **Fence enforcement.** The exact compile-time analysis that proves a cohort is local + fully-uncounted-children + mutation-free + continuation-free, reusing `escapesFrom` (define what, if anything, is needed beyond it).
4. **FBIP interaction.** An arena cell must not be an FBIP reuse donor/target (`dropReuse`/`alloc_at`/`stReserved`); state the exclusion explicitly (arrays already FBIP-excluded; arena cells join them).
5. **Arena-leak detection.** `live == baseline` cannot catch an unclosed arena scope (arena cells are off the counted books). Add an explicit invariant — an `arena-open == arena-close` count, or `arena-bytes == 0` after each close — to the oracle.
6. **`stPeak` semantics.** Document that `stPeak` no longer reflects total live data once arena cells are uncounted (parity still holds; the figure's meaning changes).
7. **Anchor feasibility (decision §7.1).** If option A (inferred), define concretely how heavy the inference is (bounded structural check vs a new IR fixed-point); if option B (`with…in`), specify how the op-less `region` handler's open/close is exempt from the `KHandleRC` counted-frame machinery without new grammar.
