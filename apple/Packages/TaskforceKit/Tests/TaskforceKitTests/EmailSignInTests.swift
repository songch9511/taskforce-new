import Auth
import Foundation
import Synchronization
import Testing
@testable import TaskforceKit

/// 이메일 6자리 코드 로그인 (OA 이메일 로그인 계약 5.1–5.4 · 11.1): 코드 정리 · 주소 검사 · 실패 고르기 · 단계 모델.
/// 실제 메일 · Supabase 0: 가짜 전송(`FakeTransport`)과 주입 시계로 돈다.

// MARK: 코드 정리

struct EmailCodeTests {
    @Test(arguments: [
        ("123456", "123456"),
        ("123 456", "123456"),
        ("123-456", "123456"),
        (" 1 2 3 4 5 6 ", "123456"),
        ("Your code is 123456.", "123456"),
        ("Your Taskforce sign-in code is: 123456\nIt expires in 10 minutes.", "123456"),
        ("code 12 expires in 10 minutes: 123456", "123456"),
        ("１２３４５６", "123456"),
        ("1234567", "123456"),
        ("12345", "12345"),
        ("abc", ""),
        ("", ""),
        ("123456 and 654321", "123456"),
        ("654321 then 123456", "654321"),
        ("code: 12 34", "1234"),
    ])
    func sanitize(_ raw: String, _ expected: String) {
        #expect(EmailCode.sanitize(raw) == expected)
    }

    @Test func aCodeIsSixDigits() {
        #expect(EmailCode.length == 6)
    }

    /// 입력 도중 값도 같은 규칙이다: 한 글자씩 쳐도 숫자만 남고 6자리를 넘지 않는다
    @Test func typingOneCharacterAtATimeNeverExceedsSix() {
        var typed = ""
        for character in "12a3456789" {
            typed = EmailCode.sanitize(typed + String(character))
            #expect(typed.count <= 6)
        }
        #expect(typed == "123456")
    }
}

// MARK: 주소 검사

struct EmailAddressTests {
    @Test(arguments: [
        ("me@example.com", "me@example.com"),
        ("  Me@Example.COM \n", "me@example.com"),
        ("first.last+tag@sub.example.co.kr", "first.last+tag@sub.example.co.kr"),
    ])
    func validAddressesAreTrimmedAndLowercased(_ raw: String, _ expected: String) {
        #expect(EmailAddress.normalize(raw) == expected)
    }

    @Test(arguments: ["", "   ", "plain", "no-at.example.com", "a@b", "a@b.", "a@.co", "@b.co", "a b@c.co", "a@b c.co", "a@@b.co", "a@b@c.co", "a@b..co", "a@-b.co"])
    func invalidAddressesAreRejected(_ raw: String) {
        #expect(EmailAddress.normalize(raw) == nil, "\(raw)")
    }
}

// MARK: 게이트

struct EmailSignInGateTests {
    @Test func onlyYesOpensTheGate() {
        #expect(EmailSignInGate.isEnabled(infoDictionary: ["EmailSignInEnabled": "YES"]))
        for value in ["NO", "yes", "true", "", "$(EMAIL_SIGN_IN_ENABLED)", "1"] {
            #expect(!EmailSignInGate.isEnabled(infoDictionary: ["EmailSignInEnabled": value]), "\(value)")
        }
        #expect(!EmailSignInGate.isEnabled(infoDictionary: [:]))
        #expect(!EmailSignInGate.isEnabled(infoDictionary: nil))
        #expect(!EmailSignInGate.isEnabled(infoDictionary: ["EmailSignInEnabled": true]))
    }
}

// MARK: 실패 고르기

