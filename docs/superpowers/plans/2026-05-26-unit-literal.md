# Unit Literal `()` Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers-extended-cc:subagent-driven-development (recommended) or superpowers-extended-cc:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add surface syntax `()` (with arbitrary whitespace between the parens permitted) as a value, type, and pattern, so the existing `TcUnit` tycon becomes reachable.

**Architecture:** Three new BNFC productions (`EUnit`, `TUnit`, `PUnit`) in `grammar/Wok.cf`, each of the form `"(" ")"` — two separate tokens so BNFC's default whitespace-as-separator behavior accepts `( )`. After regenerating the parser, three new case branches in `src/Wok/TypeChecking/Infer.hs` translate each to `CTCon TcUnit []`. No new constructor name; no `Unit` alias.

**Tech Stack:** Haskell, cabal, BNFC + alex + happy, tasty + tasty-golden + tasty-hunit.

**Spec:** `docs/superpowers/specs/2026-05-26-unit-literal-design.md`

---

### Task 1: Grammar productions + BNFC regen + parse golden tests

**Goal:** Three new BNFC productions (`EUnit`, `TUnit`, `PUnit`), regenerated parser, and parse-golden coverage proving `()`, `( )`, and `(   )` all parse to the same AST.

**Files:**
- Modify: `grammar/Wok.cf` — add three productions
- Regenerated (do not hand-edit): `src-generated/GeneratedParser/Wok/Abs.hs`, `Lex.x`, `Par.y`, `Print.hs`, `Layout.hs`, plus generated `.hs` from alex/happy
- Create: `test/examples/11-unit.wok` — parse-test source exercising every unit position
- Create: `test/golden/11-unit.expected` — expected printed AST (capture via golden file generation)

**Acceptance Criteria:**
- [ ] `grammar/Wok.cf` contains `EUnit`, `TUnit`, `PUnit` productions, each `"(" ")"`.
- [ ] `bnfc --haskell -d --text-token -o src-generated grammar/Wok.cf` runs without conflicts (no shift-reduce, no reduce-reduce).
- [ ] `cabal build` succeeds after BNFC regen.
- [ ] `GeneratedParser.Wok.Abs.AtomPat` includes `PUnit` constructor (no fields).
- [ ] `GeneratedParser.Wok.Abs.Type` includes `TUnit` constructor.
- [ ] `GeneratedParser.Wok.Abs.Exp` includes `EUnit` constructor.
- [ ] Parsing `u = ()`, `u = ( )`, and `u = (   )` all succeed and produce identical printed-AST output.
- [ ] All existing parse-golden tests continue to pass (no regressions in `test/examples/01-*`..`10-*`).

**Verify:** `cabal test --test-options="-p parse" 2>&1 | tail -20` shows the parse-golden group passing with the new `11-unit` test included.

**Steps:**

- [ ] **Step 1: Add the three productions to the BNFC grammar**

Open `grammar/Wok.cf`. The relevant context for `Exp2`, `Type2`, and `AtomPat` is around lines 95-188 in the existing file (the comment "Patterns (full version: ...)" lives near line 75 and "Types (Task 8: full type expressions)" near line 108).

After the existing `APParen.  AtomPat ::= "(" Pat ")" ;` line (~line 103), add:

```bnfc
PUnit.    AtomPat ::= "(" ")" ;          -- unit pattern; whitespace permitted: ( ), (   )
```

After the existing `TParen.   Type2 ::= "(" Type ")" ;` line (~line 130), add:

```bnfc
TUnit.    Type2 ::= "(" ")" ;            -- unit type; whitespace permitted
```

After the existing `EParen.   Exp2 ::= "(" Exp ")" ;` line (~line 179), add:

```bnfc
EUnit.    Exp2 ::= "(" ")" ;             -- unit value; whitespace permitted
```

Two-token form is intentional. A single lexer token `"()"` would forbid whitespace between the parens; the two-token form lets BNFC's standard whitespace-as-token-separator behavior accept `( )` and `(   )` automatically without any lexer special-case.

LALR(1) safety: the lookahead `)` immediately after `(` is what distinguishes these from `EParen`/`TParen`/`APParen` (which require an `Exp`/`Type`/`Pat` token next) and from `ETuple`/`TTuple`/`APTuple` (which require an `Exp`/`Type`/`Pat` followed by `,`).

- [ ] **Step 2: Regenerate parser**

Run from project root:

```bash
bnfc --haskell -d --text-token -o src-generated grammar/Wok.cf
```

This must complete with no conflicts. If you see any "shift/reduce" or "reduce/reduce" lines, stop — the grammar change was incorrect.

- [ ] **Step 3: Verify build**

```bash
cabal build 2>&1 | tail -5
```

