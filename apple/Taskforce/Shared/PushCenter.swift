import Foundation
import Observation
import TaskforceKit
import UserNotifications
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// 알림 (C10 · Phase A3): 권한 · 기기 토큰 등록 · 누른 알림 열기. 앱 전체에서 하나.
/// - 권한은 첫 실행에 묻지 않고, 로그인했고 연결이 하나라도 있을 때 한 번 묻는다 (`PushPermission`).
/// - 허용돼 있으면 실행 · 로그인마다 토큰을 다시 받아 `POST /api/v1/devices`로 보낸다 (토큰이 바뀌었을 수 있다).
/// - 로그아웃 전에 `DELETE /api/v1/devices`로 이 기기를 뺀다.
/// - 알림을 누르면 iPhone은 `target`을 홈 화면이 받아 가고, Mac은 `onOpen`(런처)으로 넘긴다.
@MainActor
@Observable
final class PushCenter: NSObject {
    static let shared = PushCenter()

    /// 누른 알림이 가리키는 곳. 화면이 받아 가면 비운다 (`take()`)
    private(set) var target: NotificationTarget?
    /// 있으면 누른 알림을 여기로 바로 넘긴다 (Mac 런처)
    @ObservationIgnored var onOpen: ((NotificationTarget) -> Void)?

    @ObservationIgnored private var services: AppServices?
    @ObservationIgnored private var userID: UUID?
    @ObservationIgnored private var token: String?
    /// 마지막으로 서버에 보낸 "사용자|토큰": 같은 실행에서 겹쳐 보내지 않는다
    @ObservationIgnored private var uploaded: String?
    @ObservationIgnored private var requesting = false

    /// 앱이 시작할 때 (알림을 눌러 앱이 열린 경우도 받을 수 있게 가장 먼저)
    func install() {
        UNUserNotificationCenter.current().delegate = self
    }

    /// 로그인 상태가 바뀔 때 (로그아웃이면 nil). 이미 허용돼 있으면 토큰을 다시 받아 이 사용자로 보낸다.
    func follow(userID: UUID?, services: AppServices?) {
        guard userID != self.userID else { return }
        self.userID = userID
        self.services = services
        uploaded = nil
        guard userID != nil else { return }
        Task {
            if PushPermission.shouldRegister(status: await Self.status(), signedIn: self.userID != nil) {
                Self.registerForRemoteNotifications()
            }
        }
    }

    /// 알림 권한을 아직 묻지 않았으면 한 번 묻는다 (로그인했고 연결이 있을 때, 다른 시트가 없을 때). 허용하면 토큰을 받는다.
    func requestIfNeeded(hasConnections: Bool, isPresentingOther: Bool = false) async {
        guard !requesting else { return }
        requesting = true
        defer { requesting = false }
        let status = await Self.status()
        guard PushPermission.shouldRequest(
            status: status, signedIn: userID != nil, hasConnections: hasConnections, isPresentingOther: isPresentingOther
        ) else { return }
        let granted = (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        if granted { Self.registerForRemoteNotifications() }
    }

    /// 앱 델리게이트가 받은 기기 토큰
    func didRegister(deviceToken: Data) {
        token = PushToken.hex(deviceToken)
        Task { await upload() }
    }

    /// 로그아웃 전에 (아직 세션이 있을 때): 이 기기로 더는 알림을 보내지 않는다. 실패해도 로그아웃은 막지 않는다.
    func unregister() async {
        guard let token, let services, userID != nil else { return }
        uploaded = nil
        try? await services.api.unregisterDevice(token: token)
    }

    /// 누른 알림을 받아 간다
    func take() -> NotificationTarget? {
        defer { target = nil }
        return target
    }

    fileprivate func open(_ target: NotificationTarget) {
        if let onOpen {
            onOpen(target)
        } else {
            self.target = target
        }
    }

    private func upload() async {
        guard let token, let services, let userID else { return }
        let key = "\(userID.uuidString)|\(token)"
        guard uploaded != key else { return }
        uploaded = key
        let registration = DeviceRegistration(
            token: token, platform: Self.platform, environment: Self.environment,
            appVersion: DeviceRegistration.appVersion(infoDictionary: Bundle.main.infoDictionary ?? [:])
        )
        do {
            try await services.api.registerDevice(registration)
        } catch {
            // 다음 실행 · 로그인 때 다시 보낸다
            if uploaded == key { uploaded = nil }
        }
    }

    // MARK: 시스템

    /// 이 기기의 알림 권한 (0.2.0 설정 창 Reports 탭도 읽는다)
    static func status() async -> PushPermission.Status {
        switch await UNUserNotificationCenter.current().notificationSettings().authorizationStatus {
        case .notDetermined: .notDetermined
        case .denied: .denied
        default: .allowed
        }
    }

    private static func registerForRemoteNotifications() {
        #if os(iOS)
        UIApplication.shared.registerForRemoteNotifications()
        #else
        NSApplication.shared.registerForRemoteNotifications()
        #endif
    }

    private static var platform: DevicePlatform {
        #if os(iOS)
        .ios
        #else
        .macos
        #endif
    }

    /// 서명 프로필의 aps-environment (개발 서명 = sandbox, TestFlight · App Store = production). 없으면 빌드 설정으로
    static let environment: PushEnvironment = {
        #if os(iOS)
        let profileURL = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision")
        #else
        let profileURL: URL? = Bundle.main.bundleURL.appending(path: "Contents/embedded.provisionprofile")
        #endif
        #if DEBUG
        let isDebug = true
        #else
        let isDebug = false
        #endif
        return PushEnvironment.resolve(provisioningProfile: profileURL.flatMap { try? Data(contentsOf: $0) }, isDebugBuild: isDebug)
    }()
}

extension PushCenter: UNUserNotificationCenterDelegate {
    /// 앱이 앞에 있어도 알림을 보여 준다
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound])
    }

    /// 알림을 누름: 그 할 일로 간다 (재연결 알림은 연결 화면으로, 화면이 `target.kind`로 가른다)
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let target = NotificationTarget(userInfo: response.notification.request.content.userInfo)
        Task { @MainActor in PushCenter.shared.open(target) }
        completionHandler()
    }
}
