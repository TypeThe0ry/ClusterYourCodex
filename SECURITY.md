# Security policy

ClusterYourCodex executes user-approved commands on user-owned computers. This
makes credential isolation, source provenance, and cleanup ownership core
security properties rather than optional hardening.

## Reporting

Until a dedicated security contact is published, report vulnerabilities through
GitHub private vulnerability reporting for this repository. Do not open a public
issue containing credentials, private topology, or an unpatched exploit.

## Required invariants

- Codex and MCP payloads never contain raw worker credentials.
- Host or worker identity changes fail closed until the user confirms them.
- Every remote operation runs in a job-owned workspace.
- Logs and diagnostic bundles are redacted before export.
- Source snapshots exclude common secret and environment files by default.
- Retries are limited to classified transient failures.

