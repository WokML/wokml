# `as` As-Patterns Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers-extended-cc:subagent-driven-development (recommended) or superpowers-extended-cc:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `as` as-patterns (`pat as name`, name LAST, OCaml/F# style) to the wok language — match a structure and bind a name to the whole matched value — working everywhere `AtomPat` appears.

**Architecture:** A native typed node `TPAs Text (Tpat a)` carried from the grammar (`Abs.APAs`) through inference into both elaboration paths: the single-`Alt` `elabPatF` path (case arms, single-clause functions, lambdas, let/where) and the `Wok.IR.Match` decision-tree compiler (multi-clause functions). In `Match`, a new `MAs Text MPat` node is *peeled* at the top of `compileMatch`/`matchCoverage` — binding the as-name to the column's scrutinee atom and replacing the column with the inner pattern — so the matrix operations never see it. The surface uses the `as` keyword (`"as"` becomes a reserved token via the production); `@` is left untouched in `VarSym` (no lexer-class change, no fixture migration) — it is earmarked for future visible type application.

**Tech Stack:** Haskell, BNFC (grammar → `src-generated/GeneratedParser`), Alex/Happy, Cabal, tasty/tasty-golden.

**Source spec:** `docs/superpowers/specs/2026-06-07-as-patterns-design.md`

**Global build/test commands:**
- Build: `cabal build`
- Full suite: `cabal test` (587 green at plan start)
- Run a file: `cabal run -v0 wok -- <file.wok> --run`
- Dump ANF: `cabal run -v0 wok -- <file.wok> --dump-anf`
- Accept goldens (READ diffs first): `cabal run wok-tests -- --accept`
- Regenerate parser: `bnfc --haskell -d -p GeneratedParser --text-token -o src-generated grammar/Wok.cf`

**Warnings discipline:** hand-written code is `-Wall -Werror -Wincomplete-patterns`. Every `case`/function over `Abs.AtomPat`, `TpatF`, or `MPatF` must stay exhaustive — adding a constructor forces an explicit branch (a real implementation or a clear `error` for genuinely unreachable states) at every match site, or the build fails.

---

## File Structure

Files touched, by responsibility:

- `grammar/Wok.cf` — surface grammar. Add the `APAs. AtomPat ::= AtomPat "as" VarId` production (`"as"` auto-reserved). `VarSym`/`@` untouched. Regeneration target.
- `src-generated/GeneratedParser/Wok/{Abs,Par.y,Lex.x,Layout.hs,...}` — BNFC output (regenerated, then 3 manual patches reapplied).
- `src/Wok/TypeChecking/Typed.hs` — add the `TPAs` typed-pattern node.
- `src/Wok/TypeChecking/Infer.hs` — translate `Abs.APAs` → `TPAs`, add the as-name binding.
- `src/Wok/IR/Elaborate.hs` — `elabPatF` (old path), `toMPat`, `clauseVars`, `irrefutableHead`.
- `src/Wok/IR/Match.hs` — add `MAs` to `MPatF`; peel in `compileMatch` and `matchCoverage`; unreachable cases in the matrix ops.
- `examples/` — a small as-pattern example (e.g. `dedupHead`), with run-golden.
- `test/Spec.hs` and golden dirs — new tests + any re-accepted goldens.

---

## Task 1: Add the `as` keyword + `APAs` grammar production (RISK GATE)

**Goal:** `pat as name` parses as `Abs.APAs`, the shift/reduce conflict count is unchanged, and the full suite stays green — with as-patterns reported as "not yet implemented" downstream. `@`/`VarSym` are untouched.

**Files:**
- Modify: `grammar/Wok.cf` (AtomPat productions ~line 182-191)
- Regenerate + patch: `src-generated/GeneratedParser/Wok/{Par.y,Layout.hs}` (3 manual patches per `grammar/Wok.cf:13-69`)
- Modify: `src/Wok/TypeChecking/Infer.hs` (`inferAtomPat`, add a stub `Abs.APAs` case)

**Acceptance Criteria:**
- [ ] `APAs. AtomPat ::= AtomPat "as" VarId ;` added; `VarSym`/`@` unchanged.
- [ ] Parser regenerated and all THREE manual patches reapplied (`grammar/Wok.cf:13-69`).
- [ ] BNFC shift/reduce conflict count is UNCHANGED vs. before this task. (If it rises, STOP and report.)
- [ ] The `@@` cross-fixity fixture is untouched and its test still passes (no migration needed).
- [ ] `cabal build` succeeds (no `-Werror` failure: `inferAtomPat` handles `Abs.APAs`).
- [ ] `cabal test` is green (587).
- [ ] A `.wok` file containing `(Some x) as whole` reaches inference and reports a clear "as-patterns not yet implemented" error (proving the grammar is wired end-to-end), not a parse error.

