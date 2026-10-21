import Darwin
import Foundation

// 가짜 `claude` (OA D3a 계약 4.3, 시험 전용 — 앱은 링크하지 않는다).
// - 인자를 계약 2.4의 집합과 정확히 대조한다 (다르면 stderr "unexpected flags" + exit 3: 인자 계약이 시험된다).
// - `--settings`의 훅 명령을 `/bin/sh -c`로 실제로 실행하고(훅 입력 JSON을 stdin으로), 결정대로 결과를 지어 낸다.
// - `--mcp-config`의 `tf` 서버를 띄워 `initialize` · `tools/list` · `tools/call`을 한다.
// - 대본은 시험이 넣은 임시 `HOME/.fake-claude/scenario.json` (환경이 넷뿐이라 HOME으로 찾는다). 실행마다 `report-<n>.json`을 남긴다.
// - SIGINT: 돌던 도구를 끝내고 `error_during_execution` · `aborted_tools` 결과를 낸 뒤 exit 0 (S0 CC-4).

nonisolated(unsafe) var fakeInterrupted: sig_atomic_t = 0

enum Fake {
    static let prompt = "When you need the user's input, call mcp__tf__ask_user (1–4 questions). Make one such call at a time and wait for its result."

    static let projectOpen = "<<<PROJECT INSTRUCTIONS: "

