import Foundation
import Supabase
import Testing
@testable import TaskforceKit

/// 기억 저장소: 읽기 상태 · 쓰기 결과 · 409 뒤 성공 추정 금지 · 정책 보류 · 계정 경계
@MainActor
struct MemoryStoreTests {
    let gateway = FakeChatGateway()
    let scope = ChatTestAccount.fixedScope()
    let project = ChatContractFixtures.contextID
    let otherProject = ChatContractFixtures.otherContextID

    func store() -> MemoryStore { MemoryStore(gateway: gateway, scope: scope) }

    /// 서버의 지금 기억 (쓰기에 따라 바뀌는 가짜 DB)
    final class ServerRows: @unchecked Sendable {
        private let lock = NSLock()
        private var rows: [MemoryItem]
        init(_ rows: [MemoryItem]) { self.rows = rows }
        var all: [MemoryItem] { lock.lock(); defer { lock.unlock() }; return rows }
        func replace(_ rows: [MemoryItem]) { lock.lock(); self.rows = rows; lock.unlock() }
    }

    func serve(_ rows: ServerRows) {
        gateway.currentMemoryHandler = { rows.all.filter(\.isCurrent) }
        gateway.memoryItemsHandler = { ids in rows.all.filter { ids.contains($0.id) } }
        gateway.contextsHandler = { [project = project, otherProject = otherProject] in
            [WorkContext(id: project, name: "Shape launch"), WorkContext(id: otherProject, name: "Acme website")]
        }
    }

    // MARK: 읽기

    @Test func listShowsOnlyCurrentItemsNewestFirstWithProjectNames() async throws {
        let rows = ServerRows([
            Memories.item(1, "old", at: 0), Memories.item(2, "newer", scope: .context, context: project, at: 100),
            Memories.item(3, "forgotten", revoked: true, at: 200), Memories.item(4, "replaced", superseded: true, at: 300),
        ])
        serve(rows)
        let memory = store()
        await memory.loadList()
        #expect(memory.load == .loaded)
        #expect(memory.items.map(\.statement) == ["newer", "old"])
        #expect(MemoryText.scope(memory.items[0], contexts: memory.contexts) == "Shape launch")
        #expect(MemoryText.scope(memory.items[1], contexts: memory.contexts) == "All work")
    }

    @Test func readStatesAreOfflineFailedLoadedNotInvented() async throws {
        gateway.currentMemoryHandler = { throw URLError(.notConnectedToInternet) }
        let memory = store()
        await memory.loadList()
        #expect(memory.load == .offline && memory.items.isEmpty)
        gateway.currentMemoryHandler = { throw FakeChatGateway.Failure() }
        await memory.loadList()
        #expect(memory.load == .failed)
        gateway.currentMemoryHandler = { [] }
        await memory.loadList()
        // 비어 있음은 읽은 뒤의 사실이다
        #expect(memory.load == .loaded && memory.items.isEmpty)
        // 받은 목록이 있으면 다음 읽기가 실패해도 그대로 둔다
        gateway.currentMemoryHandler = { [Memories.item(1)] }
        await memory.loadList()
        gateway.currentMemoryHandler = { throw URLError(.timedOut) }
        await memory.loadList()
        #expect(memory.items.count == 1 && memory.load == .loaded)
    }

    /// 서버 DB에 기억 테이블이 아직 없다 (마이그레이션 적용 전): 실패가 아니라 기능이 아직 없다고 말한다
    @Test func missingTablesAreUnavailableNotAFailureNorEmpty() async throws {
        gateway.currentMemoryHandler = { throw PostgrestError(code: "PGRST205", message: "Could not find the table 'public.memory_items'") }
        let memory = store()
        await memory.loadList()
        #expect(memory.load == .unavailable && memory.writesUnavailable && memory.items.isEmpty)
        gateway.currentMemoryHandler = { throw PostgrestError(code: "42P01", message: "relation does not exist") }
        await memory.loadList()
        #expect(memory.load == .unavailable)
        // 다른 오류는 실패다
        gateway.currentMemoryHandler = { throw PostgrestError(code: "XX000", message: "boom") }
        let other = store()
        await other.loadList()
        #expect(other.load == .failed && !other.writesUnavailable)
    }

    // MARK: 쓰기: 성공은 서버 응답 뒤에만

