#if os(macOS) && DEBUG
import AppKit
import TaskforceKit

/// 복귀 요약(C3) 상태 PNG: `-TF_EDGE_SHELL YES -TF_C3 YES -TFSampleData -TFEdgeSnapshot <폴더> -TFEdgeSnapshotSummary` (+ `-TF_S4 YES`로 Review 연결, `-TFSnapshotDark`, `-TFReduceMotion YES`).
/// 견본 가짜 서버(`SampleReturnSummaryGateway`)를 시나리오대로 바꿔 가며 같은 패널(All work)에서 담는다: 변화 · 많은 줄 · 지운 원문 토큰 · 잘림 · 일부 읽지 못함 · 읽기 실패 · 오래됨 · 빈 상태(아무것도 안 보임) ·
/// 기능 꺼짐(아무것도 안 보임) · 첫 Clear 전 · Clear 진행 중 · Clear 뒤 · 충돌(409) · 응답 유실 · 거절. 렌더된 fixture일 뿐이다: 실제 서버 · 계정 · AI 호출이 없다.
@MainActor
enum SummarySnapshot {
    static func capture(_ edge: EdgeShellController, file: (String) -> URL, settle: () async -> Void) async {
        guard let store = edge.shell.summary, let gateway = AppRuntime.sampleSummaryGateway else { return }
        let shell = edge.shell
        func shoot(_ name: String) { EdgeSnapshot.capture(edge, to: file("summary-\(name)")) }
        /// 패널 높이에 맞게 견본의 일을 몇 개로 줄인다 (카드가 주인공이고 목록이 그 아래에 이어진다)
        edge.workOverride = { work in
            var work = work
            work.review = Array(work.review.prefix(1))
            let keep = Set([10, 11, 12, 13].map(SampleData.id))
            work.open = work.open.filter { keep.contains($0.id) }
            work.doneToday = Array(work.doneToday.prefix(1))
            return work
        }
        /// 새 방문: 가짜 서버를 시나리오로 되돌리고(Clear 전) 저장소를 처음 상태로 비운 뒤 All work를 열어 읽는다
        func visit(_ scenario: SampleReturnSummaryGateway.Scenario, clear: SampleReturnSummaryGateway.ClearBehavior = .apply) async {
            gateway.reset(scenario, clear: clear)
            store.reset()
            shell.openAllWork()
            await store.refresh()
            await settle()
        }

        await visit(.changes)
        shoot("changes")
        await visit(.long)
        shoot("long")
        await visit(.deletedSource)
        shoot("deleted-source")
        await visit(.neverCleared)
        shoot("never-cleared")

        // 잘림: 보인 작업만 읽음 처리한다 → Clear 뒤에는 나머지가 나온다 ("모두 처리됨"이 아니다)
        await visit(.truncated)
        shoot("truncated")
        _ = await shell.clearSummary()?.value
        await settle()
        shoot("truncated-after-clear")

        // 읽지 못함 · 일부 읽지 못함 (비어 있다고 하지 않는다)
        await visit(.unavailable)
        shoot("changes-unavailable")
        await visit(.decisionsUnavailable)
        shoot("decisions-unavailable")
        await visit(.readFails)
        shoot("read-failed")
        // 받은 뒤 다시 읽지 못함: 줄은 두되 오래됨 표시, Clear 숨김
        await visit(.changes)
        gateway.scenario = .readFails
        await store.refresh()
        await settle()
        shoot("stale")

        // 빈 상태 · 기능 꺼짐: 아무것도 말하지 않는다
        await visit(.empty)
        shoot("empty")
        await visit(.featureOff)
        shoot("feature-off")

        // Clear: 진행 중(Clear 비활성) → 서버가 받은 뒤(결정 줄은 남고 Clear는 없다)
        await visit(.changes, clear: .hang)
        let clearing = shell.clearSummary()
        await settle()
        shoot("clearing")
        gateway.releaseHeld()
        _ = await clearing?.value
        await settle()
        shoot("after-clear")

        // 충돌 · 응답 유실 · 거절: 성공이라 하지 않고 자동 재전송 없이 다시 조회한 지금 상태
        await visit(.changes, clear: .conflict)
        _ = await shell.clearSummary()?.value
        await settle()
        shoot("conflict")
        await visit(.changes, clear: .loseResponse)
        _ = await shell.clearSummary()?.value
        await settle()
        shoot("lost-response")
        await visit(.changes, clear: .reject)
        _ = await shell.clearSummary()?.value
        await settle()
        shoot("rejected")

        // 움직임 줄이기
        await visit(.changes)
        shell.reduceMotion = true
        await settle()
        shoot("reduce-motion")
        shell.reduceMotion = EdgeShellController.systemReduceMotion
        edge.workOverride = nil
        gateway.releaseHeld()
    }
}
#endif
