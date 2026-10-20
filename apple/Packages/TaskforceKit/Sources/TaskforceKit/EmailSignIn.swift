import Auth
import Foundation
import Observation

// 이메일 6자리 코드 로그인 (OA 이메일 로그인 계약 5.1–5.4). 화면 없는 규칙: 게이트 · 주소 검사 · 코드 정리 · 실패 고르기 · 단계 모델.
// Supabase가 코드를 메일로 보내고(`SessionStore.sendEmailCode`) 코드를 넣으면 로그인한다(`verifyEmailCode`).
// 화면의 글(사용자 승인 2026-10-20)은 `SignInCopy`에 있고, 여기서는 상태 · 줄을 글로 바꾸는 길만 둔다 (`EmailSignInLine.text` · `EmailSignInStatus.text`).

/// 이메일 로그인 입구를 보일지: Info.plist `EmailSignInEnabled` ← `$(EMAIL_SIGN_IN_ENABLED)`. Debug는 YES, Release는 NO로 커밋한다
/// (법률 게시 · Resend 도메인 확인과 Pro 전환 · 훅 마이그레이션 적용이 끝난 날 YES로 바꾼다). 값이 정확히 "YES"일 때만 연다.
public enum EmailSignInGate {
    public static let infoKey = "EmailSignInEnabled"

    public static func isEnabled(infoDictionary: [String: Any]?) -> Bool {
        (infoDictionary?[infoKey] as? String) == "YES"
    }
}

/// 이메일 칸에 쓴 글 → 서버에 보낼 주소. 앞뒤 공백을 지우고 소문자로 맞춘다. `@` 하나와 그 뒤 점 있는 도메인이 없으면 nil (서버를 부르지 않는다)
public enum EmailAddress {
    public static func normalize(_ raw: String) -> String? {
        let address = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !address.isEmpty, address.count <= 254, !address.contains(where: \.isWhitespace) else { return nil }
        let parts = address.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty else { return nil }
        let labels = parts[1].split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2, labels.allSatisfy({ !$0.isEmpty && !$0.hasPrefix("-") && !$0.hasSuffix("-") }) else { return nil }
        return address
    }
}

/// 코드 칸에 들어오는 글(입력 · 붙여 넣기 · 자동 채우기)을 6자리 숫자로 정리한다
public enum EmailCode {
    public static let length = 6

    /// - 전각 숫자는 ASCII로 바꾼다
    /// - 글 안에 숫자 6개가 이어진 덩어리가 정확히 하나면 그것을 쓴다 ("Your code is 123456." → "123456")
    /// - 그 밖에는 숫자만 모아 앞 6자리까지만 둔다 ("123 456" · "123-456" → "123456", "1234567" → "123456")
    public static func sanitize(_ raw: String) -> String {
        var runs: [String] = []
        var current = ""
        for scalar in raw.unicodeScalars {
            if scalar.properties.generalCategory == .decimalNumber, let value = scalar.properties.numericValue, value >= 0, value <= 9 {
                current.append(String(Int(value)))
            } else if !current.isEmpty {
                runs.append(current)
                current = ""
            }
        }
        if !current.isEmpty { runs.append(current) }
        let exactlySix = runs.filter { $0.count == length }
        if exactlySix.count == 1 { return exactlySix[0] }
        return String(runs.joined().prefix(length))
    }
}

/// 보내기 · 확인이 실패한 이유. 서버가 준 설명 · 오류 코드는 화면에 싣지 않는다 (이 낱말 하나로 문구를 고른다)
public enum EmailSignInFailure: Equatable, Sendable {
    /// 틀린 코드와 만료된 코드: 서버가 구별하지 않는다 (`otp_expired`)
    case wrongOrExpiredCode
    /// 너무 자주 (HTTP 429, 메일 발송 한도, 메일 공급자의 하루 상한을 Supabase가 429로 전할 때)
    case rateLimited
    /// 가입 훅이 거절한 주소 (일회용 도메인) 또는 서버가 주소를 받지 않음
    case blockedAddress
    case sendFailed
    case offline
    /// 서버는 로그인시켰지만 이 기기에 세션을 저장하지 못했다
    case notSaved

