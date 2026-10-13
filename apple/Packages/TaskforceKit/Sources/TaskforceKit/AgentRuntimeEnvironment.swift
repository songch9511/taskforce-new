import Foundation

/// 이 앱이 사용자의 에이전트(`claude` · `codex`)를 띄울 수 있는 환경인지 (OA M1a, DEC-1 A).
/// App Sandbox 안의 앱이 띄운 자식 프로세스는 샌드박스를 물려받아 사용자의 로그인(`~/.claude`, Keychain)과 PATH에 닿지 못한다.
/// 이 타입은 값만 제공한다. 샌드박스 빌드에서 보일 화면 문구는 디자인이 정해지면 따로 붙인다.
public enum AgentRuntimeEnvironment {
    /// 샌드박스 프로세스에만 시스템이 넣는 환경 변수 (값은 컨테이너 id)
    public static let sandboxContainerKey = "APP_SANDBOX_CONTAINER_ID"

    /// 샌드박스 안에서 돌고 있는지: `APP_SANDBOX_CONTAINER_ID`가 있으면 true.
    /// `environment`는 시험이 넘긴다 (기본: 이 프로세스의 환경)
    public static func isSandboxed(environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        environment[sandboxContainerKey] != nil
    }
}
