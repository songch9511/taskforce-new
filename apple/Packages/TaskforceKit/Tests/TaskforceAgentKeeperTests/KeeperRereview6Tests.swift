#if os(macOS)
import Darwin
import Foundation
import Testing
@testable import TaskforceAgentWire

/// 재검토 6 지킴이 쪽 (OA D3a 15장 3 · 4 · 6): 다시 disclaim한 프로세스는 부모로 가른다(무관한 앱의 disclaim은 끝을 막지 않는다), 정상 끝은 보고 `ended` 줄,
/// 부른 쪽 확인 뒤 idversion. 훑기 규칙은 시험 프로세스를 지킴이로 치고 목록 · 조회를 끼워 넣어 결정적으로 본다. 실제 `claude` 실행 0
struct KeeperRereview6Tests {
    typealias World = KeeperScanRulesTests.World

    /// 지킴이 뒤에 생긴, 스스로 책임 프로세스인 자식 하나 (부모 pid · id를 정한다)
    @discardableResult
    static func redisclaimed(_ world: World, parentPID: pid_t, parentID: UInt64) -> ProcessGeneration {
        let pid = world.next
        return world.process(parentPID: parentPID, parentID: parentID, responsibleID: world.own.own + UInt64(pid))
    }

    // MARK: 15장 3 무관한 프로세스

    /// Claude 데스크톱 · Chrome native host 모양: 지킴이 뒤에 뜬 다른 앱(책임 프로세스 ≠ 지킴이)이 disclaim으로 띄운 자식. 부모가 살아 있으면 끝을 막지 않는다
    @Test func aRedisclaimedChildOfALiveUnrelatedParentLeavesTheScanComplete() throws {
        let world = try World()
        let app = world.process(responsibleID: 12_345)
        Self.redisclaimed(world, parentPID: app.pid, parentID: app.own)
        #expect(world.scan() == KeeperMembers.Scan(members: [], complete: true))
        // unique id 변형이 없을 때도 (책임 pid로)
        let byPID = try World()
        let other = byPID.process()
        let child = Self.redisclaimed(byPID, parentPID: other.pid, parentID: other.own)
        byPID.responsiblePIDs = [other.pid: .present(4242), child.pid: .present(child.pid)]
        var lookups = byPID.lookups
        lookups.responsibleUniqueID = nil
        #expect(KeeperMembers.scan(keeperPID: byPID.me, keeperID: byPID.own.own, lookups: lookups) == KeeperMembers.Scan(members: [], complete: true))
    }

    /// 부모가 구성원 · 사라짐 · 좀비 · 다른 프로세스(pid 재사용) · 책임 조회 실패면 구성원이 다시 disclaim해 띄웠을 수 있다: 불완전
    @Test func aRedisclaimedChildWhoseParentIsNotProvablyUnrelatedMakesTheScanIncomplete() throws {
        for parent in ["member", "gone", "zombie", "reused", "lookup-failed", "responsible-is-keeper"] {
            let world = try World()
            let app = world.process(responsibleID: parent == "member" ? nil : 12_345)
            var parentPID = app.pid
            switch parent {
            case "gone":
                // 목록을 읽은 뒤 끝났다 (목록에는 없다: 부모 조회만이 가른다)
                world.entries.removeAll { $0.pid == app.pid }
                world.generations[app.pid] = .gone
            case "zombie":
                world.generations[app.pid] = .present(ProcessGeneration(
                    pid: app.pid, startSeconds: app.startSeconds, startMicros: app.startMicros, parentPID: app.parentPID, group: app.group, uid: app.uid,
                    zombie: true, own: app.own, parent: app.parent
                ))
            case "reused": parentPID = world.process(responsibleID: 12_345).pid
            case "lookup-failed":
                world.entries.removeAll { $0.pid == app.pid }
                world.responsible[app.pid] = .failed
            case "responsible-is-keeper": world.responsible[app.pid] = .present(world.own.own)
            default: break
            }
            Self.redisclaimed(world, parentPID: parentPID, parentID: app.own)
            #expect(world.scan()?.complete == false, "\(parent)")
        }
    }

    /// 지킴이가 앞선 훑기에서 구성원으로 본 id가 부모면 (그 뒤 스스로 책임 프로세스가 됐어도) 불완전
    @Test func aRedisclaimedChildOfAParentTheKeeperSawAsAMemberMakesTheScanIncomplete() throws {
        let world = try World()
        let parent = world.process(responsibleID: 12_345)
        Self.redisclaimed(world, parentPID: parent.pid, parentID: parent.own)
        #expect(world.scan()?.complete == true)
        #expect(KeeperMembers.scan(keeperPID: world.me, keeperID: world.own.own, seen: [parent.own], lookups: world.lookups)?.complete == false)
    }

    // MARK: 15장 4 정상 끝 = 보고 `ended` 줄 + 0 종료

    @Test func theEndedReportLineHasOneShape() {
        #expect(KeeperReport.ended.line == "ended")
        #expect(KeeperReport(line: "ended") == .ended)
        for line in ["ended 0", "ended ", "Ended"] { #expect(KeeperReport(line: line) == nil, "\(line)") }
    }

    /// 지킴이는 구성원 0을 증명하고 끝 기록을 쓴 뒤 `ended`를 보고하고 0으로 끝난다 (그 뒤 보고 pipe는 닫힌다)
    @Test func theKeeperReportsEndedAfterItsRecordAndThenExitsZero() throws {
        let keeper = try KeeperTests()
        let kept = try keeper.launch(["/usr/bin/true", "true"])
        close(kept.stdinWrite)
        var lines: [KeeperReport] = []
        while let line = kept.nextReport(timeout: 10) {
            if line == .ended { #expect(KeeperRecord.read(kept.ended) != nil, "기록 뒤에 보고한다") }
            lines.append(line)
        }
        #expect(lines.count == 3)
        #expect(lines.dropFirst() == [.exited(code: 0, signal: nil), .ended])
        #expect(kept.exitCode(timeout: 5) == 0)
        close(kept.stdoutRead)
        close(kept.reportRead)
    }

    // MARK: 15장 6 부른 쪽이 지킴이를 띄운 뒤 exec

    /// 정책을 만족해도 부모의 idversion이 지킴이 것보다 작아야 한다: 같거나 크면(띄운 뒤 exec) · 읽지 못하면 거절
    @Test func aParentThatExecedAfterSpawningTheKeeperIsRefused() {
        let parent: pid_t = 4242
        func allows(_ parentVersion: UInt32?, _ ownVersion: UInt32?) -> Bool {
            KeeperCaller.allows(.liveParent, parent: parent, parentNow: { parent }, version: { $0 == parent ? parentVersion : ownVersion }, me: 0)
        }
        #expect(allows(7, 8))
        #expect(!allows(8, 8))
        #expect(!allows(9, 8), "띄운 뒤 exec")
        #expect(!allows(nil, 8))
        #expect(!allows(7, nil))
        // 실제 값: 이 시험 프로세스(부모 자리)는 자기가 띄운 자식보다 먼저 매겨졌다
        #expect(KeeperCaller.idVersion(getpid()) != nil)
    }
}
#endif
