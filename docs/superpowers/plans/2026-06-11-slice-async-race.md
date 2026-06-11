# Slice 2: `race` + cooperative cancellation + `Nondet` — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers-extended-cc:subagent-driven-development. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Add `race` (run two `Async` children, first-to-complete wins, loser dropped) carrying a new `Nondet` effect marker, plus a deterministic resolver `runDet` — all as wok library code over the coroutine machinery (no interpreter change).

**Architecture:** `race` reuses the Slice-1 driver shape (`asCoro` adapter + lockstep) but returns the first completer and **drops** the loser (cooperative cancellation = the loser's carrier goes unused; its remaining tail never runs). `Nondet` is the nondeterminism marker: `race` performs `Nondet.decide` only on a *tie* (both children complete the same round). `runDet` discharges `Nondet` deterministically (`decide -> True`, left-biased), so races are reproducible for tests while the *type* honestly carries `Nondet`. Spec: `2026-06-11-async-effect-surface-and-cps-design.md` §3/§4/§7 (the `ndet` marker is named **`Nondet`**, locked this slice).

**Tech Stack:** wok prelude (`prelude/Std/Control.wok`); tasty-golden fixtures; `cabal build`/`test`.

**Invariants:** `race` discharges `Async`+`Coro`, adds `Nondet`, propagates residual `e`. Loser-drop is affine-legal (0 uses) — the SPIKE confirms it (else use the existing `cancel` library fn; either way **no new keyword**, per the cancellation-via-control-flow decision). `runDet` makes races deterministic for goldens.

---

## File structure
- **Modify `prelude/Std/Control.wok`** (only production file): append `effect Nondet = { decide : Bool }`, `runDet`, `race` (+ its `runRace` helper) after the Slice-1 `par` block.
- **Test fixtures** (new): deterministic race, cancellation-observability, Nondet-typing typecheck, unhandled-Nondet fail.

---

## Task 0: Branch and baseline
**Goal:** Branch `feat/slice-async-race` from main; baseline green (748).
**Verify:** `git branch --show-current` → `feat/slice-async-race`; `cabal test` green (748).
**Steps:** (done by coordinator) checkout -b; `cabal test`; par-basic=120, par-order=1234.

---

## Task 1: `Nondet` + `runDet` + `race` (with the drop-vs-cancel spike)
**Goal:** Add the `Nondet` effect, the `runDet` resolver, and `race` over the coroutine machinery; prove a deterministic race runs. SPIKE: confirm dropping the loser carrier (0 uses) type-checks under the affine analysis.

**Files:** Modify `prelude/Std/Control.wok`; Test `test/run-examples/race-basic.wok` (+ identical `test/typecheck-examples/race-basic.wok`) + goldens.

**Acceptance:**
- [ ] `effect Nondet = { decide : Bool }`, `runDet`, `race` in the prelude; prelude type-checks.
- [ ] `race` discharges `Async`, adds `Nondet`, propagates `e`.
- [ ] `race-basic.wok` (a deterministic race under `runDet`) `--run`s to `7`.
- [ ] Loser is dropped (0 uses) OR explicitly `cancel`-ed — report which the affine analysis required.
- [ ] Full suite green; coro/par values unchanged.

**Verify:** `cabal run -v0 wok -- test/run-examples/race-basic.wok --run` → `7`.

**Steps:**

- [ ] **Step 1: Write the failing test** (`test/run-examples/race-basic.wok` AND identical `test/typecheck-examples/race-basic.wok`):
```
module Main
import Std.Base
import Std.Control

fast : () -> U64 with Async
fast u = let p = Async.yield () in 7

slow : () -> U64 with Async
slow u = let p = Async.yield () in let q = Async.yield () in 9

main : U64
main = runDet (\u -> race fast slow)
```
Expected `--run` → `7` (fast completes after 1 yield; slow needs 2, so fast wins and slow is dropped before returning 9).

- [ ] **Step 2: Run; confirm it fails** (`Nondet`/`runDet`/`race` unknown).

- [ ] **Step 3: Add to `prelude/Std/Control.wok`** (after the Slice-1 `par` definition):
```
-- ---------------------------------------------------------------------------
-- race (slice async-race): run two Async children, first to COMPLETE wins; the
-- loser is dropped (its carrier goes unused -> its remaining tail never runs =
-- cooperative cancellation, no keyword). `Nondet` is the nondeterminism marker:
-- race performs `Nondet.decide` only on a TIE (both complete the same round).

-- Nondet: the nondeterminism marker. `decide` is the environment's choice;
-- a real runtime resolves it by timing, `runDet` resolves it deterministically.
effect Nondet = { decide : Bool }

-- runDet: deterministic resolver -- `decide` is always True (left-biased), so a
-- race under runDet is reproducible. Discharges Nondet.
runDet : (() -> a with Nondet + eff e) -> a with eff e
runDet c = with Nondet { decide -> True } (c ())

-- runRace: lockstep-drive two coroutines; return the first to Complete, dropping
-- the other. On a simultaneous completion (tie) ask `Nondet.decide`.
runRace : Step () () r (row e) -> Step () () r (row e) -> r with Nondet + eff e
runRace sa sb = case sa of
  Completed ra -> case sb of
    Completed rb -> case Nondet.decide of
                      True  -> ra
                      False -> rb
    Suspended _ gb -> ra
  Suspended _ ga -> case sb of
    Completed rb -> rb
    Suspended _ gb ->
      let sa2 = step ga () in
      let sb2 = step gb () in
      runRace sa2 sb2

-- race: adapt each child, start both, drive to the first completion.
race : (() -> r with Async + eff e) -> (() -> r with Async + eff e) -> r with Nondet + eff e
race a b = runRace (start (asCoro a)) (start (asCoro b))
```
SPIKE: the two arms `Suspended _ gb -> ra` and `Suspended _ ga -> rb` DROP the loser's carrier (0 uses). If the affine analysis REJECTS this (e.g. `FutureConsumedTwice`-style "must consume" / a carrier-escape / a linearity error), change those two arms to explicitly `cancel` the loser: `Suspended _ gb -> let _ = cancel gb in ra` and `Suspended _ ga -> let _ = cancel ga in rb` (using the existing prelude `cancel`). REPORT which form the analysis required — this answers whether cooperative cancellation is pure-drop (control-flow) or needs the explicit `cancel`. Do NOT change `src/**`/the analysis.

- [ ] **Step 4: Run; confirm `--run` → 7.** If it's a TYPE error (e.g. `runDet`/`race` row doesn't line up, or `decide -> True` value-op handler syntax is off — model it on the prelude `reader e c = with self = Reader { ask -> e } in c self`), fix only the NEW prelude text (not src/). If the affine drop is rejected, apply the `cancel` fallback (Step 3 spike) and rerun.

