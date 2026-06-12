# Slice 3: Conc effect + deterministic interpreter scheduler (Provider A) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers-extended-cc:subagent-driven-development (recommended) or superpowers-extended-cc:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship the `Conc` concurrency surface (`spawn`/`async`/`await`/channels) backed by a deterministic interpreter-level scheduler (Provider A), with tokens as plain-data provider ids so the wok side never holds a carrier.

**Architecture:** The wok surface is `effect Conc`, plain `data Fiber/Promise/Chan` wrapping a `U64` provider id, and library `runConc`/`parAll`/`raceAny`. Concurrency operations desugar through a single monomorphic transport operation `Conc.req : Request -> Transport`, where `Transport` is a plain-`data` envelope (`data Transport = Transport U64`) over one trusted runtime-identity coercion `__coerce : a -> b`, fenced behind `erase`/`recall`; this recovers the polymorphic result type of `await`/`recv` with no new type-system machinery (no extern carrier, no `opaque` keyword). `runConc` adapts `Conc` to the existing `Coro Request Transport` machinery and hands the root coroutine to a new Haskell driver `driveConc`, which holds all scheduler state in a `StateT SchedState` sidecar (run-queue, generational promise/channel cells) and steps coroutine segments via the existing pure `run`/`enter`. The CEK machine is unchanged except for one new `PrimResult` constructor (`PRDrive`) that `enter` dispatches to `driveConc`.

**wok syntax conventions (apply to ALL fixtures below):** lambda is `\ x -> e` (NOT `fn`); a `let` binder must be named (`let r = e in ...`, NOT `let _ =`); the list type is `[a]` with `[]`/`::` constructors; `::` is **pattern-only** — build lists with `[x]`/`++` in expressions; tuple-pattern let (`let (x, y) = ... in ...`) is supported.

**Tech Stack:** Haskell (GHC, the interpreter/typechecker); wok prelude (`prelude/Std/Control.wok`); `tasty`/`tasty-golden` test harness (`test/Spec.hs` with `test/run-examples` + `test/run-golden`, `test/typecheck-examples`, `test/typecheck-fail-examples`).

---

## File Structure

- `prelude/Std/Control.wok` — MODIFY. Add `effect Conc`, `data Fiber/Promise/Chan`, `data Transport`, `data Request`, `extern __coerce`, `extern __drive_conc`, the `erase`/`recall` helpers, and the library functions `runConc`/`yield`/`spawn`/`async`/`await`/`newChan`/`send`/`recv`/`cancel`/`parAll`/`raceAny`.
- `src/Wok/Interp/Value.hs` — MODIFY. Add the `PRDrive` constructor to `PrimResult`.
- `src/Wok/Interp/Prim.hs` — MODIFY. Add `__coerce` (runtime-identity) and `__drive_conc` (returns `PRDrive`).
- `src/Wok/Interp/Sched.hs` — CREATE. `SchedState`, `Cell`, and `driveConc :: PrimTable -> Value -> Either RuntimeError Value` (the scheduler; pure, `StateT SchedState (Either RuntimeError)`).
- `src/Wok/Interp/Machine.hs` — MODIFY. In `enter`, dispatch `PRDrive thunk` to `Sched.driveConc`.
- `src/Wok/TypeChecking/Infer.hs` — MODIFY. Add the payload well-formedness check for `Promise`/`Chan`.
- `src/Wok/TypeChecking/Error.hs` — MODIFY. Add the `ConcPayloadEffectful` error variant.
- `test/typecheck-examples/conc-*.wok`, `test/typecheck-fail-examples/conc-*.wok`, `test/run-examples/conc-*.wok` + `test/run-golden/conc-*.expected` — CREATE.

Boundaries: the scheduler lives entirely in `Sched.hs` (one module, deletable if Provider B/C supersedes it); the machine change is one constructor + one `enter` arm; the typechecker change is one localized check.

---

### Task 0: Branch and baseline

**Goal:** A clean feature branch off `main` with the suite green.

**Files:** none (git only).

