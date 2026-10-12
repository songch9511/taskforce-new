import Carbon.HIToolbox
import Foundation
import Testing
@testable import Taskforce
@testable import TaskforceKit
@testable import TaskforceUI

/// Release 표면 gate (R1 Mac): Release는 **Edge 셸 + All work + S4 Review + C3 ReturnSummary**만 켠다. Chats(B3) 런타임 · 레일 Chats 칸 · ⌘3 · ⌘N · 연결 복귀 읽기 · 프로젝트 묶음(S3b) · 기억 · 0.2.0 설정 창은 꺼져 있다
/// (Release 설정은 구 `MacSettingsView`: Plan & usage · billing 그대로). DEBUG 인자 동작은 그대로다.
/// 한계: Release 쪽 분기는 `EdgeSurfaces.current`의 `#else` 한 줄이라 Debug 시험 호스트는 그 줄을 실행하지 못한다 — `EdgeSurfaces.release` 값 시험 + Release 빌드 + 리뷰로 확인한다.
@MainActor
struct ReleaseSurfacesTests {
    /// Release 표면에서 Chats만 켠 변형 (양성 대조군: 같은 가짜 네트워크가 Chats가 켜지면 요청을 실제로 본다)
    static var releaseWithChats: EdgeSurfaces {
        var surfaces = EdgeSurfaces.release
        surfaces.chats = true
        return surfaces
    }

    // MARK: 표면 값

    @Test func theReleaseSetIsTheShellAllWorkReviewAndTheSummaryOnly() {
        let release = EdgeSurfaces.release
        #expect(release.shell && release.review && release.summary)
        #expect(!release.chats && !release.projects && !release.settingsWindow)
    }

    /// DEBUG 인자 조합표: 지금 동작 그대로 (`-TF_EDGE_SHELL`은 셸 + Chats + 0.2.0 설정 창, 나머지는 각자의 축)
    @Test func debugArgumentsKeepTheirCurrentMeaning() throws {
        func surfaces(_ keys: [String]) throws -> EdgeSurfaces {
            let store = try TestDefaults()
            defer { store.cleanup() }
            for key in keys { store.defaults.set(true, forKey: key) }
            return EdgeSurfaces.debug(store.defaults)
        }
        #expect(try surfaces([]) == EdgeSurfaces(shell: false, review: false, summary: false, chats: false, projects: false, settingsWindow: false))
        #expect(try surfaces([EdgeShellFlag.key]) == EdgeSurfaces(shell: true, review: false, summary: false, chats: true, projects: false, settingsWindow: true))
        #expect(try surfaces([S4Flag.key]) == EdgeSurfaces(shell: false, review: true, summary: false, chats: false, projects: false, settingsWindow: false))
        #expect(try surfaces([C3Flag.key]) == EdgeSurfaces(shell: false, review: false, summary: true, chats: false, projects: false, settingsWindow: false))
        #expect(try surfaces([S3bFlag.key]) == EdgeSurfaces(shell: false, review: false, summary: false, chats: false, projects: true, settingsWindow: false))
        #expect(try surfaces([EdgeShellFlag.key, S4Flag.key, C3Flag.key, S3bFlag.key]) == EdgeSurfaces(shell: true, review: true, summary: true, chats: true, projects: true, settingsWindow: true))
    }

    @Test func theReleaseSurfacesArgumentReproducesTheReleaseSetWhateverElseIsGiven() throws {
        let store = try TestDefaults()
        defer { store.cleanup() }
        store.defaults.set(true, forKey: EdgeSurfaces.releaseKey)
        #expect(EdgeSurfaces.debug(store.defaults) == .release, "다른 인자 없이도")
        for key in [EdgeShellFlag.key, S4Flag.key, C3Flag.key, S3bFlag.key] { store.defaults.set(true, forKey: key) }
        #expect(EdgeSurfaces.debug(store.defaults) == .release, "다른 인자가 모두 켜져 있어도 Chats · 프로젝트 · 0.2.0 설정 창은 꺼진다")
        #expect(EdgeSurfaces.releaseKey == "TF_RELEASE_SURFACES")
    }

