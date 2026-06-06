# Effects Slice 3: bounded `(with H e)` + delimited-continuation fix — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers-extended-cc:subagent-driven-development (recommended) or superpowers-extended-cc:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the bounded handler expression `(with H e)` correct for *all* handler kinds by fixing the delimited-continuation bug that makes a resuming handler in non-tail position return wrong answers, then pin the bounded surface as goldens and reconcile the docs.

**Architecture:** The bounded form already parses and routes (`EParen` over the existing `EWith`/`EWithH` `Exp2` productions → same `inferHandler` → `THandle`), so there is **no grammar, parser, or typechecker change**. The one substantive change is in lowering + runtime: a handler in value position has its arms `jump` to a post-handler join point, but `resume` re-installs the handler without rebinding that join, so a resumed sub-run's answer escapes to the static top-level continuation instead of returning to the resume call site. The fix records the handler's answer-join (`hAnswerJoin :: Maybe JoinId` on `Handler`, set from the tail continuation in `Elaborate`) and has `dispatchOp` rebind it to deliver to the resume call site `after` when re-installing the handler. Tail-position handlers carry `Nothing` and are unchanged.

**Tech Stack:** Haskell — ANF IR (`src/Wok/IR/Anf.hs`), elaborator (`src/Wok/IR/Elaborate.hs`), CEK interpreter (`src/Wok/Interp/Machine.hs`, `src/Wok/Interp/Value.hs`), tasty-golden suite (`test/Spec.hs`, `test/run-examples/`, `test/run-golden/`).

Implements **slice 3** of `docs/superpowers/specs/2026-06-05-effect-handlers-ROADMAP.md`. Design: `docs/superpowers/specs/2026-06-06-effects-slice-3-bounded-handlers-design.md`. Branch: `feat/effects-slice-3-bounded-handlers` (already created off `main`). Full-branch review before any merge (standing rule).

---

## Build / test commands (reference)

- Build: `cabal build`
- Full suite: `cabal test` (or `cabal run wok-tests`)
- One program: `cabal run -v0 wok -- <file.wok> --run` (prints `main`); `--dump-anf` to dump ANF.
- Accept/regenerate goldens: `cabal run wok-tests -- --accept` (read diffs before accepting).
- Run-test pairing: `test/run-examples/NAME.wok` ↔ `test/run-golden/NAME.expected` (`test/Spec.hs:166,195-197`).

---

## File structure

- `src/Wok/IR/Anf.hs` — add `hAnswerJoin :: Maybe JoinId` to `Handler`; update `collectHandler` and `renderHandler` pattern matches. (Task 1)
- `src/Wok/IR/Elaborate.hs` — set `hAnswerJoin` from `tk` in `elabKF … (THandle …)`. (Task 1)
- `src/Wok/Interp/Machine.hs` — rebind the answer-join to `after` in `dispatchOp`'s resume; add `Atom (..)` to the `Wok.IR.Anf` import. (Task 1)
- `test/run-examples/*.wok` + `test/run-golden/*.expected` — the failing resume matrix (Task 1) and the bounded-surface goldens (Task 2).
- `docs/superpowers/specs/2026-06-05-effect-handlers-ROADMAP.md`, `docs/.../2026-06-05-effect-handler-surface-syntax.md`, memory `effect-surface-syntax-final` — reconcile (Task 3).

---

### Task 1: Fix the delimited-continuation bug for non-tail resuming handlers

**Goal:** A resuming handler (multishot / generator / single-shot control) used in a non-tail position (`(with H e) + k`, `let r = (with H e) in …`, spliced into `++`) returns the correct answer; tail-position handlers are unchanged.

**Files:**
- Modify: `src/Wok/IR/Anf.hs:70-73` (`Handler` record), `src/Wok/IR/Anf.hs:141` (`collectHandler`), `src/Wok/IR/Anf.hs:310` (`renderHandler`)
- Modify: `src/Wok/IR/Elaborate.hs:486-497` (`elabKF … THandle`)
- Modify: `src/Wok/Interp/Machine.hs:13-15` (import), `src/Wok/Interp/Machine.hs:137-150` (`dispatchOp`)
- Create: `test/run-examples/{28-bounded-multishot-arith,29-bounded-multishot-prefix,30-bounded-multishot-let,31-bounded-generator-splice,32-bounded-control-single,33-bounded-nested-multishot}.wok` + matching `test/run-golden/*.expected`

