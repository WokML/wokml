## Code Style
- Follow the Haskell Style Guide
- Use explicit export lists for all modules
- Prefer qualified imports for clarity
- Use hlint suggestions unless they reduce readability
- When doing hlint, please ignore the generated code in the directory 'src-generated'.
- Keep functions small and composable
- Write type signatures for all top-level definitions
- Be mindful of lazy evaluation and space leaks

## Type System
- Leverage the type system to eliminate invalid states
- Use newtypes for domain types instead of raw primitives
- Prefer sum types (ADTs) for modeling alternatives
- Use phantom types or GADTs when extra type safety is needed
- Avoid partial functions (head, tail, fromJust) — use safe alternatives

## Testing
- Use Hspec for unit and integration tests
- Use QuickCheck for property-based testing
- Test pure functions exhaustively — they're easy to test
- Use tasty as the test framework runner

## Regarding to over-engineering
Avoid over-engineering. Only make changes that are directly requested or clearly
necessary. Keep solutions simple and focused:

- Scope: Don't add features, refactor code, or make "improvements" beyond what was
asked. A bug fix doesn't need surrounding code cleaned up. A simple feature doesn't need
extra configurability.

- Documentation: Don't add docstrings, comments, or type annotations to code you didn't
change. Only add comments where the logic isn't self-evident.

- Defensive coding: Don't add error handling, fallbacks, or validation for scenarios
that can't happen. Trust internal code especially tested pure code. Only validate at system
boundaries (user input, external APIs).

- Abstractions: Don't create helpers, utilities, or abstractions for one-time
operations. Don't design for hypothetical future requirements. The right amount of
complexity is the minimum needed for the current task.

## Regarding to testing
Please write a high-quality, general-purpose solution using the standard tools
available. Do not create helper scripts or workarounds to accomplish the task more
efficiently. Implement a solution that works correctly for all valid inputs, not just
the test cases. Do not hard-code values or create solutions that only work for specific
test inputs. Instead, implement the actual logic that solves the problem generally. And
please don't create loopholes or temporary fixes to the problem domain.

Focus on understanding the problem requirements and implementing the correct algorithm.
Tests are there to verify correctness, not to define the solution. Provide a principled
implementation that follows best practices and software design principles.

If the task is unreasonable or infeasible, or if any of the tests are incorrect, please
inform me rather than working around them. The solution should be robust, maintainable,
and extendable.

## Regarding to output styles
Because this is a research frontier language research project so you have to use layman
terms to explain to me so I can better understand what the brainstorm context, and how
to plan better and work with you with better understanding.

## Regarding to the development workflow
Always do this in order:
  1. Brainstorm
  2. Write spec
  3. Check if it is consistent (without misalignments) in the context. Correct it
  4. Generate spec, let user review the spec, then always run with subagents pipeline
  5. After that always review and check if the tests are well-formed or not, that is:
      * without temporary fix
      * is coherent to the spec's goal
      * is reviewed and documented
      * run '/code-review' for me.
  6. Fix it