// SPDX-License-Identifier: GPL-3.0-only
import Darwin
import DeskBridgeCore
import Foundation

/// A release download is bounded while receiving, before it can occupy an
/// unbounded URLSession download file. The caller still verifies its exact hash.
enum MacHostDownload {
    struct Policy: Sendable {
        let source: URL
        let bytes: Int64
        let maximumRedirects: Int

        func allows(_ url: URL) -> Bool {
            guard url.scheme?.lowercased() == "https", url.user == nil, url.password == nil,
                  url.port == nil || url.port == 443, url.fragment == nil,
                  let host = url.host?.lowercased() else { return false }
            switch host {
            case "github.com":
                return url.path == source.path && url.query == nil
            case "release-assets.githubusercontent.com", "objects.githubusercontent.com":
                return true
            default:
                return false
            }
        }
    }

    static func fetch(from source: URL, expectedBytes: Int64,
                      configuration: URLSessionConfiguration = .ephemeral,
                      maximumRedirects: Int = 5, timeout: TimeInterval = 600,
                      temporaryDirectory: URL = FileManager.default.temporaryDirectory) async throws -> URL {
        try Task.checkCancellation()
        let policy = Policy(source: source, bytes: expectedBytes, maximumRedirects: maximumRedirects)
        guard expectedBytes > 0, maximumRedirects >= 0, timeout.isFinite, timeout > 0,
              policy.allows(source), source.host?.lowercased() == "github.com" else {
            throw MacHostPolicy.Failure.download
        }
        let transfer = try MacHostDownloadTransfer(policy: policy, timeout: timeout,
                                                  temporaryDirectory: temporaryDirectory)
        let temporary = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                transfer.start(configuration: configuration, continuation: continuation)
            }
        } onCancel: {
            transfer.cancel()
        }
        do { try Task.checkCancellation() }
        catch { try? FileManager.default.removeItem(at: temporary); throw error }
        return temporary
    }
}

/// URLSession may call delegates and task cancellation on different executors.
/// Every mutable field, including the file descriptor, is protected by lock.
final class MacHostDownloadTransfer: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let policy: MacHostDownload.Policy
    private let timeout: TimeInterval
    private let temporary: URL
    private let lock = NSLock()
    private var descriptor: Int32
    private var receivedBytes: Int64 = 0
    private var receivedResponse = false
    private var redirects = 0
    private var continuation: CheckedContinuation<URL, any Error>?
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var deadline: DispatchSourceTimer?
    private var terminal: Result<URL, any Error>?

    init(policy: MacHostDownload.Policy, timeout: TimeInterval, temporaryDirectory: URL) throws {
        self.policy = policy; self.timeout = timeout
        temporary = temporaryDirectory.appendingPathComponent("deskbridge-sunshine-" + UUID().uuidString + ".part")
        descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw MacHostPolicy.Failure.download }
        super.init()
    }

    deinit {
        if descriptor >= 0 { close(descriptor); try? FileManager.default.removeItem(at: temporary) }
    }

    func start(configuration: URLSessionConfiguration, continuation: CheckedContinuation<URL, any Error>) {
        lock.lock()
        if let terminal {
            lock.unlock(); continuation.resume(with: terminal); return
        }
        self.continuation = continuation
        // Ephemeral transport only: no ambient cookies, credentials or cache.
        let configuration = configuration.copy() as! URLSessionConfiguration
        configuration.httpCookieStorage = nil; configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil; configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = min(60, timeout)
        configuration.timeoutIntervalForResource = timeout
        let queue = OperationQueue(); queue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
        var request = URLRequest(url: policy.source)
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        let task = session.dataTask(with: request)
        self.session = session; self.task = task
        // An explicit wall-clock deadline also bounds a peer that keeps sending.
        let deadline = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        deadline.schedule(deadline: .now() + timeout)
        deadline.setEventHandler { [weak self] in self?.finish(.failure(URLError(.timedOut))) }
        self.deadline = deadline
        lock.unlock()
        deadline.resume(); task.resume()
    }

    func cancel() { finish(.failure(CancellationError())) }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        lock.lock()
        let allowed = terminal == nil && response.url.map(policy.allows) == true &&
            request.url.map(policy.allows) == true && redirects < policy.maximumRedirects
        if allowed { redirects += 1 }
        lock.unlock()
        guard allowed else {
            // Reject before URLSession can issue a request to the new location.
            completionHandler(nil); finish(.failure(MacHostPolicy.Failure.download)); return
        }
        var checked = request
        checked.setValue(nil, forHTTPHeaderField: "Authorization")
        checked.setValue(nil, forHTTPHeaderField: "Proxy-Authorization")
        checked.setValue(nil, forHTTPHeaderField: "Cookie")
        checked.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        completionHandler(checked)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        lock.lock()
        let allowed = terminal == nil && !receivedResponse && response.url.map(policy.allows) == true &&
            (response as? HTTPURLResponse)?.statusCode == 200 && response.expectedContentLength <= policy.bytes
        if allowed { receivedResponse = true }
        lock.unlock()
        completionHandler(allowed ? .allow : .cancel)
        if !allowed { finish(.failure(MacHostPolicy.Failure.download)) }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        guard terminal == nil else { lock.unlock(); return }
        guard receivedResponse, Int64(data.count) <= policy.bytes - receivedBytes else {
            lock.unlock(); finish(.failure(MacHostPolicy.Failure.download)); return
        }
        let written = data.withUnsafeBytes { buffer -> Bool in
            var offset = 0
            while offset < buffer.count {
                let result = write(descriptor, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if result < 0 && errno == EINTR { continue }
                guard result > 0 else { return false }
                offset += result
            }
            return true
        }
        if written { receivedBytes += Int64(data.count) }
        lock.unlock()
        if !written { finish(.failure(MacHostPolicy.Failure.download)) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        lock.lock()
        let complete = receivedResponse && receivedBytes == policy.bytes
        lock.unlock()
        if let error { finish(.failure(error)) }
        else if complete { finish(.success(temporary)) }
        else { finish(.failure(MacHostPolicy.Failure.download)) }
    }

    private func finish(_ result: Result<URL, any Error>) {
        lock.lock()
        guard terminal == nil else { lock.unlock(); return }
        terminal = result
        if descriptor >= 0 { close(descriptor); descriptor = -1 }
        if case .failure = result { try? FileManager.default.removeItem(at: temporary) }
        let continuation = continuation; self.continuation = nil
        let session = session; self.session = nil; task = nil
        let deadline = deadline; self.deadline = nil
        lock.unlock()
        deadline?.cancel(); session?.invalidateAndCancel()
        continuation?.resume(with: result)
    }
}
