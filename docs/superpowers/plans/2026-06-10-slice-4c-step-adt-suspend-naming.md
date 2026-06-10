# Slice 4c — closed `Step` ADT + suspend-family naming — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers-extended-cc:subagent-driven-development (recommended) or superpowers-extended-cc:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the 4b′ CPS `step` with a closed, transparent `Step a b r = Completed r | Suspended a (Suspension a b r)` ADT eliminated by `case`, and align the coroutine surface to the suspend-family vocabulary (rename `Future`→`Suspension`, drop `value`, `start` returns `Step`, `resume`→`run`).

**Architecture:** `Suspension` is the existing `TcFuture` handle renamed. `Step` is a new **built-in** tycon (`TcStep`) whose constructors `Completed`/`Suspended` reuse the existing runtime VCon tags — so `Step` *is* the value `__coro_resume` already produces (no lowering, no allocation, no CPS). The carrier + affine analyses (which run on the typed AST, before any IR step) treat both `Suspension` and `Step` as second-class + consume-once; because the tail binds in a `case` arm rather than a closure, multi-future interleaving (zip) type-checks with no new type-system machinery.

**Tech Stack:** Haskell (GHC/Cabal); wok type checker (`src/Wok/TypeChecking/*`), interpreter prims (`src/Wok/Interp/Prim.hs`), embedded prelude (`prelude/Std/Control.wok`), `tasty`/`tasty-golden` suite (`test/Spec.hs`), goldens auto-discovered from `test/{run,typecheck-fail}-examples/`.

**Grounding facts (verified at plan time):**
- `TyCon` enum: `src/Wok/TypeChecking/Types.hs:43` (`TcFuture` at :53, `TcUser Text` at :54, `TcEffect Text` at :61). `CType = CTCon TyCon [CType] | CTArr CType CRow CType | … | CTGen Int` (:92); `CRow` (:99); `Scheme {schemeVars,schemeConstraints,schemeBody}` (:105); `mkScheme` (:113).
- `TcFuture` sites to rename: `Types.hs:53`, `Infer.hs:755` (resolve `"Future"`), `Infer.hs:3480`/`3508` (pretty), `Class.hs:180` (`tyConKey`), `Carrier.hs:349` (`isHandleType`), `Carrier.hs:812` (`isFutureType`). Built-in registration string: `Builtins.hs:41` (`("Future", TyConInfo futureKind 3 [])`).
- Built-in ADT machinery: `Env` has `envCons :: Map Text ConInfo` and `envTyCons :: Map Text TyConInfo` (`Env.hs:99-100`); `ConInfo {conScheme::Scheme, conArity::Int, conTyCon::Text}` (:37); `TyConInfo {tcKind, tcArity, tcCons::[Text]}` (:44). Prelude ADTs (`data Bool`, `data Result`) live in `Std.Base`; their constructor names are the runtime VCon tags.
- Coro prims (`Prim.hs`): `coroSuspP`/`coroUnwrapP`/`coroValueP`/`coroResumeP`/`coroDoneP`/`coroCancelP`/`coroStepP` registered in the `prims` list (:16-36). Runtime tags built: `VCon "Suspended" [x,k]` (`coroSuspP`), `VCon "Completed" [r]` (`coroDoneP`). `value` is the prim `coroValueP` (name `"value"`). The prim-table name-set assertion is `test/Spec.hs:4051-4052`.
- Carrier/affine run on the **typed AST** (`TExpr`) pre-ANF; `isHandleType`/`handleBindersOfPat` classify handle types; `checkFutureAffine` counts "future passed as an argument = one consumption" (`Carrier.hs:619-647`); both walks descend into `TCase` (`Carrier.hs:233`, `:594`) and `TLam`.
- Current prelude surface (`prelude/Std/Control.wok`): `effect Coro a b`, externs `__coro_susp/__coro_resume/__coro_unwrap/__coro_done/__coro_cancel`, `start`, `extern value`, `resume`, `cancel`, and the 4b′ `step` + `extern __coro_step`.

---

### Task 1: Rename the handle `Future` → `Suspension` (mechanical, behavior-preserving)

**Goal:** Rename the coroutine handle type from `Future` to `Suspension` everywhere, with no behavior change; suite stays green.

