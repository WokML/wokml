# LetRec `NGroupCode` constant-pool fix (M2a-2 follow-up)

**Date:** 2026-06-25
**Status:** FILED — design captured, NOT yet implemented. Surfaced by the Region Slice R1 memory-blindness audit (`region-slice-r1` memory note).
**Scope:** M2a-2 (shared-env recursive closures), NOT region work. A small, self-contained fix.

## The bug

Every evaluation of a `LetRec` (recursive group) calls `allocStatic (NGroupCode defs)` (`src/Wok/Interp/RC/Machine.hs:163`). `allocStatic` (`Value.hs:1597`) hands out a FRESH negative (immortal) address each call — it does NOT intern. So a `let rec` inside a loop or a recursive function allocates **one immortal cell per evaluation**, accumulating in the abstract `Store`'s `stCells` (and drifting `stNextStatic` downward) without bound:

```
loop n = case n of
  0 -> 0
  _ -> let rec g x = … in g 1 + loop (n - 1)     -- one NGroupCode cell leaked per call
```

It is **uncounted** (`allocStatic` never touches `stStats`), so the RC oracle (`stLive == baseline`) is structurally blind to it. A real interpreter-era space leak. Reachable by any program with an inner recursive group inside a loop/recursion; invisible at test scale (the corpus programs are short). Codegen would dissolve it (code emitted once as static data), but **codegen is far future**, so the interpreter-era leak is worth fixing now.

## Root cause: a constant treated as a per-evaluation allocation

`NGroupCode` holds `defs` — the member `(binder, params, body)` triples. This is **code**: fixed at elaboration, no runtime values. It is a **compile-time constant**. Re-allocating an identical constant per evaluation is a representation error, not a logic bug.

Crucially, the representation **already splits the constant from the variable part**. A member handle is `RVRecMember gAddr i envAddr`:
- `gAddr` → the `NGroupCode` (**the code**) — constant, identical every evaluation and across activations.
- `envAddr` → the `NEnv` (**the captured enclosing locals**) — variable, correctly per-evaluation and counted.

So the M2a-2 code/env split already anticipated this. The fix is only to make `gAddr` a **shared** constant address instead of a fresh per-evaluation one.

## The principled fix: a constant pool (no temporary hack)

Allocate each distinct `LetRec`'s `NGroupCode` **once** and reuse it across all evaluations and all activations. Two equivalent forms:

- **(A) Intern on first evaluation**, keyed by the group's stable identity — its member binder `Unique`s (`groupU`, assigned by the elaborator, identical across evaluations). The `Store` gains a memo `Map GroupKey Addr`; the `LetRec` arm checks it before `allocStatic`, reusing the address on a hit. Lazy; no dead-code walk; minimal change.
- **(B) Pre-allocate at module load** — a constant-pool pass walks every `LetRec`, installs its `NGroupCode` as a static constant once, and records the mapping; evaluation references the pre-allocated address. The explicit "constant pool populated at load" form.

Both are principled — they correct the representation, not paper over the symptom. **Recommend (A)** as the minimal sound version, formalizable into (B)'s explicit pool later. Neither is a temporary fix: a temporary fix would be e.g. capping static cells, or special-casing the leak in a test (a loophole) — both rejected.

## Why it is sound

- `NGroupCode` is **immutable** code; sharing it across evaluations and concurrent activations (a recursive function on the stack) is safe — no mutation, no per-evaluation specialization.
- Addresses are **not user-observable** (no language-level pointer equality on code); sharing `gAddr` is invisible to the program.
- **Cross-backend:** both backends intern identically (same `LetRec` → same address), staying in lockstep; the differential oracle is unaffected — `NGroupCode` is an uncounted static cell, so no counted stat (`allocs`/`frees`/`peak`) and no golden file changes. The leak's disappearance (fewer immortal `stCells` entries) is the only effect.

## Architectural framing: interpreter / allocator / runtime split

A **constant pool** is a **runtime** concept: read-only data (code constants now; string literals, big-int literals later), allocated once at load, owned by the runtime, referenced by the interpreter, and **never touched by the dynamic allocator** (constants are not alloc'd/freed per-operation). `NGroupCode` belongs there.

So this fix is a concrete step toward the planned **interpreter / allocator / runtime split**: it carves the constant pool out as a distinct region, separate from (i) the counted dynamic heap and (ii) per-evaluation allocations. The static/immortal region today is the de-facto constant pool — this fix just stops polluting it with duplicate constants. And it **transfers to codegen** (which emits the same code as static data), so it is not throwaway interpreter scaffolding.

## Implementation sketch + regression guard

- `Store`: add `stGroupCode :: Map (Set Unique) Addr` (or key by a representative member `Unique`).
- `Machine.hs` `LetRec` arm: `case Map.lookup groupU (stGroupCode s) of Just a -> (a, s); Nothing -> let (a, s') = allocStatic (NGroupCode defs) s in (a, s' { stGroupCode = Map.insert groupU a (stGroupCode s') })`.
- Test: evaluate a `LetRec`-in-a-loop N times; assert the immortal/static cell count stays **constant** (one per distinct `LetRec`), not O(N). (Once the immortal region gains a high-water self-check analogous to the physical-memory invariant added in Region R1, this also becomes catchable structurally rather than by a dedicated test.)
- Confirm the differential oracle stays green (no counted-stat change) and the existing `LetRec`/recursive-closure corpus is unaffected.
