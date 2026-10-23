#if os(macOS) && DEBUG
import Darwin
import Foundation
import Testing
import TaskforceAgentWire
@testable import TaskforceKit

/// 이어받기의 런타임 (OA 외부 세션 PR2m, 계약 6.1 · 12.3 · 20장 1–6): 가짜 서버 · 가짜 `claude` · 임시 폴더만 쓴다 (실제 `claude` · 실제 Keychain · 실제 `~/.claude` 0)
@Suite(.serialized)
struct ClaudeAttachRuntimeTests {
    static let claudeID = FakeClaude.claudeID
    static let otherID = FakeClaude.otherClaudeID

    /// 하네스 + 이어받기 가능한 가짜 `claude` + 등록부 resolver. 작업 폴더는 가짜 `claude`의 폴더(홈 아래)다
    final class Rig: @unchecked Sendable {
        let fake: FakeClaude
        let writers: ScriptedWriterCheck
        let h: BridgeHarness
        let registry: WorkspaceRegistry
        let resolver: RegistryWorkspaceResolver
        let partition: URL
        let connection = UUID()
        let agentSession = UUID(uuidString: BridgeHarness.sessionID)!

        init(verdict: ExternalWriterVerdict = .free, version: String = "2.1.306 (Claude Code)", runs: [[String: Any]] = [["steps": [["text": "Resumed"]]]], adapter: Bool = true) async throws {
            writers = ScriptedWriterCheck(verdict)
            fake = try FakeClaude(externalWriters: writers)
            try fake.scenario(["version": version, "runs": runs])
            partition = fake.box.root.appending(path: "partition", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: partition, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            registry = WorkspaceRegistry(file: partition.appending(path: "workspaces.json"), rules: WorkspaceFolderRules(home: fake.box.root.path, systemRoots: []))
            let reads = WorkspaceRegistryResolverTests.Reads()
            resolver = RegistryWorkspaceResolver(registry: registry, sessions: reads, contexts: reads)
            h = try BridgeHarness(workspace: nil)
            h.workspaces = resolver
            try await h.restart(adapters: adapter ? [fake.process] : [], reopenLedger: false)
            await h.registerFirst()
        }

        var folder: String { fake.realWorkspace }

        func facts(_ plan: AttachPlan, external: String? = nil, ref: String? = nil, connection: UUID? = nil, thisMac: UUID?? = nil) -> AttachServerFacts {
            AttachServerFacts(
                externalSessionID: external ?? plan.sessionID, workspaceRef: ref ?? plan.workspaceRef, connectionID: connection ?? self.connection, thisMacConnectionID: thisMac ?? self.connection
            )
        }

        /// 로컬 확인이 하는 일 전부: 준비 → (서버) → 확정
        @discardableResult
        func attach(id: String = ClaudeAttachRuntimeTests.claudeID) async -> (plan: AttachPlan?, refusal: AttachRefusal?) {
            switch await h.runtime.prepareAttach(sessionID: id, folder: folder) {
            case .failure(let refusal): return (nil, refusal)
            case .success(let plan): return (plan, await h.runtime.commitAttach(plan, agentSessionID: agentSession, server: facts(plan)))
            }
        }

        func attachedSession(_ plan: AttachPlan) -> [String: Any] {
            ["external_session_id": plan.sessionID, "workspace_ref": plan.workspaceRef, "resume": true]
        }

        func sendMessage(task: String = UUID().uuidString.lowercased(), turn: Int = 1, session: [String: Any]? = nil) -> FakeBridgeServer.Created {
            h.message("Next", session: BridgeHarness.sessionID, task: task, turn: turn, extra: session.map { ["session": $0] } ?? [:])
        }

        func run(_ created: FakeBridgeServer.Created) async -> String? {
            h.clock.jump(by: 6)
            await h.runtime.tick()
            await h.settle(timeout: 40) { ["idle", "failed", "cancelled"].contains(h.server.taskState(created.taskID) ?? "") }
            return h.server.taskState(created.taskID)
        }

        /// 턴이 끝난 뒤 프로세스가 끝났음을 이 Mac의 원장이 알 때까지 (터미널 · 기록 보기는 도는 실행이 있으면 값을 주지 않는다)
        func quiet(_ created: FakeBridgeServer.Created) async {
            await h.eventually(timeout: 30) { await h.task(created.taskID)?.alive == false }
        }

        /// 접수 전에 거절된(`declined`) 명령의 이유: 서버 task 상태가 아니라 이 Mac의 원장이 말한다
        func refusal(_ created: FakeBridgeServer.Created) async -> String? {
            h.clock.jump(by: 6)
            await h.runtime.tick()
            await h.eventually(timeout: 20) { await h.command(created.commandID)?.state.isFinished == true }
            return await h.command(created.commandID)?.reason
        }

        var registryFile: Data? { try? Data(contentsOf: partition.appending(path: "workspaces.json")) }

        /// 런타임 · adapter 로그 중 Claude id · 폴더 경로가 든 줄: 없어야 한다 (로그는 코드뿐이다)
        func leakyLogLines() -> [String] {
            (h.log.lines + fake.log.lines).filter { line in [ClaudeAttachRuntimeTests.claudeID, ClaudeAttachRuntimeTests.otherID, folder, fake.workspace].contains { line.contains($0) } }
        }
    }

