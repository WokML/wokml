# Effect-safety holes — executable fix plan (2026-07-05)

Status: **Phase A DONE (commit 6af0663) + Phase C mostly done (C1/C5 open).
Phase B and D not started.** Plain checklist plan — deliberately NOT a
superpowers plan/tracker; execute tasks top-to-bottom in this file, tick the
boxes, commit per task. Written against branch `feat/resume-launders-loadbearing`
(tip 795b74d).

**Execution findings (2026-07-05, Phase A):**
- The entry ambient is `{IO}` (closed), NOT `{}`: ground IO is discharged by
  running the program, never by a handler (`isGroundIO`,
  `IOEffectNotHandleable`), and the whole FFI corpus (106 tests) performs IO
  from `main` with no gate. D-A is refined accordingly.
- NEW insight from triage: capability-style named-instance functions
  (`prog : Exn -> U64` taking a HANDLE) must NOT carry a `with Exn` row — a
  named handler deliberately does not discharge by label (performs route
  through the handle; `Infer.hs` "NO ambient-row discharge"), so such a row
  demands a discharge nothing provides. Two rc-m2b fixtures carried the
  decorative row and typechecked only via the hole; rows dropped. Any user
  code with that pattern will surface the same way.
- Residual corner (A4): `emitRow`'s bare-row-var catch-all is still `pure ()`;
  a CAF performing a still-polymorphic residual would bypass `emitEffect`. Not
  constructible in any shape found (CAFs have no params, so residuals resolve
  concrete before being performed). Recorded here; revisit if carriers become
  first-class.

Source: adversarial pressure-test of the one-shot-multiplicity and
trapped-effect-skolemization theses (session 2026-07-05). All findings verified
with runnable reproducers against the built compiler (reproducer sources are
inlined below; nothing depends on files outside the repo).

## Findings being fixed

- **H1 (soundness crash, the serious one).** Every 0-arg binding bypasses the
  entire effect discipline. `bad : U64; bad = let v = Log.emit 1 in 2`
  TYPECHECKS and crashes at `--run` with `NoMatchingHandler`. No coroutines
  needed. The identical body with one parameter is correctly rejected
  (`UndischargedEffect Log`) — arity is the exact discriminator (verified both
  ways). Root cause: `typeEquationWith`'s zero-parameter top-level branch
  (`Infer.hs:3654-3663`) seeds the ambient as a FRESH OPEN row var and closes it
  after the body, but never reconciles it against anything — effects are
  collected, then dropped. This SUBSUMES the rung-3 spec's F2 follow-up
  (its `drive : U64` shape leaks *because* it is 0-arg, not primarily because
  of `emitRow` tail-dropping) and is the same family as the rung-2 note's
  "point-free 0-arg" observation.
- **H2 (staged-perform false negative).** The trapped-var classifier is
  per-signature, not per-arrow: a var with a channel on an arrow BELOW the
  equation's activation depth counts as dischargeable, so the body can perform
  it at partial-application time and launder. Accepted today:

  ```
  mk : Suspension U64 U64 U64 (row e) -> U64 -> U64 with eff e
  mk g = let r = run g 0 in \ x -> r + x        -- performs e at stage 1
  ```

  The concrete analogue (`with Log` on the same shape) is REJECTED — a
  polymorphic/concrete inconsistency. Dynamically backstopped today (eager
  `start` + second-class carriers; verified: the exploiting caller is rejected
  at the `start` site, the under-handler form runs correctly), so this is a
  type-honesty hole, not a crash. Falsifies the rung-3 spec's AS3 and the C2
  claim as worded; the deleted rung-1 recording (closed ambient + bare
  residual) would have caught it.
- **H3 (doc rot).** Explainer item 1 is two generations stale; the rung-3 spec
  D1 omits `effectRelevantRowVars` (the shipped rule is
  `effRel ∧ ¬dischargeable`, commit 1c75751) and has drifted line refs; the
  four superseded rung-era specs have no forward pointer to the skolemization
  end-state; the one-shot spec §2's value-restriction argument is imprecise;
  the one-shot spec §9's recommended runtime oracle was never shipped.

## Locked decisions (do not re-litigate during execution)

