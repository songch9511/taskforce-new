import Testing
@testable import TaskforceKit

struct SignInNonceTests {
    @Test func hashesWithSHA256Hex() {
        // echo -n "abc" | shasum -a 256
        #expect(SignInNonce(raw: "abc").hashed == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    @Test func randomHasRequestedLengthAndDiffers() {
        let a = SignInNonce.random()
        let b = SignInNonce.random()
        #expect(a.raw.count == 32)
        #expect(SignInNonce.random(length: 8).raw.count == 8)
        #expect(a != b)
    }
}
