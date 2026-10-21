#if os(macOS)
import Darwin
import Foundation
import TaskforceAgentWire

// Open in Claude (OA 외부 세션 후속 F4, 사용자 결정 2026-10-21): 목록의 줄에서 **그 세션**을 Claude 데스크톱 앱에서 연다.
// 사용자의 수정하지 않은 `claude`를 `--desktop --resume <id>` 인자 둘로만 띄운다 (CLI 2.1.306 실측: 그 세션의 cwd에서, 터미널(pty) 아래에서만 돈다. 터미널이 아니면 거절한다).
// 대화 · 자격 · 프롬프트는 건드리지 않는다: 프롬프트 · stdin 입력은 CLI가 허용하지 않고 이 코드도 쓰지 않는다.
//
// 지키는 것
// - id는 소문자 정규 UUID만 (옵션 · 경로 · 셸 글자가 들어갈 길 없음). 그 밖은 아무것도 띄우지 않는다
// - cwd는 이 행의 폴더를 **실제 폴더 규칙**(`WorkspaceFolderRules.standard`, 사용자 행동이라 stat · realpath를 해도 된다)이 받아 준 realpath만. 아니면 띄우지 않는다
// - 자식 환경은 어댑터와 같은 넷(HOME · USER · LANG · PATH, `ClaudeCodeEnvironment.child`): Taskforce의 비밀 · `ANTHROPIC_*` · `DYLD_*`가 가지 않는다
// - 기한 15초, 끝나지 않으면 프로세스 그룹을 SIGKILL로 정리한다
// - 출력은 결과 코드 하나로만 바꾼다 (메모리에 잠깐 두고 버린다). id · 경로 · 출력 글을 로그 · 값으로 내보내지 않는다

/// 결과 (고정 셋). 호출한 쪽은 `.unavailable`이면 앱만 앞으로 가져온다
public enum ClaudeDesktopOpenResult: Equatable, Sendable {
    /// `claude`가 0으로 끝났다: 앱이 앞으로 온다
    case opened
    /// 그 세션이 다른 터미널에 열려 있다고 거절했다 ("Run /desktop there instead")
    case openInAnotherTerminal
    /// 그 밖 모두: id · 폴더 · `claude`를 쓸 수 없거나, `--desktop`을 모르는 옛 버전 · 로그인 필요 · 시간 초과 · 다른 거절
    case unavailable
}

public enum ClaudeDesktopOpen {
    public static let timeout: TimeInterval = 15
    /// 출력은 앞에서 이만큼만 메모리에 둔다
    static let maxOutput = 16 * 1024
    static let refusalPhrase = "open in another terminal"

