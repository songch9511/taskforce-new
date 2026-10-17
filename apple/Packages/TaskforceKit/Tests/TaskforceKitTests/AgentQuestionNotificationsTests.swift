import Foundation
import Testing
@testable import TaskforceKit

/// 로컬 알림 규칙과 새 문구 (OA D4b-m-1, D4bm-60 · 61 · 62 · 계약 9장): 글은 상태 + 열 곳뿐 — 질문 글 · 이슈 제목 · 세션 이름 · 경로는 한 글자도 실리지 않는다 (카나리)
struct AgentQuestionNotificationsTests {
    typealias F = AgentQuestionFixtures

    static let canary = "DO_NOT_STORE_SECRET_D4BM"

    private func opened(agent: String = "Claude Code", request: String = F.requestID) -> AgentQuestionOpened {
        AgentQuestionOpened(key: F.key(request), sessionID: F.sessionID, agentName: agent)
    }

    @Test func theTitleIsTheAgentNameAndTheBodyIsTheApprovedNeedsYourAnswer() {
        let plan = AgentQuestionNotifications.plan(for: opened(), copy: .approved)
        #expect(plan.title == "Claude Code" && plan.body == "Needs your answer", "사용자가 승인한 알림 본문 (PR #157)")
        #expect(AgentQuestionNotifications.plan(for: opened()).body == "Needs your answer", "앱이 쓰는 기본값도 같다")
    }

    @Test func anEmptyCopyLeavesTheBodyOut() {
        let plan = AgentQuestionNotifications.plan(for: opened(), copy: AgentQuestionUnapprovedCopy())
        #expect(plan.title == "Claude Code" && plan.body == "", "값이 없으면 본문이 비어 있다")
    }

    @Test func anUnknownAgentNameFallsBackToTheAppName() {
        #expect(AgentQuestionNotifications.plan(for: opened(agent: ""), copy: .approved).title == "Taskforce")
    }

    @Test func nothingFromTheQuestionOrTheSessionIsInTheNotification() throws {
        // 질문 글 · 선택지 · 세션 이름 · 경로를 카나리로 심어도 알림에는 닿을 길이 없다: 재료는 열쇠 · 세션 id · 에이전트 이름뿐이다
        let json = F.pending(prompts: [F.prompt(text: "Edit \(Self.canary)/secret.txt", header: Self.canary, options: [(Self.canary, Self.canary)])], request: "req-\(Self.canary)")
        let q = try #require(AgentPendingQuestion(json: Data(json.utf8), taskID: F.taskID))
        let plan = AgentQuestionNotifications.plan(for: AgentQuestionOpened(key: q.key, sessionID: F.sessionID, agentName: "Claude Code"), copy: .approved)
        let everything = [plan.id, plan.title, plan.body] + plan.userInfo.map { "\($0.key)=\($0.value)" }
        #expect(everything.allSatisfy { !$0.contains(Self.canary) }, "요청 id도 해시로만 쓴다")
        #expect(Set(plan.userInfo.keys) == ["kind", "session_id", "task_id"] && plan.userInfo["kind"] == "agent_question")
    }

    @Test func theIdentifierIsOnePerQuestionVersionAndStableAcrossReads() {
        let a = AgentQuestionNotifications.identifier(for: F.key("r1"))
        #expect(a == AgentQuestionNotifications.identifier(for: F.key("r1")) && a != AgentQuestionNotifications.identifier(for: F.key("r2")))
        #expect(a.hasPrefix("agent-question:\(F.taskID.uuidString.lowercased()):") && a.count == "agent-question:".count + 36 + 1 + 64)
    }

    @Test func itPostsOnlyWhenAllowedAndNotAlreadyVisibleOnTheKeySurface() {
        typealias N = AgentQuestionNotifications
        #expect(N.shouldPost(permission: .allowed, isVisibleOnKeySurface: false))
        #expect(!N.shouldPost(permission: .allowed, isVisibleOnKeySurface: true), "그 카드가 지금 보이면 보내지 않는다")
        #expect(!N.shouldPost(permission: .denied, isVisibleOnKeySurface: false), "거절했으면 조용히")
        #expect(!N.shouldPost(permission: .notDetermined, isVisibleOnKeySurface: false), "질문 순간에 시스템 창을 띄우지 않는다")
    }

