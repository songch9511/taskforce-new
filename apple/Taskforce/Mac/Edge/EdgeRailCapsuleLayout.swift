#if os(macOS)
import CoreGraphics
import Foundation
import TaskforceUI

/// 캡슐 레일의 자리 (OA U3, 디자인 EdgeRail · `bundle.css` `.tf-edge` · `.tf-capsule` · `.tf-rest-bar`). 창 좌표, 위가 0.
/// 레일은 화면 오른쪽 가운데에 검은 캡슐의 열로 떠 있다: ① Taskforce bell ② 살아 있는 세션 링(넷까지)과 New session `+` ③ Projects · Chats · More.
/// 그리기와 포인터 판정이 **같은 값**을 쓴다 (이 구조체의 frame들이 곧 판정이다). 모양은 바뀌지 않고 접힘 ↔ 펼침은 열 전체의 transform(.72배, 오른쪽 가운데 기준)뿐이다.
/// 숫자는 DS 미리보기를 헤드리스 브라우저로 재서 맞췄다: 캡슐 44 · 칸 32 · 칸 사이 2 · 안쪽 6 · 캡슐 사이 6, 세션 캡슐은 "넘치는 칸" 덩어리에 위 2가 더 있어
/// 링 n개의 접힌 높이 = 14 + 34n, 펼친 높이 = 46 + 34n (넷 + `+` = 182), 셋째 캡슐 112(칸 셋) · 146(칸 넷, 외부 세션 게이트), bell 캡슐 44. 열은 늘 창의 세로 가운데에서 자란다.
struct EdgeRailCapsuleLayout: Equatable {
    enum Mode: Equatable {
        /// 살아 있는 링 0 · 요청 0 · 펼침 아님: 막대 하나
        case rest
        /// bell 캡슐 + 링 캡슐(링 ≤ 3), 셋째 캡슐은 접혀 있다
        case compact
        case expanded
    }

    /// 어느 칸인가
    struct Hit: Equatable {
        var item: UUID?
        var control: EdgeShellModel.Control?
        var bell = false
        var plus = false
    }

    // MARK: 수치 (RailCapsuleMetrics)

    static let width = RailCapsuleMetrics.width
    static let inset = RailCapsuleMetrics.inset
    static let item = RailCapsuleMetrics.item
    static let gap = RailCapsuleMetrics.gap
    static let padding = RailCapsuleMetrics.padding
    static let room = RailCapsuleMetrics.shadowRoom
    static let compactScale = RailCapsuleMetrics.compactScale
    /// 링은 넷까지 (펼침), 접힘에서는 셋까지
    static let expandedRings = 4
    static let compactRings = 3
    /// "넘치는 칸" 덩어리(링 넷째 · `+`)의 위쪽 안쪽 2 (DS `.tf-capsule.is-sessions … padding-top: 2px`)
    static let moreInset: CGFloat = 2

    /// 창 폭: 그림자 여유 + 캡슐 + 화면 끝까지 6
    static let windowWidth = room + width + inset
    /// 가장 큰 열 (bell + 링 넷 · `+` + 셋째 캡슐)
    static var maxColumnHeight: CGFloat {
        bellHeight + inset + sessionsHeight(rings: expandedRings, expanded: true) + inset + thirdHeight
    }

    static var windowHeight: CGFloat { maxColumnHeight + 2 * room }
    static var windowSize: CGSize { CGSize(width: windowWidth, height: windowHeight) }

    static let bellHeight = padding * 2 + item
    /// 셋째 캡슐의 가장 큰 높이: Projects · Chats · On this Mac · More 넷 (외부 세션 게이트가 꺼져 있으면 셋이라 이보다 낮다 — 창은 늘 가장 큰 열이 들어가는 크기다)
    static let thirdHeight = padding * 2 + 4 * item + 3 * gap

