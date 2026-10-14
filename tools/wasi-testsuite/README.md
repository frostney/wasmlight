# wasi-testsuite adapter

Runs the pinned [WebAssembly/wasi-testsuite](https://github.com/WebAssembly/wasi-testsuite)
Preview 1 corpus against `wasmlight run`. This is the external oracle for #78. The committed baseline is the
work list for #79–#85.

| Path | Role |
| --- | --- |
| `../../tests/spec/wasi/` | Fetched corpus and upstream runner (Apache-2.0, git-ignored except `LICENSE` and `PROVENANCE.md`) |
| `vendor.sh` | Fetches the pinned commit (`e0aa527`) and verifies it against `manifest.sha256` |
| `manifest.sha256` | sha256 per path for all 151 corpus files; any mismatch, missing or extra file fails |
| `wasmlight.py` | Upstream-protocol runtime adapter; reads `$WASMLIGHT` (default `build/wasmlight`) |
| `run.py` | Runs the P1 suites, prints the tally and diffs against the baseline |
| `expectations/{linux,macos}.toml` | Baseline in upstream's expectations format |

## Run

```bash
tools/wasi-testsuite/vendor.sh   # fetch + verify (~103 MB, once); --verify re-checks offline
python3 -m pip install -r tests/spec/wasi/test-runner/requirements/common.txt
lwpt build --mode release wasmlight
lwpt run wasi-testsuite        # = python3 tools/wasi-testsuite/run.py
```

- The corpus is no longer committed (it was ~103 MB / 151 files); `lwpt run wasi-testsuite` fails with a clear message if it has not been fetched. CI fetches it in a setup step cached on the pinned commit + manifest hash; the test run itself uses no network.
- Each test that declares a fixture root (`fs-tests.dir`) runs against its own scratch copy, mapped as `--dir /=<copy>`. The fetched fixtures are never written.
- Every test has a timeout (`$WASI_TESTSUITE_TIMEOUT`, default 30 s). A timeout is a failure, never a skip.
- `run.py` exits non-zero only when results differ from the baseline: a new failure (including a timeout), an unexpected pass (stale entry) or a baseline entry that matches no test. Results go to `build/wasi-testsuite/results.json`.

## Baseline

- Each `expected = "fail"` entry is commented with the issue that owns the WASI function it exercises (#79–#85). When an issue lands, delete its entries; `run.py` flags any entry left behind as an unexpected pass.
- Socket cases (`sock_*`) are listed separately with `action = "skip"`. They are reported as unsupported, outside the non-network scope, and are not failures.

## Refresh the corpus

```bash
tools/wasi-testsuite/vendor.sh --update-manifest <prod/testsuite-base sha>
```

Then set `SHA`/`SOURCE_SHA` in `vendor.sh`, update `PROVENANCE.md`, rerun and update the baseline in the same change.
