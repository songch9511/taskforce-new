import Foundation

// 알림 (Phase A3)의 화면 없는 규칙: 기기 토큰 표기 · APNs 환경 · 권한을 물을 때 · 알림을 눌렀을 때 열 곳.
// 알림을 보내는 쪽은 서버(src/lib/notify)다. 앱은 토큰을 `POST /api/v1/devices`로 보내고, 누르면 그 할 일로 간다.

public enum PushToken {
    /// APNs 기기 토큰을 서버가 받는 16진수로 (소문자, contract.ts `deviceRequestSchema.token`)
    public static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }
}

/// 이 빌드가 받는 APNs 서버 (contract.ts `deviceRequestSchema.environment`). 틀리면 서버가 보낸 알림이 오지 않는다.
public enum PushEnvironment: String, Sendable, Codable, Equatable {
    case sandbox, production

    /// 서명 프로필의 `aps-environment`가 기준이다 (Xcode 개발 서명 = development, TestFlight · App Store = production).
    /// 프로필이 없으면 (App Store에서 받은 iOS 앱 · 시뮬레이터 · 서명 없는 빌드) Debug는 sandbox, 그 밖은 production.
    public static func resolve(provisioningProfile: Data?, isDebugBuild: Bool) -> PushEnvironment {
        if let value = apsEnvironment(inProvisioningProfile: provisioningProfile) {
            return value == "development" ? .sandbox : .production
        }
        return isDebugBuild ? .sandbox : .production
    }

    /// 서명 프로필(CMS로 싼 plist)의 `Entitlements`에서 APNs 환경
    /// (iOS `aps-environment`, macOS `com.apple.developer.aps-environment`)
    static func apsEnvironment(inProvisioningProfile data: Data?) -> String? {
        guard let data,
              let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(of: Data("</plist>".utf8), in: start.lowerBound..<data.endIndex),
              let root = try? PropertyListSerialization.propertyList(from: data[start.lowerBound..<end.upperBound], format: nil)
                as? [String: Any],
              let entitlements = root["Entitlements"] as? [String: Any]
        else { return nil }
        return (entitlements["aps-environment"] ?? entitlements["com.apple.developer.aps-environment"]) as? String
    }
}

/// contract.ts `deviceRequestSchema.platform`
public enum DevicePlatform: String, Sendable, Codable, Equatable {
    case ios, macos
}

/// POST /api/v1/devices 본문
public struct DeviceRegistration: Encodable, Equatable, Sendable {
    public let token: String
    public let platform: DevicePlatform
    public let environment: PushEnvironment
    /// "0.1.0 (1)" (서버는 40자까지)
    public let appVersion: String?

    enum CodingKeys: String, CodingKey {
        case token, platform, environment
        case appVersion = "app_version"
    }

    public init(token: String, platform: DevicePlatform, environment: PushEnvironment, appVersion: String?) {
        self.token = token
        self.platform = platform
        self.environment = environment
        self.appVersion = appVersion.map { String($0.prefix(40)) }
    }

    /// 번들의 버전 · 빌드 번호로 "0.1.0 (1)"
    public static func appVersion(infoDictionary: [String: Any]) -> String? {
        let version = infoDictionary["CFBundleShortVersionString"] as? String
        let build = infoDictionary["CFBundleVersion"] as? String
        switch (version, build) {
        case let (version?, build?): return "\(version) (\(build))"
        case let (version?, nil): return version
        default: return nil
        }
    }
}

/// 알림 권한을 언제 물을지. 첫 실행에 바로 묻지 않고, 로그인했고 연결이 하나라도 있어 알릴 일이 생길 수 있을 때 한 번 묻는다
/// (시스템도 한 번만 묻는다). 다른 시트 · 확인 화면이 떠 있으면 닫힌 뒤로 미룬다.
public enum PushPermission {
    public enum Status: Sendable, Equatable {
        case notDetermined, denied, allowed
    }

    public static func shouldRequest(status: Status, signedIn: Bool, hasConnections: Bool, isPresentingOther: Bool) -> Bool {
        status == .notDetermined && signedIn && hasConnections && !isPresentingOther
    }

    /// 기기 토큰을 받아 서버에 보낼지: 이미 허용했으면 실행 · 로그인마다 (토큰이 바뀌었을 수 있다)
    public static func shouldRegister(status: Status, signedIn: Bool) -> Bool {
        status == .allowed && signedIn
    }
}

/// 알림을 눌렀을 때 열 곳 (서버 src/lib/notify/apns.ts: `kind` · `action_id` · `action_ids`)
public struct NotificationTarget: Equatable, Sendable {
    public enum Kind: String, Sendable, Equatable {
        /// 확인 요청이 새로 생김: Review 카드
        case confirmation
        /// 오늘 · 내일 마감: 할 일 행
        case due
        case other
    }

    public let kind: Kind
    /// 없으면 앱만 연다
    public let actionID: UUID?

    public init(kind: Kind, actionID: UUID?) {
        self.kind = kind
        self.actionID = actionID
    }

    public init(userInfo: [AnyHashable: Any]) {
        kind = (userInfo["kind"] as? String).flatMap(Kind.init(rawValue:)) ?? .other
        let first = (userInfo["action_id"] as? String) ?? (userInfo["action_ids"] as? [String])?.first
        actionID = first.flatMap(UUID.init(uuidString:))
    }
}
