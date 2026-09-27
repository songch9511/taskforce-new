import SwiftUI
import TaskforceKit

/// 지금 할 일. 순서 · 이유는 서버가 정하고, 무엇이 바뀌든 `/now`를 다시 불러온다.
@MainActor
@Observable
final class NowModel {
    private(set) var response: NowResponse?
    private(set) var loading = false
    private(set) var loadError: String?
    private(set) var busy: Set<UUID> = []
    private(set) var deletingAccount = false
    var message: String?
    /// 고치기 시트가 닫힌 뒤에 보여줄 안내 (닫히는 중에 띄운 알림은 iOS가 버릴 수 있다)
    private var messageAfterSheet: String?
    /// 겹쳐 부른 불러오기 중 마지막 것만 반영한다 (늦게 온 옛 응답이 새 응답을 덮지 않게)
    private var loadSequence = 0

    private let services: AppServices

    init(services: AppServices) {
        self.services = services
    }

    func load() async {
        loadSequence += 1
        let sequence = loadSequence
        loading = true
        defer { if sequence == loadSequence { loading = false } }
        do {
            let response = try await services.api.now()
            guard sequence == loadSequence else { return }
            self.response = response
            loadError = nil
        } catch is CancellationError {
        } catch {
            guard sequence == loadSequence else { return }
            loadError = (error as? APIError)?.userMessage ?? error.localizedDescription
        }
    }

    func confirm(_ id: UUID) async { await act(id) { try await $0.confirmAction(id: id) } }
    /// 확인 요청에 "아니에요" = 삭제 (서버가 남은 확인 이유도 지운다)
    func reject(_ id: UUID) async { await act(id) { try await $0.deleteAction(id: id) } }
    func complete(_ id: UUID) async { await act(id) { try await $0.editAction(id: id, ActionEdit(status: .done)) } }
    func delete(_ id: UUID) async { await act(id) { try await $0.deleteAction(id: id) } }

    func save(_ id: UUID, _ edit: ActionEdit) async -> String? {
        do {
            _ = try await services.api.editAction(id: id, edit)
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

    func answerWeekly(_ answer: WeeklyCheckAnswer) async {
        guard let prompt = response?.weeklyCheck else { return }
        do {
            try await services.api.answerWeeklyCheck(weekStart: prompt.weekStart, answer: answer)
        } catch {
            message = (error as? APIError)?.userMessage ?? error.localizedDescription
        }
        await load()
    }

    /// 계정 삭제. 성공하면 true (세션 정리는 부르는 쪽이 한다), 실패하면 안내를 띄운다.
    func deleteAccount() async -> Bool {
        deletingAccount = true
        defer { deletingAccount = false }
        do {
            try await services.api.deleteAccount()
            return true
        } catch {
            let detail = (error as? APIError)?.userMessage ?? error.localizedDescription
            message = "계정을 삭제하지 못했어요. \(detail)"
            return false
        }
    }

    private func act(_ id: UUID, _ call: (APIClient) async throws -> ActionSummary) async {
        busy.insert(id)
        defer { busy.remove(id) }
        do {
            _ = try await call(services.api)
        } catch {
            message = (error as? APIError)?.userMessage ?? error.localizedDescription
        }
        await load()
    }
}

struct NowView: View {
    let services: AppServices
    let email: String?

    @Environment(SessionStore.self) private var session
    @Environment(ActionChangeFeed.self) private var changes
    @State private var model: NowModel
    @State private var editing: EditTarget?
    @State private var confirmingAccountDeletion = false

    init(services: AppServices, email: String?) {
        self.services = services
        self.email = email
        _model = State(initialValue: NowModel(services: services))
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("지금 할 일")
                .taskforceDestinations(services: services)
                .toolbar { toolbar }
                .refreshable { await model.load() }
                // 나타날 때마다, 그리고 Realtime 신호(MainTabs의 구독 하나)가 올 때마다
                .task(id: changes.revision) { await model.load() }
                .sheet(item: $editing, onDismiss: { model.sheetDismissed() }) { target in
                    EditActionSheet(target: target) { edit in await model.save(target.id, edit) }
                }
                .messageAlert($model.message)
                .confirmationDialog("계정을 삭제할까요?", isPresented: $confirmingAccountDeletion, titleVisibility: .visible) {
                    Button("계정 삭제", role: .destructive) {
                        Task {
                            if await model.deleteAccount() { await session.accountDeleted() }
                        }
                    }
                    Button("취소", role: .cancel) {}
                } message: {
                    Text("계정을 삭제하면 보낸 원문, 할 일, 변경 이력이 모두 지워지고 되돌릴 수 없어요.")
                }
        }
    }

    @ViewBuilder
    private var content: some View {
        if let response = model.response {
            if response.now.isEmpty && response.confirmations.isEmpty && response.weeklyCheck == nil {
                ContentUnavailableView(
                    "지금 할 일이 없어요",
                    systemImage: "checkmark.circle",
                    description: Text("회의록이나 메시지가 들어오면 할 일을 찾아 여기에 올려요.")
                )
            } else {
                list(response)
            }
        } else if let error = model.loadError {
            ContentUnavailableView {
                Label("불러오지 못했어요", systemImage: "wifi.exclamationmark")
            } description: {
                Text(error)
            } actions: {
                Button("다시 시도") { Task { await model.load() } }
            }
        } else {
            ProgressView()
        }
    }

    private func list(_ response: NowResponse) -> some View {
        List {
            if let error = model.loadError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
            if response.weeklyCheck != nil {
                Section {
                    WeeklyCheckCard { answer in Task { await model.answerWeekly(answer) } }
                }
            }
            if !response.confirmations.isEmpty {
                Section {
                    ForEach(response.confirmations) { action in
                        ConfirmationRow(
                            action: action,
                            busy: model.busy.contains(action.id),
                            onConfirm: { Task { await model.confirm(action.id) } },
                            onReject: { Task { await model.reject(action.id) } },
                            onEdit: { editing = EditTarget(action) }
                        )
                    }
                } header: {
                    Text("확인해 주세요")
                } footer: {
                    Text("AI가 확신하지 못한 것만 물어봐요.")
                }
            }
            Section {
                if response.now.isEmpty {
                    Text("확인된 할 일이 없어요.")
                        .foregroundStyle(.secondary)
                }
                ForEach(response.now) { ranked in
                    NavigationLink(value: ActionRoute(id: ranked.id)) {
                        NowRow(ranked: ranked)
                    }
                    .disabled(model.busy.contains(ranked.id))
                    .swipeActions(edge: .leading) {
                        Button {
                            Task { await model.complete(ranked.id) }
                        } label: {
                            Label("완료", systemImage: "checkmark")
                        }
                        .tint(.green)
                    }
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            Task { await model.delete(ranked.id) }
                        } label: {
                            Label("삭제", systemImage: "trash")
                        }
                    }
                }
            } header: {
                if !response.confirmations.isEmpty || response.weeklyCheck != nil {
                    Text("지금 할 일")
                }
            }
        }
        #if os(iOS)
        .listStyle(.insetGrouped)
        #endif
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        #if os(macOS)
        ToolbarItem {
            Button {
                Task { await model.load() }
            } label: {
                Label("새로고침", systemImage: "arrow.clockwise")
            }
            .disabled(model.loading)
        }
        #endif
        ToolbarItem(placement: .primaryAction) {
            Menu {
                if let email {
                    Text(email)
                }
                Button("로그아웃", role: .destructive) {
                    Task { await session.signOut() }
                }
                Button("계정 삭제", role: .destructive) {
                    confirmingAccountDeletion = true
                }
                .disabled(model.deletingAccount)
            } label: {
                Label("계정", systemImage: "person.crop.circle")
            }
        }
    }
}

