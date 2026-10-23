#if os(macOS)
import Darwin
import Foundation

/// 백그라운드 일의 출력 꼬리 읽기 (세션 보기 V1, DZ oa-session-view-dz v2 E10 · 열린 질문 3): **한 일의 출력 하나의 끝 부분**만 읽는다.
/// PR-D1 읽기(`ClaudeAppTranscriptReader`)와 같은 수준으로 좁게 닫고, 이 한 파일에 모았다 (보안 검토 대상).
///
/// - **경로는 기록에서 오지 않는다.** (세션 id · 일의 id · 작업 폴더)로 만든다: 일의 id는 영숫자 · `_` · `-` 64자 이하, 세션 id는 소문자 정규 UUID만 (검사가 파일 시스템보다 먼저다).
///   명령 일은 `<임시 폴더>/claude-<uid>/<프로젝트 디렉터리>/<세션 id>/tasks/<일 id>.output`, 에이전트 일은 `<~/.claude>/projects/<프로젝트 디렉터리>/<세션 id>/subagents/agent-<일 id>.jsonl`이다.
///   에이전트 일의 출력 파일은 기호 링크라서 **따라가지 않고** 그 대상인 세션 폴더의 파일을 직접 연다 (같은 하드닝으로).
/// - **그 길의 모든 폴더는 이 uid의 진짜 폴더**다 (기호 링크 아님: `lstat`이 폴더이고 `realpath`가 같은 경로, 임시 폴더 자신만 소유자 · 쓰기 권한을 보지 않는다). **그룹 · 모두가 쓸 수 있는 폴더는 믿지 않는다** (보안 P3-2: 확인과 읽기 사이에 다른 사용자가 이름을 바꿔치기할 수 없는 폴더만).
///   파일은 이 uid의 **일반 파일**이어야 한다 (기호 링크 · FIFO · 폴더 · 남의 파일은 열지도 않는다).
///   열기는 `O_NOFOLLOW` · `O_NONBLOCK` · 열린 fd의 소유자 · 일반 파일 · `F_GETPATH` 일치 (`ExternalSessionFileSystem.read`): 확인한 뒤 길이 바뀌어도 거절한다.
///   프로젝트 디렉터리는 작업 폴더로 짐작하고, 모르거나 맞지 않으면 `claude-<uid>`(또는 `projects`) 아래 **디렉터리 이름만** 나열해(상한 `maxListed`) 그 세션 폴더가 있는 것을 고른다.
/// - **크기 상한**: 명령 출력은 파일 끝 `window`바이트(기본 16 KiB, "Show earlier"로 넓혀도 256 KiB), 에이전트 기록은 끝 2 MiB 창 안의 완성된 줄(한 줄 1 MiB, 글 한 칸 32 KiB)에서 마지막 200개. 큰 파일을 끝까지 읽지 않는다.
/// - **이어 읽기**(`update`): 파일 크기가 그대로면 내용을 읽지 않는다. 에이전트는 마지막으로 읽은 줄의 끝에서부터 새로 붙은 완성된 줄만 읽는다 (줄었거나 창보다 많이 붙었으면 통째로).
///   커서는 파일의 정체(만든 시각)도 안다: 같은 길의 다른 파일이면 크기와 상관없이 통째로 다시 읽는다 (명령 · 에이전트 모두).
/// - 평문으로만 다룬다: 색 코드(ANSI) · 제어 글자 · 눈에 보이지 않는 서식 글자를 지운다. 메모리에만 두고 **로그를 남기지 않는다**: 이 타입에는 로그 자리가 없고 값의 `description`은 글 · 경로 · id를 찍지 않는다.
public struct BackgroundTaskTail: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public struct Limits: Equatable, Sendable {
        /// 명령 출력의 기본 창 (끝에서부터)
        public var tailBytes: Int
        /// "Show earlier"로 넓혀도 넘지 않는 창
        public var maxTailBytes: Int
        /// 에이전트 기록을 읽는 끝 창
        public var windowBytes: Int
        public var maxLineBytes: Int
        public var maxTurns: Int
        public var maxTextBytes: Int

        public static let standard = Limits()

