#if os(macOS) && DEBUG
import Foundation
import SQLite3
import Testing
@testable import TaskforceKit

/// 독립 검토 반영 D (OA D2b 계약 7장 D, P3 목록): 파일 권한 · 보관 정리 · 등록 예산 · 주소 정책 · lease 대조 · 스키마 · 잠금
struct BridgeReviewDTests {
    private func permissions(_ path: String) throws -> Int {
        (try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int) ?? -1
    }

    // MARK: security 1 — WAL · SHM도 0600

    @Test func theDatabaseItsWalAndShmAndTheLockFileAreOwnerOnly() async throws {
        let dir = TempDirectory()
        for round in 0..<2 { // 새로 만들 때와 다시 열 때 (닫으면 WAL · SHM이 지워졌다가 다시 만들어진다)
            let ledger = try BridgeLedger(directory: dir.url)
            try await ledger.saveCommand(BridgeTest.command(cursor: round + 1))
            for suffix in ["", "-wal", "-shm"] {
                #expect(try permissions(ledger.fileURL.path + suffix) == 0o600, "round \(round) ledger.sqlite\(suffix)")
            }
            #expect(try permissions(dir.url.appending(path: "ledger.lock").path) == 0o600)
            #expect(try permissions(dir.url.path) == 0o700)
            await ledger.close()
        }
    }

    // MARK: security 2 · code — tasks · question_maps · counters · 격리된 corrupt 파일 정리

    @Test func pruneRemovesFinishedTasksTheirQuestionMapsOldCountersAndOldQuarantinedFiles() async throws {
        let dir = TempDirectory()
        let ledger = try BridgeLedger(directory: dir.url, now: { BridgeTest.t0 })
        let oldSession = "5e551011-0000-4000-8000-0000000000a1"
        let liveSession = "5e551011-0000-4000-8000-0000000000a2"
        var finished = BridgeTest.task("7a5c0001-0000-4000-8000-0000000000a1", session: oldSession)
        finished.lastState = "idle"
        try await ledger.saveTask(finished)
        var live = BridgeTest.task("7a5c0001-0000-4000-8000-0000000000a2", session: liveSession)
        live.alive = true
        live.lastState = "running"
        try await ledger.saveTask(live)
        try await ledger.saveQuestionMap(taskID: finished.agentTaskID, requestID: "r", mappingJSON: "{}")
        try await ledger.saveQuestionMap(taskID: live.agentTaskID, requestID: "r", mappingJSON: "{}")
        for task in [finished, live] { // 세션 번호표(counters)를 만든다
            let row = try await ledger.appendEvent(taskID: task.agentTaskID, numbering: .sessionScoped, build: BridgeTest.build(type: "session_bound"), update: { _ in })
            if task.agentTaskID == finished.agentTaskID { try await ledger.removeOutbox(keys: [row.key]) } // 다 보낸 사건
        }
        let oldCorrupt = dir.url.appending(path: "ledger.sqlite.corrupt-\(Int(BridgeTest.t0.timeIntervalSince1970))")
        let recentCorrupt = dir.url.appending(path: "ledger.sqlite.corrupt-\(Int(BridgeTest.t0.timeIntervalSince1970) + 9 * 86400)")
        try Data("old".utf8).write(to: oldCorrupt)
        try Data("recent".utf8).write(to: recentCorrupt)

        let report = try await ledger.prune(now: BridgeTest.t0.addingTimeInterval(10 * 86400))
        #expect(report.tasks == 1 && report.questionMaps == 1 && report.counters == 1 && report.corruptFiles == 1, "\(report)")
        #expect(try await ledger.task(finished.agentTaskID) == nil)
        #expect(try await ledger.task(live.agentTaskID) != nil, "살아 있는 task는 남는다")
        #expect(try await ledger.questionMap(taskID: live.agentTaskID, requestID: "r") != nil)
        #expect(!FileManager.default.fileExists(atPath: oldCorrupt.path), "7일 넘은 격리 파일은 지운다")
        #expect(FileManager.default.fileExists(atPath: recentCorrupt.path), "최근 격리 파일은 남긴다")
        await ledger.close()
    }

