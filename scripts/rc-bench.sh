#!/usr/bin/env bash
# scripts/rc-bench.sh
#
# Run --dump-rc-stats over the four Slice-2 benchmark programs and print a
# labelled table. Used to capture the pre-change baseline and to re-measure
# after each optimization slice.
#
# Usage: bash scripts/rc-bench.sh [> bench/baseline.txt]

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

run_bench() {
  local label="$1"
  local file="$2"
  echo "=== $label ==="
  cabal run -v0 wok -- --dump-rc-stats "$file"
  echo ""
}

run_bench "tree    (binary tree, depth 8)"    bench/tree.wok
run_bench "list    (spine of 100 nodes)"      bench/list.wok
run_bench "bools   (1000 bool-alloc steps)"   bench/bools.wok
run_bench "maybes  (64 Option values)"        bench/maybes.wok
