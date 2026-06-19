# M2b resume-binder-type RC leak — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers-extended-cc:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix the silent RC leak where a handler op-arm that discards `resume` leaks the captured continuation's owned set when the handler's answer type is unboxed, by typing the resume binder as the continuation type `T -> R` the checker already computes.

**Architecture:** Thread the already-computed `resume : T -> R` from `Infer.hs` onto the typed `TOpArm` node and stamp it onto the elaborated binder, replacing the wrong `teType body` (answer type `R`). `Wok.IR.Perceus` is untouched — the corrected (always-boxed arrow) type flows through its existing audited owned-set path. Coverage: a file corpus for end-to-end RC run-the-exploit + red-check, and an in-memory QuickCheck property at the typechecker layer.

**Tech Stack:** Haskell, GHC 9.10, cabal, tasty + Hspec + QuickCheck. Spec: `docs/superpowers/specs/2026-06-19-m2b-resume-binder-type-leak-fix-design.md`.

**Branch:** `feat/m2b-resume-binder-type-leak-fix` (off `main` @ `56a6a8e`). Do NOT merge to `main` — the full-branch `/code-review` is the user's gate.

**Build/test commands:**
- Build exe: `cabal build exe:wok`
- Exe path: `BIN=$(cabal list-bin exe:wok)`
- Stats on one program: `"$BIN" <file.wok> --dump-rc-stats`
- Perceus dump: `"$BIN" <file.wok> --dump-perceus`
- Full test suite: `cabal test 2>&1 | tail -40`
- A single tasty group: `cabal test --test-options='-p "<pattern>"' 2>&1 | tail -40`

---

## Task 1: Red-state reproducers (file corpus)

**Goal:** Land the leak reproducers and balanced regression locks as `test/rc-m2b` corpus files; confirm the unboxed-answer discard arms are RED (heap-imbalanced) on the current branch, before any fix.

**Files:**
- Create: `test/rc-m2b/30-discard-unboxed-answer-leak.wok`
- Create: `test/rc-m2b/31-discard-never-unboxed-answer-leak.wok`
- Create: `test/rc-m2b/32-discard-unboxed-answer-wildcard.wok`
- Create: `test/rc-m2b/33-discard-boxed-answer-balanced.wok`
- Create: `test/rc-m2b/34-split-result-boxed-answer-unboxed.wok`
- Create: `test/rc-m2b/35-apply-unboxed-answer.wok`

**Acceptance Criteria:**
- [ ] Files 30, 31, 32, 34 are heap-IMBALANCED (`allocs > frees`) under `--dump-rc-stats` on this branch (the leak, reproduced).
- [ ] Files 33 and 35 are heap-BALANCED on this branch (boxed-answer discard already works; apply arm already works).
- [ ] Every file's RC result equals its reference-interpreter result (correct value; only the heap leaks) — verified by the auto-wired `rc-m2b` differential harness once the suite runs.

**Verify:**
```bash
BIN=$(cabal list-bin exe:wok)
for f in 30-discard-unboxed-answer-leak 31-discard-never-unboxed-answer-leak \
         32-discard-unboxed-answer-wildcard 34-split-result-boxed-answer-unboxed; do
  echo "== $f (expect allocs > frees) =="; "$BIN" test/rc-m2b/$f.wok --dump-rc-stats
done
for f in 33-discard-boxed-answer-balanced 35-apply-unboxed-answer; do
  echo "== $f (expect allocs == frees) =="; "$BIN" test/rc-m2b/$f.wok --dump-rc-stats
done
```
Expected: the first loop shows `frees` < `allocs`; the second shows `frees == allocs`.

**Steps:**

- [ ] **Step 1: Write the headline leak repro (resumable op, unboxed U64 answer, named discard).** This content is already verified to leak (5/0).

`test/rc-m2b/30-discard-unboxed-answer-leak.wok`:
```
module Main
import Std.Base

-- M2b resume-binder-type leak (spec 2026-06-19): a resumable op whose arm BINDS
-- but DISCARDS resume, with an UNBOXED answer type (U64). 'xs' is boxed and live
-- across the op (in the captured continuation's owned set). Before the fix the
-- resume binder is typed with the answer type U64 (unboxed) and is excluded from
-- the arm's owned set, so __rc_drop(resume) is omitted and xs leaks. After the
-- fix resume is typed T -> R (boxed) and the owned set is freed. Heap must
-- return to baseline.
effect Choose = { choose : U64 -> U64 }

prog : Choose -> U64 with Choose
prog e =
  let xs = [1, 2, 3] in
  let u  = e.choose 9 in
  case xs of
    []       -> 0
    (h :: _) -> h

run : (Choose -> U64 with Choose + eff e) -> U64 with eff e
run c = with self = Choose { choose n k -> 88 ; v -> v } in c self

main : U64
main = run prog
```

