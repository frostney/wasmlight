"""Exercise the real gate with deliberately incorrect runner behavior."""

import re
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

GATE = Path(__file__).with_name("check.py")
GOOD = "TOTAL files=257 errors=0 pass=65188 fail=0 skip=0 staged=0 total=65188"


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

    def run_gate(self, tally=GOOD, status=0, tiers=("interp",)):
        self.runner.write_text(
            "import json, sys\nfrom pathlib import Path\n"
            "assert len(sys.argv[3:]) == 257\n"
            "assert all(Path(p).parent == Path(__file__).parent for p in sys.argv[3:])\n"
            f"print({tally!r})\n"
            f"sys.exit({status})\n"
        )
        args = [sys.executable, str(GATE), "--runner", sys.executable, str(self.runner),
                "--corpus", str(self.root)]
        for tier in tiers:
            args += ["--tier", tier]
        return subprocess.run(args, capture_output=True, text=True, check=False)

    def test_all_tiers_pass_with_only_root_scripts(self):
        result = self.run_gate(tiers=("interp", "jit", "aot"))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.count(GOOD), 3)

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


if __name__ == "__main__":
    unittest.main()
