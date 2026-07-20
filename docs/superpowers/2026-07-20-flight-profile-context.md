# Flight profile — context

Date: 2026-07-20. Status: **brainstorm capture, pre-spec.** Nothing here is decided.

This records where the "can wok's runtime go on a satellite?" thread got to, and the
empirical findings behind it, so the specs that follow are built on measured facts rather
than on the conversation's memory of them.

## Specs spawned by this thread

| spec | subject | status |
| ---- | ------- | ------ |
| `specs/2026-07-21-tco-tail-call-contraction.md` | tail calls stop growing the continuation | **shipped** 2026-07-20, 2 open follow-ups |
| `specs/2026-07-20-trmc-design.md` | modulo-constructor recursion → loop | draft, blocked on its C1 + C8 |
| `specs/2026-07-21-parameterized-resume-frame-leak.md` | `set`-shaped ops leak one frame each | draft, localised but **not root-caused** |
| `specs/2026-07-21-ir-tail-representation.md` | tail position as an IR contract, not a machine behaviour | draft, one cheap experiment gates it |

They were one document until 2026-07-21; the last three were discovered while prototyping the
first. Read this file for *why* the work exists and what was measured; read the specs for what
to build.

---

## 1. The goal, restated

The starting question was "make the runtime small and portable like OxCaml's". That framing
is wrong on the facts and was dropped:

> **OxCaml is not a spaceflight runtime.** It is Jane Street's OCaml fork for low-latency
> trading (modes: locality / uniqueness / affinity; unboxed types; SIMD). What is actually
> worth borrowing is not "be like OxCaml" but the property its locality mode delivers:
> **a code path that provably does not allocate, checked by the compiler.**

The goal was then re-stated by the user as two things — *interpretability* (the compiler can
explain its memory behaviour) and a *verifiable process*. The claim this document rests on:

> **These are the same technical requirement — memory behaviour that is statically
> decidable.** Interpretability is "the compiler can say why"; flight-worthiness is "the
> compiler can prove the bound". One artifact serves both.

So the proposed unit of work is not a smaller runtime. It is a **flight profile**: a
compile-time-enforced subset of wok, in the sense that MISRA C is a subset of C. Violations
are compile errors, not runtime discoveries.

<open_question id="Q1">
Is this a research identity for wok ("the language whose memory behaviour is a proof"), or
is there a real target board / mission? The answer changes the deliverable: identity ⇒ the
certificate is the product; real mission ⇒ a whole tool-qualification stack follows.
Unresolved as of this writing.
</open_question>

---

## 2. What we measured (2026-07-20)

All of the following was read out of the tree, not recalled.

### 2.1 Dynamic RC has exactly one true consumer

`wok_rc` (the non-destructive refcount peek, `runtime/wok_rc.h:43`) has **one production
call site** in the whole tree:

- `src/Wok/Interp/RC/Value.hs:3230` — `arrayUnique`, gating `Array.set`'s in-place write.

Everything else that "needs rc==1" does **not** peek. It rides the decrement's return value,
which is information the drop operation already produces:

- **FBIP reuse** — `rcDropReuse` (`src/Wok/Interp/RC/Prim.hs:202`): "when the decrement hits
  zero (unique), RETAINS the freed shell as the token".
- **FFI owned move-out** — the foreign dispatch is the sole dropper
  (`src/Wok/Interp/RC/Machine.hs:409` and its comment block).

<decision id="D1">
Distinguish **"did my decrement reach 0"** (intrinsic to drop; costs nothing extra) from
**"am I unique while still holding"** (a genuine dynamic query). Only the latter is dynamic
RC in the sense that matters here, and wok has exactly one instance of it.
</decision>

### 2.2 The counter is needed exactly when sharing is data-dependent

Perceus places `drop x` statically. What it cannot decide statically is whether a given drop
is the *last* one, and that is undecidable precisely when the sharing degree depends on
runtime data:

1. branch aliasing — `let ys = if b then xs else zs`
2. storing into a structure that may already hold the value
3. loop-carried sharing
4. higher-order / polymorphic code, where the callee cannot see the caller's ownership

