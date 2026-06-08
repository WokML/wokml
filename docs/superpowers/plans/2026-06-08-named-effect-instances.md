# Named Effect Instances — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers-extended-cc:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Let a computation hold multiple reachable instances of one effect — introduce a named instance with `with count = state 0 in …`, perform through the name (`count.get`), with the handle's type being the effect itself (`State U64`) and the dot resolved type-directed. No `&`, no sigil, no new token.

**Architecture:** Named instances sit *beside* the unchanged ambient effect row. Runtime routing is by an instance id = the handler's self-binder `Unique` (compile-time, per `with self =` site). The dot accessor is overloaded and resolved by the receiver's type at compile time; handle-taking helpers are annotated. Escape (second-class) is enforced by a type-based carrier rule.

**Tech Stack:** Haskell; BNFC grammar (`grammar/Wok.cf` + 3 manual patches); the CEK ANF interpreter (`Machine.hs`/`Value.hs`); HM inference (`Infer.hs`/`Types.hs`); elaboration (`Elaborate.hs`); Tasty golden tests.

**Spec:** `docs/superpowers/specs/2026-06-08-named-effect-instances-design.md`.
**Baseline:** 591 tests green (`cabal test`). **GUARDRAIL: no `&` syntax anywhere — revert on sight.**

---

### Task 1: Grammar — named-introduction productions

**Goal:** Parse `with count = state 0 in body` (named runner) and `with self = State { … } in body` (named primitive), without changing the shift/reduce conflict count.

**Files:**
- Modify: `grammar/Wok.cf` (near the `EWith*` block, lines ~385–405)
- Regenerate: `src-generated/GeneratedParser/Wok/*` (via `bnfc`), reapply the 3 manual patches (`grammar/Wok.cf:13-69`)
- Test: `test/examples/` + `test/golden/` (parser goldens), `test/Spec.hs` discovery

**Acceptance Criteria:**
- [ ] `EWithNamed.  Exp2 ::= "with" VarId "=" VarId "{"? …` — concretely two productions added:
      `EWithNamed.  Exp2 ::= "with" VarId "=" VarId [WithArg] "in" Exp ;` and
      `EWithNamedH. Exp2 ::= "with" VarId "=" ConId "{" [HandlerArm] "}" "in" Exp ;`
- [ ] Both disambiguate from `EWithRun`/`EWithH` by the `=` after `with VarId`.
- [ ] `with &x = …` is a parse error (binder is `VarId`, never an `AtomPat`; no `&` token exists).
- [ ] Shift/reduce conflict count is **unchanged** vs baseline.

**Verify:** `bnfc --haskell -d -p GeneratedParser --text-token -o src-generated grammar/Wok.cf 2>&1 | grep -i conflict` (record count); reapply patches; `cabal build`; add a parser example `test/examples/NN-with-named.wok` and `cabal run wok-tests -- --accept` (read diff first).

**Steps:**
- [ ] Add the two productions to `grammar/Wok.cf`.
- [ ] Regenerate; capture conflict count; compare to baseline (run `bnfc` on a clean checkout if needed to get the baseline number).
- [ ] Reapply the 3 manual patches (Layout.hs separator; Par.y `NEListRecordFieldPat`; Par.y empty-record `ConId '{' '}'`).
- [ ] `cabal build` green.
- [ ] Add a parse example exercising both forms; accept goldens after reading the diff.
- [ ] Commit.

---

### Task 2: IR + runtime — instance ids, `VInst`, routing by id

**Goal:** Represent and route named instances at runtime, with the ambient path byte-for-byte unchanged.

**Files:**
- Modify: `src/Wok/IR/Anf.hs` — `ROp` gains a leading `Maybe Atom` (the instance handle); `Handler` gains `hSelf :: Maybe Binder`. Update `collectRhs`/`collectHandler`/`renderRhs`/`renderOpArm` and all matches.
- Modify: `src/Wok/Interp/Value.hs` — add `VInst Unique` to `Value` (+ `Eq`/`renderValue`).
- Modify: `src/Wok/Interp/Machine.hs` — `Handle e h`: if `hSelf h = Just sb`, bind `sb -> VInst (nameUniq (bndName sb))` in `e`'s scope before installing `KHandle`. `evalRhs` `ROp minst lbl op as`: resolve `minst` (a `Maybe Atom`) to `Maybe Unique`; pass to `dispatchOp`. `dispatchOp`/`findHandler` take `Maybe Unique`: `Nothing` = nearest covering `(lbl,op)` (today); `Just u` = nearest `KHandle` whose `hSelf` unique == `u` covering `(lbl,op)`.