    /// `--append-system-prompt`가 `prompt`로 시작해 고른 작업 폴더를 `--add-dir` 값 그대로 말하는가 (Kit `ClaudeCodePrompts.v2`의 앞부분).
    /// 첫 줄(질문 안내 + 폴더 줄 + 안내 문장)은 한 줄이다. 경로에 제어 글자가 있으면 폴더 줄이 없다(질문 안내만).
    /// 그 뒤는 비었거나, 빈 줄 다음에 Taskforce가 읽어 붙인 프로젝트 지침 블록이어야 한다 (소개 문장 + `<<<PROJECT INSTRUCTIONS: …>>>` 블록, 마지막은 닫는 표지나 `[Not included: …]`)
    static func promptNamesWorkspace(_ text: String, addDir: String) -> Bool {
        let parts = text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        let head = String(parts[0])
        let rest = parts.count > 1 ? String(parts[1]) : ""
        guard !head.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }), head.hasPrefix(prompt) else { return false }
        if addDir.isEmpty || addDir.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) {
            guard head == prompt else { return false }
        } else {
            guard head.hasPrefix(prompt + " The user's chosen workspace folder for this session is: \(addDir) (absolute path).") else { return false }
        }
        if parts.count == 1 { return true }
        return rest.hasPrefix("\nThe workspace folder has its own project instructions.") && rest.contains("\n\n" + projectOpen) && (rest.hasSuffix(">>>") || rest.hasSuffix("in total.)]"))
    }

    nonisolated(unsafe) static var report: [String: Any] = [:]
    nonisolated(unsafe) static var reportURL: URL?
    nonisolated(unsafe) static var messageCounter = 0
    nonisolated(unsafe) static var denials: [[String: Any]] = []
    nonisolated(unsafe) static var sessionID = ""
    nonisolated(unsafe) static var mcp: MCPClient?
    nonisolated(unsafe) static var lastText = ""

    struct Flags {
        var tools = ""
        var mcpConfig = ""
        var addDir = ""
        var systemPrompt = ""
        var settings = ""
        var sessionID: String?
        var resume: String?
    }

    // MARK: 출력

    static func emit(_ object: [String: Any]) {
        guard var data = try? JSONSerialization.data(withJSONObject: object) else { return }
        data.append(0x0A)
        data.withUnsafeBytes { _ = write(STDOUT_FILENO, $0.baseAddress, data.count) }
    }

    static func saveReport() {
        guard let reportURL, let data = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]) else { return }
        try? data.write(to: reportURL)
    }

    static func append(_ key: String, _ value: Any) {
        var list = report[key] as? [Any] ?? []
        list.append(value)
        report[key] = list
        saveReport()
    }

    static func nextMessageID() -> String {
        messageCounter += 1
        return "msg_fake_\(messageCounter)"
    }

    static func assistant(_ content: [String: Any], model: String = "claude-sonnet-5", error: String? = nil, messageID: String? = nil) {
        var event: [String: Any] = [
            "type": "assistant", "session_id": sessionID,
            "message": ["model": model, "id": messageID ?? nextMessageID(), "type": "message", "role": "assistant", "content": [content]],
        ]
        if let error { event["error"] = error }
        emit(event)
    }

    static func toolResult(_ id: String, _ text: String, isError: Bool) {
        emit(["type": "user", "session_id": sessionID, "message": ["role": "user", "content": [["type": "tool_result", "tool_use_id": id, "content": text, "is_error": isError]]]])
        append("tool_results", ["id": id, "is_error": isError, "text": text])
    }

    /// SIGINT를 받았으면 결과를 내고 끝낸다
    /// 기다리는 동안 SIGINT가 오면 바로 중단 결과를 내고 끝난다
    static func pauseInterruptibly(_ seconds: Double) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            checkInterrupt()
            Thread.sleep(forTimeInterval: 0.02)
        }
        checkInterrupt()
    }

    /// 파일이 생길 때까지 기다린다 (그 동안 SIGINT가 오면 바로 중단 결과를 내고 끝난다)
    static func waitInterruptibly(forFile path: String, max seconds: Double) {
        let deadline = Date().addingTimeInterval(seconds)
        while !FileManager.default.fileExists(atPath: path), Date() < deadline {
            checkInterrupt()
            Thread.sleep(forTimeInterval: 0.02)
        }
        checkInterrupt()
    }

    static func checkInterrupt() {
        guard fakeInterrupted != 0 else { return }
        emit(["type": "user", "session_id": sessionID, "message": ["role": "user", "content": [["type": "text", "text": "[Request interrupted by user for tool use]"]]]])
        emit(["type": "result", "subtype": "error_during_execution", "is_error": true, "stop_reason": "tool_use", "terminal_reason": "aborted_tools", "session_id": sessionID])
        report["interrupted"] = true
        markEnded()
        mcp?.stop()
        exit(0)
    }

    // MARK: 하위 프로세스

    /// 명령을 `/bin/sh -c`로 돌려 stdout · 종료 코드를 받는다 (훅)
    static func shell(_ command: String, input: Data, timeout: TimeInterval) -> (stdout: String, code: Int32) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.environment = ProcessInfo.processInfo.environment
        let stdin = Pipe()
        let stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return ("", 127) }
        // 출력은 따로 끝까지 읽는다 (큰 출력이 파이프를 막지 않게)
        let collected = OutputBox()
        let reader = stdout.fileHandleForReading
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            collected.data = reader.readDataToEndOfFile()
            done.signal()
        }
        stdin.fileHandleForWriting.write(input)
        try? stdin.fileHandleForWriting.close()
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        if process.isRunning {
            process.terminate()
            append("shell_runs", ["outcome": "timeout"])
            return ("", 1)
        }
        // 훅은 끝났다: 남은 출력을 EOF까지 다 읽은 뒤에 쓴다 (짧은 상한이면 붐비는 기계에서 읽기 전에 빈 출력 = 결정 없음으로 읽었다, 18장 d6). 포기 상한만
        let drained = done.wait(timeout: .now() + 60) == .success
        // 결정이 비면 시험이 그 까닭(시간 초과 · 신호 · 다 못 읽음)을 읽는다 (종료 모양만, 글 없음)
        append("shell_runs", ["outcome": process.terminationReason == .uncaughtSignal ? "signal" : "exit", "status": Int(process.terminationStatus), "drained": drained])
        return (String(decoding: collected.data, as: UTF8.self), process.terminationStatus)
    }

    final class OutputBox: @unchecked Sendable {
        var data = Data()
    }

    // MARK: 훅

    static func hookCommands(_ path: String) -> (sessionStart: String?, preToolUse: String?) {
        guard let data = FileManager.default.contents(atPath: path), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hooks = object["hooks"] as? [String: Any] else { return (nil, nil) }
        func command(_ key: String) -> String? {
            guard let groups = hooks[key] as? [[String: Any]], let first = groups.first, let entries = first["hooks"] as? [[String: Any]] else { return nil }
            return entries.first?["command"] as? String
        }
        return (command("SessionStart"), command("PreToolUse"))
    }

    static func sessionStart(_ command: String, resume: Bool, cwd: String) {
        let name = resume ? "SessionStart:resume" : "SessionStart:startup"
        emit(["type": "system", "subtype": "hook_started", "hook_name": name, "hook_event": "SessionStart", "session_id": sessionID])
        let input = try? JSONSerialization.data(withJSONObject: ["hook_event_name": "SessionStart", "source": resume ? "resume" : "startup", "session_id": sessionID, "cwd": cwd])
        let (stdout, code) = shell(command, input: input ?? Data(), timeout: 10)
        emit(["type": "system", "subtype": "hook_response", "hook_name": name, "hook_event": "SessionStart", "output": stdout, "stdout": stdout, "stderr": "", "exit_code": code,
              "outcome": code == 0 ? "success" : "error", "session_id": sessionID])
        report["session_start_stdout"] = stdout
    }

    enum Outcome {
        case done
        case deferred(id: String, name: String, input: [String: Any])
    }

    /// 도구 호출 하나: (assistant tool_use) → PreToolUse 훅 → 결정대로 실행 · 거절 · 보류
    static func call(id: String, name: String, input: [String: Any], step: [String: Any], hook: String?, cwd: String, announce: Bool) -> Outcome {
        if announce { assistant(["type": "tool_use", "id": id, "name": name, "input": input]) }
        checkInterrupt()
        var effective = input
        if step["skip_hook"] as? Bool == true || hook == nil {
            execute(id: id, name: name, input: effective, step: step)
            return .done
        }
        emit(["type": "system", "subtype": "hook_started", "hook_name": "PreToolUse:\(name)", "hook_event": "PreToolUse", "session_id": sessionID])
        let hookInput: [String: Any] = [
            "session_id": sessionID, "transcript_path": NSHomeDirectory() + "/.fake-claude/transcript.jsonl", "cwd": cwd,
            "permission_mode": step["permission_mode"] as? String ?? "default", "hook_event_name": "PreToolUse", "tool_name": name, "tool_input": input, "tool_use_id": id,
        ]
        let started = Date()
        let (stdout, code) = shell(hook!, input: (try? JSONSerialization.data(withJSONObject: hookInput)) ?? Data(), timeout: 10)
        append("hook_ms", Int(Date().timeIntervalSince(started) * 1000))
        emit(["type": "system", "subtype": "hook_response", "hook_name": "PreToolUse:\(name)", "hook_event": "PreToolUse", "output": stdout, "stdout": stdout, "stderr": "",
              "exit_code": code, "outcome": code == 0 ? "success" : "error", "session_id": sessionID])
        let output = (try? JSONSerialization.jsonObject(with: Data(stdout.utf8)) as? [String: Any])?["hookSpecificOutput"] as? [String: Any]
        let decision = code == 2 ? "deny" : (output?["permissionDecision"] as? String ?? "")
        let reason = output?["permissionDecisionReason"] as? String ?? "hook error"
        append("decisions", ["id": id, "tool": name, "decision": decision])
        checkInterrupt()
        switch decision {
        case "allow":
            if let updated = output?["updatedInput"] as? [String: Any] { effective = updated }
            execute(id: id, name: name, input: effective, step: step)
        case "deny":
            denials.append(["tool_name": name, "tool_use_id": id])
            toolResult(id, reason, isError: true)
        case "defer":
            return .deferred(id: id, name: name, input: input)
        default:
            // 결정 없음: manual 모드에서 쓰기는 거절, 읽기는 그냥 허용 (S0 CC-10)
            if ["Read", "Glob", "Grep"].contains(name) {
                execute(id: id, name: name, input: effective, step: step)
            } else {
                emit(["type": "system", "subtype": "permission_denied", "tool_name": name, "tool_use_id": id, "session_id": sessionID])
                denials.append(["tool_name": name, "tool_use_id": id])
                toolResult(id, "Permission to use \(name) has been denied.", isError: true)
            }
        }
        return .done
    }

    static func execute(id: String, name: String, input: [String: Any], step: [String: Any]) {
        switch name {
        case "Write":
            guard let path = input["file_path"] as? String, let content = input["content"] as? String else { return toolResult(id, "InputValidationError", isError: true) }
            try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            let ok = FileManager.default.createFile(atPath: path, contents: Data(content.utf8))
            toolResult(id, ok ? "File created successfully at: \(path)" : "write failed", isError: !ok)
        case "Edit":
            guard let path = input["file_path"] as? String, let old = input["old_string"] as? String, let new = input["new_string"] as? String,
                  let text = try? String(contentsOfFile: path, encoding: .utf8), text.contains(old) else { return toolResult(id, "edit failed", isError: true) }
            try? text.replacingOccurrences(of: old, with: new).write(toFile: path, atomically: true, encoding: .utf8)
            toolResult(id, "The file \(path) has been updated.", isError: false)
        case "Bash":
            let command = input["command"] as? String ?? ""
            append("bash_commands", command)
            if let seconds = step["sleep"] as? Int, seconds > 0 {
                runSleep(id: id, seconds: seconds)
            } else {
                let (stdout, code) = shell(command, input: Data(), timeout: 10)
                toolResult(id, String(stdout.prefix(2000)), isError: code != 0)
            }
        case "mcp__tf__ask_user":
            guard let mcp, let reply = mcp.request("tools/call", params: ["name": "ask_user", "arguments": input]), let result = reply["result"] as? [String: Any] else {
                return toolResult(id, "MCP error", isError: true)
            }
            let text = ((result["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
            append("mcp_results", text)
            toolResult(id, text, isError: result["isError"] as? Bool ?? false)
        default:
            toolResult(id, "ok", isError: false)
        }
    }

    /// 오래 걸리는 Bash (자식 `sleep`): SIGINT를 받으면 자식을 끝내고 중단 결과를 낸다
    static func runSleep(id: String, seconds: Int) {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = [String(seconds)]
        try? child.run()
        report["sleep_pid"] = Int(child.processIdentifier)
        saveReport()
        emit(["type": "system", "subtype": "task_started", "task_id": "t1", "tool_use_id": id, "session_id": sessionID])
        while child.isRunning {
            if fakeInterrupted != 0 {
                kill(child.processIdentifier, SIGKILL)
                child.waitUntilExit()
                emit(["type": "system", "subtype": "task_notification", "task_id": "t1", "tool_use_id": id, "status": "stopped", "session_id": sessionID])
                toolResult(id, "The user doesn't want to proceed with this tool use.", isError: true)
                checkInterrupt()
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        toolResult(id, "", isError: false)
    }

    // MARK: 인자

    static func parse(_ arguments: [String]) -> Flags? {
        var flags = Flags()
        var seen = Set<String>()
        var index = 0
        func value() -> String? {
            index += 1
            return index < arguments.count ? arguments[index] : nil
        }
        while index < arguments.count {
            let token = arguments[index]
            guard seen.insert(token).inserted else { return nil }
            switch token {
            case "-p", "--verbose", "--include-hook-events", "--strict-mcp-config": break
            case "--output-format": guard value() == "stream-json" else { return nil }
            case "--max-budget-usd": guard let budget = value(), Double(budget) != nil else { return nil }
            case "--tools":
                guard let tools = value(), ["Read,Glob,Grep,Edit,Write,Bash", "Read,Glob,Grep"].contains(tools) else { return nil }
                flags.tools = tools
            case "--mcp-config": guard let path = value() else { return nil }; flags.mcpConfig = path
            case "--add-dir": guard let path = value() else { return nil }; flags.addDir = path
            case "--settings": guard let path = value() else { return nil }; flags.settings = path
            case "--setting-sources": guard value() == "project" else { return nil }
            case "--permission-mode": guard value() == "manual" else { return nil }
            case "--append-system-prompt": guard let text = value() else { return nil }; flags.systemPrompt = text
            case "--session-id": flags.sessionID = value()
            case "--resume": flags.resume = value()
            default: return nil
            }
            index += 1
        }
        let required: Set<String> = ["-p", "--output-format", "--verbose", "--include-hook-events", "--max-budget-usd", "--tools", "--strict-mcp-config", "--mcp-config", "--add-dir",
                                     "--settings", "--setting-sources", "--permission-mode", "--append-system-prompt"]
        guard required.isSubset(of: seen), (flags.sessionID == nil) != (flags.resume == nil) else { return nil }
        // 프롬프트는 `--add-dir`과 순서가 정해져 있지 않으므로 다 읽은 뒤에 대조한다
        guard promptNamesWorkspace(flags.systemPrompt, addDir: flags.addDir) else { return nil }
        return flags
    }

    /// 커널이 실제로 실행한 파일 (`_NSGetExecutablePath`, 8장 8: 검사한 realpath로 띄웠나)
    static func executablePath() -> String {
        var size: UInt32 = 4096
        var buffer = [CChar](repeating: 0, count: Int(size))
        guard _NSGetExecutablePath(&buffer, &size) == 0 else { return "" }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// 같은 프로세스 그룹에 남는 자손 하나 (`sleep 600`, 기다리지 않는다. 8장 13). 파이프를 물려주지 않는다 (가짜 자신은 바로 끝난다)
    static func leaveChild() {
        var pid: pid_t = 0
        let argv: [UnsafeMutablePointer<CChar>?] = [strdup("/bin/sleep"), strdup("600"), nil]
        defer { for pointer in argv { free(pointer) } }
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        for fd in [Int32(0), 1, 2] { posix_spawn_file_actions_addopen(&actions, fd, "/dev/null", fd == 0 ? O_RDONLY : O_WRONLY, 0) }
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT))
        if posix_spawn(&pid, "/bin/sleep", &actions, &attributes, argv, environ) == 0 {
            report["left_child_pid"] = Int(pid)
            saveReport()
        }
    }

    /// 세션을 떠난(setsid) 자손 하나: Claude Code 2.1.241은 Bash 도구 명령을 `detached`로 띄운다 (9장 4). SIGINT를 무시하고 600초 잔다.
    /// 환경은 가짜의 것을 그대로 물려받는다 (spawn marker 포함). SIGINT를 무시하기 시작한 뒤에 돌아온다 (그 전에 끝내기가 오면 시험이 흔들린다: 준비 파일을 2초까지 기다린다)
    static func detachChild() {
        var pid: pid_t = 0
        let ready = (reportURL?.path ?? NSTemporaryDirectory() + "fake-claude") + ".detached-ready"
        let script = "use POSIX; POSIX::setsid(); $SIG{INT} = 'IGNORE'; open(my $f, '>', $ARGV[0]); close($f); sleep 600;"
        let argv: [UnsafeMutablePointer<CChar>?] = [strdup("/usr/bin/perl"), strdup("-e"), strdup(script), strdup(ready), nil]
        defer { for pointer in argv { free(pointer) } }
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        for fd in [Int32(0), 1, 2] { posix_spawn_file_actions_addopen(&actions, fd, "/dev/null", fd == 0 ? O_RDONLY : O_WRONLY, 0) }
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT))
        if posix_spawn(&pid, "/usr/bin/perl", &actions, &attributes, argv, environ) == 0 {
            report["detached_child_pid"] = Int(pid)
            saveReport()
            for _ in 0..<200 where !FileManager.default.fileExists(atPath: ready) { Thread.sleep(forTimeInterval: 0.01) }
        }
    }

    /// 짧게 사는 중간 셸 밑의 setsid 손자 (셸은 0.3초 뒤 끝난다, 9장 4 정정): 감독이 그 셸을 살아 있을 때 보아 둬야 손자를 찾는다.
    /// 손자는 SIGINT를 무시하고, 준비되면 자기 pid를 준비 파일에 적는다 (2초까지 기다려 보고에 넣는다)
    static func detachGrandchild() {
        var pid: pid_t = 0
        let ready = (reportURL?.path ?? NSTemporaryDirectory() + "fake-claude") + ".grandchild-ready"
        let perl = "use POSIX; POSIX::setsid(); $SIG{INT} = 'IGNORE'; open(my $f, '>', $ARGV[0]); print $f $$; close($f); sleep 600;"
        let shell = "/usr/bin/perl -e \"$2\" \"$1\" & sleep 0.3"
        let argv: [UnsafeMutablePointer<CChar>?] = [strdup("/bin/sh"), strdup("-c"), strdup(shell), strdup("sh"), strdup(ready), strdup(perl), nil]
        defer { for pointer in argv { free(pointer) } }
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        for fd in [Int32(0), 1, 2] { posix_spawn_file_actions_addopen(&actions, fd, "/dev/null", fd == 0 ? O_RDONLY : O_WRONLY, 0) }
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT))
        guard posix_spawn(&pid, "/bin/sh", &actions, &attributes, argv, environ) == 0 else { return }
        for _ in 0..<200 {
            if let text = try? String(contentsOfFile: ready, encoding: .utf8), let grandchild = Int(text), grandchild > 1 {
                report["detached_grandchild_pid"] = grandchild
                saveReport()
                return
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
    }

    /// 끝나는 시각 (닫기와 다음 턴이 겹치지 않는지 보는 시험, 9장 10)
    static func markEnded() {
        report["ended_at"] = Date().timeIntervalSince1970
        saveReport()
    }

    static func readStdin() -> Data {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            let count = read(STDIN_FILENO, &buffer, buffer.count)
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { break }
            data.append(contentsOf: buffer[0..<count])
        }
        return data
    }

    // MARK: 본체

    static func main(openFDs: [Int32], environmentKeys: [String]) -> Int32 {
        signal(SIGPIPE, SIG_IGN)
        signal(SIGINT) { _ in fakeInterrupted = 1 }
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard let home = ProcessInfo.processInfo.environment["HOME"] else { return 4 }
        let folder = URL(fileURLWithPath: home).appending(path: ".fake-claude", directoryHint: .isDirectory)
        let scenario = (try? JSONSerialization.jsonObject(with: Data(contentsOf: folder.appending(path: "scenario.json")))) as? [String: Any] ?? [:]
        if arguments == ["--version"] {
            print(scenario["version"] as? String ?? "2.1.241 (Claude Code)")
            return 0
        }
        if arguments == ["auth", "status"] {
            let auth = scenario["auth"] ?? ["loggedIn": true, "authMethod": "claude.ai", "email": "someone@example.com"]
            print(String(decoding: (try? JSONSerialization.data(withJSONObject: auth)) ?? Data(), as: UTF8.self))
            return 0
        }
        guard let flags = parse(arguments) else {
            FileHandle.standardError.write(Data("unexpected flags\n".utf8))
            return 3
        }
        // 실행 번호
        let counter = folder.appending(path: "count")
        let number = Int((try? String(contentsOf: counter, encoding: .utf8)) ?? "0") ?? 0
        try? String(number + 1).write(to: counter, atomically: true, encoding: .utf8)
        reportURL = folder.appending(path: "report-\(number).json")
        let runs = scenario["runs"] as? [[String: Any]] ?? [[:]]
        let run = runs[min(number, runs.count - 1)]
        sessionID = flags.sessionID ?? flags.resume ?? ""
        let cwd = FileManager.default.currentDirectoryPath
        let stdin = readStdin()
        report = [
            "args_ok": true, "project_instructions": flags.systemPrompt.contains(projectOpen), "fds": openFDs.map(Int.init), "env_keys": environmentKeys.sorted(), "stdin_bytes": stdin.count, "resume": flags.resume != nil,
            "session_id": sessionID, "cwd": cwd, "tools": flags.tools, "pid": Int(getpid()), "pgid": Int(getpgrp()),
            "argv0": CommandLine.arguments.first ?? "", "exec_path": executablePath(), "started_at": Date().timeIntervalSince1970,
        ]
        saveReport()
        // SIGINT를 듣지 않는 CLI (일반 Stop도 SIGKILL로 이어지는지, 9장 6)
        if run["ignore_sigint"] as? Bool == true { signal(SIGINT, SIG_IGN) }
        if run["detached_child_early"] as? Bool == true { detachChild() }
        if run["die"] as? String == "before_init" { kill(getpid(), SIGKILL) }

        let hooks = hookCommands(flags.settings)
        if let config = (try? JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: flags.mcpConfig)))) as? [String: Any],
           let servers = config["mcpServers"] as? [String: Any], let tf = servers["tf"] as? [String: Any], let command = tf["command"] as? String {
            mcp = MCPClient(command: command, arguments: tf["args"] as? [String] ?? [])
        }
        let mcpTools = mcp?.toolNames ?? []
        if run["skip_session_start"] as? Bool != true, let command = hooks.sessionStart {
            sessionStart(command, resume: flags.resume != nil, cwd: cwd)
        }
        checkInterrupt()
        // 보류를 답하는 빈 stdin resume: 보류 id의 훅을 init보다 먼저 부른다 (S0 r3-cc9-2 순서)
        let deferredFile = folder.appending(path: "deferred-\(sessionID).json")
        if flags.resume != nil, stdin.isEmpty, let saved = (try? JSONSerialization.jsonObject(with: Data(contentsOf: deferredFile))) as? [String: Any],
           let id = saved["id"] as? String, let name = saved["name"] as? String, var input = saved["input"] as? [String: Any] {
            try? FileManager.default.removeItem(at: deferredFile)
            if let override = run["resume_input_override"] as? [String: Any] { input = override }
            // 멈춘 동안 SIGINT가 오면 훅을 부르지 않고 끝난다 (Stop이 답 훅보다 먼저, 14장 7)
            if let pause = run["pause_before_resume_hook"] as? Double { pauseInterruptibly(pause) }
            // 시험이 표시 파일을 만들 때까지 (시간 대신 그 사건으로, 120초 포기 상한). 기다리는 동안 SIGINT면 위와 같다
            if let gate = run["wait_for_file_before_resume_hook"] as? String { waitInterruptibly(forFile: gate, max: 120) }
            emit(["type": "command_lifecycle", "state": "started", "session_id": sessionID])
            // 보류 id가 아닌 다른 tool id로 부른다 (상태 유실 흉내, 14장 7)
            let resumeID = run["resume_id_override"] as? String ?? id
            if case .deferred(let again, let againName, let againInput) = call(id: resumeID, name: name, input: input, step: [:], hook: hooks.preToolUse, cwd: cwd, announce: false) {
                return finishDeferred(id: again, name: againName, input: againInput, file: deferredFile)
            }
            if let pause = run["pause_after_resume_hook"] as? Double { pauseInterruptibly(pause) }
        }
        let initVersion = run["init_version"] as? String ?? "2.1.241"
        let tools = flags.tools.split(separator: ",").map(String.init) + mcpTools.map { "mcp__tf__\($0)" }
        emit([
            "type": "system", "subtype": "init", "cwd": cwd, "session_id": sessionID, "tools": tools,
            "mcp_servers": mcp.map { [["name": "tf", "status": $0.toolNames.isEmpty ? "failed" : "connected"]] } ?? [], "model": "claude-sonnet-5",
            "permissionMode": "default", "claude_code_version": initVersion, "apiKeySource": "none", "plugins": [], "skills": [],
        ])
        checkInterrupt()
        if run["die"] as? String == "after_init" { kill(getpid(), SIGKILL) }
        if run["synthetic_login_error"] as? Bool == true {
            assistant(["type": "text", "text": "Not logged in · Please run /login"], model: "<synthetic>", error: "authentication_failed")
            emit(["type": "result", "subtype": "success", "is_error": true, "stop_reason": "stop_sequence", "terminal_reason": "api_error", "session_id": sessionID,
                  "result": "Not logged in · Please run /login"])
            mcp?.stop()
            return 1
        }
        var lastDeferred: (id: String, name: String, input: [String: Any])?
        for step in run["steps"] as? [[String: Any]] ?? [] {
            checkInterrupt()
            if let text = step["text"] as? String {
                lastText = text
                assistant(["type": "text", "text": text])
            } else if let name = step["tool"] as? String {
                let id = step["id"] as? String ?? "toolu_\(UUID().uuidString.prefix(8))"
                let input = step["input"] as? [String: Any] ?? [:]
                if case .deferred(let deferredID, let deferredName, let deferredInput) = call(id: id, name: name, input: input, step: step, hook: hooks.preToolUse, cwd: cwd, announce: true) {
                    lastDeferred = (deferredID, deferredName, deferredInput)
                    if step["same_response"] as? Bool != true { break }
                }
            }
        }
        checkInterrupt()
        if let lastDeferred {
            return finishDeferred(id: lastDeferred.id, name: lastDeferred.name, input: lastDeferred.input, file: deferredFile)
        }
        if let final = run["final_text"] as? String {
            lastText = final
            assistant(["type": "text", "text": final])
        }
        if run["leave_child"] as? Bool == true { leaveChild() }
        if run["detached_child"] as? Bool == true { detachChild() }
        if run["detached_grandchild"] as? Bool == true { detachGrandchild() }
        emit(["type": "result", "subtype": "success", "is_error": false, "stop_reason": "end_turn", "terminal_reason": "completed", "session_id": sessionID, "result": lastText,
              "permission_denials": denials])
        mcp?.stop()
        if let linger = run["linger_after_result"] as? Double { Thread.sleep(forTimeInterval: linger) }
        // 결과 뒤 시험이 표시 파일을 만들 때까지 머문다 (시간 대신 그 사건으로, 120초 포기 상한)
        if let gate = run["wait_for_file_after_result"] as? String { waitInterruptibly(forFile: gate, max: 120) }
        saveReport()
        return 0
    }

    /// 한 응답에서 보류된 마지막 호출만 보고한다 (S0 CC-3a · CC-9)
    static func finishDeferred(id: String, name: String, input: [String: Any], file: URL) -> Int32 {
        if let data = try? JSONSerialization.data(withJSONObject: ["id": id, "name": name, "input": input]) { try? data.write(to: file) }
        emit(["type": "result", "subtype": "success", "is_error": false, "stop_reason": "tool_deferred", "terminal_reason": "tool_deferred", "session_id": sessionID,
              "deferred_tool_use": ["id": id, "name": name, "input": input], "permission_denials": denials])
        report["deferred"] = id
        saveReport()
        mcp?.stop()
        return 0
    }
}