- [ ] **Step 2: Write the Never-op variant (proves it is NOT Never-specific).** Verified to leak (5/0).

`test/rc-m2b/31-discard-never-unboxed-answer-leak.wok`:
```
module Main
import Std.Base

-- Same leak with a Never-typed op and an UNBOXED answer (U64): the Never typing
-- does NOT save it (refutes the M3 spec's Never-vs-resumable framing). Heap must
-- return to baseline after the fix.
effect Exn = { throw : U64 -> Never }

prog : Exn -> U64 with Exn
prog e =
  let xs = [1, 2, 3] in
  let u  = e.throw 9 in
  case xs of
    []       -> 0
    (h :: _) -> h

run : (Exn -> U64 with Exn + eff e) -> U64 with eff e
run c = with self = Exn { throw n k -> 88 ; v -> v } in c self

main : U64
main = run prog
```

- [ ] **Step 3: Write the wildcard-discard variant (the other discard path).**

`test/rc-m2b/32-discard-unboxed-answer-wildcard.wok`:
```
module Main
import Std.Base

-- The wildcard-discard arm (`choose n _ -> ...`) takes the same control path as a
-- named-but-unused arm: body typed R, resume discarded. Leaks identically when R
-- is unboxed. Heap must return to baseline after the fix.
effect Choose = { choose : U64 -> U64 }

prog : Choose -> U64 with Choose
prog e =
  let xs = [1, 2, 3] in
  let u  = e.choose 9 in
  case xs of
    []       -> 0
    (h :: _) -> h

run : (Choose -> U64 with Choose + eff e) -> U64 with eff e
run c = with self = Choose { choose n _ -> 88 ; v -> v } in c self

main : U64
main = run prog
```

- [ ] **Step 4: Write the decisive control (op result boxed, answer unboxed).** Verified to leak (5/0) — proves it is the answer type, not the op result type.

`test/rc-m2b/34-split-result-boxed-answer-unboxed.wok`:
```
module Main
import Std.Base

-- Op RESULT type is [U64] (boxed) but the handler ANSWER type is U64 (unboxed).
-- Still leaks before the fix -> the leak is driven by the ANSWER type, not the op
-- result type. Heap must return to baseline after the fix.
effect Choose = { choose : U64 -> [U64] }

prog : Choose -> U64 with Choose
prog e =
  let xs = [1, 2, 3] in
  let u  = e.choose 9 in
  case xs of
    []       -> 0
    (h :: _) -> h

run : (Choose -> U64 with Choose + eff e) -> U64 with eff e
run c = with self = Choose { choose n k -> 88 ; v -> v } in c self

main : U64
main = run prog
```

- [ ] **Step 5: Write the boxed-answer balanced lock (regression guard).** Verified balanced (8/8); must STAY balanced after the fix (no double-free).

`test/rc-m2b/33-discard-boxed-answer-balanced.wok`:
```
module Main
import Std.Base

-- Boxed answer ([U64]) discard arm: already balanced before the fix (the boxed
-- answer coincidentally typed resume boxed). Must STAY balanced after the fix
-- (no double-free regression on the previously-working path).
effect Choose = { choose : U64 -> U64 }

prog : Choose -> [U64] with Choose
prog e =
  let xs = [1, 2, 3] in
  let u  = e.choose 9 in
  xs

run : (Choose -> [U64] with Choose + eff e) -> [U64] with eff e
run c = with self = Choose { choose n k -> [9, 9] ; v -> v } in c self

main : [U64]
main = run prog
```

- [ ] **Step 6: Write the apply-path lock (unboxed answer, resume APPLIED).** Guards §7.6: after the fix `resume` is in the owned set AND applied; the move-out must still prevent a double-free.

