import Foundation
import Testing
@testable import TaskforceKit

/// 가짜 이슈 상세 서버
final class FakeIssueDetailGateway: IssueDetailGateway, @unchecked Sendable {
    struct Failure: Error {}

    private let lock = NSLock()
    private var _detail: ActionDetail?
    private var _failure: Error?
    private var _reads: [UUID] = []
    private var _hold: Latch?

    var reads: [UUID] { lock.withLock { _reads } }
    func serve(_ detail: ActionDetail?) { lock.withLock { _detail = detail } }
    func fail(_ error: Error?) { lock.withLock { _failure = error } }
    func hold(_ latch: Latch?) { lock.withLock { _hold = latch } }

    func issueDetail(id: UUID) async throws -> ActionDetail {
        let (detail, failure, latch) = lock.withLock { () -> (ActionDetail?, Error?, Latch?) in
            _reads.append(id)
            return (_detail, _failure, _hold)
        }
        if let latch { await latch.wait() }
        if let failure { throw failure }
        guard let detail else { throw APIError.server(status: 404, code: .notFound, message: "") }
        return detail
    }
}

/// 이슈 상세의 읽기 (M4): 번호와 근거 인용(Source). 인용은 원문 그대로, 가장 새 것이 먼저, 실행 receipt는 뺀다
@MainActor
struct IssueDetailTests {
    typealias Fx = SessionFx

    static let source1 = UUID(uuidString: "50000000-0000-4000-8000-000000000001")!
    static let source2 = UUID(uuidString: "50000000-0000-4000-8000-000000000002")!
    static let receipt = UUID(uuidString: "50000000-0000-4000-8000-000000000003")!

    private static func action(number: String = #","number":139"#) throws -> ActionRecord {
        try TaskforceJSON.decoder().decode(ActionRecord.self, from: Data("""
        {"id":"a0000000-0000-4000-8000-000000000001","title":"Rewrite pricing page copy","scope_summary":null,"owner":"me","counterpart":null,"due_date":null,"status":"open",
         "needs_confirmation":false,"confirm_reasons":[],"started_at":null,"last_activity_at":"2026-10-14T01:00:00.000Z","created_at":"2026-10-13T01:00:00.000Z"\(number)}
        """.utf8))
    }

