// SPDX-License-Identifier: GPL-3.0-only
import DeskBridgeCore
import Foundation

private final class ProgressClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt64 = 0
    func read() -> UInt64 { lock.withLock { value } }
    func set(_ value: UInt64) { lock.withLock { self.value = value } }
}
func runTransferProgressChecks() throws -> Int {
    enum Failure: Error { case failed(String) }
    var count = 0
    func check(_ condition: Bool, _ message: String) throws {
        guard condition else { throw Failure.failed(message) }; count += 1
    }
    let clock = ProgressClock()
    let gate = TransferProgressGate(now: { clock.read() })
    try check(gate.accept(bytes: 1, total: 20_000), "first progress delivered immediately")
    let burst = (2..<10_002).filter { gate.accept(bytes: UInt64($0), total: 20_000) }.count
    try check(burst == 0, "ten thousand chunk callbacks cannot flood main actor")
    clock.set(99_999_999)
    try check(!gate.accept(bytes: 10_002, total: 20_000), "updates limited to ten per second")
    clock.set(100_000_000)
    try check(gate.accept(bytes: 10_003, total: 20_000), "next interval update admitted")
    clock.set(0)
    try check(!gate.accept(bytes: 10_004, total: 20_000), "clock reversal cannot underflow")
    try check(gate.accept(bytes: 20_000, total: 20_000), "completion delivered without waiting")
    try check(!gate.accept(bytes: 20_000, total: 20_000), "completion delivered once")
    let empty = TransferProgressGate(now: { 0 })
    try check(empty.accept(bytes: 0, total: 0) && !empty.accept(bytes: 0, total: 0), "empty transfer completes once")
    return count
}
