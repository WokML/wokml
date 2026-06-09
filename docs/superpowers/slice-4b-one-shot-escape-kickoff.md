# Slice 4b kickoff prompt — the one-shot escaping continuation (typed, second-class Future)

Paste the block below into a fresh session to start slice 4b. It is the converged framing
after extended design discussion: the minimal ESCAPE primitive (not a scheduler, not
parallelism), as a TYPE-SYSTEM slice with a CEK reference semantics, under a HARD
decidability / HM-principality constraint (no rank-2, no linear types).

```
Work on the next foundational slice for the wok language (repo: /Users/zy/wokml):
SLICE 4b — THE ONE-SHOT ESCAPING CONTINUATION (a typed, second-class, region-confined,
affine Future). This is the MINIMAL escape primitive, NOT a scheduler and NOT parallelism.
It is a TYPE-SYSTEM slice with a CEK reference semantics. Branch from main first
(feat/one-shot-escape). Standing rules: FULL-BRANCH review before any merge to main; I
prefer clarifying questions in prose (not multiple-choice).

============================================================================
WHAT THIS IS ABOUT (concept — read before any code)

A continuation has two axes. COUNT is settled: one-shot is the LAW (affine no-dup analysis,
Wok.IR.Multiplicity). This slice is the ESCAPE axis, in its SMALLEST form: a continuation
captured, parked, and resumed EXACTLY ONCE, LATER, after its handler's extent has ended.

- Effect handlers are BOUNDED delimited continuations (perform = shift, handler = reset,
  resume : T -> R bounded by R, T, and one-shot). Raw delimited control is "too
  unrestricted" because those bounds vanish. THE BOUND IS THE DESIGN.
- LAYER SEPARATION: a CONTROL-FLOW CAPABILITY is the typed PRIMITIVE that grants bounded
  one-shot capture/resume, provided by a user handler. A SCHEDULER is a POLICY over it.
  Lazy / async / concurrency / parallelism are also POLICIES. This slice types the
  CAPABILITY ONLY; ALL policies are DEFERRED. The capability must be POLICY-AGNOSTIC.
- A FUTURE is the capability's handle: a ONE-SHOT suspended computation (a parked
  continuation + its residual capabilities), resumed EXACTLY ONCE. "Re-entry" = the
  captured context is RE-ESTABLISHED at that single resume — NOT entered repeatedly (that
  would be multi-shot, forbidden).

============================================================================
HARD CONSTRAINT: DECIDABLE, HM-PRINCIPAL INFERENCE — NO RANK-2, NO LINEAR TYPES

The type system MUST stay decidable with HM-style PRINCIPAL inference (+ row polymorphism +
the existing second-class-handle discipline). Two mechanisms are OUT OF BOUNDS:
  - RANK-2 / higher-rank types (runST-style `forall s.` region branding). (Rank-2 inference
    is technically decidable, but it breaks HM PRINCIPALITY and needs annotations /
    bidirectional typing — complexity this language is choosing not to take on.)
  - FULL LINEAR/AFFINE TYPES on freely-flowing first-class values.

THE LOAD-BEARING DECISION (strongly preferred; confirm in brainstorming):
Make the FUTURE SECOND-CLASS — reuse the named-instance second-class discipline (scoped to
its `with`; not returnable, not storable in first-class data, not captured by an escaping
closure). This ONE choice satisfies BOTH constraints at once:
  - LIFETIME BOUND without rank-2: second-class-ness is a STRUCTURAL well-scopedness check,
    not a `forall s` region variable. Decidable, principal, no HM change. Optionally
    REINFORCED by USE-confinement via the row: `await` requires the capability — ideally a
    SPECIFIC NAMED instance, via wok's shipped per-activation routing — in the row, so a
    leaked Future is INERT/un-awaitable outside its capability (a harmless leak, not
    unsoundness). Pure row-HM, principal, no rank-2.
  - CARDINALITY BOUND without linear types: a second-class Future can't be stashed in data
    or returned, so its uses stay SYNTACTICALLY LOCAL — the affine (no-await-twice) check
    stays a LOCAL analysis (slice-X-flavored), NOT program-wide linear types.

So NO-RANK-2 and NO-LINEAR-TYPES are the SAME decision: second-class Futures. (First-class
Futures would need BOTH rank-2 region branding AND linear types; second-class need NEITHER.)

THE TRADE TO ACCEPT: users cannot freely stash/return Futures. Bulk control combinators
(par / select / awaitAll) are CAPABILITY-PROVIDED PRIMITIVES (the runtime holds the
continuations BELOW the second-class boundary), not user code over stored Future-lists. The
real reshaping risk is no longer "rank-2?" but "does a REQUIRED use case genuinely need a
FIRST-CLASS Future?" If yes, STOP and surface it — THAT pulls the heavy machinery back in.

============================================================================
THE CRUCIAL QUESTION (escape semantics — everything is downstream)

What does resuming a continuation AFTER its handler returned mean?
  1. CAPTURE BOUNDARY: k delimited up to its handler, or the whole computation?
  2. CAPABILITY RECONSTRUCTION: the resumed k re-performs effects whose handlers returned.
     This must be a TYPE guarantee (k's residual row = exactly what the capability re-
     establishes via deep capture), NOT a runtime reroute. A re-performed effect with no
     re-establishable handler must be a TYPE ERROR.
  3. SHARED vs PRIVATE capabilities: effects handled INSIDE the captured continuation are
     private (carried by k); effects handled OUTSIDE the capability boundary are SHARED
     across resumptions (-> ndet/races when mutable). The type system must distinguish
     these relative to the capture point. (Soundness crux for future concurrency + state.)
  4. ANSWER ROUTING: the arm returned once; resuming k produces the answer a SECOND time.
     It must flow REGION-INTERNALLY to the consuming continuation, never escaping the
     capability scope. Confirm this closes slice-3's answer-join question for escape.
  5. ONE-SHOT ACROSS ESCAPE: the Future is awaited XOR cancelled = the affine discipline
     with two eliminators. TYPE resume-xor-cancel now (cancellation RUNTIME deferred).

CAPTURE-BOUNDARY FORK against the CEK machine: full-continuation capture vs capability-
config-delimited (k up to the capability handler + a typed config = residual row + result
type + result destination -- the existential a second-class Future hides).

============================================================================
THE THREE BOUNDS (the spec spine)

1. LIFETIME / REGION — via SECOND-CLASS Futures (+ optional row use-confinement). NO rank-2.
   (See the DECIDABILITY constraint.)
2. EFFECT — the row discipline at the delimiter + the shared/private split (crucial Q #3).
   Deep capture carries the handlers, so re-entry is well-typed BY CONSTRUCTION iff the
   continuation's row = what the capability re-provides. The "capability config" for future
   relocation is this residual row made into a descriptor — but RELOCATION IS DEFERRED.
3. CARDINALITY — affine on the Future (no-await-twice), kept a LOCAL analysis BECAUSE
   Futures are second-class. NO linear types. Type resume-xor-cancel.

============================================================================
DECIDED DIRECTION (confirm, don't relitigate)

- DECIDABLE, HM-PRINCIPAL inference is a HARD constraint. No rank-2. No full linear types.
  Second-class Futures are the mechanism (see DECIDABILITY).
- TYPE SYSTEM + CEK reference semantics; design the bounds to be MULTICORE-SOUND now
  (data-race-free via second-class confinement + affine); DEFER the production/multicore
  runtime.
- The capability is POLICY-AGNOSTIC; schedulers/lazy/async/concurrency/parallelism are
  DEFERRED policy handlers over it.
- Value restriction is GONE (one-shot-as-law) — do not reintroduce it.
- Selective CPS / contify-vs-reify is a BACKEND concern (interpreter is uniform-reified) —
  OUT of scope.
- No async keyword, no function colouring; capture/await are ordinary effect ops.

============================================================================
SLICE SCOPE (tight — type the escape primitive, defer every policy)

- IN: (1) the control-flow-capability effect + the second-class Future (one-shot resumable
  computation) type; (2) the await/resume-once typing rule; (3) the lifetime bound via
  second-class + (optional) row use-confinement; (4) the affine bound on the Future
  (LOCAL analysis) incl. typing resume-xor-cancel; (5) the shared/private capability
  distinction in the row (crucial Q #3) AT THE TYPE LEVEL; (6) a TRIVIAL SYNCHRONOUS
  RESUMER (resume the parked computation immediately / force-on-demand) as the reference
  semantics. Deliverable: an escaping-one-shot capability that slice X would reject now
  type-checks + runs under the trivial resumer; awaiting a Future twice = compile error;
  a Future escaping its scope (returned/stored) = type error.
- DEFER: spawn, parallelism/relocation + the worker capability-config, scheduler/async/lazy
  POLICIES, ndet racy-scheduling semantics, the cancellation RUNTIME (finalizer unwinding),
  OS readiness primitives, the multicore runtime, and FIRST-CLASS Futures.

============================================================================
OPEN QUESTIONS TO SETTLE IN BRAINSTORMING

- Is SECOND-CLASS Futures EXPRESSIVE ENOUGH — i.e. does any REQUIRED use case need a first-
  class Future (stashed/returned)? This, not rank-2, is the reshaping risk.
- Does wok's second-class discipline allow region-LOCAL use (sufficient) while forbidding
  outward escape? Probe named-instance enforcement directly.
- Is row use-confinement + named-instance per-activation routing enough to confine `await`
  to the RIGHT capability activation (so a leaked Future can't be awaited elsewhere)?
- Shared vs private capabilities relative to the capture point — how is it typed?
- Capture-boundary fork (full vs capability-config-delimited) against the CEK machine.
- How much of resume-xor-cancel must be typed now.
- Naming: "control-flow capability", the effect, the Future type.

============================================================================
THE BIG RISK — front-load it

NOT rank-2 (ruled out) and NOT linear types (avoided by second-class). The real risk is
EXPRESSIVENESS: is a SECOND-CLASS Future enough to express the target control patterns, or
does a real await/par example force a FIRST-CLASS Future (which WOULD drag in rank-2 +
linear types)? Second: can the CEK machine resume-after-the-handler-returned with the answer
routed region-internally and capabilities reconstructed by TYPE (not runtime reroute)? Build
the smallest typed await + trivial synchronous resumer in the first day, and try to break
second-class confinement with a realistic example. If second-class is insufficient, surface
it — it reshapes the slice (first-class Futures => rank-2 + linear types => prerequisite
slices => roadmap reorders).

============================================================================
READ FIRST (authoritative)

1. Memory one-shot-as-law-multiplicity — the count axis + the escape/count distinction.
2. docs/superpowers/specs/2026-06-09-one-shot-multiplicity-analysis-design.md §5 (the cardOf
   escape rule; ask: does it stay LOCAL for second-class Future values?).
3. Memory named-effect-instances-design + examples/named-instances.wok — the SECOND-CLASS
   handle discipline + per-activation routing this slice REUSES (lifetime + use confinement).
4. Memory effect-surface-syntax-final — async-as-ops, the bind-k-resume-later case, the
   Future-hides-the-existential point, ndet.
5. Memory effect-compilation-strategy — capabilities-as-row, ndet, "scheduler is a handler"
   (now a deferred POLICY), contify/reify as backend-only.
6. Memory higher-ir-direction — the "no linear types" / decidable HM stance the hard
   constraint upholds.
7. Code: src/Wok/IR/Multiplicity.hs (the affine analysis — keep it LOCAL for Futures),
   src/Wok/Interp/Machine.hs (Kont, dispatchOp, slice-3 answer-join + slice-4a deep
   re-install = capability reconstruction), src/Wok/IR/Anf.hs, and the second-class / hSelf
   enforcement for named instances (the lifetime mechanism).
8. docs/superpowers/specs/2026-06-05-effect-handlers-ROADMAP.md — slice 4b row + re-anchored
   slice X.

============================================================================
WORKFLOW

START with brainstorming (resolve the EXPRESSIVENESS risk FIRST: is second-class enough?;
then the capture-boundary fork, the shared/private split, the row use-confinement, and how
much resume-xor-cancel to type; write a converged spec). THEN writing-plans, THEN
subagent-driven-development. TDD — type + golden tests: escaping-one-shot type-checks + runs
under the trivial resumer; await-twice = compile error; Future-escapes-scope = type error;
a re-performed effect with no re-establishable handler = type error. Full-branch review
before any merge to main.

Notes:
- Type system + CEK reference semantics. No scheduler, no parallelism, no workers, no OS.
- DECIDABLE HM-PRINCIPAL inference is non-negotiable: no rank-2, no full linear types;
  second-class Futures are the mechanism.
- Escape is still ONE-SHOT. The affine check must enforce it on the Future.
- Prefer assembling existing decidable bounds (row system; second-class handles + per-
  activation routing; slice X local affine analysis) at a new boundary over inventing
  machinery. If a use case forces FIRST-CLASS Futures, surface it; that reorders the roadmap.

BUILD/TEST: cabal build; cabal test (652 green at start); cabal run -v0 wok -- <file.wok>
--run | --dump-anf | --dump-multiplicity. Grammar change -> bnfc regen + reapply 3 manual
patches (grammar/Wok.cf:13-69) + confirm shift/reduce count UNCHANGED (32). Regenerate
goldens with cabal run wok-tests -- --accept (READ diffs first).
```