    private static func source(_ id: UUID, kind: String, title: String, at: String, url: String?) throws -> SourceSummary {
        let link = url.map { #""\#($0)""# } ?? "null"
        return try TaskforceJSON.decoder().decode(SourceSummary.self, from: Data("""
        {"id":"\(id.uuidString.lowercased())","kind":"\(kind)","title":"\(title)","occurred_at":"\(at)","external_url":\(link),"created_at":"\(at)","processing_status":"done","meeting":null}
        """.utf8))
    }

    private static func detail(number: String = #","number":139"#, evidence: [(UUID, UUID, String, Double)] = []) throws -> ActionDetail {
        let records = evidence.enumerated().map { index, entry in
            EvidenceRecord(id: UUID(), actionID: Fx.issue(1), sourceID: entry.1, quote: entry.2, role: .created, createdAt: Fx.at(entry.3))
        }
        let sources: [SourceSummary] = [
            try source(source1, kind: "message", title: "#pricing", at: "2026-10-10T01:00:00.000Z", url: "https://acme.slack.com/archives/C1/p1"),
            try source(source2, kind: "meeting", title: "Pricing sync", at: "2026-10-12T01:00:00.000Z", url: "https://www.notion.so/x"),
            try source(receipt, kind: "execution", title: "Draft saved", at: "2026-10-13T01:00:00.000Z", url: "taskforce://artifacts/abc"),
        ]
        return ActionDetail(
            action: try action(number: number), evidence: records, sources: Dictionary(uniqueKeysWithValues: sources.map { ($0.id, $0) }), events: []
        )
    }

    private func makeStore(_ gateway: FakeIssueDetailGateway, user: UUID = UUID()) -> (IssueDetailStore, AccountScope) {
        let scope = AccountScope(currentAccount: { user })
        return (IssueDetailStore(gateway: gateway, scope: scope), scope)
    }

    // MARK: 내용

    @Test func theNumberAndTheSourcesComeFromTheDetailRead() async throws {
        let gateway = FakeIssueDetailGateway()
        gateway.serve(try Self.detail(evidence: [(UUID(), Self.source1, "Can the pricing copy ship before Thursday?", 10), (UUID(), Self.source2, "Ship by Thursday", 20)]))
        let (store, _) = makeStore(gateway)
        #expect(store.screen(for: Fx.issue(1)) == .blank)
        await store.load(Fx.issue(1))
        guard case .ready(let content) = store.screen(for: Fx.issue(1)) else { Issue.record("not ready"); return }
        #expect(content.number == 139)
        #expect(content.sources.map(\.quote) == ["Ship by Thursday", "Can the pricing copy ship before Thursday?"], "가장 새 인용이 먼저")
        #expect(content.hasSource && content.canShowAll && content.leadSource?.quote == "Ship by Thursday")
    }

    @Test func oneQuoteHasNoShowAllAndNoEvidenceHasNoSourceGroup() async throws {
        let gateway = FakeIssueDetailGateway()
        gateway.serve(try Self.detail(evidence: [(UUID(), Self.source1, "Only one", 10)]))
        let (store, _) = makeStore(gateway)
        await store.load(Fx.issue(1))
        guard case .ready(let one) = store.screen(for: Fx.issue(1)) else { Issue.record("not ready"); return }
        #expect(one.hasSource && !one.canShowAll)
        gateway.serve(try Self.detail(evidence: []))
        await store.load(Fx.issue(1))
        guard case .ready(let none) = store.screen(for: Fx.issue(1)) else { Issue.record("not ready"); return }
        #expect(!none.hasSource && !none.canShowAll && none.leadSource == nil, "직접 추가한 이슈는 Source 그룹이 없다")
    }

    @Test func anExecutionReceiptIsNotASourceQuote() async throws {
        let gateway = FakeIssueDetailGateway()
        gateway.serve(try Self.detail(evidence: [(UUID(), Self.receipt, "Draft saved", 30), (UUID(), Self.source1, "Real quote", 10)]))
        let (store, _) = makeStore(gateway)
        await store.load(Fx.issue(1))
        guard case .ready(let content) = store.screen(for: Fx.issue(1)) else { Issue.record("not ready"); return }
        #expect(content.sources.map(\.quote) == ["Real quote"])
    }

    @Test func aMissingNumberLeavesTheNumberEmpty() async throws {
        let gateway = FakeIssueDetailGateway()
        gateway.serve(try Self.detail(number: ""))
        let (store, _) = makeStore(gateway)
        await store.load(Fx.issue(1))
        guard case .ready(let content) = store.screen(for: Fx.issue(1)) else { Issue.record("not ready"); return }
        #expect(content.number == nil)
    }

    @Test func aSlackQuoteRemovedOnDisconnectKeepsItsExistingWords() async throws {
        let gateway = FakeIssueDetailGateway()
        gateway.serve(try Self.detail(evidence: [(UUID(), Self.source1, RemovedQuote.slackDisconnected, 10)]))
        let (store, _) = makeStore(gateway)
        await store.load(Fx.issue(1))
        guard case .ready(let content) = store.screen(for: Fx.issue(1)) else { Issue.record("not ready"); return }
        #expect(RemovedQuote.isRemoved(try #require(content.leadSource).quote))
    }

    // MARK: 읽기 상태

    @Test func failureOfflineAndGoneAreDifferentScreens() async throws {
        let gateway = FakeIssueDetailGateway()
        let (store, _) = makeStore(gateway)
        gateway.fail(Failure())
        await store.load(Fx.issue(1))
        #expect(store.screen(for: Fx.issue(1)) == .failed)
        gateway.fail(URLError(.notConnectedToInternet))
        await store.load(Fx.issue(2))
        #expect(store.screen(for: Fx.issue(2)) == .offline)
        gateway.fail(nil)
        gateway.serve(nil)
        await store.load(Fx.issue(3))
        #expect(store.screen(for: Fx.issue(3)) == .gone, "서버에 없는 이슈")
    }

    typealias Failure = FakeIssueDetailGateway.Failure

    @Test func retryAfterAFailureReads() async throws {
        let gateway = FakeIssueDetailGateway()
        gateway.fail(Failure())
        let (store, _) = makeStore(gateway)
        await store.load(Fx.issue(1))
        #expect(store.screen(for: Fx.issue(1)) == .failed)
        gateway.fail(nil)
        gateway.serve(try Self.detail())
        await store.load(Fx.issue(1))
        guard case .ready = store.screen(for: Fx.issue(1)) else { Issue.record("not ready"); return }
    }

    @Test func aFailureAfterAReadKeepsWhatWasRead() async throws {
        let gateway = FakeIssueDetailGateway()
        gateway.serve(try Self.detail())
        let (store, _) = makeStore(gateway)
        await store.load(Fx.issue(1))
        gateway.fail(Failure())
        await store.load(Fx.issue(1))
        guard case .ready(let content) = store.screen(for: Fx.issue(1)) else { Issue.record("not ready"); return }
        #expect(content.number == 139)
    }

    @Test func onlyTheLastStartedReadForAnIssueIsApplied() async throws {
        let gateway = FakeIssueDetailGateway()
        let slow = Latch()
        gateway.serve(try Self.detail(number: #","number":1"#))
        gateway.hold(slow)
        let (store, _) = makeStore(gateway)
        let first = Task { await store.load(Fx.issue(1)) }
        #expect(await slow.waitForArrivals(1, timeout: .seconds(2)))
        gateway.hold(nil)
        gateway.serve(try Self.detail(number: #","number":2"#))
        await store.load(Fx.issue(1))
        await slow.open()
        await first.value
        guard case .ready(let content) = store.screen(for: Fx.issue(1)) else { Issue.record("not ready"); return }
        #expect(content.number == 2)
    }

    @Test func aReadStartedForAnotherUserIsDroppedEvenWithoutALeaveNotice() async throws {
        final class Box: @unchecked Sendable { var user = UUID() }
        let box = Box()
        let gateway = FakeIssueDetailGateway()
        gateway.serve(try Self.detail())
        let slow = Latch()
        gateway.hold(slow)
        let store = IssueDetailStore(gateway: gateway, scope: AccountScope(currentAccount: { box.user }))
        let late = Task { await store.load(Fx.issue(1)) }
        #expect(await slow.waitForArrivals(1, timeout: .seconds(2)))
        box.user = UUID()
        await slow.open()
        await late.value
        #expect(store.screen(for: Fx.issue(1)) == .blank)
    }

    @Test func theAccountLeavingClearsEveryDetailAndDropsALateRead() async throws {
        let gateway = FakeIssueDetailGateway()
        gateway.serve(try Self.detail())
        let (store, scope) = makeStore(gateway)
        await store.load(Fx.issue(1))
        scope.accountLeft()
        #expect(store.screen(for: Fx.issue(1)) == .blank)
        let slow = Latch()
        gateway.hold(slow)
        let late = Task { await store.load(Fx.issue(1)) }
        #expect(await slow.waitForArrivals(1, timeout: .seconds(2)))
        scope.accountLeft()
        await slow.open()
        await late.value
        #expect(store.screen(for: Fx.issue(1)) == .blank)
    }
}
