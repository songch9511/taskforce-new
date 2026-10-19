#if os(macOS)
import AppKit
import AuthenticationServices
import SwiftUI
import TaskforceKit

/// 브라우저 창 하나를 띄우는 일 (ASWebAuthenticationSession). 시험은 가짜 구현으로 바꿔 실제 창 · 네트워크에 닿지 않는다.
@MainActor
protocol WebAuthenticationRunning {
    /// `url`을 브라우저 창에서 열고, `taskforce://` 주소로 돌아온 URL을 준다. 사용자가 창을 닫았으면 `.canceled`
    func run(url: URL, anchor: ASPresentationAnchor) async -> WebAuthenticationResult
    /// 떠 있는 창을 닫는다 (진행 중인 `run`은 `.canceled`로 끝난다)
    func cancel()
}

enum WebAuthenticationResult: Equatable {
    case callback(URL)
    case canceled
    /// 창을 열지 못했다 (`start()`가 false): "Couldn't open Apple sign-in. Try again."
    case couldNotOpen
    /// 창이 오류로 끝났다 (설명 글은 쓰지 않는다): "Couldn't sign in with Apple. Try again."
    case failed
}

/// 시스템 브라우저 창 (`prefersEphemeralWebBrowserSession = false`: 브라우저에 이미 로그인돼 있으면 다시 입력하지 않는다).
/// 같은 scheme을 다른 앱이 등록해도 부른 앱의 세션만 콜백을 받는다.
@MainActor
final class SystemWebAuthenticationRunner: NSObject, WebAuthenticationRunning, ASWebAuthenticationPresentationContextProviding {
    private var session: ASWebAuthenticationSession?
    private var anchor: ASPresentationAnchor?
    private var continuation: CheckedContinuation<WebAuthenticationResult, Never>?

    func run(url: URL, anchor: ASPresentationAnchor) async -> WebAuthenticationResult {
        // 이미 떠 있으면 새로 열지 않는다 (`AppleSignInFlow`가 한 번에 하나만 부른다)
        guard continuation == nil else { return .canceled }
        self.anchor = anchor
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            let session = ASWebAuthenticationSession(url: url, callback: .customScheme(AppleWebAuthorization.callbackScheme)) { [weak self] callback, error in
                // 완료 핸들러는 메인 큐로 온다. 토큰이 든 주소는 여기서 한 번만 넘기고 어디에도 남기지 않는다
                let result: WebAuthenticationResult
                if let callback {
                    result = .callback(callback)
                } else if (error as? ASWebAuthenticationSessionError)?.code == .canceledLogin {
                    result = .canceled
                } else {
                    result = .failed
                }
                MainActor.assumeIsolated { self?.finish(result) }
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            self.session = session
            if !session.start() { finish(.couldNotOpen) }
        }
    }

    func cancel() {
        session?.cancel()
    }

    private func finish(_ result: WebAuthenticationResult) {
        let continuation = continuation
        self.continuation = nil
        session = nil
        anchor = nil
        continuation?.resume(returning: result)
    }

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated { anchor ?? NSApplication.shared.keyWindow ?? NSApplication.shared.windows.first ?? ASPresentationAnchor() }
    }
}

/// Mac의 Sign in with Apple (브라우저 창): 로그인 · 로그인 방법 이어 붙이기 · 계정 삭제 재확인이 같은 흐름을 쓴다 (`AppleWebAuthorization`).
/// Developer ID 앱은 앱 안 Apple 로그인을 쓸 수 없어(권한을 받지 못한다) Apple 웹 로그인을 연다: 결과는 Taskforce 서버(`/api/v1/apple/return`)를 거쳐
/// `taskforce://auth/apple?…`로 돌아오고, 이 흐름이 자기 세션 안에서 자기가 만든 state일 때만 받는다. 토큰 · code · nonce · 이메일은 로그에 남기지 않는다.
/// 설정(`AppleServicesID` · `AppleWebReturnURL`)이 없으면 버튼 · 행을 숨긴다 (`GoogleSignInFlow`와 같은 방식).
@MainActor
final class AppleSignInFlow {
    static let config = AppleWebSignInConfig(infoDictionary: Bundle.main.infoDictionary ?? [:])
    static var isAvailable: Bool { config != nil }
    static let shared = AppleSignInFlow(config: config, runner: SystemWebAuthenticationRunner())

    /// 흐름 하나의 끝: 값, 사용자가 닫음(조용히), 또는 화면에 보일 한 줄
    enum Authorization<Value: Sendable>: Sendable {
        case value(Value)
        case canceled
        case failed(String)
    }

    /// 로그인에 쓸 토큰: Apple ID 토큰과, Supabase에 원본으로 보낼 nonce (Apple에는 해시를 보냈다)
    struct SignInToken: Equatable, Sendable {
        let idToken: String
        let nonce: SignInNonce
    }

    private let config: AppleWebSignInConfig?
    private let runner: WebAuthenticationRunning
    /// 떠 있는 흐름 (런처 행과 설정 창 버튼을 함께 눌러도 흐름 하나만)
    private var running = false

