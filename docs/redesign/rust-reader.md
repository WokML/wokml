# The `once` continuation, for C/Rust readers

Companion to `spec.md` 1.1 (clause kinds) and C8. Audience: readers arriving
with C or Rust intuitions who want to know what `k` in
`once ask q, k -> ...` actually is. This note exists because of an inversion
of the D10 finding: everywhere else in this design, familiarity taught the
wrong law and the familiar word was banned (`ctl`, `Amb`, `final`). Here
Rust's ownership vocabulary teaches the RIGHT law unmodified — so we use it.

## The type that does all the work

```
k : FnOnce(T) -> R
```

where `T` is the op's result type (what the perform site receives) and `R`
is the handler's answer-out type (`Handler E a R`). Everything about `k`
follows from reading that type the way a Rust reader already does:

| wok | C/Rust reading | exact? |
|-----|----------------|--------|
| plain clause `get -> t` | ordinary function call into the handler; the arm body is the function body; auto-resume is its `return` | fully — plain arms compile to exactly that (contified: a jump and a stack slot) |
| `once ask q, k -> e` | `k: FnOnce(T) -> R`; calling is `resume`; a tail call only when in tail position | fully, via Rust; C needs "a one-shot `swapcontext` whose call returns when the whole other context finishes" |
| `abort throw e -> e` | `noreturn` / `longjmp` / `?` early-exit — the perform site is never returned to | fully — and capture elision makes the implementation match the intuition: no continuation is ever materialized |
| calling `k v` | `coroutine.resume(v)` — feed the suspended computation a value, run it, receive a result | with one caveat: see "resume-to-completion" below |
| the one-shot law | move semantics: calling `k` consumes it | fully — `FnOnce`, not `Fn` |
| E-AFFINE "consumed twice: first at 18:13, again at 19:5" | rustc E0382 "value moved here / used after move", both sites named | character for character |
| `k` is second-class (cannot escape the arm) | a lifetime bound: `k` is borrowed from the handler activation and cannot outlive it | close; wok checks it as a mode, not a lifetime |
| `var cur = init` baton | a field of the coroutine's driver struct; `:=` writes it | close; one-shot makes the slot uniquely owned, so it compiles to in-place update |
| `perform` / `E.op v` | `yield v` / `.await` — suspend here, deliver `v` upward | fully |
| `Suspension` / `Step` (the coroutine surface) | Rust's `Coroutine` object and `CoroutineState::{Yielded, Complete}` | fully — this, not `k`, is the step-wise analogue (see below) |

## What `k` actually contains

At a `perform`, execution stops at the perform site. The frames between that
site and the `handle` that intercepts it — not the whole stack, just that
delimited segment — become `k`. (OCaml 5 calls this segment a fiber and
links it off the heap; wok's interpreter reaches the same shape through
CPS, and the RC discipline owns the captured frames.) The arm then runs
INSIDE the handler with `k` in hand.

`k` has exactly three legal fates, and the clause kinds name them:

1. **Called** (`once`, at most once): the segment is reattached and runs.
2. **Dropped** (an abort path, or the whole `abort` kind): the segment is
   deallocated — RC frees the owned set; nothing runs. With the `abort`
   clause kind the segment is never even built.
3. **Stored** (moved into a `ContCell` via the explicit escape hatch):
   consumption is deferred, the affine obligation travels with it.

## Resume-to-completion: the one place the Rust prior needs adjusting

Rust's `resume()` returns at the NEXT suspension point, handing you
`Yielded(v)` or `Complete(r)`. wok's `k v` does something stronger: it runs
the rest of the computation TO COMPLETION under the same handler (deep
semantics — the handler rides along), and returns the FINAL answer `R`,
after the `return` clause. If the resumed computation performs again, the
arm re-enters recursively inside your `k v` call; you do not see the
intermediate suspensions.

When you want the Rust behavior — advance to the next yield and get a state
back — that is not `k`; that is the coroutine surface: `step` a
`Suspension` and match the `Step` (`Completed r | Suspended a rest`).

## Watching `k` work: the generator, traced

```
collect : Handler (Yield a) r [a]
collect = handler Yield
  once yield x, k -> x :: k ()
  return u       -> []

count lo hi = case lo == hi of
  True  -> ()
  False ->
    Yield.yield lo
    count (lo + 1) hi

main = handle collect in count 1 3
```

Step by step, with what each `k` holds:

```
handle collect in count 1 3
  count 1 3: 1 /= 3, so perform Yield.yield 1
    CAPTURE k1 = [ receive (); then run count 2 3; then finish the body ]
    arm: x = 1        ->  1 :: k1 ()
      k1 (): resume. yield 1 returns (). count 2 3: 2 /= 3, perform yield 2
        CAPTURE k2 = [ receive (); then run count 3 3; then finish the body ]
        arm: x = 2    ->  2 :: k2 ()
          k2 (): resume. yield 2 returns (). count 3 3: 3 == 3 -> ()
            body COMPLETE with () -> return clause: return u -> []
          k2 () = []                -- the final answer of that resumed run
        arm value: 2 :: [] = [2]    -- becomes the answer of k1's run
      k1 () = [2]
    arm value: 1 :: [2] = [1, 2]
main = [1, 2]
```

Read the shape: each `k i ()` call RETURNS (this is the part a tail-call or
goto reading cannot express — `x :: k ()` conses onto a value that comes
back), and what it returns is the answer built by the arms and the `return`
clause of everything downstream. The list is assembled on the way back up,
exactly like a recursive function returning — because that is what resuming
a continuation under a deep handler is.

Affine accounting for the same trace: `k1` consumed once (inside the depth-1
arm), `k2` consumed once, nothing consumed twice, the `return` clause
consumed no continuation at all — `--dump-multiplicity` on the running v1
twin reports `Yield.yield : 1`.

## Memory, in one paragraph

Because `k` is affine and second-class, the RC story is simple: the captured
frames are an owned set. Call `k` and ownership moves into the resumed
computation (resume move-out); drop `k` and the set is freed on the spot
(abort-free drop); declare the clause `abort` and the set is never built
(capture elision). There is no garbage collector behind any of this — the
one-shot law is what makes plain reference counting sufficient.
