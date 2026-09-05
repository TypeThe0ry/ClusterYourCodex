# Contributing to ClusterYourCodex

ClusterYourCodex is in early development. Changes should preserve the product
contract in `AGENTS.md` and the versioned protocol in `schemas/`.

## Development flow

1. Create a focused branch.
2. Keep platform-specific behavior behind an adapter or probe boundary.
3. Add or update tests.
4. Run Rust formatting, linting, and tests.
5. Run the pnpm workspace checks.
6. Include observable verification in the pull request.

Never commit credentials, worker addresses, private source snapshots, or copied
diagnostic bundles. Use synthetic fixtures in tests.

## Pull requests and merge automation

All implementation, UI, documentation, CI, packaging, and release-record
changes land through a pull request; do not push directly to `main`. A change
must include the relevant `docs/project-status.md` and `CHANGELOG.md` evidence,
plus links to any affected GitHub issues.

After the local checks pass, request GitHub's protected auto-merge so the PR is
merged only when the repository's required CI, CodeQL, dependency, packaging,
and platform checks are green:

```powershell
gh pr merge <number> --auto --squash
```

Auto-merge is an execution convenience, not a check bypass. If a required check
fails, fix the branch and update the same PR; never force-merge or rewrite the
durable evidence to make a release appear green.
