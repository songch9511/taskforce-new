#if os(iOS)
import SwiftUI
import TaskforceKit
import TaskforceUI

enum AccountRoute: Hashable, Identifiable {
    case home, profile, connections, consent

    var id: Self { self }
}

/// 계정 메뉴 시트: Profile · Connections · AI processing · Sign Out · Delete Account
struct AccountSheet: View {
    let email: String?
    let initialRoute: AccountRoute

    @Environment(SessionStore.self) private var session
    @Environment(AccountStore.self) private var account
    @Environment(\.services) private var services
    @Environment(\.dismiss) private var dismiss
    @State private var path: [AccountRoute] = []
    @State private var confirmingDelete = false
    @State private var deleting = false
    @State private var message: String?

    var body: some View {
        NavigationStack(path: $path) {
            Form {
                Section {
                    NavigationLink(value: AccountRoute.profile) {
                        LabeledContent("Profile", value: account.profile?.displayName ?? "")
                    }
                    NavigationLink(value: AccountRoute.connections) {
                        LabeledContent("Connections", value: connectedSummary)
                    }
                    NavigationLink(value: AccountRoute.consent) {
                        LabeledContent("AI processing", value: account.hasConsent ? "On" : "Off")
                    }
                }
                Section {
                    if let email {
                        LabeledContent(session.signInMethods.accountLabel, value: email)
                    }
                    Button("Sign Out") {
                        Task {
                            // 세션이 남아 있을 때 이 기기를 알림에서 뺀다
                            await PushCenter.shared.unregister()
                            await session.signOut()
                            GoogleSignInFlow.signOut()
                        }
                    }
                    Button("Delete Account", role: .destructive) {
                        confirmingDelete = true
                    }
                    .disabled(deleting)
                }
                Section {
                    Link("Privacy Policy", destination: LegalLinks.privacy)
                    Link("Terms of Use", destination: LegalLinks.terms)
                }
            }
            .navigationTitle("Account")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .navigationDestination(for: AccountRoute.self) { route in
                Group {
                    switch route {
                    case .home: EmptyView()
                    case .profile: ProfileForm()
                    case .connections: ConnectionsView()
                    case .consent: ConsentSettingsView()
                    }
                }
                // 줄을 눌러 들어가면 루트("Account")의 작은 제목을 물려받지만, 시트가 처음부터 이 화면으로 열리면(`initialRoute`:
                // 재연결 배너 · 재연결 알림) 물려받지 못해 큰 제목이 첫 줄 위에 겹친다. 어느 길로 와도 작은 제목으로 둔다.
                .navigationBarTitleDisplayMode(.inline)
            }
            .task { await account.load() }
            .confirmationDialog("Delete your account?", isPresented: $confirmingDelete, titleVisibility: .visible) {
                Button("Delete Account", role: .destructive) { deleteAccount() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Your sources, tasks, and history are deleted right away. This can't be undone.")
            }
            .messageAlert($message)
        }
        .onAppear {
            if initialRoute != .home, path.isEmpty { path = [initialRoute] }
        }
    }

    private var connectedSummary: String {
        let count = ConnectionProvider.stageOne.filter { account.state(for: $0).isConnected }.count
        return count == 0 ? "" : "\(count)"
    }

    private func deleteAccount() {
        guard let services else { return }
        deleting = true
        Task {
            message = await AccountDeletion.delete(services: services, session: session)
            deleting = false
        }
    }
}
#endif
