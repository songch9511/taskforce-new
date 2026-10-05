import Supabase
import SwiftUI
import TaskforceKit

/// Fresh identity verification remains required. Apple-linked accounts cannot revoke
/// their Apple grant from this Developer ID app, so deletion stops before any write.
@MainActor
enum AccountDeletion {
    static let contactURL = URL(string: "mailto:privacy@taskforcelabs.dev")!
    static let unavailableMessage = "Apple sign-in verification is required or could not be ruled out. Account deletion is unavailable in this Google-only Mac app. Your account and data have not been deleted. Contact privacy@taskforcelabs.dev for account access or deletion help."
    static let confirmationMessage = "Taskforce deletes your stored sources, tasks, drafts, and history; original items in connected services stay. Accounts requiring Apple sign-in verification cannot be deleted here; contact privacy@taskforcelabs.dev for help. For eligible accounts, we try to remove Google and connected-service access, but it may remain. Check those account settings to remove any access left. This can't be undone."

    static func delete(services: AppServices, session: SessionStore) async -> String? {
        await delete(
            session: session,
            fetchUser: { try await services.supabase.auth.user() },
            deleteOnServer: { try await services.api.deleteAccount() },
            removeSavedData: { try? AppRuntime.savedNow?.remove(account: $0) },
            disconnectGoogle: { GoogleSignInFlow.disconnect() },
            accountDeleted: { await session.accountDeleted() }
        )
    }

    // Dependencies let the regression hold the server response while the current account changes.
    static func delete(
        session: SessionStore,
        fetchUser: () async throws -> User,
        deleteOnServer: () async throws -> Void,
        removeSavedData: (UUID) -> Void,
        disconnectGoogle: () -> Void,
        accountDeleted: () async -> Void
    ) async -> String? {
        guard case .signedIn(let userID, _) = session.state else {
            return "Sign in with Google before deleting your account."
        }
        let fresh: User
        do { fresh = try await fetchUser() }
        catch { return "Couldn't verify your account. Try again before deleting it." }
        let currentID: UUID? = if case .signedIn(let id, _) = session.state { id } else { nil }
        if let blocker = deletionBlocker(fresh: fresh, cached: session.signInMethods, expectedID: userID, currentID: currentID) {
            return blocker
        }
        do { try await deleteOnServer() }
        catch { return "Couldn't delete your account. \(error.userMessage)" }
        removeSavedData(userID)
        guard case .signedIn(let remainingUserID, _) = session.state, remainingUserID == userID else { return nil }
        disconnectGoogle()
        await accountDeleted()
        return nil
    }
    static func deletionBlocker(fresh: User, cached: SignInMethods, expectedID: UUID, currentID: UUID?) -> String? {
        guard fresh.id == expectedID, currentID == expectedID else {
            return "Your account changed. Try again before deleting it."
        }
        let plan = AccountDeletionPlan(fresh: SignInMethods(user: fresh), cached: cached)
        guard !plan.reauthorizeWithApple else { return unavailableMessage }
        guard plan.disconnectGoogle else { return "Sign in with Google before deleting your account." }
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
