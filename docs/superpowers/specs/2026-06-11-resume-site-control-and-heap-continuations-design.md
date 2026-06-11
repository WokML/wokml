# Resume-site effect control + heap continuations (layer-3 runtime foundations)

Status: **Design direction** (architecture), brainstormed 2026-06-11. Spans the
language (type discipline) and the future runtime; this is NOT a single
implementation slice. Phasing is in §8. Supersedes nothing; extends the
residual-row work (`2026-06-10-slice-4b-dprime-residual-row-*`) and the kinded-Ty
foundation (`2026-06-10-kinded-type-representation-design.md`).

Prior commitments this builds on:
- Effect handlers are the one control mechanism; handlers are second-class
  (keeps inference HM + row-unification, decidable).
- One-shot is the law (affine no-dup analysis on continuation binders;
  multi-shot = compile error).
- Effect compilation is stackless **selective** CPS (contify-vs-reify by
  escape + multiplicity).
- The planned runtime is **Perceus-style reference counting** (Koka) with reuse
  (FBIP) and an older heap.

---

## 1. Problem

Slice 4b" gave `Suspension a b r (row e)` / `Step a b r (row e)` a residual
effect-row parameter, intending "resuming a coroutine forces the resume site to
handle the parked tail's effects." Investigation showed the row is **decorative
under the current second-class discipline**:

- A generic resume driver `replay : Suspension U64 U64 U64 (row e) -> U64`
  (body `run g 0`) type-checks as **effect-polymorphic / pure**
  (`forall a. Suspension U64 U64 U64 a -> U64`). The residual is *absorbed*: a
  bare row variable performs no concrete labels, so it never propagates. Pinned
  by `test/typecheck-examples/coro-resume-driver.wok`.
- Stripping `with eff e` from `run`/`step` leaves the whole suite green and the
  negative test still rejecting — proof the resume obligation does no work today.

Why it is still sound today: two guarantees, supplied for free by the discipline:
1. `start`'s **eager demand** — `start`'s result `with eff e` forces the full
   residual to be handled at the lifecycle root.
2. **Second-class carriers** — the suspension cannot leave the dynamic scope
   where it was created, so every resume happens inside that scope, where the
   handler is present.

This is the "resume laundering" hole: a resume driver hides the resumed
computation's effects from its own type. Harmless now, because the wall keeps a
handler present. **Layer-3 (Task/scheduler/Stream) needs carriers to travel** (a
scheduler stores parked tasks in a run-queue and resumes them later, elsewhere),
which removes the wall — at which point laundering becomes a real soundness hole.
The residual row must become the thing that carries the obligation to the resume
site. That is "explicit resume control."

---

## 2. Decision: resume-site semantics

A resumed tail's effects resolve against the handler **at the resume site**
(dynamic), not the start site.

Why this is essentially forced — start-site coherence across travel is
self-contradictory:

```
   to make a tail's `State.get` resolve to the START handler S0 after start
   returned, the continuation k must CARRY S0:

      g -> k -> [ tail code ] + [ S0 handler frame ]
                                 \___ a handler inside a first-class value
                                      = a first-class handler
                                      = exactly what the second-class rule bans
                                        (the handler-escape unsoundness)

   start-site + travel  =>  first-class handlers  =>  banned.
   If carriers travel at all, resume-site is the only sound option that keeps
   handlers second-class (and inference decidable).
```

Supporting arguments:
- **Resume-site is what an effect IS.** An operation never carries its handler;
  it asks whoever is on the dynamic stack now. That late binding is why handlers
  compose. Start-site (freezing interpreters and dragging them along) is the
  exotic, heavier construct.
- **The residual `e` is, by definition, the delegated effects.** Effects handled
  inside the producer are discharged locally and never enter `e`; effects left in
  `e` are the ones explicitly handed to the driver. Resolving them at resume
  honors that delegation. Coherence remains available two ways: handle an effect
  *inside* the producer (it leaves `e`), or handle it *around the whole drive*
  (one frame spanning all resumes).
- **Every production async system agrees** — `await` runs the continuation on the
  executor's context, not the creator's. Thread-affinity (start-site) is the
  known anti-pattern.
- **Values still travel.** Anything the tail needs from the start context is read
  pre-suspend into a local (`let cfg = Config.get in ...`); it rides inside `k`.
  Only *handlers* don't travel — and you want a handler's result to travel, not
  the handler.

Accepted non-goal: a transaction/region kept open *across* a yield to an
arbitrary scheduler gap is hard under resume-site — correctly, since that is the
universal "don't hold a lock across await" footgun. The legitimate form
(scheduler-level transaction spanning the task's life) is itself resume-site.

---

## 3. The load-bearing row (make resume behave like a function call)

Guiding principle:

> A Suspension is "a function you can call to continue." Make resuming it behave
> exactly like calling a function.

A function value already has everything we want: it is first-class, and its
effect row is already load-bearing (you cannot call `f : () -> () with Log`
without `Log` in scope; calling it resolves `Log` dynamically at the call site =
resume-site). So the fix is parity, not a new concept.

Mechanism: performing a residual row `e` — **even a bare row variable** — must
obligate the enclosing function's effect row to be `>= e` (stop silently
absorbing bare row variables; treat the residual exactly like any other effect
row, which the existing sound row-unification already handles). Consequence:

```
   replay : Suspension U64 U64 U64 (row e) -> U64 with eff e
                                              ^^^^^^^^^^^  becomes mandatory
```

and a scheduler's `runNext` is forced to surface the union of its parked tasks'
effects — it can no longer claim purity while running effectful tasks.

Timing: the row is **redundant under second-class** (today). Making it
load-bearing now would add obligations with no benefit and flip the
`coro-resume-driver` characterization with nothing to show for it. It lands
**together with first-class carriers** (§5). `coro-resume-driver.wok` is the
marker whose golden must consciously flip when that happens.

---

## 4. `start` stays eager; the thunk is the lazy form

An unfinished coroutine has two representations, and the first is already ideal:

```
   UNSTARTED (a thunk)            MID-FLIGHT (a Suspension)
   c : () -> r with Coro a b      g : Suspension a b r (row e)
       + eff e
   - a FUNCTION value             - NOT a function; a carrier
   - first-class already          - second-class today
   - row already load-bearing     - row currently NOT load-bearing  <- the gap
     (calling it demands e)
   - store / drop / pass freely;  - storing it = the open
     performs nothing               first-class question (§5)
```

"Lazy start" is redundant: holding the thunk already gives pure spawn, free
cancel, and deferred effects. Call `start` only **under the run-site's handlers**
(the scheduler), and eager `start`'s over-demand is harmless — the same scope
covers every later `step`. Over-demand only hurts at the *spawn* site, which you
avoid by spawning the thunk, not the Step.

Rejected alternatives:
- **Lazy/pure `start` (separate `begin` op, three states):** redundant with the
  thunk; introduces an API asymmetry (first run takes `()`, resumes take `b`).
- **Split residual into before/after-suspend rows ("C"):** would let each resume
  demand only its chunk's effects, but needs a control-flow-sensitive effect
  analysis (not free in HM) for a rare need (per-step handler granularity without
  a covering scope). YAGNI; defer indefinitely.

---

## 5. The first-class carrier trio (the layer-3 gate)

A scheduler keeps a run-queue, so a Suspension must live in a data structure and
be resumed across ticks. That removes the second-class wall, so three guarantees
the wall gave for free must be re-established:

```
   put g in a queue, resume it on a later tick
        |
        |-- (1) STORAGE      can g live in a data structure at all?
        |        today: no (CarrierEscape). need: first-class carrier.
        |
        |-- (2) AT-MOST-ONCE once aliased, what stops `run g; run g`?
        |        "one-shot is the law" must follow g THROUGH the queue
        |        (affine-through-aliasing). miss it -> multi-shot -> unsound.
        |        This is the one guarantee the RC runtime does NOT provide.
        |
        \-- (3) NO-DROP / CLEANUP   a queued g never resumed -> tail never runs.
                 if the tail owns a resource it leaks. need: drop discipline.
```

The load-bearing row (§3) is one piece of (1). These together unlock
`Task`/scheduler.

---

## 6. Runtime: stackless selective CPS + Perceus (Koka), not GHC/OCaml heap stacks

Coroutines are effects, the effect machinery is stackless selective CPS, so
coroutines are stackless. A reified continuation is an RC'd **heap object**, which
maps the trio onto runtime primitives:

```
   guarantee                  Perceus / RC primitive
   ------------------------   --------------------------------------------------
   (1) storage in a queue     a continuation IS a heap value -> RC'd, store/move  free
   (2) at-most-once           RC ALLOWS aliasing -> does NOT enforce this
                              -> stays a STATIC affine check                      types
   (3a) no memory leak        RC reclaims at refcount 0                           free
   (3b) resource cleanup      attach cancel/`finally` to RC-drop; dropping an
                              unresumed continuation runs its finalizer           free
   (4) steady-state cost      one-shot consume -> RC 0 -> REUSE the allocation
                              (FBIP) for the next step -> 0 alloc/step in loops    payoff
```

