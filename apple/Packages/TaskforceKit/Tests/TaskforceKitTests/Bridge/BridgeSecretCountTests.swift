#if os(macOS) && DEBUG
import Foundation
import Testing
@testable import TaskforceKit

/// OA D4b-m-2 계약 16.15 단위: 값마다 "답한 POST 수 N" · "끝을 본 답 명령 수 M" · 돌고 있는 제출로 `isBusy`와 닫힘 정산의 버림을 정한다.
struct BridgeSecretCountTests {
    @Test func theCountsOfAnsweredPostsAndEndedCommandsDecideBusyAndTheClosureDrop() async {
        let secrets = LocalSecretAnswers()
        let task = UUID().uuidString
        let key = LocalSecretKey(taskID: task, requestID: "r")
        let other = LocalSecretKey(taskID: UUID().uuidString, requestID: "r")
        await secrets.put(key: key, value: AgentAnswerValue(text: "v1"))
        await secrets.put(key: other, value: AgentAnswerValue(text: "other"))
        let restingBusy = await secrets.hasInFlight
        #expect(!restingBusy, "put만으로는 바쁘지 않다 (쉬는 값)")
        // 제출이 돌고 있다: 바쁨
        await secrets.beginSubmission(key: key)
        let running = await secrets.hasInFlight
        #expect(running)
        await secrets.endSubmission(key: key)
        let ended = await secrets.hasInFlight
        #expect(!ended)
        // answered 세 번: N=3. 옛 명령의 정산 하나는 M만 하나 올린다 (task 대소문자 무관)
        await secrets.noteAnswered(key: key)
        await secrets.noteAnswered(key: key)
        await secrets.noteAnswered(key: key)
        let unfinished = await secrets.hasInFlight
        #expect(unfinished, "N=3 > M=0")
        let droppedByOpenSettle = await secrets.answerCommandEnded(taskID: task.uppercased(), closesQuestion: false)
        #expect(droppedByOpenSettle == 0)
        let stillBusy = await secrets.hasInFlight
        #expect(stillBusy, "N=3 > M=1")
        // 닫힘 정산이어도 N > M(2 < 3)이면 버리지 않는다
        let droppedWhileUnfinished = await secrets.answerCommandEnded(taskID: task, closesQuestion: true)
        let keptWhileUnfinished = await secrets.contains(key: key)
        #expect(droppedWhileUnfinished == 0 && keptWhileUnfinished)
        // 이제 M=2: 다음 닫힘 정산이 M=3=N을 채워 버린다. 다른 task의 값은 그대로다
        let droppedAtLast = await secrets.answerCommandEnded(taskID: task, closesQuestion: true)
        #expect(droppedAtLast == 1)
        let gone = await secrets.contains(key: key)
        let otherKept = await secrets.contains(key: other)
        #expect(!gone && otherKept)
        // 닫힘 정산이어도 제출이 돌고 있으면 버리지 않는다
        await secrets.put(key: key, value: AgentAnswerValue(text: "v2"))
        await secrets.beginSubmission(key: key)
        let droppedWhileRunning = await secrets.answerCommandEnded(taskID: task, closesQuestion: true)
        #expect(droppedWhileRunning == 0)
        let kept = await secrets.contains(key: key)
        #expect(kept)
        // 그 닫힘 정산은 센 명령으로 설명되지 않았으니 표시가 남아 제출이 끝날 때 값이 버려진다 (계약 16.16)
        await secrets.endSubmission(key: key)
        let droppedAtEnd = await secrets.contains(key: key)
        #expect(!droppedAtEnd)
        // M은 N을 넘지 않는다: 이 Mac이 세지 않은 명령(재시작 전의 것 등)의 정산이 새 제출의 계수를 앞지르지 않는다
        await secrets.put(key: key, value: AgentAnswerValue(text: "v3"))
        await secrets.noteAnswered(key: key)
        _ = await secrets.answerCommandEnded(taskID: task, closesQuestion: false)
        _ = await secrets.answerCommandEnded(taskID: task, closesQuestion: false)
        await secrets.noteAnswered(key: key)
        let afterCap = await secrets.hasInFlight
        #expect(afterCap, "앞서 센 정산 둘 가운데 하나만 M에 들어갔다: 새 answered는 진행 중이다")
        // 전달로 꺼내면 계수도 함께 사라진다
        _ = await secrets.take(key: key)
        _ = await secrets.take(key: other)
        let empty = await secrets.hasInFlight
        #expect(!empty)
    }

    // MARK: 계약 16.16 — 제출이 도는 동안 먼저 닿은 닫힘 정산

