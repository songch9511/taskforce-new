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

    #if DEBUG
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
    #endif

    /// 이 빌드의 표면: Release는 `release`, Debug는 launch argument
    static var current: EdgeSurfaces {
        #if DEBUG
        return debug()
        #else
        return release
        #endif
    }

    #if DEBUG
    /// 인자 영역(`-KEY YES`)만: 저장된 defaults로는 켜지지 않는다
    private static func bool(_ key: String, _ defaults: UserDefaults?) -> Bool {
        if let defaults { return defaults.bool(forKey: key) }
        let arguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        guard let value = arguments[key] else { return false }
        return (value as? Bool) ?? (value as? String).map { NSString(string: $0).boolValue } ?? false
    }
    #endif
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

// --- U1 ---
extension EdgeSurfaces {
    /// Assistant 창 (OA U1): 떠 있는 창 · 레일 Chats(⌘3) · ⌘N이 패널의 Chats 화면 대신 창을 연다. **Debug는 셸이 켜지면 켜지고 Release는 늘 꺼짐**이다
    /// (`release.chats == false`라 Release에는 Chats도 창도 없다). 별도 저장 값이 아니라 셸 · Chats에서 나오므로 두 표면과 어긋나지 않는다
    var assistantWindows: Bool { shell && chats }

    /// 이 실행에서 Assistant 창을 쓰는가 (`EdgeShellController`의 기본값): 표면 값 그대로다.
    /// Debug에서 `-TFPanelChats YES`를 주면 창 대신 옛 패널의 Chats(B3)로 연다 — 패널 Chats 화면을 확인하는 옛 합성 조작 · 견본 하네스(`EdgeInteraction` · `EdgeSnapshot`의 Chats 상태)를 위한 인자다
    static var assistantWindowsForThisRun: Bool {
        #if DEBUG
        let arguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        if let value = arguments["TFPanelChats"], (value as? Bool) ?? (value as? String).map({ NSString(string: $0).boolValue }) ?? false { return false }
        #endif
        return current.assistantWindows
    }
}

// --- U2 ---
extension EdgeSurfaces {
    /// 새 Issues 화면 (OA U2): 레일 첫 칸 Projects(⌘2) → Projects → 이슈 목록 → 이슈 상세, 세션 패널 · Ask 알약 · New session `+` · 링 = 이슈(세션 반영).
    /// 셋(셸 · Chats · 프로젝트 묶음)이 모두 켜져 있고 `issueScreens` 값이 켜졌을 때만 켜진다: 멤버십 런타임과 `+`의 Assistant 창이 Chats 런타임에 산다.
    /// **꺼지면 지금 동작 전부 그대로다** (All work · 검색 · 필터 · 핀 · 레일 높이 · 세션 읽기 0). `EdgeSurfaces.release`는 이 값을 켜지 못한다 (`allowsIssueScreens`가 false)
    func allowsIssueScreens(flag: Bool) -> Bool {
        flag && shell && chats && projects
    }

    static let issueScreensKey = "TF_U2"

    /// 이 실행의 게이트. Debug = `-TF_U2 YES`(인자 영역만, 저장된 defaults로는 켜지지 않는다) + `shell && chats && projects`.
    /// `-TF_RELEASE_SURFACES YES`면 Release 표면(`projects == false`)이라 꺼진다. Release 빌드는 늘 false다 (출시 때 켜는 것은 L5 결정)
    static func issueScreens(_ defaults: UserDefaults? = nil) -> Bool {
        #if DEBUG
        return debug(defaults).allowsIssueScreens(flag: bool(issueScreensKey, defaults))
        #else
        return false
        #endif
    }

    /// 앱이 실제로 쓰는 값 (`ChatRuntime`의 기본값)
    static var issueScreensForThisRun: Bool { issueScreens() }
}

// --- U3 ---
extension EdgeSurfaces {
    /// Taskforce 대화 (OA U3): 레일 첫 캡슐의 bell · Review 패널을 대신하는 Taskforce 대화 · v2 Review 읽기 · 충돌 해소 · 대화 끝의 복귀 요약 · ⌘1 / ⌥Space가 가장 오래된 요청.
    /// 새 Issues 화면(U2) + Review(S4) + 복귀 요약(C3)이 **모두** 켜졌을 때만 켜진다. 하나라도 꺼지면 꺼진다.
    /// 새 플래그는 없다 (U3-05). **Release는 늘 false다** — `issueScreens`가 Release에서 늘 꺼져 있다 (`allowsIssueScreens`). 출시 때 켜는 것은 L5 결정이다
    func allowsTaskforceConversation(issueScreens: Bool) -> Bool {
        issueScreens && review && summary
    }

    /// 이 실행의 게이트. Debug = `-TF_EDGE_SHELL YES -TF_S3B YES -TF_U2 YES -TF_S4 YES -TF_C3 YES` (인자 영역만, 저장된 defaults로는 켜지지 않는다). Release 빌드는 늘 false
    static func taskforceConversation(_ defaults: UserDefaults? = nil) -> Bool {
        #if DEBUG
        return debug(defaults).allowsTaskforceConversation(issueScreens: issueScreens(defaults))
        #else
        return false
        #endif
    }

    /// 앱이 실제로 쓰는 값
    static var taskforceConversationForThisRun: Bool { taskforceConversation() }
}
#endif

