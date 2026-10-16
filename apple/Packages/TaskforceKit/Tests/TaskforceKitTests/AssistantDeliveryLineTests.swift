import Foundation
import Testing
@testable import TaskforceKit

/// 에이전트 대상 메시지 아래의 전달 한 줄 (DS MessageDelivery, OA D4a-04 – 09, 계약 4장 표): 서버가 계산한 상태 9 × 이유 17을 말로 옮긴다.
/// DS에 있는 말은 그대로, 새 문구 아홉은 사용자 승인(2026-10-18)을 받아 앱이 그대로 쓴다 (`AgentCopy`). 모르는 이유만 일반 줄 "Not sent · Send again"으로 떨어진다
struct AssistantDeliveryLineTests {
    typealias Link = MessageDeliveryLine.Link

    func context(agent: String? = "Claude Code", target: AgentTargetState? = nil) -> AgentDeliveryContext {
        AgentDeliveryContext(agentName: agent, targetState: target)
    }

    func line(
        _ state: AgentDeliveryState, reason: AgentDeliveryReason? = nil, candidates: [AgentReferentCandidate] = [], agent: String? = "Claude Code",
        target: AgentTargetState? = nil
    ) -> MessageDeliveryLine? {
        MessageDeliveryLine.of(AgentDelivery(state: state, reason: reason, candidates: candidates), context: context(agent: agent, target: target))
    }

    // MARK: DS에 있는 줄

    @Test func theDesignLines() {
        #expect(line(.accepted) == MessageDeliveryLine(strong: nil, text: "Received"), "accepted = received (에이전트가 받음)")
        #expect(line(.sent) == MessageDeliveryLine(strong: nil, text: "Sent"))
        #expect(line(.outcomeUnknown) == MessageDeliveryLine(strong: nil, text: "Unknown · Not confirmed by the agent"), "Unknown은 Send again이 없다")
        #expect(line(.expired) == MessageDeliveryLine(strong: nil, text: "Expired · Older than 24 hours", link: Link(.sendAgain, "Send again")))
        #expect(line(.notSent) == MessageDeliveryLine(strong: "Not sent", text: nil, link: Link(.sendAgain, "Send again")), "그 밖 · 이유 없음: Not sent · Send again")
    }

    @Test func queuedSaysWhatItWaitsFor() {
        #expect(line(.queued, reason: .sessionExternal)?.combined == "Queued · Session is in Terminal")
        #expect(line(.queued, reason: .questionOpen)?.combined == "Queued · Answer the question first", "DS 말 재사용(PanelHeader 툴팁)")
        // 앞 메시지가 막고 있다는 말은 따로 하지 않는다 (머리는 Not sent · Send again으로 보인다)
        for reason in [AgentDeliveryReason.sessionBusy, .liveLimit, .queueOrder] {
            #expect(line(.queued, reason: reason) == MessageDeliveryLine(strong: nil, text: "Queued"), "\(reason.raw)")
        }
        #expect(line(.queued) == MessageDeliveryLine(strong: nil, text: "Queued"))
        #expect(line(.queued)?.link == nil, "Queued에는 Send again이 없다")
    }

    /// D4a-09: Mac is offline은 `queued`이고 이유가 없으며 그 대화 연결의 대상 상태가 `unreachable`일 때뿐이다 (서버가 준 대상 상태를 옮길 뿐)
    @Test func macIsOfflineOnlyForQueuedWithoutReasonAndAnUnreachableTarget() {
        #expect(line(.queued, target: .unreachable)?.combined == "Queued · Mac is offline")
        for target in [AgentTargetState.ready, .notConnected, .signInNeeded, .unsupported, .unknown("x")] {
            #expect(line(.queued, target: target)?.combined == "Queued", "\(target.raw)")
        }
        #expect(line(.queued, target: nil)?.combined == "Queued")
        // 이유가 있으면 이유가 이긴다
        #expect(line(.queued, reason: .sessionExternal, target: .unreachable)?.combined == "Queued · Session is in Terminal")
        #expect(line(.queued, reason: .sessionBusy, target: .unreachable)?.combined == "Queued", "이유가 있는데 Mac is offline이라 하지 않는다")
        // 다른 상태에는 붙지 않는다
        #expect(line(.sent, target: .unreachable)?.combined == "Sent")
        #expect(line(.notSent, target: .unreachable)?.text == nil)
    }

    @Test func notSentReasonsFromTheDesignAndReusedStatusWords() {
        #expect(line(.notSent, reason: .signInNeeded)?.combined == "Not sent · Not signed in to Claude Code")
        #expect(line(.notSent, reason: .signInNeeded, agent: "Codex")?.text == "Not signed in to Codex", "에이전트 이름")
        #expect(line(.notSent, reason: .signInNeeded, agent: nil)?.text == nil, "이름을 모르면 지어내지 않는다")
        #expect(line(.notSent, reason: .writeGateClosed)?.combined == "Not sent · Access not verified")
        #expect(line(.notSent, reason: .notConnected)?.combined == "Not sent · Not connected", "DS 말 재사용(TargetPicker)")
        #expect(line(.notSent, reason: .unsupported)?.combined == "Not sent · Unsupported", "DS 말 재사용(TargetPicker)")
        for reason in [AgentDeliveryReason.signInNeeded, .writeGateClosed, .notConnected, .unsupported] {
            #expect(line(.notSent, reason: reason)?.link == Link(.sendAgain, "Send again"), "\(reason.raw)")
        }
        // 그 밖 · 모르는 이유: 일반 줄 (말을 지어내지 않는다)
        for reason in [AgentDeliveryReason.sessionExternal, .sessionBusy, .liveLimit, .queueOrder, .invalidReferent, .notFound, .alreadyDispatched, .questionOpen, .unknown("disk_full")] {
            #expect(line(.notSent, reason: reason) == MessageDeliveryLine(strong: "Not sent", text: nil, link: Link(.sendAgain, "Send again")), "\(reason.raw)")
        }
    }

