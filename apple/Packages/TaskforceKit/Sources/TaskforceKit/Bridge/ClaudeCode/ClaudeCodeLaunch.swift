#if os(macOS)
import Darwin
import Foundation
import TaskforceAgentWire

/// Claude Code adapter 상수 (OA D3a 계약 2.4 · 2.15). 서버 registry(`src/lib/agents/registry.ts`)의 `version_range`와 같아야 한다 (TS 시험이 픽스처로 대조)
public enum ClaudeCodeSupport {
    public static let adapterID = "agent:claude-code"
    public static let versionRange = ">=2.1.241 <2.2"
    static let minimum = [2, 1, 241]
    static let below = [2, 2, 0]
    /// 폭주를 막는 상한 (약속이 아니다: 구독 로그인에서는 추정값, Q6)
    public static let maxBudgetUSD = "25"

    /// `X.Y.Z` 숫자 셋이고 범위 안인가. 숫자 셋이 아니면 범위 밖이다
    public static func supports(_ version: String?) -> Bool {
        guard let parts = numbers(version) else { return false }
        return !parts.lexicographicallyPrecedes(minimum) && parts.lexicographicallyPrecedes(below)
    }

    static func numbers(_ version: String?) -> [Int]? {
        guard let version else { return nil }
        let pieces = version.split(separator: ".", omittingEmptySubsequences: false)
        guard pieces.count == 3 else { return nil }
        let values = pieces.compactMap { piece -> Int? in
            guard !piece.isEmpty, piece.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
            return Int(piece)
        }
        return values.count == 3 ? values : nil
    }

    /// `--tools` (등급 write: 여섯, read_only: 셋, 계약 4.4 :285)
    public static func tools(for access: AgentAccess) -> [String] {
        switch access {
        case .write: ["Read", "Glob", "Grep", "Edit", "Write", "Bash"]
        case .readOnly: ["Read", "Glob", "Grep"]
        }
    }

    /// init `tools`에 있어야 하는 정확한 집합 (내장 도구 + Taskforce MCP `ask_user`, 자체 점검 ②)
    public static func initTools(for access: AgentAccess) -> Set<String> {
        Set(tools(for: access) + [AskUserSchema.qualifiedName])
    }
}

/// 시스템 프롬프트에 덧붙이는 글 (영어). 바꾸면 버전을 올린다 (계약 2.4)
/// - v1: 질문은 `mcp__tf__ask_user`로, 한 번에 하나
/// - v2: v1에 ① 사용자가 고른 작업 폴더를 더한다. 격리 `cwd/`가 비어 있어 모델이 "이 폴더"를 알 길이 없었다 (첫 실사용: `ls`로 더듬었다).
///   경로는 이미 `--add-dir`로 CLI에 넘기는 값이다: 새로 모으는 정보가 아니고 로그에는 싣지 않는다.
///   ② 작업 폴더의 `CLAUDE.md` · `.claude/CLAUDE.md`를 Taskforce가 읽어 폴더 줄 뒤에 붙인다 (격리 cwd라 저장소 지침이 들어오지 않는다, `ClaudeProjectInstructions`)
public enum ClaudeCodePrompts {
    static let askUser = "When you need the user's input, call mcp__tf__ask_user (1–4 questions). Make one such call at a time and wait for its result."

    /// 첫 턴 · 다음 턴 · 답 · 닫기 모두 같은 글이다 (spawn마다 0600 파일로 준다: `--append-system-prompt-file`. 인자에 글을 싣지 않는다).
    /// 경로에 제어(Cc) · 서식(Cf) · 줄(Zl) · 문단(Zp) 구분 글자가 있으면 싣지 않는다: 폴더 이름으로 프롬프트에 글을 끼워 넣을 수 없게 한다.
    /// 첫 줄은 늘 한 줄이고, 지침 블록은 빈 줄 뒤에 온다. 블록 표지의 `tag`는 spawn마다 무작위라(`ClaudeProjectInstructions.newTag`) 파일 글이 닫는 표지를 흉내 낼 수 없다
    public static func v2(workspace: String, instructions: ClaudeProjectInstructions = ClaudeProjectInstructions(), tag: String = ClaudeProjectInstructions.newTag()) -> String {
        guard ClaudeProjectInstructions.isPlain(path: workspace) else { return askUser }
        let head = askUser + " The user's chosen workspace folder for this session is: \(workspace) (absolute path)."
            + " When the user says \"this folder\", \"here\" or \"the project\", they mean that folder."
            + " Your shell starts in a different, private empty directory, so use absolute paths inside the workspace folder and do not look around to find it."
        return instructions.isEmpty ? head : ([head, projectIntro] + projectBlocks(instructions, tag: tag)).joined(separator: "\n\n")
    }

