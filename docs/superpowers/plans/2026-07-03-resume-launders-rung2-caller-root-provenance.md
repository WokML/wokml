# Resume-launders rung 2 (caller-root provenance) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers-extended-cc:subagent-driven-development. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Close the three handler-discharge laundering positions by recording a bare residual obligation iff its tail is a caller-supplied root, replacing rung 1's exempt-by-identity machinery.

**Architecture:** At seed time collect the `KEffect` row-variable representatives in the declared parameter + result types (`ctxCallerResidualRoots`); at the emit site record iff the residual tail's representative is in that set (representative-following). Retire `ctxExemptRows`/`withExemptRows` and the three exempt wrap sites. Type-only.

**Tech Stack:** Haskell wok type checker (`src/Wok/TypeChecking/{Infer,Monad}.hs`); tasty-golden; wok `.wok` corpus.

**User decisions (already made):**
- "yes do it now" — proceed autonomously; rung 2 = the three handler positions.
- Inner-abstraction family (lambda-param + sigless-local) DEFERRED to the next slice (different mechanism: effect propagation, confirmed by adversarial review).
- Continue on `feat/resume-launders-loadbearing` (rung 2 supersedes rung-1's exemptions).

**Design:** `docs/superpowers/specs/2026-07-03-resume-launders-rung2-caller-root-provenance-design.md` (adversarially verified SOUND, no over-reject counterexample).

---

## File Structure
- `src/Wok/TypeChecking/Monad.hs` — add `ctxCallerResidualRoots` + accessors; remove `ctxExemptRows`/`withExemptRows`/`currentExemptRows`.
- `src/Wok/TypeChecking/Infer.hs` — seed-time root collection (walking nested arrows/type-args); `emitResidualTail` membership check; remove the exempt wraps at arm/discharge/runner sites; drop now-unused resumeContTy row-return plumbing if orphaned.
- `test/typecheck-fail-examples/launder-leak-*.wok` (moved from typecheck-examples) + goldens — the conscious flip.
- `test/typecheck-examples/launder-leak-inner-*.wok` (NEW) — pin the deferred inner-abstraction leaks green.
- New positive tests: nested-function + residual-through-nested-arrow.

## Test commands
- Full: `cabal test wok-tests 2>&1 | tail -20`
- Filtered: `cabal test wok-tests --test-options='-p "<pat>"'`; regen: add `--accept`.

---

### Task 1: Caller-root provenance mechanism (replace exempt machinery)

**Goal:** Record a bare residual obligation iff its tail is a caller-supplied root; retire the exempt-by-identity machinery.

**Files:**
- Modify: `src/Wok/TypeChecking/Monad.hs`
- Modify: `src/Wok/TypeChecking/Infer.hs`

**Acceptance Criteria:**
- [ ] `ctxCallerResidualRoots :: [RowRef s]` added to TC state with `withCallerRoots`/`currentCallerResidualRoots`; seeded fresh per equation.
- [ ] `typeEquationWith` collects the representative refs of every `KEffect` row variable in the declared PARAMETER types and declared RESULT type, WALKING nested arrows and type arguments (not head-only), and installs them for the body.
- [ ] `emitResidualTail` records iff the residual tail's representative ∈ `ctxCallerResidualRoots` (force BOTH the tail and each stored root to representatives via `reprRowRef` before comparing); no other record path.
- [ ] `ctxExemptRows`, `withExemptRows`, `currentExemptRows`, `rowRefExempt`, and the three `withExemptRows (...)` wrap sites (arm bodies, discharge re-emit at ~2705, runner-form at ~2367) are REMOVED; `resumeContTyFor`'s row-returning additions dropped if now unused.
- [ ] `declClosed` gate and the deferred post-pass throw remain unchanged.
- [ ] No new `TCError` constructor.

**Verify:** `cabal test wok-tests 2>&1 | tail -30` — the only failures are the 3 `launder-leak-*` typecheck-examples now REJECTING (they flip in Task 2) and their old goldens; the 3 rung-1 death tests still reject; the accept-corpus stays green.

**Steps:**
- [ ] **Step 1:** In `Monad.hs`, add `ctxCallerResidualRoots :: [RowRef s]` to `TCCtx` (positional constructor in `runTC` → add `[]` in the right slot), plus `withCallerRoots :: [RowRef s] -> TC s a -> TC s a` (Reader `local`, replacing the field) and `currentCallerResidualRoots :: TC s [RowRef s]`. Remove `ctxExemptRows` and its `withExemptRows`/`currentExemptRows`.
- [ ] **Step 2:** In `Infer.hs`, write a pure helper `callerRootRefs :: [Type s] -> Type s -> TC s [RowRef s]` (or reuse an existing type-walk) that collects `KEffect`-kinded row-variable cell refs occurring anywhere in the parameter types and result type — recursing through `TArr` (both the arrow's effect row AND its domain/codomain), `TCon` type arguments, tuples, and `(row e)` slots. Force to representative before capturing the ref.
- [ ] **Step 3:** In `typeEquationWith`, at the seed (near the `declClosed <- ...` capture), compute `roots <- callerRootRefs pTys <declared-result>` and wrap the body with `withCallerRoots roots` (compose with the existing `withEffRowSig declClosed effRef`).
- [ ] **Step 4:** Rewrite `emitResidualTail`: on a bare unbound `KEffect` tail whose `reprRowRef` is a member of (the repr-normalised) `currentCallerResidualRoots`, `recordPendingResidual`; else skip. Delete the old exempt-consulting body.
- [ ] **Step 5:** Remove the three `withExemptRows` wrap sites and any now-dead helpers (`rowRefExempt`, `resumeContTyFor` row-return additions). Let GHC's `-Wunused` guide.
- [ ] **Step 6:** `cabal build lib:wok 2>&1 | tail -15` → clean.
- [ ] **Step 7:** `cabal test wok-tests 2>&1 | tail -40`. Expected: only the 3 `launder-leak-*` (now rejecting) fail their old accept-goldens; rung-1 death tests + accept-corpus green. If a legit accept-corpus program (coro-residual-handled/multi, 11-effect-collect, 54-reentrant-routing, 44-named-instance, prelude handlers) newly fails, STOP — the root-collection over-collected; diagnose.
- [ ] **Step 8:** Commit `feat(effects): rung-2 caller-root residual provenance; retire exempt-by-identity`.

---

### Task 2: Flip the leak characterizations to death tests + pin the deferred family

**Goal:** The 3 handler-position leaks become death tests; the 2 inner-abstraction leaks are pinned green as the new documented boundary.

**Files:**
- Move: `test/typecheck-examples/launder-leak-{handled-expr,nested,runner-sugar}.wok` → `test/typecheck-fail-examples/` (+ new `typecheck-fail-golden/`, delete old typecheck/anf/typed-anf goldens).
- Create: `test/typecheck-examples/launder-leak-inner-lambda.wok`, `launder-leak-inner-local-fn.wok` (+ goldens).

**Acceptance Criteria:**
- [ ] The 3 moved files reject with `UndischargedEffect`; headers updated from "KNOWN LEAK" to "rung-2 death test (was the rung-1 boundary)".
- [ ] The 2 inner-abstraction leaks TYPECHECK (accepted), headers marking them the deferred inner-abstraction family (ref the note).
- [ ] Old typecheck/anf/typed-anf goldens for the moved files removed; new fail-goldens name `UndischargedEffect`.

**Verify:** `cabal test wok-tests --test-options='-p "launder-leak"' 2>&1 | tail -20` → PASS

**Steps:**
- [ ] **Step 1:** `git mv` the 3 `launder-leak-*.wok` into `test/typecheck-fail-examples/`; `git rm` their `test/{typecheck,anf,typed-anf}-golden/launder-leak-*.expected`. Update each header to "rung-2 death test".
- [ ] **Step 2:** Create `launder-leak-inner-lambda.wok` (`driver g = (\h -> run h 0) g`, closed sig `Suspension U64 U64 U64 (row e) -> U64`) and `launder-leak-inner-local-fn.wok` (`drive g = let go u = run g 0 in go ()`, same sig), each with a header: "KNOWN LEAK (inner-abstraction family, deferred — see docs/superpowers/2026-07-02-lambda-effect-laundering-note.md); TYPECHECKS today (the lie)."
- [ ] **Step 3:** `cabal test wok-tests --test-options='--accept -p "launder-leak"'`. Confirm the 3 fail-goldens name `UndischargedEffect`, and the 2 inner ones typecheck (success goldens). If an inner one REJECTS, the deferred family got caught unexpectedly — STOP and report (would change scope).
- [ ] **Step 4:** Verify → PASS.
- [ ] **Step 5:** Commit `test(effects): flip handler-position leaks to death tests; pin inner-abstraction leaks (rung 2)`.

---

### Task 3: Regression + edge-case positives

**Goal:** Confirm no false positives on the accept-corpus and cover the design's edge cases (nested function, residual through a nested-arrow param).

**Files:**
- Create: `test/typecheck-examples/rung2-nested-fn-ok.wok` (a closed-sig function with a local helper that performs only INTERNAL, fully-handled effects — must accept), `test/typecheck-fail-examples/rung2-nested-arrow-root.wok` (a residual supplied through a nested function-typed param, performed under a closed sig — must reject, exercising nested-arrow root collection).

**Acceptance Criteria:**
- [ ] Accept-corpus green: `coro-residual-handled`, `coro-residual-multi`, `11-effect-collect`, `54-reentrant-routing`, `44-named-instance`, full prelude handler set.
- [ ] rung-1 death tests still reject.
- [ ] The 2 new edge tests behave as specified.
- [ ] Full `cabal test wok-tests` green.

**Verify:** `cabal test wok-tests 2>&1 | tail -10` → all pass

**Steps:**
- [ ] **Step 1:** Write `rung2-nested-fn-ok.wok`: a closed-sig top-level fn whose local `where`/`let` helper performs an effect that the enclosing function fully handles (mirroring `coro-residual-handled`'s shape but with a local helper) — must ACCEPT (the residual tail is internal, not a caller-root).
- [ ] **Step 2:** Write `rung2-nested-arrow-root.wok`: a closed-sig fn taking a param like `k : Suspension U64 U64 U64 (row e) -> U64` and performing that residual, so the root `e` lives in a nested arrow — must REJECT with `UndischargedEffect` (guards the nested-arrow collection requirement).
- [ ] **Step 3:** `cabal test wok-tests --test-options='--accept -p "rung2-"'`; confirm the ok-test accepts and the root-test rejects with `UndischargedEffect`.
- [ ] **Step 4:** Full `cabal test wok-tests 2>&1 | tail -10` → green.
- [ ] **Step 5:** Commit `test(effects): rung-2 regression + nested-fn/nested-arrow edge tests`.

---

## Self-Review
- Spec coverage: §3 mechanism → Task 1; §6 migration → Task 2; §5 edge cases + §7 criteria → Task 3. Deferred family (§4) → Task 2 characterizations.
- Placeholder scan: Task 1 is frontier (root-walk + retiring the exempt machinery need judgment; steps give the shape, GHC `-Wunused` guides removal). Task 2/3 have exact programs + commands.
- Type consistency: `ctxCallerResidualRoots`/`withCallerRoots`/`currentCallerResidualRoots`/`callerRootRefs` used consistently; `reprRowRef`/`recordPendingResidual`/`UndischargedEffect` reused from rung 1.