    @Test func confirmReplacesTheInferredRowWithTheServersNewRow() async throws {
        let inferred = Memories.item(1, "Jordan decides partner dates", origin: .inferred, scope: .context, context: project, version: 3)
        let rows = ServerRows([inferred])
        serve(rows)
        let confirmed = Memories.item(2, "Jordan decides partner dates", origin: .explicit, scope: .context, context: project, at: 50)
        gateway.confirmHandler = { id, version in
            rows.replace([Memories.item(1, "Jordan decides partner dates", origin: .inferred, scope: .context, context: self.project, version: 4, superseded: true, supersededBy: confirmed.id), confirmed])
            return confirmed
        }
        let memory = store()
        await memory.loadList()
        #expect(memory.canConfirm(inferred))
        let result = await memory.confirm(inferred.id)
        #expect(result == .applied(confirmed))
        // 앱이 읽은 행의 version을 그대로 보냈다
        #expect(gateway.calls(prefix: "confirm") == ["confirm:\(inferred.id.uuidString):v3"])
        #expect(memory.resolve(inferred.id) == confirmed.id)
        #expect(memory.items.map(\.id) == [confirmed.id])
        #expect(memory.noteState(for: inferred.id) == .current(confirmed))
    }

    /// 보내는 중에는 완료로 보이지 않는다: 응답 전에는 행이 그대로이고 바쁘다
    @Test func nothingLooksDoneBeforeTheServerAnswers() async throws {
        let item = Memories.item(1, "old", origin: .inferred)
        let rows = ServerRows([item])
        serve(rows)
        let latch = Latch()
        let confirmed = Memories.item(2, "old")
        gateway.confirmHandler = { _, _ in await latch.wait(); return confirmed }
        let memory = store()
        await memory.loadList()
        let pending = Task { await memory.confirm(item.id) }
        while await latch.arrivals == 0 { await Task.yield() }
        #expect(memory.isBusy(item.id))
        #expect(memory.items.map(\.id) == [item.id] && memory.resolve(item.id) == item.id)
        // 두 번 눌러도 한 번만 보낸다
        #expect(await memory.confirm(item.id) == .ignored)
        await latch.open()
        #expect(await pending.value == .applied(confirmed))
        #expect(gateway.calls(prefix: "confirm").count == 1)
    }

    @Test func editSendsTheTrimmedStatementAndFollowsTheNewRow() async throws {
        let item = Memories.item(1, "배포는 금요일", version: 2)
        let rows = ServerRows([item])
        serve(rows)
        let edited = Memories.item(2, "배포는 목요일")
        gateway.editHandler = { _, edit in
            #expect(edit.expectedVersion == 2 && edit.statement == "배포는 목요일" && edit.value == .inherit)
            return edited
        }
        let memory = store()
        await memory.loadList()
        #expect(await memory.edit(item.id, statement: "  배포는 목요일 \n") == .applied(edited))
        #expect(memory.resolve(item.id) == edited.id)
        // 빈 글 · 1000자 초과는 보내지 않는다
        #expect(await memory.edit(edited.id, statement: "  ") == .ignored)
        #expect(await memory.edit(edited.id, statement: String(repeating: "가", count: 1001)) == .ignored)
        #expect(gateway.calls(prefix: "edit").count == 1)
    }

    @Test func moveSendsTheTargetAndFollowsTheMovedRow() async throws {
        let item = Memories.item(1, version: 1)
        let rows = ServerRows([item])
        serve(rows)
        let moved = Memories.item(9, scope: .context, context: project, value: .object(["moved_from": .string(item.id.uuidString.lowercased())]))
        gateway.moveHandler = { _, _, target in
            #expect(target == .context(self.project))
            return moved
        }
        let memory = store()
        await memory.loadList()
        #expect(await memory.move(item.id, to: .context(project)) == .applied(moved))
        #expect(memory.noteState(for: item.id) == .current(moved))
    }

    // MARK: 409 / 재전송 (Codex 반례): 409를 성공으로 올리지 않는다