    @Test func theFlagEnumsFollowTheSurfacesWithTheirOldSignatures() throws {
        let store = try TestDefaults()
        defer { store.cleanup() }
        #expect(!EdgeShellFlag.isEnabled(store.defaults) && !ChatsFlag.isEnabled(store.defaults) && !SettingsWindowFlag.isEnabled(store.defaults))
        store.defaults.set(true, forKey: EdgeShellFlag.key)
        #expect(EdgeShellFlag.isEnabled(store.defaults) && ChatsFlag.isEnabled(store.defaults) && SettingsWindowFlag.isEnabled(store.defaults), "DEBUG: Chats · 설정 창은 지금처럼 셸을 따른다")
        #expect(!S4Flag.isEnabled(store.defaults) && !C3Flag.isEnabled(store.defaults) && !S3bFlag.isEnabled(store.defaults))
        store.defaults.set(true, forKey: EdgeSurfaces.releaseKey)
        #expect(EdgeShellFlag.isEnabled(store.defaults) && S4Flag.isEnabled(store.defaults) && C3Flag.isEnabled(store.defaults))
        #expect(!ChatsFlag.isEnabled(store.defaults) && !SettingsWindowFlag.isEnabled(store.defaults) && !S3bFlag.isEnabled(store.defaults))
    }

    /// 시험 호스트에는 인자가 없다: 이 빌드의 표면은 모두 꺼짐 (Debug 기본)
    @Test func theTestHostHasNoArgumentsSoNothingIsOn() {
        #expect(EdgeSurfaces.current == EdgeSurfaces.debug())
        #expect(EdgeSurfaces.current == EdgeSurfaces(shell: false, review: false, summary: false, chats: false, projects: false, settingsWindow: false))
    }

    // MARK: 설정 창

    @Test func theReleaseSurfacesKeepTheLegacySettingsWindow() {
        #expect(MacSettingsRootKind(surfaces: .release) == .legacy, "billing이 있는 구 창")
        #expect(MacSettingsRootKind(surfaces: EdgeSurfaces.debug()) == .legacy)
        #expect(MacSettingsRootKind(surfaces: EdgeSurfaces(shell: true, review: false, summary: false, chats: true, projects: false, settingsWindow: true)) == .window)
        #expect(MacSettingsRootKind.current == .legacy)
    }

    // MARK: 실제 생성 경로 (Edge 기초)

    private func foundation(
        _ surfaces: EdgeSurfaces, account: AppChatAccount, services: AppServices, connectivity: AsyncStream<Bool>? = nil
    ) -> (foundation: AppRuntime.EdgeFoundation, chatCalls: Int, scopeCalls: Int) {
        var chatCalls = 0
        var scopeCalls = 0
        let made = AppRuntime.makeEdgeFoundation(
            surfaces: surfaces,
            makeChat: {
                chatCalls += 1
                return AppRuntime.makeChatRuntime(session: account.session, services: services, sample: false, s3b: surfaces.projects, connectivity: connectivity)
            },
            makeScope: {
                scopeCalls += 1
                return AppRuntime.makeEdgeScope(session: account.session, sample: false)
            }
        )
        return (made, chatCalls, scopeCalls)
    }

    @Test func releaseMakesNoChatsRuntimeButGivesS4AndC3TheirOwnAccountScope() throws {
        let account = try AppChatAccount.make()
        let made = foundation(.release, account: account, services: S3bGateTests.services().services)
        #expect(made.chatCalls == 0, "makeChatRuntime을 부르지 않는다")
        #expect(made.foundation.chat == nil)
        #expect(made.scopeCalls == 1)
        let scope = try #require(made.foundation.scope, "Chats가 없어도 S4 · C3의 계정 경계가 있다")
        #expect(scope.token?.userID == AppChatAccount.userID, "세션에 붙어 지금 계정을 안다")
    }

    @Test func aShellThatIsOffMakesNothing() throws {
        let account = try AppChatAccount.make()
        let off = EdgeSurfaces.debug()
        let made = foundation(off, account: account, services: S3bGateTests.services().services)
        #expect(made.chatCalls == 0 && made.scopeCalls == 0 && made.foundation.chat == nil && made.foundation.scope == nil)
        // 셸이 꺼져 있으면 S4 · C3 표면 값이 켜져 있어도 만들지 않는다
        var only = EdgeSurfaces.release
        only.shell = false
        let silent = foundation(only, account: account, services: S3bGateTests.services().services)
        #expect(silent.chatCalls == 0 && silent.scopeCalls == 0 && silent.foundation.scope == nil)
    }

