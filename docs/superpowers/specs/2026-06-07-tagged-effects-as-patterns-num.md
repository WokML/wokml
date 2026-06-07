# Ergonomics spec: tagged effect instances, `@` as-patterns, and a deferred `Num` class

Date: 2026-06-07
Status: **Design intent for a future session.** Not yet planned or scheduled. This
document captures three related ergonomic ideas so a later session can brainstorm
each to a converged design and write an implementation plan. Two of them share the
`@` token; the third (`Num`) is deferred pending the number-system design.

Reads with: `docs/koka.md` (§"Nested handlers of the same effect" — scoped/duplicate
labels), `docs/superpowers/specs/2026-06-05-effect-handler-surface-syntax.md` (§11
non-goals: `inject`/duplicate labels), `docs/superpowers/specs/2026-06-07-effects-slice-4a-parameterized-handlers-design.md`
(the in-block `name = init` param form that a tag composes with), the `Eq` dictionary
slice (memory `typed-core-next-eq-dictionaries`).

## 0. The `@` thread — one rule, two features

`@` is a **postfix naming operator**, uniform across the language:

> **`subject@name`** — the subject on the left is named/tagged by the lowercase
> identifier on the right.

- `State@count` = "the `State` effect, **named** `count`" (an effect instance).
- `(Just y)@whole` = "this `Just y` pattern, **named** `whole`" (an as-pattern).

The name is always **after** `@`. This is a **deliberate departure from Haskell/Scala**,
which write as-patterns name-first (`name@pat`): wok puts the name last so that the
*single* rule "`@` attaches a name on its right" covers both effect tags and patterns.
The cost is unfamiliarity to Haskell users; the win is one coherent rule (and a minor
readability gain — the match shape reads first, then its alias).

Both uses are `subject@VarId` but live in disjoint grammatical positions (effect
references / rows vs. patterns), so they never ambiguate each other — see §3 for the
one real obstacle (lexing: `@` is currently a `VarSym` character).

---

## 1. Tagged effect instances (`State@tag`)

### Problem

Today a computation can hold only **one** instance of a given effect. Stacking two
`State` handlers doesn't give two cells: `findHandler` (`src/Wok/Interp/Machine.hs`)
routes an operation to the **nearest** handler covering `(effect, op)`, so the outer
`State` is unaddressable.

```
with state 0 in        -- a counter?
with state 0 in        -- a total?   both are just "State"; State.get hits the inner one
prog ()                -- the outer cell can never be reached
```

The current workaround (slice-4a docs) is one `State` over a record with field access
as a "lens" (`data St = St { count : U64, total : U64 }`). It works but **couples**
the cells into one hand-threaded value and loses the "two independent effects" framing.

### Proposed surface

A **tag** distinguishes instances of the same effect:

```
prog u =
  let _ = State@count.set (State@count.get + 1) in
  let _ = State@total.set (State@total.get + State@count.get) in
  ()

main =
  with state@count 0 in     -- instance tagged `count`
  with state@total 0 in     -- a second, independent instance tagged `total`
  prog ()
```

In the row these are two distinct labels: `... with State@count U64 + State@total U64`.
The untagged `State` remains valid and denotes the single default instance (back-compat).

### Recommended design: STATIC tags (compile-time labels)

A tag is a **compile-time label**, part of the effect's row identity — *not* a runtime
value or a Koka-style dynamically-generated instance (evidence). `State@count` and
`State@total` are distinct row atoms; row unification treats them as different labels.
This is exactly the **scoped/duplicate-label** facility the row theory already supports
(`docs/koka.md`: `⟨exc, exc⟩` is legal and distinct from `⟨exc⟩`); a tag is the
surface way to *name* which copy you mean. Static tags fit wok's invariants:

- **Decidable / HM:** a tag is a label, not a new type-system feature; row unification
  stays HM + row unification, just over `effect@tag` atoms instead of `effect` atoms.
- **Second-class handlers:** no first-class handler values, no evidence passing.

### The three layers to change

