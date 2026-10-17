#if os(macOS)
import Darwin
import Foundation
import Testing
@testable import TaskforceAgentWire

/// 21장 (재검토 12): "부모가 무관하다"를 근거로 쓰는 모든 길(`.gone` · 좀비 · 책임 조회 중 사라짐 · 15장 3 다시 disclaim)이 한 확인을 거친다 —
/// 추적 아님(목록 행 · 세대 조회 때) · 목록 부모 pid의 지금 프로세스 = 세대의 부모 id · 부모 pid ≠ 1 · ≠ 지킴이 · 앞뒤 같은 id · 좀비 아님 ·
/// 순서(부모 < 자식, `.gone`은 부모 < 지킴이) · 책임 ≠ 지킴이 · seen 밖. 15장 3은 지킴이 앞에 생긴 부모(launchd 포함)면 앞의 둘만 증명하면 된다.
/// 목록 · 조회를 끼워 넣어 결정적으로 본다 (`KeeperScanRulesTests.World`)
struct KeeperScanRule21Tests {
    typealias World = KeeperScanRulesTests.World
    typealias Rule18 = KeeperScanRule18Tests
    typealias Rule19 = KeeperScanRule19Tests

    func scan(_ world: World) -> KeeperMembers.Scan? {
        KeeperMembers.scan(keeperPID: world.me, keeperID: world.own.own, lookups: world.lookups)
    }

    /// 그 pid의 세대를 바꿔 적는다 (부모 pid · 부모 id · 추적 · 좀비)
    @discardableResult
    static func regenerate(
        _ world: World, _ process: ProcessGeneration, parentPID: pid_t? = nil, parent: UInt64? = nil, traced: Bool? = nil, zombie: Bool? = nil
    ) -> ProcessGeneration {
        let changed = ProcessGeneration(
            pid: process.pid, startSeconds: process.startSeconds, startMicros: process.startMicros, parentPID: parentPID ?? process.parentPID, group: process.group,
            uid: process.uid, zombie: zombie ?? process.zombie, own: process.own, parent: parent ?? process.parent, version: process.version, traced: traced ?? process.traced
        )
        world.generations[process.pid] = .present(changed)
        return changed
    }

    /// 목록의 그 pid 행을 바꿔 적는다 (부모 pid · 추적 · 원래 부모)
    static func relist(_ world: World, pid: pid_t, parentPID: pid_t, traced: Bool = false, originalParentPID: pid_t = 0) {
        guard let index = world.entries.firstIndex(where: { $0.pid == pid }) else { return }
        let row = world.entries[index]
        world.entries[index] = ListedProcess(
            pid: row.pid, parentPID: parentPID, uid: row.uid, ruid: row.ruid, startSeconds: row.startSeconds, startMicros: row.startMicros, traced: traced,
            originalParentPID: originalParentPID
        )
    }

    /// 무관한 tracer T: 지킴이 앞(`old`) 또는 뒤에 생겼고 책임 프로세스는 다른 앱이다
    static func tracer(_ world: World, old: Bool) -> ProcessGeneration {
        old ? Rule18.parent(world) : Rule18.parent(world, young: true)
    }

    /// 구성원 C가 다시 disclaim으로 띄운 V (스스로 책임 프로세스, 지킴이 뒤에 생겼다). C가 살아 있으면(`alive`) 목록 · 조회에 있고, 아니면 pid만 남는다
    static func redisclaimedByMember(_ world: World, alive: Bool) -> (member: pid_t, v: ProcessGeneration) {
        let member: pid_t
        if alive {
            member = Rule18.parent(world, responsible: .present(world.own.own), young: true).pid
        } else {
            member = world.next
            world.next += 1
        }
        let pid = world.next
        let v = world.process(parentPID: member, parentID: world.own.own + UInt64(member), responsibleID: world.own.own + UInt64(pid))
        return (member, v)
    }

    // MARK: 반례와 그 갈래 — 모두 불완전

    @Test func theReviewersCounterexampleOldTracerRedisclaimExecAndMemberExitIsIncomplete() throws {
        // 재검토 12: T가 V를 attach하고 V가 exec(부모 id = T, 책임은 V 그대로), 구성원 C가 끝났다. V는 추적 중이고 지금 부모는 T다
        for old in [true, false] {
            let world = try World()
            let t = Self.tracer(world, old: old)
            let (member, v) = Self.redisclaimedByMember(world, alive: false)
            Self.relist(world, pid: v.pid, parentPID: t.pid, traced: true, originalParentPID: member)
            Self.regenerate(world, v, parentPID: t.pid, parent: t.own, traced: true)
            #expect(scan(world)?.complete == false, old ? "지킴이 앞에 생긴 tracer" : "지킴이 뒤에 생긴 tracer")
        }
    }

    @Test func anExecWhileTracedFollowedByADetachIsIncomplete() throws {
        // V가 추적 중에 exec(부모 id = T)하고 T가 떨어졌다: 부모는 살아 있는 구성원 C로 돌아왔고 표시는 지워졌다 — 목록 부모 C ≠ 세대 부모 T
        for old in [true, false] {
            let world = try World()
            let t = Self.tracer(world, old: old)
            let (_, v) = Self.redisclaimedByMember(world, alive: true)
            Self.regenerate(world, v, parent: t.own)
            #expect(scan(world)?.complete == false, old ? "지킴이 앞에 생긴 tracer" : "지킴이 뒤에 생긴 tracer")
        }
    }

