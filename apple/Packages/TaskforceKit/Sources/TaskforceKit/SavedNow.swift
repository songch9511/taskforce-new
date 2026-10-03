import Foundation

/// 이 기기에 남기는 마지막 목록 사본 (오프라인 · 새로고침 실패 화면용, Figma M15 · M19 · P10).
/// 사용자 결정 (2026-10-03): 계정마다 할 일 제목 · 기한 · 상태만 남긴다. 원문 · 인용 · 상대 · 확인 이유 · id는 남기지 않는다.
/// 행 순서는 받은 그대로(서버 순서)라 따로 적지 않는다. 오프라인 목록은 읽기만 하므로 행은 자리로 구별한다.
public struct SavedNow: Codable, Sendable, Hashable {
    /// 파일 형식. 모양을 바꾸면 올리고, 모르는 판은 읽지 않는다
    public static let version = 1

    /// 저장된 할 일 한 줄
    public struct Task: Codable, Sendable, Hashable {
        public let title: String
        public let dueDate: LocalDate?
        public let status: Status

        public init(title: String, dueDate: LocalDate?, status: Status) {
            self.title = title
            self.dueDate = dueDate
            self.status = status
        }

        enum CodingKeys: String, CodingKey {
            case title, status
            case dueDate = "due_date"
        }
    }

    /// 저장할 때의 구역. 파일에 쓰는 이름이라 앱 안의 이름과 따로 둔다
    public enum Status: String, Codable, Sendable, CaseIterable {
        case review
        case inProgress = "in_progress"
        case toDo = "to_do"
        case doneToday = "done_today"

        public init(_ group: TaskGroup) {
            switch group {
            case .review: self = .review
            case .inProgress: self = .inProgress
            case .toDo: self = .toDo
            case .doneToday: self = .doneToday
            }
        }

        public var group: TaskGroup {
            switch self {
            case .review: .review
            case .inProgress: .inProgress
            case .toDo: .toDo
            case .doneToday: .doneToday
            }
        }
    }

    public let savedAt: Date
    /// 구역 순서(Review → In Progress → To Do → Done Today), 구역 안은 받은 순서
    public let tasks: [Task]

    enum CodingKeys: String, CodingKey {
        case version, tasks
        case savedAt = "saved_at"
    }

    public init(savedAt: Date, tasks: [Task]) {
        self.savedAt = savedAt
        self.tasks = tasks
    }

    /// 받은 전체 목록(찾기 · 범위로 좁히지 않은 `TaskBoard.sections()`)에서 제목 · 기한 · 상태만 뽑는다
    public init(sections: TaskSections, savedAt: Date) {
        let tasks = TaskGroup.allCases.flatMap { group in
            sections.actions(in: group).map { Task(title: $0.title, dueDate: $0.dueDate, status: Status(group)) }
        }
        self.init(savedAt: savedAt, tasks: tasks)
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let version = try c.decode(Int.self, forKey: .version)
        guard version == Self.version else {
            throw DecodingError.dataCorruptedError(forKey: .version, in: c, debugDescription: "모르는 저장본 판 \(version)")
        }
        savedAt = try c.decode(Date.self, forKey: .savedAt)
        tasks = try c.decode([Task].self, forKey: .tasks)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(Self.version, forKey: .version)
        try c.encode(savedAt, forKey: .savedAt)
        try c.encode(tasks, forKey: .tasks)
    }

    /// 저장본의 한 행. id는 저장본 안의 자리라 같은 저장본에서는 바뀌지 않는다 (오프라인 목록의 선택 · 스크롤용, 서버 id가 아니다)
    public struct Row: Identifiable, Sendable, Hashable {
        public let id: Int
        public let task: Task
    }

    /// 그 구역의 저장된 행 (받은 순서). Done Today는 저장한 날이 `now`의 오늘(기기 시간대)일 때만 보인다:
    /// 어제 끝낸 일을 "Done Today"로 보이지 않게.
    public func rows(in group: TaskGroup, now: Date, timeZone: TimeZone = .current) -> [Row] {
        if group == .doneToday, LocalDate(date: savedAt, timeZone: timeZone) != LocalDate(date: now, timeZone: timeZone) {
            return []
        }
        return tasks.enumerated().filter { $0.element.status.group == group }.map { Row(id: $0.offset, task: $0.element) }
    }
}

