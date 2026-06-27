# String Slice E5 (half 1) — Codepoint iteration

Date: 2026-06-27
Status: DRAFT (pending user review)
Branch (target): a fresh `feat/string-slice-e5` off `main` (E1–E4 merged at `2c90b77`)
Predecessor: [[string-architecture-slice-e]] — E1–E4 all merged to main (local FF).

---

## 0. Scope

This slice delivers **codepoint iteration**: the ability to loop over a string's
Unicode characters in wok, which is impossible today. It is *half 1* of the E5
scope split recorded in the E4 design (`2026-06-26-string-slice-e4-design.md` §0).

**In scope (the entire surface added):**

- `decodeCharAt : String -> U64 -> Char` — decode the codepoint whose UTF-8
  encoding begins at a **byte offset**. First-order (no closure). O(1).
- `charWidthAt : String -> U64 -> U64` — the byte width (1–4) of the codepoint
  whose UTF-8 encoding begins at a byte offset. First-order. O(1).
- `singleton : Char -> String` — one codepoint as a string. First-order.
- `foldChars : (s -> Char -> s) -> s -> String -> s` — the keystone left fold over
  codepoints, written as **ordinary wok library code** over the two decode prims.

**Explicitly NOT in scope (deferred, with the reasons):**

- **The "prim-calls-closure machine frame."** The E1/E2 specs assumed `foldChars`
  required a new reified continuation frame in the machine core. This slice
  establishes that it does **not** — see §2. No machine-core change is made.
- **A string builder / in-place string mutation / the "pre-size the output"
  optimization.** Building strings incrementally (`map`/`filter`/`fromChars`)
  needs either copy-on-write append or an rc==1 in-place buffer. `foldChars`
  *consumes*; it never builds a string, and `singleton` is a single shot. The
  builder is a distinct *production* mechanism (rc==1 mutable buffer + freeze,
  riding on Array Slice C) for a later slice. Decided in the E5 brainstorm: a
  buffer is only ever needed for a transform that **grows** a character; width-
  preserving and shrinking transforms can reuse the input buffer in place. None
  of that is needed for iteration.
- **`chars : String -> [Char]` / `fromChars : [Char] -> String`.** These commit to
  `[Char]`'s representation, which is exactly the list-vs-stream question being
  deferred. `foldChars` commits to no collection representation, so it ships now.
- **The fusable stream layer (E5 half 2)** and the **list internal
  representation** discussion — explicitly parked for a separate session.
- **Ordering comparisons (`<`, `>=`, …) on `U64`.** wok has only `eqU64` today;
  this slice does not add ordering operators (see §4.3 for how the loop
  terminates without them).

---

## 1. Background: why iteration is the gap

String runtime representation today (all funnelled through `stringBytes` in
`src/Wok/Interp/RC/Prim.hs`):

- `NString ByteString` — flat valid UTF-8 (E1).
- `InlineStr ByteString` — SSO, ≤7 bytes, no heap cell (E3).
- `NStringView Addr Int Int` — zero-copy window into a parent (E4).

Existing prims already give **random** codepoint access: `index : String -> U64 ->
Char` and `length : String -> U64`. But `index` re-decodes from the start on every
call (O(n)), so looping with it is **O(n²)** — and there is no way at all to drive a
user function across the characters. `Char` is already a first-class **unboxed
immediate** (`RVLit (LChar c)`, a Haskell `Char` = Unicode scalar), so characters
need no reference counting.

The missing capability is a single-pass (O(n)), effect-sound way to fold a closure
over the codepoints.

---

## 2. Key design decision: decompose, do not add a machine frame

A higher-order primitive that loops over a closure *in Haskell* would be unsound:
continuation capture in this CEK machine walks the explicit `Kont`/`RCKont` frame
stack (`findHandler`/`rcFindHandler`, `spliceKont`) and is structurally blind to
the Haskell call stack. An effect performed by the fold closure mid-string would
capture a continuation that omits the rest of the loop. (Confirmed by
reconnaissance of `dispatchOp` (reference machine, `Machine.hs`) /
`rcDispatchOp` (RC machine, `RC/Machine.hs`), `continuationOwned`, `spliceKont`,
`moveOutCont` (all `RC/Value.hs`).)

