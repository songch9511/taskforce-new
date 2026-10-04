import Foundation

/// M8 `Use` 칩 하나: 초안에 보낼 수 있는 원문
public struct DraftSource: Equatable, Sendable, Identifiable {
    public let id: UUID
    public let title: String
    public let service: SourceService

    public init(id: UUID, title: String, service: SourceService) {
        self.id = id
        self.title = title
        self.service = service
    }
}

/// M8 Run with AI의 `Use` 칩 (Figma 185:2561): 이 할 일의 근거 원문 중 초안 자료로 보낼 수 있는 것.
/// 서버(`src/lib/execution/store.ts` `loadMaterial` → `context.ts` `buildExecutionContext`)와 같은 순서 · 거르기 · 수다:
/// receipt가 아닌 근거 중 최근 40개(`EVIDENCE_LIMIT`)에서, 실행 receipt(원문 kind execution)와 Slack 원문(Slack 링크 · 연결을 끊어 지운 인용)을 빼고,
/// 원문마다 한 번, 6개까지 (`MAX_SOURCES`). 칩은 "보낼 수 있는 자료"이지 보낸 것의 증명이 아니다:
/// 출처를 확인할 수 없는 원문 · 원문에서 찾지 못한 구절 · 링크 없는 Slack 원문(앱은 연결 서비스를 읽지 않는다)은 서버가 더 뺀다 (`material.ts`).
public enum DraftSources {
    /// 서버 `context.ts` `MAX_SOURCES`
    public static let limit = 6
    /// 서버 `store.ts` `EVIDENCE_LIMIT` (receipt를 뺀 근거 중 최근 몇 개를 읽나)
    static let evidenceLimit = 40

    public static func make(evidence: [EvidenceRecord], sources: [UUID: SourceSummary]) -> [DraftSource] {
        var seen = Set<UUID>()
        var result: [DraftSource] = []
        let recentFirst = evidence.filter { $0.role != .executed }
            .sorted { ($0.createdAt, $0.id.uuidString) > ($1.createdAt, $1.id.uuidString) }
            .prefix(evidenceLimit)
        for record in recentFirst where result.count < limit {
            guard !record.quote.isEmpty, !RemovedQuote.isRemoved(record.quote),
                  let source = sources[record.sourceID], source.kind != .execution
            else { continue }
            let service = SourceService.infer(externalURL: source.externalURL, kind: source.kind)
            guard service != .slack, seen.insert(source.id).inserted else { continue }
            let title = (source.meeting?.title ?? source.title).flatMap(nonEmpty) ?? service.accessibilityName
            result.append(DraftSource(id: source.id, title: title, service: service))
        }
        return result
    }

    private static func nonEmpty(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
