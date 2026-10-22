#if os(macOS) && DEBUG
import Foundation
import Testing
import TaskforceAgentWire
@testable import TaskforceKit

/// 어댑터가 읽는 stream-json의 `task_*` 줄과 `background_tasks_changed` (DZ v2 · BG-5): 아이디 · 종류 · 설명 · 상태 · 끝낸 코드 · 시각만 꺼내 로컬 목록에 먹인다.
/// **명령 글은 이름이 되지 않는다**: `description`은 모델이 안 쓰면 명령 글 자체이므로, 그 도구 호출의 `input.description`(모델이 쓴 글)과 같을 때만 이름으로 쓴다.
/// 서버로 가는 사건 · 기존 `progress` 간격 · 자체 점검은 그대로다 (이 사건들은 로컬 전용이다)
struct ClaudeBackgroundTaskStreamTests {
    static let commandSentinel = "SENTINEL-STREAM-SHELL-COMMAND secret=hunter2"

    private func line(_ object: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
    }

    private func started(_ task: String = "bk1abc9xy", tool: String? = "toolu_b", type: String? = "local_bash", description: String? = "Run the dev server", backgrounded: Bool? = true) -> Data {
        var object: [String: Any] = ["type": "system", "subtype": "task_started", "task_id": task, "uuid": "u", "session_id": "s"]
        if let tool { object["tool_use_id"] = tool }
        if let type { object["task_type"] = type }
        if let description { object["description"] = description }
        if let backgrounded { object["is_backgrounded"] = backgrounded }
        return line(object)
    }

    private func notification(_ task: String = "bk1abc9xy", status: String?, summary: String = "Background command \"x\" completed (exit code 0)") -> Data {
        var object: [String: Any] = ["type": "system", "subtype": "task_notification", "task_id": task, "tool_use_id": "toolu_b", "output_file": "/private/tmp/x", "summary": summary, "session_id": "s"]
        if let status { object["status"] = status }
        return line(object)
    }

    private func assistantTool(id: String = "toolu_b", name: String = "Bash", input: [String: Any]) -> Data {
        line([
            "type": "assistant", "session_id": "s",
            "message": ["id": "msg_1", "model": "claude-fixture", "role": "assistant", "content": [["type": "tool_use", "id": id, "name": name, "input": input]]],
        ])
    }

    private func mapper() -> ClaudeEventMapper {
        ClaudeEventMapper(config: ClaudeMapperConfig(
            mode: .turn(newSessionID: nil), expectedSessionID: nil, expectedTools: nil, expectedCwd: nil, requireSessionStart: false, workspaceRealPath: "/w", versionSupported: { _ in true }
        ))
    }

