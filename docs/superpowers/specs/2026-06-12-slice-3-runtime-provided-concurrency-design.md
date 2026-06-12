# Slice 3: runtime-provided concurrency (the provider model)

Status: **Design spec**, 2026-06-12. Reframes "Slice 3" away from the original
"trusted-scheduler vs first-class-carrier" fork. The conclusion of the brainstorm:
**the carrier wall guards a much narrower thing than we treated it as.** Unstructured
concurrency (`spawn`/`Fiber`), result-bearing concurrency (`async`/`await`/`Promise`),
and channels are all reachable by *ceding scheduling to a provider* and routing
inter-task communication through **provider-validated id tokens and data-carrying channels** rather
than through reified wok continuations. First-class carriers are needed only for an
**in-wok scheduler** (a power / self-hosting feature), not for user-facing concurrency.

Builds on / supersedes parts of:
- `2026-06-11-async-effect-surface-and-cps-design.md` (the `Async`/`par`/`race` layer;
  the §6 opaque-token / waker interface; §7 "determinism is not tracked").
- `2026-06-11-resume-site-control-and-heap-continuations-design.md` (resume-site
  semantics; the first-class-carrier trio §5; the load-bearing row §3).
- The coroutine CPS machinery (`Coro`, `Suspension`/`Step`, `__coro_*` prims).

Invariants carried forward: effect handlers are the one control mechanism; handlers
are second-class; one-shot is the law; nondeterminism enters only via foreign effects
in the row (no synthetic marker).

---

## 1. The reframe: from a fork to a provider model

The original Slice 3 question was posed as a fork:

> dynamic `scope`/`spawn`/`await`/`Promise` needs **either** a trusted N-scheduler
> **or** first-class carriers.

The brainstorm dissolved it. The carrier wall (storage + affine-through-aliasing +
drop, resume-site §5) is entirely about **resuming a wok-visible carrier** — a
reified continuation stored in a wok data structure and re-entered. Two observations
remove that need for everything users actually want:

1. **Fire-and-forget `spawn` never brings a carrier back.** The running task's
   continuation lives inside the *provider* (behind an opaque token), never as a wok
   value. There is nothing to store-in-wok, nothing to resume-in-wok, nothing to
   alias. All three carrier guarantees become the provider's problem.

2. **Results come back as DATA through channels, not as resumed continuations.**
   `async`/`await` route the result value across a channel (a provider primitive);
   the awaiter blocks on `recv` (the provider parks *its* continuation, opaquely).
   Neither continuation is ever reified into a wok value.

So the real structure is not "trusted scheduler vs carriers" but **a single
provider-agnostic surface with three possible providers**:

```
   SURFACE (this spec)            Conc effect: spawn / async / await / channels
                                  data Fiber / Promise / Chan (provider-id wrappers)
        | one surface, three providers below
   ----------------------------------------------------------------------------
   PROVIDER A: interpreter prim   trusted Haskell scheduler over __coro_* .
   (this slice, runnable now)     DETERMINISTIC. carriers live in Haskell, never
                                  in wok. cost: a substantial trusted-core prim.
   PROVIDER B: foreign executor   real scheduler via `extern "lib" "sym"` over the
   (slice 4, FFI)                 §6 opaque-token / waker boundary. NONDETERMINISTIC
                                  (its nondeterminism rides task IO in the row).
   PROVIDER C: in-wok scheduler   reify continuations as wok values and schedule in
   (deferred power feature)       wok. THIS is the only path that needs first-class
                                  carriers + affine-through-aliasing. Self-hosting.
```

The type-system surface (§3) is **identical** across all three. Only the provider of
the scheduler differs. The original fork was really the choice of *provider*, and the
answer is "all three, layered" — ship A now, B at slice 4, C if/when self-hosting is
wanted.

---

## 2. The surface

The provider tokens must be **first-class** (storable, copyable, no consume-once rule) —
you only ever *reference* them, never resume them. The tempting choice, `extern type`,
is the *wrong* form: in the codebase it sets `tcCarrier = True` = second-class + affine
+ no-escape (`Infer.hs:899-900`, `Env.hs:48-51`), marking the tokens as carriers — the
opposite of what §3.2 needs. Rather than invent a non-carrier extern form, the tokens
are **ordinary `data` wrapping a provider id** — the §6 opaque-token (slot index +
generation) made concrete. They are then first-class for free, with **zero new
type-system machinery**:

