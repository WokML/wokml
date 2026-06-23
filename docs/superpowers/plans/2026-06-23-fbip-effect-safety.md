# FBIP effect-safety (E+ lazy reclaim) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers-extended-cc:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close the FBIP S2 residual — a reuse token spanning an effectful call under an aborting handler leaks its reserved shell — by reclaiming in-flight reservations when a continuation is discarded (E+ lazy reclaim).

**Architecture:** A `stReserved` set in the `Store` tracks in-flight reservation addresses (insert at `drop_reuse`, remove at `alloc_at`). When an `NCont` is dropped (a handler discards a continuation — "abort", a normal mid-run event, NOT program termination), the runtime frees the in-flight reservations trapped in its prefix, via a `continuationReservations` collector (sibling of the existing `continuationOwned`) and a `freeReservation` special-free. Resume and the pairing are untouched, so reuse survives a resume.

**Tech Stack:** Haskell (`src/Wok/Interp/RC/Value.hs`), the C arena (no C change this slice), tasty test-suite `wok-tests`, the differential oracle (`runBothBackends`).

**Spec:** `docs/superpowers/specs/2026-06-23-fbip-effect-safety-design.md` (read its Terminology section + §3–5).

**User decisions (already made):**
- **E+ (lazy reclaim)**, not B (counted cell) — "E+ is good". B deferred (its C-heap reserved marker is the cost; E+ avoids the value-model change).
- `stReserved` set is accepted (needed to distinguish in-flight reservations from spent tokens lingering in an env).
- The `ROp`-refusal stays this slice (relaxing it is a deferred pure-win follow-on E+ enables).
- "abort" = a handler not resuming a captured continuation (mid-run), explicitly not program shutdown.

**Verify (whole suite):** `cabal test wok-tests` → green (baseline 1312). Per group: `cabal test wok-tests --test-options='-p "<pattern>"'`.

---

### Task 1: `stReserved` set + hot-path updates

**Goal:** Add the in-flight reservation set to the `Store` and maintain it in `dropReuse` (insert) and `allocAt` (remove on every consume path), with store-algebra unit tests. (Spec §3.1.)

**Files:**
- Modify: `src/Wok/Interp/RC/Value.hs` (`stReserved :: Set Addr` field on `Store`; `emptyStore`; the inserts/deletes in `dropReuse`/`allocAt`; export nothing new — `stReserved` is an internal field but the `Store` record is already exported).
- Test: `test/Spec.hs` (a `rc-reserved` group near `wokRcReuseTests`).

**Acceptance Criteria:**
- [ ] `Store` has `stReserved :: Set Addr`; `emptyStore` initializes it to `Set.empty`.
- [ ] `dropReuse` on a unique cell (`HAddr` AND `CAddr` reserve paths) inserts the reserved `rsAddr` into `stReserved`; `rc>1` / `Inline` / static do NOT.
- [ ] `allocAt` consuming a `Just` token removes `rsAddr` from `stReserved` on BOTH the reuse re-stamp path AND the not-eligible free+fresh path; `RVReuse Nothing` does not touch it.
- [ ] After a reuse pair (`dropReuse` then `allocAt` reuse), `stReserved` is back to its prior value (insert then delete). After a `dropReuse` with no consume, the address remains in `stReserved`.

**Verify:** `cabal test wok-tests --test-options='-p "rc-reserved"'` → PASS; `cabal build lib:wok` clean.

**Steps:**

- [ ] **Step 1: Failing tests** in `test/Spec.hs` (`rc-reserved` group): (a) reserve inserts; (b) reuse consume removes (net empty); (c) not-eligible consume removes; (d) shared `rc>1` does not insert. Build cells with `St.allocPure`/`St.emptyStore`; run `dropReuse`/`allocAt` via `runExceptT`; assert `Set.member`/`Set.notMember` on `St.stReserved`.

