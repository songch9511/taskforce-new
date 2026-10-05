import SwiftUI
import TaskforceKit
import TaskforceUI

struct SignInView: View {
    @Environment(SessionStore.self) private var session
    @State private var signingInWithGoogle = false

    /// 기존 Google 로그인 버튼 크기를 유지한다.
    private let buttonHeight = SignInWithGoogleButton.height

    var body: some View {
        VStack(spacing: TFSpace.xl) {
            Spacer()
            HStack(spacing: TFSpace.md) {
                TFImage.logoMark
                    .renderingMode(.template)
                    .resizable()
                    .aspectRatio(TFImage.logoMarkAspectRatio, contentMode: .fit)
                    .frame(height: 28)
                Text("Taskforce")
                    .font(.largeTitle.weight(.semibold))
            }
            .foregroundStyle(TFColor.textPrimary)
            .accessibilityElement(children: .combine)
            Spacer()
            VStack(spacing: TFSpace.md) {
                if GoogleSignInFlow.isAvailable {
                    SignInWithGoogleButton {
                        signingInWithGoogle = true
                        GoogleSignInFlow.signIn(session: session) { signingInWithGoogle = false }
                    }
                    .frame(maxWidth: 360, minHeight: buttonHeight, maxHeight: buttonHeight)
                    .disabled(signingInWithGoogle)
                }

                if !GoogleSignInFlow.isAvailable {
                    Text("Google sign-in is unavailable in this build.")
                        .font(TFFont.footnote)
                }
            }
            Text(SessionStore.googleOnlyNotice)
                .font(TFFont.footnote)
                .foregroundStyle(TFColor.textSecondary)
                .multilineTextAlignment(.center)

            Link("Contact for account access or deletion help", destination: AccountDeletion.contactURL)
                .font(TFFont.footnote)

            if let message = session.errorMessage {
                Text(message)
                    .font(TFFont.footnote)
                    .foregroundStyle(TFColor.statusOverdue)
                    .multilineTextAlignment(.center)
            } else if let notice = session.notice, notice != SessionStore.googleOnlyNotice {
                Text(notice)
                    .font(TFFont.footnote)
                    .foregroundStyle(TFColor.textSecondary)
                    .multilineTextAlignment(.center)
            }
            LegalLinksRow()
                .font(TFFont.footnote)
        }
        .padding(TFSpace.xxl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(TFColor.bgCanvas)
        .onDisappear { GoogleSignInFlow.forgetRunningFlow() }
    }
}
