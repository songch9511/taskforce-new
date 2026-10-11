import Foundation
import Testing
@testable import TaskforceKit

/// 계정 경계 (B3 방식을 범위 멤버십 저장소에 재사용): 앱 시작 때 세션에 붙어 화면과 무관하게 로그아웃 · 다른 계정 · 같은 UUID 재로그인에 비우고,
/// 떠난 세션이 시작한 읽기 · 쓰기의 늦은 응답은 새 세션에 반영하지 않으며 새 요청의 busy를 풀지 않는다. 정상 토큰 갱신은 데이터를 잃지 않는다.
/// 저장 위치 · 기간: 모두 `WorkContextStore` 메모리 (디스크 없음)
@MainActor
struct WorkContextAccountBoundaryTests {
    let shape = ContextFx.context(1, "Shape launch", version: 3)
    let acme = ContextFx.context(2, "Acme website", version: 5)
    let a = WorkListTests.id(1)
    let b = WorkListTests.id(2)

    func make(_ account: ChatTestAccount) -> (store: WorkContextStore, server: FakeContextServer) {
        let server = FakeContextServer(contexts: [shape, acme])
        return (WorkContextStore(gateway: server, scope: account.scope), server)
    }

    func filled(_ account: ChatTestAccount) async throws -> (store: WorkContextStore, server: FakeContextServer) {
        let (store, server) = make(account)
        server.seed(shape.id, a, origin: .user)
        await store.refresh()
        await store.move(a, from: shape.id, to: acme.id)
        #expect(store.canUndo(a) && store.hasRead)
        return (store, server)
    }

    @Test func logoutClearsMembershipsUndoAndNotes() async throws {
        let account = try ChatTestAccount.make()
        let (store, _) = try await filled(account)
        account.session.apply(event: .signedOut, session: nil)
        #expect(!store.hasRead && store.members.isEmpty && store.contexts.isEmpty && store.load == .loading)
        #expect(store.index.memberships(of: a) == .unknown && !store.canUndo(a) && store.feedback(for: a) == nil)
        #expect(store.projectLinks(for: a) == nil)
    }

    /// 같은 UUID가 다시 로그인해도 다른 세션이다: 이전 Undo가 돌아오지 않는다
    @Test func reloggingInAsTheSameUserStartsFresh() async throws {
        let account = try ChatTestAccount.make()
        let (store, server) = try await filled(account)
        let writes = server.writes.count
        account.relogin()
        #expect(!store.hasRead && !store.canUndo(a))
        #expect(await store.undoLast(a) == .ignored)
        #expect(server.writes.count == writes, "옛 세션의 Undo는 새 세션에서 서버로 나가지 않는다")
    }

    @Test func anotherAccountNeverSeesTheFirstAccountsMemberships() async throws {
        let account = try ChatTestAccount.make()
        let (store, _) = try await filled(account)
        let second = ChatTestAccount.session(userID: UUID())
        try account.storage.save(second)
        account.session.apply(event: .signedIn, session: second)
        #expect(store.index.memberships(of: a) == .unknown && store.members.isEmpty)
        #expect(account.scope.token?.userID == second.user.id)
    }

    @Test func tokenRefreshKeepsTheSameSessionsData() async throws {
        let account = try ChatTestAccount.make()
        let (store, _) = try await filled(account)
        let epoch = account.scope.epoch
        account.session.apply(event: .tokenRefreshed, session: account.signedIn)
        account.session.apply(event: .initialSession, session: account.signedIn)
        #expect(account.scope.epoch == epoch)
        #expect(store.hasRead && store.canUndo(a) && store.index.memberships(of: a).links.map(\.project.name) == ["Acme website"])
    }

