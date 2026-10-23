#if os(macOS) && DEBUG
import Foundation
import Testing
@testable import TaskforceKit

/// 이어받은 세션의 실행 인자 (OA 외부 세션 PR2m, 계약 ES-11 · ES-12 B · ES-12b · 19장): 이어받은 세션만 빈 `--setting-sources`와 `--system-prompt-snapshot off`를 쓰고,
/// 새 세션 · Taskforce 세션의 다음 턴 인자는 **바이트까지 그대로**다. 기대 값은 이 파일이 글로 적은 것이다 (제품 코드로 만든 값이 아니다)
struct ExternalSessionAttachLaunchTests {
    private let id = "5e5e5e5e-0000-4000-8000-0000000000a1"

    private func args(_ session: ClaudeCodeLaunch.SessionArgument, access: AgentAccess = .write, attached: Bool? = nil) -> [String] {
        if let attached {
            return ClaudeCodeLaunch.arguments(access: access, workspace: "/w", settings: "/c/s.json", mcp: "/c/m.json", promptFile: "/c/p.txt", session: session, attached: attached)
        }
        return ClaudeCodeLaunch.arguments(access: access, workspace: "/w", settings: "/c/s.json", mcp: "/c/m.json", promptFile: "/c/p.txt", session: session)
    }

    private func golden(sources: String, session: [String], snapshot: Bool, tools: String = "Read,Glob,Grep,Edit,Write,Bash") -> [String] {
        var expected = [
            "-p", "--output-format", "stream-json", "--verbose", "--include-hook-events", "--max-budget-usd", "25", "--tools", tools, "--strict-mcp-config", "--mcp-config", "/c/m.json",
            "--add-dir", "/w", "--settings", "/c/s.json", "--setting-sources", sources, "--permission-mode", "manual", "--append-system-prompt-file", "/c/p.txt",
        ]
        if snapshot { expected += ["--system-prompt-snapshot", "off"] }
        return expected + session
    }

    @Test func aNewSessionKeepsItsArgumentsByteForByte() {
        let expected = golden(sources: "project", session: ["--session-id", id], snapshot: false)
        #expect(args(.new(id)) == expected)
        #expect(args(.new(id), attached: false) == expected)
        #expect(args(.new(id), access: .readOnly) == golden(sources: "project", session: ["--session-id", id], snapshot: false, tools: "Read,Glob,Grep"))
    }

    @Test func aResumedTaskforceSessionKeepsItsArgumentsByteForByte() {
        let expected = golden(sources: "project", session: ["--resume", id], snapshot: false)
        #expect(args(.resume(id)) == expected)
        #expect(args(.resume(id), attached: false) == expected)
    }

    @Test func anAttachedSessionUsesEmptySettingSourcesAndSnapshotOffAndNothingElseChanges() {
        let expected = golden(sources: "", session: ["--resume", id], snapshot: true)
        #expect(args(.resume(id), attached: true) == expected)
        #expect(args(.resume(id), access: .readOnly, attached: true) == golden(sources: "", session: ["--resume", id], snapshot: true, tools: "Read,Glob,Grep"))
        // 빈 값은 인자 하나다 (`--setting-sources=`가 아니다)
        let all = args(.resume(id), attached: true)
        let index = try! #require(all.firstIndex(of: "--setting-sources"))
        #expect(all[index + 1] == "")
    }

    @Test func theAttachedSetHasNoProjectSourceAndNoRestrictedFlag() {
        let all = args(.resume(id), attached: true)
        #expect(!all.contains("project") && !all.contains("--restricted"), "R2: 빈 sources가 쓰는 길이다 (--restricted는 로컬 세션 간 메시지 소켓을 없앤다)")
        #expect(all.filter { $0 == "--setting-sources" }.count == 1 && all.filter { $0 == "--system-prompt-snapshot" }.count == 1)
    }

    @Test func theAttachedFlagNeverTurnsANewSessionIntoAnIsolatedOne() {
        #expect(args(.new(id), attached: true) == golden(sources: "project", session: ["--session-id", id], snapshot: false), "새 세션은 이어받은 세션이 아니다")
    }

    @Test func theMinimumVersionForTheAttachedFlagsIsTheOneTheContractNames() {
        #expect(ExternalSessionRules.minimumResumeVersion == "2.1.257")
    }

    // MARK: 시작 프롬프트

    @Test func theNewSessionPromptIsUnchanged() {
        let expected = "When you need the user's input, call mcp__tf__ask_user (1–4 questions). Make one such call at a time and wait for its result."
            + " The user's chosen workspace folder for this session is: /w (absolute path)."
            + " When the user says \"this folder\", \"here\" or \"the project\", they mean that folder."
            + " Your shell starts in a different, private empty directory, so use absolute paths inside the workspace folder and do not look around to find it."
        #expect(ClaudeCodePrompts.v2(workspace: "/w") == expected)
    }

    @Test func theAttachedPromptSaysTheShellStartsInTheWorkspaceInsteadOfThePrivateDirectory() {
        let text = ClaudeCodePrompts.v2(workspace: "/w", shellInWorkspace: true)
        #expect(text.hasPrefix("When you need the user's input, call mcp__tf__ask_user (1–4 questions). Make one such call at a time and wait for its result. The user's chosen workspace folder for this session is: /w (absolute path)."))
        #expect(text.contains("Your shell starts in the workspace folder."))
        #expect(!text.contains("private empty directory"), "cwd가 작업 폴더인데 다른 폴더라고 말하지 않는다")
        #expect(!text.contains("\n"), "첫 줄은 한 줄이다")
    }
}
#endif
