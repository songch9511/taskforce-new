import Foundation

// OA U3: Taskforce 대화 규칙 (화면 없는 순수 함수). 판정 · 순서는 서버가 정한 그대로고 앱은 다시 정렬하지 않는다.
// - 보일 종류는 `confirm` · `result_ready` · `path_conflict` 셋이다 (U3-22). 에이전트 질문 셋 · C3 실행 결정은 그리지도 세지도 않는다 — 질문은 그 세션에서만 답한다 (DS :132).
// - 모르는 종류는 건너뛰고 응답이 완전하다고 믿지 않는다 (`skippedUnknown`).
// - 본문을 만들 재료가 없는 요청은 세지 않는다 (지어내지 않는다): v1 확인 요청에 짝이 없는 `confirm` · 세션을 모르는 `result_ready` · 경로 · 세션을 모르는 `path_conflict`.
//   재료를 **아직 읽는 중**이면 기다리는 것이고(`deferred`: 화면은 아무 주장도 하지 않는다), 다 읽었는데도 없으면 건너뛴 것이다(`skippedUnknown`: 응답을 믿지 않고 말한다).
// - 항목은 안정 id(`kind:열쇠`)로 가리킨다. 몇 번째인지(index)를 들고 있다가 목록이 바뀐 뒤 다른 항목에 행동하는 일이 없다.

/// Taskforce 요청 하나 (대화의 카드 하나)
public struct TaskforceRequest: Identifiable, Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        case confirm, resultReady, pathConflict
    }

    /// 안정 id: 서버 항목 `id` (`confirm:<action>` · `result_ready:<run>` · `path_conflict:<lease>`)
    public let id: String
    public let kind: Kind
    /// 묶음의 업무 id. `confirm`은 v1 확인 요청의 id와 같다
    public let actionID: UUID
    /// 처리되면 바뀐다: 옛 version으로 행동하지 않는다
    public let version: String
    public let result: TaskforceResultRef?
    public let conflict: TaskforceConflictRef?

    public init(id: String, kind: Kind, actionID: UUID, version: String, result: TaskforceResultRef? = nil, conflict: TaskforceConflictRef? = nil) {
        self.id = id
        self.kind = kind
        self.actionID = actionID
        self.version = version
        self.result = result
        self.conflict = conflict
    }
}

/// 본문 재료를 다 읽었나 (읽는 중이면 그 요청은 기다린다)
public struct TaskforceReadiness: Equatable, Sendable {
    /// v1 `/now` 목록을 받았다 (confirm 본문 · 근거가 거기서 온다)
    public var confirmationsKnown = true
    /// U2 세션 저장소가 세션을 읽었다
    public var sessionsKnown = true
    /// 경로 충돌 상세 읽기가 끝났다
    public var conflictDetailsKnown = true

    public static let ready = TaskforceReadiness()

    public init(confirmationsKnown: Bool = true, sessionsKnown: Bool = true, conflictDetailsKnown: Bool = true) {
        self.confirmationsKnown = confirmationsKnown
        self.sessionsKnown = sessionsKnown
        self.conflictDetailsKnown = conflictDetailsKnown
    }
}

/// 한 응답에서 보일 요청들
public struct TaskforceVisibleRequests: Equatable, Sendable {
    /// 서버 순서 그대로
    public let requests: [TaskforceRequest]
    /// 모르는 종류 · 읽을 수 없는 항목 · 재료를 다 읽었는데도 없는 요청을 건너뛰었다: 응답이 완전하다고 믿지 않는다 (요청 위 Notice)
    public let skippedUnknown: Bool
    /// 재료를 아직 읽는 중이라 기다리는 요청이 있다 (비었다고도 못 읽었다고도 말하지 않는다)
    public let deferred: Bool

    public static let none = TaskforceVisibleRequests(requests: [], skippedUnknown: false)

    public init(requests: [TaskforceRequest], skippedUnknown: Bool, deferred: Bool = false) {
        self.requests = requests
        self.skippedUnknown = skippedUnknown
        self.deferred = deferred
    }
}