    @Test func aClosureSettleNoCountedCommandExplainsIsRememberedAndDropsTheValueWhenTheSubmissionEnds() async {
        let secrets = LocalSecretAnswers()
        let task = UUID().uuidString
        let key = LocalSecretKey(taskID: task, requestID: "r")
        await secrets.put(key: key, value: AgentAnswerValue(text: "v"))
        await secrets.beginSubmission(key: key)
        // 닫힘 정산이 먼저 닿는다 (N=0 · M=0: 센 명령으로 설명되지 않는다): 제출이 돌고 있어 값은 그대로다
        let droppedEarly = await secrets.answerCommandEnded(taskID: task, closesQuestion: true)
        let keptWhileRunning = await secrets.contains(key: key)
        #expect(droppedEarly == 0 && keptWhileRunning)
        // 응답이 뒤늦게 answered로 도착한다: N=1 · M=0. 제출이 끝나면 표시를 보고 값을 버린다 (바쁨도 함께 사라진다)
        await secrets.noteAnswered(key: key)
        let busyBeforeEnd = await secrets.hasInFlight
        #expect(busyBeforeEnd)
        await secrets.endSubmission(key: key)
        let gone = await secrets.hasPending
        let busy = await secrets.hasInFlight
        #expect(!gone && !busy, "N=1 · M=0으로 굳지 않는다")
    }

    @Test func theMarkDropsTheValueOnlyWhenTheLastRunningSubmissionOfTheKeyEnds() async {
        let secrets = LocalSecretAnswers()
        let task = UUID().uuidString
        let key = LocalSecretKey(taskID: task, requestID: "r")
        await secrets.put(key: key, value: AgentAnswerValue(text: "v"))
        await secrets.beginSubmission(key: key)
        await secrets.beginSubmission(key: key)
        _ = await secrets.answerCommandEnded(taskID: task, closesQuestion: true) // 표시 (제출 둘이 돈다)
        await secrets.endSubmission(key: key)
        let whileOneRuns = await secrets.contains(key: key)
        #expect(whileOneRuns, "다른 제출이 아직 돈다: 값은 그대로다")
        await secrets.endSubmission(key: key)
        let afterLast = await secrets.contains(key: key)
        #expect(!afterLast, "마지막 제출이 끝나면 버린다")
    }

    @Test func aClosureSettleThatACountedCommandExplainsLeavesNoMark() async {
        let secrets = LocalSecretAnswers()
        let task = UUID().uuidString
        let key = LocalSecretKey(taskID: task, requestID: "r")
        await secrets.put(key: key, value: AgentAnswerValue(text: "v"))
        await secrets.beginSubmission(key: key)
        await secrets.noteAnswered(key: key) // C1이 센 명령이다 (N=1)
        // C1의 닫힘 정산: M=1로 설명된다. 같은 제출에서 아직 못 받은 다른 answered가 있을 수 있으니 표시하지 않는다
        let dropped = await secrets.answerCommandEnded(taskID: task, closesQuestion: true)
        #expect(dropped == 0)
        await secrets.endSubmission(key: key)
        let kept = await secrets.contains(key: key)
        #expect(kept, "설명된 닫힘 정산은 표시를 남기지 않는다: 제출이 끝나도 값은 그대로다")
    }

    @Test func aNewSubmissionClearsTheMarkOfTheOldOneAndDiscardAndTakeClearItToo() async {
        let secrets = LocalSecretAnswers()
        let task = UUID().uuidString
        let key = LocalSecretKey(taskID: task, requestID: "r")
        // 새 제출은 닫힘 뒤에 시작했다: 그 값의 운명은 서버의 답이 정한다
        await secrets.put(key: key, value: AgentAnswerValue(text: "old"))
        await secrets.beginSubmission(key: key)
        _ = await secrets.answerCommandEnded(taskID: task, closesQuestion: true) // 표시
        await secrets.put(key: key, value: AgentAnswerValue(text: "new"))
        await secrets.beginSubmission(key: key)
        await secrets.endSubmission(key: key)
        await secrets.endSubmission(key: key)
        let keptNew = await secrets.contains(key: key)
        #expect(keptNew, "새 제출이 시작하며 표시를 지웠다")
        _ = await secrets.take(key: key)
        // 값이 버려지면(discard) 표시도 함께 사라진다: 같은 제출이 두는 다음 값을 옛 표시가 지우지 않는다
        await secrets.put(key: key, value: AgentAnswerValue(text: "v1"))
        await secrets.beginSubmission(key: key)
        _ = await secrets.answerCommandEnded(taskID: task, closesQuestion: true) // 표시
        await secrets.discard(key: key)
        await secrets.put(key: key, value: AgentAnswerValue(text: "v2"))
        await secrets.endSubmission(key: key)
        let keptAfterDiscard = await secrets.contains(key: key)
        #expect(keptAfterDiscard, "discard가 표시를 지웠다")
        // take도 같다
        await secrets.put(key: key, value: AgentAnswerValue(text: "v3"))
        await secrets.beginSubmission(key: key)
        _ = await secrets.answerCommandEnded(taskID: task, closesQuestion: true) // 표시
        _ = await secrets.take(key: key)
        await secrets.put(key: key, value: AgentAnswerValue(text: "v4"))
        await secrets.endSubmission(key: key)
        let keptAfterTake = await secrets.contains(key: key)
        #expect(keptAfterTake, "take가 표시를 지웠다")
    }
}
#endif
