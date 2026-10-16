import AppKit
import Carbon.HIToolbox
import Foundation
import Testing
@testable import Taskforce
@testable import TaskforceKit
@testable import TaskforceUI

/// Review 페이지(S4)의 모델 · 키 · 쓰기. 진짜 `NowStore` · `APIClient`를 가짜 네트워크 위에서 부르고(`ReviewHarness`), 셸 모델은 `NowStore.sections`를 그대로 옮겨 받는다
@MainActor
struct ReviewRig {
    let harness: ReviewHarness
    let desk: ReviewDesk
    let shell: EdgeShellModel

    static func make(reviews: Int = 3, open: Bool = true) async throws -> ReviewRig {
        let harness = try await ReviewHarness.make(reviews: reviews, open: open ? 1 : 0)
        let desk = ReviewDesk(now: harness.store, scope: harness.scope)
        let shell = EdgeShellModel(schedule: { _, _ in EdgeTimer() }, review: desk)
        await harness.store.load()
        let rig = ReviewRig(harness: harness, desk: desk, shell: shell)
        rig.sync()
        return rig
    }

    /// 앱의 `followWork`처럼 목록을 셸에 옮긴다
    func sync() {
        let store = harness.store
        shell.update(EdgeWorkSnapshot(
            sections: store.sections, working: [], stopping: [], load: WorkLoad.from(refresh: store.refreshState, hasList: store.response != nil),
            doneSince: store.doneTodaySince, canConnect: false
        ))
    }

    /// 사용자가 고른 답 하나를 보내고 끝나기를 기다린다
    func answered(_ answer: ReviewAnswer, _ id: UUID) async throws -> ReviewWriteResult {
        let task = try #require(shell.answer(answer, for: id))
        return await task.value
    }

    var ids: [UUID] { shell.reviewQueue.ids }
    func id(_ n: Int) -> UUID { ReviewHarness.id(n) }
}

struct S4GateTests {
    // MARK: 플래그

    /// 테스트 호스트에는 `-TF_S4`가 없다: 기본은 꺼짐 (Release도 늘 꺼짐)
    @Test func theFlagIsOffByDefault() {
        #expect(!ProcessInfo.processInfo.arguments.contains("-\(S4Flag.key)"))
        #expect(!S4Flag.isEnabled())
        #expect(S4Flag.key == "TF_S4")
    }

    /// 저장된 defaults로는 켜지지 않는다: 인자 영역만 (테스트는 전용 suite를 넘긴다)
    @Test func theFlagFollowsAnInjectedSuiteNotTheStoredDefaults() throws {
        let store = try TestDefaults()
        defer { store.cleanup() }
        #expect(!S4Flag.isEnabled(store.defaults))
        store.defaults.set(true, forKey: S4Flag.key)
        #expect(S4Flag.isEnabled(store.defaults))
        store.defaults.set(false, forKey: S4Flag.key)
        #expect(!S4Flag.isEnabled(store.defaults))
    }

    /// 다른 축이다: Edge 셸 · S3b 플래그가 S4를 켜지 않는다
    @Test func theOtherFlagsDoNotTurnS4On() throws {
        let store = try TestDefaults()
        defer { store.cleanup() }
        store.defaults.set(true, forKey: EdgeShellFlag.key)
        store.defaults.set(true, forKey: S3bFlag.key)
        #expect(EdgeShellFlag.isEnabled(store.defaults) && S3bFlag.isEnabled(store.defaults) && !S4Flag.isEnabled(store.defaults))
    }

    // MARK: 실제 생성 경로 (`AppRuntime.reviewDesk`가 부르는 같은 함수)

    @MainActor
    @Test func theCreationPathMakesNoDeskUnlessOn() async throws {
        let harness = try await ReviewHarness.make()
        // 기본 · off
        #expect(AppRuntime.makeReviewDesk(now: harness.store, scope: harness.scope, s4: false) == nil)
        #expect(AppRuntime.reviewDesk(now: harness.store, scope: harness.scope) == nil, "테스트 실행에는 인자가 없다: 실제 경로는 기본 꺼짐")
        // on이어도 목록이나 계정 경계가 없으면 만들지 않는다
        #expect(AppRuntime.makeReviewDesk(now: nil, scope: harness.scope, s4: true) == nil)
        #expect(AppRuntime.makeReviewDesk(now: harness.store, scope: nil, s4: true) == nil)
        // on
        #expect(AppRuntime.makeReviewDesk(now: harness.store, scope: harness.scope, s4: true) != nil)
    }

    /// off: 셸에 Review가 없다. Review 입구(⌘1 · 링 · 단계 · 답)는 모두 아무것도 하지 않거나 지금 동작 그대로다
    @MainActor
    @Test func offTheShellHasNoReviewAndTheRingStillOpensAllWork() async throws {
        let harness = try await ReviewHarness.make()
        await harness.store.load()
        let shell = EdgeShellModel(schedule: { _, _ in EdgeTimer() })
        shell.update(EdgeWorkSnapshot(sections: harness.store.sections, working: [], stopping: [], load: .loaded(problem: nil), doneSince: nil, canConnect: false))
        #expect(shell.review == nil)

        shell.openNewestReview()
        shell.openReview(itemID: ReviewHarness.id(2))
        shell.stepReview(1)
        #expect(!shell.panelOpen && shell.view == .allWork && shell.reviewID == nil, "Review 입구가 없다")
        #expect(shell.answer(.confirm, for: ReviewHarness.id(1)) == nil)

        // 레일의 Needs-you 링: 지금처럼 All work에서 그 행을 표시한다
        let entry = try #require(shell.slots.first { $0.kind == .needsYou })
        shell.openRailEntry(entry)
        #expect(shell.panelOpen && shell.view == .allWork && shell.currentID == entry.id && shell.railCurrentID == entry.id)
        #expect(await harness.server.writeCount() == 0)
    }

    /// on: 같은 입구가 Review 페이지를 연다 (열기는 쓰기가 아니다)
    @MainActor
    @Test func onTheRingAndNewestOpenTheReviewPage() async throws {
        let rig = try await ReviewRig.make()
        let entry = try #require(rig.shell.slots.first { $0.id == rig.id(2) && $0.kind == .needsYou })
        rig.shell.openRailEntry(entry)
        #expect(rig.shell.panelOpen && rig.shell.view == .review && rig.shell.shownReview?.id == rig.id(2) && rig.shell.railCurrentID == rig.id(2))
        // 일을 누른 링(needs you가 아닌 것)은 지금처럼
        let open = RailEntry(id: rig.id(101), title: "Open 1", kind: .running, state: .inProgress)
        rig.shell.openRailEntry(open)
        #expect(rig.shell.view == .allWork && rig.shell.currentID == rig.id(101))
        #expect(await rig.harness.server.writeCount() == 0, "링을 눌러 여는 것은 어떤 답도 아니다")
    }

