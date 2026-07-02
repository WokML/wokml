# Handler-block redesign: `var` state members + block-scope arm bodies

Status: **Design (approved for full spec)**, 2026-07-02. Surface-ergonomics slice
for the effect-handler block. Semantics-preserving; no runtime, IR, or type-story
change. Companion explainer: `docs/effect-handlers-explainer.html` (§8).

Relates to: the 2026-06-12 repo-review backlog item #9 ("multi-line handler
blocks"), now precisely re-characterized below. Does NOT touch the separate
"resume launders effects" honest-types work (`docs/superpowers/specs/2026-06-11-resume-site-control-and-heap-continuations-design.md`),
which is queued as the next surface-language slice after this one.

---

## 1. Summary

Two coupled changes to the effect-handler block `{ … }`:

1. **`var` state member.** A parameterized handler's baton is today a bare arm
   `State { s = i ; … }`, which reads like a stray statement. Mark it with a
   `var` keyword: `State { var s = i ; … }`.
2. **Block-scope arm bodies.** Make the handler block indentation-aware so a
   single arm's *body* can span multiple lines. Newlines already separate arms;
   the only gap is multi-line *bodies*.

Together the handler reads as a clean block of members:

```
state i c =
  with self = State {
    var s = i
    get     -> s
    set x k -> k x ()
    v       -> (v, s)
  } in c self
```

---

## 2. Motivation

- The bare baton `s = i` is grammatically one of the `[HandlerArm]` entries
  (`grammar/Wok.cf:462`, `HParam`), so it sits in the same list as `get`/`set`
  and reads like a statement injected among the operation clauses. A `var`
  keyword labels it as intentional handler-local state.
- "Handlers must be one line" is **stale**. Verified this session:
  newline-separated *arms* (no semicolons) already parse and run
  (`test/run-examples/multiline-handler-state.wok`). The real residual is
  narrow: when a single arm's *body* spans lines, `RecordLayout.hs` injects a
  spurious `;` at the newline and the parse fails. Fixing that completes #9.

---

## 3. Design

### 3.1 `var` state member

- New grammar production alongside the existing bare form (kept for a clean
  rejection message, see below):

  ```
  HParam.  HandlerArm ::= VarId "=" Exp ;         -- kept (now rejected in elaborator)
  HParamV. HandlerArm ::= "var" VarId "=" Exp ;   -- new: the accepted form
  ```

- `var` becomes a **global reserved word**, exactly like `as` and `with`
  (this lexer reserves every quoted terminal globally via `eitherResIdent`;
  a truly *contextual* keyword would need a second hand-rolled token pre-pass and
  is not worth it). Safe: no `.wok` file uses `var` as an identifier today.
  (This supersedes the earlier "contextual keyword" idea.)

- **Rejection UX.** The bare `HParam` still parses, but the elaborator rejects it
  with a targeted, positioned error:
  *"handler-local state must be declared with `var` — did you mean `var s = i`?"*
  This gives a clean message instead of a generic parse error and keeps the
  migration mechanical.

### 3.2 Block-scope arm bodies (column-aware layout)

This is NOT BNFC's native offside engine. `with` cannot be a BNFC layout keyword
(it is overloaded with the type-level `with` in `T -> R with E`), and the handler
productions use *explicit* braces — which is exactly why the repo hand-rolls
`src/Wok/RecordLayout.hs` as a token-stream pre-pass
(`grammar/Wok.cf:427-434`). The fix lives entirely in that pre-pass.

Current behavior (`src/Wok/RecordLayout.hs`): a `BlockBrace openLine lastLine
isHandler` context inserts a virtual `;` before any token that begins a new
source line inside the brace (guard around `RecordLayout.hs:220-244`,
`curLine > lastLine && lastLine > openLine`). There is **no column comparison**
(`tokenLine` at `:40-41` is the only position accessor) — so a deeper-indented
continuation line of an arm body wrongly gets a separator.

The fix — **make the insertion column-aware, gated to handler braces**:

1. Add `tokenCol :: Token -> Int` (`tokenCol t = case tokenPosn t of Pn _ _ c -> c`),
   sibling to `tokenLine`.
2. Extend `BlockBrace` with a **reference column** field, set to the column of
   the first arm token after `{` (the arm-start column).
