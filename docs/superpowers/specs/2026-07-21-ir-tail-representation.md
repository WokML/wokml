---
spec: ir-tail-representation
status: draft
---

# Representing tail position in the IR

**A contract decision, not an optimisation.** Split out 2026-07-21 from
<ref file="2026-07-21-tco-tail-call-contraction.md">the TCO slice</ref>, which created the
debt, and shared with <ref file="2026-07-20-trmc-design.md">TRMC</ref>, whose lowering choice
would settle it.

---

## 1. The problem

The shipped tail-call contraction lives in the **machine**: `callKont`
(`src/Wok/Interp/RC/Machine.hs`) inspects the let-body at run time and decides whether to push
a frame. Nothing in the IR records that a call is in tail position.

<decision id="D1" status="finding">
**Both of this project's targets are codegen targets.** Neither a flight profile nor a
low-latency trading runtime runs on the RC interpreter. A tail-call property that exists only
as an interpreter behaviour therefore delivers nothing to either — a backend would have to
rediscover it independently, and might not, or might do it differently.

This is the same class of concern the runtime already resolved deliberately: `runtime/README.md`
freezes the `wok_rc` ABI as "the surface future codegen emits against", explicitly so that
layout and calling conventions are a contract rather than an interpreter detail. Tail position
has no such treatment.
</decision>

---

## 2. Why it is a contract decision

Getting this wrong is expensive in a way an ordinary optimisation is not:

- The IR is what codegen consumes. A representation choice propagates into every backend.
- Analyses that run over the IR (Perceus, multiplicity, escape/region, reuse pairing) each
  have to be correct about the new form, and several of them already `error` loudly on IR
  shapes they were not designed to see (e.g. `RReuseCon` in `Wok.IR.Multiplicity`,
  `Wok.IR.Escape`, `Wok.IR.Perceus`).
- Changing it later means a coordinated update across the backend and every analysis, which is
  precisely the cost the runtime README warns about for its own ABI.

---

## 3. The candidates

### A. A distinguished tail-call form

Add a tail-call `Rhs`/`Expr` node so tail position is **syntax**, not a pattern each consumer
re-derives.

- **For:** unambiguous; a backend cannot miss it; analyses that must treat tail calls
  specially get a node to match on.
- **Against:** a new IR node is the most invasive option — every exhaustive `case` over the IR
  must gain an arm, including the several passes that deliberately `error` on unexpected forms.

### B. Reuse `LetJoin` / `Jump` for self tail calls

The IR already has `LetJoin JoinId [Binder] Expr Expr` / `Jump JoinId [Atom]`
(`src/Wok/IR/Anf.hs`), and `Jump` already carries exactly "transfer, do not grow" semantics —
the RC machine evaluates the join body under the join's *own* captured continuation `jk`, not
the current `k`.

- **For:** no new node; the semantics already exist and are already implemented correctly;
  every analysis already handles `LetJoin`/`Jump`.
- **For, decisively:** <ref file="2026-07-20-trmc-design.md">TRMC</ref> wants to emit
  `LetJoin`/`Jump` anyway. Choosing B means TRMC's implementation **retires this debt as a
  side effect** rather than adding to it.
- **Against:** join points are *local*; a self tail call is a call to a top-level bind. Whether
  a self-recursive function can be lowered to a local join without changing its calling
  convention or its interaction with Perceus is the open question below.
- **Against:** it does nothing for tail calls to *other* functions (mutual or unknown targets),
  so it is a partial answer.

<decision id="D2" status="re-costed 2026-07-21 after running C1">
B remains the more attractive starting point — it converges with TRMC and needs no new node —
but the experiment moved where its cost sits, in both directions:

- **Cheaper than feared on the analysis side.** Perceus already handles recursive joins
  correctly; no fixpoint work is needed (<ref>C1</ref>, findings 1-2).
- **Blocked on the machine side.** `RCJoin` captures a scope that excludes the join, so a back
  edge is unbound at run time (finding 3). B requires changing what a join point *is*.

The mechanical change is small (a lazy knot). The semantic change — "non-recursive label"
becomes "label" — is a contract change, and at least four other consumers (`Wok.IR.Escape`,
`Wok.IR.Multiplicity`, `Wok.IR.Region`, the reference interpreter) have not been checked
against it.

