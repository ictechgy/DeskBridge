# Windows without a physical monitor

This optional Windows 11 x64 host feature, including Home edition, is intended to create one persistent virtual screen for Sunshine to capture. Mac/Linux virtual-display creation, login/unlock, waking and per-session display creation are outside its scope.

**Automatic driver installation is currently unavailable.** The installer, recovery path and status UI are implemented, but the pinned third-party driver's control interface still needs an acceptable security review. The packaged policy blocks installation in both the UI and elevated backend. A valid signature and matching hash alone do not establish driver safety. Do not change the policy flag to bypass that review.

For now, an attached monitor or an HDMI/DisplayPort dummy plug can provide a display for the existing Sunshine connection, subject to the target GPU's behavior. First-time setup needs a display or another working remote-access method; Knot cannot bootstrap an inaccessible computer.

## Setup after the driver gate is cleared

1. Complete normal Sunshine setup and require encryption for both LAN and WAN. Keep another way to access the PC until the first headless stream works.
2. In the packaged Knot Windows EXE, choose **이 Windows 공유 → 모니터 없이 사용**. Installation requires an explicit action, official download and administrator approval. Source/developer folders only offer status and instructions.
3. Check status after any requested restart. An installed device, an active display and a successful stream are separate facts. If needed, use Windows Display settings to extend the desktop onto the virtual display. Knot does not change physical-screen topology.
4. In Sunshine's **Troubleshooting** page, find its display enumeration. Match the virtual screen's `friendly_name` and `display_name` against Knot's status. Copy that entry's **`device_id`** into **Configuration → Audio/Video → Display Device ID** (`output_name`). This is a text field, not a monitor dropdown. Do not paste a Windows `DISPLAY` number. Use the installed Sunshine version's own enumeration.
5. Choose **Ensure active** (`dd_configuration_option=ensure_active`), save and restart Sunshine if requested. Avoid **Ensure only display**, which can disable physical screens. Start at 1920×1080, 60 Hz, SDR. The fixed template also advertises QHD and 4K at 60 Hz; mode switching and GPU encoding still need real-device validation.
6. Connect to Sunshine's Desktop through the existing Knot/Moonlight client. Verify video, pointer coordinates, keyboard and reconnection with the physical monitor disconnected. Installation status alone does not prove these work.

Knot does not read Sunshine credentials, logs or configuration, or call its administration API. Manual output selection avoids coupling to the installed Sunshine version's identifier implementation.

## Removal and recovery

First clear Sunshine's Display Device ID or choose another screen, and arrange another way to access the PC. Then use **Knot 가상 화면 제거**. Removal can end the stream and move windows.

An administrator-owned journal records the exact planned random device instance before creation. Knot removes only that matching device and unchanged owned files/registry state. Foreign present/phantom displays, altered settings, unknown files and ambiguous ownership cause refusal with data preserved. A pending restart retains recovery data; restart and run removal again. Do not manually delete the journal to bypass refusal.

Uninstalling Knot intentionally leaves the virtual display and recovery data. Remove the display first if no longer needed. Windows driver-store cached packages are retained; Knot never force-deletes a shared OEM driver package.

## Package and validation boundary

The candidate is [Virtual Display Driver 25.7.23](https://github.com/VirtualDrivers/Virtual-Display-Driver/releases/tag/25.7.23), MIT. Its driver-only ZIP has an `x86` filename but contains AMD64 binaries. The archive, four member files, catalog signer and fixed XML are pinned in [dependency metadata](../host/windows/VirtualDisplayDependency.json), [inventory](../host/windows/VirtualDisplayFiles.json) and [notices](../host/windows/VirtualDisplay-NOTICE.txt). Parsing has exact bounds; the privileged broker re-verifies its protected copy.

Windows CI checks package signatures without installing the driver. Inert tests compile the actual adapter and inject device/display/transaction fixtures; they never enumerate a real desktop or change devices, registry or topology. The DLL is not claimed to be reproducibly built from the source tag. Driver security review, stock Windows 11/Secure Boot acceptance, UAC/application-control compatibility, reboot recovery and actual headless streaming remain outstanding. Do not disable system security policies or enable test-signing.

Before enabling installation or updating an installable driver's pins, maintain an explicit allowlist of supported deployment manifests and test removal across upgrades. Current removal deliberately accepts only the bundled candidate's exact hashes; arbitrary journal-supplied hashes are never a new trust authority. No enabled release has deployed this candidate yet.

Sunshine field semantics were checked against its [pinned output selector](https://github.com/LizardByte/Sunshine/blob/63d35f702ee9e362e43263742981836ec0710384/src_assets/common/assets/web/configs/tabs/audiovideo/DisplayOutputSelector.vue) and [display options](https://github.com/LizardByte/Sunshine/blob/63d35f702ee9e362e43263742981836ec0710384/src_assets/common/assets/web/configs/tabs/audiovideo/DisplayDeviceOptions.vue).
