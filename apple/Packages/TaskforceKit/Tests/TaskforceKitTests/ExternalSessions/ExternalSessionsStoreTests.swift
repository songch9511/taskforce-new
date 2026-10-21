#if os(macOS) && DEBUG
import Foundation
import Testing
@testable import TaskforceKit

/// 레일 항목 · 패널의 상태 (계약 8 · 17장): 언제 훑나 · 점 · 처음 읽는 동안만 Checking · 서버 보고 · 보임 지표 · 계정 경계
@MainActor
struct ExternalSessionsStoreTests {
    typealias R = ExternalSessionReportTests

    final class Fake: @unchecked Sendable {
        private let lock = NSLock()
        private var _scan = ExternalSessionScan(rows: [])
        private var _installed: Bool? = nil
        private var _scans = 0
        private var _reports: [[ExternalSessionRow]] = []
        private var _shown: [(String, String)] = []
        private var _gate: CheckedContinuation<Void, Never>?
        var holdScans = false

        var scan: ExternalSessionScan {
            get { lock.withLock { _scan } }
            set { lock.withLock { _scan = newValue } }
        }
        var installed: Bool? {
            get { lock.withLock { _installed } }
            set { lock.withLock { _installed = newValue } }
        }
        var scans: Int { lock.withLock { _scans } }
        var reports: [[ExternalSessionRow]] { lock.withLock { _reports } }
        var shown: [(String, String)] { lock.withLock { _shown } }

        func doScan() async -> ExternalSessionScan {
            lock.withLock { _scans += 1 }
            if holdScans { await withCheckedContinuation { continuation in lock.withLock { _gate = continuation } } }
            return scan
        }

        func release() {
            let gate = lock.withLock { () -> CheckedContinuation<Void, Never>? in
                holdScans = false
                defer { _gate = nil }
                return _gate
            }
            gate?.resume()
        }

        func recordReport(_ rows: [ExternalSessionRow]) { lock.withLock { _reports.append(rows) } }
        func recordShown(_ rows: String, _ held: String) { lock.withLock { _shown.append((rows, held)) } }
    }

    struct Setup {
        let store: ExternalSessionsStore
        let fake: Fake
        let seen: InMemoryExternalSessionSeenStore
        let scope: AccountScope
        let clock: Clock
    }

