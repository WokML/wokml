# Async effect surface + CPS continuation logic (structured concurrency, runtime-deferred)

Status: **Design spec**, 2026-06-11. Defines the async / structured-concurrency
**surface language** and the pluggable-runtime **interface**, and scopes the
implementable work to the **CPS continuation logic** (which the coroutine
machinery already provides) plus a **deterministic, library-level driver** so the
surface type-checks AND runs on today's interpreter. NO real scheduler, NO IO, NO
parallelism, NO foreign executor in this slice.

Builds on:
- `2026-06-11-resume-site-control-and-heap-continuations-design.md` (the
  direction: resume-site semantics, trusted mechanism + pluggable executor,
  stackless CPS + Perceus).
- The coroutine CPS machinery: `Coro a b`, `Suspension`/`Step (row e)`,
  `start`/`step`/`run`/`cancel`, `__coro_*` trusted prims, the existing
  `coro-multi-driver` example (drives several coroutines at once).
- Invariants: effect handlers are the one control mechanism; handlers are
  second-class; one-shot is the law; nondeterminism enters only via foreign effects in the row (no synthetic marker -- see �7).

---

## 0. Scope

**DETERMINED here (surface + interface — specified even if not all built):**
- The `Async` effect and its operation set.
- Structured combinators `par` (wait-both) and `race` (first-wins) -- both neutral; no determinism marker (�7).
- The cancellation model (cooperative, transparent / `finally`-based).
- The pluggable-runtime **interface** (opaque-token / waker contract) that a
  future `foreign` executor implements.

**SHIPPED this slice (implemented + tested on the current interpreter):**
- `Async` with the cooperative operation `yield`.
- `par` as a **library function** over the coro CPS machinery (following the
  existing multi-driver pattern), with a fixed deterministic interleave schedule.
- Deterministic golden tests: typecheck + run.

**DEFERRED (named, not built):**
- `finally` / cleanup-on-cancel — deferred until resources exist. (`race`'s
  cooperative cancellation ships now as pure-drop, no keyword — slice async-race;
  there is simply nothing to clean up yet.)
- Dynamic `scope`/`spawn`/`await`/`Promise` — needs an N-child driver.
- Real runtime (IO, timers, parallelism) via a `foreign` executor — needs FFI;
  its interface is specified here so it slots in without surface changes.
- Interceptable cancellation (a `Cancelled`/`Abort` effect).
- Tier-2 user-written handler runtimes (would need first-class carriers).

The dividing principle: **carriers never escape, and never appear in *application*
code.** End-user code passes children as thunks and reads results; the *library
drivers* hold continuations as **second-class arguments** (passed down, never stored
or returned — which the carrier rule already permits, `future-arg-ok.wok`), and a
future foreign runtime holds them behind the opaque-token boundary (§6). This keeps
the whole surface inside the affine system already shipped.

---

## 1. Architecture (two layers, recap)

```
   MECHANISM (already shipped, trusted)   continuation capture / resume / drop
                                          = the coro CPS machinery
        ▲ carriers stay below this line (second-class)
   DRIVERS (this spec)                    Async effect + par/race, written as
                                          library drivers directly over the
                                          mechanism (synchronous, deterministic)
        ▲ opaque-token / waker contract (specified, §6) — FOREIGN runtimes only
   RUNTIME (future)                       a real scheduler: IO, timers, parallelism,
                                          pluggable `foreign` executors. NOT this
                                          slice (par/race above are drivers, not
                                          this layer).
```

`par`/`race` are **built-in drivers** (handlers) over `Async`, driving the coro
mechanism synchronously and deterministically — they are *not* the future runtime
layer (no IO, no scheduler, no tokens). Children only ever see `Async`; their
non-Async residual `e` propagates to the combinator's call site (resume-site
semantics). A foreign runtime (§6) plugs in later via the token boundary without
changing these drivers or the surface.

---

## 2. The `Async` effect (surface)

```
effect Async = {
  yield : () -> ()          -- cooperative suspension point
}
```

- `Async.yield : () -> () with Async`. Each `Async` op is a **breakpoint** (§4.1):
  a park point where the driver may interleave, capture the continuation, or — at
  the next resume — cancel (§4.2). **The effect row is the breakpoint map** — a
  function without `Async` is an uncancellable, non-yielding atom.
