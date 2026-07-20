---
spec: trmc
status: draft
---

> **2026-07-21: split.** This document originally carried three other things that were
> discovered while prototyping it. They now have their own specs:
> <ref file="2026-07-21-tco-tail-call-contraction.md">TCO</ref> (shipped; was the unplanned
> prerequisite), <ref file="2026-07-21-parameterized-resume-frame-leak.md">the
> parameterized-resume frame leak</ref>, and
> <ref file="2026-07-21-ir-tail-representation.md">the IR tail-representation decision</ref>.
> What remains here is TRMC itself.
>
> **Not buildable.** <ref>C1</ref> (the hole hazard) is open and needs a prototype;
> <ref>C8</ref> (the lowering choice) is blocked on the IR decision.

# TRMC — tail recursion modulo constructor

Turn `f x = C ... (f x') ...` — a self-call sitting in a *constructor argument*, therefore not
in tail position — into a loop with constant continuation depth.

Companion to FBIP (`2026-06-23-fbip-reuse-design`). The two are orthogonal axes and are only
jointly sufficient:

| axis | mechanism | status |
| ---- | --------- | ------ |
| heap — linear transform | FBIP reuse | **shipped**, measured |
| stack — linear transform | **TRMC** | this spec, not started |

---

## 1. Problem, with evidence

`mapInc` is the canonical shape:

```
mapInc xs = case xs of
  Nil       -> Nil
  Cons x xx -> Cons (x + 1) (mapInc xx)
```

FBIP already makes this **allocation-free in steady state** — measured 2026-07-20: build a
10-cell spine, then `mapInc` over it five times, `allocs = 10`, not 60
(`docs/superpowers/2026-07-20-flight-profile-context.md` §3d).

But the recursive call is an *argument* to `Cons`, so the machine must remember "wrap the
returned value in `Cons (x+1) _`" before recursing: **one continuation frame per element.**
The project's own explainer (`docs/trmc-and-list-representation.html`) states this exactly.
`grep -riE "trmc|modulo cons|destination.passing" src/` returns nothing — not implemented.

Measured depth, after TCO landed (so the *call* contributes nothing and this is TRMC's residual
alone):

| program | N=10 | N=40 |
| ------- | ---- | ---- |
| `mapInc` (modulo-cons) | 12 | 42 |

<decision id="D1">
FBIP flattens the **heap**; it does nothing to the **stack**. These are independent, and the
zero-allocation steady state measured above is currently paid for with O(n) continuation depth.
TRMC is the missing half, not an optimisation on top of a working whole.
</decision>

### 1.1 Prerequisite — already landed

<ref file="2026-07-21-tco-tail-call-contraction.md">TCO</ref> had to ship first. Before it, wok
performed no tail-call optimisation at all, so a TRMC'd loop would still have grown the
continuation linearly and the transform would have bought nothing measurable.

That slice also produced the instrument this spec needs: `wok <file> --dump-kont-depth`.

---

## 2. Scope

<non_goal id="NG1">
**Multi-recursive-call shapes.** `sumTree t = case t of Node v l r -> v + sumTree l + sumTree r`
has two recursive calls combined by an operator; it is not modulo-constructor and TRMC cannot
transform it. Tree recursion needs an explicit worklist or a bounded-depth argument. Out of
scope, and a language-feel question worth its own thread.
</non_goal>

<non_goal id="NG2">
**Mutual recursion across top-level binds.** First slice handles direct self-recursion only.
The transformation generalises, but recognition and companion-function naming get materially
more complex, and nothing in the corpus needs it yet.
</non_goal>

<non_goal id="NG3">
**Making the loop bound statically determinable.** TRMC converts unbounded *recursion* into
unbounded *iteration*. Depth becomes O(1) and derivable, which is a real improvement, but a
loop over a runtime-length list still has no static iteration bound. Closing that requires
bounding the **data** (fixed-capacity structures), not the control flow. See §6.
</non_goal>

<non_goal id="NG4">
**Effect-performing loops.** Those grow for a different reason —
<ref file="2026-07-21-parameterized-resume-frame-leak.md">the parameterized-resume leak</ref> —
which TRMC does not touch.
</non_goal>

---

## 3. The design fork

### 3.1 Option A — destination passing (proposed)