3. In the insertion branch, for `bcIsHandler` contexts, insert a separator on a
   new line only when the line's leading-token column is `<=` the reference
   column (a new arm). When the leading token is strictly deeper (`>`
   reference column), it is a **continuation of the current arm body** — do NOT
   insert a separator; just advance `lastLine`.
4. Non-handler (record-literal) braces keep today's line-only behavior — the fix
   is `bcIsHandler`-gated, so multi-line record fields are out of scope and
   unaffected.

Because the pre-pass runs before BNFC's own layout
(`src/Wok/Parsing.hs`: `pModule . resolveLayout True . insertRecordVirtualCommas
. tokens`), nested `let`/`case`/`of` inside an arm body are resolved
independently afterward and are unaffected.

**Expected behavior to document (not a regression):** a continuation line
indented to *exactly* the arm reference column is read as a new arm — standard
offside semantics. Bodies must be indented strictly deeper than their arm.

### 3.3 What does not change

- Runtime, IR, the differential oracle, and all effect semantics.
- Call sites: `with count = state 0 in count.set 42` is byte-for-byte identical.
- Stateless handlers: `Except { throw e k -> Err e ; v -> Ok v }` — no `var`,
  unchanged.
- The two-argument resume `k x ()` (the "write" side).
- Semicolons remain valid, optional arm separators (one-liners keep working).
- Single-baton constraint: two batons stay a `DuplicateHandlerParam` error.

---

## 4. Decisions (locked) and rejected alternatives

- **A. Require `var`** (reject bare `s = i`). Chosen for a single clean surface.
  Cost: the 26-file migration is mandatory and atomic with the rejection.
  Fallback if churn is unwanted: accept both forms (not chosen).
- **B. `var` = global reserved word** (not contextual). Forced by the lexer;
  zero real-world breakage.
- **Rejected — parameter-list form** `State(s = i) { … }` (former "Option B"):
  breaks wok's record-block symmetry, needs a new head production, widens
  horizontally for multiple state, and doesn't match Koka. Dropped in favor of
  the `var` member (`A`), which matches wok's record-block model and Koka's
  parameterized-handler surface.
- **Deferred — `s := x` assignment writes**: a coherent Koka-style fast-follow
  once `var` lands; out of scope here.
- **Deferred — multiple batons**: rejected today (`DuplicateHandlerParam`);
  needs a multi-value resume. Future work; the `var` syntax generalizes to it
  but the semantics do not exist yet.

---

## 5. Detailed implementation plan

### 5.1 Grammar + regen (`grammar/Wok.cf`, `src-generated/`)

- Add `HParamV. HandlerArm ::= "var" VarId "=" Exp ;` after `HParam`
  (`Wok.cf:462`). Keep `HParam`.
- Regenerate: `bnfc --haskell -d -p GeneratedParser --text-token -o src-generated
  grammar/Wok.cf` (per `README.md`, `wok.cabal`).
- **Reapply the two documented post-regen hand patches** (`Wok.cf:5-35`): the
  `Layout.hs` separator-insertion fix and the `Par.y` LALR-conflict fix for
  `PRecordOpen`. `bnfc` regenerates both from scratch and silently drops the
  hand edits; they must be re-applied and verified. This is the riskiest
  mechanical step — budget for it.

### 5.2 Reserved word

Automatic: adding `"var"` as a grammar terminal makes the regenerated
`Lex.x` reserve it globally. No separate lexer edit.

### 5.3 Layout (`src/Wok/RecordLayout.hs`)

Implement §3.2: add `tokenCol`, extend `BlockBrace` with the reference column,
gate the column-aware separator suppression to `bcIsHandler`. Leave record-brace
behavior unchanged.

### 5.4 Elaborator + errors

- `src/Wok/TypeChecking/Error.hs`: add `BareHandlerParam SourceSpan Text`
  (sibling to `DuplicateHandlerParam` at `:122`); render the hint message.
- `src/Wok/TypeChecking/Infer.hs`: in `classifyArm` (`:2439-2462`), route
  `Abs.HParamV name init pos -> pure (ParamArmC …)` and
  `Abs.HParam name _ pos -> throwError (BareHandlerParam (Just pos) name)`.
  `paramArms`/`DuplicateHandlerParam` logic (`:2539/2565`, `:2733/2758`)
  is unchanged — single-baton still enforced via `ParamArmC`.
