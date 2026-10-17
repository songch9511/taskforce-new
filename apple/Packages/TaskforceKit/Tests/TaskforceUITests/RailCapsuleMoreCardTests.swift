import CoreGraphics
import Testing
import TaskforceKit
@testable import TaskforceUI

/// OA U3 16.1 · DS EdgeRail "More open": ⋯ 카드의 치수와 자리 (순수 값)
@MainActor
struct RailCapsuleMoreCardTests {
    private let visible = CGRect(x: 0, y: 0, width: 1440, height: 900)

    @Test func theCardSitsTenPointsLeftOfTheThirdCapsuleWithItsBottomFlushWithTheCapsule() {
        // DS: `.tf-edge .tf-menu { right: calc(100% + 10px); bottom: 0 }`
        let capsule = CGRect(x: 1390, y: 300, width: 44, height: 112)
        let frame = RailMoreCardGeometry.frame(size: CGSize(width: 170, height: 76), capsule: capsule, visible: visible)
        #expect(frame.maxX == capsule.minX - 10, "오른쪽 끝은 캡슐 왼쪽 10pt")
        #expect(frame.minY == capsule.minY, "아래 끝은 셋째 캡슐의 아래 끝과 같다")
        #expect(frame.size == CGSize(width: 170, height: 76))
    }

    @Test func aCardThatWouldLeaveTheScreenIsPushedBackIn() {
        let lowCapsule = CGRect(x: 1390, y: -20, width: 44, height: 112)
        #expect(RailMoreCardGeometry.frame(size: CGSize(width: 170, height: 76), capsule: lowCapsule, visible: visible).minY == 0)
        let nearLeftEdge = CGRect(x: 100, y: 300, width: 44, height: 112)
        #expect(RailMoreCardGeometry.frame(size: CGSize(width: 170, height: 76), capsule: nearLeftEdge, visible: visible).minX == 0)
    }

    @Test func theCardNumbersAreTheDesignSystemOnes() {
        // DS `.tf-menu`: 최소 폭 170 · 안쪽 4 · 줄 안쪽 8/10
        #expect(RailMoreCard.minWidth == 170 && RailMoreCard.padding == 4)
        #expect(RailMoreCard.rowInset.top == 8 && RailMoreCard.rowInset.leading == 10 && RailMoreCard.rowInset.bottom == 8 && RailMoreCard.rowInset.trailing == 10)
        #expect(RailMoreCardGeometry.gap == 10)
    }

    @Test func theCardHasExactlyConnectionsAndSettingsWithTheirIcons() {
        let model = ContextMenuModel(items: [
            .init(id: "connections", icon: .connections, label: "Connections"), .init(id: "settings", icon: .settings, label: "Settings"),
        ])
        #expect(model.items.map(\.label) == ["Connections", "Settings"] && model.items.map(\.icon) == [.connections, .settings])
        // 줄 이동은 ContextMenuModel의 규칙이다: ↓은 첫 줄에서 시작하고 끝에서 돌지 않는다
        model.move(1)
        #expect(model.highlighted == 0)
        model.move(1)
        model.move(1)
        #expect(model.highlighted == 1)
        model.move(-1)
        #expect(model.highlighted == 0)
    }
}
