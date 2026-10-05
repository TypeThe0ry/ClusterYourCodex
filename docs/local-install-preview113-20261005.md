# Local Windows install — preview.113

This record captures the final local installation performed from the public
`v0.1.0-preview.113` Setup asset. It contains no credentials or bearer tokens.

## Source and package

- Release: [`v0.1.0-preview.113`](https://github.com/TypeThe0ry/ClusterYourCodex/releases/tag/v0.1.0-preview.113)
- Source commit: `11ca9d82c2782a93ec25a40958c480e818be3a51`
- Setup asset: `ClusterYourCodex-Setup.exe`
- The downloaded Setup SHA-256 matched its adjacent `.sha256` sidecar before execution.

## Installation result

- Install mode: silent `/S`
- Install root: `%LOCALAPPDATA%\Programs\ClusterYourCodex`
- Data root: `%LOCALAPPDATA%\ClusterYourCodex`
- Installer transaction: committed
- Installed product version: `0.1.0-preview.113`
- Scheduled task: `ClusterYourCodex Controller`, running

The transaction first staged the payload and then committed the install
manifest. The existing `preview.112` binaries were not reported as upgraded
until the committed manifest and executable versions agreed.

## Runtime probes

Installed binaries all reported `0.1.0-preview.113`:

```text
cyc 0.1.0-preview.113
cyc-controller 0.1.0-preview.113
cyc-worker 0.1.0-preview.113
```

The authenticated CLI health probe returned:

```json
{"apiVersion":"cyc.dev/v1","controllerVersion":"0.1.0-preview.113","database":"ok","status":"ok"}
```

This proves the local Windows Controller and database are running after the
public Setup install. It does not relabel the retained NUC Linux proof as a
preview.113 cross-node run; that evidence remains linked from the current
audit with its original build label.