**Acceptance Criteria:**
- [ ] `(with {flip k -> k True + k False ; v->v} pick()) + 0` evaluates to `30` (was `10`).
- [ ] `1 + (with {flip k -> k True + k False ; v->v} pick())` evaluates to `31` (was `11`).
- [ ] `let r = (with {…multishot…} pick()) in r` evaluates to `30` (was `10`).
- [ ] `[100] ++ (with {yield x k -> [x] ++ k() ; v->[]} producer())` evaluates to `[100, 1, 2, 3]` (was `[100]`).
- [ ] `1 + (with {ask k -> k 41} prog())` evaluates to `42` (correct, previously correct only by accident).
- [ ] Nested bounded multishot evaluates correctly.
- [ ] Existing `17-choice-multishot` (tail multishot) still `30`; full suite green.

**Verify:** `cabal test` green; each new file `cabal run -v0 wok -- test/run-examples/<f>.wok --run` prints the value in its `.expected`.

**Steps:**

- [ ] **Step 1: Write the failing matrix (red).** Create these six files and their hand-authored CORRECT goldens.

`test/run-examples/28-bounded-multishot-arith.wok`:
```
module Main
import Std.Base

effect Choice = { flip : Bool }

pick : () -> U64 with Choice
pick u = if Choice.flip then 10 else 20

-- Bounded multishot handler in NON-tail position (operand of +). Both branches
-- must run: k True (10) + k False (20) = 30, then + 0.
main : U64
main = (with { Choice.flip k -> k True + k False
               ; v -> v }
         pick ()) + 0
```
`test/run-golden/28-bounded-multishot-arith.expected`:
```
30
```

`test/run-examples/29-bounded-multishot-prefix.wok`:
```
module Main
import Std.Base

effect Choice = { flip : Bool }

pick : () -> U64 with Choice
pick u = if Choice.flip then 10 else 20

-- Outer context BEFORE the handler: 1 + (10 + 20) = 31.
main : U64
main = 1 + (with { Choice.flip k -> k True + k False
                   ; v -> v }
             pick ())
```
`test/run-golden/29-bounded-multishot-prefix.expected`:
```
31
```

`test/run-examples/30-bounded-multishot-let.wok`:
```
module Main
import Std.Base

effect Choice = { flip : Bool }

pick : () -> U64 with Choice
pick u = if Choice.flip then 10 else 20

-- Handler result bound mid-block, then used. Must be 30.
main : U64
main =
  let r = (with { Choice.flip k -> k True + k False
                  ; v -> v }
            pick ()) in
  r
```
`test/run-golden/30-bounded-multishot-let.expected`:
```
30
```

`test/run-examples/31-bounded-generator-splice.wok`:
```
module Main
import Std.Base

effect Yield = { yield : U64 -> () }

producer : () -> () with Yield
producer u =
  let a = Yield.yield 1 in
  let b = Yield.yield 2 in
  Yield.yield 3

-- Generator (single resume per yield) spliced inline via the bounded form.
-- Must collect [1,2,3] and prepend 100.
main : [U64]
main =
  [100] ++ (with { Yield.yield x k -> [x] ++ k ()
                   ; v             -> [] }
             producer ())
```
`test/run-golden/31-bounded-generator-splice.expected`:
```
[100, 1, 2, 3]
```

`test/run-examples/32-bounded-control-single.wok`:
```
module Main
import Std.Base

effect Ask = { ask : U64 }

prog : () -> U64 with Ask
prog u = Ask.ask

-- Single-shot control resume in non-tail position. Must be 42.
main : U64
main = 1 + (with { Ask.ask k -> k 41 } prog ())
```
`test/run-golden/32-bounded-control-single.expected`:
```
42
```