    // MARK: 패널 키 (실제 컨트롤러의 `handleKey`)

    /// Chats가 켜진 셸 (DEBUG에서 셸이 켜진 지금의 구성): ⌘3 · ⌘N이 Chats로 간다. 견본 대화 서버의 실제 `ChatRuntime`을 둔다 (네트워크 · 계정 없음).
    /// `chat: nil`은 이제 "Chats가 없는 셸"(Release 표면)이다 — 그 구성의 키는 `ReleaseSurfacesTests`가 실제 컨트롤러로 본다
    @MainActor
    static func controller(review: ReviewDesk?) -> EdgeShellController {
        EdgeShellController(launcher: LauncherModel(configurationError: "test"), chat: ChatRuntime(gateway: SampleChatGateway()), review: review)
    }

    static func key(_ characters: String, code: Int, flags: NSEvent.ModifierFlags = [], isRepeat: Bool = false) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil, characters: characters,
            charactersIgnoringModifiers: characters, isARepeat: isRepeat, keyCode: UInt16(code)
        )!
    }

    @MainActor
    @Test func offTheReviewKeysPassThroughAndTheExistingKeysStillWork() async throws {
        let controller = Self.controller(review: nil)
        #expect(controller.shell.review == nil)
        #expect(!controller.handleKey(Self.key("1", code: kVK_ANSI_1, flags: .command)), "⌘1은 연결이 없다: 지나간다")
        #expect(!controller.handleKey(Self.key("1", code: kVK_ANSI_1)))
        #expect(!controller.handleKey(Self.key("\u{F702}", code: kVK_LeftArrow, flags: [.numericPad, .function])))
        // 지금 키는 그대로
        #expect(controller.handleKey(Self.key("2", code: kVK_ANSI_2, flags: .command)) && controller.shell.view == .allWork && controller.shell.panelOpen)
        #expect(controller.handleKey(Self.key("3", code: kVK_ANSI_3, flags: .command)) && controller.shell.view == .chats)
        #expect(controller.handleKey(Self.key("\u{1B}", code: kVK_Escape)) && !controller.shell.panelOpen)
    }

    @MainActor
    @Test func onCommandOneOpensTheNewestAndTheArrowsStepButOnlyOnTheReviewPage() async throws {
        let rig = try await ReviewRig.make()
        let controller = Self.controller(review: rig.desk)
        controller.shell.update(EdgeWorkSnapshot(sections: rig.harness.store.sections, working: [], stopping: [], load: .loaded(problem: nil), doneSince: nil, canConnect: false))

        // Review 페이지가 아닐 때 ← →는 지나간다 (All work의 검색칸 등이 쓴다)
        controller.shell.openAllWork()
        #expect(!controller.handleKey(Self.key("\u{F702}", code: kVK_LeftArrow, flags: [.numericPad, .function])))
        #expect(!controller.handleKey(Self.key("1", code: kVK_ANSI_1)))

        #expect(controller.handleKey(Self.key("1", code: kVK_ANSI_1, flags: .command)))
        #expect(controller.shell.view == .review && controller.shell.shownReview?.id == rig.id(3), "⌘1 = 가장 새 항목")
        #expect(controller.handleKey(Self.key("\u{F702}", code: kVK_LeftArrow, flags: [.numericPad, .function])))
        #expect(controller.shell.shownReview?.id == rig.id(2))
        #expect(controller.handleKey(Self.key("\u{F703}", code: kVK_RightArrow, flags: [.numericPad, .function])))
        #expect(controller.shell.shownReview?.id == rig.id(3))
        // 기존 ⌘2 · ⌘3 · ⌘N과 충돌하지 않는다
        #expect(controller.handleKey(Self.key("2", code: kVK_ANSI_2, flags: .command)) && controller.shell.view == .allWork)
        #expect(controller.handleKey(Self.key("3", code: kVK_ANSI_3, flags: .command)) && controller.shell.view == .chats)
        #expect(await rig.harness.server.writeCount() == 0, "열기 · 탐색 · 키는 어떤 답도 아니다")
    }

    @MainActor
    @Test func numberKeysAnswerOnlyOutsideTextEditingAndOnlyOnce() async throws {
        let rig = try await ReviewRig.make()
        let controller = Self.controller(review: rig.desk)
        controller.shell.update(EdgeWorkSnapshot(sections: rig.harness.store.sections, working: [], stopping: [], load: .loaded(problem: nil), doneSince: nil, canConnect: false))
        _ = controller.handleKey(Self.key("1", code: kVK_ANSI_1, flags: .command))
        #expect(controller.shell.shownReview?.id == rig.id(3))

        // 3은 v1에 없는 세 번째 행동: 지나간다. 수식키가 붙은 번호도 지나간다
        #expect(!controller.handleKey(Self.key("3", code: kVK_ANSI_3)))
        #expect(!controller.handleKey(Self.key("1", code: kVK_ANSI_1, flags: .option)))
        #expect(!controller.handleKey(Self.key("1", code: kVK_ANSI_1, flags: .control)))

        // 텍스트 편집 중: 번호는 글자다
        let field = NSTextView(frame: NSRect(x: 0, y: 0, width: 100, height: 20))
        controller.panel.panel.contentView?.addSubview(field)
        #expect(controller.panel.panel.makeFirstResponder(field))
        #expect(!controller.handleKey(Self.key("1", code: kVK_ANSI_1)), "편집 중인 텍스트가 먼저")
        #expect(!controller.handleKey(Self.key("\u{F702}", code: kVK_LeftArrow, flags: [.numericPad, .function])), "← →도 커서 이동에 쓴다")
        #expect(await rig.harness.server.arrived(rig.id(3)) == 0)
        field.removeFromSuperview()
        _ = controller.panel.panel.makeFirstResponder(nil)

        // 편집 밖: 1 = Confirm. 누르고 있어 반복된 키는 먹기만 한다
        #expect(controller.handleKey(Self.key("1", code: kVK_ANSI_1)))
        #expect(controller.handleKey(Self.key("1", code: kVK_ANSI_1, isRepeat: true)))
        #expect(controller.handleKey(Self.key("1", code: kVK_ANSI_1, isRepeat: true)))
        #expect(await rig.harness.wait { await rig.harness.server.writeCount("confirm", for: rig.id(3)) == 1 })
        try await Task.sleep(for: .milliseconds(60))
        #expect(await rig.harness.server.arrived(rig.id(3)) == 1, "한 번의 선택은 한 번의 요청")
        #expect(await rig.harness.server.writeCount() == 1)
    }

    @MainActor
    @Test func aSheetOrAnOpenMenuKeepsTheKeysOut() async throws {
        let rig = try await ReviewRig.make()
        let controller = Self.controller(review: rig.desk)
        controller.shell.update(EdgeWorkSnapshot(sections: rig.harness.store.sections, working: [], stopping: [], load: .loaded(problem: nil), doneSince: nil, canConnect: false))
        _ = controller.handleKey(Self.key("1", code: kVK_ANSI_1, flags: .command))
        controller.shell.setMenuOpen(true)
        #expect(!controller.handleKey(Self.key("1", code: kVK_ANSI_1)) && !controller.handleKey(Self.key("\u{F703}", code: kVK_RightArrow, flags: [.numericPad, .function])))
        controller.shell.setMenuOpen(false)
        #expect(await rig.harness.server.arrived(rig.id(3)) == 0)
    }

    /// Codex b52443b 검토 C: ⌘1도 텍스트 편집(입력칸 · IME 조합) · 메뉴 · 시트 밖에서만 듣는다. 기존 ⌘2 · ⌘3 · ⌘N은 입력칸에서도 그대로다
    @MainActor
    @Test func commandOneIsHeardOnlyOutsideTextEditingMenusAndSheets() async throws {
        let rig = try await ReviewRig.make()
        let controller = Self.controller(review: rig.desk)
        controller.shell.update(EdgeWorkSnapshot(sections: rig.harness.store.sections, working: [], stopping: [], load: .loaded(problem: nil), doneSince: nil, canConnect: false))
        controller.shell.openAllWork()
        let commandOne = Self.key("1", code: kVK_ANSI_1, flags: .command)
        let window = controller.panel.panel

        // 편집할 수 있는 텍스트가 첫 응답자: ⌘1은 지나가고 화면은 그대로
        let field = NSTextView(frame: NSRect(x: 0, y: 0, width: 100, height: 20))
        window.contentView?.addSubview(field)
        #expect(window.makeFirstResponder(field))
        #expect(!controller.handleKey(commandOne))
        #expect(controller.shell.view == .allWork && controller.shell.reviewPresentation == 0)
        // 기존 키는 입력칸에서도 그대로 (이 PR이 바꾸지 않는다)
        #expect(controller.handleKey(Self.key("3", code: kVK_ANSI_3, flags: .command)) && controller.shell.view == .chats)
        #expect(controller.handleKey(Self.key("2", code: kVK_ANSI_2, flags: .command)) && controller.shell.view == .allWork)
        #expect(controller.handleKey(Self.key("n", code: kVK_ANSI_N, flags: .command)) && controller.shell.view == .chats)
        controller.shell.openAllWork()
        field.removeFromSuperview()
        _ = window.makeFirstResponder(nil)

        // IME 조합 중인 입력
        let composing = MarkedTextView(frame: NSRect(x: 0, y: 0, width: 100, height: 20))
        composing.marked = true
        window.contentView?.addSubview(composing)
        #expect(window.makeFirstResponder(composing))
        #expect(!controller.handleKey(commandOne) && controller.shell.view == .allWork)
        composing.marked = false
        #expect(controller.handleKey(commandOne) && controller.shell.view == .review, "조합이 아닌 입력이면 ⌘1이 듣는다")
        composing.removeFromSuperview()
        _ = window.makeFirstResponder(nil)
        controller.shell.openAllWork()

        // 열린 메뉴
        controller.shell.setMenuOpen(true)
        #expect(!controller.handleKey(commandOne) && controller.shell.view == .allWork)
        controller.shell.setMenuOpen(false)

        // 시트
        let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 80, height: 60), styleMask: [.titled], backing: .buffered, defer: true)
        window.beginSheet(sheet, completionHandler: nil)
        try #require(window.attachedSheet != nil, "시트가 붙어야 이 시험이 뜻이 있다")
        #expect(!controller.handleKey(commandOne) && controller.shell.view == .allWork)
        window.endSheet(sheet)

        // 편집 밖: 가장 새 항목
        #expect(controller.handleKey(commandOne))
        #expect(controller.shell.view == .review && controller.shell.shownReview?.id == rig.id(3))
        #expect(await rig.harness.server.writeCount() == 0)
    }

    @MainActor
    @Test func theKeyTableMatchesTheContract() {
        #expect(EdgeKeyCommand.of(keyCode: kVK_ANSI_1, flags: .command) == .review)
        #expect(EdgeKeyCommand.of(keyCode: kVK_ANSI_1, flags: []) == nil)
        #expect(EdgeKeyCommand.of(keyCode: kVK_ANSI_1, flags: [.command, .shift]) == nil)
        #expect(EdgeKeyCommand.of(keyCode: kVK_ANSI_1, flags: [.command, .option]) == nil)
        let arrows: NSEvent.ModifierFlags = [.numericPad, .function]
        #expect(EdgeReviewKeys.of(keyCode: kVK_LeftArrow, characters: "\u{F702}", flags: arrows) == .previous)
        #expect(EdgeReviewKeys.of(keyCode: kVK_RightArrow, characters: "\u{F703}", flags: arrows) == .next)
        #expect(EdgeReviewKeys.of(keyCode: kVK_LeftArrow, characters: "\u{F702}", flags: arrows.union(.shift)) == nil, "Shift + 방향키는 선택 확장에 쓴다")
        #expect(EdgeReviewKeys.of(keyCode: kVK_RightArrow, characters: "\u{F703}", flags: arrows.union(.command)) == nil)
        #expect(EdgeReviewKeys.of(keyCode: kVK_ANSI_1, characters: "1", flags: []) == .answer(.confirm))
        #expect(EdgeReviewKeys.of(keyCode: kVK_ANSI_2, characters: "2", flags: []) == .answer(.dismiss))
        #expect(EdgeReviewKeys.of(kVK_ANSI_Keypad1, "1", .numericPad) == .answer(.confirm), "키패드 1")
        #expect(EdgeReviewKeys.of(keyCode: kVK_ANSI_1, characters: "1", flags: .shift) == .answer(.confirm), "1에 Shift가 필요한 배열(AZERTY)")
        #expect(EdgeReviewKeys.of(keyCode: kVK_ANSI_1, characters: "!", flags: .shift) == nil)
        for number in ["0", "3", "4", "9"] { #expect(EdgeReviewKeys.of(keyCode: kVK_ANSI_3, characters: number, flags: []) == nil, "세 번째 행동은 없다") }
        for flags: NSEvent.ModifierFlags in [.command, .option, .control] { #expect(EdgeReviewKeys.of(keyCode: kVK_ANSI_1, characters: "1", flags: flags) == nil) }
        #expect(EdgeReviewKeys.of(keyCode: kVK_ANSI_A, characters: "a", flags: []) == nil)
    }

    final class MarkedTextView: NSView, @preconcurrency NSTextInputClient {
        var marked = false
        override var acceptsFirstResponder: Bool { true }
        func insertText(_ string: Any, replacementRange: NSRange) {}
        func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {}
        func unmarkText() {}
        func selectedRange() -> NSRange { NSRange(location: NSNotFound, length: 0) }
        func markedRange() -> NSRange { NSRange(location: NSNotFound, length: 0) }
        func hasMarkedText() -> Bool { marked }
        func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? { nil }
        func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }
        func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect { .zero }
        func characterIndex(for point: NSPoint) -> Int { 0 }
    }

    @MainActor
    @Test func textEditingIsAnEditableTextAFieldEditorOrAnIMEComposition() {
        let editable = NSTextView()
        editable.isEditable = true
        let readOnly = NSTextView()
        readOnly.isEditable = false
        readOnly.isSelectable = true
        let fieldEditor = NSTextView()
        fieldEditor.isFieldEditor = true
        fieldEditor.isEditable = false
        let composing = MarkedTextView()
        composing.marked = true
        let idle = MarkedTextView()
        #expect(EdgeReviewKeys.isTextEditing(editable) && EdgeReviewKeys.isTextEditing(fieldEditor) && EdgeReviewKeys.isTextEditing(composing))
        #expect(!EdgeReviewKeys.isTextEditing(readOnly), "읽기 전용으로 고른 인용은 편집이 아니다")
        #expect(!EdgeReviewKeys.isTextEditing(idle) && !EdgeReviewKeys.isTextEditing(NSView()) && !EdgeReviewKeys.isTextEditing(nil))
    }
}