    /// 정확히 `--desktop --resume <id>`. id가 소문자 정규 UUID가 아니면 nil
    public static func arguments(sessionID: String) -> [String]? {
        guard ExternalSessionRules.isCanonicalUUID(sessionID), sessionID.wholeMatch(of: /[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/) != nil else { return nil }
        return ["--desktop", "--resume", sessionID]
    }

    /// 끝난 모양 → 결과. 거절 글이 있으면 종료 코드와 상관없이 `.openInAnotherTerminal`, 시간 초과 · 신호 · 0이 아닌 종료는 `.unavailable`
    public static func classify(exitCode: Int32?, timedOut: Bool, output: Data) -> ClaudeDesktopOpenResult {
        if timedOut { return .unavailable }
        if folded(output).contains(refusalPhrase) { return .openInAnotherTerminal }
        return exitCode == 0 ? .opened : .unavailable
    }

    /// 색 · 제어 열을 지우고 공백류를 한 칸으로 접고 소문자로 (pty가 줄을 접어도 · 색이 끼어도 같은 글로 읽는다)
    static func folded(_ output: Data) -> String {
        var scalars = String.UnicodeScalarView()
        var pendingSpace = false
        var iterator = String(decoding: output.prefix(maxOutput), as: UTF8.self).unicodeScalars.makeIterator()
        while let scalar = iterator.next() {
            if scalar.value == 0x1B {
                // CSI `ESC [ … 최종 바이트`, OSC `ESC ] … BEL | ESC \`, 그 밖은 한 글자
                guard let kind = iterator.next() else { break }
                if kind == "[" {
                    while let next = iterator.next(), !(0x40...0x7E).contains(next.value) {}
                } else if kind == "]" {
                    while let next = iterator.next(), next.value != 0x07, next.value != 0x1B {}
                }
                continue
            }
            if scalar.properties.isWhitespace || scalar.value < 0x20 {
                pendingSpace = !scalars.isEmpty
                continue
            }
            if pendingSpace {
                scalars.append(" ")
                pendingSpace = false
            }
            scalars.append(contentsOf: String(scalar).lowercased().unicodeScalars)
        }
        return String(scalars)
    }

    /// 진짜 실행 (막는다): `claude`를 pty 슬레이브를 0 · 1 · 2로 해서 띄우고 `timeout`까지 기다린다. 출력은 결과로만 바뀐다.
    /// 끝난 `claude`는 터미널을 붙든 자손을 기다리지 않는다. 기한이 되면 프로세스 그룹을 정리한다
    public static func runUnderPTY(executable: ClaudeCodeExecutable, arguments: [String], environment: [String: String], cwd: String, timeout: TimeInterval) -> ClaudeDesktopOpenResult {
        guard let (master, slave) = openPTY() else { return .unavailable }
        _ = fcntl(master, F_SETFL, fcntl(master, F_GETFL) | O_NONBLOCK)
        // 검사한 실제 파일로 띄운다 (보안 검토 P3): 후보 링크가 검사 뒤에 바뀌어도 다른 파일이 돌지 않는다. 자식이 보는 이름은 후보 경로다 (어댑터의 지킴이와 같다)
        let spawned = AgentSpawn.spawn(
            executable: executable.realPath, argv0: executable.path, arguments: arguments, environment: environment, cwd: cwd, fds: [(0, slave), (1, slave), (2, slave)], disclaim: false
        )
        close(slave)
        guard let spawned else {
            close(master)
            return .unavailable
        }
        let pid = spawned.pid
        let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(max(0, timeout) * 1_000_000_000)
        var output = Data()
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        var status: Int32 = 0
        var exited = false
        var timedOut = false
        var terminalClosed = false

        /// 읽을 수 있는 만큼 한 번. 읽었으면 true
        func readOnce() -> Bool {
            let count = buffer.withUnsafeMutableBufferPointer { read(master, $0.baseAddress!, $0.count) }
            if count > 0 {
                if output.count < maxOutput { output.append(contentsOf: buffer[0..<min(count, maxOutput - output.count)]) }
                return true
            }
            // 0 · EIO: 슬레이브가 모두 닫혔다. EAGAIN: 지금은 없다
            if count == 0 || (count < 0 && errno != EAGAIN && errno != EINTR) { terminalClosed = true }
            return false
        }

        while true {
            if waitpid(pid, &status, WNOHANG) == pid {
                exited = true
                // 남은 출력만 가져온다 (붙든 자손이 계속 써도 끝낸다)
                var rounds = 0
                while rounds < 64, readOnce() { rounds += 1 }
                break
            }
            let now = DispatchTime.now().uptimeNanoseconds
            if now >= deadline {
                timedOut = true
                break
            }
            if terminalClosed {
                usleep(20_000)
                continue
            }
            var item = pollfd(fd: master, events: Int16(POLLIN), revents: 0)
            let waitMilliseconds = Int32(max(1, min(100, (deadline - now) / 1_000_000)))
            guard poll(&item, 1, waitMilliseconds) > 0 else { continue }
            if endsPolling(revents: item.revents) {
                // 오류 · 끊김 · 잘못된 fd: 더 기다리지 않는다 (남은 것만 가져온다). 끝난 뒤에는 위의 waitpid · 기한이 마친다
                var rounds = 0
                while rounds < 64, readOnce() { rounds += 1 }
                terminalClosed = true
            } else if item.revents & Int16(POLLIN) != 0 {
                _ = readOnce()
            }
        }
        if timedOut {
            // 하위 프로세스까지 (그룹 = spawn이 만든 새 그룹). 끝난 claude가 띄운 앱은 그룹이 아니라 건드리지 않는다
            killpg(pid, SIGKILL)
            kill(pid, SIGKILL)
            // 거두는 일은 기다리지 않는다 (보안 검토 P3): SIGKILL이면 곧 끝나지만 호출은 기한에서 돌아가고, 좀비가 남지 않게 뒤에서 거둔다
            DispatchQueue.global(qos: .utility).async {
                var reaped: Int32 = 0
                while waitpid(pid, &reaped, 0) < 0, errno == EINTR {}
            }
        }
        close(master)
        let code: Int32? = exited && (status & 0x7f) == 0 ? (status >> 8) & 0xff : nil
        return classify(exitCode: code, timedOut: timedOut, output: output)
    }

    /// pty 한 쌍 (보안 검토 P3): 만들 때부터 `O_CLOEXEC`다. `openpty`는 만든 뒤에 `fcntl`로 걸어서 그 사이 다른 스레드의 spawn이 물려받을 수 있다.
    /// 슬레이브는 `TIOCPTYGNAME`이 준 이름으로 열고 제어 터미널로 삼지 않는다 (`O_NOCTTY`). 줄 접힘을 줄이려고 넓게 (거절 글은 접혀도 읽는다)
    static func openPTY() -> (master: Int32, slave: Int32)? {
        let master = posix_openpt(O_RDWR | O_NOCTTY | O_CLOEXEC)
        guard master >= 0 else { return nil }
        var name = [CChar](repeating: 0, count: 128)
        guard grantpt(master) == 0, unlockpt(master) == 0, ptsname_r(master, &name, name.count) == 0 else {
            close(master)
            return nil
        }
        let slave = open(name, O_RDWR | O_NOCTTY | O_CLOEXEC)
        guard slave >= 0 else {
            close(master)
            return nil
        }
        var size = winsize(ws_row: 24, ws_col: 200, ws_xpixel: 0, ws_ypixel: 0)
        _ = ioctl(master, TIOCSWINSZ, &size)
        return (master, slave)
    }

    /// 마스터를 더 기다릴 필요가 없다: 오류 · 잘못된 fd는 언제나, 끊김은 읽을 것이 없을 때만 (읽을 것이 남은 끊김은 마저 읽는다)
    static func endsPolling(revents: Int16) -> Bool {
        if revents & Int16(POLLERR | POLLNVAL) != 0 { return true }
        return revents & Int16(POLLHUP) != 0 && revents & Int16(POLLIN) == 0
    }

    /// 실제 실행기: 막는 `runUnderPTY`를 GCD 스레드에서
    public static let livePTY: ClaudeDesktopSessionOpener.Runner = { executable, arguments, environment, cwd, timeout in
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: runUnderPTY(executable: executable, arguments: arguments, environment: environment, cwd: cwd, timeout: timeout))
            }
        }
    }
}

