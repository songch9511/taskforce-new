import Foundation
import Testing
@testable import TaskforceKit

struct ConnectionsTests {
    @Test func handoffCallbackMustBeCompleted() throws {
        let callback = try #require(ConnectionCallback.parse(URL(string: "taskforce://connections/notion?handoff=h_123abc")!))
        #expect(callback == ConnectionCallback(provider: .notion, outcome: .handoff("h_123abc")))
    }

    @Test func handoffWinsOverStatusAndBlankHandoffIsIgnored() throws {
        let both = try #require(ConnectionCallback.parse(URL(string: "taskforce://connections/slack?status=error&handoff=abc")!))
        #expect(both.outcome == .handoff("abc"))
        let blank = try #require(ConnectionCallback.parse(URL(string: "taskforce://connections/slack?handoff=&status=denied")!))
        #expect(blank.outcome == .status(.denied))
    }

    @Test(arguments: [
        ("connected", ConnectionCallback.Status.connected, true),
        ("connected_empty", .connectedEmpty, true),
        ("connected_no_meetings", .connectedNoMeetings, true),
        ("denied", .denied, false),
        ("error", .error, false),
        ("invalid_state", .invalidState, false),
        ("brand_new", .unknown("brand_new"), false),
    ])
    func callbackStatuses(_ raw: String, _ status: ConnectionCallback.Status, _ connected: Bool) throws {
        let callback = try #require(ConnectionCallback.parse(URL(string: "taskforce://connections/google?status=\(raw)")!))
        #expect(callback.provider == .google)
        #expect(callback.outcome == .status(status))
        #expect(status.isConnected == connected)
    }

    @Test func statusMessagesAreEnglishAndQuietOnPlainSuccessOrCancel() {
        #expect(ConnectionCallback.Status.connected.message == nil)
        #expect(ConnectionCallback.Status.denied.message == nil)
        #expect(ConnectionCallback.Status.invalidState.message == "The link expired. Try again.")
        #expect(ConnectionCallback.Status.error.message == "Couldn't connect. Try again.")
        #expect(ConnectionCallback.Status.connectedEmpty.message?.hasPrefix("Connected.") == true)
    }

    @Test func ignoresOtherURLs() {
        #expect(ConnectionCallback.parse(URL(string: "https://connections/notion?status=connected")!) == nil)
        #expect(ConnectionCallback.parse(URL(string: "taskforce://actions/123")!) == nil)
        let unknownProvider = ConnectionCallback.parse(URL(string: "taskforce://connections/myspace?handoff=x")!)
        #expect(unknownProvider == ConnectionCallback(provider: nil, outcome: .handoff("x")))
    }

    @Test func completeFailureClassification() {
        #expect(ConnectionCompleteFailure.classify(.server(status: 409, code: .conflict, message: "")) == .consentRequired)
        #expect(ConnectionCompleteFailure.classify(.server(status: 404, code: .notFound, message: "")) == .failed("Couldn't connect. Try again."))
        #expect(ConnectionCompleteFailure.classify(.unexpectedStatus(404)) == .failed("Couldn't connect. Try again."))
        #expect(ConnectionCompleteFailure.classify(.transport("offline")) == .failed("Can't reach the server. Check your connection."))
    }

    func record(_ provider: String, _ status: ConnectionStatus?, synced: TimeInterval? = nil) -> ConnectionRecord {
        ConnectionRecord(
            id: UUID(), provider: provider, displayName: "Acme", status: status,
            lastSyncedAt: synced.map { Date(timeIntervalSince1970: $0) }, lastError: nil
        )
    }

    @Test func stateNotConnectedWithoutRecords() {
        #expect(ConnectionState.state(for: .notion, in: [record("slack", .active)]) == .notConnected)
    }

