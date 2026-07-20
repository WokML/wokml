---
spec: tco-tail-call-contraction
status: in_review
---

# TCO — the tail-call contraction

**Shipped 2026-07-20.** Split out of `2026-07-20-trmc-design.md` on 2026-07-21, where it was
discovered as an unplanned prerequisite. This document is the record of what landed, what it
measured, and the two follow-ups it left open.

Related: <ref file="2026-07-21-ir-tail-representation.md">the IR-level representation
question</ref> (the debt this slice created), <ref file="2026-07-21-parameterized-resume-frame-leak.md">D0c</ref>
(a separate depth leak found while validating this), <ref file="2026-07-20-trmc-design.md">TRMC</ref>
(the slice this unblocked).

---

## 1. The finding that prompted it

While building the instrument to measure TRMC's claimed benefit, the baseline measurement
showed something unplanned:

| program | N=10 | N=40 | N=100 |
| ------- | ---- | ---- | ----- |
| `mapInc` (modulo-cons — TRMC's target) | 12 | 42 | — |
| accumulate+reverse (tail-recursive) | 12 | 42 | — |
| `loop n = loop (n-1)` (**pure tail call, no data**) | 11 | 41 | 101 |

<decision id="D1" status="finding">
**wok performed no tail-call optimisation at all.** Every shape was O(N), including a call
with nothing after it. This was not a TRMC problem; TRMC would have produced a loop that still
grew the continuation linearly.
</decision>

**Root cause — a missing contraction, not an architectural limit.** ANF names every
intermediate, so a source-level tail call arrives as a call wearing a `Let` frame:

```
loop n : U64 =
  case n of
    0 -> 0
    _ -> let t.1 : U64 = -(n, 1)
         let t.2 : U64 = loop(t.1)
         t.2                          <-- the call's continuation is the IDENTITY
```

`Let b (RApp f as) (Ret (AVar b))`. The machine pushed `KLetRC`, whose return arm only rebinds
and continues (`src/Wok/Interp/RC/Machine.hs`); its window registration is flag-gated and a
no-op by default, so **the frame carried no RC obligation** for this shape.

---

## 2. Why it is RC-safe

The hazard for any reference-counted language is owing a `drop` *after* the call, which a tail
transfer would skip. Measured — Perceus already hoists drops above the call, because "drop at
last use" naturally places them there:

```
Cons v t.1 ->
  let _dup    = __rc_dup(t.1)
  let _drop.2 = __rc_drop(xs)      <-- before
  let t.2     = +(a, v)
  let t.3     = sumAcc(t.2, t.1)   <-- the call
  t.3                               <-- immediately returned
```

<decision id="D2">
Safety does not rest on that observation, which is only two examples. It rests on the
**precondition**: the body must be exactly `Ret (AVar b)`, so there is *no post-call code of
any kind* — nothing to drop, nothing to dup, nothing at all. Any shape with a value live
across the call keeps code after the `Let` and therefore is not contracted.

**Conservative by construction, not by analysis.** The contraction fires only when there is
provably nothing left to do.
</decision>

---

## 3. As implemented

`callKont` / `isTailReturn` in `src/Wok/Interp/RC/Machine.hs`; the `RApp` arm of `evalRhsRC`
asks `callKont` for its continuation instead of always building a frame:

```haskell
callKont env b body sc k
  | isTailReturn b body, not (windowRouted env b) = k
  | otherwise                                     = KLetRC b body sc k
```

Three deliberate restrictions:

- **`RApp` only.** `ROp` keeps its frame — the op-site continuation must include it so the
  captured `above` prefix is correct, and effect capture is not worth perturbing for a depth
  win. (This is why <ref file="2026-07-21-parameterized-resume-frame-leak.md">D0c</ref> is a
  separate problem, not a gap in this one.)
- **Precondition exactly `Ret (AVar b)`** — see <ref>D2</ref>.
- **Stands down under `windowRouted`.** Under the death-test flag `KLetRC`'s return arm is not
  inert (it registers a `Window`-routed view); eliding it would silently weaken the check the
  flag exists to run.

### 3.1 The instrument

`stKontPeak` (`src/Wok/Interp/RC/Value.hs`), sampled per machine step by `runRC`
(`sampleKontPeak`), surfaced by `wok <file> --dump-kont-depth`. Deliberately **not** added to
`renderRcStats`, whose output is byte-compared by the Suite B goldens.

Gated by `rceKontStat :: Bool` on `RCEnv`, defaulting to `False`.
`runModuleRCWith` / `runModuleRCUncheckedWith` keep their signatures as wrappers over
`...KontStat False`, so no existing caller or test changed; only `--dump-kont-depth` passes
`True`.

<decision id="D3" status="mistake worth recording">
The sampler was first wired unconditionally. `kontDepth` walks the continuation, so sampling
every step is O(depth) per step — and the suite contains a **100_000-cell deep-list test**,
making that ~10^10 operations. The run went from 34s to *not finishing*.

Because the harness buffers output it looked like a slow compile rather than a runaway, and
two aborted runs were spent before the cause was read off a killed process's log.

**Cost a diagnostic against the suite's worst case, not against the hand-written N=40 examples
used to develop it.**
</decision>

---

## 4. Measured result

| program | before | after |
| ------- | ------ | ----- |
| `loop n = loop (n-1)`, N=10/40/100 | 11 / 41 / 101 | **1 / 1 / 1** |
| accumulate+reverse, N=10/40/80 | 12 / 42 / 82 | **2 / 2 / 2** |
| `mapInc` (modulo-cons), N=10/40 | 12 / 42 | 12 / 42 *(unchanged — correct, TRMC's job)* |

Results unchanged at every size (65 / 860 / 3320). **Full suite green: 2193/2193, 24.22s.**

### 4.1 Adversarial: named handler in a tail-recursive loop

The shape where this could plausibly break something: `kontDepth` is what tags a named
handler's activation, so after TCO every iteration installs at the *same* depth and a stale
tag could in principle be confused with a live one. Handlers do reach the RC machine (verified:
`test/examples/26-with-handler.wok` and `examples/named-instances.wok` both produce
`--dump-rc-stats`, so the "handler-free" wording in `Wok.IR.Reachable`'s comment is stale).

Installing and completing a `state` instance once per iteration:

| n | reference result | kontPeak | allocs | frees |
| - | ---------------- | -------- | ------ | ----- |
| 5 | 40 | 6 | 30 | 30 |
| 20 | 460 | 6 | 120 | 120 |
| 60 | 3780 | 6 | 360 | 360 |

Constant depth, balanced accounting, results hand-checked. **No tag collision.**

The dual shape — a tail call *inside* a live handler scope — was also measured, and separated
two things that looked like one:

| shape (handler installed once, alive throughout) | n=4 | n=8 | n=16 |
| ------------------------------------------------ | --- | --- | ---- |
| tail call in live handler scope, **op in loop body** | 8 | 12 | 20 |
| tail call in live handler scope, **no op in loop body** | 4 | 4 | **4** |

TCO is correct in both. The growth in the first row is entirely the effect *operations* — that
is <ref file="2026-07-21-parameterized-resume-frame-leak.md">D0c</ref>, not this. And it cannot
be a TCO regression in any case: `callKont` only ever *removes* a frame, so post-change depth
is bounded by pre-change depth pointwise.

---

## 5. What this does and does not deliver to the two targets

Both project targets — the flight profile and soft real-time / trading — need bounded stack
behaviour, and this is a prerequisite for both. But be precise about what shipped.

| claim | true? |
| ----- | ----- |
| tail recursion is constant-depth on the RC machine | **yes**, measured |
| "wok has TCO" | **no** — reference interpreter untouched (<ref>C1</ref>) |
| effect-performing loops are bounded | **no** — <ref file="2026-07-21-parameterized-resume-frame-leak.md">D0c</ref> |
| non-tail (modulo-cons) recursion is bounded | **no** — that is TRMC |
| a codegen backend inherits this | **no** — <ref>C2</ref> |

<decision id="D4">
The honest summary: this slice **unblocked TRMC and fixed the reference implementation**. It
delivers nothing to either target directly, because neither target runs on the RC interpreter.
Its value is that TRMC's benefit is now real rather than notional — before it, a TRMC'd loop
would still have grown the continuation.
</decision>

---

## 6. Challenges

<challenge id="C1" summary="the two interpreters now disagree about continuation depth">
The RC machine has the contraction; `src/Wok/Interp/Machine.hs` was not touched (`git diff
--stat` empty) and its `RApp` arm still builds `KLet b body sc k` unconditionally. The two
interpreters are each other's differential oracle, and a property that holds on one but not
the other is a place where the oracle is blind.
</challenge>

<response to="C1" status="open">
Not observable today: the parity harnesses compare **results and heap accounting**, not
continuation depth, and depth is in no golden. So nothing is currently wrong.

It is a latent divergence, and it bites the moment anything asserts a depth property across
both machines — which TRMC's acceptance criteria propose to do. Two ways out:

1. mirror the contraction into `Wok.Interp.Machine` (small, keeps the oracle honest), or
2. state explicitly that depth is an RC-machine-only property, never asserted on the reference
   machine.

Option 1 preferred and cheap. Open because it was not measured, and the reference machine has
no `stKontPeak` instrument yet.
</response>

<challenge id="C2" summary="a machine-level fix does not reach either real target">
`callKont` is a decision the *interpreter* makes by inspecting the let-body at run time.
Nothing in the IR marks a call as tail. Both targets are **codegen** targets; a backend would
have to rediscover this independently.
</challenge>

<response to="C2" status="open">
Correct, and it is this slice's main structural debt. Promoted to its own document —
<ref file="2026-07-21-ir-tail-representation.md">the IR tail-representation question</ref> —
because it is a contract decision shared with TRMC, and larger than either slice.

Interim position: the contraction stays in the machine, and this response is the record that
it is not the end state.
</response>

<challenge id="C3" summary="the RC-safety argument was validated on two examples">
§2 shows Perceus hoisting drops above the call in two measured programs. Two examples are not
a proof that no shape reaches `callKont` owing a post-call obligation.
</challenge>

<response to="C3" status="resolved">
The safety argument does not depend on the drop-hoisting observation — that was corroboration,
not the mechanism. It depends on the precondition being `Ret (AVar b)` **exactly**, which
admits no post-call code at all (<ref>D2</ref>). A shape owing a drop after the call has that
drop *in the let-body*, making the body not `Ret (AVar b)`, so the contraction cannot fire.

Backed by the full suite (2193 tests, including the heap-empty oracle and abstract/C parity)
passing unchanged, plus the adversarial handler corpus in §4.1 with balanced allocs/frees at
every size.
</response>

---

## 7. Acceptance criteria — all met 2026-07-20

1. ✅ pure tail call O(1) in N, measured at three sizes (1 / 1 / 1 for N=10/40/100)
2. ✅ results unchanged at every size
3. ✅ adversarial named-handler-in-tail-loop: constant depth, balanced accounting, results
   hand-checked
4. ✅ full suite green, 2193/2193, 24.22s — no runtime regression
5. ✅ `renderRcStats` untouched, so Suite B goldens unaffected by construction

**Status `in_review`, not `buildable`:** the implementation is done and verified, but
<ref>C1</ref> and <ref>C2</ref> are open follow-ups.
