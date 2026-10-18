#if os(macOS) && DEBUG
import Foundation
import Testing
@testable import TaskforceKit

/// 작업 폴더 거절 규칙 (OA D4a2-04, 계약 13.6 "거절 규칙"): 표의 모든 줄 + 기호 링크로 우회 + 다른 소유자 + 파일
struct WorkspaceRegistryRulesTests {
    static let home = "/Users/tester"
    static let me: UInt32 = 501

    /// 파일 시스템 없이 글자만 보는 사실 (모든 경로가 디렉터리이고 내 것이다)
    static func facts(owner: UInt32 = me, directory: Bool = true, missing: Set<String> = []) -> WorkspaceFolderRules.Facts {
        WorkspaceFolderRules.Facts(
            realpath: { missing.contains($0) ? nil : $0 }, inspect: { _ in (directory, owner) }, userID: me
        )
    }

    static func standard(protected: [String] = [], facts: WorkspaceFolderRules.Facts = facts()) -> WorkspaceFolderRules {
        WorkspaceFolderRules(
            home: home, systemRoots: ["/System", "/Library", "/Applications", "/usr", "/bin", "/sbin", "/private"], protectedRoots: protected, facts: facts
        )
    }

    private func rejection(_ path: String, rules: WorkspaceFolderRules = standard()) -> WorkspaceFolderRules.Rejection? {
        if case .failure(let why) = rules.validate(path) { return why }
        return nil
    }

    @Test func rootTheHomeFolderAndItsAncestorsAreRejected() {
        #expect(rejection("/") == .root)
        #expect(rejection("/Users") == .homeOrAncestor)
        #expect(rejection(Self.home) == .homeOrAncestor)
    }

    @Test func theLibraryAndTheClaudeFolderAndEverythingInsideThemAreRejected() {
        #expect(rejection(Self.home + "/Library") == .userLibrary)
        #expect(rejection(Self.home + "/Library/Application Support/dev.taskforcelabs.taskforce/Bridge") == .userLibrary)
        #expect(rejection(Self.home + "/.claude") == .claudeConfig)
        #expect(rejection(Self.home + "/.claude/projects/x") == .claudeConfig)
    }

    @Test func theSystemFoldersAndEverythingInsideThemAreRejected() {
        for path in ["/System", "/System/Library", "/Library", "/Library/Foo", "/Applications", "/Applications/Xcode.app", "/usr", "/usr/local/bin", "/bin", "/sbin", "/private", "/private/tmp", "/private/var/folders/x"] {
            #expect(rejection(path) == .system, "\(path)")
        }
    }

    @Test func theVolumesFolderItselfIsRejectedButAFolderOnAnExternalDriveIsAllowed() {
        #expect(rejection("/Volumes") == .volumesRoot)
        #expect(rejection("/Volumes/Disk/project") == nil)
        #expect(rejection("/Volumes/Disk") == nil)
    }

    @Test func aFolderUnderTheHomeFolderIsAllowed() throws {
        let real = try #require(try? Self.standard().validate(Self.home + "/Documents/client-a").get())
        #expect(real == Self.home + "/Documents/client-a")
    }

    @Test func aFolderOutsideTheHomeFolderAndTheExternalDrivesIsRejected() {
        #expect(rejection("/opt/project") == .outsideAllowedAreas)
        #expect(rejection("/Users/someone-else/project") == .outsideAllowedAreas)
    }

    @Test func theAppDataFoldersAndTheFoldersThatContainThemAreRejected() {
        // 앱 데이터가 홈 밖(외장 볼륨)에 있어도: 그 안, 그것을 품는 폴더 모두 거절한다 (보안 재검토 3 F7)
        let rules = Self.standard(protected: ["/Volumes/Disk/app/Bridge/v1"])
        #expect(rejection("/Volumes/Disk/app/Bridge/v1", rules: rules) == .appData)
        #expect(rejection("/Volumes/Disk/app/Bridge/v1/claude-code/session/cwd", rules: rules) == .appData)
        #expect(rejection("/Volumes/Disk/app/Bridge", rules: rules) == .appData, "앱 데이터를 품는 폴더")
        #expect(rejection("/Volumes/Disk/app", rules: rules) == .appData)
        #expect(rejection("/Volumes/Disk", rules: rules) == .appData)
        #expect(rejection("/Volumes/Disk/other", rules: rules) == nil, "형제 폴더는 받는다")
        #expect(rejection("/Volumes/Disk/app-other", rules: rules) == nil, "글자 접두가 같은 형제는 받는다 (경로 성분으로 본다)")
    }

