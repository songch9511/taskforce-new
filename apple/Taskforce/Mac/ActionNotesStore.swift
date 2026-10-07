#if os(macOS)
import Foundation
import Observation
import TaskforceKit

/// Account-scoped, memory-only note drafts with serialized optimistic writes.
@MainActor
@Observable
final class ActionNotesStore {
    struct Entry: Equatable {
        var markdown = ""
        var savedMarkdown = ""
        var revision = 0
        var isLoaded = false
        var isLoading = false
        var isSaving = false
        var error: String?
        var serverVersion: ActionNotes?

        var isDirty: Bool { markdown != savedMarkdown }
    }

    typealias Reader = @Sendable (UUID) async throws -> ActionNotes?
    typealias Writer = @Sendable (UUID, String, Int) async throws -> ActionNotes

    private(set) var ownerID: UUID?
    private(set) var entries: [UUID: Entry] = [:]
    let maximumLength = 10_000

    @ObservationIgnored private let read: Reader
    @ObservationIgnored private let write: Writer
    @ObservationIgnored private let debounce: Duration
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var loadTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var debounceTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var saveTasks: [UUID: Task<Void, Never>] = [:]

    init(debounce: Duration = .milliseconds(450), read: @escaping Reader, write: @escaping Writer) {
        self.debounce = debounce
        self.read = read
        self.write = write
    }

    func entry(for id: UUID) -> Entry { entries[id] ?? Entry() }

    /// Sign-out and account switches discard drafts and make all earlier responses stale.
    func setOwner(_ id: UUID?) {
        guard ownerID != id else { return }
        generation += 1
        ownerID = id
        loadTasks.values.forEach { $0.cancel() }
        debounceTasks.values.forEach { $0.cancel() }
        saveTasks.values.forEach { $0.cancel() }
        loadTasks = [:]
        debounceTasks = [:]
        saveTasks = [:]
        entries = [:]
    }

