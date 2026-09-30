import GoogleSignIn
import SwiftUI
import TaskforceKit
#if canImport(UIKit)
import UIKit

/// Google 로그인 창을 띄울 곳 (iOS: 맨 위 화면, Mac: 창)
typealias GoogleSignInAnchor = UIViewController
#else
import AppKit

typealias GoogleSignInAnchor = NSWindow
#endif

/// Sign in with Google (로그인만). Google Sign-In SDK → ID 토큰 · 액세스 토큰 → Supabase `signInWithIdToken` (Apple 로그인과 같은 방식).
/// 범위는 SDK 기본값(openid · email · profile)만 받는다. Gmail · Calendar는 연결 화면의 서버 연동으로 따로 받는다.
/// 설정(`GIDClientID` · URL scheme, `GoogleSignInConfig`)이 없으면 버튼 · 런처 행을 숨기고 SDK를 건드리지 않는다.
@MainActor
enum GoogleSignInFlow {
    static let config = GoogleSignInConfig(infoDictionary: Bundle.main.infoDictionary ?? [:])

    static var isAvailable: Bool { config != nil }

    /// 떠 있는 로그인 흐름 (런처 행과 설정 창 버튼을 함께 눌러도 흐름 하나만: SDK는 두 번째가 첫 번째를 덮어 nonce가 어긋난다).
    /// 끝을 받지 못한 채 로그인 화면이 사라지면 `forgetRunningFlow`가 푼다 (버튼이 계속 막히지 않게)
    private static var running: UUID?

    /// 로그인을 시작한다. Google에는 nonce의 SHA-256을, Supabase에는 원래 값을 보낸다 (Supabase Google 제공자의 nonce 확인은 켜 둔다).
    /// `anchor`가 없으면 지금 앞에 있는 화면 · 창. `onFinish`: 창을 닫았거나 Supabase 로그인까지 끝났을 때.
    static func signIn(session: SessionStore, presenting anchor: GoogleSignInAnchor? = nil, onFinish: @escaping @MainActor () -> Void = {}) {
        guard let config, running == nil else {
            onFinish()
            return
        }
        guard let anchor = anchor ?? currentAnchor() else {
            session.reportError("Couldn't open Google sign-in. Try again.")
            onFinish()
            return
        }
        let flow = UUID()
        running = flow
        let google = GIDSignIn.sharedInstance
        google.configuration = GIDConfiguration(clientID: config.clientID)
        let nonce = SignInNonce.random()
        google.signIn(withPresenting: anchor, hint: nil, additionalScopes: nil, nonce: nonce.hashed) { result, error in
            // SDK는 결과를 메인 큐로 준다. 토큰 문자열만 꺼내 메인 액터로 넘긴다.
            let outcome: Outcome
            if let error {
                outcome = (error as? GIDSignInError)?.code == .canceled ? .canceled : .failed(error.localizedDescription)
            } else if let user = result?.user, let idToken = user.idToken?.tokenString {
                outcome = .tokens(idToken: idToken, accessToken: user.accessToken.tokenString)
            } else {
                outcome = .noToken
            }
            Task { @MainActor in
                await finish(outcome, nonce: nonce, session: session)
                if running == flow { running = nil }
                onFinish()
            }
        }
    }

    private enum Outcome: Sendable {
        case tokens(idToken: String, accessToken: String)
        case canceled
        case noToken
        case failed(String)
    }

    private static func finish(_ outcome: Outcome, nonce: SignInNonce, session: SessionStore) async {
        switch outcome {
        case .tokens(let idToken, let accessToken):
            // Supabase가 받지 않으면 이 기기의 Google 로그인도 지운다 (다음 시도는 계정 고르기부터)
            if !(await session.signInWithGoogle(idToken: idToken, accessToken: accessToken, nonce: nonce)) {
                GIDSignIn.sharedInstance.signOut()
            }
        case .canceled:
            // 사용자가 창을 닫은 경우는 오류로 보여주지 않는다.
            break
        case .noToken:
            session.reportError("Google didn't return a sign-in token. Try again.")
        case .failed(let description):
            session.reportError("Couldn't sign in with Google. \(description)")
        }
    }

    /// 로그인 화면이 사라질 때: 끝을 받지 못한 흐름이 다음 로그인을 막지 않게 한다
    static func forgetRunningFlow() {
        running = nil
    }

    /// Google 로그인 콜백이면 SDK에 넘기고 true. 보통은 ASWebAuthenticationSession이 바로 받고, 앱 밖에서 열린 경우를 위해 둔다.
    /// `taskforce://` 연결 콜백은 false (연결 화면이 처리한다).
    static func handle(_ url: URL) -> Bool {
        guard let config, config.handles(url) else { return false }
        _ = GIDSignIn.sharedInstance.handle(url)
        return true
    }

    /// Taskforce 로그인이 풀릴 때마다(로그아웃 · 세션 만료 · 계정 삭제) 이 기기의 Google 로그인도 지운다 (권한 폐기는 계정 삭제 때만, `disconnect`).
    /// 다음에 로그인한 다른 계정이 전 계정의 Google 토큰을 폐기하는 일이 없게.
    static func signOut() {
        guard isAvailable else { return }
        GIDSignIn.sharedInstance.signOut()
    }

    /// 계정을 지운 뒤: Google에서 이 앱의 권한을 폐기한다 (Google 계정의 "연결된 앱"에서 빠진다).
    /// 기다리지 않고, 실패해도 삭제는 이미 끝났다 (이 기기의 Google 로그인만 지운다).
    /// 이 기기에 Google 토큰이 없으면(다른 기기에서만 Google로 로그인) 폐기할 것이 없다.
    static func disconnect() {
        guard isAvailable else { return }
        GIDSignIn.sharedInstance.disconnect { error in
            if error != nil { GIDSignIn.sharedInstance.signOut() }
        }
    }

    private static func currentAnchor() -> GoogleSignInAnchor? {
        #if canImport(UIKit)
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let window = scenes.compactMap(\.keyWindow).first ?? scenes.flatMap(\.windows).first
        var top = window?.rootViewController
        while let presented = top?.presentedViewController { top = presented }
        return top
        #else
        return NSApplication.shared.keyWindow ?? NSApplication.shared.windows.first { $0.isVisible }
        #endif
    }
}