The standard construction (OCaml `[@tail_mod_cons]`, Koka). `f` gains a companion in
*destination-passing style*: instead of returning its result, `f_dps dst i args` writes the
result into slot `i` of cell `dst`.

```
mapInc xs =
  case xs of
    Nil       -> Nil
    Cons x xx -> let root = Cons (x+1) HOLE in
                 letjoin loop(dst, ys) =
                   case ys of
                     Nil       -> set dst[1] := Nil ; Ret root
                     Cons y yy -> let c = Cons (y+1) HOLE in
                                  set dst[1] := c ;
                                  Jump loop(c, yy)
                 in Jump loop(root, xx)
```

Constant continuation depth, one pass, O(n). Generalises to any constructor with exactly one
recursive field.

**Cost:** introduces a cell that is *partially initialised* between its allocation and the
write that fills its hole. That state is new to wok and is the load-bearing hazard
(<ref>C1</ref>).

### 3.2 Option B — accumulate and reverse (refuted)

Build the result backwards into an accumulator, then reverse. Claimed: constant stack using
only existing machinery, with FBIP making the reverse allocation-free
(`test/rc-c-backend/fbip-reverse.wok`, measured `allocs = 3`).

<decision id="D2" status="REFUTED by measurement 2026-07-20">
**The constant-stack claim was wrong.** Hand-written accumulate+reverse measured depth N+2 —
identical to the untransformed version — because its recursion is *tail* recursion and wok did
not optimise tail calls at the time.

<ref file="2026-07-21-tco-tail-call-contraction.md">TCO has since landed</ref>, so B now does
give constant stack (measured 2 / 2 / 2 for N=10/40/80). Its remaining objections still stand:

1. **It only works for lists.** TRMC applies to any constructor with a recursive field;
   accumulate-reverse has no meaning for `Node v l (f r)`.
2. **It is two passes.** O(2n) traversal where TRMC is O(n).

The one property it retains, and the reason to keep it on record: it never creates a
partially-initialised cell, which is strictly better under a verification regime
(<ref>Q1</ref>). If <ref>C1</ref> resolves badly, B is the fallback for the list-shaped subset.
</decision>

---

## 4. Pipeline placement

Current order (`app/Main.hs`): elaborate → `pruneToReachable` → `Perceus.insertRC` →
`reusePairing`.

<decision id="D3">
**TRMC runs before `Perceus.insertRC`.** Perceus must see the loop form so it inserts dup/drop
against the *actual* control flow; running TRMC after RC insertion would require rewriting
already-placed dup/drop across a control-flow change, which is the error-prone direction.

This puts TRMC before `reusePairing` too, which is what <ref>C2</ref> is about.
</decision>

New order: elaborate → prune → **TRMC** → `insertRC` → `reusePairing`.

---

## 5. Challenges

<challenge id="C1" summary="a partially-initialised cell is observable if an effect aborts mid-loop">
Between `let c = Cons (y+1) HOLE` and `set dst[1] := c`, cell `c` has a slot holding undefined
bits. If an effect operation inside the loop aborts (a handler that does not resume), the
continuation carrying the pending `set` is discarded, and the half-built spine is reachable
from `root` with a hole in it. A subsequent drop cascade would then read the hole as a pointer
and follow it.

This is the same *shape* as the hazard FBIP already had to solve —
`test/rc-c-backend/fbip-effect-abort.wok` and the "E+ lazy reclaim" work exist precisely
because an abort can strand a reuse reservation.
</challenge>

<response to="C1" status="open">
**Needs a prototype before this spec is buildable.** Three candidate resolutions, in decreasing
order of preference:

1. **Fill the hole at allocation with a sentinel** (the interned `Nil`-like inline immediate,
   or a dedicated `HOLE` tag). The cell is then never malformed — a drop cascade reading the
   slot sees a well-formed uncounted immediate and stops. Cost: one extra store per cell,
   likely dead when immediately overwritten. **This looks like the right answer** and it
   exploits the existing inline-immediate encoding (`runtime/README.md`, low 2 bits `11`), but
   it must be prototyped against the abort corpus.
2. **Forbid effects in a TRMC'd loop body** — recognition refuses to fire if the body contains
   `Handle`/`ROp`. Sound and cheap, but it is another whole-body fence of the kind that made
   R1's region inference find nothing (context doc §2.5, §3), so it should be a last resort.