private extension EdgeReviewKeys {
    static func of(_ code: Int, _ characters: String, _ flags: NSEvent.ModifierFlags) -> ReviewKey? {
        of(keyCode: code, characters: characters, flags: flags)
    }
}

@MainActor
struct EdgeReviewModelTests {
    // MARK: 가장 새 항목 · 링 · 단계

    @Test func commandOneOpensTheNewestAndTheHeaderStepsFollowServerOrder() async throws {
        let rig = try await ReviewRig.make()
        rig.shell.openNewestReview()
        #expect(rig.ids == [1, 2, 3].map(rig.id), "서버 순서 그대로")
        #expect(rig.shell.panelOpen && rig.shell.view == .review && rig.shell.shownReview?.id == rig.id(3))
        rig.shell.stepReview(-1)
        #expect(rig.shell.shownReview?.id == rig.id(2))
        rig.shell.stepReview(-1)
        rig.shell.stepReview(-1)
        #expect(rig.shell.shownReview?.id == rig.id(1), "처음에서 멈춘다")
        rig.shell.stepReview(2)
        rig.shell.stepReview(1)
        #expect(rig.shell.shownReview?.id == rig.id(3), "끝에서 멈춘다")
        #expect(await rig.harness.server.writeCount() == 0)
    }

    @Test func anEmptyQueueSaysNoDecisionsWaitingOnlyAfterTheListArrived() async throws {
        let rig = try await ReviewRig.make(reviews: 0)
        rig.shell.openNewestReview()
        #expect(!rig.shell.panelOpen, "OA U2b: 답할 것이 없으면 ⌘1은 빈 Review를 열지 않는다")
        rig.shell.openReview(itemID: UUID())
        #expect(rig.shell.view == .review && rig.shell.shownReview == nil && rig.shell.reviewScreen == .empty(problem: nil), "그래도 빈 화면은 다른 길(답한 뒤)로 보인다")
        // 목록을 아직 못 받았으면 아무 주장도 하지 않는다
        let loading = EdgeShellModel(schedule: { _, _ in EdgeTimer() }, review: rig.desk)
        loading.openNewestReview()
        #expect(loading.reviewScreen == .blank)
        loading.update(EdgeWorkSnapshot(load: .offline))
        #expect(loading.reviewScreen == .offline)
        loading.update(EdgeWorkSnapshot(load: .failed))
        #expect(loading.reviewScreen == .failed)
    }

