# Slice 4b — One-Shot Escaping Continuation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers-extended-cc:subagent-driven-development (recommended) or superpowers-extended-cc:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a second-class, affine `Future` — a runtime-held one-shot escaping continuation — so that an escaping coroutine that slice X rejects today type-checks and runs under a trivial synchronous resumer, with await-twice and scope-escape as static errors.

**Architecture:** A new built-in `Future` type (carrier-second-class, affine), a runtime-held continuation surfaced only as an opaque handle, and one trusted escape op certified `once` (the deferred `opMultiplicity` axiom). The continuation lives below the effect boundary; the user holds the handle. Reference semantics is the existing CEK machine's deep re-install.

**Tech Stack:** Haskell (GHC, Cabal), the wok CEK interpreter (`Wok.Interp.Machine`/`Value`), the ANF analyses (`Wok.IR.Multiplicity`), the type checker (`Wok.TypeChecking.{Infer,Carrier,Builtins}`), BNFC grammar (no change expected), golden tests (`test/Spec.hs`).

**Spec:** `docs/superpowers/specs/2026-06-09-one-shot-escape-design.md`.

**HARD RULE:** Task 0 is a STOP-GATE. Do not start Task 1+ until Task 0's decision note is written into the spec and the gate criterion passes. If Task 0 shows the primitive forces a *first-class* Future (rank-2 + linear types), STOP and surface it to the user — that reshapes the roadmap. Full-branch review before any merge to `main`.

---

## File Structure

| File | Responsibility | Tasks |
|---|---|---|
| `src/Wok/Interp/Value.hs` | `VFuture` value (or `VCon "Future"` convention) + a single-use guard | 0, 4 |
| `src/Wok/Interp/Machine.hs` | host-op hook in `dispatchOp` for the `Coro` capability; `start`/`resume`/`value` semantics | 0, 4 |
| `src/Wok/TypeChecking/Builtins.hs` | register `Future` tycon (arity 3) | 1 |
| `src/Wok/TypeChecking/Types.hs` (or wherever `TyCon` lives) | add `TcFuture` constructor | 1 |
| `src/Wok/TypeChecking/Infer.hs` | resolve `"Future"`; type `start`/`resume`/`value`; residual-row obligation; resume-xor-cancel | 1, 4, 5 |
| `src/Wok/TypeChecking/Carrier.hs` | `Future` is handle-like → second-class | 2 |
| `src/Wok/IR/Multiplicity.hs` | trusted-`once` sink for the escape op/prim | 3 |
| `prelude/Std/Control.wok` | `Coro` effect + `coro` runner + `start`/`resume`/`value` wok surface | 4 |
| `test/typecheck-fail-examples/` | the four required negatives | 2, 3, 5 |
| `test/run-examples/` + `test/golden/` | passing escape + multi-driver examples; `--dump-multiplicity` golden | 3, 4 |
| `examples/`, roadmap, memory | docs | 6 |

---

## Task 0: Spike — minimal escaping coroutine, end-to-end (STOP-GATE)

**Goal:** Get the single smallest escaping example to type-check and run under a synchronous resumer, resolving the three open mechanism questions, and record the decision in the spec. This de-risks the whole slice.

**The three questions to answer (empirically, in code):**
1. **Host-op hook shape.** How does `dispatchOp` hand a `Coro` op to host code? (Hypothesis: a reserved-label branch `lbl == "Coro"` before `lookupOpArm`, or an `hNative` field on `Handler`. Pick the smaller diff.)
2. **Future value representation.** Hypothesis: `VCon (Tx.pack "Future") [yieldedVal, VCont k]` — no new constructor. Confirm it round-trips through `enter`/`returnTo` and `renderValue`.
3. **Resume semantics vs deep re-install (spec §5.2 crux).** Because `dispatchOp` re-installs the whole handler on resume, confirm what happens when the resumed producer performs `Coro.suspend` *again*. Decide and record: (a) single-shot only — re-suspension is a runtime/type error for now; or (b) chaining falls out — `resume` yields another future and we embrace generators early. **Write the answer into spec §5.2 as a decision note.**

