# Effects Slice 3: bounded handler scope `(with H e)` + the delimited-continuation fix

Date: 2026-06-06
Status: Design converged (from extended brainstorming + a root-cause investigation).
Implements: **slice 3** of `docs/superpowers/specs/2026-06-05-effect-handlers-ROADMAP.md`.
Reads with: `2026-06-05-effect-handler-surface-syntax.md` (§4.1 scope rule, §11 deferred
bounded form, §12 sharp edges), `docs/superpowers/specs/2026-06-05-effect-handlers-unified-case-design.md`
(§"Compilation and runtime model": the CEK machine / deep `VCont` lowering this fix touches).

## 1. Summary

Slice 3 delivers the **bounded, parenthesized handler expression** `(with H e)` whose
handler scopes only the expression `e`, not the rest of the enclosing block — so a handler
can be used mid-expression and the block continues after it.

The brainstorming produced two findings that reshape the slice from what the roadmap assumed:

1. **The bounded form already parses and routes correctly, with zero grammar changes.**
   `with { arms } e` (and headed `with E { arms } e`) is an `Exp2` whose trailing `Exp`
   is the handled computation; the existing `EParen` (`"(" Exp ")"`) bounds it. It routes
   through the same `inferHandler` → `THandle` → Elaborate path. The roadmap's notated
   separator `(with H ; e)` is **not** added: `;` is already the arm separator, the `}`
   already ends the handler, and a dedicated `"(" "with" … ")"` production would *conflict*
   with `EParen`+`EWith`. So the canonical bounded form is **`(with H e)`, no separator**.

2. **The bounded form is NOT pure additive sugar — it surfaces a latent runtime bug.**
   A handler in **non-tail position** (exactly what the bounded form is) mis-handles
   `resume`: a multishot / generator / deferred-resume handler returns wrong answers
   because the captured continuation is not delimited at the handler boundary. This is a
   pre-existing slice-1/2 defect (reachable today via `(with {multishot} e) + 0`), latent
   only because the prefix `with` is always at the block tail. Slice 3 **fixes it**.

The decision (option A from brainstorming): bless `(with H e)`, fix the delimiter bug
properly, ship the bounded surface as goldens + docs. No new grammar, no separator.

## 2. Root cause of the delimited-continuation bug

When a handler is in value position, `normName` (`src/Wok/IR/Elaborate.hs:125-131`) hoists
the post-handler work into a join point and lowers the handler's arms to **`jump` to it**:

```
join j31(r) = r + 0                    -- "+ 0" after the handler
... with { return v      -> jump j31(v)
           flip resume   -> ... jump j31(t.7) }
```

In the machine, a join point captures the continuation **at its definition site**
(`LetJoin j ps jb k` → `JoinPoint sc ps jb k`, `src/Wok/Interp/Machine.hs:60-61`), and
`Jump j` transfers to that **static** `jk` (`Machine.hs:64-69`), discarding the current
continuation.

`resume` (`Machine.hs:147`) re-installs the handler over `after` (the resume call site):

```haskell
resumeVal = VCont (\after -> above (KHandle h hsc after))
```

but `hsc` still maps `j31 → jk = the top-level continuation`. So when a resumed sub-run
finishes and the return arm runs `jump j31 v`, control jumps to the **static top-level**
continuation, *escaping* the `after` that `resume` just installed.

Trace of `(with { flip k -> k True + k False } pick()) + 0` (expected 30):

- `flip` fires; arm runs `resume(True)`.
- `resume(True)` re-runs `pick` → `10` → return arm `jump j31(10)` → jumps to the static
  `r+0`→halt → program returns **10**. `resume(False)` never runs.

**Why tail position works:** no join point exists; arms tail-return values which flow to the
`KHandle` frame's `k`, and `resume` *does* rebind that `k` to `after`.
**Why single-shot `1 + (with {ask k -> k 41} …)` returned 42:** by accident — it escapes on
its one resume and `1+41` equals the correct answer. Multishot exposes that the escape is real.

## 3. The fix: make the answer-join honor `resume`

The arms jumping to the handler's answer-join is correct *at the top level* but must be
**redirected to `after` when the handler is re-installed by `resume`.** Record which join is
the handler's answer continuation; have `resume` rebind it to deliver straight to `after`.

Three localized changes:

1. **`src/Wok/IR/Anf.hs` — `Handler`:** add `hAnswerJoin :: Maybe JoinId` — the join the
   arms deliver to in value position; `Nothing` in tail position. Update `collectHandler`
   (free-var collection) and `renderHandler` (no behavioural change; field is metadata).