    /// 다른 기기에서 Edit 성공 → 내 Edit 409. 옛 행에 `superseded_by`가 있어도 그 후속 행은 다른 기기의 글이다: 성공 표시 0, 지금 상태 재표시
    @Test func conflictAfterAnotherDevicesEditShowsTheirTextNotAsMySuccess() async throws {
        let mine = Memories.item(1, "Ship Friday", version: 1)
        let rows = ServerRows([mine])
        serve(rows)
        let theirs = Memories.item(7, "Ship Thursday (other Mac)", at: 20)
        gateway.editHandler = { _, _ in
            // 내 요청이 닿기 전에 다른 기기가 먼저 정정했다
            rows.replace([Memories.item(1, "Ship Friday", version: 2, superseded: true, supersededBy: theirs.id), theirs])
            throw APIError.server(status: 409, code: .conflict, message: "그 사이 기억이 바뀌었습니다.")
        }
        let memory = store()
        await memory.loadList()
        let result = await memory.edit(mine.id, statement: "Ship Thursday")
        #expect(result == .refreshed)
        #expect(memory.feedback(for: mine.id) == .conflict)
        // 성공으로 올리지 않았다: 후속 행을 내 것으로 이어 붙이지 않는다
        #expect(memory.resolve(mine.id) == mine.id)
        #expect(memory.item(mine.id)?.isCurrent == false)
        // 지금 상태를 보인다: 다른 기기의 글
        #expect(memory.noteState(for: mine.id) == .current(theirs))
        #expect(memory.items.map(\.statement) == ["Ship Thursday (other Mac)"])
    }

    /// 다른 기기가 범위 B로 Move → 내 범위 A Move 409. 옛 행은 `revoked_at` + 후속 행(범위 B): 내 요청의 결과로 보이지 않는다
    @Test func conflictAfterAnotherDevicesMoveKeepsTheirScope() async throws {
        let mine = Memories.item(1, "Short FAQs", version: 1)
        let rows = ServerRows([mine])
        serve(rows)
        let theirs = Memories.item(
            9, "Short FAQs", scope: .context, context: otherProject, value: .object(["moved_from": .string(mine.id.uuidString.lowercased())]), at: 30
        )
        gateway.moveHandler = { _, _, _ in
            rows.replace([Memories.item(1, "Short FAQs", version: 2, revoked: true), theirs])
            throw APIError.server(status: 409, code: .conflict, message: "x")
        }
        let memory = store()
        await memory.loadList()
        #expect(await memory.move(mine.id, to: .context(project)) == .refreshed)
        #expect(memory.feedback(for: mine.id) == .conflict)
        #expect(memory.resolve(mine.id) == mine.id)
        // 지금 상태: 범위는 다른 기기가 고른 B (내가 고른 A가 아니다)
        guard case .current(let shown) = memory.noteState(for: mine.id) else {
            Issue.record("지금 기억을 보이지 못함")
            return
        }
        #expect(shown.contextID == otherProject)
        #expect(MemoryText.scope(shown, contexts: memory.contexts) == "Acme website")
    }

    /// 응답을 못 받고(전송 오류) 같은 요청을 다시 보내면 409다 (서버는 이미 처리했을 수 있다): 같은 처리 — 성공으로 올리지 않고 지금 상태
    @Test func retryAfterALostResponseIsHandledLikeAnyConflict() async throws {
        let item = Memories.item(1, "Jordan decides", origin: .inferred, version: 1)
        let rows = ServerRows([item])
        serve(rows)
        let confirmed = Memories.item(2, "Jordan decides", origin: .explicit, at: 40)
        let attempts = Counter()
        gateway.confirmHandler = { _, _ in
            if attempts.next() == 1 {
                // 서버는 처리했지만 응답이 오지 않았다
                rows.replace([Memories.item(1, "Jordan decides", origin: .inferred, version: 2, superseded: true, supersededBy: confirmed.id), confirmed])
                throw URLError(.networkConnectionLost)
            }
            throw APIError.server(status: 409, code: .conflict, message: "x")
        }
        let memory = store()
        await memory.loadList()
        #expect(await memory.confirm(item.id) == .failed)
        #expect(memory.items.map(\.id) == [item.id], "응답 전에는 바뀌지 않는다")
        // 같은 요청을 다시 보낸다 (같은 version)
        #expect(await memory.confirm(item.id) == .refreshed)
        #expect(gateway.calls(prefix: "confirm").count == 2)
        #expect(memory.feedback(for: item.id) == .conflict)
        #expect(memory.resolve(item.id) == item.id, "응답의 새 행이 없으므로 내 결과로 이어 붙이지 않는다")
        #expect(memory.items.map(\.id) == [confirmed.id])
    }

