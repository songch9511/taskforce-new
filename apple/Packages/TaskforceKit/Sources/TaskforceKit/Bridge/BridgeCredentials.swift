#if os(macOS)
import Foundation
import Security

// 장치 자격 (OA D2b 계약 2.12 · D2a notes 10.5). device_id는 파티션(계정)마다 따로 만든 난수이고, secret은 서버가 등록 때 준 값이다.
// 하드웨어 id · 기기 이름은 쓰지 않는다. 로그 · 원장 · 오류 메시지에 두 값 모두 남기지 않는다.

public enum BridgeCredentialRules {
    /// 32바이트(256비트) 난수를 base64url(패딩 없음)로: 43자. 서버는 16–200자를 받고 128비트 이상을 요구한다
    public static func newDeviceID() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        if status != errSecSuccess {
            // 난수 공급이 실패하는 일은 사실상 없다. 그래도 예측 가능한 값으로 떨어지지 않게 시스템 난수로 다시 채운다
            for index in bytes.indices { bytes[index] = UInt8.random(in: .min ... .max) }
        }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// 서버 `verifyBridgeSecret`과 같은 모양: base64url 43자 (auth.ts). 응답에서 이 모양을 확인한 뒤에만 저장한다
    public static func isValidSecret(_ secret: String) -> Bool {
        secret.utf8.count == 43 && secret.utf8.allSatisfy { byte in
            (byte >= 0x30 && byte <= 0x39) || (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A) || byte == 0x2D || byte == 0x5F
        }
    }
}

public protocol BridgeCredentialStore: Sendable {
    func deviceID(partition: String) throws -> String?
    func secret(partition: String) throws -> String?
    func save(deviceID: String, partition: String) throws
    func save(secret: String, partition: String) throws
    /// 계정 삭제 · 폐기 때 그 파티션의 두 항목을 지운다
    func deleteAll(partition: String) throws
    /// Settings의 Disconnect (OA Settings › Your agents 6.3): 서버가 폐기를 받은 뒤 **장치 secret만** 지운다. `device_id`는 둔다 — 다시 연결(Reconnect)이 같은 Mac(같은 bridge 행)을 되살린다
    func deleteSecret(partition: String) throws
}

public struct BridgeCredentialStoreUnsupported: Error, Equatable, Sendable {}

extension BridgeCredentialStore {
    /// 기본은 지우지 못한다 (모든 실제 저장소는 구현한다). 잘못된 기본값으로 `device_id`까지 지우지 않는다
    public func deleteSecret(partition: String) throws { throw BridgeCredentialStoreUnsupported() }
}

/// 시험 · 메모리 저장소. 실제 Keychain을 건드리지 않는다
public final class InMemoryBridgeCredentialStore: BridgeCredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var devices: [String: String] = [:]
    private var secrets: [String: String] = [:]

    public init() {}

    public func deviceID(partition: String) throws -> String? {
        lock.lock()
        defer { lock.unlock() }
        return devices[partition]
    }

    public func secret(partition: String) throws -> String? {
        lock.lock()
        defer { lock.unlock() }
        return secrets[partition]
    }

    public func save(deviceID: String, partition: String) throws {
        lock.lock()
        defer { lock.unlock() }
        devices[partition] = deviceID
    }

    public func save(secret: String, partition: String) throws {
        lock.lock()
        defer { lock.unlock() }
        secrets[partition] = secret
    }

    public func deleteAll(partition: String) throws {
        lock.lock()
        defer { lock.unlock() }
        devices[partition] = nil
        secrets[partition] = nil
    }

    public func deleteSecret(partition: String) throws {
        lock.lock()
        defer { lock.unlock() }
        secrets[partition] = nil
    }
}

