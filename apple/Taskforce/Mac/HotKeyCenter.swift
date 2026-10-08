#if os(macOS)
import AppKit
import Carbon.HIToolbox
import TaskforceKit

/// 전역 단축키 (기본 ⌥Space). Carbon `RegisterEventHotKey`는 샌드박스 안에서도 손쉬운 사용 권한 없이 동작한다.
@MainActor
final class HotKeyCenter {
    var onPress: (() -> Void)?
    private(set) var current: HotKeyShortcut?
    private(set) var isSuspended = false
    var isRegistered: Bool { hotKeyRef != nil && !isSuspended }

    private let identifier: EventHotKeyID
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private let registerKey: (HotKeyShortcut, EventHotKeyID) -> EventHotKeyRef?
    private let unregisterKey: (EventHotKeyRef) -> Void

    init(id: UInt32 = 1,
         register: @escaping (HotKeyShortcut, EventHotKeyID) -> EventHotKeyRef? = { shortcut, identifier in
             var reference: EventHotKeyRef?
             let status = RegisterEventHotKey(
                 shortcut.keyCode, shortcut.modifiers, identifier, GetApplicationEventTarget(), 0, &reference
             )
             return status == noErr ? reference : nil
         },
         unregister: @escaping (EventHotKeyRef) -> Void = { UnregisterEventHotKey($0) }) {
        identifier = EventHotKeyID(signature: OSType(0x5446_4C4E), id: id)
        registerKey = register
        unregisterKey = unregister
    }

    func install() {
        guard handlerRef == nil else { return }
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData in
                guard let event, let userData else { return OSStatus(eventNotHandledErr) }
                var identifier = EventHotKeyID()
                let status = GetEventParameter(
                    event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                    nil, MemoryLayout<EventHotKeyID>.size, nil, &identifier
                )
                guard status == noErr else { return OSStatus(eventNotHandledErr) }
                return MainActor.assumeIsolated {
                    Unmanaged<HotKeyCenter>.fromOpaque(userData).takeUnretainedValue()
                        .handle(signature: identifier.signature, id: identifier.id)
                }
            },
            1, &eventType, Unmanaged.passUnretained(self).toOpaque(), &handlerRef
        )
    }

    func handle(signature: OSType, id: UInt32) -> OSStatus {
        guard signature == identifier.signature, id == identifier.id,
              !isSuspended, hotKeyRef != nil else { return OSStatus(eventNotHandledErr) }
        onPress?()
        return noErr
    }

    /// Attach the replacement first, so a failed registration never removes the working shortcut.
    @discardableResult
    func register(_ shortcut: HotKeyShortcut) -> Bool {
        guard shortcut.isValid else { return false }
        if current?.matches(shortcut) == true, hotKeyRef != nil {
            current = shortcut
            return true
        }
        guard let replacement = registerKey(shortcut, identifier) else { return false }
        if let hotKeyRef { unregisterKey(hotKeyRef) }
        hotKeyRef = replacement
        current = shortcut
        isSuspended = false
        return true
    }

    func remove() {
        if let hotKeyRef { unregisterKey(hotKeyRef) }
        hotKeyRef = nil
        current = nil
        isSuspended = false
    }

    func suspend() {
        guard !isSuspended else { return }
        if let hotKeyRef { unregisterKey(hotKeyRef) }
        hotKeyRef = nil
        isSuspended = true
    }

    @discardableResult
    func resume() -> Bool {
        guard isSuspended else { return true }
        guard let current else { isSuspended = false; return true }
        guard let reference = registerKey(current, identifier) else { return false }
        hotKeyRef = reference
        isSuspended = false
        return true
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
