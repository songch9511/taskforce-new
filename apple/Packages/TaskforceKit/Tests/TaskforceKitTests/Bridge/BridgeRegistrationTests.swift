#if os(macOS) && DEBUG
import Foundation
import Testing
@testable import TaskforceKit

/// 등록 · 자격 · 오류 회복 (OA D2b 계약 2.11 · 2.12 · 4.1 K16)
struct BridgeRegistrationTests {
    private func registers(_ h: BridgeHarness) -> [FakeBridgeServer.Recorded] { h.server.requests("register") }

    @Test func theDeviceIDIsAFortyThreeCharacterRandomValueKeptPerPartitionAndStableAcrossRestarts() async throws {
        let h = try BridgeHarness()
        await h.registerFirst()
        let deviceID = try #require(try h.credentials.deviceID(partition: h.partition.id))
        #expect(deviceID.count == 43 && registers(h).first?.json["device_id"] as? String == deviceID)
        try await h.restart()
        await h.runtime.tick()
        #expect(try h.credentials.deviceID(partition: h.partition.id) == deviceID)
        let other = try BridgeHarness()
        await other.registerFirst()
        #expect(try other.credentials.deviceID(partition: other.partition.id) != deviceID, "계정 둘이 이어지지 않는다")
    }

    @Test func theBridgeSecretIsStoredOnlyAfterItsShapeIsChecked() async throws {
        let h = try BridgeHarness()
        await h.registerFirst()
        let secret = try #require(try h.credentials.secret(partition: h.partition.id))
        #expect(BridgeCredentialRules.isValidSecret(secret) && secret == h.server.secret(bridgeID: h.bridgeID))
        #expect(try await h.ledger.meta().bridgeID == h.bridgeID)
    }

    @Test func registrationHappensOnlyWhenThereIsNoSecretNeverPerRun() async throws {
        let h = try BridgeHarness()
        h.agent.setScript(.normal())
        await h.registerFirst()
        for index in 1...3 {
            h.message("m\(index)", task: "7a5c0001-0000-4000-8000-0000000000c\(index)", turn: index)
            h.clock.jump(by: 6)
            for _ in 0..<5 {
                await h.runtime.tick()
                try? await Task.sleep(for: .milliseconds(5))
            }
        }
        await h.settle { h.agent.startedTurns.count == 3 }
        #expect(registers(h).count == 1, "실행마다 등록하지 않는다")
        try await h.restart()
        await h.runtime.tick()
        #expect(registers(h).count == 1, "원장 · 자격이 남아 있으면 재시작도 등록하지 않는다")
    }

    @Test func aMissingSecretRegistersAgainWithTheSameDeviceID() async throws {
        let h = try BridgeHarness()
        await h.registerFirst()
        let deviceID = try #require(try h.credentials.deviceID(partition: h.partition.id))
        try h.credentials.deleteAll(partition: h.partition.id)
        try h.credentials.save(deviceID: deviceID, partition: h.partition.id)
        try await h.restart()
        await h.runtime.tick()
        #expect(registers(h).count == 2 && registers(h).last?.json["device_id"] as? String == deviceID)
        #expect(await h.runtime.status == .connected)
    }

    // MARK: 401 · 403 · 404 · 409 · 429

    @Test func a401WithALiveSessionRegistersOnceMoreAndRetriesTheRequest() async throws {
        let h = try BridgeHarness()
        await h.registerFirst()
        let oldSecret = try #require(try h.credentials.secret(partition: h.partition.id))
        h.server.failNext("commands", .init(status: 401))
        _ = await h.runtime.poll(wait: 0, reason: .realtime)
        #expect(registers(h).count == 2)
        let newSecret = try #require(try h.credentials.secret(partition: h.partition.id))
        #expect(newSecret != oldSecret)
        let commands = h.server.requests("commands")
        #expect(commands.count == 3 && commands.last?.secret == newSecret, "원래 요청은 새 secret으로 되풀이")
        #expect(await h.runtime.status != .credentialRejected)
    }

    @Test func aSecond401LeavesTheCredentialRejectedStateWithoutAnotherRegistration() async throws {
        let h = try BridgeHarness()
        await h.registerFirst()
        h.server.failNext("commands", .init(status: 401, count: 10))
        _ = await h.runtime.poll(wait: 0, reason: .realtime)
        #expect(registers(h).count == 2)
        #expect(await h.runtime.status == .credentialRejected)
        await h.runtime.tick()
        await h.runtime.tick()
        #expect(registers(h).count == 2, "멈춤 상태에서는 다시 등록하지 않는다")
    }

    @Test func a401WhenTheSessionIsGoneIsTheAccountLeavingNotACredentialProblem() async throws {
        let h = try BridgeHarness()
        await h.registerFirst()
        h.sessionValid.set(false)
        h.server.failNext("commands", .init(status: 401))
        _ = await h.runtime.poll(wait: 0, reason: .realtime)
        #expect(registers(h).count == 1)
        #expect(await h.runtime.status == .stopped)
        let count = h.server.requests.count
        await h.runtime.tick()
        #expect(h.server.requests.count == count, "계정이 떠났으면 더 보내지 않는다")
    }

