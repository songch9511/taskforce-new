import AppKit
import AuthenticationServices
import Auth
import Carbon.HIToolbox
import Foundation
import Supabase
import SwiftUI
import Testing
@testable import Taskforce
@testable import TaskforceKit

/// Mac 런처 셸 (U1 PR4): 범위 · 펼침 · seen · 저장본 · 오프라인(M20) · 키
@Suite(.serialized)
@MainActor
struct LauncherShellModelTests {
    @Test func consentSuccessResumesPendingProvider() async throws {
        let harness = try await ShellHarness.make(now: ShellNow.body())
        let account = try #require(harness.model.account)
        await account.connect(.notion, using: EnvironmentValues().webAuthenticationSession)
        #expect(account.pendingProvider == .notion)
        #expect(account.showsConsent)

        await account.giveConsent()

        #expect(await harness.router.consentRequests() == 1)
        #expect(account.hasConsent)
        #expect(account.resumeProvider == .notion)
        #expect(account.pendingProvider == nil)
        #expect(!account.showsConsent)
        #expect(account.message == nil)
    }

    @Test(arguments: [400, 404])
    func consentFailureKeepsPendingProviderAndShowsError(status: Int) async throws {
        let harness = try await ShellHarness.make(now: ShellNow.body())
        let account = try #require(harness.model.account)
        await harness.router.setConsentStatus(status)
        await account.connect(.notion, using: EnvironmentValues().webAuthenticationSession)
        #expect(account.pendingProvider == .notion)

        await account.giveConsent()

        #expect(await harness.router.consentRequests() == 1)
        #expect(!account.hasConsent)
        #expect(account.resumeProvider == nil)
        #expect(account.pendingProvider == .notion)
        #expect(account.showsConsent)
        #expect(account.message == APIError.server(status: status, code: status == 404 ? .notFound : .invalidRequest, message: "Consent unavailable").userMessage)
    }

    @Test(arguments: [400, 404])
    func consentFailureDoesNotRetryBlockedHandoff(status: Int) async throws {
        let harness = try await ShellHarness.make(now: ShellNow.body())
        let account = try #require(harness.model.account)
        await harness.router.setConsentStatus(status)
        await account.handleCallback(URL(string: "taskforce://connections/notion?handoff=test-handoff")!)
        #expect(account.showsConsent)
        #expect(await harness.router.completeRequests() == 1)

        await account.giveConsent()

        #expect(!account.hasConsent)
        #expect(account.resumeProvider == nil)
        #expect(account.showsConsent)
        #expect(account.message != nil)
        #expect(await harness.router.completeRequests() == 1)
    }

    @Test(arguments: [204, 400, 404], [false, true])
    func lateConsentDoesNotChangeAccount(status: Int, changesAccount: Bool) async throws {
        let harness = try await ShellHarness.make(now: ShellNow.body())
        let account = try #require(harness.model.account)
        await account.connect(.notion, using: EnvironmentValues().webAuthenticationSession)
        await harness.router.setConsentStatus(status)
        await harness.router.holdConsent()
        let consent = Task { await account.giveConsent() }
        await harness.waitUntil { await harness.router.hasPendingConsent() }

        if changesAccount {
            harness.session.apply(event: .signedIn, session: shellSession(userID: UUID()))
        } else {
            harness.session.apply(event: .signedOut, session: nil)
        }
        harness.model.sessionChanged()
        account.message = "Current account message"
        await harness.router.releaseConsent()
        await consent.value

        #expect(!account.hasConsent)
        #expect(account.resumeProvider == nil)
        #expect(account.pendingProvider == nil)
        #expect(!account.showsConsent)
        #expect(account.message == "Current account message")
        #expect(await harness.router.completeRequests() == 0)
    }

    @Test(arguments: [400, 404])
    func unavailableProviderStartStillShowsComingSoon(status: Int) async throws {
        let harness = try await ShellHarness.make(now: ShellNow.body())
        let account = try #require(harness.model.account)
        await harness.router.setStartStatus(status)

        await account.connect(.notion, using: EnvironmentValues().webAuthenticationSession)

        #expect(account.comingSoon == [.notion])
        #expect(account.message == nil)
        #expect(!account.hasConsent)
        #expect(!account.showsConsent)
        #expect(account.connecting == nil)
    }

    /// 범위를 바꿔도 고르던 행이 새 목록에 있으면 그 행, 없으면 같은 자리 (`reselect`), 패널에서 돌아오면 본 행 (`rowAfterBack`)
    @Test func scopeKeepsTheSelectionRules() async throws {
        let harness = try await ShellHarness.make(now: ShellNow.body(reviews: ["R1"], toDo: ["T1", "T2"]))
        let model = harness.model
        let t2 = try #require(model.items.firstIndex { $0.action?.title == "T2" })
        model.select(t2)

        model.chooseScope(.toDo)
        #expect(model.scope == .toDo)
        #expect(model.selectedItem?.action?.title == "T2")
        #expect(model.items.allSatisfy { $0.group == .toDo })

        // T2가 없는 범위: 같은 자리 (끝을 넘지 않게)
        model.chooseScope(.review)
        #expect(model.selectedItem?.action?.title == "R1")

        // ⌘K 패널에서 돌아오면 본 할 일의 행
        model.chooseScope(.allTasks)
        let t1 = try #require(model.items.firstIndex { $0.action?.title == "T1" })
        model.select(t1)
        model.openActions()
        #expect(model.screen.isActions)
        model.back()
        #expect(model.screen == .list)
        #expect(model.selectedItem?.action?.title == "T1")
    }

