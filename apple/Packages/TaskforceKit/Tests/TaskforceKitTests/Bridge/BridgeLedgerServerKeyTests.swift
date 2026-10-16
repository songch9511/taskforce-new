#if os(macOS)
import Foundation
import Testing
@testable import TaskforceKit

/// View full의 원장 찾기 (OA D4a-17): 서버가 에이전트 글에 붙인 열쇠 `agent-message:<run_id>:<sha256 hex(bridge 사건 id)>`(`external_event_id`)로 이 Mac 원장의 전문을 찾는다.
/// 원장 표는 바꾸지 않는다 (`full_texts.event_id`를 해시해 맞춘다). 다른 계정의 원장(파티션) · 한 달 정리로 지워진 글 · 잘리지 않은 글은 없다 (nil)
struct BridgeLedgerServerKeyTests {
    private let t0 = BridgeTest.t0
    private let task1 = "7a5c0001-0000-4000-8000-000000000001"
    private let task2 = "7a5c0002-0000-4000-8000-000000000001"
    private let run = "77777777-0000-4000-8000-000000000001"

    // sha256을 따로 계산한 값 (`shasum -a 256`): 사건 id = `<task id>:<seq>`
    private let hashTask1Seq1 = "07b44db73cbff9e956592cd060ea709525d1ad330ffb1da6326a9811458ebec3"
    private let hashTask1Seq2 = "d0360d5db3b14f2a410694ca3520094ba71e35dea6ab96122553657118a311c0"
    private let hashTask2Seq1 = "4473bb126351dbd834675ee8c4d920b092e64097d7e27566edccf21c8414139c"

    private func ledger(_ directory: TempDirectory, clock: NowBox? = nil) throws -> BridgeLedger {
        let box = clock ?? NowBox(t0)
        return try BridgeLedger(directory: directory.appending("ledger"), now: { box.value })
    }

    // MARK: 열쇠

    @Test func theServerKeyIsAgentMessageRunAndTheSha256OfTheEventID() {
        #expect(BridgeLedger.serverKey(runID: run, eventID: "\(task1):1") == "agent-message:\(run):\(hashTask1Seq1)")
        #expect(BridgeLedger.serverKey(runID: run, eventID: "\(task1):2") == "agent-message:\(run):\(hashTask1Seq2)")
        #expect(BridgeLedger.serverKey(runID: run, eventID: "\(task2):1") == "agent-message:\(run):\(hashTask2Seq1)")
        // 서버는 UTF-8 바이트를 해시한다 (`convert_to(…, 'UTF8')`): 한글 사건 id도 같다 (독립 계산: printf '%s' '한글' | shasum -a 256)
        #expect(BridgeLedger.serverKey(runID: run, eventID: "한글") == "agent-message:\(run):bd87f9bb68b67d2fa1cb82b6751820e946d5b1316d25d5fd96512fb4be44a2a8")
    }

    @Test func aKeyThatIsNotAnAgentMessageKeyIsNotParsed() {
        let good = "agent-message:\(run):\(hashTask1Seq1)"
        #expect(BridgeLedger.parseServerKey(good)?.runID == run && BridgeLedger.parseServerKey(good)?.eventHash == hashTask1Seq1)
        for bad in [
            "", "agent-message", "agent-message:\(run)", "agent-message:\(run):zz", "agent-message:\(run):\(hashTask1Seq1.prefix(63))",
            "agent-question:\(run):\(hashTask1Seq1)", "message:\(run):\(hashTask1Seq1)", "agent-message::\(hashTask1Seq1)",
            "agent-message:\(run):\(hashTask1Seq1.uppercased())", "agent-message:\(run):\(hashTask1Seq1):extra",
        ] {
            #expect(BridgeLedger.parseServerKey(bad) == nil, "\(bad)")
        }
    }

    // MARK: 찾기 (실제 SQLite 원장)

    @Test func theFullTextIsFoundByTheServerKeyOfItsEvent() async throws {
        let dir = TempDirectory()
        let ledger = try ledger(dir)
        try await ledger.saveTask(BridgeTest.task(task1))
        _ = try await ledger.appendEvent(taskID: task1, numbering: .taskSequence, build: BridgeTest.build(text: "short", full: "the full first reply"), update: { _ in })
        _ = try await ledger.appendEvent(taskID: task1, numbering: .taskSequence, build: BridgeTest.build(text: "short", full: "the full second reply"), update: { _ in })
        #expect(try await ledger.fullText(forServerKey: "agent-message:\(run):\(hashTask1Seq1)") == "the full first reply")
        #expect(try await ledger.fullText(forServerKey: "agent-message:\(run):\(hashTask1Seq2)") == "the full second reply")
        // 여러 task 중에서 맞는 것
        try await ledger.saveTask(BridgeTest.task(task2, turn: 2))
        _ = try await ledger.appendEvent(taskID: task2, numbering: .taskSequence, build: BridgeTest.build(text: "short", full: "another turn's full reply"), update: { _ in })
        #expect(try await ledger.fullText(forServerKey: "agent-message:\(run):\(hashTask2Seq1)") == "another turn's full reply")
        #expect(try await ledger.fullText(forServerKey: "agent-message:\(run):\(hashTask1Seq1)") == "the full first reply")
    }

