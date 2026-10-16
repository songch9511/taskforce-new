import Foundation
import SwiftUI
import Testing
import TaskforceKit
@testable import TaskforceUI

/// ConfirmCard (OA D4a, DS Molecules): 되돌리기 어려운 일 앞의 예 · 아니오 하나. 질문 카드 자리에 열린다 (모달이 아니다).
/// 주 동작은 하나 · Cancel은 secondary · `autoFocus`면 Cancel이 먼저 포커스 · 오류 한 줄은 이 카드의 유일한 빨강 · 두 번 눌러도 한 번
struct ConfirmCardTests {
    @Test func thereIsOnePrimaryAndCancelIsSecondary() {
        let buttons = ConfirmCard.buttons(confirmLabel: "Resume here", cancelLabel: "Cancel")
        #expect(buttons.count == 2)
        #expect(buttons.filter { $0.kind == .primary }.map(\.title) == ["Resume here"], "주 버튼은 하나")
        #expect(buttons.filter { $0.kind == .secondary }.map(\.title) == ["Cancel"])
        #expect(buttons.first?.kind == .primary, "주 동작이 먼저 · Cancel이 뒤 (DS ActionBar)")
        // 이름은 "Confirm" · "OK"가 아니라 일어나는 동사다: 문구는 부르는 쪽이 정한다 (기본 취소 말은 Cancel)
        #expect(ConfirmCard.defaultCancelLabel == "Cancel")
    }

    @Test func autoFocusPutsFocusOnCancelFirstAndWithoutItNothingTakesFocus() {
        #expect(ConfirmCard.initialFocus(autoFocus: true) == .cancel)
        #expect(ConfirmCard.initialFocus(autoFocus: false) == nil, "카드가 키를 가져가지 않는다 (입력칸에서 쓰던 글을 건드리지 않는다)")
    }

    /// Return은 **포커스가 카드 안에 있을 때만** 그 단추에 간다: 입력칸에서 글을 쓰다 누른 Return이 카드를 확정하지 않는다. Esc는 카드가 포커스를 가진 때 Cancel이다
    @Test func returnAndEscapeActOnlyWhileTheCardHasFocus() {
        #expect(ConfirmCard.returnTarget(focus: .confirm) == .confirm)
        #expect(ConfirmCard.returnTarget(focus: .cancel) == .cancel, "Cancel에 포커스가 있으면 Return도 Cancel (안전한 쪽)")
        #expect(ConfirmCard.returnTarget(focus: nil) == nil, "카드에 포커스가 없으면 Return은 카드의 일이 아니다")
        #expect(ConfirmCard.escapeCancels(focus: .confirm) && ConfirmCard.escapeCancels(focus: .cancel))
        #expect(!ConfirmCard.escapeCancels(focus: nil))
    }

    @Test func theErrorLineIsTheOnlyRedAndIsAnnouncedAsAnAlert() {
        #expect(ConfirmCard.errorColor == TFColor.statusOverdue)
        #expect(ConfirmCard.errorAnnouncement("Close the terminal session first") == "Close the terminal session first")
        #expect(ConfirmCard.errorAnnouncement(nil) == nil && ConfirmCard.errorAnnouncement("") == nil)
        #expect(ConfirmCard.accessibilityTraits(forError: true).contains(.isStaticText))
    }

    @Test func pressingTwiceActsOnce() {
        var gate = OneShot()
        let first = gate.claim()
        let second = gate.claim()
        let third = gate.claim()
        #expect(first, "처음은 동작한다")
        #expect(!second && !third, "두 번째부터는 동작하지 않는다")
        gate.reset()
        let afterReset = gate.claim()
        #expect(afterReset, "카드가 새 대상으로 바뀌면 다시 쓸 수 있다")
        // 바쁜 카드는 단추가 꺼진다
        #expect(ConfirmCard.buttonsDisabled(busy: true) && !ConfirmCard.buttonsDisabled(busy: false))
    }

    @Test func rowsAreLabelValuePairs() {
        let row = ConfirmCard.Row(label: "Closes", value: "#144 Confirm the refund window")
        #expect(row.accessibilityLabel == "Closes: #144 Confirm the refund window")
    }

    // MARK: LinkButton (DS Button `link`)

    @Test func theLinkIsAccentColoredAndFollowsTheSurroundingFont() throws {
        let source = try WorkComponentTests.source("LinkButton.swift")
        let code = WorkComponentTests.code(source)
        #expect(code.contains("TFColor.textAccent"), "`text/accent`")
        #expect(!code.contains(".font("), "주변 줄의 글꼴을 따른다 (글꼴을 정하지 않는다)")
        #expect(code.contains(".underline("), "호버 때 밑줄 (DS `.is-link:hover`)")
    }
}
