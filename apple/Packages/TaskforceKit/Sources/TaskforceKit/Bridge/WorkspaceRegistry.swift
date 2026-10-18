#if os(macOS)
import Darwin
import Foundation
import Synchronization

/// 이 Mac · 이 계정이 에이전트에게 열어 준 작업 폴더의 등록부 (OA D4a2-01 · 03, 사용자 결정 11.1 "작업 폴더 = 프로젝트마다").
///
/// - 자리: 이 계정 파티션 폴더의 `workspaces.json` (0600, 원자적 쓰기). 계정 삭제(`BridgeStorage.deletePartition`)가 파티션째 같이 지운다. 서버에는 아무것도 보내지 않는다
/// - 표 셋: `projects[프로젝트(context) id]` (프로젝트마다 한 번 고른 폴더) · `sessions[agent session id]` (그 세션이 쓰는 폴더, 처음 쓸 때 핀을 꽂는다) ·
///   `pending[대화 id]` (Ungrouped 대화에서 보내기 전에 한 번 고른 폴더). 값은 폴더의 realpath이고, 폴더마다 **불투명 id**(`ws_<uuid>`)가 하나 붙는다
/// - **서버에는 경로 대신 불투명 id만 간다** (`session_bound.workspace_ref`, D4a2-03): 경로에는 사용자 이름 · 고객 이름이 든다. 런타임이 `ref(forPath:)` · `path(forRef:)`로 바꾼다.
///   모르는 경로는 id를 만들지 않는다(등록하지 않은 폴더는 서버에 이름이 가지 않는다)
/// - 등록은 `WorkspaceFolderRules`를 통과한 폴더만 한다 (한 곳에서 거른다). 쓰기 직전에 resolver가 같은 규칙으로 다시 본다
/// - 깨진 파일은 빈 표로 읽고, 다음에 쓰기 전에 옆(`workspaces.json.corrupt`)으로 옮긴다 (지우지 않는다). 경로 원문은 로그에 남기지 않는다: 이 타입은 로그를 쓰지 않는다
/// - 파티션 폴더가 없으면 쓰지 않는다(`writeFailed`): 폴더는 원장이 연다. 계정 삭제가 폴더를 지운 뒤의 늦은 쓰기가 폴더를 다시 만들지 못한다
public final class WorkspaceRegistry: @unchecked Sendable {
    public enum RegistryError: Error, Equatable, Sendable {
        /// 규칙을 통과하지 못한 폴더다
        case rejected(WorkspaceFolderRules.Rejection)
        /// 파일을 쓰지 못했다 (표는 바뀌지 않았다)
        case writeFailed
    }

    struct Tables: Equatable {
        /// 불투명 id → realpath
        var refs: [String: String] = [:]
        var projects: [String: String] = [:]
        var sessions: [String: String] = [:]
        var pending: [String: String] = [:]
    }

    private struct State {
        var tables = Tables()
        var loaded = false
        /// 읽지 못한 파일이 있다: 다음 쓰기 전에 옆으로 옮긴다
        var corruptOnDisk = false
    }

    public static let fileName = "workspaces.json"
    static let refPrefix = "ws_"
    static let version = 1

    /// 서버로 가는 폴더 식별 모양: `ws_` + 소문자 UUID (39자). 경로는 이 모양이 될 수 없다
    public static func isOpaqueRef(_ value: String) -> Bool {
        guard value.hasPrefix(refPrefix) else { return false }
        let rest = value.dropFirst(refPrefix.count)
        guard let id = UUID(uuidString: String(rest)) else { return false }
        return id.uuidString.lowercased() == rest
    }

    public let file: URL
    public let rules: WorkspaceFolderRules
    private let state = Mutex(State())

    public init(file: URL, rules: WorkspaceFolderRules) {
        self.file = file
        self.rules = rules
    }

    // MARK: 프로젝트

    /// 그 프로젝트(context)에 연결된 폴더. 없으면 nil
    public func folder(forProject contextID: UUID) -> String? {
        read { tables in tables.projects[Self.key(contextID)].flatMap { tables.refs[$0] } }
    }

    /// 프로젝트의 폴더를 정한다 (이미 있으면 바꾼다). 규칙을 통과한 폴더만 받고, 돌려주는 값은 등록한 realpath다
    @discardableResult
    public func setFolder(_ path: String, forProject contextID: UUID) throws -> String {
        let real = try accept(path)
        try write(adding: real) { tables in
            let ref = Self.ensureRef(for: real, in: &tables)
            tables.projects[Self.key(contextID)] = ref
        }
        return real
    }

    public func removeFolder(forProject contextID: UUID) {
        _ = try? write { $0.projects[Self.key(contextID)] = nil }
    }

    /// 프로젝트마다 연결된 폴더 (Settings가 보인다)
    public func projectFolders() -> [UUID: String] {
        read { tables in
            var result: [UUID: String] = [:]
            for (key, ref) in tables.projects {
                if let id = UUID(uuidString: key), let path = tables.refs[ref] { result[id] = path }
            }
            return result
        }
    }