- DEFERRED operations (specified, not in slice 1):
  - `await : Promise a -> a with Async` — suspend until a one-shot `Promise` is
    fulfilled (needs `Promise` + a runtime that fulfils it).
  - `spawn : (() -> a with Async + e) -> Promise a with Async` — dynamic child
    (needs an N-child scope driver).

Only `yield` ships in slice 1; it is sufficient to demonstrate and test
interleaving with no IO.

---

## 3. Structured combinators (surface + types)

### `par` — deterministic, ships this slice

```
par : (() -> a with Async + e)
   -> (() -> b with Async + e)
   -> (a, b) with e
```

- Runs both children, interleaving them at their `yield` points under a **fixed**
  schedule (left-biased round-robin — see §10), and returns both results.
- **Discharges `Async`** (par is its driver) → `Async` is not in par's result row.
- **Deterministic**: fixed schedule + fixed effect order, fully reproducible (no determinism marker needed -- �7).
- Residual `e` (children's other effects) propagates to the par call site
  (resume-site: those effects resolve where par is invoked).

### `race` — neutral combinator, SHIPPED (slice async-race)

```
race : (() -> r with Async + eff e)
    -> (() -> r with Async + eff e)
    -> r with eff e
```

- First child to complete wins; the loser is **dropped** — its carrier simply goes
  unused, so its remaining tail never runs (cooperative cancellation, §4.3). The
  Slice-2 **spike confirmed the affine analysis accepts the drop (0 uses)**, so this
  is pure control-flow — **no keyword, no explicit `cancel` call** needed. (`finally`
  on drop arrives with resources/Perceus; nothing to clean up yet.)
- **Discharges `Async`** (and `Coro`); propagates the children's residual `e`. A
  plain combinator, exactly like `par` — **no extra marker in the row**.
- **On a tie** (both children complete the same lockstep round) the **left** child
  wins — a fixed, deterministic rule. Correctness comes from `runRace` handling
  every `Step` combination (`Completed`/`Suspended` × both sides) exhaustively; no
  tagging or choice effect is needed.
- **No `Nondet` / determinism marker** — see §7 for why. Earlier drafts added a
  `Nondet` effect + a `runDet` resolver; both were removed as scaffolding for an
  enforceable-determinism story that cannot exist.

### `scope` / `spawn` — dynamic nursery, DEFERRED

Dynamic-arity structured spawn. Needs an N-child driver holding N carriers; still
carrier-free at the surface (children are thunks, results are `Promise`s). Later
slice.

---

## 4. Breakpoints and cancellation (logic)

The cancellation *logic* is specified in full here; it *ships* with `race`
(Slice 2). `par` (Slice 1) never cancels (no loser), so it exercises breakpoints
for interleaving only.

### 4.1 Breakpoints

A **breakpoint** is an `Async` operation site (`yield`, later `await`) — the point
where a task **parks** and hands control back to its driver. Three things coincide
there:

- the driver may **interleave** (run another task),
- the continuation is **captured** (the CPS suspend point, §5),
- and, on the *next* resume, the driver may decide to **cancel** instead of
  continuing (§4.2).

`yield` itself is pure "park and return to the driver" — it carries no cancellation
logic. **The effect row is the breakpoint map**: a function whose row contains
`Async` parks (is schedulable and cancellable); a function whose row lacks `Async`
is an **atom** that runs start-to-finish, never interleaves, and cannot be
cancelled mid-execution. Readable from the type, no annotations.

```
   [ chunk0 ]──yield──►(parked)──resume?──►[ chunk1 ]──yield──►(parked)──...──►done
                          ▲                    ▲
                          control is with      driver decides HERE (§4.2):
                          the driver           resume → run chunk1, or
                                               cancel → drop (§4.3)
```

### 4.2 Cancellation is observed at *resume*, not at yield

Cancellation is **cooperative**, and the check belongs at **resume**, driver-side —
not at the yield. The reason is structural: execution is single-threaded, so a task
holds control throughout each chunk; nothing else runs to *request* a cancel until
the task parks. So at the moment a task yields, no cancel can exist yet — it arrives
*while the task is parked*, from whoever runs next. The earliest (and only) place to
**observe** it is when the driver goes to resume the task:

```
   taskA: [chunk0]──yield──►(parked).............resume? ──►[chunk1]
                              ▲                     ▲
   taskB runs, requests       no cancel exists      driver checks the flag HERE:
   cancel of A                at yield-time         cancelled → skip chunk1, drop A
```

Consequences:

- **`yield` stays pure** — all cancellation lives in the driver's resume decision.
- **No wasted work** — the driver decides *before* entering the next chunk, so a
  cancelled task never runs another chunk.
- **The first chunk is inherently uncancellable** — nothing could have requested its
  cancel yet. Not a special rule; a consequence of resume-checking.
- **Atomic windows** — straight-line code between two breakpoints runs to the next
  breakpoint uninterrupted (it contains no `Async` op). Preemptive models (async
  exceptions, `Thread.stop`) cannot promise this — which is why wok is cooperative.
- **Latency** — a task is reachable by cancel only at its next breakpoint; a tight
  compute loop with no `Async` op is uncancellable until it finishes (add an
  explicit `Async.yield` checkpoint if responsiveness is needed).

### 4.3 Mechanism: cancellation is an inferred drop, not an explicit op

To cancel, the driver simply **stops resuming** the parked carrier. The carrier
then goes dead, the compiler **infers the drop** by liveness (CFG dataflow —
Perceus inserts it), and the drop runs the continuation's captured `finally`:

```
   driver decides cancel ──► does NOT resume the carrier
                             carrier goes dead on this path
                             compiler-inferred DROP (liveness / Perceus)
                             drop runs the captured `finally` blocks
                               (from the breakpoint up to the scope)
                             child's remaining logic NEVER runs
```

The work splits cleanly: the **compiler** infers *where* to drop (liveness); the
**runtime** knows *what* to run on drop (the finalizers captured in the continuation
— the `finally` blocks dynamically in scope at the breakpoint).

There is **no `discontinue` operation** in the committed design — cancellation is
the *absence* of a resume plus the inferred drop. (`discontinue` — actively
re-entering the continuation to raise a cancel *into* it — is needed only for the
deferred interceptable mode, §4.5.)

Near-term reality: there are **no resource types and no `finally` surface yet**, so
there is nothing to clean up — cancellation today is simply the carrier being
dropped (the existing discard). Finalize-on-drop arrives with the Perceus runtime +
`finally` + resources, **under the same driver code**: the driver still just drops,
and the runtime gains finalize-on-drop beneath it. So a `race` written now needs no
change later.

### 4.4 Affine accounting

Transparent cancellation is a **drop = zero consuming uses**, which the shipped
affine analysis already permits (the bound is `≤1`, and `0 ≤ 1`). So a `race` driver
that resumes the winner and drops the loser type-checks under the system already on
`main` — **no new analysis**, and cancellation is *not* a "second consuming use".

(The explicit `cancel`/`__coro_cancel` op still exists as an *eager, explicit*
discard and counts as one consuming use, so resume-then-explicit-cancel is still
rejected as a double-consume — `future-resume-then-cancel.wok`. But cancellation
does not *require* it; the driver expresses cancel as a drop.)

With a future **resource** type, the affine bound on a resource-owning carrier
upgrades to **linear**: dropping it must run its cleanup (finalize-on-drop) rather
than being a silent no-op — the roadmap's no-drop obligation. Until resource types
exist, affine + plain drop suffices.

### 4.5 Observability — transparent (default) vs interceptable (deferred)

- **Transparent (default, this design):** the cancelled child cannot observe the
  cancel; the driver drops its carrier and (future) its `finally` runs. Expressed
  entirely by inferred drop (§4.3) — no re-entry, no cancellation reason.
- **Interceptable (deferred):** cancellation is delivered *into* the child as a
  catchable `Cancelled`/`Abort` effect (custom teardown, or a bounded
  non-cancellable section). This is the genuine `discontinue` — actively re-entering
  the continuation with a reason — which inferred drop cannot express. Deferred; the
  only thing that would reintroduce an explicit `discontinue`.

### 4.6 In the combinators

- `par`: deterministic, runs both to completion — **no cancellation** (no loser).
- `race`: runs both; once one completes, the driver **stops resuming the other** (a
  drop, §4.3) and returns the winner. The loser's `finally` runs on drop (future).
  No explicit cancel/discontinue call.
- `scope` exit / `timeout`: drop all still-running children (deferred slices).

---

## 5. The CPS continuation logic (what "ship" means here)

The continuation mechanism already exists; this slice *uses* it, it does not build
a new engine.

- A child `c : () -> a with Async + e` is run as a coroutine by **adapting
  `Async.yield` to `Coro.suspend`** (a small handler), then driven with
  `start`/`step`. Each adapted `yield` is a breakpoint (§4.1) — the suspend *is*
  the continuation-capture point, so scheduling, cancellation, and capture are the
  same event.
- Cancellation (Slice 2) needs no special op (§4.3): the driver cancels a child by
  simply **not recursing with its carrier**. The carrier goes dead, the
  compiler-inferred drop reclaims it, and (future runtime) the drop runs its
  `finally`. Dropping is affine-legal (0 uses ≤ 1, §4.4) — no new analysis.
- `par` is a **recursive driver** that holds the two children's coro carriers as
  **function arguments** (second-class, passed down — never stored in a data
  structure), resuming them alternately and recursing with the fresh carriers each
  `step` returns. This is the `coro-multi-driver` pattern specialised to two
  children with result combination.
- One-shot holds: each carrier is consumed once per `step` and the driver recurses
  with the successor carrier — no double-consume, no escape.
- **No new interpreter primitives, no first-class carriers.** If the affine
  analysis cannot express the two-carrier recursive driver as a library function
  (the spike, §9 Task 1), the fallback is a single trusted `__par` primitive in
  the interpreter (like `__coro_*`); the surface and types are unchanged either
  way.

---

## 6. The pluggable-runtime interface (DETERMINED; future foreign executors)

Specified now so a real runtime slots in later without changing the surface. NOT
implemented this slice (no FFI yet).

- The built-in driver is **one** implementation of an interface; a `foreign`
  executor (`extern "lib" "sym"`) is another.
- **Opaque-token / waker contract**: the mechanism issues an opaque **generational
  token** (slot index + generation) for each parked task. An executor stores
  tokens and calls `wake(token)`. The mechanism validates on redemption — slot
  live? generation matches? not already woken/cancelled? — and resumes **once**,
  bumping the generation. A misbehaving executor (double-wake, stale-wake,
  post-cancel-wake) is rejected at the boundary.
- **Safety stays on our side**: one-shot, no-resume-after-cancel, and memory
  safety are enforced at redemption, never delegated across the boundary. The
  executor is ceded **policy** (scheduling, IO, timing), not **safety**.
- The foreign executor declares its effect (`... with IO`/`Foreign`), which the
  row tracks (trusted-by-declaration); `foreign` is privileged/gated.

---

## 7. Determinism is NOT a tracked property (and why)

There is **no `Nondet` marker** and no determinism guarantee in the type system.
This is deliberate. The reasoning (the design converged here after trying a
`Nondet` effect, then a per-source `nondet` tag, and rejecting both):

- **Determinism cannot be enforced.** The only source of nondeterminism is the
  **foreign boundary** (a real clock, a real scheduler, a real RNG). Foreign code
  is *trusted, not verified* — you declare its effects and hope. So any
  "row lacks the marker ⇒ deterministic" promise rests on unverifiable honesty.
  Claiming a guarantee you can't keep is itself a leaky abstraction.
- **It taxes users for nothing.** A `Nondet` marker forces extra row entries,
  handling obligations, and a `runDet` to thread — all to back a hollow promise.
- **Nondeterminism is a property of the *handler*, not the effect interface.** The
  same effect (`Clock`, a scheduler) is deterministic under a mock/pure handler and
  nondeterministic under a foreign one. Tagging the *interface* bakes an
  implementation assumption into the declaration.
- **Pure wok is deterministic by construction** — deterministic interpreter,
  one-shot law (no `amb`/backtracking), pure handlers are just functions. So in pure
  wok there is no nondeterminism to mark; `race` (lockstep, left-biased) is fully
  reproducible.

What we keep: the roadmap invariant "nondeterminism is visible in the row" still
holds — but realized by the thing that's actually honest and unavoidable, the
**foreign effect itself**. When a real scheduler/clock/RNG arrives (slice 4), it
appears in the row as its declared foreign effect (e.g. `IO`). The user reads the
row, sees the foreign/world-touching capability, and *infers* "this can vary"; the
compiler never over-promises. Effects (`Async`, a future `Clock`/`Random`/scheduler
capability) are **neutral capabilities**; determinism follows from *who resolves
them* — pure handler (reproducible) vs foreign handler (its nondeterminism is in
the row). No synthetic marker, no tag.

---

## 8. Testing (verifiable now)

- **typecheck-examples**: `par`/`yield` signatures; par discharges `Async` and
  no determinism marker; residual `e` propagates.
- **run-examples**: `par` of two `yield`-ing children → deterministic interleave
  → golden output; par returns both results.
- **typecheck-fail-examples**: `Async.yield` performed in an explicitly-typed pure
  function with no driver in scope → unhandled-effect. (Must be an annotated
  function, not `main` — `main` does not obligate its effect row, cf. 4b″.) Existing
  carrier/affine fixtures already guard escape/double-resume.
- The deterministic reference driver makes concurrent behaviour reproducible, so
  goldens are stable.

---

## 9. Phasing (slices)

- **Slice 1 (this):** `Async` (`yield`) + `par` (deterministic) as a library
  driver over coro + deterministic tests. Tasks: (0) branch/baseline; (1) SPIKE —
  express the two-carrier recursive driver as a library function over coro; if it
  fails the affine analysis, fall back to a trusted `__par` prim; (2) the `Async`
  effect + `par` signature + the Async→Coro adapter; (3) deterministic interleave
  schedule + golden examples; (4) full-branch review + finish.
- **Slice 2 (DONE):** `race` (neutral first-wins combinator) + cooperative cancellation (pure-drop, transparent). No Nondet marker (determinism not tracked, �7).
- **Slice 3:** dynamic `scope`/`spawn`/`await`/`Promise` (N-child driver).
- **Slice 4:** real runtime via a `foreign` executor over the §6 token interface
  (needs FFI).
- **Later:** interceptable cancellation; Tier-2 user handler runtimes (needs
  first-class carriers — gated).

---

## 10. Open questions / decisions to lock during planning

1. **`par`'s exact schedule.** Left-biased round-robin (step A to its next yield,
   then B, repeat) is the simplest reproducible choice; lock it and document it as
   the deterministic contract.
