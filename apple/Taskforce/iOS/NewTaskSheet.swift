#if os(iOS)
import SwiftUI
import TaskforceKit
import TaskforceUI

/// 직접 추가 (오른쪽 위 "+"): 제목 + 기한. 원문 없이 `POST /actions` (`NowStore.add`).
/// 쓰는 동안 열린 할 일(Review · In Progress · To Do)에서 맞는 것을 "Existing"으로 보여 줘 중복을 피하게 한다 (추가는 막지 않는다).
/// Figma에 없는 화면이라 Apple 기본 부품(Form)과 Taskforce 토큰으로만 구성한다.
struct NewTaskSheet: View {
    /// 추가된 뒤, 시트를 닫기 직전
    let onAdded: () -> Void

    @Environment(NowStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var due: DueChoice = .none
    @State private var pickedDate = Date()
    @State private var saving = false
    @State private var detent: PresentationDetent = .medium
    @FocusState private var titleFocused: Bool

    private enum DueChoice: CaseIterable {
        case none, today, tomorrow, date

        var label: String {
            switch self {
            case .none: "None"
            case .today: "Today"
            case .tomorrow: "Tomorrow"
            case .date: "Date…"
            }
        }
    }

    var body: some View {
        @Bindable var store = store
        NavigationStack {
            Form {
                Section {
                    TextField("Title", text: $title)
                        .focused($titleFocused)
                        .submitLabel(.done)
                        .onSubmit(add)
                        .disabled(saving)
                }
                if !duplicates.isEmpty {
                    Section("Existing") {
                        ForEach(duplicates) { duplicateRow($0) }
                    }
                }
                Section("Due") {
                    dueChoices
                    if due == .date {
                        DatePicker("Date", selection: $pickedDate, in: Calendar.current.startOfDay(for: Date())..., displayedComponents: .date)
                            .datePickerStyle(.graphical)
                            .labelsHidden()
                    }
                }
                .disabled(saving)
            }
            .navigationTitle("New Task")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(saving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if saving {
                        ProgressView()
                    } else {
                        Button("Add", action: add)
                            .disabled(cappedTitle.isEmpty)
                    }
                }
            }
            .messageAlert($store.addError)
        }
        .presentationDetents([.medium, .large], selection: $detent)
        // 중간 높이의 기본 시트 배경은 반투명이라 뒤의 목록 글자가 제목 칸에 비친다
        .presentationBackground(TFColor.bgCanvas)
        .interactiveDismissDisabled(saving)
        .onAppear { titleFocused = true }
        // 서버 제목 최대 길이(UTF-16)를 넘게 쓰지 못하게
        .onChange(of: title) { _, text in
            if text.utf16.count > LauncherAdd.maxTitleLength { title = LauncherAdd.capped(text) }
        }
    }

    private var cappedTitle: String { LauncherAdd.capped(title) }

    private var today: LocalDate { DueDateFormat.today() }

    /// 맞는 열린 할 일 세 개까지 (방금 완료한 것은 빼고 · 끝낸 할 일은 보지 않는다)
    private var duplicates: [ActionSummary] {
        Array(LauncherAdd.existing(matching: title, in: store.board.now).prefix(3))
    }

    private var dueDate: LocalDate? {
        switch due {
        case .none: nil
        case .today: today
        case .tomorrow: today.adding(days: 1)
        // 선택기는 기기 시간대로 날짜를 보여 준다 (Mac 런처와 같다)
        case .date: LocalDate(date: pickedDate, timeZone: .current)
        }
    }

    // MARK: 기한

    /// 한 줄에 다 들어가지 않으면 (좁은 화면 · 큰 글자) 두 줄로
    private var dueChoices: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: TFSpace.sm) { chips(DueChoice.allCases) }
            VStack(alignment: .leading, spacing: TFSpace.sm) {
                HStack(spacing: TFSpace.sm) { chips([.none, .today]) }
                HStack(spacing: TFSpace.sm) { chips([.tomorrow, .date]) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func chips(_ choices: [DueChoice]) -> some View {
        ForEach(choices, id: \.self) { choice in
            Button(choice.label) { choose(choice) }
                .buttonStyle(DueChipStyle(selected: due == choice))
                .accessibilityAddTraits(due == choice ? .isSelected : [])
        }
    }

    private func choose(_ choice: DueChoice) {
        withAnimation(.snappy(duration: 0.2)) { due = choice }
        if choice == .date {
            // 달력이 키보드에 가리지 않게
            titleFocused = false
            detent = .large
        }
    }

    // MARK: Existing

    private func duplicateRow(_ action: ActionSummary) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: TFSpace.md) {
            Text(action.title)
                .font(TFFont.callout)
                .foregroundStyle(TFColor.textPrimary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let dueDate = action.dueDate {
                Text(DueText.short(dueDate, today: today))
                    .font(TFFont.footnote)
                    .foregroundStyle(DueText.isOverdue(dueDate, today: today) ? TFColor.statusOverdue : TFColor.textSecondary)
                    .fixedSize()
            }
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: 추가

    private func add() {
        guard !saving, !cappedTitle.isEmpty else { return }
        saving = true
        Task {
            let added = await store.add(title: cappedTitle, due: dueDate)
            saving = false
            guard added else { return }
            onAdded()
            dismiss()
        }
    }
}

/// 기한 고르기 칩: 고른 것은 fill/inverse (Primary 캡슐), 나머지는 fill/secondary
private struct DueChipStyle: ButtonStyle {
    let selected: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(TFFont.callout.weight(.semibold))
            .foregroundStyle(selected ? TFColor.textInverse : TFColor.textPrimary)
            .lineLimit(1)
            .padding(.horizontal, TFSpace.md)
            .padding(.vertical, TFSpace.sm)
            .background(selected ? TFColor.fillInverse : TFColor.fillSecondary, in: Capsule())
            .contentShape(Capsule())
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}
#endif