    final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var date = ExternalSessionReportTests.now
        var now: Date { lock.withLock { date } }
        func advance(_ seconds: TimeInterval) { lock.withLock { date = date.addingTimeInterval(seconds) } }
    }

    func make(seen: Date? = nil, poll: TimeInterval = 10) -> Setup {
        let fake = Fake()
        let user = UUID()
        let scope = AccountScope(currentAccount: { user })
        let seenStore = InMemoryExternalSessionSeenStore(seen)
        let clock = Clock()
        let store = ExternalSessionsStore(
            scope: scope, scan: { await fake.doScan() }, isInstalled: { fake.installed }, report: { fake.recordReport($0) }, shown: { fake.recordShown($0, $1) }, seen: seenStore,
            now: { clock.now }, pollInterval: poll
        )
        return Setup(store: store, fake: fake, seen: seenStore, scope: scope, clock: clock)
    }

    /// 조건이 될 때까지 기다린다 (최대 3초)
    func until(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<300 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    // MARK: 상태

    @Test func openingTheListShowsCheckingUntilTheFirstScanThenTheRows() async {
        let s = make()
        s.fake.holdScans = true
        s.fake.scan = ExternalSessionScan(rows: [R.row(1), R.row(2, status: .held(.claudeApp))])
        s.store.panelOpened()
        #expect(s.store.phase == .checking)
        #expect(s.store.rows.isEmpty)
        #expect(await until { s.fake.scans == 1 })
        s.fake.release()
        #expect(await until { s.store.phase == .ready })
        #expect(s.store.rows.count == 2)
        s.store.panelClosed()
    }

    @Test func theSecondOpenKeepsTheLastRowsInsteadOfCheckingAgain() async {
        let s = make()
        s.fake.scan = ExternalSessionScan(rows: [R.row(1)])
        s.store.panelOpened()
        #expect(await until { s.store.phase == .ready })
        s.store.panelClosed()
        s.fake.holdScans = true
        s.store.panelOpened()
        #expect(s.store.phase == .ready && s.store.rows.count == 1)
        s.fake.release()
        s.store.panelClosed()
    }

    @Test func anEmptyScanIsEmptyAndTheFailuresMapToTheirStates() async {
        let s = make()
        await s.store.refresh()
        #expect(s.store.phase == .empty)
        s.fake.scan = ExternalSessionScan(rows: [], failure: .unreadable)
        await s.store.refresh()
        #expect(s.store.phase == .failed && s.store.rows.isEmpty)
        s.fake.scan = ExternalSessionScan(rows: [], failure: .notFound)
        await s.store.refresh()
        #expect(s.store.phase == .notInstalled)
        s.fake.installed = true
        await s.store.refresh()
        #expect(s.store.phase == .empty, "Claude Code는 있는데 아직 쓴 적이 없다")
    }

    @Test func whenTheProbeSaysNotInstalledTheScanIsNotEvenRun() async {
        let s = make()
        s.fake.installed = false
        s.fake.scan = ExternalSessionScan(rows: [R.row(1)])
        await s.store.refresh()
        #expect(s.store.phase == .notInstalled && s.store.rows.isEmpty)
        #expect(s.fake.scans == 0)
        #expect(s.fake.reports.isEmpty)
    }

    @Test func overlappingRefreshesShareOneScan() async {
        let s = make()
        s.fake.holdScans = true
        let first = Task { await s.store.refresh() }
        #expect(await until { s.fake.scans == 1 })
        let second = Task { await s.store.refresh() }
        try? await Task.sleep(for: .milliseconds(50))
        #expect(s.fake.scans == 1)
        s.fake.release()
        await first.value
        await second.value
        #expect(s.fake.scans == 1)
    }

    // MARK: 점

    @Test func theSessionsThereAtTheFirstScanAreNotNewAndALaterOneMakesTheDot() async {
        let s = make()
        s.fake.scan = ExternalSessionScan(rows: [R.row(1)])
        s.store.railExpanded()
        #expect(await until { s.store.phase == .ready && !s.store.isScanning })
        #expect(!s.store.hasNew, "앱이 처음 훑을 때 있던 세션은 새것이 아니다")
        s.clock.advance(60)
        let brandNew = ExternalSessionRow(
            id: ExternalSessionFixture.uuid(9), ref: String(repeating: "b", count: 64), title: "New", folderPath: "/h/p", groupPath: "/h/p", lastActivity: s.clock.now, created: s.clock.now,
            client: .claudeDesktop, status: .held(.claudeApp)
        )
        s.fake.scan = ExternalSessionScan(rows: [R.row(1), brandNew])
        await s.store.refresh()
        #expect(s.store.hasNew)
    }

    @Test func openingTheListClearsTheDotAndSessionsSeenWhileOpenAreNotNew() async {
        let s = make(seen: R.now.addingTimeInterval(-3600))
        s.fake.scan = ExternalSessionScan(rows: [R.row(1)])  // created = now - 1h ... = baseline, 새것이 아님
        let newer = ExternalSessionRow(
            id: ExternalSessionFixture.uuid(9), ref: String(repeating: "b", count: 64), title: nil, folderPath: nil, groupPath: nil, lastActivity: R.now, created: R.now.addingTimeInterval(-60),
            client: nil, status: .available
        )
        s.fake.scan = ExternalSessionScan(rows: [newer])
        await s.store.refresh()
        #expect(s.store.hasNew)
        s.store.panelOpened()
        #expect(!s.store.hasNew)
        #expect(s.seen.lastOpened == s.clock.now)
        #expect(await until { s.fake.scans >= 2 })
        #expect(!s.store.hasNew, "열려 있는 동안은 점이 없다")
        s.clock.advance(120)
        s.store.panelClosed()
        await s.store.refresh()
        #expect(!s.store.hasNew, "열려 있는 동안 본 세션은 새것이 아니다")
    }

    @Test func aRowAlreadyInTaskforceNeverMakesTheDot() async {
        let s = make(seen: R.now.addingTimeInterval(-3600))
        s.fake.scan = ExternalSessionScan(rows: [ExternalSessionRow(
            id: ExternalSessionFixture.uuid(9), ref: String(repeating: "b", count: 64), title: nil, folderPath: nil, groupPath: nil, lastActivity: R.now, created: R.now, client: nil, status: .inTaskforce
        )])
        await s.store.refresh()
        #expect(!s.store.hasNew)
    }

    @Test func theRailExpandingWhileTheListIsOpenDoesNotScanAgain() async {
        let s = make()
        s.store.panelOpened()
        #expect(await until { s.fake.scans == 1 })
        s.store.railExpanded()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(s.fake.scans == 1)
        s.store.panelClosed()
    }

    // MARK: 서버 보고 · 보임 지표

    @Test func everySuccessfulScanIsReportedButAFailedOneIsNot() async {
        let s = make()
        s.fake.scan = ExternalSessionScan(rows: [R.row(1)])
        await s.store.refresh()
        #expect(await until { s.fake.reports.count == 1 })
        #expect(s.fake.reports.first?.count == 1)
        s.fake.scan = ExternalSessionScan(rows: [], failure: .unreadable)
        await s.store.refresh()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(s.fake.reports.count == 1)
    }

    @Test func theShownMetricGoesOutOnceWithBucketsWhenTheOpenListFirstShowsRows() async {
        let s = make()
        // 닫혀 있을 때(레일 펼침)는 "보임"이 아니다
        s.fake.scan = ExternalSessionScan(rows: (1...7).map { R.row($0, status: $0 <= 3 ? .held(.terminal) : .available) })
        await s.store.refresh()
        try? await Task.sleep(for: .milliseconds(30))
        #expect(s.fake.shown.isEmpty)
        s.store.panelOpened()
        #expect(await until { s.fake.shown.count == 1 })
        #expect(s.fake.shown.first?.0 == "6-15" && s.fake.shown.first?.1 == "3+")
        await s.store.refresh()
        try? await Task.sleep(for: .milliseconds(30))
        #expect(s.fake.shown.count == 1, "한 번만")
        s.store.panelClosed()
    }

    @Test func noRowsMeansNoShownMetric() async {
        let s = make()
        s.store.panelOpened()
        #expect(await until { s.store.phase == .empty })
        try? await Task.sleep(for: .milliseconds(30))
        #expect(s.fake.shown.isEmpty)
        s.store.panelClosed()
    }

    // MARK: 10초 훑기 · 계정

    @Test func whileOpenItScansAgainOnItsIntervalAndStopsWhenClosed() async {
        let s = make(poll: 0.02)
        s.store.panelOpened()
        #expect(await until { s.fake.scans >= 3 })
        s.store.panelClosed()
        try? await Task.sleep(for: .milliseconds(80))
        let stopped = s.fake.scans
        try? await Task.sleep(for: .milliseconds(120))
        #expect(s.fake.scans == stopped)
    }

    @Test func whenTheAccountLeavesItEmptiesAndALateAnswerIsDropped() async {
        let s = make()
        s.fake.scan = ExternalSessionScan(rows: [R.row(1)])
        await s.store.refresh()
        #expect(s.store.phase == .ready)
        s.fake.holdScans = true
        let late = Task { await s.store.refresh() }
        #expect(await until { s.fake.scans == 2 })
        s.scope.accountLeft()
        #expect(s.store.phase == .idle && s.store.rows.isEmpty && !s.store.hasNew)
        s.fake.release()
        await late.value
        #expect(s.store.phase == .idle && s.store.rows.isEmpty, "그 사이 시작한 훑기의 늦은 답은 쓰지 않는다")
        #expect(s.fake.reports.count == 1)
    }

    /// 실제 설정 도메인을 만들지 않는다: 사전으로 바꾼 `ExternalSessionDefaults`
    final class DictionaryDefaults: ExternalSessionDefaults, @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String: Any] = [:]
        var keys: Set<String> { lock.withLock { Set(values.keys) } }
        func object(forKey key: String) -> Any? { lock.withLock { values[key] } }
        func set(_ value: Any?, forKey key: String) { lock.withLock { values[key] = value } }
    }

    @Test func theSeenStoreKeepsTheTimeUnderItsOwnKey() {
        let defaults = DictionaryDefaults()
        let store = UserDefaultsExternalSessionSeenStore(defaults: defaults)
        #expect(store.lastOpened == nil)
        let date = Date(timeIntervalSince1970: 1_792_400_000)
        store.setLastOpened(date)
        #expect(store.lastOpened == date)
        #expect(UserDefaultsExternalSessionSeenStore(defaults: defaults).lastOpened == date)
        #expect(defaults.keys == ["taskforce.externalSessions.lastOpened"] && UserDefaultsExternalSessionSeenStore.key == "taskforce.externalSessions.lastOpened")
        defaults.set("not a number", forKey: UserDefaultsExternalSessionSeenStore.key)
        #expect(store.lastOpened == nil, "모르는 값은 기준이 없는 것으로 본다")
    }
}
#endif