    /// 같은 요청을 다시 보낸 잊기는 서버가 200으로 돌려준다: "이 항목은 지금 기억이 아님"
    @Test func forgetRetryIsOkAndMeansNotRememberedNow() async throws {
        let item = Memories.item(1)
        let rows = ServerRows([item])
        serve(rows)
        gateway.forgetHandler = { _, _ in
            rows.replace([Memories.item(1, version: 2, revoked: true)])
            return Memories.item(1, version: 2, revoked: true)
        }
        let memory = store()
        await memory.loadList()
        #expect(await memory.forget(item.id) == .forgotten)
        #expect(memory.items.isEmpty)
        #expect(memory.noteState(for: item.id) == .notRemembered)
        #expect(memory.feedback(for: item.id) == nil)
    }

    /// 잊기 200이지만 다른 기기가 **옮겨서** 잊힌 것이면 그 사실은 다른 범위에 남아 있다: 잊었다고 말하지 않고 다시 읽어 보인다
    @Test func forgetOkAfterAnotherDeviceMovedItDoesNotClaimForgotten() async throws {
        let item = Memories.item(1, "Short FAQs")
        let rows = ServerRows([item])
        serve(rows)
        let moved = Memories.item(
            9, "Short FAQs", scope: .context, context: otherProject, value: .object(["moved_from": .string(item.id.uuidString.lowercased())]), at: 30
        )
        gateway.forgetHandler = { _, _ in
            rows.replace([Memories.item(1, "Short FAQs", version: 2, revoked: true), moved])
            return Memories.item(1, "Short FAQs", version: 2, revoked: true)
        }
        let memory = store()
        await memory.loadList()
        #expect(await memory.forget(item.id) == .refreshed)
        #expect(memory.feedback(for: item.id) == .conflict)
        #expect(memory.noteState(for: item.id) == .current(moved))
        #expect(memory.items.map(\.id) == [moved.id])
    }

    // MARK: 정책 보류 · 기능 꺼짐 · 없는 항목

    @Test func unavailableConfirmAndScopeHideOnlyThatAction() async throws {
        let inferred = Memories.item(1, origin: .inferred)
        let explicit = Memories.item(2)
        serve(ServerRows([inferred, explicit]))
        gateway.confirmHandler = { _, _ in throw APIError.server(status: 409, code: .confirmUnavailable, message: "x") }
        gateway.moveHandler = { _, _, _ in throw APIError.server(status: 409, code: .scopeUnavailable, message: "x") }
        let memory = store()
        await memory.loadList()
        #expect(memory.canConfirm(inferred) && memory.canChangeScope(explicit))
        #expect(await memory.confirm(inferred.id) == .unavailable)
        #expect(await memory.move(explicit.id, to: .context(project)) == .unavailable)
        #expect(!memory.canConfirm(inferred) && !memory.canChangeScope(explicit))
        // 다른 행의 동작은 그대로, 충돌 안내도 아니다
        #expect(memory.canChangeScope(Memories.item(3)))
        #expect(memory.feedback(for: inferred.id) == nil)
        // 감추기는 쓰기 자체를 막지 않는다 (Edit · Forget은 허용)
        #expect(!memory.writesUnavailable)
    }

    /// Slack 원문 후보를 글자 그대로 Edit하려 하면 서버가 거절한다: 글을 고쳐 써야 한다 (Confirm 감춤이 아니다)
    @Test func editUnavailableAsksForNewWording() async throws {
        let inferred = Memories.item(1, "Jordan decides", origin: .inferred)
        serve(ServerRows([inferred]))
        gateway.editHandler = { _, _ in throw APIError.server(status: 409, code: .confirmUnavailable, message: "x") }
        let memory = store()
        await memory.loadList()
        #expect(await memory.edit(inferred.id, statement: "Jordan decides") == .unavailable)
        #expect(memory.feedback(for: inferred.id) == .rewriteToSave)
        #expect(memory.canConfirm(inferred), "Edit 거절이 Confirm을 감추지 않는다")
    }

    @Test func featureOffMakesWritesUnavailableButReadingStillWorks() async throws {
        let item = Memories.item(1)
        serve(ServerRows([item]))
        gateway.forgetHandler = { _, _ in throw APIError.server(status: 404, code: .notFound, message: "없는 경로입니다.") }
        let memory = store()
        await memory.loadList()
        #expect(await memory.forget(item.id) == .unavailable)
        #expect(memory.writesUnavailable)
        #expect(memory.items.count == 1 && memory.load == .loaded)
        #expect(memory.feedback(for: item.id) == nil, "기능 꺼짐을 실패로 꾸미지 않는다")
        // 이제 쓰기를 시도하지 않는다
        #expect(await memory.forget(item.id) == .ignored)
        #expect(gateway.calls(prefix: "forget").count == 1)
    }

