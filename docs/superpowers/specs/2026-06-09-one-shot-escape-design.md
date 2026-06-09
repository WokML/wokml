# Slice 4b — the one-shot escaping continuation (a second-class, affine Future)

Date: 2026-06-09
Status: **Shipped (2026-06-09)** — Tasks 0–6 landed on `feat/one-shot-escape`, 681 tests
green, pending full-branch review before merge to `main`.
Design converged (extended brainstorming). Implements **slice 4b** of
`docs/superpowers/specs/2026-06-05-effect-handlers-ROADMAP.md`, re-scoped from "the
concurrency runtime" to "the **escape axis** of the continuation, in its smallest form."
Branch: `feat/one-shot-escape`.

Reads with: `one-shot-as-law-multiplicity` memory (the **count** axis; this slice is the
**escape** axis), `2026-06-09-one-shot-multiplicity-analysis-design.md` §7 (the deferred
`opMultiplicity`/trusted-`once` table, which returns here as its single intended consumer),
`named-effect-instances-design` memory + `src/Wok/TypeChecking/Carrier.hs` (the second-class
**carrier rule** this slice reuses), `effect-compilation-strategy` memory (the scheduler is a
deferred **policy**), `higher-ir-direction` memory (decidable HM, no linear types), and
`src/Wok/Interp/Machine.hs` (`dispatchOp`, slice-3 `answerRebind`, slice-4a deep re-install).

---

## 1. Summary

A continuation has two axes. **Count** is settled — one-shot is the law (the affine no-dup
analysis in `Wok.IR.Multiplicity`). This slice is the **escape** axis, in its minimal form:
a continuation **captured, parked, and resumed exactly once, later, after its handler's arm
has returned**, with the handler re-established on resume.

The slice delivers a **second-class, affine `Future`**: a handle to one parked one-shot
resumable computation. The continuation itself lives **below the effect boundary** (held by
the runtime as a `VCont`); the user holds only the opaque second-class handle. The escaping
operation is a **trusted-`once`** op (the `opMultiplicity` axiom deferred from the
multiplicity spec). A trivial **synchronous resumer** is the reference semantics: resume the
parked computation immediately / on demand, with no scheduler.

Deliverable: an escaping-one-shot capability that slice X rejects today now type-checks and
runs under the trivial resumer; **awaiting a Future twice = compile error**; **a Future
escaping its scope (returned/stored/listed) = type error**; **a re-performed effect with no
re-establishable handler at the resume site = type error**.

This is a **type-system slice with a CEK reference semantics**. It is policy-agnostic: the
scheduler, parallelism, lazy/async policies, cancellation runtime, and first-class Futures
are all **deferred** (§9).

---

## 2. The conceptual core: the bounds are the price of effects

The decisive framing, settled in brainstorming, is a three-layer stack separated by **what
is deferred and whether it is effectful**:

| Layer | What it defers | Re-run twice? | Escape its scope? | The price |
|---|---|---|---|---|
| **1. Lazy thunk** | a **pure** computation | harmless (same result) | harmless (pure dups freely) | **none** — unrestricted, first-class, memoizable |
| **2. Async/await (this slice)** | an **effectful** computation | the multi-shot hazard (re-perform effects → polymorphic-ref unsoundness) | the capability cannot be reconstructed (handlers gone) | **all three bounds**: second-class + affine + residual-row |
| **3. Parallelism** | many effectful computations + a scheduler | + data races on shared mutable state | + `ndet` | layer 2 + a scheduler **policy** |

The affinity, the second-classness, and the residual-row check on the `Future` are
**precisely the cost of the suspended computation being effectful.** A pure thunk pays none
of them. Therefore:

- **Layer 1 (pure lazy thunk) is OUT — by category, not omission.** It needs none of this
  machinery, and wok is strict by choice. A `Future` is **not** a thunk; conflating them is
  the design error. (A pure-laziness feature, if ever wanted, is separate and unrestricted.)
- **Layer 2 is this slice.** The three bounds are non-negotiable because the deferred
  computation performs effects.
- **Layer 3 is a scheduler policy over layer 2 — deferred.**

The "trivial synchronous resumer" constrains *when* resume fires (now, on demand), never
*whether* a continuation was captured (**always** — it is real capture, not an effectful
thunk forced at the await site).