Conversely, **region-inferred allocations need no counter at all**: arena cells are
uncounted and `dup`/`drop` on them are already no-ops (`runtime/README.md`, section
"Uncounted cells: inert dup/drop").

### 2.3 The certificate already exists

`src/Wok/Interp/RC/Machine.hs:102`:

```haskell
rcePlacement :: Map Unique Placement    -- Arena | Heap
```

Every allocation binder is **already** statically labelled arena-or-heap, by a pass
(`Wok.IR.Region.planRegions`) that is documented as pure and idempotent
(`src/Wok/IR/Region.hs:102-104`).

<decision id="D2">
The flight-profile predicate does not need new analysis. Candidate form:

> a program is flight-legal **iff** `rcePlacement` contains no `Heap`.

Stronger and more explainable variant: run Perceus as normal, then a pass proving every
emitted `__rc_dup` / `__rc_drop` lands on an arena binder and deleting them all. Any
survivor is a compile error naming the binder and its escape site.

This yields one artifact that is simultaneously the memory bound, the human-readable
explanation, and something an **independent small verifier** can re-check — which is the
answer to "who qualifies the Haskell compiler?" (nobody has to, if the certificate is
checkable downstream). Whether that argument holds under real standards is <ref>Q2</ref>.
</decision>

<open_question id="Q2" status="researched 2026-07-20, partially answered">
Does a compiler-emitted, independently-checkable certificate reduce tool qualification burden
under DO-178C / DO-330? **Structurally yes; formally unsettled.** See §5.3.
</open_question>

### 2.4 Two holes that would make the certificate self-deceiving

**Hole A — the silent fallback to counted heap.** `src/Wok/Interp/RC/Machine.hs:427`:

```haskell
allocRouted bd node st = case Map.lookup (binderUnique bd) (rcePlacement env) of
  Just Arena -> arenaAlloc node st
  _          -> alloc node st        -- <-- "not planned" degrades to counted
```

Default-is-permissive. Under D2's predicate, "contains no `Heap`" could be satisfied by
*never having analysed the binder*. In a flight profile an unplanned binder must be a hard
error.

**Hole B — the runtime-decided heap.** `runtime/README.md`'s encodable-or-fallback rule: a
value lands on the C heap or the Haskell `IntMap` heap depending on field contents,
`arity > 255`, and *first-kind-wins descriptor recording* — meaning **the same constructor
can land on different heaps depending on which instantiation executed first**. Memory layout
that depends on execution order is not verifiable. Flight profile must require all
constructors be statically C-encodable, as a compile error.

Both holes are the same disease in two forms: *the permissive answer is the default*.

### 2.5 The coverage ceiling is much tighter than expected

`Wok.IR.Region.planRegions` has two fences:

- **Module-level effect fence** (`src/Wok/IR/Region.hs:124`): if the module contains **any**
  `Handle`, *every* allocation in it is forced `Heap`. The comment (lines 106-121) explains
  why this over-approximation is sound: an effect-free body `A` can still have its arena
  bracket captured by a handler installed above it in the caller chain, and proving otherwise
  is interprocedural.
- **Per-body continuation fence** (`src/Wok/IR/Region.hs:164-167`): a body that captures a
  continuation is all-`Heap`.

Critically, `planRegions` runs on the **whole-program** `CoreModule` produced by
`elaborateProgramFull` (which includes prelude binds — `app/Main.hs:77`). Consequence to
verify empirically:

There is also a **third, coarsest gate** above both, in the machine
(`src/Wok/Interp/RC/Machine.hs:1584`):

```haskell
let plan | null (firstOrderNoHandlerViolations cm) = rpPlacement (planRegions cm)
         | otherwise                               = Map.empty
```

`firstOrderNoHandlerViolations` (`src/Wok/IR/Reachable.hs:123`) requires every bind
**reachable from `main`** to be handler-free. Note it is reachability-scoped, and
`pruneToReachable` runs before `planRegions` on the production path.

