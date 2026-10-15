import Foundation

/// 세션 다시 읽기 규칙 (OA U2-35, 계약 3.1 ③). `agent_sessions` · `agent_tasks`는 Realtime 발행 대상이 아니라서 링 · 상태 줄을 살아 있게 하려면 앱이 다시 읽어야 한다.
/// 읽기를 시작하는 때: 화면(Issues · 이슈 목록 · 상세 · 세션 패널)을 열 때 · `actions` 변경 신호 · 온라인 복귀 · 잠자기에서 깸 (저장소의 `refresh()`를 부르는 쪽이 정한다),
/// 그리고 열린 task가 하나라도 있으면 5초마다. 이 순수 함수가 5초 읽기의 유일한 규칙이다.
/// 서버에 `agent_sessions` · `agent_tasks` 발행이 생기면 이 규칙을 지운다 (다시 읽기 규칙은 이 한 곳)
public enum AgentSessionReadPolicy {
    public static let interval: TimeInterval = 5

    /// 다음 읽기까지의 시간. 열린 task가 없거나(닫힌 세션의 task는 세지 않는다) 앱이 잠자면 nil — 멈춘다
    public static func pollInterval(items: [AgentSessionItem], asleep: Bool) -> TimeInterval? {
        guard !asleep, items.contains(where: \.hasOpenTask) else { return nil }
        return interval
    }
}
