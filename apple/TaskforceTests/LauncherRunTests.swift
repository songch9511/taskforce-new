import AppKit
import Auth
import Carbon.HIToolbox
import Foundation
import Supabase
import Testing
@testable import Taskforce
@testable import TaskforceKit

/// Mac 런처 실행 (U2 Mac PR3): M8 Run with AI · Taskforce 갈래 · 초안 보기 · 중단 · ⌘K 항목 · 범위 Taskforce Working · 키
@Suite(.serialized)
@MainActor
struct LauncherRunTests {
    /// ⌘R로 M8, esc는 상세로 · Goal은 남는다. 빈 Goal은 Start가 꺼져 보내지 않고, ⌘↩는 보내는 동안 다시 눌러도 한 번만 보낸다. 202면 상세 · 갈래 working
    @Test func runWithAIKeepsTheGoalAndStartsOnce() async throws {
        let harness = try await RunLauncherHarness.make(toDo: ["T1", "T2"])
        let model = harness.model
        let t1 = RunLauncherHarness.actionID("T1")
        harness.select("T1")
        #expect(model.handleKey(.run(kVK_ANSI_R, [.command])))
        guard case .runWithAI(let target) = model.screen else {
            Issue.record("M8이 아님: \(model.screen)")
            return
        }
        #expect(target.action.id == t1)
        #expect(model.isSubScreen)
        #expect(model.crumb?.screen == "Run with AI")
        #expect(model.primaryAction == LauncherModel.BarAction(title: "Start", keys: "⌘↩"))
        #expect(!model.canStartRun)
        #expect(model.handleKey(.run(kVK_Return, [.command])))

        model.goal = "  초안 써 줘 "
        #expect(model.handleKey(.run(kVK_Escape)))
        #expect(model.screen == .detail(target))
        #expect(model.handleKey(.run(kVK_ANSI_R, [.command])))
        #expect(model.goal == "  초안 써 줘 ")

        await harness.router.holdCreate()
        #expect(model.handleKey(.run(kVK_Return, [.command])))
        await harness.waitUntil { await harness.router.hasHeldCreate() }
        #expect(!model.canStartRun)
        #expect(model.handleKey(.run(kVK_Return, [.command])))
        await harness.router.releaseCreate(RunLauncherHarness.runRow(1, action: t1, state: "queued"))
        await harness.waitUntil { model.screen == .detail(target) }
        #expect(await harness.router.createBodies() == [["action_id": t1.lowercased, "goal": "draft", "request": "초안 써 줘"]])
        #expect(model.lane(for: t1)?.state == .working)
        #expect(model.runAvailability(for: target) == .disabled(.alreadyRunning))
    }