```haskell
wokRcReservedTests :: TestTree
wokRcReservedTests = testGroup "rc-reserved"
  [ testCase "drop_reuse reserves; alloc_at reuse releases (net empty)" $ do
      let s0 = St.initSentinel St.emptyStore
          (nil, s1)  = St.allocPure (St.NCon (T.pack "Nil") []) s0
          (cons, s2) = St.allocPure (St.NCon (T.pack "Cons") [St.RVLit (St.LInt 1), St.RVBox nil]) s1
      Right (tok, s3) <- runExceptT (St.dropReuse cons s2)
      Set.member cons (St.stReserved s3) @? "reserved after drop_reuse"
      Right (_, s4) <- runExceptT (St.allocAt tok (St.NCon (T.pack "Cons") [St.RVLit (St.LInt 2), St.RVBox nil]) s3)
      Set.notMember cons (St.stReserved s4) @? "released after alloc_at reuse"
  -- ... (c) not-eligible release, (d) shared no-insert
  ]
```
Register it beside `wokRcReuseTests`.

- [ ] **Step 2: Run, expect FAIL** (`stReserved` undefined).
- [ ] **Step 3: Implement** in `Value.hs`: add `, stReserved :: Set Addr` to `data Store`; add `, stReserved = Set.empty` to `emptyStore`; in `dropReuse`'s `HAddr rc==1` and `CAddr rc==0` reserve branches add `stReserved = Set.insert (HAddr i / CAddr p) (stReserved …)`; in `allocAt`'s reuse branch and not-eligible branch add `stReserved = Set.delete a (stReserved …)` (where `a = rsAddr`). (`Data.Set` is already imported as `Set`.)
- [ ] **Step 4: Run, expect PASS**; `cabal build lib:wok`.
- [ ] **Step 5: Commit** — `git commit -am "feat(rc): stReserved in-flight reservation set + hot-path updates (effect-safety T1)"`

---

### Task 2: `continuationReservations` + `freeReservation` + the abort reclaim

**Goal:** Reclaim the in-flight reservations trapped in a discarded continuation when its `NCont` is dropped, with a collector unit test and a hand-built reclaim test. (Spec §3.2–§3.4.)

**Files:**
- Modify: `src/Wok/Interp/RC/Value.hs` (`continuationReservations`, `freeReservation`, `reclaimIfNCont`, wired into the IO `dropAddr` `HAddr` branch; export `continuationReservations` for the test).
- Test: `test/Spec.hs` (`rc-reclaim` group).

**Acceptance Criteria:**
- [ ] `continuationReservations :: RCKont -> Set Addr -> [Addr]` walks `KLetRC`/`KHandleRC` scope envs and `KAppRC` values, collecting `RVReuse (Just (ReuseSlot a _ _))` where `a ∈ stReserved`, deduped. A spent token (`a ∉ stReserved`) is excluded.
- [ ] `freeReservation` frees a reserved shell: `HAddr i` → `stDead` insert + `recordFree` + `stReserved` delete (loud if already dead); `CAddr p` → `wok_free` + `recordFree` + `stReserved` delete.
- [ ] When an `NCont` cell is dropped (rc→0), `dropAddr` reclaims `continuationReservations` of its prefix BEFORE/with the owned-set cascade — the reserved shells are freed exactly once.
- [ ] Hand-built: an `NCont` whose prefix holds an in-flight reservation, when dropped, frees that shell (`stLive` returns to baseline; the address ends in `stDead`); a prefix holding a SPENT token (address not in `stReserved`) frees nothing extra.

**Verify:** `cabal test wok-tests --test-options='-p "rc-reclaim"'` → PASS; full `cabal test wok-tests` → no regression (1312 baseline).

**Steps:**

- [ ] **Step 1: Failing tests** (`rc-reclaim`): (a) `continuationReservations` over a hand-built prefix returns the in-flight addr, excludes the spent one, dedups; (b) dropping an `NCont` holding an in-flight reservation reclaims it (`stLive` baseline, addr in `stDead`); (c) dropping an `NCont` holding only a spent token reclaims nothing.

