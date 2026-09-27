import SwiftUI
import TaskforceKit

@MainActor
@Observable
final class ActionDetailModel {
    let actionID: UUID
    private(set) var detail: ActionDetail?
    private(set) var history: [HistoryEntry] = []
    private(set) var loadError: String?
    private(set) var busy = false
    private(set) var handoff: HandoffResponse?
    var message: String?
    /// 고치기 시트가 닫힌 뒤에 보여줄 안내 (닫히는 중에 띄운 알림은 iOS가 버릴 수 있다)
    private var messageAfterSheet: String?
    /// 겹쳐 부른 불러오기 중 마지막 것만 반영한다
    private var loadSequence = 0

    private let services: AppServices

    init(actionID: UUID, services: AppServices) {
        self.actionID = actionID
        self.services = services
    }

    func load() async {
        loadSequence += 1
        let sequence = loadSequence
        do {
            let detail = try await services.reads.actionDetail(id: actionID)
            guard sequence == loadSequence else { return }
            self.detail = detail
            history = ActionHistory.entries(events: detail.events, evidence: detail.evidence, today: DueDateFormat.today())
            loadError = nil
        } catch is CancellationError {
        } catch {
            guard sequence == loadSequence else { return }
            loadError = (error as? APIError)?.userMessage ?? "불러오지 못했어요."
        }
    }

    func start() async { await act { try await $0.startAction(id: self.actionID) } }
    func complete() async { await act { try await $0.editAction(id: self.actionID, ActionEdit(status: .done)) } }
    func reopen() async { await act { try await $0.editAction(id: self.actionID, ActionEdit(status: .open)) } }
    func confirm() async { await act { try await $0.confirmAction(id: self.actionID) } }
    func delete() async { await act { try await $0.deleteAction(id: self.actionID) } }

    func save(_ edit: ActionEdit) async -> String? {
        do {
            _ = try await services.api.editAction(id: actionID, edit)
            await load()
            return nil
        } catch let error as APIError where error.isConflict {
            await load()
            messageAfterSheet = error.userMessage
            return nil
        } catch {
            return (error as? APIError)?.userMessage ?? error.localizedDescription
        }
    }

    func sheetDismissed() {
        guard let pending = messageAfterSheet else { return }
        messageAfterSheet = nil
        message = pending
    }

    /// AI에게 넘기기: 문서를 받아 바로 클립보드에 복사하고 공유 시트를 띄울 수 있게 둔다.
    func prepareHandoff() async {
        busy = true
        defer { busy = false }
        do {
            let response = try await services.api.handoff(id: actionID)
            Clipboard.copy(response.markdown)
            handoff = response
        } catch {
            message = (error as? APIError)?.userMessage ?? error.localizedDescription
        }
    }

    func dismissHandoff() {
        handoff = nil
    }

    private func act(_ call: (APIClient) async throws -> ActionSummary) async {
        busy = true
        defer { busy = false }
        do {
            _ = try await call(services.api)
        } catch let error as APIError {
            message = error.userMessage
        } catch {
            message = error.localizedDescription
        }
        await load()
    }
}

struct ActionDetailView: View {
    @State private var model: ActionDetailModel
    @State private var editing: EditTarget?
    @State private var confirmingDelete = false

    init(actionID: UUID, services: AppServices) {
        _model = State(initialValue: ActionDetailModel(actionID: actionID, services: services))
    }

    var body: some View {
        Group {
            if let detail = model.detail {
                content(detail)
            } else if let error = model.loadError {
                ContentUnavailableView {
                    Label("불러오지 못했어요", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error)
                } actions: {
                    Button("다시 시도") { Task { await model.load() } }
                }
            } else {
                ProgressView()
            }
        }
        .navigationTitle("할 일")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task { await model.load() }
        .refreshable { await model.load() }
        .sheet(item: $editing, onDismiss: { model.sheetDismissed() }) { target in
            EditActionSheet(target: target) { edit in await model.save(edit) }
        }
        .sheet(item: Binding(get: { model.handoff }, set: { if $0 == nil { model.dismissHandoff() } })) { handoff in
            HandoffSheet(handoff: handoff)
        }
        .confirmationDialog("이 할 일을 삭제할까요?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("삭제", role: .destructive) { Task { await model.delete() } }
        } message: {
            Text("근거와 이력은 남아요.")
        }
        .messageAlert($model.message)
    }

