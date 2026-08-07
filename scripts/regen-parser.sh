#!/usr/bin/env bash
# Regenerate the BNFC parser from grammar/Wok.cf and re-apply the hand
# patches that the checked-in src-generated/ tree carries:
#   parser-patches/layout.patch  -- column-aware handler-block layout (64d32ea)
#   parser-patches/par.patch     -- left-recursive record-field list (S/R fix)
# Run from the repo root. Verifies nothing; `git diff src-generated` after a
# no-op run must be empty.
set -euo pipefail

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

bnfc --haskell -d -p GeneratedParser --text-token -o "$tmp" grammar/Wok.cf
rm -f "$tmp"/GeneratedParser/Wok/Doc.txt \
      "$tmp"/GeneratedParser/Wok/Skel.hs \
      "$tmp"/GeneratedParser/Wok/Test.hs

patch --silent "$tmp/GeneratedParser/Wok/Layout.hs" scripts/parser-patches/layout.patch
patch --silent "$tmp/GeneratedParser/Wok/Par.y"     scripts/parser-patches/par.patch

rsync -a --delete "$tmp/GeneratedParser/" src-generated/GeneratedParser/
echo "regen-parser: done (patches applied)"
