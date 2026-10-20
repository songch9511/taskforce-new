#if os(macOS)
import AppKit
import SwiftUI
import Testing
import TaskforceKit
@testable import TaskforceUI

/// 설정 행의 비밀 한 줄 칸 (OA 결제 계약 6.4 · 9.3 · 16.4): 접근성 이름 · 값은 한 번 읽고 칸을 비운다 · UserDefaults · Keychain · 로그에 남기지 않는다
@MainActor
@Suite(.serialized)
struct SecureFieldSmTests {
    private func host(_ view: some View) -> (NSWindow, NSView) {
        let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 400, height: 80), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: view.frame(width: 360, height: 60))
        window.contentView = host
        window.alphaValue = 0
        window.orderFront(nil)
        host.layoutSubtreeIfNeeded()
        return (window, host)
    }

    private func field(in view: NSView) -> SecretNSField? {
        if let field = view as? SecretNSField { return field }
        for child in view.subviews { if let found = field(in: child) { return found } }
        return nil
    }

    /// SwiftUI가 AppKit 칸을 만들 때까지 실행 루프를 돌린다 (고정 sleep 대신 조건)
    private func waitForField(in view: NSView, timeout: TimeInterval = 30) async -> SecretNSField? {
        let deadline = Date().addingTimeInterval(timeout)
        while field(in: view) == nil, Date() < deadline {
            view.layoutSubtreeIfNeeded()
            try? await Task.sleep(for: .milliseconds(20))
        }
        return field(in: view)
    }

    @Test func theFieldIsASecureOneNamedForScreenReadersWithTheGivenPlaceholderAtThirteenPoints() async throws {
        let handle = SecureFieldSmHandle()
        let (window, view) = host(SecureFieldSm(label: "OpenRouter key", placeholder: "sk-or-…", handle: handle, onSubmit: { _ in }))
        defer { window.orderOut(nil) }
        let field = try #require(await waitForField(in: view))
        #expect(field.isKind(of: NSSecureTextField.self))
        #expect(field.accessibilityLabel() == "OpenRouter key")
        #expect(field.placeholderString == "sk-or-…")
        #expect(field.font?.pointSize == 13, "설정 행의 작은 칸은 13")
        #expect(!field.isBordered && !field.drawsBackground, "칸의 면 · 가장자리는 DS 트레이 모양이 그린다")
    }

    @Test func submittingSendsTheValueOnceAsASecretBoxAndEmptiesTheFieldAndItsUndoHistory() async throws {
        var received: [SecretBox] = []
        let handle = SecureFieldSmHandle()
        let (window, view) = host(SecureFieldSm(label: "OpenRouter key", handle: handle, onSubmit: { received.append($0) }))
        defer { window.orderOut(nil) }
        let field = try #require(await waitForField(in: view))
        field.stringValue = "sk-or-v1-0123456789abcdef0123"
        handle.submit()
        #expect(received.count == 1 && received.first?.reveal() == "sk-or-v1-0123456789abcdef0123")
        #expect(field.stringValue.isEmpty, "보낸 뒤 칸을 비운다")
        #expect(field.undoManager?.canUndo != true)
        handle.submit()
        #expect(received.count == 1, "빈 칸은 보내지 않는다")
    }

    @Test func theBoxHidesTheValueFromEveryWayOfPrintingIt() {
        let box = SecretBox("sk-or-v1-NEVER-SHOW")
        #expect("\(box)" == "<secret>" && String(reflecting: box) == "<secret>" && Mirror(reflecting: box).children.isEmpty)
    }

    @Test func theValueNeverReachesThePreferencesOfTheProcess() async throws {
        let secret = "sk-or-v1-NOT-IN-DEFAULTS-9876543210"
        let handle = SecureFieldSmHandle()
        let (window, view) = host(SecureFieldSm(label: "OpenRouter key", handle: handle, onSubmit: { _ in }))
        defer { window.orderOut(nil) }
        let field = try #require(await waitForField(in: view))
        field.stringValue = secret
        handle.submit()
        let dump = UserDefaults.standard.dictionaryRepresentation().map { "\($0.key)=\($0.value)" }.joined(separator: "\n")
        #expect(!dump.contains(secret))
    }

    /// 소스 모양: 이 부품 · 화면 파일은 저장 · 로그 길이 없다 (값이 디스크 · 로그로 갈 길을 막는다)
    @Test func theSourcesHaveNoPersistenceOrLoggingPath() throws {
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "../../Sources/TaskforceUI").standardized
        for name in ["SecureFieldSm.swift", "PlanSummaryView.swift"] {
            let source = try String(contentsOf: directory.appending(path: name), encoding: .utf8)
            let code = source.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }.joined(separator: "\n")
            for forbidden in ["UserDefaults", "AppStorage", "SceneStorage", "Keychain", "SecItem", "print(", "NSLog", "os_log", "Logger(", "debugPrint", "dump("] {
                #expect(!code.contains(forbidden), "\(name)에 \(forbidden)")
            }
        }
    }
}
#endif
