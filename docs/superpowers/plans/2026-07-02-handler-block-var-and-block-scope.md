# Handler-block `var` + block-scope Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers-extended-cc:subagent-driven-development (recommended) or superpowers-extended-cc:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Reshape the effect-handler block so its state cell is a `var` member and arm bodies can span multiple lines, with identical semantics.

**Architecture:** Two coupled surface changes: (1) a new `HParamV. HandlerArm ::= "var" VarId "=" Exp` grammar production (`var` a global reserved word) that supersedes the bare `HParam`; (2) a column-aware separator suppression in the hand-rolled `RecordLayout.hs` token pre-pass, gated to handler braces. No IR/runtime/type-story change.

**Tech Stack:** Haskell (GHC 9.10), BNFC grammar (`grammar/Wok.cf` → `src-generated/`), the wok interpreter + differential RC backend, tasty/Hspec test suite.

**Spec:** `docs/superpowers/specs/2026-07-02-handler-block-var-and-block-scope-design.md`

**User decisions (already made):**
- "Option A" — require `var`; reject bare `s = i` with a hint (single clean surface).
- `var` is a global reserved word (contextual keyword dropped — the lexer reserves terminals globally, like `as`/`with`; no `.wok` uses `var`).
- Keep the two-argument resume `k x ()`; `s := x` assignment is a deferred fast-follow.
- Single baton only; multiple batons stay a `DuplicateHandlerParam`. Layout fix is handler-brace-only.
- Execute autonomously, all subagents on `sonnet`.

---

### Task 1: Grammar `HParamV` + regen + accept both forms

**Goal:** Add the `var s = i` handler-arm syntax and make the compiler accept it (alongside the still-parsing bare form) with identical elaboration.

**Files:**
- Modify: `grammar/Wok.cf` (after `HParam` at ~`:462`)
- Regenerate: `src-generated/GeneratedParser/Wok/**` (via bnfc)
- Modify: `src/Wok/TypeChecking/Infer.hs` (`classifyArm` ~`:2461`)
- Modify: `src/Wok/TypeChecking/Class.hs` (`goArm` ~`:562-564`)

**Acceptance Criteria:**
- [ ] `cabal build` succeeds.
- [ ] A `.wok` handler using `var s = i` parses, typechecks, and runs correctly.
- [ ] The bare `s = i` form still parses and runs (temporary — rejected in Task 5).
- [ ] The two documented post-regen hand patches (`Layout.hs`, `Par.y`) are re-applied.

**Verify:** `cabal build 2>&1 | tail -5` → no errors; then run the two `.wok` probes below → both print `(42, 42)`.

**Steps:**

- [ ] **Step 1: Add the grammar production.** In `grammar/Wok.cf`, immediately after the `HParam.` line (~`:462`), add:

```
HParamV. HandlerArm ::= "var" VarId "=" Exp ;   -- accepted handler-local state; slice handler-block-var
```
Keep `HParam.` (bare form) — it stays parseable so Task 5 can reject it with a good message.

- [ ] **Step 2: Regenerate the parser.** Run:

```bash
bnfc --haskell -d -p GeneratedParser --text-token -o src-generated grammar/Wok.cf
```

- [ ] **Step 3: Re-apply the two post-regen hand patches.** `grammar/Wok.cf:5-35` documents them: (a) the `Layout.hs` `maybeInsertSeparator` fix for paren-opening top-level decls, and (b) the `Par.y` LALR fix routing `PRecord`/`PRecordOpen` through the empty-record rule. `bnfc` overwrote both; restore them (diff the regenerated `src-generated/GeneratedParser/Wok/Layout.hs` and `Par.y` against `git show HEAD:` versions and re-apply the wok-specific edits). Confirm with `git diff --stat src-generated` that only intended files changed.

- [ ] **Step 4: Route `HParamV` in `classifyArm`.** In `src/Wok/TypeChecking/Infer.hs`, next to the existing `Abs.HParam` case (~`:2461`), add:

```haskell
  Abs.HParamV (Abs.VarId (pos, name)) initExp ->
    pure (ParamArmC name initExp pos)
```
Leave the `Abs.HParam` case returning `ParamArmC` for now (both accepted).

- [ ] **Step 5: Handle `HParamV` in `Class.hs` `goArm`.** In `src/Wok/TypeChecking/Class.hs` (~`:562-564`), add a case so the exhaustiveness check passes:

```haskell
    goArm (Abs.HParamV v a) = Abs.HParamV v (go a)
```

- [ ] **Step 6: Build and probe.** Run `cabal build`. Then write `/tmp` probes (one `var s = i`, one bare `s = i`, both `state`/`get`/`set` returning `(a, s)`, driven by `with count = state 0 in let a = count.set 42 in count.get`) and run each with the built `wok --run` (set `wok_datadir` to the repo root). Both must print `(42, 42)`.

- [ ] **Step 7: Commit.**

