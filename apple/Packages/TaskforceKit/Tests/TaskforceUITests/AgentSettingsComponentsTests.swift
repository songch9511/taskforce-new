#if os(macOS)
import AppKit
import SwiftUI
import Testing
import TaskforceKit
@testable import TaskforceUI

/// Settings › Your agents의 부품 (OA Settings › Your agents 14.2): 접근성 이름(줄 + 상태 + 동작) · 굵은 말 · 빨강 0 · 긴 내용이 폭을 넘지 않는다
struct AgentSettingsComponentsTests {
    typealias Facts = AgentSettingsFacts

    static func report(installed: Bool = true, signedIn: BridgeV1SignedIn = .yes) -> BridgeV1AdapterReport {
        BridgeV1AdapterReport(adapter: "agent:claude-code", installed: installed, version: installed ? "2.1.241" : nil, signedIn: signedIn, managedSettings: false)
    }

    static func line(state: AgentTargetState? = .ready, status: BridgeStatus? = .connected, installed: Bool = true, live: Bool = false) -> AgentSettingsLine {
        AgentSettingsRules.line(Facts(
            canRunAgents: true, status: status, hasLiveProcess: live, report: report(installed: installed),
            target: state.map { .row(state: $0, access: .write) } ?? .none
        ))
    }

    // MARK: 접근성 이름: 줄 + 상태 (+ 실패 줄), 동작은 버튼이 자기 이름으로

    @Test func theRowNameIsTheAgentTheStateAndTheFailureLine() {
        #expect(AgentRow.accessibilityName(Self.line(state: nil)) == "Claude Code, Not connected")
        #expect(AgentRow.accessibilityName(Self.line(state: nil), hint: "Something went wrong. Try again in a moment.") == "Claude Code, Not connected, Something went wrong. Try again in a moment.")
        #expect(AgentRow.accessibilityName(Self.line(live: true)) == "Claude Code, Signed in · Session active")
        #expect(AgentRow.accessibilityName(Self.line(installed: false)) == "Claude Code, Not installed")
    }

    @Test func theButtonNamesTheActionAndTheAgent() {
        #expect(AgentRow.actionName(Self.line(state: nil)) == "Connect Claude Code")
        #expect(AgentRow.actionName(Self.line(status: .revoked)) == "Reconnect Claude Code")
        #expect(AgentRow.actionName(Self.line()) == nil, "Level은 동작이 아니라 값이다")
        #expect(AgentRow.actionName(Self.line(installed: false)) == nil)
    }

    @Test func aFolderRowNamesItsProjectItsPathAndWhetherItIsMissing() {
        let project = AgentFolderProject(id: UUID(), name: "Acme website", icon: .briefcase)
        let present = AgentSettingsFolders.lines(folders: [project.id: "/Users/alex/acme"], projects: [project.id: project], homes: ["/Users/alex"], exists: { _ in true }).lines
        let gone = AgentSettingsFolders.lines(folders: [project.id: "/Users/alex/acme"], projects: [project.id: project], homes: ["/Users/alex"], exists: { _ in false }).lines
        #expect(AgentFolderRow.accessibilityName(present[0]) == "Acme website, ~/acme")
        #expect(AgentFolderRow.accessibilityName(gone[0]) == "Acme website, ~/acme, Missing")
        #expect(AgentFolderRow.accessibilityName(present[1]) == "Ungrouped, Ask each time")
    }

    // MARK: 색 0 · 굵은 말

    /// 이 파일은 빨강을 쓰지 않는다 (실패 줄은 조용한 회색 힌트 톤): 상태 색 · 시스템 빨강 · 임의의 색 리터럴이 소스에 없다
    @Test func theComponentsNeverUseRedOrAnyNewColor() throws {
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Sources/TaskforceUI/AgentSettingsComponents.swift"), encoding: .utf8)
        for forbidden in ["statusOverdue", ".red", "Color.red", "NSColor.red", "Color(red", "Color(.sRGB", "systemRed", "TFColor.status"] {
            #expect(!source.contains(forbidden), "\(forbidden)")
        }
        // 색은 토큰으로만: `TFColor.`가 아닌 `Color` 값은 쓰지 않는다 (타입 이름 `Color`는 `secondary` 한 곳)
        let colorLiterals = source.components(separatedBy: "Color(").count - 1
        #expect(colorLiterals == 0, "Color(...) 리터럴 \(colorLiterals)")
    }

