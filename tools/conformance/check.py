#!/usr/bin/env python3
"""Require the pinned Core 3 corpus to pass, independently in every tier."""

import argparse
from pathlib import Path
import re
import subprocess
import sys

EXPECTED = {
    "files": 257,
    "errors": 0,
    "pass": 65188,
    "fail": 0,
    "skip": 0,
    "staged": 0,
    "total": 65188,
}


def check(runner: list[str], corpus: Path, tiers: list[str]) -> None:
    scripts = sorted(corpus.glob("*.wast"))
    if len(scripts) != EXPECTED["files"]:
        raise ValueError(f"expected {EXPECTED['files']} core scripts, found {len(scripts)}")
    for tier in tiers:
        result = subprocess.run(
            [*runner, "--failures-only", f"--tier={tier}", *map(str, scripts)],
            capture_output=True, text=True, check=False,
        )
        print(result.stdout, end="")
        print(result.stderr, end="", file=sys.stderr)
        if result.returncode != 0:
            raise ValueError(f"{tier}: wasmspec exited {result.returncode}")
        totals = [line for line in result.stdout.splitlines() if line.startswith("TOTAL ")]
        if len(totals) != 1:
            raise ValueError(f"{tier}: expected exactly one TOTAL tally")
        fields = re.findall(r"\b([a-z]+)=(\d+)\b", totals[0])
        values = {key: int(value) for key, value in fields}
        if len(values) != len(fields):
            raise ValueError(f"{tier}: duplicate tally field")
        for key, expected in EXPECTED.items():
            if values.get(key) != expected:
                raise ValueError(f"{tier}: expected {key}={expected}, got {values.get(key)}")
    print("Pinned core conformance OK: " + ", ".join(tiers))


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--runner", nargs="+", required=True)
    parser.add_argument("--corpus", type=Path, required=True)
    parser.add_argument("--tier", action="append", choices=("interp", "jit", "aot"))
    args = parser.parse_args()
    try:
        check(args.runner, args.corpus, args.tier or ["interp"])
    except (OSError, ValueError) as error:
        print(f"conformance: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
