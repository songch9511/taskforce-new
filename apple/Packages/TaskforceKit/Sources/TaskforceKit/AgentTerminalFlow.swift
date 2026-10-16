import Foundation
import Observation

// 세션 알약 흐름 (OA D4a-03 · 15 · 16, DS README :124 "one writer at a time"): 세션 패널 머리의 알약 둘.
// - **Open in Terminal**(`bound`, 첫 턴 뒤): 실행 파일 · 폴더 같은 미리 조건을 **서버 호출 전에** 확인하고(못 열면 서버 0), 서버 `open-external`을 부른 다음, 그 Mac에서 터미널을 연다.
//   서버 뒤 실패(터미널을 못 연다)는 세션을 `external` 그대로 둔다 — 사용자는 Resume here로 돌아올 수 있다 (되돌리는 요청 없음). 409(`session_busy` · `conflict`)는 다시 읽는다
// - **Resume here**(`external`): 확인 카드 "Is the Terminal session closed?"를 질문 카드 자리에 연다 (모달이 아니다). [Resume here]를 누르면 프로세스 검사기를 부르고, 프로세스가 있으면
//   빨간 한 줄 "Close the terminal session first"를 보이며 `external`을 유지한다. 없으면 서버 `resume-here {confirmed_terminal_closed:true}`. 못 찾은 것은 증명이 아니므로 확인 카드는 늘 거친다
// 터미널을 여는 launcher · 프로세스 검사기는 **프로토콜만** 여기 있고 앱의 실제 구현은 D4a-2다 (D4a-1은 가짜 · "못 찾음" 기본값). 알약을 이 Mac의 세션에만 보이는 규칙은 `AgentSessionPillRules.swift`다.

/// 이 Mac에서 터미널을 연다 (앱의 실제 구현: D4a-2의 `.command` 파일). 서버 호출 앞뒤에 부른다
public protocol AgentTerminalLauncher: Sendable {
    /// 미리 조건 (실행 파일 경로 · 작업 폴더 같은 것)을 **서버를 부르기 전에** 확인한다. 못 열면 false — 서버 호출은 0이다
    func canOpen(sessionID: UUID) async -> Bool
    /// 서버가 세션을 `external`로 넘긴 뒤 터미널을 연다
    func open(sessionID: UUID) async throws
}

/// Resume here 전에 그 세션을 이어받은 프로세스(터미널의 claude 등)가 아직 있는지 본다. 모든 프로세스를 훑을 수 있으므로 메인 스레드 밖에서 부른다
public protocol AgentProcessInspector: Sendable {
    /// 찾으면 true. 못 찾아도 증명은 아니다 (확인 카드는 늘 거친다)
    func hasProcess(resuming sessionID: UUID) async -> Bool
}

/// D4a-1의 기본 검사기: 아무것도 찾지 않는다 (실제 검사기는 D4a-2가 넣는다)
public struct NoProcessFoundInspector: AgentProcessInspector {
    public init() {}

    public func hasProcess(resuming sessionID: UUID) async -> Bool { false }
}

@MainActor
@Observable
public final class AgentSessionPillFlow {
    /// 질문 카드 자리에 열린 Resume here 확인 카드 하나 (한 번에 하나)
    public struct ResumeCard: Equatable, Sendable {
        public let sessionID: UUID
        /// 빨간 한 줄 (프로세스가 아직 있다). 입력 오류라 이 카드의 유일한 빨강이다
        public var error: String?
        /// 서버를 부르는 중이다 (두 번 눌러도 한 번)
        public var busy: Bool

        public init(sessionID: UUID, error: String? = nil, busy: Bool = false) {
            self.sessionID = sessionID
            self.error = error
            self.busy = busy
        }
    }

    public private(set) var resumeCard: ResumeCard?
    /// 서버 · 터미널 일이 끝났다 (성공 · 실패 · 409): 부르는 쪽이 세션을 다시 읽는다 (서버가 사실이다)
    @ObservationIgnored public var onNeedsReread: () -> Void = {}

    @ObservationIgnored private let requests: any AgentSessionRequests
    @ObservationIgnored private let launcher: (any AgentTerminalLauncher)?
    @ObservationIgnored private let inspector: any AgentProcessInspector
    @ObservationIgnored private let scope: AccountScope
    @ObservationIgnored private var openInFlight: Set<UUID> = []

