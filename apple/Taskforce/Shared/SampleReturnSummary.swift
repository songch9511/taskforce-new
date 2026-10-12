#if DEBUG
import Foundation
import TaskforceKit

/// 디자인 비교 · 격리 확인용 가짜 서버 (Debug 빌드, `-TFSampleData`): 복귀 요약 읽기 · Clear · 첫 정상 표시 확정(기준점)을 서버 없이 시나리오대로 돌려준다.
/// **렌더 fixture일 뿐이다**: 실제 서버 · 계정 · AI 호출이 없고, 서버 계약(C3 `6cfd382` + A–D 후속 계약 `handoffs/c3-ad-contract.md`)을 흉내 낼 뿐 서버 구현이 아니다.
/// - `-TFSampleSummary <이름>`: 시작 시나리오 (기본 changes). `-TFSampleSummaryClear <이름>`: Clear를 보냈을 때의 서버 반응 (기본 apply).
///   `-TFSampleSummaryBaseline <이름>`: 첫 정상 표시 확정을 보냈을 때의 서버 반응 (기본 apply)
/// - 작업은 견본 목록(`SampleData`)의 것이다: 줄을 누르면 All work의 그 행이 열린다 (S4가 켜져 있으면 확인 요청은 Review로)
final class SampleReturnSummaryGateway: ReturnSummaryGateway, @unchecked Sendable {
    enum Scenario: String, CaseIterable {
        /// 변화 몇 줄 + Needs your answer + 실행 결과 + 오늘 끝낸 일 + 목록에 없는 취소된 작업
        case changes
        /// 많은 줄 · 긴 제목 · 한 작업의 여러 변화(마지막 발생 순 셋) (긴 내용을 주 화면에 담는다)
        case long
        /// 지운 원문 · 접근 상실 · 보관 만료 토큰
        case deletedSource
        /// 작업이 많아 앞부분만 (`sources.changes: truncated`, 커서는 보인 작업만 가리킨다): `More changes are available`, Clear 가능
        case truncated
        /// 앱이 말로 옮기지 못하는 변화(모르는 outcome · kind): 줄은 남고 `Some changes couldn't be shown`, Clear 차단
        case uninterpretable
        /// 변화 원천을 읽지 못했다 (커서 없음, 결정 줄만)
        case unavailable
        /// 결정 대기를 읽지 못했다 (안전한 변화의 Clear는 그대로)
        case decisionsUnavailable
        /// 읽기 자체가 실패
        case readFails
        /// 서버 gate 꺼짐 (404)
        case featureOff
        /// 완전하고 비어 있다
        case empty
        /// 질문만 남았다 (처음부터): 카드 캡션 `Needs your answer`, Clear 없음
        case questionsOnly
        /// 첫 사용: 한 번도 Clear하지 않았고 기준점도 없다 (`since: null` + `init_token`). 첫 정상 표시 뒤 서버가 기준점을 확정하고 새 run 결과가 Clear 없이 나온다
        case firstUse
        /// 한 번도 Clear하지 않았다 (`since: null`, 토큰 없음: 이 기능이 없는 서버)
        case neverCleared
    }

    enum ClearBehavior: String {
        /// 곧 읽음 처리한다 (200)
        case apply
        /// 조회한 뒤 범위가 달라졌다 (409): 새 변화가 하나 더 보인다
        case conflict
        /// 서버는 읽음 처리했지만 응답을 잃었다
        case loseResponse
        /// 끝나지 않는다 (`releaseHeld()`로 받는다)
        case hang
        /// 거절 (429)
        case reject
    }

    enum BaselineBehavior: String {
        /// 곧 기준점을 만든다 (200 initialized)
        case apply
        /// 확인과 표시 사이에 범위가 달라졌다 (409): 아무것도 쓰지 않는다
        case conflict
        /// 서버는 기준점을 만들었지만 응답을 잃었다
        case loseResponse
        /// 끝나지 않는다 (`releaseHeld()`로 받는다)
        case hang
    }

