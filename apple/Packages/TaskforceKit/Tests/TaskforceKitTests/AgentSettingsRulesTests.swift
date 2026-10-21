#if os(macOS)
import Foundation
import Testing
@testable import TaskforceKit

/// Settings › Your agents의 줄 · 상세 규칙 (OA Settings › Your agents 5장 · 14.1): 5.2 표의 모든 줄과 우선순위 · 모르는 서버 상태는 주장 0 · 굵은 말 목록 · Open now 매핑 · 각주 순서
struct AgentSettingsRulesTests {
    typealias Facts = AgentSettingsFacts
    static let bridge = UUID(uuidString: "b1111111-1111-4111-8111-111111111111")!

    static func report(installed: Bool = true, version: String? = "2.1.241", signedIn: BridgeV1SignedIn = .yes, managed: Bool = false) -> BridgeV1AdapterReport {
        BridgeV1AdapterReport(adapter: "agent:claude-code", installed: installed, version: installed ? version : nil, signedIn: signedIn, managedSettings: managed)
    }

    /// 모든 값이 도착한 평범한 사실 (연결됨 · 로그인됨 · 세션 없음)
    static func facts(
        state: AgentTargetState? = .ready, access: AgentAccessLevel? = .write, status: BridgeStatus? = .connected, live: Bool = false,
        report: BridgeV1AdapterReport? = report(), canRun: Bool = true, target: Facts.Target? = nil
    ) -> Facts {
        Facts(
            canRunAgents: canRun, status: status, hasLiveProcess: live, report: report,
            target: target ?? state.map { .row(state: $0, access: access) } ?? .none
        )
    }

    // MARK: 문구: 승인된 글자 그대로

    /// DZ README 표와 계약 12장 · 19장의 승인 문구. 한 글자라도 다르면 깨진다 (이 목록은 상수에서 뽑지 않고 손으로 적었다)
    @Test func everyApprovedStringIsExactlyTheApprovedText() {
        typealias C = AgentSettingsCopy
        #expect(C.sectionTitle == "Your agents" && C.agentName == "Claude Code")
        #expect(C.signedInSessionActive == "Signed in · Session active" && C.signedInNoSession == "Signed in · No active session")
        #expect(C.notSignedIn == "Not signed in" && C.notConnected == "Not connected" && C.checking == "Checking…")
        #expect(C.cantRunInThisBuild == "Can't run agents in this build" && C.offline == "Offline")
        #expect(C.connect == "Connect" && C.reconnect == "Reconnect" && C.disconnect == "Disconnect")
        #expect(C.status == "Status" && C.signIn == "Sign-in" && C.session == "Session" && C.none == "None" && C.access == "Access" && C.level == "Level" && C.openNow == "Open now")
        #expect(C.activeSince("10:12") == "Active since 10:12")
        #expect(C.canWrite == "Can write" && C.readOnly == "Read only" && C.unsupported == "Unsupported")
        #expect(C.signInHelp == "Sign in from Terminal by running claude, then come back. Taskforce never asks for your login.")
        #expect(C.notInstalled == "Not installed" && C.installHelp == "Install Claude Code on this Mac, then come back.")
        #expect(C.version == "Version" && C.thisMac == "This Mac")
        #expect(C.managedSettings == "Claude Code on this Mac uses settings managed by your organization.")
        #expect(C.unsupportedVersion == "This version of Claude Code isn't supported yet. Update it, then come back.")
        #expect(C.connectIntro == "Connecting lets Taskforce start Claude Code on this Mac for work you send it. It runs on your Claude plan.")
        #expect(C.accessFootnote == "Open now is what Taskforce can let Claude Code do at this moment.")
        #expect(C.tooManyMacs == "Too many Macs" && C.tenMacsNotice == "This account has 10 Macs connected" && C.showMacs == "Show Macs" && C.macsTitle == "Macs")
        #expect(C.unnamedMac == "Mac" && C.removeMacAction == "Remove…" && C.remove == "Remove")
        #expect(C.lastSeen("4 min ago") == "Last seen 4 min ago" && C.removeMacTitle("Studio") == "Remove Studio?")
        #expect(C.removeMacDetail == "Its agent sessions stop. Conversations stay.")
        #expect(C.folders == "Folders" && C.ungrouped == "Ungrouped" && C.askEachTime == "Ask each time" && C.change == "Change…" && C.removeFolderAction == "Remove…" && C.missing == "Missing")
        #expect(C.removeFolderTitle == "Remove this folder?" && C.removeFolderDetail(project: "Acme website") == "The next new session in Acme website asks again.")
        #expect(C.disconnectRow == "Disconnect this Mac" && C.disconnectAction == "Disconnect…" && C.disconnectTitle == "Disconnect this Mac?" && C.disconnect == "Disconnect")
        #expect(C.disconnectDetail == "Claude Code sessions on this Mac stop. Their conversations and your folders stay.")
        #expect(C.agentPurpose == "Taskforce Agent runs Claude Code in the folders you choose for your projects.")
        #expect(C.somethingWentWrong == "Something went wrong. Try again in a moment." && C.youAreOffline == "You're offline. Try again.")
    }