1. **Type system / rows (substantive):** a row label becomes `effect + optional tag`.
   Unify `State@count` only with `State@count`; discharge a `with State@count` handler
   removes exactly that label. The polymorphic tail rides through as before.
2. **Surface:** tag syntax on the handler (`with State@count { s = i ; … }` primitive;
   `with state@count 0 in` runner sugar) and on operations (`State@count.get`,
   `State@count.set x`). Untagged forms keep meaning the default instance.
3. **Runtime:** `findHandler` / `dispatchOp` match on `(effect, tag, op)` and route to
   the handler carrying the matching tag, not merely the nearest one.

### Open questions (settle in the future brainstorm)

- **Runner abstraction over a tag.** With static tags, `state@count` bakes the tag in
  syntactically, so the library `state` runner can't be polymorphic over a tag the way
  it is over `s`. Options: (a) tags only on the *inline* primitive + a per-tag runner
  the user writes; (b) a tag-parameterised runner form; (c) tags as a restricted
  type-level argument. (a) is simplest and matches "library author writes the inline
  form once" — but a user wanting a tagged cell may have to write the inline handler.
- **Tag scoping & shadowing.** Can the same tag be reused at different scopes (nested
  `with state@count` over another)? Likely yes (nearest wins per tag), mirroring the
  untagged rule.
- **Tag namespace.** Are tags global identifiers, per-effect, or per-module? Recommend
  per-effect, lexical (just a label after `@`).
- **Default-instance interaction.** `State` (untagged) vs `State@count` — distinct
  labels; a program may use both. Confirm coverage/lint still works per label.

### Scope honesty

This is the `inject` / duplicate-label family that the surface spec lists as a current
**non-goal** — it is a **row-system feature**, not a syntax tweak (the biggest of the
deferred effect items). Slice 4a deliberately left it forward-compatible: the in-block
param form already composes as `with State@tag { s = i ; … }`, so nothing is undone.

---

## 2. `@` as-patterns (`pat@name` — name LAST, per §0)

### What

**As-patterns**: match a structure *and* bind a name to the whole matched value. Per the
§0 rule, the name goes **after** `@` (`pat@name`), consistent with `effect@tag` — the
reverse of Haskell's `name@pat`.

```
-- match head/tail AND name the whole list `whole`
dedupHead : [U64] -> [U64]
dedupHead (x :: y :: rest)@whole = case x == y of
  True  -> dedupHead (y :: rest)     -- drop the dup, keep going
  False -> whole                     -- reuse the whole list, no rebuild
dedupHead other = other
```

Read it as "`(x :: y :: rest)`, named `whole`." Without as-patterns you either rebuild
the value (`x :: y :: rest`) or match twice. As-patterns pair naturally with the tuple
destructuring-`let` already shipped and are common in recursive / rewriting code.

### Grammar sketch

Add an as-pattern to the pattern grammar (`grammar/Wok.cf`), at the `AtomPat` level,
**name on the right**:

```
APAs. AtomPat ::= AtomPat "@" VarId ;     -- <atom pattern>@name; left-recursive, BNFC-friendly
```

(Match the left `AtomPat`, bind `VarId` to the same scrutinee; richer left patterns use
parens, e.g. `(Just x)@whole`, `(x :: xs)@whole`.) Elaborate by binding the as-name to
the scrutinee the inner pattern matched — reuse the existing pattern-binder machinery
(the path case-alternatives use). Verify the new left-recursive `AtomPat` rule leaves the
BNFC shift/reduce conflict count unchanged.

### Why it's not free

