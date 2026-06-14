# Perceus on the interpreter: static analysis + RC explicit-store oracle (M1)

Status: **Design** (brainstormed 2026-06-14). Scope is the first milestone (M1) of bringing
Perceus-style reference counting to wok on the **interpreter**, deliberately ahead of any
codegen. Supersedes the "Perceus comes with codegen, not the interpreter" stance in
`docs/superpowers/plans/2026-06-03-anf-interpreter-sketch.md`; defers the QBE/native backend
decision in the `higher-ir-direction` memory.

Prior commitments this builds on:
- ANF + join points IR (`Wok.IR.Anf`), strict, with typed binders carrying a (currently dead)
  `Mult` slot.
- One-shot is the law: `Multiplicity.analyzeModule` rejects provably-multishot resume arms
  (a sound upper bound: accepted => resume invoked at most once at runtime).
- Second-class carriers + escape/free-var analysis (`Wok.TypeChecking.Carrier`).
- The eventual backend direction leans owned SSA-chordal register allocation (the "Fable note"),
  NOT QBE; codegen and register allocation are explicitly OUT OF SCOPE here.

---

## 1. Purpose and scope

**Purpose.** Stand up reference counting on the interpreter as a **correctness/semantics
oracle** for Perceus dup/drop placement, and in doing so **pin the allocation-extern interface**
and the continuation-ownership model that a future backend will mirror. The analysis is the
genuinely hard, runtime-agnostic part; the oracle makes it falsifiable on day one.

**In scope (M1):**
- A Perceus **static analysis** (Core->Core ANF pass) that inserts `dup`/`drop` as
  allocation-extern calls, for the **no-handler (pure first-order data) fragment**.
- An **RC explicit-store interpreter** (a separate, independent module) that executes those
  ops over an owned heap and validates correctness differentially against the existing
  interpreter.
- The allocation-extern interface (`Store` API + `dup`/`drop`).

**Out of scope (deferred):**
- Reuse / FBIP (`isUnique`/`dropReuse`/`allocAt`, drop-guided reuse, reuse specialization).
- Borrowed-parameter inference / linear hints (on the roadmap; ignored here).
- Continuation RC (designed now, dormant; implemented in M2 — see Section 7).
- Codegen, register allocation, spill cost, ABI, address recycling.

**Post-review hardening (2026-06-14).** A high-effort recall-biased `/code-review` found 6 confirmed
correctness bugs the corpus/oracle didn't exercise; all are fixed with teeth (commits 07262ae,
3e62e99, a251ab6, 91d619a, e808700, cb1d457): (F3) Bool was mis-classified unboxed while the
interpreter heap-allocates it — `isBoxedType` now agrees with the value rep (unboxed ⇔ RVLit);
(F1) Case scrutinee-reuse missed joins reached via nested Case or transitive join chains (a real
UAF) — reuse detection now closes over all transitively-reachable joins; (F5) returning a LetRec
group member dropped-then-returned it; (F2) a value-CAF referenced from a function read an
uninstalled placeholder — the forced result is now written into its static cell; (F6) a letrec
group capturing a value-CAF cascade-decref'd it — the CAF is now bound static so the cascade skips
it; (F4) closure cells leaked on application — `enterRC` now consumes the moved closure cell
(incref captures + cascade drop) across saturated/partial/over-application. Full suite 965 green.

**Known M1 limitations / deferrals (→ M1.5):**
- **Explicit `RLam` lambdas / HOFs still corpus-guarded.** Closure *application* RC is now sound
  (F4), so partial application works; but the Suite-A corpus guard and Suite-F generator still
  exclude explicit `RLam` lambdas/HOFs (and `balanceLint` refuses to certify a covered bind
  containing an `RLam`) pending broader testing; and the RC boundary `runModuleRC` now REJECTS an
  out-of-scope module (any bind reachable from `main` containing `RLam`/`ROp`/`Handle`) with a clear
  error rather than silently leaking (review #1). Closure-body BORROW-style captures (e.g. an
  `RProj` parent kept alive across a captured use) would over-free under F4's consume-once
  assumption — revisit when closure bodies gain borrow captures.
