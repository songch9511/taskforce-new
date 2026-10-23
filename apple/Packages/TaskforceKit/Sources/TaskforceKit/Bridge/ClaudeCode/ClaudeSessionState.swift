#if os(macOS)
import Foundation

/// 세션 폴더의 상태 파일 `state.json` (0600, OA D3a 계약 2.10-1 · 2.4): Claude Code 세션 id · 묶였는지 · 열린 보류 하나 (id · 종류 · 입력 digest · spawn id · 시각 · 대상 지문 ·
/// 비밀 항목 id) · 비밀값 답을 건넨 적이 있다는 표식. **글 0:** 질문 글 · 답 · 비밀값 · 명령 · 경로를 쓰지 않는다. 앱이 다시 떠도 답 resume가 "그 요청이 아직 열려 있나"와 "어느 항목이 비밀인가"를 볼 수 있게 한다
public struct ClaudeSessionState: Equatable, Sendable {
    public struct OpenDeferred: Equatable, Sendable {
        public var id: String
        /// `input` · `approval`
        public var kind: String
        public var inputSHA256: String
        public var spawnID: String
        public var at: Date
        /// Edit · Write 대상의 지문 (경로가 아니라 해시, 8장 2)
        public var targetSHA256: String?
        /// 입력 질문의 비밀 항목 id (값이 아니라 id만, 10장 7): 앱이 다시 떠도 그 답 값을 가리개에 쌓는다
        public var secretItemIDs: [String]
        /// 질문 항목이 하나다 (그때 답 글 `text`도 그 항목의 값이다)
        public var singleItem: Bool

        public init(
            id: String, kind: String, inputSHA256: String, spawnID: String, at: Date, targetSHA256: String? = nil, secretItemIDs: [String] = [], singleItem: Bool = false
        ) {
            self.id = id
            self.kind = kind
            self.inputSHA256 = inputSHA256
            self.spawnID = spawnID
            self.at = at
            self.targetSHA256 = targetSHA256
            self.secretItemIDs = secretItemIDs
            self.singleItem = singleItem
        }
    }

    /// 이 세션이 어디서 왔나 (OA 외부 세션 PR2m, 계약 ES-08): 없으면 Taskforce가 시작한 세션이다. `attached`는 **이 Mac의 사용자가 로컬 Resume here 확인에서** 이어받은 Claude Code 세션이다
    /// (`writeAttached`만 쓴다: 명령 · push · 서버가 시작한 길은 이 값을 쓰지 못한다)
    public enum Origin: String, Equatable, Sendable {
        case attached
    }

    public var providerSessionID: String?
    /// init이 그 id를 돌려줬다 (`session_bound`를 냈다)
    public var bound = false
    public var origin: Origin?
    /// 로컬 Resume here 확인으로 이어받은 시각 (이 시각보다 먼저 서버가 만든 명령은 거절한다, 계약 20장 6)
    public var attachedAt: Date?
    public var openDeferred: OpenDeferred?
    /// 이 Claude 세션에 비밀값 답을 건넨 적이 있다 (값 0, 11장 9). 앱이 다시 떠 가리개가 비었으면 이 세션의 다음 턴 · 답 resume를 띄우지 않는다
    public var secretAnswered = false

    public init() {}

    static let fileName = "state.json"

    /// `writeAttached`의 결과
    public enum AttachWrite: Equatable, Sendable {
        /// 새로 묶었다
        case written
        /// 이미 같은 id로 이어받은 상태다 (멱등: 처음 시각을 그대로 둔다)
        case alreadyAttached
        /// 쓰지 않았다: 이미 다른 id로 묶였거나 · 묶이지 않은 id가 있거나 · Taskforce가 시작한 같은 id의 세션이거나 · 읽을 수 없는 파일(모르는 버전 포함)이 있거나 · 폴더가 없거나 · id가 정규 소문자 UUID가 아니다
        case refused
    }

