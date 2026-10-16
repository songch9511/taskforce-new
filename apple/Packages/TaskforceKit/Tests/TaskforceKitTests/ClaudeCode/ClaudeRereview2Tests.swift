#if os(macOS) && DEBUG
import Darwin
import Foundation
import Synchronization
import Testing
import TaskforceAgentWire
@testable import TaskforceKit

/// 재검토 2 반영 (OA D3a 계약 10장) — 고친 뒤의 API로 보는 시험. 재현은 `ClaudeRereview2ReproTests`. 이름 앞의 `cN`이 10장 항목 번호다
@Suite(.serialized)
struct ClaudeRereview2Tests {
    let box = ClaudeSandbox()
    static let timing = ClaudeCodeTiming.testing

    struct Root {
        let process: ClaudeSpawnedProcess
        let identity: AgentProcessIdentity
    }

    /// 실제 adapter처럼 띄운다 (새 그룹 · argv의 `--settings …/config/<marker>.settings.json`)
    func spawn(_ script: String, marker: String = UUID().uuidString) throws -> Root {
        let settings = box.root.appending(path: "config/\(marker).settings.json").path
        let process = try ClaudeSpawner.spawn(
            executable: "/bin/sh", arguments: ["-c", script, "sh", "--settings", settings], environment: ["PATH": "/usr/bin:/bin", ClaudeProcessInspector.markerKey: marker],
            cwd: box.root.path
        )
        process.closeStandardStreams()
        return Root(process: process, identity: AgentProcessIdentity(pid: Int(process.pid), startedAt: process.startedAt, processMarker: marker))
    }

    // MARK: 2 같은 세대

    @Test func c2ACandidateWhoseListedGenerationDiffersIsDropped() async throws {
        let pidFile = box.root.appending(path: "kid.pid").path
        let root = try spawn("/bin/sleep 30 & echo $! > '\(pidFile)'; while :; do sleep 1; done")
        defer { _ = ClaudeProcessInspector.forceKill(root.process) }
        let kid = try await ClaudeProcessIdentityTests.readPID(pidFile)
        let kidID = try #require(ClaudeProcessInspector.uniqueIDs(pid: kid)?.own)
        let lineage = ClaudeLineage()
        lineage.seed(root.process.pid)
        // 목록이 본 그 pid의 시작 시각이 지금 세대와 다르다 (목록과 id 읽기 사이에 pid가 재사용된 것과 같다): 소속을 정하지 않고 버린다
        var listed = try #require(ClaudeProcessInspector.userProcessInfos())
        for index in listed.indices where listed[index].kp_proc.p_pid == kid { listed[index].kp_proc.p_un.__p_starttime.tv_sec -= 1 }
        let members = try #require(ClaudeProcessInspector.descendants(root.identity, lineage: lineage, processes: listed))
        #expect(!members.contains { $0.pid == kid })
        #expect(!lineage.contains(kidID), "다른 세대의 id를 혈통에 넣지 않는다")
        // 목록이 맞으면 같은 그룹 · 부모로 찾는다
        #expect(ClaudeProcessInspector.descendants(root.identity, lineage: lineage)?.contains(ClaudeProcessInspector.Member(pid: kid, uniqueID: kidID)) == true)
    }

    // MARK: 3 부팅 · 하한