```bash
git add grammar/Wok.cf src-generated src/Wok/TypeChecking/Infer.hs src/Wok/TypeChecking/Class.hs
git commit -m "feat(handler): accept 'var name = init' handler-state syntax (bare form still parses)"
```

---

### Task 2: Column-aware block-scope for arm bodies

**Goal:** Let a single handler arm's body span multiple lines by suppressing the virtual separator on deeper-indented continuation lines (handler braces only).

**Files:**
- Modify: `src/Wok/RecordLayout.hs` (`tokenLine` ~`:40`, `BlockBrace` ~`:156-161`, insertion branch ~`:205-244`)

**Acceptance Criteria:**
- [ ] A handler arm whose body spans lines (e.g. `set x k -> <nl indented> let y = x in <nl> k y ()`) parses, typechecks, runs correctly.
- [ ] Existing newline-separated single-line arms still parse (no regression).
- [ ] Record literals are unaffected (`bcIsHandler`-gated).

**Verify:** build, then run the multi-line-body probe → prints `(42, 42)`; then `cabal test` → the existing `preludeTests` / handler examples stay green.

**Steps:**

- [ ] **Step 1: Add `tokenCol`.** Next to `tokenLine` in `src/Wok/RecordLayout.hs`:

```haskell
tokenCol :: Token -> Int
tokenCol t = case tokenPosn t of Pn _ _ c -> c
```

- [ ] **Step 2: Add a reference column to `BlockBrace`.** Extend the `BlockBrace` constructor with an `Int` reference-column field (the arm-start column), set it to `tokenCol` of the first token after `{` at the site where `BlockBrace … isHandler` is currently constructed (~`:208`). Thread it through the two other `BlockBrace …` re-constructions (~`:238`, `:244`) unchanged.

- [ ] **Step 3: Gate separator insertion on column for handler braces.** In the insertion branch (~`:220-244`), where the guard is `curLine > lastLine && lastLine > openLine`, add: when `bcIsHandler` is `True`, insert the separator only if `tokenCol t <= refCol`; if `curLine > lastLine` but `tokenCol t > refCol`, treat it as a body continuation — do NOT insert, but still advance `lastLine`. Non-handler braces keep the current line-only behavior.

- [ ] **Step 4: Build and probe.** `cabal build`, then run the multi-line-body `.wok` (a `set` arm whose body is `let y = x in <newline> k y ()`, indented deeper than the arm). It must parse and print `(42, 42)`.

- [ ] **Step 5: Regression.** `cabal test 2>&1 | tail -20` — the suite must stay green (no new failures vs. the Task 1 baseline).

- [ ] **Step 6: Commit.**

```bash
git add src/Wok/RecordLayout.hs
git commit -m "feat(layout): column-aware block scope for multi-line handler arm bodies"
```

---

### Task 3: Migrate prelude + tests to `var`

**Goal:** Rewrite every stateful handler's bare baton `name = init` to `var name = init`, so nothing depends on the bare form before Task 5 rejects it.

**Files:**
- Modify: `prelude/Std/Control.wok` (`state`, `writer`)
- Modify: ~24 `test/**/*.wok` fixtures defining an inline `State`/`Writer`-style handler (incl. `test/typecheck-fail-examples/44-state-swapped-resume.wok`)

**Acceptance Criteria:**
- [ ] No `.wok` file under `prelude/` or `test/` contains a bare handler baton (`{ name = init` or `; name = init` inside a handler ConId-brace) — all use `var`.
- [ ] `cabal test` stays green.

**Verify:** `grep -rnE '\{ *[a-z_]+ = |; *[a-z_]+ = [^-]' prelude/ test/ --include='*.wok'` shows only `var …`-prefixed hits (or record literals, not handlers); `cabal test 2>&1 | tail -20` green.

**Steps:**

- [ ] **Step 1: Enumerate.** `grep -rlnE '(State|Writer) \{|with self = ' prelude/ test/ --include='*.wok'` and inspect each for a bare baton arm.

- [ ] **Step 2: Rewrite each baton.** In each, change the baton arm `s = i` (or `log = []`, etc.) to `var s = i`. Example, `prelude/Std/Control.wok`:

```
state i c = with self = State { var s = i ; get -> s ; set x k -> k x () ; v -> (v, s) } in c self
writer c  = with self = Writer { var log = [] ; tell w k -> k (log ++ w) () ; v -> (v, log) } in c self
```
Do NOT touch stateless handlers (`reader`, `except`) or record literals.

- [ ] **Step 3: Verify no bare batons remain.** Run the Verify grep above; every handler baton is now `var`.

- [ ] **Step 4: Full suite.** `cabal test 2>&1 | tail -20` — green.

- [ ] **Step 5: Commit.**

```bash
git add prelude test
git commit -m "refactor(handler): migrate all stateful handlers to 'var' baton syntax"
```

---

### Task 4: Positive tests for the new surface

**Goal:** Lock the new capabilities with fixtures: a multi-line arm body, a nested handler with a multi-line body, one example per handler form, and the single-baton guard.

