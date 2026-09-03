#!/usr/bin/env python3
"""Fail-closed Issue #5 native selector guard.

The hostile-workload acceptance probes are platform-specific and several of
the regression tests intentionally fail closed.  A successful ordinary
``cargo test`` invocation is therefore not enough: this module first proves
that the positive selector is present in the current target's test list, then
runs exactly that selector and validates the Rust test summary.

The implementation uses only the Python standard library and passes command
arguments as an argv list.  This keeps it usable from PowerShell, Bash, CI,
and the Linux native probe without invoking a shell or interpolating a test
name into shell syntax.
"""

from __future__ import annotations

import argparse
import datetime as _datetime
import json
import os
import platform as _platform
import shlex
import subprocess
import sys
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Callable, Dict, Iterable, List, Mapping, Optional, Sequence, Tuple


SCHEMA_VERSION = 1
RESULT_KIND = "cyc.dev/issue5-selector-guard/v1"
DEFAULT_TIMEOUT_SECONDS = 1800.0
MAX_DIAGNOSTIC_CHARS = 8192

PLATFORMS = ("linux", "windows", "macos")
EXPECTED_SELECTORS = {
    "linux": "isolation::tests::linux_live_dedicated_identity_credential_and_residual_reconciliation",
    "windows": "isolation::tests::windows_native_containment_job_object_and_guard",
    "macos": "isolation::tests::macos_live_external_reconciliation",
}


@dataclass
class CommandOutcome:
    """A small runner result that is easy to replace in unit tests."""

    returncode: Optional[int]
    stdout: str = ""
    stderr: str = ""
    error: Optional[str] = None


Runner = Callable[[Sequence[str], Path, Mapping[str, str], float], CommandOutcome]


def detect_host_platform(system_name: Optional[str] = None) -> Optional[str]:
    """Map the host OS name to the Issue #5 platform vocabulary."""

    name = system_name if system_name is not None else _platform.system()
    return {
        "Linux": "linux",
        "Windows": "windows",
        "Darwin": "macos",
    }.get(name)


def _utc_now() -> str:
    return (
        _datetime.datetime.now(_datetime.timezone.utc)
        .replace(microsecond=0)
        .isoformat()
        .replace("+00:00", "Z")
    )


def _clip(value: str, limit: int = MAX_DIAGNOSTIC_CHARS) -> str:
    """Bound command diagnostics so a noisy compiler cannot inflate JSON."""

    if len(value) <= limit:
        return value
    head = limit // 2
    tail = limit - head
    return value[:head] + "\n...[truncated]...\n" + value[-tail:]


def _display_command(command: Sequence[str]) -> str:
    # shlex.join is a display-only representation.  The actual subprocess
    # invocation always receives the unmodified argv list.
    return shlex.join([str(item) for item in command])


def build_list_command(repo: Path, cargo: str = "cargo") -> List[str]:
    """Build the exact cargo command used to enumerate library tests."""

    return [
        cargo,
        "test",
        "--manifest-path",
        str(repo / "Cargo.toml"),
        "-p",
        "cyc-worker",
        "--lib",
        "--locked",
        "--",
        "--list",
    ]


def build_run_command(
    repo: Path,
    platform_name: str,
    selector: Optional[str] = None,
    cargo: str = "cargo",
) -> List[str]:
    """Build the platform-specific exact selector command."""

    if platform_name not in EXPECTED_SELECTORS:
        raise ValueError("unknown Issue #5 platform: " + platform_name)
    selected = selector if selector is not None else EXPECTED_SELECTORS[platform_name]
    command = [
        cargo,
        "test",
        "--manifest-path",
        str(repo / "Cargo.toml"),
        "-p",
        "cyc-worker",
        "--lib",
        "--locked",
        "--",
    ]
    # The Linux positive probe is ignored because it needs root/cgroup-v2 and
    # a disposable identity.  The Windows/macOS positive selectors are live
    # probes and must not be silently widened with --ignored.
    if platform_name == "linux":
        command.append("--ignored")
    command.extend(["--exact", "--nocapture", selected])
    return command


