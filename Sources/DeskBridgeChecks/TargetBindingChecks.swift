// SPDX-License-Identifier: GPL-3.0-only
import DeskBridgeCore
import Foundation

func runTargetBindingChecks() throws -> Int {
    var count = 0
    let a = "192.168.1.20", b = "100.90.80.70"
    func rejects(_ action: () throws -> Void) throws {
        do { try action(); throw TargetCheckFailure.acceptedStaleTarget }
        catch is TargetBinding.Failure { count += 1 }
    }
    var target = TargetBinding()
    try rejects { try target.require(input: a, expectedAddress: a) }
    let first = try target.begin(input: a)
    try target.accept(first, currentInput: a)
    try target.require(input: a, expectedAddress: a); count += 1
    // Edit without reconnect: even before the UI invalidates, action is bound to its endpoint.
    try rejects { try target.require(input: b, expectedAddress: a) }
    target.invalidate()
    try rejects { try target.require(input: a, expectedAddress: a) }
    // A failed B check cannot resurrect the previous verified A authority.
    let failed = try target.begin(input: b); target.failed(failed)
    try rejects { try target.require(input: b, expectedAddress: b) }
    try rejects { try target.require(input: a, expectedAddress: a) }
    // Asynchronous A finishes after B starts: reject A and retain the newer pending B.
    let obsolete = try target.begin(input: a)
    let current = try target.begin(input: b)
    try rejects { try target.accept(obsolete, currentInput: b) }
    target.failed(obsolete)
    try target.accept(current, currentInput: b)
    try target.require(input: b, expectedAddress: b); count += 1
    // Edit B→A while B request in-flight cannot accept an obsolete reply.
    let editDuringCheck = try target.begin(input: b)
    try rejects { try target.accept(editDuringCheck, currentInput: a) }
    try rejects { try target.require(input: b, expectedAddress: b) }
    // Canonical whitespace is benign; another actor's expected endpoint still must match.
    let trim = try target.begin(input: " " + a + " ")
    try target.accept(trim, currentInput: a)
    try target.require(input: " " + a + " ", expectedAddress: a); count += 1
    try rejects { try target.require(input: a, expectedAddress: b) }
    // Validation failure clears previous authority before throwing.
    do { _ = try target.begin(input: "8.8.8.8"); throw TargetCheckFailure.acceptedStaleTarget }
    catch is EndpointPolicy.Failure { count += 1 }
    try rejects { try target.require(input: a, expectedAddress: a) }
    return count
}
enum TargetCheckFailure: Error { case acceptedStaleTarget }

