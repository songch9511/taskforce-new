import AppKit
import Carbon.HIToolbox
import Foundation
import Testing
@testable import Taskforce
@testable import TaskforceKit
@testable import TaskforceUI

/// Assistant 창의 에이전트 대화 (OA D4a-1, 격리 호스트): 보내기 → 전달 줄 · Send again · 후보 고르기 메뉴 · Stop · 잘린 답 View full · 이벤트 줄 · auto 칩 누르기.
/// 서버는 가짜(`AgentChatSampleGateway`: 렌더 fixture)이고 창은 만들되 화면에 올리지 않는다 (`presents = false`). 실제 서버 · 계정 · `claude` 실행이 없다
@MainActor
struct AssistantAgentChatTests {
    typealias Data = AgentChatSampleData

    @MainActor
    private struct Rig {
        let controller: EdgeShellController
        let runtime: ChatRuntime
        let gateway: AgentChatSampleGateway
        let defaults: TestDefaults
        /// 계정은 시험이 끝날 때까지 산다 (`AccountScope`는 세션 저장소를 붙들지 않는다)
        let account: AppChatAccount

        var shell: EdgeShellModel { controller.shell }
        var manager: AssistantWindowManager { controller.assistant! }
        var chat: ChatStore { runtime.chat }
    }

    private func rig(_ scene: AgentChatSampleGateway.State, issueScreens: Bool = true) async throws -> Rig {
        let account = try AppChatAccount.make()
        let gateway = AgentChatSampleGateway()
        gateway.state = scene
        let runtime = ChatRuntime(gateway: gateway, contextGateway: IssueSampleContextGateway(), scope: account.scope, now: { Date() }, issueScreens: issueScreens)
        let defaults = try TestDefaults()
        let controller = EdgeShellController(
            launcher: LauncherModel(configurationError: "test"), chat: runtime, assistantWindows: true, positionStore: AssistantWindowPositionStore(defaults: defaults.defaults)
        )
        controller.assistant?.presents = false
        controller.ignoresExternalDismissal = false
        await runtime.targets.refresh()
        await runtime.chat.refresh()
        return Rig(controller: controller, runtime: runtime, gateway: gateway, defaults: defaults, account: account)
    }

    /// 대화를 보이는 창 하나 (읽기가 끝난 뒤)
    private func open(_ r: Rig) async throws -> AssistantWindowModel {
        let id = try #require(r.manager.openWindow(for: Data.conversationID))
        let model = try #require(r.manager.controllers[id]?.model)
        await r.chat.settle()
        await model.agent?.sessions.refresh()
        return model
    }

    private func turns(_ r: Rig) -> [ChatTurn] { r.chat.turns(for: Data.conversationID) }

    /// 조건이 설 때까지 기다린다 (양보 횟수로 짐작하지 않는다). 안전망 3초
    private func eventually(_ condition: @MainActor () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return condition()
    }

