#if os(macOS) && DEBUG
import Foundation
import Testing
@testable import TaskforceKit

/// 하위 에이전트 트리 T1: 파서가 `task_started`의 `parent_task_id` · `spawn_depth`를 읽고, 매퍼가 **전경 에이전트(`task_type == local_agent`)도** 판에 올린다.
/// 전경 Bash는 지금처럼 버린다. 진행(progress) 의미 · 첫 `result` 뒤 규칙 · 서버로 가는 사건은 바뀌지 않는다 (T2).
/// 실측 C1 · C3 · C4 표본은 칸만 남기고 값을 지어낸 것이다 (`AgentTreeFixtures`)
struct ClaudeSubagentStreamTests {
    typealias Fx = AgentTreeFixtures

    private func line(_ object: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
    }

    private func started(
        _ task: String = "a9999999999999999", tool: String? = "toolu_x", type: String? = "local_agent", description: String? = "Check a note", backgrounded: Bool? = true, parent: Any? = nil, depth: Any? = nil
    ) -> Data {
        var object: [String: Any] = ["type": "system", "subtype": "task_started", "task_id": task]
        if let tool { object["tool_use_id"] = tool }
        if let type { object["task_type"] = type }
        if let description { object["description"] = description }
        if let backgrounded { object["is_backgrounded"] = backgrounded }
        if let parent { object["parent_task_id"] = parent }
        if let depth { object["spawn_depth"] = depth }
        return line(object)
    }

    private func mapper() -> ClaudeEventMapper {
        ClaudeEventMapper(config: ClaudeMapperConfig(
            mode: .turn(newSessionID: nil), expectedSessionID: nil, expectedTools: nil, expectedCwd: nil, requireSessionStart: false, workspaceRealPath: "/w", versionSupported: { _ in true }
        ))
    }

    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func feed(_ lines: [Data], step: TimeInterval = 5) -> [ClaudeMapperAction] {
        var mapper = mapper()
        var actions: [ClaudeMapperAction] = []
        var now = t0
        for data in lines {
            now = now.addingTimeInterval(step)
            guard let event = ClaudeStreamParser.parse(data) else { continue }
            actions += mapper.consume(event, facts: ClaudeSpawnFacts(), now: now)
        }
        return actions
    }

    private func background(_ actions: [ClaudeMapperAction]) -> [BackgroundTaskEvent] {
        actions.compactMap { if case .backgroundTask(let event) = $0 { event } else { nil } }
    }

    private func board(_ events: [BackgroundTaskEvent]) -> BackgroundTaskList {
        var list = BackgroundTaskList()
        for (index, event) in events.enumerated() { list.apply(event, now: t0.addingTimeInterval(TimeInterval(1000 + index))) }
        return list
    }

    private func task(_ list: BackgroundTaskList, _ id: String) -> BackgroundTask? { list.tasks.first { $0.id == id } }

    // MARK: 파서

