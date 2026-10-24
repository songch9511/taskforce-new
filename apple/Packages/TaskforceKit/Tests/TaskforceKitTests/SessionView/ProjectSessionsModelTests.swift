#if os(macOS) && DEBUG
import Foundation
import Testing
@testable import TaskforceKit

/// 열 때 한 번 닫을 때까지 쥐고 있는 문 (읽기가 아직 끝나지 않은 순간을 만든다)
final class ProjectSessionsGate: @unchecked Sendable {
    private let lock = NSLock()
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private var isOpen = true

    func close() { lock.withLock { isOpen = false } }

    func open() {
        let pending = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            isOpen = true
            defer { waiting = [] }
            return waiting
        }
        for continuation in pending { continuation.resume() }
    }

    func pass() async {
        if lock.withLock({ isOpen }) { return }
        await withCheckedContinuation { continuation in
            let resumeNow = lock.withLock { () -> Bool in
                if isOpen { return true }
                waiting.append(continuation)
                return false
            }
            if resumeNow { continuation.resume() }
        }
    }
}

/// 프로젝트 화면의 Sessions 묶음 상태(에이전트 트리 T3m): 그리는 동안은 파일을 읽지 않고, 사용자가 세션 행을 펼칠 때 **그 세션 하나만** 기록을 한 번 읽는다 (30초 안에 다시 펴면 다시 읽지 않는다).
/// 이 Mac에서 도는 세션은 판(`BackgroundTaskBoard`)의 값을 먼저 쓴다. 읽기는 가짜 면(`ClaudeAppTranscriptScript`)이고 실제 기록 · 서버는 열지 않는다
@MainActor
struct ProjectSessionsModelTests {
    typealias Fx = SessionFx
    typealias S = ClaudeAppTranscriptScript

    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    /// 시험 장치: 세션마다 가짜 면 하나, 찾기 횟수, 손으로 흘리는 시계, 문
    @MainActor
    final class Rig {
        let board = BackgroundTaskBoard()
        let clock = ClaudeAppClock()
        let gate = ProjectSessionsGate()
        let scripts = ScriptBook()
        var finds = 0
        var unreadable: Set<UUID> = []
        let model: ProjectSessionsModel

        final class ScriptBook: @unchecked Sendable {
            private let lock = NSLock()
            private var byProvider: [String: ClaudeAppTranscriptScript] = [:]
            func script(_ provider: String) -> ClaudeAppTranscriptScript {
                lock.withLock {
                    if let found = byProvider[provider] { return found }
                    let made = ClaudeAppTranscriptScript()
                    byProvider[provider] = made
                    return made
                }
            }
            var all: [ClaudeAppTranscriptScript] { lock.withLock { Array(byProvider.values) } }
        }

        static func provider(_ id: UUID) -> String { "claude-\(id.uuidString.lowercased())" }

        init(metrics: AgentTreeMetrics? = nil) {
            let clock = clock
            model = ProjectSessionsModel(uptime: { clock.uptime }, metrics: metrics)
            let scripts = scripts
            model.connect(
                board: board,
                findTarget: { [unowned self] id in
                    finds += 1
                    await gate.pass()
                    return unreadable.contains(id) ? nil : AgentLocalTranscriptTarget(providerSessionID: Self.provider(id), cwd: "/Users/tester/proj")
                },
                makeSource: { provider, _ in scripts.script(provider) }
            )
        }

        func script(for id: UUID) -> ClaudeAppTranscriptScript { scripts.script(Self.provider(id)) }

        func eventually(_ condition: @MainActor () -> Bool) async -> Bool {
            let deadline = ContinuousClock.now.advanced(by: .seconds(2))
            while !condition() {
                if ContinuousClock.now > deadline { return false }
                try? await Task.sleep(for: .milliseconds(5))
            }
            return true
        }
    }

    private func item(_ n: Int, agent: AgentMarkKind = .claudeCode, closed: Bool = false) -> AgentSessionItem {
        AgentSessionItem(
            id: Fx.id(n), name: "S\(n)", agent: agent, agentName: agent == .codex ? "Codex" : "Claude Code", connectionID: Fx.claudeConnection, status: closed ? .closed : .bound,
            ring: closed ? nil : .running, line: closed ? "" : "Running", createdAt: Fx.at(Double(n)), updatedAt: Fx.at(Double(n) + 500), issueIDs: [Fx.issue(1)], currentIssueID: Fx.issue(1),
            conversationID: nil, hasOpenTask: false, pill: nil
        )
    }

