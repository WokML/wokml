# RC property generator: adversarial join-cluster shapes

**Date:** 2026-06-14
**Status:** design approved, pending spec review
**Area:** `test/Spec.hs` — the Suite F property generator (`genProgram`/`genExpr`),
testing `Wok.IR.Perceus.insertRC` + `Wok.Interp.RC.Machine.runModuleRC`.

## Motivation

Every review round on `feat/perceus-interpreter-m1` has found the *same* bug class
in the Perceus pass: **"a var consumed somewhere the dup/drop placement didn't
see."** Instances so far — F1 (Case scrutinee reuse missed through transitive /
nested joins, a UAF), #4 (join-body `jDelta` not symmetric with the Jump's
transitive-cap reservation, a leak), and §1 (a `Let` rhs that *moves* a var which
is *also* reserved for a downstream join — no dup planned, a double-consume). Each
was found by manual review, not by tests.

Why tests missed them: the corpus exercises a fixed handful of join shapes, and the
500-case Suite F property generator emits **only first-order data with no joins at
all** (`genExpr` builds `Ret`/`Let`/`Case`, never `LetJoin`/`Jump`). So the entire
"joins capturing/forwarding owned vars" space — where this bug class lives — is
unexercised by random programs.

**Goal.** Extend the property generator to emit join clusters that span the known
bug class, with enough frequency that reverting any of the three fixes (§1, #4, F1)
makes the property test fail within its 500 cases — turning "found by review round
N" into "auto-caught." This is the residual coverage gap called out in
`docs/superpowers/2026-06-14-join-reconciliation-review-focus.md` §4.

## Non-goals (YAGNI)

- Faithful surface-level / elaborator-mirrored generation (rejected: the elaborator
  provably does not emit the §1 shape, so a faithful mirror could never catch it).
- Multiple simultaneous captured vars; chain depth > 3; capturing a non-scrutinee
  outer var.
- Records / pairs as the *directly-moved* capture — `GList` only for the move op
  (`Cons k c` is the simplest valid move; capture-*use* in a join body may be any
  boxed type).
- Any change to the oracle, the pass, the interpreters, or the corpus.

## Key design insight

The generator only needs to emit **well-scoped, runnable, type-consistent, covered
ANF**. It does **not** reason about ownership — that is the *pass's* job, and the
existing Suite F oracle already checks the pass got it right via three independent
signals on every generated program:

- **differential output:** `Interp.renderValue (Interp.runModule cm)` must equal
  `RCM.rcOutput (runModuleRC (insertRC cm))` (dup/drop never change values);
- **heap-empty:** `stLive == rcBaseline`;
- **balanced:** `stAllocs - stFrees == rcBaseline`;
- a misplacement that frees early is **trapped** by the RC interpreter as a `Left`
  (UAF / double-free), surfacing as a divergence (exactly one interpreter failed).

Both interpreters (`Wok.Interp.Machine` and `Wok.Interp.RC.Machine`) already execute
`LetJoin`/`Jump`, so join-bearing programs run through the *full* triple oracle, not
just `balanceLint`. Consequently:

- The generator's sole obligation is structural validity (well-scoped, arity-correct
  jumps, type-consistent values, covered fragment). It never needs to be "correct"
  about RC.
- Any property failure is a **true** finding: either a real pass bug, or a real
  structural bug in the generator (caught immediately by the first run).
- No false positives are expected: the generator stays inside the covered,
  first-order, no-handler fragment that `insertRC` fully supports, and the §1/#2
  hand-built tests already confirm the correct pass balances these shapes.

## Design

### New form: `genJoinCluster env n ty`