struct EmailSignInFailureTests {
    func api(_ status: Int, _ code: String) -> AuthError {
        .api(message: code, errorCode: ErrorCode(code), underlyingData: Data(),
             underlyingResponse: HTTPURLResponse(url: URL(string: "https://example.invalid/auth/v1")!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }

    @Test func verifyingPicksOneInputErrorForWrongAndExpiredCodes() {
        #expect(EmailSignInFailure.forVerify(api(403, "otp_expired")) == .wrongOrExpiredCode)
        #expect(EmailSignInFailure.forVerify(api(400, "validation_failed")) == .wrongOrExpiredCode)
        #expect(EmailSignInFailure.forVerify(api(422, "unexpected_failure")) == .wrongOrExpiredCode)
    }

    @Test func verifyingTooOftenIsRateLimited() {
        #expect(EmailSignInFailure.forVerify(api(429, "over_request_rate_limit")) == .rateLimited)
        #expect(EmailSignInFailure.forVerify(api(429, "anything")) == .rateLimited)
        #expect(EmailSignInFailure.forVerify(api(400, "over_request_rate_limit")) == .rateLimited)
    }

    @Test func noConnectionIsOffline() {
        #expect(EmailSignInFailure.forVerify(URLError(.notConnectedToInternet)) == .offline)
        #expect(EmailSignInFailure.forSend(URLError(.timedOut)) == .offline)
    }

    @Test func sendingARejectedAddressIsBlockedAndOtherRefusalsAreNot() {
        // 가입 훅이 일회용 도메인을 거절하면 403
        #expect(EmailSignInFailure.forSend(api(403, "unexpected_failure")) == .blockedAddress)
        #expect(EmailSignInFailure.forSend(api(403, "hook_failed")) == .blockedAddress)
        #expect(EmailSignInFailure.forSend(api(400, "email_address_invalid")) == .blockedAddress)
        #expect(EmailSignInFailure.forSend(api(400, "email_address_not_authorized")) == .blockedAddress)
        #expect(EmailSignInFailure.forSend(api(500, "unexpected_failure")) == .sendFailed)
        #expect(EmailSignInFailure.forSend(api(422, "email_provider_disabled")) == .sendFailed)
        #expect(EmailSignInFailure.forSend(api(400, "validation_failed")) == .sendFailed)
    }

    @Test func sendingTooOftenOrOverTheDailyCapIsRateLimited() {
        #expect(EmailSignInFailure.forSend(api(429, "over_email_send_rate_limit")) == .rateLimited)
        #expect(EmailSignInFailure.forSend(api(429, "over_request_rate_limit")) == .rateLimited)
        // 가입 상한 훅 (429) · 메일 공급자의 하루 상한을 Supabase가 429로 전하는 경우
        #expect(EmailSignInFailure.forSend(api(429, "unexpected_failure")) == .rateLimited)
        #expect(EmailSignInFailure.forSend(api(400, "over_email_send_rate_limit")) == .rateLimited)
    }

    @Test func unknownErrorsAreTheGenericOnes() {
        struct Odd: Error {}
        #expect(EmailSignInFailure.forSend(Odd()) == .sendFailed)
        #expect(EmailSignInFailure.forVerify(Odd()) == .wrongOrExpiredCode)
    }

    /// 화면 줄: 모두 조용한 회색 한 줄이다 (빨강 없음). 보내기 실패 · 한도 · 확인 한도 · 다시 받기 실패는 한 줄로 합친다
    @Test func everyFailureShowsOneQuietLineAndTheLimitsAreMergedWithTheFailures() {
        #expect(EmailSignInFailure.wrongOrExpiredCode.line == .wrongCode)
        #expect(EmailSignInFailure.blockedAddress.line == .addressBlocked)
        #expect(EmailSignInFailure.rateLimited.line == .couldntContinue)
        #expect(EmailSignInFailure.sendFailed.line == .couldntContinue)
        #expect(EmailSignInFailure.offline.line == .offline)
        #expect(EmailSignInFailure.notSaved.line == .notSaved)
    }

    /// 줄의 글: 승인된 문구 그대로. 연결 · 저장 실패는 앱에 이미 있는 문구다
    @Test func theLinesSpeakTheApprovedWords() {
        #expect(EmailSignInLine.addressInvalid.text == "Add the full address, like jordan@example.com.")
        #expect(EmailSignInLine.addressBlocked.text == "This address can't be used. Try another one.")
        #expect(EmailSignInLine.wrongCode.text == "That code didn't work. Try the latest email.")
        #expect(EmailSignInLine.couldntContinue.text == "Couldn't continue. Try again in a few minutes.")
        #expect(EmailSignInLine.offline.text == "Can't reach the sign-in service. Check your connection.")
        #expect(EmailSignInLine.notSaved.text == "Couldn't save your sign-in. Try again.")
        #expect(EmailSignInStatus.codeSent.text(address: "me@example.com") == "Code sent to me@example.com")
        #expect(EmailSignInStatus.newCodeSent.text(address: "me@example.com") == "New code sent to me@example.com")
    }

    /// 로그에는 고정 낱말만 간다 (이메일 · 코드가 들어갈 틈이 없다)
    @Test func logCodesAreFixedWords() {
        let all: [EmailSignInFailure] = [.wrongOrExpiredCode, .rateLimited, .blockedAddress, .sendFailed, .offline, .notSaved]
        #expect(all.map(\.logCode) == ["wrong_code", "rate_limited", "blocked_address", "send_failed", "offline", "not_saved"])
    }
}

// MARK: 모델

/// 응답을 붙들어 두고 풀 수 있는 문 (한 번)
private actor Gate {
    private var entered = false
    private var released = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func pass() async {
        entered = true
        if released { return }
        await withCheckedContinuation { waiting.append($0) }
    }

    func release() {
        released = true
        for continuation in waiting { continuation.resume() }
        waiting = []
    }

    /// 문에 닿을 때까지 기다린다 (제한 시간은 실패를 알리려는 것일 뿐, 고정 대기가 아니다)
    func waitUntilEntered(timeout: Duration = .seconds(60)) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while !entered, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(5)) }
        return entered
    }
}

