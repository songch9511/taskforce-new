import SwiftUI
import Testing
import TaskforceKit
@testable import TaskforceUI

/// OA U3 11.2: Result ready 카드 · 충돌 본문의 답 단계(키 1 · 2) · 머리 steps(요청 이름 · 창) · confirm 메타 줄 · auto 칩
@MainActor
struct TaskforceRequestCardsTests {
    private func answer(_ keep: TaskforceConflictKeep, _ phase: TaskforceAnswerPhase) -> TaskforceAnswer {
        TaskforceAnswer(requestID: "path_conflict:x", keep: keep, phase: phase)
    }

    @Test func beforeChoosingBothAnswersAreReadyAndOfflineLocksThem() {
        typealias C = TaskforceConflictCard
        #expect(C.phase(for: .holder, chosen: nil, canAnswer: true) == .ready && C.phase(for: .later, chosen: nil, canAnswer: true) == .ready)
        #expect(C.phase(for: .holder, chosen: nil, canAnswer: false) == .locked, "오프라인에서는 나중에 보내려고 모아 두지 않는다")
    }

    @Test func choosingLocksTheOtherAnswerAndChecksTheChosenOne() {
        typealias C = TaskforceConflictCard
        for phase in [TaskforceAnswerPhase.holding, .sending] {
            let chosen = answer(.later, phase)
            #expect(C.phase(for: .later, chosen: chosen, canAnswer: true) == .chosen, "고른 답에 check")
            #expect(C.phase(for: .holder, chosen: chosen, canAnswer: true) == .locked, "답 잠금")
        }
    }

    @Test func theFirstSideSaysTouchedFirstBeforeItsState() {
        let session = AgentSessionItem(
            id: UUID(), name: "Pricing copy draft", agent: .claudeCode, agentName: "Claude Code", connectionID: UUID(), status: .bound, ring: .running, line: "Running",
            createdAt: Date(), updatedAt: Date(), issueIDs: [], currentIssueID: nil, conversationID: nil, hasOpenTask: true, pill: nil
        )
        #expect(TaskforceConflictSide.first(session).line == "Touched first · Running")
        let closed = AgentSessionItem(
            id: UUID(), name: "Old", agent: .codex, agentName: "Codex", connectionID: UUID(), status: .closed, ring: nil, line: "",
            createdAt: Date(), updatedAt: Date(), issueIDs: [], currentIssueID: nil, conversationID: nil, hasOpenTask: false, pill: nil
        )
        #expect(TaskforceConflictSide.first(closed).line == "Touched first", "상태 말이 없는 닫힌 세션")
    }

    @Test func requestStepsNameThePositionAndSlideAfterTen() {
        let steps = PanelHeader.Steps(count: 3, current: 1, style: .request)
        #expect(steps.accessibilityLabel == "Request 2 of 3" && steps.dotLabel(0) == "Request 1 of 3")
        #expect(steps.visibleDots == 0..<3)
        let many = PanelHeader.Steps(count: 20, current: 12, style: .request)
        #expect(many.visibleDots == 7..<17 && many.visibleDots.contains(12), "지금 요청이 가운데")
        #expect(many.visibleDots.count == 10, "380 폭에서 제목이 잘리지 않는 만큼")
    }

    @Test func theOldReviewStepsAreUntouched() {
        let steps = PanelHeader.Steps(count: 20, current: 12)
        #expect(steps.style == .review && steps.accessibilityLabel == "Review item 13 of 20" && steps.dotLabel(3) == "Review item 4")
        #expect(steps.visibleDots == 0..<20, "옛 Review는 점을 모두 그린다 (Release 그대로)")
    }

    @Test func theTaskforceConfirmCardHasNoMetaLineWhenThereIsNoProject() {
        // 메타가 비면 줄이 없다: 질문이 이미 질문이다. 번호 글은 답이 넷일 때만 (DS) — 키는 그대로 답한다
        let answers = [DecisionBlock<EmptyView>.Answer(index: 1, label: "Confirm"), .init(index: 2, label: "Dismiss")]
        let block = DecisionBlock(meta: "", question: "Not sure it's yours", answers: answers, quietKeys: true, onAnswer: { _ in }) { EmptyView() }
        _ = block.body
        #expect(AnswerOption(index: 1, label: "Confirm", quietKey: true, action: {}).quietKey)
        #expect(!AnswerOption(index: 1, label: "Confirm", action: {}).quietKey, "Release S4는 번호를 그대로 그린다")
    }
}

/// OA U3-47: auto 칩은 옅은 면 위의 조용한 글이다 (점선 없음), 대비 높이기에서만 1pt 테두리
struct ContextChipLookTests {
    @Test func theAutoChipIsAQuietTextOnALightFillWithNoOutline() {
        let look = ContextChip.Look.of(origin: .auto, increasedContrast: false)
        #expect(look.fill == .selected && look.quietText && look.borderWidth == 0, "bg-selected · text-secondary · 테두리 0")
        #expect(look.insets == [3, 6, 3, 4])
    }

    @Test func theAddedChipKeepsItsElevatedFillAndBothHaveTheSameTwentyTwoPointFrame() {
        let added = ContextChip.Look.of(origin: .added, increasedContrast: false)
        #expect(added.fill == .elevated && !added.quietText && added.borderWidth == 0)
        #expect(added.insets == ContextChip.Look.of(origin: .auto, increasedContrast: false).insets, "안쪽 3/4/3/6: 둘 다 22pt (16 + 3 + 3)")
    }

    @Test func increasedContrastGivesBothAOnePointBorder() {
        #expect(ContextChip.Look.of(origin: .auto, increasedContrast: true).borderWidth == 1)
        #expect(ContextChip.Look.of(origin: .added, increasedContrast: true).borderWidth == 1)
    }
}
