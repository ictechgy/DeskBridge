// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

// One callback bridge retains attempt identity and routes to the active ordered event sink.
// Session and media references are weak; prepared feedback closures retain native routing ownership.

import Foundation
import os

/// Weak media storage is runtime-atomic; sourceLock guards attempt/source publication and event delivery.
/// Setup assigns weak references before callbacks start. The retained context survives until backend
/// workers join, then stop releases its opaque retain and clears the weak current context.
package final class StreamBridgeContext: @unchecked Sendable {
    package nonisolated(unsafe) weak var session: StreamSession?
    package nonisolated(unsafe) weak var videoDecoder: VideoDecoder?
    package nonisolated(unsafe) weak var audioDecoder: AudioDecoder?

    package let feedback: SessionFeedback
    package let publicEvents: SessionEventSource?
    private var attemptID = UUID()
    private let sourceLock = NSLock()
    private var eventSource: ObjectIdentifier?
    // Decoder epochs can be fenced while this transport is still observed.
    // Termination admission ends only at the actor's explicit retirement boundary.
    private var terminationSource: ObjectIdentifier?
    private var terminationAttempt: UUID?
    private var terminationEventsRetired = true
    private var admittedTerminationCode: Int32?
    // A self-initiated reconnect emits its UI edge before stopping the old
    // receiver. Fence its late audio failure in the same lock as event delivery.
    private var audioEventsQuiesced = false

    package var currentAttempt: UUID { sourceLock.withLock { attemptID } }

    package func beginAttempt(_ id: UUID) {
        sourceLock.withLock {
            attemptID = id
            audioEventsQuiesced = false
            publicEvents?.beginAttempt(id)
        }
    }

    package func setEventSource(_ backend: NativeBackend, attempt: UUID = UUID()) {
        sourceLock.withLock {
            eventSource = ObjectIdentifier(backend)
            terminationSource = ObjectIdentifier(backend)
            terminationAttempt = attempt
            terminationEventsRetired = false
            admittedTerminationCode = nil
            attemptID = attempt
            audioEventsQuiesced = false
            publicEvents?.beginAttempt(attempt)
        }
    }

    package func acceptsEvent(from backend: NativeBackend?, attempt: UUID) -> Bool {
        sourceLock.withLock {
            attempt == attemptID && (eventSource == nil || backend.map(ObjectIdentifier.init) == eventSource)
        }
    }

    /// Retain intent before the callback queues an actor Task. A PC-sent reason
    /// outranks local dead-peer (-1); the first explicit PC reason stays intact.
    package func admitTermination(code: Int32, from backend: NativeBackend, attempt: UUID) -> Bool {
        sourceLock.withLock {
            guard !terminationEventsRetired, terminationAttempt == attempt,
                  terminationSource == ObjectIdentifier(backend) else { return false }
            if admittedTerminationCode == nil || (admittedTerminationCode == -1 && code != -1) {
                admittedTerminationCode = code
            }
            return true
        }
    }

    /// Retirement and the final intent snapshot share admission's lock. Keep the
    /// snapshot through receiver drain so an already-queued actor event cannot lose it.
    package func terminationIntent(from backend: NativeBackend, attempt: UUID, retiring: Bool = false) -> Int32? {
        sourceLock.withLock {
            guard terminationAttempt == attempt,
                  terminationSource == ObjectIdentifier(backend) else { return nil }
            if retiring { terminationEventsRetired = true }
            return admittedTerminationCode
        }
    }

    /// The session's event stream, yielded to straight from backend threads so events keep the order
    /// the backend fired them (a Task hop would not). Invariant: written once in start() before any
    /// pipeline runs, and never cleared; stop() finishes it instead.
    package nonisolated(unsafe) var eventContinuation: AsyncStream<StreamEvent>.Continuation?

    /// Weak-static fallback for callbacks that don't take a context pointer
    /// (the decoder-renderer slots except setup, the audio-renderer slots
    /// except init, and the connection-listener slots). The native backend
    /// only runs one session at a time so a single-slot global is correct.
    /// Guarded by an NSLock so the setter on the actor and the getter on a
    /// receive thread don't tear.
    private static let currentLock = NSLock()
    private nonisolated(unsafe) static weak var _current: StreamBridgeContext?

    package static var current: StreamBridgeContext? {
        get {
            currentLock.lock(); defer { currentLock.unlock() }
            return _current
        }
        set {
            currentLock.lock(); defer { currentLock.unlock() }
            _current = newValue
        }
    }

    package init(
        session: StreamSession,
        videoDecoder: VideoDecoder,
        audioDecoder: AudioDecoder, feedback: SessionFeedback = SessionFeedback(), publicEvents: SessionEventSource? = nil
    ) {
        self.session = session
        self.videoDecoder = videoDecoder
        self.audioDecoder = audioDecoder
        self.feedback = feedback
        self.publicEvents = publicEvents
    }

    package func emit(_ event: StreamEvent, source: NativeBackend? = nil, attempt: UUID? = nil) {
        sourceLock.withLock {
            guard source == nil || eventSource == source.map(ObjectIdentifier.init),
                  attempt == nil || attempt == attemptID else { return }
            switch event {
            case .reconnecting:
                audioEventsQuiesced = true
            case .audioFailed where audioEventsQuiesced:
                return
            default:
                break
            }
            if let publicEvents { publicEvents.yield(event, attempt: attemptID) } else { eventContinuation?.yield(event) }
        }
    }

    package func finishEvents() {
        if let publicEvents { publicEvents.finish() } else { eventContinuation?.finish() }
    }

    /// Resolve a context pointer handed to a context-aware callback back
    /// into a bridge instance. Returns nil if the pointer is null.
    package static func from(_ ptr: UnsafeMutableRawPointer?) -> StreamBridgeContext? {
        guard let ptr else { return nil }
        return Unmanaged<StreamBridgeContext>.fromOpaque(ptr).takeUnretainedValue()
    }
}
