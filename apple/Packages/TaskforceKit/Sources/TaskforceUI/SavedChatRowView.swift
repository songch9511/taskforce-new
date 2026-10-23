#if os(macOS)
import SwiftUI
import TaskforceKit

/// Sessions 패널의 Saved chats 줄 (OA D3v-m, DZ 승인 2026-10-23 `oa-desktop-chat-view-dz` 시트 1): Claude 마크 20 · 제목(callout, 한 줄 끝 줄임; 제목이 없으면 회색 "Untitled") · "시각 · 기기 이름"(footnote).
/// **링 · 상태 말 · 버튼이 없다** (저장된 기록은 상태가 없다). 줄 전체가 버튼이다: 누르면 읽기 전용 패널이 Sessions 왼쪽에 열린다.
/// 오른쪽 클릭 메뉴는 **Delete 하나**다: 누르면 바로 지우지 않고 그 대화를 열어 확인 카드를 띄운다 (`onDelete`). 줄에 hover 버튼은 없다.
/// `current`는 `bg/selected` (지금 그 대화가 열려 있다). 접근성 이름은 "제목 — 시각 · 기기" + 동작 Delete
public struct SavedChatRowView: View {
    let row: SavedChatRow
    let now: Date
    let current: Bool
    let onOpen: () -> Void
    let onDelete: () -> Void

    public init(_ row: SavedChatRow, now: Date, current: Bool = false, onOpen: @escaping () -> Void, onDelete: @escaping () -> Void) {
        self.row = row
        self.now = now
        self.current = current
        self.onOpen = onOpen
        self.onDelete = onDelete
    }

    public var body: some View {
        PanelRowChrome(current: current, highlighted: false, accessibilityName: row.accessibilityName(now: now), askLabel: nil, onOpen: onOpen, onAsk: nil) { lit, _ in
            HStack(alignment: .top, spacing: 10) {
                AgentMark(.claudeCode, size: 20)
                    .frame(minHeight: 20)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 0) {
                    Text(row.displayTitle)
                        .font(TFFont.callout)
                        .tracking(-0.24)
                        .foregroundStyle(row.isUntitled ? (lit ? TFColor.textSecondarySelected : TFColor.textSecondary) : TFColor.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(height: 20, alignment: .leading)
                    Text(row.metaText(now: now))
                        .font(TFFont.footnote)
                        .tracking(-0.08)
                        .foregroundStyle(lit ? TFColor.textSecondarySelected : TFColor.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(height: 18, alignment: .leading)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .contextMenu {
            Button(SavedChatsCopy.delete, action: onDelete)
        }
        .accessibilityAction(named: SavedChatsCopy.delete, onDelete)
    }
}

#Preview("Saved chat rows") {
    VStack(spacing: 2) {
        ForEach(SavedChatsPreview.rows) { row in
            SavedChatRowView(row, now: Date(), onOpen: {}, onDelete: {})
        }
    }
    .padding(8)
    .frame(width: 380)
    .background(TFColor.bgPanel)
}

private enum SavedChatsPreview {
    static let rows: [SavedChatRow] = [
        SavedChatRow(id: UUID(), title: "Fix launcher focus after sleep", lastMessageAt: Date().addingTimeInterval(-720), deviceName: "Daniel's MacBook Air"),
        SavedChatRow(id: UUID(), title: nil, lastMessageAt: Date().addingTimeInterval(-86_400), deviceName: "Daniel's MacBook Pro 16-inch (second floor)"),
        SavedChatRow(id: UUID(), title: "Source marks audit", lastMessageAt: Date().addingTimeInterval(-7_200), deviceName: nil),
    ]
}
#endif
