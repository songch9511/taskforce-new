import Testing
@testable import TaskforceKit

struct AppOpenTrackerTests {
    /// 상태를 차례로 넣고 보낸 횟수를 센다
    func opens(_ phases: [AppOpenTracker.Phase]) -> Int {
        var tracker = AppOpenTracker()
        return phases.filter { tracker.update($0) }.count
    }

    @Test func firstAppearanceWhileActiveCounts() {
        #expect(opens([.active]) == 1)
    }

    @Test func appearingInactiveCountsOnceItBecomesActive() {
        #expect(opens([.inactive, .active]) == 1)
    }

    @Test func briefInactiveDoesNotCount() {
        // 제어 센터 · 알림 · Face ID
        #expect(opens([.active, .inactive, .active, .inactive, .active]) == 1)
    }

    @Test func returningFromBackgroundCounts() {
        #expect(opens([.active, .inactive, .background, .inactive, .active]) == 2)
        #expect(opens([.active, .background, .active, .background, .active]) == 3)
    }

    @Test func backgroundAloneDoesNotCount() {
        #expect(opens([.background, .inactive]) == 0)
        #expect(opens([.background, .active]) == 1)
    }

    @Test func repeatedActiveCountsOnce() {
        #expect(opens([.active, .active]) == 1)
    }
}
