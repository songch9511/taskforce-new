#if os(macOS)
import Foundation
import Testing
@testable import TaskforceKit

/// 세션 보기 V1의 줄 만들기 (DZ v2): Claude 패널은 기록의 줄에서, Taskforce 패널은 서버 대화의 글 + 이 Mac 기록의 도구 단계에서 같은 모양의 줄을 만든다.
/// 단계는 이 Mac의 기록에서만 온다 (서버 저장은 후속): 그 세션이 이 Mac에서 돌지 않았으면 단계 없이 말 · 시간 · 복사만이다
struct SessionTimelineSourceTests {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

    // MARK: Claude 패널

    private func turn(_ id: String, _ kind: ClaudeAppTurn.Kind, _ seconds: TimeInterval? = nil, truncated: Bool = false, target: String? = nil, failed: Bool = false, real: Bool = true) -> ClaudeAppTurn {
        ClaudeAppTurn(id: id, kind: kind, timestamp: seconds.map(at), truncated: truncated, lineOffset: real ? 10 : -1, toolUseID: real ? "tu-\(id)" : nil, target: target, failed: failed)
    }

    @Test func aTranscriptBecomesUserAssistantAndStepItemsWithTheirTimes() {
        let data = SessionTimelineSource.claude([
            turn("1", .user("go"), 0), turn("2", .assistant("I will read."), 2), turn("3", .tool(name: "Read", description: nil), 3, target: "pricing.mdx"),
            turn("4", .peer("from another session", ClaudeAppPeer(plugin: nil, verifiedPeerPID: nil, messageID: nil)), 5), turn("5", .tool(name: "Bash", description: "Run the copy lint"), 6, failed: true),
        ])
        #expect(data.items.map(\.role) == [.user, .assistant, .step, .user, .step])
        #expect(data.items.map(\.id) == ["1", "2", "3", "4", "5"])
        #expect(data.items[1].text == "I will read." && data.items[0].text == nil)
        #expect(data.items.map(\.time) == [at(0), at(2), at(3), at(5), at(6)])
        #expect(data.items[2].stepName == "Read")
        #expect(data.steps["3"] == SessionStepInfo(name: "Read", target: "pricing.mdx", failed: false, canExpand: true))
        #expect(data.steps["5"] == SessionStepInfo(name: "Bash", target: "Run the copy lint", failed: true, canExpand: true))
        #expect(data.steps["2"] == nil)
    }

    @Test func theDescriptionBeatsTheFileNameAndAnEmptyOneIsNothing() {
        let data = SessionTimelineSource.claude([
            turn("1", .tool(name: "Task", description: "Compare ko.json"), target: "x.json"), turn("2", .tool(name: "Read", description: ""), target: "a.mdx"), turn("3", .tool(name: "Grep", description: nil)),
        ])
        #expect(data.steps["1"]?.target == "Compare ko.json" && data.steps["2"]?.target == "a.mdx" && data.steps["3"]?.target == nil)
    }

    @Test func aFileNameInAStepIsShortenedForTheLine() {
        let name = "LauncherWindowControllerWakeFromSleep.swift"
        let data = SessionTimelineSource.claude([turn("1", .tool(name: "Edit", description: nil), target: name)])
        #expect(data.steps["1"]?.target == SessionStepText.shortFileName(name))
        #expect(data.steps["1"]?.line == "Edit · " + SessionStepText.shortFileName(name))
    }

    @Test func aStepCanExpandOnlyWhenItHasAPlaceInARealTranscript() {
        let data = SessionTimelineSource.claude([turn("1", .tool(name: "Read", description: nil), real: false), turn("2", .tool(name: "Read", description: nil))])
        #expect(data.steps["1"]?.canExpand == false && data.steps["2"]?.canExpand == true)
    }

