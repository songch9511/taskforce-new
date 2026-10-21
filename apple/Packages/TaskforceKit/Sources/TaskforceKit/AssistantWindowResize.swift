import CoreGraphics
import Foundation

/// 사용자가 정한 Assistant 창 크기 (화면별 기억). `height`가 nil이면 높이는 내용에 맞춘다: 폭만 바꿨거나 아직 바꾸지 않았다
public struct AssistantWindowSize: Codable, Equatable, Sendable {
    public var width: CGFloat
    public var height: CGFloat?

    public init(width: CGFloat, height: CGFloat? = nil) {
        self.width = width
        self.height = height
    }

    /// 기본: 380pt 폭, 높이는 내용에 맞춘다 (빈 대화 440 · 560까지)
    public static let standard = AssistantWindowSize(width: AssistantWindowGeometry.width, height: nil)
}

/// Assistant 창의 크기 조절 규칙 (순수 함수). 좌표 · 변화량은 화면 좌표(아래가 0, 위로 끌면 `dy`가 양수)다.
/// 기본 크기는 그대로(`width` · `emptyHeight` · `maxHeight`)이고, 사용자가 가장자리 · 모서리를 끌면 그 값이 기본을 대신한다.
extension AssistantWindowGeometry {
    /// 작게: 입력창(대상 알약 · 보내기)이 한 줄에 들어가는 폭
    public static let minWidth: CGFloat = 320
    /// 작게: 머리 · 메시지 한 줄 · 입력창이 쓸 만한 높이
    public static let minHeight: CGFloat = 260
    /// 본문이 최소 이만큼은 보여야 한다 (메시지 한 줄)
    public static let minBodyHeight: CGFloat = 72
    /// 핸들에 포커스를 두고 ⌥ + 화살표
    public static let keyboardResizeStep: CGFloat = 16

    /// 크기를 바꾸는 가장자리 · 모서리
    public enum ResizeEdge: CaseIterable, Sendable {
        case top, bottom, left, right, topLeft, topRight, bottomLeft, bottomRight

        public var movesLeft: Bool { self == .left || self == .topLeft || self == .bottomLeft }
        public var movesRight: Bool { self == .right || self == .topRight || self == .bottomRight }
        public var movesTop: Bool { self == .top || self == .topLeft || self == .topRight }
        public var movesBottom: Bool { self == .bottom || self == .bottomLeft || self == .bottomRight }
        /// 높이가 바뀌는 쪽인가 (아니면 폭만 바뀐다: 높이는 계속 내용에 맞춘다)
        public var changesHeight: Bool { movesTop || movesBottom }
    }

    /// 창이 커질 수 있는 가장 큰 크기: 보이는 영역에서 레일(펼친 폭)을 뺀 곳. 화면이 아주 작아도 최소 밑으로 내려가지 않는다
    public static func maxSize(visible: CGRect, railWidth: CGFloat) -> CGSize {
        CGSize(width: Swift.max(minWidth, visible.width - railWidth), height: Swift.max(minHeight, visible.height))
    }

    /// 창의 가장자리가 갈 수 있는 영역: 보이는 영역에서 오른쪽 레일을 뺀 곳
    public static func resizeBounds(visible: CGRect, railWidth: CGFloat) -> CGRect {
        CGRect(x: visible.minX, y: visible.minY, width: Swift.max(0, visible.width - railWidth), height: visible.height)
    }

    /// 사용자가 줄일 수 있는 가장 낮은 높이: 머리 · 입력 영역 · 메시지 한 줄. 입력 영역이 커지면(칩 · 질문 카드) 그만큼 올라간다
    public static func minimumHeight(head: CGFloat, footer: CGFloat) -> CGFloat {
        Swift.max(minHeight, head + footer + minBodyHeight)
    }

    /// 창의 크기: 사용자가 정한 값 · 내용 · 화면으로. 정한 높이가 없으면 내용에 맞추고(`height(content:isEmpty:)`: 440 · 560),
    /// 정한 높이는 내용과 상관없이 따른다. 어느 쪽이든 이 화면의 최대(보이는 영역 − 레일) 안이고, 정한 값은 최소 밑으로 내려가지 않는다
    public static func size(
        _ preferred: AssistantWindowSize, contentHeight: CGFloat, isEmpty: Bool, head: CGFloat, footer: CGFloat, visible: CGRect, railWidth: CGFloat
    ) -> CGSize {
        let limit = maxSize(visible: visible, railWidth: railWidth)
        let width = Swift.min(Swift.max(preferred.width, minWidth), limit.width)
        guard let chosen = preferred.height else {
            return CGSize(width: width, height: Swift.min(height(content: contentHeight, isEmpty: isEmpty), limit.height))
        }
        return CGSize(width: width, height: Swift.min(Swift.max(chosen, minimumHeight(head: head, footer: footer)), limit.height))
    }