    @Test func anAttachAfterTheListingIsIncomplete() throws {
        // 목록 때는 추적 아님 · 부모 C였는데, 그 뒤 T가 attach하고 V가 exec했다: 세대 조회 때 추적 중 · 부모 pid · id = T
        for old in [true, false] {
            let world = try World()
            let t = Self.tracer(world, old: old)
            let (_, v) = Self.redisclaimedByMember(world, alive: true)
            Self.regenerate(world, v, parentPID: t.pid, parent: t.own, traced: true)
            #expect(scan(world)?.complete == false, old ? "지킴이 앞에 생긴 tracer" : "지킴이 뒤에 생긴 tracer")
        }
    }

    @Test func aParentIDLeftMismatchedAfterADetachIsIncomplete() throws {
        // 추적 중 exec(부모 id = T) 뒤 C가 끝났고 T가 떨어졌다: 원래 부모를 찾지 못해 launchd로 — 목록 부모 1(id 1) ≠ 세대 부모 T
        for old in [true, false] {
            let world = try World()
            world.generations[1] = .failed
            world.uniqueIDs[1] = .present(1)
            let t = Self.tracer(world, old: old)
            let (_, v) = Self.redisclaimedByMember(world, alive: false)
            Self.relist(world, pid: v.pid, parentPID: 1)
            Self.regenerate(world, v, parentPID: 1, parent: t.own)
            #expect(scan(world)?.complete == false, old ? "지킴이 앞에 생긴 tracer" : "지킴이 뒤에 생긴 tracer")
        }
    }

    @Test func aChildTracedAtItsGenerationReadIsNeverExcused() throws {
        // 목록 때는 추적 아님, 세대 조회 때 추적 중 (그 사이 attach): 책임 조회 중 사라짐 · 좀비 · 다시 disclaim 셋 다
        for old in [true, false] {
            let vanished = try World()
            let parent = old ? Rule18.parent(vanished) : Rule18.parent(vanished, young: true)
            let child = vanished.process(parentPID: parent.pid, parentID: parent.own)
            vanished.responsible[child.pid] = .gone
            Self.regenerate(vanished, child, traced: true)
            #expect(scan(vanished)?.complete == false, "책임 조회에서 사라짐 \(old)")
            let zombie = try World()
            let zombieParent = old ? Rule18.parent(zombie) : Rule18.parent(zombie, young: true)
            let dead = Rule19.zombie(zombie, parentPID: zombieParent.pid, parentID: zombieParent.own)
            Self.regenerate(zombie, dead, traced: true)
            #expect(scan(zombie)?.complete == false, "좀비 \(old)")
            let disclaimed = try World()
            let app = old ? Rule18.parent(disclaimed) : Rule18.parent(disclaimed, young: true)
            let pid = disclaimed.next
            let v = disclaimed.process(parentPID: app.pid, parentID: app.own, responsibleID: disclaimed.own.own + UInt64(pid))
            Self.regenerate(disclaimed, v, traced: true)
            #expect(scan(disclaimed)?.complete == false, "다시 disclaim \(old)")
        }
    }

    // MARK: 생존 — 무관한 부모 아래 평범한 생멸은 그대로 완전

    @Test func ordinaryChurnUnderAnUnrelatedParentStaysComplete() throws {
        for old in [true, false] {
            let world = try World()
            let parent = old ? Rule18.parent(world) : Rule18.parent(world, young: true)
            Rule19.zombie(world, parentPID: parent.pid, parentID: parent.own)
            Rule18.vanishedAtResponsibility(world, parent: parent)
            if old { world.listed(parentPID: parent.pid) }
            let pid = world.next
            world.process(parentPID: parent.pid, parentID: parent.own, responsibleID: world.own.own + UInt64(pid))
            #expect(scan(world) == KeeperMembers.Scan(members: [], complete: true), old ? "지킴이 앞에 생긴 부모" : "지킴이 뒤에 생긴 부모")
        }
    }

    @Test func anAppLaunchedByLaunchdAfterTheKeeperStaysComplete() throws {
        // LaunchServices · XPC: 부모 launchd(세대 조회는 다른 사용자라 실패, unique id 1만 읽힌다), 스스로 책임 프로세스, 부모 id = launchd
        let world = try World()
        world.generations[1] = .failed
        world.uniqueIDs[1] = .present(1)
        let pid = world.next
        world.process(parentPID: 1, parentID: 1, responsibleID: world.own.own + UInt64(pid))
        #expect(scan(world) == KeeperMembers.Scan(members: [], complete: true))
    }

    // MARK: 실제 조회

    @Test func theLiveUniqueIDLookupReadsLaunchdAndAgreesWithTheGeneration() throws {
        // 세대 조회(flavor 18)는 다른 사용자인 launchd를 읽지 못하고, unique id 조회(flavor 17)는 읽는다
        #expect(AgentProcesses.generation(pid: 1) == .failed)
        guard case .present(let launchd) = AgentProcesses.uniqueID(pid: 1) else {
            Issue.record("launchd의 unique id를 읽었다")
            return
        }
        #expect(launchd > 0)
        guard case .present(let me) = AgentProcesses.generation(pid: getpid()) else { throw CancellationError() }
        #expect(AgentProcesses.uniqueID(pid: getpid()) == .present(me.own))
        #expect(AgentProcesses.uniqueID(pid: 0) == .failed)
    }
}
#endif
