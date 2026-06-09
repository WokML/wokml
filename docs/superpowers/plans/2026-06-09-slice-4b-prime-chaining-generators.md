# Slice 4b′ — Chaining / Consumer-Driven Generators (the `step` function) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers-extended-cc:subagent-driven-development (recommended) or superpowers-extended-cc:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a pull-based, consumer-driven generator combinator `step` to the wok coroutine library — resume a parked `Future` once and dispatch on completed-vs-suspended — as a plain `Std.Control` function plus one interpreter prim, with NO grammar change.

**Architecture:** `step` is a Scott/CPS-encoded eliminator: it resumes one layer via the existing `__coro_resume`, then a new bodyless prim `__coro_step` dispatches the resulting `Completed[r]`/`Suspended[x,k]` future onto two user callbacks (`onDone r` / `onYield x s'`). The tail future `s'` is bound as a `Future`-typed lambda parameter, so it is second-class by the existing carrier rule and consume-once by the existing affine rule — no new type-system machinery and no new error type. The deferred named-arm sugar (`step e v of done r -> … ; yield x s' -> …`) is kept in mind by locking the argument order so it desugars to a trivial positional application.

**Tech Stack:** Haskell (GHC, Cabal), the wok interpreter (`src/Wok/Interp/*`), type checker (`src/Wok/TypeChecking/*`), the embedded prelude (`prelude/Std/Control.wok`), and the `tasty` / `tasty-golden` test suite (`test/Spec.hs`, `cabal test`, accept goldens with `cabal run wok-tests -- --accept`).

**Key grounding facts (verified against the tree at plan time):**
- The coro prims live in `src/Wok/Interp/Prim.hs`; the registry list is `prims` at lines 16-36; `PRApply Value [Value]` applies a value to args (`Machine.hs:132` enters it).
- The prim-table name-set assertion is `test/Spec.hs:4051-4052` (must add `"__coro_step"`).
- The affine walk **already descends into `TLam` bodies** (`Carrier.hs:574`) and `consumeCard` already handles lambda capture; the carrier-escape walk **already descends into `TLam`** (`Carrier.hs:215`). So the day-one "does the walk descend into lambdas" question is answered by the existing code; Task 3's negatives are its confirmation through the full pipeline.
- `step`'s `Future` first argument is counted as a consumption by the existing rule ("a `Future` passed as an argument to ANY function consumes it, except `value`", `Carrier.hs:619-647`). No `Multiplicity.hs` change: `step` never hands a continuation to anything (the capture stays inside the producer's already-trusted `__coro_susp`).
- Golden tests auto-discover `.wok` files in `test/{run,typecheck-fail}-examples/` and compare to `.expected` in `test/{run,typecheck-fail}-golden/` (`test/Spec.hs:64-67`, harness via `tasty-golden`).

---

### Task 1: The `__coro_step` dispatch prim

**Goal:** Add the bodyless `__coro_step` prim that dispatches a resumed future onto two callbacks, register it, and lock its presence in the prim-table test.

**Files:**
- Modify: `src/Wok/Interp/Prim.hs` (add `coroStepP`; add it to the `prims` list at lines 30-35)
- Modify: `test/Spec.hs` (prim-table name-set assertion at lines 4051-4052; add prim unit tests in the `interpPrimTests` group)

**Acceptance Criteria:**
- [ ] `__coro_step` is in `primTable` with arity 3.
- [ ] `Completed[r]` dispatches to `onDone` applied to `[r]`.
- [ ] `Suspended[x,k]` dispatches to `onYield` applied to `[x, theSuspendedFuture]` (the same `Suspended` value, re-handed as the tail).
- [ ] A non-future first argument yields a `PrimError`.
- [ ] The prim-table name-set test passes with `"__coro_step"` added.

**Verify:** `cabal test 2>&1 | grep -iE "InterpPrim|coro_step|FAIL"` → the new `__coro_step` cases pass; no `FAIL`.

**Steps:**

- [ ] **Step 1: Create the implementation branch**

```bash
cd /Users/zy/wokml
git checkout -b feat/slice-4b-prime
```

- [ ] **Step 2: Write the failing prim unit tests**

In `test/Spec.hs`, inside the `interpPrimTests` group (the `testGroup "InterpPrim"` that begins near line 4049), add these three cases (place them after the existing `"table has exactly the bodyless operators"` case):

