import SwiftUI

/// Key (Figma 202:1756): 테두리만 있는 키캡. 키 하나에 상자 하나(⌘ · K 따로), Return은 그린 기호라 이모지로 바뀌지 않는다.
/// 런처 액션 바 · ⌘K 메뉴의 단축키 표시. (채운 `Keycap`은 런처 ⌘K 패널(U6a M7 전) · 설정 단축키 칸이 아직 쓴다.)
public struct KeyHint: View {
    public enum Key: Sendable, Hashable {
        case text(String)
        /// ↩ (SF Symbol `return`으로 그린다)
        case returnKey
    }

    let keys: [Key]
    let onFill: Bool

    /// "⌘K" · "⌘↩" · "⌥Space" · "esc". 키 글자는 text/primary (액션 바는 반투명 유리 위: Figma의 text/secondary는
    /// 창 뒤가 가장 나쁜 바탕이면 4.5:1에 못 미쳐 바꿈, 사용자 결정 2026-10-03, `GlassContrastTests`).
    /// `onFill`: 회색 면(settings/fill, 액션 바 Return 동작 알약) 위. 불투명 면이라 그대로 text/secondary-selected (4.5:1 이상, `ContrastTests`).
    public init(_ shortcut: String, onFill: Bool = false) {
        keys = Self.keys(shortcut)
        self.onFill = onFill
    }

    public init(keys: [Key], onFill: Bool = false) {
        self.keys = keys
        self.onFill = onFill
    }

    /// 키 하나에 상자 하나인 글자: 수정 키와 화살표
    nonisolated static let singleKeys: Set<Character> = ["⌘", "⌥", "⌃", "⇧", "↑", "↓", "←", "→"]

    /// 단축키 글자를 키로 나눈다: 수정 키(⌘ ⌥ ⌃ ⇧) · 화살표는 하나씩, ↩는 그린 기호, 나머지 이어진 글자는 키 하나 ("Space" · "esc")
    nonisolated public static func keys(_ shortcut: String) -> [Key] {
        var keys: [Key] = []
        var pending = ""
        func flush() {
            if !pending.isEmpty { keys.append(.text(pending)) }
            pending = ""
        }
        for character in shortcut where !character.isWhitespace {
            if singleKeys.contains(character) {
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
            case .text("↑"): "Up Arrow"
            case .text("↓"): "Down Arrow"
            case .text("←"): "Left Arrow"
            case .text("→"): "Right Arrow"
            case .text(let text): text
            }
        }
        .joined(separator: " ")
    }

    public var body: some View {
        HStack(spacing: 3) {
            ForEach(Array(keys.enumerated()), id: \.offset) { _, key in
                KeyCap(key: key, color: onFill ? TFColor.textSecondarySelected : TFColor.textPrimary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.spokenName(keys))
    }
}

/// 키 상자 하나: 20×20부터, 안쪽 4, r5, 1pt 글자색 테두리, 글자 11 semibold
private struct KeyCap: View {
    let key: KeyHint.Key
    let color: Color

    var body: some View {
        Group {
            switch key {
            case .text(let text):
                Text(text).font(TFFont.key)
            case .returnKey:
                Image(systemName: "return").font(.system(size: 9, weight: .semibold))
            }
        }
        .foregroundStyle(color)
        .lineLimit(1)
        .padding(.horizontal, TFSpace.xs)
        .frame(minWidth: 20, minHeight: 20)
        .overlay(RoundedRectangle(cornerRadius: TFRadius.sm, style: .continuous).strokeBorder(color, lineWidth: 1))
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
