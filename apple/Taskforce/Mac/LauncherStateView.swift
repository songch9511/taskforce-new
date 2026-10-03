#if os(macOS)
import SwiftUI
import TaskforceKit
import TaskforceUI

/// 본문 카드 가운데 상태 (`EmptyState`, 동작은 액션 바): M20 오프라인 + 저장본 없음 · 새로고침 실패 + 저장본 없음 ·
/// M21 할 일 없음(확인한 연결 · 시각은 U4) · 첫 동기화 · 처음 불러오는 중 · 설정 오류.
struct LauncherStateView: View {
    let state: LauncherModel.Body

    var body: some View {
        switch state {
        case .offlineEmpty:
            EmptyState(systemImage: "wifi.slash", title: Self.nothingSaved, message: Self.connectsOnce)
        case .failedEmpty:
            EmptyState(systemImage: "exclamationmark.triangle", title: Self.nothingSaved, message: Self.connectsOnce)
        case .empty:
            EmptyState(systemImage: nil, title: "No tasks yet", message: "Tasks you take on will appear here.")
        case .syncing:
            EmptyState(systemImage: "arrow.triangle.2.circlepath", title: ConnectionSync.label)
        case .message(let text):
            EmptyState(systemImage: "wrench.and.screwdriver", title: "Setup needed", message: text)
        case .loading, .list, .single:
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityLabel("Loading")
        }
    }

    /// Figma M20 문구
    static let nothingSaved = "Nothing saved on this Mac yet"
    static let connectsOnce = "Tasks appear after Taskforce connects once."
}
#endif