```
data Fiber    = Fiber U64        -- id; the provider maps it to the running task
data Promise a = Promise U64       -- id of a one-shot result cell; `a` is PHANTOM
data Chan a    = Chan U64          -- id of a channel; `a` is PHANTOM (payload type)

-- the concurrency capability (neutral, §5). Its operations ARE the scheduler's
-- breakpoints: the provider may interleave at any Conc op. `yield` is the explicit
-- cooperative breakpoint for compute loops with no other Conc op.
effect Conc = {
  yield : () -> ()
}

-- PAYLOAD RESTRICTION (Slice 3 / Provider A): in every signature below, `a` ranges
-- over EFFECT-FREE, FIRST-ORDER DATA only (no function/thunk types, no closures with
-- a residual row). This is what keeps Provider A free of the load-bearing row (§3.3,
-- §3.4). The restriction lifts when the load-bearing residual row lands (Provider B).

-- fire-and-forget: run a self-contained task, get a handle. forkIO-shaped.
extern spawn  : (() -> () with Conc) -> Fiber with Conc

-- result-bearing: spawn + a one-shot cell the task fulfils.
extern async  : (() -> a  with Conc) -> Promise a with Conc

-- block until fulfilled; the value crosses as DATA, not a resumed carrier.
extern await  : Promise a -> a with Conc

-- channels carry data between tasks.
extern newChan : () -> Chan a with Conc
extern send    : Chan a -> a -> () with Conc
extern recv    : Chan a -> a with Conc

-- signal a task through the provider; Fiber is DATA, never re-entered. NOTE: this is
-- an EXPLICIT cancel op, which reverses async-spec §4.3's "cancellation is an inferred
-- drop, no explicit op." That is safe here precisely because the carrier is
-- provider-held: there is no wok-side affine carrier to double-consume (§10 T8).
extern cancel  : Fiber -> () with Conc
```

**Token representation.** Only the *types* are plain `data`; the operations stay
`extern` prims that build/read these `VCon`s. The `data` constructors are visible, so a
user could pattern-match `Fiber id` or forge `Fiber 999`. That is harmless: the
provider already **validates every token** (§6: slot live? generation matches? not
already woken/cancelled?) — a forged or stale id is rejected at the boundary, exactly
as required for untrusted foreign executors. What is lost is *encapsulation*, not
*safety*; wok has no module-privacy mechanism anywhere yet (async-spec §11.2), so this
costs nothing wok does not already lack, and it upgrades for free when privacy lands.
The phantom `a` on `Promise a`/`Chan a` gives full payload type-safety at the surface
(`async : (() -> a) -> Promise a`, `await : Promise a -> a` thread `a`); the runtime
representation is an erased id.

`Conc` is the analogue of `Async` from the prior slice, but it denotes
*provider-scheduled* concurrency rather than pure deterministic lockstep. The
`extern` prims are backed by the active provider (interpreter prim in this slice).
The scheduler interleaves tasks at `Conc` operations (`yield`, and the implicit park
points inside `await`/`recv`/`send`); a `Conc`-closed child that never performs a
`Conc` op is an uninterruptible atom, exactly as in async-spec §4.1.

**The signatures above are the CONTRACT, not the encoding.** Provider A realises
`spawn`/`async`/`await`/`send`/`recv`/`cancel` as wok *library functions* over a single
monomorphic transport operation `Conc.req : Request -> Transport` (the `effect Conc`
actually declares just `req`; `yield` and the rest desugar to it). `Transport` is a
plain-`data` envelope (`data Transport = Transport U64`) over one trusted
runtime-identity coercion (`__coerce : a -> b`, fenced behind `erase`/`recall`) that
recovers the polymorphic result type of `await`/`recv`. This keeps the whole surface
inside the existing type system with **no new type-system machinery** (no extern carrier,
no `opaque` keyword) and sidesteps the unsupported effectful-constructor-field case by
*erasing* the spawned thunk rather than storing it as a typed field. The unit/handle is
named `Fiber` (a lightweight cooperatively-scheduled computation, NOT an OS thread). Full
encoding in the implementation plan `2026-06-12-slice-3-conc-provider.md`.

`async`/`await` are *not* separate machinery — they are the canonical channel pattern:

```
async f  ==  let p = newPromise in spawn (fn () -> fulfil p (f ())) ; p
await p  ==  block until p fulfilled, return its value     -- = recv on a 1-shot cell
```

(shown as prims for the provider to implement efficiently; the equivalence is the
semantics, not necessarily the implementation).

---

## 3. The type-system rules (the heart)

These are the only rules that matter, and the claim is that **the deterministic slice
needs no new type-system machinery; the IO-bearing case needs one piece already on the
roadmap.**

### 3.1 `spawn` pins the child to the ambient row (no user-effect laundering)

A spawned task runs *later, elsewhere*, under the **provider's** dynamic context, not
the spawner's. By resume-site semantics, the task's effects resolve at its run site.
The provider supplies handlers only for **ambient** effects (the foreign row: IO,
timers, etc. — empty pre-FFI). A *user* effect (`State`, a custom effect) handled by a
second-class handler in the spawner's scope is **gone** by the time the task runs.

Therefore `spawn`'s child must be **effect-closed up to the ambient row**:

```
   child residual  ⊆  Ambient            (Ambient = the provider's foreign row)
```

- **Pre-FFI (Provider A):** `Ambient = {}`. The child is `() -> () with Conc`
  (pure up to `Conc`, which it carries only to nest-spawn). A child performing `State`
  fails to unify against the closed `Conc` row → "unhandled effect", forcing the user
  to wrap it (`fn () -> with State 0 {..} body`). This is enforced by **`spawn`'s
  signature** (a closed child row), resolved by today's strict unifier — it is
  *signature design*, not a new analysis, but it is also not "the unifier does it for
  free": the closed row is a deliberate obligation. Crucially it guards **only
  `spawn`'s direct argument** — channel/promise payloads are a *separate* ingress and
  are handled by the payload restriction (§3.3), not by this pin.
- **Post-FFI (Provider B):** to let a child do IO, `Ambient ⊇ IO`. Expressing
  "residual ⊆ Ambient" while *rejecting* user effects is exactly the **load-bearing
  residual row** (resume-site §3): performing a residual must obligate, and ambient
  effects discharge trivially (always in scope) while user effects do not. This is a
  *special case* of §3, far smaller than first-class carriers, but it is **not free** —
  it is the one piece the general (IO-bearing) `spawn` inherits from the deferred work.

This corrects an overclaim made during design ("zero new type-system machinery"): true
for the deterministic slice, not for IO-bearing children.

### 3.2 Tokens are ordinary data, not carriers

`Fiber`, `Promise a`, `Chan a` are values you only **reference** (name them to
`cancel`/`await`/`send`/`recv` *through the provider*); you never *re-enter* them.
Affine/one-shot discipline governs things you resume; it does not govern data you merely
reference. Representing them as plain `data` wrapping a provider id (§2) makes them
first-class — copyable, storable, no carrier rule — with **no new type-system
machinery**. (Contrast `Suspension`, which you *do* resume, is `extern type`, and
therefore stays a `tcCarrier` second-class carrier. The distinction is now structural:
carriers hold a continuation and are `extern`-marked; tokens hold an id and are `data`.)

### 3.3 Channels carry effect-free data only (this slice); carriers cannot enter them

A `Suspension` (carrier) is **not** first-class — the existing carrier-escape rule
forbids storing it (`Carrier.hs`, `CarrierEscape`) — so it structurally cannot enter a
`Chan`/`Promise`. That part is free.

The subtler hole: a channel of **effectful thunks** (`Chan (() -> a with State)`) is
NOT free. Sending such a thunk and running it on the receiving side — where no `State`
handler exists — **launders the user effect**, defeating §3.1's pin (which guards only
`spawn`'s direct argument). Making this sound requires *running a received thunk to
obligate the runner's row with the thunk's residual* — exactly the **load-bearing
residual row** (resume-site §3) that Provider A is trying to avoid.

So Slice 3 takes the **payload restriction** (§2): `Chan a`/`Promise a` carry only
**effect-free, first-order data** — no function/thunk payloads. Under that restriction
no residual can ride a channel, and Provider A needs no load-bearing row. The
restriction lifts (function/thunk payloads become legal) precisely when the
load-bearing row lands (Provider B). This corrects the earlier "a channel of thunks is
fine" claim, which was false under `Ambient = {}`.

### 3.4 `await` is a value-recv, not a carrier-resume

