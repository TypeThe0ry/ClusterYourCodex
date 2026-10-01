# VMware current-candidate install probe — 2026-10-01

This record captures the first current-source Setup payload produced by the
green Windows Setup acceptance run `36811133742`. The probe used the existing
D-drive Windows 11 guest and VMware `vmrun` only; no Computer Use or VMware GUI
automation was used. Guest credentials remain in the host-only private
validation directory and are not copied into Git.

## Install result

- The candidate was downloaded from the `windows-setup-candidate` artifact of
  CI run `36811133742` and copied into the guest through VMware Tools.
- Setup ran with `/S` and exited with code `0`.
- The guest lifecycle diagnostic reported `status=succeeded`,
  `requestedAction=Install`, `lastStage=complete`, `firewallVerified=true`,
  and `coreSucceeded=true`.
- The installed controller process was present at the expected per-user
  install root and used the guest's private address for its managed-worker
  listener. No credential value or token was recorded in this repository.
- The candidate's SHA-256 matched the sidecar downloaded from CI. The hash is
  retained in the host-only evidence directory rather than duplicated here.

## Discovery result

The installed `cyc.exe discover --timeout-ms 500 --pretty` command exited `0`
and returned the versioned discovery envelope:

```json
{
  "apiVersion": "cyc.dev/discovery/v1",
  "broadcast": true,
  "candidates": [],
  "credentialsTransmitted": false,
  "pairingRequired": true
}
```

The empty candidate list is expected for this isolated guest segment. The
important acceptance properties are that the scan path is runnable, discovery
is broadcast-based, no credentials are transmitted, and pairing remains an
explicit trust step. Positive Windows↔Windows, Windows↔Linux, and Linux↔Linux
discovery/runtime records remain in
[`cross-platform-validation-20260927.md`](cross-platform-validation-20260927.md).

## Repair boundary

A second same-version `/S` invocation was started through the non-interactive
VMware Tools channel. It opened the installer process in the services session
instead of producing a reliable interactive repair result, so it was stopped
as an inconclusive channel probe and is **not** counted as Repair success. The
previous successful Install diagnostic was left intact. This is a test-channel
limitation, not a reason to weaken the product's Interactive scheduled-task or
ACL checks.

The temporary autologon used to obtain the first interactive session was
removed with the guest cleanup script (`AutoAdminLogon=0`, no stored password),
and the VM was soft-powered off. The final host-side `vmrun list` was empty.

## Remaining gate

This probe strengthens the current-source Install and LAN-discovery evidence,
but it does not close Issue #2. A clean Windows 11 guest still needs a
repeatable current-source `Install → Repair → Upgrade → Rollback → Uninstall`
matrix and an installed-package worker job. The hosted Windows acceptance run
and the sanitized cross-platform records remain authoritative for the live
Windows↔Windows, Windows↔Linux, and Linux↔Linux paths.
