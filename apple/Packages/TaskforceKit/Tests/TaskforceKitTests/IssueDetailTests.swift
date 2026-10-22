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

    // MARK: 끝남 표시가 남은 이슈를 id로 읽기 (다시 켠 뒤 링을 되살린다)

    /// 상태와 제목이 다른 행 하나 (RLS `actions` 행 그대로)
    private static func detail(status: String, title: String) throws -> ActionDetail {
        let record = try TaskforceJSON.decoder().decode(ActionRecord.self, from: Data("""
        {"id":"a0000000-0000-4000-8000-000000000001","title":"\(title)","scope_summary":null,"owner":"me","counterpart":null,"due_date":null,"status":"\(status)",
         "needs_confirmation":false,"confirm_reasons":[],"started_at":null,"last_activity_at":"2026-10-14T01:00:00.000Z","created_at":"2026-10-13T01:00:00.000Z","number":139}
        """.utf8))
        return ActionDetail(action: record, evidence: [], sources: [:], events: [])
    }

    #if os(macOS)
    @Test func aDoneIssueIsFinishedWithItsTitleAndAnOpenOneIsNot() async throws {
        let gateway = FakeIssueDetailGateway()
        let (store, scope) = makeStore(gateway)
        let lookup = FinishedIssueLookup(gateway: gateway, scope: scope)
        gateway.serve(try Self.detail(status: "done", title: "Privacy policy beta 1.4"))
        let finished = await lookup.read(Fx.issue(1))
        guard case .finished(let summary) = finished else { Issue.record("not finished: \(finished)"); return }
        #expect(summary.title == "Privacy policy beta 1.4" && summary.status == .done && summary.id == UUID(uuidString: "a0000000-0000-4000-8000-000000000001"))
        gateway.serve(try Self.detail(status: "open", title: "Reopened"))
        #expect(await lookup.read(Fx.issue(1)) == .notFinished, "다시 열린 이슈의 끝남 표시는 쓸모없다")
        #expect(gateway.reads == [Fx.issue(1), Fx.issue(1)], "기존 RLS 읽기(`issueDetail`)를 id로 부른다")
        #expect(store.screen(for: Fx.issue(1)) == .blank, "상세 화면의 캐시에 넣지 않는다 (제목은 어디에도 저장하지 않는다)")
    }

    @Test func aCancelledOrDeletedIssueIsGone() async throws {
        let gateway = FakeIssueDetailGateway()
        let user = UUID()
        let scope = AccountScope(currentAccount: { user })
        let lookup = FinishedIssueLookup(gateway: gateway, scope: scope)
        gateway.serve(try Self.detail(status: "dropped", title: "Cancelled"))
        #expect(await lookup.read(Fx.issue(1)) == .gone, "취소(dropped)한 이슈는 끝난 일이 아니다")
        gateway.serve(nil)
        #expect(await lookup.read(Fx.issue(1)) == .gone, "서버에 없는 이슈(지워짐 · 남의 것)")
    }

    @Test func aFailedOrOfflineReadIsUnknownSoTheMarkIsKept() async throws {
        let gateway = FakeIssueDetailGateway()
        let user = UUID()
        let scope = AccountScope(currentAccount: { user })
        let lookup = FinishedIssueLookup(gateway: gateway, scope: scope)
        gateway.fail(Failure())
        #expect(await lookup.read(Fx.issue(1)) == .unknown)
        gateway.fail(URLError(.notConnectedToInternet))
        #expect(await lookup.read(Fx.issue(1)) == .unknown)
    }

    @Test func aSignedOutAccountOrOneThatLeftWhileReadingIsUnknown() async throws {
        let gateway = FakeIssueDetailGateway()
        gateway.serve(try Self.detail(status: "done", title: "A title"))
        let signedOut = FinishedIssueLookup(gateway: gateway, scope: AccountScope())
        #expect(await signedOut.read(Fx.issue(1)) == .unknown && gateway.reads.isEmpty, "로그인한 계정이 없으면 읽지도 않는다")
        let user = UUID()
        let scope = AccountScope(currentAccount: { user })
        let lookup = FinishedIssueLookup(gateway: gateway, scope: scope)
        let slow = Latch()
        gateway.hold(slow)
        let late = Task { await lookup.read(Fx.issue(1)) }
        #expect(await slow.waitForArrivals(1, timeout: .seconds(2)))
        scope.accountLeft()
        await slow.open()
        #expect(await late.value == .unknown, "읽는 사이 계정이 떠났으면 그 결과를 쓰지 않는다")
        // 읽는 사이 계정이 떠났는데 서버가 "없다"고 답해도 (다른 계정에서는 남의 이슈로 보인다) 표시를 버리라고 하지 않는다
        let scope2 = AccountScope(currentAccount: { user })
        let lookup2 = FinishedIssueLookup(gateway: gateway, scope: scope2)
        let slow2 = Latch()
        gateway.serve(nil)
        gateway.hold(slow2)
        let late2 = Task { await lookup2.read(Fx.issue(1)) }
        #expect(await slow2.waitForArrivals(1, timeout: .seconds(2)))
        scope2.accountLeft()
        await slow2.open()
        #expect(await late2.value == .unknown, "떠난 뒤에 온 '없다'는 쓰지 않는다")
    }
    #endif

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
