#if os(macOS)
import SwiftUI
import TaskforceKit
import TaskforceUI

// Settings › Account › Saved chats (OA D3v-m, DZ 승인 2026-10-23 `oa-desktop-chat-view-dz` 시트 6, 계약 27장 Q-D3v2): 한 줄 "Delete all saved chats" + "Delete…".
// 누르면 그 줄 자리에서 확인한다 (`ConfirmRow`: "Delete all saved chats?" · "Delete all" · Cancel, 모달 아님). 지우는 동안은 단추가 바쁘고, 끝나면 줄이 사라진다 (저장된 대화가 없다).
// 지우지 못하면(서버의 모두 지우기는 원자적이라 아무것도 지워지지 않았다) 같은 줄이 "Couldn't delete · 승인된 이유 줄"과 Try again이 된다 (일부만 지워지는 V13은 없다). 각주(저장 중 표시)는 없다 (Q-D3v3).
// **저장된 대화가 없으면 절이 머리째 없다.** 저장소가 없는 셸(목록 게이트 꺼짐 · 격리 실행)에서도 없다.

/// 이 절이 무엇을 보이나 (순수한 판단: 시험이 상태마다 확인한다)
struct SavedChatsSettingsPlan: Equatable {
    enum Row: Equatable {
        /// 절이 없다 (저장된 대화가 없다)
        case hidden
        /// "Delete all saved chats" + Delete…
        case delete
        /// 확인 줄 (지우는 중이면 `busy`)
        case confirm(busy: Bool)
        /// 지우지 못했다: "Couldn't delete · 이유" + Try again
        case failed(detail: String)
    }

    /// - confirming: 확인 줄을 열었다 (`SettingsWindowConfirm.deleteAllSavedChats`)
    @MainActor
    static func of(store: SavedChatsStore, confirming: Bool) -> Row {
        switch store.deleteAllState {
        case .deleting:
            return .confirm(busy: true)
        case .failed(let reason):
            guard store.hasChats else { return .hidden }
            return .failed(detail: "\(SavedChatsCopy.couldNotDelete) · \(reason.reason)")
        case .idle:
            break
        }
        guard store.hasChats else { return .hidden }
        return confirming ? .confirm(busy: false) : .delete
    }
}

struct SettingsSavedChatsSection: View {
    private var model: SettingsWindowModel { .shared }

    var body: some View {
        if let store = model.savedChats {
            content(store)
        }
    }

    @ViewBuilder
    private func content(_ store: SavedChatsStore) -> some View {
        let row = SavedChatsSettingsPlan.of(store: store, confirming: model.confirming == .deleteAllSavedChats)
        switch row {
        case .hidden:
            EmptyView()
        case .delete:
            SettingsSection(SavedChatsCopy.title) {
                SettingsTrayRow(SavedChatsCopy.deleteAllRow) {
                    Button(SavedChatsCopy.deleteAllButton) { model.confirming = .deleteAllSavedChats }
                        .buttonStyle(TFButtonStyle())
                }
            }
        case .confirm(let busy):
            SettingsSection(SavedChatsCopy.title) {
                ConfirmRow(
                    SavedChatsCopy.deleteAllTitle, detail: SavedChatsCopy.deleteAllDetail, confirmLabel: SavedChatsCopy.deleteAllConfirm, busy: busy,
                    onConfirm: run, onCancel: { model.confirming = nil }
                )
            }
        case .failed(let detail):
            SettingsSection(SavedChatsCopy.title) {
                SettingsTrayRow(SavedChatsCopy.deleteAllRow, detail: detail) {
                    Button(ExternalSessionCopy.tryAgain, action: run)
                        .buttonStyle(TFButtonStyle())
                }
            }
        }
    }

    /// 확인 줄의 Delete all · 실패 줄의 Try again: 서버에 한 번 보낸다 (`SettingsWindowModel.deleteAllSavedChats`)
    private func run() {
        Task { await model.deleteAllSavedChats() }
    }
}
#endif