/// 한 세션을 Claude 데스크톱 앱에서 연다. 결과는 고정 코드 셋이고 로그에도 고정 코드만 남긴다
public struct ClaudeDesktopSessionOpener: Sendable {
    public typealias Runner = @Sendable (_ executable: ClaudeCodeExecutable, _ arguments: [String], _ environment: [String: String], _ cwd: String, _ timeout: TimeInterval) async -> ClaudeDesktopOpenResult

    let locator: ClaudeCodeLocator
    let folderRules: WorkspaceFolderRules
    let desktopInstalled: @Sendable () -> Bool
    let appEnvironment: [String: String]
    let timeout: TimeInterval
    let log: any BridgeLogSink
    let run: Runner

    /// - folderRules: 사용자가 폴더를 고를 때와 같은 실제 규칙 (`WorkspaceFolderRules.standard`)
    /// - desktopInstalled: Claude 데스크톱 앱이 이 Mac에 있나 (보안 검토 P2-2). 없으면 `claude`를 띄우지 않는다
    /// - appEnvironment: 앱의 환경. 자식에는 `ClaudeCodeEnvironment.child`가 고른 넷만 간다
    public init(
        locator: ClaudeCodeLocator, folderRules: WorkspaceFolderRules, desktopInstalled: @escaping @Sendable () -> Bool,
        appEnvironment: [String: String] = ProcessInfo.processInfo.environment, timeout: TimeInterval = ClaudeDesktopOpen.timeout, log: any BridgeLogSink = NoBridgeLog(),
        run: @escaping Runner = ClaudeDesktopOpen.livePTY
    ) {
        self.locator = locator
        self.folderRules = folderRules
        self.desktopInstalled = desktopInstalled
        self.appEnvironment = appEnvironment
        self.timeout = timeout
        self.log = log
        self.run = run
    }

    private enum Preparation: Sendable {
        case ready(executable: ClaudeCodeExecutable, environment: [String: String], cwd: String)
        case refused(cause: String)
    }

    /// 막을 수 있는 파일 시스템 호출(폴더 검사의 stat · realpath는 보호 폴더면 접근 동의 창을 띄운다, `claude` 찾기)은 협력 스레드가 아니라 GCD 스레드에서 한다 (보안 검토 P3).
    /// 앱 설치 확인이 먼저다: 앱이 없으면 사용자의 폴더를 만지지도 않는다
    private func prepare(folder: String) -> Preparation {
        guard desktopInstalled() else { return .refused(cause: "no_app") }
        guard case .success(let real) = folderRules.validate(folder) else { return .refused(cause: "folder") }
        guard let executable = locator.locate() else { return .refused(cause: "no_claude") }
        return .ready(executable: executable, environment: ClaudeCodeEnvironment.child(app: appEnvironment, executable: executable), cwd: real)
    }

    /// `.unavailable`이면 아무것도 띄우지 않았거나 `claude`가 거절했다: 부른 쪽이 앱만 앞으로 가져온다
    public func open(sessionID: String, folder: String?) async -> ClaudeDesktopOpenResult {
        guard let arguments = ClaudeDesktopOpen.arguments(sessionID: sessionID) else { return finish(.unavailable, cause: "bad_id") }
        guard let folder else { return finish(.unavailable, cause: "folder") }
        let preparation: Preparation = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { continuation.resume(returning: prepare(folder: folder)) }
        }
        switch preparation {
        case .refused(let cause): return finish(.unavailable, cause: cause)
        case .ready(let executable, let environment, let cwd): return finish(await run(executable, arguments, environment, cwd, timeout), cause: nil)
        }
    }

    private func finish(_ result: ClaudeDesktopOpenResult, cause: String?) -> ClaudeDesktopOpenResult {
        let code = switch result {
        case .opened: "opened"
        case .openInAnotherTerminal: "another_terminal"
        case .unavailable: "unavailable"
        }
        var fields: [String: BridgeLogValue] = ["result": .code(code)]
        if let cause { fields["cause"] = .code(cause) }
        log.log("claude_desktop_open", fields)
        return result
    }
}
#endif