    @Test func theFoldersFootnoteIsTheFourApprovedSentencesInOneParagraph() {
        #expect(AgentSettingsCopy.foldersFootnote == "Claude Code works only in the folder you choose for each project. Sessions already started keep their folder. Your own Claude Code settings aren't applied. macOS may ask whether Taskforce Agent, the helper that runs Claude Code, can open these folders.")
        #expect(AgentSettingsCopy.foldersFootnote.components(separatedBy: ". ").count == 4, "네 문장")
    }

    @Test func theFailureLinesAreTheExistingSentences() {
        #expect(AgentSettingsCopy.somethingWentWrong == (APIError.unexpectedStatus(500)).userMessage)
    }

    // MARK: 5.2 표: 줄 0–8

    @Test func row0IsCheckingUntilBothTheProbeAndTheTargetListArrive() {
        for facts in [Self.facts(report: nil), Self.facts(target: .notLoaded), Self.facts(report: nil, target: .notLoaded)] {
            let line = AgentSettingsRules.line(facts)
            #expect(line.kind == .checking && line.detail == "Checking…" && line.control == .none && !line.bold)
        }
    }

    @Test func row1ABuildThatCannotRunAgentsSaysSoAndWaitsForNothing() {
        // 이 빌드가 못 띄우면 probe · 대상 목록을 기다리지 않는다 (받을 수 없다): Checking…에 갇히지 않는다
        let line = AgentSettingsRules.line(Self.facts(report: nil, canRun: false, target: .notLoaded))
        #expect(line.kind == .unavailable && line.detail == "Can't run agents in this build" && line.control == .level && !line.bold)
        #expect(AgentSettingsRules.line(Self.facts(status: .revoked, canRun: false)).kind == .unavailable, "폐기 상태도 이 빌드의 한계가 먼저다")
    }

    @Test func aServerThatDoesNotOfferAgentsDoesNotClaimAConnectionOrOfferRegistration() {
        for status in [BridgeStatus.connected, .revoked, .credentialRejected, .tooManyBridges, .offline] {
            let facts = Self.facts(status: status, target: .unavailable)
            let line = AgentSettingsRules.line(facts)
            #expect(line.kind == .serverUnavailable && line.detail == "Not available" && line.control == .none && !line.bold)
            #expect(line.accessibilityLabel == "Claude Code, Not available")
            let detail = AgentSettingsRules.detail(facts)
            #expect(detail.signIn == AgentSettingsValue("Signed in") && detail.version == "2.1.241")
            #expect(detail.openNow == nil && detail.accessFootnote == nil && detail.statusFootnote == nil)
            #expect(detail.showsFolders && !detail.showsDisconnect)
        }
        #expect(AgentSettingsRules.line(Self.facts(report: nil, target: .unavailable)).kind == .serverUnavailable, "서버가 이미 답했으면 로컬 probe를 기다리는 말로 가리지 않는다")
        let disabledBuild = AgentSettingsRules.line(Self.facts(canRun: false, target: .unavailable))
        #expect(disabledBuild.kind == .unavailable && disabledBuild.detail == "Can't run agents in this build", "빌드 한계는 별개다")
    }

    @Test func row2RevokedOrRejectedIsABoldNotConnectedWithReconnect() {
        for status in [BridgeStatus.revoked, .credentialRejected] {
            let line = AgentSettingsRules.line(Self.facts(status: status))
            #expect(line.kind == .reconnect && line.detail == "Not connected" && line.bold && line.control == .reconnect, "\(status)")
        }
    }

    @Test func row3TooManyMacsIsBoldWithNoControl() {
        let line = AgentSettingsRules.line(Self.facts(status: .tooManyBridges))
        #expect(line.kind == .tooManyMacs && line.detail == "Too many Macs" && line.bold && line.control == .none)
    }

