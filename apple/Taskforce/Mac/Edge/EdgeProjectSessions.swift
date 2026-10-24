#if os(macOS)
import AppKit
import SwiftUI
import TaskforceKit
import TaskforceUI

// 프로젝트 이슈 목록 맨 위의 Sessions 묶음 (에이전트 트리 T3m): 그 프로젝트의 열린 이슈 · 오늘 끝난 이슈에 묶인 세션의 합집합을 `SessionRow`로 보이고,
// 행을 누르면 세션 패널의 카드 트리로 들어간다. 자식이 없는 세션은 원래 대화로 들어간다.
// 새 문구는 묶음 머리 "Sessions"(이슈 상세와 같은 낱말) 하나뿐이다. 세션이 없으면 묶음이 없다 (빈 칸 · 안내 문구 없음).
// 즉시 쌓기 `VStack`이다 (21-7: 게으른 쌓기로 바꾸지 않는다). 그리는 동안은 기록 파일을 읽지 않는다 — 읽기는 사용자가 행을 펼칠 때 `ProjectSessionsModel`이 한다.

/// 실제 앱의 기록 읽기 면: 이 Mac의 `~/.claude` 기록을 읽기만 한다 (`ClaudeAppTranscriptReader`). 글 · 경로를 로그에 남기지 않는다
enum ProjectSessionsLive {
    static func source() -> any ClaudeAppTranscriptSource {
        ClaudeAppTranscriptReader(claudeDirectory: NSHomeDirectory() + "/.claude", log: BridgeOSLog())
    }
}

struct ProjectSessionsGroup: View {
    @Bindable var shell: EdgeShellModel
    let project: UUID
    /// 그 프로젝트 이슈 목록의 세션 (`EdgeShellModel.projectSessionItems`): 이슈 목록이 정해 건넨다
    let sessions: [AgentSessionItem]

    var body: some View {
        let model = shell.projectSessions
        if !sessions.isEmpty {
            // 이슈 목록은 한 번만 만든다 (세션마다 만들지 않는다): 다른 프로젝트와의 공유를 가리는 데 쓴다
            let work = shell.workItems
            VStack(alignment: .leading, spacing: 0) {
                GroupLabel("Sessions")
                // 행 사이 2 (이슈 행과 같다)
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(sessions) { session in
                        ProjectSessionBlock(shell: shell, session: session, project: project, work: work)
                    }
                }
            }
            // 판의 변화(접힌 행의 "Running n")를 따라간다: 이 묶음이 보이는 동안만 1초마다 판의 버전을 본다 (바뀌었을 때만 다시 그린다)
            .task {
                while !Task.isCancelled {
                    model.syncBoard()
                    try? await Task.sleep(for: .seconds(1))
                }
            }
            // 묶음이 행 1개 이상으로 보였다 (하루 한 번, 종류만)
            .task(id: sessions.count) { model.noteGroupShown(rows: sessions.count) }
        }
    }
}

/// 프로젝트 목록의 부모 세션 행. 자식 탐색은 세션 패널의 카드 트리에서 한다.
struct ProjectSessionBlock: View {
    @Bindable var shell: EdgeShellModel
    let session: AgentSessionItem
    let project: UUID
    let work: [WorkItem]

    var body: some View {
        let model = shell.projectSessions
        let _ = model.boardVersion
        SessionRow(
            session, current: shell.sessionPanelID == session.id,
            shared: shell.sharedProjectNames(of: session, besides: project, in: work), summary: model.collapsedSummary(of: session),
            onOpen: { shell.openSession(session.id) },
            onAsk: { shell.onAsk(AssistantOpenItem(kind: .agentSession, id: session.id, title: session.name)) }
        )
    }
}

#endif