/// 주입 시계
private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = Date(timeIntervalSince1970: 1_800_000_000)
    var now: Date { lock.withLock { current } }
    func advance(_ seconds: TimeInterval) { lock.withLock { current = current.addingTimeInterval(seconds) } }
}

@MainActor
private final class FakeTransport: EmailCodeTransport {
    var sends: [String] = []
    var verifies: [(email: String, code: String)] = []
    var sendResults: [EmailCodeSendResult] = []
    var verifyResults: [EmailCodeVerifyResult] = []
    var sendGate: Gate?
    var verifyGate: Gate?

    func sendEmailCode(email: String) async -> EmailCodeSendResult {
        sends.append(email)
        await sendGate?.pass()
        return sendResults.isEmpty ? .sent : sendResults.removeFirst()
    }

    func verifyEmailCode(email: String, code: String) async -> EmailCodeVerifyResult {
        verifies.append((email, code))
        await verifyGate?.pass()
        return verifyResults.isEmpty ? .signedIn : verifyResults.removeFirst()
    }
}

@MainActor
struct EmailSignInModelTests {
    fileprivate let clock = TestClock()
    fileprivate let transport = FakeTransport()

    func makeModel() -> EmailSignInModel {
        let model = EmailSignInModel(transport: transport, now: { [clock] in clock.now })
        return model
    }

    /// 이메일 단계에서 주소를 보내 코드 단계까지
    func atTheCodeStep(_ model: EmailSignInModel, address: String = "me@example.com") async {
        model.begin()
        model.emailInput = address
        model.submitEmail()
        await model.settled()
    }

    // MARK: 단계

    @Test func theFlowGoesFromTheMethodsToTheEmailToTheCode() async {
        let model = makeModel()
        #expect(model.step == .methods)
        model.begin()
        #expect(model.step == .email)
        model.emailInput = "  Me@Example.COM "
        model.submitEmail()
        #expect(model.isSending)
        await model.settled()
        #expect(model.step == .code)
        #expect(model.address == "me@example.com")
        #expect(model.status == .codeSent)
        #expect(model.line == nil)
        #expect(model.codeInput.isEmpty)
        #expect(!model.isSending)
        #expect(transport.sends == ["me@example.com"])
    }

    @Test func backFromTheEmailStepGoesToTheFirstScreenAndForgetsTheInput() {
        let model = makeModel()
        model.begin()
        model.emailInput = "me@example.com"
        model.back()
        #expect(model.step == .methods)
        #expect(model.emailInput.isEmpty)
    }

    @Test func useADifferentEmailGoesBackWithTheAddressFilledIn() async {
        let model = makeModel()
        await atTheCodeStep(model)
        model.setCode("12")
        model.useDifferentEmail()
        #expect(model.step == .email)
        #expect(model.emailInput == "me@example.com")
        #expect(model.codeInput.isEmpty)
        #expect(model.status == nil)
        #expect(model.resendAvailableAt == nil && model.expiresAt == nil)
    }

