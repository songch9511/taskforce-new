import Foundation
import Testing
@testable import Taskforce

/// 자동 업데이트(Sparkle 2) 시작 판단 (OA M1b U1 · U2). 판단은 Sparkle을 import하지 않는 `UpdateConfiguration`이 하고,
/// 이 시험은 진짜 업데이터를 시작하지 않는다 (시험 호스트에서 Sparkle이 도는 것을 막는 것이 U2다).
struct UpdateStartTests {
    /// 32바이트(ed25519 공개 키 크기)를 base64로 쓴 값. 진짜 키가 아니다
    static let goodKey = Data(repeating: 7, count: 32).base64EncodedString()
    static let goodFeed = "https://updates.example.com/taskforce/appcast.xml"

    static func decide(
        feed: String = goodFeed, key: String = goodKey, isTestHost: Bool = false, isDebugBuild: Bool = false
    ) -> UpdateConfiguration.Decision {
        UpdateConfiguration(feedURL: feed, publicKey: key).decision(isTestHost: isTestHost, isDebugBuild: isDebugBuild)
    }

    @Test func aReleaseBuildWithAFeedAndAKeyStarts() {
        #expect(Self.decide() == .start)
        // 개발 중 로컬 서버로 확인하는 http 피드도 (Info.plist의 NSAllowsLocalNetworking이 로컬 주소만 허용한다)
        #expect(Self.decide(feed: "http://localhost:8000/appcast.xml") == .start)
    }

    // MARK: U1 — 피드 주소나 공개 키가 비면 시작하지 않는다

    @Test func anEmptyFeedAddressDoesNotStart() {
        for feed in ["", "   ", "\n\t", "$(SPARKLE_FEED_URL)", "not a url", "ftp://updates.example.com/appcast.xml", "https://", "/appcast.xml"] {
            #expect(Self.decide(feed: feed) == .notStarted(.noFeedURL), "피드: \(feed.debugDescription)")
        }
    }

    @Test func anEmptyPublicKeyDoesNotStart() {
        let tooShort = Data(repeating: 7, count: 16).base64EncodedString()
        for key in ["", "  ", "$(SPARKLE_PUBLIC_ED_KEY)", "not base64 !!!", tooShort, Self.goodKey + Self.goodKey] {
            #expect(Self.decide(key: key) == .notStarted(.noPublicKey), "키: \(key.debugDescription)")
        }
    }

    @Test func surroundingWhitespaceIsNotPartOfTheValues() {
        #expect(Self.decide(feed: "  \(Self.goodFeed)\n", key: " \(Self.goodKey) ") == .start)
    }

    @Test func bothMissingReportsTheFeedFirst() {
        #expect(Self.decide(feed: "", key: "") == .notStarted(.noFeedURL))
    }

    @Test func theInfoPlistValuesAreReadAsText() {
        #expect(UpdateConfiguration(info: ["SUFeedURL": Self.goodFeed, "SUPublicEDKey": Self.goodKey]) == UpdateConfiguration(feedURL: Self.goodFeed, publicKey: Self.goodKey))
        // 키가 없거나 문자열이 아니면 비어 있는 것과 같다 (크래시 없음)
        #expect(UpdateConfiguration(info: nil) == UpdateConfiguration(feedURL: "", publicKey: ""))
        #expect(UpdateConfiguration(info: ["SUFeedURL": 3, "SUPublicEDKey": ["a"]]) == UpdateConfiguration(feedURL: "", publicKey: ""))
        #expect(UpdateConfiguration(info: [:]).decision(isTestHost: false, isDebugBuild: false) == .notStarted(.noFeedURL))
    }

    // MARK: U2 — XCTest 호스트 · Debug에서는 시작하지 않는다

    @Test func aTestHostNeverStarts() {
        #expect(Self.decide(isTestHost: true) == .notStarted(.testHost))
        // 설정이 비어 있어도 첫 이유는 호스트다 (호스트에서는 설정을 보지도 않는다)
        #expect(Self.decide(feed: "", key: "", isTestHost: true) == .notStarted(.testHost))
    }

    @Test func aDebugBuildNeverStarts() {
        #expect(Self.decide(isDebugBuild: true) == .notStarted(.debugBuild))
        #expect(Self.decide(isTestHost: true, isDebugBuild: true) == .notStarted(.testHost))
    }

    /// 지금 이 시험이 도는 프로세스(Debug-Test 호스트)에 실제 값으로 물어본다
    @Test @MainActor func thisTestHostDoesNotStartTheUpdater() {
        #expect(UpdateConfiguration.current.decision(isTestHost: TestHost.isTestHost(), isDebugBuild: AppRuntime.isDebugBuild) == .notStarted(.testHost))
        // 호스트 앱이 스스로 부른 시작(`MacAppDelegate`)은 시험 호스트에서 일찍 돌아오므로 업데이터는 꺼져 있다
        #expect(!AppUpdater.shared.isRunning)
        #expect(!AppUpdater.shared.canCheckForUpdates)
    }

    @Test @MainActor func startingWithoutAUsableConfigurationStartsNothing() {
        let good = UpdateConfiguration(feedURL: Self.goodFeed, publicKey: Self.goodKey)
        let cases: [(UpdateConfiguration, Bool, Bool, UpdateConfiguration.Decision)] = [
            (UpdateConfiguration(feedURL: "", publicKey: Self.goodKey), false, false, .notStarted(.noFeedURL)),
            (UpdateConfiguration(feedURL: Self.goodFeed, publicKey: ""), false, false, .notStarted(.noPublicKey)),
            (good, true, false, .notStarted(.testHost)),
            (good, false, true, .notStarted(.debugBuild)),
        ]
        for (configuration, isTestHost, isDebugBuild, expected) in cases {
            let updater = AppUpdater()
            updater.start(configuration: configuration, isTestHost: isTestHost, isDebugBuild: isDebugBuild)
            #expect(updater.lastDecision == expected)
            #expect(!updater.isRunning)
            #expect(!updater.canCheckForUpdates, "메뉴 항목은 꺼져 있다")
            updater.checkForUpdates() // 시작하지 않았으면 아무 일도 없다 (크래시 없음)
            #expect(!updater.isRunning)
        }
    }

    // MARK: 종료 위임 지점 (bridge WP 몫)

    /// 지금은 항상 허용. 실행 중인 에이전트 턴이 있을 때의 종료 확인은 bridge WP가 `UpdateRelaunchPolicy.allowsRelaunchNow()`에서 한다
    @Test func relaunchIsAlwaysAllowedForNow() {
        #expect(UpdateRelaunchPolicy.allowsRelaunchNow())
    }
}
