#if os(macOS) && DEBUG
import Darwin
import Foundation
import Testing
@testable import TaskforceKit

/// 세기 · 빼기 · 확인 · 안전 (계약 5.1–5.3 · T1–T4 · T8, 시험은 임시 폴더의 가짜 홈만 읽는다)
struct ExternalSessionScannerTests {
    typealias F = ExternalSessionFixture
    static let now = Date()
    static let key = ExternalSessionKey(bytes: Data(repeating: 9, count: 32))

    /// 가짜 홈 + 그 위의 스캐너. 폴더 규칙은 가짜 사실(모든 폴더가 내 디렉터리)로 본다
    struct World {
        let home: ExternalHome
        var cwd: String { home.home + "/proj" }
        var dirName: String { ExternalSessionRules.projectDirectoryName(forCwd: cwd) ?? "" }

        func rules(missing: Set<String> = []) -> WorkspaceFolderRules {
            let uid = getuid()
            return WorkspaceFolderRules(
                home: home.home, claudeConfig: home.claude, systemRoots: [],
                facts: .init(realpath: { missing.contains($0) ? nil : $0 }, inspect: { _ in (true, uid) }, userID: uid)
            )
        }

        func scanner(
            fileSystem: ExternalSessionFileSystem = .live, facts: ExternalSessionProcessFacts = ExternalSessionHoldTests.facts(uid: getuid()), protected: [String] = [],
            taskforce: Set<String> = [], attached: Set<String> = [], version: String? = nil, expected: String? = nil, missing: Set<String> = [], tweak: (inout ExternalSessionScanner.Configuration) -> Void = { _ in }
        ) -> ExternalSessionScanner {
            var configuration = ExternalSessionScanner.Configuration(
                claudeDirectory: home.claude, expectedConfigDirectory: expected, folderRules: rules(missing: missing), protectedRoots: protected,
                taskforceSessionIDs: { taskforce }, attachedSessionIDs: { attached }, installedCLIVersion: { version }
            )
            tweak(&configuration)
            return ExternalSessionScanner(configuration: configuration, fileSystem: fileSystem, processFacts: facts, key: ExternalSessionScannerTests.key, clock: { ExternalSessionScannerTests.now })
        }

        /// 평범한 세션 하나: 3시간 전에 쓰였고 1 KiB가 넘는다
        @discardableResult
        func session(_ n: Int, cwd: String? = nil, directory: String? = nil, entrypoint: String? = "cli", ageHours: Double = 3, title: String? = nil, pad: Int = 1200, extra: [String] = []) throws -> String {
            let id = F.uuid(n)
            let folder = cwd ?? self.cwd
            var lines = [F.user(id: id, cwd: folder, entrypoint: entrypoint)]
            if let title { lines.append(F.customTitle(id: id, title)) }
            lines += extra
            return try home.transcript(directory: directory ?? (ExternalSessionRules.projectDirectoryName(forCwd: folder) ?? "x"), id: id, lines: lines, modified: ExternalSessionScannerTests.now.addingTimeInterval(-ageHours * 3600), pad: pad)
        }
    }

    private func withWorld<T>(_ body: (World) async throws -> T) async throws -> T {
        let home = try ExternalHome()
        defer { home.cleanup() }
        return try await body(World(home: home))
    }

    private func row(_ scan: ExternalSessionScan, _ n: Int) -> ExternalSessionRow? { scan.rows.first { $0.id == F.uuid(n) } }

    // MARK: 세기

    @Test func recentTranscriptsAreListedNewestFirstWithTheirFolderTitleAndSource() async throws {
        try await withWorld { world in
            try world.session(1, entrypoint: "claude-desktop", ageHours: 5, title: "Fix launcher focus")
            try world.session(2, cwd: world.home.home + "/other", ageHours: 2)
            try world.session(3, entrypoint: "claude-vscode", ageHours: 9)
            let scan = await world.scanner().scan()
            #expect(scan.failure == nil && !scan.truncated)
            #expect(scan.rows.map(\.id) == [F.uuid(2), F.uuid(1), F.uuid(3)])
            let first = try #require(row(scan, 1))
            #expect(first.title == "Fix launcher focus")
            #expect(first.client == .claudeDesktop)
            #expect(first.status == .available)
            #expect(first.folderPath == world.cwd && first.groupPath == world.cwd && first.groupName == "proj")
            #expect(row(scan, 2)?.client == .terminal)
            #expect(row(scan, 3)?.client == .other)
            #expect(row(scan, 2)?.title == nil)
            #expect(first.ref == Self.key.ref(forSessionID: F.uuid(1)) && !first.ref.contains("5e5e5e5e"))
        }
    }

