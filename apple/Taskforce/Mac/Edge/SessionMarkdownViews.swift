#if os(macOS)
import AppKit
import SwiftUI
import TaskforceKit
import TaskforceUI

// 답의 글 표시 (DZ oa-session-view-dz v2 E1 · E4, 사용자 승인 "안전한 부분만 그림"): 코드 블록(복사 · 긴 것은 열 줄 + Show all) · 인라인 코드 · 목록 · 굵게 · 제목(굵기만).
// 파서는 Kit `SafeMarkdown`이고 링크 · 첨부를 담을 자리가 없다. 여기서도 시스템의 마크다운 해석(`AttributedString(markdown:)` · `LocalizedStringKey`)을 쓰지 않는다:
// 글은 `AttributedString(String)`(해석 없음)에 글꼴 · 바탕만 입힌다. 링크 속성은 어디서도 만들지 않는다 (시험이 모든 조각의 `link == nil`을 본다).

/// `SafeMarkdown`의 인라인을 보이는 글로 (순수 함수: 시험이 링크 · 첨부가 없음을 본다)
enum SessionMarkdownRender {
    /// - bold: 제목(굵기만 바뀌고 크기는 그대로)이면 모든 글이 굵다
    static func attributed(_ inlines: [SafeMarkdown.Inline], bold: Bool = false) -> AttributedString {
        var out = AttributedString()
        for inline in inlines {
            switch inline {
            case .text(let text):
                var piece = AttributedString(text)
                if bold { piece.font = TFFont.calloutEmphasis }
                out += piece
            case .code(let text):
                var piece = AttributedString(text)
                piece.font = TFFont.monoInline
                piece.backgroundColor = TFColor.bgField
                out += piece
            case .bold(let inner):
                out += attributed(inner, bold: true)
            }
        }
        return out
    }

    /// 목록 항목 앞의 표지: 점 또는 번호
    static func marker(_ item: SafeMarkdown.ListItem, ordered: Bool, position: Int) -> String {
        ordered ? "\(item.number ?? position)." : "•"
    }
}

/// 같은 글을 다시 해석하지 않는다 (화면은 글이 그대로여도 몇 번씩 다시 그려진다: 1초 시계 · 스크롤 · 호버). 해석은 순수 함수라 원문이 열쇠다. 메모리에만, `capacity`개까지 (오래된 것부터 버린다). 계정이 떠나면 비운다
@MainActor
final class SessionMarkdownCache {
    static let shared = SessionMarkdownCache()
    static let capacity = 128

    private var parsed: [String: [SafeMarkdown.Block]] = [:]
    private var order: [String] = []
    /// 해석한 횟수 (시험이 센다)
    private(set) var parses = 0

    func blocks(for source: String) -> [SafeMarkdown.Block] {
        if let hit = parsed[source] { return hit }
        parses += 1
        let blocks = SafeMarkdown.parse(source)
        parsed[source] = blocks
        order.append(source)
        if order.count > Self.capacity { parsed[order.removeFirst()] = nil }
        return blocks
    }

    func removeAll() {
        parsed = [:]
        order = []
    }
}

/// 답의 글. 문단 사이 8 · 블록 사이 8 · 목록 항목 사이 4 · 들여쓰기 20 (E1). 글은 callout 15/21, 선택 · 복사 가능.
/// 말풍선 안에서는(`Message`가 켠 `messageHugsText`) 글 폭에 맞춘다 (전폭으로 늘리지 않는다)
struct SessionMarkdownView: View {
    let source: String
    @Environment(\.messageHugsText) private var hugs

