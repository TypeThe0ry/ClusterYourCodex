# Windows CI live round trip: run 34224323417

Verified on 2026-09-08 from the downloaded GitHub Actions artifact, not from
workflow configuration alone.

- Workflow: https://github.com/TypeThe0ry/ClusterYourCodex/actions/runs/34224323417
- Conclusion: success.
- PR head: `51a1c519a2d474071cfcaaa32c9e2965d4f91a50`.
- Executed merge commit in result.json: `926bd6a0ca364663236c3876940a342f3d4a934c`.
- GitHub commit API confirms that PR head is the merge commit's second parent.
- Artifact ID: `10056719760`, name `ClusterYourCodex-windows-controller-worker-roundtrip`.
- Artifact archive size reported by GitHub: 93018 bytes.
- Downloaded result.json SHA-256: `dc09f23658322193333f084f07f9c1ae5f4f549ded5519d6cd42918b46c57538`.
- Result: passed; failure null; all 14 check flags true.
- Job: `c1af7921-22a4-4834-be79-dd84ccdc5e2a`.
- Run: `f6e762c9-97c7-41a6-aff0-da730ff8242e`.
- Observed states: queued, running, succeeded; reported run duration 37 seconds.
- Cleanup receipt: removed, jobRootDeleted true, terminal acknowledgment succeeded,
  reservation released with reason removed_receipt.

The script runs real controller and worker processes in a same-host Windows
fixture. It checks pairing, heartbeat, task completion, downloaded logs and
artifact bytes, route traces, owned-process cleanup and secret scanning.
The downloaded report records these assertions; it is not independent proof
of a different machine or a newer commit.

This does **not** prove GUI SSH credential storage, remote SSH installation,
persistent Scheduled Task lifecycle, cross-machine execution, clean-VM
deployment, production signing, or the current PR head's acceptance. Those
remain separate gates. No stable release is justified by this result alone.
