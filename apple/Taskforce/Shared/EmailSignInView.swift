import AppKit
import SwiftUI
import TaskforceKit
import TaskforceUI

// 이메일 8자리 코드 로그인의 두 단계 화면 (OA 이메일 로그인, 사용자 승인 2026-10-20: DZ-E1–E4 그림 · 문구 표).
// 규칙은 모두 Kit `EmailSignInModel`에 있고 여기는 그리기만 한다: 오류는 모두 칸 아래 조용한 회색 한 줄, 다시 받기 60초 잠금은 숫자를 보이지 않는다
// (막힌 버튼의 이유는 hover 제목 · VoiceOver에만), Sign in은 8자리가 될 때까지 막는다 (막힌 버튼의 글자는 그대로 흐려질 뿐이다).

extension EmailSignInGate {
    /// 이 앱이 이메일 로그인 입구를 보이는지: Info.plist `EmailSignInEnabled` (Debug YES · Release NO로 커밋)
    static var isOpen: Bool { isEnabled(infoDictionary: Bundle.main.infoDictionary) }
}

/// 이메일 로그인 모델을 앱에 잇는 곳: 세션 · 결과 로그. 로그인 화면이 보일 때마다 부른다 (여러 번 불러도 안전하다)
@MainActor
enum EmailSignInFlow {
    static func configure(_ model: EmailSignInModel = .shared, session: SessionStore) {
        model.attach(to: session)
        model.outcomeSink = { log($0) }
        model.refresh()
    }

    /// 결과 코드만 OSLog에 남긴다 (`SignInLog`: `email send ok|failed:<코드>` · `email verify ok|canceled|failed:<코드>`). 이메일 · 코드는 싣지 않는다
    static func log(_ outcome: EmailSignInOutcome) {
        switch outcome {
        case .sent: SignInLog.record(.email, .send, .ok)
        case .sendFailed(let code): SignInLog.record(.email, .send, .failed(code))
        case .verified: SignInLog.record(.email, .verify, .ok)
        case .verifyFailed(let code): SignInLog.record(.email, .verify, .failed(code))
        case .verifyCanceled: SignInLog.record(.email, .verify, .canceled)
        }
    }
}

/// 막힌 버튼의 이유: 글로 보이지 않고 hover 제목 · VoiceOver에만 있다. 막히지 않았으면 nil
@MainActor
enum EmailSignInHelp {
    static func resend(_ model: EmailSignInModel, at date: Date) -> String? {
        guard model.step == .code, !model.canResend(at: date) else { return nil }
        let seconds = model.resendSecondsLeft(at: date)
        return seconds > 0 ? SignInCopy.resendAvailableIn(seconds: seconds) : nil
    }

    static func signIn(_ model: EmailSignInModel) -> String? {
        model.step == .code && model.codeInput.count < EmailCode.length ? SignInCopy.enterEightDigits : nil
    }
}

/// 이메일 단계 · 코드 단계 (로그인 화면의 버튼 자리를 같은 자리에서 바꾼다). 제목 · 법률 줄은 `SignInView`가 그대로 둔다
struct EmailSignInSteps: View {
    @Bindable var model: EmailSignInModel

    /// Apple · Google 버튼과 같은 폭 · 높이 (`SignInView`)
    static let columnWidth: CGFloat = 360

    var body: some View {
        VStack(spacing: TFSpace.md) {
            switch model.step {
            case .methods:
                EmptyView()
            case .email:
                EmailStep(model: model)
            case .code:
                CodeStep(model: model)
            }
        }
        .frame(maxWidth: Self.columnWidth)
        .onChange(of: model.line) { _, line in
            // 회색 힌트는 VoiceOver가 바로 읽지 않는다: 줄이 생길 때 공지한다
            if let line { AccessibilityNotification.Announcement(line.text).post() }
        }
    }
}

/// 라벨 + 한 칸 + 칸 아래 회색 한 줄 (DS TextField `hint`)
private struct SignInField: View {
    let label: String
    @Binding var text: String
    var hint: String?
    var monospaced = false
    var oneTimeCode = false
    var readOnly = false
    var focusRequest = 0
    var onSubmit: () -> Void

