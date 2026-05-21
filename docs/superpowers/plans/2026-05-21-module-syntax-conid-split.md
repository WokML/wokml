# Module Syntax & ConId/VarId Split — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers-extended-cc:subagent-driven-development (recommended) or superpowers-extended-cc:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add the v2 surface syntax to the Wok grammar — an uppercase/lowercase identifier split, module declarations, the `x.y` projection, and a future-keyword reserved-word bucket.

**Architecture:** All grammar lives in the single BNFC source `grammar/Wok.cf`. Each task edits that file, regenerates the Haskell modules with `bnfc`, rebuilds, and verifies via the tasty-golden round-trip suite. Tasks are strictly sequential because they all edit one file. Semantic passes (name resolution, visibility) are out of scope — this is surface syntax only.

**Tech Stack:** BNFC 2.9.x, Alex, Happy, GHC 9.10 / GHC2024, Cabal 3.x, tasty + tasty-golden + tasty-hunit.

**Spec:** `docs/superpowers/specs/2026-05-21-module-syntax-conid-split-design.md`

---

## Conventions for every task

- **Regeneration command:** `bnfc --haskell -d -p GeneratedParser --text-token -o src grammar/Wok.cf`
- **BNFC overwrites** `src/GeneratedParser/Wok/{Abs.hs,Lex.x,Par.y,Print.hs,Layout.hs,ErrM.hs}` (all committed) plus `Test.hs`/`Skel.hs`/`Doc.txt`/`*.bak` (gitignored). Commit only the six committed files.
- **Conflict count:** `cabal build` runs Happy, which prints `shift/reduce conflicts: N` to stderr. v1's baseline is **24**. Record N after each task. A rise of a few from new pattern/projection rules is expected and benign (Happy's default-shift gives the intended greedy parse); a large jump or any `reduce/reduce` conflict must be investigated.
- **Golden files** hold *pretty-printed source*, not raw ASTs. `ECon` and `EVar` print identically (the bare name), so the identifier split does not change any existing golden file. A deliberately-malformed example produces a `PARSE ERROR: ...` line, which `parseToBS` (`test/Spec.hs:60`) writes into the golden — that is how negative tests are expressed.
- **Accepting goldens:** `cabal test --test-options=--accept` creates/updates golden files. Always inspect a newly accepted golden before committing.
- **Commits** use the repo's conventional-commit style and end with the trailer `Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>`.

---

### Task 1: ConId/VarId lexer split

**Goal:** Split the single `VarId` token into `ConId` (uppercase-initial) and `VarId` (lowercase/`_`-initial), and reclassify every grammar position so constructors and type constructors are lexically distinct from variables.

**Files:**
- Modify: `grammar/Wok.cf`
- Regenerate: `src/GeneratedParser/Wok/Abs.hs`, `src/GeneratedParser/Wok/Lex.x`, `src/GeneratedParser/Wok/Par.y`, `src/GeneratedParser/Wok/Print.hs`, `src/GeneratedParser/Wok/Layout.hs`, `src/GeneratedParser/Wok/ErrM.hs`
- Create: `test/examples/12-conid-split.wok`, `test/golden/12-conid-split.expected`
- Create: `test/examples/13-data-lowercase-error.wok`, `test/golden/13-data-lowercase-error.expected`

**Acceptance Criteria:**
- [ ] `grammar/Wok.cf` defines `position token ConId` (starts `upper`) and `position token VarId` (starts `lower | '_'`).
- [ ] `DData` and `ConDef` heads, and the `PApp` head, use `ConId`; `APCon`, `TCon`, `ECon` productions are added.
- [ ] `bnfc` + `cabal build` succeed; conflict count recorded in the commit message.
- [ ] All eleven pre-existing parse goldens, the fixity tests, and the resolve tests still pass unchanged.
- [ ] `data foo = Bar` (lowercase type name) produces a parse error.

