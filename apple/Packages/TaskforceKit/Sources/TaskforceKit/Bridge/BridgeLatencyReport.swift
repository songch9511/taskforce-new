#if os(macOS) && DEBUG
import Foundation

/// ONE-TF-11 지연 측정 장치 (Debug 전용, 계약 2.10): 원장에 남긴 시각만으로 경로별 개수 · p50 · p95 · 최대를 뽑는다. 글 0.
/// 지연 = 멈춤 지점(Claude Code는 프로세스 시작 `spawn_at`, Codex는 `turn/start` 전송 `input_at`)을 서버 시계로 환산한 값 − 서버가 명령을 만든 시각(`server_created_at`).
/// 서버 시계 환산은 `meta.clock_offset_ms`(왕복 중간점 추정)로 한다. 실제 수치는 실제 스택 확인(코디네이터 MS-1)에서만 ONE-TF-11 통과로 적는다 — 가짜 서버는 기제만 확인한다.
public enum BridgeLatencyReport {
    public struct Row: Equatable, Sendable {
        /// `realtime` · `long_poll` · `heartbeat` · `startup`
        public let source: String
        public let count: Int
        public let p50: TimeInterval
        public let p95: TimeInterval
        public let max: TimeInterval
    }

    public static func build(from commands: [BridgeCommandRecord], clockOffsetMS: Int) -> [Row] {
        let offset = TimeInterval(clockOffsetMS) / 1000
        var groups: [String: [TimeInterval]] = [:]
        for command in commands {
            guard command.kind == "message", let created = command.serverCreatedAt, let stop = command.spawnAt ?? command.inputAt else { continue }
            let latency = stop.addingTimeInterval(offset).timeIntervalSince(created)
            groups[command.wakeSource ?? "unknown", default: []].append(latency)
        }
        return groups.keys.sorted().map { source in
            let sorted = groups[source]!.sorted()
            return Row(source: source, count: sorted.count, p50: percentile(sorted, 0.50), p95: percentile(sorted, 0.95), max: sorted.last ?? 0)
        }
    }

    /// 가까운 순위(nearest-rank): 정렬된 표본에서 ceil(p × n)번째
    static func percentile(_ sorted: [TimeInterval], _ p: Double) -> TimeInterval {
        guard !sorted.isEmpty else { return 0 }
        let rank = Int((p * Double(sorted.count)).rounded(.up))
        return sorted[min(max(rank, 1), sorted.count) - 1]
    }
}
#endif