    /// 본 기록에 에이전트 하나(`root`)가 백그라운드로 시작했고, 메타에 그 자식 둘이 있는 세션
    private func family(_ script: S, root: String = "root", children: [String] = ["c1", "c2"], running: [String] = []) {
        var cursor = ClaudeAppTranscriptCursor(sessionID: ExternalSessionFixture.uuid(0xF1))
        // 도는 자식은 본 기록의 시작 줄로 (상태를 안다), 메타뿐인 자식은 상태 없이 보인다
        let started = [BackgroundTaskEvent.started(taskID: root, toolUseID: nil, kind: .agent, name: "Research", at: t0, parentID: nil, depth: 1, foreground: false)]
            + running.map { .started(taskID: $0, toolUseID: nil, kind: .agent, name: "Running \($0)", at: t0, parentID: root, depth: 2, foreground: false) }
        cursor.signals = ClaudeAppTranscriptSignals(failedToolIDs: [], background: started, toolOutcomes: [])
        script.queueOpen(.page(ClaudeAppTranscriptPage(turns: [S.turn(1)], cursor: cursor, hasEarlier: false, skippedLines: 0)))
        let metas = children.map { SubagentMeta(id: $0, parentID: root, depth: 2, name: "Child \($0)", requestShape: nil, toolUseID: nil) }
        script.queueSubagents(.metas(metas, cursor: SubagentCursor(project: "-Users-tester-proj", stamp: t0)))
    }

    private func ids(_ rows: [SubagentTreeRow]) -> [String] { rows.map(\.task.id) }

    // MARK: 그리는 동안은 읽지 않는다

    @Test func drawingTheListNeverReadsATranscriptOrLooksUpATarget() {
        let rig = Rig()
        let sessions = (1...5).map { item($0) }
        for session in sessions { family(rig.script(for: session.id)) }
        for _ in 0..<20 {
            for session in sessions {
                _ = rig.model.rows(of: session)
                _ = rig.model.collapsedSummary(of: session)
                _ = rig.model.isExpanded(session.id)
                _ = rig.model.canExpand(session)
            }
            rig.model.syncBoard()
        }
        #expect(rig.finds == 0, "목록을 그릴 때 기록 위치를 찾지 않는다")
        #expect(rig.scripts.all.allSatisfy { $0.openCalls == 0 && $0.subagentCalls == 0 && $0.newerCalls == 0 }, "기록 파일 읽기 0")
    }

    @Test func aCollapsedRowShowsOnlyWhatTheBoardAlreadyKnows() {
        let rig = Rig()
        let session = item(1)
        #expect(rig.model.collapsedSummary(of: session) == nil, "판에 없으면 아무것도 보이지 않는다")
        let key = session.id.uuidString.lowercased()
        rig.board.apply(.started(taskID: "r1", toolUseID: nil, kind: .agent, name: "A", at: t0, parentID: nil, depth: 1, foreground: false), session: key)
        rig.board.apply(.started(taskID: "r2", toolUseID: nil, kind: .agent, name: "B", at: t0, parentID: "r1", depth: 2, foreground: true), session: key)
        #expect(rig.model.collapsedSummary(of: session) == "Running 2")
        #expect(rig.model.collapsedSummary(of: item(2)) == nil, "다른 세션의 판 값은 섞이지 않는다")
        #expect(rig.finds == 0 && rig.scripts.all.isEmpty, "판을 읽을 뿐 기록은 열지 않는다")
    }

    @Test func aClosedSessionShowsNoRunningSummaryAndItsTasksAreStopped() {
        let rig = Rig()
        let session = item(1, closed: true)
        let key = session.id.uuidString.lowercased()
        rig.board.apply(.started(taskID: "r1", toolUseID: nil, kind: .agent, name: "A", at: t0, parentID: nil, depth: 1, foreground: false), session: key)
        #expect(rig.model.collapsedSummary(of: session) == nil, "닫힌 세션의 일은 도는 중이 아니다")
        rig.model.toggle(session)
        let rows = rig.model.rows(of: session)
        #expect(rows.map(\.task.status) == [.stopped], "펼쳐도 Stopped로 보인다")
        #expect(rows.first?.task.endedAt == session.updatedAt, "끝난 때는 세션이 마지막으로 바뀐 때로 고정한다 (그릴 때마다 흘러가지 않는다)")
    }