    @Test func aSuccessfulSignInEmptiesTheModel() async {
        let model = makeModel()
        await atTheCodeStep(model)
        model.setCode("123456")
        await model.settled()
        #expect(transport.verifies.map(\.code) == ["123456"])
        #expect(transport.verifies.map(\.email) == ["me@example.com"])
        #expect(model.step == .methods)
        #expect(model.emailInput.isEmpty && model.address.isEmpty && model.codeInput.isEmpty)
        #expect(!model.isVerifying)
    }

    @Test func theSharedModelIsOne() {
        #expect(EmailSignInModel.shared === EmailSignInModel.shared)
    }

    // MARK: 주소 검사

    @Test(arguments: ["", "no-at", "a@b", "a@b.", "@b.co", "a b@c.co"])
    func anInvalidAddressNeverCallsTheServer(_ input: String) {
        let model = makeModel()
        model.begin()
        model.emailInput = input
        model.submitEmail()
        #expect(model.line == .addressInvalid)
        #expect(model.step == .email)
        #expect(!model.isSending)
        #expect(transport.sends.isEmpty)
    }

    @Test func fixingTheAddressClearsTheInputError() async {
        let model = makeModel()
        model.begin()
        model.emailInput = "nope"
        model.submitEmail()
        #expect(model.line == .addressInvalid)
        model.emailInput = "me@example.com"
        model.submitEmail()
        await model.settled()
        #expect(model.line == nil)
        #expect(model.step == .code)
    }

    @Test func sendingTwiceAtOnceSendsOnce() async {
        let model = makeModel()
        let gate = Gate()
        transport.sendGate = gate
        model.begin()
        model.emailInput = "me@example.com"
        model.submitEmail()
        model.submitEmail()
        #expect(await gate.waitUntilEntered())
        model.submitEmail()
        await gate.release()
        await model.settled()
        #expect(transport.sends.count == 1)
    }

    // MARK: 코드 · 자동 확인

    @Test func sixDigitsVerifyExactlyOnceAndTheSameValueNeverAgain() async {
        let model = makeModel()
        await atTheCodeStep(model)
        transport.verifyResults = [.failed(.wrongOrExpiredCode)]
        model.setCode("12345")
        #expect(transport.verifies.isEmpty)
        model.setCode("123456")
        await model.settled()
        #expect(transport.verifies.count == 1)
        // 같은 값을 다시 넣어도 부르지 않는다
        model.setCode("123456")
        model.setCode("123 456")
        await model.settled()
        #expect(transport.verifies.count == 1)
        // 값을 바꾸면 다시 한 번
        model.setCode("654321")
        await model.settled()
        #expect(transport.verifies.map(\.code) == ["123456", "654321"])
    }

    @Test func theSameCodeIsNotVerifiedTwiceWhileTheFirstIsStillOut() async {
        let model = makeModel()
        await atTheCodeStep(model)
        let gate = Gate()
        transport.verifyGate = gate
        model.setCode("123456")
        #expect(await gate.waitUntilEntered())
        #expect(model.isVerifying)
        model.setCode("123456")
        model.setCode("111111")
        model.submitCode()
        await gate.release()
        await model.settled()
        #expect(transport.verifies.count == 1)
    }

    @Test func aPastedSentenceIsCleanedAndVerified() async {
        let model = makeModel()
        await atTheCodeStep(model)
        model.setCode("Your code is 123456.")
        await model.settled()
        #expect(transport.verifies.map(\.code) == ["123456"])
    }

    @Test func returnOrSignInVerifiesTheSameWayAndFewerDigitsDoNothing() async {
        let model = makeModel()
        await atTheCodeStep(model)
        transport.verifyResults = [.failed(.wrongOrExpiredCode), .signedIn]
        model.setCode("12345")
        model.submitCode()
        #expect(transport.verifies.isEmpty)
        model.setCode("123456")
        await model.settled()
        #expect(transport.verifies.count == 1)
        // 틀린 코드를 다시 한 번 눌러 보는 것은 사용자가 시킨 일이다
        model.submitCode()
        await model.settled()
        #expect(transport.verifies.count == 2)
        #expect(model.step == .methods)
    }

