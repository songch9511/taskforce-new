#if os(macOS)
import AppKit
import Observation
import SwiftUI
import TaskforceKit
import TaskforceUI

/// 머리의 폴더 줄을 다시 읽으라는 신호 하나 (`ChatRuntime.folderRecheck`): 이 Mac의 폴더 등록부는 관찰되지 않아, 값을 올려야 머리를 그리는 뷰가 다시 그려진다
@MainActor
@Observable
final class FolderRecheck {
    var tick = 0
}

/// 대화 · 기억 · 범위 멤버십 상태를 한 곳에 묶는다 (`TF_EDGE_SHELL`이 켜진 격리 Debug 실행에서만 만든다, `AppRuntime.chatRuntime`).
/// 앱 시작 때 세션에 한 번 붙어, 패널 · 설정 창이 떠 있는지와 상관없이 로그아웃 · 다른 계정 · 같은 UUID 재로그인에 초안 · 캐시 · 대기 전송을 비운다.
/// 저장 위치: 초안 · 아직 서버에 없는 빈 대화 · 보내는 중인 글 · 읽은 대화 · 기억은 모두 **이 객체의 메모리**뿐이다 (디스크 · UserDefaults 없음).
/// 앱을 끄면 사라지고, 다시 켜면 서버 대화에서 마지막 대화 · 범위를 읽어 되살린다 (A03)
@MainActor
final class ChatRuntime {
    let scope: AccountScope
    /// 안 연 끝남 표시의 저장소: 셸 컨트롤러가 레일 링 · 데스크톱 링에 그대로 넘긴다 (끝난 링이 앱을 다시 켠 뒤에도 남는다)
    let doneStores: RailDoneStores
    let memory: MemoryStore
    let chat: ChatStore
    /// Assistant 창의 대상 목록 (OA U1): 대상 메뉴의 행. 이 빌드가 에이전트를 띄울 수 없으면(샌드박스) 모든 에이전트 행이 "Can't run agents in this build"다
    let targets: AssistantTargetsStore
    /// All work의 실제 범위(프로젝트) 멤버십 (S3b). 없으면 모든 할 일이 Ungrouped (범위를 읽지 않는다)
    let contexts: WorkContextStore?
    /// 새 Issues 화면(OA U2)의 세션 · 이슈 번호 · 이슈 상세 읽기. **게이트가 꺼져 있으면 nil** (`EdgeSurfaces.issueScreens`): 읽기도 타이머도 없다
    let issues: IssueRuntime?
    /// 에이전트 대화의 Stop 요청과 그 결과 (OA D4a-13): Assistant 창 · 세션 패널이 같이 쓴다. 이 연결이 Stop route를 모르면(견본 · 시험용 가짜) 요청이 없다
    let stop: AgentStopStore
    /// Assistant 창의 에이전트 대화 세션을 좁게 읽는다 (OA D4a-13b): 열린 대화의 세션과 그 task만. U2의 `issueScreens` 게이트와 상관없이 창이 열리면 읽는다 — 이 연결이 세션 읽기를 모르면 nil
    let agentTurns: AgentSessionStore?
    /// 세션 패널의 줄 동작 (Send again · 후보 고르기 메뉴 · View full, OA D4a-1): Assistant 창은 창마다 자기 것을 가진다
    let panelDesk: AgentTurnDesk
    /// 세션 패널 머리의 알약 흐름 (OA D4a-03 · 15 · 16): 서버 `open-external` · `resume-here`와 확인 카드. 이 연결이 세션 route를 모르면 nil.
    /// 터미널을 여는 launcher · 프로세스 검사기는 D4a-2가 넣는다 (지금은 launcher가 없어 Open in Terminal 알약이 없고, 검사기는 "못 찾음"이다)
    let pillFlow: AgentSessionPillFlow?
    /// 에이전트의 열린 질문 (OA D4b-m-1): Assistant 창과 세션 패널이 **같은 상태**를 본다 (2초 보류 · Undo · 실패 되돌림). **게이트가 꺼져 있거나**(`EdgeSurfaces.agentQuestions`) 이 연결이 질문 읽기 · 답 route를 모르면 nil: 카드도 읽기도 알림도 없다
    let questions: AgentQuestionStore?
    /// 질문이 열리면 이 Mac이 거는 로컬 알림 (D4bm-60). bridge가 켜져 있을 때만 보낸다. `questions`가 없으면 nil
    let notifications: AgentNotifications?
    /// 그 세션의 카드가 지금 키 표면에 보이나 (알림을 보내지 않는 조건): 컨트롤러가 창 · 패널에 잇는다
    var isQuestionVisible: (UUID) -> Bool = { _ in false }
    /// 인용의 원문 링크를 연다 (테스트는 가짜로 바꾼다)
    var openURL: (URL) -> Void = { NSWorkspace.shared.open($0) }
    /// 이 Taskforce 세션이 **이 Mac에서** 돌아 어댑터가 묶은 Claude 세션 id · 세션 cwd (세션 보기의 도구 단계 · 일 목록을 이 Mac의 기록에서 읽는다). 이 Mac이 모르는 세션이면 nil (단계는 후속의 서버 저장 뒤에).
    /// 시험 · 견본은 가짜로 바꾼다
    var localTranscriptTarget: @MainActor (UUID) async -> AgentLocalTranscriptTarget? = { id in await BridgeHost.shared?.activeRuntime?.localTranscriptTarget(forAgentSession: id) }
    /// 이어받은 Taskforce 세션의 턴이 "다른 곳에서 쥐고 있어" 막힌 이유 (이 Mac의 런타임 메모리, OA 외부 세션 PR2m 계약 S16): 세션 패널의 머리 아래 상태 줄이 읽는다. 막히지 않았으면 nil. 시험 · 견본은 가짜로 바꾼다
    var attachedHold: @MainActor (UUID) async -> ExternalWriterVerdict? = { id in await BridgeHost.shared?.activeRuntime?.attachedHold(forAgentSession: id) }
    /// 어댑터가 읽은 `task_*` 줄로 만든 백그라운드 일 목록 (이 Mac 안에서만). 실제 앱은 어댑터와 같은 공유 판이다
    var backgroundBoard: BackgroundTaskBoard = .shared
    /// 보내기 전에 작업 폴더를 묻는 시스템 폴더 창 (OA D4a2-05). 시험은 가짜 패널로 바꾼다 (실제 `NSOpenPanel`을 열지 않는다)
    var workspacePicker: any AgentWorkspacePicking = WorkspacePicker()
    /// 지금 계정의 폴더 등록부 + 연결 확인 (bridge가 꺼져 있으면 nil: 묻지 않는다). 시험은 가짜로 바꾼다
    var workspaceAsking: @MainActor () -> AgentWorkspaceAsking? = { BridgeHost.shared?.workspaceAsking }
    /// 홈으로 줄여 보일 경로들 (홈 · 홈의 realpath, Settings › Your agents와 같다). **처음 쓸 때 한 번** 구한다 (머리를 그릴 때마다 파일 시스템을 보지 않는다). 시험 · 견본은 바꾸고 되돌린다
    lazy var workspaceHomes: [String] = {
        let home = NSHomeDirectory()
        let real = URL(fileURLWithPath: home).resolvingSymlinksInPath().path
        return real == home ? [home] : [home, real]
    }()
    /// 폴더가 지금 있는 디렉터리인가 (머리 폴더 메뉴의 Show in Finder를 켠다). 시험은 바꾼다
    var folderExists: (String) -> Bool = { path in
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }
    /// 폴더를 Finder에서 보인다 (사용자 승인 2026-10-22: Show in Finder). 시험은 기록만 하는 가짜로 바꾼다 (실제 Finder를 열지 않는다)
    var revealInFinder: @MainActor (URL) -> Void = { NSWorkspace.shared.activateFileViewerSelecting([$0]) }
    /// 이 Mac의 bridge id (모르면 nil). 첫 보내기 직후 세션은 생겼는데 핀이 아직 없을 때, 그 세션이 이 Mac의 것인지 알아 고른 폴더를 계속 보이는 데 쓴다.
    /// 기본은 질문 저장소가 아는 값이다 (질문이 꺼져 있으면 nil: 모르면 보이지 않는다). 시험은 바꾼다
    var thisMacBridgeID: () -> UUID? = { nil }
    /// 폴더 줄을 다시 읽으라는 신호: 이 Mac의 폴더 등록부는 관찰되지 않아(bridge가 다른 스레드에서 세션 핀을 쓴다) 다른 변화가 와야만 머리가 다시 그려진다.
    /// 세션 저장소가 새로 읽을 때마다(열린 task가 있으면 5초마다) · 창의 짧은 다시 읽기가 핀을 찾았을 때 · 폴더가 있는지 새로 볼 때 올라간다. `folderLine(for:)`가 읽어 두어 머리를 그리는 뷰가 따라간다
    let folderRecheck = FolderRecheck()
    /// 세션이 막 생긴 창이 핀이 꽂히길 짧게 다시 읽는 횟수 · 간격 (시험은 바꾼다: 0이면 없다)
    var folderPollRounds = 20
    var folderPollInterval: Duration = .milliseconds(500)
    /// 폴더가 있는지를 경로마다 한 번만 본다 (머리를 그릴 때마다 파일 시스템을 보지 않는다). 컨트롤에 포인터가 닿으면 새로 본다 (`refreshFolderExistence`) — 누르는 순간의 확인은 늘 새로 한다
    private var existenceByPath: [String: Bool] = [:]
    /// 폴더 창이 떠 있다 (두 번 눌러도 한 창)
    private var isAskingWorkspace = false
    #if DEBUG
    /// 견본이면 가짜 서버 (스냅샷이 상태를 바꿔 가며 담는다)
    var sampleGateway: SampleChatGateway?
    var sampleContextGateway: SampleContextGateway?
    #endif
    private var connectivityTask: Task<Void, Never>?
    private var sleepObservers: [NSObjectProtocol] = []

