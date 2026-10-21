#if os(macOS)
import Foundation

/// 이 Mac의 Claude Code 세션 훑기 (OA 외부 세션 PR1, 계약 5장 · 9장). 발견 · 판정은 이 actor 하나에서 직렬이다.
///
/// - 읽는 범위: `~/.claude/projects/<디렉터리>/<소문자 UUID>.jsonl`의 이름 · 크기 · 시각, 머리 64 KiB · 꼬리 256 KiB의 몇 칸, `sessions/<pid>.json`. 그 밖은 열지 않는다
/// - 안전: 발견 루트의 `projects`는 기호 링크가 아니고 realpath가 루트 안이다 · 디렉터리 · 파일 모두 기호 링크 아님 · 이 사용자 소유 일반 파일만 (T2)
/// - 상한: 훑는 파일 500 · 총 읽기 32 MiB · 줄 50 · 나열 5만 항목 (T3). 상한에 걸리면 `truncated`
/// - 결과는 메모리에만 둔다. 같은 파일(수정 시각 · 크기가 같다)은 머리 · 꼬리를 다시 읽지 않는다 (디스크 캐시 없음)
/// - 모르면 막는다: 판정을 못 하면 `couldNotCheck`, cwd를 확인하지 못하면 `cannotResume(.unreadable)`
public actor ExternalSessionScanner {
    public struct Configuration: Sendable {
        /// `$HOME/.claude` (ES-05: 이것으로 고정)
        public var claudeDirectory: String
        /// probe가 준 `configDirectory`: 있으면 그 realpath가 발견 루트와 같을 때만 목록을 낸다
        public var expectedConfigDirectory: String?
        public var folderRules: WorkspaceFolderRules
        /// 앱 데이터 · bridge root · 세션 폴더 루트(realpath): 이 안이 cwd인 세션은 Taskforce가 띄운 것이라 뺀다
        public var protectedRoots: [String]
        /// Taskforce가 띄운 세션의 Claude id (세션 폴더 상태): 뺀다
        public var taskforceSessionIDs: @Sendable () -> Set<String>
        /// 이미 이어받은 세션의 Claude id: "In Taskforce" 줄로 남긴다
        public var attachedSessionIDs: @Sendable () -> Set<String>
        /// 우리 혈통의 pid: 외부 writer로 세지 않는다
        public var ownPIDs: @Sendable () -> Set<Int32>
        /// 이 Mac의 `claude --version` (probe). 모르면 nil
        public var installedCLIVersion: @Sendable () -> String?
        public var window: TimeInterval = 7 * 24 * 3600
        public var maxFiles = 500
        public var maxRows = 50
        public var maxListedEntries = 50_000
        public var readBudget: Int64 = 32 << 20
        public var minimumSize: Int64 = 1024

        public init(
            claudeDirectory: String, expectedConfigDirectory: String? = nil, folderRules: WorkspaceFolderRules, protectedRoots: [String] = [],
            taskforceSessionIDs: @escaping @Sendable () -> Set<String> = { [] }, attachedSessionIDs: @escaping @Sendable () -> Set<String> = { [] },
            ownPIDs: @escaping @Sendable () -> Set<Int32> = { [] }, installedCLIVersion: @escaping @Sendable () -> String? = { nil }
        ) {
            self.claudeDirectory = claudeDirectory
            self.expectedConfigDirectory = expectedConfigDirectory
            self.folderRules = folderRules
            self.protectedRoots = protectedRoots
            self.taskforceSessionIDs = taskforceSessionIDs
            self.attachedSessionIDs = attachedSessionIDs
            self.ownPIDs = ownPIDs
            self.installedCLIVersion = installedCLIVersion
        }
    }

    private struct Candidate {
        var id: String
        var directory: String
        var path: String
        var modified: Date
        var created: Date
        var size: Int64
    }

    private struct Cached {
        var path: String
        var modified: Date
        var size: Int64
        var meta: ExternalSessionTranscript.Meta?
    }

    private let configuration: Configuration
    private let fileSystem: ExternalSessionFileSystem
    private let processFacts: ExternalSessionProcessFacts
    private let key: ExternalSessionKey
    private let clock: @Sendable () -> Date
    private var cache: [String: Cached] = [:]

    public init(
        configuration: Configuration, fileSystem: ExternalSessionFileSystem = .live, processFacts: ExternalSessionProcessFacts = .live, key: ExternalSessionKey,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.configuration = configuration
        self.fileSystem = fileSystem
        self.processFacts = processFacts
        self.key = key
        self.clock = clock
    }

    public func scan() -> ExternalSessionScan {
        let now = clock()
        let fs = fileSystem
        // 발견 루트: ~/.claude (없으면 Claude Code를 쓴 적이 없다)
        guard let rootEntry = fs.lstat(configuration.claudeDirectory) else { return ExternalSessionScan(rows: [], failure: .notFound) }
        guard let root = fs.realpath(configuration.claudeDirectory), rootEntry.kind == .directory || rootEntry.kind == .symlink,
              let realRoot = fs.lstat(root), realRoot.kind == .directory, realRoot.owner == fs.userID else { return ExternalSessionScan(rows: [], failure: .unreadable) }
        if let expected = configuration.expectedConfigDirectory, fs.realpath(expected) != root { return ExternalSessionScan(rows: [], failure: .unreadable) }
        let projects = root + "/projects"
        switch fs.lstat(projects) {
        case nil: return ExternalSessionScan(rows: [], failure: nil)
        case let entry?:
            guard entry.kind == .directory, entry.owner == fs.userID, fs.realpath(projects) == projects else { return ExternalSessionScan(rows: [], failure: .unreadable) }
        }

        var truncated = false
        var candidates: [Candidate] = []
        var listed = 0
        // 나열 자체가 상한을 지킨다: 폴더를 끝까지 읽은 뒤 세지 않고, 남은 칸 + 1개까지만 읽어 넘쳤는지 안다
        switch fs.list(projects, configuration.maxListedEntries + 1) {
        case .missing: return ExternalSessionScan(rows: [], failure: nil)
        case .failed: return ExternalSessionScan(rows: [], failure: .unreadable)
        case .entries(let directories):
            if directories.count > configuration.maxListedEntries { truncated = true }
            collect: for directory in directories.sorted(by: { $0.name < $1.name })
            where directory.kind == .directory && directory.owner == fs.userID && ExternalSessionReadAllowList.isProjectDirectory(directory.name) {
                let remaining = configuration.maxListedEntries - listed
                guard case .entries(let files) = fs.list(projects + "/" + directory.name, remaining + 1) else { continue }
                for file in files.prefix(remaining) {
                    listed += 1
                    guard file.kind == .regular, file.owner == fs.userID, file.size >= configuration.minimumSize, ExternalSessionReadAllowList.isTranscript(file: file.name),
                          let id = ExternalSessionRules.sessionID(fromFileName: file.name) else { continue }
                    candidates.append(Candidate(id: id, directory: directory.name, path: projects + "/" + directory.name + "/" + file.name, modified: file.modified, created: file.created, size: file.size))
                }
                if files.count > remaining {
                    truncated = true
                    break collect
                }
            }
        }

        let own = configuration.ownPIDs()
        let hold = ExternalSessionHold.snapshot(facts: processFacts, fileSystem: fs, sessionsDirectory: root + "/sessions", ownPIDs: own, now: now)
        let runningIDs = Set(hold.live.map(\.sessionID)).union(hold.argumentIDs ?? [])
        // 창 안의 것 + 지금 돌고 있는 것(날짜와 상관없이). 같은 id가 두 디렉터리에 있으면 더 최근 것 하나
        var newest: [String: Candidate] = [:]
        for candidate in candidates where now.timeIntervalSince(candidate.modified) <= configuration.window || runningIDs.contains(candidate.id) {
            if let known = newest[candidate.id], known.modified >= candidate.modified { continue }
            newest[candidate.id] = candidate
        }
        var chosen = newest.values.sorted { ($0.modified, $0.id) > ($1.modified, $1.id) }
        if chosen.count > configuration.maxFiles {
            chosen = Array(chosen.prefix(configuration.maxFiles))
            truncated = true
        }

        let taskforceIDs = configuration.taskforceSessionIDs()
        let attachedIDs = configuration.attachedSessionIDs()
        let installed = configuration.installedCLIVersion()
        let cliTooOld = installed.flatMap { ExternalSessionRules.version($0, atLeast: ExternalSessionRules.minimumResumeVersion) } == false
        var budget = ExternalSessionTranscript.Budget(remaining: configuration.readBudget)
        var fresh: [String: Cached] = [:]
        var rows: [ExternalSessionRow] = []
        for candidate in chosen {
            if taskforceIDs.contains(candidate.id) { continue }
            let meta: ExternalSessionTranscript.Meta?
            if let hit = cache[candidate.id], hit.path == candidate.path, hit.modified == candidate.modified, hit.size == candidate.size {
                meta = hit.meta
            } else if budget.exhausted {
                truncated = true
                continue
            } else {
                meta = ExternalSessionTranscript.read(path: candidate.path, id: candidate.id, size: candidate.size, fileSystem: fs, budget: &budget)
            }
            fresh[candidate.id] = Cached(path: candidate.path, modified: candidate.modified, size: candidate.size, meta: meta)
            if ExternalSessionRules.isSDKEntrypoint(meta?.entrypoint) { continue }
            // Taskforce가 띄운 세션: cwd가 앱 데이터 · bridge root · 세션 폴더 안이다 (글자만 본다 — cwd를 파일 시스템으로 열지 않는다)
            if let cwd = meta?.cwd, ExternalSessionRules.isPlainAbsolutePath(cwd), configuration.protectedRoots.contains(where: { GateFileSystem.isInside(cwd, root: $0) }) { continue }
            rows.append(row(for: candidate, meta: meta, hold: hold, attached: attachedIDs.contains(candidate.id), cliTooOld: cliTooOld))
        }
        cache = fresh
        rows.sort { lhs, rhs in
            let (l, r) = (ExternalSessionGrouping.rank(lhs.status), ExternalSessionGrouping.rank(rhs.status))
            return l != r ? l < r : (lhs.lastActivity, lhs.id) > (rhs.lastActivity, rhs.id)
        }
        if rows.count > configuration.maxRows {
            rows = Array(rows.prefix(configuration.maxRows))
            truncated = true
        }
        return ExternalSessionScan(rows: rows, failure: nil, truncated: truncated)
    }

    /// 열기 직전의 다시 확인 (F4 · 보안 검토 P3): 마지막 훑기가 본 세션 하나에 같은 쥠 판정(등록 파일 · argv · 같은 폴더의 claude · 최근 기록)을 지금 사실로 다시 돌린다.
    /// 기록은 시각만 본다(열어 읽지 않는다). 훑은 적 없는 id · 기록이 사라진 세션은 nil(모른다): 부른 쪽이 막는다. `.available`은 지금 쥔 곳이 없다는 뜻이다
    public func recheck(id: String) -> ExternalSessionStatus? {
        guard let cached = cache[id], let entry = fileSystem.lstat(cached.path), entry.kind == .regular, entry.owner == fileSystem.userID else { return nil }
        if configuration.attachedSessionIDs().contains(id) { return .inTaskforce }
        let root = fileSystem.realpath(configuration.claudeDirectory) ?? configuration.claudeDirectory
        let hold = ExternalSessionHold.snapshot(facts: processFacts, fileSystem: fileSystem, sessionsDirectory: root + "/sessions", ownPIDs: configuration.ownPIDs(), now: clock())
        // 훑을 때와 같은 신뢰: 기록 안의 cwd는 평범한 절대 경로이고 부모 디렉터리 이름과 같을 때만 힌트로 쓴다
        let directory = ((cached.path as NSString).deletingLastPathComponent as NSString).lastPathComponent
        var cwd: String?
        if let hint = cached.meta?.cwd, ExternalSessionRules.isPlainAbsolutePath(hint), ExternalSessionRules.projectDirectoryName(forCwd: hint) == directory { cwd = hint }
        switch ExternalSessionHold.decide(id: id, cwd: cwd, modified: entry.modified, snapshot: hold) {
        case .free: return .available
        case .held(let holder): return .held(holder)
        case .unknown: return .couldNotCheck
        case .cwdMismatch: return .cannotResume(.unreadable)
        }
    }

    private enum CwdState {
        case ok
        case worktree
        case folderNotAllowed
        case unreadable
    }

    /// `~/.claude/worktrees/<이름>`처럼 사용자가 저장소 밖에 모아 둔 워크트리 자리다 (저장소로 읽히는 것이 홈이거나 `~/.claude` 안): 홈 폴더 이름 밑으로 묶지 않고 일반 폴더 규칙의 결과를 쓴다
    private func isUsersOwnWorktreeLayout(repository: String) -> Bool {
        repository == configuration.folderRules.home || GateFileSystem.isInside(repository, root: configuration.claudeDirectory)
    }

    private func row(for candidate: Candidate, meta: ExternalSessionTranscript.Meta?, hold: ExternalSessionHold.Snapshot, attached: Bool, cliTooOld: Bool) -> ExternalSessionRow {
        var state = CwdState.unreadable
        var folderPath: String?
        var groupPath: String?
        var trustedCwd: String?
        // 기록 안의 cwd는 힌트일 뿐이다 (5.3): 평범한 절대 경로이고 그 이름이 부모 디렉터리 이름과 정확히 같아야 한다.
        // **cwd를 파일 시스템으로 열지 않는다** (stat · realpath 0): Documents · Desktop 같은 보호 폴더 안이면 macOS 접근 동의 창이 앱 이름으로 뜬다.
        // Claude Code의 cwd는 이미 실제 경로이고, 폴더가 지금도 있는지는 이어받을 때(사용자 행동) 확인한다
        if let cwd = meta?.cwd, ExternalSessionRules.isPlainAbsolutePath(cwd), ExternalSessionRules.projectDirectoryName(forCwd: cwd) == candidate.directory {
            trustedCwd = cwd
            if let repository = ExternalSessionRules.worktreeRepository(ofCwd: cwd), !isUsersOwnWorktreeLayout(repository: repository) {
                state = .worktree
                folderPath = cwd
                groupPath = repository
            } else {
                switch configuration.folderRules.validate(cwd) {
                case .success(let real):
                    state = .ok
                    folderPath = real
                case .failure(let why):
                    switch why {
                    case .notAbsolute, .notFound, .notADirectory: state = .unreadable
                    default: state = .folderNotAllowed
                    }
                    folderPath = cwd
                }
                groupPath = folderPath
            }
        }
        let status: ExternalSessionStatus
        if attached {
            status = .inTaskforce
        } else {
            switch ExternalSessionHold.decide(id: candidate.id, cwd: trustedCwd, modified: candidate.modified, snapshot: hold) {
            case .cwdMismatch: status = .cannotResume(.unreadable)
            case .held(let holder): status = .held(holder)
            case .unknown: status = .couldNotCheck
            case .free:
                switch state {
                case .unreadable: status = .cannotResume(.unreadable)
                case .worktree: status = .cannotResume(.worktree)
                case .folderNotAllowed: status = .cannotResume(.folderNotAllowed)
                case .ok: status = cliTooOld ? .cannotResume(.updateClaudeCode) : .available
                }
            }
        }
        return ExternalSessionRow(
            id: candidate.id, ref: key.ref(forSessionID: candidate.id), title: meta?.title, folderPath: folderPath, groupPath: groupPath, lastActivity: candidate.modified,
            created: candidate.created, client: ExternalSessionRules.client(forEntrypoint: meta?.entrypoint), status: status
        )
    }
}

