import CoreGraphics
import Foundation
import Testing
@testable import TaskforceKit

/// Assistant 창 크기 조절의 순수 규칙: 가장자리 · 모서리 끌기, 최소 · 최대, 자동 높이와 사용자 높이, 화면별 기억.
/// 좌표는 화면 좌표(아래가 0)다. 끌기 변화량 `delta`도 같다 (위로 끌면 `dy`가 양수)
struct AssistantWindowResizeTests {
    typealias G = AssistantWindowGeometry

    /// 1440 × 875 보이는 영역, 레일 44 → 창이 쓸 수 있는 영역은 오른쪽 44를 뺀 곳
    let visible = CGRect(x: 0, y: 0, width: 1440, height: 875)
    var bounds: CGRect { G.resizeBounds(visible: visible, railWidth: 44) }
    /// 380 × 440 창, 왼쪽 위 (600, 700)
    let frame = CGRect(x: 600, y: 260, width: 380, height: 440)
    let min = CGSize(width: G.minWidth, height: G.minHeight)

    private func resize(_ frame: CGRect, _ edge: G.ResizeEdge, dx: CGFloat = 0, dy: CGFloat = 0, max: CGSize? = nil) -> CGRect {
        G.resized(frame, edge: edge, by: CGPoint(x: dx, y: dy), within: bounds, min: min, max: max ?? G.maxSize(visible: visible, railWidth: 44))
    }

    // MARK: 한도

    @Test func theDefaultsAreTheShippedSizeAndTheLimitsAroundIt() {
        #expect(G.width == 380 && G.emptyHeight == 440 && G.maxHeight == 560, "기본은 그대로")
        #expect(G.minWidth == 320 && G.minHeight == 260, "작게는 입력창과 메시지 한 줄이 쓸 만한 크기까지")
        #expect(G.minWidth < G.width && G.minHeight < G.emptyHeight)
    }

    @Test func theLargestSizeIsTheVisibleAreaMinusTheRail() {
        #expect(G.maxSize(visible: visible, railWidth: 44) == CGSize(width: 1440 - 44, height: 875))
        #expect(G.maxSize(visible: visible, railWidth: 0) == CGSize(width: 1440, height: 875), "레일이 없는 화면은 끝까지")
        let tiny = CGRect(x: 0, y: 0, width: 200, height: 100)
        let limit = G.maxSize(visible: tiny, railWidth: 44)
        #expect(limit.width >= G.minWidth && limit.height >= G.minHeight, "화면이 작아도 최대가 최소 밑으로 내려가지 않는다")
    }

    @Test func theResizeBoundsAreTheVisibleAreaWithoutTheRail() {
        #expect(G.resizeBounds(visible: visible, railWidth: 44) == CGRect(x: 0, y: 0, width: 1440 - 44, height: 875))
    }

    @Test func theMinimumHeightKeepsTheHeaderTheComposerAndOneMessage() {
        #expect(G.minimumHeight(head: 52, footer: 100) == G.minHeight, "보통의 입력 영역은 기본 최소 높이로 충분하다")
        #expect(G.minimumHeight(head: 52, footer: 300) == 52 + 300 + G.minBodyHeight, "칩이 많거나 질문 카드가 열리면 그만큼 더 크게")
        #expect(G.minimumHeight(head: 0, footer: 0) == G.minHeight, "아직 재지 못했을 때")
    }

    // MARK: 가장자리 · 모서리

    @Test func theRightEdgeWidensTheWindowAndKeepsTheLeftAndTheTop() {
        let r = resize(frame, .right, dx: 60)
        #expect(r == CGRect(x: 600, y: 260, width: 440, height: 440))
        #expect(r.minX == frame.minX && r.maxY == frame.maxY, "왼쪽 위는 그대로")
    }

    @Test func theLeftEdgeMovesTheLeftSideAndKeepsTheRightSide() {
        let r = resize(frame, .left, dx: -50)
        #expect(r == CGRect(x: 550, y: 260, width: 430, height: 440))
        #expect(r.maxX == frame.maxX && r.maxY == frame.maxY)
        let narrower = resize(frame, .left, dx: 40)
        #expect(narrower == CGRect(x: 640, y: 260, width: 340, height: 440))
    }

