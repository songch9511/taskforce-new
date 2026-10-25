#if os(macOS)
import Foundation

/// Persisted lifecycle events prove terminal states, not whether a process is still running.
/// Live running and input-waiting states must come from the owned runtime.
public enum CodexObservedStatus: Equatable, Sendable {
    case unknown, running, needsYou, done, idle, failed

    static func parse(_ data: Data, offset: Int64 = 0) -> Self {
        var lines = data.split(separator: 10, omittingEmptySubsequences: false)
        if offset > 0, !lines.isEmpty { lines.removeFirst() }
        if data.last != 10, !lines.isEmpty { lines.removeLast() }
        var latestTurn: String?
        var status: Self = .unknown
        for line in lines where !line.isEmpty {
            guard line.count <= 1 << 20,
                  let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else {
                status = .unknown
                latestTurn = nil
                continue
            }
            guard object["type"] as? String == "event_msg",
                  let payload = object["payload"] as? [String: Any],
                  let type = payload["type"] as? String,
                  ["task_started", "task_complete", "turn_aborted"].contains(type) else { continue }
            guard let turn = payload["turn_id"] as? String, !turn.isEmpty else {
                status = .unknown
                latestTurn = nil
                continue
            }
            if type == "task_started" {
                latestTurn = turn
                status = .unknown
            } else {
                // A late completion from a previous turn must not finish the newest turn.
                guard latestTurn == nil || latestTurn == turn else { continue }
                latestTurn = turn
                if type == "turn_aborted" {
                    status = .idle
                } else {
                    status = payload["error"].map { $0 is NSNull ? .done : .failed } ?? .done
                }
            }
        }
        return status
    }
}
#endif
