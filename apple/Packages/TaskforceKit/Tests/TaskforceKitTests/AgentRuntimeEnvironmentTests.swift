import Foundation
import Testing
@testable import TaskforceKit

/// 샌드박스 감지 (OA M1a): 샌드박스 앱이 띄운 자식 프로세스는 샌드박스를 물려받아 사용자의 `claude` · `codex` 로그인과 PATH에 닿지 못한다.
/// 기준은 환경 변수 `APP_SANDBOX_CONTAINER_ID`가 있는지다 (샌드박스 프로세스에만 시스템이 넣는다). 환경 변수가 없어도
/// 홈 디렉터리가 `…/Library/Containers/…` 안이면 샌드박스다 (보조 판정: 환경이 비워진 실행). 이 값만 제공하고 화면 문구는 이 PR의 일이 아니다.
struct AgentRuntimeEnvironmentTests {
    static let plainHome = "/Users/someone"

    @Test func sandboxedWhenTheContainerVariableIsPresent() {
        #expect(AgentRuntimeEnvironment.isSandboxed(environment: ["APP_SANDBOX_CONTAINER_ID": "dev.taskforcelabs.taskforce"], homeDirectory: Self.plainHome))
        #expect(AgentRuntimeEnvironment.isSandboxed(environment: ["PATH": "/usr/bin", "APP_SANDBOX_CONTAINER_ID": "x"], homeDirectory: Self.plainHome))
    }

    @Test func notSandboxedWhenItIsAbsent() {
        #expect(!AgentRuntimeEnvironment.isSandboxed(environment: [:], homeDirectory: Self.plainHome))
        #expect(!AgentRuntimeEnvironment.isSandboxed(environment: ["PATH": "/usr/bin", "HOME": "/Users/someone"], homeDirectory: Self.plainHome))
        // 비슷한 이름은 세지 않는다
        #expect(!AgentRuntimeEnvironment.isSandboxed(environment: ["APP_SANDBOX_CONTAINER": "x", "app_sandbox_container_id": "x"], homeDirectory: Self.plainHome))
    }

    /// 보조 판정: 환경 변수 없이 홈 디렉터리가 컨테이너 안이면 샌드박스
    @Test func sandboxedWhenTheHomeDirectoryIsInsideAContainer() {
        let container = "/Users/someone/Library/Containers/dev.taskforcelabs.taskforce/Data"
        #expect(AgentRuntimeEnvironment.isSandboxed(environment: [:], homeDirectory: container))
        #expect(AgentRuntimeEnvironment.isSandboxed(environment: [:], homeDirectory: container + "/Library/Caches"))
    }

    /// 이름만 비슷한 경로는 컨테이너가 아니다 (사용자 폴더 이름이 Containers여도 `/Library/Containers/`가 아니면)
    @Test func aPlainHomeThatMerelyMentionsContainersIsNotASandbox() {
        #expect(!AgentRuntimeEnvironment.isSandboxed(environment: [:], homeDirectory: "/Users/containers"))
        #expect(!AgentRuntimeEnvironment.isSandboxed(environment: [:], homeDirectory: "/Users/someone/Containers/work"))
        #expect(!AgentRuntimeEnvironment.isSandboxed(environment: [:], homeDirectory: "/Users/someone/Library/Containers"))
        #expect(!AgentRuntimeEnvironment.isSandboxed(environment: [:], homeDirectory: ""))
    }

    @Test func theKeyIsTheOneTheSystemSets() {
        #expect(AgentRuntimeEnvironment.sandboxContainerKey == "APP_SANDBOX_CONTAINER_ID")
    }

    @Test func theDefaultsReadThisProcess() {
        let expected = ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil || NSHomeDirectory().contains("/Library/Containers/")
        #expect(AgentRuntimeEnvironment.isSandboxed() == expected)
    }
}
