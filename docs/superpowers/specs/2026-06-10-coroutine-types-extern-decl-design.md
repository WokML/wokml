# Slice 4d — coroutine types as `extern` declarations (visible `Step`/`Suspension` in `Std.Control`)

Date: 2026-06-10
Status: **Design converged** (brainstorming 2026-06-10). Follow-on to slice 4c
(`2026-06-10-slice-4c-step-adt-suspend-naming-design.md`, merged `3b57112`). Makes the coroutine
types — currently invisible compiler built-ins (`TcStep`/`TcSuspension` in `Builtins.hs`) — into
**visible, prelude-declared `extern` types**, so a user reading `Std.Control` sees `Step`'s
constructors and the opaque `Suspension` and can write `case` arms from the source alone. Pure
surface/discoverability + trust-mechanism change; **runtime representation is unchanged** (still
the most performant form from 4c).

Reads with: memory `extern-primitive-declarations` (the value-level `extern` trust anchor this
extends to types), `effects-slice-4c-step-adt` (the built-ins this replaces), `prelude/Std/Control.wok`
(the surface), `src/Wok/TypeChecking/Builtins.hs` (the registrations removed), `Carrier.hs`
(`isHandleType`/affine), `Infer.hs` (`resolveTyCon`, the `extern` Embedded gate), `grammar/Wok.cf`
(`DExtern`/`DData`).

## 1. Summary

Slice 4c shipped `Step a b r = Completed r | Suspended a (Suspension a b r)` and `Suspension a b r`
as **compiler built-ins**: registered in `Builtins.hs`, resolved by name in `Infer.hs`, and matched
by dedicated `TyCon` constructors (`TcStep`/`TcSuspension`) in the carrier/affine analyses. They
work and are performant, but they are **invisible** — a user reading `Std.Control` sees the
externs reference `Step a b r` with no declaration of what `Completed`/`Suspended` are.

This slice makes them **declared in the prelude**, extending the existing value-level `extern`
trust marker (prelude-only; analyses trust the marker by identity, not by name) to **types**:

```wok
extern type Suspension a b r                       -- opaque, no constructors
extern data Step a b r
  = Completed r
  | Suspended a (Suspension a b r)
```

A *marked* (`extern`, `Embedded`-origin) tycon is **second-class carrier + affine**; an *unmarked*
`data`/type in a user file is ordinary. The discipline rides the marker, never the name — so a
user's unrelated `data Step` is never mis-restricted. The runtime is byte-for-byte unchanged.

## 2. Surface

`prelude/Std/Control.wok` gains two real declarations (replacing the 4c reference *comment*):

```wok
-- The parked producer: opaque, second-class, affine. You never construct one;
-- you obtain it from a `Suspended` arm and feed it to `step`/`run`/`cancel`.
extern type Suspension a b r

-- The outcome of one step: a closed, case-able sum. `case` on it (both arms).
extern data Step a b r
  = Completed r                      -- the producer returned its final r
  | Suspended a (Suspension a b r)   -- it yielded an `a`; the tail is a Suspension
```

Everything else in `Std.Control` is unchanged (the `Coro` effect, the `__coro_*` value externs,
`start`/`step`/`run`/`cancel`). Usage is exactly as in 4c (`case start … of Completed r -> … ;
Suspended x g -> …`).

## 3. The marker (semantics)

`extern data` and `extern type` are **`Embedded`-only**, reusing the existing `extern` gate: a
`UserFile` declaring either is rejected with `ExternNotAllowed` (the same Part-1 gate that already
rejects a `UserFile` value `extern`, `Infer.hs:3088`). A marked tycon confers exactly the 4c
discipline:

- **Carrier (second-class, no escape):** `isHandleType` is True for it; it may be a `let`-RHS /
  `case`-scrutinee / handle-typed arg but never returned, stored in a constructor/record/list, or
  captured by an escaping closure (`CarrierEscape`).
- **Affine (consume-once):** a `Suspension` is consumed by `step`/`run`/`cancel` (the
  passed-as-argument rule); a `Step` is consumed by `case`-scrutiny. Consuming either twice is
  `FutureConsumedTwice`.

