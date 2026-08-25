# Troubleshooting

## Collect evidence without secrets

Record:

- ClusterYourCodex product version and release asset SHA-256;
- source commit/tag from `release-manifest.json`;
- Windows/Linux/macOS version and architecture;
- operation/job ID, selected node and placement reason;
- native exit code, elapsed time, retry count;
- redacted error code and stage;
- stdout/stderr/artifact hashes and expected output names.

Do not attach SSH passwords, private keys, controller/enrollment tokens,
credential-vault exports, unredacted worker configuration, or private host
inventory.

## GUI will not open

```powershell
& "$env:LOCALAPPDATA\Programs\ClusterYourCodex\ClusterYourCodex.exe"
$LASTEXITCODE
```

Exit `1` with `desktop_host_unavailable` means the native host itself could not
run. If the window opens but one subsystem is unavailable, use its stable error
code: `controller_auth_unavailable`, `integration_data_unavailable`,
`full_run_check_unavailable`, `provisioning_store_unavailable`, or a more
specific worker-kit/vault error. Rerun Setup Repair before deleting state.

## Controller unavailable

- Confirm the per-user **ClusterYourCodex Controller** Scheduled Task exists and
  is running under the initiating user.
- Confirm no unrelated process occupies the configured controller port.
- Use the GUI repair path; do not paste the controller token into a command.

## Add Computer stops at host key

Compare the displayed fingerprint with the worker's trusted fingerprint. A new
or changed key is a hard failure until independently explained. Do not delete
`known_hosts` or disable strict checking to make the operation continue.

## Authentication fails

Verify the account, SSH server policy, and selected GUI authentication method.
For password auth, re-enter the corrected password. For agent auth, confirm the
controller process can reach a running native agent with an accepted identity.
For private-key auth, select an absolute regular-file path owned by the current
controller user; links/reparse points and path aliases are rejected. Re-enter an
encrypted key's passphrase after restart because passphrases are deliberately
session-only. Never embed private-key material in a password field or JobSpec.

## Worker is connected but Full Run fails

Read the first failed layer:

1. plugin check;
2. fresh heartbeat;
3. source snapshot;
4. worker selection;
5. remote execution;
6. log verification;
7. artifact verification;
8. cleanup.

A submitted/started job is not success. Preserve terminal native exit code and
cleanup evidence. Deterministic build failures should be fixed and resubmitted;
authentication, host-key, permission, disk, and deterministic failures should
not be retried blindly.

## Setup fails

Keep the Setup exit code and lifecycle diagnostic JSON. Rerun the same Setup to
resume a recognized transaction. Do not move the package with `/D=`, delete
the data root, remove firewall/task state manually, or edit the install
manifest before recovery has been attempted.