- **Prims are not first-class RC values.** A bare prim (e.g. `eqU64`) cannot be an `RCValue`, so a
  prelude `Eq`-over-`U64` instance dictionary (whose method body *is* a bare prim) cannot run on
  the RC interpreter — it fails with `UnboundVar "eqU64"`. User-defined typeclasses whose methods
  are real expressions (arity>0 closures stored in the dict record) work, and are what Suite B
  uses to exercise a non-zero immortal baseline. Supporting prims-as-values is an M1.5 change.
- **A LITERAL (unboxed) value-CAF referenced from a function is still broken** (same root as F2, no
  fix): a literal result (`RVLit`) has no `Node` to write into the static cell, so a forward
  closure capturing it via the knot env reads the placeholder (e.g. `theNum = 5; addNum n = n +
  theNum` → `PrimError "expected U64"`). Needs an `NLit`/boxed-literal node or boxed CAF results.
  No corpus program uses it; latent, → M1.5.
- **Per-boxed-value-CAF baseline padding** (review #2/#5, documented-not-fixed per the
  no-over-engineering rule): F2 copies a forced boxed CAF's node into its static cell (an uncounted
  alias of the same children) but leaves the original dynamic root cell orphaned-yet-counted in the
  immortal baseline. It is NOT a leak versus the baseline-relative oracle (`stLive == rcBaseline`),
  and nothing drops a CAF in M1, so there is no current bug — but it is baseline waste and a latent
  UAF *if* a future change ever frees a CAF (the static alias would then dangle). → M1.5: allocate
  CAF results in the static region from the start (root + children), removing the alias.
- **List/string `++` is absent from the RC prim table** (first-order scope); programs using concat
  cannot run on the RC interpreter.
- **The differential/property harness treats `(Left, Left)` (both interpreters error) as agreement**
  without comparing error text. Unreachable for the current corpus/generator (only total prims
  `+`/`-`/`*` over literals are generated; no partial ops), but revisit if partial prims enter the
  corpus.
