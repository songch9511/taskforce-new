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

    /// 키캡 하나씩: 수식키(⌃ ⌥ ⇧ ⌘ 순서) 뒤에 키 (0.2.0 설정 창 `KeyCombo` · `ShortcutRecorder`)
    public var keyCaps: [String] {
        [(Modifier.control, "⌃"), (Modifier.option, "⌥"), (Modifier.shift, "⇧"), (Modifier.command, "⌘")]
            .filter { modifiers & $0.0 != 0 }
            .map(\.1) + [keyLabel]
    }

    /// Shift만으로는 글자 입력과 겹치므로 ⌘ · ⌥ · ⌃ 중 하나는 있어야 한다
    public var isValid: Bool {
        keyCode <= 0x7F && modifiers & ~Modifier.all == 0
            && modifiers & (Modifier.command | Modifier.option | Modifier.control) != 0
            && !keyLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public func matches(_ other: HotKeyShortcut) -> Bool {
        keyCode == other.keyCode && modifiers == other.modifiers
    }

    public enum Action: Sendable {
        case launcher, settings

        var defaultsKey: String {
            switch self {
            case .launcher: "launcher.hotKey"
            case .settings: "settings.hotKey"
            }
        }
    }

    public static func load(for action: Action, from defaults: UserDefaults = .standard) -> HotKeyShortcut? {
        guard let data = defaults.data(forKey: action.defaultsKey),
              let shortcut = try? JSONDecoder().decode(HotKeyShortcut.self, from: data),
              shortcut.isValid
        else { return action == .launcher ? .default : nil }
        return shortcut
    }

    public func save(for action: Action, to defaults: UserDefaults = .standard) {
        guard isValid, let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: action.defaultsKey)
    }

    public static func reset(for action: Action, in defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: action.defaultsKey)
    }

    public static func load(from defaults: UserDefaults = .standard) -> HotKeyShortcut {
        load(for: .launcher, from: defaults) ?? .default
    }

    public func save(to defaults: UserDefaults = .standard) {
        save(for: .launcher, to: defaults)
    }

    public static func reset(in defaults: UserDefaults = .standard) {
        reset(for: .launcher, in: defaults)
    }
}
