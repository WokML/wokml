# Effect-safety holes — executable fix plan (2026-07-05)

Status: **Phase A DONE (commit 6af0663) + Phase C done except C5. Phase B
EXECUTED AND FALSIFIED (2026-07-06): the D-C prototype gate STOPPED it — the
depth-indexed classifier was built, gated, and REVERTED (false positives the
rule cannot express; see
`2026-07-06-h2-depth-indexed-prototype-findings.md`). H2 remains OPEN,
dynamically backstopped. Phase D not started.** Plain checklist plan —
deliberately NOT a superpowers plan/tracker; execute tasks top-to-bottom in
this file, tick the boxes, commit per task. Written against branch
`feat/resume-launders-loadbearing` (tip 795b74d).

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

**OUTCOME (2026-07-06): FALSIFIED at the B2 gate; D-C STOP invoked; B1
reverted; B3-B5 not applicable.** The depth rule rejected the staged form
correctly but ALSO rejected the honest controls: `mkLam` (this plan's own
must-stay-accepting fixture), a pure-lambda probe (`mkPure g = \ x -> x` —
no perform anywhere), and two shipped fixtures (`poly-fp1-open-return-arrow`
= the FP-1 idiom pin, and `conc-producer-capture`, whose intended
`CarrierEscape` it masks). Root cause: the staged/honest distinction is a
property of the inference TRACE (which ambient was active at the `run`
application), and inference erases it before reconciliation — the app-site
`closeRow` (`Infer.hs:2492-2494`) collapses the shared row var, `emitRow`
drops bare residuals (`:3051`), and the lambda sub-ambient closes to `{}`
(`:2191`) — so both forms reconcile with IDENTICAL types. No classifier-only
rule can express the difference; D-B's "verified reasoning" for `mkLam` was
wrong in detail. Full trace, gate table, and future directions (emit-site
bare-residual check / row-plumbing rework / accept the dynamic backstop):
`docs/superpowers/2026-07-06-h2-depth-indexed-prototype-findings.md`.
H2 stays OPEN and dynamically backstopped; suite back to 2165 green.

- [x] **B1. Thread equation arity to the classifier.** (built, gated, then
      REVERTED per the B2 verdict — see OUTCOME above)
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
- [x] **B2. Prototype gate (D-C).** RAN; verdict = STOP. 4/2165 failed, all
      false positives (see OUTCOME above); prelude itself survived (the risk
      class `asCoro`/`par`/`race`/`step` all have arity == channel depth).
- [ ] ~~**B3. Fixtures.**~~ NOT APPLICABLE — the rule was reverted, so the
      `launder-staged-perform` death test cannot be added (the staged form
      still accepts today) and `mkOk`/`mkLam` accepts would pin nothing new.
- [x] **B4. Update claims.** Done for the falsified outcome: rung-3 spec §6
      "STRICTER" claim dropped (incomparable), C2/AS3 completeness scope
      already amended by the 2026-07-05 header note, F3 updated to
      OPEN-with-falsified-candidate (NOT "resolved" — the plan's original
      wording assumed the fix shipped).
- [ ] ~~**B5. Commit**~~ superseded — no compiler change to commit; the
      findings doc + plan/spec sync commit stands in its place.

## Phase C — H3: documentation truth (mechanical, can interleave)

- [x] **C1. Explainer rewrite** (`docs/effect-handlers-explainer.html`, item 1
      + header sub). New state: rungs 1-3 shipped THEN superseded — the whole
      apparatus was deleted for scoped rigid skolemization of trapped effect
      vars (branch `feat/resume-launders-loadbearing`); remaining open =
      F1 (wrapped carrier), F2→H1 (now: the 0-arg bypass, fixed in Phase A),
      H2 staged-perform (OPEN — Phase B falsified at the gate; explainer says
      so and points at the findings doc). Historical rung narrative kept,
      marked superseded. (Done 2026-07-06.)
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
- [x] **C5. Memory hygiene** (assistant-side, zero repo cost): update the
      `explicit-resume-effect-laundering` memory (no longer OPEN) and trim
      MEMORY.md under its 24.4KB limit so the index stops truncating.
      (Done 2026-07-06: memory updated with the Phase-B falsification;
      MEMORY.md 27.1KB → 20.0KB, detail verified present in topic files
      before trimming index lines.)

## Phase D — optional: the one-shot runtime oracle

