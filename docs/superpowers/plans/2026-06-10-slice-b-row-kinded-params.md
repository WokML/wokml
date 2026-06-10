# Slice B — Row-Kinded Type-Constructor Parameters Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers-extended-cc:subagent-driven-development (recommended) or superpowers-extended-cc:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add the facility for a type constructor to declare a parameter of kind `Row` (`KEffect`) via `(row e)`, pass a row variable as a type argument `(row e)` (in signatures and constructor fields), and kind-check tycon applications — proven by test fixtures only (no prelude/`Suspension`/runtime change).

**Architecture:** A new `(row VarId)` grammar form in two positions (tycon parameter, type argument). Elaboration gives `TyConInfo` real per-parameter kinds and per-parameter constructor quantifiers; a `(row e)` argument elaborates to a `KEffect` variable that, inside a declaration, resolves to the bound row parameter. Tycon applications gain a kind check (each argument's kind must match the declared parameter kind) that throws a contextual kind error. Nothing else changes; the facility is proven by fixtures.

**Tech Stack:** Haskell, GHC 9.10, BNFC 2.9.6.3 (grammar → Alex/Happy), `-Wall -Werror`, `tasty-golden`.

---

## Background the engineer needs

This is Slice B of `docs/superpowers/specs/2026-06-10-slice-b-row-kinded-params-design.md`, built on the merged kinded-`Ty` foundation (Slice A, on `main`). Read the spec's §3 (kind), §4 (syntax), §7 (kind-check), §12 (scope). Memory `kinded-ty-representation` and `wok-constructor-naming-convention` give the foundation + style.

### The kinded foundation (Slice A, already on `main`)

`src/Wok/TypeChecking/Types.hs`: ONE kinded type-expression sort. A row is a `Type s`/`CType` of kind `KEffect`; `type Row s = Type s` / `type CRow = CType` are aliases; row constructors are `RowEmpty`/`RowExtend` (inference) and `CREmpty`/`CRExtend` (closed); `CTGen Int` is a quantified var whose kind comes from the scheme's `[(Int,Kind)]` quantifier list. `Kind = KStar | KEffect | KArrow Kind Kind`; `KEffect` is the row kind. `unifyVar` kind-checks (Slice A added `KindMismatch SourceSpan CType CType` + `kindOf`). **Decidability contract:** variable kinds stay `{KStar, KEffect}`; no `KArrow`-kinded variables; kind-checking is syntax-directed.

### Exactly what Slice B needs (and what it doesn't)

- A tycon parameter `(row e)` has kind `KEffect`; a bare `a` stays `KStar`.
- A `(row e)` *argument* appears in (a) a **signature** (`peek : Box (row e) -> U64`) and (b) a **constructor field** as a tycon-application argument (`data Pair (row e) = Pair (Box (row e))`). It elaborates to a `KEffect` variable.
- Applications are kind-checked: a `*`-typed arg in a row slot, or a row arg in a `*` slot → a contextual kind error.
- **NOT in scope:** effect-carrying *arrow* fields (`field : () -> a with eff e`) — `translateConArg` rejects `with` in field types (`Infer.hs:919-934`, "a later feature") and 4b″ does not need it (it threads `e` as a tycon argument, e.g. `Step … (Suspension a b r e)`). Also out: concrete rows as arguments (`Box {Log}`), kind polymorphism, applying to `Suspension`/`Step`.

### Grounded code sites

- `grammar/Wok.cf`: `DData`/`DExternData`/`DExternType` use `[VarId]` (lines 89-91); `separator VarId ""` (142); `Type2` productions (271-276); `RCVar ::= "row" VarId` (291, existing `row`-keyword use); `row` is in `ReservedKw` (126-127).
- `src/Wok/TypeChecking/Env.hs:44-49`: `TyConInfo { tcKind :: Kind, tcArity :: Int, tcCons :: [Text], tcCarrier :: Bool }`.
- `src/Wok/TypeChecking/Infer.hs`:
  - `processDataDecls` registers tycons/constructors. `registerTyCons` builds `tcKind = foldr KArrow KStar (replicate (length params) KStar)` (all `KStar`) and `info = TyConInfo k (length params) [] carrier`. `registerCon` builds the constructor scheme with `quantifiers = [ (i, KStar) | i <- [0 .. paramCount-1] ]` (**all `KStar`** — lines ~874, ~908). `dataLikeHead`/`conDefsOf` extract `(pos, name, params, carrier)` from the three decl forms (Slice 4d added this).
  - `translateConArg`/`walkArg` translates a constructor field type; `walkArg (Abs.TApp …)` handles a tycon-application field (arity check at ~947/958). It REJECTS `with` (the `walkArg other` fall-through).
  - The signature-type translator `goT` (inside the `Abs.Type → Scheme` builder): `goT (Abs.TVar …)` allocates a `KStar` `CTGen` slot via `seenRef`/`allocSlot`; `goT (Abs.TApp …)` checks arity then `CTCon (resolveTyCon name) <$> mapM goT args` (lines 551-570); row variables (`eff e`) are allocated as `KEffect` slots in the effect-row path (search the file for how `Abs.ERVarOnly`/effect rows allocate a `KEffect` quantifier — mirror it for `(row e)`).
- `src/Wok/TypeChecking/Error.hs`: `TypeError` (has `KindMismatch SourceSpan CType CType` from Slice A); `Kind` is in `Types`.
- Coro regression anchors: `421/10/52/64`. Current suite: **701** green.

### Method

Grammar change ⇒ BNFC regen + reapply the 3 manual patches (`grammar/Wok.cf` top comments) + confirm shift/reduce conflicts stay at **31**. Use `-Werror` exhaustiveness as the porting worklist. Full-branch review before merge.

### Files this slice touches

- `grammar/Wok.cf`, `src-generated/GeneratedParser/Wok/*` (Task 1)
- `src/Wok/Reordering.hs` (Task 1, if `Abs` shape of the decls changes the `reorderDecl` patterns)
- `src/Wok/TypeChecking/Env.hs` (Task 2, per-param kinds on `TyConInfo`)
- `src/Wok/TypeChecking/Infer.hs` (Task 2 elaboration, Task 3 kind-check + prettyCType)
- `src/Wok/TypeChecking/Error.hs` (Task 3, contextual kind error)
- `test/typecheck-examples/`, `test/typecheck-fail-examples/`, `test/Spec.hs` (Tasks 2-3)

---

## Task 0: Branch and baseline

**Goal:** Branch from `main`; record the green baseline + the parser conflict count.

**Files:** none.

**Acceptance Criteria:**
- [ ] On branch `feat/slice-b-row-kinded-params` from `main`.
- [ ] `cabal test` green (701); coro anchors `421/10/52/64`.
- [ ] Happy shift/reduce conflict count recorded (expect 31).

**Verify:** `git branch --show-current` → `feat/slice-b-row-kinded-params`

**Steps:**

- [ ] **Step 1: Branch**
```bash
cd /Users/zy/wokml
git checkout main
git checkout -b feat/slice-b-row-kinded-params
```

- [ ] **Step 2: Baseline**
```bash
cabal test 2>&1 | grep -iE "All [0-9]+ tests"
for f in coro-escape coro-step-range coro-step-zip coro-multi-driver; do printf "%s=" "$f"; cabal run -v0 wok -- test/run-examples/$f.wok --run; done
```
Expected: `All 701 tests passed`; `421/10/52/64`.

- [ ] **Step 3: Conflict baseline**
```bash
happy src-generated/GeneratedParser/Wok/Par.y --ghc -i/tmp/wok-b0.info 2>&1 | grep -i conflict; grep -iE "shift/reduce conflicts:" /tmp/wok-b0.info; rm -f /tmp/wok-b0.info
```
Expected: `shift/reduce conflicts:  31`.

---

## Task 1: Grammar — `(row e)` parameter and type-argument forms

**Goal:** Add the `(row VarId)` parameter form to the three data-decl productions and a `(row VarId)` `Type2`; regenerate; reapply patches; keep `reorderDecl` exhaustive; prove the forms parse, with the conflict count unchanged. Nothing elaborates them yet.

**Files:**
- Modify: `grammar/Wok.cf`
- Regenerate: `src-generated/GeneratedParser/Wok/*`
- Modify: `src/Wok/Reordering.hs` (only if the `DData`/`DExternData`/`DExternType` `Abs` shape changed)
- Create: `test/examples/41-row-kinded-params.wok` + golden (parse round-trip)

**Acceptance Criteria:**
- [ ] `TyParam` category with `TPPlain`/`TPRow`; the three decls use `[TyParam]`; a `(row VarId)` `Type2`.
- [ ] BNFC regen + 3 manual patches reapplied; conflict count still 31.
- [ ] `cabal build` clean; existing `data`/`extern` decls parse unchanged.
- [ ] A round-trip parse golden for the new forms.

**Verify:** `cabal test 2>&1 | grep -i 41-row-kinded-params` → PASS

**Steps:**

- [ ] **Step 1: Grammar productions**

In `grammar/Wok.cf`, add a `TyParam` category and switch the data-decl param lists to it. Replace the `[VarId]` in `DData`/`DExternData`/`DExternType` (lines 89-91) with `[TyParam]`, and add:
```
-- Type-constructor parameters: a bare VarId (kind *) or `(row VarId)` (kind Row/KEffect, slice B).
TPPlain.  TyParam ::= VarId ;
TPRow.    TyParam ::= "(" "row" VarId ")" ;
separator TyParam "" ;
```
So the three decls read:
```
DData.       Decl ::= "data" ConId [TyParam] "=" [ConDef] ;
DExternData. Decl ::= "extern" "data" ConId [TyParam] "=" [ConDef] ;
DExternType. Decl ::= "extern" "type" ConId [TyParam] ;
```
(Leave `DEffect ConId [VarId]` on `[VarId]` — effects get no row params in Slice B.) Add a `Type2`:
```
TRowArg.  Type2 ::= "(" "row" VarId ")" ;   -- a row variable as a type argument (slice B)
```
Add a top-of-file POST-REGEN NOTE bullet: slice B added `TyParam` (`(row e)`) and the `TRowArg` `Type2`; no new manual patch required.

- [ ] **Step 2: Regenerate + conflict check**
```bash
cd /Users/zy/wokml
bnfc --haskell -d -p GeneratedParser --text-token -o src-generated grammar/Wok.cf 2>&1 | grep -iE "conflict" || echo "bnfc: no .cf conflicts"
happy src-generated/GeneratedParser/Wok/Par.y --ghc -i/tmp/wok-b1.info 2>&1 | grep -i conflict; grep -iE "shift/reduce conflicts:" /tmp/wok-b1.info; rm -f /tmp/wok-b1.info
```
Confirm `shift/reduce conflicts:  31` (unchanged). If it increased, the `(row …)` forms are ambiguous — stop and re-examine (most likely the `Type2` `(row VarId)` vs `(Type)` — but `row` is a keyword so `(Type)` can't start with it; investigate before proceeding).

- [ ] **Step 3: Reapply the 3 manual patches**

Per `grammar/Wok.cf` lines 13-69: (1) `Layout.hs` decl-separator paren-branch split (binder `pt`); (2) `Par.y` left-recursive `NEListRecordFieldPat` (both `PRecord` and `PRecordOpen` route through it); (3) `Par.y` empty-record `ConId '{' '}'` rule. Confirm:
```bash
grep -n "NEListRecordFieldPat\|PRecord \$1 \[\]" src-generated/GeneratedParser/Wok/Par.y
grep -n "isParenOpen" src-generated/GeneratedParser/Wok/Layout.hs
```

- [ ] **Step 4: Keep `reorderDecl` exhaustive**

The `DData`/`DExternData`/`DExternType` `Abs` constructors now carry `[TyParam]` instead of `[VarId]`. `reorderDecl` matches them with `@(DData{})` wildcards (`src/Wok/Reordering.hs:220-222`), so it likely still compiles. Build and fix any incompleteness the compiler reports:
```bash
cabal build 2>&1 | grep -iE "error:|incomplete|TyParam|DData" | head
```
If `reorderDecl` or another exhaustive `Decl` match breaks, update it (the param list is opaque to reordering — pass through unchanged).

- [ ] **Step 5: Build clean**
```bash
cabal build 2>&1 | tail -3
```
Expected: clean. `processDataDecls` etc. now receive `[TyParam]` — they will need updating in Task 2, but Task 1 only needs the build green. If `processDataDecls`'s `dataLikeHead`/`registerCon` pattern-match `[VarId]` and now break, do the MINIMAL Task-1 fix: extract just the names (treat every `TyParam` as a plain name for now, ignoring `(row …)`'s kind) so the build compiles; Task 2 adds the real kind handling. Concretely, a helper `tyParamName :: Abs.TyParam -> Text` (`TPPlain (VarId (_,n)) -> n`; `TPRow (VarId (_,n)) -> n`) used where `[VarId]` names were extracted.

- [ ] **Step 6: Parse round-trip example**

Create `test/examples/41-row-kinded-params.wok` (parse-only; not loaded/typechecked):
```wok
data Box (row e) = Box U64
data Pair (row e) = Pair (Box (row e))
peek : Box (row e) -> U64
```

- [ ] **Step 7: Generate + verify golden**
```bash
cabal test --test-options=--accept 2>&1 | grep -i "41-row-kinded-params"
cat test/golden/41-row-kinded-params.expected
git status --short test/golden/ | grep -v 41-row-kinded-params || echo "(only the new golden added)"
cabal test 2>&1 | grep -iE "All [0-9]+ tests"
```
Expected: round-trip golden added; no other golden changed; suite green (702).

- [ ] **Step 8: Commit**
```bash
git add grammar/Wok.cf src-generated/ src/Wok/Reordering.hs src/Wok/TypeChecking/Infer.hs test/examples/41-row-kinded-params.wok test/golden/41-row-kinded-params.expected
git commit -m "feat(grammar): (row e) tycon-param + type-arg forms (slice B)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 2: Elaboration — per-parameter kinds + `(row e)` argument elaboration (positive proof)

**Goal:** Give `TyConInfo` real per-parameter kinds and constructors per-parameter quantifiers; elaborate a `(row e)` argument (in a signature and a constructor field) to a `KEffect` variable resolving to a bound row param; make the positive fixture type-check and run. (Kind *rejection* of ill-kinded applications is Task 3.)

**Files:**
- Modify: `src/Wok/TypeChecking/Env.hs` (per-param kinds on `TyConInfo`)
- Modify: `src/Wok/TypeChecking/Infer.hs` (`processDataDecls`: `registerTyCons` `tcKind`, `registerCon` quantifiers; `translateConArg`/`walkArg` and `goT`: `(row e)` argument → `KEffect`)
- Create: `test/typecheck-examples/row-param-box.wok` + its goldens (typecheck/anf/typed-anf) and `test/run-examples/row-param-box.wok` + run golden

**Acceptance Criteria:**
- [ ] `TyConInfo` exposes per-parameter kinds (a `tcParamKinds :: [Kind]` field, or `tcKind` decomposed); a `(row e)` param ⇒ `KEffect`, a bare param ⇒ `KStar`.
- [ ] `registerCon` builds constructor quantifiers using the per-param kinds (not all-`KStar`).
- [ ] A `(row e)` type argument elaborates to a `KEffect` variable in BOTH `translateConArg` (fields) and `goT` (signatures); inside a decl it resolves to the bound row param's slot.
- [ ] The positive fixture type-checks and `--run`s to `5`.
- [ ] Full suite green; no pre-existing golden changed.

**Verify:** `cabal run -v0 wok -- test/run-examples/row-param-box.wok --run` → `5`

**Steps:**

- [ ] **Step 1: Per-parameter kinds on `TyConInfo`**

In `src/Wok/TypeChecking/Env.hs`, add a field recording each parameter's kind:
```haskell
data TyConInfo = TyConInfo
  { tcKind       :: Kind
  , tcArity      :: Int
  , tcCons       :: [Text]
  , tcCarrier    :: Bool
  , tcParamKinds :: [Kind]   -- ^ kind of each parameter, in order (slice B; KStar for bare, KEffect for (row e))
  }
  deriving (Eq, Show)
```
Build to find every `TyConInfo` construction (`Builtins.hs`, `Infer.hs`, `test/Spec.hs`) and add the field. For the built-ins in `Builtins.hs`, `tcParamKinds = replicate arity KStar` (all current built-ins are `*`-kinded params): e.g. `("[]", TyConInfo listKind 1 [] False [KStar])`, tuples `(tupleName n, TyConInfo (tupleKind n) n [] False (replicate n KStar))`, nullary ones `[]`. In `test/Spec.hs` add `[]` or `[KStar]`/`[KStar,KStar]` matching each test tycon's arity.

- [ ] **Step 2: Build per-param kinds in `processDataDecls`**

In `Infer.hs`, where `dataLikeHead` returns the params and `registerTyCons` builds the kind, compute a per-param kind list from the `[TyParam]`:
```haskell
paramKind :: Abs.TyParam -> Kind
paramKind (Abs.TPPlain _) = KStar
paramKind (Abs.TPRow _)   = KEffect

tyParamName :: Abs.TyParam -> Text
tyParamName (Abs.TPPlain (Abs.VarId (_, n))) = n
tyParamName (Abs.TPRow   (Abs.VarId (_, n))) = n
```
In `registerTyCons`, build `let ks = map paramKind params; k = foldr KArrow KStar ks; info = TyConInfo k (length params) [] carrier ks`. In `registerCon`, the constructor quantifiers must use these kinds: replace `quantifiers = [ (i, KStar) | i <- [0 .. paramCount-1] ]` (and the record-con `quantifiers` at ~908) with `quantifiers = zip [0 ..] ks` where `ks` are the tycon's per-param kinds (thread `ks`/`tcParamKinds` into `registerCon`). The `paramMap`/`paramNames` extraction uses `tyParamName`.

- [ ] **Step 3: Elaborate a `(row e)` argument to a `KEffect` variable**

The new `Abs` `Type2` constructor (BNFC-named from `TRowArg`, e.g. `Abs.TRowArg (Abs.VarId (_, e))`) must be handled in BOTH type translators:
- `goT` (signatures, `Infer.hs` ~513): add a case that allocates a `KEffect` slot for `e` and returns its `CTGen`. Mirror exactly how an effect-row variable (`eff e`, `Abs.ERVarOnly`) allocates a `KEffect` quantifier — find that path (search `ERVarOnly`/the effect-row translation) and reuse its slot allocator so `(row e)` and `eff e` for the same name share a slot. The key difference from `goT (Abs.TVar …)` (which allocs a `KStar` slot) is the kind is `KEffect`.
- `translateConArg`/`walkArg` (constructor fields, `Infer.hs` ~936): add a `walkArg (Abs.TRowArg (Abs.VarId (_, e)))` case. Inside a `data` decl, `e` should resolve to the declared row PARAM via `paramMap` (it is a `KEffect` `CTGen` for that param index); thread the param's kind so the resulting `CTGen` is the param's slot. (If `e` is not a declared param, it is a fresh `KEffect` var — but for Slice B fixtures it is always a param.)

Confirm both translators agree the result is a `KEffect`-kinded `CTGen` referencing the right slot.

- [ ] **Step 4: Positive fixtures**

Create `test/typecheck-examples/row-param-box.wok`:
```wok
module Main
import Std.Base

-- A row-kinded parameter `e` (kind Row), threaded as a type argument.
data Box (row e) = Box U64
data Pair (row e) = Pair (Box (row e))   -- (row e) as a constructor-field tycon argument

peek : Box (row e) -> U64
peek (Box n) = n

main : U64
main = peek (Box 5)
```
Create `test/run-examples/row-param-box.wok` with the same content (for the run golden).

- [ ] **Step 5: Type-check + run**
```bash
cabal run -v0 wok -- test/typecheck-examples/row-param-box.wok 2>&1 | tail -6
cabal run -v0 wok -- test/run-examples/row-param-box.wok --run
```
Expected: type-checks; the inferred schemes show `Box` applied to a row var (e.g. `peek : forall a. Box a -> U64` with `a` a row gen); `--run` prints `5`. If `(row e)` doesn't resolve (UnknownTyCon / a `KStar` slot), revisit Step 3's slot allocation.

- [ ] **Step 6: Generate goldens; confirm no pre-existing golden churn**
```bash
cabal test --test-options=--accept 2>&1 | grep -i "row-param-box"
git status --short test/ | grep -v "row-param-box" || echo "(only row-param-box goldens added)"
cabal test 2>&1 | grep -iE "All [0-9]+ tests"
```
Expected: new goldens for `row-param-box` (typecheck/anf/typed-anf in `typecheck-examples`, plus run-golden); no pre-existing golden changed; suite green.

- [ ] **Step 7: Commit**
```bash
git add src/Wok/TypeChecking/Env.hs src/Wok/TypeChecking/Builtins.hs src/Wok/TypeChecking/Infer.hs test/Spec.hs test/typecheck-examples/row-param-box.wok test/run-examples/row-param-box.wok test/typecheck-golden/row-param-box.expected test/anf-golden/row-param-box.expected test/typed-anf-golden/row-param-box.expected test/run-golden/row-param-box.expected
git commit -m "feat(tc): row-kinded tycon parameters + (row e) argument elaboration (slice B)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 3: Kind-check tycon applications + contextual error + prettyCType hardening (negatives)

**Goal:** Reject ill-kinded applications (a `*` arg in a row slot, or a row arg in a `*` slot) with a clear, contextual error; harden `prettyCType`'s row arms; prove the negatives and the gate.

**Files:**
- Modify: `src/Wok/TypeChecking/Error.hs` (contextual kind error)
- Modify: `src/Wok/TypeChecking/Infer.hs` (kind-check at the 4 application sites; `prettyCType` row arms)
- Create: `test/typecheck-fail-examples/{row-arg-in-star-slot,star-arg-in-row-slot,extern-row-param-user-forbidden}.wok` + goldens
- Modify: `test/Spec.hs` (a kind-check unit anchor)

**Acceptance Criteria:**
- [ ] A contextual kind error (tycon name + parameter index + expected/actual kind) renders clearly.
- [ ] `Option (row e)` (row in a `*` slot) and `Box U64` (`*` in a row slot) → that error.
- [ ] A `UserFile` `extern type T (row e)` → `ExternNotAllowed` (existing gate, reconfirmed).
- [ ] `prettyCType` row arms hardened (no silent empty-string for a row reaching a type printer).
- [ ] Full suite green; no pre-existing golden changed.

**Verify:** `cabal test 2>&1 | grep -iE "row-arg-in-star-slot|star-arg-in-row-slot|All [0-9]+ tests"`

**Steps:**

- [ ] **Step 1: Contextual kind error**

In `src/Wok/TypeChecking/Error.hs`, add (importing `Kind` from `Types`):
```haskell
  | TyConArgKind SourceSpan Text Int Kind Kind
    -- ^ Tycon application kind error: <tycon> parameter #<i> (0-based) expects
    -- kind <expected>, but the argument has kind <actual>. (slice B; the
    -- application-level analogue of the unification-level KindMismatch.)
```
(Keep Slice A's `KindMismatch` for the unification path.) Add an arm to any exhaustive `TypeError` `case`/renderer if present (Slice A found none for `KindMismatch`; the derived `Show` renders it).

- [ ] **Step 2: Kind-check the application sites**

Each argument's surface kind is syntax-directed: a `(row e)` argument (`Abs.TRowArg`) is `KEffect`; every other surface type argument is `KStar`. Write a helper:
```haskell
argKind :: Abs.Type -> Kind
argKind (Abs.TRowArg _) = KEffect
argKind _               = KStar
```
At the two **signature** application sites (`goT`, `Infer.hs:542` nullary and `:559` applied) and the two **constructor-field** sites (`walkArg`, `Infer.hs:947` nullary and `:958` applied), after the arity check, verify each argument's kind against the tycon's `tcParamKinds`:
```haskell
  | tcArity info == length args -> do
      sequence_ [ when (argKind a /= pk) $
                    throwError (TyConArgKind (Just pos) name i pk (argKind a))
                | (i, a, pk) <- zip3 [0 ..] args (tcParamKinds info) ]
      CTCon (resolveTyCon name) <$> mapM goT args   -- (walkArg uses walkArg)
```
(For the nullary `tcArity info == 0` sites, there are no args to check; no change beyond consistency.) This catches: a `(row e)` in a `KStar` slot, and a `*` type in a `KEffect` slot. (A `(row e)` argument in a `*` slot means `argKind = KEffect /= KStar = pk` → error; a normal type in a row slot means `argKind = KStar /= KEffect` → error.)

- [ ] **Step 3: `prettyCType` row-arm hardening (defensive)**

In `Infer.hs:prettyCType`, the row-node arms (`CREmpty`/`CRExtend`) currently delegate to `prettyCRow` (empty string / comma list) — fine for a row in arrow position, misleading for a row reaching `prettyCType` as a standalone type. Slice B's row args are row *variables* (`CTGen`, which print as a var name), so a concrete row node should not reach `prettyCType` as a top-level type; make that explicit:
```haskell
prettyCType CREmpty        = Tx.pack "{}"
prettyCType (CRExtend l _ rest) = Tx.concat [Tx.pack "{", l, Tx.pack " | ", prettyCType rest, Tx.pack "}"]
```
(Render a row argument readably rather than as `""`/`"x,y,"`. Keep `prettyCRow` unchanged for the arrow `with`-clause path.) Confirm no golden changes (rows still don't reach this path in the fixtures; the change only affects the would-be-misleading output).

- [ ] **Step 4: Negative fixtures**

`test/typecheck-fail-examples/star-arg-in-row-slot.wok`:
```wok
module Main
import Std.Base

data Box (row e) = Box U64

bad : Box U64        -- U64 (kind *) in Box's row parameter slot
bad = Box 0

main : U64
main = 0
```
`test/typecheck-fail-examples/row-arg-in-star-slot.wok`:
```wok
module Main
import Std.Base

bad : Option (row e)   -- a row argument in Option's `*` parameter slot

main : U64
main = 0
```
`test/typecheck-fail-examples/extern-row-param-user-forbidden.wok`:
```wok
module Main

extern type T (row e)   -- extern in a UserFile -> ExternNotAllowed (existing gate)

main : U64
main = 0
```

- [ ] **Step 5: Generate + verify the negative goldens**
```bash
cabal test --test-options=--accept 2>&1 | grep -iE "star-arg-in-row-slot|row-arg-in-star-slot|extern-row-param-user-forbidden"
for f in star-arg-in-row-slot row-arg-in-star-slot extern-row-param-user-forbidden; do echo "--- $f"; cat test/typecheck-fail-golden/$f.expected; done
```
Expected: the first two render `TyConArgKind …` (naming the tycon + parameter + kinds); the third renders `ExternNotAllowed …`. Confirm the `Box U64` message clearly names the row parameter (not "boxing forbidden").

- [ ] **Step 6: Kind-check unit anchor**

In `test/Spec.hs`, add a small test (near `dataTests`) asserting `processDataDecls` records `tcParamKinds` correctly for `data Box (row e) = Box U64` (e → `KEffect`) and `data Plain a = Plain a` (a → `KStar`). Reuse the existing `dataTests` harness (`I.processDataDecls B.initialEnv [...]` + `TE.lookupTyCon`):
```haskell
    , testCase "tcParamKinds records (row e) as KEffect, bare as KStar" $ do
        env <- <dataTests harness for>
                 [ "data Box (row e) = Box U64", "data Plain a = Plain a" ]
        case TE.lookupTyCon (T.pack "Box") env of
          Just i  -> TE.tcParamKinds i @?= [Ty.KEffect]
          Nothing -> assertFailure "Box not registered"
        case TE.lookupTyCon (T.pack "Plain") env of
          Just i  -> TE.tcParamKinds i @?= [Ty.KStar]
          Nothing -> assertFailure "Plain not registered"
```
(Match the existing `dataTests` construction exactly; it parses+registers a module.)

- [ ] **Step 7: Full suite + regression**
```bash
cabal test 2>&1 | grep -iE "All [0-9]+ tests"
git diff --stat -- 'test/*-golden/' | grep -i golden | grep -vE "row-param-box|41-row-kinded|star-arg|row-arg|extern-row" && echo "!!! unexpected golden churn" || echo "only new fixtures' goldens"
for f in coro-escape coro-step-range coro-step-zip coro-multi-driver; do printf "%s=" "$f"; cabal run -v0 wok -- test/run-examples/$f.wok --run; done
```
Expected: all green; only the new fixtures' goldens added; coro `421/10/52/64`.

- [ ] **Step 8: Commit**
```bash
git add src/Wok/TypeChecking/Error.hs src/Wok/TypeChecking/Infer.hs test/Spec.hs test/typecheck-fail-examples/ test/typecheck-fail-golden/
git commit -m "feat(tc): kind-check tycon applications (row/* slots) + harden prettyCType (slice B)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 4: Full-branch review and finish

**Goal:** The standing-rule full-branch review before merge to `main`.

**Files:** none.

**Acceptance Criteria:**
- [ ] Full-branch review `main..HEAD` completed and triaged.
- [ ] Build + test green; no pre-existing golden changed; coro `421/10/52/64`.
- [ ] Decidability contract held (variable kinds `{KStar, KEffect}`; no `KArrow`-kinded variable; kind-check syntax-directed).
- [ ] Integration decision made with the user (confirm in prose).

**Verify:** review report; `cabal test` green.

**Steps:**

- [ ] **Step 1: Snapshot**
```bash
cabal build 2>&1 | tail -3
cabal test 2>&1 | grep -iE "All [0-9]+ tests"
git diff --stat main -- 'test/*-golden/' | grep -i golden | grep -vE "row-param-box|41-row-kinded|star-arg|row-arg|extern-row" || echo "no pre-existing golden changed"
git log --oneline main..HEAD | cat
```

- [ ] **Step 2: Full-branch review**

Invoke `superpowers-extended-cc:requesting-code-review` over `main..HEAD`. The review must check: the grammar change added no new conflicts (still 31); `tcParamKinds` is correct and consulted at all four application sites; a `(row e)` argument elaborates to a `KEffect` variable and resolves to the bound param in a decl; the kind-check rejects both slot-mismatch directions with a contextual error; the decidability contract holds (no `KArrow`-kinded variables introduced; kind-check is syntax-directed, not inference); effect-carrying arrow fields are NOT supported (correctly out of scope); no pre-existing golden churn; coro regression intact.

- [ ] **Step 3: Triage** with `superpowers-extended-cc:receiving-code-review`; fix as small commits; re-run `cabal test` after each.

- [ ] **Step 4: Finish** with `superpowers-extended-cc:finishing-a-development-branch`; confirm with the user in prose before merging to `main`.

---

## Self-review (author's pass against the spec)

- **Spec §4 surface (`(row e)` decl + use):** Task 1 (grammar) + Task 2 (elaboration). ✔
- **Spec §5 grammar (TyParam + Type2, BNFC + 3 patches + conflict):** Task 1. ✔
- **Spec §6 elaboration (per-param kinds + constructor quantifiers + `(row e)` arg → KEffect resolving to the param):** Task 2 (note the `registerCon` all-`KStar` quantifier fix at Infer.hs:874/908). ✔
- **Spec §7 kind-check (4 sites, contextual error, decidable/syntax-directed):** Task 3. ✔
- **Spec §8 prettyCType hardening (defensive):** Task 3 Step 3. ✔
- **Spec §9 gating (extern row param Embedded-only):** Task 3 negative fixture (reuses existing gate). ✔
- **Spec §10 testing (positive runnable; negatives lead with `Option (row e)`; gate; unit anchor; regression):** Tasks 2-3. ✔
- **Spec §12 OUT (effect-carrying arrow fields; concrete-row args; Suspension; kind poly; same-name ban):** none introduced; effect-carrying arrow fields explicitly avoided (the positive proof uses a tycon-arg field, not a `with`-field). ✔
- **Decidability contract:** only `KStar`/`KEffect` argument kinds; the kind-check compares declared param kinds to syntax-directed arg kinds — no new variable kinds, no inference. ✔
- **Type consistency:** `tcParamKinds :: [Kind]` (Task 2) is read by the kind-check (Task 3); `TyConArgKind` (Task 3) used only at the application sites; `paramKind`/`tyParamName`/`argKind` helpers named consistently across tasks. ✔
