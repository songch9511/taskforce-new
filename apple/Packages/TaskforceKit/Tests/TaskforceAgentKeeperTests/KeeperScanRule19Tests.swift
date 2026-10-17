#if os(macOS)
import Darwin
import Foundation
import Synchronization
import Testing
@testable import TaskforceAgentWire

/// 19장 (재검토 10): 18장 예외에 더한 조건 — 추적 중 아님 · 두 목록 일치 · 부모 세대로 책임 조회를 묶음 (넷째 시작 시각 조건은 20장이 unique id 순서로 바꿨다).
/// 하나라도 아니면 그 훑기는 불완전이다. 목록 · 조회를 끼워 넣어 결정적으로 본다 (`KeeperScanRulesTests.World`)
struct KeeperScanRule19Tests {
    typealias World = KeeperScanRulesTests.World
    typealias Rule18 = KeeperScanRule18Tests

    func scan(_ world: World, lookups: KeeperMembers.Lookups? = nil) -> KeeperMembers.Scan? {
        KeeperMembers.scan(keeperPID: world.me, keeperID: world.own.own, lookups: lookups ?? world.lookups)
    }

    /// 목록의 그 pid 행을 바꿔 적는다 (추적 표시 · 원래 부모)
    static func mark(_ world: World, pid: pid_t, traced: Bool = false, originalParentPID: pid_t = 0) {
        guard let index = world.entries.firstIndex(where: { $0.pid == pid }) else { return }
        let row = world.entries[index]
        world.entries[index] = ListedProcess(
            pid: row.pid, parentPID: row.parentPID, uid: row.uid, ruid: row.ruid, startSeconds: row.startSeconds, startMicros: row.startMicros,
            traced: traced, originalParentPID: originalParentPID
        )
    }

    /// 무관한 부모 아래 (a) 세대 조회에서 사라진 자식 · (b) 책임 조회에서 사라진 자식 — 18장 규칙만이면 둘 다 완전이다
    static func worlds() throws -> [(name: String, world: World, child: pid_t, parent: ProcessGeneration)] {
        let a = try World()
        let parentA = Rule18.parent(a)
        let childA = a.listed(parentPID: parentA.pid)
        let b = try World()
        let parentB = Rule18.parent(b)
        let childB = b.process(parentPID: parentB.pid, parentID: parentB.own)
        b.responsible[childB.pid] = .gone
        return [("(a) 세대 조회에서 사라짐", a, childA, parentA), ("(b) 책임 조회에서 사라짐", b, childB.pid, parentB)]
    }

    // MARK: 정상 — 그대로 완전

    @Test func aChildThatVanishedUnderAnUntracedUnrelatedParentStillLeavesTheScanComplete() throws {
        for (name, world, _, _) in try Self.worlds() {
            #expect(scan(world) == KeeperMembers.Scan(members: [], complete: true), "\(name)")
        }
    }

    // MARK: 1 (P1) 추적

    @Test func aTracedChildIsNeverExcused() throws {
        for (name, world, child, _) in try Self.worlds() {
            Self.mark(world, pid: child, traced: true)
            #expect(scan(world)?.complete == false, "\(name): P_TRACED — 지금 부모는 tracer다")
        }
    }

    @Test func aChildWithASavedOriginalParentIsNeverExcused() throws {
        for (name, world, child, _) in try Self.worlds() {
            Self.mark(world, pid: child, originalParentPID: 4242)
            #expect(scan(world)?.complete == false, "\(name): p_oppid ≠ 0 — 추적이 끝나지 않았다")
        }
    }

    // MARK: 2 (P2) 두 목록