**Files:**
- Modify: `src/Wok/TypeChecking/Types.hs` (`TcFuture` → `TcSuspension`, :53)
- Modify: `src/Wok/TypeChecking/Infer.hs` (:755 resolve `"Suspension"`; :3480, :3508 pretty)
- Modify: `src/Wok/TypeChecking/Class.hs` (:180 `tyConKey ... = "Suspension"`)
- Modify: `src/Wok/TypeChecking/Carrier.hs` (:349 `isHandleType`, :812 `isFutureType`, and the surrounding comments)
- Modify: `src/Wok/TypeChecking/Builtins.hs` (:41 `("Suspension", TyConInfo suspensionKind 3 [])`)
- Modify: `prelude/Std/Control.wok` (every `Future` in a type signature → `Suspension`)
- Modify: coro goldens/examples that mention the type name (see Step 4)

**Acceptance Criteria:**
- [ ] No occurrence of `TcFuture` or surface `Future` remains for the coroutine handle (`grep` clean).
- [ ] `cabal test` is fully green (this is a pure rename).

**Verify:** `grep -rn "TcFuture\|\"Future\"" src/ ; cabal test 2>&1 | tail -3` → no matches; all tests pass.

**Steps:**

- [ ] **Step 1: Branch.**
```bash
cd /Users/zy/wokml && git checkout -b feat/slice-4c-step-adt
```

- [ ] **Step 2: Rename the Haskell constructor `TcFuture` → `TcSuspension`.**
In `src/Wok/TypeChecking/Types.hs:53`, change `| TcFuture` to `| TcSuspension`. Then fix every reference (the compiler will list them): `Infer.hs:755` (`| name == Tx.pack "Suspension" = TcSuspension`), `Infer.hs:3480`/`3508` (`CTCon TcSuspension xs`), `Class.hs:180` (`tyConKey TcSuspension = Tx.pack "Suspension"`), `Carrier.hs:349` (`isHandleType (CTCon TcSuspension _) = True`), `Carrier.hs:812` (`isFutureType (CTCon TcSuspension _) = True` — rename the function to `isSuspensionType` for clarity and update its call sites).

- [ ] **Step 3: Rename the built-in registration.**
In `src/Wok/TypeChecking/Builtins.hs:41`, change `("Future", TyConInfo futureKind 3 [])` to `("Suspension", TyConInfo suspensionKind 3 [])` and rename the local `futureKind` binding to `suspensionKind` (:29-30).

- [ ] **Step 4: Rename in the prelude and goldens.**
In `prelude/Std/Control.wok`, replace `Future` with `Suspension` in every type signature (the `extern __coro_*` sigs, `start`, `value`, `resume`, `cancel`, `step`). In `test/typecheck-fail-examples/future-*.wok` and `test/run-examples/coro-*.wok`, replace `Future` → `Suspension` in type annotations. Regenerate affected goldens that print the type name: `cabal run wok-tests -- --accept --pattern "future-\|coro-" 2>&1 | tail -3` (read the diff first; it should be a pure `Future`→`Suspension` text change).

- [ ] **Step 5: Verify green.**
Run: `grep -rn "TcFuture\|\"Future\"" src/ ; cabal test 2>&1 | tail -3`
Expected: no matches; all tests pass.

- [ ] **Step 6: Commit.**
```bash
git add -A
git commit -m "refactor(4c): rename coroutine handle Future -> Suspension

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: Add the built-in `Step` ADT, carrier+affine

**Goal:** Introduce `Step a b r = Completed r | Suspended a (Suspension a b r)` as a built-in tycon with two constructors mapping to the existing runtime tags, and make it carrier (no escape) + affine (consumed by `case`-scrutiny).

**Files:**
- Modify: `src/Wok/TypeChecking/Types.hs` (add `TcStep` to the `TyCon` enum)
- Modify: `src/Wok/TypeChecking/Infer.hs` (resolve `"Step"` → `TcStep`; pretty-print)
- Modify: `src/Wok/TypeChecking/Class.hs` (`tyConKey TcStep = "Step"`)
- Modify: `src/Wok/TypeChecking/Builtins.hs` (register `Step` tycon + `Completed`/`Suspended` constructors)
- Modify: `src/Wok/TypeChecking/Carrier.hs` (`isHandleType` accepts `TcStep`; affine counts `case`-scrutiny of a `Step` binder as a consumption)
- Modify: `test/Spec.hs` (unit tests via `schemeOf`/carrier-affine helpers)

**Acceptance Criteria:**
- [ ] `Step a b r` resolves; `Completed`/`Suspended` are constructors of `Step` with the right field types.
- [ ] A `case` on a `Step`-typed binding type-checks and is exhaustive over `{Completed, Suspended}`.
- [ ] Returning/storing a `Step` (or the `g'` from a `Suspended` arm) → `CarrierEscape`.
- [ ] Scrutinizing the same `Step` binding twice → `FutureConsumedTwice`.

