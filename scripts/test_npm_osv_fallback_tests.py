#!/usr/bin/env python3
from pathlib import Path
import sys
import unittest

# ``python -m unittest scripts/test_npm_osv_fallback_tests.py`` does not add
# the script directory to ``sys.path`` on every supported Python launcher.
sys.path.insert(0, str(Path(__file__).resolve().parent))
import test_npm_osv_fallback as fallback


class OsvFallbackTests(unittest.TestCase):
    def test_collects_nested_resolved_packages_and_deduplicates(self):
        inventory = [
            {
                "name": "workspace",
                "dependencies": {
                    "react": {
                        "version": "19.2.8",
                        "resolved": "https://registry.npmjs.org/react/-/react-19.2.8.tgz",
                        "dependencies": {
                            "scheduler": {
                                "version": "0.27.1",
                                "resolved": "https://registry.npmjs.org/scheduler/-/scheduler-0.27.1.tgz",
                            }
                        },
                    },
                    "alias": {"version": "link:../alias", "resolved": "workspace:alias"},
                },
                "devDependencies": {
                    "react-copy": {
                        "version": "19.2.8",
                        "resolved": "https://registry.npmjs.org/react/-/react-19.2.8.tgz",
                    }
                },
            }
        ]
        self.assertEqual(
            fallback.collect_packages(inventory),
            [("react", "19.2.8"), ("react-copy", "19.2.8"), ("scheduler", "0.27.1")],
        )

    def test_peer_suffix_is_normalised(self):
        self.assertEqual(fallback._normalise_version("4.1.11(@types/node@24.13.3)"), "4.1.11")
        self.assertIsNone(fallback._normalise_version("workspace:*"))

    def test_low_advisory_is_below_moderate_gate(self):
        self.assertFalse(fallback._relevant_severity({"database_specific": {"severity": "LOW"}}))
        self.assertFalse(fallback._relevant_severity({"database_specific": {"severity": "none"}}))

    def test_moderate_high_and_unknown_fail_closed(self):
        for severity in ("MODERATE", "MEDIUM", "HIGH", "CRITICAL", ""):
            detail = {"database_specific": {"severity": severity}} if severity else {}
            self.assertTrue(fallback._relevant_severity(detail))


if __name__ == "__main__":
    unittest.main()
