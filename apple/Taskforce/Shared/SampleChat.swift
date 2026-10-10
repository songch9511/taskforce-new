#if DEBUG
import Foundation
import TaskforceKit

/// 디자인 비교 · 격리 확인용 가짜 서버 (Debug 빌드, `-TFSampleData`): 대화 · 기억을 메모리에서 서버처럼 돌려준다. 네트워크 · 계정 · 실제 AI 호출 없음.
/// 확인 · 정정 · 잊기 · 범위 옮기기 · 보내기가 실제 서버 계약대로 (version 확인 · 새 행 · 후속 행) 메모리 안에서 돌아, 격리 실행에서 포인터 · 키보드로 눌러 볼 수 있다.
/// `scenario`는 스냅샷이 상태를 바꿔 가며 담는 데 쓴다 (실사용 앱의 저장소 · 설정은 건드리지 않는다)
actor SampleChatGateway: ChatGateway {
    enum Scenario: String, Sendable {
        /// 대화 셋 + 기억 셋
        case full
        /// 대화 없음 · 기억 없음
        case empty
        /// 읽기가 오프라인 / 서버 오류
        case offline, failed
        /// 대화는 읽히지만 쓰기가 gate 꺼짐(404)
        case featureOff
        /// 보내기가 끝나지 않는다 ("Sending…")
        case sendHangs
        /// 보내기가 전송 오류로 실패한다
        case sendFails
        /// 보내기가 동의 전 409
        case consentNeeded
    }

    private var scenario: Scenario
    private var memory: [MemoryItem]
    private var conversationRows: [ChatConversation]
    private var messageRows: [UUID: [ChatMessage]]
    private var nextSeq = 10
    private var nextMemory = 100

    /// 스냅샷이 상태를 바꿔 가며 담는다: 시나리오를 바꾸고 서버 쪽 데이터를 처음으로 되돌린다
    func setScenario(_ scenario: Scenario) {
        self.scenario = scenario
        memory = SampleChatIDs.memory
        conversationRows = SampleChatIDs.conversations
        messageRows = SampleChatIDs.messages
    }

    init(scenario: Scenario = .full) {
        self.scenario = scenario
        memory = SampleChatIDs.memory
        conversationRows = SampleChatIDs.conversations
        messageRows = SampleChatIDs.messages
    }

    private func read<T>(_ value: () -> T) throws -> T {
        switch scenario {
        case .offline: throw URLError(.notConnectedToInternet)
        case .failed: throw APIError.server(status: 500, code: .internalError, message: "x")
        default: return value()
        }
    }

    // MARK: 읽기

    func conversations() async throws -> [ChatConversation] {
        try read { scenario == .empty ? [] : conversationRows }
    }

    func lastMessages(conversationIDs: [UUID]) async throws -> [UUID: ChatMessage] {
        try read {
            var result: [UUID: ChatMessage] = [:]
            for id in conversationIDs { if let last = messageRows[id]?.last { result[id] = last } }
            return result
        }
    }

    func messages(conversationID: UUID) async throws -> [ChatMessage] { try read { messageRows[conversationID] ?? [] } }

    func message(id: UUID) async throws -> ChatMessage? {
        try read { messageRows.values.joined().first { $0.id == id } }
    }

    func workContexts() async throws -> [WorkContext] {
        try read { [WorkContext(id: SampleChatIDs.shapeLaunch, name: "Shape launch"), WorkContext(id: SampleChatIDs.acme, name: "Acme website")] }
    }

    func currentMemoryItems() async throws -> [MemoryItem] {
        try read { scenario == .empty ? [] : memory.filter(\.isCurrent) }
    }

    func memoryItems(ids: [UUID]) async throws -> [MemoryItem] { try read { memory.filter { ids.contains($0.id) } } }

    func memorySource(id: UUID) async throws -> MemorySource? {
        try read { SampleChatIDs.sources[id] }
    }

    // MARK: 쓰기

    private func writeGate() throws {
        if scenario == .featureOff { throw APIError.server(status: 404, code: .notFound, message: APIError.featureOffMessage) }
    }

    func createConversation(id: UUID, title: String?, contextID: UUID?) async throws -> ChatConversation {
        try writeGate()
        if let existing = conversationRows.first(where: { $0.id == id }) { return existing }
        let row = ChatConversation(id: id, title: title, contextID: contextID, createdAt: Date())
        conversationRows.append(row)
        return row
    }

    func updateConversation(id: UUID, contextID: UUID?) async throws -> ChatConversation {
        try writeGate()
        guard let index = conversationRows.firstIndex(where: { $0.id == id }) else { throw APIError.server(status: 404, code: .notFound, message: "x") }
        let old = conversationRows[index]
        conversationRows[index] = ChatConversation(
            id: old.id, title: old.title, contextID: contextID, createdAt: old.createdAt, lastMessageAt: old.lastMessageAt, lastReadAt: old.lastReadAt,
            archivedAt: old.archivedAt, textPurgedAt: old.textPurgedAt
        )
        return conversationRows[index]
    }

    func postChatMessage(conversationID: UUID, clientMessageID: UUID, text: String) async throws -> ChatPostedMessage {
        try writeGate()
        switch scenario {
        case .sendHangs:
            // 응답이 오지 않는다 (취소되면 끝난다)
            try await Task.sleep(for: .seconds(3600))
        case .sendFails:
            throw APIError.transport("offline")
        case .consentNeeded:
            throw APIError.server(status: 409, code: .conflict, message: APIError.consentRequiredMessage)
        default:
            break
        }
        // 같은 제출은 저장된 쌍을 돌려준다
        if let user = messageRows[conversationID]?.first(where: { $0.clientMessageID == clientMessageID }),
           let reply = messageRows[conversationID]?.first(where: { $0.replyTo == user.id }) {
            return ChatPostedMessage(message: user, reply: reply)
        }
        let now = Date()
        nextSeq += 2
        let user = ChatMessage(
            id: UUID(), conversationID: conversationID, seq: nextSeq, role: .user, clientMessageID: clientMessageID, text: text, createdAt: now
        )
        let reply = ChatMessage(
            id: UUID(), conversationID: conversationID, seq: nextSeq + 1, role: .assistant, text: "Noted. This is a sample reply from the isolated fake server.",
            createdAt: now.addingTimeInterval(1), replyTo: user.id
        )
        messageRows[conversationID, default: []] += [user, reply]
        if let index = conversationRows.firstIndex(where: { $0.id == conversationID }) {
            let old = conversationRows[index]
            conversationRows[index] = ChatConversation(
                id: old.id, title: old.title, contextID: old.contextID, createdAt: old.createdAt, lastMessageAt: now, lastReadAt: old.lastReadAt,
                archivedAt: old.archivedAt, textPurgedAt: old.textPurgedAt
            )
        }
        return ChatPostedMessage(message: user, reply: reply)
    }

    private func row(_ id: UUID, version: Int) throws -> (index: Int, item: MemoryItem) {
        try writeGate()
        guard let index = memory.firstIndex(where: { $0.id == id }) else { throw APIError.server(status: 404, code: .notFound, message: "기억이 없습니다.") }
        let item = memory[index]
        guard item.isCurrent, item.version == version else { throw APIError.server(status: 409, code: .conflict, message: "x") }
        return (index, item)
    }

    private func replace(_ index: Int, with newRow: MemoryItem) -> MemoryItem {
        let old = memory[index]
        memory[index] = MemoryItem(
            id: old.id, scopeKind: old.scopeKind, contextID: old.contextID, statement: old.statement, value: old.value, origin: old.origin,
            sourceRef: old.sourceRef, observedAt: old.observedAt, supersededBy: newRow.id, supersededAt: Date(), revokedAt: nil,
            confidence: old.confidence, sourcePurged: old.sourcePurged, version: old.version + 1, createdAt: old.createdAt
        )
        memory.append(newRow)
        return newRow
    }

    private func freshID() -> UUID {
        nextMemory += 1
        return UUID(uuidString: String(format: "C1A90000-0000-4000-8000-%012d", nextMemory))!
    }

    func confirmMemory(id: UUID, expectedVersion: Int) async throws -> MemoryItem {
        let (index, item) = try row(id, version: expectedVersion)
        guard item.origin == .inferred else { throw APIError.server(status: 409, code: .confirmUnavailable, message: "x") }
        return replace(index, with: MemoryItem(
            id: freshID(), scopeKind: item.scopeKind, contextID: item.contextID, statement: item.statement, origin: .explicit, sourceRef: item.sourceRef,
            observedAt: Date()
        ))
    }

    func editMemory(id: UUID, edit: MemoryEdit) async throws -> MemoryItem {
        let (index, item) = try row(id, version: edit.expectedVersion)
        return replace(index, with: MemoryItem(
            id: freshID(), scopeKind: item.scopeKind, contextID: item.contextID, statement: edit.statement, origin: .explicit, observedAt: Date()
        ))
    }

    func forgetMemory(id: UUID, expectedVersion: Int) async throws -> MemoryItem {
        let (index, item) = try row(id, version: expectedVersion)
        memory[index] = MemoryItem(
            id: item.id, scopeKind: item.scopeKind, contextID: item.contextID, statement: item.statement, value: item.value, origin: item.origin,
            sourceRef: item.sourceRef, observedAt: item.observedAt, revokedAt: Date(), confidence: item.confidence, sourcePurged: item.sourcePurged,
            version: item.version + 1, createdAt: item.createdAt
        )
        return memory[index]
    }

    func moveMemory(id: UUID, expectedVersion: Int, to target: MemoryTarget) async throws -> MemoryItem {
        let (index, item) = try row(id, version: expectedVersion)
        guard item.origin == .explicit else { throw APIError.server(status: 409, code: .scopeUnavailable, message: "x") }
        memory[index] = MemoryItem(
            id: item.id, scopeKind: item.scopeKind, contextID: item.contextID, statement: item.statement, value: item.value, origin: item.origin,
            sourceRef: item.sourceRef, observedAt: item.observedAt, revokedAt: Date(), version: item.version + 1, createdAt: item.createdAt
        )
        let moved: MemoryItem
        switch target {
        case .global:
            moved = MemoryItem(
                id: freshID(), scopeKind: .global, statement: item.statement, value: .object(["moved_from": .string(item.id.uuidString.lowercased())]),
                origin: .explicit, observedAt: item.observedAt
            )
        case .context(let context):
            moved = MemoryItem(
                id: freshID(), scopeKind: .context, contextID: context, statement: item.statement,
                value: .object(["moved_from": .string(item.id.uuidString.lowercased())]), origin: .explicit, observedAt: item.observedAt
            )
        }
        memory.append(moved)
        return moved
    }
}