/// `tf` MCP 서버 (stdio JSON-RPC) 대화
final class MCPClient {
    let process = Process()
    let input = Pipe()
    let output = Pipe()
    var buffer = Data()
    var nextID = 1
    var toolNames: [String] = []

    init(command: String, arguments: [String]) {
        process.executableURL = URL(fileURLWithPath: command)
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return }
        _ = request("initialize", params: ["protocolVersion": "2025-06-18", "capabilities": [:], "clientInfo": ["name": "fake-claude", "version": "0"]])
        send(["jsonrpc": "2.0", "method": "notifications/initialized"])
        if let reply = request("tools/list", params: [:]), let result = reply["result"] as? [String: Any], let tools = result["tools"] as? [[String: Any]] {
            toolNames = tools.compactMap { $0["name"] as? String }
            Fake.report["mcp_tools"] = toolNames
        }
    }

    func send(_ object: [String: Any]) {
        guard var data = try? JSONSerialization.data(withJSONObject: object) else { return }
        data.append(0x0A)
        input.fileHandleForWriting.write(data)
    }

    func request(_ method: String, params: [String: Any]) -> [String: Any]? {
        let id = nextID
        nextID += 1
        send(["jsonrpc": "2.0", "id": id, "method": method, "params": params])
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<newline]
                buffer = Data(buffer[buffer.index(after: newline)...])
                if let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any], object["id"] as? Int == id { return object }
                continue
            }
            let chunk = output.fileHandleForReading.availableData
            if chunk.isEmpty { return nil }
            buffer.append(chunk)
        }
        return nil
    }

    func stop() {
        try? input.fileHandleForWriting.close()
        process.waitUntilExit()
    }
}

