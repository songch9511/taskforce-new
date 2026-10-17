import Foundation

// OA U3: 레일 첫 캡슐의 Taskforce bell 규칙 (DS EdgeRail "The Taskforce bell"). 화면 없는 순수 함수.
// - 보임: 보이는 요청이 있거나 Taskforce 대화가 열려 있을 때만. 아니면 없다 (⌘1은 그래도 대화를 연다).
// - 울림: 보이는 요청이 있을 때만. 바뀐 것(복귀 요약)은 bell을 울리지 않는다. 대화가 열려 있고 요청이 없으면 조용히 보인다.
// - 늘 흰색이다: 색이 아니라 움직임이 부른다 (움직임은 `TaskforceUI.RailBell`).
// - 개수는 화면에 없다: 접근성 이름에만 쓴다 (", {n} items").

public struct TaskforceBell: Equatable, Sendable {
    /// 요청이 기다린다: 도착 bounce 뒤 2.4초마다 숨쉬고 흔들린다
    public let rings: Bool
    /// 대화가 열려 있다: 칸이 `bezel-hover`로 칠해진다
    public let selected: Bool
    /// 보이는 요청의 수 (접근성 이름에만)
    public let count: Int

    public init(rings: Bool, selected: Bool, count: Int) {
        self.rings = rings
        self.selected = selected
        self.count = count
    }

    /// 툴팁: "Taskforce · Needs your answer" / "Taskforce · Nothing waiting"
    public var tooltip: String { TaskforceCopy.bellTooltip(rings: rings) }

    /// 접근성 이름: 툴팁 + (요청이 있을 때) 개수. 개수는 읽어 주는 데만 쓴다
    public var accessibilityName: String {
        rings ? "\(tooltip), \(count) \(count == 1 ? "item" : "items")" : tooltip
    }
}

public enum TaskforceBellRules {
    /// bell (없으면 nil). `enabled`는 Taskforce 대화가 이 구성에 있는가 (게이트)
    public static func bell(requestCount: Int, conversationOpen: Bool, enabled: Bool) -> TaskforceBell? {
        guard enabled, requestCount > 0 || conversationOpen else { return nil }
        return TaskforceBell(rings: requestCount > 0, selected: conversationOpen, count: requestCount)
    }
}