    @Test func editingTheCodeAfterAMissClearsTheErrorAndAllowsTheSameValueAgain() async {
        let model = makeModel()
        await atTheCodeStep(model)
        transport.verifyResults = [.failed(.wrongOrExpiredCode)]
        model.setCode("123456")
        await model.settled()
        #expect(model.line == .wrongCode)
        model.setCode("1")
        #expect(model.line == nil)
        model.setCode("123456")
        await model.settled()
        #expect(transport.verifies.count == 2)
    }

    /// Sign in은 6자리가 들어올 때까지 막힌다. 확인하는 중에도 막힌다 (틀린 뒤에는 6자리가 그대로라 다시 열린다)
    @Test func signInStaysDisabledUntilSixDigitsAndWhileSomethingIsOut() async {
        let model = makeModel()
        #expect(!model.canSubmitCode)
        await atTheCodeStep(model)
        #expect(!model.canSubmitCode)
        model.setCode("48291")
        #expect(!model.canSubmitCode)
        let gate = Gate()
        transport.verifyGate = gate
        transport.verifyResults = [.failed(.wrongOrExpiredCode)]
        model.setCode("482916")
        #expect(await gate.waitUntilEntered())
        #expect(!model.canSubmitCode)
        await gate.release()
        await model.settled()
        #expect(model.canSubmitCode, "틀린 뒤에는 다시 눌러 볼 수 있다 (앱은 횟수로 막지 않는다)")
    }

    // MARK: 오류 고르기

    @Test func aWrongCodeIsOneQuietLineAndTheFieldIsSelectedForRetyping() async {
        let model = makeModel()
        await atTheCodeStep(model)
        transport.verifyResults = [.failed(.wrongOrExpiredCode)]
        let before = model.selectAllRequests
        model.setCode("123456")
        await model.settled()
        #expect(model.line == .wrongCode)
        #expect(model.selectAllRequests == before + 1)
        #expect(model.codeInput == "123456")
        #expect(!model.isVerifying)
        #expect(model.step == .code)
    }

    @Test func tooManyTriesIsAQuietLineAndTheFieldStaysAsItWas() async {
        let model = makeModel()
        await atTheCodeStep(model)
        transport.verifyResults = [.failed(.rateLimited)]
        let before = model.selectAllRequests
        model.setCode("123456")
        await model.settled()
        #expect(model.line == .couldntContinue)
        #expect(model.selectAllRequests == before)
    }

    @Test func noConnectionWhileVerifyingIsAQuietLine() async {
        let model = makeModel()
        await atTheCodeStep(model)
        transport.verifyResults = [.failed(.offline)]
        model.setCode("123456")
        await model.settled()
        #expect(model.line == .offline)
    }

    @Test(arguments: [
        (EmailSignInFailure.blockedAddress, EmailSignInLine.addressBlocked),
        (.rateLimited, .couldntContinue),
        (.sendFailed, .couldntContinue),
        (.offline, .offline),
    ])
    func eachSendFailureShowsItsLineAndStaysOnTheEmailStep(_ failure: EmailSignInFailure, _ line: EmailSignInLine) async {
        let model = makeModel()
        model.begin()
        model.emailInput = "me@example.com"
        transport.sendResults = [.failed(failure)]
        model.submitEmail()
        await model.settled()
        #expect(model.line == line)
        #expect(model.step == .email)
        #expect(!model.isSending)
        #expect(model.resendAvailableAt == nil)
        // 다시 보내면 지난 줄이 사라진다
        model.submitEmail()
        await model.settled()
        #expect(model.line == nil)
        #expect(model.step == .code)
    }

    // MARK: 다시 받기

    @Test func resendIsLockedForSixtySecondsThenOpens() async {
        let model = makeModel()
        await atTheCodeStep(model)
        #expect(!model.canResend(at: clock.now))
        #expect(model.resendSecondsLeft(at: clock.now) == 60)
        clock.advance(17.2)
        #expect(!model.canResend(at: clock.now))
        #expect(model.resendSecondsLeft(at: clock.now) == 43)
        clock.advance(42.7)
        #expect(!model.canResend(at: clock.now))
        #expect(model.resendSecondsLeft(at: clock.now) == 1)
        clock.advance(0.2)
        #expect(model.canResend(at: clock.now))
        #expect(model.resendSecondsLeft(at: clock.now) == 0)
    }