    private let lock = NSLock()
    private var _scenario: Scenario
    private var _behavior: ClearBehavior
    private var _baselineBehavior: BaselineBehavior
    private var cleared = false
    private var initialized = false
    private var lateArrival = false
    private var held: [CheckedContinuation<Void, Never>] = []
    private(set) var reads = 0
    private(set) var clears: [String] = []
    private(set) var baselines: [String] = []

    init(scenario: Scenario = .changes, clear: ClearBehavior = .apply, baseline: BaselineBehavior = .apply) {
        _scenario = scenario
        _behavior = clear
        _baselineBehavior = baseline
    }

    var scenario: Scenario {
        get { lock.withLock { _scenario } }
        set { lock.withLock { _scenario = newValue } }
    }

    var behavior: ClearBehavior {
        get { lock.withLock { _behavior } }
        set { lock.withLock { _behavior = newValue } }
    }

    var baselineBehavior: BaselineBehavior {
        get { lock.withLock { _baselineBehavior } }
        set { lock.withLock { _baselineBehavior = newValue } }
    }

    /// 서버가 처음 상태로 돌아간다 (Clear 전, 기준점 전, 새 변화 없음). 센 요청도 비운다
    func reset(_ scenario: Scenario? = nil, clear: ClearBehavior? = nil, baseline: BaselineBehavior? = nil) {
        lock.withLock {
            if let scenario { _scenario = scenario }
            if let clear { _behavior = clear }
            if let baseline { _baselineBehavior = baseline }
            cleared = false
            initialized = false
            lateArrival = false
            reads = 0
            clears = []
            baselines = []
        }
        releaseHeld()
    }

