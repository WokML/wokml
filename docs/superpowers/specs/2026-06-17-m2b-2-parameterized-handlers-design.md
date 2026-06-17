# M2b-2 — Parameterized handlers, two-arg resume, value position on the RC store (design)

Status: design, pending implementation. Date: 2026-06-17. Author: brainstorm with Claude.
Predecessor: `docs/superpowers/specs/2026-06-17-m2b-continuations-effects-rc-design.md` (the
M2b umbrella; M2b-1 implemented on `feat/m2b-1-continuation-frames`).

> **Supersedes §5.2** of the M2b umbrella doc (which sketched M2b-2 in one paragraph). The
> model, slice cut, and acceptance below are the authoritative plan. Everything in the
> umbrella's §3 (invariants), §4.2–§4.5 (owned-set mechanism, level-1 decision, capture/
> resume/abort accounting) still holds and is *extended*, not redesigned.

## 0. Summary

M2b-1 brought reference counting to effect handlers for the narrow fragment: **no
parameter, one-argument resume, tail position**. M2b-2 lifts the remaining three
restrictions so the full `Std.Control` `state` (and `writer`) runners run heap-balanced:

1. **Handler parameter** (`hParam`) — a value the handler frame owns (e.g. `State`'s `s`).
2. **Two-argument resume** (`VContP`) — `resume(newParam, result)` rebinds the parameter.
3. **Value / non-tail position** (`hAnswerJoin = Just j`) — the answer-redirect.

Plus the two soundness obligations the umbrella flagged: the **#3 fix** (a nested
parameterized handler in an aborting prefix must free its parameter) and the
**carrier-wall check** (a continuation handle must never reach a counted data slot).

The reference interpreter (`Wok.Interp.Machine`) remains the differential heap-balance
oracle for the *semantics* (two-arg resume, answer-rebind). For *ownership* (the parameter,
the #3 fragment, the carrier wall) the reference does no refcounting and gives zero
guidance — those are validated by **run-the-exploit** against the RC store, driven by the
Suite-G generative property, exactly as M2b-1 demanded.

## 1. The confirmed model (the parameter is a baton)

The division of labour is the M1/Perceus contract, unchanged:

- **Compiler (Perceus, static):** decides and places every *consume*. Two forms — an
  explicit `__rc_dup x` / `__rc_drop x` instruction, or a consume *implicit in an
  operation* (a `Case` consuming its scrutinee, an application consuming a one-shot value).
  Where an operation already consumes a value, the pass places **no** drop.
- **Runtime (interpreter):** never *decides* a drop. It executes the `__rc_dup`/`__rc_drop`
  instructions, allocates, and — when a cell's count hits zero — **cascades to that cell's
  children** and releases them. The cascade has always been the runtime's job (a dead
  `Cons` decrements its head and tail with no per-child instruction).

The handler parameter fits entirely inside this contract. Think of it as a **baton**:

- While a handler frame is *passive* (installed, no op firing) the **frame holds the
  baton** — `hsc[hParam]`.
- The moment one of its ops fires, the baton's ownership **moves to the running op-arm**
  (it becomes an owned binder of that arm, alongside the op-args and `resume`).
- The arm's *ordinary* last-use machinery decides the old baton's fate and emits it **as
  IR**: dead in the arm (`set x k -> k x ()`, old `s` unused) → `__rc_drop s`; passed
  onward (`get -> resume(s,s)`, `return v -> (v,s)`) → consumed by the operation, no drop.
- On `resume(newParam, result)` the runtime's only parameter action is a **pure own-new
  move**: bind `newParam` into the re-installed frame's slot. No drop — the previous slot
  binding was handed to the arm at dispatch and is stale.

