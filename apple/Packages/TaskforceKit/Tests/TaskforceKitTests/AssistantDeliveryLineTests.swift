import Foundation
import Testing
@testable import TaskforceKit

/// 에이전트 대상 메시지 아래의 전달 한 줄 (OA U1, DS MessageDelivery): 서버가 계산한 상태를 **기존 여섯 단어로만** 옮긴다.
/// 이유 코드 문구 · 후보 고르기 · 취소 · Send again은 D4a다: 그 밖의 상태는 일반 실패 줄 "Not sent"로 보인다
struct AssistantDeliveryLineTests {
    func line(_ state: AgentDeliveryState, reason: AgentDeliveryReason? = nil) -> MessageDeliveryLine {
        MessageDeliveryLine.of(AgentDelivery(state: state, reason: reason))
    }

    @Test func theSixWordsOfTheDesign() {
        #expect(line(.accepted) == MessageDeliveryLine(strong: nil, text: "Received"), "accepted = received (에이전트가 받음)")
        #expect(line(.sent) == MessageDeliveryLine(strong: nil, text: "Sent"))
        #expect(line(.outcomeUnknown) == MessageDeliveryLine(strong: nil, text: "Unknown · Not confirmed by the agent"))
        #expect(line(.queued) == MessageDeliveryLine(strong: nil, text: "Queued"))
        #expect(line(.notSent) == MessageDeliveryLine(strong: "Not sent", text: nil), "Not sent만 굵다 (빨강이 아니다)")
        #expect(line(.expired) == MessageDeliveryLine(strong: nil, text: "Expired · Older than 24 hours"))
    }

    @Test func everyOtherStateIsTheGeneralNotSentLine() {
        for state in [AgentDeliveryState.answered, .needsReferent, .cancelled, .unknown("teleported")] {
            #expect(line(state) == MessageDeliveryLine(strong: "Not sent", text: nil), "\(state.raw)")
        }
    }

    /// 이유 코드 17개의 문구는 D4a가 정한다: U1은 이유로 문구를 바꾸지 않는다 (없는 문구를 지어내지 않는다)
    @Test func reasonCodesDoNotChangeTheWords() {
        #expect(line(.queued, reason: .sessionBusy) == line(.queued))
        #expect(line(.notSent, reason: .writeGateClosed) == line(.notSent))
        #expect(line(.notSent, reason: .unknown("disk_full")) == line(.notSent))
    }

    @Test func onlyNotSentIsBoldAndNoneIsRed() {
        let all: [AgentDeliveryState] = [.accepted, .sent, .outcomeUnknown, .queued, .notSent, .expired, .answered, .needsReferent, .cancelled]
        let bold = all.filter { line($0).strong != nil }
        #expect(Set(bold) == [.notSent, .answered, .needsReferent, .cancelled], "굵은 줄은 일반 실패 줄뿐")
        #expect(line(.accepted).combined == "Received" && line(.notSent).combined == "Not sent")
        #expect(line(.queued).combined == "Queued")
    }
}
