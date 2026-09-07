# Goal: feedback-driven hardening after core usability

Status: queued until the core-usability acceptance signal is recorded.

## Objective

Give an operator a short, repeatable way to try a packaged ClusterYourCodex
preview and report a problem with enough source, platform, stage, and redacted
diagnostic context to reproduce it. This goal starts after the Add Computer →
credential vault → worker pairing → job/result loop is usable on one supported
controller/worker pair.

## Feedback loop

1. Install one public prerelease and record the exact tag and installer hash.
2. Exercise the three visible actions: Add Computer, Connect Codex, and Run
   the check. If a worker is available, submit one small build or test job.
3. When something fails, record the stage shown in the UI, the exact version,
   platform pair, reproduction steps, and the redacted error code or receipt.
4. File the report with the repository's preview-feedback template. Reports
   that block connection, pairing, execution, result transfer, or cleanup are
   promoted ahead of cosmetic and wording issues.
5. Retest a fix on the same platform pair, then add the retained evidence to
   the repository status record before the next public prerelease.

## Done criteria

- A user can find the feedback template directly from GitHub Issues.
- Every accepted report names the preview tag, source/installer identity,
  controller OS, worker OS/architecture, failing stage, and a reproduction or
  explicit “not reproducible” result.
- Diagnostic attachments are redacted: no SSH password, private key,
  passphrase, access token, or raw secret is stored in the issue or repository.
- Fixes that improve the usable path are included in the next public
  prerelease; intermediate public builds remain `isPrerelease=true` and
  `isDraft=false`.
- This feedback goal never waives the independent Windows, Linux, macOS,
  signing, or hostile-workload gates required for a stable Release.

## Out of scope for this stage

Full visual polish, broad wording review, and non-blocking edge cases stay in
the feedback backlog until a report demonstrates that they prevent a normal
operator from completing the core loop.
