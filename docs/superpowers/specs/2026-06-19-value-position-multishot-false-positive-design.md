# Value-position handler: one-shot check false-positive — design

Date: 2026-06-19
Status: design, pending user review
Branch: `fix/value-position-multishot-false-positive` (off `main` @ `46c1d30`)
Found by: the xhigh `/code-review` of the M2b resume-binder-type leak fix (a separate,
pre-existing bug; see `2026-06-19-m2b-resume-binder-type-leak-fix-design.md`).

---

## 0. Summary

wok's one-shot law (`Wok.IR.Multiplicity`) rejects a handler that could resume its
continuation more than once (`ω`). The check **over-fires on value-position handlers**: it
flags **every** value-position arm (`hAnswerJoin = Just j`) as `ω`, regardless of whether
the arm resumes 0, 1, or many times. A genuine one-shot value-position handler — including
the shipped `test/rc-m2b/24-state-value.wok` — is therefore falsely rejected and cannot be
run via `--run`.

Root cause: a value-position arm finishes by jumping to the handler's **answer-join**
(`jump j answer`); `cardOf`'s `Jump` rule charges `Many` for a jump to any join not in its
local env, and the answer-join (defined outside the arm) is never in that env. The fix:
tell the analysis the answer-join is an **exit** that contributes **zero** resume-uses, by
threading the handler's `hAnswerJoin` to the per-arm analysis and seeding `cardOf`'s
join-env with `answerJoin → Zero`. Genuine multi-shot still errors.

Scope: `Wok.IR.Multiplicity` only. Tail-position handlers (`hAnswerJoin = Nothing`) are
unaffected.

---

## 1. Verified ground truth (`main` @ `46c1d30`)

`--dump-multiplicity` / `--run` on value-position handlers:

| program | resumes | reported card | `--run` |
|---|---|---|---|
| value-position discard (`choose n k -> 88`) | 0 | `ω` | rejected "multishot resume" |
| `24-state-value.wok` (value-position `get`/`set`) | 1 | `ω` (both) | rejected |

The elaborated arm (from `--dump-anf`) for the discard case:

```
main =
  join j33(r.2 : U64) = case r.2 of 0 -> 0 ; _ -> r.2
  let t : U64 = prog(self)
  t
  with self : U64 = {
    return v : U64 -> jump j33(v)
    Choose.choose(n : U64, resume : U64 -> U64) -> jump j33(88)   -- resume unused
  }
```

`armCard` analyzes `oaBody = jump j33(88)` in isolation. `cardOf`'s rule
`Jump j as -> addC (Map.findWithDefault Many j env) (if mentionsAny r as then Many else Zero)`
sees `j33 ∉ env` → `Many`; `resume ∉ [88]` → `Zero`; `addC Many Zero = Many = ω`. The arm
never touches `resume`, so the true card is `0`.

The check only fires on the `--run` path (`Pipeline.elaborateCheckedFull` →
`analyzeModule`); the `rc-m2b` corpus harness uses the un-checked elaborate path, which is
why the shipped value-position tests are green there yet rejected by `--run`.

---

## 2. Root cause (precise)

`cardOf`'s `Map.findWithDefault Many j env` term answers "how many times does jumping to
`j` re-invoke `resume`?". For a `LetJoin`-bound `j` in scope, `env` holds the real count.
The `Many` default exists for **recursive joins**: when analyzing a `LetJoin j _ jb b`, a
recursive `Jump j` inside `jb` sees `j` not-yet-in-env, and `Many` conservatively models a
loop that could resume every iteration. That default is correct and must stay.

The **answer-join** is a different kind of "join not in env": it is the handler's *exit*
continuation, defined by the value-position elaboration **outside** the arm body. Its body
runs *after* the handler returns, in the enclosing scope, and **cannot reference the arm's
`resume` binder** (a fresh local of the arm). So jumping to it contributes **zero**
resume-uses. Charging `Many` is the bug.

`armCard` cannot distinguish the two today because it analyzes each `oaBody` with no
knowledge of the enclosing handler's `hAnswerJoin`.

---

## 3. The fix (decisions)

### 3.1 Seed the answer-join as a zero-cost exit

Thread the handler's `hAnswerJoin` to the per-arm analysis and seed `cardOf`'s initial
join-env with `answerJoin → Zero`. Then:

- `jump answerJoin answer` (the normal exit) → `addC Zero (resume∈args ? Many : Zero)` →
  the args check alone. Discard arm → `0`; one-shot arm (`let res = resume(...) in
  jump answerJoin res`) → `1` (the resume call) `+ 0` (the exit) → `1`.
