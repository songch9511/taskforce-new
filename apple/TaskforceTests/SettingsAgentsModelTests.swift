import Foundation
import Testing
@testable import TaskforceKit
@testable import Taskforce

/// Settings › Your agents의 모델 (OA Settings › Your agents 6 · 7 · 8 · 9장 · 14.3): 읽기 · 새로 고침 10초 · Connect · Reconnect · Disconnect · 10대 · 폴더 · 계정 경계.
/// 가짜 면만 쓴다: 실제 `claude` · 폴더 창 · Keychain · 알림 센터 · 서버 0
@MainActor
struct SettingsAgentsModelTests {
    typealias Env = FakeAgentSettingsEnvironment

    static func model(_ env: Env, now: HostBox<Date>? = nil) -> AgentSettingsModel {
        let clock = now ?? HostBox(Date(timeIntervalSince1970: 1_800_000_000))
        let model = AgentSettingsModel(now: { clock.value })
        model.attach(env)
        return model
    }

    static func connected() -> Env {
        let env = Env()
        env.targetsRead = env.serverRow(state: .ready)
        return env
    }

    static func notConnected() -> Env {
        let env = Env()
        env.targetsRead = .rows([])
        return env
    }

    static func revoked() -> Env {
        let env = notConnected()
        env.runtimeStatus = .revoked
        return env
    }

    // MARK: 읽기

    @Test func theRowAndDetailFollowTheMacsFactsAndTheServersTargetRow() async {
        let env = Self.connected()
        env.name = "Daniel's MacBook Pro"
        env.since = Date(timeIntervalSince1970: 1_790_849_520)
        env.runtimeHasLiveProcess = true
        let model = Self.model(env)
        #expect(model.line.kind == .checking, "읽기 전에는 아무것도 주장하지 않는다")
        await model.refresh(.shown)
        #expect(model.line.kind == .ready && model.line.detail == "Signed in · Session active")
        #expect(model.detail.thisMac == "Daniel's MacBook Pro" && model.detail.version == "2.1.241" && model.detail.showsDisconnect)
        #expect(model.thisMacBridgeID == env.bridge)
    }

    @Test func thisMacsNameFallsBackToTheTargetRowsNameAndThenToNothing() async {
        let env = Env()
        env.targetsRead = env.serverRow(state: .ready, deviceName: "Studio")
        let model = Self.model(env)
        await model.refresh(.shown)
        #expect(model.detail.thisMac == "Studio", "RLS가 이름을 못 주면 서버가 대상 행에 준 이름")
        env.name = "Daniel's MacBook Pro"
        await model.refresh(.again)
        #expect(model.detail.thisMac == "Daniel's MacBook Pro", "RLS 값이 먼저")
        env.name = nil
        env.targetsRead = .rows([])
        await model.refresh(.again)
        #expect(model.detail.thisMac == nil, "둘 다 모르면 줄이 없다 (짐작하지 않는다)")
    }

    @Test func aTargetRowOfAnotherMacIsNotThisMacsConnection() async {
        let env = Env()
        env.targetsRead = .rows([.agent(AssistantTarget.Agent(
            adapter: Env.adapter, displayName: "Claude Code", connectionID: UUID(), state: .ready, access: .write, bridgeID: UUID(), deviceName: "Studio"
        ))])
        let model = Self.model(env)
        await model.refresh(.shown)
        #expect(model.line.kind == .connect, "다른 Mac의 연결은 이 Mac의 것이 아니다: 이 Mac은 Connect")
    }

    @Test func aFailedTargetReadClaimsNothingAndKeepsTheLastRows() async {
        let env = Self.connected()
        let model = Self.model(env)
        env.targetsRead = .failed
        await model.refresh(.shown)
        #expect(model.line.kind == .checking, "받은 적이 없으면 주장하지 않는다")
        env.targetsRead = env.serverRow(state: .signInNeeded)
        await model.refresh(.again)
        #expect(model.line.kind == .signInNeeded)
        env.targetsRead = .failed
        await model.refresh(.again)
        #expect(model.line.kind == .signInNeeded, "읽지 못하면 마지막으로 받은 것을 그대로 둔다")
    }

    @Test func anUnavailableServerNeverOffersConnectOrReconnect() async {
        for status in [BridgeStatus.connected, .revoked, .credentialRejected] {
            let env = Env()
            env.runtimeStatus = status
            env.targetsRead = .unavailable
            let model = Self.model(env)
            await model.refresh(.shown)
            #expect(model.line.detail == "Not available" && model.line.control == .none)
            #expect(model.detail.openNow == nil && !model.detail.showsDisconnect)
            #expect(model.detail.signIn?.text == "Signed in", "이 Mac의 로그인 사실은 그대로다")
            await model.connect()
            await model.reconnect()
            #expect(env.connectCalls == 0 && env.reconnectCalls == 0 && env.notificationCalls == 0)
        }
    }