```haskell
-- (a) collector: build a KLetRC frame whose scope env has an in-flight token + a spent token
let inflight = St.HAddr 7; spent = St.HAddr 9
    sc = St.emptyRCScope { St.rscEnv = Map.fromList
           [ (u1, St.RVReuse (Just (St.ReuseSlot inflight 2 True)))
           , (u2, St.RVReuse (Just (St.ReuseSlot spent 2 True))) ] }
    prefix = St.KLetRC b (Ret (AVar n)) sc St.KDoneRC
    reserved = Set.fromList [inflight]   -- only inflight is reserved
St.continuationReservations prefix reserved @?= [inflight]
```

- [ ] **Step 2: Run, expect FAIL.**
- [ ] **Step 3: Implement** in `Value.hs`:

```haskell
continuationReservations :: RCKont -> Set Addr -> [Addr]
continuationReservations k reserved = Set.toList (Set.fromList (go k))
  where
    go KDoneRC                = []
    go (KLetRC _ _ sc k')     = vals (Map.elems (rscEnv sc)) ++ go k'
    go (KAppRC vs k')         = vals vs ++ go k'
    go (KHandleRC _ _ sc k')  = vals (Map.elems (rscEnv sc)) ++ go k'
    go (KDropCellRC _ k')     = go k'
    vals vs = [ a | RVReuse (Just (ReuseSlot a _ _)) <- vs, a `Set.member` reserved ]

freeReservation :: Addr -> Store -> RC Store
freeReservation a@(HAddr i) s
  | IS.member i (stDead s) = liftRC (Left (PrimError (Tx.pack ("freeReservation: double-reclaim of addr " <> show i))))
  | otherwise = pure s { stDead = IS.insert i (stDead s), stStats = recordFree (stStats s)
                       , stReserved = Set.delete a (stReserved s) }
freeReservation a@(CAddr p) s = do
  hp <- heapPtr s
  liftIO (H.wokFree hp p)
  pure (bumpFreeStats s) { stReserved = Set.delete a (stReserved s) }
freeReservation (Inline _) s = pure s

-- reclaim in-flight reservations when an NCont cell is about to be freed.
reclaimIfNCont :: Addr -> Store -> RC Store
reclaimIfNCont (HAddr i) s
  | not (IS.member i (stDead s))
  , Just (Cell rc (NCont prefix _)) <- IM.lookup i (stCells s)
  , rc <= 1
  = foldM (flip freeReservation) s (continuationReservations prefix (stReserved s))
reclaimIfNCont _ s = pure s
```

In the IO `dropAddr` `go (a@(HAddr _) : rest) s` branch, call `reclaimIfNCont a s` first:
```haskell
    go (a@(HAddr _) : rest) s = do
      s0 <- reclaimIfNCont a s
      (mkids, s') <- liftRC (dropAddrStepPure a s0)
      case mkids of
        Nothing   -> go rest s'
        Just kids -> go (kids ++ rest) s'
```
Export `continuationReservations` (and `freeReservation` if the test needs it). Add `foldM` import (`Control.Monad`) if absent.

- [ ] **Step 4: Run, expect PASS**; full suite no regression.
- [ ] **Step 5: Commit** — `git commit -am "feat(rc): reclaim FBIP reservations on continuation abort (effect-safety T2)"`

---

### Task 3: End-to-end effect-safety tests (abort = no leak; resume = reuse survives)

**Goal:** Prove E+ end-to-end on the differential oracle: an effectful map under an aborting handler does not leak, and under a resuming handler still reuses. (Spec §7.)

**Files:**
- Modify: `test/Spec.hs` (`rc-effect-safety` group).
- Create (if expressible): `test/rc-c-backend/fbip-effect-abort.wok`, `fbip-effect-resume.wok`.

