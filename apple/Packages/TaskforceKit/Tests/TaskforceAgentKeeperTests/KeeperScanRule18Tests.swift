#if os(macOS)
import Darwin
import Foundation
import Testing
@testable import TaskforceAgentWire

/// 18장 훑기 규칙: 지킴이 뒤에 시작해 훑는 사이에 사라진 프로세스는, 목록의 부모가 지금 같은 프로세스로 살아 있고 구성원이 아님을 증명할 때만 불완전으로 치지 않는다
/// (같은 프로세스 · 순서는 20장: unique id 순서로 가른다).
/// 시험 프로세스를 지킴이로 치고 목록 · 조회를 끼워 넣어 결정적으로 본다 (`KeeperScanRulesTests.World`)
struct KeeperScanRule18Tests {
    typealias World = KeeperScanRulesTests.World

    /// 무관한 부모 하나 (책임 프로세스는 다른 앱). 목록에 자기 행이 있다.
    /// 기본은 지킴이보다 먼저 생긴 부모다(unique id < 지킴이, 지킴이 1초 전 시작: 셸 · 편집기 · 상주 빌드 서비스) — 20장에서 세대를 못 읽은 자식(`.gone`)을 무해로 가를 수 있는 유일한 부모.
    /// `young`이면 지킴이 뒤에 생긴 부모(unique id = 지킴이 + pid, 지킴이와 같은 때 시작: 세션 중에 시작한 빌드) — 그 뒤 매긴 자식보다는 id가 작다
    @discardableResult
    /// - `own`: unique id (위 기본을 덮는다)
    static func parent(
        _ world: World, startSeconds: UInt64? = nil, responsible: ProcessLookup<UInt64> = .present(12345), zombie: Bool = false, own: UInt64? = nil, young: Bool = false
    ) -> ProcessGeneration {
        let pid = world.next
        world.next += 1
        let seconds = startSeconds ?? (young ? world.own.startSeconds : world.own.startSeconds - 1)
        world.entries.append(ListedProcess(pid: pid, parentPID: 1, uid: world.uid, ruid: world.uid, startSeconds: seconds, startMicros: world.own.startMicros))
        let generation = ProcessGeneration(
            pid: pid, startSeconds: seconds, startMicros: world.own.startMicros, parentPID: 1, group: pid, uid: world.uid, zombie: zombie,
            own: own ?? (young ? world.own.own + UInt64(pid) : world.own.own - UInt64(pid - 900_000)), parent: 1
        )
        world.generations[pid] = .present(generation)
        world.responsible[pid] = responsible
        return generation
    }

    /// (a) 세대 조회에서 사라진 자식: 목록에만 있다 (지킴이 + 1초에 시작)
    static func vanishedAtGeneration(_ world: World, parentPID: pid_t) {
        world.listed(parentPID: parentPID)
    }

    /// (b) 세대는 읽었는데 책임 조회에서 사라진 자식
    static func vanishedAtResponsibility(_ world: World, parent: ProcessGeneration) {
        let child = world.process(parentPID: parent.pid, parentID: parent.own)
        world.responsible[child.pid] = .gone
    }

    func scan(_ world: World, seen: Set<UInt64> = []) -> KeeperMembers.Scan? {
        KeeperMembers.scan(keeperPID: world.me, keeperID: world.own.own, seen: seen, lookups: world.lookups)
    }

    // MARK: 완전 — 무관한 부모

    @Test func aChildThatVanishedUnderALiveUnrelatedParentLeavesTheScanComplete() throws {
        let world = try World()
        let parent = Self.parent(world)
        Self.vanishedAtGeneration(world, parentPID: parent.pid)
        #expect(scan(world) == KeeperMembers.Scan(members: [], complete: true), "지킴이 앞에 생긴 부모")
        Self.vanishedAtResponsibility(world, parent: parent)
        #expect(scan(world) == KeeperMembers.Scan(members: [], complete: true), "책임 조회에서 사라짐")
        // 지킴이 뒤에 생긴 부모(세션 중에 시작한 빌드): 책임 조회에서 사라진 자식은 부모 id < 자식 id로 무해하다.
        // 세대를 못 읽은 자식은 20장부터 불완전이다 (`KeeperScanRule20Tests`)
        let young = try World()
        let build = Self.parent(young, young: true)
        Self.vanishedAtResponsibility(young, parent: build)
        #expect(scan(young) == KeeperMembers.Scan(members: [], complete: true), "지킴이 뒤에 생긴 부모 · 책임 조회에서 사라짐")
    }