    @Test func row4NotInstalledIsBoldWithNoControl() {
        let line = AgentSettingsRules.line(Self.facts(report: Self.report(installed: false)))
        #expect(line.kind == .notInstalled && line.detail == "Not installed" && line.bold && line.control == .none)
    }

    @Test func row5NoConnectionOffersConnectAndIsNotBold() {
        for facts in [Self.facts(state: nil), Self.facts(state: .notConnected)] {
            let line = AgentSettingsRules.line(facts)
            #expect(line.kind == .connect && line.detail == "Not connected" && !line.bold && line.control == .connect, "연결 없음은 굵지 않고 Connect")
        }
    }

    @Test func row6SignInNeededIsBoldNotSignedInWithTheLevel() {
        let line = AgentSettingsRules.line(Self.facts(state: .signInNeeded))
        #expect(line.kind == .signInNeeded && line.detail == "Not signed in" && line.bold && line.control == .level)
    }

    @Test func row7OfflineComesFromTheServerOrFromThisMacsRuntime() {
        #expect(AgentSettingsRules.line(Self.facts(state: .unreachable)).detail == "Offline")
        for status in [BridgeStatus.offline, .sleeping] {
            let line = AgentSettingsRules.line(Self.facts(status: status))
            #expect(line.kind == .offline && line.detail == "Offline" && !line.bold && line.control == .level, "\(status)")
        }
    }

    @Test func row8ReadyShowsTheSessionAndWhatTheServerSays() {
        #expect(AgentSettingsRules.line(Self.facts(live: true)).detail == "Signed in · Session active")
        #expect(AgentSettingsRules.line(Self.facts(live: false)).detail == "Signed in · No active session")
        #expect(AgentSettingsRules.line(Self.facts(state: .unsupported, live: true)).detail == "Signed in · Session active · Unsupported", "지금 Claude Code의 실제 모습")
        #expect(AgentSettingsRules.line(Self.facts(access: .readOnly, live: true)).detail == "Signed in · Session active · Read only")
        #expect(AgentSettingsRules.line(Self.facts(state: .unsupported, access: .readOnly)).detail == "Signed in · No active session · Unsupported · Read only")
        for line in [AgentSettingsRules.line(Self.facts()), AgentSettingsRules.line(Self.facts(state: .unsupported))] {
            #expect(line.kind == .ready && line.control == .level && !line.bold)
        }
    }

    // MARK: 우선순위: 위에서부터 먼저 맞는 줄

    @Test func theTableWinsFromTheTopWhenSeveralRowsMatch() {
        // 0이 모두를 이긴다 (이 빌드가 띄울 수 있을 때)
        #expect(AgentSettingsRules.line(Self.facts(status: .revoked, report: nil)).kind == .checking)
        // 2가 3 · 4 · 5를 이긴다
        #expect(AgentSettingsRules.line(Self.facts(state: nil, status: .revoked, report: Self.report(installed: false))).kind == .reconnect)
        // 3이 4 · 5를 이긴다
        #expect(AgentSettingsRules.line(Self.facts(state: nil, status: .tooManyBridges, report: Self.report(installed: false))).kind == .tooManyMacs)
        // 4가 5 · 6 · 7 · 8을 이긴다
        for state in [AgentTargetState?.none, .notConnected, .signInNeeded, .unreachable, .ready] {
            #expect(AgentSettingsRules.line(Self.facts(state: state, report: Self.report(installed: false))).kind == .notInstalled, "\(String(describing: state))")
        }
        // 5가 7을 이긴다: 연결이 없으면 오프라인이어도 Connect다
        #expect(AgentSettingsRules.line(Self.facts(state: nil, status: .offline)).kind == .connect)
        // 6이 7(이 Mac 런타임의 오프라인)을 이긴다
        #expect(AgentSettingsRules.line(Self.facts(state: .signInNeeded, status: .offline)).kind == .signInNeeded)
    }

    @Test func anUnknownServerStateClaimsNothing() {
        for raw in ["paused", "future_state", ""] {
            let line = AgentSettingsRules.line(Self.facts(state: .unknown(raw)))
            #expect(line.kind == .checking && line.detail == "Checking…" && line.control == .none, "\(raw)")
        }
        // 모르는 접근 등급도 말을 지어내지 않는다
        #expect(AgentSettingsRules.line(Self.facts(access: .unknown("admin"))).detail == "Signed in · No active session")
    }

