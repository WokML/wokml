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
  # POSITIVE: run the full rc-ffi-foreign AND rc-borrow corpora through the
  # wok RC interpreter (the borrow-out / foreign-borrow-read paths) under
  # ASan+WOK_RC_MALLOC. Every .wok file in test/rc-ffi-foreign/ and
  # test/rc-borrow/ is run; an ASan-reported error on ANY clean-path file is a
  # regression. rc-borrow exercises the raw-pointer CHeap read path
  # (peekElemOff/plusPtr/H.c_memchr over a CHeap buffer + the 0xFFFA
  # WokBorrowView handle alloc/free in borrowSliceRC/borrowDemoRC) under the
  # same sanitizer coverage as the Slice-2 borrow-out path (FFI Slice 3 Task 3
  # review finding). detect_leaks=0: macOS has no LSan (harmless on Linux too).
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
  for f in test/rc-ffi-foreign/*.wok test/rc-borrow/*.wok test/rc-ffi-owned/*.wok; do
    # FFI Slice 3 Task 6 negative controls (death-*.wok / contstore-*.wok) are
    # REJECTED at compile/admission time, not clean-path runnable -- skip them here;
    # they have their own negative-control sections below. FFI Slice 4 adds
    # coherence-*.wok (Task 1 compile-reject fixtures) in test/rc-ffi-owned/ --
    # also not clean-path runnable; the runnable move-out corpus is the rest
    # (00-consume-unique / 01-consume-shared exercise the MOVE / COPY branches).
    case "$(basename "$f")" in
      death-*|contstore-*|coherence-*) continue ;;
    esac
    if ASAN_OPTIONS=detect_leaks=0 cabal run -v0 -fasan exe:wok -- "$f" --dump-rc-stats >/dev/null 2>&1; then
      echo "ok: $f"
    else
      echo "FAIL: ASan reported on $f (clean path -- unexpected abort)" >&2
      exit 1
    fi
  done
  echo "ok: borrow-out + borrow-read corpus clean under ASan"

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

  # ---------------------------------------------------------------------------
  # NEGATIVE CONTROL (FFI Slice 3 Task 6 death-test matrix): rebuild with the
  # Borrow carrier ESCAPE check disabled (flag ffi-borrow-noescape-negctrl) and
  # confirm each escape route is a GENUINE use-after-free, not a vacuous control.
  #
  # Each test/rc-borrow/death-*.wok forces a Borrow from the malloc'd
  # `Demo.lendBuffer` (Task 5 -- NOT the static `__borrow_demo`) past the carrier
  # wall (return / list / tuple / closure / slice). With the wall disabled the
  # program type-checks and runs: the lending function's activation-scoped close
  # (`KBorrowCloseRC` -> `borrowClose` -> `wok_borrow_demo_close` = libc free)
  # frees the buffer when the function returns, and the caller's read then hits the
  # FREED malloc'd buffer -> ASan read-after-free. A clean exit on ANY of these
  # means the carrier wall (Task 1) or the activation close (Task 5) is inert -- a
  # regression. The malloc'd producer is what makes this NON-vacuous: a static
  # `__borrow_demo` buffer would never fault.
  #
  # This is an incremental Haskell-only rebuild: the flag flips a CPP gate in
  # Wok.TypeChecking.Carrier; the C objects (already -DWOK_RC_MALLOC + ASan from
  # the positive build) are reused unchanged -- exactly like the noclamp control.
  #
  # The stored-continuation route (contstore-*.wok) is DELIBERATELY ABSENT: it is
  # rejected at the M3 continuation-escape boundary (`firstOrderNoHandlerViolations`),
  # which this mutation does not disable, so it never runs and stages no UAF (see the
  # Task 6 notes in test/rc-borrow/contstore-escape-rejected.wok).
  # ---------------------------------------------------------------------------
  echo "== interp: negative control -- rebuilding with -fffi-borrow-noescape-negctrl =="
  cabal build -fasan -fffi-borrow-noescape-negctrl exe:wok
  for f in test/rc-borrow/death-*.wok; do
    echo "== interp: borrow death-test -- $(basename "$f") MUST abort under ASan =="
    if ASAN_OPTIONS=detect_leaks=0 cabal run -v0 -fasan -fffi-borrow-noescape-negctrl exe:wok \
         -- "$f" --dump-rc-stats >/dev/null 2>&1; then
      echo "FAIL: $f did NOT abort (carrier wall inert, or close not freeing the buffer?)" >&2
      exit 1
    else
      echo "ok: $(basename "$f") use-after-free caught by ASan (carrier wall + activation close are load-bearing)"
    fi
  done

  # ---------------------------------------------------------------------------
  # NEGATIVE CONTROLS (FFI Slice 4 Task 6 death-test matrix, owned-INTO-C): defeat
  # the copy-when-shared guard TWO distinct ways and confirm each is a GENUINE,
  # DISTINCT fault, not a vacuous control.
  #
  # Both death-*.wok fixtures build a SHARED Bytes (`b` is read again after
  # `Sink.consume b`, so Perceus dups it -> rc > 1 at the call -> the UNMUTATED
  # router COPIES, and both files run CLEAN without any flag). Each flag mutates
  # the shared branch of `symConsume` differently. NOTE: neither mutation is the
  # naive "always dropAddr" force-move -- 'dropAddr' is refcount-SAFE (it only
  # frees at rc==0), so at rc==2 it would merely decrement to 1 and NOTHING would
  # fault. Both mutations reach PAST 'dropAddr' to the real allocator's 'free'.
  #
  #   * ffi-owned-noguard-negctrl + death-use-after-move.wok: hard-free the cell
  #     pointer ONCE (models a C consumer that took the raw shared buffer and
  #     freed it). The sibling's later `Libc.memchr` read -- a REAL C call ASan
  #     intercepts, unlike a Haskell `peekElemOff`, which ASan does NOT instrument
  #     (the Slice-3 vacuous-test lesson) -- then touches the freed buffer ->
  #     ASan `heap-use-after-free`.
  #   * ffi-owned-doublefree-negctrl + death-double-free.wok: free the cell
  #     pointer TWICE back-to-back INSIDE the dispatch (models the buffer freed by
  #     BOTH C and wok). ASan intercepts the SECOND `free` on the already-freed
  #     pointer -> ASan `attempting double-free` -- a DISTINCT class from the UAF
  #     above, with no intervening poisoned read.
  #
  # A single global mutation cannot produce BOTH classes at once (the first hard
  # free poisons the region, so any later access is a UAF read before a second
  # free could be reached), hence the two separate flags -- one genuine UAF, one
  # genuine double-free. A clean exit under EITHER flag means the copy-when-shared
  # guard (Task 4) is inert -- a regression.
  #
  # Region-double-move (a MoveOut on an R1-region-reachable, uncounted Bytes) has
  # NO fixture here: Wok.IR.Escape.escapingAtomsRhs treats EVERY RForeignCall
  # argument as an escaping position with NO call-head exemption (unlike a plain
  # RApp), so arenaEscapes is unconditionally True for any Bytes binder used as a
  # Sink.consume argument -- such a value can never be arena/region-routed by the
  # current compiler; it is always born on the counted heap. Confirmed empirically
  # (a Bytes built and consumed only inside a helper, never escaping otherwise,
  # still allocates/frees through the ordinary counted MOVE path, matching
  # 00-consume-unique.wok's accounting -- no arena instrumentation fires). The
  # router's "uncounted -> COPY" branch (spec §7.1) is therefore defensive-only
  # against a hypothetical future relaxation of that escape rule, not reachable
  # from today's surface language; this is reported honestly rather than faked.
  #
  # Each flag flip is an incremental Haskell-only rebuild (a CPP gate in
  # Wok.Interp.RC.Machine's `symConsume` arm); the C objects (already
  # -DWOK_RC_MALLOC + ASan from the positive build) are reused unchanged --
  # exactly like the noclamp / borrow-noescape controls.
  # ---------------------------------------------------------------------------
  echo "== interp: owned-INTO-C death-tests -- confirming flag OFF runs them CLEAN under ASan =="
  for f in test/rc-ffi-owned/death-*.wok; do
    if ASAN_OPTIONS=detect_leaks=0 cabal run -v0 -fasan exe:wok -- "$f" --dump-rc-stats >/dev/null 2>&1; then
      echo "ok: $(basename "$f") clean without the mutation (unmutated COPY path is safe)"
    else
      echo "FAIL: $(basename "$f") aborted WITHOUT the mutation (flag off) -- the fixture itself is unsound" >&2
      exit 1
    fi
  done

  echo "== interp: negative control (UAF) -- rebuilding with -fffi-owned-noguard-negctrl =="
  cabal build -fasan -fffi-owned-noguard-negctrl exe:wok
  echo "== interp: owned-INTO-C death-test -- death-use-after-move.wok MUST abort (heap-use-after-free) =="
  if ASAN_OPTIONS=detect_leaks=0 cabal run -v0 -fasan -fffi-owned-noguard-negctrl exe:wok \
       -- test/rc-ffi-owned/death-use-after-move.wok --dump-rc-stats >/dev/null 2>&1; then
    echo "FAIL: death-use-after-move.wok did NOT abort (copy-when-shared guard inert?)" >&2
    exit 1
  else
    echo "ok: death-use-after-move.wok heap-use-after-free caught by ASan (copy-when-shared guard is load-bearing)"
  fi

  echo "== interp: negative control (double-free) -- rebuilding with -fffi-owned-doublefree-negctrl =="
  cabal build -fasan -fffi-owned-doublefree-negctrl exe:wok
  echo "== interp: owned-INTO-C death-test -- death-double-free.wok MUST abort (attempting double-free) =="
  if ASAN_OPTIONS=detect_leaks=0 cabal run -v0 -fasan -fffi-owned-doublefree-negctrl exe:wok \
       -- test/rc-ffi-owned/death-double-free.wok --dump-rc-stats >/dev/null 2>&1; then
    echo "FAIL: death-double-free.wok did NOT abort (copy-when-shared guard inert?)" >&2
    exit 1
  else
    echo "ok: death-double-free.wok double-free caught by ASan (copy-when-shared guard is load-bearing)"
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
#   - FFI Slice 3 Task 3 (foreign-borrow read prims): the full rc-borrow corpus
#     (length/byteAt/slice/memchr/copy over __borrow_demo) also runs CLEAN,
#     exercising the 0xFFFA WokBorrowView raw-pointer reads (peekElemOff,
#     H.c_memchr) and handle alloc/free in borrowSliceRC/borrowDemoRC.
# The double-free guard for the adopt path is mutation-confirmed at the Haskell
# level (08-strndup-dup-share in test/rc-ffi-foreign/): temporarily injecting
# free(p) right after adoptCHeapPtr caused a SIGABRT from macOS libc double-free
# detection.
echo "== borrow-out ASan coverage: C lifecycle covered + Haskell interp path covered (run with 'interp' subcommand) =="
