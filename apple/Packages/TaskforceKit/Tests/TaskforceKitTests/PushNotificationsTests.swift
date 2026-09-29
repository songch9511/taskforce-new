import Foundation
import Testing
@testable import TaskforceKit

/// 알림 (C10 · Phase A3): 토큰 표기 · APNs 환경 · 권한을 물을 때 · 알림 내용 읽기
struct PushNotificationsTests {
    @Test func tokenIsLowercaseHex() {
        #expect(PushToken.hex(Data([0x00, 0x0f, 0xab, 0xff])) == "000fabff")
        let token = PushToken.hex(Data((0..<32).map { UInt8($0 * 7 % 256) }))
        #expect(token.count == 64)
        // 서버 형식: 16진수 32~200자
        #expect(token.allSatisfy { $0.isHexDigit && !$0.isUppercase })
    }

    /// 서명 프로필 모양: CMS 봉투 안에 plist가 그대로 들어 있다
    func profile(_ entitlements: [String: Any]) throws -> Data {
        let plist = try PropertyListSerialization.data(
            fromPropertyList: ["Name": "Taskforce", "Entitlements": entitlements], format: .xml, options: 0
        )
        return Data([0x30, 0x82, 0x3a, 0x1c, 0x06, 0x09]) + plist + Data([0xa0, 0x82, 0x0d, 0x00])
    }

    @Test func environmentFollowsProvisioningProfile() throws {
        let iOSDevelopment = try profile(["aps-environment": "development"])
        let iOSProduction = try profile(["aps-environment": "production"])
        let macDevelopment = try profile(["com.apple.developer.aps-environment": "development"])
        let macProduction = try profile(["com.apple.developer.aps-environment": "production"])
        // 프로필이 빌드 설정보다 앞선다 (Release를 개발 서명으로 기기에 올려도 sandbox)
        #expect(PushEnvironment.resolve(provisioningProfile: iOSDevelopment, isDebugBuild: false) == .sandbox)
        #expect(PushEnvironment.resolve(provisioningProfile: iOSProduction, isDebugBuild: true) == .production)
        #expect(PushEnvironment.resolve(provisioningProfile: macDevelopment, isDebugBuild: false) == .sandbox)
        #expect(PushEnvironment.resolve(provisioningProfile: macProduction, isDebugBuild: false) == .production)
    }

    @Test func environmentWithoutProfileFollowsBuild() throws {
        // App Store · TestFlight iOS에는 프로필이 없다 → Release = production. 시뮬레이터 Debug = sandbox
        #expect(PushEnvironment.resolve(provisioningProfile: nil, isDebugBuild: false) == .production)
        #expect(PushEnvironment.resolve(provisioningProfile: nil, isDebugBuild: true) == .sandbox)
        #expect(PushEnvironment.resolve(provisioningProfile: Data("not a profile".utf8), isDebugBuild: true) == .sandbox)
        // 알림 권한이 없는 프로필
        #expect(PushEnvironment.resolve(provisioningProfile: try profile(["application-identifier": "x"]), isDebugBuild: false) == .production)
    }

    @Test func registrationCarriesAppVersion() {
        #expect(DeviceRegistration.appVersion(infoDictionary: ["CFBundleShortVersionString": "0.1.0", "CFBundleVersion": "7"]) == "0.1.0 (7)")
        #expect(DeviceRegistration.appVersion(infoDictionary: ["CFBundleShortVersionString": "0.1.0"]) == "0.1.0")
        #expect(DeviceRegistration.appVersion(infoDictionary: [:]) == nil)
        let long = DeviceRegistration(token: "ab", platform: .macos, environment: .production, appVersion: String(repeating: "9", count: 60))
        #expect(long.appVersion?.count == 40)
    }

    @Test func permissionIsAskedOnlyWhenThereIsSomethingToNotify() {
        #expect(PushPermission.shouldRequest(status: .notDetermined, signedIn: true, hasConnections: true, isPresentingOther: false))
        // 첫 실행 · 연결 전에는 묻지 않는다
        #expect(!PushPermission.shouldRequest(status: .notDetermined, signedIn: true, hasConnections: false, isPresentingOther: false))
        #expect(!PushPermission.shouldRequest(status: .notDetermined, signedIn: false, hasConnections: true, isPresentingOther: false))
        // 다른 시트가 떠 있으면 미룬다
        #expect(!PushPermission.shouldRequest(status: .notDetermined, signedIn: true, hasConnections: true, isPresentingOther: true))
        // 이미 답했으면 다시 묻지 않는다
        #expect(!PushPermission.shouldRequest(status: .denied, signedIn: true, hasConnections: true, isPresentingOther: false))
        #expect(!PushPermission.shouldRequest(status: .allowed, signedIn: true, hasConnections: true, isPresentingOther: false))
        #expect(PushPermission.shouldRegister(status: .allowed, signedIn: true))
        #expect(!PushPermission.shouldRegister(status: .denied, signedIn: true))
        #expect(!PushPermission.shouldRegister(status: .allowed, signedIn: false))
    }

    @Test func confirmationPayloadOpensReviewCard() {
        // src/lib/notify/apns.ts confirmationPayload
        let target = NotificationTarget(userInfo: [
            "aps": ["alert": ["title": "확인이 필요해요", "body": "새로 찾은 할 일을 확인해 주세요"]],
            "action_id": "11111111-1111-4111-8111-111111111111",
            "kind": "confirmation",
        ])
        #expect(target == NotificationTarget(kind: .confirmation, actionID: Fixtures.actionID))
    }

    @Test func duePayloadOpensFirstTask() {
        let due = NotificationTarget(userInfo: [
            "action_id": "11111111-1111-4111-8111-111111111111",
            "action_ids": ["11111111-1111-4111-8111-111111111111", "22222222-2222-4222-8222-222222222222"],
            "kind": "due",
        ])
        #expect(due == NotificationTarget(kind: .due, actionID: Fixtures.actionID))
        let listOnly = NotificationTarget(userInfo: ["action_ids": ["22222222-2222-4222-8222-222222222222"], "kind": "due"])
        #expect(listOnly.actionID == UUID(uuidString: "22222222-2222-4222-8222-222222222222"))
    }

    @Test func reconnectPayloadOpensConnections() {
        // src/lib/notify/apns.ts reconnectPayload: 할 일 정보 없이 kind만
        let target = NotificationTarget(userInfo: [
            "aps": ["alert": ["title": "Connections", "body": "Reconnect Gmail to keep syncing."]],
            "kind": "reconnect",
        ])
        #expect(target == NotificationTarget(kind: .reconnect, actionID: nil))
    }

    @Test func unknownPayloadJustOpensTheApp() {
        #expect(NotificationTarget(userInfo: [:]) == NotificationTarget(kind: .other, actionID: nil))
        #expect(NotificationTarget(userInfo: ["kind": "weekly", "action_id": "not-a-uuid"]) == NotificationTarget(kind: .other, actionID: nil))
    }
}