    @Test func aFinishedTaskWithUnsentEventsOrUnfinishedCommandsIsKept() async throws {
        let dir = TempDirectory()
        let ledger = try BridgeLedger(directory: dir.url, now: { BridgeTest.t0 })
        var withEvent = BridgeTest.task("7a5c0001-0000-4000-8000-0000000000b1", session: "5e551011-0000-4000-8000-0000000000b1")
        withEvent.lastState = "failed"
        try await ledger.saveTask(withEvent)
        _ = try await ledger.appendEvent(taskID: withEvent.agentTaskID, numbering: .taskSequence, build: BridgeTest.build(type: "failed"), update: { _ in })
        var withCommand = BridgeTest.task("7a5c0001-0000-4000-8000-0000000000b2", session: "5e551011-0000-4000-8000-0000000000b2")
        withCommand.lastState = "idle"
        try await ledger.saveTask(withCommand)
        try await ledger.saveCommand(BridgeTest.command("c0000000-0000-4000-8000-0000000000b2", task: withCommand.agentTaskID, state: .accepted))
        let report = try await ledger.prune(now: BridgeTest.t0.addingTimeInterval(10 * 86400))
        #expect(report.tasks == 0)
        #expect(try await ledger.task(withEvent.agentTaskID) != nil)
        #expect(try await ledger.task(withCommand.agentTaskID) != nil)
        await ledger.close()
    }

    // MARK: security 3 — 등록 예산 · 물러서기, 401 낡은 secret

    @Test func automaticRegistrationsAreBudgetedAndBackOffEvenWhenTheyKeepSucceeding() async throws {
        let h = try BridgeHarness()
        await h.registerFirst()
        h.server.failNext("commands", .init(status: 404, count: 100_000)) // 등록은 성공하는데 곧 bridge가 없다고 되풀이한다
        for _ in 0..<20 {
            h.clock.jump(by: 1)
            await h.runtime.tick()
        }
        let first20 = h.server.requests("register").count
        #expect(first20 <= 6, "20초 동안 등록은 몇 번 안 된다 (물러서기): \(first20)")
        #expect(first20 >= 2)
        for _ in 0..<60 {
            h.clock.jump(by: 60)
            await h.runtime.tick()
        }
        let hour = h.server.requests("register").count
        #expect(hour <= 12, "1시간에 열 번이 예산이다 (서버 한도 20회 아래): \(hour)")
    }

    @Test func a401ForASecretThatWasAlreadyReplacedRetriesWithTheNewSecretInsteadOfRegisteringAgain() async throws {
        let h = try BridgeHarness()
        await h.registerFirst()
        let before = h.server.requests("register").count
        let used = Locked<[String]>([])
        let result: String = try await h.runtime.authed(.commands) { secret in
            used.set(used.get() + [secret])
            if used.get().count == 1 {
                // 이 요청이 가는 사이 다른 호출이 다시 등록해 secret이 바뀌었다
                _ = await h.runtime.register(reactivate: false, reason: "connect")
                throw BridgeClientError.unauthorized
            }
            return "ok"
        }
        #expect(result == "ok")
        #expect(h.server.requests("register").count == before + 1, "다시 등록하지 않는다 (내가 부른 등록 하나뿐)")
        #expect(Set(used.get()).count == 2, "두 번째 시도는 새 secret으로 갔다")
    }

    // MARK: security 4 · 5 — adapter 규칙, 환경 허용 목록

    @Test func theFakeNeverSignalsASystemPidAndCannotProveWhatItDoesNotKnow() async {
        let agent = FakeAgentProcess()
        #expect(await agent.terminateOrphan(AgentProcessIdentity(pid: 1, startedAt: Date(), processMarker: "m")) == .unknown, "pid 1에는 신호를 보내지 않는다")
        // 시작 시각까지 맞는 pid 1(launchd)이어도 신호를 보내지 않는다 (가드가 없으면 끝내 보려다 `.alive`가 된다)
        let launchdStart = FakeAgentProcess.processStartTime(pid: 1)
        #expect(launchdStart != nil)
        if let launchdStart {
            let started = Date()
            #expect(await agent.terminateOrphan(AgentProcessIdentity(pid: 1, startedAt: launchdStart, processMarker: "m")) == .unknown)
            #expect(Date().timeIntervalSince(started) < 0.5, "신호를 보내 보며 기다리지 않는다")
        }
        #expect(await agent.terminateOrphan(AgentProcessIdentity(pid: 0, startedAt: Date(), processMarker: "m")) == .unknown)
        #expect(await agent.liveness(AgentProcessIdentity(pid: nil, startedAt: Date(), processMarker: "never-seen")) == .unknown, "모르는 실행의 끝을 증명하지 못한다")
        #expect(await agent.terminateOrphan(AgentProcessIdentity(pid: nil, startedAt: Date(), processMarker: "never-seen")) == .unknown)
    }