2. **`Async` vs `Coro`.** Recommend `Async` be its own surface effect that the
   drivers adapt to `Coro` — so `Async`/`Coro` stay distinct user concepts and the
   adapter is the only coupling.
3. **Library driver vs trusted `__par` prim.** Decided by the Slice 1 spike;
   library-first.
4. **`finally` surface syntax** (for the cancellation slice).
5. **`Promise` representation** (for the `await`/`spawn` slice) — a one-shot cell,
   carrier-discipline TBD.
6. **`par` arity** — strictly binary first; variadic / over a list later.
7. **Shared residual row.** `par`/`race` use one row `e` across both children
   (same `e` in both arrows). Row polymorphism widens each child to the union, but
   it forbids combining two children with *incompatible* residuals — acceptable, and
   the same shape as the `coro-step-zip` signature. Revisit with independent rows
   `e`/`f` only if a real need appears.

---

## 11. Deferred review findings (backlog from the Slice 1 `/code-review`)

The Slice 1 full + recall review confirmed the code correct (no Critical/Important
bugs). These five items are real but each needs work OUTSIDE this library-only
slice; recorded here rather than bolted onto the merge.

1. **Misleading diagnostic on mismatched residual rows (compiler change).** When
   two `par` children have *incompatible* residual effects (both handled), the
   error is a positionless `UnknownField "<row>" "Foo"` from the row machinery,
   not a `RowMismatch` with a source span. Pre-existing in row unification, merely
   surfaced by `par`. Fixing it is a type-checker diagnostic change affecting all
   row mismatches — its own slice + full-branch review. **Best candidate for the
   next diagnostics slice.**
