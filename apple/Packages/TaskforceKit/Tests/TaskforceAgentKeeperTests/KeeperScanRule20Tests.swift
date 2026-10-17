#if os(macOS)
import Darwin
import Foundation
import Testing
@testable import TaskforceAgentWire

/// 20장 (재검토 11): 18 · 19장 예외의 부모 동일성을 벽시계 대신 unique id 순서로 가른다 (fork 때 전역 카운터로 늘어나는 단조 값).
/// - 자식 세대를 읽은 갈래(좀비 · 책임 조회 중 사라짐 · 15장 3 다시 disclaim): 부모 id < 자식 id일 때만 무해 — `PT_DETACH`가 재사용된 pid의 새 프로세스 T에
///   붙이고 exec이 부모 unique id를 T로 갱신해도 T는 자식 뒤에 생겼다.
/// - 자식 세대를 못 읽은 갈래(`.gone`): 목록 부모 pid의 지금 프로세스가 지킴이보다 먼저 생겼을 때(id < 지킴이)만 무해 — 그러면 스냅숏 때도 그 pid의 주인이었다.
/// 목록 · 조회를 끼워 넣어 결정적으로 본다 (`KeeperScanRulesTests.World`)
struct KeeperScanRule20Tests {
    typealias World = KeeperScanRulesTests.World
    typealias Rule18 = KeeperScanRule18Tests
    typealias Rule19 = KeeperScanRule19Tests

    func scan(_ world: World) -> KeeperMembers.Scan? {
        KeeperMembers.scan(keeperPID: world.me, keeperID: world.own.own, lookups: world.lookups)
    }

    /// 구성원 C 추적 → C의 원래 부모 끝 · 회수 → 무관한 T가 그 pid를 다시 씀 → detach(T에 붙고 추적 표시 · `p_oppid`를 지운다) → C가 exec(부모 unique id = T).
    /// T는 살아 있고 좀비가 아니며 책임 프로세스는 다른 앱이고, C보다 뒤에 생겼다(id · 달력 시각 모두). 목록의 C 행은 추적 표시가 없다
    static func detachedToAReusedPID(_ world: World) -> (t: ProcessGeneration, child: ProcessGeneration) {
        let t = Rule18.parent(world, startSeconds: world.own.startSeconds + 2, own: world.own.own + 2_000_000)
        let child = world.process(parentPID: t.pid, parentID: t.own)
        return (t, child)
    }

    // MARK: 자식 세대를 읽은 갈래: 부모 id < 자식 id

    @Test func aZombieDetachedToAReusedParentPIDThenExecIsNeverExcused() throws {
        let world = try World()
        let t = Rule18.parent(world, startSeconds: world.own.startSeconds + 2, own: world.own.own + 2_000_000)
        let zombie = Rule19.zombie(world, parentPID: t.pid, parentID: t.own)
        #expect(zombie.parent == t.own && t.own > zombie.own, "시험 전제: 부모 unique id = T, T가 자식 뒤에 생겼다")
        #expect(scan(world)?.complete == false, "fork 뒤 좀비가 된 C의 부모 T는 C보다 뒤에 생겼다: C의 원래 부모가 아니다")
    }

    @Test func aChildVanishedAtResponsibilityAfterADetachToAReusedParentPIDIsNeverExcused() throws {
        let world = try World()
        let (_, child) = Self.detachedToAReusedPID(world)
        world.responsible[child.pid] = .gone
        #expect(scan(world)?.complete == false)
        // 같은 순서를 pid 변형으로
        var byPID = world.lookups
        byPID.responsibleUniqueID = nil
        world.responsiblePIDs[child.pid] = .gone
        for row in world.entries where row.pid != child.pid { world.responsiblePIDs[row.pid] = .present(4242) }
        #expect(KeeperMembers.scan(keeperPID: world.me, keeperID: world.own.own, lookups: byPID)?.complete == false, "pid 변형")
    }

    @Test func aRedisclaimedChildDetachedToAReusedParentPIDIsNeverExcused() throws {
        // 15장 3: 스스로 책임인 자식도 읽은 세대의 부모 unique id로 부모를 가른다 — 같은 순서로 부모가 T가 된다
        let world = try World()
        let (_, child) = Self.detachedToAReusedPID(world)
        world.responsible[child.pid] = .present(child.own)
        #expect(scan(world)?.complete == false)
    }

    @Test func aParentYoungerThanTheKeeperButOlderThanItsChildStillExcusesZombiesAndResponsibilityVanishes() throws {
        // 세션 중에 시작한 빌드(지킴이 뒤에 생긴 무관한 부모)의 좀비 · 책임 조회 중 사라짐 · disclaim은 막지 않는다
        let zombie = try World()
        let build = Rule18.parent(zombie, young: true)
        Rule19.zombie(zombie, parentPID: build.pid, parentID: build.own)
        #expect(scan(zombie) == KeeperMembers.Scan(members: [], complete: true), "좀비")
        let vanished = try World()
        let other = Rule18.parent(vanished, young: true)
        Rule18.vanishedAtResponsibility(vanished, parent: other)
        #expect(scan(vanished) == KeeperMembers.Scan(members: [], complete: true), "책임 조회에서 사라짐")
        let redisclaimed = try World()
        let host = Rule18.parent(redisclaimed, young: true)
        let child = redisclaimed.process(parentPID: host.pid, parentID: host.own)
        redisclaimed.responsible[child.pid] = .present(child.own)
        #expect(scan(redisclaimed) == KeeperMembers.Scan(members: [], complete: true), "다시 disclaim (Chrome native host 같은 다른 앱)")
    }

    // MARK: 자식 세대를 못 읽은 갈래(`.gone`): 부모 id < 지킴이 id

    @Test func aGoneChildUnderAParentYoungerThanTheKeeperMakesTheScanIncomplete() throws {
        // 생존 쪽 결과: 세션 중에 시작한 빌드의 자식이 목록과 세대 조회 사이에 거둬지면 그 훑기는 불완전이다 (빌드가 끝나면 끝을 증명한다)
        let world = try World()
        let build = Rule18.parent(world, young: true)
        world.listed(parentPID: build.pid)
        #expect(scan(world)?.complete == false)
    }

    @Test func aGoneChildUnderAParentOlderThanTheKeeperLeavesTheScanComplete() throws {
        let world = try World()
        let shell = Rule18.parent(world)
        #expect(shell.own < world.own.own, "시험 전제: 지킴이보다 먼저 생긴 부모")
        world.listed(parentPID: shell.pid)
        #expect(scan(world) == KeeperMembers.Scan(members: [], complete: true))
        // 부모 자신의 행은 필요 없다: 지킴이 전부터 살아 있는 프로세스는 스냅숏 때도 그 pid의 주인이었다
        let rowless = try World()
        let daemon = Rule18.parent(rowless)
        rowless.entries.removeAll { $0.pid == daemon.pid }
        rowless.listed(parentPID: daemon.pid)
        #expect(scan(rowless) == KeeperMembers.Scan(members: [], complete: true), "부모 행 없음")
    }

    @Test func aClockRollbackCannotMakeAReusedParentLookOlderThanAGoneChild() throws {
        // detach 뒤 부모 행과 지금 조회는 모두 T다(같은 시작 시각). 시계가 뒤로 갔으면 T의 달력 시작이 자식보다 앞이어도 T의 id는 지킴이 · 자식 뒤다
        let world = try World()
        let t = Rule18.parent(world, startSeconds: world.own.startSeconds - 5, own: world.own.own + 2_000_000)
        world.listed(parentPID: t.pid)
        #expect(scan(world)?.complete == false)
    }
}
#endif