    /// `Show N More` 줄에서 ↩: 그 섹션을 펼치고 처음 드러난 행을 고른다
    @Test func returnOnShowMoreExpands() async throws {
        let harness = try await ShellHarness.make(
            now: ShellNow.body(toDo: ["T1", "T2", "T3", "T4", "T5", "T6", "T7"]),
            displayPreferences: SectionDisplayPreferences(toDo: .five)
        )
        let model = harness.model
        let more = try #require(model.items.firstIndex { if case .showMore(.toDo, 2) = $0 { true } else { false } })
        model.select(more)
        #expect(model.handleKey(.key(kVK_Return)))
        #expect(!model.items.contains { if case .showMore(.toDo, _) = $0 { true } else { false } })
        #expect(model.items.compactMap(\.action?.title) == ["T1", "T2", "T3", "T4", "T5", "T6", "T7"])
        #expect(model.selectedItem?.action?.title == "T6")
    }

    /// Local section preferences default to All, override server limits, and reload on the next show.
    @Test func sectionPreferencesOverrideServerLimitsAndReloadOnShow() async throws {
        let reviews = ["R1", "R2", "R3", "R4", "R5", "R6"]
        let tasks = ["T1", "T2", "T3", "T4", "T5", "T6"]
        let harness = try await ShellHarness.make(now: ShellNow.body(reviews: reviews, toDo: tasks, limits: (1, 1, 1)))
        let model = harness.model

        #expect(model.items.compactMap(\.action?.title) == reviews + tasks)
        #expect(!model.items.contains { if case .showMore = $0 { true } else { false } })

        SectionDisplayPreferences(review: .five, toDo: .five).save(to: harness.displayPreferencesDefaults)
        model.prepareForShow()

        #expect(model.items.contains { if case .showMore(.review, 1) = $0 { true } else { false } })
        #expect(model.items.contains { if case .showMore(.toDo, 1) = $0 { true } else { false } })
    }

    /// A live insertion or reorder keeps the highlighted row aligned with the open detail and Confirm target.
    @Test func detailSelectionTracksLiveInsertionAndReordering() async throws {
        let harness = try await ShellHarness.make(now: ShellNow.body(reviews: ["A", "B", "C"]))
        let model = harness.model
        let target = try #require(model.items.first { $0.action?.title == "A" })
        let targetID = try #require(target.action?.id)
        model.openDetail(for: target)

        let now = try #require(model.now)
        await harness.router.setNow(ShellNow.body(reviews: ["X", "A", "B", "C"]))
        await now.load()
        #expect(model.screen.isDetail)
        #expect(model.selection == 1)
        #expect(model.selectedItem?.action?.id == targetID)
        #expect(model.detailTarget?.action.id == targetID)

        await harness.router.setNow(ShellNow.body(reviews: ["C", "B", "X", "A"]))
        await now.load()
        #expect(model.screen.isDetail)
        #expect(model.selection == 3)
        #expect(model.selectedItem?.action?.id == targetID)
        #expect(model.detailTarget?.action.id == targetID)

        #expect(model.handleKey(.key(kVK_Return, command: true)))
        await harness.waitUntil { await harness.router.confirmRequests() == 1 && model.screen == .list }
        #expect(await harness.router.confirmIDs() == [targetID])
    }

