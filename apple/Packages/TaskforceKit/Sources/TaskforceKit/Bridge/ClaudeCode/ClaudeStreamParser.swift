#if os(macOS)
import Foundation
import TaskforceAgentWire

/// Claude Code `--output-format stream-json` 한 줄의 형태 (OA D3a 계약 2.9). 글은 대화 메시지 글만 꺼내고, 도구 입력 · 출력 · 훅 출력(답 포함) 원문은 들고 있지 않는다
public enum ClaudeStreamEvent: Equatable, Sendable {
    case systemInit(ClaudeInitInfo)
    case hookStarted(name: String, event: String)
    /// `stdout`는 SessionStart 표식 확인용으로만 쓴다 (PreToolUse 훅 출력은 담지 않는다)
    case hookResponse(name: String, event: String, exitCode: Int?, markerSeen: Bool)
    case assistant(ClaudeAssistantInfo)
    case toolResults([ClaudeToolResultInfo])
    case result(ClaudeResultInfo)
    case rateLimit(status: String?)
    /// `system/task_started` · `task_notification` · `task_progress` · `task_updated` · `background_tasks_changed` (백그라운드 일의 줄, 세션 보기 V1).
    /// 모양이 틀린 `task_started` · `task_notification`은 `nil`이다 (전처럼 진행 신호로만 센다)
    case task(ClaudeTaskStreamEvent?)
    /// 그 밖 (`command_lifecycle` · `attachment` · `thinking_tokens` · `api_retry` · 모르는 type): 개수만 센다
    case other(String)

    /// 시험용 짧은 이름
    var kindName: String {
        switch self {
        case .systemInit: "init"
        case .hookStarted(let name, _): "hook_started:\(name)"
        case .hookResponse(let name, _, _, _): "hook_response:\(name)"
        case .assistant: "assistant"
        case .toolResults: "tool_result"
        case .result: "result"
        case .rateLimit: "rate_limit"
        case .task: "task"
        case .other(let type): type
        }
    }
}

public struct ClaudeInitInfo: Equatable, Sendable {
    public var sessionID: String?
    public var cwd: String?
    public var tools: [String]
    /// 이름 → 상태 (`connected` …)
    public var mcpServers: [String: String]
    public var permissionMode: String?
    public var version: String?
    /// 값이 아니라 있는지만 (계약 2.8 끝: R1-17 보안 검토 입력)
    public var hasPlugins: Bool
    public var hasSkills: Bool
    public var hasMessagingSocket: Bool
}

public enum ClaudeContentBlock: Equatable, Sendable {
    case text(String)
    /// Edit · Write의 대상 경로만 (산출물). 그 밖 입력은 담지 않는다
    case toolUse(id: String, name: String, filePath: String?)
    case thinking
    case other
}

public struct ClaudeAssistantInfo: Equatable, Sendable {
    public var messageID: String?
    public var model: String?
    /// 줄 맨 위의 `error` (예: `authentication_failed`)
    public var error: String?
    public var blocks: [ClaudeContentBlock]
    /// 도구 호출 id → 모델이 쓴 `input.description` (백그라운드 일의 이름을 확인하는 데만 쓴다: 명령 글은 담지 않는다)
    public var toolDescriptions: [String: String] = [:]

    /// 진짜 모델 응답인가 (`<synthetic>`도 오류도 아님)
    public var isGenuine: Bool { model != nil && model != "<synthetic>" && error == nil }
}

public struct ClaudeToolResultInfo: Equatable, Sendable {
    public var toolUseID: String
    public var isError: Bool
}

public struct ClaudeResultInfo: Equatable, Sendable {
    public var subtype: String?
    public var isError: Bool
    public var stopReason: String?
    public var terminalReason: String?
    public var sessionID: String?
    public var deferredToolUseID: String?

    public var isDeferred: Bool { stopReason == "tool_deferred" || terminalReason == "tool_deferred" }
}

/// 백그라운드 일의 줄에서 꺼낸 칸 (아이디 · 종류 · 모델이 쓴 설명 · 상태 · 끝낸 코드 · 시각). 요약 글 · 출력 파일 경로는 담지 않는다
public enum ClaudeTaskStreamEvent: Equatable, Sendable {
    case started(taskID: String, toolUseID: String?, taskType: String?, description: String?, isBackgrounded: Bool?)
    case progress(taskID: String)
    case updated(taskID: String, status: String?, endMillis: Int64?)
    case notification(taskID: String, toolUseID: String?, status: String?, exitCode: Int?, kind: BackgroundTaskKind?)
    case changed([ClaudeChangedTask])
}

