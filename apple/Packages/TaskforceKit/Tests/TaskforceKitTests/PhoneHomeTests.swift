import Foundation
import Testing
@testable import TaskforceKit

/// iPhone 목록 셸 (U1 PR5b, Figma P1 · P10): 검색칸 자리표시 · Review 자리 · 쓰기 막기 · 저장본 찾기 · 실패 원문 줄
struct PhoneHomeTests {
    let savedAt = Date(timeIntervalSince1970: 1_791_000_000)

    /// P1 `Search 23 tasks` · P10 `Search 23 saved tasks` (23 = Review 4 + In Progress 5 + To Do 14, Done Today는 세지 않는다)
    @Test func searchPromptCountsOpenTasks() {
        let live = TaskScope.allTasks.count(in: ListFixture.sections, changed: [])
        #expect(PhoneHome.searchPrompt(count: live, saved: false) == "Search 23 tasks")
        let saved = SavedNow(sections: ListFixture.sections, savedAt: savedAt)
        #expect(PhoneHome.searchPrompt(count: TaskScope.allTasks.count(in: saved, now: savedAt), saved: true) == "Search 23 saved tasks")
    }

    @Test func searchPromptSingularAndEmpty() {
        #expect(PhoneHome.searchPrompt(count: 1, saved: false) == "Search 1 task")
        #expect(PhoneHome.searchPrompt(count: 1, saved: true) == "Search 1 saved task")
        #expect(PhoneHome.searchPrompt(count: 0, saved: false) == "Search tasks")
        #expect(PhoneHome.searchPrompt(count: 0, saved: true) == "Search saved tasks")
    }

    /// 행 누르기: 실행을 쓸 수 있는 계정(credits 200)만 상세(P2), 나머지는 U1 PR5b 그대로 근거 펼치기 (운영 회귀 0)
    @Test func rowTapOpensDetailOnlyWhenExecutionIsAvailable() {
        #expect(PhoneHome.rowTap(executionAvailable: true) == .openDetail)
        #expect(PhoneHome.rowTap(executionAvailable: false) == .expandSource)
    }

    /// P1 Review 카드 `1 of 4`. 하나뿐이거나 자리가 없으면 보이지 않는다
    @Test func reviewPosition() {
        #expect(PhoneHome.reviewPosition(0, of: 4) == "1 of 4")
        #expect(PhoneHome.reviewPosition(3, of: 4) == "4 of 4")
        #expect(PhoneHome.reviewPosition(0, of: 1) == nil)
        #expect(PhoneHome.reviewPosition(4, of: 4) == nil)
        #expect(PhoneHome.reviewPosition(0, of: 0) == nil)
    }

    /// P10: 오프라인이거나 저장본을 보이는 동안은 Confirm · Dismiss · 상태 바꾸기를 보내지 않는다 (모아 두었다 보내지도 않는다)
    @Test func writesWaitForAConnection() {
        let at = Date(timeIntervalSince1970: 1_791_000_000)
        #expect(PhoneHome.canWrite(.live, showingSavedCopy: false))
        #expect(!PhoneHome.canWrite(.offlineSaved(since: at, savedAt: at), showingSavedCopy: false))
        #expect(!PhoneHome.canWrite(.offlineEmpty(since: at), showingSavedCopy: false))
        // 새로고침 실패: 이번 실행에서 받은 목록이면 온라인이라 보낼 수 있고, 저장본이면 id가 없어 못 보낸다
        #expect(PhoneHome.canWrite(.refreshFailed(at: at, savedAt: at), showingSavedCopy: false))
        #expect(!PhoneHome.canWrite(.refreshFailed(at: at, savedAt: at), showingSavedCopy: true))
        #expect(!PhoneHome.canWrite(.loading, showingSavedCopy: true))
    }

    /// 검색칸이 `saved`인 때: 오프라인 + 보일 목록, 새로고침 실패 + 보일 목록 (Mac `showsSavedTasks`와 같은 규칙)
    @Test func savedTasksWording() {
        let at = Date(timeIntervalSince1970: 1_791_000_000)
        #expect(RefreshState.offlineSaved(since: at, savedAt: at).showsSavedTasks)
        #expect(RefreshState.refreshFailed(at: at, savedAt: at).showsSavedTasks)
        #expect(!RefreshState.refreshFailed(at: at, savedAt: nil).showsSavedTasks)
        #expect(!RefreshState.offlineEmpty(since: at).showsSavedTasks)
        #expect(!RefreshState.live.showsSavedTasks)
        #expect(!RefreshState.loading.showsSavedTasks)
    }

    /// 저장본 찾기: 저장된 제목으로 거르고 구역 · 받은 순서는 그대로
    @Test func savedRowsFilterByTitle() {
        let saved = SavedNow(sections: ListFixture.sections, savedAt: savedAt)
        #expect(PhoneHome.savedRows(saved, in: .toDo, matching: "", now: savedAt).count == 14)
        // 말마다 모두 들어 있으면 (`TaskFilter`)
        #expect(PhoneHome.savedRows(saved, in: .toDo, matching: "일 3", now: savedAt).map(\.task.title) == [
            "할 일 23", "할 일 30", "할 일 31", "할 일 32", "할 일 33", "할 일 34",
        ])
        #expect(PhoneHome.savedRows(saved, in: .review, matching: "일 3", now: savedAt).map(\.task.title) == ["할 일 3"])
        // 상대 이름은 저장하지 않아서 찾지 못한다
        #expect(PhoneHome.savedRows(saved, in: .toDo, matching: "상대", now: savedAt).isEmpty)
        // 다음 날이면 Done Today는 없다
        #expect(PhoneHome.savedRows(saved, in: .doneToday, matching: "", now: savedAt.addingTimeInterval(86_400 * 2)).isEmpty)
    }

    @Test func failedSourcesTitle() {
        #expect(FailedSources(count: 1, latestAt: nil, reason: nil).title == "Couldn’t read 1 source")
        #expect(FailedSources(count: 3, latestAt: nil, reason: .aiTimeout).title == "Couldn’t read 3 sources")
    }
}