    // MARK: 펼칠 때만, 그 세션 하나만

    @Test func expandingReadsOnlyThatSessionOnceAndShowsItsTree() async {
        let rig = Rig()
        let a = item(1), b = item(2)
        family(rig.script(for: a.id))
        family(rig.script(for: b.id))
        rig.model.toggle(a)
        #expect(rig.model.isExpanded(a.id) && !rig.model.isExpanded(b.id))
        #expect(await rig.eventually { rig.model.rows(of: a).count == 3 })
        #expect(ids(rig.model.rows(of: a)) == ["root", "c1", "c2"], "부모 아래 자식 둘 (메타뿐인 자식은 상태 없이)")
        let read = rig.script(for: a.id)
        #expect(read.openCalls == 1 && read.subagentCalls == 1, "본 기록 한 번 · 메타 훑기 한 번")
        #expect(read.newerCalls == 0, "꼬리를 따라가지 않는다 (한 번 읽고 끝)")
        #expect(read.calledOnMain == false, "기록 읽기는 메인 밖에서 한다")
        #expect(rig.finds == 1, "이 세션 하나만 찾았다")
        #expect(rig.script(for: b.id).openCalls == 0 && rig.model.rows(of: b).isEmpty, "다른 세션은 읽지 않는다")
    }

    @Test func foldingAndUnfoldingWithinThirtySecondsDoesNotReadAgainButAfterThirtySecondsItDoes() async {
        let rig = Rig()
        let a = item(1)
        family(rig.script(for: a.id))
        rig.model.toggle(a)
        #expect(await rig.eventually { rig.model.rows(of: a).count == 3 })
        rig.model.toggle(a)
        #expect(rig.model.rows(of: a).isEmpty && !rig.model.isExpanded(a.id), "접으면 줄이 없다")
        rig.clock.advance(29)
        rig.model.toggle(a)
        try? await Task.sleep(for: .milliseconds(60))
        #expect(rig.model.rows(of: a).count == 3, "읽어 둔 트리가 바로 보인다")
        #expect(rig.finds == 1 && rig.script(for: a.id).openCalls == 1, "29초 만에 다시 폈다: 다시 읽지 않는다")
        rig.model.toggle(a)
        rig.clock.advance(2)
        family(rig.script(for: a.id), children: ["c1", "c2", "c3"])
        rig.model.toggle(a)
        #expect(await rig.eventually { rig.model.rows(of: a).count == 4 }, "처음 읽은 지 31초가 지나 다시 폈다: 다시 읽고 새 자식이 보인다")
        #expect(rig.finds == 2 && rig.script(for: a.id).openCalls == 2)
    }

    @Test func expandingAgainWhileTheFirstReadIsStillRunningStartsNoSecondRead() async {
        let rig = Rig()
        let a = item(1)
        family(rig.script(for: a.id))
        rig.gate.close()
        rig.model.toggle(a)
        #expect(await rig.eventually { rig.finds == 1 })
        rig.model.toggle(a)
        rig.model.toggle(a)
        rig.model.toggle(a)
        rig.model.toggle(a)
        try? await Task.sleep(for: .milliseconds(40))
        #expect(rig.finds == 1, "읽는 중에 접었다 폈다 해도 읽기는 하나")
        rig.gate.open()
        #expect(await rig.eventually { rig.model.rows(of: a).count == 3 })
        #expect(rig.script(for: a.id).openCalls == 1)
    }

    @Test func aSessionThisMacCannotReadShowsNothingAndStillCountsAsReadForThirtySeconds() async {
        let rig = Rig()
        let a = item(1)
        rig.unreadable = [a.id]
        rig.model.toggle(a)
        #expect(await rig.eventually { rig.finds == 1 })
        try? await Task.sleep(for: .milliseconds(30))
        #expect(rig.model.rows(of: a).isEmpty && rig.model.isExpanded(a.id), "펼쳤지만 보일 자식이 없다 (안내 글도 없다)")
        rig.model.toggle(a)
        rig.model.toggle(a)
        try? await Task.sleep(for: .milliseconds(30))
        #expect(rig.finds == 1, "30초 안에는 다시 찾지 않는다")
        #expect(rig.scripts.all.isEmpty, "위치를 몰라 기록은 열지도 않았다")
    }

