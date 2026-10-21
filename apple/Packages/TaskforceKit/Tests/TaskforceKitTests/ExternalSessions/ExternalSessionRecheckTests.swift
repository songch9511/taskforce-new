#if os(macOS) && DEBUG
import Darwin
import Foundation
import Testing
@testable import TaskforceKit

extension ExternalSessionSuites {
    /// 열기 직전의 다시 확인 (F4 · 보안 검토 P3): 훑은 뒤 누가 그 세션을 쥐었는지 같은 판정(등록 파일 · argv · 같은 폴더의 claude · 최근 기록)을 그 세션 하나에만 다시 돌린다.
    /// 시험은 임시 폴더의 가짜 홈과 가짜 프로세스 사실만 쓴다
    struct ExternalSessionRecheckTests {
        typealias F = ExternalSessionFixture
        typealias W = ExternalSessionScannerTests.World

        /// 훑은 뒤에 바뀌는 프로세스 사실
        final class Facts: @unchecked Sendable {
            private let lock = NSLock()
            private var _lookups: [Int32: ExternalSessionProcessFacts.Lookup] = [:]
            private var _argv: Set<String>? = []
            private var _folders: Set<String>? = []
            var lookups: [Int32: ExternalSessionProcessFacts.Lookup] {
                get { lock.withLock { _lookups } }
                set { lock.withLock { _lookups = newValue } }
            }
            var argv: Set<String>? {
                get { lock.withLock { _argv } }
                set { lock.withLock { _argv = newValue } }
            }
            var folders: Set<String>? {
                get { lock.withLock { _folders } }
                set { lock.withLock { _folders = newValue } }
            }
            var facts: ExternalSessionProcessFacts {
                ExternalSessionProcessFacts(userID: getuid(), lookup: { self.lookups[$0] ?? .gone }, argumentSessionIDs: { _ in self.argv }, unregisteredClaudeFolders: { _, _ in self.folders })
            }
        }

        private func withWorld<T>(_ body: (W) async throws -> T) async throws -> T {
            let home = try ExternalHome()
            defer { home.cleanup() }
            return try await body(W(home: home))
        }

        private func registry(_ world: W, pid: Int, id: Int, entrypoint: String, cwd: String? = nil, facts: Facts) throws {
            try world.home.registry(pid: pid, json: F.json(["pid": pid, "sessionId": F.uuid(id), "cwd": cwd ?? world.cwd, "entrypoint": entrypoint, "kind": "interactive"]))
            facts.lookups[Int32(pid)] = .present(start: Date(), uid: getuid())
        }

        @Test func aSessionNobodyHoldsStaysAvailable() async throws {
            try await withWorld { world in
                try world.session(1, entrypoint: "claude-desktop")
                let facts = Facts()
                let scanner = world.scanner(facts: facts.facts)
                _ = await scanner.scan()
                #expect(await scanner.recheck(id: F.uuid(1)) == .available)
            }
        }

        @Test func aHolderThatAppearedSinceTheScanIsSeen() async throws {
            try await withWorld { world in
                try world.session(1, entrypoint: "claude-desktop")
                try world.session(2, entrypoint: "claude-desktop")
                try world.session(3, entrypoint: "claude-desktop")
                try world.session(4, entrypoint: "claude-desktop")
                let facts = Facts()
                let scanner = world.scanner(facts: facts.facts)
                let scan = await scanner.scan()
                #expect(scan.rows.allSatisfy { $0.status == .available })
                // 훑은 뒤: 1은 터미널이, 2는 데스크톱 앱이, 3은 argv로, 4는 같은 폴더의 등록 안 된 claude가
                try registry(world, pid: 4001, id: 1, entrypoint: "cli", facts: facts)
                try registry(world, pid: 4002, id: 2, entrypoint: "claude-desktop", facts: facts)
                facts.argv = [F.uuid(3)]
                facts.folders = [world.cwd]
                #expect(await scanner.recheck(id: F.uuid(1)) == .held(.terminal))
                #expect(await scanner.recheck(id: F.uuid(2)) == .held(.claudeApp))
                #expect(await scanner.recheck(id: F.uuid(3)) == .held(.terminal), "argv의 --resume")
                facts.argv = []
                #expect(await scanner.recheck(id: F.uuid(4)) == .held(.unknown), "같은 폴더의 등록 안 된 claude")
            }
        }

