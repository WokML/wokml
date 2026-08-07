# once/return retrofit — session handoff

Workspace: /Users/zy/wokml-retrofit (a git worktree off main), branch
feat/retrofit-once-return. Do NOT work in /Users/zy/wokml — that worktree
holds the docs/redesign-v2-surface branch plus ~655 files of UNCOMMITTED
prelude-flattening WIP belonging to feat/tco-and-recursive-joins.

Design authority: docs/redesign/ on branch docs/redesign-v2-surface
(spec.md D-once/D10/D21 for the keyword rationale; the Section E probe
battery for the empirical motivation — silent collapses S1/S2).

## State (commits on this branch)

- e4b93a2 build(parser): scripted BNFC regen. The checked-in
  src-generated/ tree is HAND-PATCHED (column-aware handler layout +
  record-pattern S/R fix). NEVER run bnfc directly — always
  scripts/regen-parser.sh, which reapplies scripts/parser-patches/*.
- c0b1403 feat(surface): the core retrofit, DONE and smoke-verified:
  - grammar: HOnceArm/HOnceUArm (`once E.op pats k ->` /
    `once op pats k ->`, last binder = continuation, DECLARED) and
    HRetArm (`return v ->` value arm); `ctl` released from ReservedKw.
  - typechecker (src/Wok/TypeChecking/Infer.hs): classifyArm carries the
    declared kind; split-by-count retired. New errors (Error.hs):
    ArmArityMismatch (plain = arity, once = arity+1), ValueArmNeedsReturn
    (bare `v ->`), ContinuationShadowed (STRICT: shadowsName traversal —
    any rebinding of the continuation name in the arm body),
    ReturnArmBinderNotVar (patterns in return position deferred, v2 D14).
  - prelude/Std/Control.wok: all 7 arms converted.
  - Smoke oracle green: once/return generator prints [1..6]; the S2
    shadow probe dies at the shadowing binder's position; old control
    arms die with expected/got; state-accumulate (runner user, no
    literal arms) runs unchanged at 31.

## Facts the next session must know

- Run programs from INSIDE this worktree with
  `cabal run -v0 exe:wok -- <file> --run` (a directly-invoked binary
  lacks the cabal data-dir and fails opening the prelude; probe files
  outside the worktree fail import resolution).
- Import convention on main is `import Std.Base` / `import Std.Control`
  (the flat `import Base` is the uncommitted flattening, elsewhere).
- -Werror=incomplete-patterns polices HandlerArm consumers: adding
  constructors surfaces every consumer as a build error (Class.hs was
  the third consumer last time).
- Errors print show-style via "typecheck in <mod>: <show>". Prose
  rendering is retrofit item 2, deliberately OUT OF SCOPE here.
- Until the codemod runs, every file with literal old-syntax arms fails
  loudly by design (control arms: ArmArityMismatch; value arms:
  ValueArmNeedsReturn). That is the expected mid-state, not a bug.

## The task: Phase 4 (codemod), then 5 (suite), then 6 (review)

PHASE 4 — compiler-assisted codemod. Regex cannot do this: header-form
arms (`set x k ->`) need effect-declaration context for arity. Build a
small dev tool that reuses the library's parser + effect tables (Loader /
the Abs tree with token positions) to classify every HandlerArm in every
.wok file and emit in-place text edits:
  - control arm (binders = op arity + 1): insert `once ` before the head
  - value arm (unqualified head naming no op, zero binders): insert
    `return ` before the head
  - plain op arms: untouched
Corpus: ~117 files with `k ->` arms + ~60 with `; v ->` value arms
(prelude already done), plus ONE hand rename: the helper FUNCTION named
`once` in test/multiplicity-fail-examples/helper-partial-escape.wok
(3 lines) must be renamed (keyword collision). Also sweep
test/examples/16-reserved.wok / 17-reserved-error.wok (once/return join
the reserved set; ctl leaves it) and prose mentions of the old arm syntax
(examples/README.md, syntax.md).

PHASE 5 — `cabal test` green (2000+ tests). Run-output goldens are
unchanged by construction; fixtures that asserted OLD error shapes for
arm mistakes may change error constructor. Add permanent acceptance
fixtures: the S1 pair (arity collapse now loud both directions) and the
S2 shadow (ContinuationShadowed), modeled on the Section E probes
documented in docs/redesign/spec.md on the other branch.

PHASE 6 — full-branch code review (the owner's review-before-merge law)
before this merges to main. Nothing gets pushed without it.

## Working rules

- Empirical first: verdicts are observed via cabal run, never predicted.
- No emojis anywhere. Commit style: type(scope): summary, body explains
  why, trailer: Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>.
- Keep scope tight: no renderer unification, no v2 features (labels,
  handle/use, D20 rows) — this branch is once/return + its errors only.
