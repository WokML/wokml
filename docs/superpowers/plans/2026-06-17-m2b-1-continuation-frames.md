# M2b-1 — Counted Handler Frames + Tail-Resume / Abort Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers-extended-cc:subagent-driven-development (recommended) or superpowers-extended-cc:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the RC interpreter reference-count effect-handler frames and reified
within-handler continuations for the **no-parameter, one-argument, tail-resume-or-abort**
handler fragment, lifting the no-handler guard for that fragment and proving heap balance
against the reference interpreter.

**Architecture:** Runtime-centric, built B-ready (spec §2). A counted `KHandleRC` frame and
a counted `NCont` continuation node are added to the RC store; the machine performs
*move-out-on-resume* and *cascade-on-drop*; Perceus places the static drop of the `resume`
binder over the op-arm body (resume-application = consume; no-resume = `__rc_drop` →
cascade). The reference interpreter (`Wok.Interp.Machine`) is the differential heap-balance
oracle throughout.

**Tech Stack:** Haskell, `cabal`, tasty + Hspec + QuickCheck (`test-suite wok-tests`,
`test/Spec.hs`). RC store in `Wok.Interp.RC.{Value,Machine,Prim}`; Perceus pass in
`Wok.IR.Perceus`; escape analysis in `Wok.IR.Escape`; boundary guard in `Wok.IR.Reachable`.

**Spec:** `docs/superpowers/specs/2026-06-17-m2b-continuations-effects-rc-design.md`.

---

## CRITICAL: how to treat refcount details in this plan

RC soundness is a non-local, silent, type-unenforced conservation law. The repo's hard-won
discipline (M2a memories): **plain reasoning produces confident-but-wrong "it's sound"
conclusions; only run-the-exploit heap measurement is reliable.** Therefore:

- The **test in each task is the contract.** `assertRcAgrees` (heap balance + reference
  agreement) and `balanceLint` are the oracles. Write the test first; it must go red, then
  green.
- The **reference interpreter is the semantic template.** Each runtime arm below cites the
  exact `Wok.Interp.Machine` code to mirror; the RC version mirrors the *control flow* and
  adds the store threading + the dup/drop discipline from spec §3.2–§3.3.
- Where a step says **"balance against the oracle"**, the implementer derives the exact
  `incref`/`dropAddr` placement by running the task's heap-balance test and the generative
  property, iterating to green. This is TDD, not a placeholder — the move-vs-cascade *model*
  is fixed (spec §3.2); the per-site counts are discovered by measurement.
- **Never** mark a task complete on "looks sound." Complete only when the heap-balance
  oracle is green AND (from Task 6 on) the generative property is green.

## Test/verify commands

- Full suite: `cabal test wok-tests 2>&1 | tail -40`
- Targeted (tasty pattern): `cabal test wok-tests --test-options='-p "<substring>"' 2>&1 | tail -40`
- Build only: `cabal build wok 2>&1 | tail -20`

## File structure (what each task touches)

- `src/Wok/IR/Anf.hs` — `freeVarsExpr (Handle)` fix (Task 0).
- `src/Wok/IR/Reachable.hs` — the M2b-1 supported-fragment predicate inside
  `firstOrderNoHandlerViolations`/`exprScopeFeaturesWith` (Task 1).
- `src/Wok/IR/Escape.hs` — `m2bResumeEscapes` helper reusing `escapesFrom` (Task 1).
- `src/Wok/IR/Perceus.hs` — bring `Handle`/op-arms into coverage + instrument them (Task 2).
- `src/Wok/Interp/RC/Value.hs` — `KHandleRC` constructor; `NCont` node; `nodeValues`
  extension (Tasks 3–5).
- `src/Wok/Interp/RC/Machine.hs` — `Handle` install, `KHandleRC` return arm, RC `dispatchOp`
  + `findHandler`, `NCont` alloc, resume move-out, abort cascade (Tasks 3–5).
- `test/rc-m2b/*.wok` — new corpus (Tasks 3–5).
- `test/Spec.hs` — register `rc-m2b` in Suites A/B; `genM2bProgram` + `prop_m2b*` (Task 6).

---

### Task 0: Fix `freeVarsExpr (Handle)` to include handler-arm free vars

**Goal:** `freeVarsExpr` returns the free variables of a `Handle` node's handler arms (the
return-arm body and each op-arm body, minus their binders), so a closure or `LetRec` group
enclosing a handler computes its captures correctly. This is the M2b prerequisite (spec §1).

**Files:**
- Modify: `src/Wok/IR/Anf.hs:455` (`freeVarsExpr (Handle e _) = freeVarsExpr e`)
- Test: `test/Spec.hs` (new HUnit case near the other `freeVarsExpr` unit tests; search for
  existing `freeVarsExpr` usages to colocate)

**Acceptance Criteria:**
- [ ] `freeVarsExpr` of a `Handle` whose op arm references an outer var `x` (not otherwise
  free in the handled expr) includes `x`.
- [ ] A binder bound by an op arm (`oaArgs`, `oaResume`) or the return arm (`hReturn` binder)
  is NOT free.
