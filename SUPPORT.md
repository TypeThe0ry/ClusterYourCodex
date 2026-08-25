# Support policy

## Prerelease support

ClusterYourCodex is currently prerelease software. The newest published
prerelease is the supported test target; older preview builds may be required
only as the `N-1` input to an upgrade test. Breaking changes and migrations are
listed in `CHANGELOG.md`.

Before opening a bug:

1. verify the downloaded artifact and sidecar hash;
2. reproduce on the newest prerelease;
3. run the GUI health check and Full Run Check;
4. collect redacted diagnostics, exact product version, OS/build, architecture,
   source SHA, operation ID, native exit code, and artifact hashes;
5. remove passwords, tokens, private keys, enrollment bundles, controller
   credentials, and private host addresses unless they are essential and safe
   to disclose.

Use [GitHub Issues](https://github.com/TypeThe0ry/ClusterYourCodex/issues) for
ordinary bugs and feature requests. Use GitHub private vulnerability reporting
for suspected security vulnerabilities; see `SECURITY.md`.

## Supported preview boundary

- Controller/Desktop: Windows x64 prerelease, with local packaging/lifecycle
  validation; the complete clean-profile and live-fleet matrix remains pending.
- Workers: Windows x64 and Linux x64/aarch64 implementations for trusted
  single-user workloads. CI and packaging validation exist, but live
  two-machine authentication/execution acceptance has not yet been completed.
- macOS: native controller/CLI/worker binaries and signed exact-five-file Worker
  Kits are packaged for x64 and arm64. Managed execution remains
  `runtimeGated=true`, `containmentReady=false`, and `liveReady=false`.
- Network: user-controlled LAN or another explicitly trusted network path.
- Authentication: password, native SSH agent, and validated local-private-key
  paths are implemented and fixture/CI tested through the native boundary.
  Live server acceptance for all three modes remains pending. Remembered
  passwords use Windows Credential Manager; private-key passphrases are
  session-only.

“Supported preview boundary” means that bugs in this declared scope are valid
preview reports. It is not a claim of completed hardware certification, hostile
workload isolation, or stable-release support.

No response-time SLA is promised during preview. Stable support windows and
minimum compatible versions will be declared before `v1.0.0`.
