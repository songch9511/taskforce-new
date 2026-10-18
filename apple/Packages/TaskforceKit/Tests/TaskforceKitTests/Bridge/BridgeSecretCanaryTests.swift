#if os(macOS) && DEBUG
import Foundation
import Testing
@testable import TaskforceKit

/// OA D4b-m-2 카나리 (계약 16.8, 보안 L1): 고정 카나리 `TF_CANARY_D4BM2_<uuid>`를 비밀값 칸에 넣고 **실제 길** 끝까지 흘린다:
/// 질문 저장소(2초 보류) → `submitLocalSecret`(heartbeat → put → POST) → 가짜 서버가 답 명령을 만듦 → lease → `take` → 실제 Claude Code adapter(가짜 `claude`)의 답 훅.
/// 여섯 곳을 본다: ① 요청 ② 로그 ③ 디스크 ④ 덤프 ⑤ 접근성(Mac 호스트 시험 `BridgeSecretSubmitterTests`) ⑥ 양성 대조(모델에는 정확히 한 번 닿았다)
@Suite(.serialized)
struct BridgeSecretCanaryTests {
    typealias F = AgentQuestionFixtures

    /// 질문 저장소가 보는 `LocalSecretAnswerSubmitting`을 런타임의 실제 길로 잇는다 (앱의 `BridgeLocalSecretSubmitter`와 같은 일, 계정 확인만 항상 참)
    struct RuntimeSubmitter: LocalSecretAnswerSubmitting {
        let runtime: BridgeRuntime
        func submit(_ answer: LocalSecretAnswer) async -> LocalSecretOutcome {
            await runtime.submitLocalSecret(answer, accountStillMatches: { true })
        }
    }


    /// 질문 저장소 쪽 (MainActor): 서버가 쥔 열린 질문을 읽고, 카드에 값을 넣고, 2초 보류 뒤 실제 길로 보낸다
    @MainActor
    final class StoreDriver {
        let gateway = FakeAgentQuestionGateway()
        let ticker = ManualTicker()
        let log = LogLines()
        let store: AgentQuestionStore
        let session: UUID

        init(runtime: BridgeRuntime, task: UUID, session: UUID) {
            self.session = session
            gateway.records = [QFx.record(
                F.pending(prompts: [F.prompt(id: "key", text: "Paste the API key", header: "Key", options: [], other: true, secret: true)], request: "toolu_secret", task: task),
                task: task, session: session
            )]
            let ticker = ticker
            let log = log
            store = AgentQuestionStore(
                gateway: gateway, scope: ChatTestAccount.fixedScope(), secrets: RuntimeSubmitter(runtime: runtime), sleep: { await ticker.sleep($0) }, log: { log.add($0) }
            )
            store.thisMacBridgeID = F.bridgeID
        }

        func open() async {
            store.sessionsRead([QFx.item(session: session, bridge: F.bridgeID)])
            await store.settle()
        }

        func submit(_ canary: String) -> AgentQuestionStore.Phase? {
            store.submitSecret(SecretBox(canary), session: session)
            return store.entry(session: session)?.phase
        }

        func fireAndWaitSent() async -> Bool {
            _ = await eventually { !ticker.pendingDelays.isEmpty }
            ticker.fire()
            return await eventually { store.entry(session: session)?.phase == .sent }
        }

        var reflectedState: String { BridgeSecretCanaryTests.reflected(store.entries) }
    }

    func harness(_ fake: FakeClaude) async throws -> BridgeHarness {
        let harness = try BridgeHarness(withAdapter: false, workspace: fake.workspace)
        try await harness.restart(adapters: [fake.process], reopenLedger: false)
        fake.process.attach(AgentRuntimeServices(decideTool: fake.decider.function))
        await harness.registerFirst()
        return harness
    }