    @Test func a403StopsTheNetworkInterruptsLiveTurnsKeepsTheLedgerAndNeverReactivatesByItself() async throws {
        let h = try BridgeHarness()
        h.agent.setScript(.staysRunning())
        await h.registerFirst()
        let created = h.message()
        await h.runtime.tick()
        #expect(await h.eventually { (await h.command(created.commandID))?.state == .accepted })
        h.server.revoke(bridgeID: h.bridgeID)
        h.clock.jump(by: 31)
        await h.runtime.tick()
        #expect(await h.runtime.status == .revoked)
        #expect(await h.eventually { !h.agent.interrupts.isEmpty })
        #expect(try await h.ledger.command(created.commandID) != nil, "원장 보존")
        let count = h.server.requests.count
        for _ in 0..<3 {
            h.clock.jump(by: 60)
            await h.runtime.tick()
        }
        #expect(h.server.requests.count == count, "네트워크 멈춤")
        #expect(registers(h).allSatisfy { $0.json["reactivate"] as? Bool == false }, "자동 reactivate 금지")
    }

    @Test func reactivateIsAUserActionThatSendsReactivateTrue() async throws {
        let h = try BridgeHarness()
        await h.registerFirst()
        h.server.revoke(bridgeID: h.bridgeID)
        h.clock.jump(by: 31)
        await h.runtime.tick()
        #expect(await h.runtime.status == .revoked)
        #expect(await h.runtime.reactivate())
        #expect(registers(h).last?.json["reactivate"] as? Bool == true)
        #expect(await h.runtime.status != .revoked)
        h.clock.jump(by: 6)
        await h.runtime.tick()
        #expect(h.server.requests("heartbeat").count >= 2)
    }

    @Test func a404ClearsTheBridgeIDAndRegistersAgainKeepingTheDeviceID() async throws {
        let h = try BridgeHarness()
        await h.registerFirst()
        let deviceID = try #require(try h.credentials.deviceID(partition: h.partition.id))
        h.server.removeBridge(h.bridgeID)
        h.clock.jump(by: 31)
        await h.runtime.tick()
        #expect(try await h.ledger.meta().bridgeID == nil)
        await h.runtime.tick()
        #expect(registers(h).count == 2 && registers(h).last?.json["device_id"] as? String == deviceID)
        let stored = try await h.ledger.meta().bridgeID
        #expect(!h.bridgeID.isEmpty && stored == h.bridgeID)
    }

    @Test func tooManyBridgesIsAStatusWithNoRetryLoop() async throws {
        let h = try BridgeHarness()
        h.server.fillBridges(userID: h.userID, count: 10)
        await h.runtime.tick()
        #expect(await h.runtime.status == .tooManyBridges)
        let attempts = registers(h).count
        for _ in 0..<3 {
            h.clock.jump(by: 60)
            await h.runtime.tick()
        }
        #expect(registers(h).count == attempts, "재시도 0")
    }

    @Test func aRateLimitedRegistrationWaitsForRetryAfter() async throws {
        let h = try BridgeHarness()
        h.server.failNext("register", .init(status: 429, headers: ["Retry-After": "120"]))
        await h.runtime.tick()
        #expect(registers(h).count == 1)
        h.clock.jump(by: 60)
        await h.runtime.tick()
        #expect(registers(h).count == 1, "Retry-After 동안은 다시 등록하지 않는다")
        h.clock.jump(by: 61)
        await h.runtime.tick()
        #expect(registers(h).count == 2)
        #expect(await h.runtime.status == .connected)
    }

    @Test func connectSendsTheAdapterListOnlyWhenTheUserPressesIt() async throws {
        let h = try BridgeHarness()
        await h.registerFirst()
        #expect(registers(h).first?.json["connect"] as? [String] == [])
        // probe 보고가 있는 adapter(이 앱에 있는 것)만 connect한다
        try await h.restart(adapters: [h.agent, FakeAgentProcess(adapter: "agent:codex", clock: h.clock.clock)], reopenLedger: false)
        #expect(await h.runtime.connect(adapters: ["agent:codex", "agent:claude-code", "agent:codex"]))
        #expect(registers(h).last?.json["connect"] as? [String] == ["agent:claude-code", "agent:codex"])
    }

    @Test func drainModeRefusesConnect() async throws {
        let h = try BridgeHarness(mode: .drain)
        #expect(await h.runtime.connect(adapters: ["agent:codex"]) == false)
        #expect(h.server.requests.isEmpty)
    }

    @Test func aBadSecretShapeIsNeverStored() async throws {
        let h = try BridgeHarness()
        h.server.badSecret = true
        await h.runtime.tick()
        #expect(try h.credentials.secret(partition: h.partition.id) == nil)
        #expect(h.log.events.contains("register_bad_secret"))
    }
}
#endif
