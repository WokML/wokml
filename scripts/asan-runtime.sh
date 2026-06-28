#!/usr/bin/env bash
set -euo pipefail

CC="${CC:-cc}"
SAN="-fsanitize=address,undefined -fno-omit-frame-pointer"
WARN="-Wall -Wextra -Wpedantic"
# WOK_RC_CHECK_PHYSICAL: arms the self-policing PHYSICAL-memory invariant (peak_physical <=
#   K*peak_logical + C*slab). Debug/sanitizer-build only -- a release build never aborts on a
#   memory heuristic. With it armed here, EVERY existing test (T1-T10, deep-list, arrays)
#   checks the bound for free, closing the unbounded-physical-growth (slab-orphaning) class.
# WOK_RC_PHYSICAL_TEST_HOOK: compiles wok_test_orphan_slabs so the T11 death test can drive
#   the invariant to fire (the permanent negative control).
PHYS="-DWOK_RC_CHECK_PHYSICAL -DWOK_RC_PHYSICAL_TEST_HOOK"
BASE="-std=c17 -O1 -g $WARN $PHYS -Iruntime"

run() { # $1 = label, $2.. = extra defines
  local label="$1"; shift
  $CC $BASE $SAN "$@" runtime/wok_rc.c runtime/wok_utf8.c runtime/test/wok_rc_test.c -o /tmp/wok_rc_test
  echo "== $label =="
  if [ "$(uname -s)" = "Darwin" ]; then
    /tmp/wok_rc_test                          # LSan unsupported on Apple's ASan runtime
  else
    ASAN_OPTIONS=detect_leaks=1 /tmp/wok_rc_test
  fi
}

run_arena() { # $1 = label, $2.. = extra defines
  local label="$1"; shift
  $CC $BASE $SAN "$@" runtime/wok_rc.c runtime/test/wok_arena_test.c -o /tmp/wok_arena_test
  echo "== $label (arena) =="
  if [ "$(uname -s)" = "Darwin" ]; then
    /tmp/wok_arena_test
  else
    ASAN_OPTIONS=detect_leaks=1 /tmp/wok_arena_test
  fi

  # T11 negative control: orphaning slabs MUST trip the physical-invariant abort (SIGABRT,
  # exit 134). A clean exit means the self-policing assertion is inert -- a regression.
  echo "== $label (arena) physical-invariant death test (WOK_TEST_DEATH=physical) =="
  # ASan turns SIGABRT into its own report+exit (often 1, not 134); allow either nonzero.
  if WOK_TEST_DEATH=physical ASAN_OPTIONS="${ASAN_OPTIONS:-}" /tmp/wok_arena_test >/dev/null 2>&1; then
    echo "FAIL: physical-invariant death test did NOT abort (assertion inert?)" >&2
    exit 1
  else
    echo "ok: physical-invariant abort fired as expected"
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

run_arena "arena (default)"
run_arena "malloc backend (UAF oracle)" -DWOK_RC_MALLOC
run_arena "poison-on-free"              -DWOK_RC_POISON

# WokForeignBytes negative control: omit the host-side libc free and confirm LSan detects it.
# Only meaningful on Linux (Apple's ASan runtime does not support LSan); skip on Darwin.
# A clean exit from this binary would be a regression (it means the leak is undetected).
if [ "$(uname -s)" != "Darwin" ]; then
  echo "== WokForeignBytes leak negative control (WOK_FOREIGN_BYTES_LEAK_TEST) =="
  $CC $BASE $SAN -DWOK_FOREIGN_BYTES_LEAK_TEST runtime/wok_rc.c runtime/wok_utf8.c runtime/test/wok_rc_test.c -o /tmp/wok_foreign_bytes_leak_test
  if ASAN_OPTIONS=detect_leaks=1 /tmp/wok_foreign_bytes_leak_test >/dev/null 2>&1; then
    echo "FAIL: WokForeignBytes leak negative control did NOT report a leak (LSan inert?)" >&2
    exit 1
  else
    echo "ok: WokForeignBytes leak detected as expected (LSan fired)"
  fi
else
  echo "== WokForeignBytes leak negative control: SKIPPED on Darwin (LSan unsupported) =="
fi
