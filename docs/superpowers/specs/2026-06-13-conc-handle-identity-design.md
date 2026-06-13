# Conc handle identity: closing the cross-scheduler id collision

Status: **Implemented** (branch fix/conc-handle-identity), 2026-06-13. Closes the "nested `runConc` id-space
collision" limitation recorded in the slice-3 spec §11
(`2026-06-12-slice-3-runtime-provided-concurrency-design.md`) — a verified
silent-wrong-value bug in shipped code.

Scope: interpreter only (`Machine.hs`, `Sched.hs`, and the shared `IdSupply` /
`idRegionBound` / `maxIdRegion` definitions in `Value.hs`). Zero wok-surface
change: token types, `Request`, `Transport`, and every prelude signature stay
byte-identical. No type-system change.

---

## 1. The problem is broader than "nesting"

`Fiber`/`Promise a`/`Chan a` are plain `data` wrapping a bare `U64` id, and
every `driveConc` instance mints ids from its own counter starting at 0
(`Sched.hs:49`). Any handle that reaches a scheduler other than the one that
minted it silently addresses that scheduler's same-numbered cell. Three doors:

1. **Nesting** (the §11 case, verified by running the exploit): an outer
   handle used under an inner `runConc` — `Conc.req` dispatches to the
   innermost handler, so the inner scheduler serves the outer handle's id.
   Cross-delivery and wrong-value `await`, no error.
2. **Sequential escape**: `runConc`'s result type `a` is unconstrained, so a
   handle simply returns out of one `runConc` and is used inside a later
   sibling. If the sibling has minted a same-numbered handle of its own, the
   stale handle silently aliases it:
   `let p = runConc (\() -> async f) in runConc (\() -> let q = async g in await p)`
   — `await p` reads `q`'s cell. (If the sibling minted nothing, the lookup
   happens to miss and errors today — by accident, with a misleading
   "unknown promise" message.) No nesting involved; same silent wrong value.
3. **CAF escape**: CAFs are forced by separate, lazily-demanded `run` calls
   (`Machine.hs:297`). A top-level constant `top = runConc (\() -> async f)`
   mints ids in its own interpreter entry; the escaped handle collides with
   any other scheduler in the program.

