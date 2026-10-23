#if os(macOS)
import Foundation

/// Taskforce 세션 패널이 이 Mac의 Claude 기록 위치를 찾는 일정 (순수: 시계 · 파일을 만지지 않는다). 첫 턴이 끝나기 전에는 어댑터가 아직 Claude 세션을 묶지 않았다.
/// - 못 찾으면 계속 찾는다: 간격은 1 · 2 · 4 · 8 · 15 · 30초이고 30초가 상한이다 (이전에는 1초 간격 30번에서 영영 멈췄다)
/// - 세는 것은 **패널이 보이는 동안**의 찾기뿐이다: 숨은 동안은 찾지도 세지도 않고, 보이면 바로 찾는다
/// - 마지막 일의 상태(키)가 바뀌면 처음부터 다시 (그 순간 바로): 새 턴이 시작하면 어댑터가 Claude 세션을 다시 묶었을 수 있다
/// - 이미 찾은 위치도 키가 바뀔 때 · 숨었다 다시 보일 때 한 번 확인한다 (그 사이 사라지거나 달라졌을 수 있다)
public struct LocalTranscriptLookup: Equatable, Sendable {
    /// 못 찾았을 때 다음 찾기까지의 간격(초). 마지막 값이 상한이다
    public static let delays: [TimeInterval] = [1, 2, 4, 8, 15, 30]

    /// 연달아 못 찾은 횟수 (패널이 보이는 동안의 찾기만)
    public private(set) var failures = 0
    private var nextAt: TimeInterval = 0
    private var lastKey: String?
    /// 찾은 위치를 이번 키 · 이번 보임에서 확인했다
    private var validated = false
    private var wasShown = true

    public init() {}

    /// 지금 찾을 때인가. `now`는 단조 시계(초)
    public mutating func shouldLook(now: TimeInterval, shown: Bool, hasTarget: Bool, key: String?) -> Bool {
        if key != lastKey {
            lastKey = key
            failures = 0
            nextAt = now
            validated = false
        }
        guard shown else {
            wasShown = false
            return false
        }
        if !wasShown {
            wasShown = true
            validated = false
        }
        if hasTarget { return !validated }
        return now >= nextAt
    }

    /// 찾은 결과를 알린다 (`shouldLook`이 true였던 바로 그 호출 뒤에)
    public mutating func record(found: Bool, now: TimeInterval) {
        validated = true
        if found {
            failures = 0
        } else {
            failures += 1
            nextAt = now + Self.delays[min(failures, Self.delays.count) - 1]
        }
    }
}
#endif