**Verify:** `cabal test` → all green; `cabal run -v0 wok -- /tmp/as_stub.wok --run` → "as-patterns not yet implemented".

**Steps:**

- [ ] **Step 1: Record the current conflict count (baseline for the gate)**

Run a clean regeneration of the *current* grammar and capture Happy's conflict report, so you can compare after the change:

```bash
bnfc --haskell -d -p GeneratedParser --text-token -o /tmp/bnfc-baseline grammar/Wok.cf
happy --info=/tmp/happy-baseline.info /tmp/bnfc-baseline/GeneratedParser/Wok/Par.y -o /dev/null 2>&1 | grep -i conflict || echo "no conflicts reported"
```

Note the number (e.g. "N shift/reduce conflicts"). This is the baseline. (Do NOT overwrite the real `src-generated` here — this is a throwaway dir.)

- [ ] **Step 2: Edit the grammar — add the `as` production**

In `grammar/Wok.cf`, add the as-pattern production alongside the other `AtomPat` rules (after `APParen`/`PUnit`, around line 191). Do NOT touch the `VarSym` token (`@` stays an operator char):

```
APAs.     AtomPat ::= AtomPat "as" VarId ;   -- <atom pattern> as name; left-recursive, BNFC-friendly
```

BNFC auto-reserves `"as"` as a token. This is safe: `as` is not a keyword today, imports are `import ModPath` (no aliasing), and no `.wok` file uses `as` as an identifier.

- [ ] **Step 3: Regenerate the parser into the real tree**

```bash
bnfc --haskell -d -p GeneratedParser --text-token -o src-generated grammar/Wok.cf
```

- [ ] **Step 4: Reapply the THREE manual patches**

Per `grammar/Wok.cf:13-69`, reapply to the freshly generated files:
1. `src-generated/GeneratedParser/Wok/Layout.hs` — split the combined `isLayoutOpen || isParenOpen` branch and add `maybeInsertSeparator` only on the paren branch (lambda binder must be `pt`, not `_`). See `grammar/Wok.cf:13-28`.
2. `src-generated/GeneratedParser/Wok/Par.y` — replace the right-recursive `ListRecordFieldPat` with the left-recursive `NEListRecordFieldPat` and update `PRecordOpen` to `reverse` it. See `grammar/Wok.cf:30-56`.
3. `src-generated/GeneratedParser/Wok/Par.y` — hand-add the empty-record pattern `AtomPat : ConId '{' '}' { ... PRecord $1 [] }` as the first `ConId '{' ... '}'` alternative. See `grammar/Wok.cf:58-69`.

Use `git diff` against the prior `src-generated` to confirm the only *semantic* change beyond the three patches is the new `"as"` token and the `APAs` rule.

- [ ] **Step 5: Confirm the conflict count is UNCHANGED (the gate)**

```bash
happy --info=/tmp/happy-new.info src-generated/GeneratedParser/Wok/Par.y -o /dev/null 2>&1 | grep -i conflict || echo "no conflicts reported"
```

Compare to the Step 1 baseline. It MUST match. If the count rose, STOP and report — do not proceed or "fix" by hand-deleting conflicts.

- [ ] **Step 6: Add the stub `inferAtomPat` case (keeps `-Werror` happy)**

In `src/Wok/TypeChecking/Infer.hs`, add a case to `inferAtomPat` (after `APParen`, around line 1055). BNFC generates `APAs AtomPat VarId`:

```haskell
inferAtomPat (Abs.APAs _ (Abs.VarId (pos, _))) =
  throwError (UnsupportedFeature (Just pos)
    (Tx.pack "as-patterns not yet implemented"))
```

(This is replaced with the real implementation in Task 2; it exists only so the build is exhaustive and the grammar is provably wired through.)

- [ ] **Step 7: Build and run the full suite**

```bash
cabal build 2>&1 | tail -20
cabal test 2>&1 | tail -30
```

Expected: build clean, 587 tests green (the `@@` cross-fixity fixture is untouched and still passes).

- [ ] **Step 8: Prove the grammar is wired (stub error, not parse error)**

```bash
cat > /tmp/as_stub.wok <<'EOF'
module Main
import Std.Base

f : Option U64 -> Option U64
f (Some x) as whole = whole
f None = None

main : Option U64
main = f (Some 1)
EOF
cabal run -v0 wok -- /tmp/as_stub.wok --run 2>&1 | head -5
```

Expected: the "as-patterns not yet implemented" error (a downstream/inference error), NOT a parse error. This confirms `pat as name` parses and reaches inference. Remove `/tmp/as_stub.wok` after.

- [ ] **Step 9: Commit**

