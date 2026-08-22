# ClusterYourCodex repository instructions

## Product contract

ClusterYourCodex is Codex-first software that lets Codex distribute executable
work across computers owned by the user. Keep the user-facing product focused
on Codex. Internal protocols may be versioned and decoupled to tolerate Codex
updates, but do not reposition the product as a generic AI orchestration suite.

## Engineering constraints

- Windows is the first shipping controller platform.
- Keep controller, protocol, scheduler, transport, and UI boundaries portable
  to Linux and macOS.
- Never hard-code machine names, IPs, usernames, workspace paths, or the current
  Helio/P1/NUC topology.
- Keep secrets behind references. Never put passwords, private keys, tokens, or
  raw credential configuration in `JobSpec`, MCP payloads, logs, tests, docs, or
  command-line arguments.
- Prefer native script files and structured arguments over nested shell strings.
- Any cleanup must prove that its target is job-owned.
- Preserve unrelated user changes. Do not rewrite an existing `AGENTS.md`; use
  a marked additive section and a reversible installer.
- Add tests for protocol compatibility, scheduler decisions, state transitions,
  redaction, and job isolation.

## Verification

Run the narrowest relevant checks first, then the full workspace checks:

```text
cargo fmt --all -- --check
cargo clippy --workspace --all-targets -- -D warnings
cargo test --workspace
pnpm -r lint
pnpm -r test
pnpm -r build
```

Do not report a remote command as successful until its native exit code and
expected artifacts have been verified.

