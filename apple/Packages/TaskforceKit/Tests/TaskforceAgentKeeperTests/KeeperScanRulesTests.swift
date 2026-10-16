#if os(macOS)
import Darwin
import Foundation
import Testing
@testable import TaskforceAgentWire

/// 재검토 5 훑기 규칙 (OA D3a 14장 4–6)과 부른 쪽 확인 (14장 12): 시험 프로세스를 지킴이로 치고 목록 · 조회를 끼워 넣어 결정적으로 본다
struct KeeperScanRulesTests {
    /// 시험 프로세스 = 지킴이. 그 밖의 pid는 끼워 넣은 값만 있다
    final class World: @unchecked Sendable {
        let me = getpid()
        let uid = getuid()
        let own: ProcessGeneration
        var entries: [ListedProcess] = []
        var generations: [pid_t: ProcessLookup<ProcessGeneration>] = [:]
        var responsible: [pid_t: ProcessLookup<UInt64>] = [:]
        var responsiblePIDs: [pid_t: ProcessLookup<pid_t>] = [:]
        var next: pid_t = 900_001

        init() throws {
            guard case .present(let own) = AgentProcesses.generation(pid: getpid()) else { throw CancellationError() }
            self.own = own
        }

        /// 지킴이 뒤(`after`)나 앞에 시작한 프로세스 하나를 목록에 넣는다
        @discardableResult
        func listed(after: Bool = true, parentPID: pid_t = 1, uid: uid_t? = nil, ruid: uid_t? = nil) -> pid_t {
            let pid = next
            next += 1
            let seconds = after ? own.startSeconds + 1 : own.startSeconds - 1
            entries.append(ListedProcess(pid: pid, parentPID: parentPID, uid: uid ?? self.uid, ruid: ruid ?? self.uid, startSeconds: seconds, startMicros: own.startMicros))
            return pid
        }

        /// 지킴이 뒤에 생긴 같은 사용자 프로세스 하나 (세대 · 책임 조회 포함)
        @discardableResult
        func process(parentPID: pid_t = 1, parentID: UInt64 = 1, responsibleID: UInt64? = nil) -> ProcessGeneration {
            let pid = listed(parentPID: parentPID)
            let id = own.own + UInt64(pid)
            let generation = ProcessGeneration(
                pid: pid, startSeconds: own.startSeconds + 1, startMicros: own.startMicros, parentPID: parentPID, group: pid, uid: uid, zombie: false, own: id, parent: parentID
            )
            generations[pid] = .present(generation)
            responsible[pid] = .present(responsibleID ?? own.own)
            return generation
        }

        var lookups: KeeperMembers.Lookups {
            KeeperMembers.Lookups(
                listing: { self.entries },
                generation: { pid in pid == self.me ? .present(self.own) : (self.generations[pid] ?? .gone) },
                responsiblePID: { self.responsiblePIDs[$0] ?? .failed },
                responsibleUniqueID: { self.responsible[$0] ?? .gone }
            )
        }

        func scan() -> KeeperMembers.Scan? {
            KeeperMembers.scan(keeperPID: me, keeperID: own.own, lookups: lookups)
        }
    }

    @Test func aMemberIsFoundAndAQuietWorldIsComplete() throws {
        let world = try World()
        let member = world.process()
        #expect(world.scan() == KeeperMembers.Scan(members: [member], complete: true))
    }

    // MARK: 14장 4 실효 사용자가 바뀐 자손

    @Test func aSetuidChildOfAMemberTheKeeperOrLaunchdMakesTheScanIncomplete() throws {
        for parent in ["member", "keeper", "launchd"] {
            let world = try World()
            let member = world.process()
            let parentPID: pid_t = parent == "member" ? member.pid : parent == "keeper" ? world.me : 1
            world.listed(parentPID: parentPID, uid: 0)
            #expect(world.scan()?.complete == false, "\(parent)")
            #expect(world.scan()?.members == [member], "구성원은 그대로 찾는다")
        }
    }

    @Test func aSetuidProcessThatIsNotOursLeavesTheScanComplete() throws {
        let world = try World()
        world.listed(parentPID: 4242, uid: 0)
        world.listed(after: false, parentPID: 1, uid: 0)
        #expect(world.scan()?.complete == true, "부모가 우리 쪽이 아니거나 지킴이 앞에 시작했다")
    }

    // MARK: 14장 5 다시 disclaim한 자손

    @Test func aSelfResponsibleProcessWhoseParentStartedAfterTheKeeperMakesTheScanIncomplete() throws {
        let world = try World()
        let member = world.process()
        let pid = world.next
        world.process(parentPID: member.pid, parentID: member.own, responsibleID: world.own.own + UInt64(pid))
        #expect(world.scan()?.complete == false)
        #expect(world.scan()?.members == [member])
    }

    @Test func aSelfResponsibleProcessOfAnOlderParentOrAnotherResponsibleLeavesTheScanComplete() throws {
        let world = try World()
        let pid = world.next
        world.process(parentPID: 77, parentID: world.own.own - 1, responsibleID: world.own.own + UInt64(pid))
        world.process(parentPID: 78, parentID: world.own.own + 999_999, responsibleID: 12345)
        #expect(world.scan() == KeeperMembers.Scan(members: [], complete: true))
    }

    @Test func withoutTheUniqueIDVariantASelfResponsiblePIDIsCheckedToo() throws {
        let world = try World()
        let member = world.process()
        let child = world.process(parentPID: member.pid, parentID: member.own)
        world.responsiblePIDs = [member.pid: .present(world.me), child.pid: .present(child.pid)]
        var lookups = world.lookups
        lookups.responsibleUniqueID = nil
        let scan = KeeperMembers.scan(keeperPID: world.me, keeperID: world.own.own, lookups: lookups)
        #expect(scan?.complete == false)
        #expect(scan?.members == [member])
    }

