#if os(macOS)
import Foundation

/// 턴마다 하는 외부 writer 검사의 결과 (OA 외부 세션 PR2m, 계약 ES-10 · 5.4)
public enum ExternalWriterVerdict: Equatable, Sendable {
    /// 쥔 곳이 없다
    case free
    /// 지금 그 세션을 쥔 곳이 있다
    case held(ExternalSessionHolder)
    /// 판정을 못 했다: **막는다** (fail-closed)
    case unknown
}

/// 같은 Claude id를 우리 말고 쓰는 곳이 있나 (계약 ES-10, 19장 "같은 id로 `-p --resume` 둘이 동시에 돌아도 CLI가 막지 않는다" → 이 검사와 원장 writer 검사가 유일한 보호다).
/// 이어받은 세션을 띄우는 **모든 spawn(턴 · 답 · 닫기) 직전에** 부른다. 시험은 가짜로 바꾼다
public protocol ExternalWriterChecking: Sendable {
    /// - ownPIDs: 우리 혈통의 프로세스 pid (같은 adapter가 띄워 살아 있는 것): 외부 writer로 세지 않는다
    /// - ownLastActivity: 우리 앞 턴이 끝난 시각. 기록이 그 시각까지 쓰였으면 우리 쓰기다 (바로 다음 턴이 "방금 쓰임"에 걸리지 않게). 모르면 nil (60초 창을 그대로 쓴다)
    func check(sessionID: String, workspace: String, ownPIDs: Set<Int32>, ownLastActivity: Date?) async -> ExternalWriterVerdict
}

/// 이 Mac의 실제 판정: `ExternalSessionHold`의 신호 1–4 (등록 파일 · argv · 같은 cwd의 등록 안 된 `claude` · 기록이 60초 안에 쓰임)를 그 세션 하나에 돌린다.
/// 읽는 것은 `sessions/<pid>.json`(허용 목록 이름만)과 그 세션 기록 **파일 하나의 `lstat`**(수정 시각)뿐이다: 기록 본문 · 자격 파일은 열지 않는다 (T8).
/// 기록 파일은 작업 폴더에서 Claude Code 규칙(CC-A)으로 만든 자리에서 찾는다 — 이어받은 세션은 cwd가 원래 폴더라 새 줄이 거기에 붙는다 (R1). 못 찾거나 모양이 틀리면 `unknown`
public struct LiveExternalWriterCheck: ExternalWriterChecking {
    /// 우리 마지막 턴이 끝난 시각 뒤 이 안에 쓰인 기록은 우리 것으로 본다 (프로세스가 끝나기 직전의 쓰기 · 시계 오차)
    static let ownWriteSlack: TimeInterval = 3

    private let claudeDirectory: String
    private let facts: ExternalSessionProcessFacts
    private let fileSystem: ExternalSessionFileSystem
    private let clock: @Sendable () -> Date

    public init(
        claudeDirectory: String, facts: ExternalSessionProcessFacts = .live, fileSystem: ExternalSessionFileSystem = .live, clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.claudeDirectory = claudeDirectory
        self.facts = facts
        self.fileSystem = fileSystem
        self.clock = clock
    }

    public func check(sessionID: String, workspace: String, ownPIDs: Set<Int32>, ownLastActivity: Date?) async -> ExternalWriterVerdict {
        // 프로세스 목록 · 파일 읽기는 막힐 수 있다: 협력 스레드 밖에서
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: run(sessionID: sessionID, workspace: workspace, ownPIDs: ownPIDs, ownLastActivity: ownLastActivity))
            }
        }
    }

    func run(sessionID: String, workspace: String, ownPIDs: Set<Int32>, ownLastActivity: Date?) -> ExternalWriterVerdict {
        // `--resume`에 `/` · 옵션이 들어갈 길 · 셸 글자가 든 폴더 · 해시가 붙어 확인할 수 없는 긴 폴더는 디스크를 만지기 전에 모른다로 막는다 (T4 · T5)
        guard ExternalSessionRules.isCanonicalUUID(sessionID), ExternalSessionRules.isPlainAbsolutePath(workspace),
              let directory = ExternalSessionRules.projectDirectoryName(forCwd: workspace) else { return .unknown }
        let root = fileSystem.realpath(claudeDirectory) ?? claudeDirectory
        let transcript = root + "/projects/" + directory + "/" + sessionID + ".jsonl"
        guard let entry = fileSystem.lstat(transcript), entry.kind == .regular, entry.owner == fileSystem.userID else { return .unknown }
        var modified = entry.modified
        if let ownLastActivity, modified <= ownLastActivity.addingTimeInterval(Self.ownWriteSlack) { modified = .distantPast }
        let snapshot = ExternalSessionHold.snapshot(facts: facts, fileSystem: fileSystem, sessionsDirectory: root + "/sessions", ownPIDs: ownPIDs, now: clock())
        switch ExternalSessionHold.decide(id: sessionID, cwd: workspace, modified: modified, snapshot: snapshot) {
        case .free: return .free
        case .held(let holder): return .held(holder)
        // 등록 파일의 폴더가 기록의 폴더와 다르다: 판정하지 않는다 (5.3-3)
        case .unknown, .cwdMismatch: return .unknown
        }
    }
}
#endif