    @Test func aFolderThatIsNotMineIsRejected() {
        let rules = Self.standard(facts: Self.facts(owner: 0))
        #expect(rejection(Self.home + "/Documents/p", rules: rules) == .notOwnedByUser)
    }

    @Test func aFileOrAMissingPathOrARelativePathIsRejected() {
        #expect(rejection(Self.home + "/Documents/file.txt", rules: Self.standard(facts: Self.facts(directory: false))) == .notADirectory)
        #expect(rejection(Self.home + "/Documents/gone", rules: Self.standard(facts: Self.facts(missing: [Self.home + "/Documents/gone"]))) == .notFound)
        #expect(rejection("Documents/p") == .notAbsolute)
        #expect(rejection("") == .notAbsolute)
        #expect(rejection(Self.home + "/a\u{0}b") == .notAbsolute)
    }

    // MARK: 실제 파일 시스템: 기호 링크로 우회할 수 없다

    private func realRules(_ temp: TempDirectory) throws -> (rules: WorkspaceFolderRules, home: String, outside: String) {
        let home = temp.appending("home")
        let outside = temp.appending("outside")
        for path in [home.appending(path: "Library/Application Support"), home.appending(path: ".claude"), home.appending(path: "Documents/project"), outside] {
            try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        }
        // 이 시험의 "시스템 폴더"는 임시 폴더 안의 sys다
        let system = temp.appending("sys")
        try FileManager.default.createDirectory(at: system.appending(path: "usr"), withIntermediateDirectories: true)
        let rules = WorkspaceFolderRules(home: home.path, systemRoots: [system.path], volumesRoot: outside.path)
        return (rules, home.path, outside.path)
    }

    @Test func aSymlinkInsideTheHomeFolderThatPointsAtTheLibraryOrTheSystemIsRejectedByItsRealPath() throws {
        let temp = TempDirectory()
        let (rules, home, _) = try realRules(temp)
        let toLibrary = home + "/Documents/looks-fine"
        try FileManager.default.createSymbolicLink(atPath: toLibrary, withDestinationPath: home + "/Library/Application Support")
        let toClaude = home + "/Documents/dotclaude"
        try FileManager.default.createSymbolicLink(atPath: toClaude, withDestinationPath: home + "/.claude")
        let toSystem = home + "/Documents/system"
        try FileManager.default.createSymbolicLink(atPath: toSystem, withDestinationPath: temp.appending("sys/usr").path)
        for link in [toLibrary, toClaude, toSystem] {
            if case .success = rules.validate(link) { Issue.record("기호 링크로 우회했다: \(link)") }
        }
        if case .failure(let why) = rules.validate(toLibrary) { #expect(why == .userLibrary) }
        if case .failure(let why) = rules.validate(toSystem) { #expect(why == .system) }
        // 같은 폴더를 가리키지 않는 평범한 폴더는 받는다
        if case .failure(let why) = rules.validate(home + "/Documents/project") { Issue.record("받아야 할 폴더가 거절됐다: \(why)") }
    }

    @Test func aRealFileIsRejectedAsNotADirectory() throws {
        let temp = TempDirectory()
        let (rules, home, _) = try realRules(temp)
        let file = home + "/Documents/notes.txt"
        FileManager.default.createFile(atPath: file, contents: Data("x".utf8))
        if case .failure(let why) = rules.validate(file) { #expect(why == .notADirectory) } else { Issue.record("파일을 받았다") }
    }

    @Test func theRealFolderIsReturnedWithItsSymlinksResolved() throws {
        let temp = TempDirectory()
        let (rules, home, _) = try realRules(temp)
        let link = home + "/Documents/alias"
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: home + "/Documents/project")
        let real = try #require(try? rules.validate(link).get())
        #expect(real.hasSuffix("/home/Documents/project") && !real.hasSuffix("alias"))
    }
}
#endif