    @Test func aTruncatedAnswerCopiesTheVisibleTextWithItsEllipsis() {
        let data = SessionTimelineSource.claude([turn("1", .assistant("cut here"), truncated: true), turn("2", .assistant("whole"))])
        #expect(data.items.map(\.text) == ["cut here…", "whole"])
    }

    // MARK: 진행 상태

    @Test func theRunStateFollowsTheDesktopStatusAndAClosedSessionIsFinished() {
        #expect(SessionTimelineSource.runState(.running, closed: false) == .running)
        #expect(SessionTimelineSource.runState(.needsApproval, closed: false) == .frozen && SessionTimelineSource.runState(.needsAnswer, closed: false) == .frozen)
        #expect(SessionTimelineSource.runState(.idle, closed: false) == .finished && SessionTimelineSource.runState(.done, closed: false) == .finished)
        #expect(SessionTimelineSource.runState(nil, closed: false) == .finished, "모르면 일한다고 말하지 않는다")
        #expect(SessionTimelineSource.runState(.running, closed: true) == .finished)
    }

    @Test func theRunStateOfATaskforceSessionFollowsItsLastTask() {
        for running in [AgentTaskState.dispatched, .accepted, .running] { #expect(SessionTimelineSource.runState(task: running, closed: false) == .running) }
        #expect(SessionTimelineSource.runState(task: .awaitingAnswer, closed: false) == .frozen)
        for finished in [AgentTaskState.idle, .completed, .failed, .cancelled, .unreachable, .unknown("x")] { #expect(SessionTimelineSource.runState(task: finished, closed: false) == .finished) }
        #expect(SessionTimelineSource.runState(task: nil, closed: false) == .finished)
        #expect(SessionTimelineSource.runState(task: .running, closed: true) == .finished)
    }

    // MARK: Taskforce 패널: 대화 + 이 Mac 기록의 단계

    private func chat(_ n: Int, user: Bool, _ seconds: TimeInterval, text: String? = nil, event: Bool = false) -> ChatTurn {
        var turn = ChatTurn(
            id: UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", n))!, isUser: user, text: text ?? (user ? "ask \(n)" : "answer \(n)"), createdAt: at(seconds), status: .sent, clientMessageID: nil
        )
        turn.isEvent = event
        return turn
    }

    private func id(_ n: Int) -> String { String(format: "00000000-0000-4000-8000-%012d", n) }

    @Test func stepsAreInsertedBetweenTheAskAndTheReplyByTime() {
        let data = SessionTimelineSource.chat(
            [chat(1, user: true, 0), chat(2, user: false, 60)],
            steps: [turn("s1", .tool(name: "Read", description: nil), 10), turn("s2", .tool(name: "Grep", description: nil), 20), turn("s3", .tool(name: "Edit", description: nil), 40)]
        )
        #expect(data.items.map(\.id) == [id(1), "s1", "s2", "s3", id(2)])
        #expect(data.items.map(\.role) == [.user, .step, .step, .step, .assistant])
    }

    @Test func aStepAtTheSameTimeComesAfterTheAskAndBeforeTheReply() {
        let data = SessionTimelineSource.chat([chat(1, user: true, 10), chat(2, user: false, 30)], steps: [turn("a", .tool(name: "Read", description: nil), 10), turn("b", .tool(name: "Read", description: nil), 30)])
        #expect(data.items.map(\.id) == [id(1), "a", "b", id(2)])
    }

    @Test func stepsAfterTheLastMessageStayAtTheEndWhileTheTurnIsStillRunning() {
        let data = SessionTimelineSource.chat([chat(1, user: true, 0), chat(2, user: false, 5)], steps: [turn("a", .tool(name: "Bash", description: nil), 50)])
        #expect(data.items.map(\.id) == [id(1), id(2), "a"])
    }

    @Test func stepsOfEarlierTurnsLandInTheirOwnTurn() {
        let data = SessionTimelineSource.chat(
            [chat(1, user: true, 0), chat(2, user: false, 30), chat(3, user: true, 100), chat(4, user: false, 160)],
            steps: [turn("a", .tool(name: "Read", description: nil), 10), turn("b", .tool(name: "Read", description: nil), 120)]
        )
        #expect(data.items.map(\.id) == [id(1), "a", id(2), id(3), "b", id(4)])
    }

    @Test func stepsOlderThanTheChatAreLeftOutSoAnAdoptedSessionsHistoryDoesNotFloodThePanel() {
        let data = SessionTimelineSource.chat(
            [chat(1, user: true, 1000), chat(2, user: false, 1060)],
            steps: [turn("old1", .tool(name: "Read", description: nil), 10), turn("edge", .tool(name: "Read", description: nil), 997), turn("mine", .tool(name: "Read", description: nil), 1020)]
        )
        #expect(data.items.map(\.id) == [id(1), "edge", "mine", id(2)], "5초 여유 안의 단계는 시계 어긋남으로 본다")
    }

    @Test func stepsWithoutATimeAndNonToolTurnsAreLeftOut() {
        let data = SessionTimelineSource.chat(
            [chat(1, user: true, 0), chat(2, user: false, 60)],
            steps: [turn("a", .tool(name: "Read", description: nil), nil), turn("b", .assistant("text"), 10), turn("c", .user("typed"), 12), turn("d", .tool(name: "Read", description: nil), 20)]
        )
        #expect(data.items.map(\.id) == [id(1), "d", id(2)])
    }

    @Test func withoutALocalTranscriptTheTimelineIsTheChatAlone() {
        let data = SessionTimelineSource.chat([chat(1, user: true, 0), chat(2, user: false, 60), chat(3, user: false, 61, event: true)], steps: [])
        #expect(data.items.map(\.role) == [.user, .assistant, .other])
        #expect(data.steps.isEmpty)
    }

    @Test func aChatWithNoMessagesHasNoStepsEvenIfTheTranscriptHasSome() {
        #expect(SessionTimelineSource.chat([], steps: [turn("a", .tool(name: "Read", description: nil), 1)]).items.isEmpty)
    }

    @Test func anAnswerCopiesTheFullTextOnceViewFullExpandedItAndNothingWhenItWasPurged() {
        var cut = chat(2, user: false, 60, text: "short…")
        cut.isTruncated = true
        var expanded = cut
        expanded.fullText = "the whole answer"
        let purged = ChatTurn(id: UUID(uuidString: id(9))!, isUser: false, text: "", createdAt: at(70), status: .sent, clientMessageID: nil, textDeleted: true)
        let data = SessionTimelineSource.chat([chat(1, user: true, 0), cut, expanded, purged], steps: [])
        #expect(data.items.map(\.text) == [nil, "short…", "the whole answer", nil])
    }

    @Test func aTruncatedAnswerWithoutTheEllipsisGetsOneAndTheSharedRuleIsTheViewsRule() {
        var cut = chat(2, user: false, 60, text: "cut here")
        cut.isTruncated = true
        #expect(cut.visibleText == "cut here…")
        cut.fullText = "full"
        #expect(cut.visibleText == "full")
        #expect(chat(3, user: false, 1, text: "plain").visibleText == "plain")
        var already = chat(4, user: false, 1, text: "ends…")
        already.isTruncated = true
        #expect(already.visibleText == "ends…")
    }

    @Test func theTimesComeFromTheServerMessageTimeAndTheStepsFromTheTranscript() {
        let data = SessionTimelineSource.chat([chat(1, user: true, 0), chat(2, user: false, 90)], steps: [turn("a", .tool(name: "Read", description: nil), 5)])
        #expect(data.items.map(\.time) == [at(0), at(5), at(90)])
        let entries = SessionTimeline.build(data.items, state: .finished)
        #expect(entries.compactMap { if case .footer(let f) = $0 { f } else { nil } } == [SessionFooter(id: "footer-\(id(2))", workedFor: 90, copyText: "answer 2")])
    }
}
#endif