    @Test func c3ALineageFromAnotherBootIsEndedWithoutAScanOrASignal() async throws {
        let pidFile = box.root.appending(path: "orphan.pid").path
        let marker = UUID().uuidString
        let root = try spawn("/usr/bin/perl -e 'use POSIX; POSIX::setsid(); open(F, q(>\(pidFile))); print F $$; close F; sleep 600;' & sleep 0.3; exit 0", marker: marker)
        let file = box.sessionsRoot.appending(path: "lineage/\(marker).lineage")
        let before = ClaudeLineage(file: file, fresh: true)
        before.seed(root.process.pid)
        before.save(force: true)
        _ = try await offPool { root.process.waitForExit() }
        let orphan = try await ClaudeProcessIdentityTests.readPID(pidFile)
        defer { kill(orphan, SIGKILL) }
        #expect(ClaudeProcessInspector.liveness(root.identity, lineage: ClaudeLineage(file: file)) == .alive)
        // 같은 파일이 다른 부팅에 적힌 것이라면: 그 spawn은 이미 끝났다 (id는 부팅마다 새로 센다)
        let lines = try String(contentsOf: file, encoding: .utf8).split(separator: "\n").map(String.init)
        try (([lines[0], "boot " + UUID().uuidString] + lines.dropFirst(2)).joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
        let other = ClaudeLineage(file: file)
        #expect(other.fromOtherBoot)
        #expect(ClaudeProcessInspector.liveness(root.identity, lineage: other) == .ended(AgentExit(code: nil)))
        let timing = Self.timing
        #expect(try await offPool { ClaudeProcessInspector.terminate(root.identity, timing: timing, lineage: other) } == .ended(AgentExit(code: nil)))
        #expect(kill(orphan, 0) == 0, "다른 부팅의 혈통으로는 신호를 보내지 않는다")
        // 다시 뜬 adapter도 끝으로 본다. 다른 부팅의 파일은 앱이 뜰 때 purge가 지운다 (11장 1: 확인할 때는 지우지 않는다 — 다시 물어도 끝)
        let adapter = ClaudeCodeProcess(sessionsRoot: box.sessionsRoot, hookServer: nil, helpers: ClaudeCodeHelpers(hook: "/x", mcp: "/y"),
                                        locator: ClaudeCodeLocator(candidates: [], confinedTo: box.root.path), timing: .testing)
        #expect(await adapter.liveness(root.identity) == .ended(AgentExit(code: nil)))
        #expect(await adapter.liveness(root.identity) == .ended(AgentExit(code: nil)))
        // 앱이 뜰 때: 지우지 않고 이번 부팅의 끝 기록으로 바꾼다 (결정 11-1)
        adapter.purgeLineageOfOtherBoots()
        #expect(ClaudeLineage.load(file) == .ended)
        #expect(await adapter.liveness(root.identity) == .ended(AgentExit(code: nil)))
    }

    @Test func c3AProcessCreatedBeforeTheRootIsNeverADescendant() async throws {
        // 뿌리보다 먼저 만들어진 무관한 프로세스, 그 id가 (깨졌거나 끼워 넣은) 혈통에 있다
        let victim = try ClaudeSpawner.spawn(executable: "/bin/sleep", arguments: ["30"], environment: ["PATH": "/bin"], cwd: box.root.path)
        victim.closeStandardStreams()
        defer { _ = ClaudeProcessInspector.forceKill(victim) }
        let victimID = try #require(ClaudeProcessInspector.uniqueIDs(pid: victim.pid)?.own)
        let root = try spawn("exit 0")
        let lineage = ClaudeLineage()
        lineage.seed(root.process.pid)
        lineage.insert(victimID)
        _ = try await offPool { root.process.waitForExit() }
        #expect(ClaudeProcessInspector.descendants(root.identity, lineage: lineage)?.contains { $0.pid == victim.pid } == false)
        let timing = Self.timing
        #expect(try await offPool { ClaudeProcessInspector.terminate(root.identity, timing: timing, lineage: lineage) } == .ended(AgentExit(code: nil)))
        #expect(kill(victim.pid, 0) == 0, "뿌리보다 먼저 만들어진 프로세스에는 신호 0")
    }

    @Test func c3ADescendantIsFoundEvenWhenTheWallClockSaysItStartedBeforeTheRoot() async throws {
        let pidFile = box.root.appending(path: "clock.pid").path
        let root = try spawn("/usr/bin/perl -e 'use POSIX; POSIX::setsid(); open(F, q(>\(pidFile))); print F $$; close F; sleep 600;' & sleep 0.3; exit 0")
        let lineage = ClaudeLineage()
        lineage.seed(root.process.pid)
        _ = try await offPool { root.process.waitForExit() }
        let orphan = try await ClaudeProcessIdentityTests.readPID(pidFile)
        defer { kill(orphan, SIGKILL) }
        // 원장의 시작 시각이 한 시간 뒤로 적혔다 (벽시계가 움직였다): 자손의 벽시계 시작 시각은 그보다 앞이지만 id 순서로 자손이다
        var identity = root.identity
        identity.startedAt = identity.startedAt.addingTimeInterval(3600)
        #expect(ClaudeProcessInspector.descendants(identity, lineage: lineage)?.contains { $0.pid == orphan } == true)
    }

    // MARK: 4 비용 · 정리

    /// 전체 다시 쓰기(정리)는 0.5초씩 묶는다 (11장 3 뒤: 새 id는 바로 덧붙고, 덧붙이지 못한 것만 정리가 다시 쓴다). 덧붙이지 못한 사이 파일은 없다 (12장 5)
    @Test func c4LineageSavesAreBatchedExceptTheForcedFirstOne() throws {
        let file = box.root.appending(path: "lineage/batch.lineage")
        let lineage = ClaudeLineage(file: file, fresh: true)
        lineage.seed(getpid())
        lineage.insert(11)
        lineage.save(force: true)
        #expect(try String(contentsOf: file, encoding: .utf8).contains("\n11 0\n"))
        // 덧붙이기가 실패하게 (읽기 전용): 정리할 것이 생긴다. 그 사이 파일은 지워져 증거 없음이다
        chmod(file.path, 0o400)
        lineage.insert(12)
        lineage.save()
        #expect(!FileManager.default.fileExists(atPath: file.path), "0.5초 안에는 다시 쓰지 않는다 (그동안 파일 없음)")
        #expect(!ClaudeLineage(file: file).hasEvidence)
        Thread.sleep(forTimeInterval: ClaudeLineage.saveInterval + 0.1)
        lineage.save()
        #expect(try String(contentsOf: file, encoding: .utf8).contains("\n12 0\n"))
        #expect(ClaudeLineage(file: file).contains(12))
    }

    @Test func c4AppStartPurgesLineageFilesOfOtherBootsOnly() throws {
        let folder = box.sessionsRoot.appending(path: "lineage", directoryHint: .isDirectory)
        let keep = ClaudeLineage(file: folder.appending(path: "\(UUID().uuidString).lineage"), fresh: true)
        keep.seed(getpid())
        keep.insert(5)
        keep.save(force: true)
        let other = folder.appending(path: "\(UUID().uuidString).lineage")
        try "taskforce-lineage 3\nboot \(UUID().uuidString)\nroot 7 70\nresponsible yes\n7 70\n".write(to: other, atomically: true, encoding: .utf8)
        let broken = folder.appending(path: "\(UUID().uuidString).lineage")
        try "nonsense\n".write(to: broken, atomically: true, encoding: .utf8)
        let unrelated = folder.appending(path: "notes.txt")
        try "x".write(to: unrelated, atomically: true, encoding: .utf8)
        ClaudeCodeProcess(sessionsRoot: box.sessionsRoot, hookServer: nil, helpers: ClaudeCodeHelpers(hook: "/x", mcp: "/y"),
                          locator: ClaudeCodeLocator(candidates: [], confinedTo: box.root.path)).purgeLineageOfOtherBoots()
        #expect(FileManager.default.fileExists(atPath: keep.file?.path ?? ""))
        #expect(ClaudeLineage.load(other) == .ended, "다른 부팅의 파일은 끝 기록으로 (결정 11-1)")
        #expect(FileManager.default.fileExists(atPath: broken.path), "다른 부팅으로 확인되지 않은 파일은 남긴다 (11장 1)")
        #expect(FileManager.default.fileExists(atPath: unrelated.path))
    }

    @Test func c4ARestartedAdapterReplacesTheIDsWithAnEndRecordOnceItProvesTheEnd() async throws {
        let marker = UUID().uuidString
        let root = try spawn("exit 0", marker: marker)
        let file = box.sessionsRoot.appending(path: "lineage/\(marker).lineage")
        let lineage = ClaudeLineage(file: file, fresh: true)
        lineage.seed(root.process.pid)
        lineage.save(force: true)
        _ = try await offPool { root.process.waitForExit() }
        let adapter = ClaudeCodeProcess(sessionsRoot: box.sessionsRoot, hookServer: nil, helpers: ClaudeCodeHelpers(hook: "/x", mcp: "/y"),
                                        locator: ClaudeCodeLocator(candidates: [], confinedTo: box.root.path), timing: .testing)
        #expect(await adapter.liveness(root.identity) == .ended(AgentExit(code: nil)))
        #expect(ClaudeLineage.load(file) == .ended, "id는 지우고 끝 기록만 (11장 1)")
    }

    // MARK: 5 앱 데이터 폴더

    @Test func c5EditsAndWritesInsideTheAppDataFoldersAreDenied() async throws {
        let data = box.workspace.appending(path: "Library/Application Support/app", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        box.file("Library/Application Support/app/ledger.sqlite")
        let cwd = box.sessionsRoot.appending(path: "\(ClaudeTest.session)/cwd", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)
        let decider = ScriptedDecider([.success(ScriptedDecider.response(.allow, .policyAuto)), .success(ScriptedDecider.response(.allow, .policyAuto))])
        let context = ClaudeGateContext(
            mode: .normal, access: .write, workspaceRealPath: box.workspacePath, sessionCwdRealPath: cwd.path, childPATH: "/usr/bin:/bin", agentSessionID: ClaudeTest.session,
            agentTaskID: ClaudeTest.task, turnSeq: 1, deferIssued: false, answerDelivered: false, protectedRealPaths: [ClaudeSandbox.real(data.path)]
        )
        let gate = ClaudeToolGate(fileSystem: .live, decide: decider.function, serverTimeout: .seconds(30))
        for (tool, input) in [
            ("Write", WireJSON.object(["file_path": .string(data.path + "/ledger.sqlite"), "content": .string("x")])),
            ("Edit", WireJSON.object(["file_path": .string(data.path + "/new/state.json"), "old_string": .string("a"), "new_string": .string("b")])),
            ("Write", WireJSON.object(["file_path": .string(data.path), "content": .string("x")])),
        ] {
            let outcome = await gate.evaluate(ClaudeTest.request(tool, input, cwd: cwd.path), context: context)
            #expect(outcome.response == HookResponse(decision: .deny, reason: ClaudeGateReason.appData), "\(tool)")
        }
        #expect(decider.calls.isEmpty)
        // 앱 데이터 밖은 그대로 서버로
        let outside = await gate.evaluate(ClaudeTest.request("Write", .object(["file_path": .string(box.workspacePath + "/ok.txt"), "content": .string("x")]), cwd: cwd.path), context: context)
        #expect(outside.response.decision == .allow)
    }

    @Test func c5TheAdapterProtectsItsSessionsRootAndTheGivenFolders() async throws {
        let fake = try FakeClaude(decider: ScriptedDecider([.success(ScriptedDecider.response(.allow, .policyAuto))]))
        let data = fake.box.workspace.appending(path: "appdata", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        let adapter = ClaudeCodeProcess(
            sessionsRoot: fake.box.sessionsRoot, hookServer: fake.server, helpers: fake.helpers, locator: ClaudeCodeLocator(candidates: [fake.claude.path], confinedTo: fake.box.root.path),
            environment: fake.environment, managedSettingsPath: fake.box.root.appending(path: "managed-settings.json").path, timing: fake.timing, log: fake.log, protectedRoots: [data]
        )
        adapter.attach(AgentRuntimeServices(decideTool: fake.decider.function))
        try fake.scenario(["runs": [["steps": [["tool": "Write", "id": "toolu_w", "input": ["file_path": data.path + "/x.json", "content": "x"]]], "final_text": "ok"]]])
        let events = EventLog()
        _ = try await adapter.startTurn(AgentTurnStart(
            taskID: ClaudeTest.task, sessionID: ClaudeTest.session, turnSeq: 1, adapter: "agent:claude-code", externalSessionID: nil, workspaceRef: fake.workspace, resume: false,
            access: .write, policyMode: .manual, marker: UUID().uuidString.lowercased(), text: "Write it."
        ), events: events.sink)
        #expect(await events.wait { FakeClaude.ended($0) })
        #expect((fake.report(0)?["decisions"] as? [[String: Any]])?.first?["decision"] as? String == "deny")
        #expect(!FileManager.default.fileExists(atPath: data.path + "/x.json"))
        #expect(fake.decider.calls.isEmpty)
    }

    // MARK: 7 이 Mac에서 답한 비밀값

    @Test func c7ALocallyAnsweredSecretIsRedactedEvenWhenTheSecretItemsAreUnknown() async throws {
        let fake = try FakeClaude()
        let secret = "CANARY-SECRET-7f3a"
        try fake.scenario(["runs": [
            ["steps": [["tool": "mcp__tf__ask_user", "id": "toolu_secret", "input": ["questions": [["id": "key", "header": "Key", "text": "Paste the API key", "secret": true]]]]]],
            ["steps": [["text": "Your key \(secret) works."]]],
        ]])
        let first = EventLog()
        let identity = try await fake.turn(events: first)
        #expect(await first.wait { FakeClaude.ended($0) })
        // 비밀 항목 id가 없는 상태 파일 (예전 상태 · 손상): 이 Mac에서 답한 값이면 답 값 전부를 비밀로 본다
        let folder = fake.box.sessionsRoot.appending(path: ClaudeTest.session)
        var state = ClaudeSessionState.load(from: folder)
        state.openDeferred?.secretItemIDs = []
        try state.save(in: folder)
        let restarted = fake.restarted()
        let events = EventLog()
        let result = try await restarted.deliverAnswer(AgentAnswerDelivery(
            taskID: ClaudeTest.task, sessionID: ClaudeTest.session, turnSeq: 1, adapter: "agent:claude-code", externalSessionID: FakeClaude.providerSession(identity),
            workspaceRef: fake.workspace, marker: UUID().uuidString.lowercased(), access: .write, policyMode: .manual, requestID: "toolu_secret", kind: .input, structured: true,
            value: AgentAnswerValue(text: secret), answeredLocally: true
        ), events: events.sink)
        guard case .delivered = result else {
            Issue.record("\(result)")
            return
        }
        #expect(await events.wait { FakeClaude.ended($0) })
        #expect(ClaudeRereviewProcessTests.texts(events.all).contains("Your key [redacted] works."))
    }

    @Test func c7TheStateFileKeepsSecretItemIDsButNeverValues() throws {
        let folder = box.root.appending(path: "state", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var state = ClaudeSessionState()
        state.openDeferred = ClaudeSessionState.OpenDeferred(id: "toolu_q", kind: "input", inputSHA256: "abc", spawnID: "s", at: Date(), secretItemIDs: ["key"], singleItem: true)
        try state.save(in: folder)
        let loaded = ClaudeSessionState.load(from: folder)
        #expect(loaded.openDeferred?.secretItemIDs == ["key"])
        #expect(loaded.openDeferred?.singleItem == true)
    }

    // MARK: 8 디코드한 뒤 탐지

    @Test func c8DetectionDecodesPercentJSONAndShellQuotingAndNormalization() {
        let redactor = SecretRedactor(["pässwörd-é12345"])
        let nfd = "pässwörd-é12345".decomposedStringWithCanonicalMapping
        #expect(redactor.detects("x " + nfd))
        #expect(redactor.detects("p%C3%A4ssw%C3%B6rd-%C3%A912345"))
        #expect(redactor.detects("pa%CC%88ssw%C3%B6rd-%C3%A912345"), "퍼센트 + NFD")
        let slashU = String(UnicodeScalar(UInt8(0x5C))) + "u" // 백슬래시 + u
        #expect(redactor.detects("{\"k\":\"p" + slashU + "00e4ssw" + slashU + "00F6rd-" + slashU + "00e912345\"}"), "JSON 이스케이프 + 대소문자 섞임")
        #expect(redactor.detects("{\"k\":\"p" + slashU + "00e4sswörd-é12345\"}"), "일부만 이스케이프")
        #expect(redactor.detects("'pässw'\"ö\"'rd-é12345'"), "셸 따옴표를 이어 붙인 형태")
        #expect(!redactor.detects("pässwörd-é1234 5"), "다른 값")
        #expect(!SecretRedactor().detects("anything"))
        // 값 끝 글자에 글의 결합 표시가 붙으면 NFC로는 합쳐져 못 찾는다: NFD로도 본다
        #expect(SecretRedactor(["passwore"]).detects("passwore\u{0301}"))
        // `+`가 값의 글자이고 나머지만 퍼센트 인코딩: `+`를 빈칸으로 읽지 않는 방식으로도 푼다
        #expect(SecretRedactor(["abc+def/ghi=jk"]).detects("v=abc+def%2Fghi%3Djk"))
    }

    // MARK: 9 스칼라 기준 · 결합 표시 · 숨긴 수

    @Test func c9TwoCombiningMarksStayButMoreBecomeCodesAndTheCutShowsHowMuchIsHidden() {
        let card = { (command: String) in ClaudeToolGate.approvalQuestion(id: "t", tool: "Bash", relPath: nil, command: command).text }
        #expect(card("caf" + "e\u{0301}\u{0302} x") == "Run: caf" + "e\u{0301}\u{0302} x", "결합 표시 둘은 그대로")
        #expect(card("e\u{0301}\u{0302}\u{0301} x") == "Run: e" + #"\u{0301}\u{0302}\u{0301}"# + " x", "셋 이상은 코드로")
        #expect(card("e" + String(repeating: "\u{0301}", count: 3) + "x") == "Run: e" + #"\u{0301}"# + "×3x")
        let long = String(repeating: "a", count: 400)
        #expect(card(long) == "Run: " + String(repeating: "a", count: 212) + "…(+108)…" + String(repeating: "a", count: 80))
        // 결합 표시 둘이 붙은 글자 200개 = 600 스칼라 (글자 수로는 200): 스칼라로 세어 자른다
        let stacked = card(String(repeating: "e\u{0301}\u{0302}", count: 200))
        #expect(stacked.unicodeScalars.count <= "Run: ".unicodeScalars.count + 300)
        #expect(stacked.contains("…(+"))
        let wide = String(repeating: "가", count: 1000)
        let text = card(wide)
        #expect(text.unicodeScalars.count <= "Run: ".unicodeScalars.count + 300)
        // 원래 1,000 스칼라 → 자리 4자리(9) → 앞 211 · 끝 80 · 숨김 709
        #expect(text.contains("…(+709)…"))
    }
}

/// 런타임 쪽 (10장 7): 이 Mac에서 답한 비밀값이면 adapter에 그렇다고 알린다 (다시 뜬 앱의 adapter가 그 값을 가리개에 쌓는다)
@Suite(.serialized)
struct ClaudeRereview2RuntimeTests {
    @Test func c7TheRuntimeTellsTheAdapterTheAnswerWasGivenLocally() async throws {
        let h = try BridgeHarness()
        let question = AgentQuestion(
            providerRequestID: "req-secret", kind: .input, structured: false, text: "Token?",
            items: [AgentQuestionItem(id: "q", header: "Token", text: "token", options: [], secret: true)]
        )
        h.agent.setScript(.asking(question))
        let locally = Mutex<Bool?>(nil)
        h.agent.onDeliver { delivery in locally.withLock { $0 = delivery.answeredLocally } }
        await h.registerFirst()
        let created = h.message()
        await h.runtime.tick()
        await h.settle { (try? await h.ledger.task(created.taskID))?.openRequestID == "req-secret" }
        await h.secrets.put(requestID: "req-secret", value: AgentAnswerValue(text: "SENTINEL-SECRET-LOCAL-41aa"))
        h.server.enqueueAnswer(bridgeID: h.bridgeID, taskID: created.taskID, requestID: "req-secret", locally: true, structured: false)
        h.clock.jump(by: 6)
        await h.runtime.tick()
        #expect(await h.eventually { h.agent.deliveredAnswers.count == 1 })
        #expect(locally.withLock { $0 } == true)
    }
}
#endif
