#if os(macOS)
import AppKit
import SwiftUI
import TaskforceKit
import TaskforceUI

// 세션 보기 V1의 복사 (DZ oa-session-view-dz v2 E4 · E5, 사용자 승인 2026-10-22): 답 밑 오른쪽 아이콘(마우스를 올리거나 포커스가 있을 때만) · 코드 블록 머리의 아이콘(늘 보임).
// 복사하는 것은 **원문**이다 (보이는 모양이 아니다): 마지막 답의 마크다운 원문, 코드 블록은 울타리 줄 없는 글자. 누르면 그 자리에서 "Copied"가 1.5초.
// 클립보드에만 쓴다: 서버 · 로그 · 지표 0.

/// 복사가 쓰는 클립보드 (시험은 기록만 하는 가짜로 바꾼다)
protocol SessionPasteboarding: AnyObject, Sendable {
    func copy(_ text: String)
}

final class SystemSessionPasteboard: SessionPasteboarding {
    func copy(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}

private struct SessionPasteboardKey: EnvironmentKey {
    static let defaultValue: any SessionPasteboarding = SystemSessionPasteboard()
}

extension EnvironmentValues {
    var sessionPasteboard: any SessionPasteboarding {
        get { self[SessionPasteboardKey.self] }
        set { self[SessionPasteboardKey.self] = newValue }
    }
}

/// 복사 직후의 "Copied" 상태: 누른 뒤 `duration`초가 지나면 돌아온다 (다시 누르면 시계를 새로 센다). 시계는 시험이 바꾼다
@MainActor
@Observable
final class SessionCopyFeedback {
    /// 복사 피드백이 머무는 시간 (DZ v2 E12: 1.5초)
    static let duration: TimeInterval = 1.5

    private(set) var copied = false
    @ObservationIgnored private var reset: Task<Void, Never>?
    @ObservationIgnored private let sleep: @Sendable (TimeInterval) async -> Void

    init(sleep: @escaping @Sendable (TimeInterval) async -> Void = { try? await Task.sleep(for: .seconds($0)) }) {
        self.sleep = sleep
    }

    /// 글을 클립보드에 쓰고 "Copied"를 보인다. 보낼 글이 비었으면 아무 일도 없다 (빈 글로 클립보드를 지우지 않는다)
    func copy(_ text: String, to pasteboard: any SessionPasteboarding) {
        guard !text.isEmpty else { return }
        pasteboard.copy(text)
        copied = true
        reset?.cancel()
        let sleep = sleep
        reset = Task { [weak self] in
            await sleep(Self.duration)
            guard !Task.isCancelled else { return }
            self?.copied = false
        }
    }

    deinit { reset?.cancel() }
}

/// 복사 단추 (DS IconButton 28 · 아이콘 14): 평상시 `text/secondary`, 호버 `text/primary` + `bg/selected`. 누르면 같은 자리가 check + "Copied"(13/18 `text/primary`)로 바뀐다.
/// - alwaysVisible: 코드 블록 머리는 늘 보인다. 답 밑 줄은 `revealed`(답 위 호버) · 포커스 · 복사 직후에만 (자리는 늘 잡혀 있어 글이 밀리지 않는다)
/// - onField: `bg/field` 위에서는 보조 글을 `text/secondary-selected`로 올린다 (다크에서 `text/secondary`는 필드 위 AA 미달)
struct SessionCopyButton: View {
    let text: String
    var alwaysVisible = true
    var revealed = false
    var onField = false
    @State private var feedback = SessionCopyFeedback()
    @State private var hovering = false
    @FocusState private var focused: Bool
    @Environment(\.sessionPasteboard) private var pasteboard

    /// 보이나: 늘 보이는 단추 · 답 위 호버 · 포커스 · 복사 직후
    static func isVisible(alwaysVisible: Bool, revealed: Bool, focused: Bool, copied: Bool) -> Bool {
        alwaysVisible || revealed || focused || copied
    }

    var body: some View {
        let visible = Self.isVisible(alwaysVisible: alwaysVisible, revealed: revealed, focused: focused, copied: feedback.copied)
        Button { feedback.copy(text, to: pasteboard) } label: {
            if feedback.copied {
                HStack(spacing: TFSpace.xs) {
                    TFIcon.check.image(size: 14)
                    Text(SessionViewCopy.copied).font(TFFont.footnote).tracking(-0.08)
                }
                .foregroundStyle(TFColor.textPrimary)
                .frame(height: 28)
                .padding(.horizontal, TFSpace.xs)
            } else {
                TFIcon.copy.image(size: 14)
                    .foregroundStyle(hovering ? TFColor.textPrimary : (onField ? TFColor.textSecondarySelected : TFColor.textSecondary))
                    .frame(width: 28, height: 28)
                    .background(hovering ? TFColor.bgSelected : Color.clear, in: RoundedRectangle(cornerRadius: TFRadius.sm, style: .continuous))
            }
        }
        .buttonStyle(.plain)
        .focused($focused)
        .overlay {
            if focused { RoundedRectangle(cornerRadius: TFRadius.sm, style: .continuous).strokeBorder(TFColor.borderAccent, lineWidth: 2).padding(-3) }
        }
        .opacity(visible ? 1 : 0)
        .onHover { hovering = $0 }
        .animation(TFMotion.ease(TFMotion.hoverFade), value: visible)
        .animation(TFMotion.ease(TFMotion.hoverFade), value: hovering)
        .accessibilityLabel(feedback.copied ? SessionViewCopy.copied : SessionViewCopy.copy)
        .help(SessionViewCopy.copy)
        .onChange(of: feedback.copied) { _, copied in
            // 시작 · 끝만 알린다 (VoiceOver)
            if copied { AccessibilityNotification.Announcement(SessionViewCopy.copied).post() }
        }
    }
}
#endif
