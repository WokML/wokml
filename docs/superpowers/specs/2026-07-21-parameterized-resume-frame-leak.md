---
spec: parameterized-resume-frame-leak
status: draft
---

# The parameterized-resume frame leak

A loop performing `set`-shaped effect operations grows the continuation by **one frame per
operation**, without bound. Found 2026-07-20 while validating
<ref file="2026-07-21-tco-tail-call-contraction.md">TCO</ref>; split out 2026-07-21.

**Localised by measurement. Not root-caused.** This document exists to record the localisation
precisely so the root-cause work starts from evidence rather than from the first hypothesis.

---

## 1. What was measured

Same loop shape throughout: handler installed once in `main` and alive for the whole run, the
loop itself tail-recursive (so TCO applies and the *call* contributes nothing). Only the loop
body varies.

| loop body | handler arm in `prelude/Control.wok` | n=4 | n=8 | n=16 |
| --------- | ------------------------------------ | --- | --- | ---- |
| *(no op)* | — | 4 | 4 | **4** |
| `c.get` | `get -> s` — value-position arm, auto-resume | 4 | 4 | **4** |
| `c.set n` | `set x k -> k x ()` — **parameterized two-arg resume** | 8 | 12 | 20 |
| `c.set (c.get + n)` | both | 8 | 12 | 20 |

<decision id="D1" status="finding">
**Effect operations do not leak frames. The parameterized two-argument resume leaks exactly
one frame per call.**

The first framing of this defect — "every effect operation in a loop leaves a frame behind" —
is **wrong**, and measurement is what corrected it. `get` is flat at 4 regardless of n; only
`set` grows, and linearly in call count.
</decision>

### 1.1 Minimal repro

```
module Main
import Base
import Control

walk : State U64 -> U64 -> U64
walk c n = case n of
  0 -> 0
  _ -> let z = c.set n in walk c (n - 1)

main : (U64, U64)
main = with s = state 0 in walk s 16
```

`wok <file> --dump-kont-depth` reports 8 / 12 / 20 for n = 4 / 8 / 16. Substituting `c.get`
for `c.set n` gives a flat 4.

### 1.2 Where the defect is

`enterRC`'s `NCont` arm — specifically the `Just pb` (parameterized handler) branch in
`src/Wok/Interp/RC/Machine.hs`, versus the `Nothing` branch immediately above it, which does
**not** exhibit the growth.

The two branches look structurally identical with respect to the continuation — both end in
`spliceKont prefix (KHandleRC h hTag hsc' k)`. So the difference is not in the splice itself
but in **what `k` holds at the resume point**, i.e. in the residual frames of the arm body
`k x ()` versus the value-position arm `get -> s`.

<assumption id="A1" status="unverified">
Working hypothesis: the value-position arm resumes with no residual frames of its own, while
the explicit two-argument application `k x ()` leaves at least one frame live at the moment of
the splice, which then gets buried under the re-installed prefix and is not reached until the
whole chain unwinds.

**This is a hypothesis, not a finding.** It has not been confirmed by reading the elaborated
arm bodies or by instrumenting the splice. Confirming or refuting it is step 1 of the
root-cause work.
</assumption>

---

## 2. Why this matters, and to which target

<decision id="D2">
**This is more urgent for trading than for flight**, which inverts the usual ordering of the
two targets.

A flight system runs bounded mission phases; O(N) continuation depth over a bounded N is a
bound, even if a poor one. A trading system runs an event loop for **days**. The canonical
shape

```
loop state = let ev = receive in loop (step ev state)
```

with `receive` served by a parameterized handler grows the continuation **without bound over
the process lifetime**. That is not a latency problem — it is an eventual OOM, and it makes
`State`-style effects unusable in a long-running loop.
</decision>

For the flight profile it is also disqualifying, but for the ordinary reason: P10's
stack-bound rationale is not met while any loop shape has unbounded depth.
<ref file="2026-07-21-tco-tail-call-contraction.md">TCO</ref> and
<ref file="2026-07-20-trmc-design.md">TRMC</ref> together do **not** close this — they address
calls and constructor-argument recursion respectively, not effect operations.

