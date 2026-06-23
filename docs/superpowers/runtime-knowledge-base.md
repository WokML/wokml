# wok runtime-representation — knowledge base (local RAG)

**Purpose.** A single, lightweight, grep-able reference that grounds the runtime/codegen
claims made across the wok specs (arena allocator, layout compaction, and beyond). Every
fact is tagged with its **source** so a claim in a spec can be traced and re-checked locally
without re-fetching. Keep it *small-weight*: concise claims + citations, not prose essays.

**How to use.** Grep for a term (e.g. `scan_fsize`, `sharded`, `NaN`, `FBIP`) to find the
fact + its source tag, then open the source. When a spec asserts a runtime fact, it should be
traceable to a `[tag]` here. If you add a new researched fact, add it here with a source tag.

**Confidence markers.** `[verified]` = read from the cited source. `[reconstructed]` = from
memory of a source now offline — **verify before relying**. `[general]` = established
common knowledge.

---

## Sources index

- **[R1]** in-repo: `docs/superpowers/2026-06-21-mimalloc-koka-allocator-research.md` —
  mimalloc v2.3.2 + Koka `kklib`, studied from read-only clones, **cites `file:line`**.
- **[R2]** in-repo: `docs/superpowers/2026-06-21-packed-data-local-research.md` —
  LoCal/Gibbon (packed/serialized data), cites the PLDI'19 paper by section.
- **[R3]** LuaJIT 2.0 IP-disclosure post, Mike Pall:
  `http://lua-users.org/lists/lua-l/2009-11/msg00089.html` — fetched this session.
