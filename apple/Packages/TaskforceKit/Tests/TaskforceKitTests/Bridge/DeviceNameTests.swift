#if os(macOS) && DEBUG
import Foundation
import Testing
@testable import TaskforceKit

/// Mac 기기 이름 보내기 (OA F1m, 서버 F1s): 정규화 · 보내도 되는 빌드 판정 · register · heartbeat 본문 · 로그에 이름 0
struct DeviceNameTests {
    // MARK: 정규화: 서버와 같은 표

    private func scalars(_ text: String?) -> [UInt32]? { text.map { $0.unicodeScalars.map(\.value) } }

    /// 서버 시험(`swift-fixtures.test.ts`)이 같은 파일(`Fixtures/bridge-v1/device-name.json`)을 `normalizeDeviceName`으로 읽는다
    @Test func theSharedTableNormalizesLikeTheServer() throws {
        let cases = try #require(try BridgeFixtures.file("device-name")["cases"] as? [[String: Any]])
        #expect(cases.count > 20)
        for item in cases {
            let name = try #require(item["name"] as? String)
            let raw = try #require(item["raw"] as? String)
            let expected = item["expected"] as? String
            // Swift의 `==`는 정준 동등을 같다고 본다 ("e\u{301}" == "\u{e9}"): NFC까지 증명하려면 코드 포인트로 비교한다
            #expect(scalars(DeviceName.normalized(raw)) == scalars(expected), "\(name): \(raw.unicodeScalars.map { String($0.value, radix: 16) })")
        }
    }

    @Test func aMissingNameStaysMissingAndTheLimitIsSixtyFourCodePoints() {
        #expect(DeviceName.normalized(nil) == nil)
        #expect(DeviceName.maxCodePoints == 64)
        let long = String(repeating: "가", count: 200)
        #expect(DeviceName.normalized(long)?.unicodeScalars.count == 64)
    }

    @Test func aNormalizedNameNormalizesToItself() throws {
        let cases = try #require(try BridgeFixtures.file("device-name")["cases"] as? [[String: Any]])
        for item in cases {
            guard let expected = item["expected"] as? String else { continue }
            #expect(scalars(DeviceName.normalized(expected)) == scalars(expected), "\(expected)")
        }
    }

    // MARK: 보내도 되는 빌드 · 서버 (F1s notes 8장 위험 2)

    @Test func debugBuildsSendTheNameOnlyToALoopbackServer() throws {
        let production = try #require(URL(string: "https://app.taskforce.example"))
        #expect(!DeviceNamePolicy.allowsSending(isDebugBuild: true, apiBaseURL: production), "개발 빌드가 운영 서버로 이름을 보내지 않는다")
        for local in ["http://localhost:3000", "http://127.0.0.1:3000", "http://[::1]:3000", "http://dev.localhost:3000"] {
            #expect(DeviceNamePolicy.allowsSending(isDebugBuild: true, apiBaseURL: try #require(URL(string: local))), Comment(rawValue: local))
        }
        // Release는 bridge가 켜진 빌드에서만 런타임이 만들어진다 (호스트가 `BRIDGE_ENABLED`로 막는다)
        #expect(DeviceNamePolicy.allowsSending(isDebugBuild: false, apiBaseURL: production))
    }

    @Test func theProviderIsGivenOnlyWhereSendingIsAllowed() throws {
        let production = try #require(URL(string: "https://app.taskforce.example"))
        let local = try #require(URL(string: "http://localhost:3000"))
        #expect(DeviceNamePolicy.provider(isDebugBuild: true, apiBaseURL: production, source: { "Mac" }) == nil)
        #expect(DeviceNamePolicy.provider(isDebugBuild: true, apiBaseURL: local, source: { "Mac" })?() == "Mac")
        #expect(DeviceNamePolicy.provider(isDebugBuild: false, apiBaseURL: production, source: { "Mac" })?() == "Mac")
    }

    // MARK: register · heartbeat 본문

    private func heartbeats(_ h: BridgeHarness) -> [FakeBridgeServer.Recorded] { h.server.requests("heartbeat") }

    @Test func registerSendsTheNormalizedNameUnderTheServerKey() async throws {
        let h = try BridgeHarness(deviceName: { "  Daniel\u{200B}'s\tMacBook  Pro " })
        await h.registerFirst()
        let register = try #require(h.server.requests("register").first)
        #expect(register.json["device_name"] as? String == "Daniel's MacBook Pro", "원문 그대로가 아니라 정규화한 값")
    }

    @Test func everyHeartbeatCarriesTheName() async throws {
        let h = try BridgeHarness(deviceName: { "Daniel's MacBook Pro" })
        await h.registerFirst()
        for _ in 0..<3 {
            h.clock.jump(by: 31)
            await h.runtime.tick()
        }
        let beats = heartbeats(h)
        #expect(beats.count >= 3, "heartbeat \(beats.count)번")
        #expect(beats.allSatisfy { $0.json["device_name"] as? String == "Daniel's MacBook Pro" }, "서버가 쓰기 실패를 삼키므로 매번 싣는다")
    }

    @Test func aMacWithNoNameSendsNoKeyNotNull() async throws {
        for provider in [nil, { @Sendable () -> String? in nil }, { @Sendable () -> String? in "\u{202E}\u{200B}  " }] as [(@Sendable () -> String?)?] {
            let h = try BridgeHarness(deviceName: provider)
            await h.registerFirst()
            h.clock.jump(by: 31)
            await h.runtime.tick()
            for request in h.server.requests("register") + heartbeats(h) {
                #expect(request.json["device_name"] == nil && !request.bodyJSON.contains("device_name"), "키 자체가 없다 (null 금지)")
            }
        }
    }

    @Test func aDrainRuntimeNeverSendsTheName() async throws {
        let h = try BridgeHarness(deviceName: { "Daniel's MacBook Pro" })
        await h.registerFirst()
        try await h.seedEvents(count: 1)
        try await h.restart(mode: .drain)
        let before = heartbeats(h).count
        h.clock.jump(by: 31)
        await h.runtime.tick()
        let after = Array(heartbeats(h).dropFirst(before))
        #expect(!after.isEmpty, "마무리 모드도 남은 일을 위해 heartbeat는 보낸다")
        #expect(after.allSatisfy { $0.json["device_name"] == nil }, "bridge가 꺼진 것으로 본다: 이름은 보내지 않는다")
    }

    // MARK: 로그 · 원장 · 디스크에 이름 0

    @Test func theNameIsNeverLoggedOrWrittenToTheLedger() async throws {
        let name = "Canary-\(UUID().uuidString.prefix(8))'s Mac"
        let h = try BridgeHarness(deviceName: { name })
        await h.registerFirst()
        h.clock.jump(by: 31)
        await h.runtime.tick()
        _ = await h.runtime.disconnect()
        let logged = h.log.lines.joined(separator: "\n")
        #expect(!logged.contains(name) && !logged.contains("Canary"), "로그에는 코드 · 개수만 남는다")
        #expect(!h.diskContains(name), "원장 파일에도 이름이 없다")
    }
}
#endif