    /// - issueScreens: 새 Issues 화면을 켜는가 (기본은 이 실행의 게이트 `EdgeSurfaces.issueScreens`). 켜져 있어도 이 연결이 `IssueScreensGateway`를 따르지 않으면(견본 · 시험용 가짜) 만들지 않는다
    /// - agentQuestions: 에이전트 질문 카드를 켜는가 (기본은 이 실행의 표면 `EdgeSurfaces.current.agentQuestions`). 켜져 있어도 이 연결이 `AgentQuestionGateway`를 따르지 않으면(견본 · 시험용 가짜) 만들지 않는다
    /// - secretSubmitter: 비밀값을 이 Mac에서 내보내는 곳. 없으면 비밀값 답은 "Couldn't send"로 돌아온다 (실제 구현은 D4b-m-2)
    /// - doneStores: 안 연 끝남 표시의 저장소 (레일 링 · 데스크톱 링, 계약 23장). 실제 앱은 `AppRuntime.makeChatRuntime`이 영속 저장소를 넘긴다 — 기본(메모리)은 시험이 실사용 설정을 건드리지 않게 하는 값이다
    /// - notificationCenter: 로컬 알림을 거는 센터 (시험은 가짜: 실제 알림 센터에 아무것도 보내지 않는다)
    /// - questionSleep: 2초 보류 · 종료 기다림의 시계 (시험은 손으로 돌린다)
    /// - notificationsEnabled: 질문 알림을 보내는가 (기본: bridge가 켜져 있을 때만, `BridgeFlag`)
    init(
        gateway: any ChatGateway, contextGateway: (any ContextGateway)? = nil, scope: AccountScope = AccountScope(),
        now: @escaping @Sendable () -> Date = { Date() }, issueScreens: Bool = EdgeSurfaces.issueScreensForThisRun,
        agentQuestions: Bool = EdgeSurfaces.current.agentQuestions, secretSubmitter: (any LocalSecretAnswerSubmitting)? = nil,
        doneStores: RailDoneStores = .inMemory(),
        notificationCenter: any AgentNotificationCenter = SystemAgentNotificationCenter(),
        questionSleep: @escaping AgentQuestionStore.Sleep = { try? await Task.sleep(for: .seconds($0)) }, notificationsEnabled: @escaping () -> Bool = { BridgeFlag.current }
    ) {
        #if DEBUG
        // 견본 하네스(`-TFEdgeSnapshotIssues`)는 세션 · 번호 · 상세와 프로젝트 아이콘이 있는 견본 서버를 읽는다 (실서버 · 기존 견본은 그대로)
        let gateway = issueScreens ? IssueSnapshotData.gateway(replacing: gateway) : gateway
        #endif
        self.scope = scope
        self.doneStores = doneStores
        memory = MemoryStore(gateway: gateway, scope: scope)
        // 대상 목록 · 칩을 실은 보내기는 실제 연결(`LiveChatGateway`)만 가진다. 견본 · 시험용 가짜는 Taskforce 대상으로만 보낸다
        let assistant = gateway as? any AssistantGateway
        chat = ChatStore(gateway: gateway, scope: scope, memory: memory, now: now, assistant: assistant)
        targets = AssistantTargetsStore(gateway: assistant, scope: scope, canRunAgents: { !AgentRuntimeEnvironment.isSandboxed() })
        // 에이전트 대화의 쓰기 · 읽기(Send again · 후보 · Stop · 전달 읽기)와 세션 route도 실제 연결만 가진다 (`as?`, OA D4a-20b)
        let conversationRoutes = gateway as? any AgentConversationGateway
        let sessionRoutes = gateway as? any AgentSessionRequests
        chat.agentConversation = conversationRoutes
        panelDesk = AgentTurnDesk(chat: chat)
        stop = AgentStopStore(conversations: conversationRoutes, sessions: sessionRoutes, scope: scope)
        // launcher (OA D4a2-06): `.command` 파일을 기본 처리 앱으로 연다. 견본(`-TFEdgeSnapshotAgentChat`)만 터미널을 열지 않는 가짜를 달아 알약 모양을 Figma와 맞춰 본다.
        // 프로세스 검사기(D4a2-07)는 이 Mac 상태가 묶은 Claude 세션 id로 프로세스를 훑는다 (메인 스레드 밖)
        #if DEBUG
        let launcher: (any AgentTerminalLauncher)? = AgentChatSnapshot.isEnabled || QuestionSnapshot.isEnabled ? SnapshotTerminalLauncher() : AgentTerminalLauncherLive.launcher()
        #else
        let launcher: (any AgentTerminalLauncher)? = AgentTerminalLauncherLive.launcher()
        #endif
        let inspector = AgentTerminalLauncherLive.inspector()
        pillFlow = sessionRoutes.map { AgentSessionPillFlow(requests: $0, launcher: launcher, inspector: inspector, scope: scope) }
        let sessionReads = gateway as? any AgentSessionGateway
        let chatForFocus = chat
        agentTurns = sessionReads.map { AgentSessionStore(gateway: $0, scope: scope, now: now, focus: { chatForFocus.viewedAgentSessionIDs() }) }
        // View full: 이 Mac의 bridge 원장에서 서버 열쇠로 전문을 찾는다 (다른 Mac의 세션이거나 정리됐으면 없다). bridge가 꺼져 있으면 링크가 없다
        chat.fullTextLookup = { key in
            guard let runtime = await MainActor.run(body: { BridgeHost.shared?.activeRuntime }) else { return nil }
            return await runtime.fullText(forServerKey: key)
        }
        #if DEBUG
        // 견본 하네스(`-TFEdgeSnapshotIssues`)는 프로젝트 아이콘 · 긴 이름이 있는 견본 범위를 읽는다 (실서버 · 기존 견본은 그대로)
        let contextGateway = issueScreens ? IssueSnapshotData.contextGateway(replacing: contextGateway) : contextGateway
        #endif
        contexts = contextGateway.map { WorkContextStore(gateway: $0, scope: scope) }
        issues = issueScreens ? (gateway as? any IssueScreensGateway).map { IssueRuntime(gateway: $0, scope: scope, now: now) } : nil
        // Stop · 알약이 끝나면 세션을 다시 읽는다 (서버가 사실이다): 좁은 저장소와, 켜져 있으면 U2의 전체 저장소
        let narrow = agentTurns
        let full = issues?.sessions
        stop.onChanged = { Task { @MainActor in
            await narrow?.refresh()
            await full?.refresh()
        } }
        // 턴을 시작할 수 있는 모든 입구(패널 보내기 · Assistant 창 보내기 · Send again · 후보 고르기)가 세션을 다시 읽게 한다:
        // 쉬는 세션(열린 task 없음)은 5초 읽기가 돌지 않아, 다시 읽지 않으면 Stop 원이 서지 않는다
        chat.onAgentTurnMayStart = { Task { @MainActor in
            await narrow?.refresh()
            await full?.refresh()
        } }
        pillFlow?.onNeedsReread = { Task { @MainActor in
            await narrow?.refresh()
            await full?.refresh()
        } }
        // 에이전트의 글(답 · 질문 · 사건 줄)은 서버가 비동기로 쓰고 `conversation_messages`는 Realtime 대상이 아니다: 세션 저장소가 새로 읽을 때마다
        // (열린 task가 있으면 5초마다) 보이는 에이전트 대화의 글도 다시 읽는다. 질문이 꺼져 있어도 켜 둔다 (Claude Code 첫 실사용: 마지막 답이 서버에는 있는데 창에 나오지 않았다, `AgentThreadFollow`)
        let chatToFollow = chat
        // 세션을 새로 읽을 때마다 열린 창의 폴더 줄도 다시 읽게 알린다: 핀이 창의 짧은 다시 읽기보다 늦게 꽂혀도 이 정기 읽기가 보인다 (사용자 결정 2026-10-22 재검토 2)
        let recheck = folderRecheck
        let followThreads: @MainActor ([AgentSessionItem]) -> Void = { [weak chatToFollow] items in
            chatToFollow?.agentSessionsRead(items)
            recheck.tick += 1
        }
        agentTurns?.onApplied = followThreads
        issues?.sessions.onApplied = followThreads
        // 에이전트 질문 (OA D4b-m-1): 세션 저장소가 새로 읽을 때마다 질문 저장소가 질문을 기다리는 세션의 질문을 읽는다 (좁은 저장소 · U2 전체 저장소 둘 다)
        if agentQuestions, let routes = gateway as? any AgentQuestionGateway {
            let questions = AgentQuestionStore(gateway: routes, scope: scope, secrets: secretSubmitter, sleep: questionSleep)
            let notifications = AgentNotifications(center: notificationCenter, isEnabled: notificationsEnabled)
            self.questions = questions
            self.notifications = notifications
            scope.onLeft { [weak notifications] in notifications?.accountLeft() }
            questions.thisMacProvider = { await BridgeHost.shared?.activeRuntime?.localBridgeID() }
            agentTurns?.onApplied = { [weak questions, weak notifications] items in
                followThreads(items)
                questions?.sessionsRead(items)
                notifications?.sessionsSeen(items, thisMacBridgeID: questions?.thisMacBridgeID, signedIn: scope.token != nil)
            }
            issues?.sessions.onApplied = { [weak questions, weak notifications] items in
                followThreads(items)
                questions?.sessionsRead(items)
                notifications?.sessionsSeen(items, thisMacBridgeID: questions?.thisMacBridgeID, signedIn: scope.token != nil)
            }
            // 서버가 답을 받았다: 그 대화를 다시 읽어 서버의 사건 줄("Answered" · 고른 답)이 보이게 한다 (접힌 줄은 그 열쇠가 오면 치운다, D4bm-25)
            let chatStore = chat
            questions.onAnswered = { _, conversation in if let conversation { chatStore.loadConversation(conversation) } }
            questions.onOpened = { [weak self, weak notifications] opened in
                notifications?.opened(opened, isVisible: self?.isQuestionVisible(opened.sessionID) ?? false)
            }
            questions.onClosed = { [weak notifications] keys in notifications?.closed(keys) }
        } else {
            questions = nil
            notifications = nil
        }
        // 이 Mac의 bridge id는 질문 저장소가 읽은 값을 쓴다 (질문이 꺼져 있으면 모른다)
        thisMacBridgeID = { [weak self] in self?.questions?.thisMacBridgeID }
        followSleep()
    }

