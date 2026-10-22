#if os(macOS) && DEBUG
import Foundation
import Testing
@testable import TaskforceKit

extension ExternalSessionSuites {
    /// Sessions 패널의 줄 규칙 (OA PR-D2, DZ 승인 2026-10-22 `oa-rail-sessions-dz`): 출처별 두 절(Taskforce → On this Mac), 링 있는 줄은 Show all 밑으로 접지 않고
    /// 쉬는 줄 · 끝난 줄만 절마다 셋 뒤로 접는다. 줄의 말은 승인된 문구뿐이다 (새 문구: Sessions · Taskforce · Done · No sessions)
    struct SessionsPanelRulesTests {
        typealias F = ExternalSessionFixture
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        // MARK: Taskforce 절

        private func item(
            _ n: Int, ring: AgentSessionRing?, line: String? = nil, updated: TimeInterval = 60, issue: Int? = nil, closed: Bool = false, name: String? = nil,
            agent: AgentMarkKind = .claudeCode
        ) -> AgentSessionItem {
            let issueID = issue.map { SessionFx.issue($0) }
            return AgentSessionItem(
                id: SessionFx.id(n), name: name ?? "Session \(n)", agent: agent, agentName: agent.accessibilityName, connectionID: SessionFx.claudeConnection,
                status: closed ? .closed : .bound, ring: ring, line: line ?? (closed ? "" : (ring?.label ?? "")), createdAt: now.addingTimeInterval(-updated - 100), updatedAt: now.addingTimeInterval(-updated),
                issueIDs: issueID.map { [$0] } ?? [], currentIssueID: issueID, conversationID: nil, hasOpenTask: false, pill: nil
            )
        }

        private func taskforce(_ items: [AgentSessionItem], numbers: [UUID: Int] = [:], expanded: Bool = false) -> SessionsSection<SessionsTaskforceRow> {
            SessionsPanelRules.taskforce(items, issueNumber: { numbers[$0] }, now: now, expanded: expanded, timeZone: TimeZone(identifier: "UTC")!)
        }

        @Test func theNumbersAndCopyAreTheApprovedOnes() {
            #expect(SessionsPanelRules.foldLimit == 3, "쉬는 줄 · 끝난 줄은 셋 뒤에 Show all")
            #expect(SessionsPanelCopy.title == "Sessions" && SessionsPanelCopy.shortcut == "⌘4" && SessionsPanelCopy.taskforce == "Taskforce")
            #expect(SessionsPanelCopy.onThisMac == "On this Mac" && SessionsPanelCopy.noSessions == "No sessions")
            #expect(SessionsPanelCopy.done == "Done" && AgentSessionRules.done == "Done")
        }

        @Test func taskforceRowsAreRingsFirstThenIdleThenClosedAndNewestFirstInsideAGroup() {
            let items = [
                item(1, ring: .idle, updated: 600), item(2, ring: .running, updated: 100), item(3, ring: .needsYou, updated: 5000), item(4, ring: nil, updated: 10, closed: true),
                item(5, ring: .done, updated: 200), item(6, ring: .idle, updated: 300), item(7, ring: .running, updated: 50), item(8, ring: .unreachable, updated: 700),
                item(9, ring: .waiting, updated: 20), item(10, ring: .stopping, updated: 30),
            ]
            let ids = taskforce(items, expanded: true).rows.map(\.id)
            // needs-you → running · stopping · unreachable(같은 묶음, 새것 먼저) → done → waiting → 쉬는 줄(새것 먼저) → 끝난 줄
            #expect(ids == [3, 10, 7, 2, 8, 5, 9, 6, 1, 4].map { SessionFx.id($0) })
        }

