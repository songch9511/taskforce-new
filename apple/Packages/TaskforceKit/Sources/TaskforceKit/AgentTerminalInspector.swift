#if os(macOS)
import Foundation

/// Resume here 전의 프로세스 검사기 (OA D4a2-07): Taskforce 세션 id → 이 Mac 상태가 묶은 Claude 세션 id → 같은 사용자의 프로세스 argv에 `--resume <id>`가 있나.
/// - 상태가 없으면(이 Mac이 모르는 세션 · 첫 턴 전) false다. **못 찾음은 증명이 아니다**: 확인 카드는 늘 거친다
/// - 모든 프로세스를 훑을 수 있으므로 메인 스레드에서 돌리지 않는다. 훑기는 주입한 실행기(`run`)에서 한다 (시험은 어느 스레드인지 본다)
public struct ClaudeResumeProcessInspector: AgentProcessInspector {
    public typealias Scan = @Sendable (String) -> Bool
    public typealias Runner = @Sendable (@escaping @Sendable () -> Bool) async -> Bool

    private let providerSession: @Sendable (UUID) async -> String?
    private let scan: Scan
    private let run: Runner

    public init(
        providerSession: @escaping @Sendable (UUID) async -> String?, scan: @escaping Scan = { ClaudeCodeProcessScanner.hasProcess(resuming: $0) },
        run: @escaping Runner = { work in await Task.detached(priority: .userInitiated) { work() }.value }
    ) {
        self.providerSession = providerSession
        self.scan = scan
        self.run = run
    }

    public func hasProcess(resuming sessionID: UUID) async -> Bool {
        guard let provider = await providerSession(sessionID) else { return false }
        let scan = scan
        return await run { scan(provider) }
    }
}
#endif