    /// Start 실패: 409 → 동의 화면, 404 · 429 → 한 줄 알림 (후보 문구)
    @Test(arguments: [
        (409, #"{"error":{"code":"conflict","message":"x"}}"#, LauncherModel.Screen.consentNeeded),
        (404, #"{"error":{"code":"not_found","message":"x"}}"#, .notice("Run with AI isn't available right now.")),
        (429, #"{"error":{"code":"rate_limited","message":"x"}}"#, .notice("Too many runs. Try again later.")),
    ])
    func startFailures(_ status: Int, _ body: String, _ expected: LauncherModel.Screen) async throws {
        let harness = try await RunLauncherHarness.make(toDo: ["T1"])
        await harness.router.set(createRun: RunLauncherReply(status: status, body: body))
        harness.select("T1")
        #expect(harness.model.handleKey(.run(kVK_ANSI_R, [.command])))
        harness.model.goal = "초안"
        #expect(harness.model.handleKey(.run(kVK_Return, [.command])))
        await harness.waitUntil { harness.model.screen == expected }
    }

    /// ⌘R: 시작할 수 있는 할 일이면 M8, 아니면(Review · credits 404 · 오프라인) 다시 불러오기 (M19 Try Again)
    @Test func commandRPicksRunWithAIOrReload() async throws {
        let harness = try await RunLauncherHarness.make(reviews: ["R1"], toDo: ["T1"])
        let model = harness.model
        harness.select("R1")
        var before = await harness.router.nowRequests()
        #expect(model.handleKey(.run(kVK_ANSI_R, [.command])))
        #expect(model.screen == .list)
        await harness.waitUntil { await harness.router.nowRequests() > before }

        harness.connectivity.yield(false)
        await harness.waitUntil { model.refreshState.isOffline }
        harness.select("T1")
        before = await harness.router.nowRequests()
        #expect(model.handleKey(.run(kVK_ANSI_R, [.command])))
        #expect(model.screen == .list)

        let hidden = try await RunLauncherHarness.make(toDo: ["T1"], credits: nil)
        hidden.select("T1")
        let hiddenBefore = await hidden.router.nowRequests()
        #expect(hidden.model.handleKey(.run(kVK_ANSI_R, [.command])))
        #expect(hidden.model.screen == .list)
        await hidden.waitUntil { await hidden.router.nowRequests() > hiddenBefore }
    }

    /// 오프라인이 되면 M8의 Start가 꺼진다 (보내지 않는다)
    @Test func offlineDisablesStart() async throws {
        let harness = try await RunLauncherHarness.make(toDo: ["T1"])
        harness.select("T1")
        #expect(harness.model.handleKey(.run(kVK_ANSI_R, [.command])))
        harness.model.goal = "초안"
        #expect(harness.model.canStartRun)
        harness.connectivity.yield(false)
        await harness.waitUntil { harness.model.refreshState.isOffline }
        #expect(!harness.model.canStartRun)
        #expect(harness.model.handleKey(.run(kVK_Return, [.command])))
        try await Task.sleep(for: .milliseconds(100))
        #expect(await harness.router.createBodies().isEmpty)
    }

    /// ↩ · ⌥↩는 Goal 줄바꿈(Start 아님), 한글 조합 중 ↩ · ⌘↩는 입력기에 넘긴다
    @Test func returnInGoalIsANewlineAndCompositionIsLeftAlone() async throws {
        let harness = try await RunLauncherHarness.make(toDo: ["T1"])
        harness.select("T1")
        #expect(harness.model.handleKey(.run(kVK_ANSI_R, [.command])))
        harness.model.goal = "초안"
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.borderless], backing: .buffered, defer: false)
        let editor = NSTextView(frame: window.contentLayoutRect)
        window.contentView = editor
        window.makeFirstResponder(editor)
        #expect(harness.model.handleKey(.run(kVK_Return, window: window)))
        #expect(editor.string == "\n")
        #expect(!harness.model.handleKey(.run(kVK_Return, [.option], window: window)))
        editor.setMarkedText("ㅎ", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(!harness.model.handleKey(.run(kVK_Return, window: window)))
        #expect(!harness.model.handleKey(.run(kVK_Return, [.command], window: window)))
        try await Task.sleep(for: .milliseconds(100))
        #expect(await harness.router.createBodies().isEmpty)
        #expect(harness.model.screen.isRunWithAI)
    }

    /// ⌘.: 그 할 일의 끝나지 않은 run을 모두 멈춘다 (끝난 run은 보내지 않음). ⌘K에는 Stop Taskforce만 (Run with AI는 이미 도는 중이라 없음)
    @Test func commandPeriodStopsEveryOpenRun() async throws {
        let t1 = RunLauncherHarness.actionID("T1")
        let harness = try await RunLauncherHarness.make(toDo: ["T1"], runs: [
            RunLauncherHarness.runRow(1, action: t1, state: "running"), RunLauncherHarness.runRow(2, action: t1, state: "queued", hold: "credit"),
            RunLauncherHarness.runRow(3, action: t1, state: "done"),
        ])
        harness.select("T1")
        let target = try #require(harness.model.detailTarget)
        let taskforce = harness.model.actionGroups(for: target).last
        #expect(taskforce?.title == "Taskforce on this task")
        #expect(taskforce?.entries == [.stopTaskforce])
        #expect(harness.model.handleKey(.run(kVK_ANSI_Period, [.command])))
        await harness.waitUntil { await harness.router.stopPaths().count == 2 }
        #expect(Set(await harness.router.stopPaths()) == Set([1, 2].map { "/api/v1/runs/\(RunLauncherHarness.runID($0))/stop" }))
    }

    /// 할 일을 Delete(⌘⌫) · Done으로 옮길 때 끝나지 않은 run을 먼저 멈춘다
    @Test(arguments: [false, true])
    func deleteAndDoneStopRunsFirst(_ done: Bool) async throws {
        let t1 = RunLauncherHarness.actionID("T1")
        let harness = try await RunLauncherHarness.make(toDo: ["T1", "T2"], runs: [RunLauncherHarness.runRow(1, action: t1, state: "running")])
        harness.select("T1")
        let target = try #require(harness.model.detailTarget)
        if done {
            harness.model.setState(target.action, to: .done)
        } else {
            #expect(harness.model.handleKey(.run(kVK_Delete, [.command])))
        }
        await harness.waitUntil { await harness.router.stopPaths() == ["/api/v1/runs/\(RunLauncherHarness.runID(1))/stop"] }
    }

    /// 갈래: 멈춤 · 실패 run에도 앞서 만든 초안이 있으면 View Draft. Tab · Tab으로 버튼에 옮겨 ↩ → 초안 화면, esc → 상세, ⌘C 복사 줄
    @Test(arguments: [RunState.stopped, .failed])
    func laneShowsViewDraftAndOpensTheDraft(_ state: RunState) async throws {
        let harness = try await RunLauncherHarness.make(toDo: ["T1"])
        let model = harness.model
        let t1 = RunLauncherHarness.actionID("T1")
        let run = RunSummary(id: UUID(), actionID: t1, state: state, createdAt: Date())
        let draft = Artifact(id: UUID(), runID: run.id, stepID: UUID(), actionID: t1, title: "회신 초안", body: "본문", retainUntil: Date(), createdAt: Date())
        model.runs?.applySample(credits: .available(CreditsSummary(available: 100, reserved: 0), checkedAt: Date()), runs: [run], steps: [], drafts: [draft])
        harness.select("T1")
        let lane = try #require(model.lane(for: t1))
        #expect(lane.drafts == [draft])
        #expect(RunLaneText.make(lane, platform: .macOS)?.title == (state == .stopped ? "Stopped. No new steps will start." : "Couldn't finish the draft"))

        #expect(model.handleKey(.run(kVK_Tab)))
        #expect(model.screen.isDetail)
        #expect(model.handleKey(.run(kVK_Tab)))
        #expect(model.laneFocusTarget?.action.id == t1)
        #expect(model.primaryAction == LauncherModel.BarAction(title: "View Draft", keys: "↩"))
        #expect(model.handleKey(.run(kVK_Return)))
        guard case .draft(let target?, let shown) = model.screen else {
            Issue.record("초안이 아님: \(model.screen)")
            return
        }
        #expect(shown == draft)
        #expect(model.primaryAction == LauncherModel.BarAction(title: "Copy", keys: "⌘C"))
        #expect(model.handleKey(.run(kVK_Escape)))
        #expect(model.screen == .detail(target))
        #expect(model.laneFocusTarget == nil)
    }

    /// 초안 Copy(⌘C · 막대): 제목 + 본문을 복사하고 `Copied`를 잠깐 보인 뒤 런처를 닫는다 (사용자 결정, Raycast Copy to Clipboard).
    /// 본문을 지운 초안은 Copy가 없다
    @Test(arguments: [false, true])
    func copyDraftCopiesThenCloses(_ fromBar: Bool) async throws {
        let harness = try await RunLauncherHarness.make(toDo: ["T1"])
        let model = harness.model
        let t1 = RunLauncherHarness.actionID("T1")
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("LauncherRunTests-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        model.pasteboard = pasteboard
        var closed = 0
        model.close = { closed += 1 }
        let run = RunSummary(id: UUID(), actionID: t1, state: .done, outcome: .draftReady, createdAt: Date())
        let draft = Artifact(id: UUID(), runID: run.id, stepID: UUID(), actionID: t1, title: "회신 초안", body: "안녕하세요\n본문", retainUntil: Date(), createdAt: Date())
        model.runs?.applySample(credits: .available(CreditsSummary(available: 100, reserved: 0), checkedAt: Date()), runs: [run], steps: [], drafts: [draft])
        harness.select("T1")
        let target = try #require(model.detailTarget)
        model.openDraft(draft, for: target)
        if fromBar {
            model.performPrimary()
        } else {
            #expect(model.handleKey(.run(kVK_ANSI_C, [.command])))
        }
        #expect(pasteboard.string(forType: .string) == "회신 초안\n\n안녕하세요\n본문")
        #expect(model.screen == .done("Copied"))
        await harness.waitUntil { closed == 1 }

        let purged = Artifact(id: UUID(), runID: run.id, stepID: UUID(), actionID: t1, title: "옛 초안", body: "", retainUntil: Date(),
                              bodyPurgedAt: Date(), createdAt: Date())
        model.openDraft(purged, for: target)
        #expect(model.primaryAction == nil)
        model.copyDraft()
        #expect(model.screen == .draft(target, purged))
        #expect(pasteboard.string(forType: .string) == "회신 초안\n\n안녕하세요\n본문")
    }

    /// 초안 링크 (receipt 원문 슬립 · 앱 밖): 읽어서 초안 화면, 없으면 "Draft not found."
    @Test func artifactLinkOpensTheDraftOrSaysNotFound() async throws {
        let t1 = RunLauncherHarness.actionID("T1")
        let harness = try await RunLauncherHarness.make(toDo: ["T1"])
        await harness.router.set(artifacts: [RunLauncherHarness.artifactRow(id: RunLauncherHarness.artifactID, action: t1)])
        harness.model.open(ArtifactLink.url(for: UUID(uuidString: RunLauncherHarness.artifactID)!))
        await harness.waitUntil { if case .draft = harness.model.screen { true } else { false } }
        guard case .draft(let target, let artifact) = harness.model.screen else { return }
        #expect(target?.action.id == t1)
        #expect(artifact.title == "일정 변경 회신")

        harness.model.back()
        harness.model.open(ArtifactLink.url(for: UUID()))
        await harness.waitUntil { harness.model.screen == .notice(ArtifactLink.notFoundMessage) }
    }

    /// 할 일 행 ↩는 초안 receipt가 가장 최근 근거여도 원래 원문 (M1 `Open in Notion`), 원문 링크가 없을 때만 초안
    @Test func sourceLinkPrefersTheOriginal() {
        let notion = EvidenceLine(id: UUID(), quote: "q", sourceID: UUID(), sourceTitle: "회의록", occurredAt: Date(timeIntervalSince1970: 1),
                                  externalURL: URL(string: "https://www.notion.so/a"), service: .notion)
        let receipt = EvidenceLine(id: UUID(), quote: "초안 저장", sourceID: UUID(), sourceTitle: "초안", occurredAt: Date(timeIntervalSince1970: 2),
                                   externalURL: ArtifactLink.url(for: UUID()), service: .manual(.execution))
        #expect(LauncherModel.sourceLink(EvidenceDigest(lines: [notion, receipt])) == notion)
        #expect(LauncherModel.sourceLink(EvidenceDigest(lines: [receipt])) == receipt)
    }

    /// 범위 Taskforce Working: 끝나지 않은 run이 있는 열린 할 일 (M13 순서 · 개수). credits 404면 범위 · ⌘K 묶음 · 갈래가 없다
    @Test func taskforceWorkingScopeAndHiddenExecution() async throws {
        let t1 = RunLauncherHarness.actionID("T1")
        let harness = try await RunLauncherHarness.make(toDo: ["T1", "T2"], runs: [RunLauncherHarness.runRow(1, action: t1, state: "running")])
        let model = harness.model
        // M13 마지막 묶음: Taskforce Working → Changed Since Last Look
        #expect(model.scopeChoices == [.allTasks, .review, .inProgress, .toDo, .doneToday, .taskforceWorking, .changed])
        #expect(model.count(for: .taskforceWorking) == 1)
        model.chooseScope(.taskforceWorking)
        #expect(model.items.compactMap(\.action?.title) == ["T1"])
        // 실행을 쓸 수 없게 되면(credits 404) 범위 · Stop Taskforce가 사라지고 All Tasks로 본다
        await harness.router.set(credits: nil)
        await model.runs?.loadCredits()
        #expect(model.scope == .allTasks)
        #expect(model.items.compactMap(\.action?.title) == ["T1", "T2"])
        harness.select("T1")
        #expect(!model.canStop(try #require(model.detailTarget)))

        let hidden = try await RunLauncherHarness.make(toDo: ["T1"], credits: nil, runs: [RunLauncherHarness.runRow(1, action: t1, state: "running")])
        #expect(!hidden.model.scopeChoices.contains(.taskforceWorking))
        hidden.select("T1")
        let target = try #require(hidden.model.detailTarget)
        #expect(!hidden.model.actionGroups(for: target).contains { $0.title == "Taskforce on this task" })
        #expect(hidden.model.lane(for: t1) == nil)
        #expect(await hidden.router.paths().allSatisfy { !$0.contains("execution_") })
    }

    /// 지켜보던 run이 끝나면 `/now`를 다시 받는다 (바뀜 점은 서버 값 그대로). 런처가 숨으면 그만 본다
    @Test func finishedRunReloadsNowAndHidingStopsWatching() async throws {
        let t1 = RunLauncherHarness.actionID("T1")
        let harness = try await RunLauncherHarness.make(toDo: ["T1"], changed: ["T1"], runs: [RunLauncherHarness.runRow(1, action: t1, state: "running")])
        let model = harness.model
        model.prepareForShow()
        harness.select("T1")
        #expect(model.runSubject == t1)
        model.runs?.watch([t1])
        await harness.waitUntil { model.lane(for: t1)?.state == .working }
        let before = await harness.router.nowRequests()
        await harness.router.set(runs: [RunLauncherHarness.runRow(1, action: t1, state: "done", outcome: "draft_ready")])
        await model.runs?.refreshWatched()
        await harness.waitUntil { await harness.router.nowRequests() > before }
        #expect(model.changedIDs == [t1])
        model.didHide()
        #expect(model.runSubject == nil)
        #expect(model.runs?.watched.isEmpty == true)
    }

    /// 계정이 바뀌면 M8 · Goal · 지켜보기 · run을 비운다
    @Test func accountSwitchClearsRunScreensAndPolling() async throws {
        let t1 = RunLauncherHarness.actionID("T1")
        let harness = try await RunLauncherHarness.make(toDo: ["T1", "T2"], runs: [RunLauncherHarness.runRow(1, action: t1, state: "running")])
        let model = harness.model
        model.runs?.watch([t1])
        await harness.waitUntil { model.runs?.isPolling == true }
        harness.select("T2")
        model.openRun(try #require(model.detailTarget))
        model.goal = "초안"
        #expect(model.screen.isRunWithAI)
        try harness.switchAccount()
        #expect(model.screen == .list)
        #expect(model.runs?.watched.isEmpty == true)
        #expect(model.runs?.isPolling == false)
        #expect(model.runs?.workingActionIDs.isEmpty == true)
    }

    /// M8 · 상세를 오가도 바뀐 할 일의 seen은 떠날 때 한 번만 (U1 규칙 유지)
    @Test func seenStillGoesOnceAroundRunWithAI() async throws {
        let harness = try await RunLauncherHarness.make(toDo: ["T1", "T2"], changed: ["T1"])
        let model = harness.model
        let t1 = RunLauncherHarness.actionID("T1")
        model.prepareForShow()
        await harness.waitUntil { await harness.router.nowRequests() >= 2 }
        try await Task.sleep(for: .milliseconds(100))
        harness.select("T1")
        model.syncSeen()
        #expect(model.handleKey(.run(kVK_ANSI_R, [.command])))
        model.syncSeen()
        #expect(model.handleKey(.run(kVK_Escape)))
        model.syncSeen()
        #expect(await harness.router.seenIDs().isEmpty)
        harness.select("T2")
        model.syncSeen()
        await harness.waitUntil { await harness.router.seenIDs() == [t1] }
        model.didHide()
        try await Task.sleep(for: .milliseconds(100))
        #expect(await harness.router.seenIDs() == [t1])
    }

    /// ⌘R: 새로고침 실패 · 할 일 아닌 줄(Show N More)은 다시 불러오기, ⌘K 패널에서는 M8
    @Test func commandRInPanelAndOnOtherRows() async throws {
        let harness = try await RunLauncherHarness.make(toDo: ["T1", "T2", "T3", "T4", "T5", "T6"])
        let model = harness.model
        let more = try #require(model.items.firstIndex { if case .showMore = $0 { true } else { false } })
        model.select(more)
        var before = await harness.router.nowRequests()
        #expect(model.handleKey(.run(kVK_ANSI_R, [.command])))
        #expect(model.screen == .list)
        await harness.waitUntil { await harness.router.nowRequests() > before }

        harness.select("T1")
        model.openActions()
        #expect(model.handleKey(.run(kVK_ANSI_R, [.command])))
        #expect(model.screen.isRunWithAI)

        await harness.router.set(now: nil)
        harness.select("T1")
        await model.now?.load()
        guard case .refreshFailed = model.refreshState else {
            Issue.record("새로고침 실패가 아님: \(model.refreshState)")
            return
        }
        before = await harness.router.nowRequests()
        #expect(model.handleKey(.run(kVK_ANSI_R, [.command])))
        #expect(model.screen == .list)
        await harness.waitUntil { await harness.router.nowRequests() > before }
    }

    /// 런처를 닫으면 Goal을 지운다 (사용자 글은 메모리에만, 닫을 때까지)
    @Test func goalClearsWhenTheLauncherCloses() async throws {
        let harness = try await RunLauncherHarness.make(toDo: ["T1"])
        harness.model.prepareForShow()
        harness.select("T1")
        #expect(harness.model.handleKey(.run(kVK_ANSI_R, [.command])))
        harness.model.goal = "초안"
        harness.model.didHide()
        harness.model.prepareForShow()
        harness.select("T1")
        #expect(harness.model.handleKey(.run(kVK_ANSI_R, [.command])))
        #expect(harness.model.goal.isEmpty)
    }

    /// M8을 연 뒤 그 할 일이 사라지면(다른 기기에서 지움 · 끝냄) 새 목록이 올 때 목록으로 돌아가고 보내지 않는다
    @Test func staleTaskInRunWithAIGoesBackToTheList() async throws {
        let harness = try await RunLauncherHarness.make(toDo: ["T1", "T2"])
        harness.select("T1")
        #expect(harness.model.handleKey(.run(kVK_ANSI_R, [.command])))
        harness.model.goal = "초안"
        await harness.router.set(now: ShellNow.body(toDo: ["T2"]))
        await harness.model.now?.load()
        #expect(harness.model.screen == .list)
        #expect(!harness.model.canStartRun)
        try await Task.sleep(for: .milliseconds(100))
        #expect(await harness.router.createBodies().isEmpty)
    }

    /// 로그인 전에 받은 초안 링크(앱을 링크로 열었는데 세션을 읽는 중 · 로그아웃)는 처음 로그인하면 연다. 목록에 없는 할 일의 초안은 esc로 목록
    @Test func draftLinkBeforeSignInOpensAfterSignIn() async throws {
        let harness = try await RunLauncherHarness.make(toDo: ["T1"])
        await harness.router.set(artifacts: [RunLauncherHarness.artifactRow(id: RunLauncherHarness.artifactID, action: UUID())])
        harness.session.apply(event: .signedOut, session: nil)
        harness.model.open(ArtifactLink.url(for: UUID(uuidString: RunLauncherHarness.artifactID)!))
        #expect(harness.model.screen == .list)
        try harness.switchAccount()
        // 앱에서는 `MacAppDelegate`가 로그인 상태를 따라 부른다
        harness.model.sessionChanged()
        await harness.waitUntil { if case .draft(nil, _) = harness.model.screen { true } else { false } }
        #expect(harness.model.crumb?.task == nil)
        #expect(harness.model.handleKey(.run(kVK_Escape)))
        #expect(harness.model.screen == .list)
    }

    /// 앱을 초안 링크로 열면 초안을 목록보다 먼저 읽을 수 있다: 목록이 오면 그 할 일을 붙인다 (머리 · esc → 상세)
    @Test func draftReadBeforeTheListGetsItsTaskWhenTheListArrives() async throws {
        let t1 = RunLauncherHarness.actionID("T1")
        let harness = try await RunLauncherHarness.make(toDo: ["T1"])
        await harness.router.set(artifacts: [RunLauncherHarness.artifactRow(id: RunLauncherHarness.artifactID, action: t1)])
        await harness.router.set(now: nil)
        harness.session.apply(event: .signedOut, session: nil)
        harness.model.open(ArtifactLink.url(for: UUID(uuidString: RunLauncherHarness.artifactID)!))
        try harness.switchAccount()
        harness.model.sessionChanged()
        await harness.waitUntil { if case .draft(nil, _) = harness.model.screen { true } else { false } }
        await harness.router.set(now: ShellNow.body(toDo: ["T1"]))
        await harness.model.now?.load()
        #expect(harness.model.crumb?.task == "T1")
        #expect(harness.model.handleKey(.run(kVK_Escape)))
        #expect(harness.model.screen.isDetail)
    }

    /// 갈래 문구 (Figma M1 · M12 · M17 · 후보)와 M17 막대
    @Test func laneText() {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let utc = TimeZone(identifier: "UTC")!
        let action = UUID()
        func lane(_ state: RunLane.State, drafts: Int = 0) -> RunLane {
            let run = RunSummary(id: UUID(), actionID: action, state: .running, createdAt: now.addingTimeInterval(-600))
            let made = (0..<drafts).map { i in
                Artifact(id: UUID(), runID: run.id, stepID: UUID(), actionID: action, title: "초안 \(i)", body: "", retainUntil: now,
                         createdAt: now.addingTimeInterval(Double(-60 * i)))
            }
            return RunLane(state: state, drafts: made, run: run)
        }
        // Kit `RunLaneText`의 Mac 글 (제목 · 부제)
        struct Card: Equatable {
            let title: String
            let subtitle: String?
        }
        func card(_ lane: RunLane) -> Card? {
            RunLaneText.make(lane, platform: .macOS, now: now, timeZone: utc).map { Card(title: $0.title, subtitle: $0.subtitle) }
        }
        #expect(card(lane(.working)) == .init(title: "Writing draft", subtitle: "Started 14:03"))
        #expect(card(lane(.paused(.credit))) == .init(title: "Draft paused", subtitle: "Not enough credits. The draft will resume when credits are added."))
        #expect(card(lane(.draftReady, drafts: 1)) == .init(title: "초안 0", subtitle: "AI draft · 14:13"))
        #expect(card(lane(.draftReady, drafts: 3))?.subtitle == "3 AI drafts · 14:13")
        #expect(card(lane(.needsInput(question: nil)))?.subtitle == "Question deleted after 90 days.")
        #expect(card(lane(.needsConnection(capability: "gmail.send")))?.subtitle == "Connect Gmail to continue.")
        #expect(card(lane(.stopped(finishing: true, stoppedAt: nil))) == .init(title: "Stopped. No new steps will start.", subtitle: "Finishing the current step."))
        #expect(card(lane(.failed(.rejected)))?.subtitle == "The AI provider declined this request.")
        #expect(RunLaneText.stopRequested(lane(.stopped(finishing: false, stoppedAt: now)), now: now, timeZone: utc) == "Stop requested 14:13")
        #expect(RunLaneText.stopRequested(lane(.stopped(finishing: false, stoppedAt: nil)), now: now, timeZone: utc) == nil)
        #expect(RunLaneText.stopRequested(lane(.stopped(finishing: false, stoppedAt: now.addingTimeInterval(-86_400 * 2))), now: now, timeZone: utc)
            == "Stop requested Sep 19")
        #expect(RunLaneText.announcement(.draftReady) == "Draft ready")
        #expect(RunLaneText.announcement(.stopped(finishing: false, stoppedAt: now)) == "Stop requested")
    }
}

extension LauncherModel.Screen {
    var isRunWithAI: Bool {
        if case .runWithAI = self { true } else { false }
    }
}

extension NSEvent {
    /// 런처 키 (수정 키 · 창 지정)
    @MainActor
    static func run(_ code: Int, _ flags: NSEvent.ModifierFlags = [], window: NSWindow? = nil) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: window?.windowNumber ?? 0, context: nil,
            characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: UInt16(code)
        )!
    }
}

struct RunLauncherReply: Sendable {
    let status: Int
    let body: String
}

@MainActor
private final class RunLauncherHarness {
    let model: LauncherModel
    let session: SessionStore
    let router: RunLauncherRouter
    let connectivity: AsyncStream<Bool>.Continuation
    private let storage: RunLauncherStorage

