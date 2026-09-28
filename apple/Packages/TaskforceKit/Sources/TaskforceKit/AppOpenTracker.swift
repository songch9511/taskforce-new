import Foundation

/// 지표 2 · 3 `app_opened`를 언제 보낼지. 제어 센터 · 알림 · Face ID로 잠깐 inactive가 됐다 돌아온 건
/// 새로 연 게 아니다: 로그인한 화면이 처음 나타난 뒤, 그리고 백그라운드에서 돌아올 때만 보낸다.
public struct AppOpenTracker: Sendable, Equatable {
    /// SwiftUI `ScenePhase`와 같은 세 상태 (패키지는 SwiftUI에 기대지 않는다)
    public enum Phase: Sendable {
        case active, inactive, background
    }

    /// 마지막으로 보낸 뒤 백그라운드에 갔었는지. 처음 나타남도 연 것으로 친다.
    private var away = true

    public init() {}

    /// 장면 상태가 바뀔 때마다(처음 나타날 때 포함) 부른다. true면 `app_opened`를 보낸다.
    public mutating func update(_ phase: Phase) -> Bool {
        switch phase {
        case .background:
            away = true
            return false
        case .inactive:
            return false
        case .active:
            defer { away = false }
            return away
        }
    }
}
