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
/// - 계정 경계: 선택을 **받는 동기 경계**(`begin`)에서 `AccountScope` token · 항목 · 쓰기 번호를 잡고, **보내기 직전**(`send`)과 응답 뒤 · 후속 읽기 뒤에 다시 본다.
///   받은 뒤 예약된 작업이 시작하기 전에 같은 UUID 재로그인 · 다른 계정 · 로그아웃이 있었거나 화면이 달라졌으면 쓰기 0이고, 옛 요청의 결과는
///   새 세션의 진행 표시 · 안내를 건드리지 못한다 (항목마다 쓰기 번호, B3 `MemoryStore` · S3b `WorkContextStore`와 같은 방식).
///   이미 서버로 나간 요청은 취소하지 않는다: 같은 epoch의 토큰 갱신 · 화면 이동에도 정직한 결과를 돌려준다
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
    /// 근거를 마지막으로 확인한 때: 항목의 `last_activity_at`(근거가 더해졌을 수 있다)과 Review 페이지에 들어온 차례(`presentation`).
    /// 원문만 지워지거나 접근이 바뀌는 일은 항목의 활동 시각을 바꾸지 않는다 (예: Slack 연결 끊기 `purge_slack_sources`): 활동 시각만 믿으면
    /// 다시 열어도 옛 인용이 그대로 보인다. 그래서 확인은 활동 시각과 따로 **페이지에 다시 들어올 때마다** 한다 (폴링 없음, 서버 계약 변경 없음)
    private struct Freshness: Hashable {
        let activity: Date
        let presentation: Int
    }

    @ObservationIgnored private var evidenceStamp: [UUID: Freshness] = [:]
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

    /// 사용자가 고른 답 하나를 **받은 순간**(클릭 · 키, 동기 경계)에 잡아 둔 것: 그때의 계정 token · 항목 · 쓰기 번호.
    /// 예약된 작업이 나중에 시작해도 그동안 계정이 바뀌었거나 화면이 달라졌다면 옛 선택은 새 상태로 나가지 않는다 (`send`가 보내기 직전에 다시 본다)
    struct Ticket {
        let id: UUID
        let answer: ReviewAnswer
        fileprivate let token: AccountScope.Token
        fileprivate let owner: Int
    }

    /// 선택을 받는 동기 경계: 계정 token을 잡고 이 항목을 "보내는 중"으로 올린다. 이미 보내는 항목이거나 로그인 세션이 없으면 nil (반복 키 · 중복 클릭은 여기서 한 번만 통과)
    func begin(_ answer: ReviewAnswer, for id: UUID) -> Ticket? {
        guard let token = scope.token, sending[id] == nil else { return nil }
        counter += 1
        let owner = counter
        owners[id] = owner
        sending[id] = answer
        notice = nil
        return Ticket(id: id, answer: answer, token: token, owner: owner)
    }

    /// 받아 둔 선택을 보낸다. **보내기 직전에** 다시 본다: 계정 token이 그대로(같은 UUID 재로그인 · 다른 계정이면 달라진다, 같은 계정의 토큰 갱신은 그대로)이고,
    /// 이 선택의 쓰기 번호가 살아 있고(`reset()`이 비우면 죽는다), 호출한 쪽의 `isStillValid`(패널 · Review 화면 · 이 항목이 아직 보이는 결정인지)가 참일 때만 보낸다.
    /// 하나라도 어긋나면 쓰기 0 · `.ignored`다 (자기 번호일 때만 진행 표시를 거둔다). 이미 시작한 요청은 취소하지 않는다: 서버가 받았는지 모르는 요청을 버리지 않고 정직한 결과를 돌려준다
    @discardableResult
    func send(_ ticket: Ticket, isStillValid: () -> Bool) async -> ReviewWriteResult {
        let id = ticket.id
        // 세션이 바뀌면 `reset()`이 진행 표시를 비우고 새 세션이 같은 항목에 새 요청을 잡을 수 있다: 이 요청이 잡은 것일 때만 푼다
        defer {
            if owners[id] == ticket.owner {
                owners[id] = nil
                sending[id] = nil
            }
        }
        guard scope.isCurrent(ticket.token), owners[id] == ticket.owner, isStillValid() else { return .ignored }
        let result = await now.answerReview(id, ticket.answer)
        // 응답이 오는 사이(후속 `/now` 읽기 포함) 계정이 떠났거나 이 항목에 더 새 요청이 잡혔다면 어떤 결과도 반영하지 않는다
        guard scope.isCurrent(ticket.token), owners[id] == ticket.owner else { return .ignored }
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

    /// 이 항목의 근거를 확인한다 (읽기일 뿐 해결이 아니다). 같은 페이지 방문(`presentation`) 안에서 이미 확인했고 항목이 달라지지 않았으면 다시 읽지 않는다:
    /// 단계를 옮겼다 돌아와도 같은 방문이면 다시 읽지 않지만, 패널을 다시 열거나 Review로 다시 들어오면 다시 읽는다.
    /// 다시 확인하는 동안 · 확인하지 못했을 때 전에 읽은 근거는 지금 근거로 보이지 않는다 (`source(for:)`).
    /// 읽지 못하면 사용자가 Try again을 누르거나 다시 들어올 때까지 다시 부르지 않는다 (`retrySource`)
    func loadSource(for action: ActionSummary, presentation: Int) async {
        let id = action.id
        let freshness = Freshness(activity: action.lastActivityAt, presentation: presentation)
        if evidenceStamp[id] == freshness {
            await evidenceReads[id]?.value
            return
        }
        evidenceStamp[id] = freshness
        let read = Task { [now] in _ = await now.loadEvidence(id, force: true) }
        evidenceReads[id] = read
        await read.value
        if evidenceReads[id] == read { evidenceReads[id] = nil }
    }

    /// Try again: 근거를 다시 읽는다
    func retrySource(for action: ActionSummary, presentation: Int) async {
        evidenceStamp[action.id] = nil
        await loadSource(for: action, presentation: presentation)
    }

    /// 결정 아래 보일 원문. 다시 확인하는 중이면 전에 읽은 인용을 보이지 않고 "읽는 중"이다 (지금 근거가 아닐 수 있다), 확인하지 못했으면 실패다
    func source(for id: UUID) -> ReviewSource {
        if now.evidenceRefreshing.contains(id) { return .loading }
        return ReviewSource.of(digest: now.evidence[id], failed: now.evidenceFailed.contains(id))
    }
}
#endif