    /// A missing detail target closes with no row selected, so Return cannot confirm its former neighbor.
    @Test func removingDetailTargetClosesWithoutSelectingAnotherReview() async throws {
        let harness = try await ShellHarness.make(now: ShellNow.body(reviews: ["A", "B"]))
        let model = harness.model
        model.openDetail(for: try #require(model.items.first { $0.action?.title == "A" }))
        let now = try #require(model.now)
        await harness.router.setNow(ShellNow.body(reviews: ["B"]))
        await now.load()

        #expect(model.screen == .list)
        #expect(model.selectedItem == nil)
        #expect(model.primaryAction == nil)
        #expect(!model.canConfirmReview)
        #expect(model.handleKey(.key(kVK_Return, command: true)))
        #expect(await harness.router.confirmRequests() == 0)
    }

    /// A new per-section cap expands just enough to keep the open target visible and selected.
    @Test func applyingSectionCapKeepsDetailTargetVisible() async throws {
        let reviews = (1...7).map { "R\($0)" }
        let harness = try await ShellHarness.make(now: ShellNow.body(reviews: reviews))
        let model = harness.model
        let target = try #require(model.items.first { $0.action?.title == "R7" })
        let targetID = try #require(target.action?.id)
        model.openDetail(for: target)

        let preferences = SectionDisplayPreferences(review: .five)
        preferences.save(to: harness.displayPreferencesDefaults)
        model.applySectionDisplayPreferences(preferences)

        #expect(model.screen.isDetail)
        #expect(model.selectedItem?.action?.id == targetID)
        #expect(model.detailTarget?.action.id == targetID)
        #expect(!model.items.contains { if case .showMore(.review, _) = $0 { true } else { false } })
    }

    /// A live group change retains the stale-target guard: the old Review detail cannot confirm the moved task.
    @Test func groupChangeMakesOpenReviewDetailStale() async throws {
        let harness = try await ShellHarness.make(now: ShellNow.body(reviews: ["R1", "R2"]))
        let model = harness.model
        let target = try #require(model.items.first { $0.action?.title == "R1" })
        let targetID = try #require(target.action?.id)
        model.openDetail(for: target)

        let now = try #require(model.now)
        await harness.router.setNow(ShellNow.body(reviews: ["R2"], toDo: ["R1"]))
        await now.load()
        #expect(model.screen.isDetail)
        #expect(model.selectedItem?.action?.id == targetID)
        #expect(model.detailTarget?.group == .toDo)
        #expect(!model.canConfirmReview)

        model.performPrimary()
        #expect(model.screen == .list)
        #expect(model.selectedItem?.action?.id == targetID)
        #expect(await harness.router.confirmRequests() == 0)
    }

    /// 바뀐 행을 골랐다가 떠나면 seen 한 번. 다시 와서 떠나도 다시 보내지 않고, 점은 바로 지운다
    @Test func seenIsSentOnceWhenLeavingAChangedRow() async throws {
        let harness = try await ShellHarness.make(now: ShellNow.body(toDo: ["T1", "T2"], changed: ["T1"]))
        let model = harness.model
        model.prepareForShow()
        // 연 뒤의 다시 불러오기가 끝난 뒤에 시작한다 (새 `/now`는 보낸 기록을 비운다)
        await harness.waitUntil { await harness.router.nowRequests() >= 2 }
        try await Task.sleep(for: .milliseconds(100))
        let t1 = try #require(model.items.first { $0.action?.title == "T1" }?.action?.id)
        #expect(model.showsDot(t1))
        model.select(0)
        model.syncSeen()
        #expect(await harness.router.seenIDs().isEmpty)

        model.move(1)
        model.syncSeen()
        await harness.waitUntil { await harness.router.seenIDs() == [t1] }
        #expect(!model.showsDot(t1))

        model.move(-1)
        model.syncSeen()
        model.move(1)
        model.syncSeen()
        model.didHide()
        try await Task.sleep(for: .milliseconds(100))
        #expect(await harness.router.seenIDs() == [t1])
    }

    /// 새 `/now`로 고른 행 위에 바뀐 행이 끼어들어도, 그 자리의 다른 행(본 적 없는 행)에 seen을 보내지 않는다 (리뷰 B1)
    @Test func refreshKeepsSeenOnTheSelectedRowWhenRowsShift() async throws {
        let harness = try await ShellHarness.make(now: ShellNow.body(toDo: ["A", "X"], changed: ["X"]))
        let model = harness.model
        model.prepareForShow()
        await harness.waitUntil { await harness.router.nowRequests() >= 2 }
        try await Task.sleep(for: .milliseconds(100))
        let x = try #require(model.items.first { $0.action?.title == "X" }?.action?.id)
        model.select(1)
        model.syncSeen()

        // 바뀐 C가 X 자리(1)에 끼어든다
        await harness.router.setNow(ShellNow.body(toDo: ["A", "C", "X"], changed: ["C", "X"]))
        let now = try #require(model.now)
        await now.load()
        // 화면이 하는 일: 목록이 바뀌면 다시 맞추고, 고른 할 일을 따라 seen
        model.reconcileSelection()
        model.syncSeen()
        #expect(model.selectedItem?.action?.id == x)
        #expect(await harness.router.seenIDs().isEmpty)

        // X를 떠나면 X만
        model.move(-1)
        model.syncSeen()
        await harness.waitUntil { await harness.router.seenIDs() == [x] }
        try await Task.sleep(for: .milliseconds(100))
        #expect(await harness.router.seenIDs() == [x])
    }

    /// 이번 실행에서 받은 목록도 저장본도 없이 오프라인이면 M20, 연결이 돌아오면 목록을 다시 불러온다
    @Test func offlineWithoutSavedCopyShowsM20ThenReloadsOnReconnect() async throws {
        let harness = try await ShellHarness.make(now: nil)
        let model = harness.model
        #expect(model.now?.response == nil)
        #expect(model.savedList == nil)

        harness.connectivity.yield(false)
        await harness.waitUntil { model.refreshState.isOffline }
        #expect(model.bodyState == .offlineEmpty)
        #expect(model.statusText?.hasPrefix("Offline since ") == true)
        #expect(!model.showsSavedTasks)

        await harness.router.setNow(ShellNow.body(toDo: ["T1"]))
        harness.connectivity.yield(true)
        await harness.waitUntil { model.now?.response != nil }
        #expect(model.bodyState == .list)
        #expect(model.statusText == nil)
    }

    /// ⌘R: 다시 불러온다 (M19 `Try Again`)
    @Test func commandRReloads() async throws {
        let harness = try await ShellHarness.make(now: nil)
        let model = harness.model
        #expect(model.secondaryAction == LauncherModel.BarAction(title: "Try Again", keys: "⌘R"))
        let before = await harness.router.nowRequests()
        #expect(model.handleKey(.key(kVK_ANSI_R, command: true)))
        await harness.waitUntil { await harness.router.nowRequests() > before }
    }

    /// esc는 범위 메뉴가 열려 있으면 메뉴만 닫는다. 그다음 esc는 지금처럼 런처를 닫는다
    @Test func escapeClosesTheScopeMenuFirst() async throws {
        let harness = try await ShellHarness.make(now: ShellNow.body(toDo: ["T1"]))
        let model = harness.model
        var closed = false
        model.close = { closed = true }
        #expect(model.handleKey(.key(kVK_ANSI_P, command: true)))
        #expect(model.scopeMenuSelection == 0)
        #expect(model.handleKey(.key(kVK_DownArrow)))
        #expect(model.scopeMenuSelection == 1)
        #expect(model.handleKey(.key(kVK_Escape)))
        #expect(model.scopeMenuSelection == nil)
        #expect(model.scope == .allTasks)
        #expect(!closed)
        #expect(model.handleKey(.key(kVK_Escape)))
        #expect(closed)
    }

    /// 범위 메뉴에서 ↩: 고른 범위로
    @Test func returnInTheScopeMenuChoosesTheScope() async throws {
        let harness = try await ShellHarness.make(now: ShellNow.body(reviews: ["R1"], toDo: ["T1"]))
        let model = harness.model
        model.toggleScopeMenu()
        model.selectScopeMenuRow(model.scopeChoices.firstIndex(of: .toDo) ?? 0)
        #expect(model.primaryAction == LauncherModel.BarAction(title: "Show To Do", keys: "↩"))
        #expect(model.handleKey(.key(kVK_Return)))
        #expect(model.scope == .toDo)
        #expect(model.scopeMenuSelection == nil)
        #expect(model.count(for: .allTasks) == 2)
    }

    /// Selecting a task does not start its run watch; Return opens inline details.
    @Test func returnOnATaskOpensDetailsWithoutStartingItsRun() async throws {
        let harness = try await ShellHarness.make(now: ShellNow.body(toDo: ["T1"]))
        let model = harness.model
        model.prepareForShow()
        let taskID = try #require(model.selectedItem?.action?.id)
        #expect(model.runSubject == nil)
        model.select(0)
        #expect(model.handleKey(.key(kVK_Return)))
        #expect(model.screen.isDetail)
        #expect(model.detailTarget?.action.id == taskID)
        #expect(model.runSubject == taskID)
    }

    /// Plain Return and key repeat only open Review details; the action bar Confirm sends one request.
    @Test func reviewReturnRepeatNeverConfirmsAndPrimaryConfirmsOnce() async throws {
        let harness = try await ShellHarness.make(now: ShellNow.body(reviews: ["R1"]))
        let model = harness.model
        var closeCount = 0
        model.close = { closeCount += 1 }

        #expect(model.primaryAction == LauncherModel.BarAction(title: "Confirm", keys: "⌘↩"))
        #expect(model.secondaryAction == LauncherModel.BarAction(title: "Dismiss", keys: "⌘⌫"))
        #expect(model.handleKey(.key(kVK_Return, isRepeat: true)))
        #expect(await harness.router.confirmRequests() == 0)
        #expect(model.screen == .list)

        #expect(model.handleKey(.key(kVK_Return)))
        #expect(model.screen.isDetail)
        #expect(await harness.router.confirmRequests() == 0)
        #expect(model.handleKey(.key(kVK_Return, isRepeat: true)))
        #expect(await harness.router.confirmRequests() == 0)

        model.back()
        #expect(model.screen == .list)
        model.performPrimary()
        await harness.waitUntil { await harness.router.confirmRequests() == 1 && model.screen != .working("Working…") }
        try await Task.sleep(for: .milliseconds(800))

        #expect(await harness.router.confirmRequests() == 1)
        #expect(closeCount == 0)
        #expect(model.screen == .list)
        #expect(model.selectedItem?.action?.title == "R1")
    }

    /// Actions menu Confirm uses the same single server operation as the action bar and shortcut.
    @Test func actionsMenuConfirmSendsOneRequest() async throws {
        let harness = try await ShellHarness.make(now: ShellNow.body(reviews: ["R1"]))
        let model = harness.model
        let target = try #require(model.selectedItem.flatMap { item -> LauncherModel.Target? in
            guard let action = item.action, let group = item.group else { return nil }
            return LauncherModel.Target(action: action, group: group)
        })
        model.openActions()
        let confirm = try #require(model.actionEntries(for: target).firstIndex(of: .confirm))
        model.select(confirm)
        model.primary()