    /// 서버가 판정하는 말을 앱이 다시 계산하지 않는다: 버전이 범위 밖이어도 "Unsupported"는 서버가 `unsupported`라고 했을 때만이다
    @Test func theAppNeverRecomputesWhatTheServerDecides() {
        let oldVersion = Self.report(version: "1.0.88")
        #expect(!AgentSettingsRules.line(Self.facts(state: .ready, report: oldVersion)).detail.contains("Unsupported"), "범위 밖 버전이어도 서버가 ready면 ready")
        #expect(AgentSettingsRules.line(Self.facts(state: .unsupported, report: Self.report(version: "2.1.241"))).detail.contains("Unsupported"), "서버가 unsupported면 범위 안 버전이어도 Unsupported")
        // 이 Mac에서 로그인 상태 파일이 "no"여도 줄은 서버를 따른다 (Status › Sign-in만 P를 보인다)
        let signedOutHere = Self.facts(state: .ready, report: Self.report(signedIn: .no))
        #expect(AgentSettingsRules.line(signedOutHere).detail == "Signed in · No active session")
        #expect(AgentSettingsRules.detail(signedOutHere).signIn == AgentSettingsValue("Not signed in", bold: true))
        // 서버가 읽기 전용이라고 해야 "Read only"
        #expect(!AgentSettingsRules.line(Self.facts(access: .write)).detail.contains("Read only"))
    }

    // MARK: 굵은 말 목록

    @Test func onlyTheFourStatusWordsAreBoldInTheRow() {
        let states: [AgentTargetState?] = [nil, .notConnected, .signInNeeded, .unreachable, .ready, .unsupported, .unknown("x")]
        let statuses: [BridgeStatus?] = [nil, .connected, .offline, .sleeping, .revoked, .tooManyBridges, .credentialRejected, .connecting]
        let reports: [BridgeV1AdapterReport?] = [nil, Self.report(), Self.report(installed: false), Self.report(signedIn: .no)]
        var boldWords: Set<String> = []
        for canRun in [true, false] {
            for state in states {
                for status in statuses {
                    for report in reports {
                        let line = AgentSettingsRules.line(Self.facts(state: state, status: status, report: report, canRun: canRun))
                        if line.bold { boldWords.insert(line.detail) }
                    }
                }
            }
        }
        #expect(boldWords == ["Not signed in", "Not connected", "Not installed", "Too many Macs"], "굵은 말 목록")
        // 그 "Not connected"는 폐기 · 자격 거절(Reconnect)일 때만 굵다. 연결 없음(Connect)은 굵지 않다
        #expect(AgentSettingsRules.line(Self.facts(state: nil)).bold == false)
    }

    // MARK: 접근성: 줄 + 상태 + 동작

    @Test func theAccessibilityNameIsTheRowTheStateAndTheAction() {
        #expect(AgentSettingsRules.line(Self.facts(state: nil)).accessibilityLabel == "Claude Code, Not connected, Connect")
        #expect(AgentSettingsRules.line(Self.facts(status: .revoked)).accessibilityLabel == "Claude Code, Not connected, Reconnect")
        #expect(AgentSettingsRules.line(Self.facts(live: true)).accessibilityLabel == "Claude Code, Signed in · Session active, Level Can write")
        #expect(AgentSettingsRules.line(Self.facts(report: Self.report(installed: false))).accessibilityLabel == "Claude Code, Not installed")
    }

    // MARK: 상세: Status · Access

    private func detail(_ facts: Facts) -> AgentSettingsDetail { AgentSettingsRules.detail(facts, timeZone: TimeZone(identifier: "UTC")!) }

    @Test func detailForAConnectedMacShowsSignInSessionVersionAndTheMacName() {
        var facts = Self.facts(state: .unsupported, live: true)
        facts.deviceName = "Daniel's MacBook Pro"
        // UTC 2026-10-01 10:12
        facts.liveSince = Date(timeIntervalSince1970: 1_790_849_520)
        let detail = detail(facts)
        #expect(detail.signIn == AgentSettingsValue("Signed in") && detail.session == AgentSettingsValue("Active since 10:12"))
        #expect(detail.version == "2.1.241" && detail.thisMac == "Daniel's MacBook Pro")
        #expect(detail.level == "Can write", "Level은 고칠 수 없는 Value (SA-01 A)")
        #expect(detail.openNow == AgentSettingsValue("Unsupported", bold: true) && detail.accessFootnote == "Open now is what Taskforce can let Claude Code do at this moment.")
        #expect(detail.showsFolders && detail.showsDisconnect)
    }

