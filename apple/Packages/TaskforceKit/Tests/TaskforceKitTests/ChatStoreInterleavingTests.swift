import Foundation
import Testing
@testable import TaskforceKit

/// 같은 대화를 두고 {목록 새로 읽기(extras 포함) · 직접 읽기 · 글 읽기 · 내 글 보내기(POST) · 내 프로젝트 바꾸기(PATCH) · 서버의 삭제 · 보관 · 복원 · 메시지 저장 · 읽음 · 글 비움 · 프로젝트 변경}이
/// 무작위로 섞이고 응답이 무작위 순서로 늦게 도착해도 지키는 불변식 (시드 고정, 240개). 서버는 모델이고 호출한 때의 사실을 찍어 두며 응답은 장면이 놓아 줄 때까지 붙잡힌다.
/// 메시지 개수와 `last_message_at`은 따로 움직이고, 시드의 절반은 시각이 뒤로 간다 (`db_now()`는 트랜잭션 시작 시각이라 서버 시각이 줄 수 있다):
/// - 본문이 정상(.ready)이면 대상(행)을 안다 (본문만 남고 Composer가 대상 없이 기다리는 상태가 없다). 오류 화면(.failed)에는 이전 본문이 없다
/// - 쥔 행은 서버가 돌려준 행 그대로다 (섞인 행이 없다). 서버 시각이 앞으로만 가는 시드에서는 쥔 행의 서버 버전(`ChatRowVersion`)이 줄지 않는다
/// - 모든 응답이 끝난 뒤 새로 읽기 한 번이면 쥔 행이 서버의 마지막 행과 **모든 필드**(프로젝트 · 읽음 · 글 비움 · 시각)에서 같다 (시각이 뒤로 갔어도). 없으면 .failed
/// - 서버가 없는 대화를 새로 읽기가 확인한 뒤에는, 그 전에 나간 읽기의 늦은 응답이 되살리지 못한다
private struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// 서버 쪽 사실 하나: 대화 X가 있나 · 보관했나 · 메시지가 몇 개인가, 그리고 행의 시각 · 프로젝트 (메시지 개수와 `last_message_at`은 따로다)
private struct Fact: Sendable, Equatable {
    var exists = false
    var archived = false
    var messages: [Rec] = []
    var lastMessageAt: TimeInterval?
    var lastReadAt: TimeInterval?
    var textPurged = false
    var contextID: UUID?
    var alive: Bool { exists && !archived }

    /// 서버에 저장된 메시지 하나 (내가 보낸 글이면 `cmid`가 있고 답은 그 글에 `replyTo`)
    struct Rec: Sendable, Equatable {
        let seq: Int
        let isUser: Bool
        let text: String
        let cmid: UUID?
        let replyTo: Int?
        let at: TimeInterval
    }
}

/// 서버 시각 모델: 시각이 앞으로만 가는 시드와, 아무 값이나 가는 시드 (`db_now()`는 트랜잭션 시작 시각이라 나중에 저장한 값이 더 작을 수 있다)
@MainActor
private final class TimeSource {
    private var rng: SeededGenerator
    let allowBackward: Bool

    init(seed: UInt64, allowBackward: Bool) {
        rng = SeededGenerator(seed: seed ^ 0xA5A5_A5A5_5A5A_5A5A)
        self.allowBackward = allowBackward
    }

    func next(after current: TimeInterval?) -> TimeInterval {
        allowBackward ? Double(Int.random(in: 1...1000, using: &rng)) : (current ?? 0) + Double(Int.random(in: 1...5, using: &rng))
    }
}

@MainActor
private final class ModelServer {
    struct Pending {
        let id: Int
        let resume: @MainActor () -> Void
    }

