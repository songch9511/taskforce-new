import Foundation
import Testing
@testable import TaskforceKit
@testable import Taskforce

/// 설정 · 게이트 · 이름 보내기 가드 (OA Settings › Your agents 9 · 10 · 11장): 새 플래그 0 · Taskforce Agent 목적 글 다섯 키 · Mac 이름은 보내도 되는 빌드에서만
@MainActor
struct SettingsAgentsConfigTests {
    private let partition = BridgePartition(apiOrigin: "https://x.test", userID: UUID())

    // MARK: F1m 가드

    @Test func aDebugBuildPointedAtAProductionServerNeverGetsANameProvider() throws {
        let production = try #require(URL(string: "https://api.taskforcelabs.dev"))
        let configuration = BridgeHost.runtimeConfiguration(partition: partition, appVersion: "0.2.0", mode: .normal, isDebugBuild: true, apiBaseURL: production)
        #expect(configuration.deviceName == nil, "개발 빌드가 운영 서버로 이름을 보내지 않는다")
    }

    @Test func aDebugBuildOnALoopbackServerAndReleaseGetTheNameProvider() throws {
        let local = try #require(URL(string: "http://localhost:3000"))
        let production = try #require(URL(string: "https://api.taskforcelabs.dev"))
        #expect(BridgeHost.runtimeConfiguration(partition: partition, appVersion: "0.2.0", mode: .normal, isDebugBuild: true, apiBaseURL: local).deviceName != nil)
        #expect(BridgeHost.runtimeConfiguration(partition: partition, appVersion: "0.2.0", mode: .normal, isDebugBuild: false, apiBaseURL: production).deviceName != nil, "Release는 bridge가 켜진 빌드(L5)에서만 런타임이 있다")
        #expect(BridgeHost.runtimeConfiguration(partition: partition, appVersion: "0.2.0", mode: .drain, isDebugBuild: false, apiBaseURL: production).mode == .drain)
    }

    // MARK: Taskforce Agent 목적 글

    private func projectYML() throws -> String {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appending(path: "project.yml")
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// 다섯 키가 승인된 같은 한 문장이다 (macOS 폴더 권한 창이 "Taskforce Agent" 이름으로 이 글을 보인다)
    @Test func theTaskforceAgentTargetHasTheFiveFolderPurposeKeysWithTheApprovedSentence() throws {
        let yml = try projectYML()
        let target = try #require(yml.range(of: "  TaskforceAgent:\n").map { String(yml[$0.lowerBound...]) })
        let block = String(target.prefix(upTo: target.range(of: "  # 시험 전용 가짜")?.lowerBound ?? target.endIndex))
        let keys = ["NSDocumentsFolderUsageDescription", "NSDesktopFolderUsageDescription", "NSDownloadsFolderUsageDescription", "NSRemovableVolumesUsageDescription", "NSNetworkVolumesUsageDescription"]
        for key in keys {
            #expect(block.contains("INFOPLIST_KEY_\(key): \"\(AgentSettingsCopy.agentPurpose)\""), "\(key)")
        }
        #expect(block.components(separatedBy: "UsageDescription").count - 1 == 5, "다섯 키뿐이다")
        #expect(AgentSettingsCopy.agentPurpose == "Taskforce Agent runs Claude Code in the folders you choose for your projects.")
    }

    @Test func theMainAppAndOtherTargetsGetNoFolderPurposeKeys() throws {
        let yml = try projectYML()
        let agent = try #require(yml.range(of: "  TaskforceAgent:\n"))
        let end = try #require(yml.range(of: "  # 시험 전용 가짜", range: agent.upperBound..<yml.endIndex))
        let outside = String(yml[..<agent.lowerBound]) + String(yml[end.lowerBound...])
        #expect(!outside.contains("UsageDescription"), "권한 창이 뜨는 책임 프로세스는 helper \"Taskforce Agent\" 하나다")
    }

    // MARK: 게이트: 새 플래그 0

    @Test func thereIsNoNewFlagForTheAgentsSettings() throws {
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appending(path: "Taskforce", directoryHint: .isDirectory)
        let files = try #require(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        var offenders: [String] = []
        for case let url as URL in files where url.pathExtension == "swift" {
            let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            if text.contains("TF_AGENTS_SETTINGS") || text.contains("AgentsSettingsFlag") { offenders.append(url.lastPathComponent) }
        }
        #expect(offenders.isEmpty, "새 플래그 0 (SA-09): \(offenders)")
    }
}
