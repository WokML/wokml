# FBIP Slice 1 (S2) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers-extended-cc:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement Koka-style in-place reuse (`drop_reuse` → `alloc_at`) for the single-path shapes `map` and `reverse` on the RC interpreter, so the spine allocation count collapses to ~0 with output and cross-backend stats unchanged.

**Architecture:** A first-class affine reuse token (`RVReuse`) produced by a `drop_reuse` runtime op and consumed by an `alloc_at` op, on both heaps (abstract `IntMap` index-recycle / C pointer re-stamp). The pairing is a **post-pass** (`reusePairing`) over `insertRC` output that rewrites a `Case`-matched parent-drop + a dominated slot-kind-compatible `RCon` into `__rc_drop_reuse` + `RReuseCon`. Reuse is gated at runtime by `rc == 1`.

**Tech Stack:** Haskell (GHC, the RC interpreter under `src/Wok/Interp/RC/` + `src/Wok/IR/`), C (`runtime/wok_rc.{c,h}`), tasty + Hspec test-suite `wok-tests`, the differential oracle (`runBothBackends`).

**Spec:** `docs/superpowers/specs/2026-06-23-fbip-reuse-design.md` (the precise contract — every task cites its sections).

**User decisions (already made):**
- Scope = **S2** (map + reverse); filter/conditional-reuse, tree-rebalance, static rc-elision, cross-arity reuse all deferred.
- Pairing is a **post-pass** after `insertRC` ("auditable and less invasive; the interpreter is the gold-standard reference until dogfooding").
- Strings stay non-encodable abstract literals (future Array-like String is a separate track); the slot-kind guard refuses to pair across the string boundary.
- Runtime `rc == 1` gate is the MVP; static specialization deferred.

**Verify (whole suite):** `cabal test wok-tests` → all green (baseline 1282). Per-group: `cabal test wok-tests --test-options='-p "<pattern>"'`.

---

### Task 1: Runtime — reuse token + abstract-heap `drop_reuse`/`alloc_at`

**Goal:** Add the `RVReuse`/`ReuseSlot` value, the value-only `nodeCEligible`, and `dropReuse`/`allocAt` handling the abstract (`HAddr`) and `Inline`/static cases, with store-algebra unit tests. (Spec §4.1–§4.4.)

**Files:**
- Modify: `src/Wok/Interp/RC/Value.hs` (add `RVReuse` to `RCValue`; `ReuseSlot`; `nodeCEligible`; `dropReuse`; `allocAt`; export them; `valueChildren (RVReuse _) = []`).
- Test: `test/Spec.hs` (a new `wokRcReuseTests` group near the other store-algebra unit groups, e.g. beside `wokRcHeapTests`).

**Acceptance Criteria:**
- [ ] `RVReuse (Maybe ReuseSlot)` constructor exists; `valueChildren (RVReuse _) = []`; `incref`/`dropAddr` treat it inertly (no counted child).
- [ ] `nodeCEligible :: Node -> Bool` returns `True` iff `arity ≤ 255 && all (isJust . encodeSlotC) fields` for an `NCon` (value-only — no `Store`, no descriptor, no tag check); `False`/irrelevant for non-`NCon`.
- [ ] `dropReuse` on a unique (`rc==1`) abstract `NCon` cell returns `RVReuse (Just slot)` with the children released and the index removed from `stCells` but NOT in `stDead` and NO `recordFree`; on `rc>1` decrements and returns `RVReuse Nothing`; on `Inline`/static returns `RVReuse Nothing`.
- [ ] `allocAt (RVReuse Nothing) n` == `alloc n` (fresh, `recordAlloc`); `allocAt (RVReuse (Just slot)) n` with arity+eligibility match writes `Cell 1 n` at `rsAddr`'s `HAddr i` with NO `recordAlloc`; on mismatch frees the shell (`stDead` + `recordFree`) and `alloc`s fresh.
- [ ] A reuse pair nets to 0 allocs / 0 frees in `stStats`; a shared (`rc>1`) drop + fresh alloc nets identically to the pre-FBIP path.

**Verify:** `cabal test wok-tests --test-options='-p "rc-reuse"'` → PASS.

**Steps:**

- [ ] **Step 1: Failing tests** — add `wokRcReuseTests` to `test/Spec.hs` and register it in the RC test list (beside `wokRcHeapTests` at ~line 201). Cover: (a) unique reuse nets 0/0; (b) shared `rc>1` → `RVReuse Nothing` + fresh alloc; (c) not-eligible (token arity/eligibility mismatch) → free + fresh, net 1/1; (d) `valueChildren (RVReuse _) == []`.