**Acceptance Criteria:**
- [ ] `Value` has `VInst Unique`; never equal to anything (like closures).
- [ ] `findHandler` takes the target `Maybe Unique`; ambient (`Nothing`) behaviour identical to today.
- [ ] `Handle` with `hSelf = Just sb` binds the self handle; with `Nothing` is unchanged.
- [ ] All 591 existing tests still pass (every existing `ROp` is `ROp Nothing …`, every `Handler` is `hSelf = Nothing`).

**Verify:** `cabal build`; `cabal test` → 591 pass. (End-to-end routing is exercised in Task 6; here, a focused HUnit test in `Spec.hs` can hand-build a 2-instance `Handle`/`ROp` IR and assert the right cell answers, if convenient.)

**Steps:**
- [ ] Update `Anf.hs` data decls + every total match (`collect*`, `render*`); compiler will list the sites.
- [ ] Add `VInst Unique` + `Eq` + `renderValue` ("<instance>").
- [ ] Thread the instance through `evalRhs`/`dispatchOp`/`findHandler`; bind self in `Handle`.
- [ ] `cabal build` then `cabal test` → 591.
- [ ] Commit.

---

### Task 3: Type checker — effect-as-type, type-directed dot, named-with inference

**Goal:** Type `State U64` in type position as a handle type; resolve `x.op` by `x`'s type (perform vs projection) with an `Accessor` constraint + annotation requirement; infer the two named-`with` forms.

**Files:**
- Modify: `src/Wok/TypeChecking/Types.hs` — a way to denote an instance-handle type (e.g. `TcEffect Text` tycon variant, kept out of the user data namespace), kind `KEffect -> KStar` for effect tycons.
- Modify: `src/Wok/TypeChecking/Infer.hs`:
  - In type translation (`translate*`/`walkArg`): an effect name (`lookupEffect`) used in type position → the handle type `TCon (TcEffect name) [args]`.
  - `inferExprW (Abs.EProj e (VarId (pos,label)))` (the fallback at ~1557): if `e`'s forced type is an effect-handle `TcEffect en [..]` → perform (resolve `label` in `en`'s `eiOps`, emit **no** ambient effect, build a typed perform node carrying the instance expression); if record → `inferProjection` (today); if a metavar → emit an `Accessor` constraint, or error "ambiguous accessor; annotate" if it would generalize unresolved.
  - `inferExprW (Abs.EWithNamed name fVar wargs body)`: desugar to `fVar wargs (\name -> body)` — like `EWithRun` (1705) but the lambda binder is `name`, not `_`.
  - `inferExprW (Abs.EWithNamedH name (ConId effect) arms body)`: like `inferHandler` but bind `name : TcEffect effect [params]` in `body`'s scope and record the self-binder for elaboration.
- Test: `test/typecheck-examples/` + goldens; `test/typecheck-fail-examples/` for the annotation error.

**Acceptance Criteria:**
- [ ] `prog : State U64 -> State U64 -> ()` with `count.get`/`count.set` checks; row omits `State`.
- [ ] `logged : State U64 -> () with IO` checks; State absent from the row.
- [ ] Two-same-type `sumProd` checks.
- [ ] Unannotated `bump c = c.get` errors "ambiguous accessor".
- [ ] Record projection still works (`p.x`); existing typecheck goldens unchanged.

**Verify:** `cabal build`; add typecheck examples + accept goldens (read diffs); `cabal test`.

**Steps:** TDD per criterion — failing typecheck-golden first, then implement, then accept. Commit per coherent chunk.

---

### Task 4: Elaboration — named perform → `ROp` with instance; named primitive → `Handle{hSelf}`

**Goal:** Lower the typed named-`with` and named-perform nodes to the Task-2 IR.

**Files:**
- Modify: `src/Wok/IR/Elaborate.hs`:
  - The typed perform node from Task 3 (a perform through an instance expression) → `ROp (Just instanceAtom) effect op atoms` (normalise the instance expression to an atom).
  - `EWithNamedH` typed node → `Handle handledBody (Handler … { hSelf = Just selfBinder })` (extend `elabKF` ~486; bind the self name as a fresh binder).
  - Ambient `TProjCon effect op` stays `ROp Nothing effect op …` (unchanged).
- Test: `test/anf-golden/`, `test/typed-anf-golden/`.