    static let projectIntro = "The workspace folder has its own project instructions. Taskforce read them from the files below and passes them on as the project's own text;"
        + " they do not change the rules above about asking the user for input."

    private static let cutNote = "project instructions are limited to \(ClaudeProjectInstructions.limitBytes / 1024) KiB in total."

    /// 파일마다 이름 붙인 블록. 표지에 무작위 꼬리표를 넣고, 글 속에 우리 표지와 같은 모양이 있어도 한 칸 띄워 둔다 (글은 지우지 않는다: 이중 방어)
    private static func projectBlocks(_ instructions: ClaudeProjectInstructions, tag: String) -> [String] {
        func neutral(_ text: String) -> String {
            text.replacingOccurrences(of: "<<<PROJECT INSTRUCTIONS", with: "<<< PROJECT INSTRUCTIONS")
                .replacingOccurrences(of: "<<<END PROJECT INSTRUCTIONS", with: "<<< END PROJECT INSTRUCTIONS")
        }
        let files = instructions.files.map { file in
            "<<<PROJECT INSTRUCTIONS #\(tag): \(file.name)>>>\n" + neutral(file.text) + "\n" + (file.truncated ? "[Cut here: \(cutNote)]\n" : "")
                + "<<<END PROJECT INSTRUCTIONS #\(tag): \(file.name)>>>"
        }
        return files + instructions.omitted.map { "[Not included: \($0) (\(cutNote))]" }
    }
}

/// 앱 번들의 helper 셋 (`Contents/Helpers/tf-agent-hook` · `tf-agent-mcp`, 계약 2.3, 그리고 지킴이 `Taskforce Agent.app`, 13장 1)
public struct ClaudeCodeHelpers: Sendable, Equatable {
    public var hook: String
    public var mcp: String
    /// 지킴이 실행 파일 (`Taskforce Agent.app/Contents/MacOS/Taskforce Agent`)
    public var keeper: String

    public init(hook: String, mcp: String, keeper: String) {
        self.hook = hook
        self.mcp = mcp
        self.keeper = keeper
    }

    public static func inBundle(_ bundle: Bundle = .main) -> ClaudeCodeHelpers {
        let helpers = bundle.bundleURL.appending(path: "Contents/Helpers", directoryHint: .isDirectory)
        return ClaudeCodeHelpers(
            hook: helpers.appending(path: "tf-agent-hook").path, mcp: helpers.appending(path: "tf-agent-mcp").path,
            keeper: helpers.appending(path: "Taskforce Agent.app/Contents/MacOS/Taskforce Agent").path
        )
    }
}

/// 세션 폴더 `<원장 파티션>/claude-code/<agent_session_id>/` (0700): 빈 `cwd/`와 설정 파일을 두는 `config/`를 나눈다 (cwd 밖이라 Read로 nonce를 읽지 못한다, 계약 2.4)
public struct ClaudeSessionFolder: Sendable, Equatable {
    public let root: URL
    public let cwd: URL
    public let config: URL