These are the *same* properties `TcStep`/`TcSuspension` carry in 4c; the marker just becomes their
source of truth.

## 4. Mechanism — trust the marker, not the name

The marked declarations **replace** the built-ins:

- **Remove** from `Builtins.hs`: the `("Step", …)` and `("Suspension", …)` tycon entries and the
  `Step` constructor `envCons` entries. **Remove** the dedicated `TcStep`/`TcSuspension`
  constructors from the `TyCon` enum and their `Infer.hs:resolveTyCon` name cases and pretty
  clauses and `Class.hs:tyConKey` cases. `Step`/`Suspension` become ordinary `TcUser "Step"` /
  `TcUser "Suspension"` tycons — *declared* by the prelude, like `Bool`/`Result`.
- **Add a carrier flag to `TyConInfo`** (`tcCarrier :: Bool`, default `False`). Elaborating an
  `Embedded` `extern data`/`extern type` sets it `True`. (A `UserFile` can't — the gate rejects it
  before the flag is ever set.)
- **The carrier + affine analyses consult the flag, not a `TyCon` constructor.** Today
  `isHandleType` pattern-matches `CTCon TcSuspension`/`CTCon TcStep`; it becomes "the tycon's
  `TyConInfo.tcCarrier` is True." Since `isHandleType` is a pure `CType -> Bool`, the set of
  carrier tycon names (those with `tcCarrier`) is threaded into the carrier walk (`checkCarriers`'
  `Ctx`) and the affine seeding (`checkFutureAffine`/`consumeCard`), the same way the
  `ParamResolver`/`ReaderTrust` contexts are already threaded. (Effect-instance handles
  `CTCon (TcEffect _) _` stay matched directly — they are not part of this marker set.)
- **The 4c producer-exemption is retargeted** from "result type is `TcStep`/`TcSuspension`" to
  "result type is a *marked* carrier tycon" (still `Embedded`-gated), so `step`/`start` still
  type-check returning a freshly-produced `Step`.

**Runtime unchanged (performant).** `Step`'s constructors `Completed`/`Suspended` are ordinary
constructors whose runtime tags are their names — which coincide with the VCon tags the prims
already build (`coroDoneP`/`coroSuspP`). So `Step` is *still* the value `__coro_resume` returns:
no conversion, no allocation change, no lowering, `case` is an ordinary tag dispatch. `Suspension`
is still the bare continuation. The `__coro_*` prim implementations are untouched; only their wok
extern signatures already reference `Step`/`Suspension`, which now resolve to the prelude-declared
tycons rather than the built-ins.

## 5. Grammar

Two new productions in `grammar/Wok.cf`, both reusing the existing `extern` keyword:

```
DExternData. Decl ::= "extern" "data" ConId [VarId] "=" [ConDef] ;   -- constructored, marked
DExternType. Decl ::= "extern" "type" ConId [VarId] ;                -- opaque, marked
```

(`type` is a contextual token appearing only after `extern`, so it does not become a general
reserved word that would clash with user identifiers. If BNFC makes that awkward, the fallback is a
single `extern data ConId [VarId] MaybeConstructors` with an optional `= [ConDef]`, where the
opaque form omits the constructors; decide during implementation, preferring the clearer two-form
spelling.) This is a **grammar change**: regenerate BNFC, reapply the three manual patches
(`grammar/Wok.cf` top comments), and confirm the shift/reduce conflict count does not increase
(the suite is the safety net).

## 6. Robustness

Because carrier-ness rides the `tcCarrier` flag (set only by an `Embedded` `extern` marker), a user
file that declares `data Step a b r = …` gets an ordinary unmarked `TcUser "Step"` — **not**
carrier, not affine, no spurious `CarrierEscape`/`FutureConsumedTwice`. (If such a user file also
imports `Std.Control`, the existing same-name cross-module conflict detection applies, unchanged —
that is orthogonal to this slice.) This is the property the 4c built-in had via a distinct `TyCon`
constructor; the marker preserves it without hardcoding the name `"Step"` anywhere in the analyses.

