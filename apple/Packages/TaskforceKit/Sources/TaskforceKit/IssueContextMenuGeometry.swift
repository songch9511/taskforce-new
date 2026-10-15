import CoreGraphics
import Foundation

/// 범용 ContextMenu의 자리 (OA U2-15, DS ContextMenu: "The menu opens at the pointer or beside its row, never over it"). 좌표는 화면 좌표(아래가 0).
/// 메뉴는 눌린 행을 덮지 않는다: 행 아래 4pt, 아래 자리가 없으면 행 위 4pt. 가로는 포인터에서 시작해 화면 안으로 민다.
/// 하위 메뉴는 부모 왼쪽으로 4pt 겹쳐 열리고(Figma `30:1596`) 왼쪽에 자리가 없으면 오른쪽으로 연다
public enum ContextMenuGeometry {
    public static let gap: CGFloat = 4
    public static let submenuOverlap: CGFloat = 4
    /// 메뉴의 안쪽 여백 (하위 메뉴의 첫 줄을 부모 줄에 맞출 때)
    public static let inset: CGFloat = 5

    /// 화면 위 · 아래에 남기는 여백
    public static let screenMargin: CGFloat = 8

    /// 메뉴 창이 가질 수 있는 가장 큰 높이: 보이는 화면에서 위 · 아래 여백을 뺀 것. 줄이 이보다 길면 메뉴가 이 높이로 줄고 안에서 스크롤된다
    public static func maxHeight(visible: CGRect) -> CGFloat {
        max(0, visible.height - 2 * screenMargin)
    }

    /// 줄 전체의 높이(`natural`)가 화면보다 크면 `maxHeight`로 줄인 크기 (아니면 그대로)
    public static func limited(natural: CGSize, visible: CGRect) -> CGSize {
        CGSize(width: natural.width, height: min(natural.height, maxHeight(visible: visible)))
    }

    /// 메뉴 창의 자리. `row`: 눌린 행의 자리, `pointerX`: 포인터의 가로 위치
    public static func frame(size: CGSize, row: CGRect, pointerX: CGFloat, visible: CGRect) -> CGRect {
        let below = row.minY - gap - size.height
        let above = row.maxY + gap
        let fitsBelow = below >= visible.minY
        let fitsAbove = above + size.height <= visible.maxY
        var y: CGFloat
        if fitsBelow {
            y = below
        } else if fitsAbove {
            y = above
        } else {
            // 어느 쪽에도 안 들어가면 자리가 더 넓은 쪽에 두고 화면 안으로 민다
            let roomBelow = row.minY - visible.minY
            let roomAbove = visible.maxY - row.maxY
            y = roomBelow >= roomAbove ? below : above
        }
        y = max(visible.minY, min(y, visible.maxY - size.height))
        let x = max(visible.minX, min(pointerX, visible.maxX - size.width))
        return CGRect(x: x, y: y, width: size.width, height: size.height)
    }

    /// 하위 메뉴의 자리. `row`: 부모 메뉴 안에서 하위 메뉴를 연 줄의 자리 (화면 좌표)
    public static func submenuFrame(size: CGSize, parent: CGRect, row: CGRect, visible: CGRect) -> CGRect {
        var x = parent.minX - size.width + submenuOverlap
        if x < visible.minX { x = parent.maxX - submenuOverlap }
        x = max(visible.minX, min(x, visible.maxX - size.width))
        // 첫 줄이 부모의 그 줄에 맞게: 메뉴 위가 줄 위보다 안쪽 여백만큼 위
        var y = row.maxY + inset - size.height
        y = max(visible.minY, min(y, visible.maxY - size.height))
        return CGRect(x: x, y: y, width: size.width, height: size.height)
    }
}
