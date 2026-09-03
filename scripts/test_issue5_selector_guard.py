#!/usr/bin/env python3
"""Unit tests for the fail-closed Issue #5 selector guard."""

import unittest
from pathlib import Path
import sys
from typing import List, Mapping, Sequence

# Make the test runnable both as ``python scripts/test_...py`` and through
# ``python -m unittest`` from the repository root; ``scripts`` is intentionally
# not a Python package in the project.
sys.path.insert(0, str(Path(__file__).resolve().parent))

from issue5_selector_guard import (
    CommandOutcome,
    EXPECTED_SELECTORS,
    parse_test_result,
    run_guard,
)


class FakeRunner:
    def __init__(self, listed: CommandOutcome, executed: CommandOutcome):
        self.listed = listed
        self.executed = executed
        self.commands: List[Sequence[str]] = []

    def __call__(
        self,
        command: Sequence[str],
        cwd: Path,
        env: Mapping[str, str],
        timeout_seconds: float,
    ) -> CommandOutcome:
        self.commands.append(command)
        return self.listed if "--list" in command else self.executed


class Issue5SelectorGuardTests(unittest.TestCase):
    repo = Path(__file__).resolve().parents[1]
    selector = EXPECTED_SELECTORS["linux"]

    def test_nonexistent_selector_fails_before_execution(self) -> None:
        runner = FakeRunner(
            CommandOutcome(0, "isolation::tests::some_other_test: test\n"),
            CommandOutcome(0, "test result: ok. 1 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out;\n"),
        )
        result = run_guard(
            self.repo,
            "linux",
            host_system="Linux",
            runner=runner,
        )
        self.assertEqual(result["status"], "failed")
        self.assertEqual(result["list"]["selectorMatches"], 0)
        self.assertEqual(len(runner.commands), 1)
        self.assertEqual(result["errors"][0]["code"], "selector_not_found")

    def test_zero_tests_fails_closed(self) -> None:
        runner = FakeRunner(
            CommandOutcome(0, self.selector + ": test\n"),
            CommandOutcome(
                0,
                "running 0 tests\n\ntest result: ok. 0 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out;\n",
            ),
        )
        result = run_guard(
            self.repo,
            "linux",
            host_system="Linux",
            runner=runner,
        )
        self.assertEqual(result["status"], "failed")
        self.assertEqual(result["tests"]["passed"], 0)
        self.assertEqual(result["tests"]["failed"], 0)
        self.assertIn("tests_passed_zero", [error["code"] for error in result["errors"]])

    def test_success_requires_exact_selector_and_positive_summary(self) -> None:
        runner = FakeRunner(
            CommandOutcome(0, "prefix\n" + self.selector + ": test\nsuffix\n"),
            CommandOutcome(
                0,
                "test result: ok. 1 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; finished in 0.01s\n",
            ),
        )
        result = run_guard(
            self.repo,
            "linux",
            host_system="Linux",
            runner=runner,
        )
        self.assertEqual(result["status"], "passed")
        self.assertEqual(result["tests"]["passed"], 1)
        self.assertEqual(result["tests"]["failed"], 0)
        self.assertEqual(len(runner.commands), 2)
        self.assertEqual(runner.commands[1][-1], self.selector)
        self.assertIn("--exact", runner.commands[1])
        self.assertIn("--ignored", runner.commands[1])

    def test_summary_parser_rejects_missing_result(self) -> None:
        self.assertIsNone(parse_test_result("running 1 test\ntest foo ... ok\n"))


if __name__ == "__main__":
    unittest.main()