**Verify:** `cabal test 2>&1 | grep -iE "Step|carrier|affine|FAIL"` → new cases pass; no FAIL.

**Steps:**

- [ ] **Step 1: Add `TcStep` to the enum + resolution + pretty.**
`Types.hs`: add `| TcStep` to `TyCon`. `Infer.hs:755` resolution: add `| name == Tx.pack "Step" = TcStep`. `Infer.hs` pretty (near :3480): add `prettyCType (CTCon TcStep xs) = …` mirroring the `TcSuspension` clause (render as `Step a b r`). `Class.hs`: add `tyConKey TcStep = Tx.pack "Step"`.

- [ ] **Step 2: Register the tycon + constructors in `Builtins.hs`.**
Add imports: `import Wok.TypeChecking.Types (Kind (..), CType (..), CRow (..), TyCon (..), Scheme (..))` and `ConInfo (..)`. Add the tycon entry and the constructors:
```haskell
    stepKind :: Kind
    stepKind = KArrow KStar (KArrow KStar (KArrow KStar KStar))   -- * -> * -> * -> *

    -- in tyConEntries:
      , ("Step", TyConInfo stepKind 3 [Data.Text.pack "Completed", Data.Text.pack "Suspended"])
```
Add a `envCons` map to `initialEnv` (currently only `envTyCons` is set):
```haskell
initialEnv = emptyEnv
  { envTyCons = Map.fromList tyConEntries
  , envCons   = Map.fromList conEntries
  }
```
with (CTGen 0 = a, 1 = b, 2 = r):
```haskell
    stepTy   = CTCon TcStep [CTGen 0, CTGen 1, CTGen 2]
    suspTy   = CTCon TcSuspension [CTGen 0, CTGen 1, CTGen 2]
    vars3    = [(0, KStar), (1, KStar), (2, KStar)]
    arr d c  = CTArr d CREmpty c
    conEntries =
      [ ( Data.Text.pack "Completed"
        , ConInfo (Scheme vars3 [] (arr (CTGen 2) stepTy)) 1 (Data.Text.pack "Step") )
      , ( Data.Text.pack "Suspended"
        , ConInfo (Scheme vars3 [] (arr (CTGen 0) (arr suspTy stepTy))) 2 (Data.Text.pack "Step") )
      ]
```

- [ ] **Step 3: Make `Step` carrier (no escape).**
`Carrier.hs:349` `isHandleType`: add `isHandleType (CTCon TcStep _) = True`. (A `Step` is then escape-restricted exactly like a `Suspension`: it may be a `let`-RHS/`case`-scrutinee/handle-arg but not returned/stored/listed. The `g'` bound by a `Suspended` arm is already classified by `handleBindersOfPat` as a `TcSuspension` binder.)

- [ ] **Step 4: Write the failing carrier/affine tests** in `test/Spec.hs` (mirror the existing `assertCarrierEscape` / `FutureConsumedTwice` golden style, but as `typecheck-fail` examples since they need `Std.Control`). Create:
  - `test/typecheck-fail-examples/step-escapes.wok`: a function returning a `Step` (or the `g'` from a `Suspended` arm) → expect `CarrierEscape`.
  - `test/typecheck-fail-examples/step-scrutinized-twice.wok`: `let s = step g () in (case s of …) + (case s of …)` → expect `FutureConsumedTwice`.