    @Test func aMacWithNoNameHasNoThisMacLineAndAnEmptyNameIsTheSame() {
        for name in [nil, ""] {
            var facts = Self.facts()
            facts.deviceName = name
            #expect(detail(facts).thisMac == nil, "짐작하지 않는다")
        }
    }

    @Test func aSixtyFourCharacterMacNameIsShownWhole() {
        var facts = Self.facts()
        let name = String(repeating: "M", count: 64)
        facts.deviceName = name
        #expect(detail(facts).thisMac == name, "이름은 규칙이 자르지 않는다 (끝 줄임은 화면의 몫)")
    }

    @Test func openNowFollowsTheServersOpenGradeAndIsMissingWithoutAConnection() {
        #expect(detail(Self.facts(state: .ready, access: .write)).openNow == AgentSettingsValue("Can write"))
        #expect(detail(Self.facts(state: .ready, access: .readOnly)).openNow == AgentSettingsValue("Read only"))
        #expect(detail(Self.facts(state: .unsupported, access: .write)).openNow == AgentSettingsValue("Unsupported", bold: true))
        #expect(detail(Self.facts(state: .signInNeeded, access: .write)).openNow == AgentSettingsValue("Can write"))
        for none in [Self.facts(state: nil), Self.facts(status: .revoked), Self.facts(status: .tooManyBridges), Self.facts(report: Self.report(installed: false)), Self.facts(report: nil)] {
            let value = detail(none)
            #expect(value.openNow == nil && value.accessFootnote == nil, "연결 없음 · 모름: Open now 줄도 각주도 없다")
        }
        #expect(detail(Self.facts(state: .ready, access: nil)).openNow == nil, "등급을 모르면 줄이 없다")
        let blocked = detail(Self.facts(report: nil, canRun: false, target: .notLoaded))
        #expect(blocked.openNow == AgentSettingsValue("Can't run agents in this build", bold: true) && !blocked.showsFolders && !blocked.showsDisconnect)
    }

    @Test func notInstalledHasNoSignInOrVersionLine() {
        let value = detail(Self.facts(state: nil, report: Self.report(installed: false)))
        #expect(value.signIn == nil && value.version == nil, "로그인할 대상이 없다")
        #expect(value.session == AgentSettingsValue("None"))
        #expect(value.showsFolders && !value.showsDisconnect)
    }

    @Test func aBuildThatCannotRunAgentsHasNoSignInVersionFoldersOrDisconnect() {
        let value = detail(Self.facts(report: nil, canRun: false, target: .notLoaded))
        #expect(value.signIn == nil && value.version == nil && value.statusFootnote == nil)
        #expect(!value.showsFolders && !value.showsDisconnect && value.session == AgentSettingsValue("None"))
    }

    @Test func checkingShowsCheckingInTheSignInLine() {
        let value = detail(Self.facts(report: nil, target: .notLoaded))
        #expect(value.signIn == AgentSettingsValue("Checking…") && value.openNow == nil)
        // probe는 왔고 대상 목록만 아직: 로그인은 이 Mac의 사실이라 보이고, 서버가 정하는 Open now는 없다
        let probeOnly = detail(Self.facts(target: .notLoaded))
        #expect(probeOnly.signIn == AgentSettingsValue("Signed in") && probeOnly.openNow == nil)
    }

    @Test func aProbeWithAnUnknownLoginShowsChecking() {
        #expect(detail(Self.facts(report: Self.report(signedIn: .unknown))).signIn == AgentSettingsValue("Checking…"))
    }

    // MARK: Status 각주: 조건마다 한 문장, 순서대로 하나만

    @Test func theStatusFootnoteIsOneSentenceInTheContractOrder() {
        let all = Self.facts(state: nil, report: Self.report(version: "1.0.88", signedIn: .no, managed: true))
        #expect(detail(all).statusFootnote == AgentSettingsCopy.signInHelp, "로그인 안 됨이 먼저")
        #expect(detail(Self.facts(state: nil, report: Self.report(installed: false, managed: true))).statusFootnote == AgentSettingsCopy.installHelp, "설치 안 됨")
        #expect(detail(Self.facts(report: Self.report(version: "1.0.88", managed: true))).statusFootnote == AgentSettingsCopy.managedSettings, "managed settings가 버전보다 먼저")
        #expect(detail(Self.facts(report: Self.report(version: "1.0.88"))).statusFootnote == AgentSettingsCopy.unsupportedVersion)
        #expect(detail(Self.facts(state: nil)).statusFootnote == AgentSettingsCopy.connectIntro, "연결 전 안내는 맨 뒤")
        #expect(detail(Self.facts(state: nil, report: Self.report(signedIn: .no))).statusFootnote == AgentSettingsCopy.signInHelp, "다른 각주가 있으면 연결 전 안내는 물러난다")
        #expect(detail(Self.facts()).statusFootnote == nil)
        #expect(detail(Self.facts(status: .revoked)).statusFootnote == nil, "Reconnect 줄에는 연결 전 안내가 없다")
    }

