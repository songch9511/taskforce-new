#if os(macOS) && DEBUG
import AppKit
import CryptoKit
import TaskforceKit
import TaskforceUI

/// 새 셸(캡슐 레일 · Taskforce bell · Taskforce 대화) PNG (OA U3, 디자인 비교용):
/// `-TF_EDGE_SHELL YES -TFSampleData -TF_S3B YES -TF_U2 YES -TF_S4 YES -TF_C3 YES -TFEdgeSnapshot <폴더> -TFEdgeSnapshotTaskforce` (+ `-TFSnapshotDark`, `-TFReduceMotion YES`).
/// 화면 녹화 권한 없이 자기 창(레일 · 이슈 패널 · 세션 패널)의 내용만 그려 데스크톱 견본 위에 실제 자리대로 붙인다 (`IssueSnapshot.compose`).
/// 움직이는 장면은 숨쉬기의 쉬는 프레임(크기 1, echo 없음)에서 찍는다 (`RailMotionSnapshot.frozen`).
/// 남기는 것(`mac-edge-taskforce-<이름>.png`): 레일 — rail-rest · rail-compact-bell-rings · rail-compact-rings · rail-compact-bell · rail-expanded · rail-expanded-no-bell · rail-expanded-no-rings ·
/// rail-more-open · rail-more-open-projects · rail-more-open-taskforce · rail-taskforce-open · rail-needs-you · rail-many · rail-many-expanded / 대화 — confirm · confirm-no-meta · confirm-long · result · conflict · conflict-held · conflict-sent · conflict-409 ·
/// conflict-long · steps-two · steps-many · request-summary · summary-only · empty-next · empty-projects · loading · offline · failed · incomplete · unknown-kind · last-answer.
/// 서버 응답은 가짜(`IssueSampleGateway` · `SampleReturnSummaryGateway`)라 렌더 fixture일 뿐이다: 실제 서버 · 계정 · AI 호출이 없다.
@MainActor
enum TaskforceSnapshot {
    static var isEnabled: Bool { ProcessInfo.processInfo.arguments.contains("-TFEdgeSnapshotTaskforce") }

    // MARK: 견본

    static let lease = UUID(uuidString: "c0000000-0000-4000-8000-000000000001")!
    static let holderRun = UUID(uuidString: "d0000000-0000-4000-8000-000000000001")!
    static let laterRun = UUID(uuidString: "d0000000-0000-4000-8000-000000000002")!
    static let issue = IssueSnapshotData.issue(139)

    /// 확인 요청 셋: 프로젝트가 있는 것 둘(Shape launch · Taskforce 0.2.0)과 없는 것 하나. 서버 순서 = 목록 순서
    static let seeds: [IssueSnapshotData.Seed] = IssueSnapshotData.seeds + [
        .init(number: 160, title: "Lifetime plan section wording", state: .toDo, dueOffset: 2, projects: [IssueSnapshotData.taskforce], review: true),
        .init(number: 161, title: "Alex asked for Thursday instead of Friday", state: .toDo, dueOffset: -1, projects: [], review: true),
    ]

    static let longConfirm: IssueSnapshotData.Seed = .init(
        number: 170,
        title: "Rewrite the entire pricing page, onboarding emails, release notes and the help center article about the Lifetime plan before Thursday",
        state: .toDo, dueOffset: 1, projects: [IssueSnapshotData.taskforce], review: true
    )

    static func confirm(_ number: Int) -> TaskforceDecisionGroup {
        let action = IssueSnapshotData.issue(number)
        let item = TaskforceDecisionItem(id: "confirm:\(action.uuidString.lowercased())", kind: .confirm, actionID: action, version: "action:\(number):3")
        return TaskforceDecisionGroup(key: "\(action):confirm", actionID: action, kind: .confirm, items: [item])
    }

    static func result(session: Int = 2) -> TaskforceDecisionGroup {
        let ref = TaskforceResultRef(sessionID: IssueSnapshotData.session(session), reviewedTurnSeq: 0, lastTurnSeq: 2, changedAt: "2026-10-15T01:00:00.000Z")
        let item = TaskforceDecisionItem(id: "result_ready:\(holderRun.uuidString.lowercased())", kind: .resultReady, actionID: issue, version: "result:1", result: ref)
        return TaskforceDecisionGroup(key: "\(issue):result_ready", actionID: issue, kind: .resultReady, items: [item])
    }

