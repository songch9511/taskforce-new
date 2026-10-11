import Foundation
import Testing
@testable import TaskforceKit

/// D13 · ARCH07 대조 (앱 쪽): 범위 멤버십은 묶음 · 검색 · 정리일 뿐 실행 권한이 아니다. 멤버십 변경은 실행 · 정책 · 승인 · 완료 · 할 일 필드 경로를 부르지 않는다
@MainActor
struct MembershipIsNotPermissionTests {
    let shape = ContextFx.context(1, "Shape launch", version: 3)
    let acme = ContextFx.context(2, "Acme website", version: 5)
    let a = WorkListTests.id(1)

    /// 멤버십을 어떻게 바꿔도 서버로 나가는 것은 범위 읽기 둘과 멤버십 쓰기 둘뿐이다 (게이트웨이 면에 그 밖의 것이 없다)
    @Test func everyMembershipChangeOnlyReadsContextsAndWritesMemberships() async {
        let server = FakeContextServer(contexts: [shape, acme])
        let store = WorkContextStore(gateway: server, scope: ChatTestAccount.fixedScope())
        server.seed(shape.id, a, origin: .auto)
        await store.refresh()
        await store.add(a, to: shape.id)
        await store.move(a, from: shape.id, to: acme.id)
        await store.undoLast(a)
        await store.remove(a, from: shape.id)
        await store.undoLast(a)
        server.otherDevice(.add, ctx: acme.id, action: a)
        await store.add(a, to: acme.id)
        for call in server.calls {
            switch call {
            case .contexts, .members, .change, .move: break
            }
        }
        #expect(!server.calls.isEmpty && server.writes.count >= 4)
    }

    /// 멤버십 쓰기 끝점이 부르는 경로는 `contexts/…/members[/move]` 둘뿐 (`ContextContractTests`가 요청 경로를 고정한다). 여기서는 소스에 실행 · 정책 호출이 없음을 고정한다
    @Test func membershipSourcesNeverReachExecutionOrPolicyCalls() throws {
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/TaskforceKit")
        let files = ["WorkContextStore.swift", "ContextEndpoints.swift", "ContextGateway.swift", "ContextReads.swift", "ContextModels.swift", "WorkMembership.swift", "ProjectLinkRules.swift"]
        // 실행 · 승인 · 정책 · 완료 · 착수 · 할 일 수정 · 동의 호출 이름
        let forbidden = [
            "createRun", "stopRun", "startAction", "setProgress", "confirmAction", "editAction", "deleteAction", "handoff(", "giveAIConsent",
            "RunStore", "RunSummary", "ExecutionPolicy", "approve", "begin_call", "createAction", "RunRules",
        ]
        for file in files {
            let text = try String(contentsOf: sources.appendingPathComponent(file), encoding: .utf8)
            // 주석 줄은 설명이므로 코드 줄만 본다
            let code = text.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }.joined(separator: "\n")
            for name in forbidden {
                #expect(!code.contains(name), "\(file)이 \(name)을 부른다")
            }
        }
    }

    /// 멤버십이 바뀌어도 할 일의 필드(상태 · 활동 · 수행자 · 기한 · 이유)는 그대로다
    @Test func changingMembershipsLeavesTheActionFieldsAlone() async {
        let open = [WorkListTests.action(1, started: true), WorkListTests.action(2)]
        let before = WorkItem.list(reviews: [], open: open, doneToday: [], working: [a], memberships: .empty)
        let server = FakeContextServer(contexts: [shape, acme])
        let store = WorkContextStore(gateway: server, scope: ChatTestAccount.fixedScope())
        await store.refresh()
        await store.add(a, to: shape.id)
        await store.move(a, from: shape.id, to: acme.id)
        let after = WorkItem.list(reviews: [], open: open, doneToday: [], working: [a], memberships: store.index)
        #expect(before.map(\.action) == after.map(\.action))
        #expect(before.map(\.state) == after.map(\.state) && before.map(\.activity) == after.map(\.activity))
        #expect(before.map(\.performer) == after.map(\.performer) && before.map(\.reasons) == after.map(\.reasons))
        #expect(after[0].memberships.links.map(\.project.name) == ["Acme website"] && before[0].memberships == .none)
    }
}
