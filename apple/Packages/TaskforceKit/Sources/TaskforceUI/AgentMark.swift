import SwiftUI
import TaskforceKit

/// AgentMark (0.2.0 디자인 시스템 Atoms): 세션이나 메시지가 속한 에이전트의 공식 마크. Taskforce · Claude Code · Codex.
/// - 공급된 파일을 그대로 쓴다 (Figma AgentMark 31:1578에서 내보낸 SVG, `Tokens.xcassets/agent`). 다시 그리거나 색을 바꾸거나 윤곽을 두르지 않는다:
///   Taskforce · Codex는 `text/primary` 잉크(template), Claude Code는 자기 주황 `#D97757`(original)
/// - `placeholder`는 마크가 정해지지 않았거나 공급된 파일이 없는 에이전트의 점선 `border/control` 둥근 사각형 (모르는 에이전트도 이것)
/// - 글자(glyph)이지 타일이 아니다: 에이전트 이름 옆에 둔다. 마크만으로 상태를 말하지 않는다
/// - 세션 행 · 세션 패널 머리 · Assistant 대상 메뉴(와 대상 알약)에만 쓴다. 20pt(기본), 대상 메뉴는 16pt, 칩 안은 12pt
public struct AgentMark: View {
    nonisolated public static let sizes: [CGFloat] = [20, 16, 12]

    let kind: AgentMarkKind
    let size: CGFloat

    public init(_ kind: AgentMarkKind, size: CGFloat = 20) {
        self.kind = kind
        self.size = size
    }

    nonisolated static func assetName(_ kind: AgentMarkKind) -> String? {
        switch kind {
        case .taskforce: "agent/taskforce"
        case .claudeCode: "agent/claude-code"
        case .codex: "agent/codex"
        case .placeholder: nil
        }
    }

    public var body: some View {
        Group {
            switch kind {
            case .taskforce, .codex:
                Image(Self.assetName(kind) ?? "", bundle: .module).resizable().interpolation(.high).foregroundStyle(TFColor.textPrimary)
            case .claudeCode:
                Image(Self.assetName(kind) ?? "", bundle: .module).resizable().interpolation(.high)
            case .placeholder:
                // 20pt 기준 `rx 4.5` · 1pt 점선(2 2)을 크기에 맞춰 줄인다
                let scale = size / 20
                RoundedRectangle(cornerRadius: 4.5 * scale, style: .continuous)
                    .inset(by: 0.5 * scale)
                    .stroke(TFColor.borderControl, style: StrokeStyle(lineWidth: scale, dash: [2 * scale, 2 * scale]))
            }
        }
        .frame(width: size, height: size)
        .accessibilityLabel(kind.accessibilityName)
    }
}

#Preview("AgentMark") {
    HStack(spacing: 16) {
        ForEach(AgentMarkKind.allCases, id: \.self) { kind in
            VStack(spacing: 8) {
                AgentMark(kind, size: 20)
                AgentMark(kind, size: 16)
                AgentMark(kind, size: 12)
            }
        }
    }
    .padding(16)
    .background(TFColor.bgPanel)
}
