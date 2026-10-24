#if os(macOS)
import Foundation

public struct CodexLocalSession: Identifiable, Equatable, Sendable, CustomStringConvertible {
    public let id: String
    public let title: String
    public let updatedAt: Date
    public var description: String { "CodexLocalSession" }
    public var openURL: URL? {
        guard ExternalSessionRules.isCanonicalUUID(id) else { return nil }
        return URL(string: "codex://threads/\(id)")
    }
}

public struct CodexSessionSnapshot: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let turns: [ClaudeAppTurn]
    public let tasks: BackgroundTaskList
    public let hasEarlier: Bool
    public var description: String { "CodexSessionSnapshot" }
    public var debugDescription: String { description }
}

/// Local, read-only Codex state. Never executes commands or reports transcript content.
public actor CodexLocalSessionReader {
    public enum Result: Equatable, Sendable { case sessions([CodexLocalSession]), unreadable }
    public enum SnapshotResult: Equatable, Sendable { case snapshot(CodexSessionSnapshot), unreadable }
    private let directory: String
    private let files: ExternalSessionFileSystem
    static let byteLimit = 2 * 1024 * 1024
    public init(directory: String = ProcessInfo.processInfo.environment["CODEX_HOME"] ?? (NSHomeDirectory() + "/.codex"), files: ExternalSessionFileSystem = .live) {
        self.directory = directory
        self.files = files
    }

    private struct Thread {
        let id: String
        let title: String
        let path: String
        let updated: Int64
        let source: String
        var spawn: [String: Any]? {
            guard let data = source.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let subagent = object["subagent"] as? [String: Any] else { return nil }
            return subagent["thread_spawn"] as? [String: Any]
        }
        var agentName: String? {
            if let path = spawn?["agent_path"] as? String, let name = path.split(separator: "/").last {
                return ExternalSessionRules.sanitizedTitle(String(name))
            }
            return (spawn?["agent_role"] as? String ?? spawn?["agent_nickname"] as? String).flatMap(ExternalSessionRules.sanitizedTitle)
        }
        var spawnParent: String? {
            guard let data = source.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let subagent = object["subagent"] as? [String: Any],
                  let spawn = subagent["thread_spawn"] as? [String: Any] else { return nil }
            return spawn["parent_thread_id"] as? String
        }
        var session: CodexLocalSession? {
            guard ExternalSessionRules.isCanonicalUUID(id), let title = ExternalSessionRules.sanitizedTitle(title) else { return nil }
            return CodexLocalSession(id: id, title: title, updatedAt: Date(timeIntervalSince1970: Double(updated)))
        }
    }
    private enum Failure: Error { case unreadable }
    nonisolated private func root() throws -> String {
        guard let root = files.realpath(directory), let entry = files.lstat(root), entry.kind == .directory,
              entry.owner == files.userID, !entry.othersCanWrite else { throw Failure.unreadable }
        return root
    }
    nonisolated private func trusted(_ path: String, root: String, kind: ExternalSessionFileSystem.Entry.Kind) -> Bool {
        guard path.hasPrefix(root + "/"), files.realpath(path) == path else { return false }
        let components = String(path.dropFirst(root.count + 1)).split(separator: "/", omittingEmptySubsequences: false)
        guard !components.contains(".."), !components.contains("."), !components.contains("") else { return false }
        var current = root
        for (index, component) in components.enumerated() {
            current += "/" + component
            guard let entry = files.lstat(current), entry.owner == files.userID, !entry.othersCanWrite,
                  entry.kind == (index == components.count - 1 ? kind : .directory) else { return false }
        }
        return true
    }
    nonisolated private func database(root: String) throws -> SQLiteDatabase {
        let path = root + "/state_5.sqlite"
        guard trusted(path, root: root, kind: .regular) else { throw Failure.unreadable }
        for suffix in ["-wal", "-shm"] where files.lstat(path + suffix) != nil {
            guard trusted(path + suffix, root: root, kind: .regular) else { throw Failure.unreadable }
        }
        return try SQLiteDatabase(path: path, readOnly: true)
    }
    nonisolated private static let columns = "t.id, t.title, t.rollout_path, t.updated_at, t.source"
    nonisolated private func threads(_ db: SQLiteDatabase, sql: String, binds: [SQLValue] = []) throws -> [Thread] {
        try db.rows(sql, binds) { Thread(id: $0.requiredText(0), title: $0.requiredText(1), path: $0.requiredText(2), updated: $0.int(3), source: $0.requiredText(4)) }
    }
    nonisolated private func rootThread(_ db: SQLiteDatabase, id: String) throws -> Thread {
        guard ExternalSessionRules.isCanonicalUUID(id), let thread = try threads(db, sql: "SELECT \(Self.columns) FROM threads t WHERE t.id = ? AND t.archived = 0 AND t.source IN ('cli','vscode','exec') AND NOT EXISTS (SELECT 1 FROM thread_spawn_edges e WHERE e.child_thread_id = t.id)", binds: [.text(id)]).first else { throw Failure.unreadable }
        return thread
    }
    public func read() -> Result {
        if files.lstat(directory) == nil { return .sessions([]) }
        do {
            let root = try root()
            if files.lstat(root + "/state_5.sqlite") == nil { return .sessions([]) }
            let db = try database(root: root)
            let records = try threads(db, sql: "SELECT \(Self.columns) FROM threads t WHERE t.archived = 0 AND t.source IN ('cli','vscode','exec') AND NOT EXISTS (SELECT 1 FROM thread_spawn_edges e WHERE e.child_thread_id = t.id) ORDER BY t.updated_at DESC, t.id LIMIT 200")
            let titles = indexTitles(root: root)
            return .sessions(records.compactMap(\.session).map { session in
                CodexLocalSession(id: session.id, title: titles[session.id] ?? session.title, updatedAt: session.updatedAt)
            })
        } catch { return .unreadable }
    }
    nonisolated private func indexTitles(root: String) -> [String: String] {
        let path = root + "/session_index.jsonl"
        guard trusted(path, root: root, kind: .regular), let entry = files.lstat(path), entry.size >= 0 else { return [:] }
        let offset = max(0, entry.size - Int64(Self.byteLimit))
        guard let data = files.read(path, offset, min(Self.byteLimit, Int(entry.size))) else { return [:] }
        var lines = data.split(separator: 10, omittingEmptySubsequences: false)
        if offset > 0, !lines.isEmpty { lines.removeFirst() }
        if data.last != 10, !lines.isEmpty { lines.removeLast() }
        var titles: [String: String] = [:]
        for line in lines where line.count <= 16_384 {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let id = object["id"] as? String, ExternalSessionRules.isCanonicalUUID(id),
                  let raw = object["thread_name"] as? String, let title = ExternalSessionRules.sanitizedTitle(raw) else { continue }
            titles[id] = title
        }
        return titles
    }
    nonisolated private func graph(_ db: SQLiteDatabase, rootID: String) throws -> [(Thread, String?, Int)] {
        var queue = [(rootID, 0)], visited: Set<String> = [rootID]
        var result: [(Thread, String?, Int)] = []
        while !queue.isEmpty, result.count < 256 {
            let (parent, depth) = queue.removeFirst()
            guard depth < 16 else { continue }
            let children = try threads(db, sql: "SELECT \(Self.columns) FROM threads t JOIN thread_spawn_edges e ON e.child_thread_id = t.id WHERE e.parent_thread_id = ? ORDER BY t.updated_at DESC, t.id LIMIT 256", binds: [.text(parent)])
            for child in children where result.count < 256 {
                guard ExternalSessionRules.isCanonicalUUID(child.id), child.spawnParent == parent, visited.insert(child.id).inserted else { continue }
                result.append((child, parent == rootID ? nil : parent, depth + 1))
                queue.append((child.id, depth + 1))
            }
        }
        return result
    }
    public func snapshot(sessionID: String) -> SnapshotResult {
        do {
            let root = try root(), db = try database(root: root)
            let thread = try rootThread(db, id: sessionID)
            let transcript = try transcript(thread, root: root)
            let titles = indexTitles(root: root)
            let tasks = try graph(db, rootID: sessionID).map { child, parent, depth in
                BackgroundTask(id: child.id, kind: .agent, name: titles[child.id] ?? child.agentName ?? ExternalSessionRules.sanitizedTitle(child.title), status: .stopped, parentID: parent, depth: depth, statusUnknown: true)
            }
            return .snapshot(CodexSessionSnapshot(turns: transcript.turns, tasks: BackgroundTaskList(metadataTasks: tasks), hasEarlier: transcript.hasEarlier))
        } catch { return .unreadable }
    }
    nonisolated public func tail(sessionID: String, rootSessionID: String) -> BackgroundTaskTail.Result {
        do {
            let root = try root(), db = try database(root: root)
            _ = try rootThread(db, id: rootSessionID)
            guard let child = try graph(db, rootID: rootSessionID).first(where: { $0.0.id == sessionID })?.0 else { return .unreadable }
            let value = try transcript(child, root: root)
            return .output(.agent(value.turns, hasEarlier: value.hasEarlier))
        } catch { return .unreadable }
    }
    nonisolated private func transcript(_ thread: Thread, root: String) throws -> CodexTranscriptParser.Parsed {
        let path = thread.path
        guard path.hasPrefix(root + "/sessions/") || path.hasPrefix(root + "/archived_sessions/"),
              trusted(path, root: root, kind: .regular), let entry = files.lstat(path), entry.size >= 0,
              let head = files.read(path, 0, min(1 << 20, Int(entry.size))),
              CodexTranscriptParser.matchesSession(head, id: thread.id) else { throw Failure.unreadable }
        let offset = max(0, entry.size - Int64(Self.byteLimit))
        guard let data = files.read(path, offset, min(Self.byteLimit, Int(entry.size))),
              let after = files.lstat(path), after.kind == .regular, after.owner == entry.owner,
              after.created == entry.created, after.size >= entry.size else { throw Failure.unreadable }
        return CodexTranscriptParser.parse(data, offset: offset)
    }
}
#endif