    /// 에이전트 대화의 **첫 보내기 직전** 작업 폴더를 묻는다 (OA D4a2-05). `true`면 보내도 된다(묻지 않았거나, 골라서 등록했다). `false`면 보내지 않는다 —
    /// 폴더 창을 취소했거나 이미 묻는 중이다. 글은 입력 칸에 그대로 둔다. 묻는 조건은 `AgentWorkspaceGate`: 세션이 아직 없음 ∧ 대상이 이 Mac의 연결 ∧ 그 프로젝트에 폴더가 없음(Ungrouped는 그 대화가 고른 폴더가 없음)
    /// `stillCurrent`: 보내려던 곳이 아직 그대로인가 (`AgentSendTicket`): 폴더를 기다리는 동안 바뀌면 `false`
    func prepareAgentSend(
        conversationID: UUID, hasSession: Bool, target: AssistantTargetPick, chips: [AssistantChip], stillCurrent: @MainActor () -> Bool = { true }
    ) async -> Bool {
        guard !isAskingWorkspace else { return false }
        guard target.isAgent, !hasSession, let asking = workspaceAsking() else { return true }
        isAskingWorkspace = true
        let gate = AgentWorkspaceSendGate(folders: asking.folders, picker: workspacePicker, isThisMac: asking.isThisMac)
        let projects = AgentWorkspaceGate.projects(chips: chips, index: contexts?.index)
        let outcome = await gate.prepare(conversationID: conversationID, hasSession: hasSession, target: target, projects: projects, stillCurrent: stillCurrent)
        isAskingWorkspace = false
        return outcome == .proceed
    }

