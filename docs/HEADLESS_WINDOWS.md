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

An administrator-owned journal records the exact planned random device instance before creation and the Windows-published OEM INF before binding the device. A fresh post-install check must match instance, OEM INF and driver version. Knot removes only that matching device and unchanged owned files/registry state. Foreign present/phantom displays, altered settings, unknown files and ambiguous ownership cause refusal with data preserved. A pending restart retains recovery data. Schema 3 requires both a changed CIM boot timestamp and a changed protected volatile boot-session marker before releasing resources after interrupted or reboot-pending removal; missing or unchanged evidence preserves the deployment. Restart and run removal again. Older schema 2 pending records lack the additional evidence and require administrator review. Successful installation pending restart and failed installation with pending rollback have separate receipts and messages. Do not manually delete the journal to bypass refusal.

Uninstalling Knot intentionally leaves the virtual display and recovery data. Remove the display first if no longer needed. Windows driver-store cached packages are retained; Knot never force-deletes a shared OEM driver package.

## Package and validation boundary

The candidate is [Virtual Display Driver 25.7.23](https://github.com/VirtualDrivers/Virtual-Display-Driver/releases/tag/25.7.23), MIT. Its driver-only ZIP has an `x86` filename but contains AMD64 binaries. The archive, four member files, catalog signer and fixed XML are pinned in [dependency metadata](../host/windows/VirtualDisplayDependency.json), [inventory](../host/windows/VirtualDisplayFiles.json) and [notices](../host/windows/VirtualDisplay-NOTICE.txt). Parsing has exact bounds; the privileged broker re-verifies its protected copy.

Windows CI checks package signatures without installing the driver. Inert tests compile the actual adapter and inject device/display/transaction fixtures; they never enumerate a real desktop or change devices, registry or topology. The DLL is not claimed to be reproducibly built from the source tag. Driver security review, stock Windows 11/Secure Boot acceptance, UAC/application-control compatibility, reboot recovery and actual headless streaming remain outstanding. Do not disable system security policies or enable test-signing.

[Trusted deployment profiles](../host/windows/VirtualDisplayDeployments.json) preserve exact supported historical archive, signer, driver and deployed-file identities independently of the current download pin, install policy and XML template. Removal accepts only those source-owned profiles; journal-supplied hashes never become a new trust authority. Future driver updates must retain supported profiles and test removal across upgrades. No enabled release has deployed this candidate yet.

The complete deployment is flushed and verified in a fresh protected sibling directory, then published by same-volume rename before registry or device mutation. Final removal retires the owned directory before deleting its remaining journal. Interrupted staging or retired directories are preserved and never swept. A stable private control directory holds an exclusive persistent file lock; no predictable global mutex is used. Preflight refusal cannot trigger rollback of a pre-existing deployment.

A narrowly recognized incomplete JSON update can be quarantined with its exact hash in the protected control directory only when an intact predecessor and all remaining owned payload files validate. Parseable hostile records, orphan updates (including a noninitial update without its predecessor), unknown files, interrupted control/registry-key creation and ambiguous state still require administrator review. The stored installation restart flag records Windows's original request; read-only status does not clear it or infer successful streaming after a reboot. The read-only UI shows the recovery record before attempting native device probing; a failed probe disables operation buttons without hiding that record.

Enablement still requires stock Windows validation of reboot identity across clock/time-zone changes, sleep, Fast Startup and explicit restart; OEM-package selection; private ACL/lock behavior; interrupted writes and recovery; and actual headless streaming. Synthetic fixtures do not establish these runtime properties.

Sunshine field semantics were checked against its [pinned output selector](https://github.com/LizardByte/Sunshine/blob/63d35f702ee9e362e43263742981836ec0710384/src_assets/common/assets/web/configs/tabs/audiovideo/DisplayOutputSelector.vue) and [display options](https://github.com/LizardByte/Sunshine/blob/63d35f702ee9e362e43263742981836ec0710384/src_assets/common/assets/web/configs/tabs/audiovideo/DisplayDeviceOptions.vue).