    @Test func missingItemIsGoneNotFeatureOff() async throws {
        let item = Memories.item(1)
        let rows = ServerRows([item])
        serve(rows)
        gateway.forgetHandler = { _, _ in
            rows.replace([])
            throw APIError.server(status: 404, code: .notFound, message: "기억이 없습니다.")
        }
        let memory = store()
        await memory.loadList()
        #expect(await memory.forget(item.id) == .unavailable)
        #expect(!memory.writesUnavailable)
        #expect(memory.feedback(for: item.id) == .gone)
        #expect(memory.items.isEmpty)
    }

    @Test func otherFailuresStayRetryableWithAPlainMessage() async throws {
        let item = Memories.item(1)
        serve(ServerRows([item]))
        gateway.forgetHandler = { _, _ in throw APIError.transport("offline") }
        let memory = store()
        await memory.loadList()
        #expect(await memory.forget(item.id) == .failed)
        #expect(memory.feedback(for: item.id) == .failed("Can't reach the server. Check your connection."))
        #expect(memory.items.count == 1, "바뀐 것이 없다")
    }

    // MARK: 접근 상실 · 글 지워짐 · Slack 유래 출처의 추정 (서버 정책 보류 (d))

    @Test func confirmFollowsTheSourcesState() async throws {
        let ref = MemorySourceRef(sourceID: ChatContractFixtures.sourceID, quote: "Thursday")
        let item = Memories.item(1, "Jordan decides", origin: .inferred, sourceRef: ref)
        serve(ServerRows([item]))
        let memory = store()
        await memory.loadList()
        // 출처 상태를 읽기 전에는 주지 않는다
        #expect(!memory.canConfirm(item))
        gateway.sourceHandler = { _ in TestSources.make() }
        await memory.loadSource(for: item)
        #expect(memory.canConfirm(item), "정상 출처의 추정은 Confirm이 보인다")
        for (label, source) in [
            ("접근 상실", TestSources.make(accessLost: true)),
            ("글 지워짐", TestSources.make(purgedReason: "retention")),
            ("Slack 끊김", TestSources.make(url: nil, purgedReason: "disconnected")),
            ("Slack 유래", TestSources.make(url: "https://app.slack.com/client/T1/C1")),
        ] {
            gateway.sourceHandler = { _ in source }
            await memory.loadSource(for: item)
            #expect(!memory.canConfirm(item), "\(label)")
        }
        // 원문 행이 사라졌다
        gateway.sourceHandler = { _ in nil }
        await memory.loadSource(for: item)
        #expect(!memory.canConfirm(item))
    }

    /// 노트는 확인 전 추정의 출처 상태를 미리 읽어 접근 상실이면 처음부터 Confirm을 감춘다
    @Test func noteHidesConfirmUpFrontForAnAccessLostSource() async throws {
        let ref = MemorySourceRef(sourceID: ChatContractFixtures.sourceID)
        let lost = Memories.item(1, origin: .inferred, sourceRef: ref)
        let healthy = Memories.item(2, origin: .inferred, sourceRef: ref)
        serve(ServerRows([lost, healthy]))
        let memory = store()
        gateway.sourceHandler = { _ in TestSources.make(accessLost: true) }
        await memory.loadReferenced(ids: [lost.id])
        #expect(!memory.canConfirm(lost))
        gateway.sourceHandler = { _ in TestSources.make() }
        await memory.loadReferenced(ids: [healthy.id])
        #expect(memory.canConfirm(healthy))
    }

    /// 서버가 `confirm_unavailable`을 주면 (앱이 미리 몰랐던 접근 상실 등) 그 항목의 Confirm을 감추고 지금 상태를 다시 읽는다 — 성공도 실패도 아님
    @Test func serverRefusalHidesConfirmAndRereadsWithoutPretending() async throws {
        let ref = MemorySourceRef(sourceID: ChatContractFixtures.sourceID, quote: "Thursday")
        let item = Memories.item(1, "Jordan decides", origin: .inferred, sourceRef: ref)
        let rows = ServerRows([item])
        serve(rows)
        let lostNow = Box(false)
        gateway.sourceHandler = { _ in TestSources.make(accessLost: lostNow.value) }
        gateway.confirmHandler = { _, _ in
            lostNow.value = true
            throw APIError.server(status: 409, code: .confirmUnavailable, message: "x")
        }
        let memory = store()
        await memory.loadList()
        await memory.loadSource(for: item)
        #expect(memory.canConfirm(item))
        let listReads = gateway.calls(prefix: "currentMemory").count
        #expect(await memory.confirm(item.id) == .unavailable)
        #expect(!memory.canConfirm(item))
        #expect(gateway.calls(prefix: "currentMemory").count > listReads, "지금 상태를 다시 읽었다")
        #expect(memory.feedback(for: item.id) == nil, "실패로 꾸미지 않는다")
        #expect(memory.resolve(item.id) == item.id && memory.items.map(\.id) == [item.id])
        #expect(memory.sourceDisplay(for: item) == .unavailable("Can't open the original"))
    }

