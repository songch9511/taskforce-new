#if os(macOS) && DEBUG
import Foundation
import Testing
@testable import TaskforceKit

/// 줄의 말 (DZ 승인 2026-10-21): 상태 말 · 이유 · 시각 · 출처, 제목 대체, 시각 서식
struct ExternalSessionLineTextTests {
    typealias F = ExternalSessionFixture
    static let utc = TimeZone(identifier: "UTC")!
    static let now = Date(timeIntervalSince1970: 1_792_400_000)  // 2026-10-19 (Mon) 08:53:20 UTC

    static func row(
        status: ExternalSessionStatus, client: ExternalSessionClient? = .terminal, title: String? = "Fix launcher focus", folder: String? = "/Users/tester/proj", ageMinutes: Double = 2
    ) -> ExternalSessionRow {
        ExternalSessionRow(
            id: F.uuid(1), ref: String(repeating: "a", count: 64), title: title, folderPath: folder, groupPath: folder, lastActivity: now.addingTimeInterval(-ageMinutes * 60),
            created: now.addingTimeInterval(-ageMinutes * 60), client: client, status: status
        )
    }

    private func line(_ row: ExternalSessionRow) -> ExternalSessionLineContent { ExternalSessionLineText.make(row, now: Self.now, timeZone: Self.utc) }

    @Test func runningRowsSayWhereAndOnlyTheClaudeAppOffersOpenInClaude() {
        let app = line(Self.row(status: .held(.claudeApp), client: .claudeDesktop))
        #expect(app.statusWord == "Running in Claude" && app.statusIsEmphasis && app.metaText == "Running in Claude · 2 min ago" && app.action == .openInClaude)
        let terminal = line(Self.row(status: .held(.terminal), ageMinutes: 0.2))
        #expect(terminal.metaText == "Running in Terminal · now" && terminal.action == nil)
        for holder in [ExternalSessionHolder.background, .unknown] {
            let elsewhere = line(Self.row(status: .held(holder), ageMinutes: 4))
            #expect(elsewhere.metaText == "Running elsewhere · 4 min ago" && elsewhere.action == nil, "동작도 거절 줄도 없다")
        }
    }

    @Test func anIdleRowSaysIdleTimeAndSourceWithoutEmphasis() {
        let desktop = line(Self.row(status: .available, client: .claudeDesktop, ageMinutes: 40))
        #expect(desktop.metaText == "Idle · 40 min ago · Claude desktop" && !desktop.statusIsEmphasis && desktop.action == nil)
        #expect(line(Self.row(status: .available, client: .terminal, ageMinutes: 180)).metaText == "Idle · 3 hr ago · Terminal")
        #expect(line(Self.row(status: .available, client: .other, ageMinutes: 180)).metaText == "Idle · 3 hr ago", "Claude · Terminal 밖 출처는 비워 둔다")
        #expect(line(Self.row(status: .available, client: nil, ageMinutes: 180)).metaText == "Idle · 3 hr ago")
    }

    @Test func blockedRowsPutTheReasonWhereTheSourceWouldBe() {
        let table: [(ExternalSessionBlock, String)] = [(.worktree, "Worktree"), (.folderNotAllowed, "Folder isn't allowed"), (.unreadable, "Unreadable"), (.updateClaudeCode, "Update Claude Code")]
        for (reason, text) in table {
            let blocked = line(Self.row(status: .cannotResume(reason), client: .claudeDesktop, ageMinutes: 120))
            #expect(blocked.metaText == "Can't resume here · \(text) · 2 hr ago" && blocked.statusIsEmphasis && blocked.action == nil, Comment(rawValue: text))
        }
    }

    @Test func aCouldNotCheckRowKeepsTimeAndSourceAndAnInTaskforceRowShowsTime() {
        #expect(line(Self.row(status: .couldNotCheck, client: .claudeDesktop, ageMinutes: 60)).metaText == "Couldn't check · 1 hr ago · Claude desktop")
        let taskforce = line(Self.row(status: .inTaskforce, ageMinutes: 120))
        #expect(taskforce.metaText == "In Taskforce · 2 hr ago" && !taskforce.statusIsEmphasis)
    }

    @Test func theTitleFallsBackToTheFolderNameThenUntitled() {
        #expect(line(Self.row(status: .available)).title == "Fix launcher focus")
        #expect(line(Self.row(status: .available, title: nil)).title == "proj")
        #expect(line(Self.row(status: .available, title: "", folder: "/Users/tester/notes")).title == "notes")
        #expect(line(Self.row(status: .cannotResume(.unreadable), title: nil, folder: nil)).title == "Untitled")
        #expect(line(Self.row(status: .available, title: nil, folder: "/")).title == "Untitled")
    }