`await : Promise a -> a` returns **data** (effect-free, first-order — §3.3). The
awaiter's own continuation is parked by the provider (opaque), exactly like any
blocking call; the producer's continuation lives in the provider. **No wok continuation
is reified.** This is why result-bearing concurrency does not need first-class
carriers — the result crosses the provider boundary as a value. Note the precise scope
of the guarantee: it is about the *continuation* (never reified), not about latent
effects in `a` — which is why `a` is restricted to effect-free data (§3.3); a closure
payload is not a carrier but can still carry a deferred user effect.

**Prim-trust obligation (runtime analogue of the forging check).** The phantom `a`
gives surface type-safety but **no runtime witness** — wok cannot itself bridge an
erased id back to a typed `a` (verified: a user `readAs : Promise a -> a` is rejected
with `RigidEscape`). So `await`/`recv` are sound only because the **provider** stores
and returns the correctly-typed value. The provider must therefore key each cell's
stored value to its `Promise`/`Chan`, so two handles of different `a` built from
colliding ids cannot cross-deliver. This is the value-side counterpart to the §6
id-forging validation: forging is caught at the boundary, and type-correct delivery is
guaranteed at the boundary — both are provider obligations, not wok-checkable.

---

## 4. Provider A: the trusted interpreter scheduler (what ships this slice)

A deterministic cooperative scheduler implemented in the interpreter (Haskell), over
the existing `__coro_*` capture:

- A run-queue of started coroutines (held in Haskell — no wok carrier escape).
- `Promise`/`Chan` cells (Haskell `IORef`-like, but inside the pure interpreter state).
- `spawn` adapts the child to a coroutine (the `asCoro` trick), enqueues it.
- `await`/`recv` park the caller (capture its `__coro_*` continuation into the queue,
  keyed by the cell); fulfilment re-enqueues it with the value.
- A **deterministic** termination policy (FIFO ready-queue; defined channel delivery
  order): root completion ends the program; still-parked fibers are dropped
  (daemonic, forkIO-style). A diverging loser/orphan cannot hang the program.

Properties:
- **Runnable now**, on today's interpreter, with no FFI.
- **Deterministic** → reproducible golden tests (same reasoning as `par`/`race`).
- Carriers are held in **Haskell**, never in wok values → **no first-class-carrier
  analysis** and **no carrier-escape relaxation** in wok.
- **Cost (stated honestly):** this is a substantial *trusted-core* expansion — a
  run-queue + channel cells + park/wake loop in the interpreter. It is the "large new
  trusted anchor" flagged when the trusted-scheduler horn was first raised. It is
  justified because (a) it is the same shape Provider B implements behind §6, so it
  prototypes that interface, and (b) it keeps the wok surface honest and provider-clean.

Provider A's determinism means it needs **no** `Ambient` beyond `{}` (§3.1) — children
are pure-up-to-`Conc`. So Provider A exercises only the zero-new-machinery path.

---

## 5. Determinism (reconciling with async-spec §7)

`Conc` is a **neutral capability**, like `Async`. Determinism follows from *who
resolves it*:

- **Under Provider A** (interpreter scheduler): a fixed schedule → fully deterministic
  and reproducible. `Conc` carries no IO; no determinism marker.
- **Under Provider B** (foreign executor): the scheduler is nondeterministic. Much
  observable nondeterminism rides the tasks' own foreign effects (IO is in the row).
  **But not all of it:** `send`/`recv` on a shared `Chan` make *value* outcomes
  schedule-dependent with **no IO in any row** (the channel cell is provider-internal,
  §4). So channel-order is an untracked nondeterminism source. This does not break §7
  — §7's stance is that determinism is *unenforceable and not tracked*, precisely
  because sources like this exist — but it does mean we do **not** claim "the row lacks
  IO ⇒ deterministic." `Conc` stays neutral; no synthetic marker; and determinism is
  simply not promised once channels are shared.