def run_subprocess(
    command: Sequence[str],
    cwd: Path,
    env: Mapping[str, str],
    timeout_seconds: float,
) -> CommandOutcome:
    """Run one command without a shell and preserve bounded text output."""

    try:
        completed = subprocess.run(
            list(command),
            cwd=str(cwd),
            env=dict(env),
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
            timeout=timeout_seconds,
            check=False,
        )
    except subprocess.TimeoutExpired as error:
        stdout = error.stdout if isinstance(error.stdout, str) else ""
        stderr = error.stderr if isinstance(error.stderr, str) else ""
        return CommandOutcome(
            returncode=None,
            stdout=stdout,
            stderr=stderr,
            error="command timed out after {:.3f}s".format(timeout_seconds),
        )
    except (OSError, ValueError) as error:
        return CommandOutcome(
            returncode=None,
            error="{}: {}".format(type(error).__name__, error),
        )
    return CommandOutcome(
        returncode=completed.returncode,
        stdout=completed.stdout or "",
        stderr=completed.stderr or "",
    )


def selector_matches(list_output: str, selector: str) -> int:
    """Count exact Rust harness entries for ``selector``.

    ``cargo test --list`` emits entries such as ``name: test``.  Comparing the
    complete name before the suffix avoids accepting a prefix or a similarly
    named regression test.
    """

    suffix = ": test"
    matches = 0
    for raw_line in list_output.splitlines():
        line = raw_line.strip()
        if not line.endswith(suffix):
            continue
        name = line[: -len(suffix)].strip()
        if name == selector:
            matches += 1
    return matches


def _count_from_summary(line: str, label: str) -> Optional[int]:
    # Avoid a regex dependency for the surrounding line; cargo's summary is a
    # stable ``N label`` pair, and only decimal non-negative counts are valid.
    tokens = line.replace(";", " ").split()
    for index in range(len(tokens) - 1):
        if tokens[index + 1] == label:
            try:
                value = int(tokens[index], 10)
            except ValueError:
                return None
            return value if value >= 0 else None
    return None


def parse_test_summaries(output: str) -> List[Dict[str, int]]:
    """Parse every Rust ``test result`` summary in combined command output."""

    summaries: List[Dict[str, int]] = []
    for raw_line in output.splitlines():
        line = raw_line.strip()
        if not line.lower().startswith("test result:"):
            continue
        passed = _count_from_summary(line, "passed")
        failed = _count_from_summary(line, "failed")
        ignored = _count_from_summary(line, "ignored")
        measured = _count_from_summary(line, "measured")
        filtered_out = _count_from_summary(line, "filtered")
        # ``filtered out`` is two tokens; _count_from_summary finds the count
        # paired with ``filtered``.  A malformed result line is retained as a
        # sentinel so callers fail closed instead of selecting another line.
        if passed is None or failed is None or ignored is None:
            summaries.append({"_malformed": 1})
            continue
        summaries.append(
            {
                "passed": passed,
                "failed": failed,
                "ignored": ignored,
                "measured": measured if measured is not None else 0,
                "filteredOut": filtered_out if filtered_out is not None else 0,
            }
        )
    return summaries


def parse_test_result(output: str) -> Optional[Dict[str, int]]:
    """Return aggregate Rust test counts, or ``None`` for missing/malformed."""

    summaries = parse_test_summaries(output)
    if not summaries or any("_malformed" in item for item in summaries):
        return None
    result = {
        "passed": 0,
        "failed": 0,
        "ignored": 0,
        "measured": 0,
        "filteredOut": 0,
    }
    for summary in summaries:
        for key in result:
            result[key] += summary[key]
    return result


def _base_result(
    requested_platform: str,
    host_system: str,
    host_machine: str,
    host_platform: Optional[str],
    selector: Optional[str],
    list_command: Optional[Sequence[str]],
    run_command: Optional[Sequence[str]],
    started_at: str,
) -> Dict[str, object]:
    return {
        "schemaVersion": SCHEMA_VERSION,
        "kind": RESULT_KIND,
        "status": "failed",
        "requestedPlatform": requested_platform,
        "platform": host_platform,
        "selector": selector,
        "host": {
            "system": host_system,
            "machine": host_machine,
            "platform": host_platform,
        },
        "commands": {
            "list": {
                "argv": list(list_command) if list_command is not None else None,
                "display": _display_command(list_command) if list_command is not None else None,
            },
            "run": {
                "argv": list(run_command) if run_command is not None else None,
                "display": _display_command(run_command) if run_command is not None else None,
            },
        },
        "checks": {
            "hostPlatform": {
                "passed": False,
                "requested": requested_platform,
                "actual": host_platform,
            },
            "selectorListed": {"passed": False, "matches": 0},
            "testRun": {"passed": False, "exitCode": None},
            "testSummary": {"passed": False, "tests": None},
        },
        "list": {"exitCode": None, "selectorMatches": 0},
        "run": {"exitCode": None, "tests": None},
        "tests": None,
        "errors": [],
        "diagnostics": {},
        "startedAt": started_at,
        "endedAt": None,
        "elapsedSeconds": None,
    }