    // MARK: 큐가 바뀔 때 (옛 index가 다른 항목에 행동하지 않는다)

    @Test func aReorderedQueueKeepsTheShownItemAndAnswersGoToItsID() async throws {
        let rig = try await ReviewRig.make()
        rig.shell.openReview(itemID: rig.id(2))
        #expect(rig.shell.shownReview?.id == rig.id(2))
        let before = rig.shell.shownReview!.id

        // 서버가 순서를 바꿨다: 2가 맨 앞이 된다 → 2는 index 0이지만 그래도 보이는 것은 2, 답도 2에만
        await rig.harness.server.bump(rig.id(1), to: Date(timeIntervalSince1970: 1_791_100_000))
        await rig.harness.server.bump(rig.id(3), to: Date(timeIntervalSince1970: 1_791_200_000))
        await rig.harness.store.load()
        rig.sync()
        #expect(rig.ids.first == rig.id(2) && rig.shell.shownReview?.id == before, "index가 아니라 id로 가리킨다")
        let result = try await rig.answered(.confirm, before)
        #expect(result == .applied)
        #expect(await rig.harness.server.writeCount("confirm", for: rig.id(2)) == 1)
        #expect(await rig.harness.server.writeCount() == 1)
    }

    @Test func whenTheShownItemIsResolvedElsewhereTheNextItemTakesOverButAStaleClickGoesNowhere() async throws {
        let rig = try await ReviewRig.make()
        rig.shell.openReview(itemID: rig.id(2))
        let seen = rig.id(2) // 사용자가 본 항목 (버튼이 render 때 잡아 둔 id)

        // 다른 기기가 2를 처리했다
        await rig.harness.server.otherDeviceResolves(seen, confirmed: true)
        await rig.harness.store.load()
        rig.sync()
        #expect(rig.shell.shownReview?.id == rig.id(3), "같은 자리의 다른 항목이 아니라 2의 뒤를 이은 항목")

        // 옛 화면의 클릭(2): 이제 큐에 없으므로 아무것도 보내지 않고, 지금 보이는 3에도 가지 않는다
        #expect(rig.shell.answer(.dismiss, for: seen) == nil)
        #expect(await rig.harness.server.arrived(seen) == 0)
        #expect(await rig.harness.server.arrived(rig.id(3)) == 0)
    }

