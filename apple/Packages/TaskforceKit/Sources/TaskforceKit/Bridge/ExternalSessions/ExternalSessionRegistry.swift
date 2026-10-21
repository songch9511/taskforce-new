#if os(macOS)
import Foundation

/// Claude Code의 세션 등록 파일 `~/.claude/sessions/<pid>.json` 읽기 (OA 외부 세션 PR1, 계약 5.4 신호 1 · OB-1).
/// **문서에 없는 내부 형식이다 (확인 필요 R4).** 그래서 이름은 `^[0-9]{1,10}\.json$`뿐, 64 KiB 상한, 모르는 모양은 건너뛰고,
/// 읽은 파일이 하나도 해석되지 않으면(형식이 바뀐 것) `unavailable`로 알려 신호 1을 건너뛰게 한다. 옆의 `<pid>.<hash>.key`(0600)는 열지 않는다.
enum ExternalSessionRegistry {
    static let maxFileBytes = 64 * 1024
    static let maxFiles = 500

    struct Entry: Equatable, Sendable {
        var pid: Int32
        var sessionID: String
        var cwd: String?
        /// 프로세스 시작 시각. 값이 없거나 읽지 못하면 nil (그때는 pid 재사용을 가릴 수 없어 살아 있으면 쥔 것으로 본다)
        var procStart: Date?
        var entrypoint: String?
        var kind: String?
    }

    enum Read: Equatable, Sendable {
        case entries([Entry])
        /// 폴더를 읽을 수 없거나 형식이 바뀌어 하나도 해석하지 못했다
        case unavailable
    }

    private struct File: Decodable {
        var pid: Int?
        var sessionId: String?
        var cwd: String?
        var procStart: Scalar?
        var entrypoint: String?
        var kind: String?

        enum CodingKeys: String, CodingKey { case pid, sessionId, cwd, procStart, entrypoint, kind }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            if let number = try? container.decodeIfPresent(Int.self, forKey: .pid) {
                pid = number
            } else if let text = try? container.decodeIfPresent(String.self, forKey: .pid) {
                pid = Int(text)
            }
            sessionId = try? container.decodeIfPresent(String.self, forKey: .sessionId)
            cwd = try? container.decodeIfPresent(String.self, forKey: .cwd)
            procStart = try? container.decodeIfPresent(Scalar.self, forKey: .procStart)
            entrypoint = try? container.decodeIfPresent(String.self, forKey: .entrypoint)
            kind = try? container.decodeIfPresent(String.self, forKey: .kind)
        }
    }

    private enum Scalar: Decodable {
        case number(Double)
        case text(String)

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let number = try? container.decode(Double.self) {
                self = .number(number)
            } else {
                self = .text(try container.decode(String.self))
            }
        }
    }

    static func read(fileSystem: ExternalSessionFileSystem, sessionsDirectory: String) -> Read {
        let items: [ExternalSessionFileSystem.Entry]
        switch fileSystem.list(sessionsDirectory) {
        case .missing: return .entries([])
        case .failed: return .unavailable
        case .entries(let found): items = found
        }
        var entries: [Entry] = []
        var undecodable = 0
        for item in items.prefix(maxFiles) where item.kind == .regular && item.owner == fileSystem.userID && ExternalSessionReadAllowList.isRegistry(file: item.name) {
            guard item.size > 0, item.size <= Int64(maxFileBytes), let data = fileSystem.read(sessionsDirectory + "/" + item.name, 0, Int(item.size)),
                  let file = try? JSONDecoder().decode(File.self, from: data), let pid = file.pid, pid > 0, pid <= Int(Int32.max),
                  let id = file.sessionId, ExternalSessionRules.isCanonicalUUID(id) else {
                undecodable += 1
                continue
            }
            entries.append(Entry(
                pid: Int32(pid), sessionID: id, cwd: file.cwd.flatMap { $0.utf8.count <= 4096 ? $0 : nil }, procStart: file.procStart.flatMap(parseProcStart),
                entrypoint: file.entrypoint.flatMap { $0.utf8.count <= 64 ? $0 : nil }, kind: file.kind.flatMap { $0.utf8.count <= 64 ? $0 : nil }
            ))
        }
        if entries.isEmpty, undecodable > 0 { return .unavailable }
        return .entries(entries)
    }

    /// `procStart`의 모양은 문서에 없다 (R4): 초 · 밀리초 숫자(글자 포함), ISO 8601, `ps`의 `lstart`(`Wed Oct 21 10:00:00 2026`)를 읽는다. 못 읽으면 nil
    private static func parseProcStart(_ value: Scalar) -> Date? {
        switch value {
        case .number(let number): return fromEpoch(number)
        case .text(let text):
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            if let number = Double(trimmed) { return fromEpoch(number) }
            for options: ISO8601DateFormatter.Options in [[.withInternetDateTime, .withFractionalSeconds], [.withInternetDateTime]] {
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = options
                if let date = formatter.date(from: trimmed) { return date }
            }
            for format in ["EEE MMM d HH:mm:ss yyyy", "EEE MMM  d HH:mm:ss yyyy"] {
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.timeZone = .current
                formatter.dateFormat = format
                if let date = formatter.date(from: trimmed) { return date }
            }
            return nil
        }
    }

    private static func fromEpoch(_ number: Double) -> Date? {
        guard number.isFinite, number > 0 else { return nil }
        let seconds = number > 1e11 ? number / 1000 : number
        return Date(timeIntervalSince1970: seconds)
    }
}
#endif
