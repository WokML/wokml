# M2a-2 — the reasoning chain: from "promoted region" to shared-env recursive closures

Status: design rationale, companion to
`2026-06-15-m2a-2-shared-env-recursive-closures-design.md`. Date: 2026-06-15.
Author: brainstorm with Claude.

This document records *how* the M2a-2 design was reached and, crucially, *why the
first realization (the "promoted region" via the uncounted knot) was rejected*. It
is deliberately a narrative, in layman terms where useful, so the decision is
durable and re-litigable. The settled design lives in the companion spec; this is
the journey and the discarded alternatives.

Notation used throughout:

- `══>` a **counted** edge (the reference count tracks it).
- `┄┄>` an **uncounted** edge (a knot link or a borrow; not tracked).
- `[X]`  a heap cell. `( )` a scope boundary.

---

## 1. The problem, in plain terms

A `letrec f … g …` of mutually-recursive *local* functions (`f` calls `g`, `g`
calls `f`) is a clump that the compiler today allocates as **one cheap "paper
plate" — an uncounted region**:

```
   scope: the letrec body
   ════════════════════════════════════════
     region R
       ┌───────────────────────────┐
       │    [f] ┄┄┄┄┄> [g]          │
       │        <┄┄┄┄┄              │   ← knot edges: UNCOUNTED
       └───────────────────────────┘
   ════════════════════════════════════════
   at scope exit  →  throw the whole plate away (free [f], free [g])
```

It is cheap because there is no per-cell counting, and the mutual `f ┄┄> g ┄┄> f`
knot is left **uncounted** — if you counted it you would get a refcount **cycle**
(each keeps the other above zero forever; plain reference counting cannot reclaim a
cycle). The plate dodges this: discard the whole thing at scope exit.

The cheap model assumes *born-here-dies-here*. **Escape** breaks that assumption: a
member is returned, stored in a constructor/record/list, or captured by a closure
that itself leaves the scope. Then throwing the plate away frees siblings that the
escapee still points at — a **use-after-free**; or never freeing it — a **leak**.
M1.5/M2a-1 made the cheap model airtight by *rejecting* every escaping shape. M2a-2
is about admitting them.

The four historical deferrals (M1.5 numbering): **#1** a member *consumes* (moves)
an enclosing capture; **#2** a member captures an enclosing local AND a member
escapes; **#3** an inner group captures an outer group's member (cross-region);
**#4** a standalone closure captures a sibling and escapes.

---

## 2. First realization considered — and REJECTED: the "promoted region" via the knot

The natural first idea (and the one sketched in the M2 umbrella spec §4.2): when a
member escapes, **promote** the whole clump from a throwaway plate to a single
genuinely **counted unit**. Keep the knot edges uncounted; put one shared refcount
on the *whole box*; count only the references that come in *from outside*; free the
whole box when that count hits zero.

```
                    ┌──── promoted region R (the "unit") ────┐
   caller ══════C══>│   [f] ┄┄┄┄┄> [g]                       │
                    │       <┄┄┄┄┄                            │  ← knot STILL uncounted
                    │   [f] ═══════════> [c]  (captured local)│  ← owned by the unit
                    │   [g] ═══════════> [c]                  │
                    └────────────────────────────────────────┘
            shared count  C = (number of external refs into the box)
   last external drop → C reaches 0 → free [f],[g],[c] together
```

This **works** and we fully worked out its mechanics: a store-side shared count
keyed by region id; `incref`/`dropAddr` redirect to that count for promoted
members; a **parent-region-aware `countedChildren`** (skip *intra-region* knot
edges and statics, but *keep* an external edge that points into a promoted region);
free-as-unit at zero; a `__rc_promote` marker primitive to flip a region and seed
the count; "borrow on call-head / own on escape" member accounting in Perceus.

Its soundness rests on a bespoke invariant: **every counted edge points from a
younger allocation to an older one; the only age-violating edges (the knot) are
uncounted, hence acyclic.** True, but *ours to prove and maintain*.

### 2.1 Why we rejected it

Four reasons, compounding:

1. **It is bespoke machinery the real backend will discard.** A compiled backend
   does not represent mutually-recursive locals as cyclic closure cells at all (see
   §3). The promoted region is scaffolding specific to the *current interpreter's*
   choice to bake siblings into each closure's environment.

