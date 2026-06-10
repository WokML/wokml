# Slice 4b″ — Residual-Row `Suspension`/`Step` Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers-extended-cc:subagent-driven-development (recommended) or superpowers-extended-cc:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Thread a residual effect-row parameter `e` through the coroutine types and operations (`Suspension a b r (row e)` / `Step a b r (row e)`, `start`/`step`/`run`/`cancel`) so that resuming forces the resume site to handle the parked tail's effects — turning the "bounded handler escaped" runtime crash into a compile-time type error.

**Architecture:** Ride the Slice A/B kinded-Ty facility (already on `main`): give the coroutine `extern` types a `(row e)` parameter and thread `e` through the `start`/`step`/`run`/`cancel` and `__coro_*` signatures. The resume obligation falls out of the *existing* effect-row discipline — no new analysis. Runtime is unchanged (`e` is phantom). A two-line pretty-printer change suppresses a concrete-empty residual so pure-tailed coroutines don't churn.

**Tech Stack:** Haskell, GHC 9.10, `-Wall -Werror`, `tasty-golden`. wok prelude (`Std.Control`).

---

## Background the engineer needs

This is the implementable form of `docs/superpowers/specs/2026-06-10-slice-4b-dprime-residual-row-on-kinded-ty-design.md` (read it). The kind prerequisite is DONE — Slices A (kinded-Ty merge) + B (`(row e)` row-kinded tycon params + kind-checked applications) are on `main`. So this slice is mostly a `prelude/Std/Control.wok` change + a printer tweak + fixtures + golden migration.

### The current coroutine surface (`prelude/Std/Control.wok:20-62`)

```wok
effect Coro a b = { suspend : a -> b }
extern type Suspension a b r
extern data Step a b r = Completed r | Suspended a (Suspension a b r)
extern __coro_susp   : a -> (b -> s) -> Step a b r
extern __coro_resume : Suspension a b r -> b -> Step a b r
extern __coro_unwrap : Step a b r -> r
extern __coro_done   : r -> Step a b r
extern __coro_cancel : Suspension a b r -> ()
start  : (() -> r with Coro a b) -> Step a b r
start c = with Coro { suspend x k -> __coro_susp x k ; v -> __coro_done v } (c ())
step   : Suspension a b r -> b -> Step a b r
step s v = __coro_resume s v
run    : Suspension a b r -> b -> r
run s v = __coro_unwrap (__coro_resume s v)
cancel : Suspension a b r -> ()
cancel s = __coro_cancel s
```

### What changes (the whole slice)