    @Test func theTopEdgeMovesTheTopAndKeepsTheBottom() {
        let r = resize(frame, .top, dy: 30)
        #expect(r == CGRect(x: 600, y: 260, width: 380, height: 470))
        #expect(r.minY == frame.minY, "아래는 그대로")
        #expect(resize(frame, .top, dy: -40) == CGRect(x: 600, y: 260, width: 380, height: 400))
    }

    @Test func theBottomEdgeMovesTheBottomAndKeepsTheTop() {
        let r = resize(frame, .bottom, dy: -70)
        #expect(r == CGRect(x: 600, y: 190, width: 380, height: 510))
        #expect(r.maxY == frame.maxY, "위는 그대로")
        #expect(resize(frame, .bottom, dy: 50) == CGRect(x: 600, y: 310, width: 380, height: 390))
    }

    @Test func eachCornerMovesBothOfItsEdgesAndNothingElse() {
        #expect(resize(frame, .bottomRight, dx: 20, dy: -30) == CGRect(x: 600, y: 230, width: 400, height: 470))
        #expect(resize(frame, .bottomLeft, dx: -20, dy: -30) == CGRect(x: 580, y: 230, width: 400, height: 470))
        #expect(resize(frame, .topRight, dx: 20, dy: 30) == CGRect(x: 600, y: 260, width: 400, height: 470))
        #expect(resize(frame, .topLeft, dx: -20, dy: 30) == CGRect(x: 580, y: 260, width: 400, height: 470))
    }

    @Test func aStillMouseChangesNothingOnAnyEdge() {
        for edge in G.ResizeEdge.allCases {
            #expect(resize(frame, edge) == frame, "\(edge)")
        }
    }

    // MARK: 최소 · 최대 · 화면

    @Test func theWindowNeverGetsSmallerThanTheMinimumAndTheFarEdgeStaysPut() {
        let right = resize(frame, .right, dx: -5000)
        #expect(right.width == G.minWidth && right.minX == frame.minX, "오른쪽 가장자리를 끝까지 당겨도 왼쪽은 그대로")
        let left = resize(frame, .left, dx: 5000)
        #expect(left.width == G.minWidth && left.maxX == frame.maxX, "왼쪽 가장자리를 끝까지 밀어도 오른쪽은 그대로 (창이 밀려나지 않는다)")
        let bottom = resize(frame, .bottom, dy: 5000)
        #expect(bottom.height == G.minHeight && bottom.maxY == frame.maxY)
        let top = resize(frame, .top, dy: -5000)
        #expect(top.height == G.minHeight && top.minY == frame.minY)
        let corner = resize(frame, .topLeft, dx: 5000, dy: -5000)
        #expect(corner.size == min && corner.maxX == frame.maxX && corner.minY == frame.minY)
    }

    @Test func aShortAutoHeightWindowDoesNotJumpToTheMinimumWhenGrabbed() {
        let short = CGRect(x: 600, y: 488, width: 380, height: 212)   // 짧은 대화: 내용에 맞춘 높이가 최소(260)보다 작다
        for edge in G.ResizeEdge.allCases {
            #expect(resize(short, edge) == short, "누르기만 해서는 커지지 않는다: \(edge)")
        }
        #expect(resize(short, .bottom, dy: 40) == short, "더 줄이지는 못한다")
        #expect(resize(short, .bottom, dy: -60) == CGRect(x: 600, y: 428, width: 380, height: 272), "늘리는 것은 된다")
        #expect(resize(short, .top, dy: 30) == CGRect(x: 600, y: 488, width: 380, height: 242))
    }

    @Test func aTallerMinimumFromABigComposerIsKept() {
        let tall = CGSize(width: G.minWidth, height: 420)
        let r = G.resized(frame, edge: .bottom, by: CGPoint(x: 0, y: 5000), within: bounds, min: tall, max: G.maxSize(visible: visible, railWidth: 44))
        #expect(r.height == 420)
    }

