# Desktop content and information hierarchy

The desktop is an operational workspace, not a landing page.

- Do not restore the removed promotional home title or page subtitles in any locale.
- Keep navigation labels, table headings, actionable errors and empty states.
- Start Tasks with history and filters; do not add a paragraph explaining what tasks are.
- Show computer identity and status in the overview. Keep availability reasons,
  execution slots and telemetry generation/sequence inside a closed technical-details disclosure.
- Preserve diagnostic evidence; simplify its presentation rather than deleting it.
- Reuse translated controls across English, Chinese, Spanish and Japanese.

## Verification on 2026-09-08

Chrome at http://127.0.0.1:1420/ confirmed that the removed promotional title
and subtitle were absent. After hot reload, the computer row exposed a closed
technical-details control; telemetry and internal availability reasons were no
longer in the initial page content. This is a frontend check, not worker lifecycle acceptance.