    // MARK: 세션

    /// 이 세션이 쓰는 폴더 (핀). 없으면 nil
    public func pinned(session sessionID: String) -> String? {
        read { tables in tables.sessions[Self.key(sessionID)].flatMap { tables.refs[$0] } }
    }

    /// 세션에 폴더를 꽂는다 (이미 있으면 바꾸지 않는다: 세션을 연 뒤에는 폴더가 따라 움직이지 않는다). 규칙을 통과한 폴더만 받는다
    public func pin(session sessionID: String, to path: String) throws {
        let real = try accept(path)
        try write(adding: real) { tables in
            let key = Self.key(sessionID)
            guard tables.sessions[key] == nil else { return }
            tables.sessions[key] = Self.ensureRef(for: real, in: &tables)
        }
    }

    // MARK: 대화 (Ungrouped)

    /// Ungrouped 대화가 보내기 전에 고른 폴더. 없으면 nil
    public func pending(conversation conversationID: UUID) -> String? {
        read { tables in tables.pending[Self.key(conversationID)].flatMap { tables.refs[$0] } }
    }

    @discardableResult
    public func setPending(_ path: String, conversation conversationID: UUID) throws -> String {
        let real = try accept(path)
        try write(adding: real) { tables in
            let ref = Self.ensureRef(for: real, in: &tables)
            tables.pending[Self.key(conversationID)] = ref
        }
        return real
    }

    public func removePending(conversation conversationID: UUID) {
        _ = try? write { $0.pending[Self.key(conversationID)] = nil }
    }

    // MARK: 경로 ↔ 불투명 id (D4a2-03)

    /// 등록된 폴더의 불투명 id. 등록하지 않은 경로는 nil이다 (id를 새로 만들지 않는다)
    public func ref(forPath path: String) -> String? {
        let real = rules.facts.realpath(path) ?? path
        return read { tables in tables.refs.first(where: { $0.value == real })?.key }
    }

    /// 불투명 id가 가리키는 폴더. 모르는 id는 nil이다
    public func path(forRef ref: String) -> String? {
        read { $0.refs[ref] }
    }

    // MARK: 규칙

    private func accept(_ path: String) throws -> String {
        switch rules.validate(path) {
        case .success(let real): return real
        case .failure(let why): throw RegistryError.rejected(why)
        }
    }

    // MARK: 표 읽기 · 쓰기

    private static func key(_ id: UUID) -> String { id.uuidString.lowercased() }
    private static func key(_ id: String) -> String { id.lowercased() }

    private static func ensureRef(for path: String, in tables: inout Tables) -> String {
        if let existing = tables.refs.first(where: { $0.value == path })?.key { return existing }
        let ref = refPrefix + UUID().uuidString.lowercased()
        tables.refs[ref] = path
        return ref
    }

    /// 어느 표도 가리키지 않는 id를 지운다 (서버에 간 id가 가리키는 세션 핀이 있는 동안은 남는다)
    private static func collect(_ tables: inout Tables) {
        let used = Set(tables.projects.values).union(tables.sessions.values).union(tables.pending.values)
        tables.refs = tables.refs.filter { used.contains($0.key) }
    }

    private func read<T>(_ body: (Tables) -> T) -> T {
        state.withLock { state in
            loadIfNeeded(&state)
            return body(state.tables)
        }
    }

    /// 한 폴더(realpath)가 다른 폴더의 조상이거나 자손인가. 같은 실제 경로는 겹침이 아니다 (두 프로젝트가 한 폴더를 쓰면 같은 `ws_id`다).
    /// 겹치는 폴더를 따로 등록하면 같은 파일이 폴더마다 다른 가상 경로가 되어 서버의 경로 잠금이 갈라진다 (재검토 1, Astra 1)
    private static func overlaps(_ real: String, among others: some Sequence<String>) -> Bool {
        others.contains { $0 != real && (GateFileSystem.isInside(real, root: $0) || GateFileSystem.isInside($0, root: real)) }
    }

    /// 표를 바꾸고 디스크에 쓴다. 쓰지 못하면 표를 되돌리고 던진다.
    /// - adding: 이 쓰기가 새로 등록하는 폴더(realpath). 바꾼 뒤 쓰이는 다른 폴더와 겹치면 던진다 (자기 옛 폴더는 바꾼 뒤 쓰이지 않으니 겹침이 아니다)
    private func write(adding real: String? = nil, _ change: (inout Tables) -> Void) throws {
        try state.withLock { state in
            loadIfNeeded(&state)
            var next = state.tables
            change(&next)
            Self.collect(&next)
            if next == state.tables { return }
            if let real, Self.overlaps(real, among: next.refs.values) { throw RegistryError.rejected(.overlapsRegisteredFolder) }
            guard persist(next, moveCorruptAside: state.corruptOnDisk) else { throw RegistryError.writeFailed }
            state.tables = next
            state.corruptOnDisk = false
        }
    }

