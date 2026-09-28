import Foundation
import Testing
@testable import TaskforceKit

struct SourceStackTests {
    @Test(arguments: [
        ("https://www.notion.so/abc", SourceKind.meeting, SourceService.notion),
        ("https://acme.notion.site/abc", .doc, .notion),
        ("https://acme.slack.com/archives/C1/p123", .message, .slack),
        ("https://mail.google.com/mail/u/0/#inbox/abc", .email, .gmail),
        ("https://meet.google.com/abc-defg-hij", .meeting, .googleMeet),
        ("https://docs.google.com/document/d/abc", .meeting, .googleMeet),
        ("https://docs.google.com/document/d/abc", .doc, .manual(.doc)),
        ("https://example.com/x", .note, .manual(.note)),
        ("https://notnotion.so/x", .note, .manual(.note)),
    ])
    func infersServiceFromLink(_ url: String, _ kind: SourceKind, _ expected: SourceService) {
        #expect(SourceService.infer(externalURL: URL(string: url), kind: kind) == expected)
    }

    @Test func noLinkIsManual() {
        #expect(SourceService.infer(externalURL: nil, kind: .email) == .manual(.email))
    }

    @Test func mediumStackShowsEachServiceOnce() {
        #expect(SourceStackLayout.medium([.notion, .slack, .notion]) == .init(icons: [.notion, .slack], more: 0))
        #expect(SourceStackLayout.medium([.notion, .slack, .gmail]) == .init(icons: [.notion, .slack, .gmail], more: 0))
    }

    @Test func mediumStackCollapsesFourOrMore() {
        let result = SourceStackLayout.medium([.notion, .slack, .gmail, .googleMeet, .manual(.note), .notion])
        #expect(result == .init(icons: [.notion, .slack, .gmail], more: 2))
    }

    @Test func smallStackCountsEveryOtherSource() {
        #expect(SourceStackLayout.small(others: []) == .init(icons: [], more: 0))
        #expect(SourceStackLayout.small(others: [.slack]) == .init(icons: [.slack], more: 0))
        #expect(SourceStackLayout.small(others: [.slack, .gmail]) == .init(icons: [.slack, .gmail], more: 0))
        // 외 5곳 = 아이콘 2 + "+3"
        #expect(SourceStackLayout.small(others: [.slack, .gmail, .notion, .slack, .googleMeet]) == .init(icons: [.slack, .gmail], more: 3))
        // 같은 서비스 두 곳: 아이콘 하나 + "+1"
        #expect(SourceStackLayout.small(others: [.notion, .notion]) == .init(icons: [.notion], more: 1))
    }

    // MARK: 근거 고르기

    func evidence(_ id: Int, source: UUID, quote: String, at seconds: TimeInterval) -> EvidenceRecord {
        EvidenceRecord(
            id: UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", id))!,
            actionID: Fixtures.actionID,
            sourceID: source,
            quote: quote,
            role: .created,
            createdAt: Date(timeIntervalSince1970: seconds)
        )
    }

    @Test func digestLeadsWithNewestAndListsOldestFirst() throws {
        let notionSource = try TaskforceJSON.decoder().decode([SourceSummary].self, from: Data(Fixtures.sourceRow.utf8))[0]
        let slackID = UUID()
        let manualID = UUID()
        let digest = EvidenceDigest(
            evidence: [
                evidence(3, source: slackID, quote: "월요일도 괜찮아요", at: 300),
                evidence(1, source: notionSource.id, quote: "금요일까지 보낼게요", at: 100),
                evidence(2, source: notionSource.id, quote: "금요일까지 보낼게요", at: 200),
                evidence(4, source: manualID, quote: "다음 주로", at: 400),
            ],
            sources: [notionSource.id: notionSource]
        )
        // 같은 원문 같은 구절은 한 번
        #expect(digest.lines.map(\.quote) == ["금요일까지 보낼게요", "월요일도 괜찮아요", "다음 주로"])
        #expect(digest.lines[0].service == .notion)
        #expect(digest.lines[0].sourceTitle == "주간 회의")
        #expect(digest.lead?.quote == "다음 주로")
        // 맨 앞 근거의 원문을 뺀 나머지, 처음 들어온 순서
        #expect(digest.otherSources == [.notion, .manual(.note)])
    }

    @Test func emptyDigest() {
        let digest = EvidenceDigest(evidence: [], sources: [:])
        #expect(digest.isEmpty && digest.lead == nil && digest.otherSources.isEmpty)
    }
}