        await harness.waitUntil { await harness.router.confirmRequests() == 1 && model.screen != .working("Working…") }
        #expect(await harness.router.confirmRequests() == 1)
        #expect(model.screen == .list)
        #expect(model.selectedItem?.action?.id == target.action.id)
    }

    /// ⌘↩ invokes the canonical Confirm once; repeated command Return is ignored.
    @Test func commandReturnConfirmsOnce() async throws {
        let harness = try await ShellHarness.make(now: ShellNow.body(reviews: ["R1"]))
        let model = harness.model
        model.openDetail(for: try #require(model.selectedItem))
        #expect(model.screen.isDetail)
        #expect(model.handleKey(.key(kVK_Return, command: true, isRepeat: true)))
        #expect(await harness.router.confirmRequests() == 0)
        #expect(model.handleKey(.key(kVK_Return, command: true)))

        await harness.waitUntil { await harness.router.confirmRequests() == 1 && model.screen != .working("Working…") }
        #expect(await harness.router.confirmRequests() == 1)
        #expect(model.screen == .list)
    }

    /// A successful Review Dismiss keeps the launcher open and reports completion.
    @Test func successfulDismissKeepsLauncherOpen() async throws {
        let harness = try await ShellHarness.make(now: ShellNow.body(reviews: ["R1"]))
        let model = harness.model
        var closeCount = 0
        model.close = { closeCount += 1 }
        #expect(model.secondaryAction == LauncherModel.BarAction(title: "Dismiss", keys: "⌘⌫"))
        model.performSecondary()

        await harness.waitUntil { await harness.router.dismissRequests() == 1 && model.screen != .working("Working…") }
        try await Task.sleep(for: .milliseconds(800))

        #expect(await harness.router.dismissRequests() == 1)
        #expect(closeCount == 0)
        #expect(model.screen == .list)
        #expect(model.selectedItem?.action?.title == "R1")
        #expect(model.feedbackMessage == "Dismissed")
    }

    /// A status move and its Undo keep the launcher open and focused on the same task.
    @Test func statusChangeAndUndoKeepLauncherOpen() async throws {
        let harness = try await ShellHarness.make(now: ShellNow.body(toDo: ["T1", "T2"]))
        let model = harness.model
        var closeCount = 0
        model.close = { closeCount += 1 }
        let selected = try #require(model.selectedItem)
        let action = try #require(selected.action)

        model.setState(action, to: .done)
        #expect(model.screen == .list)
        #expect(model.selectedItem?.action?.id == action.id)
        #expect(model.canUndo)

        model.undo()
        #expect(model.screen == .list)
        #expect(model.selectedItem?.action?.id == action.id)
        #expect(!model.canUndo)

        await harness.waitUntil {
            let progressRequests = await harness.router.progressRequests()
            let nowRequests = await harness.router.nowRequests()
            return progressRequests == 2 && nowRequests >= 3
        }
        try await Task.sleep(for: .milliseconds(800))

        #expect(closeCount == 0)
        #expect(model.screen == .list)
        #expect(model.selectedItem?.action?.id == action.id)
        #expect(model.now?.sections.find(action.id)?.group == .toDo)
    }

    /// Editing a due date returns to the selected row with success feedback instead of closing.
    @Test func dueEditKeepsLauncherOpenAndSelection() async throws {
        let harness = try await ShellHarness.make(now: ShellNow.body(toDo: ["T1", "T2"]))
        let model = harness.model
        var closeCount = 0
        model.close = { closeCount += 1 }
        let selected = try #require(model.selectedItem)
        let action = try #require(selected.action)
        let target = LauncherModel.Target(action: action, group: .toDo)

        model.openActions()
        let dueChoice = try #require(model.actionEntries(for: target).firstIndex(of: .editDue))
        model.select(dueChoice)
        model.primary()
        let due = try #require(LocalDate(year: 2026, month: 10, day: 7))
        model.chooseDue(due)

        await harness.waitUntil { await harness.router.dueRequests() == 1 && model.screen == .list }
        try await Task.sleep(for: .milliseconds(800))

        #expect(closeCount == 0)
        #expect(model.selectedItem?.action?.id == action.id)
        #expect(model.feedbackMessage != nil)
    }

    /// A failed Confirm keeps its error visible and leaves the launcher open.
    @Test func failedConfirmKeepsLauncherOpenAndShowsError() async throws {
        let harness = try await ShellHarness.make(now: ShellNow.body(reviews: ["R1"]))
        let model = harness.model
        var closeCount = 0
        model.close = { closeCount += 1 }
        await harness.router.setConfirmStatus(500)

        model.performPrimary()
        await harness.waitUntil { model.screen != .working("Working…") }

        #expect(await harness.router.confirmRequests() == 1)
        #expect(model.screen == .notice("Something went wrong. Try again in a moment."))
        #expect(closeCount == 0)
    }

    /// `/now`를 받으면 요청한 계정의 저장본을 남기고, 로그아웃하면 지운다
    @Test func savedCopyIsWrittenForTheAccountAndDeletedOnSignOut() async throws {
        let harness = try await ShellHarness.make(now: ShellNow.body(reviews: ["R1"], toDo: ["T1"]))
        let account = harness.firstAccount
        let copy = try #require(harness.saved.load(account: account))
        #expect(copy.tasks.map(\.title) == ["R1", "T1"])

        harness.session.apply(event: .signedOut, session: nil)
        #expect(harness.saved.load(account: account) == nil)
        #expect(!FileManager.default.fileExists(atPath: harness.saved.root.path))
    }

    /// 로그아웃 직전에 보낸 `/now`가 로그아웃 뒤에 와도 저장본을 다시 쓰지 않는다
    @Test func lateNowAfterSignOutIsNotSaved() async throws {
        let harness = try await ShellHarness.make(now: nil)
        let account = harness.firstAccount
        await harness.router.setNow(ShellNow.body(toDo: ["Private"]))
        await harness.router.holdNow()
        let now = try #require(harness.model.now)
        let read = Task { await now.load() }
        await harness.waitUntil { await harness.router.hasPendingNow() }

        harness.session.apply(event: .signedOut, session: nil)
        await harness.router.releaseNow()
        _ = await read.value

        #expect(harness.saved.load(account: account) == nil)
        #expect(now.response == nil)
    }

    /// 앱을 열 때 다른 계정의 저장본은 지우고, 이번 실행에서 `/now`를 받기 전에는 지금 계정의 저장본을 보인다 (M15 · M19)
    @Test func launchPrunesOtherAccountsAndShowsTheCurrentSavedCopy() async throws {
        let other = UUID()
        let first = UUID()
        let saved = ShellHarness.temporaryStore()
        let copy = SavedNow(
            sections: TaskBoard(now: try ShellNow.decode(ShellNow.body(toDo: ["Saved T1"]))).sections(),
            savedAt: Date(timeIntervalSince1970: 1_791_000_000)
        )
        try saved.save(copy, account: other)
        try saved.save(copy, account: first)

        let harness = try await ShellHarness.make(now: nil, firstAccount: first, saved: saved)
        #expect(saved.load(account: other) == nil)
        #expect(harness.model.savedList == copy)
        #expect(harness.model.showsSavedTasks)
        #expect(harness.model.items.contains { if case .saved(let row) = $0 { row.task.title == "Saved T1" } else { false } })
        #expect(harness.model.bodyState == .list)
    }
}