        public init(tailBytes: Int = 16 << 10, maxTailBytes: Int = 256 << 10, windowBytes: Int = 2 << 20, maxLineBytes: Int = 1 << 20, maxTurns: Int = 200, maxTextBytes: Int = 32 << 10) {
            self.tailBytes = tailBytes
            self.maxTailBytes = maxTailBytes
            self.windowBytes = windowBytes
            self.maxLineBytes = maxLineBytes
            self.maxTurns = maxTurns
            self.maxTextBytes = maxTextBytes
        }
    }

    public enum Output: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
        /// 명령 일의 끝 부분. `hasEarlier`: 파일에 더 앞이 있다
        case text(String, hasEarlier: Bool)
        /// 에이전트 일: 그 에이전트의 말 · 도구 단계 (오래된 것이 먼저)
        case agent([ClaudeAppTurn], hasEarlier: Bool)

        public var description: String { "BackgroundTaskTail.Output()" }
        public var debugDescription: String { description }
    }

    public enum Result: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
        case output(Output)
        /// 그 자리에 아직 아무것도 없다 (일이 막 시작해 폴더 · 파일이 아직 없다). 끝난 일이면 지워진 것이다
        case missing
        /// 있는데 열 수 없거나 믿을 수 없다 (기호 링크 · 남의 것 · 일반 파일 아님 · 읽기 실패 · 검사에 걸린 이름)
        case unreadable

        public var description: String {
            switch self {
            case .output: "BackgroundTaskTail.Result.output"
            case .missing: "BackgroundTaskTail.Result.missing"
            case .unreadable: "BackgroundTaskTail.Result.unreadable"
            }
        }

        public var debugDescription: String { description }
    }

    /// 앞 읽기가 남긴 자리 (화면이 쥐고 있다가 다음 `update`에 준다). 값의 뜻은 읽는 쪽만 안다
    public struct Cursor: Equatable, Sendable {
        var size: Int64
        /// 명령: 읽은 창 크기. 에이전트: 다음에 읽을 자리 (완성된 줄의 끝)
        var position: Int64
        /// 읽은 파일의 정체: 만든 시각. 같은 길에 지우고 다시 만든 다른 파일이면 다르다 (크기가 같거나 더 커도 옛 자리에서 이어 읽지 않는다)
        var created: Date
    }

    /// 이어 읽은 결과: 그대로이거나, 화면의 것을 통째로 바꾸거나(`replace`), 에이전트의 새 줄만 덧붙인다 (`append`). 믿을 수 없게 된 길은 커서 없이 `replace`다
    public enum Update: Equatable, Sendable {
        case unchanged
        case replace(Result, Cursor?)
        case append([ClaudeAppTurn], Cursor)
    }

    private let fileSystem: ExternalSessionFileSystem
    /// `$HOME/.claude`
    private let claudeDirectory: String
    private let temporaryRoot: String
    private let limits: Limits

    /// - temporaryRoot: Claude Code의 일 출력이 있는 임시 폴더의 실제 경로 (기본 `/private/tmp`, 시험은 임시 폴더)
    public init(fileSystem: ExternalSessionFileSystem = .live, claudeDirectory: String, temporaryRoot: String = "/private/tmp", limits: Limits = .standard) {
        self.fileSystem = fileSystem
        self.claudeDirectory = claudeDirectory
        self.temporaryRoot = temporaryRoot
        self.limits = limits
    }

    public var description: String { "BackgroundTaskTail()" }
    public var debugDescription: String { description }

    // MARK: 공개

    /// - window: 명령 출력에서 끝에서부터 읽을 바이트 (0 이하는 기본, 상한 `maxTailBytes`). 에이전트 일에는 쓰지 않는다
    public func read(sessionID: String, cwd: String?, taskID: String, kind: BackgroundTaskKind, window: Int = Limits.standard.tailBytes) -> Result {
        guard ExternalSessionRules.isCanonicalUUID(sessionID), BackgroundTaskText.isValidTaskID(taskID) else { return .unreadable }
        switch kind {
        case .agent:
            switch agentFile(sessionID: sessionID, cwd: cwd, agentID: taskID) {
            case .failed(let result): return result
            case .file(let path, let entry): return agentWindow(path: path, entry: entry, sessionID: sessionID, agentID: taskID).result
            }
        case .command, .other:
            switch commandFile(sessionID: sessionID, cwd: cwd, taskID: taskID) {
            case .failed(let result): return result
            case .file(let path, let entry): return commandTail(path: path, size: max(0, entry.size), wanted: wanted(window))
            }
        }
    }

    /// 이어 읽기: 크기가 그대로면 읽지 않고(`unchanged`), 에이전트는 마지막으로 읽은 줄의 끝부터 새로 붙은 완성된 줄만 읽는다 (`append`).
    /// 처음 · 줄었다 · 창이 바뀌었다 · 창보다 많이 붙었다 · 길을 믿을 수 없게 됐다면 통째로 (`replace`: 믿을 수 없는 길은 커서 없이)
    public func update(sessionID: String, cwd: String?, taskID: String, kind: BackgroundTaskKind, window: Int = Limits.standard.tailBytes, since cursor: Cursor?) -> Update {
        guard ExternalSessionRules.isCanonicalUUID(sessionID), BackgroundTaskText.isValidTaskID(taskID) else { return .replace(.unreadable, nil) }
        switch kind {
        case .agent:
            switch agentFile(sessionID: sessionID, cwd: cwd, agentID: taskID) {
            case .failed(let result): return .replace(result, nil)
            case .file(let path, let entry): return updateAgent(path: path, entry: entry, sessionID: sessionID, agentID: taskID, since: cursor)
            }
        case .command, .other:
            switch commandFile(sessionID: sessionID, cwd: cwd, taskID: taskID) {
            case .failed(let result): return .replace(result, nil)
            case .file(let path, let entry):
                let size = max(0, entry.size)
                let bytes = wanted(window)
                if let cursor, cursor.size == size, cursor.position == Int64(bytes), cursor.created == entry.created { return .unchanged }
                let result = commandTail(path: path, size: size, wanted: bytes)
                guard case .output = result else { return .replace(result, nil) }
                return .replace(result, Cursor(size: size, position: Int64(bytes), created: entry.created))
            }
        }
    }

    /// 세션 폴더의 `subagents/`에서 하위 에이전트 메타(`agent-<id>.meta.json`)를 읽는다 (에이전트 트리 T1).
    /// 길은 (세션 id · 기록 폴더)로 만들고 폴더 사슬 검사는 에이전트 꼬리를 읽을 때와 **같은 함수**다 (`subagentsFolder` → `directory`). 이름은 `agent-<id>.meta.json`(id는 일 id 규칙)만, 이 uid의 일반 파일 4 KiB 이하만,
    /// 가장 새 것부터 256개까지 읽는다 (넘는 이름은 무시). 파일은 `ExternalSessionFileSystem.read`(`O_NOFOLLOW` · fd 소유자 · `F_GETPATH`)로 열고 선언한 칸만 해석한다 (`SubagentMeta.parse`): 깨진 파일은 그 파일만 버린다.
    /// - since: 앞서 훑은 자리. 거기 적힌 **프로젝트 폴더를 기억해** `~/.claude/projects`를 다시 나열하지 않고(없어졌으면 다시 찾는다) 그 아래 길을 모두 다시 확인하며, 길을 믿을 수 있고 `subagents/` 폴더의 바뀐 시각이 그대로면 이름도 훑지 않고 `.unchanged` (폴더 안의 새 파일은 폴더의 바뀐 시각을 바꾼다).
    ///   폴더 항목이 `SubagentMeta.maxScanned`개를 넘으면 앞의 그만큼만 보고 자리에 `overflowed`를 남긴다 (읽는 순서는 정해져 있지 않아 가장 새 에이전트가 빠졌을 수 있다)
    public func subagents(sessionID: String, cwd: String?, since cursor: SubagentCursor? = nil) -> SubagentListing {
        guard ExternalSessionRules.isCanonicalUUID(sessionID) else { return .unreadable }
        let folder: String
        let modified: Date
        let project: String
        switch subagentsFolder(sessionID: sessionID, cwd: cwd, remembered: cursor?.project) {
        case .failed(.missing): return .missing
        case .failed: return .unreadable
        case .folder(let path, let entry, let name):
            folder = path
            modified = entry.modified
            project = name
        }
        if let cursor, cursor.stamp == modified { return .unchanged }
        let entries: [ExternalSessionFileSystem.Entry]
        let overflowed: Bool
        switch fileSystem.list(folder, SubagentMeta.maxScanned + 1) {
        case .entries(let found):
            overflowed = found.count > SubagentMeta.maxScanned
            entries = Array(found.prefix(SubagentMeta.maxScanned))
        case .missing: return .missing
        case .failed: return .unreadable
        }
        let candidates = entries.compactMap { entry -> (id: String, entry: ExternalSessionFileSystem.Entry)? in
            guard entry.kind == .regular, entry.owner == fileSystem.userID, (1...Int64(SubagentMeta.maxBytes)).contains(entry.size), let id = SubagentMeta.id(fromFileName: entry.name) else { return nil }
            return (id, entry)
        }
        let newest = candidates.sorted { a, b in a.entry.modified != b.entry.modified ? a.entry.modified > b.entry.modified : a.id < b.id }.prefix(SubagentMeta.maxMetas)
        let metas = newest.compactMap { candidate -> SubagentMeta? in
            guard let data = fileSystem.read(folder + "/agent-" + candidate.id + ".meta.json", 0, Int(candidate.entry.size)) else { return nil }
            return SubagentMeta.parse(data, id: candidate.id)
        }
        return .metas(metas, cursor: SubagentCursor(project: project, stamp: modified, overflowed: overflowed))
    }

    /// 명령 출력의 창 크기 (0 이하는 기본, 상한 `maxTailBytes`)
    private func wanted(_ window: Int) -> Int { min(max(window <= 0 ? limits.tailBytes : window, 1), limits.maxTailBytes) }

    // MARK: 길 확인

    private enum Check {
        case ok
        case missing
        case bad
    }

    /// 진짜 폴더인가: `lstat`이 폴더(기호 링크면 아니다)이고 `realpath`가 같은 경로(길 어디에도 기호 링크가 없다).
    /// `owned`면 이 uid의 것이고 **그룹 · 모두가 쓸 수 없다** (쓸 수 있으면 확인과 읽기 사이에 이름을 바꿔치기할 수 있다). 임시 폴더 자신(`owned: false`)은 모두가 쓰는 폴더라 예외다
    private func directory(_ path: String, owned: Bool = true) -> Check {
        guard let entry = fileSystem.lstat(path) else { return .missing }
        guard entry.kind == .directory, !owned || (entry.owner == fileSystem.userID && !entry.othersCanWrite), fileSystem.realpath(path) == path else { return .bad }
        return .ok
    }

    /// `base` 아래에서 그 세션 폴더(`<이름>/<세션 id>`)가 든 프로젝트 디렉터리 이름. 작업 폴더로 짐작한 이름이 기호 링크 따위로 믿을 수 없으면 `.unreadable`로 끝낸다 (이름 훑기로 돌아서지 않는다)
    private enum Located {
        case found(String)
        case missing
        case unreadable
    }

    /// 앞서 찾은 프로젝트 디렉터리가 아직 그 세션을 갖고 있나: 갖고 있으면 `.found`, 그 폴더가 믿을 수 없게 됐으면 `.unreadable`, 이름이 규칙 밖이거나 폴더 · 세션이 없어졌으면 nil (다시 찾는다)
    private func stillHolds(_ name: String, in base: String, sessionID: String) -> Located? {
        guard ExternalSessionReadAllowList.isProjectDirectory(name) else { return nil }
        switch directory(base + "/" + name) {
        case .ok: return fileSystem.lstat(base + "/" + name + "/" + sessionID) != nil ? .found(name) : nil
        case .bad: return .unreadable
        case .missing: return nil
        }
    }

    private func locate(in base: String, sessionID: String, cwd: String?) -> Located {
        let fs = fileSystem
        if let cwd, ExternalSessionRules.isPlainAbsolutePath(cwd), let name = ExternalSessionRules.projectDirectoryName(forCwd: cwd), ExternalSessionReadAllowList.isProjectDirectory(name) {
            switch directory(base + "/" + name) {
            case .ok: if fs.lstat(base + "/" + name + "/" + sessionID) != nil { return .found(name) }
            case .bad: return .unreadable
            case .missing: break
            }
        }
        guard case .entries(let entries) = fs.list(base, ExternalSessionRegistry.maxListed + 1), entries.count <= ExternalSessionRegistry.maxListed else { return .unreadable }
        let names = entries.filter { $0.kind == .directory && $0.owner == fs.userID && !$0.othersCanWrite && ExternalSessionReadAllowList.isProjectDirectory($0.name) }.map(\.name).sorted()
        var best: (name: String, modified: Date)?
        for name in names {
            guard let session = fs.lstat(base + "/" + name + "/" + sessionID) else { continue }
            if let known = best, known.modified >= session.modified { continue }
            best = (name, session.modified)
        }
        return best.map { .found($0.name) } ?? .missing
    }

    /// 파일 한 개: 이 uid의 일반 파일 (기호 링크 · FIFO · 폴더 · 남의 파일은 `.bad`)
    private func regularFile(_ path: String) -> (Check, ExternalSessionFileSystem.Entry?) {
        guard let entry = fileSystem.lstat(path) else { return (.missing, nil) }
        guard entry.kind == .regular, entry.owner == fileSystem.userID else { return (.bad, nil) }
        return (.ok, entry)
    }

    /// 길을 따라가 읽을 파일 하나를 찾은 결과 (믿을 수 없거나 없으면 그 `Result`)
    private enum Found {
        case file(path: String, entry: ExternalSessionFileSystem.Entry)
        case failed(Result)
    }

    // MARK: 명령 일

    private func commandFile(sessionID: String, cwd: String?, taskID: String) -> Found {
        let base = temporaryRoot + "/claude-\(fileSystem.userID)"
        switch directory(temporaryRoot, owned: false) {
        case .missing: return .failed(.missing)
        case .bad: return .failed(.unreadable)
        case .ok: break
        }
        switch directory(base) {
        case .missing: return .failed(.missing)
        case .bad: return .failed(.unreadable)
        case .ok: break
        }
        let project: String
        switch locate(in: base, sessionID: sessionID, cwd: cwd) {
        case .found(let name): project = name
        case .missing: return .failed(.missing)
        case .unreadable: return .failed(.unreadable)
        }
        let sessionFolder = base + "/" + project + "/" + sessionID
        for folder in [sessionFolder, sessionFolder + "/tasks"] {
            switch directory(folder) {
            case .missing: return .failed(.missing)
            case .bad: return .failed(.unreadable)
            case .ok: break
            }
        }
        let path = sessionFolder + "/tasks/" + taskID + ".output"
        let (check, entry) = regularFile(path)
        switch check {
        case .missing: return .failed(.missing)
        case .bad: return .failed(.unreadable)
        case .ok: break
        }
        guard let entry else { return .failed(.unreadable) }
        return .file(path: path, entry: entry)
    }

    /// 파일 끝 `wanted`바이트를 보이는 글로
    private func commandTail(path: String, size: Int64, wanted: Int) -> Result {
        guard size > 0 else { return .output(.text("", hasEarlier: false)) }
        let length = Int(min(Int64(wanted), size))
        let offset = size - Int64(length)
        guard let data = fileSystem.read(path, offset, length) else { return .unreadable }
        return .output(.text(Self.text(from: data, startsMidFile: offset > 0), hasEarlier: offset > 0))
    }

    // MARK: 에이전트 일

    /// 세션 폴더의 `subagents/` 폴더까지의 길을 확인한 결과 (에이전트 꼬리와 메타 훑기가 같이 쓴다)
    private enum FolderFound {
        case folder(path: String, entry: ExternalSessionFileSystem.Entry, project: String)
        case failed(Result)
    }

    /// - remembered: 앞서 찾은 프로젝트 디렉터리 이름. 아직 그 세션을 갖고 있으면 `projects`를 나열하지 않고 그 아래 길만 확인한다 (이름 규칙 밖이거나 세션이 없어졌으면 처음처럼 찾는다)
    private func subagentsFolder(sessionID: String, cwd: String?, remembered: String? = nil) -> FolderFound {
        let fs = fileSystem
        guard let rootEntry = fs.lstat(claudeDirectory), rootEntry.kind == .directory || rootEntry.kind == .symlink, let root = fs.realpath(claudeDirectory),
              let realRoot = fs.lstat(root), realRoot.kind == .directory, realRoot.owner == fs.userID, !realRoot.othersCanWrite else { return .failed(.missing) }
        let projects = root + "/projects"
        switch directory(projects) {
        case .missing: return .failed(.missing)
        case .bad: return .failed(.unreadable)
        case .ok: break
        }
        let project: String
        switch remembered.flatMap({ stillHolds($0, in: projects, sessionID: sessionID) }) ?? locate(in: projects, sessionID: sessionID, cwd: cwd) {
        case .found(let name): project = name
        case .missing: return .failed(.missing)
        case .unreadable: return .failed(.unreadable)
        }
        let sessionFolder = projects + "/" + project + "/" + sessionID
        for folder in [sessionFolder, sessionFolder + "/subagents"] {
            switch directory(folder) {
            case .missing: return .failed(.missing)
            case .bad: return .failed(.unreadable)
            case .ok: break
            }
        }
        guard let entry = fs.lstat(sessionFolder + "/subagents") else { return .failed(.missing) }
        return .folder(path: sessionFolder + "/subagents", entry: entry, project: project)
    }

    private func agentFile(sessionID: String, cwd: String?, agentID: String) -> Found {
        let folder: String
        switch subagentsFolder(sessionID: sessionID, cwd: cwd) {
        case .failed(let result): return .failed(result)
        case .folder(let path, _, _): folder = path
        }
        let path = folder + "/agent-" + agentID + ".jsonl"
        let (check, entry) = regularFile(path)
        switch check {
        case .missing: return .failed(.missing)
        case .bad: return .failed(.unreadable)
        case .ok: break
        }
        guard let entry else { return .failed(.unreadable) }
        return .file(path: path, entry: entry)
    }

    /// 끝 창(`windowBytes`)의 완성된 줄에서 읽은 에이전트의 말 · 단계 + 다음 이어 읽기 자리 (창 안의 마지막 완성된 줄의 끝)
    private func agentWindow(path: String, entry: ExternalSessionFileSystem.Entry, sessionID: String, agentID: String) -> (result: Result, cursor: Cursor?) {
        let size = max(0, entry.size)
        guard size > 0 else { return (.output(.agent([], hasEarlier: false)), Cursor(size: 0, position: 0, created: entry.created)) }
        let length = Int(min(Int64(limits.windowBytes), size))
        let offset = size - Int64(length)
        guard let data = fileSystem.read(path, offset, length) else { return (.unreadable, nil) }
        let (turns, dropped) = agentTurns(in: data, start: offset, startsAtLine: offset == 0, sessionID: sessionID, agentID: agentID)
        let consumed = data.lastIndex(of: 0x0A).map { $0 - data.startIndex + 1 } ?? 0
        return (.output(.agent(turns, hasEarlier: offset > 0 || dropped)), Cursor(size: size, position: offset + Int64(consumed), created: entry.created))
    }

    private func updateAgent(path: String, entry: ExternalSessionFileSystem.Entry, sessionID: String, agentID: String, since cursor: Cursor?) -> Update {
        let size = max(0, entry.size)
        // 다른 파일(같은 길에 지우고 다시 만듦)이면 옛 자리에서 이어 읽지 않고 통째로 읽는다
        if let cursor, cursor.created == entry.created {
            if size == cursor.size { return .unchanged }
            // 붙었다 (줄었거나 창보다 많이 붙은 것은 아래에서 통째로): 마지막으로 읽은 줄의 끝에서부터 새로 붙은 부분만
            if size > cursor.size, cursor.position <= size, size - cursor.position <= Int64(limits.windowBytes) {
                let length = Int(size - cursor.position)
                guard length > 0, let data = fileSystem.read(path, cursor.position, length) else { return .replace(.unreadable, nil) }
                // 개행이 오지 않은 줄은 아직 쓰는 중이다: 완성된 줄까지만 (아무 줄도 완성되지 않았으면 그대로)
                guard let last = data.lastIndex(of: 0x0A) else { return .unchanged }
                let consumed = last - data.startIndex + 1
                let (turns, _) = agentTurns(in: Data(data.prefix(consumed)), start: cursor.position, startsAtLine: true, sessionID: sessionID, agentID: agentID)
                return .append(turns, Cursor(size: size, position: cursor.position + Int64(consumed), created: entry.created))
            }
        }
        let window = agentWindow(path: path, entry: entry, sessionID: sessionID, agentID: agentID)
        return .replace(window.result, window.cursor)
    }

    // MARK: 글 정리

    /// 끝 부분의 바이트를 보이는 글로: 창 앞의 잘린 글자 · 잘린 줄을 버리고, 색 코드 · 제어 글자 · 서식 글자를 지운다
    static func text(from data: Data, startsMidFile: Bool) -> String {
        var bytes = Array(data)
        // 글자 가운데에서 시작했다면 이어지는 바이트(10xxxxxx)를 건너뛴다
        var head = 0
        while head < bytes.count, bytes[head] & 0xC0 == 0x80 { head += 1 }
        bytes.removeFirst(head)
        if startsMidFile, let newline = bytes.firstIndex(of: 0x0A), newline < bytes.count - 1 { bytes.removeFirst(newline + 1) }
        // 파일 끝에서 글자가 아직 다 쓰이지 않았을 수 있다: 끝의 덜 쓴 글자는 버린다
        trimIncompleteTail(&bytes)
        let scalars = Array(String(decoding: bytes, as: UTF8.self).unicodeScalars)
        var out = String.UnicodeScalarView()
        var index = 0
        while index < scalars.count {
            let scalar = scalars[index]
            if scalar == "\u{1B}" {
                index = skipEscape(scalars, from: index)
                continue
            }
            if scalar == "\r" {
                out.append("\n")
                index += (index + 1 < scalars.count && scalars[index + 1] == "\n") ? 2 : 1
                continue
            }
            if !isStripped(scalar) { out.append(scalar) }
            index += 1
        }
        return String(out).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func trimIncompleteTail(_ bytes: inout [UInt8]) {
        var back = 0
        var index = bytes.count - 1
        while index >= 0, back < 4 {
            let byte = bytes[index]
            if byte & 0xC0 == 0x80 {
                back += 1
                index -= 1
                continue
            }
            let needed = byte >= 0xF0 ? 4 : byte >= 0xE0 ? 3 : byte >= 0xC0 ? 2 : 1
            if needed > back + 1 { bytes.removeSubrange(index...) }
            return
        }
    }

    /// ESC로 시작하는 색 · 커서 · 제목 코드 하나를 건너뛴 다음 위치 (CSI: 마침 글자까지, OSC: BEL이나 ESC \까지, 그 밖은 ESC와 다음 글자)
    private static func skipEscape(_ scalars: [Unicode.Scalar], from start: Int) -> Int {
        var index = start + 1
        guard index < scalars.count else { return index }
        if scalars[index] == "[" {
            index += 1
            var steps = 0
            while index < scalars.count, steps < 64 {
                let value = scalars[index].value
                index += 1
                steps += 1
                if value >= 0x40 && value <= 0x7E { break }
            }
            return index
        }
        if scalars[index] == "]" {
            index += 1
            var steps = 0
            while index < scalars.count, steps < 4096 {
                if scalars[index] == "\u{07}" { return index + 1 }
                if scalars[index] == "\u{1B}", index + 1 < scalars.count, scalars[index + 1] == "\\" { return index + 2 }
                index += 1
                steps += 1
            }
            return index
        }
        return index + 1
    }

    /// 제어 글자(줄바꿈 · 탭 제외)와 눈에 보이지 않는 서식 글자(방향 바꿈 · 폭 없는 공백 · 연한 하이픈 · BOM · 태그 글자)와 줄 · 문단 구분. ZWJ · ZWNJ는 둔다
    private static func isStripped(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x0A, 0x09, 0x200C, 0x200D: return false
        case 0x2028, 0x2029: return true
        default:
            let category = scalar.properties.generalCategory
            return category == .control || category == .format
        }
    }

    // MARK: 에이전트 기록의 줄

    private static let assistantNeedle = Data("\"assistant\"".utf8)

    /// 읽는 칸만 선언한다 (사용자 줄 · 도구 결과 · 첨부 · 생각은 읽지 않는다)
    private struct Line: Decodable {
        var type: String?
        var agentId: String?
        var sessionId: String?
        var timestamp: String?
        var blocks: [Block] = []

        enum CodingKeys: String, CodingKey { case type, agentId, sessionId, timestamp, message }
        enum MessageKeys: String, CodingKey { case content }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            type = try? container.decodeIfPresent(String.self, forKey: .type)
            agentId = try? container.decodeIfPresent(String.self, forKey: .agentId)
            sessionId = try? container.decodeIfPresent(String.self, forKey: .sessionId)
            timestamp = try? container.decodeIfPresent(String.self, forKey: .timestamp)
            if let message = try? container.nestedContainer(keyedBy: MessageKeys.self, forKey: .message), let list = try? message.decodeIfPresent([Lossy].self, forKey: .content) {
                blocks = list.compactMap(\.block)
            }
        }
    }

    private struct Lossy: Decodable {
        var block: Block?
        init(from decoder: Decoder) throws { block = try? Block(from: decoder) }
    }

    private struct Block: Decodable {
        var type: String?
        var text: String?
        var name: String?
        var description: String?
        var fileName: String?

        enum CodingKeys: String, CodingKey { case type, text, name, input }
        enum InputKeys: String, CodingKey { case description, filePath = "file_path", notebookPath = "notebook_path" }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            type = try? container.decodeIfPresent(String.self, forKey: .type)
            text = try? container.decodeIfPresent(String.self, forKey: .text)
            name = try? container.decodeIfPresent(String.self, forKey: .name)
            // 도구 입력은 `description`과 파일 **이름**만 꺼낸다 (명령 · 경로 · 내용은 담지 않는다)
            if let input = try? container.nestedContainer(keyedBy: InputKeys.self, forKey: .input) {
                description = try? input.decodeIfPresent(String.self, forKey: .description)
                let path = (try? input.decodeIfPresent(String.self, forKey: .filePath)) ?? (try? input.decodeIfPresent(String.self, forKey: .notebookPath))
                fileName = path.flatMap(SessionStepText.fileName(fromPath:))
            }
        }
    }

    /// 끝 창의 완성된 줄에서 이 에이전트의 말 · 도구 단계 (마지막 `maxTurns`개). 두 번째 값: 앞을 버렸다
    private func agentTurns(in data: Data, start: Int64, startsAtLine: Bool, sessionID: String, agentID: String) -> ([ClaudeAppTurn], Bool) {
        var spans: [Range<Int>] = []
        var lineStart = 0
        data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            guard let base = buffer.baseAddress else { return }
            var position = 0
            while position < buffer.count, let found = memchr(base + position, 0x0A, buffer.count - position) {
                let index = base.distance(to: UnsafeRawPointer(found))
                spans.append(lineStart..<index)
                lineStart = index + 1
                position = index + 1
            }
        }
        // 창이 줄 가운데에서 시작하면 그 조각은 줄이 아니다 (이어 읽기는 줄 경계에서 시작한다). 개행 없이 끝난 줄은 아직 쓰는 중이다 (읽지 않는다)
        if !startsAtLine, !spans.isEmpty { spans.removeFirst() }
        let decoder = JSONDecoder()
        var turns: [ClaudeAppTurn] = []
        for span in spans where !span.isEmpty && span.count <= limits.maxLineBytes {
            let line = data.subdata(in: span)
            guard line.range(of: Self.assistantNeedle) != nil, String(validating: line, as: UTF8.self) != nil, let record = try? decoder.decode(Line.self, from: line),
                  record.type == "assistant", record.agentId.map({ $0 == agentID }) ?? true, record.sessionId.map({ $0 == sessionID }) ?? true else { continue }
            let time = record.timestamp.flatMap(Self.date)
            let offset = start + Int64(span.lowerBound)
            var count = 0
            func add(_ kind: ClaudeAppTurn.Kind, truncated: Bool = false, target: String? = nil) {
                turns.append(ClaudeAppTurn(id: "\(offset)-\(count)", kind: kind, timestamp: time, truncated: truncated, lineOffset: -1, toolUseID: nil, target: target))
                count += 1
            }
            for block in record.blocks {
                switch block.type {
                case "text":
                    if let text = block.text, let (kept, cut) = plain(text) { add(.assistant(kept), truncated: cut) }
                case "tool_use":
                    guard let name = block.name.flatMap(ExternalSessionRules.sanitizedTitle) else { continue }
                    add(.tool(name: name, description: block.description.flatMap(ExternalSessionRules.sanitizedTitle)), target: block.fileName)
                default: continue
                }
            }
        }
        let dropped = turns.count > limits.maxTurns
        return (dropped ? Array(turns.suffix(limits.maxTurns)) : turns, dropped)
    }

    private func plain(_ raw: String) -> (String, Bool)? {
        var scalars = String.UnicodeScalarView()
        var bytes = 0
        var truncated = false
        for scalar in raw.unicodeScalars {
            if Self.isStripped(scalar) { continue }
            let size = scalar.utf8.count
            if bytes + size > limits.maxTextBytes {
                truncated = true
                break
            }
            scalars.append(scalar)
            bytes += size
        }
        let text = String(scalars).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : (text, truncated)
    }

    private static func date(_ text: String) -> Date? {
        guard text.utf8.count <= 40 else { return nil }
        if let date = try? Date(text, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)) { return date }
        return try? Date(text, strategy: Date.ISO8601FormatStyle())
    }
}
#endif