    @Test func theWindowStaysInsideTheVisibleAreaAndOutOfTheRail() {
        let right = resize(frame, .right, dx: 5000)
        #expect(right.maxX == bounds.maxX && right.maxX == visible.maxX - 44, "레일을 덮지 않는다")
        let left = resize(frame, .left, dx: -5000)
        #expect(left.minX == bounds.minX)
        let top = resize(frame, .top, dy: 5000)
        #expect(top.maxY == bounds.maxY && top.height <= 875)
        let bottom = resize(frame, .bottom, dy: -5000)
        #expect(bottom.minY == bounds.minY)
    }

    @Test func theLargestSizeCapsAWindowThatWouldOtherwiseFitTheScreen() {
        let cap = CGSize(width: 600, height: 700)
        let r = resize(CGRect(x: 100, y: 300, width: 380, height: 440), .bottomRight, dx: 5000, dy: -5000, max: cap)
        #expect(r.width == 600 && r.height == 700 && r.minX == 100 && r.maxY == 740, "왼쪽 위는 그대로, 최대에서 멈춘다")
        let atTheFloor = resize(CGRect(x: 100, y: 100, width: 380, height: 440), .bottomRight, dy: -5000, max: cap)
        #expect(atTheFloor.minY == bounds.minY && atTheFloor.height == 540, "최대보다 먼저 화면 아래에서 멈춘다")
        let left = resize(CGRect(x: 600, y: 100, width: 380, height: 440), .left, dx: -5000, max: cap)
        #expect(left.width == 600 && left.maxX == 980)
    }

    @Test func aWindowAlreadyOutsideTheBoundsStillResizesToAtLeastTheMinimum() {
        // 보이는 영역 밖에 걸친 창에서 끌기를 시작해도 최소를 어기지 않는다
        let outside = CGRect(x: -300, y: 260, width: 380, height: 440)
        let left = resize(outside, .left, dx: 500)
        #expect(left.width >= G.minWidth && left.maxX == outside.maxX)
        let beyond = CGRect(x: 1300, y: 260, width: 380, height: 440)
        let right = resize(beyond, .right, dx: -500)
        #expect(right.width >= G.minWidth && right.minX == beyond.minX)
    }

    // MARK: 크기 정하기 (사용자 값 + 내용 + 화면)

    private func size(_ preferred: AssistantWindowSize = .standard, content: CGFloat = 300, isEmpty: Bool = false, head: CGFloat = 52, footer: CGFloat = 100, visible override: CGRect? = nil, rail: CGFloat = 44) -> CGSize {
        G.size(preferred, contentHeight: content, isEmpty: isEmpty, head: head, footer: footer, visible: override ?? visible, railWidth: rail)
    }

    @Test func withoutAChoiceTheWindowIsTheShippedSize() {
        #expect(size(content: 300, isEmpty: true) == CGSize(width: 380, height: 440), "빈 대화 440")
        #expect(size(content: 300) == CGSize(width: 380, height: 300), "글이 있으면 내용에 맞춘다")
        #expect(size(content: 2000) == CGSize(width: 380, height: 560), "560에서 본문이 스크롤한다")
        #expect(size(content: 200) == CGSize(width: 380, height: 200), "짧은 대화는 최소 높이보다 작아도 내용에 맞춘다 (예전 그대로)")
    }

    @Test func aChosenWidthKeepsTheHeightHuggingTheContent() {
        let wide = AssistantWindowSize(width: 520)
        #expect(size(wide, content: 300) == CGSize(width: 520, height: 300))
        #expect(size(wide, content: 2000) == CGSize(width: 520, height: 560))
    }

    @Test func aChosenHeightFreesTheWindowFromTheContentInBothDirections() {
        let fixed = AssistantWindowSize(width: 380, height: 700)
        #expect(size(fixed, content: 300) == CGSize(width: 380, height: 700), "내용보다 커도 그 높이")
        #expect(size(fixed, content: 2000) == CGSize(width: 380, height: 700), "560을 넘어도 그 높이 (본문이 스크롤한다)")
        let short = AssistantWindowSize(width: 380, height: 300)
        #expect(size(short, content: 500, isEmpty: true) == CGSize(width: 380, height: 300), "빈 대화의 440 바닥도 사용자가 낮출 수 있다")
    }