    @Test func onlyTheDesignedValuesAreBold() {
        #expect(AgentSettingsValue("Unsupported", bold: true).bold && !AgentSettingsValue("Can write").bold)
        let line = Self.line(installed: false)
        #expect(line.bold, "Not installed는 굵다")
        #expect(!Self.line(state: nil).bold, "연결 없음은 굵지 않다")
    }

    // MARK: 긴 내용은 본 화면에서: 폭을 넘지 않는다

    @MainActor
    private func fitting<V: View>(_ view: V, width: CGFloat = 520) -> CGSize {
        let host = NSHostingView(rootView: view.frame(width: width))
        host.frame = NSRect(x: 0, y: 0, width: width, height: 2000)
        host.layoutSubtreeIfNeeded()
        return host.fittingSize
    }

    @MainActor
    @Test func aVeryLongProjectNameWrapsAndAVeryLongPathStaysOnOneLineInsideTheWidth() {
        let shortProject = AgentFolderProject(id: UUID(), name: "Acme", icon: .briefcase)
        let longProject = AgentFolderProject(id: UUID(), name: String(repeating: "Northwind Traders 2026 website relaunch and brand refresh ", count: 4), icon: .briefcase)
        let longPath = "/Users/alex/Documents/Clients/Northwind Traders/2026/Marketing site/brand refresh/source/final/export/archive/older/oldest"
        func row(_ project: AgentFolderProject, path: String) -> AgentFolderLine {
            AgentSettingsFolders.lines(folders: [project.id: path], projects: [project.id: project], homes: ["/Users/alex"], exists: { _ in true }).lines[0]
        }
        let short = fitting(AgentFolderRow(line: row(shortProject, path: "/Users/alex/a")))
        let longName = fitting(AgentFolderRow(line: row(longProject, path: "/Users/alex/a")))
        let longPathRow = fitting(AgentFolderRow(line: row(shortProject, path: longPath)))
        #expect(short.height >= SettingsTray.rowMinHeight && short.height < 60, "한 줄 행")
        #expect(longName.height > short.height + 20, "긴 이름은 줄바꿈한다 (잘리지 않는다)")
        #expect(longPathRow.height < 60, "긴 경로는 한 줄에서 가운데를 줄인다")
        #expect(short.width <= 520 && longName.width <= 520 && longPathRow.width <= 520, "폭 밖으로 나가지 않는다")
    }

    @MainActor
    @Test func theFailureLineMakesTheRowTallerButStaysInsideTheWidth() {
        let plain = fitting(AgentRow(line: Self.line(state: nil), onOpen: {}))
        let failed = fitting(AgentRow(line: Self.line(state: nil), hint: AgentSettingsCopy.somethingWentWrong, onOpen: {}))
        #expect(failed.height > plain.height && failed.width <= 520)
    }

    @MainActor
    @Test func everyRowKindRendersAtTheWindowWidth() {
        let kinds: [AgentSettingsLine] = [
            Self.line(state: nil), Self.line(status: .revoked), Self.line(status: .tooManyBridges), Self.line(installed: false), Self.line(state: .signInNeeded),
            Self.line(state: .unreachable), Self.line(live: true),
            AgentSettingsRules.line(Facts(canRunAgents: false)), AgentSettingsRules.line(Facts(canRunAgents: true)),
        ]
        for line in kinds {
            #expect(fitting(AgentRow(line: line, busy: true, onOpen: {})).height >= SettingsTray.rowMinHeight, "\(line.kind)")
            #expect(fitting(AgentDetailHeader(line: line, busy: true, hint: "x")).height > 30, "\(line.kind)")
        }
    }
}
#endif
