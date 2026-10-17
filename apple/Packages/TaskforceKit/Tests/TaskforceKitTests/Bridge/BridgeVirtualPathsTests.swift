#if os(macOS) && DEBUG
import Foundation
import Testing
@testable import TaskforceKit

/// 서버로 가는 모든 경로 칸은 가상 루트다 (OA D4a2-03 끝까지, 코디네이터 13.11 · 보안 F1): 작업 폴더 `/taskforce/<ws_id>`, 세션 cwd `/taskforce-session/cwd`, 그 밖 `/taskforce-outside`.
/// 값 바꾸기(`VirtualWorkspacePaths`)와, 실제 `ClaudeToolGate` → 런타임 `decideTool` → 가짜 서버 본문까지 한 줄로 본다. 가짜 서버 · 임시 폴더만 쓴다 (실제 `claude` 0)
struct BridgeVirtualPathsTests {
    static let ws = "/Users/tester/Documents/client-a"
    static let cwd = "/Users/tester/Library/Application Support/dev.taskforcelabs.taskforce/Bridge/v1/p/claude-code/5e551011/cwd"
    static let ref = "ws_3f1c2c52-1111-4222-8333-444455556666"
    static let root = "/taskforce/" + ref
    let paths = VirtualWorkspacePaths(workspace: ws, ref: ref, sessionCwd: cwd)

    // MARK: 값 바꾸기

    @Test func theWorkspaceAndEverythingInsideItBecomeTheVirtualRootAndNothingOfTheRealPathSurvives() {
        #expect(paths.virtualPath(Self.ws) == Self.root)
        #expect(paths.virtualPath(Self.ws + "/pricing/page.mdx") == Self.root + "/pricing/page.mdx")
        #expect(paths.virtualPath(Self.cwd) == "/taskforce-session/cwd")
        #expect(paths.virtualPath(Self.cwd + "/scratch.txt") == "/taskforce-session/cwd/scratch.txt")
        #expect(paths.virtualPath("/etc/hosts") == "/taskforce-outside")
        #expect(paths.virtualPath(Self.ws + "-other/x") == "/taskforce-outside", "글자 접두가 같은 형제 폴더는 밖이다 (경로 성분으로 본다)")
        #expect(paths.virtualPath(Self.ws + "/../secret") == "/taskforce-outside", "`..`로 빠지는 길은 안으로 두지 않는다")
        for real in [Self.ws, Self.ws + "/a/b", Self.cwd, "/etc/hosts", Self.ws + "-other/x"] {
            let virtual = paths.virtualPath(real)
            #expect(!virtual.contains("Users") && !virtual.contains("client-a") && !virtual.contains("Library"), "\(virtual)")
        }
    }

    @Test func aVirtualPathComesBackToTheRealPathOnlyInsideTheWorkspaceOrTheSessionFolder() {
        #expect(paths.realPath(Self.root) == Self.ws)
        #expect(paths.realPath(Self.root + "/a/b.txt") == Self.ws + "/a/b.txt")
        #expect(paths.realPath("/taskforce-session/cwd/x") == Self.cwd + "/x")
        #expect(paths.realPath("/taskforce-outside") == nil)
        #expect(paths.realPath("/taskforce/ws_9a9a9a9a-1111-4222-8333-444455556666/x") == nil, "다른 폴더의 가상 루트는 이 세션의 것이 아니다")
        #expect(paths.realPath(Self.root + "/../../etc/passwd") == nil, "서버가 준 `..`로 작업 폴더 밖을 가리키지 못한다")
        #expect(paths.realPath(Self.root + "/./a") == nil)
        #expect(paths.realPath(Self.ws + "/a") == nil, "실제 경로를 가상 경로로 받지 않는다")
    }

    @Test func aFolderTheRegistryDoesNotKnowGetsTheFixedUnregisteredRoot() {
        for ref in [nil, "/Users/tester/Documents/client-a", "workspace-fake", "ws_NOT-A-UUID"] {
            let unregistered = VirtualWorkspacePaths(workspace: Self.ws, ref: ref, sessionCwd: nil)
            #expect(unregistered.virtualRoot == "/taskforce/ws_unregistered", "\(String(describing: ref))")
            #expect(unregistered.virtualPath(Self.ws + "/a") == "/taskforce/ws_unregistered/a")
        }
    }

