// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// A stalled transport teardown cannot leave the native Quit request pending forever.
@MainActor final class DesktopTermination {
    private var started = false
    private(set) var finished = false
    private var cleanupTask: Task<Void, Never>?
    private var deadlineTask: Task<Void, Never>?

    static func cleanupOwners(_ actions: [@MainActor () async -> Void]) async {
        let tasks = actions.map { action in Task { @MainActor in await action() } }
        await withTaskCancellationHandler {
            for task in tasks { await task.value }
        } onCancel: { for task in tasks { task.cancel() } }
    }

    func begin(timeout: Duration = .seconds(5), revoke: @MainActor () -> Void = {}, cleanup: @escaping @MainActor () async -> Void,
               reply: @escaping @MainActor () -> Void) {
        guard !started else { return }
        started = true
        // Revoke owned sharing before any asynchronous screen teardown can stall.
        revoke()
        cleanupTask = Task { [weak self] in
            await cleanup()
            self?.finish(reply)
        }
        deadlineTask = Task { [weak self] in
            do { try await Task.sleep(for: timeout) } catch { return }
            self?.finish(reply)
        }
    }
    private func finish(_ reply: () -> Void) {
        guard !finished else { return }
        finished = true
        cleanupTask?.cancel(); deadlineTask?.cancel()
        cleanupTask = nil; deadlineTask = nil
        reply()
    }
}