```haskell
  , testCase "__coro_step on Completed applies onDone to r" $
      case runPrim (T.pack "__coro_step")
             [ IV.VCon (T.pack "Completed") [li 7]
             , IV.VCon (T.pack "OnDone") []
             , IV.VCon (T.pack "OnYield") [] ] of
        Right (IV.PRApply (IV.VCon nm []) [arg]) -> do
          nm @?= T.pack "OnDone"
          IV.renderValue arg @?= T.pack "7"
        other -> assertFailure (show2 other)
  , testCase "__coro_step on Suspended applies onYield to x and the tail future" $
      case runPrim (T.pack "__coro_step")
             [ IV.VCon (T.pack "Suspended") [li 3, IV.VCon (T.pack "K") []]
             , IV.VCon (T.pack "OnDone") []
             , IV.VCon (T.pack "OnYield") [] ] of
        Right (IV.PRApply (IV.VCon nm []) [xv, IV.VCon sc _]) -> do
          nm @?= T.pack "OnYield"
          IV.renderValue xv @?= T.pack "3"
          sc @?= T.pack "Suspended"
        other -> assertFailure (show2 other)
  , testCase "__coro_step on a non-future errors" $
      case runPrim (T.pack "__coro_step")
             [ li 1, IV.VCon (T.pack "OnDone") [], IV.VCon (T.pack "OnYield") [] ] of
        Left (IV.PrimError _) -> pure ()
        other -> assertFailure (show2 other)
```

Also update the prim-table name-set assertion at lines 4051-4052 to include `"__coro_step"`:

```haskell
  , testCase "table has exactly the bodyless operators" $
      Data.List.sort (Map.keys IP.primTable)
        @?= Data.List.sort (map T.pack ["+","-","*","/","div","mod","eqU64","eqU32","u32","&&","||","++","$","__coro_susp","__coro_unwrap","value","__coro_resume","__coro_done","__coro_cancel","__coro_step"])
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `cabal test 2>&1 | grep -iE "coro_step|bodyless|FAIL"`
Expected: FAIL — `__coro_step` is not in the table (`UnboundVar`) and the name-set assertion mismatches.

- [ ] **Step 4: Implement and register the prim**

In `src/Wok/Interp/Prim.hs`, add `coroStepP` to the `prims` list (after `coroCancelP` at line 35):

```haskell
  , coroCancelP
  , coroStepP
  ]