        @Test func aTaskforceRowSaysStatusTimeAndIssueNumberAndAClosedOneOnlyTimeAndNumber() {
            let rows = taskforce(
                [item(1, ring: .needsYou, updated: 180, issue: 9), item(2, ring: .done, line: AgentSessionRules.done, updated: 2400, issue: 11), item(3, ring: .idle, line: "Idle", updated: 3 * 3600, issue: 12),
                 item(4, ring: nil, updated: 86_400 + 600, issue: 8, closed: true), item(5, ring: .running, line: "Running", updated: 30)],
                numbers: [SessionFx.issue(9): 9, SessionFx.issue(11): 11, SessionFx.issue(12): 12, SessionFx.issue(8): 8], expanded: true
            ).rows
            let byID = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
            #expect(byID[SessionFx.id(1)]?.metaText == "Needs your answer · 3 min ago · #9")
            #expect(byID[SessionFx.id(2)]?.metaText == "Done · 40 min ago · #11")
            #expect(byID[SessionFx.id(3)]?.metaText == "Idle · 3 hr ago · #12")
            #expect(byID[SessionFx.id(4)]?.metaText == "Yesterday · #8", "끝난 줄은 상태 말 없이 시각 · 번호만")
            #expect(byID[SessionFx.id(5)]?.metaText == "Running · now", "이슈 번호를 모르면 번호 없이 (지어내지 않는다)")
            #expect(byID[SessionFx.id(4)]?.isClosed == true && byID[SessionFx.id(4)]?.ring == nil)
            #expect(byID[SessionFx.id(2)]?.ring == .done)
        }

        @Test func theRowNamesTheAgentAndKeepsTheAccessibilityNameOfASessionRow() {
            let row = taskforce([item(1, ring: .running, line: "Running", issue: 12, name: "Pricing copy draft", agent: .codex)], numbers: [SessionFx.issue(12): 12], expanded: true).rows[0]
            #expect(row.agent == .codex && row.name == "Pricing copy draft")
            #expect(row.accessibilityName == "Pricing copy draft — Codex — Running · 1 min ago · #12")
            let closed = taskforce([item(2, ring: nil, issue: 8, closed: true, name: "Spike")], numbers: [SessionFx.issue(8): 8], expanded: true).rows[0]
            #expect(closed.accessibilityName == "Spike — Claude Code — 1 min ago · #8")
        }

        @Test func ringRowsAreNeverFoldedAndQuietRowsFoldAfterThree() {
            var items = (1...6).map { item($0, ring: .running, line: "Running", updated: Double($0)) }
            items += (10...15).map { item($0, ring: .idle, line: "Idle", updated: Double($0) * 100) }
            items += [item(20, ring: nil, closed: true), item(21, ring: .done, line: "Done")]
            let folded = taskforce(items)
            #expect(folded.rows.filter { $0.ring != nil && $0.ring != .idle }.count == 7, "링이 있는 줄(주황 · 도는 중 · 끝)은 일곱 모두 보인다")
            #expect(folded.rows.filter { $0.ring == .idle || $0.isClosed }.count == 3, "쉬는 줄 · 끝난 줄은 셋까지")
            #expect(folded.hiddenCount == 4 && folded.togglesFold && !folded.expanded)
            let open = taskforce(items, expanded: true)
            #expect(open.rows.count == items.count && open.hiddenCount == 0 && open.togglesFold && open.expanded, "펼치면 Show less")
        }

        @Test func aSectionWithThreeOrFewerQuietRowsHasNoShowAll() {
            let items = [item(1, ring: .running, line: "Running"), item(2, ring: .idle, line: "Idle"), item(3, ring: .idle, line: "Idle"), item(4, ring: nil, closed: true)]
            let section = taskforce(items)
            #expect(section.rows.count == 4 && section.hiddenCount == 0 && !section.togglesFold)
            #expect(taskforce([]).rows.isEmpty && taskforce([]).isEmpty)
        }

        // MARK: On this Mac 절