    // MARK: 대화 노트가 가리키는 행

    @Test func notesFollowCorrectionsAndNeverShowReplacedOrForgottenAsCurrent() async throws {
        let replaced = Memories.item(1, "v1", superseded: true, supersededBy: ChatContractFixtures.id(2))
        let current = Memories.item(2, "v2")
        let forgotten = Memories.item(3, "gone", revoked: true)
        let rows = ServerRows([replaced, current, forgotten])
        serve(rows)
        let memory = store()
        #expect(memory.noteState(for: replaced.id) == .loading)
        await memory.loadReferenced(ids: [replaced.id, forgotten.id, ChatContractFixtures.id(99)])
        #expect(memory.noteState(for: replaced.id) == .current(current), "정정 뒤 후속 행을 따라간다")
        #expect(memory.noteState(for: forgotten.id) == .notRemembered)
        #expect(memory.noteState(for: ChatContractFixtures.id(99)) == .notRemembered, "읽을 수 없는 행도 이유를 지어내지 않는다")
    }

    // MARK: 목록 캐시와 참조 캐시: 더 새로 읽은 행이 이긴다 (Codex 읽기 검토 P2 A)

    /// 목록으로 받은 옛 "현재" 행이 대화 쪽에서 새로 읽은 행(잊음 → 원문 지움)을 가리지 않는다
    @Test func aNewerReferencedRowBeatsTheOlderListedRow() async throws {
        let v1 = Memories.item(701, "Synthetic old memory", origin: .observed)
        let memory = store()
        gateway.currentMemoryHandler = { [v1] }
        await memory.loadList()
        #expect(memory.noteState(for: v1.id) == .current(v1))
        // 다른 기기가 잊은 뒤 대화 쪽 읽기가 revoked v2를 받는다
        let v2 = Memories.item(701, "Synthetic old memory", origin: .observed, version: 2, revoked: true)
        gateway.memoryItemsHandler = { _ in [v2] }
        await memory.loadReferenced(ids: [v1.id])
        #expect(memory.item(v1.id)?.isCurrent == false && memory.item(v1.id)?.version == 2)
        #expect(memory.noteState(for: v1.id) == .notRemembered)
        #expect(!memory.items.contains { $0.id == v1.id }, "Settings 목록에서도 빠진다")
        // 이어서 원문이 지워져 version 3 · 빈 글: 옛 글을 다시 보이지 않는다
        let v3 = Memories.item(701, origin: .observed, version: 3, revoked: true, purged: true)
        gateway.memoryItemsHandler = { _ in [v3] }
        await memory.loadReferenced(ids: [v1.id])
        #expect(memory.item(v1.id)?.statement == "" && memory.item(v1.id)?.version == 3)
        #expect(MemoryText.statement(try #require(memory.item(v1.id))) == "Original text deleted")
    }

    /// 반대 순서: 노트가 읽은 "현재" 행을, 그 뒤에 읽은 목록(거기 없음)이 가린다 · 목록에도 있으면 그대로
    @Test func aNewerListReadBeatsTheOlderReferencedRow() async throws {
        let v1 = Memories.item(702, "Synthetic memory", origin: .observed)
        let memory = store()
        gateway.memoryItemsHandler = { _ in [v1] }
        await memory.loadReferenced(ids: [v1.id])
        #expect(memory.noteState(for: v1.id) == .current(v1))
        // 목록을 읽어 보니 그 행이 없다 (그 사이 잊었거나 대체됐다): 옛 "현재" 행을 보이지 않는다
        gateway.currentMemoryHandler = { [] }
        await memory.loadList()
        #expect(memory.item(v1.id) == nil)
        #expect(memory.noteState(for: v1.id) == .notRemembered)
        // 목록에 그대로 있으면 현재다
        gateway.currentMemoryHandler = { [v1] }
        await memory.loadList()
        #expect(memory.noteState(for: v1.id) == .current(v1))
    }

