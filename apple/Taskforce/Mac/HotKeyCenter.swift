#if os(macOS)
import AppKit
import Carbon.HIToolbox
import TaskforceKit

/// 전역 단축키 (기본 ⌥Space). Carbon `RegisterEventHotKey`는 샌드박스 안에서도 손쉬운 사용 권한 없이 동작한다.
@MainActor
final class HotKeyCenter {
    var onPress: (() -> Void)?
    private(set) var current: HotKeyShortcut?

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?

    /// 앱 이벤트 대상에 단축키 처리기를 한 번 붙인다. Carbon은 이 처리기를 메인 스레드에서 부른다.
    func install() {
        guard handlerRef == nil else { return }
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, userData in
                guard let userData else { return OSStatus(eventNotHandledErr) }
                MainActor.assumeIsolated {
                    Unmanaged<HotKeyCenter>.fromOpaque(userData).takeUnretainedValue().onPress?()
                }
                return noErr
            },
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &handlerRef
        )
    }

    /// 단축키를 바꾼다. 다른 앱이 이미 쓰고 있으면 false (이전 단축키는 그대로 둔다).
    @discardableResult
    func register(_ shortcut: HotKeyShortcut) -> Bool {
        let previous = current
        unregister()
        if attach(shortcut) {
            current = shortcut
            return true
        }
        if let previous, attach(previous) { current = previous }
        return false
    }

    private func attach(_ shortcut: HotKeyShortcut) -> Bool {
        var reference: EventHotKeyRef?
        // 'TFLN' (Taskforce launcher)
        let identifier = EventHotKeyID(signature: OSType(0x5446_4C4E), id: 1)
        let status = RegisterEventHotKey(
            shortcut.keyCode, shortcut.modifiers, identifier, GetApplicationEventTarget(), 0, &reference
        )
        guard status == noErr, let reference else { return false }
        hotKeyRef = reference
        return true
    }

    private func unregister() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        hotKeyRef = nil
    }
}

extension HotKeyShortcut {
    /// 설정에서 누른 키 → Carbon 키 코드 · 수정 키
    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var modifiers: UInt32 = 0
        if flags.contains(.command) { modifiers |= Modifier.command }
        if flags.contains(.shift) { modifiers |= Modifier.shift }
        if flags.contains(.option) { modifiers |= Modifier.option }
        if flags.contains(.control) { modifiers |= Modifier.control }
        let label: String
        switch Int(event.keyCode) {
        case kVK_Space: label = "Space"
        case kVK_Return: label = "↩"
        case kVK_Tab: label = "⇥"
        case kVK_Delete: label = "⌫"
        case kVK_LeftArrow: label = "←"
        case kVK_RightArrow: label = "→"
        case kVK_UpArrow: label = "↑"
        case kVK_DownArrow: label = "↓"
        case kVK_Escape: return nil
        default:
            guard let characters = event.charactersIgnoringModifiers?.uppercased(), !characters.isEmpty else { return nil }
            label = characters
        }
        self.init(keyCode: UInt32(event.keyCode), modifiers: modifiers, keyLabel: label)
    }
}
#endif
