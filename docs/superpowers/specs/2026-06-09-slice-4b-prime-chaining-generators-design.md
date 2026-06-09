# Slice 4b′ — chaining / consumer-driven generators (the `step` *function*)

Date: 2026-06-09
Status: **Implemented** on `feat/slice-4b-prime` (pending full-branch review before merge to
`main`). Follow-on to slice 4b (merged: `2026-06-09-one-shot-escape-design.md`). Shipped direction:
a **library function**, no surface-language change. Named-arm syntax sugar is explicitly
**deferred** (§9, §11). **A limitation surfaced during implementation:** multi-future interleaving
(zip/merge) is currently REJECTED by the conservative carrier rule — see §2 and §13. Single-future
consumer-driven pull works and is validated.

Reads with: `2026-06-09-one-shot-escape-design.md` (slice 4b — the single-shot escape this
extends; esp. the Task 0 decision note in §5.2 and §9's deferred-list entry for 4b′), memory
`effects-slice-4b-one-shot-escape` (the shipped mechanism + the load-bearing findings),
`prelude/Std/Control.wok` (the `Coro`/`Future`/`__coro_*` surface this extends),
`examples/generators.wok` (the EXISTING push-model generator, to contrast against).

## 1. Summary

Slice 4b's `resume : Future a b r -> b -> r` runs a parked producer to completion — it assumes
**one** suspension. A producer that suspends *repeatedly* (a generator yielding a stream) cannot
be driven: `resume` is typed to return the final `r`, so a re-suspension produces a malformed
value and a runtime crash (the documented "re-suspension is unguarded" limitation).

4b′ adds a **`step`** combinator that resumes a future **once** and dispatches on whether the
producer **completed** or **suspended again**, binding the tail future **second-class** in the
yield branch. This is the **pull / consumer-driven** iterator: the consumer controls the pace,
pulls one value at a time, and interleaves its own logic between pulls — which the existing
push-model in-arm handler (`examples/generators.wok`) cannot express.

The committed shape is a **plain higher-order library function** (a Scott/Church-encoded
eliminator), NOT new grammar:

```wok
step : Future a b r -> b -> (r -> t) -> (a -> Future a b r -> t) -> t
```

The two branches are passed as callbacks; the tail future `s'` is the second-class parameter of
the yield callback. This keeps wok's language grammar untouched — coroutines stay a *library*
(the Lua discipline, §4) — while preserving the static safety the slice exists to buy (§5).

The decisive enabling fact (from the 4b spike): **the runtime already chains for free** — deep
re-install re-captures on each re-suspension and produces `VCon "Suspended" [a', k']` /
`VCon "Completed" [r]`. So 4b′ is a **pure typing + library increment**: dispatch on the tag the
machine already produces, and bind the tail future second-class. No new runtime control machinery.

## 2. Push vs pull — why this isn't `generators.wok`

`examples/generators.wok` already does generators in the **push** model: the consumer IS the
handler (`Yield.yield x k -> [x] ++ k ()`), reacting to each yield as the producer drives. That
works and needs no escape, and it covers **fold-shaped** consumers (the running example's
`sumPulled` is, in fact, push-expressible).

4b′ is the **pull** model: the *consumer* drives. It holds "the rest of the producer" as a
second-class future between pulls and does arbitrary work between them (branch / filter / stop
early), threading the tail through its own recursion. This single-future form works and is
validated:

```wok
-- producer yields lo, lo+1, …, hi-1 (suspends once per value)
range : U64 -> U64 -> () with Coro U64 ()
range lo hi = case eqU64 lo hi of
  True  -> ()
  False -> let u = Coro.suspend lo in range (lo + 1) hi

-- consumer pulls, threading the tail future s' through its own recursion:
sumPulled : Future U64 () () -> U64
sumPulled s = step s () (\r -> 0) (\x s' -> x + sumPulled s')   -- s' : tail future, second-class
```

> **LIMITATION (surfaced in implementation; deferred).** The naturally-distinguishing pull case —
> **zip/merge of two producers**, where the consumer holds two live futures and picks the order —
> is **currently REJECTED** by the conservative carrier rule, and this is **inherent to the CPS
> form**. To step a second future you must reference it inside the first's `onYield` callback (the
> tail `a'` is only bound there), so that callback **closure captures a second-class future**,
> which the carrier rule forbids in a non-handle continuation slot (`CarrierEscape`). Crucially,
> the deferred named-arm sugar would **not** fix this (it desugars to the same capturing closure);
> only a **carrier-rule relaxation** (permit a *non-escaping* future-capturing closure in a
> continuation slot) or the rejected second-class-sum `case` form would. This is locked as a
> tripwire golden `future-step-multi-future-interleave` (expects `CarrierEscape "zipSum"`) and is
> the motivating case for a follow-up slice (§13). Note that single-future pull is largely
> push-expressible, so multi-future interleaving is the capability that most distinguishes pull
> from push — hence this limitation is material, not cosmetic.

