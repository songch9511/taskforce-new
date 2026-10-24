#if os(macOS)
import AppKit
import SwiftUI
import TaskforceKit
import TaskforceUI

/// Local, read-only Codex conversation. It never uses Claude's relay or desktop metrics.
@MainActor
@Observable
final class CodexSessionPanelModel {
    private(set) var sessionID: String?
    private(set) var turns: [ClaudeAppTurn] = []
    private(set) var failed = false
    private(set) var hasEarlier = false
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var loop: Task<Void, Never>?

    func stop() {
        generation += 1
        loop?.cancel()
        loop = nil
        sessionID = nil
        turns = []
        failed = false
        hasEarlier = false
    }

    func start(_ id: String, pane: SessionSidePaneModel,
               read: @escaping @Sendable () async -> CodexLocalSessionReader.SnapshotResult) {
        stop()
        sessionID = id
        let token = generation
        loop = Task { [weak self, weak pane] in
            while !Task.isCancelled {
                let result = await read()
                guard !Task.isCancelled, let self, let pane, self.generation == token else { return }
                switch result {
                case .snapshot(let snapshot):
                    self.turns = snapshot.turns
                    self.hasEarlier = snapshot.hasEarlier
                    self.failed = false
                    pane.tasks = snapshot.tasks
                    // Codex statuses are deliberately unknown; refresh an open tail independently.
                    await pane.tail?.readOnce()
                case .unreadable:
                    self.turns = []
                    self.failed = true
                    pane.returnToTree()
                    pane.tasks = BackgroundTaskList()
                }
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }
}

struct CodexSessionPanelView: View {
    @Bindable var shell: EdgeShellModel
    @Bindable var presentation: EdgeClaudeAppPanelPresentation
    @State private var openFailed = false
    private let reader = CodexLocalSessionReader()

    private var visibleID: String? { shell.codexPanelShown ? shell.codexPanelSession?.id : nil }

    var body: some View {
        SessionPanelFrame(pane: presentation.pane, reduceMotion: shell.reduceMotion,
                          root: shell.codexPanelSession.map { AgentTreeRoot(title: $0.title, agent: .codex) },
                          childComposer: { task in AnyView(openButton(id: task.id)) }) { width in
            VStack(spacing: 0) {
                if let session = shell.codexPanelSession {
                    PanelHeader(title: session.title, agent: .codex,
                                pill: PanelHeaderPill(title: "Open in Codex") { openInCodex(session.id) },
                                status: "Local session · Read only")
                        .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { presentation.headHeight = $0 }
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            if presentation.codex.sessionID == session.id {
                                if presentation.codex.failed {
                                    PanelEmptyState(title: "Couldn’t load this chat") {
                                        Button("Try again") { begin(session.id) }.buttonStyle(TFButtonStyle(.secondary, size: .md))
                                    }
                                } else {
                                    if presentation.codex.hasEarlier {
                                        Text("Showing recent messages. Open in Codex for the full conversation.")
                                            .font(TFFont.footnote).foregroundStyle(TFColor.textSecondary)
                                    }
                                    ForEach(presentation.codex.turns) { turn in ClaudeAppTurnView(turn: turn) }
                                }
                            }
                        }
                        .padding(TFSpace.lg)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { presentation.bodyHeight = $0 }
                    }
                    .defaultScrollAnchor(.bottom)
                    if openFailed { Text("Couldn’t open Codex.").font(TFFont.footnote).padding(TFSpace.lg) }
                }
            }
            .frame(width: width).frame(maxHeight: .infinity, alignment: .top)
        }
        .onChange(of: visibleID, initial: true) { _, id in
            presentation.reset()
            openFailed = false
            guard let id, SessionsPanelBody.readsLiveCodexSessions else { return }
            begin(id)
        }
    }

    private func begin(_ id: String) {
        let reader = reader
        presentation.beginSession("codex:" + id)
        presentation.pane.makeTail = { task in
            BackgroundTaskTailModel(taskID: task.id, limits: .init(tailBytes: 2 << 20, maxTailBytes: 2 << 20), read: { _ in reader.tail(sessionID: task.id, rootSessionID: id) })
        }
        presentation.codex.start(id, pane: presentation.pane) { await reader.snapshot(sessionID: id) }
    }

    private func openInCodex(_ id: String) {
        guard ExternalSessionRules.isCanonicalUUID(id), let url = URL(string: "codex://threads/\(id)") else { return }
        openFailed = !NSWorkspace.shared.open(url)
    }

    private func openButton(id: String) -> some View {
        VStack(spacing: TFSpace.sm) {
            if case .agent(_, let earlier) = presentation.pane.tail?.state, earlier {
                Text("Showing recent messages. Open in Codex for the full conversation.")
                    .font(TFFont.footnote).foregroundStyle(TFColor.textSecondary)
            }
            Button("Open in Codex") { openInCodex(id) }
                .buttonStyle(TFButtonStyle(.secondary, size: .md))
        }.padding(TFSpace.lg)
    }
}
#endif