    /// 이 대화가 쓰는 폴더의 경로 (이 Mac이 **이 대화에** 적어 둔 것만): 세션이 있으면 그 세션의 로컬 핀. 핀이 아직 없는데(첫 보내기 직후 · 다른 Mac의 세션) 그 세션이 **이 Mac의 것으로 알려져** 있으면
    /// 보내기 전에 고른 폴더를 계속 쓴다 (줄이 사라졌다 돌아오지 않게). 이 Mac의 것인지 모르거나 다른 Mac의 것이면 nil이다. 세션이 없으면 보내기 전에 고른 폴더
    private func currentFolderPath(for model: AssistantWindowModel, in folders: any AgentWorkspaceFolders) -> String? {
        let session = model.sessionID
        if let path = folders.folder(forSession: session, conversation: model.conversationID) { return path }
        guard session != nil, let item = model.sessionItem, AgentSessionRules.isOnThisMac(item, thisMacBridgeID: thisMacBridgeID()) else { return nil }
        return folders.folder(forSession: nil, conversation: model.conversationID)
    }

    /// 대화 머리의 작업 폴더 줄 (사용자 결정 2026-10-21): 에이전트 대화에서 이 Mac의 등록부가 **이 대화에** 적어 둔 폴더가 있을 때만 (`currentFolderPath`).
    /// 폴더를 고르기 전 · 다른 Mac의 세션 · 이 Mac의 것인지 모르는 세션(핀 전) · Taskforce 대화는 nil이라 머리에 아무것도 더하지 않는다. 경로는 이 Mac에만 있고 서버로 가거나 로그에 남지 않는다.
    /// `exists`: 폴더가 지금 있나 (없으면 Show in Finder만 꺼진다) — 경로마다 한 번만 본다. 다시 읽기 신호(`folderRecheck`)를 읽어 두어 이 줄을 그리는 뷰가 신호를 따라간다
    func folderLine(for model: AssistantWindowModel) -> AgentWorkspaceFolderLine? {
        _ = folderRecheck.tick
        guard model.toAgent, let asking = workspaceAsking(), let path = currentFolderPath(for: model, in: asking.folders) else { return nil }
        return AgentWorkspaceFolderLine(path: path, homes: workspaceHomes, exists: folderStillExists(path))
    }