- [ ] `hParam`/`hSelf` binders are removed from the arms' free sets.
- [ ] Full suite stays green (no existing program's capture accounting regresses).

**Verify:** `cabal test wok-tests --test-options='-p "freeVarsExpr"' 2>&1 | tail -20` → PASS;
then full suite green.

**Steps:**

- [ ] **Step 1: Write the failing test.** Add to `test/Spec.hs` (use the real constructors;
  mirror existing AST-building helpers in that file):

```haskell
-- freeVarsExpr must see handler-arm free vars (M2b prerequisite)
, testCase "freeVarsExpr includes op-arm free vars" $ do
    let x   = Name (Tx.pack "x") (Unique 9001)
        k   = Name (Tx.pack "k") (Unique 9002)
        v   = Name (Tx.pack "v") (Unique 9003)
        u64 = CTCon TcU64 []
        -- handle (Ret 0) with { return v -> v;  E.op(k) -> x }
        h = Handler (Binder v Unrestricted u64, Ret (AVar v))
                    [ OpArm (Tx.pack "E") (Tx.pack "op") [] (Binder k Unrestricted u64)
                            (Ret (AVar x)) ]
                    Nothing Nothing Nothing
        e = Handle (Ret (ALit (LInt 0))) h
    Set.member (Unique 9001) (freeVarsExpr e) @?= True   -- x is free
    Set.member (Unique 9002) (freeVarsExpr e) @?= False  -- k (oaResume) is bound
    Set.member (Unique 9003) (freeVarsExpr e) @?= False  -- v (return binder) is bound
```

- [ ] **Step 2: Run, expect FAIL.** `cabal test wok-tests --test-options='-p "freeVarsExpr includes op-arm"'` → FAIL (x not in set).

- [ ] **Step 3: Implement.** Replace `src/Wok/IR/Anf.hs:455`:

```haskell
freeVarsExpr (Handle e h)       = freeVarsExpr e `Set.union` freeVarsHandler h

-- | Free vars of a handler's arms: the return-arm body minus its binder, plus each
-- op-arm body minus that arm's args + resume binder; finally minus hParam/hSelf.
freeVarsHandler :: Handler -> Set Unique
freeVarsHandler (Handler (rb, rbody) ops _ mparam mself) =
  let retFv = Set.delete (binderUnique rb) (freeVarsExpr rbody)
      opFv  = Set.unions
                [ freeVarsExpr body
                    `Set.difference` Set.fromList (binderUnique resume : map binderUnique args)
                | OpArm _ _ args resume body <- ops ]
      bound = Set.fromList (map binderUnique (maybe [] pure mparam ++ maybe [] pure mself))
  in (retFv `Set.union` opFv) `Set.difference` bound
```

  Add `freeVarsHandler` to the module export list if the tests need it (optional). Ensure
  `Handler`/`OpArm` field accessors are in scope (they are, same module).

- [ ] **Step 4: Run targeted test, expect PASS.** Then full suite: `cabal test wok-tests 2>&1 | tail -40` → all green (this proves no existing capture accounting regressed — the harm was latent because effects were walled off, but verify).

- [ ] **Step 5: Commit.**

```bash
git add src/Wok/IR/Anf.hs test/Spec.hs
git commit -m "fix(anf): freeVarsExpr(Handle) includes handler-arm free vars (M2b prereq)"
```

---

### Task 1: M2b-1 supported-handler-fragment boundary predicate

**Goal:** `firstOrderNoHandlerViolations` stops rejecting `Handle`/`ROp` outright and instead
admits the M2b-1 fragment (handlers with `hParam = Nothing`, `hAnswerJoin = Nothing` (tail),
one-argument resume, and `resume` never escaping its op-arm body) while rejecting everything
else with a precise message. Pure analysis; no runtime yet.

**Files:**
- Modify: `src/Wok/IR/Reachable.hs` (the `Anf.Handle _ _` arm at line ~329 and the `ROp` arm
  at ~202 in `exprScopeFeaturesWith`)
- Modify: `src/Wok/IR/Escape.hs` (add `m2bResumeEscapes`; export it)
- Test: `test/Spec.hs` (new HUnit group "m2b-1 fragment predicate")

**Acceptance Criteria:**
- [ ] A tail-resume no-param one-arg handler (Reader/`ask`, `Tick`) → admitted (no violation).
- [ ] An abort handler (`Except`/`throw`, resume unused) → admitted.
- [ ] `hParam ≠ Nothing` (State/Writer) → rejected with a param message.
- [ ] `hAnswerJoin = Just _` (value position) → rejected with a non-tail message.
- [ ] A two-argument resume → rejected.
- [ ] `resume` stored into a con/record/returned/captured → rejected with an escaping-continuation message.
- [ ] The existing LetRec deferral checks (consume #1, cross-region #3, nested-capture) are unchanged.

**Verify:** `cabal test wok-tests --test-options='-p "m2b-1 fragment"' 2>&1 | tail -30` → PASS.

**Steps:**

- [ ] **Step 1: Add the escape helper to `src/Wok/IR/Escape.hs`** (export in the module list):

```haskell
-- | True iff the op-arm's resume binder ESCAPES its body --- it occurs in any
-- non-call-head position (stored into a con/record, returned, jumped, aliased, or
-- captured into a nested closure) rather than being applied as a saturated call head.
-- A resume used only as a saturated tail call head does NOT escape. Reuses the shared
-- 'escapesFrom' walker (single source of truth).
m2bResumeEscapes :: Binder -> Expr -> Bool
m2bResumeEscapes resume = escapesFrom (Set.singleton (binderUnique resume))
```

- [ ] **Step 2: Add the fragment predicate logic in `Reachable.exprScopeFeaturesWith`.**
  Replace the `Anf.Handle _ _ -> [Tx.pack "Handle (effect handler)"]` arm (line ~329) and the
  `Anf.ROp{} -> [Tx.pack "ROp (effect operation)"]` arm (line ~202). The `ROp` itself is no
  longer a violation once handlers are admitted (an `ROp` reachable from a `main` whose
  handlers are all in-fragment is fine; an `ROp` with no handler fails at runtime exactly as
  the reference does). Make `Handle` check the handler against the M2b-1 fragment:

```haskell
-- in exprScopeFeaturesWith's `go`:
Anf.Handle inner h ->
  m2bHandlerViolations h ++ go mob lr bsc inner

-- helper (top-level in Reachable, or a where-bound fn):
m2bHandlerViolations :: Anf.Handler -> [Text]
m2bHandlerViolations h =
  concat
    [ [ Tx.pack "effect handler with a handler-parameter (M2b-2; not yet on the RC store)" ]
      | Anf.hParam h /= Nothing ]
    ++ [ [ Tx.pack "effect handler in value (non-tail) position (M2b-2)" ]
       | Anf.hAnswerJoin h /= Nothing ]
    ++ concat
        [ [ Tx.pack "effect op arm with multi-argument resume (M2b-2)" ]
        | OpArm _ _ args _ _ <- Anf.hOps h, not (null args) ]   -- see NOTE below
    ++ concat
        [ [ Tx.pack "effect op arm whose resume ESCAPES its body (first-class continuation; M3)" ]
        | OpArm _ _ _ resume body <- Anf.hOps h, m2bResumeEscapes resume body ]
```

  **NOTE on "multi-argument resume":** the arg-count that distinguishes one-arg (`VCont`) from
  two-arg (`VContP`) resume is determined by `hParam` (a parameterized handler resumes with
  `(newParam, result)`), not by `oaArgs` (the op's own arguments). So the `hParam /= Nothing`
  check already covers two-arg resume; the `oaArgs`-based clause above is WRONG — remove it
  and rely on the `hParam` clause. (`oaArgs` are the operation's arguments, e.g. `set`'s `x`,
  which are fine in M2b-1 for a no-param handler — though no stock no-param op takes args;
  keep the door open.) Keep only the `hParam`, `hAnswerJoin`, and resume-escape clauses.

  Also recurse into the handler arms so a nested `Handle`/unsupported feature inside an arm is
  still surfaced:

```haskell
    ++ go Set.empty lr bsc (snd (Anf.hReturn h))
    ++ concat [ go Set.empty lr bsc (Anf.oaBody op) | op <- Anf.hOps h ]
```

  Import `OpArm (..)` / the field accessors from `Wok.IR.Anf` as needed; import
  `m2bResumeEscapes` from `Wok.IR.Escape`.

- [ ] **Step 3: Write the predicate tests** in `test/Spec.hs` (build small `CoreModule`s with
  a `main` that handles; assert `firstOrderNoHandlerViolations` is `[]` for in-fragment and
  non-`[]` for out-of-fragment). Mirror the existing `firstOrderNoHandlerViolations` test style
  if present; otherwise construct `Handler`/`OpArm` directly as in Task 0.

  Cover: Reader-shaped (admit), Tick (admit), Except-shaped abort (admit), param handler
  (reject), value-position `hAnswerJoin = Just j` (reject), resume-stored-in-con (reject).

- [ ] **Step 4: Run, expect FAIL then implement to PASS.** Full suite green afterwards (the
  existing handler-free corpus is unaffected; no in-tree program is in the new fragment yet, so
  Suites A/B are unchanged until Task 3 adds the corpus).

- [ ] **Step 5: Commit.**

```bash
git add src/Wok/IR/Reachable.hs src/Wok/IR/Escape.hs test/Spec.hs
git commit -m "feat(rc): admit the M2b-1 handler fragment at the boundary guard (tail/abort, no param, resume non-escaping)"
```

---

### Task 2: Perceus instrumentation of the M2b-1 handler fragment

**Goal:** Bring `Handle` (M2b-1 fragment) into Perceus coverage and instrument it: the handled
expression, the return-arm body, and each op-arm body. In an op arm, `oaResume` and `oaArgs`
are owned locals of the arm; `resume` is dropped (`__rc_drop`) on any path that does not apply
it (abort), and consumed by its single application on the resume path. Validated statically by
`balanceLint`/`lintInstrumented`; the runtime that proves it sound is Task 3–5.

**Files:**
- Modify: `src/Wok/IR/Perceus.hs` — `coveredExpr` (~258), `coveredRhs` (~271 for `ROp`),
  `ownExpr` (~806 `Handle`), `mutExpr` (~1167), `collectJoins` (~1342), `trackedBinders`
  (~1370), `checkExpr` (~1580), and the move/own occurrence helpers (~928, ~958, ~1669–1691)
- Test: `test/Spec.hs` (golden-style: `prettyPerceus` of a handler program; `balanceLint`
  clean) + a new golden under `test/rc-perceus-golden/` if that is where Perceus goldens live

**Acceptance Criteria:**
- [ ] `coveredExpr` returns `True` for an M2b-1-fragment `Handle`; still `False` for an
  out-of-fragment one (so the pass leaves unsupported handlers unchanged).
- [ ] An abort op arm emits `__rc_drop resume` (when `resume` is boxed) on the non-resuming
  path; a tail-resume arm emits no drop of `resume` (consumed by its application).
- [ ] The return-arm body and handled expression are instrumented like ordinary bodies.
- [ ] `balanceLint` / `lintInstrumented` report no violation on the M2b-1 corpus.
- [ ] The handler-free corpus's instrumented output is byte-identical to before (no regression
  in existing Perceus goldens).

**Verify:** `cabal test wok-tests --test-options='-p "perceus"' 2>&1 | tail -30` → PASS; full
suite green.

**Steps:**

- [ ] **Step 1: Decide coverage by the fragment predicate.** In `coveredExpr`, replace
  `coveredExpr Handle{} = False` with a check that the handler is in the M2b-1 fragment (reuse
  the Task 1 predicate — factor it so both `Reachable` and `Perceus` call one function, e.g.
  export `m2bHandlerInFragment :: Handler -> Bool` from `Wok.IR.Escape`). Out-of-fragment →
  `False` (unchanged behaviour). Likewise `coveredRhs (ROp ...)` becomes covered when the
  enclosing handler is in fragment (the `ROp` itself is instrumented for its argument moves).

- [ ] **Step 2: Write the failing golden test.** Add a small handler program and assert its
  `prettyPerceus` output. Start with the abort case (clearest drop):

```
-- expected fragment (illustrative; exact dups/drops are what the test pins):
-- E.op(resume) ->  let _ = __rc_drop(resume)   -- resume unused on this path
--                  <arm body>
```

  Use an actual `.wok` program in the corpus dir + `.expected`, following the existing
  `rc-perceus-golden` convention the Explore step found
  (`test/rc-perceus-golden/10-local-mutual-rec.expected`).

- [ ] **Step 3: Instrument.** Extend the pass arms so a covered `Handle` is walked:
  - `ownExpr` (currently `ownExpr _ sup _ e@Handle{} = (sup, e)`): instrument the handled
    expr under the current owned set; instrument the return arm with its binder owned;
    instrument each op arm with `oaArgs ++ [oaResume]` added to the owned set (boxed ones),
    placing the standard last-use drops — so an unused (abort) `resume` is dropped, a
    tail-applied `resume` is consumed by the application.
  - `mutExpr`, `collectJoins`, `trackedBinders`, `checkExpr`: recurse into handler arms
    instead of treating `Handle` as a leaf (mirror how `LetRec`/`Case` recurse).
  - The move/own occurrence helpers (`ownedOccs`/`moveOperandUniques`, ~928/~1669): an `ROp`'s
    operands move like `RApp` args (already at ~1691 `ROp _ _ _ as -> as`); confirm the
    instance handle `m` (named instance) is treated as a borrow (call-head-like) or move
    consistently with the reference (it is read-only — borrow).

  **Balance against the oracle:** run the golden + `balanceLint`. The exact dup/drop set is
  what `balanceLint` accepts and the Task-3+ heap oracle confirms. Iterate to lint-clean.

- [ ] **Step 4: Run targeted + full suite.** Confirm existing Perceus goldens unchanged (diff
  any that move; an out-of-fragment handler must still be left untouched).

- [ ] **Step 5: Commit.**

```bash
git add src/Wok/IR/Perceus.hs src/Wok/IR/Escape.hs test/Spec.hs test/rc-perceus-golden/
git commit -m "feat(rc): Perceus instruments the M2b-1 handler fragment (op-arm resume drop placement)"
```

---

### Task 3: RC store — `KHandleRC` frame + `Handle` install + return-arm completion

**Goal:** Add the counted handler frame to the RC store and run a handler whose body performs
**no operation** (just returns), so the new frame's install + normal-completion (return arm)
path is exercised with heap balance, before any continuation machinery.

**Files:**
- Modify: `src/Wok/Interp/RC/Value.hs` — add `KHandleRC Handler Int RCScope RCKont` to `RCKont`
  (mirror reference `Wok.Interp.Value.Kont` line ~106); update any total `RCKont` matches.
- Modify: `src/Wok/Interp/RC/Machine.hs` — `evalExprRC` `Handle` arm (replace the reject at
  ~165), `returnToRC` `KHandleRC` arm (mirror reference `returnTo`'s `KHandle` at ~41).
- Create: `test/rc-m2b/01-handle-noop-return.wok`
- Modify: `test/Spec.hs` — register `test/rc-m2b/` in the Suite A (`rcDifferentialHarness`) and
  Suite B (`rcStatsHarness`) directory lists.

**Acceptance Criteria:**
- [ ] `RCKont` has `KHandleRC`; the file compiles (all matches total).
- [ ] `evalExprRC (Handle e h)` installs `KHandleRC h tag sc' k` exactly mirroring the
  reference (`hSelf` → `VInst` self-binding; `tag = kontDepth k`); no longer errors.
- [ ] `returnToRC ... (KHandleRC h _ hsc k)` runs the return arm (`hReturn`) binding the
  produced value to the return binder, in `hsc`.
- [ ] `01-handle-noop-return.wok` runs on the RC store, output matches the reference, and the
  heap returns to baseline (`assertRcAgrees`).

**Verify:** `cabal test wok-tests --test-options='-p "rc-m2b"' 2>&1 | tail -30` → PASS.

**Steps:**

- [ ] **Step 1: Write the corpus program** `test/rc-m2b/01-handle-noop-return.wok`:

```
module Main
import Std.Base

-- A handler whose body performs NO operation: exercises KHandleRC install +
-- normal completion (return arm), no continuation. Heap must return to baseline.
effect Tick = { tick : () }

runTick : (Tick -> a with Tick + eff e) -> a with eff e
runTick c = with self = Tick { tick k -> k () } in c self

main : U64
main = runTick (\t -> 7)
```

  (The body `\t -> 7` never calls `tick`, so no op fires — only install + return arm.)

  `kontDepth` for `RCKont` is needed for the tag: add `kontDepth` to `Wok.Interp.RC.Value`
  mirroring the reference (`Wok.Interp.Value:116`), counting `KLetRC`/`KAppRC`/`KDropCellRC`/
  `KHandleRC` frames.

- [ ] **Step 2: Register the corpus dir + run, expect FAIL** (guard now admits it — Task 1 —
  but the RC machine still errors on `Handle` until this task). Add `test/rc-m2b` to the Suite
  A/B directory lists in `test/Spec.hs` (find where `test/rc-m2a1` is registered and add a
  sibling entry). Run → FAIL.

- [ ] **Step 3: Add `KHandleRC` to `RCKont`** in `Value.hs` and `kontDepth`; fix any
  non-exhaustive matches the compiler flags.

- [ ] **Step 4: Implement the two machine arms** in `Machine.hs`, mirroring the reference:

```haskell
-- evalExprRC, replacing the Handle reject (~165):
  Handle e h ->
    let tag = kontDepth k
        sc' = case hSelf h of
                Just sb -> sc { rscEnv = bindRCBinder sb (VInstRC (nameUniq (bndName sb)) tag) (rscEnv sc) }
                Nothing -> sc
    in Right (REval e sc' (KHandleRC h tag sc' k) s)

-- returnToRC, new arm mirroring reference returnTo's KHandle (~41):
returnToRC _ v (KHandleRC h _ hsc k) s =
  let (rb, rbody) = hReturn h
  in Right (REval rbody hsc { rscEnv = bindRCBinder rb v (rscEnv hsc) } k s)
```

  **`VInstRC`:** the RC value type (`RCValue`) currently has only `RVLit | RVBox |
  RVRecMember`. A named-instance handle (`hSelf`) needs an RC analogue of the reference
  `VInst Unique Int`. Add `RVInst Unique Int` to `RCValue` (an unboxed identity pair — NOT a
  counted heap value; `valueChildren (RVInst _ _) = []`). Update `valueChildren`,
  `resolveRCAtom` rendering, and any total `RCValue` matches. For M2b-1's ambient `Tick`
  (no named instance dispatch), `hSelf` may be `Just` (the prelude binds `self`); the handle
  must resolve but its identity is only consulted by named dispatch (Task 4's `findHandler`).

  **Balance against the oracle:** a no-op handler should be perfectly balanced already (no
  continuation, the return arm consumes `v`). If `assertRcAgrees` reports imbalance, the
  handler-scope values (`sc'`) ownership is the suspect — the handled expr borrows the
  enclosing scope; confirm the `KHandleRC` frame does not double-own `sc'`.

- [ ] **Step 5: Run targeted, expect PASS; full suite green. Commit.**

```bash
git add src/Wok/Interp/RC/Value.hs src/Wok/Interp/RC/Machine.hs test/rc-m2b/ test/Spec.hs
git commit -m "feat(rc): KHandleRC frame + Handle install + return-arm completion (no-op handler heap-balanced)"
```

---

### Task 4: RC store — `ROp` dispatch + `NCont` + abort (no-resume) cascade

**Goal:** Run a handler that performs an operation whose arm does **not** resume (abort). This
adds the RC `dispatchOp`/`findHandler`, the counted `NCont` continuation node, binding
`resume` to an `RVBox`→`NCont`, and proves that dropping the never-resumed continuation
(`__rc_drop resume` from Task 2) frees the continuation's **owned set** (spec §4.2) —
heap-balanced.

**READ FIRST: spec §4.2–§4.3 (the owned-set mechanism).** The continuation does NOT own
"every value in the captured scopes" — that double-frees borrowed/moved/global bindings (see
the §4.2 counterexample). On abort it must free exactly `continuationOwned` = the values the
captured continuation's own pending drop/move instructions would consume, computed via the
`Wok.IR.Escape` owning-vs-borrowing SSOT, deduped by binder `Unique`. So the `NCont` free does
**NOT** route through the generic `nodeValues`/`dropAddr` cascade.

**Files:**
- Modify: `src/Wok/Interp/RC/Value.hs` — add the `NCont` node (store the captured frame prefix
  **concretely**, as an `RCKont` with a splice marker, so one structure serves both the
  owned-set query and the Task-5 resume splice); add `continuationOwned :: <captured prefix> ->
  Store -> [Addr]` computing the owned set per §4.2 (reusing/extending `Wok.IR.Escape`). Do NOT
  make `NCont` cascade via `nodeValues`.
- Modify: `src/Wok/Interp/RC/Machine.hs` — `evalRhsRC` `ROp` arm (replace reject at ~207) →
  RC `dispatchOp`; `findHandler` over `RCKont`; allocate `NCont`; bind `resume`; the abort
  `__rc_drop` of an `NCont` handle frees `continuationOwned` then the shell.
- Modify: `src/Wok/IR/Escape.hs` — if the owning/borrowing classifier needs a continuation-
  oriented query (`nonHeadOccs`/`escapingAtomsRhs` exist; add what's missing **there**, the SSOT).
- Create: `test/rc-m2b/02-except-abort.wok`, `test/rc-m2b/03-abort-drops-captured.wok`

**Acceptance Criteria:**
- [ ] `NCont` is a heap node storing the captured prefix concretely. `continuationOwned`
  computes the owned set per §4.2 (free-in-body ∩ owning-position, via the `Escape` SSOT;
  plus `KAppRC` over-args and `KDropCellRC` addr; deduped by `Unique`) — NOT all scope values.
- [ ] RC `findHandler` walks `RCKont` to the nearest matching `KHandleRC` (ambient + named
  `instOk` parity with the reference).
- [ ] An op fires: the `above` frames are MOVED into a fresh `NCont` (rc = 1; no incref of
  children); `resume` is bound to `RVBox <addr>`; the arm runs under `kBelow`.
- [ ] `02-except-abort.wok` (`throw` aborts): output matches reference; heap balances.
- [ ] `03-abort-drops-captured.wok` (a boxed value live in the `above` frame is freed by the
  abort path, not leaked): heap balances.
- [ ] A **moved-away** value in the captured scope is NOT double-freed on abort (add a
  `04-abort-moved.wok` with `let y = Con x` before the throw; heap balances). This is the
  §4.2 counterexample and the whole reason for `continuationOwned`.

**Verify:** `cabal test wok-tests --test-options='-p "rc-m2b"' 2>&1 | tail -30` → PASS.

**Steps:**

- [ ] **Step 1: Write the corpus.** `02-except-abort.wok`:

```
module Main
import Std.Base

effect Exn = { throw : U64 -> Never }

run : (Exn -> a with Exn + eff e) -> Option a with eff e
run c = with self = Exn { throw n k -> None ; v -> Some v } in c self

main : Option U64
main = run (\e -> e.throw 5)
```

  `03-abort-drops-captured.wok` — make a boxed value live in the captured `above` frame at the
  op site, so the abort cascade must free it (else leak):

```
module Main
import Std.Base

effect Exn = { throw : U64 -> Never }

run : (Exn -> a with Exn + eff e) -> Option a with eff e
run c = with self = Exn { throw n k -> None ; v -> Some v } in c self

-- xs is boxed (a list), live in the frame above the throw; the abort path must
-- drop it via the NCont cascade rather than leak it.
main : Option U64
main = run (\e ->
  let xs = [1, 2, 3] in
  let _  = e.throw 9 in
  head xs)
```

- [ ] **Step 2: Run, expect FAIL** (RC machine still errors on `ROp`).

- [ ] **Step 3: Add `NCont` to `Value.hs`.** Represent the captured continuation as a node
  holding the reified `above` frame chain plus the handler to re-install (host data;
  store-resident so it is counted):

```haskell
-- in Node:
  | NCont RCKont (Handler, Int, RCScope)
  -- ^ a reified within-handler continuation: the captured 'above' frame chain (to
  -- re-prepend on resume) and the handler to re-install (handler, activation tag,
  -- captured handler scope). Its counted children (nodeValues) are every RCValue
  -- owned by the captured frames' scopes and the handler scope. Move-out on resume;
  -- cascade on drop. See spec 4.2.
```

  `nodeValues (NCont above (_,_,hsc)) = kontScopeValues above ++ Map.elems (rscEnv hsc)` where
  `kontScopeValues` walks the `RCKont` chain collecting each frame's `rscEnv` values (write
  this helper in `Value.hs`). **This enumeration is load-bearing and is the single source of
  truth for the cascade** — get it exactly right; the generative property (Task 6) is what
  proves it.

- [ ] **Step 4: Implement RC `dispatchOp` + `findHandler`** in `Machine.hs`, mirroring the
  reference (`Wok.Interp.Machine:178` and `:227`) but: (a) thread `Store`; (b) build the
  continuation as a concrete `NCont` cell, not a Haskell closure; (c) MOVE the `above` frames
  into the cell (no incref of their children — they were already owned by the live frames). For
  M2b-1 the resume is one-argument and (Task 5) tail; here the arm aborts, so `resume` is bound
  and then dropped by the Task-2 `__rc_drop`, whose `dropAddr` on the `NCont` runs the cascade.

  Sketch (refine against the oracle):

```haskell
-- evalRhsRC, replacing the ROp reject (~207):
  ROp minst lbl op as -> do
    vs      <- mapM (resolveRCAtom sc) as
    mTarget <- resolveInstRC sc minst   -- Maybe (Unique, Int), mirror reference
    rcDispatchOp mTarget lbl op vs (KLetRC b body sc k) s
```

  `rcDispatchOp` walks to the handler via `rcFindHandler`, allocates
  `alloc (NCont above (h, hTag, hsc)) s` (rc = 1, no child incref — move), binds
  `oaResume` to `RVBox <addr>` and `oaArgs` to `vs`, and evals `oaBody` under `kBelow`.

  **Carrier-wall sanity (M2b-1):** since `resume` here is only dropped or (Task 5) tail-applied,
  it cannot be stored — Task 1's `m2bResumeEscapes` already rejected storing it. So no
  `RVBox`→`NCont` reaches a con/record/NEnv in this fragment. (The full carrier-wall *check* is
  M2b-2 where param slots appear.)

  **Balance against the oracle:** run `02`/`03`. If `03` leaks, the cascade's `nodeValues
  (NCont …)` is missing a frame's values; if it double-frees, the move at capture wrongly
  increfed. Iterate to balanced.

- [ ] **Step 5: Run targeted, expect PASS; full suite green. Commit.**

```bash
git add src/Wok/Interp/RC/Value.hs src/Wok/Interp/RC/Machine.hs test/rc-m2b/
git commit -m "feat(rc): ROp dispatch + NCont continuation node + abort (no-resume) cascade, heap-balanced"
```

---

### Task 5: RC store — tail-resume move-out

**Goal:** Run a handler whose op arm **tail-resumes** (one argument). Applying the `resume`
handle (`RVBox`→`NCont`) re-prepends the captured frames and re-installs the handler, deleting
the `NCont` shell WITHOUT cascading its children (the move). Heap balances.

**Files:**
- Modify: `src/Wok/Interp/RC/Machine.hs` — recognize an application of an `RVBox`→`NCont` in
  `enterRC` (new arm): the move-out resume. A new machine op `moveOutCont` that deletes the
  `NCont` cell without cascading (mirrors `dropAddr` but skips the child cascade; one-shot ⇒
  rc = 1).
- Modify: `src/Wok/Interp/RC/Value.hs` — add `moveOutCont :: Addr -> Store -> Either
  RuntimeError (RCKont, (Handler, Int, RCScope), Store)` (free the shell, return the frames +
  handler, do NOT touch children's counts).
- Create: `test/rc-m2b/04-reader-ask.wok`, `test/rc-m2b/05-tick-tail-resume.wok`,
  `test/rc-m2b/06-resume-after-alloc.wok`

**Acceptance Criteria:**
- [ ] Applying an `RVBox`→`NCont` reconstructs the Kont (`above` re-prepended + re-installed
  `KHandleRC`) and continues with the resume argument as the produced value.
- [ ] `moveOutCont` frees the `NCont` cell, decrementing `stLive`/incrementing `stFrees` by
  one for the shell, but does NOT cascade the children (they moved back into the live Kont).
- [ ] `04-reader-ask.wok` and `05-tick-tail-resume.wok` run, match the reference, heap balances.
- [ ] `06-resume-after-alloc.wok` (a boxed value allocated in the `above` frame, used after
  resume) balances — proving the move returns the value to live ownership rather than freeing
  or duplicating it.

**Verify:** `cabal test wok-tests --test-options='-p "rc-m2b"' 2>&1 | tail -30` → PASS.

**Steps:**

- [ ] **Step 1: Write the corpus.** `04-reader-ask.wok`:

```
module Main
import Std.Base

effect Reader = { ask : U64 }

reader : U64 -> (Reader -> a with Reader + eff e) -> a with eff e
reader n c = with self = Reader { ask -> n } in c self

main : U64
main = reader 10 (\r -> 1 + r.ask)
```

  `05-tick-tail-resume.wok`:

```
module Main
import Std.Base

effect Tick = { tick : U64 }

runTick : (Tick -> a with Tick + eff e) -> a with eff e
runTick c = with self = Tick { tick k -> k 1 } in c self

main : U64
main = runTick (\t -> t.tick + t.tick)
```

  `06-resume-after-alloc.wok` (boxed value across the resume):

```
module Main
import Std.Base

effect Reader = { ask : U64 }

reader : U64 -> (Reader -> a with Reader + eff e) -> a with eff e
reader n c = with self = Reader { ask -> n } in c self

-- xs (boxed list) is live in the frame above ask; resume must hand it back so
-- 'length xs' after the ask sees it, with no leak and no double-free.
main : U64
main = reader 3 (\r ->
  let xs = [1, 2] in
  let m  = r.ask in
  m + length xs)
```

- [ ] **Step 2: Run, expect FAIL** (applying an `RVBox`→`NCont` currently hits the
  `NotAFunction "applied a non-closure heap node"` arm in `enterRC`).

- [ ] **Step 3: Implement `moveOutCont` in `Value.hs`:**

```haskell
-- | Resume move-out: free the NCont shell WITHOUT cascading its children, and return the
-- captured frame chain + handler-reinstall info. One-shot guarantees rc == 1 here, so the
-- single owner is consumed; the children's refcounts are LEFT UNTOUCHED because ownership
-- transfers to the re-prepended live frames (the move). Contrast 'dropAddr', which cascades.
moveOutCont :: Addr -> Store -> Either RuntimeError (RCKont, (Handler, Int, RCScope), Store)
moveOutCont a s = do
  c <- deref a s
  case cNode c of
    NCont above hinfo ->
      let st = stStats s
          s' = s { stCells = IM.delete a (stCells s)
                 , stDead  = IS.insert a (stDead s)
                 , stStats = st { stFrees = stFrees st + 1, stLive = stLive st - 1 } }
      in Right (above, hinfo, s')
    _ -> Left (PrimError (Tx.pack ("resume of non-continuation addr " <> show a)))
```

  (If a one-shot violation ever slipped through, rc > 1 would make this free a still-aliased
  cell — but one-shot is enforced upstream; assert `cRc c == 1` defensively and surface a loud
  `PrimError` if not, so a future regression is caught, not silently corrupted.)

- [ ] **Step 4: Implement the resume arm in `enterRC`.** When the applied value is `RVBox addr`
  whose node is `NCont`, with exactly one argument `[v]` (M2b-1):

```haskell
      NCont{} -> case args of
        [v] -> do
          (above, (h, hTag, hsc), s') <- moveOutCont addr s
          -- Re-prepend the captured frames and re-install the handler over the resume site,
          -- then deliver v into them. Mirrors the reference VCont: Return v (above (KHandle h
          -- hTag hsc after)). Here 'k' is the post-resume continuation ('after').
          let k' = above (KHandleRC h hTag hsc k)
          Right (RReturn v k' s')
        _ -> Left (ArityError (Tx.pack "continuation expects exactly one argument"))
```

  **`above` representation:** the reference `above` is a `Kont -> Kont` builder. For RC, the
  captured frames stored in `NCont` are a concrete `RCKont` whose innermost tail must be
  re-pointed at `KHandleRC h hTag hsc k`. Store `above` either as a builder
  (`RCKont -> RCKont`, kept out of `nodeValues` — but then how are its values enumerated for
  the cascade?) OR as a concrete prefix list of frames with a "splice point". **Decision:**
  store the concrete captured frame *prefix* (a list of frames with `KDoneRC`-terminated tails
  replaced by a marker), and provide two operations: `kontScopeValues` (for the cascade) and
  `spliceKont prefix tail` (for resume). This keeps the values enumerable for `nodeValues`
  (the cascade) AND splice-able for resume. Implement `spliceKont` in `Value.hs`. (This is the
  central representation decision; if the builder form is used, `nodeValues` must instead store
  the owned values separately — but that risks the move/cascade sets diverging, the M2a-class
  bug. Prefer the concrete-prefix form so ONE structure serves both.)

  **Balance against the oracle:** `04`/`05` are scalar-only (no boxed capture) and should
  balance immediately. `06` is the real test: if it double-frees, the move wrongly cascaded; if
  it leaks, the splice dropped a frame. Iterate to balanced.

- [ ] **Step 5: Run targeted, expect PASS; full suite green. Commit.**

```bash
git add src/Wok/Interp/RC/Value.hs src/Wok/Interp/RC/Machine.hs test/rc-m2b/
git commit -m "feat(rc): tail-resume move-out (NCont splice + shell free without cascade), heap-balanced"
```

---

### Task 6: Generative property + teeth + lint for the M2b-1 fragment

**Goal:** Extend Suite G with an adversarial generator for M2b-1 handler programs and the
accepted⟹sound property, plus mutation (teeth) and lint-clean properties, with explicit
non-vacuity coverage floors. This is the durable oracle that prevents a green-shipping
double-free in an un-hand-tested shape.

**Files:**
- Modify: `test/Spec.hs` — `genM2bProgram`, `prop_m2bEscape`, `prop_m2bTeeth`,
  `prop_m2bLintClean`; register in the Suite G test group.

**Acceptance Criteria:**
- [ ] `genM2bProgram` produces handler programs varying: tail-resume vs abort; op fired under
  trivial vs non-trivial `above` (directly vs inside a `Let`/`Case`); 1–3 ops; nested handlers;
  a boxed value live across the op (the `03`/`06` shape).
- [ ] `prop_m2bEscape`: for every generated program that is accepted (in-fragment AND one-shot),
  the RC run heap-balances and agrees with the reference (reusing the `assertRcAgrees` logic
  inline as in `prop_m2a1Escape`).
- [ ] `prop_m2bTeeth`: `OmitOneDrop`/`OmitOneDup`/`DuplicateOneDrop` are each caught (no-op,
  static lint, or runtime fault) on generated programs.
- [ ] `prop_m2bLintClean`: `balanceLint` reports nothing on in-fragment generated programs.
- [ ] Coverage floors via `checkCoverage`: "abort path run", "tail-resume run", "op under
  non-trivial above", "boxed value across op" each ≥ a non-trivial %.
- [ ] **Red-check:** reverting any one of Tasks 3–5's fixes makes `prop_m2bEscape` go red
  (document the red-check in the commit message).

**Verify:** `cabal test wok-tests --test-options='-p "m2b"' 2>&1 | tail -40` → PASS; run with
`--quickcheck-tests 5000` to stress.

**Steps:**

- [ ] **Step 1: Write `genM2bProgram`** mirroring `genM2a1Program` (~9320) structure: a sized
  generator picking an `M2bShape` (`TailResume | Abort | AbortDropsCaptured |
  ResumeAcrossAlloc | NestedHandlers | OpUnderCase`) and emitting a `CoreModule` with a `main`
  that installs the handler and performs the op. Reuse the existing AST-building combinators in
  `test/Spec.hs`.

- [ ] **Step 2: Write the three properties** mirroring `prop_m2a1Escape` /
  `prop_m2a1Teeth` / `prop_m2a1LintClean` (~11108 / ~11605 / ~11586), swapping the generator and
  gating `accepted = null (firstOrderNoHandlerViolations cm)` (one-shot is enforced upstream;
  if the generator can emit multi-shot, also gate on the multiplicity check — confirm the
  harness elaboration path or filter in the generator).

- [ ] **Step 3: Add coverage floors** with `cover`/`checkCoverage` and `label`, exactly as the
  hardened `prop_m2a1Escape` does (the floors must FAIL the property if unmet, not just warn).

- [ ] **Step 4: Run, expect PASS.** Then do the red-checks: temporarily revert Task 5's
  `moveOutCont` to a `dropAddr` (cascade) and confirm `prop_m2bEscape` goes red on
  `ResumeAcrossAlloc`; revert and confirm green. Repeat for Task 4 (skip the move at capture →
  red). Record the red-check results.

- [ ] **Step 5: Commit.**

```bash
git add test/Spec.hs
git commit -m "test(rc): Suite G generative property + teeth + lint for the M2b-1 handler fragment (red-checked)"
```

---

## Self-Review

**Spec coverage:** Task 0 ↔ spec §1 prerequisite + §5.1. Task 1 ↔ §6 boundary guard. Task 2 ↔
§4.4 static seam. Tasks 3–5 ↔ §4.1–§4.3 representation + runtime (frame, NCont, move-out vs
cascade). Task 6 ↔ §7 oracle. The carrier-wall *check* (§3.4/§8) is intentionally deferred to
M2b-2 (no param slots in M2b-1; `m2bResumeEscapes` already blocks storing a continuation) —
noted in Task 4 Step 4. `freeVarsExpr` regression verification (§8) is Task 0 Step 4.

**Placeholder scan:** the refcount-fill steps are explicit oracle-driven TDD (see "CRITICAL"
header), not vague placeholders; each has a concrete failing test and a concrete reference
template. The `NCont`/`above` representation decision (Task 5 Step 4) is made (concrete-prefix
+ `spliceKont`), not deferred.

**Type consistency:** `KHandleRC Handler Int RCScope RCKont` (Task 3) is used by `returnToRC`
(Task 3), `findHandler`/`dispatchOp` (Task 4), and resume re-install (Task 5). `NCont RCKont
(Handler, Int, RCScope)` (Task 4) is consumed by `moveOutCont`/`spliceKont`/`nodeValues`
consistently. `RVInst Unique Int` (Task 3) is the named-instance handle. `m2bResumeEscapes`
(Task 1) and `m2bHandlerInFragment` (Task 2) are shared by `Reachable` and `Perceus`.

**Risk to watch (flagged for the reviewer):** the `NCont` move/cascade set must be the SAME
`nodeValues` enumeration on capture, resume, and drop — divergence is the M2a-class
double-free. Task 6's generator + red-checks are the guard; the full-branch `/code-review`
must build the exploit, not trust "verified".