**Files:**
- Modify: `src/Wok/Interp/Machine.hs:157-201` (`dispatchOp`) — add the host-op branch.
- Modify: `src/Wok/Interp/Value.hs:48-77` (`Value`) — only if the spike shows `VCon` reuse is insufficient.
- Create (scratch, deleted at task end): `/tmp/coro-spike.wok`.
- Modify: `docs/superpowers/specs/2026-06-09-one-shot-escape-design.md` (§5.2 decision note).

**Acceptance Criteria (the GATE):**
- [ ] A scratch program with a producer that suspends once and a driver that resumes once type-checks and runs to the expected value under `--run`.
- [ ] The resume re-establishes the coro handler (capability reconstruction observed: an effect performed after the suspend point is handled).
- [ ] The §5.2 decision (single-shot carve-out vs chaining-for-free) is written into the spec with the observed machine behavior.
- [ ] If no second-class realization works without first-class Futures: STOP, write the finding, do not proceed.

**Verify:** `cabal build && cabal run -v0 wok -- /tmp/coro-spike.wok --run` → prints the expected number (e.g. `421`).

**Steps:**

- [ ] **Step 1: Write the scratch example first (defines the target surface).**

Use the lowest-surface form — plain functions, no dot, no prelude wiring yet. Inline the capability so the spike touches only the machine:

```wok
module Main
import Std.Base

effect Coro a b = { suspend : a -> b }

producer : () -> U64 with Coro U64 U64
producer _ = (Coro.suspend 42) + 1

main : U64
main =
  with coro in
    let s = start producer in     -- start : (() -> r with Coro a b) -> Future a b r
    resume s (value s * 10)        -- value s = 42 ; resume runs producer's tail -> 421
```

`coro`, `start`, `resume`, `value` do not exist yet — Steps 2-5 make exactly this run. If wiring a prelude `Coro` is too heavy for the spike, hardcode the capability label in `dispatchOp` and stub `start`/`resume`/`value` as primitives registered in the prim table; the goal is a running skeleton, not clean code.

- [ ] **Step 2: Add the host-op branch in `dispatchOp`.**

In `src/Wok/Interp/Machine.hs`, before the `lookupOpArm` path, branch when the operation belongs to the built-in capability. Concretely, intercept `start`/`resume`/`value` (by label/op name) and implement:
- `start`: install the coro delimiter, run the thunk; on the producer's `suspend x`, capture `above` as the continuation `k`, build the future `VCon "Future" [x, VCont (\after -> above (KHandle h hTag hsc after))]`, and resume `start`'s own continuation (`kBelow`) with that future value.
- `value`: return the head of the future's payload.
- `resume`: apply the future's stored `VCont` to the resume argument under the current kont (reuse `enter`/`PRApply`).

Quote the current capture machinery you are reusing (Machine.hs:193-198):

```haskell
resumeVal = case hParam h of
  Nothing ->
    VCont (\after -> above (KHandle h hTag (answerRebind after hsc) after))
  Just pb -> ...
```

The future's continuation is built the same way — the only difference is it is stored in a value instead of bound to an arm's resume binder.

- [ ] **Step 3: Build and run the scratch program.**

Run: `cabal build && cabal run -v0 wok -- /tmp/coro-spike.wok --run`
Expected: `421` (or, if the multiplicity/carrier checks reject it first, observe the rejection — that tells you which later task must relax which rule; note it but for the spike you may bypass the checks via `Pipeline.elaborateProgramFull` without `analyzeModule`).

- [ ] **Step 4: Probe the re-suspend behavior (the §5.2 crux).**

Add a temporary second `Coro.suspend` in `producer` after the first and re-run. Observe whether the re-installed handler re-captures (chaining) or errors. Record the exact behavior.

- [ ] **Step 5: Write the decision note into the spec and clean up.**

Append to spec §5.2 the observed behavior and the committed direction (single-shot carve-out vs chaining-for-free), and whether `start`/`resume`/`value` are host ops vs prims. Delete `/tmp/coro-spike.wok`.

```bash
rm -f /tmp/coro-spike.wok
git add src/Wok/Interp/Machine.hs src/Wok/Interp/Value.hs docs/superpowers/specs/2026-06-09-one-shot-escape-design.md
git commit -m "spike(4b): minimal escaping coroutine runs; record resume-semantics decision"
```