    @FocusState private var focused: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
        VStack(alignment: .leading, spacing: TFSpace.xs) {
            Text(label)
                .font(TFFont.footnote)
                .foregroundStyle(TFColor.textSecondary)
                .accessibilityHidden(true)
            TextField(label, text: $text)
                .textFieldStyle(.plain)
                .font(monospaced ? .system(size: 15, design: .monospaced).monospacedDigit() : TFFont.footnote)
                .foregroundStyle(TFColor.textPrimary)
                .textContentType(oneTimeCode ? .oneTimeCode : .emailAddress)
                .autocorrectionDisabled()
                .focused($focused)
                .focusEffectDisabled()
                .disabled(readOnly)
                .padding(.vertical, 6)
                .padding(.horizontal, TFSpace.sm)
                .background(TFColor.bgElevated, in: shape)
                .overlay(shape.strokeBorder(focused ? TFColor.fillAccent : TFColor.borderControl, lineWidth: 1))
                .background(shape.inset(by: -3).fill(TFColor.fillAccent.opacity(focused ? 0.35 : 0)))
                .onSubmit(onSubmit)
                .accessibilityLabel(label)
            if let hint {
                Text(hint)
                    .font(TFFont.footnote)
                    .foregroundStyle(TFColor.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .onAppear { focused = true }
        // 틀린 코드: 칸의 글을 전체 선택해 바로 다시 칠 수 있게 한다
        .onChange(of: focusRequest) {
            focused = true
            DispatchQueue.main.async { NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil) }
        }
    }
}

/// 주 버튼 (DS Button primary block): 글자는 그대로 두고 스피너만 더한다 (`loading`)
private struct PrimaryBlockButton: View {
    let title: String
    var loading = false
    var disabled = false
    var help: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: TFSpace.sm) {
                if loading { ProgressView().controlSize(.small) }
                Text(title)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(TFButtonStyle(.primary, size: .md))
        // 보내는 · 확인하는 동안은 흐려지지 않고 스피너만 돈다 (눌림만 막는다). 8자리 전의 Sign in은 흐려진다
        .disabled(disabled)
        .allowsHitTesting(!loading)
        .help(help ?? "")
        .accessibilityHint(help ?? "")
    }
}

private struct EmailStep: View {
    @Bindable var model: EmailSignInModel

    var body: some View {
        VStack(spacing: TFSpace.md) {
            SignInField(
                label: SignInCopy.emailLabel, text: $model.emailInput, hint: model.line?.text, readOnly: model.isSending,
                onSubmit: { model.submitEmail() })
            PrimaryBlockButton(title: SignInCopy.sendCode, loading: model.isSending) { model.submitEmail() }
            Button(SignInCopy.back) { model.back() }
                .buttonStyle(TFButtonStyle(.text, size: .md))
                .disabled(model.isSending)
        }
    }
}

private struct CodeStep: View {
    @Bindable var model: EmailSignInModel
    /// 칸에 보이는 글: 들어오는 글을 정리한 뒤 되돌려 쓴다 (붙여 넣은 "Your code is 1234 5678"이 칸에서 "12345678"이 된다)
    @State private var typed = ""

    var body: some View {
        VStack(spacing: TFSpace.md) {
            if let status = model.status {
                // 긴 주소는 가운데를 줄여 끝(.co)이 남게 한다
                Text(status.text(address: model.address))
                    .font(TFFont.callout)
                    .foregroundStyle(TFColor.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .accessibilityLabel(status.text(address: model.address))
            }
            SignInField(
                label: SignInCopy.codeLabel, text: $typed, hint: model.line?.text, monospaced: true, oneTimeCode: true, readOnly: model.isVerifying,
                focusRequest: model.selectAllRequests, onSubmit: { model.submitCode() })
            PrimaryBlockButton(
                title: SignInCopy.signIn, loading: model.isVerifying, disabled: !model.canSubmitCode, help: EmailSignInHelp.signIn(model)
            ) { model.submitCode() }
            // 다시 받기: 막힌 동안에도 글자는 그대로다 (숫자 카운트다운 없음). 1초마다 다시 읽어 열린다
            TimelineView(.periodic(from: .now, by: 1)) { context in
                HStack(spacing: TFSpace.md) {
                    let help = EmailSignInHelp.resend(model, at: context.date)
                    Button(SignInCopy.resendCode) { model.resend() }
                        .buttonStyle(TFButtonStyle(.text, size: .md))
                        .disabled(!model.canResend(at: context.date))
                        .help(help ?? "")
                        .accessibilityHint(help ?? "")
                    Button(SignInCopy.useDifferentEmail) { model.useDifferentEmail() }
                        .buttonStyle(TFButtonStyle(.text, size: .md))
                        .disabled(model.isSending || model.isVerifying)
                }
                .onChange(of: context.date) { model.refresh() }
            }
        }
        .onAppear { typed = model.codeInput }
        .onChange(of: typed) { _, new in
            model.setCode(new)
            if model.codeInput != new { typed = model.codeInput }
        }
        // 모델이 바뀌어도(다시 받기로 비움 · 흐름을 떠남) 칸이 따라간다
        .onChange(of: model.codeInput) { _, new in if typed != new { typed = new } }
    }
}
