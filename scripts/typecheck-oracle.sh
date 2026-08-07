#!/usr/bin/env bash
# scripts/typecheck-oracle.sh
#
# S4 oracle harness (spec 2026-08-06-sexp-ingestion-oracle.md, D8/S4). Runs
# the FULL sexp path -- `wokparse -sexp` (grammar/c) piped into `wok`
# (default mode, which prints `name : scheme` per entry-module decl) -- over
# the corpus and locks the scheme text down as a golden tree under
# test/oracle-golden/. Those goldens are the CONTRACT a future C
# typechecker implements against: byte-equal scheme text on this corpus.
#
# Corpus: the same four flat directories as the "Sexp.Differential" tasty
# group (test/Spec.hs), so the oracle corpus tracks the S3 intersection:
#
#   test/typecheck-examples  test/examples  test/run-examples
#   docs/redesign/examples/accept
#
# minus the files test/Spec.hs's `sexpKnownDivergences` excludes from that
# intersection (a single file: the position-only error-span mismatch on
# conc-carrier-transport-rejected, expected per spec D4 -- see the comment
# above that set in test/Spec.hs). Keep KNOWN_DIVERGENCES below in sync
# with that set by hand; there is no shared source of truth between the
# Haskell test suite and this shell script. Note test/Spec.hs's
# `sexpNoV1Twin` (13-data-lowercase-error) is NOT mirrored here: its dump
# has no `module` header, so the `wok` step fails and it lands in the
# ordinary skip-(gap) bucket like the other test/examples fragments.
#
# Per file: one `wokparse -sexp` invocation (never batched -- batch loops
# over wokparse have been flaky in this sandbox per the spec's corpus
# audit), piped to a mktemp .sexp file; a nonzero wokparse exit is a
# C-parse rejection, skipped with a logged reason. Otherwise `wok
# <tmp>.sexp` is run; a nonzero exit here means the sexp bridge could not
# ingest the file into a runnable program (a SexpGap the mapper reported,
# a structural Loader error such as a missing `module` header on a
# fragment file, or -- less commonly -- a genuine pipeline failure): all
# such cases are skipped with the logged stderr as the reason, since none
# of them are byte-for-byte oracle content the C typechecker would need to
# reproduce this slice (spec D8's note: error-side comparison is a later
# `--errors-canonical` mode, not this one).
#
# Two modes:
#   (default)  compare each ok file's stdout against its existing golden,
#              report PASS/FAIL per file, exit nonzero on any FAIL or on
#              any golden that exists on disk but was not reproduced this
#              run (a silent coverage regression).
#   --update   (re)write the golden tree. Each file's scheme text is
#              generated TWICE; if the two runs disagree the script
#              refuses to write a golden and exits nonzero immediately --
#              that would mean the oracle itself is nondeterministic,
#              which is a finding to report, not paper over.
#
# Sequential, single loop -- no parallelism (house style: see the header
# comment of scripts/oneshot-oracle.sh and the corpus-audit anomaly note
# in the spec about batched wokparse stalls).

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

MODE="compare"
case "${1:-}" in
  "")          MODE="compare" ;;
  --update)    MODE="update" ;;
  *)
    echo "usage: $0 [--update]" >&2
    exit 1
    ;;
esac

# ---------------------------------------------------------------
# Locate wokparse
# ---------------------------------------------------------------
WOKPARSE="${WOK_WOKPARSE:-grammar/c/wokparse}"
if [ ! -e "$WOKPARSE" ]; then
  echo "error: wokparse not found at '$WOKPARSE'" >&2
  echo "  build it (grammar/c/Makefile), or set WOK_WOKPARSE=/path/to/wokparse" >&2
  exit 1
fi
if [ ! -x "$WOKPARSE" ]; then
  echo "error: '$WOKPARSE' exists but is not executable" >&2
  exit 1
fi

