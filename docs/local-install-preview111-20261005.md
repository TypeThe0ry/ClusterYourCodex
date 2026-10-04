# Local Windows install and cross-platform execution — 2026-10-05

This record captures the current Windows controller after a real installation
of the public `v0.1.0-preview.111` Setup payload. It is supplemental to the
LAN deployment record and does not contain passwords, tokens, private keys, or
worker enrollment material.

## Installation result

The downloaded Setup executable was staged outside the checkout under
`D:\ClusterYourCodex-validation\preview111-local-upgrade-20261004` and its
detached SHA-256 sidecar matched the executable:

```text
80A0911333FB90D0C7E38E342AE5C574076668A7F8C0AFF318486B4B044368C0
```

The first upgrade attempt failed closed because the previous install manifest
recorded a managed global `AGENTS.md` block that was no longer present in the
user file. The user file was backed up byte-for-byte; no Codex content was
deleted. The stale manifest was quarantined, the old controller was stopped by
its scheduled-task boundary, and the same verified Setup payload was retried.
The retry exited `0` and committed a fresh install manifest.

The resulting local state is:

| Check | Result |
| --- | --- |
| install manifest `productVersion` | `0.1.0-preview.111` |
| core commit state | `committed` |
| native Codex plugin version | `0.1.0-preview.111` |
| native plugin activation | `succeeded=true`, installed and enabled |
| global `AGENTS.md` | original content plus exactly one managed block; no content outside the block was replaced |
| controller health | `status=ok`, `database=ok`, API `cyc.dev/v1` |
| controller scheduled task | `Running` |
| native plugin contract | pass |
| native plugin integrity/MCP probe | pass; six required files and bundled runtime present |

The active plugin source is the installer-managed local marketplace, and the
Codex CLI reports the same preview version and source path. The stable
`v0.0.1` tag was not changed.

## Live worker verification after the install

The controller's post-install fleet reported both remote workers online with
`0.1.0-preview.111`. Two fresh jobs used the merged `origin/main` revision
`1ec6e75c783b31ce35ba76e1bff23d63d9260527` as their Git source:

| Target | Job | Run | Result | Artifact proof |
| --- | --- | --- | --- | --- |
| Windows worker (Helio) | `9a76645b-9b60-44e9-86f1-92215c793b98` | `21cfcb25-a958-4734-8610-2ab1625a2e18` | `succeeded`, exit `0` | `CYC_PREVIEW111_WINDOWS_OK`, artifact `7177428d-fcac-4d90-b1c3-f1b67525bd30`, SHA-256 `69835C623EB1C6B4F2FB29BBB612FE2803E178E25343185008F7DA06C6D82317` |
| Linux worker (NUC) | `43cfb6c1-c5d9-4018-8226-a243917ab232` | `28299a92-d991-40d6-9c58-d2e841840daa` | `succeeded`, exit `0` | `CYC_PREVIEW111_LINUX_OK`, artifact `8df779a6-1a55-4757-a965-2e5328d239c0`, SHA-256 `D22D7C949CEB1A927D9F1850FF4655C7B61F1D9D4B0FFE80E46D56FBF094EE8F` |

The planner rejected the Linux worker for the Windows requirement and selected
the Windows worker; for the Linux requirement it rejected the Windows worker
and selected the Linux worker. This is live placement evidence, not a cached
fixture result.

## Release boundary

The installation and Windows↔Windows/Windows↔Linux execution paths are usable
in the preview. macOS native LaunchAgent/live-round-trip validation remains
deferred by request. The clean-guest full lifecycle matrix and production
signing gates tracked by Issues #2 and #3 therefore remain open, and
`v0.1.0-preview.111` remains a prerelease.