`test/rc-m2b/35-apply-unboxed-answer.wok`:
```
module Main
import Std.Base

-- Unboxed answer (U64), arm APPLIES resume (resume now in the owned set after the
-- fix AND consumed as a move-out). Must be balanced before AND after the fix (the
-- move-out, not the owned-set drop, consumes resume; no double-free).
effect Choose = { choose : U64 -> U64 }

prog : Choose -> U64 with Choose
prog e =
  let xs = [1, 2, 3] in
  let u  = e.choose 9 in
  case xs of
    []       -> u
    (h :: _) -> h

run : (Choose -> U64 with Choose + eff e) -> U64 with eff e
run c = with self = Choose { choose n k -> k 7 ; v -> v } in c self

main : U64
main = run prog
```

- [ ] **Step 7: Build and verify the red/green baseline.** Run the Verify block above. Confirm 30/31/32/34 leak (`frees < allocs`) and 33/35 balance. If 32 (wildcard) or 35 (apply) fail to typecheck/run, adjust the program minimally to a valid shape that preserves the intent (wildcard discard / applied resume) and re-verify; record the final content.

- [ ] **Step 8: Commit.**
```bash
git add test/rc-m2b/30-*.wok test/rc-m2b/31-*.wok test/rc-m2b/32-*.wok \
        test/rc-m2b/33-*.wok test/rc-m2b/34-*.wok test/rc-m2b/35-*.wok
git commit -m "test(m2b): red-state corpus for resume-binder-type leak (unboxed-answer discard)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 2: The fix — thread the resume continuation type

**Goal:** Type the resume binder as the continuation type `T -> R` (always a boxed arrow) the typechecker already computes, replacing the wrong `teType body`. After this task, Task 1's leaking files (30/31/32/34) become heap-balanced; the boxed/apply files (33/35) stay balanced; `Wok.IR.Perceus` is unchanged.

**Files:**
- Modify: `src/Wok/TypeChecking/Typed.hs` (add field to `TOpArm`)
- Modify: `src/Wok/TypeChecking/Infer.hs` (compute + thread `resumeContTy`; widen `goArm`)
- Modify: `src/Wok/TypeChecking/Carrier.hs` (widen 4 `TOpArm` patterns)
- Modify: `src/Wok/IR/Elaborate.hs` (use threaded type for the binder; drop stale comment)

**Acceptance Criteria:**
- [ ] Project builds: `cabal build` clean.
- [ ] `test/rc-m2b/30,31,32,34` are heap-BALANCED (`allocs == frees`); `33,35` stay balanced.
- [ ] `Wok.IR.Perceus.hs` has no logic change (only an optional comment refresh; `git diff` shows no code change there).
- [ ] `--dump-perceus` on file 30 now shows `let _drop = __rc_drop(resume)` in the `choose` arm.

**Verify:**
```bash
cabal build exe:wok 2>&1 | tail -5
BIN=$(cabal list-bin exe:wok)
for f in 30-discard-unboxed-answer-leak 31-discard-never-unboxed-answer-leak \
         32-discard-unboxed-answer-wildcard 34-split-result-boxed-answer-unboxed \
         33-discard-boxed-answer-balanced 35-apply-unboxed-answer; do
  echo "== $f (expect allocs == frees) =="; "$BIN" test/rc-m2b/$f.wok --dump-rc-stats | head -2
done
"$BIN" test/rc-m2b/30-discard-unboxed-answer-leak.wok --dump-perceus | grep -A4 'choose'
```
Expected: all six balanced; the dump shows `__rc_drop(resume)` in the arm.

**Steps:**

- [ ] **Step 1: Add the resume-type field to `TOpArm` (`Typed.hs`).** Insert an `a`-typed field after the resume-name. The datatype derives `Functor/Foldable/Traversable`, so the field is zonked `Type s -> CType` automatically by the existing freeze traversal.

In `src/Wok/TypeChecking/Typed.hs`, change:
```haskell
  | TOpArm Text Text [Tpat a] Text (Texp a)   -- effect, op, args, resume-name, body
```
to:
```haskell
  | TOpArm Text Text [Tpat a] Text a (Texp a) -- effect, op, args, resume-name, resume-type (T -> R), body
