#if os(macOS)
import Foundation
import Testing
@testable import TaskforceKit

/// 어댑터가 모은 일 목록을 이 Mac 안에서 패널에 건네는 판 (세션마다 하나, 메모리만, 서버 · 로그 0)
struct BackgroundTaskBoardTests {
    private let at = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func eventsFillTheListOfTheSessionTheyBelongTo() {
        let board = BackgroundTaskBoard()
        board.apply(.started(taskID: "a", toolUseID: nil, kind: .command, name: "Run", at: at), session: "S1")
        board.apply(.started(taskID: "b", toolUseID: nil, kind: .agent, name: "Audit", at: at), session: "s2")
        board.apply(.finished(taskID: "a", kind: nil, status: .done, exitCode: 0, at: at.addingTimeInterval(9)), session: "s1")
        #expect(board.tasks(session: "s1").tasks.map(\.status) == [.done], "세션 id는 대소문자를 가리지 않는다")
        #expect(board.tasks(session: "S2").tasks.map(\.id) == ["b"])
        #expect(board.tasks(session: "none").tasks.isEmpty)
    }

    @Test func theVersionRisesOnlyWhenTheListChanges() {
        let board = BackgroundTaskBoard()
        let start = board.version
        let event = BackgroundTaskEvent.started(taskID: "a", toolUseID: nil, kind: .command, name: nil, at: at)
        board.apply(event, session: "s1")
        #expect(board.version == start + 1)
        board.apply(event, session: "s1")
        #expect(board.version == start + 1, "같은 사건은 바꾸지 않는다")
        board.clear(session: "s1")
        #expect(board.version == start + 2 && board.tasks(session: "s1").tasks.isEmpty)
        board.clear(session: "s1")
        #expect(board.version == start + 2)
    }

    @Test func theBoardKeepsOnlyTheNewestSessionsAndRejectsHostileKeys() {
        let board = BackgroundTaskBoard()
        for n in 0..<(BackgroundTaskBoard.maxSessions + 10) { board.apply(.started(taskID: "t", toolUseID: nil, kind: .command, name: nil, at: at), session: "session-\(n)") }
        #expect(board.sessionCount <= BackgroundTaskBoard.maxSessions)
        #expect(board.tasks(session: "session-0").tasks.isEmpty, "가장 오래 안 쓴 세션부터 버린다")
        #expect(!board.tasks(session: "session-\(BackgroundTaskBoard.maxSessions + 9)").tasks.isEmpty)
        board.apply(.started(taskID: "t", toolUseID: nil, kind: .command, name: nil, at: at), session: String(repeating: "x", count: 500))
        #expect(board.tasks(session: String(repeating: "x", count: 500)).tasks.isEmpty, "너무 긴 키는 받지 않는다")
    }

    @Test func aSessionThatWasJustUpdatedIsNotTheOneThatIsDropped() {
        let board = BackgroundTaskBoard()
        let start = BackgroundTaskEvent.started(taskID: "t", toolUseID: nil, kind: .command, name: nil, at: at)
        for n in 0..<BackgroundTaskBoard.maxSessions { board.apply(start, session: "session-\(n)") }
        // 가장 오래된 세션이 새 소식을 받는다: 이제 가장 오래 안 쓴 것은 그다음 세션이다
        board.apply(.finished(taskID: "t", kind: nil, status: .done, exitCode: 0, at: at.addingTimeInterval(5)), session: "session-0")
        board.apply(start, session: "session-new")
        #expect(board.sessionCount == BackgroundTaskBoard.maxSessions)
        #expect(!board.tasks(session: "session-0").tasks.isEmpty, "방금 쓴 세션은 남는다")
        #expect(board.tasks(session: "session-1").tasks.isEmpty, "가장 오래 안 쓴 세션이 빠진다")
    }

    /// 리뷰 P1: 프로세스가 끝났는데 도는 줄 알았던 일은 끝난 것이다 (스냅샷 `[]` = 도는 일 없음). 끝 시각은 그때다
    @Test func aSnapshotOfNothingStopsEveryRunningTaskOfTheSessionAtTheGivenTime() {
        let board = BackgroundTaskBoard()
        board.apply(.started(taskID: "a", toolUseID: nil, kind: .command, name: nil, at: at), session: "s1")
        board.apply(.started(taskID: "b", toolUseID: nil, kind: .agent, name: nil, at: at), session: "s1")
        board.apply(.finished(taskID: "b", kind: .agent, status: .done, exitCode: nil, at: at.addingTimeInterval(3)), session: "s1")
        board.apply(.started(taskID: "c", toolUseID: nil, kind: .command, name: nil, at: at), session: "s2")
        let version = board.version
        board.apply(.snapshot(runningTaskIDs: []), session: "s1", now: at.addingTimeInterval(30))
        let list = board.tasks(session: "s1").tasks
        #expect(list.first { $0.id == "a" }?.status == .stopped && list.first { $0.id == "a" }?.endedAt == at.addingTimeInterval(30))
        #expect(list.first { $0.id == "b" }?.status == .done, "끝난 일은 그대로")
        #expect(board.tasks(session: "s2").tasks.first?.status == .running, "다른 세션은 건드리지 않는다")
        #expect(board.version == version + 1)
        board.apply(.snapshot(runningTaskIDs: []), session: "s1", now: at.addingTimeInterval(60))
        #expect(board.version == version + 1, "바뀐 것이 없으면 판이 바뀐 것이 아니다")
    }

