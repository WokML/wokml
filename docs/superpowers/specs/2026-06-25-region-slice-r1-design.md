# Region Slice R1 — inferred function-local arenas (R+escape), no new grammar

**Date:** 2026-06-25
**Status:** spec, pending user review before plan generation.
**Supersedes the outline:** `docs/superpowers/specs/2026-06-25-region-slice-r1-gist.md` (the gist; this is the full spec it gated into).
**Companion visual:** `docs/borrowership-granularity.html` (the coarse→fine borrowership ladder; R1 = lifting L3→L4 invisibly).
**Context:**
- `docs/superpowers/2026-06-24-array-region-valuemodel-arc.md` §5–6, §8 (the region epic; F/R/R+escape/D; the "second-class + escape analysis, no lifetime-in-types" verdict; the interpreter-vs-codegen judgment).
- `docs/superpowers/specs/2026-06-15-m2-continuation-aware-drop-design.md` §4.2, §7.1–7.5 (region-lifetime promotion; scoped arenas; the runtime-agnostic-placement principle; RAII scope-based).
- `src/Wok/IR/Escape.hs` (the shipped escape/borrowership analysis — the single source of truth for escaping positions).
- Memory: `[[array-slice-d-deferred-regions-pivot]]`, `[[effect-compilation-strategy]]`, `[[higher-ir-direction]]`, `[[c-runtime-arena-allocator]]`, `[[c-runtime-data-vs-state-split]]`.

---

## 0 · Provenance & locked decisions

After deferring Array Slice D (no consumer + structurally foreclosed by uniform-representation polymorphism), we pivoted to the **regions epic**, reframed as climbing one borrowership-granularity ladder (L1 immortal · L2 uniform borrow-on-call · **L3 region cohort** · **L4 escape-driven promotion** · L5 borrow-passing · L6 lifetime-in-types, rejected). R1 lifts L3→L4 **invisibly**.

Locked with the user:
- **Anchor A — invisible / inferred.** No surface marking; the compiler infers the region. (Not the opt-in `with…in` form.)
- **No new surface grammar** — a permanent constraint on the whole epic.
- **Biggest measurable win.** Maximise the drop in counted `allocs`/`frees`: route *every* sound local allocation into the uncounted arena (each becomes one fewer counted alloc and free), not just pure-data cohorts.
- **R1 region = the function body** (per-activation). Inferring "does this allocation escape the call?" is exactly **Go-style escape analysis**, and it is the inferred scope that makes the codegen transfer clean (§7): a function-local arena becomes a **stack frame** at codegen.
- **Region cells are uncounted** (the only way the win is oracle-visible today, gist §1.3).
- **Codegen transferability is a first-class design invariant** (§7), at the user's request.

## 1 · Goal & non-goals

### Goal
Introduce an **uncounted, per-activation arena tier** (C runtime + abstract-heap mirror, bit-for-bit) and a **backend-agnostic R+escape routing annotation** on the ANF IR, so that within a function body every allocation the escape analysis proves **non-escaping, mutation-free, and continuation-free** is *born in the activation's arena* (uncounted; the whole arena bulk-freed in O(1) on return, after dropping any counted children), while everything that may escape is *born in the counted RC heap* (no copy-out, no promotion walker). The win — a drop in counted `allocs`/`frees` plus a new arena-footprint stat — is proven identical on both backends by the differential oracle.

### In scope
- The C **uncounted-arena ABI**: a per-activation checkpoint stack (`wok_arena_open`/`wok_arena_close`) + arena allocation, distinct from the counted slab heap.
- The **abstract-heap mirror** of the arena (so the differential oracle can cross-check it bit-for-bit).
- A **routing pass** that annotates each allocation site in the ANF IR with `Arena | Heap`, computed from `Wok.IR.Escape` — the single artifact both the interpreter and a future codegen consume.
- The interpreter routing both backends' `alloc` on the annotation; arena cells **uncounted** (`dup`/`drop` no-ops); **scan-out** of arena cells' counted children at `close`, then O(1) reset.
- The three R1 fences (non-escaping, mutation-free, continuation-free) as compile-time predicates reusing `Escape.hs`.
- **Oracle extension**: reduced counted `allocs`/`frees`, a new `arena-bytes`/`arena-peak` stat, and an **arena-leak invariant** (every open is closed; arena empty after each close), all bit-for-bit across backends.