    let id = ChatContractFixtures.id(2, prefix: "bcb50000")
    let listedRow = ChatConversation(id: ChatContractFixtures.id(1, prefix: "bcb50000"), title: nil, createdAt: .test(0), lastMessageAt: .test(1000))
    let connection = UUID(uuidString: "c0c00000-0000-4000-8000-000000000001")!
    let projects: [UUID?] = [nil, ChatContractFixtures.id(41, prefix: "c0170000"), ChatContractFixtures.id(42, prefix: "c0170000"), ChatContractFixtures.id(43, prefix: "c0170000")]
    var fact = Fact()
    var autoDeliver = false
    /// 내 글이 서버에서 거절된 적이 있나 (실패한 보내기는 화면에 남으므로 그 시드는 본문 수렴을 따로 보지 않는다)
    var postFailed = false
    /// 내 글의 시각을 정한다 (서버 시각 모델)
    var postTime: @MainActor (TimeInterval?) -> TimeInterval = { ($0 ?? 0) + 1 }
    /// 서버가 지금까지 돌려준 X의 행들: 쥔 행은 이 중 하나여야 한다 (섞인 행이 없다)
    private(set) var issuedRows: Set<ChatConversation> = []
    private(set) var pending: [Pending] = []
    private var nextID = 0

    func row(_ fact: Fact) -> ChatConversation {
        let row = ChatConversation(
            id: id, title: nil, contextID: fact.contextID, createdAt: .test(0), lastMessageAt: fact.lastMessageAt.map { .test($0) },
            lastReadAt: fact.lastReadAt.map { .test($0) }, archivedAt: fact.archived ? .test(1) : nil, textPurgedAt: fact.textPurged ? .test(2) : nil,
            target: .taskforce
        )
        issuedRows.insert(row)
        return row
    }

    func message(_ rec: Fact.Rec) -> ChatMessage {
        Chats.message(
            rec.seq, in: id, seq: rec.seq, role: rec.isUser ? .user : .assistant, text: rec.text, cmid: rec.cmid,
            replyTo: rec.replyTo.map { ChatContractFixtures.id($0, prefix: "aaaa0000") }, at: rec.at
        )
    }

    func messages(_ fact: Fact) -> [ChatMessage] {
        guard fact.alive else { return [] }
        return fact.messages.map(message)
    }

    /// 내가 보낸 글(POST): 서버는 호출한 때 저장하고(글 + 답, 시각은 `time`) 응답은 붙잡힌다. 없는 · 보관한 대화는 오류다
    func post(cmid: UUID, text: String) async throws -> ChatPostedMessage {
        guard fact.alive else {
            postFailed = true
            throw FakeChatGateway.Failure()
        }
        let time = postTime(fact.lastMessageAt)
        let user = Fact.Rec(seq: fact.messages.count + 1, isUser: true, text: text, cmid: cmid, replyTo: nil, at: time)
        let reply = Fact.Rec(seq: user.seq + 1, isUser: false, text: "r\(user.seq + 1)", cmid: nil, replyTo: user.seq, at: time)
        fact.messages += [user, reply]
        fact.lastMessageAt = time
        return await respond { [self] _ in ChatPostedMessage(message: message(user), reply: message(reply)) }
    }

    /// 내가 바꾼 프로젝트(PATCH): 서버는 호출한 때 바꾸고 바뀐 행을 돌려준다
    func patch(contextID: UUID?) async throws -> ChatConversation {
        guard fact.alive else { throw FakeChatGateway.Failure() }
        fact.contextID = contextID
        return await respond { [self] fact in row(fact) }
    }

    /// 호출한 때의 사실로 응답을 만들어 두고, 장면이 놓아 줄 때까지 붙잡는다 (`autoDeliver`면 바로 돌려준다)
    func respond<T: Sendable>(_ make: @MainActor (Fact) -> T) async -> T {
        let value = make(fact)
        if autoDeliver { return value }
        return await withCheckedContinuation { continuation in
            nextID += 1
            pending.append(Pending(id: nextID, resume: { continuation.resume(returning: value) }))
        }
    }

    func deliver(at index: Int) {
        let entry = pending.remove(at: index)
        entry.resume()
    }
}

