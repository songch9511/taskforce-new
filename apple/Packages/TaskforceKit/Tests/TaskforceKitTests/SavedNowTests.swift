import Foundation
import Testing
@testable import TaskforceKit

/// 저장본: 계정마다 제목 · 기한 · 상태만 (사용자 결정 2026-10-03), 계정 격리, 로그아웃 · 계정 삭제 때 지움
struct SavedNowTests {
    let root: URL
    let store: SavedNowStore
    let alice = UUID(uuidString: "aaaaaaaa-0000-4000-8000-000000000001")!
    let bob = UUID(uuidString: "bbbbbbbb-0000-4000-8000-000000000002")!
    let savedAt = Date(timeIntervalSince1970: 1_791_000_000)

    init() {
        root = FileManager.default.temporaryDirectory.appending(path: "SavedNowTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        store = SavedNowStore(root: root)
    }

    var sections: TaskSections {
        let due = LocalDate(year: 2026, month: 10, day: 2)!
        let review = ListFixture.action(1, review: true, due: due)
        let doing = ListFixture.action(11, started: true)
        let todo = ListFixture.action(21, due: due)
        let done = ListFixture.action(41, status: .done)
        return TaskSections(
            review: [review],
            inProgress: [RankedAction(action: doing, score: 1, reasons: [], daysUntilDue: nil, changed: true)],
            toDo: [RankedAction(action: todo, score: 1, reasons: [.dueSoon], daysUntilDue: 1)],
            doneToday: [done]
        )
    }

    @Test func roundTripsTitleDueAndStatusInOrder() throws {
        defer { try? store.removeAll() }
        try store.save(SavedNow(sections: sections, savedAt: savedAt), account: alice)
        let saved = try #require(store.load(account: alice))
        #expect(saved.savedAt == savedAt)
        #expect(saved.tasks == [
            .init(title: "할 일 1", dueDate: LocalDate(year: 2026, month: 10, day: 2), status: .review),
            .init(title: "할 일 11", dueDate: nil, status: .inProgress),
            .init(title: "할 일 21", dueDate: LocalDate(year: 2026, month: 10, day: 2), status: .toDo),
            .init(title: "할 일 41", dueDate: nil, status: .doneToday),
        ])
        #expect(saved.rows(in: .toDo, now: savedAt).map(\.task.title) == ["할 일 21"])
        // 행 id는 저장본 안의 자리 (구역이 달라도 겹치지 않는다)
        #expect(TaskGroup.allCases.flatMap { saved.rows(in: $0, now: savedAt).map(\.id) } == [0, 1, 2, 3])
    }

    /// 파일에는 제목 · 기한 · 상태 · 저장 시각 · 판만 있다 (원문 · 상대 · 확인 이유 · id · 점수 없음)
    @Test func fileHoldsOnlyTheAllowedFields() throws {
        defer { try? store.removeAll() }
        try store.save(SavedNow(sections: sections, savedAt: savedAt), account: alice)
        let data = try Data(contentsOf: store.file(for: alice))
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(object.keys) == ["version", "saved_at", "tasks"])
        let tasks = try #require(object["tasks"] as? [[String: Any]])
        for task in tasks {
            #expect(Set(task.keys).isSubset(of: ["title", "due_date", "status"]))
        }
        let text = String(decoding: data, as: UTF8.self)
        #expect(!text.contains("상대"))
        #expect(!text.contains("담당 확인"))
        #expect(!text.contains(ListFixture.id(1).uuidString.lowercased()))
        #expect(!text.contains(ListFixture.id(1).uuidString))
    }

    @Test func accountsAreIsolated() throws {
        defer { try? store.removeAll() }
        try store.save(SavedNow(sections: sections, savedAt: savedAt), account: alice)
        #expect(store.load(account: bob) == nil)
        try store.save(SavedNow(savedAt: savedAt, tasks: []), account: bob)
        #expect(store.load(account: alice)?.tasks.count == 4)
        #expect(store.load(account: bob)?.tasks.isEmpty == true)
    }

    /// 계정 삭제: 그 계정만 지운다
    @Test func removingOneAccount() throws {
        defer { try? store.removeAll() }
        try store.save(SavedNow(sections: sections, savedAt: savedAt), account: alice)
        try store.save(SavedNow(sections: sections, savedAt: savedAt), account: bob)
        try store.remove(account: alice)
        #expect(store.load(account: alice) == nil)
        #expect(store.load(account: bob) != nil)
        #expect(!FileManager.default.fileExists(atPath: store.folder(for: alice).path))
    }

    /// 로그아웃 · 계정 전환: 모든 계정의 저장본을 지운다
    @Test func removingAll() throws {
        try store.save(SavedNow(sections: sections, savedAt: savedAt), account: alice)
        try store.save(SavedNow(sections: sections, savedAt: savedAt), account: bob)
        try store.removeAll()
        #expect(store.load(account: alice) == nil)
        #expect(store.load(account: bob) == nil)
        #expect(!FileManager.default.fileExists(atPath: root.path))
        // 지운 뒤에도 다시 저장할 수 있다
        try store.save(SavedNow(savedAt: savedAt, tasks: []), account: alice)
        #expect(store.load(account: alice) != nil)
        try store.removeAll()
    }

    @Test func savingReplacesThePreviousCopy() throws {
        defer { try? store.removeAll() }
        try store.save(SavedNow(sections: sections, savedAt: savedAt), account: alice)
        try store.save(SavedNow(savedAt: savedAt.addingTimeInterval(60), tasks: []), account: alice)
        let saved = try #require(store.load(account: alice))
        #expect(saved.tasks.isEmpty)
        #expect(saved.savedAt == savedAt.addingTimeInterval(60))
    }

    @Test(arguments: [#"{"version": 2, "saved_at": "2026-10-03T00:00:00Z", "tasks": []}"#, "not json", #"{"tasks": []}"#])
    func unreadableCopyIsDropped(_ contents: String) throws {
        defer { try? store.removeAll() }
        try FileManager.default.createDirectory(at: store.folder(for: alice), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: store.file(for: alice))
        #expect(store.load(account: alice) == nil)
        #expect(!FileManager.default.fileExists(atPath: store.file(for: alice).path))
    }

    @Test func folderIsExcludedFromBackup() throws {
        defer { try? store.removeAll() }
        try store.save(SavedNow(savedAt: savedAt, tasks: []), account: alice)
        let values = try root.resourceValues(forKeys: [.isExcludedFromBackupKey])
        #expect(values.isExcludedFromBackup == true)
    }

    /// 어제 저장한 Done Today는 "Done Today"로 보이지 않는다 (기기 시간대의 오늘)
    @Test func doneTodayOnlyOnTheSameDay() {
        let seoul = TimeZone(identifier: "Asia/Seoul")!
        // 2026-10-03 09:00 KST
        let midnightUTC = 1_791_000_000 - 1_791_000_000 % 86_400
        let saved = SavedNow(sections: sections, savedAt: Date(timeIntervalSince1970: TimeInterval(midnightUTC)))
        let sameDay = saved.savedAt.addingTimeInterval(3600)
        let nextDay = saved.savedAt.addingTimeInterval(86_400)
        #expect(saved.rows(in: .doneToday, now: sameDay, timeZone: seoul).map(\.task.title) == ["할 일 41"])
        #expect(saved.rows(in: .doneToday, now: nextDay, timeZone: seoul).isEmpty)
        #expect(saved.rows(in: .review, now: nextDay, timeZone: seoul).count == 1)
    }

    /// 지울 것이 없어도 성공이다 (로그아웃마다 부른다)
    @Test func removingWhatIsNotThereSucceeds() throws {
        try store.removeAll()
        try store.remove(account: alice)
    }

    /// 오프라인 목록도 같은 범위 · 개수 규칙을 쓴다 (M15 · P10 "Search 23 saved tasks")
    @Test func scopesWorkOnTheSavedCopy() {
        let saved = SavedNow(sections: ListFixture.sections, savedAt: savedAt)
        #expect(TaskScope.allTasks.count(in: saved, now: savedAt) == 23)
        #expect(TaskScope.review.count(in: saved, now: savedAt) == 4)
        #expect(TaskScope.toDo.count(in: saved, now: savedAt) == 14)
        #expect(TaskScope.doneToday.count(in: saved, now: savedAt) == 6)
        #expect(TaskScope.changed.count(in: saved, now: savedAt) == 0)
        #expect(TaskScope.review.rows(in: saved, group: .toDo, now: savedAt).isEmpty)
        #expect(TaskScope.allTasks.rows(in: saved, group: .toDo, now: savedAt).count == 14)
        // 다음 날이면 Done Today는 세지 않는다
        #expect(TaskScope.doneToday.count(in: saved, now: savedAt.addingTimeInterval(86_400 * 2)) == 0)
    }

    @Test func statusNamesAreStable() {
        #expect(SavedNow.Status.allCases.map(\.rawValue) == ["review", "in_progress", "to_do", "done_today"])
        for group in TaskGroup.allCases {
            #expect(SavedNow.Status(group).group == group)
        }
    }
}
