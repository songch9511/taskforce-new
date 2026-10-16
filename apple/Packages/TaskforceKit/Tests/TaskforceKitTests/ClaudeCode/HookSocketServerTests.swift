#if os(macOS)
import Darwin
import Foundation
import Synchronization
import Testing
import TaskforceAgentWire
@testable import TaskforceKit

/// bridge 소켓 서버 (OA D3a 계약 2.6 · 4.1 "소켓 서버", G2 · G32): 폴더 0700 · 소켓 0600 · 피어 uid · 긴 경로 대체 · 남은 파일 정리 · nonce 등록부 (L0)
@Suite(.serialized)
struct HookSocketServerTests {
    let box = ClaudeSandbox()
    static let nonce = "Zm9vYmFyZm9vYmFyZm9vYmFyZm9vYmFyZm9vYmFyMDA"

    var socketPath: String { box.root.appending(path: "b/hook.sock").path }

    /// 길 · 유예를 보는 시험은 넉넉한 소켓 예산(처리기가 붐비는 기계에서 늦어도 시간 초과 deny로 뒤집히지 않게, 18장). 시간 초과 길은 `productionSocket`
    func server(
        peerUID: @escaping @Sendable (Int32) -> uid_t? = HookSocketServer.peerUID, budgets: (response: TimeInterval, read: TimeInterval) = ClaudeTest.socketBudgets
    ) throws -> HookSocketServer {
        let server = HookSocketServer(path: socketPath, peerUID: peerUID, responseBudget: budgets.response, readBudget: budgets.read)
        try server.start()
        return server
    }

    func request(nonce: String = Self.nonce, session: String = ClaudeTest.session, provider: String? = "claude-1") throws -> Data {
        try HookRequest(nonce: nonce, sessionID: session, providerSessionID: provider, hookEvent: "PreToolUse", toolUseID: "toolu_1", toolName: "Read",
                        toolInput: .object([:]), inputSHA256: "d", permissionMode: "default", cwd: "/c").encodedLine()
    }

    /// 길을 보는 시험이라 넉넉히 기다린다 (붐비는 기계에서 1.5초를 넘길 수 있다). 시간 예산은 `aSlowHandlerIsCutOffWithADeny` · HookMain 시험이 본다
    func exchange(_ line: Data) throws -> HookResponse {
        try HookResponse.decode(line: UnixSocket.exchange(path: socketPath, request: line, deadline: Date().addingTimeInterval(10)))
    }

    func register(_ server: HookSocketServer, provider: String? = "claude-1", seen: Shared<[HookRequest]>? = nil) {
        server.register(nonce: Self.nonce, HookSocketServer.Registration(agentSessionID: ClaudeTest.session, providerSessionID: provider) { request in
            seen?.mutate { $0.append(request) }
            return HookResponse(decision: .allow, reason: "Inside the workspace.")
        })
    }

    @Test func theFolderIsPrivateAndTheSocketIsOwnerOnly() throws {
        let server = try server()
        defer { server.stop() }
        let folder = try FileManager.default.attributesOfItem(atPath: (socketPath as NSString).deletingLastPathComponent)
        #expect(folder[.posixPermissions] as? Int == 0o700)
        var info = stat()
        #expect(lstat(socketPath, &info) == 0)
        #expect(info.st_mode & 0o777 == 0o600)
        #expect((info.st_mode & S_IFMT) == S_IFSOCK)
        #expect(info.st_uid == getuid())
    }

    @Test func aRegisteredNonceAndMatchingSessionReachTheHandler() throws {
        let server = try server()
        defer { server.stop() }
        let seen = Shared<[HookRequest]>([])
        register(server, seen: seen)
        #expect(try exchange(request()) == HookResponse(decision: .allow, reason: "Inside the workspace."))
        #expect(seen.value.count == 1)
    }

    @Test func anUnknownNonceOrAMismatchedSessionIsDeniedWithoutTheHandler() throws {
        let server = try server()
        defer { server.stop() }
        let seen = Shared<[HookRequest]>([])
        register(server, seen: seen)
        for line in [try request(nonce: "AAAA" + Self.nonce.dropFirst(4)), try request(nonce: String(Self.nonce.dropLast())), try request(session: "5e551011-0000-4000-8000-000000000002"),
                     try request(provider: "claude-2"), try request(provider: nil)] {
            #expect(try exchange(line).decision == .deny)
        }
        #expect(seen.value.isEmpty)
        #expect(try exchange(Data("{not json}\n".utf8)).decision == .deny)
    }