The conventional fix would be a reified `KFoldChars` frame. **We reject it.** A
fold over codepoints decomposes into:

1. a **first-order** primitive that decodes *one* codepoint at a byte offset
   (`decodeCharAt`/`charWidthAt`) — no closure, no loop; and
2. `foldChars` written as an **ordinary recursive wok function** over it.

A wok loop is *not* invisible to capture: its progress (offset + accumulator) lives
in real `KLetRC`/`KAppRC` frames on the machine's continuation. An effect performed
by the fold closure therefore captures "the rest of the fold" for free, through the
**existing, already-hardened** continuation machinery — adding **zero** new surface
to `continuationOwned`/`spliceKont`/`cascadeChildren`, the exact code where prior
slices' use-after-frees hid. This is also how `Array.map`/`fold` already work
(higher-order ops are wok functions over first-order `index`/`length`; no Array
prim calls a closure).

Visual companion: `docs/string-codepoint-iteration.html`.

Consequence: this slice is small and low-risk. The "reusable closure-driving frame"
is *not* built, and is not needed by future consumers either — arrays, bytes, and
codepoints all have indexed/offset access, so each decomposes the same way. The
frame would only ever be forced by a source with **no** indexed access, which a
string is not.

---

## 3. Surface (added to `prelude/Std/String.wok`)

```
-- Codepoint iteration (Slice E5). Offsets are BYTE offsets into the UTF-8 buffer.
extern decodeCharAt : String -> U64 -> Char   -- codepoint starting at byte offset
extern charWidthAt  : String -> U64 -> U64    -- byte width (1..4) of that codepoint
extern singleton    : Char -> String          -- one codepoint as a string

-- foldChars: left fold over codepoints, single pass (O(n)).
-- EFFECT-POLYMORPHIC: the fold closure may perform effects (`with eff e`), and
-- foldChars performs exactly the closure's effects. A pure use unifies `e` with
-- the empty row; the effect death-test (§6) instantiates `e = Emit`. This is the
-- signature shape used throughout Std.Control (e.g. `__coro_susp : a -> (b -> s
-- with eff e) -> ...`).
foldChars : (s -> Char -> s with eff e) -> s -> String -> s with eff e
foldChars f acc str = foldCharsGo f acc str 0 (byteLength str)

foldCharsGo : (s -> Char -> s with eff e) -> s -> String -> U64 -> U64 -> s with eff e
foldCharsGo f acc str off end =
  case eqU64 off end of
    True  -> acc
    False -> foldCharsGo f (f acc (decodeCharAt str off))
                         str (off + charWidthAt str off) end
```

`decodeCharAt`/`charWidthAt` are exposed (not hidden) — they are the low-level
codepoint cursor, and with them a user can write their own char loops (map, filter,
search) in wok today, which is the point of the slice.

---

## 4. Implementation

Both interpreters must gain the three prims (the differential oracle runs every
program through both and compares output + allocation stats). `foldChars` is wok
code, so it is compiled once and runs on both.

### 4.1 Shared UTF-8 helpers (new tiny module, e.g. `src/Wok/Interp/Utf8.hs`)

Pure, machine-agnostic, imported by both `Prim.hs` modules (DRY):

```haskell
-- | Byte width (1..4) implied by a UTF-8 lead byte. Errors on a continuation
-- byte (0x80..0xBF) — not a codepoint boundary.
utf8Width :: Word8 -> Either RuntimeError Int

-- | Decode the single codepoint whose UTF-8 encoding begins at byte index i.
-- Returns (codepoint, byteWidth). O(1). Errors (Left) if the byte at i is itself
-- a continuation byte (0x80..0xBF) — i.e. i is not a codepoint boundary. Assumes
-- valid UTF-8 for the bytes AFTER a valid lead (the String invariant guarantees
-- the continuation bytes at i+1.. exist).
decodeCharAt :: ByteString -> Int -> Either RuntimeError (Char, Int)
```

