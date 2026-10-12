#if os(macOS) && DEBUG
import AppKit
import CryptoKit
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
        /// 담은 PNG마다 한 줄: 이름 · 바이트 지문 · 판정. 하나라도 INVALID면 실행이 실패로 끝난다 (조용히 저장하지 않는다)
        var checks: [String] = []
        var seen: [String: String] = [:]
        var invalid = 0
        /// `-TFEdgeSnapshotOnly a,b`: 이 이름들만 담는다 (상태를 만드는 단계는 그대로 돈다). 바뀐 상태만 다시 담을 때 쓴다
        let only: Set<String>? = {
            let arguments = ProcessInfo.processInfo.arguments
            guard let index = arguments.firstIndex(of: "-TFEdgeSnapshotOnly"), arguments.indices.contains(index + 1) else { return nil }
            return Set(arguments[index + 1].split(separator: ",").map(String.init))
        }()
        /// 검증기 자체를 확인하는 DEBUG 전용 주입: `-TFEdgeSnapshotInjectDismiss <이름>`은 그 상태를 담기 직전에 패널을 접고(밖 클릭이 하는 일 `shell.dismiss()`),
        /// `-TFEdgeSnapshotNoReopen`은 다시 열기를 끈다 (그러면 패널 없는 상태를 INVALID로 잡아 실행이 실패해야 한다)
        let arguments = ProcessInfo.processInfo.arguments
        let injectDismiss: String? = arguments.firstIndex(of: "-TFEdgeSnapshotInjectDismiss").flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil }
        let noReopen = arguments.contains("-TFEdgeSnapshotNoReopen")
        /// 패널이 보이는 상태에서만 담는다. 무인 캡처 중 다른 앱의 클릭 · 키 잃음이 패널을 접었으면(밖 클릭 · 키를 잃으면 접는 제품 동작) 같은 저장소 상태로 다시 열어 담고(최대 3번, 다시 연 횟수를 기록),
        /// 그래도 안 보이거나 다른 상태와 바이트가 같으면 INVALID다
        func shoot(_ name: String) async {
            if let only, !only.contains(name) { return }
            var reopened = 0
            if injectDismiss == name {
                shell.dismiss()
                await settle()
            }
            func shown() -> Bool { shell.panelOpen && shell.view == .allWork && edge.panel.isVisible && edge.panel.panel.alphaValue > 0.99 }
            while !shown() && reopened < (noReopen ? 0 : 3) {
                shell.openAllWork()
                reopened += 1
                await settle()
            }
            let url = file("summary-\(name)")
            try? FileManager.default.removeItem(at: url)
            EdgeSnapshot.capture(edge, to: url)
            let fingerprint = (try? Data(contentsOf: url)).map { SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined() } ?? "none"
            var verdict = "ok"
            if !shown() {
                verdict = "INVALID 패널이 보이지 않는다 (panelOpen=\(shell.panelOpen) view=\(shell.view) isVisible=\(edge.panel.isVisible) alpha=\(edge.panel.panel.alphaValue))"
            } else if fingerprint == "none" {
                verdict = "INVALID PNG를 쓰지 못했다"
            } else if let other = seen[fingerprint] {
                verdict = "INVALID \(other)와 바이트가 같다"
            }
            if verdict.hasPrefix("INVALID") { invalid += 1 } else { seen[fingerprint] = name }
            checks.append("\(name) sha256=\(fingerprint.prefix(16)) reopened=\(reopened) \(verdict)")
        }
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
        await shoot("changes")
        await visit(.long)
        await shoot("long")
        await visit(.deletedSource)
        await shoot("deleted-source")

        // 정상 잘림: 더 있다고만 말하고 Clear는 가능 → Clear 뒤에는 나머지 페이지 (모두 처리됨이라 하지 않는다)
        await visit(.truncated)
        await shoot("truncated")
        _ = await shell.clearSummary()?.value
        await settle()
        await shoot("truncated-after-clear")

        // D-7: 해석 못 한 변화는 줄을 남기고 Clear를 막는다 / 결정 읽기 실패는 안전한 변화의 Clear를 막지 않는다
        await visit(.uninterpretable)
        await shoot("uninterpretable")
        await visit(.decisionsUnavailable)
        await shoot("questions-unavailable")

        // B: 질문만 남은 카드 (처음부터 · Clear 뒤). Clear는 숨는다
        await visit(.questionsOnly)
        await shoot("questions-only")
        await visit(.changes)
        _ = await shell.clearSummary()?.value
        await settle()
        await shoot("after-clear-questions-only")

        // C: 첫 사용. 첫 정상 표시 뒤 서버가 기준점을 확정한다(확정은 붙잡아 두었다가 보낸다). 그 뒤에는 Clear 없이도 새 run 결과가 나온다
        await visit(.firstUse, baseline: .hang)
        await shoot("first-use-confirming")
        gateway.releaseHeld()
        await settle()
        await settle()
        await shoot("first-use-confirmed")

        // 빈 상태: 아무것도 말하지 않는다
        await visit(.empty)
        await shoot("empty")

        // 움직임 줄이기
        await visit(.changes)
        shell.reduceMotion = true
        await settle()
        await shoot("reduce-motion")
        shell.reduceMotion = EdgeShellController.systemReduceMotion
        edge.workOverride = nil
        gateway.releaseHeld()
        let report = file("summary-capture-check").deletingPathExtension().appendingPathExtension("txt")
        let argumentLine = arguments.dropFirst().joined(separator: " ")
        try? (["args: \(argumentLine)", "invalid=\(invalid)"] + checks).joined(separator: "\n").appending("\n").write(to: report, atomically: true, encoding: .utf8)
        if invalid > 0 { exit(2) }
    }
}
#endif