    /// 폴더가 있는 디렉터리인가: 경로마다 한 번만 본다 (머리를 그릴 때마다 파일 시스템을 보지 않는다)
    private func folderStillExists(_ path: String) -> Bool {
        if let known = existenceByPath[path] { return known }
        let exists = folderExists(path)
        existenceByPath[path] = exists
        return exists
    }

    /// 컨트롤에 포인터가 닿았다 (메뉴가 열리기 전): 지금까지 본 폴더들이 있는지 새로 보고, 달라진 것이 있을 때만 머리를 다시 그리게 한다 (포인터가 닿을 때마다 다시 그리지 않는다)
    func refreshFolderExistence() {
        let known = existenceByPath
        existenceByPath.removeAll()
        var changed = false
        for (path, was) in known {
            let now = folderExists(path)
            existenceByPath[path] = now
            if now != was { changed = true }
        }
        if changed { folderRecheck.tick += 1 }
    }

    /// 머리 폴더 메뉴의 "Show in Finder" (사용자 승인 2026-10-22): 이 대화의 지금 폴더를 Finder에서 보인다. 폴더가 없거나(오래된 화면에서 눌러도) 폴더가 아니면 아무것도 하지 않는다 — 오류 글 없음.
    /// 누르는 순간의 확인은 캐시를 쓰지 않고 늘 새로 한다
    func showFolderInFinder(_ model: AssistantWindowModel) {
        guard model.toAgent, let asking = workspaceAsking(), let path = currentFolderPath(for: model, in: asking.folders), folderExists(path) else { return }
        revealInFinder(URL(fileURLWithPath: path, isDirectory: true))
    }

    /// 이 대화가 보내기 전에 고른 폴더를 지운다 (대화가 그 폴더를 쓰지 않게 된 때). 창 모델의 `forgetFolder`가 여기로 온다
    func forgetChosenFolder(of conversation: UUID) {
        workspaceAsking()?.folders.forgetFolder(forConversation: conversation)
    }