- [ ] **Step 5: Goldens + regression:**
```
cabal test --test-options=--accept 2>&1 | grep -iE "race-basic"
cat test/typecheck-golden/race-basic.expected
cabal test 2>&1 | grep -iE "All [0-9]+ tests passed"
for f in coro-escape par-basic par-order coro-multi-driver; do printf "%s=" "$f"; cabal run -v0 wok -- test/run-examples/$f.wok --run; done
```
Confirm: race-basic golden shows `race`/`runDet` typed (a `with Nondet` appears on `race`'s use or is discharged by `runDet` so `main : U64`); suite green; coro/par values unchanged (421/120/1234/64).

- [ ] **Step 6: Commit:**
```
git add prelude/Std/Control.wok test/
git commit -m "feat(async): race (first-wins, loser dropped) + Nondet marker + runDet resolver (slice async-race)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 2: cancellation observability + Nondet typing + unhandled-Nondet
**Goal:** Prove (a) the dropped loser's remaining tail is SKIPPED (cooperative cancellation, observable), (b) `race` carries `Nondet` and an unhandled `Nondet` is a type error.

**Files (new + goldens):**
- `test/run-examples/race-cancel.wok` — observable loser-drop.
- `test/typecheck-examples/race-nondet.wok` — `race` typed `with Nondet`.
- `test/typecheck-fail-examples/nondet-unhandled.wok` — pure fn racing without `runDet` → rejected.

**Acceptance:**
- [ ] `race-cancel.wok` `--run`s to a value that is ABSENT the loser's late effect (proves the loser was dropped before its tail).
- [ ] `race-nondet.wok` type-checks; golden shows a function whose row carries `Nondet` (race undischarged) — e.g. `useRace : () -> U64 with Nondet`.
- [ ] `nondet-unhandled.wok` REJECTED with an unhandled-`Nondet` type error.
- [ ] Suite green; coro/par/race values unchanged; churn limited to new fixtures.

**Verify:** `cabal run -v0 wok -- test/run-examples/race-cancel.wok --run` (the cancellation value); `cabal run -v0 wok -- test/typecheck-fail-examples/nondet-unhandled.wok 2>&1 | tail -1` → unhandled-`Nondet`.

**Steps:**

- [ ] **Step 1: Cancellation observability** (`test/run-examples/race-cancel.wok`). Use the `writer`-combinator observation pattern (as `par-order` does): each child `Writer.tell`s markers; the loser's LATE marker (emitted in the tail past the round where the winner completes) must be ABSENT from the log, while a marker it emits BEFORE that round is present. Encode the log into a number via a small in-fixture fold (mirror `par-order.wok`). Design the two children so the winner completes first and the loser's tail marker is provably skipped; compute the expected golden and confirm it omits the loser's late marker. (The implementer designs the exact children + value; the REQUIRED property: the golden distinguishes "loser dropped before its tail" from "loser ran to completion".) Wrap in `runDet` (race carries Nondet) and `writer`.

- [ ] **Step 2: Nondet typing** (`test/typecheck-examples/race-nondet.wok`):
```
module Main
import Std.Base
import Std.Control

g : () -> U64 with Async
g u = let p = Async.yield () in 1

useRace : () -> U64 with Nondet
useRace u = race g g

main : U64
main = runDet useRace
```
`useRace : () -> U64 with Nondet` proves race adds `Nondet` (Async discharged). `main` discharges it via `runDet`. Golden shows `useRace`'s `with Nondet`. (Also runnable → 1.)

- [ ] **Step 3: Unhandled-Nondet fail** (`test/typecheck-fail-examples/nondet-unhandled.wok`):
```
module Main
import Std.Base
import Std.Control

g : () -> U64 with Async
g u = let p = Async.yield () in 1

solo : () -> U64
solo u = race g g
```
`solo : () -> U64` (pure) but `race g g` carries `Nondet` → unhandled-`Nondet` type error (annotated helper, not `main`).

- [ ] **Step 4: Goldens + regression** (accept; verify each: race-cancel value omits the loser's late marker; race-nondet golden shows `with Nondet`; nondet-unhandled golden is an unhandled-`Nondet` error). Suite green; coro/par/race values unchanged; churn limited to the new fixtures.

- [ ] **Step 5: Commit:**
```
git add test/
git commit -m "test(async): race cancellation observability + Nondet typing + unhandled-Nondet (slice async-race)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 3: Full-branch review and finish
**Goal:** Standing-rule full-branch review `main..HEAD`; triage; integrate per user (prose).
**Acceptance:** review done + triaged; build+test green; coro/par/race values stable; `src/`/interpreter unchanged; the cancellation form (drop vs cancel) and the Nondet representation confirmed sound; integration decided with user.
**Steps:** review `git diff main...HEAD`; triage + fix; finish via finishing-a-development-branch; confirm merge in prose. Update spec §3/§4/§7 to record `Nondet` + the `decide`/`runDet` representation + the cancellation form the spike settled.
