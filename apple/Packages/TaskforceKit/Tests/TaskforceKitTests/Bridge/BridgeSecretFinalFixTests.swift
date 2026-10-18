#if os(macOS) && DEBUG
import Foundation
import Testing
@testable import TaskforceKit

/// OA D4b-m-2 계약 16.15 (마지막 고침): 먼저 빨갛게 만들고(이름은 노트 "## 16.15") 고친 뒤 초록이 된다.
/// ① 진행 표시는 명령 · 제출 단위다: 옛 명령의 늦은 정산이 새 답의 `isBusy`를 끄지 않는다 (Astra P2-1).
/// ② 닫힘 정산(withdrawn · stale/not_prepared · 404 · declined)은 끝나지 않은 다른 제출이 없으면 값을 버린다 (Astra P2-2).
/// ③ `put`이 건너뛰어지면 그 열쇠의 옛 값도 지운다: 옛 값이 새 제출의 POST로 나가지 않는다 (보안 F-5).
struct BridgeSecretFinalFixTests {
    typealias S = SecretFixture

    // MARK: ① 진행 표시는 제출 단위 (Astra P2-1)

    /// C1(lease 응답 유실, 아직 정산 전) 위에 서버가 질문을 되살려 둘째 제출이 C2를 만든 채, C1이 늦게 `not_received`로 정산되는 순서. C2는 아직 목록에 나오지 않는다
    @Test func aLateSettleOfAnOldCommandNeverTurnsOffBusyWhileANewerAnswerIsStillInFlight() async throws {
        let h = try BridgeHarness()
        let created = try await S.open(h, endsAfterAsking: true)
        let oldCommand = try await S.submitAndLoseTheLease(h, created: created)
        h.server.restoreQuestion(taskID: created.taskID) // 서버가 질문을 되살렸다 (C1의 정산은 아직 이 Mac에 닿지 않았다)
        let latest = S.canary()
        #expect(await S.submit(h, S.answer(created, value: latest)) == .sent, "서버는 answered (새 명령 C2)")
        let ids = h.server.commandIDs(taskID: created.taskID, kind: "answer")
        #expect(ids.count == 2 && ids.first == oldCommand)
        let newCommand = try #require(ids.last)
        h.server.setCommandStep(newCommand, "skipped") // C2는 아직 목록에 나오지 않는다: 옛 명령의 늦은 정산이 먼저 닿는다
        let busyBefore = await h.runtime.isBusy()
        #expect(busyBefore, "둘 다 끝나지 않았다 (N=2 > M=0)")
        try await S.settleAsNotReceived(h, commandID: oldCommand)
        let rests = await h.secrets.contains(key: S.key(created))
        #expect(rests, "정산은 값을 버리지 않는다")
        let busy = await h.runtime.isBusy()
        #expect(busy, "C1의 정산은 M만 하나 올린다: C2가 아직 진행 중이라 바쁨은 남는다 (업데이트 재시작이 값을 지우면 안 된다)")
        // C2가 나와 한 번 전달된다
        h.server.setCommandStep(newCommand, "prepared")
        await S.deliver(h)
        #expect(await h.eventually { h.agent.deliveredAnswers.count == 1 })
        #expect(h.agent.deliveredAnswers.first?.value.answers == [S.itemID: .one(latest)])
        await h.settle { h.server.taskState(created.taskID) == "idle" } // 보낼 사건을 비운다 (그 몫의 바쁨은 이 시험이 보는 것이 아니다)
        let pending = await h.secrets.hasPending
        let busyAfter = await h.runtime.isBusy()
        #expect(!pending && !busyAfter, "끝에는 값 0 · 바쁨 거짓")
    }

    // MARK: ② 닫힘 정산이면 버린다 (Astra P2-2)