    // MARK: prepare: 쓰지 않고 조건만 본다

    @Test func prepareIssuesAPlanFromLocalFactsAndWritesNothing() async throws {
        let r = try await Rig()
        let result = await r.h.runtime.prepareAttach(sessionID: Self.claudeID, folder: r.folder)
        let plan = try #require(try? result.get())
        #expect(plan.sessionID == Self.claudeID && plan.folder == r.folder && plan.adapter == "agent:claude-code")
        #expect(plan.bridgeID == UUID(uuidString: r.h.bridgeID))
        #expect(WorkspaceRegistry.isOpaqueRef(plan.ref) && plan.workspaceRef == "/taskforce/" + plan.ref, "서버에는 가상 루트만 간다")
        #expect(!plan.workspaceRef.contains(r.folder))
        #expect(r.registryFile == nil && r.registry.pinned(session: BridgeHarness.sessionID) == nil && r.registry.path(forRef: plan.ref) == nil, "등록부에 아무것도 쓰지 않았다")
        #expect(r.fake.state.providerSessionID == nil && !r.fake.state.bound, "상태 폴더도 만들지 않았다")
        #expect(r.writers.calls.count == 1 && r.writers.calls[0].sessionID == Self.claudeID && r.writers.calls[0].workspace == r.folder, "쥔 곳을 이 순간 다시 본다")
    }

    @Test func prepareRefusesWhenSomeoneElseHoldsTheSession() async throws {
        for (verdict, expected) in [
            (ExternalWriterVerdict.held(.claudeApp), AttachRefusal.held(.claudeApp)), (.held(.terminal), .held(.terminal)), (.held(.background), .held(.background)),
            (.held(.unknown), .held(.unknown)), (.unknown, .couldNotCheck),
        ] {
            let r = try await Rig(verdict: verdict)
            let result = await r.h.runtime.prepareAttach(sessionID: Self.claudeID, folder: r.folder)
            #expect(result == .failure(expected), "\(verdict)")
        }
    }

    @Test func prepareRefusesAnIdThatCouldBeAnArgumentOrAPath() async throws {
        let r = try await Rig()
        for bad in [Self.claudeID.uppercased(), "-r", "../x", "/tmp/a.jsonl", Self.claudeID + " ", "pending:" + Self.claudeID, ""] {
            #expect(await r.h.runtime.prepareAttach(sessionID: bad, folder: r.folder) == .failure(.unreadable), "\(bad)")
        }
        #expect(r.writers.calls.isEmpty, "디스크 · 프로세스를 보기 전에 거절한다")
    }

