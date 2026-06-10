# Slice 4c — the closed `Step` ADT + suspend-family naming (supersedes the 4b′ CPS `step`)

Date: 2026-06-10
Status: **Implemented** on `feat/slice-4c-step-adt` (pending full-branch review before merge to
`main`). 687 tests green. Supersedes the surface of slice 4b
(`2026-06-09-one-shot-escape-design.md`) and replaces the 4b′ CPS `step`
(`2026-06-09-slice-4b-prime-chaining-generators-design.md`, merged `c5aef74`). This reworks the
already-merged coroutine surface, so it is a deliberate surface-churn slice justified by
**correctness + readability** (the explicit priorities) and by unlocking multi-future interleaving.
Implementing session: writing-plans → subagent-driven-development. TDD. Full-branch review before
merge to `main`.

Reads with: memory `effects-slice-4b-prime-chaining-generators` (the converged rationale + the
two-axis/affine-wall analysis), `effects-slice-4b-one-shot-escape` (the shipped mechanism this
reworks), `prelude/Std/Control.wok` (the surface being changed), `src/Wok/TypeChecking/Carrier.hs`
(`isHandleType`/`checkFutureAffine`/`checkCarriers`), `src/Wok/Interp/Prim.hs` (the `__coro_*`
prims), `src/Wok/Interp/Machine.hs` (`dispatchOp`/deep re-install).

## 1. Summary

Slice 4b′ shipped `step` as a CPS combinator (`step f v onDone onYield`). Two problems surfaced:

1. **Multi-future interleaving (zip/merge) is rejected.** The CPS callback that steps a second
   producer captures its future, and the carrier rule forbids a future-capturing closure in a
   non-handle continuation slot (`CarrierEscape`). It is inherent to the CPS form; locked as the
   `future-step-multi-future-interleave` tripwire golden.
2. **Naming incoherence.** The producer performs `Coro.suspend`, the runtime tags are
   `Suspended`/`Completed`, but the consumer surface used `Future`/`value`/`resume` — three
   vocabularies for one boundary.

This slice replaces the CPS `step` with a **closed, transparent `Step` ADT eliminated by `case`**,
and aligns the whole surface to the **suspend-family** vocabulary already shipped on the producer
and runtime sides. The decisive insight: a `case` binds the tail in an **arm**, not a closure, so
referencing a second future in an arm body is ordinary in-scope use — **the carrier rule never
fires**, and multi-future interleaving type-checks with **no new type-system machinery** (no
rank-2 regions, no second-class arrow). The runtime already produces the exact sum we surface, so
this is also allocation-neutral.

## 2. The naming decision (suspend-family) and why

The boundary between a producer and a consumer has exactly two events. Each already has a settled
word on the producer and runtime sides; the consumer must speak the same word:

| event | producer | runtime tag | consumer (this slice) |
|---|---|---|---|
| produced a value, more to come | `Coro.suspend x` | `Suspended [x, k]` | `Suspended x g'` |
| finished with result `r` | `return r` | `Completed [r]` | `Completed r` |

Cross-language grounding (checked against the references): Rust separates `Future` (async,
single `Poll::Ready`) from `Coroutine` (`resume -> CoroutineState = Yielded | Complete`); OCaml's
resumable handle is a **one-shot `continuation`** (`continue`, resume-once enforced dynamically —
wok enforces the same discipline *statically*); OCaml's pull-stream node is `Nil | Cons`. The
generator tradition (Koka/Python/JS/Rust keyword) uses `yield`. We deliberately choose the
**suspend-family over the yield-family** because it (a) keeps the producer surface 4b shipped
(`Coro`/`suspend`) with zero churn, (b) reuses the runtime tags verbatim as the `Step`
constructors, and (c) makes producer, runtime, and consumer speak one word. The cost — divergence
from the external `yield` convention — is accepted in favour of not surprising existing wok users.
(`Future` is renamed because it is the one name that means the *opposite* everywhere else.)

The rejected yield-family alternative is recorded in §11.

## 3. Types and surface

```wok
-- PRODUCER (unchanged from 4b)
effect Coro a b = { suspend : a -> b }       -- a = yielded type, b = resumed-with type

-- HANDLE (renamed from `Future`): opaque, second-class, affine
Suspension a b r                              -- r = producer's return type; no user constructors

-- OUTCOME (new): a built-in, transparent, carrier+affine ADT
Step a b r = Completed r | Suspended a (Suspension a b r)

-- CONSUMER API
start  : (() -> r with Coro a b) -> Step a b r     -- install + run to first suspend; FIRST outcome
step   : Suspension a b r -> b -> Step a b r        -- resume once; next outcome
run    : Suspension a b r -> b -> r                 -- single-shot convenience (see §3.2)
cancel : Suspension a b r -> ()                     -- discard a suspension without resuming
```

