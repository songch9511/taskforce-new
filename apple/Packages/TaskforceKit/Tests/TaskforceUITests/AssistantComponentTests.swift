import CryptoKit
import Foundation
import Testing
import TaskforceKit
@testable import TaskforceUI
#if canImport(AppKit)
import AppKit
#endif

/// Assistant 창 부품 (OA U1)의 순수 규칙 · 자산 · 키 규칙: AgentMark 자산은 공급된 파일 그대로 · 칩 · 대상 메뉴의 줄 이동 · Return 규칙 · Review 타일
struct AssistantComponentTests {
    // MARK: AgentMark: 공급된 파일 그대로

    static let agentFolder = TokenCatalog.sourceCatalog.appending(path: "agent", directoryHint: .isDirectory)

    static func svg(_ name: String) throws -> Data {
        try Data(contentsOf: agentFolder.appending(path: "\(name).imageset/\(name).svg"))
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Figma AgentMark(31:1578)에서 `exportAsync`로 내보낸 SVG의 해시 (2026-10-14, 길이 · FNV로도 대조: 658/81413f4c · 434/b02fb778 · 2906/7c7b6add).
    /// 한 글자라도 바뀌면(다시 그림 · 색 바꿈 · 윤곽) 이 시험이 깨진다. 마크를 바꾸려면 새 공급 파일의 해시로 함께 바꾼다
    static let suppliedHashes: [String: String] = [
        "taskforce": "2b6d254724a76af64ce28a746b3ccd21b0113979363e25a4f7ddcac6d5f9ccfa",
        "claude-code": "0e6559e5f4ec0df01d090628342e747c6ee2f5277aa29731f0dbb56084a6011f",
        "codex": "5ee2de992f95a1d3aa774d83e1f2a838f085b2bea7f0750b59ba2967ac157082",
    ]

    @Test(arguments: ["taskforce", "claude-code", "codex"])
    func theMarkFilesAreExactlyTheSuppliedOnes(_ name: String) throws {
        #expect(Self.sha256(try Self.svg(name)) == Self.suppliedHashes[name], "\(name).svg가 공급된 파일과 다르다")
    }

    @Test func claudeCodeKeepsItsOwnOrangeAndTheOthersAreInk() throws {
        let claude = try String(decoding: Self.svg("claude-code"), as: UTF8.self)
        #expect(claude.contains(##"fill="#D97757""##) && !claude.contains("#1D1D1F"))
        for name in ["taskforce", "codex"] {
            let text = try String(decoding: Self.svg(name), as: UTF8.self)
            #expect(text.contains(##"fill="#1D1D1F""##) && !text.contains("#D97757"), "\(name)은 잉크")
        }
    }

    @Test func templateIntentFollowsTheRule() throws {
        func intent(_ name: String) throws -> String? {
            let data = try Data(contentsOf: Self.agentFolder.appending(path: "\(name).imageset/Contents.json"))
            let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
            return (json["properties"] as? [String: Any])?["template-rendering-intent"] as? String
        }
        #expect(try intent("taskforce") == "template" && intent("codex") == "template", "text/primary로 칠한다")
        #expect(try intent("claude-code") == "original", "자기 색 그대로")
    }

    @Test func everyMarkKindHasItsAssetExceptThePlaceholder() {
        #expect(AgentMark.assetName(.taskforce) == "agent/taskforce")
        #expect(AgentMark.assetName(.claudeCode) == "agent/claude-code")
        #expect(AgentMark.assetName(.codex) == "agent/codex")
        #expect(AgentMark.assetName(.placeholder) == nil, "점선 사각형은 그린다 (공급된 파일이 없는 에이전트)")
        #expect(AgentMark.sizes == [20, 16, 12])
    }

    @Test(arguments: ["agent/taskforce", "agent/claude-code", "agent/codex"])
    func theMarksLoadFromTheCompiledCatalog(_ name: String) throws {
        guard TokenCatalog.isCompiled else { return }
        #if canImport(AppKit)
        let image = try #require(TFColor.bundle.image(forResource: name), "\(name)을 컴파일된 카탈로그에서 찾지 못함")
        #expect(image.size == NSSize(width: 20, height: 20))
        #endif
    }

    // MARK: 칩

    @Test func aChipNamesWhatItCanBeRemovedBy() {
        #expect(ContextChip.removeLabel("#139 Rewrite pricing page copy") == "Remove #139 Rewrite pricing page copy")
        #expect(ContextChip.iconSize == 12 && ContextChip.radius == 6)
    }

    // MARK: 대상 알약 · 메뉴

    @Test func thePillSaysWhoTheMessageGoesTo() {
        #expect(TargetPill.accessibilityLabel("Codex") == "Send to Codex")
        #expect(TargetPill.markSize == 16 && TargetPill.chevronSize == 14)
    }

    @MainActor
    func menu(selected: Int? = 0) -> (TargetMenuModel, picked: Picks) {
        let picks = Picks()
        let options = AssistantTargetRules.options(from: [
            .taskforce,
            .agent(.init(adapter: "agent:claude-code", displayName: "Claude Code", connectionID: UUID(), state: .unsupported, access: nil)),
            .agent(.init(adapter: "agent:codex", displayName: "Codex", connectionID: UUID(), state: .ready, access: .readOnly)),
        ], canRunAgents: true)
        return (TargetMenuModel(options: options, selected: selected, onPick: { picks.names.append($0.name) }), picks)
    }

    final class Picks {
        var names: [String] = []
    }

    /// 대상 목록을 돌려주는 가짜 (읽기만 한다)
    final class StubTargets: AssistantGateway, @unchecked Sendable {
        nonisolated(unsafe) var reply: @Sendable () async throws -> [AssistantTarget] = { [.taskforce] }
        func targets() async throws -> [AssistantTarget] { try await reply() }
        func createConversation(id: UUID, title: String?, contextID: UUID?, target: ChatTarget) async throws -> ChatCreatedConversation { throw URLError(.badURL) }
        func postChatMessage(conversationID: UUID, clientMessageID: UUID, text: String, attachments: [ChatAttachment]) async throws -> ChatPostedMessage { throw URLError(.badURL) }
        func postAgentMessage(conversationID: UUID, clientMessageID: UUID, text: String, attachments: [ChatAttachment]) async throws -> AgentPostedMessage { throw URLError(.badURL) }
    }

    /// 열 때까지 읽기를 붙잡는 문
    actor Gate {
        private(set) var arrivals = 0
        private var opened = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func wait() async {
            arrivals += 1
            if opened { return }
            await withCheckedContinuation { waiters.append($0) }
        }

        func open() {
            opened = true
            waiters.forEach { $0.resume() }
            waiters = []
        }
    }

    @MainActor
    @Test func aLiveMenuFollowsTheTargetStoreSoAgentsAppearWhenTheReadEnds() async {
        let stub = StubTargets()
        let gate = Gate()
        let codex = UUID()
        stub.reply = {
            await gate.wait()
            return [.taskforce, .agent(.init(adapter: "agent:codex", displayName: "Codex", connectionID: codex, state: .ready, access: .write))]
        }
        let user = UUID()
        let store = AssistantTargetsStore(gateway: stub, scope: AccountScope(currentAccount: { user }), canRunAgents: { true })
        let retries = Picks()
        let model = TargetMenuModel(store: store, pick: { .taskforce }, onPick: { _ in }, onRetry: { retries.names.append("retry") })
        // 읽기가 끝나기 전에 메뉴를 연다: Taskforce뿐이고 "Loading…"
        #expect(model.options.map(\.name) == ["Taskforce"] && model.status == .loading && model.selected == 0)
        let read = Task { await store.refresh() }
        for _ in 0..<1000 where await gate.arrivals == 0 { await Task.yield() }
        #expect(model.status == .loading)
        await gate.open()
        await read.value
        // 같은 메뉴가 저장소를 지켜본다: 복사해 둔 목록이 아니라 끝난 뒤의 행이 나타난다
        #expect(model.status == .ready && model.options.map(\.name) == ["Taskforce", "Codex"] && model.selected == 0)
        // 실패: 줄과 다시 시도
        stub.reply = { throw URLError(.notConnectedToInternet) }
        await store.refresh()
        #expect(model.status == .failed)
        model.retry()
        #expect(retries.names == ["retry"])
        stub.reply = { [.taskforce] }
        await store.refresh()
        #expect(model.status == .ready)
    }

    @MainActor
    @Test func aHighlightFollowsItsTargetWhenTheListChangesAndClearsWhenTheTargetIsGone() async {
        let stub = StubTargets()
        let user = UUID()
        let store = AssistantTargetsStore(gateway: stub, scope: AccountScope(currentAccount: { user }), canRunAgents: { true })
        let a = UUID(), b = UUID(), codexConnection = UUID()
        let claudeA = AssistantTarget.agent(.init(adapter: "agent:claude-code", displayName: "Claude Code", connectionID: a, state: .ready, access: .write))
        let claudeB = AssistantTarget.agent(.init(adapter: "agent:claude-code", displayName: "Claude Code", connectionID: b, state: .ready, access: .write))
        let codex = AssistantTarget.agent(.init(adapter: "agent:codex", displayName: "Codex", connectionID: codexConnection, state: .ready, access: .write))
        stub.reply = { [.taskforce, claudeA, claudeB, codex] }
        await store.refresh()
        let picks = Picks()
        let model = TargetMenuModel(store: store, pick: { .taskforce }, onPick: { picks.names.append($0.id) }, onRetry: {})
        let bID = model.options[2].id
        model.highlighted = 2
        #expect(model.options[2].id == bID && model.options.map(\.name) == ["Taskforce", "Claude Code", "Claude Code", "Codex"])
        // 조회 결과가 A를 지운다: 강조는 B를 따라가고 Return은 B를 고른다 (자리 번호가 아니라 대상 id)
        stub.reply = { [.taskforce, claudeB, codex] }
        await store.refresh()
        #expect(model.highlighted == 1 && model.options[1].id == bID)
        model.activate()
        #expect(picks.names == [bID], "Codex가 아니라 강조했던 B")
        // B마저 사라지면 강조는 풀리고 Return은 아무 일도 하지 않는다
        stub.reply = { [.taskforce, codex] }
        await store.refresh()
        #expect(model.highlighted == nil)
        model.activate()
        #expect(picks.names == [bID], "지워진 대상 자리에 있던 다른 행을 고르지 않는다")
        // 사라진 뒤 ↓은 고른 행(없으면 첫 행)에서 다시 시작한다
        model.move(1)
        #expect(model.highlighted == 0)
    }

    @MainActor
    @Test func aStaticMenuModelIsAlwaysReady() {
        let (model, _) = menu()
        #expect(model.status == .ready && model.options.count == 3)
    }

    @MainActor
    @Test func arrowKeysWalkTheRowsWithoutWrapping() {
        let (model, _) = menu(selected: 1)
        #expect(model.highlighted == nil)
        model.move(1)
        #expect(model.highlighted == 1, "처음 ↓은 고른 행에서 시작한다")
        model.move(1)
        model.move(1)
        #expect(model.highlighted == 2, "끝에서 돌지 않는다")
        model.move(-1)
        model.move(-1)
        model.move(-1)
        #expect(model.highlighted == 0, "처음에서 돌지 않는다")
        let (fresh, _) = menu(selected: nil)
        fresh.move(-1)
        #expect(fresh.highlighted == 2, "처음 ↑은 마지막 행")
        let (none, _) = menu(selected: nil)
        none.move(1)
        #expect(none.highlighted == 0, "고른 행이 없으면 첫 행")
    }

    @MainActor
    @Test func returnPicksTheHighlightedRowAndAClickPicksItsRow() {
        let (model, picks) = menu()
        model.activate()
        #expect(picks.names.isEmpty, "짚은 행이 없으면 아무 일도 없다")
        model.move(1)
        model.move(1)
        model.activate()
        #expect(picks.names == ["Claude Code"])
        model.pick(2)
        model.pick(99)
        #expect(picks.names == ["Claude Code", "Codex"], "범위 밖은 무시")
    }

    // MARK: Return 규칙

    @Test func returnSendsShiftReturnBreaksTheLineAndAnImeNeverSends() {
        func decision(_ key: UInt16 = 36, shift: Bool = false, option: Bool = false, command: Bool = false, control: Bool = false, marked: Bool = false) -> PromptKeyRule.Decision {
            PromptKeyRule.decision(keyCode: key, shift: shift, option: option, command: command, control: control, hasMarkedText: marked)
        }
        #expect(decision() == .submit)
        #expect(decision(76) == .submit, "키패드 Enter")
        #expect(decision(shift: true) == .newline)
        #expect(decision(option: true) == .newline)
        #expect(decision(marked: true) == .passThrough, "조합 중 Enter는 조합 확정에 쓰인다")
        #expect(decision(shift: true, marked: true) == .passThrough)
        #expect(decision(control: true) == .passThrough)
        #expect(decision(0) == .passThrough, "Return이 아닌 키는 그대로")
        #expect(decision(53) == .passThrough, "Esc는 창이 듣는다")
    }

    // MARK: 프롬프트 박스 · 타일 · 메시지

    #if os(macOS)
    @Test func thePromptBoxKeepsTheDesignNumbers() {
        #expect(PromptBox.minTextHeight == 40 && PromptBox.maxTextHeight == 160)
        #expect(PromptBox.sendSize == 28)
        let inset = PromptBox.inset
        #expect((inset.top, inset.leading, inset.bottom, inset.trailing) == (8, 8, 6, 6), "DS bundle.css 안쪽 8/6/6/8")
        #expect(PromptBox.sendLabel(running: false) == "Send" && PromptBox.sendLabel(running: true) == "Stop new steps")
    }

    @Test func aSessionChipWearsAnAgentMarkAndEverythingElseTheItemIcon() {
        let item = AssistantChip(kind: .action, itemID: UUID(), origin: .auto, title: "x")
        let session = AssistantChip(kind: .agentSession, itemID: UUID(), origin: .added, title: "y")
        #expect(PromptBox.icon(for: item) == .item(.result))
        #expect(PromptBox.icon(for: session) == .agent(.placeholder))
    }
    #endif

    @Test func theReviewTileKeepsTheDesignNumbers() {
        #expect(ReviewTile.side == 32 && RailItem.side == ReviewTile.side)
        #expect(ReviewTile.openRing == (1.5, 2) && ReviewTile.focusRing == (2, 3))
        #expect(ReviewTile.hiddenDiameter == 16 && ReviewTile.hiddenIcon == 10)
        #expect(ReviewTile.hiddenIcon == 16 * (ReviewTile.hiddenDiameter / ReviewTile.side) * 1.25, "숨으면 타일 .5배 · 아이콘 1.25배 → 아이콘 10pt")
        #expect(ReviewTile.usesHoverOverlay(.needsYou) && !ReviewTile.usesHoverOverlay(.changes), "마커는 위에 덧칠, changes는 면 자체가 바뀐다")
    }

    @Test func notSentIsBoldAndTheReasonIsSecondary() {
        let failed = ChatStatusLine.parts(.failed("Can't reach the server."))
        #expect(failed?.strong == "Not sent" && failed?.text == "Can't reach the server.")
        #expect(ChatStatusLine.parts(.needsConsent)?.strong == "Not sent" && ChatStatusLine.parts(.needsConsent)?.text == nil)
        #expect(ChatStatusLine.parts(.sending)?.strong == nil && ChatStatusLine.parts(.sending)?.text == "Sending…")
        #expect(ChatStatusLine.parts(.noReply)?.strong == nil, "굵은 말은 막힌 것뿐")
        #expect(ChatStatusLine.parts(.sent) == nil)
        // 합친 글은 기존 그대로
        #expect(ChatStatusLine.text(.failed("x")) == "Not sent · x")
    }
}

#if os(macOS)
/// 프롬프트 글 영역의 실제 `NSTextView`: IME 조합 중 Return은 보내지 않고, Shift+Return은 줄을 바꾼다
@MainActor
struct PromptTextViewTests {
    final class Submissions {
        var count = 0
    }