    @Test func theServerCanBecomeUnavailableAndReturnWithoutLosingItsConnection() async {
        let env = Self.connected()
        let model = Self.model(env)
        await model.refresh(.shown)
        #expect(model.line.kind == .ready)
        env.targetsRead = .unavailable
        await model.refresh(.again)
        #expect(model.line.detail == "Not available" && model.line.control == .none)
        env.targetsRead = .failed
        await model.refresh(.again)
        #expect(model.line.detail == "Not available", "읽기 실패는 서버가 마지막에 말한 상태를 유지한다")
        env.targetsRead = env.serverRow(state: .ready)
        await model.refresh(.again)
        #expect(model.line.kind == .ready && model.detail.showsDisconnect)
        #expect(env.connectCalls == 0 && env.reconnectCalls == 0)
        env.targetsRead = .rows([])
        await model.refresh(.again)
        #expect(model.line.kind == .connect, "실제로 연결 행이 없을 때만 Connect")
    }

    @Test func aBuildThatCannotRunAgentsReadsNothingButStaysHonest() async {
        let env = Env()
        env.canRunAgents = false
        env.report = nil
        let model = Self.model(env)
        await model.refresh(.shown)
        await model.refresh(.again)
        #expect(env.targetCalls == 0 && env.probeCalls == 0 && env.refreshProbeCalls == 0 && env.macsCalls == 0, "서버 · 런타임 호출 0 (11장)")
        await model.connect()
        await model.reconnect()
        await model.disconnect()
        #expect(env.connectCalls == 0 && env.reconnectCalls == 0 && env.disconnectCalls == 0, "버튼 0 · 동작 0")
        #expect(model.line.kind == .unavailable && model.line.detail == "Can't run agents in this build")
        #expect(!model.detail.showsFolders && !model.detail.showsDisconnect)
        #expect(!model.showsMacsNotice)
    }

    @Test func aWindowWithoutAnyEnvironmentIsABuildThatCannotRunAgents() {
        let model = AgentSettingsModel()
        #expect(model.line.kind == .unavailable, "대화 상태가 없으면(플래그 꺼짐) 못 띄운다고 말한다")
    }

    // MARK: 새로 고침 (SA-06): 10초에 한 번

    @Test func shownAndWindowKeyRefreshOncePerTenSecondsAndAgainNeverWaits() async {
        let env = Self.connected()
        let clock = HostBox(Date(timeIntervalSince1970: 1_800_000_000))
        let model = Self.model(env, now: clock)
        await model.refresh(.windowKey)
        #expect(env.refreshProbeCalls == 1 && env.targetCalls == 1)
        clock.value = clock.value.addingTimeInterval(9)
        await model.refresh(.windowKey)
        await model.refresh(.shown)
        #expect(env.refreshProbeCalls == 1 && env.targetCalls == 1, "10초 안의 두 번째는 0")
        clock.value = clock.value.addingTimeInterval(2)
        await model.refresh(.windowKey)
        #expect(env.refreshProbeCalls == 2, "10초가 지나면 다시")
        await model.refresh(.again)
        await model.refresh(.again)
        #expect(env.refreshProbeCalls == 2 && env.probeCalls == 2 && env.targetCalls == 4, "동작 뒤 읽기는 probe를 새로 하지 않고 읽기만 한다")
    }

    /// ch.21 4: 진행 중인 `.again`에 `.windowKey`가 합쳐지면, 그 전체 새로 고침(로그인 캐시 비움 + 서버 보고)을 잃지 않고 다음 반복에서 한다
    @Test func anAgainInFlightThatMeetsAWindowKeyKeepsTheFullRefreshForTheNextRound() async {
        let env = Self.connected()
        env.targetsGate = AgentTestGate()
        let model = Self.model(env)
        let first = Task { await model.refresh(.again) }
        while !(env.targetsGate?.arrived ?? false) { try? await Task.sleep(for: .milliseconds(2)) }
        await model.refresh(.windowKey) // Terminal에서 로그인하고 돌아왔다: 합쳐진다
        env.targetsGate?.open()
        await first.value
        #expect(env.refreshProbeCalls == 1, "합쳐진 요청의 로그인 캐시 비움 · 서버 보고를 다음 반복에서 한다")
        #expect(env.probeCalls == 1, "처음 반복은 읽기만")
        #expect(env.targetCalls == 2)
    }