    @Test func prepareRefusesAFolderTheRulesOrTheOverlapRuleRefuse() async throws {
        let r = try await Rig()
        for path in ["/", r.fake.box.root.path, r.fake.box.root.path + "/.ssh", "/tmp", r.fake.box.root.path + "/missing", "relative"] {
            #expect(await r.h.runtime.prepareAttach(sessionID: Self.claudeID, folder: path) == .failure(.folder), "\(path)")
        }
        // 프로젝트 폴더의 자손은 겹친다 (계약 13.13)
        try r.registry.setFolder(r.folder, forProject: UUID())
        let sub = r.folder + "/sub"
        try FileManager.default.createDirectory(atPath: sub, withIntermediateDirectories: true)
        #expect(await r.h.runtime.prepareAttach(sessionID: Self.claudeID, folder: sub) == .failure(.folder))
        #expect(r.writers.calls.isEmpty)
    }

    @Test func prepareRefusesAnOldOrMissingClaudeCode() async throws {
        let old = try await Rig(version: "2.1.241 (Claude Code)")
        #expect(await old.h.runtime.prepareAttach(sessionID: Self.claudeID, folder: old.folder) == .failure(.version), "2.1.257 미만")
        let unsupported = try await Rig(version: "2.2.0 (Claude Code)")
        #expect(await unsupported.h.runtime.prepareAttach(sessionID: Self.claudeID, folder: unsupported.folder) == .failure(.version), "adapter 범위 밖")
        #expect(old.writers.calls.isEmpty && unsupported.writers.calls.isEmpty)
    }

    @Test func prepareRefusesWithoutAnAdapterOrWithoutTheRegistryResolver() async throws {
        let bare = try await Rig(adapter: false)
        #expect(await bare.h.runtime.prepareAttach(sessionID: Self.claudeID, folder: bare.folder) == .failure(.notReady))
        // 등록부가 아닌 resolver(가짜 · Debug 일회용)면 이어받지 않는다
        let r = try await Rig()
        r.h.workspaces = nil
        try await r.h.restart(adapters: [r.fake.process], reopenLedger: false)
        await r.h.registerFirst()
        #expect(await r.h.runtime.prepareAttach(sessionID: Self.claudeID, folder: r.folder) == .failure(.notReady))
    }

    @Test func prepareRefusesBeforeThisMacHasABridge() async throws {
        let r = try await Rig()
        try await r.h.wipeLedger()
        try await r.h.restart(adapters: [r.fake.process], reopenLedger: true)
        #expect(await r.h.runtime.prepareAttach(sessionID: Self.claudeID, folder: r.folder) == .failure(.notReady), "등록 전: 서버에 보낼 bridge id가 없다")
    }

    @Test func aSecondPrepareForTheSameSessionWaitsUntilTheFirstIsDoneOrCancelled() async throws {
        let r = try await Rig()
        let plan = try #require(try? await r.h.runtime.prepareAttach(sessionID: Self.claudeID, folder: r.folder).get())
        #expect(await r.h.runtime.prepareAttach(sessionID: Self.claudeID, folder: r.folder) == .failure(.notReady), "같은 id에 대한 Resume here 두 번은 하나만 (9.2)")
        await r.h.runtime.cancelAttach(plan)
        #expect((try? await r.h.runtime.prepareAttach(sessionID: Self.claudeID, folder: r.folder).get()) != nil)
        // 다른 id는 서로 막지 않는다
        #expect((try? await r.h.runtime.prepareAttach(sessionID: Self.otherID, folder: r.folder).get()) != nil)
    }

    @Test func anOldUnfinishedPlanDoesNotBlockForever() async throws {
        let r = try await Rig()
        _ = try #require(try? await r.h.runtime.prepareAttach(sessionID: Self.claudeID, folder: r.folder).get())
        r.h.clock.jump(by: 600)
        #expect((try? await r.h.runtime.prepareAttach(sessionID: Self.claudeID, folder: r.folder).get()) != nil)
    }

    // MARK: commit: 서버 답이 이 Mac의 계획과 맞을 때만 핀 · 상태