---

## 3. The primitive (the user-facing shape)

The capability is a coroutine-shaped escape: a producer performs a `suspend`-style op exactly
at the capture point; a separate driver holds the resulting **second-class `Future`** and
resumes it **once**. The shipped surface uses **plain functions** (`start`/`value`/`resume`/
`cancel`) — no new grammar. The carrier rule is the main reused mechanism:

1. the **carrier rule** (`Carrier.hs`) makes a `Future`-typed binding second-class, and
   already permits binding a handle with `let` and using it through its name, or passing it
   as a handle-typed argument (incl. threading through recursion);
2. **type-directed dot dispatch** (`EProj`) is the mechanism for `s.resume` / `s.value`
   but is **NOT wired to Future-typed bindings in this slice** — the dot-accessor surface
   is a deferred nicety (§9). `value`/`resume`/`cancel` are called as plain functions.

### 3.1 Types

A new built-in tycon `Future a b r` (kind `* -> * -> * -> *`), where the captured
continuation's internals (its environment and private handlers) are **existentially hidden**;
only the interface is visible via **plain functions** (the dot-accessor surface `s.resume` /
`s.value` is a deferred nicety — see §9):

- `value  : Future a b r -> a`        — the value the producer suspended with (a **pure, non-consuming**
  projection; may be read any number of times).
- `resume : Future a b r -> b -> r`   — resume the parked continuation **once** with a `b`, running it to
  completion and delivering the producer's result `r` to the driver (the **affine
  eliminator**; see §6).
- `cancel : Future a b r -> ()`       — the other consuming eliminator; resume XOR cancel, at most once
  total (enforced by the affine consumption check).

The producer-side operation is an ordinary user effect:

```wok
effect Coro a b = { suspend : a -> b }     -- yield an `a`, get a `b` back on resume
```

`start` is the installer (no separate `with coro in` needed); it installs the Coro handler
and runs a suspendable computation to its first suspension, returning the handle:

```wok
start : (() -> r with Coro a b) -> Future a b r     -- a trusted-`once` capability op
```

Degenerate shapes simplify naturally: `a = ()` (no value yielded) or `b = ()` (resume with
no payload). `Future a b r` is the general symmetric-coroutine arity; the naming
(`Future`/`Coro`/`start`/`resume`/`value`/`cancel`) is settled here.

### 3.2 Canonical examples

**Escape that slice X rejects today, now type-checks and runs:**

```wok
module Main
import Std.Base
import Std.Control

producer : () -> U64 with Coro U64 U64
producer _ = (Coro.suspend 42) + 1     -- park here yielding 42; on resume, finish

main : U64
main =
  let s = start producer in            -- producer runs to its suspend; PARKED; s : Future
  resume s (value s * 10)              -- value s = 42; resume with 420; producer returns 421
```

Note: `start producer` (not `start (producer ())`); `value`/`resume` are plain functions
(not dot accessors); no `with coro in` wrapper needed — `start` is the installer.

**Fixed multi-continuation deterministic driver (falls out for free — two named handles, like
two `state` cells; no list, no scheduler, fully deterministic):**

```wok
worker : U64 -> () -> U64 with Coro U64 U64
worker n _ = (Coro.suspend n) * 2

main : U64
main =
  let a = start (worker 10) in         -- parked, yielded 10
  let b = start (worker 20) in         -- parked, yielded 20 (held simultaneously with a)
  resume b (value b + 1) + resume a (value a + 1)   -- driver picks the order: 42 + 22 = 64
```

**Await-twice = compile error (affine on `resume`):**

```wok
let s = start producer in
resume s 1 + resume s 2                -- ERROR FutureConsumedTwice: `s` consumed more than once
```

**Future escaping its scope = type error (carrier rule):**

```wok
leak : Future U64 U64 U64 -> Future U64 U64 U64
leak s = s                             -- ERROR CarrierEscape: `Future` returned
```

---

## 4. The runtime/user line (load-bearing)

The single most important architectural invariant, and the answer to "where does the parked
continuation live":