<assumption id="A1" status="REFUTED 2026-07-20">
Predicted: any linked module containing a handler (including the prelude) forces the whole
program all-`Heap`, and this would dominate the dogfood numbers.

**Measured false.** Gate 1 is reachability-scoped and `pruneToReachable` removes unreached
prelude handlers, so `gate.firstOrder` reports OK on 14 of 17 runnable corpus files. The
gates are *not* the binding constraint. See §3.
</assumption>

---

## 3. Dogfood result (measured 2026-07-20)

Added `--dump-region` (`app/Main.hs`), which mirrors the `--dump-rc-stats` pipeline exactly
(whole-program elaborate → `pruneToReachable` → Perceus → reuse pairing) and then re-derives
the plan and the gates the machine consults. Pure reporting; nothing executes.

Swept `examples/` + `bench/` + `test/examples/`. 17 files reach the region planner; the rest
skip (most `test/examples/` are parser/typechecker fixtures with no `main`, plus three
`examples/` files failing typecheck with `ArityMismatch` in the current working tree —
`generators-pull`, `pull-take`, `pull-zip`, unrelated to this thread and not investigated).

**The headline number:**

```
binders.arena = 0     — on every single file, without exception
```

Including files where **both gates pass**: `bench/tree.wok` (2 binders, gates OK,
0 fenced bodies), `examples/probabilistic.wok` (27 binders), `examples/nondeterminism.wok`
(13), `examples/as-patterns.wok` (15), `examples/collatz.wok` (3), `bench/{list,maybes}.wok`.

<decision id="D4" status="finding">
**The gates are not the binding constraint. The escape rule is.** `placeLet`
(`src/Wok/IR/Region.hs:332`) routes `Arena` only when
`not (arenaEscapes (singleton bd) cont)`. In a pure functional language, allocations are
overwhelmingly *returned* — they escape their activation **by construction**.

`bench/tree.wok` is the clean illustration: `build d = Node 1 (build (d-1)) (build (d-1))`
allocates a `Node` and returns it. There is no scratch cohort for a per-activation arena to
hold, in that program or in any other corpus program.

Corroboration from the other side: the only shape in the test suite that yields `Arena`
(`regShape1`, `test/Spec.hs:21228`) allocates a `Pair`, immediately destructures it, and
returns a scalar — pure scratch. That shape is precisely what a case-of-known-constructor /
unboxing pass would delete outright.
</decision>

### What this does to the plan

<decision id="D5" status="finding">
**D2's predicate ("`rcePlacement` contains no `Heap`") is satisfiable by exactly zero real
wok programs today.** The flight profile cannot be built on R1's per-activation arena as it
stands — not because of the effect fence or the continuation fence, but because the arena's
underlying model does not match the language.

A per-activation arena is an *imperative* memory model: locals die with the frame. Functional
allocation flows outward. Making regions carry real wok code plausibly requires the region to
be supplied by the **caller** (Tofte-Talpin-style region polymorphism, or a whole-program
"one arena per top-level entry" shape), which is a substantially larger design than R1 — not
a widening of it.
</decision>

This is a negative result and it lands *before* any spec was written on top of the
assumption. That was the point of measuring.

### 3b. The second candidate predicate, also measured

If regions cannot carry the profile, the other standard formulation is the one actual flight
software uses: **no dynamic allocation after initialization**. Measured with the existing
`--dump-rc-stats` (no compiler change needed): `allocs - baseline` is a lower bound on
allocations performed after top-level binds are installed.

Only 8 corpus files reach the RC interpreter at all (the rest are rejected by the boundary
guard or fail typecheck in the current tree). Of those 8:

```
bench/bools.wok            allocs=0    baseline=0   post-init=0     PASS
bench/tree.wok             allocs=255  baseline=0   post-init=255   FAIL
bench/list.wok             allocs=100  baseline=0   post-init=100   FAIL
bench/maybes.wok           allocs=72   baseline=0   post-init=72    FAIL
examples/state-accumulate  allocs=26   baseline=0   post-init=26    FAIL
examples/named-instances   allocs=10   baseline=0   post-init=10    FAIL
test/examples/26,27        allocs=1    baseline=0   post-init=1     FAIL
```