    /// 로그아웃 전에 보낸 쓰기의 늦은 200은 다음 로그인(같은 UUID)에 반영되지 않는다 (멤버 · version · Undo 모두)
    @Test func aWriteThatOutlivesTheSessionIsDropped() async throws {
        let account = try ChatTestAccount.make()
        let (store, server) = make(account)
        await store.refresh()
        let latch = Latch()
        server.holdWrites(latch)
        let writing = Task { await store.add(a, to: shape.id) }
        while await latch.arrivals == 0 { await Task.yield() }
        account.relogin()
        await latch.open()
        let result = await writing.value
        #expect(result == .ignored)
        #expect(!store.hasRead && store.members.isEmpty && !store.canUndo(a) && store.feedback(for: a) == nil)
        #expect(!store.isBusy(a))
    }

    /// 옛 요청이 늦게 끝나도 새 세션이 같은 할 일에 잡은 busy를 풀지 못한다 (한 번에 하나 규칙)
    @Test func anOldWriteFinishingLateDoesNotReleaseTheNewSessionsBusy() async throws {
        let account = try ChatTestAccount.make()
        let (store, server) = make(account)
        await store.refresh()
        let old = Latch()
        server.holdWrites(old)
        let oldWrite = Task { await store.add(a, to: shape.id) }
        while await old.arrivals == 0 { await Task.yield() }
        account.relogin()
        // 새 세션이 같은 할 일에 새 요청을 잡는다
        await store.refresh()
        let fresh = Latch()
        server.holdWrites(fresh)
        let newWrite = Task { await store.add(a, to: acme.id) }
        while await fresh.arrivals == 0 { await Task.yield() }
        #expect(store.isBusy(a))
        await old.open()
        _ = await oldWrite.value
        #expect(store.isBusy(a), "옛 요청의 정리가 새 요청의 busy를 지우지 않는다")
        #expect(await store.remove(a, from: acme.id) == .ignored, "셋째 요청은 서버로 나가지 않는다")
        await fresh.open()
        #expect(await newWrite.value != .ignored)
        #expect(!store.isBusy(a))
    }

    @Test func aReadThatOutlivesTheSessionIsDropped() async throws {
        let account = try ChatTestAccount.make()
        let (store, server) = make(account)
        server.seed(shape.id, a, origin: .user)
        let latch = Latch()
        server.holdReads(latch)
        let reading = Task { await store.refresh() }
        while await latch.arrivals == 0 { await Task.yield() }
        account.relogin()
        await latch.open()
        await reading.value
        #expect(!store.hasRead && store.members.isEmpty, "떠난 세션이 읽은 멤버십이 새 세션에 보이지 않는다")
        #expect(store.index.memberships(of: a) == .unknown)
    }

    /// 409 · 응답 유실 뒤 다시 읽는 사이 세션이 바뀌어도 새 세션에 충돌 안내를 남기지 않는다
    @Test func aConflictFollowUpNeverMarksTheNewSession() async throws {
        let account = try ChatTestAccount.make()
        let (store, server) = make(account)
        await store.refresh()
        server.otherDevice(.add, ctx: shape.id, action: b)
        let latch = Latch()
        // 409 뒤 다시 읽기를 붙잡는다 (쓰기 요청 전의 읽기 횟수 이후)
        server.holdReads(nil)
        let writing = Task { () -> ProjectWriteResult in
            server.holdReads(latch)
            return await store.add(a, to: shape.id)
        }
        while await latch.arrivals == 0 { await Task.yield() }
        account.relogin()
        await latch.open()
        let result = await writing.value
        #expect(result == .ignored)
        #expect(store.feedback(for: a) == nil && !store.hasRead)
    }

    @Test func signedOutStoresDoNothing() async {
        let server = FakeContextServer(contexts: [shape])
        let store = WorkContextStore(gateway: server, scope: AccountScope(currentAccount: { nil }))
        await store.refresh()
        #expect(server.calls.isEmpty && !store.hasRead)
        #expect(await store.add(a, to: shape.id) == .ignored)
        #expect(await store.undoLast(a) == .ignored)
        #expect(server.calls.isEmpty)
    }
}