This is the §7 thesis instantiated and slightly sharpened: the effect is neutral,
nondeterminism is the provider's (and the channel topology's) property, never a tracked
guarantee. (Earlier draft claimed "pure-result tasks return the same value under any
schedule" — deleted: false once tasks share a channel.)

---

## 6. Structured concurrency is a library over the unstructured surface

With Provider A's `async`/`await`, the structured combinators become ordinary wok
library functions — no special prim:

```
parAll : List (() -> a with Conc) -> List a with Conc   -- a = effect-free data (§3.3)
parAll fs = map await (map async fs)          -- spawn each, then collect each

raceAny : List (() -> a with Conc) -> a with Conc   -- first promise to fulfil; cancel rest
```

This **relocates** (does not magically eliminate) the earlier "`parAll` needs a small
trusted prim" conclusion. Be honest about the bookkeeping: on the *pure-wok* spine,
`parAll` needed its own prim because N carriers forced a `List Carrier` escape and
`par`-folding failed the strict unifier (confirmed: a recursive `parAll` discharges
`Async`, and the rigid residual row cannot re-absorb it under the Leijen-2005 unifier,
which has no subsumption — `par-residual-mismatch.wok`). On the *provider* spine,
`parAll` is a library wrapper — **but only because Provider A's scheduler prim (§4)
already holds the carriers in Haskell.** The prim did not disappear; it moved *down* a
layer and *grew* (from a focused `__par` into a full run-queue + channels). So `parAll`
is "free" only if the scheduler is being built anyway for `spawn`/`async`/`await`. It
is — those are the slice's point — so adopting the provider spine is the right call;
but `parAll` alone would not justify the larger prim (the old focused `__par` would be
smaller). Recorded so the trade is visible, not hidden behind "no special prim."

The pure-wok deterministic `par`/`race` (already shipped, no `Conc`, no scheduler)
remain the **zero-dependency deterministic** layer for fixed-arity structured work.
They are not redundant with `parAll`: they need no scheduler and carry no `Conc`.

---

## 7. What ships in Slice 3 vs deferred

**SHIPPED this slice (Provider A):**
- `Conc` effect (with `yield`) + `Fiber`/`Promise a`/`Chan a` as plain `data` wrapping
  a provider id (§2, §3.2) — first-class, **no new type-system machinery**.
- `spawn`/`async`/`await`/`newChan`/`send`/`recv`/`cancel` as `extern` prims backed by
  a deterministic interpreter scheduler.
- The **payload restriction** (§3.3): `Chan a`/`Promise a`/`async`/`await` admit only
  effect-free, first-order `a`. Enforced as a well-formedness check on these signatures.
- `parAll`/`raceAny` as library functions (§6).
- The §3.1 pin enforced via `spawn`'s closed child row, `Ambient = {}` (children
  pure-up-to-`Conc`).
- Deterministic golden tests (§8).

**SPECIFIED, not built (Provider B, slice 4):**
- The same surface backed by a `foreign` executor over the §6 opaque-token / waker
  boundary; `Ambient ⊇ IO` (children may do IO); the §3.1 load-bearing-row piece.

**DEFERRED as a power feature (Provider C):**
- First-class carriers + affine-through-aliasing + drop discipline (resume-site §5),
  enabling an **in-wok** scheduler. Not required by any user-facing concurrency above.

---

## 8. Testing (Provider A, deterministic)

- **typecheck-examples:** `spawn` of a `Conc`-closed child typechecks; `async`/`await`
  round-trips a value; `parAll` discharges `Conc` and returns all results.
- **typecheck-fail-examples:** `spawn (fn () -> State.get ...)` with `State` unhandled
  in the child → unhandled-effect at the `spawn` site (the §3.1 pin). A `Suspension`
  placed in a `Chan` → carrier-escape (existing rule). A `Chan (() -> a with State)` or
  `async` returning an effectful/function `a` → payload-restriction violation (§3.3).
- **run-examples:** deterministic `async`/`await` value round-trip; `parAll` of N
  children that each call `Conc.yield` a few times → deterministic interleave → golden
  result list; a fire-and-forget `spawn` whose result is delivered on a `Chan` and
  observed before the root returns (§9.1).

---

## 9. Open questions / decisions to lock during planning

1. **Drain policy for fire-and-forget.** RESOLVED: root completion ends the
   program; still-parked fibers (race losers, un-awaited `spawn` orphans) are
   dropped, never resumed again (daemonic, forkIO-style). A diverging
   loser/orphan cannot hang the program. Considered alternatives —
   join-all-at-exit, explicit daemon flag, run-until-main-settles-then-drain-ready
   — all let a diverging orphan spin forever; cancellation here = stop resuming +
   drop the carrier, consistent with the race design.
