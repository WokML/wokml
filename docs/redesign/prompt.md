# The engineered prompt (provenance)

This is the seed prompt, preserved verbatim, that opened the sessions
producing this bundle (2026-07-21/22). It drove the empirical probe battery
against the current compiler (Section E), whose findings — the silent-
legality collapses S1-S4, the five error voices, the conservative-rejection
map — became the motivation and evidence base for the v2 surface redesign
(spec.md), its trade studies (C1-C12), and the rejected-designs ledger
(rejected.md).

---

# SECTION E — THE ONE-SHOT <-> AFFINE-k SEAM (densest coverage; anchor on MY examples)

## E.0 ANCHORING (do this first, before generating anything)
I have supplied real WokML programs above/below, under the marker <WOK_EXAMPLES>. Treat
them as GROUND TRUTH for concrete syntax — spacing, keyword spelling, how `resume k` is
written, how handlers and `with` are laid out, how signatures and `uses` rows look.

- First, extract from <WOK_EXAMPLES> a short SYNTAX PROFILE: the exact surface forms you
  observe for (a) effect declarations, (b) each handler clause shape you can find,
  (c) `resume k` binding, (d) call sites, (e) `with` stacking, (f) signatures + `uses`.
- Every program you produce in Section E must be a MUTATION of one of my examples, or
  built strictly from the forms in the SYNTAX PROFILE. Do NOT introduce surface syntax
  that does not appear in my examples or the RULES. If a probe REQUIRES a form my examples
  never show (e.g. storing k in a data constructor, and no constructor syntax appears),
  STOP and log it under E.4 GAPS rather than inventing the form.
- If my examples CONTRADICT the RULES above, do not reconcile silently: log the conflict
  under E.4, quote both, and proceed using MY example as the authority for surface syntax.

## E.1 THE INVARIANT UNDER TEST
`k` (the continuation bound by a shape-(3) clause) is AFFINE: usable at most once, and it
must not outlive the handler activation that introduced it. Wok enforces this with NO
surface annotation — inference alone. Section E hunts for programs where that enforcement
is unclear, evadable, or where a legal-looking program should be rejected.

## E.2 ESCAPE & DUPLICATION BATTERY (the core deliverable)
For EACH vector below, produce a MINIMAL mutation of one of my examples: a REJECT case
(the escape/duplication actually happens) and, where meaningful, the nearest ACCEPT case
that stays legal — the smallest edit apart. Name the vector, cite which of my examples you
mutated, and give the expected compiler verdict + the exact reason `k`'s affinity is or
isn't violated.

  V1  DOUBLE USE, sequential:      k called, then k called again later in the clause.
  V2  DOUBLE USE, branch-merge:    k called in BOTH arms of a match, arms rejoin — is the
                                   join counted as one use or two? (attack the merge rule)
  V3  DOUBLE USE, loop:            k invoked inside a recursion/loop in the clause body.
  V4  ESCAPE via return closure:   k captured in a lambda that the clause RETURNS.
  V5  ESCAPE via data constructor: k stored in a constructed value that leaves the handler.
  V6  ESCAPE via another effect:   k passed as an argument to a DIFFERENT effect op.
  V7  ALIASING:                    k bound to a second name, both live — does inference see
                                   the alias as one resource or two?
  V8  NESTED SAME EFFECT:          an inner handler of the SAME effect; inner k vs outer k —
                                   can one be mistaken for / capture the other?
  V9  persist() INTERACTION:       `persist(k)` then also `k(...)` — the multi-shot escape
                                   hatch used alongside the affine original. What's legal?
  V10 DROP PATH:                   clause takes an `abort`/early-exit path WITHOUT using k —
                                   is dropping an owned k on that path handled? (this is the
                                   owned-C-buffer-then-abort leak, in continuation form)

## E.3 THE HARD ONE — SILENT-LEGALITY PROBES
The failure mode that matters most: a program that VIOLATES k's affinity but still parses
and elaborates as some OTHER legal program (so the error is silent, not loud). For each you
find, give: the intended (illegal) reading, the alternative legal reading it collapses to,
and which rule should have made it LOUD but doesn't. These rank above everything else in E.

## E.4 GAPS & CONFLICTS
- GAPS: probes you could not express because my examples + RULES lack the needed surface
  form (report the probe and the missing form; do not invent it).
- CONFLICTS: places <WOK_EXAMPLES> and the RULES disagree on surface syntax.

# E OUTPUT
Reuse the main format (ID, rule/vector, verdict, program, readings). Additionally, for
every Section-E program, cite the source example it was mutated from. Rank order within E:
E.3 silent-legality first, then E.2 vectors, then E.4. You may read our grammar/ directory
and examples to see our current one. And help me to see what is the most optimal way for
both LLM agents and user with prior experiece finds it interesting and easy to pick up.

---

# The next-session boot prompt (paste this to resume the work)

Engineered from what made the original sessions effective: empirical
grounding, killer programs, the ledger bar, and one task per session.

---

You are continuing the wok v2 surface redesign on branch
`docs/redesign-v2-surface`. Before anything else, read
`docs/redesign/plan.md` (status, cautions, task menu), then
`docs/redesign/spec.md` sections 1.0-1.6 and decisions D13-D20. The bundle
is a buildable spec-format contract with 26 conformance examples
(`docs/redesign/examples/`) and a 19-entry rejection ledger
(`docs/redesign/rejected.md`).

METHOD — non-negotiable:
- Empirical first: before any design claim about current behavior, probe
  the real compiler (`cabal run -v0 exe:wok -- <file> --run` or
  `--dump-multiplicity`); verdicts are observed, never predicted.
- TWO example corpora, do not confuse them: the top-level `examples/`
  directory is CURRENT wok — the ground truth for writing probes (they
  must compile). `docs/redesign/examples/` is the HYPOTHETICAL v2
  surface — conformance targets only; those files do NOT compile and must
  never be fed to the compiler as probes.
- Killer programs over prose: every accept/reject claim comes with a
  minimal program; reject files fail for EXACTLY one declared reason.
- Every new binding/resolution/syntax proposal is first tested against the
  principles P1/P2 (spec 1.0) and the D19 ledger bar; do not re-litigate a
  rejected.md entry without a program the ledger lacks.
- Zero-surface-change rule for description refactors: if you touch only
  the spec's story, the examples must not change by one character.
- Git: this worktree carries unrelated staged/unstaged WIP from
  feat/tco-and-recursive-joins. Commit ONLY via
  `git commit -- docs/redesign/`. Never plain `git commit`.

TODAY'S TASK — exactly one, from plan.md's "Next session" menu:
<choose: (1) finish the owner review at D15/D16 with q4-trace.md open,
challenging unstated exemptions | (2) resolve Q1 into a decision |
(3) execute the fork: build v2 starting at slot/role resolution + P2
typing (assumption A2 is the highest-risk unknown), or retrofit
once/return + E-ARITY/E-SHADOW into current wok, or park | (4) the
fork-independent free win: regenerate the Section E probe battery from the
documentation, run each against the current compiler, and land it in
test/multiplicity-examples/ as accept/reject twins on the main line>

Work the task to completion; land decisions into the spec with the
challenge/decision/ledger machinery; keep the contract check green
(every challenge resolved) before calling anything buildable.
