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
        guard case .task(.started(_, _, _, let description?, _, _, _))? = ClaudeStreamParser.parse(started(description: String(repeating: "d", count: 5000))) else {
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

    /// 보안 P3-6: 에이전트도 같은 확인을 받는다. 앞에서는 에이전트의 description을 그대로 믿었다 (모델이 늘 쓰므로): 그런데 CLI가 모델이 안 쓴 칸을 다른 글(프롬프트 · 명령)로 채우는 일이 없다는 보장은 없다
    @Test func aBackgroundAgentNeedsItsDescriptionConfirmedLikeACommand() {
        let tool = assistantTool(id: "toolu_a", name: "Agent", input: ["description": "Audit pricing strings against the glossary", "prompt": Self.commandSentinel])
        let confirmed = feed([tool, started("a02862466294fcd8e", tool: "toolu_a", type: "local_agent", description: "Audit pricing strings against the glossary")])
        #expect(background(confirmed) == [.started(taskID: "a02862466294fcd8e", toolUseID: "toolu_a", kind: .agent, name: "Audit pricing strings against the glossary", at: Date(timeIntervalSince1970: 1_800_000_010))])
        // 모델이 쓴 글이 아닌 글(프롬프트 자체)이 description 자리에 오면 이름이 아니다
        let prompt = feed([tool, started("a02862466294fcd8e", tool: "toolu_a", type: "local_agent", description: Self.commandSentinel)])
        #expect(background(prompt).first.flatMap(name(of:)) == nil)
        #expect(!String(reflecting: prompt).contains("hunter2"), "프롬프트 글이 동작 값에 남지 않는다")
        // 그 도구 호출을 본 적이 없으면 확인할 수 없다
        let unseen = feed([started("a02862466294fcd8e", tool: "toolu_a", type: "local_agent", description: "Audit pricing strings against the glossary")])
        #expect(background(unseen).first.flatMap(name(of:)) == nil)
        let noTool = feed([tool, started("a02862466294fcd8e", tool: nil, type: "local_agent", description: "Audit pricing strings against the glossary")])
        #expect(background(noTool).first.flatMap(name(of:)) == nil)
    }

    @Test func anUnknownTaskTypeIsOtherAndNeedsTheSameConfirmationAsACommand() {
        let actions = feed([assistantTool(id: "toolu_m", name: "Monitor", input: ["description": "Watch the logs"]), started("mon1", tool: "toolu_m", type: "monitor", description: "Watch the logs")])
        #expect(background(actions).first.map { if case .started(_, _, let kind, let name, _, _, _, _) = $0 { "\(kind)/\(name ?? "-")" } else { "?" } } == "other/Watch the logs")
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
        #expect(events.contains(.started(taskID: "a02862466294fcd8e", toolUseID: nil, kind: .agent, name: nil, at: Date(timeIntervalSince1970: 1_800_000_010))), "목록에만 있는 일도 알게 된다 (이름은 도구 호출로 확인할 수 없어 비운다)")
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

    private var resultLine: Data { line(["type": "result", "subtype": "success", "is_error": false, "stop_reason": "end_turn", "terminal_reason": "completed", "session_id": "s"]) }
    private var assistantText: Data { line(["type": "assistant", "session_id": "s", "message": ["id": "m", "model": "claude-fixture", "role": "assistant", "content": [["type": "text", "text": "ok"]]]]) }

    private func notBackground(_ actions: [ClaudeMapperAction]) -> [String] {
        actions.compactMap { if case .backgroundTask = $0 { nil } else { String(describing: $0) } }
    }

    /// 리뷰 P1: 처음 `result` 뒤에도 CLI는 일이 끝날 때까지 `task_updated` · `task_notification` · `background_tasks_changed`를 낸다 (실측 2.1.308, 마지막 두 번째 `result`까지).
    /// 그 줄들은 **이 Mac의 판에만** 가는 사건이라 턴이 끝난 뒤에도 계속 반영한다 (서버로 가는 것 · 진행 신호 · 자체 점검은 첫 `result`에서 끝난다)
    @Test func afterTheResultTheTaskLinesStillReachTheLocalBoardAndNothingElseDoes() {
        let base = feed([assistantText, resultLine])
        let later = feed([assistantText, resultLine, started("bk7late", tool: nil), notification("bk7late", status: "completed"), assistantText, resultLine])
        #expect(background(later).count == 2, "시작 · 끝 알림이 판으로 간다")
        #expect(background(later).first == .started(taskID: "bk7late", toolUseID: nil, kind: .command, name: nil, at: Date(timeIntervalSince1970: 1_800_000_015)))
        if case .finished(let id, _, let status, let code, _)? = background(later).last { #expect(id == "bk7late" && status == .done && code == 0) } else { Issue.record("끝 사건이 없다") }
        #expect(notBackground(later) == notBackground(base), "서버로 가는 사건 · 진행 신호는 첫 result 뒤에 더 생기지 않는다 (두 번째 result · assistant도 무시)")
        #expect(progresses(later) == 0)
    }

    @Test func afterTheResultAnUpdateAndAnEmptySnapshotAlsoReachTheBoard() {
        let end: Int64 = 1_800_000_060_000
        let actions = feed([
            started(), assistantText, resultLine,
            line(["type": "system", "subtype": "task_updated", "task_id": "bk1abc9xy", "patch": ["status": "completed", "end_time": end]]),
            line(["type": "system", "subtype": "background_tasks_changed", "tasks": []]),
        ])
        let events = background(actions)
        #expect(events.contains(.finished(taskID: "bk1abc9xy", kind: nil, status: .done, exitCode: nil, at: Date(timeIntervalSince1970: 1_800_000_060))))
        #expect(events.last == .snapshot(runningTaskIDs: []))
    }

    @Test func afterASelfCheckFailureOrInTheClosingModeNothingIsMapped() {
        var failed = mapper()
        _ = failed.oversizedLine()
        let afterFail = ClaudeStreamParser.parse(started()).map { failed.consume($0, facts: ClaudeSpawnFacts(), now: Date()) } ?? [.resultSeen]
        #expect(afterFail.isEmpty, "자체 점검이 실패한 spawn은 멈추는 중이다: 그 뒤 줄은 판에 닿지 않는다")
        var closing = ClaudeEventMapper(config: ClaudeMapperConfig(
            mode: .close(requestID: "toolu_x"), expectedSessionID: nil, expectedTools: nil, expectedCwd: nil, requireSessionStart: false, workspaceRealPath: "/w", versionSupported: { _ in true }
        ))
        let inClose = ClaudeStreamParser.parse(started()).map { closing.consume($0, facts: ClaudeSpawnFacts(), now: Date()) } ?? [.resultSeen]
        #expect(inClose.isEmpty)
    }

    /// 실측 기록(2.1.308, 일 둘): 일 A(12초) · 일 B(30초)를 백그라운드로 띄우고 첫 턴이 끝난 뒤 둘이 차례로 끝난다. 스냅샷은 도는 일 **전부**다 ([A] → [A,B] → [B] → [])
    @Test func theRecordedTwoTaskRunEndsBothTasksAfterTheFirstResultAndTheSnapshotsAreFullLists() throws {
        // 파일은 `Fixtures/claude-code-2.1.241/` 안에 둔다 (Package.swift의 리소스 선언이 그 폴더 하나다). 세션 · 줄 id · 경로만 가짜로 바꾼 실측 줄
        let lines = try ClaudeTest.fixture("bg-two-tasks-2.1.308")
        let actions = feed([
            assistantTool(id: "toolu_018rmEZNtyiudTypUyzgDmp3", input: ["command": "bash ./bgjob.sh 12 A", "description": "Job A", "run_in_background": true]),
            assistantTool(id: "toolu_01CgmF9q2k9oxVFZPSstAFtp", input: ["command": "bash ./bgjob.sh 30 B", "description": "Job B", "run_in_background": true]),
        ] + lines)
        var list = BackgroundTaskList()
        var seenSnapshots: [[String]] = []
        for event in background(actions) {
            if case .snapshot(let running) = event { seenSnapshots.append(running) }
            list.apply(event, now: Date(timeIntervalSince1970: 1_800_000_999))
        }
        #expect(seenSnapshots == [["bd0xi08gp"], ["bd0xi08gp", "bod5exuaq"], ["bod5exuaq"], []], "도는 일 전부의 스냅샷")
        let a = list.tasks.first { $0.id == "bd0xi08gp" }
        let b = list.tasks.first { $0.id == "bod5exuaq" }
        #expect(a?.status == .done && a?.exitCode == 0 && a?.kind == .command && a?.name == "Job A")
        #expect(b?.status == .done && b?.exitCode == 0 && b?.name == "Job B", "첫 result 뒤에 끝난 일도 Done이다 (Running으로 남지 않는다)")
        #expect(a?.endedAt == Date(timeIntervalSince1970: 1_792_704_631.950) && b?.endedAt == Date(timeIntervalSince1970: 1_792_704_649.972), "끝 시각은 task_updated의 end_time이다")
        #expect(list.runningCount == 0)
    }

    @Test func theMapperNeverEmitsTheTaskEventsToTheServerStream() {
        let actions = feed([assistantTool(input: ["description": "Run the dev server"]), started(), notification(status: "completed")])
        let emitted = actions.compactMap { action -> AgentEvent? in if case .emit(let event) = action { event } else { nil } }
        #expect(emitted.allSatisfy { $0 == .accepted || $0 == .progress }, "서버로 가는 것은 지금과 같다: 접수 · 진행 신호뿐")
    }

    private func name(of event: BackgroundTaskEvent) -> String? {
        if case .started(_, _, _, let name, _, _, _, _) = event { name } else { nil }
    }
}
#endif