    @Test func anUnreadableVersionDoesNotClaimAnUnsupportedVersion() {
        #expect(detail(Self.facts(report: Self.report(version: nil))).statusFootnote == nil, "adapter가 거절한다고 말하려면 버전을 알아야 한다")
    }

    @Test func theVersionRangeFootnoteUsesTheAdaptersOwnFact() {
        #expect(ClaudeCodeSupport.supports("2.1.241") && !ClaudeCodeSupport.supports("2.2.0"))
        #expect(detail(Self.facts(report: Self.report(version: "2.2.0"))).statusFootnote == AgentSettingsCopy.unsupportedVersion)
        #expect(detail(Self.facts(report: Self.report(version: "2.1.241"))).statusFootnote == nil)
    }

    // MARK: 끊을 연결

    @Test func thereIsAConnectionToDisconnectOnlyWhenTheServerGivesARowAndTheRuntimeIsNotStuck() {
        #expect(AgentSettingsRules.hasConnection(Self.facts()))
        #expect(AgentSettingsRules.hasConnection(Self.facts(state: .signInNeeded)))
        #expect(AgentSettingsRules.hasConnection(Self.facts(report: Self.report(installed: false))), "claude를 지웠어도 서버의 연결은 있다")
        for facts in [
            Self.facts(state: nil), Self.facts(state: .notConnected), Self.facts(target: .notLoaded), Self.facts(status: .revoked), Self.facts(status: .credentialRejected),
            Self.facts(status: .tooManyBridges), Self.facts(canRun: false),
        ] {
            #expect(!AgentSettingsRules.hasConnection(facts))
        }
    }

    // MARK: T 고르기: 이 Mac의 연결 행

    @Test func thisMacsRowIsTheClaudeCodeRowWhoseBridgeIsThisMac() {
        let other = UUID()
        let theirs = AssistantTarget.Agent(adapter: "agent:claude-code", displayName: "Claude Code", connectionID: UUID(), state: .ready, access: .write, bridgeID: other, deviceName: "Studio")
        let mine = AssistantTarget.Agent(adapter: "agent:claude-code", displayName: "Claude Code", connectionID: UUID(), state: .signInNeeded, access: nil, bridgeID: Self.bridge)
        let codex = AssistantTarget.Agent(adapter: "agent:codex", displayName: "Codex", connectionID: UUID(), state: .ready, access: .write, bridgeID: Self.bridge)
        let targets: [AssistantTarget] = [.taskforce, .agent(theirs), .agent(codex), .agent(mine), .other("future")]
        #expect(AgentSettingsRules.thisMacRow(in: targets, adapter: "agent:claude-code", bridgeID: Self.bridge) == mine)
        #expect(AgentSettingsRules.thisMacRow(in: targets, adapter: "agent:claude-code", bridgeID: other) == theirs)
        #expect(AgentSettingsRules.thisMacRow(in: targets, adapter: "agent:claude-code", bridgeID: UUID()) == nil, "다른 Mac의 연결은 이 Mac의 것이 아니다")
        #expect(AgentSettingsRules.thisMacRow(in: targets, adapter: "agent:claude-code", bridgeID: nil) == nil, "이 Mac이 등록 전이면 어느 행도 이 Mac의 것이 아니다")
    }

    @Test func aRowWithNoBridgeIsNotThisMacsAndTheAnswerIsNoConnection() {
        let unconnected = AssistantTarget.Agent(adapter: "agent:claude-code", displayName: "Claude Code", connectionID: nil, state: .notConnected, access: nil)
        #expect(AgentSettingsRules.thisMacRow(in: [.agent(unconnected)], adapter: "agent:claude-code", bridgeID: Self.bridge) == nil)
        #expect(AgentSettingsRules.target(from: nil) == .none)
        #expect(AgentSettingsRules.target(from: unconnected) == .row(state: .notConnected, access: nil))
    }

