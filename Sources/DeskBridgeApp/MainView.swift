// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 DeskBridge contributors
import SwiftUI
import DeskBridgeCore

enum Page: String, CaseIterable, Identifiable {
    case desktop = "Windows 화면", linuxDesktop = "Linux 화면", macHost = "이 Mac 공유", files = "파일", setup = "시작하기"
    var id: String { rawValue }
    var symbol: String {
        switch self { case .desktop: "desktopcomputer"; case .linuxDesktop: "desktopcomputer"; case .macHost: "display.2"; case .files: "folder"; case .setup: "checklist" }
    }
}
struct MainView: View {
    @EnvironmentObject private var desktop: DesktopModel
    @State private var page: Page?
    private let linux: LinuxDesktopWorkspace?
    init(initialPage: Page = .desktop, linux: LinuxDesktopWorkspace? = nil) { _page = State(initialValue: initialPage); self.linux = linux }
    var body: some View {
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 9) {
                    Image("BrandMark").resizable().interpolation(.high)
                        .frame(width: 30, height: 30).accessibilityHidden(true)
                    Text("DeskBridge").font(.system(size: 17, weight: .bold))
                }.padding(.horizontal, 20).padding(.top, 22).padding(.bottom, 20)
                List(selection: $page) {
                    Section("작업 공간") {
                        ForEach(Page.allCases) { item in
                            Label(item.rawValue, systemImage: item.symbol).tag(item).padding(.vertical, 5)
                        }
                    }
                }.listStyle(.sidebar).scrollContentBackground(.hidden)
                sidebarHost.padding(20)
            }.navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 260)
        } detail: {
            Group {
                switch page ?? .desktop {
                case .desktop: DesktopPage { page = .setup }
                case .linuxDesktop:
                    if let linux { LinuxDesktopSurface(model: linux.desktop, files: linux.files) }
                    else { Text("Linux 연결 컨텍스트가 없습니다.") }
                case .macHost: MacHostPage()
                case .files: FilesPage()
                case .setup: SetupPage(onDesktop: { page = .desktop }, onFiles: { page = .files })
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity).background(QuietStyle.canvas)
                .navigationTitle((page ?? .desktop).rawValue)
        }.navigationSplitViewStyle(.balanced)
            .onOpenURL { url in
                page = InvitationRouting.review(url.absoluteString, windows: desktop, linux: linux?.desktop)
            }
            .sheet(item: $desktop.pendingInvitation) { invitation in
                ConnectionInvitationSheet(model: desktop, invitation: invitation)
            }
    }
    private var activeDesktop: DesktopModel { page == .linuxDesktop ? linux?.desktop ?? desktop : desktop }
    private var sidebarHost: some View { SidebarHostStatus(model: activeDesktop) }
}

/// Parse first: malformed links cannot choose a role from unvalidated text.
@MainActor enum InvitationRouting {
    static func review(_ text: String, windows: DesktopModel, linux: DesktopModel?) -> Page {
        let invitation: ConnectionInvitation
        do { invitation = try ConnectionInvitation(text: text) }
        catch { windows.invitationError = DesktopModel.failureMessage(error); return .desktop }
        let isLinux = invitation.platform == .linux
        guard let target = isLinux ? linux : windows else {
            windows.invitationError = "Linux 연결 컨텍스트가 없습니다. 앱을 다시 여세요."; return .desktop
        }
        do { try target.reviewInvitation(invitation) }
        catch { target.invitationError = DesktopModel.failureMessage(error).replacingOccurrences(of: "Windows", with: target.platformName) }
        return isLinux ? .linuxDesktop : .desktop
    }
}
private struct SidebarHostStatus: View {
    @ObservedObject var model: DesktopModel
    var body: some View { sidebarHost }
    private var sidebarHost: some View {
        VStack(alignment: .leading, spacing: 14) {
            Divider()
            Label {
                VStack(alignment: .leading, spacing: 4) {
                    Text(hostName).font(.callout.weight(.semibold)).lineLimit(1)
                    Text(hostState).font(.caption).foregroundStyle(.secondary)
                }
            } icon: { Image(systemName: "desktopcomputer").foregroundStyle(.secondary) }
        }.accessibilityElement(children: .combine)
    }
    private var hostName: String {
        if !model.serverName.isEmpty { return model.serverName }
        return model.settings.host?.name ?? "아직 연결된 PC가 없어요"
    }
    private var hostState: String {
        if model.streaming { return "화면 연결 중" }
        if model.busy { return "PC 확인 중" }
        if model.errorMessage != nil { return "연결 확인 필요" }
        if model.paired { return "페어링됨" }
        return model.settings.host == nil ? "\(model.platformName) 화면에서 PC를 선택하세요" : "저장된 PC · 확인 필요"
    }
}
