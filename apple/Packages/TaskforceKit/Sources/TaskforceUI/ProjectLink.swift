import SwiftUI
import TaskforceKit

/// ProjectLink (Organism): 이 대화 · 할 일이 어느 프로젝트에 속하는지, 왜, 바꾸기. 접힌 줄 `folder` 아이콘, 상태 줄 "Project · Set by you" · "Project · Auto-linked" · "Project · No clear link".
/// 열면 카드 둘: "Why this project"(이유)와 Project 행(팝업 버튼 + 바꾼 뒤 Undo). 사용자의 선택이 이긴다. 바꾸는 것은 정리뿐, 에이전트 접근은 바뀌지 않는다.
/// 확인되지 않은 후보(inferred)는 "Project · Not confirmed"로 접힌 줄에서 보이고, 열면 팝업 대신 Confirm / Dismiss: 사용자 선택처럼 꾸미지 않는다.
/// 보관된 범위는 읽기 전용(팝업 없이 한 줄), 요청이 진행 중이면 컨트롤이 막힌다. 안내(`message`)가 있으면 열어 둔다
public struct ProjectLink: View {
    let content: ProjectLinkContent
    let onChange: (UUID?) -> Void
    let onUndo: () -> Void
    let onConfirm: () -> Void
    let onDismiss: () -> Void
    /// 열어 둔 채로 시작 (디자인은 닫힘이 기본. 바꾼 뒤 · 안내가 있을 때는 이 값과 상관없이 열린다). 사진 · 시험용
    let initiallyOpen: Bool

    public init(
        content: ProjectLinkContent, onChange: @escaping (UUID?) -> Void, onUndo: @escaping () -> Void,
        onConfirm: @escaping () -> Void = {}, onDismiss: @escaping () -> Void = {}, initiallyOpen: Bool = false
    ) {
        self.initiallyOpen = initiallyOpen
        self.content = content
        self.onChange = onChange
        self.onUndo = onUndo
        self.onConfirm = onConfirm
        self.onDismiss = onDismiss
    }

    /// 대화 헤더 (명시적 선택만)
    public init(project: ChatProject, onChange: @escaping (UUID?) -> Void, onUndo: @escaping () -> Void) {
        self.init(content: project.content, onChange: onChange, onUndo: onUndo)
    }

    public var body: some View {
        // 바꾼 뒤 · 안내가 있을 때는 열어 둔다: Undo · 안내가 보이게 (디자인 README)
        Disclosure(icon: .project, summary: content.name, meta: content.meta, defaultOpen: initiallyOpen || content.canUndo || content.message != nil) {
            Card(title: "Why this project") { CardText(content.reason, afterTitle: true) }
            Card {
                HStack(spacing: TFSpace.sm) {
                    Text(ChatCopy.projectLabel)
                        .font(TFFont.footnote)
                        .foregroundStyle(TFColor.textPrimary)
                    Spacer(minLength: 0)
                    trailing
                }
                .padding(EdgeInsets(top: TFSpace.sm, leading: TFSpace.md, bottom: TFSpace.sm, trailing: TFSpace.md))
                .frame(minHeight: SettingsTray.rowMinHeight)
                if let message = content.message {
                    Text(message)
                        .font(TFFont.meta)
                        .foregroundStyle(TFColor.statusOverdue)
                        .padding(EdgeInsets(top: 0, leading: TFSpace.md, bottom: TFSpace.sm, trailing: TFSpace.md))
                }
            }
        }
        .id("\(content.canUndo)-\(content.message ?? "")")
    }

    @ViewBuilder
    private var trailing: some View {
        if content.basis == .candidate {
            if let note = content.note {
                noteText(note)
            } else {
                Button(WorkProjectCopy.dismiss, action: onDismiss).buttonStyle(TFButtonStyle(.text)).disabled(content.isBusy)
                Button(WorkProjectCopy.confirm, action: onConfirm).buttonStyle(TFButtonStyle(.text)).disabled(content.isBusy)
            }
        } else {
            if content.canUndo {
                Button("Undo", action: onUndo).buttonStyle(TFButtonStyle(.text)).disabled(content.isBusy)
            }
            if content.choices.isEmpty {
                noteText(content.note ?? content.name)
            } else {
                SettingsPopup(
                    label: ChatCopy.projectLabel, selection: Optional(content.contextID), choices: content.choices.map { ($0.contextID, $0.name) },
                    isEnabled: !content.isBusy
                ) { choice in
                    if choice != content.contextID { onChange(choice) }
                }
            }
        }
    }

    private func noteText(_ text: String) -> some View {
        Text(text)
            .font(TFFont.footnote)
            .foregroundStyle(TFColor.textSecondary)
            .lineLimit(1)
            .truncationMode(.tail)
    }
}