    @Test func chatsOnUsesTheChatsRuntimeScopeLikeToday() throws {
        let account = try AppChatAccount.make()
        let made = foundation(Self.releaseWithChats, account: account, services: S3bGateTests.services().services)
        #expect(made.chatCalls == 1 && made.scopeCalls == 0)
        #expect(made.foundation.chat != nil && made.foundation.scope === made.foundation.chat?.scope, "DEBUG(Chats 켬)의 지금 경로 그대로")
    }

    @Test func releaseConnectsS4AndTheSummaryOnTheEdgeScopeAndNothingElse() async throws {
        let account = try AppChatAccount.make()
        let harness = try await ReviewHarness.make(reviews: 1, open: 1)
        let made = foundation(.release, account: account, services: S3bGateTests.services().services)
        let features = AppRuntime.makeEdgeFeatures(
            surfaces: .release, foundation: made.foundation, now: harness.store, makeGateway: { LiveReturnSummaryGateway(services: harness.services) }
        )
        #expect(features.review != nil && features.summary != nil, "Chats 런타임 없이도 S4 · C3가 만들어진다")
        // 꺼진 표면은 만들지 않는다
        var withoutSummary = EdgeSurfaces.release
        withoutSummary.summary = false
        var gatewayCalls = 0
        let none = AppRuntime.makeEdgeFeatures(surfaces: withoutSummary, foundation: made.foundation, now: harness.store, makeGateway: { gatewayCalls += 1; return nil })
        #expect(none.review != nil && none.summary == nil && gatewayCalls == 0)
        var shellOff = EdgeSurfaces.release
        shellOff.shell = false
        let silent = AppRuntime.makeEdgeFeatures(surfaces: shellOff, foundation: made.foundation, now: harness.store, makeGateway: { gatewayCalls += 1; return nil })
        #expect(silent.review == nil && silent.summary == nil && gatewayCalls == 0)
    }

    // MARK: 요청 0 (off 표면은 런타임도 요청도 만들지 않는다)

    /// 짧게 기다렸다 부르지 않은 것을 확인한다 (양보만 한다)
    private func quiet() async {
        for _ in 0..<60 { await Task.yield() }
        try? await Task.sleep(for: .milliseconds(80))
    }

    private func isChatsRequest(_ path: String) -> Bool {
        path.contains("/conversations") || path.contains("/memory") || path.contains("/context_members") || path.contains("/work_contexts") || path.contains("/contexts/")
    }

    @Test func releaseNeverMakesConversationMemoryOrMembershipRequestsThroughAnyChatsEntry() async throws {
        let account = try AppChatAccount.make()
        let (services, host) = S3bGateTests.services()
        let (stream, continuation) = AsyncStream<Bool>.makeStream()
        let made = foundation(.release, account: account, services: services, connectivity: stream)
        #expect(made.chatCalls == 0 && made.foundation.chat == nil)
        // 셸은 Chats 없이 만들어진다 (컨트롤러가 `chat != nil`로 정한다)
        let shell = EdgeShellModel(schedule: { _, _ in EdgeTimer() }, chatsEnabled: made.foundation.chat != nil)
        // 모든 Chats 진입: 레일 Chats 칸 · ⌘3 · ⌘N · 마지막 화면 열기 · 패널로 직접
        shell.openChats()
        shell.newChat()
        shell.openPanel(.chats)
        shell.togglePanel()
        shell.togglePanel()
        #expect(shell.view == .allWork, "어느 길로도 Chats 화면이 열리지 않는다")
        // 연결이 끊겼다 돌아온다 (Chats 런타임이 있었다면 대화 목록을 다시 읽는 신호)
        continuation.yield(false)
        continuation.yield(true)
        await quiet()
        continuation.finish()
        let paths = S3bStubProtocol.paths(host: host)
        #expect(paths.isEmpty, "요청 0: \(paths)")
        #expect(!paths.contains(where: isChatsRequest))
    }

