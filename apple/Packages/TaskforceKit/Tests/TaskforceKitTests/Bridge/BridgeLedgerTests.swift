#if os(macOS)
import Foundation
import Testing
@testable import TaskforceKit

/// 원장 (OA D2b 계약 2.5 · 4.1 K3): 스키마 · write-ahead 저장 · 번호 매기기 · 손상 격리 · 파티션 분리 · 보관 정리
struct BridgeLedgerTests {
    private let t0 = BridgeTest.t0

    private func ledger(_ directory: TempDirectory, byteLimit: Int = 50_000_000, clock: NowBox? = nil) throws -> BridgeLedger {
        let box = clock ?? NowBox(t0)
        return try BridgeLedger(directory: directory.appending("ledger"), now: { box.value }, byteLimit: byteLimit)
    }

    // MARK: 스키마 · 파일 모양

    @Test func opensWithTheDocumentedPragmasAndSchemaVersion() async throws {
        let dir = TempDirectory()
        let ledger = try ledger(dir)
        let info = try await ledger.diagnostics()
        #expect(info.journalMode == "wal")
        #expect(info.synchronous == 2)
        #expect(info.foreignKeys)
        #expect(info.schemaVersion == 1)
        #expect(info.quickCheck == "ok")
        #expect(try await ledger.meta().schemaVersion == 1)
    }

    @Test func theFolderIsPrivateAndTheFileIsOwnerOnly() async throws {
        let dir = TempDirectory()
        let ledger = try ledger(dir)
        try await ledger.saveTask(BridgeTest.task())
        let folder = try FileManager.default.attributesOfItem(atPath: ledger.directory.path)[.posixPermissions] as? Int
        let file = try FileManager.default.attributesOfItem(atPath: ledger.fileURL.path)[.posixPermissions] as? Int
        #expect(folder == 0o700)
        #expect(file == 0o600)
    }

    // MARK: 기록은 다시 열어도 남는다

    @Test func recordsSurviveReopening() async throws {
        let dir = TempDirectory()
        var command = BridgeTest.command(state: .startIntent)
        command.stepID = "57e90001-0000-4000-8000-000000000001"
        command.marker = "tf-marker"
        command.adapter = "agent:claude-code"
        command.leaseExpiresAt = t0.addingTimeInterval(330)
        command.spawnAt = t0.addingTimeInterval(1.5)
        command.reason = "because"
        command.signalAt = t0.addingTimeInterval(2.5)
        command.ackOp = "readback"
        command.ackResult = "unknown"
        var task = BridgeTest.task()
        task.pid = 4242
        task.processStartedAt = t0.addingTimeInterval(2)
        task.processMarker = "tf-marker"
        task.alive = true
        task.lastSeq = 7
        task.lastState = "running"
        task.openRequestID = "req-1"
        task.openRequestKind = "input"
        task.openRequestSecret = true
        task.closedRequestIDs = ["a", "b"]
        task.cancelState = "requested"
        task.externalSessionID = "claude-session-9"
        task.workspaceRef = "workspace-a"
        task.acceptedAt = t0.addingTimeInterval(3)
        task.currentCommandID = command.commandID
        task.segmentTerminal = "completed"
        do {
            let ledger = try ledger(dir)
            try await ledger.saveCommand(command)
            try await ledger.saveTask(task)
            try await ledger.updateMeta {
                $0.bridgeID = "b1111111-1111-4111-8111-111111111111"
                $0.clockOffsetMS = -250
                $0.adaptersReportHash = "abc"
            }
            await ledger.close()
        }
        let reopened = try ledger(dir)
        #expect(try await reopened.command(command.commandID) == command)
        #expect(try await reopened.task(task.agentTaskID) == task)
        let meta = try await reopened.meta()
        #expect(meta.bridgeID == "b1111111-1111-4111-8111-111111111111" && meta.clockOffsetMS == -250 && meta.adaptersReportHash == "abc")
    }

