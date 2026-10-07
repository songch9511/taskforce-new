import Foundation
import Testing
@testable import Taskforce
@testable import TaskforceKit

@Suite(.serialized)
@MainActor
struct ActionNotesStoreTests {
    @Test func flushWaitsForInflightSaveAndPersistsRevertBeforeHandoff() async throws {
        let id = UUID()
        let mock = NotesMock(reads: [ActionNotes(actionID: id, markdown: "original", revision: 1)])
        let store = makeStore(mock, debounce: .seconds(30))
        store.setOwner(UUID())
        await store.load(id)
        await mock.holdNextWrite()
        #expect(store.edit("first edit", for: id))

        let handoff = Task { await store.flush(id) }
        try await waitUntil { await mock.writeCount() == 1 }
        #expect(store.edit("original", for: id))
        await mock.releaseHeldWrite()

        #expect(await handoff.value)
        #expect(await mock.writeCalls() == [
            .init(id: id, markdown: "first edit", expectedRevision: 1),
            .init(id: id, markdown: "original", expectedRevision: 2)
        ])
        #expect(store.entry(for: id).markdown == "original")
        #expect(store.entry(for: id).revision == 3)
        #expect(!store.entry(for: id).isDirty)
        store.setOwner(nil)
    }

    @Test func lateReadFromPreviousAccountCannotReplaceCurrentActionNotes() async throws {
        let id = UUID()
        let mock = NotesMock(reads: [
            ActionNotes(actionID: id, markdown: "previous account", revision: 1),
            ActionNotes(actionID: id, markdown: "current account", revision: 4)
        ])
        await mock.holdReads()
        let store = makeStore(mock)
        store.setOwner(UUID())
        let previousRead = Task { await store.load(id) }
        try await waitUntil { await mock.readCount() == 1 }

        store.setOwner(UUID())
        let currentRead = Task { await store.load(id) }
        try await waitUntil { await mock.readCount() == 2 }
        await mock.releaseRead(2)
        await currentRead.value
        #expect(store.entry(for: id).markdown == "current account")

        await mock.releaseRead(1)
        await previousRead.value
        #expect(store.entry(for: id).markdown == "current account")
        store.setOwner(nil)
    }

    @Test func conflictKeepsDraftAndRetryMineUsesServerRevision() async throws {
        let id = UUID()
        let mock = NotesMock(reads: [
            ActionNotes(actionID: id, markdown: "initial", revision: 2),
            ActionNotes(actionID: id, markdown: "server version", revision: 8)
        ])
        await mock.conflictNextWrite()
        let store = makeStore(mock, debounce: .seconds(30))
        store.setOwner(UUID())
        await store.load(id)
        #expect(store.edit("my draft", for: id))
        #expect(!(await store.flush(id)))
        #expect(store.entry(for: id).markdown == "my draft")
        #expect(store.entry(for: id).serverVersion?.markdown == "server version")
        #expect(!store.entry(for: id).isSaving)

        #expect(await store.retryMine(id))
        #expect(await mock.writeCalls().map(\.expectedRevision) == [2, 8])
        #expect(store.entry(for: id).markdown == "my draft")
        #expect(store.entry(for: id).revision == 9)
        #expect(store.entry(for: id).serverVersion == nil)
        store.setOwner(nil)
    }

    @Test func saveFailureRetainsDraftUntilExplicitRetry() async throws {
        let id = UUID()
        let mock = NotesMock(reads: [ActionNotes(actionID: id, markdown: "saved", revision: 1)])
        await mock.failNextWrite()
        let store = makeStore(mock, debounce: .seconds(30))
        store.setOwner(UUID())
        await store.load(id)
        #expect(store.edit("unsaved draft", for: id))
        #expect(!(await store.flush(id)))
        #expect(store.entry(for: id).markdown == "unsaved draft")
        #expect(store.entry(for: id).isDirty)
        #expect(store.entry(for: id).error != nil)

        #expect(await store.retry(id))
        #expect(store.entry(for: id).savedMarkdown == "unsaved draft")
        store.setOwner(nil)
    }

    @Test func enforcesUTF16LengthWithoutDroppingTheExistingDraft() async throws {
        let id = UUID()
        let store = makeStore(NotesMock(reads: [ActionNotes(actionID: id, markdown: "", revision: 0)]))
        store.setOwner(UUID())
        await store.load(id)
        #expect(store.edit(String(repeating: "가", count: 5_000), for: id))
        #expect(!store.edit(String(repeating: "😀", count: 5_001), for: id))
        #expect(store.entry(for: id).markdown.utf16.count == 5_000)
        #expect(store.entry(for: id).error != nil)
        store.setOwner(nil)
    }

    private func makeStore(_ mock: NotesMock, debounce: Duration = .milliseconds(450)) -> ActionNotesStore {
        ActionNotesStore(
            debounce: debounce,
            read: { id in try await mock.read(id) },
            write: { id, markdown, revision in try await mock.write(id, markdown: markdown, revision: revision) }
        )
    }

    private func waitUntil(_ condition: @escaping @Sendable () async -> Bool) async throws {
        for _ in 0..<200 {
            if await condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        throw NotesTestTimeout()
    }
}

private struct NotesTestTimeout: Error {}

private actor NotesMock {
    struct WriteCall: Equatable, Sendable {
        let id: UUID
        let markdown: String
        let expectedRevision: Int
    }

    private var reads: [ActionNotes?]
    private var readIndex = 0
    private var readIsHeld = false
    private var readContinuations: [Int: CheckedContinuation<ActionNotes?, Error>] = [:]
    private var calls: [WriteCall] = []
    private var holdWrite = false
    private var heldWrite: CheckedContinuation<ActionNotes, Error>?
    private var shouldConflict = false
    private var shouldFail = false

    init(reads: [ActionNotes?]) { self.reads = reads }

    func holdReads() { readIsHeld = true }
    func holdNextWrite() { holdWrite = true }
    func conflictNextWrite() { shouldConflict = true }
    func failNextWrite() { shouldFail = true }
    func readCount() -> Int { readIndex }
    func writeCount() -> Int { calls.count }
    func writeCalls() -> [WriteCall] { calls }

    func read(_ id: UUID) async throws -> ActionNotes? {
        readIndex += 1
        let index = readIndex
        if readIsHeld {
            return try await withCheckedThrowingContinuation { readContinuations[index] = $0 }
        }
        guard reads.indices.contains(index - 1) else { return reads.last ?? nil }
        return reads[index - 1]
    }

    func releaseRead(_ index: Int) {
        guard readContinuations[index] != nil else { return }
        let continuation = readContinuations.removeValue(forKey: index)!
        let result = reads.indices.contains(index - 1) ? reads[index - 1] : reads.last ?? nil
        continuation.resume(returning: result)
    }

    func write(_ id: UUID, markdown: String, revision: Int) async throws -> ActionNotes {
        calls.append(.init(id: id, markdown: markdown, expectedRevision: revision))
        if holdWrite {
            holdWrite = false
            return try await withCheckedThrowingContinuation { heldWrite = $0 }
        }
        if shouldConflict {
            shouldConflict = false
            throw APIError.server(status: 409, code: .conflict, message: "Changed")
        }
        if shouldFail {
            shouldFail = false
            throw APIError.transport("offline")
        }
        return ActionNotes(actionID: id, markdown: markdown, revision: revision + 1)
    }

    func releaseHeldWrite() {
        guard let continuation = heldWrite else { return }
        heldWrite = nil
        guard let call = calls.first else { return }
        continuation.resume(returning: ActionNotes(actionID: call.id, markdown: call.markdown, revision: call.expectedRevision + 1))
    }
}