2. **`src/Wok/IR/Elaborate.hs` — `elabKF tk … (THandle …)`:** set it from the tail
   continuation: `case tk of TJump j -> Just j; TRet -> Nothing`. Arm lowering is unchanged
   (arms already deliver via `tk`). The answer-join is exactly the value-position merge join
   `normName` created, or the enclosing branch join when the handler is a branch tail — in
   both cases that join IS the handler's answer continuation, so the rebind is correct.

3. **`src/Wok/Interp/Machine.hs` — `dispatchOp`:** when building `resumeVal`, re-install the
   handler over a scope where the answer-join is rebound to deliver its argument straight to
   `after` (identity → `after`) instead of running its static post-handler body:

   ```haskell
   let resumeVal = VCont (\after ->
         let hsc' = case hAnswerJoin h of
               Just j | Just (JoinPoint _ ps _ _) <- Map.lookup j (scJoins hsc) ->
                 hsc { scJoins = Map.insert j
                                   (JoinPoint hsc ps (Ret (AVar (joinParamName ps))) after)
                                   (scJoins hsc) }
               _ -> hsc
         in above (KHandle h hsc' after))
   ```

   The **op arm at top level keeps the original `hsc`** (so the real post-handler work, e.g.
   `+0`, applies once to the final answer); only the **re-installed** handler used by
   `resume` gets the rebind. Each delimited sub-run then returns its answer to the resume call
   site, while the top-level exit flows through the post-handler work exactly once.
   `joinParamName ps` extracts the single result binder name from the original join's params
   (`ps`); a defensive fallback leaves `hsc` unchanged if the join is absent or not unary.

### Correctness across cases (traced, pre-implementation)

| Program | Today | After fix |
|---|---|---|
| tail multishot `with {flip k -> k True + k False} pick()` | 30 | 30 (unchanged) |
| `(multishot) + 0` | 10 | 30 |
| `1 + (multishot)` | 11 | 31 |
| `let r = (multishot) in r` | 10 | 30 |
| `[100] ++ (generator)` | [100] | [100,1,2,3] |
| `1 + (with {ask k -> k 41} prog())` | 42 (lucky) | 42 (correct) |

Tail handlers set `hAnswerJoin = Nothing`, take no rebind, and behave exactly as before
(regression-guarded by the existing `17-choice-multishot`).

## 4. Scope

In scope:
- The delimited-continuation fix (§3): `Anf.hs`, `Elaborate.hs`, `Machine.hs`.
- Golden tests pinning (a) the corrected non-tail resuming behavior — the §3 matrix — and
  (b) the already-working bounded surface: `(with H e)+k`, header form `(with E { } e)`,
  nested bounded handlers, reshape-and-unpack via `let`.
- Docs reconciliation: ROADMAP slice-3 row → done; surface-spec §4.1/§11/§12 updated to
  state the bounded form is `(with H e)` (no separator) and works for all handler kinds;
  drop the "extract a helper today" workaround language. Migrate 1–2 helper-bounded examples
  to the inline form where it reads naturally.

Out of scope (unchanged from roadmap; deferred to slice 4):
- **Clean stateful `State`** via parameterized handlers. The function-answer-type encoding
  also hits the one-argument-continuation convention (`k s s`); whether it works after the
  §3 fix is *verified* in the plan, but not promised — clean `State` remains slice 4.
- **Async scheduler / `spawn` / `par` / `Future` / `Control.Wok`.** The deferred-resume
  *shape* type-checks but needs a runtime + existentials to actually resume parked
  continuations.
- The separator `;`/`in` (rejected: conflict + overload, no need — see §1).

## 5. Surface syntax (final)

```
-- bounded: handler scopes only `e`; block continues after the `)`
(with { Exn.throw m k -> None ; v -> Some v } risky True)
(with State { get -> 0 ; set s -> () } prog ())     -- header rides along
let r = (with { … } comp) in use r                  -- reshape mid-function, no helper
[100] ++ (with { Yield.yield x k -> [x] ++ k() ; v -> [] } producer())  -- generator inline
```

No separator between the handler `}` and the computation `e`; the `}` is the boundary, the
`)` bounds the scope. Everything from slices 1–2 (optional header, auto-resume / binder
control, value arms, the forgotten-resume lint, `Never`) applies for free.

## 6. Risks

- **Highest risk = the machine rebind (§3.3).** Front-load it behind the failing §3 matrix
  (TDD) so the fix is proven against every resume shape before touching docs.
- The `hAnswerJoin` provenance assumption — that `tk = TJump j` always names the handler's
  answer continuation — is argued in §3.2; the nested-branch golden (`33`) exercises it.
- Free-var / hint collection over the new `Handler` field must stay consistent
  (`collectHandler`) or the printer/round-trip goldens drift.