    @Test func onlyRegularSmallEnoughNamedFilesCount() async throws {
        try await withWorld { world in
            try world.session(1)
            let dir = try world.home.directory(world.dirName)
            // 이름이 UUID가 아니거나 .jsonl이 아닌 것
            for name in ["notes.jsonl", F.uuid(2) + ".jsonl.bak", F.uuid(3) + ".json", F.uuid(4).uppercased() + ".jsonl", "custom-title.json"] {
                try String(repeating: "x", count: 2000).write(toFile: dir + "/" + name, atomically: false, encoding: .utf8)
            }
            // 1 KiB 미만
            try world.session(5, pad: 0)
            // <uuid>/ 디렉터리와 subagents/ 안의 파일
            try FileManager.default.createDirectory(atPath: dir + "/" + F.uuid(6) + "/subagents", withIntermediateDirectories: true)
            try String(repeating: "x", count: 2000).write(toFile: dir + "/" + F.uuid(6) + "/subagents/" + F.uuid(7) + ".jsonl", atomically: false, encoding: .utf8)
            try FileManager.default.createDirectory(atPath: dir + "/subagents", withIntermediateDirectories: true)
            try String(repeating: "x", count: 2000).write(toFile: dir + "/subagents/" + F.uuid(8) + ".jsonl", atomically: false, encoding: .utf8)
            let scan = await world.scanner().scan()
            #expect(scan.rows.map(\.id) == [F.uuid(1)])
        }
    }

    @Test func theWindowIsSevenDaysExceptSessionsRunningRightNow() async throws {
        try await withWorld { world in
            try world.session(1, ageHours: 24 * 6.9)
            try world.session(2, ageHours: 24 * 7.1)
            try world.session(3, ageHours: 24 * 30)
            try world.home.registry(pid: 4242, json: F.json(["pid": 4242, "sessionId": F.uuid(3), "cwd": world.cwd, "entrypoint": "claude-desktop"]))
            let facts = ExternalSessionHoldTests.facts(lookups: [4242: .present(start: Date(), uid: getuid())], uid: getuid())
            let scan = await world.scanner(facts: facts).scan()
            #expect(Set(scan.rows.map(\.id)) == [F.uuid(1), F.uuid(3)])
            #expect(row(scan, 3)?.status == .held(.claudeApp))
        }
    }

    @Test func anOldSessionNamedInSomeArgvIsAlsoKept() async throws {
        try await withWorld { world in
            try world.session(1, ageHours: 24 * 20)
            let scan = await world.scanner(facts: ExternalSessionHoldTests.facts(argv: [F.uuid(1)], uid: getuid())).scan()
            #expect(row(scan, 1)?.status == .held(.terminal))
        }
    }

    @Test func sdkRunsAreLeftOutAndAnUnreadableEntrypointIsKept() async throws {
        try await withWorld { world in
            try world.session(1, entrypoint: "sdk-cli")
            try world.session(2, entrypoint: "sdk-ts")
            try world.session(3, entrypoint: nil)
            let scan = await world.scanner().scan()
            #expect(scan.rows.map(\.id) == [F.uuid(3)])
            #expect(row(scan, 3)?.client == nil)
        }
    }

    @Test func sessionsStartedByTaskforceAreLeftOutAndAttachedOnesStayAsInTaskforce() async throws {
        try await withWorld { world in
            try world.session(1)
            try world.session(2)
            let appData = world.home.home + "/AppData/Bridge"
            try FileManager.default.createDirectory(atPath: appData, withIntermediateDirectories: true)
            try world.session(3, cwd: appData + "/claude-code/sess/cwd")
            try world.session(4)
            let scan = await world.scanner(protected: [appData], taskforce: [F.uuid(1)], attached: [F.uuid(4)]).scan()
            #expect(Set(scan.rows.map(\.id)) == [F.uuid(2), F.uuid(4)])
            #expect(row(scan, 4)?.status == .inTaskforce)
        }
    }