- **CAFs are forced eagerly** by `runModuleRC` (vs the reference's lazy-on-demand), which is why the
  differential harness prunes both modules to the reachable-from-`main` binds for symmetry. An
  on-demand CAF model in `runModuleRC` is a possible M1.5 refinement.

**Milestones.**
- **M1 (this spec):** first-order data RC on the no-handler fragment, validated to heap-empty.
- **M1.5:** the limitations above — closure/HOF RC, prims-as-values, `++`, on-demand CAFs.
- **M2:** continuation-aware drop (the Kont-ownership fold-in turned on; affine drop-of-unresumed).
- **Deferred:** reuse/FBIP, borrow hints, codegen.

---

## 2. Invariants (preconditions for RC completeness)

RC is sound AND complete for wok — **no cycle collector is needed** — provided every one of
these holds. They are load-bearing; document them so a future feature does not silently break
completeness:

1. **Immutable data** — no in-place-mutable, sharable, pointer-bearing cell.
2. **Strict construction** — constructor/record fields are already-bound Atoms (`Anf.hs`), so a
   node can never reference a value that does not yet exist (no knot-tying). No field is
   back-patched after allocation.
3. **Functions-only LetRec** (`Anf.hs:60`) — recursion is on functions, not values, so there is
   no value cycle.
4. **No counted back-edge** — the one cycle wok *can* form is the LetRec closure-env knot
   (`Machine.hs:59-64`, closure -> env -> closure). The RC store MUST represent intra-group
   recursive references as **direct/static (uncounted) edges**: top-level binds are a static
   immortal region; local LetRec groups are an uncounted region dropped as a unit. This is the
   single thing that, if violated, silently breaks completeness.
5. **One-shot continuations** — `Multiplicity.analyzeModule` already enforces this; it makes a
   captured continuation consumed at most once (single consumption frontier).

If any of (1)-(5) is later relaxed (mutable refs, laziness, co-inductive/negative-position
types, multi-shot continuations), a cycle story is required (Bacon-Rajan trial deletion is the
zero-annotation backstop) and the static-precision story narrows.

---

## 3. Pipeline / data flow

```
typecheck
  -> elaborate to ANF (Wok.IR.Anf)
  -> [NEW] Perceus pass: ownership/last-use analysis -> insert dup/drop extern calls   (Section 5)
  -> RC explicit-store CEK interpreter (separate module)                               (Section 6)
  -> validation: differential output + heap-empty + no UAF/double-free + balance       (Section 8)
```

The Perceus pass is a runtime-agnostic ANF transform. The `Store` threads through the RC
interpreter purely (like `IdSupply` today), which deliberately avoids any IO / lazy-CAF /
`unsafePerformIO` hazard — the store is just another threaded value.

---

## 4. Allocation-extern interface (the Store API)

**Value split** (RC interpreter only; the reference interpreter's `Value` is untouched):

```
Value = VLit Lit            -- inline scalar, never counted
      | VBox Addr           -- handle into the Store (was VCon / VRecord / VClosure)
Node  = NCon   Text [Value]
      | NRecord Text (Map Text Value)
      | NClosure Env [Binder] Expr
Cell  = Cell { rc :: Int, node :: Node }
Store = Store { cells :: IntMap Cell, next :: Addr, dead :: IntSet, stats :: Stats }
Stats = Stats { allocs, frees, currentLive, peakLive :: Int }
```

`VInst`/`VCont`/`VContP` do not arise in M1 (no-handler fragment).

**RC operations as prelude `extern` primitives** (compiler-inserted by the Perceus pass; not
user-written; Embedded-origin like the coro prims):

- `extern dup : a -> a` — incref the handle; identity on `VLit`; returns the same handle.
- `extern drop : a -> ()` — decref; at `rc == 0`, recursively drop the node's boxed fields,
  then tombstone the cell; returns unit.
- Reserved for the reuse layer (NOT in M1): `isUnique`, `dropReuse`, `allocAt`.

**Allocation sites** = `RCon`/`RRecord`/`RLam` — they allocate a cell (`rc = 1`, bump `next`,
bump stats) and return `VBox addr`.

**Threading mechanism.** The store threads through the machine purely. `dup`/`drop` reach it via
one new `PrimResult` constructor — `PRStore (Store -> Either RuntimeError (Value, Store))` —
mirroring the existing `PRDrive` seam. No other prim signatures change.

**Free behavior (tuned for the oracle): tombstone-on-free, monotonic addresses.** A freed cell
moves to `dead`; deref of a `dead`/absent addr is a `RuntimeError` (use-after-free caught);
`drop` of a `dead` cell is a `RuntimeError` (double-free caught). Addresses are never recycled in
M1, so a stale handle cannot silently alias a fresh cell (no ABA masking).

**FUTURE:** address recycling (a real free-list / slot reuse) will be needed for memory bounds
and is a prerequisite of the FBIP reuse layer; it is deliberately omitted from M1 because it
would mask the very UAF/ABA the oracle exists to catch. Revisit with the reuse milestone.

---

## 5. The static analysis (Strategy 2 + Kont-ownership fold-in)

A Core->Core ANF pass (Perceus ownership-passing insertion, Reinking et al. PLDI 2021 Sec 3.4,
adapted to wok).

**Principle.** Every boxed value has exactly one owner responsible for exactly one `drop`, or for
passing ownership onward. The pass walks the ANF carrying an **owned set** Delta — boxed locals
that must each be consumed exactly once before the current context ends — inserting `dup` where a
value is shared and `drop` where it dies. dups are delayed toward the leaves; drops are emitted as
early as a value goes dead.

**Per-construct rules (M1 first-order fragment):**

- **`Ret a`** — the result transfers ownership to the caller; every *other* var in Delta is dead
  -> `drop` it before returning.
- **`Let x = rhs in body`** — operands of `rhs` last-used here are consumed (moved, no `dup`);
  operands used again later get a `dup` first. `x` (if boxed) joins Delta for `body`.
- **`RApp` / `RCon` / `RRecord`** — all *consume* operands by ownership-passing (a call hands
  args to the callee; a constructor stores fields into the new cell). `dup` any operand not
  last-used here; move the rest.
- **`Case scrut alts`** — **own-children / drop-parent**: in each `AltCon`, `dup` the matched-out
  children that the alt keeps, then `drop` the parent shell at the match (the recursive
  parent-drop is balanced by those dups). **Branch reconciliation:** every alt must consume the
  same Delta -> insert a `drop` at the entry of any alt where an owned var is dead
  (drop-on-the-dead-branch). Chosen for a uniform owned-only model (simplest oracle invariant) and
  forward-compatibility with the deferred reuse layer (the parent is freed at the match, exactly
  where drop-guided reuse threads the cell); borrowing the parent was rejected because it
  introduces an owned/borrowed two-class distinction and blocks reuse (Lorenzen & Leijen,
  Frame-Limited Reuse, ICFP 2022).
- **`LetJoin` / `Jump`** (join points = phi/block-params) — jump args transfer ownership into the
  join; a var owned at a jump site but not passed is dropped before the jump; the owned set the
  join expects must be **reconciled across all of its jump sites**. This is the fiddliest part of
  the pass (the design doc historically pairs join-point ownership reconciliation with
  drop-placement) and is the spot to budget extra care / a possible follow-up.
- **`LetRec` (functions-only)** — the whole group is one **uncounted region**: intra-group mutual
  references are direct/non-counted; allocated together, dropped as a unit at scope exit
  (invariant 4).
- **Globals** — RC-exempt static region: references to top-level binds are never `dup`/`drop`'d
  (known by top-level Unique).

**Kont-ownership fold-in (specified now, dormant in M1, switched on in M2).** At a perform/`ROp`
site the captured continuation *owns the live owned set at that point* — its capture set is
exactly `Carrier.freeVars` at the suspend point. One-shot => the continuation is consumed once:
resumed (capture flows into the resumed tail, dropped there) or dropped-unresumed (the
continuation's `drop` recursively releases the capture). The resume/op site is a **hard
use-boundary** — drops are never hoisted across it, and a value live across it is owned by the
continuation, not the local frame. Writing this rule now keeps the analysis whole; M2 only turns
it on.

**Mechanics.** Backward last-use liveness over the ANF (a variable's last occurrence, respecting
branches). Reuse `Multiplicity`'s lattice scaffolding for branch joins, but with **data rules**
(capture-into-constructor = ownership transfer = consume, NOT `Many` — the continuation-specific
rule is wrong for data). Reuse `Carrier`'s escape/free-var info for capture sets.

**Output.** The same ANF + inserted `dup`/`drop` extern-call `Let`s + LetRec/global exemption
markers + per-suspend capture-set annotations (for M2). A `--dump-perceus` mode prints it; a
static balance lint ("every owned binder reaches exactly one consume on every path") is a
golden-/property-checkable invariant independent of execution.

---

## 6. Interpreter changes (the RC explicit-store CEK)

**Architectural decision: a separate, independent RC interpreter module**, leaving the current
CEK machine and its `Value` 100% untouched. The existing interpreter is the trusted 809-green
reference; the oracle is *differential* (run both, compare). Two independent implementations give
a real differential signal — an independent bug surfaces as divergence — whereas parameterizing
one machine over a heap abstraction would couple them so a shared bug hides identically in both,
weakening the very signal the oracle exists for. The duplication (~the 380-LOC machine) is
bounded and may be unified once the analysis is proven.

**Deltas vs the reference machine:**
1. **Value/heap types** as in Section 4. `renderValue` and `Eq` deref through the store so output
   matches the reference exactly (required for the differential assert).
2. **Store threading** through `step`/`run`/`evalExpr`/`evalRhs`/`enter`/`returnTo` (like
   `IdSupply` today).
3. **Allocation** at `RCon`/`RRecord`/`RLam`.
4. **Deref** at `RProj` and `Case`; deref of a dead/absent addr -> `RuntimeError` (UAF catch).
5. **`dup`/`drop` prims** via `PRStore`; `drop` at zero recursively drops boxed children then
   tombstones; `drop` of a dead cell -> `RuntimeError` (double-free catch).
6. **`drop` is ITERATIVE** — an explicit worklist in the store, NOT host recursion. Recursively
   dropping a long structure (e.g. a million-cons list whose last reference dies) would otherwise
   blow the Haskell stack.
7. **LetRec = uncounted region** (invariant 4): allocate the group with intra-group edges
   excluded from refcounting; drop the group as a unit. Exact representation (region tag on cells,
   or a side region-table) is an implementation detail for the plan — one of the careful bits.
8. **Globals = static immortal region**: allocated once, never counted, never dropped, and
   **excluded from `currentLive`** so the heap-empty assertion measures only the dynamic heap.
9. **Result handling**: at exit, render the result (read-only deref), then `drop` it, then assert
   `currentLive == 0` and `allocs == frees`. (Final-drop ordering is a careful bit.)

---

## 7. Continuations (M2 preview, not built in M1)

M1 restricts the corpus to the no-handler fragment, so continuations never arise and the
Kont-ownership rules (Section 5) stay dormant. M2 turns them on:
- Attach the static capture set (`Carrier.freeVars` at each suspend point) to each continuation.
- `drop` of an unresumed continuation (cancel / race-loser / orphan — all affine-legal, card
  Zero) recursively releases the capture set and runs finalizers (a finalizer mechanism does not
  exist today — `Control.wok:181` — so M2 introduces one).
- Ownership of a value captured into a continuation transfers to the continuation; it is dropped
  via the continuation, not at its textual last use in the producer.

These are recorded so the M1 analysis is whole; the implementation and its corpus are M2's.

---

## 8. Validation (the oracle)

Harnessed on `tasty` + `tasty-golden`/`tasty-hunit`. Coverage measured with **HPC**
(`cabal test --enable-coverage`), targeting full expression coverage of the new modules
(analysis pass, RC interpreter, store), with Suite F filling gaps the curated corpus misses.

- **Suite A — Differential run (primary).** For each no-handler program, run the **reference
  interpreter on the original (pre-Perceus) ANF** and the **RC interpreter on the
  Perceus-instrumented ANF** in the same test; assert byte-identical rendered output (`dup`/`drop`
  do not change values, so outputs must match). Reference output stays pinned by the existing
  `run-golden`. Corpus: a dedicated `test/rc-examples/` dir (effectful files are guard-rejected by
  detecting `Handle`/`ROp` in the elaborated ANF).
- **Suite B — Heap accounting.** Assert `currentLive == 0` and `allocs == frees` at exit. Plus a
  `--dump-rc-stats` golden (`allocs`/`frees`/`peakLive`) so allocation behavior is pinned (a
  move silently turning into a dup shows up as a diff).
- **Suite C — Oracle-has-teeth.** (a) Store-trap unit tests: tombstone a cell, assert deref-of-dead
  and drop-of-dead raise `RuntimeError`; rc never negative. (b) Fault-injection: a debug knob that
  perturbs the analysis (omit a `drop` -> Suite B reports a leak; omit a `dup` on a shared value
  -> Suite C trips UAF/double-free; duplicate a `drop` -> double-free). Assert the corpus fails
  loudly under each mutation. This certifies the oracle is not vacuous.
- **Suite D — Analysis-output golden.** `--dump-perceus` annotated ANF, golden-tested like
  `anf-golden`; plus the static balance lint (Section 5) over the pass output.
- **Suite E — Targeted micro-programs (rule-by-rule):** shared subterm -> one `dup`; conditional
  consume -> drop-on-dead-branch; linear pass-through -> no `dup`; nested match -> own-children
  chain; record field ownership; local mutual recursion -> letrec-region drop; multi-clause /
  decision tree -> join-point reconciliation; deep list -> recursive-drop at scale (assert
  `frees == N+1`, exercises iterative drop).
- **Suite F — Property-based (in M1 scope).** QuickCheck-generate random first-order ANF
  expressions; run A + B (differential output + heap-empty). Strongest single guard for placement
  bugs the curated corpus misses.

**"M1 done"** = the whole no-handler corpus passes A-F, with the analysis whole (continuation
rules specified but dormant) and HPC coverage of the new modules driven to target.

---

## 9. Careful spots (budget extra design/plan attention)

1. **Join-point ownership reconciliation** (Section 5) — the same job as drop placement; may need
   a focused follow-up.
2. **LetRec uncounted-region representation** (Section 6.7) — region tag vs side-table.
3. **Result-value final-drop ordering** (Section 6.9).
4. **Iterative `drop`** (Section 6.6) — must be a worklist, not host recursion.
5. **Address recycling** (Section 4 FUTURE) — out of M1, prerequisite of the reuse layer.

---

## 10. References

- Reinking, Xie, de Moura, Leijen. *Perceus: Garbage Free Reference Counting with Reuse.* PLDI 2021.
- Ullrich, de Moura. *Counting Immutable Beans.* IFL 2019 (RC completeness for acyclic immutable data).
- Lorenzen, Leijen. *Reference Counting with Frame-Limited Reuse.* ICFP 2022 (borrowing blocks reuse; drop-guided reuse).
- Bacon, Rajan. *Concurrent Cycle Collection in Reference Counted Systems.* ECOOP 2001 (trial deletion — the future backstop if invariants relax).
- Project memory: `rc-perceus-interpreter-plan`, `higher-ir-direction`, `explicit-resume-effect-laundering`.
