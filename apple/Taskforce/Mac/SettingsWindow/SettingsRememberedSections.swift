#if os(macOS)
import AppKit
import SwiftUI
import TaskforceKit
import TaskforceUI

// Settings › Account › Remembered (B3, 디자인 SettingsPage · RememberedRow · RememberedDetail).
// 읽기는 RLS(`MemoryStore`), 쓰기는 서버 API. 성공은 서버가 답한 뒤에만 말하고, 409는 성공으로 올리지 않고 지금 상태를 다시 읽어 보인다.

/// Account 탭의 한 줄 "Remembered": 누르면 목록
struct SettingsRememberedSection: View {
    var body: some View {
        SettingsSection {
            SettingsTrayRow(MemoryCopy.rowTitle, detail: MemoryCopy.rowDetail, onOpen: { SettingsWindowModel.shared.open(.remembered) })
        }
    }
}

/// Remembered 목록: 기억 행 + 각주 "context, not permission". 읽는 중 · 오프라인 · 실패 · 없음은 서로 다른 화면
struct SettingsRememberedList: View {
    private var runtime: ChatRuntime? { SettingsWindowModel.shared.chatRuntime }

    var body: some View {
        if let memory = runtime?.memory {
            content(memory)
                .task { await memory.loadList() }
        }
    }

    @ViewBuilder
    private func content(_ memory: MemoryStore) -> some View {
        switch Self.screen(load: memory.load, isEmpty: memory.items.isEmpty) {
        case .blank:
            // 읽는 중: 아무 주장도 하지 않는다
            EmptyView()
        case .offline:
            stateRow(MemoryCopy.offline, memory: memory)
        case .failed:
            stateRow(MemoryCopy.couldNotLoad, memory: memory)
        case .unavailable:
            // 서버에 아직 없는 기능: 실패도 "비어 있음"도 아니다
            SettingsSection(footnote: MemoryCopy.listFootnote) {
                SettingsTrayRow(MemoryCopy.unavailable)
            }
        case .empty:
            SettingsSection(footnote: MemoryCopy.listFootnote) {
                SettingsTrayRow(MemoryCopy.emptyList)
            }
        case .list:
            SettingsSection(footnote: MemoryCopy.listFootnote) {
                ForEach(memory.items) { item in
                    RememberedRow(
                        statement: MemoryText.statement(item), meta: MemoryText.meta(item, contexts: memory.contexts, withTime: true),
                        isTentative: MemoryText.isTentative(item), onOpen: { SettingsWindowModel.shared.open(.memory(item.id)) }
                    )
                }
            }
        }
    }

    private func stateRow(_ text: String, memory: MemoryStore) -> some View {
        SettingsSection(footnote: MemoryCopy.listFootnote) {
            SettingsTrayRow(text) {
                Button(MemoryCopy.tryAgain) { Task { await memory.loadList() } }.buttonStyle(TFButtonStyle())
            }
        }
    }

    enum Screen: Equatable {
        case blank, offline, failed, unavailable, empty, list
    }

    /// 목록 화면: 받은 행이 있으면 목록, 없으면 읽기 상태가 화면이다 (읽는 중에는 "Nothing remembered yet."이라고 하지 않는다)
    static func screen(load: MemoryStore.Load, isEmpty: Bool) -> Screen {
        if !isEmpty { return .list }
        switch load {
        case .idle, .loading: return .blank
        case .offline: return .offline
        case .failed: return .failed
        case .unavailable: return .unavailable
        case .loaded: return .empty
        }
    }
}

/// 기억 하나 (RememberedDetail): 문장 + Confirm(추정) · Edit, kind, 범위 팝업, 언제, 출처 인용, Forget(제자리 확인)
struct SettingsMemoryDetail: View {
    let id: UUID
    private var runtime: ChatRuntime? { SettingsWindowModel.shared.chatRuntime }

    var body: some View {
        if let runtime {
            let memory = runtime.memory
            let current = memory.resolve(id)
            Group {
                if let item = memory.item(current) {
                    RememberedDetail(
                        content: Self.content(for: item, memory: memory),
                        isConfirmingForget: SettingsWindowModel.shared.confirming == .forgetMemory(current),
                        onConfirm: { Task { await memory.confirm(current) } },
                        onEdit: { text in Task { await memory.edit(current, statement: text) } },
                        onMove: { target in Task { await memory.move(current, to: target) } },
                        onAskForget: { SettingsWindowModel.shared.confirming = .forgetMemory(current) },
                        onCancelForget: { SettingsWindowModel.shared.confirming = nil },
                        onForget: {
                            Task {
                                // 잊기 200은 "지금 기억이 아님"이다: 목록으로 돌아간다. 충돌이면 지금 상태를 보이고 머문다
                                let result = await memory.forget(current)
                                if result == .forgotten { SettingsWindowModel.shared.back() } else { SettingsWindowModel.shared.confirming = nil }
                            }
                        },
                        onRetrySource: { Task { await memory.loadSource(for: item) } },
                        onOpenURL: { runtime.openURL($0) }
                    )
                } else if memory.load == .loaded {
                    SettingsSection { SettingsTrayRow(MemoryCopy.noLongerRemembered) }
                }
            }
            .task(id: current) {
                if memory.load == .idle { await memory.loadList() }
                if let item = memory.item(current) { await memory.loadSource(for: item) }
            }
        }
    }

    static func content(for item: MemoryItem, memory: MemoryStore, now: Date = Date()) -> RememberedDetail.Content {
        RememberedDetail.Content(
            statement: MemoryText.statement(item), isTentative: MemoryText.isTentative(item), isCurrent: item.isCurrent, kind: MemoryText.kindLine(item),
            scopeName: MemoryText.scope(item, contexts: memory.contexts),
            // 범위 popup은 explicit이고 전체 · 프로젝트일 때만 (서버가 보류한 항목은 감춘다)
            scopeChoices: memory.canChangeScope(item) ? MemoryText.scopeChoices(for: item, contexts: memory.contexts) : [],
            selectedScope: MemoryText.currentTarget(item), when: WhenText.label(item.observedAt, now: now), source: memory.sourceDisplay(for: item),
            canConfirm: memory.canConfirm(item), canChange: true, isBusy: memory.isBusy(item.id), notice: memory.feedback(for: item.id)?.text,
            writesUnavailable: memory.writesUnavailable
        )
    }
}
#endif