    @Test func theSameSessionIdInTwoProjectFoldersIsOneRowTheNewest() async throws {
        try await withWorld { world in
            try world.session(1, ageHours: 10)
            try world.session(1, cwd: world.home.home + "/proj2", ageHours: 1)
            let scan = await world.scanner().scan()
            #expect(scan.rows.count == 1)
            #expect(scan.rows.first?.folderPath == world.home.home + "/proj2")
        }
    }

    // MARK: 5.3 cwd 확인 (T4)

    @Test func theCwdInTheTranscriptMustMatchItsProjectFolderName() async throws {
        try await withWorld { world in
            // 부모 디렉터리와 다른 cwd를 주장한다
            try world.session(1, cwd: world.home.home + "/elsewhere", directory: world.dirName)
            // 일치한다
            try world.session(2)
            let scan = await world.scanner().scan()
            #expect(row(scan, 1)?.status == .cannotResume(.unreadable))
            #expect(row(scan, 1)?.folderPath == nil && row(scan, 1)?.groupPath == nil, "믿을 수 없는 cwd는 어디에도 쓰지 않는다")
            #expect(row(scan, 2)?.status == .available)
        }
    }

    @Test(arguments: [
        "/Users/tester/../etc", "/Users/tester/./proj", "/Users/tester/a\u{0}b", "/Users/tester/a\nb", "/Users/tester/x'; rm -rf ~; '", "relative/path", "~/proj", "", "/Users//tester",
    ])
    func aMaliciousOrOddCwdNeverGivesAFolderAndNeverResumes(cwd: String) async throws {
        try await withWorld { world in
            // 디렉터리 이름은 cwd에서 규칙대로 만든 것이라 이름 대조는 통과할 수 있다: 그래도 평범한 절대 경로가 아니면(`..` · NUL · 개행) 거절한다
            let name = ExternalSessionRules.projectDirectoryName(forCwd: cwd) ?? "x"
            try world.session(1, cwd: cwd, directory: name.isEmpty ? "x" : name)
            let scan = await world.scanner().scan()
            let status = row(scan, 1)?.status
            if ExternalSessionRules.isPlainAbsolutePath(cwd) {
                // `'` 같은 셸 글자가 든 올바른 경로: 폴더 규칙이 정한다 (홈 밖이라 거절). 이 글자가 셸에 들어갈 길은 없다
                #expect(status == .cannotResume(.folderNotAllowed) || status == .cannotResume(.unreadable))
            } else {
                #expect(status == .cannotResume(.unreadable), "\(cwd.debugDescription)")
            }
            #expect(row(scan, 1)?.folderPath == nil || ExternalSessionRules.isPlainAbsolutePath(cwd))
        }
    }