    static let artifactID = "77777777-7777-4777-8777-777777777777"

    private init(model: LauncherModel, session: SessionStore, router: RunLauncherRouter, connectivity: AsyncStream<Bool>.Continuation, storage: RunLauncherStorage) {
        self.model = model
        self.session = session
        self.router = router
        self.connectivity = connectivity
        self.storage = storage
    }

    /// `ShellNow`의 할 일 id (To Do 행)
    static func actionID(_ title: String) -> UUID {
        let number = title.utf8.reduce(3) { ($0 &* 31 &+ Int($1)) % 1_000_000_000 }
        return UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", number))!
    }

    static func runID(_ n: Int) -> String { String(format: "55555555-5555-4555-8555-%012d", n) }

    static func runRow(_ n: Int, action: UUID, state: String, hold: String? = nil, outcome: String? = nil) -> String {
        let quoted: (String?) -> String = { $0.map { "\"\($0)\"" } ?? "null" }
        return """
        {"id":"\(runID(n))","action_id":"\(action.lowercased)","goal":"draft","state":"\(state)","hold_reason":\(quoted(hold)),\
        "outcome":\(quoted(outcome)),"budget_credits":null,"created_at":"2026-10-04T05:0\(n):00Z","stopped_at":null}
        """
    }

    static func artifactRow(id: String, action: UUID) -> String {
        """
        {"id":"\(id)","run_id":"\(runID(1))","step_id":"66666666-6666-4666-8666-666666666666","action_id":"\(action.lowercased)","kind":"draft",\
        "title":"일정 변경 회신","body":"본문","model":"m","prompt_version":"draft-v1","retain_until":"2027-01-02T05:00:00Z",\
        "body_purged_at":null,"created_at":"2026-10-04T05:01:00Z"}
        """
    }

