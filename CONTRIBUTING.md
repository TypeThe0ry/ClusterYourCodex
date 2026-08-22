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