**Acceptance Criteria:**
- [ ] `count.get` elaborates to `ROp (Just (AVar count)) "State" "get" []`.
- [ ] `with self = State {…} in c self` elaborates to a `Handle` whose `Handler.hSelf` is the `self` binder.
- [ ] Ambient `State.get` elaboration unchanged; existing anf/typed-anf goldens unchanged.

**Verify:** `cabal build`; accept anf goldens (read diffs); `cabal test`.

**Steps:** TDD per criterion. Commit per chunk.

---

### Task 5: Carrier rule — type-based escape check

**Goal:** Reject a handle (or a closure capturing one) escaping its scope.

**Files:**
- Modify: a post-inference pass (new module `src/Wok/TypeChecking/Carrier.hs` or fold into `Infer.hs` after a binding is fully typed). A *carrier* = an expression whose free vars include an in-scope handle binder (binder whose type is `TcEffect …`). A carrier may appear only as a `.op`-perform head or a handle-typed application argument; never returned/stored/listed/closure-escaped.
- Test: `test/typecheck-fail-examples/` (return, constructor-store, list, escaping closure — one golden each); `test/typecheck-examples/` (local-closure-OK).

**Acceptance Criteria:**
- [ ] `with count = state 0 in count` (return), `Some count` (store), `[c1,c2]` (list), `\x -> count.set x` returned (closure) each error "instance handle cannot escape its scope".
- [ ] Local closure capture used in-scope is allowed.
- [ ] Bounded: one finite AST/free-var pass; no fixpoint.

**Verify:** `cabal build`; accept typecheck-fail goldens; `cabal test`.

**Steps:** TDD per criterion. Commit per chunk.

---

### Task 6: Prelude runners + end-to-end examples

**Goal:** Update `Control.wok` runners to pass their self-handle, and prove the whole feature end-to-end.

**Files:**
- Modify: `prelude/Std/Control.wok` — each runner's thunk takes the handle and uses the named-primitive form, e.g.
  `state : s -> (State s -> a with State s + eff e) -> (a, s) with eff e`
  `state i c = with self = State { s = i ; get -> s ; set x k -> k x () ; v -> (v, s) } in c self`
  (same for `reader`/`writer`/`except`).
- Test: `test/run-examples/NN-two-cells.wok`, `NN-sumprod.wok`, `NN-alias.wok`, `NN-mixed-row.wok` + goldens. Keep the existing untagged effect examples green.

**Acceptance Criteria:**
- [x] `with count = state 0 in with total = state 0 in prog count total` runs; two independent results. (`50-two-cells` → `(((), 1), 1)`)
- [x] `sumProd` (two same-type cells) yields the right pair. (`51-sum-prod` → `(((), 24), 10)`)
- [x] Aliasing (one cell passed as both args) is well-defined. (`52-aliasing` → `((), 12)`)
- [x] Mixed row: handle param beside an ambient effect; row is just the ambient one. (`53-mixed-row` → `((105, [5]), 105)`)
- [x] Untagged `with state 0 in … State.get` examples unchanged. (all existing run-goldens byte-identical)
- [x] Full `cabal test` green (619: 615 + 4 new).

**Note (per-activation routing landed here):** the prelude `state` reused twice mints both cells at
ONE `with self =` site, so site-`Unique` routing collapsed them. Implemented the design's anticipated
sound fix — `VInst (uniq, kontDepth)` + a tag on the `KHandle` frame — so two same-type cells route
apart (§5). Also fixed a carrier-rule false positive: a `let`-binder whose RHS is a perform
(`let old = cell.get`, result `U64`) was wrongly flagged a carrier by a free-var heuristic; it now
joins the carrier set only when its result type is a handle OR its RHS is a direct-escape form (a
bare handle or a handle-capturing closure).

**Verify:** `cabal run -v0 wok -- test/run-examples/50-two-cells.wok --run`; accept run goldens (read diffs); `cabal test`.

**Steps:** Update runners; add examples; accept goldens; full test. Commit.

---

## Dependencies
- Task 3 needs Task 1 (parse). Task 4 needs Tasks 2+3. Task 5 needs Task 3. Task 6 needs all.
- Tasks 1 and 2 are independent and can start in either order.

## Self-review note
Spec coverage: §3/§6 → T1; §5 → T2; §4.1/§4.2 → T3; §3.4/§3.5 + §4.1 lowering → T4; §4.3 → T5; §3.5 + §8 → T6. Aliasing (§4.4) falls out of T2's id routing + T6's example. Deferred items (§7) are out of scope by design.
