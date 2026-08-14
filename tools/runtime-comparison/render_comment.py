#!/usr/bin/env python3
"""Render the sticky pull-request comment for runtime comparison results."""

from __future__ import annotations

import argparse
import json
import math
from pathlib import Path


MARKER = "<!-- wasmlight-runtime-comparison -->"
PEERS = ("Wasmtime", "Wasmer", "WasmEdge", "WAMR", "wazero", "wasm3")


def read_report(path: Path | None) -> dict | None:
    if path is None or not path.is_file():
        return None
    try:
        report = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return None
    if not isinstance(report, dict) or not isinstance(report.get("results"), list):
        return None
    return report


def result_map(report: dict) -> dict[tuple[str, str], dict]:
    mapped = {}
    for row in report["results"]:
        if not isinstance(row, dict) or row.get("profile") != "best":
            continue
        median = row.get("median_ms")
        if not isinstance(median, (int, float)) or not math.isfinite(median) or median <= 0:
            continue
        mapped[(str(row.get("workload")), str(row.get("runtime")))] = row
    return mapped


def format_ms(row: dict | None) -> str:
    return "—" if row is None else f"{row['median_ms']:.3f} ms"


def format_peer(candidate: dict | None, peer: dict | None) -> str:
    if peer is None:
        return "—"
    if candidate is None:
        return format_ms(peer)
    ratio = candidate["median_ms"] / peer["median_ms"]
    return f"{peer['median_ms']:.3f} ms ({ratio:.2f}x)"


def ranges_overlap(left: dict, right: dict) -> bool:
    required = ("min_ms", "max_ms")
    if any(not isinstance(left.get(key), (int, float)) for key in required):
        return False
    if any(not isinstance(right.get(key), (int, float)) for key in required):
        return False
    return left["min_ms"] <= right["max_ms"] and right["min_ms"] <= left["max_ms"]


def format_delta(baseline: dict | None, current: dict | None) -> str:
    if baseline is None or current is None:
        return "—"
    base = baseline["median_ms"]
    candidate = current["median_ms"]
    if ranges_overlap(baseline, current):
        change = (base / candidate - 1.0) * 100.0
        return f"~ overlap ({change:+.1f}%)"
    if candidate < base:
        return f"🟢 {(base / candidate - 1.0) * 100.0:.1f}% faster"
    return f"🔴 {(candidate / base - 1.0) * 100.0:.1f}% slower"


def short_sha(value: str | None) -> str:
    return value[:12] if value else "unavailable"


def build_comment(
    baseline: dict | None,
    current: dict | None,
    *,
    base_sha: str | None = None,
    head_sha: str | None = None,
    run_url: str | None = None,
) -> str:
    lines = [MARKER, "## Runtime comparison", ""]
    if current is None:
        lines.append("❌ The candidate comparison did not produce a valid report.")
        if run_url:
            lines.extend(("", f"[Inspect the workflow run]({run_url})."))
        return "\n".join(lines) + "\n"

    current_rows = result_map(current)
    baseline_rows = result_map(baseline) if baseline else {}
    workloads = [str(value) for value in current.get("workloads", [])]
    if not workloads:
        lines.append("❌ The candidate report contains no workloads.")
        return "\n".join(lines) + "\n"

    if baseline is None:
        lines.append("⚠️ The base comparison report is unavailable; PR-vs-main deltas cannot be shown.")
        lines.append("")
    else:
        lines.append(
            f"Same-runner comparison of main `{short_sha(base_sha)}` and PR "
            f"`{short_sha(head_sha)}`. Lower is better."
        )
        lines.append("")

    header = ["Workload", "main", "PR", "Δ PR vs main", *PEERS]
    lines.append("| " + " | ".join(header) + " |")
    lines.append("| " + " | ".join(["---", *(["---:"] * (len(header) - 1))]) + " |")
    for workload in workloads:
        base_row = baseline_rows.get((workload, "wasmlight"))
        current_row = current_rows.get((workload, "wasmlight"))
        cells = [
            workload,
            format_ms(base_row),
            format_ms(current_row),
            format_delta(base_row, current_row),
        ]
        cells.extend(
            format_peer(current_row, current_rows.get((workload, peer)))
            for peer in PEERS
        )
        lines.append("| " + " | ".join(cells) + " |")

    method = current.get("method", {})
    sample_count = method.get("samples", "?")
    warmups = method.get("warmups", "?")
    host = current.get("host", {})
    lines.extend(
        (
            "",
            f"Medians from {sample_count} rotated samples after {warmups} warm-up on "
            f"`{host.get('os', 'unknown host')}`. Compilation and cache population are "
            "outside the timer; every workload verifies its result.",
            "",
            "Peer ratios are `PR wasmlight / peer`: above 1 means the peer was faster. "
            "Peer columns use each pinned runtime's best available CI configuration.",
            "",
            "This required check gates build, preparation, and successful execution only. "
            "Timing deltas are informational and never fail the PR.",
            "",
            "Raw samples, ranges, commands, versions, artifact sizes, and module hashes are "
            "available in the `runtime-comparison-results` workflow artifact.",
        )
    )
    if run_url:
        lines.extend(("", f"[Workflow run]({run_url})"))
    return "\n".join(lines) + "\n"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--baseline", type=Path)
    parser.add_argument("--current", type=Path)
    parser.add_argument("--base-sha")
    parser.add_argument("--head-sha")
    parser.add_argument("--run-url")
    parser.add_argument("--output", type=Path, required=True)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    body = build_comment(
        read_report(args.baseline),
        read_report(args.current),
        base_sha=args.base_sha,
        head_sha=args.head_sha,
        run_url=args.run_url,
    )
    args.output.write_text(body, encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
