#if os(macOS)
import Foundation

/// `BRIDGE_ENABLED` (Mac, OA D2b 계약 2.14 · Q10). **기본은 꺼짐**이다: 꺼진 빌드는 네트워크 · 프로세스 0.
/// - 빌드 설정 `TF_BRIDGE_ENABLED`(Base · Release = `NO`) → Info.plist `TaskforceBridgeEnabled`. 켜는 것(L5)은 xcconfig 한 줄이다
/// - Debug는 여기에 더해 실행 인자 `-TF_BRIDGE YES`가 있어야 켜진다 (인자 영역만 읽는다: 저장된 설정으로는 켜지지 않는다 — `EdgeSurfaces`의 Debug 방식)
/// - 가짜 agent는 Debug에서 `-TF_BRIDGE_FAKE_AGENT YES`일 때만 (Release 바이너리에는 가짜가 없다)
/// 꺼졌는데 원장에 할 일이 남았으면 `BridgeHost`가 마무리 모드로 올린다 (새 전달 0, 사건 · cancel · readback은 계속).
enum BridgeFlag {
    static let infoKey = "TaskforceBridgeEnabled"
    static let argumentKey = "TF_BRIDGE"
    static let fakeAgentKey = "TF_BRIDGE_FAKE_AGENT"

    /// 이 빌드·실행에서 켜졌나. `info`는 Info.plist 사전, `arguments`는 실행 인자 영역
    static func isEnabled(info: [String: Any]?, arguments: [String: Any], isDebugBuild: Bool) -> Bool {
        guard truthy(info?[infoKey]) else { return false }
        return isDebugBuild ? truthy(arguments[argumentKey]) : true
    }

    /// Debug에서 가짜 agent를 쓰나 (Release는 늘 false)
    static func usesFakeAgent(arguments: [String: Any], isDebugBuild: Bool) -> Bool {
        isDebugBuild && truthy(arguments[fakeAgentKey])
    }

    static var current: Bool {
        isEnabled(info: Bundle.main.infoDictionary, arguments: argumentDomain, isDebugBuild: AppRuntime.isDebugBuild)
    }

    static var currentUsesFakeAgent: Bool {
        usesFakeAgent(arguments: argumentDomain, isDebugBuild: AppRuntime.isDebugBuild)
    }

    private static var argumentDomain: [String: Any] {
        UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
    }

    /// `YES` · `true` · `1`만 켜진 것으로 본다. 빈 값 · 풀리지 않은 `$(…)` · 모르는 글자는 꺼짐 (기본 꺼짐)
    private static func truthy(_ value: Any?) -> Bool {
        if let flag = value as? Bool { return flag }
        guard let text = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else { return false }
        return ["yes", "true", "1"].contains(text)
    }
}
#endif
