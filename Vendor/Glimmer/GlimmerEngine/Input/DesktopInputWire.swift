// SPDX-License-Identifier: GPL-3.0-only
// DeskBridge additions: ordered desktop input packet submission.
import Foundation

// Host dispatch evidence (read-only source verification; Windows runtime remains pending):
// https://github.com/LizardByte/Sunshine/blob/3d6e1d6008bd4a24906283ab25fcd0becc0a1c07/src/stream.cpp#L779
// https://github.com/LizardByte/Sunshine/blob/3d6e1d6008bd4a24906283ab25fcd0becc0a1c07/src/stream.cpp#L1308
// https://github.com/LizardByte/Sunshine/blob/3d6e1d6008bd4a24906283ab25fcd0becc0a1c07/src/input.cpp#L2214
// https://github.com/LizardByte/Sunshine/blob/3d6e1d6008bd4a24906283ab25fcd0becc0a1c07/src/input.cpp#L2240

/// Real packet/channel seam: Sunshine dispatches input by payload type, not by ENet channel ID.
/// Desktop text, keys and pointer edges share reliable channel 2 so network loss cannot reorder edits.
public enum DesktopInputWire {
    public enum Kind { case keyboard, mouse, text }
    public static func channel(for kind: Kind, desktopOrdering: Bool) -> UInt8 {
        if desktopOrdering { return Enet.ctrlChannelKeyboard }
        switch kind {
        case .keyboard: return Enet.ctrlChannelKeyboard
        case .mouse: return Enet.ctrlChannelMouse
        case .text: return Enet.ctrlChannelUtf8
        }
    }
}

/// One current text submission, preserving its accepted prefix across a local retry.
/// This is a packet cursor, not another input queue; the existing desktop continuation owns later actions.
public struct DesktopTextSubmission {
    private var text: String?
    private var packets: [[UInt8]] = []
    private var next = 0
    public init() {}
    /// A cancelled logical commit must not lend its cursor to a later identical commit.
    public mutating func abandon() {
        text = nil
        packets.removeAll(keepingCapacity: true)
        next = 0
    }
    public mutating func submit(_ value: String, accept: ([UInt8]) -> Int32) -> Int32 {
        if text != value {
            text = value
            packets = InputEncoder.utf8TextPackets(value)
            next = 0
        }
        while next < packets.count {
            let result = accept(packets[next])
            guard result == 0 else { return result }
            next += 1
        }
        abandon()
        return 0
    }
}