    @Test func aFullRefreshInFlightThatMeetsAnAgainStaysFullOnceAndTheNextRoundOnlyReads() async {
        let env = Self.connected()
        env.targetsGate = AgentTestGate()
        let model = Self.model(env)
        let first = Task { await model.refresh(.shown) }
        while !(env.targetsGate?.arrived ?? false) { try? await Task.sleep(for: .milliseconds(2)) }
        await model.refresh(.again)
        env.targetsGate?.open()
        await first.value
        #expect(env.refreshProbeCalls == 1 && env.probeCalls == 1 && env.targetCalls == 2, "전체 한 번 + 읽기만 한 번")
    }

    @Test func againNeverSpendsTheTenSecondBudgetOfTheFullRefresh() async {
        let env = Self.connected()
        let model = Self.model(env)
        await model.refresh(.again)
        await model.refresh(.again)
        await model.refresh(.shown)
        #expect(env.refreshProbeCalls == 1, "읽기만 하는 새로 고침은 전체 새로 고침의 10초 예산을 쓰지 않는다")
        await model.refresh(.windowKey)
        #expect(env.refreshProbeCalls == 1, "전체 새로 고침이 예산을 쓴다")
    }

    @Test func refreshCleansTheAlreadyReadValuesWhenTheAccountLeaves() async {
        let env = Self.connected()
        env.name = "Studio"
        let model = Self.model(env)
        await model.refresh(.shown)
        #expect(model.detail.thisMac == "Studio")
        model.accountLeft()
        #expect(model.line.kind == .checking && model.detail.thisMac == nil && model.report == nil && model.busy == nil && model.failure == nil)
    }

    // MARK: Connect (6.1)

    @Test func connectShowsBusyWhileItRunsRefusesASecondPressAndAsksNotificationsAfterSuccess() async {
        let env = Self.notConnected()
        env.connectGate = AgentTestGate()
        env.onConnect = { env.targetsRead = env.serverRow(state: .ready) }
        let model = Self.model(env)
        await model.refresh(.shown)
        #expect(model.line.control == .connect)
        let task = Task { await model.connect() }
        while !(env.connectGate?.arrived ?? false) { try? await Task.sleep(for: .milliseconds(2)) }
        #expect(model.busy == .connect, "누르는 동안 busy")
        await model.connect()
        #expect(env.connectCalls == 1, "겹쳐 누르면 한 번만")
        env.connectGate?.open()
        await task.value
        #expect(model.busy == nil && model.failure == nil)
        #expect(model.line.kind == .ready, "서버가 연결을 주면 줄이 5 → 8로")
        #expect(env.notificationCalls == 1, "SA-10: 연결이 처음 성공하면 알림 묻기 길을 한 번 탄다")
    }

    @Test func connectFailuresAreQuietGrayLinesWithTheExistingSentences() async {
        for (outcome, text) in [
            (AgentConnectOutcome.failed(.offline), "You're offline. Try again."),
            (.failed(.other), "Something went wrong. Try again in a moment."),
            (.unavailable, "Something went wrong. Try again in a moment."),
        ] {
            let env = Self.notConnected()
            env.connectOutcome = outcome
            let model = Self.model(env)
            await model.refresh(.shown)
            await model.connect()
            #expect(model.rowHint == text && model.busy == nil, "\(outcome)")
            #expect(env.notificationCalls == 0, "실패하면 알림을 묻지 않는다")
            #expect(model.line.control == .connect, "다시 누를 수 있다")
            // 다시 누르면 지난 실패 줄은 사라진다 (성공하든 또 실패하든 새 결과로)
            env.connectOutcome = .connected
            await model.connect()
            #expect(model.rowHint == nil)
        }
    }

    @Test func tooManyMacsAndNeedsReconnectAreStatesTheRowSaysNotFailureLines() async {
        let env = Self.notConnected()
        env.connectOutcome = .tooManyMacs
        env.onConnect = { env.runtimeStatus = .tooManyBridges }
        let model = Self.model(env)
        await model.refresh(.shown)
        await model.connect()
        #expect(model.rowHint == nil && model.line.kind == .tooManyMacs && model.showsMacsNotice)
        let revoked = Self.notConnected()
        revoked.connectOutcome = .needsReconnect
        revoked.onConnect = { revoked.runtimeStatus = .revoked }
        let other = Self.model(revoked)
        await other.refresh(.shown)
        await other.connect()
        #expect(other.rowHint == nil && other.line.kind == .reconnect)
    }

    @Test func connectDoesNothingWhenTheRowIsNotOfferingIt() async {
        let env = Self.connected()
        let model = Self.model(env)
        await model.refresh(.shown)
        await model.connect()
        await model.reconnect()
        #expect(env.connectCalls == 0 && env.reconnectCalls == 0, "Connect 줄이 아니면 서버 호출 0 (D2a Q7: 사용자가 그 버튼을 눌렀을 때만)")
        let blocked = Env()
        blocked.canRunAgents = false
        let none = Self.model(blocked)
        await none.connect()
        #expect(blocked.connectCalls == 0)
    }

