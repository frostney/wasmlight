#!/usr/bin/env python3
"""Run the fetched wasi-testsuite Preview 1 corpus against wasmlight and
compare the results with the committed baseline.

Exit status is non-zero only when the results differ from the baseline: a
test that fails but is not listed as `expected = "fail"` (a new failure,
timeouts included), or a listed test that now passes (an unexpected pass,
so the baseline is stale). Every difference is printed.

usage: tools/wasi-testsuite/run.py [--expectations FILE] [--json-output FILE]
  $WASMLIGHT                binary to test (default build/wasmlight)
  $WASI_TESTSUITE_TIMEOUT   per-test timeout in seconds (default 30)
"""

import argparse
import json
import subprocess
import sys
import tomllib
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
CORPUS = ROOT / "tests" / "spec" / "wasi"
SUITES = [
    CORPUS / "tests" / "assemblyscript" / "testsuite" / "wasm32-wasip1",
    CORPUS / "tests" / "c" / "testsuite" / "wasm32-wasip1",
    CORPUS / "tests" / "rust" / "testsuite" / "wasm32-wasip1",
]
RUNNER = CORPUS / "test-runner" / "wasi_test_runner.py"
ADAPTER = HERE / "wasmlight.py"


def default_expectations() -> Path:
    name = "macos" if sys.platform == "darwin" else "linux"
    return HERE / "expectations" / f"{name}.toml"


def baseline_names(path: Path) -> set[tuple[str, str]]:
    with open(path, "rb") as f:
        data = tomllib.load(f)
    return {(s["name"], t["name"]) for s in data.get("suite", [])
            for t in s.get("test", [])}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--expectations", type=Path, default=default_expectations())
    parser.add_argument("--json-output", type=Path,
                        default=ROOT / "build" / "wasi-testsuite" / "results.json")
    opts = parser.parse_args()
    missing = [p for p in (RUNNER, *SUITES) if not p.exists()]
    if missing:
        print(f"wasi-testsuite corpus not fetched: {missing[0]} is missing.\n"
              "Run tools/wasi-testsuite/vendor.sh first (fetches the pinned "
              "commit and verifies it against tools/wasi-testsuite/manifest.sha256).",
              file=sys.stderr)
        return 2
    opts.json_output.parent.mkdir(parents=True, exist_ok=True)

    cmd = [sys.executable, str(RUNNER), "-t", *map(str, SUITES),
           "-r", str(ADAPTER), "-e", str(opts.expectations),
           "--json-output-location", str(opts.json_output), "--disable-colors"]
    # The runner's own exit status is ignored: the baseline comparison
    # below decides. Its console report still goes to the log.
    subprocess.run(cmd, check=False)

    with open(opts.json_output, encoding="UTF-8") as f:
        results = json.load(f)["results"]

    seen: set[tuple[str, str]] = set()
    tally = {"pass": 0, "fail": 0, "unsupported": 0, "timeout": 0}
    diffs: list[str] = []
    for suite in results:
        for test in suite["tests"]:
            key = (suite["name"], test["name"])
            seen.add(key)
            outcome = test["outcome"]
            timed_out = any("timeout expired" in m for m in test["failures"])
            if outcome == "skip":
                tally["unsupported"] += 1
            elif outcome in ("pass", "xpass"):
                tally["pass"] += 1
            else:
                tally["fail"] += 1
                if timed_out:
                    tally["timeout"] += 1
            if outcome == "fail":
                why = "timeout" if timed_out else "failure"
                diffs.append(f"NEW {why.upper()}: {key[0]} :: {key[1]}")
                diffs.extend(f"    {m.splitlines()[0]}" for m in test["failures"][:1])
            elif outcome == "xpass":
                diffs.append(f"UNEXPECTED PASS (baseline stale): {key[0]} :: {key[1]}")

    for key in sorted(baseline_names(opts.expectations) - seen):
        diffs.append(f"BASELINE ENTRY MATCHES NO TEST: {key[0]} :: {key[1]}")

    total = sum(tally[k] for k in ("pass", "fail", "unsupported"))
    print(f"\nwasi-testsuite P1 tally ({total} tests): pass={tally['pass']} "
          f"fail={tally['fail']} (timeouts={tally['timeout']}) "
          f"unsupported={tally['unsupported']}")
    if diffs:
        print(f"\nResults differ from baseline {opts.expectations}:")
        print("\n".join(diffs))
        return 1
    print(f"Results match baseline {opts.expectations}.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