/// 견본 데이터 (디자인 ChatPage · SettingsPage의 MEMORIES · CHATS 그대로): 고정 id · 날짜
enum SampleChatIDs {
    static let shape = UUID(uuidString: "BCB50000-0000-4000-8000-000000000001")!
    static let copy = UUID(uuidString: "BCB50000-0000-4000-8000-000000000002")!
    static let blank = UUID(uuidString: "BCB50000-0000-4000-8000-000000000003")!
    static let shapeLaunch = UUID(uuidString: "09D60000-0000-4000-8000-000000000001")!
    static let acme = UUID(uuidString: "09D60000-0000-4000-8000-000000000002")!
    static let keepsShort = UUID(uuidString: "C1A90000-0000-4000-8000-000000000001")!
    static let thursdays = UUID(uuidString: "C1A90000-0000-4000-8000-000000000002")!
    static let jordan = UUID(uuidString: "C1A90000-0000-4000-8000-000000000003")!
    static let copyQuestion = UUID(uuidString: "AAAA0000-0000-4000-8000-000000000004")!
    static let chatUtterance = UUID(uuidString: "AAAA0000-0000-4000-8000-000000000001")!
    static let calendarSource = UUID(uuidString: "B1C10000-0000-4000-8000-000000000001")!
    static let gmailSource = UUID(uuidString: "B1C10000-0000-4000-8000-000000000002")!