- **D-A: top-level 0-arg bindings are pure, `main` included.** A 0-arg binding
  of ground type has no arrow to carry a `with` row, so its contract IS the
  empty row; enforcing it is the same "no `with` = pure" law functions already
  obey. Any effect a CAF performs is unhandleable-by-construction under
  module-init forcing, and even under lazy first-reference forcing we choose
  rejection for signature honesty (a handler at the forcing site would be
  invisible in any type). Nested/local 0-arg bindings keep inheriting the
  enclosing ambient (the `both u = let a = useIO () …` case, `Infer.hs:3649`).
- **D-B: H2's fix is depth-indexed dischargeability inside the existing
  skolemization architecture** (classifier change only), NOT a resurrection of
  rung-1 emit-site recording. A spine effect-row tail is a channel iff it sits
  at arrow depth == the equation's parameter count (where `effRowAtDepth`
  already reads the ambient seed, `Infer.hs:3618`); deeper spine tails and
  non-spine positive-arrow tails belong to returned closures, whose rows are
  inferred and reconciled separately (verified reasoning: honest
  `mk g = \x -> run g x` still accepts because the lambda row unifies with the
  rigid at reconciliation; staged form clashes rigid-vs-`{}`).
- **D-C: H2 ships behind a C1-style prototype gate** (same discipline that
  falsified the naive-rigid thesis): full corpus + adversarial battery green
  BEFORE deleting the old classifier arm. If the corpus shows a false positive
  the depth rule cannot express, STOP and write a findings doc instead of
  patching around it.
- **D-D: reuse `UndischargedEffect`** for both H1 and H2 rejections (consistent
  with rung-3 D3; keeps golden shapes stable).

## Phase A — H1: close the 0-arg hole (soundness; do first)

- [x] **A1. Seed the top-level 0-arg ambient closed-empty.**
      In `typeEquationWith`'s `pTys == []` / `Nothing` enclosing-ambient branch
      (`src/Wok/TypeChecking/Infer.hs:3654-3663`): replace the
      `ambient0 <- freshRVar` seed with the closed empty row (mirror what a
      no-`with` sig gets at `Infer.hs:561`, `TFun -> … CREmpty`). `emitEffect`
      then rejects at the emit site with a positioned `UndischargedEffect`,
      exactly as it does for a closed function sig (the 1-arg control probe
      shows the expected error shape: `UndischargedEffect (Just (r,c)) "Log"`).
      Delete the now-wrong comment lines 3655-3657 and state the new contract:
      "a top-level value evaluates with nowhere to discharge effects — its
      ambient is the empty row; performing into it is an error."
      Note: `closeRow ambient` after the body becomes a no-op on an
      already-empty row — keep or drop it, whichever reads cleaner.
- [x] **A2. Corpus triage.** `cabal test` full suite. Expected fallout classes:
      (a) fixtures whose 0-arg bindings perform effects only under handlers —
      must stay green (handlers discharge before the ambient);
      (b) fixtures that DELIBERATELY characterized the hole (grep
      `typecheck-examples` + `run-examples` for 0-arg bindings calling
      `run`/`step`/`start` or performing ops at top level) — flip to
      death tests, per-file conscious decision, note each in the commit body;
      (c) anything else newly red = investigate before touching goldens.
      Check `coro-residual-handled.wok`'s comment ("main does not obligate
      effect rows") — after A1 that comment is stale; update it.
- [x] **A3. Death tests.** Add to `test/typecheck-fail-examples/` +
      `typecheck-fail-golden/`:
      `caf-plain-effect.wok` (the H1 reproducer above — plain concrete effect
      in a ground CAF), and `caf-local-start-residual.wok` (the F2 shape:
      `drive : U64; drive = case start producer of { Completed r -> r ;
      Suspended a g -> run g 5 }` with a `Coro U64 U64 + Log` producer).
      Both must reject `UndischargedEffect`. Add ONE accept fixture pinning the
      nested-inheritance behavior (local 0-arg let performing an effect inside
      a function that declares it) so A1's scope is provably top-level-only.