public enum TaskforceRequestRules {
    /// 응답 → 보일 요청
    /// - confirmable: v1 `/now`의 확인 요청 id들 (본문 이유 · 기한 · 근거가 거기서 온다)
    /// - conflicts: 읽은 경로 충돌 상세 (lease id)
    /// - knownSessions: U2 세션 저장소가 읽은 세션 id들
    /// - readiness: 재료를 다 읽었나. 아직이면 없는 재료의 요청은 기다리고(`deferred`), 다 읽었으면 건너뛴 것이다
    public static func visible(
        _ response: TaskforceReviewResponse, confirmable: Set<UUID>, conflicts: [UUID: TaskforceConflictDetail], knownSessions: Set<UUID>,
        readiness: TaskforceReadiness = .ready
    ) -> TaskforceVisibleRequests {
        var requests: [TaskforceRequest] = []
        var seen = Set<String>()
        var skipped = false
        var deferred = false
        func missing(known: Bool) {
            if known { skipped = true } else { deferred = true }
        }
        for group in response.decisions ?? [] {
            if group.kind == .unknown { skipped = true }
            for item in group.items {
                guard item.kind.isKnown else {
                    skipped = true
                    continue
                }
                // 그리지 않는 종류: 건너뛴다 (모르는 종류가 아니다)
                guard item.kind.isDrawn else { continue }
                guard item.isReadable else {
                    skipped = true
                    continue
                }
                guard seen.insert(item.id).inserted else { continue }
                switch item.kind {
                case .confirm:
                    guard confirmable.contains(item.actionID) else {
                        missing(known: readiness.confirmationsKnown)
                        continue
                    }
                    requests.append(TaskforceRequest(id: item.id, kind: .confirm, actionID: item.actionID, version: item.version))
                case .resultReady:
                    // 세션이 지워졌으면(null) 보일 것이 없다. 모르는 세션은 읽는 중이면 기다린다
                    guard let result = item.result, let session = result.sessionID else {
                        skipped = true
                        continue
                    }
                    guard knownSessions.contains(session) else {
                        missing(known: readiness.sessionsKnown)
                        continue
                    }
                    requests.append(TaskforceRequest(id: item.id, kind: .resultReady, actionID: item.actionID, version: item.version, result: result))
                case .pathConflict:
                    guard let conflict = item.conflict else { continue }
                    guard let detail = conflicts[conflict.leaseID], detail.holderRunID == conflict.holderRunID, detail.laterRunID == conflict.laterRunID else {
                        missing(known: readiness.conflictDetailsKnown)
                        continue
                    }
                    guard let holder = detail.holderSessionID, let later = detail.laterSessionID else {
                        skipped = true
                        continue
                    }
                    guard knownSessions.contains(holder), knownSessions.contains(later) else {
                        missing(known: readiness.sessionsKnown)
                        continue
                    }
                    requests.append(TaskforceRequest(id: item.id, kind: .pathConflict, actionID: item.actionID, version: item.version, conflict: conflict))
                default:
                    continue
                }
            }
        }
        return TaskforceVisibleRequests(requests: requests, skippedUnknown: skipped, deferred: deferred)
    }

    /// 응답에서 경로 충돌 ref들 (상세를 읽을 대상)
    public static func conflictRefs(_ response: TaskforceReviewResponse) -> [TaskforceConflictRef] {
        response.items.filter { $0.kind == .pathConflict }.compactMap(\.conflict)
    }

    /// 화면이 응답을 믿을 수 있나: 결정 원천을 읽었고 모르는 것을 건너뛰지 않았고 `complete`다.
    /// 아니면 "비어 있다"고 말하지 않고 Notice로 말한다 (요청이 있으면 위에 Notice 하나)
    public static func isTrustworthy(_ response: TaskforceReviewResponse, skippedUnknown: Bool) -> Bool {
        response.decisionsOK && response.complete && !skippedUnknown
    }
}

/// 서버 순서 그대로의 요청 목록. 요청은 id로 가리킨다
public struct TaskforceRequestQueue: Equatable, Sendable {
    public let requests: [TaskforceRequest]

    public init(_ requests: [TaskforceRequest]) {
        self.requests = requests
    }

    public var count: Int { requests.count }
    public var isEmpty: Bool { requests.isEmpty }
    public var ids: [String] { requests.map(\.id) }

    /// ⌘1 · ⌥Space · bell의 목적지: 서버 순서의 첫 요청 (가장 오래 기다린 요청, 긴급이 먼저)
    public var first: TaskforceRequest? { requests.first }