    /// 세션 캡슐의 높이: 접힘은 링 n개(≤ 3), 펼침은 링 n개(≤ 4) + `+`. 링 0의 접힘은 캡슐이 없다 (0)
    static func sessionsHeight(rings: Int, expanded: Bool) -> CGFloat {
        let n = CGFloat(rings)
        if expanded { return 2 * padding + (n + 1) * item + n * gap + moreInset }
        return rings == 0 ? 0 : 2 * padding + n * item + (n - 1) * gap + gap + moreInset
    }

    // MARK: 입력

    let mode: Mode
    /// bell 캡슐이 있다 (요청이 있거나 대화가 열려 있다)
    let bell: Bool
    /// 접힘에서 보일 링 (노치: 앞의 셋까지, 살아 있는 종류만)
    let compactRingCount: Int
    /// 펼침에서 보일 링 (칸 전체, 넷까지)
    let ringCount: Int
    /// 셋째 캡슐의 칸 (Projects · Chats · More)
    var controls: [EdgeShellModel.Control] = EdgeShellModel.Control.allCases

    var expanded: Bool { mode == .expanded }

    var shownRings: Int {
        switch mode {
        case .rest: 0
        case .compact: min(compactRingCount, Self.compactRings)
        case .expanded: min(ringCount, Self.expandedRings)
        }
    }

    var showsSessions: Bool { mode == .expanded || (mode == .compact && shownRings > 0) }
    var showsThird: Bool { mode == .expanded }
    var showsBell: Bool { bell && mode != .rest }

    /// 열을 .72배로 줄이는 때 (접힘 · 쉼)
    var scale: CGFloat { mode == .expanded ? 1 : Self.compactScale }

    /// 줄이기의 기준점: 열의 오른쪽 가운데
    var anchor: CGPoint { CGPoint(x: Self.room + Self.width, y: Self.windowHeight / 2) }

    // MARK: 줄이기 전의 자리 (그리기)

    private var thirdControls: [EdgeShellModel.Control] { controls }

    private var thirdCapsuleHeight: CGFloat { Self.padding * 2 + CGFloat(thirdControls.count) * Self.item + CGFloat(max(thirdControls.count - 1, 0)) * Self.gap }

    private var sessionsCapsuleHeight: CGFloat { Self.sessionsHeight(rings: shownRings, expanded: expanded) }

    /// 열의 높이 (보이는 캡슐들 + 캡슐 사이)
    var columnHeight: CGFloat {
        var heights: [CGFloat] = []
        if showsBell { heights.append(Self.bellHeight) }
        if showsSessions { heights.append(sessionsCapsuleHeight) }
        if showsThird { heights.append(thirdCapsuleHeight) }
        return heights.reduce(0, +) + CGFloat(max(heights.count - 1, 0)) * Self.inset
    }

    private var columnTop: CGFloat { (Self.windowHeight - columnHeight) / 2 }

    private var capsuleX: CGFloat { Self.room }

    /// bell 캡슐 (줄이기 전)
    var bellCapsuleDrawn: CGRect? {
        showsBell ? CGRect(x: capsuleX, y: columnTop, width: Self.width, height: Self.bellHeight) : nil
    }

    /// 세션 캡슐 (줄이기 전)
    var sessionsCapsuleDrawn: CGRect? {
        guard showsSessions else { return nil }
        let top = columnTop + (showsBell ? Self.bellHeight + Self.inset : 0)
        return CGRect(x: capsuleX, y: top, width: Self.width, height: sessionsCapsuleHeight)
    }

    /// 셋째 캡슐 (줄이기 전)
    var thirdCapsuleDrawn: CGRect? {
        guard showsThird else { return nil }
        let top = columnTop + (showsBell ? Self.bellHeight + Self.inset : 0) + (showsSessions ? sessionsCapsuleHeight + Self.inset : 0)
        return CGRect(x: capsuleX, y: top, width: Self.width, height: thirdCapsuleHeight)
    }