2. **`Conc` vs `Async`.** Both now carry a `yield` breakpoint, so the overlap is
   direct. Are they one effect or two? `Async` (pure lockstep `par`/`race`, no provider)
   and `Conc` (provider-scheduled) have different power and different providers.
   Recommend keeping them distinct: `Async` = the pure deterministic layer, `Conc` = the
   provider layer; an adapter (`asCoro`-style) bridges if needed. Revisit if it grates.
3. **`Promise` one-shot discipline.** `await` twice on one `Promise`: error, or cached
   value? A cached one-shot cell (await-many, fulfil-once) is the ergonomic choice and
   needs no affine rule (the cell is data). Lock it.
4. **Ambient row representation (the §3.1 / load-bearing-row tie-in).** How is "the
   provider's foreign row" represented so that `residual ⊆ Ambient` rejects user
   effects but admits IO? This is the one piece Provider B inherits from resume-site §3;
   Provider A avoids it (`Ambient = {}`). Decide before slice 4 locks the surface.
5. **Trusted-core size.** Is Provider A's scheduler prim acceptable as a permanent
   trusted anchor, or only as a bridge until Provider B/C? (It can be retired once C
   lands, or kept as the deterministic provider for testing.)
6. **Phantom type parameter (§2).** Confirm wok accepts `data Promise a = Promise U64`
   (where `a` appears only on the left). Standard HM, but it is the single load-bearing
   assumption of the plain-data token representation — pin it with an early fixture.
7. **Payload restriction enforcement (§3.3).** Where does "`a` is effect-free
   first-order data" get checked — a well-formedness pass on the `extern` prim
   signatures, or a kind/constraint on the payload position? Define the check and its
   error. (Note: `Promise a`/`Chan a` themselves are first-class data, so they may be
   stored/passed freely; the restriction is only on what `a` ranges over.)

---

## 10. Tensions reconciled (audit trail of the brainstorm)

Recorded explicitly because the design converged across a long conversation and these
are the places it shifted. An auditor should check these did not leave residue.

- **T1 — provider trichotomy.** Mid-conversation, "runtime-provided" drifted toward
  "foreign FFI only," which would make Slice 3 unrunnable pre-FFI. Corrected: Provider
  A (interpreter prim) is runnable now and deterministic; FFI is Provider B. §1, §4.
- **T2 — runnable artifact.** With the provider model, the Slice-3 deliverable is
  Provider A's scheduler prim, not "a spec with nothing to run." §4, §7.
- **T3 — "zero new type-system machinery" overclaim.** RETRACTED for two cases:
  (a) IO-bearing `spawn` (Provider B) needs the load-bearing row (§3.1); (c) channels
  carrying effectful thunks need it too, so Slice 3 takes the payload restriction
  instead (§3.3). The token case (b) is RESOLVED *without* new machinery: tokens are
  plain `data` wrapping a provider id (§3.2), not a new extern form. So Provider A's
  remaining claim is true: with plain-data tokens + the payload restriction, no
  residual-row analysis and no new tycon machinery are needed.
- **T4 — `parAll` prim relocated, not eliminated.** Old pure-wok spine: `parAll` needed
  its own prim. Provider spine: `parAll` is a library over `async`/`await` — but the
  scheduler prim beneath it is *larger* than the old focused `__par`. Honest framing in
  §6: free only because the scheduler is built anyway for `spawn`/`async`.
- **T7 — token types are carriers under `extern type`.** The biggest concrete bug the
  audit caught: §2's tokens, as `extern type`, would be second-class affine carriers,
  contradicting §3.2. Fixed by making the tokens plain `data` wrapping a provider id
  (forging caught at the §6 provider boundary) — no new extern form, no keyword. §2,
  §3.2, §7.
- **T8 — channel-payload laundering + explicit `cancel`.** The §3.1 pin guards only
  `spawn`'s argument; effectful values crossing `Chan`/`Promise` are a second ingress,
  closed by the payload restriction (§3.3). Separately, `cancel : Fiber -> ()` is an
  explicit op (reversing async-spec §4.3) — sound here only because the carrier is
  provider-held (no wok affine double-consume). §2, §3.3.
- **T9 — `main` exemption is generic, not `main`-keyed.** Fact-check: the typechecker
  has no `main` special-case; the "doesn't obligate its row" property belongs to *any*
  unannotated zero-arg top-level binding (`Infer.hs:2976-2984`). The §3.1/T6 analogy
  holds (provider supplies top handlers; the child IS checked against `Ambient`), but
  do not look for a `main` special-case — it is not there.
