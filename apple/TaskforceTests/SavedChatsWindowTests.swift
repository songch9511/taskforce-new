import AppKit
import Carbon.HIToolbox
import Foundation
import Testing
@testable import Taskforce
@testable import TaskforceKit
@testable import TaskforceUI

/// 저장된 대화 읽기 패널 창 (OA D3v-m): 컨트롤러가 저장소가 있을 때만 창을 만들고, Sessions 왼쪽 40 · 위 맞춤에 세우고, Esc · 접기를 따라가고, 설정 창이 같은 저장소를 읽게 이어 준다.
/// 실제 서버 · Claude 기록에 닿지 않는다 (가짜 닫힘)
@MainActor
struct SavedChatsWindowTests {
    typealias X = EdgeExternalSessionsTests
    typealias M = SavedChatsMacTests

    @MainActor
    struct Windows {
        let controller: EdgeShellController
        let backend: M.Backend
        let saved: SavedChatsStore?
        var shell: EdgeShellModel { controller.shell }
    }

    /// 컨트롤러만 (기다림 없이): 설정 창 모델에 저장소를 올리는 일은 만들 때 한다
    private func makeController(withStore: Bool) throws -> (controller: EdgeShellController, backend: M.Backend, saved: SavedChatsStore?, list: ExternalSessionsStore) {
        let account = try AppChatAccount.make()
        let runtime = ChatRuntime(gateway: IssueSampleGateway(), contextGateway: IssueSampleContextGateway(), scope: account.scope, now: { Date() }, issueScreens: true)
        let counter = X.Counter()
        let list = ExternalSessionsStore(scope: account.scope, scan: { counter.scan() }, seen: InMemoryExternalSessionSeenStore(Date(timeIntervalSinceNow: -10_000)), pollInterval: 3600)
        let backend = M.Backend(pages: [(1...3).map { M.row($0) }])
        backend.setMessages([M.message(1, role: "user", body: "first"), M.message(2, role: "assistant", body: "second")], for: M.id(1))
        let saved = withStore ? M.store(backend, scope: account.scope) : nil
        let controller = EdgeShellController(
            launcher: LauncherModel(configurationError: "test"), chat: runtime, assistantWindows: false, injectedExternalSessions: list, injectedSavedChats: saved
        )
        return (controller, backend, saved, list)
    }

    private func windows(withStore: Bool = true) async throws -> Windows {
        let (controller, backend, saved, list) = try makeController(withStore: withStore)
        controller.ignoresExternalDismissal = false
        // 다른 시험이 만든 키 창이 이 패널의 "키를 잃음"을 부를 수 있다: 키 창은 늘 이 컨트롤러의 창이라고 답한다 (`EdgeSessionsTests.windows`와 같다)
        controller.keyWindow = { [weak controller] in
            guard let controller else { return nil }
            return controller.savedChatPanel?.isVisible == true ? controller.savedChatPanel?.panel : controller.panel.panel
        }
        controller.shell.accountChanged(SampleData.userID)
        await list.refresh()
        await saved?.refresh()
        controller.followPanel()
        controller.followSavedChatPanel()
        return Windows(controller: controller, backend: backend, saved: saved)
    }

    @Test func theWindowExistsOnlyWithAStoreAndTheSettingsWindowReadsTheSameStore() throws {
        // 기다림 없이 이어서 확인한다: 다른 시험이 만드는 컨트롤러가 설정 창 모델의 저장소를 그 사이에 바꾸지 못한다
        let with = try makeController(withStore: true)
        #expect(with.controller.savedChatPanel != nil && with.controller.shell.savedChats === with.saved)
        #expect(SettingsWindowModel.shared.savedChats === with.saved, "Settings › Account의 Saved chats가 같은 저장소를 읽고 지운다")
        let without = try makeController(withStore: false)
        #expect(without.controller.savedChatPanel == nil && without.controller.shell.savedChats == nil, "목록 게이트가 꺼진 셸은 창이 없다")
        #expect(SettingsWindowModel.shared.savedChats == nil, "저장소가 없는 셸이 만들어지면 설정 창도 절이 없다")
    }

    @Test func theWindowStandsFortyLeftOfSessionsTopAlignedAndFollowsTheShell() async throws {
        _ = try #require(EdgeRailPanelController.screen, "화면이 있어야 창 자리를 잰다")
        let w = try await windows()
        defer {
            w.shell.dismiss()
            w.controller.followPanel()
        }
        let window = try #require(w.controller.savedChatPanel)
        w.shell.openSessions()
        #expect(await X().until { w.controller.panel.isVisible && w.controller.panel.targetFrame() != nil })
        #expect(!window.isVisible, "대화를 열기 전에는 창이 없다")
        w.shell.openSavedChat(M.id(1))
        #expect(await X().until { window.isVisible && window.presentation.shown })
        let main = try #require(w.controller.panel.targetFrame())
        #expect(await X().until { abs(window.panel.frame.maxX - (main.minX - 40)) < 1 && abs(window.panel.frame.maxY - main.maxY) < 1 }, "Sessions 왼쪽 40, 위 맞춤")
        #expect(window.panel.frame.width == EdgePanelMetrics.width && (EdgePanelMetrics.minHeight...EdgePanelMetrics.maxHeight).contains(window.height()))
        // Esc: 읽기 패널만 접힌다 (Sessions는 남는다)
        _ = try #require(w.controller.handleKeyForTest(code: kVK_Escape, flags: []))
        #expect(await X().until { !window.presentation.shown })
        #expect(w.shell.panelOpen && w.controller.panel.isVisible && w.shell.savedChatPanelID == nil)
        // 다시 열고 패널을 접으면 함께 내려간다
        w.shell.openSavedChat(M.id(1))
        #expect(await X().until { window.presentation.shown })
        w.shell.dismiss()
        w.controller.followPanel()
        #expect(await X().until { !window.presentation.shown && !w.controller.hasMonitors })
    }

    @Test func clickingTheSavedChatWindowIsNotAnOutsideClickSoSessionsStaysOpen() async throws {
        _ = try #require(EdgeRailPanelController.screen, "화면이 있어야 창 자리를 잰다")
        let w = try await windows()
        defer {
            w.shell.dismiss()
            w.controller.followPanel()
        }
        let window = try #require(w.controller.savedChatPanel)
        w.shell.openSessions()
        #expect(await X().until { w.controller.panel.isVisible })
        w.shell.openSavedChat(M.id(1))
        #expect(await X().until { window.isVisible })
        // 이 창이 키가 되면(눌렀다): 키를 잃은 메인 패널이 Sessions 전체를 접지 않는다
        w.controller.windowDidResignKey(Notification(name: NSWindow.didResignKeyNotification, object: w.controller.panel.panel))
        try? await Task.sleep(for: .milliseconds(100))
        #expect(w.shell.panelOpen && w.shell.savedChatPanelID == M.id(1), "읽기 패널 창을 눌러도 Sessions가 접히지 않는다")
    }
}