    @Test func aTranscriptThatCannotBeOpenedShowsNothing() async {
        let rig = Rig()
        let a = item(1)
        rig.model.toggle(a)
        #expect(await rig.eventually { rig.script(for: a.id).openCalls == 1 })
        try? await Task.sleep(for: .milliseconds(30))
        #expect(rig.model.rows(of: a).isEmpty)
    }

    // MARK: 판이 먼저, 기록은 거기에 더한다

    @Test func theBoardsValuesShowAtOnceAndTheTranscriptIsAddedWhenTheReadFinishes() async {
        let rig = Rig()
        let a = item(1)
        family(rig.script(for: a.id))
        let key = a.id.uuidString.lowercased()
        rig.board.apply(.started(taskID: "live", toolUseID: nil, kind: .agent, name: "Live one", at: t0, parentID: nil, depth: 1, foreground: false), session: key)
        rig.gate.close()
        rig.model.toggle(a)
        #expect(await rig.eventually { rig.finds == 1 })
        #expect(ids(rig.model.rows(of: a)) == ["live"], "읽는 중에도 판의 값은 바로 보인다")
        rig.gate.open()
        #expect(await rig.eventually { rig.model.rows(of: a).count == 4 })
        #expect(Set(ids(rig.model.rows(of: a))) == ["live", "root", "c1", "c2"])
    }

    @Test func aBoardChangeIsNoticedBySyncingTheBoardVersionOnlyWhenItMoved() {
        let rig = Rig()
        let before = rig.model.boardVersion
        rig.model.syncBoard()
        #expect(rig.model.boardVersion == before, "판이 그대로면 아무것도 바뀌지 않는다")
        rig.board.apply(.started(taskID: "r1", toolUseID: nil, kind: .agent, name: "A", at: t0, parentID: nil, depth: 1, foreground: false), session: "s")
        rig.model.syncBoard()
        #expect(rig.model.boardVersion != before, "판이 바뀌었다")
    }

    // MARK: 접기 · 펴기 선택

    @Test func branchChoicesArePerSessionSurviveReadsAndAreForgottenWithTheTask() async {
        let rig = Rig()
        let a = item(1), b = item(2)
        family(rig.script(for: a.id), children: [], running: ["c1"])
        family(rig.script(for: b.id), children: [], running: ["c1"])
        rig.model.toggle(a)
        rig.model.toggle(b)
        #expect(await rig.eventually { rig.model.rows(of: a).count == 2 && rig.model.rows(of: b).count == 2 })
        rig.model.toggleBranch("root", level: 0, in: a.id)
        #expect(ids(rig.model.rows(of: a)) == ["root"] && rig.model.rows(of: a).first?.isExpanded == false, "a의 root를 접었다")
        #expect(rig.model.rows(of: b).count == 2, "b는 그대로")
        #expect(rig.model.rows(of: a).first?.branchSummary == "Running 1", "접힌 분기의 끝 글: 기존 낱말과 숫자뿐")
        rig.model.toggle(a)
        rig.clock.advance(40)
        family(rig.script(for: a.id), children: [], running: ["c1", "c2"])
        rig.model.toggle(a)
        #expect(await rig.eventually { rig.script(for: a.id).openCalls == 2 })
        #expect(await rig.eventually { rig.model.rows(of: a).first?.branchSummary == "Running 2" }, "다시 읽어도 접어 둔 분기는 접혀 있다")
    }

    @Test func aLongTreeIsCutAtTheWindowAndShowAllOpensItUp() async {
        let rig = Rig()
        let a = item(1)
        let many = (0..<(ProjectSessions.treeRowWindow + 30)).map { "k\($0)" }
        family(rig.script(for: a.id), children: many)
        rig.model.toggle(a)
        #expect(await rig.eventually { rig.model.rows(of: a).count == many.count + 1 })
        #expect(rig.model.visibleRows(of: a).rows.count == ProjectSessions.treeRowWindow && rig.model.visibleRows(of: a).isCut)
        rig.model.toggleShowAll(a.id)
        #expect(rig.model.visibleRows(of: a).rows.count == many.count + 1 && rig.model.showsAll(a.id))
        rig.model.toggleShowAll(a.id)
        #expect(rig.model.visibleRows(of: a).rows.count == ProjectSessions.treeRowWindow)
    }

