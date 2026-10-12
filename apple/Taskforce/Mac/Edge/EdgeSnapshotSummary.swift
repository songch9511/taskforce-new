#if os(macOS) && DEBUG
import AppKit
import TaskforceKit

/// 복귀 요약(C3) 상태 PNG: `-TF_EDGE_SHELL YES -TF_C3 YES -TFSampleData -TFEdgeSnapshot <폴더> -TFEdgeSnapshotSummary` (+ `-TF_S4 YES`로 Review 연결, `-TFSnapshotDark`, `-TFReduceMotion YES`).
/// 견본 가짜 서버(`SampleReturnSummaryGateway`)를 시나리오대로 바꿔 가며 같은 패널(All work)에서 담는다. A–D 승인 후속으로 **바뀐 화면만** 담는다:
/// 승인된 새 문구(changes · long: 마지막 발생 순 셋 · deleted-source) · 정상 잘림 `More changes are available`(+ Clear 뒤 나머지) · 해석 못 한 변화 `Some changes couldn't be shown`(Clear 없음) ·
/// `Couldn't load items needing your answer` · 질문만 남은 카드(처음부터 · Clear 뒤) · 첫 사용(기준점 확정 전 · 뒤: Clear 없이 새 run 결과) · 빈 상태(아무것도 안 보임) · 움직임 줄이기.
/// 렌더된 fixture일 뿐이다: 실제 서버 · 계정 · AI 호출이 없다.
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
        /// 새 방문: 가짜 서버를 시나리오로 되돌리고(Clear 전, 기준점 전) 저장소를 처음 상태로 비운 뒤 All work를 열어 읽는다
        func visit(
            _ scenario: SampleReturnSummaryGateway.Scenario, clear: SampleReturnSummaryGateway.ClearBehavior = .apply,
            baseline: SampleReturnSummaryGateway.BaselineBehavior = .apply
        ) async {
            gateway.reset(scenario, clear: clear, baseline: baseline)
            store.reset()
            shell.openAllWork()
            await store.refresh()
            await settle()
        }

        // A: 승인된 문구 (Title changed · Updated from source · Needs revision · Result ready …)
        await visit(.changes)
        shoot("changes")
        await visit(.long)
        shoot("long")
        await visit(.deletedSource)
        shoot("deleted-source")

        // 정상 잘림: 더 있다고만 말하고 Clear는 가능 → Clear 뒤에는 나머지 페이지 (모두 처리됨이라 하지 않는다)
        await visit(.truncated)
        shoot("truncated")
        _ = await shell.clearSummary()?.value
        await settle()
        shoot("truncated-after-clear")

        // D-7: 해석 못 한 변화는 줄을 남기고 Clear를 막는다 / 결정 읽기 실패는 안전한 변화의 Clear를 막지 않는다
        await visit(.uninterpretable)
        shoot("uninterpretable")
        await visit(.decisionsUnavailable)
        shoot("questions-unavailable")

        // B: 질문만 남은 카드 (처음부터 · Clear 뒤). Clear는 숨는다
        await visit(.questionsOnly)
        shoot("questions-only")
        await visit(.changes)
        _ = await shell.clearSummary()?.value
        await settle()
        shoot("after-clear-questions-only")

        // C: 첫 사용. 첫 정상 표시 뒤 서버가 기준점을 확정한다(확정은 붙잡아 두었다가 보낸다). 그 뒤에는 Clear 없이도 새 run 결과가 나온다
        await visit(.firstUse, baseline: .hang)
        shoot("first-use-confirming")
        gateway.releaseHeld()
        await settle()
        await settle()
        shoot("first-use-confirmed")

        // 빈 상태: 아무것도 말하지 않는다
        await visit(.empty)
        shoot("empty")

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