    // MARK: 새 문구 (사용자 승인 2026-10-18)

    @Test func theApprovedNewReasonsAreTheSection7WordsAndOnlyThose() {
        #expect(AgentCopy.versionUnsupported == "Unsupported version" && AgentCopy.usageLimited == "Usage limit reached" && AgentCopy.spawnFailed == "Session didn't start")
        #expect(AgentCopy.notReceived == "Not received" && AgentCopy.sessionClosed == "Session closed" && AgentCopy.stopped == "Stopped")
        #expect(AgentCopy.chooseReferent == "Choose an issue" && AgentCopy.addChip("#139 Rewrite pricing page copy") == "Add #139 Rewrite pricing page copy")
        #expect(AgentCopy.stoppedMayContinue == "Stopped · commands may still be running")
        let cases: [(AgentDeliveryReason, String)] = [
            (.versionUnsupported, "Unsupported version"), (.usageLimited, "Usage limit reached"), (.spawnFailed, "Session didn't start"), (.notReceived, "Not received"),
        ]
        for (reason, words) in cases {
            #expect(line(.notSent, reason: reason) == MessageDeliveryLine(strong: "Not sent", text: words, link: Link(.sendAgain, "Send again")), "\(reason.raw)")
        }
        #expect(line(.notSent, reason: .sessionClosed) == MessageDeliveryLine(strong: "Not sent", text: "Session closed"), "닫힌 세션은 Send again이 없다")
        #expect(line(.cancelled) == MessageDeliveryLine(strong: "Not sent", text: "Stopped", link: Link(.sendAgain, "Send again")))
    }

    @Test func needsReferentIsQueuedWithTheChooseLink() {
        let candidates = [AgentReferentCandidate(actionID: UUID(), title: "가격 문구"), AgentReferentCandidate(actionID: UUID(), title: "온보딩")]
        let result = line(.needsReferent, candidates: candidates)
        #expect(result == MessageDeliveryLine(strong: nil, text: "Queued", link: Link(.chooseReferent(candidates), "Choose an issue")))
        #expect(result?.combined == "Queued", "링크는 접근성에서 따로 누르는 동작이다")
        // 후보가 없으면 고를 것이 없다: 링크도 없다
        #expect(line(.needsReferent) == MessageDeliveryLine(strong: nil, text: "Queued"))
    }

    // MARK: 줄이 없는 값

    /// D4a-05 · D4a-08: answered는 서버가 곧바로 이벤트 줄을 쓰므로 두 번 말하지 않고, 모르는 값은 아무것도 주장하지 않는다
    @Test func answeredAndUnknownValuesHaveNoLine() {
        #expect(line(.answered) == nil)
        #expect(line(.unknown("teleported")) == nil)
        #expect(line(.unknown("teleported"), reason: .unknown("x")) == nil)
    }

    // MARK: Send again이 있는 곳과 없는 곳

    @Test func sendAgainIsOnlyOnNotSentExpiredAndCancelled() {
        let withLink: [AgentDeliveryState] = [.notSent, .expired, .cancelled]
        let states: [AgentDeliveryState] = [.accepted, .sent, .outcomeUnknown, .queued, .notSent, .expired, .cancelled, .answered, .needsReferent, .unknown("x")]
        for state in states {
            let has = line(state)?.link?.kind == .sendAgain
            #expect(has == withLink.contains(state), "\(state.raw)")
        }
        #expect(line(.notSent, reason: .sessionClosed)?.link == nil)
    }

    @Test func everyNotSentReasonKeepsBoldOnlyOnTheFirstWord() {
        let reasons: [AgentDeliveryReason] = [
            .notConnected, .signInNeeded, .unsupported, .writeGateClosed, .sessionExternal, .versionUnsupported, .usageLimited, .spawnFailed, .notReceived,
            .sessionBusy, .liveLimit, .queueOrder, .sessionClosed, .invalidReferent, .notFound, .alreadyDispatched, .questionOpen, .unknown("x"),
        ]
        for reason in reasons {
            let result = line(.notSent, reason: reason)
            #expect(result?.strong == "Not sent", "\(reason.raw): 굵은 말은 Not sent뿐")
        }
        // 그 밖의 줄은 굵은 말이 없다 (Not sent만 굵다)
        for state in [AgentDeliveryState.accepted, .sent, .outcomeUnknown, .queued, .expired, .needsReferent] {
            #expect(line(state)?.strong == nil, "\(state.raw)")
        }
        #expect(line(.cancelled)?.strong == "Not sent")
    }

    // MARK: 접근성 · 줄이 길 때

    @Test func combinedIsTheAccessibleNameAndNeverIncludesTheLink() {
        #expect(line(.notSent, reason: .writeGateClosed)?.combined == "Not sent · Access not verified")
        #expect(line(.expired)?.combined == "Expired · Older than 24 hours")
        #expect(line(.notSent)?.combined == "Not sent")
        #expect(line(.accepted)?.combined == "Received")
    }

    @Test func aLongAgentNameStillMakesOneLineThatTheViewWraps() {
        let name = String(repeating: "Very long agent name ", count: 8)
        let result = line(.notSent, reason: .signInNeeded, agent: name)
        #expect(result?.text == "Not signed in to \(name)", "줄을 줄이거나 자르지 않는다: 오른쪽 맞춤으로 감싸는 것은 화면이다")
    }

    @Test func theSendAgainWordIsTheDesignWord() {
        #expect(MessageDeliveryLine.sendAgainTitle == "Send again")
    }
}
