import AppKit
import SwiftUI
import Testing
@testable import TaskforceKit
import TaskforceUI
@testable import Taskforce

/// Settings › Connections의 Your agents (OA Settings › Your agents 11장 · 14.3): 어디에 보이나 · 게이트 · 상세 이름 · 실제로 그려진 모습 (접근성 트리)
@MainActor
struct SettingsAgentsStructureTests {
    @Test func yourAgentsIsTheLastTopicOfTheConnectionsTabAndOnlyWhenSignedIn() {
        #expect(SettingsWindowTab.connections.sections(.signedIn) == [.aiProcessing, .sources, .moreServices, .yourAgents], "AI processing → Sources → More services → Your agents")
        #expect(SettingsWindowTab.connections.sections(.signedIn, macsNotice: true) == [.macsNotice, .aiProcessing, .sources, .moreServices, .yourAgents], "10대일 때만 맨 위 Notice 하나")
        for access in [SettingsWindowAccess.signedOut, .loading] {
            #expect(SettingsWindowTab.connections.sections(access, macsNotice: true) == [.signInRequired], "로그인이 아니면 에이전트 절도 Notice도 없다")
        }
        #expect(SettingsWindowSection.yourAgents.title == "Your agents" && SettingsWindowSection.macsNotice.title == nil)
    }

    @Test func yourAgentsIsNoLongerOnTheHiddenList() {
        #expect(!SettingsWindowHidden.allCases.map(\.rawValue).contains("Your agents"))
        #expect(SettingsWindowHidden.allCases.allSatisfy { !$0.reason.contains("D4: 에이전트 adapter gate") })
    }

    @Test func theNoticeHasNoTitleSoItIsNotATrayAndComesFirst() {
        let sections = SettingsWindowTab.connections.sections(.signedIn, macsNotice: true)
        #expect(sections.first == .macsNotice && sections.filter { $0 == .macsNotice }.count == 1, "탭 맨 위에 Notice는 하나까지")
    }

    @Test func theAgentAndMacsDetailsBelongToTheConnectionsTabWithTheirOwnTitles() {
        #expect(SettingsWindowDetail.agent.title == "Claude Code" && SettingsWindowDetail.macs.title == "Macs")
        #expect(SettingsWindowDetail.agent.tab == .connections && SettingsWindowDetail.macs.tab == .connections)
        #expect(SettingsWindowDetail.agent.backTitle(tab: .connections) == "Connections" && SettingsWindowDetail.macs.backTitle(tab: .connections) == "Connections")
        let window = SettingsWindowModel()
        window.open(.agent)
        #expect(window.title(on: .connections) == "Claude Code" && window.title(on: .account) == "Account", "다른 탭의 상세는 보이지 않는다")
        window.open(.macs)
        #expect(window.title(on: .connections) == "Macs")
        window.back()
        #expect(window.detail == nil)
    }

    @Test func theMoreCardsConnectionsEntryLandsOnTheTabThatShowsYourAgents() {
        // 더 보기 카드 "Connections"는 `SettingsOpener.open(.connections)`: 그 저장값은 Connections 탭이다
        #expect(SettingsWindowTab.tab(stored: MacSettingsTab.connections.rawValue) == .connections)
        #expect(SettingsWindowTab.connections.sections(.signedIn).contains(.yourAgents))
    }

    @Test func releaseStillShowsTheOldSettingsWindowSoTheNewSectionNeverReachesIt() {
        #expect(EdgeSurfaces.release.settingsWindow == false)
        #expect(MacSettingsRootKind(surfaces: .release) == .legacy, "Release는 옛 창 그대로: Your agents 절이 없다")
    }

    @Test func theLiveEnvironmentIsNotAttachedOverAFakeAndNotWithoutAChatRuntime() {
        let window = SettingsWindowModel()
        window.attachAgentEnvironment(services: nil)
        #expect(window.agents.environment == nil, "대화 상태가 없으면(플래그 꺼짐) 붙이지 않는다: 이 빌드는 못 띄운다")
        let fake = FakeAgentSettingsEnvironment()
        window.agents.attach(fake)
        window.attachAgentEnvironment(services: nil)
        #expect(window.agents.environment === fake)
    }

