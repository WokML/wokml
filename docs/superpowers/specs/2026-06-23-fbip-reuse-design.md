# FBIP Slice 1 (S2) — in-place reuse for `map` + `reverse`

**Status:** IMPLEMENTED on `feat/fbip-reuse-s2` (1307 green; pending full-branch review/merge)
**Date:** 2026-06-23
**Track:** RC runtime / value-model. The recorded capstone after layout-compaction immediates.
**Visual companion:** `docs/fbip-reuse.html` (intuition; this spec is the precise contract).

---

## 0. Thesis in one paragraph

A `map` over an N-element list today does N frees (the old `Cons` cells die on the
descent) and N allocations (the new `Cons` cells are born on the unwind), for a list
that never changed length. FBIP — *functional but in-place* — threads the just-dropped
cell straight into the same-size allocation, so the spine is rewritten in place and the
allocation count collapses toward zero, with the program's output bit-for-bit unchanged.
This slice delivers the runtime-conditional form (Koka's `drop_reuse` → `alloc_at`) for
the canonical single-path shapes `map` and `reverse`, gated at runtime by `rc == 1`.

---

## 1. Where we are (the substrate this rides on)

All merged to `main`:

- **Slab arena** (`runtime/wok_rc.{c,h}`): bump + arity-exact LIFO `freelist[arity]`,
  `arity ≥ 64` → direct `malloc`. `wok_alloc` / `wok_dec` (returns new rc, no free) /
  `wok_free` (pushes to the free list). FBIP **bypasses** the free list for a matched pair.
- **Layout compaction / the descriptor**: a cell is `8 + 8*arity` bytes — **size is a pure
  function of arity**, known statically. This is what lets `alloc_at` ask "does the shell fit?"
- **Immediates**: a nullary constructor is an inline `Addr (Inline Word32)` with no cell.
  Donors are always real cells; the arity-0 free list isn't polluted.
- **Perceus** (`src/Wok/IR/Perceus.hs`): inserts `__rc_dup` / `__rc_drop`. The reuse
  pairing is a focused **post-pass** over its output (it recognizes the emitted
  `__rc_drop`-at-a-`Case`-match pattern; the core pass is untouched — see §6).
- **The differential oracle**: every program runs on both backends — the abstract
  `IntMap` heap (`src/Wok/Interp/RC/Value.hs`) and the C arena — and the harness asserts
  output is bit-for-bit identical AND the alloc/free/peak stats match (1282 green).

FBIP adds **one** new layer on top; everything under it shipped already.

---

## 2. Scope

### In (S2)
- The two runtime operations `drop_reuse` and `alloc_at` on **both** backends, with shared
  stat accounting (§4, §5).
- A first-class **reuse token** value (§4.1) — required because `map` holds the token across
  the recursive call.
- The **pairing post-pass** for the single-path shapes (§6): a unique boxed cell dropped at a
  `Case` match, paired with a downstream constructor allocation of matching **slot-kind
  signature** (§6.3) that the alt dominates on a straight-line path.
- The **runtime `rc == 1` gate** (§7): reuse fires only when the dropped cell is actually
  unique; otherwise a fresh allocation, identical to today.
- Corpus + oracle assertions covering `map`, `reverse`, the shared-cell fallback, and the
  `Cons`-with-immediate-tail interaction (§10).

### Out (deferred, explicitly)
- **`filter`** and any **conditional reuse** (a branch that drops the cell *without*
  rebuilding) — needs a "drop the token for real" path on a *program* branch. (S3.)
- **Tree insert / rebalance** — multi-arity, cross-constructor reuse patterns.
- **Static rc-elision ("reuse specialization")** — proving `rc == 1` from the
  one-shot/multiplicity + escape analyses so the runtime check is elided. (Follow-on.)
- **Cross-arity reuse** — forbidden outright (§5.3): it would waste bytes and corrupt the
  arena's per-arity accounting on the later free.
- **Slot-kind-incompatible reuse** — refused statically (§6.3): a kind-changing `map`
  (`[Int] → [Char]`, `[Int] → [String]`) does not reuse and allocates fresh (conservative,
  correct). Strings stay non-encodable abstract literals (a string field forces the whole
  cell to the abstract heap); FBIP still reuses string-bearing cells *there* by index, just
  never via a C cell — so "set strings aside" costs FBIP nothing.
- **A reuse token spanning an effect operation** — refused statically (§6.2): the pairing
  scan stops at the first `ROp` on the alt's straight-line tail, so a token never crosses an
  effect op. **Residual (honest):** the refusal handles the *direct* `ROp` form, but a token
  can still in principle span an **effectful CALL** — an `RApp` to a function that *itself*
  performs an op — because the scan rides past an ordinary `RApp` (it must, to ride past the
  recursive `map`/`reverse` call). Under an *aborting* handler, dropping the captured
  continuation frees the token's **fields** (`continuationOwned` is total over `RReuseCon` —
  the fields are the owned moves) but **not the reserved shell** (the token has no finalizer
  in the M2b/M3 continuation-RC owned set), so the shell leaks. The S2 corpus is **effect-free**,
  so this is **unobservable** there. **Full effect-safety** — a Koka-style reuse-token
  finalizer wired into the continuation-RC owned set so an abort reclaims the reserved shell —
  is a **deferred follow-on**, not part of S2.

