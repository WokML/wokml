# Slice B — row-kinded type-constructor parameters (`(row e)`)

Date: 2026-06-10
Status: **Design converged** (brainstorming 2026-06-10). The facility step on the kinded-`Ty`
foundation (Slice A, merged `main` cb22b58). Adds the ability for a type constructor to declare a
parameter of kind `Row` (`KEffect`), the `(row e)` surface syntax to declare and apply it, and
kind-checking of tycon applications — proven by TEST FIXTURES only (no prelude/`Suspension`/runtime
change). 4b″ (`Suspension a b r e`) and layer-3 (`Task`/`Stream`/scheduler) consume the facility
later. Implementing session: writing-plans → subagent-driven-development. TDD. Grammar change ⇒ BNFC
regen + reapply the 3 manual patches + confirm shift/reduce count unchanged. Full-branch review
before merge.

Reads with: `2026-06-10-kinded-type-representation-design.md` (the foundation + §7 decidability
contract), memory `kinded-ty-representation` (Slice A shipped), `wok-constructor-naming-convention`
(same-name constructors — used by the examples here), `2026-06-09-slice-4b-dprime-residual-row-future-design.md`
(the first consumer). Grounding code: `grammar/Wok.cf` (`DData`/`DExternData`/`DExternType`,
`Type2`, `RCVar`), `src/Wok/TypeChecking/{Types,Env,Infer}.hs` (`Kind`, `TyConInfo.tcKind`,
`processDataDecls`, the tycon-application arity checks, `translateConArg`).

## 1. Summary

Slice A merged the two type sorts into one kinded representation but introduced no way to *use* a row
as a type-constructor argument: every `data`/`extern` parameter is still kind `*`. Slice B adds that
facility. A parameter written `(row e)` has kind `KEffect` (the row kind); it is referenced inside the
declaration via the existing `eff e`, and supplied at a use site as `(row e)`. Tycon applications are
now kind-checked: a row in a `*` slot, or a `*`-typed argument in a row slot, is a `KindMismatch`.
Nothing else changes — the prelude, `Suspension`/`Step`, and the runtime are untouched; the facility
is proven entirely by test fixtures (a small step that establishes the foundation before any consumer
rides on it).

## 2. Scope decision

**Facility proven by tests only.** A `typecheck-examples` fixture declares a tycon with a `(row e)`
parameter, applies it correctly (type-checks, and `--run`s for the `data` case), and applies it
wrongly (→ `KindMismatch`). The prelude's `Suspension`/`Step` stay arity-3 as today. Giving the
coroutine types a residual-row parameter, with the effect-threading discipline that makes it
meaningful, is slice **4b″** — a separate slice that consumes this facility. (Rejected: folding 4b″
into B — it conflates the facility with the residual-row soundness work and bloats the review.)

## 3. The row kind

Reuse the existing `KEffect` as the row kind. After Slice A it already classifies BOTH effect rows
and record rows (they share the `CType` representation). No new `Kind` constructor; no rename. A
`(row e)` parameter has kind `KEffect`.

## 4. Surface syntax — `(row e)`, reusing the `row` keyword

`row` is already a reserved keyword (used as `Point + row r` in record extension), so `(row VarId)`
introduces no identifier clash and changes no existing syntax.

- **Declaration site.** A type-constructor parameter may be `(row e)` (kind `KEffect`) instead of a
  bare `e` (kind `*`). Applies to `data`, `extern data`, `extern type`.
  ```wok
  data Box (row e) = Box U64                   -- a row-kinded parameter e (single-con; same-name ctor)
  ```
  (Constructor named `Box`, same as the type — wok's same-name convention for single-constructor
  types; see `wok-constructor-naming-convention`. No `Mk` prefix.)

- **Use site.** `(row e)` as a type argument supplies a row variable — in a signature OR a
  constructor field (a tycon applied to a row argument):
  ```wok
  data Pair (row e) = Pair (Box (row e))       -- field: Box applied to the row arg e
  peek : Box (row e) -> U64                     -- signature: Box applied to the row arg e
  peek (Box n) = n
  ```

- **Construction needs no row syntax.** Inference fills the row in:
  ```wok
  main : U64
  main = peek (Box 5)                           -- e is an inferred (unconstrained) row => 5
  ```

