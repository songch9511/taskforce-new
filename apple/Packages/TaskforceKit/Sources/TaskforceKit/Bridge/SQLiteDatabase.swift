#if os(macOS)
import Foundation
import SQLite3

// 시스템 SQLite3의 얇은 감싸기 (새 의존성 0). 원장 actor 하나 안에서만 쓴다 (스레드 간 공유 없음).

nonisolated(unsafe) private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

enum SQLValue {
    case null
    case int(Int64)
    case text(String)

    static func n(_ value: Int) -> SQLValue { .int(Int64(value)) }
    static func optionalN(_ value: Int?) -> SQLValue { value.map { .int(Int64($0)) } ?? .null }
    static func optional(_ value: Int64?) -> SQLValue { value.map { .int($0) } ?? .null }
    static func optional(_ value: String?) -> SQLValue { value.map { .text($0) } ?? .null }
    static func bool(_ value: Bool) -> SQLValue { .int(value ? 1 : 0) }

    /// 시각은 밀리초 정수로 적는다
    static func date(_ value: Date) -> SQLValue { .int(Self.milliseconds(value)) }
    static func optional(_ value: Date?) -> SQLValue { value.map { .date($0) } ?? .null }

    static func milliseconds(_ date: Date) -> Int64 { Int64((date.timeIntervalSince1970 * 1000).rounded()) }
}

struct SQLRow {
    fileprivate let statement: OpaquePointer

    func int(_ column: Int32) -> Int64 { sqlite3_column_int64(statement, column) }
    func optionalInt(_ column: Int32) -> Int64? { sqlite3_column_type(statement, column) == SQLITE_NULL ? nil : int(column) }
    func bool(_ column: Int32) -> Bool { int(column) != 0 }

    func text(_ column: Int32) -> String? {
        guard let pointer = sqlite3_column_text(statement, column) else { return nil }
        return String(cString: pointer)
    }

    func requiredText(_ column: Int32) -> String { text(column) ?? "" }

    func date(_ column: Int32) -> Date { Date(timeIntervalSince1970: Double(int(column)) / 1000) }
    func optionalDate(_ column: Int32) -> Date? { optionalInt(column).map { Date(timeIntervalSince1970: Double($0) / 1000) } }
}

final class SQLiteDatabase {
    private var handle: OpaquePointer?

    init(path: String) throws {
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        var opened: OpaquePointer?
        let code = sqlite3_open_v2(path, &opened, flags, nil)
        handle = opened
        guard code == SQLITE_OK else {
            let error = BridgeLedgerError.sqlite(code: Int(code), message: opened.map { String(cString: sqlite3_errmsg($0)) } ?? "open")
            if let opened { sqlite3_close_v2(opened) }
            handle = nil
            throw error
        }
    }

    deinit {
        close()
    }

    var isOpen: Bool { handle != nil }

    func close() {
        guard let handle else { return }
        sqlite3_close_v2(handle)
        self.handle = nil
    }

    private func failure(_ code: Int32? = nil) -> BridgeLedgerError {
        guard let handle else { return .sqlite(code: Int(SQLITE_MISUSE), message: "closed") }
        return .sqlite(code: Int(code ?? sqlite3_extended_errcode(handle)), message: String(cString: sqlite3_errmsg(handle)))
    }

    func exec(_ sql: String) throws {
        guard let handle else { throw failure() }
        var message: UnsafeMutablePointer<CChar>?
        let code = sqlite3_exec(handle, sql, nil, nil, &message)
        if code != SQLITE_OK {
            let text = message.map { String(cString: $0) } ?? "exec"
            sqlite3_free(message)
            throw BridgeLedgerError.sqlite(code: Int(code), message: text)
        }
    }

    private func prepare(_ sql: String, _ binds: [SQLValue]) throws -> OpaquePointer {
        guard let handle else { throw failure() }
        var statement: OpaquePointer?
        let code = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
        guard code == SQLITE_OK, let statement else { throw failure(code) }
        for (offset, value) in binds.enumerated() {
            let index = Int32(offset + 1)
            let result: Int32
            switch value {
            case .null: result = sqlite3_bind_null(statement, index)
            case .int(let number): result = sqlite3_bind_int64(statement, index, number)
            case .text(let text): result = sqlite3_bind_text(statement, index, text, -1, sqliteTransient)
            }
            guard result == SQLITE_OK else {
                sqlite3_finalize(statement)
                throw failure(result)
            }
        }
        return statement
    }

    /// 결과 행이 없는 문장. 바뀐 행 수를 돌려준다
    @discardableResult
    func run(_ sql: String, _ binds: [SQLValue] = []) throws -> Int {
        let statement = try prepare(sql, binds)
        defer { sqlite3_finalize(statement) }
        var code = sqlite3_step(statement)
        while code == SQLITE_ROW { code = sqlite3_step(statement) }
        guard code == SQLITE_DONE else { throw failure(code) }
        return Int(sqlite3_changes(handle))
    }

    func rows<T>(_ sql: String, _ binds: [SQLValue] = [], _ map: (SQLRow) -> T) throws -> [T] {
        let statement = try prepare(sql, binds)
        defer { sqlite3_finalize(statement) }
        var result: [T] = []
        while true {
            let code = sqlite3_step(statement)
            if code == SQLITE_ROW {
                result.append(map(SQLRow(statement: statement)))
            } else if code == SQLITE_DONE {
                return result
            } else {
                throw failure(code)
            }
        }
    }

    func scalarInt(_ sql: String, _ binds: [SQLValue] = []) throws -> Int64? {
        try rows(sql, binds) { $0.optionalInt(0) }.first ?? nil
    }

    func scalarText(_ sql: String, _ binds: [SQLValue] = []) throws -> String? {
        try rows(sql, binds) { $0.text(0) }.first ?? nil
    }

    var lastInsertRowID: Int64 { handle.map { sqlite3_last_insert_rowid($0) } ?? 0 }

    /// 한 트랜잭션: 본문이 던지면 되돌린다. 안에서 `await`하지 않는다 (actor 안 동기 코드)
    func transaction<T>(_ body: () throws -> T) throws -> T {
        try exec("BEGIN IMMEDIATE")
        do {
            let value = try body()
            try exec("COMMIT")
            return value
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }
}
#endif
