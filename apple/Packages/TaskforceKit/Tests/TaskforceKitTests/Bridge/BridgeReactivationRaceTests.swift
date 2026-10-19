#if os(macOS) && DEBUG
import Foundation
import Testing
@testable import TaskforceKit

struct BridgeReactivationRaceTests {
    private func heldRevocation() async throws -> (BridgeHarness, AgentSettingsRuntimeTests.Gate, Locked<Bool>, Task<Void, Never>) {
        let h = try BridgeHarness(withAdapter: false)
        let agent = AgentSettingsRuntimeTests.RecordingAgent(inner: h.agent, log: .init())
        try await h.restart(adapters: [agent], reopenLedger: false)
        await h.registerFirst()
        try await h.ledger.saveTask(BridgeTest.task(at: h.clock.now))
        let gate = AgentSettingsRuntimeTests.Gate()
        let forgetting = Locked(false)
        let forgotten = Locked(false)
        agent.onForget {
            forgetting.set(true)
            await gate.wait()
            forgotten.set(true)
        }
        h.server.revoke(bridgeID: h.bridgeID)
        h.clock.jump(by: 40)
        let runtime = h.runtime
        let cleanup = Task { await runtime.tick() }
        #expect(await h.eventually { forgetting.get() }, "403 cleanup reached the held forget operation")
        #expect(await runtime.status == .revoked)
        return (h, gate, forgotten, cleanup)
    }

    @Test(arguments: [false, true])
    func userReactivationWaitsForRevocationCleanup(reconnect: Bool) async throws {
        let (h, gate, forgotten, cleanup) = try await heldRevocation()
        defer { gate.open(); h.agent.killEverything() }
        let runtime = h.runtime
        #expect(await !runtime.networkEnabled, "Revocation blocks requests before asynchronous cleanup")
        let registeredBefore = h.server.registerAttempts
        let registeredEarly = Locked(false)
        h.server.onRequest = { request in
            if request.route == "register", request.method == "POST", !forgotten.get() { registeredEarly.set(true) }
        }
        let entered = Locked(false)
        let activation = Task {
            entered.set(true)
            return reconnect ? await runtime.reconnect(adapters: ["agent:claude-code"]) : await runtime.reactivate()
        }
        #expect(await h.eventually { entered.get() })
        #expect(h.server.registerAttempts == registeredBefore, "No registration while old session cleanup is held")
        gate.open()
        await cleanup.value
        let activated = await activation.value
        #expect(activated, "Runtime log: \(h.log.lines); routes: \(h.server.requests.map { $0.route + ":" + $0.method })")
        #expect(!registeredEarly.get(), "Registration follows completed session cleanup")
        #expect(await runtime.networkEnabled, "Old revocation cannot turn a reactivated runtime off")
        h.agent.setScript(.normal())
        h.message("after cleanup", session: UUID().uuidString.lowercased())
        h.clock.jump(by: 6)
        await runtime.tick()
        #expect(await h.eventually { h.agent.startedTurns.count == 1 })
        await runtime.close()
    }

    @Test(arguments: [false, true])
    func stoppingWhileReactivationWaitsNeverReenablesTheRuntime(reconnect: Bool) async throws {
        let (h, gate, forgotten, cleanup) = try await heldRevocation()
        defer { gate.open(); h.agent.killEverything() }
        let runtime = h.runtime
        let registeredBefore = h.server.registerAttempts
        let entered = Locked(false)
        let activation = Task {
            entered.set(true)
            return reconnect ? await runtime.reconnect(adapters: ["agent:claude-code"]) : await runtime.reactivate()
        }
        #expect(await h.eventually { entered.get() })
        await runtime.stop()
        gate.open()
        await cleanup.value
        #expect(await !activation.value)
        #expect(forgotten.get(), "Revocation cleanup finishes even when the account leaves")
        #expect(h.server.registerAttempts == registeredBefore)
        #expect(await runtime.status == .stopped)
        #expect(await !runtime.networkEnabled)
        #expect(await !runtime.loopsRunning)
        await runtime.close()
    }

