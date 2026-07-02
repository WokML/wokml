# Resume-launders-effects rung 2 — caller-root residual provenance (design)

Status: **DESIGN / for review** (2026-07-03). Rung 2 of the "resume launders
effects" epic. Supersedes the mechanism sketch in
`2026-07-02-resume-launders-rung2-provenance.md` §3 (that doc's problem statement
and CLOSED/OPEN table still stand; this doc picks and sharpens the mechanism).
Rung 1 (direct + arm-hosted drivers) is on `feat/resume-launders-loadbearing`.
Memory: `[[explicit-resume-effect-laundering]]`.

## 1. Problem (recap)

Rung 1 closes laundering only where a bare residual reaches the enclosing declared
row DIRECTLY. Where it passes through a handler's discharge sub-ambient, rung 1
exempts the whole terminal, so three positions still launder under a closed sig:
handled-expression `with H (run g 0)`, nested handlers, runner-sugar
`with s = state 0 in f ()` (pinned green as `test/typecheck-examples/launder-leak-*.wok`).
The reason it was hard: after `dischargeEffects` strips the handled labels, a
benign handler-internal leftover tail and a genuinely-unhandled caller residual are
BOTH a bare `Unbound KEffect` row variable — locally indistinguishable.

## 2. The discriminator (verified)

They are distinguishable by **provenance**: a residual obligates the enclosing
closed row **iff its tail variable is one the CALLER supplied** — i.e. it occurs in
the function's declared PARAMETER or RESULT types. A caller-supplied polymorphic
row variable can never be discharged internally (you cannot write a handler for an
unknown row variable), so performing it under a closed sig is always a real
obligation. A fresh handler-internal tail (a `with`-block's sub-ambient, a resume
continuation row, a runner thunk's leftover) is not caller-supplied and closes to
empty — benign.

Verified against ALL SIX cases (the 3 that a naive "record everywhere" broke, and
the 3 leaks):

| Program | Residual tail origin | Caller-root? | Correct verdict |
|---------|---------------------|--------------|-----------------|
| `coro-residual-handled` (`drive : () -> U64`) | fresh sub-ambient (Log handled) | no | accept (skip) |
| `coro-residual-multi` (`drive : () -> U64`) | fresh sub-ambient | no | accept (skip) |
| `11-effect-collect` (`collect : String -> String`) | fresh sub-ambient (Emit handled) | no | accept (skip) |
| `launder-leak-handled-expr` (`… (row e) -> U64`) | param `g`'s `(row e)` | yes | **reject** |
| `launder-leak-nested` (`… (row e) -> U64`) | param `g`'s `(row e)` | yes | **reject** |
| `launder-leak-runner-sugar` (`(() -> U64 with eff e) -> …`) | param `f`'s arrow `eff e` | yes | **reject** |

None of the accept-cases has a row-typed parameter carrying the residual; each
reject-case does. Clean split.

## 3. Mechanism

**Collect caller-roots at seed, check membership at emit.** Concretely:

1. In `typeEquationWith`, at seed time (where rung 1 already captures `declClosed`
   from `mSigEffRow`, `Infer.hs:~3689`), ALSO collect the representative refs of
   every `KEffect` row variable occurring in the declared PARAMETER types (`pTys`)
   and the declared RESULT type. Store them in a new TC-context set
   `ctxCallerResidualRoots :: [RowRef s]`, installed for the equation body (a
   sibling of the existing `withEffRowSig`).
2. In `emitResidualTail` (the bare-residual emit site), record an obligation iff
   the residual tail's representative is a member of `ctxCallerResidualRoots`
   (representative-following via the existing `reprRowRef`, since unification
   re-links). Otherwise skip (benign internal tail).

This **REPLACES** rung 1's "record everything under declared-closed, then exempt
handler terminals by identity" with one positive rule: "record only caller-supplied
roots." The replacement is a simplification — internal tails (resume continuation
rows, discharge sub-ambients, runner leftovers) are naturally not caller-roots, so
the whole `ctxExemptRows` / `reprRowRef`-exemption / `withExemptRows` machinery and
its three wrap sites (arm bodies, discharge re-emit, runner-form) are RETIRED. The
`declClosed` gate stays (an open sig still records nothing). The deferred post-pass
throw (after carrier/affine) stays unchanged.

Why this subsumes rung 1's cases:
- Top-level `drive g = run g 0`: tail `e` ∈ roots (param `g`) → record. Same result.
- Arm-hosted `with { Ask.ask -> run g 0 }`: tail `e` ∈ roots → record. (Rung 1
  needed resume-row identity exemption to AVOID false-positiving `k`; here `k`'s
  row is internal, not a root, so it is naturally skipped — no exemption needed.)
- Legit resuming handler `with { Ask.ask k -> k 42 }`: `k`'s row is internal → skip.

## 4. Scope

**IN:** the three handler-discharge positions (the `launder-leak-*.wok` targets),
via the caller-root rule replacing rung 1's exemption machinery.

**OUT (deferred — the "inner-abstraction residual propagation" family, a DIFFERENT
mechanism):** any residual absorbed by an INNER ABSTRACTION with its own open
ambient before it reaches the enclosing declared-closed row. Adversarial review
(2026-07-03) confirmed this family has at least two members:
- **Lambda-parameter:** `driver g = (\h -> run h 0) g`.
- **Sigless local function:** `drive g = let go u = run g 0 in go ()` — the residual
  is performed under `go`'s OWN inferred (open) ambient, so the caller-root gate
  never fires, even though the performed tail is literally `drive`'s captured param
  root `e`.