/// exec 때 받은 환경의 키 (`KERN_PROCARGS2`, 14장 10): Foundation이 시작하며 자기 환경에 더한 값(`__CF_USER_TEXT_ENCODING`)은 넘겨받은 것이 아니다. 읽지 못하면 nil
func fakeExecEnvironmentKeys() -> [String]? {
    var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, getpid()]
    var size = 0
    guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
    var buffer = [UInt8](repeating: 0, count: size)
    guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
    let argc = buffer.withUnsafeBytes { $0.load(as: Int32.self) }
    var index = MemoryLayout<Int32>.size
    while index < size, buffer[index] != 0 { index += 1 }
    while index < size, buffer[index] == 0 { index += 1 }
    func next() -> String {
        let start = index
        while index < size, buffer[index] != 0 { index += 1 }
        defer { index += 1 }
        return String(decoding: buffer[start..<index], as: UTF8.self)
    }
    for _ in 0..<argc where index < size { _ = next() }
    var keys: [String] = []
    while index < size {
        let entry = next()
        if entry.isEmpty { break }
        keys.append(String(entry.prefix { $0 != "=" }))
    }
    return keys
}

/// `--disclaim-spawn <실행 파일> [인자…]`: 책임 프로세스를 내려놓고(disclaim) 띄운 뒤 그 pid를 쓰고 끝난다 (다시 disclaim한 자손 시험, 14장 5. 터미널 · 실행기 흉내)
func fakeDisclaimSpawn(_ command: [String]) -> Int32 {
    typealias SetDisclaim = @convention(c) (UnsafeMutablePointer<posix_spawnattr_t?>, Int32) -> Int32
    guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_spawnattrs_setdisclaim"), let path = command.first else { return 5 }
    var attributes: posix_spawnattr_t?
    posix_spawnattr_init(&attributes)
    defer { posix_spawnattr_destroy(&attributes) }
    guard unsafeBitCast(symbol, to: SetDisclaim.self)(&attributes, 1) == 0 else { return 5 }
    let argv: [UnsafeMutablePointer<CChar>?] = command.map { strdup($0) } + [nil]
    defer { for pointer in argv { free(pointer) } }
    var pid: pid_t = 0
    guard posix_spawn(&pid, path, nil, &attributes, argv, environ) == 0 else { return 6 }
    print(pid)
    fflush(stdout)
    return 0
}