`decodeCharAt`/`utf8Width` both reject a continuation lead byte, so a call at a
non-boundary offset is a loud `PrimError`, never a silent misdecode. To keep the
lead-byte dispatch in one place (DRY), `decodeCharAt` calls `utf8Width` for the
width-and-boundary check, then reads the continuation bytes. `utf8Width` always
returns a width in 1..4 or `Left` — never 0 — which is what guarantees the
`foldChars` loop makes progress (the offset strictly advances; see §4.4).

`decodeCharAt` reads the lead byte, masks it, reads the (width-1) continuation
bytes, assembles the Int codepoint, returns `(toEnum cp, width)`. No
`Data.Text.Encoding.decodeUtf8` on the tail (that would be O(n) per call).

### 4.2 The decode prims

**RC machine** (`src/Wok/Interp/RC/Prim.hs`, field `rpFn :: [RCValue] -> Store -> RC
(RCPrimResult, Store)`), modelled on `stringByteAt` (RC/Prim.hs:789-824):

- `decodeCharAt [sv@(RVBox aa), RVLit (LInt off)]`: `bs <- stringBytes sv s`;
  resolve the offset via `asStringIndex` (the existing helper byteAt uses — rejects
  a negative offset) then upper-bound check `i >= BS.length bs` (else `PrimError
  "String.decodeCharAt: out of bounds"`); `(c, _) <- liftRC (Utf8.decodeCharAt bs
  i)` (`liftRC :: Either RuntimeError a -> RC a`, the idiom in this module — *not*
  `liftEither`); `s1 <- dropAddr aa s`; `pure (PRDone (RVLit (LChar c)), s1)`.
  Consumes the string. 0 alloc.
- `charWidthAt`: same shape; `w <- liftRC (Utf8.utf8Width (BS.index bs i))`; return
  `RVLit (LInt (toInteger w))`. Consumes the string. 0 alloc.

The offset arg is an immediate (no drop). The `Char`/`U64` results are immediates.

**Reference machine** (`src/Wok/Interp/Prim.hs`, `primFn :: [Value] -> Either
RuntimeError PrimResult`, strings are `VLit (LStr Text)`): encode the Text to UTF-8
once (`TxEnc.encodeUtf8 t`), then reuse the same `Utf8` helpers at the byte offset.
This makes the reference `decodeCharAt` O(n) per call (O(n²) over a fold) — fine,
the reference machine is the correctness oracle, not the performance path; both
machines read the *same* bytes so results agree.

### 4.3 `singleton`

- RC: `[RVLit (LChar c)]` → `bs = TxEnc.encodeUtf8 (Tx.singleton c)`; `(na, s1) <-
  alloc (NString bs) s`; `pure (PRDone (RVBox na), s1)`. The `alloc` chokepoint
  auto-routes ≤7-byte bodies to `InlineStr` (E3), and a single codepoint is ≤4
  bytes, so `na` comes back as `InlineStr bs` (an uncounted immediate, no heap
  cell): **`singleton` always produces an inline string → 0 heap cells**. The Char
  arg is an immediate (no drop).
- Reference: `[VLit (LChar c)]` → `PRDone (VLit (LStr (Tx.singleton c)))`.

### 4.4 Termination without ordering operators

wok has only `eqU64`. The loop uses `eqU64 off end` where `end = byteLength str`.
This is sound because **codepoints tile the byte buffer exactly**: starting at 0 and
advancing by exact codepoint widths, `off` takes the values `0, w0, w0+w1, …,
byteLength` and hits `byteLength` precisely. Before completion `off < end` always;
it never overshoots. (Relies on the valid-UTF-8 String invariant + a correct
`charWidthAt`; a `charWidthAt` bug would overshoot, and the next `decodeCharAt`'s
bounds-check fires a loud `PrimError` rather than looping — see §6 backstop. No
ordering operator is introduced.)

