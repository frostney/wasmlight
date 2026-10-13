#!/usr/bin/env bash
# Re-vendor the pinned WebAssembly/wasi-testsuite Preview 1 corpus into
# tests/spec/wasi/. Run by hand only; CI never runs this (the corpus is
# committed so test runs need no network).
#
# usage: tools/wasi-testsuite/vendor.sh <prod/testsuite-base sha> <source main sha>
set -euo pipefail

SHA="${1:?usage: vendor.sh <prod/testsuite-base sha> <source main sha>}"
SOURCE_SHA="${2:?usage: vendor.sh <prod/testsuite-base sha> <source main sha>}"
REPO_URL="https://github.com/WebAssembly/wasi-testsuite"
BRANCH="prod/testsuite-base"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
DEST="$ROOT/tests/spec/wasi"

# Exactly what the runner reads: the P1 test directories (wasm, json specs,
# manifest, fixture dirs) and the runner's Python package. No sources or
# build files.
DIRS=(
  tests/assemblyscript/testsuite/wasm32-wasip1
  tests/c/testsuite/wasm32-wasip1
  tests/rust/testsuite/wasm32-wasip1
  test-runner/wasi_test_runner
)
FILES=(
  LICENSE
  test-runner/wasi_test_runner.py
  test-runner/requirements/common.txt
)

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
git -C "$WORK" init -q
git -C "$WORK" remote add origin "$REPO_URL"
git -C "$WORK" fetch -q --depth 1 origin "$SHA"
git -C "$WORK" checkout -q --detach FETCH_HEAD
test "$(git -C "$WORK" rev-parse HEAD)" = "$SHA"

rm -rf "$DEST"
mkdir -p "$DEST"
# git archive exports exactly the tracked files (no caches, no .pyc).
git -C "$WORK" archive --format=tar HEAD -- "${DIRS[@]}" "${FILES[@]}" \
  | tar -x -C "$DEST"

{
  echo "# wasi-testsuite provenance"
  echo
  echo "- Repository: WebAssembly/wasi-testsuite ($REPO_URL)"
  echo "- Branch: $BRANCH"
  echo "- Commit: $SHA"
  echo "- Source main commit: $SOURCE_SHA"
  echo "- Licence: Apache-2.0 (LICENSE, copied unmodified)"
  echo "- Refresh: tools/wasi-testsuite/vendor.sh <commit> <source main commit>"
  echo
  echo "Vendored paths (copied unmodified):"
  echo
  for p in "${FILES[@]}" "${DIRS[@]}"; do echo "- \`$p\`"; done
  echo
  echo "Files: $(cd "$DEST" && git -C "$WORK" archive --format=tar HEAD -- "${DIRS[@]}" "${FILES[@]}" | tar -t | grep -vc '/$')"
} > "$DEST/PROVENANCE.md"
echo "vendored $SHA into $DEST"