public struct ClaudeChangedTask: Equatable, Sendable {
    public var taskID: String
    public var taskType: String?
    public var description: String?

    public init(taskID: String, taskType: String?, description: String?) {
        self.taskID = taskID
        self.taskType = taskType
        self.description = description
    }
}

public enum ClaudeStreamParser {
    /// 한 줄을 읽는다. JSON 객체가 아니면 nil (세고 무시한다)
    public static func parse(_ line: Data) -> ClaudeStreamEvent? {
        guard let value = try? WireJSON.parse(line), case .object(let fields) = value, let type = fields["type"]?.stringValue else { return nil }
        let subtype = fields["subtype"]?.stringValue
        switch (type, subtype) {
        case ("system", "init"):
            var servers: [String: String] = [:]
            for server in fields["mcp_servers"]?.arrayValue ?? [] {
                if let name = server["name"]?.stringValue { servers[name] = server["status"]?.stringValue ?? "" }
            }
            func present(_ key: String) -> Bool {
                switch fields[key] {
                case nil, .null?: false
                case .array(let items)?: !items.isEmpty
                case .object(let items)?: !items.isEmpty
                case .string(let text)?: !text.isEmpty
                default: true
                }
            }
            return .systemInit(ClaudeInitInfo(
                sessionID: fields["session_id"]?.stringValue, cwd: fields["cwd"]?.stringValue, tools: (fields["tools"]?.arrayValue ?? []).compactMap(\.stringValue),
                mcpServers: servers, permissionMode: fields["permissionMode"]?.stringValue, version: fields["claude_code_version"]?.stringValue,
                hasPlugins: present("plugins"), hasSkills: present("skills"), hasMessagingSocket: present("messaging_socket_path")
            ))
        case ("system", "hook_started"):
            return .hookStarted(name: fields["hook_name"]?.stringValue ?? "", event: fields["hook_event"]?.stringValue ?? "")
        case ("system", "hook_response"):
            let event = fields["hook_event"]?.stringValue ?? ""
            let stdout = event == "SessionStart" ? (fields["stdout"]?.stringValue ?? "") : ""
            let exit = fields["exit_code"]?.int64Value.map { Int($0) }
            return .hookResponse(name: fields["hook_name"]?.stringValue ?? "", event: event, exitCode: exit, markerSeen: Self.hasMarker(stdout))
        case ("system", "task_started"):
            guard let id = Self.taskID(fields) else { return .task(nil) }
            return .task(.started(
                taskID: id, toolUseID: Self.toolUseID(fields), taskType: Self.capped(fields["task_type"]?.stringValue, 40), description: Self.capped(fields["description"]?.stringValue, Self.maxDescription),
                isBackgrounded: fields["is_backgrounded"]?.boolValue
            ))
        case ("system", "task_notification"):
            guard let id = Self.taskID(fields) else { return .task(nil) }
            // 요약 글(따옴표 안에 모델의 설명이나 명령이 들어 있을 수 있다)은 끝낸 코드와 종류를 읽고 버린다
            let summary = fields["summary"]?.stringValue ?? ""
            return .task(.notification(
                taskID: id, toolUseID: Self.toolUseID(fields), status: Self.capped(fields["status"]?.stringValue, 40), exitCode: BackgroundTaskText.exitCode(inSummary: summary),
                kind: BackgroundTaskText.kind(inSummary: summary)
            ))
        case ("system", "task_progress"):
            guard let id = Self.taskID(fields) else { return .other("system/task_progress") }
            return .task(.progress(taskID: id))
        case ("system", "task_updated"):
            guard let id = Self.taskID(fields) else { return .other("system/task_updated") }
            let patch = fields["patch"]
            return .task(.updated(taskID: id, status: Self.capped(patch?["status"]?.stringValue, 40), endMillis: patch?["end_time"]?.int64Value))
        case ("system", "background_tasks_changed"):
            let changed: [ClaudeChangedTask] = (fields["tasks"]?.arrayValue ?? []).prefix(Self.maxChangedTasks).compactMap { item in
                guard let id = item["task_id"]?.stringValue, BackgroundTaskText.isValidTaskID(id) else { return nil }
                return ClaudeChangedTask(taskID: id, taskType: Self.capped(item["task_type"]?.stringValue, 40), description: Self.capped(item["description"]?.stringValue, Self.maxDescription))
            }
            return .task(.changed(changed))
        case ("assistant", _):
            let message = fields["message"]
            let blocks: [ClaudeContentBlock] = (message?["content"]?.arrayValue ?? []).map { block in
                switch block["type"]?.stringValue {
                case "text": return .text(block["text"]?.stringValue ?? "")
                case "tool_use":
                    return .toolUse(id: block["id"]?.stringValue ?? "", name: block["name"]?.stringValue ?? "", filePath: block["input"]?["file_path"]?.stringValue)
                case "thinking", "redacted_thinking": return .thinking
                default: return .other
                }
            }
            // 도구 호출마다 모델이 쓴 `input.description`만 (백그라운드 일의 이름을 확인하는 데 쓴다: 명령 글은 담지 않는다)
            var descriptions: [String: String] = [:]
            for block in message?["content"]?.arrayValue ?? [] where block["type"]?.stringValue == "tool_use" {
                if let id = block["id"]?.stringValue, BackgroundTaskText.isValidToolUseID(id), let text = Self.capped(block["input"]?["description"]?.stringValue, Self.maxDescription), !text.isEmpty { descriptions[id] = text }
            }
            return .assistant(ClaudeAssistantInfo(
                messageID: message?["id"]?.stringValue, model: message?["model"]?.stringValue, error: fields["error"]?.stringValue, blocks: blocks, toolDescriptions: descriptions
            ))
        case ("user", _):
            let results: [ClaudeToolResultInfo] = (fields["message"]?["content"]?.arrayValue ?? []).compactMap { block in
                guard block["type"]?.stringValue == "tool_result", let id = block["tool_use_id"]?.stringValue else { return nil }
                return ClaudeToolResultInfo(toolUseID: id, isError: block["is_error"]?.boolValue ?? false)
            }
            return results.isEmpty ? .other("user") : .toolResults(results)
        case ("result", _):
            return .result(ClaudeResultInfo(
                subtype: subtype, isError: fields["is_error"]?.boolValue ?? false, stopReason: fields["stop_reason"]?.stringValue,
                terminalReason: fields["terminal_reason"]?.stringValue, sessionID: fields["session_id"]?.stringValue,
                deferredToolUseID: fields["deferred_tool_use"]?["id"]?.stringValue
            ))
        case ("rate_limit_event", _):
            return .rateLimit(status: fields["rate_limit_info"]?["status"]?.stringValue)
        default:
            return .other(subtype.map { "\(type)/\($0)" } ?? type)
        }
    }