- [x] **D1. Single-use continuation guard.** (Done 2026-07-06.) Per-capture
      `OneShotFlag` on `VCont`/`VContP` (minted in `dispatchOp` with the
      activation tag, asserted in `enter` → new `OneShotViolation` error),
      gated by `WOK_DEBUG_ONESHOT=1` read once per process — default OFF, so
      production keeps the free multi-shot capability per the one-shot spec
      §9. Enablement is a FULL-SUITE oracle run (`scripts/oneshot-oracle.sh`,
      mirroring the `asan-runtime.sh` convention — a strict superset of the
      planned multiplicity+effect corpora), because the suite deliberately
      pins the machine's free-multi-shot semantics in one hand-built-IR test;
      that test now self-adapts and under the env var expects
      `OneShotViolation`, doubling as the END-TO-END negative control (it IS
      a multi-shot arm with the frontend check bypassed). Three `enter`-level
      unit tests mutation-confirm the assert + pin that a flag-less
      continuation stays multi-shot. DIFFERENTIAL VERDICT: the law-admitted
      corpus is violation-free; exactly SIX run-golden `*multishot*` fixtures
      abort — law-REJECTED programs (`--run` refuses them via
      `elaborateCheckedFull`; the run-golden harness deliberately uses the
      UNCHECKED elaborator to pin machine capability) — so the script asserts
      set-equality on them as six wok-source negative controls (a missing
      abort = oracle decay; an extra failure = a law miss — both exit
      non-zero). EXECUTION FINDING: the first flag
      implementation initialized the ref with `tag `seq` False`; strictness
      analysis + full laziness collapsed EVERY capture onto one floated
      process-global IORef (86/2168 oracle-run failures, single-apply
      programs aborting from unrelated tests' applies) — fixed with a
      non-foldable initial value (`tag < 0`), documented in
      `Value.hs:mkOneShotFlag`. The RC machine needs no oracle (its
      `moveOutCont` frees the shell at first resume).
- [x] **D2. Update one-shot spec §9 note** (folds into C4). (Done 2026-07-06:
      §9 status note now records the shipped oracle + script + negative
      control.)

## Ship gate (whole plan)

- [x] Full suite green (2168 = 2165 + 3 oracle unit tests), `hlint` clean on
      the new code (pre-existing hints untouched); D shipped → sanitizer run
      2026-07-06: C-runtime portion of `asan-runtime.sh` clean; the `interp`
      ASan mode consciously SKIPPED — D's diff touches only the pure-Haskell
      reference machine (no RC-machine or C-runtime code in the diff), which
      that mode does not exercise.
- [x] The H1 reproducers reject; the honest-form controls accept; `--run`
      corpus unchanged. (H2's reproducer STILL ACCEPTS by design — Phase B was
      falsified at the gate; H2 is open + dynamically backstopped.)
- [x] ONE whole-branch adversarial review before merge (per CLAUDE.md; the
      load-bearing gate) — RAN 2026-07-06 on the post-795b74d commits
      (6af0663 H1 fix + 8e9daea Phase-D oracle): verdict SHIP-WITH-FIXES,
      all findings FIXED in a87d910. MAJOR: a user `effect IO` override
      re-opened the CAF bypass (entry ambient seeded by LABEL; emitEffect
      discharges by label; the permitted override is handleable) — 7-line
      reproducer typechecked then crashed at --run; fixed by consulting
      isGroundIO at the seed (override ⇒ closed empty entry ambient) + death
      test caf-user-io-override-bypass. MINOR: oracle script leaf-name
      collision brittleness — now asserts each expected failure is a unique
      "run golden" leaf. NIT: documented why the 7th multishot fixture
      (37-known-reentrant, dynamically single-shot) is excluded. The review
      also verified: handled-CAF/point-free/pattern-bind non-bypasses, oracle
      false-positive hunt (200-capture same-hTag loop clean), all appliers
      route through enter, death-test load-bearing-ness by mutation. Suite
      2169 green + oracle script green after fixes. The gate caught a real
      soundness hole AGAIN (4th consecutive slice).
- [x] User-run `/code-review high` (2026-07-06): 8 finder angles + 1-vote
      verify → 8 CONFIRMED (all quality/diagnostic, no soundness blocker) +
      2 PLAUSIBLE (accepted as-is: oracle-script tasty-format coupling fails
      loud; NOINLINE micro-cost). All CONFIRMED fixed in 6eb4fe4: positioned
      trapped-effect diagnostics via shared reconcileDeclared (spec D3/Q1
      finally fulfilled; 27 goldens regenerated), shared effTailVar, empty
      `effect IO = {}` override rejected (override-once now airtight),
      resumeContTyFor comment rewritten, RowRef + finishApp dead code
      removed, assertApplyOk test helper. Known-filed F1/H2/A4 were
      surfaced-and-excluded as already documented. Suite 2170 green.
      **MERGED to main (clean FF e395d34..6eb4fe4, 2026-07-06, local not
      pushed).**

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

H2 staged launder (STILL ACCEPTS — Phase B falsified at the gate):
```
module Main
import Std.Base
import Std.Control
mk : Suspension U64 U64 U64 (row e) -> U64 -> U64 with eff e
mk g = let r = run g 0 in \ x -> r + x
main : U64
main = 0
```

H2 honest controls (accepting; under the B1 prototype, `mkLam` REJECTED —
the false positive that triggered the D-C STOP):
```
mkOk : Suspension U64 U64 U64 (row e) -> U64 -> U64 with eff e
mkOk g x = run g x
```
```
mkLam : Suspension U64 U64 U64 (row e) -> U64 -> U64 with eff e
mkLam g = \ x -> run g x
```