    /// 보내기 실패: 429 · 속도 제한 코드는 한도, 403(가입 훅) · 주소 오류 코드는 막힌 주소, 연결 실패, 그 밖
    public static func forSend(_ error: Error) -> EmailSignInFailure {
        if error is URLError { return .offline }
        guard case let AuthError.api(_, code, _, response) = error else { return .sendFailed }
        if isRateLimited(code: code, status: response.statusCode) { return .rateLimited }
        if response.statusCode == 403 || code == ErrorCode("email_address_invalid") || code == .emailAddressNotAuthorized { return .blockedAddress }
        return .sendFailed
    }

    /// 확인 실패: 한도 · 연결 실패가 아니면 모두 틀리거나 만료된 코드로 알린다 (서버가 구별하지 않는다)
    public static func forVerify(_ error: Error) -> EmailSignInFailure {
        if error is URLError { return .offline }
        if case let AuthError.api(_, code, _, response) = error, isRateLimited(code: code, status: response.statusCode) { return .rateLimited }
        return .wrongOrExpiredCode
    }

    private static func isRateLimited(code: ErrorCode, status: Int) -> Bool {
        status == 429 || code == .overEmailSendRateLimit || code == .overRequestRateLimit
    }

    /// 화면에 보일 줄
    public var line: EmailSignInLine {
        switch self {
        case .wrongOrExpiredCode: .wrongCode
        // 보내기 실패 · 보내기 한도 · 확인 한도 · 다시 받기 실패는 한 줄이다 (어느 쪽이든 사용자가 할 일은 잠시 뒤 다시)
        case .rateLimited, .sendFailed: .couldntContinue
        case .blockedAddress: .addressBlocked
        case .offline: .offline
        case .notSaved: .notSaved
        }
    }

    /// 로그에 남기는 고정 낱말 (이메일 · 코드가 들어갈 틈이 없다)
    public var logCode: String {
        switch self {
        case .wrongOrExpiredCode: "wrong_code"
        case .rateLimited: "rate_limited"
        case .blockedAddress: "blocked_address"
        case .sendFailed: "send_failed"
        case .offline: "offline"
        case .notSaved: "not_saved"
        }
    }
}

/// 이메일 · 코드 단계에서 칸 아래에 보이는 한 줄. 모두 조용한 회색 힌트다 (빨강 없음, 사용자 결정 2026-10-20)
public enum EmailSignInLine: Equatable, Sendable {
    case addressInvalid
    case addressBlocked
    case wrongCode
    /// 보내기 실패 · 한도 · 확인 한도 · 다시 받기 실패를 합친 한 줄
    case couldntContinue
    case offline
    case notSaved

    public var text: String {
        switch self {
        case .addressInvalid: SignInCopy.addressInvalid
        case .addressBlocked: SignInCopy.addressBlocked
        case .wrongCode: SignInCopy.wrongCode
        case .couldntContinue: SignInCopy.couldntContinue
        case .offline: SessionStore.offlineMessage
        case .notSaved: SessionStore.sessionNotSavedMessage
        }
    }
}

public enum EmailCodeSendResult: Equatable, Sendable {
    case sent
    case failed(EmailSignInFailure)
}

public enum EmailCodeVerifyResult: Equatable, Sendable {
    case signedIn
    case failed(EmailSignInFailure)
    /// 부르지 않았거나 결과를 쓰지 않는다: 로그아웃 상태가 아니었거나, 기다리는 사이 다른 계정이 들어왔다
    case ignored
}

/// 코드를 보내고 확인하는 쪽 (앱은 `SessionStore`, 시험은 가짜)
@MainActor
public protocol EmailCodeTransport: AnyObject {
    func sendEmailCode(email: String) async -> EmailCodeSendResult
    func verifyEmailCode(email: String, code: String) async -> EmailCodeVerifyResult
}

extension SessionStore: EmailCodeTransport {}

/// 코드 단계의 상태 줄
public enum EmailSignInStatus: Equatable, Sendable {
    case codeSent
    case newCodeSent

    public func text(address: String) -> String {
        switch self {
        case .codeSent: SignInCopy.codeSent(to: address)
        case .newCodeSent: SignInCopy.newCodeSent(to: address)
        }
    }
}

/// 로그(`SignInLog`)에 남기는 결과: 고정 낱말뿐
public enum EmailSignInOutcome: Equatable, Sendable {
    case sent
    case sendFailed(String)
    case verified
    case verifyFailed(String)
    /// 답이 오기 전에 사용자가 그 단계를 떠났거나, 로그인 상태가 바뀌어 결과를 쓰지 않았다
    case verifyCanceled
}

