# Knot brand compatibility

Knot replaces the public DeskBridge name in 0.2.0-preview.14. The rebrand changes displayed names, the app mark, public repository links and distribution filenames. It does not reset or copy a user's pairing identities. No live settings, keys, service logs or existing user files are read by the rebrand/build process.

## Stable technical identifiers

| Surface | Retained identity | Reason |
| --- | --- | --- |
| macOS app | `org.deskbridge.app` and internal executable `DeskBridge` | Keep bundle identity stable; visible app is `Knot.app` |
| macOS saved trust/settings | Existing DeskBridge Application Support paths and preferences suites | Reuse the existing certificate/settings namespace without copying keys |
| Connection QR/link | `deskbridge://connect`, existing v1/v2 fields and validation | Existing exported invitations remain compatible |
| Windows screen client | `%LOCALAPPDATA%\DeskBridge-Reverse-v1`, owner marker and private profiles | Preserve per-address engine pairing |
| Windows file setup | `deskbridge-transfer`, `C:\DeskBridgeShare`, ProgramData directories, firewall name and managed config marker | Continue strict ownership checks and managed revocation |
| Windows installer | Existing AppId GUID, install directory and installed `DeskBridge-Windows.exe` filename | Upgrade the same deployment and replace the original broker in place; public download is `Knot-…exe` |
| Linux package | `deskbridge-linux-host`, desktop-file/icon ID and `deskbridge-linux` command | dpkg treats the new preview as an upgrade of the same package |
| Linux private store | `~/.local/share/deskbridge-linux-v1` and its owner marker | Preserve existing host credentials/certificates |
| Source/build internals | DeskBridge Swift modules, managed namespaces/resources, script filenames and original notices | Avoid unrelated code/interface changes and retain attribution |

The names above may appear in advanced setup and recovery instructions because they describe the actual compatible resources. The GUI, package display names and downloadable artifact names use Knot.

## Update and verification

Quit the existing application before replacing it with Knot. On Mac, replace/remove the old DeskBridge.app application bundle when installing Knot.app; keeping two copies with the same bundle ID can make URL opening ambiguous. Do not delete Application Support or reset certificates as part of the name change. Ad-hoc signing does not guarantee macOS permission retention, so any permission request must still be handled by the user.

The Windows installer keeps its AppId and broker destination. Linux retains its Debian package identifier. Source and synthetic checks verify these contracts; actual Windows installer upgrades, macOS permission attribution, Linux desktop capture and cross-device sessions remain device acceptance checks.

The GitHub repository is `ictechgy/Knot`; GitHub redirects the old `ictechgy/DeskBridge` repository URL. Old locally saved export filenames remain valid—their payload schemas and validation are unchanged.
