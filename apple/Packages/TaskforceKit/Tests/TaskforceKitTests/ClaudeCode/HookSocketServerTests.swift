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

    func server(peerUID: @escaping @Sendable (Int32) -> uid_t? = HookSocketServer.peerUID) throws -> HookSocketServer {
        let server = HookSocketServer(path: socketPath, peerUID: peerUID)
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
        server.unregister(nonce: Self.nonce, after: .milliseconds(100))
        #expect(try exchange(request()).decision == .allow, "끝난 spawn의 nonce는 2초 동안 남는다 (늦은 훅)")
        try await Task.sleep(for: .milliseconds(300))
        #expect(try exchange(request()).decision == .deny)
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

    @Test func aSlowHandlerIsCutOffWithADeny() async throws {
        let server = try server()
        defer { server.stop() }
        let answered = Shared<[String]>([])
        server.register(nonce: Self.nonce, HookSocketServer.Registration(agentSessionID: ClaudeTest.session, providerSessionID: "claude-1", handler: { _ in
            try? await Task.sleep(for: .seconds(3))
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