// MARK: - 하네스

extension LauncherModel.Screen {
    var isActions: Bool {
        if case .actions = self { true } else { false }
    }
}

extension NSEvent {
    static func key(_ code: Int, command: Bool = false, isRepeat: Bool = false) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: command ? [.command] : [], timestamp: 0, windowNumber: 0, context: nil,
            characters: "", charactersIgnoringModifiers: "", isARepeat: isRepeat, keyCode: UInt16(code)
        )!
    }
}

/// `/now` 응답 본문
enum ShellNow {
    static func body(
        reviews: [String] = [], toDo: [String] = [], changed: Set<String> = [], limits: (Int, Int, Int) = (2, 5, 5)
    ) -> Data {
        func row(_ title: String, review: Bool, index: Int) -> String {
            // id는 제목으로 정한다 (목록 자리가 바뀌어도 같은 할 일)
            let number = title.utf8.reduce(3) { ($0 &* 31 &+ Int($1)) % 1_000_000_000 }
            let id = String(format: "00000000-0000-4000-8000-%012d", number)
            let ranked = review ? "" : #","score":1,"reasons":[],"days_until_due":null"#
            return """
            {"id":"\(id)","title":"\(title)","owner":"me","status":"open","due_date":null,"counterpart":null,\
            "needs_confirmation":\(review),"confirm_reasons":\(review ? #"["담당 확인"]"# : "[]"),"started_at":null,\
            "last_activity_at":"2026-09-29T10:00:00Z","changed":\(changed.contains(title))\(ranked)}
            """
        }
        let now = toDo.enumerated().map { row($1, review: false, index: $0) }.joined(separator: ",")
        let confirmations = reviews.enumerated().map { row($1, review: true, index: $0) }.joined(separator: ",")
        return Data("""
        {"now":[\(now)],"confirmations":[\(confirmations)],\
        "section_limits":{"review":\(limits.0),"in_progress":\(limits.1),"to_do":\(limits.2)}}
        """.utf8)
    }

