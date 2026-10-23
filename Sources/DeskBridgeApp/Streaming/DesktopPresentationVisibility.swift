// SPDX-License-Identifier: GPL-3.0-only

/// Key focus controls input; actual visibility controls presentation and display sleep.
/// Repeated AppKit notifications must not repeatedly flush the decoder or replace activities.
struct DesktopPresentationVisibility {
    private(set) var suppressed: Bool?

    mutating func update(isVisible: Bool, isMiniaturized: Bool, isOcclusionVisible: Bool) -> Bool? {
        let next = !isVisible || isMiniaturized || !isOcclusionVisible
        guard next != suppressed else { return nil }
        suppressed = next
        return next
    }
}