    @Test func whenTheLastItemIsHandledTheQueueShowsNoDecisionsWaiting() async throws {
        let rig = try await ReviewRig.make(reviews: 1)
        rig.shell.openNewestReview()
        let id = rig.id(1)
        let result = try await rig.answered(.dismiss, id)
        #expect(result == .applied)
        rig.sync()
        #expect(rig.shell.shownReview == nil && rig.shell.reviewScreen == .empty(problem: nil) && rig.shell.reviewID == nil)
    }

    @Test func answeringAdvancesToTheNextItemOnlyAfterTheServerTookTheAnswer() async throws {
        let rig = try await ReviewRig.make()
        rig.shell.openReview(itemID: rig.id(2))
        await rig.harness.server.hold(rig.id(2))

        let task = try #require(rig.shell.answer(.confirm, for: rig.id(2)))
        #expect(await rig.harness.wait { await rig.harness.server.arrived(rig.id(2)) == 1 })
        rig.sync()
        // 보내는 중: 항목은 그대로, 진행 표시, 완료 표시 없음
        #expect(rig.shell.shownReview?.id == rig.id(2) && rig.desk.sending[rig.id(2)] == .confirm)
        // 같은 항목에 반복 · 다른 답 · 다시 클릭: 보내지 않는다
        #expect(rig.shell.answer(.confirm, for: rig.id(2)) == nil, "받는 경계에서 이미 보내는 항목은 거절된다 (반복 키 · 중복 클릭)")
        await rig.harness.server.release(rig.id(2))
        #expect(await task.value == .applied)
        rig.sync()
        #expect(rig.shell.shownReview?.id == rig.id(3), "서버가 받은 뒤에야 다음 항목")
        #expect(await rig.harness.server.arrived(rig.id(2)) == 1)
    }

    @Test func nothingIsSentWhileOfflineOrWhenThePanelIsClosed() async throws {
        let rig = try await ReviewRig.make()
        rig.shell.openNewestReview()
        rig.shell.update(EdgeWorkSnapshot(review: rig.shell.reviewQueue.items, load: .loaded(problem: .offline)))
        #expect(!rig.shell.reviewScreen.canAnswer && rig.shell.answer(.confirm, for: rig.id(3)) == nil, "나중에 보내려고 모아 두지 않는다")
        rig.shell.update(EdgeWorkSnapshot(review: rig.shell.reviewQueue.items, load: .loaded(problem: nil)))
        rig.shell.dismiss()
        #expect(rig.shell.answer(.confirm, for: rig.id(3)) == nil, "닫힌 패널에서는 답이 없다")
        #expect(await rig.harness.server.arrived(rig.id(3)) == 0)
    }

    // MARK: 안내 · 정직한 표시

    @Test func aLostResponseKeepsAnHonestNoticeEvenAfterTheItemLeavesTheList() async throws {
        let rig = try await ReviewRig.make()
        rig.shell.openReview(itemID: rig.id(2))
        await rig.harness.server.script(rig.id(2), .applyThenLose)

        let result = try await rig.answered(.confirm, rig.id(2))
        rig.sync()

        #expect(result == .unverified)
        // 서버는 적용했고 목록에서도 사라졌지만, 앱은 내 요청의 성공을 단정하지 않는다
        #expect(!rig.ids.contains(rig.id(2)))
        #expect(rig.desk.notice == ReviewDesk.Notice(id: rig.id(2), text: ReviewCopy.unverified))
        #expect(await rig.harness.server.arrived(rig.id(2)) == 1, "자동 재전송 없음")
        // 보던 항목은 다음 항목으로 갔다
        #expect(rig.shell.shownReview?.id == rig.id(3))
        // Review를 떠나면 안내는 거둔다
        rig.shell.openAllWork()
        #expect(rig.desk.notice == nil)
    }

    @Test func aRefusalLeavesTheItemAnsweredAgainOnlyByTheUsersNextChoice() async throws {
        let rig = try await ReviewRig.make()
        rig.shell.openReview(itemID: rig.id(1))
        await rig.harness.server.script(rig.id(1), .reject(409, "conflict"))

        let result = try await rig.answered(.confirm, rig.id(1))
        rig.sync()
        #expect(result == .rejected(ReviewCopy.conflict))
        #expect(rig.desk.notice?.text == "This changed somewhere else. It's been refreshed.")
        #expect(rig.shell.shownReview?.id == rig.id(1) && rig.desk.sending.isEmpty, "그대로 있고 다시 고를 수 있다")
        #expect(await rig.harness.server.arrived(rig.id(1)) == 1)

        // 사용자가 다시 골랐다
        let again = try await rig.answered(.confirm, rig.id(1))
        #expect(again == .applied)
        #expect(rig.desk.notice == nil)
        #expect(await rig.harness.server.arrived(rig.id(1)) == 2)
    }

    // MARK: 클릭 · 키를 받은 뒤 전송 직전까지 (Codex 9d0cc95 검토 P2-D): 동기 경계에서 계정 · 화면 · 항목 소유권을 잡고 보내기 직전에 다시 본다

    /// 클릭을 받아 예약만 된 상태(Task는 아직 시작하지 않았다)를 만든다: 테스트는 MainActor라 이 함수 안에서 양보하지 않는 한 예약된 Task가 시작하지 않는다
    private func queued(_ rig: ReviewRig, _ answer: ReviewAnswer = .confirm, for id: UUID) throws -> Task<ReviewWriteResult, Never> {
        try #require(rig.shell.answer(answer, for: id))
    }

    @Test(arguments: [false, true])
    func aClickQueuedBeforeAnAccountChangeSendsNothingUnderTheNewSession(differentAccount: Bool) async throws {
        let rig = try await ReviewRig.make()
        rig.shell.openReview(itemID: rig.id(2))
        let task = try queued(rig, for: rig.id(2))
        // Task가 시작하기 전에 계정이 떠났다 (같은 UUID 재로그인 · 다른 계정)
        if differentAccount { try rig.harness.switchAccount() } else { rig.harness.reloginSameUser() }

        #expect(await task.value == .ignored)
        #expect(await rig.harness.server.arrived(rig.id(2)) == 0, "옛 세션의 클릭이 새 세션으로 나가지 않는다")
        #expect(rig.desk.sending.isEmpty && rig.desk.notice == nil && rig.harness.store.busy.isEmpty)
        // 새 세션은 영향이 없다: 같은 항목은 아직 Review에 있고, 새 세션의 사용자 선택은 그대로 한 번 나간다
        await rig.harness.store.load()
        rig.sync()
        #expect(rig.ids.contains(rig.id(2)))
        rig.shell.openReview(itemID: rig.id(2))
        #expect(try await rig.answered(.confirm, rig.id(2)) == .applied)
        #expect(await rig.harness.server.arrived(rig.id(2)) == 1)
    }

