import SwiftUI
import TaskforceKit

/// ProjectLink (Organism): 이 대화가 어느 프로젝트에 속하는지, 왜, 바꾸기. 접힌 줄 `folder` 아이콘, 상태 줄 "Project · Set by you" · "Project · No clear link".
/// 열면 카드 둘: "Why this project"(이유)와 Project 행(팝업 버튼 + 바꾼 뒤 Undo). 사용자의 선택이 이긴다 (자동 연결 없음). 바꾸는 것은 정리뿐, 에이전트 접근은 바뀌지 않는다.
public struct ProjectLink: View {
    let project: ChatProject
    let onChange: (UUID?) -> Void
    let onUndo: () -> Void

    public init(project: ChatProject, onChange: @escaping (UUID?) -> Void, onUndo: @escaping () -> Void) {
        self.project = project
        self.onChange = onChange
        self.onUndo = onUndo
    }

    public var body: some View {
        // 바꾼 뒤에는 열어 둔다: Undo가 보이게 (디자인 README)
        Disclosure(icon: .project, summary: project.name, meta: "Project · \(project.basis.label)", defaultOpen: project.canUndo) {
            Card(title: "Why this project") { CardText(project.reason, afterTitle: true) }
            Card {
                HStack(spacing: TFSpace.sm) {
                    Text(ChatCopy.projectLabel)
                        .font(TFFont.footnote)
                        .foregroundStyle(TFColor.textPrimary)
                    Spacer(minLength: 0)
                    if project.canUndo {
                        Button("Undo", action: onUndo).buttonStyle(TFButtonStyle(.text))
                    }
                    SettingsPopup(
                        label: ChatCopy.projectLabel, selection: Optional(project.contextID), choices: project.choices.map { ($0.contextID, $0.name) }
                    ) { choice in
                        if choice != project.contextID { onChange(choice) }
                    }
                }
                .padding(EdgeInsets(top: TFSpace.sm, leading: TFSpace.md, bottom: TFSpace.sm, trailing: TFSpace.md))
                .frame(minHeight: SettingsTray.rowMinHeight)
                if let message = project.message {
                    Text(message)
                        .font(TFFont.meta)
                        .foregroundStyle(TFColor.statusOverdue)
                        .padding(EdgeInsets(top: 0, leading: TFSpace.md, bottom: TFSpace.sm, trailing: TFSpace.md))
                }
            }
        }
        .id(project.canUndo)
    }
}
