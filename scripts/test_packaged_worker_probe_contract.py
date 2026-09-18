import copy
import unittest
import contextlib
import io
import json
from pathlib import Path
import subprocess
import tempfile
from unittest.mock import patch

from test_packaged_worker_probe import run, validate_report


class ProbeContract(unittest.TestCase):
    def setUp(self):
        self.manifest = {"version": "0.0.1", "os": "macos", "architecture": "aarch64"}
        self.report = {"agentVersion": "0.0.1", "os": "macos", "arch": "aarch64",
                       "resources": {"logicalCpuCores": 8, "memoryMib": 16384, "diskMib": 10000}}

    def test_valid(self):
        validate_report(self.report, self.manifest)

    def test_wrong_identity(self):
        for field in ("agentVersion", "os", "arch"):
            with self.subTest(field=field):
                report = copy.deepcopy(self.report)
                report[field] = "wrong"
                with self.assertRaises(ValueError):
                    validate_report(report, self.manifest)

    def test_missing_or_invalid_capacity(self):
        for field in self.report["resources"]:
            for value in (None, False, 0, -1, "8", 1.5, float("nan"), float("inf")):
                with self.subTest(field=field, value=value):
                    report = copy.deepcopy(self.report)
                    report["resources"][field] = value
                    with self.assertRaises(ValueError):
                        validate_report(report, self.manifest)

    def test_run_binds_binary_workspace_and_timeout(self):
        with tempfile.TemporaryDirectory() as kit:
            (Path(kit) / "worker-kit.json").write_text(json.dumps(self.manifest), encoding="utf-8")
            workspaces = []

            def execute(args, **kwargs):
                self.assertEqual(args[0], str(Path(kit).resolve() / "cyc-worker"))
                self.assertEqual(args[1:3], ["probe", "--workspace"])
                workspace = Path(args[3])
                self.assertTrue(workspace.is_dir())
                self.assertIn("中文", workspace.name)
                self.assertEqual(kwargs["timeout"], 90)
                self.assertTrue(kwargs["check"])
                workspaces.append(workspace)
                return subprocess.CompletedProcess(args, 0, json.dumps(self.report))

            output = io.StringIO()
            with patch("platform.system", return_value="Darwin"), \
                 patch("platform.machine", return_value="arm64"), \
                 patch("subprocess.run", side_effect=execute), contextlib.redirect_stdout(output):
                run(kit)
            self.assertFalse(workspaces[0].exists())
            receipt = json.loads(output.getvalue())
            self.assertEqual(receipt["exitCode"], 0)
            self.assertFalse(receipt["serviceLifecycleTested"])

    def test_wrong_host_never_executes(self):
        with tempfile.TemporaryDirectory() as kit:
            (Path(kit) / "worker-kit.json").write_text(json.dumps(self.manifest), encoding="utf-8")
            with patch("platform.system", return_value="Linux"), \
                 patch("subprocess.run") as execute:
                with self.assertRaises(ValueError):
                    run(kit)
                execute.assert_not_called()

    def test_execution_failure_never_reports_pass(self):
        with tempfile.TemporaryDirectory() as kit:
            (Path(kit) / "worker-kit.json").write_text(json.dumps(self.manifest), encoding="utf-8")
            for error in (subprocess.CalledProcessError(1, "probe"),
                          subprocess.TimeoutExpired("probe", 90)):
                output = io.StringIO()
                with patch("platform.system", return_value="Darwin"), \
                     patch("platform.machine", return_value="arm64"), \
                     patch("subprocess.run", side_effect=error), contextlib.redirect_stdout(output):
                    with self.assertRaises(type(error)):
                        run(kit)
                self.assertEqual(output.getvalue(), "")


if __name__ == "__main__":
    unittest.main()