    // MARK: Reconnect (6.2)

    @Test func reconnectIsOfferedForARevokedMacAndKeepsTheFolders() async {
        let env = Self.revoked()
        env.onReconnect = {
            env.runtimeStatus = .connected
            env.targetsRead = env.serverRow(state: .ready)
        }
        let project = AgentFolderProject(id: UUID(), name: "Acme website", icon: .briefcase)
        env.projectsRead = [project.id: project]
        env.store?.registerFolders([project.id: "/Users/alex/acme"])
        let model = Self.model(env)
        await model.refresh(.shown)
        #expect(model.line.kind == .reconnect && model.line.control == .reconnect)
        #expect(model.folderLines.first?.display == "~/acme", "폴더는 지우지 않는다: 폐기 뒤에도 그대로 보인다")
        await model.reconnect()
        #expect(env.reconnectCalls == 1 && model.line.kind == .ready && env.notificationCalls == 1)
        #expect(model.folderLines.first?.display == "~/acme")
    }

    @Test func reconnectFailureShowsTheQuietLineAndStaysReconnect() async {
        let env = Self.revoked()
        env.reconnectOutcome = .failed(.other)
        let model = Self.model(env)
        await model.refresh(.shown)
        await model.reconnect()
        #expect(model.rowHint == "Something went wrong. Try again in a moment." && model.line.kind == .reconnect)
    }

    // MARK: Disconnect this Mac (6.3)

    @Test func cancellingTheConfirmationNeverCallsTheRuntime() async {
        let env = Self.connected()
        let window = SettingsWindowModel()
        window.agents.attach(env)
        await window.agents.refresh(.shown)
        window.confirming = .disconnectAgent
        window.confirming = nil
        #expect(env.disconnectCalls == 0)
    }

    @Test func confirmingDisconnectCallsTheRuntimeOnceClosesTheRowAndReadsTheNewState() async {
        let env = Self.connected()
        env.onDisconnect = {
            env.runtimeStatus = .revoked
            env.targetsRead = .rows([])
        }
        let window = SettingsWindowModel()
        window.agents.attach(env)
        await window.agents.refresh(.shown)
        window.confirming = .disconnectAgent
        await window.disconnectAgent()
        #expect(env.disconnectCalls == 1 && window.confirming == nil)
        #expect(window.agents.line.kind == .reconnect && !window.agents.detail.showsDisconnect, "Not connected · Reconnect")
        #expect(window.agents.disconnectHint == nil)
    }

    @Test func aFailedDisconnectKeepsTheConfirmationAndShowsAQuietLine() async {
        let env = Self.connected()
        env.disconnectOutcome = .failed(.offline)
        let window = SettingsWindowModel()
        window.agents.attach(env)
        await window.agents.refresh(.shown)
        window.confirming = .disconnectAgent
        await window.disconnectAgent()
        #expect(window.confirming == .disconnectAgent, "이 Mac에서 바뀐 것은 0이라 확인 줄이 그대로 남는다")
        #expect(window.agents.disconnectHint == "You're offline. Try again." && window.agents.line.kind == .ready)
        // 다시 눌러 성공하면 실패 줄이 사라진다
        env.disconnectOutcome = .disconnected(unresolvedProcesses: 0)
        await window.disconnectAgent()
        #expect(window.confirming == nil && window.agents.disconnectHint == nil)
    }

    @Test func theDisconnectRunsToTheEndEvenWhenTheWindowForgetsTheConfirmation() async {
        let env = Self.connected()
        env.disconnectGate = AgentTestGate()
        let window = SettingsWindowModel()
        window.agents.attach(env)
        await window.agents.refresh(.shown)
        window.confirming = .disconnectAgent
        let task = Task { await window.disconnectAgent() }
        while !(env.disconnectGate?.arrived ?? false) { try? await Task.sleep(for: .milliseconds(2)) }
        #expect(window.agents.busy == .disconnect)
        window.close() // 창을 닫아도 일은 계속한다
        env.disconnectGate?.open()
        await task.value
        #expect(env.disconnectCalls == 1 && window.agents.busy == nil)
    }

    // MARK: 계정 경계: 늦은 응답은 버린다