    @Test func updatingAMissingRecordDoesNothing() async throws {
        let dir = TempDirectory()
        let ledger = try ledger(dir)
        #expect(try await ledger.updateCommand("nope") { $0.state = .settled } == nil)
        #expect(try await ledger.updateTask("nope") { $0.alive = true } == nil)
    }

    // MARK: 사건 번호 · 같은 트랜잭션

    @Test func taskEventsGetMonotonicSeqAndIdsThatContinueAfterReopening() async throws {
        let dir = TempDirectory()
        let task = BridgeTest.task()
        do {
            let ledger = try ledger(dir)
            try await ledger.saveTask(task)
            let first = try await ledger.appendEvent(taskID: task.agentTaskID, numbering: .taskSequence, build: BridgeTest.build(), update: { $0.lastState = "accepted" })
            let second = try await ledger.appendEvent(taskID: task.agentTaskID, numbering: .taskSequence, build: BridgeTest.build(), update: { _ in })
            #expect(first.seq == 1 && first.eventID == "\(task.agentTaskID):1")
            #expect(second.seq == 2 && second.eventID == "\(task.agentTaskID):2")
            #expect(try await ledger.task(task.agentTaskID)?.lastSeq == 2)
            #expect(try await ledger.task(task.agentTaskID)?.lastState == "accepted")
            await ledger.close()
        }
        let reopened = try ledger(dir)
        let third = try await reopened.appendEvent(taskID: task.agentTaskID, numbering: .taskSequence, build: BridgeTest.build(), update: { _ in })
        #expect(third.seq == 3 && third.eventID == "\(task.agentTaskID):3")
        #expect(try await reopened.outboxRows().map(\.seq) == [1, 2, 3])
    }

    @Test func theBuiltEventSeesTheAssignedSeqAndIDAndItsJSONIsStoredVerbatim() async throws {
        let dir = TempDirectory()
        let ledger = try ledger(dir)
        let task = BridgeTest.task()
        try await ledger.saveTask(task)
        let row = try await ledger.appendEvent(taskID: task.agentTaskID, numbering: .taskSequence, build: BridgeTest.build(text: "hello"), update: { _ in })
        #expect(row.bodyJSON == "{\"event_id\":\"\(task.agentTaskID):1\",\"seq\":1,\"text\":\"hello\"}")
        #expect(row.bytes == row.bodyJSON.utf8.count)
        #expect(row.type == "message" && row.attempts == 0 && row.deadReason == nil)
        #expect(row.agentSessionID == task.agentSessionID && row.agentTaskID == task.agentTaskID)
    }

    @Test func sessionAndReconcileEventsCarryNoSeqAndKeepTheirOwnCounters() async throws {
        let dir = TempDirectory()
        let ledger = try ledger(dir)
        let task = BridgeTest.task()
        try await ledger.saveTask(task)
        _ = try await ledger.appendEvent(taskID: task.agentTaskID, numbering: .taskSequence, build: BridgeTest.build(), update: { _ in })
        let bound = try await ledger.appendEvent(taskID: task.agentTaskID, numbering: .sessionScoped, build: BridgeTest.build(type: "session_bound"), update: { _ in })
        let bound2 = try await ledger.appendEvent(taskID: task.agentTaskID, numbering: .sessionScoped, build: BridgeTest.build(type: "session_bound"), update: { _ in })
        let reconcile = try await ledger.appendEvent(taskID: task.agentTaskID, numbering: .reconcile, build: BridgeTest.build(type: "reconcile"), update: { _ in })
        let reconcile2 = try await ledger.appendEvent(taskID: task.agentTaskID, numbering: .reconcile, build: BridgeTest.build(type: "reconcile"), update: { _ in })
        #expect(bound.eventID == "\(task.agentSessionID):s1" && bound2.eventID == "\(task.agentSessionID):s2")
        #expect(reconcile.eventID == "\(task.agentTaskID):r1" && reconcile2.eventID == "\(task.agentTaskID):r2")
        #expect(bound.seq == nil && reconcile.seq == nil)
        // seq는 task 사건만 올린다
        #expect(try await ledger.task(task.agentTaskID)?.lastSeq == 1)
        #expect(try await ledger.task(task.agentTaskID)?.reconcileCount == 2)
    }

