# FFI Slice 2 — the user-facing foreign-module surface (Path C)

Status: DRAFT (brainstorm converged 2026-06-29; user approved the design sections and
asked to run the workflow autonomously). Builds on FFI Slice 1 (the C→RC ownership
handoff: copy-in + zero-copy adopt via the `0xFFFB` `WokForeignBytes` cell), which is
FF-able on `feat/ffi-bytes-in`. This slice branches off that tip
(`feat/ffi-foreign-module`).

Links: `ffi-bytes-in-slice1` (Slice 1 — the ownership handoff this slice surfaces),
`extern-primitive-declarations` (the `extern` keyword + gated-privilege trust anchor),
`qualified-imports-deferred` (the broader slice this deliberately does NOT do),
`string-architecture-slice-e` (E4 view router / borrow tier, E6 `Bytes`),
`named-effect-instances-design` (the effect-operation dot we mirror),
`higher-ir-direction` / `one-shot-as-law-multiplicity` (multiplicity-as-analysis, not
linear types — the philosophy this slice's ownership story follows).

---

## 1. Motivation and goal

Slice 1 built the ownership *plumbing* — bringing a byte buffer from outside the wok
allocator into the reference-counted runtime, either by copy-in (Tier 1) or zero-copy
adopt (Tier 2, freed by a foreign free at refcount-zero). It deliberately shipped **no
user-facing surface**: the two producers (`__ffi_demo_copy` / `__ffi_demo_adopt`) are
hidden prelude-only intrinsics that exist only to exercise the memory path.

This slice gives the user a **real, visible way to call C**: a `foreign module` that maps
a C library to a wok namespace, e.g.

```
foreign module Libc "c" free "free" where
  memchr  : Bytes -> U64 -> U64 -> U64 with IO
  strndup : Bytes -> U64 -> owned Bytes with IO
```

accessed as `Libc.memchr` / `Libc.strndup`. Calling `Libc.strndup buf n` performs a
**genuine foreign call** to the real libc `strndup`, which mallocs a buffer that wok
then **adopts and frees** at refcount-zero (Slice 1's Tier 2, now driven from the
surface). The `__ffi_demo_*` intrinsics are retired — the surface supersedes them.

### The bank-vs-cash framing (kept in view, not acted on)

This slice is "banking", consistent with Slice 1: the *surface*, the *ownership
contract*, and the *IO honesty marker* are codegen-durable. The *optimal* inlined,
trampoline-free C-ABI call remains "cash" collected once a native (QBE/SSA) backend
exists. Per the LuaJIT finding (interpreted FFI is ~5× *slower* than the classic API and
"not worth the trouble"), this slice does **not** build `dlopen`/`libffi`. The honest
interpreter-era FFI is the GHC `unsafe foreign import` pattern over a **blessed
allow-list** of statically-linked symbols (the same mechanism that binds the `wok_rc`
runtime and StringZilla). Symbols outside the allow-list are *recognized by the surface
but rejected at resolution* with a clean "not available in the interpreter; deferred to
native codegen" error.

---

## 2. Background: current mechanics and the gaps (verified 2026-06-29)

- **Grammar already has what we need for the *types*.** `with E` parses on a signature
  (`TWith. Type ::= Type1 "->" Type "with" EffectRow`, `grammar/Wok.cf:274`); `IO` is
  just an `EffectAtom` (`ERAtom. EffectAtom ::= ConId [Type2]`, `:285`). The dotted
  `Libc.memchr` already parses as `EProj (ECon "Libc") (VarId "memchr")`. So `with IO`
  and `Libc.memchr` need **no grammar work** — only *semantics*.
- **No `foreign` keyword exists** (`grammar/Wok.cf`). The `foreign module … where …`
  block + the `owned` return marker + the `free "sym"` header clause are the **only new
  grammar**, requiring a BNFC regen of `src-generated/GeneratedParser/Wok/Abs.hs`
  (the `Decl` datatype is at `Abs.hs:20-36`).
- **`extern` gate.** `extern` is rejected in `UserFile` modules — `inferProgramTC`,
  `Infer.hs:3340-3346` throws `ExternNotAllowed` for every user-file extern
  (collected by `externDecls`, `Infer.hs:3411-3418`). Bare `extern` stays prelude-only;
  the *foreign-module member* becomes the user-allowed FFI form (gate flip — by
  construct, not by string-count; see §4.5).
- **Effect-operation dot.** `Infer.hs:1775` resolves `E.op` via `lookupEffect`
  (`Env.hs:223`) against `envEffects`, instantiates the op scheme, `emitEffect`s, and at
  the `EProj` case **falls back to `inferProjection` at the call site `Infer.hs:1795`**
  (the function itself is *defined* at `Infer.hs:2417`). The new foreign-module arm
  inserts at the `:1795` call site. We mirror the effect-op dot with a
  `lookupForeignModule` arm (§4.4).
- **Effect rows + discharge.** Rows are `Type`s of kind `KEffect`
  (`Types.hs:69-82`); `closeRow` (`Infer.hs:3168`) closes open tails to `RowEmpty`;
  `UndischargedEffect` (`Infer.hs:2486`) errors on an unhandled effect in a closed row.
  There is **no ground effect today** — every built-in effect (`State`, `Reader`, …,
  `prelude/Std/Control.wok`) is user-handleable, and there is **no entry-point
  IO-exemption hook** (it does not exist yet). `IO` is the first ground effect (§4.3).
- **Prim dispatch.** `APrim (Text,Text)` carries `(module, name)` identity
  (`Anf.hs:49-54`); `Elaborate.hs:87-90` routes a prelude `extern` to `APrim`; the
  dispatch tables key on `(module, name)` in `Prim.hs` / `RC/Prim.hs`, names in
  `PrimNames.hs`. Foreign-module members need an analogous but **distinct** routing
  (§4.6) — they are *not* trusted prelude externs.
- **Slice 1 substrate (reused verbatim).** `WokForeignBytes` cell (tag `0xFFFB`),
  `wok_foreign_bytes_alloc` / `_ptr` / `_len`, the `dropAddr` foreign-free-then-`wok_free`
  path, the `NForeignBytes` RC node, the 24 B handle accounting, and the `Region`
  `TcBytes` escape fence are all in place on the base branch.

---

## 3. Scope

### In scope (Slice 2)

1. **The `foreign module` construct** — grammar + AST + loader/typecheck registration of
   a per-file foreign-module namespace.
2. **`Libc.member` resolution** — a `lookupForeignModule` rule mirroring the
   effect-operation dot, resolving locally (no import / qualified-imports machinery).
3. **The `IO` ground effect** — registered built-in effect, no ops, un-handleable,
   un-forgeable, permitted unhandled only at the program entry point, zero runtime cost.
4. **The `extern` gate flip** — foreign-module members are user-allowed; bare `extern`
   stays prelude-only.
5. **The ownership surface** — `owned` return marker (transfer-full → adopt) + `free
   "sym"` module-header clause (the deallocator). Absence of `owned` → copy (transfer
   none). Rides entirely on the existing Perceus RC + escape analysis (no new ownership
   analysis; see §4.2 and §5).
6. **The blessed allow-list + marshalling** — a small set of real, deterministic,
   length-explicit libc symbols (`memchr`, `strndup`), with borrow-out (wok→C) for
   buffer arguments and copy/adopt for buffer returns. Unblessed symbols → clean error.
7. ~~**Retire** the `__ffi_demo_*` prelude intrinsics; the surface supersedes them.~~
   **REVISED during planning (kept, not retired):** the blessed surface set has no
   clean deterministic *copy-return* (transfer-none) libc function (`strndup` always
   transfers; exposing it without `owned` would leak), so retiring `__ffi_demo_copy`
   would drop Tier-1 copy-in coverage and break the `test/rc-ffi-bytes` corpus. The two
   intrinsics are **kept as internal, prelude-only (`extern`-gated) Tier-1/Tier-2 C-path
   test fixtures**; the `foreign module` surface supersedes them for *user-facing* FFI.
   They remain `extern`-gated (a user file still cannot declare them), so this is not a
   surface leak. Full retirement waits for a real copy-return consumer (deferred).
8. **Tests** — differential oracle, gate-flip both directions, honesty gate, adopt
   death-tests through the surface, borrow-out sanitizer soundness, IO discharge.

### Out of scope — deferred, recorded as first-class follow-ons

- **The borrow tier (`transfer none`, scoped).** Zero-copy *borrow* of foreign memory
  (`withForeignBytes buf (\b -> …)`) gated by the activation-scoped escape analysis — the
  GObject `(transfer none)` half of the spectrum, the E4 view router over foreign memory.
  This slice's `transfer none` returns are handled by **copy** only.
- **Opaque foreign types.** `foreign type Sqlite "sqlite3" free "sqlite3_close"` — the
  per-*type* finaliser (the natural generalization of the module `free` clause to a
  resource type). Not built; the `free` clause is designed to generalize to it.
- **Argument-position ownership transfer** (`owned` on a parameter = transfer *into* C).
  The `owned` keyword is designed to extend there; not built.
- **General `dlopen`/`libffi` + the optimal inlined call** — codegen "cash".
- **Per-function deallocator override** (a member overriding the module's `free`) — a
  noted future extension for multi-allocator libraries; not built (the blessed set uses
  one allocator).
- **Cross-file qualified access** (`import Libc` then `Libc.x` from another file) — that
  is the deferred `qualified-imports` slice. Foreign modules are declared and used
  **inline in the same file** here.
- **NUL-terminated C-string functions** (`strlen`/`strdup`) — deliberately excluded; see
  §4.6 (they overread wok's non-NUL-terminated `Bytes`).
- **Genuinely nondeterministic I/O** (`read`/`time`/`rand`/`open`) — recognized by the
  surface but unblessed (would blind the differential oracle); codegen-era.

---

## 4. Design

### 4.1 The `foreign module` construct

A foreign module maps a C library to a wok namespace, declared **inline in a user file**:

```
foreign module Libc "c" free "free" where
  memchr  : Bytes -> U64 -> U64 -> U64 with IO
  strndup : Bytes -> U64 -> owned Bytes with IO
  open64 "open64" : ...                            -- optional symbol override (member name ≠ symbol)
```

- `foreign module ConId String` — the wok namespace name (`Libc`) and the **library
  string** (`"c"`). The library string is metadata that selects the host binding set; in
  the interpreter it is matched against the blessed allow-list (no `dlopen`).
- `free String` (optional header clause) — the library's deallocator symbol. **Required
  iff** any member is `owned`. Declared **once** (it is essentially constant per C
  library — `free`, `g_free`, `sqlite3_free`).
- Members: `VarId [symbolOverride] ":" Type`. The C symbol defaults to the member name;
  an optional leading string overrides it (so `open64 "open64"` or a renamed member). The
  return type may be prefixed `owned` (transfer full; see §4.2). The type **is** the C
  prototype expressed in wok types; `with IO` marks the foreign effect (§4.3).

**Grammar (BNFC, to add).** Recommended block form:

```
DForeign.   Decl ::= "foreign" "module" ConId String ForeignFree "where" "{" [ForeignMember] "}" ;
FFNone.     ForeignFree ::= ;
FFSym.      ForeignFree ::= "free" String ;
FMember.    ForeignMember ::= ForeignOwned VarId ForeignSym ":" Type ;
FONo.       ForeignOwned ::= ;
FOYes.      ForeignOwned ::= "owned" ;
FSNone.     ForeignSym ::= ;
FSName.     ForeignSym ::= String ;
separator   ForeignMember ";" ;
```

`owned` sits on the **member** (a leading keyword) rather than embedded in the return
type, so the general `Type` grammar is **untouched** — the cleanest minimal delta, and it
is semantically a property of the member's result. (The user-facing intuition remains
"the return is `owned`"; the keyword's placement is the only concession.)

**Layout risk.** The `where "{" … "}"` block is layout-sensitive; per the documented
`grammar/Wok.cf` POST-REGEN convention, BNFC's layout output needs a hand-patch (like
prior blocks). If that patch proves heavy, the **layout-free fallback** is a flat per-member
decl form (`foreign Libc strndup : …`) grouped by a preceding `foreign module Libc "c"
free "free"` header — same AST, no indented block. The plan picks based on patch cost
(this is the one real grammar risk and the natural Slice-2a/2b fracture line; §3, §9).

**AST + registration.** `DForeign ConId lib free [FMember]` lowers, during loading /
typecheck setup, into an `envForeignModules :: Map Text ForeignModuleInfo`, where
`ForeignModuleInfo` records the lib string, the deallocator, and each member's
`(symbol, type, owned?)`. This map is the foreign-module analogue of `envEffects`.

### 4.2 Ownership: `owned` + `free` (the transfer model)

The surface separates the two orthogonal questions (the GObject-Introspection model):

- **Does ownership transfer?** — *per member*, varies. `owned` return = `(transfer full)`
  = wok takes ownership. No `owned` = `(transfer none)` = wok does not own it.
- **How is the library's memory freed?** — *per module*, ~constant. The header `free
  "sym"`.

Lowering to Slice 1's tiers:

- `owned` return → **Tier 2 adopt**: the returned foreign buffer is wrapped in a
  `WokForeignBytes` (`0xFFFB`) handle pointing at it; at refcount-zero `dropAddr` runs the
  module's deallocator on the foreign pointer, then `wok_free`s the 24 B handle. (Slice 1
  machinery, verbatim.)
- no `owned` return → **Tier 1 copy-in**: the returned bytes are `memcpy`'d into a normal
  `WokBytes` cell; wok never frees the foreign original (the library owns it). Reuses
  `allocNBytes`.

**`owned` is not linear surface syntax.** It is boundary metadata on a `foreign module`
member — like `: Bytes` and `with IO` already are — describing the C function's contract,
the *one* fact no analysis can recover (owned vs borrowed pointers are physically
indistinguishable; the LuaJIT finding). Ordinary wok code never writes `owned`.

**The safety guarantees come from analysis, not declaration, and require no new
analysis.** Once a foreign buffer becomes an `owned Bytes`, it is a normal RC value:
Perceus dup/drop placement gives exactly-once free (no double-free), liveness gives no
use-after-free, and `Bytes` cannot form cycles so there is no leak. The escape fence
(`Region.isStringType TcBytes`) already routes it to the counted heap, never an arena.
This is the same "linear-type benefits via analysis, no surface modes" move wok already
makes for FBIP reuse and `Array.set`-under-`rc==1`. Declaring `owned` on a non-owned
buffer is UB exactly as in every FFI (and as in OxCaml, whose uniqueness checker also
trusts the `external` declaration); copy (the default) is never wrong.

### 4.3 The `IO` ground effect

`IO` is a built-in **ground** effect: no operations, never handled, never constructed by
the user.

- **Registration.** Seed `IO` into the compiler's initial environment (`envEffects`,
  alongside the builtin tycons in `TypeChecking/Builtins.hs`) as an `EffectInfo` with an
  empty op map. `with IO` then type-checks (the name resolves); no grammar change.
- **Introduction.** A foreign member's arrow type carries `with IO`; **applying** it emits
  `IO` into the ambient row by ordinary application inference (no special projection
  rule). `IO` then propagates up the call chain like any effect.
- **Discharge — verified to need NO code.** The original design imagined a new
  entry-point exemption pass. Investigation during execution (2026-06-29) showed it is
  unnecessary: wok has **no entry-effect-emptiness gate**. `ModeRun` (`app/Main.hs:112`)
  type-checks the entry module and runs it via `Interp.runModule` with no effect-row
  check; a top-level binding's row is closed (open tail → `RowEmpty`) but **concrete
  labels are preserved with no emptiness requirement** (`Infer.hs:3108-3124`), and
  `UndischargedEffect` (`:2486`) fires only at a *perform* site when an op's effect is
  absent from a **closed** ambient. So `IO` behaves as an ordinary inferred/declared
  effect at the type level — its only special property is at **runtime**, where a foreign
  call simply executes (whereas an unhandled `State.get` would fault). Concretely:
  - An unsigned binding (incl. the entry) that calls a foreign function gets `IO`
    *inferred* into its row (the open ambient extends) → no error; its type becomes
    `… with IO`.
  - A binding *signed* `with IO` carries `IO` in its closed row → no error.
  - A binding *signed without* `IO` (closed, pure or other-effect) that calls a foreign
    function → `UndischargedEffect` for `IO` (correct: it lied about its effects).
  - The runtime ignores the effect row; "running the program is the handler" is automatic
    (Koka `io`), needing no pass.
  So discharge needs **no new code**. The only `IO`-specific work is (a) **registration**
  (so the name resolves), and (b) **rejecting a `with`-handler over `IO`** — `IO` has no
  ops, so there is nothing to handle; a handler targeting `IO` is a clean error
  (`IOEffectNotHandleable`). `IO` cannot be forged (only a foreign member's type
  introduces it) or intercepted.
- **Runtime.** `IO` has **no** runtime representation — no handler frame, no world token.
  The interpreter, hitting a foreign call, simply executes the host function. `IO` is a
  static honesty marker only, which is also why it does not disturb the deterministic
  differential oracle.

### 4.4 Resolution (`lookupForeignModule`)

`Libc.memchr` parses as `EProj (ECon "Libc") (VarId "memchr")`. Add an arm beside the
effect-operation dot (`Infer.hs:1775`): when the projection head is a `ConId` naming a
**foreign module** (`lookupForeignModule "Libc" env`), resolve the member, return its
declared type (carrying `with IO`); applying it emits `IO` and the foreign call is
elaborated (§4.6). Resolution order: effect-op dot, then foreign-module dot, then the
existing `inferProjection` (record/named-perform) fallback. A `ConId` that is **both** an
effect and a foreign module is a clean ambiguity error. Because the foreign module is
declared in the same file, this resolves **locally** — no import or qualified-imports
machinery (the deliberate narrow shim; `qualified-imports-deferred`).

### 4.5 The `extern` gate flip

The capability is the **construct**, not a string count: a `foreign module` member is the
user-allowed FFI form; a bare `extern` stays prelude-only. The
`UserFile → ExternNotAllowed` check (`Infer.hs:3340-3346`) is unchanged for bare
`extern`; foreign-module members go through their own (user-allowed) path. This is sound
for exactly the reason in `extern-primitive-declarations`: the gated privilege is "can
touch continuations / runtime control state", which intrinsics have (prelude-only) and
**FFI cannot** (C cannot see wok continuations). So FFI is user-facing without reopening
the trusted-once-sink spoofing class — a foreign member is a *distinct, weaker* trust
class than an intrinsic `extern` (it is never a trusted once-sink; §4.6).

### 4.6 Blessed allow-list + marshalling

**The finding that picks the set.** Real libc string functions are a poor fit for a
deterministic differential oracle, for three reasons: (1) **NUL-termination** —
`strlen`/`strdup` read to a NUL, but wok `Bytes` are length-prefixed and *not*
NUL-terminated, so handing them a wok buffer overreads; (2) **implementation-defined
results** — `memcmp` specifies only the *sign*, so real libc and the Haskell model may
disagree in magnitude; (3) **locale/platform dependence** — `strerror`, locale-sensitive
`toupper`, etc. The rule: **length-explicit, fully-specified, byte-pure functions only.**

The Slice-2 blessed set (both real POSIX/libc, both length-bounded → safe borrow-out,
both faithfully modelable → deterministic):

- `memchr : Bytes -> U64 -> U64 -> U64 with IO` — `(buf, byte, n)`; reads at most `n`
  bytes (no overread); returns the offset of the first `byte` (low 8 bits of the U64) in
  `buf[0..n)`, or `n` if absent. The C pointer result is **marshalled** to a wok offset
  (wok has no raw pointer type). Exercises **borrow-out + multi-arg + scalar return**.
- `strndup : Bytes -> U64 -> owned Bytes with IO` — `(buf, n)`; duplicates `len = min(n,
  strnlen(buf,n))` bytes into a malloc'd, NUL-terminated buffer (bounded by `n` → no
  overread). **The adopted `owned Bytes` has length `len` (the NUL terminator excluded),
  and the `WokForeignBytes` handle is initialized with the true byte count `len`, not
  `n`** — the adopt path must compute the returned length (via `strlen` on the result,
  which is safe because `strndup` guarantees NUL-termination, or by tracking `len`), never
  charge or expose `n`. The Haskell reference/abstract model produces the same `len`-byte
  `Bytes`. Exercises **borrow-out + adopt-return + the `owned`/`free` path** end to end.

**Marshalling.**

- *Borrow-out (arguments).* On `CHeap`, the buffer argument is passed to C as
  `wok_bytes_data(p)` (the inline data pointer) for the duration of a **synchronous,
  non-retaining** call. This is `(transfer none)` on the argument: C reads, does not
  retain, does not free; wok's buffer lifetime is untouched. Sound precisely because the
  blessed functions are synchronous and length-bounded.
- *Return.* `owned` → adopt (Tier 2, `WokForeignBytes` + module deallocator at rc-zero);
  no `owned` → copy (Tier 1, `allocNBytes`). The return disposition (copy/adopt + the
  deallocator symbol) is resolved from the foreign-module decl and threaded to the runtime
  with the foreign call.

**Dispatch / IR.** A foreign-module member elaborates to a foreign-call representation
carrying the resolved `(lib, symbol)`, the argument marshalling, and the return
disposition. This is **distinct from `APrim`** (which is a trusted prelude extern keyed
`(module,name)`): a foreign call is user-declared, untrusted (never a once-sink), and
carries a disposition. The plan decides the concrete encoding (a new `Atom`/`Expr`
variant `AForeign` vs a tagged-`APrim` reusing the dispatch tables); the spec fixes the
*semantics* (resolve `(lib,symbol)` against the blessed allow-list; reject unblessed; apply
the disposition). The blessed host bindings live in the interpreter
(`Prim.hs`/`RC/Prim.hs`) as `foreign import ccall` (real C on `CHeap`) plus a faithful
Haskell model for the abstract/reference backends (the Slice-1 producer pattern).

### 4.7 Backend modeling

- **Reference interpreter:** both functions modeled purely (`memchr` = `elemIndex` in the
  first `n` bytes; `strndup` = a `Bytes` copy). Ownership unobservable.
- **RC abstract heap:** `memchr` → scalar; `strndup` → `NForeignBytes` (adopt, 24 B
  handle charged) per Slice 1, so `peak_bytes` tracks the handle, not the foreign buffer.
- **RC C heap:** real `foreign import ccall "memchr"/"strndup"`; `memchr` reads the
  borrowed pointer; `strndup`'s malloc'd result is wrapped in `WokForeignBytes` and freed
  by the module deallocator at rc-zero.

All three agree on observable bytes and logical stats — the oracle validates uniformly,
exactly as in Slice 1.

---

## 5. Soundness invariants

1. **No new ownership analysis.** `owned` routes into Slice 1's already-death-tested adopt
   node and the existing escape fence. Exactly-once free / no-UAF / no-leak are Perceus RC
   + liveness + acyclicity of `Bytes`, unchanged.
2. **Borrow-out is non-escaping and non-freeing.** The lent pointer is used only within a
   synchronous C call, never retained, never freed by C; the wok buffer's refcount and
   lifetime are untouched. Length-bounded reads ⇒ no overread (the reason NUL functions
   are excluded).
3. **`fromBytes` stays the only door into `String`.** Foreign bytes are `Bytes`; they
   become `String` only through the E6 UTF-8 gate (unchanged).
4. **`IO` is sound as a ground effect.** Enters only via foreign-member types, leaves only
   at the entry point; all *other* unhandled effects still error; no runtime
   representation; un-handleable, un-forgeable.
5. **Gate flip is narrow.** Only foreign-module members become user-allowed; bare `extern`
   in a user file still errors. FFI cannot touch continuations (distinct weaker trust
   class), so no trusted-once-sink spoofing is reopened.
6. **Honesty gate.** A `foreign module` naming an unblessed `(lib,symbol)` is a clean
   resolution error, not a silent no-op or a crash. No `dlopen`.
7. **Slice-1 invariants preserved.** `0xFFFB` reserved-tag exclusion, `wok_free` tag
   dispatch order, allocator-mismatch rule (adopted buffers freed by the *foreign* free,
   never `wok_free`), free ordering (foreign buffer then handle) — all unchanged.

---

## 6. Testing strategy

The differential oracle (reference / RC-abstract / RC-CHeap; output + logical stats) is
the correctness gate, as in every slice.

1. **Differential parity** for `Libc.memchr` and `Libc.strndup` through the surface:
   present/absent byte (memchr), full/truncated/NUL-bearing duplication (strndup),
   feeding `length`/`index`/`fromBytes`/`eqBytes`. Adopt charges the fixed 24 B handle;
   the oracle pins the zero-copy saving (Slice 1 §4.6 invariant), now via the surface.
2. **Gate flip, both directions.** A user file with a `foreign module` compiles; a user
   file with a bare `extern` still throws `ExternNotAllowed`.
3. **Honesty gate.** A `foreign module` naming an unblessed symbol → a clean
   "not available in the interpreter" error (a pinned diagnostic, not a panic).
4. **Adopt soundness through the surface.** Reuse Slice 1's dup-then-drop "freed exactly
   once" death test and the negative control (skip the foreign free → LSan leak; free
   `data_ptr` with `wok_free` → ASan bad-free), now driven by `Libc.strndup`. Mutation-
   confirm the teeth (inject a double-free → SIGABRT).
5. **Borrow-out sanitizer soundness.** ASan/UBSan over `Libc.memchr`/`strndup` confirm no
   overread of the borrowed buffer and that the lent buffer is not freed by C. Update
   `scripts/asan-runtime.sh` for any new C (the E6 `wok_utf8.c` link lesson).
6. **`IO` discharge.** A program calling `Libc.memchr` type-checks with `IO` at the top; a
   program with a *different* forgotten effect still errors; a `with`-handler over `IO`
   is rejected.
7. **Determinism.** Faithful Haskell models for `memchr`/`strndup` documented; no
   nondeterministic symbol is blessed.
8. **Corpus.** A `test/rc-ffi-foreign/` directory mirroring `test/rc-ffi-bytes/`:
   memchr/strndup round-trips, adopt dup/drop balance, gate-flip and honesty negatives.

---

## 7. Code touch-points (anchors for the plan)

- **Grammar:** `grammar/Wok.cf` (new `DForeign` + member productions + `foreign`/`owned`
  keywords; layout patch per the POST-REGEN convention). BNFC regen →
  `src-generated/GeneratedParser/Wok/Abs.hs` (`Decl`), `.../Par.hs`, `.../Lex.hs`,
  `.../Print.hs`, plus the layout/`Skel` as needed.
- **AST / loader:** the surface `Decl` mirror in `src/Wok/Syntax` (or wherever `DEffect`
  etc. are surfaced from `Abs`), and `Loader.hs` to collect `DForeign` into the program.
- **Typecheck:** `src/Wok/TypeChecking/Env.hs` (`envForeignModules`, `ForeignModuleInfo`,
  `lookupForeignModule` beside `lookupEffect:223`); `Infer.hs` (the `EProj`
  foreign-module arm at the `inferProjection` fallback call site `:1795`; the
  `with`-handler-over-`IO` rejection at the handler effect-resolution site; the gate path
  beside `:3340-3346`). NOTE: `IO` discharge needs **no** new pass — verified there is no
  entry-effect gate (`app/Main.hs:112` `ModeRun`; `Infer.hs:3108-3124`); `IO` is an
  ordinary effect at the type level. `Builtins.hs` (seed the `IO` ground effect into the
  initial `envEffects`); `Error.hs` (new diagnostics: unblessed symbol, IO-handler-rejected,
  ambiguous ConId).
- **IR / elaborate:** the foreign-call representation (`Anf.hs` near `APrim:49-54`;
  `Elaborate.hs` near `:87-90`) carrying `(lib,symbol)` + disposition.
- **Interp:** `src/Wok/Interp/Prim.hs` + `src/Wok/Interp/RC/Prim.hs` (blessed host
  bindings: `foreign import ccall` for `memchr`/`strndup` + faithful models; the
  allow-list); `RC/Heap.hs` (the ccall imports); reuse Slice 1's `allocNBytes` /
  `allocForeignBytes` / `dropAddr`.
- **Prelude:** `prelude/Std/Bytes.wok` — remove `__ffi_demo_copy`/`__ffi_demo_adopt` and
  their `PrimNames.hs` entries / prim-table rows (retirement); confirm nothing else
  references them.
- **Region:** confirm `Region.isStringType TcBytes` still fences the surface-driven adopt
  path (escaping `owned Bytes` → counted heap, never arena).
- **Tests:** `test/Spec.hs` wiring + `test/rc-ffi-foreign/` corpus + property tests;
  `scripts/asan-runtime.sh` link update for any new C.

---

## 8. Risks and open questions

- **BNFC layout patch (the main risk).** The `where`-block is layout-sensitive. If the
  patch is heavy, fall back to the flat per-member decl form (§4.1) — same AST, no
  indented block. This is the Slice-2a/2b fracture line.
- **Foreign-call IR encoding.** New `AForeign` variant vs tagged `APrim`. Lean to a
  distinct variant for trust-class clarity (a foreign call must never be mistaken for a
  trusted once-sink), but the plan decides; either way the analyses must treat it as
  untrusted and the disposition must be threaded.
- **`owned` placement.** Member-leading keyword (chosen, minimal grammar) vs return-type
  prefix (more faithful, invasive). Revisit only if argument-transfer lands (which needs
  type-position markers anyway).
- **Entry-point identification for IO discharge.** Confirm exactly where `--run` selects
  the entry expression / how `main` is recognized, so the IO whitelist applies at the
  right (and only the right) close.
- **`memchr` byte argument.** Taken as `U64`, used mod 256; document.
- **`__ffi_demo_*` retirement fallout.** Slice-1 tests reference these; they migrate to
  the surface (`Libc.strndup`) or are removed. Ensure the Slice-1 *ownership* coverage
  (dup/drop death tests, peak_bytes pin) is preserved through the surface, not lost.
- **Sanitizer link drift.** Any new C must be added to every build + sanitizer path
  (the E6 `wok_utf8.c` lesson).

---

## 9. Plan-phase notes (model-tier routing)

- **Grammar + BNFC regen + layout patch** is **standard** (multi-file, integration,
  fiddly): Sonnet; escalate to frontier if the layout patch needs judgment.
- **`lookupForeignModule` resolution, the `IO` ground effect + discharge, the gate flip**
  are **standard** (typecheck integration, the genuinely-new semantics): Sonnet,
  escalate to frontier if the IO discharge / resolution-order interplay needs design
  judgment.
- **The foreign-call IR + marshalling + blessed host bindings** are **standard** (the new
  design surface): Sonnet; the borrow-out soundness and the adopt-through-surface path are
  the parts to review hardest (frontier-reviewed, run-the-exploit discipline).
- **Prelude retirement, prim registration, keyword/AST mechanical wiring** are
  **mechanical** once the design exists (complete spec, 1-2 files): Haiku.
- **Test corpus + oracle wiring** is **standard** (Sonnet); the adopt/borrow death-tests
  reviewed hardest.
- Per-task spec + code-quality reviewers at the standard tier; the final whole-branch deep
  review at session level (Opus) before any merge, then `/code-review high`. No merge to
  main without the user's full-branch review (`review-before-merge`).
