// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import GlimmerEngine

enum EnginePolicyCheckFailure: Error { case failed(String) }

/// Pure policy checks: no session, identity, preferences, socket, screen or media initialization.
@discardableResult
func runEnginePolicyChecks() throws -> Int {
    var checks = 0
    func require(_ condition: @autoclosure () -> Bool, _ label: String) throws {
        guard condition() else { throw EnginePolicyCheckFailure.failed(label) }
        checks += 1
    }
    try StreamSecurityPolicy.validateSignalling(url: "rtspenc://192.0.2.1:48010")
    checks += 1
    for url in ["rtsp://192.0.2.1:48010", "https://example.test/rtspenc://", "rtsp://rtspenc://example.test", "", "file:///rtspenc://"] {
        do {
            try StreamSecurityPolicy.validateSignalling(url: url)
            throw EnginePolicyCheckFailure.failed("accepted plaintext or malformed signalling")
        } catch is StreamSecurityPolicy.Failure { checks += 1 }
    }
    for features in UInt32(0)...UInt32(15) {
        if features & 7 == 7 {
            let selected = try StreamSecurityPolicy.negotiatedFeatures(supported: features)
            try require(selected == 7, "all three encryption channels must be selected")
        } else {
            do {
                _ = try StreamSecurityPolicy.negotiatedFeatures(supported: features)
                throw EnginePolicyCheckFailure.failed("accepted an unencrypted channel")
            } catch is StreamSecurityPolicy.Failure { checks += 1 }
        }
    }
    return checks
}