- **The row parameter is threaded as a TYPE ARGUMENT, not used in an effect position.** This is
  exactly what the first consumer needs: 4b″'s `Step a b r e = Completed r | Suspended a (Suspension
  a b r e)` passes `e` as a tycon argument (to `Suspension`), NOT via an effect-carrying arrow field.

- **OUT of scope:** (a) **effect-carrying arrow fields** — a constructor field of type `() -> a with
  eff e` (referencing a row param in a `with` clause) is NOT supported (`translateConArg` rejects
  `with` in field types today; it remains deferred). (b) **Concrete rows as type arguments** (e.g.
  `Box {Log}`). Slice B needs only a row *variable* argument, in a signature or a tycon-application
  field.

## 5. Grammar

Two additions in `grammar/Wok.cf`, both reusing `row`:

1. A parameter form. Widen the tycon parameter list from `[VarId]` to a list that also admits
   `(row VarId)` — a new `TyParam` category:
   ```
   TPPlain.  TyParam ::= VarId ;
   TPRow.    TyParam ::= "(" "row" VarId ")" ;
   separator TyParam "" ;
   ```
   and change `DData`/`DExternData`/`DExternType` to use `[TyParam]` instead of `[VarId]`. Every
   existing all-`VarId` declaration still parses (a `VarId` is a `TPPlain`).
2. A type-argument form. Add a `Type2`:
   ```
   TRowArg.  Type2 ::= "(" "row" VarId ")" ;
   ```
   `(row e)` cannot be confused with `(Type)` (`TParen`) — a parenthesized type can't start with the
   keyword `row`.

Grammar change ⇒ BNFC regen + reapply the 3 manual patches (`grammar/Wok.cf` top comments) + confirm
the shift/reduce conflict count does not increase (baseline 31 on the patched parser). `reorderDecl`
and any exhaustive `Decl`/`Type` matches gain the new constructors where needed (the `-Werror`
worklist surfaces them). The pretty-printer (BNFC `Print.hs`) round-trips the new forms; if a
parse-golden in `test/examples/` is added, accept its golden.

## 6. Elaboration

- **`TyConInfo` carries real per-parameter kinds.** `tcKind :: Kind` is already a full kind but
  `processDataDecls` builds it all-`*` (`foldr KArrow KStar (replicate arity KStar)`, `Infer.hs:854`).
  Build it from the declared params: each `TPPlain` contributes `KStar`, each `TPRow` contributes
  `KEffect`, so `tcKind = foldr KArrow KStar (map paramKind params)`. (Equivalently store an explicit
  `[Kind]` param-kind list on `TyConInfo` if that reads cleaner — decide in planning.)
- **Parameter binding + constructor quantifiers.** A `(row e)` param binds `e` as a `KEffect`
  quantifier — recorded `(i, KEffect)` BOTH in the tycon's kind AND in each constructor's scheme
  quantifiers. Note `registerCon` currently hardcodes all-`KStar` quantifiers (`Infer.hs:874, 908`),
  so it must consult the per-param kinds too, or a constructor whose result mentions a row param gets
  a wrong (`KStar`) quantifier.
- **Use site.** A `(row e)` type argument (in a signature or a constructor field) elaborates to a
  `KEffect` variable. Inside a `data` declaration the arg's VarId resolves to the bound row param's
  slot; elsewhere it is a fresh `KEffect` variable — the same KEffect-var mechanism `eff e` already
  uses in a `with` clause. An ordinary (non-`(row …)`) type argument stays `KStar`. Thread this
  through `translateConArg` (constructor fields) and the `Abs.Type → Scheme` builder (signatures).

## 7. Kind-checking of tycon applications

Today the application checks verify only arity (`Infer.hs:542, 559, 947, 958` — `tcArity info ==
length args`). Extend them to also check kinds: for `T t1 … tn`, each argument `ti` must have the kind
`T`'s declared parameter `i` demands. The argument's kind is syntax-directed: a `(row e)` argument is
`KEffect`; every other surface type argument is `KStar`. A mismatch throws **`KindMismatch`** (added
in Slice A) — with a clear message naming the offending parameter, e.g. *"parameter `e` of `Box`
expects a row, but got type `U64`"*. (Improve the `KindMismatch` rendering to include the
parameter/tycon context; it currently carries just the two `CType`s.)

This is decidable and syntax-directed; it adds no inference (kinds are declared and checked, never
inferred). Decidability contract (foundation §7) holds: variable kinds remain `{KStar, KEffect}`; a
`(row e)` variable is `KEffect`, never `KArrow`; no higher-order unification is introduced.

## 8. `prettyCType` hardening (folded in from Slice A review)

DEFENSIVE (Slice B's row args are always row *variables* — `CTGen` — so concrete row *nodes*
`CREmpty`/`CRExtend` don't actually reach `prettyCType` until concrete-row args land; harden now
because it's cheap and the next step will hit it). Slice A's review flagged that
`prettyCType`'s row arms currently delegate to `prettyCRow` (yielding `""`/`"x,y,"`), which would
render a row-bearing type misleadingly. Harden them: render a row argument the way the row reads at a
type-argument position (reuse the effect-row printer so `Box (row e)` prints back faithfully), and
make any genuinely-unexpected row-as-top-level-type an `error`. Confirm round-trip pretty-printing of
a row-kinded application.

## 9. Robustness / gating (reuses existing machinery)

- `extern type`/`extern data` with a `(row e)` param remain **Embedded-only** (the existing Part-1
  gate): a `UserFile` declaring one → `ExternNotAllowed`. A user `data Box (row e) = …` is allowed
  (`data` is not gated) and is the runnable positive fixture.
- Same-name constructors (`data Box (row e) = Box …`) are the wok convention and unaffected.

## 10. Testing

- **Positive (runnable):** `data Box (row e) = Box U64`; a field-level use `data Pair (row e) = Pair
  (Box (row e))` (proves a `(row e)` argument inside a constructor field); `peek : Box (row e) -> U64`
  / `peek (Box n) = n`; `main = peek (Box 5)` → `5`. Type-checks and `--run`s. Golden-pinned
  (typecheck/anf/typed-anf/run).
- **Negative — row in a `*` slot (lead, unambiguous):** `Option (row e)` → `KindMismatch`.
- **Negative — `*` in a row slot:** `Box U64` → `KindMismatch` (assert the message names the row
  parameter, so the fixture doesn't read like "boxing a U64 is forbidden").
- **Gate:** a `UserFile` `extern type T (row e)` → `ExternNotAllowed`; the user `data Box (row e)`
  positive confirms `data` is allowed.
- **Decidability anchor (unit):** a tycon-application kind check accepts a `KEffect` arg in a row slot
  and rejects a `KStar` arg there (and vice-versa).
- **Regression:** the whole existing suite stays green; the coro run-examples (421/10/52/64) and all
  existing goldens are unchanged except any intentionally-added parse golden for the new syntax.

## 11. Build / verify

`cabal build`; `cabal test`; `cabal run -v0 wok -- <file> --run`. Grammar change ⇒ BNFC regen + 3
manual patches + shift/reduce count unchanged (31). Full-branch review before merge to `main`.

## 12. Scope

**IN:** the `(row e)` decl-param + type-argument grammar; `TyConInfo` per-parameter kinds + per-param
constructor quantifiers; a `(row e)` type argument (in signatures and constructor fields) elaborating
to a `KEffect` var that resolves to a bound row param inside a decl; kind-checked tycon applications
(`KindMismatch` with a contextual message); the defensive `prettyCType` row-arm hardening; the
fixtures above.

**OUT (deferred):** **effect-carrying arrow fields** (a constructor field `() -> a with eff e` — not
supported by `translateConArg` today; 4b″ doesn't need it, it threads `e` as a tycon argument);
concrete rows as type arguments (`Box {Log}`); applying the facility to
`Suspension`/`Step` (that's 4b″); any consumer (`Task`/`Stream`/scheduler); kind polymorphism or a
parameter usable at both `*` and `Row` (excluded by the decidability contract and meaningless when a
field fixes the parameter's role); kind *inference* of a parameter's kind from constructor-field usage
(annotate with `(row e)` instead); a compiler ban on same-name type/constructor (pressure-tested and
rejected — see `wok-constructor-naming-convention`).

## 13. Rejected alternatives

- **Syntax `(e : Row)` (kind annotation) or `(eff e)`.** Rejected in favour of `(row e)`: `row` is
  already the keyword for a row variable and `KEffect` is the unified row kind, so `row` is the
  accurate, existing-vocabulary spelling; `(e : Row)` adds a `Row` kind keyword AND still needs a
  use-site row marker; `eff` is narrower than the kind (it now also covers record rows).
- **Fold 4b″ into Slice B.** Rejected: keep the facility a small, test-proven step before the
  residual-row soundness work rides on it.
- **Concrete-row type arguments now.** Deferred (YAGNI) — only a row *variable* is needed to prove the
  facility; add concrete rows when a consumer needs them.
- **Banning same-name type/constructor (`data Box = Box`).** Rejected (would break record-elision
  sugar and all existing record decls; style-via-hard-error is heavy-handed). See the convention memo.

## 14. Open questions (settle in planning)

1. **`TyConInfo` shape:** derive param kinds from `tcKind` (decompose the `KArrow` spine) vs store an
   explicit `[Kind]` param-kind list. Prefer whichever reads cleaner at the application kind-check.
2. **`KindMismatch` payload:** it currently carries two `CType`s; add the tycon name + parameter
   index/name so the message can say "parameter `e` of `Box` expects a row". Minor error-type change.
3. **Parse golden:** whether to add a `test/examples/` round-trip golden for the `(row e)` forms (nice
   coverage) in addition to the typecheck fixtures.

---

## Kickoff prompt (paste into a fresh session)

```
Work on Slice B — ROW-KINDED TYPE-CONSTRUCTOR PARAMETERS for the wok language (repo /Users/zy/wokml):
let a tycon declare a parameter of kind Row (KEffect) via `(row e)`, apply it with a row-variable
argument `(row e)`, and kind-check applications (KindMismatch on a row/`*` slot mismatch). Prove the
FACILITY with TEST FIXTURES ONLY — no prelude/Suspension/runtime change (small step; 4b″ consumes it
later). Branch from main first (feat/slice-b-row-kinded-params). Standing rules: FULL-BRANCH review
before any merge to main; clarifying questions in PROSE (not multiple-choice). Spec:
docs/superpowers/specs/2026-06-10-slice-b-row-kinded-params-design.md.