/// 이메일 로그인 화면의 단계와 입력 (모델은 한 개: 설정 창을 닫았다 열어도 코드 단계가 남는다).
/// 메서드는 화면 동작이라 바로 돌아오고, 서버 호출은 안에서 이어 간다(`settled()`가 끝을 기다린다: 시험).
/// 흐름을 떠나면(Back · 다른 이메일 · 성공 · 계정이 떠남 · 10분) `generation`이 올라 그 전에 시작한 늦은 답은 쓰지 않는다.
@MainActor
@Observable
public final class EmailSignInModel {
    public enum Step: Equatable, Sendable {
        /// 첫 화면 (Apple · Google · 이메일 입구)
        case methods
        case email
        case code
    }

    public static let shared = EmailSignInModel()

    /// 같은 주소로 다시 받기를 막는 시간 (서버 규칙과 같다)
    public static let resendWait: TimeInterval = 60
    /// 코드가 살아 있는 시간 (Supabase `otp_expiry` 600초). 이 시간이 지나면 모델을 비운다
    public static let codeLifetime: TimeInterval = 600

    public private(set) var step: Step = .methods
    /// 이메일 칸의 글
    public var emailInput = ""
    /// 코드를 보낸 주소 (코드 단계)
    public private(set) var address = ""
    /// 코드 칸의 글 (정리된 숫자)
    public private(set) var codeInput = ""
    public private(set) var status: EmailSignInStatus?
    public private(set) var line: EmailSignInLine?
    public private(set) var isSending = false
    public private(set) var isVerifying = false
    public private(set) var resendAvailableAt: Date?
    public private(set) var expiresAt: Date?
    /// 오를 때마다 화면이 코드 칸 글을 전체 선택한다 (틀린 코드를 바로 다시 칠 수 있게)
    public private(set) var selectAllRequests = 0

    /// 흐름을 떠날 때마다 오른다
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var transport: (any EmailCodeTransport)?
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private var lastAttempt: String?
    @ObservationIgnored private var pending: Task<Void, Never>?
    @ObservationIgnored private var attached: Set<ObjectIdentifier> = []
    /// 결과 코드를 로그로 보내는 입구 (앱이 `SignInLog`로 잇는다)
    @ObservationIgnored public var outcomeSink: (@MainActor (EmailSignInOutcome) -> Void)?

    public init(transport: (any EmailCodeTransport)? = nil, now: @escaping @Sendable () -> Date = { Date() }) {
        self.transport = transport
        self.now = now
    }

    /// 이 세션으로 보내고 확인한다. 계정이 이 기기를 떠날 때마다(로그아웃 · 만료 · 다른 계정) 모델을 비운다:
    /// 다른 방법으로 로그인했다가 나왔을 때 지난 코드 단계가 남아 있지 않게
    public func attach(to session: SessionStore) {
        transport = session
        guard attached.insert(ObjectIdentifier(session)).inserted else { return }
        session.onSignedOut { [weak self] _ in self?.reset() }
    }

    // MARK: 단계

    /// 첫 화면의 "Continue with email" → 이메일 단계
    public func begin() {
        guard step == .methods else { return }
        step = .email
        line = nil
    }

    /// 이메일 단계의 "Back" → 첫 화면 (입력을 비운다)
    public func back() {
        reset()
    }

    /// 코드 단계의 "Use a different email" → 이메일 단계 (쓰던 주소를 채워 둔다)
    public func useDifferentEmail() {
        let previous = address
        reset()
        step = .email
        emailInput = previous
    }

    /// 모두 비우고 첫 화면으로. 그 전에 시작한 늦은 답은 쓰지 않는다
    public func reset() {
        generation += 1
        step = .methods
        emailInput = ""
        address = ""
        codeInput = ""
        status = nil
        line = nil
        isSending = false
        isVerifying = false
        resendAvailableAt = nil
        expiresAt = nil
        lastAttempt = nil
    }

    /// 코드가 살아 있는 10분이 지났으면 비운다 (화면이 시계마다, 창이 다시 열릴 때마다 부른다)
    public func refresh() {
        if let expiresAt, now() >= expiresAt { reset() }
    }

    // MARK: 코드 보내기

    /// "Send code" · Return: 주소가 틀렸으면 서버를 부르지 않고 입력 오류
    public func submitEmail() {
        guard step == .email, !isSending, !isVerifying else { return }
        guard let normalized = EmailAddress.normalize(emailInput) else {
            line = .addressInvalid
            return
        }
        line = nil
        startSend(to: normalized, again: false)
    }

