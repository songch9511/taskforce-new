import CoreGraphics
import Foundation
import Testing
@testable import TaskforceKit

/// 첫 Assistant 창의 위치 기준 (U2-44, U3-45): 열린 패널들(이슈 패널 + 그 왼쪽 40의 세션 패널)의 바깥 가장자리에서 왼쪽 12
struct AssistantPanelsFrameTests {
    typealias G = AssistantWindowGeometry

    /// 캡슐 레일: 화면 끝에서 6 안쪽의 44 폭
    let railFrame = CGRect(x: 1440 - 6 - 44, y: 400, width: 44, height: 319)
    /// 이슈 패널 380 (펼친 레일에서 12)
    let issuePanel = CGRect(x: 1440 - 6 - 44 - 12 - 380, y: 500, width: 380, height: 360)

    @Test func theSessionPanelSitsFortyLeftOfTheIssuePanel() {
        #expect(SessionPanelMetrics.panelGap == 40, "지금 보이는 간격 그대로 (미리보기 46은 U3 DZ 8)")
    }

    @Test func thePanelsFrameIsTheUnionOfTheOpenPanelWindows() throws {
        let sessionPanel = CGRect(x: issuePanel.minX - SessionPanelMetrics.panelGap - 380, y: issuePanel.maxY - 320, width: 380, height: 320)
        let union = try #require(G.panelsFrame([issuePanel, sessionPanel]))
        #expect(union.minX == sessionPanel.minX && union.maxX == issuePanel.maxX)
        #expect(union.maxY == issuePanel.maxY && union.minY == issuePanel.minY)
        #expect(G.panelsFrame([issuePanel]) == issuePanel)
        #expect(G.panelsFrame([]) == nil)
    }

    @Test func theFirstWindowOpensTwelveLeftOfTheSessionPanelWhenOneIsOpen() throws {
        let sessionPanel = CGRect(x: issuePanel.minX - SessionPanelMetrics.panelGap - 380, y: issuePanel.maxY - 320, width: 380, height: 320)
        let union = try #require(G.panelsFrame([issuePanel, sessionPanel]))
        let origin = G.firstTopLeft(panelFrame: union, railFrame: railFrame)
        #expect(origin.x == sessionPanel.minX - 12 - G.width)
        #expect(origin.y == issuePanel.maxY, "위는 패널과 같다")
    }

    @Test func withoutAPanelTheFirstWindowOpensTwelveLeftOfTheCapsuleRail() {
        let origin = G.firstTopLeft(panelFrame: nil, railFrame: railFrame)
        #expect(origin.x == railFrame.minX - 12 - G.width)
        #expect(origin.y == railFrame.maxY)
    }
}