```haskell
-- in test/Spec.hs, near wokRcHeapTests
wokRcReuseTests :: TestTree
wokRcReuseTests = testGroup "rc-reuse"
  [ testCase "unique cons reuse nets 0 alloc / 0 free" $ do
      -- build  Cons 1 Nil  at rc 1 on the abstract heap
      let s0 = St.initSentinel St.emptyStore
          (nil, s1)  = St.allocPure (St.NCon (T.pack "Nil") []) s0   -- or Inline; use allocPure for a cell
          (cons, s2) = St.allocPure (St.NCon (T.pack "Cons") [St.RVLit (St.LInt 1), St.RVBox nil]) s1
          a0 = St.stAllocs (St.stStats s2)
      -- dropReuse the unique cons, then allocAt a new Cons of the same shape
      Right (tok, s3) <- runExceptT (St.dropReuse cons s2)
      Right (cons', s4) <- runExceptT
        (St.allocAt tok (St.NCon (T.pack "Cons") [St.RVLit (St.LInt 2), St.RVBox nil]) s3)
      St.stAllocs (St.stStats s4) @?= a0          -- no new alloc recorded
      St.stFrees  (St.stStats s4) @?= St.stFrees (St.stStats s2)  -- no free recorded
      cons' @?= cons                              -- same index reused
  -- ... (b) shared, (c) not-eligible, (d) valueChildren
  ]
```

- [ ] **Step 2: Run, expect FAIL** — `cabal test wok-tests --test-options='-p "rc-reuse"'` → fails to compile (`RVReuse`/`dropReuse`/`allocAt` undefined).

- [ ] **Step 3: Implement in `Value.hs`.** Add to `RCValue`:

```haskell
  | RVReuse (Maybe ReuseSlot)     -- affine in-place-reuse ticket

data ReuseSlot = ReuseSlot { rsAddr :: Addr, rsArity :: Word32, rsCEligible :: Bool }
  deriving (Eq, Show)
```