    /// 창 관리자가 모델마다 건다: 모델이 알리는 "이 대화는 그 폴더를 쓰지 않는다"를 이 Mac의 등록부에 옮긴다
    func wireFolders(_ model: AssistantWindowModel) {
        model.forgetFolder = { [weak self] in self?.forgetChosenFolder(of: $0) }
    }

    /// 창이 닫힌다: 빈 새 대화(서버에 없고 글이 없다)를 보이던 창이면 그 대화에 적힌 폴더를 버린다 (보낸 대화의 폴더는 세션의 기록이라 남긴다)
    func windowClosing(_ model: AssistantWindowModel) {
        let conversation = model.conversationID
        if chat.isLocalChat(conversation), !chat.hasMessages(conversation) { forgetChosenFolder(of: conversation) }
    }

    /// 머리 폴더 메뉴의 "New chat in another folder…" (사용자 결정 2026-10-21): 폴더 창을 먼저 연다 — 취소하면 아무것도 바뀌지 않는다. 고르면 같은 에이전트의 **새 대화**에 그 폴더를 적어 이 창에 열고
    /// 입력칸에 포커스를 준다. 이 대화(글 · 초안 · 폴더)는 그대로다: Claude 세션의 폴더는 세션을 연 뒤 바뀌지 않으므로 이 대화의 폴더를 바꾸는 길은 없다.
    /// 폴더 창의 문구 · 거절 규칙은 보내기 전 묻기와 같다 (승인된 "Choose a folder for this session" · "Choose", 겹치는 폴더 · 민감 폴더 거절).
    /// 폴더 창을 기다리는 동안 계정 · 대화 · 대상이 바뀌면 아무것도 적지 않는다 (`prepareAgentSend`와 같다). 폴더 창이 이미 떠 있으면 아무것도 하지 않는다.
    /// 고른 폴더를 등록하지 못하면(창이 받아 준 뒤 틈에 거절 · 쓰기 실패) 창은 그대로 두고 이 대화에 인라인 한 줄을 보인다 — 거절은 폴더 창이 보였을 승인된 문장 그대로, 그 밖은 Settings › Your agents의 쓰기 실패와 같은 승인된 말
    func startChatInAnotherFolder(_ model: AssistantWindowModel) async {
        guard model.toAgent, !isAskingWorkspace, let asking = workspaceAsking() else { return }
        isAskingWorkspace = true
        defer { isAskingWorkspace = false }
        model.clearFolderNotice()
        let account = scope.token
        let conversation = model.conversationID
        let target = model.pick
        let unchanged: @MainActor () -> Bool = { [scope] in
            scope.token == account && model.conversationID == conversation && model.pick.isSame(as: target)
        }
        let folders = asking.folders
        let folderScope = AgentWorkspaceGate.Scope.conversation(conversation)
        let accepts: @Sendable (String) -> Bool = { folders.accepts(path: $0, scope: folderScope) }
        let reason: @Sendable (String) -> String = { folders.rejectionMessage(forPath: $0, scope: folderScope) }
        guard let path = await workspacePicker.pickFolder(
            message: AgentWorkspaceCopy.chooseFolderForSession, prompt: AgentWorkspaceCopy.choose, rejection: AgentWorkspaceCopy.rejected, accepts: accepts, reason: reason
        ), unchanged() else { return }
        var failure: (any Error)?
        let started = model.startAgentChat { id in
            do { try folders.register(path: path, scope: .conversation(id)) } catch {
                failure = error
                throw error
            }
        }
        // 새 대화를 열지 못했다면 조용히 지나치지 않는다: 폴더를 적지 못했거나(등록 실패) 새 대화를 쓸 수 없었다 (이미 세션이 있는 대화 · 창이 옮겨 가지 못함) — 어느 쪽이든 승인된 한 줄
        if !started { model.showFolderNotice(failure.map { Self.folderFailureText($0, path: path, folders: folders, scope: folderScope) } ?? AgentSettingsCopy.somethingWentWrong) }
    }

    /// 등록 실패의 인라인 글 (승인된 문장만): 등록부의 거절이면 폴더 창이 그 폴더에 보였을 문장, 그 밖(쓰기 실패)은 Settings의 실패 줄과 같은 말
    private static func folderFailureText(_ error: any Error, path: String, folders: any AgentWorkspaceFolders, scope: AgentWorkspaceGate.Scope) -> String {
        if case WorkspaceRegistry.RegistryError.rejected = error { return folders.rejectionMessage(forPath: path, scope: scope) }
        return AgentSettingsCopy.somethingWentWrong
    }

    /// Assistant 창의 보내기 (OA D4a2-05 · Astra P2-2). 에이전트 대화의 첫 보내기 직전에는 작업 폴더를 먼저 묻는다: 취소하면 보내지 않고 글은 입력 칸에 그대로 둔다.
    /// 묻는 동안 계정 · 창 · 대화 · 대상 · 칩 · 초안이 바뀌면 (`AgentSendTicket`) 등록도 전송도 하지 않고 초안도 지우지 않는다 — 폴더 창을 기다린 뒤 다른 대화로 보내지 않게
    func sendFromWindow(_ model: AssistantWindowModel) async {
        let text = model.draft
        guard model.canSend(text) else { return }
        if model.toAgent {
            let ticket = model.sendTicket(account: scope.token)
            let unchanged: @MainActor () -> Bool = { [scope] in model.sendTicket(account: scope.token) == ticket }
            guard await prepareAgentSend(
                conversationID: model.conversationID, hasSession: model.sessionID != nil, target: model.pick, chips: model.chips.chips, stillCurrent: unchanged
            ), unchanged() else { return }
        }
        await model.send(text)
    }

