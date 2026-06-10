# Slice 4d — Coroutine Types as `extern` Declarations Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers-extended-cc:subagent-driven-development (recommended) or superpowers-extended-cc:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the invisible compiler-built-in coroutine types `Step`/`Suspension` with visible, prelude-declared `extern data`/`extern type` declarations in `Std.Control`, so the second-class-carrier + affine discipline rides a per-tycon marker flag instead of dedicated `TyCon` enum constructors.

**Architecture:** Two new grammar productions (`extern data`, `extern type`, both `Embedded`-only) elaborate to ordinary `TcUser` tycons carrying a new `TyConInfo.tcCarrier :: Bool` flag. The carrier-escape and affine-consumption analyses (`Carrier.hs`) stop pattern-matching `TcStep`/`TcSuspension` and instead consult the set of marked carrier-tycon names threaded in from the env. The `TcStep`/`TcSuspension` built-ins are removed. The runtime representation is byte-for-byte unchanged — `Step`'s constructors keep the VCon tags the `__coro_*` prims already build.

**Tech Stack:** Haskell, BNFC 2.9.6.3 (grammar -> Alex/Happy parser), Cabal, `tasty-golden`.

---

## Background the engineer needs

Read these before starting — they are the converged design and the exact code being changed:

- `docs/superpowers/specs/2026-06-10-coroutine-types-extern-decl-design.md` — THE spec. Do not re-litigate; details there.
- `docs/superpowers/specs/2026-06-10-slice-4c-step-adt-suspend-naming-design.md` §12 — what 4c shipped (the built-ins this replaces).
- `prelude/Std/Control.wok` — the surface; currently has a `Step`/`Suspension` reference *comment* (lines 23-50) to replace with two real declarations.

Key facts established by codebase exploration (trust these):