- A **recursive** join is still not seeded → still `Many` (conservative, unchanged).
- `resume` **escaping** via the exit (`jump answerJoin resume` — returning the continuation
  as the answer) still hits the args check → `Many`. So that genuine escape still errors.

This is sound: seeding `Zero` asserts only that the answer-join's *own body* does not invoke
the arm's `resume`, which is structurally guaranteed (the body is outside the arm). The
relaxation can never lower a genuine multi-shot below `ω` — the two-resume, recursive, and
escape cases are all independent of the answer-join seed.

### 3.2 Rejected alternatives

- **Blanket `findWithDefault Zero`** for unknown joins — *unsound*: a recursive join that
  resumes once per iteration would be undercounted to `1` instead of `ω` (the `Many` default
  is load-bearing for recursion).
- **Skip the check for value-position handlers** — *unsound*: a value-position handler can be
  genuinely multi-shot (resume twice), which must still error.

### 3.3 Implementation surface (`Wok.IR.Multiplicity` only)

- `cardOfWithTrust`: add a **seed join-env** parameter (`Map JoinId Card`); start `go` from
  it instead of `Map.empty`.
- `cardOf` (public shim): unchanged signature — passes an empty trust map **and** empty
  seed. (Keeps the existing `cardOf` unit tests untouched.)
- `computeTrustMap`: passes an empty seed (top-level functions have no answer-join).
- `armCard`: take the arm's `Maybe JoinId` (its handler's `hAnswerJoin`); build the seed
  `maybe Map.empty (\j -> Map.singleton j Zero) aj` and pass it.
- `opArmsInModule` / `opArmsInExpr` / `opArmsInRhs` / `opArmsInAlt` / `opArmsInHandler`:
  change the element type from `OpArm` to `(Maybe JoinId, OpArm)`; `opArmsInHandler` pairs
  each of its ops with the handler's `hAnswerJoin`; nested handlers (reached via
  `opArmsInExpr (oaBody oa)`) get their own answer-join.
- `analyzeModule` / `prettyMultiplicity`: iterate the `(Maybe JoinId, OpArm)` pairs.

`Carrier.hs` has its **own** local `armCard` (the carrier-affine analysis) — unrelated;
not touched. No other module changes.

---

## 4. Testing (run-the-exploit + red-check)

1. **Green after fix (the exploit):** the value-position discard reports `0`; a
   value-position one-shot (`24-state-value`) reports `1` for each op; both **run via
   `--run`** (no "multishot resume"). Add a `--run` golden (or assertion) for a
   value-position one-shot so the run path is covered, not just `--dump-multiplicity`.
2. **Red-check #1 — genuine multi-shot still errors:** a value-position arm that resumes
   twice (`choose n k -> let a = k 0 in let b = k 1 in a + b`) must still report `ω` and be
   rejected by `--run`. (The existing `cardOf` unit test `resumeTwiceSeq → Many` already
   pins this at the function level; add a value-position program-level case.)
3. **Red-check #2 — revert re-introduces the bug:** removing the answer-join seed makes the
   value-position one-shot/discard go back to `ω` (a named test goes red).
4. **Golden:** add `--dump-multiplicity` golden(s) for a value-position one-shot (→ `1`) and
   discard (→ `0`); regenerate any existing multiplicity golden that changes (expected:
   none — no current golden exercises a value-position handler; verify).
5. **No regression:** the existing `cardOf` unit tests (`Ret unit → 0`, `resumeOnce → 1`,
   `resumeTwiceSeq → Many`, `resumeInBothArms → 1`, escape cases → `Many`) stay green; full
   suite green.

---

## 5. Acceptance criteria

- Value-position one-shot and zero-shot (discard) handlers pass the one-shot check and run
  via `--run`; reported cards are `1` / `0`, not `ω`.
- A genuine multi-shot value-position handler still reports `ω` and is rejected (red-check
  #1); reverting the seed re-introduces the false `ω` (red-check #2).
- Tail-position handlers unchanged.
- `Wok.IR.Multiplicity` is the only source module changed; `cardOf`'s public signature is
  unchanged; full suite green.

---

## 6. Out of scope

- Any broader rework of the multiplicity analysis or the one-shot law itself.
- The tail-position path (no answer-join; already correct).
- The interpreter / RC pass (unaffected — this is a frontend check-precision fix).
