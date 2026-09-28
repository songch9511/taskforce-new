import AuthenticationServices
import SwiftUI
import TaskforceKit
#if canImport(UIKit)
import UIKit
#endif

/// 계정 삭제 (App Store 5.1.1(v)): 삭제 직전에 Sign in with Apple을 한 번 더 받아 authorization code를 서버로 보내면
/// 서버가 Apple 토큰을 폐기한다. 사용자가 Apple 확인을 취소해도 삭제는 하고, 로그인 화면에 한 줄로 알린다.
@MainActor
enum AccountDeletion {
    static let revokeSkippedNote = "Account deleted. To remove Apple sign-in too, open Settings › Apple Account › Sign in with Apple."

    /// 성공하면 nil, 실패하면 화면에 보여 줄 한 줄
    static func delete(services: AppServices, session: SessionStore) async -> String? {
        let code = await AppleReauthorization.authorizationCode()
        do {
            try await services.api.deleteAccount(authorizationCode: code)
        } catch {
            return "Couldn't delete your account. \(error.userMessage)"
        }
        await session.accountDeleted(note: code == nil ? revokeSkippedNote : nil)
        return nil
    }
}

/// 범위 없는 Apple ID 요청으로 authorization code만 받는다 (취소 · 실패면 nil)
@MainActor
final class AppleReauthorization: NSObject, ASAuthorizationControllerDelegate, ASAuthorizationControllerPresentationContextProviding {
    private let anchor: ASPresentationAnchor
    private var controller: ASAuthorizationController?
    private var continuation: CheckedContinuation<String?, Never>?

    private init(anchor: ASPresentationAnchor) {
        self.anchor = anchor
    }

    static func authorizationCode() async -> String? {
        guard let anchor = currentAnchor() else { return nil }
        return await AppleReauthorization(anchor: anchor).run()
    }

    private static func currentAnchor() -> ASPresentationAnchor? {
        #if canImport(UIKit)
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.compactMap(\.keyWindow).first ?? scenes.flatMap(\.windows).first
        #else
        return NSApplication.shared.keyWindow ?? NSApplication.shared.windows.first { $0.isVisible }
        #endif
    }

    private func run() async -> String? {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            let request = ASAuthorizationAppleIDProvider().createRequest()
            let controller = ASAuthorizationController(authorizationRequests: [request])
            controller.delegate = self
            controller.presentationContextProvider = self
            self.controller = controller
            controller.performRequests()
        }
    }

    private func finish(_ code: String?) {
        continuation?.resume(returning: code)
        continuation = nil
        controller = nil
    }

    func authorizationController(controller: ASAuthorizationController, didCompleteWithAuthorization authorization: ASAuthorization) {
        let credential = authorization.credential as? ASAuthorizationAppleIDCredential
        finish(credential?.authorizationCode.flatMap { String(data: $0, encoding: .utf8) })
    }

    func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: Error) {
        finish(nil)
    }

    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        anchor
    }
}

/// 개인정보 처리방침 · 이용약관 링크 (App Store 5.1.1(i))
struct LegalLinksRow: View {
    var body: some View {
        HStack(spacing: 16) {
            Link("Privacy Policy", destination: LegalLinks.privacy)
            Link("Terms of Use", destination: LegalLinks.terms)
        }
    }
}