    /// 설명의 글자 수 상한 (이름 한 줄이면 충분하다: 값이 커지지 않게)
    static let maxDescription = 400
    /// `background_tasks_changed` 한 줄에서 읽는 일의 수
    static let maxChangedTasks = 64

    /// `task_id`: 영숫자 · `_` · `-` 64자 이하 (출력 파일 이름이 이 아이디로 만들어진다). 아니면 nil
    private static func taskID(_ fields: [String: WireJSON]) -> String? {
        guard let id = fields["task_id"]?.stringValue, BackgroundTaskText.isValidTaskID(id) else { return nil }
        return id
    }

    private static func toolUseID(_ fields: [String: WireJSON]) -> String? {
        guard let id = fields["tool_use_id"]?.stringValue, BackgroundTaskText.isValidToolUseID(id) else { return nil }
        return id
    }

    private static func capped(_ text: String?, _ limit: Int) -> String? {
        guard let text else { return nil }
        return text.count > limit ? String(text.prefix(limit)) : text
    }

    /// SessionStart 훅 출력에 표식이 있나 (`additionalContext == "tf-hook-ready"`)
    static func hasMarker(_ stdout: String) -> Bool {
        guard let value = try? WireJSON.parse(Data(stdout.utf8)) else { return false }
        return value["hookSpecificOutput"]?["additionalContext"]?.stringValue == HookOutput.marker
    }
}
#endif