- **User side.** Calls `start producer` (which installs the Coro capability internally),
  holds an opaque **second-class `Future` handle** (or nothing), calls `value`/`resume`/`cancel`
  as plain functions. **Never** sees or stores a raw continuation. Bounded by: second-class
  (carrier rule), affine (resume/await **xor** cancel, ≤1), residual-row-checked (capability
  reconstruction).
- **Runtime side.** Holds the parked `VCont` **below the boundary**, performs the delimited
  capture, re-installs handlers on resume, routes the answer region-internally. The escape op
  is **trusted-`once`** — the `opMultiplicity = once` axiom deferred from the multiplicity
  spec §7, trusted like an FFI type signature.

**The hole this pokes in one-shot-as-law is exactly one trusted axiom on the built-in escape
op — not a general relaxation.** `Multiplicity.hs`'s `ROp r … → Many` rule (an arm that hands
`k` to an op) stays in force for all user code; only the trusted capability ops are certified
`once`. The line holds: a continuation is **never** a user value — it is either consumed
in-arm (slices 1–4a, contified) or held by the runtime and surfaced only as an opaque
second-class `Future` handle (this slice).

**Why no first-class Future (and why the scheduler will not need one either).** "First-class"
is ambiguous: first-class **in the host** (a Haskell `VCont` in a queue) is free and is how
the machine already works; first-class **in wok** (a user-written `[Future a]`) is what needs
rank-2/region or linear types — and is rejected. A future scheduler is a **runtime-provided
primitive** whose run-queue is a *host* value below the boundary, sound because it is
`with`-scoped and run-to-completion (all parked continuations resumed before the boundary
closes) + deep re-install + trusted-`once`. First-class-in-wok (Effekt's `box`) is the
**named, deferred upgrade axis**, needed *only* to let users write *new* control abstractions
over stored futures — revisited at the scheduler, with a concrete use case in hand.

---

## 5. The three bounds (the spec spine)

### 5.1 Lifetime / region — via second-class Futures (no rank-2)

Extend the carrier rule (`Carrier.hs:isHandleType`, ~292) to treat `CTCon TcFuture _` as
handle-like. A `Future`-typed binding is then second-class by the **existing** post-inference
walk: it may be a `let`/`where`-RHS used through its name, a dot-receiver (`s.resume`,
`s.value`), or a handle-typed argument (incl. a recursive-call argument) — and **never**
returned, stored in a constructor/record, put in a list, or captured by an escaping closure.
Violation = the existing `CarrierEscape` error. This is a **structural well-scopedness
check**, decidable and HM-principal — **no `forall s` region branding, no rank-2.**

Unlike a named effect-instance handle, a `Future` is not tied to an effect instance, so the
`TPerformOn`-receiver allowance is via the new `value`/`resume` accessors, not ambient
dispatch. Aliasing (two names for one future) is a runtime property, not a type one (consistent with
named instances); the affine eliminator (§5.3) handles it **conservatively** — it tracks
direct `let`/`case` aliases and counts a future passed to ANY function (except the `value`
reader) as a consumption, rejecting on doubt, so a future that could be resumed twice through
an alias or a helper is rejected rather than admitted. Tightening this (alias/inter-procedural
precise counting) is the deferred chaining work (§5.3, 4b′/4b″), only pursued if the
conservative rule rejects something real.

### 5.2 Effect — residual row + capability reconstruction (the soundness crux)

When `start (producer ())` captures the producer's continuation `k`, `k` is delimited **up to
the `coro` capability handler** (the machine already captures `above` up to the matching
`KHandle`). On `s.resume v`, the machine re-installs the captured handlers (slice-4a deep
re-install) and routes the answer to the resume call site (slice-3 `answerRebind`). So **the
capability is reconstructed by construction** for every handler captured *inside* `k`.

The type guarantee: **every effect the resumed continuation re-performs must be handled at the
resume site.** The producer's `with Coro a b` is discharged by `coro`; the *residual* row of
`k` (what it still performs after the suspend) flows into the type of `s.resume`. Concretely:

- If `k` completes without re-performing `Coro` → `s.resume v : r` (clean). This is the
  single-suspension case the slice targets.
- If `k` re-performs an effect, that effect *should* appear in `s.resume v`'s row and be
  handled at the resume site. **As shipped, this is NOT enforced** — see the correction
  below. The residual-row obligation is the deferred 4b″ work.

> **CORRECTION (post-review, 2026-06-09): re-suspension is UNGUARDED.** The text above (and
> the crux note below) describes the *intended* residual-row discipline, but the shipped
> `Future a b r` carries **no residual row**, so there is **no row obligation on `resume`**. A
> well-typed producer that performs `Coro.suspend` more than once therefore **type-checks**,
> and at runtime `resume s v` returns a malformed `Suspended(...)` value; using that result as
> the producer's `r` (e.g. feeding it to `__coro_unwrap`'s consumer) **crashes with a runtime
> `PrimError`** — it is NOT a type error. This is a known limitation; the guard requires the
> deferred residual-row-carrying Future (4b′ chaining / 4b″, §9). Do not rely on a re-suspension
> being rejected at compile time today.

