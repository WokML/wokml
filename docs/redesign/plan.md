# Redesign bundle: status and handoff plan

Status (2026-08-04, branch `docs/redesign-v2-surface`): spec.md is
`buildable` — 15 challenges all resolved, 28 decisions, 2 generating
principles (P1 visibility, P2 roles/slots), a 19-entry rejection ledger,
ZERO open questions (Q1 resolved as D21: replay Search as a fenced
library). 26
conformance examples (12 accept + 14 reject). 2026-08-04: C13/D24 — the
`abort` clause kind (trade study prompted by the once/return retrofit
review: the migrated aborting arms re-created a mandatory dead `k` binder);
closes the clause-kind set as {plain, once, abort, return, var} under the
one-shot law, adds A12 (abort-by-inference rejected) and twins
accept/10 + reject/12. Also 2026-08-04: C8 AMENDED — the `once` head gains
a `,` separator before the continuation (`once ask q, k ->`), restoring
binder-count = op-arity left of the comma for every clause kind; spelling
trade ran comma vs bar vs parens (comma adopted; bar imports or-pattern/
guard priors, parens break head uniformity); evidence = four probes vs the
retrofit build (follow-the-type riddle, adversarial naming runs,
nullary-op illusion runs) + OCaml `, k` / Unison `-> k` prior art. Then
D25 (same day, owner decision): `once` CUT — the comma is the sole
control-clause classifier, backed by ABORT-TOTALITY (new E-ABORT: a comma
arm must consume `k` on some path, else write `abort`); keywords now mark
exactly the clauses holding no continuation; `once` stays reserved at
clause-head for the v1-migration diagnostic; never-vs-abort family
question closed as moot. spec-min.md added: the one-page normative
extract for the C parser work. Then C14/D26/D27 (same day): the local
mutability round — D26 non-recursive value bindings (the rebind idiom
`let off = off + 4`; function equations stay recursive; value
self-reference errors with the eta hint), D27 mutation-has-one-home
(write-locality for `:=`: boundaries are lambdas, local function
equations, handler literals; snapshot reads; args -> batons -> enclosing
resolution; three-voice E-VARSCOPE), A13 rejects Koka-style
function-local var (counter + while-lambda counterfactuals), twins
accept/11 + reject/13; both recursive-let UnboundVar holes recorded as
v1 backlog #15; A14 (return-as-abort, the nullary-op collision) closes
the naming probes' ledger debt. Finally C15/D28: the E-SHADOW fence
rescoped to the USABILITY REGION (frozen for the whole arm, live or dead
-- consume-then-shadow absorbs a double resume; but fresh beyond any
function-forming boundary, since capture is rejected nothing legal is
maskable) -- the k convention now composes across nested handlers; twins
accept/12 + reject/14; E-SHADOW preempts E-ABORT/E-AFFINE when the
shadow is the enabling edit; v1 retrofit keeps strict (corpus-clean),
D28 adoption there optional. Every
empirical claim was
re-run and verified against the current compiler; two review rounds (a full
8-angle multi-agent review, then a delta review) found 15 + 8 defects, all
fixed. The owner review is COMPLETE: earlier rounds produced D20
(parenthesized labeled row entries), A10/A11 (closure of the
resolution-design space), and the capitals invariant in 1.6; the final
D15/D16 interrogation ran four fresh probes (q4-trace.md addendum),
certifying the row-composition equation and pinning Step's travel rule.

## Where everything is

- Branch `docs/redesign-v2-surface`, commits: b31dd2d (bundle), 08cb6c1
  (delta-review fixes), f6b3b1e (owner-review round), plus this handoff.
- The bundle: spec.md (the contract), surface.md (concrete surface),
  q4-trace.md (D15's empirical certificate), rejected.md (19 counterfactual
  programs), examples/ (accept/reject conformance), prompt.md (the seed
  prompt + the next-session boot prompt), rust-reader.md (the control
  continuation explained through Rust's FnOnce/move vocabulary — the one
  place familiar priors teach the right law; includes the traced
  generator), spec-min.md (the one-page normative extract for the C
  parser: grammar, comma classification, checks in pipeline order,
  canonical examples — where it and spec.md disagree, spec.md wins).
- WORKTREE CAUTIONS: (1) the parent branch feat/tco-and-recursive-joins has
  extensive uncommitted WIP living in this same tree — do not sweep it;
  (2) six prelude/Std -> prelude renames are STAGED in the index and get
  swept into any plain `git commit` — always commit this bundle via
  pathspec: `git commit -- docs/redesign/`; (3) switching to a branch that
  lacks these docs removes them from the working tree (they are committed
  HERE).
- The probe corpus (Section E battery, q4/c1 probes) lives in a
  session-local scratchpad, NOT the repo, and may not survive:
  /private/tmp/claude-501/-Users-zy-wokml/795ce70c-6c11-4acb-b629-bd402d8b57a2/scratchpad/probes/
  Every probe is reconstructible from the documentation: spec.md and
  q4-trace.md record each program and its observed verdict.

## Provenance (condensed)

prompt.md's Section E seed drove a 21-probe empirical battery against the
current compiler (silent collapses S1-S4, five error voices, sound-but-
conservative enforcement) -> the v2 surface with trade studies C1-C12 and
killer programs -> multi-agent review + fixes -> Q4 resolved empirically as
confinement (D15) -> the P1/P2 principles refactor (zero surface change) ->
owner-review rounds producing D17-D20 and ledger entries through A11.

## Next session: pick ONE

1. (DONE 2026-07-22) Owner review at D15/D16 — four probes, q4-trace
   addendum; row composition certified, Step travel rule pinned.
2. (DONE 2026-07-22) Q1 resolved as D21: `Search.replay` as a pure
   library behind the closed-row purity fence; cost model documented;
   naming rationale recorded (Search over Amb/NonDet).
3. EXECUTE THE FORK (the big resource decision):
   - BUILD v2: (a) grammar + parser; (b) elaboration into the EXISTING
     typed core (the Loader/Elaborate seam); (c) slot/role resolution + P2
     typing — start here because assumption A2 (the unified mode checker
     subsumes today's fences) is the highest-risk unknown; (d) unified
     E-code renderer; (e) conformance runner over examples/.
   - RETROFIT current wok instead: once/return + E-ARITY/E-SHADOW first
     (closes S1/S2 on the real compiler), then the unified renderer, then
     explicit Handler answer types. Do NOT retrofit capabilities (spec
     appendix).
   - PARK as a design record (also legitimate).
4. FORK-INDEPENDENT FREE WIN: promote the Section E battery into
   test/multiplicity-examples/ on the main line — regenerate each program
   from the documentation, run it against the current compiler to pin its
   verdict, land as accept/reject twins through the normal pipeline.
5. Before any merge to main: owner sign-off on the full bundle + a delta
   review of anything changed after f6b3b1e.

## Working rules that made this effective (carry them forward)

- EMPIRICAL FIRST: probe the current compiler before deciding
  (`cabal run -v0 exe:wok -- <file> --run` / `--dump-multiplicity`);
  verdicts are observed, never predicted.
- KILLER PROGRAMS over prose; accept/reject twins smallest-edit-apart.
- New binding/resolution proposals meet the D19 ledger bar and the P1/P2
  litmus BEFORE earning a fresh trade study; do not re-litigate rejected.md
  entries without a program the ledger lacks.
- Description-layer refactors must be zero-surface-change (D18 precedent);
  verify by diffing the examples.
- spec-format contract discipline: every challenge gets a resolved
  response; buildable is a checked gate, not a mood.