    @Test func statePrefersActiveThenErrorThenReconnect() {
        let active = record("notion", .active, synced: 10)
        let failing = record("notion", .error, synced: 20)
        let expired = record("notion", .reauth)
        let revoked = record("notion", .revoked)
        #expect(ConnectionState.state(for: .notion, in: [expired, failing, active]) == .connected(active))
        #expect(ConnectionState.state(for: .notion, in: [expired, failing]) == .syncFailed(failing))
        #expect(ConnectionState.state(for: .notion, in: [revoked]) == .needsReconnect(revoked))
        #expect(ConnectionState.state(for: .notion, in: [expired, revoked]) == .needsReconnect(expired))
        #expect(ConnectionState.state(for: .notion, in: [record("notion", nil)]) == .notConnected)
    }

    @Test func stateUsesLatestSyncedActiveConnection() {
        let older = record("gmail", .active, synced: 10)
        let newer = record("gmail", .active, synced: 99)
        #expect(ConnectionState.state(for: .gmail, in: [older, newer]).record == newer)
    }

    @Test func decodesConnectionRowWithUnknownStatus() throws {
        let json = """
        [{"id":"55555555-5555-4555-8555-555555555555","provider":"notion","display_name":"Acme","status":"paused",
          "last_synced_at":"2026-09-27T01:02:03.123456+00:00","last_error":null}]
        """
        let rows = try TaskforceJSON.decoder().decode([ConnectionRecord].self, from: Data(json.utf8))
        #expect(rows[0].status == nil)
        #expect(rows[0].displayName == "Acme")
        #expect(rows[0].lastSyncedAt != nil)
    }

    @Test func startFailureClassification() {
        #expect(ConnectionStartFailure.classify(.server(status: 400, code: .invalidRequest, message: "")) == .comingSoon)
        #expect(ConnectionStartFailure.classify(.unexpectedStatus(404)) == .comingSoon)
        #expect(ConnectionStartFailure.classify(.server(status: 404, code: .notFound, message: "")) == .comingSoon)
        #expect(ConnectionStartFailure.classify(.server(status: 409, code: .conflict, message: "")) == .consentRequired)
        #expect(ConnectionStartFailure.classify(.transport("offline")) == .other)
    }

    @Test func providerStages() {
        #expect(ConnectionProvider.stageOne == [.notion, .google, .gmail, .slack])
        #expect(ConnectionProvider.stageTwo.allSatisfy { !$0.isStageOne })
        #expect(ConnectionProvider.gmail.note == "Beta · Reconnect every 7 days")
        #expect(ConnectionProvider.google.readsBeforeConnecting.count == 3)
        #expect(ConnectionProvider.stageTwo.allSatisfy { $0.logo == nil })
    }

    // MARK: 단축키

    @Test func defaultHotKeyIsOptionSpace() {
        #expect(HotKeyShortcut.default.displayLabel == "⌥Space")
        #expect(HotKeyShortcut.default.isValid)
    }

    @Test func hotKeyLabelOrderAndValidity() {
        let all = HotKeyShortcut(keyCode: 40, modifiers: HotKeyShortcut.Modifier.all, keyLabel: "K")
        #expect(all.displayLabel == "⌃⌥⇧⌘K")
        #expect(!HotKeyShortcut(keyCode: 40, modifiers: HotKeyShortcut.Modifier.shift, keyLabel: "K").isValid)
        #expect(!HotKeyShortcut(keyCode: 40, modifiers: 0, keyLabel: "K").isValid)
        // Carbon 수정 키 밖의 비트는 버린다
        #expect(HotKeyShortcut(keyCode: 49, modifiers: HotKeyShortcut.Modifier.option | 1, keyLabel: "Space") == .default)
    }

    @Test func hotKeyRoundTripsThroughDefaults() throws {
        let defaults = try #require(UserDefaults(suiteName: "hotkey-\(UUID().uuidString)"))
        #expect(HotKeyShortcut.load(from: defaults) == .default)
        let custom = HotKeyShortcut(keyCode: 40, modifiers: HotKeyShortcut.Modifier.command | HotKeyShortcut.Modifier.shift, keyLabel: "K")
        custom.save(to: defaults)
        #expect(HotKeyShortcut.load(from: defaults) == custom)
        HotKeyShortcut.reset(in: defaults)
        #expect(HotKeyShortcut.load(from: defaults) == .default)
    }
}