This is the **shared/private split** at the type level: handlers captured *inside* `k`
(private) travel with it and are re-established; effects handled *outside* the capability
(shared/ambient) are provided by the resume site. For a single synchronous resume there are
no races, so the **full shared-vs-mutation/`ndet` marking is deferred to layer 3**; this slice
types only the **reconstruction** obligation (residual row ⊆ resume-site-establishable), which
is what soundness needs now.

> **THE CRUX TO VALIDATE FIRST (TDD day one).** The exact machine semantics of resuming past
> the capability's own `suspend`: does `s.resume` re-establish the `coro` capability's
> suspend-handling (which would make a re-suspension re-park and force `resume`'s result to be
> a done-or-yield sum — the deferred chaining case, §9), or does it run `k` with the
> capability's `suspend` **not** re-handled (so a re-suspension *would* surface `Coro` in
> `resume`'s residual row → handled at the resume site or a type error)? **The slice intended
> the latter**, but as shipped the residual row is NOT carried by `Future`, so a re-suspension
> is **unguarded** (see the CORRECTION above): the single-suspension producer types cleanly as
> `r`, while deliberate re-suspension (unbounded generators) type-checks too and crashes at
> runtime. Closing this is the deferred residual-row work (§9, 4b′/4b″). Build the smallest
> typed `start` + synchronous `resume` first and confirm this is sound and implementable
> against `dispatchOp` before building anything else.

#### Task 0 decision note (spike result, 2026-06-09)

The walking-skeleton ran to **421** under `--run` and **NOT BLOCKED** — first-class is not
required: the continuation lives below the boundary as a plain `VCont` inside a `VCon`, the
user only ever holds the opaque `Suspended`/`Completed` handle. Decisions recorded:

- **(a) Host-op hook shape.** No `dispatchOp` change and no `hNative` field were needed. The
  capture happens through the *ordinary* wok handler path: `start` installs a normal
  `with Coro { suspend x k -> … ; v -> … }` handler; the only host code is two trusted
  bodyless prims (`Wok.Interp.Prim`), `__coro_susp x k` (packs the future) and `__coro_unwrap`
  (peels one re-install layer). This is the smallest of the three hypotheses — primitives over
  a future value, capture via the existing handler arm. The reserved-label / `hNative`
  branches were not needed.
- **(b) Future value representation.** Reuse confirmed: `VCon "Suspended" [yielded, VCont k]`
  (and `VCon "Completed" [r]`), an ordinary two-constructor wok `data Future a b r`. It
  round-trips through `enter`/`returnTo`/`renderValue` unchanged; no new `Value` constructor.
