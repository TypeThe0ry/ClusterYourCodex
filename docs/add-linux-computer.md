# Add a Linux computer

> **Acceptance status:** This is the implemented and CI-tested preview flow.
> Password, native-agent, private-key, systemd, and full Windows-to-Linux live
> acceptance evidence is still pending. The internal Linux dedicated-identity
> and cgroup-v2 mechanism passed one native P1 test, but the production hostile
> tier remains deliberately unavailable while issue #5's escape, identity,
> resource, and reconciliation proofs are completed.

## Worker prerequisites

- x86_64 or aarch64 Linux with Bash and OpenSSH server.
- A login account with a writable home directory and permission for the chosen
  Worker Kit scope.
- `systemd --user` for user scope, or root/systemd for explicit system scope.
- Network reachability to the Windows controller's managed TLS listener.

## GUI flow

1. Open **Add Computer** on the Windows controller.
2. Enter the Linux host, SSH port, and account. Choose an implemented preview
   path: password, identities exposed by the controller's native SSH agent, or
   an absolute local private-key path with an optional passphrase.
3. Verify the SSH host-key fingerprint out-of-band and approve the exact value.
4. Select Linux and the detected architecture. Keep the detected workspace
   unless there is a concrete storage requirement.
5. Continue through the expected acceptance stages: kit upload, signature
   verification, install/pair, systemd activation, heartbeat, and managed
   smoke. A skipped/unverified stage is a failed acceptance.
6. Run **Full Run Check** and, for that exact environment, confirm source digest,
   selected node/reason,
   stdout/stderr hashes, native exit code, artifact SHA-256, descendant cleanup,
   and lease release.

The lifecycle uses a user systemd service for non-root `auto` scope and may use
a system service only when system scope is explicitly selected with sufficient
privilege. It does not rely on `nohup`, `screen`, or an SSH foreground process
as the sole persistence mechanism.

## Manual diagnostic fallback

The signed Worker Kit includes `install-worker.sh`. Its exact CLI is printed by:

```bash
bash ./install-worker.sh --help
```

Use the GUI for normal onboarding so operation IDs, recovery checkpoints, host
identity, secrets, and controller pairing remain consistent. Do not paste an
enrollment secret into shell history when collecting diagnostics.