    static func conflict(version: Int = 2) -> TaskforceDecisionGroup {
        let ref = TaskforceConflictRef(leaseID: lease, conflictVersion: version, holderActionID: issue, holderRunID: holderRun, laterRunID: laterRun, released: false, stopped: true)
        let item = TaskforceDecisionItem(id: "path_conflict:\(lease.uuidString.lowercased())", kind: .pathConflict, actionID: issue, version: "conflict:\(version)", conflict: ref)
        return TaskforceDecisionGroup(key: "\(issue):path_conflict", actionID: issue, kind: .pathConflict, items: [item])
    }

    static func detail(path: String = "src/content/pricing.mdx") -> TaskforceConflictDetail {
        TaskforceConflictDetail(
            leaseID: lease, relPath: path, holderRunID: holderRun, laterRunID: laterRun,
            holderSessionID: IssueSnapshotData.session(1), laterSessionID: IssueSnapshotData.session(2)
        )
    }

    /// 서버 순서: 결과 · 충돌 · 확인 요청들
    static func response(_ groups: [TaskforceDecisionGroup]? = nil, complete: Bool = true) -> TaskforceReviewResponse {
        TaskforceReviewResponse(complete: complete, decisions: groups ?? [result(), conflict(), confirm(150), confirm(160), confirm(161)])
    }

    /// 확인 요청 아래 원문 (v1 근거)
    static func evidence() -> [UUID: EvidenceDigest] {
        [
            IssueSnapshotData.issue(150): EvidenceDigest(lines: [
                ReviewSnapshot.line("Could we do the core launch on Thursday instead? Partner review moved up a day.", "Gmail thread · Jordan Lee", .gmail, ago: 7_200),
            ]),
            IssueSnapshotData.issue(160): EvidenceDigest(lines: [
                ReviewSnapshot.line("The Lifetime plan should say it is billed once to your OpenRouter account.", "#pricing · Mina", .slack, ago: 5_400, url: "https://acme.slack.com/sample"),
            ]),
            IssueSnapshotData.issue(161): EvidenceDigest(lines: [
                ReviewSnapshot.line("Alex needs the proposal by Thursday now.", "#sales · Mina", .slack, ago: 3_600, url: "https://acme.slack.com/sample"),
            ]),
            IssueSnapshotData.issue(170): EvidenceDigest(lines: [
                ReviewSnapshot.line(
                    "Please rewrite the pricing page, the onboarding emails, the release notes and the help center article about the Lifetime plan before Thursday so that all four read the same way and the first month price is shown once on every card.",
                    "Kickoff meeting notes", .notion, ago: 90_000, url: "https://www.notion.so/sample"
                ),
            ]),
        ]
    }

    // MARK: 장면