    private static func date(_ month: Int, _ day: Int, _ hour: Int = 10, _ minute: Int = 24) -> Date {
        var components = DateComponents(year: 2026, month: month, day: day, hour: hour, minute: minute)
        components.timeZone = TimeZone.current
        return Calendar(identifier: .gregorian).date(from: components) ?? Date()
    }

    static let conversations: [ChatConversation] = [
        ChatConversation(id: copy, title: "Pricing copy check", createdAt: date(10, 8), lastMessageAt: date(10, 8, 11, 2)),
        ChatConversation(id: blank, title: nil, createdAt: date(10, 8, 9, 0)),
        ChatConversation(id: shape, title: "Shape design priorities", contextID: shapeLaunch, createdAt: date(9, 30), lastMessageAt: date(9, 30, 18, 5)),
    ]

    static let messages: [UUID: [ChatMessage]] = [
        shape: [
            ChatMessage(
                id: chatUtterance, conversationID: shape, seq: 1, role: .user, clientMessageID: UUID(), text: "Use the shorter FAQ on both pricing pages. I always want it short.",
                createdAt: date(9, 30, 18, 4)
            ),
            ChatMessage(
                id: UUID(uuidString: "AAAA0000-0000-4000-8000-000000000002")!, conversationID: shape, seq: 2, role: .assistant,
                text: "Done. I'll keep the FAQ short on both pricing pages. You asked for this before the Thursday review, so I noted it as a rule for Shape launch.",
                refs: ChatRefs(memoryItemIDs: [keepsShort, jordan], contextIDs: [shapeLaunch], actionIDs: []), createdAt: date(9, 30, 18, 5),
                replyTo: chatUtterance,
                content: ChatMessageContent(citations: [
                    ChatCitation(
                        sourceID: gmailSource.uuidString, sourceTitle: "Jordan Lee · Launch timing", sourceKind: "email", occurredAt: date(9, 30, 10, 42),
                        externalURL: URL(string: "https://mail.google.com/mail/u/0/#inbox/launch"), quote: "Could we do the core launch on Thursday instead?"
                    ),
                ])
            ),
        ],
        copy: [
            ChatMessage(
                id: copyQuestion, conversationID: copy, seq: 1, role: .user, clientMessageID: UUID(), text: "Can you compare plan B with plan A for the pricing page?",
                createdAt: date(10, 8, 11, 0)
            ),
            ChatMessage(
                id: UUID(uuidString: "AAAA0000-0000-4000-8000-000000000003")!, conversationID: copy, seq: 2, role: .assistant, text: "Plan B is shorter and drops the annual table.",
                createdAt: date(10, 8, 11, 2), replyTo: copyQuestion
            ),
        ],
    ]

