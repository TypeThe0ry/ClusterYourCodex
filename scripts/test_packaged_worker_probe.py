"""Run the packaged worker on its native host; not a service lifecycle test."""

import argparse
import json
import platform
from pathlib import Path
import subprocess
import tempfile


def validate_report(report, manifest):
    for field, expected in (("agentVersion", manifest["version"]),
                            ("os", manifest["os"]),
                            ("arch", manifest["architecture"])):
        if report.get(field) != expected:
            raise ValueError(f"probe {field} does not match packaged manifest")
    resources = report.get("resources", {})
    for field in ("logicalCpuCores", "memoryMib", "diskMib"):
        value = resources.get(field)
        if type(value) is not int or value <= 0:
            raise ValueError(f"probe has invalid {field}")


def run(kit_root):
    kit = Path(kit_root).resolve(strict=True)
    manifest = json.loads((kit / "worker-kit.json").read_text(encoding="utf-8-sig"))
    host_os = {"Linux": "linux", "Darwin": "macos"}.get(platform.system())
    host_arch = {"x86_64": "x86_64", "amd64": "x86_64",
                 "arm64": "aarch64", "aarch64": "aarch64"}.get(platform.machine().lower())
    if host_os is None or (host_os, host_arch) != (manifest["os"], manifest["architecture"]):
        raise ValueError("packaged probe requires a matching native Linux/macOS host")
    worker = kit / "cyc-worker"
    # TemporaryDirectory owns this exact tree; no user workspace is removed.
    with tempfile.TemporaryDirectory(prefix="cyc-packaged-probe-") as temporary:
        workspace = Path(temporary) / "workspace with spaces 中文"
        workspace.mkdir(mode=0o700)
        completed = subprocess.run(
            [str(worker), "probe", "--workspace", str(workspace)],
            capture_output=True, text=True, encoding="utf-8", timeout=90, check=True,
        )
        validate_report(json.loads(completed.stdout), manifest)
    # Do not publish the inventory/hostname; retain only the acceptance result.
    print(json.dumps({"schemaVersion": "cyc.dev/packaged-worker-probe/v1",
                      "status": "pass", "os": host_os, "arch": host_arch,
                      "version": manifest["version"], "exitCode": completed.returncode,
                      "unicodeWorkspace": True, "serviceLifecycleTested": False}))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--kit-root", required=True)
    run(parser.parse_args().kit_root)
