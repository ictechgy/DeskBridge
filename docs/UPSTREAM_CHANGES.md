# GlimmerEngine patch provenance

Base: Se7enbrc/glimmer dc74ced497fc84defd706b4270e50478b430e562 (2026.10.8-rc.12).
All original GPL/copyright notices retained. The original 266 package blobs plus license, credits and security notes are recorded in Vendor/Glimmer/UPSTREAM.json.

Knot changes, 2026-10-18:

- NEW Protocol/StreamSecurityPolicy.swift: require encrypted rtspenc signalling and all three media/control capability bits.
- Network/RtspClient.swift: apply pure mandatory policy in the real pre-network/RTSP negotiation path.
- Network/RtspClient.swift (preview.8): authenticate encrypted responses, reject repeated/older host sequence numbers independent of the outbound counter, and bind exactly one CSeq to the request before committing receive state. Strict monotonic ordering permits gaps from retries and rejects wrap within the instance; complete headers/status are required. No plaintext fallback or destination change is introduced.
- Network/InputBatcher.swift (preview.9): report actual report/pair send acceptance; preserve unsent mouse chunks, absolute positions and reliable gyro-null state; refuse later ordering barriers and mouse mode/channel changes until earlier retained state drains. Only accepted relative chunks are consumed. Rejected state rearms one timer; terminal stop prevents replay. Superseded unreliable sensor samples remain droppable.
- Session/StreamConnection+Configuration.swift and Session/StreamSession+Connect.swift: request all-channel encryption.
- Input/StreamInput.swift: desktop input sequencing state.
- NEW Input/StreamInput+Desktop.swift: narrow public keyboard, committed text, absolute pointer and focus-release bridge.
- NEW Input/DesktopInputWire.swift plus Input/InputText.swift, Network/InputBatcher.swift, Session/NativeBackend.swift and Session/NativeBackend+Input.swift: desktop-only shared reliable channel, real text acceptance and a single-batch retry cursor so a remote save/click cannot overtake or duplicate pending text. Legacy non-desktop channel defaults are retained.
- Input/StreamInput+Desktop.swift (preview.8): once committed-text ordering allows a key event to replay, a new owned key release is recorded before older rejected releases are retried. Revoking focus/ownership still discards delayed text and queued key-down work. The reliable retry/reconciliation path remains authoritative for a rejected key release.
- Network/InputBatcher.swift and Session/NativeBackend+Input.swift: merge absolute pointer motion under backpressure while preserving the shared reliable channel and text/key/button barriers.
- Network/Network.swift, Pairing.swift, NetworkClient+Endpoints.swift, NetworkClient+Request.swift and ControlTransport.swift: provisional pairing trust, strict present session-key fields and HTTP framing, mandatory TLS pin, bounded exchange lifecycle and launch/resume reply ownership.
- Session/StreamSession+Public.swift: a public native lifecycle adapter connects the existing balanced activity and wake edges to Knot's platform implementation.

Host compatibility source: Sunshine's pinned stream.cpp dispatch ignores ENet channel ID and input.cpp queues/drains input FIFO. Exact links are retained in DesktopInputWire.swift. Real host acceptance is still required.

The native app window/media/input adapters are newly maintained under Sources/DeskBridgeApp/Streaming. A positional key mapping excerpt is GPL-attributed. PIN proof cryptography, codec implementation and receiver cryptography remain upstream code; the pairing transaction around that proof is patched as described above. This document is a change summary, not a security proof.

Verify every untouched upstream blob with scripts/verify_vendor.py. The exact maintained diff against the pinned originals is Vendor/Glimmer/DeskBridge.patch.

The zero-context patch is checked without changing files by `git apply --reverse --unidiff-zero --check DeskBridge.patch` from `Vendor/Glimmer`; the vendor verifier runs this check on every build.