```wok
-- the genuinely-pull case (CURRENTLY REJECTED — CarrierEscape "zipSum"; see the LIMITATION above):
zipSum : Future U64 () () -> Future U64 () () -> U64
zipSum a b =
  step a () (\ra -> 0)
    (\xa a' -> step b () (\rb -> 0)
                 (\xb b' -> (xa + xb) + zipSum a' b'))   -- closure captures `b` -> CarrierEscape
```

## 3. The design — function-only

### 3.1 The dispatch prim (`src/Wok/Interp/Prim.hs`)

A small bodyless prim beside the existing `coroResumeP`/`coroUnwrapP`. It dispatches a
*resumed* future on the tag the machine already produces and applies the matching callback:

```haskell
-- | `__coro_step s onDone onYield` dispatches a resumed future on its tag.
-- `Completed [r]` applies `onDone r`; `Suspended [x, k]` applies `onYield x s'`,
-- where s' is the SAME Suspended future re-handed to the consumer as the tail.
coroStepP :: Prim
coroStepP = mkPrim (Tx.pack "__coro_step") 3 $ \args -> case args of
  [VCon t [r], onDone, _]
    | t == Tx.pack "Completed"  -> Right (PRApply onDone [r])
  [s@(VCon t [x, _]), _, onYield]
    | t == Tx.pack "Suspended"  -> Right (PRApply onYield [x, s])
  [s, _, _] -> Left (PrimError (Tx.pack "__coro_step: not a future: " <> renderValue s))
  _         -> Left (ArityError (Tx.pack "__coro_step"))
```

`onYield x s` re-hands `s` (the whole `Suspended[x,k]` value *is* the tail future), so
`value`/`resume`/`step` all keep working on it unchanged — no fresh allocation.

### 3.2 The prelude function (`prelude/Std/Control.wok`)

Two lines beside the existing coro wrappers. `step` resumes one layer (reusing the existing
`__coro_resume`) and dispatches:

```wok
-- __coro_step decouples the answer type `t` from the future's `r` (the two
-- branches agree on `t`, independent of the producer's result type).
extern __coro_step : Future a b r -> (r -> t) -> (a -> Future a b r -> t) -> t