    @Test func aHeldRegistrationCannotSendTheRevokedCredentialOnAnotherRoute() async throws {
        let h = try BridgeHarness()
        await h.registerFirst()
        h.server.revoke(bridgeID: h.bridgeID)
        await h.runtime.handleRevoked()
        let gate = AgentSettingsRuntimeTests.Gate()
        defer { gate.open() }
        let arrived = Locked(false)
        h.server.onRequest = { request in
            if request.route == "register", request.method == "POST" {
                arrived.set(true)
                await gate.wait()
            }
        }
        let runtime = h.runtime
        let activation = Task { await runtime.reactivate() }
        #expect(await h.eventually { arrived.get() })
        #expect(await runtime.secret == nil, "The revoked credential is unavailable during registration")
        let commandsBefore = h.server.requests("commands").count
        _ = await runtime.poll(wait: 0, reason: .startup)
        #expect(h.server.requests("commands").count == commandsBefore, "An old loop tail cannot send the revoked credential")
        gate.open()
        #expect(await activation.value, "A stale route must not revoke the registration in progress")
        #expect(await runtime.networkEnabled)
        await runtime.close()
    }

    @Test func aLateForbiddenForTheOldCredentialDoesNotRevokeTheNewOne() async throws {
        let h = try BridgeHarness()
        await h.registerFirst()
        let gate = AgentSettingsRuntimeTests.Gate()
        defer { gate.open() }
        let arrived = Locked(false)
        let runtime = h.runtime
        let oldRequest = Task {
            try? await runtime.authed(.commands) { (_: String) async throws -> Bool in
                arrived.set(true)
                await gate.wait()
                throw BridgeClientError.forbidden
            }
        }
        #expect(await h.eventually { arrived.get() })
        h.server.revoke(bridgeID: h.bridgeID)
        await runtime.handleRevoked()
        #expect(await runtime.reactivate())
        gate.open()
        _ = await oldRequest.value
        #expect(await runtime.networkEnabled)
        #expect(await runtime.status != .revoked, "The response belongs to the old credential")
        let commandsBefore = h.server.requests("commands").count
        _ = await runtime.poll(wait: 0, reason: .startup)
        #expect(h.server.requests("commands").count == commandsBefore + 1)
        h.server.revoke(bridgeID: h.bridgeID)
        _ = await runtime.poll(wait: 0, reason: .startup)
        #expect(await runtime.status == .revoked, "A fresh 403 for the current credential still revokes")
        #expect(await !runtime.networkEnabled)
        await runtime.close()
    }

    @Test func reactivationJoinsAReplacementCleanupBeforeEnablingRequests() async throws {
        let h = try BridgeHarness()
        let runtime = h.runtime
        let firstGate = AgentSettingsRuntimeTests.Gate()
        let secondGate = AgentSettingsRuntimeTests.Gate()
        defer { firstGate.open(); secondGate.open() }
        let replacement = Task { await secondGate.wait() }
        let original = Task {
            await firstGate.wait()
            await runtime.installRevocationForTest(replacement)
        }
        await runtime.installRevocationForTest(original)
        let entered = Locked(false)
        let completed = Locked(false)
        let activation = Task {
            let result = await runtime.prepareReactivationForTest(entered: entered)
            completed.set(true)
            return result
        }
        #expect(await h.eventually { entered.get() })
        _ = await runtime.status
        firstGate.open()
        await original.value
        #expect(!(await h.eventually { completed.get() }), "The replacement cleanup remains held for the existing wait budget")
        #expect(await !runtime.networkEnabled)
        secondGate.open()
        #expect(await activation.value)
        #expect(await runtime.networkEnabled)
        await runtime.close()
    }

}

private extension BridgeRuntime {
    func installRevocationForTest(_ cleanup: Task<Void, Never>) {
        networkEnabled = false
        setStatus(.revoked)
        revocationTask = cleanup
    }

    func prepareReactivationForTest(entered: Locked<Bool>) async -> Bool {
        entered.set(true)
        return await prepareReactivation()
    }
}
#endif