- **(c) Resume vs deep re-install (THE crux) — OBSERVED.** Probed with a producer doing a
  *second* `Coro.suspend`. Resuming produced `Suspended(7, <continuation>)`: `dispatchOp`'s
  deep re-install re-installs the WHOLE Coro handler (suspend arm included), so a re-performed
  `suspend` **re-captures and chains for free at runtime**. So the runtime naturally does the
  *done-or-yield chaining* the spec scopes OUT (§9), NOT the single-suspension carve-out. Also
  observed: deep re-install re-runs the *value* arm too, so `k v` returns `Completed r`, not
  raw `r` (hence `__coro_unwrap`). **Committed direction unchanged: the slice stays
  single-shot at the TYPE level** (§5.2 residual-row obligation; re-suspension surfaces `Coro`
  in `resume`'s row → handled-at-resume-site or type error). The runtime over-delivers
  (chaining is free); the *typing* (Tasks 3/5) is what restricts it. Chaining is therefore a
  pure typing increment for 4b′ — no new runtime machinery is needed, which is a useful
  de-risking of §9.
- **(d) Multiplicity bypass — YES (expected).** The suspend arm hands `k` to `__coro_susp`, so
  `Multiplicity.hs`'s `ROp r→Many` rule rejects it (`multishot resume … Coro.suspend`). The
  spike temporarily routes `--run` through `Pipeline.elaborateProgramFull` instead of
  `elaborateCheckedFull` (one-line change in `app/Main.hs`, marked `SPIKE … RESTORE`). **Task 3
  is the real fix** (trusted `opMultiplicity = once` on the escape op); restore
  `elaborateCheckedFull` then. Type-checking itself was NOT bypassed — the example type-checks
  as written, once `__coro_susp`'s polymorphic continuation slot (`b -> s`, with `s` decoupled
  from the future's `r`) absorbs the otherwise-occurs-checking `k : b -> answer` typing that
  `inferHandler` gives a control-arm resume (`Infer.hs` ~1983, `resume : T -> R`).

The spike machinery (the prelude `coro`/`start`/`resume`/`value`/`Future`/`__coro_*`) was kept
OUT of the embedded `Std.Control` (putting it there made every test's whole-program
multiplicity analysis flag the prelude `suspend` arm); it lived in the scratch example only.
The committed interpreter delta is just the two prims + the temporary `app/Main.hs` bypass +
the prim-table unit-test update.

### 5.3 Cardinality — affine, local, resume-xor-cancel (no linear types)

Because Futures are second-class, all their uses are **syntactically local** (the carrier rule
guarantees it), so the no-await-twice check stays a **local analysis** — slice-X-flavored, not
program-wide linear types. Two pieces:

1. **Relax the trusted escape op.** Today `Multiplicity.hs` `cardOf` returns `Many` for any
   resume binder that escapes into an `RApp`/`ROp`. For the **trusted escape sink only**
   (`__coro_susp`), handing `k` to it is certified `1`, not rejected. User code is unchanged.
   **The match is on the prim's IDENTITY (post-review, C2):** `cardOf`/`analyzeModule` take the
   canonical `Unique` of the genuine `(Std.Control, "__coro_susp")` binding (resolved in the
   pipeline from the elaborated global-name map, by *defining module* — see
   `elaborateProgramFullTrusted`), NOT the hint text. A user-defined top-level `__coro_susp`
   has a distinct identity and is therefore NOT trusted (it is rejected as `MultishotResume`).
   When Std.Control is not loaded the trusted identity is `Nothing` and the relaxation never
   fires.
2. **Affine on the eliminator** (`checkFutureAffine`). A `Future`'s `resume`/`cancel` is the
   affine consumer: **at most one** consumption per future (a `Future` consumed twice →
   `FutureConsumedTwice`). **THE CONSUMPTION RULE (post-review, conservative,
   inter-procedurally sound without summaries):** a `Future` passed as an ARGUMENT to **any**
   function counts as consuming it (`One`), **except** the non-consuming reader `value` (and
   its prim `__coro_value`), which counts `Zero`. Rationale: the carrier rule lets a future
   flow into a `Future`-typed parameter slot, so a helper `useit f = resume f n` called twice
   double-resumes; counting *passing the future* as a consumption catches that without an
   inter-procedural summary. `resume`/`cancel` are consumers like any other callee.
   **The reader is trusted by EXTERN IDENTITY (post-review, C3), not a bare text match.**
   `value` is a direct `extern` in `Std.Control` (bound to the value-projection prim), and
   `extern` is **prelude-only** (a `UserFile` declaring one is rejected with `ExternNotAllowed`,
   Part 1). The affine check trusts a `value` callee only when it resolves, at this module's
   scope, to that prelude extern — i.e. the name is the reader name AND it is neither (a)
   **redefined by this module at the top level** (a user `value : Future … -> …` is a regular,
   non-extern binding — `rtShadows`), NOR (b) **locally shadowed** (a `let value = \f -> resume
   f 1` is the local binding — the free-occurrence test). Since only the prelude can mint an
   `extern`, a reader name that survives both checks IS the prelude extern reader by identity;
   anything else (a user top-level or local `value`) is treated as a consumer
   (`FutureConsumedTwice`). This closes the double-consume-via-shadowed-`value` hole (C3)
   structurally, and — unlike the earlier `ReservedName` reservation — it no longer forbids a
   user from *defining* `value`; it just doesn't *trust* a user `value`.
   Escaping-closure capture remains `Many`. Aliasing (`let t = s`) is tracked: a consuming use
   of an alias counts against the original. **Cancellation** is the *second* eliminator: a
   future is resumed **xor** cancelled (≤1 total). This slice **types resume-xor-cancel now**;
   the **cancellation runtime** (finalizer unwinding) is deferred (§9). **DEFERRED with
   chaining (4b′/4b″):** precise inter-procedural consumption — threading a future through a
   non-consuming helper more than once, or through recursion for chaining — is rejected today
   (over-conservative) and is the upgrade axis. This is the no-drop groundwork flagged in
   `one-shot-as-law-multiplicity`.

> **Known pre-existing limitation (out of slice scope, I1).** There is a pre-existing
> resolution split between the type checker and the interpreter: a same-module top-level
> binding that shadows an *implicit-prelude* name resolves to the **user** binding in the type
> checker but to the **prelude** binding in the interpreter. This is NOT introduced by slice
> 4b. The earlier reserved-vocabulary rule (the removed `ReservedName` check) masked this for
> the coro names by forbidding the shadow outright. **With the reservation retired in favour of
> extern-identity trust (Part 1 + C3), a user MAY again define a top-level `value` in a
> `Std.Control`-importing module, so I1 is re-exposed for the coro vocabulary.** It remains a
> **correctness-only, not a soundness** issue: the affine check now treats every user `value`
> (own top-level or local) as a CONSUMER — it trusts only the prelude `extern value` by
> identity — so an I1 resolution split can never UNDER-reject (a double-consume through a user
> `value` is still `FutureConsumedTwice`). The general bug remains for prelude names and is
> recommended for a separate fix (align checker/interpreter resolution, or forbid prelude-name
> shadowing wholesale). Deliberately out of scope for this slice.

---

## 6. The trivial synchronous resumer (reference semantics)

The reference runtime drives the parked continuation **immediately, synchronously,
deterministically** — no scheduler, no readiness, no `ndet`:

- `start c` evaluates `c` under the `coro` capability until `c` performs `Coro.suspend x`. The
  `coro` handler arm captures `c`'s continuation `k` (delimited to the capability), stores
  `(x, k)` in the capability's runtime state (host-side, below the boundary), mints a fresh
  second-class `Future` handle, and **returns the handle** to the `start` call site (the arm
  has returned without resuming — this is the escape, exactly the shape slice X rejects).
- `s.value` projects the stored `x`.
- `s.resume v` re-installs `k`'s captured frames over the resume site (deep re-install),
  delivers `v`, and runs `k` to completion, routing the result `r` to the `resume` call site.

The TYPING targets the general resume-after-arm-returned semantics; "synchronous" only means
`resume` drives `k` immediately rather than a scheduler doing it later. The machine's existing
deep re-install makes this the **natural** path, not extra runtime machinery.

**Testing consequence (mirrors the multiplicity spec):** the immutable `Kont` tolerates a
second resume, so a false-affine bug will not crash — it will run and yield a coincidentally
plausible result. So the affine/escape checks are tested **directly** via type/golden
artifacts, never via "does it run." An optional debug-only single-use assertion on the future
handle is a cheap differential oracle.

---

## 7. Where it plugs into the code

- **Type:** register `Future` in `Builtins.hs` (kind `* -> * -> * -> *`, arity 3) and resolve
  `"Future"` → a new `TcFuture` `TyCon` in `Infer.hs:resolveTyCon`; add `TcFuture` to the
  `TyCon` enum.
- **Carrier:** extend `Carrier.hs:isHandleType` to accept `CTCon TcFuture _`; add the
  `value`/`resume` accessor slots as allowed dot-receivers.
- **Typing:** the `coro` capability's `start`/`resume`/`value` are typed against the effect
  row as in `inferHandler` (§5.2 residual-row obligation on `resume`).
- **Multiplicity:** introduce the trusted `opMultiplicity` table (default `Many`, `once`
  override) and route the escape op through it in `cardOf`'s `ROp` case; everything else
  unchanged.
- **Machine:** the `coro` capability arm parks `(x, k)` host-side and mints a `VFuture`
  handle; `resume`/`value` ops dispatch on it; reuse `dispatchOp`'s deep re-install +
  `answerRebind`. No new `Kont` constructor expected (the future handle is a `Value`; the
  continuation it points to is an ordinary `VCont` held in capability state).

No grammar change is anticipated (reuse `let` + dot + `with`-runner). If that changes, regen
BNFC, reapply the three manual patches (`grammar/Wok.cf:13-69`), and confirm the shift/reduce
count stays 32.

---

## 8. Prior art (situating the choice)

| | effect types | multi-shot | continuation class | runtime |
|---|---|---|---|---|
| OCaml 5 | none (runtime) | runtime-clone (`multicont`) | **first-class** value | stackful fibers |
| Koka | **rows** | yes (reified) | first-class-ish resume | evidence + reify |
| Effekt | yes (capabilities) | yes | **second-class** (+ `box`) | — |
| **wok** | **rows** | **no (one-shot law)** | **second-class (no `box` yet)** | uniform reified interp |

wok is the **strictest coherent point** — Effekt's second-class discipline plus
one-shot-as-law, with the `box`/first-class escape hatch deferred. Schedulers/dynamic future
collections are exactly where OCaml (queues of first-class continuations), Koka (reification),
and Effekt (`box`) concentrate their heavy machinery; deferring them costs nothing today and
lands the future first-class decision at the scheduler, deliberately.

---

## 9. Scope: IN / OUT

**IN (shipped on `feat/one-shot-escape`)**
1. The opaque `Future a b r` second-class type (`TcFuture`) + the `Coro` effect + `start`/`resume`/`value`/`cancel` as plain functions via trusted prims + `Std.Control`.
2. The await/resume-once typing rule: the affine consumption check `checkFutureAffine` (`FutureConsumedTwice`) — both await-twice and resume-then-cancel rejected.
3. The lifetime bound via the extended carrier rule (`CarrierEscape` for Future-typed bindings).
4. The trusted-once relaxation for `__coro_susp` (the escape sink) in `Wok.IR.Multiplicity`, restoring `elaborateCheckedFull`.
5. The "no handler ANYWHERE" rejection: a producer with an unhandled effect propagates into `start`'s row and is a type error at the call site (RowMismatch). The subtler "a BOUNDED handler that returned BEFORE resume" case — where the handler was present at `start` but has already returned by the time `resume` fires — is NOT caught and is deferred (it needs a residual-row-carrying Future; see 4b″ below).
6. The **trivial synchronous resumer** as the reference CEK semantics.

**OUT (deferred)**
- **Unbounded generators / chaining** (4b′) — a future whose resumption yields another future; needs a done-or-yield eliminator with a second-class sum component. The crux in §5.2 deliberately scopes this out. Runtime over-delivers (deep re-install makes chaining free); this is a pure typing increment. **Known limitation until then:** a producer that performs `Coro.suspend` more than once type-checks (no residual-row obligation on `resume`) and crashes at runtime with a `PrimError` on `resume` — re-suspension is currently UNGUARDED (see the §5.2 CORRECTION).
- **Residual-row-carrying Future + bounded-handler-escaped unhandled-reperform** (4b″) — a Future typed as `Future a b r eff` carrying the residual effect row, so a re-performed effect is visible at the resume site; needed to catch the bounded-handler-escaped case. Requires a row-indexed Future.
- **Dot-accessor surface** (`s.resume`, `s.value`) — a deferred ergonomic nicety; the shipped surface uses plain functions. Type-directed dot dispatch (`EProj`) exists but is not wired to Future-typed bindings.
- **Scheduler / `spawn` / `par` / `select` / readiness / `ndet` racy scheduling** → layer 3 (runtime-provided primitives; `effect-compilation-strategy`).
- **First-class Futures in wok / Effekt-style `box`** → revisited at the scheduler.
- **Cancellation runtime** (finalizer unwinding) — only the *type* (resume-xor-cancel) is in.
- **Relocation / worker capability-config / multicore runtime / OS readiness** → deferred.
- **Selective CPS / contify-vs-reify** — backend; the interpreter is uniform-reified.

---

## 10. Soundness / multicore

The bounds are designed to be **multicore-sound now** even though the runtime is deferred:
second-class confinement + affine resume = no shared mutable continuation and no double-resume,
so a future scheduler cannot introduce a data race on the continuation itself. Mutable state
*shared* across resumptions (the layer-3 hazard) is exactly what the deferred shared/`ndet`
marking will govern; this slice does not enable it (single synchronous resume, no concurrency).

---

## 11. Testing strategy (TDD)

- **Type/golden — passing:** the §3.2 escape example and the fixed multi-continuation driver
  type-check and run under the trivial resumer with the expected results (`421`, `64`); a
  `--dump-multiplicity` golden shows the escape op certified `1`.
- **`typecheck-fail` corpus (the four required negatives):**
  1. **await-twice** (`s.resume 1 + s.resume 2`) → `MultishotResume`.
  2. **Future escapes scope** (returned / stored in a constructor / put in a list) →
     `CarrierEscape`.
  3. **re-performed effect with no re-establishable handler** at the resume site → unhandled-
     effect type error.
  4. **resume-xor-cancel violated** (`resume` then `cancel`, or both twice) →
     `MultishotResume`.
- **Unit tests** on the extended `Carrier`/`Multiplicity` rules (`Future` handle-ness; the
  trusted `opMultiplicity` route) over hand-built inputs — the TDD anchor.
- **Day-one spike (the crux, §5.2):** the smallest typed `start` + synchronous `resume`,
  confirming the resume-past-the-capability semantics is sound and implementable against
  `dispatchOp` *before* building the rest. If it forces a first-class Future, **stop and
  surface it** (reshapes the roadmap).
- Regenerate goldens with `cabal run wok-tests -- --accept` (read diffs first).

---

## 12. Build / verify

- `cabal build`; `cabal test` (652 green at branch start — must stay green plus the new
  escape goldens / `typecheck-fail` negatives).
- `cabal run -v0 wok -- <file.wok> --run | --dump-anf | --dump-multiplicity`.
- No grammar change anticipated; if it changes, regen BNFC + reapply the three manual patches
  + confirm shift/reduce count unchanged (32).
- **Full-branch review before any merge to `main`** (per-task reviews do not substitute;
  `review-before-merge`).

---

## 13. Rejected alternatives (with reasons, for deliberate re-litigation)

- **Lazy-thunk reading of the resumer** (`spawn` boxes a computation, `await` forces it).
  Rejected: that is layer-1 (effectful laziness) wearing an async costume; it never parks a
  continuation, so it does not exercise escape, capability reconstruction, or the bounds. The
  resumer must be real capture (§2, §6).
- **`spawn`/`await` of independent tasks as the slice surface.** Rejected for *this* slice:
  synchronously + single-task it degenerates to the thunk reading above; it becomes honest
  only with a scheduler (layer 3). Kept as the eventual layer-3 policy surface.
- **A user-written escaping handler that stores `k` in its own state.** Rejected: a
  continuation in user handler state is `k`-into-data, which the carrier and multiplicity rules
  reject; it is the first-class direction (rank-2 + linear). The capability is runtime-held
  instead (§4).
- **A special `step … as v rest in` binder.** Rejected as unnecessary for the single-shot
  primitive: the shipped carrier rule already permits `let s = start … in s.resume (s.value …)`
  with dot accessors. The binder/eliminator returns only for the deferred chaining slice (§9).
- **First-class Futures now (rank-2 region branding + linear types).** Rejected by the hard
  decidability constraint; deferred as Effekt-style `box` (§4, §8).
- **Re-installing the capability's own `suspend` on resume (done-or-yield sum result).**
  Rejected for the minimal slice: it forces a built-in sum-with-second-class-component and its
  eliminator; the single-suspension primitive is sound without it (§5.2 crux). Deferred to 4b′.
- **Make the interpreter enforce affine (linear `Kont`).** Rejected, consistent with the
  multiplicity spec: the law is a frontend gate; a debug-only single-use assertion is the kept,
  opt-in oracle (§6).