    @Test func aChosenSizeIsClampedToTheLimitsAndTheScreen() {
        #expect(size(AssistantWindowSize(width: 100, height: 100)) == CGSize(width: G.minWidth, height: G.minHeight), "최소")
        #expect(size(AssistantWindowSize(width: 9000, height: 9000)) == CGSize(width: 1440 - 44, height: 875), "최대는 보이는 영역 − 레일")
        let small = CGRect(x: 0, y: 0, width: 800, height: 600)
        #expect(size(AssistantWindowSize(width: 900, height: 800), visible: small) == CGSize(width: 800 - 44, height: 600), "작은 화면으로 옮기면 그 화면 안으로")
        #expect(size(AssistantWindowSize(width: 900, height: 800), visible: small, rail: 0) == CGSize(width: 800, height: 600), "레일 없는 화면")
        #expect(size(AssistantWindowSize(width: 380, height: 270), head: 52, footer: 300) == CGSize(width: 380, height: 52 + 300 + G.minBodyHeight), "큰 입력 영역이면 최소 높이가 올라간다")
    }

    @Test func theAutoHeightIsAlsoKeptInsideAShortScreen() {
        let short = CGRect(x: 0, y: 0, width: 1440, height: 400)
        #expect(size(content: 2000, visible: short).height == 400)
        #expect(size(content: 300, isEmpty: true, visible: short).height == 400, "440 바닥도 화면을 넘지 않는다")
    }

    // MARK: 위치 (넓어진 창도 레일을 덮지 않는다)

    @Test func aWiderWindowIsPulledInFromTheRailByItsOwnWidth() {
        let wide = G.clamped(topLeft: CGPoint(x: 1300, y: 700), size: CGSize(width: 600, height: 400), visible: visible, railWidth: 44)
        #expect(wide.x + 600 <= 1440 - 44, "넓은 창도 레일을 덮지 않는다")
        let narrow = G.clamped(topLeft: CGPoint(x: 1300, y: 700), size: CGSize(width: 320, height: 400), visible: visible, railWidth: 44)
        let limit: CGFloat = 1440 - 44 - 320
        #expect(narrow.x == limit, "320 폭 창은 레일 왼쪽 끝에 닿는다")
        let fine = CGPoint(x: 200, y: 700)
        #expect(G.clamped(topLeft: fine, size: CGSize(width: 600, height: 400), visible: visible, railWidth: 44) == fine)
    }

    @Test func theOldHeightOnlyClampStillUsesTheDefaultWidth() {
        let old = G.clamped(topLeft: CGPoint(x: 1300, y: 700), height: 400, visible: visible, railWidth: 44)
        #expect(old == G.clamped(topLeft: CGPoint(x: 1300, y: 700), size: CGSize(width: 380, height: 400), visible: visible, railWidth: 44))
    }

    @Test func aWindowTallerThanTheScreenStillKeepsItsTopVisible() {
        let small = CGRect(x: 0, y: 0, width: 1440, height: 300)
        let point = G.clamped(topLeft: CGPoint(x: 100, y: 200), size: CGSize(width: 380, height: 500), visible: small, railWidth: 44)
        #expect(point.y == small.maxY)
    }

    // MARK: 자리와 크기의 기억 (화면별)

    @Test func theStandardSizeIsThe380WideAutoHeight() {
        #expect(AssistantWindowSize.standard == AssistantWindowSize(width: 380, height: nil))
    }

    @Test func aSizeIsRememberedPerDisplayAndOnlyTheStandardOneForgets() {
        var positions = AssistantWindowPositions()
        #expect(positions.size(display: "1") == nil)
        positions.rememberSize(AssistantWindowSize(width: 520, height: 700), display: "1")
        positions.rememberSize(AssistantWindowSize(width: 460), display: "2")
        #expect(positions.size(display: "1") == AssistantWindowSize(width: 520, height: 700))
        #expect(positions.size(display: "2") == AssistantWindowSize(width: 460, height: nil), "폭만 정했으면 높이는 자동")
        #expect(positions.size(display: "3") == nil, "다른 화면에는 기억이 없다")
        positions.rememberSize(.standard, display: "1")
        #expect(positions.size(display: "1") == nil, "기본으로 되돌리면 기억을 지운다")
        #expect(positions.size(display: "2") != nil)
    }