-- `step` resumes the parked continuation ONCE with `v`, then dispatches: the
-- producer either completed (onDone r) or suspended again (onYield x s'), where
-- s' is the tail future, second-class. The total, generator-safe counterpart of
-- `resume`. `step` consumes its input future (it is passed as an argument, so the
-- existing affine rule counts it); s' is consumed by whatever the onYield branch
-- threads it into.
step : Future a b r -> b -> (r -> t) -> (a -> Future a b r -> t) -> t
step f v onDone onYield = __coro_step (__coro_resume f v) onDone onYield
```

That is the entire compiler-side delta: **one prim, one extern signature, one wrapper.** No
grammar, no BNFC regen, no new carrier or affine rule, no new error type.

### 3.3 `value`, `resume`, `start` coexist (unchanged from 4b)

- `value : Future a b r -> a` still reads the current yield (non-consuming). `start` runs to the
  first suspend, so the first yield is read via `value`; `step` advances to the next.
- `resume : Future a b r -> b -> r` is KEPT for the single-shot convenience case (with its
  documented crash-on-re-suspend). `step` is the total, generator-safe form, recommended for
  anything that may suspend more than once.

### 3.4 Carrier + affine — reused with (likely) zero changes

Because `step` is a function and `s'` is a lambda parameter, the existing binder-keyed analyses
apply directly:

- **Carrier (second-classness).** `s'` is a `Future`-typed lambda parameter, so
  `isHandleType (CTCon TcFuture _)` (`Carrier.hs:349`) already makes it second-class; it may be
  threaded through recursion as a handle-arg but never returned, listed, stored, or captured by
  an escaping closure. Violation = the existing `CarrierEscape`.
- **Affine (consume-once).** The existing conservative rule — *"a `Future` passed as an argument
  to ANY function consumes it, except the `value` reader"* — already covers `step`: `step f …`
  consumes `f` (one consumption, like `resume`/`cancel`/a helper); the fresh `s'` is consumed in
  turn by whatever the yield branch threads it into. The generator pattern recurses on the
  **fresh tail** `s'`, never reusing the old `s`, so each future is consumed exactly once and the
  existing `checkFutureAffine` admits it. (Contrast `future-recursive-consume.wok`, which reuses
  the *same* future in a loop and is correctly rejected.)

The single thing to verify on day one (a check, not a design risk): that `checkFutureAffine` and
the carrier walk descend into **lambda bodies** so the `s'` param in `\x s' -> …` is tracked the
same as a top-level clause binder. The analyses are binder-keyed, so this should hold; it is the
first test to write.

> **CONFIRMED (implementation, 2026-06-09).** Both walks already descend into `TLam` bodies — the
> affine walk (`Carrier.hs:574`, `TLam pats body -> introducedBy … body >> walk … body`) and the
> carrier-escape walk (`Carrier.hs:215`, `TLam pats body -> check ctx (bindPats env pats) False
> body`). So the `s'` lambda param is tracked with **no new rule**: `future-step-tail-twice`
> rejects with `FutureConsumedTwice "s'"` and `future-step-tail-escapes` with `CarrierEscape
> "grab"`, while `coro-step-range` (recursing on the fresh tail) is accepted. `Multiplicity.hs`
> was **untouched** (`step` hands no continuation to anything — capture stays inside the producer's
> already-trusted `__coro_susp`). The zero-new-rules, no-grammar, no-new-error-type assumption
> held in full. The *only* discovery beyond the plan was the multi-future carrier limitation
> (§2 LIMITATION / §13) — a real expressiveness boundary, not a new rule.

### 3.5 Runtime

No new control machinery. `step` is: apply the parked continuation to the resume value (reuse the
`__coro_resume` path → the machine's deep re-install re-captures on re-suspend), then dispatch on
the result tag in `__coro_step` — `Completed [r]` → `onDone r`; `Suspended [x, k]` → `onYield x s`.

## 4. Why a function, not syntax — the Lua pressure-test

Lua is the canonical proof that coroutines need **zero language syntax**: they are a *library*
(`coroutine.create/resume/yield/status/wrap`), and the only iteration *syntax* Lua has (`for-in`)
is **general** (any iterator plugs in), never coroutine-specific. Lua can be syntax-free because
it is (1) dynamically typed (the yield payload and the return payload share one untyped slot),
(2) built on a **mutable, reused** handle (`resume` mutates `co` in place — there is no *tail*
value to type), and (3) dispatches **out of band** (`status`, or a `nil` sentinel).

wok deliberately gave up all three: it is statically typed (the payload slot needs a type),
futures are immutable + affine (each step **mints a new tail value**), and the whole point of 4b
was to make "you read the wrong thing" a *type* error, not a runtime one. The consequence is a
**correlation trilemma** — to bind `r` only when done and `x, s'` only when yielded, in a typed,
`null`-free language, you must pick one of:

| approach | language grows? | second-class sum? | safe (payload correlated with tag)? |
|---|---|---|---|
| payload-carrying sum + `case` (`Done r \| Yield a (Future …)`) | no | **yes** (needs carrier rules) | yes |
| **eliminator / CPS — the `step` function** | **no** | **no** | **yes** |
| named-arm grammar (`step … of done/yield`) | **yes** (special-purpose) | no | yes |
| Lua-style `status` + `case` (decorrelated) | no | no | **NO — partial `value`/`result` readers reintroduce runtime crashes** |

The `step` function is the only row that is **both zero-language-growth and safe**, and it is
also the smallest library delta. The callback shape is not ceremony — it is the one mechanism
(binder scoping in place of a stored sum) that buys back the static safety Lua simply does not
have. This is wok's faithful "coroutines are a library": the grammar is untouched exactly as
Lua's is; the capability lives in `Std.Control` exactly as Lua's lives in `coroutine.*`.

**Forward rule (the Lua lesson for spec size):** if generator sugar is ever wanted, follow Lua —
invest the one syntactic production at the **general iterator-protocol** level (a `for`/unfold
that any producer plugs into), NOT a coroutine-specific `step … of` eliminator. A special-purpose
syntactic form for one library type is exactly the per-feature growth that makes a language spec
big; it is the thing Lua pointedly refuses. The named-arm sugar is therefore deferred (§9) and,
if pursued, redirected to a general construct designed on its own merits with multiple producers
in hand.

## 5. Compilation errors — no new error type

Every misuse of `step` reduces to "a `Future` passed to a function" or "a `Future` that escapes,"
which the existing analyses already diagnose. **`Error.hs` does not change.** Errors render as a
`Show` of the constructor, named by the offending binding; the source span is `Nothing` (a
pre-existing typed-AST limitation, identical for any surface form, so the function form costs
nothing here). Affine errors name the offending **future variable**; carrier escapes name the
**enclosing binding**.

The four negatives and their exact rendered errors (each backed by an existing golden of the same
shape):

```wok
-- input future consumed twice  (cf. future-helper-double-consume.wok)
twice s = step s () (\r->0) (\x s'->x) + step s () (\r->0) (\x s'->x)
--   => typecheck in Main: FutureConsumedTwice Nothing "s"

-- tail future consumed twice  (lambda param is binder-keyed, name survives)
badTail s = step s () (\r->0) (\x s' -> step s' () (\r->0) (\y t->y)
                                      + step s' () (\r->0) (\y t->y))
--   => typecheck in Main: FutureConsumedTwice Nothing "s'"

-- tail future escapes its scope  (cf. future-escapes-return.wok)
grab : Future U64 () () -> [Future U64 () ()]
grab s = step s () (\r->[]) (\x s' -> [s'])
--   => typecheck in Main: CarrierEscape Nothing "grab"

-- re-performs an unhandled effect after suspend  (cf. future-reperform-unhandled.wok)
--   => typecheck in Main: RowMismatch Nothing CREmpty (CRExtend "Log" …)
```

And the generator pattern itself **passes**, because it recurses on the fresh tail `s'` (each
future consumed once), while the reuse-the-same-future loop is correctly rejected — the
`future-recursive-consume.wok` golden is the existing proof that the discriminating line is
"new tail vs reused handle," precisely where generators live.

**Two honest caveats** (both minor, both orthogonal to this slice):
1. **Arm type/arity mismatches are generic.** Disagreeing branch result types give a unification
   error phrased via `step`'s type variable `t`, not a bespoke "the done and yield branches must
   agree." Normal ML-grade; a grammar form could mint friendlier messages, deferred with the sugar.
2. **Message polish is raw `Show`** for *all* wok diagnostics, not a `step` issue. A `TypeError`
   pretty-printer + typed-AST span tracking would lift every error at once; noted as a separate
   future improvement, not coupled here.

## 6. Type correctness

`step` is answer-type-preserving (both branches : `t`), HM-principal, rank-1 (the callbacks are
first-order: `r -> t` and `a -> Future a b r -> t`), and row-polymorphic — it is the
asymmetric-coroutine `resume`-with-dispatch. The `Future a b r` recurrence in the yield branch is
the same tycon at the same args. `t` is decoupled from the future's `r` (the two branches unify
on `t`). No new inference complexity, no rank-2.

## 7. Scope

**IN (shipped):** the `step` function (the `__coro_step` prim + extern signature + the
`Std.Control` wrapper); `s'` second-class + affine via the existing carrier/affine machinery
(confirmed to descend into lambda bodies, §3.4); the single-future pull-generator example
(`coro-step-range`, → 10); the three step typecheck-fail goldens (input-twice / tail-twice /
tail-escapes); the multi-future limitation tripwire golden (`future-step-multi-future-interleave`,
→ `CarrierEscape "zipSum"`); keep `value`/`resume`/`start`/`cancel` as-is. (Two example files with
a local helper `step` were renamed to `tick` to avoid colliding with the new prelude name:
`test/run-examples/46-std-control-mtl.wok` and `examples/mtl-machine.wok` — the latter caught by
the final full-branch review since `examples/` is not scanned by CI; see §13. A repo-wide sweep
confirmed no other `Std.Control`-importing file defines a top-level `step`.)

**OUT (deferred):**
- **Multi-future interleaving (zip/merge)** — REJECTED today by the conservative carrier rule
  (callback closure captures a second-class future, §2 LIMITATION). Lifting it needs a
  carrier-rule relaxation (permit a *non-escaping* future-capturing closure in a continuation
  slot) — a follow-up slice, now motivated by the tripwire golden. This is the most consequential
  deferral (it is the capability that distinguishes pull from push).
- **Named-arm syntax sugar** (`step … of done/yield`) — deferred; note it would NOT lift the
  multi-future limitation (it desugars to the same capturing closure). If pursued, redirected to a
  *general* iterator-protocol construct (§4).
- The residual-row obligation / capability-reconstruction-by-type (that is 4b″, independent).
- Making `resume` itself total (it stays the single-shot convenience form).
- A nameable first-class `Step` value / payload-carrying sum (§4 — reintroduces a second-class sum;
  note it WOULD lift the multi-future limitation since the tail binds in a `case` arm, not a closure).
- The I1 prelude-name-shadowing fix (a `Pipeline.hs` provenance change) — left deferred per the
  4b spec's "separate fix" note; this slice sidestepped the `step` collision by renaming the one
  example helper (§13).
- Any scheduler / readiness / racy interleaving runtime (layer 3).
- Diagnostic polish (span tracking, `TypeError` pretty-printer) — orthogonal, benefits all errors.

## 8. Resolved questions (formerly open)

- **Fused eliminator vs nameable `Step` value vs function** → **function** (§3, §4). No
  second-class sum; no grammar.
- **Surface syntax for the eliminator** → **none** for 4b′; the function is the surface. Sugar
  deferred and redirected to a general iterator protocol (§4, §7).
- **Should `step` subsume `resume`?** → **no**, keep both (`resume` = single-shot convenience;
  `step` = total form). Additive.
- **First-yield asymmetry** → confirmed intended: `value` reads the first yield (post-`start`),
  `step` advances to subsequent ones.
- **Naming** → `step`, with callback parameters conventionally `onDone`/`onYield` (free to rename
  at call sites; they are ordinary lambdas).

## 9. Testing (as shipped)

- **Passing run-example:** `coro-step-range` — a range-style producer driven by `sumPulled`
  (consumer recursion on the fresh tail), asserts `10`. Back-compat: `coro-escape` (421) and
  `coro-multi-driver` (64) still run; `examples/generators.wok` (push model) unaffected.
- **typecheck-fail goldens (three step-specific, run-confirmed before accept):**
  `future-step-input-twice` → `FutureConsumedTwice "s"`; `future-step-tail-twice` →
  `FutureConsumedTwice "s'"` (the lambda-descent confirmation); `future-step-tail-escapes` →
  `CarrierEscape "grab"`. The unhandled-reperform case is the *pre-existing*
  `future-reperform-unhandled` (start-row check) — NOT duplicated.
- **Limitation tripwire:** `future-step-multi-future-interleave` → `CarrierEscape "zipSum"` locks
  the deferred multi-future boundary; when a carrier-relaxation slice lands, this golden will flip
  (start type-checking) and must be promoted to a passing run-example.
- Test count: 681 (4b merge) → 689 green.

## 10. Build / verify

`cabal build`; `cabal test` (689 green); `cabal run -v0 wok -- <file> --run`. **No grammar
change**, so no BNFC regen and the shift/reduce count stays 32. Full-branch review before merge to
`main`.

## 11. Rejected alternatives (with reasons, for deliberate re-litigation)

- **Named-arm grammar `step … of done/yield`.** Rejected for 4b′: it is a *special-purpose*
  syntactic form for one library type — genuine language-spec growth, and exactly what Lua's
  discipline refuses (§4). The function form is byte-for-byte equivalent in soundness diagnostics
  (§5). Deferred; if ever pursued, as a *general* iterator construct.
- **First-class `Step a b r = Done r | Yield a (Future a b r)` value + `case`.** Rejected: the sum
  holds a second-class `Future`, making it a second-class sum needing its own carrier rules —
  heavier, not lighter (§4 trilemma).
- **Lua-style decorrelated `status` + `case` (`status`/`result`/re-typed `resume`).** Rejected
  despite being the most Lua-looking: typed decorrelation reintroduces partial `value`/`result`
  readers (a runtime `PrimError` on misuse) — the exact crash 4b exists to abolish — and is the
  *largest* library delta of the live options (§4).
- **Re-typing `resume` to return the next future.** Rejected: breaks 4b's `resume : … -> r`
  back-compat. `step` is additive instead.
- **Fixing I1 (prelude-name shadowing) inside this slice.** When the new prelude `step` collided
  with the local `step` in `46-std-control-mtl.wok`, an early implementation bundled a
  `Pipeline.hs` binding-provenance fix (make a redefining module own the name). **Reverted** to
  keep the slice tight: I1 is a deliberately-deferred limitation (per the 4b spec's "separate fix"
  note) and the fix touches shared provenance infra (the same `envVarOrigin` the diamond-import
  conflict detection keys on). Sidestepped by renaming the example helper `step → tick`. The
  principled I1 fix remains a separate future slice.
- **Carrier-rule relaxation to allow multi-future interleaving — IN this slice.** Not attempted:
  it is a real type-analysis change (permit a non-escaping future-capturing closure in a
  continuation slot) needing its own soundness design, far beyond "add a combinator." Deferred and
  motivated by the `future-step-multi-future-interleave` tripwire (§2 LIMITATION, §7). This is the
  genuinely valuable follow-up — it is what makes `step` earn its keep over the push handler.

---

## 12. Implementation outcome (2026-06-09, `feat/slice-4b-prime`, pending review)

Five commits: (1) `__coro_step` prim + unit tests; (2) `Std.Control` `step` wrapper + extern +
`coro-step-range` example (+ `step → tick` rename in the mtl example); (3) three step
typecheck-fail goldens; (4) the multi-future limitation tripwire golden; (5) this spec/memory
update. 689 tests green. The design held with **zero new typing/grammar/error machinery**
(§3.4 CONFIRMED). The one substantive discovery is the **multi-future carrier limitation** (§2):
single-future consumer-driven pull works; zip/merge is deferred to a carrier-relaxation slice.

---

## Kickoff prompt (paste into a fresh session)

```
Work on slice 4b′ for the wok language (repo /Users/zy/wokml): CHAINING / CONSUMER-DRIVEN
GENERATORS via a `step` LIBRARY FUNCTION (no grammar change), extending the merged slice 4b
(one-shot escaping continuation). Branch from main first (feat/slice-4b-prime). Standing rules:
FULL-BRANCH review before any merge to main; I prefer clarifying questions in prose.

Brainstorming is DONE (see the design doc). START with writing-plans, THEN
subagent-driven-development. TDD.

COMMITTED DESIGN (function-only; syntax sugar DEFERRED on purpose — prove the library form
encapsulates the abstraction before spending grammar on it):
- Prim `__coro_step : Future a b r -> (r -> t) -> (a -> Future a b r -> t) -> t` in
  src/Wok/Interp/Prim.hs: dispatch a resumed future — Completed[r] -> onDone r;
  Suspended[x,k] -> onYield x (the same Suspended value as the tail s').
- Prelude (prelude/Std/Control.wok):
    extern __coro_step : Future a b r -> (r -> t) -> (a -> Future a b r -> t) -> t
    step : Future a b r -> b -> (r -> t) -> (a -> Future a b r -> t) -> t
    step f v onDone onYield = __coro_step (__coro_resume f v) onDone onYield
- KEEP value/resume/start/cancel from 4b. resume stays single-shot convenience; step is total.
- Carrier + affine REUSE with (likely) ZERO new rules: s' is a Future-typed LAMBDA param
  (second-class by isHandleType already); `step` consumes its input future by the existing
  "future passed as an argument consumes it" rule. The generator recurses on the FRESH tail s'
  (each future consumed once) so it passes; reuse-the-same-future is rejected
  (future-recursive-consume.wok proves it). DAY-ONE CHECK: confirm checkFutureAffine + the carrier
  walk descend into lambda bodies so the s' param is tracked.
- NO new error type: misuses reduce to FutureConsumedTwice / CarrierEscape / RowMismatch (Error.hs
  unchanged). Four typecheck-fail goldens (§5 of the design).

KEY ENABLING FACT (4b spike, in 2026-06-09-one-shot-escape-design.md §5.2): the runtime ALREADY
chains for free — deep re-install re-captures on re-suspend, producing VCon "Suspended" [a',k'] /
VCon "Completed" [r]. So 4b′ is a PURE TYPING + LIBRARY increment; NO new runtime control machinery.

OUT OF SCOPE: named-arm syntax sugar (deferred; if ever, a GENERAL iterator protocol, not a
coro-specific eliminator); residual-row obligation (4b″); making resume total; first-class
Step/payload-carrying sum; scheduler/interleaving runtime (layer 3); diagnostic span/pretty-print
polish (orthogonal).

READ FIRST: docs/superpowers/specs/2026-06-09-slice-4b-prime-chaining-generators-design.md (this
slice's design), 2026-06-09-one-shot-escape-design.md (slice 4b, esp §5.2 Task 0 note + §9),
memory effects-slice-4b-one-shot-escape, prelude/Std/Control.wok (Coro/Future/__coro_* surface),
examples/generators.wok (the push model to contrast), src/Wok/Interp/Prim.hs (the __coro_* prims),
src/Wok/Interp/Machine.hs (dispatchOp / deep re-install), src/Wok/TypeChecking/Carrier.hs
(isHandleType:349, checkFutureAffine), test/typecheck-fail-{examples,golden} (the future-* goldens
to mirror).

BUILD/TEST: cabal build; cabal test; cabal run -v0 wok -- <file> --run. NO grammar change (shift/
reduce stays 32). Full-branch review before merge.
```