    @Test func aLateConnectAnswerAfterTheAccountLeftWritesNothingAndAsksNothing() async {
        let env = Self.notConnected()
        env.connectGate = AgentTestGate()
        let model = Self.model(env)
        await model.refresh(.shown)
        let task = Task { await model.connect() }
        while !(env.connectGate?.arrived ?? false) { try? await Task.sleep(for: .milliseconds(2)) }
        model.accountLeft()
        let reads = env.targetCalls
        env.connectGate?.open()
        await task.value
        #expect(model.busy == nil && model.failure == nil && model.rowHint == nil)
        #expect(env.notificationCalls == 0 && env.targetCalls == reads, "옛 계정의 늦은 성공은 알림도 읽기도 부르지 않는다")
        #expect(model.line.kind == .checking, "새 계정은 처음부터 읽는다")
    }

    @Test func aLateDisconnectAnswerAfterTheAccountLeftIsDropped() async {
        let env = Self.connected()
        env.disconnectGate = AgentTestGate()
        env.disconnectOutcome = .failed(.other)
        let model = Self.model(env)
        await model.refresh(.shown)
        let task = Task { await model.disconnect() }
        while !(env.disconnectGate?.arrived ?? false) { try? await Task.sleep(for: .milliseconds(2)) }
        model.accountLeft()
        env.disconnectGate?.open()
        let result = await task.value
        #expect(result == false && model.failure == nil, "늦은 실패도 새 계정 화면에 줄을 남기지 않는다")
    }

    @Test func aLateReadAfterTheAccountLeftDoesNotFillTheNewAccountsScreen() async {
        let env = Self.connected()
        env.name = "Old account's Mac"
        env.targetsGate = AgentTestGate()
        let model = Self.model(env)
        let reading = Task { await model.refresh(.shown) }
        while !(env.targetsGate?.arrived ?? false) { try? await Task.sleep(for: .milliseconds(2)) }
        model.accountLeft() // 읽는 중에 계정이 떠났다
        env.targetsGate?.open()
        await reading.value
        #expect(model.line.kind == .checking && model.detail.thisMac == nil && model.liveSince == nil && model.thisMacBridgeID == nil, "옛 계정의 늦은 읽기가 새 계정에 남지 않는다")
        // 새 계정은 처음부터 읽는다 (10초 제한도 새로 시작)
        env.targetsGate = nil
        await model.refresh(.shown)
        #expect(model.line.kind == .ready)
    }

    // MARK: 10대 (6.4)

    @Test func theTenMacsFlowShowsTheNoticeListsOtherMacsOldestFirstAndRemovesOne() async {
        let env = Self.notConnected()
        env.runtimeStatus = .tooManyBridges
        let mine = env.bridge!
        let old = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!
        let recent = UUID(uuidString: "00000000-0000-4000-8000-000000000002")!
        env.macsRead = [
            AgentMacRecord(id: recent, deviceName: "Recent", lastHeartbeatAt: Date(timeIntervalSince1970: 1_799_999_000)),
            AgentMacRecord(id: mine, deviceName: "Mine", lastHeartbeatAt: Date(timeIntervalSince1970: 1_800_000_000)),
            AgentMacRecord(id: old, deviceName: nil, lastHeartbeatAt: Date(timeIntervalSince1970: 1_790_000_000)),
        ]
        env.onRemove = {
            env.runtimeStatus = .connected
            env.macsRead = env.macsRead?.filter { $0.id != old }
        }
        let window = SettingsWindowModel()
        window.agents.attach(env)
        await window.agents.refresh(.shown)
        #expect(window.agents.showsMacsNotice && window.agents.line.kind == .tooManyMacs)
        #expect(SettingsWindowTab.connections.sections(.signedIn, macsNotice: true).first == .macsNotice)
        window.open(.macs)
        await window.agents.loadMacs()
        #expect(window.agents.macs.map(\.id) == [old, recent], "이 Mac은 없고 오래된 순")
        #expect(AgentSettingsMacs.title(window.agents.macs[0]) == "Mac", "이름 없는 Mac")
        window.confirming = .removeMac(old)
        await window.removeMac(old)
        #expect(env.removed == [old], "그 Mac id로 폐기 1")
        #expect(window.agents.macs.map(\.id) == [recent], "목록을 다시 읽었다")
        #expect(!window.agents.showsMacsNotice && window.agents.line.kind == .connect && window.agents.line.control == .connect, "Connect가 다시 열린다")
        #expect(window.detail == nil && window.confirming == nil, "Connect가 열린 탭으로 돌아간다")
        #expect(env.connectCalls == 0, "자동으로 연결하지 않는다")
    }

