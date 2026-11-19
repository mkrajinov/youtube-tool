#!/usr/bin/env bash
# Prints the version to release for the current commit.
#
#   - If a v* tag already points at HEAD (a re-run), that version again.
#   - Else VERSION, if it hasn't been released yet (bump VERSION by hand for a new minor/major).
#   - Else the next patch after the highest released tag with VERSION's major.minor.
#
# Needs the tags fetched (actions/checkout with fetch-depth: 0).
set -euo pipefail

cd "$(dirname "$0")/.."
base="$(tr -d '[:space:]' < VERSION)"

here="$(git tag --points-at HEAD --list 'v*' | sed 's/^v//' | sort -V | tail -1)"
if [[ -n "$here" ]]; then
  echo "$here"
  exit 0
fi

if ! git rev-parse -q --verify "refs/tags/v$base" >/dev/null; then
  echo "$base"
  exit 0
fi

minor="${base%.*}"   # 0.3.0 -> 0.3
last="$(git tag --list "v$minor.*" | sed 's/^v//' | sort -V | tail -1)"
echo "$minor.$(( ${last##*.} + 1 ))"