---

## Task 1: Register the `Future` type

**Goal:** `Future a b r` is a known built-in tycon, so types mentioning it parse and check.

**Files:**
- Modify: `src/Wok/TypeChecking/Builtins.hs` (the `tyConEntries` list, ~line 33-38 where `U64`/`[]`/tuples register).
- Modify: the `TyCon` enum (search for `TcNever`/`TcU64`) — add `TcFuture`.
- Modify: `src/Wok/TypeChecking/Infer.hs` `resolveTyCon` (~745-755) — map `"Future"` → `TcFuture`.
- Test: `test/typecheck-examples/` (a positive type-checks case) or a unit test in `test/Spec.hs`.

**Acceptance Criteria:**
- [ ] A signature `f : Future U64 U64 U64 -> ()` type-checks (no `UnknownTyCon`).
- [ ] `Future` has kind `* -> * -> * -> *` / arity 3.

**Verify:** `cabal test` (new positive case green).

**Steps:**

- [ ] **Step 1: Add `TcFuture` to the `TyCon` enum.**

Find the enum holding `TcU64`, `TcString`, `TcNever`, `TcList`, tuple cons. Add:

```haskell
  | TcFuture          -- second-class one-shot escaping continuation handle (slice 4b)
```

Update any exhaustive `case` over `TyCon` the compiler flags (renderer, kind lookup) — follow what `TcNever`/`TcList` do.

- [ ] **Step 2: Register in `Builtins.hs`.**

Mirror the `[]` (list, arity 1) entry; `Future` is arity 3:

```haskell
  , (Tx.pack "Future", TyConInfo { tciKind = kArr3, tciArity = 3, tciCons = [] })
```

where `kArr3 = KArrow KStar (KArrow KStar (KArrow KStar KStar))` (define inline if no helper exists, following the existing list/tuple kind construction).

- [ ] **Step 3: Resolve the name in `Infer.hs:resolveTyCon`.**

Add the case alongside the existing string→TyCon mappings:

```haskell
    Tx.pack "Future" -> Just TcFuture
```

- [ ] **Step 4: Add a positive type-checks test and run it.**

Create `test/typecheck-examples/future-type-mentions.wok`:

```wok
module Main
import Std.Base
ignore : Future U64 U64 U64 -> ()
ignore _ = ()
main : U64
main = 0
```

Run: `cabal run -v0 wok -- test/typecheck-examples/future-type-mentions.wok` (print-schemes mode) → no error, `ignore` scheme prints.

- [ ] **Step 5: Commit.**

```bash
git add src/Wok/TypeChecking/Builtins.hs src/Wok/TypeChecking/Infer.hs test/typecheck-examples/future-type-mentions.wok
git commit -m "feat(4b): register built-in Future type (arity 3)"
```

---

## Task 2: Make `Future` second-class (carrier rule)

**Goal:** A `Future`-typed binding may only be used locally (let-RHS-through-name, dot/accessor receiver, handle-typed argument); returning/storing/listing it is a `CarrierEscape` error.

**Files:**
- Modify: `src/Wok/TypeChecking/Carrier.hs` (`isHandleType` ~292; the handle-slot predicate ~310-314).
- Test: `test/typecheck-fail-examples/future-escapes-return.wok` (+ `.expected`).

**Acceptance Criteria:**
- [ ] `isHandleType (CTCon TcFuture _)` is `True`.
- [ ] A function returning a `Future` → `CarrierEscape`.
- [ ] Storing a `Future` in a constructor/list → `CarrierEscape`.

**Verify:** `cabal test` (the `typecheck-fail` golden for the new case green).

**Steps:**

- [ ] **Step 1: Write the failing negative test first.**

`test/typecheck-fail-examples/future-escapes-return.wok`:

```wok
module Main
import Std.Base
effect Coro a b = { suspend : a -> b }
producer : () -> U64 with Coro U64 U64
producer _ = (Coro.suspend 42) + 1
leak : () -> Future U64 U64 U64
leak _ = with coro in start producer        -- Future returned out of its capability scope
main : U64
main = 0
```

