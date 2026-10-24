#if os(macOS)
import Foundation

/// A bounded snapshot through the same trusted reader as the conversation. No tail follower.
public enum ProjectSessionsTree {
    public static func read(source: any ClaudeAppTranscriptSource, sessionID: String, cwd: String?) -> BackgroundTaskList? {
        guard case .page(let page) = source.open(sessionID: sessionID, cwd: cwd) else { return nil }
        var descriptions: [String: String] = [:]
        var calls: [String: AgentCallRecord] = [:]
        for turn in page.turns {
            guard case .tool(let name, let description) = turn.kind, let id = turn.toolUseID else { continue }
            if let description, !description.isEmpty, descriptions[id] == nil { descriptions[id] = description }
            if (name == "Agent" || name == "Task"), BackgroundTaskText.isValidToolUseID(id) {
                var record = calls[id] ?? AgentCallRecord()
                record.called = true
                if record.startedAt == nil { record.startedAt = turn.timestamp }
                calls[id] = record
            }
        }
        for outcome in page.cursor.signals.toolOutcomes where calls[outcome.toolUseID]?.called == true {
            calls[outcome.toolUseID]?.outcome = AgentCallRecord.Outcome(failed: outcome.failed, at: outcome.at)
        }
        var list = BackgroundTaskList()
        for event in page.cursor.signals.background { list.apply(event) }
        list.resolveNames { descriptions[$0] }
        if case .metas(let metas, _) = source.subagents(sessionID: sessionID, cwd: cwd, since: nil) {
            // Result signals can precede an Agent call outside this window.
            let outcomes = Dictionary(page.cursor.signals.toolOutcomes.map { ($0.toolUseID, $0) }, uniquingKeysWith: { _, last in last })
            for meta in metas {
                guard let id = meta.toolUseID, calls[id]?.outcome == nil, let outcome = outcomes[id] else { continue }
                var record = calls[id] ?? AgentCallRecord()
                record.outcome = AgentCallRecord.Outcome(failed: outcome.failed, at: outcome.at)
                calls[id] = record
            }
            list = list.adding(subagents: metas, calls: calls)
        }
        return list
    }
}
#endif