### 4.5 Prim name registration

Add `decodeCharAtName`, `charWidthAtName`, `singletonName` to
`src/Wok/IR/PrimNames.hs`, each keyed `(Std.String, <name>)`, and register the three
prims in both `rcStringPrims` (RC/Prim.hs) and `stringPrims` (Prim.hs). No
typechecker change: the `extern` declarations in `Std.String.wok` carry the types,
and `Char` is already a builtin tycon.

---

## 5. Correctness properties / invariants

- **P1 (decode/encode round-trip):** for every codepoint `c`,
  `decodeCharAt (singleton c) 0 == c` and `charWidthAt (singleton c) 0 ==
  byteLength (singleton c)`.
- **P2 (fold = decode-all):** `foldChars (\acc c -> acc ++ [c]) [] s` equals the
  Haskell `Tx.unpack (decodeUtf8 (stringBytes s))` codepoint sequence; and
  `foldChars (\n _ -> n + 1) 0 s == length s`.
- **P3 (single pass / exact tiling):** `foldChars` visits each codepoint exactly
  once; `off` reaches `byteLength str` exactly.
- **P4 (machine agreement):** for every test program, the reference machine and the
  RC machine produce identical output and identical logical allocation stats.
- **P5 (effect-soundness):** if the fold closure performs an effect handled by an
  enclosing handler that resumes, the fold continues correctly across the resume
  (the captured continuation includes the remaining iterations).
- **P6 (RC balance):** a `foldChars` over a string drops the string exactly once and
  leaks/​double-frees nothing; a boxed accumulator (e.g. a built list) is owned and
  released correctly, including across an effect capture/abort.

---

## 6. Testing

Test corpus is `.wok` files in categorized dirs, run by `test/Spec.hs` through the
`rc differential` (both machines agree), `rc stats` (allocation oracle), and
C-backend differential (abstract heap vs C heap) groups.

