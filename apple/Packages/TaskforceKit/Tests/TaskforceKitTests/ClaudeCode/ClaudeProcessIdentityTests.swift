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

    /// spawn marker 환경 변수(9장 4)를 실제 adapter처럼 넣는다: 자손이 물려받는다
    func spawn(script: String = "while :; do sleep 1; done", marker: String = UUID().uuidString, extra: [String] = []) throws -> Child {
        let settings = box.root.appending(path: "config/\(marker).settings.json").path
        let process = try ClaudeSpawner.spawn(
            executable: "/bin/sh", arguments: ["-c", script, "sh", "--settings", settings] + extra,
            environment: ["PATH": "/usr/bin:/bin", ClaudeProcessInspector.markerKey: marker], cwd: box.root.path
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

    /// 부모만 끝나고 같은 그룹의 자손이 남으면 아직 끝이 아니다 (8장 13, A6): 그룹을 SIGKILL로 끝낸 뒤에만 `.ended`
    @Test func a13TerminateEndsTheGroupNotJustTheParent() async throws {
        // 부모는 SIGINT에 끝나고(trap), 백그라운드 자식은 신호를 받지 않아 남는다
        let child = try spawn(script: "trap 'exit 0' INT; sleep 600 & while :; do sleep 0.2; done")
        let group = child.process.pid
        defer { killpg(group, SIGKILL) }
        try await Task.sleep(for: .milliseconds(300))
        let timing = self.timing
        let result = try await offPool { ClaudeProcessInspector.terminate(child.identity, timing: timing) }
        #expect(result == .ended(AgentExit(code: nil, signal: Int(SIGKILL))))
        _ = try await offPool { child.process.waitForExit() }
        let deadline = Date().addingTimeInterval(2)
        while killpg(group, 0) == 0, Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        #expect(killpg(group, 0) != 0, "그룹에 남은 것 0")
    }

    /// 부모가 이미 없어도 그 그룹의 자손이 살아 있으면 살아 있다 (고아 확인이 끝났다고 하지 않는다)
    @Test func a13ADeadParentWithLiveDescendantsIsStillAlive() async throws {
        let child = try spawn(script: "sleep 600 & exit 0")
        let group = child.process.pid
        defer { killpg(group, SIGKILL) }
        _ = try await offPool { child.process.waitForExit() }
        #expect(ClaudeProcessInspector.liveness(child.identity) == .alive)
        let timing = self.timing
        #expect(try await offPool { ClaudeProcessInspector.terminate(child.identity, timing: timing) } == .ended(AgentExit(code: nil, signal: Int(SIGKILL))))
        #expect(ClaudeProcessInspector.liveness(child.identity) == .ended(AgentExit(code: nil)))
    }

    /// 세션을 떠난(setsid) 자손은 그룹 밖이다: 혈통(만들 때의 부모 id)으로 찾아 끝낸 뒤에만 `.ended` (9장 4 정정). 부모가 이미 없어도 그 자손이 살아 있으면 `alive`
    @Test func b4ASetsidDescendantIsFoundByItsLineageAndEnded() async throws {
        let pidFile = box.root.appending(path: "detached.pid").path
        let perl = "use POSIX; POSIX::setsid(); $SIG{INT} = q(IGNORE); sleep 600;"
        let child = try spawn(script: "trap 'exit 0' INT; /usr/bin/perl -e '\(perl)' & echo $! > '\(pidFile)'; while :; do sleep 0.2; done")
        defer { killpg(child.process.pid, SIGKILL) }
        var detached: pid_t = 0
        for _ in 0..<100 {
            if let text = try? String(contentsOfFile: pidFile, encoding: .utf8), let value = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)) { detached = value; break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(detached > 0)
        defer { kill(detached, SIGKILL) }
        try await Task.sleep(for: .milliseconds(200))
        #expect(getsid(detached) == detached, "세션을 떠났다")
        let timing = self.timing
        let result = try await offPool { ClaudeProcessInspector.terminate(child.identity, timing: timing) }
        #expect(result == .ended(AgentExit(code: nil, signal: Int(SIGKILL))))
        let deadline = Date().addingTimeInterval(2)
        while kill(detached, 0) == 0, Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        #expect(kill(detached, 0) != 0, "혈통으로 찾은 자손을 끝냈다")
    }

    /// adapter처럼 띄운 직후 혈통의 뿌리를 적으면, 부모가 끝나 launchd로 옮겨진 setsid 자손도 찾는다 (자손이 exec한 뒤에 부모가 끝난다)
    @Test func b4ADeadParentWithALiveSetsidDescendantIsAlive() async throws {
        let pidFile = box.root.appending(path: "orphan.pid").path
        let child = try spawn(script: "/usr/bin/perl -e 'use POSIX; POSIX::setsid(); open(F, q(>\(pidFile))); print F $$; close F; sleep 600;' & sleep 0.3; exit 0")
        let lineage = ClaudeLineage()
        lineage.seed(child.process.pid)
        _ = try await offPool { child.process.waitForExit() }
        let detached = try await Self.readPID(pidFile)
        defer { kill(detached, SIGKILL) }
        #expect(ClaudeProcessInspector.liveness(child.identity, lineage: lineage) == .alive)
        let timing = self.timing
        let result = try await offPool { ClaudeProcessInspector.terminate(child.identity, timing: timing, lineage: lineage) }
        guard case .ended = result else {
            Issue.record("\(result)")
            return
        }
        #expect(await Self.vanished(detached))
        #expect(ClaudeProcessInspector.liveness(child.identity, lineage: lineage) == .ended(AgentExit(code: nil)))
    }

    /// 자식을 만들고 곧 끝나는 중간 프로세스: 지켜보기(`watch`)가 살아 있을 때 보아 두면, 그 setsid 손자를 부모들이 다 끝난 뒤에도 찾는다
    @Test func b4AWatchedLineageFindsTheGrandchildOfAShortLivedIntermediate() async throws {
        let pidFile = box.root.appending(path: "grandchild.pid").path
        // 중간 셸: setsid 손자를 띄우고 0.2초 뒤 끝난다
        let intermediate = box.file("intermediate.sh", "/usr/bin/perl -e 'use POSIX; POSIX::setsid(); open(F, q(>\(pidFile))); print F $$; close F; sleep 600;' &\nsleep 0.2\n")
        let child = try spawn(script: "sleep 0.3; /bin/sh '\(intermediate.path)'; exit 0")
        let lineage = ClaudeLineage()
        lineage.seed(child.process.pid)
        lineage.watch(child.identity)
        defer { lineage.forget() }
        _ = try await offPool { child.process.waitForExit() }
        let grandchild = try await Self.readPID(pidFile)
        defer { kill(grandchild, SIGKILL) }
        let timing = self.timing
        #expect(ClaudeProcessInspector.liveness(child.identity, lineage: lineage) == .alive, "중간 셸은 끝났고 손자는 launchd 밑에 있다")
        // 셸의 백그라운드 명령은 SIGINT를 무시한 채 뜬다 (job control 없음): SIGKILL까지 간다
        let result = try await offPool { ClaudeProcessInspector.terminate(child.identity, timing: timing, lineage: lineage) }
        #expect(result == .ended(AgentExit(code: nil, signal: Int(SIGKILL))))
        #expect(await Self.vanished(grandchild))
    }

    /// 부모가 끝난 뒤에 exec한 자식은 부모 id가 launchd(1)가 된다: 그 전에 본 자기 id로 찾는다
    @Test func b4AChildThatExecsAfterItsParentEndedIsKnownByItsOwnID() async throws {
        let pidFile = box.root.appending(path: "late-exec.pid").path
        let late = box.file("late.pl", "use POSIX; POSIX::setsid(); open(F, q(>\(pidFile))); print F $$; close F; sleep 600;")
        // 중간(perl): 자식을 만들고 0.3초 뒤 끝난다. 자식은 0.8초 뒤에 exec한다
        let child = try spawn(script: "/usr/bin/perl -e 'if (fork() == 0) { select(undef, undef, undef, 0.8); exec(q(/usr/bin/perl), q(\(late.path))); } select(undef, undef, undef, 0.3);'; exit 0")
        let lineage = ClaudeLineage()
        lineage.seed(child.process.pid)
        lineage.watch(child.identity)
        defer { lineage.forget() }
        _ = try await offPool { child.process.waitForExit() }
        let orphan = try await Self.readPID(pidFile)
        defer { kill(orphan, SIGKILL) }
        #expect(ClaudeProcessInspector.uniqueIDs(pid: orphan)?.parent == 1, "부모가 끝난 뒤 exec")
        #expect(ClaudeProcessInspector.liveness(child.identity, lineage: lineage) == .alive)
        let timing = self.timing
        let result = try await offPool { ClaudeProcessInspector.terminate(child.identity, timing: timing, lineage: lineage) }
        guard case .ended = result else {
            Issue.record("\(result)")
            return
        }
        #expect(await Self.vanished(orphan))
    }

    /// 다시 뜬 앱: CLI는 이미 끝났고 그 setsid 자손만 남았다. 혈통 파일(감독하던 앱이 적은 것)로만 찾을 수 있다 → 끝내고 파일을 지운다
    @Test func b4ARestartedAdapterFindsTheOrphanOfAnEndedCLIThroughTheLineageFile() async throws {
        let pidFile = box.root.appending(path: "restart.pid").path
        let marker = UUID().uuidString
        let child = try spawn(script: "/usr/bin/perl -e 'use POSIX; POSIX::setsid(); open(F, q(>\(pidFile))); print F $$; close F; sleep 600;' & sleep 0.3; exit 0", marker: marker)
        let file = box.sessionsRoot.appending(path: "lineage/\(marker).lineage")
        let before = ClaudeLineage(file: file)
        before.seed(child.process.pid)
        before.save()
        _ = try await offPool { child.process.waitForExit() }
        let orphan = try await Self.readPID(pidFile)
        defer { kill(orphan, SIGKILL) }
        let restarted = ClaudeCodeProcess(sessionsRoot: box.sessionsRoot, hookServer: nil, helpers: ClaudeCodeHelpers(hook: "/x", mcp: "/y"),
                                          locator: ClaudeCodeLocator(candidates: [], confinedTo: box.root.path), timing: .testing)
        #expect(await restarted.liveness(child.identity) == .alive, "부모는 끝났지만 파일의 혈통으로 자손을 본다")
        let ended = await restarted.terminateOrphan(child.identity)
        guard case .ended = ended else {
            Issue.record("\(ended)")
            return
        }
        #expect(await Self.vanished(orphan))
        #expect(!FileManager.default.fileExists(atPath: file.path), "끝을 증명한 뒤 파일을 지웠다")
        #expect(await restarted.liveness(child.identity) == .ended(AgentExit(code: nil)))
    }

    /// 혈통 파일: 다시 뜬 앱이 읽는다. 이번 부팅에 적힌 숫자 줄만 받는다 (다른 부팅 · 이상한 줄은 버린다)
    @Test func b4TheLineageFileIsReadOnlyForThisBootAndOnlyAsNumbers() throws {
        let file = box.root.appending(path: "lineage/x.lineage")
        let lineage = ClaudeLineage(file: file)
        lineage.insert(4242)
        lineage.insert(77)
        lineage.save()
        let text = try String(contentsOf: file, encoding: .utf8)
        let boot = try #require(ClaudeProcessInspector.bootTime())
        #expect(text == "taskforce-lineage 1\n\(ClaudeLineage.stamp(boot))\n77\n4242\n")
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        #expect(ClaudeLineage(file: file).contains(4242))
        try "taskforce-lineage 1\nboot 1\n4242\n".write(to: file, atomically: true, encoding: .utf8)
        #expect(!ClaudeLineage(file: file).contains(4242), "다른 부팅")
        try "taskforce-lineage 1\n\(ClaudeLineage.stamp(boot))\n4242\n-1\n".write(to: file, atomically: true, encoding: .utf8)
        #expect(!ClaudeLineage(file: file).contains(4242), "숫자가 아닌 줄")
        lineage.forget()
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    /// 커널 id: exec까지 마친 자식의 부모 id는 부모가 끝나 launchd로 옮겨진 뒤에도 그대로다 (혈통의 바탕)
    @Test func b4AnOrphansParentIDStaysTheIDOfItsOriginalParent() async throws {
        let pidFile = box.root.appending(path: "kept.pid").path
        let child = try spawn(script: "/usr/bin/perl -e 'open(F, q(>\(pidFile))); print F $$; close F; sleep 600;' & sleep 0.3; exit 0")
        let parent = try #require(ClaudeProcessInspector.uniqueIDs(pid: child.process.pid))
        _ = try await offPool { child.process.waitForExit() }
        let orphan = try await Self.readPID(pidFile)
        defer { kill(orphan, SIGKILL) }
        #expect(ClaudeProcessInspector.uniqueIDs(pid: orphan)?.parent == parent.own)
        #expect(ClaudeProcessInspector.uniqueIDs(pid: getpid())?.own != parent.own)
    }

    /// 그 pid가 사라졌다 (launchd가 좀비를 거둘 때까지 2초 기다린다)
    static func vanished(_ pid: pid_t) async -> Bool {
        let deadline = Date().addingTimeInterval(2)
        while kill(pid, 0) == 0, Date() < deadline { try? await Task.sleep(for: .milliseconds(20)) }
        return kill(pid, 0) != 0
    }

    /// 파일에 적힌 pid를 읽는다 (자식이 적을 때까지 기다린다)
    static func readPID(_ path: String) async throws -> pid_t {
        for _ in 0..<250 {
            if let text = try? String(contentsOfFile: path, encoding: .utf8), let value = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)), value > 1 { return value }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw CancellationError()
    }

    /// 확인한 pid에만 신호 (9장 5): 시작 시각이 다르면 그 pid를 다른 프로세스가 쓰는 것이다
    @Test func b5OnlyVerifiedProcessesAreSignalled() async throws {
        let child = try spawn()
        defer { _ = ClaudeProcessInspector.forceKill(child.process) }
        let wrong = ClaudeProcessInspector.Member(pid: child.process.pid, start: child.identity.startedAt.addingTimeInterval(-1))
        ClaudeProcessInspector.signalVerified([wrong], SIGKILL)
        try await Task.sleep(for: .milliseconds(200))
        #expect(ClaudeProcessInspector.liveness(child.identity) == .alive, "시작 시각이 다르면 신호 0")
        let right = ClaudeProcessInspector.Member(pid: child.process.pid, start: child.identity.startedAt)
        ClaudeProcessInspector.signalVerified([right], SIGKILL)
        let status = try await offPool { child.process.waitForExit() }
        #expect(status.signal == SIGKILL)
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