    @Test func aClickQueuedBeforeTheItemLeavesTheQueueOrThePanelClosesSendsNothing() async throws {
        // 큐에서 항목이 빠졌다 (다른 기기가 처리)
        var rig = try await ReviewRig.make()
        rig.shell.openReview(itemID: rig.id(2))
        var task = try queued(rig, for: rig.id(2))
        rig.shell.update(EdgeWorkSnapshot(review: rig.shell.reviewQueue.items.filter { $0.id != rig.id(2) }, load: .loaded(problem: nil)))
        #expect(await task.value == .ignored)
        #expect(await rig.harness.server.arrived(rig.id(2)) == 0 && rig.desk.sending.isEmpty)

        // 패널이 닫혔다
        rig = try await ReviewRig.make()
        rig.shell.openReview(itemID: rig.id(2))
        task = try queued(rig, for: rig.id(2))
        rig.shell.dismiss()
        #expect(await task.value == .ignored)
        #expect(await rig.harness.server.arrived(rig.id(2)) == 0 && rig.desk.sending.isEmpty)

        // 다른 화면으로 옮겼다
        rig = try await ReviewRig.make()
        rig.shell.openReview(itemID: rig.id(2))
        task = try queued(rig, for: rig.id(2))
        rig.shell.openAllWork()
        #expect(await task.value == .ignored)
        #expect(await rig.harness.server.arrived(rig.id(2)) == 0 && rig.desk.sending.isEmpty)

        // 닫았다 다시 열었다 = 다른 방문: 옛 클릭은 새 방문의 것이 아니다
        rig = try await ReviewRig.make()
        rig.shell.openReview(itemID: rig.id(2))
        task = try queued(rig, for: rig.id(2))
        rig.shell.dismiss()
        rig.shell.openReview(itemID: rig.id(2))
        #expect(await task.value == .ignored)
        #expect(await rig.harness.server.arrived(rig.id(2)) == 0)

        // 오프라인이 됐다
        rig = try await ReviewRig.make()
        rig.shell.openReview(itemID: rig.id(2))
        task = try queued(rig, for: rig.id(2))
        rig.shell.update(EdgeWorkSnapshot(review: rig.shell.reviewQueue.items, load: .loaded(problem: .offline)))
        #expect(await task.value == .ignored)
        #expect(await rig.harness.server.arrived(rig.id(2)) == 0)
    }

    @Test func aClickQueuedBeforeAnotherItemTookTheScreenSendsNothingToAnyItem() async throws {
        let rig = try await ReviewRig.make()
        rig.shell.openReview(itemID: rig.id(2))
        let task = try queued(rig, for: rig.id(2))
        // 큐가 바뀌어 보이는 항목이 다른 것이 됐다 (보던 2가 빠지고 3이 이어받음): 3에도 가지 않는다
        rig.shell.update(EdgeWorkSnapshot(review: rig.shell.reviewQueue.items.filter { $0.id != rig.id(2) }, load: .loaded(problem: nil)))
        #expect(rig.shell.shownReview?.id == rig.id(3))
        #expect(await task.value == .ignored)
        #expect(await rig.harness.server.arrived(rig.id(2)) == 0)
        #expect(await rig.harness.server.arrived(rig.id(3)) == 0)
    }

    // 대조: 같은 상황이어도 유효한 상호작용은 그대로 한 번 나간다

    @Test func aTokenRefreshOrAReorderBeforeDispatchStillSendsExactlyOnce() async throws {
        let rig = try await ReviewRig.make()
        rig.shell.openReview(itemID: rig.id(2))
        let task = try queued(rig, for: rig.id(2))
        // 같은 계정의 토큰 갱신(epoch 그대로) + 큐 순서 변화(보던 항목은 id 그대로)
        try rig.harness.refreshToken()
        rig.shell.update(EdgeWorkSnapshot(review: rig.shell.reviewQueue.items.reversed(), load: .loaded(problem: nil)))
        #expect(rig.shell.shownReview?.id == rig.id(2))
        #expect(await task.value == .applied)
        #expect(await rig.harness.server.arrived(rig.id(2)) == 1)
        #expect(await rig.harness.server.writeCount("confirm", for: rig.id(2)) == 1)
    }

    @Test func steppingAwayAndBackBeforeDispatchStillSendsAndOrdinaryFollowUpsEachSendOnce() async throws {
        let rig = try await ReviewRig.make()
        rig.shell.openReview(itemID: rig.id(2))
        let task = try queued(rig, for: rig.id(2))
        rig.shell.stepReview(1)
        rig.shell.stepReview(-1)
        #expect(rig.shell.shownReview?.id == rig.id(2))
        #expect(await task.value == .applied)
        rig.sync()
        // 정상 연속 상호작용: 다음 항목에 다시 고르면 그 항목으로 한 번
        #expect(rig.shell.shownReview?.id == rig.id(3))
        #expect(try await rig.answered(.dismiss, rig.id(3)) == .applied)
        #expect(await rig.harness.server.writeCount() == 2)
        #expect(await rig.harness.server.arrived(rig.id(2)) == 1)
        #expect(await rig.harness.server.arrived(rig.id(3)) == 1)
    }

    @Test func twoClicksInTheSameTurnQueueOneWrite() async throws {
        let rig = try await ReviewRig.make()
        rig.shell.openReview(itemID: rig.id(2))
        let first = rig.shell.answer(.confirm, for: rig.id(2))
        let second = rig.shell.answer(.dismiss, for: rig.id(2))
        let third = rig.shell.answer(.confirm, for: rig.id(2))
        #expect(first != nil && second == nil && third == nil, "예약된 항목에는 겹쳐 받지 않는다")
        #expect(await first?.value == .applied)
        #expect(await rig.harness.server.arrived(rig.id(2)) == 1)
    }

    @Test func aRequestThatAlreadyStartedKeepsItsTruthfulResultWhateverHappensToTheScreenAfterward() async throws {
        let rig = try await ReviewRig.make()
        rig.shell.openReview(itemID: rig.id(2))
        await rig.harness.server.hold(rig.id(2))
        let task = try queued(rig, for: rig.id(2))
        #expect(await rig.harness.wait { await rig.harness.server.arrived(rig.id(2)) == 1 })
        // 이미 서버로 나간 뒤에는 패널을 닫고 화면을 옮겨도 취소하지 않는다 (서버가 받았는지 모를 요청을 버리지 않는다)
        rig.shell.dismiss()
        rig.shell.openAllWork()
        await rig.harness.server.release(rig.id(2))
        #expect(await task.value == .applied)
        #expect(rig.desk.sending.isEmpty && rig.harness.store.busy.isEmpty)
        #expect(await rig.harness.server.writeCount("confirm", for: rig.id(2)) == 1)
    }

