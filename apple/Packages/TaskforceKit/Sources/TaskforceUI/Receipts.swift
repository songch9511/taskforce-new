import SwiftUI
import TaskforceKit

/// Receipts (0.2.0 디자인 시스템 Molecules, 결정 D-8): 피드백 하나가 여러 작업에 닿은 뒤 **작업마다 무슨 일이 있었는지**. Taskforce 채팅 메시지 안에 들어간다.
/// - 줄 하나 = 작업 하나, 줄마다 자기 결과. 실패는 **굵은 글씨로 풀어 쓰고** 그 줄에만 `Retry`가 있다.
/// - 줄은 그 작업의 단일 상세를 연다 (따로 영수증 화면이 없다).
/// 이 PR(C3)은 **컴포넌트 틀만** 만든다: 실제 결과(작업별 발송 receipt · Retry 채움)는 F2다. 실제 결과가 없으면 이 컴포넌트를 그리는 곳이 없다
/// (화면에 연결하지 않고, 가짜 성공 · 실패 receipt를 만들지 않는다 — 미리보기 견본만 있다).
public struct Receipts: View {
    public struct Item: Equatable, Sendable, Identifiable {
        public let id: UUID
        public let title: String
        /// 이 작업의 결과 한 줄 ("FAQ shortened · Version 5", 실패면 이유까지: "Not applied · locked for review")
        public let outcome: String
        public let failed: Bool

        public init(id: UUID, title: String, outcome: String, failed: Bool = false) {
            self.id = id
            self.title = title
            self.outcome = outcome
            self.failed = failed
        }
    }

    let items: [Item]
    let onOpen: (UUID) -> Void
    let onRetry: ((UUID) -> Void)?

    /// - onRetry: 없으면 실패 줄에도 Retry가 없다 (다시 할 길이 없는 실패를 버튼으로 꾸미지 않는다)
    public init(items: [Item], onOpen: @escaping (UUID) -> Void = { _ in }, onRetry: ((UUID) -> Void)? = nil) {
        self.items = items
        self.onOpen = onOpen
        self.onRetry = onRetry
    }

    nonisolated public static let retryLabel = "Retry"

    /// Retry는 실패한 줄에만, 다시 할 길이 있을 때만
    nonisolated public static func showsRetry(_ item: Item, hasHandler: Bool) -> Bool { item.failed && hasHandler }

    public var body: some View {
        Card {
            CardRows {
                ForEach(items) { item in
                    // Retry는 실패한 그 줄에만. 없는 줄은 줄 전체가 상세를 연다 (›)
                    if Self.showsRetry(item, hasHandler: onRetry != nil) {
                        CardRow(title: item.title, detail: AttributedString(item.outcome), attention: true, onOpen: { onOpen(item.id) }) {
                            Button(Self.retryLabel) { onRetry?(item.id) }.buttonStyle(TFButtonStyle(.secondary, size: .sm))
                        }
                    } else {
                        CardRow(title: item.title, detail: AttributedString(item.outcome), attention: item.failed, onOpen: { onOpen(item.id) })
                    }
                }
            }
        }
    }
}

#Preview("Receipts") {
    // 디자인 SSOT의 견본 (미리보기에만 있다: 실제 화면에는 연결되지 않는다)
    Receipts(
        items: [
            .init(id: UUID(), title: "Pricing page", outcome: "FAQ shortened · Version 5"),
            .init(id: UUID(), title: "Acme pricing", outcome: "Not applied · locked for review", failed: true),
        ],
        onRetry: { _ in }
    )
    .padding(16)
    .frame(width: 380)
    .background(TFColor.bgPanel)
}
