import SwiftUI
import TaskforceKit

/// 고치기 시트에 넘기는 지금 값
struct EditTarget: Identifiable {
    let id: UUID
    let title: String
    let due: LocalDate?
    let owner: ActionOwner

    init(_ action: ActionSummary) {
        id = action.id
        title = action.title
        due = action.dueDate
        owner = action.owner
    }

    init(_ action: ActionRecord) {
        id = action.id
        title = action.title
        due = action.dueDate
        owner = action.owner
    }
}

/// 제목 · 기한 · 담당 고치기. 바뀐 필드만 보낸다 (고친 것은 AI 오판 신호로 남는다).
struct EditActionSheet: View {
    let target: EditTarget
    /// 저장. 실패하면 시트에 보여줄 문구, 성공(또는 다시 불러와 닫아야 할 때)이면 nil
    let onSave: (ActionEdit) async -> String?

    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var hasDue: Bool
    @State private var due: Date
    @State private var owner: ActionOwner?
    @State private var saving = false
    @State private var error: String?

    init(target: EditTarget, onSave: @escaping (ActionEdit) async -> String?) {
        self.target = target
        self.onSave = onSave
        _title = State(initialValue: target.title)
        _hasDue = State(initialValue: target.due != nil)
        _due = State(initialValue: target.due.map(DisplayDate.pickerDate) ?? Date())
        _owner = State(initialValue: target.owner == .unknown ? nil : target.owner)
    }

    private var edit: ActionEdit {
        ActionEdit.changes(
            title: title,
            due: hasDue ? DisplayDate.localDate(from: due) : nil,
            owner: owner,
            from: (target.title, target.due, target.owner)
        )
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("할 일") {
                    TextField("제목", text: $title, axis: .vertical)
                        .lineLimit(1...4)
                }
                Section("기한") {
                    Toggle("기한 있음", isOn: $hasDue.animation())
                    if hasDue {
                        DatePicker("날짜", selection: $due, displayedComponents: .date)
                            .environment(\.locale, DisplayDate.korean)
                    }
                }
                Section {
                    Picker("담당", selection: $owner) {
                        if target.owner == .unknown {
                            Text("미정").tag(ActionOwner?.none)
                        }
                        Text("나").tag(ActionOwner?.some(.me))
                        Text("다른 사람").tag(ActionOwner?.some(.other))
                    }
                    .pickerStyle(.segmented)
                } header: {
                    Text("담당")
                } footer: {
                    Text("다른 사람 일로 바꾸면 지금 할 일에서 빠져요.")
                }
                if let error {
                    Section {
                        Text(error).foregroundStyle(.red)
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("고치기")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("취소") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if saving {
                        ProgressView()
                    } else {
                        Button("저장") { save() }
                            .disabled(edit.isEmpty)
                    }
                }
            }
            .interactiveDismissDisabled(saving)
        }
        #if os(macOS)
        .frame(minWidth: 380, minHeight: 360)
        #endif
    }

    private func save() {
        let edit = edit
        saving = true
        error = nil
        Task {
            let message = await onSave(edit)
            saving = false
            if let message {
                error = message
            } else {
                dismiss()
            }
        }
    }
}