    // MARK: 계정 · 세션

    @Test(arguments: [false, true])
    func anAnswerFinishingAfterANewSessionTouchesNothingOfIt(differentAccount: Bool) async throws {
        let rig = try await ReviewRig.make()
        rig.shell.openReview(itemID: rig.id(1))
        await rig.harness.server.hold(rig.id(1))

        let old = try #require(rig.shell.answer(.confirm, for: rig.id(1)))
        #expect(await rig.harness.wait { await rig.harness.server.arrived(rig.id(1)) == 1 })
        #expect(rig.desk.sending[rig.id(1)] == .confirm)

        if differentAccount { try rig.harness.switchAccount() } else { rig.harness.reloginSameUser() }
        #expect(rig.desk.sending.isEmpty && rig.desk.notice == nil, "계정이 떠나면 진행 표시 · 안내는 비워진다")
        await rig.harness.store.load()
        rig.sync()
        rig.shell.openReview(itemID: rig.id(1))
        let new = try #require(rig.shell.answer(.dismiss, for: rig.id(1)))
        #expect(await rig.harness.wait { await rig.harness.server.arrived(rig.id(1)) == 2 })
        #expect(rig.desk.sending[rig.id(1)] == .dismiss)

        await rig.harness.server.releaseNext(rig.id(1))
        #expect(await old.value == .ignored)
        #expect(rig.desk.sending[rig.id(1)] == .dismiss, "옛 요청이 끝나도 새 세션의 진행 표시는 그대로")
        #expect(rig.desk.notice == nil)

        await rig.harness.server.release(rig.id(1))
        #expect(await new.value == .applied)
        #expect(rig.desk.sending.isEmpty)
    }

    @Test func switchingAccountsClearsWhichDecisionWasShown() async throws {
        let rig = try await ReviewRig.make()
        rig.shell.accountChanged(ReviewHarness.userID)
        rig.shell.openReview(itemID: rig.id(2))
        #expect(rig.shell.reviewID == rig.id(2))
        rig.shell.accountChanged(UUID())
        #expect(rig.shell.reviewID == nil)
    }

    // MARK: 머리 제목이 가려지지 않게

    @Test func theFullTitleJoinsTheBodyOnlyWhenTheHeaderCannotShowIt() {
        #expect(!ReviewHeaderFit.truncates("제안서 v2 보내기", steps: 1))
        #expect(!ReviewHeaderFit.truncates("계약서 변경 사항 검토", steps: 4), "단계 점 넷 옆에서도 이 정도는 들어간다")
        #expect(ReviewHeaderFit.truncates("금요일 고객 데모 준비 (새 온보딩, 결제 화면 포함)", steps: 4))
        #expect(ReviewHeaderFit.truncates(String(repeating: "Long title ", count: 8), steps: 1))
        // 단계 점이 많을수록 제목 자리가 줄어든다
        let title = "Send the revised proposal to the Acme team"
        #expect(!ReviewHeaderFit.truncates(title, steps: 1) && ReviewHeaderFit.truncates(title, steps: 9))
    }

    // MARK: 원문

    @Test func theSourceIsReadWhenTheDecisionIsShownAndReadAgainOnlyWhenTheItemChanged() async throws {
        let rig = try await ReviewRig.make()
        let action = try #require(rig.shell.reviewQueue.item(rig.id(2)))
        await rig.harness.server.setEvidence(rig.id(2), [.init(quote: "Could we do Thursday instead?", sourceTitle: "Thread", url: "https://mail.google.com/mail/u/0/#inbox/x", at: Date(timeIntervalSince1970: 1_791_000_000))])
        #expect(rig.desk.source(for: rig.id(2)) == .loading)

        await rig.desk.loadSource(for: action, presentation: rig.shell.reviewPresentation)
        guard case .lines(let lines) = rig.desk.source(for: rig.id(2)) else {
            Issue.record("quote expected: \(rig.desk.source(for: rig.id(2)))")
            return
        }
        #expect(lines.map(\.text) == ["Could we do Thursday instead?"] && lines[0].place == "Thread" && lines[0].url?.host == "mail.google.com")
        // 다시 보여도(단계를 옮겼다 돌아옴) 다시 읽지 않는다
        await rig.desk.loadSource(for: action, presentation: rig.shell.reviewPresentation)
        #expect(await rig.harness.server.evidenceReadCount(rig.id(2)) == 1)
        // 항목이 달라졌으면(`last_activity_at`) 다시 읽는다: 지금 근거가 아니면 보이지 않게
        await rig.harness.server.bump(rig.id(2), to: Date(timeIntervalSince1970: 1_791_500_000))
        await rig.harness.store.load()
        rig.sync()
        let changed = try #require(rig.shell.reviewQueue.item(rig.id(2)))
        await rig.desk.loadSource(for: changed, presentation: rig.shell.reviewPresentation)
        #expect(await rig.harness.server.evidenceReadCount(rig.id(2)) == 2)
    }

    // MARK: 원문 신선도 (Codex b52443b 검토 B): 활동 시각과 따로, 다시 들어올 때마다 확인

    @Test func aSourceRemovedWithoutAnyActionActivityIsNotShownAgainWhenTheUserComesBack() async throws {
        let rig = try await ReviewRig.make()
        let id = rig.id(2)
        let at = Date(timeIntervalSince1970: 1_791_000_000)
        await rig.harness.server.setEvidence(id, [.init(quote: "OLD_QUOTE", sourceTitle: "Thread", url: nil, at: at)])
        rig.shell.openReview(itemID: id)
        let action = try #require(rig.shell.shownReview)
        let visit = rig.shell.reviewPresentation
        await rig.desk.loadSource(for: action, presentation: visit)
        guard case .lines(let before) = rig.desk.source(for: id) else {
            Issue.record("quote expected")
            return
        }
        #expect(before.map(\.text) == ["OLD_QUOTE"])

        // 원문만 지워졌다 (Slack 연결 끊기처럼 `actions.last_activity_at`은 그대로)
        await rig.harness.server.setEvidence(id, [.init(quote: RemovedQuote.slackDisconnected, sourceTitle: "Thread", url: nil, at: at)])
        // 같은 방문 안에서 단계를 옮겼다 돌아와도 다시 읽지 않는다
        rig.shell.stepReview(1)
        rig.shell.openReview(itemID: id)
        #expect(rig.shell.reviewPresentation == visit)
        await rig.desk.loadSource(for: action, presentation: rig.shell.reviewPresentation)
        #expect(await rig.harness.server.evidenceReadCount(id) == 1)

        // 패널을 닫았다 다시 연다 = 다시 들어옴: 활동 시각이 같아도 다시 확인한다
        rig.shell.dismiss()
        rig.shell.openReview(itemID: id)
        let revisit = rig.shell.reviewPresentation
        #expect(revisit == visit + 1 && rig.shell.shownReview?.lastActivityAt == action.lastActivityAt)
        await rig.harness.server.holdEvidence()
        let reload = Task { await rig.desk.loadSource(for: action, presentation: revisit) }
        #expect(await rig.harness.wait { await rig.harness.server.pendingEvidenceReads() == 1 })
        #expect(rig.desk.source(for: id) == .loading, "확인하는 동안 전에 읽은 인용을 보이지 않는다")
        await rig.harness.server.releaseAllEvidence()
        await reload.value
        guard case .lines(let after) = rig.desk.source(for: id) else {
            Issue.record("a removed line expected")
            return
        }
        #expect(after.count == 1 && after[0].removed && after[0].text.isEmpty, "옛 인용은 나오지 않는다")
        #expect(await rig.harness.server.evidenceReadCount(id) == 2)
    }