    public func contains(_ id: String) -> Bool { requests.contains { $0.id == id } }
    public func request(_ id: String) -> TaskforceRequest? { requests.first { $0.id == id } }
    public func index(of id: String) -> Int? { requests.firstIndex { $0.id == id } }

    /// 이 요청에서 `offset`만큼 옮긴 요청의 id (← →). 끝에서 돌지 않고 멈춘다. 목록에 없는 id면 nil
    public func neighbor(of id: String, offset: Int) -> String? {
        guard let index = index(of: id) else { return nil }
        return requests[min(max(index + offset, 0), requests.count - 1)].id
    }

    /// 보던 요청이 빠졌을 때 다음에 볼 요청: 그 뒤에 있던 것 중 아직 남은 첫 번째, 없으면 앞에 있던 것 중 가장 가까운 것
    public static func successor(of id: String, previous: [String], current: [String]) -> String? {
        guard let index = previous.firstIndex(of: id) else { return nil }
        let alive = Set(current)
        if let next = previous[(index + 1)...].first(where: alive.contains) { return next }
        return previous[..<index].last(where: alive.contains)
    }

    /// 지금 화면에 보일 요청: 보던 요청이 아직 있으면 그것(순서가 바뀌어도 id로), 빠졌으면 그 뒤를 이은 요청, 보던 것이 없으면 첫 요청. 목록이 비면 nil
    public func resolving(_ shown: String?, previous: [String]) -> String? {
        if let shown {
            if contains(shown) { return shown }
            if let next = Self.successor(of: shown, previous: previous, current: ids) { return next }
        }
        return first?.id
    }
}

/// 머리의 steps 창 (U3-24): 점은 제목이 잘리지 않는 만큼(380 폭에서 10)까지 그리고, 넘으면 지금 요청이 가운데 오게 창을 민다 (끝에서는 멈춘다)
public enum TaskforceStepsWindow {
    public static let maxDots = 10

    public static func visible(count: Int, current: Int, maxDots: Int = Self.maxDots) -> Range<Int> {
        guard count > maxDots, maxDots > 0 else { return 0..<max(count, 0) }
        let clamped = min(max(current, 0), count - 1)
        let start = min(max(clamped - maxDots / 2, 0), count - maxDots)
        return start..<(start + maxDots)
    }
}

/// 대화 본문에 무엇을 보일지 (EmptyState의 다섯 화면 + 요청). 받은 응답이 없으면 "결정이 없다"고 말하지 않는다
public enum TaskforceScreen: Equatable, Sendable {
    /// 아무 주장도 하지 않는다: 이번 실행의 응답이 아직 없음 (읽는 중 · 로그아웃)
    case blank
    /// 응답 없이 오프라인
    case offline
    /// 응답 없이 읽기 실패 (이 서버가 아직 이 기능이 없는 404 포함)
    case failed
    /// 믿을 수 있는 응답에 기다리는 요청이 없다: "No decisions waiting" (뒤에 끊겼으면 `problem`)
    case empty(problem: WorkLoad.Problem?)
    /// 요청 하나를 보인다 (뒤에 끊겼거나 일부만 읽었으면 `problem`)
    case request(problem: WorkLoad.Problem?)
    /// 요청은 없지만 응답을 믿을 수 없다 (일부만 읽음 · 모르는 종류): 비어 있다고 말하지 않고 Notice만 말한다
    case incomplete(problem: WorkLoad.Problem)

    /// - hasResponse: 이번 실행에서 받은 응답이 있다
    /// - readProblem: 마지막 읽기가 끊겼다 (응답이 있으면 응답은 그대로 두고 위에 Notice)
    /// - trustworthy: `TaskforceRequestRules.isTrustworthy`
    /// - deferred: 본문 재료를 아직 읽는 중이라 기다리는 요청이 있다 (요청이 없으면 아무 주장도 하지 않는다)
    public static func of(hasResponse: Bool, readProblem: WorkLoad.Problem?, trustworthy: Bool, hasRequest: Bool, deferred: Bool = false) -> TaskforceScreen {
        guard hasResponse else {
            switch readProblem {
            case .offline?: return .offline
            case .failed?: return .failed
            case nil: return .blank
            }
        }
        let problem: WorkLoad.Problem? = readProblem ?? (trustworthy ? nil : .failed)
        if hasRequest { return .request(problem: problem) }
        // 기다리는 요청이 있으면 비었다고도 못 읽었다고도 말하지 않는다
        if deferred, trustworthy { return .blank }
        // 요청이 없는데 응답을 믿을 수 없으면 "No decisions waiting"이라고 말하지 않는다
        if !trustworthy { return .incomplete(problem: readProblem ?? .failed) }
        return .empty(problem: readProblem)
    }

