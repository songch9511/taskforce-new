#if os(macOS)
import Foundation

// 하위 에이전트 트리 (에이전트 트리 T1): 일 목록(`BackgroundTaskList`)을 부모 · 자식 줄로 펼치는 순수 규칙. 옆줄(Taskforce 패널 · Claude 패널)이 쓰고, 프로젝트 화면(T3m)이 그대로 다시 쓴다.
// **선은 provider가 준 부모 id로만 긋는다.** 이름 · 시각 · 폴더로 부모를 짐작하지 않는다. 부모를 모르거나 믿을 수 없는 일(부모 칸 없음 · 자기 참조 · 순환 · 이 목록에 없는 부모)은
// 세션 바로 아래(level 0)에 다른 표시 없이 둔다: 선을 그리지 않는 것이 곧 "모름"이다.

/// 접힘 · 펼침의 선택 (세션마다 하나, 이 Mac의 메모리에만). 기본은 2단계까지 펴 둔다: 세션 바로 아래(level 0)와 그 자식(level 1)이 보이고, 더 깊은 분기는 접혀 있다.
/// 사용자가 누른 줄만 기본과 다르게 기억한다 (갱신이 와도 그대로). 일이 목록에서 사라지면 `prune`이 잊는다
public struct SubagentTreeExpansion: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    /// 기본으로 보이는 단계 수 (세션 바로 아래 + 그 자식)
    public static let defaultVisibleLevels = 2

    private let visibleLevels: Int
    private var overrides: [String: Bool] = [:]

    public init(visibleLevels: Int = SubagentTreeExpansion.defaultVisibleLevels) {
        self.visibleLevels = visibleLevels
    }

    /// 고른 줄의 수
    public var count: Int { overrides.count }

    /// 이 줄이 펴져 있나 (자식이 없는 줄에는 뜻이 없다). 고른 적이 없으면 기본: 아래 단계가 아직 보이는 단계 안이면 편다
    public func isExpanded(id: String, level: Int) -> Bool {
        overrides[id] ?? (level + 1 < visibleLevels)
    }

    public mutating func toggle(id: String, level: Int) {
        let next = !isExpanded(id: id, level: level)
        overrides[id] = next == (level + 1 < visibleLevels) ? nil : next
    }

    /// 목록에 남은 일의 선택만 둔다
    public mutating func prune(keeping ids: Set<String>) {
        overrides = overrides.filter { ids.contains($0.key) }
    }

    public var description: String { "SubagentTreeExpansion()" }
    public var debugDescription: String { description }
}

/// 보이는 줄 하나. `level` 0 = 세션 바로 아래
public struct SubagentTreeRow: Identifiable, Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public var id: String { task.id }
    public let task: BackgroundTask
    public let level: Int
    /// 자식이 있다 (눌러 펴고 접는 줄)
    public let hasChildren: Bool
    /// 자식이 있고 펴져 있다
    public let isExpanded: Bool
    /// 접힌 분기의 끝에 쓰는 글: 그 아래 모든 단계의 도는 일 · 실패 수를 숫자와 기존 낱말만으로 ("Running 2 · Failed 1"). 0은 쓰지 않고 둘 다 0이면 nil. 접히지 않았거나 자식이 없으면 nil
    public let branchSummary: String?

    public var description: String { "SubagentTreeRow()" }
    public var debugDescription: String { description }
}

public enum SubagentTree {
    /// 보이는 줄들 (위에서 아래로). 형제 안에서만 `BackgroundTaskList.ordered`의 순서(도는 중 → 실패 → 그 밖, 새것 먼저)를 따르고, 자식은 부모 바로 아래에 온다.
    /// 접힌 분기의 자손은 나오지 않는다
    public static func rows(for list: BackgroundTaskList, expansion: SubagentTreeExpansion) -> [SubagentTreeRow] {
        let ordered = list.ordered
        let known = Dictionary(ordered.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        // 선: 이 목록에 있는 부모이고, 자기 자신이 아니고, 순환에 속하지 않을 때만. (순환의 일원은 모두 세션 바로 아래다: 어느 쪽이 위인지 provider도 말하지 않았다)
        func isOnCycle(_ id: String) -> Bool {
            var seen: Set<String> = []
            var cursor = known[id]?.parentID
            while let current = cursor, let task = known[current], seen.insert(current).inserted {
                if current == id { return true }
                cursor = task.parentID
            }
            return false
        }

        var children: [String: [BackgroundTask]] = [:]
        var roots: [BackgroundTask] = []
        for task in ordered {
            if let parent = task.parentID, known[parent] != nil, !isOnCycle(task.id) {
                children[parent, default: []].append(task)
            } else {
                roots.append(task)
            }
        }

        // 접힌 분기의 끝 글을 위한 수: 자손 가운데 도는 일 · 실패 (자기 자신은 세지 않는다)
        var counts: [String: (running: Int, failed: Int)] = [:]
        func below(_ id: String) -> (running: Int, failed: Int) {
            if let cached = counts[id] { return cached }
            var total = (running: 0, failed: 0)
            for child in children[id] ?? [] {
                if child.status == .running { total.running += 1 }
                if child.status == .failed { total.failed += 1 }
                let nested = below(child.id)
                total.running += nested.running
                total.failed += nested.failed
            }
            counts[id] = total
            return total
        }

        var rows: [SubagentTreeRow] = []
        func visit(_ task: BackgroundTask, level: Int) {
            let kids = children[task.id] ?? []
            let expanded = !kids.isEmpty && expansion.isExpanded(id: task.id, level: level)
            var summary: String?
            if !kids.isEmpty, !expanded {
                let total = below(task.id)
                let parts = [total.running > 0 ? "\(SessionViewCopy.running) \(total.running)" : nil, total.failed > 0 ? "\(SessionViewCopy.failed) \(total.failed)" : nil].compactMap { $0 }
                summary = parts.isEmpty ? nil : parts.joined(separator: " · ")
            }
            rows.append(SubagentTreeRow(task: task, level: level, hasChildren: !kids.isEmpty, isExpanded: expanded, branchSummary: summary))
            if expanded { for kid in kids { visit(kid, level: level + 1) } }
        }
        for root in roots { visit(root, level: 0) }
        return rows
    }
}
#endif
