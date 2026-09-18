import copy
import unittest

from test_packaged_worker_probe import validate_report


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
            for value in (None, False, 0, -1, "8"):
                with self.subTest(field=field, value=value):
                    report = copy.deepcopy(self.report)
                    report["resources"][field] = value
                    with self.assertRaises(ValueError):
                        validate_report(report, self.manifest)


if __name__ == "__main__":
    unittest.main()