    @Test func aFailedRemoveKeepsTheListAndTheConfirmationWithAQuietLineOnThatMacOnly() async {
        let env = Self.notConnected()
        env.runtimeStatus = .tooManyBridges
        let a = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!
        let b = UUID(uuidString: "00000000-0000-4000-8000-000000000002")!
        env.macsRead = [AgentMacRecord(id: a, deviceName: "A", lastHeartbeatAt: nil), AgentMacRecord(id: b, deviceName: "B", lastHeartbeatAt: nil)]
        env.removeOutcome = .failed(.offline)
        let window = SettingsWindowModel()
        window.agents.attach(env)
        await window.agents.refresh(.shown)
        window.open(.macs)
        await window.agents.loadMacs()
        window.confirming = .removeMac(a)
        await window.removeMac(a)
        #expect(window.confirming == .removeMac(a) && window.detail == .macs && window.agents.macs.count == 2)
        #expect(window.agents.macHint(a) == "You're offline. Try again." && window.agents.macHint(b) == nil)
    }

    @Test func aMacListThatCannotBeReadSaysSoInsteadOfClaimingNoMacs() async {
        let env = Self.notConnected()
        env.runtimeStatus = .tooManyBridges
        env.macsRead = nil
        let model = Self.model(env)
        await model.refresh(.shown)
        await model.loadMacs()
        #expect(model.macsFailed && model.macs.isEmpty)
    }

    // MARK: 폴더 (7장)

    private func foldersFixture() -> (Env, [AgentFolderProject]) {
        let env = Self.connected()
        let projects = [
            AgentFolderProject(id: UUID(), name: "Shape launch", icon: .rocket), AgentFolderProject(id: UUID(), name: "Acme website", icon: .briefcase),
            AgentFolderProject(id: UUID(), name: "Taskforce 0.2.0", icon: .codeXml),
        ]
        env.projectsRead = Dictionary(uniqueKeysWithValues: projects.map { ($0.id, $0) })
        env.store?.registerFolders([projects[0].id: "/Users/alex/Documents/Shape/launch", projects[1].id: "/Users/alex/Projects/acme-site", projects[2].id: "/Volumes/Work SSD/taskforce"])
        return (env, projects)
    }

    @Test func threeProjectsShowTheirFoldersAndUngroupedAsksEachTime() async {
        let (env, _) = foldersFixture()
        let model = Self.model(env)
        await model.refresh(.shown)
        #expect(model.folderLines.map(\.name) == ["Acme website", "Shape launch", "Taskforce 0.2.0", "Ungrouped"])
        #expect(model.folderLines.map(\.display) == ["~/Projects/acme-site", "~/Documents/Shape/launch", "/Volumes/Work SSD/taskforce", "Ask each time"])
    }

    @Test func aFolderThatIsGoneIsMissingAndNothingIsRemoved() async {
        let (env, projects) = foldersFixture()
        env.existing = ["/Users/alex/Projects/acme-site", "/Volumes/Work SSD/taskforce"]
        let model = Self.model(env)
        await model.refresh(.shown)
        let shape = model.folderLines.first { $0.project?.id == projects[0].id }
        #expect(shape?.missing == true, "사라진 폴더는 굵은 Missing")
        #expect(env.store?.removed.isEmpty == true, "자동으로 지우지 않는다")
    }

    @Test func aDeletedProjectsFolderIsCleanedUpButOnlyOnceTheProjectsWereRead() async {
        let (env, projects) = foldersFixture()
        let gone = UUID()
        env.store?.registerFolders([gone: "/Users/alex/gone-project"])
        let model = Self.model(env)
        env.projectsRead = nil
        await model.refresh(.shown)
        #expect(env.store?.removed.isEmpty == true && model.folderLines.map(\.name) == ["Ungrouped"], "프로젝트를 읽지 못했으면 줄도 정리도 없다")
        env.projectsRead = Dictionary(uniqueKeysWithValues: projects.map { ($0.id, $0) })
        await model.refresh(.again)
        #expect(env.store?.removed == [gone] && model.folderLines.count == 4, "읽은 목록에 없는 프로젝트의 폴더는 등록부에서 지운다")
    }

    /// ch.21 3: 등록된 프로젝트 id를 하나도 빼지 않고 직접 묻는다 — 이름순 500 목록으로 판단하지 않는다
    @Test func registeredFoldersAreAskedByTheirOwnIdsSoAFiveHundredAndOneRegistryLosesNothing() async {
        let env = Self.connected()
        var projects: [UUID: AgentFolderProject] = [:]
        var folders: [UUID: String] = [:]
        for index in 0..<501 {
            let project = AgentFolderProject(id: UUID(), name: "Project \(index)", icon: .folder)
            projects[project.id] = project
            folders[project.id] = "/Users/alex/p\(index)"
        }
        env.projectsRead = projects
        env.store?.registerFolders(folders)
        let model = Self.model(env)
        await model.refresh(.shown)
        #expect(env.projectIDsAsked.last.map(Set.init) == Set(folders.keys) && env.projectIDsAsked.last?.count == 501, "등록된 501개를 모두 물었다")
        #expect(env.store?.removed.isEmpty == true, "정상 프로젝트의 매핑을 지우지 않는다")
        #expect(model.folderLines.count == 502)
    }

