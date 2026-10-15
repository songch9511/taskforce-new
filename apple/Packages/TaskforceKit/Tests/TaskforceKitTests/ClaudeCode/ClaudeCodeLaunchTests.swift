#if os(macOS)
import Foundation
import Testing
import TaskforceAgentWire
@testable import TaskforceKit

/// 실행 인자 · 설정 파일 · 자식 환경 · 실행 파일 찾기 (OA D3a 계약 2.4 · 2.5 · 4.1). ①(G17) · 환경 넷(G24) · 시험 locator(G33)
struct ClaudeCodeLaunchTests {
    let box = ClaudeSandbox()

    // MARK: 실행 인자

    @Test func firstTurnAndResumeArgumentsAreExactlyTheContractSet() {
        let first = ClaudeCodeLaunch.arguments(access: .write, workspace: "/w", settings: "/s/config/a.settings.json", mcp: "/s/config/a.mcp.json", session: .new("11111111-1111-4111-8111-111111111111"))
        #expect(first == [
            "-p", "--output-format", "stream-json", "--verbose", "--include-hook-events", "--max-budget-usd", "25", "--tools", "Read,Glob,Grep,Edit,Write,Bash",
            "--strict-mcp-config", "--mcp-config", "/s/config/a.mcp.json", "--add-dir", "/w", "--settings", "/s/config/a.settings.json", "--setting-sources", "project",
            "--permission-mode", "manual", "--append-system-prompt", ClaudeCodePrompts.v1, "--session-id", "11111111-1111-4111-8111-111111111111",
        ])
        let resume = ClaudeCodeLaunch.arguments(access: .readOnly, workspace: "/w", settings: "/s", mcp: "/m", session: .resume("abc"))
        #expect(resume.suffix(2) == ["--resume", "abc"])
        #expect(resume[resume.firstIndex(of: "--tools")! + 1] == "Read,Glob,Grep")
        #expect(!resume.contains("--session-id") && !resume.contains("--model") && !resume.contains("acceptEdits"))
    }

    @Test func thePromptAsksForOneQuestionCallAtATime() {
        #expect(ClaudeCodePrompts.v1 == "When you need the user's input, call mcp__tf__ask_user (1–4 questions). Make one such call at a time and wait for its result.")
    }

    // MARK: 설정 파일 (정확히 이 모양, `permissions` 없음)

    @Test func settingsQuoteEveryShellArgumentAndCarryNoPermissions() throws {
        let settings = try ClaudeCodeLaunch.settingsJSON(hook: "/App/Taskforce.app/Contents/Helpers/tf-agent-hook", socket: "/s/hook.sock", session: ClaudeTest.session, nonce: "AbC-_123")
        #expect(settings.canonicalText == #"{"hooks":{"PreToolUse":[{"hooks":[{"command":"'/App/Taskforce.app/Contents/Helpers/tf-agent-hook' pre-tool-use --socket '/s/hook.sock' --session '5e551011-0000-4000-8000-000000000001' --nonce 'AbC-_123'","timeout":10,"type":"command"}],"matcher":"*"}],"SessionStart":[{"hooks":[{"command":"'/App/Taskforce.app/Contents/Helpers/tf-agent-hook' session-start","timeout":10,"type":"command"}]}]}}"#)
        #expect(settings["permissions"] == nil)
        let mcp = ClaudeCodeLaunch.mcpJSON(helper: "/App/Taskforce.app/Contents/Helpers/tf-agent-mcp", session: ClaudeTest.session)
        #expect(mcp.canonicalText == #"{"mcpServers":{"tf":{"args":["--session","5e551011-0000-4000-8000-000000000001"],"command":"/App/Taskforce.app/Contents/Helpers/tf-agent-mcp"}}}"#)
    }

    @Test func aQuoteControlCharacterOrNULInAnyShellValueRefusesTheSpawn() {
        for bad in ["/App/it's/hook", "/App/a\nb", "/App/a\u{0}b", "/App/a\u{7}b"] {
            #expect(throws: AgentStartError(.spawnFailed)) { try ClaudeCodeLaunch.settingsJSON(hook: bad, socket: "/s", session: "x", nonce: "n") }
            #expect(throws: AgentStartError(.spawnFailed)) { try ClaudeCodeLaunch.settingsJSON(hook: "/h", socket: bad, session: "x", nonce: "n") }
        }
    }

    @Test func configFilesAreWrittenPrivatelyAndVerifiedByReadingThemBack() throws {
        let config = box.root.appending(path: "config", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
        let settings = try ClaudeCodeLaunch.settingsJSON(hook: "/h", socket: "/s", session: "x", nonce: "n")
        let mcp = ClaudeCodeLaunch.mcpJSON(helper: "/m", session: "x")
        let files = try ClaudeCodeLaunch.writeConfig(directory: config, spawnID: "11111111-1111-4111-8111-111111111111", settings: settings, mcp: mcp)
        #expect(files.settings.lastPathComponent == "11111111-1111-4111-8111-111111111111.settings.json")
        let mode = try FileManager.default.attributesOfItem(atPath: files.settings.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
        #expect(ClaudeCodeLaunch.verifyConfig(files, settings: settings, mcp: mcp))
        // 쓴 뒤 바뀐 파일은 spawn하지 않는다 (①, 사례 8-03)
        try Data(#"{"hooks":{"PreToolUse":"this-should-be-an-array"}}"#.utf8).write(to: files.settings)
        #expect(!ClaudeCodeLaunch.verifyConfig(files, settings: settings, mcp: mcp))
        try Data("{".utf8).write(to: files.settings)
        #expect(!ClaudeCodeLaunch.verifyConfig(files, settings: settings, mcp: mcp))
    }

    @Test func aNonceIs43Base64URLCharactersAndFresh() {
        let a = ClaudeCodeLaunch.newNonce()
        let b = ClaudeCodeLaunch.newNonce()
        #expect(a.count == 43 && a != b)
        #expect(a.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" })
    }

    // MARK: 자식 환경 (AC-42, G24)

    @Test func theChildGetsExactlyFourKeysWhateverTheAppHas() {
        let app = ["HOME": "/Users/u", "USER": "u", "PATH": "/usr/bin:/bin", "LANG": "ko_KR.UTF-8", "ANTHROPIC_API_KEY": "sk-canary", "CLAUDE_CODE_OAUTH_TOKEN": "canary",
                   "DYLD_INSERT_LIBRARIES": "/tmp/x.dylib", "NODE_OPTIONS": "--require x", "TMPDIR": "/tmp"]
        let executable = ClaudeCodeExecutable(path: "/Users/u/.local/bin/claude", realPath: "/Users/u/.local/share/claude/versions/2.1.241", directory: "/Users/u/.local/bin")
        let env = ClaudeCodeEnvironment.child(app: app, executable: executable)
        #expect(Set(env.keys) == ["HOME", "PATH", "LANG", "USER"])
        #expect(env["HOME"] == "/Users/u" && env["USER"] == "u" && env["LANG"] == "ko_KR.UTF-8")
        #expect(env["PATH"] == "/Users/u/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin")
    }

    @Test func pathPutsTheFoundClaudeFolderFirstWithoutDuplicates() {
        let brew = ClaudeCodeExecutable(path: "/opt/homebrew/bin/claude", realPath: "/opt/homebrew/Cellar/claude/2.1.241/bin/claude", directory: "/opt/homebrew/bin")
        #expect(ClaudeCodeEnvironment.path(executableDirectory: brew.directory, home: "/Users/u") == "/opt/homebrew/bin:/Users/u/.local/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin")
    }

    @Test func langFallsBackToEnglishUTF8AndHomeUserFallBackToTheAccount() {
        let executable = ClaudeCodeExecutable(path: "/x/claude", realPath: "/x/claude", directory: "/x")
        for lang in [nil, "", "C", "en_US", "ko_KR.EUC-KR", "x;rm -rf ~"] as [String?] {
            var app = ["HOME": "/h", "USER": "u"]
            app["LANG"] = lang
            #expect(ClaudeCodeEnvironment.child(app: app, executable: executable)["LANG"] == "en_US.UTF-8", "\(String(describing: lang))")
        }
        let bare = ClaudeCodeEnvironment.child(app: [:], executable: executable)
        #expect(bare["HOME"]?.hasPrefix("/") == true)
        #expect(bare["USER"]?.isEmpty == false)
    }

    // MARK: 실행 파일 찾기 (Q7, G33)

    func install(_ relative: String, mode: Int = 0o755) -> URL {
        let url = box.home.appending(path: relative)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data("#!/bin/sh\n".utf8).write(to: url)
        try? FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
        return url
    }

    @Test func theFirstExistingCandidateIsUsedWhenItIsAPrivateExecutable() {
        let first = install(".local/bin/claude")
        let second = install("brew/claude")
        let locator = ClaudeCodeLocator(candidates: [first.path, second.path], confinedTo: box.root.path)
        #expect(locator.locate()?.path == first.path)
        #expect(locator.locate()?.directory == first.deletingLastPathComponent().path)
        let skipMissing = ClaudeCodeLocator(candidates: [box.home.appending(path: "nope/claude").path, second.path], confinedTo: box.root.path)
        #expect(skipMissing.locate()?.path == second.path)
    }

    @Test func aGroupWritableNonExecutableOrDirectoryCandidateIsRefused() {
        let writable = install("a/claude", mode: 0o775)
        #expect(ClaudeCodeLocator(candidates: [writable.path], confinedTo: box.root.path).locate() == nil)
        let plain = install("b/claude", mode: 0o644)
        #expect(ClaudeCodeLocator(candidates: [plain.path], confinedTo: box.root.path).locate() == nil)
        let folder = box.home.appending(path: "c/claude", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        #expect(ClaudeCodeLocator(candidates: [folder.path], confinedTo: box.root.path).locate() == nil)
    }

    @Test func aLinkIsCheckedAtItsRealPathButPathKeepsTheLinkFolder() {
        let target = install("share/claude/versions/2.1.241")
        let link = box.home.appending(path: ".local/bin/claude")
        try? FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let found = ClaudeCodeLocator(candidates: [link.path], confinedTo: box.root.path).locate()
        #expect(found?.realPath == ClaudeSandbox.real(target.path))
        #expect(found?.directory == link.deletingLastPathComponent().path)
    }

    @Test func theTestLocatorRefusesAnythingOutsideTheTestFolder() {
        // 시험이 실제 사용자의 `claude`를 띄우지 않게 (계약 0.3-6): 임시 폴더 밖 실행 파일은 받지 않는다
        #expect(ClaudeCodeLocator(candidates: ["/bin/sh"], confinedTo: box.root.path).locate() == nil)
        let inside = install(".local/bin/claude")
        let escape = box.home.appending(path: ".local/bin/escape")
        try? FileManager.default.createSymbolicLink(atPath: escape.path, withDestinationPath: "/bin/sh")
        #expect(ClaudeCodeLocator(candidates: [escape.path, inside.path], confinedTo: box.root.path).locate() == nil, "임시 폴더 밖을 가리키는 첫 후보에서 멈춘다")
    }

    @Test func theStandardCandidatesAreTheThreeContractPaths() {
        #expect(ClaudeCodeLocator.standardCandidates(home: "/Users/u") == ["/Users/u/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"])
    }

    // MARK: 세션 폴더 · 상태 파일 (글 0)

    @Test func theSessionFolderSeparatesAnEmptyCwdFromTheConfigFolder() throws {
        let folder = try ClaudeSessionFolder.prepare(sessionsRoot: box.sessionsRoot, agentSessionID: ClaudeTest.session)
        #expect(folder.cwd.path.hasSuffix("/\(ClaudeTest.session)/cwd"))
        #expect(folder.config.path.hasSuffix("/\(ClaudeTest.session)/config"))
        for url in [folder.root, folder.cwd, folder.config] {
            #expect(try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int == 0o700)
        }
        #expect(throws: AgentStartError(.spawnFailed)) { try ClaudeSessionFolder.prepare(sessionsRoot: box.sessionsRoot, agentSessionID: "../escape") }
    }

    @Test func theStateFileHoldsOnlyIDsDigestsAndTimes() throws {
        let folder = try ClaudeSessionFolder.prepare(sessionsRoot: box.sessionsRoot, agentSessionID: ClaudeTest.session)
        var state = ClaudeSessionState()
        state.providerSessionID = "0e09f680-f476-4f2e-96d9-670f24599f6d"
        state.bound = true
        state.openDeferred = ClaudeSessionState.OpenDeferred(
            id: "toolu_1", kind: "approval", inputSHA256: "abc", spawnID: "s", at: Date(timeIntervalSince1970: 1_760_000_000), targetSHA256: String(repeating: "f", count: 64)
        )
        try state.save(in: folder.root)
        #expect(ClaudeSessionState.load(from: folder.root) == state)
        #expect(try FileManager.default.attributesOfItem(atPath: folder.root.appending(path: "state.json").path)[.posixPermissions] as? Int == 0o600)
        let object = try #require(try WireJSON.parse(Data(contentsOf: folder.root.appending(path: "state.json"))).objectValue)
        // 비밀값을 건넨 적이 있다는 표식만 (값 0, 11장 9)
        #expect(Set(object.keys) == ["v", "provider_session_id", "bound", "open_deferred", "secret_answered"])
        // 대상은 경로가 아니라 지문(sha256)으로만 (8장 2), 비밀 항목은 값이 아니라 id만 (10장 7)
        #expect(Set(try #require(object["open_deferred"]?.objectValue).keys) == ["id", "kind", "input_sha256", "spawn_id", "at", "target_sha256", "secret_item_ids", "single_item"])
    }
}
#endif