    func makeView() throws -> (PromptNSTextView, Submissions) {
        let submissions = Submissions()
        let view = PromptNSTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 40))
        view.isEditable = true
        view.onSubmit = { submissions.count += 1 }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 80), styleMask: [.borderless], backing: .buffered, defer: true)
        window.contentView?.addSubview(view)
        window.makeFirstResponder(view)
        return (view, submissions)
    }

    func key(_ code: UInt16, characters: String = "\r", flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil, characters: characters,
            charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code
        ))
    }

    @Test func returnSendsButNotWhileAnImeIsComposing() throws {
        let (view, submissions) = try makeView()
        view.setMarkedText("ㅎ", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(view.hasMarkedText())
        view.keyDown(with: try key(36))
        #expect(submissions.count == 0, "조합 중 Enter는 조합을 확정할 뿐 보내지 않는다")
        view.unmarkText()
        view.keyDown(with: try key(36))
        #expect(submissions.count == 1)
    }

    @Test func shiftReturnBreaksTheLineAndSendsNothing() throws {
        let (view, submissions) = try makeView()
        view.string = "first"
        view.setSelectedRange(NSRange(location: 5, length: 0))
        view.keyDown(with: try key(36, flags: .shift))
        #expect(view.string == "first\n" && submissions.count == 0)
    }

    @Test func theTextIsThreeFifteenByTwentyAndThePlaceholderIsTheSecondaryColor() {
        #expect(PromptNSTextView.font.pointSize == 15)
        #expect(PromptNSTextView.paragraphStyle.minimumLineHeight == 20 && PromptNSTextView.paragraphStyle.maximumLineHeight == 20)
        let attributes = PromptNSTextView.attributes(color: .black)
        #expect(attributes[.kern] as? Double == -0.24)
    }
}
#endif
