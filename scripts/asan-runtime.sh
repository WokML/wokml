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

if [ "${1:-}" = "interp" ]; then
  # ---------------------------------------------------------------------------
  # POSITIVE: run the full rc-ffi-foreign corpus through the wok RC interpreter
  # (the borrow-out path) under ASan+WOK_RC_MALLOC. Every .wok file in
  # test/rc-ffi-foreign/ is run; an ASan-reported error on ANY clean-path file
  # is a regression. detect_leaks=0: macOS has no LSan (harmless on Linux too).
  #
  # WHY cabal clean: GHC's C compilation reuses cached .dyn_o objects keyed on
  # the source file hash, not the cc-options hash. Switching the 'asan' flag
  # changes the linker flags and the recorded cc-options but does NOT force a
  # recompile of unchanged C source files. A clean wipes the cached objects so
  # the next build compiles all C files with the new flags (including
  # -fsanitize=address -DWOK_RC_MALLOC). Without this, the slab allocator
  # (non-MALLOC) is used and ASan redzones are absent -- overreads are silent.
  # ---------------------------------------------------------------------------
  echo "== interp: cabal clean (force C recompile with new cc-options) =="
  cabal clean
  echo "== interp: building wok with -fasan (WOK_RC_MALLOC, ASan redzones) =="
  cabal build -fasan exe:wok
  echo "== interp: positive -- corpus must be CLEAN under ASan =="
  for f in test/rc-ffi-foreign/*.wok; do
    if ASAN_OPTIONS=detect_leaks=0 cabal run -v0 -fasan exe:wok -- "$f" --dump-rc-stats >/dev/null 2>&1; then
      echo "ok: $f"
    else
      echo "FAIL: ASan reported on $f (clean path -- unexpected abort)" >&2
      exit 1
    fi
  done
  echo "ok: borrow-out corpus clean under ASan"

  # ---------------------------------------------------------------------------
  # NEGATIVE CONTROL: rebuild with the clamp removed (ffi-noclamp-negctrl).
  # The overrun probe (asan-overrun-probe.wok) uses an 8-byte no-zero buffer
  # with n=128; the unclamped strndup scan crosses the ASan redzone past the
  # 24-byte cell boundary and MUST abort. A clean exit means the clamp gate is
  # inert -- a regression.
  # Incremental rebuild here is fine: we are switching the Haskell CPP flag
  # (ffi-noclamp-negctrl) which triggers GHC Haskell recompile; the C objects
  # (already -DWOK_RC_MALLOC + ASan) are reused unchanged -- that is correct.
  # ---------------------------------------------------------------------------
  echo "== interp: negative control -- rebuilding with -fffi-noclamp-negctrl =="
  cabal build -fasan -fffi-noclamp-negctrl exe:wok
  echo "== interp: negative control -- overrun probe MUST abort under ASan =="
  if ASAN_OPTIONS=detect_leaks=0 cabal run -v0 -fasan -fffi-noclamp-negctrl exe:wok \
       -- test/rc-ffi-foreign/asan-overrun-probe.wok --dump-rc-stats >/dev/null 2>&1; then
    echo "FAIL: borrow-out negative control did NOT abort (clamp gate inert?)" >&2
    exit 1
  else
    echo "ok: borrow-out overread caught by ASan (clamp gate has teeth)"
  fi
  # Restore the default (no-asan) build so subsequent `cabal test` works without
  # the ASan dylib dependency. cabal clean + rebuild re-links against the normal
  # slab allocator.
  echo "== interp: restoring default (no-asan) build =="
  cabal clean && cabal build exe:wok
  echo "== interp: done -- default build restored =="
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

# BORROW-OUT SANITIZER COVERAGE (honest statement, FFI Slice 2):
# This script exercises the STANDALONE C lifecycle tests (wok_rc_test.c /
# wok_arena_test.c) under ASan+UBSan, which covers:
#   - WokForeignBytes alloc/free cycle (test_foreign_bytes_cell, T13-class)
#   - libc free at rc-zero via wok_dec
#   - LSan leak negative control (Linux only)
# ALSO COVERED (bash scripts/asan-runtime.sh interp):
#   - The Haskell rcForeignDispatch borrow-out path (strndup CLAMP, memchr
#     pointer passing) through the wok RC interpreter under ASan+WOK_RC_MALLOC.
#   - POSITIVE: the full rc-ffi-foreign corpus runs CLEAN (no ASan reports).
#   - NEGATIVE CONTROL (mutation-confirmed): flag ffi-noclamp-negctrl drops
#     the scan clamp; asan-overrun-probe.wok (8-byte no-zero buffer, n=128)
#     crosses the cell redzone and aborts. This proves the clamp gate has teeth.
# The double-free guard for the adopt path is mutation-confirmed at the Haskell
# level (08-strndup-dup-share in test/rc-ffi-foreign/): temporarily injecting
# free(p) right after adoptCHeapPtr caused a SIGABRT from macOS libc double-free
# detection.
echo "== borrow-out ASan coverage: C lifecycle covered + Haskell interp path covered (run with 'interp' subcommand) =="
