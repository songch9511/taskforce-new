import CryptoKit
import Foundation

/// Sign in with Apple용 nonce. Apple에는 `hashed`를 보내고, Supabase에는 `raw`를 보낸다.
/// Supabase가 ID 토큰의 nonce 클레임과 `raw`의 SHA-256을 비교해 재사용 공격을 막는다.
public struct AppleSignInNonce: Sendable, Equatable {
    public let raw: String

    public var hashed: String { Self.sha256(raw) }

    public init(raw: String) {
        self.raw = raw
    }

    public static func random(length: Int = 32) -> AppleSignInNonce {
        precondition(length > 0)
        let charset = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVXYZabcdefghijklmnopqrstuvwxyz-._")
        var generator = SystemRandomNumberGenerator()
        let raw = String((0..<length).map { _ in charset.randomElement(using: &generator)! })
        return AppleSignInNonce(raw: raw)
    }

    static func sha256(_ input: String) -> String {
        SHA256.hash(data: Data(input.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