`test/run-examples/33-bounded-nested-multishot.wok`:
```
module Main
import Std.Base

effect Choice = { flip : Bool }

pick : () -> U64 with Choice
pick u = if Choice.flip then 10 else 20

-- Nested bounded multishot: inner handler bounded, its result used by an outer
-- bounded multishot. Inner = 30; outer sums k True (30) + k False (30) = 60.
main : U64
main =
  (with { Choice.flip k -> k True + k False
          ; v -> v }
    (if Choice.flip
       then (with { Choice.flip k -> k True + k False ; v -> v } pick ())
       else 0))
```
`test/run-golden/33-bounded-nested-multishot.expected`:
```
90
```
> Derivation for `33`: outer `flip` → `k True + k False`. `k True`: outer scrutinee `True` → inner `(with … pick())` = 30. `k False`: `False` → `0`. So `30 + 0 = 30`? Re-derive precisely during execution and set the golden to the observed-correct value AFTER the fix (Step 6) — the inner+outer interaction is exactly what we are validating. Write the file now; set `33`'s `.expected` from the post-fix run (Step 6) and confirm it is stable, not from this comment.

- [ ] **Step 2: Confirm they fail (red).**

Run: `cabal test 2>&1 | grep -E "28-bounded|29-bounded|30-bounded|31-bounded|33-bounded"`
Expected: `28/29/30/31/33` FAIL (actual prints the buggy value: `10`, `11`, `10`, `[100]`, wrong). `32` PASSES already (correct-by-accident) — that is fine; it is a regression guard.

- [ ] **Step 3: Add `hAnswerJoin` to `Handler` (Anf.hs).**

In `src/Wok/IR/Anf.hs`, change the `Handler` record (lines 70-73) to:
```haskell
data Handler = Handler
  { hReturn :: (Binder, Expr)
  , hOps :: [OpArm]
  , hAnswerJoin :: Maybe JoinId
    -- ^ The join point this handler's arms deliver their answer to, when the
    -- handler is in value (non-tail) position; Nothing in tail position. Used
    -- by the interpreter to redirect a resumed sub-run's answer to the resume
    -- call site instead of the static post-handler continuation.
  } deriving (Eq, Show)
```
Update `collectHandler` (line 141) to match the new arity (the field needs no traversal — a `JoinId` binds nothing):
```haskell
collectHandler :: Handler -> HintTable -> HintTable
collectHandler (Handler ret ops _) t =
  let (rb, re) = ret
      t1 = collectExpr re (insertBinder rb t)
  in foldr collectOpArm t1 ops
```
Update `renderHandler` (line 310) pattern to ignore the field (no rendered change, keeps ANF goldens stable):
```haskell
renderHandler fmt tbl (Handler (rb, re) ops _) =
```

- [ ] **Step 4: Set `hAnswerJoin` from the tail continuation (Elaborate.hs).**

In `src/Wok/IR/Elaborate.hs`, `elabKF tk _ (THandle e arms)` (lines 486-497), change the final `pure` to record the answer-join derived from `tk`:
```haskell
  let answerJoin = case tk of
        TJump j -> Just j   -- value position: arms deliver via `jump j`
        TRet    -> Nothing  -- tail position: arms tail-return; nothing to rebind
  pure (Handle handledBody (Handler retArm opArms answerJoin))
```
(`tk` is already in scope as the function argument; `TailK` is `TRet | TJump JoinId` at `Elaborate.hs:87`.)

- [ ] **Step 5: Rebind the answer-join on resume (Machine.hs).**

