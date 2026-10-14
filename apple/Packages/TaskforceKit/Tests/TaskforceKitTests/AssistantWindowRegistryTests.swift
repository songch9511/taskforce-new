import CoreGraphics
import Foundation
import Testing
@testable import TaskforceKit

/// Assistant 창 관리 규칙 (OA U1): 창 하나 = 대화 하나 · 최대 8개 · 같은 대화는 그 창을 앞으로 · 위치는 대화 id별 · 화면별
struct AssistantWindowRegistryTests {
    func conversation(_ n: Int) -> UUID { UUID(uuidString: String(format: "c0000000-0000-4000-8000-%012d", n))! }
    func window(_ n: Int) -> UUID { UUID(uuidString: String(format: "d0000000-0000-4000-8000-%012d", n))! }

    /// 창 id를 1부터 차례로 주는 레지스트리
    func opened(_ count: Int) -> AssistantWindowRegistry {
        var registry = AssistantWindowRegistry()
        for n in 1...max(count, 1) where count > 0 { _ = registry.open(conversation: conversation(n), windowID: window(n)) }
        return registry
    }

    // MARK: 열기 · 상한

    @Test func openingAConversationCreatesAWindowForIt() {
        var registry = AssistantWindowRegistry()
        #expect(registry.open(conversation: conversation(1), windowID: window(1)) == .opened(window(1)))
        #expect(registry.windowIDs == [window(1)] && registry.conversationID(of: window(1)) == conversation(1))
        #expect(registry.window(showing: conversation(1)) == window(1))
        #expect(registry.window(showing: conversation(2)) == nil)
    }

    @Test func openingTheSameConversationAgainBringsItsWindowForwardInsteadOfOpeningASecond() {
        var registry = opened(3)
        #expect(registry.open(conversation: conversation(1), windowID: window(9)) == .reused(window(1)))
        #expect(registry.windowIDs.count == 3, "같은 대화의 창은 하나")
        #expect(registry.frontmost == window(1), "다시 연 창이 가장 앞이다")
    }

    @Test func atMostEightWindowsAndAtTheCapTheLeastRecentlyUsedComesForward() {
        var registry = opened(8)
        #expect(registry.windowIDs.count == AssistantWindowRegistry.maxWindows && AssistantWindowRegistry.maxWindows == 8)
        // 가장 오래 쓰지 않은 창 = 1번 (열린 차례)
        #expect(registry.open(conversation: conversation(9), windowID: window(9)) == .atCapacity(raise: window(1)))
        #expect(registry.windowIDs.count == 8 && registry.window(showing: conversation(9)) == nil, "아홉째 창은 만들지 않는다")
        #expect(registry.frontmost == window(1), "그 창을 앞으로 가져온다 (쓴 것으로 친다)")
        // 이제 가장 오래 쓰지 않은 창은 2번
        #expect(registry.open(conversation: conversation(10), windowID: window(10)) == .atCapacity(raise: window(2)))
    }

    @Test func usingAWindowMovesItToTheFrontOfTheUseOrder() {
        var registry = opened(8)
        registry.touch(window(1))
        #expect(registry.leastRecentlyUsed == window(2))
        #expect(registry.frontmost == window(1))
        registry.touch(window(1))
        #expect(registry.frontmost == window(1) && registry.windowIDs.count == 8, "같은 창을 거듭 써도 겹치지 않는다")
    }

    @Test func closingAWindowFreesASlot() {
        var registry = opened(8)
        registry.close(window(3))
        #expect(registry.windowIDs.count == 7 && registry.window(showing: conversation(3)) == nil)
        #expect(registry.open(conversation: conversation(9), windowID: window(9)) == .opened(window(9)))
        registry.close(window(404))
        #expect(registry.windowIDs.count == 8, "없는 창을 닫아도 아무 일 없다")
    }

    @Test func hiddenWindowsStillCountTowardTheCap() {
        var registry = opened(8)
        for n in 1...8 { registry.setHidden(true, window(n)) }
        #expect(registry.open(conversation: conversation(9), windowID: window(9)) == .atCapacity(raise: window(1)))
        #expect(registry.isHidden(window(1)) == false, "앞으로 가져온 창은 다시 보인다")
    }

    // MARK: 앞 창 · 숨김

    @Test func frontmostIsTheMostRecentlyUsedVisibleWindow() {
        var registry = opened(3)
        #expect(registry.frontmost == window(3))
        registry.setHidden(true, window(3))
        #expect(registry.frontmost == window(2), "숨은 창은 앞 창이 아니다")
        for n in 1...3 { registry.setHidden(true, window(n)) }
        #expect(registry.frontmost == nil)
        #expect(registry.mostRecentlyUsed == window(3), "숨은 것 가운데 가장 최근 창: ⌘3이 다시 보인다")
        registry.setHidden(false, window(3))
        #expect(registry.frontmost == window(3))
    }