        @Test func aTranscriptWrittenSinceTheScanCountsAsHeld() async throws {
            try await withWorld { world in
                let path = try world.session(1, entrypoint: "claude-desktop")
                let facts = Facts()
                let scanner = world.scanner(facts: facts.facts)
                _ = await scanner.scan()
                #expect(await scanner.recheck(id: F.uuid(1)) == .available)
                // 스캐너의 시계는 `ExternalSessionScannerTests.now`: 그보다 5초 전에 쓰였다
                try world.home.setModified(path, ExternalSessionScannerTests.now.addingTimeInterval(-5))
                #expect(await scanner.recheck(id: F.uuid(1)) == .held(.unknown), "최근 기록")
            }
        }

        @Test func aSessionTaskforceAlreadyTookOverIsNotFree() async throws {
            try await withWorld { world in
                try world.session(1, entrypoint: "claude-desktop")
                let facts = Facts()
                let scanner = world.scanner(facts: facts.facts, attached: [F.uuid(1)])
                _ = await scanner.scan()
                #expect(await scanner.recheck(id: F.uuid(1)) == .inTaskforce, "이미 이어받은 세션에는 두 번째 writer를 만들지 않는다")
            }
        }

        @Test func anUnreadableSignalFailsClosed() async throws {
            try await withWorld { world in
                try world.session(1, entrypoint: "claude-desktop")
                let facts = Facts()
                let scanner = world.scanner(facts: facts.facts)
                _ = await scanner.scan()
                facts.argv = nil
                #expect(await scanner.recheck(id: F.uuid(1)) == .couldNotCheck, "argv를 못 읽으면 쥔 곳이 없다고 하지 않는다")
                facts.argv = []
                facts.folders = nil
                #expect(await scanner.recheck(id: F.uuid(1)) == .couldNotCheck)
            }
        }

        @Test func aRegistryWithAnotherFolderIsAMismatchNotAFreeSession() async throws {
            try await withWorld { world in
                try world.session(1, entrypoint: "claude-desktop")
                let facts = Facts()
                let scanner = world.scanner(facts: facts.facts)
                _ = await scanner.scan()
                try registry(world, pid: 4001, id: 1, entrypoint: "claude-desktop", cwd: world.home.home + "/elsewhere", facts: facts)
                #expect(await scanner.recheck(id: F.uuid(1)) == .cannotResume(.unreadable))
            }
        }

        /// 보안 재검토 P3: 훑기가 목록에서 뺀 세션(Taskforce가 띄운 것 · SDK 실행 · 앱 데이터 폴더 안)은 다시 확인도 하지 않는다 (nil = 모른다: 부른 쪽이 막는다).
        /// 훑은 뒤에 바뀔 수 있는 것은 Taskforce가 띄운 세션 목록뿐이고, 나머지는 캐시에 남은 기록 머리(entrypoint · cwd)로 같은 규칙을 다시 적용한다
        @Test func aSessionTaskforceStartedSinceTheScanIsNotRechecked() async throws {
            final class Started: @unchecked Sendable {
                private let lock = NSLock()
                private var _ids: Set<String> = []
                var ids: Set<String> {
                    get { lock.withLock { _ids } }
                    set { lock.withLock { _ids = newValue } }
                }
            }
            try await withWorld { world in
                try world.session(1, entrypoint: "claude-desktop")
                let started = Started()
                let scanner = world.scanner(facts: Facts().facts, tweak: { $0.taskforceSessionIDs = { started.ids } })
                let scan = await scanner.scan()
                #expect(scan.rows.map(\.id) == [F.uuid(1)])
                #expect(await scanner.recheck(id: F.uuid(1)) == .available)
                started.ids = [F.uuid(1)]
                #expect(await scanner.recheck(id: F.uuid(1)) == nil, "그 사이 Taskforce가 띄운 세션이다: 외부 세션이 아니다")
            }
        }