Removed vs 4b/4b′: `value` (subsumed by binding `x` in `Suspended x g'`), the CPS `step`
(`… -> (r -> t) -> (a -> … -> t) -> t`), and the internal `__coro_step` prim. `resume` is renamed
`run`.

### 3.1 Canonical examples

```wok
-- single-future pull (replaces sumPulled): the tail g' threads through recursion
sumPulled : Suspension U64 () () -> U64
sumPulled g = case step g () of
  Completed _    -> 0
  Suspended x g' -> x + sumPulled g'

main : U64
main = case start (\u -> range 0 5) of
  Completed _    -> 0
  Suspended x g' -> x + sumPulled g'          -- 0 + (1+2+3+4) = 10

-- multi-future zip (PREVIOUSLY REJECTED, now type-checks — tail binds in a case arm, no closure)
zipSum : Suspension U64 () () -> Suspension U64 () () -> U64
zipSum a b = case step a () of
  Completed _    -> 0
  Suspended xa a' -> case step b () of
    Completed _    -> 0
    Suspended xb b' -> (xa + xb) + zipSum a' b'

-- single-shot (replaces `resume s (value s * 10)`): yield value comes from the pattern
single : U64
single = case start producer of
  Completed r     -> r
  Suspended x g'  -> run g' (x * 10)          -- x = 42; run to completion → 421
```

### 3.2 `run` (the single-shot convenience)

`run g v` resumes `g` once and returns the producer's result, assuming the producer does **not**
suspend again. It is the renamed 4b `resume`, and carries the same documented partiality: if the
producer re-suspends, `run` fails at runtime (the residual-row guard that would make this a type
error is the independent 4b″ work). `run` is a convenience over `case step g v of Completed r -> r
; Suspended _ _ -> «error»`. It is kept for ergonomics; if the project prefers correctness-only
surface, it may be dropped (users write the explicit `case`). Flagged for the spec-review gate.

## 4. Internal representation (performant + easy to analyze)

The runtime already represents a resumed coroutine as `VCon "Suspended" [x, k]` or
`VCon "Completed" [r]` (4b). **`Step` is the typed, transparent view of that existing value** — its
constructors `Suspended`/`Completed` map to those exact tags. Therefore:

- `step g v` is the resume-one-step the runtime already performs (the `__coro_resume` path: apply
  the parked continuation `k` to `v`, deep re-install re-captures on re-suspend), **typed to return
  `Step a b r`**. No conversion, no extra allocation, no callbacks.
- `start c` installs the `Coro` handler and runs `c` to its first suspension, returning the
  resulting `Step` (the `Suspended`/`Completed` VCon) directly.
- `case s of Completed r -> … ; Suspended x g' -> …` compiles to the ordinary two-tag case
  dispatch.
- The 4b′ `__coro_step` CPS dispatcher is **removed** (unused).
- `Suspension` is the existing `TcFuture` tycon renamed (`TcSuspension` or keep the internal
  constructor, rename only the surface). `Step`/`Completed`/`Suspended` are a built-in tycon +
  constructors whose runtime tags are the existing `"Completed"`/`"Suspended"`.

This is simultaneously the most performant (reuses the value `resume` already builds) and the
easiest to analyze (a normal ADT + `case`, no lambdas introduced before the analyses run).

## 5. The analyses (correctness)

`Suspension` and `Step` are both **carrier (escape-restricted) and affine (consume-once)**,
reusing the existing machinery by adding them to its type-sets:

- **Carrier (`Carrier.hs`).** `isHandleType` accepts `Suspension` (as it did `TcFuture`) and `Step`.
  A `Step` or `Suspension` binding may be a `let`-RHS used by name, a handle-typed argument
  (incl. recursion), or a `case` scrutinee — but never returned, stored in a constructor/list, or
  captured by an escaping closure. The `Suspended` constructor is the one blessed exemption to
  "no `Suspension` inside a constructor."
- **Affine (`checkFutureAffine`).** A `Suspension` is consumed once (passed as an argument =
  consumption, as today). A `Step` is consumed once by **`case`-scrutiny** (the new consumption
  site). Scrutinizing the same `Step` binding twice, or threading a `Suspension`/`Step` so it could
  be consumed twice, is `FutureConsumedTwice`. The generator recurses on the **fresh** tail `g'`,
  so each handle is consumed exactly once.