    /// 칸의 x (캡슐 안 가운데)
    private var itemX: CGFloat { capsuleX + (Self.width - Self.item) / 2 }

    var bellItemDrawn: CGRect? {
        bellCapsuleDrawn.map { CGRect(x: itemX, y: $0.minY + Self.padding, width: Self.item, height: Self.item) }
    }

    /// 링 i의 자리 (줄이기 전). 셋까지는 칸 순서대로, 넷째는 "넘치는 칸" 덩어리 안이다
    func ringDrawn(_ index: Int) -> CGRect? {
        guard let capsule = sessionsCapsuleDrawn, index >= 0, index < shownRings else { return nil }
        let step = Self.item + Self.gap
        let y = index < 3 ? capsule.minY + Self.padding + CGFloat(index) * step : capsule.minY + Self.padding + 3 * step + Self.moreInset
        return CGRect(x: itemX, y: y, width: Self.item, height: Self.item)
    }

    /// New session `+` (줄이기 전, 펼침에만): 링 뒤
    var plusDrawn: CGRect? {
        guard expanded, let capsule = sessionsCapsuleDrawn else { return nil }
        let step = Self.item + Self.gap
        let n = shownRings
        let y = capsule.minY + Self.padding + CGFloat(min(n, 3)) * step + Self.moreInset + (n >= 4 ? step : 0)
        return CGRect(x: itemX, y: y, width: Self.item, height: Self.item)
    }

    func controlDrawn(_ control: EdgeShellModel.Control) -> CGRect? {
        guard let capsule = thirdCapsuleDrawn, let index = thirdControls.firstIndex(of: control) else { return nil }
        return CGRect(x: itemX, y: capsule.minY + Self.padding + CGFloat(index) * (Self.item + Self.gap), width: Self.item, height: Self.item)
    }

    /// 쉼 막대 (줄이기 전): 8 × 48, 반지름 4, 화면 끝에서 6 안쪽, 세로 가운데
    var restBarDrawn: CGRect? {
        guard mode == .rest else { return nil }
        return CGRect(
            x: Self.windowWidth - Self.inset - RailCapsuleMetrics.restBarWidth, y: (Self.windowHeight - RailCapsuleMetrics.restBarHeight) / 2,
            width: RailCapsuleMetrics.restBarWidth, height: RailCapsuleMetrics.restBarHeight
        )
    }

    // MARK: 줄인 뒤의 자리 (포인터 판정 · 툴팁)

    /// 줄이기(.72배, 오른쪽 가운데 기준)를 적용한 자리
    func scaled(_ rect: CGRect) -> CGRect {
        let s = scale
        guard s != 1 else { return rect }
        let a = anchor
        return CGRect(x: a.x + (rect.minX - a.x) * s, y: a.y + (rect.minY - a.y) * s, width: rect.width * s, height: rect.height * s)
    }

    var bellCapsuleFrame: CGRect? { bellCapsuleDrawn.map(scaled) }
    var sessionsCapsuleFrame: CGRect? { sessionsCapsuleDrawn.map(scaled) }
    var thirdCapsuleFrame: CGRect? { thirdCapsuleDrawn.map(scaled) }
    var bellFrame: CGRect? { bellItemDrawn.map(scaled) }
    var plusFrame: CGRect? { plusDrawn.map(scaled) }
    var restBarFrame: CGRect? { restBarDrawn.map(scaled) }

    func ringFrame(_ index: Int) -> CGRect? { ringDrawn(index).map(scaled) }
    func controlFrame(_ control: EdgeShellModel.Control) -> CGRect? { controlDrawn(control).map(scaled) }