- `src/Wok/TypeChecking/Class.hs`: `goArm` (`:562-564`) must add a
  `HParamV` case (`goArm (Abs.HParamV v a) = Abs.HParamV v (go a)`) or GHC's
  exhaustiveness check fails. Keep the `HParam` case.

### 5.5 Migration (26 files)

- Prelude: `prelude/Std/Control.wok` `state` (`s = i`) and `writer` (`log = []`)
  -> `var …`. `reader`/`except` have no baton, untouched.
- Tests: ~24 `.wok` files defining an inline `State`/`Writer`-style handler,
  including typecheck-fail fixtures that use a bare baton for an unrelated
  negative test (e.g. `test/typecheck-fail-examples/44-state-swapped-resume.wok`)
  — migrate these too so they keep testing the intended failure.
- Find with: `grep -rlE '(State|Writer) \{' test/ prelude/ --include='*.wok'`,
  then any handler defining a bare `name = init` arm. The bare-rejection makes
  any missed file fail loudly, so the full suite is the backstop.

---

## 6. Testing and verification

- **Positive (new capability):** a handler with a multi-line arm *body*
  (e.g. `set x k -> <newline, indented> let y = x in <newline> k y ()`) parses,
  typechecks, runs, and returns the correct value on both backends.
- **Positive:** `var s = i` parses/runs for `state` and `writer`;
  nested handlers with multi-line bodies (extend
  `test/run-examples/41-state-writer-nested.wok` / `42-writer-state-nested.wok`).
- **Positive:** one example per handler form — anonymous `with { }`, headed
  `with C { }`, named `with x = C { }`.
- **Negative:** bare `s = i` now yields `BareHandlerParam` with the hint
  (new typecheck-fail fixture).
- **Negative (preserved):** `var s = i ; var t = j` still `DuplicateHandlerParam`.
- **Regression:** full suite green after migration; differential oracle shows
  identical cross-backend results (semantics unchanged).
- **hlint** clean on the touched Haskell (ignore `src-generated`).

---

## 7. Risks and mitigations

- **Layout ripple to record literals** — mitigated by `bcIsHandler` gating; a
  multi-line record-field test should confirm records are unchanged.
- **Regen drops the two hand patches** — mitigated by a documented reapply step
  + full suite (parse failures surface immediately).
- **Migration misses a file** — the bare-rejection makes it a loud elaboration
  error, not a silent pass; grep + full suite catch it.
- **Column-comparison off-by-one / tab handling** — pin with the multi-line-body
  and exact-column tests; document the exact-column-reads-as-new-arm behavior.

---

## 8. Non-goals / future work

- `s := x` assignment writes (Koka-style fast-follow).
- Multiple batons (needs multi-value resume).
- Multi-line record-literal fields (this fix is handler-gated).
- The "resume launders effects" honest-types slice (separate, queued next).

---

## 9. Phasing (for the resumable plan)

Ordered to keep the suite green at each checkpoint:

1. Grammar `HParamV` + regen + reapply hand patches; elaborator temporarily
   **accepts both** `HParam` and `HParamV` (route both to `ParamArmC`).
   *(standard — regen + hand-patch is debugging-shaped.)*
2. `RecordLayout.hs` column-aware arm-body fix. *(standard — layout subtlety.)*
3. Migrate all 26 files to `var`. *(mechanical.)*
4. Add tests: multi-line body, nested, per-form, single-baton. *(mechanical.)*
5. Flip the elaborator to **reject** bare `HParam` with `BareHandlerParam` +
   add the negative fixture; run full suite + differential oracle.
   *(standard.)*

Model tiers are assigned per-task in the plan file (phase 5).

---

## 10. Touched files

- `grammar/Wok.cf` (+ regenerated `src-generated/GeneratedParser/**`,
  + reapplied `Layout.hs`/`Par.y` hand patches)
- `src/Wok/RecordLayout.hs`
- `src/Wok/TypeChecking/Infer.hs`
- `src/Wok/TypeChecking/Class.hs`
- `src/Wok/TypeChecking/Error.hs`
- `prelude/Std/Control.wok`
- ~24 `test/**/*.wok` fixtures + new positive/negative fixtures