- **`extern` is already a keyword**; `data` and `type` are already keywords (`type` sits in `ReservedKw`, grammar line 126). So `extern data` / `extern type` introduce no new reserved words and cannot clash with user identifiers. After `extern`, one-token lookahead (`data` vs `type` vs `SigName`-start) disambiguates the three extern productions — no new LALR conflict expected.
- **`Std.Control` is loaded with `Embedded` origin** (`src/Wok/Loader.hs:77`), so its `extern` decls pass the Part-1 gate; a `UserFile` using `extern` is rejected with `ExternNotAllowed`.
- **Hand-written code is `-Wall -Werror` with exhaustiveness checks** (`wok.cabal:30-32`). Consequences: a non-exhaustive `case`/function on `Decl` fails the build; an unused import or unused `where`-binding fails the build. Both bite this slice (Reordering's `reorderDecl` is exhaustive; `Builtins.hs` will lose bindings).
- **The generated parser sublibrary is plain `-Wall` (not `-Werror`)** — BNFC output's warnings are tolerated.
- **Runtime is untouched.** `__coro_*` prims in `src/Wok/Interp/Prim.hs` are NOT modified. `Step`'s constructor tags `Completed`/`Suspended` coincide with the VCon tags the prims build; after this slice `Step` resolves to a prelude-declared `TcUser "Step"` instead of `TcStep`, but the value representation is identical.
- **Two type pretty-printers exist.** `Infer.hs:prettyCType` (used by `prettyScheme` / typecheck-success golden) already renders `CTCon TcSuspension xs` as `"Suspension ..."` AND has a generic `CTCon (TcUser n) xs` clause that renders `TcUser "Suspension"` as `"Suspension ..."` — **same text**, so typecheck-success goldens do NOT change. `Anf.hs:prettyCTypeLocal` (used by typed-anf golden) renders `TcSuspension` via the `show tc` fallback as the literal `"TcSuspension"`, but renders `TcUser "Suspension"` as `"Suspension"` — so only the **typed-anf** goldens change (3 files), `TcSuspension` -> `Suspension`, `TcStep` -> `Step`.

### Verified coro regression baselines (must stay identical)

Run-examples (`cabal run -v0 wok -- test/run-examples/<f>.wok --run`):

| file | expected |
|------|----------|
| `coro-escape` | `421` |
| `coro-step-range` | `10` |
| `coro-step-zip` | `52` |
| `coro-multi-driver` | `64` |

Typecheck-fail negatives (`test/typecheck-fail-golden/<f>.expected`):

| file | expected error |
|------|----------------|
| `step-escapes` | `CarrierEscape Nothing "leak"` |
| `suspension-escapes` | `CarrierEscape ...` |
| `step-inline-escape-{list,return,tuple}` | `CarrierEscape ...` |
| `step-scrutinized-twice` | `FutureConsumedTwice Nothing "s"` |
| `future-await-twice` | `FutureConsumedTwice ...` |
| `future-{escapes-return,helper-double-consume,recursive-consume,resume-then-cancel}` | unchanged |

### Files touched across the slice

- `grammar/Wok.cf` — two new productions (Task 1).
- `src-generated/GeneratedParser/Wok/*` — BNFC regen output (Task 1).
- `src/Wok/Reordering.hs` — two new pass-through `reorderDecl` clauses (Task 1).
- `src/Wok/TypeChecking/Env.hs` — `tcCarrier` field on `TyConInfo` (Task 2).
- `src/Wok/TypeChecking/Builtins.hs` — add `False` to all `TyConInfo` ctors (Task 2), then remove `Step`/`Suspension` entries + dead helpers (Task 4).
- `src/Wok/TypeChecking/Infer.hs` — `processDataDecls` (Task 2), gate (Task 2), carrier-set wiring + `resultIsAffineCarrier` (Tasks 3-4), `resolveTyCon` + `prettyCType` removal (Task 4).
- `src/Wok/TypeChecking/Carrier.hs` — thread carrier-tycon set; predicates (Tasks 3-4).
- `src/Wok/TypeChecking/Types.hs` — remove `TcStep`/`TcSuspension` from `TyCon` (Task 4).
- `src/Wok/TypeChecking/Class.hs` — remove `tyConKey` cases (Task 4).
- `prelude/Std/Control.wok` — replace comment with real decls (Task 4).
- `test/typed-anf-golden/{future-arg-ok,future-type-mentions,step-case}.expected` — regen (Task 4).
- `test/examples/`, `test/typecheck-fail-examples/`, `test/typecheck-examples/` — new corpus files (Tasks 1, 2, 5).
- `test/Spec.hs` — one unit test for the marker flag (Task 3).

---

## Task 0: Branch and capture baseline

**Goal:** Create the feature branch and record the green baseline so regressions are detectable.

**Files:** none (git + measurement only).

**Acceptance Criteria:**
- [ ] On branch `feat/slice-4d-coro-extern-types` forked from `main`.
- [ ] `cabal build` succeeds; baseline test count recorded.
- [ ] Baseline Happy shift/reduce conflict count recorded.

**Verify:** `git branch --show-current` -> `feat/slice-4d-coro-extern-types`

**Steps:**

- [ ] **Step 1: Branch from main**

```bash
cd /Users/zy/wokml
git checkout main
git checkout -b feat/slice-4d-coro-extern-types
```

- [ ] **Step 2: Record the test baseline**

```bash
cabal build 2>&1 | tail -5
cabal test 2>&1 | tail -20
```
Record the passing count (expected ~687 green from 4c). Keep this number; every later task must not regress it (only ADD passing tests).

- [ ] **Step 3: Record the Happy conflict baseline**

```bash
cabal build 2>&1 | grep -iE "shift/reduce|reduce/reduce|conflict" || echo "no conflicts reported in this build"
```
If a clean build reports no conflict lines (incremental builds skip Happy), force the parser sublibrary to rebuild and capture the count:
```bash
touch grammar/Wok.cf
bnfc --haskell -d -p GeneratedParser --text-token -o src-generated grammar/Wok.cf 2>&1 | grep -iE "conflict" || echo "bnfc reported no conflicts"
```
Record the number reported (e.g. "N shift/reduce conflicts"). Task 1 must not increase it.

- [ ] **Step 4: Restore any regen side effects**

`bnfc` regen in Step 3 may rewrite `src-generated/`. Discard those changes so Task 1 starts clean:
```bash
git checkout -- src-generated/ 2>/dev/null || true
git status --short
```
Expected: clean tree (no modifications).

---

## Task 1: Grammar — `extern data` / `extern type` productions

**Goal:** Add the two productions, regenerate the parser, reapply the three documented manual patches, keep `reorderDecl` exhaustive, and prove the new forms parse and round-trip without increasing the conflict count.

**Files:**
- Modify: `grammar/Wok.cf` (after line 79, the `DData` production)
- Regenerate: `src-generated/GeneratedParser/Wok/{Abs,Par,Lex,Layout,Print,...}.hs`
- Modify: `src/Wok/Reordering.hs:219-225` (add two pass-through clauses)
- Create: `test/examples/40-extern-coro-types.wok`
- Create (via `--accept`): `test/golden/40-extern-coro-types.expected`

**Acceptance Criteria:**
- [ ] `grammar/Wok.cf` has `DExternData` and `DExternType` productions.
- [ ] BNFC regen produces `Abs.DExternData` and `Abs.DExternType` constructors.
- [ ] The three manual post-regen patches are reapplied (Layout.hs decl-separator; Par.y left-recursive `NEListRecordFieldPat`; Par.y empty-record-pattern rule).
- [ ] Happy shift/reduce conflict count is unchanged vs the Task 0 baseline.
- [ ] `reorderDecl` handles `DExternData` and `DExternType` (build is `-Werror` exhaustive).
- [ ] `cabal build` succeeds.
- [ ] The new round-trip example parses and prints stably.

**Verify:** `cabal test 2>&1 | grep -i "40-extern-coro-types"` -> PASS

**Steps:**

- [ ] **Step 1: Add the grammar productions**

In `grammar/Wok.cf`, immediately after the `DData` line (line 79), add:

```
DExternData. Decl ::= "extern" "data" ConId [VarId] "=" [ConDef] ; -- marked carrier ADT (Embedded-only; gate in Infer)
DExternType. Decl ::= "extern" "type" ConId [VarId] ;              -- marked opaque carrier (Embedded-only)
```

Then, in the top-of-file POST-REGEN NOTE block, add a fourth bullet documenting that `extern data`/`extern type` were added in slice 4d and require no new manual patch beyond the existing three (record this so future regens know the patch list is unchanged).

- [ ] **Step 2: Regenerate the parser**

```bash
cd /Users/zy/wokml
bnfc --haskell -d -p GeneratedParser --text-token -o src-generated grammar/Wok.cf 2>&1 | tee /tmp/bnfc-4d.log
grep -iE "conflict" /tmp/bnfc-4d.log || echo "bnfc reported no conflicts"
```
Confirm the conflict count matches the Task 0 baseline. If it INCREASED, stop — the productions are ambiguous; re-read the grammar notes and the design §5 fallback (single `extern data` with optional constructors) before proceeding.

- [ ] **Step 3: Reapply the three manual patches**

BNFC regen overwrites the hand-patched files. Reapply, per the instructions in `grammar/Wok.cf` lines 13-69:

1. `src-generated/GeneratedParser/Wok/Layout.hs` — split the `isLayoutOpen || isParenOpen` branch in `res`, adding `maybeInsertSeparator` on the paren branch only (binder must be `pt`, not `_`). See `grammar/Wok.cf:13-28`.
2. `src-generated/GeneratedParser/Wok/Par.y` — replace the auto-generated right-recursive `ListRecordFieldPat` with the left-recursive `NEListRecordFieldPat` and update `PRecordOpen` to use `reverse $3`. See `grammar/Wok.cf:42-56`.
3. `src-generated/GeneratedParser/Wok/Par.y` — hand-add the empty-record-pattern `AtomPat : ConId '{' '}' { ... PRecord $1 [] }` rule as the first `ConId '{' ... '}'` alternative. See `grammar/Wok.cf:64-69`.

Confirm with:
```bash
grep -n "NEListRecordFieldPat\|PRecord \$1 \[\]" src-generated/GeneratedParser/Wok/Par.y
grep -n "isParenOpen" src-generated/GeneratedParser/Wok/Layout.hs
```

- [ ] **Step 4: Make `reorderDecl` exhaustive (write the failing build first)**

Build now to SEE the non-exhaustiveness error (TDD for a compiler pass = the build is the test):
```bash
cabal build wok 2>&1 | grep -iE "non-exhaustive|incomplete|DExternData|DExternType" | head
```
Expected: a `-Wincomplete-patterns` error in `Reordering.hs` for the new constructors.

Then fix `src/Wok/Reordering.hs` — add, alongside the other pass-through clauses (after line 220, the `DData` clause):

```haskell
reorderDecl _ d@(DExternData{}) = Right d  -- marked carrier ADT; no exprs to reorder
reorderDecl _ d@(DExternType{}) = Right d  -- marked opaque carrier; no exprs to reorder
```

- [ ] **Step 5: Confirm the build is clean**

```bash
cabal build 2>&1 | tail -5
```
Expected: builds with no errors. (Nothing yet ELABORATES the new decls; `processDataDecls` ignores them because its filter only matches `DData` — that is Task 2. They parse and pass through reordering, which is all Task 1 needs.)

- [ ] **Step 6: Add a round-trip parse example**

Create `test/examples/40-extern-coro-types.wok` with the exact prelude forms (names are irrelevant here — this file is only parsed + pretty-printed by the "parse golden" group, never loaded or type-checked):

```wok
extern type Suspension a b r
extern data Step a b r = Completed r | Suspended a (Suspension a b r)
```

- [ ] **Step 7: Generate and inspect the golden**

```bash
cabal test --test-options=--accept 2>&1 | grep -i "40-extern-coro-types"
cat test/golden/40-extern-coro-types.expected
```
Confirm the golden contains both declarations printed back (exact spacing is whatever BNFC's printer emits; the point is a stable round-trip). Confirm no OTHER golden changed:
```bash
git status --short test/golden/
```
Expected: only `40-extern-coro-types.expected` is new/changed.

- [ ] **Step 8: Run the full suite (no regressions)**

```bash
cabal test 2>&1 | tail -20
```
Expected: baseline count + 1 (the new parse golden), all green.

- [ ] **Step 9: Commit**

```bash
git add grammar/Wok.cf src-generated/ src/Wok/Reordering.hs test/examples/40-extern-coro-types.wok test/golden/40-extern-coro-types.expected
git commit -m "feat(grammar): extern data/extern type productions (slice 4d)"
```

---

## Task 2: Elaborate `extern data`/`extern type` to carrier-marked tycons

**Goal:** Add `tcCarrier :: Bool` to `TyConInfo`; teach `processDataDecls` to register `DExternData` (with constructors, `tcCarrier=True`) and `DExternType` (opaque, `tcCarrier=True`); reject both in a `UserFile` via the existing `ExternNotAllowed` gate. The `TcStep`/`TcSuspension` built-ins still exist and the prelude still uses the comment — the new path is exercised only by tests in this task.

**Files:**
- Modify: `src/Wok/TypeChecking/Env.hs:44-49` (add `tcCarrier` field)
- Modify: `src/Wok/TypeChecking/Builtins.hs:44-53` (add `False` to every `TyConInfo` ctor)
- Modify: `src/Wok/TypeChecking/Infer.hs:825-862` (`processDataDecls`), `:3086-3089` (gate), add `externTypeDecls`
- Modify: `test/Spec.hs:873,909,925` (add `False` to `TyConInfo` ctors)
- Create: `test/typecheck-fail-examples/extern-data-user-forbidden.wok`
- Create: `test/typecheck-fail-examples/extern-type-user-forbidden.wok`
- Create (via `--accept`): the two matching `test/typecheck-fail-golden/*.expected`

**Acceptance Criteria:**
- [ ] `TyConInfo` has `tcCarrier :: Bool`; all constructors updated; build green.
- [ ] An `Embedded` module declaring `extern type T a` / `extern data T a = C a` registers `T` with `tcCarrier=True`; ordinary `data` keeps `tcCarrier=False`.
- [ ] `extern data`/`extern type` constructors and arity register exactly as a `data` decl would (so `case`-exhaustiveness and constructor schemes are identical).
- [ ] A `UserFile` with `extern data`/`extern type` -> `ExternNotAllowed`.
- [ ] Full suite green (baseline + new negatives).

**Verify:** `cabal test 2>&1 | grep -iE "extern-(data|type)-user-forbidden"` -> PASS

**Steps:**

- [ ] **Step 1: Add the `tcCarrier` field**

In `src/Wok/TypeChecking/Env.hs`, change `TyConInfo` (lines 44-49) to:

```haskell
data TyConInfo = TyConInfo
  { tcKind :: Kind
  , tcArity :: Int
  , tcCons :: [Text]
  , tcCarrier :: Bool
    -- ^ True iff this tycon was declared by an @extern data@/@extern type@
    -- (Embedded-only). A carrier tycon is second-class (no escape) and affine
    -- (consume-once); the Carrier analyses consult this flag, not a TyCon tag.
  }
  deriving (Eq, Show)
```

- [ ] **Step 2: Fix the construction sites flagged by the build**

Build to enumerate every site that constructs `TyConInfo` positionally:
```bash
cabal build 2>&1 | grep -iE "TyConInfo|expects 3|expected 4" | head
```

In `src/Wok/TypeChecking/Builtins.hs`, append `False` to each entry (lines 44-53):

```haskell
      [ ("U64",    TyConInfo KStar 0 [] False)
      , ("U32",    TyConInfo KStar 0 [] False)
      , ("String", TyConInfo KStar 0 [] False)
      , ("Never",  TyConInfo KStar 0 [] False)
      , ("Char",   TyConInfo KStar 0 [] False)
      , ("()",     TyConInfo KStar 0 [] False)
      , ("[]",     TyConInfo listKind 1 [] False)
      , ("Suspension", TyConInfo suspensionKind 3 [] False)
      , ("Step", TyConInfo stepKind 3 [Data.Text.pack "Completed", Data.Text.pack "Suspended"] False)
      ] ++ [ (tupleName n, TyConInfo (tupleKind n) n [] False) | n <- [2 .. 16] ]
```
(The `Suspension`/`Step` entries are removed in Task 4; for now they just gain `False`.)

In `test/Spec.hs`, lines 873-874, 909-910, 925 — append `False` to each `TE.TyConInfo Ty.KStar N []`:

```haskell
      let tciA = TE.TyConInfo Ty.KStar 0 [] False
          tciB = TE.TyConInfo Ty.KStar 1 [] False
```
(Apply the same `False` suffix at all three locations.)

Build until green:
```bash
cabal build 2>&1 | tail -3
```

- [ ] **Step 3: Write the failing elaboration test**

Add a unit test to `test/Spec.hs`. Find the `dataTests` group (it already tests `tcArity`/`tcCons` via `lookupTyCon`, see lines ~1125-1166) and add a sibling test that runs the type checker over an `Embedded` snippet and asserts `tcCarrier`. Mirror however `dataTests` currently obtains an `Env` from source (look at the existing `dataTests` body for the exact harness call — reuse it, passing `Embedded` origin). The assertion:

```haskell
    , testCase "extern data/type set tcCarrier; data does not" $ do
        env <- <existing-dataTests-typecheck-harness> Embedded
                 (T.unlines
                   [ "module M"
                   , "extern type Susp a b r"
                   , "extern data St a b r = Done r | More a (Susp a b r)"
                   , "data Plain a = MkPlain a" ])
        case TE.lookupTyCon (T.pack "Susp") env of
          Just i  -> TE.tcCarrier i @?= True
          Nothing -> assertFailure "Susp not registered"
        case TE.lookupTyCon (T.pack "St") env of
          Just i  -> do TE.tcCarrier i @?= True
                        TE.tcCons i @?= [T.pack "Done", T.pack "More"]
          Nothing -> assertFailure "St not registered"
        case TE.lookupTyCon (T.pack "Plain") env of
          Just i  -> TE.tcCarrier i @?= False
          Nothing -> assertFailure "Plain not registered"
```
If `dataTests` has no `Embedded` helper, the simplest is to call the same module-inference entry point `inferModule`/`inferModuleWith` that the existing data tests use; match their style exactly. Run it to confirm it FAILS (because `processDataDecls` ignores the new decls and never sets the flag):
```bash
cabal test 2>&1 | grep -iE "extern data/type set tcCarrier"
```
Expected: FAIL (e.g. `Susp not registered` — the tycon was never registered).

- [ ] **Step 4: Generalize `processDataDecls` over data-like decls**

In `src/Wok/TypeChecking/Infer.hs`, replace the `dataDecls` filter and the `DData`-only `registerTyCons`/`registerCons` clauses (lines 825-862) so they also handle `DExternData` and `DExternType`. Add a small classifier and route through it:

```haskell
processDataDecls :: Env -> [Abs.Decl] -> TC s Env
processDataDecls env0 decls = do
  envWithTyCons <- registerTyCons env0 dataDecls
  registerCons envWithTyCons dataDecls
  where
    dataDecls = filter isDataLike decls

    isDataLike Abs.DData{}       = True
    isDataLike Abs.DExternData{} = True
    isDataLike Abs.DExternType{} = True
    isDataLike _                 = False

    -- (pos, name, params, isCarrier) for the tycon-registration pass.
    dataLikeHead (Abs.DData (Abs.ConId (pos, n)) ps _)       = (pos, n, ps, False)
    dataLikeHead (Abs.DExternData (Abs.ConId (pos, n)) ps _) = (pos, n, ps, True)
    dataLikeHead (Abs.DExternType (Abs.ConId (pos, n)) ps)   = (pos, n, ps, True)
    dataLikeHead _ = error "processDataDecls.dataLikeHead: non-data-like (input pre-filtered)"

    -- The constructor defs to register, if any. extern type has none.
    conDefsOf (Abs.DData (Abs.ConId (pos, n)) ps cs)       = Just (pos, n, ps, cs)
    conDefsOf (Abs.DExternData (Abs.ConId (pos, n)) ps cs) = Just (pos, n, ps, cs)
    conDefsOf Abs.DExternType{}                            = Nothing
    conDefsOf _ = error "processDataDecls.conDefsOf: non-data-like (input pre-filtered)"

    registerTyCons env [] = pure env
    registerTyCons env (d : ds) =
      let (pos, name, params, carrier) = dataLikeHead d
      in case lookupTyCon name env of
        Just _  -> throwError (DuplicateTyCon (Just pos) name)
        Nothing -> do
          let k    = foldr KArrow KStar (replicate (length params) KStar)
              info = TyConInfo k (length params) [] carrier
          registerTyCons (extendTyCon name info env) ds

    registerCons env [] = pure env
    registerCons env (d : ds) = case conDefsOf d of
      Nothing -> registerCons env ds   -- extern type: opaque, no constructors
      Just (pos, tcName, params, conDefs) -> do
        let paramNames = [ n | Abs.VarId (_, n) <- params ]
            paramMap = Map.fromList (zip paramNames [0 ..])
        conDefs' <- normalizeElision (Just pos) tcName conDefs
        checkFieldNameUniqueness (Just pos) conDefs'
        env' <- foldM (registerCon tcName paramMap) env conDefs'
        let cons = [ cn | Abs.ConDef (Abs.ConId (_, cn)) _ <- conDefs' ]
            tcInfo = case lookupTyCon tcName env' of
              Just t  -> t { tcCons = cons }
              Nothing -> error "registerCons: tycon vanished"
            env'' = extendTyCon tcName tcInfo env'
        registerCons env'' ds
```
Leave `registerCon` (lines 864-896) and the helpers `normalizeElision`/`checkFieldNameUniqueness` unchanged — they already do the right thing on the unwrapped `[ConDef]`. Note `registerCon` uses `resolveTyCon tcName` for the result type; in this task `resolveTyCon "Step"`/`"Suspension"` still returns `TcStep`/`TcSuspension`, but the test uses neutral names `Susp`/`St`/`Plain` which resolve to `TcUser`, so the test is unaffected by the still-present built-ins.

- [ ] **Step 5: Run the elaboration test (now green)**

```bash
cabal test 2>&1 | grep -iE "extern data/type set tcCarrier"
```
Expected: PASS.

- [ ] **Step 6: Extend the Part-1 gate to reject extern types in a UserFile**

In `src/Wok/TypeChecking/Infer.hs`, add a scanner next to `externDecls` (after line 3148):

```haskell
-- | The @extern data@/@extern type@ declarations in a module, as
-- (tycon-name, position) pairs. Used by the Part-1 gate to reject either in a
-- UserFile: a marked carrier tycon is a trust anchor, mintable only by the
-- standard prelude (Embedded), exactly like a value-level @extern@.
externTypeDecls :: [Abs.Decl] -> [(Text, (Int, Int))]
externTypeDecls = concatMap go
  where
    go (Abs.DExternData (Abs.ConId (pos, n)) _ _) = [(n, pos)]
    go (Abs.DExternType (Abs.ConId (pos, n)) _)   = [(n, pos)]
    go (Abs.DLocal d)                             = go d
    go _                                          = []
```

Then extend the gate's `UserFile` branch (lines 3086-3089):

```haskell
    case origin of
      Embedded   -> pure ()
      UserFile _ -> do
        forM_ (externDecls decls) $ \(n, pos) ->
          throwError (ExternNotAllowed (Just pos) n)
        forM_ (externTypeDecls decls) $ \(n, pos) ->
          throwError (ExternNotAllowed (Just pos) n)
```

- [ ] **Step 7: Add the two UserFile negatives**

Create `test/typecheck-fail-examples/extern-data-user-forbidden.wok`:

```wok
module Main

extern data Bad a = MkBad a

main : U64
main = 0
```

Create `test/typecheck-fail-examples/extern-type-user-forbidden.wok`:

```wok
module Main

extern type Bad a

main : U64
main = 0
```
(Both are self-contained — they reach the gate rather than failing earlier on an unknown reference.)

- [ ] **Step 8: Generate and verify the negative goldens**

```bash
cabal test --test-options=--accept 2>&1 | grep -iE "extern-(data|type)-user-forbidden"
cat test/typecheck-fail-golden/extern-data-user-forbidden.expected
cat test/typecheck-fail-golden/extern-type-user-forbidden.expected
```
Expected: each contains `... ExternNotAllowed (Just (l,c)) "Bad"` (the row/col is whatever the file layout yields).

- [ ] **Step 9: Full suite (no regressions)**

```bash
cabal test 2>&1 | tail -20
```
Expected: baseline + Task 1's golden + the elaboration unit test + 2 negatives, all green.

- [ ] **Step 10: Commit**

```bash
git add src/Wok/TypeChecking/Env.hs src/Wok/TypeChecking/Builtins.hs src/Wok/TypeChecking/Infer.hs test/Spec.hs test/typecheck-fail-examples/extern-data-user-forbidden.wok test/typecheck-fail-examples/extern-type-user-forbidden.wok test/typecheck-fail-golden/extern-data-user-forbidden.expected test/typecheck-fail-golden/extern-type-user-forbidden.expected
git commit -m "feat(tc): elaborate extern data/type to carrier-marked tycons; gate to Embedded (slice 4d)"
```

---

## Task 3: Thread the carrier-tycon marker set through the analyses

**Goal:** Make `Carrier.hs`'s carrier-escape and affine-consumption predicates consult a `Set Text` of marked carrier-tycon names (computed from the env's `tcCarrier` flags) instead of hardcoded `TyCon` tags — while KEEPING `TcStep`/`TcSuspension` recognition as a temporary fallback so behavior is bit-identical (the prelude still declares them as built-ins; the marker set is empty in practice). This is a pure plumbing refactor; the cutover that flips the prelude and removes the fallback is Task 4.

**Files:**
- Modify: `src/Wok/TypeChecking/Carrier.hs` (predicates + threading)
- Modify: `src/Wok/TypeChecking/Infer.hs:3097-3134` (compute `carrierTys`, pass it in)
- Modify: `test/Spec.hs` (one anchor unit test)

**Acceptance Criteria:**
- [ ] `isHandleType`, `isAffineCarrierType`, `handleBindersOfPat`, `bindPats`, `bindDecls`, `isHandleSlot`, `isInlineFutureApp`, `futureBindersOfPat`, `futureBindersOfDecls`, `walk`, `checkCarriers`, `checkFutureAffine` all take/thread the carrier-tycon `Set Text`.
- [ ] `checkCarriers` / `checkFutureAffine` callers in `Infer.hs` pass `carrierTys` computed from `env2`.
- [ ] Behavior is unchanged: all 4c run-examples and negatives are byte-identical; full suite green.
- [ ] A unit test confirms `isHandleType`/affine see a `tcCarrier`-marked `TcUser` tycon as a carrier.

**Verify:** `cabal test 2>&1 | tail -20` -> baseline count preserved, all green

**Steps:**

- [ ] **Step 1: Rewrite the type predicates to take the marker set (with fallback)**

In `src/Wok/TypeChecking/Carrier.hs`, replace `isHandleType` (lines 362-369) with:

```haskell
-- | Is this a second-class HANDLE type — an effect-instance handle
-- @CTCon (TcEffect _) _@, or a MARKED carrier tycon (an @extern data@/@extern
-- type@, whose name is in @carrierTys@)? Both must not escape their scope.
--
-- NOTE (slice 4d transition): @TcSuspension@/@TcStep@ are kept as a fallback so
-- this refactor is behaviour-preserving while the prelude still declares them as
-- built-ins. Task 4 removes the fallback once the prelude flips to extern decls.
isHandleType :: Set Text -> CType -> Bool
isHandleType _          (CTCon (TcEffect _) _) = True
isHandleType carrierTys (CTCon (TcUser n)   _) = Set.member n carrierTys
isHandleType _          (CTCon TcSuspension  _) = True   -- TODO(4d): remove fallback
isHandleType _          (CTCon TcStep        _) = True   -- TODO(4d): remove fallback
isHandleType _          _                       = False
```

Replace `isAffineCarrierType` (lines 852-854) and delete `isSuspensionType` (lines 841-843); inline its meaning here:

```haskell
-- | Is this an AFFINE carrier type — a MARKED carrier tycon (consume-once)?
-- A 'Suspension' is consumed when passed as an argument; a 'Step' is consumed
-- when it is the SCRUTINEE of a @case@. Effect-instance handles are carriers but
-- are NOT subject to the consumption bound, so they are excluded here.
--
-- NOTE (slice 4d transition): TcStep/TcSuspension fallback removed in Task 4.
isAffineCarrierType :: Set Text -> CType -> Bool
isAffineCarrierType carrierTys (CTCon (TcUser n) _) = Set.member n carrierTys
isAffineCarrierType _          (CTCon TcStep _)      = True   -- TODO(4d): remove fallback
isAffineCarrierType _          (CTCon TcSuspension _) = True  -- TODO(4d): remove fallback
isAffineCarrierType _          _                     = False
```
Update the two comment references to `isSuspensionType` (lines 504, 838-840 region) to drop the dangling name; the doc comment on `futureBindersOfPat` (803-805) can stay accurate.

- [ ] **Step 2: Thread the set into the carrier walk**

In `Carrier.hs`:

(a) Add a field to `Ctx` (lines 63-80):
```haskell
data Ctx = Ctx
  { ctxResolve    :: ParamResolver
  , ctxSpan       :: SourceSpan
  , ctxName       :: Text
  , ctxHandlerArm :: Bool
  , ctxCarrierTys :: Set Text   -- ^ names of marked carrier tycons (slice 4d)
  }
```

(b) `checkCarriers` (lines 106-114) gains a leading `Set Text` param and builds `Ctx` with record syntax:
```haskell
checkCarriers
  :: Set Text -> ParamResolver -> Bool -> SourceSpan -> Text
  -> [([TPat], TExpr)] -> Either TypeError ()
checkCarriers carrierTys resolve resultIsCarrier sp name clauses =
  mapM_ checkClause clauses
  where
    ctx = Ctx { ctxResolve = resolve, ctxSpan = sp, ctxName = name
              , ctxHandlerArm = False, ctxCarrierTys = carrierTys }
    checkClause (pats, body) =
      let env0 = Env (Set.unions (map (handleBindersOfPat carrierTys) pats))
                     (Set.unions (map patVars pats))
      in check (ctx { ctxHandlerArm = resultIsCarrier }) env0 False body
```

(c) `check` (line 138): change the inline-future guard to pass the set:
```haskell
  | isInlineFutureApp (ctxCarrierTys ctx) e, not allowed, not (ctxHandlerArm ctx) = err ctx
```

(d) `isInlineFutureApp` (lines 190-192): add the set param:
```haskell
isInlineFutureApp :: Set Text -> TExpr -> Bool
isInlineFutureApp carrierTys (Texp ty (TApp _ _)) = isAffineCarrierType carrierTys ty
isInlineFutureApp _          _                    = False
```

(e) `recurse`: in the `TApp` case (lines 216-222) thread the set into `isHandleSlot`:
```haskell
        argAllowed i = case drop i paramTys of
          (pt : _) -> isHandleSlot (ctxCarrierTys ctx) pt
          []       -> False
```
In `TLam` (line 227): `check ctx (bindPats (ctxCarrierTys ctx) env pats) False body`.
In `TLet` (lines 240-243): `let env' = bindDecls (ctxCarrierTys ctx) env decls`.

(f) `isHandleSlot` (lines 385-389): add the set param and thread it:
```haskell
isHandleSlot :: Set Text -> CType -> Bool
isHandleSlot carrierTys pt = isHandleType carrierTys pt || isHandleContinuation pt
  where
    isHandleContinuation (CTArr dom _ _) = isHandleType carrierTys dom
    isHandleContinuation _               = False
```

(g) `checkDecl` (295-297), `checkAlt` (301-306), `checkArm` (318-322): each has `ctx` in scope; replace every `bindPats env ...` with `bindPats (ctxCarrierTys ctx) env ...` and `bindDecls env0 decls` with `bindDecls (ctxCarrierTys ctx) env0 decls`.

(h) `bindPats` (326-330) and `bindDecls` (345-359): add a leading `Set Text` param; thread it into `handleBindersOfPat` and `isHandleType`:
```haskell
bindPats :: Set Text -> Env -> [TPat] -> Env
bindPats carrierTys env pats = env
  { envCarriers = Set.union (envCarriers env) (Set.unions (map (handleBindersOfPat carrierTys) pats))
  , envLocals   = Set.union (envLocals env)   (Set.unions (map patVars pats))
  }

bindDecls :: Set Text -> Env -> [TLocalDecl CType] -> Env
bindDecls carrierTys env decls = env
  { envCarriers = Set.union (envCarriers env) (Set.fromList carrierNames)
  , envLocals   = Set.union (envLocals env)   (Set.fromList allNames)
  }
  where
    allNames = [ n | TLocalDecl n _ _ <- decls ]
    carrierNames =
      [ n
      | TLocalDecl n pats rhs <- decls
      , let inner = Set.union (envCarriers env)
                              (Set.unions (map (handleBindersOfPat carrierTys) pats))
      , directlyEscapes inner rhs
          || isHandleType carrierTys (peelArrowResults (length pats) (typeOf rhs))
      ]
    typeOf (Texp t _) = t
```

(i) `handleBindersOfPat` (404-420): add the set param and thread it to its recursive calls and `isHandleType`:
```haskell
handleBindersOfPat :: Set Text -> TPat -> Set Text
handleBindersOfPat carrierTys (Tpat ty p) = case p of
  TPVar n
    | isHandleType carrierTys ty -> Set.singleton n
    | otherwise                  -> Set.empty
  TPWild      -> Set.empty
  TPLitI _    -> Set.empty
  TPLitS _    -> Set.empty
  TPLitC _    -> Set.empty
  TPUnit      -> Set.empty
  TPTuple ps  -> Set.unions (map (handleBindersOfPat carrierTys) ps)
  TPList ps   -> Set.unions (map (handleBindersOfPat carrierTys) ps)
  TPCon _ ps  -> Set.unions (map (handleBindersOfPat carrierTys) ps)
  TPCons h t  -> Set.union (handleBindersOfPat carrierTys h) (handleBindersOfPat carrierTys t)
  TPAs n inner ->
    let rest = handleBindersOfPat carrierTys inner
    in if isHandleType carrierTys ty then Set.insert n rest else rest
```

- [ ] **Step 3: Thread the set into the affine walk**

In `Carrier.hs`:

(a) `checkFutureAffine` (559-573): add a leading `Set Text` param; thread it to seeding and `walk`:
```haskell
checkFutureAffine
  :: Set Text -> Set Text -> SourceSpan -> Text
  -> [([TPat], TExpr)] -> Either TypeError ()
checkFutureAffine carrierTys ownTopLevel sp name clauses = mapM_ checkClause clauses
  where
    trust = ReaderTrust preludeReaderNames
                        (Set.intersection preludeReaderNames ownTopLevel)
    checkClause (pats, body) =
      let seeded = Set.unions (map (futureBindersOfPat carrierTys) pats)
      in do
        mapM_ (checkBinder body) (Set.toList seeded)
        walk carrierTys trust sp name body
    checkBinder scope fut
      | consumeCard trust fut scope == Many = Left (FutureConsumedTwice sp fut)
      | otherwise                           = Right ()
```
(`consumeCard` does NOT need the set — it identifies binders by name/alias, not by type; only the binder-FINDING helpers use the type predicate.)

(b) `walk` (580-636): add a leading `Set Text` param; thread it to recursive `walk` calls and to `futureBindersOfPat`/`futureBindersOfDecls` in `TLam`, `TLet`, `walkAlt`, `walkArm`:
```haskell
walk :: Set Text -> ReaderTrust -> SourceSpan -> Text -> TExpr -> Either TypeError ()
walk carrierTys trust sp name (Texp _ node) = case node of
  ...
  TApp h args         -> walk carrierTys trust sp name h
                           >> mapM_ (walk carrierTys trust sp name) args
  TLam pats body      -> introducedBy (Set.unions (map (futureBindersOfPat carrierTys) pats)) body
                           >> walk carrierTys trust sp name body
  ...
  TLet decls body ->
    let futs = futureBindersOfDecls carrierTys decls
    in do mapM_ (checkBinder body) (Set.toList futs)
          mapM_ (\(TLocalDecl _ _ rhs) -> walk carrierTys trust sp name rhs) decls
          walk carrierTys trust sp name body
  ...
  where
    ...
    walkAlt (TAlt pat decls altBody) =
      let futs = Set.union (futureBindersOfPat carrierTys pat) (futureBindersOfDecls carrierTys decls)
      in do mapM_ (checkBinder altBody) (Set.toList futs)
            mapM_ (\(TLocalDecl _ _ rhs) -> walk carrierTys trust sp name rhs) decls
            walk carrierTys trust sp name altBody
    walkArm arm = case arm of
      TReturnArm pat body    -> introducedBy (futureBindersOfPat carrierTys pat) body
                                  >> walk carrierTys trust sp name body
      TOpArm _ _ pats _ body -> introducedBy (Set.unions (map (futureBindersOfPat carrierTys) pats)) body
                                  >> walk carrierTys trust sp name body
      TParamArm _ initE      -> walk carrierTys trust sp name initE
```
Thread `carrierTys` through ALL recursive `walk ...` occurrences in the body (every arm of the `case` and the `where` helpers).

(c) `futureBindersOfPat` (806-822) and `futureBindersOfDecls` (827-836): add the set param; thread to `isAffineCarrierType` and recursive calls (same shape as `handleBindersOfPat` in Step 2(i)):
```haskell
futureBindersOfPat :: Set Text -> TPat -> Set Text
futureBindersOfPat carrierTys (Tpat ty p) = case p of
  TPVar n
    | isAffineCarrierType carrierTys ty -> Set.singleton n
    | otherwise                         -> Set.empty
  ... (recurse with `futureBindersOfPat carrierTys`) ...

futureBindersOfDecls :: Set Text -> [TLocalDecl CType] -> Set Text
futureBindersOfDecls carrierTys decls = Set.unions
  [ binders
  | TLocalDecl n pats rhs <- decls
  , let resultIsFuture = null pats && isAffineCarrierType carrierTys (typeOf rhs)
        patFuts = Set.unions (map (futureBindersOfPat carrierTys) pats)
        binders = (if resultIsFuture then Set.singleton n else Set.empty)
                    `Set.union` patFuts
  ]
  where typeOf (Texp t _) = t
```

- [ ] **Step 4: Compute and pass `carrierTys` in `Infer.hs`**

In `src/Wok/TypeChecking/Infer.hs`, inside the `withEnv (const env1i) $ do` block, after `env2 <- currentEnv` (line 3080), add:

```haskell
    -- Names of marked carrier tycons (extern data/type), read off the env's
    -- tcCarrier flags. Threaded into both post-inference soundness passes so
    -- carrier-ness rides the marker, not a TyCon tag (slice 4d).
    let carrierTys = Set.fromList
          [ n | (n, info) <- Map.toList (envTyCons env2), tcCarrier info ]
```

Update the `checkCarriers` call (lines 3118-3121) to pass `carrierTys` first:
```haskell
      in either throwError pure
           (checkCarriers carrierTys resolveParams
                          (producerExempt && resultIsAffineCarrier arity (tdScheme td))
                          Nothing (tdName td) (tdClauses td))
```
Update the `checkFutureAffine` call (lines 3132-3134):
```haskell
    forM_ tds $ \td ->
      either throwError pure
        (checkFutureAffine carrierTys ownNonExtern Nothing (tdName td) (tdClauses td))
```
(Leave `resultIsAffineCarrier` as-is in this task — it still matches `TcStep`/`TcSuspension`; retargeting is Task 4. `carrierTys` is empty here because the prelude still uses built-ins, so the fallback in the predicates keeps behavior identical.)

- [ ] **Step 5: Confirm `Set`/`Map` are imported in `Infer.hs`**

`Set` and `Map` are already imported (the carrier rule and `localSchemes` use them). Build to confirm no import error:
```bash
cabal build 2>&1 | tail -5
```

- [ ] **Step 6: Add the day-one anchor unit test**

Add to `test/Spec.hs` (the `carrierRuleTests` group is the natural home — find it near line 1794). Add a test that builds a one-element carrier set and checks the predicates directly. If `isHandleType`/`isAffineCarrierType` are not exported from `Carrier.hs`, prefer an end-to-end assertion instead: a tiny `Embedded` module declaring `extern type H a` and a function that RETURNS an `H`-typed value must be rejected with `CarrierEscape` only when... — simplest is the behavioural anchor: assert that an `Embedded` program returning a marked-carrier value fails. Concretely add:

```haskell
    , testCase "marked extern type is treated as a non-escaping carrier" $ do
        -- An Embedded module: returning a marked carrier from a non-producer
        -- function is a CarrierEscape (the marker confers the discipline).
        let src = T.unlines
              [ "module M"
              , "extern type H a"
              , "extern mk : H U64"
              , "leak : H U64"
              , "leak = mk" ]
        case <typecheck-harness> Embedded src of
          Left e  | T.pack "CarrierEscape" `T.isInfixOf` (T.pack (show e)) -> pure ()
                  | otherwise -> assertFailure ("expected CarrierEscape, got: " ++ show e)
          Right _ -> assertFailure "expected CarrierEscape for returned marked carrier"
```
Use whatever `Embedded`-origin typecheck harness `carrierRuleTests` / `dataTests` already use (match the existing call exactly). If that group lacks a reusable harness returning `Either TypeError _`, reuse the same entry point the existing `assertCarrierEscape` helper calls (lines 1871-1875). Run it — it should PASS (the fallback OR the marker both classify `H` as a carrier; with the marker set non-empty for this `Embedded` module, the marker path is what fires).

- [ ] **Step 7: Full suite + coro regression sweep**

```bash
cabal test 2>&1 | tail -20
for f in coro-escape coro-step-range coro-step-zip coro-multi-driver; do
  printf "%s = " "$f"; cabal run -v0 wok -- test/run-examples/$f.wok --run
done
```
Expected: full suite green (baseline + the new anchor test); the four run-examples print `421 / 10 / 52 / 64`.

- [ ] **Step 8: Commit**

```bash
git add src/Wok/TypeChecking/Carrier.hs src/Wok/TypeChecking/Infer.hs test/Spec.hs
git commit -m "refactor(tc): thread carrier-tycon marker set through carrier/affine analyses (slice 4d)"
```

---

## Task 4: Cutover — declare `Step`/`Suspension` in the prelude; remove the built-ins

**Goal:** Flip `Std.Control` to real `extern type Suspension` / `extern data Step` decls, delete the `TcStep`/`TcSuspension` built-ins everywhere, drop the transition fallback in `Carrier.hs`, retarget the producer-exemption to the marker set, and regenerate the three affected typed-anf goldens. The marker becomes the single source of truth; behavior (4c run-examples + negatives) is preserved.

**Files:**
- Modify: `prelude/Std/Control.wok:23-50` (replace comment with decls)
- Modify: `src/Wok/TypeChecking/Builtins.hs` (remove `Step`/`Suspension` entries, constructors, dead helpers, unused imports)
- Modify: `src/Wok/TypeChecking/Types.hs:53-58` (remove `TcSuspension`/`TcStep` from `TyCon`)
- Modify: `src/Wok/TypeChecking/Infer.hs` (`resolveTyCon`, `prettyCType`, `prettyCTypeAtom`, `resultIsAffineCarrier`)
- Modify: `src/Wok/TypeChecking/Class.hs:180-181` (remove `tyConKey` cases)
- Modify: `src/Wok/TypeChecking/Carrier.hs` (drop the two fallback lines in each predicate)
- Modify: `test/typed-anf-golden/{future-arg-ok,future-type-mentions,step-case}.expected`

**Acceptance Criteria:**
- [ ] `Std.Control` declares `extern type Suspension a b r` and `extern data Step a b r = Completed r | Suspended a (Suspension a b r)`; the 4c comment block is gone.
- [ ] `TcStep`/`TcSuspension` no longer exist anywhere (`grep` returns nothing in `src/`).
- [ ] `resultIsAffineCarrier` consults `carrierTys`.
- [ ] All 4c run-examples (`421/10/52/64`) and negatives produce identical output.
- [ ] The three typed-anf goldens now read `Suspension`/`Step` instead of `TcSuspension`/`TcStep`.
- [ ] Full suite green.

**Verify:** `grep -rn "TcStep\|TcSuspension" src/` -> no matches; `cabal test` -> all green

**Steps:**

- [ ] **Step 1: Replace the prelude comment with real declarations**

In `prelude/Std/Control.wok`, replace the comment block (lines 23-50, the "COROUTINE TYPES (compiler built-ins)" block) with:

```wok
-- COROUTINE TYPES (prelude-declared `extern`; slice 4d).
--
-- `Suspension` is the opaque, second-class, affine parked producer: you never
-- construct one; you obtain it from a `Suspended` arm and feed it to
-- `step`/`run`/`cancel`. `Step` is the closed outcome of one step; eliminate it
-- with an ordinary `case` (both arms). Their carrier + consume-once discipline
-- rides the `extern` marker (Embedded-only), not the names.
extern type Suspension a b r

extern data Step a b r = Completed r | Suspended a (Suspension a b r)
```
Keep everything below (the `__coro_*` value externs, `start`/`step`/`run`/`cancel`) unchanged. Use single-line `extern data` form (matching Std.Base's single-line `data` style, lines 15-17) to avoid any layout-continuation risk.

- [ ] **Step 2: Remove the built-in tycon + constructor registrations**

In `src/Wok/TypeChecking/Builtins.hs`:
- Delete the `("Suspension", ...)` and `("Step", ...)` entries from `tyConEntries` (lines 51-52).
- Replace the `conEntries` definition (lines 71-77) with `conEntries = []` (the `Step` constructors are now declared by the prelude).
- Delete the now-unused `where` helpers: `suspensionKind`, `stepKind`, `stepTy`, `suspTy`, `vars3`, `arr`, and the comment block at 55-58.
- Remove now-unused imports: `CType`, `CRow`, `TyCon`, `Scheme` from the `Wok.TypeChecking.Types` import (keep only `Kind`); remove `import qualified Data.Text` and the `Data.Text (Text)` import if `conEntries`/the deleted code were their only users. Build with `-Werror` to find exactly which imports/bindings are now unused:

```bash
cabal build 2>&1 | grep -iE "unused|defined but not used|redundant" | head
```
Remove each flagged import/binding until clean. (`tupleName`/`tupleKind`/`listKind` and `Text` are still used by the tuple/list entries — keep them.)

- [ ] **Step 3: Remove the `TyCon` enum constructors**

In `src/Wok/TypeChecking/Types.hs`, delete `TcSuspension` (line 53) and `TcStep` plus its comment (lines 54-58) from the `TyCon` enum. The result keeps `... | TcList | TcUser Text | TcEffect Text`.

- [ ] **Step 4: Remove `resolveTyCon` name cases**

In `src/Wok/TypeChecking/Infer.hs`, delete the two lines (755-756):
```haskell
  | name == Tx.pack "Suspension" = TcSuspension
  | name == Tx.pack "Step"   = TcStep
```
Now `resolveTyCon "Step"`/`"Suspension"` fall through to `TcUser name`, exactly like `Bool`/`Result`.

- [ ] **Step 5: Remove `prettyCType`/`prettyCTypeAtom` cases**

In `src/Wok/TypeChecking/Infer.hs`, delete the `CTCon TcSuspension xs` and `CTCon TcStep xs` clauses in `prettyCType` (lines 3511-3514) and in `prettyCTypeAtom` (lines 3541-3544). The generic `CTCon (TcUser n) xs` clauses (3505-3507, 3537-3538) now render them as `"Suspension ..."`/`"Step ..."` — same text as before.

- [ ] **Step 6: Remove `tyConKey` cases**

In `src/Wok/TypeChecking/Class.hs`, delete lines 180-181:
```haskell
tyConKey TcSuspension = Tx.pack "Suspension"
tyConKey TcStep       = Tx.pack "Step"
```
`tyConKey (TcUser t) = t` (line 183) now produces the same `"Step"`/`"Suspension"` keys.

- [ ] **Step 7: Retarget `resultIsAffineCarrier` to the marker set**

In `src/Wok/TypeChecking/Infer.hs`, change `resultIsAffineCarrier` (lines 3167-3175) to take the carrier set:
```haskell
resultIsAffineCarrier :: Set.Set Text -> Int -> Scheme -> Bool
resultIsAffineCarrier carrierTys arity = isCarrier . peel arity . schemeBody
  where
    peel 0 t              = t
    peel n (CTArr _ _ b)  = peel (n - 1) b
    peel _ t              = t
    isCarrier (CTCon (TcUser n) _) = Set.member n carrierTys
    isCarrier _                    = False
```
Update its call site (line 3120) to pass `carrierTys`:
```haskell
                          (producerExempt && resultIsAffineCarrier carrierTys arity (tdScheme td))
```

- [ ] **Step 8: Drop the transition fallback in `Carrier.hs`**

In `src/Wok/TypeChecking/Carrier.hs`, delete the two `-- TODO(4d): remove fallback` lines in `isHandleType` and the two in `isAffineCarrierType` (the `CTCon TcSuspension`/`CTCon TcStep` clauses added in Task 3 Step 1). The predicates become:
```haskell
isHandleType :: Set Text -> CType -> Bool
isHandleType _          (CTCon (TcEffect _) _) = True
isHandleType carrierTys (CTCon (TcUser n)   _) = Set.member n carrierTys
isHandleType _          _                       = False

isAffineCarrierType :: Set Text -> CType -> Bool
isAffineCarrierType carrierTys (CTCon (TcUser n) _) = Set.member n carrierTys
isAffineCarrierType _          _                     = False
```
Update the doc comments that still mention `TcSuspension`/`TcStep` (lines ~364, 504, 803-805, 838-840) to refer to "a marked carrier tycon" instead.

- [ ] **Step 9: Build clean**

```bash
cabal build 2>&1 | tail -10
grep -rn "TcStep\|TcSuspension" src/
```
Expected: build succeeds; `grep` returns NOTHING in `src/`. Fix any remaining reference the compiler flags.

- [ ] **Step 10: Regenerate the three typed-anf goldens**

```bash
cabal test --test-options=--accept 2>&1 | grep -iE "future-arg-ok|future-type-mentions|step-case"
git diff test/typed-anf-golden/
```
Expected diff: ONLY `TcSuspension` -> `Suspension` and `TcStep` -> `Step` in those three files (e.g. `future-arg-ok.expected` line 1 `TcSuspension U64 U64 U64` -> `Suspension U64 U64 U64`; `step-case.expected` `TcStep U64 () U64` -> `Step U64 () U64`). If ANY other golden changed, investigate before accepting — a typecheck-success golden change would mean the pretty-printer reasoning was wrong.

- [ ] **Step 11: 4c regression sweep**

```bash
cabal test 2>&1 | tail -20
for f in coro-escape coro-step-range coro-step-zip coro-multi-driver; do
  printf "%s = " "$f"; cabal run -v0 wok -- test/run-examples/$f.wok --run
done
for f in step-escapes suspension-escapes step-scrutinized-twice future-await-twice \
         step-inline-escape-list step-inline-escape-return step-inline-escape-tuple; do
  printf "%s: " "$f"; cabal run -v0 wok -- test/typecheck-fail-examples/$f.wok 2>&1 | tail -1
done
```
Expected: full suite green; run-examples `421/10/52/64`; negatives report `CarrierEscape`/`FutureConsumedTwice` exactly as in the baseline table.

- [ ] **Step 12: Commit**

```bash
git add prelude/Std/Control.wok src/Wok/TypeChecking/Builtins.hs src/Wok/TypeChecking/Types.hs src/Wok/TypeChecking/Infer.hs src/Wok/TypeChecking/Class.hs src/Wok/TypeChecking/Carrier.hs test/typed-anf-golden/
git commit -m "feat(tc): declare Step/Suspension as prelude extern types; remove TcStep/TcSuspension built-ins (slice 4d)"
```

---

## Task 5: Robustness — user `data Step` type-checks; sweep `examples/`

**Goal:** Prove the marker, not the name, confers the discipline: a `UserFile` declaring its own unmarked `data Step a b r = ...` (no import of `Std.Control`) and returning/storing it freely must type-check. Plus manually sweep the non-CI `examples/` coroutine programs (they are NOT scanned by the suite).

**Files:**
- Create: `test/typecheck-examples/user-data-step-not-carrier.wok`
- Create (via `--accept`): `test/typecheck-golden/user-data-step-not-carrier.expected`, `test/typed-anf-golden/user-data-step-not-carrier.expected`, `test/anf-golden/user-data-step-not-carrier.expected`
- Sweep (no edits expected): `examples/{coroutine,generators-pull,pull-take,pull-zip}.wok`

**Acceptance Criteria:**
- [ ] A `UserFile` with its own unmarked `data Step a b r` that returns AND stores values of that type type-checks (no `CarrierEscape`, no `FutureConsumedTwice`).
- [ ] All `examples/` coroutine programs still run with their previous results.
- [ ] Full suite green.

**Verify:** `cabal test 2>&1 | grep -i "user-data-step-not-carrier"` -> PASS

**Steps:**

- [ ] **Step 1: Write the robustness example**

Create `test/typecheck-examples/user-data-step-not-carrier.wok`. It declares its OWN `Step` (same name and shape as the prelude's, but UNMARKED and NOT imported) and both returns it and stores it in a list — operations the carrier rule forbids for a marked carrier. Because this `Step` is an ordinary `TcUser` with `tcCarrier=False`, it must be accepted:

```wok
module Main
import Std.Base

data Step a b r = Completed r | Suspended a r

mkStep : U64 -> Step U64 U64 U64
mkStep n = Completed n

returnIt : Step U64 U64 U64
returnIt = mkStep 7

storeIt : [Step U64 U64 U64]
storeIt = [mkStep 1, mkStep 2]

main : U64
main = case returnIt of
  Completed r -> r
  Suspended x y -> x
```
(Do NOT `import Std.Control` here — that would trigger the orthogonal same-name cross-module conflict on `Step`, which is out of scope. The point is that an unmarked `Step` is free.)

- [ ] **Step 2: Confirm it type-checks and runs**

```bash
cabal run -v0 wok -- test/typecheck-examples/user-data-step-not-carrier.wok 2>&1 | tail -5
cabal run -v0 wok -- test/typecheck-examples/user-data-step-not-carrier.wok --run
```
Expected: type-checks cleanly (no `CarrierEscape`); `--run` prints `7`. If it reports `CarrierEscape`/`FutureConsumedTwice`, the marker is leaking via the name — STOP and re-examine `resolveTyCon` / `carrierTys` (the user `Step` must be unmarked).

- [ ] **Step 3: Generate its goldens**

```bash
cabal test --test-options=--accept 2>&1 | grep -i "user-data-step-not-carrier"
git status --short test/typecheck-golden/ test/typed-anf-golden/ test/anf-golden/
```
Confirm only the new `user-data-step-not-carrier.expected` files appear (this source is in `test/typecheck-examples/`, which feeds the typecheck-success, anf, and typed-anf golden groups — see `test/Spec.hs:63-66`).

- [ ] **Step 4: Manually sweep the non-CI examples**

`examples/` is NOT scanned by the suite. Run each coroutine program and confirm it still works (capture the output; these have no recorded golden, so compare against a `main` checkout if unsure):

```bash
for f in coroutine generators-pull pull-take pull-zip; do
  echo "=== examples/$f.wok ==="
  cabal run -v0 wok -- examples/$f.wok --run 2>&1 | tail -3
done
```
Expected: every program runs without a type error and produces a sensible result. If any program used a form that the cutover changed, note it; none is expected to need edits (the surface `case`/`Completed`/`Suspended`/`step`/`run`/`cancel` is unchanged from 4c). If an example DOES need a trivial fix, make it and note it in the commit.

- [ ] **Step 5: Full suite**

```bash
cabal test 2>&1 | tail -20
```
Expected: all green (baseline + every test added across Tasks 1-5).

- [ ] **Step 6: Commit**

```bash
git add test/typecheck-examples/user-data-step-not-carrier.wok test/typecheck-golden/user-data-step-not-carrier.expected test/typed-anf-golden/user-data-step-not-carrier.expected test/anf-golden/user-data-step-not-carrier.expected
# include any examples/ edits only if Step 4 required them
git commit -m "test(4d): unmarked user data Step type-checks; sweep examples (slice 4d)"
```

---

## Task 6: Full-branch review and finish

**Goal:** Satisfy the standing rule — a FULL-BRANCH code review before any merge to `main` — then integrate.

**Files:** none (review + integration).

**Acceptance Criteria:**
- [ ] Full-branch review completed against `main`; findings triaged.
- [ ] `cabal build` and `cabal test` green on the final tree.
- [ ] `grep -rn "TcStep\|TcSuspension" src/` is empty.
- [ ] Integration decision made (merge / PR) per the user's preference.

**Verify:** review report produced; suite green.

**Steps:**

- [ ] **Step 1: Final verification snapshot**

```bash
cabal build 2>&1 | tail -3
cabal test 2>&1 | tail -20
grep -rn "TcStep\|TcSuspension" src/ || echo "clean: no built-in carrier tags remain"
git log --oneline main..HEAD
```

- [ ] **Step 2: Request a full-branch code review**

Invoke the `superpowers-extended-cc:requesting-code-review` skill (or the user's `/code-review` flow) scoped to the WHOLE branch diff `main..HEAD`, not per-task. The review must check: the grammar change introduced no new conflicts; the marker is the SOLE carrier mechanism (no residual name-keying); the producer-exemption retarget is Embedded-gated; the runtime/prims are untouched; the 4c regression table holds.

- [ ] **Step 3: Triage findings**

Use `superpowers-extended-cc:receiving-code-review` to evaluate each finding with technical rigor. Apply fixes as small follow-up commits; re-run `cabal test` after each.

- [ ] **Step 4: Finish the branch**

Invoke `superpowers-extended-cc:finishing-a-development-branch` and follow the user's chosen integration path. Per the user's standing preference, confirm in prose before merging to `main`.

---

## Self-review notes (author's pass against the spec)

- **Spec §2 (surface):** Task 4 Step 1 replaces the comment with the two decls. ✔
- **Spec §3 (Embedded-only + carrier + affine):** gate in Task 2 Step 6; discipline via marker in Tasks 3-4. ✔
- **Spec §4 (trust the marker):** built-ins removed (Task 4 Steps 2-6); `tcCarrier` flag (Task 2); analyses consult the set (Task 3); producer-exemption retargeted (Task 4 Step 7). ✔
- **Spec §4 runtime-unchanged:** `Prim.hs` never touched; verified by the run-examples sweep (Tasks 3, 4). ✔
- **Spec §5 (grammar):** two productions, BNFC regen, three manual patches reapplied, conflict count checked (Task 1). The `extern data ... = ...` two-form spelling is used (not the constructor-less fallback), since `type`/`data` are already keywords and disambiguation is clean. ✔
- **Spec §6 (robustness):** unmarked user `data Step` type-checks (Task 5). ✔
- **Spec §9 (testing):** surface/visibility (Task 1 round-trip golden + Task 4 prelude flip), discipline-preserved negatives (Task 4 regression sweep), robustness (Task 5), day-one anchor (Task 3 Step 6), UserFile-extern gate (Task 2). ✔
- **Spec §10 (build/verify):** `cabal build`/`cabal test`/`--run`; BNFC regen + 3 patches + conflict check (Task 1); full-branch review (Task 6). ✔
- **Out of scope** (generalizing extern type/data, transitive-containment, user construction of `Step`, projection-laundering, residual-row guard): none introduced. ✔