```bash
git add grammar/Wok.cf src-generated/ src/Wok/TypeChecking/Infer.hs
git commit -m "feat(grammar): add 'as' keyword and APAs as-pattern production

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 2: Front-end + single-`Alt` path (case arms, single-clause functions, lambdas)

**Goal:** As-patterns type-check and run everywhere that flows through `elabPatF` — case arms, single-clause functions, lambda binders, let binders, nested and `var as var` — via the native `TPAs` node. Multi-clause functions still report a clear "next task" error.

**Files:**
- Modify: `src/Wok/TypeChecking/Typed.hs` (`TpatF`, ~line 58-69)
- Modify: `src/Wok/TypeChecking/Infer.hs` (`inferAtomPat`, replace the Task 1 stub, ~line 1055)
- Modify: `src/Wok/IR/Elaborate.hs` (`elabPatF` ~line 636; `irrefutableHead` ~line 863; temporary errors in `toMPat` ~line 796 and `clauseVars` ~line 816)
- Test: `test/Spec.hs` (or a new `run-examples`/`typecheck-examples` file with golden)

**Acceptance Criteria:**
- [ ] `TPAs Text (Tpat a)` added to `TpatF`, deriving intact.
- [ ] `inferAtomPat` translates `Abs.APAs` to `TPAs`, adding `(name, ty)` to the binds.
- [ ] `elabPatF` handles `TPAs`: binds the as-name to the scrutinee via a `Let`, then matches the inner pattern.
- [ ] `irrefutableHead` treats `TPAs _ inner` as irrefutable iff `inner` is.
- [ ] A case arm `case e of (Some x) as whole -> ...`, a lambda `\(p, q) as both -> ...`, a single-clause IRREFUTABLE-head function (`twice n as m = n + m`), an as-over-compound-inner (`(h :: t) as whole`), and `x as y` all `--run` correctly. (NOTE: a single-clause *refutable* head like `f (Some x) as whole` routes through the Match path → Task 3, not here. Nested as-patterns *under a constructor* (`Some (n as m)`) depend on the `buildSubPats` fix in Task 2b.)
- [ ] A *multi-clause* as-pattern function reports a clear "as-patterns in multi-clause heads: implemented in Task 3" error (temporary).
- [ ] `cabal test` green.

**Verify:** `cabal run -v0 wok -- /tmp/as_single.wok --run` → expected values; `cabal test` → green.

**Steps:**

- [ ] **Step 1: Write the failing test (single-clause + case arm)**

Create `test/run-examples/as-pattern-single.wok` (the run-golden harness compares `--run` stdout against `as-pattern-single.golden`):

```
module Main
import Std.Base

-- single-clause function with a refutable as-pattern arg
unwrapOr : U64 -> Option U64 -> U64
unwrapOr d o = case o of
  (Some x) as whole -> x
  None -> d

-- case arm as-pattern that reuses the whole value
firstOrEmpty : [U64] -> [U64]
firstOrEmpty xs = case xs of
  (h :: t) as whole -> whole
  [] -> []

-- var as var (both bind the whole value)
twice : U64 -> U64
twice n as m = n + m

main : U64
main = unwrapOr 0 (Some 7) + twice 3 + (case firstOrEmpty [9] of (h :: _) as _w -> h ; [] -> 0)
```

Expected result: `7 + 6 + 9 = 22`. Create `test/run-examples/as-pattern-single.golden` with the program's expected `--run` output (match the exact format other run-goldens use — generate it after implementation in Step 7, then read-and-accept).

- [ ] **Step 2: Run to verify it fails**

```bash
cabal run -v0 wok -- test/run-examples/as-pattern-single.wok --run 2>&1 | head
```

Expected: "as-patterns not yet implemented" (the Task 1 stub).

- [ ] **Step 3: Add the `TPAs` node to `TpatF`**

In `src/Wok/TypeChecking/Typed.hs`, add to `TpatF` (after `TPCons`, line ~68):

```haskell
  | TPCons (Tpat a) (Tpat a) -- h :: t
  | TPAs Text (Tpat a)       -- `inner as name`: bind `name` to the whole matched value
```

The `deriving (Show, Functor, Foldable, Traversable)` covers it (the `Text` is not the type param).

- [ ] **Step 4: Replace the Infer stub with the real translation**

In `src/Wok/TypeChecking/Infer.hs`, replace the Task 1 stub `inferAtomPat (Abs.APAs ...)` with:

```haskell
inferAtomPat (Abs.APAs inner (Abs.VarId (_, name))) = do
  (ty, innerBinds, innerNode) <- inferAtomPat inner
  -- the as-name has the inner pattern's type; no new unification
  pure (ty, (name, ty) : innerBinds, Ty.Tpat ty (Ty.TPAs name innerNode))
