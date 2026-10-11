#if os(macOS)
import Foundation
import Observation
import TaskforceKit

/// Review(S4)에서 사용자가 고른 답을 보내고, 그 결과를 정직하게 들고 있는 곳. **이 객체를 만들었는지가 S4 gate다** (`S4Flag`, 기본 꺼짐):
/// 꺼져 있으면 `EdgeShellModel.review == nil`이라 Review 페이지 · ⌘1 · ← → · 1 · 2 연결이 만들어지지 않고 지금(S3b/B3/Edge) 그대로다.
///
/// - 답은 사용자가 고른 것(클릭 · 1/2 키)만 보낸다. 열기 · 탐색 · 읽기 · 닫기는 어떤 답도 아니다.
/// - 항목당 요청 하나: 이미 보내는 항목에는 보내지 않는다 (반복 키 · 중복 클릭 → 1회). `NowStore.answerReview`가 같은 규칙을 한 번 더 지킨다.
/// - 성공은 서버가 받았다는 응답뿐이다. 실패 · 409 · 응답 유실은 자동으로 다시 보내지 않고 `/now`를 다시 읽어 지금 상태를 보이며, 안내를 남긴다.
///   목록에서 항목이 사라졌다는 사실은 내 요청의 성공 증거가 아니다 (그래서 안내는 항목이 사라져도 남는다).
/// - 계정 경계: 쓰기를 시작할 때 `AccountScope` token을 잡고, 응답 뒤 · 후속 읽기 뒤에 다시 본다. 같은 UUID 재로그인 · 다른 계정 · 로그아웃이면 옛 요청의 결과는
///   새 세션의 진행 표시 · 안내를 건드리지 못한다 (항목마다 쓰기 번호, B3 `MemoryStore` · S3b `WorkContextStore`와 같은 방식).
@MainActor
@Observable
final class ReviewDesk {
    /// 가장 최근 안내 한 줄. 어느 항목에 대한 것인지 들고 있어, 그 항목이 큐에서 사라졌어도 말할 수 있다
    struct Notice: Equatable {
        let id: UUID
        let text: String
    }

    /// 보내는 중인 답 (항목마다 하나)
    private(set) var sending: [UUID: ReviewAnswer] = [:]
    private(set) var notice: Notice?

    @ObservationIgnored let now: NowStore
    @ObservationIgnored private let scope: AccountScope
    @ObservationIgnored private var owners: [UUID: Int] = [:]
    @ObservationIgnored private var counter = 0
    /// 근거를 읽은 때의 그 항목 `last_activity_at`: 달라졌으면(근거가 더해졌을 수 있다) 다시 읽는다
    @ObservationIgnored private var evidenceStamp: [UUID: Date] = [:]
    /// 읽는 중인 근거 읽기: 화면의 `.task`가 취소돼도(다른 결정으로 옮김) 읽기는 끝까지 가서 "읽는 중"으로 멈춰 서지 않게 한다
    @ObservationIgnored private var evidenceReads: [UUID: Task<Void, Never>] = [:]

    init(now: NowStore, scope: AccountScope) {
        self.now = now
        self.scope = scope
        scope.onLeft { [weak self] in self?.reset() }
    }

    /// 계정이 떠남: 진행 표시 · 안내 · 읽은 기록을 비운다 (옛 요청의 늦은 결과는 token · 쓰기 번호가 버린다)
    func reset() {
        sending = [:]
        notice = nil
        owners = [:]
        evidenceStamp = [:]
        evidenceReads = [:]
    }

    func isSending(_ id: UUID) -> Bool { sending[id] != nil }

    func clearNotice() { notice = nil }

    /// 고른 답 하나를 보낸다. 보내지 않았으면 `.ignored`
    @discardableResult
    func answer(_ answer: ReviewAnswer, for id: UUID) async -> ReviewWriteResult {
        guard let token = scope.token, sending[id] == nil else { return .ignored }
        counter += 1
        let owner = counter
        owners[id] = owner
        sending[id] = answer
        notice = nil
        // 세션이 바뀌면 `reset()`이 진행 표시를 비우고 새 세션이 같은 항목에 새 요청을 잡을 수 있다: 이 요청이 잡은 것일 때만 푼다
        defer {
            if owners[id] == owner {
                owners[id] = nil
                sending[id] = nil
            }
        }
        let result = await now.answerReview(id, answer)
        // 응답이 오는 사이(후속 `/now` 읽기 포함) 계정이 떠났거나 이 항목에 더 새 요청이 잡혔다면 어떤 결과도 반영하지 않는다
        guard scope.isCurrent(token), owners[id] == owner else { return .ignored }
        switch result {
        case .applied, .ignored:
            break
        case .rejected(let message):
            notice = Notice(id: id, text: message)
        case .unverified:
            notice = Notice(id: id, text: ReviewCopy.unverified)
        }
        return result
    }

    /// 이 항목의 근거를 읽어 둔다. 이미 읽었고 그 뒤 항목이 달라지지 않았으면 다시 읽지 않는다 (읽기일 뿐 해결이 아니다).
    /// 읽지 못하면 사용자가 Try again을 누를 때까지 다시 부르지 않는다 (`retrySource`)
    func loadSource(for action: ActionSummary) async {
        let id = action.id
        if evidenceStamp[id] == action.lastActivityAt {
            await evidenceReads[id]?.value
            return
        }
        evidenceStamp[id] = action.lastActivityAt
        let read = Task { [now] in _ = await now.loadEvidence(id, force: true) }
        evidenceReads[id] = read
        await read.value
        if evidenceReads[id] == read { evidenceReads[id] = nil }
    }

    /// Try again: 근거를 다시 읽는다
    func retrySource(for action: ActionSummary) async {
        evidenceStamp[action.id] = nil
        await loadSource(for: action)
    }

    func source(for id: UUID) -> ReviewSource {
        ReviewSource.of(digest: now.evidence[id], failed: now.evidenceFailed.contains(id))
    }
}
#endif
