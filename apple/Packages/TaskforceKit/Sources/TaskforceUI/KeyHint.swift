import SwiftUI

/// Key (Figma 202:1756): 테두리만 있는 키캡. 키 하나에 상자 하나(⌘ · K 따로), Return은 그린 기호라 이모지로 바뀌지 않는다.
/// 런처 액션 바 · ⌘K 메뉴의 단축키 표시. (지금 화면의 채운 `Keycap`은 PR4 · PR5가 화면을 바꿀 때 이것으로 옮긴다.)
public struct KeyHint: View {
    public enum Key: Sendable, Hashable {
        case text(String)
        /// ↩ (SF Symbol `return`으로 그린다)
        case returnKey
    }

    let keys: [Key]

    /// "⌘K" · "⌘↩" · "⌥Space" · "esc"
    public init(_ shortcut: String) {
        keys = Self.keys(shortcut)
    }

    public init(keys: [Key]) {
        self.keys = keys
    }

    nonisolated static let modifiers: Set<Character> = ["⌘", "⌥", "⌃", "⇧"]

    /// 단축키 글자를 키로 나눈다: 수정 키(⌘ ⌥ ⌃ ⇧)는 하나씩, ↩는 그린 기호, 나머지 이어진 글자는 키 하나 ("Space" · "esc")
    nonisolated public static func keys(_ shortcut: String) -> [Key] {
        var keys: [Key] = []
        var pending = ""
        func flush() {
            if !pending.isEmpty { keys.append(.text(pending)) }
            pending = ""
        }
        for character in shortcut where !character.isWhitespace {
            if modifiers.contains(character) {
                flush()
                keys.append(.text(String(character)))
            } else if character == "↩" {
                flush()
                keys.append(.returnKey)
            } else {
                pending.append(character)
            }
        }
        flush()
        return keys
    }

    /// VoiceOver: "Command K"
    nonisolated public static func spokenName(_ keys: [Key]) -> String {
        keys.map { key in
            switch key {
            case .returnKey: "Return"
            case .text("⌘"): "Command"
            case .text("⌥"): "Option"
            case .text("⌃"): "Control"
            case .text("⇧"): "Shift"
            case .text("⌫"): "Delete"
            case .text(let text): text
            }
        }
        .joined(separator: " ")
    }

    public var body: some View {
        HStack(spacing: 3) {
            ForEach(Array(keys.enumerated()), id: \.offset) { _, key in
                KeyCap(key: key)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.spokenName(keys))
    }
}

/// 키 상자 하나: 20×20부터, 안쪽 4, r5, 1pt text/secondary 테두리, 글자 11 semibold
private struct KeyCap: View {
    let key: KeyHint.Key

    var body: some View {
        Group {
            switch key {
            case .text(let text):
                Text(text).font(TFFont.key)
            case .returnKey:
                Image(systemName: "return").font(.system(size: 9, weight: .semibold))
            }
        }
        .foregroundStyle(TFColor.textSecondary)
        .lineLimit(1)
        .padding(.horizontal, TFSpace.xs)
        .frame(minWidth: 20, minHeight: 20)
        .overlay(RoundedRectangle(cornerRadius: TFRadius.sm, style: .continuous).strokeBorder(TFColor.textSecondary, lineWidth: 1))
    }
}

#Preview("Key hint") {
    HStack(spacing: 12) {
        KeyHint("⌘K")
        KeyHint("↩")
        KeyHint("⌘↩")
        KeyHint("⌘R")
        KeyHint("esc")
        KeyHint("⌥Space")
    }
    .padding()
}
