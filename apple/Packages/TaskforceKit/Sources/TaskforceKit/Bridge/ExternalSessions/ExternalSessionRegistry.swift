#if os(macOS)
import Foundation

/// Claude Code의 세션 등록 파일 `~/.claude/sessions/<pid>.json` 읽기 (OA 외부 세션 PR1, 계약 5.4 신호 1 · OB-1).
/// **문서에 없는 내부 형식이다 (확인 필요 R4).** 그래서 이름은 `^[0-9]{1,10}\.json$`뿐, 64 KiB 상한, 모르는 모양은 건너뛰고,
/// 읽은 파일이 하나도 해석되지 않으면(형식이 바뀐 것) `unavailable`로 알려 신호 1을 건너뛰게 한다. 옆의 `<pid>.<hash>.key`(0600)는 열지 않는다.
enum ExternalSessionRegistry {
    static let maxFileBytes = 64 * 1024
    static let maxFiles = 500
    /// 폴더에서 나열하는 항목 상한 (넘으면 쥔 곳을 다 보지 못한 것이라 `unavailable`)
    static let maxListed = 5_000

    struct Entry: Equatable, Sendable {
        var pid: Int32
        var sessionID: String
        var cwd: String?
        /// 프로세스 시작 시각. 값이 없거나 읽지 못하면 nil (그때는 pid 재사용을 가릴 수 없어 살아 있으면 쥔 것으로 본다)
        var procStart: Date?
        /// 시간대가 없는 `lstart` 글을 다른 시간대로 읽은 값 (`procStart`는 이 Mac의 시간대, 이것은 UTC). 두 읽기가 같거나 시각이 정해진 모양이면 nil.
        /// 데스크톱이 띄운 번들 `claude`(2.1.304)는 `lstart`를 UTC로 적는다 — 이 Mac의 시간대로만 읽으면 시간대 차이만큼 어긋나 살아 있는 세션이 stale로 보인다
        var procStartAlternate: Date? = nil
        var entrypoint: String?
        var kind: String?
        /// `status` · `waitingFor` (DR-2, PR-D1). 키가 없거나 모르는 값이면 `.unknown`: 줄은 그대로 읽고 상태만 모른다
        var state: ClaudeAppSessionState = .unknown
        /// `statusUpdatedAt` (밀리초 · 초 · 글). 없거나 믿을 범위 밖이면 nil
        var statusUpdatedAt: Date? = nil
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
        var status: String?
        var waitingFor: String?
        var statusUpdatedAt: Scalar?

        enum CodingKeys: String, CodingKey { case pid, sessionId, cwd, procStart, entrypoint, kind, status, waitingFor, statusUpdatedAt }

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
            status = try? container.decodeIfPresent(String.self, forKey: .status)
            waitingFor = try? container.decodeIfPresent(String.self, forKey: .waitingFor)
            statusUpdatedAt = try? container.decodeIfPresent(Scalar.self, forKey: .statusUpdatedAt)
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

    static func read(fileSystem: ExternalSessionFileSystem, sessionsDirectory: String, now: Date = Date(), limit: Int = maxListed, localZone: TimeZone = .current) -> Read {
        let items: [ExternalSessionFileSystem.Entry]
        // 상한보다 하나 더 요청해 넘쳤는지 안다: 다 보지 못한 폴더로는 쥔 곳이 없다고 말할 수 없다
        switch fileSystem.list(sessionsDirectory, limit + 1) {
        case .missing: return .entries([])
        case .failed: return .unavailable
        case .entries(let found):
            if found.count > limit { return .unavailable }
            items = found
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
            let starts = file.procStart.map { parseProcStart($0, now: now, localZone: localZone) } ?? []
            entries.append(Entry(
                pid: Int32(pid), sessionID: id, cwd: file.cwd.flatMap { $0.utf8.count <= 4096 ? $0 : nil }, procStart: starts.first, procStartAlternate: starts.dropFirst().first,
                entrypoint: file.entrypoint.flatMap { $0.utf8.count <= 64 ? $0 : nil }, kind: file.kind.flatMap { $0.utf8.count <= 64 ? $0 : nil },
                state: ClaudeAppSessionState.parse(status: file.status, waitingFor: file.waitingFor),
                statusUpdatedAt: file.statusUpdatedAt.flatMap { parseProcStart($0, now: now, localZone: localZone).first }
            ))
        }
        if entries.isEmpty, undecodable > 0 { return .unavailable }
        return .entries(entries)
    }

    /// 믿을 수 있는 `procStart`의 범위: 2015-01-01부터 지금보다 하루 앞(시계 오차)까지. 밖이면 읽지 않은 것(nil)으로 둔다.
    /// 단위를 잘못 읽은 값(µs · ns를 초 · ms로)은 먼 미래가 되어 어긋난 시작 시각 = "pid 재사용"으로 보이고, 쥔 세션을 비어 있다고 오판한다(fail-open).
    /// nil이면 살아 있는 pid는 쥔 것으로 본다 (`ExternalSessionHold.isAlive`)
    static let earliestProcStart = Date(timeIntervalSince1970: 1_420_070_400)
    static let procStartSkew: TimeInterval = 86_400

    private static func plausible(_ date: Date?, now: Date) -> Date? {
        guard let date, date >= earliestProcStart, date <= now.addingTimeInterval(procStartSkew) else { return nil }
        return date
    }

    /// `procStart`의 모양은 문서에 없다 (R4): 초 · 밀리초 숫자(글자 포함), ISO 8601, `ps`의 `lstart`(`Wed Oct 21 10:00:00 2026`)를 읽는다. 못 읽거나 믿을 범위 밖이면 빈 목록.
    /// `lstart`에는 시간대가 없다: 데스크톱 번들 `claude`(2.1.304)는 UTC로 적는다 (KST Mac의 `ps lstart`보다 9시간 앞선 글). 터미널 쪽 형식은 실측 전이라 이 Mac의 시간대로도 읽는다 — 둘을 차례로(이 Mac, UTC) 돌려준다
    private static func parseProcStart(_ value: Scalar, now: Date, localZone: TimeZone) -> [Date] {
        parseProcStartRaw(value, localZone: localZone).compactMap { plausible($0, now: now) }
    }

    private static func parseProcStartRaw(_ value: Scalar, localZone: TimeZone) -> [Date] {
        switch value {
        case .number(let number): return fromEpoch(number).map { [$0] } ?? []
        case .text(let text):
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            if let number = Double(trimmed) { return fromEpoch(number).map { [$0] } ?? [] }
            for options: ISO8601DateFormatter.Options in [[.withInternetDateTime, .withFractionalSeconds], [.withInternetDateTime]] {
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = options
                if let date = formatter.date(from: trimmed) { return [date] }
            }
            var readings: [Date] = []
            for zone in [localZone, TimeZone(identifier: "UTC") ?? TimeZone(secondsFromGMT: 0)!] {
                guard let date = lstart(trimmed, in: zone), !readings.contains(date) else { continue }
                readings.append(date)
            }
            return readings
        }
    }

    private static func lstart(_ text: String, in zone: TimeZone) -> Date? {
        for format in ["EEE MMM d HH:mm:ss yyyy", "EEE MMM  d HH:mm:ss yyyy"] {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = zone
            formatter.dateFormat = format
            if let date = formatter.date(from: text) { return date }
        }
        return nil
    }

    private static func fromEpoch(_ number: Double) -> Date? {
        guard number.isFinite, number > 0 else { return nil }
        let seconds = number > 1e11 ? number / 1000 : number
        return Date(timeIntervalSince1970: seconds)
    }
}
#endif