/// 묶음 (레일 패널의 묶음 머리 = 폴더 이름, 로컬)
public struct ExternalSessionGroup: Identifiable, Equatable, Sendable {
    public var id: String
    /// 머리 이름: Taskforce 프로젝트 폴더와 같으면 그 프로젝트 이름, 아니면 폴더 이름. 폴더를 모르면 nil(머리 없는 묶음)
    public var name: String?
    public var rows: [ExternalSessionRow]

    public init(id: String, name: String?, rows: [ExternalSessionRow]) {
        self.id = id
        self.name = name
        self.rows = rows
    }
}

public enum ExternalSessionGrouping {
    /// 묶음은 줄 4개까지 보이고 넘으면 머리 오른쪽에 "Show all" (DZ 승인)
    public static let visibleLimit = 4

    /// 묶음에서 지금 보일 줄: 펼치지 않았으면 처음 4개
    public static func visibleRows(_ group: ExternalSessionGroup, expanded: Bool) -> [ExternalSessionRow] {
        expanded || group.rows.count <= visibleLimit ? group.rows : Array(group.rows.prefix(visibleLimit))
    }

    /// 묶음 안 순서: 다른 곳에서 돌고 있음 → 이어받기 가능(Idle) → 그 밖 → 이미 이어받음
    public static func rank(_ status: ExternalSessionStatus) -> Int {
        switch status {
        case .held: 0
        case .available: 1
        case .couldNotCheck, .cannotResume: 2
        case .inTaskforce: 3
        }
    }

