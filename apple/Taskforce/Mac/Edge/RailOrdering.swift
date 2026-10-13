#if os(macOS)
import Foundation
import TaskforceUI

/// 레일에 오를 수 있는 일 하나: 지금 무엇을 하는지(`ActivityRing.Kind`)가 있는 일만 (디자인 EdgeRail "live work you can jump to")
struct RailEntry: Identifiable, Equatable {
    let id: UUID
    let title: String
    let kind: ActivityRing.Kind
    /// 업무 상태 (○ ◉ ✓ · Review)
    let state: TaskStatusMark.State
    /// 활동 글. 없으면 링의 말
    let activity: String

    init(id: UUID, title: String, kind: ActivityRing.Kind, state: TaskStatusMark.State, activity: String? = nil) {
        self.id = id
        self.title = title
        self.kind = kind
        self.state = state
        self.activity = activity ?? kind.accessibilityLabel
    }

    var accessibilityLabel: String {
        RailItem.accessibilityLabel(title: title, state: state, activity: activity)
    }
}

/// 레일의 칸 순서 (디자인 EdgeRail · README "Rail shortcuts"):
/// - 펼친 레일은 일을 넷까지: needs you → running(stop requested · connection lost 포함) → done just now → 나머지
/// - 숨은 레일(노치)은 앞의 셋까지, 그것도 needs you · running · done 종류만
/// - 목록에 남아 있는 일은 서로의 순서를 바꾸지 않는다: 종류가 바뀌어도(running → connection lost) 제자리
/// - 새 일은 자기 우선순위 자리에 끼운다(같은 우선순위면 먼저 온 일 뒤). 넷을 넘으면 끝에서 빠진다
enum RailOrdering {
    static let capacity = 4
    static let notchCapacity = 3

    /// 작을수록 앞
    static func priority(_ kind: ActivityRing.Kind) -> Int {
        switch kind {
        case .needsYou: 0
        case .running, .stopping, .unreachable: 1
        case .done: 2
        case .waiting: 3
        }
    }

    /// 노치에 보일 수 있는 종류 (needs you · running 류 · done)
    static func isLead(_ kind: ActivityRing.Kind) -> Bool { priority(kind) <= 2 }

    /// - previous: 지난번 칸의 id 순서
    /// - entries: 지금 레일에 오를 수 있는 일 (순서는 들어온 차례)
    static func slots(previous: [UUID], entries: [RailEntry]) -> [RailEntry] {
        let byID = Dictionary(entries.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var list = previous.compactMap { byID[$0] }
        let kept = Set(list.map(\.id))
        var seen = kept
        let newcomers = entries
            .filter { seen.insert($0.id).inserted }
            .enumerated()
            .sorted { ($0.element.kind.railPriority, $0.offset) < ($1.element.kind.railPriority, $1.offset) }
            .map(\.element)
        for entry in newcomers {
            let rank = priority(entry.kind)
            let index = list.lastIndex { priority($0.kind) <= rank }.map { $0 + 1 } ?? 0
            list.insert(entry, at: index)
        }
        return Array(list.prefix(capacity))
    }

    /// 숨은 레일의 노치: 칸의 앞에서부터 needs you · running · done 종류만, 셋까지
    static func notch(_ slots: [RailEntry]) -> [RailEntry] {
        Array(slots.prefix { isLead($0.kind) }.prefix(notchCapacity))
    }

    /// 레일 전체의 접근성 이름. 개수는 화면이 아니라 여기에만 쓴다 (README "No numbers to read at a glance")
    static func accessibilityLabel(_ entries: [RailEntry]) -> String {
        func count(_ kinds: Set<ActivityRing.Kind>) -> Int { entries.filter { kinds.contains($0.kind) }.count }
        let running = count([.running])
        let needs = count([.needsYou])
        let lost = count([.unreachable])
        let stopping = count([.stopping])
        var parts = ["\(running) running"]
        if needs > 0 { parts.append("\(needs) need\(needs == 1 ? "s" : "") you") }
        if lost > 0 { parts.append("\(lost) unreachable") }
        if stopping > 0 { parts.append("\(stopping) stopping") }
        return "Taskforce — " + parts.joined(separator: ", ")
    }
}

private extension ActivityRing.Kind {
    var railPriority: Int { RailOrdering.priority(self) }
}
#endif