- **T5 — determinism.** `Conc` neutral; deterministic under A; nondeterminism rides
  task IO under B. Consistent with §7, newly made explicit. §5.
- **T6 — `spawn` vs `main` exemption.** A spawned child is "like `main`" only in that
  the provider supplies its top handlers. Unlike `main` (exempt from declaring its
  row), `spawn`'s child *is* checked: its residual is unified against `Ambient` (§3.1).
  The analogy is about provided handlers, not the declaration exemption.

---

## 11. Provider A — known limitations (implementation + full-branch review)

The Provider A interpreter scheduler shipped on `feat/slice-3-conc` (778 green,
full-branch reviewed). These limitations are accepted for this slice and tracked for
follow-ups; none is a soundness hole in what ships.

- **Residual non-`Conc` effects in children are not runnable across resume.**
  `driveConc` resumes coroutine segments under a fresh `KDone`, which drops the ambient
  handler context. So a spawned/async child performing a non-`Conc` effect (e.g. `Log`)
  would hit an unhandled-effect *runtime* error, not a type error. `runConc`'s residual
  row `e` is therefore structural, not yet runnable for non-`Conc` child effects —
  documented at the `runConc`/`__drive_conc` signatures. Lifting this needs ambient-handler
  threading through the resume (related to the load-bearing-row / `explicit-resume-effect-laundering`
  work). All shipped fixtures keep children pure-up-to-`Conc`.
- **Payload restriction is annotation-time only.** The `Promise`/`Chan` function-payload
  check (§3.3) fires on signature annotations, not inferred types; an un-annotated
  `Chan (() -> …)` slips the static check and is caught at runtime as an unhandled-effect
  error (the §3.1 pin). Worse diagnostic, not unsound.
- **`__coerce : a -> b` is reachable from user code.** wok has no module privacy
  (async-spec §11.2), so `import Std.Control` exposes the `__coerce` erasure prim — a fully
  general unsafe cast, strictly broader than the type-constrained `__coro_*` prims. Sound
  *inside* the prelude (used only behind the `erase`/`recall` + `Transport` envelope); the
  real fix is module privacy / export lists (its own slice). Until then, user code naming
  `__coerce` is unsupported.
- **Cancellation is deferred.** `cancel`/`cancelFiber` were removed from the surface for
  this slice (a `ReqCancel` with no scheduler case had been a runtime trap). The only
  cancellation that ships is `raceAny` dropping losers — losers keep getting scheduled
  while the root still runs, then are dropped un-resumed once the root completes
  (daemonic, early-return drain; results discarded). Real cancellation needs fiber-id
  tracking + finalizers (`finally`), per §4.5/§4.6.
- **Nested `runConc` id-space collision.** `Fiber`/`Promise`/`Chan` handles are plain
  `U64` ids with no scheduler identity. An outer scheduler's handle used under an inner
  `runConc` silently addresses the *inner* scheduler's same-numbered cell (verified:
  cross-delivery and wrong-value `await` — no error, wrong answer). Avoid nesting
  `runConc` until handles carry instance identity (e.g. a scheduler-unique tag checked
  at request time).
- **The payload restriction remains bypassable in known ways even after the
  data-con-field fix.** Carriers/closures still cross the *static* check via:
  constructor fields of types only referenced positionally, record-constructor fields
  (`tcCons` stores positional cons only), and fully inference-only payloads with no
  written signature (the check is signature-locus only). The DYNAMIC transport guard
  (runtime continuation walk at the cell/channel boundary) is the backstop for
  *continuations* specifically; an effectful *closure* crossing sig-free remains a
  runtime unhandled-effect trap (worse diagnostic, not unsound).
- **One-shot transport guard is runtime-enforced.** The affine (one-shot) discipline on
  coro carriers is now enforced at the promise-cell / channel boundary: any value
  entering a cell or channel is spine-walked (`containsCont` in `Sched.hs`, data-con and
  record spines; deliberately not closure envs) and a captured continuation is rejected
  with `conc: a continuation cannot cross the transport (carrier in Promise/Chan)`. The
  static layer additionally rejects carrier *tycons* (`Step`/`Suspension`, the
  `tcCarrier`-marked externs) named anywhere in a `Promise`/`Chan` payload signature.
