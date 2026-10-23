import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Taskforce
@testable import TaskforceKit
@testable import TaskforceUI

/// Settings › Account › Saved chats의 Mac 쪽 (OA D3v-m, DZ 시트 6, 계약 27장 Q-D3v2 · Q-D3v3): "Delete all saved chats" 한 줄 · 확인 · 지우는 중 · 결과 · 실패(원자적이라 아무것도 지워지지 않았다: V5 + 이유 + Try again).
/// 서버에 닿지 않는다 (가짜 닫힘). 저장 표시(각주 · "Saving On/Off")는 어디에도 없다
@MainActor
struct SavedChatsSettingsMacTests {
    typealias M = SavedChatsMacTests

    private func make(rows: [SavedChatRow] = (1...3).map { M.row($0) }) async -> (SettingsWindowModel, SavedChatsStore, M.Backend, AccountScope) {
        let scope = AccountScope(currentAccount: { SampleData.userID })
        let backend = M.Backend(pages: [rows])
        let store = M.store(backend, scope: scope)
        await store.refresh()
        let model = SettingsWindowModel()
        model.savedChats = store
        return (model, store, backend, scope)
    }

    // MARK: 주제 목록

    @Test func theAccountTabHasASavedChatsTopicOnlyWhenTheShellHasAStoreAndNothingElseMoves() {
        let account = SettingsWindowTab.account
        #expect(account.sections(.signedIn, savedChats: true) == [.profile, .signIn, .planAndUsage, .remembered, .savedChats, .deleteAccount, .about, .legal])
        #expect(account.sections(.signedIn) == [.profile, .signIn, .planAndUsage, .remembered, .deleteAccount, .about, .legal], "저장소가 없으면 지금 그대로")
        #expect(account.sections(.signedOut, savedChats: true) == [.signIn, .about, .legal] && account.sections(.loading, savedChats: true) == [.signIn, .about, .legal])
        for tab in SettingsWindowTab.allCases where tab != .account {
            #expect(tab.sections(.signedIn, savedChats: true) == tab.sections(.signedIn), "다른 탭은 그대로")
        }
        #expect(SettingsWindowSection.savedChats.title == "Saved chats")
    }

    // MARK: 줄의 상태

    @Test func withNoSavedChatsThereIsNoRowAndNoSection() async {
        let (model, store, _, _) = await make(rows: [])
        #expect(SavedChatsSettingsPlan.of(store: store, confirming: false) == .hidden, "저장된 대화가 없으면 줄을 감춘다")
        model.confirming = .deleteAllSavedChats
        #expect(SavedChatsSettingsPlan.of(store: store, confirming: true) == .hidden, "확인 줄도 지울 것이 없으면 없다")
    }

    @Test func withSavedChatsTheRowOffersDeleteAndTheConfirmReplacesItInPlace() async {
        let (_, store, _, _) = await make()
        #expect(SavedChatsSettingsPlan.of(store: store, confirming: false) == .delete)
        #expect(SavedChatsSettingsPlan.of(store: store, confirming: true) == .confirm(busy: false))
    }

    @Test func theCopyIsTheApprovedWordsAndThereIsNoSavingIndicator() {
        #expect(SavedChatsCopy.deleteAllRow == "Delete all saved chats" && SavedChatsCopy.deleteAllButton == "Delete…")
        #expect(SavedChatsCopy.deleteAllTitle == "Delete all saved chats?" && SavedChatsCopy.deleteAllDetail == "Deletes the saved copies from all your devices")
        #expect(SavedChatsCopy.deleteAllConfirm == "Delete all" && SavedChatsCopy.couldNotDelete == "Couldn't delete", "실패는 V5다: 서버가 원자적이라 일부만 지워지는 V13은 없다")
        let all = (SavedChatsCopy.approved + [SavedChatsCopy.delete]).joined(separator: "\n").lowercased()
        #expect(!all.contains("saving") && !all.contains("saved to your account") && !all.contains("until you delete"), "저장 중 표시(V14–V16)는 없다")
    }