    /// 정정 · 옮김의 후속 행도 새로 읽은 쪽을 따른다
    @Test func successorsFollowTheNewerRead() async throws {
        let edited = Memories.item(703, "Synthetic old", version: 1)
        let rows = ServerRows([edited])
        serve(rows)
        let memory = store()
        await memory.loadList()
        // 다른 기기가 정정: 옛 행은 대체, 새 행이 현재
        let successor = Memories.item(704, "Synthetic new", at: 20)
        rows.replace([Memories.item(703, "Synthetic old", version: 2, superseded: true, supersededBy: successor.id), successor])
        await memory.loadReferenced(ids: [edited.id])
        #expect(memory.noteState(for: edited.id) == .current(successor))
        #expect(!memory.items.contains { $0.id == edited.id })
        // 옮김: 옛 행은 잊히고 후속 행(moved_from)이 목록에 있다
        let source = Memories.item(705, "Synthetic scoped", scope: .context, context: project)
        let other = ServerRows([source])
        serve(other)
        let moving = store()
        await moving.loadList()
        let moved = Memories.item(706, "Synthetic scoped", scope: .context, context: otherProject, value: .object(["moved_from": .string(source.id.uuidString.lowercased())]), at: 30)
        other.replace([Memories.item(705, "Synthetic scoped", scope: .context, context: project, version: 2, revoked: true), moved])
        await moving.loadReferenced(ids: [source.id])
        await moving.loadList()
        #expect(moving.noteState(for: source.id) == .current(moved))
    }

    /// 행 없음(지워짐)도 새로 읽은 쪽이 이긴다: 옛 목록 행이 되살아나지 않고, 그 뒤 목록에 다시 있으면 그 행
    @Test func aRowReadAsMissingBeatsTheOlderListedRow() async throws {
        let v1 = Memories.item(707, "Synthetic memory")
        let memory = store()
        gateway.currentMemoryHandler = { [v1] }
        await memory.loadList()
        gateway.memoryItemsHandler = { _ in [] }
        await memory.loadReferenced(ids: [v1.id])
        #expect(memory.item(v1.id) == nil && memory.noteState(for: v1.id) == .notRemembered)
        #expect(!memory.items.contains { $0.id == v1.id })
        gateway.currentMemoryHandler = { [v1] }
        await memory.loadList()
        #expect(memory.item(v1.id)?.id == v1.id)
    }

    /// 늦게 끝난 옛 참조 읽기는 더 새 행을 덮지 못한다
    @Test func aLateOlderReferencedReadDoesNotOverwriteANewerRow() async throws {
        let v1 = Memories.item(708, "Synthetic memory", origin: .observed)
        let v2 = Memories.item(708, "Synthetic memory", origin: .observed, version: 2, revoked: true)
        let latch = Latch()
        let calls = Counter()
        gateway.memoryItemsHandler = { _ in
            if calls.next() == 1 {
                await latch.wait()
                return [v1]
            }
            return [v2]
        }
        let memory = store()
        let old = Task { await memory.loadReferenced(ids: [v1.id]) }
        while await latch.arrivals == 0 { await Task.yield() }
        await memory.loadReferenced(ids: [v1.id])
        #expect(memory.item(v1.id)?.isCurrent == false)
        await latch.open()
        await old.value
        #expect(memory.item(v1.id)?.isCurrent == false && memory.item(v1.id)?.version == 2)
        #expect(memory.noteState(for: v1.id) == .notRemembered)
    }

    /// 늦게 끝난 옛 목록 읽기도 새로 읽은 행을 되살리지 못한다
    @Test func aLateOlderListReadDoesNotResurrectANewerRow() async throws {
        let v1 = Memories.item(709, "Synthetic memory", origin: .observed)
        let v2 = Memories.item(709, "Synthetic memory", origin: .observed, version: 2, revoked: true)
        let latch = Latch()
        gateway.currentMemoryHandler = {
            await latch.wait()
            return [v1]
        }
        let memory = store()
        let old = Task { await memory.loadList() }
        while await latch.arrivals == 0 { await Task.yield() }
        gateway.memoryItemsHandler = { _ in [v2] }
        await memory.loadReferenced(ids: [v1.id])
        await latch.open()
        await old.value
        #expect(memory.item(v1.id)?.isCurrent == false)
        #expect(!memory.items.contains { $0.id == v1.id })
        #expect(memory.noteState(for: v1.id) == .notRemembered)
    }

