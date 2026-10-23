#if os(macOS) && DEBUG
import Foundation
@testable import TaskforceKit

/// 세션 보기 V1 시험의 기록 줄 (DZ oa-session-view-dz 탐침의 키 이름 그대로, 값은 가짜). 도구 본문 · 명령 · 요약의 글(sentinel)은 어느 출력에도 나오면 안 된다
enum SessionViewLine {
    typealias F = ExternalSessionFixture

    /// 파일 경로 · 명령 · 검색어 · 결과 · 프롬프트에 심은 값: 단계 줄 · 일 목록 어디에도 나오면 안 된다 (파일 **이름**만 나온다)
    static let pathSentinel = "SENTINEL-DIR-OF-THE-FILE"
    static let commandSentinel = "SENTINEL-SHELL-COMMAND"
    static let patternSentinel = "SENTINEL-SEARCH-PATTERN"
    static let errorSentinel = "SENTINEL-ERROR-RESULT-TEXT"
    static let stdoutSentinel = "SENTINEL-BG-STDOUT"
    static let promptSentinel = "SENTINEL-AGENT-PROMPT"
    static let summarySentinel = "SENTINEL-NOTIFICATION-SUMMARY-QUOTE"
    static let outputPathSentinel = "SENTINEL-OUTPUT-FILE-PATH"

    static let neverShown = [pathSentinel, commandSentinel, patternSentinel, errorSentinel, stdoutSentinel, promptSentinel, summarySentinel, outputPathSentinel]

    /// 도구를 쓴 줄 (시각을 정할 수 있다)
    static func tool(id: String, toolID: String, name: String, input: [String: Any], timestamp: String = "2026-10-22T01:00:03.000Z") -> String {
        F.json([
            "type": "assistant", "sessionId": id, "uuid": UUID().uuidString.lowercased(), "timestamp": timestamp, "isSidechain": false,
            "message": ["role": "assistant", "content": [["type": "tool_use", "id": toolID, "name": name, "input": input]]],
        ])
    }

    /// 도구 결과 줄: `is_error`가 `nil`이면 그 칸이 없다
    static func result(id: String, toolID: String, text: String = "ok", isError: Bool?, timestamp: String = "2026-10-22T01:00:04.000Z") -> String {
        var block: [String: Any] = ["type": "tool_result", "tool_use_id": toolID, "content": text]
        if let isError { block["is_error"] = isError }
        return F.json([
            "type": "user", "sessionId": id, "uuid": UUID().uuidString.lowercased(), "timestamp": timestamp, "isSidechain": false,
            "message": ["role": "user", "content": [block]],
        ])
    }

    /// 백그라운드 Bash의 시작 줄 (BG-1): `toolUseResult.backgroundTaskId`
    static func bashStarted(id: String, toolID: String, taskID: String, timestamp: String = "2026-10-22T01:00:05.000Z") -> String {
        F.json([
            "type": "user", "sessionId": id, "uuid": UUID().uuidString.lowercased(), "timestamp": timestamp, "isSidechain": false,
            "message": ["role": "user", "content": [["type": "tool_result", "tool_use_id": toolID, "content": "Command running in background with ID: \(taskID)"]]],
            "toolUseResult": ["stdout": stdoutSentinel, "stderr": "", "interrupted": false, "isImage": false, "noOutputExpected": false, "backgroundTaskId": taskID],
        ])
    }

    /// 백그라운드 에이전트의 시작 줄 (BG-1): `toolUseResult.agentId` + `isAsync`
    static func agentStarted(id: String, toolID: String, agentID: String, timestamp: String = "2026-10-22T01:00:06.000Z") -> String {
        F.json([
            "type": "user", "sessionId": id, "uuid": UUID().uuidString.lowercased(), "timestamp": timestamp, "isSidechain": false,
            "message": ["role": "user", "content": [["type": "tool_result", "tool_use_id": toolID, "content": "Async agent launched"]]],
            "toolUseResult": [
                "isAsync": true, "status": "async_launched", "agentId": agentID, "description": "Agent description text", "prompt": promptSentinel,
                "outputFile": "/private/tmp/claude-501/\(outputPathSentinel)/tasks/\(agentID).output", "canReadOutputFile": true, "canContinueAgent": true, "resolvedModel": "claude-fixture",
            ],
        ])
    }

    /// 전경 에이전트가 끝나 돌려준 결과 줄: `toolUseResult.agentId` + `status`(비동기 시작이 아니라서 `isAsync`가 없다). 프롬프트 · 결과 글은 가짜 sentinel이다
    static func agentFinished(id: String, toolID: String, agentID: String, timestamp: String = "2026-10-22T01:00:40.000Z") -> String {
        F.json([
            "type": "user", "sessionId": id, "uuid": UUID().uuidString.lowercased(), "timestamp": timestamp, "isSidechain": false,
            "message": ["role": "user", "content": [["type": "tool_result", "tool_use_id": toolID, "content": [["type": "text", "text": stdoutSentinel]]]]],
            "toolUseResult": ["status": "completed", "agentId": agentID, "agentType": "general-purpose", "prompt": promptSentinel, "content": [["type": "text", "text": stdoutSentinel]], "totalDurationMs": 35_000, "totalTokens": 10],
        ])
    }

    /// 끝 알림의 글 (BG-2): `<task-notification>` 안의 태그들. 요약의 따옴표 안 글은 가짜 sentinel이다
    static func notificationText(taskID: String, toolID: String = "toolu_x", status: String, summary: String) -> String {
        "<task-notification>\n<task-id>\(taskID)</task-id>\n<tool-use-id>\(toolID)</tool-use-id>\n<output-file>/private/tmp/claude-501/\(outputPathSentinel)/tasks/\(taskID).output</output-file>\n<status>\(status)</status>\n<summary>\(summary)</summary>\n</task-notification>"
    }

    /// 끝 알림 줄 (사용자 모양): `origin.kind == "task-notification"`
    static func notification(id: String, taskID: String, status: String, summary: String, timestamp: String = "2026-10-22T01:00:30.000Z", toolID: String = "toolu_x") -> String {
        F.json([
            "type": "user", "sessionId": id, "uuid": UUID().uuidString.lowercased(), "timestamp": timestamp, "isSidechain": false,
            "origin": ["kind": "task-notification", "producer": "session-task", "runId": "0abc-1234"], "turnOrigin": "task_notification", "promptSource": "system",
            "message": ["role": "user", "content": notificationText(taskID: taskID, toolID: toolID, status: status, summary: summary)],
        ])
    }

    /// 끝 알림 줄 (첨부 모양): 턴이 도는 동안 끼어든 `queued_command` + `commandMode == "task-notification"`
    static func queuedNotification(id: String, taskID: String, status: String, summary: String, timestamp: String = "2026-10-22T01:00:31.000Z") -> String {
        F.json([
            "type": "attachment", "sessionId": id, "uuid": UUID().uuidString.lowercased(), "timestamp": timestamp,
            "attachment": ["type": "queued_command", "commandMode": "task-notification", "prompt": notificationText(taskID: taskID, status: status, summary: summary)],
        ])
    }

    static func date(_ iso: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: iso)
    }
}
#endif
