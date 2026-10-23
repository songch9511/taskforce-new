#if os(macOS) && DEBUG
import Foundation
import Testing
@testable import TaskforceKit

/// "On this Mac" 줄의 Resume here (OA 외부 세션 PR2m, 계약 8.2 · 8.3 · 17장): 어느 줄에 단추가 있고, 게이트 · 확인 상태가 줄을 어떻게 바꾸나. 순수 규칙이다
struct ExternalSessionAttachRulesTests {
    typealias F = ExternalSessionFixture
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func row(_ n: Int, status: ExternalSessionStatus = .available, client: ExternalSessionClient? = .terminal, folder: String? = "/Users/tester/proj") -> ExternalSessionRow {
        ExternalSessionRow(
            id: F.uuid(n), ref: String(repeating: "a", count: 64), title: "Session \(n)", folderPath: folder, groupPath: folder, lastActivity: now.addingTimeInterval(-3600),
            created: now.addingTimeInterval(-7200), client: client, status: status
        )
    }

    private func section(
        _ rows: [ExternalSessionRow], live: [String: ClaudeAppLiveStatus] = [:], attach: ExternalSessionAttachPresentation = .off
    ) -> [SessionsMacRow] {
        SessionsPanelRules.onThisMac(rows, live: { live[$0] }, now: now, expanded: true, attach: attach).rows
    }

    private func ready(_ phases: [String: ExternalSessionAttachModel.Phase] = [:]) -> ExternalSessionAttachPresentation {
        ExternalSessionAttachPresentation(gate: .ready, phases: phases)
    }

    // MARK: 단추

    @Test func anIdleRowGetsResumeHereWhenTheGateIsReady() throws {
        let result = try #require(section([row(1)], attach: ready()).first)
        #expect(result.line.action == .resumeHere && result.line.actionTitle == "Resume here")
        #expect(result.line.extraActions.isEmpty && result.line.statusWord == "Idle" && result.attach == nil)
    }

    @Test func anIdleDesktopRowKeepsOpenInClaudeOnlyForVoiceOver() throws {
        let result = try #require(section([row(1, client: .claudeDesktop)], attach: ready()).first)
        #expect(result.line.action == .resumeHere, "DZ: 눈에 보이는 단추는 Resume here 하나")
        #expect(result.line.extraActions == [.openInClaude], "Open in Claude는 VoiceOver 동작으로 남는다")
    }

    @Test func withoutTheGateNothingChanges() throws {
        for attach in [ExternalSessionAttachPresentation.off, ExternalSessionAttachPresentation(gate: .unavailable, phases: [:])] {
            let terminal = try #require(section([row(1)], attach: attach).first)
            #expect(terminal.line.action == nil && terminal.line.extraActions.isEmpty && terminal.attach == nil)
            let desktop = try #require(section([row(2, client: .claudeDesktop)], attach: attach).first)
            #expect(desktop.line.action == .openInClaude && desktop.line.statusWord == "Idle", "게이트가 없으면 이전 그대로")
        }
    }

    @Test func aTargetThatIsNotReadyShowsItsWordAndNeverResume() throws {
        let attach = ExternalSessionAttachPresentation(gate: .notReady(word: "Offline"), phases: [:])
        let terminal = try #require(section([row(1)], attach: attach).first)
        #expect(terminal.line.statusWord == "Offline" && !terminal.line.statusIsEmphasis && terminal.line.action == nil)
        #expect(terminal.line.detail.first == ExternalSessionLineText.timeLabel(now.addingTimeInterval(-3600), now: now), "시각은 그대로")
        let desktop = try #require(section([row(2, client: .claudeDesktop)], attach: attach).first)
        #expect(desktop.line.action == .openInClaude, "Open in Claude는 이어받기와 상관없이 그대로")
    }

