#!/usr/bin/env python3
"""Require the pinned Core 3 corpus to pass, independently in every tier.

With more than one tier, the non-core scripts beneath the corpus root
(proposals, legacy, custom) must also produce byte-identical output in every
tier, apart from the TOTAL line's tier and compiled fields.
"""

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

TIER_FIELDS = re.compile(r" tier=\S+ compiled=\d+\b")


def run(runner: list[str], tier: str, scripts: list[Path]) -> subprocess.CompletedProcess:
    result = subprocess.run(
        [*runner, "--failures-only", f"--tier={tier}", *map(str, scripts)],
        capture_output=True, text=True, check=False,
    )
    print(result.stdout, end="")
    print(result.stderr, end="", file=sys.stderr)
    return result


def total_line(tier: str, stdout: str) -> str:
    totals = [line for line in stdout.splitlines() if line.startswith("TOTAL ")]
    if len(totals) != 1:
        raise ValueError(f"{tier}: expected exactly one TOTAL tally")
    return totals[0]


def check_tier_ran(tier: str, total: str) -> None:
    """A tier that silently fell back to the interpreter must not pass."""
    ran = re.findall(r"\btier=(\S+)", total)
    if ran != [tier]:
        raise ValueError(f"{tier}: expected tier={tier}, got {ran}")
    compiled = re.findall(r"\bcompiled=(\d+)\b", total)
    if len(compiled) != 1:
        raise ValueError(f"{tier}: expected exactly one compiled count")
    if tier == "interp" and int(compiled[0]) != 0:
        raise ValueError(f"interp: expected compiled=0, got {compiled[0]}")
    if tier != "interp" and int(compiled[0]) == 0:
        raise ValueError(f"{tier}: compiled no functions")


def check_core(runner: list[str], corpus: Path, tiers: list[str]) -> None:
    scripts = sorted(corpus.glob("*.wast"))
    if len(scripts) != EXPECTED["files"]:
        raise ValueError(f"expected {EXPECTED['files']} core scripts, found {len(scripts)}")
    for tier in tiers:
        result = run(runner, tier, scripts)
        if result.returncode != 0:
            raise ValueError(f"{tier}: wasmspec exited {result.returncode}")
        total = total_line(tier, result.stdout)
        check_tier_ran(tier, total)
        fields = re.findall(r"\b([a-z]+)=(\d+)\b", total)
        values = {key: int(value) for key, value in fields}
        if len(values) != len(fields):
            raise ValueError(f"{tier}: duplicate tally field")
        for key, expected in EXPECTED.items():
            if values.get(key) != expected:
                raise ValueError(f"{tier}: expected {key}={expected}, got {values.get(key)}")


def check_identity(runner: list[str], corpus: Path, tiers: list[str]) -> None:
    scripts = sorted(path for path in corpus.rglob("*.wast") if path.parent != corpus)
    if not scripts:
        raise ValueError("no non-core scripts found for the tier-identity check")
    reference = None
    for tier in tiers:
        result = run(runner, tier, scripts)
        total = total_line(tier, result.stdout)
        check_tier_ran(tier, total)
        observed = (result.returncode, TIER_FIELDS.sub("", result.stdout))
        if reference is None:
            reference = (tier, observed)
        elif observed != reference[1]:
            raise ValueError(
                f"{tier}: non-core output differs from {reference[0]} "
                f"(tiers must be observationally identical)")


def check(runner: list[str], corpus: Path, tiers: list[str]) -> None:
    check_core(runner, corpus, tiers)
    print("Pinned core conformance OK: " + ", ".join(tiers))
    if len(tiers) > 1:
        check_identity(runner, corpus, tiers)
        print("Non-core tier identity OK: " + ", ".join(tiers))


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
