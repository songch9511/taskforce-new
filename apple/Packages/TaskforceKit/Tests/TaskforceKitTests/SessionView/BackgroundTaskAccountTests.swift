#if os(macOS)
import Foundation
import Testing
@testable import TaskforceKit

/// 보안 P3-1: 열어 본 시각(이 Mac의 저장본)과 이 Mac의 일 목록 판은 **계정과 함께** 간다. 다른 계정(또는 주인을 모르는 저장본)이 보면 비우고, 알던 계정이 떠나면(로그아웃 · 다른 계정) 판을 비운다.
/// 끝남 표시(`RailDoneStore`)와 같은 규칙이다: 주인이 이 계정이 아니면 이 계정의 표시가 아니다
struct BackgroundTaskAccountTests {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private let alice = UUID(uuidString: "00000000-0000-4000-8000-0000000000a1") ?? UUID()
    private let bob = UUID(uuidString: "00000000-0000-4000-8000-0000000000b2") ?? UUID()

    private func started(_ id: String) -> BackgroundTaskEvent { .started(taskID: id, toolUseID: nil, kind: .command, name: nil, at: t0) }

    // MARK: 저장본의 주인

    @Test func bothStoresRememberTheOwnerAndTheDefaultsStoreSurvivesANewInstance() {
        let memory = InMemoryBackgroundTaskOpenStore()
        #expect(memory.owner == nil)
        memory.setOwner(alice)
        #expect(memory.owner == alice)
        memory.setOwner(nil)
        #expect(memory.owner == nil)

        let defaults = FakeRailDefaults()
        let first = UserDefaultsBackgroundTaskOpenStore(defaults: defaults)
        #expect(first.owner == nil)
        first.setOwner(bob)
        first.markOpened(session: "s", at: t0)
        let second = UserDefaultsBackgroundTaskOpenStore(defaults: defaults)
        #expect(second.owner == bob && second.openedAt(session: "s") == t0, "다시 켠 뒤에도 그대로")
    }

    @Test func clearingDropsTheOpenTimesAndLeavesTheOwnerForTheCallerToDecide() {
        let store = UserDefaultsBackgroundTaskOpenStore(defaults: FakeRailDefaults())
        store.setOwner(alice)
        store.markOpened(session: "s", at: t0)
        store.clear()
        #expect(store.openedAt(session: "s") == nil && store.owner == alice)
    }

    @Test func aBrokenSavedOwnerIsNoOwner() {
        let defaults = FakeRailDefaults()
        defaults.set("not-a-uuid", forKey: UserDefaultsBackgroundTaskOpenStore.ownerKey)
        #expect(UserDefaultsBackgroundTaskOpenStore(defaults: defaults).owner == nil)
        defaults.set(Data([1, 2, 3]), forKey: UserDefaultsBackgroundTaskOpenStore.ownerKey)
        #expect(UserDefaultsBackgroundTaskOpenStore(defaults: defaults).owner == nil)
    }

    // MARK: 계정이 오고 간다

    @Test func aDifferentOrUnknownOwnerOfTheSavedOpenTimesIsPrunedWhenAnAccountIsAdopted() {
        for savedOwner in [nil, bob] {
            let store = InMemoryBackgroundTaskOpenStore()
            store.setOwner(savedOwner)
            store.markOpened(session: "s", at: t0)
            let account = BackgroundTaskAccount(openStore: store, board: BackgroundTaskBoard())
            account.adopt(account: alice)
            #expect(store.openedAt(session: "s") == nil, "주인이 \(savedOwner == nil ? "없는" : "다른") 저장본은 이 계정의 것이 아니다")
            #expect(store.owner == alice)
        }
    }

    @Test func theSameOwnerKeepsTheOpenTimesWhenAdoptedAgain() {
        let store = InMemoryBackgroundTaskOpenStore()
        store.setOwner(alice)
        store.markOpened(session: "s", at: t0)
        let account = BackgroundTaskAccount(openStore: store, board: BackgroundTaskBoard())
        account.adopt(account: alice)
        account.adopt(account: alice)
        #expect(store.openedAt(session: "s") == t0 && store.owner == alice)
    }

    @Test func anAccountThatLeavesTakesTheBoardWithIt() {
        let board = BackgroundTaskBoard()
        board.apply(started("a"), session: "s1")
        board.apply(started("b"), session: "s2")
        let account = BackgroundTaskAccount(openStore: InMemoryBackgroundTaskOpenStore(), board: board)
        account.leave()
        #expect(board.sessionCount == 0 && board.tasks(session: "s1").tasks.isEmpty)
    }

    @Test func switchingAccountsLeavesNothingOfTheFirstForTheSecond() {
        let store = InMemoryBackgroundTaskOpenStore()
        let board = BackgroundTaskBoard()
        let account = BackgroundTaskAccount(openStore: store, board: board)
        account.adopt(account: alice)
        store.markOpened(session: "s", at: t0)
        board.apply(started("a"), session: "s")
        account.leave()
        account.adopt(account: bob)
        #expect(store.openedAt(session: "s") == nil && board.tasks(session: "s").tasks.isEmpty && store.owner == bob)
    }
}
#endif
