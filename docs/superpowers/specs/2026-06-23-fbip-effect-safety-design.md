# FBIP effect-safety (E+ lazy reclaim) — design

**Status:** IMPLEMENTED on `feat/fbip-reuse-s2` (1322 green, ASan clean; pending review/merge)
**Date:** 2026-06-23
**Track:** RC runtime / FBIP. Closes the one open residual from the FBIP S2 slice (`feat/fbip-reuse-s2`).
**Visual companion:** `docs/fbip-effect-safety.html`.
**Builds on:** `docs/superpowers/specs/2026-06-23-fbip-reuse-design.md` (FBIP S2) — read its §4 (the token, `drop_reuse`/`alloc_at`), §6 (the post-pass + its `Handle`/`ROp` refusals).

---

## Terminology — what "abort" means here

**"Abort" is NOT program termination, a crash, or a runtime panic.** It is a normal, mid-run,
in-the-language control-flow event: an **effect handler deciding not to resume** a continuation
it captured at an operation, so that captured continuation is **discarded** (e.g. an exception
handler that catches and returns a default, an early-return / short-circuit effect, a `find`
that stops at the first hit, a backtracking choice that prunes a branch). The program keeps
running normally afterwards. The complementary case is **resume** — the handler calls the
continuation and execution proceeds. A genuine program-level error/termination is explicitly
NOT in scope: there the whole heap is torn down at exit, so a stranded shell is moot. E+ matters
precisely because after a (recoverable) abort the program *continues*, so an unreclaimed
reservation would accumulate across repeated aborts.

---

## 0. Thesis

An FBIP reuse token reserves a dying cell's shell at `drop_reuse` and re-stamps it at a paired
`alloc_at`. In pure code the `alloc_at` always runs. But if the token's lifetime spans an
**effectful call** whose operation captures the continuation, and the handler **aborts** (drops
the continuation instead of resuming), the pending `alloc_at` never runs and the reserved shell
is orphaned → **a leak**. (The companion crash — the continuation-drop analysis erroring on
`RReuseCon` — is already fixed; this design closes the leak.) The fix, **E+ (lazy reclaim)**:
do nothing at capture; on **resume** the reservation is reused in place untouched; on **abort**
the runtime reclaims the in-flight reservations trapped in the discarded continuation,
piggybacking on the walk it already does to free the continuation's owned set.

---

## 1. Where we are

From the FBIP S2 slice (merged-pending on `feat/fbip-reuse-s2`):

- A reuse token is `RVReuse (Maybe ReuseSlot)`. `drop_reuse` on a unique cell **reserves** its
  shell off-books: an `HAddr` is removed from `stCells` but NOT added to `stDead` and NOT
  `recordFree`d; a `CAddr` is `wok_dec`'d to 0 but NOT freed. `alloc_at` revives it (re-stamp,
  reuse) or — if not slot-eligible — frees it and allocs fresh.
- The token is uncounted (`valueChildren (RVReuse _) = []`).
- The pairing post-pass refuses to span a `Handle` and an `ROp` (so a token never spans a
  *bare* effect op). It does NOT block an `RApp` to a function that performs an op internally —
  an **effectful call** — which is where the residual lives.
- Already fixed (the crash): the runtime continuation-drop analysis (`Escape.escapingAtomsRhs`,
  reached via `continuationOwned`) is total over `RReuseCon` (treats its fields like a plain
  `RCon`, ignores the affine token). So abort no longer crashes — it just leaks the shell.

**The load-bearing invariant (§5 of the companion).** Because the pairing never spans a
`Handle` (or `ROp`), a reservation never crosses a handler boundary: its `drop_reuse` and its
`alloc_at` always sit inside the same handler region. **Consequence:** the only way a
reservation can become unreachable-from-the-live-program is a **continuation abort**. So
reclaiming at abort is both necessary and sufficient.

---

## 2. Scope

### In (E+)
- A `Store` field `stReserved` tracking the currently in-flight reservation addresses.
- `drop_reuse` inserts into it; `alloc_at` removes (on both the reuse and the not-eligible-free
  consume paths).
- A `continuationReservations` collector + a `freeReservation` special-free.
- The `NCont` drop (abort) reclaims the in-flight reservations trapped in its prefix.
- Resume and the pairing are UNCHANGED.
- Tests: an effectful map under an **aborting** handler (the leak regression) and under a
  **resuming** handler (proves reuse survives a resume), plus a collector unit test, all on the
  differential oracle.

### Out (deferred, explicitly)
- **B (counted reserved cell)** — the RC-uniform version (reservation = a counted `NReserved`
  cell freed by the existing `continuationOwned`). Cleaner in principle but touches the core
  value model + the C descriptor cascade. Kept on the shelf; E+ does not foreclose it.
- **Relaxing the `ROp` refusal.** With E+ making abort safe, the pairing *could* be allowed to
  span a bare `ROp` (reuse across an effect op, reclaimed on abort). That is a pure-win
  follow-on but a scope expansion (more reuse, more test surface); this slice keeps the refusal.
