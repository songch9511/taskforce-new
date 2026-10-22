#if os(macOS)
import Foundation

/// 표시만 남은 이슈를 id로 읽은 결과 (`FinishedIssueLookup`)
public enum FinishedIssueResult: Sendable, Equatable {
    /// 아직 끝난 이슈: 그 모습(제목 · 상태)으로 링을 그린다
    case finished(ActionSummary)
    /// 다시 열렸다: 끝남 표시는 쓸모없다
    case notFinished
    /// 서버에 없다 · 지워졌다 · 취소(dropped)했다: 끝남 표시를 버린다
    case gone
    /// 읽지 못했다 (오프라인 · 실패 · 그 사이 계정이 떠났다): 표시는 두고 나중에 다시 읽는다
    case unknown
}

/// 다시 켠 뒤 레일의 끝난 링을 되살리는 읽기 (OA PR-D2, 계약 23장: 끝난 링은 열어 볼 때까지 남는다).
/// 끝남 표시(`RailDoneMarks.issues`)는 id · 시각뿐이라(제목은 어디에도 저장하지 않는다) 오늘 끝난 일 목록에 없는 이슈는 제목을 모른다 — 그 이슈를 **기존 RLS 읽기**(`IssueDetailGateway.issueDetail`)로 id마다 읽어
/// 제목 · 상태를 얻는다. 읽은 모습은 메모리에서 링을 그리는 데만 쓰고 어디에도 쓰지 않는다 (이슈 상세 화면의 캐시와 섞지 않는다).
/// 읽는 사이 계정이 떠나면 그 결과를 쓰지 않는다 (`.unknown`)
@MainActor
public final class FinishedIssueLookup {
    private let gateway: any IssueDetailGateway
    private let scope: AccountScope

    public init(gateway: any IssueDetailGateway, scope: AccountScope) {
        self.gateway = gateway
        self.scope = scope
    }

    public func read(_ id: UUID) async -> FinishedIssueResult {
        guard let token = scope.token else { return .unknown }
        do {
            let record = try await gateway.issueDetail(id: id).action
            guard scope.isCurrent(token) else { return .unknown }
            switch record.status {
            case .done:
                return .finished(ActionSummary(
                    id: record.id, title: record.title, owner: record.owner, status: record.status, dueDate: record.dueDate, counterpart: record.counterpart,
                    needsConfirmation: record.needsConfirmation, confirmReasons: record.confirmReasons, startedAt: record.startedAt, lastActivityAt: record.lastActivityAt
                ))
            case .open: return .notFinished
            case .dropped: return .gone
            }
        } catch {
            guard scope.isCurrent(token) else { return .unknown }
            if let api = error as? APIError, case .server(_, .notFound, _) = api { return .gone }
            return .unknown
        }
    }
}
#endif
