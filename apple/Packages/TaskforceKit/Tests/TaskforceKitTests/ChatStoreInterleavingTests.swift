import Foundation
import Testing
@testable import TaskforceKit

/// 같은 대화를 두고 {목록 새로 읽기(extras 포함) · 직접 읽기 · 글 읽기 · Try again · 서버의 삭제 · 보관 · 복원 · 메시지 저장}이 무작위로 섞이고
/// 응답이 무작위 순서로 늦게 도착해도 지키는 불변식 (시드 고정, 200개 이상). 서버는 모델이고 호출한 때의 사실을 찍어 두며 응답은 장면이 놓아 줄 때까지 붙잡힌다:
/// - 쥔 행의 서버 버전(`ChatRowVersion`)은 줄지 않는다 (늦게 끝난 옛 응답이 더 새 행을 덮지 않는다)
/// - 본문이 정상(.ready)이면 대상(행)을 안다 (본문만 남고 Composer가 대상 없이 기다리는 상태가 없다). 오류 화면(.failed)에는 이전 본문이 없다
/// - 모든 응답이 끝난 뒤 새로 읽기 한 번이면 보이는 상태가 서버의 마지막 사실과 같다 (있으면 행 · 버전 · 본문 · Composer, 없으면 .failed)
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

/// 서버 쪽 사실 하나: 대화 X가 있나 · 보관했나 · 메시지가 몇 개인가 (개수가 곧 버전: 0이면 `last_message_at`이 없다)
private struct Fact: Sendable, Equatable {
    var exists = false
    var archived = false
    var messageCount = 0
    var alive: Bool { exists && !archived }
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
    var fact = Fact()
    var autoDeliver = false
    private(set) var pending: [Pending] = []
    private var nextID = 0

    func row(_ fact: Fact) -> ChatConversation {
        ChatConversation(
            id: id, title: nil, createdAt: .test(0), lastMessageAt: fact.messageCount == 0 ? nil : .test(Double(fact.messageCount)),
            archivedAt: fact.archived ? .test(1) : nil,
            target: ChatConversationTarget(kind: .agent, agentConnectionID: connection, agentSessionID: ChatContractFixtures.id(2, prefix: "5e550000"))
        )
    }

    func messages(_ fact: Fact) -> [ChatMessage] {
        guard fact.alive, fact.messageCount > 0 else { return [] }
        return (1...fact.messageCount).map { Chats.message($0, in: id, seq: $0, role: .assistant, text: "m\($0)", at: Double($0)) }
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
    enum Step: CaseIterable { case refresh, direct, body, mutate }

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
                guard fact.alive, fact.messageCount > 0, let last = server.messages(fact).last else { return [:] }
                return [id: last]
            }
        }
        gateway.contextsHandler = { [] }

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
            if let version = chat.conversations.first(where: { $0.id == id })?.rowVersion {
                if let last = lastVersion, version < last { problems.append("\(when): 쥔 행의 서버 버전이 줄었다") }
                lastVersion = max(lastVersion ?? version, version)
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
        var budget: [Step: Int] = [.refresh: 4, .direct: 3, .body: 2, .mutate: 4]
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
            case .mutate:
                var options: [(inout Fact) -> Void] = []
                if !server.fact.exists {
                    options = [{ $0.exists = true; $0.archived = false }]
                } else if server.fact.archived {
                    options = [{ $0.archived = false }, { $0.exists = false }]
                } else {
                    options = [{ $0.messageCount += 1 }, { $0.messageCount += 1 }, { $0.archived = true }, { $0.exists = false }]
                }
                options[Int.random(in: 0..<options.count, using: &rng)](&server.fact)
            }
            await yieldALot()
            observe("seed \(seed) step \(steps) 시작")
        }

        // 2. 서버가 마지막 사실로 멈춘 뒤: 서버가 없는 대화는 새로 읽기가 먼저 확인한 다음 늦은 응답을 놓는다 (되살리면 안 된다). 있는 대화는 응답을 다 놓은 뒤 새로 읽는다
        let final = server.fact
        func drain(_ label: String) async {
            var guardSteps = 0
            while (finished < ops.count || !server.pending.isEmpty), guardSteps < 400 {
                guardSteps += 1
                if server.pending.isEmpty { await yieldALot() } else { await deliverRandom() }
                observe("seed \(seed) \(label)")
            }
            if finished < ops.count { problems.append("\(label): 작업이 끝나지 않는다") }
        }
        if !final.alive, Bool.random(using: &rng) {
            server.autoDeliver = true
            await chat.refresh()
            observe("seed \(seed) 확인 새로 읽기")
            if chat.screen(for: id) != .failed || chat.isTargetKnown(id) { problems.append("새로 읽기가 없는 대화를 확인하지 못했다") }
            await drain("확인 뒤 늦은 응답")
            if chat.screen(for: id) != .failed || chat.isTargetKnown(id) || !chat.turns(for: id).isEmpty {
                problems.append("확인한 대화를 늦은 응답이 되살렸다")
            }
            server.autoDeliver = false
        } else {
            await drain("응답 모두 놓기")
        }

        // 3. 수렴: 새로 읽기 한 번이면 보이는 상태가 서버의 마지막 사실과 같다
        server.autoDeliver = true
        await chat.refresh()
        await chat.settle()
        observe("seed \(seed) 수렴")
        if final.alive {
            let held = chat.conversations.first { $0.id == id }
            if !chat.isTargetKnown(id) { problems.append("수렴: 서버에 있는데 행이 없다") }
            if held?.rowVersion != server.row(final).rowVersion { problems.append("수렴: 쥔 행의 버전이 서버와 다르다 (\(String(describing: held?.lastMessageAt)))") }
            if chat.screen(for: id) != .ready(problem: nil) { problems.append("수렴: 본문이 정상이 아니다 (\(chat.screen(for: id)))") }
            if chat.turns(for: id).map(\.text) != server.messages(final).map(\.text) { problems.append("수렴: 본문이 서버와 다르다") }
            if !chat.canCompose(in: id) { problems.append("수렴: Composer를 쓸 수 없다") }
        } else {
            if chat.screen(for: id) != .failed || chat.isTargetKnown(id) || !chat.turns(for: id).isEmpty || chat.canCompose(in: id) {
                problems.append("수렴: 서버에 없는데 오류 화면이 아니다 (\(chat.screen(for: id)))")
            }
        }
        return problems
    }
}
