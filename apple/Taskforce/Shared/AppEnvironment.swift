import SwiftUI
import TaskforceKit
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

extension EnvironmentValues {
    /// Startup이 만든 서비스 묶음 (설정이 빠졌으면 nil)
    @Entry var services: AppServices?
}

extension View {
    /// 오류 · 안내 한 줄을 알림으로
    func messageAlert(_ message: Binding<String?>) -> some View {
        alert(
            message.wrappedValue ?? "",
            isPresented: Binding(get: { message.wrappedValue != nil }, set: { if !$0 { message.wrappedValue = nil } })
        ) {
            Button("OK", role: .cancel) {}
        }
    }
}

enum Clipboard {
    static func copy(_ text: String) {
        #if canImport(UIKit)
        UIPasteboard.general.string = text
        #elseif canImport(AppKit)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
    }

    static var text: String? {
        #if canImport(UIKit)
        UIPasteboard.general.string
        #elseif canImport(AppKit)
        NSPasteboard.general.string(forType: .string)
        #endif
    }
}

extension Error {
    /// 화면에 보여 줄 한 줄 (영어 틀)
    var userMessage: String {
        (self as? APIError)?.userMessage ?? "Something went wrong. Try again in a moment."
    }
}

/// 로그인해 있는 동안 하나만 두는 `actions` Realtime 구독. 화면은 `revision`이 바뀌면 다시 불러온다.
/// 화면마다 구독하면 채널을 만들고 지우기를 되풀이해 신호를 놓치기 쉽다.
@MainActor
@Observable
final class ActionChangeFeed {
    /// Realtime 신호가 (묶여서) 올 때마다 1씩 오른다
    private(set) var revision = 0

    func follow(services: AppServices, userID: UUID) async {
        while !Task.isCancelled {
            for await _ in services.actionChanges(userID: userID) {
                revision += 1
            }
            // 구독이 안 되거나 끊겼으면 잠시 뒤 다시 붙는다 (그동안은 새로고침 · 화면 복귀 때 불러온다)
            try? await Task.sleep(for: .seconds(15))
        }
    }
}

extension AppOpenTracker.Phase {
    init(_ phase: ScenePhase) {
        switch phase {
        case .active: self = .active
        case .background: self = .background
        default: self = .inactive
        }
    }
}
