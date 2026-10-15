#if os(macOS)
import Foundation

/// 세션 폴더의 상태 파일 `state.json` (0600, OA D3a 계약 2.10-1 · 2.4): Claude Code 세션 id · 묶였는지 · 열린 보류 하나 (id · 종류 · 입력 digest · spawn id · 시각).
/// **글 0:** 질문 글 · 답 · 명령 · 경로를 쓰지 않는다. 앱이 다시 떠도 답 resume가 "그 요청이 아직 열려 있나"를 볼 수 있게 한다
public struct ClaudeSessionState: Equatable, Sendable {
    public struct OpenDeferred: Equatable, Sendable {
        public var id: String
        /// `input` · `approval`
        public var kind: String
        public var inputSHA256: String
        public var spawnID: String
        public var at: Date

        public init(id: String, kind: String, inputSHA256: String, spawnID: String, at: Date) {
            self.id = id
            self.kind = kind
            self.inputSHA256 = inputSHA256
            self.spawnID = spawnID
            self.at = at
        }
    }

    public var providerSessionID: String?
    /// init이 그 id를 돌려줬다 (`session_bound`를 냈다)
    public var bound = false
    public var openDeferred: OpenDeferred?

    public init() {}

    static let fileName = "state.json"

    public static func load(from folder: URL) -> ClaudeSessionState {
        guard let data = try? Data(contentsOf: folder.appending(path: fileName)), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["v"] as? Int == 1 else { return ClaudeSessionState() }
        var state = ClaudeSessionState()
        state.providerSessionID = object["provider_session_id"] as? String
        state.bound = object["bound"] as? Bool ?? false
        if let open = object["open_deferred"] as? [String: Any], let id = open["id"] as? String, let kind = open["kind"] as? String,
           let digest = open["input_sha256"] as? String, let spawnID = open["spawn_id"] as? String, let at = open["at"] as? Double {
            state.openDeferred = OpenDeferred(id: id, kind: kind, inputSHA256: digest, spawnID: spawnID, at: Date(timeIntervalSince1970: at / 1000))
        }
        return state
    }

    public func save(in folder: URL) throws {
        var object: [String: Any] = ["v": 1, "bound": bound]
        object["provider_session_id"] = providerSessionID ?? NSNull()
        if let openDeferred {
            object["open_deferred"] = [
                "id": openDeferred.id, "kind": openDeferred.kind, "input_sha256": openDeferred.inputSHA256, "spawn_id": openDeferred.spawnID,
                "at": (openDeferred.at.timeIntervalSince1970 * 1000).rounded(),
            ]
        } else {
            object["open_deferred"] = NSNull()
        }
        let url = folder.appending(path: Self.fileName)
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
#endif