    /// 서버 Stop/Done(`20261128000000_agent_delivery_fixes.sql:112`)은 Claude task를 취소하고 cancel 명령 없이 돌아온다. 목록 조회 뒤 lease 전에 일어나면 늦은 lease가 `stale/not_prepared`를 받는다
    @Test func aStopOrDoneBetweenTheListAndTheLeaseClosesTheQuestionAndTheLateStaleLeaseDropsTheValue() async throws {
        let h = try BridgeHarness()
        let created = try await S.open(h, endsAfterAsking: true)
        #expect(await S.submit(h, S.answer(created, value: S.canary())) == .sent)
        let commandID = try #require(h.server.commandIDs(taskID: created.taskID, kind: "answer").first)
        let server = h.server
        let taskID = created.taskID
        server.onRequest = { record in
            // Stop/Done가 lease 직전에 끼어든다: 답 단계는 건너뛰어지고 task는 취소된다 (cancel 명령은 없다)
            if record.route == "ack", record.json["op"] as? String == "lease" {
                server.setCommandStep(commandID, "skipped")
                server.setTaskState(taskID, "cancelled")
            }
        }
        h.clock.jump(by: 6)
        await h.runtime.tick()
        server.onRequest = nil
        #expect(server.commandLeaseCount(commandID) >= 1, "목록에 나온 명령이 lease를 시도했다")
        #expect(server.requests("ack").contains { $0.json["op"] as? String == "cancel" } == false)
        #expect(server.commandIDs(taskID: taskID, kind: "cancel").isEmpty, "cancel 명령은 없었다")
        let pending = await h.secrets.hasPending
        #expect(!pending, "닫힘 정산이면 값 0 (TTL 24시간까지 남지 않는다)")
        let busy = await h.runtime.isBusy()
        #expect(!busy)
        #expect(h.agent.deliveredAnswers.isEmpty)
        // 보관 정리 · 다음 tick 뒤에도 그대로다
        await h.runtime.housekeeping()
        let still = await h.secrets.hasPending
        #expect(!still)
    }

    @Test func aClosureSettleKeepsTheValueWhileAnotherSubmissionIsStillUnfinished() async throws {
        let h = try BridgeHarness()
        let created = try await S.open(h, endsAfterAsking: true)
        let oldCommand = try await S.submitAndLoseTheLease(h, created: created)
        h.server.restoreQuestion(taskID: created.taskID)
        let latest = S.canary()
        #expect(await S.submit(h, S.answer(created, value: latest)) == .sent, "C2 (answered)")
        #expect(h.server.commandIDs(taskID: created.taskID, kind: "answer").count == 2)
        // 옛 명령 C1이 이제야 stale/not_prepared를 받는다 (닫힘 종류). 그러나 C2가 끝나지 않았다 → 값은 남는다
        h.server.staleOnNextLease(oldCommand, reason: "not_prepared")
        await S.deliver(h)
        #expect(await h.eventually { h.agent.deliveredAnswers.count == 1 })
        #expect(h.agent.deliveredAnswers.first?.value.answers == [S.itemID: .one(latest)], "C1의 닫힘 정산이 C2 몫의 값을 지우지 않았다")
        let pending = await h.secrets.hasPending
        #expect(!pending)
    }