    // MARK: 흐름

    @Test func confirmingDeletesAllThroughTheServerAndTheRowDisappears() async {
        let (model, store, backend, _) = await make()
        model.confirming = .deleteAllSavedChats
        await model.deleteAllSavedChats()
        #expect(backend.deleteAllCalls == 1, "서버에 한 번 보낸다")
        #expect(model.confirming == nil && store.rows.isEmpty)
        #expect(SavedChatsSettingsPlan.of(store: store, confirming: false) == .hidden, "결과: 저장된 대화가 없어 줄이 사라진다")
    }

    @Test func whileDeletingTheConfirmRowIsBusyAndAPressSendsOnce() async {
        let gate = M.Gate()
        let scope = AccountScope(currentAccount: { SampleData.userID })
        let hits = SavedDeleteAllCounter()
        let store = SavedChatsStore(
            scope: scope, readPage: { _, _ in (1...3).map { M.row($0) } }, readMessages: { _, _, _ in [] }, deleteChat: { _ in }, deleteAll: { hits.hit(); await gate.wait() }
        )
        await store.refresh()
        let model = SettingsWindowModel()
        model.savedChats = store
        let first = Task { await model.deleteAllSavedChats() }
        #expect(await EdgeExternalSessionsTests().until { store.deleteAllState == .deleting })
        #expect(SavedChatsSettingsPlan.of(store: store, confirming: true) == .confirm(busy: true))
        await model.deleteAllSavedChats()
        await gate.open()
        await first.value
        #expect(hits.count == 1, "지우는 동안 다시 눌러도 한 번")
    }

    @Test func aFailureSaysCouldNotDeleteWithTheReasonAndTryAgainDeletesAgain() async {
        let (model, store, backend, _) = await make()
        backend.failDeleteAll(APIError.transport("offline"))
        model.confirming = .deleteAllSavedChats
        await model.deleteAllSavedChats()
        #expect(model.confirming == nil && store.rows.count == 3, "남은 것을 다시 읽어 보인다")
        #expect(SavedChatsSettingsPlan.of(store: store, confirming: false) == .failed(detail: "Couldn't delete · You're offline. Try again."))
        backend.failDeleteAll(nil)
        await model.deleteAllSavedChats()
        #expect(backend.deleteAllCalls == 2 && store.rows.isEmpty && SavedChatsSettingsPlan.of(store: store, confirming: false) == .hidden, "Try again이 다시 보낸다")
    }

    @Test func aServerErrorUsesTheGenericReasonLine() async {
        let (model, store, backend, _) = await make()
        backend.failDeleteAll(APIError.server(status: 500, code: .internalError, message: "x"))
        await model.deleteAllSavedChats()
        #expect(SavedChatsSettingsPlan.of(store: store, confirming: false) == .failed(detail: "Couldn't delete · Something went wrong. Try again in a moment."))
    }

    @Test func theTrayRowDeletesNothingWithoutAStore() async {
        let model = SettingsWindowModel()
        await model.deleteAllSavedChats()
        #expect(model.confirming == nil && model.savedChats == nil)
    }

    @Test func anAccountSwitchClearsTheRowAndTheFailure() async {
        let (model, store, backend, scope) = await make()
        backend.failDeleteAll(APIError.transport("offline"))
        await model.deleteAllSavedChats()
        #expect(SavedChatsSettingsPlan.of(store: store, confirming: false) != .hidden)
        scope.accountLeft()
        #expect(SavedChatsSettingsPlan.of(store: store, confirming: false) == .hidden && store.deleteAllState == .idle, "다른 계정에 앞 계정의 줄 · 실패가 남지 않는다")
    }
}

final class SavedDeleteAllCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.withLock { value } }
    func hit() { lock.withLock { value += 1 } }
}