# ---------------------------------------------------------------
# Locate / build the wok binary. wok_datadir must point at the repo root
# so Paths_wok resolves the embedded prelude data files when the list-bin
# binary is run directly (needed earlier in this project, same reason).
# ---------------------------------------------------------------
echo "== building exe:wok (if needed) ==" >&2
cabal build exe:wok >&2
WOKBIN="$(cabal list-bin exe:wok 2>/dev/null | tail -1)"
if [ -z "$WOKBIN" ] || [ ! -x "$WOKBIN" ]; then
  echo "error: could not locate the wok executable via 'cabal list-bin exe:wok'" >&2
  exit 1
fi
export wok_datadir="$REPO_ROOT"

# ---------------------------------------------------------------
# Corpus
# ---------------------------------------------------------------
CORPUS_DIRS="test/typecheck-examples test/examples test/run-examples docs/redesign/examples/accept"

# test/Spec.hs, sexpKnownDivergences -- keep in sync by hand.
KNOWN_DIVERGENCES="conc-carrier-transport-rejected"

is_known_divergence() {
  local base="$1" k
  for k in $KNOWN_DIVERGENCES; do
    [ "$k" = "$base" ] && return 0
  done
  return 1
}

GOLDEN_ROOT="test/oracle-golden"
mkdir -p "$GOLDEN_ROOT"

SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/typecheck-oracle.XXXXXX")"
trap 'rm -rf "$SCRATCH"' EXIT

touched_list="$SCRATCH/touched.list"
: > "$touched_list"

n_compared=0
n_updated=0
n_fail=0
n_reject=0
n_gap=0
n_excluded=0

for dir in $CORPUS_DIRS; do
  dirbase="$(basename "$dir")"
  goldendir="$GOLDEN_ROOT/$dirbase"
  mkdir -p "$goldendir"

  # NUL-delimited + process substitution (not a pipe): whitespace in
  # filenames survives, and the while loop still runs in THIS shell, so
  # the counters it updates (n_compared, n_fail, ...) are not lost to a
  # subshell the way `find ... | while read` would lose them.
  while IFS= read -r -d '' f; do
    base="$(basename "$f" .wok)"

    if is_known_divergence "$base"; then
      n_excluded=$((n_excluded + 1))
      echo "SKIP (known-divergence) $f"
      continue
    fi

    sexpfile="$SCRATCH/$dirbase-$base.sexp"
    wperr="$SCRATCH/$dirbase-$base.wp.err"

    if ! "$WOKPARSE" -sexp "$f" > "$sexpfile" 2>"$wperr"; then
      n_reject=$((n_reject + 1))
      echo "SKIP (C-reject) $f: $(head -1 "$wperr" 2>/dev/null || true)"
      rm -f "$sexpfile" "$wperr"
      continue
    fi

    goldenfile="$goldendir/$base.schemes"

    # The gap check is mode-independent: a file `wok` cannot yet ingest is
    # skipped the same way whether goldens are being written or compared,
    # and it happens before either mode's own work.
    out1="$SCRATCH/$dirbase-$base.out1"; err1="$SCRATCH/$dirbase-$base.err1"
    if ! "$WOKBIN" "$sexpfile" > "$out1" 2>"$err1"; then
      n_gap=$((n_gap + 1))
      echo "SKIP (gap) $f: $(head -1 "$err1" 2>/dev/null || true)"
      rm -f "$sexpfile" "$wperr" "$out1" "$err1"
      continue
    fi

    if [ "$MODE" = "update" ]; then
      out2="$SCRATCH/$dirbase-$base.out2"; err2="$SCRATCH/$dirbase-$base.err2"

      if ! "$WOKBIN" "$sexpfile" > "$out2" 2>"$err2"; then
        echo "" >&2
        echo "ORACLE NONDETERMINISM: $f produced scheme output on the first run" >&2
        echo "  but FAILED on the second identical run. Refusing to write a golden." >&2
        cat "$err2" >&2
        exit 1
      fi

      if ! diff -q "$out1" "$out2" >/dev/null; then
        echo "" >&2
        echo "ORACLE NONDETERMINISM: $f produced DIFFERENT scheme text across two" >&2
        echo "  back-to-back runs. Refusing to write a golden." >&2
        diff -u "$out1" "$out2" >&2 || true
        exit 1
      fi

      cp "$out1" "$goldenfile"
      echo "UPDATE $f"
      echo "$goldenfile" >> "$touched_list"
      n_updated=$((n_updated + 1))
      rm -f "$sexpfile" "$wperr" "$out1" "$err1" "$out2" "$err2"
    else
      if [ ! -f "$goldenfile" ]; then
        n_fail=$((n_fail + 1))
        echo "FAIL $f: no golden at $goldenfile (run --update)"
      elif diff -q "$out1" "$goldenfile" >/dev/null; then
        echo "PASS $f"
        n_compared=$((n_compared + 1))
        echo "$goldenfile" >> "$touched_list"
      else
        n_fail=$((n_fail + 1))
        echo "FAIL $f: scheme text differs from $goldenfile"
        diff -u "$goldenfile" "$out1" || true
        echo "$goldenfile" >> "$touched_list"
      fi
      rm -f "$sexpfile" "$wperr" "$out1" "$err1"
    fi
  done < <(find "$dir" -maxdepth 1 -name '*.wok' -print0 | sort -z)