    @Test func anAccountChangeWhileTheProjectsAreBeingReadNeverPrunes() async {
        let (env, _) = foldersFixture()
        let gone = UUID()
        env.store?.registerFolders([gone: "/Users/alex/gone-project"])
        env.projectsGate = AgentTestGate()
        let model = Self.model(env)
        let task = Task { await model.refresh(.shown) }
        while !(env.projectsGate?.arrived ?? false) { try? await Task.sleep(for: .milliseconds(2)) }
        model.accountLeft() // 읽는 사이 계정이 떠났다
        env.projectsGate?.open()
        await task.value
        #expect(env.store?.removed.isEmpty == true, "계정 세대가 바뀌었으면 읽은 답이 \"없다\"여도 지우지 않는다")
        #expect(model.folderLines.map(\.name) == ["Ungrouped"], "옛 계정의 줄을 새 화면에 채우지 않는다")
    }

    @Test func anAccountChangeWhileTheFoldersAreBeingCheckedNeverPrunes() async {
        let (env, _) = foldersFixture()
        let gone = UUID()
        env.store?.registerFolders([gone: "/Users/alex/gone-project"])
        env.existingGate = AgentTestGate()
        let model = Self.model(env)
        let task = Task { await model.refresh(.shown) }
        while !(env.existingGate?.arrived ?? false) { try? await Task.sleep(for: .milliseconds(2)) }
        model.accountLeft() // 폴더가 있는지 보는 사이 계정이 떠났다
        env.existingGate?.open()
        await task.value
        #expect(env.store?.removed.isEmpty == true && model.folderLines.map(\.name) == ["Ungrouped"])
    }

    @Test func aRegistryReplacedWhileTheReadWasInFlightIsNeverPruned() async {
        let (env, _) = foldersFixture()
        let gone = UUID()
        env.store?.registerFolders([gone: "/Users/alex/gone-project"])
        let first = env.store
        env.projectsGate = AgentTestGate()
        let model = Self.model(env)
        let task = Task { await model.refresh(.shown) }
        while !(env.projectsGate?.arrived ?? false) { try? await Task.sleep(for: .milliseconds(2)) }
        env.store = FakeFolderStore() // 다른 계정의 등록부로 바뀌었다
        env.projectsGate?.open()
        await task.value
        #expect(first?.removed.isEmpty == true && env.store?.removed.isEmpty == true, "읽던 등록부가 아니면 지우지 않는다")
    }

    @Test func aFolderThatChangedWhileTheReadWasInFlightIsNotPruned() async {
        let (env, _) = foldersFixture()
        let gone = UUID()
        env.store?.registerFolders([gone: "/Users/alex/gone-project"])
        env.projectsGate = AgentTestGate()
        let model = Self.model(env)
        let task = Task { await model.refresh(.shown) }
        while !(env.projectsGate?.arrived ?? false) { try? await Task.sleep(for: .milliseconds(2)) }
        env.store?.forceFolder(gone, "/Users/alex/moved-project") // 읽는 사이 그 프로젝트의 폴더가 바뀌었다 (Change…)
        env.projectsGate?.open()
        await task.value
        #expect(env.store?.removed.isEmpty == true, "읽은 값 그대로일 때만 지운다")
    }

    /// ch.21 5: 거절이 아닌 쓰기 실패는 있는 문장을 조용한 회색 줄로 보인다
    @Test func aFolderThatCouldNotBeSavedShowsTheExistingSentenceInGrayAndKeepsTheOldFolder() async {
        let (env, projects) = foldersFixture()
        env.picker.result = "/Users/alex/Projects/acme-v2"
        env.store?.writeFails = true
        let model = Self.model(env)
        await model.refresh(.shown)
        await model.changeFolder(project: projects[1])
        #expect(model.folderHint == "Something went wrong. Try again in a moment.", "있는 문장")
        #expect(model.folderLines.first { $0.project?.id == projects[1].id }?.display == "~/Projects/acme-site", "옛 폴더 그대로")
        env.store?.writeFails = false
        await model.changeFolder(project: projects[1])
        #expect(model.folderHint == nil && model.folderLines.first { $0.project?.id == projects[1].id }?.display == "~/Projects/acme-v2", "다음에 저장되면 줄이 사라진다")
    }