    @Test func aFailedBuildLeavesNoPartialWrite() async throws {
        struct Boom: Error {}
        let dir = TempDirectory()
        let ledger = try ledger(dir)
        let task = BridgeTest.task()
        try await ledger.saveTask(task)
        await #expect(throws: Boom.self) {
            _ = try await ledger.appendEvent(taskID: task.agentTaskID, numbering: .taskSequence, build: { _, _ in throw Boom() }, update: { $0.alive = true })
        }
        #expect(try await ledger.task(task.agentTaskID)?.lastSeq == 0)
        #expect(try await ledger.task(task.agentTaskID)?.alive == false)
        #expect(try await ledger.outboxRows().isEmpty)
    }

    @Test func appendingToAnUnknownTaskIsRefused() async throws {
        let dir = TempDirectory()
        let ledger = try ledger(dir)
        await #expect(throws: BridgeLedgerError.unknownTask("ghost")) {
            _ = try await ledger.appendEvent(taskID: "ghost", numbering: .taskSequence, build: BridgeTest.build(), update: { _ in })
        }
    }

    @Test func theFullTextIsKeptOnlyWhenTheEventWasTruncated() async throws {
        let dir = TempDirectory()
        let ledger = try ledger(dir)
        let task = BridgeTest.task()
        try await ledger.saveTask(task)
        let plain = try await ledger.appendEvent(taskID: task.agentTaskID, numbering: .taskSequence, build: BridgeTest.build(), update: { _ in })
        let cut = try await ledger.appendEvent(taskID: task.agentTaskID, numbering: .taskSequence, build: BridgeTest.build(text: "short", full: "the full long text"), update: { _ in })
        #expect(try await ledger.fullText(eventID: plain.eventID) == nil)
        #expect(try await ledger.fullText(eventID: cut.eventID) == "the full long text")
    }

    // MARK: outbox

    @Test func outboxFailuresCountAttemptsAndDeadLettersLeaveTheSendableList() async throws {
        let dir = TempDirectory()
        let ledger = try ledger(dir)
        let task = BridgeTest.task()
        try await ledger.saveTask(task)
        let a = try await ledger.appendEvent(taskID: task.agentTaskID, numbering: .taskSequence, build: BridgeTest.build(), update: { _ in })
        let b = try await ledger.appendEvent(taskID: task.agentTaskID, numbering: .taskSequence, build: BridgeTest.build(), update: { _ in })
        let later = t0.addingTimeInterval(8)
        try await ledger.recordOutboxFailure(keys: [a.key], nextAttemptAt: later, status: "http_503")
        let rows = try await ledger.outboxRows()
        #expect(rows.map(\.attempts) == [1, 0])
        #expect(rows[0].nextAttemptAt == later && rows[0].lastStatus == "http_503")
        try await ledger.markOutboxDead(keys: [b.key], reason: "invalid")
        #expect(try await ledger.outboxRows().map(\.eventID) == [a.eventID])
        let all = try await ledger.outboxRows(includeDead: true)
        #expect(all.map(\.deadReason) == [nil, "invalid"])
        try await ledger.removeOutbox(keys: [a.key])
        #expect(try await ledger.outboxRows().isEmpty)
    }

    // MARK: ack는 먼저 적고 보낸다

    @Test func anAckIsWrittenBeforeItIsSentAndTheCommandRemembersWhatItReported() async throws {
        let dir = TempDirectory()
        let ledger = try ledger(dir)
        try await ledger.saveCommand(BridgeTest.command(state: .leased))
        let key = try await ledger.enqueueAck(commandID: BridgeTest.command().commandID, op: "readback", result: "unknown", bodyJSON: "{\"op\":\"readback\"}")
        let command = try await ledger.command(BridgeTest.command().commandID)
        #expect(command?.ackOp == "readback" && command?.ackResult == "unknown" && command?.ackFinalAt == nil)
        #expect(try await ledger.dueAcks(now: t0, limit: 10).map(\.key) == [key])
        try await ledger.recordAckFailure(key: key, nextAttemptAt: t0.addingTimeInterval(10))
        #expect(try await ledger.dueAcks(now: t0, limit: 10).isEmpty)
        #expect(try await ledger.dueAcks(now: t0.addingTimeInterval(10), limit: 10).map(\.attempts) == [1])
        try await ledger.settleAck(key: key, commandState: .settled, reason: nil)
        #expect(try await ledger.allAcks().isEmpty)
        let settled = try await ledger.command(BridgeTest.command().commandID)
        #expect(settled?.state == .settled && settled?.ackFinalAt == t0)
    }

    // MARK: 질문 · 작업 조회

    @Test func questionMapsAreKeptPerTaskAndRequest() async throws {
        let dir = TempDirectory()
        let ledger = try ledger(dir)
        try await ledger.saveQuestionMap(taskID: "t", requestID: "r", mappingJSON: "{\"labels\":{\"a\":\"ab\"}}")
        #expect(try await ledger.questionMap(taskID: "t", requestID: "r") == "{\"labels\":{\"a\":\"ab\"}}")
        #expect(try await ledger.questionMap(taskID: "t", requestID: "other") == nil)
    }

    @Test func liveTaskInSessionFindsTheWriterExceptTheOneBeingAsked() async throws {
        let dir = TempDirectory()
        let ledger = try ledger(dir)
        var running = BridgeTest.task("7a5c0001-0000-4000-8000-000000000001")
        running.alive = true
        var other = BridgeTest.task("7a5c0001-0000-4000-8000-000000000002", session: "5e551011-0000-4000-8000-000000000002")
        other.alive = true
        try await ledger.saveTask(running)
        try await ledger.saveTask(other)
        #expect(try await ledger.liveTask(inSession: running.agentSessionID, excluding: nil)?.agentTaskID == running.agentTaskID)
        #expect(try await ledger.liveTask(inSession: running.agentSessionID, excluding: running.agentTaskID) == nil)
        #expect(try await ledger.liveTask(inSession: "5e551011-0000-4000-8000-000000000003", excluding: nil) == nil)
    }

    // MARK: 손상 격리 (지우지 않는다)

    @Test func aCorruptFileIsMovedAsideNotDeletedAndTheLedgerStartsEmpty() async throws {
        let dir = TempDirectory()
        let folder = dir.appending("ledger")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let garbage = Data("this is not a sqlite database at all, just junk bytes".utf8) + Data(repeating: 0x41, count: 4096)
        try garbage.write(to: folder.appending(path: "ledger.sqlite"))
        let ledger = try BridgeLedger(directory: folder, now: { BridgeTest.t0 })
        let quarantined = try #require(ledger.quarantinedFile)
        #expect(quarantined.lastPathComponent.hasPrefix("ledger.sqlite.corrupt-"))
        #expect(try Data(contentsOf: quarantined) == garbage)
        #expect(try await ledger.allCommands().isEmpty && ledger.fileURL.path != quarantined.path)
        try await ledger.saveCommand(BridgeTest.command())
        #expect(try await ledger.allCommands().count == 1)
    }

    @Test func aHealthyFileIsNotQuarantined() async throws {
        let dir = TempDirectory()
        let first = try ledger(dir)
        try await first.saveCommand(BridgeTest.command())
        await first.close()
        let second = try ledger(dir)
        #expect(second.quarantinedFile == nil)
        #expect(try await second.allCommands().count == 1)
    }

    // MARK: 파티션

    @Test func partitionsAreSeparatedByUserAndByServerOrigin() {
        let alice = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
        let bob = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
        let local = BridgePartition(apiOrigin: "http://localhost:3000", userID: alice)
        #expect(local.id.count == 32 && local.id.allSatisfy { "0123456789abcdef".contains($0) })
        #expect(local.id == BridgePartition(apiOrigin: "http://localhost:3000", userID: alice).id)
        #expect(local.id != BridgePartition(apiOrigin: "http://localhost:3000", userID: bob).id)
        #expect(local.id != BridgePartition(apiOrigin: "https://api.taskforcelabs.dev", userID: alice).id)
        #expect(BridgePartition(apiBaseURL: URL(string: "HTTP://LocalHost:3000/some/path?q=1")!, userID: alice) == local)
        let root = URL(fileURLWithPath: "/tmp/root")
        #expect(local.directory(in: root).path == "/tmp/root/\(local.id)")
    }

    @Test func twoPartitionsNeverSeeEachOthersRows() async throws {
        let dir = TempDirectory()
        let alice = BridgePartition(apiOrigin: "http://x", userID: UUID())
        let bob = BridgePartition(apiOrigin: "http://x", userID: UUID())
        let a = try BridgeLedger(directory: alice.directory(in: dir.url), now: { BridgeTest.t0 })
        let b = try BridgeLedger(directory: bob.directory(in: dir.url), now: { BridgeTest.t0 })
        try await a.saveCommand(BridgeTest.command())
        try await a.saveTask(BridgeTest.task())
        #expect(try await b.allCommands().isEmpty)
        #expect(try await b.allTasks().isEmpty)
        #expect(a.fileURL != b.fileURL)
    }

    // MARK: 보관 정리 (계약 2.5 "보관")

    @Test func retentionDropsFinishedCommandsAfterSevenDaysAndKeepsActiveOnes() async throws {
        let dir = TempDirectory()
        let ledger = try ledger(dir)
        let old = t0.addingTimeInterval(-8 * 86400)
        let recent = t0.addingTimeInterval(-6 * 86400)
        try await ledger.saveCommand(BridgeTest.command("c-old-settled", state: .settled, at: old))
        try await ledger.saveCommand(BridgeTest.command("c-old-withdrawn", state: .withdrawn, at: old))
        try await ledger.saveCommand(BridgeTest.command("c-old-gone", state: .gone, at: old))
        try await ledger.saveCommand(BridgeTest.command("c-recent-settled", state: .settled, at: recent))
        try await ledger.saveCommand(BridgeTest.command("c-old-started", state: .started, at: old))
        let report = try await ledger.prune(now: t0)
        #expect(report.commands == 3)
        #expect(Set(try await ledger.allCommands().map(\.commandID)) == ["c-recent-settled", "c-old-started"])
    }

    @Test func fullTextsLastThirtyDaysAndDeadLettersSeven() async throws {
        let dir = TempDirectory()
        let clock = NowBox(t0.addingTimeInterval(-31 * 86400))
        let ledger = try ledger(dir, clock: clock)
        let task = BridgeTest.task()
        try await ledger.saveTask(task)
        let stale = try await ledger.appendEvent(taskID: task.agentTaskID, numbering: .taskSequence, build: BridgeTest.build(full: "stale full"), update: { _ in })
        clock.value = t0.addingTimeInterval(-8 * 86400)
        let dead = try await ledger.appendEvent(taskID: task.agentTaskID, numbering: .taskSequence, build: BridgeTest.build(), update: { _ in })
        try await ledger.markOutboxDead(keys: [dead.key], reason: "invalid")
        clock.value = t0.addingTimeInterval(-1 * 86400)
        let fresh = try await ledger.appendEvent(taskID: task.agentTaskID, numbering: .taskSequence, build: BridgeTest.build(full: "fresh full"), update: { _ in })
        let recentDead = try await ledger.appendEvent(taskID: task.agentTaskID, numbering: .taskSequence, build: BridgeTest.build(), update: { _ in })
        try await ledger.markOutboxDead(keys: [recentDead.key], reason: "invalid")
        clock.value = t0
        let report = try await ledger.prune(now: t0)
        #expect(report.fullTexts == 1 && report.deadLetters == 1)
        #expect(try await ledger.fullText(eventID: fresh.eventID) == "fresh full")
        #expect(try await ledger.fullText(eventID: stale.eventID) == nil)
        #expect(Set(try await ledger.outboxRows(includeDead: true).map(\.eventID)).contains(recentDead.eventID))
        #expect(!Set(try await ledger.outboxRows(includeDead: true).map(\.eventID)).contains(dead.eventID))
    }

    @Test func unsentEventsOlderThanSevenDaysExpireAndSayWhy() async throws {
        let dir = TempDirectory()
        let clock = NowBox(t0.addingTimeInterval(-8 * 86400))
        let ledger = try ledger(dir, clock: clock)
        let task = BridgeTest.task()
        try await ledger.saveTask(task)
        let ancient = try await ledger.appendEvent(taskID: task.agentTaskID, numbering: .taskSequence, build: BridgeTest.build(), update: { _ in })
        clock.value = t0.addingTimeInterval(-6 * 86400)
        let fresh = try await ledger.appendEvent(taskID: task.agentTaskID, numbering: .taskSequence, build: BridgeTest.build(), update: { _ in })
        clock.value = t0
        let report = try await ledger.prune(now: t0)
        #expect(report.expiredEvents == 1)
        #expect(try await ledger.outboxRows().map(\.eventID) == [fresh.eventID])
        let dead = try await ledger.outboxRows(includeDead: true).first { $0.eventID == ancient.eventID }
        #expect(dead?.deadReason == "outbox_expired")
    }

    @Test func overTheByteLimitTheOldestFullTextsGoFirst() async throws {
        let dir = TempDirectory()
        let clock = NowBox(t0)
        let ledger = try ledger(dir, byteLimit: 200_000, clock: clock)
        let task = BridgeTest.task()
        try await ledger.saveTask(task)
        let big = String(repeating: "x", count: 60_000)
        var ids: [String] = []
        for index in 0..<5 {
            clock.value = t0.addingTimeInterval(Double(index))
            let row = try await ledger.appendEvent(taskID: task.agentTaskID, numbering: .taskSequence, build: BridgeTest.build(full: big), update: { _ in })
            ids.append(row.eventID)
        }
        _ = try await ledger.prune(now: t0.addingTimeInterval(10))
        let remaining = try await ids.asyncCompactMap { try await ledger.fullText(eventID: $0) }
        #expect(remaining.count < 5)
        #expect(try await ledger.fullText(eventID: ids[4]) != nil)
        #expect(try await ledger.fullText(eventID: ids[0]) == nil)
    }

    // MARK: 할 일 판단

    @Test func pendingWorkIsAnythingUnfinishedUnsentOrAlive() async throws {
        let dir = TempDirectory()
        let ledger = try ledger(dir)
        #expect(try await ledger.hasPendingWork() == false)
        try await ledger.saveCommand(BridgeTest.command(state: .settled))
        #expect(try await ledger.hasPendingWork() == false)
        try await ledger.saveCommand(BridgeTest.command("c2", state: .leased))
        #expect(try await ledger.hasPendingWork())
        try await ledger.updateCommand("c2") { $0.state = .settled }
        #expect(try await ledger.hasPendingWork() == false)
        let task = BridgeTest.task()
        try await ledger.saveTask(task)
        _ = try await ledger.appendEvent(taskID: task.agentTaskID, numbering: .taskSequence, build: BridgeTest.build(), update: { _ in })
        #expect(try await ledger.hasPendingWork())
    }
}

final class NowBox: @unchecked Sendable {
    var value: Date

    init(_ value: Date) {
        self.value = value
    }
}

extension Array {
    fileprivate func asyncCompactMap<T>(_ transform: (Element) async throws -> T?) async rethrows -> [T] {
        var result: [T] = []
        for element in self {
            if let value = try await transform(element) { result.append(value) }
        }
        return result
    }
}
#endif
