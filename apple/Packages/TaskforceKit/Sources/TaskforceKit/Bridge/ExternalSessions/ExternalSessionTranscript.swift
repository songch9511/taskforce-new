#if os(macOS)
import Foundation

/// 기록 파일(`<uuid>.jsonl`)에서 읽는 것 (OA 외부 세션 PR1, 계약 ES-01 A · T1 · T3). **대화 줄은 열지 않는다.**
/// - 머리 64 KiB: `sessionId`가 파일 id와 같은 줄의 `cwd` · `entrypoint` · `version`뿐 (각 칸은 처음 나온 값)
/// - 꼬리 256 KiB: 마지막 `custom-title.customTitle` 또는 `agent-name.agentName` (파일에서 더 뒤에 나온 것)
/// - `user` · `assistant` · `last-prompt` 줄의 글은 어디에도 담지 않는다: 줄을 디코딩해도 선언한 칸(`type` · `sessionId` · 위 칸)만 꺼낸다.
///   제목 줄은 글자 `custom-title` · `agent-name`이 들어 있는 줄만 디코딩한다
/// - 한 줄 64 KiB를 넘으면 버린다. 읽는 창의 잘린 줄(꼬리의 첫 줄 · 머리의 마지막 줄)은 버린다. 실패하면 비운다
enum ExternalSessionTranscript {
    static let headBytes = 64 * 1024
    static let tailBytes = 256 * 1024
    static let maxLineBytes = 64 * 1024
    static let maxFieldLength = 4096

    struct Meta: Equatable, Sendable {
        var cwd: String?
        var entrypoint: String?
        var version: String?
        /// 정리한 제목 (`ExternalSessionRules.sanitizedTitle`)
        var title: String?
    }

    /// 읽은 바이트의 합을 세는 예산 (T3: 한 번 훑는 총 읽기 32 MiB)
    struct Budget {
        var remaining: Int64
        var exhausted: Bool { remaining <= 0 }
    }

    private struct HeadLine: Decodable {
        var sessionId: String?
        var cwd: String?
        var entrypoint: String?
        var version: String?

        enum CodingKeys: String, CodingKey { case sessionId, cwd, entrypoint, version }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            sessionId = try? container.decodeIfPresent(String.self, forKey: .sessionId)
            cwd = try? container.decodeIfPresent(String.self, forKey: .cwd)
            entrypoint = try? container.decodeIfPresent(String.self, forKey: .entrypoint)
            version = try? container.decodeIfPresent(String.self, forKey: .version)
        }
    }

    private struct TitleLine: Decodable {
        var type: String?
        var sessionId: String?
        var customTitle: String?
        var agentName: String?

        enum CodingKeys: String, CodingKey { case type, sessionId, customTitle, agentName }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            type = try? container.decodeIfPresent(String.self, forKey: .type)
            sessionId = try? container.decodeIfPresent(String.self, forKey: .sessionId)
            customTitle = try? container.decodeIfPresent(String.self, forKey: .customTitle)
            agentName = try? container.decodeIfPresent(String.self, forKey: .agentName)
        }
    }

    private static let customTitleNeedle = Data("\"custom-title\"".utf8)
    private static let agentNameNeedle = Data("\"agent-name\"".utf8)

    /// 파일 하나의 머리 · 꼬리를 읽는다. 읽지 못하면 nil (제목 없이 · 판정 없이 줄을 둔다)
    static func read(path: String, id: String, size: Int64, fileSystem: ExternalSessionFileSystem, budget: inout Budget) -> Meta? {
        guard size > 0 else { return nil }
        var headWindow: Data
        var tailWindow: Data
        if size <= Int64(headBytes + tailBytes) {
            guard let whole = fileSystem.read(path, 0, Int(size)) else { return nil }
            budget.remaining -= Int64(whole.count)
            headWindow = whole.prefix(headBytes)
            tailWindow = whole.suffix(tailBytes)
            if whole.count > headBytes { headWindow = dropPartialTail(headWindow) }
            if whole.count > tailBytes { tailWindow = dropPartialHead(tailWindow) }
        } else {
            guard let head = fileSystem.read(path, 0, headBytes) else { return nil }
            budget.remaining -= Int64(head.count)
            headWindow = dropPartialTail(head)
            if let tail = fileSystem.read(path, size - Int64(tailBytes), tailBytes) {
                budget.remaining -= Int64(tail.count)
                tailWindow = dropPartialHead(tail)
            } else {
                tailWindow = Data()
            }
        }
        var meta = Meta()
        for line in lines(of: headWindow) {
            guard let parsed = try? JSONDecoder().decode(HeadLine.self, from: line), parsed.sessionId == id else { continue }
            if meta.cwd == nil { meta.cwd = limited(parsed.cwd) }
            if meta.entrypoint == nil { meta.entrypoint = limited(parsed.entrypoint, max: 64) }
            if meta.version == nil { meta.version = limited(parsed.version, max: 64) }
            if meta.cwd != nil, meta.entrypoint != nil, meta.version != nil { break }
        }
        var title: String??
        for line in lines(of: tailWindow) {
            guard line.range(of: customTitleNeedle) != nil || line.range(of: agentNameNeedle) != nil,
                  let parsed = try? JSONDecoder().decode(TitleLine.self, from: line) else { continue }
            if let sessionId = parsed.sessionId, sessionId != id { continue }
            switch parsed.type {
            case "custom-title"?: if let name = parsed.customTitle { title = .some(ExternalSessionRules.sanitizedTitle(name)) }
            case "agent-name"?: if let name = parsed.agentName { title = .some(ExternalSessionRules.sanitizedTitle(name)) }
            default: continue
            }
        }
        if case .some(let value) = title { meta.title = value }
        return meta
    }

    private static func limited(_ text: String?, max: Int = maxFieldLength) -> String? {
        guard let text, !text.isEmpty, text.utf8.count <= max else { return nil }
        return text
    }

    /// 줄(0x0A로 나눈 것) 중 64 KiB 이하만
    private static func lines(of data: Data) -> [Data] {
        data.split(separator: 0x0A, omittingEmptySubsequences: true).filter { $0.count <= maxLineBytes }.map { Data($0) }
    }

    /// 창의 끝에서 잘린 줄(마지막 개행 뒤)을 버린다
    private static func dropPartialTail(_ data: Data) -> Data {
        guard let last = data.lastIndex(of: 0x0A) else { return Data() }
        return Data(data[data.startIndex...last])
    }

    /// 창의 앞에서 잘린 줄(첫 개행 앞)을 버린다
    private static func dropPartialHead(_ data: Data) -> Data {
        guard let first = data.firstIndex(of: 0x0A) else { return Data() }
        return Data(data[data.index(after: first)...])
    }
}
#endif