    /// 답을 보낼 수 있나: 요청이 보이고 오프라인이 아닐 때만. 오프라인에서는 나중에 보내려고 모아 두지 않는다
    public var canAnswer: Bool {
        if case .request(let problem) = self { problem != .offline } else { false }
    }

    /// 요약을 그릴 수 있는 화면인가 (읽는 중 · 오프라인 · 읽기 실패에서는 요약을 그리지 않는다)
    public var drawsSummary: Bool {
        switch self {
        case .request, .empty, .incomplete: true
        case .blank, .offline, .failed: false
        }
    }
}

/// Taskforce 대화의 글자. 새 문구는 최소로 하고 기존 앱 문구를 재사용한다 (`handoffs/oa-u3-notes.md`에 새 문구를 모두 적는다)
public enum TaskforceCopy {
    /// 패널 머리 제목 · 레일 bell 이름의 앞 낱말
    public static let title = "Taskforce"
    public static let needsYourAnswer = ReviewCopy.needsYourAnswer
    public static let nothingWaiting = "Nothing waiting"
    /// 결과 카드 캡션
    public static let resultReady = "Result ready"
    /// 충돌: 먼저 쓴 쪽 줄의 상태 앞 낱말
    public static let touchedFirst = "Touched first"
    public static let answerSent = "Answer sent"
    public static let undo = "Undo"
    /// 빈 대화: 한 줄 + 다음 일 라벨 + 나갈 길 (Now가 비었을 때)
    public static let noDecisions = PanelEmptyCopy.noDecisions
    public static let next = "Next"
    public static let projects = "Projects"
    public static let tryAgain = ReviewCopy.tryAgain

    /// confirm 카드의 메타 (OA U3-25): **확인된** 프로젝트 이름만 — "Needs your answer"는 말하지 않는다(질문이 이미 질문이다, DS DecisionBlock). 이름이 없으면 메타 줄이 없다("").
    /// Release S4의 `ReviewCopy.meta`("Needs your answer · …")는 그대로다
    public static func confirmMeta(memberships: WorkMemberships) -> String {
        memberships.links.map(\.project.title).joined(separator: ", ")
    }

    /// bell 툴팁 · 접근성 이름의 앞부분
    public static func bellTooltip(rings: Bool) -> String {
        "\(title) · \(rings ? needsYourAnswer : nothingWaiting)"
    }

    /// "Which session keeps pricing.mdx?" — 경로의 마지막 요소 (경로 전체는 메타에)
    public static func whichSessionKeeps(path: String) -> String {
        "Which session keeps \(fileName(path))?"
    }

    /// "File conflict · src/content/pricing.mdx"
    public static func fileConflict(path: String) -> String {
        "File conflict · \(path)"
    }

    public static func keep(_ session: String) -> String { "Keep \(session)" }

    /// 먼저 쓴 쪽 줄의 상태: "Touched first · Running" (상태 말이 없는 닫힌 세션이면 "Touched first")
    public static func touchedFirst(line: String) -> String {
        line.isEmpty ? touchedFirst : "\(touchedFirst) · \(line)"
    }

    /// steps 접근성 이름 (사용자 승인 2026-10-18): "Request 2 of 3"
    public static func requestPosition(_ number: Int, of count: Int) -> String {
        "Request \(number) of \(count)"
    }

    /// 경로의 마지막 요소. 비었으면 경로 그대로
    static func fileName(_ path: String) -> String {
        let name = path.split(separator: "/", omittingEmptySubsequences: true).last.map(String.init)
        return name ?? path
    }
}

/// `PanelEmptyKind.noDecisions`는 UI 모듈에 있어 Kit이 직접 쓰지 못한다: 같은 글을 한 곳에 둔다 (UI 시험이 같음을 확인한다)
public enum PanelEmptyCopy {
    public static let noDecisions = "No decisions waiting"
}