    /// 포인터가 레일 모양 안인가: 캡슐 모양(둥근 사각형) 안뿐이다. 쉼에서는 막대 (오른쪽은 화면 끝까지: 막대와 화면 끝 사이 6pt는 다른 것의 자리가 아니다)
    func hitsRail(_ point: CGPoint) -> Bool {
        if mode == .rest {
            guard let bar = restBarFrame else { return false }
            return CGRect(x: bar.minX, y: bar.minY, width: Self.windowWidth - bar.minX, height: bar.height).contains(point)
        }
        for capsule in [bellCapsuleFrame, sessionsCapsuleFrame, thirdCapsuleFrame].compactMap({ $0 }) where Self.roundedContains(capsule, point) {
            return true
        }
        return false
    }

    /// 반지름이 폭의 절반인 캡슐 모양 안인가
    static func roundedContains(_ rect: CGRect, _ point: CGPoint) -> Bool {
        guard rect.contains(point) else { return false }
        let radius = min(rect.width, rect.height) / 2
        // 위아래 둥근 끝: 중심선에서 반지름 안
        if point.y < rect.minY + radius {
            let dx = point.x - rect.midX, dy = point.y - (rect.minY + radius)
            return dx * dx + dy * dy <= radius * radius
        }
        if point.y > rect.maxY - radius {
            let dx = point.x - rect.midX, dy = point.y - (rect.maxY - radius)
            return dx * dx + dy * dy <= radius * radius
        }
        return true
    }

    /// 포인터 아래의 칸 (칸은 원이다)
    func hit(_ point: CGPoint, slots: [RailEntry]) -> Hit {
        guard hitsRail(point), mode != .rest else { return Hit() }
        if let bell = bellFrame, Self.circleContains(bell, point) { return Hit(bell: true) }
        for (index, entry) in slots.enumerated() {
            if let frame = ringFrame(index), Self.circleContains(frame, point) { return Hit(item: entry.id) }
        }
        if let plus = plusFrame, Self.circleContains(plus, point) { return Hit(plus: true) }
        for control in controls {
            if let frame = controlFrame(control), Self.circleContains(frame, point) { return Hit(control: control) }
        }
        return Hit()
    }

    static func circleContains(_ rect: CGRect, _ point: CGPoint) -> Bool {
        let radius = rect.width / 2
        let dx = point.x - rect.midX, dy = point.y - rect.midY
        return dx * dx + dy * dy <= radius * radius
    }

    /// 화면 안에서 레일 창의 자리 (화면 좌표, 아래가 0): 오른쪽 끝에 붙고 세로는 `midY` 가운데
    static func windowFrame(screenMaxX: CGFloat, midY: CGFloat) -> CGRect {
        CGRect(x: screenMaxX - windowWidth, y: midY - windowHeight / 2, width: windowWidth, height: windowHeight)
    }

    /// 화면 좌표(아래가 0)의 펼친 레일 바깥 모양: Assistant 창이 피하는 자리의 왼쪽 가장자리 · 위 가장자리. 펼친 열이 가운데에서 자랄 때의 가장 큰 모양이다
    /// 셋째 캡슐은 가장 큰 모양(칸 넷: 외부 세션 게이트)으로 센다 — 창이 레일을 덜 피하는 쪽으로 틀리지 않게 (게이트가 꺼져 칸이 셋이면 34pt 넉넉할 뿐이다)
    static func expandedRailFrame(
        screenMaxX: CGFloat, midY: CGFloat, bell: Bool, rings: Int,
        controls: [EdgeShellModel.Control] = [.allWork, .chats, .onThisMac, .more]
    ) -> CGRect {
        let layout = EdgeRailCapsuleLayout(mode: .expanded, bell: bell, compactRingCount: 0, ringCount: rings, controls: controls)
        let window = windowFrame(screenMaxX: screenMaxX, midY: midY)
        let top = layout.bellCapsuleDrawn?.minY ?? layout.sessionsCapsuleDrawn?.minY ?? 0
        let bottom = layout.thirdCapsuleDrawn?.maxY ?? 0
        return CGRect(x: window.minX + room, y: window.maxY - bottom, width: width, height: bottom - top)
    }
}
#endif