- [ ] **Step 2: Run it; expect it to currently NOT error (red).**

Run: `cabal run -v0 wok -- test/typecheck-fail-examples/future-escapes-return.wok`
Expected before the fix: no `CarrierEscape` (the rule does not yet know `Future`).

- [ ] **Step 3: Extend `isHandleType`.**

In `Carrier.hs`, locate (verbatim shape):

```haskell
isHandleType :: CType -> Bool
isHandleType (CTCon (TcEffect _) _) = True
isHandleType _                      = False
```

Add the `Future` clause:

```haskell
isHandleType (CTCon (TcEffect _) _) = True
isHandleType (CTCon TcFuture _)     = True     -- slice 4b: Futures are second-class
isHandleType _                      = False
```

If the handle-slot predicate (allowed argument positions) separately matches `TcEffect`, mirror it for `TcFuture` so a `Future`-typed *argument* (incl. recursive-call arg) stays allowed.

- [ ] **Step 4: Capture the expected error and run green.**

Create `test/typecheck-fail-examples/future-escapes-return.expected` with the `CarrierEscape` message (run the command, copy the exact stderr). Run `cabal test` → the `typecheck-fail` group includes the new case, green.

- [ ] **Step 5: Commit.**

```bash
git add src/Wok/TypeChecking/Carrier.hs test/typecheck-fail-examples/future-escapes-return.wok test/typecheck-fail-examples/future-escapes-return.expected
git commit -m "feat(4b): Future is second-class via the carrier rule"
```

---

## Task 3: Trusted-`once` escape op + await-twice rejection

**Goal:** Handing the continuation to the trusted future-minting op is certified `1` (not `Many`), and resuming a future twice is a `MultishotResume` error.

**Files:**
- Modify: `src/Wok/IR/Multiplicity.hs` (the `cardRhs` `ROp`/`RApp` cases ~88; add a trusted-sink set).
- Test: `test/typecheck-fail-examples/future-await-twice.wok` (+ `.expected`); `test/golden/coro-escape.multiplicity.expected` (the `--dump-multiplicity` artifact).

**Acceptance Criteria:**
- [ ] The escape op/prim that captures the continuation is certified `1` in `--dump-multiplicity`.
- [ ] `resume s a + resume s b` (same future resumed twice) → `MultishotResume`.
- [ ] All existing multiplicity goldens stay green (no user-code rule change).

**Verify:** `cabal test` (multiplicity + new negative green).

**Steps:**

- [ ] **Step 1: Write the await-twice negative test (red).**

`test/typecheck-fail-examples/future-await-twice.wok`:

```wok
module Main
import Std.Base
effect Coro a b = { suspend : a -> b }
producer : () -> U64 with Coro U64 U64
producer _ = (Coro.suspend 42) + 1
main : U64
main =
  with coro in
    let s = start producer in
    resume s 1 + resume s 2          -- s resumed twice -> MultishotResume
```

- [ ] **Step 2: Add the trusted-sink recognition in `Multiplicity.hs`.**

The current rule (verbatim) rejects any escape into an op/call:

```haskell
ROp minst _ _ as -> if maybe False (mentionsAtom r) minst || mentionsAny r as
                      then Many else Zero
```

