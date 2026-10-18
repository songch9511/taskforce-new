#if os(macOS) && DEBUG
import Foundation
import Synchronization
import Testing
@testable import TaskforceKit

/// 끝난 턴의 마지막 출력이 정산되는 동안에는 `forgetSession`이 비밀값 가리개를 지우지 않는다 (Astra P2-3, 코디네이터 13.11). 가짜 `claude`만 쓴다 (실제 `claude` 실행 0)
struct ClaudeRedactionSettleTests {
    /// spawn이 등록부에서 내려온 직후(마지막 출력을 내기 전)에 세션을 잊게 하고, 그 순간 가리개가 남아 있는지 본다
    private func finishedTurn(forgetAtTheGap: Bool) async throws -> (fake: FakeClaude, keptDuringTheGap: Bool?, events: EventLog) {
        let holder = Mutex<ClaudeCodeProcess?>(nil)
        let kept = Mutex<Bool?>(nil)
        let hooks = ClaudeCodeTestHooks(afterUnregister: {
            guard let process = holder.withLock({ $0 }) else { return }
            if forgetAtTheGap { await process.forgetSession(ClaudeTest.session) }
            let stillThere = await !process.redactor(ClaudeTest.session).isEmpty
            kept.withLock { $0 = stillThere }
        })
        let fake = try FakeClaude(hooks: hooks)
        try fake.scenario(["runs": [["steps": [["text": "hello"]]]]])
        holder.withLock { $0 = fake.process }
        await fake.process.seedRedactorForTest(SecretRedactor(["a-secret-value-123"]), for: ClaudeTest.session)
        let events = EventLog()
        _ = try await fake.turn(events: events)
        #expect(await events.wait { FakeClaude.ended($0) })
        return (fake, kept.withLock { $0 }, events)
    }

    @Test func aForgetThatArrivesWhileTheFinishedTurnsOutputIsSettlingKeepsTheRedactorThenClearsItWhenDone() async throws {
        let (fake, keptDuringTheGap, _) = try await finishedTurn(forgetAtTheGap: true)
        #expect(keptDuringTheGap == true, "정산 중에는 가리개를 남긴다: 마지막 출력이 비밀값을 되말하면 가려야 한다")
        var cleared = false
        for _ in 0..<500 where !cleared {
            cleared = await fake.process.redactor(ClaudeTest.session).isEmpty
            if !cleared { try? await Task.sleep(for: .milliseconds(20)) }
        }
        #expect(cleared, "정산이 끝나면 미룬 잊기가 이어서 지운다 (두 번째 호출 없이)")
    }

    @Test func withoutAForgetRequestTheRedactorIsNotClearedByTheTurnEnding() async throws {
        let (fake, keptDuringTheGap, _) = try await finishedTurn(forgetAtTheGap: false)
        #expect(keptDuringTheGap == true)
        for _ in 0..<100 { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(await !fake.process.redactor(ClaudeTest.session).isEmpty, "잊으라는 요청이 없으면 그대로다")
    }
}
#endif