**Acceptance Criteria:**
- [ ] On a new branch `feat/slice-3-conc` created from `main`.
- [ ] `cabal test` (or the project's test command) passes at baseline.

**Verify:** `cabal test 2>&1 | tail -5` → all suites pass.

**Steps:**

- [ ] **Step 1: Branch from main**

```bash
git checkout main && git pull --ff-only 2>/dev/null; git checkout -b feat/slice-3-conc
```

- [ ] **Step 2: Confirm baseline green**

Run: `cabal test`
Expected: all tests pass (the current `main` count, ~763). Record the number; it is the floor for every later task.

---

### Task 1: Conc surface that typechecks (no runtime yet)

**Goal:** The full `Conc` surface — effect, plain-data tokens, transport, and library function signatures — typechecks. Running is deferred (prims may error at runtime; this task asserts types only).

**Files:**
- Modify: `prelude/Std/Control.wok` (append after the `race` definition, ~line 145)
- Test: `test/typecheck-examples/conc-surface.wok`

**Acceptance Criteria:**
- [ ] `runConc`, `spawn`, `async`, `await`, `newChan`, `send`, `recv`, `cancel`, `yield`, `parAll`, `raceAny` all have the signatures below and the module typechecks.
- [ ] `Fiber`, `Promise a`, `Chan a` are plain `data` (NOT `extern type`) — confirmed not carriers (a `Promise a` may be stored in a list).
- [ ] A `typecheck-examples` fixture using the full surface passes.

**Verify:** `cabal test 2>&1 | grep conc-surface` → PASS.

**Steps:**

- [ ] **Step 1: Write the failing typecheck fixture**

Create `test/typecheck-examples/conc-surface.wok`:

```wok
module Main
import Std.Base
import Std.Control

head0 : [a] -> a
head0 xs = case xs of
  h :: _ -> h
  []     -> head0 xs

-- a list of Promises is ordinary data (tokens are NOT carriers): must typecheck
gen : () -> U64 with Conc
gen u = let y = Conc.yield () in 7

useSurface : () -> [U64] with Conc
useSurface u =
  let ps = [async gen] ++ [async gen] in
  [await (head0 ps)]

main : U64
main = runConc (\ () -> let (x, y) = (await (async gen), await (async gen)) in x + y)
```

- [ ] **Step 2: Run to verify it fails**

Run: `cabal test 2>&1 | grep -A2 conc-surface`
Expected: FAIL — `runConc`/`Conc`/`async` unbound (surface not defined yet).

- [ ] **Step 3: Add the surface to `Control.wok`**

Append to `prelude/Std/Control.wok`:

```wok
-- ============ Conc: provider-scheduled concurrency (slice 3, Provider A) ============
-- Handles are PLAIN DATA wrapping a provider id (first-class; the real carriers live in
-- the Haskell scheduler keyed by id). A Fiber is a lightweight cooperatively-scheduled
-- computation (NOT an OS thread).
data Fiber     = Fiber U64
data Promise a = Promise U64        -- `a` PHANTOM: surface type-safety, erased at runtime
data Chan a    = Chan U64           -- `a` PHANTOM

-- Transport: a type-erased value in transit through the Conc transport. Plain data, so
-- first-class and storable in Request; the U64 slot is a label only, gated by erase/recall.
-- `__coerce` is the one trusted runtime-identity retype (soundness rests on the scheduler
-- delivering type-correct values: prim-trust obligation, spec 3.4).
data Transport = Transport U64
extern __coerce : a -> b

erase : a -> Transport
erase v = Transport (__coerce v)

recall : Transport -> a
recall t = case t of Transport n -> __coerce n

recallId : Transport -> U64
recallId t = recall t

-- Request: the transport message. ReqSpawn/ReqAsync carry an ALREADY-ADAPTED coro thunk
-- ERASED into Transport (so the constructor field is plain Transport, not an effectful
-- function type -- which sidesteps the unsupported-effectful-field type-checker gap).
data Request
  = ReqYield
  | ReqSpawn Transport
  | ReqAsync Transport
  | ReqAwait U64
  | ReqNewChan
  | ReqSend U64 Transport
  | ReqRecv U64
  | ReqCancel U64

-- Conc: ONE monomorphic operation. The typed wrappers below recover polymorphism via recall.
effect Conc = { req : Request -> Transport }

-- adapt a Conc computation to the Coro Request Transport transport the driver drives.
asConc : (() -> a with Conc + eff e) -> () -> a with Coro Request Transport + eff e
asConc c _ = with Conc { req r k -> k (Coro.suspend r) } (c ())

-- the driver entry: hand the adapted root coro to the Haskell scheduler (PRDrive hook).
extern __drive_conc : (() -> a with Coro Request Transport + eff e) -> a with eff e

-- runConc: the Provider-A handler for Conc. Discharges Conc, propagates residual e.
runConc : (() -> a with Conc + eff e) -> a with eff e
runConc c = __drive_conc (asConc c)

yield : () -> () with Conc
yield u = let r = Conc.req ReqYield in ()

spawn : (() -> () with Conc) -> Fiber with Conc
spawn f = Fiber (recallId (Conc.req (ReqSpawn (erase (asConc f)))))

async : (() -> a with Conc) -> Promise a with Conc
async f = Promise (recallId (Conc.req (ReqAsync (erase (asConc (\ () -> erase (f ())))))))

await : Promise a -> a with Conc
await p = recall (Conc.req (ReqAwait (promiseId p)))

newChan : () -> Chan a with Conc
newChan u = Chan (recallId (Conc.req ReqNewChan))

send : Chan a -> a -> () with Conc
send c v = let r = Conc.req (ReqSend (chanId c) (erase v)) in ()

recv : Chan a -> a with Conc
recv c = recall (Conc.req (ReqRecv (chanId c)))

cancel : Fiber -> () with Conc
cancel t = let r = Conc.req (ReqCancel (fiberId t)) in ()

-- id extractors (plain pattern matches; no carrier discipline)
fiberId : Fiber -> U64
fiberId t = case t of Fiber n -> n
promiseId : Promise a -> U64
promiseId p = case p of Promise n -> n
chanId : Chan a -> U64
chanId c = case c of Chan n -> n

-- parAll/raceAny: STRUCTURED concurrency as a library over async/await (no new prim).
-- a ranges over effect-free first-order data (payload restriction, Task 2).
parAll : [() -> a with Conc] -> [a] with Conc
parAll fs = mapAwait (mapAsync fs)

mapAsync : [() -> a with Conc] -> [Promise a] with Conc
mapAsync fs = case fs of
  []      -> []
  g :: gs -> [async g] ++ mapAsync gs

mapAwait : [Promise a] -> [a] with Conc
mapAwait ps = case ps of
  []      -> []
  p :: qs -> [await p] ++ mapAwait qs

raceAny : [() -> a with Conc] -> a with Conc
raceAny fs = await (firstReady (mapAsync fs))
-- firstReady: deterministic first-to-fulfil. v1: leftmost (the scheduler runs children
-- to completion in spawn order during drain, so leftmost completes first); refined to
-- true first-ready when the scheduler exposes readiness (Task 7 note).
firstReady : [Promise a] -> Promise a with Conc
firstReady ps = case ps of
  p :: _ -> p
  []     -> firstReady ps
```

- [ ] **Step 4: Run to verify it passes**

Run: `cabal test 2>&1 | grep -A2 conc-surface`
Expected: PASS. Also run the full suite: `cabal test 2>&1 | tail -3` → no regressions (baseline count + new fixtures).

- [ ] **Step 5: Commit**

```bash
git add prelude/Std/Control.wok test/typecheck-examples/conc-surface.wok
git commit -m "feat(conc): Conc surface + plain-data tokens (typecheck only)"
```

---

### Task 2: Payload restriction well-formedness check

**Goal:** Reject `Promise a`/`Chan a` (and `async`/`await`/`send`/`recv`) where `a` is a function type or carries effects — enforcing "effect-free first-order data" (spec 3.3), so no residual can ride a channel.

**Files:**
- Modify: `src/Wok/TypeChecking/Error.hs` (add error variant near `ExternNotAllowed`, ~line 177)
- Modify: `src/Wok/TypeChecking/Infer.hs` (hook after `translateConArg`/type-application resolution, ~lines 984-1026)
- Test: `test/typecheck-fail-examples/conc-payload-fn.wok`, `test/typecheck-fail-examples/conc-payload-effectful.wok`

**Acceptance Criteria:**
- [ ] `Chan (() -> U64)` (or `Promise (() -> U64)`) in any signature → `ConcPayloadEffectful` error with a source span.
- [ ] `Chan U64`, `Promise (List U64)`, `Chan Bool` accepted (first-order data ok).
- [ ] A polymorphic `Promise a` slot in a generic helper is allowed (the check fires on CONCRETE function/effectful instantiation, not on a bare type variable — `parAll`/`mapAwait` must still typecheck).

**Verify:** `cabal test 2>&1 | grep conc-payload` → both fail-fixtures PASS (i.e. produce the expected error), and `conc-surface` still PASS.

**Steps:**

- [ ] **Step 1: Write the failing fixtures**

`test/typecheck-fail-examples/conc-payload-fn.wok`:

```wok
module Main
import Std.Base
import Std.Control

bad : Chan (() -> U64)
bad = newChan ()

main : U64
main = 0
```

`test/typecheck-fail-examples/conc-payload-effectful.wok`:

```wok
module Main
import Std.Base
import Std.Control

bad : () -> Promise (() -> () with Conc) with Conc
bad u = async (fn () -> (fn () -> Conc.yield ()))

main : U64
main = 0
```

Create the expected golden files `test/typecheck-fail-golden/conc-payload-fn.expected` etc. after Step 4 (golden idiom: first run writes them; verify they say `typecheck: ... ConcPayloadEffectful ...`).

- [ ] **Step 2: Run to verify they fail (currently UNEXPECTED SUCCESS)**

Run: `cabal test 2>&1 | grep -A2 conc-payload`
Expected: FAIL with "UNEXPECTED SUCCESS" (the payloads currently typecheck).

- [ ] **Step 3: Add the error variant**

In `src/Wok/TypeChecking/Error.hs`, beside `ExternNotAllowed`:

```haskell
  | ConcPayloadEffectful SourceSpan Text  -- Promise/Chan payload is function-typed or effectful
```

Add a `show`/render arm matching the surrounding style, e.g.:

```haskell
render (ConcPayloadEffectful sp ty) =
  positioned sp ("Promise/Chan payload must be effect-free first-order data, got: " <> ty)
```

- [ ] **Step 4: Add the check in Infer.hs**

Where a type application `TCon name [arg]` is resolved (the same place record/con field kinds are validated, near `translateConArg`), add: when `name` is `Promise` or `Chan`, walk `arg`'s resolved `CType` and reject if it contains a function arrow (`CTArr`/`TArr`) or a non-empty effect row. A bare unresolved type variable is allowed (polymorphic slot). Sketch:

```haskell
checkConcPayload :: SourceSpan -> CType -> TC s ()
checkConcPayload sp t = case t of
  CTArr{}        -> throwError (ConcPayloadEffectful sp (renderCType t))
  CTCon _ args   -> mapM_ (checkConcPayload sp) args   -- nested data ok; recurse into args
  CTVar{}        -> pure ()                              -- polymorphic slot: allowed
  _ | hasEffectRow t -> throwError (ConcPayloadEffectful sp (renderCType t))
    | otherwise      -> pure ()
```

Wire it where `Promise`/`Chan` type-applications are elaborated (guard on the tycon name). `hasEffectRow` walks for any `KEffect`-kinded subterm that is non-empty. Exact insertion point: the type-translation arm that produces `CTCon (TcUser n) args` — add `when (n elem [Promise, Chan]) $ checkConcPayload pos (head args)`.

- [ ] **Step 5: Run to verify the fixtures now error correctly**

Run: `cabal test 2>&1 | grep -A2 conc-payload`
Expected: PASS (each fixture now produces `typecheck: ... ConcPayloadEffectful ...` matching its golden). Confirm `conc-surface` and `parAll`/`mapAwait` still typecheck (polymorphic `Promise a` allowed).

- [ ] **Step 6: Commit**

```bash
git add src/Wok/TypeChecking/Error.hs src/Wok/TypeChecking/Infer.hs test/typecheck-fail-examples/conc-payload-*.wok test/typecheck-fail-golden/conc-payload-*.expected
git commit -m "feat(conc): payload restriction -- Promise/Chan carry effect-free first-order data"
```

---

### Task 3: Coercion prim + the PRDrive hook (scaffolding)

**Goal:** `__coerce` (runtime identity) and the `PRDrive` machine hook compile and are wired, so `runConc` reaches a (stub) `driveConc`. No scheduling logic yet.

**Files:**
- Modify: `src/Wok/Interp/Value.hs` (`PrimResult`, ~line 90)
- Modify: `src/Wok/Interp/Prim.hs` (`prims` list + new prim defs)
- Create: `src/Wok/Interp/Sched.hs` (stub `driveConc`)
- Modify: `src/Wok/Interp/Machine.hs` (`enter` PRDrive arm; import Sched)

**Acceptance Criteria:**
- [ ] `PrimResult` has `PRDrive Value`.
- [ ] `__coerce` is registered and is `PRDone . id` on its single arg.
- [ ] `__drive_conc thunk` produces `PRDrive thunk`; `enter` dispatches it to `Sched.driveConc`.
- [ ] Project compiles; stub `driveConc` returns a `RuntimeError` ("conc: not yet implemented") so the build is green but conc programs fail loudly.

**Verify:** `cabal build` → success; `cabal test 2>&1 | tail -3` → no regressions (no conc run-fixtures yet).

**Steps:**

- [ ] **Step 1: Add `PRDrive` to PrimResult**

In `src/Wok/Interp/Value.hs`:

```haskell
data PrimResult = PRDone Value | PRApply Value [Value] | PRDrive Value
```

- [ ] **Step 2: Add the coercion + drive prims**

In `src/Wok/Interp/Prim.hs`, add to the `prims` list `, coerceP, driveConcP` and define:

```haskell
coerceP :: Prim
coerceP = mkPrim (Tx.pack "__coerce") 1 $ \args -> case args of
  [v] -> Right (PRDone v)                 -- identity: the type is recalled, not stored
  _   -> Left (ArityError (Tx.pack "__coerce"))

driveConcP :: Prim
driveConcP = mkPrim (Tx.pack "__drive_conc") 1 $ \args -> case args of
  [thunk] -> Right (PRDrive thunk)
  _       -> Left (ArityError (Tx.pack "__drive_conc"))
```

- [ ] **Step 3: Stub the scheduler module**

Create `src/Wok/Interp/Sched.hs`:

```haskell
module Wok.Interp.Sched (driveConc) where

import Wok.Interp.Value (PrimTable, Value, RuntimeError (..))
import qualified Data.Text as Tx

-- | Drive a Conc root (an adapted `() -> a with Coro Request Transport` thunk) to its result.
-- Stub: real scheduler lands in Task 4.
driveConc :: PrimTable -> Value -> Either RuntimeError Value
driveConc _ _ = Left (PrimError (Tx.pack "conc: not yet implemented"))
```

Add `Wok.Interp.Sched` to the cabal `other-modules`.

- [ ] **Step 4: Dispatch PRDrive in `enter`**

In `src/Wok/Interp/Machine.hs`, add `import qualified Wok.Interp.Sched as Sched` and extend the `VPrim` branch of `enter` (after the `PRApply` arm, line ~132):

```haskell
          PRDrive thunk   -> do
            v <- Sched.driveConc prims thunk
            if null over then Right (Return v k) else enter prims v over k
```

- [ ] **Step 5: Build + verify no regressions**

Run: `cabal build && cabal test 2>&1 | tail -3`
Expected: builds; all prior tests pass. A conc run-program would now fail with "conc: not yet implemented" (no such fixtures yet).

- [ ] **Step 6: Commit**

```bash
git add src/Wok/Interp/Value.hs src/Wok/Interp/Prim.hs src/Wok/Interp/Sched.hs src/Wok/Interp/Machine.hs *.cabal
git commit -m "feat(conc): PRDrive hook + __coerce prim + Sched stub"
```

---

### Task 4: driveConc core — `yield` + `spawn` + drain (SPIKE)

**Goal:** A deterministic cooperative scheduler that drives the root coro and fire-and-forget `spawn`ed children, interleaving at `yield`, draining all to completion. This is the spike that validates the transport encoding; the `driveConc` body is developed test-first against the goldens below.

**Files:**
- Modify: `src/Wok/Interp/Sched.hs` (real `SchedState` + `driveConc` for `ReqYield`/`ReqSpawn`)
- Create: `test/run-examples/conc-spawn-order.wok` + `test/run-golden/conc-spawn-order.expected`

**Design contract (the spike must satisfy these exactly):**

```haskell
data Cell = Pending [Id] | Full Value          -- a promise/chan cell (Task 5/6)
data SchedState = SchedState
  { ssNext  :: !Int                            -- next fresh id
  , ssReady :: !(Seq (Id, Value))              -- (carrier-id, resume value) FIFO
  , ssCarrier :: !(Map Id Value)               -- id -> parked continuation (a Step's VCont)
  }
```

Scheduling protocol (single-threaded, deterministic FIFO):
- Run a coro segment by entering its carrier with a resume value: `run prims (Eval/Return ...)` via the existing `enter prims carrier [resumeVal] KDone` → loop to `Done step`. `step` is a `VCon "Completed" [v]` or `VCon "Suspended" [request, carrier']`.
- On `Suspended ReqYield carrier'`: push `(thisId, carrier', VLit LUnit)` to the BACK of `ssReady` (round-robin), pop next.
- On `Suspended (ReqSpawn coroThunk) carrier'`: allocate `tid`; `start` the spawned thunk (run it to its first Suspended/Completed); enqueue the spawner's `carrier'` resumed with `Fiber tid` boxed, and enqueue the new child. Return `Fiber`'s id to the spawner.
- On `Completed v`: if this is the ROOT coro, record `v` as the result; if a child, discard (fire-and-forget) — its effects already ran.
- DRAIN: keep popping `ssReady` until empty; then return the recorded root result.

**Acceptance Criteria:**
- [ ] `runConc` of a root that `spawn`s two `yield`ing children produces a deterministic interleave matching the golden.
- [ ] `yield` round-robins (root, child A, child B, root, ...) per the FIFO rule.
- [ ] Children run to completion during drain even though un-awaited (fire-and-forget).

**Verify:** `cabal test 2>&1 | grep conc-spawn-order` → PASS.

**Steps:**

- [ ] **Step 1: Write the failing run fixture**

`test/run-examples/conc-spawn-order.wok` (uses a `Log` effect handled INSIDE each task — children are Conc-closed per spec 3.1; the observable interleave is the order of emitted numbers collected via a shared `Chan`... but Chan is Task 6). For Task 4, observe order via the ROOT collecting child completion through a counter returned by drain. Simplest observable spike: root yields between two spawns, and the program's RESULT encodes the interleave via a tick counter threaded in the resume values:

```wok
module Main
import Std.Base
import Std.Control

-- child increments a shared tick by yielding; result is the final tick count the
-- root observes. (Pure-result observation: no Chan needed for the spike.)
worker : () -> () with Conc
worker u = let _ = Conc.yield () in let _ = Conc.yield () in ()

main : U64
main = runConc (fn () ->
  let _ = spawn worker in
  let _ = spawn worker in
  let _ = Conc.yield () in
  let _ = Conc.yield () in
  42)
```

`test/run-golden/conc-spawn-order.expected`:

```
42
```

(The spike's first golden asserts the program completes and drains without error/hang, returning the root's value. The interleave-ORDER assertion comes via Task 6's Chan fixture, which can record the actual schedule. Keep this spike golden minimal: correct completion + drain.)

- [ ] **Step 2: Run to verify it fails**

Run: `cabal test 2>&1 | grep -A2 conc-spawn-order`
Expected: FAIL — "conc: not yet implemented" (stub).

- [ ] **Step 3: Implement `driveConc` for yield + spawn + drain**

Replace `Sched.hs`'s stub. Use `Control.monad.State.Strict` over `Either RuntimeError`. Key helpers reuse the machine: import `enter`, `run` from `Wok.Interp.Machine` (move them to an exposed module or import the internal one — see note). Algorithm:

```haskell
-- pseudo-to-real: develop against the golden
driveConc prims rootThunk = evalStateT go (SchedState 0 Seq.empty Map.empty)
  where
    go = do
      -- start the root: apply the 0-arg thunk to () and run to first Step
      rootStep <- lift (startCoro prims rootThunk)
      rootRes  <- driveLoop (Root) rootStep
      drainAll
      pure rootRes

    -- step a Step: handle Completed/Suspended(req)
    driveLoop who step = case step of
      VCon "Completed" [v] -> pure v   -- only the root path returns; children handled in drain
      VCon "Suspended" [req, carrier] -> handleReq who req carrier
      _ -> lift (Left (PrimError "conc: malformed Step"))

    handleReq who req carrier = case req of
      VCon "ReqYield" [] -> do
        enqueue carrier VLit_unit          -- round-robin: back of queue
        -- if `who` is Root, we must still eventually return root's result: park root too,
        -- then process queue; root completion recorded when its Completed surfaces in drain.
        ...
      VCon "ReqSpawn" [childThunk] -> do
        tid <- freshId
        childStep <- lift (startCoro prims childThunk)
        enqueueStep childStep              -- child joins the ready set
        resume carrier (boxId tid)         -- spawner continues with Fiber id
      ...
```

NOTE on reusing `run`/`enter`: `startCoro prims thunk` = `enter prims thunk [VLit LUnit] KDone` then `run` to `Done`. Since `Machine` already exports `run`/`enter`, import them. `Step` values are the `VCon "Suspended"/"Completed"` the existing `start` builds. The trickiest part (the spike's purpose) is correctly resuming a parked `carrier` (a `VCont`): `enter prims carrier [resumeVal] KDone` then `run`. Validate the deep-resume re-installs the Coro handler exactly as `__coro_resume` does (it must, since the carrier IS the same VCont `dispatchOp` built).

- [ ] **Step 4: Run to verify it passes**

Run: `cabal test 2>&1 | grep -A2 conc-spawn-order`
Expected: PASS (returns `42`, drains cleanly). Run full suite: no regressions.

- [ ] **Step 5: Commit**

```bash
git add src/Wok/Interp/Sched.hs src/Wok/Interp/Machine.hs test/run-examples/conc-spawn-order.wok test/run-golden/conc-spawn-order.expected
git commit -m "feat(conc): driveConc spike -- yield + spawn + drain (deterministic)"
```

---

### Task 5: async / await / Promise cells

**Goal:** `async` registers a child whose result fills a generational promise cell; `await` blocks the caller on that cell (parking it in `blocked`), resuming when the cell is `Full`. Await-many / fulfil-once (cached).

**Files:**
- Modify: `src/Wok/Interp/Sched.hs` (`ReqAsync`/`ReqAwait`; `Cell`, `ssCells`, `ssBlocked`)
- Create: `test/run-examples/conc-async-await.wok` + `.expected`; `test/run-examples/conc-await-many.wok` + `.expected`

**Acceptance Criteria:**
- [ ] `await (async f)` returns `f`'s result (value crosses as data through the cell).
- [ ] `await` on a not-yet-fulfilled promise parks the caller; the scheduler runs the producer, fulfils the cell, then resumes the waiter (FIFO among waiters).
- [ ] A second `await` on the same promise returns the cached value (fulfil-once).
- [ ] Deadlock (await a promise no live task will fulfil, queue empty) → `RuntimeError "conc: deadlock"`, not a hang.

**Verify:** `cabal test 2>&1 | grep -E 'conc-async-await|conc-await-many'` → PASS.

**Steps:**

- [ ] **Step 1: Write failing fixtures**

`test/run-examples/conc-async-await.wok`:

```wok
module Main
import Std.Base
import Std.Control

compute : () -> U64 with Conc
compute u = let _ = Conc.yield () in 21

main : U64
main = runConc (fn () -> let p = async compute in let q = async compute in await p + await q)
```

`.expected`: `42`

`test/run-examples/conc-await-many.wok`:

```wok
module Main
import Std.Base
import Std.Control

compute : () -> U64 with Conc
compute u = 10

main : U64
main = runConc (fn () -> let p = async compute in await p + await p)
```

`.expected`: `20`  (fulfil-once cached: second await returns 10 again)

- [ ] **Step 2: Run to verify fail**

Run: `cabal test 2>&1 | grep -A2 conc-async-await`
Expected: FAIL — `ReqAsync`/`ReqAwait` unhandled (Sched errors on unknown request).

- [ ] **Step 3: Extend SchedState + handle ReqAsync/ReqAwait**

```haskell
data Cell = Pending !(Seq Id) | Full !Value   -- waiters (parked carrier ids) or the value
-- add to SchedState: ssCells :: !(Map Id Cell)
```

- `ReqAsync childThunk`: `pid <- freshId; insert ssCells pid (Pending empty)`; start the child, tag it so that when it `Completed v` the driver fulfils `pid` (carry the owning `pid` alongside the child carrier in the ready set, e.g. ready entries become `(Id, Maybe PromiseId, Value)` or keep a `Map childId promiseId`). Resume the caller with `boxId pid`.
- Child `Completed v` whose `pid` is known: set `ssCells[pid] = Full v`; move every waiter in the old `Pending` queue to `ssReady` with resume value `v` (boxed).
- `ReqAwait pid`: look up `ssCells[pid]`. `Full v` → resume caller immediately with `boxV v`. `Pending ws` → append caller's carrier id to `ws` (park); do NOT resume now; pop next ready.
- Drain end with non-empty `blocked` and empty `ready` → `Left (PrimError "conc: deadlock")`.

- [ ] **Step 4: Run to verify pass**

Run: `cabal test 2>&1 | grep -E 'conc-async-await|conc-await-many'`
Expected: PASS (`42`, `20`). Full suite green.

- [ ] **Step 5: Commit**

```bash
git add src/Wok/Interp/Sched.hs test/run-examples/conc-async-await.wok test/run-golden/conc-async-await.expected test/run-examples/conc-await-many.wok test/run-golden/conc-await-many.expected
git commit -m "feat(conc): async/await over generational promise cells (fulfil-once)"
```

---

### Task 6: Chan / send / recv

**Goal:** Bounded-by-determinism channels: `newChan` allocates a cell; `send` enqueues a value (waking one parked receiver); `recv` returns the next value or parks. This is the observable-interleave primitive for golden tests.

**Files:**
- Modify: `src/Wok/Interp/Sched.hs` (`ReqNewChan`/`ReqSend`/`ReqRecv`; channel cell = FIFO buffer + receiver waiters)
- Create: `test/run-examples/conc-chan-order.wok` + `.expected`

**Acceptance Criteria:**
- [ ] `send`/`recv` move values FIFO; `recv` on empty parks the caller; `send` wakes the oldest parked receiver.
- [ ] A root spawning two workers that `send` their ids to a shared channel, then `recv`ing twice, observes a DETERMINISTIC order (golden) — this is the interleave-order assertion deferred from Task 4.

**Verify:** `cabal test 2>&1 | grep conc-chan-order` → PASS.

**Steps:**

- [ ] **Step 1: Failing fixture**

`test/run-examples/conc-chan-order.wok`:

```wok
module Main
import Std.Base
import Std.Control

worker : Chan U64 -> U64 -> () -> () with Conc
worker ch tag u = let _ = Conc.yield () in send ch tag

main : U64
main = runConc (fn () ->
  let ch = newChan () in
  let _ = spawn (worker ch 1) in
  let _ = spawn (worker ch 2) in
  let a = recv ch in
  let b = recv ch in
  a * 10 + b)
```

`.expected`: the deterministic result (compute it from the FIFO/round-robin rule; with spawn order [w1,w2] and round-robin, `a=1,b=2` → `12`). Set the golden to the observed value on first correct run and document the schedule in a comment in the fixture.

- [ ] **Step 2: Run to verify fail**

Run: `cabal test 2>&1 | grep -A2 conc-chan-order`
Expected: FAIL — channel requests unhandled.

- [ ] **Step 3: Implement channel cells**

A channel cell: `Chan` id → `(Seq Value, Seq Id)` (buffered values, parked receiver carrier ids). `ReqNewChan` → fresh id, empty cell, return boxed id. `ReqSend cid v`: if a receiver is parked, pop oldest and resume it with `v`; else append `v` to the buffer; resume sender with unit. `ReqRecv cid`: if buffer non-empty, pop oldest, resume caller with it; else park caller in the cell's receiver queue, pop next ready. Reuse the same `freshId`/park/resume helpers as Task 5 (DRY — factor `park`/`wake` if not already).

- [ ] **Step 4: Run to verify pass**

Run: `cabal test 2>&1 | grep conc-chan-order`
Expected: PASS. Full suite green.

- [ ] **Step 5: Commit**

```bash
git add src/Wok/Interp/Sched.hs test/run-examples/conc-chan-order.wok test/run-golden/conc-chan-order.expected
git commit -m "feat(conc): channels (send/recv) with FIFO + parked receivers"
```

---

### Task 7: parAll / raceAny goldens + raceAny refinement

**Goal:** Validate the library combinators end-to-end and make `raceAny` honest (first-to-fulfil, losers dropped).

**Files:**
- Modify: `prelude/Std/Control.wok` (`firstReady`/`raceAny` if refinement needed)
- Create: `test/run-examples/conc-parall.wok` + `.expected`; `test/run-examples/conc-raceany.wok` + `.expected`

**Acceptance Criteria:**
- [ ] `parAll [f1,f2,f3]` returns `[r1,r2,r3]` in spawn order (golden).
- [ ] `raceAny [slow, fast]` returns the fast result; losers are dropped (not awaited) without error.
- [ ] `parAll` typechecks with `a` = first-order data and is rejected (Task 2) for function payloads.

**Verify:** `cabal test 2>&1 | grep -E 'conc-parall|conc-raceany'` → PASS.

**Steps:**

- [ ] **Step 1: Failing fixtures**

`test/run-examples/conc-parall.wok`:

```wok
module Main
import Std.Base
import Std.Control

mk : U64 -> () -> U64 with Conc
mk n u = let _ = Conc.yield () in n

sumL : List U64 -> U64
sumL xs = case xs of Nil -> 0 | Cons h t -> h + sumL t

main : U64
main = runConc (fn () -> sumL (parAll (Cons (mk 1) (Cons (mk 2) (Cons (mk 3) Nil)))))
```

`.expected`: `6`

`test/run-examples/conc-raceany.wok`:

```wok
module Main
import Std.Base
import Std.Control

fast : () -> U64 with Conc
fast u = 100

slow : () -> U64 with Conc
slow u = let _ = Conc.yield () in let _ = Conc.yield () in 200

main : U64
main = runConc (fn () -> raceAny (Cons fast (Cons slow Nil)))
```

`.expected`: `100`

- [ ] **Step 2: Run to verify fail / observe behavior**

Run: `cabal test 2>&1 | grep -E 'conc-parall|conc-raceany'`
Expected: `conc-parall` likely PASSes already (built on async/await). `conc-raceany` may return the wrong value if `firstReady` is naive — that drives the refinement.

- [ ] **Step 3: Refine raceAny if needed**

If `firstReady` (leftmost) does not match "first to fulfil", change `raceAny` to poll cell readiness via a new `Conc` query, OR accept the documented deterministic rule (leftmost-that-completes-first under the FIFO schedule) and set the golden accordingly. Prefer the simplest correct rule; document it in the fixture comment. Drop losers by simply not awaiting them (the scheduler drains them during teardown — confirm drain does not error on an un-awaited promise whose waiter never came).

- [ ] **Step 4: Run to verify pass**

Run: `cabal test 2>&1 | grep -E 'conc-parall|conc-raceany'`
Expected: PASS. Full suite green.

- [ ] **Step 5: Commit**

```bash
git add prelude/Std/Control.wok test/run-examples/conc-parall.wok test/run-golden/conc-parall.expected test/run-examples/conc-raceany.wok test/run-golden/conc-raceany.expected
git commit -m "feat(conc): parAll/raceAny library combinators + goldens"
```

---

### Task 8: Full-branch review + finish

**Goal:** The branch is correct, consistent with the spec, and ready to merge (after the required full-branch review per project policy).

**Files:** none (review + any fixes surfaced).

**Acceptance Criteria:**
- [ ] `cabal test` fully green; conc fixtures all pass.
- [ ] A `typecheck-fail` fixture proves `spawn` of a child performing an UNHANDLED user effect is rejected (the spec 3.1 pin): `spawn (fn () -> Log.emit 1)` with `Log` unhandled → unhandled-effect. (Add `test/typecheck-fail-examples/conc-spawn-unclosed.wok` if not already covered.)
- [ ] Spec cross-check: tokens are plain data (3.2); payload restriction enforced (3.3); `Conc` neutral / no determinism marker (5); drain-to-completion + deadlock-errors (9.1); await-many/fulfil-once (9.3).
- [ ] Full-branch `/code-review` run; findings triaged.

**Verify:** `cabal test 2>&1 | tail -3` → all green; review complete.

**Steps:**

- [ ] **Step 1: Add the spawn-closure fail fixture**

`test/typecheck-fail-examples/conc-spawn-unclosed.wok`:

```wok
module Main
import Std.Base
import Std.Control

effect Log = { emit : U64 -> () }

bad : () -> Fiber with Conc
bad u = spawn (fn () -> Log.emit 1)   -- Log unhandled in child -> rejected (spec 3.1 pin)

main : U64
main = 0
```

Run: `cabal test 2>&1 | grep conc-spawn-unclosed` → PASS (produces an unhandled-effect / row-mismatch error; record its golden).

- [ ] **Step 2: Full suite + review**

Run: `cabal test`
Expected: all green.
Then run a full-branch review (`/code-review` high or `/code-review ultra`) and triage findings. Per project policy, a full-branch review is required before merge to `main`.

- [ ] **Step 3: Commit any review fixes**

```bash
git add -A && git commit -m "fix(conc): address full-branch review findings"
```

---

## Self-Review

**Spec coverage:**
- 2 (surface: Conc, tokens, ops) → Task 1. 3.1 (spawn pin) → Task 8 fixture. 3.2 (plain-data tokens) → Task 1. 3.3 (payload restriction) → Task 2. 3.4 (prim-trust / Transport) → Tasks 1+3 (the `__coerce` seam). 4 (interpreter scheduler) → Tasks 3-6. 5 (determinism / neutral Conc) → deterministic goldens throughout. 6 (parAll/raceAny library) → Task 7. 7 shipped list → all tasks. 9 OQ#1 drain → Task 4/5; OQ#3 fulfil-once → Task 5; OQ#6 phantom param → Task 1 (the `Promise a` decl is the fixture); OQ#7 payload enforcement → Task 2. GAP: OQ#2 (Conc vs Async) is a no-op decision (kept distinct) — no task needed.
- Provider B (FFI) and Provider C (carriers) are explicitly out of scope (spec 7) — correctly no tasks.

**Placeholder scan:** Tasks 0-3, 8 contain complete code. Tasks 4-6 contain a precise design contract (SchedState, request protocol, drain rule) + complete tests + a code sketch for `driveConc`; the body is spike-developed against the goldens — this is the one genuinely research-y unit and is structured as a spike (the project's accepted pattern for novel drivers, cf. slice-1 Task 1). The sketch names every helper and every request arm; no "TODO"/"handle edge cases" placeholders.

**Type consistency:** `Request` constructors (`ReqYield`/`ReqSpawn`/`ReqAsync`/`ReqAwait`/`ReqNewChan`/`ReqSend`/`ReqRecv`/`ReqCancel`) are identical across Control.wok (Task 1) and Sched.hs (Tasks 4-6). `Transport`/`__coerce`/`erase`/`recall` consistent. `Promise`/`Chan`/`Fiber` id extractors (`promiseId`/`chanId`/`fiberId`) and `recallId` defined once (Task 1). `PRDrive` added once (Task 3) and consumed once (Task 3 enter). `Cell` introduced in Task 5, extended (not redefined) in Task 6.

**Known risk (flagged honestly):** the spike (Task 4) must confirm that re-entering a parked `VCont` via `enter prims carrier [v] KDone` re-installs the Coro handler identically to `__coro_resume` (it should — same VCont). If the deep-resume/answer-join interaction misbehaves for the multi-carrier case, the fallback is a dedicated `__sched_step` prim that performs the resume inside the machine (same surface, different plumbing). This contingency is the spike's go/no-go.
