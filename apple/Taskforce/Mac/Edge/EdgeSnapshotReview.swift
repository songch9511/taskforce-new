#if os(macOS) && DEBUG
import AppKit
import TaskforceKit

/// Review 페이지 상태 PNG (S4): `-TF_EDGE_SHELL YES -TF_S4 YES -TFSampleData -TFEdgeSnapshot <폴더> -TFEdgeSnapshotReview` (+ `-TF_S3B YES`로 범위 이름, `-TFSnapshotDark`).
/// 견본 확인 요청 몇 개로 큐를 짜고(서버 순서: 오래된 것이 앞) 가짜 답 서버(`SampleReviewServer`)로 보내는 중 · 충돌 · 응답 유실을 담는다.
/// 렌더된 fixture일 뿐이다: 실제 서버 · 계정 · AI 호출이 없다.
@MainActor
enum ReviewSnapshot {
    /// 견본의 이 번호(`SampleData.id`)들을 확인 요청 큐로 만든다. 제목이 길고(10) · 범위가 둘(12) · 후보뿐(14)인 것처럼 S3b 견본 멤버십이 있는 할 일을 고른다
    static let queue = [14, 10, 12, 21]

    static func line(_ quote: String, _ title: String?, _ service: SourceService, ago: TimeInterval, url: String? = "https://example.com/sample") -> EvidenceLine {
        EvidenceLine(
            id: UUID(), quote: quote, sourceID: UUID(), sourceTitle: title, occurredAt: Date(timeIntervalSinceNow: -ago),
            externalURL: url.flatMap(URL.init(string:)), service: service
        )
    }

    /// 견본 목록의 확인 요청을 이 번호들로 바꾼다 (서버 순서 = 주어진 순서, 마지막이 가장 새 항목)
    static func setQueue(
        _ now: NowStore, _ numbers: [Int], evidence extra: [Int: [EvidenceLine]] = [:], titles: [Int: String] = [:], reasons: [Int: [String]] = [:]
    ) {
        let all = SampleData.now
        let known = Dictionary(uniqueKeysWithValues: (all.now.map(\.action) + all.confirmations).map { ($0.id, $0) })
        let base = Date(timeIntervalSinceNow: -3_600)
        let reviews: [ActionSummary] = numbers.enumerated().compactMap { index, number in
            guard let source = known[SampleData.id(number)] else { return nil }
            return ActionSummary(
                id: source.id, title: titles[number] ?? source.title, owner: .me, status: .open, dueDate: source.dueDate, counterpart: nil,
                needsConfirmation: true, confirmReasons: reasons[number] ?? (source.confirmReasons.isEmpty ? ["기한 확인"] : source.confirmReasons),
                startedAt: nil, lastActivityAt: base.addingTimeInterval(Double(index) * 60)
            )
        }
        let taken = Set(numbers.map(SampleData.id))
        var evidence = SampleData.evidence
        for (number, lines) in extra { evidence[SampleData.id(number)] = EvidenceDigest(lines: lines) }
        now.applySample(
            NowResponse(now: all.now.filter { !taken.contains($0.id) }, confirmations: reviews, weeklyCheck: nil, tracksChanges: true),
            doneToday: SampleData.doneToday, evidence: evidence
        )
    }

    static let baseEvidence: [Int: [EvidenceLine]] = [
        14: [line("데모 환경은 목요일까지 올려 둘게요", "#eng · 지훈", .slack, ago: 7_200, url: "https://acme.slack.com/sample")],
        12: [line("디자인 파일은 금요일 오전에 공유드릴게요", "디자인 싱크 회의록", .notion, ago: 90_000, url: "https://www.notion.so/sample")],
    ]

