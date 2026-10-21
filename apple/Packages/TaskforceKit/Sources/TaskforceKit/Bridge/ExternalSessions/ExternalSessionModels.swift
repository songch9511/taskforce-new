#if os(macOS)
import Foundation

// 외부 세션(Taskforce 밖에서 시작한 Claude Code 세션) 발견의 값 (OA 외부 세션 PR1, 계약 5 · 8장 · 16장).
// 이 Mac 안에서만 만들어지고 메모리에만 둔다. 서버로 가는 것은 제목 · 상태 · 마지막 활동 · 불투명 id뿐이다 (`ExternalSessionReport`).
// 로그에는 어떤 값도 남기지 않는다: 행의 `description`은 글 · 경로 · id 없이 상태만 말한다.

/// 세션을 시작한 곳 (기록 머리의 `entrypoint`). Claude 데스크톱 · 터미널만 이름을 붙이고 그 밖은 비운다 (계약 17장)
public enum ExternalSessionClient: Equatable, Sendable {
    case claudeDesktop
    case terminal
    /// 알려진 이름이 아닌 출처(VS Code 등): 이름을 쓰지 않는다
    case other
}

/// 지금 그 세션을 쥔 곳 (5.4)
public enum ExternalSessionHolder: Equatable, Sendable {
    case claudeApp
    case terminal
    case background
    case unknown
}

/// 이어받을 수 없는 이유 (8.2 · 계약 17장의 말: Worktree · Folder isn't allowed · Unreadable · Update Claude Code)
public enum ExternalSessionBlock: Equatable, Sendable {
    case worktree
    case folderNotAllowed
    case unreadable
    case updateClaudeCode
}

/// 줄의 상태 (8.2). 위에서부터 먼저 맞는 것
public enum ExternalSessionStatus: Equatable, Sendable {
    /// 아무 곳에서도 열려 있지 않고 이어받을 수 있다 ("Idle")
    case available
    /// 이미 Taskforce가 이어받았다 ("In Taskforce")
    case inTaskforce
    case held(ExternalSessionHolder)
    /// 판정에 실패했다 (fail-closed: 막는다)
    case couldNotCheck
    case cannotResume(ExternalSessionBlock)
}

public struct ExternalSessionRow: Identifiable, Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    /// 소문자 정규 UUID (기록 파일 이름). **이 Mac 안에서만** 쓴다: 서버 · 로그 · 지표에 가지 않는다
    public let id: String
    /// 서버로 가는 불투명 id (id의 HMAC, 열쇠는 이 Mac에만 있다)
    public let ref: String
    /// 기록의 `custom-title` / `agent-name` (제어 글자 제거, 200자). 없으면 nil
    public var title: String?
    /// 작업 폴더(realpath, 이 Mac 안에서만). 확인할 수 없으면 nil
    public var folderPath: String?
    /// 묶음 머리가 될 폴더: 워크트리는 그 저장소 폴더, 그 밖은 작업 폴더
    public var groupPath: String?
    /// 마지막 활동 (기록 파일의 수정 시각)
    public var lastActivity: Date
    /// 처음 생긴 시각 (기록 파일의 생성 시각, 없으면 수정 시각). 레일 점이 쓴다
    public var created: Date
    public var client: ExternalSessionClient?
    public var status: ExternalSessionStatus

    public init(
        id: String, ref: String, title: String?, folderPath: String?, groupPath: String?, lastActivity: Date, created: Date, client: ExternalSessionClient?,
        status: ExternalSessionStatus
    ) {
        self.id = id
        self.ref = ref
        self.title = title
        self.folderPath = folderPath
        self.groupPath = groupPath
        self.lastActivity = lastActivity
        self.created = created
        self.client = client
        self.status = status
    }

    /// 묶음 머리 이름: 묶음 폴더의 마지막 성분 (경로가 아니다). 폴더를 모르면 nil
    public var groupName: String? {
        guard let groupPath else { return nil }
        let name = (groupPath as NSString).lastPathComponent
        return name.isEmpty || name == "/" ? nil : name
    }

    public var description: String { "ExternalSessionRow(status: \(status))" }
    public var debugDescription: String { description }
}

/// 훑을 때 잡은 "누구의 어느 Mac"인가 (계정 파티션 + 이 Mac의 bridge id). 보고는 이 값으로만 나간다:
/// 훑은 뒤 보내기 전에 계정이 바뀌었으면 버린다 (다른 계정의 열쇠로 만든 id가 새 계정의 목록에 섞이지 않게)
public struct ExternalSessionOrigin: Equatable, Sendable {
    /// 계정 파티션 id (계정마다 다르다)
    public var partition: String
    public var bridgeID: UUID

    public init(partition: String, bridgeID: UUID) {
        self.partition = partition
        self.bridgeID = bridgeID
    }
}

/// 한 번 훑은 결과
public struct ExternalSessionScan: Equatable, Sendable {
    public enum Failure: Equatable, Sendable {
        /// `~/.claude`(또는 `projects`)가 없다: Claude Code를 쓴 적이 없다
        case notFound
        /// 읽을 수 없다 · 발견 루트가 기호 링크 등으로 밖을 가리킨다 · probe의 설정 폴더와 다르다 (ES-05)
        case unreadable
    }

    public var rows: [ExternalSessionRow]
    public var failure: Failure?
    /// 상한(파일 500 · 읽기 32 MiB · 줄 50)에 걸려 일부를 건너뛰었다
    public var truncated: Bool
    /// 훑을 때 잡은 계정 · bridge. 이 Mac에 bridge가 아직 없으면 nil (그때는 서버에 알리지 않는다). 스캐너는 모르고 부르는 쪽(앱)이 채운다
    public var origin: ExternalSessionOrigin?

    public init(rows: [ExternalSessionRow], failure: Failure? = nil, truncated: Bool = false, origin: ExternalSessionOrigin? = nil) {
        self.rows = rows
        self.failure = failure
        self.truncated = truncated
        self.origin = origin
    }
}
#endif
