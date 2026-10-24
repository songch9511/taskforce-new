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
        try db.exec("CREATE TABLE threads(id TEXT PRIMARY KEY,title TEXT,rollout_path TEXT,updated_at INTEGER,source TEXT,archived INTEGER); CREATE TABLE thread_spawn_edges(parent_thread_id TEXT,child_thread_id TEXT,status TEXT)")
        return (root, db)
    }
    private func insert(_ id: String, root: URL, db: SQLiteDatabase, parent: String? = nil, source: String? = nil, archived: Int64 = 0, metaID: String? = nil) throws {
        let path = root.appendingPathComponent("sessions/\(id).jsonl")
        var data = try line(["type":"session_meta", "payload":["id": metaID ?? id]])
        data.append(try line(["type":"response_item", "payload":["type":"message", "role":"assistant", "content":[["type":"output_text", "text":"Reply for \(id)"]]]]))
        try data.write(to: path)
        let origin = try source ?? parent.map { String(decoding: try JSONSerialization.data(withJSONObject: ["subagent":["thread_spawn":["parent_thread_id":$0]]]), as: UTF8.self) } ?? "cli"
        try db.run("INSERT INTO threads VALUES(?,?,?,?,?,?)", [.text(id),.text("Original"),.text(path.path),.int(100),.text(origin),.int(archived)])
        if let parent { try db.run("INSERT INTO thread_spawn_edges VALUES(?,?,?)", [.text(parent),.text(id),.text("running")]) }
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
            try db.run("INSERT INTO threads VALUES(?,?,?,?,?,?)", [.text(id),.text("Task"),.text("unused"),.int(Int64(n)),.text("vscode"),.int(0)])
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