    static func capture(_ edge: EdgeShellController, file: (String) -> URL, settle: () async -> Void) async {
        guard let now = edge.launcher.now, let desk = edge.shell.review else { return }
        let shell = edge.shell
        let server = SampleReviewServer()
        now.installSampleReview(server)
        func shoot(_ name: String) { EdgeSnapshot.capture(edge, to: file("review-\(name)")) }
        func id(_ n: Int) -> UUID { SampleData.id(n) }
        func reset() {
            server.scenario = .apply
            server.releaseHeld()
            now.resetSampleReview()
            now.applySampleOnline()
            desk.reset()
        }
        func queue(_ numbers: [Int] = Self.queue, evidence: [Int: [EvidenceLine]]? = nil, titles: [Int: String] = [:]) {
            setQueue(now, numbers, evidence: evidence ?? baseEvidence, titles: titles)
        }

        reset()
        queue()
        await settle()
        // 1) ⌘1: 가장 새 항목 (21: 원문 둘 · 범위 없음)
        shell.openNewestReview()
        await settle()
        shoot("newest-two-sources")
        // 2) 단계 점을 눌러 둘째(10): 긴 제목 + 범위 이름 (S3b 켜졌을 때)
        shell.openReview(itemID: id(10))
        await settle()
        shoot("long-title")
        // 3) 두 프로젝트(12): 하나로 합치지 않는다
        shell.openReview(itemID: id(12))
        await settle()
        shoot("two-projects")
        // 4) 후보뿐(14): 범위 이름을 붙이지 않는다
        shell.openReview(itemID: id(14))
        await settle()
        shoot("candidate-only")

        // 원문 상태: 지워짐 · 없음 · 읽지 못함 · 읽는 중
        queue(evidence: [14: [line(RemovedQuote.slackDisconnected, "#eng · 지훈", .slack, ago: 7_200, url: nil)]])
        shell.openReview(itemID: id(14))
        await settle()
        shoot("source-removed")
        queue(evidence: [14: []])
        await settle()
        shoot("source-none")
        queue(evidence: [:])
        now.applySampleEvidenceFailed([id(14)])
        await settle()
        shoot("source-failed")
        queue(evidence: [:])
        now.applySampleEvidenceFailed([])
        await settle()
        shoot("source-loading")

        // 하나 · 없음
        reset()
        queue([10])
        await settle()
        shell.openNewestReview()
        await settle()
        shoot("single")
        queue([])
        await settle()
        shoot("empty")

        // 보내는 중 → 서버가 받은 뒤 다음 항목
        reset()
        queue()
        await settle()
        server.scenario = .hang
        shell.openNewestReview()
        shell.answer(.confirm, for: id(21))
        await settle()
        shoot("sending")
        server.releaseHeld()
        await settle()
        shoot("after-answer-next")

        // 충돌 · 응답 유실 (항목은 그대로, 안내만)
        reset()
        queue()
        await settle()
        server.scenario = .conflict
        shell.openReview(itemID: id(12))
        shell.answer(.dismiss, for: id(12))
        try? await Task.sleep(for: .seconds(1.2))
        shoot("conflict")
        reset()
        queue()
        await settle()
        server.scenario = .loseResponse
        shell.openReview(itemID: id(12))
        shell.answer(.confirm, for: id(12))
        try? await Task.sleep(for: .seconds(1.2))
        shoot("unverified")
        // 다시 읽은 목록에서 그 항목이 사라졌다: 성공이라 하지 않고 안내만 남는다
        setQueue(now, [14, 10, 21], evidence: baseEvidence)
        await settle()
        shoot("unverified-gone")

        // 오프라인(받은 목록 그대로) · 목록 없이 오프라인 · 읽기 실패 · 읽는 중
        reset()
        queue()
        await settle()
        shell.openNewestReview()
        now.applySampleOffline(loadedAt: Date(timeIntervalSinceNow: -600), since: Date(timeIntervalSinceNow: -60))
        await settle()
        shoot("offline-with-list")
        reset()
        now.applySampleState(saved: nil, offlineSince: Date(timeIntervalSinceNow: -60), failedAt: nil)
        await settle()
        shoot("offline-no-list")
        reset()
        now.applySampleState(saved: nil, offlineSince: nil, failedAt: Date())
        await settle()
        shoot("failed-no-list")
        reset()
        now.applySampleState(saved: nil, offlineSince: nil, failedAt: nil)
        await settle()
        shoot("loading")

        // 순서가 바뀌어도 보던 항목은 그대로, 그 항목이 사라지면 뒤를 이은 항목
        reset()
        queue()
        await settle()
        shell.openReview(itemID: id(10))
        await settle()
        shoot("reorder-before")
        queue([12, 21, 10, 14])
        await settle()
        shoot("reorder-after")
        queue([12, 21, 14])
        await settle()
        shoot("removed-elsewhere")

        // 움직임 줄이기
        reset()
        queue()
        await settle()
        shell.openNewestReview()
        shell.reduceMotion = true
        await settle()
        shoot("reduce-motion")
        shell.reduceMotion = EdgeShellController.systemReduceMotion
        server.releaseHeld()
    }
}
#endif
