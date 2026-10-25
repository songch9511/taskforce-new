#if os(macOS)
import Foundation
import Testing
@testable import TaskforceKit

struct CodexObservedStatusTests {
    private func event(_ type: String, turn: String? = "one", error: Any? = nil) throws -> Data {
        var payload: [String: Any] = ["type": type]
        if let turn { payload["turn_id"] = turn }
        if let error { payload["error"] = error }
        var data = try JSONSerialization.data(withJSONObject: ["type": "event_msg", "payload": payload])
        data.append(10)
        return data
    }

    @Test func terminalStatesRequireLifecycleEvidence() throws {
        #expect(CodexObservedStatus.parse(Data()) == .unknown)
        #expect(CodexObservedStatus.parse(try event("task_started")) == .unknown)
        #expect(CodexObservedStatus.parse(try event("task_complete")) == .done)
        #expect(CodexObservedStatus.parse(try event("task_complete", error: NSNull())) == .done)
        #expect(CodexObservedStatus.parse(try event("task_complete", error: ["message": "failed"])) == .failed)
        #expect(CodexObservedStatus.parse(try event("turn_aborted")) == .idle)
        #expect(CodexObservedStatus.parse(try event("task_complete", turn: nil)) == .unknown)
    }

    @Test func newestStartCannotBeCompletedByAnOlderTurn() throws {
        var data = try event("task_started", turn: "old")
        data.append(try event("task_complete", turn: "old"))
        data.append(try event("task_started", turn: "new"))
        data.append(try event("task_complete", turn: "old"))
        #expect(CodexObservedStatus.parse(data) == .unknown)
        data.append(try event("turn_aborted", turn: "old"))
        #expect(CodexObservedStatus.parse(data) == .unknown)
        data.append(try event("task_complete", turn: "new"))
        #expect(CodexObservedStatus.parse(data) == .done)
    }

    @Test func unrelatedRecordsDoNotChangeTerminalState() throws {
        var data = try event("task_complete")
        for type in ["thread_settings_applied", "item_completed", "token_count"] {
            data.append(try event(type, turn: "other"))
        }
        var response = try JSONSerialization.data(withJSONObject: ["type": "response_item", "payload": ["type": "task_started", "turn_id": "other"]])
        response.append(10)
        data.append(response)
        #expect(CodexObservedStatus.parse(data) == .done)
    }

    @Test func partialFirstAndLastRecordsAreNotLifecycleEvidence() throws {
        let complete = try event("task_complete")
        #expect(CodexObservedStatus.parse(complete, offset: 10) == .unknown)
        #expect(CodexObservedStatus.parse(Data(complete.dropLast())) == .unknown)
        var data = Data("partial first record\n".utf8)
        data.append(try event("task_started"))
        data.append(Data(complete.dropLast()))
        #expect(CodexObservedStatus.parse(data, offset: 10) == .unknown)
        data.append(10)
        #expect(CodexObservedStatus.parse(data, offset: 10) == .done)
    }

    @Test func malformedLifecycleCannotLeaveAStaleCompletion() throws {
        var data = try event("task_complete")
        data.append(try event("task_started", turn: nil))
        #expect(CodexObservedStatus.parse(data) == .unknown)
        data = try event("task_complete")
        data.append(Data("invalid json\n".utf8))
        #expect(CodexObservedStatus.parse(data) == .unknown)
    }
}
#endif
