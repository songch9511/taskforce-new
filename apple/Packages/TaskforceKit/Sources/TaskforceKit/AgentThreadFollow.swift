import Foundation

/// 에이전트 대화의 글 따라 읽기 (Claude Code 첫 실사용: 승인 세 번 뒤 마지막 답이 Mac 대화에 나오지 않았다).
///
/// 에이전트의 글(답 · 질문 · 사건 줄)은 bridge가 서버에 쓰고, 앱은 `conversation_messages`를 RLS로 읽는다. 이 표는 Realtime 발행 대상이 아니고(`actions` · `bridge_commands`만이다),
/// 대화 글은 대화를 열 때 · 질문에 답했을 때 · 목록을 읽을 때만 다시 읽었다. 그래서 답이 서버에 있어도 화면은 모르는 채였다.
/// 세션 읽기(`AgentSessionReadPolicy`: 열린 task가 있으면 5초마다)가 이미 돌고 있으므로 그 읽기가 반영될 때 같이 읽는다:
/// - 열린 task가 있는 세션: 읽을 때마다 (턴 중간의 글 · 질문 줄이 보인다)
/// - 열려 있지 않지만 **마지막으로 본 뒤 턴 번호나 상태가 바뀐** 세션: 한 번 더 (턴이 끝난 읽기에서 마지막 답을 읽는다. 서버는 글을 쓴 같은 트랜잭션에서 task를 바꾸므로 이 읽기에는 마지막 글이 들어 있다)
/// - 처음 보는 쉬는 세션은 읽지 않는다 (대화를 열 때 이미 읽었다), 그대로인 쉬는 세션도 읽지 않는다
public enum AgentThreadFollow {
    /// 세션을 마지막으로 읽었을 때 본 값
    public struct Mark: Equatable, Sendable {
        public var turnSeq: Int
        public var state: AgentTaskState?
    }

    public struct Plan: Equatable, Sendable {
        /// 글을 다시 읽을 세션들
        public var reread: Set<UUID>
        /// 다음에 비교할 값 (이번 읽기에 없는 세션은 버린다)
        public var marks: [UUID: Mark]
    }

    public static func plan(items: [AgentSessionItem], marks: [UUID: Mark]) -> Plan {
        var reread = Set<UUID>()
        var next: [UUID: Mark] = [:]
        for item in items {
            let mark = Mark(turnSeq: item.turnSeq, state: item.lastTaskState)
            if item.hasOpenTask || marks[item.id].map({ $0 != mark }) == true { reread.insert(item.id) }
            next[item.id] = mark
        }
        return Plan(reread: reread, marks: next)
    }
}

extension ChatStore {
    /// 세션 읽기가 반영됐다 (`AgentSessionStore.onApplied`): 보이는 에이전트 대화 중 글을 다시 읽을 세션의 것을 읽는다.
    /// 보이지 않는 대화는 읽지 않는다 (보일 때 열면서 읽는다)
    public func agentSessionsRead(_ items: [AgentSessionItem]) {
        let plan = AgentThreadFollow.plan(items: items, marks: agentThreadMarks)
        agentThreadMarks = plan.marks
        guard !plan.reread.isEmpty else { return }
        for id in shownAgentConversations() where agentSessionID(for: id).map(plan.reread.contains) == true {
            spawn { await self.loadThread(id) }
        }
    }
}