    /// 세션 폴더에 "이어받음" 상태를 쓴다 (`provider_session_id` · `bound = true` · `origin = attached` · `attached_at`). **로컬 Resume here 확인만 부른다** (계약 20장 1).
    /// **이미 묶인 폴더를 다른 id로 덮지 않는다** (20장 3, 핀처럼 덮어쓰기 없음): 같은 id로 이어받은 상태면 `alreadyAttached`(다시 쓰지 않는다: 처음 시각이 그대로),
    /// 그 밖의 기존 상태 · 읽을 수 없는 파일은 지우지 않고 `refused`다. id는 정규 소문자 UUID만 (`--resume`에 `/` · 옵션이 들어갈 길을 0으로, T5). 폴더는 이미 있어야 한다 (만들지 않는다)
    public static func writeAttached(providerSessionID id: String, at date: Date, in folder: URL) -> AttachWrite {
        guard ExternalSessionRules.isCanonicalUUID(id) else { return .refused }
        let file = folder.appending(path: fileName)
        var existing: ClaudeSessionState?
        if FileManager.default.fileExists(atPath: file.path) {
            guard let data = try? Data(contentsOf: file), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], object["v"] as? Int == 1 else { return .refused }
            existing = load(from: folder)
        }
        if let existing {
            if existing.bound, existing.providerSessionID == id, existing.origin == .attached { return .alreadyAttached }
            if existing.bound || existing.providerSessionID != nil { return .refused }
        }
        var state = existing ?? ClaudeSessionState()
        state.providerSessionID = id
        state.bound = true
        state.origin = .attached
        state.attachedAt = date
        do {
            try state.save(in: folder)
        } catch {
            return .refused
        }
        return .written
    }

    public static func load(from folder: URL) -> ClaudeSessionState {
        guard let data = try? Data(contentsOf: folder.appending(path: fileName)), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["v"] as? Int == 1 else { return ClaudeSessionState() }
        var state = ClaudeSessionState()
        state.providerSessionID = object["provider_session_id"] as? String
        state.bound = object["bound"] as? Bool ?? false
        state.origin = (object["origin"] as? String).flatMap(Origin.init(rawValue:))
        state.attachedAt = (object["attached_at"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) }
        state.secretAnswered = object["secret_answered"] as? Bool ?? false
        if let open = object["open_deferred"] as? [String: Any], let id = open["id"] as? String, let kind = open["kind"] as? String,
           let digest = open["input_sha256"] as? String, let spawnID = open["spawn_id"] as? String, let at = open["at"] as? Double {
            state.openDeferred = OpenDeferred(
                id: id, kind: kind, inputSHA256: digest, spawnID: spawnID, at: Date(timeIntervalSince1970: at / 1000), targetSHA256: open["target_sha256"] as? String,
                secretItemIDs: open["secret_item_ids"] as? [String] ?? [], singleItem: open["single_item"] as? Bool ?? false
            )
        }
        return state
    }

    public func save(in folder: URL) throws {
        var object: [String: Any] = ["v": 1, "bound": bound, "secret_answered": secretAnswered]
        object["provider_session_id"] = providerSessionID ?? NSNull()
        // 이어받은 세션만 두 칸이 더 있다 (Taskforce가 시작한 세션의 파일 모양은 그대로다)
        if let origin { object["origin"] = origin.rawValue }
        if let attachedAt { object["attached_at"] = (attachedAt.timeIntervalSince1970 * 1000).rounded() }
        if let openDeferred {
            object["open_deferred"] = [
                "id": openDeferred.id, "kind": openDeferred.kind, "input_sha256": openDeferred.inputSHA256, "spawn_id": openDeferred.spawnID,
                "at": (openDeferred.at.timeIntervalSince1970 * 1000).rounded(), "target_sha256": openDeferred.targetSHA256.map { $0 as Any } ?? NSNull(),
                "secret_item_ids": openDeferred.secretItemIDs, "single_item": openDeferred.singleItem,
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