    /// "Resend code": 보낸 뒤 60초가 지난 뒤에만
    public func resend() {
        guard step == .code, canResend(at: now()) else { return }
        line = nil
        startSend(to: address, again: true)
    }

    public func canResend(at date: Date) -> Bool {
        guard step == .code, !isSending, !isVerifying else { return false }
        return resendAvailableAt.map { date >= $0 } ?? true
    }

    /// 다시 받기까지 남은 초 (올림). 열려 있으면 0
    public func resendSecondsLeft(at date: Date) -> Int {
        guard let resendAvailableAt else { return 0 }
        return max(0, Int((resendAvailableAt.timeIntervalSince(date)).rounded(.up)))
    }

    private func startSend(to address: String, again: Bool) {
        isSending = true
        let started = generation
        pending = Task { [weak self] in
            guard let self else { return }
            let result = await self.send(address)
            self.finishSend(result, address: address, again: again, started: started)
        }
    }

    private func send(_ address: String) async -> EmailCodeSendResult {
        guard let transport else { return .failed(.sendFailed) }
        return await transport.sendEmailCode(email: address)
    }

    private func finishSend(_ result: EmailCodeSendResult, address: String, again: Bool, started: Int) {
        // 답이 오기 전에 흐름을 떠났다: 쓰지 않는다 (새 흐름의 상태를 건드리지 않는다)
        guard started == generation else { return }
        isSending = false
        switch result {
        case .sent:
            let sentAt = now()
            self.address = address
            emailInput = address
            step = .code
            codeInput = ""
            lastAttempt = nil
            line = nil
            status = again ? .newCodeSent : .codeSent
            resendAvailableAt = sentAt.addingTimeInterval(Self.resendWait)
            expiresAt = sentAt.addingTimeInterval(Self.codeLifetime)
            outcomeSink?(.sent)
        case .failed(let failure):
            line = failure.line
            outcomeSink?(.sendFailed(failure.logCode))
        }
    }

    // MARK: 코드 확인

    /// 코드 칸에 글이 들어왔다 (입력 · 붙여 넣기 · 자동 채우기). 6자리가 차면 한 번 확인한다: 같은 값으로 두 번 부르지 않는다
    public func setCode(_ raw: String) {
        guard step == .code else { return }
        let code = EmailCode.sanitize(raw)
        guard code != codeInput else { return }
        codeInput = code
        line = nil
        if code.count < EmailCode.length { lastAttempt = nil }
        if code.count == EmailCode.length, lastAttempt != code { startVerification() }
    }

    /// "Sign in" · Return: 6자리일 때 (이미 틀렸던 같은 값도 사용자가 다시 시키면 한 번 더)
    public func submitCode() {
        guard step == .code, codeInput.count == EmailCode.length else { return }
        startVerification()
    }

    public var canSubmitCode: Bool {
        step == .code && codeInput.count == EmailCode.length && !isVerifying && !isSending
    }

    private func startVerification() {
        guard !isVerifying, !isSending else { return }
        let code = codeInput
        let address = self.address
        lastAttempt = code
        isVerifying = true
        line = nil
        let started = generation
        pending = Task { [weak self] in
            guard let self else { return }
            let result = await self.verify(address, code)
            self.finishVerification(result, started: started)
        }
    }

    private func verify(_ address: String, _ code: String) async -> EmailCodeVerifyResult {
        guard let transport else { return .ignored }
        return await transport.verifyEmailCode(email: address, code: code)
    }

    private func finishVerification(_ result: EmailCodeVerifyResult, started: Int) {
        switch result {
        case .signedIn:
            // 로그인이 끝났다: 어느 단계에 있든 모델은 비운다
            outcomeSink?(.verified)
            reset()
        case .failed(let failure):
            guard started == generation else {
                outcomeSink?(.verifyCanceled)
                return
            }
            isVerifying = false
            line = failure.line
            if failure == .wrongOrExpiredCode { selectAllRequests += 1 }
            outcomeSink?(.verifyFailed(failure.logCode))
        case .ignored:
            if started == generation { isVerifying = false }
            outcomeSink?(.verifyCanceled)
        }
    }

    /// 진행 중인 서버 호출이 끝나기를 기다린다 (시험)
    func settled() async {
        await pending?.value
    }
}