### Out of scope (deferred up the ladder / to later rungs)
- **Coarser/larger inferred regions** (loop/phase/whole-`with` arenas). R1 is function-body granularity only.
- **The opt-in `with…in` arena** (anchor B). Not built.
- **Borrow-passing (L5).** R1's coverage is bounded by the current coarse borrow model — a value passed as a *consuming* argument escapes the caller's arena (§5.4). L5 lifts that ceiling; not in R1.
- **Continuation-capturing / effectful-with-capture function bodies.** Fenced out (§5.3); the M2b/M3 interaction is a later rung.
- **Mutable cells in the arena.** `NArray`/`WokArray` stay counted in R1 (§5.2). Arena↔mutation is a later rung.
- **Mixed cohorts without the fast path / general LoCal serialization / lifetime-in-types.** Later / rejected.
- **Any new surface grammar.** Permanent.

## 2 · Architecture: three layers, one annotation

```
          ┌─────────────────────────────────────────────────────────────┐
 compile  │  Wok.IR.Region (NEW pass)                                     │
 time     │    reads Wok.IR.Escape  ->  tags each alloc site Arena | Heap │   <-- the ONLY artifact
          │    + marks each function body with its arena scope            │       codegen reuses (§7)
          └───────────────────────────────┬─────────────────────────────┘
                                           │  annotated ANF IR
                 ┌─────────────────────────┴───────────────────────────┐
 run time        │ interpreter reads the annotation at each `alloc`     │
          ┌──────┴───────────────┐                  ┌──────────────────┴────────┐
          │ CHeap backend         │                  │ AbstractHeap backend       │
          │  arena = C checkpoint │   differential   │  arena = uncounted addr set │
          │  stack (wok_arena_*)  │ <== oracle ====>  │  reset on close (IntMap)    │
          └───────────────────────┘   bit-for-bit    └────────────────────────────┘
```

The compile-time pass is **runtime-agnostic** (the M2 spec §7 principle). The interpreter is the *first* consumer of the annotation; codegen is the *second* (§7). The abstract mirror exists **only** as the oracle's reference.

## 3 · The uncounted arena tier (runtime)

### 3.1 C runtime (`runtime/wok_rc.{c,h}`)
A per-activation arena is a **separate bump region** owned by the `WokHeap` — its *own* slabs and bump pointer, distinct from the counted slab allocator — checkpointed LIFO. **It must NOT be a checkpoint into the shared counted bump region.** Within one function body, R+escape interleaves `Arena` and `Heap` allocations (a non-escaping local → arena, an escaping value → the counted heap, in program order); if both bumped one shared frontier, resetting it at close would reclaim the memory of an escaped *counted* cell allocated after the checkpoint — a use-after-free. Keeping arena memory in its own region makes close reset *only* arena cells; counted cells (escapees) are never touched. New ABI (additive, the counted path untouched):

```c
/* Open an arena scope: push the current bump frontier; returns a handle/depth.   */
uint32_t wok_arena_open(WokHeap* h);
/* Allocate an UNCOUNTED cell in the innermost open arena (rc field unused).        */
WokObj*  wok_arena_alloc(WokHeap* h, uint32_t tag, uint32_t arity);
/* Close the innermost arena: bulk-reclaim everything bump-allocated since open     */
/* (reset the frontier; recycle the grown slabs). The caller has ALREADY dropped    */
/* the arena cells' counted children (the Haskell scan-out, §4.3) before this call. */
void     wok_arena_close(WokHeap* h, uint32_t handle);
```