    /// 양성 대조군: 같은 가짜 네트워크 · 같은 신호가 Chats가 켜지면 실제로 요청을 만든다 — 위의 0이 의미가 있다
    @Test func theSameStubSeesConversationRequestsWhenChatsIsOnOpeningAndOnReconnect() async throws {
        let account = try AppChatAccount.make()
        let (services, host) = S3bGateTests.services()
        let (stream, continuation) = AsyncStream<Bool>.makeStream()
        let made = foundation(Self.releaseWithChats, account: account, services: services, connectivity: stream)
        let chat = try #require(made.foundation.chat)
        let shell = EdgeShellModel(schedule: { _, _ in EdgeTimer() }, chatsEnabled: true)
        shell.onChatsOpened = { chat.chat.openChats() }
        shell.openChats()
        await chat.chat.settle()
        let opened = S3bStubProtocol.paths(host: host).filter(isChatsRequest).count
        #expect(opened >= 1, "Chats를 열면 대화 목록을 읽는다")
        continuation.yield(false)
        continuation.yield(true)
        for _ in 0..<400 where S3bStubProtocol.paths(host: host).filter(isChatsRequest).count <= opened {
            try? await Task.sleep(for: .milliseconds(10))
        }
        continuation.finish()
        #expect(S3bStubProtocol.paths(host: host).filter(isChatsRequest).count > opened, "연결이 돌아오면 열지 않아도 다시 읽는다 — Release에는 이 follower가 없다")
    }
}

/// Chats가 없는 셸 (Release): 레일 고정 칸은 둘, Chats 진입 · 키는 아무것도 하지 않는다
@MainActor
struct EdgeShellWithoutChatsTests {
    func shell(chats: Bool) -> EdgeShellModel {
        EdgeShellModel(schedule: { _, _ in EdgeTimer() }, chatsEnabled: chats)
    }

    @Test func theRailHasTwoFixedControlsWithoutChats() {
        #expect(shell(chats: false).controls == [.allWork, .more])
        #expect(shell(chats: false).controls.map(\.label) == ["All work", "More"])
        #expect(shell(chats: true).controls == [.allWork, .chats, .more], "Chats가 있으면 지금 그대로")
        #expect(EdgeShellModel(schedule: { _, _ in EdgeTimer() }).chatsEnabled, "기본은 지금 그대로(켜짐)")
    }

    @Test func everyChatsEntryDoesNothingAndCallsNothing() {
        let model = shell(chats: false)
        var opened = 0, newChats = 0
        model.onChatsOpened = { opened += 1 }
        model.onNewChat = { newChats += 1 }
        model.openChats()
        #expect(!model.panelOpen && model.view == .allWork && opened == 0, "닫힌 패널은 Chats로 열리지 않는다")
        model.newChat()
        #expect(!model.panelOpen && model.view == .allWork && newChats == 0 && opened == 0)
        model.openPanel(.chats)
        #expect(!model.panelOpen && model.view == .allWork)
        model.openAllWork()
        #expect(model.panelOpen && model.view == .allWork)
        model.openChats()
        model.newChat()
        #expect(model.panelOpen && model.view == .allWork && opened == 0 && newChats == 0, "All work가 열려 있어도 그대로")
        model.dismiss()
        model.togglePanel()
        #expect(model.panelOpen && model.view == .allWork, "⌥ Space는 마지막 화면(All work)을 연다")
    }

    // MARK: 실제 컨트롤러의 키 (`handleKey`)

    /// Release 표면: Chats 런타임이 없는 컨트롤러 — ⌘3 · ⌘N은 연결이 없어 지나가고(false) 화면도 바뀌지 않는다. ⌘2 · Esc는 그대로
    @Test func theRealControllerPassesCommandThreeAndNThroughWhenThereIsNoChatsRuntime() {
        let controller = EdgeShellController(launcher: LauncherModel(configurationError: "test"), chat: nil)
        #expect(!controller.shell.chatsEnabled && controller.shell.controls == [.allWork, .more])
        #expect(controller.handleKey(EdgeReviewTests.key("2", code: kVK_ANSI_2, flags: .command)) && controller.shell.view == .allWork && controller.shell.panelOpen)
        #expect(!controller.handleKey(EdgeReviewTests.key("3", code: kVK_ANSI_3, flags: .command)), "⌘3은 먹지 않는다")
        #expect(!controller.handleKey(EdgeReviewTests.key("n", code: kVK_ANSI_N, flags: .command)), "⌘N도 먹지 않는다")
        #expect(controller.shell.view == .allWork && controller.shell.panelOpen, "화면은 그대로")
        #expect(controller.handleKey(EdgeReviewTests.key("\u{1B}", code: kVK_Escape)) && !controller.shell.panelOpen)
    }

