import Foundation
import Testing
@testable import TaskforceKit

struct HotKeyShortcutTests {
    @Test func separatePreferencesAndResets() throws {
        let name = "hotkeys-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let launcher = HotKeyShortcut(keyCode: 40, modifiers: .init(1 << 8), keyLabel: "K")
        let settings = HotKeyShortcut(keyCode: 43, modifiers: .init(1 << 11), keyLabel: ",")
        #expect(HotKeyShortcut.load(for: .settings, from: defaults) == nil)
        launcher.save(to: defaults)
        settings.save(for: .settings, to: defaults)
        #expect(HotKeyShortcut.load(from: defaults) == launcher)
        #expect(HotKeyShortcut.load(for: .settings, from: defaults) == settings)
        HotKeyShortcut.reset(in: defaults)
        #expect(HotKeyShortcut.load(from: defaults) == .default)
        #expect(HotKeyShortcut.load(for: .settings, from: defaults) == settings)
        launcher.save(to: defaults)
        HotKeyShortcut.reset(for: .settings, in: defaults)
        #expect(HotKeyShortcut.load(from: defaults) == launcher)
        #expect(HotKeyShortcut.load(for: .settings, from: defaults) == nil)
    }

    @Test func corruptAndInvalidPreferencesUseActionDefaults() throws {
        let name = "hotkeys-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        for data in [
            Data("broken".utf8),
            Data(#"{"keyCode":999,"modifiers":256,"keyLabel":"K"}"#.utf8),
            Data(#"{"keyCode":40,"modifiers":257,"keyLabel":"K"}"#.utf8),
            Data(#"{"keyCode":40,"modifiers":0,"keyLabel":"K"}"#.utf8)
        ] {
            defaults.set(data, forKey: "launcher.hotKey")
            defaults.set(data, forKey: "settings.hotKey")
            #expect(HotKeyShortcut.load(from: defaults) == .default)
            #expect(HotKeyShortcut.load(for: .settings, from: defaults) == nil)
        }
    }

    @Test func collisionIgnoresLabels() {
        let translated = HotKeyShortcut(keyCode: 49, modifiers: HotKeyShortcut.Modifier.option, keyLabel: "Spacebar")
        #expect(translated.matches(.default))
        #expect(!HotKeyShortcut(keyCode: 49, modifiers: HotKeyShortcut.Modifier.command, keyLabel: "Space").matches(.default))
    }
}
