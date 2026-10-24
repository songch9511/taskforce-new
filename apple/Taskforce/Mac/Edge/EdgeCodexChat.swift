#if os(macOS)
import AppKit
import SwiftUI
import TaskforceUI
import Observation
import TaskforceKit

/// Account-owned continuation. A panel may detach without ending the turn.
@MainActor
@Observable
final class CodexSessionChatModel {
    typealias Send = @Sendable (String, String) async throws -> CodexChatReceipt
    var draft = ""
    private var childDrafts: [String: String] = [:]
    private(set) var sessionID: String?
    private(set) var managedThreadID: String?
    private(set) var isRunning = false
    private(set) var requests: [CodexChatPrompt] = []
    private(set) var responding: Set<String> = []
    @ObservationIgnored var onManagedThread: (String) -> Void = { _ in }
    @ObservationIgnored private var sender: CodexChatSender?
    @ObservationIgnored private var eventLoop: Task<Void, Never>?
    private(set) var isSending = false
    private(set) var errorMessage: String?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var pending: Task<Void, Never>?
    @ObservationIgnored private var send: Send?
    @ObservationIgnored private var disconnect: (@Sendable () async -> Void)?

    func start(_ id: String, managedThreadID: String? = nil, send: Send? = nil, disconnect: (@Sendable () async -> Void)? = nil) {
        stop()
        sessionID = id
        self.managedThreadID = managedThreadID
        if let send {
            self.send = send
            self.disconnect = disconnect
        } else {
            let sender = CodexChatSender(managedThreadID: managedThreadID)
            self.sender = sender
            let token = generation
            eventLoop = Task { [weak self] in
                for await event in sender.events {
                    guard !Task.isCancelled, let self, self.generation == token else { return }
                    self.receive(event)
                }
            }
            self.send = { try await sender.send(threadID: $0, text: $1) }
            self.disconnect = { await sender.stop() }
        }
    }

    func stop() {
        generation = UUID()
        eventLoop?.cancel()
        eventLoop = nil
        sender = nil
        requests = []
        responding = []
        isRunning = false
        managedThreadID = nil
        pending?.cancel()
        pending = nil
        if let disconnect { Task { await disconnect() } }
        disconnect = nil
        send = nil
        sessionID = nil
        draft = ""
        childDrafts = [:]
        isSending = false
        errorMessage = nil
    }

    @discardableResult
    func submitRoot(pane: SessionSidePaneModel) -> Task<Void, Never>? {
        guard pane.allowsRootInput else { return nil }
        let original = draft
        return submit(ChatComposerRules.normalized(original)) { [weak self] in
            if self?.draft == original { self?.draft = "" }
        }
    }

    func childDraft(for id: String) -> String { childDrafts[id] ?? "" }
    func setChildDraft(_ text: String, for id: String) { childDrafts[id] = text }

    @discardableResult
    func submitChild(_ task: TaskforceKit.BackgroundTask, pane: SessionSidePaneModel) -> Task<Void, Never>? {
        guard pane.showsTree, pane.selectedID == task.id,
              let payload = AgentTreeContextMessage.make(task: task, text: childDraft(for: task.id)) else { return nil }
        let original = childDraft(for: task.id)
        let draftGeneration = pane.draftGeneration
        return submit(payload) { [weak self, weak pane] in
            if self?.childDraft(for: task.id) == original { self?.childDrafts[task.id] = nil }
            guard let pane, pane.draftGeneration == draftGeneration else { return }
            if pane.selectedID == task.id { pane.selectRootInTree() }
        }
    }

    private func submit(_ text: String, accepted: @escaping @MainActor () -> Void) -> Task<Void, Never>? {
        guard !isSending, !isRunning, let sessionID, let send, ChatComposerRules.isSendable(text) else { return nil }
        let token = generation
        isSending = true
        isRunning = true
        errorMessage = nil
        let task = Task { [weak self] in
            do {
                let receipt = try await send(sessionID, text)
                guard !Task.isCancelled, let self, self.generation == token else { return }
                self.isSending = false
                self.pending = nil
                self.managedThreadID = receipt.threadID
                self.onManagedThread(receipt.threadID)
                accepted()
            } catch {
                guard !Task.isCancelled, let self, self.generation == token else { return }
                self.isSending = false
                self.pending = nil
                self.isRunning = false
                self.errorMessage = Self.message(for: error)
            }
        }
        pending = task
        return task
    }

    func receive(_ event: CodexChatEvent) {
        switch event {
        case .managedThread(let id):
            managedThreadID = id
            onManagedThread(id)
        case .approval(let id, let kind, let summary):
            requests.removeAll { $0.id == id }
            requests.append(.approval(id: id, kind: kind, summary: summary))
        case .input(let id, let questions):
            requests.removeAll { $0.id == id }
            requests.append(.input(id: id, questions: questions))
        case .requestResolved(let id):
            requests.removeAll { $0.id == id }
            responding.remove(id)
        case .turnCompleted:
            isRunning = false
            requests = []
            responding = []
        case .failure(let error):
            isRunning = false
            requests = []
            responding = []
            errorMessage = Self.message(for: error)
        }
    }

    func interrupt() {
        guard let sender else { return }
        let token = generation
        Task { [weak self] in
            do { try await sender.interrupt() }
            catch {
                guard let self, self.generation == token else { return }
                self.errorMessage = Self.message(for: error)
            }
        }
    }