    /// DEBUG에서 셸이 켜진 지금의 구성(Chats 런타임이 있다): ⌘3 · ⌘N은 지금처럼 Chats로 간다
    @Test func theRealControllerStillSendsCommandThreeAndNToChatsWhenThereIsAChatsRuntime() {
        let controller = EdgeReviewTests.controller(review: nil)
        #expect(controller.shell.chatsEnabled && controller.shell.controls == [.allWork, .chats, .more])
        #expect(controller.handleKey(EdgeReviewTests.key("3", code: kVK_ANSI_3, flags: .command)) && controller.shell.view == .chats)
        #expect(controller.handleKey(EdgeReviewTests.key("2", code: kVK_ANSI_2, flags: .command)) && controller.shell.view == .allWork)
        #expect(controller.handleKey(EdgeReviewTests.key("n", code: kVK_ANSI_N, flags: .command)) && controller.shell.view == .chats)
    }

    @Test func chatsStillOpensWhenTheShellHasIt() {
        let model = shell(chats: true)
        var opened = 0
        model.onChatsOpened = { opened += 1 }
        model.openChats()
        #expect(model.panelOpen && model.view == .chats && opened == 1)
    }

    @Test func commandKeysThreeAndNArePassedThroughWithoutChats() {
        let without = shell(chats: false)
        #expect(!without.listens(to: .chats) && !without.listens(to: .newChat), "먹지 않는다")
        #expect(without.listens(to: .escape) && without.listens(to: .allWork) && without.listens(to: .review))
        let with = shell(chats: true)
        #expect(with.listens(to: .chats) && with.listens(to: .newChat))
    }

    // MARK: 레일 배치

    @Test func theLayoutFollowsTheControlCount() {
        let three = EdgeRailLayout(notchCount: 2, restCount: 1, expanded: true, idle: false)
        let two = EdgeRailLayout(notchCount: 2, restCount: 1, expanded: true, idle: false, controls: [.allWork, .more])
        #expect(three.controls == EdgeShellModel.Control.allCases, "기본은 지금 그대로")
        #expect(two.controlFrame(.allWork) == three.controlFrame(.allWork), "첫 칸 자리는 같다")
        #expect(two.controlFrame(.more).minY == three.controlFrame(.chats).minY, "More가 Chats 자리로 올라온다")
        #expect(two.moreHeight == three.moreHeight - (EdgeRailLayout.item + EdgeRailLayout.gap), "칸 하나만큼 짧다")
        #expect(two.railRect.height == three.railRect.height - (EdgeRailLayout.item + EdgeRailLayout.gap))
        #expect(two.railRect.maxY <= EdgeRailLayout.windowHeight, "창 안에 들어간다")
    }

    @Test func thePointerHitTestOnlyKnowsTheShownControls() {
        let two = EdgeRailLayout(notchCount: 0, restCount: 0, expanded: true, idle: false, controls: [.allWork, .more])
        let three = EdgeRailLayout(notchCount: 0, restCount: 0, expanded: true, idle: false)
        let moreCenter = CGPoint(x: two.controlFrame(.more).midX, y: two.controlFrame(.more).midY)
        #expect(two.hit(moreCenter, slots: []).control == .more)
        // 예전 Chats 자리의 한가운데는 이제 More다 (Chats가 아니다)
        let oldChatsCenter = CGPoint(x: three.controlFrame(.chats).midX, y: three.controlFrame(.chats).midY)
        #expect(two.hit(oldChatsCenter, slots: []).control == .more)
        #expect(three.hit(oldChatsCenter, slots: []).control == .chats, "Chats가 있으면 지금 그대로")
        // 두 칸 아래는 레일 밖이다
        let below = CGPoint(x: two.controlFrame(.more).midX, y: two.controlFrame(.more).maxY + EdgeRailLayout.item)
        #expect(two.hit(below, slots: []).control == nil)
        #expect(EdgeRailLayout.windowHeight >= two.railRect.maxY)
    }
}