    /// 끌기가 시작된 때의 창에 변화량을 더해 새 창을 구한다. 끄는 쪽 가장자리만 움직이고 반대쪽은 그대로다.
    /// 크기는 `min` ~ `max`, 가장자리는 `bounds` 안이다 (영역 밖에서 시작한 창은 최소를 먼저 지킨다).
    /// 이미 최소보다 작은 창(내용에 맞춘 짧은 대화)은 누르기만 해서 커지지 않는다: 더 줄이지 못할 뿐 늘리는 것은 된다
    public static func resized(
        _ frame: CGRect, edge: ResizeEdge, by delta: CGPoint, within bounds: CGRect, min requested: CGSize, max maximum: CGSize
    ) -> CGRect {
        let minimum = CGSize(width: Swift.min(requested.width, frame.width), height: Swift.min(requested.height, frame.height))
        var minX = frame.minX, maxX = frame.maxX, minY = frame.minY, maxY = frame.maxY
        if edge.movesLeft {
            minX = constrain(
                frame.minX + delta.x, hard: (frame.maxX - maximum.width, frame.maxX - minimum.width), soft: (bounds.minX, .greatestFiniteMagnitude)
            )
        }
        if edge.movesRight {
            maxX = constrain(
                frame.maxX + delta.x, hard: (frame.minX + minimum.width, frame.minX + maximum.width), soft: (-.greatestFiniteMagnitude, bounds.maxX)
            )
        }
        if edge.movesBottom {
            minY = constrain(
                frame.minY + delta.y, hard: (frame.maxY - maximum.height, frame.maxY - minimum.height), soft: (bounds.minY, .greatestFiniteMagnitude)
            )
        }
        if edge.movesTop {
            maxY = constrain(
                frame.maxY + delta.y, hard: (frame.minY + minimum.height, frame.minY + maximum.height), soft: (-.greatestFiniteMagnitude, bounds.maxY)
            )
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// 값을 `hard`(크기 한도)와 `soft`(보이는 영역) 둘 안으로 넣는다. 둘이 겹치지 않으면 `hard`만 지킨다
    private static func constrain(_ value: CGFloat, hard: (low: CGFloat, high: CGFloat), soft: (low: CGFloat, high: CGFloat)) -> CGFloat {
        var low = Swift.max(hard.low, soft.low)
        var high = Swift.min(hard.high, soft.high)
        if low > high { (low, high) = hard }
        return Swift.min(Swift.max(value, low), high)
    }

    /// 핸들에 포커스를 두고 ⌥ + 화살표: 오른쪽 아래 모서리를 16pt씩 옮긴다 (왼쪽 위는 그대로)
    public static func keyboardResizeDelta(_ direction: Direction) -> CGPoint {
        switch direction {
        case .left: CGPoint(x: -keyboardResizeStep, y: 0)
        case .right: CGPoint(x: keyboardResizeStep, y: 0)
        case .up: CGPoint(x: 0, y: keyboardResizeStep)
        case .down: CGPoint(x: 0, y: -keyboardResizeStep)
        }
    }

    /// 너비 · 높이를 가진 창을 보이는 영역 안으로 넣는다 (넓어진 창도 레일을 덮지 않는다). 높이가 보이는 영역보다 크면 위를 맞춘다
    public static func clamped(topLeft: CGPoint, size: CGSize, visible: CGRect, railWidth: CGFloat) -> CGPoint {
        let rightLimit = visible.maxX - railWidth - size.width
        let x = Swift.max(visible.minX, Swift.min(topLeft.x, rightLimit))
        let y: CGFloat
        if size.height >= visible.height {
            y = visible.maxY
        } else {
            y = Swift.max(visible.minY + size.height, Swift.min(topLeft.y, visible.maxY))
        }
        return CGPoint(x: x, y: y)
    }
}