### 5.1 Load-bearing ordering invariant

Carrier + affine run on the **typed AST** (`TExpr`, pre-ANF), where the dispatch is a `case` on
`Step` — so multi-future interleaving sees no closure and passes. The lowering of `Step`/`case`
toward the runtime VCon dispatch happens **later, in elaboration to IR** — *never* as a typed-AST
rewrite. If any pass lowered `Step`→CPS before the carrier check, zip would break again. This
ordering is the entire reason the slice needs no second-class arrow and no carrier relaxation.

> **CONFIRMED (implementation):** the invariant holds **trivially** — `Step` IS the runtime
> `Suspended`/`Completed` VCon (built-in `TcStep`, constructors map to the existing tags), so there
> is **no lowering to CPS at all**; `case` on a `Step` is an ordinary tag-dispatch. There is no
> transformation that could turn the dispatch into a capturing closure, so multi-future zip
> type-checks and `coro-step-zip` runs (→ 52).

### 5.2 Safety obligation (first test to write)

The `Suspended`-may-hold-a-`Suspension` exemption must not let a suspension launder out of scope:
because `Step` is itself carrier+affine, a contained `Suspension` cannot escape any more than a
bare one can. Verify with a negative: returning/storing a `Step`, or returning the `g'` extracted
from a `Suspended` arm, must be `CarrierEscape`.

## 6. Type correctness

`Step` is an ordinary closed two-constructor type; `case` on it is HM-principal and exhaustiveness
is enforced (both arms required — the readability/totality win). The `Suspension a b r` recurrence
inside `Suspended` is the same tycon at the same args. No rank-2, no new arrow, no inference
change. `start`/`step` are typed against the `Coro` row exactly as in 4b.

## 7. Scope

**IN:** rename `Future` → `Suspension`; add the built-in `Step a b r = Completed r | Suspended a
(Suspension a b r)`; `start : … -> Step a b r`; `step : Suspension a b r -> b -> Step a b r`
(ADT-returning, replacing the CPS form); `run` (renamed `resume`); `cancel`; carrier + affine
extended to `Suspension`+`Step` (incl. `case`-scrutiny as a `Step` consumption + the `Suspended`
constructor exemption); remove `value` and `__coro_step`; the ordering invariant (§5.1); the full
example/golden migration (§8).

**OUT (deferred):**
- The yield-family naming (rejected, §11).
- The general second-class one-shot **arrow** (rejected — not needed once `case` binds the tail;
  YAGNI for real generator code; memory records the analysis).
- **Dynamic-arity** multi-future (lists/queues of suspensions, schedulers) — the affine wall
  (consume-once over a dynamic collection needs linear types or runtime) puts this at layer 3
  (runtime-provided), per the existing layering.
- Residual-row-carrying `Suspension` (4b″) that would make `run`/re-suspension a *type* error.
- Cancellation finalizer runtime; first-class/`box`; scheduler.

## 8. Migration (what changes on the merged surface)

- `prelude/Std/Control.wok`: rename `Future`→`Suspension`; drop `value` + the CPS `step` + retire
  `__coro_step`; `start` returns `Step`; add the `Step` ADT; `resume`→`run`.
- `src/Wok/Interp/Prim.hs`: remove `coroStepP`; keep `__coro_susp`/`__coro_resume`/`__coro_unwrap`/
  `__coro_done`/`__coro_cancel`; remove the `value` extern (and its prim) unless reused.
- Builtins/Infer: rename `TcFuture` surface to `Suspension`; register `Step` + its constructors
  mapping to the `Completed`/`Suspended` tags.
- Examples + goldens to rewrite to the new surface: `coro-escape` (now `case start … of` + `run`),
  `coro-multi-driver`, `coro-step-range` (the §3.1 `case` form), the three `future-step-*`
  negatives (retargeted: double-`case` a `Step`, escape a `Step`/`g'`, input double-consume), and
  **flip `future-step-multi-future-interleave` from a typecheck-fail tripwire to a passing
  run-example** (zip now type-checks → assert its result).
- Update the 4b/4b′ spec status notes to point here.

## 9. Testing

- Run-examples (passing): `coro-step-range` (10), `coro-multi-driver`-style, the **promoted zip**
  example (assert its sum), the single-shot `single` (421). Back-compat conceptually preserved
  (same producers, new surface).