    @Test func foldersTheRulesRefuseAreFolderNotAllowedAndMissingOnesAreUnreadable() async throws {
        try await withWorld { world in
            try world.session(1, cwd: world.home.home)
            try world.session(2, cwd: world.home.home + "/.ssh")
            try world.session(3, cwd: world.home.claude)
            try world.session(4, cwd: "/")
            try world.session(5, cwd: world.home.home + "/gone")
            try world.session(6, cwd: world.home.home + "/proj/.git/hooks")
            let scan = await world.scanner(missing: [world.home.home + "/gone"]).scan()
            for n in [1, 2, 3, 4, 6] { #expect(row(scan, n)?.status == .cannotResume(.folderNotAllowed), "\(n)") }
            #expect(row(scan, 5)?.status == .cannotResume(.unreadable))
        }
    }

    @Test func aProjectDirectoryNameOver200UnitsCannotBeCheckedSoItIsUnreadable() async throws {
        try await withWorld { world in
            let long = world.home.home + "/" + String(repeating: "a", count: 210)
            try world.session(1, cwd: long, directory: String(repeating: "a", count: 200) + "-0123456789abcdef")
            let scan = await world.scanner().scan()
            #expect(row(scan, 1)?.status == .cannotResume(.unreadable))
        }
    }

    @Test func aWorktreeSessionIsListedButCannotResumeAndGroupsUnderItsRepository() async throws {
        try await withWorld { world in
            let worktree = world.home.home + "/Repo/.claude/worktrees/feat"
            try world.session(1, cwd: worktree)
            try world.session(2, cwd: world.home.home + "/Repo")
            let scan = await world.scanner().scan()
            let item = try #require(row(scan, 1))
            #expect(item.status == .cannotResume(.worktree))
            #expect(item.groupPath == world.home.home + "/Repo" && item.groupName == "Repo")
            #expect(item.folderPath == nil || item.folderPath?.hasSuffix("feat") == true)
            #expect(row(scan, 2)?.status == .available)
            let groups = ExternalSessionGrouping.groups(scan.rows)
            #expect(groups.count == 1 && groups.first?.rows.count == 2, "워크트리는 그 저장소 밑")
        }
    }

    // MARK: 상태

    @Test func aHeldSessionShowsWhoHoldsItEvenWhenItsFolderIsRefused() async throws {
        try await withWorld { world in
            let worktree = world.home.home + "/Repo/.claude/worktrees/feat"
            try world.session(1, cwd: worktree)
            try world.home.registry(pid: 4242, json: F.json(["pid": 4242, "sessionId": F.uuid(1), "cwd": worktree, "entrypoint": "claude-desktop"]))
            let facts = ExternalSessionHoldTests.facts(lookups: [4242: .present(start: Date(), uid: getuid())], uid: getuid())
            let scan = await world.scanner(facts: facts).scan()
            #expect(row(scan, 1)?.status == .held(.claudeApp))
        }
    }

    @Test func aRegistryCwdThatDisagreesMakesTheRowUnreadable() async throws {
        try await withWorld { world in
            try world.session(1)
            try world.home.registry(pid: 4242, json: F.json(["pid": 4242, "sessionId": F.uuid(1), "cwd": world.home.home + "/another", "entrypoint": "cli"]))
            let facts = ExternalSessionHoldTests.facts(lookups: [4242: .present(start: Date(), uid: getuid())], uid: getuid())
            #expect(row(await world.scanner(facts: facts).scan(), 1)?.status == .cannotResume(.unreadable))
        }
    }

    @Test func aSessionWeCouldNotCheckIsCouldNotCheck() async throws {
        try await withWorld { world in
            try world.session(1)
            let scan = await world.scanner(facts: ExternalSessionHoldTests.facts(argv: nil, uid: getuid())).scan()
            #expect(row(scan, 1)?.status == .couldNotCheck)
        }
    }

    @Test func aRecentlyWrittenSessionNobodyOwnsIsHeldElsewhere() async throws {
        try await withWorld { world in
            try world.session(1, ageHours: 10.0 / 3600)
            #expect(row(await world.scanner().scan(), 1)?.status == .held(.unknown))
        }
    }

    @Test func anOldClaudeCodeMakesResumableRowsUpdateClaudeCode() async throws {
        try await withWorld { world in
            try world.session(1)
            try world.session(2, cwd: world.home.home)
            let old = await world.scanner(version: "2.1.241").scan()
            #expect(row(old, 1)?.status == .cannotResume(.updateClaudeCode))
            #expect(row(old, 2)?.status == .cannotResume(.folderNotAllowed), "더 앞선 이유가 이긴다")
            #expect(row(await world.scanner(version: "2.1.257").scan(), 1)?.status == .available)
            #expect(row(await world.scanner(version: "2.1.304 (Claude Code)").scan(), 1)?.status == .available)
            #expect(row(await world.scanner(version: nil).scan(), 1)?.status == .available, "버전을 모르면 막지 않는다")
            #expect(row(await world.scanner(version: "weird").scan(), 1)?.status == .available)
        }
    }

    @Test func rowsAreOrderedHeldThenAvailableThenTheRestThenInTaskforce() async throws {
        try await withWorld { world in
            try world.session(1, ageHours: 1, extra: [])
            try world.session(2, cwd: world.home.home, ageHours: 2)
            try world.session(3, ageHours: 30)
            try world.session(4, ageHours: 5)
            try world.session(5, ageHours: 40)
            try world.home.registry(pid: 4242, json: F.json(["pid": 4242, "sessionId": F.uuid(5), "cwd": world.cwd, "entrypoint": "cli"]))
            let facts = ExternalSessionHoldTests.facts(lookups: [4242: .present(start: Date(), uid: getuid())], uid: getuid())
            let scan = await world.scanner(facts: facts, attached: [F.uuid(4)]).scan()
            #expect(scan.rows.map(\.id) == [F.uuid(5), F.uuid(1), F.uuid(3), F.uuid(2), F.uuid(4)])
        }
    }

    // MARK: 상한 (T3)

    @Test func theNumberOfFilesExaminedIsCappedAt500AndTheRowsAt50() async throws {
        try await withWorld { world in
            for n in 1...520 { try world.session(n, ageHours: 3 + Double(n) / 100, pad: 1100) }
            let recording = RecordingFileSystem()
            let scan = await world.scanner(fileSystem: recording.fileSystem).scan()
            #expect(scan.truncated)
            #expect(scan.rows.count == 50)
            #expect(recording.reads.count <= 500)
            #expect(scan.rows.first?.id == F.uuid(1), "가장 최근 것부터")
        }
    }

    @Test func theTotalReadBudgetStopsTheScan() async throws {
        try await withWorld { world in
            for n in 1...40 { try world.session(n, ageHours: 3 + Double(n) / 100, pad: 90_000) }
            let recording = RecordingFileSystem()
            let scan = await world.scanner(fileSystem: recording.fileSystem, tweak: { $0.readBudget = 400_000 }).scan()
            #expect(scan.truncated)
            // 한 파일(머리 + 꼬리 ≤ 320 KiB)을 읽는 중 넘을 수는 있어도 예산 + 한 파일을 넘지 않는다
            #expect(recording.bytesRead <= 400_000 + 320 * 1024)
            #expect(scan.rows.count < 40)
        }
    }

    @Test func aHugeSparseTranscriptOnlyCostsItsWindows() async throws {
        try await withWorld { world in
            let path = try world.session(1)
            let handle = try #require(FileHandle(forWritingAtPath: path))
            try handle.truncate(atOffset: 2 << 30)
            try handle.close()
            let recording = RecordingFileSystem()
            let started = Date()
            let scan = await world.scanner(fileSystem: recording.fileSystem).scan()
            #expect(Date().timeIntervalSince(started) < 3)
            #expect(row(scan, 1) != nil)
            #expect(recording.bytesRead <= 320 * 1024)
        }
    }

    @Test func theListingItselfIsBoundedToo() async throws {
        try await withWorld { world in
            for n in 1...30 { try world.session(n) }
            let scan = await world.scanner(tweak: { $0.maxListedEntries = 10 }).scan()
            #expect(scan.truncated)
            #expect(scan.rows.count <= 10)
        }
    }

    @Test func aSecondScanDoesNotReadUnchangedFilesAgainButReadsChangedOnes() async throws {
        try await withWorld { world in
            let first = try world.session(1)
            try world.session(2)
            let recording = RecordingFileSystem()
            let scanner = world.scanner(fileSystem: recording.fileSystem)
            _ = await scanner.scan()
            let afterFirst = recording.reads.count
            #expect(afterFirst > 0)
            _ = await scanner.scan()
            #expect(recording.reads.count == afterFirst, "바뀐 것이 없으면 머리 · 꼬리를 다시 읽지 않는다")
            try world.home.setModified(first, Self.now.addingTimeInterval(-7200))
            let third = await scanner.scan()
            #expect(recording.reads.count > afterFirst)
            #expect(abs((row(third, 1)?.lastActivity ?? .distantPast).timeIntervalSince(Self.now.addingTimeInterval(-7200))) < 0.01)
        }
    }

    // MARK: 안전 (T2 · T8)

    @Test func symlinkedTranscriptsAndProjectFoldersAreSkipped() async throws {
        try await withWorld { world in
            try world.session(1)
            let outside = world.home.root + "/outside"
            try FileManager.default.createDirectory(atPath: outside, withIntermediateDirectories: true)
            try F.user(id: F.uuid(2), cwd: world.cwd).write(toFile: outside + "/real.jsonl", atomically: false, encoding: .utf8)
            let dir = try world.home.directory(world.dirName)
            try world.home.link(dir + "/" + F.uuid(2) + ".jsonl", to: outside + "/real.jsonl")
            let realProject = outside + "/proj"
            try FileManager.default.createDirectory(atPath: realProject, withIntermediateDirectories: true)
            try (F.user(id: F.uuid(3), cwd: world.cwd) + String(repeating: " ", count: 2000)).write(toFile: realProject + "/" + F.uuid(3) + ".jsonl", atomically: false, encoding: .utf8)
            try world.home.link(world.home.projects + "/-linked-project", to: realProject)
            let scan = await world.scanner().scan()
            #expect(scan.rows.map(\.id) == [F.uuid(1)])
        }
    }

    @Test func aProjectsFolderThatIsASymlinkRefusesTheWholeList() async throws {
        try await withWorld { world in
            try world.session(1)
            let moved = world.home.claude + "/projects-real"
            try FileManager.default.moveItem(atPath: world.home.projects, toPath: moved)
            try world.home.link(world.home.projects, to: moved)
            let scan = await world.scanner().scan()
            #expect(scan.failure == .unreadable && scan.rows.isEmpty)
        }
    }

    @Test func aSymlinkedClaudeFolderIsFollowedBecauseTheUserMovedIt() async throws {
        try await withWorld { world in
            try world.session(1)
            let dotfiles = world.home.root + "/dotfiles-claude"
            try FileManager.default.moveItem(atPath: world.home.claude, toPath: dotfiles)
            try world.home.link(world.home.claude, to: dotfiles)
            let scan = await world.scanner().scan()
            #expect(scan.failure == nil && scan.rows.count == 1)
        }
    }

    @Test func theProbeConfigDirectoryMustBeTheOneWeRead() async throws {
        try await withWorld { world in
            try world.session(1)
            let same = await world.scanner(expected: world.home.claude).scan()
            #expect(same.failure == nil && same.rows.count == 1)
            let other = world.home.root + "/elsewhere"
            try FileManager.default.createDirectory(atPath: other, withIntermediateDirectories: true)
            let differs = await world.scanner(expected: other).scan()
            #expect(differs.failure == .unreadable && differs.rows.isEmpty)
            let missing = await world.scanner(expected: world.home.root + "/not-there").scan()
            #expect(missing.failure == .unreadable)
        }
    }

    @Test func aMissingClaudeFolderIsNotFoundAndAMissingProjectsFolderIsJustEmpty() async throws {
        try await withWorld { world in
            try FileManager.default.removeItem(atPath: world.home.projects)
            let empty = await world.scanner().scan()
            #expect(empty.failure == nil && empty.rows.isEmpty)
            try FileManager.default.removeItem(atPath: world.home.claude)
            let gone = await world.scanner().scan()
            #expect(gone.failure == .notFound && gone.rows.isEmpty)
        }
    }

    @Test func onlyAllowListedNamesAreEverOpenedOrListed() async throws {
        try await withWorld { world in
            try world.session(1)
            // 열면 안 되는 것들: 자격 · 설정 · 키 · 데스크톱 앱 저장소 · 홈의 .claude.json
            try "SECRET".write(toFile: world.home.claude + "/.credentials.json", atomically: false, encoding: .utf8)
            try "SECRET".write(toFile: world.home.claude + "/settings.json", atomically: false, encoding: .utf8)
            try "SECRET".write(toFile: world.home.claude + "/settings.local.json", atomically: false, encoding: .utf8)
            try "SECRET".write(toFile: world.home.home + "/.claude.json", atomically: false, encoding: .utf8)
            try "SECRET".write(toFile: world.home.sessions + "/4242.abcdef0123.key", atomically: false, encoding: .utf8)
            try "SECRET".write(toFile: world.home.sessions + "/note.txt", atomically: false, encoding: .utf8)
            let desktop = world.home.home + "/Library/Application Support/Claude/claude-code-sessions/acct"
            try FileManager.default.createDirectory(atPath: desktop, withIntermediateDirectories: true)
            try "SECRET".write(toFile: desktop + "/local_x.json", atomically: false, encoding: .utf8)
            try "SECRET".write(toFile: (try world.home.directory(world.dirName)) + "/notes.txt", atomically: false, encoding: .utf8)
            try world.home.registry(pid: 4242, json: F.json(["pid": 4242, "sessionId": F.uuid(1), "cwd": world.cwd]))
            let recording = RecordingFileSystem()
            _ = await world.scanner(fileSystem: recording.fileSystem).scan()
            let transcript = #/^.*/\.claude/projects/[A-Za-z0-9-]+/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.jsonl$/#
            let registry = #/^.*/\.claude/sessions/[0-9]{1,10}\.json$/#
            for item in recording.reads {
                #expect(item.path.wholeMatch(of: transcript) != nil || item.path.wholeMatch(of: registry) != nil, "열린 파일: \(item.path.suffix(40))")
            }
            #expect(!recording.reads.isEmpty)
            for path in recording.listed {
                #expect(path == world.home.projects || path == world.home.sessions || path.hasPrefix(world.home.projects + "/"), "나열한 폴더: \(path.suffix(40))")
                #expect(!path.contains("Application Support") && !path.hasSuffix("/.claude"))
            }
            for path in recording.statted { #expect(!path.contains("Application Support") && !path.contains("credentials") && !path.hasSuffix(".claude.json") && !path.hasSuffix(".key")) }
        }
    }

    // MARK: 글 · 경로 · id는 로그 · 설명에 나오지 않는다 (T1 · 9.3)

    @Test func nothingTextualFromTheTranscriptsReachesTheScanResultOrItsDescription() async throws {
        try await withWorld { world in
            try world.session(1, title: "Visible title", extra: [F.assistant(id: F.uuid(1)), F.lastPrompt(id: F.uuid(1))])
            let scan = await world.scanner().scan()
            expectNoSentinel(in: scan)
            let item = try #require(scan.rows.first)
            let described = String(describing: item) + String(reflecting: item) + "\(item)"
            #expect(!described.contains("Visible title"))
            #expect(!described.contains(world.home.home))
            #expect(!described.contains(F.uuid(1)))
            #expect(!described.contains(item.ref))
        }
    }

    // MARK: 묶음

    @Test func groupsAreOrderedByTheirNewestActivityAndRowsByRank() throws {
        let now = Self.now
        func make(_ n: Int, group: String?, ageHours: Double, status: ExternalSessionStatus = .available) -> ExternalSessionRow {
            ExternalSessionRow(
                id: F.uuid(n), ref: String(repeating: "a", count: 64), title: nil, folderPath: group, groupPath: group, lastActivity: now.addingTimeInterval(-ageHours * 3600),
                created: now.addingTimeInterval(-ageHours * 3600), client: .terminal, status: status
            )
        }
        let rows = [
            make(1, group: "/h/old", ageHours: 50), make(2, group: "/h/taskforce", ageHours: 3), make(3, group: "/h/taskforce", ageHours: 9, status: .held(.claudeApp)),
            make(4, group: nil, ageHours: 1), make(5, group: "/h/taskforce", ageHours: 1, status: .inTaskforce), make(6, group: "/h/taskforce", ageHours: 20, status: .cannotResume(.worktree)),
        ]
        let groups = ExternalSessionGrouping.groups(rows, projectName: { $0 == "/h/taskforce" ? "Taskforce app" : nil })
        #expect(groups.map(\.id) == ["/h/taskforce", "/h/old", ""])
        #expect(groups.map(\.name) == ["Taskforce app", "old", nil])
        #expect(groups[0].rows.map(\.id) == [F.uuid(3), F.uuid(2), F.uuid(6), F.uuid(5)])
    }
}

#endif
