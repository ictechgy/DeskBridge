# Quiet Sidebar native UI validation

Concept A (Quiet Sidebar) was explicitly selected on 2026-10-19. The implementation uses native SwiftUI/AppKit controls and semantic appearance rather than embedding the HTML prototype.

## Reproduce with fresh synthetic data

```sh
python3 scripts/build.py --configuration release
python3 scripts/render_visual_fixture.py --output evidence/quiet-sidebar/native
```

The second command requires working macOS Screen Recording access. It does not request OS permission, change privacy settings, inspect any existing application preferences or capture the full desktop. It compiles a separate executable without the production `DeskBridgeApp.swift` entrypoint, uses a new temporary SettingsStore plus a unique identity suite, and captures only the exact windows it creates. It never invokes connection, streaming, file-picker or credential actions.

Without screenshot access, run one fixture for manual inspection:

```sh
python3 scripts/render_visual_fixture.py --interactive desktop --output evidence/quiet-sidebar/manual
```

Other fixtures: `files`, `setup`, `first-run`, `certificate-error`, `compact`, `files-compact`, `dark`. Close the fixture application after inspection; the temporary build/settings directory is then removed. It is not a real remote session. No production settings are loaded, and every PC/file/identity value is synthetic.

## Current evidence boundary

The optimized native app and offline checks build successfully. Source architecture review found no blocking trust/target-binding regression. In this environment, native view-cache and PDF drawings omitted compositor materials, own-window `screencapture` failed, and CUA's native pipe could not start. These failures are recorded; their images are not approved screenshots. There is no final visual score of 90+ or accepted pixel diff. Automated source/build checks do not resolve this limitation.

## Manual acceptance still needed

- Compare native Desktop, Files and Setup to the approved A references at 1200px width. Check heading/titlebar spacing, sidebar selection and primary button contrast.
- Check 880x620 and dark appearance for readable controls and reachable scroll content.
- First-run address entry must keep focus while typing. Checking the PC precedes PIN pairing; a stored PC is not labeled ready before verification.
- An existing saved-certificate reset remains reachable after connection failure and requires explicit confirmation naming that PC. Busy/streaming reset is disabled.
- Files remain separately authenticated. Credentials lock during file activity; directory selection cannot enable download; import requires displayed SSH fingerprint comparison.
- Verify native keyboard navigation, VoiceOver labels, actual Windows connection, IME, Space switching, audio and file transfers on user hardware.

This is a development preview, not a signed/notarized public release or a new runtime-security certification.
