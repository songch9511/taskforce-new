#if os(macOS)
import Foundation

/// Local Codex metadata only. No transcript reads, server reports, or inferred execution state.
public struct CodexLocalSession: Identifiable, Equatable, Sendable, CustomStringConvertible {
    public let id: String
    public let title: String
    public let updatedAt: Date
    public var description: String { "CodexLocalSession" }

    public var openURL: URL? {
        guard ExternalSessionRules.isCanonicalUUID(id) else { return nil }
        return URL(string: "codex://threads/\(id)")
    }
}

public actor CodexLocalSessionReader {
    public enum Result: Equatable, Sendable {
        case sessions([CodexLocalSession])
        case unreadable
    }

    private let directory: String
    private let files: ExternalSessionFileSystem
    /// The append-only index can grow indefinitely. Read only its most recent complete records.
    static let byteLimit = 2 * 1024 * 1024
    public init(directory: String = ProcessInfo.processInfo.environment["CODEX_HOME"] ?? (NSHomeDirectory() + "/.codex"), files: ExternalSessionFileSystem = .live) {
        self.directory = directory
        self.files = files
    }

    public func read() -> Result {
        guard let root = files.realpath(directory) else {
            return files.lstat(directory) == nil ? .sessions([]) : .unreadable
        }
        guard let rootEntry = files.lstat(root), rootEntry.kind == .directory,
              rootEntry.owner == files.userID else { return .unreadable }
        let path = root + "/session_index.jsonl"
        guard let entry = files.lstat(path) else { return .sessions([]) }
        guard entry.kind == .regular, entry.owner == files.userID, entry.size >= 0 else { return .unreadable }
        if entry.size == 0 { return .sessions([]) }
        let offset = max(0, entry.size - Int64(Self.byteLimit))
        guard let data = files.read(path, offset, min(Self.byteLimit, Int(entry.size))),
              let after = files.lstat(path), after.kind == .regular, after.owner == entry.owner,
              after.size >= entry.size else { return .unreadable }
        return .sessions(Self.parse(data, startsMidRecord: offset > 0))
    }

    static func parse(_ data: Data, startsMidRecord: Bool = false) -> [CodexLocalSession] {
        struct Record: Decodable {
            let id: String
            let thread_name: String
            let updated_at: String
        }
        let decoder = JSONDecoder()
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        var lines = data.split(separator: 0x0A, omittingEmptySubsequences: false)
        if startsMidRecord, !lines.isEmpty { lines.removeFirst() }
        // A writer can be appending the last record while we read. Only newline-terminated records count.
        if data.last != 0x0A, !lines.isEmpty { lines.removeLast() }
        var sessions: [String: CodexLocalSession] = [:]
        for line in lines {
            guard line.count <= 16_384,
                  let item = try? decoder.decode(Record.self, from: Data(line)),
                  ExternalSessionRules.isCanonicalUUID(item.id),
                  let title = ExternalSessionRules.sanitizedTitle(item.thread_name),
                  let date = fractional.date(from: item.updated_at) ?? plain.date(from: item.updated_at) else { continue }
            if let existing = sessions[item.id], existing.updatedAt > date { continue }
            sessions[item.id] = CodexLocalSession(id: item.id, title: title, updatedAt: date)
        }
        return Array(sessions.values.sorted {
            $0.updatedAt == $1.updatedAt ? $0.id < $1.id : $0.updatedAt > $1.updatedAt
        }.prefix(200))
    }
}
#endif