```

- [ ] **Step 2: Compute and thread `resumeContTy` in `Infer.hs`.** Hoist the continuation-type computation (currently inside the control branch) above `case binderPs of`, and pass it to every `Ty.TOpArm`. Replace the whole `case binderPs of ...` block (the auto-resume `[]`, wildcard `[Abs.APWild]`, and control `[Abs.APVar ...]` arms) with:

```haskell
          -- The continuation type for this arm's resume binder: T -> R (or
          -- sigma -> T -> R when the handler is parameterized). Computed for
          -- EVERY arm shape so the elaborated resume binder is typed as the
          -- (always-boxed) arrow it is, not the answer type R -- typing it R
          -- mis-marks an unboxed-answer continuation as unboxed, so Perceus omits
          -- its drop on a discard arm and the owned set leaks (spec 2026-06-19).
          resumeRow <- freshRVar
          paramRow  <- freshRVar
          let resumeContTy = case mParam of
                Just (_, paramTy, _) -> arrowT paramTy paramRow (arrowT resultTy resumeRow answerT)
                Nothing              -> arrowT resultTy resumeRow answerT
          case binderPs of
            [] -> do
              -- AUTO-RESUME: no continuation binder; the arm body has the op's
              -- RESULT type and is implicitly resumed with it. The synthesized
              -- resume binder is still typed T -> R.
              (bodyT, bodyNode) <- inferExprW mono1 body
              unify (Just pos) bodyT resultTy
              pure (Ty.TOpArm en op argPatNodes Tx.empty resumeContTy bodyNode)
            [Abs.APWild] -> do
              -- WILDCARD DISCARD: explicit intentional discard; body has the
              -- answer type R; bind nothing; never lint.
              (bodyT, bodyNode) <- inferExprW mono1 body
              unify (Just pos) bodyT answerT
              pure (Ty.TOpArm en op argPatNodes (Tx.pack "_") resumeContTy bodyNode)
            [Abs.APVar (Abs.VarId (_, kname))] -> do
              -- CONTROL: the trailing pattern is the continuation binder `k`,
              -- typed `resumeContTy` so applying it in the body flows its effects
              -- into the outer ambient. Body has the answer type R.
              let mono2 = Map.insert kname resumeContTy mono1
              (bodyT, bodyNode) <- inferExprW mono2 body
              unify (Just pos) bodyT answerT
              -- Forgotten-resume lint: a NAMED binder unreferenced in the body on
              -- a RETURNING op (result /= Never). Wildcard arms never reach here.
              resultTy' <- force resultTy
              let isNever = case resultTy' of TCon TcNever [] -> True; _ -> False
              unless (isNever || texpMentions kname bodyNode) $
                addWarning (ForgottenResume (Just pos) en op)
              pure (Ty.TOpArm en op argPatNodes kname resumeContTy bodyNode)
            _ ->
              -- More than `arity + 1` patterns, or a non-variable continuation
              -- binder: not a valid operation arm shape.
              throwError (MalformedHandlerArm (Just pos) en op)
```

(This preserves the existing control-branch semantics exactly — same `freshRVar` open rows, same `mono2` binding, same lint — and only hoists the computation so all three branches thread the same `resumeContTy`.)

- [ ] **Step 3: Widen the `goArm` pattern in `Infer.hs`.** Find (~line 2085):
```haskell
    goArm (Ty.TOpArm _ _ _ _ b) = goE b
```
change to:
```haskell
    goArm (Ty.TOpArm _ _ _ _ _ b) = goE b
```

- [ ] **Step 4: Widen the four `TOpArm` patterns in `Carrier.hs`.** Add one `_` for the new field at each site:
  - `TOpArm _ _ pats _ body ->` becomes `TOpArm _ _ pats _ _ body ->` (the sites that ignore the resume name)
  - `TOpArm _ _ pats res body ->` becomes `TOpArm _ _ pats res _ body ->` (the site that binds `res`)

Run `grep -n "TOpArm" src/Wok/TypeChecking/Carrier.hs` and fix each of the 4 matches accordingly.

- [ ] **Step 5: Use the threaded type for the binder in `Elaborate.hs`.** Update the destructuring and `elabOpArm`.

In `src/Wok/IR/Elaborate.hs`, change the comprehension (~line 553):
```haskell
  let opArmsSrc  = [ (effect, op, ps, resume, body)
                   | TOpArm effect op ps resume body <- arms ]
```
to:
```haskell
  let opArmsSrc  = [ (effect, op, ps, resume, resumeTy, body)
                   | TOpArm effect op ps resume resumeTy body <- arms ]