    var body: some View {
        let blocks = SessionMarkdownCache.shared.blocks(for: source)
        filling(
            VStack(alignment: .leading, spacing: TFSpace.sm) {
                ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                    switch block {
                    case .paragraph(let inlines): paragraph(inlines)
                    case .heading(let inlines): paragraph(inlines, bold: true)
                    case .code(let language, let text): SessionCodeBlockView(label: language, text: text)
                    case .list(let ordered, let items): list(items, ordered: ordered)
                    }
                }
            }
        )
    }

    /// 말풍선이 아니면 줄 폭을 채운다
    @ViewBuilder
    private func filling<Content: View>(_ content: Content) -> some View {
        if hugs { content } else { content.frame(maxWidth: .infinity, alignment: .leading) }
    }

    private func paragraph(_ inlines: [SafeMarkdown.Inline], bold: Bool = false) -> some View {
        filling(
            Text(SessionMarkdownRender.attributed(inlines, bold: bold))
                .font(TFFont.callout)
                .tracking(-0.24)
                .lineSpacing(3)
                .foregroundStyle(TFColor.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        )
    }

    private func list(_ items: [SafeMarkdown.ListItem], ordered: Bool) -> some View {
        VStack(alignment: .leading, spacing: TFSpace.xs) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    Text(SessionMarkdownRender.marker(item, ordered: ordered, position: index + 1))
                        .font(TFFont.callout)
                        .monospacedDigit()
                        .foregroundStyle(TFColor.textPrimary)
                        .frame(width: 20, alignment: .leading)
                        .accessibilityHidden(true)
                    paragraph(item.inlines)
                }
                .padding(.leading, CGFloat(item.depth) * 20)
            }
        }
    }
}

/// 코드 블록 (E4): `bg/field` 면 · 모서리 8 · 머리 28(라벨 12/16 + 복사) · 코드 mono 12/18 · 문법 색 없음 · 줄바꿈으로 접는다.
/// 긴 것은 180(열 줄)에서 잘라 아래 36을 흐리게 하고 Show all / Show less. 복사는 늘 전체 (읽은 만큼)
struct SessionCodeBlockView: View {
    let label: String?
    let text: String
    /// 긴 것을 열 줄로 접나. 출력 꼬리는 옆줄이 스크롤하므로 접지 않는다
    var collapses = true
    @State private var expanded = false
    @State private var naturalHeight: CGFloat = 0

    static let collapsedHeight: CGFloat = 180
    static let fadeHeight: CGFloat = 36

    /// 접어야 하나: 본문의 원래 높이가 접은 높이를 넘는다
    static func isLong(naturalHeight: CGFloat) -> Bool { naturalHeight > collapsedHeight + 1 }

    var body: some View {
        let long = collapses && Self.isLong(naturalHeight: naturalHeight)
        let collapsed = long && !expanded
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                Text(label ?? "")
                    .font(TFFont.meta)
                    .foregroundStyle(TFColor.textSecondarySelected)
                    .lineLimit(1)
                Spacer(minLength: 0)
                SessionCopyButton(text: text, alwaysVisible: true, onField: true)
            }
            .padding(EdgeInsets(top: 0, leading: 12, bottom: 0, trailing: 4))
            .frame(height: 28)
            Text(text)
                .font(TFFont.mono)
                .lineSpacing(3.5)
                .foregroundStyle(TFColor.textPrimary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(EdgeInsets(top: 0, leading: 12, bottom: 12, trailing: 12))
                .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { naturalHeight = $0 }
                .frame(maxHeight: collapsed ? Self.collapsedHeight : nil, alignment: .top)
                .clipped()
                .mask {
                    VStack(spacing: 0) {
                        Rectangle()
                        if collapsed { LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom).frame(height: Self.fadeHeight) }
                    }
                }
            if long {
                QuietLink(expanded ? SessionViewCopy.showLess : SessionViewCopy.showAll) { expanded.toggle() }
                    .padding(EdgeInsets(top: 0, leading: 6, bottom: 6, trailing: 0))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(TFColor.bgField, in: RoundedRectangle(cornerRadius: TFRadius.md, style: .continuous))
        .accessibilityElement(children: .contain)
    }
}
#endif