    // MARK: Folders (7장)

    private let home = "/Users/daniel"

    private func project(_ name: String, icon: ProjectIconName = .folder) -> AgentFolderProject { AgentFolderProject(id: UUID(), name: name, icon: icon) }

    @Test func foldersAreOneLinePerProjectByNameThenUngroupedLast() {
        let shape = project("Shape launch", icon: .rocket)
        let acme = project("Acme website", icon: .briefcase)
        let task = project("Taskforce 0.2.0", icon: .codeXml)
        let result = AgentSettingsFolders.lines(
            folders: [shape.id: "/Users/daniel/Documents/Shape/launch", acme.id: "/Users/daniel/Projects/acme-site", task.id: "/Volumes/Work SSD/taskforce"],
            projects: [shape.id: shape, acme.id: acme, task.id: task], homes: [home], exists: { _ in true }
        )
        #expect(result.lines.map(\.name) == ["Acme website", "Shape launch", "Taskforce 0.2.0", "Ungrouped"])
        #expect(result.lines.map(\.display) == ["~/Projects/acme-site", "~/Documents/Shape/launch", "/Volumes/Work SSD/taskforce", "Ask each time"])
        #expect(result.lines.last?.isUngrouped == true && result.lines.last?.path == nil && result.lines.last?.missing == false)
        #expect(result.orphans.isEmpty)
    }

    @Test func withNoFoldersOnlyUngroupedAsksEachTime() {
        let result = AgentSettingsFolders.lines(folders: [:], projects: [:], homes: [home], exists: { _ in true })
        #expect(result.lines.map(\.display) == ["Ask each time"] && result.lines.count == 1, "Folders 절은 늘 보인다: 처음에는 Ungrouped 한 줄")
    }

    @Test func aFolderThatIsGoneIsMarkedMissingAndKept() {
        let acme = project("Acme website")
        let result = AgentSettingsFolders.lines(folders: [acme.id: "/Users/daniel/gone"], projects: [acme.id: acme], homes: [home], exists: { _ in false })
        #expect(result.lines.first?.missing == true && result.lines.first?.path == "/Users/daniel/gone", "자동으로 지우지 않는다")
        #expect(result.orphans.isEmpty)
    }

    @Test func aDeletedProjectsFolderIsACleanupNotALine() {
        let known = project("Known")
        let gone = UUID()
        let result = AgentSettingsFolders.lines(
            folders: [known.id: "/Users/daniel/a", gone: "/Users/daniel/b"], projects: [known.id: known], homes: [home], exists: { _ in true }
        )
        #expect(result.lines.map(\.name) == ["Known", "Ungrouped"] && result.orphans == [gone])
    }

    @Test func whenTheProjectsAreNotKnownYetNoNameIsInventedAndNothingIsCleanedUp() {
        let id = UUID()
        let result = AgentSettingsFolders.lines(folders: [id: "/Users/daniel/a"], projects: nil, homes: [home], exists: { _ in true })
        #expect(result.lines.map(\.name) == ["Ungrouped"] && result.orphans.isEmpty, "이름을 모르면 줄도 정리도 없다")
    }

    @Test func anArchivedProjectKeepsItsArchivedSuffix() {
        let context = WorkContext(id: UUID(), name: "Old launch", status: .archived, contextVersion: 1, icon: .rocket, version: 1)
        #expect(AgentFolderProject(context).name == "Old launch · Archived" && AgentFolderProject(context).icon == .rocket)
    }

    @Test func pathsShowTheHomeAsATildeAndLongOnesAreCutInTheMiddle() {
        #expect(AgentSettingsPath.display("/Users/daniel", homes: [home]) == "~")
        #expect(AgentSettingsPath.display("/Users/daniel/Documents/Shape", homes: [home]) == "~/Documents/Shape")
        #expect(AgentSettingsPath.display("/Users/danielle/Documents", homes: [home]) == "/Users/danielle/Documents", "이름이 같은 글자로 시작하는 다른 사용자는 줄이지 않는다")
        #expect(AgentSettingsPath.display("/Volumes/Work SSD/app", homes: [home]) == "/Volumes/Work SSD/app")
        #expect(AgentSettingsPath.display("/private/Users/daniel/x", homes: ["/private/Users/daniel", home]) == "~/x", "홈의 realpath도 줄인다")
        let long = "/Users/daniel/Documents/Clients/Northwind Traders/2026/Marketing site/brand refresh/source/final/export/archive/older/oldest/deep/deeper/deepest"
        let shown = AgentSettingsPath.display(long, homes: [home])
        #expect(shown.count == AgentSettingsPath.maxLength && shown.hasPrefix("~/Documents/Clients") && shown.hasSuffix("deeper/deepest") && shown.contains("…"), "가운데를 줄인다: \(shown)")
    }