    static let memory: [MemoryItem] = [
        MemoryItem(
            id: keepsShort, scopeKind: .context, contextID: shapeLaunch, statement: "Keeps pricing-page FAQs short", origin: .explicit,
            sourceRef: MemorySourceRef(messageID: chatUtterance), observedAt: date(9, 30, 18, 4)
        ),
        MemoryItem(
            id: thursdays, scopeKind: .global, statement: "Reviews launch work on Thursday mornings", origin: .observed,
            sourceRef: MemorySourceRef(sourceID: calendarSource, quote: "Launch review · weekly"), observedAt: date(10, 6, 9, 0)
        ),
        MemoryItem(
            id: jordan, scopeKind: .context, contextID: shapeLaunch, statement: "Jordan Lee decides partner dates", origin: .inferred,
            sourceRef: MemorySourceRef(sourceID: gmailSource, quote: "Could we do the core launch on Thursday instead? Partner review moved up a day."),
            observedAt: date(9, 30, 10, 42), confidence: 0.7
        ),
    ]

    static let sources: [UUID: MemorySource] = [
        calendarSource: source(calendarSource, kind: "meeting", title: "Launch review", url: "https://calendar.google.com/event?eid=launch", at: "2026-10-06T00:00:00Z"),
        gmailSource: source(gmailSource, kind: "email", title: "Jordan Lee · Launch timing", url: "https://mail.google.com/mail/u/0/#inbox/launch", at: "2026-09-30T01:42:00Z"),
    ]

    private static func source(_ id: UUID, kind: String, title: String, url: String, at: String) -> MemorySource {
        let json = """
        {"id":"\(id.uuidString.lowercased())","kind":"\(kind)","title":"\(title)","occurred_at":"\(at)","external_url":"\(url)","created_at":"\(at)",
         "processing_status":"done","meeting":null,"access_lost_at":null,"raw_text_purged_at":null,"raw_text_purge_reason":null}
        """
        // swiftlint:disable:next force_try
        return try! TaskforceJSON.decoder().decode(MemorySource.self, from: Data(json.utf8))
    }
}

extension SampleData {
    /// `-TFSampleChat <이름>`: 시작 상태 (기본 full). 이름은 `SampleChatGateway.Scenario`
    static var chatScenario: SampleChatGateway.Scenario {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-TFSampleChat"), arguments.indices.contains(index + 1) else { return .full }
        return SampleChatGateway.Scenario(rawValue: arguments[index + 1]) ?? .full
    }
}
#endif
