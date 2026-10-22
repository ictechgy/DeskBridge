// SPDX-License-Identifier: GPL-3.0-only
import DeskBridgeCore
import Foundation

func runConnectionInvitationChecks() throws -> Int {
    var count = 0
    func expect(_ condition: Bool, _ text: String) throws { guard condition else { throw CheckFailure(message: text) }; count += 1 }
    func reject(_ text: String) throws {
        do { _ = try ConnectionInvitation(text: text); throw CheckFailure(message: "unsafe invitation accepted") }
        catch is ConnectionInvitation.Failure { count += 1 }
        catch is EndpointPolicy.Failure { count += 1 }
    }
    for name in ["WORK-PC", "개발 PC", "PC & Mac + 1", "테스트 (팀)"] {
        let original = try ConnectionInvitation(name: name, addresses: ["192.168.1.20", "100.80.10.20"])
        try expect(try ConnectionInvitation(text: original.url.absoluteString) == original, "Unicode/query escaping roundtrip")
    }
    for platform in HostPlatform.allCases {
        let invitation = try ConnectionInvitation(name: "개발 Linux + &", addresses: ["192.168.50.20", "100.80.10.20"], platform: platform)
        try expect(try ConnectionInvitation(text: invitation.url.absoluteString) == invitation, "v2 typed role roundtrip")
    }
    let linux = "deskbridge://connect?v=2&name=Linux&address=192.168.50.20&platform=linux"
    for suffix in ["&platform=linux", "&platform=windows", "&token=x"] { try reject(linux + suffix) }
    try reject(linux.replacingOccurrences(of: "platform=linux", with: "platform=unknown"))
    try reject(linux.replacingOccurrences(of: "v=2", with: "v=1"))
    try reject(linux.replacingOccurrences(of: "v=2", with: "v=3"))
    try expect(try ConnectionInvitation(text: linux).platform == .linux, "Linux emitter v2 contract")
    let base = "deskbridge://connect?v=1&name=PC&address=192.168.1.20"
    for text in ["https://connect?v=1&name=PC&address=192.168.1.20", "deskbridge://other?v=1&name=PC&address=192.168.1.20",
                 base + "&v=1", base + "&name=PC", base + "&token=secret", base + "#ignored", base + "&address=192.168.1.20",
                 base.replacingOccurrences(of: "v=1", with: "v=2"), base.replacingOccurrences(of: "v=1", with: "v=01"),
                 base.replacingOccurrences(of: "name=PC", with: "name="), base.replacingOccurrences(of: "name=PC", with: "name=%00PC"),
                 base.replacingOccurrences(of: "name=PC", with: "name=PC%0AName"), base.replacingOccurrences(of: "name=PC", with: "name=PC%E2%80%AE"),
                 base.replacingOccurrences(of: "name=PC", with: "name=%20PC"), base.replacingOccurrences(of: "name=PC", with: "name=PC Name"),
                 base.replacingOccurrences(of: "connect?", with: "connect:47989?"), base.replacingOccurrences(of: "connect?", with: "user@connect?"),
                 base.replacingOccurrences(of: "connect?", with: "connect/path?"), base.replacingOccurrences(of: "address=192.168.1.20", with: "address="),
                 "deskbridge://connect?v=1&name=PC", base + "&address=" + String(repeating: "a", count: 1600)] {
        try reject(text)
    }
    for address in ["8.8.8.8", "127.0.0.1", "localhost", "::1", "192.168.01.20", "192.168.1.20:22", "100.128.1.2"] {
        try reject(base.replacingOccurrences(of: "192.168.1.20", with: address))
    }
    try expect(try ConnectionInvitation(text: "\n " + base + " \n").addresses == ["192.168.1.20"], "pasted outer whitespace only is trimmed")
    try expect(LocalDiscoveryPolicy.candidates(name: "PC", addresses: ["8.8.8.8", "192.168.1.20", "192.168.1.20", "169.254.1.2", "::1"], port: 47989).map(\.address) == ["192.168.1.20"], "discovery filters before host TCP work")
    try expect(LocalDiscoveryPolicy.candidates(name: "PC", addresses: ["192.168.1.20"], port: 443).isEmpty, "unsupported advertised port not silently ignored")
    try expect(LocalDiscoveryPolicy.candidates(name: "PC\nSpoof", addresses: ["192.168.1.20"], port: 47989).isEmpty, "advertised name cannot inject status lines")
    try expect(LocalDiscoveryPolicy.candidates(name: "PC", addresses: Array(repeating: "192.168.1.20", count: 65), port: 47989).isEmpty, "DNS address input is bounded")
    let many = (1...12).map { "192.168.1.\($0)" }
    try expect(LocalDiscoveryPolicy.candidates(name: "PC", addresses: many, port: 47989).count == 8, "per-service result cap")
    var resolved = LocalDiscoveryPolicy.merge(existing: [], name: "PC", addresses: ["fe80::1"], port: 47989)
    try expect(resolved.isEmpty, "IPv6-first callback must remain unresolved")
    resolved = LocalDiscoveryPolicy.merge(existing: resolved, name: "PC", addresses: ["192.168.1.20"], port: 47989)
    try expect(resolved.map(\.address) == ["192.168.1.20"], "later IPv4 callback remains usable")
    resolved = LocalDiscoveryPolicy.merge(existing: resolved, name: "PC", addresses: ["fe80::2"], port: 47989)
    try expect(resolved.map(\.address) == ["192.168.1.20"], "IPv6 update cannot erase retained IPv4")
    resolved = LocalDiscoveryPolicy.merge(existing: resolved, name: "PC", addresses: many, port: 47989)
    try expect(resolved.count == 8 && Set(resolved.map(\.address)).count == 8, "incremental results remain deduplicated and bounded")
    try expect(resolved.contains { $0.address == "192.168.1.20" }, "later callbacks retain an already shown address within its range")
    let crowded = (1...10).map { "10.0.0.\($0)" } + ["100.80.10.20", "172.16.1.20", "192.168.1.20"]
    let diverse = LocalDiscoveryPolicy.candidates(name: "PC", addresses: crowded, port: 47989)
    try expect(diverse.map(\.address) == LocalDiscoveryPolicy.candidates(name: "PC", addresses: Array(crowded.reversed()), port: 47989).map(\.address), "cap follows numeric sorting of the full candidate set")
    try expect(Set(["100.80.10.20", "172.16.1.20", "192.168.1.20"]).isSubset(of: Set(diverse.map(\.address))), "crowded VPN range preserves LAN and Tailscale hints")
    let full = LocalDiscoveryPolicy.candidates(name: "PC", addresses: (1...8).map { "10.0.0.\($0)" }, port: 47989)
    let late = LocalDiscoveryPolicy.merge(existing: full, name: "PC", addresses: ["100.80.10.20", "192.168.1.20"], port: 47989)
    try expect(late.count == 8 && late.contains { $0.address == "100.80.10.20" } && late.contains { $0.address == "192.168.1.20" }, "new ranges can replace excess same-range hints")
    try expect(!late.contains { $0.address.hasPrefix("169.254.") }, "incremental selection keeps APIPA excluded")
    return count
}