Run them; they should currently NOT error correctly (Step isn't affine yet for double-scrutiny) — confirm the gap.

- [ ] **Step 5: Make `Step` affine (consumed by `case`-scrutiny).**
In `Carrier.hs` `consumeCard` (the `{Zero,One,Many}` counter, ~:648), add: scrutinizing a `Step`-typed (or `Suspension`-typed) binding in a `TCase` scrutinee position counts `One`. Concretely, in the `TCase scrut alts` handling of `consumeCard`'s `go`, if `scrut` is (an alias of) the tracked binder, contribute `One` (today a bare reference is only counted in argument position). Add a `Step` binder to the tracked set the same way Future binders are tracked (`handleBindersOfPat`/`futureBindersOfDecls` extended to `TcStep`). The existing `walk`/`checkFutureAffine` then rejects a `Step` consumed twice.

- [ ] **Step 6: Accept the goldens; verify.**
Run: `cabal run -v0 wok -- test/typecheck-fail-examples/step-escapes.wok --run` (expect `CarrierEscape …`), same for `step-scrutinized-twice` (expect `FutureConsumedTwice …`). Then `cabal run wok-tests -- --accept --pattern "step-" ` and `cabal test 2>&1 | tail -3` (green).

- [ ] **Step 7: Commit.**
```bash
git add -A
git commit -m "feat(4c): built-in Step ADT (Completed|Suspended), carrier+affine

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 3: Reshape the prelude surface (step→ADT, start→Step, drop value, resume→run, remove __coro_step)

**Goal:** Retype the prims and prelude functions so `start`/`step` return `Step`, dispatch is by `case`, `value` is gone, `resume` is `run`, and the CPS `__coro_step` is removed.

**Files:**
- Modify: `src/Wok/Interp/Prim.hs` (remove `coroStepP` from the `prims` list + its definition; remove `coroValueP` + `"value"`; update the prim-table test expectations are in Task 4/Spec)
- Modify: `prelude/Std/Control.wok` (retype externs; rewrite `start`/`step`; rename `resume`→`run`; delete `value` and the CPS `step` + `extern __coro_step`)
- Modify: `test/Spec.hs` (prim-table name-set assertion :4051-4052 — remove `"__coro_step"` and `"value"`)

**Acceptance Criteria:**
- [ ] Prims: `__coro_susp`/`__coro_resume`/`__coro_unwrap`/`__coro_done` are retyped to produce/consume `Step`; `__coro_step` and `value` removed; impls unchanged (they already build/peel the right VCons).
- [ ] `start : (() -> r with Coro a b) -> Step a b r`; `step : Suspension a b r -> b -> Step a b r`; `run : Suspension a b r -> b -> r`; `cancel : Suspension a b r -> ()`.
- [ ] Prim-table name-set test passes without `__coro_step`/`value`.

**Verify:** `cabal build 2>&1 | tail -3` (prelude type-checks); `cabal test 2>&1 | grep -iE "bodyless|FAIL"`.

**Steps:**

- [ ] **Step 1: Remove the CPS prim + the `value` prim.**
In `src/Wok/Interp/Prim.hs`, delete `coroStepP` (definition + its entry in the `prims` list) and `coroValueP` (definition + its `"value"` entry). Keep `coroSuspP`/`coroUnwrapP`/`coroResumeP`/`coroDoneP`/`coroCancelP` (impls unchanged — they build/peel the `Suspended`/`Completed` VCons, which are now `Step`).

- [ ] **Step 2: Rewrite `prelude/Std/Control.wok`.** Retype the externs to the `Step` surface and replace the eliminator block:
```wok
-- the producer effect is unchanged
effect Coro a b = { suspend : a -> b }

-- trusted builtins (impls unchanged; only the wok-level types move to Step)
extern __coro_susp   : a -> (b -> s) -> Step a b r     -- builds a Suspended Step
extern __coro_resume : Suspension a b r -> b -> Step a b r
extern __coro_unwrap : Step a b r -> r                 -- peels a Completed Step (errors on Suspended)
extern __coro_done   : r -> Step a b r                 -- builds a Completed Step
extern __coro_cancel : Suspension a b r -> ()

-- start: install Coro, run to first suspension, return the FIRST outcome as a Step
start : (() -> r with Coro a b) -> Step a b r
start c = with Coro { suspend x k -> __coro_susp x k ; v -> __coro_done v } (c ())

-- step: resume once, return the next outcome
step : Suspension a b r -> b -> Step a b r
step s v = __coro_resume s v

-- run: single-shot convenience (resume once, assume completion; errors if it re-suspends)
run : Suspension a b r -> b -> r
run s v = __coro_unwrap (__coro_resume s v)

-- cancel: discard a suspension without resuming
cancel : Suspension a b r -> ()
cancel s = __coro_cancel s
```
Delete the old `extern value`, the old `resume`, and the 4b′ `step` + `extern __coro_step`.

- [ ] **Step 3: Update the prim-table name-set test** (`test/Spec.hs:4051-4052`): remove `"__coro_step"` and `"value"` from the expected sorted list.

- [ ] **Step 4: Verify build + prim test.**
Run: `cabal build 2>&1 | tail -3` (prelude must type-check — if `__coro_susp`'s `(b -> s)`/`Step a b r` decoupling reintroduces an occurs-check, keep the `s`-decoupled slot exactly as 4b had it). Then `cabal test 2>&1 | grep -iE "bodyless|FAIL"` (name-set passes).

- [ ] **Step 5: Commit.**
```bash
git add -A
git commit -m "feat(4c): step/start return Step; drop value+__coro_step; resume->run

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 4: Migrate examples + goldens (and promote the multi-future tripwire)

**Goal:** Rewrite every coro example to the `case`/`Step` surface, retarget the negatives, and flip `future-step-multi-future-interleave` from a typecheck-fail tripwire to a **passing** zip run-example.

**Files:**
- Modify: `test/run-examples/coro-escape.wok` (+ golden), `coro-multi-driver.wok` (+ golden), `coro-step-range.wok` (+ golden)
- Move/rewrite: `test/typecheck-fail-examples/future-step-multi-future-interleave.wok` → `test/run-examples/coro-step-zip.wok` (+ golden); delete the old `.expected`
- Modify: the three `future-step-*` negatives + goldens (retarget to `Step`/`case`)
- Modify: `test/Spec.hs` if any inline coro test references the old surface

**Acceptance Criteria:**
- [ ] `coro-escape` → `421`, `coro-multi-driver` → `64`, `coro-step-range` → `10`, `coro-step-zip` → its computed sum (the zip now type-checks and runs).
- [ ] The three retargeted negatives reject with `FutureConsumedTwice`/`CarrierEscape` on the `Step` surface.
- [ ] No golden references the removed `value`/`resume`/CPS `step`.
- [ ] Whole suite green.

**Verify:** `cabal test 2>&1 | tail -3` → all pass.

**Steps:**

- [ ] **Step 1: Rewrite `coro-escape.wok`** to the new surface (yield value now comes from the `Suspended` pattern; `run` finishes it):
```wok
module Main
import Std.Base
import Std.Control
producer : () -> U64 with Coro U64 U64
producer u = (Coro.suspend 42) + 1
main : U64
main = case start producer of
  Completed r    -> r
  Suspended x s' -> run s' (x * 10)        -- 42 -> run with 420 -> 421
```
Golden stays `421`. Rewrite `coro-multi-driver.wok` similarly (golden `64`); rewrite `coro-step-range.wok` to the §3.1 `case` form (golden `10`).

- [ ] **Step 2: Promote the zip to a passing run-example.**
Create `test/run-examples/coro-step-zip.wok` with the §3.1 `zipSum` (two `gen` producers), `main` building both via `start` and folding; run it to get the actual sum and set `test/run-golden/coro-step-zip.expected` to that value (verify by hand first). Delete `test/typecheck-fail-examples/future-step-multi-future-interleave.wok` and its `.expected`.

- [ ] **Step 3: Retarget the three negatives** (`future-step-input-twice`, `future-step-tail-twice`, `future-step-tail-escapes`) to the `Step`/`case` surface — e.g. input consumed by two `step`/`case`s → `FutureConsumedTwice "s"`; the tail `g'` from a `Suspended` arm consumed twice → `FutureConsumedTwice "g'"`; `g'` escaping via a list → `CarrierEscape`. Verify each error by hand before accepting.

- [ ] **Step 4: Accept goldens + full suite.**
`cabal run wok-tests -- --accept --pattern "coro-\|step-\|future-step"` (read diffs first), then `cabal test 2>&1 | tail -3` → green. Manually re-sweep `examples/` for the old surface (`grep -rln "\.resume\|value \|onDone\|Future" examples/`) since `examples/` is not CI-scanned.

- [ ] **Step 5: Commit.**
```bash
git add -A
git commit -m "test(4c): migrate coro examples to Step/case; promote zip to passing

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 5: Spec + memory status update and review handoff

**Goal:** Mark the slice-4c spec implemented, update the 4b/4b′ spec status pointers and memory, prepare the full-branch review.

**Files:**
- Modify: `docs/superpowers/specs/2026-06-10-slice-4c-step-adt-suspend-naming-design.md` (status → implemented; resolve the `run` keep/drop note per what shipped; note that §5.1's ordering invariant holds trivially because `Step` = the runtime VCon, so there is no lowering)
- Modify: `docs/superpowers/specs/2026-06-09-slice-4b-prime-chaining-generators-design.md` (note the CPS `step` was superseded by 4c)
- Modify: `/Users/zy/.claude/projects/-Users-zy-wokml/memory/effects-slice-4b-prime-chaining-generators.md` (record the 4c outcome: Step ADT shipped; multi-future now works)

**Acceptance Criteria:**
- [ ] Spec status reads "Implemented on `feat/slice-4c-step-adt` (pending full-branch review)".
- [ ] Memory updated; the multi-future tripwire is recorded as resolved (now a passing example).

**Verify:** `git log --oneline main..feat/slice-4c-step-adt`; `cabal test 2>&1 | tail -2` → green.

**Steps:**

- [ ] **Step 1: Update the spec status + the §5.1 note** (no lowering ⇒ invariant trivially holds) and record the `run` decision actually shipped.
- [ ] **Step 2: Update the 4b′ spec + the memory note** (multi-future interleaving now type-checks; `Step`/`Suspension` are the surface; `Future`/`value`/CPS `step` removed).
- [ ] **Step 3: Commit** the in-repo docs (memory is saved directly, not committed):
```bash
git add docs/superpowers/specs
git commit -m "docs(4c): mark spec implemented; supersede 4b' CPS step

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```
- [ ] **Step 4: Request full-branch review** (per `review-before-merge`): `git diff main...feat/slice-4c-step-adt`; invoke requesting-code-review / `/code-review` over the whole branch. Do NOT merge until it passes.

---

## Self-Review

**Spec coverage:** §2 naming → Task 1 (Suspension) + Task 3 (run/start/value). §3 types/API → Tasks 2 (Step) + 3 (functions). §4 internal rep (Step = runtime VCon) → Task 2 (tags coincide) + Task 3 (prim retyping). §5 analyses → Task 2 (carrier+affine on Step; ordering invariant trivially holds since no lowering). §7 scope → Tasks 1-4. §8 migration → Task 4. §9 testing → Tasks 2,4. §11 rejected alternatives → no task (documentation only). All spec sections covered.

**Placeholder scan:** No TBD/TODO; every code step shows code or exact site+transformation; expected outputs concrete (`421`/`64`/`10`/zip-sum, the error constructors). The one judgement item (`run` keep-vs-drop) was resolved (kept) in the spec and is reflected in Task 3.

**Type consistency:** `Suspension a b r` and `Step a b r = Completed r | Suspended a (Suspension a b r)` are used identically across Tasks 2-4. Prim retypings (`__coro_susp/resume/unwrap/done → Step`, `__coro_cancel/step/run → Suspension`) are consistent with the prelude functions. Constructor names `Completed`/`Suspended` match the runtime tags built by `coroDoneP`/`coroSuspP`. `TcStep`/`TcSuspension` are used consistently.

**One risk flagged for execution (Task 2/3):** if hand-registering built-in constructors interacts badly with the match-compiler exhaustiveness or the `__coro_susp` `(b -> s)`-decoupling reintroduces an occurs-check under the new `Step` return type, that surfaces at Task 3 Step 4 (`cabal build`) — stop and inspect rather than work around.