/// Keychain 쿼리를 순수 함수로 만든다 (서명 없는 시험 호스트는 데이터 보호 Keychain을 쓸 수 없으므로, 시험은 이 사전을 검사한다.
/// 실제 쓰기 · 읽기는 서명 빌드에서 확인한다 — `oa-m1a-notes.md:105`).
/// - generic password, service `taskforce.bridge`, account `<파티션>:device_id` · `<파티션>:secret`
/// - `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` · `kSecAttrSynchronizable = false` · 데이터 보호 Keychain
/// - 접근 그룹: 앱 전용 그룹(`$(AppIdentifierPrefix)$(APP_BUNDLE_ID)`, entitlements의 `keychain-access-groups`)으로 **고정**한다 — App Group이 아니다.
///   확장 · 위젯이 장치 secret을 읽지 못한다. 서명되지 않은 시험 호스트에는 팀 접두가 없어 값이 비므로 그때는 지정하지 않는다 (`validAccessGroup`)
public enum BridgeKeychainQuery {
    public static let service = "taskforce.bridge"

    public enum Kind: String, Sendable {
        case deviceID = "device_id"
        case secret
    }

    /// `<팀 ID 10자>.<번들 id>` 모양일 때만 쓴다 (`$(AppIdentifierPrefix)`가 풀리지 않은 값 · 빈 값은 nil)
    public static func validAccessGroup(_ raw: String?) -> String? {
        guard let raw, let dot = raw.firstIndex(of: "."), raw.distance(from: raw.startIndex, to: dot) == 10 else { return nil }
        let team = raw[raw.startIndex..<dot]
        guard team.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }), raw.index(after: dot) < raw.endIndex, !raw.contains("$") else { return nil }
        return raw
    }

    public static func match(partition: String, kind: Kind, accessGroup: String? = nil) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "\(partition):\(kind.rawValue)",
            kSecAttrSynchronizable as String: false,
            kSecUseDataProtectionKeychain as String: true,
        ]
        if let accessGroup { query[kSecAttrAccessGroup as String] = accessGroup }
        return query
    }

    public static func add(partition: String, kind: Kind, value: Data, accessGroup: String? = nil) -> [String: Any] {
        var query = match(partition: partition, kind: kind, accessGroup: accessGroup)
        query[kSecValueData as String] = value
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return query
    }
}

public struct KeychainBridgeCredentialStore: BridgeCredentialStore {
    private let accessGroup: String?

    /// `accessGroup`은 `BridgeKeychainQuery.validAccessGroup`을 지난 값 (앱이 Info.plist에서 읽는다)
    public init(accessGroup: String? = nil) {
        self.accessGroup = BridgeKeychainQuery.validAccessGroup(accessGroup)
    }

    public func deviceID(partition: String) throws -> String? { try read(partition, .deviceID) }
    public func secret(partition: String) throws -> String? { try read(partition, .secret) }
    public func save(deviceID: String, partition: String) throws { try write(deviceID, partition, .deviceID) }
    public func save(secret: String, partition: String) throws { try write(secret, partition, .secret) }

    public func deleteAll(partition: String) throws {
        for kind in [BridgeKeychainQuery.Kind.deviceID, .secret] {
            let status = SecItemDelete(BridgeKeychainQuery.match(partition: partition, kind: kind, accessGroup: accessGroup) as CFDictionary)
            if status != errSecSuccess, status != errSecItemNotFound { throw KeychainError(status: status) }
        }
    }

    public func deleteSecret(partition: String) throws {
        let status = SecItemDelete(BridgeKeychainQuery.match(partition: partition, kind: .secret, accessGroup: accessGroup) as CFDictionary)
        if status != errSecSuccess, status != errSecItemNotFound { throw KeychainError(status: status) }
    }

    private func read(_ partition: String, _ kind: BridgeKeychainQuery.Kind) throws -> String? {
        var query = BridgeKeychainQuery.match(partition: partition, kind: kind, accessGroup: accessGroup)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
        return (result as? Data).flatMap { String(data: $0, encoding: .utf8) }
    }

    private func write(_ value: String, _ partition: String, _ kind: BridgeKeychainQuery.Kind) throws {
        let data = Data(value.utf8)
        let update = SecItemUpdate(BridgeKeychainQuery.match(partition: partition, kind: kind, accessGroup: accessGroup) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecItemNotFound {
            let add = SecItemAdd(BridgeKeychainQuery.add(partition: partition, kind: kind, value: data, accessGroup: accessGroup) as CFDictionary, nil)
            guard add == errSecSuccess else { throw KeychainError(status: add) }
        } else if update != errSecSuccess {
            throw KeychainError(status: update)
        }
    }
}
#endif
