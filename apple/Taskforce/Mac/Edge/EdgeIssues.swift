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
    /// Taskforce 대화의 요청 (OA U3): `GET /api/v2/review`와 경로 충돌 해소. 게이트(`EdgeSurfaces.taskforceConversation`)가 꺼진 구성에서는 읽지도 부르지도 않는다 —
    /// 셸이 `taskforceEnabled`일 때만 읽기를 시작한다 (이 객체는 이슈 게이트가 켜지면 만들어지지만 아무것도 하지 않는다)
    let taskforce: TaskforceRequestStore
    /// 다시 켠 뒤 표시만 남은 끝난 이슈를 id로 읽는다 (같은 RLS 읽기, 상세 화면의 캐시와 섞지 않는다): 끝난 링을 제목과 함께 되살린다
    let finished: FinishedIssueLookup

    init(gateway: any IssueScreensGateway, scope: AccountScope, now: @escaping @Sendable () -> Date = { Date() }) {
        sessions = AgentSessionStore(gateway: gateway, scope: scope, now: now)
        numbers = IssueNumberStore(gateway: gateway, scope: scope)
        details = IssueDetailStore(gateway: gateway, scope: scope)
        taskforce = TaskforceRequestStore(gateway: gateway, scope: scope)
        finished = FinishedIssueLookup(gateway: gateway, scope: scope)
    }

    /// 연결 경로: 온라인으로 돌아오면 세션을 다시 읽는다
    func pathChanged(online: Bool) {
        sessions.pathChanged(online: online)
        details.pathChanged(online: online)
        taskforce.pathChanged(online: online)
    }
}

/// New session `+`(레일)가 어디서 눌렸나
enum NewSessionSource: Equatable {
    case rail
}
#endif