**Acceptance Criteria:**
- [ ] **De-risk first:** confirm an effectful map under a handler reaches the RC interpreter AND the pairing fires on its `Cons` rebuild (dump `prettyPerceus (reusePairing (insertRC cm))` — the `Cons` shows `__rc_drop_reuse`/`@tok`, with the effectful `f x` `RApp` between). Report the result.
- [ ] **Abort = no leak:** the effectful map under an aborting handler runs with no crash; `stLive` returns to baseline (no leak); abstract stats == C stats. (This FAILS before T2.)
- [ ] **Resume = reuse survives:** the same map under a resuming handler still collapses the spine alloc count (reuse fires), output correct, abstract == C.
- [ ] If the shape is NOT expressible end-to-end, fall back to expanded hand-built `NCont`-reclaim coverage in T2's style and DOCUMENT the gap; the abort/resume *semantics* must still be asserted at the unit level.

**Verify:** `cabal test wok-tests --test-options='-p "rc-effect-safety"'` and `-p "rc-c-backend"` → PASS; full `cabal test wok-tests` → green.

**Steps:**

- [ ] **Step 1: De-risk** — write a minimal effectful-map `.wok` (a separate effectful function `f`, `map f xs` under a handler) OR hand-built `CoreModule`; run through `reusePairing . insertRC`; confirm the `Cons` rewrites and the program runs on both backends. Paste the lowered IR + the two-backend result. If it does not reach the fragment / pair, STOP and report DONE_WITH_CONCERNS with the lowered IR, then proceed with the hand-built fallback.
- [ ] **Step 2: Abort test** — run the aborting-handler program; assert no crash, `stLive` baseline (the reclaim fired), abstract==C. Mirror the `runBothBackends`/`rcFbip*` idiom from the FBIP T5 tests.
- [ ] **Step 3: Resume test** — run the resuming-handler program; assert reuse fires (alloc count collapses vs a non-FBIP baseline run, as in FBIP T5's `rcFbipFused`/`rcFbipNonFused`), output correct, abstract==C.
- [ ] **Step 4: Run** the groups + full suite; fix any real issue.
- [ ] **Step 5: Commit** — `git commit -am "test(rc): FBIP effect-safety abort/resume differential tests (effect-safety T3)"`

---

### Task 4: Docs

**Goal:** Mark the residual CLOSED. (Spec §6.)

**Files:**
- Modify: `docs/superpowers/specs/2026-06-23-fbip-reuse-design.md` (§2 / §11-finding: the effectful-abort residual is now CLOSED by the E+ slice; reference the effect-safety spec).
- Modify: `docs/superpowers/runtime-knowledge-base.md` (FBIP entry: effect-safety residual CLOSED via E+ lazy reclaim).
- Modify: `docs/superpowers/specs/2026-06-23-fbip-effect-safety-design.md` (Status → IMPLEMENTED on feat/fbip-reuse-s2).

**Acceptance Criteria:**
- [ ] The FBIP S2 spec + KB no longer describe the effectful-abort leak as open; they point at the E+ slice.
- [ ] The effect-safety spec Status is IMPLEMENTED.

**Verify:** `cabal test wok-tests` still green; docs read consistently.

**Steps:**
- [ ] **Step 1** — edit the three docs.
- [ ] **Step 2: Commit** — `git commit -am "docs(rc): record FBIP effect-safety (E+) as implemented (effect-safety T4)"`

---

## Self-review
- **Spec coverage:** §3.1→T1, §3.2/§3.3/§3.4→T2, §3.5 (resume unchanged)→no-op verified by T3 resume test, §4 soundness→T2/T3 tests, §5 oracle→T3 abstract==C, §7 testing→T2 (unit) + T3 (e2e), §6 docs→T4. No gap.
- **Placeholders:** none — every step names files, real code, and a `cabal test … -p` command.
- **Type consistency:** `stReserved :: Set Addr` (T1) used in `continuationReservations`/`freeReservation`/`reclaimIfNCont` (T2); `ReuseSlot`/`RVReuse`/`NCont`/`continuationOwned` are the existing FBIP S2 symbols.

## Dependencies
- T2 blockedBy T1 · T3 blockedBy T2 · T4 blockedBy T3.