**Files:**
- Create: `test/run-examples/handler-multiline-body.wok`
- Create: `test/run-examples/handler-multiline-nested.wok`
- Modify: the test harness list if fixtures are enumerated explicitly (check `test/Spec.hs` for how `run-examples` are discovered)

**Acceptance Criteria:**
- [ ] A fixture with a multi-line arm body runs on both backends with the expected result.
- [ ] A nested-handler fixture with a multi-line body runs correctly.
- [ ] The `DuplicateHandlerParam` guard still fires for two `var` batons (extend/confirm `test/typecheck-fail-examples/49-duplicate-handler-param.wok` to use `var`).
- [ ] `cabal test` green.

**Verify:** `cabal test 2>&1 | tail -20` — new fixtures pass, whole suite green.

**Steps:**

- [ ] **Step 1: Multi-line body fixture.** Create `test/run-examples/handler-multiline-body.wok` with a `state` handler whose `set` arm body is a multi-line `let … in k y ()`, exercised to a known result. Match the golden/discovery mechanism the other `run-examples` use (check a sibling fixture + `test/Spec.hs`).

- [ ] **Step 2: Nested fixture.** Create `test/run-examples/handler-multiline-nested.wok` — a `state` handler inside a `writer` handler (or vice-versa), at least one arm body multi-line.

- [ ] **Step 3: Single-baton negative.** Ensure `test/typecheck-fail-examples/49-duplicate-handler-param.wok` uses `var s = … ; var t = …` and still expects `DuplicateHandlerParam`.

- [ ] **Step 4: Wire + run.** If `test/Spec.hs` enumerates fixtures explicitly, add the two new ones; else confirm auto-discovery. `cabal test` green.

- [ ] **Step 5: Commit.**

```bash
git add test
git commit -m "test(handler): multi-line arm body, nested, single-baton fixtures"
```

---

### Task 5: Reject the bare baton with a hint

**Goal:** Make bare `s = i` a positioned elaboration error directing the user to `var`, and pin it with a negative fixture; final full-suite + differential-oracle green.

**Files:**
- Modify: `src/Wok/TypeChecking/Error.hs` (add `BareHandlerParam`, near `DuplicateHandlerParam` ~`:122`)
- Modify: `src/Wok/TypeChecking/Infer.hs` (`classifyArm` `Abs.HParam` case)
- Create: `test/typecheck-fail-examples/handler-bare-param.wok` (+ its expected-error wiring)

**Acceptance Criteria:**
- [ ] Bare `s = i` in a handler yields `BareHandlerParam` with a message naming `var` and the binder.
- [ ] The new negative fixture is asserted by the suite.
- [ ] `cabal test` green AND the differential RC oracle shows identical cross-backend results (semantics unchanged).

**Verify:** run the bare probe with `wok --run` → the `var` hint error; `cabal test 2>&1 | tail -20` green.

**Steps:**

- [ ] **Step 1: Add the error.** In `src/Wok/TypeChecking/Error.hs`, add a constructor mirroring `DuplicateHandlerParam`'s shape plus the name:

```haskell
  | BareHandlerParam SourceSpan Text
```
and a render arm: `"handler-local state must be declared with 'var' — did you mean 'var " <> name <> " = ...'?"` (follow the module's existing pretty-printer style).

- [ ] **Step 2: Reject bare in `classifyArm`.** Change the `Abs.HParam` case in `src/Wok/TypeChecking/Infer.hs` from `pure (ParamArmC …)` to:

```haskell
  Abs.HParam (Abs.VarId (pos, name)) _ ->
    throwError (BareHandlerParam (Just pos) name)
```

- [ ] **Step 3: Negative fixture.** Create `test/typecheck-fail-examples/handler-bare-param.wok` (a handler with a bare `s = i`) and wire its expected `BareHandlerParam` failure the way the other `typecheck-fail-examples` are asserted in `test/Spec.hs`.

- [ ] **Step 4: Full suite + oracle.** `cabal test 2>&1 | tail -30` — green, including the differential RC-stats oracle (`--dump-rc-stats` cross-backend equality) which proves the migration changed no runtime behavior.

- [ ] **Step 5: Commit.**

```bash
git add src/Wok/TypeChecking/Error.hs src/Wok/TypeChecking/Infer.hs test
git commit -m "feat(handler): reject bare handler baton with a 'var' hint"
```

---

## Self-review

- **Spec coverage:** §3.1 `var` → Tasks 1,5; §3.2 layout → Task 2; §5.5 migration → Task 3; §6 tests → Tasks 4,5; regen + hand patches → Task 1 Step 3. All covered.
- **Placeholder scan:** no TBD/TODO; code shown for each code step.
- **Type consistency:** `ParamArmC`, `BareHandlerParam`, `HParamV`, `tokenCol`, `bcIsHandler` used consistently across tasks.
- **Green-at-each-checkpoint:** Task 1 accepts both forms; migration (3) precedes rejection (5), so the suite never breaks mid-plan.
