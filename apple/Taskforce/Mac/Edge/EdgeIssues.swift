#if os(macOS)
import Foundation
import Observation
import TaskforceKit
import TaskforceUI

/// 새 Issues 화면(OA U2, `EdgeSurfaces.issueScreens`)이 읽는 상태: 세션 · 이슈 번호 · 이슈 상세. 셋 다 서버에서 RLS로 읽기만 한다 (쓰기 없음).
/// 게이트가 꺼져 있으면 이 객체가 없다 (`ChatRuntime.issues == nil`): 읽기도 타이머도 0이고 All work는 지금 그대로다
@MainActor
final class IssueRuntime {
    let sessions: AgentSessionStore
    let numbers: IssueNumberStore
    let details: IssueDetailStore

    init(gateway: any IssueScreensGateway, scope: AccountScope, now: @escaping @Sendable () -> Date = { Date() }) {
        sessions = AgentSessionStore(gateway: gateway, scope: scope, now: now)
        numbers = IssueNumberStore(gateway: gateway, scope: scope)
        details = IssueDetailStore(gateway: gateway, scope: scope)
    }

    /// 연결 경로: 온라인으로 돌아오면 세션을 다시 읽는다
    func pathChanged(online: Bool) {
        sessions.pathChanged(online: online)
        details.pathChanged(online: online)
    }
}

/// New session `+`(레일 · 탭)가 어디서 눌렸나
enum NewSessionSource: Equatable {
    case rail
    case tab
}
#endif
