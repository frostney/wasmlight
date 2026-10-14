# wasi-testsuite provenance

- Repository: WebAssembly/wasi-testsuite (https://github.com/WebAssembly/wasi-testsuite)
- Branch: prod/testsuite-base
- Commit: e0aa527fab67f2f311882bcee4f62cc755433b73
- Source main commit: 5ea11d8fe958beb60fb871d6852ae020e45c0433
- Licence: Apache-2.0 (LICENSE, committed unmodified)
- Fetch: `tools/wasi-testsuite/vendor.sh` (not committed; this directory is git-ignored except LICENSE and this file)
- Integrity: `tools/wasi-testsuite/manifest.sha256`, sha256 per path, 151 files.
  `vendor.sh` fails on any hash mismatch, missing file or extra file;
  `vendor.sh --verify` re-checks an existing copy without network.
- Refresh: `tools/wasi-testsuite/vendor.sh --update-manifest <commit>`, then update
  the pinned SHA/SOURCE_SHA in `vendor.sh`, this file and the baseline in the same change.

Fetched paths (copied unmodified):

- `LICENSE`
- `test-runner/wasi_test_runner.py`
- `test-runner/requirements/common.txt`
- `tests/assemblyscript/testsuite/wasm32-wasip1`
- `tests/c/testsuite/wasm32-wasip1`
- `tests/rust/testsuite/wasm32-wasip1`
- `test-runner/wasi_test_runner`