    @Test func ifTheRevisitCannotVerifyItShowsFailedNotTheOldQuote() async throws {
        let rig = try await ReviewRig.make()
        let id = rig.id(2)
        await rig.harness.server.setEvidence(id, [.init(quote: "OLD_QUOTE", sourceTitle: nil, url: nil, at: Date(timeIntervalSince1970: 1_791_000_000))])
        rig.shell.openReview(itemID: id)
        let action = try #require(rig.shell.shownReview)
        await rig.desk.loadSource(for: action, presentation: rig.shell.reviewPresentation)
        rig.shell.dismiss()
        rig.shell.openReview(itemID: id)
        await rig.harness.server.scriptEvidence(500)
        await rig.desk.loadSource(for: action, presentation: rig.shell.reviewPresentation)
        #expect(rig.desk.source(for: id) == .failed)
        // Try again이 새로 확인한다: 다시 시도하는 동안에도 전에 읽은 인용을 보이지 않는다
        await rig.harness.server.holdEvidence()
        let retry = Task { await rig.desk.retrySource(for: action, presentation: rig.shell.reviewPresentation) }
        #expect(await rig.harness.wait { await rig.harness.server.pendingEvidenceReads() == 1 })
        #expect(rig.desk.source(for: id) == .loading, "retry 중에 옛 인용이 다시 나오지 않는다")
        await rig.harness.server.releaseAllEvidence()
        await retry.value
        guard case .lines(let lines) = rig.desk.source(for: id) else {
            Issue.record("quote expected after Try again")
            return
        }
        #expect(lines.map(\.text) == ["OLD_QUOTE"])
    }

    @Test func thePresentationRisesOnlyWhenTheUserEntersTheReviewPage() async throws {
        let rig = try await ReviewRig.make()
        #expect(rig.shell.reviewPresentation == 0)
        rig.shell.openNewestReview()
        #expect(rig.shell.reviewPresentation == 1)
        rig.shell.stepReview(-1)
        rig.shell.openReview(itemID: rig.id(1))
        rig.shell.openNewestReview()
        #expect(rig.shell.reviewPresentation == 1, "열린 Review 안의 이동 · 다시 누르기는 다시 들어온 것이 아니다")
        rig.shell.dismiss()
        rig.shell.togglePanel()
        #expect(rig.shell.view == .review && rig.shell.reviewPresentation == 2, "⌥ Space로 다시 열면 다시 들어온 것")
        rig.shell.openAllWork()
        rig.shell.openReview(itemID: rig.id(2))
        #expect(rig.shell.reviewPresentation == 3)
        // S4가 꺼진 셸은 Review에 들어올 수 없다
        let off = EdgeShellModel(schedule: { _, _ in EdgeTimer() })
        off.openNewestReview()
        off.togglePanel()
        #expect(off.reviewPresentation == 0 && off.view == .allWork)
    }

    @Test func aFailedSourceReadIsNotRetriedOnItsOwnAndRetryIsExplicit() async throws {
        let rig = try await ReviewRig.make()
        let action = try #require(rig.shell.reviewQueue.item(rig.id(1)))
        await rig.harness.server.setEvidence(rig.id(1), [.init(quote: "Hello", sourceTitle: nil, url: nil, at: Date(timeIntervalSince1970: 1_791_000_000))])
        await rig.harness.server.setEvidenceStatus(500)

        await rig.desk.loadSource(for: action, presentation: rig.shell.reviewPresentation)
        #expect(rig.desk.source(for: rig.id(1)) == .failed)
        await rig.desk.loadSource(for: action, presentation: rig.shell.reviewPresentation)
        #expect(await rig.harness.server.evidenceReadCount(rig.id(1)) == 1, "스스로 다시 읽지 않는다")

        await rig.harness.server.setEvidenceStatus(200)
        await rig.desk.retrySource(for: action, presentation: rig.shell.reviewPresentation)
        guard case .lines(let lines) = rig.desk.source(for: rig.id(1)) else {
            Issue.record("quote expected after Try again")
            return
        }
        #expect(lines.map(\.text) == ["Hello"] && lines[0].place == nil)
    }

    @Test func aSlackQuoteRemovedOnDisconnectIsShownAsRemoved() async throws {
        let rig = try await ReviewRig.make()
        let action = try #require(rig.shell.reviewQueue.item(rig.id(1)))
        await rig.harness.server.setEvidence(rig.id(1), [.init(quote: RemovedQuote.slackDisconnected, sourceTitle: "#sales", url: nil, at: Date(timeIntervalSince1970: 1_791_000_000))])
        await rig.desk.loadSource(for: action, presentation: rig.shell.reviewPresentation)
        guard case .lines(let lines) = rig.desk.source(for: rig.id(1)) else {
            Issue.record("a removed line expected")
            return
        }
        #expect(lines.count == 1 && lines[0].removed && lines[0].text.isEmpty)
    }

    @Test func openingAndReadingTheSourceSendsNoWrite() async throws {
        let rig = try await ReviewRig.make()
        rig.shell.openNewestReview()
        let action = try #require(rig.shell.shownReview)
        await rig.harness.server.setEvidence(action.id, [.init(quote: "q", sourceTitle: nil, url: nil, at: Date(timeIntervalSince1970: 1_791_000_000))])
        await rig.desk.loadSource(for: action, presentation: rig.shell.reviewPresentation)
        rig.shell.stepReview(-1)
        rig.shell.dismiss()
        rig.shell.openNewestReview()
        #expect(await rig.harness.server.writeCount() == 0)
        #expect(await rig.harness.server.arrived(action.id) == 0)
    }
}
