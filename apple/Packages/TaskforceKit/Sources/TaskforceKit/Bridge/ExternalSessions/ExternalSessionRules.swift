#if os(macOS)
import Foundation

/// 외부 세션 발견의 순수 규칙 (OA 외부 세션 PR1, 계약 5장 · T4 · T5). 파일 시스템 · 프로세스를 만지지 않는다
public enum ExternalSessionRules {
    /// 이어받기 최소 Claude Code 버전 (ES-13): `-p --resume`에서 `--system-prompt-snapshot`을 쓸 수 있는 첫 버전
    public static let minimumResumeVersion = "2.1.257"
    /// 제목 상한: 서버 `title`은 1–200자(JS 문자열 = UTF-16 단위)다. 단위로 세면 코드 포인트 수 규칙도 함께 지킨다
    public static let maxTitleUTF16 = 200
    /// 프로젝트 디렉터리 이름의 상한: 이보다 길면 Claude Code가 해시를 붙여 이름을 만들어 확인할 수 없다 (CC-A)
    public static let maxProjectDirectoryUTF16 = 200

    // MARK: 세션 id (T5)

    /// `5e5e5e5e-…-000000000001.jsonl` → `5e5e5e5e-…-000000000001`. 소문자 정규형만 (`UUID` 왕복이 같을 때). 그 밖은 nil
    public static func sessionID(fromFileName name: String) -> String? {
        let suffix = ".jsonl"
        guard name.hasSuffix(suffix) else { return nil }
        let stem = String(name.dropLast(suffix.count))
        return isCanonicalUUID(stem) ? stem : nil
    }

    /// 소문자 정규 UUID인가. `--resume`에 `/` · 공백 · 옵션이 들어갈 길을 막는다: 글자 · 길이 · 왕복을 모두 본다
    public static func isCanonicalUUID(_ text: String) -> Bool {
        guard text.utf8.count == 36, let uuid = UUID(uuidString: text) else { return false }
        return uuid.uuidString.lowercased() == text
    }

    // MARK: cwd