2. **It demands a novel soundness argument.** The age-order / no-counted-cycle
   invariant is hand-built and must be actively maintained as the code evolves.
   M2a-1's five latent UAF/double-free/leak bugs **all lived in exactly this kind of
   bespoke RC seam**, not in the Perceus core. Adding more bespoke seam is adding
   more of the surface where bugs hid.

3. **It carries redundant structure.** Each member cell independently holds the
   enclosing captures, so a capture shared by *k* members needs a multiset
   accounting (`capOcc`/dups) to be freed *k* times. That whole bookkeeping exists
   only because the knot model duplicates captures across N cells.

4. **In an interpreter, it does not even buy genuine simplicity.** We tried to
   "simplify" by going to a shared-environment model directly, and found that a
   *naive* shared env in an environment-machine interpreter **collapses straight
   back into the promoted region** (see §4). The real simplicity of the shared-env
   model is a property of *compilation* (static code pointers), not of the idea.

The decisive realization: the promoted region is what you are *forced* into when you
keep manufacturing the cyclic closure cells and then have to manage the cycle. The
better move is to **not manufacture the cycle in the first place.**

---

## 3. The Koka insight: recursion lives in the *code*, not the *data*

Koka (Perceus, Leijen et al.) never builds the cycle. The key is that two different
things can be "recursive", and only one of them makes a heap cycle:

- **Recursive *data*** (lists, trees) is *inductive* — finite, built bottom-up, so a
  value can only point at *older* values. Acyclic by construction.
- **Recursive *functions*** are recursion in *control flow*. Storing each function as
  a closure whose environment holds the *other function's closure* is what
  manufactures the cycle — an implementation artifact, not something the program
  asked for.

Koka keeps the mutual reference in the **code**:

- A function compiles to **static code** (a C function — immortal, never
  refcounted). A *closure* is a heap object `{ code: &f_static, env: <captured data> }`.
- A recursive/sibling call `f → g` is a **known call**: a direct call to `g`'s static
  code, passing the shared environment explicitly. It is **not** a lookup of a `g`
  closure stored in `f`'s environment. So a closure's `env` holds only captured
  *values*; it never holds a sibling closure. The `f → g` link is a code pointer
  baked into `f`'s instructions — and code pointers are not counted heap edges.

```
   [f-closure] ─code→ f_static (immortal)     the f→g recursion lives HERE,
       │ env                                   as a direct call in f_static —
       ▼                                        NOT as a heap edge
   [captured data]  ◄── [g-closure] env
       (older values; DAG, no cycle)
```

The linchpin is the **known-call vs. unknown-call** distinction. *Known* (callee
statically determined — self/sibling/top-level): direct jump, no closure, no heap
edge. *Unknown* (callee is a first-class value you received): indirect call through
the closure's code pointer. **All recursive edges are known calls**, so recursion
never becomes a counted heap edge.

Where can a Koka heap cycle still form? Only through **mutable references** — and
Perceus explicitly does *not* collect those (acknowledged limitation; you leak or
avoid them). This is exactly the boundary our own M2 spec §7.1 already drew (pure
data + functions = RC-complete; genuine cell-mutation is the one cycle source,
deferred). Everything in wok's pure fragment is acyclic by construction.

---

## 4. The trap: a *naive* shared env in an interpreter collapses to the promoted region

We initially said "an interpreter has no code labels, so we can't do Koka's trick."
That was **wrong**, and correcting it is what unlocked the design. But first, the
trap that the correction has to clear:

An environment-machine interpreter resolves every name through an environment to a
heap value. If you try shared-env naively — `C_i = (code_i, E)` with `E` a shared
env — and then ask "when `f` is called and its body needs sibling `g`, where does
`g` come from?", the options are:

- look `g` up in `E` ⟹ `E` must hold the member closures ⟹ `E ┄> C_j ══> E` ⟹
  **cycle again**; or
- have `E` hold members by an *uncounted* back-reference with a single counted
  handle ⟹ **that is exactly the promoted region**, with the count reified on a
  header cell `E` instead of a region-id map.

So done naively in an interpreter, shared-env *is* the promoted region. They are the
same mechanism. The genuine difference Koka enjoys comes from **code pointers**, and
the question is whether an interpreter can have those.

---

## 5. The unlock: the interpreter *can* have code pointers — it already does

It can. wok's RC interpreter already installs **top-level binds at static, immortal
(negative) addresses**; a reference to a top-level function is, operationally, a code
pointer — uncounted, never dropped. We simply never used that mechanism for *local*
recursive groups; `LetRec` evaluation instead bakes siblings into each closure's
env (the knot).