        private func mac(
            _ n: Int, status: ExternalSessionStatus = .available, client: ExternalSessionClient? = .terminal, minutes: Double = 60, title: String? = nil
        ) -> ExternalSessionRow {
            ExternalSessionRow(
                id: F.uuid(0x7000 + n), ref: String(repeating: "c", count: 64), title: title ?? "Mac \(n)", folderPath: "/Users/tester/proj", groupPath: "/Users/tester/proj",
                lastActivity: now.addingTimeInterval(-minutes * 60), created: now.addingTimeInterval(-minutes * 60), client: client, status: status
            )
        }

        private func section(
            _ rows: [ExternalSessionRow], live: [Int: ClaudeAppLiveStatus] = [:], expanded: Bool = false, notice: Int? = nil, busy: Set<Int> = []
        ) -> SessionsSection<SessionsMacRow> {
            let liveByID = Dictionary(uniqueKeysWithValues: live.map { (F.uuid(0x7000 + $0.key), $0.value) })
            return SessionsPanelRules.onThisMac(
                rows, live: { liveByID[$0] }, now: now, expanded: expanded, notice: notice.map { (F.uuid(0x7000 + $0), "Running in Terminal") },
                busy: Set(busy.map { F.uuid(0x7000 + $0) }), timeZone: TimeZone(identifier: "UTC")!
            )
        }

        @Test func rowsThatTaskforceAlreadyOwnsAreNotListedTwice() {
            let rows = [mac(1, status: .inTaskforce), mac(2, status: .available)]
            #expect(section(rows, expanded: true).rows.map(\.id) == [F.uuid(0x7002)], "이어받은 세션은 Taskforce 절에만 나온다")
        }

        @Test func aLiveDesktopRowSaysItsStateWithARingAndOpensTheSessionView() {
            let rows = [
                mac(1, status: .held(.claudeApp), client: .claudeDesktop, minutes: 2), mac(2, status: .held(.claudeApp), client: .claudeDesktop, minutes: 1),
                mac(3, status: .held(.claudeApp), client: .claudeDesktop, minutes: 6), mac(4, status: .held(.claudeApp), client: .claudeDesktop, minutes: 12), mac(5, status: .held(.claudeApp), client: .claudeDesktop, minutes: 3),
            ]
            let result = section(rows, live: [1: .running, 2: .needsApproval, 3: .done, 4: .idle, 5: .needsAnswer], expanded: true).rows
            let byID = Dictionary(uniqueKeysWithValues: result.map { ($0.id, $0) })
            func row(_ n: Int) -> SessionsMacRow { byID[F.uuid(0x7000 + n)]! }
            #expect(row(1).line.metaText == "Running in Claude · 2 min ago" && row(1).line.statusIsEmphasis && row(1).ring == .running)
            #expect(row(2).line.metaText == "Needs approval in Claude · 1 min ago" && !row(2).line.statusIsEmphasis && row(2).ring == .needsYou)
            #expect(row(5).line.metaText == "Needs your answer in Claude · 3 min ago" && row(5).ring == .needsYou)
            #expect(row(3).line.metaText == "Done · 6 min ago · Claude desktop" && row(3).ring == .done)
            #expect(row(4).line.metaText == "Idle · 12 min ago · Claude desktop" && row(4).ring == .idle)
            for n in 1...5 {
                #expect(row(n).opensSession && row(n).line.action == .openInClaude, "살아 있는 데스크톱 줄은 누르면 보기가 열리고 Open in Claude가 있다")
            }
        }

        @Test func aRowWithoutALiveStatusKeepsTheApprovedLineAndHasNoRingAndOpensNothing() {
            let rows = [
                mac(1, status: .held(.terminal)), mac(2, status: .held(.claudeApp), client: .claudeDesktop), mac(3, status: .available, client: .claudeDesktop), mac(4, status: .cannotResume(.worktree)),
                mac(5, status: .couldNotCheck, client: .claudeDesktop),
            ]
            let result = section(rows, expanded: true).rows
            #expect(result.map(\.ring) == [nil, nil, nil, nil, nil])
            #expect(result.map(\.opensSession) == [false, false, false, false, false])
            #expect(result[0].line.metaText == "Running in Terminal · 1 hr ago")
            #expect(result[1].line.metaText == "Running in Claude · 1 hr ago", "Taskforce가 상태를 모르면(등록이 믿을 수 없다) 앞 승인 그대로")
            #expect(result[2].line.metaText == "Idle · 1 hr ago · Claude desktop" && result[2].line.action == .openInClaude)
            #expect(result[3].line.metaText == "Can't resume here · Worktree · 1 hr ago")
            #expect(result[4].line.metaText == "Couldn't check · 1 hr ago · Claude desktop")
        }

