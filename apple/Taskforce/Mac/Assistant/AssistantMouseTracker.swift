#if os(macOS)
import AppKit

/// 마우스를 누른 채 끄는 동안 이벤트를 직접 따라간다 (창 끌기 · 크기 조절 끌기가 같이 쓴다). `trackEvents`라 마우스가 창 밖으로 나가도 놓을 때까지 이어진다.
/// `NSWindow.performDrag`를 쓰지 않는 까닭: 키 창이 아닌 비활성 패널을 그 끌기로 옮기면 AppKit이 창을 앞으로 · 키 창으로 만든다 (옮기려다 다른 앱에 치던 글이 입력창으로 들어간다).
/// 직접 따라가면 키 창 · 앱 활성은 그대로다
struct AssistantMouseTracker {
    /// 이벤트가 있을 때의 마우스 자리 (화면 좌표, 아래가 0). 창이 움직이는 중에도 흔들리지 않게 이벤트 안의 자리가 아니라 지금의 마우스를 읽는다. 시험은 바꾼다
    var locate: (NSEvent) -> CGPoint = { _ in NSEvent.mouseLocation }
    /// 놓는 이벤트를 한 번 기다리는 시간: 이 시간마다 버튼이 아직 눌려 있는지 본다 (시험은 줄인다)
    var timeout: TimeInterval = 0.25
    /// 마우스 왼쪽 버튼이 눌려 있나: 놓는 이벤트를 놓쳤을 때(다른 창 · 시스템 대화상자가 가져감) 끌기를 끝맺는다. 시험은 바꾼다
    var buttonIsDown: () -> Bool = { NSEvent.pressedMouseButtons & 1 != 0 }

    /// `event`(왼쪽 누름)가 시작한 끌기를 놓을 때까지 따라간다. 이벤트마다 처음 누른 곳에서 움직인 만큼(`delta`, 화면 좌표, 위로 끌면 +)을 알린다.
    /// 놓는 이벤트가 오지 않아도 버튼이 올라가 있으면 끝낸다
    @MainActor
    func track(in window: NSWindow, from event: NSEvent, onDelta: (CGPoint) -> Void) {
        let start = locate(event)
        var finished = false
        repeat {
            window.trackEvents(matching: [.leftMouseDragged, .leftMouseUp], timeout: timeout, mode: .eventTracking) { tracked, stop in
                // 시간 초과: 버튼을 다시 본다
                guard let tracked else {
                    stop.pointee = true
                    return
                }
                let point = locate(tracked)
                onDelta(CGPoint(x: point.x - start.x, y: point.y - start.y))
                if tracked.type == .leftMouseUp {
                    finished = true
                    stop.pointee = true
                }
            }
        } while !finished && buttonIsDown()
    }
}
#endif
