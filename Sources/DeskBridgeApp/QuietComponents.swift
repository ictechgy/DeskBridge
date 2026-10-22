// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 DeskBridge contributors
import AppKit
import SwiftUI

enum QuietStyle {
    static let canvas = Color(nsColor: .windowBackgroundColor)
    static let surface = Color(nsColor: .controlBackgroundColor)
    static let border = Color(nsColor: .separatorColor).opacity(0.65)
    static let radius: CGFloat = 10
}
extension View {
    func quietPanel() -> some View {
        background(QuietStyle.surface, in: RoundedRectangle(cornerRadius: QuietStyle.radius))
            .overlay { RoundedRectangle(cornerRadius: QuietStyle.radius).strokeBorder(QuietStyle.border, lineWidth: 1) }
    }
}
struct QuietPageHeader: View {
    let title: String
    let subtitle: String
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 27, weight: .bold))
            Text(subtitle).font(.body).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
struct QuietBadge: View {
    let title: String
    let symbol: String
    var tint: Color = .secondary
    var body: some View {
        Label(title, systemImage: symbol).font(.caption.weight(.medium))
            .foregroundStyle(tint).padding(.horizontal, 8).padding(.vertical, 5)
            .background(tint.opacity(0.09), in: RoundedRectangle(cornerRadius: 5))
            .accessibilityElement(children: .combine)
    }
}
struct QuietHelp: View {
    let text: String
    var symbol = "info.circle"
    var body: some View {
        Label { Text(text).fixedSize(horizontal: false, vertical: true) }
        icon: { Image(systemName: symbol) }
            .font(.callout).foregroundStyle(.secondary)
    }
}
struct StatusPanel: View {
    let status: String
    let error: String?
    let busy: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            if busy || !status.isEmpty {
                HStack(alignment: .top, spacing: 9) {
                    if busy { ProgressView().controlSize(.small) }
                    Text(status).fixedSize(horizontal: false, vertical: true)
                }.accessibilityElement(children: .combine)
            }
            if let error {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
        }.font(.callout).frame(maxWidth: .infinity, alignment: .leading)
    }
}
