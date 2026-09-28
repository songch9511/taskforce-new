import Foundation

/// Mac 런처를 여는 전역 단축키 (기본 ⌥Space). Carbon `RegisterEventHotKey`가 받는 키 코드와 수정 키 값을 그대로 담는다.
/// 패키지는 iOS에서도 빌드되므로 Carbon 상수를 숫자로 둔다 (HIToolbox Events.h).
public struct HotKeyShortcut: Codable, Equatable, Sendable {
    public enum Modifier {
        public static let command: UInt32 = 1 << 8
        public static let shift: UInt32 = 1 << 9
        public static let option: UInt32 = 1 << 11
        public static let control: UInt32 = 1 << 12
        public static let all = command | shift | option | control
    }

    /// kVK_Space
    public static let spaceKeyCode: UInt32 = 0x31
    public static let `default` = HotKeyShortcut(keyCode: spaceKeyCode, modifiers: Modifier.option, keyLabel: "Space")

    public let keyCode: UInt32
    public let modifiers: UInt32
    /// 기록할 때 누른 키 글자 ("Space", "K" …)
    public let keyLabel: String

    public init(keyCode: UInt32, modifiers: UInt32, keyLabel: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers & Modifier.all
        self.keyLabel = keyLabel
    }

    /// "⌃⌥⇧⌘" 순서 (macOS 메뉴와 같은 순서) + 키
    public var displayLabel: String {
        var label = ""
        if modifiers & Modifier.control != 0 { label += "⌃" }
        if modifiers & Modifier.option != 0 { label += "⌥" }
        if modifiers & Modifier.shift != 0 { label += "⇧" }
        if modifiers & Modifier.command != 0 { label += "⌘" }
        return label + keyLabel
    }

    /// Shift만으로는 글자 입력과 겹치므로 ⌘ · ⌥ · ⌃ 중 하나는 있어야 한다
    public var isValid: Bool {
        modifiers & (Modifier.command | Modifier.option | Modifier.control) != 0 && !keyLabel.isEmpty
    }

    static let defaultsKey = "launcher.hotKey"

    public static func load(from defaults: UserDefaults = .standard) -> HotKeyShortcut {
        guard let data = defaults.data(forKey: defaultsKey),
              let shortcut = try? JSONDecoder().decode(HotKeyShortcut.self, from: data),
              shortcut.isValid
        else { return .default }
        return shortcut
    }

    public func save(to defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }

    public static func reset(in defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: defaultsKey)
    }
}
