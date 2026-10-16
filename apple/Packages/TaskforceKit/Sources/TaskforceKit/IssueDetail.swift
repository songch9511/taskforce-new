import Foundation
import Observation

// OA U2: 이슈 상세 읽기 (M4). 속성(Status · Due · Project)과 Sessions는 이미 읽은 목록 · 세션 저장소에서 오고,
// 이 읽기는 번호와 근거 인용(Source)만 더한다: `ActionDetail`(행 + 근거 + 원문 요약)을 RLS로 한 번.
// 인용은 원문 그대로다 (`EvidenceDigest`). 인용 글은 사용자 글이라 메모리에만 두고 로그 · 디스크에 남기지 않는다.

/// 이슈 상세가 서버를 읽는 면 (RLS select)
public protocol IssueDetailGateway: Sendable {
    func issueDetail(id: UUID) async throws -> ActionDetail
}

/// 상세에 더해지는 것: 번호와 근거
public struct IssueDetailContent: Sendable, Hashable {
    public let id: UUID
    public let number: Int?
    /// 근거 인용: 가장 새 것이 먼저 (원문 그대로, 실행 receipt는 뺀다). 직접 추가한 이슈는 비어 있다
    public let sources: [EvidenceLine]

    public init(id: UUID, number: Int?, sources: [EvidenceLine]) {
        self.id = id
        self.number = number
        self.sources = sources
    }

    init(_ detail: ActionDetail) {
        id = detail.action.id
        number = detail.action.number
        sources = Array(EvidenceDigest(evidence: detail.evidence, sources: detail.sources).withoutReceipts.lines.reversed())
    }

    /// Source 그룹을 그리나: 근거가 있을 때만 (직접 추가는 사용자 Claim이 근거라 그룹이 없다)
    public var hasSource: Bool { !sources.isEmpty }
    /// 맨 위에 보이는 인용 하나 (가장 새 것)
    public var leadSource: EvidenceLine? { sources.first }
    /// "Show all"이 보이나: 인용이 둘 이상일 때
    public var canShowAll: Bool { sources.count > 1 }
}

/// 상세 본문에 무엇을 보일지
public enum IssueDetailScreen: Sendable, Hashable {
    /// 읽는 중: 아무 주장도 하지 않는다 (속성 · Sessions는 이미 있는 값으로 그린다)
    case blank
    case offline
    case failed
    case ready(IssueDetailContent)
    /// 서버에 그 이슈가 없다 (지워짐 · 남의 것): 열어 둔 상세는 목록으로 돌아간다
    case gone
}

/// 이슈 상세 저장소. 이슈마다 한 번 읽고 메모리에 둔다 (계정이 떠나면 비운다). 읽은 뒤의 실패는 받은 것을 지우지 않는다
@MainActor
@Observable
public final class IssueDetailStore {
    private struct Entry {
        var content: IssueDetailContent?
        var failure: ReadFailure?
        var gone = false
    }

    private var entries: [UUID: Entry] = [:]
    public private(set) var isOnline = true
    @ObservationIgnored private let gateway: any IssueDetailGateway
    @ObservationIgnored private let scope: AccountScope
    @ObservationIgnored private var sequences: [UUID: Int] = [:]

    public init(gateway: any IssueDetailGateway, scope: AccountScope) {
        self.gateway = gateway
        self.scope = scope
        scope.onLeft { [weak self] in self?.reset() }
    }

    public func reset() {
        entries = [:]
        for id in sequences.keys { sequences[id, default: 0] += 1 }
    }

    public func pathChanged(online: Bool) { isOnline = online }

    public func screen(for id: UUID) -> IssueDetailScreen {
        guard let entry = entries[id] else { return .blank }
        if let content = entry.content { return .ready(content) }
        if entry.gone { return .gone }
        switch entry.failure {
        case .offline?: return .offline
        case .failed?: return .failed
        case .unavailable?, nil: return .blank
        }
    }

    /// 상세를 열 때 · Try again: 다시 읽는다. 받은 것이 있으면 실패해도 그대로 둔다. 마지막에 시작한 읽기만 반영한다
    public func load(_ id: UUID) async {
        guard let token = scope.token else { return }
        sequences[id, default: 0] += 1
        let sequence = sequences[id] ?? 0
        if entries[id] == nil { entries[id] = Entry() }
        do {
            let detail = try await gateway.issueDetail(id: id)
            guard scope.isCurrent(token), sequence == sequences[id] else { return }
            entries[id] = Entry(content: IssueDetailContent(detail), failure: nil)
        } catch {
            guard scope.isCurrent(token), sequence == sequences[id] else { return }
            if let api = error as? APIError, case .server(_, .notFound, _) = api {
                entries[id] = Entry(content: nil, failure: nil, gone: true)
            } else if let failure = ReadFailure.from(error, online: isOnline) {
                entries[id]?.failure = failure
            }
        }
    }
}
