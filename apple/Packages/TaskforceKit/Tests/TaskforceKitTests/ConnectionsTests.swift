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

    func record(_ provider: String, _ status: ConnectionStatus?, synced: TimeInterval? = nil, started: TimeInterval? = nil) -> ConnectionRecord {
        ConnectionRecord(
            id: UUID(), provider: provider, displayName: "Acme", status: status,
            lastSyncedAt: synced.map { Date(timeIntervalSince1970: $0) }, lastError: nil,
            syncStartedAt: started.map { Date(timeIntervalSince1970: $0) }
        )
    }

    // MARK: 동기화 진행 (C11)

    let t0: TimeInterval = 1_000_000
    func at(_ seconds: TimeInterval) -> Date { Date(timeIntervalSince1970: t0 + seconds) }

    @Test func leaseMeansSyncingUntilItGoesStale() {
        let leased = record("notion", .active, synced: t0, started: t0)
        #expect(ConnectionSync.isSyncing(leased, requestedAt: nil, at: at(60)))
        #expect(ConnectionSync.isSyncing(leased, requestedAt: nil, at: at(9 * 60)))
        // 서버 잠금 10분이 지나면 죽은 실행
        #expect(!ConnectionSync.isSyncing(leased, requestedAt: nil, at: at(10 * 60)))
        #expect(!ConnectionSync.isSyncing(record("notion", .active, synced: t0), requestedAt: nil, at: at(5)))
    }

    @Test func requestShowsSyncingUntilServerFinishesOrWindowEnds() {
        let never = record("notion", .active)
        // 연결 직후: 서버 잠금이 보이기 전에도 먼저 보여 준다
        #expect(ConnectionSync.isSyncing(never, requestedAt: at(0), at: at(5)))
        #expect(!ConnectionSync.isSyncing(never, requestedAt: at(0), at: at(ConnectionSync.optimisticWindow)))
        // 누른 뒤에 끝난 동기화가 있으면 끝남, 그 전 동기화는 세지 않는다
        #expect(!ConnectionSync.isSyncing(record("notion", .active, synced: t0 + 20), requestedAt: at(0), at: at(25)))
        #expect(ConnectionSync.isSyncing(record("notion", .active, synced: t0 - 3_600), requestedAt: at(0), at: at(25)))
        // 기기 시계가 조금 빨라도 끝난 것으로 본다
        #expect(!ConnectionSync.isSyncing(record("notion", .active, synced: t0 - 5), requestedAt: at(0), at: at(25)))
    }

    @Test func pendingMarksLastUntilServerConfirms() {
        let requested = ["notion": at(0), "slack": at(0)]
        // 아직 서버 잠금이 없음: 남김. 연결 행이 아직 없는 서비스도 잠시 남김
        #expect(ConnectionSync.pending(requested, after: [record("notion", .active)], at: at(5)) == requested)
        // 서버 잠금이 보이면 거둔다 (그다음은 서버가 정한다)
        let leased = [record("notion", .active, synced: t0 + 2, started: t0 + 2)]
        #expect(ConnectionSync.pending(requested, after: leased, at: at(6)) == ["slack": at(0)])
        // 사이에 끝났으면 거둔다
        #expect(ConnectionSync.pending(["notion": at(0)], after: [record("notion", .active, synced: t0 + 4)], at: at(6)).isEmpty)
        // 시간이 지나면 거둔다
        #expect(ConnectionSync.pending(requested, after: [record("notion", .active)], at: at(120)).isEmpty)
    }

    @Test func anySyncingLooksAtEveryConnection() {
        let records = [record("slack", .active, synced: t0), record("notion", .active, synced: t0, started: t0 + 10)]
        #expect(ConnectionSync.anySyncing(records, requested: [:], at: at(30)))
        #expect(!ConnectionSync.anySyncing([records[0]], requested: [:], at: at(30)))
        #expect(ConnectionSync.anySyncing([records[0]], requested: ["slack": at(20)], at: at(30)))
    }

    @Test func statusLines() {
        let now = at(0)
        let fresh = record("notion", .active, synced: t0 - 30)
        #expect(ConnectionState.connected(fresh).statusLine(for: .notion, syncing: false, comingSoon: false, now: now)
            == ConnectionStatusLine("Acme · Synced just now"))
        #expect(ConnectionState.connected(fresh).statusLine(for: .notion, syncing: true, comingSoon: false, now: now)
            == ConnectionStatusLine("Syncing…", showsProgress: true))
        let failing = record("notion", .error, synced: t0 - 600)
        #expect(ConnectionState.syncFailed(failing).statusLine(for: .notion, syncing: false, comingSoon: false, now: now)
            == ConnectionStatusLine("Last sync failed", isAlert: true))
        #expect(ConnectionState.syncFailed(failing).statusLine(for: .notion, syncing: true, comingSoon: false, now: now)?.text == "Syncing…")
        #expect(ConnectionState.needsReconnect(record("gmail", .reauth)).statusLine(for: .gmail, syncing: true, comingSoon: false, now: now)
            == ConnectionStatusLine("Reconnect to keep syncing", isAlert: true))
        #expect(ConnectionState.notConnected.statusLine(for: .gmail, syncing: false, comingSoon: false) == ConnectionStatusLine("Beta · Reconnect every 7 days"))
        #expect(ConnectionState.notConnected.statusLine(for: .notion, syncing: false, comingSoon: false) == nil)
        #expect(ConnectionState.notConnected.statusLine(for: .slack, syncing: false, comingSoon: true) == ConnectionStatusLine("Coming soon"))
        let unnamed = ConnectionRecord(id: UUID(), provider: "slack", displayName: nil, status: .active, lastSyncedAt: nil, lastError: nil)
        #expect(ConnectionState.connected(unnamed).statusLine(for: .slack, syncing: false, comingSoon: false) == ConnectionStatusLine("Connected"))
    }

    @Test func syncNowBusyIsNotAnError() {
        #expect(SyncNowFailure.classify(.server(status: 429, code: .rateLimited, message: "이미 동기화 중")) == .alreadySyncing)
        #expect(SyncNowFailure.classify(.unexpectedStatus(429)) == .alreadySyncing)
        #expect(SyncNowFailure.classify(.server(status: 409, code: .conflict, message: "")) == .consentRequired)
        #expect(SyncNowFailure.classify(.transport("offline")) == .failed("Can't reach the server. Check your connection."))
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
        #expect(rows[0].syncStartedAt == nil)
    }

    @Test func decodesSyncLease() throws {
        let json = """
        [{"id":"55555555-5555-4555-8555-555555555555","provider":"notion","display_name":null,"status":"active",
          "last_synced_at":"2026-09-27T01:02:03.123456+00:00","last_error":null,"sync_started_at":"2026-09-27T01:02:03.123456+00:00"}]
        """
        let rows = try TaskforceJSON.decoder().decode([ConnectionRecord].self, from: Data(json.utf8))
        #expect(rows[0].syncStartedAt == rows[0].lastSyncedAt)
        #expect(ConnectionRecord.columns.contains("sync_started_at"))
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

    /// Slack: 연결 전에 무엇을 받는지 알리고, 끊으면 Slack 글이 지워진다고 알린다 (slack-integration.md 3장 · D3)
    @Test func slackConnectAndDisconnectCopy() {
        #expect(ConnectionProvider.slack.readsBeforeConnecting == [
            "DMs and group DMs",
            "Channel threads you write in or are mentioned in",
            "New messages only. Taskforce never sends anything.",
        ])
        #expect(ConnectionProvider.notion.readsBeforeConnecting.isEmpty)
        #expect(ConnectionProvider.disconnectNote(for: "slack") == "Slack messages are removed from Taskforce. Tasks stay.")
        #expect(ConnectionProvider.disconnectNote(for: "notion") == "Tasks already found stay.")
        #expect(ConnectionProvider.disconnectNote(for: "someday") == "Tasks already found stay.")
    }

    /// 서버가 Slack 연결을 끊으며 바꾼 근거 인용은 인용이 아니라 앱 문구로 보여 준다
    @Test func removedSlackQuote() {
        #expect(RemovedQuote.isRemoved("Slack 연결을 끊어 지웠어요"))
        #expect(!RemovedQuote.isRemoved("제안서는 월요일에 받아도 괜찮아요"))
        #expect(RemovedQuote.label == "Removed when Slack was disconnected")
    }

    /// 맨 앞 근거는 남아 있는 인용을 먼저 고른다 (지운 Slack 인용이 더 최근이어도)
    @Test func evidenceLeadPrefersKeptQuote() {
        let source = UUID()
        func line(_ quote: String, _ day: Int) -> EvidenceLine {
            EvidenceLine(id: UUID(), quote: quote, sourceID: source, sourceTitle: nil, occurredAt: Date(timeIntervalSince1970: Double(day) * 86_400), externalURL: nil, service: .notion)
        }
        let digest = EvidenceDigest(lines: [line("금요일까지 제안서 보내드릴게요", 1), line(RemovedQuote.slackDisconnected, 2)])
        #expect(digest.lead?.quote == "금요일까지 제안서 보내드릴게요")
        #expect(EvidenceDigest(lines: [line(RemovedQuote.slackDisconnected, 2)]).lead?.quote == RemovedQuote.slackDisconnected)
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