    init(config: AppleWebSignInConfig?, runner: WebAuthenticationRunning) {
        self.config = config
        self.runner = runner
    }

    // MARK: 로그인

    /// 로그인을 시작한다. `onFinish`: 창을 닫았거나 Supabase 로그인까지 끝났을 때. 오류는 `session.reportError`로 로그인 화면에 알린다
    func signIn(session: SessionStore, presenting anchor: ASPresentationAnchor? = nil, onFinish: @escaping @MainActor () -> Void = {}) {
        Task { @MainActor in
            switch await authorizeSignIn(presenting: anchor) {
            case .value(let token): await session.signInWithApple(idToken: token.idToken, nonce: token.nonce)
            case .canceled: break
            case .failed(let message): session.reportError(message)
            }
            onFinish()
        }
    }

    /// Settings › Account › Sign-in "Add"에서도 쓴다: 토큰만 받는다 (`SessionStore.linkApple`이 이어 붙인다)
    /// `step`: 결과 코드 로그의 이름 (`signin` · 이어 붙이기는 `link`)
    func authorizeSignIn(presenting anchor: ASPresentationAnchor? = nil, step: SignInLog.Step = .signIn) async -> Authorization<SignInToken> {
        guard let config, !running else { return .canceled }
        let state = AppleWebAuthorization.makeState()
        let nonce = SignInNonce.random()
        let url = AppleWebAuthorization.signInURL(config: config, state: state, nonce: nonce)
        switch await open(url, state: state, purpose: .signIn, step: step, anchor: anchor) {
        case .idToken(let idToken): return .value(SignInToken(idToken: idToken, nonce: nonce))
        case .failed(let message): return .failed(message)
        default: return .canceled
        }
    }

    // MARK: 계정 삭제 재확인

    /// 삭제 직전 재확인: authorization code. 사용자가 취소했거나 받지 못하면 nil (code 없이 지운다)
    func reauthorizationCode(presenting anchor: ASPresentationAnchor? = nil) async -> String? {
        guard let config, !running else { return nil }
        let state = AppleWebAuthorization.makeState()
        let url = AppleWebAuthorization.reauthorizeURL(config: config, state: state)
        if case .code(let code) = await open(url, state: state, purpose: .reauthorize, step: .reauth, anchor: anchor) { return code }
        return nil
    }

    // MARK: 브라우저 창

    private enum Opened {
        case idToken(String)
        case code(String)
        case canceled
        case failed(String)
    }

    private func open(_ url: URL, state: String, purpose: AppleWebAuthorization.Purpose, step: SignInLog.Step, anchor: ASPresentationAnchor?) async -> Opened {
        guard let anchor = anchor ?? Self.currentAnchor() else {
            SignInLog.record(.apple, step, .failed("no_window"))
            return .failed(SignInCopy.appleOpenFailed)
        }
        running = true
        let result = await runner.run(url: url, anchor: anchor)
        running = false
        switch result {
        case .canceled:
            SignInLog.record(.apple, step, .canceled)
            return .canceled
        case .couldNotOpen:
            SignInLog.record(.apple, step, .failed("open_failed"))
            return .failed(SignInCopy.appleOpenFailed)
        case .failed:
            SignInLog.record(.apple, step, .failed("session_error"))
            return .failed(SignInCopy.appleFailed)
        case .callback(let callback):
            switch AppleWebAuthorization.parse(callback: callback, expectedState: state, purpose: purpose) {
            case .idToken(let token):
                SignInLog.record(.apple, step, .ok)
                return .idToken(token)
            case .code(let code):
                SignInLog.record(.apple, step, .ok)
                return .code(code)
            case .canceled:
                SignInLog.record(.apple, step, .canceled)
                return .canceled
            case .notOurs:
                SignInLog.record(.apple, step, .failed("not_ours"))
                return .canceled
            case .missingToken:
                SignInLog.record(.apple, step, .failed("missing_token"))
                return .failed(SignInCopy.appleMissingToken)
            case .failed(let code):
                SignInLog.record(.apple, step, .failed(code))
                return .failed(SignInCopy.appleFailed)
            }
        }
    }

    /// 로그인 화면이 사라질 때: 끝을 받지 못한 흐름이 다음 로그인을 막지 않게 창을 닫는다
    func forgetRunningFlow() {
        guard running else { return }
        runner.cancel()
    }

    private static func currentAnchor() -> ASPresentationAnchor? {
        NSApplication.shared.keyWindow ?? NSApplication.shared.windows.first { $0.isVisible }
    }

    // MARK: 앱 밖에서 열린 주소

    /// `taskforce://auth/apple…`인지 (state와 상관없이). 이 주소는 자기 ASWebAuthenticationSession만 받는다:
    /// 앱 밖에서 열린 것은 토큰을 쓰지 않고, 연결 콜백으로도 넘기지 않고 버린다
    static func isAppleCallback(_ url: URL) -> Bool {
        url.scheme?.lowercased() == AppleWebAuthorization.callbackScheme && url.host?.lowercased() == "auth"
            && ["/apple", "/apple/"].contains(url.path.lowercased())
    }
}
#endif
