#if os(macOS)
import Foundation

/// 보이는 곳의 스크롤 상태 (화면이 `onScrollGeometryChange`에서 읽는다)
public struct SessionScrollSnapshot: Equatable, Sendable {
    /// 보이는 영역의 아래 끝 (내용 좌표)
    public var visibleMaxY: CGFloat
    public var contentHeight: CGFloat
    public var visibleHeight: CGFloat

    public init(visibleMaxY: CGFloat, contentHeight: CGFloat, visibleHeight: CGFloat) {
        self.visibleMaxY = visibleMaxY
        self.contentHeight = contentHeight
        self.visibleHeight = visibleHeight
    }
}

/// "맨 아래에 붙어 있다"의 판단 (DZ 열린 질문 12, 사용자 승인): 붙어 있으면 새 글을 따라 내려가고, 사용자가 위로 올리면 끌어내리지 않는다 (단추 없음).
/// 순수한 규칙이다: 내용이 늘거나 보이는 크기가 바뀐 변화는 사용자가 스크롤한 것이 아니므로 의도를 바꾸지 않는다 (새 글이 붙는 순간 맨 아래가 멀어져도 풀리지 않는다)
public enum SessionScrollPin {
    /// 맨 아래에서 이만큼(pt) 안이면 맨 아래다
    public static let slack: CGFloat = 24

    public static func isAtBottom(_ snapshot: SessionScrollSnapshot) -> Bool {
        snapshot.visibleMaxY >= snapshot.contentHeight - slack
    }

    public static func next(pinned: Bool, old: SessionScrollSnapshot, new: SessionScrollSnapshot) -> Bool {
        if new.contentHeight != old.contentHeight || new.visibleHeight != old.visibleHeight { return pinned || isAtBottom(new) }
        return isAtBottom(new)
    }

    /// 새 글 · 상태가 바뀌었을 때 맨 아래로 내려가나
    public static func shouldFollowNewContent(pinned: Bool) -> Bool { pinned }
}
#endif