Introduce a trusted name set and treat passing `r` to it as `One` (one resume, by the runtime's guarantee). Use whatever the spike chose for the minting op/prim name (e.g. `__coro_future`):

```haskell
trustedOnce :: [Text]
trustedOnce = [Tx.pack "__coro_future"]   -- the trusted future-minting escape sink
```

and in the relevant `RApp`/`ROp` case, when the callee is in `trustedOnce` and `r` appears only as a direct argument, return `One` instead of `Many`. Keep every other path exactly as-is (no user-code change).

- [ ] **Step 3: Author the await-twice eliminator check.**

The affine eliminator counts `resume`/`await` applications per future binder. Implement the local count (conservative; reject on doubt) over the relevant binder, raising `MultishotResume` when a future is resumed more than once. Reuse the existing `MultishotResume` error constructor and the `addC`/`joinC` lattice.

- [ ] **Step 4: Add the passing `--dump-multiplicity` golden.**

Create `test/run-examples/coro-escape.wok` (the §3.2 producer/resume example) and `test/golden/coro-escape.multiplicity.expected` from `cabal run -v0 wok -- test/run-examples/coro-escape.wok --dump-multiplicity` (read the diff; the escape op shows `1`).

- [ ] **Step 5: Capture the negative `.expected` and run all green.**

Generate `test/typecheck-fail-examples/future-await-twice.expected`. Run `cabal test`.

- [ ] **Step 6: Commit.**

```bash
git add src/Wok/IR/Multiplicity.hs test/typecheck-fail-examples/future-await-twice.* test/run-examples/coro-escape.wok test/golden/coro-escape.multiplicity.expected
git commit -m "feat(4b): trusted-once escape op; reject await-twice"
```

---

## Task 4: The `coro` capability + passing examples (runtime hardened)

**Goal:** Promote the spike's machinery to a clean capability — `with coro in`, `start`/`resume`/`value` — and make the two passing examples (single-shot `421`, fixed multi-driver `64`) run via `--run` golden tests.

**Files:**
- Modify: `src/Wok/Interp/Machine.hs` (harden the host-op branch from Task 0; add the single-use guard if Task 0 chose single-shot).
- Modify: `src/Wok/Interp/Value.hs` (the guard field, if any).
- Modify: `prelude/Std/Control.wok` (declare `Coro`, the `coro` runner, and the `start`/`resume`/`value` wok-facing surface); wire as in Task-4a's `Std.Control` (already embedded).
- Modify: `src/Wok/TypeChecking/Infer.hs` (type `start`/`resume`/`value` and the residual-row obligation on `resume`, per spec §5.2).
- Test: `test/run-examples/{coro-escape,coro-multi-driver}.wok` + `test/golden/*.expected`.

**Acceptance Criteria:**
- [ ] `coro-escape.wok` runs → `421`.
- [ ] `coro-multi-driver.wok` (two futures held at once, resumed in chosen order) runs → `64`.
- [ ] Resuming re-establishes the capability (an effect performed in the resumed tail is handled).
- [ ] `resume`'s result type carries any effect the resumed tail re-performs (residual-row obligation); a re-performed effect with no handler at the resume site is a type error (covered in Task — see negative below).

**Verify:** `cabal run -v0 wok -- test/run-examples/coro-escape.wok --run` → `421`; likewise `coro-multi-driver.wok` → `64`.

**Steps:**

- [ ] **Step 1: Write both run-examples (targets).**

`test/run-examples/coro-multi-driver.wok`:

```wok
module Main
import Std.Base
effect Coro a b = { suspend : a -> b }
worker : U64 -> () -> U64 with Coro U64 U64
worker n _ = (Coro.suspend n) * 2
main : U64
main =
  with coro in
    let a = start (worker 10) in
    let b = start (worker 20) in
    resume b (value b + 1) + resume a (value a + 1)   -- 42 + 22 = 64
```

(`coro-escape.wok` already created in Task 3.)

- [ ] **Step 2: Declare the surface in `prelude/Std/Control.wok`.**

Add (mirroring the existing `state` runner shape and `Std.Control` wiring):

```wok
effect Coro a b = { suspend : a -> b }
-- start/resume/value are the driver surface over a runtime-held future.
-- coro installs the capability; the runtime parks/resumes the continuation.
```

Wire the exact wok signatures the spike settled (`start : (() -> r with Coro a b) -> Future a b r`, `resume : Future a b r -> b -> r`, `value : Future a b r -> a`). If they must be host primitives (likely), register them in the prim table and expose their schemes the way other builtins are exposed.

- [ ] **Step 3: Harden the host-op branch + add the single-use guard.**

Promote Task 0's scratch branch to a named helper `dispatchCoroOp` in `Machine.hs`. If Task 0 chose single-shot, add a runtime single-use guard on the future (a mutable/used flag in `VFuture`, or a debug-only assert per spec §6) so a second `resume` fails loudly in tests even though the law is the frontend gate.

- [ ] **Step 4: Type `start`/`resume`/`value` with the residual-row obligation.**

In `Infer.hs`, type `resume : Future a b r -> b -> r` such that the producer-tail's residual effects appear in `resume`'s row (capability reconstruction; spec §5.2). Reuse `inferHandler`'s arrow-with-row construction (`arrowT`).

- [ ] **Step 5: Run both examples and capture goldens.**

Run each with `--run`; confirm `421` and `64`. Add `test/golden/{coro-escape,coro-multi-driver}.expected` (run-output goldens) following the existing `run-examples` golden group in `test/Spec.hs`.

- [ ] **Step 6: Full suite + commit.**

```bash
cabal test
git add src/Wok/Interp/Machine.hs src/Wok/Interp/Value.hs prelude/Std/Control.wok src/Wok/TypeChecking/Infer.hs test/run-examples/coro-multi-driver.wok test/golden/coro-escape.expected test/golden/coro-multi-driver.expected
git commit -m "feat(4b): coro capability + start/resume/value; passing escape examples"
```

---

## Task 5: Type resume-xor-cancel + re-performed-effect negative

**Goal:** A future is consumed by `resume` *xor* `cancel` (≤1 total), typed now (cancellation runtime deferred); and a resumed tail that re-performs an unhandled effect is a type error.

**Files:**
- Modify: `src/Wok/IR/Multiplicity.hs` (count `cancel` alongside `resume` in the affine eliminator).
- Modify: `prelude/Std/Control.wok` (declare `cancel : Future a b r -> ()`, runtime = no-op/abort for now).
- Test: `test/typecheck-fail-examples/{future-resume-then-cancel,future-reperform-unhandled}.wok` (+ `.expected`).

**Acceptance Criteria:**
- [ ] `resume s v` then `cancel s` → `MultishotResume` (both eliminators counted).
- [ ] A producer whose tail re-performs an effect with no handler at the resume site → unhandled-effect type error.

**Verify:** `cabal test` (both negatives green).

**Steps:**

- [ ] **Step 1: Write both negatives (red).**

`test/typecheck-fail-examples/future-resume-then-cancel.wok`:

```wok
module Main
import Std.Base
effect Coro a b = { suspend : a -> b }
producer : () -> U64 with Coro U64 U64
producer _ = (Coro.suspend 42) + 1
main : U64
main =
  with coro in
    let s = start producer in
    let r = resume s 1 in
    let _ = cancel s in            -- second eliminator on an already-resumed future
    r
```

`test/typecheck-fail-examples/future-reperform-unhandled.wok`:

```wok
module Main
import Std.Base
effect Coro a b = { suspend : a -> b }
effect Log = { emit : U64 -> () }
producer : () -> U64 with Coro U64 U64 + Log
producer _ = let x = Coro.suspend 42 in let _ = Log.emit x in x   -- tail re-performs Log
main : U64
main =
  with coro in
    let s = start producer in
    resume s 1                      -- Log not handled at the resume site -> type error
```

- [ ] **Step 2: Declare `cancel` and count it in the eliminator.**

Add `cancel : Future a b r -> ()` to the surface (runtime: abort/drop the parked continuation; finalizer unwinding deferred). In `Multiplicity.hs`, include `cancel` in the per-future consumption count so `resume`+`cancel` on one future sums to `Many` → `MultishotResume`.

- [ ] **Step 3: Confirm the residual-row obligation fires.**

The `future-reperform-unhandled` case relies on Task 4's `resume` row typing: the tail's `Log` is in `resume`'s row and unhandled at the call site. If it does not yet error, tighten the `resume` row obligation in `Infer.hs` until it does.

- [ ] **Step 4: Capture `.expected` for both; run green.**

`cabal test`.

- [ ] **Step 5: Commit.**

```bash
git add src/Wok/IR/Multiplicity.hs prelude/Std/Control.wok src/Wok/TypeChecking/Infer.hs test/typecheck-fail-examples/future-resume-then-cancel.* test/typecheck-fail-examples/future-reperform-unhandled.*
git commit -m "feat(4b): type resume-xor-cancel; reject unhandled re-performed effect"
```

---

## Task 6: Examples, docs, memory

**Goal:** Ship a user-facing example, update the roadmap and memory, and (optionally) the `s.resume`/`s.value` dot ergonomics if the spike showed it cheap.

**Files:**
- Create: `examples/coroutine.wok` (commented, like `examples/generators.wok`).
- Modify: `examples/README.md`, `docs/superpowers/specs/2026-06-05-effect-handlers-ROADMAP.md` (slice-4b row → DONE/analysis-half), the multiplicity spec §7 cross-reference.
- Create/Modify: a memory file recording slice 4b's outcome; add a one-line pointer in `MEMORY.md`.
- Optional: `src/Wok/TypeChecking/Infer.hs` + elaboration for dot dispatch on `Future` receivers (`s.resume`/`s.value`), only if Task 0 showed it is a small change.

**Acceptance Criteria:**
- [ ] `examples/coroutine.wok` runs under `--run`.
- [ ] Roadmap slice-4b row reflects shipped scope (single-shot escape) and deferred (chaining/scheduler/box).
- [ ] Memory written; `MEMORY.md` pointer added.

**Verify:** `cabal run -v0 wok -- examples/coroutine.wok --run` succeeds; `cabal test` fully green.

**Steps:**

- [ ] **Step 1: Write `examples/coroutine.wok`** — the §3.2 escape + a comment explaining one-shot escape, second-class, and that the continuation lives below the boundary. Run it under `--run`.

- [ ] **Step 2: Update roadmap + multiplicity §7 cross-ref** — mark slice 4b's escape primitive shipped; note chaining/scheduler/`box` deferred; point §7's `opMultiplicity` "when it returns" line at this slice.

- [ ] **Step 3: Write the memory file** — `feat/one-shot-escape`, what shipped (second-class affine Future, trusted-once escape op, synchronous resumer, the §5.2 decision from Task 0), what is deferred, and the load-bearing findings (no host-op hook before this; deep re-install gives chaining/single-shot tradeoff). Add the `MEMORY.md` pointer line. Cross-link `[[one-shot-as-law-multiplicity]]`, `[[named-effect-instances-design]]`, `[[effect-compilation-strategy]]`.

- [ ] **Step 4 (optional): dot ergonomics** — if cheap, add `Future`-receiver dispatch so `s.resume v`/`s.value` work; update examples to the dot form. Otherwise leave plain functions and note dot as a follow-up.

- [ ] **Step 5: Commit.**

```bash
git add examples/coroutine.wok examples/README.md docs/superpowers/specs/ /Users/zy/.claude/projects/-Users-zy-wokml/memory/
git commit -m "docs(4b): coroutine example, roadmap + memory updates"
```

---

## Self-Review

**Spec coverage:** §3 primitive → Tasks 1,4 (+0 spike). §4 runtime/user line + trusted-once → Tasks 0,3. §5.1 lifetime/carrier → Task 2. §5.2 effect/residual-row/capability-reconstruction → Tasks 0,4,5. §5.3 affine + resume-xor-cancel → Tasks 3,5. §6 trivial resumer → Tasks 0,4. §9 deferred scope → respected (chaining/scheduler/box/cancellation-runtime out). §11 four negatives → Task 2 (escape), Task 3 (await-twice), Task 5 (resume-xor-cancel, unhandled-reperform); passing goldens → Tasks 3,4; day-one spike → Task 0. All covered.

**Placeholder scan:** No "TBD"/"handle edge cases". The spike-dependent specifics (op-vs-prim names, single-shot-vs-chaining) are explicitly routed through Task 0's recorded decision rather than left vague; later tasks reference that decision by name. Test code and commands are concrete.

**Type consistency:** `Future a b r` (arity 3) used consistently across Tasks 1,2,4,5; `start : (() -> r with Coro a b) -> Future a b r`, `resume : Future a b r -> b -> r`, `value : Future a b r -> a`, `cancel : Future a b r -> ()` consistent across Tasks 4,5,6. `TcFuture` consistent across Tasks 1,2. Examples trace to `421`/`64` consistently with the spec.

**Known dependency:** Tasks 1-6 are gated on Task 0's mechanism decision (host-op hook shape, future value rep, single-shot-vs-chaining). This is by design — the spec mandates the spike as a stop-gate. After Task 0, re-confirm Tasks 3-5's exact op/prim names against the decision note before dispatching them.