/// 계정별 저장본 파일. App Group 공유 컨테이너(로그인 세션 Keychain과 같은 App Group) 아래 계정 폴더에 둔다:
/// `<App Group>/Library/Application Support/Taskforce/SavedNow/<user id>/now.json`.
/// - 기기 밖으로 나가지 않게 백업에서 뺀다 (iCloud · 컴퓨터 백업)
/// - iOS 파일 보호: 기기를 켠 뒤 처음 잠금을 풀 때까지 읽지 못한다 (`completeUntilFirstUserAuthentication`)
/// - 로그아웃 · 계정 삭제 · 계정 전환에서 지운다 (`remove(account:)` · `removeAll()`, 앱이 부른다)
/// 비밀(토큰 · 키)은 넣지 않는다.
public struct SavedNowStore: Sendable {
    public static let fileName = "now.json"

    /// 계정 폴더들이 놓이는 곳
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    /// App Group 컨테이너 아래 기본 위치.
    /// - iOS: App Group 권한이 없는 빌드면 nil (저장본 없이 둔다)
    /// - macOS: 권한과 상관없이 늘 주소를 준다(`containerURL` 동작). 서명 없는 빌드에서는 `save`가 실패하거나 시스템이 접근을 물을 수 있으니,
    ///   부르는 쪽은 `save` 실패를 무시하고 저장본 없이 둔다 (로그인 세션도 저장하지 못하는 빌드다)
    public static func defaultRoot(appGroupID: String, fileManager: FileManager = .default) -> URL? {
        fileManager.containerURL(forSecurityApplicationGroupIdentifier: appGroupID)?
            .appending(path: "Library/Application Support/Taskforce/SavedNow", directoryHint: .isDirectory)
    }

    public func save(_ saved: SavedNow, account: UUID) throws {
        let folder = folder(for: account)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: Self.protection)
        try excludeFromBackup(root)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(saved).write(to: file(for: account), options: Self.writeOptions)
    }

    /// 그 계정의 저장본. 없거나 읽지 못하면(모르는 판 · 깨짐) nil이고, 읽지 못한 파일은 지운다.
    public func load(account: UUID) -> SavedNow? {
        let url = file(for: account)
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let saved = try? decoder.decode(SavedNow.self, from: data) else {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        return saved
    }

    /// 그 계정의 저장본을 지운다 (계정 삭제). 이미 없으면 성공이다. 지우지 못하면 던진다
    public func remove(account: UUID) throws {
        try Self.removeIfPresent(folder(for: account))
    }

    /// 모든 계정의 저장본을 지운다 (로그아웃 · 계정 전환: 다른 계정의 사본이 이 기기에 남지 않게). 이미 없으면 성공이다. 지우지 못하면 던진다
    public func removeAll() throws {
        try Self.removeIfPresent(root)
    }

    private static func removeIfPresent(_ url: URL) throws {
        do {
            try FileManager.default.removeItem(at: url)
        } catch CocoaError.fileNoSuchFile {
            return
        }
    }

    func folder(for account: UUID) -> URL {
        root.appending(path: account.uuidString.lowercased(), directoryHint: .isDirectory)
    }

    func file(for account: UUID) -> URL {
        folder(for: account).appending(path: Self.fileName, directoryHint: .notDirectory)
    }

    private func excludeFromBackup(_ url: URL) throws {
        var url = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try url.setResourceValues(values)
    }

    #if os(iOS)
    private static var protection: [FileAttributeKey: Any]? { [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication] }
    private static let writeOptions: Data.WritingOptions = [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
    #else
    private static var protection: [FileAttributeKey: Any]? { nil }
    private static let writeOptions: Data.WritingOptions = [.atomic]
    #endif
}