So we give the interpreter the one thing it was missing: an **inline recursive-member
value** that resolves a sibling to *code* (immortal) plus a *shared env*, not to a
cyclic closure cell:

```
   RVRecMember  groupAddr(static)  index  envAddr(counted)
```

- `groupAddr` points at the group's code, installed once as a static immortal cell
  (the `[(Binder,[Binder],Expr)]` is part of the IR — immortal, like a code label).
- `index` says which member.
- `envAddr` points at `E`, the **one shared env cell** holding the captured locals.

Because member bindings are now **inline values, not heap cells**, there are no `C_i`
cells to knot together. Sibling resolution at call time reconstructs
`RVRecMember(groupAddr, j, E)` **inline (no allocation)** and enters its code
directly — a known call. The only heap cell in the group is `E`. The picture:

```
   member values (inline):   RVRecMember(g,0,E)   RVRecMember(g,1,E)
                                       │                    │
                                       ╚════════ counted ═══╝
                                                  ▼
                                                [E]  ══> captured locals  (DAG)

   nothing in the heap points back at a member value (they are inline, copied,
   never pointed-at) ⟹ the heap is ACYCLIC by construction.
```

Ordinary refcounting on a DAG. No region, no promotion, no shared-count redirect, no
parent-aware `countedChildren`, no age-order invariant to maintain. **#3 (both
sub-cases) falls out for free**: an inner member capturing an outer member just
stores that outer member's `RVRecMember` in `E_inner`, giving `E_inner ══> E_outer`,
an ordinary counted DAG edge (inner is younger).

---

## 6. The synthesis: "promoted region" is the *spec*; "shared env" is the *realization*

This reconciles the whole dialogue. They were never competing options:

- **"Promoted region"** is the *semantic story / spec vocabulary*: a clump of
  mutually-recursive bindings plus its captured environment, treated as one unit,
  that gains a refcounted lifetime when it escapes its scope.
- **"Shared env + code pointers"** is the *concrete acyclic realization* of that
  exact notion.

```
   PROMOTED REGION (semantic)            SHARED-ENV REALIZATION (concrete)
   ────────────────────────────         ──────────────────────────────────
   the clump's single lifetime      ⟺    refcount of the one env cell E
   "external ref into the unit"     ⟺    a live RVRecMember (or wrapper) on E
   shared count → 0 ⇒ free unit     ⟺    E.rc → 0 ⇒ free E + captured locals
   internal knot (uncounted)        ⟺    code pointers (no heap edge at all)
   captured enclosing locals        ⟺    fields of E (held ONCE, no multiset)
```

The single place the two *differ* is informative: the knot model holds a shared
capture *k* times (multiset); the shared-env model holds it **once** in `E`. Forcing
the promoted region to map onto the shared env therefore tells us to **drop the
multiset accounting and share captures through one env** — strictly simpler.

The payoff is twofold, and the second matters most:

1. **Clean implementation** — one env cell (or none, if the group captures nothing),
   members inline, recursion via code pointer, escape via ordinary closure, free at
   `E.rc → 0`. The region apparatus and the multiset capture accounting *retire*.
