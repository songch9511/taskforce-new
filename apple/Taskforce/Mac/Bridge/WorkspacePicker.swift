#if os(macOS)
import AppKit
import Foundation
import TaskforceKit

/// 작업 폴더를 고르는 시스템 폴더 창 (OA D4a2-05): 폴더만, 한 개. 메시지 · 버튼 · 거절 문구는 사용자가 승인한 글이다 (`AgentWorkspaceCopy`).
/// 받아 줄 수 없는 폴더(홈 자체 · `~/Library` · 시스템 폴더 · 앱 데이터 · 남의 폴더 …)를 고르면 **창 안에서** 거절 문구를 보이고 창을 닫지 않는다.
/// 시험은 이 창을 열지 않는다 — `ChatRuntime.workspacePicker`를 가짜로 바꾼다.
@MainActor
final class WorkspacePicker: AgentWorkspacePicking {
    func pickFolder(message: String, prompt: String, rejection: String, accepts: @escaping @Sendable (String) -> Bool) async -> String? {
        await pickFolder(message: message, prompt: prompt, rejection: rejection, accepts: accepts, reason: { _ in rejection })
    }

    /// 겹치는 폴더 · 민감 폴더는 일반 거절 문장 대신 자기 문장을 창 안에 보인다 (`reason`)
    func pickFolder(
        message: String, prompt: String, rejection: String, accepts: @escaping @Sendable (String) -> Bool, reason: @escaping @Sendable (String) -> String
    ) async -> String? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.resolvesAliases = true
        panel.message = message
        panel.prompt = prompt
        let validator = FolderValidator(accepts: accepts, reason: reason)
        panel.delegate = validator
        // 메뉴 막대 앱 · 떠 있는 Assistant 창 위에서 열린다
        NSApp.activate()
        panel.level = .modalPanel
        let response = panel.runModal()
        withExtendedLifetime(validator) {}
        guard response == .OK, let url = panel.url else { return nil }
        return url.path
    }
}

/// 폴더 창 안 검증: 거절이면 `NSError`를 던져 창이 그 폴더의 거절 문구를 보이게 한다
private final class FolderValidator: NSObject, NSOpenSavePanelDelegate, @unchecked Sendable {
    let accepts: @Sendable (String) -> Bool
    let reason: @Sendable (String) -> String

    init(accepts: @escaping @Sendable (String) -> Bool, reason: @escaping @Sendable (String) -> String) {
        self.accepts = accepts
        self.reason = reason
    }

    func panel(_ sender: Any, validate url: URL) throws {
        guard accepts(url.path) else {
            throw NSError(domain: "dev.taskforcelabs.workspace-picker", code: 1, userInfo: [NSLocalizedDescriptionKey: reason(url.path)])
        }
    }
}
#endif
