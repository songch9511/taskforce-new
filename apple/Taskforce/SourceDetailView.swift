import SwiftUI
import TaskforceKit

@MainActor
@Observable
final class SourceDetailModel {
    let sourceID: UUID
    private(set) var detail: SourceDetail?
    private(set) var text: SourceText?
    /// 이미 할 일의 근거로 쓰인 줄
    private(set) var evidenceLines: Set<Int> = []
    private(set) var loadError: String?
    private(set) var reporting = false
    var selection = LineSelection()
    var result: MissingReportResponse?
    var message: String?
    /// 겹쳐 부른 불러오기 중 마지막 것만 반영한다
    private var loadSequence = 0

    private let services: AppServices

    init(sourceID: UUID, services: AppServices) {
        self.sourceID = sourceID
        self.services = services
    }

    /// 할 일 도구 스냅샷은 읽을 글이 아니고, 읽는 중인 원문은 결과가 나오기 전이라 신고를 받지 않는다.
    var canReport: Bool {
        guard let summary = detail?.source.summary else { return false }
        return summary.kind != .task && (summary.processingStatus == .done || summary.processingStatus == .failed)
    }

    var selectedQuote: String? {
        guard let range = selection.range else { return nil }
        return text?.quote(lines: range)
    }

    var quoteTooLong: Bool {
        (selectedQuote?.utf16.count ?? 0) > SourceText.maxQuoteLength  // zod max는 UTF-16 길이
    }

    func load() async {
        loadSequence += 1
        let sequence = loadSequence
        do {
            let detail = try await services.reads.sourceDetail(id: sourceID)
            guard sequence == loadSequence else { return }
            let text = SourceText(detail.source.rawText)
            self.detail = detail
            self.text = text
            evidenceLines = text.lineIndexes(matching: detail.evidence.map(\.quote))
            loadError = nil
        } catch is CancellationError {
        } catch {
            guard sequence == loadSequence else { return }
            loadError = (error as? APIError)?.userMessage ?? "불러오지 못했어요."
        }
    }

    func tap(_ line: Int) {
        guard canReport, !reporting else { return }
        selection.tap(line)
    }

    /// 고른 줄을 원문 그대로 보내 빠진 할 일로 신고한다. 서버가 LLM을 불러 몇 초 걸린다.
    func report() async {
        guard let quote = selectedQuote, !quoteTooLong else { return }
        reporting = true
        defer { reporting = false }
        do {
            result = try await services.api.reportMissing(sourceID: sourceID, quote: quote)
            selection.clear()
            await load()
        } catch let error as APIError {
            if case .server(_, .rateLimited, _) = error {
                message = "짧은 시간에 신고가 많았어요. 잠시 뒤에 다시 해 주세요."
            } else {
                message = error.userMessage
            }
        } catch {
            message = error.localizedDescription
        }
    }
}

struct SourceDetailView: View {
    let route: SourceRoute
    let services: AppServices
    @State private var model: SourceDetailModel
    @State private var openAction: ActionRoute?

    init(route: SourceRoute, services: AppServices) {
        self.route = route
        self.services = services
        _model = State(initialValue: SourceDetailModel(sourceID: route.id, services: services))
    }