def _add_error(result: Dict[str, object], code: str, message: str) -> None:
    errors = result["errors"]
    assert isinstance(errors, list)
    errors.append({"code": code, "message": message})


def run_guard(
    repo: Path,
    requested_platform: str = "auto",
    *,
    cargo: str = "cargo",
    timeout_seconds: float = DEFAULT_TIMEOUT_SECONDS,
    host_system: Optional[str] = None,
    host_machine: Optional[str] = None,
    runner: Runner = run_subprocess,
    environment: Optional[Mapping[str, str]] = None,
) -> Dict[str, object]:
    """Run the Issue #5 selector guard and return a JSON-ready result."""

    started_clock = time.monotonic()
    started_at = _utc_now()
    system_name = host_system if host_system is not None else _platform.system()
    machine_name = host_machine if host_machine is not None else _platform.machine()
    actual_platform = detect_host_platform(system_name)
    selected_platform: Optional[str]
    if requested_platform == "auto":
        selected_platform = actual_platform
    else:
        selected_platform = requested_platform

    selector = EXPECTED_SELECTORS.get(selected_platform or "")
    repo_path = Path(repo).expanduser()
    try:
        repo_path = repo_path.resolve()
    except OSError:
        # Keep the original path in structured output; the repository check
        # below will provide the actionable fail-closed error.
        pass

    list_command = (
        build_list_command(repo_path, cargo) if selected_platform in EXPECTED_SELECTORS else None
    )
    run_command = (
        build_run_command(repo_path, selected_platform, cargo=cargo)
        if selected_platform in EXPECTED_SELECTORS
        else None
    )
    result = _base_result(
        requested_platform,
        system_name,
        machine_name,
        actual_platform,
        selector,
        list_command,
        run_command,
        started_at,
    )

    def finish() -> Dict[str, object]:
        result["endedAt"] = _utc_now()
        result["elapsedSeconds"] = round(time.monotonic() - started_clock, 3)
        return result

    if requested_platform != "auto" and requested_platform not in PLATFORMS:
        _add_error(result, "unknown_platform", "requested platform is not supported")
        return finish()
    if actual_platform is None:
        _add_error(result, "unsupported_host", "host OS is not Linux, Windows, or macOS")
        return finish()
    if selected_platform != actual_platform:
        _add_error(
            result,
            "host_platform_mismatch",
            "requested platform does not match the current host",
        )
        return finish()
    if timeout_seconds <= 0:
        _add_error(result, "invalid_timeout", "timeout must be greater than zero")
        return finish()
    if not repo_path.is_dir():
        _add_error(result, "repository_missing", "repository directory does not exist")
        return finish()
    if not (repo_path / "Cargo.toml").is_file():
        _add_error(result, "manifest_missing", "repository has no Cargo.toml")
        return finish()

    checks = result["checks"]
    assert isinstance(checks, dict)
    checks["hostPlatform"]["passed"] = True

    env = dict(os.environ if environment is None else environment)
    try:
        listed = runner(list_command, repo_path, env, timeout_seconds)  # type: ignore[arg-type]
    except Exception as error:  # pragma: no cover - defensive boundary
        listed = CommandOutcome(None, error="{}: {}".format(type(error).__name__, error))
    combined_list = listed.stdout + ("\n" + listed.stderr if listed.stderr else "")
    result["list"] = {
        "exitCode": listed.returncode,
        "selectorMatches": selector_matches(combined_list, selector),  # type: ignore[arg-type]
    }
    result["diagnostics"]["listStdout"] = _clip(listed.stdout)
    result["diagnostics"]["listStderr"] = _clip(listed.stderr)
    if listed.error:
        _add_error(result, "cargo_list_error", listed.error)
    if listed.returncode != 0:
        _add_error(result, "cargo_list_failed", "cargo test --list exited non-zero")
        return finish()

    matches = result["list"]["selectorMatches"]
    checks["selectorListed"] = {"passed": matches == 1, "matches": matches}
    if matches == 0:
        _add_error(result, "selector_not_found", "positive Issue #5 selector is absent")
        return finish()
    if matches != 1:
        _add_error(result, "selector_ambiguous", "positive Issue #5 selector appears more than once")
        return finish()

    try:
        executed = runner(run_command, repo_path, env, timeout_seconds)  # type: ignore[arg-type]
    except Exception as error:  # pragma: no cover - defensive boundary
        executed = CommandOutcome(None, error="{}: {}".format(type(error).__name__, error))
    combined_run = executed.stdout + ("\n" + executed.stderr if executed.stderr else "")
    tests = parse_test_result(combined_run)
    result["run"] = {"exitCode": executed.returncode, "tests": tests}
    result["tests"] = tests
    result["diagnostics"]["runStdout"] = _clip(executed.stdout)
    result["diagnostics"]["runStderr"] = _clip(executed.stderr)
    checks["testRun"] = {"passed": executed.returncode == 0, "exitCode": executed.returncode}
    checks["testSummary"] = {
        "passed": tests is not None and tests["passed"] > 0 and tests["failed"] == 0,
        "tests": tests,
    }
    if executed.error:
        _add_error(result, "cargo_run_error", executed.error)
    if executed.returncode != 0:
        _add_error(result, "cargo_run_failed", "exact selector command exited non-zero")
    if tests is None:
        _add_error(result, "test_summary_missing", "Rust test result summary is missing or malformed")
    else:
        if tests["passed"] <= 0:
            _add_error(result, "tests_passed_zero", "exact selector run reported zero passed tests")
        if tests["failed"] != 0:
            _add_error(result, "tests_failed_nonzero", "exact selector run reported failed tests")

    if executed.returncode == 0 and tests is not None and tests["passed"] > 0 and tests["failed"] == 0:
        result["status"] = "passed"
    return finish()


