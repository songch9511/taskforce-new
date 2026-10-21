import Foundation

/// Settings › Your agents의 모든 UI 문구 한 곳 (OA Settings › Your agents 12장 · 19장, 2026-10-18 사용자 승인).
/// 새 문구는 DZ 그림(`handoffs/oa-settings-dz`)의 승인된 글 그대로이고, DS 문구는 DS 미리보기 그대로다. 한 글자도 바꾸지 않는다 — 시험이 글자 하나하나를 고정한다.
/// 서버가 판정하는 상태 말(Not connected의 연결 없음 · Not signed in · Offline · Unsupported · Read only)은 대상 목록에서만 온다: 이 파일은 그 말을 **보이는 글자**로만 둔다.
public enum AgentSettingsCopy {
    // MARK: DS (승인됨)

    public static let sectionTitle = "Your agents"
    public static let agentName = "Claude Code"
    public static let checking = "Checking…"
    public static let signedInSessionActive = "Signed in · Session active"
    public static let signedInNoSession = "Signed in · No active session"
    public static let signedIn = "Signed in"
    public static let notSignedIn = "Not signed in"
    public static let notConnected = "Not connected"
    /// 줄 뒤에 붙는 서버 판정 말 (` · Unsupported` · ` · Read only`)
    public static let unsupported = "Unsupported"
    public static let readOnly = "Read only"
    public static let canWrite = "Can write"
    public static let offline = "Offline"
    public static let cantRunInThisBuild = "Can't run agents in this build"
    public static let connect = "Connect"
    public static let reconnect = "Reconnect"
    public static let disconnect = "Disconnect"

    public static let status = "Status"
    public static let signIn = "Sign-in"
    public static let session = "Session"
    public static let none = "None"
    public static let access = "Access"
    public static let level = "Level"
    public static let openNow = "Open now"
    public static let signInHelp = "Sign in from Terminal by running claude, then come back. Taskforce never asks for your login."

    public static func activeSince(_ time: String) -> String { "Active since \(time)" }

    // MARK: 새 문구 (승인됨)

    public static let notInstalled = "Not installed"
    public static let installHelp = "Install Claude Code on this Mac, then come back."
    public static let version = "Version"
    public static let thisMac = "This Mac"
    public static let managedSettings = "Claude Code on this Mac uses settings managed by your organization."
    public static let unsupportedVersion = "This version of Claude Code isn't supported yet. Update it, then come back."
    public static let connectIntro = "Connecting lets Taskforce start Claude Code on this Mac for work you send it. It runs on your Claude plan."
    public static let accessFootnote = "Open now is what Taskforce can let Claude Code do at this moment."

    public static let tooManyMacs = "Too many Macs"
    public static let tenMacsNotice = "This account has 10 Macs connected"
    public static let showMacs = "Show Macs"
    public static let macsTitle = "Macs"
    public static let unnamedMac = "Mac"
    public static let removeMacAction = "Remove…"
    public static let remove = "Remove"
    public static let removeMacDetail = "Its agent sessions stop. Conversations stay."

    public static func lastSeen(_ relative: String) -> String { "Last seen \(relative)" }
    public static func removeMacTitle(_ name: String) -> String { "Remove \(name)?" }

    public static let folders = "Folders"
    public static let ungrouped = "Ungrouped"
    public static let askEachTime = "Ask each time"
    public static let change = "Change…"
    public static let removeFolderAction = "Remove…"
    public static let missing = "Missing"
    public static let removeFolderTitle = "Remove this folder?"
    public static func removeFolderDetail(project: String) -> String { "The next new session in \(project) asks again." }
    public static let foldersFootnote =
        "Claude Code works only in the folder you choose for each project. Sessions already started keep their folder. Your own Claude Code settings aren't applied. macOS may ask whether Taskforce Agent, the helper that runs Claude Code, can open these folders."

    public static let disconnectRow = "Disconnect this Mac"
    public static let disconnectAction = "Disconnect…"
    public static let disconnectTitle = "Disconnect this Mac?"
    public static let disconnectDetail = "Claude Code sessions on this Mac stop. Their conversations and your folders stay."

    /// macOS 폴더 권한 창에 뜨는 목적 글 (`apple/project.yml` TaskforceAgent 타깃의 다섯 키가 같은 문장): 시험이 한 글자까지 맞춰 본다
    public static let agentPurpose = "Taskforce Agent runs Claude Code in the folders you choose for your projects."

    // MARK: 있는 문장 재사용

    /// Settings의 서버 기능 비활성 문구 (`SettingsRunWithAISection.availability`)
    public static let notAvailable = "Not available"

    /// 실패 줄 (조용한 회색 힌트 톤, 빨강 아님): 기존 문장 · DS 문장
    public static let somethingWentWrong = AgentQuestionFailure.genericReason
    public static let youAreOffline = AgentQuestionFailure.offlineReason
}
