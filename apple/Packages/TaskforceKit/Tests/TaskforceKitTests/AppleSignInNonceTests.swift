import Testing
@testable import TaskforceKit

struct AppleSignInNonceTests {
    @Test func hashesWithSHA256Hex() {
        // echo -n "abc" | shasum -a 256
        #expect(AppleSignInNonce(raw: "abc").hashed == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    @Test func randomHasRequestedLengthAndDiffers() {
        let a = AppleSignInNonce.random()
        let b = AppleSignInNonce.random()
        #expect(a.raw.count == 32)
        #expect(AppleSignInNonce.random(length: 8).raw.count == 8)
        #expect(a != b)
    }
}