**Verify:** `cabal test` → every test passes (`All N tests passed`).

**Steps:**

- [ ] **Step 1: Establish a green baseline**

Run: `cabal build && cabal test`
Expected: builds, `All N tests passed`. If it is not green, stop — the working tree has a pre-existing break that must be fixed before this plan can proceed.

- [ ] **Step 2: Add the negative test (currently passes wrongly)**

Create `test/examples/13-data-lowercase-error.wok`:

```
data foo = Bar
```

Run: `cabal test --test-options=--accept` then open `test/golden/13-data-lowercase-error.expected`.
Expected right now: it contains a *successful* parse (`data foo = Bar;`) — v1 accepts a lowercase type name. This is the behavior the split must reject. Leave the accepted golden in place for now; Step 6 will re-accept it.

- [ ] **Step 3: Edit `grammar/Wok.cf` — token definitions**

Replace the token block (currently `grammar/Wok.cf:195-202`, the single `VarId`) so it reads:

```bnfc
position token ConId
  upper (letter | digit | '_' | '\'' | '-')*
  ;

position token VarId
  (lower | '_') (letter | digit | '_' | '\'' | '-')*
  ;
```

Leave `position token WokInt` and `position token VarSym` exactly as they are (the `.` stays in `VarSym` until Task 2). `upper`, `lower`, `letter`, `digit` are BNFC built-in character classes.

- [ ] **Step 4: Edit `grammar/Wok.cf` — reclassify rules**

Make exactly these production changes (everything else, including `FunName`, `DSig`, `FixName`, `InfixOp`, and all `data`-param `[VarId]` lists, stays `VarId`):

`DData` — type name becomes `ConId`:

```bnfc
DData.    Decl ::= "data" ConId [VarId] "=" [ConDef] ;
```

`ConDef` — constructor name becomes `ConId`:

```bnfc
ConDef.   ConDef ::= ConId [Type2] ;
```

`PApp` — constructor head becomes `ConId`:

```bnfc
PApp.     Pat ::= ConId AtomPat [AtomPat] ;
```

Add `APCon` immediately after `APVar` in the `AtomPat` block:

```bnfc
APVar.    AtomPat ::= VarId ;
APCon.    AtomPat ::= ConId ;
```

Add `TCon` immediately after `TVar` in the `Type2` block:

```bnfc
TVar.     Type2 ::= VarId ;
TCon.     Type2 ::= ConId ;
```

Add `ECon` immediately after `EVar` in the `Exp2` block:

```bnfc
EVar.     Exp2 ::= VarId ;
ECon.     Exp2 ::= ConId ;
```

Update the file's top comment line to: `-- wok grammar v2 (Task 1: ConId/VarId lexical split)`.

- [ ] **Step 5: Regenerate and build**

Run:
```bash
bnfc --haskell -d -p GeneratedParser --text-token -o src grammar/Wok.cf
cabal build
```
Expected: build succeeds. Note the `shift/reduce conflicts: N` line. N around 24-40 is acceptable (a bare `ConId` in pattern position now creates benign default-shift conflicts between `PApp` and `APCon`). Any `reduce/reduce conflicts` line means stop and investigate.

- [ ] **Step 6: Verify existing tests unchanged, accept new goldens**

Run: `cabal test`
Expected: `13-data-lowercase-error` now FAILS — its golden still holds the old successful parse, but the parser now rejects `data foo`. The eleven original examples, fixity tests, and resolve tests still pass. If any *original* golden changed, stop and inspect — the split must not alter them.

Then create the positive example `test/examples/12-conid-split.wok`:

```
data Color = Red | Green | Blue
data Box a = Box a

favourite : Color
favourite = Green

unbox b = case b of { Box x -> x }
```

Run: `cabal test --test-options=--accept`
Then inspect both new goldens:
- `test/golden/12-conid-split.expected` — must be a clean pretty-print (no `PARSE ERROR`).
- `test/golden/13-data-lowercase-error.expected` — must now start with `PARSE ERROR:`.