- [x] **A4. Known residual corner (document, don't fix here).** `emitRow`'s
      bare-row-var catch-all is still `pure ()`; a CAF performing a *still
      polymorphic* residual would not hit `emitEffect`. Not constructible in
      any shape we found (a CAF has no params, so residual rows resolve
      concrete by the time they're performed), but record it in the rung-3
      spec's follow-ups section (Task C2 below) so it isn't lost.
- [x] **A5. Commit** (`fix(effects): top-level 0-arg bindings obligate the
      empty effect row — closes the CAF effect bypass`), goldens regenerated,
      `hlint` clean (ignore `src-generated`).

## Phase B — H2: depth-indexed dischargeability (type-honesty)

- [ ] **B1. Thread equation arity to the classifier.**
      `dischargeableRowVars` (`Infer.hs:364`) gains an `Int` arity parameter:
      the `pos` walk tracks spine depth (increment when descending `pos b` of a
      spine `CTArr`); collect `effTail` ONLY at depth == arity. Non-spine
      arrows reached through `neg a` / `CTCon` args keep current polarity
      behavior for recursion but do NOT contribute channels at any depth
      (per D-B they belong to closures/callbacks, reconciled separately).
      Arity source: `freezeSigSkolems` is called from `finalizeGroup`/
      `finalizeGroupTyped` (`Infer.hs:3387/3424`), which see only `(name, tv)`
      — thread a `Map Name Int` of equation param counts (available where the
      group's equations are walked; `typeEquationWith` computes it as
      `length pTys`, `Infer.hs:3603`) through the group-finalization path.
      Pattern binds and 0-arg bindings: arity 0. Multi-clause groups: clauses
      share arity (verify; if a mixed-arity group is representable, take the
      minimum and leave a comment).
- [ ] **B2. Prototype gate (D-C).** Before deleting anything: run the full
      suite + `typecheck-examples` + `run-examples` + prelude with the new
      classifier active. Triage every flip:
      newly-rejected accept fixture = genuine staged leak (reclassify with a
      D4-style `with eff e`-channel variant + keep the leaking form as a death
      test) OR a false positive → STOP per D-C. Pay attention to prelude
      combinators whose equation arity is smaller than their sig's arrow count
      (`asCoro`, `par`, `race`, `step` partial forms) — these are exactly the
      risk class.
- [ ] **B3. Fixtures.** Death test `launder-staged-perform.wok` (the H2 `mk`
      reproducer) → `UndischargedEffect`. Accept fixtures: `mkOk g x = run g x`
      (channel at depth == arity, the honest curried form) and the
      returned-lambda honest form `mk g = \ x -> run g x` (channel below
      activation but perform inside the returned closure). All three verified
      shapes from the pressure-test session.
- [ ] **B4. Update claims.** In the rung-3 spec: reword C2/AS3 to scope
      completeness to "vars with no positive channel at the body's activation
      depth" and drop "§6 scoped rigidity is STRICTER than the old apparatus"
      (they are incomparable — rung-1 caught the staged form, skolemization
      pre-B1 did not). Add H2 as resolved follow-up F3.
- [ ] **B5. Commit** (`fix(effects): depth-indexed dischargeability — a
      channel below the activation arrow no longer launders staged performs`).

## Phase C — H3: documentation truth (mechanical, can interleave)

- [ ] **C1. Explainer rewrite** (`docs/effect-handlers-explainer.html`, item 1
      + header sub). New state: rungs 1-3 shipped THEN superseded — the whole
      apparatus was deleted for scoped rigid skolemization of trapped effect
      vars (branch `feat/resume-launders-loadbearing`); remaining open =
      F1 (wrapped carrier), F2→H1 (now: the 0-arg bypass, fixed in Phase A if
      done), H2 staged-perform (fixed in Phase B if done). Keep the historical
      rung narrative but mark it superseded, matching the doc's own style.
- [x] **C2. Rung-3 spec sync**
      (`docs/superpowers/specs/2026-07-03-rung3-rework-scoped-rigid-trapped-effect-skolemization-spec.md`):
      status `in_review` → implemented/shipped-on-branch with a dated header
      note (house style: the loadbearing spec's SCOPE REALITY note);
      D1 corrected to the shipped two-classifier rule
      (`effectRelevantRowVars isCarrier ∧ ¬dischargeableRowVars`, define both,
      cite commit 1c75751); refresh line refs (classifier `Infer.hs:364`,
      `effectRelevantRowVars :398`, `freezeSigSkolems :420`, reconciliation
      `:3390`/`:3456`); rewrite F2 with the verified root cause (0-arg
      exemption; the same body 1-arg rejects) pointing at Phase A; add the
      A4 polymorphic-CAF-residual note; add F3 = H2 pointing at Phase B.
- [x] **C3. Supersession pointers.** Top-of-file one-liner on each of:
      `2026-07-02-resume-launders-effect-row-loadbearing-spec.md`,
      `2026-07-02-resume-launders-rung2-provenance.md`,
      `2026-07-03-resume-launders-rung2-caller-root-provenance-design.md`,
      `2026-07-03-inner-abstraction-effect-laundering-design.md`:
      "The rung-1/2/3 mechanism this doc describes was DELETED (2026-07-03)
      and replaced by scoped rigid trapped-effect skolemization — see
      2026-07-03-rung3-rework-scoped-rigid-trapped-effect-skolemization-spec.md.
      Retained as design history."
- [x] **C4. One-shot spec §2 tightening**
      (`2026-06-09-one-shot-multiplicity-analysis-design.md`): replace the
      "requires *duplication* of the continuation" sentence with the precise
      argument — Harper–Lillibridge breaks polymorphism with a SINGLE throw
      because undelimited callcc lets the generalization context be entered
      twice (normal return + throw); wok is safe because a delimited `perform`
      has NO normal-return path separate from resume, so ≤1 resume ⇒ every
      let-generalization context evaluates ≤1 time ⇒ no polymorphic
      re-binding; M3 stored continuations delay but cannot duplicate the
      resume. Add a dated note to §9 that the recommended runtime oracle is
      shipped/not-shipped depending on Phase D's outcome.
- [ ] **C5. Memory hygiene** (assistant-side, zero repo cost): update the
      `explicit-resume-effect-laundering` memory (no longer OPEN) and trim
      MEMORY.md under its 24.4KB limit so the index stops truncating.

## Phase D — optional: the one-shot runtime oracle

- [ ] **D1. Single-use continuation guard.** A mutable used-flag on the
      continuation value (`VCont`/`VContP`, `src/Wok/Interp/Machine.hs`),
      asserted on second application; gated (env var `WOK_DEBUG_ONESHOT=1` or
      a cabal flag alongside `asan`) so production keeps the free multi-shot
      capability per the one-shot spec §9. Enable it under the existing test
      harness for the `multiplicity-*` and effect corpora as a differential
      check on the static law. Mutation-confirm the oracle itself (hand-run a
      multi-shot arm with the frontend check disabled → must abort), per the
      repo's negative-control convention.
- [ ] **D2. Update one-shot spec §9 note** (folds into C4).

## Ship gate (whole plan)

- [ ] Full suite green (~2135 + new fixtures), `hlint` clean, no ASan needed
      for A/B/C (type-checker only); D touches the interpreter → run the
      existing sanitizer script once if D ships.
- [ ] The H1 and H2 reproducers reject; the three honest-form controls accept;
      `--run` corpus unchanged.
- [ ] ONE whole-branch adversarial review before merge (per CLAUDE.md; the
      load-bearing gate), then user-run `/code-review`.

## Reproducer appendix (for fixtures; all verified 2026-07-05)

H1 minimal (must reject after A1):
```
module Main
import Std.Base
effect Log = { emit : U64 -> () }
bad : U64
bad = let v = Log.emit 1 in 2
main : U64
main = bad
```

H1/F2 coroutine form (must reject after A1; today: runtime NoMatchingHandler):
```
module Main
import Std.Base
import Std.Control
effect Log = { emit : U64 -> () }
producer : () -> U64 with Coro U64 U64 + Log
producer u =
  let x = Coro.suspend 7 in
  let v = Log.emit x in
  x + 100
drive : U64
drive = case start producer of
  Completed r   -> r
  Suspended a g -> run g 5
main : U64
main = drive
```

H2 staged launder (must reject after B1):
```
module Main
import Std.Base
import Std.Control
mk : Suspension U64 U64 U64 (row e) -> U64 -> U64 with eff e
mk g = let r = run g 0 in \ x -> r + x
main : U64
main = 0
```

H2 honest controls (must stay accepting after B1):
```
mkOk : Suspension U64 U64 U64 (row e) -> U64 -> U64 with eff e
mkOk g x = run g x
```
```
mkLam : Suspension U64 U64 U64 (row e) -> U64 -> U64 with eff e
mkLam g = \ x -> run g x
```