    @Test func aMatchingAnswerPinsTheFolderAndBindsTheAttachedState() async throws {
        let r = try await Rig()
        let (plan, refusal) = await r.attach()
        #expect(refusal == nil)
        let issued = try #require(plan)
        #expect(r.registry.pinned(session: BridgeHarness.sessionID) == r.folder && r.registry.path(forRef: issued.ref) == r.folder, "ES-08: 서버가 방금 쓴 id가 이 Mac의 핀이다")
        let state = r.fake.state
        #expect(state.origin == .attached && state.bound && state.providerSessionID == Self.claudeID && state.attachedAt == r.h.clock.now)
        #expect(await r.fake.process.isAttached(agentSession: BridgeHarness.sessionID))
        // 서버에는 경로가 한 글자도 가지 않았다
        #expect(!r.h.server.requests.map(\.bodyJSON).joined().contains(r.folder))
        #expect(r.leakyLogLines().isEmpty, "준비 · 확정이 도는 동안 로그에 id · 경로 0")
    }

    @Test func anAnswerThatDoesNotMatchThePlanIsRefusedAndWritesNothing() async throws {
        let other = UUID()
        let cases: [(String, (Rig, AttachPlan) -> AttachServerFacts)] = [
            ("다른 Claude id", { r, plan in r.facts(plan, external: Self.otherID) }),
            ("대문자 id", { r, plan in r.facts(plan, external: plan.sessionID.uppercased()) }),
            ("다른 가상 루트", { r, plan in r.facts(plan, ref: "/taskforce/ws_" + UUID().uuidString.lowercased()) }),
            ("실제 경로", { r, plan in r.facts(plan, ref: r.folder) }),
            ("다른 Mac의 연결", { r, plan in r.facts(plan, connection: other) }),
            ("이 Mac의 연결을 모름", { r, plan in r.facts(plan, thisMac: .some(nil)) }),
        ]
        for (name, make) in cases {
            let r = try await Rig()
            let plan = try #require(try? await r.h.runtime.prepareAttach(sessionID: Self.claudeID, folder: r.folder).get())
            let refusal = await r.h.runtime.commitAttach(plan, agentSessionID: r.agentSession, server: make(r, plan))
            #expect(refusal == .server, "\(name)")
            #expect(r.registry.pinned(session: BridgeHarness.sessionID) == nil && r.registryFile == nil, "\(name): 핀을 꽂지 않았다")
            #expect(r.fake.state.providerSessionID == nil && !r.fake.state.bound && r.fake.state.origin == nil, "\(name): 상태를 쓰지 않았다")
            #expect(!(await r.fake.process.isAttached(agentSession: BridgeHarness.sessionID)), "\(name)")
            #expect(r.leakyLogLines().isEmpty, "\(name): 거절해도 로그에 id · 경로 0")
        }
    }

    @Test func aPlanTheRuntimeNeverIssuedOrAlreadyUsedCannotCommit() async throws {
        let r = try await Rig()
        let plan = try #require(try? await r.h.runtime.prepareAttach(sessionID: Self.claudeID, folder: r.folder).get())
        #expect(await r.h.runtime.commitAttach(plan, agentSessionID: r.agentSession, server: r.facts(plan)) == nil)
        // 같은 계획으로 다시 확정할 수 없다 (한 번 쓰면 거둔다)
        #expect(await r.h.runtime.commitAttach(plan, agentSessionID: UUID(), server: r.facts(plan)) == .notReady)
        // 다른 id를 위조한 계획 (앱이 만든 값이 아니다)
        let forged = AttachPlan.forTest(sessionID: Self.otherID, folder: r.folder, ref: plan.ref, bridgeID: plan.bridgeID, adapter: plan.adapter)
        #expect(await r.h.runtime.commitAttach(forged, agentSessionID: UUID(), server: r.facts(forged)) == .notReady)
        #expect(r.fake.state.providerSessionID == Self.claudeID)
    }

    @Test func aPlanIsDeadAfterItsTimeAndAfterCancel() async throws {
        let r = try await Rig()
        let plan = try #require(try? await r.h.runtime.prepareAttach(sessionID: Self.claudeID, folder: r.folder).get())
        r.h.clock.jump(by: 600)
        #expect(await r.h.runtime.commitAttach(plan, agentSessionID: r.agentSession, server: r.facts(plan)) == .notReady)
        let again = try #require(try? await r.h.runtime.prepareAttach(sessionID: Self.claudeID, folder: r.folder).get())
        await r.h.runtime.cancelAttach(again)
        #expect(await r.h.runtime.commitAttach(again, agentSessionID: r.agentSession, server: r.facts(again)) == .notReady)
        #expect(r.fake.state.providerSessionID == nil && r.registry.pinned(session: BridgeHarness.sessionID) == nil)
    }

