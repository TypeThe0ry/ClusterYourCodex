#!/usr/bin/env python3
"""Strict npm advisory fallback for transient registry audit outages.

The normal dependency gate remains ``pnpm audit``.  This helper is only used
when that command reports a transport/registry timeout.  It inventories the
already-installed, lockfile-derived graph with ``pnpm list`` and queries the
OSV API.  An unavailable OSV response, an unrecognised severity, or a
moderate-or-higher advisory fails closed; a transport fallback can never turn
an unknown result into a pass.
"""

from __future__ import annotations

import argparse
import concurrent.futures
import json
import re
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any, Iterable


OSV_QUERYBATCH_URL = "https://api.osv.dev/v1/querybatch"
OSV_VULN_URL = "https://api.osv.dev/v1/vulns/{vuln_id}"
MAX_QUERY_BATCH = 1000
MAX_RETRIES = 3
RETRY_DELAYS_SECONDS = (1.0, 3.0, 7.0)
VERSION_RE = re.compile(r"^(?P<version>\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?)")
SEVERITY_LOW = {"NONE", "LOW"}


class OsvUnavailable(RuntimeError):
    """The fallback could not obtain authoritative advisory data."""


def _request_json(url: str, payload: Any | None = None) -> Any:
    data = None if payload is None else json.dumps(payload, separators=(",", ":")).encode("utf-8")
    method = "GET" if data is None else "POST"
    request = urllib.request.Request(
        url,
        data=data,
        method=method,
        headers={
            "Accept": "application/json",
            "Content-Type": "application/json",
            "User-Agent": "ClusterYourCodex-dependency-audit/1",
        },
    )
    last_error: Exception | None = None
    for attempt in range(MAX_RETRIES):
        try:
            with urllib.request.urlopen(request, timeout=30) as response:
                return json.load(response)
        except (OSError, urllib.error.URLError, TimeoutError, json.JSONDecodeError) as error:
            last_error = error
            if attempt + 1 < MAX_RETRIES:
                time.sleep(RETRY_DELAYS_SECONDS[attempt])
    raise OsvUnavailable(f"OSV request failed after {MAX_RETRIES} attempts: {url}: {last_error}")


def _normalise_version(value: Any) -> str | None:
    if not isinstance(value, str):
        return None
    match = VERSION_RE.match(value.strip())
    return match.group("version") if match else None


def _walk_dependency_sections(node: Any) -> Iterable[tuple[str, str]]:
    if isinstance(node, list):
        for item in node:
            yield from _walk_dependency_sections(item)
        return
    if not isinstance(node, dict):
        return

    for section_name in ("dependencies", "devDependencies", "optionalDependencies", "peerDependencies"):
        section = node.get(section_name)
        if not isinstance(section, dict):
            continue
        for package_name, metadata in section.items():
            if not isinstance(package_name, str) or not isinstance(metadata, dict):
                continue
            version = _normalise_version(metadata.get("version"))
            resolved = metadata.get("resolved")
            if version and isinstance(resolved, str) and resolved.startswith("https://"):
                yield package_name, version
            yield from _walk_dependency_sections(metadata)


def collect_packages(inventory: Any) -> list[tuple[str, str]]:
    """Return a deterministic, deduplicated npm package/version list."""

    packages = sorted(set(_walk_dependency_sections(inventory)))
    if not packages:
        raise ValueError("pnpm list inventory contained no resolved npm packages")
    return packages


def _query_packages(packages: list[tuple[str, str]]) -> list[tuple[str, str, str]]:
    vulnerable: list[tuple[str, str, str]] = []
    for offset in range(0, len(packages), MAX_QUERY_BATCH):
        chunk = packages[offset : offset + MAX_QUERY_BATCH]
        response = _request_json(
            OSV_QUERYBATCH_URL,
            {
                "queries": [
                    {"package": {"name": name, "ecosystem": "npm"}, "version": version}
                    for name, version in chunk
                ]
            },
        )
        if not isinstance(response, dict) or not isinstance(response.get("results"), list):
            raise OsvUnavailable("OSV querybatch returned an invalid response shape")
        results = response["results"]
        if len(results) != len(chunk):
            raise OsvUnavailable("OSV querybatch result count did not match request count")
        for (name, version), result in zip(chunk, results):
            if not isinstance(result, dict) or not isinstance(result.get("vulns", []), list):
                raise OsvUnavailable("OSV querybatch returned an invalid vulnerability list")
            for vuln in result.get("vulns", []):
                if isinstance(vuln, dict) and isinstance(vuln.get("id"), str):
                    vulnerable.append((name, version, vuln["id"]))
                else:
                    raise OsvUnavailable("OSV querybatch returned a malformed vulnerability identifier")
    return vulnerable


def _relevant_severity(detail: Any) -> bool:
    """Return true for moderate-or-higher, conservatively failing unknowns."""

    if not isinstance(detail, dict):
        raise OsvUnavailable("OSV vulnerability detail was not an object")
    database_specific = detail.get("database_specific")
    if isinstance(database_specific, dict):
        severity = database_specific.get("severity")
        if isinstance(severity, str):
            normalised = severity.strip().upper()
            if normalised in SEVERITY_LOW:
                return False
            if normalised:
                return True
    # CVSS vectors and advisories without a normalised severity are treated as
    # relevant.  Failing closed avoids silently losing a moderate/high issue.
    return True


def _load_vulnerability(vuln_id: str) -> tuple[str, Any]:
    return vuln_id, _request_json(OSV_VULN_URL.format(vuln_id=vuln_id))


def evaluate(inventory: Any) -> dict[str, Any]:
    packages = collect_packages(inventory)
    package_vulns = _query_packages(packages)
    details: dict[str, Any] = {}
    unique_ids = sorted({vuln_id for _, _, vuln_id in package_vulns})
    with concurrent.futures.ThreadPoolExecutor(max_workers=min(8, max(1, len(unique_ids)))) as executor:
        futures = [executor.submit(_load_vulnerability, vuln_id) for vuln_id in unique_ids]
        for future in concurrent.futures.as_completed(futures):
            vuln_id, detail = future.result()
            details[vuln_id] = detail

    relevant = [
        {
            "package": name,
            "version": version,
            "vulnerability": vuln_id,
            "summary": details[vuln_id].get("summary") if isinstance(details[vuln_id], dict) else None,
        }
        for name, version, vuln_id in package_vulns
        if _relevant_severity(details[vuln_id])
    ]
    return {
        "schemaVersion": 1,
        "source": "OSV",
        "packageCount": len(packages),
        "vulnerabilityCount": len(package_vulns),
        "relevantAdvisoryCount": len(relevant),
        "relevantAdvisories": relevant,
        "status": "failed" if relevant else "passed",
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--inventory", required=True, type=Path)
    args = parser.parse_args()
    try:
        with args.inventory.open("r", encoding="utf-8-sig") as handle:
            inventory = json.load(handle)
        result = evaluate(inventory)
    except (OSError, json.JSONDecodeError, ValueError, OsvUnavailable) as error:
        print(
            json.dumps(
                {"schemaVersion": 1, "source": "OSV", "status": "unavailable", "error": str(error)},
                sort_keys=True,
            )
        )
        return 2
    print(json.dumps(result, sort_keys=True))
    return 0 if result["status"] == "passed" else 1


if __name__ == "__main__":
    sys.exit(main())