    @Test func aChildProcessOnlyGetsTheAllowlistedEnvironment() {
        let source = ["HOME": "/Users/me", "PATH": "/usr/bin", "LANG": "ko_KR.UTF-8", "USER": "me", "TASKFORCE_TOKEN": "t", "SUPABASE_KEY": "k", "SSH_AUTH_SOCK": "/x", "EMPTY": ""]
        #expect(AgentChildEnvironment.allowlisted(from: source) == ["HOME": "/Users/me", "PATH": "/usr/bin", "LANG": "ko_KR.UTF-8", "USER": "me"])
        #expect(AgentChildEnvironment.allowlisted(from: ["PATH": ""]).isEmpty, "빈 값은 넘기지 않는다")
        setenv("TASKFORCE_BRIDGE_TEST_SECRET", "must-not-leak", 1)
        defer { unsetenv("TASKFORCE_BRIDGE_TEST_SECRET") }
        #expect(AgentChildEnvironment.allowlisted()["TASKFORCE_BRIDGE_TEST_SECRET"] == nil)
        #expect(Set(AgentChildEnvironment.allowlisted().keys).isSubset(of: Set(AgentChildEnvironment.allowedKeys)))
    }

    // MARK: security 6 — https / loopback만, 리다이렉트 거절, 응답 크기 상한

    @Test func bridgeRequestsGoOnlyToHTTPSOrLoopback() {
        for allowed in ["https://api.taskforcelabs.dev", "http://localhost:3000", "http://127.0.0.1:3000", "http://[::1]:3000", "http://dev.localhost:3000"] {
            #expect(BridgeEndpointPolicy.allows(URL(string: allowed)!), "\(allowed)")
        }
        for refused in ["http://api.taskforcelabs.dev", "http://localhost.evil.com", "http://127.0.0.1.evil.com", "ftp://localhost", "file:///tmp/x", "https:///path"] {
            #expect(!BridgeEndpointPolicy.allows(URL(string: refused)!), "\(refused)")
        }
    }

    private static let user = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
    private static let bridgeID = "b1111111-1111-4111-8111-111111111111"
    private static let secret = "c2VjcmV0c2VjcmV0c2VjcmV0c2VjcmV0c2VjcmV0MTI"
    private static let emptyCommands = #"{"commands":[],"readbacks":[],"next_cursor":0,"server_time":"2026-10-14T05:00:00Z"}"#

    private func client(scheme: String = "https", host: String, tokenCalls: Locked<Int> = Locked(0)) -> BridgeClient {
        BridgeClient(
            baseURL: URL(string: "\(scheme)://\(host)")!, session: StubURLProtocol.session(), expectedUserID: Self.user,
            bearer: {
                tokenCalls.set(tokenCalls.get() + 1)
                return BridgeBearer(userID: Self.user, accessToken: "user-jwt")
            }
        )
    }