    private func feed(_ lines: [Data], at start: Date = Date(timeIntervalSince1970: 1_800_000_000), step: TimeInterval = 5) -> [ClaudeMapperAction] {
        var mapper = mapper()
        var actions: [ClaudeMapperAction] = []
        var now = start
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

    private func progresses(_ actions: [ClaudeMapperAction]) -> Int {
        actions.filter { if case .emit(.progress) = $0 { true } else { false } }.count
    }

    // MARK: 파서

    @Test func theParserReadsTheFieldsOfEveryTaskLine() {
        #expect(ClaudeStreamParser.parse(started()) == .task(.started(taskID: "bk1abc9xy", toolUseID: "toolu_b", taskType: "local_bash", description: "Run the dev server", isBackgrounded: true)))
        #expect(ClaudeStreamParser.parse(started(tool: nil, type: nil, description: nil, backgrounded: nil)) == .task(.started(taskID: "bk1abc9xy", toolUseID: nil, taskType: nil, description: nil, isBackgrounded: nil)))
        let progress = line(["type": "system", "subtype": "task_progress", "task_id": "a02862466294fcd8e", "description": "x", "last_tool_name": "Read", "usage": ["total_tokens": 5, "tool_uses": 1, "duration_ms": 9]])
        #expect(ClaudeStreamParser.parse(progress) == .task(.progress(taskID: "a02862466294fcd8e")))
        let updated = line(["type": "system", "subtype": "task_updated", "task_id": "bk1abc9xy", "patch": ["status": "completed", "end_time": 1_800_000_060_000]])
        #expect(ClaudeStreamParser.parse(updated) == .task(.updated(taskID: "bk1abc9xy", status: "completed", endMillis: 1_800_000_060_000)))
        #expect(ClaudeStreamParser.parse(notification(status: "failed", summary: "Background command \"q\" failed with exit code 3"))
            == .task(.notification(taskID: "bk1abc9xy", toolUseID: "toolu_b", status: "failed", exitCode: 3, kind: .command)))
        let changed = line(["type": "system", "subtype": "background_tasks_changed", "tasks": [
            ["task_id": "bk1abc9xy", "run_id": "r1", "task_type": "local_bash", "description": "Run the dev server"], ["task_id": "a02862466294fcd8e", "run_id": "r2", "task_type": "local_agent", "description": "Audit", "subagent_type": "general-purpose"],
        ]])
        #expect(ClaudeStreamParser.parse(changed) == .task(.changed([
            ClaudeChangedTask(taskID: "bk1abc9xy", taskType: "local_bash", description: "Run the dev server"), ClaudeChangedTask(taskID: "a02862466294fcd8e", taskType: "local_agent", description: "Audit"),
        ])))
    }

    @Test func theRealRecordedLinesStillParseAsTaskLines() throws {
        let lines = try ClaudeTest.fixture("r2-cc4-sigint-sleep")
        let kinds = lines.compactMap { ClaudeStreamParser.parse($0) }.map(\.kindName)
        #expect(kinds.filter { $0 == "task" }.count == 2)
        let events = lines.compactMap { ClaudeStreamParser.parse($0) }.compactMap { event -> ClaudeTaskStreamEvent? in if case .task(let payload) = event { payload } else { nil } }
        #expect(events.first == .started(taskID: "bc7vsloip", toolUseID: "toolu_01HWCs161uj2xaLc9iWJdtpW", taskType: "local_bash", description: "Sleep for 33 seconds using isolated python3", isBackgrounded: false))
        guard case .notification(let task, _, let status, let code, _)? = events.last else {
            Issue.record("알림 줄이 아니다")
            return
        }
        #expect(task == "bc7vsloip" && status == "stopped" && code == nil)
    }

    @Test func aTaskLineWithAHostileIdOrNoIdIsAnEmptyTaskEventNotACrash() {
        for id in ["", "../x", "a b", String(repeating: "z", count: 65)] {
            #expect(ClaudeStreamParser.parse(started(id)) == .task(nil), "\(id.debugDescription)")
        }
        #expect(ClaudeStreamParser.parse(line(["type": "system", "subtype": "task_started"])) == .task(nil))
        #expect(ClaudeStreamParser.parse(line(["type": "system", "subtype": "task_updated", "task_id": "ok1", "patch": "oops"])) == .task(.updated(taskID: "ok1", status: nil, endMillis: nil)))
        #expect(ClaudeStreamParser.parse(line(["type": "system", "subtype": "background_tasks_changed", "tasks": "oops"])) == .task(.changed([])))
        let mixed = line(["type": "system", "subtype": "background_tasks_changed", "tasks": [["task_id": "../x"], ["task_id": "good1"], 5, ["no": "id"]]])
        #expect(ClaudeStreamParser.parse(mixed) == .task(.changed([ClaudeChangedTask(taskID: "good1", taskType: nil, description: nil)])))
    }

    @Test func theParserCapsADescriptionAndKeepsNoSummaryText() {
        guard case .task(.started(_, _, _, let description?, _))? = ClaudeStreamParser.parse(started(description: String(repeating: "d", count: 5000))) else {
            Issue.record("시작 줄이 아니다")
            return
        }
        #expect(description.count <= 400)
        let event = ClaudeStreamParser.parse(notification(status: "failed", summary: "Background command \"\(Self.commandSentinel)\" failed with exit code 4"))
        #expect(!String(reflecting: event as Any).contains("SENTINEL-STREAM-SHELL-COMMAND") && !String(reflecting: event as Any).contains("hunter2"), "요약 글은 값에 없다 (끝낸 코드만)")
    }

    // MARK: 매퍼

    @Test func aBackgroundBashIsNamedByTheDescriptionTheModelWrote() {
        let actions = feed([
            assistantTool(input: ["command": Self.commandSentinel, "description": "Run the dev server", "run_in_background": true]),
            started(description: "Run the dev server"),
        ])
        #expect(background(actions) == [.started(taskID: "bk1abc9xy", toolUseID: "toolu_b", kind: .command, name: "Run the dev server", at: Date(timeIntervalSince1970: 1_800_000_010))])
    }

    @Test func aDescriptionThatIsTheCommandItselfOrCannotBeConfirmedIsNeverTheName() {
        // 모델이 description을 안 쓰면 CLI가 명령 글을 description 자리에 준다
        let sameAsCommand = feed([assistantTool(input: ["command": Self.commandSentinel]), started(description: Self.commandSentinel)])
        #expect(background(sameAsCommand).first.flatMap(name(of:)) == nil)
        let mismatch = feed([assistantTool(input: ["command": Self.commandSentinel, "description": "Run the dev server"]), started(description: Self.commandSentinel)])
        #expect(background(mismatch).first.flatMap(name(of:)) == nil, "모델이 쓴 글과 다르면 이름이 아니다")
        let unseenTool = feed([started(description: "Something that looks like a name")])
        #expect(background(unseenTool).first.flatMap(name(of:)) == nil, "그 도구 호출을 본 적이 없으면 확인할 수 없다")
        let noToolID = feed([assistantTool(input: ["description": "Run the dev server"]), started(tool: nil, description: "Run the dev server")])
        #expect(background(noToolID).first.flatMap(name(of:)) == nil)
        for actions in [sameAsCommand, mismatch, unseenTool, noToolID] {
            let text = String(reflecting: actions)
            #expect(!text.contains("hunter2") && !text.contains("SENTINEL-STREAM-SHELL-COMMAND"), "명령 글이 동작 값에 남지 않는다")
        }
    }

    @Test func aBackgroundAgentKeepsItsDescriptionBecauseTheModelAlwaysWritesIt() {
        let actions = feed([started("a02862466294fcd8e", tool: "toolu_a", type: "local_agent", description: "Audit pricing strings against the glossary")])
        #expect(background(actions) == [.started(taskID: "a02862466294fcd8e", toolUseID: "toolu_a", kind: .agent, name: "Audit pricing strings against the glossary", at: Date(timeIntervalSince1970: 1_800_000_005))])
    }

    @Test func anUnknownTaskTypeIsOtherAndNeedsTheSameConfirmationAsACommand() {
        let actions = feed([assistantTool(id: "toolu_m", name: "Monitor", input: ["description": "Watch the logs"]), started("mon1", tool: "toolu_m", type: "monitor", description: "Watch the logs")])
        #expect(background(actions).first.map { if case .started(_, _, let kind, let name, _) = $0 { "\(kind)/\(name ?? "-")" } else { "?" } } == "other/Watch the logs")
    }

    @Test func aForegroundCommandAndItsLaterLinesAreIgnored() {
        let actions = feed([started("fg1", tool: "toolu_f", backgrounded: false), notification("fg1", status: "stopped"), line(["type": "system", "subtype": "task_updated", "task_id": "fg1", "patch": ["status": "completed"]])])
        #expect(background(actions).isEmpty)
    }

    @Test func aNotificationBecomesTheFinishWithItsExitCodeAndAnUnknownStatusIsStopped() {
        let actions = feed([
            started(), notification(status: "failed", summary: "Background command \"x\" failed with exit code 3"),
            started("bk2def0za", tool: "toolu_c"), notification("bk2def0za", status: "completed", summary: "Background command \"x\" completed (exit code 0)"),
            started("bk3ghi1ab", tool: "toolu_d"), notification("bk3ghi1ab", status: "stopped", summary: "Background command \"x\" was stopped"),
            started("bk4jkl2cd", tool: "toolu_e"), notification("bk4jkl2cd", status: "mystery", summary: "?"),
        ])
        let finishes = background(actions).compactMap { event -> String? in
            if case .finished(let task, _, let status, let code, _) = event { return "\(task):\(status):\(code.map(String.init) ?? "-")" }
            return nil
        }
        #expect(finishes == ["bk1abc9xy:failed:3", "bk2def0za:done:0", "bk3ghi1ab:stopped:-", "bk4jkl2cd:stopped:-"])
    }

    @Test func aTaskUpdatedPatchFinishesTheTaskAtItsEndTimeButAnUnfinishedStatusDoesNot() {
        let end: Int64 = 1_800_000_060_000
        let actions = feed([
            started(),
            line(["type": "system", "subtype": "task_updated", "task_id": "bk1abc9xy", "patch": ["status": "running"]]),
            line(["type": "system", "subtype": "task_updated", "task_id": "bk1abc9xy", "patch": ["status": "completed", "end_time": end]]),
        ])
        let finishes = background(actions).filter { if case .finished = $0 { true } else { false } }
        #expect(finishes == [.finished(taskID: "bk1abc9xy", kind: nil, status: .done, exitCode: nil, at: Date(timeIntervalSince1970: 1_800_000_060))])
        let noEnd = feed([started(), line(["type": "system", "subtype": "task_updated", "task_id": "bk1abc9xy", "patch": ["status": "failed"]])])
        #expect(background(noEnd).last == .finished(taskID: "bk1abc9xy", kind: nil, status: .failed, exitCode: nil, at: Date(timeIntervalSince1970: 1_800_000_010)), "끝 시각이 없으면 본 시각")
    }

    @Test func theChangedSnapshotNamesTheRunningOnesAndStopsTheOnesThatLeft() {
        let changed = line(["type": "system", "subtype": "background_tasks_changed", "tasks": [["task_id": "a02862466294fcd8e", "task_type": "local_agent", "description": "Audit"]]])
        let actions = feed([started(), changed])
        let events = background(actions)
        #expect(events.contains(.snapshot(runningTaskIDs: ["a02862466294fcd8e"])))
        #expect(events.contains(.started(taskID: "a02862466294fcd8e", toolUseID: nil, kind: .agent, name: "Audit", at: Date(timeIntervalSince1970: 1_800_000_010))), "목록에만 있는 일도 알게 된다")
        var list = BackgroundTaskList()
        for event in events { list.apply(event) }
        #expect(list.tasks.first { $0.id == "bk1abc9xy" }?.status == .stopped && list.tasks.first { $0.id == "a02862466294fcd8e" }?.status == .running)
    }

    @Test func aCommandInTheSnapshotIsNotNamedByItsDescription() {
        let changed = line(["type": "system", "subtype": "background_tasks_changed", "tasks": [["task_id": "bk9yza7mn", "task_type": "local_bash", "description": Self.commandSentinel]]])
        let events = background(feed([changed]))
        #expect(events.first.flatMap(name(of:)) == nil)
        #expect(!String(reflecting: events).contains("hunter2"))
    }

    @Test func theExistingProgressBehaviourIsUnchanged() {
        // 시작 · 알림은 전처럼 진행 신호로 센다 (2초에 하나), 나머지 task 줄은 전처럼 진행 신호가 아니다
        let first = feed([started(), notification(status: "completed")], step: 0.5)
        #expect(progresses(first) == 1)
        let spaced = feed([started(), notification(status: "completed")], step: 3)
        #expect(progresses(spaced) == 2)
        let others = feed([
            line(["type": "system", "subtype": "task_progress", "task_id": "bk1abc9xy"]), line(["type": "system", "subtype": "task_updated", "task_id": "bk1abc9xy", "patch": ["status": "running"]]),
            line(["type": "system", "subtype": "background_tasks_changed", "tasks": []]),
        ], step: 3)
        #expect(progresses(others) == 0)
    }

    @Test func nothingIsMappedAfterTheTurnEnded() {
        let result = line(["type": "result", "subtype": "success", "is_error": false, "stop_reason": "end_turn", "terminal_reason": "completed", "session_id": "s"])
        let assistant = line(["type": "assistant", "session_id": "s", "message": ["id": "m", "model": "claude-fixture", "role": "assistant", "content": [["type": "text", "text": "ok"]]]])
        let actions = feed([assistant, result, started()])
        #expect(background(actions).isEmpty)
    }

    @Test func theMapperNeverEmitsTheTaskEventsToTheServerStream() {
        let actions = feed([assistantTool(input: ["description": "Run the dev server"]), started(), notification(status: "completed")])
        let emitted = actions.compactMap { action -> AgentEvent? in if case .emit(let event) = action { event } else { nil } }
        #expect(emitted.allSatisfy { $0 == .accepted || $0 == .progress }, "서버로 가는 것은 지금과 같다: 접수 · 진행 신호뿐")
    }

    private func name(of event: BackgroundTaskEvent) -> String? {
        if case .started(_, _, _, let name, _) = event { name } else { nil }
    }
}
#endif
