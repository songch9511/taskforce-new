#if os(macOS) && DEBUG
import Darwin
import Foundation
import Testing
@testable import TaskforceKit

/// 이어받기 상태 쓰기 (OA 외부 세션 PR2m, 계약 6.1-4 · 20장 1 · 3): `state.json`의 `origin: attached` · `bound = true`는 **로컬 Resume here 확인에서만** 쓰고,
/// 이미 묶인 폴더를 다른 Claude id로 덮지 않는다. 가짜 임시 폴더만 쓴다
struct ExternalSessionAttachStateTests {
    private let id = "5e5e5e5e-0000-4000-8000-0000000000a1"
    private let other = "5e5e5e5e-0000-4000-8000-0000000000b2"
    private let at = Date(timeIntervalSince1970: 1_800_000_000.123)

    private func folder() -> TempDirectory { TempDirectory() }

    @Test func aFreshFolderGetsTheBoundAttachedState() {
        let temp = folder()
        #expect(ClaudeSessionState.writeAttached(providerSessionID: id, at: at, in: temp.url) == .written)
        let state = ClaudeSessionState.load(from: temp.url)
        #expect(state.bound && state.providerSessionID == id && state.origin == .attached)
        #expect(state.attachedAt.map { abs($0.timeIntervalSince(at)) < 0.001 } == true, "밀리초까지 같다")
        #expect(state.openDeferred == nil && !state.secretAnswered)
    }

    @Test func theStateFileIsPrivate() throws {
        let temp = folder()
        _ = ClaudeSessionState.writeAttached(providerSessionID: id, at: at, in: temp.url)
        let info = try FileManager.default.attributesOfItem(atPath: temp.appending("state.json").path)
        #expect((info[.posixPermissions] as? Int) == 0o600)
    }

    @Test func aStateWrittenByTheAdapterKeepsTheOriginAndTheTime() throws {
        let temp = folder()
        _ = ClaudeSessionState.writeAttached(providerSessionID: id, at: at, in: temp.url)
        // 어댑터의 다른 쓰기(보류를 열고 닫는다)는 불러온 값을 그대로 다시 쓴다: 출처 · 시각이 지워지지 않는다
        var state = ClaudeSessionState.load(from: temp.url)
        state.openDeferred = ClaudeSessionState.OpenDeferred(id: "toolu_q", kind: "input", inputSHA256: "d", spawnID: UUID().uuidString, at: Date())
        try state.save(in: temp.url)
        state.openDeferred = nil
        try state.save(in: temp.url)
        let again = ClaudeSessionState.load(from: temp.url)
        #expect(again.origin == .attached && again.bound && again.providerSessionID == id)
        #expect(again.attachedAt.map { abs($0.timeIntervalSince(at)) < 0.001 } == true)
    }

    @Test func aStateThatIsNotAttachedKeepsTheOldFileShape() throws {
        let temp = folder()
        var state = ClaudeSessionState()
        state.providerSessionID = id
        state.bound = true
        try state.save(in: temp.url)
        let object = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: temp.appending("state.json"))) as? [String: Any])
        #expect(object["origin"] == nil && object["attached_at"] == nil, "Taskforce가 시작한 세션의 파일에는 새 칸이 없다")
        #expect(ClaudeSessionState.load(from: temp.url).origin == nil)
    }

    @Test func aBoundFolderIsNeverOverwrittenWithADifferentId() {
        let temp = folder()
        _ = ClaudeSessionState.writeAttached(providerSessionID: id, at: at, in: temp.url)
        #expect(ClaudeSessionState.writeAttached(providerSessionID: other, at: at.addingTimeInterval(60), in: temp.url) == .refused)
        let state = ClaudeSessionState.load(from: temp.url)
        #expect(state.providerSessionID == id && state.attachedAt.map { abs($0.timeIntervalSince(at)) < 0.001 } == true, "처음 값 그대로")
    }

    @Test func theSameIdIsIdempotentAndKeepsTheFirstTime() {
        let temp = folder()
        _ = ClaudeSessionState.writeAttached(providerSessionID: id, at: at, in: temp.url)
        #expect(ClaudeSessionState.writeAttached(providerSessionID: id, at: at.addingTimeInterval(500), in: temp.url) == .alreadyAttached)
        #expect(ClaudeSessionState.load(from: temp.url).attachedAt.map { abs($0.timeIntervalSince(at)) < 0.001 } == true, "다시 눌러도 시각이 뒤로 가지 않는다")
    }

    @Test func aTaskforceStartedSessionWithTheSameIdIsNotTurnedIntoAnAttachedOne() throws {
        let temp = folder()
        var state = ClaudeSessionState()
        state.providerSessionID = id
        state.bound = true
        try state.save(in: temp.url)
        #expect(ClaudeSessionState.writeAttached(providerSessionID: id, at: at, in: temp.url) == .refused)
        #expect(ClaudeSessionState.load(from: temp.url).origin == nil)
    }

    @Test func anIdThatIsNotBoundYetIsNotOverwrittenEither() throws {
        let temp = folder()
        var state = ClaudeSessionState()
        state.providerSessionID = other
        state.bound = false
        try state.save(in: temp.url)
        #expect(ClaudeSessionState.writeAttached(providerSessionID: id, at: at, in: temp.url) == .refused)
        #expect(ClaudeSessionState.load(from: temp.url).providerSessionID == other)
    }

    @Test func anExistingFileThatCannotBeReadIsNotOverwritten() throws {
        let temp = folder()
        try Data("{ not json".utf8).write(to: temp.appending("state.json"))
        #expect(ClaudeSessionState.writeAttached(providerSessionID: id, at: at, in: temp.url) == .refused)
        #expect(try Data(contentsOf: temp.appending("state.json")) == Data("{ not json".utf8), "깨진 파일도 지우지 않는다")
        // 모르는 버전의 파일도 마찬가지다
        try Data(#"{"v":2,"bound":true,"provider_session_id":"x"}"#.utf8).write(to: temp.appending("state.json"))
        #expect(ClaudeSessionState.writeAttached(providerSessionID: id, at: at, in: temp.url) == .refused)
    }

    @Test func onlyACanonicalLowercaseUUIDIsWritten() {
        for bad in [id.uppercased(), "../x", "-r", "/tmp/a.jsonl", id + " ", "", "pending:" + id, String(id.dropLast()), id + "0"] {
            let temp = folder()
            #expect(ClaudeSessionState.writeAttached(providerSessionID: bad, at: at, in: temp.url) == .refused, "\(bad)")
            #expect(!FileManager.default.fileExists(atPath: temp.appending("state.json").path), "\(bad)")
        }
    }

    @Test func aFolderThatDoesNotExistGetsNothing() {
        let missing = FileManager.default.temporaryDirectory.appending(path: "tf-missing-\(UUID().uuidString)", directoryHint: .isDirectory)
        #expect(ClaudeSessionState.writeAttached(providerSessionID: id, at: at, in: missing) == .refused)
    }
}
#endif