3. Extend the E+ lazy-reclaim mechanism to also track pending TRMC holes. Most general, most
   complex.

The choice materially affects §6: option 1 is the only one that leaves no partially-defined
memory state at any instant.
</response>

<challenge id="C2" summary="does reusePairing still recognise the shape after TRMC rewrites it?">
FBIP is currently the *only* thing making `mapInc` allocation-free, and `reusePairing`
recognises a specific shape: the `Cons` alt drops the matched unique scrutinee cell and
rebuilds a same-arity, same-slot-kind `Cons`.

TRMC moves the construction: the new cell is built *before* the recursive step rather than
after it. If that breaks recognition, **we would trade a measured zero-allocation property for
a stack property** — a bad trade.
</challenge>

<response to="C2" status="resolved">
The shape should survive, and arguably improves. After TRMC the destructuring of `ys` and the
allocation of `c` are in the *same loop iteration and adjacent*, which is exactly the
single-path adjacency `reusePairing` looks for — whereas today they are separated by the entire
recursive call.

The combined result is the Koka in-place map: reuse the very cell just destructured, write
`y+1` into slot 0, and slot 1 becomes the next hole. Zero allocation **and** constant stack.

This is a claim about a pass we can run, so it is verified by construction: the FBIP corpus
(`rcFbipFiles`) must show **unchanged** allocation counts before and after TRMC lands. That is
the acceptance criterion, not a hope.
</response>

<challenge id="C3" summary="RC discipline on the hole-filling write">
`set dst[i] := c` stores an owned reference into a slot. Perceus's balance lint expects every
counted store to pair with a drop of whatever the slot held. Here the slot held a hole (or a
sentinel), so there is nothing to drop — a store with no matching release.
</challenge>

<response to="C3" status="resolved">
It is a **move-in, not a copy**: `c` is produced by the loop iteration and has exactly one
owner, which the store transfers to the parent cell. No `dup` (ownership moves), no `drop` (the
slot held no counted value).

Same discipline as the existing `MoveOut` foreign-argument path, where the dispatch is the sole
dropper and Perceus deliberately emits no `__rc_drop`. The lint must learn one new form; it is
not a new ownership concept.
</response>

<challenge id="C4" summary="interaction with the arena tier">
`arenaClose` scans out an arena cell's counted children before the O(1) bulk reset. A cell with
an unfilled hole has a slot that is not a valid child.
</challenge>

<response to="C4" status="resolved">
Moot in the first slice, and safe after. Region placement currently routes **nothing** to the
arena on real code (measured: zero placements across the entire corpus, context doc §3), so no
TRMC cell can be arena-born today.

Should regions later become annotatable (context doc D8), <ref>C1</ref>'s resolution 1 subsumes
this: a sentinel-filled slot is a well-formed uncounted immediate, which `arenaClose` already
handles correctly — inline immediates are uncounted and its scan skips them.
</response>

<challenge id="C5" summary="the hole slot's kind under the descriptor discipline">
The C runtime records a per-constructor descriptor of slot kinds, first-kind-seen wins, and a
constructor whose kinds disagree falls back to the Haskell heap. If a hole is written as one
kind and later overwritten with another, the same tag could record two descriptors.
</challenge>

<response to="C5" status="resolved">
No new kind is introduced. The recursive field of a TRMC'd constructor is a pointer field, and
`KPointer` **already subsumes pointer-or-immediate** — the low 2 bits discriminate `CAddr`
(`00`), `HAddr` (`01`) and `Inline tag` (`11`) at runtime, and the descriptor records a single
`KPointer` regardless (`runtime/README.md`, slot-encoding table).

A sentinel hole is an `Inline` immediate and the filled value is a pointer; both are
`KPointer`. The descriptor is unchanged, so the fallback rule is not triggered.
</response>

<challenge id="C6" summary="recognition must not fire on a non-linear recursive occurrence">
The transform is only valid if the recursive call's result is consumed *exactly once*, in the
constructor argument. If the result is bound and used twice, destination-passing writes one
cell where two references are expected.
</challenge>

<response to="C6" status="resolved">
Recognition requires the ANF shape `Let t = RApp f args ; Let r = RCon C [.., AVar t, ..] ;
Ret (AVar r)` **with `t` occurring exactly once** — in that constructor argument and nowhere
else. Occurrence counting over ANF is already available; `Wok.IR.Multiplicity` computes exactly
this class of fact.

