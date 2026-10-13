import Foundation
import Testing
@testable import Taskforce

/// 시험 호스트 판정 (`TestHost`): 앱을 호스트로 띄우는 Mac 시험에서 실제 계정 · 알림 · 전역 단축키 · 설정 이전을 시작하지 않으려고
/// `TaskforceApp.init`과 `MacAppDelegate.applicationDidFinishLaunching`이 같은 한 곳을 부른다.
struct TestHostTests {
    @Test func theXCTestConfigurationVariableMarksATestHost() {
        #expect(TestHost.isTestHost(environment: ["XCTestConfigurationFilePath": "/tmp/x.xctestconfiguration"], testCaseClassLoaded: false))
    }

    @Test func aLoadedXCTestCaseClassMarksATestHost() {
        #expect(TestHost.isTestHost(environment: [:], testCaseClassLoaded: true))
    }

    @Test func neitherSignalIsNotATestHost() {
        #expect(!TestHost.isTestHost(environment: [:], testCaseClassLoaded: false))
        #expect(!TestHost.isTestHost(environment: ["PATH": "/usr/bin", "XCTestConfiguration": "x"], testCaseClassLoaded: false))
    }

    /// 지금 이 시험이 도는 프로세스가 실제로 시험 호스트다
    @Test func thisProcessIsATestHost() {
        #expect(TestHost.isTestHost())
    }

    /// 앱 시작이 설정 이전기에 넘기는 빌드 종류: 이 시험 호스트는 Debug 설정(`Debug-Test`)이라 true이고, 실행 인자 `-TF_LEGACY_MIGRATION`은 없다.
    /// `TaskforceApp.init`이 직접 쓴 상수가 아니라 이 값을 그대로 넘기는지도 본다 (Debug 분기를 `false`로 바꿔도 다른 시험이 모두 통과하던 구멍)
    @Test func theMigrationIsToldTheRealBuildKind() throws {
        #expect(AppRuntime.isDebugBuild)
        #expect(!AppRuntime.legacyMigrationDebugOptIn)
        let apple = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: apple.appending(path: "Taskforce/TaskforceApp.swift"), encoding: .utf8)
        #expect(source.contains("isDebugBuild: AppRuntime.isDebugBuild") && source.contains("debugOptIn: AppRuntime.legacyMigrationDebugOptIn"))
    }

    /// 판정이 앱 소스 두 곳에 다시 복사되지 않는다 (복사하면 한쪽만 고쳐져 시험 호스트가 실제 설정 도메인을 만든다)
    @Test func theCheckLivesOnlyInTheSharedHelper() throws {
        let apple = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        guard let enumerator = FileManager.default.enumerator(at: apple.appending(path: "Taskforce"), includingPropertiesForKeys: nil) else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        var files: [String] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            if try String(contentsOf: url, encoding: .utf8).contains("XCTestConfigurationFilePath") {
                files.append(String(url.path.dropFirst(apple.path.count + 1)))
            }
        }
        #expect(files == ["Taskforce/Shared/TestHost.swift"])
    }
}
