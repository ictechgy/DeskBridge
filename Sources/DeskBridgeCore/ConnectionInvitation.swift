// SPDX-License-Identifier: GPL-3.0-only
import Foundation

public enum HostPlatform: String, Sendable, Codable, CaseIterable {
    case windows, macos, linux
    public var displayName: String { switch self { case .windows: "Windows"; case .macos: "Mac"; case .linux: "Linux" } }
}

/// Address hints only. Neither QR nor Bonjour grants trust, stores a certificate,
/// authorizes file access, or replaces the ordinary PIN/certificate handshake.
public struct ConnectionInvitation: Sendable, Equatable, Identifiable {
    public static let maximumBytes = 1536
    public let name: String
    public let addresses: [String]
    public let platform: HostPlatform?
    public var id: String { url.absoluteString }

    public enum Failure: Error, LocalizedError {
        case invalid
        public var errorDescription: String? {
            "지원되는 PC 연결 QR/링크가 아닙니다. 공유할 PC의 DeskBridge에서 새 연결 QR을 만드세요."
        }
    }

    public init(name: String, addresses: [String], platform: HostPlatform? = nil) throws {
        guard Self.validName(name), (1...8).contains(addresses.count) else { throw Failure.invalid }
        let checked = try addresses.map { try EndpointPolicy.validatedAddress($0) }
        guard checked == addresses, Set(checked).count == checked.count else { throw Failure.invalid }
        self.name = name; self.addresses = checked; self.platform = platform
    }

    public init(text: String) throws {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.utf8.count <= Self.maximumBytes,
              !text.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0) }),
              let components = URLComponents(string: text),
              components.scheme?.lowercased() == "deskbridge", components.host?.lowercased() == "connect",
              components.user == nil, components.password == nil, components.port == nil,
              components.fragment == nil, components.path.isEmpty || components.path == "/",
              let items = components.queryItems, (3...11).contains(items.count),
              items.allSatisfy({ ["v", "name", "address", "platform"].contains($0.name) && $0.value != nil }),
              items.filter({ $0.name == "v" }).count == 1,
              items.filter({ $0.name == "name" }).count == 1,
              let name = items.first(where: { $0.name == "name" })?.value
        else { throw Failure.invalid }
        let version = items.first { $0.name == "v" }?.value
        let platforms = items.filter { $0.name == "platform" }
        let platform: HostPlatform?
        if version == "1", platforms.isEmpty, items.count <= 10 { platform = nil }
        else if version == "2", platforms.count == 1, let value = platforms[0].value, let known = HostPlatform(rawValue: value) { platform = known }
        else { throw Failure.invalid }
        try self.init(name: name, addresses: items.filter { $0.name == "address" }.compactMap(\.value), platform: platform)
    }

    public var url: URL {
        var components = URLComponents()
        components.scheme = "deskbridge"; components.host = "connect"
        components.queryItems = [URLQueryItem(name: "v", value: platform == nil ? "1" : "2"), URLQueryItem(name: "name", value: name)] +
            addresses.map { URLQueryItem(name: "address", value: $0) }
        if let platform { components.queryItems?.append(URLQueryItem(name: "platform", value: platform.rawValue)) }
        // All fields originate in the checked initializer above.
        return components.url!
    }

    public static func validName(_ name: String) -> Bool {
        !name.isEmpty && name.utf16.count <= 64 && name.utf8.count <= 128 &&
            name == name.trimmingCharacters(in: .whitespacesAndNewlines) &&
            !name.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) || $0.properties.generalCategory == .format }
    }
}

public struct NearbyPC: Sendable, Identifiable, Equatable {
    public let name: String
    public let address: String
    public var id: String { address }
    public init(name: String, address: String) throws {
        let invitation = try ConnectionInvitation(name: name, addresses: [address])
        self.name = invitation.name; self.address = invitation.addresses[0]
    }
}

public enum LocalDiscoveryPolicy {
    /// DNS-SD may report IPv6 before IPv4, or add another interface later.
    public static func merge(existing: [NearbyPC], name: String, addresses: [String], port: Int) -> [NearbyPC] {
        guard port == httpPort, ConnectionInvitation.validName(name), addresses.count <= 64 else { return existing }
        var unique: [String: NearbyPC] = [:]
        for host in existing + addresses.compactMap({ try? NearbyPC(name: name, address: $0) }) {
            unique[host.id] = unique[host.id] ?? host
        }
        return selectedAddresses(Array(unique.keys), retaining: existing.map(\.address)).compactMap { unique[$0] }
    }
    public static let serviceTypes = ["_nvstream._tcp.", "_nvstream-tcp._tcp."]
    public static let maximumServices = 16
    public static let maximumResults = 32
    public static let maximumAddressesPerService = 8
    public static let httpPort = 47989

    /// Keep a representative of every present LAN/Tailscale range. Already shown
    /// addresses win within a range; a newly discovered range may replace an excess
    /// address from another range. The remaining slots and display use numeric order.
    static func selectedAddresses(_ addresses: [String], retaining existing: [String] = []) -> [String] {
        let eligible = Set(addresses.compactMap { try? EndpointPolicy.validatedAddress($0) }
            .filter { !$0.hasPrefix("169.254.") })
        let sorted = eligible.sorted { numericAddress($0) < numericAddress($1) }
        var preferred = existing.filter { eligible.contains($0) }
        preferred += sorted.filter { !preferred.contains($0) }
        var selected: [String] = []
        var ranges = Set<Substring>()
        for address in preferred {
            if let range = address.split(separator: ".").first, ranges.insert(range).inserted {
                selected.append(address)
            }
        }
        for address in preferred where selected.count < maximumAddressesPerService && !selected.contains(address) {
            selected.append(address)
        }
        return selected.sorted { numericAddress($0) < numericAddress($1) }
    }

    private static func numericAddress(_ address: String) -> UInt32 {
        address.split(separator: ".").reduce(0) { ($0 << 8) | (UInt32($1) ?? 0) }
    }

    /// DNS-SD is only a hint. Reject incompatible ports/addresses before any
    /// application TCP request; the user explicitly chooses a checked candidate.
    public static func candidates(name: String, addresses: [String], port: Int) -> [NearbyPC] {
        guard port == httpPort, ConnectionInvitation.validName(name), addresses.count <= 64 else { return [] }
        return selectedAddresses(addresses).compactMap { try? NearbyPC(name: name, address: $0) }
    }
}
