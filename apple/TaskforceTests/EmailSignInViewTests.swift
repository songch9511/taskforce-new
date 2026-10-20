import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Taskforce
@testable import TaskforceKit

/// 이메일 6자리 코드 로그인 화면 (OA 이메일 로그인 11.2, 사용자 승인 2026-10-20): 막힌 버튼의 이유 · 단계 화면이 실제로 그려진다.
/// 실제 메일 · Supabase 0: 모델은 서버가 없는 가짜 장면(`debugForce`)이다. 시험 호스트(Debug-Test, 격리 번들 ID)에서만 돈다.
@MainActor
struct EmailSignInViewTests {
    /// 고정 시계: 다시 받기 60초 잠금을 시계로 시험한다
    final class Clock: @unchecked Sendable {
        let lock = NSLock()
        var current = Date(timeIntervalSince1970: 1_800_000_000)
        var now: Date { lock.withLock { current } }
        func advance(_ seconds: TimeInterval) { lock.withLock { current = current.addingTimeInterval(seconds) } }
    }

    func model(_ clock: Clock = Clock()) -> EmailSignInModel {
        EmailSignInModel(transport: nil, now: { clock.now })
    }

    // MARK: 막힌 버튼의 이유 (글로 보이지 않는다)

    @Test func theResendReasonIsOnlyForTheLockedSixtySeconds() {
        let clock = Clock()
        let model = model(clock)
        model.debugForce(step: .code, address: "me@example.com", status: .codeSent, resendAvailableAt: clock.now.addingTimeInterval(60))
        #expect(EmailSignInHelp.resend(model, at: clock.now) == "Available in 60 seconds")
        clock.advance(17.5)
        #expect(EmailSignInHelp.resend(model, at: clock.now) == "Available in 43 seconds")
        clock.advance(42.5)
        #expect(EmailSignInHelp.resend(model, at: clock.now) == nil, "60초가 지나면 이유가 없다")
        // 이메일 단계에는 다시 받기가 없다
        model.debugForce(step: .email)
        #expect(EmailSignInHelp.resend(model, at: clock.now) == nil)
    }

    @Test func theSignInReasonIsOnlyBeforeSixDigits() {
        let model = model()
        model.debugForce(step: .code, address: "me@example.com", status: .codeSent)
        #expect(EmailSignInHelp.signIn(model) == "Enter the 6-digit code")
        model.debugForce(step: .code, address: "me@example.com", codeInput: "48291", status: .codeSent)
        #expect(EmailSignInHelp.signIn(model) == "Enter the 6-digit code")
        model.debugForce(step: .code, address: "me@example.com", codeInput: "482916", status: .codeSent)
        #expect(EmailSignInHelp.signIn(model) == nil)
        model.debugForce(step: .email)
        #expect(EmailSignInHelp.signIn(model) == nil)
    }

    // MARK: 화면이 실제로 그려진다

    /// 로그인 화면이 주는 폭(400)에 놓았을 때의 크기: 높이가 내용을 담는다 (폭은 칸이 비어 있으면 내용 폭이 작아 의미가 없다)
    func fitting(_ model: EmailSignInModel) -> CGSize {
        let host = NSHostingView(rootView: EmailSignInSteps(model: model).frame(width: 400).padding())
        host.frame = NSRect(x: 0, y: 0, width: 480, height: 520)
        host.layoutSubtreeIfNeeded()
        return host.fittingSize
    }

    @Test func theEmailStepLaysOutInEveryState() {
        let long = "alexandra.kim-henderson.design@shape-creative-studio.co"
        let scenes: [(String, EmailSignInModel)] = [
            ("empty", { let m = model(); m.debugForce(step: .email); return m }()),
            ("long", { let m = model(); m.debugForce(step: .email, emailInput: long); return m }()),
            ("sending", { let m = model(); m.debugForce(step: .email, emailInput: long, isSending: true); return m }()),
            ("invalid", { let m = model(); m.debugForce(step: .email, emailInput: "a@b", line: .addressInvalid); return m }()),
            ("couldnt", { let m = model(); m.debugForce(step: .email, emailInput: long, line: .couldntContinue); return m }()),
        ]
        for (name, scene) in scenes {
            let size = fitting(scene)
            #expect(size.width == 432 && size.height >= 100, "\(name) \(size)")
        }
    }

    @Test func theCodeStepLaysOutInEveryState() {
        let long = "alexandra.kim-henderson.design@shape-creative-studio.co"
        let later = Date().addingTimeInterval(45)
        let scenes: [(String, EmailSignInModel)] = [
            ("empty", { let m = model(); m.debugForce(step: .code, address: long, status: .codeSent, resendAvailableAt: later); return m }()),
            ("partial", { let m = model(); m.debugForce(step: .code, address: long, codeInput: "482", status: .codeSent); return m }()),
            ("verifying", { let m = model(); m.debugForce(step: .code, address: long, codeInput: "482916", status: .codeSent, isVerifying: true); return m }()),
            ("wrong", { let m = model(); m.debugForce(step: .code, address: long, codeInput: "482917", status: .codeSent, line: .wrongCode); return m }()),
            ("new", { let m = model(); m.debugForce(step: .code, address: long, status: .newCodeSent); return m }()),
        ]
        for (name, scene) in scenes {
            let size = fitting(scene)
            #expect(size.width == 432 && size.height >= 150, "\(name) \(size)")
        }
    }

    /// 첫 화면에는 단계 화면이 없다 (빈 칸 없이 접힌다)
    @Test func theMethodsStepDrawsNothing() {
        let m = model()
        m.debugForce(step: .methods)
        let size = fitting(m)
        #expect(size.height < 60, "\(size)")
    }
}