    @Test func twoListingsThatDisagreeKeepBothRowsAndAgreeingRowsCollapse() {
        let row = ListedProcess(pid: 900_001, parentPID: 500, uid: 501, ruid: 501, startSeconds: 10, startMicros: 1)
        #expect(AgentProcesses.merged([row], [row]) == [row], "같은 프로세스는 하나")
        for other in [
            ListedProcess(pid: 900_001, parentPID: 600, uid: 501, ruid: 501, startSeconds: 10, startMicros: 1),
            ListedProcess(pid: 900_001, parentPID: 500, uid: 501, ruid: 501, startSeconds: 11, startMicros: 1),
            ListedProcess(pid: 900_001, parentPID: 500, uid: 501, ruid: 501, startSeconds: 10, startMicros: 2),
            ListedProcess(pid: 900_001, parentPID: 500, uid: 0, ruid: 501, startSeconds: 10, startMicros: 1),
            ListedProcess(pid: 900_001, parentPID: 500, uid: 501, ruid: 0, startSeconds: 10, startMicros: 1),
        ] {
            #expect(AgentProcesses.merged([row], [other]) == [row, other], "다른 부모 · 시작 시각 · 사용자: 둘 다 남는다 (버리지 않는다)")
        }
    }

    @Test func twoListingsThatDisagreeMakeTheScanIncomplete() throws {
        for (name, world, _, parent) in try Self.worlds() {
            // 무관한 부모가 다른 목록에서 다른 시작 시각으로 나왔다 (그 사이 pid 재사용)
            world.entries.append(ListedProcess(
                pid: parent.pid, parentPID: 1, uid: world.uid, ruid: world.uid, startSeconds: parent.startSeconds + 5, startMicros: parent.startMicros
            ))
            #expect(scan(world)?.complete == false, "\(name)")
        }
        let quiet = try World()
        let other = quiet.process(responsibleID: 12345)
        quiet.entries.append(ListedProcess(pid: other.pid, parentPID: 4242, uid: quiet.uid, ruid: quiet.uid, startSeconds: other.startSeconds, startMicros: other.startMicros))
        #expect(scan(quiet)?.complete == false, "사라진 것이 없어도 두 목록이 다른 부모를 말하면 불완전")
    }

    // MARK: 3 (P2) 책임 조회를 부모 세대로 묶는다

    /// 자식을 가르며 부모의 책임을 읽은 뒤부터 그 pid의 세대가 `after`로 보인다. 부모 행이 먼저 훑힌다: 지킴이 뒤에 생긴 부모면 부모 자신의 책임 조회가 첫째라
    /// 둘째 책임 조회 뒤부터, 지킴이 앞에 생긴 부모(행을 건너뛴다)면 첫째 뒤부터다
    static func swapAfterResponsibility(_ world: World, parent: ProcessGeneration, after: ProcessLookup<ProcessGeneration>) -> KeeperMembers.Lookups {
        #expect(world.entries.firstIndex { $0.pid == parent.pid } == 0, "부모 행이 먼저 (시험 전제)")
        let first = parent.own > world.own.own ? 2 : 1
        let reads = Mutex(0)
        var lookups = world.lookups
        let generation = lookups.generation
        let byID = lookups.responsibleUniqueID
        lookups.responsibleUniqueID = { pid in
            if pid == parent.pid { reads.withLock { $0 += 1 } }
            return byID?(pid) ?? .failed
        }
        lookups.generation = { pid in pid == parent.pid && reads.withLock({ $0 }) >= first ? after : generation(pid) }
        return lookups
    }

    @Test func aParentWhoseGenerationChangesAcrossTheResponsibilityLookupMakesTheScanIncomplete() throws {
        for (name, world, _, parent) in try Self.worlds() {
            let reused = ProcessGeneration(
                pid: parent.pid, startSeconds: parent.startSeconds, startMicros: parent.startMicros, parentPID: 1, group: parent.pid, uid: world.uid, zombie: false,
                own: parent.own + 1000, parent: 1
            )
            let zombie = ProcessGeneration(
                pid: parent.pid, startSeconds: parent.startSeconds, startMicros: parent.startMicros, parentPID: 1, group: parent.pid, uid: world.uid, zombie: true,
                own: parent.own, parent: 1
            )
            for (after, what) in [(ProcessLookup.present(reused), "다른 unique id"), (.present(zombie), "좀비"), (.gone, "사라짐"), (.failed, "조회 실패")] {
                let lookups = Self.swapAfterResponsibility(world, parent: parent, after: after)
                #expect(scan(world, lookups: lookups)?.complete == false, "\(name): 책임 조회 뒤 부모 \(what)")
            }
        }
    }