    @Test func anInsecureEndpointSendsNothingAndNeverAsksForTheUserToken() async throws {
        let host = "\(UUID().uuidString.lowercased()).insecure.test"
        StubURLProtocol.install(host: host) { _ in StubURLProtocol.Reply(body: Data(Self.emptyCommands.utf8)) }
        let tokenCalls = Locked(0)
        let insecure = client(scheme: "http", host: host, tokenCalls: tokenCalls)
        await #expect(throws: BridgeClientError.insecureEndpoint) {
            _ = try await insecure.commands(bridgeID: Self.bridgeID, secret: Self.secret, after: 0, wait: 0)
        }
        #expect(StubURLProtocol.captured(host: host).isEmpty, "평문 주소로는 요청을 보내지 않는다")
        #expect(tokenCalls.get() == 0, "토큰도 꺼내지 않는다")
    }

    @Test func aRedirectIsNeverFollowedSoTheTokenAndSecretStayOnTheServer() async throws {
        let origin = "\(UUID().uuidString.lowercased()).origin.test"
        let elsewhere = "\(UUID().uuidString.lowercased()).elsewhere.test"
        StubURLProtocol.install(host: elsewhere) { _ in StubURLProtocol.Reply(body: Data(Self.emptyCommands.utf8)) }
        StubURLProtocol.install(host: origin) { _ in StubURLProtocol.Reply(status: 302, headers: ["Location": "https://\(elsewhere)/api/v1/bridge/commands"], redirectTo: URL(string: "https://\(elsewhere)/api/v1/bridge/commands")) }
        let redirected = client(host: origin)
        await #expect(throws: BridgeClientError.server(status: 302)) {
            _ = try await redirected.commands(bridgeID: Self.bridgeID, secret: Self.secret, after: 0, wait: 0)
        }
        #expect(StubURLProtocol.captured(host: elsewhere).isEmpty, "리다이렉트 대상으로 요청이 가지 않았다 (Authorization · secret 헤더가 새지 않는다)")
    }

    @Test func anOversizedResponseIsATransientFailureNotAParseAttempt() async throws {
        let host = "\(UUID().uuidString.lowercased()).big.test"
        StubURLProtocol.install(host: host) { _ in StubURLProtocol.Reply(body: Data(repeating: UInt8(ascii: "x"), count: BridgeClient.maxResponseBytes + 1)) }
        let big = client(host: host)
        await #expect(throws: BridgeClientError.server(status: 200)) {
            _ = try await big.commands(bridgeID: Self.bridgeID, secret: Self.secret, after: 0, wait: 0)
        }
    }

    // MARK: security 10 · code — lease payload 대조 · 24시간 창

    @Test func aLeasePayloadForAnotherCommandTaskOrSessionIsRefusedAsNotReceived() async throws {
        for (key, value) in [("id", "c0000000-0000-4000-8000-0000000000ee"), ("agent_task_id", "7a5c0001-0000-4000-8000-0000000000ee"), ("agent_session_id", "5e551011-0000-4000-8000-0000000000ee")] {
            let h = try BridgeHarness()
            await h.registerFirst()
            let created = h.message(extra: [key: value])
            await h.runtime.tick()
            #expect(h.agent.startedTurns.isEmpty, "\(key): 다른 일을 시키는 payload는 띄우지 않는다")
            let reports = h.server.requests("ack").map(\.json).filter { $0["op"] as? String == "readback" && $0["command_id"] as? String == created.commandID }
            #expect(reports.count == 1 && reports.first?["result"] as? String == "not_received", "\(key): \(reports)")
            #expect(await h.command(created.commandID)?.reason == "payload_mismatch")
        }
    }

    @Test func aCommandOlderThanTheDeliveryWindowIsNeverStarted() async throws {
        let h = try BridgeHarness()
        await h.registerFirst()
        let created = h.message()
        h.clock.jump(by: 25 * 3600)
        await h.runtime.tick()
        #expect(h.agent.startedTurns.isEmpty, "24시간 전달 창이 지났다")
        #expect(await h.command(created.commandID)?.reason == "expired")
        let fresh = h.message(session: "5e551011-0000-4000-8000-0000000000c2", task: "7a5c0001-0000-4000-8000-0000000000c2")
        h.clock.jump(by: 6)
        await h.runtime.tick()
        #expect(await h.eventually { h.agent.startedTurns.count == 1 }, "창 안의 명령은 돈다")
        _ = fresh
    }

    // MARK: code P3 — 스키마 · 읽기 전용 · 단일 인스턴스 · close_before

    private func setUserVersion(_ version: Int, at file: URL) throws {
        var db: OpaquePointer?
        guard sqlite3_open(file.path, &db) == SQLITE_OK else { throw BridgeLedgerError.corrupt }
        defer { sqlite3_close(db) }
        guard sqlite3_exec(db, "PRAGMA user_version=\(version)", nil, nil, nil) == SQLITE_OK else { throw BridgeLedgerError.corrupt }
    }

    @Test func aNewerSchemaIsNotCorruptionAndTheFileIsNeitherMovedNorDeleted() async throws {
        for version in [2, 11, 26, 99] { // 11 · 26은 sqlite 손상 코드와 같은 숫자다
            let dir = TempDirectory()
            let ledger = try BridgeLedger(directory: dir.url)
            try await ledger.saveCommand(BridgeTest.command())
            await ledger.close()
            try setUserVersion(version, at: ledger.fileURL)
            #expect(throws: BridgeLedgerError.newerSchema(version: version)) { try BridgeLedger(directory: dir.url) }
            let names = try FileManager.default.contentsOfDirectory(atPath: dir.url.path)
            #expect(names.contains("ledger.sqlite") && !names.contains { $0.contains("corrupt") }, "v\(version): \(names)")
        }
    }

    @Test func pendingWorkIsReadOnlyAndNeverTouchesACorruptOrNewerLedger() async throws {
        let corruptDir = TempDirectory()
        let partition = BridgePartition(apiOrigin: "https://x.test", userID: UUID())
        let directory = partition.directory(in: corruptDir.url)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let garbage = Data("garbage-not-sqlite".utf8)
        try garbage.write(to: directory.appending(path: "ledger.sqlite"))
        #expect(await BridgeStorage.hasPendingWork(partition: partition, root: corruptDir.url) == false)
        #expect(try Data(contentsOf: directory.appending(path: "ledger.sqlite")) == garbage, "손상 파일을 옮기거나 새로 만들지 않는다")
        #expect(!(try FileManager.default.contentsOfDirectory(atPath: directory.path)).contains { $0.contains("corrupt") })
        // 일이 남은 정상 원장은 읽는다
        let dir = TempDirectory()
        let other = BridgePartition(apiOrigin: "https://y.test", userID: UUID())
        let ledger = try BridgeLedger(directory: other.directory(in: dir.url))
        try await ledger.saveCommand(BridgeTest.command(state: .leased))
        await ledger.close()
        #expect(await BridgeStorage.hasPendingWork(partition: other, root: dir.url))
    }

    @Test func aSecondLedgerOnTheSamePartitionIsRefusedWhileTheFirstIsOpen() async throws {
        let dir = TempDirectory()
        let first = try BridgeLedger(directory: dir.url)
        #expect(throws: BridgeLedgerError.locked) { try BridgeLedger(directory: dir.url) }
        await first.close()
        let second = try BridgeLedger(directory: dir.url)
        await second.close()
    }

    @Test func aMessageCommandWithoutTheCloseBeforeKeyStillDecodes() throws {
        let json = #"{"id":"c0000000-0000-4000-8000-000000000001","agent_session_id":"5e551011-0000-4000-8000-000000000001","agent_task_id":"7a5c0001-0000-4000-8000-000000000001","turn_seq":1,"step_id":"57e90001-0000-4000-8000-000000000001","adapter":"agent:claude-code","marker":"tf-1","session":{"external_session_id":null,"workspace_ref":null,"resume":false},"access":"write","policy_mode":"manual","message":{"id":"3e550001-0000-4000-8000-000000000001","text":"hi"}}"#
        let command = try TaskforceJSON.decoder().decode(BridgeV1MessageCommand.self, from: Data(json.utf8))
        #expect(command.closeBeforeRequestID == nil && command.text == "hi")
    }

    // MARK: security 13 — Keychain 접근 그룹을 앱 전용 그룹으로 고정

    @Test func theKeychainAccessGroupIsPinnedOnlyWhenItLooksTeamQualified() {
        let group = "U9DWQKQFMW.dev.taskforcelabs.taskforce"
        #expect(BridgeKeychainQuery.validAccessGroup(group) == group)
        for unusable in [nil, "", ".dev.taskforcelabs.taskforce", "$(AppIdentifierPrefix)dev.taskforcelabs.taskforce", "SHORT.dev.x", "U9DWQKQFMW.", "U9DWQKQFMW$.dev.x"] {
            #expect(BridgeKeychainQuery.validAccessGroup(unusable) == nil, "\(unusable ?? "nil")")
        }
        let partition = String(repeating: "a", count: 32)
        #expect(BridgeKeychainQuery.match(partition: partition, kind: .secret, accessGroup: group)[kSecAttrAccessGroup as String] as? String == group)
        #expect(BridgeKeychainQuery.add(partition: partition, kind: .secret, value: Data(), accessGroup: group)[kSecAttrAccessGroup as String] as? String == group)
        #expect(BridgeKeychainQuery.match(partition: partition, kind: .secret)[kSecAttrAccessGroup as String] == nil, "서명 없는 시험 호스트는 그룹을 지정하지 않는다")
    }
}
#endif