```

Change `elabOpArm`'s signature and tuple (~line 600):
```haskell
    elabOpArm :: TailK -> Maybe (Name, Text, TExpr) -> (Text, Text, [TPat], Text, TExpr) -> Elab OpArm
    elabOpArm tk2 mParam (effect, op, ps, resumeName, body) = do
```
to:
```haskell
    elabOpArm :: TailK -> Maybe (Name, Text, TExpr) -> (Text, Text, [TPat], Text, CType, TExpr) -> Elab OpArm
    elabOpArm tk2 mParam (effect, op, ps, resumeName, resumeContTy, body) = do
```

Replace the final `pure (OpArm ...)` and its NOTE comment (~lines 621-627):
```haskell
      -- NOTE: the resume binder is annotated with `teType body`, ... (roadmap follow-up).
      pure (OpArm effect op argBinders (Binder resumeN Unrestricted (teType body)) armBody)
```
with:
```haskell
      -- The resume binder is typed with the threaded continuation type T -> R
      -- (always a boxed arrow), NOT `teType body` (the answer type R) which would
      -- mis-mark an unboxed-answer continuation as unboxed and leak its owned set
      -- on a discard arm (spec 2026-06-19). `resumeContTy` is the type the
      -- checker bound `k` to when checking this arm body.
      pure (OpArm effect op argBinders (Binder resumeN Unrestricted resumeContTy) armBody)
```

Confirm `CType` is in scope in `Elaborate.hs` (it is — used elsewhere in the module).

- [ ] **Step 6: Build.** Run `cabal build 2>&1 | tail -20`. Fix any missed `TOpArm` pattern (compile error points to the site). If the freeze step errors on an unconstrained row var in the auto-resume/wildcard `resumeContTy` (unlikely — unconstrained vars generalize, per the `id x = x` precedent), fall back to building those two branches' `resumeContTy` with `CREmpty` rows instead of `freshRVar` (still a boxed `CTArr`); keep the control branch's open rows unchanged (its body relies on them for effect flow).

- [ ] **Step 7: Verify the fix.** Run the Task 2 Verify block. All six corpus files must be balanced and the dump must show `__rc_drop(resume)`.

- [ ] **Step 8: Confirm Perceus untouched.** `git diff --stat src/Wok/IR/Perceus.hs` shows no change (or only a comment). If logic changed, revert it — the fix must be type-only.

- [ ] **Step 9: Run the full suite.** `cabal test 2>&1 | tail -40`. All green (the previously-red corpus files now pass; nothing else regresses). Investigate any failure before proceeding.

- [ ] **Step 10: Commit.**
```bash
git add src/Wok/TypeChecking/Typed.hs src/Wok/TypeChecking/Infer.hs \
        src/Wok/TypeChecking/Carrier.hs src/Wok/IR/Elaborate.hs
git commit -m "fix(m2b): type resume binder as the continuation T -> R, not the answer R

Root cause of the silent owned-set leak on unboxed-answer discard arms:
elabOpArm stamped the resume binder with teType body (the answer type R); when R
was unboxed, Perceus's boxedBinder excluded resume from the arm owned set and
omitted __rc_drop(resume). Thread the checker's already-computed resume : T -> R
(an always-boxed arrow) onto TOpArm and stamp it on the binder. Perceus
unchanged: the corrected type flows through its existing audited owned-set path.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 3: Typechecker / inference property tests

**Goal:** Add an in-memory QuickCheck property at the typechecker layer: for every generated well-typed handler, every elaborated/typed resume binder is a boxed arrow (`T -> R`). This is the user's explicit request and would have caught the bug; it covers the leak class's breadth generatively without touching `genProgram`.

**Files:**
- Modify: `test/Spec.hs` (new `resumeBinderTypeTests` group + generator; register in the suite tree)