/// 지금 할 일 한 줄: 제목, 이유 칩, 기한 · 상대
struct NowRow: View {
    let ranked: RankedAction

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(ranked.action.title)
                .font(.body)
            if !ranked.reasons.isEmpty {
                HStack(spacing: 4) {
                    ForEach(ranked.reasons, id: \.self) { ReasonChip(reason: $0) }
                }
            }
            HStack(spacing: 12) {
                if let due = ranked.action.dueDate {
                    DueLabel(due: due)
                }
                if let counterpart = ranked.action.counterpart {
                    Label(counterpart, systemImage: "person")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.caption)
        }
        .padding(.vertical, 2)
    }
}

/// 확인 요청 한 줄: 무엇을 확인해야 하는지 + 맞아요 / 아니에요 / 고치기
struct ConfirmationRow: View {
    let action: ActionSummary
    let busy: Bool
    let onConfirm: () -> Void
    let onReject: () -> Void
    let onEdit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            NavigationLink(value: ActionRoute(id: action.id)) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(action.title)
                    if !action.confirmReasons.isEmpty {
                        Text(ConfirmReasonText.userFacing(action.confirmReasons).joined(separator: " · "))
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    HStack(spacing: 12) {
                        Label(action.owner.label, systemImage: "person")
                        if let due = action.dueDate {
                            DueLabel(due: due)
                        } else {
                            Label("기한 없음", systemImage: "calendar")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
            HStack {
                Button("맞아요", action: onConfirm)
                    .buttonStyle(.borderedProminent)
                Button("아니에요", role: .destructive, action: onReject)
                    .buttonStyle(.bordered)
                Button("고치기", action: onEdit)
                    .buttonStyle(.bordered)
                if busy {
                    ProgressView().controlSize(.small)
                }
            }
            .controlSize(.small)
            .disabled(busy)
        }
        .padding(.vertical, 4)
    }
}

/// 주간 질문 (PRD 지표 5: 그림자 목록)
struct WeeklyCheckCard: View {
    let onAnswer: (WeeklyCheckAnswer) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("이번 주 질문", systemImage: "questionmark.bubble")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text("Taskforce 밖에 따로 적어둔 할 일이 있나요?")
                .font(.headline)
            HStack {
                Button("있어요") { onAnswer(.yes) }
                    .buttonStyle(.bordered)
                Button("없어요") { onAnswer(.no) }
                    .buttonStyle(.bordered)
                Spacer()
                Button("건너뛰기") { onAnswer(.skipped) }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
            }
            .controlSize(.small)
        }
        .padding(.vertical, 4)
    }
}
