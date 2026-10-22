import Foundation

/// 대화 머리의 작업 폴더 줄 (사용자 결정 2026-10-21): 폴더 이름과, 툴팁에 보이는 경로 (`~` = 홈, 길면 가운데를 줄인다 — Settings › Your agents의 Folders와 같은 규칙 `AgentSettingsPath`).
/// 보이는 글을 만들 뿐이다: 경로는 이 Mac의 등록부에만 있고 서버로 가지 않으며 로그에도 남지 않는다 (이 타입은 경로를 쥐지 않는다)
public struct AgentWorkspaceFolderLine: Equatable, Sendable {
    /// 머리에 보이는 폴더 이름 (줄이지 않는다: 보이는 폭이 모자랄 때 화면이 가운데를 줄인다). 홈 자체는 `~`
    public let name: String
    /// 전체 경로: 홈 아래는 `~`로 시작, `AgentSettingsPath.maxLength`를 넘으면 가운데를 `…`로 줄인다
    public let tooltip: String
    /// 폴더가 지금 있다 (사용자 승인 2026-10-22: 없으면 메뉴의 Show in Finder가 꺼진다. 이름 · 경로는 그대로 보인다, 오류 글 없음)
    public let exists: Bool

    /// - homes: 홈으로 줄여 보일 경로들 (홈 · 홈의 realpath)
    /// - exists: 폴더가 지금 있나 (파일 시스템은 부르는 쪽이 본다)
    /// 이름이 없는 경로(빈 글 · 뿌리 `/`)는 줄이 없다
    public init?(path: String, homes: [String], exists: Bool = true) {
        let components = path.split(separator: "/")
        guard let last = components.last else { return nil }
        self.exists = exists
        // 끝 `/` · 겹친 `/`는 비교에 끼지 않는다
        let shown = AgentSettingsPath.display("/" + components.joined(separator: "/"), homes: homes)
        name = shown == "~" ? "~" : String(last)
        tooltip = shown
    }
}
