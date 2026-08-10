#!/usr/bin/env python3
"""Fail the build if coverage.json disagrees with lcov's own summary.

    lcov --summary wok.info 2>&1 | coverage-verify.py coverage.json

The JSON is meant to be read by machines, so "roughly right" is not a
category it has. It is produced by our own parser; lcov's summary comes from
the reference implementation reading the same tracefile. If the two ever
disagree, one of them is lying to a tool that cannot tell -- so the build
stops here rather than publishing.

This gate exists because the numbers DID diverge once: the JSON reported 365
functions against genhtml's 686, and zero uncovered functions against 13,
because the parser only understood the classic FN:/FNDA: spelling and the
tracefile used lcov 2.x's FNL:/FNA:. Nothing failed; a wrong number was simply
published. A percentage that is quietly wrong is worse than no percentage.
"""

from __future__ import annotations

import json
import re
import sys

# "  lines......: 94.7% (4790 of 5059 lines)"
SUMMARY = re.compile(
    r"^\s*(lines|functions)\.*:\s*[\d.]+%\s*\((\d+)\s+of\s+(\d+)\s+\1\)", re.I
)


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: lcov --summary X.info | coverage-verify.py coverage.json",
              file=sys.stderr)
        return 2

    with open(sys.argv[1], encoding="utf-8") as fh:
        doc = json.load(fh)

    expected: dict[str, tuple[int, int]] = {}
    for raw in sys.stdin:
        m = SUMMARY.match(raw)
        if m:
            expected[m.group(1).lower()] = (int(m.group(2)), int(m.group(3)))

    if not expected:
        print("verify: lcov produced no summary to check against -- refusing "
              "to treat that as agreement", file=sys.stderr)
        return 1

    bad = []
    for kind, (hit, found) in expected.items():
        got = doc["totals"][kind]
        if (got["hit"], got["found"]) != (hit, found):
            bad.append(
                f"  {kind}: lcov says {hit}/{found}, "
                f"coverage.json says {got['hit']}/{got['found']}"
            )

    if bad:
        print("verify: coverage.json does not match lcov's own summary",
              file=sys.stderr)
        print("\n".join(bad), file=sys.stderr)
        print("\nThe JSON is consumed by tools that cannot notice this. "
              "Fix the parser rather than the check.", file=sys.stderr)
        return 1

    checked = ", ".join(f"{k} {v[0]}/{v[1]}" for k, v in sorted(expected.items()))
    print(f"verify: coverage.json matches lcov ({checked})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
