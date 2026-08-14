#!/usr/bin/env python3

import unittest

from render_comment import MARKER, build_comment, format_delta


def row(median: float, minimum: float, maximum: float) -> dict:
    return {"median_ms": median, "min_ms": minimum, "max_ms": maximum}


def report(wasmlight: dict, wasmtime: dict) -> dict:
    return {
        "workloads": ["loop"],
        "method": {"samples": 7, "warmups": 1},
        "host": {"os": "Linux-x86_64"},
        "results": [
            {"profile": "best", "workload": "loop", "runtime": "wasmlight", **wasmlight},
            {"profile": "best", "workload": "loop", "runtime": "Wasmtime", **wasmtime},
        ],
    }


class RenderCommentTests(unittest.TestCase):
    def test_non_overlapping_improvement(self) -> None:
        self.assertEqual(
            format_delta(row(100.0, 98.0, 102.0), row(80.0, 79.0, 81.0)),
            "🟢 25.0% faster",
        )

    def test_overlap_is_noise(self) -> None:
        self.assertEqual(
            format_delta(row(100.0, 95.0, 105.0), row(98.0, 96.0, 101.0)),
            "~ overlap (+2.0%)",
        )

    def test_comment_has_marker_delta_peers_and_policy(self) -> None:
        baseline = report(row(100.0, 99.0, 101.0), row(50.0, 49.0, 51.0))
        current = report(row(80.0, 79.0, 81.0), row(48.0, 47.0, 49.0))
        body = build_comment(
            baseline,
            current,
            base_sha="a" * 40,
            head_sha="b" * 40,
            run_url="https://example.invalid/run",
        )
        self.assertIn(MARKER, body)
        self.assertIn("🟢 25.0% faster", body)
        self.assertIn("| loop | 100.000 ms | 80.000 ms", body)
        self.assertIn("| Wasmtime |", body)
        self.assertIn("48.000 ms (1.67x)", body)
        self.assertIn("Timing deltas are informational", body)
        self.assertIn("runtime-comparison-results", body)

    def test_missing_candidate_reports_failure(self) -> None:
        body = build_comment(None, None, run_url="https://example.invalid/run")
        self.assertIn("did not produce a valid report", body)
        self.assertIn("Inspect the workflow run", body)


if __name__ == "__main__":
    unittest.main()