2. **Clean soundness by *mapping*, not bespoke proof** — the design is *bisimilar to
   acyclic Perceus* (Koka's settled, published model). Soundness reduces to "ordinary
   reference counting on a DAG", which the literature already establishes. We are no
   longer defending a hand-built invariant on the seam where M2a-1's bugs lived.

---

## 7. The sub-problem discovered while writing it up: the calling convention

Working the realization out concretely surfaced one genuine sub-decision. A **bare**
escaped `RVRecMember` cannot keep a uniform calling convention:

- Calling a recursive member must **borrow** it (not consume), because the recursion
  needs `E` alive across all the recursive calls — consuming the member value on
  call would free `E` mid-body and break sibling resolution / cascade into a UAF.
- But an escaped member, called from some *other* function, is — to the pass at that
  call site — just a value of function type, indistinguishable from an ordinary
  closure (whose calls *consume*). The pass cannot statically tell which convention
  to use.

Concretely, with a bare escaped member and the current consume-on-call convention:

```
   make () = letrec f n = … g(n-1) ; g n = … f(n-1) in f     -- returns f
   main    = let ff = make() in ff(3)
```

`ff = RVRecMember(g,0,E)`. At `ff(3)` the pass assumes consume (current convention),
so it emits no drop for `ff`. If the runtime *borrows* `RVRecMember`, `E` is never
released ⟹ **leak**. If the runtime *consumes* it, `E` is freed before `f`'s body
runs `g(2)` ⟹ **use-after-free**. Either way, broken.

> **Superseded (2026-06-15).** §7.1/§7.2 record the two candidates as first weighed.
> The decision later **flipped to uniform borrow-on-call** (§7.2), which eliminates the
> wrapper entirely and — orthogonally — admits #1. See the §10 addendum for the final
> lock-in and the reasoning.

### 7.1 First candidate (now the contained fallback): closure-convert at escape (a wrapper)

Internal recursion stays code-pointer / known-call (efficient, no knot). At the
moment a member **escapes** (a non-call-head occurrence — exactly what the existing
`escapingAtoms` / `nonHeadOccs` analysis already detects), wrap it into an **ordinary
`NClosure`** that captures the `RVRecMember`:

```
   f escapes  ⟹  W = NClosure { captures: [RVRecMember(g,0,E)], params: ps_f,
                                body: apply the captured member to params }
```

Externally `W` is a bona-fide closure — the **existing consume-on-call convention is
unchanged**, the pass treats it ordinarily, and `W ══> RVRecMember ══> E` stays a
DAG. Calling `W` (consume the wrapper) increfs its capture per the existing NClosure
consume dance, so `E` survives the body; sibling calls inside are known calls;
dropping the last wrapper releases `E`. Walking the example above: `ff` is a wrapper;
`ff(3)` consumes the wrapper, runs `f` with `E` alive (held by the capture), `g(2)`
resolves via the code pointer, and the wrapper's last drop frees `E`. Balanced.

This keeps the change **contained**: add `RVRecMember` for internal sibling
resolution, and a wrapper (eta/closure-conversion) at escape sites. No change to the
ordinary closure calling convention.

### 7.2 Chosen resolution (see §10): uniform borrow-on-call

Make *every* function call borrow the function value (the pass inserts an explicit
drop for a function value at its last use; `enterRC` never consumes). Uniform,
Koka-aligned, less RC traffic on hot calls, and — the decisive property — it **removes
the need for wrappers**: under a single borrow convention a bare `RVRecMember` can
escape and be called externally because the external call site *also* borrows, so the
"pass can't tell a member from a closure" problem dissolves. Its cost is blast-radius:
it changes the calling convention for *all* closures and the move-on-call-head logic in
Perceus, touching more of M1 and risking a longer red-test window. **This is the option
locked in** (see §10 and the design spec Decision D1): the cleanest, most complete,
backend-aligned end state, with the wrapper kept only as the recorded contained
fallback.

---

## 8. Honest cost — this is a representation change, not a small patch

The shared-env realization is the right end state, but it reopens M1's closure model
and is bigger than the original "promoted region patch":

- **Suite B goldens regenerate.** A group of N members now allocates **one** env cell
  (or **zero**, if it captures nothing) instead of N member cells; escapes add a
  wrapper cell each. The exact alloc/free/peak numbers change wholesale.
- **It reopens M1's closure representation** ([[rc-perceus-interpreter-plan]] called
  the region model "RC complete for wok"); this evolves it toward the
  backend-aligned representation.
- **Fresh corners need run-the-exploit verification**: partial application / currying
  of a recursive member, over-application, the #1 consuming-capture claim, and
  confirming shared-env results still match the reference interpreter's lazy-knot
  closures (output oracle — expected fine, must check).

But the verification is *easier* than M2a-1's, because we check "does it match the
trusted acyclic-Perceus / shared-env model" rather than "is our novel cycle
management sound."

---

## 9. One-line summary

Do not manufacture the cycle. Keep recursion in the **code** (a code-pointer
`RVRecMember`, known calls), keep the data a **DAG** (one shared env cell), and let
**ordinary Perceus** reclaim it. "Promoted region" survives as the intuition and the
spec's vocabulary; "shared env + code pointers" is how it actually runs; soundness is
a *mapping onto acyclic Perceus*, not a bespoke proof. The knot realization is
rejected because it is bespoke scaffolding the backend discards, it re-creates the
very seam where M2a-1's bugs hid, and it does not even buy real simplicity in an
interpreter once you realize the interpreter can carry code pointers.

---