    func respond(_ id: String, response: CodexChatResponse) {
        guard let sender, requests.contains(where: { $0.id == id }), !responding.contains(id) else { return }
        responding.insert(id)
        let token = generation
        Task { [weak self] in
            do {
                try await sender.respond(requestID: id, response: response)
                guard let self, self.generation == token else { return }
                self.requests.removeAll { $0.id == id }
                self.responding.remove(id)
            } catch {
                guard let self, self.generation == token else { return }
                self.responding.remove(id)
                self.errorMessage = Self.message(for: error)
            }
        }
    }

    private static func message(for error: Error) -> String {
        switch error as? CodexChatSendError {
        case .unavailable: "Couldn’t start Codex. Check that Codex is installed and signed in. Your message was kept."
        case .sessionUnavailable: "This conversation is unavailable in Codex. Your message was kept."
        case .deliveryUnknown: "Delivery couldn’t be confirmed. Check the conversation before sending again."
        case .rejected: "Codex couldn’t accept this message. Your message was kept."
        default: "Couldn’t send this message. Your message was kept."
        }
    }
}

enum CodexChatPrompt: Identifiable {
    case approval(id: String, kind: String, summary: String)
    case input(id: String, questions: [CodexChatQuestion])
    var id: String {
        switch self { case .approval(let id, _, _), .input(let id, _): id }
    }
}

@MainActor
final class CodexChatRuntime {
    private var account: UUID?
    private var chats: [String: CodexSessionChatModel] = [:]
    private let defaults: UserDefaults
    private var terminationObserver: NSObjectProtocol?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        terminationObserver = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.stop() }
        }
    }

    func adopt(_ account: UUID?) {
        guard self.account != account else { return }
        stop()
        self.account = account
    }

    func chat(sourceID: String) -> CodexSessionChatModel? {
        guard let account else { return nil }
        if let chat = chats[sourceID] { return chat }
        let key = "codex-managed-thread.\(account.uuidString).\(sourceID)"
        let saved = defaults.string(forKey: key)
        let chat = CodexSessionChatModel()
        chat.onManagedThread = { [weak self] managed in
            guard let self, self.account == account, managed != sourceID,
                  ExternalSessionRules.isCanonicalUUID(managed) else { return }
            self.defaults.set(managed, forKey: key)
        }
        chat.start(sourceID, managedThreadID: saved.flatMap { ExternalSessionRules.isCanonicalUUID($0) && $0 != sourceID ? $0 : nil })
        chats[sourceID] = chat
        return chat
    }

    func isManagedThread(_ id: String) -> Bool {
        guard let account, ExternalSessionRules.isCanonicalUUID(id) else { return false }
        let prefix = "codex-managed-thread.\(account.uuidString)."
        return defaults.dictionaryRepresentation().contains { key, value in
            guard key.hasPrefix(prefix), let managed = value as? String, managed == id else { return false }
            let source = String(key.dropFirst(prefix.count))
            return source != managed && ExternalSessionRules.isCanonicalUUID(source)
        }
    }

    func stop() {
        for chat in chats.values { chat.stop() }
        chats = [:]
    }
}

struct CodexChatPromptsView: View {
    @Bindable var chat: CodexSessionChatModel
    var body: some View {
        if !chat.requests.isEmpty {
            ScrollView {
                requests
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 220)
        }
    }

    private var requests: some View {
        VStack(alignment: .leading, spacing: TFSpace.md) {
            ForEach(chat.requests) { request in
                switch request {
                case .approval(let id, let kind, let summary):
                    VStack(alignment: .leading, spacing: TFSpace.sm) {
                        Text(kind == "file" ? "Allow file changes?" : "Allow this action?").font(TFFont.callout)
                        Text(summary).font(TFFont.footnote).textSelection(.enabled)
                        HStack {
                            Button("Allow once") { chat.respond(id, response: .approve) }
                            Button("Deny") { chat.respond(id, response: .deny) }
                        }.buttonStyle(TFButtonStyle(.secondary, size: .sm))
                    }.disabled(chat.responding.contains(id))
                case .input(let id, let questions):
                    CodexInputPromptView(questions: questions, isSending: chat.responding.contains(id)) { chat.respond(id, response: .input($0)) }
                        .id(id)
                }
            }
        }
    }
}

private struct CodexInputPromptView: View {
    let questions: [CodexChatQuestion]
    let isSending: Bool
    let submit: ([String: [String]]) -> Void
    @State private var answers: [String: String] = [:]
    var body: some View {
        VStack(alignment: .leading, spacing: TFSpace.sm) {
            ForEach(questions, id: \.id) { question in
                Text(question.question).font(TFFont.callout)
                if !question.isSecret {
                    ForEach(question.options, id: \.self) { option in
                        Button {
                            answers[question.id] = option
                        } label: {
                            Label(option, systemImage: answers[question.id] == option ? "checkmark.circle.fill" : "circle")
                        }.buttonStyle(.plain)
                    }
                }
                let text = Binding(get: { answers[question.id] ?? "" }, set: { answers[question.id] = $0 })
                if question.isSecret { SecureField("Your answer", text: text) }
                else { TextField("Your answer", text: text) }
            }
            Button("Send answer") {
                submit(answers.mapValues { [$0] })
            }
            .buttonStyle(TFButtonStyle(.secondary, size: .sm))
            .disabled(isSending || questions.contains { (answers[$0.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
        }.disabled(isSending)
    }
}
#endif