    static func decode(_ data: Data) throws -> NowResponse {
        try TaskforceJSON.decoder().decode(NowResponse.self, from: data)
    }
}

@MainActor
private final class ShellHarness {
    let model: LauncherModel
    let session: SessionStore
    let router: ShellRouter
    let saved: SavedNowStore
    let displayPreferencesDefaults: UserDefaults
    let connectivity: AsyncStream<Bool>.Continuation
    let firstAccount: UUID
    private let storage: ShellSessionStorage
    private let urlSession: URLSession

    private init(
        model: LauncherModel, session: SessionStore, router: ShellRouter, saved: SavedNowStore, displayPreferencesDefaults: UserDefaults,
        connectivity: AsyncStream<Bool>.Continuation, firstAccount: UUID, storage: ShellSessionStorage, urlSession: URLSession
    ) {
        self.model = model
        self.session = session
        self.router = router
        self.saved = saved
        self.displayPreferencesDefaults = displayPreferencesDefaults
        self.connectivity = connectivity
        self.firstAccount = firstAccount
        self.storage = storage
        self.urlSession = urlSession
    }

    static func temporaryStore() -> SavedNowStore {
        SavedNowStore(root: FileManager.default.temporaryDirectory.appending(path: "LauncherShell-\(UUID().uuidString)", directoryHint: .isDirectory))
    }

