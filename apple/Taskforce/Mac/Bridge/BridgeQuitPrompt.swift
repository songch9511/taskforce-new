#if os(macOS)
import AppKit

/// 종료 확인 (OA D2b 계약 2.9 · ONE-TF-15 a · Q8). 시험은 이 약속(`BridgeQuitPrompting`)을 대신 넣는다.
@MainActor
protocol BridgeQuitPrompting {
    /// 사용자가 Quit을 골랐으면 true, Cancel이면 false
    func confirmQuit() async -> Bool
}

/// 표준 `NSAlert`. 문구는 사용자가 승인했다 (2026-10-14): 제목 "Quit Taskforce?", 본문 "Running agent turns will stop.", 버튼 "Quit" · "Cancel".
/// 시스템 창이라 디자인 시스템 부품이 없고 UI 문구 규칙(짧은 관례 문구)에 맞다
@MainActor
struct BridgeQuitAlert: BridgeQuitPrompting {
    static let title = "Quit Taskforce?"
    static let message = "Running agent turns will stop."
    static let quitButton = "Quit"
    static let cancelButton = "Cancel"

    /// 창을 만들기만 한다 (시험이 문구를 본다)
    static func makeAlert() -> NSAlert {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: quitButton)
        alert.addButton(withTitle: cancelButton)
        return alert
    }

    func confirmQuit() async -> Bool {
        // 에이전트 앱(Dock 없음)이라 먼저 앞으로 나와야 창이 다른 앱 뒤에 숨지 않는다
        NSApplication.shared.activate()
        return Self.makeAlert().runModal() == .alertFirstButtonReturn
    }
}
#endif
