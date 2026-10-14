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

    /// Sparkle은 Info.plist의 피드 문자열을 그대로 읽는다(따옴표만 벗긴다): 앞뒤 공백 · 줄바꿈이 있으면 주소가 만들어지지 않아 업데이트를 확인할 때 설정 오류가 된다.
    /// 검사한 값과 Sparkle이 쓰는 값이 달라지지 않게 그런 피드는 **시작하지 않는다**. 공개 키는 Sparkle도 앞뒤 공백을 지우므로 그대로 받는다
    @Test func aFeedWithSurroundingWhitespaceIsBlockedButAKeyWithItIsNot() {
        for feed in ["  \(Self.goodFeed)", "\(Self.goodFeed)\n", " \(Self.goodFeed) ", "\t\(Self.goodFeed)", "\(Self.goodFeed)\r\n"] {
            #expect(Self.decide(feed: feed) == .notStarted(.noFeedURL), "피드: \(feed.debugDescription)")
        }
        #expect(Self.decide(key: " \(Self.goodKey)\n") == .start)
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
            (UpdateConfiguration(feedURL: " \(Self.goodFeed)\n", publicKey: Self.goodKey), false, false, .notStarted(.noFeedURL)),
            (UpdateConfiguration(feedURL: Self.goodFeed, publicKey: ""), false, false, .notStarted(.noPublicKey)),
            (good, true, false, .notStarted(.testHost)),
            (good, false, true, .notStarted(.debugBuild)),
        ]
        var created = 0
        for (configuration, isTestHost, isDebugBuild, expected) in cases {
            let updater = AppUpdater(makeController: { created += 1; return nil })
            updater.start(configuration: configuration, isTestHost: isTestHost, isDebugBuild: isDebugBuild)
            #expect(updater.lastDecision == expected)
            #expect(!updater.isRunning)
            #expect(!updater.canCheckForUpdates, "메뉴 항목은 꺼져 있다")
            updater.checkForUpdates() // 시작하지 않았으면 아무 일도 없다 (크래시 없음)
            #expect(!updater.isRunning)
        }
        // 상태 플래그가 아니라 Sparkle 컨트롤러를 만드는 호출 자체가 0번이다 (만들기를 판단 앞으로 옮겨도 잡는다)
        #expect(created == 0, "막힌 경로에서 컨트롤러를 \(created)번 만들었다")
    }

    /// 시작해도 되면 컨트롤러를 정확히 한 번 만든다 (두 번째 `start`는 아무것도 하지 않는다). 시험이 넣은 함수는 컨트롤러를 돌려주지 않아 시작된 것으로 치지 않는다
    @Test @MainActor func aUsableConfigurationCreatesTheControllerExactlyOnce() {
        var created = 0
        let updater = AppUpdater(makeController: { created += 1; return nil })
        let good = UpdateConfiguration(feedURL: Self.goodFeed, publicKey: Self.goodKey)
        updater.start(configuration: good, isTestHost: false, isDebugBuild: false)
        updater.start(configuration: good, isTestHost: false, isDebugBuild: false)
        #expect(created == 1)
        #expect(updater.lastDecision == .start)
        #expect(!updater.isRunning)
        #expect(!updater.canCheckForUpdates)
    }

    // MARK: 종료 위임 지점 (OA D2b)

    /// 실행 중인 에이전트 턴(또는 전달하지 않은 비밀값 답)이 있을 때만 지금 재시작하지 않는다. 한가하면 허용한다.
    /// 실제 호스트와 이어서 미루기까지 보는 시험은 `BridgeHostTests`가 한다
    @Test @MainActor func relaunchIsBlockedOnlyWhileBusy() {
        defer { UpdateRelaunchPolicy.resetForTesting() }
        #expect(UpdateRelaunchPolicy.allowsRelaunchNow())
        UpdateRelaunchPolicy.isBusy = { true }
        #expect(!UpdateRelaunchPolicy.allowsRelaunchNow())
        UpdateRelaunchPolicy.isBusy = { false }
        #expect(UpdateRelaunchPolicy.allowsRelaunchNow())
    }
}