```

(The grammar's left of `as` is `AtomPat`, so `inferAtomPat inner` is correct, not `inferPat`.)

- [ ] **Step 5: Handle `TPAs` in the old elaboration path (`elabPatF`)**

In `src/Wok/IR/Elaborate.hs`, add a case to `elabPatF` (after the `TPCons` case, before `TPCon`, ~line 666):

```haskell
elabPatF tk ty scrut (TPAs name inner) body = do
  -- bind `name` to the whole scrutinee, then match the inner pattern against
  -- the SAME scrutinee; the as-binding is irrefutable, refutability is the
  -- inner pattern's. The Let lands inside the inner pattern's success body.
  n <- bindFresh name
  let body' = withLocal name n $ do
        b <- body
        pure (Let (Binder n Unrestricted ty) (RAtom scrut) b)
  elabPat tk scrut inner body'
```

- [ ] **Step 6: Make `irrefutableHead` see through `TPAs`**

In `src/Wok/IR/Elaborate.hs`, `irrefutableHead` (~line 863), add a branch before the `_ -> False` fallback:

```haskell
irrefutableHead env (Tpat _ pnode) = case pnode of
  TPVar _   -> True
  TPWild    -> True
  TPUnit    -> True
  TPCon c _ -> case lookupRecordCon c env of Just _ -> True; Nothing -> False
  TPAs _ inner -> irrefutableHead env inner
  _         -> False
```

This keeps `f x as y = ...` (irrefutable) on the cheap single-clause `elabParams` path, which routes through `elabParam`'s general case → `elabPat` → the new `elabPatF` branch. (No change to `elabParam` is needed — its catch-all at line ~213 already handles any non-trivial pattern.)

- [ ] **Step 7: Add temporary `TPAs` errors to the Match-path consumers (keep `-Werror` exhaustive)**

`toMPat` and `clauseVars` in `Elaborate.hs` pattern-match `TpatF` and would now be non-exhaustive. Add clear temporary errors (replaced in Task 3).

In `toMPat`'s `go` (~line 811, after `TPCon`):

```haskell
    go (TPAs _ _) = error "match: as-pattern in multi-clause head implemented in Task 3"
```

In `clauseVars`'s `patVars` (~line 824, before the final catch-all):

```haskell
    patVars (Tpat _  (TPAs _ inner)) =
      error ("clauseVars: as-pattern in multi-clause head implemented in Task 3"
             `seq` patVars inner)   -- placeholder; Task 3 returns (name, ty) : patVars inner
```

Simpler and clearer — make `clauseVars` total now but route through a guard that is only hit by multi-clause heads. Since `clauseVars` is ONLY called by `compileClauses` (the multi-clause path), any `TPAs` reaching it is the unimplemented case:

```haskell
    patVars (Tpat _  (TPAs _ _)) =
      error "clauseVars: as-pattern in multi-clause head implemented in Task 3"
```

Use this single-line form. (Task 3 replaces both error lines with real logic.)

- [ ] **Step 8: Build, generate the golden, run, verify**

```bash
cabal build 2>&1 | tail -20
cabal run -v0 wok -- test/run-examples/as-pattern-single.wok --run
```

Expected stdout corresponds to `22`. Write that exact output into `test/run-examples/as-pattern-single.golden` (or `cabal run wok-tests -- --accept` and READ the diff). Then:

```bash
cabal test 2>&1 | tail -30
```

Expected: green.

- [ ] **Step 9: Verify the temporary multi-clause guard**

```bash
cat > /tmp/as_multi.wok <<'EOF'
module Main
import Std.Base

f : Option U64 -> U64
f (Some x) as whole = x
f None = 0

main : U64
main = f (Some 5)
EOF
cabal run -v0 wok -- /tmp/as_multi.wok --run 2>&1 | head -3
```

Expected: the "implemented in Task 3" error. Remove `/tmp/as_multi.wok` after.

- [ ] **Step 10: Commit**

```bash
git add src/Wok/TypeChecking/Typed.hs src/Wok/TypeChecking/Infer.hs src/Wok/IR/Elaborate.hs test/run-examples/as-pattern-single.wok test/run-examples/as-pattern-single.golden
git commit -m "feat(patterns): as-patterns via TPAs on the single-Alt path

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 2b: Fix nested-constructor binder bug (`buildSubPats`) — full nested support

**Goal:** Fix a pre-existing bug (discovered during Task 2 review) where a binder inside a *nested constructor* sub-pattern is dropped on the single-`Alt` path, so it produces a runtime `UnboundVar` instead of binding. Fixing it delivers full nested support — plain nested matching (`Some (Some n) -> n`) AND nested as-patterns under a constructor (`Some (n as m)`).

