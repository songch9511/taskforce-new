#if os(macOS) && DEBUG
import Foundation
import Testing
@testable import TaskforceKit

/// 측정 장치 (OA D2b 계약 2.10 · 4.1 K13): ONE-TF-11의 bridge 쪽 시각 원천. 실제 수치는 실제 스택 확인에서만 통과로 적는다
struct BridgeLatencyTests {
    private let t0 = BridgeTest.t0

    private func sample(_ source: String, created: Double, spawn: Double?, input: Double? = nil, kind: String = "message") -> BridgeCommandRecord {
        var record = BridgeTest.command(kind: kind, state: .settled)
        record.serverCreatedAt = t0.addingTimeInterval(created)
        record.spawnAt = spawn.map { t0.addingTimeInterval($0) }
        record.inputAt = input.map { t0.addingTimeInterval($0) }
        record.wakeSource = source
        return record
    }

    @Test func thereportGroupsBySourceAndUsesNearestRankPercentiles() {
        let samples = (1...20).map { sample("realtime", created: 0, spawn: Double($0) / 10) } + [sample("long_poll", created: 0, spawn: 6)]
        let rows = BridgeLatencyReport.build(from: samples, clockOffsetMS: 0)
        #expect(rows.map(\.source) == ["long_poll", "realtime"])
        let realtime = rows[1]
        #expect(realtime.count == 20)
        #expect(abs(realtime.p50 - 1.0) < 1e-4 && abs(realtime.p95 - 1.9) < 1e-4 && abs(realtime.max - 2.0) < 1e-4)
        #expect(rows[0].count == 1 && abs(rows[0].p50 - 6) < 1e-4 && abs(rows[0].max - 6) < 1e-4)
    }

    @Test func theLocalStopPointIsConvertedToTheServerClockWithTheMeasuredOffset() {
        // 서버 시계가 로컬보다 3초 앞선다: 로컬 spawn 1.0 = 서버 시각 4.0
        let rows = BridgeLatencyReport.build(from: [sample("realtime", created: 2, spawn: 1)], clockOffsetMS: 3000)
        #expect(abs((rows.first?.max ?? 0) - 2.0) < 1e-4)
    }

    @Test func codexUsesTheInputSendPointAndCommandsWithoutAStopPointAreLeftOut() {
        let rows = BridgeLatencyReport.build(
            from: [sample("realtime", created: 0, spawn: nil, input: 0.5), sample("realtime", created: 0, spawn: nil), sample("realtime", created: 0, spawn: 1, kind: "cancel")],
            clockOffsetMS: 0
        )
        #expect(rows.count == 1 && rows[0].count == 1 && abs(rows[0].max - 0.5) < 1e-4)
    }

    @Test func aRunFillsEveryMeasurementTimestampAndTheClockOffset() async throws {
        let h = try BridgeHarness()
        h.agent.setScript(.normal())
        await h.registerFirst()
        h.clock.jump(by: 6)
        let created = h.message()
        h.clock.jump(by: 0.5)
        _ = await h.runtime.poll(wait: 0, reason: .realtime)
        #expect(await h.eventually { h.agent.startedTurns.count == 1 })
        let command = try #require(await h.command(created.commandID))
        let created0 = try #require(command.serverCreatedAt)
        #expect(command.wakeSource == "realtime" && command.wakeAt != nil && command.listedAt != nil)
        #expect(command.leaseRequestedAt != nil && command.leasedAt != nil && command.serverLeasedAt != nil && command.spawnAt != nil)
        #expect(command.leasedAt! >= created0 && command.spawnAt! >= command.leasedAt!)
        #expect(command.serverLeasedAt == command.leasedAt, "서버가 lease한 시각 = 응답의 lease_expires_at − 330초")
        #expect(try await h.ledger.meta().clockOffsetMS == 0, "같은 시계면 어긋남 0")
    }

    @Test func aServerClockAheadOfTheMacIsMeasuredFromTheHeartbeatRoundTrip() async throws {
        let h = try BridgeHarness(serverClockOffset: 3)
        await h.registerFirst()
        let offset = try #require(try await h.ledger.meta().clockOffsetMS)
        #expect(abs(offset - 3000) <= 5)
    }

    @Test func theThreePathsEachProduceTwentyMeasuredSamplesAndAReport() async throws {
        // 가짜 서버가 실제 지연 없이 답하므로 이것은 기제 확인이다: 시각 원천이 채워지고 p95가 나온다
        for (path, source, openWork) in [("Realtime connected", BridgeWakeReason.realtime, false), ("Realtime lost, open work", .longPoll, true), ("Realtime lost, idle", .longPoll, false)] {
            let h = try BridgeHarness()
            h.agent.setScript { turn in turn.text == "keeper" ? .staysRunning() : .normal() }
            await h.registerFirst()
            var expectedStarts = 0
            if openWork {
                h.message("keeper", session: "5e551011-0000-4000-8000-0000000000ff", task: "7a5c0001-0000-4000-8000-0000000000ff")
                await h.runtime.tick()
                expectedStarts = 1
                #expect(await h.eventually { h.agent.startedTurns.count == expectedStarts })
            }
            for index in 0..<20 {
                h.clock.jump(by: 1)
                h.message("m\(index)", session: String(format: "5e551011-0000-4000-8000-%012d", index + 1), task: String(format: "7a5c0001-0000-4000-8000-%012d", index + 1))
                h.clock.jump(by: 0.4)
                _ = await h.runtime.poll(wait: 0, reason: source)
                expectedStarts += 1
                #expect(await h.eventually { h.agent.startedTurns.count == expectedStarts }, "\(path) \(index)")
            }
            let commands = try await h.ledger.allCommands().filter { $0.wakeSource == source.rawValue && $0.spawnAt != nil && $0.agentSessionID != "5e551011-0000-4000-8000-0000000000ff" }
            let offset = try await h.ledger.meta().clockOffsetMS ?? 0
            let rows = BridgeLatencyReport.build(from: commands, clockOffsetMS: offset)
            #expect(rows.count == 1 && rows[0].count == 20 && rows[0].source == source.rawValue, "\(path)")
            #expect(rows[0].p95 >= 0.4 && rows[0].p95 <= 0.5, "\(path): 가짜 서버는 지연 없이 답한다 (p95 \(rows[0].p95))")
        }
    }
}
#endif