    @Test func withoutTheUniqueIDVariantTheParentIsCheckedByPID() throws {
        let world = try World()
        let parent = Self.parent(world)
        Self.vanishedAtGeneration(world, parentPID: parent.pid)
        var lookups = world.lookups
        lookups.responsibleUniqueID = nil
        world.responsiblePIDs[parent.pid] = .present(4242)
        #expect(KeeperMembers.scan(keeperPID: world.me, keeperID: world.own.own, lookups: lookups)?.complete == true)
        world.responsiblePIDs[parent.pid] = .present(world.me)
        #expect(KeeperMembers.scan(keeperPID: world.me, keeperID: world.own.own, lookups: lookups)?.complete == false, "부모 책임 = 지킴이 (pid)")
        // (b) 책임 조회(pid)에서 사라진 자식: 부모로 증명할 때만 완전, 조회 실패는 그대로 불완전
        let other = try World()
        var byPID = other.lookups
        byPID.responsibleUniqueID = nil
        let otherParent = Self.parent(other)
        let child = other.process(parentPID: otherParent.pid, parentID: otherParent.own)
        other.responsiblePIDs[child.pid] = .gone
        other.responsiblePIDs[otherParent.pid] = .present(4242)
        #expect(KeeperMembers.scan(keeperPID: other.me, keeperID: other.own.own, lookups: byPID)?.complete == true, "책임 조회(pid)에서 사라짐 · 무관한 부모")
        other.responsiblePIDs[otherParent.pid] = .present(other.me)
        #expect(KeeperMembers.scan(keeperPID: other.me, keeperID: other.own.own, lookups: byPID)?.complete == false, "책임 조회(pid)에서 사라짐 · 부모 책임 = 지킴이")
        other.responsiblePIDs[otherParent.pid] = .present(4242)
        other.responsiblePIDs[child.pid] = .failed
        #expect(KeeperMembers.scan(keeperPID: other.me, keeperID: other.own.own, lookups: byPID)?.complete == false, "책임 조회(pid) 실패는 사라짐이 아니다")
    }

    // MARK: 불완전 — 증명하지 못함

    @Test func aChildWhoseParentIsLaunchdOrTheKeeperMakesTheScanIncomplete() throws {
        for parentPID in [1, getpid()] {
            // launchd는 살아 있고 오래됐으며 책임 프로세스가 지킴이가 아니다 (다른 조건으로는 거르지 못한다): 부모가 pid 1이라는 것만으로 불완전이다 — 고아는 어디서 왔는지 모른다
            let launchd = ProcessGeneration(pid: 1, startSeconds: 1, startMicros: 0, parentPID: 0, group: 1, uid: 0, zombie: false, own: 1, parent: 0)
            let world = try World()
            world.generations[1] = .present(launchd)
            world.responsible[1] = .present(1)
            Self.vanishedAtGeneration(world, parentPID: parentPID)
            #expect(scan(world)?.complete == false, parentPID == 1 ? "부모 pid 1 (고아)" : "부모 = 지킴이")
            let atResponsibility = try World()
            atResponsibility.generations[1] = .present(launchd)
            atResponsibility.responsible[1] = .present(1)
            let child = atResponsibility.process(parentPID: parentPID, parentID: parentPID == 1 ? 1 : atResponsibility.own.own)
            atResponsibility.responsible[child.pid] = .gone
            #expect(scan(atResponsibility)?.complete == false, parentPID == 1 ? "책임 조회에서 사라짐 · 부모 pid 1" : "책임 조회에서 사라짐 · 부모 = 지킴이")
        }
    }

    @Test func aChildWhoseParentVanishedOrIsAZombieMakesTheScanIncomplete() throws {
        let world = try World()
        world.listed(parentPID: 777_777)
        #expect(scan(world)?.complete == false, "부모도 사라짐")
        // 지킴이 앞에 생긴 좀비 부모 (19.1은 지킴이 뒤의 좀비 행만 사라짐으로 본다: 이 부모의 행은 건너뛰므로 자식의 부모 확인만이 가른다)
        let zombie = try World()
        let parent = Self.parent(zombie, startSeconds: zombie.own.startSeconds - 1, zombie: true, own: zombie.own.own - 1)
        Self.vanishedAtGeneration(zombie, parentPID: parent.pid)
        #expect(scan(zombie)?.complete == false, "부모가 좀비")
        // 지킴이 뒤에 생긴 좀비 부모: 그 행 자체가 사라짐(19.1)이라 어느 쪽으로도 불완전
        let late = try World()
        let lateParent = Self.parent(late, zombie: true, young: true)
        Self.vanishedAtGeneration(late, parentPID: lateParent.pid)
        #expect(scan(late)?.complete == false, "지킴이 뒤의 좀비 부모")
    }

