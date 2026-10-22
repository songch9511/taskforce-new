#if os(macOS)
import Foundation

/// 같은 입력이면 지난번에 만든 것을 그대로 돌려준다 (세션 보기의 타임라인: 단계 묶기 · 일한 시간 · 답 밑 줄을 만드는 일은 글 수에 비례한다).
/// 패널의 본문은 상태 · 호버 · 높이가 바뀔 때마다 다시 계산되지만 대화가 그대로면 입력도 그대로다: 입력의 같음으로 가른다
/// (`Array`의 `==`는 같은 저장소면 곧바로 같다고 답한다). 마지막 하나만 기억한다 (세션을 바꾸면 입력이 달라져 다시 만든다)
@MainActor
final class SessionTimelineMemo<Input: Equatable, Output> {
    private var last: (input: Input, output: Output)?
    /// 실제로 만든 횟수 (시험이 센다)
    private(set) var builds = 0

    func value(for input: Input, build: () -> Output) -> Output {
        if let last, last.input == input { return last.output }
        let output = build()
        builds += 1
        last = (input, output)
        return output
    }

    func reset() { last = nil }
}
#endif
