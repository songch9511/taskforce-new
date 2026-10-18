import Foundation
import Testing
import TaskforceKit
@testable import Taskforce

/// App Translocation (재검토 1, 보안 N1, 코디네이터 13.12): 격리 표시가 붙은 앱이 옮겨진 읽기 전용 경로로 실행되면 원래 번들 경로도 보호하고, 원래 경로를 모르면 Claude Code adapter를 만들지 않는다.
/// 번들 URL과 원래 경로 구하기는 시험이 넣는다 (실제 시스템 호출은 마지막 시험 하나뿐이고 읽기만 한다). 실제 `claude` · 폴더 창 0
@MainActor
struct ProjectWorkspacesTranslocationTests {
    /// 임시 폴더 안의 홈: `Downloads/Taskforce.app`(원래 번들)과 `var/AppTranslocation/<UUID>/d/Taskforce.app`(옮겨진 뷰 — 시험에서는 원래 번들로 가는 기호 링크)
    private struct Layout {
        let temp: URL
        let home: String
        let original: URL
        let translocated: URL

        init() throws {
            temp = FileManager.default.temporaryDirectory.appending(path: "translocation-\(UUID().uuidString)", directoryHint: .isDirectory)
            home = temp.appending(path: "home").path
            original = temp.appending(path: "home/Downloads/Taskforce.app", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: original.appending(path: "Contents/Helpers"), withIntermediateDirectories: true)
            let view = temp.appending(path: "var/AppTranslocation/\(UUID().uuidString)/d", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: view, withIntermediateDirectories: true)
            translocated = view.appending(path: "Taskforce.app", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: translocated.appending(path: "Contents/Helpers"), withIntermediateDirectories: true)
        }

        func cleanup() { try? FileManager.default.removeItem(at: temp) }
        func real(_ url: URL) -> String { GateFileSystem.realpath(url.path) ?? url.path }
    }

    private func translocation(_ yes: Bool?, original: String?) -> AppTranslocation {
        AppTranslocation(isTranslocated: { _ in yes }, originalPath: { _ in original })
    }

    @Test func aBundleThatIsNotTranslocatedProtectsOnlyItsOwnRealPath() throws {
        let layout = try Layout()
        defer { layout.cleanup() }
        let protection = AppBundleProtection(bundleURL: layout.original, translocation: translocation(false, original: layout.original.path))
        #expect(protection.roots.map(\.path) == [layout.real(layout.original)] && !protection.failClosed)
    }

    @Test func aTranslocatedBundleAlsoProtectsTheOriginalPathsRealPath() throws {
        let layout = try Layout()
        defer { layout.cleanup() }
        let protection = AppBundleProtection(bundleURL: layout.translocated, translocation: translocation(true, original: layout.original.path))
        #expect(protection.roots.map(\.path) == [layout.real(layout.translocated), layout.real(layout.original)])
        #expect(!protection.failClosed)
    }

    @Test func theTranslocationPathComponentCountsEvenWhenTheSystemCallCannotAnswer() throws {
        let layout = try Layout()
        defer { layout.cleanup() }
        // 시스템 호출이 답하지 못해도(nil) 경로 성분 `AppTranslocation`이 있으면 옮겨진 실행으로 본다
        let withOriginal = AppBundleProtection(bundleURL: layout.translocated, translocation: translocation(nil, original: layout.original.path))
        #expect(withOriginal.roots.count == 2 && !withOriginal.failClosed)
        let withoutOriginal = AppBundleProtection(bundleURL: layout.translocated, translocation: translocation(nil, original: nil))
        #expect(withoutOriginal.failClosed, "원래 경로를 구하지 못하면 닫는다")
        // 시스템 호출이 "옮겨지지 않았다"고 해도 경로가 옮겨진 뷰면 닫는다 (더 보수적인 쪽)
        #expect(AppBundleProtection(bundleURL: layout.translocated, translocation: translocation(false, original: nil)).failClosed)
        // 옮겨진 경로가 아니고 시스템 호출도 답하지 못하면 옮겨지지 않은 것으로 본다
        #expect(!AppBundleProtection(bundleURL: layout.original, translocation: translocation(nil, original: nil)).failClosed)
    }