    /// `credits`가 nil이면 404 (실행을 쓸 수 없는 계정)
    static func make(
        reviews: [String] = [], toDo: [String], changed: Set<String> = [],
        credits: String? = #"{"available":480,"reserved":0,"rate_version":"c3-v1","accepting_runs":true,"draft_estimate_credits":20}"#,
        runs: [String] = []
    ) async throws -> RunLauncherHarness {
        let user = Self.session(UUID())
        let storage = RunLauncherStorage(data: try AuthClient.Configuration.jsonEncoder.encode(user))
        let host = "supabase-\(UUID().uuidString.lowercased()).test"
        let apiHost = "api-\(UUID().uuidString.lowercased()).test"
        let router = RunLauncherRouter(now: ShellNow.body(reviews: reviews, toDo: toDo, changed: changed), credits: credits, runs: runs)
        await RunLauncherRegistry.shared.register(router, hosts: [host, apiHost])
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RunLauncherURLProtocol.self]
        let urlSession = URLSession(configuration: configuration)
        let config = AppConfig(
            supabaseURL: URL(string: "https://\(host)")!, supabaseKey: "test-key", appGroupID: "group.test.taskforce", apiBaseURL: URL(string: "https://\(apiHost)")!
        )
        let supabase = SupabaseClient(
            supabaseURL: config.supabaseURL, supabaseKey: config.supabaseKey,
            options: SupabaseClientOptions(
                auth: .init(storage: storage, autoRefreshToken: false, emitLocalSessionAsInitialSession: true), global: .init(session: urlSession)
            )
        )
        let session = SessionStore(auth: supabase.auth)
        session.apply(event: .signedIn, session: user)
        let services = AppServices(config: config, supabase: supabase, session: urlSession)
        let (stream, continuation) = AsyncStream<Bool>.makeStream()
        let saved = SavedNowStore(root: FileManager.default.temporaryDirectory.appending(path: "LauncherRun-\(UUID().uuidString)", directoryHint: .isDirectory))
        let model = LauncherModel(
            session: session, services: services, account: AccountStore(services: services, session: session), saved: saved, connectivity: stream
        )
        model.sessionChanged()
        let harness = RunLauncherHarness(model: model, session: session, router: router, connectivity: continuation, storage: storage)
        await harness.waitUntil { model.now?.loaded == true }
        if credits != nil {
            await harness.waitUntil { model.runs?.isAvailable == true }
            if !runs.isEmpty { await harness.waitUntil { model.runs?.workingActionIDs.isEmpty == false } }
        } else {
            await harness.waitUntil { model.runs?.credits == .unavailable }
        }
        return harness
    }

