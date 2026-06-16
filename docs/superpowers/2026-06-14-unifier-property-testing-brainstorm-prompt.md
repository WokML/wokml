# Brainstorm prompt — property-testing the unifier (Tier A)

**What this is.** A ready-to-paste prompt to start a *new* session that designs a
property test for the type unifier. It's the cheap, targeted half of "should we
property-test the typechecker too" — it aims straight at two already-known, still-open
bugs (a row-unify hang and a `rigidUnify` panic) without needing a well-typed-program
generator. The expensive end-to-end half (a type-directed generator feeding the whole
pipeline) is deliberately **out of scope** here; see "Deferred (Tier B)" at the end.

**How to use it.** Open a fresh session in this repo and paste the block below. It's
phrased to trigger the brainstorming skill (design first, code later) and to make the
new session verify the summary against the actual code before trusting it.

---

```
Brainstorm a property test for the type UNIFIER. Do NOT write code yet — settle the
design first, then write a spec under docs/superpowers/specs/.

Why this, and why now:
- The whole test suite has exactly ONE property test today (the RC differential in
  test/Spec.hs); it covers the BACK half of the pipeline (ANF -> Perceus -> RC
  interpret) and bypasses the typechecker entirely. The front half (parse ->
  typecheck/infer -> elaborate) has only unit + golden tests.
- The pipeline is: source -> parse (Wok.Loader) -> typecheck (TC.inferProgramWith)
  -> elaborate to ANF (Wok.IR.Elaborate.elaborateModule) -> Perceus.insertRC -> RC
  interpret; see src/Wok/Pipeline.hs.
- There are KNOWN, verified, still-open bugs in this exact area (memory
  [[repo-review-backlog-2026-06]]; doc at docs/superpowers/2026-06-12-repo-review-backlog.md
  -- verify it's still there): a "row-unify hang" (non-termination) and a
  "rigidUnify panic" (a crash). Non-termination and panics on random input are
  exactly what property testing catches best, so this is targeted, not speculative.

Goal: a QuickCheck property (or small family) over RANDOM TYPES that exercises
`unify` and its helpers (occurs check / level adjustment, zonk) and asserts the
metatheory holds. Candidate properties to weigh during the brainstorm:
  1. TERMINATION  -- unify finishes within a step/time budget (targets the row-unify
                     hang). Decide how to bound it (fuel, timeout, or a step counter
                     threaded through the TC monad).
  2. NO PANIC     -- unify never throws/`error`s; it either succeeds or returns a
                     typed unification error (targets rigidUnify panic).
  3. MGU VALIDITY -- if unify a b SUCCEEDS, then after it, zonk a == zonk b
                     (the substitution it built actually unifies the two types).
  4. REFLEXIVITY  -- unify a a always succeeds.
  5. SYMMETRY     -- unify a b succeeds iff unify b a succeeds (same outcome class).
  6. ZONK IDEMPOTENCE -- zonk (zonk t) == zonk t.

Key facts to verify and design around (read the code first):
- The unifier is `unify :: SourceSpan -> Type s -> Type s -> TC s ()` in
  Wok.TypeChecking.Unify -- it runs in the ST-based `TC s` monad with MUTABLE type
  variables (STRef (TVar s)), doing in-place unification, plus occursAdjust,
  unifyVar, unifyRow. So the property harness must build/run in that monad (runST /
  the test harness the existing unit tests use). The existing unit tests
  (unifyTests, unifyWalksTests, rowUnifyTests, zonkTests, generalizeTests,
  solveTests in test/Spec.hs) are the template for setting up the monad and for
  instantiating an external type into a fresh `Type s` and zonking back.
- External vs internal types: CType (Wok.TypeChecking.Types) is the external/zonked
  type; `Type s` is the internal mutable one. The generator most likely produces
  CType, the harness instantiates it into `Type s` (with some fresh unification
  variables), unifies, then zonks back to CType to compare.
- Types are KINDED (memory [[kinded-ty-representation]]: CType/CRow merged into one
  kinded representation; rows are a kind). A random-type generator MUST respect kinds
  (star vs row) -- either generate only well-kinded types, or deliberately test that
  ill-kinded input is rejected gracefully (a typed error) rather than a panic. Decide
  which in the brainstorm.
- Rows are the subtle part (and where the known hang lives): same-name labels can
  coexist in a row, rows have tails (possibly shared variables), and ordering is up
  to permutation. The generator needs to produce these shapes (duplicate labels,
  shared/odd tails) for the termination property to have teeth.

Scope boundaries:
- Unifier + its direct helpers (occurs/level adjust, zonk) ONLY. NOT full type
  inference of programs, and NOT a well-typed-program generator -- that end-to-end
  "type safety over the whole pipeline" test is a separate, larger effort (Tier B),
  explicitly out of scope here.
- Before designing the generator, consider whether the 2-3 named backlog bugs are
  cheaper to FIX directly first (the property test then guards against regressions
  and finds their unknown siblings) -- raise this trade-off with me.

Please read src/Wok/TypeChecking/Unify.hs, src/Wok/TypeChecking/Types.hs, the
existing unify/zonk/row unit tests in test/Spec.hs, and the repo-review backlog doc,
then brainstorm with me -- propose 2-3 approaches (e.g. generate CType and round-trip
through the monad vs. generate `Type s` directly; fuel vs timeout for termination)
with trade-offs and a recommendation, before settling on one and writing the spec.
```

---

## Deferred (Tier B) — the end-to-end version, for later

A **type-directed generator of well-typed surface programs** run through the *whole*
pipeline (typecheck → elaborate → RC + reference interpret), asserting type safety
(well-typed ⇒ no runtime type error, result type matches the inferred type) +
differential agreement + heap-empty. This is the highest-value test — the only thing
that catches the "elaboration scope leak → silently wrong values" class — but
generating well-typed terms is a research-grade subproject, and the language surface
(effects, typeclasses) is still moving. Revisit after M1.5/M2. Note it would feed
*real elaborator output* into the RC pass, which never emits the §1 direct-move +
forward shape — so it is **complementary** to the hand-built ANF join-cluster
generator, not a replacement for it.
