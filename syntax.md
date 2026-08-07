
## This is a note for myself.

I want to check the CDR coding that is to allocate a sane size of list and when user is writing recursive function that requires list we can try to allocate in batch to remove the pointer chasing here.

## Effect / continuation compilation (notes from 2026-06-05 design chat)

- The CEK ANF interpreter is defunctionalized CPS already, so it is stackless: the `Kont` ADT reifies the user call stack as immutable heap data and `run` is a flat trampoline. Concurrency is just scheduling many `Config`s through that one loop; a fiber is a parked continuation.
- A join point IS the direct-style compilation of a one-shot + tail + non-escaping continuation. Slogan: contify when you can, reify when you must.
- Today's auto-resume (tail-resumptive, one-shot) is fully contifiable -> compiles to a jump, no closure. The reified/CPS path is needed ONLY for escaping continuations (async/await, generators) and multi-shot (amb/backtracking).
- Default second-class (contified, direct); promote to first-class (reified) only where escape analysis + multiplicity analysis prove escape or multi-shot. Sane fast default, analysis upgrades the rare case, never an annotation. (Effekt's idea, made conditional.)
- Stackless selective CPS over stackful fibers (the OCaml 5 route): our continuations are immutable so multi-shot is re-apply not stack-copy; and selective CPS needs effect types, which our row types give us (OCaml lacked them, which is why it went fibers).
- Dispatch: replace the runtime handler walk (`findHandler`) with evidence passing (an indexed call); it also makes the contify target statically known.
- Duplication worry: effect-polymorphic fns that might carry a controlling effect get a CPS twin -- contagious up the call graph, an inlining barrier, lands on the most-reused combinators (map/fold/traverse). OPEN/CLOSE type simplification prunes the >80% that only LOOKED polymorphic; the genuine higher-order spine is the irreducible residue.
- Runtime: a default scheduler handler at `main` gives dispatch-to-runtime with no ceremony, and being a handler it is replaceable (e.g. a deterministic test scheduler). Capabilities = required effects in the row (must be handled, DI); hints = ignorable effects/attributes (correctness must survive dropping every hint). Real OS async needs one readiness primitive as a runtime addition; park/unpark control flow is all in-language.

## resume: auto by default, bind to control (2026-06-05, final)

Default = no binder = auto-resume (tail-resumptive); body is the OPERATION's result:

    main =
      with { Ask.ask -> 41 }      -- continues automatically with 41
      useAsk ()                   -- => 42

Declare a control clause with `once` to bind the continuation `k`; body becomes
the ANSWER type. The keyword states the law: the clause resumes AT MOST ONCE.

    once Exn.throw msg k   -> None                       -- 0x: abort (exception)
    once Choice.flip   k   -> append (k True) (k False)  -- Nx: rejected, one-shot law
    once Async.await fut k -> Blocked fut k              -- 1x-deferred: hand k off, resume later (async)

`k` is an ordinary name (no magic `resume`); `once` declares WHICH binder it is,
not how many times it runs -- that stays inferred. A value clause is written
`return v -> e`. Full spec:
docs/superpowers/specs/2026-06-05-effect-handler-surface-syntax.md