    @Test func onlyIdleRowsOfferResumeAndEveryOtherStatusKeepsItsLine() throws {
        let statuses: [ExternalSessionStatus] = [.held(.claudeApp), .held(.terminal), .held(.background), .held(.unknown), .couldNotCheck, .cannotResume(.worktree), .cannotResume(.folderNotAllowed), .cannotResume(.unreadable), .cannotResume(.updateClaudeCode)]
        for (index, status) in statuses.enumerated() {
            let base = try #require(section([row(index + 1, status: status)], attach: .off).first)
            let with = try #require(section([row(index + 1, status: status)], attach: ready()).first)
            #expect(with.line == base.line, "\(status): 게이트가 줄을 바꾸지 않는다")
            #expect(with.line.action != .resumeHere)
        }
    }

    @Test func aRowWithoutAFolderOrWithALiveDesktopStatusGetsNoResume() throws {
        let noFolder = try #require(section([row(1, folder: nil)], attach: ready()).first)
        #expect(noFolder.line.action != .resumeHere)
        // Taskforce가 상태를 아는 살아 있는 데스크톱 줄은 이어받지 않는다 (그 세션에는 옆에서 말을 건다, 계약 21장)
        let live = try #require(section([row(2, status: .available, client: .claudeDesktop)], live: [F.uuid(2): .idle], attach: ready()).first)
        #expect(live.line.action == .openInClaude && live.opensSession)
    }

    // MARK: 제자리 확인

    @Test func aRowWithAConfirmationHidesItsButtonAndCarriesThePhase() throws {
        let id = F.uuid(1)
        for phase in [ExternalSessionAttachModel.Phase.confirming(note: nil), .confirming(note: "Close it in Claude first"), .working] {
            let result = try #require(section([row(1, client: .claudeDesktop), row(2)], attach: ready([id: phase])).first)
            #expect(result.id == id && result.attach == phase)
            #expect(result.line.action == nil && result.line.extraActions.isEmpty, "확인 중에는 줄의 버튼을 숨긴다 (확인 글자와 겹쳐 보이지 않게)")
        }
    }

    @Test func otherRowsKeepTheirButtonWhileOneRowIsConfirming() throws {
        let rows = section([row(1), row(2)], attach: ready([F.uuid(1): .confirming(note: nil)]))
        #expect(rows.map(\.line.action) == [nil, .resumeHere])
        #expect(rows.map(\.attach) == [.confirming(note: nil), nil])
    }

    @Test func aPhaseForARowThatIsNoLongerIdleIsIgnored() throws {
        let result = try #require(section([row(1, status: .held(.claudeApp))], attach: ready([F.uuid(1): .confirming(note: nil)])).first)
        #expect(result.attach == nil && result.line.statusWord == "Running in Claude", "열린 줄에는 확인이 없다")
    }

    @Test func theLineTextsStayTheApprovedOnes() {
        #expect(ExternalSessionLineContent(title: "t", statusWord: "Idle", statusIsEmphasis: false, detail: [], action: .resumeHere).actionTitle == "Resume here")
        var busy = ExternalSessionLineContent(title: "t", statusWord: "Idle", statusIsEmphasis: false, detail: [], action: .openInClaude)
        busy.isBusy = true
        #expect(busy.actionTitle == "Opening…")
        #expect(ExternalSessionLineContent(title: "t", statusWord: "Idle", statusIsEmphasis: false, detail: [], action: .openInClaude).actionTitle == "Open in Claude")
    }

    @Test func theSectionOrderAndFoldingAreUnchanged() {
        let rows = (1...6).map { row($0) }
        let base = SessionsPanelRules.onThisMac(rows, live: { _ in nil }, now: now, expanded: false)
        let with = SessionsPanelRules.onThisMac(rows, live: { _ in nil }, now: now, expanded: false, attach: ready())
        #expect(base.rows.map(\.id) == with.rows.map(\.id) && base.hiddenCount == with.hiddenCount && base.togglesFold == with.togglesFold)
    }
}
#endif
