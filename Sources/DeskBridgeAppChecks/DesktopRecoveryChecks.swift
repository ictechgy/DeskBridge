// SPDX-License-Identifier: GPL-3.0-only
import GlimmerEngine

func runDesktopRecoveryChecks() throws -> Int {
    var count = 0
    func expect(_ condition: Bool, _ message: String) throws {
        guard condition else { throw ModelCheckFailure(message: message) }; count += 1
    }
    var state = DesktopRecoveryPresentation()
    try expect(state.message != nil, "connecting did not show an in-window status")
    state.receive(.connectionEstablished)
    try expect(state.message != nil, "control connection hid video wait before first frame")
    state.receive(.firstFrame)
    try expect(state.message == nil, "first frame did not clear connecting status")
    state.receive(.waitingForVideo(true))
    try expect(state.phase == .waiting && state.message != nil, "live video stall was invisible")
    state.receive(.waitingForVideo(false))
    try expect(state.message == nil, "resumed video did not clear waiting status")
    state.receive(.reconnecting)
    state.receive(.stageFailed(name: "synthetic retry", errorCode: -1))
    state.receive(.stageStarting(name: "synthetic reconnect"))
    state.receive(.waitingForVideo(false))
    try expect(state.phase == .reconnecting && state.message?.contains("마지막 화면") == true,
               "reconnect lost its frozen-picture explanation")
    state.receive(.reconnected)
    try expect(state.phase == .waiting, "transport recovery falsely proved fresh video")
    state.receive(.firstFrame)
    try expect(state.message == nil, "fresh recovery frame did not clear status")
    state.receive(.reconnecting); state.receive(.firstFrame); state.receive(.reconnected)
    try expect(state.message == nil, "late reconnected event restored a stale waiting card")
    for terminal in [StreamEvent.stopped, .connectionTerminated(errorCode: -1)] {
        var ended = DesktopRecoveryPresentation()
        ended.receive(.reconnecting); ended.receive(terminal); ended.receive(.firstFrame); ended.receive(.reconnecting)
        try expect(ended.phase == .ended && ended.message == nil, "terminal presentation accepted stale recovery events")
    }
    return count
}

@MainActor func runDesktopTerminationChecks() async throws -> Int {
    var count = 0
    for delayed in [false, true] {
        let termination = DesktopTermination()
        var replies = 0
        var revocations = 0
        var cleanupOrderingFailed = false
        termination.begin(timeout: .milliseconds(10), revoke: { revocations += 1 }, cleanup: {
            guard revocations == 1 else { cleanupOrderingFailed = true; return }
            if delayed { try? await Task.sleep(for: .seconds(30)) }
        }, reply: { replies += 1 })
        termination.begin(revoke: { revocations += 100 }, cleanup: {}, reply: { replies += 100 })
        guard revocations == 1 else { throw ModelCheckFailure(message: "sharing revocation deferred behind async cleanup") }
        for _ in 0..<1000 {
            if termination.finished { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        guard termination.finished && replies == 1 && !cleanupOrderingFailed && revocations == 1 else { throw ModelCheckFailure(message: "Quit deadline or reentrant reply failed") }
        await Task.yield()
        guard replies == 1 else { throw ModelCheckFailure(message: "late cleanup replied twice") }
        count += 3
    }
    var release: CheckedContinuation<Void, Never>?
    var completed = Set<Int>()
    let cleanup = Task { @MainActor in
        await DesktopTermination.cleanupOwners([
            { await withCheckedContinuation { release = $0 }; completed.insert(0) },
            { completed.insert(1) }, { completed.insert(2) }, { completed.insert(3) }
        ])
    }
    for _ in 0..<1000 where release == nil || completed.count < 3 { await Task.yield() }
    guard release != nil && completed == [1, 2, 3] else { throw ModelCheckFailure(message: "one suspended owner blocked other cleanup") }
    release?.resume(); await cleanup.value
    guard completed == [0, 1, 2, 3] else { throw ModelCheckFailure(message: "parallel owner cleanup was skipped") }
    count += 2
    return count
}
