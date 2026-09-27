import SwiftUI
import TaskforceKit

@MainActor
@Observable
final class SourcesModel {
    private(set) var sources: [SourceSummary]?
    private(set) var loadError: String?

    /// 겹쳐 부른 불러오기 중 마지막 것만 반영한다
    private var loadSequence = 0

    private let services: AppServices

    init(services: AppServices) {
        self.services = services
    }

    func load() async {
        loadSequence += 1
        let sequence = loadSequence
        do {
            let sources = try await services.reads.recentSources()
            guard sequence == loadSequence else { return }
            self.sources = sources
            loadError = nil
        } catch is CancellationError {
        } catch {
            guard sequence == loadSequence else { return }
            loadError = (error as? APIError)?.userMessage ?? "불러오지 못했어요."
        }
    }
}

/// 최근 원문 목록. 원문을 열어 빠진 할 일을 신고할 수 있다.
struct SourcesView: View {
    let services: AppServices
    @State private var model: SourcesModel

    init(services: AppServices) {
        self.services = services
        _model = State(initialValue: SourcesModel(services: services))
    }

    var body: some View {
        NavigationStack {
            Group {
                if let sources = model.sources {
                    if sources.isEmpty {
                        ContentUnavailableView(
                            "아직 원문이 없어요",
                            systemImage: "doc.text",
                            description: Text("회의록 · 메시지 · 메일이 들어오면 여기에 쌓여요.")
                        )
                    } else {
                        List(sources) { source in
                            NavigationLink(value: SourceRoute(id: source.id)) {
                                SourceRow(source: source)
                            }
                        }
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
            .navigationTitle("원문")
            .taskforceDestinations(services: services)
            .refreshable { await model.load() }
            .task { await model.load() }
            #if os(macOS)
            .toolbar {
                ToolbarItem {
                    Button {
                        Task { await model.load() }
                    } label: {
                        Label("새로고침", systemImage: "arrow.clockwise")
                    }
                }
            }
            #endif
        }
    }
}

struct SourceRow: View {
    let source: SourceSummary

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: source.kind.symbolName)
                .foregroundStyle(.secondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 3) {
                Text(source.title ?? source.kind.label)
                    .lineLimit(2)
                HStack(spacing: 6) {
                    Text(source.kind.label)
                    Text(DisplayDate.full(source.occurredAt))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if source.processingStatus != .done {
                StatusBadge(status: source.processingStatus)
            }
        }
        .padding(.vertical, 2)
    }
}

struct StatusBadge: View {
    let status: ProcessingStatus

    var body: some View {
        Text(status.label)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .foregroundStyle(status == .failed ? Color.red : Color.secondary)
            .background((status == .failed ? Color.red : Color.secondary).opacity(0.12), in: Capsule())
    }
}