    @Test func aWriterThatAppearedWhileTheServerWasAnsweringStopsTheCommit() async throws {
        let r = try await Rig()
        let plan = try #require(try? await r.h.runtime.prepareAttach(sessionID: Self.claudeID, folder: r.folder).get())
        r.writers.next(.held(.claudeApp))
        #expect(await r.h.runtime.commitAttach(plan, agentSessionID: r.agentSession, server: r.facts(plan)) == .held(.claudeApp), "데스크톱이 그 사이 열었다")
        #expect(r.registry.pinned(session: BridgeHarness.sessionID) == nil && r.fake.state.providerSessionID == nil)
    }

    @Test func aSessionAlreadyPinnedToAnotherFolderOrBoundToAnotherIdIsNeverOverwritten() async throws {
        // 핀: 이미 다른 폴더에 꽂혀 있다
        let pinned = try await Rig()
        let elsewhere = pinned.fake.box.root.path + "/elsewhere"
        try FileManager.default.createDirectory(atPath: elsewhere, withIntermediateDirectories: true)
        try pinned.registry.pin(session: BridgeHarness.sessionID, to: elsewhere)
        let plan = try #require(try? await pinned.h.runtime.prepareAttach(sessionID: Self.claudeID, folder: pinned.folder).get())
        #expect(await pinned.h.runtime.commitAttach(plan, agentSessionID: pinned.agentSession, server: pinned.facts(plan)) == .folder)
        #expect(pinned.registry.pinned(session: BridgeHarness.sessionID) == GateFileSystem.realpath(elsewhere) && pinned.fake.state.providerSessionID == nil)
        // 상태: 이미 다른 Claude id로 묶였다
        let bound = try await Rig()
        try bound.fake.attach(provider: Self.otherID, session: BridgeHarness.sessionID)
        let second = try #require(try? await bound.h.runtime.prepareAttach(sessionID: Self.claudeID, folder: bound.folder).get())
        #expect(await bound.h.runtime.commitAttach(second, agentSessionID: bound.agentSession, server: bound.facts(second)) == .inUse)
        #expect(bound.fake.stateOf(BridgeHarness.sessionID).providerSessionID == Self.otherID, "20장 3: 다른 id로 덮지 않는다")
    }

    @Test func aClaudeSessionAnotherTaskforceSessionAlreadyHoldsIsRefusedAtCommit() async throws {
        let r = try await Rig()
        try r.fake.attach(provider: Self.claudeID, session: "5e551011-0000-4000-8000-0000000000e2")
        let plan = try #require(try? await r.h.runtime.prepareAttach(sessionID: Self.claudeID, folder: r.folder).get())
        #expect(await r.h.runtime.commitAttach(plan, agentSessionID: r.agentSession, server: r.facts(plan)) == .inUse, "한 Claude 세션에 writer 하나")
        #expect(r.fake.state.providerSessionID == nil)
    }

    @Test func pressingAgainAfterAHalfFinishedAttachCompletesItInsteadOfFailing() async throws {
        let r = try await Rig()
        // 핀만 꽂히고 상태 쓰기 전에 앱이 멈췄다 (6.1-4)
        let proposal = try #require(r.registry.proposedRef(forPath: r.folder))
        #expect(r.registry.attachPin(session: BridgeHarness.sessionID, to: r.folder, ref: proposal.ref) == .pinned(ref: proposal.ref))
        #expect(!(await r.fake.process.isAttached(agentSession: BridgeHarness.sessionID)))
        // 다시 누르면 서버는 같은 행을 돌려주고 (이 Mac의 핀과 같은 폴더) 나머지를 마친다
        let (plan, refusal) = await r.attach()
        #expect(refusal == nil && plan?.ref == proposal.ref)
        #expect(await r.fake.process.isAttached(agentSession: BridgeHarness.sessionID))
        // 또 눌러도 멱등이다
        let (_, again) = await r.attach()
        #expect(again == nil && r.fake.state.providerSessionID == Self.claudeID)
    }