    @Test func aParentPIDReusedAfterTheChildStartedMakesTheScanIncomplete() throws {
        let world = try World()
        // 그 pid의 지금 프로세스가 자식(지킴이 + 1초)보다 늦게 생겼다(시작 시각 · unique id 모두 자식 뒤): 자식의 부모가 아니다
        let parent = Self.parent(world, startSeconds: world.own.startSeconds + 2, own: world.own.own + 2_000_000)
        Self.vanishedAtGeneration(world, parentPID: parent.pid)
        #expect(scan(world)?.complete == false)
    }

    @Test func aParentWhoseIDDoesNotMatchTheChildsParentIDMakesTheScanIncomplete() throws {
        let world = try World()
        let parent = Self.parent(world)
        let child = world.process(parentPID: parent.pid, parentID: parent.own + 1)
        world.responsible[child.pid] = .gone
        #expect(scan(world)?.complete == false, "책임 조회에서 사라짐: 부모 unique id 불일치")
    }

    @Test func aParentThatIsAMemberMakesTheScanIncomplete() throws {
        let world = try World()
        let parent = Self.parent(world, responsible: .present(world.own.own), young: true)
        Self.vanishedAtGeneration(world, parentPID: parent.pid)
        let result = scan(world)
        #expect(result?.complete == false, "부모의 책임 프로세스 = 지킴이")
        #expect(result?.members == [parent])
        // 책임 조회에서 사라진 자식: 구성원 부모는 자식보다 먼저 생겼으니(20장 순서 조건을 통과한다) 책임 프로세스 = 지킴이만이 가른다
        let atResponsibility = try World()
        let member = Self.parent(atResponsibility, responsible: .present(atResponsibility.own.own), young: true)
        Self.vanishedAtResponsibility(atResponsibility, parent: member)
        #expect(scan(atResponsibility)?.complete == false, "책임 조회에서 사라짐 · 부모의 책임 프로세스 = 지킴이")
    }

    @Test func aParentTheKeeperHasSeenAsAMemberMakesTheScanIncomplete() throws {
        let world = try World()
        let parent = Self.parent(world)
        Self.vanishedAtGeneration(world, parentPID: parent.pid)
        #expect(scan(world, seen: [parent.own])?.complete == false)
        // 책임 조회에서 사라진 자식의 부모(지킴이 뒤에 생긴 부모, 구성원 id만 지킴이가 본다)
        let young = try World()
        let build = Self.parent(young, young: true)
        Self.vanishedAtResponsibility(young, parent: build)
        #expect(scan(young, seen: [build.own])?.complete == false, "책임 조회에서 사라짐")
    }

    @Test func aFailedParentLookupMakesTheScanIncomplete() throws {
        let world = try World()
        let parent = Self.parent(world)
        Self.vanishedAtGeneration(world, parentPID: parent.pid)
        world.responsible[parent.pid] = .failed
        #expect(scan(world)?.complete == false, "부모 책임 조회 실패")
        let generation = try World()
        let other = Self.parent(generation)
        Self.vanishedAtGeneration(generation, parentPID: other.pid)
        generation.generations[other.pid] = .failed
        #expect(scan(generation)?.complete == false, "부모 세대 조회 실패")
    }

    @Test func aFailedChildLookupStillMakesTheScanIncomplete() throws {
        let world = try World()
        let parent = Self.parent(world)
        let child = world.process(parentPID: parent.pid, parentID: parent.own)
        world.responsible[child.pid] = .failed
        #expect(scan(world)?.complete == false, "책임 조회 실패는 사라짐이 아니다")
        let generation = try World()
        let other = Self.parent(generation)
        let pid = generation.listed(parentPID: other.pid)
        generation.generations[pid] = .failed
        #expect(scan(generation)?.complete == false, "세대 조회 실패는 사라짐이 아니다")
    }
}
#endif
