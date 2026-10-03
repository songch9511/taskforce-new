import Foundation

/// iPhone 목록 (Figma 156:6 P1 · P10 · P11)의 화면 없는 규칙. 순서 · 구역은 서버와 `TaskBoard`가 정하고, 여기서는 보이는 글자 · 쓰기 가능 여부만 정한다.
public enum PhoneHome {
    /// 검색칸 자리표시 (P1 `Search 23 tasks`, P10 `Search 23 saved tasks`).
    /// 개수는 열린 할 일(Review + In Progress + To Do)로, 런처 범위 All Tasks와 같은 수다 (`TaskScope.allTasks`). 없으면 개수 없이
    public static func searchPrompt(count: Int, saved: Bool) -> String {
        let noun = saved ? "saved task" : "task"
        switch count {
        case ...0: return "Search \(noun)s"
        case 1: return "Search 1 \(noun)"
        default: return "Search \(count) \(noun)s"
        }
    }

    /// Review 카드 자리 (P1 `1 of 4`). 하나뿐이면 보이지 않는다
    public static func reviewPosition(_ index: Int, of count: Int) -> String? {
        guard count > 1, (0..<count).contains(index) else { return nil }
        return "\(index + 1) of \(count)"
    }

    /// 확정 · 넘기기 · 진행 상태 바꾸기 · 삭제를 보낼 수 있는지.
    /// 오프라인이거나 보이는 목록이 저장본이면 막는다: 저장본에는 서버 id가 없고, 쓰기를 모아 두었다 보내지 않는다 (P10 `Nothing is saved for later.`)
    public static func canWrite(_ state: RefreshState, showingSavedCopy: Bool) -> Bool {
        !state.isOffline && !showingSavedCopy
    }

    /// 저장본의 그 구역 행을 찾는 말로 거른다 (저장된 제목만, `TaskFilter`). Done Today는 저장한 날이 오늘일 때만 (`SavedNow.rows`)
    public static func savedRows(
        _ saved: SavedNow, in group: TaskGroup, matching query: String, now: Date, timeZone: TimeZone = .current
    ) -> [SavedNow.Row] {
        saved.rows(in: group, now: now, timeZone: timeZone).filter { TaskFilter.matches(text: $0.task.title, query: query) }
    }
}

extension RefreshState {
    /// 보이는 목록이 이번 실행에서 새로 받은 것이 아니라 저장해 둔 것인지 (오프라인 · 새로고침 실패 뒤): 검색칸이 `Search … saved tasks`
    public var showsSavedTasks: Bool {
        switch self {
        case .offlineSaved, .refreshFailed(_, .some): true
        default: false
        }
    }
}

extension FailedSources {
    /// 실패 원문 줄 (U1 PR4에서 채택한 문구): "Couldn’t read 2 sources"
    public var title: String {
        count == 1 ? "Couldn’t read 1 source" : "Couldn’t read \(count) sources"
    }
}
