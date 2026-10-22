// SPDX-License-Identifier: GPL-3.0-only
import Combine
import Darwin
import DeskBridgeCore
import Foundation

/// DNS-SD metadata resolution only: no subnet/port scan or TCP host probing.
/// Production AppLifecycle starts it; constructing a model/fixture never searches.
@MainActor
final class NearbyPCBrowser: NSObject, ObservableObject, @preconcurrency NetServiceBrowserDelegate, @preconcurrency NetServiceDelegate {
    @Published private(set) var hosts: [NearbyPC] = []
    @Published private(set) var searching = false
    @Published private(set) var status = "같은 Wi-Fi의 Sunshine PC를 찾을 수 있어요."
    private var browsers: [NetServiceBrowser] = []
    private var services: [String: NetService] = [:]
    private var resolved: [String: [NearbyPC]] = [:]
    private var timeout: Task<Void, Never>?
    private var generation = UUID()

    func start() {
        stop()
        hosts = []; resolved = [:]; searching = true
        status = "같은 Wi-Fi에서 Sunshine PC를 찾는 중…"
        let current = UUID(); generation = current
        for type in LocalDiscoveryPolicy.serviceTypes {
            let browser = NetServiceBrowser()
            browser.delegate = self
            browser.schedule(in: .main, forMode: .common)
            browsers.append(browser)
            browser.searchForServices(ofType: type, inDomain: "local.")
        }
        timeout = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(10)) } catch { return }
            guard let self, generation == current else { return }
            stop()
            status = hosts.isEmpty ? "PC를 찾지 못했어요. Sunshine 실행과 Mac의 로컬 네트워크 권한을 확인하거나 QR로 연결하세요."
                : "찾은 PC를 선택하세요. PIN으로 PC를 확인한 뒤 연결합니다."
        }
    }

    func stop() {
        let wasSearching = searching
        generation = UUID(); timeout?.cancel(); timeout = nil
        for browser in browsers { browser.delegate = nil; browser.stop(); browser.remove(from: .main, forMode: .common) }
        browsers = []
        for service in services.values { service.delegate = nil; service.stop(); service.remove(from: .main, forMode: .common) }
        services = [:]; searching = false
        if wasSearching { status = hosts.isEmpty ? "검색을 중지했습니다. 다시 찾기 또는 QR 연결을 선택하세요." : "찾은 PC를 선택하세요. PIN으로 확인한 뒤 연결합니다." }
    }

    private func key(_ service: NetService) -> String { service.type + "|" + service.domain + "|" + service.name }
    private func publish() {
        var unique: [String: NearbyPC] = [:]
        for items in resolved.sorted(by: { $0.key < $1.key }).map(\.value) {
            for host in items { unique[host.id] = unique[host.id] ?? host }
        }
        hosts = Array(unique.values).sorted { ($0.name, $0.address) < ($1.name, $1.address) }
            .prefix(LocalDiscoveryPolicy.maximumResults).map { $0 }
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        guard searching, browsers.contains(where: { $0 === browser }),
              LocalDiscoveryPolicy.serviceTypes.contains(service.type), service.domain == "local.",
              ConnectionInvitation.validName(service.name), services[key(service)] == nil,
              services.count < LocalDiscoveryPolicy.maximumServices else { return }
        services[key(service)] = service
        service.delegate = self
        service.schedule(in: .main, forMode: .common)
        service.resolve(withTimeout: 3)
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) {
        guard browsers.contains(where: { $0 === browser }) else { return }
        let id = key(service)
        services[id]?.delegate = nil; services[id]?.stop(); services[id]?.remove(from: .main, forMode: .common)
        services.removeValue(forKey: id)
        resolved.removeValue(forKey: id); publish()
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didNotSearch errorDict: [String: NSNumber]) {
        guard browsers.contains(where: { $0 === browser }) else { return }
        stop()
        status = "검색을 시작하지 못했어요. 시스템 설정 → 개인정보 보호 및 보안 → 로컬 네트워크에서 Knot를 허용하거나 QR을 사용하세요."
    }

    func netServiceDidResolveAddress(_ sender: NetService) {
        guard searching, services[key(sender)] === sender else { return }
        let addresses = (sender.addresses ?? []).prefix(64).compactMap { Self.ipv4($0) }
        resolved[key(sender)] = LocalDiscoveryPolicy.merge(existing: resolved[key(sender)] ?? [], name: sender.name,
                                                           addresses: addresses, port: sender.port)
        // Keep the bounded resolver alive for incremental IPv4/IPv6/interface updates.
        publish()
    }

    func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        guard services[key(sender)] === sender else { return }
        sender.delegate = nil
        sender.stop(); sender.remove(from: .main, forMode: .common)
        services.removeValue(forKey: key(sender))
        resolved.removeValue(forKey: key(sender))
        publish()
    }

    static func ipv4(_ data: Data) -> String? {
        guard data.count >= MemoryLayout<sockaddr_in>.size else { return nil }
        let address = data.withUnsafeBytes { $0.loadUnaligned(as: sockaddr_in.self) }
        guard address.sin_len == UInt8(MemoryLayout<sockaddr_in>.size), address.sin_family == sa_family_t(AF_INET),
              Int(UInt16(bigEndian: address.sin_port)) == LocalDiscoveryPolicy.httpPort else { return nil }
        var value = address.sin_addr.s_addr
        return withUnsafeBytes(of: &value) { $0.map { String($0) }.joined(separator: ".") }
    }
}
