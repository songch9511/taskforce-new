import SwiftUI
import TaskforceKit

/// ProjectIcon (0.2.0 디자인 시스템 Atoms, OA U2): 프로젝트의 Lucide 글리프 16pt, 선 1.75, `text/primary`. 풀 12종은 `ProjectIconName.pool`이고 풀 밖 이름은 folder.
/// `ungrouped`(점선 원) · `done-today`(체크 원)는 `text/secondary`로 고정된 조용한 아이콘이고 선택지가 아니다.
/// 장식이다: 이름이 늘 옆에 있어 접근성 트리에는 없다
public struct ProjectGlyph: View {
    public enum Kind: Equatable, Sendable {
        case project(ProjectIconName)
        case ungrouped
        case doneToday
    }

    let kind: Kind
    /// 눌렸거나 호버한 행 위의 조용한 아이콘은 `text/secondary-selected`
    let lit: Bool

    public init(_ kind: Kind, lit: Bool = false) {
        self.kind = kind
        self.lit = lit
    }

    public init(_ name: ProjectIconName) {
        self.init(.project(name))
    }

    nonisolated static func icon(for kind: Kind) -> TFIcon {
        switch kind {
        case .project(let name): .project(name)
        case .ungrouped: .ungrouped
        case .doneToday: .doneToday
        }
    }

    public var body: some View {
        Self.icon(for: kind).image()
            .foregroundStyle(isQuiet ? (lit ? TFColor.textSecondarySelected : TFColor.textSecondary) : TFColor.textPrimary)
            .accessibilityHidden(true)
    }

    private var isQuiet: Bool { kind == .ungrouped || kind == .doneToday }
}

#Preview("ProjectGlyph") {
    LazyVGrid(columns: Array(repeating: GridItem(.fixed(28)), count: 8), spacing: 10) {
        ForEach(ProjectIconName.pool + [.folder], id: \.self) { ProjectGlyph($0) }
        ProjectGlyph(.ungrouped)
        ProjectGlyph(.doneToday)
    }
    .padding(16)
    .background(TFColor.bgPanel)
}
