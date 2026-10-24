#if os(macOS)
import Foundation
import Testing
@testable import TaskforceKit

struct CodexLocalSessionsTests {
    private let first = "10000000-0000-0000-0000-000000000001"
    private let second = "10000000-0000-0000-0000-000000000002"
    private func line(_ id: String, _ title: String, _ date: String = "2026-10-25T00:00:00Z") -> String {
        let data = try! JSONSerialization.data(withJSONObject: ["id": id, "thread_name": title, "updated_at": date], options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self) + "\n"
    }

    @Test func newestMetadataWinsAndTitlesAreSanitized() {
        let data = line(first, "new\nname", "2026-10-25T01:00:00.123Z") + line(second, "other") + line(first, "old")
        let rows = CodexLocalSessionReader.parse(Data(data.utf8))
        #expect(rows.map(\.id) == [first, second])
        #expect(rows.first?.title == "new name")
        #expect(rows.first?.openURL?.absoluteString == "codex://threads/\(first)")
        #expect(rows.first?.description == "CodexLocalSession")
    }

    @Test func malformedAndPartialRecordsCannotCreateRowsOrURLs() {
        let data = line("../../anything", "unsafe") + "not-json\n" + line(first, "valid") + line(second, "partial").dropLast()
        #expect(CodexLocalSessionReader.parse(Data(data.utf8)).map(\.id) == [first])
        #expect(CodexLocalSessionReader.parse(Data(line(first, "cut").utf8), startsMidRecord: true).isEmpty)
        #expect(CodexLocalSessionReader.parse(Data(line(first, "bad", "invalid").utf8)).isEmpty)
    }

    @Test func capsVisibleMetadataAndSkipsOversizedRecords() {
        let records = (1...205).map {
            line(String(format: "10000000-0000-0000-0000-%012d", $0), "Session \($0)")
        }.joined()
        #expect(CodexLocalSessionReader.parse(Data(records.utf8)).count == 200)
        #expect(CodexLocalSessionReader.parse(Data(line(first, String(repeating: "x", count: 20_000)).utf8)).isEmpty)
    }

    @Test func readsOnlyIndexAndRejectsSymlinks() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let reader = CodexLocalSessionReader(directory: root.path)
        #expect(await reader.read() == .sessions([]))
        let file = root.appendingPathComponent("session_index.jsonl")
        try Data(line(first, "actual metadata").utf8).write(to: file)
        guard case .sessions(let rows) = await reader.read() else { Issue.record("Index should load"); return }
        #expect(rows.count == 1)
        try FileManager.default.removeItem(at: file)
        let elsewhere = root.appendingPathComponent("other.jsonl")
        try Data(line(second, "must not read").utf8).write(to: elsewhere)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: elsewhere)
        #expect(await reader.read() == .unreadable)
    }

    @Test func readFailureDoesNotReuseStaleSessions() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("session_index.jsonl")
        try Data(line(first, "before removal").utf8).write(to: file)
        let reader = CodexLocalSessionReader(directory: root.path)
        guard case .sessions(let rows) = await reader.read() else { Issue.record("Index should load"); return }
        #expect(rows.count == 1)
        try FileManager.default.removeItem(at: file)
        #expect(await reader.read() == .sessions([]))
    }
}
#endif