    /// 잠자기: 자는 동안 전달 읽기 · 세션 읽기 5초 시계가 멈추고, 깨면 한 번 읽는다 (OA D4a-10 · U2-35). 세션 패널이 켜진 구성은 컨트롤러가 U2 저장소를 따로 잇는다
    private func followSleep() {
        let center = NSWorkspace.shared.notificationCenter
        let chat = chat
        let narrow = agentTurns
        sleepObservers = [
            center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated {
                    chat.setAsleep(true)
                    narrow?.setAsleep(true)
                }
            },
            center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated {
                    chat.setAsleep(false)
                    narrow?.setAsleep(false)
                }
            },
        ]
    }

    /// 연결 경로를 두 저장소에 알린다 (오프라인에서 돌아오면 대화 목록을 다시 읽는다)
    func followConnectivity(_ updates: AsyncStream<Bool>) {
        connectivityTask?.cancel()
        connectivityTask = Task { [weak self] in
            var wasOnline = true
            for await online in updates {
                guard let self else { return }
                chat.pathChanged(online: online)
                agentTurns?.pathChanged(online: online)
                memory.pathChanged(online: online)
                contexts?.pathChanged(online: online)
                issues?.pathChanged(online: online)
                if online, !wasOnline {
                    await chat.refresh()
                    await contexts?.refresh()
                }
                wasOnline = online
            }
        }
    }
}

/// Chats 화면 (디자인 ChatPage · ChatHistory): 머리(제목 · 새 대화 · history) · 본문(목록 또는 대화) · 입력칸.
/// 읽는 중 · 오프라인 · 실패 · 없음 · 기능 꺼짐은 서로 다른 화면이다. 업무 · 원문이 없어도 상담은 된다 (Composer는 늘 열려 있다).
enum EdgeChatScreen {
    static let bottomAnchor = "chat-bottom"
}

struct ChatPanelHeader: View {
    let chat: ChatStore

    var body: some View {
        PanelHeader(
            title: chat.headerTitle, onNewChat: { _ = chat.newChat() }, historyOpen: chat.mode == .history, onHistory: { chat.toggleHistory() }
        )
    }
}

struct ChatPanelBody: View {
    let runtime: ChatRuntime
    let shell: EdgeShellModel
    private var chat: ChatStore { runtime.chat }

    var body: some View {
        Group {
            switch chat.mode {
            case .history: history
            case .chat: conversation
            }
        }
        .accessibilityElement(children: .contain)
    }

    // MARK: 목록

    @ViewBuilder
    private var history: some View {
        switch chat.listScreen {
        case .blank:
            // 읽는 중: 아무 주장도 하지 않는다
            Color.clear.frame(height: 0)
        case .offline:
            PanelEmptyState(.offline) { tryAgain(.md) { Task { await chat.refresh() } } }
        case .failed:
            PanelEmptyState(title: ChatCopy.couldNotLoad) { tryAgain(.md) { Task { await chat.refresh() } } }
        case .ready(let problem):
            VStack(alignment: .leading, spacing: 0) {
                if let problem { problemNotice(problem, retry: { Task { await chat.refresh() } }) }
                if chat.listIsEmpty {
                    emptyHistory
                } else {
                    ChatHistory(entries: chat.entries, currentID: chat.currentID, onOpen: { chat.open($0) })
                }
            }
        }
    }

    @ViewBuilder
    private var emptyHistory: some View {
        if chat.isUnavailable {
            // 서버에서 꺼져 있다: 실패가 아니다
            PanelEmptyState(title: ChatCopy.unavailable) { tryAgain(.md) { chat.retryUnavailable() } }
        } else {
            PanelEmptyState(title: ChatCopy.noConversations) {
                Button(ChatCopy.newChat) { _ = chat.newChat() }.buttonStyle(TFButtonStyle(.secondary, size: .md))
            }
        }
    }

    // MARK: 대화

    @ViewBuilder
    private var conversation: some View {
        switch chat.screen {
        case .blank:
            Color.clear.frame(height: 0)
        case .offline:
            PanelEmptyState(.offline) { tryAgain(.md) { reloadThread() } }
        case .failed:
            PanelEmptyState(title: ChatCopy.couldNotLoadChat) { tryAgain(.md) { reloadThread() } }
        case .ready(let problem):
            if let id = chat.currentID {
                VStack(alignment: .leading, spacing: TFSpace.md) {
                    if let problem { problemNotice(problem, retry: reloadThread) }
                    if chat.needsConsent {
                        Notice(title: ChatCopy.consentNeeded) {
                            Button(ChatCopy.allowAIButton) { shell.onConnect() }.buttonStyle(TFButtonStyle(.secondary))
                        }
                    }
                    if chat.isUnavailable {
                        Notice(title: ChatCopy.unavailable) {
                            Button(ChatCopy.tryAgain) { chat.retryUnavailable() }.buttonStyle(TFButtonStyle(.secondary))
                        }
                    }
                    if !chat.isUnavailable, let project = chat.project(for: id) {
                        ProjectLink(project: project, onChange: { choice in Task { await chat.chooseProject(choice) } }, onUndo: { Task { await chat.undoProject() } })
                    }
                    ForEach(chat.turns(for: id)) { turn in
                        ChatTurnView(turn: turn, runtime: runtime, onRetry: { cmid in Task { await chat.retry(cmid) } })
                    }
                    Color.clear.frame(height: 1).id(EdgeChatScreen.bottomAnchor)
                }
                .padding(.top, TFSpace.xs)
            }
        }
    }