- [ ] **Step 7: Confirm green and commit**

Run: `cabal test`
Expected: `All N tests passed`.

```bash
git add grammar/Wok.cf src/GeneratedParser/Wok/Abs.hs src/GeneratedParser/Wok/Lex.x src/GeneratedParser/Wok/Par.y \
        src/GeneratedParser/Wok/Print.hs src/GeneratedParser/Wok/Layout.hs src/GeneratedParser/Wok/ErrM.hs \
        test/examples/12-conid-split.wok test/golden/12-conid-split.expected \
        test/examples/13-data-lowercase-error.wok test/golden/13-data-lowercase-error.expected
git commit -m "feat(grammar): split identifiers into ConId and VarId tokens"
```

---

### Task 2: Module declarations

**Goal:** Add the `module` header, `import`, `use`, and the `local` private marker, plus the hierarchical `ModPath` nonterminal; remove `.` from the operator alphabet.

**Files:**
- Modify: `grammar/Wok.cf`
- Regenerate: `src/GeneratedParser/Wok/Abs.hs`, `src/GeneratedParser/Wok/Lex.x`, `src/GeneratedParser/Wok/Par.y`, `src/GeneratedParser/Wok/Print.hs`, `src/GeneratedParser/Wok/Layout.hs`, `src/GeneratedParser/Wok/ErrM.hs`
- Create: `test/examples/14-modules.wok`, `test/golden/14-modules.expected`

**Acceptance Criteria:**
- [ ] `ModPath` (`MPName`, `MPDot`), `DModule`, `DImport`, `DUse`, `DLocal` are defined.
- [ ] `.` is removed from the `VarSym` alphabet.
- [ ] `module`, `import`, `use`, `local` are reserved keywords (visible in `src/GeneratedParser/Wok/Lex.x` `resWords`).
- [ ] A file with a `module Foo.Bar` header, `import`/`use` lines, and a `local` decl parses and round-trips.

**Verify:** `cabal test` → every test passes.

**Steps:**

- [ ] **Step 1: Edit `grammar/Wok.cf` — remove `.` from `VarSym`**

Change `position token VarSym` so its alphabet no longer lists `'.'`:

```bnfc
position token VarSym
  ('!' | '#' | '$' | '%' | '&' | '*' | '+' | '/' |
   '<' | '=' | '>' | '?' | '@' | '\\' | '^' | '|' | '-' | '~')+
  ;
```

- [ ] **Step 2: Edit `grammar/Wok.cf` — add module productions**

Add this block immediately after the `Module.` / `[Decl]` rules (near `grammar/Wok.cf:16-23`):

```bnfc
-- Hierarchical dotted module paths (e.g. Data.List)
MPName.   ModPath ::= ConId ;
MPDot.    ModPath ::= ModPath "." ConId ;

-- Module-level declarations.
-- DModule is conventionally the first decl; a later semantic pass enforces
-- "present, first, unique". DLocal recursively wraps any Decl; the semantic
-- pass restricts it to value/type/data/fixity decls.
DModule.  Decl ::= "module" ModPath ;
DImport.  Decl ::= "import" ModPath ;
DUse.     Decl ::= "use" ModPath ;
DLocal.   Decl ::= "local" Decl ;
```

Update the top comment line to: `-- wok grammar v2 (Task 2: module declarations)`.

- [ ] **Step 3: Regenerate and build**

Run:
```bash
bnfc --haskell -d -p GeneratedParser --text-token -o src grammar/Wok.cf
cabal build
```
Expected: build succeeds. Record the conflict count; it should be roughly unchanged from Task 1 (the new rules use distinct keyword tokens). Any `reduce/reduce` conflict means stop.

- [ ] **Step 4: Confirm keywords reserved**

Run: `grep -E '"(module|import|use|local)"' src/GeneratedParser/Wok/Lex.x`
Expected: all four appear (BNFC put them in the `resWords` tree because they are literals in productions).