    @Test func theAccessibilityNameIsTheTitleAndTheMetaLine() {
        #expect(line(Self.row(status: .held(.claudeApp), client: .claudeDesktop)).accessibilityName == "Fix launcher focus — Running in Claude · 2 min ago")
    }

    @Test func timeLabelsFollowTheApprovedForms() {
        let now = Self.now  // 2026-10-19 (Mon) 08:53 UTC
        func label(_ ago: TimeInterval) -> String { ExternalSessionLineText.timeLabel(now.addingTimeInterval(-ago), now: now, timeZone: Self.utc) }
        #expect(label(0) == "now" && label(59) == "now")
        #expect(label(60) == "1 min ago" && label(2 * 60) == "2 min ago" && label(59 * 60) == "59 min ago")
        #expect(label(3600) == "1 hr ago" && label(8 * 3600) == "8 hr ago")
        // 오늘 08:53 기준 9시간 전은 어제 23:53, 30시간 전은 어제 02:53 → 달력의 어제
        #expect(label(9 * 3600) == "Yesterday" && label(30 * 3600) == "Yesterday")
        #expect(label(50 * 3600) == "Sat", "그제 (토요일)부터는 어제가 아니라 요일")
        #expect(label(4 * 86400) == "Thu" && label(6 * 86400) == "Tue")
        #expect(label(7 * 86400) == "Oct 12" && label(30 * 86400) == "Sep 19")
        #expect(ExternalSessionLineText.timeLabel(now.addingTimeInterval(120), now: now, timeZone: Self.utc) == "now", "미래 시각도 방금")
    }

    @Test func groupsShowFourRowsUntilExpanded() {
        let rows = (1...6).map { n in
            ExternalSessionRow(id: F.uuid(n), ref: String(repeating: "a", count: 64), title: nil, folderPath: "/h/p", groupPath: "/h/p", lastActivity: Self.now.addingTimeInterval(-Double(n)), created: Self.now, client: nil, status: .available)
        }
        let group = ExternalSessionGroup(id: "/h/p", name: "p", rows: rows)
        #expect(ExternalSessionGrouping.visibleRows(group, expanded: false).map(\.id) == rows.prefix(4).map(\.id))
        #expect(ExternalSessionGrouping.visibleRows(group, expanded: true).count == 6)
        let small = ExternalSessionGroup(id: "x", name: nil, rows: Array(rows.prefix(4)))
        #expect(ExternalSessionGrouping.visibleRows(small, expanded: false).count == 4)
        #expect(ExternalSessionGrouping.visibleLimit == 4)
    }

    @Test func everyCopyStringIsTheApprovedOne() {
        let approved: [String] = [
            "On this Mac", "On this Mac — new sessions", "Running in Claude", "Running in Terminal", "Running elsewhere", "Couldn't check", "Can't resume here", "Idle", "In Taskforce", "Worktree",
            "Folder isn't allowed", "Unreadable", "Update Claude Code", "Claude desktop", "Terminal", "Untitled", "Open in Claude", "Show all", "Show less", "Checking…",
            "No recent Claude Code sessions", "Claude Code isn't installed", "Get Claude Code", "Couldn't check sessions", "Try again",
        ]
        let used: [String] = [
            ExternalSessionCopy.sectionTitle, ExternalSessionCopy.accessibilityNewSessions, ExternalSessionCopy.runningInClaude, ExternalSessionCopy.runningInTerminal,
            ExternalSessionCopy.runningElsewhere, ExternalSessionCopy.couldNotCheck, ExternalSessionCopy.cannotResume, ExternalSessionCopy.idle, ExternalSessionCopy.inTaskforce,
            ExternalSessionCopy.worktree, ExternalSessionCopy.folderNotAllowed, ExternalSessionCopy.unreadable, ExternalSessionCopy.updateClaudeCode, ExternalSessionCopy.claudeDesktop,
            ExternalSessionCopy.terminal, ExternalSessionCopy.untitled, ExternalSessionCopy.openInClaude, ExternalSessionCopy.showAll, ExternalSessionCopy.showLess, ExternalSessionCopy.checking,
            ExternalSessionCopy.empty, ExternalSessionCopy.notInstalled, ExternalSessionCopy.getClaudeCode, ExternalSessionCopy.couldNotCheckSessions, ExternalSessionCopy.tryAgain,
        ]
        #expect(used == approved)
    }
}
#endif
