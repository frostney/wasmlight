"""Exercise the real gate with deliberately incorrect runner behavior."""

import json
import re
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

GATE = Path(__file__).with_name("check.py")
GOOD = "TOTAL files=257 errors=0 tier={tier} compiled={compiled} pass=65188 fail=0 skip=0 staged=0 total=65188"
NESTED = ("FAIL proposals/outside.wast:3 assert_return\n"
          "TOTAL files=1 errors=0 tier={tier} compiled={compiled} pass=1 fail=1 skip=0 staged=0 total=2")

# The fake runner reads its behavior from runner.json: the core tally and exit
# status, per-tier overrides, and the non-core output and exit status.
RUNNER = """\
import json, sys
from pathlib import Path
here = Path(__file__).parent
spec = json.loads((here / "runner.json").read_text())
tier = sys.argv[2].removeprefix("--tier=")
scripts = [Path(p) for p in sys.argv[3:]]
compiled = spec["compiled"].get(tier, 0 if tier == "interp" else 42)
if all(p.parent == here for p in scripts):
    assert len(scripts) == 257
    print(spec["tally"].format(tier=spec["reported_tier"].get(tier, tier), compiled=compiled))
    sys.exit(spec["status"])
assert all(p.parent != here for p in scripts)
print(spec["nested"].get(tier, spec["nested"]["interp"]).format(tier=tier, compiled=compiled))
sys.exit(spec["nested_status"].get(tier, 1))
"""


class ConformanceGateTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        for index in range(257):
            (self.root / f"{index}.wast").touch()
        proposals = self.root / "proposals"
        proposals.mkdir()
        (proposals / "outside.wast").touch()
        self.runner = self.root / "runner.py"
        self.runner.write_text(RUNNER)

    def run_gate(self, tally=GOOD, status=0, tiers=("interp",), reported_tier=None,
                 compiled=None, nested=None, nested_status=None):
        (self.root / "runner.json").write_text(json.dumps({
            "tally": tally,
            "status": status,
            "reported_tier": reported_tier or {},
            "compiled": compiled or {},
            "nested": {"interp": NESTED, **(nested or {})},
            "nested_status": nested_status or {},
        }))
        args = [sys.executable, str(GATE), "--runner", sys.executable, str(self.runner),
                "--corpus", str(self.root)]
        for tier in tiers:
            args += ["--tier", tier]
        return subprocess.run(args, capture_output=True, text=True, check=False)

    def test_all_tiers_pass_with_only_root_scripts(self):
        result = self.run_gate(tiers=("interp", "jit", "aot"))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Pinned core conformance OK: interp, jit, aot", result.stdout)
        self.assertIn("Non-core tier identity OK: interp, jit, aot", result.stdout)

    def test_interp_only_skips_the_identity_check(self):
        result = self.run_gate()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("Non-core tier identity", result.stdout)

    def test_runner_failure_cannot_be_hidden_by_a_good_tally(self):
        result = self.run_gate(status=1)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("wasmspec exited 1", result.stderr)

    def test_incorrect_tallies_fail_even_when_runner_exits_zero(self):
        for field, value in [("pass", 65187), ("fail", 1), ("skip", 1),
                             ("staged", 1), ("errors", 1), ("files", 256),
                             ("total", 65187)]:
            with self.subTest(field=field):
                tally = re.sub(rf"\b{field}=\d+", f"{field}={value}", GOOD)
                result = self.run_gate(tally=tally)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(f"expected {field}=", result.stderr)

    def test_missing_duplicate_and_ambiguous_tallies_fail(self):
        for tally in ("", GOOD + "\n" + GOOD, GOOD + " pass=65188", GOOD.replace(" skip=0", "")):
            with self.subTest(tally=tally):
                self.assertNotEqual(self.run_gate(tally=tally).returncode, 0)

    def test_missing_core_script_fails_before_execution(self):
        (self.root / "0.wast").unlink()
        result = self.run_gate()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("expected 257 core scripts, found 256", result.stderr)

    def test_a_tier_that_fell_back_to_the_interpreter_fails(self):
        result = self.run_gate(tiers=("interp", "jit"), reported_tier={"jit": "interp"})
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("jit: expected tier=jit", result.stderr)

    def test_a_compiling_tier_that_compiled_nothing_fails(self):
        for tier in ("jit", "aot"):
            with self.subTest(tier=tier):
                result = self.run_gate(tiers=("interp", tier), compiled={tier: 0})
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(f"{tier}: compiled no functions", result.stderr)

    def test_an_interpreter_run_that_compiled_code_fails(self):
        result = self.run_gate(compiled={"interp": 5})
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("interp: expected compiled=0", result.stderr)

    def test_non_core_output_divergence_fails(self):
        diverged = NESTED.replace("outside.wast:3", "outside.wast:4")
        result = self.run_gate(tiers=("interp", "jit", "aot"), nested={"aot": diverged})
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("aot: non-core output differs from interp", result.stderr)

    def test_non_core_divergence_is_located_and_passing_runs_stay_quiet(self):
        diverged = NESTED.replace("outside.wast:3", "outside.wast:4")
        result = self.run_gate(tiers=("interp", "jit"), nested={"jit": diverged})
        self.assertIn("-FAIL proposals/outside.wast:3 assert_return", result.stderr)
        self.assertIn("+FAIL proposals/outside.wast:4 assert_return", result.stderr)
        quiet = self.run_gate(tiers=("interp", "jit"))
        self.assertEqual(quiet.returncode, 0, quiet.stderr)
        self.assertNotIn("FAIL proposals/", quiet.stdout)
        self.assertEqual(quiet.stdout.count("TOTAL files=1 "), 2)

    def test_non_core_exit_status_divergence_fails(self):
        result = self.run_gate(tiers=("interp", "jit"), nested_status={"jit": 0})
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("exit status: interp=1 jit=0", result.stderr)
        self.assertIn("jit: non-core output differs from interp", result.stderr)

    def test_a_tier_that_crashes_before_its_tally_shows_where(self):
        crashed = "FAIL proposals/outside.wast:9 crashed-here"
        result = self.run_gate(tiers=("interp", "jit"), nested={"jit": crashed},
                               nested_status={"jit": 139})
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("jit: exit status 139; last output:", result.stderr)
        self.assertIn(crashed, result.stderr)
        self.assertIn("jit: expected exactly one TOTAL tally", result.stderr)

    def test_a_long_divergence_is_truncated_visibly(self):
        long = "\n".join(f"FAIL proposals/outside.wast:{n} x" for n in range(300))
        result = self.run_gate(tiers=("interp", "jit"),
                               nested={"jit": long + "\n" + NESTED.splitlines()[1]})
        self.assertNotEqual(result.returncode, 0)
        self.assertRegex(result.stderr, r"\.\.\. \d+ more diff lines")

    def test_missing_non_core_scripts_fail_the_identity_check(self):
        (self.root / "proposals" / "outside.wast").unlink()
        result = self.run_gate(tiers=("interp", "jit"))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("no non-core scripts found", result.stderr)


if __name__ == "__main__":
    unittest.main()
