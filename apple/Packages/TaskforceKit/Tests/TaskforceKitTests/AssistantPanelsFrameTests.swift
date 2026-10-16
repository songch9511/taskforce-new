import CoreGraphics
import Foundation
import Testing
@testable import TaskforceKit

/// 첫 Assistant 창의 위치 기준 (U2-44): 열린 패널들(세션 패널 · 펼친 탭 36 포함)의 바깥 가장자리에서 왼쪽 12
struct AssistantPanelsFrameTests {
    typealias G = AssistantWindowGeometry

    let railFrame = CGRect(x: 1440 - 44, y: 400, width: 44, height: 319)
    /// 이슈 패널 380 (펼친 레일에서 12)
    let issuePanel = CGRect(x: 1440 - 44 - 12 - 380, y: 500, width: 380, height: 360)

    @Test func theExpandedTabIsThirtySixWide() {
        #expect(SessionTabMetrics.expandedWidth == 36)
        #expect(SessionTabMetrics.collapsedWidth == 24)
    }

    @Test func thePanelsFrameIsTheUnionOfTheOpenPanelWindows() throws {
        let issueWindow = CGRect(x: issuePanel.minX - 36, y: issuePanel.minY, width: issuePanel.width + 36, height: issuePanel.height)
        let sessionPanel = CGRect(x: issueWindow.minX - 40 - 380, y: issuePanel.maxY - 320, width: 380, height: 320)
        let union = try #require(G.panelsFrame([issueWindow, sessionPanel]))
        #expect(union.minX == sessionPanel.minX && union.maxX == issuePanel.maxX)
        #expect(union.maxY == issuePanel.maxY && union.minY == issuePanel.minY)
        #expect(G.panelsFrame([issueWindow]) == issueWindow)
        #expect(G.panelsFrame([]) == nil)
    }

    @Test func theFirstWindowOpensTwelveLeftOfTheSessionPanelWhenOneIsOpen() throws {
        let issueWindow = CGRect(x: issuePanel.minX - 36, y: issuePanel.minY, width: issuePanel.width + 36, height: issuePanel.height)
        let sessionPanel = CGRect(x: issueWindow.minX - 40 - 380, y: issuePanel.maxY - 320, width: 380, height: 320)
        let union = try #require(G.panelsFrame([issueWindow, sessionPanel]))
        let origin = G.firstTopLeft(panelFrame: union, railFrame: railFrame)
        #expect(origin.x == sessionPanel.minX - 12 - G.width)
        #expect(origin.y == issuePanel.maxY, "위는 패널과 같다")
    }

    @Test func theTabCountsOnceWhetherItIsInTheWindowOrTheInset() throws {
        // 탭이 창 안에 있으면(창 프레임이 36 넓다) 안쪽 여백은 0, 창 밖에서 따로 재면 36 — 어느 쪽이든 같은 자리다
        let withTab = CGRect(x: issuePanel.minX - 36, y: issuePanel.minY, width: issuePanel.width + 36, height: issuePanel.height)
        let viaWindow = G.firstTopLeft(panelFrame: withTab, railFrame: railFrame)
        let viaInset = G.firstTopLeft(panelFrame: issuePanel, railFrame: railFrame, panelOuterInset: SessionTabMetrics.expandedWidth)
        #expect(viaWindow == viaInset)
    }
}