B also still covers only *self* tail calls, so it is not a complete answer to <ref>D1</ref>.
A plausible end state remains **both**: B for self-recursion (TRMC's natural output), A later
if general tail calls need to reach codegen.

**Still not decided**, but the open question is now narrow and concrete: <ref>C4</ref>.
</decision>

---

## 4. What each target actually needs

| target | needs | why |
| ------ | ----- | --- |
| flight profile | tail position visible to a **verifier**, not just to a backend | the profile's value is an independently checkable certificate; a property the compiler knows but does not record cannot be re-checked |
| soft real-time / trading | tail position honoured by the **backend** | a growing continuation in a long-running event loop is resident-memory growth, not just latency |

<decision id="D3">
The two targets want the same thing here for once, with no divergence in guarantee strength —
unlike the FBIP `rc == 1` gate, where trading tolerates a dynamic test and flight does not.
Tail position is either recorded in the IR or it is not.

That makes this the **cheapest cross-target win available**: one representation choice serves
both, with no tightening step and no forked implementation.
</decision>

---

## 5. Challenges

<challenge id="C1" summary="can a self tail call actually be lowered to a join point?">
Option B assumes a self-recursive top-level function can become a `LetJoin` with the recursive
call as a `Jump`. Join points are local to a body and take a fixed parameter list; a top-level
bind has a calling convention, may be referenced as a value, and its parameters are owned
on entry under Perceus's discipline. Whether the lowering preserves all of that — especially
the ownership of parameters across a `Jump` versus across a call — is unverified.
</challenge>

<response to="C1" status="RUN 2026-07-21 — answered, and it moves the cost to a different place">
Experiment run in `cabal repl lib:wok` against hand-built IR (the seam `test/Spec.hs` already
uses for `regShape1`). Shape: a **recursive** join with boxed parameters —

```
walk xs w =
  letjoin go(ys) = case ys of
                     Nil      -> 0
                     Cons v t -> let c = Box(w) in jump go(t)   -- BACK EDGE
  in jump go(xs)
```

**Finding 1 — Perceus handles recursive joins correctly.** It did not error and did not
mis-instrument. Emitted, for the adversarial shape where the captured outer local `w` is
consumed on the recursive arm:

```
Cons v t ->
  let _dup.1  = __rc_dup(t)
  let _drop.3 = __rc_drop(ys)
  let _dup.2  = __rc_dup(w)
  let c = Box(w)
  let _drop.4 = __rc_drop(c)
  jump j9000(t)
Nil ->
  let _drop.1 = __rc_drop(ys)
  let _drop.2 = __rc_drop(w)
```

Hand-traced over N iterations: each iteration's `dup w` is matched by the `drop c` cascade in
the same iteration (net zero), and `w` is dropped exactly once on the exit arm. Balanced.

**Finding 2 — the "no fixpoint" claim is true, but not for the stated reason.**
`src/Wok/IR/Perceus.hs` says *"no fixpoint is needed because joins are non-recursive"*. The
load-bearing property is actually that **a join's expected owned set is declared by its
signature** (boxed params + `cap j`), not inferred from its body, so every jump site —
including a back edge — reconciles to the same fixed expectation locally. Non-recursiveness is
not what makes it work. The `closeJoins` termination comment is likewise over-cautious: it
carries a `seen` set, so a self-edge terminates regardless.

**Finding 3 — the blocker is the machine, not the analysis.** Executing the module fails:

```
RUNTIME ERROR: UnboundVar "j9000"
```

`src/Wok/Interp/RC/Machine.hs`, the `LetJoin` arm:

```haskell
LetJoin j ps jb body ->
    let jp = RCJoin sc ps jb k          -- captures sc, which does NOT contain j
    in pure (REval body sc { rscJoins = Map.insert j jp (rscJoins sc) } k s)
```

`RCJoin` captures the scope *before* the join is inserted, so `jbody` runs without `j` in
`rscJoins` and a back edge is unbound. This is a faithful implementation of "join = a
non-recursive label" — the machine is not buggy, it is enforcing the semantics.

<decision id="D4" status="finding">
**Recursive joins are unrepresentable in the machine's join semantics, and Perceus is silently
permissive about it.** Perceus accepted and correctly instrumented IR the machine then refused
to run. There is no IR-level validation catching this.

That is a finding independent of this spec's subject and worth fixing on its own: an analysis
that blesses IR the evaluator rejects is a gap in the contract, whatever is decided about tail
calls.
</decision>

The cost of option B therefore moves: it is **not** "extend Perceus with a fixpoint" (Perceus
is already fine). It is **"change what a join point means"** — `RCJoin` would need to capture a
scope including itself (a lazy knot, which the codebase already does for the static env in
`reserveStatic`). Mechanically that is small; semantically it changes an IR concept from
"non-recursive label" to "label", which is exactly the kind of contract change <ref>D1</ref>
says must be deliberate.

Still unanswered, and now the remaining question for B: does anything else — `Wok.IR.Escape`,
`Wok.IR.Multiplicity`, `Wok.IR.Region`, the reference interpreter — rely on joins being
non-recursive? Only Perceus was tested.
</response>

<challenge id="C2" summary="does this block TRMC, or does TRMC decide it?">
Circular on its face: TRMC's lowering choice would settle the representation, but the
representation is a contract that ought to be decided deliberately rather than as a side
effect of one feature.
</challenge>

<response to="C2" status="resolved">
Not circular in practice, because <ref>C1</ref> is answerable independently of TRMC and is
cheap. Order:

1. answer <ref>C1</ref> with the hand-built lowering — no product code, no TRMC dependency;
2. if the lowering is sound, adopt B for self tail calls and let TRMC emit it, which retires
   this debt as a side effect;
3. if it is not, TRMC needs option A or a different lowering, and this document becomes a
   prerequisite of TRMC rather than a companion to it.

So the dependency runs one way and the experiment comes first. TRMC should not start choosing
its lowering until step 1 is done.
</response>

<challenge id="C3" summary="is the machine-level contraction wrong to keep in the meantime?">
With tail position unrepresented in the IR, `callKont` is a behaviour the IR does not describe
— arguably the reference implementation and the contract have already diverged.
</challenge>

<response to="C3" status="resolved">
Keep it. It is semantics-preserving (`callKont` only ever removes a frame — post-change depth
is bounded by pre-change depth pointwise), it is verified by the full suite, and it makes
TRMC's benefit real rather than notional.

The divergence it creates is one of *precision*, not of meaning: the interpreter is better than
the IR says it must be. That is a safe direction — a backend that ignores tail position
produces a correct program with worse depth, not a wrong one. The unsafe direction would be an
IR that promises a property the machine does not deliver.

This response is the record that the interim state is deliberate.
</response>

---

<challenge id="C4" summary="what else assumes joins are non-recursive?">
<ref>C1</ref> tested Perceus only, and found it safe. `Wok.IR.Escape`, `Wok.IR.Multiplicity`,
`Wok.IR.Region` and `Wok.Interp.Machine` all walk `LetJoin`/`Jump` and none was checked. Any
one of them relying on acyclicity — for termination, or for a "each join visited once"
assumption — turns option B from a small knot into a broader change.
</challenge>

<response to="C4" status="RUN 2026-07-21 — no consumer broke; two new findings">
**The change made.** `Machine.hs`'s `Jump` arm now re-inserts `j` into the scope `jbody` runs
under, making a join a recursive label. **Reconstructed inline, not stored** — the lazy-knot
alternative is both unavailable (repo-wide `StrictData` + `Data.Map.Strict` would `<<loop>>`)
and undesirable (it would put a cyclic Haskell structure inside an `RCScope`, which is
reachable from a *counted* `NCont` cell — the margin <ref>C5</ref> describes). Inline
reconstruction keeps every stored `RCJoin` acyclic, mirroring the M2a-2 `LetRec` treatment.

Probes, all against hand-built IR in `cabal repl lib:wok`. **The instrument was validated
first** (sum 1..n for n=1/2/3/5 → 1/3/6/15) before any number below was believed:

| probe | result |
| ----- | ------ |
| depth vs n (1 → 1000) | `kontPeak = 1`, **constant** |
| deep iteration, n=1000 | out=500500 correct, allocs==frees, balanced |
| C heap backend | same numbers, balanced |
| FBIP `reusePairing` | same numbers, balanced |
| `Escape.arenaEscapes` | no hang; `ys`→False, `w`→True (plausible) |
| `Region.planRegions` | no hang; **binder 8005 → `Arena`** |
| `Multiplicity.analyzeModule` | `[]` — accepts |
| **resume crossing the back edge** | correct at n=1/3/5/50; `kontPeak = 2` **constant**; balanced |
| nested recursive joins (both with back edges) | correct at n=1/3/5/30; `kontPeak = 1`; balanced |
| reference interpreter | `Left (UnboundVar "j9000")` — **still diverges** |
| full suite | 2193/2193, 33.63s |

<decision id="D5" status="finding">
**Arena allocations accumulate per *activation*, not per iteration.** The loop-body
`c = Box(w)` is `Arena`-placed, so it never enters `stAllocs` (separate books) — which is why
counted allocs stayed at n+1 and looked like the allocation was not happening. The arena
counters show what is really going on: `arenaPeak` = 80 bytes at n=5, **3200 at n=200** —
16 bytes per iteration, released only when the activation exits.

A long-running loop therefore grows the arena without bound. **Same shape as
<ref file="2026-07-21-parameterized-resume-frame-leak.md">D0c</ref>, in a different resource**,
and it matters for the same target: a trading event loop, not a bounded mission phase.

Incidentally this is the first non-zero arena placement observed anywhere — the corpus sweep
measured zero across all real code (context doc §3). The shape that earns it is the one
predicted: allocate, consume immediately, never escape.
</decision>

<decision id="D6" status="finding">
**D0c is confirmed narrow by this run.** The resume-crossing-a-back-edge probe uses a
*non-parameterized, tail-resumptive* handler (`tick n k -> k n`) and its depth is **constant at
2 through n=50**. Only the parameterized two-argument resume grows. That corroborates the
`get`/`set` asymmetry from the other spec by an independent route.
</decision>

**Retracted from an earlier pass of this work:** a `cardOf` probe was used to argue
Multiplicity was safe. It was a category error — `cardOf` returns `Many` for *every* ordinary
variable, including one used exactly once in a module with no joins at all (`Zero` only for
unused). It measures continuation multiplicity for the one-shot law, not general usage. That
probe proved nothing and the conclusion drawn from it does not stand; the resume-crossing-back-
edge probe above is the real test, and it passes.

<open_question id="Q1" status="all three closed 2026-07-21">
**Reference interpreter — mirrored.** `Wok.Interp.Machine`'s `Jump` arm got the identical
inline reconstruction, with a comment saying why the two must stay in lockstep. Oracle #1
(`rcDifferentialHarness`, reference vs RC) is restored: both machines agree on a recursive
join at n = 1 / 3 / 5 / 50 / 200. Full suite green afterwards, 2193/2193, 24.59s.

**Mutually recursive joins — they work, contrary to prediction.** `jA` → `jB` → `jA` runs
correctly and balanced at n = 1 / 3 / 5. The prediction that they would fail was wrong: `jB`
is defined *inside* `jA`'s body, and that body has already had `jA` re-inserted by the
reconstruction, so `jB`'s captured scope can see `jA`. Lexically nested mutual recursion is
therefore covered, not just self-recursion.

**Abort through a recursive join — balanced.** A handler arm that discards its resume, so the
continuation reified from inside the recursive join (owning the boxed rest-of-list) is dropped
and `cascadeChildren` runs on it: `allocs == frees`, `live == 0`, at n = 1 / 3 / 5 / 20.
Controls with no join and with a non-recursive join are likewise balanced.

<assumption id="A2" status="process note, not a finding">
That last probe first reported a **large leak** (n=20 leaking 20 cells). It was a defect in the
hand-built IR, not in the machine: the resume binder was typed `U64` instead of a function type
`U64 -> {} -> U64`, so Perceus did not treat it as a counted value and emitted no drop for the
discarded resume.

Two checks caught it before it was reported as a finding — the real corpus
(`test/rc-c-backend/fbip-effect-abort.wok`) balances at `allocs = frees = 4`, and the
no-join/non-recursive-join controls leaked *too*, which a change-induced regression would not
explain.

Worth recording because this is a bug class the project has already fixed once and written
down (the M2b resume-binder-type leak: the binder must be `T -> R`, not `R`). Hand-built IR
bypasses the type checker, so it can silently reproduce exactly the errors the front end
exists to prevent — **a hand-built-IR probe is not evidence until a control says the effect
is specific to the change under test.**
</assumption>
</open_question>

<!-- superseded by the RUN response above; kept for the prioritisation it records -->
<details><summary>original plan for C4</summary>

Directly answerable by the same method that answered <ref>C1</ref>, and it should be done
before B is adopted: run the hand-built recursive-join module through each pass and look for a
hang, an `error`, or a wrong answer.

Prioritise by likely fragility:

1. **`Wok.IR.Escape`** — it computes reachability over join edges; a cycle is the classic hang.
2. **`Wok.IR.Multiplicity`** — counts occurrences; a back edge means an occurrence count that
   is a loop bound, not a constant, which is exactly the kind of thing a one-shot analysis
   could get wrong *silently*.
3. **`Wok.IR.Region`** — walks joins for placement; likely benign but unverified.
4. **the reference interpreter** — same `LetJoin` scope-capture question as the RC machine;
   probably fails identically, which would at least keep the two machines consistent.

Note the shape of the risk revealed by <ref>D4</ref>: the failure mode here is not a loud
error. Perceus *silently accepted* IR the machine rejects, so "it did not crash" is not
evidence any of these four are safe.

</details>

<challenge id="C5" summary="does a recursive join break the project's no-cycle commitment?">
wok's RC has no cycle collector, so the design **prevents** cycles rather than collecting
them. The commitment is recorded in code:

- `Machine.hs:254` (M2a-2 `LetRec`) — the intra-group knot is re-tied inline so "there is no
  counted cycle to break"
- `Machine.hs:1010` — "mutual-recursion knot is re-tied without a counted cycle"
- `Value.hs:803` (M3 continuation cells) — the park slot never overwrites a live value, "so it
  forges no cycle"

Option B's lazy knot makes `RCJoin` reference a scope that contains itself. On its face that is
exactly the shape the project has three times gone out of its way to avoid.
</challenge>

<response to="C5" status="resolved, with a caveat worth keeping">
**The commitment is not broken.** Three independent reasons, in increasing order of how much
they should be trusted:

1. **Wrong heap.** `RCJoin` is a Haskell value in `rscJoins :: Map JoinId RCJoin`
   (`Value.hs:271`), managed by GHC's collector. The knot is a cycle in the *interpreter's own*
   data, not in the RC store. GHC collects cycles; wok's refcounts never see it.
2. **No counted edge is created.** Scopes are captured **by reference without increfing** —
   `KHandleRC` "captures `sc'` BY REFERENCE, exactly like the `KLetRC b body sc k` frame
   captures its `sc` WITHOUT increfing… We do NOT incref the scope's values on install." A
   captured scope therefore adds no refcount edge that could close a counted loop.
3. **No drop path can reach it.** `rscJoins` appears **exactly once** in
   `src/Wok/Interp/RC/Value.hs` — at its own declaration. No cascade, no owned-set computation,
   no drop worklist reads it. `cascadeChildren (NCont prefix _)` discards the scope component
   outright, and `continuationOwned` walks frames via `rscEnv` only.

**Why this differs from the M2a-2 precedent**, so nobody later "fixes" joins by analogy: the
`LetRec` case involved **counted heap cells** (a shared `NEnv`), where a stored self-reference
*would* be a counted cycle, hence the inline-reconstruction workaround. A join point is not a
heap cell and is not counted, so the workaround is unnecessary here.

<assumption id="A1" status="holds today, but incidentally">
Reason 3 is the load-bearing one, and it is **incidental rather than designed**.
`rcDispatchOp` allocates `NCont prefix (h, hTag, hsc)` — an RC-*counted* cell whose payload
contains an `RCScope`, hence `rscJoins`. A Haskell-cyclic join structure would therefore sit
inside a counted cell. It is safe only because `cascadeChildren` matches `(NCont prefix _)` and
throws the scope away.

If a future slice makes any cascade or owned-set walk descend into `hsc` — plausible, if some
other leak is traced to values held in a captured handler scope — a recursive join turns that
walk into an infinite loop. The margin rests on one `_` in one pattern match.

If option B is adopted, that `_` should get a comment saying why it must stay a `_`.
</assumption>
</response>

---

## 6. Acceptance criteria

For the decision (not an implementation):

1. <ref>C1</ref>'s hand-built lowering exists as a test, with results, heap accounting and
   depth compared against the un-lowered version.
2. The ownership questions in <ref>C1</ref>'s response are answered explicitly, not assumed.
3. A choice between A, B, and A+B is recorded here with its rationale, and the rejected options
   kept rather than deleted.
4. If B is chosen, <ref file="2026-07-20-trmc-design.md">TRMC</ref>'s lowering section is
   updated to reference this decision rather than restating it.