Conservative by construction: if the occurrence count is anything other than one, the function
is left untransformed and behaves as today.
</response>

<challenge id="C7" summary="the constant-depth claim needs measuring, not asserting">
A regression that reintroduced depth growth would be silent, and depth is the entire point of
this spec.
</challenge>

<response to="C7" status="resolved">
The instrument exists: `--dump-kont-depth`, shipped with
<ref file="2026-07-21-tco-tail-call-contraction.md">TCO</ref>.

Acceptance: for a TRMC'd `mapInc` over a spine of length N, peak continuation depth must be
**O(1) in N** — measured at two sizes and compared, not asserted. Baseline to beat is 12 / 42
for N=10 / 40.

Caveat carried from that slice: the depth instrument exists on the **RC machine only**, so this
criterion is asserted there and not on the reference interpreter.
</response>

<challenge id="C8" summary="the lowering emits Jump — but is that lowering sound?">
§3.1 lowers to `LetJoin`/`Jump`, relying on `Jump` being a true tail transfer (the RC machine
evaluates the join body under the join's *own* captured continuation `jk`, not the current
`k`). That much is verified by reading. But whether a self-recursive top-level function can
become a join point without disturbing parameter ownership under Perceus is **not** verified.
</challenge>

<response to="C8" status="open">
Blocked on, and answered by, <ref file="2026-07-21-ir-tail-representation.md">the IR
tail-representation decision</ref> — specifically its C1, which proposes exactly this
experiment (hand-build the lowered IR for a simple self-recursive function, run it through
Perceus and the RC machine, compare results / accounting / depth).

**TRMC should not start choosing its lowering until that experiment is done.** If the join-point
lowering is sound, TRMC emits it and retires that document's debt as a side effect; if not,
TRMC needs a different lowering and that document becomes a prerequisite rather than a
companion.
</response>

---

## 6. What this buys the two targets

Full dual-target analysis is in `docs/superpowers/2026-07-20-flight-profile-context.md`. TRMC's
specific contribution:

| requirement | who needs it | TRMC's contribution |
| ----------- | ------------ | ------------------- |
| no direct/indirect recursion (P10 R1 / JPL R4) | flight | **satisfied** for modulo-constructor shapes — recursion becomes a loop |
| derivable stack bound | **both** | **satisfied** for those shapes, and measurable |
| statically determinable loop bound (P10 R2 / JPL R3) | flight | **not addressed** — <ref>NG3</ref> |
| bounded resident state in a long-running loop | trading | partial — helps list transforms, not effect loops (<ref>NG4</ref>) |

<decision id="D4">
The gap TRMC leaves for flight is **P10 Rule 2**: it converts an unbounded recursion into an
unbounded *loop*. Closing it means bounding the data, i.e. fixed-capacity preallocated
structures — which is the same requirement the flight profile already has for other reasons, so
the mechanisms converge rather than multiply.
</decision>

<open_question id="Q1">
<ref>C1</ref>'s resolution decides whether TRMC is admissible in a flight profile *at all*.
Resolution 1 (sentinel fill) leaves no partially-defined memory at any instant and is
certifiable in principle. Resolutions 2 and 3 leave a window in which a reachable cell contains
undefined bits, which a memory-safety certificate cannot cover.

The context document's D5 holds that the two targets must not fork the implementation, so the
flight constraint decides it for both: **resolve C1 in favour of the sentinel unless
prototyping forbids it.** The cost — one store per cell, likely dead when immediately
overwritten — is one trading would accept anyway.
</open_question>

---

## 7. Acceptance criteria

None met; not started.

1. FBIP corpus (`rcFbipFiles`) allocation counts **unchanged** before/after TRMC (<ref>C2</ref>).
2. Peak continuation depth O(1) in spine length for a TRMC'd `mapInc`, measured at two sizes,
   against the 12 / 42 baseline (<ref>C7</ref>).
3. The abort corpus (`fbip-effect-abort.wok` plus a new TRMC analogue) clean under ASan on both
   heap backends (<ref>C1</ref>).
4. Full suite green.
5. `--dump-rc-stats` output for existing goldens byte-identical.

**Blocked on:** <ref>C1</ref> (prototype the sentinel) and <ref>C8</ref> (the lowering
experiment, owned by the IR representation spec).
