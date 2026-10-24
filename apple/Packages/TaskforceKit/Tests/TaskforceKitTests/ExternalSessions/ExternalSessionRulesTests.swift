#if os(macOS) && DEBUG
import Foundation
import Testing
@testable import TaskforceKit

extension ExternalSessionSuites {
    /// 외부 세션 발견의 순수 규칙 (OA 외부 세션 PR1, 계약 5장 · T4 · T5): 파일 이름 → id, cwd → 프로젝트 디렉터리 이름, 제목 정리, 출처, 워크트리, 버전. 가짜 값만 쓴다
    struct ExternalSessionRulesTests {
        // MARK: 세션 id (T5: `--resume` 인자에 `/` · 옵션이 들어갈 길을 0으로)

        @Test func aLowercaseCanonicalUUIDFileNameIsTheSessionID() {
            let id = "5e5e5e5e-0000-4000-8000-000000000001"
            #expect(ExternalSessionRules.sessionID(fromFileName: id + ".jsonl") == id)
            #expect(ExternalSessionRules.sessionID(fromFileName: "00000000-0000-0000-0000-000000000000.jsonl") == "00000000-0000-0000-0000-000000000000")
        }

        @Test func everythingElseIsNotASessionFileName() {
            let id = "5e5e5e5e-0000-4000-8000-000000000001"
            let bad = [
                id.uppercased() + ".jsonl", id, id + ".json", id + ".jsonl.bak", id + ".jsonl ", " " + id + ".jsonl", "-r.jsonl", "--resume.jsonl", "../" + id + ".jsonl",
                "/tmp/a.jsonl", "a/" + id + ".jsonl", id.replacingOccurrences(of: "-", with: "") + ".jsonl", "5e5e5e5e-0000-4000-8000-00000000000.jsonl", "5e5e5e5e-0000-4000-8000-0000000000012.jsonl",
                "x" + id + ".jsonl", id + "\0.jsonl", id + "\n.jsonl", "a.jsonl", ".jsonl", "", "subagents", "custom-title.json", "5e5e5e5e-0000-4000-8000-00000000000g.jsonl",
            ]
            for name in bad { #expect(ExternalSessionRules.sessionID(fromFileName: name) == nil, "\(name.debugDescription)") }
        }

        @Test func canonicalUUIDOnlyAcceptsTheLowercaseRoundTripForm() {
            #expect(ExternalSessionRules.isCanonicalUUID("5e5e5e5e-0000-4000-8000-000000000001"))
            #expect(!ExternalSessionRules.isCanonicalUUID("5E5E5E5E-0000-4000-8000-000000000001"))
            #expect(!ExternalSessionRules.isCanonicalUUID("-r"))
            #expect(!ExternalSessionRules.isCanonicalUUID("/tmp/a.jsonl"))
            #expect(!ExternalSessionRules.isCanonicalUUID("5e5e5e5e-0000-4000-8000-000000000001 "))
        }

        // MARK: cwd → 프로젝트 디렉터리 이름 (CC-A: 영숫자 아닌 글자를 `-`로, UTF-16 단위, 200자 넘으면 확인 불가)

        @Test func nonAlphanumericCharactersBecomeDashes() {
            #expect(ExternalSessionRules.projectDirectoryName(forCwd: "/Users/alice/Projects/my app") == "-Users-alice-Projects-my-app")
            #expect(ExternalSessionRules.projectDirectoryName(forCwd: "/a.b_c") == "-a-b-c")
            #expect(ExternalSessionRules.projectDirectoryName(forCwd: "/Users/x/.claude/worktrees/feat") == "-Users-x--claude-worktrees-feat")
        }

        @Test func eachUTF16UnitBecomesOneDash() {
            // 한글은 한 단위, 이모지(서로게이트 쌍)는 두 단위
            #expect(ExternalSessionRules.projectDirectoryName(forCwd: "/김") == "--")
            #expect(ExternalSessionRules.projectDirectoryName(forCwd: "/😀") == "---")
            #expect(ExternalSessionRules.projectDirectoryName(forCwd: "/a😀b") == "-a--b")
        }

        @Test func aNameLongerThan200UnitsCannotBeChecked() {
            #expect(ExternalSessionRules.projectDirectoryName(forCwd: "/" + String(repeating: "a", count: 199))?.count == 200)
            #expect(ExternalSessionRules.projectDirectoryName(forCwd: "/" + String(repeating: "a", count: 200)) == nil)
            #expect(ExternalSessionRules.projectDirectoryName(forCwd: "/" + String(repeating: "김", count: 200)) == nil)
        }

        @Test func aCwdThatIsNotAPlainAbsolutePathIsRefused() {
            for cwd in ["", "relative/path", "~/project", "/Users/a/../b", "/Users/a/./b", "/Users/a\0b", "/Users/a\nb", "/Users/a\rb", "/Users//b", "/Users/a/"] {
                #expect(!ExternalSessionRules.isPlainAbsolutePath(cwd), "\(cwd.debugDescription)")
            }
            // 셸 글자가 든 폴더 이름도 올바른 경로다: 이 경로는 셸에 넣지 않는다 (posix_spawn + chdir). 막는 것은 디렉터리 이름 대조(스캐너)다
            for cwd in ["/", "/Users/alice/Projects/my app", "/Volumes/Disk/한글 폴더/x", "/Users/a/it's here", "/Users/a/x'; rm -rf ~; '"] {
                #expect(ExternalSessionRules.isPlainAbsolutePath(cwd), "\(cwd.debugDescription)")
            }
        }

        // MARK: 제목 (ES-01: 200자 · 제어 글자 제거. 서버 제목 규칙과 같게)

        @Test func controlAndFormatCharactersAreRemovedAndWhitespaceIsCollapsed() {
            #expect(ExternalSessionRules.sanitizedTitle("Fix\nlauncher\tfocus") == "Fix launcher focus")
            #expect(ExternalSessionRules.sanitizedTitle("a\u{0}b\u{7F}c") == "abc")
            #expect(ExternalSessionRules.sanitizedTitle("\u{202E}evil\u{202C}") == "evil")
            #expect(ExternalSessionRules.sanitizedTitle("zero\u{200B}width\u{FEFF}") == "zerowidth")
            #expect(ExternalSessionRules.sanitizedTitle("  padded   spaces  ") == "padded spaces")
            #expect(ExternalSessionRules.sanitizedTitle("line\u{2028}break\u{2029}x") == "line break x")
            #expect(ExternalSessionRules.sanitizedTitle("가격 페이지 FAQ 문구 다듬기") == "가격 페이지 FAQ 문구 다듬기")
        }

        @Test func aTitleWithNothingLeftIsNil() {
            for raw in ["", " ", "\n\t", "\u{0}\u{1}", "\u{202E}", "\u{200B}\u{FEFF}"] { #expect(ExternalSessionRules.sanitizedTitle(raw) == nil, "\(raw.debugDescription)") }
        }

        @Test func aLongTitleIsCutAt200UTF16UnitsWithoutSplittingACharacter() throws {
            let long = String(repeating: "a", count: 300)
            #expect(ExternalSessionRules.sanitizedTitle(long)?.utf16.count == 200)
            // 199번째까지 영문 + 이모지(두 단위)가 경계를 넘으면 이모지를 통째로 뺀다
            let emoji = String(repeating: "a", count: 199) + "😀tail"
            let cut = try #require(ExternalSessionRules.sanitizedTitle(emoji))
            #expect(cut == String(repeating: "a", count: 199))
            #expect(cut.utf16.count <= 200)
            let hangul = try #require(ExternalSessionRules.sanitizedTitle(String(repeating: "가", count: 300)))
            #expect(hangul.utf16.count == 200)
            // 끝이 잘린 뒤 공백이 남지 않는다
            let spaced = try #require(ExternalSessionRules.sanitizedTitle(String(repeating: "a", count: 199) + " bbb"))
            #expect(spaced == String(repeating: "a", count: 199))
        }

        @Test func aSanitizedTitleSatisfiesTheServerRule() {
            let raw = ["Fix\nlauncher", "\u{202E}x\u{200B}y ", String(repeating: "가", count: 500), "  a  b  ", "😀😀😀"]
            for item in raw {
                guard let title = ExternalSessionRules.sanitizedTitle(item) else { continue }
                #expect(title.utf16.count >= 1 && title.utf16.count <= 200)
                #expect(title == title.trimmingCharacters(in: .whitespacesAndNewlines))
                for scalar in title.unicodeScalars {
                    let category = scalar.properties.generalCategory
                    #expect(category != .control && category != .format && category != .lineSeparator && category != .paragraphSeparator, "\(scalar.value)")
                }
            }
        }

        // MARK: 출처 (CC-K: -p · SDK 실행은 목록에서 뺀다)

        @Test func entrypointsMapToTheSourceAndSDKRunsAreExcluded() {
            #expect(ExternalSessionRules.client(forEntrypoint: "claude-desktop") == .claudeDesktop)
            #expect(ExternalSessionRules.client(forEntrypoint: "cli") == .terminal)
            #expect(ExternalSessionRules.client(forEntrypoint: "claude-vscode") == .other)
            #expect(ExternalSessionRules.client(forEntrypoint: "mystery") == .other)
            #expect(ExternalSessionRules.client(forEntrypoint: nil) == nil)
            for sdk in ["sdk-cli", "sdk-ts", "sdk-py", "sdk-anything"] { #expect(ExternalSessionRules.isSDKEntrypoint(sdk)) }
            for other in ["cli", "claude-desktop", "claude-vscode", nil] { #expect(!ExternalSessionRules.isSDKEntrypoint(other)) }
        }

        // MARK: 워크트리 (계약 16장: 줄은 보이되 "Can't resume here")

        @Test func aWorktreeSessionIsRecognizedAndItsRepositoryIsTheGroup() {
            #expect(ExternalSessionRules.worktreeRepository(ofCwd: "/Users/d/Repo/.claude/worktrees/feat") == "/Users/d/Repo")
            #expect(ExternalSessionRules.worktreeRepository(ofCwd: "/Users/d/Repo/.claude/worktrees/feat/src/deep") == "/Users/d/Repo")
            #expect(ExternalSessionRules.worktreeRepository(ofCwd: "/Users/d/.claude/worktrees/taskforce-020/oa-x") == "/Users/d")
            #expect(ExternalSessionRules.worktreeRepository(ofCwd: "/Users/d/Repo/.Claude/Worktrees/feat") == "/Users/d/Repo")
        }

        @Test func otherFoldersAreNotWorktrees() {
            for cwd in ["/Users/d/Repo", "/Users/d/Repo/.claude", "/Users/d/Repo/.claude/worktrees", "/Users/d/Repo/.claude/other/x", "/Users/d/Repo/worktrees/x", "/Users/d/.claude-worktrees/x"] {
                #expect(ExternalSessionRules.worktreeRepository(ofCwd: cwd) == nil, Comment(rawValue: cwd))
            }
        }

        // MARK: 버전 (이어받기 최소 2.1.304: 빈 `--setting-sources` 격리를 2.1.304 · 2.1.306에서만 확인했다, PR2m 보안 P3-3; 계약 ES-13의 2.1.257을 올렸다)

        @Test func versionsCompareNumerically() {
            let minimum = ExternalSessionRules.minimumResumeVersion
            #expect(minimum == "2.1.304")
            #expect(ExternalSessionRules.version("2.1.304", atLeast: minimum) == true)
            #expect(ExternalSessionRules.version("2.1.306", atLeast: minimum) == true)
            #expect(ExternalSessionRules.version("2.1.303", atLeast: minimum) == false)
            #expect(ExternalSessionRules.version("2.1.257", atLeast: minimum) == false, "예전 최소: 이제 막는다")
            #expect(ExternalSessionRules.version("2.1.241", atLeast: minimum) == false)
            #expect(ExternalSessionRules.version("2.2.0", atLeast: minimum) == true)
            #expect(ExternalSessionRules.version("3.0.0", atLeast: minimum) == true)
            #expect(ExternalSessionRules.version("2.1.1000", atLeast: minimum) == true)
            #expect(ExternalSessionRules.version("2.1.304-beta.1", atLeast: minimum) == true)
            #expect(ExternalSessionRules.version("2.1", atLeast: minimum) == false)
            #expect(ExternalSessionRules.version("garbage", atLeast: minimum) == nil)
            #expect(ExternalSessionRules.version("", atLeast: minimum) == nil)
            #expect(ExternalSessionRules.version("2.1.304 (Claude Code)", atLeast: minimum) == true)
        }

        // MARK: 구간 (지표는 수가 아니라 구간만)

        @Test func countsBecomeBucketsOnly() {
            #expect([1, 2, 5, 6, 15, 16, 50].map(ExternalSessionRules.rowsBucket) == ["1", "2-5", "2-5", "6-15", "6-15", "16+", "16+"])
            #expect([0, 1, 2, 3, 9].map(ExternalSessionRules.heldBucket) == ["0", "1-2", "1-2", "3+", "3+"])
        }
    }
}
#endif