    func releaseHeld() {
        let waiting = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            defer { held = [] }
            return held
        }
        waiting.forEach { $0.resume() }
    }

    // MARK: ReturnSummaryGateway

    func returnSummary() async throws -> ReturnSummaryResponse {
        let (scenario, cleared, initialized, late) = lock.withLock { () -> (Scenario, Bool, Bool, Bool) in
            reads += 1
            return (_scenario, self.cleared, self.initialized, lateArrival)
        }
        try? await Task.sleep(for: .milliseconds(80))
        switch scenario {
        case .readFails: throw APIError.transport("sample: connection lost")
        case .featureOff: throw APIError.server(status: 404, code: .notFound, message: APIError.featureOffMessage)
        default: return Self.response(scenario, cleared: cleared, initialized: initialized, lateArrival: late)
        }
    }

    func clearReturnSummary(cursor: String) async throws -> ReturnSummaryClearResponse {
        let behavior = lock.withLock { () -> ClearBehavior in
            clears.append(cursor)
            return _behavior
        }
        let done = ReturnSummaryClearResponse(clearedThrough: Date(), applied: true)
        switch behavior {
        case .apply:
            try? await Task.sleep(for: .milliseconds(250))
            lock.withLock { cleared = true }
            return done
        case .conflict:
            try? await Task.sleep(for: .milliseconds(150))
            lock.withLock { lateArrival = true }
            throw APIError.server(status: 409, code: .conflict, message: "변화가 있습니다.")
        case .loseResponse:
            try? await Task.sleep(for: .milliseconds(150))
            lock.withLock { cleared = true }
            throw APIError.transport("sample: response lost")
        case .hang:
            await withCheckedContinuation { continuation in lock.withLock { held.append(continuation) } }
            lock.withLock { cleared = true }
            return done
        case .reject:
            throw APIError.server(status: 429, code: .rateLimited, message: "")
        }
    }

    func confirmReturnSummaryBaseline(initToken: String) async throws -> ReturnSummaryBaselineResponse {
        let behavior = lock.withLock { () -> BaselineBehavior in
            baselines.append(initToken)
            return _baselineBehavior
        }
        switch behavior {
        case .apply:
            try? await Task.sleep(for: .milliseconds(150))
            lock.withLock { initialized = true }
            return ReturnSummaryBaselineResponse(status: .initialized, applied: true)
        case .conflict:
            try? await Task.sleep(for: .milliseconds(100))
            throw APIError.server(status: 409, code: .conflict, message: "기준점 범위가 달라졌습니다.")
        case .loseResponse:
            try? await Task.sleep(for: .milliseconds(100))
            lock.withLock { initialized = true }
            throw APIError.transport("sample: response lost")
        case .hang:
            await withCheckedContinuation { continuation in lock.withLock { held.append(continuation) } }
            lock.withLock { initialized = true }
            return ReturnSummaryBaselineResponse(status: .initialized, applied: true)
        }
    }

    // MARK: 견본 응답 (서버 계약의 모양)

    private static func id(_ n: Int) -> UUID { SampleData.id(n) }
    /// 목록에 없는 작업 (취소됨): 줄은 보이되 열 곳이 없다
    private static let droppedID = SampleData.id(70)
    /// `-TFSampleSummaryEnglish`: 글자 인식(Vision)으로 줄을 눌러 보는 합성 조작 실행에서만 영문 제목 (제목은 화면 글자일 뿐, 줄은 id로 따른다)
    private static var english: Bool { ProcessInfo.processInfo.arguments.contains("-TFSampleSummaryEnglish") }
    private static func t(_ korean: String, _ english: String) -> String { Self.english ? english : korean }

    private static func at(_ minutesAgo: Double) -> Date { Date(timeIntervalSinceNow: -minutesAgo * 60) }

    private static func change(
        _ source: ReturnSummaryChangeSource, _ kind: String, detail: String? = nil, state: ReturnSummarySourceState? = nil, ago: Double = 30
    ) -> ReturnSummaryChange {
        ReturnSummaryChange(source: source, kind: kind, at: at(ago), detail: detail, sourceState: source == .actionEvent ? (state ?? .available) : nil)
    }

    private static func item(
        _ id: UUID, _ title: String, state: ReturnSummaryProgress? = .inProgress, needsAnswer: Bool = false, changes: [ReturnSummaryChange] = []
    ) -> ReturnSummaryItem {
        let decisions = needsAnswer ? [ReturnSummaryDecision(id: "confirm:\(id.uuidString.lowercased())", kind: .confirm, version: "d1", urgent: false)] : []
        return ReturnSummaryItem(
            actionID: id, title: title, status: state == nil ? .dropped : (state == .done ? .done : .open), state: state, needsAnswer: needsAnswer,
            decisions: decisions, changes: changes, next: ReturnSummaryNext(kind: needsAnswer ? .answer : .open, decisionKinds: needsAnswer ? [.confirm] : []),
            version: "\(id.uuidString.suffix(4))-\(changes.count)-\(needsAnswer)"
        )
    }

    private static func response(
        _ items: [ReturnSummaryItem], cursor: String? = "c3.sample", since: Date? = Date(timeIntervalSinceNow: -20 * 3_600),
        baseline: ReturnSummaryBaseline = .cleared, initToken: String? = nil, complete: Bool = true, changes: ReturnSummarySourceStatus = .ok,
        decisions: ReturnSummarySourceStatus = .ok
    ) -> ReturnSummaryResponse {
        ReturnSummaryResponse(
            generatedAt: Date(), since: since, baseline: baseline, cursor: cursor, initToken: initToken, complete: complete, empty: complete && items.isEmpty,
            sources: .init(changes: changes, decisions: decisions), items: items
        )
    }

    private static var asking: ReturnSummaryItem {
        item(SampleData.reviewID, t("제안서 v2 보내기", "Send proposal v2"), needsAnswer: true, changes: [change(.run, "done", detail: "review_failed", ago: 90)])
    }
    private static var askingOnly: ReturnSummaryItem { item(SampleData.reviewID, t("제안서 v2 보내기", "Send proposal v2"), needsAnswer: true) }
    private static var draft: ReturnSummaryItem {
        item(id(11), t("온보딩 디자인 시안", "Onboarding design draft"), changes: [change(.run, "done", detail: "agent_done", ago: 45)])
    }
    private static var longDemo: ReturnSummaryItem {
        item(id(10), t("금요일 고객 데모 준비 (새 온보딩, 결제 화면 포함)", "Customer demo prep"), changes: [change(.actionEvent, "due_changed", ago: 200), change(.actionEvent, "merged", ago: 60)])
    }
    private static var longPartner: ReturnSummaryItem {
        item(id(13), t("해외 파트너 요구사항을 반영한 다음 주 경영진 리뷰 발표 자료 정리", "Executive review deck"), changes: [change(.actionEvent, "owner_changed", ago: 120)])
    }
    private static var doneToday: ReturnSummaryItem { item(id(50), t("주간 회의록 정리", "Weekly notes"), state: .done, changes: [change(.actionEvent, "completed", ago: 15)]) }
    private static var dropped: ReturnSummaryItem {
        item(droppedID, t("취소된 배너 교체", "Replace old banner"), state: nil, changes: [change(.actionEvent, "dropped", ago: 300)])
    }

    static func response(_ scenario: Scenario, cleared: Bool, initialized: Bool = false, lateArrival: Bool) -> ReturnSummaryResponse {
        let late = item(id(14), t("데모 환경 배포", "Deploy demo environment"), changes: [change(.actionEvent, "due_changed", ago: 1)])
        switch scenario {
        case .changes:
            if cleared { return response([askingOnly], cursor: "c3.sample-after", since: Date()) }
            return response([asking, draft, longDemo, doneToday, dropped] + (lateArrival ? [late] : []))
        case .long:
            if cleared { return response([askingOnly], cursor: "c3.sample-after", since: Date()) }
            // 마지막 발생 순 셋: due → title → owner → updated → due ⇒ Owner changed · Updated from source · Due date changed
            let many = item(id(12), t("지훈에게 디자인 인계", "Hand off design"), changes: [
                change(.actionEvent, "due_changed", ago: 260), change(.actionEvent, "scope_changed", ago: 240), change(.actionEvent, "owner_changed", ago: 180),
                change(.actionEvent, "merged", ago: 100), change(.actionEvent, "due_changed", ago: 40),
            ])
            let waiting = item(id(20), t("QA 시나리오 업데이트", "Update QA scenarios"), state: .toDo, changes: [change(.message, "assistant", ago: 20)])
            let failed = item(id(21), t("계약서 변경 사항 검토", "Review contract changes"), state: .toDo, changes: [change(.run, "failed", ago: 10)])
            return response([asking, draft, longDemo, longPartner, many, waiting, failed, doneToday, dropped] + (lateArrival ? [late] : []))
        case .deletedSource:
            if cleared { return response([], cursor: "c3.sample-after", since: Date()) }
            return response([
                item(id(12), t("지훈에게 디자인 인계", "Hand off design"), changes: [change(.actionEvent, "scope_changed", state: .deleted, ago: 50)]),
                item(id(13), t("해외 파트너 요구사항을 반영한 다음 주 경영진 리뷰 발표 자료 정리", "Executive review deck"), changes: [change(.actionEvent, "due_changed", state: .accessLost, ago: 80)]),
                item(id(10), t("금요일 고객 데모 준비 (새 온보딩, 결제 화면 포함)", "Customer demo prep"), changes: [change(.actionEvent, "scope_changed", state: .textExpired, ago: 400)]),
            ])
        case .truncated:
            // 앞 페이지(보인 작업만 읽음 처리) → Clear 뒤에는 나머지 페이지: 잘리지 않았다
            if cleared { return response([longPartner, item(id(12), t("지훈에게 디자인 인계", "Hand off design"), changes: [change(.actionEvent, "owner_changed", ago: 70)])], cursor: "c3.sample-page2") }
            return response([asking, draft, longDemo, doneToday], cursor: "c3.sample-page1", complete: false, changes: .truncated)
        case .uninterpretable:
            // 모르는 outcome(`mystery`) · 모르는 kind: 줄은 남고 어떤 성공 문구도 없다. Clear 차단
            return response([
                asking,
                item(id(11), t("온보딩 디자인 시안", "Onboarding design draft"), changes: [change(.run, "done", detail: "mystery", ago: 45)]),
                item(id(10), t("금요일 고객 데모 준비 (새 온보딩, 결제 화면 포함)", "Customer demo prep"), changes: [change(.actionEvent, "teleported", ago: 60), change(.actionEvent, "due_changed", ago: 30)]),
            ])
        case .unavailable:
            return response([askingOnly], cursor: nil, baseline: .unknown, complete: false, changes: .unavailable)
        case .decisionsUnavailable:
            return response([draft, longDemo], cursor: "c3.sample", complete: false, decisions: .unavailable)
        case .empty:
            return response([], cursor: "c3.sample-empty", since: Date())
        case .questionsOnly:
            return response([askingOnly, item(id(11), t("온보딩 디자인 시안", "Onboarding design draft"), needsAnswer: true)], cursor: "c3.sample-q")
        case .firstUse:
            // 첫 정상 표시 뒤 서버가 기준점을 확정한다. 그 뒤에는 Clear 없이도 새 run 결과가 나온다 (기준점 전 run · 대화 이력은 과거라 나오지 않았다)
            if cleared { return response([askingOnly], cursor: "c3.sample-after", since: nil, baseline: .initialized) }
            let actionChanges = [asking.withChanges([]), longDemo, longPartner]
            if initialized { return response(actionChanges + [draft], since: nil, baseline: .initialized) }
            return response(actionChanges, since: nil, baseline: .neverCleared, initToken: "i1.sample-first-use")
        case .neverCleared:
            if cleared { return response([], cursor: "c3.sample-after", since: Date()) }
            return response([longDemo, longPartner], since: nil, baseline: .neverCleared)
        case .readFails, .featureOff:
            return response([])
        }
    }
}

