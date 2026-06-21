#!/usr/bin/env bash
set -euo pipefail
cc -std=c17 -O1 -g -fsanitize=address,undefined -fno-omit-frame-pointer \
   -Wall -Wextra -Wpedantic -Iruntime \
   runtime/wok_rc.c runtime/test/wok_rc_test.c -o /tmp/wok_rc_test

# LeakSanitizer (detect_leaks) is unsupported by Apple's ASan runtime; requesting
# it there aborts at startup. Enable it only where the platform supports it so the
# script stays ASan+UBSan(+LSan where available)-clean on both Linux CI and macOS.
if [ "$(uname -s)" = "Darwin" ]; then
  /tmp/wok_rc_test
else
  ASAN_OPTIONS=detect_leaks=1 /tmp/wok_rc_test
fi