Foundation already on main (Slice A, cb22b58): one kinded type-expression sort — a row is a `Type`/
`CType` of kind KEffect; `type Row s = Type s`/`type CRow = CType` aliases; row ctors CREmpty/CRExtend/
RowEmpty/RowExtend; `unifyVar` kind-checks → KindMismatch; decidability contract (variable kinds
{KStar,KEffect} only, no KArrow vars). Reuse `KEffect` as the row kind; reuse the `row` keyword.

SURFACE: `data Box (row e) = Box U64` (same-name ctor — wok convention, NO Mk); a field-level row arg
`data Pair (row e) = Pair (Box (row e))`; `peek : Box (row e) -> U64` / `peek (Box n) = n`;
`main = peek (Box 5)` => 5 (e is an inferred unconstrained row). NOTE: effect-carrying ARROW fields
(`() -> a with eff e`) are OUT — translateConArg rejects `with` in fields; 4b″ threads e as a tycon
ARGUMENT (Step's `Suspension a b r e` field), which is exactly this facility.
GRAMMAR: a `(row VarId)` param form on DData/DExternData/DExternType ([VarId] -> [TyParam]) and a
`(row VarId)` Type2; BNFC regen + 3 manual patches + shift/reduce count unchanged (31).
ELABORATION: TyConInfo per-param kinds (TPRow -> KEffect) AND per-param constructor quantifiers
(registerCon hardcodes all-KStar at Infer.hs:874/908 — fix); a `(row e)` type arg (in a signature or
a constructor field) elaborates to a KEffect var resolving to the bound row param inside a decl.
KIND-CHECK: extend the tycon-application arity checks (Infer.hs:542/559/947/958) to also verify each
arg's kind matches the declared param kind -> KindMismatch (give it a contextual message naming the
param/tycon).
ALSO fold in the Slice A follow-up: harden Infer.hs prettyCType row arms (rows can now reach a printed
type). PROVE: positive runnable Box fixture (=>5); negatives `Option (row e)` and `Box U64` ->
KindMismatch; UserFile `extern type T (row e)` -> ExternNotAllowed.

HOLD THE LINE: decidable + HM-principal, row-poly only, NO kind inference of param kinds (annotate),
NO kind polymorphism, NO concrete-row type args yet, NO Suspension change. Follow the same-name
constructor convention in any wok source.
```