    @Test func showingTheChatsWindowPicksTheFrontmostOrElseTheLatestHidden() {
        var registry = opened(2)
        #expect(registry.windowToBringForward == window(2))
        registry.setHidden(true, window(2))
        #expect(registry.windowToBringForward == window(1))
        registry.setHidden(true, window(1))
        #expect(registry.windowToBringForward == window(2), "전부 숨었으면 가장 최근에 쓴 창")
        #expect(AssistantWindowRegistry().windowToBringForward == nil, "창이 없으면 새로 연다")
    }

    // MARK: 같은 창 안에서 대화 바꾸기

    @Test func switchingAWindowToAnotherConversationRebindsIt() {
        var registry = opened(2)
        #expect(registry.rebind(window(1), to: conversation(5)) == .rebound)
        #expect(registry.conversationID(of: window(1)) == conversation(5) && registry.window(showing: conversation(1)) == nil)
    }

    @Test func switchingToAConversationThatAnotherWindowShowsRaisesThatWindowInstead() {
        var registry = opened(2)
        #expect(registry.rebind(window(1), to: conversation(2)) == .showsElsewhere(window(2)))
        #expect(registry.conversationID(of: window(1)) == conversation(1), "이 창은 그대로")
        #expect(registry.frontmost == window(2))
        // 자기 자신의 대화로 바꾸기는 아무 일 없음
        #expect(registry.rebind(window(1), to: conversation(1)) == .rebound)
    }

    // MARK: 위치

    @Test func aWindowKeepsItsPositionPerConversationAndPerDisplay() {
        var positions = AssistantWindowPositions()
        let a = conversation(1), b = conversation(2)
        positions.remember(CGPoint(x: 100, y: 800), conversation: a, display: "1")
        positions.remember(CGPoint(x: 400, y: 700), conversation: a, display: "2")
        positions.remember(CGPoint(x: 150, y: 600), conversation: b, display: "1")
        #expect(positions.position(conversation: a, display: "1") == CGPoint(x: 100, y: 800))
        #expect(positions.position(conversation: a, display: "2") == CGPoint(x: 400, y: 700), "화면마다 따로")
        #expect(positions.position(conversation: b, display: "1") == CGPoint(x: 150, y: 600), "대화마다 따로")
        #expect(positions.position(conversation: b, display: "2") == nil)
        positions.remember(CGPoint(x: 111, y: 811), conversation: a, display: "1")
        #expect(positions.position(conversation: a, display: "1") == CGPoint(x: 111, y: 811), "나중 위치가 이긴다")
    }

    @Test func rememberedPositionsAreBoundedSoTheListNeverGrowsForever() {
        var positions = AssistantWindowPositions()
        for n in 1...(AssistantWindowPositions.capacity + 20) {
            positions.remember(CGPoint(x: Double(n), y: 1), conversation: conversation(n), display: "1")
        }
        #expect(positions.conversationCount == AssistantWindowPositions.capacity)
        #expect(positions.position(conversation: conversation(1), display: "1") == nil, "가장 오래된 기억부터 잊는다")
        #expect(positions.position(conversation: conversation(AssistantWindowPositions.capacity + 20), display: "1") != nil)
    }

    @Test func aStoreWithoutDefaultsKeepsPositionsInMemoryOnly() {
        let store = AssistantWindowPositionStore(defaults: nil)
        var positions = store.load()
        positions.remember(CGPoint(x: 5, y: 6), conversation: conversation(1), display: "1")
        store.save(positions)
        #expect(store.load().position(conversation: conversation(1), display: "1") == CGPoint(x: 5, y: 6))
        #expect(AssistantWindowPositionStore(defaults: nil).load().conversationCount == 0, "다른 저장소와 공유하지 않는다 (설정 도메인도 만들지 않는다)")
        store.clear()
        #expect(store.load().conversationCount == 0)
    }

    @Test func positionsSurviveRestartThroughAnIsolatedSuite() throws {
        // 고정 이름: 실행마다 새 설정 파일이 쌓이지 않게 한다 (시작 · 끝에 비운다)
        let name = "dev.taskforcelabs.unittest.u1.window-positions"
        let defaults = try #require(UserDefaults(suiteName: name))
        defaults.removePersistentDomain(forName: name)
        defer { defaults.removePersistentDomain(forName: name) }
        let store = AssistantWindowPositionStore(defaults: defaults)
        var positions = store.load()
        #expect(positions.conversationCount == 0)
        positions.remember(CGPoint(x: 12.5, y: 640), conversation: conversation(1), display: "69733248")
        store.save(positions)
        let again = AssistantWindowPositionStore(defaults: defaults).load()
        #expect(again.position(conversation: conversation(1), display: "69733248") == CGPoint(x: 12.5, y: 640))
        // 읽을 수 없는 저장본은 비어 있는 것으로 읽는다 (창이 안 열리지 않는다)
        defaults.set(Data("not json".utf8), forKey: AssistantWindowPositionStore.key)
        #expect(AssistantWindowPositionStore(defaults: defaults).load().conversationCount == 0)
        // 계정이 떠나면 위치도 지운다 (대화 id는 계정의 것이다)
        store.save(positions)
        store.clear()
        #expect(AssistantWindowPositionStore(defaults: defaults).load().conversationCount == 0)
    }
}