**1 of 8 passes, and it passes vacuously.** `bench/bools.wok` is a 1000-iteration loop over
`U64` and `Bool` only: `U64` is a scalar, and `True`/`False` are nullary constructors, which
since Layout Compaction Slice 2 are inline immediates that are never cells. It allocates
nothing because it builds no data. (Incidentally its header comment — "exercising Bool heap
allocations" — is now stale for the same reason.)

<decision id="D6" status="finding">
**Both candidate predicates are blocked, for one shared reason.** Every corpus program that
builds a data structure fails both; the only program that passes either one builds no data
structure at all. Region placement and zero-post-init-allocation are two different framings
of the same demand — *do not construct heap data at runtime* — and that is what wok programs
are made of.

Neither predicate is therefore rescuable by picking a better analysis. The obstacle is the
program style the language encourages, not the precision of the escape checker.
</decision>

### 3c. The path the measurements point at instead

The flight-software answer to "no allocation after init" is not "analyse harder", it is
**preallocate storage at init, then mutate in place**. wok already has both mechanisms:

- `Array.set` writes in place when uniquely owned (Array Slice C)
- FBIP reuse re-stamps a dead cell's shell instead of allocating (FBIP Slice 1)

So a plausible flight profile is: *arrays allocated at initialization; a steady state that
only mutates them; no constructor allocation on the hot path.* That is a **program-style**
restriction the compiler can check, rather than an analysis that must succeed.

<open_question id="Q3">
Both mechanisms are gated at runtime on `rc == 1`, not statically. `arrayUnique`
(`src/Wok/Interp/RC/Value.hs:3230`) is the single dynamic-refcount read in the entire
codebase (<ref>D1</ref>) — and it is exactly the gate this path would be load-bearing on.
A flight profile needs that uniqueness **proven at compile time**, not peeked at runtime,
which reopens the uniqueness-typing question the project has so far avoided (one-shot /
affine multiplicity exists; full uniqueness does not).

Unresolved, and it is now the central design question rather than region model selection.
</open_question>

### 3d. FBIP steady state, measured — the first positive result

The corpus benchmarks do not exercise FBIP at all (`bench/list.wok` is build+length: nothing
is dropped-and-rebuilt, so its 100 allocs are the spine itself, not a reuse failure). The
dedicated corpus (`test/rc-c-backend/fbip-*.wok`) does. Measured:

```
test/rc-c-backend/fbip-map.wok       allocs=3    (spine is 3 cells; mapInc allocates 0)
test/rc-c-backend/fbip-reverse.wok   allocs=3
test/rc-c-backend/fbip-shared.wok    allocs=5    (the negative case: shared spine, no reuse)
```

Scratch probe — build 10 cells once, then `mapInc` over the same spine **five times**:

```
allocs = 10        (not 60)      result 105, correct
```

<decision id="D7" status="finding">
**FBIP delivers a genuinely allocation-free steady state.** Construction costs N cells;
every subsequent same-shape transform costs zero. This is the "preallocate, then reuse in
place" shape, and it works today — no new mechanism required.

This materially qualifies <ref>D6</ref>. D6 remains true as stated (neither *whole-program*
predicate is satisfiable), but the reason is now visible: the corpus programs fail because
they *construct* their data at runtime, not because the steady state is unavoidably
allocating. Separate the two phases and the steady state is already clean.
</decision>

Three limits on D7, all real:

1. **The `rc == 1` gate is dynamic.** `fbip-shared.wok` is the designed negative case: a
   shared spine silently falls back to allocating. Performance degrades predictably in
   principle but the *guarantee* is not static — this is <ref>Q3</ref> again, and it is the
   single thing standing between D7 and a flight-grade claim.
2. **Same-arity / same-slot-kind only.** `wok_alloc_at` asserts an arity match
   (`runtime/wok_rc.c:315`), and `fbip-kindchange.wok` / `fbip-intwidth-flip.wok` cover the
   slot-kind cases. Shape-changing transforms still allocate.
3. **It does not help fresh construction or growth** — only transforms of existing data.

<decision id="D8" status="proposed">
Limit 3 is exactly what an **explicit, longer-lived region** covers, and it also explains why
R1 found nothing: R1 *infers* a region per activation, and functional allocations outlive the
activation. A region whose extent is *declared* by the programmer and lives for a request /
tick / frame sidesteps inference entirely — the compiler's job shrinks from "discover where
regions are" to "check nothing escapes this one", a local check rather than a global
inference.

So the two proposals are complementary, not alternatives: **FBIP for the steady-state
transform loop; an explicit preallocated region for per-event fresh data.** Together they
also blunt the unbounded-cascade tail-latency problem, since arena data is bulk-reset rather
than cascaded.
</decision>

---

## 4. The one decision still open

Whether closures / continuations / effects are in the flight profile at all.

R1's current limits (handler-free modules, L5 ceiling) mean **the subset it already covers is
approximately the subset that excludes them.** Two directions:

- **Exclude them.** Flight profile = first-order, effect-free, region-inference-total. Mostly
  supported today; the missing pieces are the predicate, the drop-deletion pass, and closing
  holes A and B.
- **Include them.** Requires answering "what happens to an escaping closure", which is the
  open interprocedural problem behind both fences.

<decision id="D3" status="superseded by D5">
Prefer excluding them initially: cut the subset small enough that the certificate can be
delivered end-to-end today, even if it admits very few programs, then widen.

**Superseded.** D3 assumed "cut it small enough and something passes". §3 measured that the
small end is *empty* — excluding closures and effects does not help, because `bench/tree.wok`
already has neither and still places nothing in an arena. The open decision is no longer
"what to exclude" but "what region model to adopt", per <ref>D5</ref>.
</decision>

---

## 5. Standards research (2026-07-20)

Full briefing with source links is in the session transcript. Confidence markers preserved:
**[V]** verified from primary/near-primary source, **[S]** secondary only, **[I]** inference,
**[?]** unconfirmed. Only the decision-relevant extracts are kept here.

### 5.1 Corrections to §1 of this document

Two claims made earlier in this document, from recollection, are now **corrected**:

<decision id="D9" status="correction">
**"Space standards forbid dynamic allocation after init" is a myth as stated.**

- **ECSS-Q-ST-80C Rev.2 (2025)** contains *no* requirement on dynamic memory and *no* WCET
  requirement at all **[V]** (full-text searched; "memory" appears 3x, all about shared-memory
  partitioning between criticality levels). Clause 6.3.4 delegates to a project coding
  standard. The prohibition seen in practice is project-imposed (MISRA or a prime's C/Ada
  subset), not ECSS text **[V]** for the negative, **[I]** for the attribution.
- **DO-178C does not forbid it either.** The guidance is in supplement **DO-332/ED-217**,
  which adds exactly two objectives to DO-178C, one of them dynamic memory management, and
  frames it as **"must be shown robust with a Vulnerability Analysis"** — a
  *justify-with-analysis* regime, not a prohibition **[V]**. "No allocation after init" is an
  industry *mitigation strategy* chosen because it discharges the vulnerabilities trivially
  **[I]**.
- **MISRA C:2012 Dir 4.12** ("Dynamic memory allocation shall not be used") and **Rule 21.3**
  (no `<stdlib.h>` alloc/free) are both **Required, not Mandatory** — deviable with a
  documented rationale **[V]** on categories, **[S]** on deviation semantics.
</decision>

### 5.2 The two analyses that actually constitute a flight argument

DO-332's dynamic-memory vulnerability list **[S]**, three independent consistent secondaries;
exact wording **[?]** (RTCA paid document): ambiguous references, fragmentation starvation,
deallocation starvation, heap exhaustion, premature deallocation, lost update / stale
reference, unbounded allocation-or-deallocation time.

<decision id="D10" status="finding">
Mapping wok's mechanisms onto that list **[I]**:

- Bump-allocated region with O(1) reset kills **fragmentation starvation**, **deallocation
  starvation**, and **unbounded allocation time** outright.
- Perceus RC kills **premature deallocation** and **lost update / stale reference** by
  construction.
- **Two remain, and they are the entire content of a wok flight-profile safety argument:**
  1. **heap exhaustion** — needs a static high-water-mark bound (this is exactly what
     `WOK_PHYS_BOUND` gestures at; see §2.3)
  2. **unbounded deallocation time** — this is the RC cascade problem, unsolved

This is a much smaller and more concrete target than "make the runtime flight-worthy".
</decision>

<decision id="D11" status="finding">
**The strongest argument for regions is a paperwork argument, not a prohibition.**
ECSS-E-ST-40C Rev.1 §5.3.8 requires budgets reported as **static code size / static data size
/ stack size, per thread**, plus per-component WCET feeding a schedulability analysis **[V]**.
There is **no heap line item in the required schema**. An arena of compile-time-known size
reports as static data; a counted heap has no box to be written in **[I]**.
</decision>

### 5.3 Tool qualification — the pattern is real and now flight-proven

DO-330 TQL determination **[V]**: a tool whose output is part of the airborne software and
*could insert an error* is Criterion 1 → **TQL-1 at DAL A** (most expensive). A tool that only
*fails to detect* and buys no process credit is Criterion 3 → **TQL-5** (cheapest).

Precedent **[V]**: **CompCert was qualified for flight in 2026** (AbsInt, for the ATR 42/72
MFC_NG), the first time DO-178C/DO-333/DO-330 certification credit was claimed from compiler
usage. **[?]** the release does not disclose DAL or TQL achieved — do not cite a number.

Precedent **[V]**: **Valex**, AbsInt's translation validator for CompCert's assembling/linking
phase (which the Coq proofs do *not* cover), checks the linked binary against CompCert's
serialized abstract assembly. Kästner/Leroy et al. ERTS 2016 frame the layering as validation
suite → formal proofs → translation validator, each adding confidence.

<decision id="D12" status="finding">
The "small trusted checker validates a large untrusted producer" pattern is real,
industrially deployed, and now certification-credited — which supports <ref>D2</ref>'s
certificate design. **But the honest framing in every source is "provides additional
confidence" / "supports the objective" — credit *reduction*, not qualification *exemption*.**

<open_question id="Q4">
No DO-330 clause was found that explicitly sanctions "untrusted producer + qualified
checker". The enabling structure (criteria table) and a live precedent (Valex) exist, but the
demotion mechanics are **[I]**, flagged by the researcher as the riskiest inference in the
briefing. Treat as an open negotiation with a certification authority, not a settled reading.
</open_question>
</decision>

### 5.4 The obstacle we had not considered: recursion

<decision id="D13" status="finding">
**JPL-D-60411 Rule 4 [V]:** *"There shall be no direct or indirect use of recursive function
calls."* Rule 3 **[V]**: every loop must have a statically determinable iteration bound.
Joint rationale, quoted: *"The absence of recursion also simplifies the task of deriving
reliable bounds on stack use. The two rules combined secure a strictly acyclic function call
graph."*

The researcher's assessment **[I]**: *"a functional language with non-tail recursion is prima
facie non-compliant, and this is probably the single hardest P10 rule for wok to meet."*

Every corpus program we measured is non-tail-recursive — `build`, `sumTree`, `lengthList`,
`mapInc`. **This is plausibly a larger obstacle than the allocation question, and it was not
on our list.** Mitigating context: P10/JPL is one organization's *C* coding standard, not a
certification requirement — neither ECSS nor DO-178C mandates it (<ref>D9</ref>).
</decision>

### 5.5 OxCaml — corrected, and it supplies the design lesson we needed

**[V]** OxCaml is not and has never been positioned as a safety-critical or spaceflight
runtime; its stated goal is performance engineering / low-latency. It *controls* GC pressure,
it does not eliminate the GC. This confirms the §1 correction.

But it has **`[@zero_alloc]`** **[V]**, which is the closest existing thing to our predicate:

- On success guarantees *"no allocations on any execution of the function, including in the
  callees"*; conservative static analysis, no runtime cost, no codegen change.
- **Compositional without inlining** — callers may rely on a callee's `zero_alloc`, so the
  property crosses module boundaries.
- Limits: all indirect calls are treated as allocating; default mode ignores exceptional
  paths (`strict` covers them); it ignores poll instructions so it cannot rule out context
  switches; `[@zero_alloc assume]` is an unchecked escape hatch.

<decision id="D14" status="finding">
**This diagnoses why both our predicates failed: they were whole-program.** D2 ("no `Heap`
anywhere") and the post-init predicate (§3b) are all-or-nothing over the entire program, so a
single allocating line anywhere fails them. `[@zero_alloc]` works in production precisely
because it is **per-function and compositional** — you annotate the hot path, not the world.

The correction is to make the wok predicate a **per-function annotation with compositional
checking**, not a global property. Our measurements do not refute the approach; they refute
the granularity we chose.

Note the differentiator to preserve: OxCaml's is a compiler-internal conservative analysis
*with sanctioned escape hatches* (`assume`); wok's proposition is an **externally checkable
certificate**. The escape hatch is what disqualifies `[@zero_alloc]` as a certification
artifact **[I]**.
</decision>

### 5.6 Region inference: our zero result is the documented failure mode

Hallenberg, Elsman & Tofte, *Combining Region Inference and Garbage Collection*, PLDI'02,
read in full **[V]**:

- Profiling the MLKit compiling its own benchmark: *"The global region r1 is by far the
  largest. The ML Kit is not optimized for regions and without the garbage collector, region
  r1 would grow without ever decreasing."*
- The structural cause, stated by the authors: *"a programmer cannot be assumed to have
  arranged that the result of a function is stored in a region different from intermediate
  results computed by the function."*
- The counterweight: *"often very little rewriting is required, even for large programs. (In
  the case of AnnoDomini, a reasonably good execution was obtained after modifying 10 lines
  out of 60,000.)"*

<decision id="D15" status="finding">
**<ref>D4</ref>/<ref>D5</ref> are confirmed by the literature — our zero-placement result is
not an implementation bug, it is the documented failure mode of pure Tofte-Talpin region
inference on idiomatic functional code**, and the reason the MLKit team bolted a GC onto it.

The recorded escapes are (a) add a collector behind the regions — unavailable if the point is
a GC-free profile — or (b) accept **programmer-visible region annotation**, which is
<ref>D8</ref>. The AnnoDomini datum (10 lines / 60 kLOC) is evidence the annotation burden may
be very small.

**[?]** No region-based memory management was found deployed in any certified (DO-178C/ECSS)
system. CompCert is the certified-*compiler* precedent; there is no certified-*region*
precedent. Treat regions in certified settings as unprecedented.
</decision>

### 5.7 Cascade bounding may be novel

Known mitigations for the unbounded-decrement cascade **[S]**: work-deferral (push to a
to-free queue, process a bounded quantum per step — converts unbounded worst-case free time
into bounded per-step work, at the cost of a memory-footprint tax that must then itself be
bounded); Deutsch-Bobrow deferred RC (reintroduces a scan, i.e. reintroduces a pause — the
wrong trade here); Anderson/Blelloch/Wei PLDI 2021 concurrent deferred RC with constant-time
overhead **[S]**, concurrent setting, may not transfer.

Closest published prior art: **Ritzau, *Memory Efficient Hard Real-Time Garbage Collection*,
Linköping 2003** — located, **not read**. Recommended reading before spec'ing the bound.

<open_question id="Q5">
The researcher found **no published work** on cascade-bound analysis for Perceus-style
*compile-time-inserted* RC specifically, and flagged it as possibly novel **[?]**. The
argument sketch: because Perceus emits dup/drop at known program points over known drop-tree
shapes, bounding the worst-case cascade becomes a compile-time analysis over type/shape
structure rather than a runtime scheduling problem — and a profile that bounds datatype depth
would bound cascade depth by the same argument.

This is <ref>D10</ref>'s second remaining vulnerability. It is the one place where the flight
profile requires research rather than engineering.
</open_question>