    @Test func onlyAVirtualRootOfTheExactShapeIsReadBackAsAnID() {
        #expect(VirtualWorkspacePaths.ref(fromVirtualRoot: Self.root) == Self.ref)
        #expect(VirtualWorkspacePaths.virtualRoot(forRef: Self.ref) == Self.root)
        for value in [Self.ref, "/Users/tester/Documents/client-a", Self.root + "/x", Self.root + "/../" + Self.ref, "/taskforce/", "/taskforce/ws_unregistered", "/taskforce/" + Self.ref.uppercased()] {
            #expect(VirtualWorkspacePaths.ref(fromVirtualRoot: value) == nil, "\(value)")
        }
    }

    private func bash(_ cwd: String) -> BridgeV1ToolDecisionQuery {
        BridgeV1ToolDecisionQuery(
            agentSessionID: BridgeHarness.sessionID, agentTaskID: ClaudeTest.task, turnSeq: 3, workspaceRealPath: Self.ws,
            call: .claudeBash(toolUseID: "toolu_1", permissionMode: "default", cwd: cwd, command: "cat pricing.mdx", runInBackground: false, dangerouslyDisableSandbox: false),
            sessionCwdRealPath: Self.cwd
        )
    }

    @Test func everyPathFieldOfEveryCallKindIsVirtualizedAndTheCommandAndRelativePathStayAsTheyAre() {
        let inWorkspace = paths.virtualize(bash(Self.ws))
        #expect(inWorkspace.workspaceRealPath == Self.root && inWorkspace.sessionCwdRealPath == nil)
        guard case .claudeBash(_, _, let cwd, let command, _, _) = inWorkspace.call else { Issue.record("claude_bash"); return }
        #expect(cwd == Self.root && command == "cat pricing.mdx", "명령 원문은 그대로다 (Q8)")
        guard case .claudeBash(_, _, let sessionCwd, _, _, _) = paths.virtualize(bash(Self.cwd)).call else { Issue.record("claude_bash"); return }
        #expect(sessionCwd == "/taskforce-session/cwd")
        guard case .claudeBash(_, _, let elsewhere, _, _, _) = paths.virtualize(bash("/tmp/elsewhere")).call else { Issue.record("claude_bash"); return }
        #expect(elsewhere == "/taskforce-outside")

        let target = BridgeV1ToolTarget(realPath: Self.ws + "/pricing.mdx", relPath: "pricing.mdx")
        let write = paths.virtualize(BridgeV1ToolDecisionQuery(
            agentSessionID: BridgeHarness.sessionID, agentTaskID: ClaudeTest.task, turnSeq: 3, workspaceRealPath: Self.ws,
            call: .claudeWrite(toolUseID: "toolu_2", permissionMode: "default", tool: "Edit", target: target)
        ))
        #expect(write.call == .claudeWrite(toolUseID: "toolu_2", permissionMode: "default", tool: "Edit", target: BridgeV1ToolTarget(realPath: Self.root + "/pricing.mdx", relPath: "pricing.mdx")))

        let codex = paths.virtualize(BridgeV1ToolDecisionQuery(
            agentSessionID: BridgeHarness.sessionID, agentTaskID: ClaudeTest.task, turnSeq: 3, workspaceRealPath: Self.ws,
            call: .codexCommand(providerRequestID: "r1", cwd: Self.ws + "/sub", command: "ls", commandActions: ["read"], firstForItem: true)
        ))
        #expect(codex.call == .codexCommand(providerRequestID: "r1", cwd: Self.root + "/sub", command: "ls", commandActions: ["read"], firstForItem: true))

        let change = paths.virtualize(BridgeV1ToolDecisionQuery(
            agentSessionID: BridgeHarness.sessionID, agentTaskID: ClaudeTest.task, turnSeq: 3, workspaceRealPath: Self.ws,
            call: .codexFileChange(providerRequestID: "r2", targets: [target, BridgeV1ToolTarget(realPath: "/etc/hosts", relPath: "../x")], firstForItem: false)
        ))
        #expect(change.call == .codexFileChange(
            providerRequestID: "r2", targets: [BridgeV1ToolTarget(realPath: Self.root + "/pricing.mdx", relPath: "pricing.mdx"), BridgeV1ToolTarget(realPath: "/taskforce-outside", relPath: "../x")],
            firstForItem: false
        ))
    }

    @Test func theServersVirtualPathsInAParseComeBackAsRealPathsAndWhatCannotComeBackStaysVirtual() {
        let parse = BridgeV1ToolDecisionParse(
            wrapper: "none", argv: ["cat", "a.txt", "b.txt"],
            paths: [.init(index: 1, absolute: Self.root + "/a.txt"), .init(index: 2, absolute: "/taskforce-outside"), .init(index: nil, absolute: "/taskforce-session/cwd")], implicitCwd: false
        )
        let response = BridgeV1ToolDecisionResponse(decision: .allow, reason: .readonlyCommand, parse: parse, agentNote: nil, holder: nil, cardFlags: [], serverTime: Date())
        let restored = paths.restore(response)
        #expect(restored.parse?.paths.map(\.absolute) == [Self.ws + "/a.txt", "/taskforce-outside", Self.cwd])
        #expect(restored.parse?.paths.map(\.index) == [1, 2, nil])
        #expect(restored.parse?.argv == parse.argv && restored.decision == .allow)
        let none = BridgeV1ToolDecisionResponse(decision: .defer, reason: .manualWrite, parse: nil, agentNote: nil, holder: nil, cardFlags: [], serverTime: Date())
        #expect(paths.restore(none) == none)
    }

    // MARK: 실제 게이트 → 런타임 → 가짜 서버

    /// 등록부 resolver를 단 하네스 + 폴더 a의 세션 cwd (실제 폴더)
    struct Rig {
        let base: BridgeWorkspaceRefTests.Rig
        let sessionCwd: String
        let gate: ClaudeToolGate
        let ref: String

        var h: BridgeHarness { base.h }
        var workspace: String { base.path }
        var root: String { VirtualWorkspacePaths.virtualRoot(forRef: ref) }

        init(folder: String = "a") async throws {
            base = try await BridgeWorkspaceRefTests.Rig(pinned: nil)
            try base.registry.setFolder(base.fixture.folder(folder), forProject: UUID())
            ref = try #require(base.registry.ref(forPath: base.fixture.real(folder)))
            let cwdURL = base.fixture.temp.appending("session/cwd")
            try FileManager.default.createDirectory(at: cwdURL, withIntermediateDirectories: true)
            sessionCwd = GateFileSystem.realpath(cwdURL.path) ?? cwdURL.path
            let runtime = base.h.runtime
            gate = ClaudeToolGate(fileSystem: .live, decide: { try await runtime.decideTool($0) }, serverTimeout: .seconds(30))
        }

        func context(session: String = BridgeHarness.sessionID, workspace: String? = nil) -> ClaudeGateContext {
            ClaudeGateContext(
                mode: .normal, access: .write, workspaceRealPath: workspace ?? self.workspace, sessionCwdRealPath: sessionCwd, childPATH: "/usr/bin:/bin", agentSessionID: session,
                agentTaskID: ClaudeTest.task, turnSeq: 3, deferIssued: false, answerDelivered: false
            )
        }

        func evaluate(_ tool: String, _ input: String, cwd: String? = nil, id: String = "toolu_1", context: ClaudeGateContext? = nil) async -> ClaudeGateOutcome {
            await gate.evaluate(ClaudeTest.request(tool, ClaudeTest.json(input), id: id, cwd: cwd ?? sessionCwd), context: context ?? self.context())
        }

        /// 가짜 서버가 받은 tool-decision 본문들
        var bodies: [[String: Any]] { h.server.requests("tool-decision").map(\.json) }
        var wire: String { h.server.requests("tool-decision").map(\.bodyJSON).joined(separator: "\n") }

        func call(_ index: Int) -> [String: Any] { bodies[index]["call"] as? [String: Any] ?? [:] }
    }

    @Test func editWriteAndBashThroughTheRealGateSendOnlyVirtualPathsToTheServer() async throws {
        let r = try await Rig()
        try Data("old".utf8).write(to: URL(fileURLWithPath: r.workspace + "/existing.txt"))
        r.h.server.setToolDecisionResponse(["decision": "defer", "reason": "manual_write", "card_flags": [String]()])
        _ = await r.evaluate("Write", #"{"file_path":"\#(r.workspace)/new.txt","content":"x"}"#, id: "toolu_w")
        _ = await r.evaluate("Edit", #"{"file_path":"\#(r.workspace)/existing.txt","old_string":"old","new_string":"new"}"#, id: "toolu_e")
        r.h.server.setToolDecisionResponse(["decision": "defer", "reason": "command_not_readonly", "card_flags": [String]()])
        _ = await r.evaluate("Bash", #"{"command":"ls"}"#, cwd: r.workspace, id: "toolu_b1")
        _ = await r.evaluate("Bash", #"{"command":"ls"}"#, cwd: r.sessionCwd, id: "toolu_b2")
        _ = await r.evaluate("Bash", #"{"command":"ls"}"#, cwd: r.base.fixture.temp.url.path, id: "toolu_b3")
        #expect(r.bodies.count == 5, "다섯 호출이 모두 서버까지 갔다: \(r.bodies.count)")

        for body in r.bodies { #expect(body["workspace_real_path"] as? String == r.root) }
        #expect((r.call(0)["target"] as? [String: String]) == ["real_path": r.root + "/new.txt", "rel_path": "new.txt"])
        #expect((r.call(1)["target"] as? [String: String]) == ["real_path": r.root + "/existing.txt", "rel_path": "existing.txt"])
        #expect(r.call(2)["cwd"] as? String == r.root, "작업 폴더에서 돈 Bash")
        #expect(r.call(3)["cwd"] as? String == "/taskforce-session/cwd", "세션 cwd에서 돈 Bash")
        #expect(r.call(4)["cwd"] as? String == "/taskforce-outside", "그 밖의 폴더")
        // 가짜 서버가 받은 모든 본문에 이 Mac의 경로 · 홈 이름 · 임시 폴더 이름이 0이다
        for needle in [r.workspace, r.sessionCwd, r.base.fixture.home, r.base.fixture.temp.url.path, "/Users/", "/private/var", r.base.fixture.temp.url.lastPathComponent, "Documents"] {
            #expect(!r.wire.contains(needle), "서버 본문에 \(needle)가 있다")
        }
    }

    @Test func aReadOnlyCommandTheServerAllowsWithAVirtualParseIsRebuiltWithTheRealPath() async throws {
        let r = try await Rig()
        try Data("x".utf8).write(to: URL(fileURLWithPath: r.workspace + "/pricing.mdx"))
        r.h.server.setToolDecisionResponse([
            "decision": "allow", "reason": "readonly_command", "card_flags": [String](),
            "parse": ["wrapper": "none", "argv": ["cat", "pricing.mdx"], "paths": [["index": 1, "absolute": r.root + "/pricing.mdx"]], "implicit_cwd": false] as [String: Any],
        ])
        let outcome = await r.evaluate("Bash", #"{"command":"cat pricing.mdx"}"#, cwd: r.workspace, id: "toolu_cat")
        #expect(outcome.response.decision == .allow, "서버가 준 가상 경로를 되돌려 실제 경로로 확인한다: \(outcome.code)")
        let rebuilt = try #require(outcome.response.command)
        #expect(rebuilt.contains("'" + r.workspace + "/pricing.mdx'") && !rebuilt.contains("/taskforce"), "다시 만든 명령에는 실제 경로만 있다: \(rebuilt)")
        #expect(!r.wire.contains(r.workspace))
    }

    @Test func aVirtualPathThatLeavesTheWorkspaceInTheServersParseIsNotRebuilt() async throws {
        let r = try await Rig()
        r.h.server.setToolDecisionResponse([
            "decision": "allow", "reason": "readonly_command", "card_flags": [String](),
            "parse": ["wrapper": "none", "argv": ["cat", "x"], "paths": [["index": 1, "absolute": r.root + "/../../../etc/hosts"]], "implicit_cwd": false] as [String: Any],
        ])
        let outcome = await r.evaluate("Bash", #"{"command":"cat x"}"#, cwd: r.workspace, id: "toolu_cat")
        #expect(outcome.response.decision != .allow && outcome.code == "parse_check_failed")
    }

    @Test func twoSessionsOnTheSameFolderShareOneVirtualRootAndAnotherFolderHasItsOwn() async throws {
        let r = try await Rig()
        try r.base.registry.setFolder(r.base.fixture.folder("b"), forProject: UUID())
        let otherRef = try #require(r.base.registry.ref(forPath: r.base.fixture.real("b")))
        r.h.server.setToolDecisionResponse(["decision": "defer", "reason": "manual_write", "card_flags": [String]()])
        let input = #"{"file_path":"\#(r.workspace)/shared.txt","content":"x"}"#
        _ = await r.evaluate("Write", input, id: "toolu_1", context: r.context(session: "5e551011-0000-4000-8000-0000000000a1"))
        _ = await r.evaluate("Write", input, id: "toolu_2", context: r.context(session: "5e551011-0000-4000-8000-0000000000a2"))
        let other = r.base.fixture.real("b")
        _ = await r.evaluate("Write", #"{"file_path":"\#(other)/shared.txt","content":"x"}"#, id: "toolu_3", context: r.context(workspace: other))
        let roots = r.bodies.map { $0["workspace_real_path"] as? String }
        #expect(roots == [r.root, r.root, VirtualWorkspacePaths.virtualRoot(forRef: otherRef)], "폴더마다 ws_id 하나 — 같은 폴더면 서로 다른 세션도 같은 열쇠다: \(roots)")
        #expect(otherRef != r.ref)
    }

    @Test func aFolderOutsideTheRegistryIsSentUnderTheFixedUnregisteredRoot() async throws {
        let r = try await Rig()
        let stranger = r.base.fixture.real("c") // 등록하지 않은 폴더
        r.h.server.setToolDecisionResponse(["decision": "defer", "reason": "manual_write", "card_flags": [String]()])
        _ = await r.evaluate("Write", #"{"file_path":"\#(stranger)/x.txt","content":"x"}"#, context: r.context(workspace: stranger))
        #expect(r.bodies.first?["workspace_real_path"] as? String == "/taskforce/ws_unregistered")
        #expect(!r.wire.contains(stranger))
    }

    // MARK: 서버가 돌려준 값 (보안 F3)

    /// 무엇이든 인정하되 부른 값을 적어 두는 resolver. 등록부 resolver처럼 기록된 경로를 인정하지 않는다
    private final class Recording: WorkspaceResolver, @unchecked Sendable {
        private let lock = NSLock()
        private var authorizedValues: [String] = []
        private var pathLookups: [String] = []
        var authorized: [String] { lock.withLock { authorizedValues } }
        var lookups: [String] { lock.withLock { pathLookups } }

        func workspace(forSession sessionID: String, adapter: String) async -> String? { nil }

        func authorize(workspaceRef: String, session sessionID: String, adapter: String) async -> Bool {
            lock.withLock { authorizedValues.append(workspaceRef) }
            return true
        }

        func workspacePath(forRef ref: String) async -> String? {
            lock.withLock { pathLookups.append(ref) }
            return nil
        }

        var recognizesRecordedPaths: Bool { false }
    }

    private func refusal(serverValue: String) async throws -> (reason: String?, started: Int, resolver: Recording) {
        let h = try BridgeHarness(workspace: nil)
        let resolver = Recording()
        h.workspaces = resolver
        try await h.restart(reopenLedger: false)
        await h.registerFirst()
        h.server.ensureSession(id: BridgeHarness.sessionID, bridgeID: h.bridgeID, externalSessionID: "ext-1", workspaceRef: serverValue)
        let created = h.message()
        h.clock.jump(by: 6)
        await h.runtime.tick()
        return (await h.command(created.commandID)?.reason, h.agent.startedTurns.count, resolver)
    }

    @Test func aRawAbsolutePathFromTheServerIsRefusedBeforeAnyResolverCallOrFileSystemAccess() async throws {
        let result = try await refusal(serverValue: "/Users/tester/Documents/client-a")
        #expect(result.reason == "workspace_unauthorized" && result.started == 0)
        #expect(result.resolver.authorized.isEmpty && result.resolver.lookups.isEmpty, "authorize(realpath 조회)를 부르지 않는다: \(result.resolver.authorized) \(result.resolver.lookups)")
    }

    @Test func aBareOpaqueIDWithoutTheVirtualRootIsRefusedTheSameWay() async throws {
        let result = try await refusal(serverValue: "ws_3f1c2c52-1111-4222-8333-444455556666")
        #expect(result.reason == "workspace_unauthorized" && result.started == 0)
        #expect(result.resolver.authorized.isEmpty && result.resolver.lookups.isEmpty)
    }

    @Test func aVirtualRootTheMacNeverIssuedIsLookedUpByIDOnlyAndNeverReachesAuthorize() async throws {
        let result = try await refusal(serverValue: "/taskforce/ws_3f1c2c52-1111-4222-8333-444455556666")
        #expect(result.reason == "workspace_unauthorized" && result.started == 0)
        #expect(result.resolver.lookups == ["ws_3f1c2c52-1111-4222-8333-444455556666"] && result.resolver.authorized.isEmpty)
    }
}
#endif
