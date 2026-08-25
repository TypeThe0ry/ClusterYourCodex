# Add a Windows computer

> **Acceptance status:** This is the implemented and CI-tested preview flow.
> Password, native-agent, private-key, and full Windows-to-Windows live
> acceptance evidence is still pending. A successful run proves the exact
> machines and credentials tested; this page is not pre-existing live evidence.

## Worker prerequisites

- Windows x64 with OpenSSH Server installed and running.
- An SSH account that can create the selected worker workspace and register the
  per-user worker Scheduled Task.
- The worker can reach the controller's managed TLS listener.
- No preinstalled Codex is required on the worker.

## GUI flow

1. Open ClusterYourCodex and select **Add Computer**.
2. Enter a display name, host/IP, SSH port, and SSH user. Choose one implemented
   preview authentication method: password, identities exposed by the native
   SSH agent, or an absolute local private-key path with an optional passphrase.
3. Compare the shown SSH host-key fingerprint with the fingerprint obtained
   from the computer or its administrator. Approve only an exact match. A
   changed stored key is a hard stop; never disable host-key checking.
4. Select Windows/x64 and a workspace such as `C:\CodexWorker` when the GUI asks
   for an advanced override. The default is preferred for a new worker.
5. Continue through the expected acceptance stages: signed five-file Worker Kit
   staging, publisher/payload verification, install/pair, Scheduled Task
   registration, start, heartbeat, and managed smoke. Treat any skipped or
   unverified stage as a failed acceptance, not a successful button click.
6. Confirm the computer card reports fresh telemetry and the operation result
   contains a successful native exit code, cleanup evidence, and artifact hash.

The renderer clears password/passphrase form state immediately after the native
invocation and native responses contain no secret. A password is written to
Windows Credential Manager only after SSH accepts it and only when **Remember**
is selected. Private-key passphrases are session-only; the key path is stored as
a non-secret policy and the native host revalidates the regular file and rejects
links/reparse points before every authentication. No authentication secret is
inserted into a JobSpec, MCP tool call, process argument, environment variable,
log, or artifact.

## Repair or remove

- **Repair** revalidates the exact kit, configuration, task, heartbeat, and
  smoke path.
- **Forget password** appears for password-authenticated computers and deletes
  only the stored SSH credential reference.
- **Remove** stops and removes the product-owned worker lifecycle. Read the GUI
  confirmation carefully before selecting a data-purge option.

After repair/remove, refresh the computer list and verify the resulting task,
heartbeat, and product-owned workspace state rather than treating a button
click as success.

Windows managed execution is currently for trusted single-user jobs. Job Object
cleanup is implemented, but a hostile-workload external guard is not.
