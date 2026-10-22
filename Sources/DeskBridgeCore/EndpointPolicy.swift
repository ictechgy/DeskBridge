// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 DeskBridge contributors
import Foundation

public enum EndpointPolicy {
    public enum Failure: Error, LocalizedError {
        case privateIPv4Required
        public var errorDescription: String? {
            "LAN 또는 Tailscale의 IPv4 주소를 입력하세요. 예: 192.168.1.20, 100.80.10.20"
        }
    }
    /// Literal addresses remove DNS rebinding/config/URL ambiguity in the initial direct-only app.
    public static func validatedAddress(_ input: String) throws -> String {
        let address = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = address.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { throw Failure.privateIPv4Required }
        var bytes: [UInt8] = []
        for part in parts {
            guard !part.isEmpty, part.utf8.allSatisfy({ (48...57).contains($0) }),
                  part.count == 1 || part.first != "0", let byte = UInt8(part)
            else { throw Failure.privateIPv4Required }
            bytes.append(byte)
        }
        let a = bytes[0], b = bytes[1]
        let allowed = a == 10 || (a == 172 && (16...31).contains(b)) ||
            (a == 192 && b == 168) || (a == 100 && (64...127).contains(b)) ||
            (a == 169 && b == 254)
        guard allowed else { throw Failure.privateIPv4Required }
        return address
    }
}