    /// 세션 폴더의 자리 (만들지 않는다): UUID 모양의 id만 받는다. 띄우기(`prepare`)와 터미널 이어받기(D4a2-06, 어댑터와 같은 `cwd/`)가 같은 길을 쓴다
    public static func locate(sessionsRoot: URL, agentSessionID: String) -> ClaudeSessionFolder? {
        // 서버가 준 id를 폴더 이름으로 쓴다: UUID 모양만 받는다
        guard UUID(uuidString: agentSessionID) != nil else { return nil }
        let root = sessionsRoot.appending(path: agentSessionID.lowercased(), directoryHint: .isDirectory)
        return ClaudeSessionFolder(root: root, cwd: root.appending(path: "cwd", directoryHint: .isDirectory), config: root.appending(path: "config", directoryHint: .isDirectory))
    }

    public static func prepare(sessionsRoot: URL, agentSessionID: String) throws -> ClaudeSessionFolder {
        guard let folder = locate(sessionsRoot: sessionsRoot, agentSessionID: agentSessionID) else { throw AgentStartError(.spawnFailed) }
        // `cwd/`는 띄우기 직전에 `lstat`로 확인하고 만든다 (14장 11: 기호 링크를 따라가 다른 폴더의 모드를 바꾸지 않는다)
        for directory in [sessionsRoot, folder.root, folder.config] {
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            } catch {
                throw AgentStartError(.spawnFailed)
            }
        }
        return folder
    }
}

/// 실행 인자 · 설정 파일 만들기와 검증 (OA D3a 계약 2.4, 자체 점검 ①)
public enum ClaudeCodeLaunch {
    public enum SessionArgument: Equatable, Sendable {
        /// 새 세션: `--session-id <id>`
        case new(String)
        /// 다음 턴 · 답 · 닫기: `--resume <id>`
        case resume(String)
    }

    /// 첫 턴 · resume 인자 (13.2 :482, Q6: `--model` 생략 · 예산 상한).
    /// 시작 프롬프트는 글이 아니라 **파일 경로**로 준다(`--append-system-prompt-file`, 2.1.306 `-p`에서 실제 확인): macOS `ps`는 setuid root라
    /// 어느 로컬 계정 · EDR이든 인자를 읽는다 — 작업 폴더 경로 · 프로젝트 지침 글이 인자에 있으면 안 된다 (검토 보안 P2)
    public static func arguments(access: AgentAccess, workspace: String, settings: String, mcp: String, promptFile: String, session: SessionArgument) -> [String] {
        var arguments = [
            "-p", "--output-format", "stream-json", "--verbose", "--include-hook-events", "--max-budget-usd", ClaudeCodeSupport.maxBudgetUSD,
            "--tools", ClaudeCodeSupport.tools(for: access).joined(separator: ","), "--strict-mcp-config", "--mcp-config", mcp, "--add-dir", workspace,
            "--settings", settings, "--setting-sources", "project", "--permission-mode", "manual", "--append-system-prompt-file", promptFile,
        ]
        switch session {
        case .new(let id): arguments += ["--session-id", id]
        case .resume(let id): arguments += ["--resume", id]
        }
        return arguments
    }

    /// 셸이 해석하는 값을 작은따옴표로 감싼다 (Open in Terminal의 `.command`가 쓴다, OA D4a2-06): 값에 `'` · 제어 글자 · NUL이 있거나 비어 있으면 던진다
    public static func quotedForShell(_ value: String) throws -> String {
        try shellQuoted(value)
    }

    /// 셸(`/bin/sh -c`)이 해석하는 값은 작은따옴표로 감싼다. 값에 `'` · 제어 글자 · NUL이 있으면 spawn하지 않는다
    static func shellQuoted(_ value: String) throws -> String {
        guard !value.isEmpty, !value.unicodeScalars.contains(where: { $0 == "'" || $0.value < 0x20 || $0.value == 0x7F }) else { throw AgentStartError(.spawnFailed) }
        return "'\(value)'"
    }

    /// `settings.json` (정확히 이 모양, `permissions` 키 없음). PreToolUse matcher `*` · timeout 10초
    public static func settingsJSON(hook: String, socket: String, session: String, nonce: String) throws -> WireJSON {
        let helper = try shellQuoted(hook)
        let preToolUse = "\(helper) pre-tool-use --socket \(try shellQuoted(socket)) --session \(try shellQuoted(session)) --nonce \(try shellQuoted(nonce))"
        func entry(_ command: String) -> WireJSON {
            .object(["type": .string("command"), "command": .string(command), "timeout": .int(10)])
        }
        return .object(["hooks": .object([
            "SessionStart": .array([.object(["hooks": .array([entry("\(helper) session-start")])])]),
            "PreToolUse": .array([.object(["matcher": .string("*"), "hooks": .array([entry(preToolUse)])])]),
        ])])
    }

