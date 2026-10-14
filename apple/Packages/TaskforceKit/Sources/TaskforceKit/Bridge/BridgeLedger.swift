#if os(macOS)
import Foundation

/// Mac의 로컬 원장 (OA D2b 계약 2.5 · Q3 SQLite). 파티션(API origin + 사용자) 하나에 파일 하나.
///
/// - 원칙 3 "먼저 적고 그다음 한다": 외부 효과(lease 요청 · 프로세스 시작 · 중단 · ack) 앞에 그 의도를 commit한다. 호출하는 쪽(`BridgeRuntime`)이 이 순서를 지키고, 여기는 각 쓰기를 한 트랜잭션으로 묶는다.
/// - 사용자 메시지 글 · 비밀값은 어느 열에도 쓰지 않는다 (lease `replay`가 글을 다시 준다). 디스크에 남는 글은 서버로 보낼 사건(32KB 이하로 자른 것)과 잘린 글 전체(View full)뿐이다.
/// - `journal_mode=WAL` · `synchronous=FULL` · `foreign_keys=ON` · `secure_delete=ON`(지운 글이 빈 쪽에 남지 않게). 폴더 0700 · 파일 0600.
/// - 열 때 `quick_check`: 손상이면 파일을 `ledger.sqlite.corrupt-<epoch초>`로 **옮기고**(지우지 않는다) 빈 원장으로 시작한다. 그 뒤 모르는 명령의 결과 확인은 모두 `unknown`이다.
public actor BridgeLedger {
    public static let schemaVersion = 1

    public nonisolated let directory: URL
    public nonisolated let fileURL: URL
    /// 열다가 손상으로 옮겨 둔 파일 (없으면 nil)
    public nonisolated let quarantinedFile: URL?

    private var db: SQLiteDatabase
    private let now: @Sendable () -> Date
    private let byteLimit: Int
    /// 단일 인스턴스 잠금: 파티션 폴더의 `ledger.lock`에 건 `flock`. 닫을 때 풀린다
    private var lockDescriptor: Int32

    private static let day: TimeInterval = 86400

    /// 열기 · `quick_check` · 스키마 만들기는 디스크를 만진다. 메인 스레드에서는 이 비동기 버전으로 연다 (새 스레드에서 열고 원장을 돌려준다)
    public static func open(directory: URL, now: @escaping @Sendable () -> Date = { Date() }, byteLimit: Int = 50_000_000) async throws -> BridgeLedger {
        try await Task.detached(priority: .userInitiated) { try BridgeLedger(directory: directory, now: now, byteLimit: byteLimit) }.value
    }

    public init(directory: URL, now: @escaping @Sendable () -> Date = { Date() }, byteLimit: Int = 50_000_000) throws {
        self.directory = directory
        self.now = now
        self.byteLimit = byteLimit
        let file = directory.appending(path: "ledger.sqlite")
        self.fileURL = file
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        // 같은 파티션 원장은 한 곳에서만 쓴다: 두 번째 런타임 · 프로세스가 같은 파일을 열면 서로의 감독을 모르고 같은 명령을 두 번 띄울 수 있다
        let descriptor = try Self.acquireLock(in: directory)
        self.lockDescriptor = descriptor
        var moved: URL?
        do {
            do {
                self.db = try Self.openPrepared(file)
            } catch let error as BridgeLedgerError where Self.isCorruption(error) {
                moved = try Self.quarantine(file, at: now())
                self.db = try Self.openPrepared(file)
            }
        } catch {
            flock(descriptor, LOCK_UN)
            Darwin.close(descriptor)
            throw error
        }
        self.quarantinedFile = moved
        // 쓰기를 한 번 해서 WAL · SHM 파일이 만들어진 뒤 세 파일 모두 소유자만 읽게 한다 (폴더가 0700이어도 파일 권한을 따로 둔다)
        _ = try? db.run("UPDATE meta SET schema_version = schema_version WHERE id = 1")
        Self.restrictPermissions(file)
    }

    deinit {
        if lockDescriptor >= 0 {
            flock(lockDescriptor, LOCK_UN)
            Darwin.close(lockDescriptor)
        }
    }

    private static func acquireLock(in directory: URL) throws -> Int32 {
        let descriptor = Darwin.open(directory.appending(path: "ledger.lock").path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw BridgeLedgerError.sqlite(code: Int(errno), message: "lock open") }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            Darwin.close(descriptor)
            throw BridgeLedgerError.locked
        }
        return descriptor
    }

    /// DB · WAL · SHM 세 파일을 0600으로 (없는 파일은 건너뛴다)
    private static func restrictPermissions(_ file: URL) {
        for suffix in ["", "-wal", "-shm"] {
            let path = file.path + suffix
            if FileManager.default.fileExists(atPath: path) { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path) }
        }
    }

    // MARK: 열기 · 손상 격리

    private static func isCorruption(_ error: BridgeLedgerError) -> Bool {
        switch error {
        case .corrupt: true
        case .sqlite(let code, _): [11, 26].contains(code & 0xFF) // SQLITE_CORRUPT · SQLITE_NOTADB
        case .unknownTask, .unknownCommand, .newerSchema, .locked: false
        }
    }

    private static func openPrepared(_ file: URL) throws -> SQLiteDatabase {
        let db = try SQLiteDatabase(path: file.path)
        do {
            let journal = try db.scalarText("PRAGMA journal_mode=WAL")
            guard journal?.lowercased() == "wal" else { throw BridgeLedgerError.corrupt }
            try db.exec("PRAGMA synchronous=FULL")
            try db.exec("PRAGMA foreign_keys=ON")
            try db.exec("PRAGMA secure_delete=ON")
            guard try db.scalarText("PRAGMA quick_check") == "ok" else { throw BridgeLedgerError.corrupt }
            let version = Int(try db.scalarInt("PRAGMA user_version") ?? 0)
            if version == 0 {
                try db.transaction {
                    for statement in Self.schema { try db.exec(statement) }
                    try db.exec("PRAGMA user_version=\(Self.schemaVersion)")
                    try db.run("INSERT INTO meta (id, schema_version) VALUES (1, ?)", [.n(Self.schemaVersion)])
                }
            } else if version > Self.schemaVersion {
                // 더 새 앱이 만든 원장: 열지 않는다 (지우지도 않는다). 손상이 아니므로 격리하지 않는다 (sqlite 오류 코드 11 · 26과 헷갈리지 않게 따로 둔 오류)
                throw BridgeLedgerError.newerSchema(version: version)
            }
            return db
        } catch {
            db.close()
            throw error
        }
    }

    /// 손상 파일을 옮겨 둔다 (WAL · SHM 포함). 지우지 않는다
    private static func quarantine(_ file: URL, at date: Date) throws -> URL {
        let fileManager = FileManager.default
        let epoch = Int(date.timeIntervalSince1970)
        let target = file.deletingLastPathComponent().appending(path: "ledger.sqlite.corrupt-\(epoch)")
        for suffix in ["", "-wal", "-shm"] {
            let source = URL(fileURLWithPath: file.path + suffix)
            guard fileManager.fileExists(atPath: source.path) else { continue }
            let destination = URL(fileURLWithPath: target.path + suffix)
            try? fileManager.removeItem(at: destination)
            try fileManager.moveItem(at: source, to: destination)
        }
        return target
    }

    public func close() {
        db.close()
        if lockDescriptor >= 0 {
            flock(lockDescriptor, LOCK_UN)
            Darwin.close(lockDescriptor)
            lockDescriptor = -1
        }
    }

    /// WAL을 본 파일에 반영한다 (절전 전, 종료 전)
    public func checkpoint() {
        _ = try? db.scalarText("PRAGMA wal_checkpoint(TRUNCATE)")
    }

    #if DEBUG
    /// 시험 전용: 이 글이 들어간 쓰기 문장을 `skip`번 건너뛴 뒤 한 번 실패시킨다 (여러 행을 한 트랜잭션으로 쓰는지 본다)
    public func debugFailWrite(containing text: String, after skip: Int = 0) {
        db.faultSubstring = text
        db.faultSkip = skip
    }
    #endif

    public func diagnostics() throws -> LedgerDiagnostics {
        LedgerDiagnostics(
            journalMode: try db.scalarText("PRAGMA journal_mode") ?? "",
            synchronous: Int(try db.scalarInt("PRAGMA synchronous") ?? -1),
            foreignKeys: (try db.scalarInt("PRAGMA foreign_keys") ?? 0) == 1,
            schemaVersion: Int(try db.scalarInt("PRAGMA user_version") ?? 0),
            quickCheck: try db.scalarText("PRAGMA quick_check") ?? ""
        )
    }

    // MARK: meta

    public func meta() throws -> BridgeLedgerMeta {
        try db.rows(
            """
            SELECT schema_version, bridge_id, registered_at, clock_offset_ms, last_heartbeat_ok_at, adapters_report_hash,
                   heartbeat_interval_seconds, unreachable_after_seconds, long_poll_max_seconds FROM meta WHERE id = 1
            """
        ) { row in
            var meta = BridgeLedgerMeta(schemaVersion: Int(row.int(0)))
            meta.bridgeID = row.text(1)
            meta.registeredAt = row.optionalDate(2)
            meta.clockOffsetMS = row.optionalInt(3).map(Int.init)
            meta.lastHeartbeatOKAt = row.optionalDate(4)
            meta.adaptersReportHash = row.text(5)
            meta.heartbeatIntervalSeconds = row.optionalInt(6).map(Int.init)
            meta.unreachableAfterSeconds = row.optionalInt(7).map(Int.init)
            meta.longPollMaxSeconds = row.optionalInt(8).map(Int.init)
            return meta
        }.first ?? BridgeLedgerMeta(schemaVersion: Self.schemaVersion)
    }

    public func updateMeta(_ change: @Sendable (inout BridgeLedgerMeta) -> Void) throws {
        var meta = try meta()
        change(&meta)
        try db.run(
            """
            UPDATE meta SET schema_version = ?, bridge_id = ?, registered_at = ?, clock_offset_ms = ?, last_heartbeat_ok_at = ?,
                adapters_report_hash = ?, heartbeat_interval_seconds = ?, unreachable_after_seconds = ?, long_poll_max_seconds = ? WHERE id = 1
            """,
            [
                .n(meta.schemaVersion), .optional(meta.bridgeID), .optional(meta.registeredAt), .optionalN(meta.clockOffsetMS),
                .optional(meta.lastHeartbeatOKAt), .optional(meta.adaptersReportHash), .optionalN(meta.heartbeatIntervalSeconds),
                .optionalN(meta.unreachableAfterSeconds), .optionalN(meta.longPollMaxSeconds),
            ]
        )
    }

    // MARK: commands

    private static let commandColumns = """
        command_id, kind, agent_session_id, agent_task_id, turn_seq, cursor, step_id, adapter, marker, state, state_at, reason, lease_expires_at,
        server_created_at, wake_source, wake_at, listed_at, lease_requested_at, leased_at, server_leased_at, spawn_at, input_at, answer_sent_at,
        signal_at, ack_op, ack_result, ack_final_at
        """

    private static func command(from row: SQLRow) -> BridgeCommandRecord {
        var record = BridgeCommandRecord(
            commandID: row.requiredText(0), kind: row.requiredText(1), agentSessionID: row.requiredText(2), agentTaskID: row.requiredText(3),
            turnSeq: Int(row.int(4)), cursor: Int(row.int(5)), state: BridgeCommandState(rawValue: row.requiredText(9)) ?? .seen, stateAt: row.date(10)
        )
        record.stepID = row.text(6)
        record.adapter = row.text(7)
        record.marker = row.text(8)
        record.reason = row.text(11)
        record.leaseExpiresAt = row.optionalDate(12)
        record.serverCreatedAt = row.optionalDate(13)
        record.wakeSource = row.text(14)
        record.wakeAt = row.optionalDate(15)
        record.listedAt = row.optionalDate(16)
        record.leaseRequestedAt = row.optionalDate(17)
        record.leasedAt = row.optionalDate(18)
        record.serverLeasedAt = row.optionalDate(19)
        record.spawnAt = row.optionalDate(20)
        record.inputAt = row.optionalDate(21)
        record.answerSentAt = row.optionalDate(22)
        record.signalAt = row.optionalDate(23)
        record.ackOp = row.text(24)
        record.ackResult = row.text(25)
        record.ackFinalAt = row.optionalDate(26)
        return record
    }

    private static func binds(_ r: BridgeCommandRecord) -> [SQLValue] {
        [
            .text(r.commandID), .text(r.kind), .text(r.agentSessionID), .text(r.agentTaskID), .n(r.turnSeq), .n(r.cursor), .optional(r.stepID),
            .optional(r.adapter), .optional(r.marker), .text(r.state.rawValue), .date(r.stateAt), .optional(r.reason), .optional(r.leaseExpiresAt),
            .optional(r.serverCreatedAt), .optional(r.wakeSource), .optional(r.wakeAt), .optional(r.listedAt), .optional(r.leaseRequestedAt),
            .optional(r.leasedAt), .optional(r.serverLeasedAt), .optional(r.spawnAt), .optional(r.inputAt), .optional(r.answerSentAt),
            .optional(r.signalAt), .optional(r.ackOp), .optional(r.ackResult), .optional(r.ackFinalAt),
        ]
    }

    public func command(_ id: String) throws -> BridgeCommandRecord? {
        try db.rows("SELECT \(Self.commandColumns) FROM commands WHERE command_id = ?", [.text(id)], Self.command(from:)).first
    }

    public func allCommands() throws -> [BridgeCommandRecord] {
        try db.rows("SELECT \(Self.commandColumns) FROM commands ORDER BY cursor, command_id", [], Self.command(from:))
    }

    /// 아직 더 할 일이 있는 명령 (옆길 · settled 제외)
    public func activeCommands() throws -> [BridgeCommandRecord] {
        let finished = BridgeCommandState.allCases.filter(\.isFinished).map { "'\($0.rawValue)'" }.joined(separator: ",")
        return try db.rows("SELECT \(Self.commandColumns) FROM commands WHERE state NOT IN (\(finished)) ORDER BY cursor, command_id", [], Self.command(from:))
    }

    public func saveCommand(_ record: BridgeCommandRecord) throws {
        let placeholders = Array(repeating: "?", count: 27).joined(separator: ",")
        try db.run("INSERT OR REPLACE INTO commands (\(Self.commandColumns)) VALUES (\(placeholders))", Self.binds(record))
    }

    @discardableResult
    public func updateCommand(_ id: String, _ change: @Sendable (inout BridgeCommandRecord) -> Void) throws -> BridgeCommandRecord? {
        guard var record = try command(id) else { return nil }
        change(&record)
        try saveCommand(record)
        return record
    }

    /// 접수 전 `ended`로 끝난 명령 중 보낼 사건이 더 없는 것을 `settled`로 (drain 모드가 끝나는 조건)
    @discardableResult
    public func settleEndedCommands() throws -> Int {
        try db.run(
            """
            UPDATE commands SET state = 'settled', state_at = ? WHERE state = 'ended' AND NOT EXISTS (
                SELECT 1 FROM outbox o WHERE o.agent_task_id = commands.agent_task_id AND o.dead_reason IS NULL)
            """,
            [.date(now())]
        )
    }

    // MARK: tasks

    private static let taskColumns = """
        agent_task_id, agent_session_id, adapter, turn_seq, external_session_id, workspace_ref, external_task_id, pid, process_started_at,
        process_marker, alive, last_seq, last_state, accepted_at, current_command_id, open_request_id, open_request_kind, open_request_secret,
        closed_request_ids, cancel_state, server_unknown_at, reconcile_count, segment_terminal, updated_at
        """

    private static func task(from row: SQLRow) -> BridgeTaskRecord {
        var record = BridgeTaskRecord(
            agentTaskID: row.requiredText(0), agentSessionID: row.requiredText(1), adapter: row.requiredText(2), turnSeq: Int(row.int(3)),
            updatedAt: row.date(23)
        )
        record.externalSessionID = row.text(4)
        record.workspaceRef = row.text(5)
        record.externalTaskID = row.text(6)
        record.pid = row.optionalInt(7).map(Int.init)
        record.processStartedAt = row.optionalDate(8)
        record.processMarker = row.text(9)
        record.alive = row.bool(10)
        record.lastSeq = Int(row.int(11))
        record.lastState = row.requiredText(12)
        record.acceptedAt = row.optionalDate(13)
        record.currentCommandID = row.text(14)
        record.openRequestID = row.text(15)
        record.openRequestKind = row.text(16)
        record.openRequestSecret = row.bool(17)
        record.closedRequestIDs = row.text(18).flatMap { try? JSONDecoder().decode([String].self, from: Data($0.utf8)) } ?? []
        record.cancelState = row.text(19)
        record.serverUnknownAt = row.optionalDate(20)
        record.reconcileCount = Int(row.int(21))
        record.segmentTerminal = row.text(22)
        return record
    }

    private static func binds(_ r: BridgeTaskRecord) -> [SQLValue] {
        let closed = (try? JSONEncoder().encode(r.closedRequestIDs)).map { String(decoding: $0, as: UTF8.self) } ?? "[]"
        return [
            .text(r.agentTaskID), .text(r.agentSessionID), .text(r.adapter), .n(r.turnSeq), .optional(r.externalSessionID), .optional(r.workspaceRef),
            .optional(r.externalTaskID), .optionalN(r.pid), .optional(r.processStartedAt), .optional(r.processMarker), .bool(r.alive), .n(r.lastSeq),
            .text(r.lastState), .optional(r.acceptedAt), .optional(r.currentCommandID), .optional(r.openRequestID), .optional(r.openRequestKind),
            .bool(r.openRequestSecret), .text(closed), .optional(r.cancelState), .optional(r.serverUnknownAt), .n(r.reconcileCount),
            .optional(r.segmentTerminal), .date(r.updatedAt),
        ]
    }

    public func task(_ id: String) throws -> BridgeTaskRecord? {
        try db.rows("SELECT \(Self.taskColumns) FROM tasks WHERE agent_task_id = ?", [.text(id)], Self.task(from:)).first
    }

    public func allTasks() throws -> [BridgeTaskRecord] {
        try db.rows("SELECT \(Self.taskColumns) FROM tasks ORDER BY updated_at DESC, agent_task_id", [], Self.task(from:))
    }

    public func saveTask(_ record: BridgeTaskRecord) throws {
        let placeholders = Array(repeating: "?", count: 24).joined(separator: ",")
        try db.run("INSERT OR REPLACE INTO tasks (\(Self.taskColumns)) VALUES (\(placeholders))", Self.binds(record))
    }

    @discardableResult
    public func updateTask(_ id: String, _ change: @Sendable (inout BridgeTaskRecord) -> Void) throws -> BridgeTaskRecord? {
        guard var record = try task(id) else { return nil }
        change(&record)
        record.updatedAt = now()
        try saveTask(record)
        return record
    }

    /// "run 시작" 한 번: task(살아 있음 · 이번 명령 · 구간 초기화)와 명령(`start_intent`) 두 행을 **한 트랜잭션**으로 쓴다 (메시지 · 답 둘 다).
    /// 둘 중 하나만 적히고 죽으면 "프로세스를 띄웠을 수 있는데 명령은 아직 lease 상태" 같은 모순이 생기므로 함께 아니면 둘 다 없다
    public func beginRun(
        taskID: String, task change: @Sendable (inout BridgeTaskRecord) -> Void, commandID: String, command commandChange: @Sendable (inout BridgeCommandRecord) -> Void
    ) throws {
        try db.transaction {
            guard var task = try task(taskID) else { throw BridgeLedgerError.unknownTask(taskID) }
            change(&task)
            task.updatedAt = now()
            try saveTask(task)
            guard var record = try command(commandID) else { throw BridgeLedgerError.unknownCommand(commandID) }
            commandChange(&record)
            try saveCommand(record)
        }
    }

    /// 같은 세션에 살아 있는 실행 (writer 하나, 계약 13.1). `taskID`는 건너뛴다 (그 task에 오는 답은 같은 실행의 이어짐이다)
    public func liveTask(inSession sessionID: String, excluding taskID: String?) throws -> BridgeTaskRecord? {
        try db.rows(
            "SELECT \(Self.taskColumns) FROM tasks WHERE alive = 1 AND agent_session_id = ? AND agent_task_id != ? ORDER BY updated_at DESC LIMIT 1",
            [.text(sessionID), .text(taskID ?? "")], Self.task(from:)
        ).first
    }

    // MARK: outbox

    private static let outboxColumns = "key, event_id, agent_session_id, agent_task_id, seq, type, body_json, bytes, observed_at, attempts, next_attempt_at, last_status, dead_reason"

    private static func outbox(from row: SQLRow) -> OutboxRow {
        OutboxRow(
            key: row.int(0), eventID: row.requiredText(1), agentSessionID: row.requiredText(2), agentTaskID: row.text(3), seq: row.optionalInt(4).map(Int.init),
            type: row.requiredText(5), bodyJSON: row.requiredText(6), bytes: Int(row.int(7)), observedAt: row.date(8), attempts: Int(row.int(9)),
            nextAttemptAt: row.date(10), lastStatus: row.text(11), deadReason: row.text(12)
        )
    }

    /// 한 트랜잭션: 번호 매기기 → 사건 만들기 → outbox 행 → (잘렸으면) 전체 글 → task 갱신 (계약 2.5 "사건마다 한 트랜잭션")
    public func appendEvent(
        taskID: String, numbering: EventNumbering, build: @Sendable (_ seq: Int?, _ eventID: String) throws -> BuiltEvent,
        update: @Sendable (inout BridgeTaskRecord) -> Void, command: (id: String, change: @Sendable (inout BridgeCommandRecord) -> Void)? = nil
    ) throws -> OutboxRow {
        try db.transaction {
            guard var task = try task(taskID) else { throw BridgeLedgerError.unknownTask(taskID) }
            let seq: Int?
            let eventID: String
            switch numbering {
            case .taskSequence:
                task.lastSeq += 1
                seq = task.lastSeq
                eventID = "\(taskID):\(task.lastSeq)"
            case .sessionScoped:
                let name = "session:\(task.agentSessionID):s"
                let next = Int(try db.scalarInt("SELECT value FROM counters WHERE name = ?", [.text(name)]) ?? 0) + 1
                try db.run("INSERT OR REPLACE INTO counters (name, value) VALUES (?, ?)", [.text(name), .n(next)])
                seq = nil
                eventID = "\(task.agentSessionID):s\(next)"
            case .reconcile:
                task.reconcileCount += 1
                seq = nil
                eventID = "\(taskID):r\(task.reconcileCount)"
            }
            let built = try build(seq, eventID)
            let created = now()
            try db.run(
                """
                INSERT INTO outbox (event_id, agent_session_id, agent_task_id, seq, type, body_json, bytes, observed_at, created_at, next_attempt_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                [
                    .text(eventID), .text(task.agentSessionID), .text(taskID), .optionalN(seq), .text(built.type), .text(built.json),
                    .n(built.json.utf8.count), .date(built.observedAt), .date(created), .date(created),
                ]
            )
            let key = db.lastInsertRowID
            if let full = built.fullText {
                try db.run("INSERT OR REPLACE INTO full_texts (event_id, agent_task_id, text, created_at) VALUES (?, ?, ?, ?)", [.text(eventID), .text(taskID), .text(full), .date(created)])
            }
            update(&task)
            task.updatedAt = created
            try saveTask(task)
            if let command, var record = try self.command(command.id) {
                command.change(&record)
                try saveCommand(record)
            }
            return OutboxRow(
                key: key, eventID: eventID, agentSessionID: task.agentSessionID, agentTaskID: taskID, seq: seq, type: built.type, bodyJSON: built.json,
                bytes: built.json.utf8.count, observedAt: built.observedAt, attempts: 0, nextAttemptAt: created, lastStatus: nil, deadReason: nil
            )
        }
    }

    /// 삽입 순서. 죽은 행(dead-letter)은 `includeDead`일 때만. `limit`은 앞에서부터
    public func outboxRows(includeDead: Bool = false, limit: Int? = nil) throws -> [OutboxRow] {
        let filter = includeDead ? "" : "WHERE dead_reason IS NULL"
        let tail = limit.map { " LIMIT \($0)" } ?? ""
        return try db.rows("SELECT \(Self.outboxColumns) FROM outbox \(filter) ORDER BY key\(tail)", [], Self.outbox(from:))
    }

    public func outboxRows(forTask taskID: String) throws -> [OutboxRow] {
        try db.rows("SELECT \(Self.outboxColumns) FROM outbox WHERE agent_task_id = ? AND dead_reason IS NULL ORDER BY key", [.text(taskID)], Self.outbox(from:))
    }

    public func removeOutbox(keys: [Int64]) throws {
        guard !keys.isEmpty else { return }
        try db.transaction {
            for key in keys { try db.run("DELETE FROM outbox WHERE key = ?", [.int(key)]) }
        }
    }

    /// 시도 횟수를 올리고 다음 시도를 미룬다
    public func recordOutboxFailure(keys: [Int64], nextAttemptAt: Date, status: String?) throws {
        guard !keys.isEmpty else { return }
        try db.transaction {
            for key in keys {
                try db.run(
                    "UPDATE outbox SET attempts = attempts + 1, next_attempt_at = ?, last_status = ? WHERE key = ?",
                    [.date(nextAttemptAt), .optional(status), .int(key)]
                )
            }
        }
    }

    /// 다시 보내지 않는다 (서버가 모양을 거절). 7일 뒤 지운다
    public func markOutboxDead(keys: [Int64], reason: String) throws {
        guard !keys.isEmpty else { return }
        let at = now()
        try db.transaction {
            for key in keys { try db.run("UPDATE outbox SET dead_reason = ?, dead_at = ? WHERE key = ?", [.text(reason), .date(at), .int(key)]) }
        }
    }

    // MARK: ack outbox

    /// ack도 먼저 적고 보낸다. 명령에는 무엇을 보고하려는지 남긴다 (같은 명령에 `unknown`을 두 번 보내지 않기 위해)
    /// `saving`이 있으면 그 명령 기록(예: 원장 분실로 만든 `declined`)과 ack를 **한 트랜잭션**으로 쓴다: 기록만 있고 ack가 없는 반쪽 상태가 남지 않는다
    @discardableResult
    public func enqueueAck(commandID: String, op: String, result: String?, bodyJSON: String, saving record: BridgeCommandRecord? = nil) throws -> Int64 {
        try db.transaction {
            if let record { try saveCommand(record) }
            try db.run(
                "INSERT INTO ack_outbox (command_id, op, body_json, next_attempt_at) VALUES (?, ?, ?, ?)",
                [.text(commandID), .text(op), .text(bodyJSON), .date(now())]
            )
            let key = db.lastInsertRowID
            try db.run("UPDATE commands SET ack_op = ?, ack_result = ? WHERE command_id = ?", [.text(op), .optional(result), .text(commandID)])
            return key
        }
    }

    public func dueAcks(now: Date, limit: Int) throws -> [AckRow] {
        try db.rows(
            "SELECT key, command_id, op, body_json, attempts, next_attempt_at FROM ack_outbox WHERE next_attempt_at <= ? ORDER BY key LIMIT ?",
            [.date(now), .n(limit)]
        ) { AckRow(key: $0.int(0), commandID: $0.requiredText(1), op: $0.requiredText(2), bodyJSON: $0.requiredText(3), attempts: Int($0.int(4)), nextAttemptAt: $0.date(5)) }
    }

    public func allAcks() throws -> [AckRow] {
        try dueAcks(now: Date.distantFuture, limit: 10_000)
    }

    public func recordAckFailure(key: Int64, nextAttemptAt: Date) throws {
        try db.run("UPDATE ack_outbox SET attempts = attempts + 1, next_attempt_at = ? WHERE key = ?", [.date(nextAttemptAt), .int(key)])
    }

    /// ack가 최종 분류를 받음: 행을 지우고 명령에 끝난 시각 · 새 상태를 적는다
    public func settleAck(key: Int64, commandState: BridgeCommandState?, reason: String?) throws {
        let at = now()
        try db.transaction {
            let commandID = try db.rows("SELECT command_id FROM ack_outbox WHERE key = ?", [.int(key)]) { $0.requiredText(0) }.first
            try db.run("DELETE FROM ack_outbox WHERE key = ?", [.int(key)])
            guard let commandID else { return }
            if let commandState {
                try db.run(
                    "UPDATE commands SET ack_final_at = ?, state = ?, state_at = ?, reason = COALESCE(?, reason) WHERE command_id = ?",
                    [.date(at), .text(commandState.rawValue), .date(at), .optional(reason), .text(commandID)]
                )
            } else {
                try db.run("UPDATE commands SET ack_final_at = ? WHERE command_id = ?", [.date(at), .text(commandID)])
            }
        }
    }

    // MARK: 전체 글 · 질문 원래 값

    public func fullText(eventID: String) throws -> String? {
        try db.scalarText("SELECT text FROM full_texts WHERE event_id = ?", [.text(eventID)])
    }

    public func saveQuestionMap(taskID: String, requestID: String, mappingJSON: String) throws {
        try db.run(
            "INSERT OR REPLACE INTO question_maps (agent_task_id, provider_request_id, mapping_json) VALUES (?, ?, ?)",
            [.text(taskID), .text(requestID), .text(mappingJSON)]
        )
    }

    public func questionMap(taskID: String, requestID: String) throws -> String? {
        try db.scalarText("SELECT mapping_json FROM question_maps WHERE agent_task_id = ? AND provider_request_id = ?", [.text(taskID), .text(requestID)])
    }

    // MARK: 보관 정리 · 할 일

    /// 끝난 명령 7일 · 죽은 outbox 행 7일 · 보내지 못한 사건 7일(Q16 A) · 전체 글 30일, 그리고 파티션당 크기 상한(오래된 전체 글부터)
    @discardableResult
    public func prune(now at: Date) throws -> PruneReport {
        var report = PruneReport()
        let week = at.addingTimeInterval(-7 * Self.day)
        let month = at.addingTimeInterval(-30 * Self.day)
        let finished = BridgeCommandState.allCases.filter(\.isFinished).map { "'\($0.rawValue)'" }.joined(separator: ",")
        try db.transaction {
            report.commands = try db.run("DELETE FROM commands WHERE state IN (\(finished)) AND state_at < ?", [.date(week)])
            report.deadLetters = try db.run("DELETE FROM outbox WHERE dead_reason IS NOT NULL AND dead_at < ?", [.date(week)])
            report.expiredEvents = try db.run(
                "UPDATE outbox SET dead_reason = 'outbox_expired', dead_at = ? WHERE dead_reason IS NULL AND created_at < ?", [.date(at), .date(week)]
            )
            report.fullTexts = try db.run("DELETE FROM full_texts WHERE created_at < ?", [.date(month)])
            // 끝난 task(살아 있지 않고 7일 넘게 바뀌지 않았으며 보낼 사건 · 끝나지 않은 명령이 없는 것)와 그 질문 원래 값, 더는 task가 없는 세션의 사건 번호표.
            // 접수 전에 조용히 끝난 `dispatched`와 답을 기다리다 버려진 `awaiting_answer`도 기한이 지나면 지운다 (heartbeat · reconcile에 영원히 남지 않게)
            report.tasks = try db.run(
                """
                DELETE FROM tasks WHERE alive = 0 AND updated_at < ? AND last_state IN ('idle', 'failed', 'cancelled', 'dispatched', 'awaiting_answer')
                  AND NOT EXISTS (SELECT 1 FROM outbox o WHERE o.agent_task_id = tasks.agent_task_id)
                  AND NOT EXISTS (SELECT 1 FROM commands c WHERE c.agent_task_id = tasks.agent_task_id AND c.state NOT IN (\(finished)))
                """,
                [.date(week)]
            )
            report.questionMaps = try db.run("DELETE FROM question_maps WHERE agent_task_id NOT IN (SELECT agent_task_id FROM tasks)")
            report.counters = try db.run(
                "DELETE FROM counters WHERE name LIKE 'session:%:s' AND substr(name, 9, length(name) - 10) NOT IN (SELECT agent_session_id FROM tasks)"
            )
        }
        report.corruptFiles = pruneQuarantinedFiles(now: at)
        // 크기 상한: 쓰는 쪽만 센다 (지운 쪽은 빈 쪽 목록으로 간다)
        while try usedBytes() > byteLimit {
            let removed = try db.run(
                "DELETE FROM full_texts WHERE event_id IN (SELECT event_id FROM full_texts ORDER BY created_at, event_id LIMIT 1)"
            )
            if removed == 0 { break }
            report.fullTexts += removed
        }
        return report
    }

    /// 손상으로 옮겨 둔 `ledger.sqlite.corrupt-<epoch>`(+WAL · SHM)는 7일 뒤 지운다 (사용자 데이터가 폴더에 영원히 남지 않게). 지운 파일 수(묶음 단위)
    private func pruneQuarantinedFiles(now at: Date) -> Int {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        var removed = 0
        for name in names where name.hasPrefix("ledger.sqlite.corrupt-") {
            let rest = name.dropFirst("ledger.sqlite.corrupt-".count)
            let digits = rest.prefix { $0.isNumber }
            guard let epoch = TimeInterval(digits), at.timeIntervalSince1970 - epoch > 7 * Self.day else { continue }
            if (try? FileManager.default.removeItem(at: directory.appending(path: name))) != nil, rest == digits { removed += 1 }
        }
        return removed
    }

    private func usedBytes() throws -> Int {
        let pages = try db.scalarInt("PRAGMA page_count") ?? 0
        let free = try db.scalarInt("PRAGMA freelist_count") ?? 0
        let size = try db.scalarInt("PRAGMA page_size") ?? 4096
        return Int((pages - free) * size)
    }

    /// 끝나지 않은 명령 · 보낼 사건 · 보낼 ack · 살아 있는 실행이 있나 (BRIDGE_ENABLED가 꺼졌을 때 마무리 모드가 필요한지, 계약 2.14)
    public func hasPendingWork() throws -> Bool {
        (try db.scalarInt(Self.pendingWorkSQL) ?? 0) > 0
    }

    private static var pendingWorkSQL: String {
        let finished = BridgeCommandState.allCases.filter(\.isFinished).map { "'\($0.rawValue)'" }.joined(separator: ",")
        return """
            SELECT
              (SELECT COUNT(*) FROM commands WHERE state NOT IN (\(finished))) +
              (SELECT COUNT(*) FROM outbox WHERE dead_reason IS NULL) +
              (SELECT COUNT(*) FROM ack_outbox) +
              (SELECT COUNT(*) FROM tasks WHERE alive = 1)
            """
    }

    /// 원장 파일을 **읽기 전용**으로 열어 할 일이 남았는지만 본다: 스키마를 만들지도 손상 파일을 옮기지도 않고 잠금도 잡지 않는다. 읽을 수 없으면 nil (파일이 없거나 손상 · 더 새 스키마)
    static func pendingWork(atFile file: URL) -> Bool? {
        guard FileManager.default.fileExists(atPath: file.path), let db = try? SQLiteDatabase(path: file.path, readOnly: true) else { return nil }
        defer { db.close() }
        do { return (try db.scalarInt(pendingWorkSQL) ?? 0) > 0 } catch { return nil }
    }

    // MARK: 스키마

    private static let schema: [String] = [
        """
        CREATE TABLE meta (
            id INTEGER PRIMARY KEY CHECK (id = 1), schema_version INTEGER NOT NULL, bridge_id TEXT, registered_at INTEGER, clock_offset_ms INTEGER,
            last_heartbeat_ok_at INTEGER, adapters_report_hash TEXT, heartbeat_interval_seconds INTEGER, unreachable_after_seconds INTEGER,
            long_poll_max_seconds INTEGER)
        """,
        """
        CREATE TABLE commands (
            command_id TEXT PRIMARY KEY, kind TEXT NOT NULL, agent_session_id TEXT NOT NULL, agent_task_id TEXT NOT NULL, turn_seq INTEGER NOT NULL,
            cursor INTEGER NOT NULL, step_id TEXT, adapter TEXT, marker TEXT, state TEXT NOT NULL, state_at INTEGER NOT NULL, reason TEXT,
            lease_expires_at INTEGER, server_created_at INTEGER, wake_source TEXT, wake_at INTEGER, listed_at INTEGER, lease_requested_at INTEGER,
            leased_at INTEGER, server_leased_at INTEGER, spawn_at INTEGER, input_at INTEGER, answer_sent_at INTEGER, signal_at INTEGER, ack_op TEXT,
            ack_result TEXT, ack_final_at INTEGER)
        """,
        "CREATE INDEX commands_state ON commands (state)",
        """
        CREATE TABLE tasks (
            agent_task_id TEXT PRIMARY KEY, agent_session_id TEXT NOT NULL, adapter TEXT NOT NULL, turn_seq INTEGER NOT NULL, external_session_id TEXT,
            workspace_ref TEXT, external_task_id TEXT, pid INTEGER, process_started_at INTEGER, process_marker TEXT, alive INTEGER NOT NULL DEFAULT 0,
            last_seq INTEGER NOT NULL DEFAULT 0, last_state TEXT NOT NULL, accepted_at INTEGER, current_command_id TEXT, open_request_id TEXT,
            open_request_kind TEXT, open_request_secret INTEGER NOT NULL DEFAULT 0, closed_request_ids TEXT NOT NULL DEFAULT '[]', cancel_state TEXT,
            server_unknown_at INTEGER, reconcile_count INTEGER NOT NULL DEFAULT 0, segment_terminal TEXT, updated_at INTEGER NOT NULL)
        """,
        "CREATE INDEX tasks_session ON tasks (agent_session_id)",
        """
        CREATE TABLE outbox (
            key INTEGER PRIMARY KEY AUTOINCREMENT, event_id TEXT NOT NULL UNIQUE, agent_session_id TEXT NOT NULL, agent_task_id TEXT, seq INTEGER,
            type TEXT NOT NULL, body_json TEXT NOT NULL, bytes INTEGER NOT NULL, observed_at INTEGER NOT NULL, created_at INTEGER NOT NULL,
            attempts INTEGER NOT NULL DEFAULT 0, next_attempt_at INTEGER NOT NULL, last_status TEXT, dead_reason TEXT, dead_at INTEGER)
        """,
        "CREATE INDEX outbox_task ON outbox (agent_task_id)",
        """
        CREATE TABLE ack_outbox (
            key INTEGER PRIMARY KEY AUTOINCREMENT, command_id TEXT NOT NULL, op TEXT NOT NULL, body_json TEXT NOT NULL,
            attempts INTEGER NOT NULL DEFAULT 0, next_attempt_at INTEGER NOT NULL)
        """,
        "CREATE TABLE full_texts (event_id TEXT PRIMARY KEY, agent_task_id TEXT NOT NULL, text TEXT NOT NULL, created_at INTEGER NOT NULL)",
        """
        CREATE TABLE question_maps (
            agent_task_id TEXT NOT NULL, provider_request_id TEXT NOT NULL, mapping_json TEXT NOT NULL, PRIMARY KEY (agent_task_id, provider_request_id))
        """,
        "CREATE TABLE counters (name TEXT PRIMARY KEY, value INTEGER NOT NULL)",
    ]
}
#endif
