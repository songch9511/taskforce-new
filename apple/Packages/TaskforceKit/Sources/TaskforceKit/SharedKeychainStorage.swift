import Auth
import Foundation
import Security

/// 로그인 세션을 App Group 공유 Keychain에 저장한다. 공유 확장 · 위젯이 같은 세션을 읽는다.
///
/// macOS에서도 iOS와 같은 방식(데이터 보호 Keychain)을 써야 App Group 접근 그룹이 동작하므로
/// supabase-swift의 기본 `KeychainLocalStorage` 대신 직접 구현한다.
public struct SharedKeychainStorage: AuthLocalStorage {
    public let service: String
    public let accessGroup: String

    public init(accessGroup: String, service: String = "taskforce.auth") {
        self.accessGroup = accessGroup
        self.service = service
    }

    public func store(key: String, value: Data) throws {
        let status = SecItemUpdate(baseQuery(key) as CFDictionary, [kSecValueData as String: value] as CFDictionary)
        if status == errSecItemNotFound {
            var query = baseQuery(key)
            query[kSecValueData as String] = value
            query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            try check(SecItemAdd(query as CFDictionary, nil))
        } else {
            try check(status)
        }
    }

    public func retrieve(key: String) throws -> Data? {
        var query = baseQuery(key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        try check(status)
        return result as? Data
    }

    public func remove(key: String) throws {
        let status = SecItemDelete(baseQuery(key) as CFDictionary)
        if status == errSecItemNotFound { return }
        try check(status)
    }

    private func baseQuery(_ key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecAttrAccessGroup as String: accessGroup,
            kSecUseDataProtectionKeychain as String: true,
        ]
    }

    private func check(_ status: OSStatus) throws {
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }
}

public struct KeychainError: Error, Equatable, CustomStringConvertible {
    public let status: OSStatus

    public var description: String {
        let message = SecCopyErrorMessageString(status, nil) as String? ?? "알 수 없는 오류"
        return "Keychain 오류 \(status): \(message)"
    }
}