A new value-producing alternative added as a weighted branch of `genExpr`
(alongside `Ret`/`genLet`/`genCase`, offered when fuel `n ≥ 3`), producing a value of
the program's current result type `ty`. It synthesizes a join cluster directly in
ANF: a `Case` on a freshly-seeded boxed capture `s`, whose continuation is a chain of
joins `j₁ (head) → … → j_d (deepest)`. The head `j₁` is the innermost `LetJoin`
(delivering the `Case`); the deepest `j_d` is the outermost. Every join has a single
`GInt` param, and every jump passes an int literal — so the capture `s` reaches the
joins **only** through their bodies' free occurrences (the `cap`), never as a jump
argument. That is exactly the F1 trap.

**Implementation note (refinement of the approved sketch).** The approved sketch had
a single `directMove on/off` knob and claimed one depth-2 shape would exercise F1, #4
and §1 *together*. Implementing it showed that is **not** true: a join body that
directly moves `s` (the §1 shape) thereby captures `s` in its *own* `cap`, which masks
both the transitive-reuse path (F1) and the transitive-`jDelta` path (#4). Each bug
needs a **structurally distinct** intermediate-join shape. So `directMove on/off`
became a three-way `IntermediateKind`, and the generator randomizes over it (with the
chain depth) so all three shapes appear across a run:

| Knob | Values | The one bug it targets |
|---|---|---|
| `chainDepth` | `PureForward`/`BranchForward`: per-kind; `MoveForward`: 2–3 | chain length / transitivity |
| `IntermediateKind = PureForward` | depth 1–3 | **F1** — `s` is captured only by the deepest join, reached *transitively*; the `Case` reuse test must close over the whole chain. Intermediates are bare `Jump j_{k+1}` (do not touch `s`). |
| `IntermediateKind = MoveForward` | depth 2–3 | **§1** — an intermediate body `let u = Cons 0 s in Jump j_{k+1}` *moves* `s` (then `u` is dead/dropped) while the deepest join also uses `s` ⇒ two consumers ⇒ a dup is required. |
| `IntermediateKind = BranchForward` | depth 2 | **#4** — the head body is `Case r₁ [0 → genExpr ty ; _ → Jump j₂]`; the `Case` arms pass `0`, so at runtime the **non-forwarding** arm runs and `s` (owned only via the transitive cap) must be dropped there. |

**Capture-seeding (robust teeth).** The cluster always seeds its own non-empty
capture `let n0 = Nil in let s = Cons h n0 in …`, so a movable boxed scrutinee always
exists regardless of `env`, and the `Case`'s `Cons` arm is the one that runs. Both
`Case` arms forward into `j₁`, so the chain runs on every runtime path (for
`BranchForward` the run stops at the head's non-forwarding arm, which is where #4
manifests).

### Canonical shapes (capturing scrutinee `s : GList`)

`MoveForward`, depth 2 (the **§1** shape):
```
let n0 = Nil in
let s  = Cons h n0 in
  LetJoin j2 [r2 : GInt]                       -- deepest: uses s  => s in cap(j2)
    (let cap = Cons 0 s in <genExpr ty>)
    (LetJoin j1 [r1 : GInt]                      -- intermediate: MOVES s, forwards on
       (let u = Cons 0 s in Jump j2 [1])         --   u is dead -> dropped
       (Case s [ Cons h t -> Jump j1 [1] ; Nil -> Jump j1 [1] ]))
```

`PureForward`, depth ≥ 2 (the **F1** shape): intermediate bodies are bare
`Jump j_{k+1} [1]` that never mention `s`; only `j_d` uses `s`. `BranchForward`,
depth 2 (the **#4** shape): `j1`'s body is `Case r1 [0 → genExpr ty ; _ → Jump j2 [1]]`
and the `Case` arms pass `0`. Depth-1 `PureForward` is the single-join reuse shape
(`s ∈ cap(j1)` directly).

### Value determinacy

The cluster is type-agnostic in `ty`. A **capturing** (deepest) join body is
`let cap = Cons 0 s in <genExpr env (n-1) ty>` — the leading `Cons` forces `s` into
the join's `cap` (a dead boxed binding the pass drops; both interpreters allocate it
and produce the same downstream value), and the trailing `genExpr` produces `ty` by
the existing rules. Every join param is `GInt` and every jump passes an int literal,
so jumps are always arity-correct and never carry `s`. The `BranchForward`
non-forwarding arm is a plain `genExpr env (n-1) ty` (no jump, no `s`). Leaf positions
recurse through the existing generators, so joins compose with lets, prims, records,
and nested cases. `env` excludes `s` and the join params, keeping `s`'s consumers
exactly the `Cons _ s` occurrences the cluster inserts.

### Fuel / termination

`chainDepth` and each nested `genExpr` consume fuel `n`; the cluster is only offered
when `n` is above a small threshold. Bounded by construction.

### Shrinking

`shrinkExpr` handles `LetJoin` **without stranding a `Jump`**:

- recursively shrink the delivering `body`, keeping the join **defined**
  (`[ LetJoin j ps jb body' | body' <- shrinkExpr body ]`);
- additionally offer dropping the whole join (`body`) **iff** the delivering body
  never jumps to it (`not (exprJumpsTo j body)`);
- never extract a join body alone (it may reference the params or `s`).

The existing `Case`-arm extraction is guarded by a new `exprHasJump` check so it
never lifts an arm body containing a `Jump` (which would dangle once its enclosing
join is gone). Conservative: it may shrink less aggressively than ideal, but never
yields a dangling `Jump` or an ill-scoped fragment. QuickCheck still reports the raw
failing case; the `review #1` / F1-follow-up hand-built tests already provide minimal
reproducers for the known shapes.

## Acceptance criteria — all met (verified 2026-06-14)

1. **No false positives.** ✅ Full suite green at **973** with the generator in place:
   the correct pass balances every generated program (500 property cases). The
   generator only emits covered, first-order, no-handler IR, arity-correct jumps,
   well-scoped references.
2. **Teeth, verified by reverting each fix in turn.** ✅ Each revert makes the property
   **fail within the first 5 cases** (not merely within 500 — robustly non-flaky):
   - revert §1 fix (`f3c12f8`) → `rc: FAILED (PrimError "double-free")` (the
     `MoveForward` double-consume, trapped at runtime);
   - revert #4 jDelta fix (`0be47d3`) → `output / heap-empty / balanced mismatch` (the
     `BranchForward` leak — `s` never dropped on the non-forwarding arm);
   - revert F1 reuse fix (`3e62e99`) → `rc: FAILED (PrimError "double-free")` (the
     `PureForward` scrutinee dropped at the match, then used in the deepest join).