    @Test func nothingIsFoundForAnEventWithoutAFullTextAnUnknownEventOrABrokenKey() async throws {
        let dir = TempDirectory()
        let ledger = try ledger(dir)
        try await ledger.saveTask(BridgeTest.task(task1))
        _ = try await ledger.appendEvent(taskID: task1, numbering: .taskSequence, build: BridgeTest.build(text: "whole"), update: { _ in })
        #expect(try await ledger.fullText(forServerKey: "agent-message:\(run):\(hashTask1Seq1)") == nil, "자르지 않은 글은 전문이 없다")
        #expect(try await ledger.fullText(forServerKey: "agent-message:\(run):\(hashTask1Seq2)") == nil, "이 Mac이 모르는 사건")
        #expect(try await ledger.fullText(forServerKey: "agent-message:\(run):\(hashTask2Seq1)") == nil)
        #expect(try await ledger.fullText(forServerKey: "not a key") == nil)
        #expect(try await ledger.fullText(forServerKey: "") == nil)
    }

    /// 다른 계정(파티션)의 원장은 다른 파일이다: 같은 열쇠로 찾아도 앞 계정의 전문이 나오지 않는다
    @Test func anotherAccountsLedgerFindsNothing() async throws {
        let first = TempDirectory()
        let second = TempDirectory()
        let mine = try ledger(first)
        let theirs = try ledger(second)
        try await mine.saveTask(BridgeTest.task(task1))
        _ = try await mine.appendEvent(taskID: task1, numbering: .taskSequence, build: BridgeTest.build(text: "short", full: "my private full text"), update: { _ in })
        let key = "agent-message:\(run):\(hashTask1Seq1)"
        #expect(try await mine.fullText(forServerKey: key) == "my private full text")
        #expect(try await theirs.fullText(forServerKey: key) == nil)
        try await theirs.saveTask(BridgeTest.task(task1))
        #expect(try await theirs.fullText(forServerKey: key) == nil, "같은 task id가 있어도 그 원장에 전문이 없다")
    }

    @Test func aFullTextPrunedAfterAMonthIsGone() async throws {
        let dir = TempDirectory()
        let box = NowBox(t0)
        let ledger = try ledger(dir, clock: box)
        try await ledger.saveTask(BridgeTest.task(task1))
        _ = try await ledger.appendEvent(taskID: task1, numbering: .taskSequence, build: BridgeTest.build(text: "short", full: "old full text"), update: { _ in })
        let key = "agent-message:\(run):\(hashTask1Seq1)"
        #expect(try await ledger.fullText(forServerKey: key) == "old full text")
        box.value = t0.addingTimeInterval(31 * 86400)
        _ = try await ledger.prune(now: box.value)
        #expect(try await ledger.fullText(forServerKey: key) == nil, "한 달 정리로 지워졌다: 링크가 없다")
    }

    /// 보관은 task 7일 · 전문 30일이다: task가 정리된 뒤(8–29일)에도 전문은 남아 있고 View full은 그 전문을 찾아야 한다.
    /// (task를 세어 사건 id를 복원하면 task가 사라진 8일째부터 존재하는 전문이 링크에서 사라진다.) 정리는 실제 `prune` SQL을 돌린다
    @Test func aFullTextIsStillFoundAfterItsTaskWasPrunedAndGoneAfterAMonth() async throws {
        let dir = TempDirectory()
        let box = NowBox(t0)
        let ledger = try ledger(dir, clock: box)
        try await ledger.saveTask(BridgeTest.task(task1))
        let event = try await ledger.appendEvent(taskID: task1, numbering: .taskSequence, build: BridgeTest.build(text: "short", full: "full text of the eighth day"), update: { _ in })
        try await ledger.removeOutbox(keys: [event.key])
        let key = "agent-message:\(run):\(hashTask1Seq1)"
        #expect(try await ledger.fullText(forServerKey: key) == "full text of the eighth day")
        box.value = t0.addingTimeInterval(8 * 86400)
        let report = try await ledger.prune(now: box.value)
        #expect(report.tasks == 1 && report.fullTexts == 0, "task는 정리되고 전문은 남는다")
        #expect(try await ledger.allTasks().isEmpty)
        #expect(try await ledger.fullText(forServerKey: key) == "full text of the eighth day", "task가 없어도 전문의 사건 id로 찾는다")
        // 다른 사건의 열쇠는 여전히 찾지 못한다
        #expect(try await ledger.fullText(forServerKey: "agent-message:\(run):\(hashTask1Seq2)") == nil)
        box.value = t0.addingTimeInterval(31 * 86400)
        _ = try await ledger.prune(now: box.value)
        #expect(try await ledger.fullText(forServerKey: key) == nil, "한 달이 지나면 전문도 없다")
    }

    // MARK: 런타임

    @Test func theRuntimeAnswersFromItsOwnLedgerAndKnowsThisMacsBridgeID() async throws {
        let harness = try BridgeHarness()
        try await harness.ledger.saveTask(BridgeTest.task(task1))
        _ = try await harness.ledger.appendEvent(taskID: task1, numbering: .taskSequence, build: BridgeTest.build(text: "short", full: "runtime full text"), update: { _ in })
        let key = "agent-message:\(run):\(hashTask1Seq1)"
        #expect(await harness.runtime.fullText(forServerKey: key) == "runtime full text")
        #expect(await harness.runtime.fullText(forServerKey: "garbage") == nil)
        #expect(await harness.runtime.localBridgeID() == nil, "등록 전에는 bridge id를 모른다")
        try await harness.ledger.updateMeta { $0.bridgeID = "b1d6e000-0000-4000-8000-000000000001" }
        #expect(await harness.runtime.localBridgeID() == UUID(uuidString: "b1d6e000-0000-4000-8000-000000000001"))
        try await harness.ledger.updateMeta { $0.bridgeID = "not-a-uuid" }
        #expect(await harness.runtime.localBridgeID() == nil, "읽을 수 없는 값은 모른다고 한다")
    }
}
#endif