- **[P1]** *Perceus: Garbage Free Reference Counting with Reuse* — Reinking, Xie, de Moura,
  Leijen, PLDI 2021. (wok's RC model.)
- **[P2]** *Low-Latency, High-Throughput Garbage Collection (LXR)* — Zhao, Blackburn,
  McKinley, PLDI 2022. (RC + Immix backup-trace.)
- **[P3]** *Immix: A Mark-Region GC…* — Blackburn, McKinley, PLDI 2008.
- **[P4]** *Ulterior Reference Counting* — Blackburn, McKinley, OOPSLA 2003. (RC + copying nursery.)
- **[K]** general/common knowledge (GHC info tables, ZGC/Shenandoah, LuaJIT GC).
- **[W]** wok decisions: `docs/superpowers/specs/2026-06-21-c-runtime-allocator-ncon-design.md`,
  `…/2026-06-21-c-runtime-arena-allocator-design.md`, `…/2026-06-22-layout-compaction-design.md`,
  `…/2026-06-22-layout-compaction-slice2-design.md`, `…/2026-06-23-fbip-reuse-design.md`,
  and the auto-memory notes.
- **[W: fbip spec]** `docs/superpowers/specs/2026-06-23-fbip-reuse-design.md` — FBIP S2
  in-place reuse design: token, ops, pairing pass, slot-kind guard, oracle invariants.

---

## 1. RC object model — Koka / Perceus  [R1, P1]

- **Header is one 64-bit word, 8 bytes:** `uint8 scan_fsize; uint8 _field_idx; uint16 tag;
  int32 refcount`.  [R1: `kklib.h:136-141`, verified]
- **Refcount is 32-bit, sign/saturation folds three roles:** `0`=unique, `1..INT32_MAX`=
  thread-local count, negatives=thread-shared/sticky, `INT32_MIN`=**immortal/static** (not a
  flag — a stuck negative count, `KK_HEADER_STATIC`).  [R1: `refcount.c:97-175`, `kklib.h:106,147`]
- **Fields are 8-byte tagged words** (pointer tagging): low bit `0`=heap pointer, `1`=inline
  value; small ints are `4n+1` (so ~62-bit); bigints are boxed pointers.  [R1: `kklib.h:987-998`,
  `integer.h:12-39`]
- **A known fixed-width / raw field (e.g. `int64`, `double`) lives raw in the unscanned
  suffix** (after the `scan_fsize` scannable prefix) — *not* boxed. Only a value forced into a
  generic tagged word (or arbitrary-precision `int` past 62-bit) is boxed.  [R1: scan_fsize model
  `kklib.h:834-886`; general Perceus layout, P1]
- **Free cascade runs in C, driven by header `scan_fsize` + per-field low bit;** convention
  **pointer-bearing fields first**; production path is *stackless* (threads parent through
  field 0, stores cursor in `_field_idx`).  [R1: `kklib.h:834-886`, `refcount.c:366-450`]
- **In-place reuse (FBIP)** = `drop_reuse` (on rc==0 & unique, drop children but **return the
  block**) + `alloc_at` (a later constructor reuses that exact pointer, re-stamps the header).
  Reuse token = a block pointer. **Size-class fit is the compiler's responsibility**, trusted
  by the runtime.  [R1: `refcount.c:213-231`, `kklib.h:650,654-667,662`]
- **wok FBIP S2 (IMPLEMENTED, `feat/fbip-reuse-s2`, 1307 green):** both heaps — abstract
  `IntMap` index-recycle AND C arena pointer re-stamp via `wok_alloc_at`; a first-class affine
  `RVReuse` token (`RVReuse Nothing` = shared/NULL, `RVReuse (Just ReuseSlot)` = reserved
  shell). The **pairing** is a `reusePairing` **post-pass** run *after* `insertRC` (auditable,
  balance-preserving; does NOT thread through `ownExpr`/`balanceLint`). The **§6.3 slot-kind
  guard** refuses to pair constructors with differing per-field storage classes (a
  `Cons`-of-`Int` shell cannot absorb a `Cons`-of-`Char` — the tag-keyed C descriptor would
  mis-decode). The pairing is **SAME-constructor only** (review finding F1): the target `RCon`
  must use the *same* constructor as the matched cell, not merely the same slot-kind signature.
  Cross-constructor reuse is unsound here — a different target tag could carry a stale tag-keyed
  C descriptor (mis-decode) AND the abstract heap (no descriptor) would reuse unconditionally,
  diverging between backends. `nodeCEligible` is **value-only** (no descriptor, no tag-table) so both backends
  decide reuse identically; the only residual runtime difference is an `Int`/`U64` field crossing
  the `≥ 2^63` boundary. **Runtime `rc == 1` gate**: a shared cell returns NULL, `alloc_at`
  allocates fresh — correctness never depends on the pairing analysis. Strings are
  non-encodable abstract literals (future Array-like `String` = separate track); the slot-kind
  guard refuses to pair across the string boundary; FBIP still reuses string-bearing cells on
  the abstract heap by index at zero extra cost. **Measured collapse:** `map`/`reverse` over a
  3-element list 6 allocs/6 frees → 3/3 (spine = 0 net); output bit-for-bit identical on both
  backends verified by the differential oracle. **EFFECT-SAFETY RESIDUAL (S2 is NOT fully
  effect-safe):** the pairing scan refuses to span a *direct* `ROp` (so a token never crosses
  an explicit effect op), and `continuationOwned` is total over an `RReuseCon` (an in-flight
  token in a captured continuation frees its **fields**, like an `RCon`, never crashes). But a
  token can still span an **effectful CALL** (an `RApp` whose callee performs an op), and the
  reserved shell has **no finalizer** in the M2b/M3 continuation-RC owned set — so under an
  *aborting* handler the shell leaks (fields are freed, shell is not). The S2 corpus is
  effect-free, so this is **unobservable** there; a Koka-style reuse-token finalizer in the
  continuation owned set is a **deferred follow-on**.  [W: fbip spec]
- **Context threading:** Koka threads a `kk_context_t* ctx` through every function; `free`/
  reclaim take the ctx (no pointer-masking needed at the RC layer).  [K, P1]

## 2. Allocator — mimalloc  [R1]

- **73 size-class bins, ~12.5% spacing.**  [R1: `page-queue.c:60-92`]
- **Per-page sharded free lists:** `free` (owner, non-atomic) / `local_free` (deferred) /
  `xthread_free` (atomic, cross-thread). Common path is lock-free.  [R1: `types.h:292-356`,
  `free.c:281`]
- **First-class heaps → O(pages) bulk teardown** (`mi_heap_destroy` frees every block without
  per-object free or graph walk); `mi_heap_new` sets `no_reclaim`.  [R1: `heap.c:362-388,258-261`]
- **THE v2 CONSTRAINT:** a heap may only **allocate** from its creating thread → races
  **silently in release** under GHC's thread-migrating RTS. Cross-thread *frees* are safe.
  **mimalloc v3 removes this.**  [R1: `mimalloc.h:206-207`, `heap.c:222`, `readme.md:84`]
- **Pointer-masking:** segments/pages are size-aligned, so `free(ptr)` recovers its page by
  masking low address bits — needed because mimalloc's `free` takes only the pointer.  [R1:
  metadata out-of-band `internal.h:528`, alignment `types.h:37-38,217`]
- **Integration:** `static.c` amalgamation drops into `c-sources` (one TU), MIT, C11.  [R1]

## 3. LuaJIT  [R3, K]

- **NaN-tagging:** 64-bit tagged values; doubles overlaid with tagged object refs via special
  NaNs. "A remote descendant of pointer-tagging."  [R3, verified in the post]
- Also in the post: low-overhead call frames (frame links as bit patterns), **linear
  pointer-free IR** (64-bit instructions, **16-bit references**, bidirectionally growable
  array), skip-list chains, FOLD engine, trace compiler.  [R3, verified]
- **Numbers are doubles / int32 — no native 64-bit integer** in the value rep (targets Lua
  5.1).  [K]
- **Tracing incremental mark/sweep GC** (no per-value refcount).  [K]
- **New-GC arena design** (16-byte cells, 64 KB aligned arenas, block/mark bitmaps,
  pointer-masking) — from the LuaJIT wiki, now **offline**.  [reconstructed — verify before
  relying]