- **Effect-gated pairing (C)** — the static alternative; not pursued.

---

## 3. The mechanism

### 3.1 The in-flight set
```haskell
-- in Store
, stReserved :: Set Addr   -- addresses currently reserved by a live (in-flight) token
```
- `dropReuse` (the `rc == 1` reserve path, both `HAddr` and `CAddr`): after reserving the
  shell, `stReserved := Set.insert rsAddr stReserved`.
- `allocAt`, on **consuming** a `Just` token — BOTH the reuse re-stamp AND the not-eligible
  free+fresh branch: `stReserved := Set.delete rsAddr stReserved`.

So `stReserved` holds exactly the reservations whose `alloc_at` has not yet run. A spent token's
value may linger in an environment, but its address is no longer in `stReserved` — which is what
keeps the collector from freeing a revived (live) or already-freed cell.

### 3.2 The collector
```haskell
-- the reserved-shell addresses still in flight inside a captured continuation prefix.
-- Sibling of 'continuationOwned'; walks the same frames.
continuationReservations :: RCKont -> Set Addr -> [Addr]
```
Walk the prefix frames (`KLetRC`/`KHandleRC` carry an `RCScope`; `KAppRC` carries values);
collect every `RVReuse (Just (ReuseSlot a _ _))` whose `a ∈ stReserved`; dedup by address.
The `stReserved` membership test is the in-flight filter (excludes spent tokens lingering in the
env). This is a value-directed scan of the runtime envs — simpler than `continuationOwned`'s
body analysis. It is a **separate** walk over the same prefix frames — NOT fused with the
`continuationOwned` walk: on abort the runtime walks the prefix once via
`reclaimIfNCont`→`continuationReservations`, then again via
`dropAddrStepPure`→`cascadeChildren`→`continuationOwned`. The extra pass costs nothing in
practice because abort is rare (it runs ONLY on abort).

### 3.3 The special-free
```haskell
freeReservation :: Addr -> Store -> RC Store
```
- `HAddr i`: the shell is off-books (absent from `stCells`). `stDead := IS.insert i`,
  `stStats := recordFree`, `stReserved := Set.delete (HAddr i)`. (Defensive: if `i ∈ stDead`
  already, that is an internal double-reclaim — fail loud.)
- `CAddr p`: `wok_free p` (its rc is 0 from `drop_reuse`; the `rc==0` guard passes; NO cascade —
  the children were released at `drop_reuse`), `recordFree`, `stReserved := Set.delete (CAddr p)`.

### 3.4 The abort path
When an `NCont` cell is freed (rc reaches 0 — the abort/discard path), in addition to cascading
its owned set (`continuationOwned`, unchanged), the runtime `foldM`s `freeReservation` over
`continuationReservations prefix stReserved`. These are TWO separate walks of the same prefix
frames on the abort path (the reservation reclaim, then the owned-set cascade), not a single
fused pass; the duplicate walk is negligible because abort is rare. Because `freeReservation` on
a `CAddr` needs IO (`wok_free`), this lives in the IO `dropAddr` loop's `NCont` handling, not the
pure step.

### 3.5 Resume — unchanged
`moveOutCont` (resume) splices the prefix back onto the live continuation. The reservations ride
along in `stReserved`, untouched; the spliced `alloc_at`s find their shells and reuse them in
place (removing from `stReserved` as they consume). No change to `moveOutCont`. This is why
**reuse survives a resume** — the performance parity with B.

---

## 4. Why it is sound

- **Necessity + sufficiency of the abort site (§1 invariant).** A reservation never crosses a
  handler boundary, so it can only be orphaned by a continuation abort. Reclaiming there closes
  every leak; nothing else can leak a reservation.
- **The two free sites are mutually exclusive.** A reserved shell is freed by exactly one of:
  (a) `alloc_at` consuming it (the live path — resume or pure), or (b) the abort reclaim (the
  continuation is discarded, so its `alloc_at` never runs). A continuation either runs its
  `alloc_at` (resume) or is dropped (abort) — never both. So no double-free, no leak.
- **The `stReserved` filter prevents freeing a non-reserved cell.** A spent token (consumed, or
  not-eligible-freed) is removed from `stReserved` at `alloc_at`, so the collector skips it even
  though its `RVReuse (Just …)` value lingers in the env. Without this filter, freeing a
  consumed token's now-live shell would corrupt the heap.
- **Nesting is handled.** `continuationReservations` scans only THIS prefix; an outer
  continuation's reservation is in `stReserved` but not in this prefix's scan, so it is not
  freed here. Each abort reclaims exactly its own continuation's in-flight reservations.