    @Test func resendBeforeSixtySecondsDoesNothing() async {
        let model = makeModel()
        await atTheCodeStep(model)
        clock.advance(59)
        model.resend()
        await model.settled()
        #expect(transport.sends.count == 1)
        #expect(model.status == .codeSent)
    }

    @Test func resendAtSixtySecondsSendsOnceMoreAndStartsTheClockAgain() async {
        let model = makeModel()
        await atTheCodeStep(model)
        model.setCode("12")
        clock.advance(60)
        model.resend()
        #expect(model.isSending)
        await model.settled()
        #expect(transport.sends == ["me@example.com", "me@example.com"])
        #expect(model.status == .newCodeSent)
        #expect(model.codeInput.isEmpty)
        #expect(model.step == .code)
        #expect(!model.canResend(at: clock.now))
        clock.advance(60)
        #expect(model.canResend(at: clock.now))
    }

    @Test func aFailedResendKeepsTheCodeStepAndShowsTheLine() async {
        let model = makeModel()
        await atTheCodeStep(model)
        clock.advance(60)
        transport.sendResults = [.failed(.rateLimited)]
        model.resend()
        await model.settled()
        #expect(model.step == .code)
        #expect(model.line == .couldntContinue)
        #expect(model.status == .codeSent)
        // 보내지 못했으니 시계는 그대로 열려 있다
        #expect(model.canResend(at: clock.now))
    }

    // MARK: 만료

    @Test func theModelEmptiesTenMinutesAfterTheCodeWasSent() async {
        let model = makeModel()
        await atTheCodeStep(model)
        clock.advance(599)
        model.refresh()
        #expect(model.step == .code)
        clock.advance(1)
        model.refresh()
        #expect(model.step == .methods)
        #expect(model.address.isEmpty)
    }

    @Test func aResendStartsTheTenMinutesAgain() async {
        let model = makeModel()
        await atTheCodeStep(model)
        clock.advance(300)
        model.resend()
        await model.settled()
        clock.advance(400)
        model.refresh()
        #expect(model.step == .code)
        clock.advance(200)
        model.refresh()
        #expect(model.step == .methods)
    }

    // MARK: 흐름을 떠난 뒤 늦게 온 답

    @Test func aLateWrongCodeAfterLeavingTheStepIsNotShown() async {
        let model = makeModel()
        await atTheCodeStep(model)
        let gate = Gate()
        transport.verifyGate = gate
        transport.verifyResults = [.failed(.wrongOrExpiredCode)]
        model.setCode("123456")
        #expect(await gate.waitUntilEntered())
        model.useDifferentEmail()
        await gate.release()
        await model.settled()
        #expect(model.step == .email)
        #expect(model.line == nil)
        #expect(!model.isVerifying)
    }

    @Test func aLateSendAnswerAfterBackIsDropped() async {
        let model = makeModel()
        let gate = Gate()
        transport.sendGate = gate
        model.begin()
        model.emailInput = "me@example.com"
        model.submitEmail()
        #expect(await gate.waitUntilEntered())
        model.back()
        await gate.release()
        await model.settled()
        #expect(model.step == .methods)
        #expect(model.status == nil)
    }

    /// 코드를 넣고 로그인은 됐는데 그 사이 화면은 다른 단계로 갔다: 로그인이 끝났으니 모델은 비운다
    @Test func aSignInThatLandsAfterLeavingEmptiesTheModel() async {
        let model = makeModel()
        await atTheCodeStep(model)
        let gate = Gate()
        transport.verifyGate = gate
        model.setCode("123456")
        #expect(await gate.waitUntilEntered())
        model.useDifferentEmail()
        await gate.release()
        await model.settled()
        #expect(model.step == .methods)
        #expect(model.emailInput.isEmpty && model.codeInput.isEmpty)
    }

    // MARK: 기록