    private func reloadThread() {
        guard let id = chat.currentID else { return }
        Task { await chat.loadThread(id) }
    }

    private func problemNotice(_ problem: WorkLoad.Problem, retry: @escaping () -> Void) -> some View {
        Notice(title: problem == .offline ? PanelEmptyKind.offline.title : ChatCopy.couldNotLoad) {
            tryAgain(.sm, action: retry)
        }
        .padding(.bottom, TFSpace.sm)
    }

    private func tryAgain(_ size: TFButtonStyle.Size, action: @escaping () -> Void) -> some View {
        Button(ChatCopy.tryAgain, action: action).buttonStyle(TFButtonStyle(.secondary, size: size))
    }
}

/// 대화의 한 줄: 사용자 글(+상태 한 줄) 또는 Taskforce의 말(+인용 · 기억 노트)
struct ChatTurnView: View {
    let turn: ChatTurn
    let runtime: ChatRuntime
    let onRetry: (UUID) -> Void

    var body: some View {
        if turn.isUser {
            VStack(alignment: .leading, spacing: TFSpace.xs) {
                Message(isUser: true) { MessageText(turn.text, isDeleted: turn.textDeleted) }
                ChatStatusLine(status: turn.status, onRetry: { turn.clientMessageID.map(onRetry) })
            }
            .accessibilityElement(children: .contain)
        } else {
            VStack(alignment: .leading, spacing: TFSpace.sm) {
                Message(isUser: false) {
                    VStack(alignment: .leading, spacing: TFSpace.sm) {
                        MessageText(turn.text, isDeleted: turn.textDeleted)
                        ForEach(Array(turn.citations.enumerated()), id: \.offset) { _, citation in
                            CitationView(citation: citation, open: runtime.openURL)
                        }
                    }
                }
                ForEach(turn.rememberedIDs, id: \.self) { id in
                    RememberedNoteHost(id: id, memory: runtime.memory)
                }
            }
        }
    }
}

/// 답의 근거 인용: 원문 그대로, 서비스의 마크 · 원문 이름 · 시각 (밑줄 없음). Slack 연결을 끊어 지운 인용은 기존 문구로
struct CitationView: View {
    let citation: ChatCitation
    let open: (URL) -> Void

    var body: some View {
        let kind = SourceKind(rawValue: citation.sourceKind) ?? .note
        let service = SourceService.infer(externalURL: citation.externalURL, kind: kind)
        let removed = RemovedQuote.isRemoved(citation.quote)
        SourceQuote(
            service: service, place: citation.sourceTitle, time: citation.occurredAt.map { WhenText.label($0) },
            text: removed ? RemovedQuote.label : citation.quote, openTitle: service.openTitle,
            onOpen: removed ? nil : citation.externalURL.map { url in { open(url) } }
        )
    }
}

/// 답 아래 RememberedNote: `refs.memory_item_ids`가 가리키는 기억을 RLS로 읽은 지금 상태로 보인다. 성공은 서버 응답 뒤에만
struct RememberedNoteHost: View {
    let id: UUID
    let memory: MemoryStore

    var body: some View {
        switch memory.noteState(for: id) {
        case .loading:
            Color.clear.frame(height: 0)
        case .notRemembered:
            RememberedNote(content: nil, onConfirm: {}, onEdit: { _ in }, onForget: {})
        case .current(let item):
            let key = item.id
            RememberedNote(
                content: RememberedNote.Content(
                    statement: MemoryText.statement(item), meta: MemoryText.meta(item, contexts: memory.contexts, withTime: false),
                    isTentative: MemoryText.isTentative(item), canConfirm: memory.canConfirm(item), canChange: true, isBusy: memory.isBusy(key),
                    message: memory.feedback(for: key)?.text, writesUnavailable: memory.writesUnavailable
                ),
                onConfirm: { Task { await memory.confirm(key) } },
                onEdit: { text in Task { await memory.edit(key, statement: text) } },
                onForget: { Task { await memory.forget(key) } }
            )
            .id(key)
        }
    }
}

/// 패널 아래 입력칸 (대화 중일 때만). 초안은 대화마다 이 저장소의 메모리에 있고, 패널을 접거나 화면을 옮겨도 지워지지 않는다
struct ChatPanelFooter: View {
    let chat: ChatStore

    var body: some View {
        if chat.mode == .chat, let id = chat.currentID {
            Composer(
                text: Binding(get: { chat.draft(for: id) }, set: { chat.setDraft($0, for: id) }), placeholder: chat.composerPlaceholder,
                isDisabled: !chat.canCompose, isSending: chat.isSending, focusRequest: chat.focusRequest, onSubmit: { text in Task { await chat.send(text) } }
            )
            .id(id)
            .padding(EdgeInsets(top: 0, leading: TFSpace.lg, bottom: 14, trailing: TFSpace.lg))
        }
    }
}
#endif
