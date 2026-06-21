#!/usr/bin/env bash
set -euo pipefail

CC="${CC:-cc}"
SAN="-fsanitize=address,undefined -fno-omit-frame-pointer"
WARN="-Wall -Wextra -Wpedantic"
BASE="-std=c17 -O1 -g $WARN -Iruntime"

run() { # $1 = label, $2.. = extra defines
  local label="$1"; shift
  $CC $BASE $SAN "$@" runtime/wok_rc.c runtime/test/wok_rc_test.c -o /tmp/wok_rc_test
  echo "== $label =="
  if [ "$(uname -s)" = "Darwin" ]; then
    /tmp/wok_rc_test                          # LSan unsupported on Apple's ASan runtime
  else
    ASAN_OPTIONS=detect_leaks=1 /tmp/wok_rc_test
  fi
}

if [ "${1:-}" = "bench" ]; then
  $CC -std=c17 -O3 $WARN -Iruntime runtime/wok_rc.c runtime/test/wok_rc_bench.c -o /tmp/wok_rc_bench_arena
  $CC -std=c17 -O3 $WARN -DWOK_RC_MALLOC -Iruntime runtime/wok_rc.c runtime/test/wok_rc_bench.c -o /tmp/wok_rc_bench_malloc
  /tmp/wok_rc_bench_arena
  /tmp/wok_rc_bench_malloc
  exit 0
fi

run "arena (default)"
run "malloc backend (UAF oracle)" -DWOK_RC_MALLOC
run "poison-on-free"              -DWOK_RC_POISON
