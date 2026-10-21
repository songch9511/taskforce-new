#if os(macOS) && DEBUG
import Darwin
import Foundation
import Testing
@testable import TaskforceKit

extension ExternalSessionSuites {
    /// 불투명 id 열쇠 (계약 17장 D1): 서버는 Claude 세션 UUID를 보지 못한다
    struct ExternalSessionKeyTests {
        typealias F = ExternalSessionFixture

        @Test func theRefIsAStableHexHMACThatDoesNotContainTheSessionID() {
            let key = ExternalSessionKey(bytes: Data(repeating: 7, count: 32))
            let id = F.uuid(1)
            let ref = key.ref(forSessionID: id)
            #expect(ref.count == 64)
            #expect(ref.utf8.allSatisfy { ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x61 && $0 <= 0x66) })
            #expect(ref == key.ref(forSessionID: id), "같은 열쇠 · 같은 id는 같은 값")
            #expect(ref == key.ref(forSessionID: id.uppercased()), "대소문자를 접는다")
            #expect(ref != key.ref(forSessionID: F.uuid(2)))
            #expect(!ref.contains(id.replacingOccurrences(of: "-", with: "")))
            #expect(!ref.contains("5e5e5e5e"))
        }

        @Test func aDifferentKeyGivesDifferentRefsSoTheServerCannotLinkMacs() {
            let a = ExternalSessionKey(bytes: Data(repeating: 1, count: 32))
            let b = ExternalSessionKey(bytes: Data(repeating: 2, count: 32))
            #expect(a.ref(forSessionID: F.uuid(1)) != b.ref(forSessionID: F.uuid(1)))
        }

        @Test func theRefMatchesAnIndependentlyComputedHMACSHA256Vector() {
            // openssl · python hmac으로 따로 계산한 값: HMAC-SHA256(key = 0x0b x 32, "tf-external-session-v1\n<uuid>")
            let key = ExternalSessionKey(bytes: Data(repeating: 0x0b, count: 32))
            #expect(key.ref(forSessionID: "00000000-0000-0000-0000-000000000000") == "b42193f7e1e3b5af74547efe4dc22eab1049d5f8de7631e72f771571098307f0")
        }

        @Test func theFileStoreCreatesA0600KeyOnceAndReadsItBack() throws {
            let home = try ExternalHome()
            defer { home.cleanup() }
            let store = FileExternalSessionKeyStore(directory: URL(fileURLWithPath: home.root + "/partition"))
            let first = try store.loadOrCreate()
            let second = try store.loadOrCreate()
            #expect(first.ref(forSessionID: F.uuid(1)) == second.ref(forSessionID: F.uuid(1)))
            let path = home.root + "/partition/" + FileExternalSessionKeyStore.fileName
            var info = stat()
            #expect(lstat(path, &info) == 0)
            #expect(info.st_mode & 0o777 == 0o600)
            #expect(info.st_uid == getuid())
            let reopened = try FileExternalSessionKeyStore(directory: URL(fileURLWithPath: home.root + "/partition")).loadOrCreate()
            #expect(reopened.ref(forSessionID: F.uuid(1)) == first.ref(forSessionID: F.uuid(1)))
        }

        @Test func aLooseCorruptOrLinkedKeyFileIsReplaced() throws {
            let home = try ExternalHome()
            defer { home.cleanup() }
            let dir = home.root + "/partition"
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            let path = dir + "/" + FileExternalSessionKeyStore.fileName
            let store = FileExternalSessionKeyStore(directory: URL(fileURLWithPath: dir))
            let original = try store.loadOrCreate().ref(forSessionID: F.uuid(1))
            // 권한이 느슨하다: 다른 사용자가 읽었을 수 있으니 새로 만든다
            chmod(path, 0o644)
            let afterLoose = try store.loadOrCreate().ref(forSessionID: F.uuid(1))
            #expect(afterLoose != original)
            // 깨졌다
            try "not a key".write(toFile: path, atomically: false, encoding: .utf8)
            chmod(path, 0o600)
            let afterCorrupt = try store.loadOrCreate().ref(forSessionID: F.uuid(1))
            #expect(afterCorrupt != afterLoose)
            // 기호 링크: 따라가지 않고 지운 뒤 새로 만든다 (링크 대상은 건드리지 않는다)
            let target = home.root + "/target.txt"
            try "TARGET".write(toFile: target, atomically: false, encoding: .utf8)
            unlink(path)
            try home.link(path, to: target)
            _ = try store.loadOrCreate()
            #expect(try String(contentsOfFile: target, encoding: .utf8) == "TARGET")
            var info = stat()
            #expect(lstat(path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFREG)
        }