    @Test func aConnectionOnThisMacCountsAsAConnectionForTheOneTimePermissionAsk() {
        typealias N = AgentQuestionNotifications
        #expect(N.shouldRequestPermission(status: .notDetermined, signedIn: true, hasThisMacConnection: true, isPresentingOther: false))
        #expect(!N.shouldRequestPermission(status: .notDetermined, signedIn: true, hasThisMacConnection: false, isPresentingOther: false))
        #expect(!N.shouldRequestPermission(status: .denied, signedIn: true, hasThisMacConnection: true, isPresentingOther: false), "시스템도 한 번만 묻는다")
        #expect(!N.shouldRequestPermission(status: .notDetermined, signedIn: true, hasThisMacConnection: true, isPresentingOther: true))
    }

    // MARK: 누르면 열 곳

    @Test func aTappedQuestionNotificationOpensThatSessionAndOldBuildsStillReadItAsOther() {
        let plan = AgentQuestionNotifications.plan(for: opened(), copy: .approved)
        let target = NotificationTarget(userInfo: plan.userInfo)
        #expect(target.kind == .question && target.sessionID == F.sessionID && target.actionID == nil)
        // 모르는 kind는 지금도 앱만 연다
        #expect(NotificationTarget(userInfo: ["kind": "something_new"]).kind == .other)
        #expect(NotificationTarget(userInfo: ["kind": "confirmation", "action_id": F.taskID.uuidString]).kind == .confirmation)
        #expect(NotificationTarget(userInfo: ["kind": "agent_question", "session_id": "not-a-uuid"]).sessionID == nil)
    }

    // MARK: 새 문구

    @Test func theApprovedCopyIsExactlyTheTwoWordsTheUserApproved() {
        #expect(AgentQuestionUnapprovedCopy.approved.anotherMac == "Answer on another Mac" && AgentQuestionUnapprovedCopy.approved.questionNotificationBody == "Needs your answer")
        #expect(!AgentQuestionUnapprovedCopy.approved.isEmpty && AgentQuestionNewCopy.active == .approved, "앱이 쓰는 값이 승인된 값이다 (Release에도 컴파일된다)")
    }

    @Test func theRemoteSecretRowNamesTheMacOrFallsBackToTheApprovedAnotherMac() {
        #expect(AgentQuestionUnapprovedCopy.approved.remoteRow(macName: "Mina's MacBook Pro") == "Answer on Mina's MacBook Pro", "DS 문구")
        #expect(AgentQuestionUnapprovedCopy.approved.remoteRow(macName: nil) == "Answer on another Mac" && AgentQuestionUnapprovedCopy.approved.remoteRow(macName: "") == "Answer on another Mac", "이름을 모르면 승인된 대체 문구")
        #expect(AgentQuestionUnapprovedCopy().remoteRow(macName: nil) == nil, "값이 비어 있으면 줄을 그리지 않는다")
    }

    @Test func theDesignWordsAreExactlyTheOnesInTheDesignSystem() {
        #expect(AgentQuestionCopy.answerSent == "Answer sent" && AgentQuestionCopy.undo == "Undo" && AgentQuestionCopy.send == "Send")
        #expect(AgentQuestionCopy.staysOnThisMac == "Stays on this Mac" && AgentQuestionCopy.cantBeEnteredHere == "Can't be entered here" && AgentQuestionCopy.otherField == "Other")
        #expect(AgentQuestionFailure.lead == "Couldn't send" && AgentQuestionFailure.offlineReason == "You're offline. Try again.")
        #expect(AssistantPromptRules.blockedDefault == "Answer the question above first")
    }
}
