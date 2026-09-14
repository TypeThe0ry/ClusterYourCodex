# Workspace UI copy

The workspace is an operational screen, not a landing page.

- Start with computers, task status, and available actions.
- Use short functional labels: Computers, Tasks, Add computer, Placement details.
- Do not add a promotional hero or a sentence explaining every page title.
- Show diagnostics and placement reasoning in expandable details.
- Preserve actionable errors, setup instructions, and security confirmations.
- Apply the same hierarchy in all supported languages.

The discarded Chinese hero and task descriptions are covered by
App.copy.test.tsx. The locale catalog test prevents discarded promotional keys
from being reintroduced. Removing this copy does not change task scheduling,
credentials, worker execution, or artifact verification.