/// `--spawn-then-exec <실행 파일> [인자…]`: 그것(지킴이)을 띄워 멈춰 두고, 이 프로세스는 Apple 서명 `/bin/sleep`으로 exec한 뒤 0.4초 뒤에 풀어 준다
/// (15장 6: 부른 쪽이 지킴이를 띄운 뒤 exec해 서명 확인을 속이는 모양, sec `callerexec`)
func fakeSpawnThenExec(_ command: [String]) -> Int32 {
    guard let path = command.first else { return 5 }
    let argv: [UnsafeMutablePointer<CChar>?] = command.map { strdup($0) } + [nil]
    var pid: pid_t = 0
    guard posix_spawn(&pid, path, nil, nil, argv, environ) == 0 else { return 6 }
    kill(pid, SIGSTOP)
    // 풀어 주는 쪽은 따로 (이 프로세스는 곧 exec한다)
    let resumeArgv: [UnsafeMutablePointer<CChar>?] = [strdup("/bin/sh"), strdup("-c"), strdup("/bin/sleep 0.4; kill -CONT \(pid)"), nil]
    var resumer: pid_t = 0
    guard posix_spawn(&resumer, "/bin/sh", nil, nil, resumeArgv, environ) == 0 else { return 6 }
    let sleepArgv: [UnsafeMutablePointer<CChar>?] = [strdup("sleep"), strdup("3"), nil]
    execv("/bin/sleep", sleepArgv)
    return 7
}

