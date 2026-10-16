import Foundation

// 레일 맨 위 Review 타일 (OA U1, DS ReviewTile). 판정은 서버가 한 것을 모아 보일 뿐이다:
// - needs-you: 지금 답할 Review 항목이 있다 (v1 확인 요청, 뒤에 D4b-s 입력이 더해진다). 노랑 `marker` 타일
// - 없으면 타일이 없다 (비활성이 아니다). 복귀 요약의 바뀐 것만으로는 타일이 생기지 않는다 (OA U2b 사용자 결정: 타일은 답할 것이 있을 때만)
// 타일은 Review(`S4`)와 복귀 요약(`C3`) 표면이 둘 다 켜졌을 때만 있다 (U1-23).

public enum ReviewTileContent: Equatable, Sendable {
    case needsYou(count: Int)
}

public enum ReviewTileRules {
    /// 타일에 보일 것 (없으면 nil)
    /// - reviewCount: 지금 Review 큐의 항목 수
    public static func content(reviewCount: Int, reviewEnabled: Bool, summaryEnabled: Bool) -> ReviewTileContent? {
        guard reviewEnabled, summaryEnabled, reviewCount > 0 else { return nil }
        return .needsYou(count: reviewCount)
    }

    /// 툴팁: 화면에는 개수가 없다
    public static func tooltip(_ content: ReviewTileContent) -> String {
        "Review · Needs your answer"
    }

    /// 접근성 이름: 툴팁 + 개수 (개수는 읽어 주는 데만 쓴다)
    public static func accessibilityName(_ content: ReviewTileContent) -> String {
        switch content {
        case .needsYou(let count): "\(tooltip(content)), \(count) \(count == 1 ? "item" : "items")"
        }
    }
}
