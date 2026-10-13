import Foundation
import Testing
@testable import TaskforceKit

/// 샌드박스 감지 (OA M1a): 샌드박스 앱이 띄운 자식 프로세스는 샌드박스를 물려받아 사용자의 `claude` · `codex` 로그인과 PATH에 닿지 못한다.
/// 기준은 환경 변수 `APP_SANDBOX_CONTAINER_ID`가 있는지다 (샌드박스 프로세스에만 시스템이 넣는다). 이 값만 제공하고 화면 문구는 이 PR의 일이 아니다.
struct AgentRuntimeEnvironmentTests {
    @Test func sandboxedWhenTheContainerVariableIsPresent() {
        #expect(AgentRuntimeEnvironment.isSandboxed(environment: ["APP_SANDBOX_CONTAINER_ID": "dev.taskforcelabs.taskforce"]))
        #expect(AgentRuntimeEnvironment.isSandboxed(environment: ["PATH": "/usr/bin", "APP_SANDBOX_CONTAINER_ID": "x"]))
    }

    @Test func notSandboxedWhenItIsAbsent() {
        #expect(!AgentRuntimeEnvironment.isSandboxed(environment: [:]))
        #expect(!AgentRuntimeEnvironment.isSandboxed(environment: ["PATH": "/usr/bin", "HOME": "/Users/someone"]))
        // 비슷한 이름은 세지 않는다
        #expect(!AgentRuntimeEnvironment.isSandboxed(environment: ["APP_SANDBOX_CONTAINER": "x", "app_sandbox_container_id": "x"]))
    }

    @Test func theKeyIsTheOneTheSystemSets() {
        #expect(AgentRuntimeEnvironment.sandboxContainerKey == "APP_SANDBOX_CONTAINER_ID")
    }

    @Test func theDefaultReadsThisProcessEnvironment() {
        let expected = ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil
        #expect(AgentRuntimeEnvironment.isSandboxed() == expected)
    }
}
