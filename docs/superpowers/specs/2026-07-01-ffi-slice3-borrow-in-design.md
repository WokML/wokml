# FFI Slice 3 — the foreign borrow tier (zero-copy `transfer none`, second-class)

Status: IMPLEMENTED on `feat/ffi-borrow-in` (2026-07-01; 7 tasks, per-task reviews + a
whole-branch Opus deep review = SHIP-WITH-FIXES, no soundness blocker; 2073 tests green,
ASan clean; pending the user's final `review-before-merge` + merge). **See "Implementation
deviations (as shipped)" below for the three places the shipped code intentionally differs
from this up-front design.** Builds on FFI Slice 2 (the user-facing
`foreign module` surface, merged + pushed, `origin/main` at `83a393a`). This slice branches
off `main` and implements the **borrow tier** that Slice 2 explicitly deferred —
*revising* its `withForeignBytes(buf, \b -> …)` combinator sketch to a **second-class
carrier type**, after the SOTA survey and a code-verification pass showed the carrier route
is both cheaper and strictly safer.

Links: `ffi-foreign-module-slice2` (the surface this extends; deferred "borrow tier" note),
`ffi-bytes-in-slice1` (the `0xFFFB` `WokForeignBytes` cell + adopt/copy tiers),
`string-architecture-slice-e` (E4 `SliceRep` view router / `NStringView`; the zero-copy
view framework we reuse), `region-slice-r1` (the activation-scoped escape analysis),
`m3-stored-continuations` (the stored-continuation primitives the borrow must survive),
`one-shot-as-law-multiplicity` (multiplicity-as-analysis, the philosophy the affine axis
follows), `extern-primitive-declarations` (the `extern`/prelude-only capability anchor that
mints carrier types).

---

## Implementation deviations (as shipped, 2026-07-01)

This design was written up front; three things shipped differently. All are sound (confirmed
by the whole-branch Opus review); recorded here so the doc matches the code.

1. **The `0xFFFA` borrow handle is kept COUNTED (`isBoxedType = True`), not uncounted.**
   §6.1/§6.4/§7.4/§10 specify `isBoxedType = False`. That premise was imprecise: the *foreign
   buffer* can't be refcounted regardless, so the no-backstop property comes entirely from the
   buffer-`close` placement (deviation 2), not from uncounting the small handle. Keeping the
   handle counted is strictly better — it makes the borrow a boxed local that the existing
   **M2b-1 boxed-local-capture guard** catches (deviation 3), giving defense-in-depth.
   `src/Wok/IR/Escape.hs` was never modified. Uncounting stays a possible future optimization.

2. **The buffer free is ACTIVATION-SCOPED, not precise family-liveness.** §6.5 proposes freeing
   at the "last use of the borrow family." Shipped instead: a `KBorrowCloseRC` continuation
   frame frees the malloc'd buffer at the borrowing *activation's* exit (reusing the R1
   activation-bracket discipline). Sound because the carrier rule confines the whole family
   (`b` + its slices) to the activation, so every read precedes the close. Precise free-ASAP
   family-liveness is DEFERRED (matters only for large buffers / tight loops). Inherits R1's
   handler-free-modules coverage limit.

3. **The stored-continuation route is caught by the M2b-1 / M3 / one-shot guards, NOT the
   carrier rule.** §3 Q4's mechanism was imprecise: a continuation's capture of `b` is not
   surface-visible to the carrier walk, so the carrier rule does not fire for cont-store.
   Coverage is instead a combination — the runtime one-shot floor (double-resume), the M2b-1
   "handler arm captures an enclosing boxed local" guard (keyed on `isBoxedType = True`, hence
   deviation 1), and the M3 resume-escape guard. The whole-branch review confirmed no admitted
   borrow-after-close read exists across all of these.

**Deferred / documented (non-blocking):**
- **Precise family-liveness (free-ASAP) — and its interpreter consequence.** The
  activation-scoped `KBorrowCloseRC` bracket threads *through* tail calls, so a tail-recursive
  loop that borrows once per iteration holds every iteration's buffer until the whole chain
  unwinds — **O(N) peak memory, defeating TCO** for the idiomatic borrow-in-a-loop (measured:
  linear RSS growth, reachable from any `import Std.Borrow`; memory-safe — all freed on unwind,
  no UAF). This is an *interpreter-unavoidable* characteristic of activation-scoped placement;
  the fix is **codegen precise close-placement** (or a future interpreter family-liveness pass),
  not this slice. Now made **observable** via the `stBorrowLentPeak` off-heap-borrow stat +
  a bounded characterization test (so a regression can't hide and the eventual fix is
  measurable). (xhigh review finding, user-accepted as a documented limitation.)
- The abort-path buffer leak (a suspended-then-abandoned activation never runs its close →
  leak, memory-safe, same class as the M2b raw-abort leak).
- Handle uncounting; `owned`-INTO-C (transfer-full args, the uniqueness axis); real
  nondeterministic producers; owned→borrow sub-moding; the explicit `withForeignBytes` combinator;
  borrow+handler coexistence (handler-free-modules limit inherited from R1).
- **xhigh-review cleanup follow-ups (non-blocking):** reorder `borrowCopyRC` to drop-then-alloc
  for a 24B-tighter peak (consistency with the `borrowSliceRC` fix; needs the saving-pin test's
  expected delta updated); factor the duplicated malloc+copy (`borrowDemoRC` vs `allocForeignBytes`)
  and the 4× read-prim tag-dispatch skeleton into shared helpers (the drift class this branch hit
  twice); cache `bodyLendsBorrow` per-definition instead of re-walking it per activation.

---

## 1. Motivation and goal

Slice 1 brought foreign bytes *into* the RC runtime (copy-in, or zero-copy adopt freed at
rc-zero). Slice 2 gave that a user surface (`foreign module Libc "c" … where …`). Both
handle the directions where wok ends up **owning** something: a copy it owns, or an adopted
buffer it frees. Neither lets wok **read a C-owned buffer without copying it and without
owning it** — the GObject `(transfer none)` *return*, where the C side keeps ownership and
reclaims the buffer on its own schedule.

This slice builds exactly that: a **foreign borrow** — a zero-copy, read-only view of a
buffer wok does not own, valid only inside a bounded scope, where escaping the scope is a
**compile-time error** because there is no refcount to keep the buffer alive.

The decisive property, and why this is harder than the E4 string-views it reuses: an
internal string view holds a refcount on its wok-owned parent, so even a mis-analyzed view
cannot dangle — RC is a backstop *underneath* the escape analysis. A foreign buffer has **no
refcount wok can hold**. So for a foreign borrow the escape analysis is not an optimization
over an already-sound path; it is *the entire soundness mechanism*. This is the posture of
the R1 *uncounted* arena, not the E4 *counted* view — and it is the variant the user
explicitly chose over the safe, backstopped "view-into-our-own-buffer" alternative.

### The bank-vs-cash framing

Consistent with the whole FFI arc. What this slice **banks** (codegen-durable): the borrow
*type*, its second-class non-escape *contract*, the *escape rejection*, and the *uncounted
zero-copy representation* in the interpreter. What stays **cash** for a native backend: the
borrow becomes a bare register pointer with the non-escape proof already discharged at
compile time, so zero dup/drop and zero handle. The LuaJIT finding is the load-bearing
justification: interpreted FFI is the slow path *even in the reference implementation*
(LuaJIT's own numbers: interpreted Lua 52.9 s → JIT 9.57 s → FFI-on-JIT 0.48 s), so spending
interpreter cycles on a sound borrow model costs nothing the asymptotic speed was ever going
to keep — the speed was always codegen's to give.

---

## 2. SOTA grounding (surveyed 2026-07-01, primary sources)

The design is a deliberate hybrid that does not exist whole in any one language. Three
surveys (LuaJIT, OxCaml, Koka/Swift) converged:

- **Koka gives the *mechanism*.** A `^`-borrowed value gets **no incref/decref** — the owner
  keeps it alive, the callee just reads (Lorenzen, *Optimizing Reference Counting with
  Borrowing*). But Koka's `^` only ever borrows other live *Koka-heap* references; it has
  **no foreign-memory story** (zero `extern`/FFI mentions in the borrowing design). So Koka
  tells us "read without a refcount," not "how to make that sound for memory you don't own."
- **OxCaml + Swift give the *soundness condition*.** OxCaml `local` and Swift `~Escapable`/
  `Span` both make a non-escaping borrowed view whose escape is a **compile-time error**, and
  Swift's history is the cautionary tale: `withUnsafeBufferPointer` shipped discipline-only
  (escape = UB) and took five evolution proposals (SE-0377/0390/0427/0446/0447) to retrofit
  static enforcement. *Aim straight for the enforced end.*
- **The frontier finding:** none of them solve zero-copy borrow of *foreign, C-owned* memory
  statically. OxCaml documents `caml_alloc_local`/`[@local_opt]` but has **no published
  pattern** for a C stub returning a borrowed foreign pointer; its best real example (httpz)
  borrows into a GC-heap buffer. So there is **no recipe to copy — only an invariant to
  lift.**
- **LuaJIT is the unsafe floor + the perf proof:** owned/foreign pointers *deliberately
  indistinguishable*, silent UAF "your problem"; and zero-overhead FFI is a JIT property, not
  an interpreter one. Lesson: keep wok's tag-visible provenance (the thing LuaJIT renounced),
  and *make the dangling borrow unrepresentable*.

**Verdict:** Koka's borrow *mechanism* (no refcount on the borrowed view) over an OxCaml/
Swift *soundness condition* (scope-confined, escape is a compile error) — realized with
machinery wok already has.

---

## 3. Background: the carrier machinery this rides (verified 2026-07-01)

A code-read pass (`src/Wok/TypeChecking/Carrier.hs` + callers) established that wok's
**second-class "carrier" machinery is the OxCaml-style mode we need, already built** — and is
both interprocedural and continuation-safe in exactly the way a foreign borrow requires.

- **What "second-class" is.** The *carrier rule* in `src/Wok/TypeChecking/Carrier.hs` (916 lines),
  invoked from `Infer.hs:3606-3614` as a post-inference type-checking pass. A type is a
  carrier iff `tcCarrier :: Bool` is set on its `TyConInfo` (`Env.hs:48-59`); a carrier value
  is **second-class (no escape)** and **affine (consume-once)**. `isHandleType`
  (`Carrier.hs:434-437`) recognizes a carrier-typed value; escape is rejected with
  `CarrierEscape` (`Error.hs:157-165`): *"returned, stored in a constructor/record/tuple, put
  in a list, or captured by an escaping closure"* are all rejected.
- **It propagates across function boundaries — modularly (Q2, verified).** `checkCarriers`
  (`Carrier.hs:120-132`) runs **once per top-level binding**, keyed on the *declared type* of
  parameters: a parameter whose type is a carrier becomes a confined binder in that
  function's own body, checked by the same escape rule (`headParamTypes` soundness note,
  `Carrier.hs:319-330`). Cross-module callees are read from the already-checked env
  (`resolveParams`, `Infer.hs:3578-3585`). So `parseHeader(b)` is sound because
  `parseHeader`'s *own* check forbids it from stashing a carrier-typed parameter — no
  call-graph tracing. This is the interprocedural guarantee an intraprocedural escape
  analysis (`escapesFrom`/`arenaEscapes`, `Escape.hs`) structurally cannot give.
- **It is general, not hard-wired to effect carriers (Q3, verified).** `tcCarrier` is set
  purely from the *declaration form* (`Infer.hs:1023-1025`): `extern data`/`extern type` →
  `True`; ordinary `data` → `False`. Three unrelated types already use it (`Suspension`,
  `Step`, `ContCell`; `prelude/Std/Control.wok:30-51`); `Bytes` is **explicitly not** a
  carrier (`prelude/Std/Bytes.wok:6`). Only the **prelude** may mint a carrier type (user
  `extern` → `ExternNotAllowed`, `Infer.hs:3563-3569`) — which matches the FFI capability
  model (the borrow producer is prelude-blessed anyway).
- **It closes the stored-continuation route (Q4, verified — the load-bearing finding).** The
  IR-level escape walkers **omit handler-arm bodies** (`Escape.hs:524-532`, `:465`), with
  soundness for *that* layer resting on `firstOrderNoHandlerViolations` (`Reachable.hs:347-373`),
  which keys on `isBoxedType` (`Escape.hs:114-137`) — the **refcount** flag. An uncounted
  borrow (`isBoxedType = False`) would **slip through that IR guard** (the agent's "single
  sharpest design fork"). But the **carrier walk descends *into* handler arms** at the
  type-checking stage (`checkArm`, `Carrier.hs:368-372`), *before* the IR omission is ever
  reached. So a closure capturing a borrow and handing it to `__cont_store`
  (`prelude/Std/Control.wok:67-69`, the M3 primitives) is rejected as `CarrierEscape` — the
  borrow-in-a-stored-continuation UAF is closed by machinery that already works, and the
  `isBoxedType` fork is rendered **soundness-moot** for the borrow (every escape is rejected
  before the IR pass runs).
- **Affine is separable from escape (verified).** `checkFutureAffine` / the `Card`
  consume-once lattice (`Carrier.hs:619-871`, reusing `Wok.IR.Multiplicity.Card`) is a
  *separate* check from the escape rule — so a **second-class but non-affine** carrier (read
  many times, never consumed) is expressible, which is what a borrow needs.

Reused substrate (in place on `main`): the E4 view framework (`SliceRep = Window|Counted|Copy`,
`Region.hs`; `NStringView` `0xFFFD`, `Value.hs`; the `rceForceWindow`/`windowClose`
death-test seam, `Machine.hs`), the `0xFFFB` `WokForeignBytes` cell + `allocNBytes` /
`dropAddr`, the `escapesFrom`/`arenaEscapes` liveness walkers, the differential oracle, and
`scripts/asan-runtime.sh interp` (GHC-under-ASan with `WOK_RC_MALLOC`).

---

## 4. Scope

### In scope (Slice 3)

1. **The `Borrow` carrier type** — a prelude-minted `extern type` (so `tcCarrier = True`):
   a second-class, **non-affine**, read-only, uncounted view of foreign bytes. (Name TBD in
   plan; `Borrow` throughout this spec.)
2. **A blessed producer returning `Borrow`** — a deterministic host "lend-then-free" byte
   source whose return *type* is `Borrow`. The `Borrow` type itself is the third return
   disposition (the `transfer none` return), carried by the type — **no new keyword**, unlike
   Slice 2's `owned` (which had to disambiguate two `Bytes`-typed returns).
3. **The uncounted zero-copy representation** — a foreign view node (reusing the E4 view
   framework) pointing into the lent buffer; `isBoxedType = False` (no dup/drop), so an
   escaping reference does *not* keep the buffer alive (the no-backstop property). Reads go
   straight through the pointer.
4. **Non-escape enforcement via the carrier rule** — escape (return, store, capture,
   continuation-capture, passing to a non-`Borrow` parameter) is a **compile-time
   `CarrierEscape`**, interprocedurally and including the M3 routes. No silent copy (gate,
   not router; §6.3).
5. **Liveness-placed buffer free** — a statically-placed `close` at the **last use of the
   borrow family** (`b` and every slice derived from it), driven by the existing liveness
   walkers; a no-op for true-C-frees producers, a real free for the deterministic test
   producer (which makes the death-test bite).
6. **`Borrow` read prims** — `length`, `byteAt`, `slice` (returns a `Borrow`), and `memchr`
   over a `Borrow` (the blessed read set). Slices are themselves borrows (family liveness).
7. **The explicit-copy escape hatch** — `Bytes.copy : Borrow -> Bytes` (Tier-1 copy-in,
   user-invoked) is the deliberate way to keep data past the borrow's scope.
8. **The death-test matrix** — one mutation-confirmed-under-ASan negative control per escape
   route (return / constructor / list / closure / **stored continuation** / slice-outlives-
   parent), plus the differential oracle pinning the zero-copy saving.

### Out of scope — deferred, recorded as first-class follow-ons

- **The interprocedural *mode* over plain `Bytes` (OxCaml `@local` on the same type).** This
  slice gives the interprocedural guarantee via a *distinct carrier type* (`Borrow`), not a
  mode-on-the-arrow over `Bytes`. A real mode (so `f : Bytes @local -> r` accepts an owned
  `Bytes` at local mode with full inference) is the larger generalization; deferred.
- **`owned`-INTO-C (argument transfer-full).** Handing wok-owned memory to C that takes
  ownership — the uniqueness axis (`unique`/`overwrite`, `Carrier.hs:619-871`), not the
  locality axis this slice uses. A separate slice.
- **Real nondeterministic `transfer none` producers** (`getenv`, `strerror`). They lend a
  *shared static buffer* clobbered on the next call (nestability hazard, §6.6) and would
  blind the differential oracle. Recognized-but-unblessed; codegen-era.
- **Owned-`Bytes`→`Borrow` sub-moding (the read-API unification).** This slice ships `Borrow`
  with its own read prims (an API split); the automatic weakening that lets the *same*
  `length`/`byteAt` accept both owned `Bytes` and `Borrow` is a later polish (§6.7).
- **The explicit `withForeignBytes`/`with_file` delimiter combinator.** The OxCaml `with_file
  (f : … @ local -> 'a)` explicit-scope form remains available as a future ergonomic
  alternative; this slice uses the implicit activation scope + last-use free.

---

## 5. The model in one walk-through

```
-- prelude only: minting the borrow (this declaration IS the whole "mode")
extern type Borrow                         -- tcCarrier = True: second-class, non-escaping

foreign module Demo "c" where
  lendBuffer : U64 -> Borrow with IO         -- return type Borrow = the transfer-none disposition

-- read the foreign buffer with zero copy, pass it into your own helper (interprocedural):
firstNul : Borrow -> Option U64
firstNul b = Borrow.memchr b 0             -- blessed read; b never escapes firstNul

count : U64 -> U64
count n =
  let b = Demo.lendBuffer n in             -- foreign buffer lent; b is a zero-copy view
  let r = scan b 0 (Borrow.length b) in    -- read freely via blessed prims / helpers
  r                                        -- buffer freed at b's last use; r is a U64 (a fact)
```

Every unsafe move is a compile-time `CarrierEscape`:

```
leak n  = let b = Demo.lendBuffer n in b                        -- ERROR: returned
stash n = let b = Demo.lendBuffer n in [b]                      -- ERROR: stored in a list
cont n  = let b = Demo.lendBuffer n in
          withH (\_ -> __cont_store cell (\_ -> use b))         -- ERROR: captured by a stored continuation (M3)
keep n  = let b = Demo.lendBuffer n in Bytes.copy b             -- OK: explicit copy escapes freely
```

---

## 6. Design

### 6.1 The `Borrow` type (second-class, non-affine, uncounted)

`Borrow` is declared `extern type Borrow` in the prelude, giving it `tcCarrier = True` with
**no new checker code** — `isHandleType`/`checkCarriers` confine it automatically. Two
deviations from the existing (effect-carrier) usage, both pre-verified as expressible:

- **Non-affine.** A borrow is read repeatedly (`byteAt b 0`, `byteAt b 1`), so it must *not*
  be consume-once. Because the affine check (`checkFutureAffine`) is separate from the escape
  check, `Borrow` opts out of the affine lattice while keeping second-class non-escape. The
  plan defines the opt-out (a flag beside `tcCarrier`, or a carrier-kind distinction); the
  spec fixes the semantics: **escape-rejected, freely duplicable as a read.**
- **Uncounted (`isBoxedType = False`).** The borrow value carries no refcount and no dup/drop.
  This is *required*, not an optimization: if the borrow were counted, an escaping reference
  would keep the buffer alive (an E4-style backstop) and the no-backstop semantics the user
  chose would be lost — and the death-test would go vacuous. Uncounted means an escaped borrow
  genuinely dangles, so escape genuinely faults. Soundness for `isBoxedType = False` is
  provided entirely by the carrier rule rejecting escapes at type-checking (§3, Q4) — the
  IR-level `isBoxedType`-keyed guard is moot because no escaping borrow reaches the IR.

### 6.2 The producer (return type `Borrow`)

The `foreign module` surface gains a third return disposition beside Slice 2's `owned`
(adopt) and default (copy): a return whose *type* is **`Borrow`** — `transfer none`,
points-into-a-buffer-C-keeps. Because `Borrow` is a distinct type, it carries the disposition
itself; no new keyword is needed (unlike `owned`, which disambiguates two `Bytes`-typed
returns). The blessed producer for this slice is a **deterministic, host-provided
lend-then-free byte source**:

- `Demo.lendBuffer : U64 -> borrowed Borrow with IO` — on call, the host mallocs a buffer of
  length `n` filled deterministically (`buf[i] = i & 0xFF`), and returns a `Borrow` view over
  it. The host retains ownership; the buffer is freed by the host's `close` (§6.5).

Deterministic content + deterministic free keep the **differential oracle** alive (all three
backends see identical bytes inside the scope) *and* make the death-test non-vacuous (the
buffer is genuinely reclaimed at the placed close, so an escaped read faults under ASan).
This is the lend-then-free flavor of `transfer none` (open / use / release), the only flavor
makeable sound deterministically; the opaque-validity flavor (`getenv`) is deferred (§4).

### 6.3 Enforcement: the carrier rule is the gate (no router-copy)

Escape of a `Borrow` is a **compile-time `CarrierEscape`** — the SOTA-uniform choice (OxCaml,
Swift `~Escapable`, Koka `^`, LuaJIT's "make it unrepresentable"), and a deliberate departure
from E4's *router-not-gate* (silent copy on escape). The justification is the missing
backstop: E4 can route an escaping view to a cheap counted/copy fallback because its parent is
wok-owned; a foreign borrow has no safe silent fallback that preserves borrow semantics, and a
silent copy of foreign memory is a surprising performance cliff. So escape is rejected, and the
**explicit** `Bytes.copy : Borrow -> Bytes` (Tier-1 copy-in) is the way to keep data — copy by
default, borrow as the special case (the user's own framing).

The rule is exactly the existing carrier rule, applied because `Borrow` is a carrier type:
reads (blessed prims), passing into a `Borrow`-typed parameter, and being the block's non-
escaping intermediate are allowed; *returning, storing, capturing, passing to a non-`Borrow`
parameter, or capturing in a stored continuation* are `CarrierEscape`. No new rejection code.

### 6.4 Representation: the uncounted foreign view

Reuse the E4 view framework with a **new, uncounted** node — call it the foreign-borrow view —
distinct from both `NStringView` (`0xFFFD`, counts a wok parent) and `WokForeignBytes`
(`0xFFFB`, owns + frees at rc-zero). The borrow view holds `{ptr, len}` into the lent buffer,
has **no parent count** and a **no-op drop** (wok does not own the buffer; the host frees it).
This is the "Window" arm of `SliceRep` finally exercised for real: E4's interpreter realizes
Window *as* Counted (always-safe); a foreign borrow cannot (no parent), so it is the first
genuinely-uncounted Window — the R1 posture. Reads (`length`, `byteAt`, `slice`, `memchr`) go
straight through `ptr`, mirroring how `bytesBytes` already fast-paths `0xFFFB`/`0xFFFC`.

Backend modeling (oracle-uniform, per the Slice-1/2 pattern):

- **Reference / abstract heap:** the producer yields the deterministic bytes as ordinary
  pure bytes (there is no real foreignness in the pure model); reads observe identical bytes;
  the death-test there exercises the `windowClose` activation assertion (no real memory to
  fault).
- **RC C heap:** the producer mallocs a real buffer; the borrow view points into it
  uncounted; the host `close` frees it; the death-test under ASan faults on a forced-escape
  read. The oracle pins **0 buffer bytes copied** on the borrow path versus `len` bytes on a
  `Bytes.copy` of the same source — a *differential* saving, not a tautological one.

### 6.5 Lifetime: the liveness-placed `close` at the family's last use

Non-escape (§6.3) and the *free* are orthogonal mechanisms. Because the borrow is uncounted,
no RC drop frees the buffer; instead a **`close` is placed statically at the last use of the
borrow family** — `b` together with every `slice b …` derived from it (each slice is itself a
`Borrow` over the same buffer). The placement is computed by the existing liveness/escape
walkers (`escapesFrom`/`arenaEscapes`, extended so a slice whose parent is a foreign borrow
contributes its last-use to the parent's free point rather than trying to count the parent).
`close` calls the producer's host release: a **no-op** for a true-C-frees producer, a real
`free` for the deterministic lend-then-free producer. The carrier rule guarantees no use of
any family member survives past the placed `close`, so the free is always safe — and because
the borrow is uncounted, the free genuinely reclaims (the death-test's teeth).

This **family liveness over uncounted aliased views** is the one genuinely-new analysis in the
slice and the focus of the deep review (the R1 precedent: the load-bearing UAF was caught by
the whole-branch review, not the per-task tests).

### 6.6 The blessed-producer contract

A `Borrow`-returning producer must guarantee **independent validity per lend**: each call returns a
buffer valid for the whole scope, freed only by its own `close`. This *rules out* single-
shared-static-buffer sources (`getenv`, `strerror`), where a second lend clobbers the first
inside its scope — a nestability hazard the deterministic fresh-malloc producer does not have.
The contract is documented and is why those real APIs stay deferred.

### 6.7 Read prims and the owned↔borrow question

This slice ships `Borrow` with **its own read prims** (`Borrow.length`, `Borrow.byteAt`,
`Borrow.slice`, `Borrow.memchr`) — an explicit API split, no coercion, existing `Bytes` code
untouched. The unification (so the *same* `length`/`byteAt` accepts an owned `Bytes` weakened
to `Borrow`, via the one-way safe sub-moding owned ⟶ borrowed) is the natural next polish and
is **deferred** (§4). The split is acceptable for the first cut and avoids a coercion rule in
the type checker on the critical path.

---

## 7. Soundness invariants

1. **Escape is a type error, interprocedurally and including continuations.** Every way a
   `Borrow` could outlive its scope — return, store in any aggregate, capture in an escaping
   closure, capture in a stored continuation, pass to a non-`Borrow` parameter — is
   `CarrierEscape`, by the existing carrier rule, which propagates across function boundaries
   (Q2) and descends into handler arms (Q4). No escaping borrow reaches the IR.
2. **Uncounted ⇒ no backstop ⇒ death-test bites.** The borrow carries no refcount; an escaped
   reference does not keep the buffer alive; the placed `close` genuinely frees; a forced
   escape faults under ASan. (The death-test is non-vacuous precisely because §6.4 is uncounted
   and §6.5 genuinely frees.)
3. **The free is placed past the family's last use.** `close` runs after the last use of `b`
   or any slice of it; the carrier rule guarantees no later use exists. No double-free
   (`close` placed once per family), no use-after-free (no use after `close`), no leak (every
   lent buffer has exactly one reachable `close`).
4. **`isBoxedType = False` is sound here.** The IR-level boxed-local guard is bypassed
   intentionally; its job is already done by the carrier rule at type-checking. The borrow
   never participates in Perceus dup/drop.
5. **`Bytes.copy` is the only escape hatch and is always sound.** It reads the live buffer
   inside the scope into an owned `Bytes` (Tier-1 copy-in); the result is a normal RC value
   with the usual guarantees.
6. **Determinism preserved.** The blessed producer is deterministic (content + free schedule);
   the three backends agree on observable bytes and logical stats; no nondeterministic source
   is blessed.
7. **Slice-1/2 invariants untouched.** `0xFFFB`/`0xFFFC`/`0xFFFD` tag dispatch, the adopt/copy
   paths, the `extern`/foreign-module gate, and `IO` discharge are unchanged; the borrow view
   is a *new* tag with its own no-op drop.

---

## 8. Testing strategy

The differential oracle (reference / RC-abstract / RC-CHeap; bytes + logical stats) is the
correctness gate, as in every slice.

1. **Differential parity** for borrow reads (`length`/`byteAt`/`slice`/`memchr` over a
   `Borrow`) across all three backends; identical observable bytes.
2. **Zero-copy saving pin (differential, not tautological).** On `CHeap`, a borrow read path
   copies **0** buffer bytes; a `Bytes.copy` of the same source copies `len`. The oracle pins
   the delta via `--dump-rc-stats` / `peak_bytes`, comparing the two paths on identical data.
3. **The death-test matrix — the load-bearing gate.** One negative control per escape route,
   each forcing the borrow past the carrier rule (the `rceForceWindow`/test seam) and
   confirming a *real* fault, mutation-confirmed:
   - returned; stored in a constructor/tuple/list; captured in an escaping closure;
   - **captured in a stored continuation** (`__cont_store`) — the M3 case;
   - **slice outlives its parent's last use** (family liveness) — the new-analysis case.
   Each: the well-typed program is rejected at compile time with `CarrierEscape`; the
   mutation (disable the carrier check / force the route) under `asan-runtime.sh interp`
   produces an ASan read-after-free (proving the guard is load-bearing, not decorative).
   A vacuous control (a "leak" that still reads live memory) is itself a test bug.
4. **Carrier-rule positives.** A borrow passed into a `Borrow`-typed helper compiles; the
   helper cannot return/store it (its own check rejects).
5. **`Bytes.copy` round-trip.** `Bytes.copy b` produces an owned `Bytes` that may escape
   freely; bytes equal the borrowed source.
6. **Producer determinism + nestability.** The lend-then-free producer is deterministic;
   nested borrows from it are independently valid (the §6.6 contract).
7. **Corpus.** `test/rc-ffi-borrow/` mirroring `test/rc-ffi-foreign/`: read round-trips,
   the death-test matrix, the saving pin; `scripts/asan-runtime.sh` link updated for any new C.

---

## 9. Code touch-points (anchors for the plan)

- **Prelude:** `prelude/Std/Control.wok` or a new `prelude/Std/Borrow.wok` — `extern type
  Borrow`; the blessed `Demo.lendBuffer` producer; `Borrow.length/byteAt/slice/memchr`,
  `Bytes.copy`.
- **Typecheck (carrier):** `src/Wok/TypeChecking/Carrier.hs` — the **non-affine** opt-out for
  `Borrow` (a flag beside `tcCarrier`/`isAffineCarrierType:913-915`, or a carrier-kind
  split); confirm `checkCarriers:120-132` / `isHandleSlot:453-457` admit a `Borrow`-typed
  parameter slot. `Env.hs:48-59` (`TyConInfo`), `Infer.hs:1023-1025` (the `extern type` →
  `tcCarrier` path), `Error.hs:157-165` (`CarrierEscape`, reused).
- **Grammar/surface:** *minimal* — no new disposition keyword (the `Borrow` return type
  carries it). A `foreign module` member may name `Borrow` as its return type; the surface
  recognizes a `Borrow`-typed return as the borrow disposition. Less grammar than Slice 2's
  `owned` (no new `ForeignOwned`-style production for borrow).
- **IR / representation:** a new uncounted foreign-borrow view node + C tag (beside
  `NStringView` `0xFFFD` in `Value.hs`, the `0xFFFB` cell in `runtime/wok_rc.h`); `isBoxedType`
  (`Escape.hs:114-137`) returns `False` for it; `bytesBytes`/read fast-paths
  (`RC/Prim.hs`) extended to the new tag.
- **Liveness / free placement:** `Escape.hs` (`escapesFrom`/`arenaEscapes` extended for the
  family-last-use of foreign-borrow slices) + the close-placement in the region/Perceus pass
  (`Region.hs`); the host `close` binding (`RC/Heap.hs` ccall) and its no-op vs real-free
  modeling.
- **Interp:** `RC/Prim.hs` / `Prim.hs` (the `lendBuffer` host binding + faithful pure model;
  the borrow read prims); `Machine.hs` (the death-test seam reuse).
- **Tests:** `test/Spec.hs` wiring + `test/rc-ffi-borrow/` corpus + the death-test matrix;
  `scripts/asan-runtime.sh` link update.

---

## 10. Risks and open questions

- **Family liveness over uncounted aliased views (the main risk).** Placing the `close` at the
  last use of `b`-or-any-slice, with no refcount to lean on, is the one genuinely-new analysis
  and the most likely UAF site. Gets the hardest review and a dedicated death-test
  (slice-outlives-parent). R1 precedent: the load-bearing bug was found by the whole-branch
  review, not the per-task tests.
- **Non-affine carrier variant.** `Borrow` is the first second-class-but-not-affine carrier.
  Verified expressible (affine is a separate check), but the opt-out mechanism (flag vs
  carrier-kind) is a design choice the plan must make cleanly so it does not weaken the affine
  guarantee for the existing effect carriers.
- **The `isBoxedType = False` decision.** Sound *given* the carrier rule, but it deliberately
  removes the IR-level boxed-local guard for the borrow — the spec leans entirely on the
  type-checker catching escapes first. Worth an explicit defense-in-depth note in review (is
  there *any* path to the IR for a borrow the carrier rule did not see? e.g. a borrow
  synthesized internally rather than user-written — confirm none).
- **Carrier-walk coverage completeness.** Q4 verified the carrier walk descends into handler
  arms; confirm it also covers the *other* binding forms a borrow can flow through (lambda
  capture, `let`-group, record/tuple construction) with no analogous omission. The agent
  flagged the IR walkers omit arms; confirm the *carrier* walk has no comparable blind spot.
- **Read-API split vs sub-moding.** Shipping `Borrow`'s own prims now (split) vs the owned→
  borrow weakening (coercion) — the split is chosen for the first cut; revisit if the split
  proves ergonomically painful before a consumer exists.
- **Producer surface.** Whether the deterministic producer is a `foreign module` member
  returning `Borrow` (preferred — exercises the real surface) or a prelude intrinsic
  (simpler, less coverage). Lean to the surface, mirroring Slice 2's choice.
- **Sanitizer link drift.** Any new C (the borrow cell, the lend-then-free producer) must be
  added to every build + sanitizer path (the E6 `wok_utf8.c` lesson).

---

## 11. Plan-phase notes (model-tier routing)

- **The `Borrow` carrier type + non-affine opt-out** is **standard** (typecheck integration,
  the genuinely-new carrier variant): Sonnet; escalate to frontier if the affine opt-out
  touches the shared carrier lattice in a way that needs design judgment.
- **The uncounted foreign-borrow view node + read prims + C tag** is **standard** (a new rep
  mirroring `0xFFFB`/`0xFFFD`): Sonnet.
- **The family-liveness `close` placement** is **frontier** — the one design-judgment,
  soundness-critical analysis; inherit the session model (Opus), run-the-exploit discipline.
- **The `borrowed` disposition grammar + BNFC regen** is **standard** (mirrors Slice 2's
  `owned`): Sonnet; mechanical once the production shape is fixed.
- **Prelude declarations, prim registration, host-binding wiring** are **mechanical** once the
  design exists: Haiku.
- **The death-test matrix + oracle wiring** is **standard** (Sonnet); the slice-outlives-
  parent and stored-continuation controls reviewed hardest.
- Per-task spec + code-quality reviewers at the standard tier; the final whole-branch deep
  review at session level (Opus) before any merge — the family-liveness analysis and the
  death-test matrix are the load-bearing gates — then `/code-review high`. No merge to main
  without the user's full-branch review (`review-before-merge`).

---

## 12. References (primary sources, surveyed 2026-07-01)

- **Koka borrowing:** Lorenzen, *Optimizing Reference Counting with Borrowing*
  (antonlorenzen.de/master_thesis_perceus_borrowing.pdf); Reinking et al., *Perceus*
  (PLDI'21); the Koka manual `^` rules. Mechanism: borrowed params get no incref/decref;
  no foreign-memory story (the gap this slice fills).
- **OxCaml modes/locality:** oxcaml.org/documentation/{modes,stack-allocation,uniqueness};
  Jane Street *Oxidizing OCaml* (Locality/Ownership); Lorenzen et al., *Oxidizing OCaml with
  Modal Memory Management* (ICFP'24). Locality = compile-time escape-as-a-mode; `local`
  escape is a type error; **no published C-stub-returns-foreign-borrow pattern** (the
  frontier gap).
- **Swift:** SE-0377 (borrowing/consuming), SE-0390 (`~Copyable`), SE-0427 (noncopyable
  generics), SE-0446 (`~Escapable`), SE-0447 (`Span`). The discipline-only →
  statically-enforced migration is the cautionary tale.
- **LuaJIT FFI:** luajit.org/ext_ffi_semantics.html. Owned/foreign pointers indistinguishable
  by design; no safety; zero-overhead FFI is a JIT property; `ffi.gc` = nondeterministic
  finalizer (Perceus beats it deterministically).