    @Test func outcomesAreFixedWordsOnly() async {
        let model = makeModel()
        var outcomes: [EmailSignInOutcome] = []
        model.outcomeSink = { outcomes.append($0) }
        await atTheCodeStep(model)
        transport.verifyResults = [.failed(.wrongOrExpiredCode), .signedIn]
        model.setCode("123456")
        await model.settled()
        model.setCode("654321")
        await model.settled()
        #expect(outcomes == [.sent, .verifyFailed("wrong_code"), .verified])
    }

    @Test func aSendFailureIsLoggedAsItsWord() async {
        let model = makeModel()
        var outcomes: [EmailSignInOutcome] = []
        model.outcomeSink = { outcomes.append($0) }
        model.begin()
        model.emailInput = "me@example.com"
        transport.sendResults = [.failed(.blockedAddress)]
        model.submitEmail()
        await model.settled()
        #expect(outcomes == [.sendFailed("blocked_address")])
    }

    @Test func leavingBeforeTheAnswerIsLoggedAsCanceled() async {
        let model = makeModel()
        var outcomes: [EmailSignInOutcome] = []
        model.outcomeSink = { outcomes.append($0) }
        await atTheCodeStep(model)
        let gate = Gate()
        transport.verifyGate = gate
        transport.verifyResults = [.failed(.wrongOrExpiredCode)]
        model.setCode("123456")
        #expect(await gate.waitUntilEntered())
        model.useDifferentEmail()
        await gate.release()
        await model.settled()
        #expect(outcomes == [.sent, .verifyCanceled])
    }
}

// MARK: 세션과 이음

private struct EmptyStorage: AuthLocalStorage {
    func store(key: String, value: Data) throws {}
    func retrieve(key: String) throws -> Data? { nil }
    func remove(key: String) throws {}
}

/// 세션 하나가 저장돼 있는 저장소
private struct SavedSessionStorage: AuthLocalStorage {
    let data: Data
    func store(key: String, value: Data) throws {}
    func retrieve(key: String) throws -> Data? { data }
    func remove(key: String) throws {}
}

@MainActor
struct EmailSignInSessionTests {
    func makeStore(storage: any AuthLocalStorage = EmptyStorage()) -> SessionStore {
        SessionStore(auth: AuthClient(url: URL(string: "https://example.supabase.co/auth/v1")!, localStorage: storage,
            fetch: { _ in throw URLError(.notConnectedToInternet) }, autoRefreshToken: false))
    }

    func session(_ id: UUID) -> Session {
        let user = User(id: id, appMetadata: [:], userMetadata: [:], aud: "authenticated", email: "me@example.com", createdAt: Date(), updatedAt: Date())
        return Session(accessToken: "access", tokenType: "bearer", expiresIn: 3600, expiresAt: Date().addingTimeInterval(3600).timeIntervalSince1970,
            refreshToken: "refresh", user: user)
    }

    /// 계정이 이 기기를 떠나면(로그아웃 · 만료 · 다른 계정) 코드 단계를 남기지 않는다
    @Test func leavingAnAccountEmptiesTheModel() async throws {
        let id = UUID()
        let value = session(id)
        let store = makeStore(storage: SavedSessionStorage(data: try JSONEncoder().encode(value)))
        let transport = FakeTransport()
        let model = EmailSignInModel(transport: transport)
        model.begin()
        model.emailInput = "me@example.com"
        model.submitEmail()
        await model.settled()
        #expect(model.step == .code)
        // 앱은 세션을 붙인다 (두 번 붙여도 한 번만 듣는다)
        model.attach(to: store)
        model.attach(to: store)

        // 다른 방법(Apple 등)으로 로그인했다가 로그아웃
        store.apply(event: .signedIn, session: value)
        #expect(model.step == .code)
        store.apply(event: .signedOut, session: nil)
        #expect(model.step == .methods)
    }

    @Test func attachingGivesTheModelItsSessionAsTheSender() async {
        let model = EmailSignInModel()
        model.begin()
        model.emailInput = "me@example.com"
        model.submitEmail()
        await model.settled()
        // 전송이 없으면 보낼 수 없다: 조용한 실패 줄
        #expect(model.step == .email)
        #expect(model.line == .couldntContinue)
        let store = makeStore()
        model.attach(to: store)
        model.submitEmail()
        await model.settled()
        // 가짜 세션 저장소의 인증 서버는 오프라인이다
        #expect(model.line == .offline)
    }
}