    @Test func aRedisclaimedChildWhoseParentChangesAcrossTheResponsibilityLookupMakesTheScanIncomplete() throws {
        // 15장 3: 스스로 책임인 자식의 무관한 부모도 같은 묶음으로 증명한다 (15장 3은 지킴이 뒤에 생긴 부모만 본다)
        let world = try World()
        let parent = Rule18.parent(world, young: true)
        let child = world.process(parentPID: parent.pid, parentID: parent.own)
        world.responsible[child.pid] = .present(child.own)
        #expect(scan(world)?.complete == true, "무관한 부모 (시험 전제)")
        let reused = ProcessGeneration(
            pid: parent.pid, startSeconds: parent.startSeconds, startMicros: parent.startMicros, parentPID: 1, group: parent.pid, uid: world.uid, zombie: false,
            own: parent.own + 1000, parent: 1
        )
        let lookups = Self.swapAfterResponsibility(world, parent: parent, after: .present(reused))
        #expect(scan(world, lookups: lookups)?.complete == false)
    }

    // MARK: 4 (P2) (a)의 부모 동일성 — 20장이 시작 시각 비교를 unique id 순서로 바꿨다 (`KeeperScanRule20Tests`)

    // MARK: 19.1 좀비 = 사라짐

    /// 지킴이 뒤에 시작해 목록에 있고 조회 때 좀비인 자식 (목록 뒤에 목록에 없는 자식을 남기고 끝났을 수 있다: launchd가 아직 거두지 않았다)
    @discardableResult
    static func zombie(_ world: World, parentPID: pid_t, parentID: UInt64) -> ProcessGeneration {
        let child = world.process(parentPID: parentPID, parentID: parentID)
        let zombie = ProcessGeneration(
            pid: child.pid, startSeconds: child.startSeconds, startMicros: child.startMicros, parentPID: 1, group: child.group, uid: child.uid, zombie: true,
            own: child.own, parent: child.parent
        )
        world.generations[child.pid] = .present(zombie)
        world.responsible[child.pid] = .gone
        return zombie
    }

    @Test func aZombieUnderAnUnrelatedParentLeavesTheScanComplete() throws {
        let world = try World()
        let parent = Rule18.parent(world)
        Self.zombie(world, parentPID: parent.pid, parentID: parent.own)
        #expect(scan(world) == KeeperMembers.Scan(members: [], complete: true), "읽은 세대의 부모 unique id로 무관한 부모를 증명했다")
    }

    @Test func aZombieThatStartedAfterTheKeeperIsTreatedLikeAVanishedProcess() throws {
        let member = try World()
        let memberParent = Rule18.parent(member, responsible: .present(member.own.own), young: true)
        Self.zombie(member, parentPID: memberParent.pid, parentID: memberParent.own)
        #expect(scan(member)?.complete == false, "부모가 구성원: 좀비가 끝나기 전에 띄운 자식은 목록에 없다")
        let orphan = try World()
        Self.zombie(orphan, parentPID: 1, parentID: 1)
        #expect(scan(orphan)?.complete == false, "부모가 launchd (fork 사슬의 고리)")
        let vanished = try World()
        Self.zombie(vanished, parentPID: 777_777, parentID: 4242)
        #expect(scan(vanished)?.complete == false, "부모도 사라짐")
        let traced = try World()
        let tracedParent = Rule18.parent(traced)
        let child = Self.zombie(traced, parentPID: tracedParent.pid, parentID: tracedParent.own)
        Self.mark(traced, pid: child.pid, traced: true)
        #expect(scan(traced)?.complete == false, "추적 중")
    }

    @Test func aZombieThatStartedBeforeTheKeeperIsStillSkipped() throws {
        let world = try World()
        let pid = world.listed(after: false, parentPID: 1)
        world.generations[pid] = .present(ProcessGeneration(
            pid: pid, startSeconds: world.own.startSeconds - 1, startMicros: world.own.startMicros, parentPID: 1, group: pid, uid: world.uid, zombie: true,
            own: world.own.own - 1, parent: 1
        ))
        #expect(scan(world) == KeeperMembers.Scan(members: [], complete: true))
    }
}
#endif
