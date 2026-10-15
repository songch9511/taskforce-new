import CoreGraphics
import Foundation
import Testing
@testable import TaskforceKit

/// 메뉴의 자리 (U2-15, DS ContextMenu "at the pointer or beside its row, never over it"). 좌표는 화면 좌표(아래가 0)
struct IssueContextMenuGeometryTests {
    typealias G = ContextMenuGeometry

    let visible = CGRect(x: 0, y: 0, width: 1440, height: 875)
    let size = CGSize(width: 240, height: 109)
    /// 눌린 행: 패널 안 (x 1000–1364), 위 y 650–704
    let row = CGRect(x: 1000, y: 650, width: 364, height: 54)

    @Test func theMenuOpensFourBelowTheRowWithoutCoveringIt() {
        let frame = G.frame(size: size, row: row, pointerX: 1100, visible: visible)
        #expect(frame.maxY == row.minY - 4, "행 아래 4")
        #expect(!frame.intersects(row))
        #expect(frame.size == size)
    }

    @Test func theMenuOpensAboveWhenThereIsNoRoomBelow() {
        let low = CGRect(x: 1000, y: 40, width: 364, height: 54)
        let frame = G.frame(size: size, row: low, pointerX: 1100, visible: visible)
        #expect(frame.minY == low.maxY + 4, "아래 자리가 없으면 위")
        #expect(!frame.intersects(low))
    }

    @Test func horizontallyItStartsAtThePointerAndIsPushedInsideTheScreen() {
        #expect(G.frame(size: size, row: row, pointerX: 1100, visible: visible).minX == 1100)
        #expect(G.frame(size: size, row: row, pointerX: 1400, visible: visible).maxX == visible.maxX, "오른쪽 끝에서는 안으로 민다")
        #expect(G.frame(size: size, row: row, pointerX: -50, visible: visible).minX == visible.minX)
    }

    @Test func whenNeitherSideFitsItPicksTheRoomierSideAndStaysInsideTheScreen() {
        let tall = CGSize(width: 240, height: 700)
        let middle = CGRect(x: 1000, y: 400, width: 364, height: 54)
        let frame = G.frame(size: tall, row: middle, pointerX: 1100, visible: visible)
        #expect(frame.minY >= visible.minY && frame.maxY <= visible.maxY)
    }

    @Test func theSubmenuOpensLeftOfTheParentOverlappingFour() {
        let parent = CGRect(x: 1100, y: 500, width: 240, height: 79)
        let rowInParent = CGRect(x: 1105, y: 540, width: 230, height: 34)
        let sub = G.submenuFrame(size: CGSize(width: 230, height: 199), parent: parent, row: rowInParent, visible: visible)
        #expect(sub.maxX == parent.minX + 4, "부모 왼쪽으로 4 겹친다")
        #expect(sub.maxY == rowInParent.maxY + 5, "첫 줄이 부모의 그 행에 맞는다 (안쪽 5)")
    }

    @Test func theSubmenuFlipsRightWhenThereIsNoRoomOnTheLeft() {
        let parent = CGRect(x: 100, y: 500, width: 240, height: 79)
        let rowInParent = CGRect(x: 105, y: 540, width: 230, height: 34)
        let sub = G.submenuFrame(size: CGSize(width: 230, height: 199), parent: parent, row: rowInParent, visible: visible)
        #expect(sub.minX == parent.maxX - 4)
        #expect(sub.maxX <= visible.maxX)
    }

    @Test func theSubmenuStaysInsideTheScreenVertically() {
        let parent = CGRect(x: 1100, y: 60, width: 240, height: 79)
        let rowInParent = CGRect(x: 1105, y: 70, width: 230, height: 34)
        let sub = G.submenuFrame(size: CGSize(width: 230, height: 199), parent: parent, row: rowInParent, visible: visible)
        #expect(sub.minY >= visible.minY)
    }
}