`valueChildren (RVReuse _) = []`. Add the value-only predicate and the two ops (mirror `dropAddr`'s `HAddr` rc≤1 branch, minus the shell free; mirror `allocPure`):

```haskell
nodeCEligible :: Node -> Bool
nodeCEligible (NCon _ vs) = length vs <= 255 && all (isJust . encodeSlotC) vs
nodeCEligible _           = False

dropReuse :: Addr -> Store -> RC (RCValue, Store)        -- returns an RVReuse
allocAt   :: RCValue -> Node -> Store -> RC (Addr, Store) -- consumes an RVReuse
```

Implement the `HAddr`/`Inline`/static arms per spec §4.2/§4.3 (the `CAddr` arms are Task 2 — for now route a `CAddr` token/addr to an internal-error `Left`, since the abstract backend never produces one). Export `RVReuse`, `ReuseSlot(..)`, `nodeCEligible`, `dropReuse`, `allocAt`.

- [ ] **Step 4: Run, expect PASS** — `cabal test wok-tests --test-options='-p "rc-reuse"'`. Then `cabal build` to confirm no break.

- [ ] **Step 5: Commit** — `git add src/Wok/Interp/RC/Value.hs test/Spec.hs && git commit -m "feat(rc): reuse token + abstract-heap drop_reuse/alloc_at (FBIP T1)"`

---

### Task 2: Runtime — C arena `wok_alloc_at` + `CAddr` reuse paths

**Goal:** Add the in-place re-stamp on the C arena and the `CAddr` arms of `dropReuse`/`allocAt`, with an additive `wok_stat_reused_inplace` counter, a standalone C test, and a sanitizer (UAF) check under `WOK_RC_MALLOC`. (Spec §4.2–§4.4, §13 task 2.)

**Files:**
- Modify: `runtime/wok_rc.h` (declare `wok_alloc_at`, `wok_stat_reused_inplace`).
- Modify: `runtime/wok_rc.c` (define `wok_alloc_at` for both backends; add the `reused_inplace` field to the arena `WokHeap` + accessor; MALLOC backend accessor returns 0).
- Modify: `src/Wok/Interp/RC/Heap.hs` (FFI binding for `wokAllocAt`).
- Modify: `src/Wok/Interp/RC/Value.hs` (`CAddr` arms of `dropReuse`/`allocAt`).
- Test: the standalone C harness used by the arena slice (find it: `grep -rl wok_alloc runtime/ test/`); add a reuse round-trip + a no-double-free assertion.

**Acceptance Criteria:**
- [ ] `wok_alloc_at(h, p, tag, arity)` asserts `p->arity == arity`, re-stamps `rc=1, tag, arity, scan=0`, bumps `reused_inplace` (NOT `allocs`/`live`/`peak`/`cur_bytes`), returns `p`.
- [ ] `dropReuse` on a unique `CAddr` decodes children, does NOT `wokFree`, does NOT `bumpFreeStats`, returns `RVReuse (Just (ReuseSlot (CAddr p) arity True))`; on `rc>1` decrements (`wokDec`) → `RVReuse Nothing`.
- [ ] `allocAt (RVReuse (Just slot)) n` with a `CAddr` slot + match re-stamps via `wok_alloc_at`, no `recordAlloc`; on mismatch `wokFree`s + `bumpFreeStats` + fresh `alloc`.
- [ ] Standalone C test: drop_reuse a cell, alloc_at into it, read back the new slots correctly; `wok_stat_allocs` unchanged across the pair; heap frees clean (no leak at `wok_heap_free`).
- [ ] `WOK_RC_MALLOC` + ASan build of the C test is clean (no UAF/leak).

**Verify:** `cabal test wok-tests --test-options='-p "rc-c-backend"'` → PASS, and the standalone C test (its existing make/clang invocation) → exit 0 under both default and `-DWOK_RC_MALLOC -fsanitize=address`.

**Steps:**

- [ ] **Step 1: C test first** — extend the standalone arena C test with a reuse round-trip:

```c
/* reserve-then-reuse: dec to 0 WITHOUT free, then alloc_at back into the same block */
WokObj* p = wok_alloc(h, TAG_CONS, 2);
wok_slot_set(p, 0, 11); wok_slot_set(p, 1, 22);
uint64_t a0 = wok_stat_allocs(h);
assert(wok_dec(p) == 0);            /* drop_reuse: children handled by caller; do NOT wok_free */
WokObj* q = wok_alloc_at(h, p, TAG_CONS, 2);
assert(q == p);
assert(wok_stat_allocs(h) == a0);   /* reuse records no alloc */
wok_slot_set(q, 0, 33);
assert(wok_slot_get(q, 0) == 33 && wok_tag(q) == TAG_CONS);
assert(wok_dec(q) == 0); wok_free(h, q);   /* clean teardown */
```

- [ ] **Step 2: Run, expect FAIL** (link error: `wok_alloc_at` undefined).

- [ ] **Step 3: Implement C.** In `wok_rc.h` add `WokObj* wok_alloc_at(WokHeap* h, WokObj* p, uint32_t tag, uint32_t arity);` and `WOK_PURE uint64_t wok_stat_reused_inplace(const WokHeap* h);`. In `wok_rc.c` (both backends):

```c
WokObj* wok_alloc_at(WokHeap* h, WokObj* p, uint32_t tag, uint32_t arity) {
    assert(tag < 65536u && arity < 256u);
    assert((uint32_t)p->arity == arity);  /* slot-kind guard makes this a real invariant */
    p->rc = 1u; p->tag = (uint16_t)tag; p->arity = (uint8_t)arity; p->scan = 0u;
    h->reused_inplace += 1u;              /* NOT allocs/live/peak/cur_bytes */
    return p;
}
```

Add `uint64_t reused_inplace;` to the arena `struct WokHeap` (and the MALLOC one for layout parity — accessor returns it there too, or 0 by spec choice; keep both backends compilable). Add the accessor.

- [ ] **Step 4: Haskell FFI** — in `src/Wok/Interp/RC/Heap.hs` bind `wokAllocAt :: Ptr WokHeap -> Word32 -> Word32 -> Ptr WokObj -> IO (Ptr WokObj)` (mirror `wokAlloc`). Implement the `CAddr` arms of `dropReuse`/`allocAt` in `Value.hs` per spec §4.2/§4.3 (drop_reuse: `wokDec`; on 0 decode children, skip `wokFree`/`bumpFreeStats`, return token; alloc_at: re-stamp via `wokAllocAt` + `wokSlotSet`, no `recordAlloc`; mismatch → `wokFree` + `bumpFreeStats` + `alloc`).

- [ ] **Step 5: Run** the C test (default + ASan/MALLOC) and `cabal test wok-tests --test-options='-p "rc-c-backend"'` → PASS.

- [ ] **Step 6: Commit** — `git commit -am "feat(rc): C arena wok_alloc_at + CAddr reuse paths (FBIP T2)"`

---

### Task 3: IR — `RReuseCon` + `__rc_drop_reuse` + machine + prim

**Goal:** Add the two IR forms the post-pass emits and make the interpreter execute them. (Spec §5, §9.)

**Files:**
- Modify: `src/Wok/IR/Anf.hs` (`RReuseCon Atom Text [Atom]` in `Rhs`; `freeVarsRhs`; `rhsMaxU` in Perceus uses it — keep totality; `prettyModule`/pretty for `Rhs`).
- Modify: `src/Wok/IR/PrimNames.hs` (`rcDropReuseName = "__rc_drop_reuse"`; a key if `__rc_drop` uses one — mirror `__rc_drop`).
- Modify: `src/Wok/Interp/RC/Prim.hs` (an `RCPrim` for `__rc_drop_reuse` calling `dropReuse`, returning `PRDone (RVReuse …)`).
- Modify: `src/Wok/Interp/RC/Machine.hs` (`evalRhsRC` arm for `RReuseCon` → `allocAt`).
- Modify: `src/Wok/IR/Perceus.hs` (`rhsMaxU (RReuseCon …)`; `coveredRhs` is NOT needed — post-pass runs later — but add a total `rhsMaxU` case).
- Test: `test/Spec.hs` (a hand-built `RReuseCon`/`__rc_drop_reuse` round-trip through `runModuleRC` asserting reuse fires).

**Acceptance Criteria:**
- [ ] `RReuseCon tok con fields :: Rhs`; `freeVarsRhs (RReuseCon tok _ as) = Set.unions (atomVars tok : map atomVars as)`; `rhsMaxU` total over it; pretty as `con@tok(...)`.
- [ ] `__rc_drop_reuse x` resolves through the RC prim path and returns `PRDone (RVReuse …)` (mirrors `__rc_drop`'s emission/registration).
- [ ] Machine `RReuseCon` arm resolves the token + fields and calls `allocAt`, threading the store.
- [ ] A hand-built module `let tok = __rc_drop_reuse xs ; let r = RReuseCon tok "Cons" [...] ; r` over a unique cons runs on BOTH backends to identical output, with the reuse pair netting 0/0.

**Verify:** `cabal test wok-tests --test-options='-p "rc-reuse-ir"'` → PASS.

**Steps:**

- [ ] **Step 1: Failing test** — `rc-reuse-ir` group in `test/Spec.hs`: construct the `CoreModule` by hand (no elaborator), run via the existing `runBothBackends`-style helper (or `RCM.runModuleRC`), assert output + abstract==C stats + reuse-pair-nets-0/0.
- [ ] **Step 2: Run, expect FAIL** (`RReuseCon` undefined).
- [ ] **Step 3: Implement** the IR form (Anf), the prim name (PrimNames), the prim (Prim.hs — mirror the `__rc_drop` `RCPrim`, but `rpFn [v] s = do (tok,s') <- dropReuse (addrOf v) s ; pure (PRDone tok, s')`), the machine arm (Machine.hs, beside `RCon` at ~204):

```haskell
evalRhsRC sc (RReuseCon tokA con fldAs) s = do
  tok  <- resolveRCAtomRC sc tokA          -- an RVReuse
  vs   <- mapM (resolveRCAtomRC sc) fldAs
  allocAt tok (NCon con vs) s              -- returns (Addr, Store) → RVBox
```

(Match the actual signature/return shape of the neighbouring `RCon` arm.)

- [ ] **Step 4: Run, expect PASS**; `cabal build`.
- [ ] **Step 5: Commit** — `git commit -am "feat(rc): RReuseCon + __rc_drop_reuse IR + machine/prim (FBIP T3)"`

---

### Task 4: Pairing post-pass `reusePairing`

**Goal:** A `CoreModule -> CoreModule` post-pass, run after `insertRC`, that recognizes a `Case`-matched parent-drop + a dominated straight-line slot-kind-compatible `RCon` and rewrites it to `__rc_drop_reuse` + `RReuseCon`. (Spec §6.)

**Files:**
- Create: `src/Wok/IR/ReusePairing.hs` (`reusePairing :: CoreModule -> CoreModule`; the slot-kind signature `slotKindOf :: CType -> SlotClass`; the straight-line target finder; a fresh-`Unique` supply seeded above the module — reuse `seedSupply`/`freshU` shape from Perceus).
- Modify: the pipeline that runs `insertRC` (find it: `grep -rn "insertRC" src test` → likely `runModuleRC` or a driver) to run `reusePairing` immediately after.
- Modify: `wok.cabal` (expose the new module).
- Test: `test/Spec.hs` (`rc-reuse-pairing` golden: `prettyPerceus`-style dump of `reusePairing (insertRC cm)` for `map`/`reverse`; assert the rewrite fired and a kind-changing map did NOT rewrite).

**Acceptance Criteria:**
- [ ] `reusePairing` fires on a straight-line `AltCon` body containing `let _ = __rc_drop p` (where `p` is the `Case` scrutinee) and a first downstream `RCon` whose static slot-kind signature equals the matched cell's; rewrites to `__rc_drop_reuse` + `RReuseCon`.
- [ ] It does NOT fire when: no parent-drop; the alt branches (nested `Case`/`LetJoin`/`RLam`) between drop and `RCon`; or slot-kind signatures differ (kind-changing map).
- [ ] It mints fresh token `Unique`s (no collision) and is balance-preserving (run `balanceLint` on `insertRC cm` BEFORE the post-pass; the post-pass output is accepted by the machine — no lint regression).
- [ ] `map (+1)` and `reverse` corpora rewrite; an `Int→Char` map corpus does not.

**Verify:** `cabal test wok-tests --test-options='-p "rc-reuse-pairing"'` → PASS.

**Steps:**

- [ ] **Step 1: Golden test** — add `test/rc-reuse-golden/{map,reverse,kindchange}.wok` (or hand-built `CoreModule`s) and a golden dump of `Perceus.prettyPerceus (reusePairing (insertRC cm))`. Assert `map`/`reverse` show `__rc_drop_reuse`/`@tok` and `kindchange` does not.
- [ ] **Step 2: Run, expect FAIL** (`reusePairing` undefined).
- [ ] **Step 3: Implement `ReusePairing.hs`.** Core shape:

```haskell
reusePairing :: CoreModule -> CoreModule
reusePairing cm@(CoreModule bs) = CoreModule (snd (mapAccumL onBind (seed cm) bs))
  -- per TopBind: walk Expr; at each `Case scrut alts`, for each AltCon c bs body,
  -- detect  ... let _ = __rc_drop scrut ...  on the straight-line tail, find the
  -- first RCon c' fields with slotKindSig (map binderType bs) == slotKindSig (types of fields),
  -- mint tok, rewrite the drop -> `let tok = __rc_drop_reuse scrut` and that RCon -> RReuseCon tok.
```

`slotKindOf :: CType -> SlotClass` maps `Int/U64→KI`, `Char→KC`, `()→KU`, boxed/pointer→`KP`, `String`/bignum→`NonEnc`; signatures equal iff per-position classes equal. "Straight-line" = chain of `Let` ending in `Ret`/`Jump`/tail `RApp`, refusing on nested `Case`/`LetJoin`/`RLam`.

- [ ] **Step 4: Wire** `reusePairing` after `insertRC` in the driver; expose the module in `wok.cabal`.
- [ ] **Step 5: Run, expect PASS**; `cabal build`.
- [ ] **Step 6: Commit** — `git commit -am "feat(rc): reusePairing post-pass — map/reverse FBIP rewrite (FBIP T4)"`

---

### Task 5: End-to-end corpus + differential oracle + fault injection

**Goal:** Prove the win and the invariant end-to-end: `map`/`reverse` reuse collapses spine allocs to ~0, output bit-for-bit unchanged, abstract==C on all stats; the fallback/kind-change/shared cases behave; and a mutated pairing is caught. (Spec §10.)

**Files:**
- Create: `test/rc-c-backend/fbip-map.wok`, `fbip-reverse.wok`, `fbip-shared.wok`, `fbip-cons-nil.wok`, `fbip-intwidth-flip.wok`, `fbip-kindchange.wok` (+ optional `fbip-string-reverse.wok`).
- Modify: `test/Spec.hs` — add the new files to `rcCBackendParity`'s file list AND add `rcCBackendTargeted`-style assertions: reuse-fires (alloc/free collapse vs a non-FBIP baseline run), shared-fallback, kind-change-no-reuse, int-width free+fresh.
- Modify (fault injection): extend the `insertRCMutated`/Suite-C mechanism (or add an analogous `reusePairingMutated`) to inject a wrong-arity / ignore-`rc==1` mutation and assert the oracle/`stDead` tripwire catches it.

**Acceptance Criteria:**
- [ ] `fbip-map`/`fbip-reverse`: output identical to the pre-FBIP run; spine alloc/free counts collapse (assert `allocs`/`frees` strictly lower than the non-reuse baseline, ~0 net for the spine); abstract stats == C stats.
- [ ] `fbip-shared`: a shared sublist forces fresh allocation (no reuse); output unchanged; abstract==C.
- [ ] `fbip-kindchange`: no reuse (slot-kind guard); output unchanged; abstract==C.
- [ ] `fbip-intwidth-flip`: the `≥2^63` result takes the not-eligible free+fresh branch; output unchanged; abstract==C.
- [ ] Fault injection: a mutated pairing (wrong arity, or reuse ignoring `rc==1`) is caught (output divergence or a loud `stDead` double-free), never a silent wrong answer.

**Verify:** `cabal test wok-tests --test-options='-p "rc-c-backend"'` and `-p "rc-fbip"` → PASS; full `cabal test wok-tests` → green.

**Steps:**

- [ ] **Step 1: Corpus** — write the `.wok` programs. `fbip-map.wok` e.g. `map (\x -> x + 1) [1,2,3,4]` printed; `fbip-reverse.wok` an accumulator reverse; `fbip-shared.wok` binds a sublist twice; `fbip-kindchange.wok` a map crossing slot kinds; `fbip-intwidth-flip.wok` a map whose result exceeds `Int64`.
- [ ] **Step 2: Targeted assertions** — mirror `rcCBackendTargeted`:

```haskell
, testCase "fbip-map reuses the spine (0 net spine allocs, abstract==C)" $ do
    (txt, absSt, cSt, bl, cAllocs) <- runBothBackends "test/rc-c-backend/fbip-map.wok"
    -- output unchanged vs expected; abstract stats == C stats; spine allocs collapsed
    absSt @?= cSt
    assertBool "balance lint clean" bl
    -- assert allocs are at/below the immediates-only floor for this program
```

- [ ] **Step 3: Fault injection** — add the mutation + assert it is caught (extend the Suite-C harness).
- [ ] **Step 4: Run** the rc groups, then the full suite. Fix any regression.
- [ ] **Step 5: Commit** — `git commit -am "test(rc): FBIP differential-oracle corpus + fault injection (FBIP T5)"`

---

### Task 6: Docs — KB + spec status + README

**Goal:** Record FBIP as IMPLEMENTED and update the through-line. (Spec §13 task 6.)

**Files:**
- Modify: `docs/superpowers/runtime-knowledge-base.md` (the FBIP `[R1]` entry + the §6 roadmap line → IMPLEMENTED with the slot-kind-guard + post-pass notes).
- Modify: `docs/superpowers/specs/2026-06-23-fbip-reuse-design.md` (Status → IMPLEMENTED).
- Modify: the RC `README`/slot table if one tracks slice status (find it: `grep -rln "Slice 2\|immediates\|wok_stat" docs *.md`).

**Acceptance Criteria:**
- [ ] KB FBIP entry reflects: drop_reuse/alloc_at on both heaps, the post-pass, the slot-kind guard, value-only eligibility, runtime `rc==1` gate, the measured alloc-count collapse.
- [ ] Spec status flipped to IMPLEMENTED with the merge ref placeholder.

**Verify:** `cabal test wok-tests` still green; docs read consistently.

**Steps:**
- [ ] **Step 1** — edit the KB + spec status + README.
- [ ] **Step 2: Commit** — `git commit -am "docs(rc): record FBIP S2 as implemented (FBIP T6)"`

---

## Self-review (run before handoff)

- **Spec coverage:** §4.1→T1, §4.2/§4.3 abstract→T1 + C→T2, §4.4 accounting→T1/T2/T5, §5→T3, §6 post-pass+slot-kind→T4, §7 children/immediates→T1/T2 tests + T5 `fbip-cons-nil`, §8 runtime gate→T1/T2, §9 machine→T3, §10 oracle/corpus/fault→T5, §11 docs→T6. No gap.
- **Placeholders:** none — every step names files, code, and a real `cabal test … -p` command.
- **Type consistency:** `RVReuse`/`ReuseSlot`/`nodeCEligible`/`dropReuse`/`allocAt` (T1) are used verbatim in T2/T3; `RReuseCon`/`__rc_drop_reuse` (T3) used verbatim in T4; `reusePairing` (T4) used in T5.

## Dependencies
- T2 blockedBy T1 · T3 blockedBy T1 · T4 blockedBy T3 · T5 blockedBy T2,T3,T4 · T6 blockedBy T5.
