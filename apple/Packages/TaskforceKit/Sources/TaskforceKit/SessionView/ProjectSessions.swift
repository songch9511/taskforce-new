#if os(macOS)
import Foundation

public enum ProjectSessions {
    public static let rereadInterval: TimeInterval = 30
    public static let treeRowWindow = 150

    public static func union(issueIDs: [UUID], in sessions: [AgentSessionItem]) -> [AgentSessionItem] {
        var seen: Set<UUID> = []
        return AgentSessionRules.listOrder(AgentSessionRules.sessions(of: Set(issueIDs), in: sessions)).filter { seen.insert($0.id).inserted }
    }

    public static func otherProjects(of session: AgentSessionItem, besides project: UUID, in work: [WorkItem]) -> [String] {
        let issues = Set(session.issueIDs)
        var projects: [UUID: WorkProject] = [:]
        for item in work where issues.contains(item.id) {
            for link in item.memberships.links where link.project.id != project && !link.project.isArchived {
                projects[link.project.id] = link.project
            }
        }
        return projects.values.sorted {
            let order = $0.name.localizedCaseInsensitiveCompare($1.name)
            return order == .orderedSame ? $0.id.uuidString < $1.id.uuidString : order == .orderedAscending
        }.map(\.name)
    }

    public static func runningSummary(_ list: BackgroundTaskList) -> String? {
        let count = list.tasks.filter { !$0.statusUnknown && $0.status == .running }.count
        return count > 0 ? "\(SessionViewCopy.running) \(count)" : nil
    }
    public static func shouldRead(lastReadAt: TimeInterval?, now: TimeInterval) -> Bool {
        lastReadAt.map { now - $0 >= rereadInterval } ?? true
    }
    public static func disclosureValue(isExpanded: Bool) -> String { isExpanded ? "Expanded" : "Collapsed" }
    public static func disclosureAction(isExpanded: Bool) -> String { isExpanded ? SessionViewCopy.showLess : SessionViewCopy.showAll }
    public static func visible(_ rows: [SubagentTreeRow], showsAll: Bool) -> (rows: [SubagentTreeRow], isCut: Bool) {
        (showsAll ? rows : Array(rows.prefix(treeRowWindow)), rows.count > treeRowWindow)
    }
}
#endif