In `src/Wok/Interp/Machine.hs`, extend the `Wok.IR.Anf` import (lines 13-15) to bring `Atom (..)` into scope (for `AVar`):
```haskell
import Wok.IR.Anf
  ( Alt (..), Atom (..), Binder (..), CoreModule (..), Expr (..), Handler (..)
  , OpArm (..), Rhs (..), TopBind (..) )
```
Then replace `dispatchOp`'s success branch (lines 144-150) with the rebinding resume:
```haskell
        Just oa ->
          -- Deep, multishot resume. When the handler is re-installed over the
          -- resume call site `after`, its ANSWER join (the join its arms deliver
          -- to in value position) must also deliver to `after` -- otherwise a
          -- resumed sub-run's answer escapes via the static post-handler
          -- continuation instead of returning to the resume call site. Rebind it
          -- per resume; the TOP-LEVEL op arm below keeps the original `hsc`, so
          -- the real post-handler work runs once on the final answer.
          let reinstall after =
                let hsc' = case hAnswerJoin h of
                      Just j
                        | Just (JoinPoint _ ps _ _) <- Map.lookup j (scJoins hsc)
                        , (pb : _) <- ps ->
                            hsc { scJoins =
                                    Map.insert j
                                      (JoinPoint hsc ps (Ret (AVar (bndName pb))) after)
                                      (scJoins hsc) }
                      _ -> hsc
                in above (KHandle h hsc' after)
              resumeVal = VCont reinstall
              env1 = bindBinders (oaArgs oa) argVals (scEnv hsc)
              env2 = bindBinder (oaResume oa) resumeVal env1
          in Right (Eval (oaBody oa) (Scope env2 (scJoins hsc)) kBelow)
```
(`JoinPoint Scope [Binder] Expr Kont` is positional — `Value.hs:84`. `bndName` comes from `Binder (..)`. The op arm still runs with the original `scJoins hsc`.)

- [ ] **Step 6: Build, run, verify green.**

Run: `cabal build`
Run each new file and confirm the value:
```
for f in 28-bounded-multishot-arith 29-bounded-multishot-prefix 30-bounded-multishot-let 31-bounded-generator-splice 32-bounded-control-single 33-bounded-nested-multishot; do
  echo -n "$f -> "; cabal run -v0 wok -- test/run-examples/$f.wok --run
done
```
Expected: `30`, `31`, `30`, `[100, 1, 2, 3]`, `42`, and `33`'s stable value. Set `test/run-golden/33-bounded-nested-multishot.expected` to `33`'s observed value and re-run to confirm determinism (run twice; identical).
Run: `cabal run wok-tests -- --accept` — inspect any drift. Only the six new run-goldens should change; if any `anf-golden`/`typed-anf-golden` changes, it must be a no-op whitespace/ordering diff (the `Handler` field is not rendered) — review before accepting. `cabal test` → green (was 562 + 6 new run tests).