    func load(_ id: UUID) async {
        guard ownerID != nil else { return }
        if entry(for: id).isLoaded { return }
        if let task = loadTasks[id] {
            await task.value
            return
        }

        var state = entry(for: id)
        state.isLoading = true
        state.error = nil
        entries[id] = state
        let requestGeneration = generation
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.readNotes(id, generation: requestGeneration)
        }
        loadTasks[id] = task
        await task.value
    }

    @discardableResult
    func edit(_ markdown: String, for id: UUID) -> Bool {
        var state = entry(for: id)
        guard markdown.utf16.count <= maximumLength else {
            state.error = "Notes can be up to 10,000 characters."
            entries[id] = state
            return false
        }
        guard markdown != state.markdown else { return true }
        state.markdown = markdown
        if state.serverVersion == nil { state.error = nil }
        entries[id] = state
        guard state.isLoaded else { return true }
        scheduleSave(for: id)
        return true
    }

    /// Flushes every edit made before the call. A conflict or save error blocks handoff.
    func flush(_ id: UUID) async -> Bool {
        guard ownerID != nil else { return false }
        let flushGeneration = generation
        debounceTasks[id]?.cancel()
        debounceTasks[id] = nil
        if !entry(for: id).isLoaded { await load(id) }
        guard generation == flushGeneration, ownerID != nil else { return false }

        while generation == flushGeneration, ownerID != nil {
            var state = entry(for: id)
            guard state.isLoaded, !state.isLoading else { return false }
            if let task = saveTasks[id] {
                await task.value
                guard generation == flushGeneration, ownerID != nil else { return false }
                continue
            }
            if state.serverVersion != nil || state.error != nil { return !state.isDirty && state.error == nil }
            if !state.isDirty { return true }

            let requestGeneration = generation
            let markdown = state.markdown
            let revision = state.revision
            state.isSaving = true
            state.error = nil
            entries[id] = state
            let task = Task { @MainActor [weak self] in
                guard let self else { return }
                await self.save(id, markdown: markdown, revision: revision, generation: requestGeneration)
            }
            saveTasks[id] = task
            await task.value
        }
        return false
    }

    func retry(_ id: UUID) async -> Bool {
        guard entry(for: id).serverVersion == nil else {
            await reloadServerVersion(id)
            return false
        }
        var state = entry(for: id)
        state.error = nil
        entries[id] = state
        return await flush(id)
    }

    func retryMine(_ id: UUID) async -> Bool {
        guard let server = entry(for: id).serverVersion else { return await retry(id) }
        var state = entry(for: id)
        state.revision = server.revision
        state.savedMarkdown = server.markdown
        state.serverVersion = nil
        state.error = nil
        entries[id] = state
        return await flush(id)
    }

    func useServerVersion(_ id: UUID) {
        guard let server = entry(for: id).serverVersion else { return }
        entries[id] = Entry(
            markdown: server.markdown, savedMarkdown: server.markdown, revision: server.revision,
            isLoaded: true
        )
    }

    #if DEBUG
    func applySample(_ markdown: String, for id: UUID) {
        entries[id] = Entry(markdown: markdown, savedMarkdown: markdown, revision: 1, isLoaded: true)
    }
    #endif

    private func scheduleSave(for id: UUID) {
        debounceTasks[id]?.cancel()
        let requestGeneration = generation
        debounceTasks[id] = Task { @MainActor [weak self] in
            guard let self else { return }
            do { try await Task.sleep(for: debounce) } catch { return }
            guard generation == requestGeneration, ownerID != nil else { return }
            debounceTasks[id] = nil
            _ = await flush(id)
        }
    }

    private func readNotes(_ id: UUID, generation requestGeneration: Int) async {
        defer { if generation == requestGeneration { loadTasks[id] = nil } }
        do {
            guard let server = try await read(id) else { throw APIError.server(status: 404, code: .notFound, message: "") }
            guard generation == requestGeneration, ownerID != nil else { return }
            guard server.actionID == id else { throw APIError.decoding("Action notes did not match the request") }
            var state = entry(for: id)
            let hasLocalDraft = state.isDirty
            state.revision = server.revision
            state.savedMarkdown = server.markdown
            if !hasLocalDraft { state.markdown = server.markdown }
            state.isLoaded = true
            state.isLoading = false
            state.error = nil
            entries[id] = state
            if state.isDirty { scheduleSave(for: id) }
        } catch {
            guard generation == requestGeneration, ownerID != nil else { return }
            var state = entry(for: id)
            state.isLoading = false
            state.error = Self.message(for: error)
            entries[id] = state
        }
    }

    private func save(_ id: UUID, markdown: String, revision: Int, generation requestGeneration: Int) async {
        defer { if generation == requestGeneration { saveTasks[id] = nil } }
        do {
            let server = try await write(id, markdown, revision)
            guard generation == requestGeneration, ownerID != nil else { return }
            guard server.actionID == id else { throw APIError.decoding("Saved notes did not match the request") }
            var state = entry(for: id)
            state.savedMarkdown = markdown
            state.revision = server.revision
            state.isSaving = false
            state.error = nil
            entries[id] = state
        } catch {
            guard generation == requestGeneration, ownerID != nil else { return }
            if (error as? APIError)?.isConflict == true {
                do {
                    guard let server = try await read(id) else {
                        throw APIError.server(status: 404, code: .notFound, message: "")
                    }
                    guard generation == requestGeneration, ownerID != nil else { return }
                    guard server.actionID == id else { throw APIError.decoding("Action notes did not match the request") }
                    var state = entry(for: id)
                    state.serverVersion = server
                    state.isSaving = false
                    state.error = "These notes changed elsewhere. Choose which version to keep."
                    entries[id] = state
                    return
                } catch {
                    guard generation == requestGeneration, ownerID != nil else { return }
                    var state = entry(for: id)
                    state.isSaving = false
                    state.error = (error as? APIError)?.isConflict == true
                        ? "These notes changed elsewhere, but the latest version couldn't be loaded. Retry to compare."
                        : Self.message(for: error)
                    entries[id] = state
                    return
                }
            }
            var state = entry(for: id)
            state.isSaving = false
            state.error = Self.message(for: error)
            entries[id] = state
        }
    }

    private func reloadServerVersion(_ id: UUID) async {
        guard ownerID != nil else { return }
        let requestGeneration = generation
        do {
            guard let server = try await read(id), generation == requestGeneration, ownerID != nil else { return }
            var state = entry(for: id)
            state.serverVersion = server
            state.isLoaded = true
            state.error = "These notes changed elsewhere. Choose which version to keep."
            entries[id] = state
        } catch {
            guard generation == requestGeneration, ownerID != nil else { return }
            var state = entry(for: id)
            state.error = Self.message(for: error)
            entries[id] = state
        }
    }

    private static func message(for error: Error) -> String {
        (error as? APIError)?.userMessage ?? "Couldn't save notes. Try again."
    }
}
#endif
