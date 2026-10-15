#if os(macOS)
import Darwin
import Foundation
import Testing
@testable import TaskforceKit

/// 고아 · 정체 확인 (OA D3a 계약 2.13 · 2.14 · 4.1 "정체", G26 · G27). 실제 하위 프로세스(`/bin/sh` 반복)를 posix_spawn으로 띄워 본다 (D2b F10 방식).
/// 정체 = pid > 1 + 커널 시작 시각 1ms 안 + 소유자 uid + argv의 `--settings …/config/<marker>.settings.json`
@Suite(.serialized)
struct ClaudeProcessIdentityTests {
    let box = ClaudeSandbox()

    struct Child {
        let process: ClaudeSpawnedProcess
        let identity: AgentProcessIdentity
    }

    func spawn(script: String = "while :; do sleep 1; done", marker: String = UUID().uuidString, extra: [String] = []) throws -> Child {
        let settings = box.root.appending(path: "config/\(marker).settings.json").path
        let process = try ClaudeSpawner.spawn(
            executable: "/bin/sh", arguments: ["-c", script, "sh", "--settings", settings] + extra, environment: ["PATH": "/usr/bin:/bin"], cwd: box.root.path
        )
        process.closeStandardStreams()
        return Child(process: process, identity: AgentProcessIdentity(pid: Int(process.pid), startedAt: process.startedAt, processMarker: marker))
    }

    var timing: ClaudeCodeTiming { ClaudeCodeTiming.testing }

    @Test func aLiveChildIsAliveAndItsStartTimeIsTheKernels() throws {
        let child = try spawn()
        defer { _ = ClaudeProcessInspector.forceKill(child.process) }
        #expect(ClaudeProcessInspector.liveness(child.identity) == .alive)
        let kernel = try #require(ClaudeProcessInspector.startTime(pid: child.process.pid))
        #expect(abs(kernel.timeIntervalSince(child.identity.startedAt)) < 0.001)
        // 프로세스 그룹 리더 (POSIX_SPAWN_SETPGROUP)
        #expect(getpgid(child.process.pid) == child.process.pid)
    }

    @Test func aDifferentStartTimeMeansThePIDWasReusedSoItEnded() throws {
        let child = try spawn()
        defer { _ = ClaudeProcessInspector.forceKill(child.process) }
        var other = child.identity
        other.startedAt = other.startedAt.addingTimeInterval(-0.01)
        #expect(ClaudeProcessInspector.liveness(other) == .ended(AgentExit(code: nil)))
        #expect(ClaudeProcessInspector.terminate(other, timing: timing) == .ended(AgentExit(code: nil)))
        #expect(ClaudeProcessInspector.liveness(child.identity) == .alive, "다른 정체에는 신호를 보내지 않는다")
    }

    @Test func aMissingMarkerCannotBeProvenSoNothingIsSignalled() throws {
        let child = try spawn()
        defer { _ = ClaudeProcessInspector.forceKill(child.process) }
        var other = child.identity
        other.processMarker = UUID().uuidString
        #expect(ClaudeProcessInspector.liveness(other) == .unknown)
        #expect(ClaudeProcessInspector.terminate(other, timing: timing) == .unknown)
        #expect(ClaudeProcessInspector.liveness(child.identity) == .alive)
    }

    @Test func pidsAtOrBelowOneAreNeverSignalled() {
        for pid in [0, 1, -1] {
            let identity = AgentProcessIdentity(pid: pid, startedAt: Date(), processMarker: UUID().uuidString)
            #expect(ClaudeProcessInspector.liveness(identity) == .unknown)
            #expect(ClaudeProcessInspector.terminate(identity, timing: timing) == .unknown)
            #expect(!ClaudeProcessInspector.interrupt(identity))
        }
        #expect(ClaudeProcessInspector.liveness(AgentProcessIdentity(pid: nil, startedAt: Date(), processMarker: UUID().uuidString)) == .unknown)
    }

    @Test func aGoneProcessIsEnded() async throws {
        let child = try spawn(script: "exit 0")
        _ = try await offPool { child.process.waitForExit() }
        #expect(ClaudeProcessInspector.liveness(child.identity) == .ended(AgentExit(code: nil)))
    }