if CommandLine.arguments.count >= 3, CommandLine.arguments[1] == "--disclaim-spawn" { exit(fakeDisclaimSpawn(Array(CommandLine.arguments.dropFirst(2)))) }
// 띄운 뒤에도 부모로 남는다 (15장 3: Claude 데스크톱 · Chrome native host처럼 무관한 앱이 disclaim으로 띄운 자식)
if CommandLine.arguments.count >= 3, CommandLine.arguments[1] == "--disclaim-spawn-stay" {
    let status = fakeDisclaimSpawn(Array(CommandLine.arguments.dropFirst(2)))
    if status != 0 { exit(status) }
    while true { sleep(60) }
}
if CommandLine.arguments.count >= 3, CommandLine.arguments[1] == "--spawn-then-exec" { exit(fakeSpawnThenExec(Array(CommandLine.arguments.dropFirst(2)))) }

// 시작하자마자 (Foundation이 무엇을 열기 전에) 열린 fd · 환경 키를 본다 (E16 · E23)
let fakeOpenFDs: [Int32] = (0..<256).map { Int32($0) }.filter { fcntl($0, F_GETFD) != -1 }
let fakeExecKeys = fakeExecEnvironmentKeys()
var fakeEnvironmentKeys: [String] = fakeExecKeys ?? []
if fakeExecKeys == nil, var pointer = Optional(environ) {
    while let entry = pointer.pointee {
        fakeEnvironmentKeys.append(String(String(cString: entry).prefix { $0 != "=" }))
        pointer += 1
    }
}
let fakeStatus = Fake.main(openFDs: fakeOpenFDs, environmentKeys: fakeEnvironmentKeys)
if Fake.reportURL != nil { Fake.markEnded() }
exit(fakeStatus)