All three are the same defect: **handle ids carry no scheduler identity**.
The §3.4 prim-trust obligation ("the provider must key each cell's stored
value to its handle, so colliding ids cannot cross-deliver") is violated
across scheduler instances, and the §6 promise ("the provider validates every
token") is vacuous when ids collide.

## 2. The decision

**Make every handle id globally unique for the lifetime of the program; keep
per-scheduler storage maps; a foreign handle then fails the existing map
lookup and gets a clean runtime error instead of a silent wrong value.**

Three components:

1. **A fresh-id supply threaded through the machine.** The interpreter is
   pure, and `step`/`enter`/`run` thread no counter today, so the supply rides
   alongside `Config` through those signatures. `driveConc` seeds `schNextId`
   from it and returns the next-free counter (the post-consumption absolute
   value, not a delta); nested drives (reached through `runF`) bump the same
   supply, so an outer scheduler's ids are globally unique even though
   non-contiguous.
2. **Disjoint id regions per interpreter entry.** Lazy CAF forcing (door 3)
   runs in thunks the supply cannot thread through. `runModule` statically
   enumerates all zero-arity binds, so each entry — main plus each CAF — seeds
   its supply at a distinct region base: id = `region (16 bits) | counter (48
   bits)`. Regions make cross-entry collisions impossible by construction
   without changing CAF laziness or forcing order. `evalExprWith` (the test
   seam) seeds region 0; separate test programs share no state, so reuse
   across tests is harmless.
3. **Validation at the existing lookup.** `processStep`'s `ReqAwait`/
   `ReqSend`/`ReqRecv` arms already look the id up in `schCells`/`schChans`;
   ids are never deleted, so a promise id minted by this scheduler always
   hits `schCells` (and a channel id `schChans`). A miss therefore means
   "not minted by this scheduler as a promise/channel" — foreign, stale, or
   forged (including a forged kind confusion, e.g. `Promise` built from a
   channel's id, which only deliberate constructor misuse can produce). The
   existing `Nothing` branches become the check.
   Error wording: `conc: handle not owned by this scheduler (created by
   another runConc, or forged)`, naming the promise/channel boundary.

Semantics: **validate, don't forward.** A request on a foreign handle is a
runtime error, never a delivery to the owning scheduler. Forwarding is both
mechanically impossible under Provider A (the inner `driveConc` is a Haskell
call nested inside the outer's `resumeCoro`; reaching the outer scheduler
would mean reifying the inner scheduler's run-queue — carriers included —
into a wok value: Provider C machinery plus a carrier-escape hazard) and
semantically wrong (effects are dynamically scoped; the innermost `Conc`
handler legitimately intercepts; a handle is a capability bound to its
minting provider instance, like a file descriptor bound to its process).
Nested `runConc` with each level using its own handles works correctly —
nesting itself is supported, not forbidden.

## 3. Rejected alternatives (re-litigate deliberately, not accidentally)

- **Forbid nesting.** Cheap to do (`driveConc` could hand `runF` a
  `PrimTable` with `__drive_conc` rebound to an error), but incomplete: doors
  2 and 3 need identity anyway, and once identity exists, nesting is safe for
  free. It also poisons composition — a library using `runConc` internally as
  a deterministic subworld would be un-callable from `Conc` contexts.
- **Scheduler tag packed into the id (`gen << 32 | slot`), checked at
  dispatch.** Considered at length and rejected as *partially duplicated*:
  the per-scheduler maps must exist regardless, and they already embody
  ownership — a `gen` field is a second copy of that fact, bought with
  pack/unpack code and two overflow guards on *dynamic* 32-bit counters
  (4 billion `runConc` invocations or handles is contrived but reachable in
  a long run; contrast §4's flat-scheme guards, where one bound is a static
  program-size property checked once at load and the other is 2^48). Its only real payoffs were a culprit-naming error
  ("scheduler #2's handle under #5") — hollow, because scheduler instances
  are anonymous to the user — and a rehearsal of the §6 Provider B token
  layout — soft, because Provider B mints its own tokens with its own
  internal discipline (slab slots + reuse generations); what transfers to B
  is the validation *contract* (the minting provider recognizes the token,
  everything else is rejected at the boundary), which the flat scheme
  implements identically. Note the §11 parenthetical ("e.g. a
  scheduler-unique tag checked at request time") suggested this shape; this
  spec supersedes that suggestion. The §2 *region* prefix is not this option
  resurrected: regions are a static artifact of lazy CAF forcing (one per
  interpreter entry, known at `runModule`), not a per-scheduler dynamic tag,
  and no request-time comparison exists.
- **Static prevention, runST-style** (`runConc : (forall s. () -> a with
  Conc s) -> a`, skolem-tagged `Promise s a`). The principled-types answer,
  out of reach and out of character: wok's Leijen-2005 unifier has no
  higher-rank annotations or subsumption; every token type changes arity; and
  it still would not stop forged ids — §6 already commits to boundary
  validation because a foreign executor cannot trust types anyway.
- **Splittable pure supply** (GHC `UniqSupply`-style), to avoid threading a
  counter back out of each resume. Pure splitting makes identities paths in a
  split-tree, which grow without bound and break the `U64` token budget; the
  `unsafePerformIO`-backed variant breaks the interpreter's purity and
  determinism. This was the one scheme that could have dodged the machine
  plumbing; nothing else does — the threading is load-bearing.
- **Forward foreign requests to the owning scheduler.** See §2: impossible
  without Provider C machinery, and semantically inverted.

## 4. Mechanism detail

- **Supply representation**: a strict counter (`Integer` internally, minted
  ids presented as the wok `U64`), threaded as an extra component:
  `step`/`enter` take it and return it beside their result, `run`'s loop
  threads it, and the `Enter`/`Run` callback types in `Sched.hs:16-20` grow
  the same component. Most equations pass it through untouched; the only
  semantic sites are `driveConc`'s mint points (`ReqSpawn`/`ReqAsync`/
  `ReqNewChan` arms, today's `schNextId`) and the region seeding in
  `runModule`.
- **Region layout**: bits 63..48 = entry region, bits 47..0 = counter.
  Main's explicit run = region 0; the k-th zero-arity bind (k from 1) =
  region k. Guards: more than `maxIdRegion` zero-arity binds (= `(2^64-1) div
  idRegionBound` = 65535, *derived* from `idRegionBound` in `Value.hs` so the
  two halves of the bit layout cannot desync), or exhausting a region's
  counter, is a hard `RuntimeError` (refuse to wrap). The wrap guard fires at
  `next mod idRegionBound == 0`, so each region yields `2^48 - 1` mintable ids
  (its last id is the sacrificed sentinel). Both bounds are unreachable in
  practice. `main`'s never-demanded `gEnv` thunk has its own CAF region; if a
  future change ever demands it, ids stay collision-free.
- **Determinism**: lazy CAF demand order is deterministic, supply threading
  is deterministic, so id assignment — and every golden — stays reproducible.
- **Scheduler state**: `Sched` keeps `schNextId` as the threaded supply's
  local view; `driveConc` passes the current supply into each
  `startCoro`/`resumeCoro` (a nested drive may bump it) and reads it back.
- **Fiber ids**: minted from the same supply; no map exists today (no
  `cancel`), so they gain identity now and validation when cancellation
  lands.
- **`containsCont` and the payload restriction are untouched and
  orthogonal**: they police *values crossing* the transport; this change
  polices *addressing*. A handle is first-order data and may legitimately
  ride a channel between fibers of the same scheduler; global uniqueness
  keeps that sound.

## 5. Change footprint

- `Machine.hs`: supply threading through `step`/`enter`/`returnTo`/`run`
  (mechanical), one-line semantic touch at region seeding in
  `runModule`/`forceTop`/`evalExprWith`.
- `Sched.hs`: `Enter`/`Run` types, seed-and-return of the supply, upgraded
  lookup-miss error messages. No new fields beyond the supply view; no
  pack/unpack helpers.
- `Value.hs`: the shared `type IdSupply = Integer`, `idRegionBound`, and
  `maxIdRegion` (derived) definitions + exports.
- Prelude, type checker, `Request`/`Transport` protocol: zero changes.
- Estimated 150-250 line diff; roughly 30 semantic lines, the rest signature
  threading. Existing goldens verified free of embedded scheduler ids.

## 6. Spec/doc updates that ride along

- Slice-3 spec §11: mark the nested-`runConc` limitation **resolved**, note
  the two additional doors (sequential escape, CAF escape) that the original
  entry missed, and point here.
- Slice-3 spec §3.4/§6: note that the prim-trust obligation and boundary
  validation are now actually delivered by Provider A (they were vacuous
  under colliding ids).
- `__drive_conc`/`runConc` doc comments in `Control.wok`: add a note that a
  handle used outside its minting scheduler is a runtime error (the "avoid
  nesting" warning itself lives only in spec §11, where it is removed).

## 7. Verification: run-the-exploit fixtures

Protocol per the slice-3 lesson: each negative fixture is executed **before**
the fix to demonstrate the silent wrong value, and **after** to show the
clean error. Soundness surfaces get run-the-exploit verifiers, not reasoning.

1. **Nested cross-await** (the §11 verified repro): outer `async` fulfils 42;
   inner `runConc` mints a same-numbered promise fulfilling 99; `await` the
   outer handle inside the inner. Before: silently 99. After: foreign-handle
   error.
2. **Nested chan cross-delivery**: outer `Chan`; inner `send`/`recv` address
   it. Locks the channel dispatch arms separately.
3. **Sequential escape**: promise returned from `runConc` #1, awaited inside
   sibling `runConc` #2 *after #2 mints its own same-numbered promise* (the
   mint-first ordering is what makes the before-state a silent wrong value
   rather than an accidental unknown-id error — same for 4 and 5). Locks the
   no-nesting variant.
4. **Inner escape outward**: inner `runConc` returns its own promise; the
   outer (which has minted its own) awaits it. The symmetric direction.
5. **CAF escape**: `top = runConc (\() -> async f)` at top level; `main`'s
   `runConc` mints its own promise, then awaits the escaped handle. Locks
   the region seeding.
6. **Positive — legitimate nesting**: inner `runConc` uses only its own
   handles; outer continues correctly after it returns; golden value. Proves
   nesting is supported and the supply threads through a nested drive and
   back.
7. Full suite (803) stays green; sequential self-contained `runConc`s are
   already covered there.

## 8. Out of scope

- **Forgery within one scheduler**: a guessed in-range id still addresses a
  live cell. That is the encapsulation gap (§11's `__coerce` entry, no module
  privacy), unchanged by this fix and closed by the privacy slice.
- **Provider B token internals**: slab slots, reuse generations, waker
  wiring. B inherits only the validation contract, which this fix makes real
  in Provider A.
- **Cancellation** (`cancel`/fiber maps), **residual child effects across
  resume**: tracked §11 items, untouched.