done

# ---------------------------------------------------------------
# Coverage check: any golden on disk this run did not reproduce is a
# coverage change worth calling out; in compare mode it is a regression
# that must not pass silently. EXCEPTION: a golden whose basename is in
# KNOWN_DIVERGENCES is expected to be untouched (its file is `continue`d
# past before touched_list is ever written) -- that is not a regression,
# just a leftover golden from before the file was excluded. Flag it as a
# WARNING advising deletion instead of failing the run.
# ---------------------------------------------------------------
n_stale=0
n_divergence_golden=0
stale_report=""
divergence_golden_report=""
while IFS= read -r existing; do
  [ -z "$existing" ] && continue
  if grep -qxF "$existing" "$touched_list"; then
    continue
  fi
  existing_base="$(basename "$existing" .schemes)"
  if is_known_divergence "$existing_base"; then
    n_divergence_golden=$((n_divergence_golden + 1))
    divergence_golden_report="$divergence_golden_report  $existing
"
  else
    n_stale=$((n_stale + 1))
    stale_report="$stale_report  $existing
"
  fi
done <<EOF
$(find "$GOLDEN_ROOT" -name '*.schemes' | sort)
EOF

echo ""
echo "== summary =="
if [ "$MODE" = "update" ]; then
  echo "updated:                     $n_updated"
else
  echo "compared:                    $n_compared"
  echo "failed:                      $n_fail"
fi
echo "skipped (C-reject):          $n_reject"
echo "skipped (gap):                $n_gap"
echo "excluded (known-divergence): $n_excluded"

if [ "$n_stale" -gt 0 ]; then
  if [ "$MODE" = "update" ]; then
    echo "coverage change: $n_stale golden(s) not regenerated this run (stale, left on disk):"
  else
    echo "coverage change: $n_stale golden(s) exist on disk but were skipped this run (REGRESSION):"
  fi
  printf '%s' "$stale_report"
else
  echo "coverage change: none"
fi

if [ "$n_divergence_golden" -gt 0 ]; then
  echo ""
  echo "WARNING: $n_divergence_golden golden(s) on disk belong to KNOWN_DIVERGENCES"
  echo "  basenames (intentionally excluded from this run, not a regression). Consider"
  echo "  deleting them so the golden tree only holds files this script covers:"
  printf '%s' "$divergence_golden_report"
fi

if [ "$MODE" = "compare" ] && { [ "$n_fail" -gt 0 ] || [ "$n_stale" -gt 0 ]; }; then
  exit 1
fi

exit 0