1. **Types** gain a `(row e)` param (Slice B facility): `extern type Suspension a b r (row e)` and `extern data Step a b r (row e) = Completed r | Suspended a (Suspension a b r (row e))`. The `Suspended` field passes `(row e)` as a tycon argument — the Slice B field-tycon-application path (binding-aware kind-check), already shipped.
2. **`start`/`step`/`run`** carry `with eff e`; **`cancel`** does NOT (it drops the tail, can't fail). The `__coro_*` prim *signatures* gain `e` (the suspend/resume ones carry it in their rows); the prim **implementations in `src/Wok/Interp/Prim.hs` are UNCHANGED** (`e` is phantom — effects erase, VCon tags identical).
3. **Pretty-printer:** suppress a *concrete-empty* residual row in a tycon-argument position (so a pure-tailed `Step U64 U64 U64 {}` prints `Step U64 U64 U64`, exactly as before — consistent with how `a -> b` drops its empty arrow row). Row *variables* and *non-empty* rows still print.
4. **Migration:** any explicit `Suspension a b r` / `Step a b r` annotation in fixtures becomes arity-mismatched (the tycon now needs the row param) → add `(row e)`. Pure-tailed code using inference does NOT churn (suppress-empty).

### Why the soundness win needs no new analysis

`step`/`run` carry `with eff e`. At a resume site, `step g v : Step a b r e with eff e`, so `e` must be handled there; if the handler that discharged `e` around `start` has returned, `e` propagates to a closed-row boundary and the **existing** `RowMismatch` fires (the same machinery that rejects `main = ask`). The crash becomes a type error.

### The one risk — front-loaded (the §10 spike)

Whether `e` threads cleanly through the `Coro` handler's answer type and the `__coro_*` prim signatures *without a compiler change* (4c had a delimiter subtlety for non-tail-resume; this adds a row on top). Task 1 IS the spike: thread `e`, prove the headline negative type-errors and a pure-tailed positive runs. If handler elaboration drops `e` (the answer-row/resume-row unification loses it), surface the needed compiler change before the full migration — do not assume prelude-only succeeds blindly.

### What does NOT change (verified reasoning)

- **Carrier/affine analyses** (`Carrier.hs`): `isHandleType`/`isAffineCarrierType` match `CTCon (TcUser n) _` with `n` in the `tcCarrier` set — `Suspension`/`Step` stay marked regardless of the extra param. No change.
- **Producer-exemption** (`Infer.hs:resultIsAffineCarrier`): matches `CTCon (TcUser n) _` in the carrier set — `Step a b r e` still matches. `start`/`step` still type-check returning a freshly-produced `Step`. No change.
- **`run`'s re-suspend partiality** (`__coro_unwrap` crashing on a `Suspended`): UNCHANGED and intentionally NOT fixed here — the residual row is about *effects*, not *completion*. `run` stays partial; that fail state is the first item of the deferred failure-model slice. `run` only gains `with eff e`.

### Files

- `prelude/Std/Control.wok` (types, ops, prim sigs)
- `src/Wok/TypeChecking/Infer.hs` (`prettyCType` suppress-empty), `src/Wok/IR/Anf.hs` (`prettyCTypeLocal` suppress-empty)
- `test/typecheck-examples/{future-arg-ok,future-type-mentions,step-case}.wok` + others writing `Suspension`/`Step` explicitly (add `(row e)`) and their goldens
- new fixtures under `test/typecheck-fail-examples/` (headline negative) and `test/typecheck-examples/` + `test/run-examples/` (positives)
- coro run-examples/goldens (regenerate; pure-tailed unchanged)

---

## Task 0: Branch and baseline

**Goal:** Branch from `main`; record the green baseline + coro anchors.

**Files:** none.

**Acceptance Criteria:**
- [ ] On branch `feat/slice-4b-dprime` from `main`.
- [ ] `cabal test` green (718); coro `421/10/52/64`.

**Verify:** `git branch --show-current` → `feat/slice-4b-dprime`

**Steps:**

- [ ] **Step 1: Branch**
```bash
cd /Users/zy/wokml
git checkout main
git checkout -b feat/slice-4b-dprime
```
- [ ] **Step 2: Baseline**
```bash
cabal test 2>&1 | grep -iE "All [0-9]+ tests"
for f in coro-escape coro-step-range coro-step-zip coro-multi-driver; do printf "%s=" "$f"; cabal run -v0 wok -- test/run-examples/$f.wok --run; done
```
Expected: `All 718 tests passed`; `421/10/52/64`.

---

## Task 1: Residual-row core + spike (thread `e`; prove the gap closes)

**Goal:** Give the coroutine types the `(row e)` param, thread `e` through all operations/prims, add the suppress-empty printer rule, migrate explicit annotations + goldens, and prove the headline negative type-errors and a pure-tailed positive runs. This front-loads the `e`-threading risk.

**Files:**
- Modify: `prelude/Std/Control.wok`
- Modify: `src/Wok/TypeChecking/Infer.hs` (`prettyCType`), `src/Wok/IR/Anf.hs` (`prettyCTypeLocal`)
- Modify: existing fixtures writing `Suspension`/`Step` explicitly + their goldens
- Create: `test/typecheck-fail-examples/coro-residual-escapes.wok` (headline negative) + golden; `test/typecheck-examples/coro-pure-tail.wok` + `test/run-examples/coro-pure-tail.wok` + goldens

**Acceptance Criteria:**
- [ ] `Suspension`/`Step` carry `(row e)`; `start`/`step`/`run` carry `with eff e`; `cancel` carries no row; prim sigs thread `e`; `Prim.hs` UNCHANGED.
- [ ] Headline negative (bounded-handler-escaped resume) is a **type error** (`RowMismatch` or equivalent unhandled-effect error), not a runtime crash.
- [ ] A pure-tailed coroutine type-checks, `--run`s, and its inferred `Step`/`Suspension` types print WITHOUT an empty `{}` (suppress-empty).
- [ ] coro run-examples `421/10/52/64`; full suite green; golden churn limited to `e`-additions on explicitly-annotated fixtures (pure-tailed unchanged).

**Verify:** `cabal run -v0 wok -- test/typecheck-fail-examples/coro-residual-escapes.wok 2>&1 | tail -1` → an unhandled-effect type error (not a crash); `cabal test 2>&1 | grep -iE "All [0-9]+ tests"`

**Steps:**

- [ ] **Step 1: Edit the prelude types + signatures**

In `prelude/Std/Control.wok`, replace the coroutine block (the `extern type Suspension …` through `cancel s = …`) with:
```wok
extern type Suspension a b r (row e)

extern data Step a b r (row e) = Completed r | Suspended a (Suspension a b r (row e))

-- Trusted builtins. Implementations are UNCHANGED (e is phantom at runtime); only the
-- wok-level signatures gain the residual row e. __coro_susp keeps the continuation slot
-- decoupled (b -> s) so the suspend arm unifies without an occurs-check; the continuation
-- performs e on resume.
extern __coro_susp   : a -> (b -> s with eff e) -> Step a b r (row e)
extern __coro_resume : Suspension a b r (row e) -> b -> Step a b r (row e) with eff e
extern __coro_unwrap : Step a b r (row e) -> r                   -- pure projection; partial on Suspended (run's fail state, deferred)
extern __coro_done   : r -> Step a b r (row e)
extern __coro_cancel : Suspension a b r (row e) -> ()

-- start: install Coro, run the producer to its first suspension, return the FIRST
-- outcome as a Step. e = the producer's NON-Coro residual: emitted at the start site
-- (before-suspend effects) AND captured into the Step (performed on resume).
start : (() -> r with Coro a b + eff e) -> Step a b r (row e) with eff e
start c = with Coro { suspend x k -> __coro_susp x k ; v -> __coro_done v } (c ())

-- step: resume once; the tail performs e, so the resume site must handle e.
step : Suspension a b r (row e) -> b -> Step a b r (row e) with eff e
step s v = __coro_resume s v

-- run: single-shot convenience. Resumes once (performing e) and assumes completion;
-- if the producer RE-SUSPENDS this still errors at runtime (the documented partiality —
-- the residual row tracks effects, not completion; run's totality is the deferred
-- failure-model slice). run reveals the tail's effects via `with eff e`.
run : Suspension a b r (row e) -> b -> r with eff e
run s v = __coro_unwrap (__coro_resume s v)

-- cancel: discard a suspension without resuming it. The tail never runs, so cancel
-- performs nothing and carries NO residual row — it is the escape hatch for a suspension
-- whose e you cannot handle.
cancel : Suspension a b r (row e) -> ()
cancel s = __coro_cancel s
```

- [ ] **Step 2: Build — does `e` thread? (THE SPIKE)**
```bash
cabal build 2>&1 | tail -20
```
The prelude is loaded + type-checked at build/test time. If it builds, the prelude type-checks (the handler threads `e`). If the prelude FAILS to type-check (e.g. the `Coro` handler's answer-type unification drops `e`, or an occurs-check fires), STOP: this is the §10 risk materializing — capture the exact error and report it; the fix is a compiler change to the handler/answer-row elaboration, which must be scoped before continuing. Do NOT hack the prelude signatures to dodge a real threading gap.

Quick prelude-loads check (any program forces prelude type-checking):
```bash
printf 'module M\nimport Std.Control\nmain : U64\nmain = 0\n' > /tmp/4bd-load.wok && cabal run -v0 wok -- /tmp/4bd-load.wok --run; rm -f /tmp/4bd-load.wok
```
Expected: `0` (prelude type-checks and loads).

- [ ] **Step 3: Suppress-empty in the two pretty-printers**

A concrete-empty residual row (`CREmpty`) in a tycon-argument position should not print (consistent with how `a -> b` drops its empty arrow row). `CREmpty` only ever appears as a kind-`KEffect` (row) argument, so filtering it from a tycon's argument list is safe and affects only row args.

In `src/Wok/TypeChecking/Infer.hs`, the `prettyCType` arm for an applied user tycon currently renders all args. Change the `CTCon (TcUser n) xs` arm (and the `CTCon (TcEffect n) xs` arm, for symmetry) to drop empty-row args:
```haskell
prettyCType (CTCon (TcUser n) xs0) =
  case filter (/= CREmpty) xs0 of
    []  -> n
    xs  -> Tx.concat [n, Tx.pack " ", Tx.intercalate (Tx.pack " ") (map prettyCTypeAtom xs)]
prettyCType (CTCon (TcEffect n) xs0) =
  case filter (/= CREmpty) xs0 of
    []  -> n
    xs  -> Tx.concat [n, Tx.pack " ", Tx.intercalate (Tx.pack " ") (map prettyCTypeAtom xs)]
```
(Keep the existing nullary `CTCon (TcUser n) []` / `CTCon (TcEffect n) []` arms as-is — they already print just `n`.) Do the same filter in `src/Wok/IR/Anf.hs`'s `prettyCTypeLocal` `CTCon (TcUser n) xs` arm:
```haskell
prettyCTypeLocal (CTCon (TcUser n) xs0) =
  case filter (/= CREmpty) xs0 of
    []  -> n
    xs  -> n <> Tx.pack " " <> Tx.intercalate (Tx.pack " ") (map prettyCTypeLocal xs)
```
`CType` derives `Eq`, so `/= CREmpty` is valid. Build clean.

- [ ] **Step 4: Migrate explicitly-annotated fixtures**

`Suspension`/`Step` are now higher-arity, so any fixture writing `Suspension a b r` / `Step a b r` (3 args) is an arity mismatch. Find them:
```bash
grep -rln "Suspension \|Step " test/typecheck-examples test/typecheck-fail-examples test/run-examples 2>/dev/null
```
Known ones: `future-arg-ok.wok`, `future-type-mentions.wok`, `step-case.wok` write `Suspension U64 U64 U64` / `Step U64 () U64`. Add a row variable arg: `Suspension U64 U64 U64 (row e)`, `Step U64 () U64 (row e)`. (A `(row e)` arg introduces a polymorphic residual row variable — the correct "any residual" annotation; there is no concrete-empty-row arg syntax, which is fine.) Edit each explicit annotation to add `(row e)`.

- [ ] **Step 5: Headline negative fixture**

`test/typecheck-fail-examples/coro-residual-escapes.wok` — a producer whose tail performs an effect (`Log`) whose handler is gone by resume time:
```wok
module Main
import Std.Base
import Std.Control

effect Log = { emit : U64 -> () }

-- The producer suspends, then performs Log AFTER the suspend (in the tail).
producer : () -> U64 with Coro U64 U64 + Log
producer u =
  let x = Coro.suspend 1 in
  let _ = Log.emit x in
  x

main : U64
main =
  -- Log is handled ONLY around `start`; by the time we `step`, the Log handler is gone.
  let s0 = with Log { emit n k -> k () } (start producer) in
  case s0 of
    Completed r      -> r
    Suspended _ g    -> run g 0    -- run g : U64 with Log -- but no Log handler here -> TYPE ERROR
```
(The exact surface for installing `Log` around `start` should match how bounded/named handlers are spelled in the existing corpus — mirror an existing `with H { … } e` example. The essential shape: `Log` discharged around `start`, then `run`/`step` on the tail at a site where `Log` is unhandled.)

- [ ] **Step 6: Pure-tailed positive fixture**

`test/typecheck-examples/coro-pure-tail.wok` and an identical `test/run-examples/coro-pure-tail.wok`:
```wok
module Main
import Std.Base
import Std.Control

-- A producer whose tail performs NO non-Coro effect: residual e is empty.
counter : () -> U64 with Coro U64 U64
counter u =
  let _ = Coro.suspend 10 in
  let _ = Coro.suspend 20 in
  99

main : U64
main =
  case start counter of
    Completed r   -> r
    Suspended x g -> case run g 0 of n -> x
```
(Adjust to the corpus's idioms; the point is a pure-tailed coroutine — empty `e` — that type-checks and runs, exercising the suppress-empty printing.)

- [ ] **Step 7: Generate goldens + verify the gap closed**
```bash
cabal test --test-options=--accept 2>&1 | grep -iE "coro-residual-escapes|coro-pure-tail|future-arg-ok|future-type-mentions|step-case"
cat test/typecheck-fail-golden/coro-residual-escapes.expected
```
Expected: `coro-residual-escapes` golden is an unhandled-effect **type error** (`RowMismatch …` with `Log`, or the equivalent), NOT a runtime/crash message. Inspect the regenerated `future-arg-ok`/`step-case` typed-anf goldens: the `Suspension`/`Step` types should show the row variable `e` (since those annotations now write `(row e)`), and a pure-tailed/empty residual prints WITHOUT `{}`.

- [ ] **Step 8: Regression + churn review**
```bash
cabal test 2>&1 | grep -iE "All [0-9]+ tests"
for f in coro-escape coro-step-range coro-step-zip coro-multi-driver; do printf "%s=" "$f"; cabal run -v0 wok -- test/run-examples/$f.wok --run; done
git diff --stat main -- 'test/*-golden/'
```
Expected: suite green; coro `421/10/52/64`; the golden diff is limited to the new fixtures + `e`-additions on the explicitly-annotated coro fixtures. Pure-tailed coro goldens (`coro-escape` etc., if golden-printed) should be unchanged (suppress-empty keeps `Step U64 U64 U64`). If a pure-tailed golden gained a `{}`, the suppress-empty filter (Step 3) is wrong — fix it.

- [ ] **Step 9: Commit**
```bash
git add prelude/Std/Control.wok src/Wok/TypeChecking/Infer.hs src/Wok/IR/Anf.hs test/
git commit -m "feat(coro): residual-row Suspension/Step (row e); resume site must handle the tail's effects (slice 4b-dprime)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 2: Coverage + document `run`'s deferred fail state

**Goal:** Add a positive that proves the residual is *usable* when handled, confirm the existing coro negatives still reject, and record in the prelude that `run` stays partial (re-suspend) pending the failure-model slice.

**Files:**
- Create: `test/typecheck-examples/coro-residual-handled.wok` + `test/run-examples/coro-residual-handled.wok` + goldens
- Modify: `prelude/Std/Control.wok` (a comment is already added in Task 1 Step 1 — verify it's present and clear)
- (No new compiler code.)

**Acceptance Criteria:**
- [ ] A coroutine whose tail performs `Log`, resumed at a site WHERE `Log` is handled, type-checks and `--run`s (proves `e` is real and dischargeable, not just a blocker).
- [ ] The existing coro negatives (`step-escapes`, `suspension-escapes`, `step-scrutinized-twice`, `future-await-twice`, `step-inline-escape-*`) still reject with the same errors.
- [ ] The `Std.Control` `run` comment states it stays partial on re-suspend (deferred failure-model slice).
- [ ] Full suite green; coro `421/10/52/64`.

**Verify:** `cabal run -v0 wok -- test/run-examples/coro-residual-handled.wok --run` → its expected value

**Steps:**

- [ ] **Step 1: Residual-handled positive**

`test/typecheck-examples/coro-residual-handled.wok` and identical `test/run-examples/coro-residual-handled.wok` — same `Log`-tailed producer as the negative, but the `Log` handler wraps the WHOLE driver (so it's live at the resume site):
```wok
module Main
import Std.Base
import Std.Control

effect Log = { emit : U64 -> () }

producer : () -> U64 with Coro U64 U64 + Log
producer u =
  let x = Coro.suspend 7 in
  let _ = Log.emit x in
  x

main : U64
main =
  with Log { emit n k -> k () }
    (case start producer of
       Completed r   -> r
       Suspended x g -> run g 0)   -- run g : U64 with Log -- Log IS handled here -> OK
```
(Mirror the corpus's handler spelling. The contrast with `coro-residual-escapes` is *where* the `Log` handler sits — around `start` only (escapes → type error) vs around the whole driver (handled → type-checks + runs). This pair is the proof the residual row works in both directions.)

- [ ] **Step 2: Confirm existing negatives unchanged**
```bash
for f in step-escapes suspension-escapes step-scrutinized-twice future-await-twice step-inline-escape-list step-inline-escape-return step-inline-escape-tuple; do printf "%s: " "$f"; cabal run -v0 wok -- test/typecheck-fail-examples/$f.wok 2>&1 | tail -1; done
```
Expected: `CarrierEscape …` / `FutureConsumedTwice …` exactly as before (the carrier/affine analyses are unaffected by the row param). If any of these fixtures wrote `Suspension`/`Step` explicitly and now arity-mismatch, add `(row e)` (Task 1 Step 4 should have caught them — double-check).

- [ ] **Step 3: Verify the `run` partiality comment**

Confirm `prelude/Std/Control.wok`'s `run` carries the comment (added in Task 1) that it stays partial on re-suspend, deferred to the failure-model slice. (No code change; this is the documentation of the known fail state per the design.)

- [ ] **Step 4: Generate goldens + full regression**
```bash
cabal test --test-options=--accept 2>&1 | grep -i "coro-residual-handled"
cabal test 2>&1 | grep -iE "All [0-9]+ tests"
for f in coro-escape coro-step-range coro-step-zip coro-multi-driver; do printf "%s=" "$f"; cabal run -v0 wok -- test/run-examples/$f.wok --run; done
git diff --stat main -- 'test/*-golden/' | grep -i golden | grep -vE "coro-residual|coro-pure-tail|future-arg-ok|future-type-mentions|step-case" && echo "!!! unexpected churn" || echo "only slice-4b-dprime fixtures churned"
```
Expected: green; coro `421/10/52/64`; golden churn limited to the slice's fixtures + the migrated annotations.

- [ ] **Step 5: Commit**
```bash
git add test/ prelude/Std/Control.wok
git commit -m "test(coro): residual-handled positive + confirm negatives; note run stays partial (slice 4b-dprime)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 3: Full-branch review and finish

**Goal:** The standing-rule full-branch review before merge to `main`.

**Files:** none.

**Acceptance Criteria:**
- [ ] Full-branch review `main..HEAD` completed and triaged.
- [ ] Build + test green; coro `421/10/52/64`; golden churn limited to the slice's fixtures.
- [ ] `Prim.hs`/runtime unchanged; carrier/affine/producer-exemption unchanged.
- [ ] Integration decision made with the user (confirm in prose).

**Verify:** review report; `cabal test` green.

**Steps:**

- [ ] **Step 1: Snapshot**
```bash
cabal build 2>&1 | tail -3
cabal test 2>&1 | grep -iE "All [0-9]+ tests"
git diff --stat main -- src/Wok/Interp/ && echo "(Prim/runtime touched? should be empty)" || true
git log --oneline main..HEAD | cat
```

- [ ] **Step 2: Full-branch review**

Invoke `superpowers-extended-cc:requesting-code-review` over `main..HEAD`. It must check: `e` threads correctly through `start`/`step`/`run` and the `__coro_*` sigs; the bounded-handler-escaped case is a type error (headline negative) AND the handled case type-checks+runs (positive) — the residual row both blocks and discharges; `cancel` correctly carries no row; the suppress-empty printer is correct (pure-tailed unchanged, row vars + non-empty rows shown) and applied in BOTH printers; `Prim.hs`/runtime UNCHANGED; carrier/affine/producer-exemption unchanged; `run`'s re-suspend partiality is unchanged and documented (NOT silently "fixed"); the decidability contract holds (no new variable kinds; `e` is a `KEffect` row). Adversarially check for an unkind-checked or e-dropping path (the earlier Slice B review missed the bare-variable case — be rigorous about the `Suspension a b r e` field threading `e` correctly).

- [ ] **Step 3: Triage** with `superpowers-extended-cc:receiving-code-review`; fix as small commits; re-run `cabal test` + coro after each.

- [ ] **Step 4: Finish** with `superpowers-extended-cc:finishing-a-development-branch`; confirm with the user in prose before merging to `main`.

---

## Self-review (author's pass against the spec)

- **Spec §2 types (`(row e)` on Suspension/Step):** Task 1 Step 1. ✔
- **Spec §3 operations + prims thread `e`; impls unchanged:** Task 1 Step 1 (+ Step 2 spike verifies). ✔
- **Spec §4 soundness via existing row discipline:** Task 1 Step 5/7 (headline negative type-errors). ✔
- **Spec §5 row printing (suppress concrete-empty; show var + non-empty):** Task 1 Step 3 (both printers) + Step 8 churn check. ✔
- **Spec §6 `cancel` no row:** Task 1 Step 1. ✔
- **Spec §7 `run` fail state noted/deferred (not fixed):** Task 1 Step 1 comment + Task 2 Step 3. ✔
- **Spec §8 conservatism (full residual):** inherent in the producer's `+ eff e` row; no split. ✔
- **Spec §10 spike (does `e` thread):** Task 1 Step 2 front-loads it. ✔
- **Spec §11 testing (headline negative, handled positive, pure-tailed positive, regression):** Task 1 Steps 5-6, Task 2 Step 1, Steps 8/4. ✔
- **Spec §12 migration (arity bump → add `(row e)` to explicit annotations; pure-tailed don't churn):** Task 1 Step 4 + Step 8 churn review. ✔
- **OUT (run totality, cancellation runtime, concrete-row args, before/after split, scheduler):** none introduced. ✔
- **Type/name consistency:** `Suspension a b r (row e)` / `Step a b r (row e)` / `with eff e` / `cancel … -> ()` used identically across tasks; the suppress-empty `filter (/= CREmpty)` rule named consistently for both printers. ✔