- [ ] **Step 5: Add the example and accept its golden**

Create `test/examples/14-modules.wok`:

```
module Geometry.Shapes

import Data.List
use Math.Trig

area : Int
area = 1

local scratch n = n
```

Run: `cabal test --test-options=--accept`
Inspect `test/golden/14-modules.expected` — it must be a clean pretty-print containing `module Geometry.Shapes;`, `import Data.List;`, `use Math.Trig;`, and `local scratch n = n` (no `PARSE ERROR`).

- [ ] **Step 6: Confirm green and commit**

Run: `cabal test`
Expected: `All N tests passed` (the eleven originals + Task 1's two + this one + fixity + resolve).

```bash
git add grammar/Wok.cf src/GeneratedParser/Wok/Abs.hs src/GeneratedParser/Wok/Lex.x src/GeneratedParser/Wok/Par.y \
        src/GeneratedParser/Wok/Print.hs src/GeneratedParser/Wok/Layout.hs src/GeneratedParser/Wok/ErrM.hs \
        test/examples/14-modules.wok test/golden/14-modules.expected
git commit -m "feat(grammar): add module header, import, use, and local"
```

---

### Task 3: Dotted names — projection and qualified constructors

**Goal:** Add the `x.y` projection expression (`EProj`/`EProjC`), upgrade type constructors and constructor patterns to accept qualified `ModPath` names, and make `Wok.Reordering` recurse into projection heads.

**Files:**
- Modify: `grammar/Wok.cf`
- Modify: `src/Wok/Reordering.hs`
- Regenerate: `src/GeneratedParser/Wok/Abs.hs`, `src/GeneratedParser/Wok/Lex.x`, `src/GeneratedParser/Wok/Par.y`, `src/GeneratedParser/Wok/Print.hs`, `src/GeneratedParser/Wok/Layout.hs`, `src/GeneratedParser/Wok/ErrM.hs`
- Create: `test/examples/15-projection.wok`, `test/golden/15-projection.expected`
- Create: `test/resolve-examples/04-projection-chain.wok`, `test/resolve-golden/04-projection-chain.expected`

**Acceptance Criteria:**
- [ ] `EProj. Exp2 ::= Exp2 "." VarId` and `EProjC. Exp2 ::= Exp2 "." ConId` are defined.
- [ ] `TCon`, `PApp` head, and `APCon` use `ModPath` instead of bare `ConId`.
- [ ] `reorderExp` in `src/Wok/Reordering.hs` has explicit `EProj`/`EProjC` cases that recurse into the projection head.
- [ ] An example with `Data.List.foldr`, a qualified type signature, a qualified constructor pattern, and a record-style `r.name` parses and round-trips.
- [ ] An infix chain inside a projection head resolves correctly.

**Verify:** `cabal test` → every test passes.

**Steps:**

- [ ] **Step 1: Edit `grammar/Wok.cf` — projection in expressions**

Add `EProj` and `EProjC` immediately after the `ECon` line in the `Exp2` block:

```bnfc
EVar.     Exp2 ::= VarId ;
ECon.     Exp2 ::= ConId ;
EProj.    Exp2 ::= Exp2 "." VarId ;
EProjC.   Exp2 ::= Exp2 "." ConId ;
```

- [ ] **Step 2: Edit `grammar/Wok.cf` — qualified names in types and patterns**

Change `TCon` to take a `ModPath`:

```bnfc
TVar.     Type2 ::= VarId ;
TCon.     Type2 ::= ModPath ;
```

Change the `PApp` head and `APCon` to take a `ModPath`:

```bnfc
PApp.     Pat ::= ModPath AtomPat [AtomPat] ;
```

```bnfc
APVar.    AtomPat ::= VarId ;
APCon.    AtomPat ::= ModPath ;
```

Update the top comment line to: `-- wok grammar v2 (Task 3: dotted names — projection and qualified constructors)`.

- [ ] **Step 3: Regenerate and build**

Run:
```bash
bnfc --haskell -d -p GeneratedParser --text-token -o src grammar/Wok.cf
cabal build
```
Expected: the build fails to compile `src/Wok/Reordering.hs` only if the new `Exp` constructors are referenced — they are not yet, so it should build. Record the conflict count (the `.` rules use a distinct token and should add no significant conflicts). Any `reduce/reduce` conflict means stop.

- [ ] **Step 4: Edit `src/Wok/Reordering.hs` — recurse into projection heads**

In `reorderExp` (`src/Wok/Reordering.hs`), add two cases immediately before the catch-all line `reorderExp _ e = Right e`:

```haskell
reorderExp t (EProj e s)     = (\e' -> EProj e' s)  <$> reorderExp t e
reorderExp t (EProjC e s)    = (\e' -> EProjC e' s) <$> reorderExp t e
```

`EProj :: Exp -> VarId -> Exp` and `EProjC :: Exp -> ConId -> Exp`; the projection head `e` is a sub-expression that may itself contain an unresolved infix chain, so it must be resolved. `ECon` is already handled correctly by the catch-all (a bare constructor has no chain to resolve).

Run: `cabal build`
Expected: builds clean, no warnings about non-exhaustive patterns.

- [ ] **Step 5: Add the projection example and accept its golden**

Create `test/examples/15-projection.wok`:

```
module Demo

qcall = Data.List.foldr f z

field r = r.name

qctor = List.Cons 1 List.Nil

qsig : Data.Maybe.Maybe Int
qsig = Data.Maybe.Nothing

qmatch x = case x of { List.Cons h t -> h }
```

Run: `cabal test --test-options=--accept`
Inspect `test/golden/15-projection.expected` — it must be a clean pretty-print (no `PARSE ERROR`), with `Data.List.foldr`, `Data.Maybe.Maybe Int`, and `List.Cons h t` reproduced.

- [ ] **Step 6: Add the resolver example and accept its golden**

Create `test/resolve-examples/04-projection-chain.wok`:

```
fixity + left
fixity * left tighter than +

proj = (a + b * c).field
```

Run: `cabal test --test-options=--accept`
Inspect `test/resolve-golden/04-projection-chain.expected` — the projection head must be reassociated, ending with `proj = (a + (b * c)).field`. If it shows `(a + b * c).field` unchanged, Step 4 is wrong — fix and re-accept.

- [ ] **Step 7: Confirm green and commit**

Run: `cabal test`
Expected: `All N tests passed`.

```bash
git add grammar/Wok.cf src/Wok/Reordering.hs src/GeneratedParser/Wok/Abs.hs src/GeneratedParser/Wok/Lex.x \
        src/GeneratedParser/Wok/Par.y src/GeneratedParser/Wok/Print.hs src/GeneratedParser/Wok/Layout.hs src/GeneratedParser/Wok/ErrM.hs \
        test/examples/15-projection.wok test/golden/15-projection.expected \
        test/resolve-examples/04-projection-chain.wok \
        test/resolve-golden/04-projection-chain.expected
git commit -m "feat(grammar): add x.y projection and qualified constructors"
```

---

### Task 4: Reserved-word bucket

**Goal:** Reserve the eight Tier-C future-feature keywords so they cannot be used as `VarId`, via a `ReservedKw` bucket reachable through a `DReserved` declaration.

**Files:**
- Modify: `grammar/Wok.cf`
- Regenerate: `src/GeneratedParser/Wok/Abs.hs`, `src/GeneratedParser/Wok/Lex.x`, `src/GeneratedParser/Wok/Par.y`, `src/GeneratedParser/Wok/Print.hs`, `src/GeneratedParser/Wok/Layout.hs`, `src/GeneratedParser/Wok/ErrM.hs`
- Create: `test/examples/16-reserved.wok`, `test/golden/16-reserved.expected`
- Create: `test/examples/17-reserved-error.wok`, `test/golden/17-reserved-error.expected`

**Acceptance Criteria:**
- [ ] `grammar/Wok.cf` defines `rules ReservedKw ::= ...` with the eight Tier-C words and `DReserved. Decl ::= ReservedKw`.
- [ ] All eight words appear in `src/GeneratedParser/Wok/Lex.x` `resWords`.
- [ ] A bare reserved word at top level parses as a `DReserved` declaration.
- [ ] Using a reserved word where a `VarId` is expected (e.g. `f = type`) produces a parse error.

**Verify:** `cabal test` → every test passes.

**Steps:**

- [ ] **Step 1: Edit `grammar/Wok.cf` — add the reserved bucket**

Add this block immediately after the `DLocal.` rule from Task 2:

```bnfc
-- Reserved for future language features. ReservedKw exists only so BNFC adds
-- these words to the lexer's reserved set, keeping them out of VarId. When a
-- feature ships, move its word out of here into that feature's real production.
rules     ReservedKw ::= "contract" | "type" | "class" | "instance"
                       | "deriving" | "forall" | "do" | "record" ;
DReserved. Decl ::= ReservedKw ;
```

Update the top comment line to: `-- wok grammar v2 (Task 4: reserved-word bucket)`.

- [ ] **Step 2: Regenerate and build**

Run:
```bash
bnfc --haskell -d -p GeneratedParser --text-token -o src grammar/Wok.cf
cabal build
```
Expected: builds. The eight words are distinct keyword tokens that start no other `Decl`, so no new conflicts. Any `reduce/reduce` conflict means stop.

- [ ] **Step 3: Confirm keywords reserved**

Run: `grep -E '"(contract|type|class|instance|deriving|forall|do|record)"' src/GeneratedParser/Wok/Lex.x`
Expected: all eight appear in the generated lexer.

- [ ] **Step 4: Add the positive example**

Create `test/examples/16-reserved.wok` (each reserved word parses as a bare `DReserved` decl):

```
contract
type
record
```

- [ ] **Step 5: Add the negative example**

Create `test/examples/17-reserved-error.wok` (a reserved word cannot be a variable):

```
useType x = type
```

- [ ] **Step 6: Accept and inspect goldens**

Run: `cabal test --test-options=--accept`
Inspect:
- `test/golden/16-reserved.expected` — a clean pretty-print reproducing `contract;`, `type;`, `record` (no `PARSE ERROR`).
- `test/golden/17-reserved-error.expected` — must start with `PARSE ERROR:`.

- [ ] **Step 7: Confirm green and commit**

Run: `cabal test`
Expected: `All N tests passed`.

```bash
git add grammar/Wok.cf src/GeneratedParser/Wok/Abs.hs src/GeneratedParser/Wok/Lex.x src/GeneratedParser/Wok/Par.y \
        src/GeneratedParser/Wok/Print.hs src/GeneratedParser/Wok/Layout.hs src/GeneratedParser/Wok/ErrM.hs \
        test/examples/16-reserved.wok test/golden/16-reserved.expected \
        test/examples/17-reserved-error.wok test/golden/17-reserved-error.expected
git commit -m "feat(grammar): reserve future-feature keywords"
```

---

### Task 5: Documentation update

**Goal:** Update `README.md` and `CHANGELOG.md` to describe the v2 surface syntax.

**Files:**
- Modify: `README.md`
- Modify: `CHANGELOG.md`

**Acceptance Criteria:**
- [ ] `README.md` documents the ConId/VarId split, the module syntax, the `x.y` projection, and the reserved-word list.
- [ ] `README.md` warts section reflects the spec's accepted warts (notably: `PApp` still takes 1+ args; `EProj` is semantically overloaded).
- [ ] `CHANGELOG.md` has a v2 entry summarizing the change.

**Verify:** `cabal test` still passes; `README.md` and `CHANGELOG.md` render correctly (manual read).

**Steps:**

- [ ] **Step 1: Update `README.md` — identifier classes**

In the "Language summary" list, replace the `Identifier classes` bullet with:

```markdown
- **Identifier classes:** `ConId` (uppercase-initial; data constructors, type
  constructors, module-name segments), `VarId` (lowercase- or `_`-initial;
  variables, type variables, function names, projection selectors), `VarSym`
  (pure-symbol operators; `.` is no longer a symbol character).
```

- [ ] **Step 2: Update `README.md` — add a module-syntax section**

After the "Language summary" list, add:

```markdown
## Modules (v2)

- **Header:** `module Data.Example` — explicit, hierarchical, no `where`.
- **Imports:** `import Data.List` (by dotted name); `use Data.List` brings a
  module's names into scope unqualified.
- **Visibility:** declarations are public by default; prefix `local` to make
  one private (`local helper x = x`).
- **Qualified access / projection:** `x.y` is one syntactic form — either a
  module member or a record field — disambiguated by a later semantic pass.
```

- [ ] **Step 3: Update `README.md` — reserved words and warts**

In the "Known AST-shape warts" section, add these bullets:

```markdown
- **`PApp` still takes 1+ args even after the ConId/VarId split.** The split
  removes the *variable vs constructor* semantic guesswork, but a 0-arg `PApp`
  would still clash with the bare-constructor atom form, so bare constructors
  remain `PAtom (APCon ...)`. This matches Haskell's `gcon`/`apat` shaping.
- **`EProj` (`x.y`) is semantically overloaded** — the parser cannot tell
  module access from record-field access. The renamer resolves module access;
  genuine field projections reach the type checker.
- **Reserved-for-future keywords:** `contract type class instance deriving
  forall do record` cannot be used as identifiers, though their features do
  not exist yet.
```

- [ ] **Step 4: Update `CHANGELOG.md`**

Add a new entry above the `0.1.0.0` entry:

```markdown
## 0.2.0.0

### Added

- ConId/VarId lexical split — constructors and type constructors are now
  lexically distinct from variables.
- Module syntax: `module` header, `import`, `use`, and the `local` private
  marker, with hierarchical dotted module paths.
- The `x.y` projection expression (module access or record field).
- A reserved-word bucket for future-feature keywords.

### Changed

- `.` is no longer a `VarSym` operator character; it is the projection /
  module-path separator.
```

- [ ] **Step 5: Confirm and commit**

Run: `cabal test`
Expected: `All N tests passed` (docs change nothing functional).

```bash
git add README.md CHANGELOG.md
git commit -m "docs: document v2 module syntax and ConId/VarId split"
```

---

## Self-Review

**Spec coverage** — every spec section maps to a task:
- Section A (ConId/VarId split, `.` reservation) → Task 1 + Task 2 Step 1.
- Section B (module header, import, use, local) → Task 2.
- Section C (`x.y` projection, qualified types/patterns, resolver recursion) → Task 3.
- Section D (reserved-word bucket) → Task 4.
- Documentation / warts → Task 5.

**Placeholder scan** — every step has concrete grammar text, file contents, commands, and expected output. No TBD/TODO.

**Type consistency** — `ModPath` (`MPName`/`MPDot`) is defined in Task 2 and reused by Task 3's `TCon`/`PApp`/`APCon`. `EProj :: Exp -> VarId -> Exp` and `EProjC :: Exp -> ConId -> Exp` are used consistently in the Task 3 grammar and the `reorderExp` cases. `ConId`/`VarId` token names are consistent across all tasks. `DReserved`/`ReservedKw` are defined and used only in Task 4.

**Sequencing** — all five tasks edit `grammar/Wok.cf`, so they are strictly sequential (each blocked by the previous). The conflict-count guard and "existing goldens unchanged" guard run every task.
