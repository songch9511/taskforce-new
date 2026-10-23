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

/// 같은 글을 다시 해석하지 않는다 (화면은 글이 그대로여도 몇 번씩 다시 그려진다: 1초 시계 · 스크롤 · 호버). 해석은 순수 함수라 원문이 열쇠다. 메모리에만, `capacity`개까지 (오래된 것부터 버린다).
/// 아주 큰 글(`maxSourceBytes` 넘음)은 판에 두지 않고 그때그때 해석한다 (열쇠 · 결과가 메모리를 크게 잡지 않게). 계정이 떠나면 비운다
@MainActor
final class SessionMarkdownCache {
    static let shared = SessionMarkdownCache()
    static let capacity = 128
    /// 이 크기(UTF-8 바이트)를 넘는 원문은 판에 두지 않는다
    static let maxSourceBytes = 64 << 10

    private var parsed: [String: [SafeMarkdown.Block]] = [:]
    private var order: [String] = []
    /// 해석한 횟수 (시험이 센다)
    private(set) var parses = 0
    /// 글 줄이 이 판을 찾은 횟수 = 마크다운 줄의 본문이 계산된 횟수 (시험이 센다: 가라앉은 화면은 늘지 않는다)
    private(set) var lookups = 0

    func blocks(for source: String) -> [SafeMarkdown.Block] {
        lookups += 1
        guard source.utf8.count <= Self.maxSourceBytes else {
            parses += 1
            return SafeMarkdown.parse(source)
        }
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

private struct SessionCodeBlockWidthKey: EnvironmentKey {
    static let defaultValue: CGFloat = 348
}

extension EnvironmentValues {
    /// 이 안의 코드 블록 면의 **바깥 폭**: 접을지(줄 수)를 정하는 한 줄 칸 수가 여기서 나온다. 패널 본문은 348(패널 380 − 양옆 16), 옆줄 꼬리는 그보다 훨씬 좁아 그쪽이 고쳐 건넨다
    var sessionCodeBlockWidth: CGFloat {
        get { self[SessionCodeBlockWidthKey.self] }
        set { self[SessionCodeBlockWidthKey.self] = newValue }
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
    @Environment(\.sessionCodeBlockWidth) private var blockWidth

    static let collapsedHeight: CGFloat = 180
    static let fadeHeight: CGFloat = 36
    /// 접지 않고 보이는 가장 긴 줄 수: mono 12 · 줄 높이 약 18 → 180에서 아래 여백 12를 뺀 안에 드는 줄 수 (`SessionPanelHangTests`가 실제로 그린 높이와 맞는지 잰다)
    static let maxRows = 9
    /// 패널(380 폭)의 코드 면 바깥 폭 (패널 380 − 본문 양옆 16) · 그 폭의 한 줄 칸 수. 칸 = mono 한 글자의 폭(7.2)
    static let panelBlockWidth: CGFloat = 348
    static let panelColumns = 48
    private static let columnWidth: CGFloat = 7.2

    /// 코드 면의 바깥 폭으로 한 줄에 들어가는 칸 수의 어림: (폭 − 안쪽 여백 12 × 2) ÷ 7.2에 3을 더해 **조금 넉넉히** 잡는다 (패널 348 → 48, 옆줄 꼬리 224 → 30).
    /// 어림이 넉넉하면 줄을 실제보다 적게 세어 못 접는 쪽(조금 더 길게 보임)으로 틀리고, 모자라면 접을 필요 없는 것을 접는다(끝이 흐려진 채 다 들어 있다): 앞쪽이 낫다
    static func columns(forBlockWidth width: CGFloat) -> Int {
        max(8, Int(((width - 24) / columnWidth + 0.001).rounded(.down)) + 3)
    }

    /// 동아시아 넓은 글자(한글 · 한자 · 가나 · 전각 · 이모지)인가: mono 한 글자의 두 칸을 차지한다 (실제로는 약 1.5칸이라 한국어는 조금 많이 세고, 그것이 위 어림과 맞는다)
    private static func isWide(_ character: Character) -> Bool {
        guard let value = character.unicodeScalars.first?.value else { return false }
        switch value {
        case 0x1100...0x115F, 0x2E80...0x303E, 0x3041...0x33FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xA000...0xA4CF, 0xAC00...0xD7A3, 0xF900...0xFAFF,
             0xFE30...0xFE6F, 0xFF00...0xFF60, 0xFFE0...0xFFE6, 0x1F300...0x1F64F, 0x1F680...0x1F6FF, 0x1F900...0x1F9FF, 0x1FA70...0x1FAFF, 0x20000...0x3FFFD:
            return true
        default:
            return false
        }
    }

    /// 한 줄이 차지하는 칸 수: 넓은 글자는 둘, 나머지는 하나
    static func displayColumns(of line: Substring) -> Int {
        line.reduce(0) { $0 + (isWide($1) ? 2 : 1) }
    }

    private static func rows(ofLine line: Substring, columns: Int) -> Int {
        max(1, (displayColumns(of: line) + columns - 1) / columns)
    }

    /// 글이 차지하는 줄 수 (줄바꿈 + 긴 줄의 접힌 줄바꿈). `columns`는 한 줄에 들어가는 칸 수 (`columns(forBlockWidth:)`)
    static func rows(of text: String, columns: Int = panelColumns) -> Int {
        let columns = max(1, columns)
        return text.split(separator: "\n", omittingEmptySubsequences: false).reduce(0) { $0 + rows(ofLine: $1, columns: columns) }
    }

    /// 접어야 하나 — **그리기 전에 글만 보고** 정한다. 그린 뒤의 높이로 정하면 줄이 처음엔 전체 높이로 서고 그다음 접히면서 높이가 두 번 바뀌어,
    /// 게으른 쌓기 · 맨 아래에 붙은 스크롤 · 창 높이 맞춤이 그 변화를 되먹임으로 따라가며 끝없이 다시 배치했다 (#187 핫픽스). 줄 수는 글과 코드 면의 폭에서 정해지므로 몇 번을 그려도 같다
    static func isLong(text: String, columns: Int = panelColumns) -> Bool {
        let columns = max(1, columns)
        var total = 0
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            total += rows(ofLine: line, columns: columns)
            if total > maxRows { return true }
        }
        return false
    }

    /// 접힌 동안 그리는 글: 보이는 열 줄 남짓만이다. 나머지는 180에서 잘려 보이지 않는데, 즉시 쌓기에서는 긴 블록 수백 줄을 한꺼번에 배치하는 비용이 줄을 그릴 때마다 든다 (열 때 몇 배).
    /// 잘라낸 뒤에도 보이는 쪽은 그대로다 (긴 줄의 보이지 않는 뒷부분도 칸으로 세어 자른다). 복사는 늘 전체 `text`
    static func visibleText(_ text: String, columns: Int = panelColumns) -> String {
        let columns = max(1, columns)
        let keep = maxRows + 2
        var lines: [Substring] = []
        var total = 0
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            lines.append(prefix(of: line, columns: columns * keep))
            total += rows(ofLine: line, columns: columns)
            if total >= keep { break }
        }
        return lines.joined(separator: "\n")
    }

    /// 줄의 앞쪽 `limit`칸어치
    private static func prefix(of line: Substring, columns limit: Int) -> Substring {
        var used = 0
        var end = line.startIndex
        for index in line.indices {
            let width = isWide(line[index]) ? 2 : 1
            if used + width > limit { break }
            used += width
            end = line.index(after: index)
        }
        return line[line.startIndex..<end]
    }

    var body: some View {
        let columns = Self.columns(forBlockWidth: blockWidth)
        let long = collapses && Self.isLong(text: text, columns: columns)
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
            Text(collapsed ? Self.visibleText(text, columns: columns) : text)
                .font(TFFont.mono)
                .lineSpacing(3.5)
                .foregroundStyle(TFColor.textPrimary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(EdgeInsets(top: 0, leading: 12, bottom: 12, trailing: 12))
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
