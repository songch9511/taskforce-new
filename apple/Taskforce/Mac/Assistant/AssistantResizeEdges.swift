#if os(macOS)
import AppKit
import TaskforceKit

/// 크기 조절 끌기가 컨트롤러에 알리는 네 가지: 시작(어느 가장자리) · 마우스가 처음 누른 곳에서 움직인 만큼 · 끝 · 두 번 눌러 기본 크기로
struct AssistantResizeHandlers {
    var begin: (AssistantWindowGeometry.ResizeEdge) -> Void = { _ in }
    var drag: (CGPoint) -> Void = { _ in }
    var end: () -> Void = {}
    var reset: () -> Void = {}
}

/// 창의 내용: SwiftUI 뷰 위에 가장자리 · 모서리의 크기 조절 띠 여덟 개를 얹는다. 띠가 위에 있어 창 가장자리의 누름을 먼저 받고,
/// 그 안쪽은 SwiftUI가 받는다. 테두리가 없는 비활성 패널(`.borderless` + `.nonactivatingPanel`)이라 AppKit이 크기 조절을 주지 않아 직접 그린다.
/// 좌표는 위가 0이다 (`isFlipped`: SwiftUI 호스팅 뷰와 같다)
final class AssistantWindowContentView: NSView {
    /// 가장자리 띠의 굵기. 머리 위 핸들(캡슐은 위 6–10pt)을 가리지 않고, 본문 스크롤 막대의 바깥 조각만 덮는다
    nonisolated static let edgeThickness: CGFloat = 5
    /// 모서리 정사각형의 한 변. 창 모서리(반지름 18)의 둥근 곳 바깥은 투명이라 누름이 창을 통과한다: 보이는 쪽(대각선으로 5pt 안쪽부터)이 잡히도록 넉넉히
    nonisolated static let cornerSize: CGFloat = 16

    let content: NSView
    private(set) var edgeViews: [AssistantWindowGeometry.ResizeEdge: AssistantResizeEdgeView] = [:]
    var handlers = AssistantResizeHandlers()

    init(content: NSView) {
        self.content = content
        super.init(frame: content.frame)
        content.frame = bounds
        content.autoresizingMask = [.width, .height]
        addSubview(content)
        for edge in AssistantWindowGeometry.ResizeEdge.allCases {
            let view = AssistantResizeEdgeView(edge: edge, owner: self)
            edgeViews[edge] = view
            addSubview(view)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let width = bounds.width, height = bounds.height
        let t = Self.edgeThickness, c = Self.cornerSize
        let sides = CGSize(width: max(0, width - 2 * c), height: max(0, height - 2 * c))
        edgeViews[.top]?.frame = CGRect(x: c, y: 0, width: sides.width, height: t)
        edgeViews[.bottom]?.frame = CGRect(x: c, y: height - t, width: sides.width, height: t)
        edgeViews[.left]?.frame = CGRect(x: 0, y: c, width: t, height: sides.height)
        edgeViews[.right]?.frame = CGRect(x: width - t, y: c, width: t, height: sides.height)
        edgeViews[.topLeft]?.frame = CGRect(x: 0, y: 0, width: c, height: c)
        edgeViews[.topRight]?.frame = CGRect(x: width - c, y: 0, width: c, height: c)
        edgeViews[.bottomLeft]?.frame = CGRect(x: 0, y: height - c, width: c, height: c)
        edgeViews[.bottomRight]?.frame = CGRect(x: width - c, y: height - c, width: c, height: c)
    }
}

/// 가장자리 또는 모서리 하나의 띠: 누르고 끌면 그만큼 창 크기를 바꾸고, 두 번 누르면 기본 크기로 돌아간다.
/// 마우스를 누르는 동안 이벤트를 직접 따라간다 (`trackEvents`): 마우스가 창 밖으로 나가도 놓을 때까지 이어지고, 창이 키 창이 되지 않는다
final class AssistantResizeEdgeView: NSView {
    let edge: AssistantWindowGeometry.ResizeEdge
    private weak var owner: AssistantWindowContentView?
    /// 이벤트가 있을 때의 마우스 자리 (화면 좌표, 아래가 0). 창이 움직이는 중에도 흔들리지 않게 이벤트가 아니라 지금의 마우스를 읽는다. 시험은 바꾼다
    var locate: (NSEvent) -> CGPoint = { _ in NSEvent.mouseLocation }
    /// 놓는 이벤트를 기다리는 가장 긴 시간 (시험은 줄인다)
    var trackTimeout: TimeInterval = NSEvent.foreverDuration

    init(edge: AssistantWindowGeometry.ResizeEdge, owner: AssistantWindowContentView) {
        self.edge = edge
        self.owner = owner
        super.init(frame: .zero)
        setAccessibilityElement(false)
        // 다른 앱이 앞이어도 · 창 크기가 바뀌어도 커서가 바뀐다
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.cursorUpdate, .activeAlways, .inVisibleRect], owner: self, userInfo: nil))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// 시스템의 창 크기 조절 커서 (macOS 15): 가장자리마다 방향이 다르다
    var cursor: NSCursor {
        let position: NSCursor.FrameResizePosition = switch edge {
        case .top: .top
        case .bottom: .bottom
        case .left: .left
        case .right: .right
        case .topLeft: .topLeft
        case .topRight: .topRight
        case .bottomLeft: .bottomLeft
        case .bottomRight: .bottomRight
        }
        return .frameResize(position: position, directions: .all)
    }

    override func cursorUpdate(with event: NSEvent) {
        cursor.set()
    }

    /// 다른 앱이 앞이어도 첫 누름이 끌기를 시작한다
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override var mouseDownCanMoveWindow: Bool { false }

    override func mouseDown(with event: NSEvent) {
        guard let window, let handlers = owner?.handlers else { return }
        if event.clickCount >= 2 {
            handlers.reset()
            return
        }
        let start = locate(event)
        handlers.begin(edge)
        window.trackEvents(matching: [.leftMouseDragged, .leftMouseUp], timeout: trackTimeout, mode: .eventTracking) { tracked, stop in
            // 시간 초과: 놓는 이벤트를 놓쳤다. 여기서 끝맺는다
            guard let tracked else {
                stop.pointee = true
                return
            }
            let point = self.locate(tracked)
            handlers.drag(CGPoint(x: point.x - start.x, y: point.y - start.y))
            if tracked.type == .leftMouseUp { stop.pointee = true }
        }
        handlers.end()
    }
}
#endif