    /// 계정이 바뀐 뒤 늦게 온 참조 읽기는 반영하지 않는다
    @Test func aLateReferencedReadAfterTheAccountLeftIsIgnored() async throws {
        let v1 = Memories.item(710, "Private words of the previous account")
        let latch = Latch()
        gateway.memoryItemsHandler = { _ in
            await latch.wait()
            return [v1]
        }
        let memory = store()
        let late = Task { await memory.loadReferenced(ids: [v1.id]) }
        while await latch.arrivals == 0 { await Task.yield() }
        scope.accountLeft()
        await latch.open()
        await late.value
        #expect(memory.referenced.isEmpty && memory.item(v1.id) == nil && memory.noteState(for: v1.id) == .loading)
    }

    /// 출처 상태 읽기도 늦게 끝난 옛 응답(접근 있음)이 새 응답(접근 상실)을 덮지 않는다
    @Test func aLateOlderSourceReadDoesNotUndoANewAccessLoss() async throws {
        let ref = MemorySourceRef(sourceID: ChatContractFixtures.sourceID, quote: "Thursday")
        let item = Memories.item(711, "Jordan decides", origin: .inferred, sourceRef: ref)
        serve(ServerRows([item]))
        let latch = Latch()
        let calls = Counter()
        gateway.sourceHandler = { _ in
            if calls.next() == 1 {
                await latch.wait()
                return TestSources.make()
            }
            return TestSources.make(accessLost: true)
        }
        let memory = store()
        await memory.loadList()
        let old = Task { await memory.loadSource(for: item) }
        while await latch.arrivals == 0 { await Task.yield() }
        await memory.loadSource(for: item)
        #expect(!memory.canConfirm(item) && memory.sourceDisplay(for: item) == .unavailable("Can't open the original"))
        await latch.open()
        await old.value
        #expect(!memory.canConfirm(item), "옛 응답(접근 있음)이 Confirm을 되살리지 않는다")
        #expect(memory.sourceDisplay(for: item) == .unavailable("Can't open the original"))
    }

    // MARK: 출처

    @Test func sourceLookupStatesAreFactual() async throws {
        let message = Chats.message(5, in: ChatContractFixtures.conversationID, seq: 1, role: .user, text: "Use the shorter FAQ.", at: 10)
        let item = Memories.item(1, sourceRef: MemorySourceRef(messageID: message.id))
        serve(ServerRows([item]))
        gateway.messageHandler = { _ in message }
        let memory = store()
        await memory.loadList()
        #expect(memory.sourceDisplay(for: item) == .loading)
        await memory.loadSource(for: item)
        guard case .quote(let quote) = memory.sourceDisplay(for: item) else {
            Issue.record("인용이 아님")
            return
        }
        #expect(quote.from == "You" && quote.place == "Chat" && quote.service == nil && quote.text == "Use the shorter FAQ.")
        // 글이 지워졌다: 옛 인용을 다시 보이지 않는다
        gateway.messageHandler = { _ in nil }
        await memory.loadSource(for: item)
        #expect(memory.sourceDisplay(for: item) == .unavailable("Original text deleted"))
        // 읽기 실패는 인용을 지어내지 않는다
        gateway.messageHandler = { _ in throw URLError(.timedOut) }
        await memory.loadSource(for: item)
        #expect(memory.sourceDisplay(for: item) == .failed)
    }

    // MARK: 계정 경계

    @Test func leavingTheAccountClearsEverythingAndDropsLateAnswers() async throws {
        let item = Memories.item(1, origin: .inferred)
        let rows = ServerRows([item])
        serve(rows)
        let latch = Latch()
        gateway.confirmHandler = { _, _ in await latch.wait(); return Memories.item(2) }
        let memory = store()
        await memory.loadList()
        let late = Task { await memory.confirm(item.id) }
        while await latch.arrivals == 0 { await Task.yield() }
        scope.accountLeft()
        #expect(memory.items.isEmpty && memory.load == .idle && memory.contexts.isEmpty && !memory.isBusy(item.id))
        await latch.open()
        #expect(await late.value == .ignored)
        // 늦은 응답이 다음 계정의 상태를 건드리지 않는다
        #expect(memory.items.isEmpty && memory.resolve(item.id) == item.id)
    }
}

/// 몇 번째 호출인가
final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func next() -> Int {
        lock.lock()
        defer { lock.unlock() }
        value += 1
        return value
    }
}