**Root cause:** `buildSubPats` (`src/Wok/IR/Elaborate.hs` ~line 721-728), in its non-trivial sub-pattern catch-all, forces the success body via `altBody <- wraps inner` and then passes `(pure altBody)` to `elabPat`. The body is thus elaborated BEFORE `elabPat` establishes the nested pattern `p`'s binders, so any variable bound by `p` (e.g. `n` in `Some (Some n)`) is out of scope → `UnboundVar`. The sibling helpers `buildSubPatFromPat` and `buildRecordFieldBindings` already pass the continuation unforced and are correct — only `buildSubPats` has the bug.

**Files:**
- Modify: `src/Wok/IR/Elaborate.hs` (`buildSubPats` catch-all)
- Modify: `src/Wok/TypeChecking/Infer.hs` (clean the now-stale comment above the `inferAtomPat (Abs.APAs ...)` case ~line 1056-1058)
- Test: `test/run-examples/as-pattern-nested.wok` + golden

**Acceptance Criteria:**
- [ ] `buildSubPats` catch-all passes the continuation unforced to `elabPat`.
- [ ] Plain nested constructor matching works: `case oo of Some (Some n) -> n; Some None -> 0; None -> 99`.
- [ ] Nested as-pattern under a constructor works: `case o of Some (n as m) -> n + m; None -> 0`.
- [ ] The stale `inferAtomPat` APAs comment is corrected to describe the real behaviour.
- [ ] `cabal test` green (no regressions); the new nested run-example passes.

**Verify:** `cabal run -v0 wok -- test/run-examples/as-pattern-nested.wok --run` → expected; `cabal test` → green.

**Steps:**

- [ ] **Step 1: Write the failing test**

Create `test/run-examples/as-pattern-nested.wok` (follow the run-golden convention used by `as-pattern-single`):

```
module Main
import Std.Base

-- plain nested constructor matching (the pre-existing bug)
flatten : Option (Option U64) -> U64
flatten oo = case oo of
  Some (Some n) -> n
  Some None -> 0
  None -> 99

-- nested as-pattern under a constructor: n and m both bind the field
nestedAs : Option U64 -> U64
nestedAs o = case o of
  Some (n as m) -> n + m
  None -> 0

main : U64
main = flatten (Some (Some 7)) + nestedAs (Some 5)
```

Expected result: `7 + 10 = 17`. Run it; expect a runtime `UnboundVar` failure (the bug).

- [ ] **Step 2: Apply the fix**

In `src/Wok/IR/Elaborate.hs`, `buildSubPats`'s non-trivial catch-all, change the body to pass the continuation unforced:

```haskell
    Tpat fty _ ->
      do n <- bindFresh (Tx.pack "t")
         let b = Binder n Unrestricted fty
             wrapNested inner = do
               alt <- elabPat tk (AVar n) p (wraps inner)
               pure (Case (AVar n) [alt])
         pure (b : bs, wrapNested)
```

(Was: `do { altBody <- wraps inner; alt <- elabPat tk (AVar n) p (pure altBody); pure (Case (AVar n) [alt]) }`. `wraps inner :: Elab Expr` is forced INSIDE `elabPat`'s continuation, where both `p`'s binders and the sibling binders are in scope.)

- [ ] **Step 3: Clean the stale comment**

