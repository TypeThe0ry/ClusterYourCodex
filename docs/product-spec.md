# ClusterYourCodex product specification

## Promise

ClusterYourCodex gives Codex additional computers. A user keeps working in
Codex while the product selects compatible capacity, executes the work, and
returns verified outputs.

The distributed unit is executable work such as builds, tests, linting,
containers, GPU compute, rendering, and batch transforms. OpenAI-hosted model
inference is outside the product boundary.

## Users

### Quick setup

A Codex user with one to eight personal computers installs the controller on
the Codex execution host and pairs workers with a short-lived code. The product
uses plain language such as Computers, Tasks, Rules, and Output Files.

### Advanced setup

An experienced user imports existing SSH hosts, chooses password, key, or SSH
agent authentication, assigns labels and workspaces, and can inspect native
commands and placement scores.

### Team setup

A future team controller shares node pools with policy, quotas, roles, and
audit. The personal product must not depend on a cloud account.

## Primary journey

1. Detect an installed Codex Desktop or CLI environment.
2. Install the local controller and Codex integration.
3. Add computers through managed pairing or existing SSH.
4. Probe operating system, architecture, CPU, memory, storage, GPU, and common
   toolchains.
5. Choose Balanced, Performance, or Manual placement.
6. Run a real Codex smoke job.
7. Show synchronization, placement, execution, verification, and artifact
   collection in both Codex and the desktop application.

## Public MVP

- Windows-first controller and desktop application.
- Windows and Linux execution targets; macOS-compatible domain contracts.
- Codex Plugin, Skill, and MCP health check.
- Persistent jobs and explicit state transitions.
- Capability-first node inventory.
- Explainable scheduling.
- Local and SSH execution foundations.
- Git revision and filtered snapshot source identities.
- Logs, native exit codes, verification results, artifacts, and SHA-256.
- Additive installation and complete rollback.

## Default behavior

- Small tasks remain local when transfer and preparation would cost more.
- Meaningful builds, tests, GPU jobs, containers, and batch work may be placed
  automatically.
- Compatibility is a hard constraint; user weight is only a preference.
- One heavy job per computer until capacity has been measured.
- A GPU is exclusive by default.
- Offline computers are skipped.
- Authentication, host identity, deterministic build failures, and stateful
  deployment failures are never retried blindly.

## Non-goals for the first release

- Distributing Codex model inference.
- Remote desktop control.
- Kubernetes replacement.
- WAN relay or NAT traversal.
- Multi-tenant billing, SSO, or enterprise policy.
- Arbitrary third-party code loaded into the controller process.