    @Test func anUnregisteredNonceIsDeniedAfterTheGracePeriod() async throws {
        let server = try server()
        defer { server.stop() }
        register(server)
        // 유예는 실제 값(2초): 첫 왕복이 그 안에 끝난다 (붐비는 기계에서도). 그 뒤 deny가 될 때까지 다시 묻는다 (잠깐 쉬기 대신, 포기 상한만)
        server.unregister(nonce: Self.nonce, after: .seconds(2))
        #expect(try exchange(request()).decision == .allow, "끝난 spawn의 nonce는 2초 동안 남는다 (늦은 훅)")
        let deadline = Date().addingTimeInterval(30)
        var decision = try exchange(request()).decision
        while decision != .deny, Date() < deadline {
            try await Task.sleep(for: .milliseconds(100))
            decision = try exchange(request()).decision
        }
        #expect(decision == .deny, "유예 뒤에는 거절")
    }

    @Test func aPeerFromAnotherUserIsDroppedBeforeReading() throws {
        let server = try server(peerUID: { _ in getuid() &+ 1 })
        defer { server.stop() }
        let seen = Shared<[HookRequest]>([])
        register(server, seen: seen)
        #expect(throws: WireError.self) { try exchange(request()) }
        #expect(seen.value.isEmpty)
    }

    @Test func aStaleSocketFileOfOursIsReplaced() throws {
        let first = try server()
        first.stop(removeFile: false)
        #expect(FileManager.default.fileExists(atPath: socketPath))
        let second = try server()
        defer { second.stop() }
        register(second)
        #expect(try exchange(request()).decision == .allow)
    }

    @Test func stoppingRemovesTheSocketFile() throws {
        let server = try server()
        server.stop()
        #expect(!FileManager.default.fileExists(atPath: socketPath))
    }

    @Test func theSocketPathUsesApplicationSupportOrFallsBackToTheUserTempFolder() {
        let support = URL(fileURLWithPath: "/Users/u/Library/Application Support")
        #expect(HookSocketServer.socketPath(applicationSupport: support, bundleID: "dev.taskforcelabs.taskforce") == "/Users/u/Library/Application Support/dev.taskforcelabs.taskforce/Bridge/hook.sock")
        let long = URL(fileURLWithPath: "/Users/" + String(repeating: "a", count: 60) + "/Library/Application Support")
        let fallback = HookSocketServer.socketPath(applicationSupport: long, bundleID: "dev.taskforcelabs.unittest.taskforce")
        #expect(fallback.utf8.count <= 100)
        #expect(fallback.hasSuffix("/hook.sock"))
        #expect(fallback.contains("/tf-"))
        #expect(fallback != HookSocketServer.socketPath(applicationSupport: long, bundleID: "dev.taskforcelabs.taskforce"), "번들 id마다 다른 소켓 (시험 호스트와 실사용 앱이 섞이지 않는다)")
    }

    /// 앱의 소켓 예산 · 정체 기다림은 계약 값 그대로 (18장: 시험만 init 인자로 넉넉히 준다)
    @Test func theProductionBudgetsAreTheContractBudgets() {
        #expect(HookSocketServer.responseBudget == 1.2 && HookSocketServer.readBudget == 1.0)
        let server = HookSocketServer(path: socketPath)
        #expect(server.responseLimit == 1.2 && server.readLimit == 1.0, "init 기본값")
        #expect(ClaudeCodeTiming.standard.identityWait == 0.8 && ClaudeCodeTiming.testing.identityWait == 0.8)
        // 서버의 답 기한은 그 서버의 예산으로 정한다 (훅 기한이 넉넉하면 자기 예산)
        let started: UInt64 = 100_000_000_000
        #expect(HookSocketServer.deadline(startedNS: started, hookDeadlineNS: started + 9_000_000_000, responseBudget: 3.5) == started + 3_500_000_000)
        #expect(HookSocketServer.deadline(startedNS: started, hookDeadlineNS: started + 3_000_000_000, responseBudget: 3.5) == started + 2_700_000_000, "훅 기한 − 0.3초가 먼저")
    }

    @Test func aSlowHandlerIsCutOffWithADeny() async throws {
        let server = try server(budgets: ClaudeTest.productionSocket)
        defer { server.stop() }
        let answered = Shared<[String]>([])
        // 처리기는 훅 예산보다 훨씬 오래 걸린다: bridge가 자기 예산에서 끊지 않으면 훅 예산까지 답이 없다
        server.register(nonce: Self.nonce, HookSocketServer.Registration(agentSessionID: ClaudeTest.session, providerSessionID: "claude-1", handler: { _ in
            try? await Task.sleep(for: .seconds(60))
            return HookResponse(decision: .allow, reason: "late")
        }, onAnswer: { id in answered.mutate { $0.append(id) } }))
        let started = Date()
        let line = try request()
        let path = socketPath
        let response = try await offPool { try HookResponse.decode(line: UnixSocket.exchange(path: path, request: line, deadline: Date().addingTimeInterval(HookWire.budget))) }
        #expect(response.decision == .deny)
        #expect(Date().timeIntervalSince(started) < HookWire.budget)
        #expect(answered.value == ["toolu_1"], "시간 초과 deny도 bridge가 그 id에 준 답이다 (④)")
    }
}
#endif