> Cross-*constructor* reuse (a `Cons` shell becoming a *different* 2-field constructor, even
> one with an identical slot-kind signature) is **NOT supported in S2** (review finding F1).
> The §6.3 backend-lockstep + descriptor-validity argument holds only for **same-constructor**
> reuse: the abstract heap has no descriptor and reuses unconditionally, but the C runtime
> decodes through a descriptor **keyed by constructor tag**, recorded first-write-wins. A
> cross-constructor target whose tag was first C-allocated at a *different* slot-kind
> instantiation would re-stamp under a **stale tag-keyed descriptor** (silent mis-decode) AND
> diverge from the abstract heap. So the pairing requires the target constructor to **equal**
> the matched constructor (in addition to the slot-kind-signature match). `map`/`reverse`
> (Cons→Cons) are same-constructor, so the corpus is unaffected. Cross-constructor reuse
> cannot be made sound within the value-only-`nodeCEligible` design.

---

## 3. The deliverable and the oracle invariant

**Two distinct comparisons; keep them straight.**

1. **The oracle invariant (correctness, both backends FBIP-instrumented).** For every corpus
   program, the abstract heap and the C arena produce byte-identical output AND identical
   alloc/free/peak counts. A reuse pair that fires nets to **0 alloc / 0 free on both**; a
   pair that does not fire nets identically on both. This is the existing oracle, extended.

2. **The win (alloc-count collapse, FBIP vs non-FBIP).** The SAME program, run with the FBIP
   pairing vs without it, produces identical output but the FBIP run records strictly fewer
   allocator events — ~0 net for a `map`/`reverse` spine instead of 2N. This is the
   measurable, deterministic, oracle-visible deliverable.

**No interpreter wall-clock claim.** A C-level microbench may report a real per-op time
number (as prior slices did), but the interpreter's deliverable is the count, not the clock.

---

## 4. The runtime mechanism

### 4.1 The reuse token

A token is a one-use ticket produced by `drop_reuse` and consumed by `alloc_at`. It is a new
`RCValue` variant in `Wok.Interp.RC.Value`:

```haskell
data RCValue
  = ...
  | RVReuse (Maybe ReuseSlot)     -- NEW: an affine in-place-reuse ticket

data ReuseSlot = ReuseSlot
  { rsAddr      :: Addr     -- the reserved shell (HAddr index or CAddr pointer)
  , rsArity     :: Word32   -- the shell's physical arity (= byte size)
  , rsCEligible :: Bool     -- whether the OLD node was C-heap-eligible (see §4.3)
  }
```

- `RVReuse Nothing` = **NULL** (the cell was shared, nothing to reuse).
- `RVReuse (Just slot)` = a reserved shell of the recorded arity.

The token is **affine**: produced once, consumed once. `valueChildren (RVReuse _) = []` — the
reserved shell is NOT a counted child (its children were already released at `drop_reuse`; it
is owned solely by the token until `alloc_at` either revives it or frees it). `incref`/`drop`
never touch a token; and because the token is introduced by the post-pass *after* Perceus has
run, no pass ever `dup`s or `drop`s it — affinity is structural (§6.4).

### 4.2 `drop_reuse` — release children, retain the shell

The interpreter-monad operation (the counted analogue of the last step of `dropAddr`):

```haskell
dropReuse :: Addr -> Store -> RC (RCValue {- RVReuse -}, Store)
```

Behaviour by address kind:

- **`Inline` / static `HAddr`**: never a donor → `(RVReuse Nothing, s)` (decrement is a no-op
  on uncounted addresses, exactly as today).