- **One-shot.** A continuation resumes at most once (wok's one-shot law). So a reservation is
  consumed by at most one spliced `alloc_at`; restoring/reusing it across two resumes (which
  would re-stamp a live cell) cannot arise. B has the identical constraint.

---

## 5. Stat accounting (the oracle)

`stReserved` is backend-agnostic (it tracks addresses, not heap contents) and both backends
evolve it identically (the same reservations fire — rc and values are identical across
backends). On abort, both backends reclaim the same `continuationReservations` set and
`recordFree` the same count. So the differential oracle's output AND alloc/free/peak stats stay
bit-for-bit identical. Per cell over its life: 1 alloc (birth) + 1 free (either `alloc_at`'s
not-eligible branch, the reuse never frees, or the abort reclaim) — balanced. The leak is closed,
so `stLive == baseline` holds for effectful-abort programs (it did not before), and the C
arena's `wok_heap_free` no longer warns.

---

## 6. Files

- `src/Wok/Interp/RC/Value.hs`: the `stReserved` field (+ `emptyStore` init); the
  `stReserved` updates inside `dropReuse` / `allocAt`; `continuationReservations`;
  `freeReservation`; the `NCont`-drop reclaim wiring in the IO `dropAddr` loop.
- `src/Wok/Interp/RC/Machine.hs`: only if the `NCont`-drop reclaim is more naturally hooked at
  the dispatch/abort site — prefer keeping it in `dropAddr` (Value.hs). No pairing change.
- `test/Spec.hs`: the collector unit test; the effectful-map abort (leak regression) + resume
  (reuse-survives) differential tests.
- `test/rc-c-backend/`: the effectful-map corpus `.wok` files IF an effectful map under a
  handler is expressible in the RC-covered fragment end-to-end; else hand-built `CoreModule` +
  `NCont` unit tests for the reclaim (see §7 risk).
- Docs: update the FBIP S2 spec §2/§6 + the KB to mark the residual CLOSED; update
  `docs/fbip-effect-safety.html`'s "no global set" claim (E+ has the small `stReserved` set).

---

## 7. Testing

1. **Collector unit test.** Hand-build an `RCKont` prefix whose frame scopes hold an in-flight
   `RVReuse (Just slot)` (address ∈ a constructed `stReserved`) AND a spent one (address ∉
   `stReserved`); assert `continuationReservations` returns exactly the in-flight address,
   deduped.
2. **Abort = no leak (the regression).** An effectful map under an **aborting** handler:
   `map f` where `f` is a separate function that performs an op (so `f x` is an effectful
   `RApp`, not a bare `ROp` — the `ROp` refusal would block a bare op), run under a handler that
   drops the continuation. Assert: no crash; `stLive` returns to baseline (no leak); abstract
   stats == C stats. This FAILS before E+ (leak) and passes after.
3. **Resume = reuse survives.** The same effectful map under a **resuming** handler. Assert:
   reuse still fires (spine alloc count collapses as in the pure case), output correct, abstract
   == C. This proves E+ keeps reuse across a resume.
4. **Differential oracle.** Both corpus programs run on both backends with the standard
   output + stats parity.

**Risk (must de-risk first, like FBIP T5).** Verify an effectful map under a handler actually
reaches the RC interpreter's covered fragment AND that the pairing fires on its `Cons` rebuild
(the `f x` effectful `RApp` must be a `continue`-past in `findTarget`, which it is — only `ROp`
and `RLam` stop it). If the elaborator/coverage does not admit this shape end-to-end, fall back
to: the collector unit test (1) + a hand-built `NCont`-drop reclaim test that constructs a
continuation holding an in-flight reservation and asserts the drop reclaims it (no leak). Report
which path was taken.

---

## 8. What E+ does NOT do (and the follow-ons it enables)

- It does NOT make reuse survive a continuation **abort** (correctly — the continuation is gone;
  the shell is reclaimed). It DOES make reuse survive a **resume** (the performance goal).
- It does NOT relax the `ROp` refusal. With E+ in place that becomes a safe, pure-win follow-on
  (reuse across a bare effect op, reclaimed on abort) — noted, not done here.
- It does NOT adopt B's RC-uniform model. If the single abort special-case ever feels like a
  wart, B is the documented refactor (at the cost of the C-heap reserved marker).

---

## 9. Task decomposition (for writing-plans)

1. **`stReserved` + the hot-path updates.** Add the `Store` field; insert in `dropReuse`;
   delete in `allocAt` (both consume branches); store-algebra unit tests that the set tracks
   in-flight reservations across reserve/consume/not-eligible.
2. **`continuationReservations` + `freeReservation` + the abort reclaim.** The collector
   (fused with / sibling of `continuationOwned`), the special-free, and the `NCont`-drop wiring
   in `dropAddr`; the collector unit test.
3. **End-to-end effect-safety tests.** The abort (leak regression) + resume (reuse-survives)
   corpus on the differential oracle, with the §7 de-risk first; fall back to hand-built if the
   fragment doesn't admit the shape.
4. **Docs.** Mark the residual CLOSED in the FBIP S2 spec + KB; correct the HTML's set claim.
