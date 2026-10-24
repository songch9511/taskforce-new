#if os(macOS) && DEBUG
import AppKit
import TaskforceKit

/// Interactive native QA fixture. Requires sample data; uses disposable transcript files
/// through the production readers. No real account, provider, or user's Claude directory.
@MainActor
enum AgentTreeSample {
    static func runIfRequested(_ edge: EdgeShellController) {
        guard SampleData.isEnabled, ProcessInfo.processInfo.arguments.contains("-TFAgentTreeSample") else { return }
        Task {
            do {
                let root = try createTranscripts()
                let reader = ClaudeAppTranscriptReader(claudeDirectory: root.path)
                let tails = BackgroundTaskTail(claudeDirectory: root.path)
                edge.shell.makeConversation = { id, cwd in ClaudeAppConversation(sessionID: id, cwd: cwd, source: reader) }
                edge.chat?.localTranscriptTarget = { id in
                    guard id == IssueSnapshotData.session(1) else { return nil }
                    return AgentLocalTranscriptTarget(providerSessionID: ExternalSessionSnapshot.sessionID(1), cwd: "/Users/sample/taskforce")
                }
                edge.shell.makeBackgroundTail = { session, cwd, task in
                    BackgroundTaskTailModel(taskID: task.id, update: { window, cursor in
                        tails.update(sessionID: session, cwd: cwd, taskID: task.id, kind: task.kind, window: window, since: cursor)
                    })
                }
                if ProcessInfo.processInfo.arguments.contains("-TFSnapshotDark") {
                    NSApp.appearance = NSAppearance(named: .darkAqua)
                }
                edge.workOverride = { _ in IssueSnapshotData.snapshot(seeds: IssueSnapshotData.seeds.filter { !$0.review }) }
                ExternalSessionSnapshot.DesktopScript.shared.sessions = [1, 9].map { number in
                    ClaudeAppSession(id: ExternalSessionSnapshot.sessionID(number), pid: Int32(40_000 + number), cwd: "/Users/sample/taskforce", procStart: nil, state: .busy, statusUpdatedAt: Date())
                }
                try? await Task.sleep(for: .seconds(1))
                await edge.shell.externalSessions?.refresh()
                await edge.shell.desktop?.pollOnce()
                if ProcessInfo.processInfo.arguments.contains("-TFAgentTreeSampleTaskforce") {
                    // The interactive fixture accepts messages in memory, never through a provider.
                    edge.chat?.chat.assistant = SampleAssistantGateway()
                    edge.shell.openSessions()
                    edge.shell.openSessionRow(IssueSnapshotData.session(1))
                    try? await Task.sleep(for: .milliseconds(300))
                    edge.sessionPanel?.panel.makeKeyAndOrderFront(nil)
                } else {
                    let number = ProcessInfo.processInfo.arguments.contains("-TFAgentTreeSamplePlain") ? 9 : 1
                    edge.shell.openDesktopSession(ExternalSessionSnapshot.sessionID(number), from: .rail)
                }
                // Fixture storage contains only the generated sample, removed on normal exit.
                _ = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
                    try? FileManager.default.removeItem(at: root)
                }
            } catch {
                // Sample failures never print transcript contents or filesystem locations.
                print("Agent tree sample could not prepare its fixture.")
            }
        }
    }

    private static func createTranscripts() throws -> URL {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("taskforce-agent-tree-\(UUID().uuidString)")
        let project = root.appendingPathComponent("projects/-Users-sample-taskforce")
        let session = ExternalSessionSnapshot.sessionID(1)
        let agents = project.appendingPathComponent(session).appendingPathComponent("subagents")
        try fm.createDirectory(at: agents, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let now = Date()
        let date = ISO8601DateFormatter()
        func line(_ type: String, _ content: [[String: Any]], offset: Double = 0, extra: [String: Any] = [:]) -> [String: Any] {
            var value: [String: Any] = ["type": type, "sessionId": session, "uuid": UUID().uuidString, "timestamp": date.string(from: now.addingTimeInterval(offset)), "message": ["role": type, "content": content]]
            value.merge(extra) { _, new in new }
            return value
        }
        func write(_ values: [[String: Any]], to url: URL) throws {
            let data = try values.map { try JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys]) + Data([10]) }.reduce(Data(), +)
            try data.write(to: url)
        }
        let titles = ["Research pricing pages", "Write plan copy", "Review pricing copy", "Read competitor pricing", "Draft comparison table", "Check tone", "Check links"]
        let replies = [
            "Research complete. I compared the trial and annual pricing pages. The trial description needs one consistent duration.",
            "Draft in progress. I am rewriting the plan descriptions using the approved product terminology.",
            "Review found a blocker. The copy lint configuration is missing from this sample workspace.",
            "Competitor research complete. I recorded the pricing structures and linked each comparison to its source.",
            "Comparison table drafted. The table separates monthly billing, annual billing, and trial terms.",
            "Tone review complete. The draft uses concise, consistent language across each plan.",
            "Link check failed. The sample preview server was unavailable; no links were changed."
        ]
        var main: [[String: Any]] = [line("user", [["type": "text", "text": "Prepare the pricing copy draft with research, writing, and review."]], offset: -200)]
        for i in 0..<3 {
            main.append(line("assistant", [["type": "tool_use", "id": "tool-\(i)", "name": "Agent", "input": ["description": titles[i]]]], offset: -190 + Double(i)))
        }
        for i in [0, 2] {
            main.append(line("user", [["type": "tool_result", "tool_use_id": "tool-\(i)", "is_error": i == 2, "content": "Sample result"]], offset: -20,
                             extra: ["toolUseResult": ["agentId": "a\(i + 1)", "isAsync": false]]))
        }
        main.append(line("assistant", [["type": "text", "text": "The research is complete. Writing is in progress; review reported a configuration issue. Open each agent to inspect its conversation."]], offset: -10))
        try write(main, to: project.appendingPathComponent("\(session).jsonl"))
        for i in titles.indices {
            let id = "a\(i + 1)"
            var meta: [String: Any] = ["description": titles[i], "spawnDepth": i < 3 ? 1 : 2, "toolUseId": "tool-\(i)"]
            if i >= 3 { meta["parentAgentId"] = i < 5 ? "a1" : "a3" }
            try JSONSerialization.data(withJSONObject: meta).write(to: agents.appendingPathComponent("agent-\(id).meta.json"))
            try write([line("assistant", [["type": "text", "text": replies[i]]], extra: ["agentId": id])], to: agents.appendingPathComponent("agent-\(id).jsonl"))
        }
        let plain = ExternalSessionSnapshot.sessionID(9)
        try write([["type": "assistant", "sessionId": plain, "uuid": UUID().uuidString, "message": ["role": "assistant", "content": [["type": "text", "text": "This is the separate session without sub-agents. It opens directly in the conversation."]]]]], to: project.appendingPathComponent("\(plain).jsonl"))
        return root
    }
}
#endif
