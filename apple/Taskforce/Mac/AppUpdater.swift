#if os(macOS)
import AppKit
import Observation
import OSLog
import Sparkle
import SwiftUI

/// 자동 업데이트 (Sparkle 2, OA M1b): 앱 수명에 `SPUStandardUpdaterController` 하나.
/// 시작할지는 `UpdateConfiguration`이 정한다: 피드 주소나 공개 키가 비어 있거나, Debug 빌드이거나, XCTest 호스트이면 **Sparkle 객체를 만들지 않는다**
/// (크래시 · 오류 창 없음, 메뉴 항목은 꺼진다). 자동 확인은 Sparkle 기본 동작을 따른다(두 번째 실행에서 사용자에게 묻는다): 설정 화면 · 기본값을 바꾸는 키는 없다.
/// 키 · 피드 · 올리기: `docs/go-live/mac-dmg.md` "자동 업데이트".
@MainActor
@Observable
final class AppUpdater {
    static let shared = AppUpdater()

    /// Sparkle 업데이터가 실제로 시작됐는지
    private(set) var isRunning = false
    /// 메뉴 항목 "Check for Updates…"를 누를 수 있는지. 시작하지 않았으면 늘 false
    private(set) var canCheckForUpdates = false
    /// `start`가 내린 판단 (시험 · 로그용). 아직 부르지 않았으면 nil
    private(set) var lastDecision: UpdateConfiguration.Decision?

    @ObservationIgnored private var controller: SPUStandardUpdaterController?
    @ObservationIgnored private let delegate: UpdaterDelegate
    @ObservationIgnored private var canCheckObservation: NSKeyValueObservation?
    /// `SPUStandardUpdaterController`를 만드는 **유일한** 곳. `start`가 시작해도 된다고 판단한 뒤에만 부른다.
    /// 시험이 세는 함수를 넣어 막힌 경로에서 만들기 호출이 0번임을 직접 본다 (진짜 Sparkle은 시험 호스트에서 시작하지 않는다)
    @ObservationIgnored private let makeController: @MainActor () -> AnyObject?

    /// 시험이 따로 만들 수 있게 열어 둔다. 앱은 `shared` 하나만 쓴다. `makeController`가 없으면 진짜 Sparkle 컨트롤러(시작까지)를 만든다
    init(makeController: (@MainActor () -> AnyObject?)? = nil) {
        let delegate = UpdaterDelegate()
        self.delegate = delegate
        self.makeController = makeController ?? {
            SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: delegate, userDriverDelegate: nil)
        }
    }

    /// 앱 시작 때 한 번 (`MacAppDelegate.applicationDidFinishLaunching`, 시험 호스트 가드 뒤). 두 번째부터는 아무것도 하지 않는다
    func start(
        configuration: UpdateConfiguration = .current, isTestHost: Bool = TestHost.isTestHost(), isDebugBuild: Bool = AppRuntime.isDebugBuild
    ) {
        guard lastDecision == nil else { return }
        let decision = configuration.decision(isTestHost: isTestHost, isDebugBuild: isDebugBuild)
        lastDecision = decision
        // 로그에는 값(주소 · 키)을 남기지 않는다. 시작했는지와 이유만
        let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "dev.taskforcelabs.taskforce", category: "updater")
        guard decision == .start else {
            log.info("not started: \(String(describing: decision), privacy: .public)")
            return
        }
        guard let controller = makeController() as? SPUStandardUpdaterController else {
            // 진짜 만들기는 늘 컨트롤러를 돌려준다. 시험이 넣은 함수가 nil을 돌려준 경우만 여기로 온다
            log.info("controller not created")
            return
        }
        self.controller = controller
        log.info("started")
        isRunning = true
        canCheckForUpdates = controller.updater.canCheckForUpdates
        canCheckObservation = controller.updater.observe(\.canCheckForUpdates, options: [.new]) { [weak self] _, change in
            let value = change.newValue ?? false
            Task { @MainActor in self?.canCheckForUpdates = value }
        }
    }

    /// 사용자가 메뉴에서 누른 확인. 시작하지 않았으면 아무 일도 없다 (메뉴 항목도 꺼져 있다)
    func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }
}

/// Sparkle이 부르는 곳. 지금은 재시작 허용 판단 하나뿐이다.
@MainActor
final class UpdaterDelegate: NSObject, SPUUpdaterDelegate {
    /// 업데이트 뒤 앱 재시작 허용. 지금은 항상 허용: 실행 중인 에이전트 턴이 있을 때의 종료 확인은 bridge WP가 `UpdateRelaunchPolicy`에서 한다
    func updaterShouldRelaunchApplication(_ updater: SPUUpdater) -> Bool {
        UpdateRelaunchPolicy.allowsRelaunchNow()
    }
}

/// 표준 항목 "Check for Updates…" (macOS 관례 문구). 업데이터가 시작되지 않았으면 꺼져 있다.
/// 메뉴 막대 메뉴(`MenuBarMenu`)와 앱 메뉴(설정 창이 앞일 때, `TaskforceApp`의 `.commands`)가 같은 버튼을 쓴다
struct CheckForUpdatesButton: View {
    var updater: AppUpdater = .shared

    var body: some View {
        Button("Check for Updates…") { updater.checkForUpdates() }
            .disabled(!updater.canCheckForUpdates)
    }
}
#endif