    /// 폴더 아래 모든 파일 바이트에 글이 있나 (`skipping`: 건너뛸 이름의 폴더)
    nonisolated static func treeContains(_ needle: String, _ root: URL, skipping: Set<String> = []) -> Bool {
        let target = Data(needle.utf8)
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return false }
        for case let url as URL in walker {
            if skipping.contains(url.lastPathComponent) {
                walker.skipDescendants()
                continue
            }
            if let data = try? Data(contentsOf: url), data.range(of: target) != nil { return true }
        }
        return false
    }

    /// 모든 반사 길로 글을 뽑는다: `String(describing:)` · `String(reflecting:)` · `dump` · `Mirror` 재귀
    nonisolated static func reflected(_ value: Any) -> String {
        var text = ""
        dump(value, to: &text)
        text += String(describing: value) + String(reflecting: value)
        func walk(_ any: Any, _ depth: Int) {
            guard depth < 8 else { return }
            for child in Mirror(reflecting: any).children {
                text += "\(child.label ?? "")=\(child.value)"
                walk(child.value, depth + 1)
            }
        }
        walk(value, 0)
        return text
    }

    @Test func theCanaryReachesTheModelExactlyOnceAndNowhereElseOnThisMac() async throws {
        let canary = SecretFixture.canary()
        let fake = try FakeClaude()
        let ask: [String: Any] = ["questions": [["id": "key", "header": "Key", "text": "Paste the API key", "secret": true]]]
        // 답 뒤에 모델이 값을 되말한다: 밖으로 나가는 글에서는 가려야 한다
        try fake.scenario(["runs": [
            ["steps": [["tool": "mcp__tf__ask_user", "id": "toolu_secret", "input": ask]]],
            ["final_text": "Your key \(canary) works."],
        ]])
        let h = try await harness(fake)
        let created = h.message("SENTINEL-USER-MESSAGE-d4bm2")
        await h.runtime.tick()
        await h.settle(timeout: 60) { (try? await h.ledger.task(created.taskID))?.openRequestID == "toolu_secret" && h.server.taskState(created.taskID) == "awaiting_answer" }
        #expect(try await h.ledger.task(created.taskID)?.openRequestSecret == true)

        // 질문 저장소: 서버가 쥔 열린 질문을 읽고, 카드에 값을 넣는다 (2초 보류)
        let task = try #require(UUID(uuidString: created.taskID))
        let session = try #require(UUID(uuidString: BridgeHarness.sessionID))
        let driver = await StoreDriver(runtime: h.runtime, task: task, session: session)
        await driver.open()
        #expect(await driver.submit(canary) == .holding)
        var dumps = await driver.reflectedState
        #expect(await driver.fireAndWaitSent(), "실제 길을 거쳐 보냈다")
        #expect(driver.gateway.answers.isEmpty, "서버 답 route는 0")

        // 값은 지금 이 Mac의 메모리(LocalSecretAnswers)에만 있다: 이 순간의 덤프에도 값이 없다
        #expect(await h.secrets.contains(key: SecretFixture.key(created, request: "toolu_secret")), "양성 대조: 값은 정말 메모리에 있다")
        dumps += Self.reflected(h.secrets) + (await driver.reflectedState)
        dumps += Self.reflected(LocalSecretAnswer(key: F.key(), answers: ["key": .secret(SecretBox(canary))]))
        dumps += Self.reflected(SecretBox(canary))
        dumps += Self.reflected(LocalAnswerBox(AgentAnswerValue(answers: ["key": .one(canary)], text: canary)))
        dumps += Self.reflected(BridgeRuntimeSnapshot(status: await h.runtime.status, isBusy: await h.runtime.isBusy(), hasLiveProcess: await h.runtime.hasLiveProcess()))
        dumps += Self.reflected(try await h.ledger.allTasks())
        dumps += Self.reflected(try await h.ledger.task(created.taskID) as Any)

        // lease → take → 답 훅
        await SecretFixture.deliver(h)
        let deadline = Date().addingTimeInterval(60)
        while h.server.taskState(created.taskID) != "idle", Date() < deadline {
            h.clock.jump(by: 6)
            await h.runtime.tick()
            await h.settle(timeout: 1) { h.server.taskState(created.taskID) == "idle" }
        }
        #expect(h.server.taskState(created.taskID) == "idle", "답 뒤 턴이 끝났다")
        await h.ledger.checkpoint()

        // ⑥ 양성 대조: 모델에는 정확히 한 번 닿았다 (가짜 `claude`의 MCP 결과)
        let mcpResults = (1...2).flatMap { (fake.report($0)?["mcp_results"] as? [String]) ?? [] }
        #expect(mcpResults.filter { $0.contains(canary) }.count == 1, "카나리가 답 훅을 거쳐 모델에 닿은 횟수 = 1: \(mcpResults.count)개 결과")
        #expect(await h.secrets.hasPending == false, "전달 뒤 상자는 비었다")

        // ① 요청: 서버가 받은 모든 요청의 URL · 헤더 · 본문
        let requests = h.server.requests
        let everything = requests.map { [$0.route, $0.method, $0.query.description, $0.token ?? "", $0.secret ?? "", $0.bodyJSON].joined(separator: "|") }.joined(separator: "\n")
        #expect(!everything.contains(canary), "서버 요청에 카나리 0 (\(requests.count)개)")
        #expect(requests.map(\.route).contains("answer-local") && requests.map(\.route).contains("events"), "양성 대조: answer-local과 events 요청이 실제로 있었다")
        let answerLocal = try #require(requests.first { $0.route == "answer-local" })
        #expect(Set(answerLocal.json.keys) == ["bridge_id", "agent_task_id", "request_digest"], "answer-local 본문은 키 셋뿐")
        #expect(everything.contains("Your key [redacted] works."), "양성 대조: 되말한 값은 가려서 나갔다")

        // ② 로그
        let logs = (h.log.lines + fake.log.lines + driver.log.all).joined(separator: "\n")
        #expect(!logs.contains(canary), "로그에 카나리 0")
        #expect(h.log.events.contains("secret_answer_post"), "양성 대조: 로그 자체는 남는다")

        // ③ 디스크: 원장(DB · WAL · SHM) · 세션 폴더(state.json · lineage) · 훅 소켓 폴더 · 작업 폴더 · 임시 HOME(가짜 claude의 기록 폴더만 빼고)
        #expect(!Self.treeContains(canary, h.ledger.directory), "원장에 카나리 0")
        #expect(!Self.treeContains(canary, h.temp.url), "임시 원장 폴더 전체에 카나리 0")
        #expect(!Self.treeContains(canary, fake.box.sessionsRoot), "세션 폴더에 카나리 0")
        #expect(!Self.treeContains(canary, fake.socketFolder), "훅 소켓 폴더에 카나리 0")
        #expect(!Self.treeContains(canary, fake.box.workspace), "작업 폴더에 카나리 0")
        #expect(!Self.treeContains(canary, fake.box.home, skipping: [".fake-claude"]), "임시 HOME에 카나리 0 (가짜 `claude`가 모델이 받은 것을 적는 폴더만 빼고)")
        #expect(Self.treeContains(canary, fake.box.home), "양성 대조: 훑기는 값을 찾을 수 있다 (가짜 `claude`의 모델 쪽 기록에는 있다, Q9 남는 위험)")

        // ④ 덤프
        dumps += await driver.reflectedState
        #expect(!dumps.contains(canary), "덤프 · describing · reflecting · Mirror 어디에도 카나리 0")
        #expect(dumps.count > 500, "양성 대조: 덤프는 비어 있지 않다")
    }
}
#endif