Crucial: RC enforces memory safety (no use-after-free, no leak) but **not
linearity** (it permits aliasing), so guarantee (2) cannot lean on the runtime —
it must remain a static analysis. And the "no-drop" question softens: instead of
mandatory *linear* consumption, stay **affine** and let RC-drop run cleanup
(Koka's `finally`/`initially`) — the GC cancels dropped tasks for you.

Why not a GHC/OCaml-style own stack (the user's question):

```
   system  | per-coroutine stack          | GC         | scans stack? | fit
   ---------------------------------------------------------------------------
   GHC     | heap, chunked, growable      | tracing    | yes (maps)   | breaks Perceus
   OCaml 5 | heap fiber stack, growable   | tracing    | yes          | breaks Perceus
   Koka    | NONE: C-stack fast path +    | Perceus RC | NO           | THIS
           | reified heap continuations   | (+ reuse)  | (dup/drop)   |
```

A GHC-style heap stack is a mutable block of raw pointers; precise RC via
inserted dup/drop cannot track its interior, so it would require *scanning* it
for roots = reintroducing tracing GC = abandoning Perceus. GHC and OCaml 5 can do
heap stacks only because they have tracing collectors. OCaml 5 is *exactly* the
"own heap stack per coroutine" design — admirable, but it depends on the tracing
GC we are deliberately not building. Koka builds no custom stack and is the model
to follow.

What we keep instead: a reified continuation is a per-coroutine **heap stacklet**
for the captured (suspended) slice only — RC'd and reusable. That is the useful
part of a heap stack (suspended state on the heap, storable in a queue, no fixed
size cap) without a global custom stack and without breaking RC.

Forgone (orthogonal, narrow): unbounded *non-tail* recursion can overflow the C
stack (GHC/OCaml never do). Mitigate separately (TCO, large C stack, graceful
overflow) if it ever bites; it is not a reason to adopt a global heap stack.

---

## 7. Making heap continuations easy and performant

Levers, in priority:

- **P1 Reify selectively.** Tail-resumptive, one-shot ops contify to a direct
  call (zero heap). `State`/`Reader`/`Writer`-style effects allocate nothing.
  Heap continuations are the exception (true coroutines / scheduler), not the
  rule.
- **P2 One-shot => reuse (the payoff).** Because multi-shot is banned, every
  reified continuation is uniquely owned at resume; consuming it drops RC to 0 and
  Perceus reuses the allocation (FBIP) for the next continuation. Generator loops
  become zero-allocation in steady state. The one-shot law is the *precondition*
  that makes continuation reuse always valid — it pays for itself.
- **P3 Capture only live state.** Close over exactly the variables live at the
  suspend point (liveness), in a small uniform unboxed layout -> fast bump-alloc
  and reuse-eligible; memory proportional to live state, not a stack.
- **P4 O(1) handler lookup via evidence passing.** Pass the handler as evidence,
  so `perform` finds its delimiter by direct lookup, not a stack walk. Ties into
  named effect instances.
- **P5 Bound the duplication tax (OPEN/CLOSE).** Don't re-reify across every
  handler in a deep stack; bound the split so deep nests don't blow up.
- **P6 RC-drop = automatic finalize/cancel.** Resource safety without manual
  frees (guarantee 3b).
- **Ease = the compiler does it.** Contify/reify, dup/drop, reuse, liveness are
  all inferred; the surface stays plain effect handlers, no `fun`/`ctl`
  annotations (analysis over annotation). The user writes handlers; the machine
  handles the continuation economics.

---

## 8. Phasing

- **DONE:** 4b" residual row (decorative under second-class; merged).
- **Long pole, language, runtime-agnostic:** the **affine-through-aliasing**
  analysis (guarantee 2) — the one thing the RC runtime will not provide. Design
  it first; it gates everything.
- **The first-class-carrier slice** = storage (1) + affine-through-aliasing (2) +
  drop discipline (3) + the load-bearing row (§3), landing **together**. This is
  what flips `coro-resume-driver`'s golden and unlocks `Task`/scheduler.
- **Future runtime:** stackless selective-CPS reification as RC'd reusable
  continuations; Perceus reuse; RC-drop cancellation. The current interpreter
  keeps phantom-`e`; the type/analysis story must stay compatible with this.
- **Consumers after the gate:** `Task`/scheduler, `Stream`/`Sink`, boxed
  `Resource` — each a small typing increment on this foundation
  (kinded-Ty design Section 2 table).

---

## 9. Open questions

1. **Affine-through-aliasing.** How does "one-shot" follow a carrier through
   arbitrary data structures (queue push/pop, aliasing, conditional consume)?
   Escape analysis + linearity. Is it decidable and HM-compatible, or does it
   need a uniqueness/linear-type layer? (This is the next brainstorm.)
2. **Storage discipline.** Does putting a carrier in a collection require a
   linear/uniqueness type, or is an affine escape analysis sufficient?
3. **Named-instance interaction.** A captured instance operation resumed under a
   *different* instance: the row tracks the effect type, not instance identity.
   Sound? Desirable? (Connects to `named-effect-instances-design`.)
4. **Nested coroutines / multi-prompt.** A coroutine resuming a coroutine — does
   the evidence/prompt machinery compose, and what is the reuse story across
   nested prompts?
5. **Cancellation semantics.** RC-drop runs `finally`; what is the surface for a
   user-initiated `cancel`/`discontinue`, and how does it interact with the
   affine->linear upgrade for resources?
