#if os(macOS)
import Foundation

/// Edge 셸이 켜는 표면의 한 곳 (0.2.0). 어느 표면을 어느 빌드에서 켜는지를 이 값 하나가 정한다:
/// - **Release**(`release`): Edge 셸 + All work + S4 Review(confirm 요청에 Confirm · Dismiss, 기존 v1 경로) + C3 복귀 요약만. Chats(B3) · 프로젝트 묶음(S3b) · 기억 · 0.2.0 설정 창은 꺼져 있다
///   (Release 설정은 지금의 구 `MacSettingsView`: Plan & usage · billing이 그대로 있다). 새 대체 단축키 동작은 없다 — Edge가 켜지면 ⌥ Space는 Edge 패널을 연다 (확정된 디자인).
/// - **DEBUG**(`debug`): 격리 실행의 launch argument만 (저장된 defaults로는 켜지지 않는다). 지금 동작 그대로 — `-TF_EDGE_SHELL YES`는 셸 + Chats + 0.2.0 설정 창을 함께 켜고, `-TF_S4` · `-TF_C3` · `-TF_S3B`는 각자의 축이다.
///   `-TF_RELEASE_SURFACES YES`는 다른 인자와 상관없이 `release`와 같은 표면을 만든다: Release 표면을 서명 앱 없이 격리 QA로 보려는 인자다 (서명된 앱이 아니다).
/// 기존 플래그 enum(`EdgeShellFlag` · `S4Flag` · `C3Flag` · `S3bFlag`)은 시그니처 그대로 이 값을 읽는다. Release 쪽 분기(`#else`)는 이 한 줄뿐이라 Debug 시험 호스트에서는 `EdgeSurfaces.release` 값 시험 + Release 빌드로 확인한다.
struct EdgeSurfaces: Equatable {
    /// Edge 셸(레일 · 패널) 자체. 켜지면 ⌥ Space는 Edge 패널을 연다
    var shell: Bool
    /// S4 Review 페이지(Needs-you 링 · ⌘1 · ← → · 1 · 2)
    var review: Bool
    /// C3 ReturnSummary(All work 위 카드 + 첫 정상 표시 기준점)
    var summary: Bool
    /// Chats(B3): 런타임 · 레일 칸 · ⌘3 · ⌘N · 연결 복귀 시 읽기
    var chats: Bool
    /// 프로젝트 묶음(S3b): 범위 멤버십 읽기 · ProjectLink (Chats 런타임 안에 산다)
    var projects: Bool
    /// 0.2.0 탭 설정 창 (꺼져 있으면 구 설정 창)
    var settingsWindow: Bool

    /// Release에서 켜는 표면: 셸 + All work + S4 + C3만
    static let release = EdgeSurfaces(shell: true, review: true, summary: true, chats: false, projects: false, settingsWindow: false)

    static let releaseKey = "TF_RELEASE_SURFACES"

    /// 격리 Debug 실행의 표면. `defaults`가 있으면(시험) 그 suite만 읽는다
    static func debug(_ defaults: UserDefaults? = nil) -> EdgeSurfaces {
        if bool(releaseKey, defaults) { return .release }
        let shell = bool(EdgeShellFlag.key, defaults)
        return EdgeSurfaces(
            shell: shell, review: bool(S4Flag.key, defaults), summary: bool(C3Flag.key, defaults),
            // 지금처럼 Chats와 0.2.0 설정 창은 셸이 켜지면 함께 (이 PR은 DEBUG 동작을 바꾸지 않는다)
            chats: shell, projects: bool(S3bFlag.key, defaults), settingsWindow: shell
        )
    }

    /// 이 빌드의 표면: Release는 `release`, Debug는 launch argument
    static var current: EdgeSurfaces {
        #if DEBUG
        return debug()
        #else
        return release
        #endif
    }

    /// 인자 영역(`-KEY YES`)만: 저장된 defaults로는 켜지지 않는다
    private static func bool(_ key: String, _ defaults: UserDefaults?) -> Bool {
        if let defaults { return defaults.bool(forKey: key) }
        let arguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        guard let value = arguments[key] else { return false }
        return (value as? Bool) ?? (value as? String).map { NSString(string: $0).boolValue } ?? false
    }
}

/// 0.2.0 Chats(B3)를 켜는 플래그: 런타임(`ChatRuntime` · 서버 대화 v2 · 기억) · 레일 Chats 칸 · ⌘3 · ⌘N. **Release는 늘 꺼짐**(`EdgeSurfaces.release.chats`).
/// DEBUG는 지금처럼 셸 플래그를 따른다 (`-TF_EDGE_SHELL YES`가 Chats를 함께 켠다).
enum ChatsFlag {
    static func isEnabled(_ defaults: UserDefaults? = nil) -> Bool {
        #if DEBUG
        return EdgeSurfaces.debug(defaults).chats
        #else
        return EdgeSurfaces.release.chats
        #endif
    }
}

/// 0.2.0 탭 설정 창을 켜는 플래그. **Release는 늘 꺼짐**(구 `MacSettingsView` 유지: Plan & usage · billing). DEBUG는 지금처럼 셸 플래그를 따른다.
enum SettingsWindowFlag {
    static func isEnabled(_ defaults: UserDefaults? = nil) -> Bool {
        #if DEBUG
        return EdgeSurfaces.debug(defaults).settingsWindow
        #else
        return EdgeSurfaces.release.settingsWindow
        #endif
    }
}
#endif