    /// `now`가 nil이면 `/now`는 500 (첫 목록 없음)
    static func make(
        now: Data?, firstAccount: UUID = UUID(), saved: SavedNowStore? = nil,
        displayPreferences: SectionDisplayPreferences = .all
    ) async throws -> ShellHarness {
        let firstSession = shellSession(userID: firstAccount)
        let storage = ShellSessionStorage(data: try AuthClient.Configuration.jsonEncoder.encode(firstSession))
        let host = "supabase-\(UUID().uuidString.lowercased()).test"
        let apiHost = "api-\(UUID().uuidString.lowercased()).test"
        let router = ShellRouter(now: now)
        await ShellRouterRegistry.shared.register(router, for: host)
        await ShellRouterRegistry.shared.register(router, for: apiHost)

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ShellStubURLProtocol.self]
        let urlSession = URLSession(configuration: configuration)
        let config = AppConfig(
            supabaseURL: URL(string: "https://\(host)")!, supabaseKey: "test-key", appGroupID: "group.test.taskforce",
            apiBaseURL: URL(string: "https://\(apiHost)")!
        )
        let supabase = SupabaseClient(
            supabaseURL: config.supabaseURL,
            supabaseKey: config.supabaseKey,
            options: SupabaseClientOptions(
                auth: .init(storage: storage, autoRefreshToken: false, emitLocalSessionAsInitialSession: true),
                global: .init(session: urlSession)
            )
        )
        let session = SessionStore(auth: supabase.auth)
        session.apply(event: .signedIn, session: firstSession)
        let services = AppServices(config: config, supabase: supabase, session: urlSession)
        let account = AccountStore(services: services, session: session)
        let store = saved ?? temporaryStore()
        let displayPreferencesDefaults = UserDefaults(suiteName: "LauncherShell-\(UUID().uuidString)")!
        displayPreferences.save(to: displayPreferencesDefaults)
        let (stream, continuation) = AsyncStream<Bool>.makeStream()
        let model = LauncherModel(
            session: session, services: services, account: account, saved: store, connectivity: stream,
            displayPreferencesDefaults: displayPreferencesDefaults
        )
        model.sessionChanged()
        for _ in 0..<200 where model.now?.loaded != true {
            try await Task.sleep(for: .milliseconds(10))
        }
        return ShellHarness(
            model: model, session: session, router: router, saved: store, displayPreferencesDefaults: displayPreferencesDefaults,
            connectivity: continuation, firstAccount: firstAccount, storage: storage, urlSession: urlSession
        )
    }

    func waitUntil(_ condition: @MainActor () async -> Bool) async {
        for _ in 0..<200 {
            if await condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(await condition())
    }
}

private final class ShellSessionStorage: AuthLocalStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var data: Data

    init(data: Data) {
        self.data = data
    }

    func store(key: String, value: Data) throws {
        lock.lock()
        defer { lock.unlock() }
        data = value
    }

    func retrieve(key: String) throws -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return data
    }

    func remove(key: String) throws {}
}

private struct ShellResponse: Sendable {
    let status: Int
    let body: Data
}

private actor ShellRouter {
    private var now: Data?
    private var consentStatus = 204
    private var startStatus = 409
    private var consentCount = 0
    private var completeCount = 0
    private var confirmCount = 0
    private var confirmedActionIDs: [UUID] = []
    private var dismissCount = 0
    private var progressCount = 0
    private var dueCount = 0
    private var confirmStatus = 200
    private var holdingConsent = false
    private var heldConsent: [CheckedContinuation<ShellResponse, Never>] = []
    private var nowCount = 0
    private var seen: [UUID] = []
    private var holding = false
    private var held: [CheckedContinuation<ShellResponse, Never>] = []

    init(now: Data?) {
        self.now = now
    }

    func response(method: String, path: String) async -> ShellResponse {
        if method == "POST", path == "/api/v1/consent" {
            consentCount += 1
            if holdingConsent { return await withCheckedContinuation { heldConsent.append($0) } }
            return consentResponse()
        }
        if method == "POST", path == "/api/v1/connections/notion/start" {
            return connectionResponse(status: startStatus)
        }
        if method == "POST", path == "/api/v1/connections/notion/complete" {
            completeCount += 1
            return connectionResponse(status: 409)
        }
        if method == "POST", path.hasPrefix("/api/v1/actions/"), path.hasSuffix("/confirm") {
            confirmCount += 1
            if confirmStatus != 200 {
                return ShellResponse(
                    status: confirmStatus,
                    body: Data("{\"error\":{\"code\":\"internal_error\",\"message\":\"Confirm unavailable\"}}".utf8)
                )
            }
            let id = path.split(separator: "/").dropLast().last.map(String.init) ?? "00000000-0000-4000-8000-000000000001"
            if let actionID = UUID(uuidString: id) { confirmedActionIDs.append(actionID) }
            let body = Data("""
            {"action":{"id":"\(id)","title":"R1","owner":"me","status":"open","due_date":null,
            "counterpart":null,"needs_confirmation":false,"confirm_reasons":[],"started_at":null,
            "last_activity_at":"2026-09-29T10:00:00Z"}}
            """.utf8)
            return ShellResponse(status: 200, body: body)
        }
        if method == "POST", path.hasPrefix("/api/v1/actions/"), path.hasSuffix("/progress") {
            progressCount += 1
            let id = path.split(separator: "/").dropLast().last.map(String.init) ?? "00000000-0000-4000-8000-000000000001"
            return actionResponse(id)
        }
        if method == "PATCH", path.hasPrefix("/api/v1/actions/") {
            dueCount += 1
            let id = path.split(separator: "/").last.map(String.init) ?? "00000000-0000-4000-8000-000000000001"
            return actionResponse(id)
        }
        if method == "DELETE", path.hasPrefix("/api/v1/actions/") {
            dismissCount += 1
            let id = path.split(separator: "/").last.map(String.init) ?? "00000000-0000-4000-8000-000000000001"
            return actionResponse(id)
        }
        if path == "/api/v1/now" {
            nowCount += 1
            if holding { return await withCheckedContinuation { held.append($0) } }
            return currentNow()
        }
        if method == "POST", path.hasPrefix("/api/v1/actions/"), path.hasSuffix("/seen") {
            let id = path.dropFirst("/api/v1/actions/".count).dropLast("/seen".count)
            if let uuid = UUID(uuidString: String(id)) { seen.append(uuid) }
            return ShellResponse(status: 204, body: Data())
        }
        if path.hasPrefix("/api/v1/") {
            return ShellResponse(status: 500, body: Data("{}".utf8))
        }
        return ShellResponse(status: 200, body: Data("[]".utf8))
    }

    private func currentNow() -> ShellResponse {
        guard let now else { return ShellResponse(status: 500, body: Data("{}".utf8)) }
        return ShellResponse(status: 200, body: now)
    }

    private func consentResponse() -> ShellResponse {
        if consentStatus == 204 { return ShellResponse(status: 204, body: Data()) }
        let code = consentStatus == 404 ? "not_found" : "invalid_request"
        return ShellResponse(status: consentStatus, body: Data("{\"error\":{\"code\":\"\(code)\",\"message\":\"Consent unavailable\"}}".utf8))
    }

    private func connectionResponse(status: Int) -> ShellResponse {
        let code = status == 409 ? "conflict" : status == 404 ? "not_found" : "invalid_request"
        return ShellResponse(status: status, body: Data("{\"error\":{\"code\":\"\(code)\",\"message\":\"Connection unavailable\"}}".utf8))
    }

    func setConsentStatus(_ status: Int) { consentStatus = status }
    func setStartStatus(_ status: Int) { startStatus = status }
    func consentRequests() -> Int { consentCount }
    func completeRequests() -> Int { completeCount }
    func confirmRequests() -> Int { confirmCount }
    func confirmIDs() -> [UUID] { confirmedActionIDs }
    func dismissRequests() -> Int { dismissCount }
    func progressRequests() -> Int { progressCount }
    func dueRequests() -> Int { dueCount }
    func setConfirmStatus(_ status: Int) { confirmStatus = status }
    func holdConsent() { holdingConsent = true }
    func hasPendingConsent() -> Bool { !heldConsent.isEmpty }

    func releaseConsent() {
        holdingConsent = false
        for continuation in heldConsent { continuation.resume(returning: consentResponse()) }
        heldConsent = []
    }

    func setNow(_ data: Data?) { now = data }
    func nowRequests() -> Int { nowCount }
    func seenIDs() -> [UUID] { seen }
    func holdNow() { holding = true }
    func hasPendingNow() -> Bool { !held.isEmpty }

    func releaseNow() {
        holding = false
        let response = currentNow()
        for continuation in held { continuation.resume(returning: response) }
        held = []
    }

    private func actionResponse(_ id: String) -> ShellResponse {
        let body = Data("""
        {"action":{"id":"\(id)","title":"T1","owner":"me","status":"open","due_date":null,
        "counterpart":null,"needs_confirmation":false,"confirm_reasons":[],"started_at":null,
        "last_activity_at":"2026-09-29T10:00:00Z"}}
        """.utf8)
        return ShellResponse(status: 200, body: body)
    }
}