    @Test func interruptSendsSIGINTOnlyAfterTheIdentityChecks() async throws {
        let child = try spawn()
        #expect(ClaudeProcessInspector.interrupt(child.identity))
        let status = try await offPool { child.process.waitForExit() }
        #expect(status.signal == SIGINT)
    }

    @Test func anOrphanThatIgnoresSIGINTIsKilledWithItsGroupAndNeverSIGTERMed() async throws {
        // SIGINT · SIGTERM을 무시하는 대본: SIGTERM을 쓰면 끝나지 않는다 → SIGKILL로 끝났다는 것이 SIGTERM 0의 증거다 (13.2 :513)
        let child = try spawn(script: "trap '' INT TERM; sleep 600 & while :; do sleep 1; done")
        try await Task.sleep(for: .milliseconds(200))
        let started = Date()
        let timing = self.timing
        let result = try await offPool { ClaudeProcessInspector.terminate(child.identity, timing: timing) }
        #expect(result == .ended(AgentExit(code: nil, signal: Int(SIGKILL))))
        #expect(Date().timeIntervalSince(started) >= timing.orphanInterruptGrace)
        // 끝내지 못했으면 시험이 직접 치운다: 가드가 꺼진 사본에서도 시험이 멈추지 않고 실패로 끝난다 (G27)
        if result != .ended(AgentExit(code: nil, signal: Int(SIGKILL))) { killpg(child.process.pid, SIGKILL) }
        let status = try await offPool { child.process.waitForExit() }
        #expect(status.signal == SIGKILL)
        // 같은 그룹의 sleep도 끝났다
        try await Task.sleep(for: .milliseconds(200))
        #expect(killpg(child.process.pid, 0) != 0)
    }

    /// 앱이 연 fd(소켓 · SQLite)는 CLOEXEC 표시가 없어도 자식에게 가지 않는다 (`POSIX_SPAWN_CLOEXEC_DEFAULT`, G25)
    @Test func anInheritableAppDescriptorDoesNotReachTheChild() async throws {
        let file = box.file("open.txt")
        let fd = open(file.path, O_RDONLY) // O_CLOEXEC 없이 연다
        #expect(fd > 2)
        defer { close(fd) }
        #expect(fcntl(fd, F_GETFD) & FD_CLOEXEC == 0)
        let process = try ClaudeSpawner.spawn(
            executable: "/bin/sh", arguments: ["-c", "if [ -e /dev/fd/\(fd) ]; then echo leaked; else echo closed; fi"], environment: ["PATH": "/usr/bin:/bin"], cwd: box.root.path
        )
        close(process.stdinFD)
        close(process.stderrFD)
        let output = try await offPool { FileHandle(fileDescriptor: process.stdoutFD, closeOnDealloc: true).readDataToEndOfFile() }
        _ = try await offPool { process.waitForExit() }
        #expect(String(decoding: output, as: UTF8.self) == "closed\n")
    }

    @Test func theProductionTimingIsTheContractTiming() {
        // SIGINT 뒤 3초 · SIGKILL 뒤 2초 (계약 2.14), 닫기 10초 (2.12), 서버 1.0초 (D3c-2 3.5), probe 5초 (2.15)
        #expect(ClaudeCodeTiming.standard == ClaudeCodeTiming(orphanInterruptGrace: 3, orphanKillGrace: 2, closeTimeout: 10, exitAfterResult: 5, drainAfterExit: 2, probeTimeout: 5, serverTimeout: 1))
    }

    @Test func theScannerFindsAnotherProcessResumingTheSession() throws {
        let id = UUID().uuidString.lowercased()
        let child = try spawn(extra: ["--resume", id])
        defer { _ = ClaudeProcessInspector.forceKill(child.process) }
        #expect(ClaudeCodeProcessScanner.hasProcess(resuming: id))
        #expect(!ClaudeCodeProcessScanner.hasProcess(resuming: UUID().uuidString.lowercased()))
        let short = UUID().uuidString.lowercased()
        let other = try spawn(extra: ["-r", short])
        defer { _ = ClaudeProcessInspector.forceKill(other.process) }
        #expect(ClaudeCodeProcessScanner.hasProcess(resuming: short))
    }
}
#endif