- typecheck-fail goldens: `Step` scrutinized twice → `FutureConsumedTwice`; `Step`/`g'` escapes →
  `CarrierEscape`; input suspension consumed twice → `FutureConsumedTwice`.
- Day-one anchor: confirm carrier+affine treat `Suspension`+`Step` correctly AND run on the
  typed-AST `case` form before any lowering (§5.1); the safety negative (§5.2).
- `examples/`: re-sweep for the new surface; confirm no shipped file breaks (note: `examples/` is
  not CI-scanned — sweep manually, as the 4b′ review caught).

## 10. Build / verify

`cabal build`; `cabal test`; `cabal run -v0 wok -- <file> --run`. No grammar change (shift/reduce
stays 32). Full-branch review before merge.

## 11. Rejected alternatives

- **Yield-family naming** (`Coro.yield` / `Step = Yield a h | Done r` / handle `Gen`). Matches the
  external generator convention and is consumer-intuitive, but churns the *producer* op and the
  runtime tags that 4b shipped. Rejected to avoid surprising existing wok users; suspend-family
  keeps the producer surface and reuses the tags. Re-litigate only if external familiarity is
  judged to outweigh wok-internal stability.
- **General second-class one-shot arrow.** The principled way to let users write their *own*
  carrier-capturing eliminators, but it adds a new arrow flavor across unification/inference/
  kinding plus carrier + multiplicity extensions — and it is unnecessary here because the `case`
  surface binds the tail in an arm, not a closure. YAGNI for real generator code (zip/take/merge
  are fixed-arity and compose out of `step`). Deferred; promote only on a concrete need.
- **Keeping the CPS `step` (4b′ form).** Rejected: it is what *creates* the multi-future capture
  problem, and it reads worse than `case`. Replaced wholesale (4b′ merged minutes earlier; ~zero
  downstream usage).
- **`Done`/`Yield` constructor names.** Consumer-intuitive (JS `done`, universal `yield`) but they
  match neither the producer op (`suspend`) nor the runtime tags (`Suspended`/`Completed`) — two
  new words for settled events. Rejected for coherence; `Completed`/`Suspended` chosen.
- **Materialized `Step` always vs CPS fusion.** Moot under §4: `Step` *is* the runtime VCon
  `resume` already builds, so there is nothing to fuse or materialize separately.
- **Keeping `value` / `Future`.** `value` is redundant once `Suspended x g'` binds the yield;
  `Future` means async-single-result everywhere else. Both changed.

## 12. Implementation outcome (2026-06-10, `feat/slice-4c-step-adt`, pending review)

Five tasks, 687 tests green. The design held; two things the plan under-specified surfaced and were
fixed (both validated in review as sound):

1. **Carrier-producer exemption (type checker).** `step s v = __coro_resume s v` returns an
   *inline-produced* `Step`, which the Task-2 escape rule (correctly) rejects for user code. So a
   function whose **declared result type is an affine carrier** is allowed to produce one at its
   **body tail** (single-level; sub-positions like list/tuple still fire `CarrierEscape`), **gated
   to `Embedded` (prelude) origin** — the same trust boundary as `extern`. User code returning an
   inline carrier is still rejected. This is the direct analogue of 4b's `ctxHandlerArm` exemption.
2. **`Suspension` is the bare continuation.** In 4c the `g'` of `Suspended x g'` is the parked
   continuation `k` (the VCon's second field), not the whole VCon as `Future` was in 4b — so
   `__coro_resume` applies a bare `VCont` directly. The plan's "prim impls unchanged" was wrong on
   this one point.

Also: `__coro_unwrap` now **errors** on a `Suspended` shape (so `run` on a re-suspending producer
fails loudly instead of returning garbage); the dead `value` reader-trust set was cleared
(`preludeReaderNames = Set.empty`).

**Known limitation (recorded, NOT exploitable today).** Field projection (`b.f`) launders a carrier
past both the carrier-escape and affine analyses (`TProj` is not a direct-escape form and not an
inline `TApp`). It is **uninhabitable today** because no base case can put a carrier into a
constructor/record field (every such construction is itself a rejected non-allowed position). It
only becomes live if a future feature lets a carrier into a field (or via a cross-module value). On
record before any such feature lands.

The multi-future interleaving limitation from 4b′ is **resolved**: `coro-step-zip` (two producers
zipped via nested `case`) type-checks and runs (→ 52). The `future-step-multi-future-interleave`
tripwire was promoted to that passing run-example.