    @Test func aClosureSettleWhileASubmissionIsStillRunningKeepsItsValue() async throws {
        let h = try BridgeHarness()
        let created = try await S.open(h, endsAfterAsking: true)
        h.server.dropResponseOnce(route: "answer-local") // 서버는 C1을 만들었지만 응답이 유실된다: 제출은 재시도 전 잠깐에 있다
        let done = Locked<LocalSecretOutcome?>(nil)
        let task = Task { done.set(await h.runtime.submitLocalSecret(S.answer(created, value: S.canary()), accountStillMatches: { true })) }
        #expect(await h.eventually { h.clock.sleeperCount > 0 }, "재시도 전의 잠깐")
        let commandID = try #require(h.server.commandIDs(taskID: created.taskID, kind: "answer").first)
        h.server.staleOnNextLease(commandID, reason: "not_prepared") // 그 사이 C1이 목록에 나와 닫힘 정산을 받는다
        h.clock.jump(by: 6)
        await h.runtime.tick()
        #expect(await h.eventually(timeout: 5) { (try? await h.ledger.command(commandID))?.state == .stale }, "닫힘 정산이 끝났다")
        let during = await h.secrets.contains(key: S.key(created))
        #expect(during, "제출이 아직 돌고 있다: 그 제출의 값을 닫힘 정산이 지우지 않는다")
        let busyDuring = await h.runtime.isBusy()
        #expect(busyDuring, "돌고 있는 제출은 바쁨이다 (N이 아직 0이어도)")
        let deadline = Date().addingTimeInterval(30)
        while done.get() == nil, Date() < deadline {
            if h.clock.sleeperCount > 0 { await h.clock.advance(by: 1) } else { try? await Task.sleep(for: .milliseconds(2)) }
        }
        await task.value
        #expect(done.get() != nil)
    }

    @Test func stoppingTheRuntimeAlsoClearsTheRunningSubmissions() async throws {
        let h = try BridgeHarness()
        let created = try await S.open(h)
        h.server.dropResponseOnce(route: "answer-local") // 제출은 재시도 전 잠깐에 있다
        let done = Locked<LocalSecretOutcome?>(nil)
        let task = Task { done.set(await h.runtime.submitLocalSecret(S.answer(created, value: S.canary()), accountStillMatches: { true })) }
        #expect(await h.eventually { h.clock.sleeperCount > 0 })
        let busyBefore = await h.secrets.hasInFlight
        #expect(busyBefore, "돌고 있는 제출")
        await h.runtime.stop() // 계정이 떠난다: 값도, 돌고 있는 제출의 계수도 비운다
        let pending = await h.secrets.hasPending
        let busy = await h.secrets.hasInFlight
        #expect(!pending && !busy, "stop 뒤에는 값 0 · 바쁨 거짓 (제출 흐름이 아직 끝나지 않았어도)")
        let deadline = Date().addingTimeInterval(30)
        while done.get() == nil, Date() < deadline {
            if h.clock.sleeperCount > 0 { await h.clock.advance(by: 1) } else { try? await Task.sleep(for: .milliseconds(2)) }
        }
        await task.value
    }

    // MARK: ③ put이 건너뛰어지면 옛 값을 지운다 (보안 F-5)

    @Test func aSkippedPutNeverLetsTheOldRestingValueGoOutForTheNewSubmission() async throws {
        let h = try BridgeHarness()
        let created = try await S.open(h, endsAfterAsking: true)
        let oldCommand = try await S.submitAndLoseTheLease(h, created: created)
        try await S.settleAsNotReceived(h, commandID: oldCommand) // 서버가 질문을 되살렸고 옛 값 V1이 쉬고 있다
        let rests = await h.secrets.contains(key: S.key(created))
        #expect(rests, "양성 대조: V1이 쉬고 있다")
        let before = h.server.requests("answer-local").count
        // 사용자가 V2를 다시 입력한다: heartbeat 앞 확인은 통과하고 put 앞 확인만 실패한다 (원장 읽기 실패 따위도 같은 모양이다)
        let checks = AccountChecks([true, false, true])
        let outcome = await S.submit(h, S.answer(created, value: S.canary()), matches: checks.closure)
        #expect(outcome == .failed(.generic), "보냈다고 하지 않는다: \(outcome)")
        #expect(h.server.requests("answer-local").count == before, "POST 0: 옛 값으로 새 제출이 나가지 않는다")
        #expect(h.server.commandIDs(taskID: created.taskID, kind: "answer").count == 1, "새 답 명령 0")
        let pending = await h.secrets.hasPending
        #expect(!pending, "put이 건너뛰어지면 그 열쇠의 옛 값도 지웠다")
        await S.deliver(h)
        #expect(h.agent.deliveredAnswers.isEmpty, "옛 값이 전달되지 않는다")
    }
}
#endif
