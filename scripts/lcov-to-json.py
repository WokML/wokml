#!/usr/bin/env python3
"""Turn an lcov tracefile into JSON, for readers that are not browsers.

The HTML report is for people. This is the same measurement for anything that
would otherwise have to scrape it: a tool, a bot, an agent asking "what is
untested here" without parsing 86 files of markup.

    lcov-to-json.py coverage/wok.info --root ../.. > coverage.json

The interesting field is `uncovered_lines`. A percentage says how much is
missed; the line numbers say WHAT, which is the only form of the answer anyone
can act on.

lcov's tracefile format, the parts used here:

    SF:<path>              start of a file record
    DA:<line>,<count>      a line, and how many times it ran
    LF:/LH:                lines found / hit
    end_of_record

Functions come in TWO spellings, and getting this wrong is not a rounding
error -- it reported 365 functions where genhtml said 686, and found zero
uncovered functions where genhtml found 13:

    classic     FN:<line>,<name>        FNDA:<count>,<name>
    lcov 2.x    FNL:<id>,<start>,<end>  FNA:<id>,<count>,<name>

Both are read. The count is over ALIASES (one per FNA/FNDA record), not over
FNL leaders, because that is what genhtml reports -- an inline function
instantiated in several translation units is several entries. FNF:/FNH: are
read only as a cross-check; they count leaders, so on a tree with inline
functions in headers they disagree with the HTML and must not be the source of
truth.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
from typing import Any


def pct(hit: int, found: int) -> float:
    # 100% for an empty file rather than a division by zero: nothing is
    # missing from it. Rounded to lcov's own precision so the two reports
    # cannot disagree in the last digit.
    return 100.0 if found == 0 else round(hit * 100.0 / found, 1)


def parse(path: str, root: str) -> list[dict[str, Any]]:
    files: list[dict[str, Any]] = []
    cur: dict[str, Any] | None = None

    with open(path, encoding="utf-8", errors="replace") as fh:
        for raw in fh:
            line = raw.strip()

            if line.startswith("SF:"):
                src = line[3:]
                try:
                    rel = os.path.relpath(src, root)
                except ValueError:  # different drive on Windows
                    rel = src
                cur = {
                    "path": rel,
                    "lines": {"found": 0, "hit": 0},
                    "functions": {"found": 0, "hit": 0},
                    "uncovered_lines": [],
                    "uncovered_functions": [],
                    "_da": {},
                    "_fn": [],   # (name, count) per ALIAS, both spellings
                    "_fnf": None,
                    "_fnh": None,
                }
                continue

            if cur is None:
                continue

            if line.startswith("DA:"):
                num, _, count = line[3:].partition(",")
                try:
                    cur["_da"][int(num)] = int(count.split(",")[0])
                except ValueError:
                    pass
            elif line.startswith("FNDA:"):           # classic
                count, _, name = line[5:].partition(",")
                try:
                    cur["_fn"].append((name, int(count)))
                except ValueError:
                    pass
            elif line.startswith("FNA:"):            # lcov 2.x
                parts = line[4:].split(",", 2)
                if len(parts) == 3:
                    try:
                        cur["_fn"].append((parts[2], int(parts[1])))
                    except ValueError:
                        pass
            elif line.startswith("LF:"):
                cur["lines"]["found"] = int(line[3:] or 0)
            elif line.startswith("LH:"):
                cur["lines"]["hit"] = int(line[3:] or 0)
            elif line.startswith("FNF:"):
                cur["_fnf"] = int(line[4:] or 0)
            elif line.startswith("FNH:"):
                cur["_fnh"] = int(line[4:] or 0)
            elif line == "end_of_record":
                da = cur.pop("_da")
                fn = cur.pop("_fn")
                fnf, fnh = cur.pop("_fnf"), cur.pop("_fnh")

                # Trust LF/LH when lcov emitted them, and fall back to the
                # per-line records when it did not, so a tracefile written by
                # a different producer still yields the same totals.
                if not cur["lines"]["found"]:
                    cur["lines"]["found"] = len(da)
                    cur["lines"]["hit"] = sum(1 for c in da.values() if c > 0)
                cur["uncovered_lines"] = sorted(n for n, c in da.items() if c == 0)
                cur["lines"]["pct"] = pct(cur["lines"]["hit"], cur["lines"]["found"])

                # Alias records are authoritative; FNF/FNH only fill in for a
                # producer that emitted no per-function records at all.
                if fn:
                    cur["functions"]["found"] = len(fn)
                    cur["functions"]["hit"] = sum(1 for _, c in fn if c > 0)
                    cur["uncovered_functions"] = sorted(
                        {name for name, c in fn if c == 0}
                    )
                else:
                    cur["functions"]["found"] = fnf or 0
                    cur["functions"]["hit"] = fnh or 0
                cur["functions"]["pct"] = pct(
                    cur["functions"]["hit"], cur["functions"]["found"]
                )
                files.append(cur)
                cur = None

    files.sort(key=lambda f: f["path"])
    return files


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("tracefile")
    ap.add_argument("--root", default=".", help="paths are reported relative to this")
    ap.add_argument("--commit", default="", help="commit the measurement describes")
    ap.add_argument("--generated-at", default="", help="ISO-8601 UTC timestamp")
    ap.add_argument("--tool", default="lcov+gcov (gcc)")
    args = ap.parse_args()

    files = parse(args.tracefile, args.root)

    lf = sum(f["lines"]["found"] for f in files)
    lh = sum(f["lines"]["hit"] for f in files)
    ff = sum(f["functions"]["found"] for f in files)
    fh = sum(f["functions"]["hit"] for f in files)

    doc = {
        # Version the shape, so a consumer can tell a change from a breakage.
        "schema": "wok-coverage/1",
        "commit": args.commit,
        "generated_at": args.generated_at,
        "tool": args.tool,
        "totals": {
            "files": len(files),
            "lines": {"found": lf, "hit": lh, "pct": pct(lh, lf)},
            "functions": {"found": ff, "hit": fh, "pct": pct(fh, ff)},
        },
        "files": files,
    }
    json.dump(doc, sys.stdout, indent=2, sort_keys=False)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