- [ ] **Step 7: Commit.**
```bash
git add src/Wok/IR/Anf.hs src/Wok/IR/Elaborate.hs src/Wok/Interp/Machine.hs \
        test/run-examples/28-bounded-multishot-arith.wok test/run-golden/28-bounded-multishot-arith.expected \
        test/run-examples/29-bounded-multishot-prefix.wok test/run-golden/29-bounded-multishot-prefix.expected \
        test/run-examples/30-bounded-multishot-let.wok test/run-golden/30-bounded-multishot-let.expected \
        test/run-examples/31-bounded-generator-splice.wok test/run-golden/31-bounded-generator-splice.expected \
        test/run-examples/32-bounded-control-single.wok test/run-golden/32-bounded-control-single.expected \
        test/run-examples/33-bounded-nested-multishot.wok test/run-golden/33-bounded-nested-multishot.expected
git commit -m "fix(effects): delimit resume in non-tail handlers (rebind answer-join)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: Pin the bounded-handler surface as goldens

**Goal:** The already-working bounded surface — reshape-and-unpack, header form, and the §12 sharp-edge case — is locked in as run-goldens so the additive-sugar form cannot regress.

**Files:**
- Create: `test/run-examples/{34-bounded-reshape-unpack,35-bounded-header}.wok` + matching `test/run-golden/*.expected`

**Acceptance Criteria:**
- [ ] A reshaping handler (`A != R`) bounded mid-function and unpacked via `case` runs (the §12 "requires a helper" case, with no helper).
- [ ] The header form `(with E { unqualified arms } e)` runs bounded.
- [ ] `cabal test` green.

**Verify:** `cabal run -v0 wok -- test/run-examples/34-bounded-reshape-unpack.wok --run` → `1000`; `…/35-bounded-header.wok --run` → `12`.

**Steps:**

- [ ] **Step 1: Write the tests (these already pass on the Task-1 binary; they pin behavior).**

`test/run-examples/34-bounded-reshape-unpack.wok`:
```
module Main
import Std.Base

effect Exn = { throw : String -> Never }

risky : Bool -> U64 with Exn
risky b = if b then Exn.throw "boom" else 7

-- Reshaping handler (computation U64, answer Option U64) bounded mid-function
-- and unpacked. Spec sec.12 claimed this needs a helper; it does not.
main : U64
main =
  let r = (with { Exn.throw m k -> None ; v -> Some v } risky True) in
  case r of
    None   -> 1000
    Some n -> n
```
`test/run-golden/34-bounded-reshape-unpack.expected`:
```
1000
```

`test/run-examples/35-bounded-header.wok`:
```
module Main
import Std.Base

effect State s = { get : s, set : s -> () }
effect Exn = { throw : String -> Never }

prog : () -> U64 with State U64
prog u = State.get

risky : Bool -> U64 with Exn
risky b = if b then Exn.throw "boom" else 7

-- Bounded header form + bounded headerless form, both mid-block via let.
main : U64
main =
  let a = (with State { get -> 5 ; set s -> () } prog ()) in
  let b = (with { Exn.throw m k -> 0 ; v -> v } risky False) in
  a + b
```
`test/run-golden/35-bounded-header.expected`:
```
12
```

- [ ] **Step 2: Build, run, verify.**

Run: `cabal run -v0 wok -- test/run-examples/34-bounded-reshape-unpack.wok --run` → `1000`
Run: `cabal run -v0 wok -- test/run-examples/35-bounded-header.wok --run` → `12`
Run: `cabal run wok-tests -- --accept` (only the two new run-goldens may appear); `cabal test` → green.

- [ ] **Step 3: Commit.**
```bash
git add test/run-examples/34-bounded-reshape-unpack.wok test/run-golden/34-bounded-reshape-unpack.expected \
        test/run-examples/35-bounded-header.wok test/run-golden/35-bounded-header.expected
git commit -m "test(effects): pin bounded (with H e) surface — reshape-unpack, header

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 3: Reconcile the docs + roadmap + memory; verify full green

**Goal:** The roadmap marks slice 3 done; the surface spec states the bounded form is `(with H e)` (no separator) and works for all handler kinds; the "extract a helper today" workaround text is removed; the memory records the slice and the delimiter fix.

**Files:**
- Modify: `docs/superpowers/specs/2026-06-05-effect-handlers-ROADMAP.md` (status board + slice-3 entry), `docs/superpowers/specs/2026-06-05-effect-handler-surface-syntax.md` (§4.1, §11, §12), memory `effect-surface-syntax-final`
- Create: memory `effects-slice-3-bounded-handlers`

**Acceptance Criteria:**
- [ ] ROADMAP status board slice-3 row reads DONE with the test count; the slice-3 entry notes "additive surface already parsed; the substance was the non-tail-resume delimiter fix."
- [ ] Surface spec §4.1/§11 give `(with H e)` (no separator) as the bounded form and drop "extract a helper today"; §12's "reshaping mid-function requires a helper" sharp edge is struck (resolved).
- [ ] Memory `effect-surface-syntax-final` notes the bounded form is `(with H e)`; new memory `effects-slice-3-bounded-handlers` records the delimiter root cause + fix.
- [ ] `cabal test` fully green; `rg -n "with H ; e|extract a helper" docs/superpowers/specs` returns no stale matches in the bounded-form context.

**Verify:** `cabal test` green; `rg -n "with H ; e" docs/superpowers/specs` → no matches.

**Steps:**

- [ ] **Step 1: Update the ROADMAP.** In `docs/superpowers/specs/2026-06-05-effect-handlers-ROADMAP.md`:
  - Status board: set the slice-3 row state to `DONE — merged to main (NNN tests green)` (fill NNN from `cabal test`); until merge, `DONE on feat/effects-slice-3-bounded-handlers`.
  - The `### Slice 3 — bounded (with H ; e)` section: replace the note with: "Surface is `(with H e)` (parenthesized prefix; no separator — `;` would overload the arm separator and a dedicated paren production conflicts with `EParen`+`EWith`). The substance was a runtime fix: a resuming handler in non-tail position did not delimit its continuation; `resume` now rebinds the handler's answer-join to the resume call site. See `2026-06-06-effects-slice-3-bounded-handlers-design.md`. Plan: `docs/superpowers/plans/2026-06-06-effects-slice-3-bounded-handlers.md`."

- [ ] **Step 2: Update the surface spec.** In `docs/superpowers/specs/2026-06-05-effect-handler-surface-syntax.md`:
  - §4.1: change "To bound a handler to less than a whole body today, extract a helper function (or a lambda) … The dedicated bounded form `(with H ; e)` is a deferred, purely additive follow-up (section 10)." to: "To bound a handler to less than a whole body, parenthesize it: `(with H e)` scopes the handler to just `e`. This is the bounded form — additive surface over the prefix `with`, correct for all handler kinds (see slice 3)."
  - §11: change the "Bounded handler scope `(with H ; e)`" bullet to "Bounded handler scope `(with H e)` — **shipped (slice 3).** Parenthesized prefix; no separator."
  - §12: strike the second sharp edge ("combined with the deferred bounded form, reshaping handlers that must be unpacked mid-function require a helper") — replace with "(resolved in slice 3: `let r = (with H e) in …` unpacks a reshaping handler mid-function with no helper)."

- [ ] **Step 3: Update memory.** Edit `/Users/zy/.claude/projects/-Users-zy-wokml/memory/effect-surface-syntax-final.md`: add that the bounded form is `(with H e)` (no separator; rejected `;`/`in`). Create `/Users/zy/.claude/projects/-Users-zy-wokml/memory/effects-slice-3-bounded-handlers.md` (type project) recording: bounded form parses for free via `EParen`+`EWith`; the real work was the non-tail-resume delimiter fix (handler arms `jump` an answer-join; `resume` now rebinds it to the call site via `hAnswerJoin` + `dispatchOp`); link `[[effect-surface-syntax-final]]`, `[[effect-compilation-strategy]]`. Add both one-line pointers to `MEMORY.md`.

- [ ] **Step 4: Verify no stale syntax + full green.**

Run: `rg -n "with H ; e|extract a helper" docs/superpowers/specs`
Expected: no matches in the bounded-form context.
Run: `cabal test`
Expected: all green.

- [ ] **Step 5: Commit.**
```bash
git add docs/superpowers/specs/2026-06-05-effect-handlers-ROADMAP.md docs/superpowers/specs/2026-06-05-effect-handler-surface-syntax.md
git commit -m "docs(effects): slice 3 done — bounded (with H e), delimiter fix; reconcile spec/roadmap

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```
(The memory files are outside the repo; update them with the Write tool, not a git commit.)

---

## Self-review

- **Spec coverage:** §1 decision (bless `(with H e)`, no separator, no grammar) → no grammar task by design (Task 2 pins it as goldens; Task 3 documents it). §2 root cause + §3 fix → Task 1. §3 correctness matrix → Task 1 Steps 1/6. §4 bounded-surface goldens → Task 2. §4 docs/roadmap/memory reconcile → Task 3. §4 out-of-scope (clean State, async, separator) → not built (correct); State verified-not-promised (no task claims it).
- **Placeholder scan:** the only soft spot is `33`'s golden value — Step 1 writes the file with a provisional comment and Step 6 explicitly sets `.expected` from the post-fix observed (stable, run-twice) value; this is the one case where the correct number must be observed, not hand-derived, and the plan says so concretely.
- **Type consistency:** `hAnswerJoin :: Maybe JoinId` added to `Handler` (Anf), set in `Elaborate` from `TailK` (`TRet`/`TJump j` per `Elaborate.hs:87`), consumed in `Machine.dispatchOp` via `hAnswerJoin h`; `JoinPoint Scope [Binder] Expr Kont` positional per `Value.hs:84`; `Ret`/`AVar`/`bndName` reachable after adding `Atom (..)` to Machine's `Wok.IR.Anf` import. All three `Handler` sites (construct at `Elaborate.hs:497`; match at `Anf.hs:141,310`) updated for the new field.
- **Ordering / dependencies:** 1 → 2 → 3. Task 1 is the risk and is first (TDD: failing matrix before the fix). Task 2 depends on Task 1's binary (cases must be correct). Task 3 depends on both and finalizes counts.
- **Risk front-loading:** the machine rebind (Task 1 Step 5) is the riskiest change and sits behind the failing matrix (Steps 1-2), so it is proven before docs.
