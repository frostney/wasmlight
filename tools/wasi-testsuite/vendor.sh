#!/usr/bin/env bash
# Fetch the pinned WebAssembly/wasi-testsuite Preview 1 corpus into
# tests/spec/wasi/ and verify it against tools/wasi-testsuite/manifest.sha256.
# The corpus is not committed (only LICENSE and PROVENANCE.md are); CI runs
# this as a setup step (cached) and the tests themselves need no network.
#
# usage:
#   tools/wasi-testsuite/vendor.sh            fetch the pinned commit, then verify
#   tools/wasi-testsuite/vendor.sh --verify   verify an existing copy only (no network)
#   tools/wasi-testsuite/vendor.sh --update-manifest <prod/testsuite-base sha>
#       refresh: fetch another commit and rewrite the manifest (update SHA,
#       SOURCE_SHA and the baseline in the same change)
#
# Verification fails on any hash mismatch, missing file or extra file.
set -euo pipefail

SHA="e0aa527fab67f2f311882bcee4f62cc755433b73"         # prod/testsuite-base
SOURCE_SHA="5ea11d8fe958beb60fb871d6852ae020e45c0433"  # main it was built from
REPO_URL="https://github.com/WebAssembly/wasi-testsuite"
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
DEST="${WASI_TESTSUITE_DIR:-$ROOT/tests/spec/wasi}"
MANIFEST="$HERE/manifest.sha256"

# Exactly what the runner reads: the P1 test directories (wasm, json specs,
# manifest, fixture dirs) and the runner's Python package.
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

sha256() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$@"; else shasum -a 256 "$@"; fi
}

# Files present in DEST that the manifest covers: everything except the
# committed PROVENANCE.md and Python bytecode caches.
present_files() {
  (cd "$DEST" && find . -type f ! -path './PROVENANCE.md' ! -name '*.pyc' \
    ! -path '*/__pycache__/*' | sed 's|^\./||' | LC_ALL=C sort)
}

verify() {
  [ -d "$DEST" ] || { echo "wasi-testsuite: $DEST missing; run tools/wasi-testsuite/vendor.sh" >&2; return 1; }
  local fail=0 expected
  expected="$(awk '{print $2}' "$MANIFEST" | LC_ALL=C sort)"
  local missing extra
  missing="$(LC_ALL=C comm -23 <(echo "$expected") <(present_files))"
  extra="$(LC_ALL=C comm -13 <(echo "$expected") <(present_files))"
  if [ -n "$missing" ]; then echo "$missing" | sed 's/^/MISSING: /' >&2; fail=1; fi
  if [ -n "$extra" ]; then echo "$extra" | sed 's/^/EXTRA: /' >&2; fail=1; fi
  local want path got
  while read -r want path; do
    [ -f "$DEST/$path" ] || continue
    got="$(cd "$DEST" && sha256 "$path" | awk '{print $1}')"
    if [ "$got" != "$want" ]; then echo "MISMATCH: $path" >&2; fail=1; fi
  done < "$MANIFEST"
  if [ "$fail" -ne 0 ]; then
    echo "wasi-testsuite: $DEST does not match $MANIFEST" >&2
    return 1
  fi
  echo "wasi-testsuite: verified $(wc -l < "$MANIFEST" | tr -d ' ') files against manifest ($SHA)"
}

fetch() {
  local sha="$1" work
  work="$(mktemp -d)"
  trap 'rm -rf "$work"' RETURN
  git -C "$work" init -q
  git -C "$work" remote add origin "$REPO_URL"
  git -C "$work" fetch -q --depth 1 origin "$sha"
  git -C "$work" checkout -q --detach FETCH_HEAD
  test "$(git -C "$work" rev-parse HEAD)" = "$sha"
  # Keep the committed PROVENANCE.md; replace everything else.
  find "$DEST" -mindepth 1 -maxdepth 1 ! -name PROVENANCE.md -exec rm -rf {} + 2>/dev/null || true
  mkdir -p "$DEST"
  # git archive exports exactly the tracked files (no caches, no .pyc).
  git -C "$work" archive --format=tar HEAD -- "${DIRS[@]}" "${FILES[@]}" | tar -x -C "$DEST"
}

case "${1:-}" in
  --verify) verify ;;
  --update-manifest)
    new="${2:?usage: vendor.sh --update-manifest <prod/testsuite-base sha>}"
    fetch "$new"
    (cd "$DEST" && present_files | while IFS= read -r f; do sha256 "$f"; done) > "$MANIFEST"
    echo "wrote $MANIFEST for $new; now set SHA/SOURCE_SHA in vendor.sh and update PROVENANCE.md" ;;
  "") fetch "$SHA"; verify ;;
  *) echo "usage: vendor.sh [--verify | --update-manifest <sha>]" >&2; exit 2 ;;
esac
