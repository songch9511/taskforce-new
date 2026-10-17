import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Taskforce
@testable import TaskforceKit
@testable import TaskforceUI

/// OA D4b-m-2 (계약 16.3-4 · 16.8 "Mac 호스트"): 앱이 비밀값을 내보내는 실제 연결. 격리 Mac 호스트(`Debug-Test`)에서 가짜 서버 · 가짜 agent · 수동 시계 · 임시 원장으로만 돈다.
/// 실사용 Application Support · Keychain · 설정은 건드리지 않는다. 카나리는 `TF_CANARY_D4BM2_<uuid>`다
@MainActor
struct BridgeSecretSubmitterTests {
    static let requestID = "req-secret"

    private static func question() -> AgentQuestion {
        AgentQuestion(
            providerRequestID: requestID, kind: .input, structured: true, text: "API token?",
            items: [AgentQuestionItem(id: "q", header: "Token", text: "token", options: [], secret: true)]
        )
    }

    private func answer(_ created: FakeBridgeServer.Created, value: String) -> LocalSecretAnswer {
        LocalSecretAnswer(key: AgentQuestionKey(taskID: UUID(uuidString: created.taskID)!, requestID: Self.requestID), answers: ["q": .secret(SecretBox(value))])
    }

    /// 질문이 열린 호스트 (서버도 `awaiting_answer`로 안다)
    private func openFixture() async throws -> (HostFixture, FakeBridgeServer.Created) {
        let fixture = HostFixture()
        fixture.agent.setScript(.asking(Self.question()))
        await fixture.start()
        let created = try #require(await fixture.message())
        // 사건은 outbox를 거쳐 서버로 간다: 수동 시계가 멈춰 있으므로 비우기를 직접 돌린다
        let runtime = fixture.host.activeRuntime
        #expect(await fixture.eventually {
            await runtime?.flushOutbox()
            return fixture.server.taskState(created.taskID) == "awaiting_answer"
        })
        return (fixture, created)
    }

    private func submitter(_ fixture: HostFixture, account: UUID? = nil) -> BridgeLocalSecretSubmitter {
        let user = fixture.user
        return BridgeLocalSecretSubmitter(account: { account ?? user.value }, host: { [weak fixture] in fixture?.host })
    }

    // MARK: 실제 경로에 있다

    @Test func theRealChatRuntimePathCarriesTheLocalSecretSubmitter() throws {
        let account = try AppChatAccount.make()
        let (services, _) = S3bGateTests.services()
        let runtime = AppRuntime.makeChatRuntime(session: account.session, services: services, sample: false, s3b: false, connectivity: nil, agentQuestions: true)
        let store = try #require(runtime.questions)
        let child = try #require(Mirror(reflecting: store).children.first { $0.label == "secrets" })
        let wrapped = try #require(Mirror(reflecting: child.value).children.first?.value)
        #expect(String(describing: type(of: wrapped)) == "BridgeLocalSecretSubmitter", "실제 생성 경로가 submitter를 넘긴다: \(type(of: wrapped))")
    }

    // MARK: 끄면 unavailable

    @Test func withoutAHostOrWithBridgeOffTheOutcomeIsUnavailableAndNothingIsSent() async throws {
        let canary = "TF_CANARY_D4BM2_\(UUID().uuidString)"
        let none = BridgeLocalSecretSubmitter(account: { UUID() }, host: { nil })
        let stranger = FakeBridgeServer.Created(commandID: "c", taskID: UUID().uuidString.lowercased(), sessionID: "s", stepID: "x", marker: "m")
        #expect(await none.submit(answer(stranger, value: canary)) == .unavailable)

        let off = HostFixture(enabled: false)
        defer { off.cleanup() }
        await off.start()
        #expect(off.host.activeRuntime == nil)
        #expect(await submitter(off).submit(answer(stranger, value: canary)) == .unavailable)
        #expect(off.server.requests.isEmpty, "꺼졌으면 요청이 하나도 없다")
    }

    // MARK: 끝까지

    @Test func anAnswerGoesThroughTheHostsRuntimeAndTheAgentGetsExactlyTheTypedValue() async throws {
        let (fixture, created) = try await openFixture()
        defer { fixture.cleanup() }
        let canary = "TF_CANARY_D4BM2_\(UUID().uuidString)"
        #expect(await submitter(fixture).submit(answer(created, value: canary)) == .sent)
        fixture.server.notifyChange()
        // 수동 시계가 멈춰 있으므로 한 번 흘리고 목록을 직접 돌린다 (lease → take → 답 훅)
        fixture.clock.jump(by: 6)
        let runtime = try #require(fixture.host.activeRuntime)
        #expect(await fixture.eventually {
            await runtime.tick()
            return fixture.agent.deliveredAnswers.count == 1
        }, "요청: \(fixture.server.requests.map(\.route))")
        #expect(fixture.agent.deliveredAnswers.first?.value.answers == ["q": .one(canary)])
        let requests = fixture.server.requests
        #expect(!requests.contains { $0.bodyJSON.contains(canary) || $0.secret?.contains(canary) == true }, "서버가 받은 요청에 값 0")
        #expect(requests.filter { $0.route == "answer-local" }.count == 1)
        let secrets = try #require(fixture.host.activeSecrets)
        #expect(await fixture.eventually { await secrets.hasPending == false }, "전달 뒤 상자가 비었다")
    }

    // MARK: 계정 경계

    @Test func aQuestionStoreAccountThatIsNotThePartitionsUserSendsNothing() async throws {
        let (fixture, created) = try await openFixture()
        defer { fixture.cleanup() }
        let secrets = try #require(fixture.host.activeSecrets)
        let outcome = await submitter(fixture, account: UUID()).submit(answer(created, value: "TF_CANARY_D4BM2_\(UUID().uuidString)"))
        #expect(outcome == .failed(.generic))
        #expect(fixture.server.requests("answer-local").isEmpty)
        #expect(await secrets.hasPending == false)
    }

    @Test func switchingTheAccountDropsTheValueInMemory() async throws {
        let (fixture, created) = try await openFixture()
        defer { fixture.cleanup() }
        let secrets = try #require(fixture.host.activeSecrets)
        await secrets.put(key: LocalSecretKey(taskID: created.taskID, requestID: Self.requestID), value: AgentAnswerValue(text: "TF_CANARY_D4BM2_\(UUID().uuidString)"))
        #expect(await secrets.hasPending)
        fixture.user.value = UUID()
        fixture.epoch.value += 1
        await fixture.host.syncAccount()
        #expect(await fixture.eventually { await secrets.hasPending == false }, "떠난 계정의 값은 메모리에도 남지 않는다 (D4bm-23)")
    }

    // MARK: 종료

    @Test func quittingDropsAValueThatIsStillWaitingInMemory() async throws {
        let (fixture, created) = try await openFixture()
        defer { fixture.cleanup() }
        let secrets = try #require(fixture.host.activeSecrets)
        await secrets.put(key: LocalSecretKey(taskID: created.taskID, requestID: Self.requestID), value: AgentAnswerValue(text: "TF_CANARY_D4BM2_\(UUID().uuidString)"))
        #expect(await fixture.eventually { fixture.host.isBusy })
        let clock = fixture.advancingClock()
        defer { clock.cancel() }
        #expect(fixture.host.terminationReply() == .terminateLater)
        #expect(await fixture.eventually { fixture.replies == [true] })
        #expect(await secrets.hasPending == false, "종료와 함께 비밀값을 버렸다 (D4bm-22)")
    }

    // MARK: 접근성 (카나리 5항)

    /// 카드와 그 안의 모든 접근성 요소에서 label · value · help · identifier · title · 자리 표시 글을 모은다
    private func accessibilityText(_ root: Any, depth: Int = 0) -> [String] {
        guard depth < 40 else { return [] }
        var out: [String] = []
        if let element = root as? NSAccessibilityProtocol {
            out.append(element.accessibilityLabel() ?? "")
            out.append(element.accessibilityHelp() ?? "")
            out.append(element.accessibilityIdentifier() ?? "")
            out.append(element.accessibilityTitle() ?? "")
            out.append(element.accessibilityPlaceholderValue() ?? "")
            out.append(element.accessibilityValueDescription() ?? "")
            out.append(element.accessibilitySelectedText() ?? "")
            if let value = element.accessibilityValue() { out.append("\(value)") }
            for child in element.accessibilityChildren() ?? [] { out += accessibilityText(child, depth: depth + 1) }
        }
        if let view = root as? NSView { for sub in view.subviews { out += accessibilityText(sub, depth: depth + 1) } }
        return out
    }

    private func allFields(in view: NSView) -> [NSTextField] {
        var found: [NSTextField] = []
        if let field = view as? NSTextField { found.append(field) }
        for sub in view.subviews { found += allFields(in: sub) }
        return found
    }

    final class Got {
        var secrets: [SecretBox] = []
    }

    @Observable
    final class CardModel {
        var status: QuestionCard.Status = .open
        var summary: String?
        var failure: AgentQuestionFailure?
    }

    struct CardRoot: View {
        let model: CardModel
        let got: Got
        var body: some View {
            QuestionCard(
                card: .init(promptID: "q", kind: .secret, title: "Enter the staging deploy token", meta: "Stays on this Mac"), status: model.status, summary: model.summary,
                failure: model.failure, actions: QuestionCardActions(onSubmitSecret: { got.secrets.append($0) })
            )
            .frame(width: 356)
        }
    }

    @Test func theSecretCardTheFoldedRowAndTheFailureLineNeverSpeakTheValue() async throws {
        let canary = "TF_CANARY_D4BM2_\(UUID().uuidString)"
        let got = Got()
        let model = CardModel()
        let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 380, height: 400), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: CardRoot(model: model, got: got))
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        try? await Task.sleep(for: .milliseconds(150))
        let content = try #require(window.contentView)
        let secure = try #require(allFields(in: content).compactMap { $0 as? SecretNSField }.first, "마스크 칸이 있다")

        // 값을 칸에 넣은 채 (보내기 전): 접근성에는 마스크만
        secure.stringValue = canary
        let typed = accessibilityText(content).joined(separator: "\n")
        #expect(!typed.contains(canary), "입력 중에도 접근성 값은 마스크다")
        #expect(typed.contains(AgentQuestionCopy.secretFieldLabel), "양성 대조: 접근성 글을 실제로 읽었다 (칸의 label)")

        // 보낸다: 칸에서 한 번 읽고 곧바로 비운다
        secure.submitValue()
        #expect(got.secrets.count == 1 && got.secrets[0].reveal() == canary, "양성 대조: 값은 정확히 한 번 SecretBox로 나왔다")
        #expect(secure.stringValue.isEmpty, "마스크 칸은 읽은 뒤 비어 있다")
        #expect(secure.undoManager?.canUndo != true && (secure.currentEditor() as? NSTextView)?.undoManager?.canUndo != true, "실행 취소 기록 0")
        #expect(window.undoManager?.canUndo != true)

        // 접힌 줄 (보류 → 보냄) · 실패 줄
        model.status = .holding
        try? await Task.sleep(for: .milliseconds(100))
        let holding = accessibilityText(content).joined(separator: "\n")
        model.status = .sent
        try? await Task.sleep(for: .milliseconds(100))
        let sent = accessibilityText(content).joined(separator: "\n")
        model.status = .open
        model.failure = .offline
        try? await Task.sleep(for: .milliseconds(100))
        let failed = accessibilityText(content).joined(separator: "\n")
        for (name, text) in [("접힌 줄 보류", holding), ("접힌 줄 보냄", sent), ("실패 줄", failed)] {
            #expect(!text.contains(canary), "\(name): 접근성 트리에 카나리 0")
        }
        // 양성 대조: 같은 훑기가 일반 글 칸의 값은 읽는다 (그러니 0은 훑기가 놓친 것이 아니다). SwiftUI 쪽 글(접힌 줄 · 실패 줄)은 이 환경에서 접근성 클라이언트가 없어 트리가 만들어지지 않으므로,
        // 거기에 닿는 입력(`summary` 없음 · 실패는 고정 단어)은 Kit의 `AgentQuestionSecretTests`가 값 0으로 고정한다
        let plain = NSTextField(string: "SENTINEL-PLAIN-FIELD")
        content.addSubview(plain)
        #expect(accessibilityText(content).contains { $0.contains("SENTINEL-PLAIN-FIELD") }, "양성 대조: 훑기는 일반 칸의 값을 읽는다")
        plain.removeFromSuperview()
        let after = allFields(in: content).map(\.stringValue).joined()
        #expect(!after.contains(canary), "어떤 칸에도 값이 없다")
    }
}
