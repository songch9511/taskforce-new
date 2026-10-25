#if os(macOS)
import Foundation
import Testing
@testable import TaskforceKit

struct CodexLocalSessionsTests {
    private let first = "10000000-0000-0000-0000-000000000001"
    private let second = "10000000-0000-0000-0000-000000000002"
    private let third = "10000000-0000-0000-0000-000000000003"
    private func line(_ object: [String: Any]) throws -> Data {
        var data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]); data.append(10); return data
    }
    private func fixture() throws -> (URL, SQLiteDatabase) {
        var root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("sessions"), withIntermediateDirectories: true)
        root = URL(fileURLWithPath: try #require(ExternalSessionFileSystem.live.realpath(root.path)))
        let db = try SQLiteDatabase(path: root.appendingPathComponent("state_5.sqlite").path)
        try db.exec("CREATE TABLE threads(id TEXT PRIMARY KEY,title TEXT,rollout_path TEXT,updated_at INTEGER,source TEXT,archived INTEGER,cwd TEXT); CREATE TABLE thread_spawn_edges(parent_thread_id TEXT,child_thread_id TEXT,status TEXT)")
        return (root, db)
    }
    private func insert(_ id: String, root: URL, db: SQLiteDatabase, parent: String? = nil, source: String? = nil, archived: Int64 = 0, metaID: String? = nil) throws {
        let path = root.appendingPathComponent("sessions/\(id).jsonl")
        var data = try line(["type":"session_meta", "payload":["id": metaID ?? id]])
        data.append(try line(["type":"response_item", "payload":["type":"message", "role":"assistant", "content":[["type":"output_text", "text":"Reply for \(id)"]]]]))
        try data.write(to: path)
        let origin = try source ?? parent.map { String(decoding: try JSONSerialization.data(withJSONObject: ["subagent":["thread_spawn":["parent_thread_id":$0]]]), as: UTF8.self) } ?? "cli"
        try db.run("INSERT INTO threads VALUES(?,?,?,?,?,?,?)", [.text(id),.text("Original"),.text(path.path),.int(100),.text(origin),.int(archived),.text(root.path)])
        if let parent { try db.run("INSERT INTO thread_spawn_edges VALUES(?,?,?)", [.text(parent),.text(id),.text("running")]) }
    }
    @Test func managedContinuationKeepsSourceTaskContextAndValidatedWorkingDirectory() async throws {
        let (root, db) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        try insert(first, root: root, db: db)
        try insert(second, root: root, db: db, source: "app_server")
        try insert(third, root: root, db: db, parent: first)
        let reader = CodexLocalSessionReader(directory: root.path)
        #expect(await reader.workingDirectory(sessionID: first) == root.path)
        #expect(await reader.workingDirectory(sessionID: third) == nil)
        guard case .snapshot(let snapshot) = await reader.snapshot(sessionID: second, contextSessionID: first) else {
            Issue.record("Expected continuation with context"); return
        }
        #expect(snapshot.tasks.tasks.map(\.id) == [third])
        #expect(snapshot.turns.first?.kind == .assistant("Reply for \(second)"))
        guard case .output(.agent(let turns, _)) = reader.tail(sessionID: third, rootSessionID: second, contextRootSessionID: first) else {
            Issue.record("Expected source child context"); return
        }
        #expect(turns.first?.kind == .assistant("Reply for \(third)"))
        #expect(reader.tail(sessionID: third, rootSessionID: second) == .unreadable)
        try db.run("UPDATE threads SET cwd=? WHERE id=?", [.text("relative/path"), .text(first)])
        #expect(await reader.workingDirectory(sessionID: first) == nil)
    }
    @Test func shortDatabaseWriterLockDoesNotEraseTheSessionList() async throws {
        let (root, db) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        try insert(first, root: root, db: db)
        let path = root.appendingPathComponent("state_5.sqlite").path
        let released = DispatchSemaphore(value: 0)
        let locked: Bool = await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                do {
                    let writer = try SQLiteDatabase(path: path)
                    try writer.exec("BEGIN EXCLUSIVE")
                    continuation.resume(returning: true)
                    Thread.sleep(forTimeInterval: 0.15)
                    try? writer.exec("COMMIT")
                } catch {
                    // Opening/locking failure must fail the fixture instead of looking like recovery.
                    continuation.resume(returning: false)
                }
                released.signal()
            }
        }
        #expect(locked)
        let result = await CodexLocalSessionReader(directory: root.path).read()
        let finished: Bool = await withCheckedContinuation { continuation in
            DispatchQueue.global().async { continuation.resume(returning: released.wait(timeout: .now() + 2) == .success) }
        }
        #expect(finished)
        guard case .sessions(let rows) = result else { Issue.record("Short writer lock must recover"); return }
        #expect(rows.map(\.id) == [first])
    }
    @Test func prolongedLockIsTransientButInvalidSchemaIsNot() async throws {
        let (root, db) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        try insert(first, root: root, db: db)
        try db.exec("BEGIN EXCLUSIVE")
        let reader = CodexLocalSessionReader(directory: root.path)
        #expect(await reader.read() == .temporarilyUnavailable)
        #expect(await reader.snapshot(sessionID: first) == .temporarilyUnavailable)
        try db.exec("ROLLBACK")
        try db.exec("DROP TABLE thread_spawn_edges")
        #expect(await reader.read() == .unreadable)
    }

    private final class SidecarRace: @unchecked Sendable {
        private let lock = NSLock()
        private var observed = false
        func firstObservation() -> Bool {
            lock.withLock {
                guard !observed else { return false }
                observed = true
                return true
            }
        }
    }

    @Test func disappearingSidecarRevalidatesButExistingSymlinkStillFails() async throws {
        let (root, db) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        try insert(first, root: root, db: db)
        let sidecar = root.appendingPathComponent("state_5.sqlite-wal").path
        let race = SidecarRace()
        var files = ExternalSessionFileSystem.live
        files.lstat = { path in
            if path == sidecar, race.firstObservation() {
                return .init(name: "state_5.sqlite-wal", kind: .regular, owner: ExternalSessionFileSystem.live.userID,
                             size: 0, modified: Date(), created: Date(), mode: 0o600)
            }
            return ExternalSessionFileSystem.live.lstat(path)
        }
        let reader = CodexLocalSessionReader(directory: root.path, files: files)
        guard case .sessions(let rows) = await reader.read() else { Issue.record("Sidecar disappeared during validation"); return }
        #expect(rows.map(\.id) == [first])
        try FileManager.default.createSymbolicLink(atPath: sidecar, withDestinationPath: root.appendingPathComponent("state_5.sqlite").path)
        #expect(await reader.read() == .unreadable)
    }

    @Test func listStatusUsesValidatedTerminalHistoryAndIsolatesUnreadableTranscripts() async throws {
        let (root, db) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        try insert(first, root: root, db: db)
        try insert(second, root: root, db: db, metaID: third)
        for id in [first, second] {
            let path = root.appendingPathComponent("sessions/\(id).jsonl")
            var data = try Data(contentsOf: path)
            data.append(try line(["type": "event_msg", "payload": ["type": "task_complete", "turn_id": "turn-1"]]))
            try data.write(to: path)
        }
        guard case .sessions(let rows) = await CodexLocalSessionReader(directory: root.path).read() else {
            Issue.record("Bad transcript must not erase the list"); return
        }
        #expect(rows.first(where: { $0.id == first })?.status == .done)
        #expect(rows.first(where: { $0.id == second })?.status == .unknown)
    }
    @Test func canonicalRootsExcludeChildrenGuardiansAndArchivedAndPreserveRenames() async throws {
        let (root, db) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        try insert(first, root: root, db: db)
        try insert(second, root: root, db: db, parent: first)
        try insert(third, root: root, db: db, source: "{\"subagent\":{\"other\":\"guardian\"}}")
        try line(["id":first,"thread_name":"Renamed task"]).write(to: root.appendingPathComponent("session_index.jsonl"))
        let reader = CodexLocalSessionReader(directory: root.path)
        guard case .sessions(let rows) = await reader.read() else { Issue.record("Expected roots"); return }
        #expect(rows.map(\.id) == [first]); #expect(rows.first?.title == "Renamed task")
        try db.run("UPDATE threads SET archived=1 WHERE id=?", [.text(first)])
        #expect(await reader.read() == .sessions([]))
    }
    @Test func nativeTreePreservesGrandchildrenAndUnknownStatusAndReadsSelectedChildOnly() async throws {
        let (root, db) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        try insert(first, root: root, db: db)
        try insert(second, root: root, db: db, parent: first)
        try insert(third, root: root, db: db, parent: second)
        let filePath = root.appendingPathComponent("sessions/\(first).jsonl").path
        #expect(ExternalSessionFileSystem.live.realpath(filePath) == filePath)
        let head = try #require(ExternalSessionFileSystem.live.read(filePath, 0, 1 << 20))
        #expect(CodexTranscriptParser.matchesSession(head, id: first))
        // Repeated edge and backward edge cannot duplicate or reparent nodes.
        try db.run("INSERT INTO thread_spawn_edges VALUES(?,?,?)", [.text(third),.text(second),.text("done")])
        let reader = CodexLocalSessionReader(directory: root.path)
        guard case .snapshot(let snapshot) = await reader.snapshot(sessionID:first) else { Issue.record("Expected snapshot"); return }
        #expect(snapshot.tasks.tasks.count == 2)
        #expect(snapshot.tasks.tasks.allSatisfy { $0.statusUnknown && $0.status == .stopped })
        #expect(snapshot.tasks.tasks.first(where: { $0.id == third })?.parentID == second)
        #expect(snapshot.turns.count == 1)
        guard case .output(.agent(let turns, _)) = reader.tail(sessionID:third, rootSessionID:first) else { Issue.record("Expected child"); return }
        #expect(turns.first?.kind == .assistant("Reply for \(third)"))
        #expect(reader.tail(sessionID:first, rootSessionID:first) == .unreadable)
    }
    @Test func rejectsMismatchedIdentityAndOutsideOrSymlinkPaths() async throws {
        let (root, db) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        try insert(first, root: root, db: db)
        try insert(second, root: root, db: db, parent:first, metaID:third)
        let reader = CodexLocalSessionReader(directory: root.path)
        #expect(reader.tail(sessionID:second, rootSessionID:first) == .unreadable)
        try db.run("UPDATE threads SET rollout_path=? WHERE id=?", [.text(root.appendingPathComponent("sessions/../private.jsonl").path),.text(first)])
        #expect(await reader.snapshot(sessionID:first) == .unreadable)
        db.close()
        try FileManager.default.moveItem(at:root.appendingPathComponent("state_5.sqlite"),to:root.appendingPathComponent("other.sqlite"))
        try FileManager.default.createSymbolicLink(at:root.appendingPathComponent("state_5.sqlite"),withDestinationURL:root.appendingPathComponent("other.sqlite"))
        #expect(await reader.read() == .unreadable)
    }
    @Test func transcriptExcludesInjectedContentAndMirrorsAndBoundsText() throws {
        var data = try line(["type":"event_msg", "payload":["type":"user_message","message":"Mirror"]])
        data.append(try line(["type":"response_item","payload":["type":"message","role":"user","content":[["type":"input_text","text":"Injected"],["type":"input_text","text":"Actual request"]],"internal_chat_message_metadata_passthrough":["content_item_kinds":["agents_md.instructions","user.text"]]]]))
        data.append(try line(["type":"response_item","payload":["type":"message","role":"user","content":[["type":"input_text","text":"<environment_context>secret</environment_context>"]]]]))
        data.append(try line(["type":"response_item","payload":["type":"message","role":"assistant","content":[["type":"output_text","text":String(repeating:"a",count:40_000)]]]]))
        data.append(Data("partial".utf8))
        let parsed = CodexTranscriptParser.parse(data)
        #expect(parsed.turns.count == 2); #expect(parsed.turns.first?.kind == .user("Actual request")); #expect(parsed.turns.last?.truncated == true)
        let oversized = Data((String(repeating:"x",count:(1 << 20) + 1) + "\n").utf8)
        #expect(CodexTranscriptParser.parse(oversized).turns.isEmpty)
    }
    @Test func missingAndInvalidSchemaFailWithoutStaleRows() async throws {
        let (root, db) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let reader = CodexLocalSessionReader(directory:root.path)
        #expect(await reader.read() == .sessions([]))
        try db.exec("DROP TABLE thread_spawn_edges")
        #expect(await reader.read() == .unreadable)
    }
    @Test func transcriptBoundsTurnsAndIgnoresMalformedMetadataAndDeveloperMessages() throws {
        var data = Data()
        for _ in 0..<205 {
            data.append(try line(["type":"response_item","payload":["type":"message","role":"assistant","content":[["type":"output_text","text":"Reply"]]]]))
        }
        data.append(try line(["type":"response_item","payload":["type":"message","role":"user","content":[["type":"input_text","text":"Hidden"]],"internal_chat_message_metadata_passthrough":["content_item_kinds":[]]]]))
        data.append(try line(["type":"response_item","payload":["type":"message","role":"developer","content":[["type":"input_text","text":"Hidden"]]]]))
        data.append(try line(["type":"response_item","payload":["type":"message","role":"assistant","channel":"analysis","content":[["type":"output_text","text":"Hidden reasoning"]]]]))
        data.append(try line(["type":"response_item","payload":["type":"message","role":"user","content":[["type":"input_text","text":"Hidden malformed metadata"]],"internal_chat_message_metadata_passthrough":"invalid"]]))
        let parsed = CodexTranscriptParser.parse(data)
        #expect(parsed.turns.last?.kind == .assistant("Reply"))
        #expect(parsed.turns.count == 200); #expect(parsed.hasEarlier)
        #expect(CodexTranscriptParser.parse(Data("broken\n".utf8)).turns.isEmpty)
    }
    @Test func graphDepthAndRootListAreBounded() async throws {
        let (root, db) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        try insert(first, root: root, db: db)
        var parent = first
        for n in 2...20 {
            let id = String(format: "10000000-0000-0000-0000-%012d", n)
            try insert(id, root: root, db: db, parent: parent); parent = id
        }
        let reader = CodexLocalSessionReader(directory: root.path)
        guard case .snapshot(let snapshot) = await reader.snapshot(sessionID:first) else { Issue.record("Expected snapshot"); return }
        #expect(snapshot.tasks.tasks.count == 16)
        #expect(reader.tail(sessionID:parent, rootSessionID:first) == .unreadable)
        for n in 100...305 {
            let id = String(format: "10000000-0000-0000-0000-%012d", n)
            try db.run("INSERT INTO threads VALUES(?,?,?,?,?,?,?)", [.text(id),.text("Task"),.text("unused"),.int(Int64(n)),.text("vscode"),.int(0),.text(root.path)])
        }
        guard case .sessions(let sessions) = await reader.read() else { Issue.record("Expected list"); return }
        #expect(sessions.count == 200)
    }
    @Test func metadataInitializerRetainsFirstLevelBoundsAndNeverInventsRunning() {
        let tasks = (0..<300).map { BackgroundTask(id:"task-\($0)",kind:.agent,name:"Task",status:.running,depth:1) }
        let list = BackgroundTaskList(metadataTasks:tasks)
        #expect(list.tasks.count == 256)
        #expect(list.tasks.allSatisfy { $0.statusUnknown && $0.status == .stopped && $0.parentID == nil })
    }
}
#endif