    /// 셸 없이 `chdir`에 줘도 되는 평범한 절대 경로인가: `/`로 시작 · 제어 글자(NUL · 개행 포함) 없음 · 빈 성분 · `.` · `..` 없음 · 끝의 `/` 없음(루트 제외)
    public static func isPlainAbsolutePath(_ path: String) -> Bool {
        guard path.hasPrefix("/") else { return false }
        if path == "/" { return true }
        guard !path.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }), !path.hasSuffix("/") else { return false }
        for component in path.dropFirst().split(separator: "/", omittingEmptySubsequences: false) {
            if component.isEmpty || component == "." || component == ".." { return false }
        }
        return true
    }

    /// Claude Code의 프로젝트 디렉터리 이름 규칙 (CC-A): cwd의 영숫자 아닌 글자(ASCII 기준, UTF-16 단위마다)를 `-`로. 200단위를 넘으면 해시가 붙어 확인할 수 없으므로 nil
    public static func projectDirectoryName(forCwd cwd: String) -> String? {
        let units = Array(cwd.utf16)
        guard units.count <= maxProjectDirectoryUTF16 else { return nil }
        var out = [UInt16]()
        out.reserveCapacity(units.count)
        for unit in units {
            let alphanumeric = (unit >= 0x30 && unit <= 0x39) || (unit >= 0x41 && unit <= 0x5A) || (unit >= 0x61 && unit <= 0x7A)
            out.append(alphanumeric ? unit : 0x2D)
        }
        return String(decoding: out, as: UTF16.self)
    }

    // MARK: 제목 (ES-01)

    /// 서버 제목 규칙과 같은 모양으로 정리한다: 공백류는 한 칸으로 접고, 그 밖의 제어 글자 · 서식 글자(방향 바꿈 · 폭 없는 공백 포함)는 지운다.
    /// 200 UTF-16 단위까지(글자 중간에서 자르지 않고, 끝 공백은 지운다). 남는 것이 없으면 nil
    public static func sanitizedTitle(_ raw: String) -> String? {
        var scalars = String.UnicodeScalarView()
        var pendingSpace = false
        for scalar in raw.unicodeScalars {
            let category = scalar.properties.generalCategory
            if scalar.properties.isWhitespace || category == .lineSeparator || category == .paragraphSeparator {
                pendingSpace = !scalars.isEmpty
                continue
            }
            if category == .control || category == .format { continue }
            if pendingSpace {
                scalars.append(" ")
                pendingSpace = false
            }
            scalars.append(scalar)
        }
        var title = ""
        var used = 0
        for character in String(scalars) {
            let size = character.utf16.count
            if used + size > maxTitleUTF16 { break }
            title.append(character)
            used += size
        }
        while let last = title.unicodeScalars.last, last.properties.isWhitespace { title.unicodeScalars.removeLast() }
        return title.isEmpty ? nil : title
    }

    // MARK: 출처

    /// `claude-desktop` → 데스크톱, `cli` → 터미널, 그 밖의 이름 → other. 모르면(기록 머리에 없다) nil
    public static func client(forEntrypoint entrypoint: String?) -> ExternalSessionClient? {
        guard let entrypoint else { return nil }
        switch entrypoint {
        case "claude-desktop": return .claudeDesktop
        case "cli": return .terminal
        default: return .other
        }
    }

    /// `-p` · SDK 실행(`sdk-cli` · `sdk-ts` …)은 picker · `--continue`에서 빠지므로 목록에서도 뺀다 (CC-K). 못 읽으면 남긴다
    public static func isSDKEntrypoint(_ entrypoint: String?) -> Bool {
        entrypoint?.hasPrefix("sdk-") == true
    }

    // MARK: 워크트리

    /// cwd가 `<저장소>/.claude/worktrees/<이름>[/…]` 안이면 그 저장소 폴더. 아니면 nil. 이름은 대소문자를 접어 본다 (폴더 규칙의 민감 이름 규칙과 같은 접기)
    public static func worktreeRepository(ofCwd cwd: String) -> String? {
        let components = cwd.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard components.count >= 3 else { return nil }
        for index in 0..<(components.count - 2)
        where WorkspaceFolderRules.folded(components[index]) == ".claude" && WorkspaceFolderRules.folded(components[index + 1]) == "worktrees" {
            return index == 0 ? "/" : "/" + components[0..<index].joined(separator: "/")
        }
        return nil
    }

    // MARK: 버전

    /// `version`이 `minimum` 이상인가. 앞의 숫자 세 묶음만 본다(`2.1.257-beta` · `2.1.257 (Claude Code)`도 읽는다). 숫자를 못 읽으면 nil
    public static func version(_ version: String, atLeast minimum: String) -> Bool? {
        guard let have = parts(version), let need = parts(minimum) else { return nil }
        return have.lexicographicallyPrecedes(need) == false
    }

    private static func parts(_ text: String) -> [Int]? {
        guard let match = text.firstMatch(of: /(\d{1,9})(?:\.(\d{1,9}))?(?:\.(\d{1,9}))?/) else { return nil }
        return [match.1, match.2, match.3].map { $0.flatMap { Int($0) } ?? 0 }
    }

    // MARK: 구간

    /// 행 수 구간 (지표는 수가 아니라 구간만): `1` · `2-5` · `6-15` · `16+`
    public static func rowsBucket(_ count: Int) -> String {
        switch count {
        case ..<2: "1"
        case 2...5: "2-5"
        case 6...15: "6-15"
        default: "16+"
        }
    }

    /// 돌고 있는 줄 수 구간: `0` · `1-2` · `3+`
    public static func heldBucket(_ count: Int) -> String {
        switch count {
        case ..<1: "0"
        case 1...2: "1-2"
        default: "3+"
        }
    }
}
#endif