private extension ReturnSummaryItem {
    /// 같은 줄에서 변화만 바꾼 사본 (견본이 첫 사용 응답에 run 이력을 넣지 않으려고)
    func withChanges(_ changes: [ReturnSummaryChange]) -> ReturnSummaryItem {
        ReturnSummaryItem(
            actionID: actionID, title: title, status: status, state: state, needsAnswer: needsAnswer, urgent: urgent, decisions: decisions, changes: changes, next: next,
            version: "\(version)-w\(changes.count)"
        )
    }
}

extension SampleData {
    private static func argument(after flag: String) -> String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }

    /// `-TFSampleSummary <이름>`: 복귀 요약 시작 시나리오 (기본 changes)
    static var summaryScenario: SampleReturnSummaryGateway.Scenario {
        argument(after: "-TFSampleSummary").flatMap(SampleReturnSummaryGateway.Scenario.init(rawValue:)) ?? .changes
    }

    /// `-TFSampleSummaryClear <이름>`: Clear를 보냈을 때의 서버 반응 (기본 apply)
    static var summaryClearBehavior: SampleReturnSummaryGateway.ClearBehavior {
        argument(after: "-TFSampleSummaryClear").flatMap(SampleReturnSummaryGateway.ClearBehavior.init(rawValue:)) ?? .apply
    }

    /// `-TFSampleSummaryBaseline <이름>`: 첫 정상 표시 확정을 보냈을 때의 서버 반응 (기본 apply)
    static var summaryBaselineBehavior: SampleReturnSummaryGateway.BaselineBehavior {
        argument(after: "-TFSampleSummaryBaseline").flatMap(SampleReturnSummaryGateway.BaselineBehavior.init(rawValue:)) ?? .apply
    }
}
#endif