In `src/Wok/TypeChecking/Infer.hs`, replace the now-inaccurate comment above the `inferAtomPat (Abs.APAs ...)` case (it still says as-patterns aren't wired in / ships a stub) with a one-line description of the real translation.

- [ ] **Step 4: Build, generate golden, verify**

```bash
cabal build 2>&1 | tail -10
cabal run -v0 wok -- test/run-examples/as-pattern-nested.wok --run
```

Confirm `17`. Write/accept the golden after reading the diff. Then `cabal test 2>&1 | tail -20` — expect green, no regressions.

- [ ] **Step 5: Commit**

```bash
git add src/Wok/IR/Elaborate.hs src/Wok/TypeChecking/Infer.hs test/run-examples/as-pattern-nested.wok test/run-golden/as-pattern-nested.expected
git commit -m "fix(elaborate): bind nested-constructor sub-pattern binders (buildSubPats)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 3: Decision-tree path (multi-clause functions) — `MAs` + peel

**Goal:** As-patterns work in multi-clause function heads (the headline `dedupHead`), via a new `MAs` node peeled at the top of `compileMatch`/`matchCoverage`. The temporary Task 2 errors are removed.

**Files:**
- Modify: `src/Wok/IR/Match.hs` (`MPatF` ~line 32; `compileMatch` ~line 74; matrix ops `specCon`/`specLit`/`buildHeadAlt` ~line 136-178; `matchCoverage`'s `analyze`/`specConP`/`specLitP` ~line 215-273)
- Modify: `src/Wok/IR/Elaborate.hs` (`toMPat` ~line 811; `clauseVars` ~line 824 — replace Task 2 errors)
- Test: `test/run-examples/` (headline `dedupHead`) + `test/anf-golden/` (reuse, not rebuild)

**Acceptance Criteria:**
- [ ] `MAs Text MPat` added to `MPatF`.
- [ ] `compileMatch` peels as-bindings from every column (binding the as-name to the column's scrutinee atom) before dispatch; `matchCoverage` strips them (no atoms).
- [ ] `toMPat` emits `MAs`; `clauseVars` includes the as-name `(name, ty)`.
- [ ] The matrix ops (`specCon`, `specLit`, `buildHeadAlt`, `specConP`, `specLitP`) have explicit `MAs` branches that `error` as genuinely-unreachable (post-peel).
- [ ] The headline `dedupHead` multi-clause function `--run`s correctly AND `--dump-anf` shows the as-name reused, not a rebuilt cons.
- [ ] Exhaustiveness/redundancy warnings are unaffected by as-patterns (a multi-clause match with as-patterns reports the same coverage as without).
- [ ] `cabal test` green (re-accept goldens after reading diffs).

**Verify:** `cabal run -v0 wok -- test/run-examples/as-pattern-dedup.wok --run` → expected list; `--dump-anf` shows reuse; `cabal test` → green.

**Steps:**

- [ ] **Step 1: Write the failing headline test**

Create `test/run-examples/as-pattern-dedup.wok`:

```
module Main
import Std.Base

-- multi-clause: collapse adjacent duplicates, reusing the whole tail unchanged
dedupHead : [U64] -> [U64]
dedupHead (x :: y :: rest) as whole = case x == y of
  True  -> dedupHead (y :: rest)
  False -> whole
dedupHead other = other

main : [U64]
main = dedupHead (1 :: 1 :: 2 :: 3 :: [])
```

Expected: `dedupHead` drops the leading dup, giving `[1, 2, 3]` (the `whole` reuse path returns the list once no leading dup remains). Create `test/run-examples/as-pattern-dedup.golden` after implementation (Step 8).

- [ ] **Step 2: Run to verify it fails**

```bash
cabal run -v0 wok -- test/run-examples/as-pattern-dedup.wok --run 2>&1 | head -3
```

Expected: the Task 2 "implemented in Task 3" error.

- [ ] **Step 3: Add `MAs` to `MPatF`**

In `src/Wok/IR/Match.hs` (~line 32):

```haskell
data MPatF
  = MVar (Maybe Text)   -- variable (Just v) or wildcard (Nothing)
  | MCon Text [MPat]    -- data constructor / TupleN / Nil / Cons
  | MLit Lit            -- literal
  | MAs Text MPat       -- `inner as name`: bind `name` to this column's scrutinee atom
  deriving (Show)
```

- [ ] **Step 4: Peel as-bindings at the top of `compileMatch`**

In `src/Wok/IR/Match.hs`, add the peel helper and rewrite `compileMatch`'s non-empty equation (~line 74-80):

```haskell
-- | Strip top-level as-bindings from each column of a row, recording each
-- as-name bound to that column's scrutinee atom. Idempotent; nested as-bindings
-- (inner as a as b) all bind to the same atom. Sub-patterns exposed later (constructor
-- fields) are peeled when they surface as columns in a recursive compileMatch.
peelAsRow :: [Atom] -> Row -> Row
peelAsRow scruts r =
  let peeled = zipWith peelCol scruts (rowPats r)
  in r { rowPats  = map fst peeled
       , rowSubst = rowSubst r ++ concatMap snd peeled }
  where
    peelCol a (MPat _ (MAs v p)) = let (p', bs) = peelCol a p in (p', (v, a) : bs)
    peelCol _ p                  = (p, [])

compileMatch :: ConOracle -> [Atom] -> [Row] -> Fresh Expr
compileMatch _ _ [] = pure failLeaf
compileMatch oracle scruts rows0 =
  case map (peelAsRow scruts) rows0 of
    []            -> pure failLeaf
    rows@(r0 : _)
      | all isWildP (rowPats r0) -> pure (jumpLeaf (bindRow scruts r0))
      | otherwise -> do
          let i = chooseColumn scruts rows
          switchOn oracle i scruts rows
```

(`bindRow` already collects the inner `MVar` bindings; the as-names are in `rowSubst` from the peel, so `jumpLeaf` finds every clause var.)

- [ ] **Step 5: Add unreachable `MAs` branches to the matrix ops**

Post-peel, no matrix op sees `MAs` in the column it inspects, but `-Wincomplete-patterns` requires explicit branches. Add to each:

`specCon` (~line 160), before the `where`:

```haskell
    MPat _ (MAs _ _) -> error "Match.specCon: MAs should have been peeled by compileMatch"
```

`specLit` (~line 171):

```haskell
    MPat _ (MAs _ _) -> error "Match.specLit: MAs should have been peeled by compileMatch"
```

`buildHeadAlt` (~line 151, alongside the `MVar` error clause):

```haskell
buildHeadAlt _ _ _ _ _ (MAs _ _) = error "Match.buildHeadAlt: MAs is not a head (peeled by compileMatch)"
```

In `matchCoverage`'s `specConP` (~line 259) and `specLitP` (~line 269):

```haskell
      MPat _ (MAs _ _) -> error "Match.specConP: MAs should have been stripped by analyze"
```
```haskell
      MPat _ (MAs _ _) -> error "Match.specLitP: MAs should have been stripped by analyze"
```

- [ ] **Step 6: Strip as-bindings in `matchCoverage`'s `analyze`**

`matchCoverage` carries no atoms, so it only strips (no binding). In `src/Wok/IR/Match.hs`, add a stripper and apply it at the top of `analyze` (~line 222):

```haskell
    stripAs :: MPat -> MPat
    stripAs (MPat _ (MAs _ p)) = stripAs p
    stripAs p                  = p

    stripAsRow :: Row -> Row
    stripAsRow r = r { rowPats = map stripAs (rowPats r) }

    analyze :: Int -> [Row] -> (Set Int, Bool)
    analyze _ []          = (Set.empty, True)
    analyze n rws0        =
      case map stripAsRow rws0 of
        []          -> (Set.empty, True)
        rws@(r0 : _)
          | all isWildP (rowPats r0) -> (Set.singleton (rowIndex r0), False)
          | otherwise -> {- existing body, using `rws` instead of `rws0` -} ...
```

Keep the existing `pickCol`/`heads`/branch/default logic verbatim, just bound over the stripped `rws`. (As-patterns don't change coverage: `pat as name` covers exactly what `pat` covers.)

- [ ] **Step 7: Replace the Task 2 temporary errors in Elaborate**

In `src/Wok/IR/Elaborate.hs`, `toMPat`'s `go` (~line 811):

```haskell
    go (TPAs name inner) = MAs name (toMPat env inner)
```

And `clauseVars`'s `patVars` (~line 824), before the catch-all:

```haskell
    patVars (Tpat ty (TPAs name inner)) = (name, ty) : patVars inner
```

(The as-name becomes a join-point parameter and an entry in `rowOrder`; the peel in Step 4 supplies its atom in `rowSubst`, so the `jumpLeaf` lookup resolves.)

- [ ] **Step 8: Build, generate goldens, verify run + ANF reuse**

```bash
cabal build 2>&1 | tail -20
cabal run -v0 wok -- test/run-examples/as-pattern-dedup.wok --run
```

Expected stdout corresponds to `[1, 2, 3]`. Write it into `test/run-examples/as-pattern-dedup.golden`. Then confirm reuse (the `False` arm returns `whole`, not a rebuilt `x :: y :: rest`):

```bash
cabal run -v0 wok -- test/run-examples/as-pattern-dedup.wok --dump-anf 2>&1 | grep -A3 -i 'whole\|dedup' | head -20
```

Expected: the `whole` binding is the scrutinee atom (an `RAtom`/param reuse), and the `False` branch jumps with that atom — no `Cons`/`Some` reconstruction. If an `anf-golden` entry is appropriate, add `test/anf-golden/as-pattern-dedup.golden` and accept it after reading.

- [ ] **Step 9: Add a coverage/redundancy regression test**

Confirm exhaustiveness analysis is unchanged by as-patterns. Add to `test/Spec.hs` a case (or a `typecheck-examples` file) asserting that a multi-clause match whose heads carry as-patterns yields the SAME non-exhaustive / redundant diagnostics as the equivalent match without as-patterns. Example fixture (non-exhaustive — missing `None`):

```
module Main
import Std.Base

f : Option U64 -> U64
f (Some x) as w = x

main : U64
main = f None
```

Expected: the same non-exhaustive-match warning as `f (Some x) = x` would produce.

- [ ] **Step 10: Full suite + accept goldens**

```bash
cabal test 2>&1 | tail -40
```

Read any golden diffs, then `cabal run wok-tests -- --accept` if appropriate, and re-run `cabal test`.

- [ ] **Step 11: Commit**

```bash
git add src/Wok/IR/Match.hs src/Wok/IR/Elaborate.hs test/run-examples/as-pattern-dedup.wok test/run-examples/as-pattern-dedup.golden test/Spec.hs test/anf-golden/ test/typecheck-examples/ 2>/dev/null
git commit -m "feat(match): as-patterns in multi-clause heads via MAs + peel

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 4: Example, docs, and final verification

**Goal:** Ship a clear as-pattern example, note the feature in the roadmap/spec, and verify the whole suite and the headline behaviours once more.

**Files:**
- Create: `examples/as-patterns.wok` (+ its run-golden if examples are golden-tested)
- Modify: `docs/superpowers/specs/2026-06-07-as-patterns-design.md` (status → implemented)
- Modify: roadmap doc if one tracks effect/ergonomics slices (search for the slice list)

**Acceptance Criteria:**
- [ ] `examples/as-patterns.wok` demonstrates as-patterns in a case arm, a single-clause function, and a multi-clause function; `--run`s correctly.
- [ ] The design spec's Status line notes it is implemented on `feat/as-patterns`.
- [ ] `cabal test` green; the stub/temporary errors from Tasks 1-2 are gone (grep finds none).
- [ ] `git grep` confirms no "not yet implemented / Task 3" as-pattern placeholders remain. (The `@@` cross-fixity fixture stays — `@` was never reserved.)

**Verify:** `cabal test` → green; `cabal run -v0 wok -- examples/as-patterns.wok --run` → expected output.

**Steps:**

- [ ] **Step 1: Write the example**

Create `examples/as-patterns.wok`:

```
-- As-patterns (`pat as name`, name LAST): match a structure AND name the whole value.
module Main
import Std.Base

-- case arm: reuse the matched list without rebuilding it
keepNonEmpty : [U64] -> [U64]
keepNonEmpty xs = case xs of
  (h :: t) as whole -> whole
  [] -> []

-- single-clause function arg
unSome : Option U64 -> Option U64
unSome (Some x) as whole = whole
unSome None = None

-- multi-clause (decision-tree path)
dedupHead : [U64] -> [U64]
dedupHead (x :: y :: rest) as whole = case x == y of
  True  -> dedupHead (y :: rest)
  False -> whole
dedupHead other = other

main : [U64]
main = dedupHead (5 :: 5 :: 5 :: 6 :: []) ++ keepNonEmpty [7]
```

- [ ] **Step 2: Run and record the golden (if examples are golden-tested)**

```bash
cabal run -v0 wok -- examples/as-patterns.wok --run
```

If `examples/` are golden-tested (check how other `examples/*.wok` are wired in `test/Spec.hs`), add the matching golden and accept after reading the diff.

- [ ] **Step 3: Update the design spec status**

In `docs/superpowers/specs/2026-06-07-as-patterns-design.md`, change the Status line to note: implemented on `feat/as-patterns` (Tasks 1-4), full suite green.

- [ ] **Step 4: Update the roadmap, if present**

```bash
git grep -nI 'as-pattern\|tagged effect\|slice' docs/ | grep -i roadmap
```

If a roadmap tracks this slice, mark as-patterns done (surface: `as` keyword) and note `@` is still free, earmarked for future visible type application.

- [ ] **Step 5: Confirm no placeholders remain**

```bash
git grep -nI 'not yet implemented\|implemented in Task 3' src/ test/ examples/ || echo "clean"
```

Expected: no as-pattern placeholders. (The `@@` cross-fixity fixture is intentionally kept.)

- [ ] **Step 6: Final full suite**

```bash
cabal build 2>&1 | tail -5
cabal test 2>&1 | tail -20
```

Expected: green.

- [ ] **Step 7: Commit**

```bash
git add examples/as-patterns.wok docs/superpowers/specs/2026-06-07-as-patterns-design.md
git commit -m "docs,examples: as-patterns example and spec status

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Self-Review (against the spec)

- **Spec coverage:** Surface `pat as name` (Task 1 grammar; `as` keyword, `@`/`VarSym` untouched). `TPAs` native node, no surface desugar (Tasks 2-3). Full support — case arms / single-clause / lambda / let (Task 2), multi-clause via Match (Task 3), nested + `var as var` (Tasks 2-3 tests). Destructuring-let components left rejected (no task touches `checkComponentPat` — correct, by design). Grammar conflict-count gate (Task 1). ✓ all spec sections map to a task.
- **Placeholder scan:** Temporary errors in Task 2 are explicitly removed in Task 3 Step 7 and verified absent in Task 4 Step 5. No "TBD"/"add error handling"/uncoded steps remain.
- **Type consistency:** `TPAs Text (Tpat a)` (Typed) ↔ `Ty.TPAs name innerNode` (Infer) ↔ `TPAs name inner` (Elaborate `elabPatF`/`toMPat`/`clauseVars`) ↔ `MAs Text MPat` (Match) — names and arities consistent across tasks. `peelAsRow`/`stripAs` defined once in Match. BNFC constructor `Abs.APAs AtomPat VarId` matched consistently in Infer.