    @Test func onlyClaudeCodeSessionsHaveATreeToOpen() {
        let rig = Rig()
        #expect(rig.model.canExpand(item(1)))
        #expect(!rig.model.canExpand(item(2, agent: .codex)), "Codex는 아직 트리가 없다")
        rig.model.toggle(item(2, agent: .codex))
        #expect(!rig.model.isExpanded(Fx.id(2)), "트리가 없는 세션은 펼쳐지지 않는다")
        #expect(rig.finds == 0)
    }

    // MARK: 계정이 바뀌면 비운다

    @Test func clearingForgetsExpansionsTreesAndChoicesAndDropsALateRead() async {
        let rig = Rig()
        let a = item(1)
        family(rig.script(for: a.id))
        rig.model.toggle(a)
        #expect(await rig.eventually { rig.model.rows(of: a).count == 3 })
        rig.model.toggleBranch("root", level: 0, in: a.id)
        rig.model.clear()
        #expect(!rig.model.isExpanded(a.id) && rig.model.rows(of: a).isEmpty)
        family(rig.script(for: a.id))
        rig.model.toggle(a)
        #expect(await rig.eventually { rig.model.rows(of: a).count == 3 }, "지운 뒤에는 읽은 적 없는 것으로: 다시 읽고 기본 모양(펼침)으로 돌아온다")
        #expect(rig.finds == 2)

        // 읽는 중에 계정이 떠났다: 늦게 돌아온 읽기는 새 계정의 상태가 되지 않는다
        let late = Rig()
        let b = item(2)
        family(late.script(for: b.id))
        late.gate.close()
        late.model.toggle(b)
        #expect(await late.eventually { late.finds == 1 })
        late.model.clear()
        late.gate.open()
        try? await Task.sleep(for: .milliseconds(60))
        #expect(late.model.rows(of: b).isEmpty && !late.model.isExpanded(b.id))
        #expect(late.script(for: b.id).openCalls == 0, "옛 계정 때 시작한 읽기는 기록을 열지도 않는다")
    }

    // MARK: 열기 지표: 한 번만

    private func metrics(_ shown: ClaudeAppSendScript, _ opened: ClaudeAppSendScript, clock: ClaudeAppClock = ClaudeAppClock()) -> AgentTreeMetrics {
        AgentTreeMetrics(
            projectSessions: AgentTreeOpenedMetric(send: shown.send, now: { clock.now }), subagentRow: AgentTreeOpenedMetric(send: opened.send, now: { clock.now })
        )
    }

    @Test func theGroupShownMetricIsSentOnceNoMatterHowOftenTheGroupAppears() async {
        let shown = ClaudeAppSendScript(), opened = ClaudeAppSendScript()
        let rig = Rig(metrics: metrics(shown, opened))
        rig.model.noteGroupShown(rows: 0)
        try? await Task.sleep(for: .milliseconds(30))
        #expect(shown.calls == 0, "행이 하나도 없으면 보내지 않는다")
        for _ in 0..<6 { rig.model.noteGroupShown(rows: 3) }
        #expect(await rig.eventually { shown.calls == 1 })
        try? await Task.sleep(for: .milliseconds(40))
        #expect(shown.calls == 1, "여러 번 그려져도 한 번")
        #expect(opened.calls == 0, "자식 줄 지표는 다른 종류다")
    }

    @Test func openingAChildRowSendsTheSubagentMetricOnce() async {
        let shown = ClaudeAppSendScript(), opened = ClaudeAppSendScript()
        let rig = Rig(metrics: metrics(shown, opened))
        for _ in 0..<4 { rig.model.noteSubagentOpened() }
        #expect(await rig.eventually { opened.calls == 1 })
        try? await Task.sleep(for: .milliseconds(40))
        #expect(opened.calls == 1 && shown.calls == 0)
    }

    @Test func withoutMetricsNothingIsSentAndNothingBreaks() {
        let rig = Rig()
        rig.model.noteGroupShown(rows: 3)
        rig.model.noteSubagentOpened()
    }
}
#endif