@MainActor
struct ChatStoreInterleavingTests {
    enum Step: CaseIterable { case refresh, direct, body, post, patch, mutate }

    @Test func randomInterleavingsKeepTheInvariantsAndConvergeToTheServersLatestState() async {
        let seeds = 240
        var failures: [String] = []
        for seed in 0..<seeds {
            let problems = await run(seed: UInt64(seed))
            if !problems.isEmpty {
                failures.append("seed \(seed): \(problems.prefix(3).joined(separator: "; "))")
                if failures.count >= 3 { break }
            }
        }
        #expect(failures.isEmpty, "\(failures.joined(separator: "\n"))")
    }

    /// 한 시드의 한 번 실행. 어긴 불변식 설명을 돌려준다 (없으면 빈 배열)
    private func run(seed: UInt64) async -> [String] {
        var rng = SeededGenerator(seed: seed)
        let allowBackward = Bool.random(using: &rng)
        let server = ModelServer()
        let gateway = FakeChatGateway()
        let scope = ChatTestAccount.fixedScope()
        let chat = ChatStore(gateway: gateway, scope: scope, now: { .test(500) })
        chat.panelConversations = { [server] in [server.id] }
        let id = server.id
        gateway.conversationsHandler = { [server] in
            await server.respond { fact in [server.listedRow] + (fact.alive ? [server.row(fact)] : []) }
        }
        gateway.conversationHandler = { [server] requested in
            guard requested == id else { return nil }
            return await server.respond { fact in fact.exists ? server.row(fact) : nil }
        }
        gateway.messagesHandler = { [server] requested in
            guard requested == id else { return [] }
            return await server.respond { fact in server.messages(fact) }
        }
        gateway.lastMessagesHandler = { [server] _ in
            await server.respond { fact in
                guard fact.alive, let last = server.messages(fact).last else { return [:] }
                return [id: last]
            }
        }
        gateway.contextsHandler = { [] }
        // 내 글(POST)의 시각: 시각이 앞으로만 가는 시드에서는 지금 시각보다 뒤, 아니면 아무 값이나 (서버 트랜잭션 시작 시각)
        let timeSource = TimeSource(seed: seed, allowBackward: allowBackward)
        server.postTime = { current in timeSource.next(after: current) }
        gateway.postHandler = { [server] requested, cmid, text in
            guard requested == id else { throw FakeChatGateway.Failure() }
            return try await server.post(cmid: cmid, text: text)
        }
        gateway.updateHandler = { [server] requested, contextID in
            guard requested == id else { throw FakeChatGateway.Failure() }
            return try await server.patch(contextID: contextID)
        }

        var problems: [String] = []
        var lastVersion: ChatRowVersion?
        func observe(_ when: String) {
            let screen = chat.screen(for: id)
            let known = chat.isTargetKnown(id)
            if case .ready = screen, !known {
                problems.append("\(when): 본문이 정상인데 대상(행)을 모른다")
            }
            if screen == .failed, !chat.turns(for: id).isEmpty {
                problems.append("\(when): 오류 화면에 이전 본문이 남았다")
            }
            if let held = chat.conversations.first(where: { $0.id == id }) {
                // 내 쓰기는 쥔 행을 합쳐 바꾼다(글이 저장되면 마지막 시각, 프로젝트 응답은 쓴 값만): 시각 필드를 뺀 나머지가 서버가 돌려준 행과 같아야 한다
                if !server.issuedRows.contains(where: { $0.sameExceptTimestamps(as: held) }) { problems.append("\(when): 쥔 행이 서버가 돌려준 어떤 행과도 다르다 (섞였다)") }
                if !allowBackward {
                    let version = held.rowVersion
                    if let last = lastVersion, version < last { problems.append("\(when): 쥔 행의 서버 버전이 줄었다") }
                    lastVersion = max(lastVersion ?? version, version)
                }
            }
        }

        var ops: [Task<Void, Never>] = []
        var finished = 0
        func start(_ work: @escaping @MainActor () async -> Void) {
            ops.append(Task { @MainActor in
                await work()
                finished += 1
            })
        }
        func yieldALot() async { for _ in 0..<12 { await Task.yield() } }
        func deliverRandom() async {
            guard !server.pending.isEmpty else { return }
            server.deliver(at: Int.random(in: 0..<server.pending.count, using: &rng))
            await yieldALot()
        }

        // 1. 무작위 장면: 작업을 시작하고 · 응답을 놓고 · 서버 사실을 바꾼다
        var budget: [Step: Int] = [.refresh: 4, .direct: 3, .body: 2, .post: 3, .patch: 3, .mutate: 7]
        var postCount = 0
        var steps = 0
        while budget.values.contains(where: { $0 > 0 }), steps < 300 {
            steps += 1
            let choices = Step.allCases.filter { (budget[$0] ?? 0) > 0 }
            if !server.pending.isEmpty, Int.random(in: 0..<100, using: &rng) < 55 {
                await deliverRandom()
                observe("seed \(seed) step \(steps) 응답 전달")
                continue
            }
            let step = choices[Int.random(in: 0..<choices.count, using: &rng)]
            budget[step, default: 0] -= 1
            switch step {
            case .refresh:
                start { await chat.refresh() }
            case .direct:
                start { await chat.readConversation(id) }
            case .body:
                start { await chat.loadThread(id) }
            case .post:
                postCount += 1
                let text = "p\(postCount)"
                start { await chat.send(text, in: id) }
            case .patch:
                let project = server.projects[Int.random(in: 0..<server.projects.count, using: &rng)]
                start { await chat.chooseProject(project, in: id) }
            case .mutate:
                // 시각: 뒤로 가는 시드에서는 아무 값이나 (`db_now()`가 트랜잭션 시작 시각이라 나중에 저장한 값이 더 작을 수 있다), 아니면 앞으로만
                func nextTime(_ current: TimeInterval?) -> TimeInterval {
                    allowBackward ? Double(Int.random(in: 1...1000, using: &rng)) : (current ?? 0) + Double(Int.random(in: 1...5, using: &rng))
                }
                let message = nextTime(server.fact.lastMessageAt)
                let read = nextTime(server.fact.lastReadAt)
                let project = server.projects[Int.random(in: 0..<server.projects.count, using: &rng)]
                var options: [(inout Fact) -> Void] = []
                if !server.fact.exists {
                    options = [{ $0.exists = true; $0.archived = false }]
                } else if server.fact.archived {
                    options = [{ $0.archived = false }, { $0.exists = false }]
                } else {
                    options = [
                        { $0.messages.append(Fact.Rec(seq: $0.messages.count + 1, isUser: false, text: "m\($0.messages.count + 1)", cmid: nil, replyTo: nil, at: message)); $0.lastMessageAt = message },
                        { $0.messages.append(Fact.Rec(seq: $0.messages.count + 1, isUser: false, text: "m\($0.messages.count + 1)", cmid: nil, replyTo: nil, at: message)); $0.lastMessageAt = message },
                        { $0.lastReadAt = read },
                        { $0.textPurged = true },
                        { $0.contextID = project },
                        { $0.contextID = project },
                        { $0.archived = true },
                        { $0.exists = false },
                    ]
                }
                options[Int.random(in: 0..<options.count, using: &rng)](&server.fact)
            }
            await yieldALot()
            observe("seed \(seed) step \(steps) 시작")
        }

        // 2. 서버가 마지막 사실로 멈춘 뒤: 서버가 없는 대화는 새로 읽기가 먼저 확인한 다음 늦은 응답을 놓는다 (되살리면 안 된다). 있는 대화는 응답을 다 놓은 뒤 새로 읽는다
        let aliveBeforeDrain = server.fact.alive
        func drain(_ label: String) async {
            var guardSteps = 0
            while (finished < ops.count || !server.pending.isEmpty), guardSteps < 400 {
                guardSteps += 1
                if server.pending.isEmpty { await yieldALot() } else { await deliverRandom() }
                observe("seed \(seed) \(label)")
            }
            if finished < ops.count { problems.append("\(label): 작업이 끝나지 않는다") }
        }
        if !aliveBeforeDrain, Bool.random(using: &rng) {
            server.autoDeliver = true
            await chat.refresh()
            observe("seed \(seed) 확인 새로 읽기")
            // 서버가 거절한 내 글은 실패한 보내기로 화면에 남는다: 그 시드는 화면 · 글 목록 대신 대상(행)만 본다
            func isGoneState() -> Bool {
                if chat.isTargetKnown(id) { return false }
                return server.postFailed || (chat.screen(for: id) == .failed && chat.turns(for: id).isEmpty)
            }
            if !isGoneState() { problems.append("새로 읽기가 없는 대화를 확인하지 못했다") }
            await drain("확인 뒤 늦은 응답")
            if !isGoneState() {
                problems.append("확인한 대화를 늦은 응답이 되살렸다 (행 \(chat.isTargetKnown(id)) · 화면 \(chat.screen(for: id)) · 글 \(chat.turns(for: id).count) · 내 글 거절 \(server.postFailed))")
            }
            server.autoDeliver = false
        } else {
            await drain("응답 모두 놓기")
        }

        // 3. 수렴: 새로 읽기 한 번이면 보이는 상태가 서버의 마지막 사실과 같다
        // 시작해 둔 POST/PATCH가 drain 중 서버에 도착할 수 있다. 모든 작업을 마친 뒤의 사실을 기준으로 삼는다.
        let final = server.fact
        server.autoDeliver = true
        await chat.refresh()
        await chat.settle()
        observe("seed \(seed) 수렴")
        if final.alive {
            let held = chat.conversations.first { $0.id == id }
            let expected = server.row(final)
            if !chat.isTargetKnown(id) { problems.append("수렴: 서버에 있는데 행이 없다") }
            if held?.contextID != expected.contextID { problems.append("수렴: 프로젝트가 서버와 다르다") }
            if held?.lastMessageAt != expected.lastMessageAt { problems.append("수렴: last_message_at이 서버와 다르다 (\(String(describing: held?.lastMessageAt)) ≠ \(String(describing: expected.lastMessageAt)))") }
            if held?.lastReadAt != expected.lastReadAt { problems.append("수렴: last_read_at이 서버와 다르다") }
            if held?.textPurgedAt != expected.textPurgedAt { problems.append("수렴: text_purged_at이 서버와 다르다") }
            if held != expected { problems.append("수렴: 쥔 행이 서버의 마지막 행과 다르다") }
            // 서버가 거절한 내 글은 실패한 보내기로 화면에 남는다: 그 시드는 본문(글 목록)을 따로 보지 않는다
            if !server.postFailed {
                if chat.screen(for: id) != .ready(problem: nil) { problems.append("수렴: 본문이 정상이 아니다 (\(chat.screen(for: id)))") }
                if chat.turns(for: id).map(\.text) != server.messages(final).map(\.text) { problems.append("수렴: 본문이 서버와 다르다") }
            }
            if !chat.canCompose(in: id) { problems.append("수렴: Composer를 쓸 수 없다") }
        } else {
            if chat.isTargetKnown(id) || chat.canCompose(in: id) || (!server.postFailed && (chat.screen(for: id) != .failed || !chat.turns(for: id).isEmpty)) {
                problems.append("수렴: 서버에 없는데 오류 화면이 아니다 (\(chat.screen(for: id)))")
            }
        }
        return problems
    }
}

private extension ChatConversation {
    /// 시각 필드(마지막 메시지 · 읽음 · 글 비움)를 뺀 나머지가 같나
    func sameExceptTimestamps(as other: ChatConversation) -> Bool {
        id == other.id && title == other.title && contextID == other.contextID && createdAt == other.createdAt
            && archivedAt == other.archivedAt && target == other.target
    }
}