---

## 3. The two candidate shapes of a fix

Deliberately not chosen here — <ref>C1</ref> is exactly the question of which applies.

**A. A narrow defect in the parameterized branch.** If the `Just pb` branch is doing something
the `Nothing` branch is not — an extra binding frame, a differently-shaped splice — the fix is
local and small.

**B. The general tail-resumptive optimisation.** For a handler whose arm resumes in tail
position, the arm's frames are dead the moment the resume happens and the whole delimited
round-trip can be compiled to a direct call. This is well-understood prior art (Koka's
tail-resumptive handlers) and would subsume A, but it is a much larger change to the effect
machinery.

<decision id="D3">
**Do not start implementing before root-causing.** The `get`/`set` asymmetry is the single
most informative fact available and it has not been explained. A fix chosen now would be a
guess dressed as a design, and this is the part of the system with the worst track record for
that — the project's own history records UAF and double-free bugs in the effect machinery that
the runtime oracles did not catch and reviews did.
</decision>

---

## 4. Challenges

<challenge id="C1" summary="is this a narrow branch defect or the general tail-resumptive gap?">
§3's A and B differ by an order of magnitude in cost and risk. The measurement localises the
defect to one branch but does not say whether that branch is *wrong* or merely *not
optimised*.
</challenge>

<response to="C1" status="open">
**The root-cause task, and the gate on everything else here.** Concretely:

1. Dump the elaborated `set` and `get` arm bodies and compare their residual frames at the
   resume point — this is what <ref>A1</ref> asserts without evidence.
2. Instrument or hand-trace `spliceKont` for one iteration of the repro, recording the
   continuation before dispatch, at the resume, and after the splice.
3. Only then decide A vs B.

Steps 1-2 are read-and-measure; they change no product code and can be done independently of
any other slice.
</response>

<challenge id="C2" summary="does the reference interpreter leak too?">
All measurements here are on the RC machine, whose `--dump-kont-depth` instrument exists.
`Wok.Interp.Machine` has no such instrument, so it is unknown whether it shares the defect.
If it does not, the two machines disagree; if it does, the defect is in the shared design
rather than the RC implementation — which is strong evidence for shape B.
</challenge>

<response to="C2" status="open">
Unmeasured. This is a genuinely informative experiment and it is cheap: the answer discriminates
between "RC-machine implementation bug" and "design-level gap", which is much of <ref>C1</ref>.

Blocked only on the reference machine having a depth instrument — the same gap
<ref file="2026-07-21-tco-tail-call-contraction.md">TCO's C1</ref> records.
</response>

<challenge id="C3" summary="is the leak really unbounded, or bounded by handler scope?">
Every measurement grows n within a single `with` scope. A trading event loop might re-enter
the handler scope periodically, which would bound the growth per scope.
</challenge>

<response to="C3" status="resolved">
It is unbounded *within a handler scope*, and a handler scope is exactly what a long-running
event loop is: the point of installing `state` once around the loop is that the state persists
across iterations. Re-entering the scope to reclaim frames would mean discarding the state —
i.e. the workaround defeats the reason for using the effect.

Bounded per scope is therefore not a mitigation for the shape in <ref>D2</ref>. It does mean a
program that opens a fresh handler per unit of work is unaffected, which is worth knowing but
is not the shape at issue.
</response>

---

## 5. Acceptance criteria

Written for the eventual fix; none are met.

1. The repro in §1.1 reports **constant** `kontPeak` across n = 4 / 16 / 64.
2. `get`-shaped and `set`-shaped ops both remain constant-depth.
3. Effect semantics unchanged: full suite green, including the abort/resume corpus
   (`test/rc-c-backend/fbip-effect-{abort,resume}.wok`) and the named-instance parity corpus.
4. Balanced accounting (`allocs == frees`, `stLive == baseline`) on both heap backends at every
   size — the growth being fixed is in the continuation, and it must not be traded for a heap
   leak.
5. Whichever of §3 A/B is chosen, the *other* is explicitly recorded as considered and why it
   was not.
