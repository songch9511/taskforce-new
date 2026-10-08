import Carbon.HIToolbox
import Testing
import TaskforceKit
@testable import Taskforce

@MainActor
struct HotKeyCenterTests {
    private let custom = HotKeyShortcut(keyCode: 40, modifiers: HotKeyShortcut.Modifier.command, keyLabel: "K")

    @Test func rejectedStartupRemainsInactiveUntilRetrySucceeds() throws {
        let reference = try #require(EventHotKeyRef(bitPattern: 1))
        var reject = true
        let center = HotKeyCenter(id: 2, register: { _, _ in reject ? nil : reference }, unregister: { _ in })
        #expect(!center.register(custom))
        #expect(!center.isRegistered)
        #expect(center.current == nil)
        reject = false
        #expect(center.register(custom))
        #expect(center.isRegistered)
        #expect(center.current == custom)
    }

    @Test func failedReplacementAndResetKeepWorkingRegistration() throws {
        var rejectDefault = false
        var removed: [EventHotKeyRef] = []
        let reference = try #require(EventHotKeyRef(bitPattern: 1))
        let center = HotKeyCenter(register: { shortcut, _ in
            rejectDefault && shortcut.matches(.default) ? nil : reference
        }, unregister: { removed.append($0) })
        #expect(center.register(custom))
        rejectDefault = true
        #expect(!center.register(.default))
        #expect(center.current == custom)
        #expect(removed.isEmpty)
        var calls = 0
        center.onPress = { calls += 1 }
        #expect(center.handle(signature: 0x5446_4C4E, id: 1) == noErr)
        #expect(calls == 1)
    }

    @Test func eventRoutingRejectsOtherIdentifiersAndSuspendedKeys() throws {
        let reference = try #require(EventHotKeyRef(bitPattern: 1))
        let launcher = HotKeyCenter(register: { _, _ in reference }, unregister: { _ in })
        let settings = HotKeyCenter(id: 2, register: { _, _ in reference }, unregister: { _ in })
        #expect(launcher.register(.default))
        #expect(settings.register(custom))
        var launcherCalls = 0
        var settingsCalls = 0
        launcher.onPress = { launcherCalls += 1 }
        settings.onPress = { settingsCalls += 1 }
        #expect(launcher.handle(signature: 0x5446_4C4E, id: 2) == eventNotHandledErr)
        #expect(settings.handle(signature: 0x5446_4C4E, id: 2) == noErr)
        #expect(settings.handle(signature: 0, id: 2) == eventNotHandledErr)
        #expect(settings.handle(signature: 0x5446_4C4E, id: 1) == eventNotHandledErr)
        #expect(launcherCalls == 0)
        #expect(settingsCalls == 1)
        settings.suspend()
        #expect(settings.handle(signature: 0x5446_4C4E, id: 2) == eventNotHandledErr)
        #expect(settings.resume())
        #expect(settings.handle(signature: 0x5446_4C4E, id: 2) == noErr)
        #expect(settingsCalls == 2)
        settings.remove()
        #expect(settings.current == nil)
        #expect(settings.handle(signature: 0x5446_4C4E, id: 2) == eventNotHandledErr)
    }

    @Test func repeatedSuspendResumeDoesNotDuplicateRegistrationAndCanRetryFailure() throws {
        let reference = try #require(EventHotKeyRef(bitPattern: 1))
        var registrations = 0
        var removals = 0
        var fail = false
        let center = HotKeyCenter(register: { _, _ in
            registrations += 1
            return fail ? nil : reference
        }, unregister: { _ in removals += 1 })
        #expect(center.register(custom))
        center.suspend()
        center.suspend()
        #expect(removals == 1)
        fail = true
        #expect(!center.resume())
        #expect(center.current == custom)
        #expect(center.isSuspended)
        fail = false
        #expect(center.resume())
        #expect(center.resume())
        #expect(registrations == 3)
        #expect(!center.isSuspended)
    }

    @Test func sameKeyDifferentLabelDoesNotReregister() throws {
        let reference = try #require(EventHotKeyRef(bitPattern: 1))
        var registrations = 0
        let center = HotKeyCenter(register: { _, _ in registrations += 1; return reference }, unregister: { _ in })
        #expect(center.register(.default))
        #expect(center.register(HotKeyShortcut(keyCode: 49, modifiers: HotKeyShortcut.Modifier.option, keyLabel: "Spacebar")))
        #expect(registrations == 1)
        #expect(center.current?.keyLabel == "Spacebar")
    }
}