    /// 재검토: 거둬지는 spawn이 시작한 일만 멈춘다 (다른 일 · 이미 끝난 일 · 없는 일 · 다른 세션은 그대로, 없는 id로 일을 지어내지 않는다)
    @Test func stoppingNamedTasksTouchesOnlyThoseThatAreStillRunningInThatSession() {
        let board = BackgroundTaskBoard()
        board.apply(.started(taskID: "mine", toolUseID: nil, kind: .command, name: nil, at: at), session: "s1")
        board.apply(.started(taskID: "mine-done", toolUseID: nil, kind: .command, name: nil, at: at), session: "s1")
        board.apply(.finished(taskID: "mine-done", kind: .command, status: .done, exitCode: 0, at: at.addingTimeInterval(3)), session: "s1")
        board.apply(.started(taskID: "other", toolUseID: nil, kind: .command, name: nil, at: at), session: "s1")
        board.apply(.started(taskID: "mine", toolUseID: nil, kind: .command, name: nil, at: at), session: "s2")
        let version = board.version
        board.stopRunning(ids: ["mine", "mine-done", "never-seen"], session: "s1", now: at.addingTimeInterval(30))
        let list = board.tasks(session: "s1").tasks
        #expect(list.first { $0.id == "mine" }?.status == .stopped && list.first { $0.id == "mine" }?.endedAt == at.addingTimeInterval(30))
        #expect(list.first { $0.id == "mine-done" }?.status == .done, "끝난 일은 그대로")
        #expect(list.first { $0.id == "other" }?.status == .running, "이름을 부르지 않은 일은 그대로")
        #expect(!list.contains { $0.id == "never-seen" }, "없는 id로 일을 만들지 않는다")
        #expect(board.tasks(session: "s2").tasks.first?.status == .running, "다른 세션은 건드리지 않는다")
        #expect(board.version == version + 1)
        board.stopRunning(ids: ["mine"], session: "s1", now: at.addingTimeInterval(60))
        #expect(board.version == version + 1, "바뀐 것이 없으면 판이 바뀐 것이 아니다")
        board.stopRunning(ids: ["mine"], session: "unknown-session", now: at)
        #expect(board.sessionCount == 2, "모르는 세션에 칸을 만들지 않는다")
    }

    @Test func clearAllDropsEveryTasksListAndTheVersionRisesOnlyWhenSomethingWasThere() {
        let board = BackgroundTaskBoard()
        board.clearAll()
        let empty = board.version
        board.apply(.started(taskID: "a", toolUseID: nil, kind: .command, name: nil, at: at), session: "s1")
        board.apply(.started(taskID: "b", toolUseID: nil, kind: .command, name: nil, at: at), session: "s2")
        let before = board.version
        board.clearAll()
        #expect(board.sessionCount == 0 && board.tasks(session: "s1").tasks.isEmpty && board.tasks(session: "s2").tasks.isEmpty)
        #expect(board.version == before + 1)
        board.clearAll()
        #expect(board.version == before + 1)
        #expect(empty < before)
    }

    @Test func manyWritersAtOnceDoNotCorruptTheList() async {
        let board = BackgroundTaskBoard()
        await withTaskGroup(of: Void.self) { group in
            for n in 0..<200 {
                group.addTask { board.apply(.started(taskID: "t\(n)", toolUseID: nil, kind: .command, name: nil, at: Date(timeIntervalSince1970: 1_800_000_000)), session: "s") }
            }
        }
        #expect(board.tasks(session: "s").tasks.count == 200)
    }

    @Test func theBoardNeverPrintsNamesOrIds() {
        let board = BackgroundTaskBoard()
        board.apply(.started(taskID: "secret-task", toolUseID: nil, kind: .command, name: "A private name", at: at), session: "secret-session")
        let text = String(describing: board) + String(reflecting: board)
        #expect(!text.contains("secret-task") && !text.contains("A private name") && !text.contains("secret-session"))
    }

    @Test func aListMergedWithAnotherKeepsTheKnownNamesAndTheFinalStates() {
        var stream = BackgroundTaskList()
        stream.apply(.started(taskID: "a", toolUseID: nil, kind: .command, name: nil, at: at))
        stream.apply(.started(taskID: "b", toolUseID: nil, kind: .agent, name: "Audit", at: at.addingTimeInterval(1)))
        var transcript = BackgroundTaskList()
        transcript.apply(.started(taskID: "a", toolUseID: "tu1", kind: .command, name: "Run the dev server", at: at))
        transcript.apply(.finished(taskID: "a", kind: .command, status: .failed, exitCode: 3, at: at.addingTimeInterval(30)))
        transcript.apply(.started(taskID: "c", toolUseID: nil, kind: .command, name: nil, at: at.addingTimeInterval(2)))
        let merged = stream.merged(with: transcript)
        #expect(merged.tasks.map(\.id).sorted() == ["a", "b", "c"])
        let a = merged.tasks.first { $0.id == "a" }
        #expect(a?.name == "Run the dev server" && a?.status == .failed && a?.exitCode == 3 && a?.toolUseID == "tu1")
        #expect(merged.tasks.first { $0.id == "b" }?.name == "Audit")
        #expect(stream.tasks.count == 2 && transcript.tasks.count == 2, "원본은 그대로다")
        #expect(merged.merged(with: transcript) == merged, "두 번 합쳐도 같다")
    }
}
#endif