        @Test func deleteRemovesTheKeyAndTheNextLoadMakesANewOne() throws {
            let home = try ExternalHome()
            defer { home.cleanup() }
            let store = FileExternalSessionKeyStore(directory: URL(fileURLWithPath: home.root + "/partition"))
            let first = try store.loadOrCreate().ref(forSessionID: F.uuid(1))
            store.delete()
            #expect(!FileManager.default.fileExists(atPath: home.root + "/partition/" + FileExternalSessionKeyStore.fileName))
            #expect(try store.loadOrCreate().ref(forSessionID: F.uuid(1)) != first)
        }

        // MARK: 로그아웃 정리 (`SessionStore.onSigningOut`): 서버 목록을 비운 뒤 열쇠를 지운다

        private final class Events: @unchecked Sendable {
            private let lock = NSLock()
            private var items: [String] = []
            func add(_ item: String) { lock.withLock { items.append(item) } }
            var all: [String] { lock.withLock { items } }
        }

        private final class OrderedKeyStore: ExternalSessionKeyStore, @unchecked Sendable {
            let events: Events
            init(_ events: Events) { self.events = events }
            func loadOrCreate() throws -> ExternalSessionKey { ExternalSessionKey.random() }
            func delete() { events.add("delete-key") }
        }

        @Test func signingOutClearsTheServerListFirstAndThenDeletesTheKey() async {
            let events = Events()
            let bridge = UUID()
            let reporter = ExternalSessionReporter(send: { id, rows in events.add("clear \(id == bridge) \(rows.count)") })
            await ExternalSessionSignOut.run(bridgeID: bridge, reporter: reporter, keyStore: OrderedKeyStore(events))
            #expect(events.all == ["clear true 0", "delete-key"], "먼저 빈 목록을 올리고(옛 토큰이 유효한 동안) 그 뒤에 열쇠를 지운다")
        }

        @Test func theKeyIsDeletedEvenIfTheServerCannotBeReached() async {
            let events = Events()
            let reporter = ExternalSessionReporter(send: { _, _ in
                events.add("clear")
                throw URLError(.notConnectedToInternet)
            })
            await ExternalSessionSignOut.run(bridgeID: UUID(), reporter: reporter, keyStore: OrderedKeyStore(events))
            #expect(events.all == ["clear", "delete-key"], "오프라인이어도 로그아웃은 가고 열쇠는 지워진다 (남은 서버 행은 열쇠를 잃어 이 Mac과 이어지지 않고 14일 뒤 지워진다)")
        }

        @Test func withoutARegisteredBridgeOnlyTheKeyIsDeleted() async {
            let events = Events()
            let reporter = ExternalSessionReporter(send: { _, _ in events.add("clear") })
            await ExternalSessionSignOut.run(bridgeID: nil, reporter: reporter, keyStore: OrderedKeyStore(events))
            #expect(events.all == ["delete-key"])
            await ExternalSessionSignOut.run(bridgeID: UUID(), reporter: reporter, keyStore: nil)
            #expect(events.all == ["delete-key", "clear"], "열쇠 저장소를 모르면 비우기만")
        }

        @Test func aFileKeyDeletedAtSignOutGivesTheNextSignInANewKey() async throws {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("tf-key-\(UUID().uuidString.lowercased())", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let store = FileExternalSessionKeyStore(directory: directory)
            let before = try store.loadOrCreate().ref(forSessionID: F.uuid(1))
            await ExternalSessionSignOut.run(bridgeID: nil, reporter: ExternalSessionReporter(send: { _, _ in }), keyStore: store)
            #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent(FileExternalSessionKeyStore.fileName).path))
            let after = try store.loadOrCreate().ref(forSessionID: F.uuid(1))
            #expect(before != after)
        }

        @Test func aStoreThatCannotWriteThrowsSoNothingIsSent() throws {
            let home = try ExternalHome()
            defer { home.cleanup() }
            let blocker = home.root + "/blocker"
            try "file, not a folder".write(toFile: blocker, atomically: false, encoding: .utf8)
            #expect(throws: (any Error).self) { try FileExternalSessionKeyStore(directory: URL(fileURLWithPath: blocker + "/partition")).loadOrCreate() }
        }
    }
}
#endif