    private func loadIfNeeded(_ state: inout State) {
        guard !state.loaded else { return }
        state.loaded = true
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        guard let data = try? Data(contentsOf: file), let tables = Self.decode(data) else {
            state.corruptOnDisk = true
            return
        }
        state.tables = tables
    }

    static func decode(_ data: Data) -> Tables? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], object["v"] as? Int == version else { return nil }
        func strings(_ key: String) -> [String: String]? {
            guard let value = object[key] else { return [:] }
            return value as? [String: String]
        }
        guard let refs = strings("refs"), let projects = strings("projects"), let sessions = strings("sessions"), let pending = strings("pending") else { return nil }
        // 모양이 맞는 id만: 서버에 가는 값이 id 모양이 아니면 읽지 않는다
        guard refs.keys.allSatisfy(isOpaqueRef) else { return nil }
        // 표가 모르는 id를 가리키면 그 줄은 버린다 (가리킬 폴더가 없다)
        func known(_ table: [String: String]) -> [String: String] { table.filter { refs[$0.value] != nil } }
        return Tables(refs: refs, projects: known(projects), sessions: known(sessions), pending: known(pending))
    }

    /// 0600으로 만든 임시 파일에 쓰고 이름을 바꾼다 (다른 사용자가 읽을 수 있는 순간이 없다)
    private static func atomicWrite(_ data: Data, to file: URL) throws {
        let temporary = file.deletingLastPathComponent().appending(path: ".\(fileName).tmp-\(UUID().uuidString.lowercased())")
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw RegistryError.writeFailed }
        var succeeded = false
        defer {
            close(descriptor)
            if !succeeded { unlink(temporary.path) }
        }
        let written = data.withUnsafeBytes { buffer -> Bool in
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.write(descriptor, buffer.baseAddress! + offset, buffer.count - offset)
                if count < 0 { if errno == EINTR { continue }; return false }
                offset += count
            }
            return true
        }
        guard written, fsync(descriptor) == 0, rename(temporary.path, file.path) == 0 else { throw RegistryError.writeFailed }
        succeeded = true
    }

    private func persist(_ tables: Tables, moveCorruptAside: Bool) -> Bool {
        let fileManager = FileManager.default
        let directory = file.deletingLastPathComponent()
        do {
            // 파티션 폴더가 없으면 쓰지 않는다 (보안 F4): 계정 삭제가 폴더를 지운 뒤에 늦게 온 쓰기가 폴더와 옛 표를 되살리지 않게. 파티션 폴더는 원장이 연다
            var info = stat()
            guard lstat(directory.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else { return false }
            if moveCorruptAside, fileManager.fileExists(atPath: file.path) {
                let aside = directory.appending(path: Self.fileName + ".corrupt")
                try? fileManager.removeItem(at: aside)
                try fileManager.moveItem(at: file, to: aside)
                try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: aside.path)
            }
            let object: [String: Any] = ["v": Self.version, "refs": tables.refs, "projects": tables.projects, "sessions": tables.sessions, "pending": tables.pending]
            let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            try Self.atomicWrite(data, to: file)
            return true
        } catch {
            return false
        }
    }
}

/// 보내기 전에 묻는 쪽(`AgentWorkspaceSendGate`)이 보는 면: "폴더가 있다"는 지금도 규칙을 통과하는 폴더가 있다는 뜻이다 (지워졌거나 기호 링크로 바뀐 폴더는 없는 것으로 보고 다시 묻는다)
extension WorkspaceRegistry: AgentWorkspaceFolders {
    public func hasFolder(forProject id: UUID) -> Bool {
        folder(forProject: id).map(accepts(path:)) ?? false
    }

    public func hasFolder(forConversation id: UUID) -> Bool {
        pending(conversation: id).map(accepts(path:)) ?? false
    }

    public func accepts(path: String) -> Bool {
        guard case .success(let real) = rules.validate(path) else { return false }
        return !read { Self.overlaps(real, among: $0.refs.values) }
    }

    /// 받아 주지 않는 폴더를 고른 사용자에게 창 안에서 보일 문장 (승인된 문구): 겹치는 폴더 · 민감 폴더는 자기 문장이고 나머지는 일반 거절 문장이다
    public func rejectionMessage(forPath path: String) -> String {
        switch rules.validate(path) {
        case .failure(.sensitiveFolder): AgentWorkspaceCopy.sensitiveFolder
        case .failure: AgentWorkspaceCopy.rejected
        case .success(let real): read { Self.overlaps(real, among: $0.refs.values) } ? AgentWorkspaceCopy.overlappingFolder : AgentWorkspaceCopy.rejected
        }
    }

    public func register(path: String, scope: AgentWorkspaceGate.Scope) throws {
        switch scope {
        case .project(let id): try setFolder(path, forProject: id)
        case .conversation(let id): try setPending(path, conversation: id)
        }
    }
}
#endif
