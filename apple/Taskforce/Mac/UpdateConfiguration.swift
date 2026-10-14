#if os(macOS)
import Foundation

/// 자동 업데이트(Sparkle 2)를 시작할지의 판단 (OA M1b). Sparkle을 import하지 않는 값이라 시험이 직접 부른다.
/// 피드 주소 · 공개 키는 Info.plist의 `SUFeedURL` · `SUPublicEDKey`이고, 값은 빌드 설정 `SPARKLE_FEED_URL` · `SPARKLE_PUBLIC_ED_KEY`에서 온다
/// (Debug는 빈 값, Release는 출시 전에 채운다: `docs/go-live/mac-dmg.md` "자동 업데이트").
struct UpdateConfiguration: Equatable, Sendable {
    let feedURL: String
    let publicKey: String

    init(feedURL: String, publicKey: String) {
        self.feedURL = feedURL
        self.publicKey = publicKey
    }

    /// Info.plist 사전에서. 키가 없거나 문자열이 아니면 빈 값이다
    init(info: [String: Any]?) {
        self.init(feedURL: info?["SUFeedURL"] as? String ?? "", publicKey: info?["SUPublicEDKey"] as? String ?? "")
    }

    /// 이 앱 번들의 값
    static var current: UpdateConfiguration { UpdateConfiguration(info: Bundle.main.infoDictionary) }

    /// 시작하지 않는 이유 (값은 담지 않는다: 로그에 그대로 남겨도 된다)
    enum Reason: Equatable, Sendable {
        /// XCTest 호스트: 시험은 업데이터를 시작하지 않는다 (`TestHost`)
        case testHost
        /// Debug 빌드: 실사용 번들 id를 쓰므로 개발 실행이 실제 업데이트를 받아 오지 않는다
        case debugBuild
        /// 비어 있음 · 풀리지 않은 `$(…)` · http(s) 주소가 아님
        case noFeedURL
        /// 비어 있음 · 풀리지 않은 `$(…)` · base64 32바이트(ed25519 공개 키 크기)가 아님
        case noPublicKey
    }

    enum Decision: Equatable, Sendable {
        case start
        case notStarted(Reason)
    }

    /// 이유는 이 순서로 하나만 돌려준다: 시험 호스트 → Debug → 피드 → 공개 키
    func decision(isTestHost: Bool, isDebugBuild: Bool) -> Decision {
        if isTestHost { return .notStarted(.testHost) }
        if isDebugBuild { return .notStarted(.debugBuild) }
        if !hasUsableFeedURL { return .notStarted(.noFeedURL) }
        if !hasUsablePublicKey { return .notStarted(.noPublicKey) }
        return .start
    }

    /// 피드는 **자르지 않고** 있는 그대로 검사한다: Sparkle은 Info.plist 원문을 그대로 읽으므로(따옴표만 벗긴다) 앞뒤 공백 · 줄바꿈이 있으면 주소가 만들어지지 않는다.
    /// 검사한 값과 Sparkle이 쓰는 값이 같아야 하므로 그런 피드는 쓸 수 없는 것으로 본다 (공개 키는 Sparkle도 앞뒤 공백을 지운다)
    private var hasUsableFeedURL: Bool {
        let text = feedURL
        guard !text.isEmpty, text == text.trimmingCharacters(in: .whitespacesAndNewlines), !text.hasPrefix("$("),
              let url = URL(string: text), let scheme = url.scheme?.lowercased() else { return false }
        return (scheme == "https" || scheme == "http") && url.host(percentEncoded: false)?.isEmpty == false
    }

    private var hasUsablePublicKey: Bool {
        let text = publicKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.hasPrefix("$("), let data = Data(base64Encoded: text) else { return false }
        return data.count == 32
    }
}

/// 업데이트 뒤 재시작을 지금 해도 되는지. **지금은 항상 허용**한다.
/// 자리: 실행 중인 에이전트 턴이 있을 때의 종료 확인은 bridge WP가 여기서 한다 (`AppUpdater.updaterShouldRelaunchApplication`이 이 함수를 부른다).
enum UpdateRelaunchPolicy {
    static func allowsRelaunchNow() -> Bool { true }
}
#endif
