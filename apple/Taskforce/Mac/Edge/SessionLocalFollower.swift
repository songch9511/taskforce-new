#if os(macOS)
import Foundation
import TaskforceKit

/// Taskforce 세션 패널이 이 Mac의 Claude 기록 위치(Claude 세션 id · 작업 폴더)를 찾아 쥐고 있는 일 (세션 보기 V1, 리뷰 P2).
/// 언제 찾을지는 Kit의 순수 일정(`LocalTranscriptLookup`)이 정하고, 이 객체는 찾은 값을 쥐고 바뀌면 알린다.
/// 시계 · 찾기 · 보임 · 마지막 일의 상태는 모두 주입된다 (시험은 시계를 손으로 돌린다)
@MainActor
final class SessionLocalFollower {
    private var lookup = LocalTranscriptLookup()
    private(set) var target: AgentLocalTranscriptTarget?
    private let find: @MainActor () async -> AgentLocalTranscriptTarget?
    private let isShown: @MainActor () -> Bool
    private let taskKey: @MainActor () -> String?
    private let onChange: @MainActor (AgentLocalTranscriptTarget?) -> Void

    /// - find: 이 Mac의 기록 위치를 지금 묻는다 (없으면 nil)
    /// - taskKey: 마지막 일의 상태를 가리키는 글 (바뀌면 새 턴이다: 어댑터가 다시 묶었을 수 있다)
    /// - onChange: 쥔 값이 바뀌었다 (처음 찾음 · 다른 값 · 사라짐)
    init(
        find: @escaping @MainActor () async -> AgentLocalTranscriptTarget?, isShown: @escaping @MainActor () -> Bool, taskKey: @escaping @MainActor () -> String?,
        onChange: @escaping @MainActor (AgentLocalTranscriptTarget?) -> Void
    ) {
        self.find = find
        self.isShown = isShown
        self.taskKey = taskKey
        self.onChange = onChange
    }

    /// 한 번 (보통 1초마다): 찾을 때면 찾고, 쥔 값이 바뀌었으면 알린다
    func tick(now: TimeInterval) async {
        guard lookup.shouldLook(now: now, shown: isShown(), hasTarget: target != nil, key: taskKey()) else { return }
        let found = await find()
        // 찾는 동안 세션이 바뀌어 이 일이 취소됐다면 그 결과는 이 세션의 것이 아니다 (A의 늦은 결과가 B 패널에 연결되지 않게): 아무것도 바꾸지 않는다
        guard !Task.isCancelled else { return }
        lookup.record(found: found != nil, now: now)
        guard found != target else { return }
        target = found
        onChange(found)
    }
}
#endif