    @Test func switchingAccountsClearsAnOpenAgentDetailAndTheModel() async {
        let env = FakeAgentSettingsEnvironment()
        env.targetsRead = env.serverRow(state: .ready)
        let window = SettingsWindowModel()
        window.agents.attach(env)
        await window.agents.refresh(.shown)
        window.open(.agent)
        window.confirming = .disconnectAgent
        window.agents.accountLeft()
        #expect(window.agents.line.kind == .checking)
    }
}

/// 실제로 그려진 모습: 오프스크린 창에 붙여 본다 (실제 포인터 · 키보드 · VoiceOver 확인이 아니다). SwiftUI의 접근성 트리는 보조 기술이 묻기 전에는 AppKit에서 읽히지 않는다 —
/// 접근성 이름은 부품의 순수 규칙(`AgentSettingsComponentsTests`)이 고정하고, 여기서는 절 · 상세가 보일 때 읽는지 · 폭 안에 그려지는지 본다
@MainActor
@Suite(.serialized)
struct SettingsAgentsRenderedTests {
    private func show<V: View>(_ view: V, height: CGFloat = 700) async -> (NSWindow, CGSize) {
        let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 560, height: height), styleMask: [.borderless], backing: .buffered, defer: false)
        let host = NSHostingView(rootView: view.frame(width: 520))
        window.contentView = host
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
        window.makeKeyAndOrderFront(nil)
        try? await Task.sleep(for: .milliseconds(250))
        host.layoutSubtreeIfNeeded()
        return (window, host.fittingSize)
    }

    private func withModel(_ env: FakeAgentSettingsEnvironment, body: () async -> Void) async {
        let model = SettingsWindowModel.shared
        model.agents.replaceEnvironment(env)
        model.close()
        await body()
        model.agents.replaceEnvironment(nil)
        model.close()
    }

    @Test func theSectionReadsOnceWhenItAppearsAndFitsTheWindow() async {
        let env = FakeAgentSettingsEnvironment()
        env.targetsRead = .rows([])
        await withModel(env) {
            let (window, size) = await show(SettingsYourAgentsSection())
            defer { window.orderOut(nil) }
            #expect(env.refreshProbeCalls == 1 && env.targetCalls == 1, "절이 보일 때 새로 고친다 (SA-06)")
            #expect(size.width <= 520 && size.height > 40, "연결 전: 줄 + 각주")
            #expect(SettingsWindowModel.shared.agents.line.kind == .connect)
        }
    }

    @Test func theDetailReadsWhenItAppearsAndDrawsEveryStateInsideTheWidth() async {
        let project = AgentFolderProject(id: UUID(), name: String(repeating: "Northwind Traders 2026 website relaunch ", count: 4), icon: .briefcase)
        var states: [(String, FakeAgentSettingsEnvironment)] = []
        let ready = FakeAgentSettingsEnvironment()
        ready.targetsRead = ready.serverRow(state: .unsupported)
        ready.name = String(repeating: "M", count: 64)
        ready.projectsRead = [project.id: project]
        ready.store?.registerFolders([project.id: "/Users/alex/" + String(repeating: "deep/", count: 30) + "leaf"])
        states.append(("ready", ready))
        let revoked = FakeAgentSettingsEnvironment()
        revoked.runtimeStatus = .revoked
        revoked.targetsRead = .rows([])
        states.append(("revoked", revoked))
        let blocked = FakeAgentSettingsEnvironment()
        blocked.canRunAgents = false
        blocked.report = nil
        states.append(("blocked", blocked))
        for (label, env) in states {
            await withModel(env) {
                SettingsWindowModel.shared.open(.agent)
                let (window, size) = await show(SettingsAgentDetail())
                defer { window.orderOut(nil) }
                #expect(env.refreshProbeCalls == (env.canRunAgents ? 1 : 0), "\(label): 상세가 보일 때 읽는다 (이 빌드가 못 띄우면 읽지 않는다)")
                #expect(size.width <= 520 && size.height > 100, "\(label): 폭 안에 그려진다 \(size)")
            }
        }
    }

    /// 오른쪽 40% 구역에 글자(배경과 다른 픽셀)가 그려졌는가: 경로 Value가 폭 계산에 밀려 사라지는 일을 막는다 (토큰 색 자산이 컴파일된 앱 호스트에서만 의미가 있다)
    private func inkInRightPart<V: View>(of view: V, width: CGFloat = 520, height: CGFloat = 44) async -> Int {
        let host = NSHostingView(rootView: view.frame(width: width, height: height).background(Color.white))
        host.appearance = NSAppearance(named: .aqua)
        let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: width, height: height), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        try? await Task.sleep(for: .milliseconds(150))
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return -1 }
        host.cacheDisplay(in: host.bounds, to: rep)
        var ink = 0
        for y in 0..<rep.pixelsHigh {
            for x in Int(Double(rep.pixelsWide) * 0.6)..<rep.pixelsWide {
                guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                if color.redComponent < 0.8 || color.greenComponent < 0.8 || color.blueComponent < 0.8 { ink += 1 }
            }
        }
        return ink
    }

    @Test func theFolderPathValueIsActuallyDrawnOnTheRightOfTheRow() async {
        let project = AgentFolderProject(id: UUID(), name: "Acme website", icon: .briefcase)
        let lines = AgentSettingsFolders.lines(folders: [project.id: "/Users/alex/Projects/acme-site"], projects: [project.id: project], homes: ["/Users/alex"], exists: { _ in true }).lines
        #expect(await inkInRightPart(of: AgentFolderRow(line: lines[0])) > 20, "경로 Value가 그려진다")
        #expect(await inkInRightPart(of: AgentFolderRow(line: lines[1])) > 20, "Ungrouped의 Ask each time도 그려진다")
        let longName = AgentFolderProject(id: UUID(), name: String(repeating: "Northwind Traders 2026 website relaunch ", count: 4), icon: .briefcase)
        let long = AgentSettingsFolders.lines(folders: [longName.id: "/Users/alex/Documents/Northwind/site"], projects: [longName.id: longName], homes: ["/Users/alex"], exists: { _ in true }).lines
        #expect(await inkInRightPart(of: AgentFolderRow(line: long[0]), height: 90) > 20, "이름이 길어도 경로가 남는 폭으로 보인다")
    }

    @Test func theMacsDetailReadsTheListWhenItAppears() async {
        let env = FakeAgentSettingsEnvironment()
        env.runtimeStatus = .tooManyBridges
        env.targetsRead = .rows([])
        env.macsRead = [AgentMacRecord(id: UUID(), deviceName: "Studio", lastHeartbeatAt: Date(timeIntervalSince1970: 1_700_000_000))]
        await withModel(env) {
            SettingsWindowModel.shared.open(.macs)
            let (window, _) = await show(SettingsMacsDetail())
            defer { window.orderOut(nil) }
            #expect(env.macsCalls == 1 && SettingsWindowModel.shared.agents.macs.count == 1)
            // 목록은 읽은 뒤에 그려진다: 한 번 더 기다려 잰다
            try? await Task.sleep(for: .milliseconds(250))
            window.contentView?.layoutSubtreeIfNeeded()
            let size = window.contentView?.fittingSize ?? .zero
            // 제목 없는 트레이는 앞 것에 12 붙는다 (`SettingsTray.followOnGap`): 행 하나(48)에서 12를 뺀 36
            #expect(size.width <= 520 && size.height >= 36, "행 하나 이상 \(size)")
        }
    }
}
