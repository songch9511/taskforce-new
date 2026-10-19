import Supabase
import SwiftUI
import TaskforceKit

/// 계정 삭제 (App Store 5.1.1(v)): Apple 로그인이 붙은 계정은 삭제 직전에 Sign in with Apple을 한 번 더 받아(Mac은 브라우저 창, `AppleSignInFlow`)
/// authorization code를 서버로 보내면 서버가 Apple 토큰을 폐기한다 (`apple_client: web`: Mac 웹 로그인의 Services ID로 받은 code).
/// 사용자가 확인을 취소했거나 받지 못해도 삭제는 하고, 끝난 뒤 로그인 화면에 한 줄로 알린다 (처리방침 5장).
/// Google 로그인이 붙은 계정은 삭제한 뒤 이 기기의 Google 권한을 폐기한다(`GoogleSignInFlow.disconnect`). 이메일 · 비밀번호(심사 계정)는 폐기할 것이 없다.
/// 무엇을 할지는 삭제 직전에 서버에서 새로 읽은 사용자로 정한다(`AccountDeletionPlan`): 다른 기기에서 Apple을 이은 계정도 놓치지 않게.
/// 계정이 바뀌는 경합은 막는다: 확인 창을 띄운 사이 · 서버 응답을 기다리는 사이 계정이 바뀌면 지금 계정을 지우거나 로그아웃시키지 않는다.
@MainActor
enum AccountDeletion {
    static let contactURL = URL(string: "mailto:privacy@taskforcelabs.dev")!
    /// 삭제 뒤 Apple 폐기를 못 했을 때 로그인 화면에 띄우는 한 줄 (사용자 승인 2026-10-19, 메뉴 이름은 확인 필요: L2)
    static let revokeSkippedNote = SignInCopy.appleRevokeSkipped
    static let accountChangedMessage = "Your account changed. Try again before deleting it."
    static let couldNotVerifyMessage = "Couldn't verify your account. Try again before deleting it."

    /// 삭제 확인 문구. 구독 문장은 그대로고(결제 WP 몫), Apple 로그인을 막던 두 조각("cannot be deleted here" · "For eligible accounts")은 없앴고
    /// 폐기 문장이 Apple을 더한 새 문장이다 (사용자 승인 2026-10-19)
    static let confirmationMessage = "Taskforce cancels future subscription renewals before deleting your stored sources, tasks, drafts, and history. An open checkout or unconfirmed cancellation can delay deletion. Deletion does not request a refund; payment records remain with the payment provider; original items in connected services stay. \(SignInCopy.deleteRemovesAccess) Check those account settings to remove any access left. This can't be undone."

    static func delete(services: AppServices, session: SessionStore) async -> String? {
        await delete(
            session: session,
            fetchUser: { try await services.supabase.auth.user() },
            reauthorize: { await AppleSignInFlow.shared.reauthorizationCode() },
            deleteOnServer: { code, client in try await services.api.deleteAccount(authorizationCode: code, client: client) },
            removeSavedData: { try? AppRuntime.savedNow?.remove(account: $0); BridgeHost.removeSavedBridgeData(for: $0) },
            disconnectGoogle: { GoogleSignInFlow.disconnect() },
            accountDeleted: { note in await session.accountDeleted(note: note) }
        )
    }

    // Dependencies let the regression hold the server response (or the Apple window) while the current account changes.
    /// 성공하면 nil, 실패하면 화면에 보여 줄 한 줄
    static func delete(
        session: SessionStore,
        fetchUser: () async throws -> User,
        reauthorize: () async -> String?,
        deleteOnServer: (String?, AppleAuthorizationClient) async throws -> Void,
        removeSavedData: (UUID) -> Void,
        disconnectGoogle: () -> Void,
        accountDeleted: (String?) async -> Void
    ) async -> String? {
        guard case .signedIn(let userID, _) = session.state else {
            return SignInCopy.signInBeforeDeleting
        }
        let fresh: User
        do { fresh = try await fetchUser() }
        catch { return couldNotVerifyMessage }
        if let blocker = deletionBlocker(fresh: fresh, expectedID: userID, currentID: currentUserID(session)) { return blocker }
        let plan = AccountDeletionPlan(fresh: SignInMethods(user: fresh), cached: session.signInMethods)
        // Apple이 붙은 계정: 브라우저 창에서 한 번 더 확인받는다. 취소 · 실패면 code 없이 지운다
        let code = plan.reauthorizeWithApple ? await reauthorize() : nil
        // 창이 떠 있는 사이 계정이 바뀌었으면 서버에 쓰지 않는다
        if let blocker = deletionBlocker(fresh: fresh, expectedID: userID, currentID: currentUserID(session)) { return blocker }
        // Mac의 재확인 code는 브라우저 창(Services ID) 것이다: 서버가 그 client로 토큰을 받아 폐기한다 (`apple_client: web`)
        do { try await deleteOnServer(code, .web) }
        catch { return "Couldn't delete your account. \(error.userMessage)" }
        removeSavedData(userID)
        guard case .signedIn(let remainingUserID, _) = session.state, remainingUserID == userID else { return nil }
        if plan.disconnectGoogle { disconnectGoogle() }
        await accountDeleted(plan.reauthorizeWithApple && code == nil ? revokeSkippedNote : nil)
        return nil
    }

    private static func currentUserID(_ session: SessionStore) -> UUID? {
        if case .signedIn(let id, _) = session.state { id } else { nil }
    }

    /// 지울 계정이 확인 시작 때의 계정 그대로인지. 아니면 쓰지 않고 알린다
    static func deletionBlocker(fresh: User, expectedID: UUID, currentID: UUID?) -> String? {
        guard fresh.id == expectedID, currentID == expectedID else { return accountChangedMessage }
        return nil
    }
}

/// 개인정보 처리방침 · 이용약관 링크 (App Store 5.1.1(i))
struct LegalLinksRow: View {
    var body: some View {
        HStack(spacing: 16) {
            Link("Privacy Policy", destination: LegalLinks.privacy)
            Link("Terms of Use", destination: LegalLinks.terms)
        }
        #if os(iOS)
        // iPhone Form 한 줄에 링크가 둘이라, 줄 전체가 한 링크로 눌리지 않게 (Mac은 이 스타일이 링크를 회색 글자로 만든다)
        .buttonStyle(.borderless)
        #endif
    }
}