    @Test func anOriginalPathThatCannotBeUsedFailsClosed() throws {
        let layout = try Layout()
        defer { layout.cleanup() }
        for original in [nil, "", "Downloads/Taskforce.app", layout.translocated.path] as [String?] {
            let protection = AppBundleProtection(bundleURL: layout.translocated, translocation: translocation(true, original: original))
            #expect(protection.failClosed, "\(String(describing: original))")
            #expect(protection.roots.map(\.path) == [layout.real(layout.translocated)], "알 수 없는 원래 경로는 더하지 않는다")
        }
    }

    @Test func theOriginalFolderAndTheFoldersHoldingItAreRefusedAsWorkFoldersWhenTheBundleIsTranslocated() throws {
        let layout = try Layout()
        defer { layout.cleanup() }
        let support = layout.temp.appending(path: "home/AppData", directoryHint: .isDirectory)
        let root = support.appending(path: "dev.taskforcelabs.unittest.taskforce/Bridge/v1", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: layout.home + "/Documents/client-a", withIntermediateDirectories: true)
        let protection = AppBundleProtection(bundleURL: layout.translocated, translocation: translocation(true, original: layout.original.path))
        let home = layout.home
        let rules = WorkspaceFolderRules(home: home, systemRoots: [], protectedRoots: ProjectWorkspaces.protectedRoots(support: support, bundleID: "dev.taskforcelabs.unittest.taskforce", root: root, bundle: protection).map(\.path))
        func refused(_ path: String) -> Bool { if case .failure = rules.validate(path) { true } else { false } }
        #expect(refused(layout.home + "/Downloads"), "원래 번들을 품은 ~/Downloads")
        #expect(refused(layout.original.path) && refused(layout.original.path + "/Contents/Helpers"))
        #expect(!refused(layout.home + "/Documents/client-a"))
        // 보호 루트에 원래 경로를 더하지 않았다면(변이) 막지 못한다는 것을 보이는 대조
        let withoutOriginal = WorkspaceFolderRules(home: home, systemRoots: [], protectedRoots: [layout.translocated.path])
        if case .success = withoutOriginal.validate(layout.home + "/Downloads") {} else { Issue.record("대조: 원래 경로 없이는 ~/Downloads를 받아야 한다") }
    }

    @Test func theHostCreatesNoClaudeCodeAdapterWhenTheOriginalBundleCannotBeProtected() throws {
        let layout = try Layout()
        defer { layout.cleanup() }
        var made = 0
        let closed = AppBundleProtection(bundleURL: layout.translocated, translocation: translocation(true, original: nil))
        #expect(BridgeHost.claudeCodeAdapter(bundle: closed, make: { made += 1; return made }) == nil && made == 0, "닫힌 실행은 adapter를 만들지 않는다")
        let known = AppBundleProtection(bundleURL: layout.translocated, translocation: translocation(true, original: layout.original.path))
        #expect(BridgeHost.claudeCodeAdapter(bundle: known, make: { made += 1; return made }) == 1)
        let plain = AppBundleProtection(bundleURL: layout.original, translocation: .notTranslocated)
        #expect(BridgeHost.claudeCodeAdapter(bundle: plain, make: { made += 1; return made }) == 2)
    }

    @Test func theLiveSystemCallsAnswerForThisTestHostWithoutCrashing() {
        let url = Bundle.main.bundleURL
        let answer = AppTranslocation.live.isTranslocated(url)
        #expect(answer == false || answer == nil, "시험 호스트는 옮겨지지 않았다: \(String(describing: answer))")
        // 옮겨지지 않은 번들의 원래 경로는 없거나 자기 자신이다 — 어느 쪽이든 죽지 않는다
        _ = AppTranslocation.live.originalPath(url)
        #expect(!AppBundleProtection(bundleURL: url).failClosed)
    }
}