    @Test func sizesAndPositionsAreIndependent() {
        var positions = AssistantWindowPositions()
        let conversation = UUID(uuidString: "bcb50000-0000-4000-8000-000000000001")!
        positions.remember(CGPoint(x: 10, y: 20), conversation: conversation, display: "1")
        positions.rememberSize(AssistantWindowSize(width: 500, height: 600), display: "1")
        #expect(positions.position(conversation: conversation, display: "1") == CGPoint(x: 10, y: 20))
        #expect(positions.conversationCount == 1, "크기는 대화 기억의 상한에 들지 않는다")
        for n in 2...(AssistantWindowPositions.capacity + 5) {
            positions.remember(CGPoint(x: Double(n), y: 1), conversation: UUID(uuidString: String(format: "bcb50000-0000-4000-8000-%012d", n))!, display: "1")
        }
        #expect(positions.size(display: "1") == AssistantWindowSize(width: 500, height: 600), "오래된 대화를 잊어도 화면의 크기는 남는다")
    }

    @Test func sizesSurviveRestartThroughTheStoreAndReadOldSavesWithoutSizes() throws {
        let name = "dev.taskforcelabs.unittest.window-sizes"
        let defaults = try #require(UserDefaults(suiteName: name))
        defaults.removePersistentDomain(forName: name)
        defer { defaults.removePersistentDomain(forName: name) }
        let store = AssistantWindowPositionStore(defaults: defaults)
        var positions = store.load()
        positions.rememberSize(AssistantWindowSize(width: 512.5, height: 640), display: "69733248")
        positions.rememberSize(AssistantWindowSize(width: 400), display: "2")
        store.save(positions)
        let again = AssistantWindowPositionStore(defaults: defaults).load()
        #expect(again.size(display: "69733248") == AssistantWindowSize(width: 512.5, height: 640))
        #expect(again.size(display: "2") == AssistantWindowSize(width: 400, height: nil))
        // 크기가 생기기 전에 저장한 위치 기억은 그대로 읽힌다 (업데이트로 위치를 잃지 않는다)
        let conversation = UUID(uuidString: "bcb50000-0000-4000-8000-000000000009")!
        let old = #"{"entries":[{"conversation":"bcb50000-0000-4000-8000-000000000009","displays":{"1":[12.5,640]}}]}"#
        defaults.set(Data(old.utf8), forKey: AssistantWindowPositionStore.key)
        let migrated = AssistantWindowPositionStore(defaults: defaults).load()
        #expect(migrated.position(conversation: conversation, display: "1") == CGPoint(x: 12.5, y: 640))
        #expect(migrated.size(display: "1") == nil)
        // 계정이 떠나면 크기도 지운다
        store.save(positions)
        store.clear()
        #expect(AssistantWindowPositionStore(defaults: defaults).load().size(display: "2") == nil)
    }

    // MARK: 키보드 (⌥ + 화살표)

    @Test func optionArrowsMoveTheBottomRightCornerBySixteen() {
        #expect(G.keyboardResizeStep == 16)
        #expect(G.keyboardResizeDelta(.right) == CGPoint(x: 16, y: 0), "→ 넓게")
        #expect(G.keyboardResizeDelta(.left) == CGPoint(x: -16, y: 0), "← 좁게")
        #expect(G.keyboardResizeDelta(.down) == CGPoint(x: 0, y: -16), "↓ 아래 가장자리를 내려 길게")
        #expect(G.keyboardResizeDelta(.up) == CGPoint(x: 0, y: 16), "↑ 짧게")
        let grown = G.resized(frame, edge: .bottomRight, by: G.keyboardResizeDelta(.down), within: bounds, min: min, max: G.maxSize(visible: visible, railWidth: 44))
        #expect(grown == CGRect(x: 600, y: 244, width: 380, height: 456), "왼쪽 위는 그대로")
    }
}