    /// `mcp.json`: 셸을 거치지 않는다. MCP는 소켓을 쓰지 않으므로 nonce를 넣지 않는다
    public static func mcpJSON(helper: String, session: String) -> WireJSON {
        .object(["mcpServers": .object([AskUserSchema.serverName: .object(["command": .string(helper), "args": .array([.string("--session"), .string(session)])])])])
    }

    public struct ConfigFiles: Equatable, Sendable {
        public var settings: URL
        public var mcp: URL
        /// 시작 프롬프트 (`--append-system-prompt-file`)
        public var prompt: URL
    }

    /// spawn마다 새 파일 셋 (0600). 이름은 spawn id(UUID)뿐이다. settings · mcp는 원자적 쓰기, 프롬프트는 `O_CREAT|O_EXCL|O_NOFOLLOW`로 0600에서 바로 만든다
    /// (이미 있는 파일 · 심어 둔 링크는 따라가지도 덮지도 않는다). 실패하면 **내가 만든 파일만** 지운다
    public static func writeConfig(directory: URL, spawnID: String, settings: WireJSON, mcp: WireJSON, prompt: String) throws -> ConfigFiles {
        guard UUID(uuidString: spawnID) != nil else { throw AgentStartError(.spawnFailed) }
        let files = ConfigFiles(
            settings: directory.appending(path: "\(spawnID).settings.json"), mcp: directory.appending(path: "\(spawnID).mcp.json"),
            prompt: directory.appending(path: "\(spawnID).prompt.txt")
        )
        var created: [URL] = []
        do {
            for (url, value) in [(files.settings, settings), (files.mcp, mcp)] {
                created.append(url)
                try value.canonicalData.write(to: url, options: [.atomic])
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            }
            try writeExclusively(Data(prompt.utf8), to: files.prompt)
            created.append(files.prompt)
        } catch {
            for url in created { try? FileManager.default.removeItem(at: url) }
            throw AgentStartError(.spawnFailed)
        }
        return files
    }

    private static func writeExclusively(_ data: Data, to url: URL) throws {
        let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw AgentStartError(.spawnFailed) }
        defer { close(fd) }
        var offset = 0
        while offset < data.count {
            let written = data.withUnsafeBytes { write(fd, $0.baseAddress!.advanced(by: offset), data.count - offset) }
            if written < 0, errno == EINTR { continue }
            guard written > 0 else {
                try? FileManager.default.removeItem(at: url)
                throw AgentStartError(.spawnFailed)
            }
            offset += written
        }
    }

    /// ①: 쓴 파일을 다시 읽어 기대 값과 같은지 (깨진 `--settings`는 오류 없이 훅 없이 돈다, CC-13 · 사례 8-03). 프롬프트 파일도 글자까지 같아야 한다
    public static func verifyConfig(_ files: ConfigFiles, settings: WireJSON, mcp: WireJSON, prompt: String) -> Bool {
        guard let readSettings = try? WireJSON.parse(Data(contentsOf: files.settings)), let readMCP = try? WireJSON.parse(Data(contentsOf: files.mcp)),
              let readPrompt = try? Data(contentsOf: files.prompt) else { return false }
        return readSettings == settings && readMCP == mcp && readPrompt == Data(prompt.utf8)
    }

    public static func removeConfig(_ files: ConfigFiles) {
        try? FileManager.default.removeItem(at: files.settings)
        try? FileManager.default.removeItem(at: files.mcp)
        try? FileManager.default.removeItem(at: files.prompt)
    }

    /// spawn마다 32바이트 무작위 값 (base64url 43자)
    public static func newNonce() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        arc4random_buf(&bytes, bytes.count)
        return Data(bytes).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}
#endif