- **Transfer to wok:** the bit-packing *discipline* + the arena *structure* — **NOT**
  NaN-boxing (wok has no floats; it costs integer range) and **NOT** the cell shape.  [W]

## 4. Wider GC landscape  [P2, P3, P4, K]

- **Immix** = mark-region with block/line bitmaps (bump + opportunistic evacuation); the
  living "SOTA mark-region" family (Go uses span bitmaps; MMTk's flagship is Immix).  [P3, K]
- **LXR** = reference counting on an Immix-style region heap + occasional backup trace;
  matches/beats production tracing collectors → validates "RC + region allocator".  [P2]
- **Ulterior RC** = RC mature space + copying/traced nursery (the ancestor of LXR). A real
  "RC + nursery" design — but the nursery is *traced*, which departs from pure Perceus.  [P4]
- **ZGC / Shenandoah** = colored pointers + load/store barriers + concurrent compaction; the
  low-latency frontier (not bitmap-centric).  [K]
- **GHC** stores a **1-word (8-byte) info-table *pointer*** in every heap object header
  (points to static layout + entry code).  [K]

## 5. Packed / serialized data — LoCal / Gibbon  [R2] — OPPOSING model, parked

- Whole tree = one flat preorder byte buffer; **no per-node header, no inter-node pointers,
  leaves unboxed**; ~4x smaller, traversal is a linear scan.  [R2 §2]
- **Region-level RC only** (no per-node header → a per-value Perceus refcount is physically
  impossible); **write-once**; **sharing → indirections**; **random access → scan**; cycles
  forbidden.  [R2 §4.5, §6, §2]
- Verdict: an **opposing** ownership model, not a variant of wok's cells. Far-future, opt-in,
  AST-types-only, behind native codegen.  [R2, W]

## 6. wok decisions — the through-line  [W]

- **Why language-specific beats general (mimalloc):** wok knows what mimalloc can't — known
  layout (the descriptor), single-threaded per run, compiler-inserted RC, static
  lifetime/uniqueness. So wok **skips** sharded lists / size-class pages / pointer-masking it
  can prove it doesn't need, *and* does FBIP/escape tricks a general allocator can't.  [W]
- **Arena (MERGED, `main`):** per-run slab arena — bump + **arity-exact** LIFO free lists +
  O(slabs) bulk teardown; `arity≥64`→direct malloc. No collector (RC = no pauses). malloc
  retained behind `WOK_RC_MALLOC` (UAF oracle). Simpler-than-mimalloc by exploiting the
  language invariants above.  [W: arena spec]
- **Compaction (DESIGN, Slice 1 = option B):** 8B header (`rc32|tag16|arity8|scan8`) + **raw
  8B descriptor-driven slots** + a descriptor-driven Haskell cascade. **No runtime promotion**
  (the descriptor regime never overflow-promotes); the int **encoding semantics are unchanged**
  — a high-bit `U64` (≥ 2⁶³) still **falls back** to the abstract heap (alloc-site selection,
  not re-boxing). Full-range-`U64`-*inline* (needs the descriptor to carry field signedness)
  and the C-driven `wok_drop` cascade are **deferred**. The **descriptor** (per-constructor,
  keyed by `tag`) is wok's info-table — a 16-bit index, not an 8-byte pointer; it hoists the
  per-slot "kind" out of every cell. The **crux**: self-description (tagged word, loses bits,
  *promotes*) vs descriptor (raw, no promotion); static typing makes the descriptor free.
  [W: compaction spec]
- **Immediates (Slice 2, IMPLEMENTED `feat/layout-compaction-slice2`, 1282 green):** a nullary
  constructor (`Nil`/`None`/`True`/`False`/any `data T = A`) is an **inline immediate** —
  `Addr` gains `Inline Word32` (the interned con tag), intercepted at the shared `alloc`
  chokepoint (no cell, no stat bump, both backends) and synthesized back by `deref`. Uncounted
  (dup/drop no-ops, reusing the static-cell precedent). The C heap never holds an arity-0 cell.
  Measured: tree −50% allocs / −20% bytes, boolean churn −100%.  [W: slice2 spec]
- **Pointer slots carry a 2-bit low tag** (was 1 bit in Slice 1): `00` = C-cell (`CAddr`,
  8-aligned, read as-is), `01` = H-addr (`(i<<2)|1`), `11` = inline immediate (`(tag<<2)|3`);
  `10` unused. Koka-style bit 0 = pointer-vs-value; `KPointer` subsumes pointer-or-immediate
  (no new `SlotKind`). The cross-heap C-vs-H split rides in bit 1.  [W]
- **Extreme-perf roadmap (follow-on slices):** ~~FBIP in-place reuse~~ (DONE, S2 above) →
  **escape→stack/region allocation** (head) → reuse specialization + rc elision →
  monomorphize/unbox. All enabled by the descriptor + arena + the analyses; none folded into
  the layout slice.  [W, P1]