    @Test func theParserReadsTheParentAndTheSpawnDepthOfAStartedTask() {
        #expect(
            ClaudeStreamParser.parse(started("a3333333333333333", backgrounded: false, parent: "a1111111111111111", depth: 2))
                == .task(.started(taskID: "a3333333333333333", toolUseID: "toolu_x", taskType: "local_agent", description: "Check a note", isBackgrounded: false, parentTaskID: "a1111111111111111", spawnDepth: 2))
        )
        // 깊이 1의 자식은 `parent_task_id`가 없다 (세션 바로 아래)
        #expect(
            ClaudeStreamParser.parse(started(depth: 1))
                == .task(.started(taskID: "a9999999999999999", toolUseID: "toolu_x", taskType: "local_agent", description: "Check a note", isBackgrounded: true, parentTaskID: nil, spawnDepth: 1))
        )
    }

    @Test func aParentOrDepthThatBreaksTheRulesIsDroppedNotTrusted() {
        func fields(_ data: Data) -> (parent: String?, depth: Int?)? {
            guard case .task(.started(_, _, _, _, _, let parent, let depth))? = ClaudeStreamParser.parse(data) else { return nil }
            return (parent, depth)
        }
        for parent in ["", "../x", "a b", String(repeating: "z", count: 65)] as [Any] {
            #expect(fields(started(parent: parent, depth: 2))?.parent == nil, "\(parent)")
        }
        #expect(fields(started(parent: 7))?.parent == nil, "문자열이 아니다")
        for depth in [-1, 17, 1000] as [Any] {
            #expect(fields(started(depth: depth))?.depth == nil, "0–16 밖: \(depth)")
        }
        #expect(fields(started(depth: 0))?.depth == 0 && fields(started(depth: 16))?.depth == 16)
        #expect(fields(started(depth: 1.5))?.depth == nil, "정수가 아니다")
        #expect(fields(started(depth: "2"))?.depth == nil, "문자열이다")
        #expect(fields(started(depth: true))?.depth == nil, "불리언이다")
    }

    @Test func thePromptOfASpawnIsNotDeclaredSoItNeverReachesAValue() {
        var object: [String: Any] = ["type": "system", "subtype": "task_started", "task_id": "a9999999999999999", "task_type": "local_agent", "is_backgrounded": true, "spawn_depth": 1]
        object["prompt"] = "SENTINEL-AGENT-PROMPT-TEXT secret=hunter2"
        let event = ClaudeStreamParser.parse(line(object))
        let dump = String(reflecting: event as Any)
        #expect(!dump.contains("SENTINEL-AGENT-PROMPT-TEXT") && !dump.contains("hunter2"))
    }

    // MARK: 매퍼: 전경 에이전트

    @Test func aForegroundAgentIsKeptOnTheBoardWithItsParentAndDepth() {
        let actions = feed([
            line(["type": "assistant", "message": ["id": "m1", "model": "claude-fixture", "content": [["type": "tool_use", "id": "toolu_n", "name": "Agent", "input": ["description": "Check a nested note"]]]]]),
            started("a3333333333333333", tool: "toolu_n", description: "Check a nested note", backgrounded: false, parent: "a1111111111111111", depth: 2),
        ])
        #expect(background(actions) == [
            .started(taskID: "a3333333333333333", toolUseID: "toolu_n", kind: .agent, name: "Check a nested note", at: t0.addingTimeInterval(10), parentID: "a1111111111111111", depth: 2, foreground: true)
        ])
    }

    @Test func aForegroundBashIsStillIgnoredAsBefore() {
        let actions = feed([
            started("bk1abc9xy", tool: "toolu_b", type: "local_bash", description: "Run it", backgrounded: false, depth: 1),
            line(["type": "system", "subtype": "task_updated", "task_id": "bk1abc9xy", "patch": ["status": "completed", "end_time": 1_800_000_060_000]]),
            line(["type": "system", "subtype": "task_notification", "task_id": "bk1abc9xy", "status": "completed"]),
        ])
        #expect(background(actions).isEmpty, "전경 명령의 시작 · 끝은 판에 오르지 않는다")
    }

    @Test func aBackgroundAgentCarriesItsDepthAndIsNotForeground() {
        let actions = feed([started("a1111111111111111", backgrounded: true, depth: 1)])
        guard case .started(_, _, let kind, _, _, let parent, let depth, let foreground)? = background(actions).first else {
            Issue.record("시작 사건이 아니다")
            return
        }
        #expect(kind == .agent && parent == nil && depth == 1 && foreground == false)
    }

    @Test func theProgressMeaningOfTaskLinesIsUnchanged() {
        // 시작 · 알림은 진행 신호로 센다, 나머지(진행 · 갱신 · 목록)는 아니다: 전경 에이전트를 판에 올려도 그대로다
        let actions = feed([
            started("a3333333333333333", backgrounded: false, parent: "a1111111111111111", depth: 2),
            line(["type": "system", "subtype": "task_updated", "task_id": "a3333333333333333", "patch": ["status": "completed", "end_time": 1_800_000_060_000]]),
            line(["type": "system", "subtype": "task_notification", "task_id": "a3333333333333333", "status": "completed"]),
        ], step: 0.5)
        let progresses = actions.filter { if case .emit(.progress) = $0 { true } else { false } }.count
        #expect(progresses == 1, "2초에 하나로 묶인다: 시작이 하나 센다")
        let nothingForTheServer = actions.filter { if case .emit(let event) = $0 { event != .progress } else { false } }
        #expect(nothingForTheServer.isEmpty, "서버로 가는 사건은 늘지 않는다")
    }

    // MARK: 실측 표본 C1 · C3 · C4

    @Test func c1TwoConcurrentBackgroundChildrenBothEndDoneAndStayUnderTheSession() {
        let events = background(feed(Fx.c1))
        let list = board(events)
        #expect(list.tasks.count == 2)
        for (id, name) in [(Fx.a, Fx.nameA), (Fx.b, Fx.nameB)] {
            let found = task(list, id)
            #expect(found?.status == .done && found?.kind == .agent && found?.name == name, "\(id)")
            #expect(found?.parentID == nil && found?.depth == 1 && found?.foreground == false)
        }
        // 스냅샷이 시작 줄보다 먼저 와도 시작 줄이 부모 · 깊이 · 이름을 채운다
        #expect(task(list, Fx.a)?.toolUseID == Fx.toolA)
    }

    @Test func c3ANestedForegroundChildKeepsRunningThroughTheSnapshotAndHangsUnderItsParent() {
        let all = feed(Fx.c3)
        // b가 끝난 뒤의 스냅샷 `[a]`까지 먹이면: nested는 스냅샷에 없지만 전경이라 멈추지 않는다
        let early = board(background(feed(Array(Fx.c3.prefix(Fx.c3IndexOfSnapshotAfterBFinished + 1)))))
        #expect(task(early, Fx.nested)?.status == .running && task(early, Fx.nested)?.foreground == true)
        #expect(task(early, Fx.nested)?.parentID == Fx.a && task(early, Fx.nested)?.depth == 2)
        #expect(task(early, Fx.b)?.status == .done && task(early, Fx.a)?.status == .running)
        // 끝까지 먹이면 모두 끝난다
        let list = board(background(all))
        #expect(list.tasks.count == 3)
        #expect(list.tasks.allSatisfy { $0.status == .done })
        #expect(task(list, Fx.nested)?.name == Fx.nameNested)
        // 마지막 빈 스냅샷은 이미 끝난 일을 되돌리지 않는다
        #expect(task(list, Fx.a)?.parentID == nil && task(list, Fx.b)?.parentID == nil)
    }

    @Test func c3TheTreeThatTheBoardHoldsIsTheProvidersTree() {
        let list = board(background(feed(Array(Fx.c3.prefix(Fx.c3IndexOfSnapshotAfterBFinished + 1)))))
        let rows = SubagentTree.rows(for: list, expansion: SubagentTreeExpansion())
        // 도는 a (자식 nested 하나) → a 바로 아래 nested, 끝난 b는 그 뒤. 선은 `parent_task_id` 하나뿐이다
        #expect(rows.map(\.task.id) == [Fx.a, Fx.nested, Fx.b])
        #expect(rows.map(\.level) == [0, 1, 0])
    }

    @Test func c4AForegroundChildKilledByTheStopEndsStoppedAndNeverDone() {
        let list = board(background(feed(Fx.c4)))
        let found = task(list, Fx.foreground)
        #expect(list.tasks.count == 1)
        #expect(found?.status == .stopped && found?.foreground == true && found?.depth == 1 && found?.parentID == nil)
        #expect(found?.endedAt == Date(timeIntervalSince1970: 1_800_000_030), "`task_updated`의 끝 시각이 이긴다")
    }

    @Test func aForegroundChildWithoutAnyEndIsStoppedOnlyWhenTheProcessIsCollected() {
        // 스냅샷은 전경 일을 멈추지 않는다. 끝 알림이 없으면 프로세스를 거둘 때(`BackgroundTaskBoard.stopRunning`)만 Stopped가 된다
        let boardStore = BackgroundTaskBoard()
        for event in background(feed(Array(Fx.c3.prefix(9)))) { boardStore.apply(event, session: "s", now: t0) }
        boardStore.apply(.snapshot(runningTaskIDs: []), session: "s", now: t0.addingTimeInterval(100))
        let afterSnapshot = boardStore.tasks(session: "s")
        #expect(task(afterSnapshot, Fx.nested)?.status == .running, "빈 스냅샷에도 전경 일은 그대로")
        #expect(task(afterSnapshot, Fx.a)?.status == .stopped && task(afterSnapshot, Fx.b)?.status == .stopped, "백그라운드 일은 스냅샷에 없으면 멈춘다")
        boardStore.stopRunning(ids: [Fx.nested], session: "s", now: t0.addingTimeInterval(200))
        #expect(task(boardStore.tasks(session: "s"), Fx.nested)?.status == .stopped)
    }

    // MARK: 값이 글을 담지 않는다

    @Test func theMappedEventsAndTheListNeverCarryThePromptSummaryPathOrId() {
        let events = background(feed(Fx.c3))
        let dump = String(reflecting: events) + String(reflecting: board(events))
        #expect(!dump.contains("prompt") && !dump.contains("/Users") && !dump.contains("/private"))
        #expect(String(describing: board(events)) == "BackgroundTaskList()")
    }
}
#endif