3. **Shrinking** ✅ terminates and yields only well-scoped sub-programs (the
   `LetJoin` case keeps joins defined; arm extraction is guarded against dangling
   `Jump`s by `exprHasJump`).
4. ✅ Counterexample reporting unchanged and diagnosable for join programs.

## Risks and mitigations

- **Flaky teeth (a bad seed misses the shape in 500 cases).** Mitigated by
  capture-seeding + tuned frequencies giving dozens of triggering programs per run;
  validated empirically by reverting each fix and running repeatedly. The
  deterministic hand-built `review #1` / F1-follow-up tests remain as the guaranteed
  backstop.
- **Generator emits structurally-invalid IR (dangling jump, arity mismatch,
  out-of-scope ref).** Surfaces immediately on the first suite run as a divergence;
  fixed during implementation. Arity and scoping are constructed, not random.
- **A generated shape reveals the correct pass failing.** This is a *true positive* —
  a new member of the bug class — and the desired outcome, not a risk to suppress.

## Files touched

- `test/Spec.hs` only — added `IntermediateKind`, `freshJoinId`, `genJoinCluster`,
  `genJoinBody`; wired the cluster into `genExpr`'s `freqM` (weight 3 when `n ≥ 3`);
  extended `shrinkExpr` for `LetJoin` with `exprHasJump` / `exprJumpsTo` /
  `clusterAltBody` helpers. No production code, no new test fixtures, no oracle
  change.