private actor ShellRouterRegistry {
    static let shared = ShellRouterRegistry()
    private var routers: [String: ShellRouter] = [:]

    func register(_ router: ShellRouter, for host: String) {
        routers[host] = router
    }

    func router(for host: String) -> ShellRouter? {
        routers[host]
    }
}

private final class ShellStubURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host?.hasSuffix(".test") == true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let host = url.host else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let method = request.httpMethod ?? "GET"
        let path = url.path
        let box = ShellCompletion(self)
        Task {
            guard let router = await ShellRouterRegistry.shared.router(for: host) else {
                box.fail(URLError(.cannotFindHost))
                return
            }
            let result = await router.response(method: method, path: path)
            let response = HTTPURLResponse(url: url, statusCode: result.status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
            box.succeed(response, body: result.body)
        }
    }

    override func stopLoading() {}
}

// URLProtocolClient is not Sendable, so the task uses this one-shot unchecked box to retain the protocol.
private final class ShellCompletion: @unchecked Sendable {
    private var urlProtocol: ShellStubURLProtocol?

    init(_ urlProtocol: ShellStubURLProtocol) {
        self.urlProtocol = urlProtocol
    }

    func succeed(_ response: URLResponse, body: Data) {
        guard let urlProtocol else { return }
        self.urlProtocol = nil
        urlProtocol.client?.urlProtocol(urlProtocol, didReceive: response, cacheStoragePolicy: .notAllowed)
        urlProtocol.client?.urlProtocol(urlProtocol, didLoad: body)
        urlProtocol.client?.urlProtocolDidFinishLoading(urlProtocol)
    }

    func fail(_ error: Error) {
        guard let urlProtocol else { return }
        self.urlProtocol = nil
        urlProtocol.client?.urlProtocol(urlProtocol, didFailWithError: error)
    }
}

private func shellSession(userID: UUID) -> Session {
    let user = User(
        id: userID, appMetadata: [:], userMetadata: [:], aud: "authenticated", email: "\(userID.uuidString)@example.com",
        createdAt: Date(), updatedAt: Date()
    )
    let lifetime: TimeInterval = 3600
    return Session(
        accessToken: "access-\(userID)", tokenType: "bearer", expiresIn: lifetime,
        expiresAt: Date().addingTimeInterval(lifetime).timeIntervalSince1970, refreshToken: "refresh-\(userID)", user: user
    )
}
