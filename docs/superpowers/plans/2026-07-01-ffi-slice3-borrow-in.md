# FFI Slice 3 — Foreign Borrow Tier Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers-extended-cc:subagent-driven-development (recommended) or superpowers-extended-cc:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let wok read a C-owned byte buffer with zero copy and no refcount — a second-class `Borrow` type whose escape is a compile-time error and whose buffer is freed at the borrow's last use.

**Architecture:** `Borrow` is a prelude-minted `extern type` (so `tcCarrier = True`), made the first **second-class but non-affine** carrier; non-escape is enforced by the existing carrier rule (interprocedural, descends into handler arms), so no new escape analysis is needed for soundness. At runtime it is an **uncounted** zero-copy foreign-view cell (`isBoxedType = False`, no dup/drop); the lent buffer is freed by a **liveness-placed `close`** at the last use of the borrow family (`b` + its slices). The death-test matrix forces each escape route under ASan to prove the gate is load-bearing.

**Tech Stack:** Haskell (GHC + cabal), BNFC grammar, C runtime (`runtime/wok_rc.*`), tasty-golden tests, `scripts/asan-runtime.sh` (ASan + `WOK_RC_MALLOC`).

**User decisions (already made):**
- "I want the latter" — the genuine foreign-owned zero-copy borrow (no RC backstop), not the safe backstopped view-into-our-own-buffer.
- "remove the idea of introducing a block for the scope" — no `withForeignBytes`/block surface; ordinary `let`, scope is implicit.
- "we can use disposition so users don't need to write callback & function chain" → resolved to the `Borrow` carrier type (the disposition is carried by the return type).
- Escape is a compile error (gate), not a silent router-copy; explicit `Bytes.copy` is the escape hatch (SOTA-aligned, user's "copy by default, borrow is special").
- Approved running autonomously (this session, subagent-driven).

---

## File structure

| File | Responsibility |
|---|---|
| `prelude/Std/Borrow.wok` (new) | `extern type Borrow`; the `Borrow` read prims; `Bytes.copy`; the `Demo.lendBuffer` foreign producer |
| `src/Wok/TypeChecking/Carrier.hs` | the non-affine carrier variant (`Borrow` is second-class but not consume-once) |
| `src/Wok/TypeChecking/Env.hs`, `Infer.hs` | carry the non-affine flag on `TyConInfo`; admit `Borrow` slots |
| `runtime/wok_rc.h`, `wok_rc.c` | the new uncounted borrow-view cell (tag `0xFFFA`) + the deterministic `wok_borrow_demo_lend`/`_close` host pair |
| `src/Wok/Interp/RC/Value.hs`, `Heap.hs` | the borrow-view RC node, alloc/read FFI bindings, `isBoxedType = False` |
| `src/Wok/Interp/RC/Prim.hs`, `Prim.hs` | host bindings + faithful pure model for the read prims and the producer |
| `src/Wok/IR/Escape.hs`, `Region.hs` | family-liveness: place `close` at the last use of `b`-or-any-slice |
| `test/rc-ffi-borrow/` (new), `test/Spec.hs` | differential oracle, the death-test matrix, the saving pin |
| `scripts/asan-runtime.sh` | link the new C |

---

### Task 1: The `Borrow` carrier type (second-class, non-affine)

**Goal:** A prelude-minted `extern type Borrow` that is second-class (escape = `CarrierEscape`) but **non-affine** (may be read repeatedly), verified purely at the type level.

**Files:**
- Create: `prelude/Std/Borrow.wok` (the `extern type Borrow` declaration only, this task)
- Modify: `src/Wok/TypeChecking/Env.hs` (add a `tcAffine :: Bool` field to `TyConInfo:48-59`, defaulting `True` so existing carriers are unchanged)
- Modify: `src/Wok/TypeChecking/Infer.hs:1023-1025` (set `tcAffine = False` for `Borrow`; `True` for all other `extern data`/`extern type`)
- Modify: `src/Wok/TypeChecking/Carrier.hs` (gate the affine check `checkFutureAffine`/`isAffineCarrierType:913-915` on `tcAffine`, leaving the escape check `isHandleType:434-437` unconditional)
- Create: `test/typecheck-fail-examples/borrow-escapes-return.wok`, `borrow-escapes-store.wok`
- Create: `test/typecheck-examples/borrow-read-twice.wok`

**Acceptance Criteria:**
- [ ] `extern type Borrow` parses and registers with `tcCarrier = True`, `tcAffine = False`.
- [ ] Returning or storing a `Borrow` is a `CarrierEscape` type error (golden in `typecheck-fail-examples/`).
- [ ] Reading a `Borrow` twice (two non-escaping uses) type-checks (golden in `typecheck-examples/`), proving it is NOT consume-once.
- [ ] Every existing carrier (`Suspension`/`Step`/`ContCell`) still affine (existing tests green).

**Verify:** `cabal test 2>&1 | tail -20` → all green, including the three new goldens.

**Steps:**

- [ ] **Step 1: Add the failing typecheck goldens.** Write `test/typecheck-fail-examples/borrow-escapes-return.wok` — a function `leak (b: Borrow) -> Borrow = b` (returns a borrow). Write `borrow-escapes-store.wok` — putting `b` in a list. Write `test/typecheck-examples/borrow-read-twice.wok` — a function reading `b` twice via a stub prim (use a no-op `extern`-level read declared in `prelude/Std/Borrow.wok` if no read prim exists yet, e.g. `Borrow.length`). Add expected golden outputs (`CarrierEscape` for the fails; success for the read-twice).
- [ ] **Step 2: Run to confirm they fail** (the type/checks don't exist yet). `cabal test 2>&1 | grep -i borrow`.
- [ ] **Step 3: Add `tcAffine` to `TyConInfo`** (`Env.hs:48-59`), default `True`; thread it through the constructor sites. Set it from the declaration in `Infer.hs:1023-1025`: a dedicated `Borrow` name → `False`, else `True`.
- [ ] **Step 4: Gate the affine check** in `Carrier.hs` on `tcAffine` (read it where `isAffineCarrierType:913-915` is consulted), leaving `isHandleType`/the escape rule untouched.
- [ ] **Step 5: Run the goldens green; run the full suite** to confirm no carrier regressions. `cabal test`.
- [ ] **Step 6: Commit.** `git add -A && git commit -m "feat(ffi): Borrow as a second-class non-affine carrier type"`

```json:metadata
{"files":["prelude/Std/Borrow.wok","src/Wok/TypeChecking/Env.hs","src/Wok/TypeChecking/Infer.hs","src/Wok/TypeChecking/Carrier.hs","test/typecheck-fail-examples/borrow-escapes-return.wok","test/typecheck-examples/borrow-read-twice.wok"],"verifyCommand":"cabal test 2>&1 | tail -20","acceptanceCriteria":["extern type Borrow registers tcCarrier=True tcAffine=False","returning/storing a Borrow is CarrierEscape","reading a Borrow twice type-checks","existing carriers stay affine"],"modelTier":"standard"}
```

---

### Task 2: The uncounted foreign-borrow view cell (runtime + RC node)

**Goal:** A new C cell (tag `0xFFFA`) holding `{ptr,len}` into a foreign buffer, with a **no-op drop**, and an RC node that reads through it with zero copy and `isBoxedType = False`.

**Files:**
- Modify: `runtime/wok_rc.h` (new `WOK_BORROW_VIEW_TAG 0xFFFAu`, `wok_borrow_view_alloc(heap, ptr, len)`, `_ptr`, `_len`; drop path is a no-op — never frees `ptr`)
- Modify: `runtime/wok_rc.c` (the alloc/accessors; ensure `wok_free` tag dispatch treats `0xFFFA` drop as freeing only the handle, never `ptr`)
- Modify: `src/Wok/Interp/RC/Value.hs` (an `NBorrowView` node; `wokBorrowViewTag = 0xFFFA`; `isBoxedType`/`nodeValues` so it is uncounted, no children, no-op drop; mirror `NStringView:766`/`allocNStringView:1853` but with NO parent ref)
- Modify: `src/Wok/Interp/RC/Heap.hs` (FFI imports `wokBorrowViewAlloc`/`_ptr`/`_len`)
- Modify: `src/Wok/IR/Escape.hs:114-137` (`isBoxedType` returns `False` for the borrow-view type)
- Modify: `scripts/asan-runtime.sh` (no new C file, but confirm `0xFFFA` exercised by the C unit harness if one is added)
- Modify: `runtime/test/wok_rc_test.c` (a unit test: alloc a borrow-view over a stack buffer, read len/ptr, drop → confirm the buffer is NOT freed, only the handle)

**Acceptance Criteria:**
- [ ] `wok_borrow_view_alloc` returns a `0xFFFA` handle; `_ptr`/`_len` read back; drop frees the handle but never `ptr` (ASan/LSan clean — the foreign buffer is the caller's).
- [ ] `NBorrowView` is uncounted: `isBoxedType = False`, no dup/drop, no child refs.
- [ ] `scripts/asan-runtime.sh` passes with the new C-unit borrow-view test.

**Verify:** `scripts/asan-runtime.sh 2>&1 | tail -15` → all sections pass; `cabal build` clean.

**Steps:**

- [ ] **Step 1: C unit death/positive test first.** In `runtime/test/wok_rc_test.c`, add a test: `uint8_t buf[4]={1,2,3,4}; WokObj* v = wok_borrow_view_alloc(heap, buf, 4); assert(wok_borrow_view_len(v)==4 && wok_borrow_view_ptr(v)==buf); wok_obj_drop(heap, v);` then assert `buf` is untouched and no leak (LSan) and no bad-free (ASan).
- [ ] **Step 2: Implement the C cell** in `wok_rc.h`/`.c` mirroring `wok_string_view_alloc:163` but storing a raw `ptr` (not a `WokObj* parent`), and a drop that frees only the 24 B handle. Add `0xFFFA` to the reserved-tag exclusion list beside `0xFFFB`/`0xFFFC`/`0xFFFD`.
- [ ] **Step 3: RC node + FFI.** Add `NBorrowView Addr Int` (ptr-addr, len) in `Value.hs`; `allocBorrowView` (CHeap → `wokBorrowViewAlloc`; AbstractHeap → a pure window over the producer's bytes, see Task 4); `nodeValues = []` (no children); `isBoxedType` for its type → `False`.
- [ ] **Step 3b:** confirm `wok_free`/`dropAddr` dispatch: a `0xFFFA` drop must NOT call any foreign free (the buffer free is the producer's `close`, Task 5) — distinct from `0xFFFB` which frees libc.
- [ ] **Step 4: Run** `scripts/asan-runtime.sh` and `cabal build`.
- [ ] **Step 5: Commit.** `git commit -am "feat(ffi): uncounted 0xFFFA borrow-view cell + RC node (no-op drop)"`

```json:metadata
{"files":["runtime/wok_rc.h","runtime/wok_rc.c","runtime/test/wok_rc_test.c","src/Wok/Interp/RC/Value.hs","src/Wok/Interp/RC/Heap.hs","src/Wok/IR/Escape.hs","scripts/asan-runtime.sh"],"verifyCommand":"scripts/asan-runtime.sh 2>&1 | tail -15","acceptanceCriteria":["0xFFFA cell alloc/read; drop frees handle not ptr","NBorrowView uncounted isBoxedType=False no dup/drop","asan-runtime.sh green with new C unit test"],"modelTier":"standard"}
```

---

### Task 3: `Borrow` read prims + `Bytes.copy` escape hatch

**Goal:** `Borrow.length`/`byteAt`/`slice`/`memchr` read a borrow with zero copy (`slice` returns a `Borrow`); `Bytes.copy : Borrow -> Bytes` materializes an owned copy.

**Files:**
- Modify: `prelude/Std/Borrow.wok` (the prim signatures: `length : Borrow -> U64`, `byteAt : Borrow -> U64 -> U64`, `slice : Borrow -> U64 -> U64 -> Borrow`, `memchr : Borrow -> U64 -> Option U64`, `copy : Borrow -> Bytes`)
- Modify: `src/Wok/IR/PrimNames.hs` (register the `(Std.Borrow, name)` keys)
- Modify: `src/Wok/Interp/RC/Prim.hs`, `src/Wok/Interp/Prim.hs` (host impls reading through `0xFFFA`; faithful pure model on the abstract heap; `copy` = `allocNBytes` over the borrowed bytes — Tier-1)
- Create: `test/run-examples/borrow-read.wok` + `test/run-golden/borrow-read.out`

**Acceptance Criteria:**
- [ ] `length`/`byteAt`/`memchr` over a borrow return correct values on all backends.
- [ ] `slice b i j` returns a `Borrow` (still second-class); reading it gives the sub-range.
- [ ] `Bytes.copy b` returns an owned `Bytes` equal to the borrowed bytes, which may escape freely (no `CarrierEscape`).

**Verify:** `cabal run wok -- test/run-examples/borrow-read.wok --run` → matches golden; `cabal test` green.

**Steps:**

- [ ] **Step 1: Golden run-example.** `borrow-read.wok`: lend a buffer (Task 4 producer; until Task 4 lands, use a temporary prelude intrinsic producer), read `length`, `byteAt 0`, `memchr 0`, and `Bytes.copy` then `Bytes.length` on the copy; print. Golden the output.
- [ ] **Step 2: Register prim names** in `PrimNames.hs` keyed `(Std.Borrow, …)`.
- [ ] **Step 3: Host + model impls.** In `RC/Prim.hs`, read through `wokBorrowViewPtr`/`_len`; `slice` allocates a NEW `0xFFFA` view at `ptr+i`, len `j-i` (a derived borrow — its liveness extends the family, Task 5); `memchr` scans the borrowed range; `copy` calls `allocNBytes` over the range. Mirror models in `Prim.hs` for the abstract backend.
- [ ] **Step 4: Run** the golden + full suite.
- [ ] **Step 5: Commit.** `git commit -am "feat(ffi): Borrow read prims (length/byteAt/slice/memchr) + Bytes.copy hatch"`

```json:metadata
{"files":["prelude/Std/Borrow.wok","src/Wok/IR/PrimNames.hs","src/Wok/Interp/RC/Prim.hs","src/Wok/Interp/Prim.hs","test/run-examples/borrow-read.wok"],"verifyCommand":"cabal test 2>&1 | tail -20","acceptanceCriteria":["length/byteAt/memchr correct all backends","slice returns a Borrow (second-class)","Bytes.copy returns escapable owned Bytes"],"modelTier":"standard"}
```

---

### Task 4: The deterministic lend-then-free producer + `Borrow` return on the surface

**Goal:** A `foreign module` member returning `Borrow` (the third disposition, carried by the return type), backed by a deterministic host `lend`/`close` pair.

**Files:**
- Modify: `runtime/wok_rc.c`/`.h` (`wok_borrow_demo_lend(n)` → malloc `n` bytes, `buf[i]=i&0xFF`, return ptr; `wok_borrow_demo_close(ptr)` → free)
- Modify: `prelude/Std/Borrow.wok` (`foreign module Demo "c" where lendBuffer : U64 -> Borrow with IO` — or a prelude-blessed producer; the return type `Borrow` IS the disposition, no new keyword)
- Modify: `src/Wok/Interp/RC/Heap.hs` (FFI imports for `lend`/`close`); the foreign-call elaboration recognizing a `Borrow` return → wrap the lent ptr in a `0xFFFA` view
- Modify: `src/Wok/TypeChecking/...` (resolution: a foreign member with return type `Borrow` is the borrow disposition; reuse Slice 2's `lookupForeignModule`/disposition path)
- Modify: the abstract-heap model: `lendBuffer n` yields the deterministic bytes as a pure window (oracle parity)

**Acceptance Criteria:**
- [ ] `Demo.lendBuffer n` returns a `Borrow` whose bytes are `i & 0xFF` for `i in 0..n`, identical on all three backends.
- [ ] The surface recognizes a `Borrow`-typed foreign return as the borrow disposition (no new keyword); `owned`/copy paths unchanged.
- [ ] `with IO` discharges as in Slice 2 (no new pass).

**Verify:** `cabal run wok -- test/run-examples/borrow-read.wok --run` → deterministic bytes; `cabal test` green.

**Steps:**

- [ ] **Step 1: Host pair in C** (`wok_borrow_demo_lend`/`_close`), added to `scripts/asan-runtime.sh` link.
- [ ] **Step 2: Surface + resolution.** Wire a `Borrow`-typed foreign-module return through the Slice-2 disposition machinery; on call, alloc a `0xFFFA` view over the lent ptr; record the `close` for Task 5's placement.
- [ ] **Step 3: Abstract model** producing identical deterministic bytes.
- [ ] **Step 4: Update `borrow-read.wok`** to use `Demo.lendBuffer` (drop the temporary intrinsic from Task 3); re-golden.
- [ ] **Step 5: Run** suite + ASan.
- [ ] **Step 6: Commit.** `git commit -am "feat(ffi): deterministic lend-then-free Borrow producer on the foreign-module surface"`

```json:metadata
{"files":["runtime/wok_rc.c","runtime/wok_rc.h","prelude/Std/Borrow.wok","src/Wok/Interp/RC/Heap.hs","src/Wok/TypeChecking/Infer.hs","scripts/asan-runtime.sh"],"verifyCommand":"cabal test 2>&1 | tail -20","acceptanceCriteria":["Demo.lendBuffer deterministic bytes all backends","Borrow-typed return = borrow disposition no keyword","with IO discharge unchanged"],"modelTier":"standard"}
```

---

### Task 5: Activation-scoped `close` placement (the soundness-critical step) — IMPLEMENTED

**IMPLEMENTED as the ACTIVATION-SCOPED close, NOT precise family-liveness** (the simpler, fully sound design; precise free-ASAP family-liveness is DEFERRED, see the deferred list). The `Borrow` carrier rule (Task 1) already guarantees a borrow and all its slices cannot escape their birth activation, so freeing the lent buffer at **activation exit** is sound: every read of the family provably happened earlier in the body. No new liveness analysis was needed. This REUSES the R1 activation-exit bracket shape (the `enterBodyRC` + close-frame discipline that the arena/window brackets use), not the bump-only `arenaClose` itself (which cannot carry a per-ptr finalizer); the new `KBorrowCloseRC` frame carries the close-set and frees each malloc'd base ptr once.

What landed (vs the original family-liveness plan below):
- `runtime/wok_rc.{h,c}`: `wok_borrow_demo_lend(n)` (real malloc, `buf[i]=i&0xFF`, cap-clamped) + `wok_borrow_demo_close(ptr)` (real free), heap-context-free. `Demo.lendBuffer`'s CHeap host now mallocs (replacing Task 4's static buffer); the Integer-domain `max 0 (min n cap)` clamp stays Haskell-side. The `__borrow_demo` static intrinsic is unchanged.
- `Value.hs`: `stBorrowClose :: [[Ptr Word8]]` close-set stack + `borrowOpen`/`borrowRegister`/`borrowClose`; new `stCloses` logical stat (bumped identically on both backends → abstract/C parity pins one close per buffer); `KBorrowCloseRC` Kont frame (depth-invisible, totality-only in the reified-continuation walkers since a borrow run is handler-free).
- `Machine.hs`: `bodyLendsBorrow` (mirrors `bodyOpensArena`, keyed on `DispBorrow`); `enterBodyRC` opens the close-set + pushes `KBorrowCloseRC` (outermost) for a lending body; `returnToRC` runs `borrowClose`; `renderRcStats` shows `closes = N` only when `N > 0` (existing goldens unperturbed).
- `Prim.hs`: `allocBorrowDemoLend` mallocs (CHeap) + registers the base ptr; AbstractHeap registers a `nullPtr` sentinel (count parity). A slice registers nothing (shares the base).
- Tests: `test/run-examples/borrow-malloc-lend.wok` (+ run-golden), `test/rc-borrow/09-malloc-lend-slice` (family: slice read after parent's last mention), `10-case-arm-lend` (both-arms), `11-recursion-per-activation` (per-activation, no cross-activation leak); a `borrow close-count` test group pinning the absolute N on both backends; a `closes parity` assertion in `rcParityHarness`; a `test_borrow_demo_lend_close` C-unit lifecycle test.

Verified: `cabal test` 2057 green; `scripts/asan-runtime.sh interp` clean on the malloc'd-producer corpus (07–11); an ad-hoc ASan double-close abort confirms the free is real (teeth). INHERITED limitation: handler-free only — `runModuleRC` rejects every handler program, so a borrow lend never co-occurs with a handler at RC runtime (a coverage bound, not a UAF hole; Task 1's carrier rule already rejects a borrow escaping into a continuation).

---

**(Original family-liveness plan, superseded by the activation-scoped close above:)**

**Goal:** Place the producer's `close` at the **last use of the borrow family** (`b` and every `slice b …`), with no refcount to lean on, so the buffer is freed exactly once after the last read.

**Files:**
- Modify: `src/Wok/IR/Escape.hs` (extend the liveness walkers so a derived borrow — a `slice` whose parent is a `0xFFFA`/`Borrow` value — contributes its last-use to the parent's free point instead of trying to count the parent)
- Modify: `src/Wok/IR/Region.hs` (emit the `close` at the computed family-last-use; a no-op for true-C-frees producers, the host `close` for the deterministic one)
- Modify: `src/Wok/Interp/RC/Machine.hs` (execute the placed `close`)
- Create: `test/run-examples/borrow-slice-family.wok` (+ golden): a borrow, a slice of it used after the parent's last syntactic mention, confirming the buffer outlives the slice.

**Acceptance Criteria:**
- [ ] The buffer is freed exactly once, after the last use of `b` or any slice of `b` (ASan/LSan clean: no leak, no double-free, no use-after-free).
- [ ] A slice used after the parent's last mention still reads valid bytes (family liveness, not naive parent-last-use).
- [ ] `--dump-rc-stats` shows one `close` per lent buffer.

**Verify:** `scripts/asan-runtime.sh interp 2>&1 | tail -15` (the interp corpus under ASan+`WOK_RC_MALLOC`) → clean on the family example; `cabal test` green.

**Steps:**

- [ ] **Step 1: Failing family test.** `borrow-slice-family.wok`: `let b = Demo.lendBuffer 8 in let s = Borrow.slice b 2 6 in <use s after b's last mention>`; assert correct bytes. Run under ASan — it should FAIL (UAF) before the family-liveness fix (naive last-use of `b` frees too early).
- [ ] **Step 2: Implement family liveness.** In `Escape.hs`, when computing the last use that drives `close` placement, union the live ranges of `b` and all borrow-views derived from it (track the `slice`→parent provenance the way `NStringView` parent is tracked, but for the uncounted `0xFFFA` family). Place the `close` in `Region.hs` past the family's last use.
- [ ] **Step 3: Branches/loops.** Confirm placement on both arms of a `case`, and that a per-iteration borrow is closed per iteration (reuse the existing per-activation placement; add a control-flow test).
- [ ] **Step 4: Run** the family test green under ASan; full suite green.
- [ ] **Step 5: Commit.** `git commit -am "feat(ffi): family-liveness close placement for uncounted borrow views"`

```json:metadata
{"files":["src/Wok/IR/Escape.hs","src/Wok/IR/Region.hs","src/Wok/Interp/RC/Machine.hs","test/run-examples/borrow-slice-family.wok"],"verifyCommand":"scripts/asan-runtime.sh interp 2>&1 | tail -15","acceptanceCriteria":["buffer freed exactly once after family last-use (ASan/LSan clean)","slice outliving parent mention reads valid bytes","one close per lent buffer in rc-stats"],"modelTier":"frontier"}
```

---

### Task 6: The death-test matrix (escape routes, mutation-confirmed under ASan)

**Goal:** Prove the gate is load-bearing: every escape route is a compile-time `CarrierEscape`, and disabling the check turns each into a real ASan use-after-free.

**Files:**
- Create: `test/typecheck-fail-examples/borrow-escape-{return,list,record,closure,cont-store,slice-escape}.wok` (each a `CarrierEscape`)
- Create: `test/rc-ffi-borrow/death-{...}.wok` + a CPP/flag-gated mutation (mirror the Slice-1/2 `ffi-noclamp-negctrl` pattern + `rceForceWindow`) that forces the borrow past the carrier rule
- Modify: `test/Spec.hs` (wire the matrix; assert compile-reject for the well-typed cases, and ASan-abort for the forced-escape mutations)
- Modify: `scripts/asan-runtime.sh` (the negative-control build)

**Acceptance Criteria:**
- [ ] Each escape route (return, list, record, escaping closure, `__cont_store`, slice-escapes-family) is rejected at compile time with `CarrierEscape`.
- [ ] The **stored-continuation** case is among them and is rejected (Q4 — the carrier walk descends into handler arms).
- [ ] For each, the mutation (force past the gate) under ASan produces a genuine read-after-free abort — mutation-confirmed, NOT vacuous (a control that still reads live memory is a test bug and must be fixed).

**Verify:** `cabal test 2>&1 | grep -iE "borrow.*(escape|death)"` → all reject-goldens pass; `scripts/asan-runtime.sh 2>&1 | tail -20` → each negative control aborts as expected.

**Steps:**

- [ ] **Step 1: The reject goldens.** One `.wok` per route, each expecting `CarrierEscape`. Include `borrow-escape-cont-store.wok`: a closure capturing `b` handed to `__cont_store` (the M3 route).
- [ ] **Step 2: The mutations.** For each route, a CPP/flag-gated build that disables the carrier check (or forces the view past it via the `rceForceWindow` seam) and a `.wok` that escapes the borrow then reads it after `close`. Under ASan this must abort with a read-after-free.
- [ ] **Step 3: Vacuity guard.** For each mutation, confirm that WITHOUT the mutation the program is rejected, and WITH it the read genuinely hits freed memory (not a live copy) — document the freed-address evidence so no control is vacuous.
- [ ] **Step 4: Wire `test/Spec.hs`** + run the full matrix.
- [ ] **Step 5: Commit.** `git commit -am "test(ffi): borrow escape death-test matrix (incl. stored-continuation), mutation-confirmed under ASan"`

```json:metadata
{"files":["test/typecheck-fail-examples/borrow-escape-return.wok","test/typecheck-fail-examples/borrow-escape-cont-store.wok","test/rc-ffi-borrow/","test/Spec.hs","scripts/asan-runtime.sh"],"verifyCommand":"scripts/asan-runtime.sh 2>&1 | tail -20","acceptanceCriteria":["every escape route rejected with CarrierEscape","stored-continuation route rejected (Q4)","each mutation aborts under ASan; no vacuous control"],"modelTier":"frontier"}
```

---

### Task 7: Differential oracle + zero-copy saving pin

**Goal:** The three-backend oracle validates borrow reads byte-identically, and pins the zero-copy saving as a real delta vs an explicit copy.

**Files:**
- Modify: `test/Spec.hs` (oracle entries for `length`/`byteAt`/`slice`/`memchr` over a borrow across reference / RC-abstract / RC-CHeap; the saving pin)
- Create: `test/rc-ffi-borrow/oracle-*.wok`

**Acceptance Criteria:**
- [ ] All three backends agree on observable bytes and logical stats for borrow reads.
- [ ] On CHeap, the borrow read path copies **0** buffer bytes; `Bytes.copy` of the same source copies `len`. The oracle pins the delta via `--dump-rc-stats`/`peak_bytes` — a differential, not tautological, pin (compare borrow vs copy on identical data).

**Verify:** `cabal test 2>&1 | grep -i "rc-ffi-borrow"` → oracle parity + the saving delta assertion pass.

**Steps:**

- [ ] **Step 1: Oracle cases.** `.wok` programs exercising each read; run all three backends; assert byte-identical output + matching logical stats.
- [ ] **Step 2: The saving pin.** Two programs on identical source bytes — one borrow-reads, one `Bytes.copy`s — assert `peak_bytes(borrow) + len == peak_bytes(copy)` (the borrow path saved exactly `len` buffer bytes). Reject a tautological pin (e.g. comparing a path to itself).
- [ ] **Step 3: Run** the corpus; full suite green.
- [ ] **Step 4: Commit.** `git commit -am "test(ffi): borrow differential oracle + zero-copy saving pin (differential)"`

```json:metadata
{"files":["test/Spec.hs","test/rc-ffi-borrow/"],"verifyCommand":"cabal test 2>&1 | grep -i rc-ffi-borrow","acceptanceCriteria":["three backends byte-identical for borrow reads","borrow copies 0 buffer bytes vs len for Bytes.copy","saving pin is differential not tautological"],"modelTier":"standard"}
```

---

## Final gate (after all tasks)

- [ ] `hlint` (ignoring `src-generated`) clean on touched files.
- [ ] Whole-branch deep review at session level (Opus) — focus: Task 5 family-liveness (the load-bearing analysis) and Task 6 death-test non-vacuity.
- [ ] `/code-review high` (full branch).
- [ ] `cabal test` fully green; `scripts/asan-runtime.sh` (+ `interp`) clean.
- [ ] No merge to main without the user's full-branch review (`review-before-merge`).

## Self-review (run by the planner)

- **Spec coverage:** §4 in-scope items 1–8 map to Tasks 1 (type), 2 (rep), 3 (prims + copy), 4 (producer/surface), 5 (liveness close), 6 (death-test matrix), 7 (oracle/saving). §6.7 read-API split = Task 3 (own prims, no sub-moding — deferred per spec). All covered.
- **Type consistency:** `tcAffine` (Task 1), `0xFFFA`/`NBorrowView`/`wok_borrow_view_*` (Task 2), `Borrow.{length,byteAt,slice,memchr}`/`Bytes.copy` (Task 3), `Demo.lendBuffer`/`wok_borrow_demo_{lend,close}` (Task 4), family `close` (Task 5) — names consistent across tasks.
- **Deferred per spec (not gaps):** owned→Borrow sub-moding, the `@local`-on-`Bytes` mode, `owned`-into-C, real nondeterministic producers, the explicit `withForeignBytes` combinator.
- **Deferred (Task 5 implementation):** **precise free-ASAP family-liveness** — the close currently fires at activation exit (sound, since `Borrow` cannot escape), not at the true last use of `b`-or-any-`slice`. The free-ASAP optimization (free right after the family's last read, shrinking the live window; matters most for a long activation or deep tail recursion where N borrow buffers stay live until unwind) is a future optimization, not a soundness gap. Also deferred: making the off-heap borrow buffer survivable across an in-body runtime error — today a `throwE` mid-borrow-body abandons the `KBorrowCloseRC` frame so the malloc'd buffer is reclaimed only by the OS at process exit (the program is aborting anyway; matches Array Slice A's "PrimError terminates → unobservable" precedent; not exercised by the clean corpus). A robust fix would track outstanding borrow buffers on the C heap context so `wok_heap_free` reclaims them.