    @Test func aShuttingDownRuntimeDoesNotAttach() async throws {
        let r = try await Rig()
        let plan = try #require(try? await r.h.runtime.prepareAttach(sessionID: Self.claudeID, folder: r.folder).get())
        await r.h.runtime.shutdown(interrupt: false)
        #expect(await r.h.runtime.commitAttach(plan, agentSessionID: r.agentSession, server: r.facts(plan)) == .notReady)
        #expect(await r.h.runtime.prepareAttach(sessionID: Self.otherID, folder: r.folder) == .failure(.notReady))
        #expect(r.fake.state.providerSessionID == nil)
    }

    // MARK: 20장 1: 명령 · 서버가 시작한 길은 핀 · 상태를 쓰지 못한다

    @Test func aCommandForASessionNobodyAttachedWritesNoStateAndNoPinAndStartsNothing() async throws {
        // 서버(또는 탈취된 서버)가 이 Mac의 아무 Claude id나 이어 띄우라고 하는 명령: 가상 루트도 이 Mac이 만든 값처럼 보낸다
        let r = try await Rig()
        try r.registry.setFolder(r.folder, forProject: UUID())
        let ref = try #require(r.registry.ref(forPath: r.folder))
        let created = r.sendMessage(session: ["external_session_id": Self.claudeID, "workspace_ref": "/taskforce/" + ref, "resume": true])
        #expect(await r.refusal(created) == "workspace_unauthorized", "이 세션의 핀이 아닌 폴더: 접수 전 거절")
        #expect(r.fake.runCount == 0, "띄우기 0")
        #expect(r.fake.state.providerSessionID == nil && !r.fake.state.bound && r.fake.state.origin == nil, "상태 0")
        #expect(r.registry.pinned(session: BridgeHarness.sessionID) == nil, "핀 0 (명령은 핀을 꽂지 못한다)")
        #expect(r.writers.calls.isEmpty)
    }

    @Test func aCommandForAPinnedSessionThatWasNeverAttachedStartsNothingEither() async throws {
        let r = try await Rig()
        try r.registry.pin(session: BridgeHarness.sessionID, to: r.folder)
        let ref = try #require(r.registry.ref(forPath: r.folder))
        let created = r.sendMessage(session: ["external_session_id": Self.claudeID, "workspace_ref": "/taskforce/" + ref, "resume": true])
        #expect(await r.run(created) == "failed", "접수 전 실패 (Session didn't start): 이 Mac이 묶은 id가 아니다")
        #expect(r.fake.runCount == 0)
        #expect(r.fake.state.providerSessionID == nil && !r.fake.state.bound && r.fake.state.origin == nil, "상태 0 (명령은 상태를 쓰지 못한다)")
        #expect(r.writers.calls.isEmpty)
    }

    @Test func aServerThatNamesAnotherClaudeIdForAnAttachedSessionStartsNothing() async throws {
        let r = try await Rig()
        let (plan, _) = await r.attach()
        let issued = try #require(plan)
        r.h.clock.jump(by: 30)
        var session = r.attachedSession(issued)
        session["external_session_id"] = Self.otherID
        let created = r.sendMessage(session: session)
        #expect(await r.run(created) == "failed")
        #expect(r.fake.runCount == 0 && r.fake.state.providerSessionID == Self.claudeID, "T6: 서버가 다른 UUID를 보냄 → 띄우기 0")
    }

    // MARK: 20장 4 · 5 · 6: 이어받은 뒤의 턴

    @Test func aTurnAfterTheAttachRunsInTheOriginalFolderWithTheIsolatedArguments() async throws {
        let r = try await Rig()
        let (plan, _) = await r.attach()
        let issued = try #require(plan)
        r.h.clock.jump(by: 30)
        let created = r.sendMessage(session: r.attachedSession(issued))
        #expect(await r.run(created) == "idle")
        let report = try #require(r.fake.report(0))
        #expect(report["resume"] as? Bool == true && report["session_id"] as? String == Self.claudeID)
        #expect(report["cwd"] as? String == r.folder && report["setting_sources"] as? String == "" && report["snapshot_off"] as? Bool == true)
        #expect(r.writers.calls.count == 3, "준비 · 확정(서버 답을 기다린 사이를 다시 본다) · 턴 직전: 세 번 본다")
    }