```

Then add the definition next to the other coro prims (after `coroCancelP`, near line 100):

```haskell
-- | `__coro_step s onDone onYield` dispatches a RESUMED future (the result of
-- `__coro_resume`, already either `Completed [r]` or `Suspended [x, k]`) onto two
-- callbacks. `Completed [r]` applies `onDone r`; `Suspended [x, k]` applies
-- `onYield x s'`, where s' is the SAME Suspended value re-handed as the tail
-- future (no fresh allocation — value/resume/step all keep working on it). This
-- is the total, generator-safe counterpart of `__coro_unwrap` (which assumes
-- Completed and is the single-shot `resume`'s peeler).
coroStepP :: Prim
coroStepP = mkPrim (Tx.pack "__coro_step") 3 $ \args -> case args of
  [VCon t [r], onDone, _]
    | t == Tx.pack "Completed"  -> Right (PRApply onDone [r])
  [s@(VCon t [x, _]), _, onYield]
    | t == Tx.pack "Suspended"  -> Right (PRApply onYield [x, s])
  [s, _, _] -> Left (PrimError (Tx.pack "__coro_step: not a future: " <> renderValue s))
  _         -> Left (ArityError (Tx.pack "__coro_step"))
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `cabal test 2>&1 | grep -iE "coro_step|bodyless|FAIL"`
Expected: PASS — the three `__coro_step` cases and the name-set assertion pass; no `FAIL`.

- [ ] **Step 6: Commit**

```bash
git add src/Wok/Interp/Prim.hs test/Spec.hs
git commit -m "feat(4b'): add __coro_step dispatch prim + unit tests

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: The `step` prelude function + happy-path end-to-end run example

**Goal:** Add `extern __coro_step` and the `step` wrapper to `Std.Control` (with a sugar-readiness note), and prove the whole stack (prim + prelude + inference + carrier + affine) works end-to-end on a pull generator that suspends repeatedly.

**Files:**
- Modify: `prelude/Std/Control.wok` (add `extern __coro_step` + `step` after `cancel`, near line 61)
- Create: `test/run-examples/coro-step-range.wok`
- Create: `test/run-golden/coro-step-range.expected`

**Acceptance Criteria:**
- [ ] `Std.Control` loads and type-checks with the new `extern` + `step`.
- [ ] A `range`-style producer (suspends once per value) driven by `step`-recursion computes the correct sum.
- [ ] The recursion that threads the FRESH tail `s'` is ACCEPTED by the affine check (each future consumed once).
- [ ] `coro-step-range.wok --run` prints `10`.

**Verify:** `cabal run -v0 wok -- test/run-examples/coro-step-range.wok --run` → `10`

**Steps:**

- [ ] **Step 1: Write the failing run example + golden**

Create `test/run-examples/coro-step-range.wok`:

```wok
module Main
import Std.Base
import Std.Control

-- Producer: suspends with lo, lo+1, ..., hi-1, driven by its own recursion.
range : U64 -> U64 -> () with Coro U64 ()
range lo hi = case eqU64 lo hi of
  True  -> ()
  False -> let u = Coro.suspend lo in range (lo + 1) hi

-- Consumer: pulls one value per step, threading the FRESH tail s' through its
-- own recursion. Each future is consumed exactly once, so the affine check
-- accepts it (contrast future-recursive-consume.wok, which reuses one future).
sumPulled : Future U64 () () -> U64
sumPulled s = step s () (\r -> 0) (\x s' -> x + sumPulled s')

main : U64
main =
  let s = start (\u -> range 0 5) in   -- parked at the first suspend, yielding 0
  value s + sumPulled s                -- 0 + (1+2+3+4+0) = 10
```

Create `test/run-golden/coro-step-range.expected` with exactly:

```
10
```

- [ ] **Step 2: Run to verify it fails**

Run: `cabal run -v0 wok -- test/run-examples/coro-step-range.wok --run`
Expected: FAIL — `step` is not defined in `Std.Control` (an unbound-variable / resolution error).

- [ ] **Step 3: Add the prelude extern + wrapper**

In `prelude/Std/Control.wok`, after the `cancel` definition (line 60-61), append:

```wok

-- `step` resumes the parked continuation ONCE with `v`, then dispatches: the
-- producer either completed (onDone r) or suspended again (onYield x s'), where
-- s' is the tail future, SECOND-CLASS (a Future-typed lambda param: carrier rule
-- makes it second-class; the affine rule counts it as consumed when threaded on).
-- This is the total, generator-safe counterpart of `resume` (which assumes a
-- single suspension and crashes on re-suspend). `step` consumes its input future
-- (passed as an argument), and produces a fresh tail s' the onYield branch consumes.
--
-- ARGUMENT ORDER IS LOAD-BEARING (sugar-readiness): the deferred named-arm sugar
--   step e v of done r -> b1 ; yield x s' -> b2
-- desugars positionally to
--   step e v (\r -> b1) (\x s' -> b2)
-- so `step` MUST stay (future, value, onDone, onYield) with onDone : r -> t and
-- onYield : a -> Future a b r -> t. Do not reorder.
extern __coro_step : Future a b r -> (r -> t) -> (a -> Future a b r -> t) -> t

step : Future a b r -> b -> (r -> t) -> (a -> Future a b r -> t) -> t
step f v onDone onYield = __coro_step (__coro_resume f v) onDone onYield
```

- [ ] **Step 4: Run to verify it passes**

Run: `cabal run -v0 wok -- test/run-examples/coro-step-range.wok --run`
Expected: PASS — prints `10`.

- [ ] **Step 5: Run the full suite and accept the new run-golden**

Run: `cabal test 2>&1 | tail -5`
Expected: the new `coro-step-range` golden is reported new/failing (no `.expected` matched yet by the harness). Then accept it:
Run: `cabal run wok-tests -- --accept --pattern "coro-step-range" 2>&1 | tail -3`
Then re-run `cabal test 2>&1 | grep -iE "coro-step-range|FAIL"` → PASS, no `FAIL`.

- [ ] **Step 6: Commit**

```bash
git add prelude/Std/Control.wok test/run-examples/coro-step-range.wok test/run-golden/coro-step-range.expected
git commit -m "feat(4b'): add step combinator to Std.Control + range pull-generator example

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 3: Typecheck-fail negatives (the lambda-descent confirmation)

**Goal:** Lock the three step-specific rejections through the full pipeline — they confirm the carrier/affine analyses descend into the `step` callback lambdas: input consumed twice, tail consumed twice (lambda-introduced binder), tail escapes (lambda-introduced binder in a list).

**Files:**
- Create: `test/typecheck-fail-examples/future-step-input-twice.wok`
- Create: `test/typecheck-fail-examples/future-step-tail-twice.wok`
- Create: `test/typecheck-fail-examples/future-step-tail-escapes.wok`
- Create: `test/typecheck-fail-golden/future-step-input-twice.expected`
- Create: `test/typecheck-fail-golden/future-step-tail-twice.expected`
- Create: `test/typecheck-fail-golden/future-step-tail-escapes.expected`

**Acceptance Criteria:**
- [ ] Consuming the input future with two `step`s → `FutureConsumedTwice Nothing "s"`.
- [ ] Consuming the tail `s'` (a lambda param) twice → `FutureConsumedTwice Nothing "s'"` (proves affine descends into lambdas).
- [ ] Letting the tail `s'` escape in a list → `CarrierEscape Nothing "grab"` (proves carrier descends into lambdas).
- [ ] The existing `future-reperform-unhandled` golden still passes (the unhandled-reperform-at-`start` case is unchanged; not duplicated here).

**Verify:** `cabal test 2>&1 | grep -iE "future-step|FAIL"` → the three `future-step-*` goldens pass; no `FAIL`.

**Steps:**

- [ ] **Step 1: Write the three failing negatives and their goldens**

Create `test/typecheck-fail-examples/future-step-input-twice.wok`:

```wok
module Main
import Std.Base
import Std.Control
-- The input future `s` is passed to TWO `step` calls => consumed twice.
producer : () -> () with Coro U64 ()
producer u = let z = Coro.suspend 1 in ()
twice : Future U64 () () -> U64
twice s = step s () (\r -> 0) (\x s' -> x)
        + step s () (\r -> 0) (\x s' -> x)
main : U64
main = let s = start producer in twice s
```

Create `test/typecheck-fail-golden/future-step-input-twice.expected` with exactly:

```
typecheck: typecheck in Main: FutureConsumedTwice Nothing "s"
```

Create `test/typecheck-fail-examples/future-step-tail-twice.wok`:

```wok
module Main
import Std.Base
import Std.Control
-- The tail future `s'` (a lambda parameter introduced by the yield branch) is
-- consumed twice. Confirms the affine walk descends into step's callback lambdas.
producer : () -> () with Coro U64 ()
producer u = let z = Coro.suspend 1 in ()
badTail : Future U64 () () -> U64
badTail s = step s () (\r -> 0)
  (\x s' -> step s' () (\r -> 0) (\y t -> y)
          + step s' () (\r -> 0) (\y t -> y))
main : U64
main = let s = start producer in badTail s
```

Create `test/typecheck-fail-golden/future-step-tail-twice.expected` with exactly:

```
typecheck: typecheck in Main: FutureConsumedTwice Nothing "s'"
```

Create `test/typecheck-fail-examples/future-step-tail-escapes.wok`:

```wok
module Main
import Std.Base
import Std.Control
-- The tail future `s'` escapes its scope (collected into a list). Confirms the
-- carrier-escape walk descends into step's callback lambdas.
producer : () -> () with Coro U64 ()
producer u = let z = Coro.suspend 1 in ()
grab : Future U64 () () -> [Future U64 () ()]
grab s = step s () (\r -> []) (\x s' -> [s'])
main : U64
main = 0
```

Create `test/typecheck-fail-golden/future-step-tail-escapes.expected` with exactly:

```
typecheck: typecheck in Main: CarrierEscape Nothing "grab"
```

- [ ] **Step 2: Run to observe and verify the actual errors**

Run each through the compiler to confirm the error matches the expected golden BEFORE accepting:

```bash
cabal run -v0 wok -- test/typecheck-fail-examples/future-step-input-twice.wok --run; echo "---"
cabal run -v0 wok -- test/typecheck-fail-examples/future-step-tail-twice.wok --run; echo "---"
cabal run -v0 wok -- test/typecheck-fail-examples/future-step-tail-escapes.wok --run
```

Expected: each prints exactly the line in its `.expected` file (`FutureConsumedTwice Nothing "s"`, `FutureConsumedTwice Nothing "s'"`, `CarrierEscape Nothing "grab"` respectively).

STOP CONDITION: if `future-step-tail-twice` does NOT report `FutureConsumedTwice "s'"` (e.g. it passes, or names the wrong binding), the affine walk is not tracking the lambda param — halt and revisit Section §3.4 of the spec before continuing; the zero-new-rules assumption is wrong and the plan must change.

- [ ] **Step 3: Accept the goldens and run the suite**

Run: `cabal run wok-tests -- --accept --pattern "future-step" 2>&1 | tail -3`
Then: `cabal test 2>&1 | grep -iE "future-step|future-reperform|FAIL"`
Expected: the three `future-step-*` goldens pass; `future-reperform-unhandled` still passes; no `FAIL`.

- [ ] **Step 4: Commit**

```bash
git add test/typecheck-fail-examples/future-step-*.wok test/typecheck-fail-golden/future-step-*.expected
git commit -m "test(4b'): step negatives — input/tail double-consume + tail escape (lambda descent)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 4: Two-producer zip example + back-compat confirmation

**Goal:** Demonstrate the genuinely-pull capability a push handler cannot express — a consumer holding two live futures and picking the order — and confirm the existing single-shot coro examples are unaffected.

**Files:**
- Create: `test/run-examples/coro-step-zip.wok`
- Create: `test/run-golden/coro-step-zip.expected`

**Acceptance Criteria:**
- [ ] Two producers driven simultaneously, stepped in alternation, summing paired yields and stopping when either completes.
- [ ] `coro-step-zip.wok --run` prints `52`.
- [ ] The existing `coro-escape` (`421`) and `coro-multi-driver` (`64`) run-goldens still pass (back-compat).

**Verify:** `cabal run -v0 wok -- test/run-examples/coro-step-zip.wok --run` → `52`

**Steps:**

- [ ] **Step 1: Write the failing run example + golden**

Create `test/run-examples/coro-step-zip.wok`:

```wok
module Main
import Std.Base
import Std.Control

gen : U64 -> U64 -> () with Coro U64 ()
gen lo hi = case eqU64 lo hi of
  True  -> ()
  False -> let u = Coro.suspend lo in gen (lo + 1) hi

-- Pull one value from each producer, sum the pair, recurse on BOTH tails. Stops
-- when EITHER producer completes. Two live futures at once -- impossible with a
-- single push handler.
zipSum : Future U64 () () -> Future U64 () () -> U64
zipSum a b =
  step a () (\ra -> 0)
    (\xa a' -> step b () (\rb -> 0)
                 (\xb b' -> (xa + xb) + zipSum a' b'))

main : U64
main =
  let a = start (\u -> gen 0 4) in    -- yields 0,1,2,3
  let b = start (\u -> gen 10 14) in  -- yields 10,11,12,13
  (value a + value b) + zipSum a b    -- (0+10) + (1+11)+(2+12)+(3+13) = 10 + 42 = 52
```

Create `test/run-golden/coro-step-zip.expected` with exactly:

```
52
```

- [ ] **Step 2: Run to verify the result**

Run: `cabal run -v0 wok -- test/run-examples/coro-step-zip.wok --run`
Expected: `52`. (If it fails to type-check on affine grounds, the two-future threading is being mis-counted — halt and inspect; each of `a`, `b`, `a'`, `b'` must be consumed exactly once.)

- [ ] **Step 3: Accept the golden and confirm back-compat**

Run: `cabal run wok-tests -- --accept --pattern "coro-step-zip" 2>&1 | tail -3`
Then: `cabal test 2>&1 | grep -iE "coro-escape|coro-multi-driver|coro-step|FAIL"`
Expected: `coro-escape`, `coro-multi-driver`, `coro-step-range`, `coro-step-zip` all pass; no `FAIL`.

- [ ] **Step 4: Run the WHOLE suite green**

Run: `cabal test 2>&1 | tail -5`
Expected: all tests pass (the prior 681 green from the merged 4b, plus the new prim cases and four new goldens). No `FAIL`.

- [ ] **Step 5: Commit**

```bash
git add test/run-examples/coro-step-zip.wok test/run-golden/coro-step-zip.expected
git commit -m "test(4b'): two-producer zip example — consumer-driven pull, both tails

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 5: Spec + memory status update and review handoff

**Goal:** Mark the spec as implemented (pending review), record the implementation outcome in memory, and prepare the full-branch review required before merge.

**Files:**
- Modify: `docs/superpowers/specs/2026-06-09-slice-4b-prime-chaining-generators-design.md` (status line + §7 IN/§8 notes)
- Modify: `/Users/zy/.claude/projects/-Users-zy-wokml/memory/effects-slice-4b-prime-chaining-generators.md`

**Acceptance Criteria:**
- [ ] Spec status reads "Implemented on `feat/slice-4b-prime` (pending full-branch review)".
- [ ] Spec records the verified fact that the carrier/affine walks already descended into lambdas (no new rule needed) and that `Multiplicity.hs` was untouched.
- [ ] Memory note updated from "design converged, not yet implemented" to "implemented on `feat/slice-4b-prime`, pending review".

**Verify:** `git log --oneline main..feat/slice-4b-prime` → shows the four implementation commits; `cabal test 2>&1 | tail -2` → all green.

**Steps:**

- [ ] **Step 1: Update the spec status line**

In `docs/superpowers/specs/2026-06-09-slice-4b-prime-chaining-generators-design.md`, change the `Status:` line near the top to:

```markdown
Status: **Implemented** on `feat/slice-4b-prime` (pending full-branch review before merge to `main`).
Design converged in brainstorming (2026-06-09); function-only, no grammar change. Named-arm sugar
deferred (§9, §11).
```

And append a one-line confirmation to §3.4 (after the existing "day-one check" sentence):

```markdown
> CONFIRMED (implementation): the affine walk (`Carrier.hs:574`) and the carrier-escape walk
> (`Carrier.hs:215`) already descend into `TLam` bodies, so the `s'` lambda param is tracked with
> no new rule; `Multiplicity.hs` was untouched (`step` hands no continuation to anything).
```

- [ ] **Step 2: Update the memory note**

In `/Users/zy/.claude/projects/-Users-zy-wokml/memory/effects-slice-4b-prime-chaining-generators.md`, change the opening sentence from "design CONVERGED 2026-06-09, function-only, NOT yet implemented" to:

```markdown
Slice 4b′ (chaining / consumer-driven pull generators) IMPLEMENTED 2026-06-09 on
`feat/slice-4b-prime` (pending full-branch review). Function-only, no grammar change.
```

And update the "How to apply" paragraph to note it is built (prim `__coro_step` + `Std.Control.step`), with goldens `coro-step-range` (10), `coro-step-zip` (52), and the three `future-step-*` negatives.

- [ ] **Step 3: Commit**

```bash
git add docs/superpowers/specs/2026-06-09-slice-4b-prime-chaining-generators-design.md
git commit -m "docs(4b'): mark spec implemented; confirm lambda-descent + no multiplicity change

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

(The memory file lives outside the repo and is saved directly, not committed.)

- [ ] **Step 4: Request full-branch review**

Per the standing rule (`review-before-merge`), a full-branch review is REQUIRED before merging to `main`. Run:

```bash
git log --oneline main..feat/slice-4b-prime
cabal test 2>&1 | tail -2
```

Then invoke the requesting-code-review skill (or `/code-review`) over the whole branch diff (`git diff main...feat/slice-4b-prime`). Do NOT merge until the review passes.

---

## Self-Review

**Spec coverage:** Spec §3.1 prim → Task 1. §3.2 prelude function → Task 2. §3.4 carrier/affine reuse + day-one lambda-descent check → confirmed by Task 1 (code reading) and Task 3 (pipeline negatives). §5 four errors → Task 3 (three step-specific; the fourth, unhandled-reperform-at-`start`, is the pre-existing `future-reperform-unhandled`, explicitly not duplicated). §2/§9 passing examples (sumPulled, zipSum) → Tasks 2 and 4. §4 Lua/sugar-readiness → Task 2 argument-order note. §7 scope (keep value/resume/start/cancel) → unchanged, confirmed by Task 4 back-compat. §10 no grammar change / shift-reduce 32 → no grammar touched (no BNFC step anywhere). Full-branch review → Task 5.

**Placeholder scan:** No TBD/TODO; every code step shows complete code; every expected output is concrete (`10`, `52`, the three exact error strings, `421`/`64` back-compat).

**Type consistency:** `step : Future a b r -> b -> (r -> t) -> (a -> Future a b r -> t) -> t` and `__coro_step : Future a b r -> (r -> t) -> (a -> Future a b r -> t) -> t` are used identically in Tasks 1, 2, and the negatives. Prim name `"__coro_step"` is consistent across the registry, the name-set test, and the prelude extern. Constructor names `Completed`/`Suspended` match those built by `coroDoneP`/`coroSuspP` in the existing `Prim.hs`.