Both leak for the SAME reason and are NOT fixed by the caller-root rule: the inner
abstraction (lambda or sigless local) does not propagate its body's residual onto
its inferred arrow / into the enclosing ambient, so at check time the residual is
not yet visible as a caller-root (a lambda's `e'` unifies with the caller root only
at APPLICATION, after its body is checked; a sigless local closes its own ambient
first). Closing them requires the inner abstraction to PROPAGATE its residual
effects onto its arrow — an effect-propagation fix orthogonal to provenance, with
its own blast radius (higher-order effect-polymorphic `map`/`fold` code). Bundling
it would put two unrelated soundness fixes in one slice. This is the immediate
next slice after rung 2; tracked (to be broadened from "lambda" to "inner
abstraction") in `docs/superpowers/2026-07-02-lambda-effect-laundering-note.md`.
NOTE: a returned closure (`makeThunk g = \u -> run g 0`) is instead blocked by the
existing `CarrierEscape` rule, so it is not a clean member of this family.

## 5. Edge cases to verify during implementation

- **Local / `where` / `let`-bound functions with their OWN sig+row params:** each
  must get ITS OWN caller-root set (its params), not the outer function's. Confirm
  local equations route through `typeEquationWith` (or the equivalent seed) so the
  set is scoped per equation. VERIFY with a nested-function test. CAVEAT (line-by-line
  review 2026-07-03): the claim "every equation gets its own roots" holds ONLY for
  the PARAMETERIZED branch. The zero-parameter branch of `typeEquationWith`
  (`pTys == []`) does NOT collect roots, so a function-typed POINT-FREE 0-arg binding
  (`helper = \g -> run g 0` with a closed row-arrow sig) launders — eta-inconsistent
  with the caught `helper g = run g 0`. This is the point-free member of the deferred
  inner-abstraction family (§4), NOT fixed by rung 2; do not special-case it. CAVEAT (adversarial
  review 2026-07-03): a SIGLESS local function that performs the OUTER function's
  caller-root residual (`drive g = let go u = run g 0 in go ()`) is NOT caught — it
  is inferred-open, absorbs the residual, and is a genuine leak in the deferred
  inner-abstraction family (§4), NOT a benign case. Rung 2 does not fix it and must
  not pretend to; do not add a hack that special-cases it (that belongs to the
  inner-abstraction propagation slice).
- **Representative-following (REQUIRED for the split to hold):** force BOTH the
  candidate residual tail AND every stored root to their representatives
  (`reprRowRef`) before comparing — a root unified with an internal var (shared
  representative) must still match, and a root that got linked must be followed.
  Omitting this silently misses correct rejections.
- **Nested-arrow / type-arg root collection (REQUIRED — the runner-sugar reject
  depends on it):** the runner-sugar root `e` sits in a NESTED function-typed
  parameter (`(() -> U64 with eff e) -> …`). Root-collection MUST walk into nested
  arrows AND type arguments (e.g. the `(row e)` inside `Suspension a b r (row e)`),
  not only top-level parameter heads. A head-only scan silently under-collects and
  misses `launder-leak-runner-sugar`.
- **Result-type roots:** include row vars in the declared RESULT type, not only
  params (a function returning a `Suspension … (row e)` and performing `e` is
  laundering into a caller-visible position). Conservative-correct. VERIFY no
  legitimate program returns a residual-typed value while performing it under a
  closed sig in a way this over-rejects (expected: none — the adversarial review
  found no over-reject counterexample; performing an unhandleable polymorphic row
  under a closed sig is always an obligation).

## 6. Migration & tests

- The 3 `test/typecheck-examples/launder-leak-*.wok` characterizations FLIP to
  rejections: MOVE them to `test/typecheck-fail-examples/` with
  `UndischargedEffect` goldens (conscious flip — the boundary the rung-1 headers
  promised). Update their headers from "KNOWN LEAK" to "rung-2 death test."
- The 3 rung-1 death tests (`resume-launders-{undeclared,in-arm,in-named-arm}`)
  must STILL reject (regression).
- The corpus route-A broke (`coro-residual-handled`, `coro-residual-multi`,
  `11-effect-collect`) + the full prelude handler set + `54-reentrant-routing` +
  `44-named-instance` must STAY green (no false positives).
- Full suite green; type-only (no runtime change); hlint clean.

## 7. Success criteria

1. The 3 handler-position leaks are rejected with `UndischargedEffect`.
2. Zero regression on the accept-corpus (the 3 route-A programs + full handler set).
3. Rung 1's 3 death tests still reject; multiplicity still wins (deferred verdict).
4. The `ctxExemptRows` exemption machinery is retired (or, if kept for safety,
   justified — but the intent is to replace, not layer).
5. Lambda-parameter gap remains OUT (documented), tee'd up as the next slice.

## 8. Risks

- **Re-touching heavily-reviewed rung-1 code.** Replacing the exemption machinery
  means the emitter core changes again; it must re-run the full rung-1 review rigor
  (death tests + corpus + whole-branch Opus deep review + `/code-review`). This is
  the same gate rung 1 passed; the payoff is a simpler, more principled mechanism.
- **A hidden accept-case with a caller-root that IS legitimately dischargeable.**
  The design claims a caller-supplied polymorphic row is never internally
  dischargeable. If a counterexample exists (a closed sig that legitimately handles
  a caller-supplied residual), the rule would over-reject. The adversarial review
  must hunt for it; none found in the current corpus or by construction (you cannot
  handle a polymorphic row variable).