2. **No privacy for internal helpers (language feature).** `parBoth`/`drainOne`/
   `asCoro` leak as public `Std.Control` symbols; wok has no export/private
   mechanism anywhere. Can't be fixed without designing module privacy — a
   language feature, deferred.
3. **Driver is unit-monomorphic (`Step () () r`) (YAGNI generalization).**
   `parBoth`/`drainOne` never inspect the yielded value but fix `a = b = ()`.
   Generalizing to `Step a b r` needs a resume-value strategy with zero current
   consumers; the spec already defers value-yielding `par`. Leave specialized.
4. **`Async`/`par` could be `Std.Async` (premature module split).** Std.Control
   now mixes mtl effects, the coroutine primitive, and the async driver. Worth a
   boundary once more drivers land (`parAll`/`select`/`race`); premature now (one
   driver). Defer.
5. **Stateful inline handler over `par` flagged multishot (analysis nuance).** An
   inline `with self = H { acc = … ; op n k -> k (…) () }` wrapping `par` trips the
   one-shot analysis as `multishot resume`, while the prelude `writer` combinator
   (same shape) does not. The determinism-order fixture (`par-order`) uses `writer`
   as the workaround. Whether this is a genuine conservative false-positive on
   inline stateful handlers composed with `par`, or expected, needs investigation.
