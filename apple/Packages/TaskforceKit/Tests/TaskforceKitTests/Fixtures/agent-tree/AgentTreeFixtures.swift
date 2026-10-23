#if os(macOS) && DEBUG
import Foundation

/// 하위 에이전트 트리 표본 (실측 C1 · C3 · C4, Claude Code 2.1.306 stream-json): 줄의 **칸만** 남기고 값은 지어낸 것이다.
/// 남긴 칸: `type` · `subtype` · `task_id` · `tool_use_id` · `parent_task_id` · `spawn_depth` · `is_backgrounded` · `task_type` · `status` · `patch` · `description` (+ 도는 일 목록의 `tasks[].task_id/task_type`).
/// 경로 · 프롬프트 · 요약 · 출력 파일 · 세션 id는 없다. 어시스턴트 줄은 이름 확인용으로 도구 호출 하나(`id` · `name` · `input.description`)만 든다 (`ClaudeEventMapper`는 직전 도구 호출의 description과 같을 때만 이름으로 쓴다).
/// 원본(실측 줄)은 코디네이터 로컬에만 있고 저장소에 없다
enum AgentTreeFixtures {
    // 일 id (실제 모양: 소문자 `a` + 16자리 16진수) · 도구 호출 id
    static let a = "a1111111111111111"
    static let b = "a2222222222222222"
    static let nested = "a3333333333333333"
    static let foreground = "a4444444444444444"
    static let toolA = "toolu_fixtureA"
    static let toolB = "toolu_fixtureB"
    static let toolNested = "toolu_fixtureN"
    static let toolForeground = "toolu_fixtureF"

    static let nameA = "Check the first note"
    static let nameB = "Check the second note"
    static let nameNested = "Check a nested note"
    static let nameForeground = "Wait for a note"

    private static func line(_ object: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
    }

    private static func assistant(tool: String, description: String) -> Data {
        line([
            "type": "assistant",
            "message": ["id": "msg_\(tool)", "model": "claude-fixture", "role": "assistant", "content": [["type": "tool_use", "id": tool, "name": "Agent", "input": ["description": description]]]],
        ])
    }

    private static func started(_ task: String, tool: String, description: String, depth: Int, parent: String? = nil, background: Bool) -> Data {
        var object: [String: Any] = [
            "type": "system", "subtype": "task_started", "task_id": task, "tool_use_id": tool, "description": description, "task_type": "local_agent", "spawn_depth": depth, "is_backgrounded": background,
        ]
        if let parent { object["parent_task_id"] = parent }
        return line(object)
    }

    private static func progress(_ task: String, tool: String, description: String) -> Data {
        line(["type": "system", "subtype": "task_progress", "task_id": task, "tool_use_id": tool, "description": description])
    }

    private static func updated(_ task: String, status: String, endMillis: Int64) -> Data {
        line(["type": "system", "subtype": "task_updated", "task_id": task, "patch": ["status": status, "end_time": endMillis]])
    }

    private static func notification(_ task: String, tool: String, status: String) -> Data {
        line(["type": "system", "subtype": "task_notification", "task_id": task, "tool_use_id": tool, "status": status])
    }

    /// 지금 도는 **백그라운드** 일의 전체 스냅샷 (전경 일은 싣지 않는다)
    private static func changed(_ tasks: [String]) -> Data {
        line(["type": "system", "subtype": "background_tasks_changed", "tasks": tasks.map { ["task_id": $0, "task_type": "local_agent"] }])
    }

    /// C1: 백그라운드 자식 둘이 동시에 돈다 (둘 다 세션 바로 아래, 깊이 1). 스냅샷이 시작 줄보다 먼저 온다
    static let c1: [Data] = [
        assistant(tool: toolA, description: nameA),
        changed([a]),
        started(a, tool: toolA, description: nameA, depth: 1, background: true),
        assistant(tool: toolB, description: nameB),
        changed([a, b]),
        started(b, tool: toolB, description: nameB, depth: 1, background: true),
        progress(a, tool: toolA, description: nameA),
        progress(b, tool: toolB, description: nameB),
        updated(a, status: "completed", endMillis: 1_800_000_050_000),
        notification(a, tool: toolA, status: "completed"),
        changed([b]),
        updated(b, status: "completed", endMillis: 1_800_000_060_000),
        notification(b, tool: toolB, status: "completed"),
        changed([]),
    ]

    /// C3: 백그라운드 둘 + 그 하나(a)가 띄운 **전경** 자식(nested, 깊이 2, `parent_task_id` = a). 둘째(b)가 끝나 스냅샷이 `[a]`만 말할 때 nested는 아직 돈다
    static let c3: [Data] = [
        assistant(tool: toolA, description: nameA),
        changed([a]),
        started(a, tool: toolA, description: nameA, depth: 1, background: true),
        assistant(tool: toolB, description: nameB),
        changed([a, b]),
        started(b, tool: toolB, description: nameB, depth: 1, background: true),
        progress(a, tool: toolA, description: nameA),
        assistant(tool: toolNested, description: nameNested),
        started(nested, tool: toolNested, description: nameNested, depth: 2, parent: a, background: false),
        updated(b, status: "completed", endMillis: 1_800_000_050_000),
        notification(b, tool: toolB, status: "completed"),
        changed([a]),
        progress(nested, tool: toolNested, description: nameNested),
        updated(nested, status: "completed", endMillis: 1_800_000_060_000),
        notification(nested, tool: toolNested, status: "completed"),
        updated(a, status: "completed", endMillis: 1_800_000_070_000),
        notification(a, tool: toolA, status: "completed"),
        changed([]),
    ]

    /// C3에서 스냅샷 `changed([a])`(b가 끝난 뒤)까지의 줄 수: 이 시점에 nested는 아직 돈다
    static let c3IndexOfSnapshotAfterBFinished = 11

    /// C4: 전경 자식 하나(깊이 1)가 사용자 Stop(SIGINT)으로 죽는다: `task_updated`는 `killed`, `task_notification`은 `stopped`
    static let c4: [Data] = [
        assistant(tool: toolForeground, description: nameForeground),
        started(foreground, tool: toolForeground, description: nameForeground, depth: 1, background: false),
        progress(foreground, tool: toolForeground, description: nameForeground),
        updated(foreground, status: "killed", endMillis: 1_800_000_030_000),
        notification(foreground, tool: toolForeground, status: "stopped"),
    ]
}
#endif