## 7. Type correctness

`Step`/`Suspension` are ordinary HM tycons (kind `* -> * -> * -> *`, arity 3); `case` on `Step` is
exhaustive over `{Completed, Suspended}`. No new inference complexity. The only type-system addition
is the `tcCarrier` flag and its consultation — a boolean, decidable, threaded like existing context.

## 8. Scope

**IN:** the `extern data`/`extern type` grammar + elaboration (Embedded-gated, sets `tcCarrier`);
remove the `TcStep`/`TcSuspension` built-ins (Builtins + enum + resolver + pretty + tyConKey);
thread the carrier-tycon set into `isHandleType`/carrier-walk/affine; retarget the producer
exemption to the marker; declare `Step`/`Suspension` in `Std.Control` (replace the 4c comment); keep
the runtime/prims unchanged; tests (below).

**OUT (deferred):**
- General `extern type`/`extern data` for *other* prelude types (this slice introduces the facility
  but only `Step`/`Suspension` use it; generalize only on demand).
- Transitive-containment ("any type with a carrier field is carrier") — rejected (§11); the marker
  is sufficient because users cannot put a carrier into a field anyway.
- User-visible construction of `Step` (users `case` it; construction stays prelude/runtime-only, as
  in 4c — a user `Suspended x g` is still `CarrierEscape`).
- The projection-laundering known limitation (recorded in 4c §12) — unchanged, still not
  exploitable.
- Residual-row guard on `run` (4b″).

## 9. Testing

- **Surface/visibility:** a golden confirming `Std.Control` parses with the `extern data`/`extern
  type` decls; the existing coro run-examples (`coro-escape` 421, `coro-step-range` 10, `coro-step-zip`
  52, `coro-multi-driver` 64) and the pull `examples/` all still run unchanged.
- **Discipline preserved (reuse 4c negatives):** `step-escapes`/`suspension-escapes` → `CarrierEscape`;
  `step-scrutinized-twice`/`future-await-twice` → `FutureConsumedTwice`; the inline-escape negatives
  → `CarrierEscape`. These must pass identically against the marker-based analyses (proof the marker
  confers the same discipline the built-in did).
- **Robustness (new):** a `typecheck` example where a `UserFile` declares its own `data Step a b r =
  …` (no import, or with a distinct use) and returns/stores it freely — must **type-check** (proof
  the unmarked user type is NOT treated as carrier). And a `UserFile` writing `extern data`/`extern
  type` → `ExternNotAllowed`.
- **Day-one anchor:** confirm `isHandleType`/affine consult the `tcCarrier` set (unit test over the
  Env), and that removing the built-ins didn't leave a dangling `TcStep`/`TcSuspension` reference.

## 10. Build / verify

`cabal build`; `cabal test`; `cabal run -v0 wok -- <file> --run`. **Grammar change** → BNFC regen +
reapply the three manual patches + confirm shift/reduce count unchanged. Full-branch review before
merge to `main`.

## 11. Rejected alternatives

- **Keep the built-in + the 4c reference comment.** Rejected per this slice's goal: the comment
  documents but does not *declare*; the types remain invisible magic. (Still the fallback if the
  grammar change proves too costly.)
- **Name-keying `TcUser "Step"`/`"Suspension"` as carrier (no marker).** Rejected: a user's
  unrelated `data Step` would be mis-treated as carrier — exactly the name-fragility 4b's
  `extern`-identity discipline was built to avoid.
- **Transitive-containment** ("a type with a carrier-typed field is itself carrier"). Principled and
  general, but its generality (user types holding a `Suspension`) is **unreachable today** (the
  carrier rule forbids putting a `Suspension` into a field), so it buys nothing concrete while
  costing a field-scanning analysis. The explicit marker is simpler and YAGNI-correct. Revisit only
  if first-class/`box` ever lets carriers into fields.
- **A new `prim` keyword** instead of `extern data`/`extern type`. Rejected: `extern` already means
  "prelude-only compiler primitive trusted by identity"; a second marker word for the same concept
  is redundant. Reuse `extern`.