    /// 폴더(워크트리는 저장소)별 묶음. 묶음 순서는 가장 최근 활동 순, 폴더를 모르는 줄은 머리 없는 묶음으로 맨 끝
    public static func groups(_ rows: [ExternalSessionRow], projectName: (String) -> String? = { _ in nil }) -> [ExternalSessionGroup] {
        var byPath: [String: [ExternalSessionRow]] = [:]
        var unknown: [ExternalSessionRow] = []
        for row in rows {
            if let path = row.groupPath { byPath[path, default: []].append(row) } else { unknown.append(row) }
        }
        let ordered: ([ExternalSessionRow]) -> [ExternalSessionRow] = { items in
            items.sorted { lhs, rhs in
                let (l, r) = (rank(lhs.status), rank(rhs.status))
                return l != r ? l < r : (lhs.lastActivity, lhs.id) > (rhs.lastActivity, rhs.id)
            }
        }
        var groups = byPath.map { path, items -> ExternalSessionGroup in
            let sorted = ordered(items)
            let name = projectName(path) ?? sorted.first?.groupName
            return ExternalSessionGroup(id: path, name: name, rows: sorted)
        }
        groups.sort { lhs, rhs in
            let (l, r) = (lhs.rows.map(\.lastActivity).max() ?? .distantPast, rhs.rows.map(\.lastActivity).max() ?? .distantPast)
            return l != r ? l > r : lhs.id < rhs.id
        }
        if !unknown.isEmpty { groups.append(ExternalSessionGroup(id: "", name: nil, rows: ordered(unknown))) }
        return groups
    }
}
#endif