    @Test func middleTruncationKeepsTheBothEndsAndNeverSplitsACharacter() {
        let text = String(repeating: "가", count: 10) + "🇰🇷" + String(repeating: "나", count: 10)
        let cut = AgentSettingsPath.middleTruncated(text, limit: 9)
        #expect(cut.count == 9 && cut.contains("…") && cut.hasPrefix("가가가가") && cut.hasSuffix("나나나나"))
        #expect(AgentSettingsPath.middleTruncated("short", limit: 9) == "short")
        #expect(AgentSettingsPath.middleTruncated("abc", limit: 2) == "abc", "너무 작은 한도는 자르지 않는다")
    }

    // MARK: Macs (6.4)

    private func mac(_ n: Int, name: String? = nil, seen: TimeInterval? = nil, base: Date = Date(timeIntervalSince1970: 1_800_000_000)) -> AgentMacRecord {
        AgentMacRecord(id: UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", n))!, deviceName: name, lastHeartbeatAt: seen.map { base.addingTimeInterval(-$0) })
    }

    @Test func theMacListIsOldestFirstWithoutThisMac() {
        let mine = mac(9, name: "Mine", seen: 0)
        let list = AgentSettingsMacs.rows([mac(1, name: "Recent", seen: 240), mine, mac(2, name: "Old", seen: 86_400 * 9), mac(3, name: nil, seen: nil), mac(4, name: "Mid", seen: 3600)], excluding: mine.id)
        #expect(list.map { AgentSettingsMacs.title($0) } == ["Mac", "Old", "Mid", "Recent"], "본 적 없는 Mac이 맨 위, 이 Mac은 없다")
        #expect(!list.contains { $0.id == mine.id }, "10대 안에 이 Mac이 없다")
    }

    @Test func theMacListIsStableWhenTimesTie() {
        let a = mac(1, name: "A", seen: 60)
        let b = mac(2, name: "B", seen: 60)
        #expect(AgentSettingsMacs.rows([b, a], excluding: nil).map(\.id) == [a.id, b.id])
        #expect(AgentSettingsMacs.rows([mac(2), mac(1)], excluding: nil).map(\.id.uuidString) == [mac(1).id.uuidString, mac(2).id.uuidString])
    }

    @Test func aMacWithoutANameIsCalledMacAndDescribesItsLastSeenTime() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(AgentSettingsMacs.title(mac(1)) == "Mac" && AgentSettingsMacs.title(mac(1, name: "")) == "Mac")
        #expect(AgentSettingsMacs.detail(mac(1, seen: 240, base: now), now: now) == "Last seen 4 min ago")
        #expect(AgentSettingsMacs.detail(mac(1, seen: 86_400 * 6, base: now), now: now) == "Last seen 6 days ago")
        #expect(AgentSettingsMacs.detail(mac(1), now: now) == nil, "본 적을 모르면 설명이 없다 (새 문구를 만들지 않는다)")
    }

    @Test func aBridgesRowDecodesFromTheServerShapeAndAMalformedDateDoesNotBlockTheList() throws {
        let json = """
        [{"id":"b1111111-1111-4111-8111-111111111111","device_name":"Studio","last_heartbeat_at":"2026-10-18T05:00:00.123456+00:00","app_version":"0.2.0"},
         {"id":"b2222222-2222-4222-8222-222222222222","device_name":null,"last_heartbeat_at":"garbage","app_version":null},
         {"id":"b3333333-3333-4333-8333-333333333333","device_name":null,"last_heartbeat_at":null}]
        """
        let rows = try TaskforceJSON.decoder().decode([AgentMacRecord].self, from: Data(json.utf8))
        #expect(rows.count == 3 && rows[0].deviceName == "Studio" && rows[0].lastHeartbeatAt != nil)
        #expect(rows[1].lastHeartbeatAt == nil && rows[1].deviceName == nil && rows[2].lastHeartbeatAt == nil)
        #expect(AgentMacRecord.columns == "id, device_name, last_heartbeat_at, app_version", "읽는 열은 이 넷뿐 (secret_hash · heartbeat_result는 읽지 않는다)")
    }
}
#endif