    @Test func aCommandCreatedBeforeTheLocalAttachIsRefused() async throws {
        let r = try await Rig()
        // 서버가 사용자의 확인 전에 미리 쌓아 둔 명령 (같은 세션으로 보이는 task)
        let plan0 = try #require(try? await r.h.runtime.prepareAttach(sessionID: Self.claudeID, folder: r.folder).get())
        let early = r.sendMessage(session: r.attachedSession(plan0))
        r.h.clock.jump(by: 120)
        #expect(await r.h.runtime.commitAttach(plan0, agentSessionID: r.agentSession, server: r.facts(plan0)) == nil)
        r.h.clock.jump(by: 5)
        #expect(await r.refusal(early) == "command_before_attach", "20장 6: 로컬 핀 시각보다 먼저 만들어진 명령은 거절한다")
        #expect(r.fake.runCount == 0)
        // 확인 뒤에 만든 명령은 돈다
        let later = r.sendMessage(session: r.attachedSession(plan0))
        #expect(await r.run(later) == "idle")
        #expect(r.fake.runCount == 1)
    }

    @Test func aCommandJustBeforeTheAttachWithinTheClockToleranceStillRuns() async throws {
        let r = try await Rig()
        let plan = try #require(try? await r.h.runtime.prepareAttach(sessionID: Self.claudeID, folder: r.folder).get())
        let near = r.sendMessage(session: r.attachedSession(plan))
        r.h.clock.jump(by: 1)
        #expect(await r.h.runtime.commitAttach(plan, agentSessionID: r.agentSession, server: r.facts(plan)) == nil)
        #expect(await r.run(near) == "idle", "시계 추정 오차(2초) 안은 거절하지 않는다")
    }

    /// 계약 20장 6의 판정 자체: 서버가 만든 시각을 모르면 이어받은 세션의 명령은 막고, 이어받지 않은 세션은 시각과 상관없이 통과한다
    @Test func aCommandWhoseServerTimeIsUnknownIsRefusedOnlyForAnAttachedSession() async throws {
        let r = try await Rig()
        var record = BridgeCommandRecord(
            commandID: UUID().uuidString.lowercased(), kind: "message", agentSessionID: BridgeHarness.sessionID, agentTaskID: UUID().uuidString.lowercased(), turnSeq: 1, cursor: 1,
            state: .seen, stateAt: r.h.clock.now
        )
        #expect(record.serverCreatedAt == nil)
        let before = await r.h.runtime.commandPostdatesAttach(record, adapter: r.fake.process, session: BridgeHarness.sessionID)
        #expect(before, "아무도 이어받지 않은 세션: 시각과 상관없이 통과")
        await r.attach()
        let unknown = await r.h.runtime.commandPostdatesAttach(record, adapter: r.fake.process, session: BridgeHarness.sessionID)
        #expect(!unknown, "서버가 만든 시각을 모르면 막는다")
        record.serverCreatedAt = r.h.clock.now.addingTimeInterval(-60)
        let older = await r.h.runtime.commandPostdatesAttach(record, adapter: r.fake.process, session: BridgeHarness.sessionID)
        #expect(!older, "이어받기보다 먼저 만들어진 명령")
        record.serverCreatedAt = r.h.clock.now.addingTimeInterval(60)
        let newer = await r.h.runtime.commandPostdatesAttach(record, adapter: r.fake.process, session: BridgeHarness.sessionID)
        #expect(newer, "이어받은 뒤에 만들어진 명령")
    }