        @Test func anSDKRunIsNotRechecked() async throws {
            try await withWorld { world in
                try world.session(1, entrypoint: "sdk-cli")
                try world.session(2, entrypoint: "sdk-ts")
                try world.session(3, entrypoint: "claude-desktop")
                let scanner = world.scanner(facts: Facts().facts)
                let scan = await scanner.scan()
                #expect(scan.rows.map(\.id) == [F.uuid(3)], "SDK 실행은 목록에 없다")
                #expect(await scanner.recheck(id: F.uuid(1)) == nil)
                #expect(await scanner.recheck(id: F.uuid(2)) == nil)
                #expect(await scanner.recheck(id: F.uuid(3)) == .available)
            }
        }

        @Test func aSessionInsideAProtectedFolderIsNotRechecked() async throws {
            try await withWorld { world in
                try world.session(1, entrypoint: "claude-desktop")
                let other = world.home.home + "/other"
                try world.session(2, cwd: other, entrypoint: "claude-desktop")
                // 앱 데이터 · bridge 폴더: 그 안이 cwd인 세션은 Taskforce가 띄운 것이라 목록에서 빠진다
                let scanner = world.scanner(facts: Facts().facts, protected: [world.cwd])
                let scan = await scanner.scan()
                #expect(scan.rows.map(\.id) == [F.uuid(2)], "보호 폴더 안의 세션은 목록에 없다")
                #expect(await scanner.recheck(id: F.uuid(1)) == nil)
                #expect(await scanner.recheck(id: F.uuid(2)) == .available)
            }
        }

        @Test func aSessionTheLastScanNeverSawOrWhoseTranscriptIsGoneIsUnknown() async throws {
            try await withWorld { world in
                let path = try world.session(1, entrypoint: "claude-desktop")
                let facts = Facts()
                let scanner = world.scanner(facts: facts.facts)
                #expect(await scanner.recheck(id: F.uuid(1)) == nil, "훑기 전에는 모른다")
                _ = await scanner.scan()
                #expect(await scanner.recheck(id: F.uuid(99)) == nil, "훑은 적 없는 id")
                try FileManager.default.removeItem(atPath: path)
                #expect(await scanner.recheck(id: F.uuid(1)) == nil, "기록이 사라졌다")
            }
        }

        /// 파일 시스템을 만진 이름을 적는다
        final class Touch: @unchecked Sendable {
            private let lock = NSLock()
            private var _stats: [String] = []
            private var _reads: [String] = []
            var stats: [String] { lock.withLock { _stats } }
            var reads: [String] { lock.withLock { _reads } }
            func reset() { lock.withLock { _stats = []; _reads = [] } }
            func stat(_ path: String) { lock.withLock { _stats.append(path) } }
            func read(_ path: String) { lock.withLock { _reads.append(path) } }
        }

        private func recording(_ touch: Touch) -> ExternalSessionFileSystem {
            let live = ExternalSessionFileSystem.live
            return ExternalSessionFileSystem(
                userID: live.userID, realpath: live.realpath, lstat: { touch.stat($0); return live.lstat($0) }, list: live.list,
                read: { touch.read($0); return live.read($0, $1, $2) }
            )
        }

        @Test func recheckLooksOnlyAtThatSessionsTranscriptTimeAndNeverReadsItsContent() async throws {
            try await withWorld { world in
                try world.session(1, entrypoint: "claude-desktop")
                try world.session(2, entrypoint: "claude-desktop")
                let touch = Touch()
                let scanner = world.scanner(fileSystem: recording(touch), facts: Facts().facts)
                _ = await scanner.scan()
                touch.reset()
                _ = await scanner.recheck(id: F.uuid(1))
                #expect(!touch.stats.contains { $0.contains(F.uuid(2)) } && !touch.reads.contains { $0.contains(F.uuid(2)) }, "다른 세션의 기록은 건드리지 않는다")
                #expect(!touch.reads.contains { $0.hasSuffix(".jsonl") }, "기록을 열어 읽지 않는다 (시각만 본다)")
                #expect(touch.stats.contains { $0.contains(F.uuid(1)) }, "그 세션의 기록 시각은 본다")
            }
        }
    }
}
#endif