    private func content(_ detail: ActionDetail) -> some View {
        let action = detail.action
        return List {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text(action.title)
                        .font(.title3.weight(.semibold))
                    if action.status != .open {
                        Text(action.status.label)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(action.status == .done ? .green : .secondary)
                    }
                }
                .padding(.vertical, 2)
                if let scope = action.scopeSummary, !scope.isEmpty {
                    Text(scope)
                        .foregroundStyle(.secondary)
                }
                LabeledContent("담당", value: action.owner.label)
                LabeledContent("기한") {
                    if let due = action.dueDate {
                        Text(DueDateFormat.summary(due, today: DueDateFormat.today()))
                    } else {
                        Text("없음")
                    }
                }
                if let counterpart = action.counterpart {
                    LabeledContent("상대", value: counterpart)
                }
                if let started = action.startedAt {
                    LabeledContent("시작", value: DisplayDate.relative(started))
                }
            }

            if action.needsConfirmation || !action.confirmReasons.isEmpty {
                Section("확인이 필요해요") {
                    ForEach(action.confirmReasons, id: \.self) { reason in
                        Label(reason, systemImage: "questionmark.circle")
                            .foregroundStyle(.orange)
                    }
                    Button("맞아요") { Task { await model.confirm() } }
                        .disabled(model.busy)
                }
            }

            Section {
                actions(action)
            }

            Section("근거") {
                if detail.evidence.isEmpty {
                    Text("근거가 없어요.").foregroundStyle(.secondary)
                }
                ForEach(detail.evidence) { evidence in
                    NavigationLink(value: SourceRoute(id: evidence.sourceID, focusQuote: evidence.quote)) {
                        EvidenceRow(evidence: evidence, source: detail.sources[evidence.sourceID])
                    }
                }
            }

            Section("변경 이력") {
                ForEach(model.history) { entry in
                    if let sourceID = entry.sourceID {
                        NavigationLink(value: SourceRoute(id: sourceID, focusQuote: entry.quote)) {
                            HistoryRow(entry: entry)
                        }
                    } else {
                        HistoryRow(entry: entry)
                    }
                }
            }
        }
        #if os(iOS)
        .listStyle(.insetGrouped)
        #endif
    }

    @ViewBuilder
    private func actions(_ action: ActionRecord) -> some View {
        if action.status == .open {
            if action.startedAt == nil {
                Button {
                    Task { await model.start() }
                } label: {
                    Label("시작", systemImage: "play")
                }
            }
            Button {
                Task { await model.complete() }
            } label: {
                Label("완료", systemImage: "checkmark.circle")
            }
        } else {
            Button {
                Task { await model.reopen() }
            } label: {
                Label("다시 열기", systemImage: "arrow.uturn.backward")
            }
        }
        Button {
            editing = EditTarget(action)
        } label: {
            Label("고치기", systemImage: "pencil")
        }
        Button {
            Task { await model.prepareHandoff() }
        } label: {
            HStack {
                Label("AI에게 넘기기", systemImage: "sparkles")
                if model.busy {
                    Spacer()
                    ProgressView().controlSize(.small)
                }
            }
        }
        if action.status == .open {
            Button(role: .destructive) {
                confirmingDelete = true
            } label: {
                Label("삭제", systemImage: "trash")
            }
        }
    }
}

struct EvidenceRow: View {
    let evidence: EvidenceRecord
    let source: SourceSummary?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("“\(evidence.quote)”")
                .font(.callout)
                .lineLimit(6)
            if let source {
                Label {
                    Text([source.title ?? source.kind.label, DisplayDate.day(source.occurredAt)].joined(separator: " · "))
                } icon: {
                    Image(systemName: source.kind.symbolName)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

struct HistoryRow: View {
    let entry: HistoryEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(entry.actor == .ai ? "AI" : "나")
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(.quaternary, in: Capsule())
                Text(entry.sentence)
                    .font(.callout)
                Spacer(minLength: 8)
                Text(DisplayDate.relative(entry.date))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let quote = entry.quote {
                Text("“\(quote)”")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
        }
        .padding(.vertical, 2)
    }
}

extension HandoffResponse: @retroactive Identifiable {
    public var id: UUID { actionID }
}

/// AI에게 넘기기 결과: 이미 복사됨 + 공유
struct HandoffSheet: View {
    let handoff: HandoffResponse
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(handoff.markdown)
                    .font(.system(.footnote, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
            .safeAreaInset(edge: .top) {
                Label("복사했어요. AI 도구에 붙여 넣으세요.", systemImage: "doc.on.clipboard")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(8)
                    .background(.bar)
            }
            .navigationTitle("AI에게 넘기기")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("닫기") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    ShareLink(item: handoff.markdown, subject: Text(handoff.title)) {
                        Label("공유", systemImage: "square.and.arrow.up")
                    }
                }
                ToolbarItem {
                    Button {
                        Clipboard.copy(handoff.markdown)
                    } label: {
                        Label("다시 복사", systemImage: "doc.on.doc")
                    }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 480, minHeight: 420)
        #endif
    }
}