    private func key(_ code: Int, _ characters: String) throws -> NSEvent {
        try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, characters: characters, charactersIgnoringModifiers: characters,
            isARepeat: false, keyCode: UInt16(code)
        ))
    }

    // MARK: 전달 줄 · Send again

    @Test func theWindowReadsTheDeliveryLinesFromTheServerAndSaysThemInWords() async throws {
        let r = try await rig(Data.waiting())
        defer { r.defaults.cleanup(); r.manager.closeAll() }
        let model = try await open(r)
        let words = turns(r).compactMap { model.deliveryLine(for: $0)?.combined }
        #expect(words == ["Queued · Mac is offline", "Not sent · Not signed in to Claude Code", "Not sent · Access not verified", "Expired · Older than 24 hours"], "Figma OA-4 Waiting")
        let again = turns(r).compactMap { model.deliveryLine(for: $0)?.link?.title }
        #expect(again == ["Send again", "Send again", "Send again"], "Queued에는 링크가 없다")
        #expect(r.gateway.calls(prefix: "deliveries").count >= 1, "대화를 열 때 전달 표시를 서버에서 읽는다")
    }

    @Test func sendAgainDeliversTheServerMessageOnceAndTheLineBecomesQueued() async throws {
        let r = try await rig(Data.waiting())
        defer { r.defaults.cleanup(); r.manager.closeAll() }
        let model = try await open(r)
        let failed = try #require(turns(r).first { model.deliveryLine(for: $0)?.strong == "Not sent" })
        async let first: Void = model.sendAgain(failed)
        async let second: Void = model.sendAgain(failed)
        _ = await (first, second)
        #expect(r.gateway.calls(prefix: "deliver:") == ["deliver:\(failed.id.uuidString)"], "두 번 눌러도 요청은 하나, 서버 메시지 id")
        let after = try #require(turns(r).first { $0.id == failed.id })
        #expect(model.deliveryLine(for: after)?.combined == "Queued")
        #expect(!model.canSendAgain(after))
    }

    // MARK: 거절된 Send again (동의 · 오류)

    @Test func aConsentRefusalOnSendAgainShowsTheConsentNoticeAndTheStatusLineAndTryAgainResendsIt() async throws {
        let r = try await rig(Data.waiting())
        defer { r.defaults.cleanup(); r.manager.closeAll() }
        let model = try await open(r)
        let failed = try #require(turns(r).first { model.deliveryLine(for: $0)?.strong == "Not sent" })
        r.gateway.deliverFailure = APIError.server(status: 409, code: .conflict, message: APIError.consentRequiredMessage)
        await model.sendAgain(failed)
        await r.chat.settle()
        let refused = try #require(turns(r).first { $0.id == failed.id })
        #expect(r.chat.needsConsent(in: Data.conversationID), "기존 동의 안내 (Allow AI processing to continue)")
        #expect(refused.status == .needsConsent && refused.showsStatusLine, "전달 줄 대신 기존 상태 줄")
        // 전달 읽기가 성공해도 거절이 사라지지 않는다
        await r.chat.refreshDeliveries(Data.conversationID)
        #expect(r.chat.needsConsent(in: Data.conversationID))
        // 동의한 뒤 Try again
        r.gateway.deliverFailure = nil
        await model.retryDelivery(refused)
        let again = try #require(turns(r).first { $0.id == failed.id })
        #expect(!r.chat.needsConsent(in: Data.conversationID) && !again.showsStatusLine && model.deliveryLine(for: again)?.combined == "Queued")
        #expect(r.gateway.calls(prefix: "deliver:") == ["deliver:\(failed.id.uuidString)", "deliver:\(failed.id.uuidString)"])
    }

    // MARK: 거절된 후보 고르기 뒤에도 다른 후보를 고를 수 있다

    /// 고른 후보가 지워졌다(404): 오류 줄 옆에 고르기 링크가 남고, Try again은 낡은 선택을 다시 보내지 않고 지금 후보로 메뉴를 다시 연다
    @Test func aRefusedCandidateChoiceKeepsTheChoiceLinkAndTryAgainReopensTheMenuWithTheCurrentCandidates() async throws {
        let r = try await rig(Data.queued())
        defer { r.defaults.cleanup(); r.manager.closeAll() }
        let model = try await open(r)
        let ambiguous = try #require(turns(r).first { $0.delivery?.state == .needsReferent })
        let (a, b, c) = (Data.referentActions[0], Data.referentActions[1], Data.referentActions[2])
        model.openReferentMenu(for: ambiguous.id)
        r.gateway.referentFailure = APIError.server(status: 404, code: .notFound, message: "No such issue")
        await model.chooseReferent(a)
        let failed = try #require(turns(r).first { $0.id == ambiguous.id })
        #expect(failed.showsStatusLine && failed.showsDeliveryLine, "오류 줄 옆에 전달 줄이 남는다")
        #expect(model.deliveryLine(for: failed)?.link?.title == "Choose an issue", "고르기 링크가 가려지지 않는다")
        // 서버가 새로 알려 준 후보: A는 지워졌다
        r.gateway.update { $0.deliveries[ambiguous.id] = AgentDelivery(state: .needsReferent, candidates: failed.delivery?.candidates.filter { $0.actionID != a } ?? []) }
        await r.chat.refreshDeliveries(Data.conversationID)
        r.gateway.referentFailure = nil
        await model.retryDelivery(try #require(turns(r).first { $0.id == ambiguous.id }))
        #expect(model.referentMenu?.candidates.map(\.actionID) == [b, c], "Try again은 지금 후보로 메뉴를 다시 연다")
        #expect(r.gateway.calls(prefix: "referent:") == ["referent:\(ambiguous.id.uuidString):\(a.uuidString)"], "낡은 선택을 다시 보내지 않았다")
        await model.chooseReferent(b)
        let picked = try #require(turns(r).first { $0.id == ambiguous.id })
        #expect(picked.delivery?.state == .sent && !picked.showsStatusLine)
        #expect(r.gateway.calls(prefix: "referent:").last == "referent:\(ambiguous.id.uuidString):\(b.uuidString)")
    }

    // MARK: 후보 고르기

    @Test func theReferentMenuOpensFromTheLinkPicksOneCandidateAndEscapeClosesItBeforeTheWindowHides() async throws {
        let r = try await rig(Data.queued())
        defer { r.defaults.cleanup(); r.manager.closeAll() }
        let model = try await open(r)
        let ambiguous = try #require(turns(r).first { $0.delivery?.state == .needsReferent })
        let link = try #require(model.deliveryLine(for: ambiguous)?.link)
        #expect(link.title == "Choose an issue", "사용자 승인 2026-10-18")
        guard case .chooseReferent(let candidates) = link.kind else {
            Issue.record("후보 링크가 아니다")
            return
        }
        #expect(candidates.count == 3)
        model.openReferentMenu(for: ambiguous.id)
        #expect(model.referentMenu?.messageID == ambiguous.id)
        let id = try #require(r.manager.controllers.keys.first)
        // Esc: 메뉴부터 닫는다 (창은 숨지 않는다), 한 번 더 누르면 창이 숨는다
        #expect(r.manager.perform(.escape, in: id))
        #expect(model.referentMenu == nil && r.manager.registry.frontmost == id, "메뉴만 닫혔다")
        model.openReferentMenu(for: ambiguous.id)
        await model.chooseReferent(Data.referentActions[1])
        #expect(r.gateway.calls(prefix: "referent:") == ["referent:\(ambiguous.id.uuidString):\(Data.referentActions[1].uuidString)"])
        #expect(model.referentMenu == nil)
        let picked = try #require(turns(r).first { $0.id == ambiguous.id })
        #expect(model.deliveryLine(for: picked)?.combined == "Sent")
        #expect(r.manager.perform(.escape, in: id) && r.manager.registry.frontmost == nil, "메뉴가 없으면 Esc는 창을 숨긴다")
    }

    // MARK: Stop

    @Test func theCircleStopsWhileTheTurnRunsAndStopRequestedShowsAtTheEndOfTheConversation() async throws {
        let r = try await rig(Data.running())
        defer { r.defaults.cleanup(); r.manager.closeAll() }
        let model = try await open(r)
        #expect(model.stopPresentation == AgentStopRules.Presentation(showsStop: true, line: nil), "열린 task: Stop 원")
        await model.stop()
        #expect(r.gateway.calls(prefix: "stopConversation") == ["stopConversation:\(Data.conversationID.uuidString)"], "Assistant 창은 대화 route")
        #expect(model.stopPresentation.line == .requested && model.stopPresentation.showsStop)
        #expect(model.stopLineText == "Stop requested · not confirmed")
        await model.stop()
        #expect(r.gateway.calls(prefix: "stopConversation").count == 1, "이미 요청했다: 다시 눌러도 보내지 않는다")
        // Stop 중에도 글을 쓰고 보낼 수 있다 (그 메시지는 대기열에 들어간다)
        model.setDraft("Also update the refund window wording")
        #expect(model.canSend)
        r.gateway.postDeliveries = [AgentDelivery(state: .queued, reason: .sessionBusy)]
        await model.send(model.draft)
        #expect(r.gateway.calls(prefix: "postAgent").count == 1)
    }

    @Test func nothingStopsWhenTheSessionIsIdleAndSendIsTheCircle() async throws {
        let r = try await rig(Data.waiting())
        defer { r.defaults.cleanup(); r.manager.closeAll() }
        let model = try await open(r)
        #expect(!model.stopPresentation.showsStop)
        await model.stop()
        #expect(r.gateway.calls(prefix: "stop").isEmpty)
    }

    @Test func mayContinueShowsTheApprovedWordAtTheEndOfTheConversation() async throws {
        let r = try await rig(Data.running())
        defer { r.defaults.cleanup(); r.manager.closeAll() }
        r.gateway.stopConfirms = true
        r.gateway.stopMayContinue = true
        let model = try await open(r)
        #expect(model.stopPresentation.showsStop, "시작: 열린 task")
        await model.stop()
        #expect(r.gateway.calls(prefix: "stopConversation").count == 1)
        #expect(r.gateway.state.sessions.tasks.first?.state == .cancelled, "서버 쪽 task가 취소됐다")
        // Stop이 끝나면 저장소가 스스로 다시 읽는다 (마지막에 시작한 읽기가 이긴다: 여기서 손으로 읽지 않고 기다린다)
        let reread = await eventually { model.sessionItem?.lastTaskState == .cancelled }
        #expect(reread, "서버가 확인한 상태를 다시 읽었다")
        #expect(model.stopPresentation == AgentStopRules.Presentation(showsStop: false, line: .mayContinue))
        #expect(model.stopLineText == "Stopped · commands may still be running", "사용자 승인 2026-10-18")
    }

    // MARK: 잘린 답 · 이벤트 줄 · auto 칩

    @Test func aCutReplyShowsViewFullOnlyWhenThisMacHasTheTextAndExpandsInPlace() async throws {
        let r = try await rig(Data.truncated())
        defer { r.defaults.cleanup(); r.manager.closeAll() }
        r.chat.fullTextLookup = { Data.fullText(forKey: $0) }
        let model = try await open(r)
        await r.chat.refresh()
        await r.chat.settle()
        let cut = try #require(turns(r).first { $0.isTruncated })
        #expect(MessageViewFull.showsLink(cut) && MessageViewFull.shownText(cut).hasSuffix("…"))
        model.viewFull(cut)
        let expanded = try #require(turns(r).first { $0.id == cut.id })
        #expect(expanded.fullText == Data.fullText && !MessageViewFull.showsLink(expanded) && Data.fullText.count > 3_000, "수천 자 전문이 그 자리에서 펼쳐진다")
        // 다른 Mac이거나 정리돼 이 Mac에 전문이 없으면 링크가 없다
        let other = try await rig(Data.truncated())
        defer { other.defaults.cleanup(); other.manager.closeAll() }
        other.chat.fullTextLookup = { _ in nil }
        _ = try await open(other)
        #expect(turns(other).filter { $0.isTruncated }.allSatisfy { !MessageViewFull.showsLink($0) })
    }

    @Test func serverEventRowsAreLinesOfTheServersWordsAndNothingElse() async throws {
        let r = try await rig(Data.events())
        defer { r.defaults.cleanup(); r.manager.closeAll() }
        _ = try await open(r)
        let events = turns(r).filter(\.isEvent).map(\.text)
        #expect(events.prefix(4) == ["Opened in Terminal", "Queued messages cancelled", "Answered", "Answered on this Mac"])
        #expect(turns(r).filter(\.isEvent).allSatisfy { !$0.isUser && $0.delivery == nil })
    }

    @Test func pressingTheAutoChipOfAnAgentConversationMakesItAddedAndTheSentChipIsAdded() async throws {
        let r = try await rig(Data.state(Data.Thread(), task: nil))
        defer { r.defaults.cleanup(); r.manager.closeAll() }
        let model = try await open(r)
        let chip = AssistantChip(kind: .action, itemID: IssueSnapshotData.issue(139), origin: .auto, title: "Rewrite pricing page copy", number: 139)
        model.followOpenItem(chip)
        let id = try #require(model.chips.chips.first?.id)
        #expect(model.chipLabel(model.chips.chips[0]).hasSuffix(" · Not sent"))
        model.promoteChip(id)
        #expect(model.chips.chips[0].origin == .added && !model.chipLabel(model.chips.chips[0]).hasSuffix(" · Not sent"))
        model.setDraft("Go")
        await model.send(model.draft)
        #expect(r.gateway.calls(prefix: "postAgent").count == 1)
    }

    // MARK: 연결 · 게이트

    @Test func theWindowGetsTheAgentSupportOnlyWhenTheConnectionKnowsTheRoutes() async throws {
        let r = try await rig(Data.running())
        defer { r.defaults.cleanup(); r.manager.closeAll() }
        let model = try await open(r)
        #expect(model.agent != nil && r.chat.agentConversation != nil && r.runtime.pillFlow != nil)
        // 읽기뿐인 연결(U2 견본)은 세션을 읽을 수는 있어도 Stop · Send again 요청이 없다
        let account = try AppChatAccount.make()
        let readOnly = ChatRuntime(gateway: IssueSampleGateway(), contextGateway: IssueSampleContextGateway(), scope: account.scope, now: { Date() }, issueScreens: true)
        #expect(readOnly.chat.agentConversation == nil && readOnly.pillFlow == nil)
        // 에이전트 route를 전혀 모르는 연결(Taskforce 견본)은 좁은 세션 읽기도 없다
        let none = ChatRuntime(gateway: SampleChatGateway(), scope: account.scope, now: { Date() }, issueScreens: false)
        #expect(none.agentTurns == nil && none.chat.agentConversation == nil && none.pillFlow == nil)
    }

    @Test func withoutTheSurfacesThereIsNoEntranceToStopSendAgainThePillOrViewFull() async throws {
        let account = try AppChatAccount.make()
        let defaults = try TestDefaults()
        defer { defaults.cleanup() }
        let gateway = AgentChatSampleGateway()
        gateway.state = Data.waiting()
        let runtime = ChatRuntime(gateway: gateway, contextGateway: IssueSampleContextGateway(), scope: account.scope, now: { Date() }, issueScreens: false)
        // Assistant 창 게이트가 꺼짐: 창 관리자가 없다 (Stop 원 · Send again · View full은 창 안에만 있다)
        let noWindows = EdgeShellController(
            launcher: LauncherModel(configurationError: "test"), chat: runtime, assistantWindows: false, positionStore: AssistantWindowPositionStore(defaults: defaults.defaults)
        )
        #expect(noWindows.assistant == nil)
        // 새 Issues 화면 게이트가 꺼짐: 세션 패널 창도 알약 동작도 없다
        #expect(noWindows.sessionPanel == nil && noWindows.shell.onSessionPill == nil && !noWindows.shell.issueScreensEnabled)
        #expect(noWindows.shell.thisMacBridgeID == nil)
        // 게이트가 켜지면 둘 다 있다
        let on = try await rig(Data.running())
        defer { on.defaults.cleanup(); on.manager.closeAll() }
        #expect(on.controller.assistant != nil && on.controller.sessionPanel != nil && on.shell.onSessionPill != nil)
    }
}