    @Test func aTurnIsBlockedWhileTheClaudeAppHoldsTheSessionAndTheReasonIsKept() async throws {
        let r = try await Rig()
        let (plan, _) = await r.attach()
        let issued = try #require(plan)
        r.h.clock.jump(by: 30)
        r.writers.next(.held(.claudeApp))
        let blocked = r.sendMessage(session: r.attachedSession(issued))
        #expect(await r.run(blocked) == "failed", "접수 전 실패: Session didn't start")
        #expect(r.fake.runCount == 0)
        #expect(await r.h.runtime.attachedHold(forAgentSession: r.agentSession) == .held(.claudeApp), "세션 패널 DZ-8: Running in Claude")
        // 닫은 뒤의 턴은 돈다 (이유가 사라진다)
        let free = r.sendMessage(task: UUID().uuidString.lowercased(), turn: 2, session: r.attachedSession(issued))
        #expect(await r.run(free) == "idle")
        #expect(await r.h.runtime.attachedHold(forAgentSession: r.agentSession) == nil)
    }

    // MARK: 터미널 · 보기 (ES-15b)

    @Test func theTerminalAndTheTranscriptViewUseTheOriginalFolderAsTheSessionCwd() async throws {
        let r = try await Rig()
        let (plan, _) = await r.attach()
        let issued = try #require(plan)
        r.h.clock.jump(by: 30)
        let created = r.sendMessage(session: r.attachedSession(issued))
        #expect(await r.run(created) == "idle")
        await r.quiet(created)
        let target = try #require(await r.h.runtime.terminalTarget(forAgentSession: r.agentSession))
        #expect(target.providerSessionID == Self.claudeID && target.folder == r.folder && target.sessionCwd == r.folder, "기록이 원래 폴더의 프로젝트 디렉터리에 있다")
        let view = try #require(await r.h.runtime.localTranscriptTarget(forAgentSession: r.agentSession))
        #expect(view.providerSessionID == Self.claudeID && view.cwd == r.folder)
    }

    /// 계약 20장 4: 기록 경로로 대신하지 않는다 — 등록부가 지금도 인정하는 핀 폴더가 아니면 기록 보기도 터미널도 값이 없다
    @Test func anAttachedSessionWhoseFolderIsNoLongerAllowedHasNeitherATranscriptNorATerminalTarget() async throws {
        let r = try await Rig()
        let (plan, _) = await r.attach()
        let issued = try #require(plan)
        r.h.clock.jump(by: 30)
        let created = r.sendMessage(session: r.attachedSession(issued))
        #expect(await r.run(created) == "idle")
        await r.quiet(created)
        let viewBefore = await r.h.runtime.localTranscriptTarget(forAgentSession: r.agentSession)
        let terminalBefore = await r.h.runtime.terminalTarget(forAgentSession: r.agentSession)
        #expect(viewBefore != nil && terminalBefore != nil)
        try FileManager.default.removeItem(atPath: r.folder)
        #expect(await r.h.runtime.localTranscriptTarget(forAgentSession: r.agentSession) == nil, "핀 폴더가 규칙을 더는 통과하지 못하면 다른 경로로 기록을 찾지 않는다")
        #expect(await r.h.runtime.terminalTarget(forAgentSession: r.agentSession) == nil)
    }

    @Test func aTaskforceStartedSessionKeepsItsPrivateSessionCwdForTheTerminal() async throws {
        let r = try await Rig(runs: [["steps": [["text": "Hello"]]]])
        try r.registry.pin(session: BridgeHarness.sessionID, to: r.folder)
        let created = r.sendMessage()
        #expect(await r.run(created) == "idle")
        await r.quiet(created)
        let target = try #require(await r.h.runtime.terminalTarget(forAgentSession: r.agentSession))
        #expect(target.sessionCwd != r.folder && target.sessionCwd.hasSuffix("/cwd"), "새 세션은 빈 세션 cwd (기존 동작 그대로)")
    }
}

extension AttachPlan {
    /// 시험 전용: 앱이 만들지 않은 계획을 위조한다 (Release에는 없다 — 이 파일은 Debug 시험뿐이다)
    static func forTest(sessionID: String, folder: String, ref: String, bridgeID: UUID, adapter: String) -> AttachPlan {
        AttachPlan(sessionID: sessionID, folder: folder, ref: ref, bridgeID: bridgeID, adapter: adapter, nonce: UUID(), issuedAt: Date())
    }
}
#endif
