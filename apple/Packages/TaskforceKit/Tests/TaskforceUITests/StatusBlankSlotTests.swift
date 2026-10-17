import AppKit
import SwiftUI
import Testing
import TaskforceKit
@testable import TaskforceUI

/// OA U3-46 · 11.2: 목록 · 상태 줄 · 요약 줄에서 In Progress에는 표시가 없다 (빈 자리 16, 접근성 이름은 "In Progress"를 남긴다).
/// 게이트 밖 (Release `WorkRow` · All work 위 요약 · iPhone · 런처 `TaskStatusMark`)은 그대로다
@MainActor
struct StatusBlankSlotTests {
    private func alphaSum<V: View>(_ view: V, side: CGFloat) -> Int {
        let renderer = ImageRenderer(content: view.frame(width: side, height: side).environment(\.colorScheme, .light))
        renderer.scale = 2
        guard let image = renderer.cgImage else { return -1 }
        var data = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let context = CGContext(
            data: &data, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
        context?.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return stride(from: 3, to: data.count, by: 4).reduce(0) { $0 + Int(data[$1]) }
    }

    @Test func onlyTheListedInProgressMarkIsBlank() {
        #expect(!StatusMark.drawsMark(.inProgress, blankInProgress: true))
        #expect(StatusMark.drawsMark(.inProgress, blankInProgress: false), "Status 속성 · 필터는 세 모양을 다 보인다")
        #expect(StatusMark.drawsMark(.toDo, blankInProgress: true) && StatusMark.drawsMark(.done, blankInProgress: true), "To Do · Done은 표시를 지킨다")
    }

    @Test func theBlankSlotDrawsNothingButKeepsTheSixteenPointFrame() {
        #expect(alphaSum(StatusMark(.inProgress, blankInProgress: true), side: 16) == 0, "표시 0")
        #expect(StatusMark.Size.md.points == 16, "자리 16: 제목 정렬을 지킨다")
        // 색 토큰은 컴파일된 카탈로그에서만 그려진다 (`swift test`는 카탈로그를 복사만 한다): 모양 비교는 Xcode 빌드(CI `TF_REQUIRE_COMPILED_CATALOG`)에서 돈다
        guard TokenCatalog.isCompiled else { return }
        #expect(alphaSum(StatusMark(.inProgress), side: 16) > 0)
        #expect(alphaSum(StatusMark(.toDo, blankInProgress: true), side: 16) > 0 && alphaSum(StatusMark(.done, blankInProgress: true), side: 16) > 0)
    }

    @Test func accessibilityNamesStillSayInProgress() {
        let row = IssueRowContent(id: UUID(), title: "Wire rings", state: .inProgress, activity: nil, due: nil, urgent: false, overdue: false)
        #expect(row.accessibilityLabel == "Wire rings — In Progress")
        #expect(StatusMark.State.inProgress.label == "In Progress")
        let summaryRow = ReturnSummaryRow(id: UUID(), title: "Pricing", progress: .inProgress, needsAnswer: false, detail: "Result ready")
        #expect(ReturnSummary.accessibilityLabel(summaryRow) == "In Progress, Pricing, Result ready")
    }

    @Test func theChangesOnlySummaryUsesTheThreeStateMarkAndTheOldCardKeepsItsOwn() {
        #expect(ReturnSummary.changesMark(.inProgress) == .inProgress && ReturnSummary.changesMark(.toDo) == .toDo && ReturnSummary.changesMark(.done) == .done)
        #expect(ReturnSummary.changesMark(.unknown) == nil && ReturnSummary.changesMark(nil) == nil)
        #expect(ReturnSummary.mark(.inProgress) == .inProgress, "옛 카드는 4종 TaskStatusMark 그대로")
    }
}
