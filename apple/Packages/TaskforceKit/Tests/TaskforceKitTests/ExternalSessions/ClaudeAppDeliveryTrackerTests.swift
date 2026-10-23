#if os(macOS) && DEBUG
import Foundation
import Testing
@testable import TaskforceKit

extension ExternalSessionSuites {
    /// 데스크톱 세션으로 보낸 말의 전달 상태 기계 (PR-D3k, 계약 25.4.4 · DZ 승인 2026-10-22 시트 4): Sending… → Sent → Received · via Taskforce, 질문이 떠 있으면 Queued · {이유}(30초 시계 멈춤),
    /// 못 보내면 Not sent · {이유 넷}. 순수 상태 기계다: 시계는 부르는 쪽이 `at:`으로 넣는다 (손으로 흘린다). 실제 기록 · 프로세스는 만지지 않는다
    struct ClaudeAppDeliveryTrackerTests {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)

        private func sent(at start: Date? = nil) -> ClaudeAppDeliveryTracker {
            var tracker = ClaudeAppDeliveryTracker(startedAt: start ?? t0)
            tracker.apply(.relayAccepted, at: (start ?? t0).addingTimeInterval(0.25))
            return tracker
        }

        // MARK: 정상 흐름

        @Test func aMessageStartsAsSendingThenSentWhenTheRelayAcceptsThenReceivedWhenTheTranscriptShowsIt() {
            var tracker = ClaudeAppDeliveryTracker(startedAt: t0)
            #expect(tracker.state == .sending && tracker.isPending)
            tracker.apply(.relayAccepted, at: t0.addingTimeInterval(0.25))
            #expect(tracker.state == .sent && tracker.isPending)
            tracker.apply(.transcriptReceived, at: t0.addingTimeInterval(1))
            #expect(tracker.state == .received && !tracker.isPending)
        }

        @Test func theTranscriptCanShowTheLineBeforeTheRelayAnswers() {
            var tracker = ClaudeAppDeliveryTracker(startedAt: t0)
            tracker.apply(.transcriptReceived, at: t0.addingTimeInterval(0.1))
            #expect(tracker.state == .received, "대상 기록의 줄이 가장 확실한 증거다")
            tracker.apply(.relayAccepted, at: t0.addingTimeInterval(0.25))
            #expect(tracker.state == .received, "끝난 상태는 늦게 온 사건으로 되돌아가지 않는다")
        }

        // MARK: 승인 기다림 = Queued, 30초 시계는 멈춘다

        @Test func aWaitingTargetMakesItQueuedWithTheReasonWordAndResumesWhenTheTargetMovesOn() {
            var tracker = sent()
            tracker.apply(.target(.waiting(.approval)), at: t0.addingTimeInterval(1))
            #expect(tracker.state == .queued(.approval))
            tracker.apply(.target(.waiting(.answer)), at: t0.addingTimeInterval(2))
            #expect(tracker.state == .queued(.answer))
            tracker.apply(.target(.busy), at: t0.addingTimeInterval(3))
            #expect(tracker.state == .sent, "질문이 끝나면 다시 기록을 기다린다")
            tracker.apply(.transcriptReceived, at: t0.addingTimeInterval(4))
            #expect(tracker.state == .received)
        }

        @Test func theThirtySecondClockStopsWhileQueuedAndKeepsWhatWasAlreadySpent() {
            var tracker = sent()
            // 보낸 지 10초: 아직이다
            tracker.apply(.tick(permissionMode: nil), at: t0.addingTimeInterval(10.25))
            #expect(tracker.state == .sent)
            // 10.25초에 질문이 떴다: 100초 동안 Queued (시계 멈춤)
            tracker.apply(.target(.waiting(.approval)), at: t0.addingTimeInterval(10.25))
            tracker.apply(.tick(permissionMode: nil), at: t0.addingTimeInterval(110.25))
            #expect(tracker.state == .queued(.approval), "기다리는 동안은 시간 초과가 없다")
            // 질문이 끝났다: 앞서 쓴 10초(보낸 뒤 0.25초에 시계가 시작) 위에 이어서 센다 (이진수로 딱 떨어지는 값만 쓴다: 경계가 부동소수 오차에 흔들리지 않게)
            tracker.apply(.target(.busy), at: t0.addingTimeInterval(110.25))
            tracker.apply(.tick(permissionMode: nil), at: t0.addingTimeInterval(110.25 + 19.75))
            #expect(tracker.state == .sent, "10 + 19.75 = 29.75초: 아직")
            tracker.apply(.tick(permissionMode: nil), at: t0.addingTimeInterval(110.25 + 20))
            #expect(tracker.state == .notSent(.notReceived), "10 + 20 = 30초")
        }

        // MARK: 못 보냄

        @Test func noTranscriptLineInThirtySecondsIsNotReceivedOrBypassWhenTheModeIsKnown() {
            var plain = sent()
            plain.apply(.tick(permissionMode: nil), at: t0.addingTimeInterval(0.25 + 29.75))
            #expect(plain.state == .sent)
            plain.apply(.tick(permissionMode: "default"), at: t0.addingTimeInterval(0.25 + 30))
            #expect(plain.state == .notSent(.notReceived), "모드를 알아도 bypass가 아니면 이유를 모른다")

            var unknown = sent()
            unknown.apply(.tick(permissionMode: nil), at: t0.addingTimeInterval(31))
            #expect(unknown.state == .notSent(.notReceived), "모드를 모르면 Not received")

            var bypass = sent()
            bypass.apply(.tick(permissionMode: "bypassPermissions"), at: t0.addingTimeInterval(31))
            #expect(bypass.state == .notSent(.bypass), "기록이 Bypass 모드라고 말할 때만")
        }

