import SwiftUI

/// Disclosure (0.2.0 디자인 시스템 Molecules): 접는 줄. 상세 하나(프로젝트 · 검사 · 결과 · 영향받는 일)를 요약 아래 접어 두고, 연 내용은 `Card`로 나눈다.
/// 요약은 패널 위의 평평한 48pt 줄(아이콘 · 제목 15 · 상태 줄 12 · 꺾쇠). 채움 · 구분선 없이 호버 판만. 꺾쇠는 열리면 200ms에 뒤집힌다.
/// 디스클로저는 카드가 아니다(카드 안 카드 없음). 디스클로저 안에 디스클로저를 넣지 않는다. 줄끼리 2pt, 앞 내용에서 12pt 아래.
public struct Disclosure<Content: View>: View {
    let icon: TFIcon?
    let summary: String
    let meta: String?
    let reduceMotion: Bool
    let content: Content
    @State private var isOpen: Bool
    @State private var hovering = false

    public init(icon: TFIcon? = nil, summary: String, meta: String? = nil, defaultOpen: Bool = false, reduceMotion: Bool = false, @ViewBuilder content: () -> Content) {
        self.icon = icon
        self.summary = summary
        self.meta = meta
        self.reduceMotion = reduceMotion
        self.content = content()
        _isOpen = State(initialValue: defaultOpen)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(TFMotion.move(TFMotion.disclosureFlip, reduceMotion: reduceMotion)) { isOpen.toggle() }
            } label: {
                HStack(spacing: 10) {
                    if let icon {
                        icon.image().foregroundStyle(TFColor.textPrimary)
                    }
                    VStack(alignment: .leading, spacing: 0) {
                        Text(summary)
                            .font(TFFont.callout)
                            .tracking(-0.24)
                            .foregroundStyle(TFColor.textPrimary)
                            .lineLimit(1)
                        if let meta {
                            Text(meta)
                                .font(TFFont.meta)
                                .foregroundStyle(hovering ? TFColor.textSecondarySelected : TFColor.textSecondary)
                                .lineLimit(1)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    TFIcon.disclosure.image(size: 14)
                        .foregroundStyle(hovering ? TFColor.textSecondarySelected : TFColor.textSecondary)
                        .rotationEffect(.degrees(isOpen ? 180 : 0))
                }
                .padding(TFSpace.sm)
                .frame(minHeight: 48)
                .background {
                    RoundedRectangle(cornerRadius: 12, style: .continuous).fill(hovering ? TFColor.bgSelected : .clear)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, -TFSpace.sm)
            .onHover { hovering = $0 }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityValue(isOpen ? "Expanded" : "Collapsed")
            if isOpen {
                VStack(alignment: .leading, spacing: TFSpace.sm) { content }
                    .padding(EdgeInsets(top: 6, leading: 0, bottom: 12, trailing: 0))
            }
        }
    }
}

#Preview("Disclosure") {
    VStack(alignment: .leading, spacing: 2) {
        Disclosure(icon: .checks, summary: "2 of 3 required checks passed", meta: "Required layout check unverified", defaultOpen: true) {
            Card(title: "Required checks") { CardText("Layout check · unverified", afterTitle: true) }
        }
        Disclosure(icon: .project, summary: "Shape launch", meta: "Project · Auto-linked") {
            Card { CardText("Same Notion database as the other launch notes.") }
        }
    }
    .padding(16)
    .frame(width: 380)
    .background(TFColor.bgPanel)
}