- **Functional (`test/rc-string/`):** the *primary smoke test* is
  `foldChars`-counts-length (a `U64` accumulator — no list, exercises only the prim
  + driver path and should land first to confirm R1's poly-`s` typecheck); then over
  ASCII, 2-byte (`é`), 3-byte (`€`), and 4-byte codepoints; empty string (returns
  acc, 0 iterations); single codepoint; `singleton` round-trips;
  `decodeCharAt`/`charWidthAt` at hand-checked offsets across a multibyte string. A
  `foldChars`-builds-`[Char]` test (boxed accumulator) follows once the U64 smoke
  test confirms the poly path compiles.
- **OOB (`test/rc-string-oob/`, both-fail = agreement):** `decodeCharAt`/
  `charWidthAt` past `byteLength` → `PrimError`; at a continuation byte → `PrimError`
  (not a codepoint boundary).
- **Differential + stats oracle:** all of the above run through both machines; the
  stats oracle pins that the `foldChars` driver allocates **no heap cells** (only the
  fold closure's own allocations appear), and that `singleton` allocates 0 cells
  (inline).
- **Effect-soundness death-test (the soundness gate; `test/rc-m2b/`-style):** a
  handler with an op `emit : Char -> ()`; a `foldChars` whose closure performs
  `emit c` on each character and returns the (unchanged) accumulator, run under a
  handler that records each emitted char and **resumes** (one-shot — multi-shot is a
  compile error by the one-shot law, so the test uses a single resume). Assert the
  recorded sequence equals `s`'s codepoints, on a string where `emit` fires on a
  **non-final** character (per R4) so "the rest of the fold" is non-trivial. This is
  the test that the decomposition (not a frame) is effect-sound: if the wok driver
  lost iterations after the first `emit`, it fails. Run through the differential
  oracle and assert no RC leak/UAF; the existing sanitizer (ASan/LSan) gate must
  stay clean.
- **Backstop test:** confirm an out-of-bounds `decodeCharAt` raises a catchable
  `PrimError` (documents that a hypothetical width bug surfaces loudly, never as an
  infinite loop into an OOB read).

---

## 7. Now-value vs codegen-deferred (banking honesty)

**Real value now (interpreter):** you can iterate a string's codepoints in wok for
the first time — O(n) single pass, effect-sound. `foldChars`, `decodeCharAt`,
`charWidthAt`, `singleton` all work and are correct on both backends.

**Heap-allocation-free driver, with a refcount caveat:** the `foldCharsGo` loop
allocates no heap cells (Char + U64 are immediates). It does incur O(n) **refcount
churn**: Perceus dups `str` and `f` once per iteration (each is used multiply in the
recursive body), and the decode prims drop their string copy. A codegen backend
would erase this by *borrowing* `str`/`f` across the loop — so "non-allocating"
means "no heap cells," not "no RC traffic," until codegen.

**Reference oracle is O(n²):** the reference `decodeCharAt` re-encodes the whole
Text per call. Acceptable — it is the correctness oracle, exercised on small test
strings only.

**Deferred to codegen:** hoisting the per-iteration refcounts; lowering `foldChars`
to a tight machine loop. (No fusion is involved — that is E5 half 2.)

---

## 8. Files touched

- `src/Wok/Interp/Utf8.hs` — NEW. Pure `utf8Width` + `decodeCharAt` helpers.
- `src/Wok/IR/PrimNames.hs` — three new prim names.
- `src/Wok/Interp/RC/Prim.hs` — RC `decodeCharAt`, `charWidthAt`, `singleton`;
  register in `rcStringPrims`.
- `src/Wok/Interp/Prim.hs` — reference `decodeCharAt`, `charWidthAt`, `singleton`;
  register in `stringPrims`.
- `prelude/Std/String.wok` — three `extern`s + `foldChars`/`foldCharsGo`.
- `test/rc-string/`, `test/rc-string-oob/`, `test/rc-m2b/` (or a dedicated dir) —
  new `.wok` corpus per §6; wired in `test/Spec.hs` if a new dir is added.

No changes to: the machine core (`Machine.hs`, `RC/Machine.hs`), the continuation
types (`Kont`/`RCKont`), `PrimResult`/`RCPrimResult`, `continuationOwned`,
`spliceKont`, the typechecker, or `Builtins.hs`.

---

## 9. Risks & open questions

- **R1 — polymorphic + effect-polymorphic higher-order wok function.**
  `foldChars`'s `(s -> Char -> s with eff e)` with type variable `s` AND effect-row
  variable `e` must typecheck and compile. Precedent is strong (the entire
  `Std.Control` mtl prelude is this shape: `reader`, `state`, `start`, etc.), so
  risk is low, but the surface task must compile BOTH a pure `foldChars` program
  (`e` = empty) and the effectful death-test (`e = Emit`) before the corpus is
  built. If the bare `with eff e` row is rejected on the closure arrow, mirror the
  exact placement from `prelude/Std/Control.wok:5-17`.
- **R2 — naming.** `decodeCharAt`/`charWidthAt` take a *byte* offset, which sits
  between the codepoint-level (`index`) and byte-level (`byteAt`) naming convention
  in `Std.String`. Names are open to a rename (e.g. `charAtByte`); the doc comments
  must make the byte-offset semantics unmistakable.
- **R3 — termination relies on the UTF-8 tiling invariant** rather than an ordering
  comparison. Mitigated by the prim bounds-checks (loud `PrimError` on any
  overshoot). If the user prefers robustness over minimalism, adding `ltU64` and
  using `case ltU64 off end` is a one-line alternative — deliberately deferred to
  keep scope tight.
- **R4 — effect death-test must genuinely capture across an iteration boundary.**
  The test must emit on a *non-final* character so "the rest of the fold" is
  non-trivial; otherwise it does not exercise P5.