## 10. Addendum — final lock-in: uniform borrow-on-call + #1 admitted via borrow-passing

After settling the realization we asked the sharper question: *between the calling
convention (D1) and consuming captures (D2), which buys more completeness?* Answering
it changed the decision and, surprisingly, closed #1.

### 10.1 D1 and D2 are orthogonal — and completeness lives in D2

They are different axes:

- **D1** — the calling convention for a function *value* (a member or closure):
  borrow it on call, or consume it.
- **D2** — how a member body treats an enclosing *capture* it consumes (moves out).

Completeness (which programs are admitted) is decided by **D2**, not D1: both D1
options admit the *same* set of programs. The two D1 options differ only in
**mechanism count and blast radius**, not in what they accept. So "which is more
complete" does not separate the D1 options — the lever is D2.

### 10.2 #1 is genuinely solvable: the dynamic, per-execution dup

M2a-1 deferred #1 because its dup-per-consuming-use was emitted at the **build site**
(statically, before the `letrec`), so it had to *guess* the runtime consume count —
SUM over-counted (leak), MAX under-counted (use-after-free), and no static number is
right for arbitrary call patterns.

The shared-env model moves the dup to the **consuming use site, inside the member
body**, so it runs **once per actual execution**. The capture lives once in `E`; member
bodies **borrow** it; a consuming use **dups it on the spot**. The runtime count then
matches by construction. Trace the exact M2a-1 counterexample — two members, both base
cases consume `cap`, recursion terminating in exactly one base case:

```
   E = {cap}          cap.rc = 1  (owned once by E)
   f 2 → g 1 → f 0    known calls; each BORROWS cap from E (no count change)
   f 0 base: CONSUME cap → dup cap (cap.rc 1→2), move the dup out
   ...exactly ONE base case fires → exactly ONE dup → one ref escapes
   result dropped → cap.rc 2→1 ;  E dropped at scope exit → cap.rc 1→0 → freed
```

Balanced: no leak (M2a-1's SUM pre-dup'd twice), no UAF (MAX would under-dup). This is
exactly the **borrow-passing** the M2a-1 deferral named as the prerequisite — and the
shared env supplies it for free, because `E` is the shared owner that *lends* the
capture to each invocation. It is also bog-standard Perceus: a borrowed value used in a
consuming position gets a dup. #1 falls out of treating `E`'s fields as **borrowed**
into member bodies. (Still gated on run-the-exploit before the guard comes down — we do
not remove a soundness guard on faith — but the mechanism is no longer speculative.)

This works identically under either D1 option (captures live in `E` and are borrowed
into bodies regardless of how the function value is called), confirming the
orthogonality.

### 10.3 Uniform borrow-on-call eliminates the wrapper

The wrapper (§7.1) existed *only* to bridge a problem specific to consume-on-call: the
pass cannot statically tell an escaped `RVRecMember` from an ordinary closure, and the
two would need different conventions (borrow vs consume). Under **uniform
borrow-on-call** that distinction is moot — *every* call borrows the function value —
so a bare `RVRecMember` may escape and be called externally with matching semantics. No
wrapper, no per-escape allocation, one convention everywhere. The runtime `enterRC`
still dispatches on value kind (reconstruct the sibling scope for an `RVRecMember`; bind
captures for an `NClosure`) but **neither consumes** the value; the function value is
dropped at its last use by the pass, like any other value. (Borrow applies to the
function *value* at the call head; argument-passing keeps its current ownership
treatment — borrowed-parameter analysis is a separate, deferred Perceus feature.)

### 10.4 Decision (locked, 2026-06-15)

- **D1 = uniform borrow-on-call.** The wrapper is recorded as the contained fallback if
  the blast radius proves unacceptable.
- **D2 = #1 admitted** via borrow-from-`E` + dup-on-consume, gated on run-the-exploit
  verification before `consumeViol` is removed.
- **Net:** the analysis admits **all four** historical deferrals (#1/#2/#3/#4) with a
  single uniform mechanism — everything borrows, recursion lives in the code, the data
  is a DAG — and soundness is a **bisimulation onto acyclic Perceus** (with borrowed
  function values and borrowed captures, both standard Perceus features), not a bespoke
  invariant.
- **Cost (accepted):** reworking the calling convention for all closures (`enterRC` +
  the move-on-call-head logic in Perceus) is the bigger M1-closure change. Taken
  deliberately for the cleanest, most complete, backend-aligned end state.