- **Uncounted:** `wok_arena_alloc` does not touch the `allocs`/`frees`/`live`/`peak` counters; it bumps a separate `arena_bytes`/`arena_peak` pair. `wok_dup`/`wok_dec` on an arena cell are **inert** — `isUncounted` recognises arena addresses, so any `dup`/`drop` the Perceus pass emits on an `Arena`-tagged binder is a runtime no-op **with no cascade** (exactly as for immortal/`Inline` values). The cell is reclaimed only by `wok_arena_close`; its counted children are released by the close **scan-out** (§4.3), not by the inert drop. (So `Wok.IR.Region` need not run in lockstep with Perceus — the runtime `isUncounted` check makes Perceus's drops inert regardless of pass order, and the scan-out is exactly the compensation that keeps the counted children balanced.)
- **O(1) close:** reset the **arena** region's bump frontier to the saved checkpoint. Arena slabs grown during the scope are **retained** (high-water, like the counted slab arena) and reused by later scopes; they are bulk-freed only at `wok_heap_free`. No per-cell walk; the counted region's frontier is untouched.
- **Nesting:** opens/closes are LIFO (a checkpoint stack over the **arena** region), matching the activation stack. A handle is the depth; `close` asserts it matches the top (loud error on mismatch).
- **No interleaving hazard:** because counted `wok_alloc` and `wok_arena_alloc` draw from *different* regions, they may freely interleave during an open scope; this is the common case (a body with both `Arena` and `Heap` allocations), not a forbidden one.
- The counted slab allocator, free-lists, `wok_free`, `peak_bytes`, and the `WokArray`/FBIP paths are **unchanged**.

### 3.2 Abstract-heap mirror (`src/Wok/Interp/RC/Value.hs`)
The oracle reference. Add an explicit **arena address space** so arena cells are representable and `isUncounted` recognises them:
- An arena cell is a positive `HAddr` recorded in a new per-depth `stArena :: [IntSet]` (a stack of address sets), allocated with `rc` irrelevant.
- `isUncounted` returns `True` for any address in `stArena` (joining the existing static/`Inline` cases), so `dup`/`drop` are no-ops on arena cells — mirroring the C side exactly.
- `arenaOpen` pushes an empty set; `arenaClose` runs the scan-out (§4.3) then deletes the depth's addresses from `stCells`/marks dead, charging the arena-stat deltas (not the counted `allocs`/`frees`).
- Touch-points the full pass must keep consistent: `dropAddr`, `cascadeChildren`, `isUncounted`, the `stReserved` FBIP guard (arena cells are FBIP-excluded — §5.5).

## 4 · The mechanism

### 4.1 The routing annotation (`Wok.IR.Region`, new)
A pass over the elaborated ANF that, per function body, computes for each `Let`-bound allocation a tag:

- **`Arena`** iff the binder is **non-escaping** in the function body (§5.1), the node is **mutation-free** (not an `NArray`, §5.2), and the body is **continuation-free** (§5.3).
- **`Heap`** otherwise (the existing counted path, unchanged).

The tag rides on the allocation RHS (a field on the alloc, or a side-table keyed by the binder `Unique`). It is a **pure function of the IR** — no heap state — so both backends and codegen read the same tags. The function body is wrapped with an arena open/close pair iff it routes at least one `Arena` allocation.

### 4.2 Interpreter routing
At each `alloc`, the interpreter reads the tag: `Arena` → `wok_arena_alloc` (C) / record in `stArena` (abstract); `Heap` → today's `alloc`. On function entry, if the body has any `Arena` alloc, emit `arena_open`; the scan-out + `arena_close` must fire on **every** exit path of the body — the normal return **and** a tail-call/`Jump` out. Close placement is therefore bracketed at the body's CPS delimiter (the same boundary the handler `open`/`close` already uses), not at a single textual return: a *missed* close is caught by the arena-leak invariant (§6), but a *premature* close would be a use-after-free, so the bracket is the load-bearing detail the plan must get exactly right. The continuation fence (§5.3) guarantees no captured continuation can re-enter the body after close, and escapees are `Heap` (§5.1), so every value still live at the bracket's close is either dead-local or counted-elsewhere.

### 4.3 Close = scan-out, then O(1) reset (the biggest-win core)
Routing *every* non-escaping local into the arena (not just pure-data cohorts) means arena cells may hold **counted** children (a counted RC-heap value the arena cell owns or borrows). At close, before the bulk reset:

1. For each arena cell at this depth, compute its **counted** children (`countedRefs` on the node — the same routine the cascade uses) and `dropAddr` each. A child that is itself an arena cell of this depth is **skipped** (uncounted; it dies in the reset). A counted child with `rc > 1` survives (shared); with `rc == 1` it cascades — exactly the RC the program would have done anyway, relocated to scope close.
2. Bulk-reset the arena (O(1)): reclaim every arena cell of this depth at once.

The **fast path**: when a cohort's arena cells have *no* counted children (pure-data — all-`Inline`/arena/static), step 1 is empty and close is truly O(1). The general path pays only for the genuine counted children, which had to be dropped regardless.

## 5 · Soundness

### 5.1 The R+escape invariant (why bulk-reset is safe)
**Escaping values are born counted, so no live counted-heap cell ever holds a pointer into the arena.** "Escapes" for a binder `p` = `p` occurs in any non-call-head, **non-scrutinee** position that outlives the activation: the return value, a consuming call argument, a constructor/record/closure field, a `Jump`, a captured continuation. Any such binder is tagged `Heap`.

**The fence is `escapesFrom` with the Case-scrutinee treated as a NON-escape — a dedicated predicate `arenaEscapes`, NOT `escapesFrom` verbatim.** (Found during Task 3: the earlier "precisely `escapesFrom`" claim was wrong. `escapesFrom` is built with `scrutEscapes = True`, so it flags a value that is merely *pattern-matched in place* — `case p of Pair a b -> …` — as escaping, which would route essentially every cohort to `Heap` and defeat the win, §5.4.) Matching `p` in place *consumes* `p` within the activation; it does not flow `p` out. So `arenaEscapes = escapeWalk False step` — the **same** alias-following step as `escapesFrom` (every `escapingAtomsRhs` occurrence is an escape), with the scrutinee-escapes flag flipped off. It lives in `Wok.IR.Escape` (the single source of truth); `Wok.IR.Region` only consumes it.

**No need to track extracted children** (this refutes the tempting `captureEscapesBody` route, which is *unsound* because it treats a consuming call-arg as a non-escape): any value stored *into* `p` (a con/record/closure field) is itself in an escaping position by that very store, so it is independently tagged `Heap`. Therefore **nothing reachable from an arena cell is itself an arena cell** — children of an arena cell are always counted (`Heap`), managed by their own refcount + the close scan-out (§4.3). Extracting a boxed child and returning it (`case p of Pair a b -> Ret a`) is sound with `p` in the arena: `a`'s underlying value is `Heap` (it flowed into the `Pair`), the match dups it out, and the scan-out drops `p`'s reference — `a` survives with its own count; `p`'s *cell* (just a pointer-slot holder) is reclaimed without dangling anything.

Therefore at close the only references *into* the arena come from (a) other arena cells of the same depth (die together) or (b) the closing activation itself (gone after return). Nothing outside can dangle ⇒ O(1) reset is sound. This is the standard region side-condition (Tofte–Talpin: free a region only if its values appear in neither the result type nor the environment), discharged here by routing rather than rejection.

### 5.2 Mutation fence
`Array.set`-in-place could overwrite an arena cell's slot with a counted ref *after* allocation, invalidating the escape verdict baked at alloc time. R1 therefore **excludes mutable cells (`NArray`/`WokArray`) from arena routing** — arrays stay counted. (Clean because arrays are already a distinct cell and already FBIP-excluded.) Arena↔mutation is a later rung.

### 5.3 Continuation fence (O3) — implemented as a MODULE-WIDE handler disable
A captured continuation must not resume into a freed arena. The hazard is sharper than "a body that captures a continuation": the per-body arena bracket frame (`KArenaCloseRC`, §4.2/Task 5) could itself be **captured into a reified continuation** by an *enclosing* handler and then discarded on abort (the arena never closes → leak) or resumed (the close fires at a stale depth → LIFO violation / UAF). A purely per-body fence cannot see that the body runs *under* a handler. So **R1 ships the conservative, sound fence: `planRegions` disables arena routing for the ENTIRE module if any `Handle` is reachable** (and the per-body `capturesContinuation` additionally fences any body containing an `ROp`). In a handler-free module no continuation is ever captured, so no bracket frame can be captured ⇒ sound; coro / `__coro_susp` / `__cont_store` continuations only arise under a `Handle`, so they are covered by the same fence. Also tightened in this slice (Task 5): `arenaEscapes` treats a boxed local captured by a `LetRec` member as escaping (it rides the group's shared env, which can outlive the activation). (`Carrier.hs` is a *separate* type-level second-class check on effect-instance handles — not this mechanism.)

**Consequence (honest):** R1's arena win currently materialises only in **handler-free modules**. For an algebraic-effects language that is a real limitation — it is exactly the spec's deferred *arena↔continuations* interaction (§1 non-goals), here realised as a blunt module-wide switch rather than a precise dynamic one. Widening it (per-activation "am I under a handler" scoping, or making `KArenaCloseRC` participate correctly in continuation capture/abort via the M2b/M3 owned-set machinery) is the next region rung.

### 5.4 The coverage ceiling (honest bound on "biggest win")
R1's drop is bounded by wok's **coarse borrow model** (L2, "uniform borrow-on-call"): only the call *head* is borrowed, so a value passed as a *consuming argument* escapes the caller's arena and is born counted. R1 therefore captures **intra-activation scratch cohorts** — values created and consumed within the body without flowing out. That is a real, measurable set, but the larger win (locals lent to callees) unlocks only with **borrow-passing (L5)**. R1 builds the mechanism; L5 later widens what it can route. This bound is stated so the measured drop is read correctly.

### 5.5 FBIP, statics, and the existing invariants
- Arena cells are **FBIP-excluded**: never an `alloc_at` target or a `drop_reuse` donor; never enter `stReserved`. (Arrays are already excluded; arena cells join them.)
- The counted invariants are untouched for `Heap` cells: `allocs − frees == baseline`, `live == baseline` at program end. Arena cells live on a *separate* set of books (§6), so they neither perturb those nor are perturbed by them.

## 6 · The cross-backend oracle invariant (the crux)

Same shape as Slice C: `Arena`-vs-`Heap` produce different stats, so the **routing decision must be identical on both backends** — and it is, because the tag is a pure compile-time function of the IR (not heap state), evaluated once and read by both. The oracle gains:

- **Reduced counted `allocs`/`frees`**, matched abstract == C, for every program that routes anything to the arena (the headline win).
- A new **`arena_bytes` / `arena_peak`** stat, matched abstract == C (the abstract mirror sums the same `wouldBeCBytes` the C side bumps).
- An **arena-leak invariant**: every `arena_open` is matched by an `arena_close`, and `arena_bytes` returns to its pre-open value after each close (since `live == baseline` cannot see arena cells, this is the dedicated check that the arena did not leak).
- Existing parity (`allocs`/`frees`/`peak`/`peak_bytes`) and leak-freedom (`live == baseline`) still hold for the counted heap.

**`stPeak` semantics note:** uncounted arena cells never enter `stLive`, so `stPeak` no longer reflects *total* live data (counted + arena). Parity still holds (both backends skip arena cells identically); `arena_peak` is the separate high-water for the arena tier. Documented, not a regression in the oracle's discriminating power.

**Honest peak trade:** scan-out-at-close holds an arena cell's counted children until scope close (leak-till-close, arc §5), which can *raise* counted `peak` versus drop-at-last-use. R1 accepts a possibly-higher `peak` for the lower `allocs`/`frees` count the user prioritised; both move identically on both backends, so the oracle stays green.

## 7 · Codegen-era transfer (first-class, per the user's ask)

**How easily does R1 carry to the codegen era? Near-1:1 by construction — and the win *grows*.** R1 is deliberately built so the durable artifacts are the backend-agnostic ones.

| R1 artifact | Codegen-era fate | Transfer cost |
|---|---|---|
| **The routing annotation** (`Wok.IR.Region`: `Arena|Heap` per alloc, from `Escape.hs`) | Codegen reads the *same* tags to choose **stack-frame** vs heap allocation. This IS Go's escape analysis; the IR tag is exactly what a native backend wants. | **~0** — reused verbatim; it is the "runtime-agnostic placement analysis" (M2 spec §7). |
| **The C arena ABI** (`wok_arena_open`/`alloc`/`close`) | Codegen emits the same calls — or, better, lowers a function-local arena to a **native stack frame** (open = `sub rsp`, alloc = bump, close = `add rsp`), the ultimate uncounted bulk-free region. | **Low** — the ABI is in the shared C runtime; codegen either calls it or inlines it. |
| **The scan-out at close** (drop arena cells' counted children) | Same drops, emitted inline by codegen; pure-cohort fast path becomes a single stack-pointer reset (zero instructions of cleanup). | **Low** — the rule is IR-level; codegen lowers it. |
| **The abstract-heap mirror** | **Not transferred** — it is the differential *oracle*, interpreter-only. Codegen validates against the C runtime + the same analysis, not the IntMap. | **n/a** — confined to the oracle by design. |
| **The soundness fences + the R+escape invariant** | **Identical** — they are properties of the IR analysis, not the runtime. The proof carries. | **~0**. |

The interpreter measures the *proxy* (counted `allocs`/`frees` drop) and proves the analysis correct; codegen realises the *real* win the interpreter cannot show (arc §8): function-local arena → **stack allocation**, inlined bump instead of an FFI call, an O(1) `add rsp` close instead of a runtime call, and the cache-locality/no-RC-traffic payoff. The relative win therefore **increases** at codegen. The one design rule that guarantees this: **keep routing an IR annotation and the arena in the shared runtime; never let the placement decision leak into interpreter-only code.** That rule is an explicit invariant of this slice (§2).

## 8 · Differential oracle requirements

For every region corpus program, on both backends:
- **Output byte-identical.**
- **`allocs`/`frees`/`peak`/`peak_bytes` match** abstract == C, and reflect the *reduced* counted counts (arena cells excluded).
- **`arena_bytes`/`arena_peak` match** abstract == C.
- **Arena-leak invariant:** opens == closes; `arena_bytes` back to pre-open after each close.
- **Counted leak-freedom:** `live == baseline`, `allocs − frees == baseline` at program end.
- A corpus program must exercise **both** branches — a non-escaping scratch cohort (→ arena, counts drop) and an escaping value (→ heap, counted) — plus a pure-data fast-path cohort and a counted-child scan-out cohort, so any cross-backend disagreement on a tag diverges the stats and fails the differential immediately.

## 9 · Testing
- **C arena unit tests** (`runtime/test`, ASan/UBSan + LeakSanitizer): open/alloc/close round-trips; LIFO nesting; bulk-reset reclaims (pointer-identity reuse after close); the arena stats; mismatch `close` is a loud error; no leak under sanitizers.
- **Routing-pass unit tests** (`Wok.IR.Region`): the `Arena|Heap` tag matches a hand-computed escape verdict on the #non-escape/#escape/#mutation/#continuation shapes; purity over re-runs (idempotent, heap-independent).
- **Store-algebra tests** (abstract): arena alloc is uncounted (`dup`/`drop` no-ops); scan-out drops exactly the counted children once; `close` returns `arena_bytes` to baseline; `live` unaffected.
- **Differential-oracle corpus** (`test/rc-region/…`): the four shapes in §8, byte-identical output + all stat parities + arena-leak + counted-baseline, on both backends.
- **Soundness teeth**: the existing Suite-C mutation oracle must still bite on the counted parts; a deliberately-wrong tag (route an escaping value to the arena) must fail the differential and/or a balance lint.
All via tasty (Hspec + QuickCheck). No temporary fixes; tests coherent to this spec and documented.

## 10 · Files touched
- `runtime/wok_rc.{c,h}` — the `wok_arena_*` ABI (checkpoint stack, arena alloc, bulk-reset, arena stats); `runtime/test` + `scripts/asan-runtime.sh`.
- `src/Wok/Interp/RC/Heap.hs` — FFI imports for `wok_arena_*`.
- `src/Wok/IR/Region.hs` (**new**) — the routing pass (`Arena|Heap` from `Wok.IR.Escape`); export the annotation.
- `src/Wok/IR/Escape.hs` — reuse only (possibly export a small per-binder non-escape helper; no analysis change).
- `src/Wok/Interp/RC/Value.hs` — the abstract arena mirror (`stArena`, `isUncounted` arena case, `arenaOpen`/`arenaClose` + scan-out), arena stats, FBIP exclusion.
- `src/Wok/Interp/RC/Machine.hs` — read the tag at `alloc`; open/close the arena around an annotated function body.
- the differential-oracle harness — arena-stat parity + arena-leak invariant.
- `test/rc-region/…`, `test/Spec.hs` — corpus + unit/store-algebra/teeth tests.
- `runtime/README.md` — document the arena tier + the routing annotation.

## 11 · Task breakdown (each ships green; tiers at plan time)
1. **C `wok_arena_*` ABI + checkpoint stack + arena stats + standalone tests** (ASan green; Haskell unchanged still builds). — *standard*.
2. **FFI bindings** (`Heap.hs`). — *mechanical*.
3. **`Wok.IR.Region` routing pass** (the `Arena|Heap` annotation from `Escape.hs`; the three fences) + unit tests. — *standard / frontier* (the escape-verdict composition is the judgment-heavy part).
4. **Abstract arena mirror + scan-out + uncounted semantics** (`Value.hs`) + store-algebra tests. — *standard*.
5. **Interpreter routing + function-body open/close** (`Machine.hs`). — *standard*.
6. **Oracle extension** (arena-stat parity + arena-leak invariant) + the `test/rc-region` corpus (four shapes). — *standard*.
7. **Docs + memory** (`runtime/README.md`, a new memory note, mark the arc/ladder); scaffolding cleanup. — *mechanical*.

## 12 · Decisions locked / deferred
**Locked:** anchor A (invisible/inferred, function-body granularity = Go-style escape analysis); no new grammar; region cells uncounted; biggest-win routing (every non-escaping mutation-free continuation-free local → arena, scan-out counted children at close, pure-cohort O(1) fast path); routing is a backend-agnostic IR annotation (the codegen-transfer linchpin); cross-backend oracle parity + arena-leak invariant; arrays excluded (mutation fence); continuation-capturing bodies excluded (O3 fence).
**Deferred (with triggers):** borrow-passing (L5, lifts the coverage ceiling §5.4); coarser regions (loop/phase/`with`); arena↔mutation (arrays); arena↔continuations (M2b/M3); the opt-in `with…in` arena (anchor B); general LoCal serialization; lifetime-in-types (L6, rejected).

## 13 · Future direction
R1 is the L3→L4 rung built so its two load-bearing parts — the escape-driven routing annotation and the shared-runtime arena — are exactly what a codegen backend reuses, where the function-local arena becomes a stack frame (§7). L5 (borrow-passing) then widens the routable set; coarser inferred regions raise the per-region payoff; and the same annotation feeds the eventual LoCal/serialization work, all without re-deciding placement.
