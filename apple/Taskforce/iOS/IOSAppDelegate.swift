#if os(iOS)
import UIKit

/// 알림 (C10): 알림 델리게이트를 가장 먼저 두고, 기기 토큰을 `PushCenter`로 넘긴다
final class IOSAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        PushCenter.shared.install()
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        PushCenter.shared.didRegister(deviceToken: deviceToken)
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        // 시뮬레이터 · 알림 기능이 없는 서명: 알림 없이 쓴다
    }
}
#endif
