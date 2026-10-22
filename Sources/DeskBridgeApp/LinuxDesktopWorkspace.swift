// SPDX-License-Identifier: GPL-3.0-only
import Combine
import DeskBridgeCore
import Foundation
import SwiftUI

/// Immutable role context. Existing Windows settings and certificate pins are never migrated.
@MainActor final class LinuxDesktopWorkspace: ObservableObject {
    let desktop: DesktopModel
    let files: FilesModel
    init(storageDirectory: URL? = nil, identitySuite: String? = nil) {
        desktop = DesktopModel(storageDirectory: storageDirectory, identitySuite: identitySuite, platform: .linux)
        files = FilesModel(desktop: desktop)
    }
}
struct LinuxDesktopSurface: View {
    @ObservedObject var model: DesktopModel
    let files: FilesModel
    @State private var guide = false
    var body: some View {
        DesktopPage { guide = true }
            .environmentObject(model).environmentObject(files)
            .sheet(item: $model.pendingInvitation) { invitation in
                ConnectionInvitationSheet(model: model, invitation: invitation).environmentObject(files)
            }
            .sheet(isPresented: $guide) {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Linux에서 먼저 공유를 켜세요").font(.title2.bold())
                    Text("Ubuntu 24.04 LTS amd64의 로그인한 X11 데스크톱을 지원합니다. Linux용 Knot .deb를 설치하고 앱에서 공식 Sunshine 설치 → 이 Linux 공유 시작 → 처음 웹 설정 → 연결 QR 순서로 진행하세요.")
                    Text("Wayland·로그인 화면·헤드리스·Linux 파일 전송은 아직 지원하지 않습니다. QR은 주소 안내이며 PIN 페어링이 따로 필요합니다.").foregroundStyle(.secondary)
                    Button("닫기") { guide = false }
                }.padding(28).frame(width: 520)
            }
    }
}