- **dynamic `HAddr i`**: deref.
  - `rc > 1`: decrement in place (no `recordFree`), return `(RVReuse Nothing, s')`.
  - `rc == 1` (unique): let `arity = length vs` (the `NCon`'s field count); compute
    `kids = cascadeChildren node`; compute `elig = nodeCEligible node` (§4.3); **remove `i`
    from `stCells`** but do NOT add it to `stDead` and do NOT `recordFree`; then drop every
    child via the existing worklist (`dropAddr`); return
    `(RVReuse (Just (ReuseSlot (HAddr i) (fromIntegral arity) elig)), s'')`.

**Why the reserved shell is safe while the token is held across a call.** On the abstract
heap, `allocPure` hands out fresh indices from the monotonic `stNext` and never re-issues a
removed index; on the C arena the shell is not on the free list (no `wokFree`). So while a
`map` holds N tokens at the bottom of its recursion, no intervening allocation can collide
with a reserved shell — only the one `alloc_at` consuming that token ever writes to it.
- **`CAddr p`**: `wokDec p`.
  - new rc `≠ 0`: `(RVReuse Nothing, s)`.
  - new rc `== 0`: decode children (`readCConValues`), compute `elig = True` (a live `CAddr`
    was C-eligible by construction), read `arity` (`wokArity p`); do NOT `wokFree`, do NOT
    `bumpFreeStats`; drop the children via the worklist; return
    `(RVReuse (Just (ReuseSlot (CAddr p) arity True)), s')`.

**Ordering** (the M2b/M3 discipline, §7): collect children → reserve the shell (remove from
`stCells` / skip `wokFree`) → process the children. The shell is held by the token; its bytes
stay intact until `alloc_at`.

**Accounting caveat.** A reserved shell is still counted in `stLive` (no `recordFree`) but is
absent from `stCells` until `alloc_at` revives it, so `stLive` transiently exceeds the
abstract live-cell-map size. Both backends do this identically (the oracle compares the
counters, not the map size); any `stLive == size stCells` invariant only holds at quiescent
points (no token in flight), so the implementation must not assert it mid-run.

### 4.3 `alloc_at` — reuse the shell if placement matches, else free + fresh

```haskell
allocAt :: RCValue {- RVReuse -} -> Node -> Store -> RC (Addr, Store)
```

The crux is keeping the abstract and C backends in lockstep. A C cell can only hold encodable
fields; if the new node crosses the C-eligible/abstract boundary relative to the old shell, the
shell cannot be reused. The decision must therefore be made from **backend-independent data**
(arity + the eligibility bit), so both runs decide identically even though their physical
addresses and actions differ.

Define the pure, **value-only** predicate (the encodability half of `allocNCon`):

```haskell
-- Are this node's fields all encodable, at the right arity? (arity ≤ 255 && every field
-- encodable). A function of the node's VALUES only — no descriptor, no tag table — so it is
-- identical on both backends.
nodeCEligible :: Node -> Bool
```

It deliberately OMITS `allocNCon`'s descriptor-mismatch and `tag < 65536` checks: those
depend on store state that differs between backends (the descriptor table is populated only
under `CHeap`), and the §6.3 slot-kind guard already guarantees that at a *paired* site the
old and new nodes share a slot-kind signature — so no descriptor mismatch can arise there, and
the tag bound is unreachable. Restricting `nodeCEligible` to the value-only check is what keeps
the two backends' reuse decisions identical; the only residual runtime difference it must
capture is integer width within `KLitInt` (a small int encodes, a `≥ 2^63` natural does not).

`allocAt token newNode s`:

- `RVReuse Nothing` → `alloc newNode s` (the existing chokepoint: routes to C / abstract /
  inline as today; `recordAlloc` bumps normally). This is the shared-cell / NULL path.
- `RVReuse (Just (ReuseSlot a ar oldElig))`:
  - **reuse-eligible** iff `nodeArity newNode == ar && nodeCEligible newNode == oldElig`.
    Both backends compute this from the same (value-only) data → identical decision. When
    reusing, the action is taken **at `rsAddr`** — re-stamp if `CAddr`, index-write if
    `HAddr` — regardless of the eligibility *bit* (the bit gates reuse-vs-free; `rsAddr`
    carries the physical home).
    - **reuse**: write the new node into the reserved shell, NO `recordAlloc`:
      - `HAddr i`: `stCells := insert i (Cell 1 newNode)`; `stNext` untouched.
      - `CAddr p`: `wok_alloc_at(h, p, tag, arity)` re-stamps the header (rc 1, new tag,
        same arity) and the slots are written via `wok_slot_set` — exactly the existing
        `allocNCon` C path minus the `wok_alloc` and minus `recordAlloc`.
    - return `(a, s')`.
  - **not eligible** (arity or eligibility-class differs): **free the reserved shell for
    real** (`HAddr i` → add `i` to `stDead` + `recordFree`; `CAddr p` → `wokFree p` +
    `bumpFreeStats`), then `alloc newNode s` fresh. Net: 1 free + 1 alloc on both backends.

> **The S2 corpus DOES exercise the "not eligible" branch** via `fbip-intwidth-flip`
> (the T5 corpus file): a `map` whose function turns an encodable int into a `≥ 2^63` natural
> flips eligibility, so a non-NULL token frees its reserved shell and allocates fresh instead
> of reusing. The output is unchanged and the abstract and C backends stay in lockstep
> (abstract == C, counts identical), so the branch is covered by the differential oracle — not
> just by a unit test. (`map (+1)` / `reverse` keep the field-kind class stable, so those
> headline shapes always reuse on the clean 0/0 path; the int-width flip is the corpus member
> that walks the free-and-fresh path.) See §11-finding.

### 4.4 Stat accounting (the oracle crux)

Per matched (drop_reuse, alloc_at) pair, the recorded deltas:

| runtime case | abstract heap | C arena | allocs | frees |
|---|---|---|---|---|
| unique + reuse-eligible | write at `i`, skip `stDead`/`recordFree` then `recordAlloc` | re-stamp `p`, skip free list / `allocs` | **0** | **0** |
| unique + NOT eligible | free `i` for real, fresh alloc | `wokFree p`, fresh alloc | +1 | +1 |
| shared (`rc > 1`) | decrement; fresh alloc | `wokDec`; fresh alloc | +1 | 0 |

The shared and not-eligible rows are **identical to non-FBIP** (a shared drop frees nothing;
a fresh alloc costs one). Only the first row is the win, and it is **0/0 on both backends in
lockstep**. The `peak` (high-water live count) does not rise on a fired pair: the cell stays
live (reserved → revived). The new C counter `wok_stat_reused_inplace` is additive
observability for the microbench (mirrors `wok_stat_reused`), not consumed by the oracle.

---

## 5. The IR changes (`Wok.IR.Anf`, `Wok.IR.PrimNames`)

Three additions; the elaborator never emits them — only the Perceus pass does.

### 5.1 `RReuseCon` — the `alloc_at` allocation form

```haskell
data Rhs
  = ...
  | RReuseCon Atom Text [Atom]   -- NEW: alloc_at(token) Con field...
```

`RReuseCon tok con fields` is `RCon con fields` that consumes a reuse token `tok` (an `AVar`
naming a token binder). Updates required:

- `freeVarsRhs (RReuseCon tok _ as) = Set.unions (atomVars tok : map atomVars as)`.
- `rhsMaxU`, `prettyModule` (pretty-print as e.g. `Con@tok(...)`).
- The machine eval site (§9).

`coveredRhs` / `balanceLint` need NO case: the pairing is a post-pass that runs *after*
`insertRC` and the lint, so those passes never see an `RReuseCon` (§6).

> Rationale for a new `Rhs` rather than overloading `RCon`: `RCon` is produced everywhere by
> the elaborator and threaded through every pass; a dedicated form keeps the existing path
> untouched and makes the reuse site syntactically obvious. `alloc_at` cannot be a prim (a
> primitive takes `[RCValue]`; the constructor *tag* is not a value).

### 5.2 `__rc_drop_reuse` — the `drop_reuse` intrinsic

A new recognized intrinsic, emitted exactly the way `__rc_drop` is, but returning the token
instead of unit:

- `Wok.IR.PrimNames`: `rcDropReuseName = "__rc_drop_reuse"` (+ a key if `__rc_drop` uses an
  `APrim (module, name)` key; mirror whatever `__rc_drop` does).
- `Wok.Interp.RC.Prim`: an `RCPrim` whose `rpFn [v] s = do (tok, s') <- dropReuse (addrOf v) s
  ; pure (PRDone tok, s')`.
- `let tok = __rc_drop_reuse parent` replaces `let _ = __rc_drop parent` at a paired site.

### 5.3 `RVReuse` (value) and the arity invariant

Already specified in §4.1. The **size-exactness** rule: reuse fires only when
`nodeArity newNode == rsArity` (a runtime defensive check). Since a wok cell is `8 + 8*arity`
bytes, arity-exact *is* byte-exact. The stronger **slot-kind-signature** match (arity *and*
per-field storage class) is enforced statically by the §6.3 pairing guard, so a runtime arity
mismatch should never occur — if one did it would be an internal pairing error.

---

## 6. The pairing post-pass (the meat)

### 6.1 A separate pass, run after `insertRC`

The pairing is a focused post-pass — `reusePairing :: CoreModule -> CoreModule` — run
immediately *after* `insertRC` (and after `balanceLint`). It recognizes the pattern the core
pass already emits and rewrites it locally; `ownExpr` / `balanceLint` are untouched. Three
reasons this beats threading the analysis into `ownExpr`:

- **Auditable + non-invasive.** A self-contained pattern rewrite over instrumented IR; the
  gold-standard reference pass keeps its existing shape and tests. (This is the chosen
  structure precisely because the interpreter is the gold standard until dogfooding.)
- **Balance-preserving by construction.** It does not change *which* values are consumed (the
  parent is still consumed; the token is produced and consumed within the rewritten fragment),
  so `balanceLint` validates the pre-FBIP IR unchanged and the rewrite cannot unbalance it.
- **Naturally scoped to S2.** It only fires on a straight-line alt; a branchy `filter` alt is
  simply not matched (deferred to S3) with no special-casing.

### 6.2 The pattern and the rewrite

`insertRC`'s `ownAlt`/`dropParentThen` emit, inside an `AltCon c bs body` of a `Case` on
scrutinee `p`, the shape `… dup kept … ; let _ = __rc_drop p ; <body> ` — the parent-drop is
present only when `p` is the owned boxed scrutinee dead at the match. The post-pass fires when,
in such an alt:

1. **the parent drop is present** — `let _ = __rc_drop p` where `p` is the `Case` scrutinee;
   the matched cell's arity is `N = length bs` and its per-field slot kinds come from the
   binder types `bs`;
2. **a target exists** — the first `let r = RCon c' fields` reachable on the alt's
   straight-line tail (a chain of `Let`s ending in `Ret` / tail `Jump` / tail `RApp`, NOT
   crossing a nested `Case` / `LetJoin` / `RLam` / `ROp` / `Handle`) that is **same-constructor**
   (`c' == c`, the matched constructor) **AND** whose **slot-kind signature matches the matched
   cell's** (§6.3). The same-constructor requirement (review finding F1) is load-bearing for
   soundness, not a simplification — see §6.3.

The straight-line scan **refuses to span an `ROp` (an effect operation)** as well as an
`RLam` / nested `Case` / `LetJoin` (review finding). An `ROp` captures the continuation — the
suspended tail, which would hold the still-unconsumed reuse token (an `RReuseCon`), is handed
to the handler; the reserved shell has **no finalizer** wired into the M2b/M3 continuation-RC
owned set, so a token spanning an effect op under an *aborting* handler would leak its reserved
shell (§2 Out, §6 residual). S2 forbids the token from spanning an effect op outright, so the
scan stops at the first `ROp` and the pair is never formed. (The S2 corpus is effect-free, so
the headline `map`/`reverse` shapes never reach this refusal.) Handler-arm bodies
(`hReturn`/`hOps`) are **intentionally not traversed in S2** — handler arms are M2-effect
territory, outside S2's `map`/`reverse` scope; a reusable pair missed inside an arm is a
forgone optimization, never wrong behavior. So the pass descends into the *handled* expression
of a `Handle` but stops at its arms.

When both hold, rewrite: `let _ = __rc_drop p` → `let tok = __rc_drop_reuse p` (fresh `tok`,
from a `Unique` supply seeded above the whole module), and the target `let r = RCon c' fields`
→ `let r = RReuseCon tok c' fields`. Otherwise the alt is left unchanged.

The target rule is deliberately simple (cf. the "match heuristic kept simple" decision):
the **first same-constructor, slot-kind-compatible `RCon` on the straight-line tail**. `map`
and `reverse` each have exactly one (Cons→Cons), so the rule is unambiguous for the corpus;
multiple candidates → take the first, leave the rest fresh (correct; a later slice can be
cleverer).

### 6.3 Slot-kind compatibility — the correctness guard (the review finding)

This is the guard the first draft missed. The C runtime decodes a cell's slots through a
descriptor **keyed by constructor tag**, recorded first-write-wins. Re-stamping a
`Cons`-of-`Int` C cell (descriptor `[KLitInt, KPointer]`) with a `Char` payload would decode
the `Char`'s codepoint as an `Int` on readback — **silent wrong output under the C backend**
(and a backend divergence the oracle would flag). So a reuse pair is admitted only when the
matched and target constructors have **identical slot-kind signatures**, computed statically
from field types:

| field type | storage class |
|---|---|
| `Int` / `U64` | `KLitInt` |
| `Char` | `KLitChar` |
| `()` | `KLitUnit` |
| any boxed / encodable-pointer type | `KPointer` |
| `String` / bignum-typed (non-encodable) | `NonEncodable` (cell lives on the abstract heap) |

Reuse-compatible iff same arity AND equal storage class at every position. This is the KB's
rule — *"size-class fit is the compiler's responsibility, trusted by the runtime."* `map (+1)`
(`Int→Int`) and `reverse` (`a→a`) satisfy it trivially; a kind-changing map (`Int→Char`,
`Int→String`) does not, so it is not paired (fresh alloc, correct). With this guard, the old
and new nodes at any paired site share a signature, so the tag-keyed descriptor stays valid on
a C re-stamp AND both backends place old/new on the same heap — which is exactly what licenses
the value-only `nodeCEligible` (§4.3). The only residual runtime difference is integer width
within `KLitInt`, which the eligibility bit + free-fallback handle.

**Same-constructor is also required (review finding F1).** The slot-kind-signature match is
*necessary but not sufficient*. The C descriptor is keyed by constructor *tag*, recorded
first-write-wins; a *cross*-constructor target whose tag was first C-allocated at a different
slot-kind instantiation would re-stamp under a **stale tag-keyed descriptor** (the same silent
mis-decode the signature guard is meant to prevent, just reached through the *target* tag
instead of the *matched* tag). Worse, the abstract heap has no descriptor and reuses
unconditionally, so a cross-constructor re-stamp would also **diverge between backends**. So
the pairing additionally requires `c' == c` (target constructor == matched constructor).
Cross-constructor reuse cannot be made sound within the value-only-`nodeCEligible` design and
is therefore *not* admitted in S2 — `map`/`reverse` are Cons→Cons, so the corpus is unaffected.

### 6.4 The token is trivially affine

Because the post-pass *introduces* `tok` (it is absent from the `insertRC` output), no existing
pass ever `dup`s or `drop`s it: Perceus ran before the token existed, and the post-pass emits
exactly one producer (`__rc_drop_reuse`) and one consumer (`RReuseCon`) on the single
straight-line path. Affinity is structural — no `ctxReuse` set, no `balanceLint` change. The
two new IR forms are inert to the analyses, which all run earlier.

### 6.5 Why it is sound

The post-pass fires only where `insertRC` already placed `let _ = __rc_drop p` — i.e. where
the `Case` rule proved `p` dead at the match (NOT reused in an alt, NOT captured by a join).
That is exactly the condition under which this drop is `p`'s last reference. The runtime
`rc == 1` gate then re-checks uniqueness dynamically: a shared sublist yields a NULL token and
`alloc_at` allocates fresh. **Correctness never depends on the pairing being right about
uniqueness** — a wrong guess costs an allocation, never a wrong answer.

`map f (Cons x xx) = Cons (f x) (map f xx)` after the post-pass (ANF, schematic):

```
Case xs of
  Cons x xx ->
    dup x ; dup xx                          -- kept children (from insertRC, unchanged)
    let tok = __rc_drop_reuse xs            -- was: let _ = __rc_drop xs   (p = xs, arity 2)
    let y   = f x
    let ys  = map f xx                      -- tok rides the pending continuation across the call
    let r   = RReuseCon tok "Cons" [y, ys]  -- was: let r = RCon "Cons" [y, ys]
    r
```

`reverse` (`rev acc (Cons x xx) = rev (Cons x acc) xx`) has its target `RCon` in tail position
before the recursive call, so the token is born and consumed without crossing a call (the
simplest shape; peak drops to one churning cell).

---

## 7. Children ordering, immediates, edge cases

- **Children cascade.** `drop_reuse` runs the existing cascade (`cascadeChildren` →
  `dropAddr` worklist) on the dying cell's counted children *before* retaining the shell —
  the M2b/M3 "collect children → reclaim shell → process children" discipline, minus the
  shell free. In `map`/`reverse` the kept children were `dup`'d at the match, so the cascade
  decrements them back to their pre-`dup` count (they survive); only genuinely-dead children
  reach 0 and free normally.
- **A child that *is* the cell**: impossible — wok forbids cycles, and a cell is never its
  own child.
- **A borrowed / static / immediate child**: already filtered by `countedRefs` / `isUncounted`
  — `drop_reuse` decrements only counted children, unchanged from `dropAddr`.
- **Immediates.** A nullary drop is a no-op with no block, so an immediate is never a donor
  (`drop_reuse (Inline _) = RVReuse Nothing`). `Cons x Nil` reusing its `Cons` shell leaves
  the inline `Nil` slot untouched; the new tail overwrites it. Cell-to-cell only.

---

## 8. Uniqueness: runtime gate (MVP) vs static (deferred)

**MVP = runtime gate.** `drop_reuse` returns a real token only when its decrement hits 0. A
shared cell yields NULL and `alloc_at` falls back. No static proof is required; the analyses
(one-shot/multiplicity, escape) are NOT a dependency of S2.

**Deferred = static specialization.** When those analyses prove `rc == 1` at a site, a later
slice can elide the runtime check and emit an unconditional in-place rewrite ("reuse
specialization"). Out of scope here; noted so the IR shapes do not foreclose it (they do not —
an unconditional `alloc_at` is just `RVReuse (Just …)` known statically).

---

## 9. The machine (execution sites, `Wok.Interp.RC.Machine`)

- **`RReuseCon tok con fields`** (new arm in `evalRhsRC`, beside `RCon` at ~204): resolve
  `tok` to its `RVReuse`, resolve `fields` to values, call `allocAt tokenVal (NCon con vs) s`.
- **`__rc_drop_reuse`** dispatches through the existing prim path (`callFn` → `enterPrim` →
  `rcPrimTable`), returning `PRDone (RVReuse …)` — no new machine plumbing beyond the prim
  table entry.
- `matchAltsRC` (case dispatch, ~572) is **unchanged**: the scrutinee deref + child binding is
  the same; reuse only changes the alt's instrumented body.

---

## 10. Testing and the differential oracle

### 10.1 Oracle assertions (extend the existing harness)
1. **Backend parity (unchanged contract).** For every corpus program, abstract output ==
   C output, AND `allocs/frees/live/peak` identical.
2. **Reuse fires.** For `map`/`reverse` over a unique list, assert the FBIP run records
   **~0 net spine allocations** (allocs/frees for the spine collapse to 0), and the output
   equals the non-FBIP run's output bit-for-bit.
3. **Shared-cell fallback.** A program that shares a sublist (so a `Cons` has `rc > 1`) must
   record fresh allocations for the shared cells (no reuse), output unchanged.

### 10.2 Corpus (`test/rc-c-backend/fbip-*.wok`, wired into the differential oracle)
- `map (+1)` over a literal list of small ints (the headline: 0 net spine allocs).
- `reverse` via accumulator (token consumed immediately; peak drops).
- a shared-sublist program (`rc > 1`, fallback to fresh — no reuse).
- `Cons` with an immediate `Nil` tail (immediate interaction).
- an **integer-width flip** — a `map` whose result crosses `≥ 2^63`, so an encodable input
  cell becomes a non-encodable output — exercises the §4.3 not-eligible free+fresh branch;
  output unchanged, counts still abstract == C.
- a **slot-kind-changing** `map` (e.g. `Int → Char`) — asserts the §6.3 guard refuses to
  pair, so it allocates fresh (no reuse), output unchanged. This is the regression test for
  the descriptor mis-decode the guard prevents.
- (optional) `reverse` over a list of **strings** — confirms FBIP reuse works on the abstract
  heap for non-encodable cells (both backends `HAddr`, both reuse, 0/0).

### 10.3 Fault injection (Suite C "oracle has teeth", `insertRCMutated` style)
There is **one fault injection** (wrong-arity), not two. The shared-cell / `rc == 1`-gate
dimension is covered by ordinary tests, not a separate fault, so the two were reconciled:
- **Wrong-arity (the actual fault injection)** — `badArityReuse` rewrites the first
  `RReuseCon tok c fields` to drop its last field, so the reused node's arity is one below the
  token's reserved-shell arity → caught by `allocAt`'s arity guard (`wok_alloc_at`'s always-on
  arity-mismatch abort on the C backend) or output divergence. This is the only mutation.
- **The shared-cell / `rc == 1`-gate dimension is NOT a fault injection** — it is covered by
  T1's `drop_reuse` on a shared cell yielding `RVReuse Nothing` (the unit test) and by the
  `fbip-shared` corpus file (a program that shares a sublist provably does **not** reuse: the
  `rc > 1` drop returns a NULL token and `alloc_at` allocates fresh, output unchanged,
  abstract == C). A shared cell never reaches the reuse path, so there is nothing to *inject*
  there; the `stDead` double-free tripwire / UAF net remains the runtime backstop if it ever
  did.

---

## 11. What this slice unlocks / sequencing

Sequencing (unchanged from the compaction/immediates specs):
**compaction → immediates → FBIP (this slice) → escape/region allocation → reuse
specialization (static rc-elision) → monomorphization.**

This slice establishes the token, the two operations, the pairing hook, and the dual-heap
accounting. S3 (filter / conditional reuse) reuses all of it and adds only the "drop the token
on a non-rebuilding branch" path. Reuse specialization reuses the token machinery and removes
the runtime check where the analyses can prove uniqueness.

### §11-finding — the review findings (what the spec review surfaced)

Two refinements over the first draft, both folded into §4.3 and §6.3:

1. **Slot-kind compatibility is a correctness guard, not an optimization (§6.3).** Cells are
   decoded through a tag-keyed descriptor, so reusing a `Cons`-of-`Int` C cell for a
   `Cons`-of-`Char` would mis-decode the payload — silent wrong output under the C backend.
   The pairing therefore admits only reuse pairs with identical static slot-kind signatures.
   This also keeps both backends placing old/new on the same heap, which is what lets
   `nodeCEligible` be a value-only predicate without diverging.
2. **The residual runtime flip is integer width, not strings (§4.3).** With the slot-kind
   guard, the only way a non-NULL token can fail to reuse is an `Int`/`U64` field crossing
   `≥ 2^63` (encodable → non-encodable within the same `KLitInt` slot). The eligibility bit +
   free-fallback handle it, accounted identically on both heaps. Strings are not a dynamic
   concern: a string field is a non-encodable literal that keeps its cell on the abstract
   heap, where FBIP reuse still works by index; the slot-kind guard refuses to pair across the
   string boundary. (Future Array-like `String` is a separate track.)

The HTML companion's "S2 is single-path, token always consumed" stays accurate: the token
always reaches an `alloc_at`; that `alloc_at` occasionally frees-and-allocates instead of
reusing. The corpus is chosen so the headline (`map (+1)` / `reverse`) hits only the clean
0/0 path; the fallback and the kind-change refusal are unit-tested for correctness on all
inputs.

---

## 12. Worked example — one `map` step, refcount by refcount

`map f (Cons x rest)`, the `Cons` cell unique (`rc 1`); `k`, `m` are the children's entry counts.

| # | what runs | Cons | x | rest |
|---|---|---|---|---|
| 1 | match `Cons x rest` (read slots) | 1 | k | m |
| 2 | `dup x ; dup rest` (alt keeps both) | 1 | k+1 | m+1 |
| 3 | `drop_reuse(Cons)`: 1→0 unique; release child refs; keep shell as token | token | k | m |
| 4 | `rest' = map f rest` (token rides the continuation) | held | k | m−1 |
| 5 | `y = f x` (consumes the kept `x`) | held | k−1 | · |
| 6 | `alloc_at(token, Cons, y, rest')` (reuse the shell) | 1 | · | · |
| 7 | return — same block, new contents | 1 | · | · |

The cell enters at rc 1 and leaves at rc 1, never freed, never allocated. The `dup` (+1) and
the `drop_reuse` child-release (−1) cancel for `x` and `rest`: ownership just moves from the
cell's slots into `f x` and the recursive call. Had the cell been shared at step 3, the token
would be NULL and step 6 would allocate fresh — same answer, one real alloc.

---

## 13. Task decomposition (for writing-plans)

1. **Runtime — abstract heap.** `RVReuse`/`ReuseSlot`, `nodeCEligible`, `dropReuse`,
   `allocAt`; store-algebra unit tests (reuse, shared fallback, not-eligible fallback).
2. **Runtime — C arena.** `wok_alloc_at` (re-stamp in place, no stat bump), the
   `drop_reuse`/`alloc_at` CAddr paths in `Value`, the additive `wok_stat_reused_inplace`
   counter; standalone C test + UAF check under `WOK_RC_MALLOC`.
3. **IR.** `RReuseCon` + `__rc_drop_reuse` (Anf `Rhs`, PrimNames, `freeVarsRhs`, `rhsMaxU`,
   `prettyModule`); the RC prim-table entry; the machine `RReuseCon` arm. (No `coveredRhs` /
   `balanceLint` case — the post-pass runs after them.)
4. **Pairing post-pass.** `reusePairing :: CoreModule -> CoreModule` run after `insertRC`:
   recognize the (`__rc_drop` of a `Case`-matched scrutinee, dominated straight-line
   slot-kind-compatible `RCon`) pattern; the static slot-kind-signature check; rewrite to
   `__rc_drop_reuse` + `RReuseCon`; a fresh-`Unique` supply seeded above the module. No change
   to `ownExpr` / `balanceLint` (balance-preserving by construction).
5. **Corpus + oracle.** `test/rc-c-backend/fbip-*.wok`, the reuse-fires / fallback /
   eligibility assertions, the Suite C fault injection (wrong-arity).
6. **Docs.** Update the KB (`runtime-knowledge-base.md` FBIP entry → IMPLEMENTED), the spec
   status, and a short README note; keep `docs/fbip-reuse.html` as the companion.