    @Test func aRejectionIsNotASaveFailureSoNoLineIsShown() async {
        let (env, projects) = foldersFixture()
        env.picker.result = "/etc/x"
        env.picker.respectsAccepts = false
        let model = Self.model(env)
        await model.refresh(.shown)
        await model.changeFolder(project: projects[1])
        #expect(model.folderHint == nil && model.failure == nil)
    }

    @Test func changeOpensTheSameFolderWindowWithTheSameRulesAndRegistersWhatIsChosen() async {
        let (env, projects) = foldersFixture()
        env.picker.result = "/Users/alex/Projects/acme-v2"
        let model = Self.model(env)
        await model.refresh(.shown)
        await model.changeFolder(project: projects[1])
        let asked = env.picker.asked.last
        #expect(asked?.message == "Choose a folder for Acme website" && asked?.prompt == "Choose" && asked?.rejection == "Choose a folder inside your home folder or on an external drive.")
        #expect(asked?.accepts("/Users/alex/Projects/x") == true && asked?.accepts("/etc") == false, "창 안 거절은 등록부의 규칙이다")
        #expect(asked?.reason("/etc") == "Choose a folder inside your home folder or on an external drive.")
        #expect(env.store?.registered.last?.path == "/Users/alex/Projects/acme-v2" && env.store?.registered.last?.scope == .project(projects[1].id))
        #expect(model.folderLines.first { $0.project?.id == projects[1].id }?.display == "~/Projects/acme-v2")
    }

    @Test func cancellingTheFolderWindowChangesNothing() async {
        let (env, projects) = foldersFixture()
        env.picker.result = nil
        let model = Self.model(env)
        await model.refresh(.shown)
        await model.changeFolder(project: projects[1])
        #expect(env.store?.registered.isEmpty == true && model.folderLines.first { $0.project?.id == projects[1].id }?.display == "~/Projects/acme-site")
    }

    @Test func aRejectedFolderChangesNothingEvenIfTheWindowLetItThrough() async {
        let (env, projects) = foldersFixture()
        env.picker.result = "/etc/hosts-folder"
        env.picker.respectsAccepts = false // 창이 뚫려 거절 폴더가 돌아온 경우
        let model = Self.model(env)
        await model.refresh(.shown)
        await model.changeFolder(project: projects[1])
        #expect(env.store?.registered.isEmpty == true, "등록부가 한 번 더 거절한다")
        #expect(model.folderLines.first { $0.project?.id == projects[1].id }?.display == "~/Projects/acme-site", "바뀐 것 0")
        #expect(model.failure == nil, "거절을 Settings 줄에 되풀이하지 않는다 (폴더 창 안의 승인된 글로 끝)")
    }

    @Test func removingAFolderIsAConfirmedActionThatMakesTheNextSessionAskAgain() async {
        let (env, projects) = foldersFixture()
        let window = SettingsWindowModel()
        window.agents.attach(env)
        await window.agents.refresh(.shown)
        window.confirming = .removeFolder(projects[1].id)
        window.confirming = nil
        #expect(env.store?.removed.isEmpty == true, "Cancel은 지우지 않는다")
        window.confirming = .removeFolder(projects[1].id)
        await window.removeFolder(project: projects[1].id)
        #expect(env.store?.removed == [projects[1].id] && window.confirming == nil)
        #expect(window.agents.folderLines.map(\.name) == ["Shape launch", "Taskforce 0.2.0", "Ungrouped"])
        #expect(AgentSettingsCopy.removeFolderDetail(project: projects[1].name) == "The next new session in Acme website asks again.")
    }

    @Test func twelveFoldersAndLongContentAreAllLines() async {
        let env = Self.connected()
        var projects: [UUID: AgentFolderProject] = [:]
        var folders: [UUID: String] = [:]
        for index in 0..<12 {
            let project = AgentFolderProject(id: UUID(), name: index == 0 ? String(repeating: "Northwind Traders · 2026 website relaunch ", count: 4) : "Project \(index)", icon: .folder)
            projects[project.id] = project
            folders[project.id] = index == 1 ? "/Users/alex/" + String(repeating: "very-long-folder-name/", count: 12) + "leaf" : "/Users/alex/p\(index)"
        }
        env.projectsRead = projects
        env.store?.registerFolders(folders)
        let model = Self.model(env)
        await model.refresh(.shown)
        #expect(model.folderLines.count == 13 && model.folderLines.last?.isUngrouped == true)
        #expect(model.folderLines.allSatisfy { $0.display.count <= AgentSettingsPath.maxLength })
    }
}

extension FakeFolderStore {
    /// 시험이 등록부의 지금 폴더를 바로 정한다 (규칙을 거치지 않는다)
    func registerFolders(_ folders: [UUID: String]) {
        for (id, path) in folders { forceFolder(id, path) }
    }
}