    // MARK: 14장 6 목록과 조회 사이에 사라짐

    @Test func aProcessListedAfterTheKeeperThatIsGoneAtLookupMakesTheScanIncomplete() throws {
        let world = try World()
        world.listed()
        #expect(world.scan()?.complete == false, "세대 조회에서 사라짐")
        let other = try World()
        let gone = other.process()
        other.responsible[gone.pid] = .gone
        #expect(other.scan()?.complete == false, "책임 조회에서 사라짐")
    }

    @Test func aProcessListedBeforeTheKeeperThatIsGoneLeavesTheScanComplete() throws {
        let world = try World()
        world.listed(after: false)
        #expect(world.scan()?.complete == true)
    }

    // MARK: 14장 12 부른 쪽 확인

    @Test func theAppIdentifierComesFromTheKeeperBundleID() {
        #expect(KeeperCaller.appIdentifier(fromKeeper: "dev.taskforcelabs.taskforce.agent") == "dev.taskforcelabs.taskforce")
        #expect(KeeperCaller.appIdentifier(fromKeeper: "dev.taskforcelabs.unittest.taskforce.agent") == "dev.taskforcelabs.unittest.taskforce")
        for bad in [nil, "dev.taskforcelabs.taskforce", "dev.taskforcelabs.taskforce.agent-hook", ".agent", "dev.x\".agent", "dev x.agent"] {
            #expect(KeeperCaller.appIdentifier(fromKeeper: bad) == nil, "\(bad ?? "nil")")
        }
    }

    @Test func theReleaseRequirementPinsTheTeamAndTheIdentifier() {
        #expect(KeeperCaller.signedAppRequirement(keeperID: "dev.taskforcelabs.taskforce.agent", team: "U9DWQKQFMW")
            == "anchor apple generic and identifier \"dev.taskforcelabs.taskforce\" and certificate leaf[subject.OU] = \"U9DWQKQFMW\"")
        #expect(KeeperCaller.signedAppRequirement(keeperID: "dev.taskforcelabs.taskforce.agent", team: nil) == nil, "팀이 없으면(서명 안 됨) 진행하지 않는다")
        #expect(KeeperCaller.signedAppRequirement(keeperID: "dev.taskforcelabs.taskforce.agent", team: "U9\" or true") == nil)
        #expect(KeeperCaller.signedAppRequirement(keeperID: nil, team: "U9DWQKQFMW") == nil)
    }

    @Test func aRequirementIsCheckedAgainstTheLiveParentAndTheParentMustStayTheSame() throws {
        let identifier = try #require(KeeperRereview5Tests.ownIdentifier())
        let me = getpid()
        #expect(KeeperCaller.satisfies(pid: me, requirement: "identifier \"\(identifier)\""))
        #expect(!KeeperCaller.satisfies(pid: me, requirement: "identifier \"dev.taskforcelabs.not-this-host\""))
        #expect(!KeeperCaller.satisfies(pid: me, requirement: "this is not a requirement ((("))
        // 시험 프로세스가 부모 자리: 지킴이(`me: 0`)는 그 뒤에 생겼다 (idversion 부모 < 지킴이, 15장 6)
        let versions: (pid_t) -> UInt32? = { $0 == me ? 1 : 2 }
        #expect(KeeperCaller.allows(.requirement("identifier \"\(identifier)\""), parent: me, parentNow: { me }, version: versions, me: 0))
        #expect(!KeeperCaller.allows(.requirement("identifier \"\(identifier)\""), parent: me, parentNow: { 1 }, version: versions, me: 0), "확인하는 동안 부모가 끝났다")
        #expect(!KeeperCaller.allows(.liveParent, parent: 1, parentNow: { 1 }), "ppid 1")
    }

    @Test func theDebugHostCheckMatchesTheBundleIDAndTheHelperLocation() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "tf-caller-\(UUID().uuidString.prefix(8))", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appending(path: "Taskforce.app/Contents", directoryHint: .isDirectory)
        let keeper = app.appending(path: "Helpers/Taskforce Agent.app", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: app.appending(path: "MacOS"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: keeper, withIntermediateDirectories: true)
        let plist = try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "dev.taskforcelabs.unittest.taskforce"], format: .xml, options: 0)
        try plist.write(to: app.appending(path: "Info.plist"))
        try Data().write(to: app.appending(path: "MacOS/Taskforce"))
        let executable = app.appending(path: "MacOS/Taskforce").path
        #expect(KeeperCaller.debugAppMatches(parentExecutable: executable, keeperBundle: keeper, keeperID: "dev.taskforcelabs.unittest.taskforce.agent"))
        #expect(!KeeperCaller.debugAppMatches(parentExecutable: executable, keeperBundle: keeper, keeperID: "dev.taskforcelabs.taskforce.agent"), "다른 빌드의 앱")
        #expect(!KeeperCaller.debugAppMatches(parentExecutable: executable, keeperBundle: root.appending(path: "Taskforce Agent.app"), keeperID: "dev.taskforcelabs.unittest.taskforce.agent"),
                "지킴이가 그 앱의 Helpers 밖")
        #expect(!KeeperCaller.debugAppMatches(parentExecutable: "/bin/sh", keeperBundle: keeper, keeperID: "dev.taskforcelabs.unittest.taskforce.agent"), "앱이 아닌 부모")
    }
}
#endif