    var body: some View {
        Group {
            if let detail = model.detail, let text = model.text {
                content(detail, text)
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
        .navigationTitle(model.detail?.source.summary.title ?? "원문")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task { await model.load() }
        .navigationDestination(item: $openAction) { route in
            ActionDetailView(actionID: route.id, services: services)
        }
        .sheet(item: $model.result) { result in
            MissingResultSheet(result: result) {
                model.result = nil
                openAction = ActionRoute(id: result.action.id)
            }
            .presentationDetents([.medium])
        }
        .messageAlert($model.message)
    }

    private func content(_ detail: SourceDetail, _ text: SourceText) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    header(detail.source.summary)
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(text.lines) { line in
                            SourceLineRow(
                                line: line,
                                selected: model.selection.contains(line.index),
                                usedAsEvidence: model.evidenceLines.contains(line.index)
                            ) {
                                model.tap(line.index)
                            }
                            .id(line.index)
                        }
                    }
                }
                .padding()
            }
            .onAppear {
                // 근거를 눌러 들어왔으면 그 구절로
                guard let quote = route.focusQuote, let first = text.lineIndexes(matching: [quote]).min() else { return }
                proxy.scrollTo(first, anchor: .center)
            }
        }
        .safeAreaInset(edge: .bottom) {
            if model.selection.range != nil {
                reportBar
            }
        }
    }

    private func header(_ summary: SourceSummary) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Label(summary.kind.label, systemImage: summary.kind.symbolName)
                Text(DisplayDate.full(summary.occurredAt))
                if summary.processingStatus != .done {
                    StatusBadge(status: summary.processingStatus)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            if let url = summary.externalURL {
                Link(destination: url) {
                    Label("원본 열기", systemImage: "arrow.up.right.square")
                }
                .font(.caption)
            }
            if model.canReport {
                Text("빠진 할 일이 있으면 그 줄을 눌러 고르세요. 여러 줄이면 마지막 줄을 한 번 더 누르세요.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else if summary.processingStatus == .pending || summary.processingStatus == .processing {
                Text("아직 읽는 중이에요. 다 읽으면 빠진 할 일을 신고할 수 있어요.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if !model.evidenceLines.isEmpty {
                Label("노랗게 표시된 줄은 이미 할 일의 근거예요.", systemImage: "highlighter")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var reportBar: some View {
        HStack(spacing: 12) {
            if model.reporting {
                ProgressView().controlSize(.small)
                Text("할 일을 찾는 중이에요… 몇 초 걸려요.")
                    .font(.footnote)
                Spacer()
            } else {
                Button("취소") { model.selection.clear() }
                Spacer()
                if model.quoteTooLong {
                    Text("\(SourceText.maxQuoteLength)자까지 고를 수 있어요")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                Button {
                    Task { await model.report() }
                } label: {
                    Label("빠진 할 일로 신고", systemImage: "plus.circle")
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.selectedQuote == nil || model.quoteTooLong)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(.bar)
    }
}

/// 원문 한 줄. 누르면 선택 범위에 넣는다.
struct SourceLineRow: View {
    let line: SourceText.Line
    let selected: Bool
    let usedAsEvidence: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            Text(line.isBlank ? " " : line.text)
                .font(.callout)
                .underline(usedAsEvidence, color: .yellow)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 3)
                .padding(.horizontal, 6)
                .background(background, in: RoundedRectangle(cornerRadius: 4))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var background: Color {
        if selected { return Color.accentColor.opacity(0.22) }
        if usedAsEvidence { return Color.yellow.opacity(0.14) }
        return .clear
    }
}

extension MissingReportResponse: @retroactive Identifiable {
    public var id: UUID { action.id }
}

/// 신고 결과: 새로 추가했거나, 이미 있는 할 일이었거나 (이미 끝냈거나 지운 할 일일 수도 있다)
struct MissingResultSheet: View {
    let result: MissingReportResponse
    let onOpen: () -> Void
    @Environment(\.dismiss) private var dismiss

    /// 이미 있는 할 일인데 열려 있지 않음: 할 일 화면에서 다시 열 수 있다
    private var alreadyClosed: Bool {
        result.status == .alreadyTracked && result.action.status != .open
    }

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: result.status == .created ? "checkmark.circle.fill" : "equal.circle.fill")
                .font(.system(size: 44))
                .foregroundStyle(result.status == .created ? .green : .blue)
            Text(result.status == .created ? "추가했어요" : "이미 있는 할 일이에요")
                .font(.title3.weight(.semibold))
            Text(result.action.title)
                .multilineTextAlignment(.center)
            if alreadyClosed {
                Text("이미 끝냈거나 지운 할 일이에요. 다시 해야 하면 할 일 화면에서 다시 열 수 있어요.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            if result.status == .created {
                Text("놓친 걸 알려주셔서 고마워요. 다음엔 더 잘 찾을게요.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            HStack {
                Button("닫기") { dismiss() }
                    .buttonStyle(.bordered)
                Button("할 일 보기", action: onOpen)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        #if os(macOS)
        .frame(minWidth: 360)
        #endif
    }
}