def _write_json_atomically(path: Path, payload: str) -> None:
    path = path.expanduser()
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(path.name + ".tmp-{}".format(os.getpid()))
    try:
        temporary.write_text(payload, encoding="utf-8", newline="\n")
        os.replace(str(temporary), str(path))
    finally:
        try:
            temporary.unlink()
        except FileNotFoundError:
            pass


def build_argument_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Fail-closed Issue #5 cargo selector/list/summary guard"
    )
    parser.add_argument("--repo", type=Path, default=Path.cwd(), help="ClusterYourCodex checkout")
    parser.add_argument(
        "--platform",
        choices=("auto",) + PLATFORMS,
        default="auto",
        help="expected host platform (default: auto-detect)",
    )
    parser.add_argument("--cargo", default="cargo", help="cargo executable or test wrapper")
    parser.add_argument(
        "--timeout-seconds",
        type=float,
        default=DEFAULT_TIMEOUT_SECONDS,
        help="per-command timeout (default: 1800)",
    )
    parser.add_argument("--output", type=Path, help="also write the JSON result atomically")
    return parser


def main(argv: Optional[Sequence[str]] = None) -> int:
    args = build_argument_parser().parse_args(argv)
    result = run_guard(
        args.repo,
        args.platform,
        cargo=args.cargo,
        timeout_seconds=args.timeout_seconds,
    )
    payload = json.dumps(result, ensure_ascii=False, indent=2, sort_keys=True) + "\n"
    try:
        if args.output is not None:
            _write_json_atomically(args.output, payload)
    except OSError as error:
        _add_error(result, "result_write_failed", "{}: {}".format(type(error).__name__, error))
        result["status"] = "failed"
        payload = json.dumps(result, ensure_ascii=False, indent=2, sort_keys=True) + "\n"
    sys.stdout.write(payload)
    return 0 if result["status"] == "passed" else 1


if __name__ == "__main__":
    raise SystemExit(main())