    func select(_ title: String) {
        // M8 · 초안 → 상세 → 목록
        for _ in 0..<3 where model.screen != .list { model.back() }
        if let index = model.items.firstIndex(where: { $0.group != nil && $0.action?.title == title }) { model.select(index) }
    }

    /// 다른 계정으로 로그인 (`onSignedOut`이 앞 계정을 비운다)
    func switchAccount() throws {
        let other = Self.session(UUID())
        try storage.store(key: "", value: try AuthClient.Configuration.jsonEncoder.encode(other))
        session.apply(event: .signedIn, session: other)
    }

    func waitUntil(_ condition: @MainActor () async -> Bool) async {
        for _ in 0..<300 {
            if await condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(await condition())
    }

    private static func session(_ userID: UUID) -> Session {
        let user = User(id: userID, appMetadata: [:], userMetadata: [:], aud: "authenticated", email: "\(userID.uuidString)@example.com",
                        createdAt: Date(), updatedAt: Date())
        return Session(accessToken: "access-\(userID)", tokenType: "bearer", expiresIn: 3600,
                       expiresAt: Date().addingTimeInterval(3600).timeIntervalSince1970, refreshToken: "refresh-\(userID)", user: user)
    }
}

private final class RunLauncherStorage: AuthLocalStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var data: Data