**Acceptance Criteria:**
- [ ] `resumeBinderTypeTests` is registered in the `defaultMain` tree (beside `inferTypedTests`).
- [ ] Property P1 (resume binder is a `CTArr`) passes across generated answer types and arm shapes, with `checkCoverage` confirming both boxed and unboxed answer types are generated.
- [ ] Property P2 (the arrow's domain/codomain match the op result `T` / answer `R`) passes.
- [ ] Property P4 (`isBoxedType (CTArr a r b) == True`) passes.
- [ ] Reverting Task 2 turns P1 red (record this in Task 4, do not revert here).

**Verify:** `cabal test --test-options='-p "resumeBinderType"' 2>&1 | tail -30` → all properties pass; coverage satisfied.

**Steps:**

- [ ] **Step 1: Write the generator (in-memory, builtins-only source).** Add to `test/Spec.hs`. Use only builtin types so `B.initialEnv` suffices (no `Std.Base`/loader). Representative types with sample literals:

```haskell
-- (label, type-text, sample-literal-text, isBoxed)
data RTy = RTy { rtyText :: String, rtyLit :: String, rtyBoxed :: Bool }

reprTys :: [RTy]
reprTys =
  [ RTy "U64"        "0"      False
  , RTy "Unit"       "()"     False
  , RTy "String"     "\"s\""  False
  , RTy "[U64]"      "[0]"    True
  , RTy "(U64, U64)" "(0, 0)" True
  ]

data ArmShape = DiscardNamed | DiscardWild | ApplyNamed | AutoResume
  deriving (Show, Eq, Enum, Bounded)

-- Render a self-contained, well-typed handler module. Op result type = tRes,
-- answer type = rAns. Only the arm shape and the two types vary.
renderHandlerSrc :: RTy -> RTy -> ArmShape -> String
renderHandlerSrc tRes rAns shape = unlines
  [ "module Main"
  , "effect E = { op : U64 -> " ++ rtyText tRes ++ " }"
  , "prog : E -> " ++ rtyText rAns ++ " with E"
  , "prog e ="
  , "  let u = e.op 0 in"
  , "  " ++ rtyLit rAns
  , "run : (E -> " ++ rtyText rAns ++ " with E + eff f) -> " ++ rtyText rAns ++ " with eff f"
  , "run c = with self = E { " ++ armText ++ " ; v -> v } in c self"
  , "main : " ++ rtyText rAns
  , "main = run prog"
  ]
  where
    armText = case shape of
      DiscardNamed -> "op n k -> " ++ rtyLit rAns
      DiscardWild  -> "op n _ -> " ++ rtyLit rAns
      ApplyNamed   -> "op n k -> k 0"          -- resumes; arm value = resumed value : R
      AutoResume   -> "op n -> 0"              -- auto-resume: body has op-result type U64

genHandlerSrc :: Gen (String, RTy, RTy, ArmShape)
genHandlerSrc = do
  tRes  <- elements reprTys
  rAns  <- elements reprTys
  shape <- elements [minBound .. maxBound]
  -- AutoResume's body must have the op RESULT type (U64 here); only emit it when
  -- that arm shape is type-consistent with the skeleton (op result U64).
  let shape' = if shape == AutoResume && rtyText tRes /= "U64" then DiscardNamed else shape
  pure (renderHandlerSrc tRes rAns shape', tRes, rAns, shape')
```

(If `AutoResume`/`ApplyNamed` rendering proves not to typecheck for some `tRes`/`rAns`
combos, constrain the generator so every emitted program types — a rejected program is a
generator bug, not a `discard`. Simplify to `[DiscardNamed, DiscardWild]` if the apply/auto
shapes need the op result type pinned to match `R`; the discard shapes are the leak-bearing
ones and are the priority.)

- [ ] **Step 2: Write a typed-AST walker for resume binders.** Collect every `TOpArm`'s resume-type field from the inferred decls. Add to `test/Spec.hs`:

```haskell
-- Every TOpArm resume-type annotation reachable in the inferred decls.
resumeTysOf :: [I.TypedDecl] -> [Ty.CType]
resumeTysOf = concatMap (concatMap armTy . TC.tdClauses)
  where
    armTy (_pats, body) = goE body
    goE (Typed.Texp _ f) = goF f
    goF f = case f of
      Typed.THandle e arms        -> goE e ++ concatMap goArm arms
      Typed.TWithNamedH _ arms e  -> concatMap goArm arms ++ goE e
      Typed.TApp h as             -> goE h ++ concatMap goE as
      Typed.TLam _ e              -> goE e
      Typed.TIf a b c             -> goE a ++ goE b ++ goE c
      Typed.TTuple es             -> concatMap goE es
      Typed.TList es              -> concatMap goE es
      Typed.TProj e _             -> goE e
      Typed.TPerformOn e _ _      -> goE e
      Typed.TRecord _ fs          -> concatMap (goE . snd) fs
      Typed.TRecordExt _ e fs     -> goE e ++ concatMap (goE . snd) fs
      Typed.TLet ds e             -> concatMap goLD ds ++ goE e
      Typed.TCase e alts          -> goE e ++ concatMap goAlt alts
      _                           -> []
    goArm (Typed.TOpArm _ _ _ _ rty b) = [rty] ++ goE b   -- the new field
    goArm (Typed.TReturnArm _ b)       = goE b
    goArm (Typed.TParamArm _ e)        = goE e
    goAlt (Typed.TAlt _ ds e)          = concatMap goLD ds ++ goE e
    goLD (Typed.TLocalDecl _ _ e)      = goE e
```

(Adjust constructor names/imports to match `Wok.TypeChecking.Typed`; the goal is to reach every `TOpArm` regardless of where the handler nests.)

- [ ] **Step 3: Write the properties.** Add the group:

```haskell
resumeBinderTypeTests :: TestTree
resumeBinderTypeTests = testGroup "resumeBinderType"
  [ testProperty "P1: every resume binder is a boxed arrow (CTArr)" $
      forAll genHandlerSrc $ \(src, _tRes, rAns, shape) ->
        cover 20 (rtyBoxed rAns)       "boxed answer"   $
        cover 20 (not (rtyBoxed rAns)) "unboxed answer" $
        cover 15 (shape == DiscardNamed || shape == DiscardWild) "discard arm" $
        case typeCheckSrc src of
          Left e   -> counterexample ("typecheck failed (generator bug):\n" ++ src ++ "\n" ++ e) False
          Right ds ->
            let rtys = resumeTysOf ds
            in counterexample ("resume types: " ++ show rtys ++ "\n" ++ src) $
               not (null rtys) && all isArrow rtys
  , testProperty "P2: resume arrow codomain matches the answer type token" $
      forAll genHandlerSrc $ \(src, _tRes, rAns, _shape) ->
        case typeCheckSrc src of
          Left _   -> property True   -- covered by P1's counterexample
          Right ds -> all (codomainMatches rAns) (resumeTysOf ds)
  , testProperty "P4: any arrow type is boxed" $
      forAll genArrow $ \cty -> Escape.isBoxedType cty
  ]
  where
    isArrow (Ty.CTArr _ _ _) = True
    isArrow _                = False
```

Helpers to add:
```haskell
-- Parse + reorder + infer a self-contained module under the builtins env.
typeCheckSrc :: String -> Either String [I.TypedDecl]
typeCheckSrc src =
  case parse (T.pack src) of
    Left e    -> Left ("parse: " ++ e)
    Right ast -> case reorderModule ast of
      Left es -> Left ("reorder: " ++ show es)
      Right rm -> case TC.inferProgramWith B.initialEnv SO.Embedded (reorderedAst rm) of
        Left e             -> Left ("infer: " ++ show e)
        Right (_, ds, _)   -> Right ds

-- The codomain (innermost arrow result) names the answer type's tycon.
codomainMatches :: RTy -> Ty.CType -> Bool
codomainMatches rAns = go
  where
    go (Ty.CTArr _ _ b) = go b
    go t                = renderCTy t == rtyText rAns   -- compare tycon shape

genArrow :: Gen Ty.CType
genArrow = do
  a <- elements [Ty.CTCon Ty.TcU64 [], Ty.CTCon Ty.TcUnit [], Ty.CTCon Ty.TcList [Ty.CTCon Ty.TcU64 []]]
  b <- elements [Ty.CTCon Ty.TcU64 [], Ty.CTCon Ty.TcBool []]
  pure (Ty.CTArr a Ty.CREmpty b)
```

(`renderCTy` may already exist as a test helper, e.g. via `Anf.prettyCTypeLocal` or
`Infer.prettyCType`; reuse one rather than writing a new pretty-printer. If P2's exact-match
proves brittle against generalized rows/vars, weaken it to "the codomain is a `CTCon` whose
head matches `rAns`'s tycon" — P1 is the load-bearing property.)

- [ ] **Step 4: Register the group.** Add `resumeBinderTypeTests` to the `defaultMain $ testGroup "wok" [ ... ]` list in `test/Spec.hs`, near `inferTypedTests`.

- [ ] **Step 5: Run and tune.** `cabal test --test-options='-p "resumeBinderType"' 2>&1 | tail -40`. Fix generator type-errors (any program that fails to typecheck is a generator bug — fix the template/knobs, not by `discard`). Confirm coverage floors are met.

- [ ] **Step 6: Commit.**
```bash
git add test/Spec.hs
git commit -m "test(m2b): typechecker property — resume binder is always a boxed arrow

Generative in-memory property over well-typed handlers: every TOpArm resume
binder is a CTArr (T -> R), across boxed/unboxed answer types and arm shapes.
Would have caught the resume-binder-type leak at the type layer. genProgram
(Core-level, no handlers) is untouched.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 4: Adversarial review and full verification

**Goal:** Independently verify the fix is sound and complete — build the exploit, prove the red-check, confirm no double-free regression, and run the full suite — before handing to the user's `/code-review` gate.

**Files:** none (review + verification only; may add a corpus file if a gap is found).

**Acceptance Criteria:**
- [ ] Red-check proven: reverting Task 2's commit makes a named test (a Task-1 corpus file AND property P1) go red; restoring makes it green.
- [ ] No double-free: files 33 and 35 balanced; the `Never` abort tests `02`/`03` balanced.
- [ ] `Wok.IR.Perceus.hs` confirmed logic-unchanged.
- [ ] Consistency checks (spec §6) discharged: no other reader of the resume binder's `bndType` is disturbed; the threaded type survives zonking; derived `Foldable`/`Traversable` consumers unaffected.
- [ ] Full suite green: `cabal test 2>&1 | tail -20`.

**Steps:**

- [ ] **Step 1: Red-check.** `git stash` or `git revert --no-commit` the Task 2 fix commit; rebuild; confirm `test/rc-m2b/30` leaks again and property P1 fails; restore the fix; confirm green. Record the exact before/after stats.

- [ ] **Step 2: Build-the-exploit sweep.** Dispatch a FRESH adversarial reviewer (subagent) to: (a) construct additional discard-resume shapes not in the corpus (nested handler, parameterized handler with unboxed answer discard, value-position/`Option`-wrapped unboxed inner) and check heap balance; (b) attempt a double-free on the apply path and the boxed-answer path; (c) confirm the §6 consistency items by code inspection. Add any genuinely-leaking or double-freeing shape found as a new corpus file and fix.

- [ ] **Step 3: Spec consistency (§6).**
  - Grep for other consumers of the resume binder's type: `grep -rn "oaResume\|bndType" src/` and confirm only `Perceus.boxedBinder` depends on its boxedness.
  - Confirm parameterized handlers (M2b-2) still pass: run `test/rc-m2b/20-state-tail.wok`, `24-state-value.wok` balanced.
  - Confirm `Never` abort unchanged-balanced: `test/rc-m2b/02`, `03`, `23`, `25`.

- [ ] **Step 4: Full suite + lint.** `cabal test 2>&1 | tail -20` (all green). `hlint src/Wok/TypeChecking/ src/Wok/IR/Elaborate.hs` (ignore `src-generated`); address real suggestions.

- [ ] **Step 5: Update memory + final commit.** Record the finding (the boxed-vs-unboxed-answer axis; the refutation of the Never-vs-resumable framing; the type-only fix; Perceus untouched) in a project memory. Commit any review-driven additions.
```bash
git add -A
git commit -m "test(m2b): adversarial review additions + red-check record for resume-binder-type fix

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

- [ ] **Step 6: Hand off (do NOT merge).** Leave the branch ready; summarize for the user's full-branch `/code-review` gate.

---

## Self-Review (plan vs spec)

- **Spec coverage:** §3 root cause → Task 2; §4.3 threading → Task 2; §7.7 type-layer property → Task 3; §7 items 1-6 RC corpus/red-check/apply-path → Tasks 1 & 4; §6 consistency checks → Task 4 Step 3; §0/§4.1 Perceus-untouched → Task 2 AC + Task 4. Covered.
- **Placeholder scan:** the fix code (Task 2) is exact; the test code (Task 3) is concrete with named fallbacks where generator/printers may need adjustment (legitimate iteration, not placeholders).
- **Type consistency:** the `TOpArm` field is added in Task 2 Step 1 and consumed with matching arity in Steps 2-5 and in Task 3's walker (`TOpArm _ _ _ _ rty b`). `resumeContTy : CType` post-elaboration; the tuple type in `elabOpArm` uses `CType`.
- **Scope:** single focused fix + its tests; `Perceus`/`genProgram` untouched; no unrelated refactor.
