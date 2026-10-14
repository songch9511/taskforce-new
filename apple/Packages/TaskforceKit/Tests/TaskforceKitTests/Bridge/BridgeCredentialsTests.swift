#if os(macOS)
import Foundation
import Security
import Testing
@testable import TaskforceKit

/// 장치 자격 (OA D2b 계약 2.12 · 4.1 K16): device_id 난수 · secret 모양 · Keychain 쿼리(ThisDeviceOnly · 동기화 안 함) · 파티션마다 따로
struct BridgeCredentialsTests {
    @Test func aNewDeviceIDIsFortyThreeBase64URLCharactersAndNeverRepeats() {
        let ids = (0..<50).map { _ in BridgeCredentialRules.newDeviceID() }
        #expect(Set(ids).count == 50)
        for id in ids {
            #expect(id.count == 43)
            #expect(id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") })
        }
        // 128비트 이상 (32바이트)
        #expect(Data(base64URL: ids[0])?.count == 32)
    }

    @Test func onlyAFortyThreeCharacterBase64URLSecretIsAccepted() {
        let good = "c2VjcmV0c2VjcmV0c2VjcmV0c2VjcmV0c2VjcmV0MTI"
        #expect(BridgeCredentialRules.isValidSecret(good))
        #expect(!BridgeCredentialRules.isValidSecret(String(good.dropLast())))
        #expect(!BridgeCredentialRules.isValidSecret(good + "A"))
        #expect(!BridgeCredentialRules.isValidSecret(String(good.dropLast()) + "="))
        #expect(!BridgeCredentialRules.isValidSecret(String(good.dropLast()) + "+"))
        #expect(!BridgeCredentialRules.isValidSecret(String(good.dropLast()) + "/"))
        #expect(!BridgeCredentialRules.isValidSecret(""))
        #expect(!BridgeCredentialRules.isValidSecret(good + "\n"))
    }

    @Test func theKeychainQueryIsThisDeviceOnlyUnsyncedDataProtectionAndHasNoAccessGroup() throws {
        let partition = "0123456789abcdef0123456789abcdef"
        let add = BridgeKeychainQuery.add(partition: partition, kind: .secret, value: Data("v".utf8))
        #expect(add[kSecClass as String] as? String == kSecClassGenericPassword as String)
        #expect(add[kSecAttrService as String] as? String == "taskforce.bridge")
        #expect(add[kSecAttrAccount as String] as? String == "\(partition):secret")
        #expect(add[kSecAttrAccessible as String] as? String == kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
        #expect(add[kSecAttrSynchronizable as String] as? Bool == false)
        #expect(add[kSecUseDataProtectionKeychain as String] as? Bool == true)
        #expect(add[kSecAttrAccessGroup as String] == nil, "App Group이 아니라 앱 전용 그룹: 확장 · 위젯이 장치 secret을 읽지 않게")
        #expect(add[kSecValueData as String] as? Data == Data("v".utf8))

        let match = BridgeKeychainQuery.match(partition: partition, kind: .deviceID)
        #expect(match[kSecAttrAccount as String] as? String == "\(partition):device_id")
        #expect(match[kSecAttrSynchronizable as String] as? Bool == false)
        #expect(match[kSecAttrAccessGroup as String] == nil)
        #expect(match[kSecUseDataProtectionKeychain as String] as? Bool == true)
        #expect(match[kSecValueData as String] == nil)
    }

    @Test func eachPartitionHasItsOwnKeychainItems() {
        let a = BridgeKeychainQuery.match(partition: String(repeating: "a", count: 32), kind: .secret)
        let b = BridgeKeychainQuery.match(partition: String(repeating: "b", count: 32), kind: .secret)
        #expect(a[kSecAttrAccount as String] as? String != b[kSecAttrAccount as String] as? String)
    }

    @Test func theInMemoryStoreKeepsPartitionsApartAndDeletesOnlyOne() throws {
        let store = InMemoryBridgeCredentialStore()
        try store.save(deviceID: "device-a", partition: "A")
        try store.save(secret: "secret-a", partition: "A")
        try store.save(deviceID: "device-b", partition: "B")
        #expect(try store.deviceID(partition: "A") == "device-a" && store.secret(partition: "A") == "secret-a")
        #expect(try store.deviceID(partition: "B") == "device-b" && store.secret(partition: "B") == nil)
        try store.deleteAll(partition: "A")
        #expect(try store.deviceID(partition: "A") == nil && store.secret(partition: "A") == nil)
        #expect(try store.deviceID(partition: "B") == "device-b")
    }
}

extension Data {
    fileprivate init?(base64URL text: String) {
        var base64 = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64 += "=" }
        self.init(base64Encoded: base64)
    }
}
#endif
