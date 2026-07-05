#!/usr/bin/env bash
set -euo pipefail

# One-shot runtime oracle run (one-shot spec section 9 / effect-safety plan
# Phase D). Re-runs the FULL test suite with WOK_DEBUG_ONESHOT=1, so every
# continuation the reference machine captures carries a used-flag and a
# second application of the same continuation aborts with OneShotViolation.
# The whole corpus thereby doubles as a differential check on the static
# one-shot multiplicity law.
#
# Expected shape of the run, asserted below (set-equality, so drift in either
# direction fails loudly):
#
#   * every static-law-ADMITTED program stays green (a new failure here = a
#     genuine law miss, the finding the oracle exists to surface);
#   * EXACTLY six run-golden multishot fixtures fail, each with
#     OneShotViolation. These are law-REJECTED programs (`--run` refuses
#     them; the run-golden harness deliberately uses the UNCHECKED
#     elaborator to pin the machine's free multi-shot capability), so under
#     the oracle they are six end-to-end negative controls: genuine
#     multi-shot arms with the frontend check bypassed MUST abort. A missing
#     failure = the oracle decayed (e.g. flag allocation collapsed to a
#     shared ref again); an extra failure = a law miss or oracle false
#     positive. Either way this script exits non-zero.
#
# The SEVENTH multishot fixture, 37-known-reentrant-multishot-limitation, is
# deliberately NOT in the list: it is law-rejected but dynamically
# SINGLE-shot — the pinned first-leaf-only re-entrancy limitation abandons
# the pending `+ k False` frame, so its continuation is applied once and the
# oracle correctly stays silent. The set-equality even pins that: if
# re-entrant enumeration is ever fixed, 37 starts aborting here and this
# script fails loudly, forcing a conscious reclassification.
#
# The hand-built-IR machine test "multi-shot: resume invoked twice" is not in
# this list because it self-adapts: it expects OneShotViolation when the env
# var is set (see Spec.hs).
#
# Default `cabal test` keeps the oracle OFF: production retains the machine's
# free multi-shot capability; the static law is the production guard.

cd "$(dirname "$0")/.."

EXPECTED_FAILURES="17-choice-multishot
28-bounded-multishot-arith
29-bounded-multishot-prefix
30-bounded-multishot-let
33-bounded-nested-multishot
56-named-multishot"

# The failure extraction below keys on tasty LEAF names, so first assert each
# expected name is globally unique in the test tree and lives under the
# "run golden" group -- a later same-named test in another group would
# otherwise be collapsed by the set comparison and mask a failure.
echo "== asserting expected-failure names are unique leaves under 'run golden' =="
listing=$(cabal test --test-show-details=direct --test-options="-l" 2>/dev/null \
            | grep -F 'multishot' || true)
while IFS= read -r name; do
  hits=$(printf '%s\n' "$listing" | grep -cF ".$name" || true)
  under_run_golden=$(printf '%s\n' "$listing" \
                       | grep -cF "run golden.$name" || true)
  if [ "$hits" -ne 1 ] || [ "$under_run_golden" -ne 1 ]; then
    echo "ORACLE RUN: expected failure '$name' is not a unique 'run golden' leaf" >&2
    echo "  (occurrences: $hits, under run golden: $under_run_golden)" >&2
    echo "  -- fix EXPECTED_FAILURES or disambiguate the test name." >&2
    exit 1
  fi
done <<< "$EXPECTED_FAILURES"

echo "== full suite under WOK_DEBUG_ONESHOT=1 =="
out=$(WOK_DEBUG_ONESHOT=1 cabal test --test-show-details=direct \
        --test-options="--hide-successes" 2>&1) || true
printf '%s\n' "$out" | tail -3

fails=$(printf '%s\n' "$out" \
          | grep -E 'FAIL( \([0-9.]+s\))?$' \
          | sed -E 's/:[[:space:]]*FAIL( \([0-9.]+s\))?$//; s/^[[:space:]]*//' \
          | grep -v '^Test suite ' | sort -u)
expected=$(printf '%s\n' "$EXPECTED_FAILURES" | sort -u)

if [ "$fails" != "$expected" ]; then
  echo "ORACLE RUN: unexpected failure set." >&2
  echo "--- expected (law-rejected multishot capability pins):" >&2
  printf '%s\n' "$expected" >&2
  echo "--- got:" >&2
  printf '%s\n' "${fails:-<none>}" >&2
  exit 1
fi

violations=$(printf '%s\n' "$out" | grep -c 'runtime error: OneShotViolation' || true)
if [ "$violations" -lt 6 ]; then
  echo "ORACLE RUN: expected >= 6 OneShotViolation aborts, saw $violations." >&2
  exit 1
fi

echo "ORACLE RUN OK: law-admitted corpus violation-free;"
echo "all 6 law-rejected multishot pins aborted with OneShotViolation."