        @Test func aMessageIsNeverTimedOutBeforeTheRelayAnswers() {
            var tracker = ClaudeAppDeliveryTracker(startedAt: t0)
            tracker.apply(.tick(permissionMode: nil), at: t0.addingTimeInterval(120))
            #expect(tracker.state == .sending, "30초 시계는 릴레이가 넘긴 뒤부터다 (릴레이 쪽 기한은 릴레이가 정한다)")
        }

        @Test func theRelayRefusingTheMessageEndsItWithTheReasonItGave() {
            var closed = ClaudeAppDeliveryTracker(startedAt: t0)
            closed.apply(.relayRefused(.sessionClosed), at: t0.addingTimeInterval(0.3))
            #expect(closed.state == .notSent(.sessionClosed))
            var failed = ClaudeAppDeliveryTracker(startedAt: t0)
            failed.apply(.relayRefused(.relayFailed), at: t0.addingTimeInterval(0.3))
            #expect(failed.state == .notSent(.relayFailed))
        }

        @Test func theSendCheckBlockingTheMessageEndsItBeforeAnythingWasSent() {
            var tracker = ClaudeAppDeliveryTracker(startedAt: t0)
            tracker.apply(.blocked(.twoWriters), at: t0)
            #expect(tracker.state == .notSent(.twoWriters))
        }

        @Test func theTargetEndingBeforeTheLineWasSeenIsSessionClosed() {
            for stage in 0..<3 {
                var tracker = ClaudeAppDeliveryTracker(startedAt: t0)
                if stage >= 1 { tracker.apply(.relayAccepted, at: t0.addingTimeInterval(0.25)) }
                if stage >= 2 { tracker.apply(.target(.waiting(.approval)), at: t0.addingTimeInterval(1)) }
                tracker.apply(.targetClosed, at: t0.addingTimeInterval(2))
                #expect(tracker.state == .notSent(.sessionClosed), "단계 \(stage)")
            }
        }

        @Test func finishedStatesIgnoreEveryLaterEvent() {
            var received = sent()
            received.apply(.transcriptReceived, at: t0.addingTimeInterval(1))
            for event: ClaudeAppDeliveryTracker.Event in [.targetClosed, .relayRefused(.relayFailed), .blocked(.twoWriters), .target(.waiting(.approval)), .tick(permissionMode: nil)] {
                received.apply(event, at: t0.addingTimeInterval(500))
                #expect(received.state == .received)
            }
            var failed = sent()
            failed.apply(.targetClosed, at: t0.addingTimeInterval(1))
            for event: ClaudeAppDeliveryTracker.Event in [.transcriptReceived, .relayAccepted, .target(.busy)] {
                failed.apply(event, at: t0.addingTimeInterval(2))
                #expect(failed.state == .notSent(.sessionClosed))
            }
        }

        // MARK: 화면 줄 (승인된 문구만)

        @Test func everyStateReadsAsTheApprovedLineAndNothingElse() {
            func line(_ state: ClaudeAppDeliveryTracker.State) -> MessageDeliveryLine { state.line }
            let sendAgain = MessageDeliveryLine.Link(.sendAgain, "Send again")
            #expect(line(.sending) == MessageDeliveryLine(strong: nil, text: "Sending…"))
            #expect(line(.sent) == MessageDeliveryLine(strong: nil, text: "Sent"))
            #expect(line(.queued(.approval)) == MessageDeliveryLine(strong: nil, text: "Queued · Needs approval in Claude"))
            #expect(line(.queued(.answer)) == MessageDeliveryLine(strong: nil, text: "Queued · Needs your answer in Claude"))
            #expect(line(.received) == MessageDeliveryLine(strong: nil, text: "Received · via Taskforce"))
            #expect(line(.notSent(.sessionClosed)) == MessageDeliveryLine(strong: "Not sent", text: "Session closed"), "닫힌 세션은 Send again이 없다")
            #expect(line(.notSent(.notReceived)) == MessageDeliveryLine(strong: "Not sent", text: "Not received", link: sendAgain))
            #expect(line(.notSent(.bypass)) == MessageDeliveryLine(strong: "Not sent", text: "Session is in Bypass mode", link: sendAgain))
            #expect(line(.notSent(.twoWriters)) == MessageDeliveryLine(strong: "Not sent", text: "Running in two places", link: sendAgain))
            #expect(line(.notSent(.relayFailed)) == MessageDeliveryLine(strong: "Not sent", text: "Not received", link: sendAgain), "중계 실패도 말은 Not received")
        }

        @Test func theMetricReasonCodesAreTheServersFive() {
            #expect(Set(ClaudeAppNotSentReason.allCases.map(\.code)) == ["session_closed", "not_received", "bypass", "two_writers", "relay_failed"])
        }

        @Test func theApprovedStringsAreExactlyTheDZTable() {
            #expect(ClaudeAppChatCopy.composerPlaceholder == "Message Claude Code")
            #expect(ClaudeAppChatCopy.confirmTitle == "Send to this session?")
            #expect(ClaudeAppChatCopy.confirmDetail == "Claude sees it as a message from Taskforce. Approvals stay in Claude.")
            #expect(ClaudeAppChatCopy.confirmSend == "Send" && ClaudeAppChatCopy.confirmCancel == "Cancel")
            #expect(ClaudeAppChatCopy.fromAnotherSession == "From another session")
            #expect(ClaudeAppChatCopy.viaTaskforce == "via Taskforce")
            #expect(ClaudeAppChatCopy.bypassMode == "Session is in Bypass mode" && ClaudeAppChatCopy.twoPlaces == "Running in two places")
        }
    }
}
#endif
