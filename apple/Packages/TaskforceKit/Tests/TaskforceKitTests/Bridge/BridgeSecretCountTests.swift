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
        // M은 N을 넘지 않는다: 이 Mac이 세지 않은 명령(재시작 전의 것 등)의 정산이 새 제출의 계수를 앞지르지 않는다
        await secrets.endSubmission(key: key)
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
}
#endif