`@` is currently a **`VarSym` character** (`grammar/Wok.cf:450`), so a bare literal
`"@"` in a production collides with operator symbols — the same hazard documented for
`+` (promoting `+` out of `VarSym` "would break `fixity + left`, the type-level `a + b`
extension, and every `+` operator in source"). See §3 for the resolution.

---

## 3. The shared `@` token (the one real obstacle)

`@` must become a recognised delimiter in two positions (after a `ConId` effect head;
between a `VarId` and a pattern) **without** breaking operators that contain `@`. Two
routes, mirroring existing grammar decisions:

- **(A) Reserve `@`** — remove `@` from the `VarSym` character class and make it a
  standalone literal (like `::`, which is *not* a `VarSym` char and is a clean literal
  in `PCons`). Cost: any operator using `@` (`@`, `@@`, `<@>`, …) stops being a valid
  `VarSym`. Probably acceptable if no such operators are in use, and simplest to parse.
- **(B) Capture-and-restrict** — keep `@` in `VarSym`, accept it via `VarSym` in the
  specific productions, and have the elaborator restrict that `VarSym` to the literal
  `"@"` (exactly how `+` is handled for `TExtend`/`ERPlus`). Cost: more plumbing, but
  no global reservation.

Recommendation: **(A) reserve `@`** unless a concrete need for `@`-operators surfaces —
as-patterns and effect tags both want `@` as a structural delimiter, and reserving it
once serves both. Verify the BNFC shift/reduce conflict count is unchanged after the
change, and that the two positions (effect-ref vs. pattern) disambiguate cleanly (they
are in disjoint grammatical contexts, so they should).

Disambiguation note: both an as-pattern `AtomPat "@" VarId` (pattern position) and an
effect tag `ConId "@" VarId` (effect-reference position) now share the `subject@VarId`
shape (the §0 unification), so they are NOT told apart by their heads — `Con@x` is
structurally valid as either. They are disambiguated purely by **grammatical context**:
an as-pattern only occurs where a pattern is expected (case arms, function/lambda args,
`let`/`where` binders), an effect tag only where an effect reference is expected (rows,
and an `Effect@tag.op` perform in expression position). Patterns and expressions/rows are
disjoint categories, so the contexts never overlap. (This shared shape is a feature: one
`@` token, one parse rule for "name on the right," two positions.)

---

## 4. `Num` class — DEFERRED (pending the number system)

### Intent

A `Num` type class so numeric **literals are polymorphic** and arithmetic works across
numeric types, instead of the current hard-wiring (every literal is `U64`; see the
apologetic comment in `prelude/Std/Base.wok`). Shape, roughly:

```
class Num a where
  (+) : a -> a -> a
  (-) : a -> a -> a
  (*) : a -> a -> a
  fromInteger : Integer -> a      -- literal `5` desugars to `fromInteger 5`
```

### Why deferred

1. **The number system isn't decided yet.** What numeric types exist (U64/U32/signed/
   `Int`/floats?), literal **defaulting** (what does `5` mean with no other constraint?),
   overflow/wrap semantics, and conversions all need settling *first*. `Num` is a thin
   layer over those decisions and shouldn't front-run them.
2. **It needs return-type-dispatched method resolution.** `fromInteger : Integer -> a`
   (and any `mempty`-like constant) is selected by the **result type / context**, not by
   an argument — which the `Eq` dictionary slice never had to do (`Eq`'s methods take the
   class type as an *argument*). Solving this is the real machinery work, and it is
   **shared** with `Monoid`/`Default`/`Bounded`: doing it once for `Num` unblocks them
   all. Check feasibility against the existing `Eq` dictionary-passing
   (`typed-core-next-eq-dictionaries`) before planning.

### Dependencies before `Num` can be planned

- The number-system design (types, defaulting, overflow, conversions).
- Return-type/nullary-method dictionary resolution (the `fromInteger` case), reusable for
  `Monoid` etc.
- The known `Eq` limitations to clear first (no cross-module instances; the pattern-match
  backtracking gap) — see the `Eq` memory.

---

## Suggested order for a future session

1. **As-patterns** (§2) — smallest; mostly grammar + the `@` token decision (§3), reusing
   existing pattern-binder elaboration. Lands the `@` token that tags will reuse.
2. **Tagged effect instances** (§1) — the row-system feature; builds on the `@` token from
   step 1 and is the bigger lift.
3. **`Num`** (§4) — only after the number system is designed and return-type dispatch is
   prototyped; that machinery then also makes `Monoid` (general `Writer`) cheap.
