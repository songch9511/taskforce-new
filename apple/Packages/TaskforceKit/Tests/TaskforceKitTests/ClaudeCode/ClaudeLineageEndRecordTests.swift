#if os(macOS) && DEBUG
import Darwin
import Foundation
import Synchronization
import Testing
import TaskforceAgentWire
@testable import TaskforceKit

/// 19.2: 파일에서 읽은 혈통(다시 뜬 앱 · 감독 밖 끝내기)은 지킴이가 사라진 뒤 지킴이 기록이 없어도 이 spawn · 이번 부팅 · 형식이 맞는 끝 기록(`<spawn>.ended`)이면 끝이다.
/// 끝 기록은 끝을 증명한 뒤에만 쓰이고(앱의 `forget` · 다른 부팅의 `purge`), 쓰는 쪽은 끝 기록을 먼저 쓰고 지킴이 기록을 지운다 — 읽는 쪽은 지킴이 기록을 먼저 보고
/// 없으면 끝 기록을 본다 (거꾸로 보면 그 사이에 끝을 확정한 다른 adapter 때문에 둘 다 놓쳤다: e14)
@Suite(.serialized)
struct ClaudeLineageEndRecordTests {
    let box = ClaudeSandbox()
    static let keeper = ClaudeLineage.Keeper(pid: 70, uniqueID: 7_000)

    /// 이번 부팅의 정체(지킴이 · 뿌리)가 적힌 혈통 파일 하나와 그것을 디스크에서 읽은 혈통
    func recorded(_ name: String = UUID().uuidString) throws -> (file: URL, lineage: ClaudeLineage) {
        let file = box.root.appending(path: "lineage/\(name).lineage")
        let writer = ClaudeLineage(file: file, fresh: true)
        writer.adopt(ClaudeLineage.Record(keeper: Self.keeper, root: 8_000, rootPID: 80, attributable: true))
        #expect(writer.save(), "혈통 파일 (시험 전제)")
        let lineage = ClaudeLineage(file: file)
        #expect(lineage.keeper == Self.keeper && !lineage.provenEnded, "디스크에서 읽은 이번 부팅 혈통 (시험 전제)")
        return (file, lineage)
    }

    static func boot() throws -> String { try #require(AgentProcesses.bootSessionID()) }

    static func writeEnded(_ file: URL, boot: String, text: String? = nil) throws {
        try Data((text ?? "taskforce-lineage 4\nboot \(boot)\nended\n").utf8).write(to: ClaudeLineage.endedFile(file))
    }

    @Test func aThisBootEndRecordProvesTheEndAfterTheKeeperRecordIsGone() throws {
        let (file, lineage) = try recorded()
        try Self.writeEnded(file, boot: Self.boot())
        #expect(lineage.endAfterKeeperGone() == .ended(AgentExit(code: nil)))
    }

    @Test func anEndRecordOfAnotherBootSpawnOrAMalformedOneProvesNothing() throws {
        let (other, otherBoot) = try recorded()
        try Self.writeEnded(other, boot: UUID().uuidString)
        #expect(otherBoot.endAfterKeeperGone() == .unknown, "다른 부팅의 끝 기록")
        let (_, otherSpawn) = try recorded()
        try Self.writeEnded(box.root.appending(path: "lineage/\(UUID().uuidString).lineage"), boot: Self.boot())
        #expect(otherSpawn.endAfterKeeperGone() == .unknown, "다른 spawn의 끝 기록")
        let (cut, truncated) = try recorded()
        try Self.writeEnded(cut, boot: Self.boot(), text: "taskforce-lineage 4\nboot \(try Self.boot())\nend")
        #expect(truncated.endAfterKeeperGone() == .unknown, "잘린 끝 기록")
        let (bad, malformed) = try recorded()
        try Self.writeEnded(bad, boot: Self.boot(), text: "taskforce-lineage 4\nboot \(try Self.boot())\nended\nmore\n")
        #expect(malformed.endAfterKeeperGone() == .unknown, "형식이 다른 끝 기록")
        let (_, neither) = try recorded()
        #expect(neither.endAfterKeeperGone() == .unknown, "지킴이 기록도 끝 기록도 없음")
    }

    /// 다른 adapter가 끝을 확정하는 그 순간(끝 기록을 쓰고 지킴이 기록을 지움)에도, 끝이 증명된 spawn을 읽는 쪽은 언제나 끝을 본다
    @Test func aReaderNeverMissesTheEndWhileAnotherAdapterConfirmsIt() throws {
        let boot = try Self.boot()
        var misses = 0
        var reads = 0
        for _ in 0..<300 {
            let (file, reader) = try recorded()
            #expect(KeeperRecord.write(ClaudeLineage.keeperFile(file), keeperID: Self.keeper.uniqueID, boot: boot), "지킴이 끝 기록 (시험 전제)")
            let other = ClaudeLineage(file: file)
            let done = Atomic<Bool>(false)
            let thread = Thread {
                usleep(UInt32.random(in: 0...300))
                other.forget()
                done.store(true, ordering: .sequentiallyConsistent)
            }
            thread.start()
            repeat {
                reads += 1
                if !reader.keeperRecorded() { misses += 1 }
            } while !done.load(ordering: .sequentiallyConsistent)
            reads += 1
            if !reader.keeperRecorded() { misses += 1 }
        }
        #expect(misses == 0, "끝을 증명한 spawn인데 끝을 놓쳤다: \(misses) / \(reads)")
    }
}
#endif
