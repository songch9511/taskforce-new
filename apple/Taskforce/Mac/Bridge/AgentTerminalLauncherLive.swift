#if os(macOS)
import AppKit
import Foundation
import TaskforceKit

/// Open in Terminal · Resume here의 앱 구현 (OA D4a2-06 · 07). 판단은 Kit이 한다 (`CommandFileTerminalLauncher` · `ClaudeResumeProcessInspector`) —
/// 여기는 값이 오는 곳(이 Mac의 활성 런타임)과 `.command`를 두는 폴더, 파일을 여는 기본 처리 앱을 대는 일뿐이다.
/// 시험이 실제 터미널을 열지 않게 `AgentTerminalOpening`을 주입할 수 있다.
enum AgentTerminalLauncherLive {
    /// `.command` 파일을 두는 폴더: `<Application Support>/<번들 id>/Terminal` (0700)
    static func commandDirectory() -> URL? {
        guard let bundleID = Bundle.main.bundleIdentifier,
              let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        return support.appending(path: bundleID, directoryHint: .isDirectory).appending(path: "Terminal", directoryHint: .isDirectory)
    }

    /// 이 Mac의 활성 런타임에서 값을 읽는 launcher. 폴더를 정하지 못하면 nil (알약을 그리지 않는다)
    static func launcher(directory: URL? = commandDirectory(), opener: any AgentTerminalOpening = WorkspaceTerminalOpener()) -> (any AgentTerminalLauncher)? {
        guard let directory else { return nil }
        return CommandFileTerminalLauncher(
            target: { sessionID in
                guard let runtime = await MainActor.run(body: { BridgeHost.shared?.activeRuntime }) else { return nil }
                return await runtime.terminalTarget(forAgentSession: sessionID)
            },
            store: AgentTerminalCommandStore(directory: directory), opener: opener
        )
    }

    /// Resume here 전의 프로세스 검사기: 이 Mac 상태가 묶은 Claude 세션 id로 프로세스를 훑는다 (메인 스레드 밖)
    static func inspector() -> any AgentProcessInspector {
        ClaudeResumeProcessInspector(providerSession: { sessionID in
            guard let runtime = await MainActor.run(body: { BridgeHost.shared?.activeRuntime }) else { return nil }
            return await runtime.providerSessionID(forAgentSession: sessionID)
        })
    }

    /// 앱 시작 때 지난 `.command` 파일을 지운다 (메인 스레드 밖)
    static func sweepOldFiles(directory: URL? = commandDirectory()) {
        guard let directory else { return }
        Task.detached(priority: .utility) { AgentTerminalCommandStore(directory: directory).sweep() }
    }
}

/// 기본 처리 앱(Terminal)으로 파일을 연다
struct WorkspaceTerminalOpener: AgentTerminalOpening {
    func open(_ file: URL) async -> Bool {
        await MainActor.run { NSWorkspace.shared.open(file) }
    }
}
#endif