**Consequences (the model in one breath):** there is **no runtime "drop-old."** Every
parameter drop is a compiler-placed `__rc_drop` (or a consume-by-operation). The runtime
only executes drops, moves the new baton in, and cascades dead cells. The **one** thing the
runtime *computes* rather than reads literally is an `NCont`'s child-set (the owned set) —
the M2b-1 mechanism. M2b-2 widens that child-set (the #3 fix) and adds compiler-placed
parameter drops; it introduces **no new category of runtime work**.

Why this is sound against cycles: `State.set` is **binding-mutation** (rebind the frame's
parameter slot to a finished immutable value), never **cell-mutation** (rewriting a live
field of a shared cell). Only cell-mutation forges counted cycles. The carrier wall
(Invariant 3) blocks the one remaining cycle shape — a continuation handle inside a
parameter slot — by *rejection*, verified by exploit in §3.5.

## 2. Slice decomposition

The three axes are not independent. **Parameter and two-arg resume are welded** (the
two-arg `resume(newParam, result)` exists only to rebind a parameter; no-param handlers are
one-arg by construction). **Value-position is orthogonal** (`answerRebind` fires with or
without a parameter — the reference applies it in both the `VCont` and `VContP` branches).
So the clean cut is **tail vs. value position**:

- **2a — parameter + two-arg resume, TAIL position.** The baton model, the two-arg `NCont`
  resume arm, the #3 fix, the carrier-wall check. *Within 2a, the #3 fix lands first* — fix
  the owned-set nested-handler skip and ship its exploit **before** the boundary admits
  `hParam`, so admission never outruns the soundness fix.
- **2b — value / non-tail position.** The RC-balanced `answerRebind`.

**Process.** One branch (`feat/m2b-2-parameterized-handlers`, off the M2b-1 tip — identical
commits to post-merge main). Two **internal oracle checkpoints** (one after 2a, one after
2b): each = `genM2bProgram` extended with that slice's shapes, the `test/rc-m2b/` corpus
heap-balanced, every lifted rejection shipped with its reproducer + a red-check, and a
run-the-exploit adversarial pass. A **single full-branch `/code-review` before merge** is
the user's gate (`[[review-before-merge]]`); M2b-1's lesson is that the full-branch
adversarial review — not the per-task green checks — is the soundness net. **No merge to
main is performed by the implementer.**

## 3. Slice 2a — parameter + two-arg resume + #3 fix + carrier wall (tail)

The acceptance target, elaborated (`runState i c = let s = i in Handle (c ()) H`,
`--dump-anf` confirmed):

```
return v          -> Tuple2(v, s)      -- consumes the parameter s
get(resume.1)     -> resume.1(s, s)    -- two-arg: newParam = s, result = s
set(x, resume.2)  -> resume.2(x, ())   -- two-arg: newParam = x, result = ()
```

### 3.1 The parameter-ownership invariant

> A handler frame **owns its parameter while passive**. Firing one of its ops **moves the
> parameter into the running op-arm**. `resume(newParam, …)` **moves the new parameter back**
> into the re-installed frame (pure own-new). Normal completion delivers the frame's
> parameter to the **return arm**, which consumes it (`(v, s)`). Therefore the dispatched
> handler's parameter is **never** in any `NCont` owned set (it is in the arm); and a
> *passive nested* handler's parameter **is** owned by its frame and is freed when an
> enclosing continuation aborts (the #3 fix, §3.4).

### 3.2 Static (Perceus) changes

The op-arm is already instrumented as a fresh owned scope (`ownOpArm`/`armCtxReset`/
`armDelta` in `Wok.IR.Perceus`). M2b-2 adds the parameter to the arms that run, and marks
the `Handle` as *consuming* its parameter at entry so the enclosing scope does not also
drop it.

1. **Entry — the `Handle` consumes `hParam`.** In `ownExpr (Handle e h)` with
   `hParam = Just pb`: `pb` is a free var of the `Handle` (it appears in the arms, so the
   fixed `freeVarsExpr (Handle …)` makes it live across the `Handle`) and is owned in the
   enclosing `delta` via the seed `let s = i`. Treat the `Handle` as **consuming** `pb`:
   remove `pb` from the handled-expr `e`'s `delta` (so `e` does not drop it) and from the
   enclosing post-`Handle` drop set (so the enclosing scope does not drop it). Ownership
   transfers inward to the arms / return arm.
2. **Return arm owns `pb`.** Add `pb` (if boxed) to `retDelta` and bind it in `retCtx`.
   `return v -> (v, s)` consumes it into the tuple; an unused boxed `pb` is dropped at last
   use (no leak).
3. **Each op-arm owns `pb`.** In `ownOpArm`, add `pb` (if boxed) to `armDelta` and bind it
   in `armCtx`. Then the existing machinery does everything: `get -> resume(s,s)` dups `s`
   once for the double use; `set x k -> k x ()` leaves the old `s` dead → `__rc_drop s`;
   abort (op fires, never resumes) drops the parameter at the arm's last use.

`coveredHandler` already recurses into the return body and each op body; it stays correct.
The lint mirror (`checkExpr`) must reset/seed the parameter in the arm/return scopes
identically (it already mirrors `ownOpArm`'s `armDelta`).

### 3.3 Runtime (RC machine) — two-arg resume

`rcDispatchOp` (`Wok.Interp.RC.Machine`) is unchanged in shape: capture moves the `above`
frames into an `NCont`, binds the op-args + `resume = RVBox cAddr`, runs the arm under
`kBelow`. The handler `h` (carrying `hParam`) is stored in the `NCont` hinfo, so the resume
arity is known at resume time from `hParam h`.

The `enterRC` `NCont` arm gains the two-arg path (mirroring the reference `enter` `VContP`
branch, `Wok.Interp.Machine:157`):

```
NCont{} -> do
  (prefix, (h, hTag, hsc), s') <- moveOutCont addr s   -- frees the shell, asserts rc == 1
  case (hParam h, args) of
    (Nothing, [v]) ->                                   -- M2b-1 one-arg path, unchanged
      Right (RReturn v (spliceKont prefix (KHandleRC h hTag hsc k)) s')
    (Just pb, [newParam, result]) ->
      let hsc' = hsc { rscEnv = bindRCBinder pb newParam (rscEnv hsc) }   -- own-new, pure move
          k'   = spliceKont prefix (KHandleRC h hTag hsc' k)
      in Right (RReturn result k' s')
    _ -> Left (ArityError "resume arity does not match handler parameter")
```

The old `hsc[pb]` binding is **overwritten** (it was moved to the arm at dispatch; stale).
**No drop here** — own-new only. This is the entire runtime delta for the parameter.

### 3.4 The #3 fix — nested passive handler parameter in the `NCont` child-set

`continuationOwned` (`Wok.Interp.RC.Value`) currently **skips** a nested `KHandleRC` in the
captured prefix (`go (KHandleRC _ _ _ k) = go k`). Sound for M2b-1 (a no-parameter handler
owns nothing live), but a nested *parameterized* handler owns its baton. Fix:

```
go (KHandleRC h _ hsc k) =
  [ (Just (binderUnique pb), a)
  | Just pb <- [hParam h]
  , Just v  <- [Map.lookup (binderUnique pb) (rscEnv hsc)]
  , a       <- countedRefs [v] ]
  ++ go k
```

Only the **parameter** is added — the rest of `hsc` is the captured enclosing scope, owned
by its binders elsewhere (the M2b-1 reasoning is unchanged). The `Unique`-keyed entry
participates in the existing dedup. A nested handler whose op already fired-and-resumed
holds its *current* baton in `hsc[pb]`; freeing that on abort is correct.

**Exploit + red-check (ships with the fix):** an outer `Except`-style handler, a nested
`State [U64]` (boxed parameter), an op handled by the **outer** handler so the inner
`State` `KHandleRC` sits in the captured prefix, then the outer **aborts** (throw). The
inner `State` baton must be freed exactly once. Revert the `KHandleRC` arm to `go k` ⟹ the
generative property + this corpus case go red (leak).

### 3.5 The carrier-wall check (verify, do not assume)

Invariant 3: no `RVBox`→`NCont` in a constructor field, record field, `NEnv` capture, or
**parameter slot**. With two-arg resume, the new surface is `resume(newParam, result)`:
were `newParam` a continuation handle, the re-install would seat an `NCont` in `hsc[pb]` —
the `state → cont → frame → state` cycle RC cannot collect.

The wall is enforced statically by `m2bResumeEscapes` (`Wok.IR.Escape`): a `resume` binder
may appear **only** as a saturated call head; any other occurrence — including as a
non-head **argument of another `resume` call** (`resume(resume, ())`), or sealed into a
con/record — is an escape and the handler is rejected. 2a's obligation is to **verify** the
two-arg argument positions are covered, by exploit: `op(x, resume) -> resume(resume, ())`
(seat the continuation into the parameter) and `set` storing a continuation **must be
rejected**; red-check by removing the resume-escape guard. No new predicate is expected —
this is a confirmation that the existing wall covers the widened surface.

### 3.6 Boundary-guard widening

`m2bHandlerViolations` (`Wok.IR.Reachable`) and `m2bHandlerInFragment` (`Wok.IR.Escape`)
drop the `hParam`-rejection but **keep** the value-position rejection (that is 2b) and the
escaping-resume rejection (M3). `m2bHandlerInFragment` becomes:

```
m2bHandlerInFragment h =
  isNothing (hAnswerJoin h)                                  -- still tail-only (until 2b)
    && all (\oa -> not (m2bResumeEscapes (oaResume oa) (oaBody oa))) (hOps h)
```

The enclosing-boxed-local arm-capture reject (`freeVarsHandler h ∩ bsc`, the M2b-1 UAF fix)
**stays** — it is context-dependent and orthogonal to the parameter. Note the parameter
`pb` is excluded from `freeVarsHandler` already (the umbrella's `Anf.freeVarsHandler` is
"arms' free vars minus their binders and `hParam`/`hSelf`"), so admitting `hParam` does not
collide with that guard.

### 3.7 Acceptance + oracle (checkpoint after 2a)

- `State` `get`/`set` in **tail** position (`main = runState 100 prog`), returning `(v, s)`
  heap-balanced via `assertRcAgrees`.
- `Writer` accumulator (`tell w k -> k (log ++ w) ()`), boxed `[w]` parameter, heap-balanced.
- Nested `State` + `Reader` (exercises a parameterized frame with another handler in scope).
- The #3 exploit (§3.4) and the carrier-wall exploit (§3.5), each pinned + red-checked.
- `genM2bProgram` extended with: `hParam` present/absent, one- vs two-arg resume, a
  **boxed parameter** dropped on a `set`-to-constant path, a **nested parameterized handler**
  in an aborting prefix. `cover`/`checkCoverage` floors so each shape is non-vacuously hit.

## 4. Slice 2b — value / non-tail position (`answerRebind`)

In value position the handler is wrapped by a `case`/join and `hAnswerJoin = Just j`: a
resumed sub-run's *answer* must be delivered to the **resume call site**, not the static
post-handler continuation. The reference does this with `answerRebind` (`Machine.hs:199`):
per resume, it rebinds the answer-join `j` to a join whose body returns its single
parameter and whose continuation is `after` (the resume site); the top-level op-arm keeps
the original `hsc`, so the real post-handler work runs once on the final answer.

### 4.1 RC-balanced `answerRebind`

The RC analogue rebinds the `RCJoin` in `hsc'` at the two-arg (and one-arg) resume site,
before the splice:

```
answerRebindRC after sc =
  case hAnswerJoin h of
    Just j | Just (RCJoin _ ps _ _) <- Map.lookup j (rscJoins sc), (pb0 : _) <- ps ->
      sc { rscJoins = Map.insert j (RCJoin sc ps (Ret (AVar (bndName pb0))) after)
                        (rscJoins sc) }
    _ -> sc
```

Applied in the `enterRC` `NCont` arm: the re-installed scope is `answerRebindRC k hsc'`
(the parameter own-new from §3.3 composes — rebind the param slot, then redirect the answer
join). **RC-balance argument:** `answerRebindRC` is a pure **control-flow** manipulation —
it replaces a join's body/continuation in the scope map; it allocates and frees **no**
counted value. The answer value flows through `Ret (AVar pb0)` (a move, no dup/drop) to
`after`. Joins are not counted heap values, so the rebind cannot leak or double-free. This
is the **claim the oracle must falsify-or-confirm**, not a proof: §4.4.

### 4.2 Boundary-guard widening

Drop the `hAnswerJoin` rejection from `m2bHandlerViolations`/`m2bHandlerInFragment`. The
fragment is now: every reachable handler has non-escaping resume (M3 still rejects escaping/
stored continuations) and no enclosing-boxed-local arm capture. `hParam` and value position
are both admitted.

### 4.3 Acceptance + oracle (checkpoint after 2b)

- `State` in **value** position (e.g. `let r = runState 0 prog in <use r>`), heap-balanced.
- A value-position **abort** (resume not taken under a value-position handler), heap-balanced.
- `genM2bProgram` extended with a value-position dimension (handler under a `case`/join),
  including value-position abort. `cover` floor: "non-tail resume run", "value-position
  abort run".

## 5. Invariants to CHECK during implementation (not assume)

- **No runtime drop-old.** Assert: the two-arg `enterRC` `NCont` arm performs **only**
  own-new (no `dropAddr` of the old parameter). Any parameter drop must be a compiler-placed
  `__rc_drop` visible in `--dump-perceus`. A boxed-parameter `set`-to-constant abort is the
  case that would expose a missing drop (leak) or a stray runtime drop (double-free).
- **Owned-set widening is exact (#3).** `continuationOwned` adds *only* the nested handler's
  parameter, deduped by `Unique`. Free fewer ⟹ leak; free more (the rest of `hsc`) ⟹
  double-free. Pin with the §3.4 exploit and red-check.
- **Carrier wall holds at the parameter slot.** The §3.5 exploit is rejected; red-check by
  removing the resume-escape guard.
- **No counted cycle through a parameterized frame.** `State.set` is binding-mutation; the
  frame's `hsc` holds the baton but the baton never holds the frame. Re-verify once `hParam`
  is counted (construct `state → cont → frame → state` and confirm it is rejected, not run).
- **`answerRebind` is control-flow only.** Value-position `State` and value-position abort
  are heap-balanced; the rebind allocates/frees no counted cell.
- **`KDropCellRC` composes** with a parameterized `KHandleRC` (an over-applied member
  returning across a parameterized handler boundary), per the umbrella §8.

## 6. Testing and the oracle (non-negotiable)

Extends the umbrella §7 discipline. Every lifted rejection ships with its run-the-exploit
reproducer **and** a red-check (revert the fix ⟹ a named test goes red). The Suite-G
generator is the durable oracle; the M2b-1 lesson stands — the **full-branch adversarial
review that BUILDS the triggering program** is mandatory before the merge gate, because the
generative property only catches the class it generates (M2b-1's constant-bodied arms
missed the capture UAF). Budget several review rounds. `rcMemSafetyFault` already classifies
double-free/UAF/dangling/`is not NEnv`/`resume of non-continuation`; add a parameter-specific
fault string only if a new failure shape is introduced.

## 7. Deferred to M3 (stay sound-rejected, pinned)

- **First-class / stored / escaping continuations** (the scheduler): `resume` stored in a
  cell/channel/`schReady`. Needs the unbuilt affine-through-aliasing analysis
  (`[[explicit-resume-effect-laundering]]`). `m2bResumeEscapes` keeps rejecting it.
- **The #7 latent owned-set dedup gap** stays marked until over-application (`KAppRC`) or an
  over-applied M2a-2 member (`KDropCellRC` env) can coincide with a live named binder inside
  a captured prefix.

## 8. Risks and open questions

- **The parameter-consumed-at-`Handle` rule** (§3.2.1) is the one new static accounting; the
  hazard is a *missed* exclusion (enclosing scope drops `s` after the `Handle` ⟹ double-free
  with the return arm's `(v,s)` consume). Verify on the `State` tail corpus early, and pin
  the boxed-parameter case in the generator.
- **`get -> resume(s,s)` mentions the parameter twice in one arm** — Perceus dups it once
  (two live copies); confirm the dup plus the own-new on re-install net to refcount-balanced.
  This is a double *mention* of `s` within a single arm, not a multi-shot resume — one-shot
  still holds (the arm resumes at most once).
- **Value-position `answerRebind`** manipulates the join scope; confirm against the oracle
  that no counted value tied to the original join is leaked when the rebind is per-resume and
  the original `hsc` is retained for the final answer.
- **One-shot enforcement on the test path.** Confirm the RC harness elaboration runs the
  Multiplicity gate (or the generator filters multi-shot), so no multi-shot program reaches
  the two-arg move-out.