    static func capture(_ edge: EdgeShellController, file: (String) -> URL, pause: @escaping (Double) async -> Void) async {
        guard let runtime = edge.chat, let issues = runtime.issues, let contexts = runtime.contexts, let now = edge.launcher.now,
              let summary = edge.shell.summary, edge.shell.taskforceEnabled else {
            print("TaskforceSnapshot: 새 셸이 꺼진 구성이다 (-TF_EDGE_SHELL YES -TF_S3B YES -TF_U2 YES -TF_S4 YES -TF_C3 YES 필요) taskforce=\(edge.shell.taskforceEnabled) issues=\(edge.chat?.issues != nil) contexts=\(edge.chat?.contexts != nil) now=\(edge.launcher.now != nil) review=\(edge.shell.review != nil) summary=\(edge.shell.summary != nil)")
            return
        }
        let shell = edge.shell
        let store = issues.taskforce
        let sample = IssueSampleGateway.shared
        let contextSample = IssueSampleContextGateway.shared
        let summaryGateway = AppRuntime.sampleSummaryGateway
        RailMotionSnapshot.frozen = true
        // 실제 포인터가 레일 위에 있으면 호버가 섞인다: 화면 왼쪽 가장자리 가운데에 치워 두고 끝나면 되돌린다
        let parked = parkPointer()
        defer { parked() }
        shell.onSessionPill = { _, _ in }
        func settle(_ seconds: Double = 0.8) async { await pause(seconds) }
        var checks: [String] = []
        var seen: [String: String] = [:]
        var invalid = 0
        let only: Set<String>? = {
            let arguments = ProcessInfo.processInfo.arguments
            guard let index = arguments.firstIndex(of: "-TFEdgeSnapshotOnly"), arguments.indices.contains(index + 1) else { return nil }
            return Set(arguments[index + 1].split(separator: ",").map(String.init))
        }()

        /// 한 장 담는다: 무인 실행에서 다른 앱의 클릭이 패널을 접었으면 다시 연다. 바이트가 다른 장면과 같으면 INVALID다 (조용히 저장하지 않는다)
        func shoot(_ name: String, panel: Bool = true, shows kind: TaskforceRequest.Kind? = nil, screen expected: TaskforceScreen? = nil, card: Bool = false) async {
            if let only, !only.contains(name) { return }
            var reopened = 0
            func shown() -> Bool { !panel || (shell.panelOpen && edge.panel.isVisible && edge.panel.panel.alphaValue > 0.99) }
            while !shown(), reopened < 3 {
                shell.openTaskforce(requestID: shell.taskforceShownID)
                reopened += 1
                await settle()
            }
            // 실제 포인터가 레일 위를 지나면 호버가 섞인다(칸이 칠해진다): 어떤 호버가 있었는지 적고, 담기 직전에 지운다. 이 하네스는 호버를 그리지 않는다
            let hoverSeen = [
                shell.hoveredControl.map { "control:\($0)" }, shell.hoveredBell ? "bell" : nil, shell.hoveredPlus ? "plus" : nil,
                shell.hoveredID != nil ? "ring" : nil, shell.assistantWindowFront ? "windowFront" : nil,
            ].compactMap { $0 }.joined(separator: ",")
            shell.hover(control: nil)
            shell.hover(bell: false)
            shell.hover(plus: false)
            shell.hover(item: nil)
            let url = file("taskforce-\(name)")
            try? FileManager.default.removeItem(at: url)
            IssueSnapshot.compose(edge, to: url)
            let fingerprint = (try? Data(contentsOf: url)).map { SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined() } ?? "none"
            var verdict = "ok"
            if !shown() {
                verdict = "INVALID 패널이 보이지 않는다"
            } else if fingerprint == "none" {
                verdict = "INVALID PNG를 쓰지 못했다"
            } else if let other = seen[fingerprint] {
                verdict = "INVALID \(other)와 바이트가 같다"
            }
            // 이름대로의 장면인지: 보인 요청의 종류가 다르면 (재료가 없어 건너뛴 경우 등) 조용히 다른 그림이 되지 않게 한다
            if verdict == "ok", let expected, shell.taskforceScreen != expected {
                verdict = "INVALID 화면이 \(expected)가 아니다 (지금: \(shell.taskforceScreen))"
            }
            if verdict == "ok", let kind, shell.shownTaskforceRequest?.kind != kind {
                verdict = "INVALID \(kind) 요청이 보이지 않는다 (보이는 것: \(shell.shownTaskforceRequest.map { "\($0.kind)" } ?? "없음"))"
            }
            // 칠해진 칸은 하나뿐: 패널이 열린 장면은 bell만 칠해지고 셋째 캡슐은 하나도 안 칠해진다 (More 카드 장면은 More만)
            let lit = shell.controls.filter { shell.railControlHighlighted($0) }
            if verdict == "ok", panel, !lit.isEmpty {
                verdict = "INVALID 패널이 열렸는데 칠해진 칸이 더 있다: \(lit)"
            }
            if verdict == "ok", card, !edge.rail.moreCard.isOpen {
                verdict = "INVALID More 카드가 닫혔다"
            }
            // More 카드가 열려 있으면 칠해진 칸은 ⋯ 하나다: 열린 화면의 칸 · 열린 대화의 bell 칠은 그리지 않는다 (재검토 1)
            if verdict == "ok", card, lit != [.more] || shell.railBellSelectionShown {
                verdict = "INVALID More 카드가 열려 있는데 칠해진 칸이 ⋯ 하나가 아니다: \(lit) bell칠=\(shell.railBellSelectionShown)"
            }
            if verdict.hasPrefix("INVALID") { invalid += 1 } else { seen[fingerprint] = name }
            checks.append("\(name) sha256=\(fingerprint.prefix(16)) reopened=\(reopened) hover=[\(hoverSeen)] lit=\(lit) \(verdict)")
        }

        /// 새 계정이 막 로그인한 것처럼 저장소를 비우고 가짜 서버 시나리오대로 다시 읽는다
        func world(
            seeds worldSeeds: [IssueSnapshotData.Seed] = seeds, sessions: IssueSampleGateway.SessionScenario = .basic, response: TaskforceReviewResponse? = response(),
            details: [UUID: TaskforceConflictDetail] = [lease: detail()], read: IssueSampleGateway.ReadScenario = .full,
            summaryScenario: SampleReturnSummaryGateway.Scenario? = nil, load: WorkLoad = .loaded(problem: nil)
        ) async {
            sample.sessions = sessions
            sample.taskforceResponse = response
            sample.taskforceDetails = details
            sample.taskforceRead = read
            sample.resolveFailure = nil
            sample.resolveDelay = 0
            contextSample.scenario = .full
            contextSample.seeds = worldSeeds
            runtime.scope.accountLeft()
            edge.workOverride = { _ in IssueSnapshotData.snapshot(seeds: worldSeeds, load: load) }
            let sampleNow = SampleData.now
            now.applySample(sampleNow, doneToday: SampleData.doneToday, evidence: SampleData.evidence.merging(evidence(), uniquingKeysWith: { _, mine in mine }))
            if let summaryScenario, let summaryGateway {
                summaryGateway.reset(summaryScenario)
                summary.reset()
            } else {
                summaryGateway?.reset(.empty)
                summary.reset()
            }
            shell.dismiss()
            shell.pointer(inside: false)
            Task { await contexts.refresh() }
            await issues.numbers.ensure(worldSeeds.map { IssueSnapshotData.issue($0.number) })
            await issues.sessions.refresh()
            shell.sessionsChanged()
            // 읽기가 끝나지 않는 장면(loading)은 기다리지 않고 띄워 둔다
            if read == .hang {
                Task { await store.refresh() }
            } else {
                await store.refresh()
            }
            await summary.refresh()
            shell.taskforceChanged()
            await settle(0.6)
        }
        /// 패널 없이 접힌 레일 (떠남 400ms 뒤)
        func folded() async {
            shell.dismiss()
            shell.pointer(inside: false)
            await settle(0.7)
        }
        /// 호버 120ms 뒤 펼친 레일
        func hovered() async {
            shell.dismiss()
            shell.pointer(inside: true)
            await settle(0.5)
        }
        func open(_ index: Int = 0) async {
            shell.pointer(inside: false)
            shell.openTaskforce(requestID: shell.taskforceQueue.ids.indices.contains(index) ? shell.taskforceQueue.ids[index] : nil)
            await settle(0.9)
        }
        func request(_ kind: TaskforceRequest.Kind, of number: Int? = nil) async {
            let queue = shell.taskforceQueue
            let match = queue.requests.first { request in
                guard request.kind == kind else { return false }
                if let number, kind == .confirm { return request.actionID == IssueSnapshotData.issue(number) }
                return true
            }
            shell.pointer(inside: false)
            shell.openTaskforce(requestID: match?.id)
            await settle(0.9)
        }

        // ── 레일 ──────────────────────────────────────────────
        // 쉼: 링 0 · 요청 0
        await world(seeds: IssueSnapshotData.seeds.filter { !$0.working && !$0.review }, sessions: .none, response: Self.response([]))
        await folded()
        await shoot("rail-rest", panel: false)

        // 접힘: bell + 링 셋 · 링만 · bell만
        await world(seeds: Self.manyRingSeeds(3, review: true), sessions: .none)
        await folded()
        await shoot("rail-compact-bell-rings", panel: false)
        await world(seeds: Self.manyRingSeeds(3, review: false), sessions: .none, response: Self.response([]))
        await folded()
        await shoot("rail-compact-rings", panel: false)
        await world(seeds: IssueSnapshotData.seeds.filter { !$0.working }, sessions: .none)
        await folded()
        await shoot("rail-compact-bell", panel: false)

        // 펼침: bell + 링 넷 + `+` + 셋째 캡슐 · bell 없음 · 링 0
        await world(seeds: Self.manyRingSeeds(4, review: true), sessions: .none)
        await hovered()
        await shoot("rail-expanded", panel: false)
        await world(seeds: Self.manyRingSeeds(4, review: false), sessions: .none, response: Self.response([]))
        await hovered()
        await shoot("rail-expanded-no-bell", panel: false)
        await world(seeds: IssueSnapshotData.seeds.filter { !$0.working && !$0.review }, sessions: .none, response: Self.response([]))
        await hovered()
        await shoot("rail-expanded-no-rings", panel: false)
        // DS "More open · no requests": 요청이 없어 bell이 없고, ⋯를 누른 것과 같은 길로 카드를 연다 (OA U3 16.1)
        await world(seeds: Self.manyRingSeeds(2, review: false), sessions: .none, response: Self.response([]))
        await hovered()
        edge.rail.openMoreCardForSnapshot()
        await settle(0.4)
        await shoot("rail-more-open", panel: false, card: true)
        edge.rail.moreCard.dismiss()
        // 재검토 1: 본문이 열린 채 More 카드를 열어도 칠해진 칸은 ⋯ 하나다: Projects가 열려 있을 때 · Taskforce 대화가 열려 있을 때(bell)
        await world()
        shell.pointer(inside: false)
        shell.openAllWork()
        await settle(0.9)
        edge.rail.openMoreCardForSnapshot()
        await settle(0.4)
        await shoot("rail-more-open-projects", panel: false, card: true)
        edge.rail.moreCard.dismiss()
        await world()
        await request(.confirm, of: 150)
        edge.rail.openMoreCardForSnapshot()
        await settle(0.4)
        await shoot("rail-more-open-taskforce", panel: false, card: true)
        edge.rail.moreCard.dismiss()

        // 세션이 질문한다: 링이 needs-you (주황), 많은 링 (다섯 이상은 넷까지)
        await world(sessions: .awaiting)
        await hovered()
        await shoot("rail-needs-you", panel: false)
        await world(seeds: Self.manyRingSeeds(7, review: true), sessions: .none)
        await folded()
        await shoot("rail-many", panel: false)
        await hovered()
        await shoot("rail-many-expanded", panel: false)

        // Taskforce 열림: bell 칸이 칠해진다
        await world()
        await request(.confirm, of: 150)
        await shoot("rail-taskforce-open")

        // ── 대화 ──────────────────────────────────────────────
        await world()
        await request(.confirm, of: 150)
        await shoot("confirm", shows: .confirm)
        await request(.confirm, of: 161)
        await shoot("confirm-no-meta", shows: .confirm)
        await request(.resultReady)
        await shoot("result", shows: .resultReady)
        await request(.pathConflict)
        await shoot("conflict", shows: .pathConflict)
        // 고른 뒤 2초 보류: 답 잠금 · 고른 답 체크 · Answer sent + Undo
        sample.resolveDelay = 5
        _ = shell.answerConflict(.later, for: shell.taskforceShownID ?? "")
        await settle(0.4)
        await shoot("conflict-held", shows: .pathConflict)
        await settle(2.4)
        await shoot("conflict-sent", shows: .pathConflict)
        store.reset()
        // 409: 안내가 남고 다시 읽는다
        await world()
        sample.resolveFailure = APIError.server(status: 409, code: .conflict, message: "x")
        await request(.pathConflict)
        _ = shell.answerConflict(.holder, for: shell.taskforceShownID ?? "")
        await settle(3.2)
        await shoot("conflict-409", shows: .pathConflict)
        // 긴 경로 · 긴 세션 이름
        await world(sessions: .longNamePair, details: [lease: detail(path: "packages/very-long-workspace-name/src/content/localized/ko/pricing-page-final-v2-with-a-long-name.mdx")])
        await request(.pathConflict)
        await shoot("conflict-long", shows: .pathConflict)

        // 긴 확인 요청
        await world(seeds: seeds + [longConfirm], response: Self.response([Self.confirm(170), Self.confirm(150)]))
        await request(.confirm, of: 170)
        await shoot("confirm-long", shows: .confirm)

        // steps: 둘 · 많은 것(20) · ← → 끝
        await world(response: Self.response([Self.confirm(150), Self.confirm(160)]))
        await request(.confirm, of: 150)
        await shoot("steps-two")
        let many = (0..<20).map { 200 + $0 }
        let manySeeds = seeds + many.map { IssueSnapshotData.Seed(number: $0, title: "Pricing review item \($0 - 199)", state: .toDo, dueOffset: nil, projects: [], review: true) }
        await world(seeds: manySeeds, response: Self.response(many.map { Self.confirm($0) }))
        await open(12)
        await shoot("steps-many")

        // 요청 + 요약 · 요약만 · 빈 상태
        await world(response: Self.response([Self.confirm(150)]), summaryScenario: .changes)
        await request(.confirm, of: 150)
        await shoot("request-summary", shows: .confirm, screen: .request(problem: nil))
        await world(response: Self.response([]), summaryScenario: .changes)
        await open()
        await shoot("summary-only", screen: .empty(problem: nil))
        await world(response: Self.response([]))
        await open()
        await shoot("empty-next", screen: .empty(problem: nil))
        await world(seeds: [], response: Self.response([]), summaryScenario: .empty)
        await open()
        await shoot("empty-projects", screen: .empty(problem: nil))
        // 마지막 답 뒤 (대화가 열린 동안 bell은 조용히 남는다)
        await world(response: Self.response([Self.confirm(150)]))
        await request(.confirm, of: 150)
        sample.taskforceResponse = Self.response([])
        await store.refresh()
        shell.taskforceChanged()
        await settle(0.8)
        await shoot("last-answer", screen: .empty(problem: nil))

        // 읽기 상태
        await world(response: Self.response(), read: .hang)
        store.reset()
        shell.openTaskforce()
        await settle(0.8)
        await shoot("loading", screen: .blank)
        store.pathChanged(online: false)
        await world(read: .offline)
        shell.openTaskforce()
        await settle(0.8)
        await shoot("offline", screen: .offline)
        store.pathChanged(online: true)
        await world(read: .failed)
        shell.openTaskforce()
        await settle(0.8)
        await shoot("failed", screen: .failed)
        await world(response: Self.response([Self.confirm(150)], complete: false))
        await request(.confirm, of: 150)
        await shoot("incomplete", shows: .confirm, screen: .request(problem: .failed))
        let unknown = TaskforceDecisionGroup(key: "k", actionID: issue, kind: .unknown, items: [TaskforceDecisionItem(id: "future:1", kind: .unknown, actionID: issue, version: "v")])
        await world(response: Self.response([unknown, Self.confirm(150)]))
        await request(.confirm, of: 150)
        await shoot("unknown-kind", shows: .confirm, screen: .request(problem: .failed))

        await world()
        shell.dismiss()
        RailMotionSnapshot.frozen = false
        let report = file("taskforce-checks").deletingPathExtension().appendingPathExtension("txt")
        try? checks.joined(separator: "\n").appending("\n").write(to: report, atomically: true, encoding: .utf8)
        if invalid > 0 {
            print("TaskforceSnapshot: INVALID \(invalid)장 (\(report.path))")
            exit(2)
        }
    }

    /// 링이 `count`개 나오는 이슈들 (v1 run이 도는 이슈 = 링 하나) + `review`면 확인 요청 셋
    static func manyRingSeeds(_ count: Int, review: Bool) -> [IssueSnapshotData.Seed] {
        let rings = (0..<count).map { index in
            IssueSnapshotData.Seed(number: 180 + index, title: "Running issue \(index + 1)", state: .inProgress, dueOffset: nil, projects: [IssueSnapshotData.taskforce], working: true)
        }
        return rings + (review ? seeds.filter(\.review) : [])
    }

    private static func parkPointer() -> () -> Void {
        guard let screen = NSScreen.screens.first else { return {} }
        let original = NSEvent.mouseLocation
        let height = screen.frame.height
        CGWarpMouseCursorPosition(CGPoint(x: 12, y: height / 2))
        return { CGWarpMouseCursorPosition(CGPoint(x: original.x, y: height - original.y)) }
    }
}
#endif