        @Test func ringRowsComeFirstInRailOrderAndTheRestKeepTheScannersOrder() {
            let rows = (1...8).map { mac($0, status: $0 <= 6 ? .held(.claudeApp) : .available, client: .claudeDesktop, minutes: Double($0)) }
            let live: [Int: ClaudeAppLiveStatus] = [1: .idle, 2: .done, 3: .running, 4: .needsApproval, 5: .running, 6: .idle]
            let ids = section(rows, live: live, expanded: true).rows.map(\.id)
            // needs-you → running(새것 먼저) → done → 나머지(스캐너 순서)
            #expect(ids == [4, 3, 5, 2, 1, 6, 7, 8].map { F.uuid(0x7000 + $0) })
        }

        @Test func ringRowsAreNeverFoldedAndTheRestFoldAfterThree() {
            var rows = (1...5).map { mac($0, status: .held(.claudeApp), client: .claudeDesktop) }
            rows += (10...16).map { mac($0, status: .available) }
            let live: [Int: ClaudeAppLiveStatus] = [1: .running, 2: .running, 3: .needsApproval, 4: .done, 5: .idle]
            let folded = section(rows, live: live)
            #expect(folded.rows.filter { [.running, .needsYou, .done].contains($0.ring) }.count == 4, "주황 · 도는 중 · 끝은 접지 않는다")
            #expect(folded.rows.count == 4 + 3 && folded.hiddenCount == 1 + 7 - 3 && folded.togglesFold, "나머지(쉬는 데스크톱 줄 포함 여덟)는 셋까지")
            #expect(section(rows, live: live, expanded: true).rows.count == rows.count)
        }

        @Test func theOpenNoticeAndTheBusyButtonReachTheRowLines() {
            let rows = [mac(1, status: .available, client: .claudeDesktop), mac(2, status: .held(.claudeApp), client: .claudeDesktop)]
            let result = section(rows, live: [2: .idle], expanded: true, notice: 1, busy: [2]).rows
            #expect(result[0].line.statusWord == "Running in Terminal" && !result[0].line.statusIsEmphasis, "다른 터미널에 열려 있다고 막힌 쉬는 줄의 회색 한 줄")
            #expect(result[1].line.isBusy && result[1].line.actionTitle == "Opening…")
        }

        @Test func theEmptyStateIsOnlyWhenBothSectionsAreEmpty() {
            #expect(SessionsPanelRules.isEmpty(taskforce: taskforce([]), mac: section([])))
            #expect(!SessionsPanelRules.isEmpty(taskforce: taskforce([item(1, ring: .idle, line: "Idle")]), mac: section([])))
            #expect(!SessionsPanelRules.isEmpty(taskforce: taskforce([]), mac: section([mac(1)])))
        }

        @Test func theRowsPrintNoTitleOrID() {
            let row = section([mac(1, title: "SENTINEL-TITLE")], expanded: true).rows[0]
            let tf = taskforce([item(1, ring: .idle, line: "Idle", name: "SENTINEL-NAME")], expanded: true).rows[0]
            for value in [String(describing: row), String(reflecting: row), String(describing: tf), String(reflecting: tf)] {
                #expect(!value.contains("SENTINEL") && !value.contains(F.uuid(0x7001)) && !value.contains(SessionFx.id(1).uuidString), "\(value)")
            }
        }
    }
}
#endif