    public init(
        requests: any AgentSessionRequests, launcher: (any AgentTerminalLauncher)?, inspector: any AgentProcessInspector = NoProcessFoundInspector(),
        scope: AccountScope
    ) {
        self.requests = requests
        self.launcher = launcher
        self.inspector = inspector
        self.scope = scope
        scope.onLeft { [weak self] in self?.reset() }
    }

    public func reset() {
        resumeCard = nil
        openInFlight = []
    }

    /// 이 앱이 Open in Terminal을 줄 수 있나 (launcher가 없으면 알약을 그리지 않는다: 동작이 없으면 그리지 않는다)
    public var offersOpenInTerminal: Bool { launcher != nil }

    /// 알약을 눌렀다. 꺼진 알약(턴이 돈다 · 질문이 열려 있다)은 아무것도 하지 않는다
    public func press(_ pill: AgentSessionPill, session: AgentSessionItem) async {
        switch pill {
        case .openInTerminal(let reason):
            guard reason == nil else { return }
            await openInTerminal(session)
        case .resumeHere:
            askResume(session)
        }
    }

    // MARK: Open in Terminal

    public func openInTerminal(_ session: AgentSessionItem) async {
        guard let launcher, let token = scope.token, openInFlight.insert(session.id).inserted else { return }
        defer { openInFlight.remove(session.id) }
        // 미리 조건은 서버를 부르기 전에: 못 열 것을 서버에 `external`로 적지 않는다
        guard await launcher.canOpen(sessionID: session.id), scope.isCurrent(token) else { return }
        do {
            _ = try await requests.openExternal(sessionID: session.id)
        } catch {
            // 409 `session_busy`(턴이 돈다) · `conflict`(첫 턴 전 · bound가 아니다) · 그 밖: 터미널을 열지 않고 다시 읽는다
            guard scope.isCurrent(token) else { return }
            onNeedsReread()
            return
        }
        guard scope.isCurrent(token) else { return }
        // 서버가 `external`로 적었다: 터미널을 못 열어도 되돌리지 않는다 (사실대로 보인다)
        try? await launcher.open(sessionID: session.id)
        guard scope.isCurrent(token) else { return }
        onNeedsReread()
    }

    // MARK: Resume here

    /// Resume here 알약: 서버를 부르지 않고 확인 카드를 연다 (다른 세션의 카드는 바뀐다)
    public func askResume(_ session: AgentSessionItem) {
        guard scope.token != nil, resumeCard?.busy != true else { return }
        resumeCard = ResumeCard(sessionID: session.id)
    }

    public func cancelResume() {
        guard resumeCard?.busy != true else { return }
        resumeCard = nil
    }

    /// [Resume here]: 프로세스 검사 → (없으면) 서버. 두 번 눌러도 한 번
    public func confirmResume() async {
        guard let card = resumeCard, !card.busy, let token = scope.token else { return }
        let id = card.sessionID
        resumeCard?.busy = true
        resumeCard?.error = nil
        let inspector = inspector
        // 모든 프로세스를 훑을 수 있다: 메인 스레드 밖에서
        let found = await Task.detached(priority: .userInitiated) { await inspector.hasProcess(resuming: id) }.value
        guard scope.isCurrent(token), resumeCard?.sessionID == id else { return }
        if found {
            // 프로세스가 아직 있다: external을 유지하고 서버를 부르지 않는다. 터미널을 닫고 다시 누르면 된다
            resumeCard = ResumeCard(sessionID: id, error: AgentCopy.closeTerminalFirst, busy: false)
            return
        }
        do {
            _ = try await requests.resumeHere(sessionID: id)
            guard scope.isCurrent(token) else { return }
            if resumeCard?.sessionID == id { resumeCard = nil }
        } catch {
            guard scope.isCurrent(token) else { return }
            if resumeCard?.sessionID == id {
                // 409: 다른 곳에서 이미 바뀌었다 — 카드를 닫고 다시 읽는다. 그 밖(연결 문제): 카드를 두고 다시 누를 수 있다
                if (error as? APIError)?.status == 409 { resumeCard = nil } else { resumeCard?.busy = false }
            }
        }
        onNeedsReread()
    }

    /// 새로 읽은 세션으로 카드를 맞춘다: 대상 세션이 더는 `external`이 아니거나 없으면 닫는다 (낡은 카드를 적용하지 않는다)
    public func reconcile(sessions: [AgentSessionItem]) {
        guard let card = resumeCard, !card.busy else { return }
        if sessions.first(where: { $0.id == card.sessionID })?.isExternal != true { resumeCard = nil }
    }
}