    init(data: Data) { self.data = data }

    func store(key: String, value: Data) throws {
        lock.lock()
        defer { lock.unlock() }
        data = value
    }

    func retrieve(key: String) throws -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return data
    }

    func remove(key: String) throws {}
}

/// 가짜 서버: `/now` · seen · credits · run 만들기(붙잡기) · 멈추기 · PostgREST 실행 표
private actor RunLauncherRouter {
    /// nil = 500 (새로고침 실패)
    private var now: Data?
    private var credits: String?
    private var runs: [String]
    private var artifacts: [String] = []
    private var createRun = RunLauncherReply(status: 500, body: "{}")
    private var holdingCreate = false
    private var heldCreate: [CheckedContinuation<RunLauncherReply, Never>] = []
    private var recorded: [(method: String, path: String, body: Data?)] = []

    init(now: Data, credits: String?, runs: [String]) {
        self.now = now
        self.credits = credits
        self.runs = runs
    }

    func set(runs: [String]) { self.runs = runs }
    func set(now: Data?) { self.now = now }
    func set(credits: String?) { self.credits = credits }
    func set(artifacts: [String]) { self.artifacts = artifacts }
    func set(createRun: RunLauncherReply) { self.createRun = createRun }
    func holdCreate() { holdingCreate = true }
    func hasHeldCreate() -> Bool { !heldCreate.isEmpty }
    func releaseCreate(_ run: String) {
        holdingCreate = false
        heldCreate.forEach { $0.resume(returning: RunLauncherReply(status: 202, body: #"{"run":\#(run)}"#)) }
        heldCreate = []
    }

    func paths() -> [String] { recorded.map(\.path) }
    func nowRequests() -> Int { recorded.filter { $0.path == "/api/v1/now" }.count }
    func stopPaths() -> [String] { recorded.map(\.path).filter { $0.hasSuffix("/stop") } }
    func seenIDs() -> [UUID] {
        recorded.filter { $0.path.hasSuffix("/seen") }.compactMap { UUID(uuidString: String($0.path.split(separator: "/")[3])) }
    }

    func createBodies() -> [[String: String]] {
        recorded.filter { $0.path == "/api/v1/runs" && $0.method == "POST" }
            .compactMap { $0.body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: String] } }
    }

    func response(method: String, path: String, query: [String: String], body: Data?) async -> RunLauncherReply {
        recorded.append((method, path, body))
        switch path {
        case "/api/v1/now":
            return now.map { RunLauncherReply(status: 200, body: String(decoding: $0, as: UTF8.self)) } ?? RunLauncherReply(status: 500, body: "{}")
        case "/api/v1/credits":
            return credits.map { RunLauncherReply(status: 200, body: $0) } ?? RunLauncherReply(status: 404, body: #"{"error":{"code":"not_found","message":"x"}}"#)
        case "/api/v1/runs":
            if holdingCreate { return await withCheckedContinuation { heldCreate.append($0) } }
            return createRun
        case _ where path.hasSuffix("/stop"):
            return RunLauncherReply(status: 200, body: #"{"run":\#(runs.first ?? "{}")}"#.replacingOccurrences(of: #""state":"running""#, with: #""state":"stopped""#))
        case _ where path.hasSuffix("/seen"):
            return RunLauncherReply(status: 204, body: "")
        case "/rest/v1/execution_runs":
            // PostgREST 흉내: state=in.(…)만 거른다
            let states = query["state"].map { $0.dropFirst(4).dropLast().split(separator: ",").map(String.init) }
            let rows = runs.filter { row in states.map { $0.contains { row.contains(#""state":"\#($0)""#) } } ?? true }
            return RunLauncherReply(status: 200, body: "[\(rows.joined(separator: ","))]")
        case "/rest/v1/execution_artifacts":
            let id = query["id"].map { String($0.dropFirst(3)) }
            let rows = artifacts.filter { row in id.map { row.contains(#""id":"\#($0)""#) } ?? true }
            return RunLauncherReply(status: 200, body: "[\(rows.joined(separator: ","))]")
        default:
            return RunLauncherReply(status: path.hasPrefix("/api/") ? 500 : 200, body: path.hasPrefix("/api/") ? "{}" : "[]")
        }
    }
}

private actor RunLauncherRegistry {
    static let shared = RunLauncherRegistry()
    private var routers: [String: RunLauncherRouter] = [:]

    func register(_ router: RunLauncherRouter, hosts: [String]) {
        for host in hosts { routers[host] = router }
    }

    func router(for host: String) -> RunLauncherRouter? { routers[host] }
}

private final class RunLauncherURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host?.hasSuffix(".test") == true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let host = url.host else { return }
        let query = Dictionary(
            (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).compactMap { item in item.value.map { (item.name, $0) } },
            uniquingKeysWith: { first, _ in first }
        )
        let method = request.httpMethod ?? "GET"
        let body = request.httpBody ?? request.httpBodyStream.map(Self.read)
        let box = RunLauncherBox(self)
        Task {
            guard let router = await RunLauncherRegistry.shared.router(for: host) else { return box.fail() }
            let reply = await router.response(method: method, path: url.path, query: query, body: body)
            box.succeed(HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!,
                        body: Data(reply.body.utf8))
        }
    }

    override func stopLoading() {}

    private static func read(_ stream: InputStream) -> Data {
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

// URLProtocolClient는 Sendable이 아니라 한 번만 쓰는 상자로 넘긴다
private final class RunLauncherBox: @unchecked Sendable {
    private var urlProtocol: RunLauncherURLProtocol?

    init(_ urlProtocol: RunLauncherURLProtocol) { self.urlProtocol = urlProtocol }

    func succeed(_ response: URLResponse, body: Data) {
        guard let urlProtocol else { return }
        self.urlProtocol = nil
        urlProtocol.client?.urlProtocol(urlProtocol, didReceive: response, cacheStoragePolicy: .notAllowed)
        urlProtocol.client?.urlProtocol(urlProtocol, didLoad: body)
        urlProtocol.client?.urlProtocolDidFinishLoading(urlProtocol)
    }

    func fail() {
        guard let urlProtocol else { return }
        self.urlProtocol = nil
        urlProtocol.client?.urlProtocol(urlProtocol, didFailWithError: URLError(.cannotFindHost))
    }
}