Expected: build succeeds. The generated `Abs.hs` now has `PUnit`, `TUnit`, `EUnit` constructors. The hand-written modules (`Wok.Parsing`, `Wok.Reordering`, `Wok.TypeChecking.*`) do NOT yet handle the new constructors, but Haskell only warns about non-exhaustive patterns in our pure-function `case`s — it does not fail the build under `-Wall` unless those warnings become errors. (If they do, that's caught and fixed in Task 2.)

If non-exhaustive-pattern warnings appear for `Wok.Reordering.reorderExp`, `inferAtomPat`, `inferExprW`, or the type-translation walker, that is expected — Task 2 adds those branches.

- [ ] **Step 4: Write the parse-test source fixture**

Create `test/examples/11-unit.wok`:

```wok
-- Unit literal coverage: value, type, pattern, and whitespace variants.

-- Bare unit value
u : ()
u = ()

-- Unit value with whitespace inside the parens
u2 : ()
u2 = ( )

-- Unit value with extra whitespace
u3 : ()
u3 = (   )

-- Unit in a tuple position (sanity: doesn't collide with ETuple)
pairUU : ((), ())
pairUU = ((), ())

-- Unit as a pattern
discard : () -> Int
discard () = 0

-- Unit as a function argument type only
returnsZero : () -> Int
returnsZero u = 0
```

- [ ] **Step 5: Capture the parse-golden expected output**

The test harness rewrites each `.wok` to its printed AST. To capture the golden:

```bash
cabal test wok-tests --test-options="-p parse.*11-unit --accept" 2>&1 | tail -10
```

If `--accept` isn't supported by the local tasty-golden version, run the test once to get the "actual" output, write it manually to `test/golden/11-unit.expected`, then re-run. Inspect the result with:

```bash
cat test/golden/11-unit.expected
```

The expected file should contain the printed forms (one printed-AST snippet, no error markers). Confirm `()`, `( )`, and `(   )` all collapse to the same printed form (BNFC printing is whitespace-canonical).

- [ ] **Step 6: Run the full parse-golden suite to confirm no regressions**

```bash
cabal test wok-tests --test-options="-p parse" 2>&1 | tail -10
```

Expected: all parse-golden tests pass, including the new `11-unit`.

- [ ] **Step 7: Commit**

```bash
git add grammar/Wok.cf src-generated/GeneratedParser/Wok/ test/examples/11-unit.wok test/golden/11-unit.expected
git commit -m "$(cat <<'EOF'
feat(grammar): add unit literal `()` productions (whitespace-permissive)

Three new BNFC productions (EUnit/TUnit/PUnit) of the form `"(" ")"`,
making the existing TcUnit tycon reachable from surface syntax. The
two-token form means `( )` and `(   )` are accepted alongside `()`,
matching ML-family convention.

Typechecker integration follows in the next commit.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: Typechecker case branches + typecheck golden tests

**Goal:** Hook the three new AST constructors into `Wok.TypeChecking.Infer` so `()` typechecks as `()`, then add golden tests covering every position (value, type, pattern, tuple) and the whitespace variants.

**Files:**
- Modify: `src/Wok/TypeChecking/Infer.hs` — add three case branches and one `translateType` case
- Modify: `src/Wok/Reordering.hs` — add identity case for `EUnit` in `reorderExp` (if GHC warns)
- Create: `test/typecheck-examples/11-unit.wok` — typecheck-success fixture
- Create: `test/typecheck-golden/11-unit.expected` — expected typed-decl output
- Create: `test/typecheck-fail-examples/09-unit-mismatch.wok` — typecheck-fail fixture (sanity: unit doesn't unify with Int)
- Create: `test/typecheck-fail-golden/09-unit-mismatch.expected` — expected error

**Acceptance Criteria:**
- [ ] `inferAtomPat (Abs.PUnit) = pure (TCon TcUnit [], [])` in `Infer.hs`.
- [ ] `inferExprW _ (Abs.EUnit) = pure (TCon TcUnit [])` in `Infer.hs`.
- [ ] Type translation handles `Abs.TUnit` returning `CTCon TcUnit []`.
- [ ] `Wok.Reordering.reorderExp` covers `EUnit` (passthrough — no infix chain inside).
- [ ] `test/typecheck-examples/11-unit.wok` typechecks; golden matches.
- [ ] `test/typecheck-fail-examples/09-unit-mismatch.wok` produces a `Mismatch` error; golden matches.
- [ ] `cabal build` succeeds with no non-exhaustive-pattern warnings introduced by the new AST constructors.
- [ ] All existing tests still pass.

**Verify:** `cabal test 2>&1 | tail -20` shows zero failures.

**Steps:**

- [ ] **Step 1: Write the typecheck success fixture FIRST (red test)**

Create `test/typecheck-examples/11-unit.wok`:

```wok
unit : ()
unit = ()

unitWs : ()
unitWs = ( )

discard : () -> Int
discard () = 0

pairUU : ((), ())
pairUU = ((), ())
```

Note: `Int` is still the integer-literal type at the time this plan runs (pre-Std.Base spec). After the Std.Base plan lands, this fixture becomes `u64` instead — that change is part of the Std.Base migration, not this plan.

- [ ] **Step 2: Write the expected golden output**

Create `test/typecheck-golden/11-unit.expected`:

```
discard : () -> Int
pairUU : ((), ())
unit : ()
unitWs : ()
```

(Names are sorted alphabetically per the harness's `sortBy (comparing TC.tdName)`.)

- [ ] **Step 3: Run the typecheck-golden test to confirm it fails**

```bash
cabal test wok-tests --test-options="-p 11-unit" 2>&1 | tail -10
```

Expected: failure. The failure message will likely be "non-exhaustive patterns" inside `inferAtomPat` / `inferExprW` / the type-translation walker, OR a build error if `-Wall` was strict. This confirms the typechecker doesn't yet handle the new constructors.

- [ ] **Step 4: Add the typechecker case branches**

Open `src/Wok/TypeChecking/Infer.hs`.

**(a) Pattern case** — find `inferAtomPat` (line ~386). Add a branch for `PUnit` adjacent to `APWild`:

```haskell
inferAtomPat Abs.PUnit = pure (TCon TcUnit [], [])
```

(`PUnit` is in the `AtomPat` data type per the grammar; placement next to other no-binder cases like `APWild` keeps the pattern list grouped.)

**(b) Expression case** — find `inferExprW` (line ~447). Add a branch for `EUnit` adjacent to the other literal expression cases:

```haskell
inferExprW _ Abs.EUnit = pure (TCon TcUnit [])
```

**(c) Type translation case** — find `translateType` (search for the function; it walks `Abs.Type` and produces `CType`). Add a branch:

```haskell
translateType _ Abs.TUnit = pure (CTCon TcUnit [])
```

(If `translateType` lives in a different module — the spec says `Infer.hs` — confirm by grepping `grep -n "translateType\|TParen\b" src/Wok/TypeChecking/Infer.hs` and adding the case in the same `case` block as `TParen`.)

- [ ] **Step 5: Add the Reordering passthrough case if needed**

Build:

```bash
cabal build 2>&1 | grep -E "warning|error" | head -10
```

If `Wok.Reordering.reorderExp` warns about non-exhaustive patterns, open `src/Wok/Reordering.hs` and find the `reorderExp` function (line ~200). The catchall is `reorderExp _ e = Right e` at line 217. Verify it actually covers `EUnit`. If not (e.g. if `-Wall -Werror` rejects the warning), add an explicit branch above the catchall:

```haskell
reorderExp _ Abs.EUnit = Right Abs.EUnit
```

The catchall should cover it, but explicit is safer if `-Wincomplete-patterns` is on.

- [ ] **Step 6: Re-run the success test**

```bash
cabal test wok-tests --test-options="-p 11-unit" 2>&1 | tail -10
```

Expected: pass.

- [ ] **Step 7: Write the typecheck-fail fixture**

Create `test/typecheck-fail-examples/09-unit-mismatch.wok`:

```wok
bad : Int
bad = ()
```

Create `test/typecheck-fail-golden/09-unit-mismatch.expected`:

```
typecheck: Mismatch Nothing (CTCon TcInt []) (CTCon TcUnit [])
```

(The exact text comes from the existing `Show TypeError` instance — verify against other fail goldens like `01-mismatch.expected` for the format.)

- [ ] **Step 8: Run the fail-golden test**

```bash
cabal test wok-tests --test-options="-p 09-unit-mismatch" 2>&1 | tail -10
```

Expected: pass.

- [ ] **Step 9: Run the entire test suite to confirm no regressions**

```bash
cabal test 2>&1 | tail -20
```

Expected: zero failures across all groups.

- [ ] **Step 10: Commit**

```bash
git add src/Wok/TypeChecking/Infer.hs src/Wok/Reordering.hs test/typecheck-examples/11-unit.wok test/typecheck-golden/11-unit.expected test/typecheck-fail-examples/09-unit-mismatch.wok test/typecheck-fail-golden/09-unit-mismatch.expected
git commit -m "$(cat <<'EOF'
feat(typecheck): infer unit literal `()` as TcUnit

Hooks the new EUnit/TUnit/PUnit AST constructors into the typechecker;
each translates to CTCon TcUnit []. Adds typecheck-success and
typecheck-fail golden tests covering value, type, pattern positions
and whitespace variants.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```
