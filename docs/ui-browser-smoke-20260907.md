# Chrome UI smoke — 2026-09-07

This is a read-only browser smoke record for the local desktop renderer. It
records what was actually visible in Chrome; it does not claim a live worker
was provisioned.

## Environment

- Browser: Chrome extension surface
- Existing browser tab: `http://127.0.0.1:1420/`
- Current-checkout renderer smoke: `http://127.0.0.1:1421/`
- Page: `ClusterYourCodex`
- Route inspected: **Computers**
- Controller banner shown by the page: `Controller online`

The already-running local dev server on port 1420 reported
`v0.1.0-preview.95` in its status line. For a source-bound renderer check, a
second Vite instance was started from the current checkout on port 1421. Its
renderer loaded the same simplified flow and four catalogs, while the local
controller proxy still reported the old `.95` controller version. Therefore
this record is UI evidence for the current source, not a claim that a packaged
preview.97 controller was running. Restart the controller and dev server from
the tagged checkout before a version-specific packaged UI acceptance run.

## Observed flow

The page exposes the short first-run path:

1. **Add a computer** opens an SSH form.
2. The form presents host/IP, SSH user, authentication method, and password
   fields; authentication choices are password, native SSH agent, and private
   key.
3. **Advanced options** keeps routing and verification details out of the
   default path.
4. With required fields empty, **Continue** is disabled. This prevents a
   partially configured computer from entering the provisioning flow.
5. The page visibly reports that the secure desktop provisioning bridge is
   unavailable in this browser-only dev session. No provisioning was started.

The top navigation also exposes Home, Computers, Tasks, Routing rules, and
Codex integration. The page clearly reports that zero computers are currently
available and offers **Refresh controller status** and **Refresh** actions.

## Locale smoke

The language picker exposed and rendered all four supported locales:

- English
- Simplified Chinese
- Spanish
- Japanese

Switching through Simplified Chinese, Spanish, and Japanese changed the
navigation, form, empty-state, and bridge-status strings. The persisted-locale
and complete-catalog checks are covered by `apps/desktop/src/i18n.test.tsx`.

## Boundary

This is a renderer/UI smoke only. It proves that the simplified onboarding
surface and locale switch are present in the running browser process. It does
not prove SSH authentication, Windows Credential Manager writes, worker
installation, Codex plugin activation, or controller-to-worker execution.
Those require the packaged current-version acceptance path and retained
install/provision/round-trip evidence.
