import Foundation
import Testing
@testable import TaskforceKit

/// 복귀 요약의 글자 · 표시 규칙 (순수 함수, A–D 승인 후속 `handoffs/c3-ad-contract.md` "Mac 쪽").
/// 핵심: 비어 있다는 말은 어디에도 없고(완전한 빈 응답은 아무것도 그리지 않는다), 읽지 못함 · 일부 실패 · 잘림 · 해석 못 한 변화는 서로 다른 말로 정직하게 말하며,
/// 해석 못 한 변화는 보이되 Clear를 막고(정상 잘림 · 결정 읽기 실패와 분리), 질문만 남으면 같은 카드가 `Needs your answer`가 되고,
/// 줄이 말하는 서로 다른 변화 셋은 실제 마지막 발생 순이며, 숫자(개수)가 없다
struct ReturnSummaryRulesTests {
    typealias Fx = ReturnSummaryFx
    let utc = TimeZone(secondsFromGMT: 0)!
    let now = Date.test(0)

    func content(
        _ summary: ReturnSummaryResponse?, isStale: Bool = false, readFailed: Bool = false, cursorSpent: Bool = false, isClearing: Bool = false,
        message: String? = nil, canOpen: @escaping (UUID) -> Bool = { _ in true }
    ) -> ReturnSummaryContent? {
        ReturnSummaryPresentation.make(
            summary: summary, isStale: isStale, readFailed: readFailed, cursorSpent: cursorSpent, isClearing: isClearing, message: message,
            now: now, timeZone: utc, canOpen: canOpen
        )
    }

    // MARK: 카드 캡션

    @Test func theCaptionIsSinceAndWhenTheLastClearWas() {
        #expect(ReturnSummaryCopy.title(since: .test(-3_600), now: now, timeZone: utc) == "Since today 08:00")
        #expect(ReturnSummaryCopy.title(since: .test(-86_400), now: now, timeZone: utc) == "Since yesterday 09:00")
        #expect(ReturnSummaryCopy.title(since: .test(-5 * 86_400), now: now, timeZone: utc) == "Since Oct 6")
    }

    /// 마지막 Clear 시각을 모르면 시각을 지어내지 않는다. 기준점만 있고 Clear가 없으면(initialized) `since`가 있어도 Since를 말하지 않는다 (Clear한 적이 없다)
    @Test func withoutASinceTheCaptionDoesNotInventATime() {
        #expect(ReturnSummaryCopy.title(since: nil, now: now, timeZone: utc) == "Changes")
        let never = Fx.response([Fx.item(1, changes: [Fx.change()])], since: nil, baseline: .neverCleared)
        #expect(content(never)?.title == "Changes")
        let initialized = Fx.response([Fx.item(1, changes: [Fx.change()])], since: -3_600, baseline: .initialized)
        #expect(content(initialized)?.title == "Changes")
        let unknownBaseline = Fx.response([Fx.item(1, changes: [Fx.change()])], since: -3_600, baseline: .unknown)
        #expect(content(unknownBaseline)?.title == "Changes")
        let cleared = Fx.response([Fx.item(1, changes: [Fx.change()])], since: -3_600, baseline: .cleared)
        #expect(content(cleared)?.title == "Since today 08:00")
    }

    // MARK: A — 변화 글 (승인된 문구)

    @Test func actionEventTokensReadAsTheApprovedPhrases() {
        func text(_ kind: String, _ state: ReturnSummarySourceState? = .available) -> String? {
            ReturnSummaryCopy.change(Fx.change(.actionEvent, kind, sourceState: state))
        }
        #expect(text("due_changed") == "Due date changed")
        #expect(text("scope_changed") == "Title changed")
        #expect(text("owner_changed") == "Owner changed")
        #expect(text("merged") == "Updated from source")
        #expect(text("completed") == "Completed")
        #expect(text("dropped") == "Canceled")
        #expect(text("reopened") == "Reopened")
        #expect(text("artifact_created") == "Draft ready")
        #expect(text("teleported") == nil)
    }

    /// `Needs revision`은 review_failed에만, `Result ready`는 agent_done에만 쓴다. `Processing finished`는 결과 이름 없이 끝난 처리뿐이고, 모르는 결과를 정상 성공으로 올리지 않는다
    @Test func runResultsUseTheApprovedPhrasesAndNeverPromoteUnknownOutcomes() {
        func text(_ kind: String, _ detail: String? = nil) -> String? {
            ReturnSummaryCopy.change(Fx.change(.run, kind, detail: detail))
        }
        #expect(text("done", "draft_ready") == "Draft ready")
        #expect(text("done", "needs_input") == "Taskforce has a question")
        #expect(text("done", "needs_connection") == "Needs a connection")
        #expect(text("done", "needs_capability") == "Needs a connection")
        #expect(text("done", "review_failed") == "Needs revision")
        #expect(text("done", "agent_done") == "Result ready")
        #expect(text("done") == "Processing finished")
        #expect(text("failed") == "Couldn't finish the draft")
        // 모르는 결과: 어떤 성공 문구도 주지 않는다 (해석 못 한 변화)
        for unknown in ["something_new", "passed_review", "ok", ""] {
            #expect(text("done", unknown) == nil, "\(unknown)")
            #expect(!Fx.change(.run, "done", detail: unknown).isInterpretable, "\(unknown)")
        }
        #expect(text("exploded") == nil && !Fx.change(.run, "exploded").isInterpretable)
        // 그 문구는 그 결과에만 나온다
        for detail in ["draft_ready", "needs_input", "needs_connection", "needs_capability", "agent_done", nil] {
            #expect(text("done", detail) != "Needs revision", "\(detail ?? "nil")")
        }
        for detail in ["draft_ready", "needs_input", "needs_connection", "needs_capability", "review_failed", nil] {
            #expect(text("done", detail) != "Result ready", "\(detail ?? "nil")")
        }
        for detail in ["draft_ready", "needs_input", "needs_connection", "needs_capability", "review_failed", "agent_done"] {
            #expect(text("done", detail) != "Processing finished", "\(detail)")
        }
    }

    @Test func messageTokens() {
        #expect(ReturnSummaryCopy.change(Fx.change(.message, "assistant")) == "New reply")
        #expect(ReturnSummaryCopy.change(Fx.change(.message, "event")) == "New update")
        #expect(ReturnSummaryCopy.change(Fx.change(.message, "gossip")) == nil && !Fx.change(.message, "gossip").isInterpretable)
        #expect(ReturnSummaryCopy.change(Fx.change(.unknown, "done")) == nil && !Fx.change(.unknown, "done").isInterpretable)
    }

    /// 지운 원문 · 접근 상실 · 보관 만료는 글이나 옛 제목이 아니라 토큰의 말이다 (Remembered · 초안과 같은 말). 모르는 원문 상태는 해석 못 한 변화다
    @Test func aGoneSourceIsAWordNotAQuote() {
        func text(_ state: ReturnSummarySourceState) -> String? {
            ReturnSummaryCopy.change(Fx.change(.actionEvent, "scope_changed", sourceState: state))
        }
        #expect(text(.available) == "Title changed")
        #expect(text(.deleted) == "Title changed · Original text deleted")
        #expect(text(.accessLost) == "Title changed · The source is no longer available")
        #expect(text(.textExpired) == "Title changed · Text deleted after 90 days.")
        #expect(text(.unknown) == nil && !Fx.change(.actionEvent, "scope_changed", sourceState: .unknown).isInterpretable)
        #expect(ReturnSummaryCopy.sourceDeleted == MemoryCopy.purgedStatement && ReturnSummaryCopy.sourceUnavailable == MemoryCopy.sourceMissing)
        // 무엇이 바뀌었는지 모르는 변화는 원문 상태만 따로 말하지 않는다 (해석 못 한 변화로 통째로 둔다)
        #expect(ReturnSummaryCopy.change(Fx.change(.actionEvent, "teleported", sourceState: .deleted)) == nil)
    }

    /// 승인된 새 문구 17개(+ 조건부 `Next: review the result`는 이 앱에서 생략)가 그대로이고, 기존 Clear · Needs your answer · Since …를 재사용한다
    @Test func theApprovedStringsAreExactlyThese() {
        let approved = [
            "Changes", "Couldn't load changes", "Couldn't load items needing your answer", "More changes are available", "Some changes couldn't be shown",
            "Due date changed", "Title changed", "Owner changed", "Updated from source", "Completed", "Canceled", "Reopened",
            "Needs revision", "Result ready", "Processing finished", "New reply", "New update",
        ]
        let actual = [
            ReturnSummaryCopy.changesTitle, ReturnSummaryCopy.couldNotLoad, ReturnSummaryCopy.couldNotLoadQuestions, ReturnSummaryCopy.moreAvailable,
            ReturnSummaryCopy.couldNotShow, ReturnSummaryCopy.actionEventDueChanged, ReturnSummaryCopy.actionEventTitleChanged,
            ReturnSummaryCopy.actionEventOwnerChanged, ReturnSummaryCopy.actionEventUpdatedFromSource, ReturnSummaryCopy.actionEventCompleted,
            ReturnSummaryCopy.actionEventDropped, ReturnSummaryCopy.actionEventReopened, ReturnSummaryCopy.runNeedsRevision, ReturnSummaryCopy.runResultReady,
            ReturnSummaryCopy.runProcessingFinished, ReturnSummaryCopy.messageAssistant, ReturnSummaryCopy.messageEvent,
        ]
        #expect(actual == approved)
        #expect(ReturnSummaryCopy.clear == "Clear" && ReturnSummaryCopy.needsYourAnswer == "Needs your answer" && ReturnSummaryCopy.questionsTitle == "Needs your answer")
    }

    // MARK: 줄의 보조 글 · 최근 서로 다른 셋 (D-6)

    /// `Next: review the result`는 실제 결과에 도달할 길이 없어서(지금은 All work 행 이동뿐) 어디에도 만들지 않는다
    @Test func needsYourAnswerLeadsThenChangesAndNoNextLineIsEverMade() {
        let both = Fx.item(1, needsAnswer: true, changes: [Fx.change(.run, "done", detail: "review_failed")])
        #expect(ReturnSummaryCopy.detail(both) == "Needs your answer · Needs revision")
        let result = Fx.item(2, changes: [Fx.change(.run, "done", detail: "agent_done")], next: .reviewResult)
        #expect(ReturnSummaryCopy.detail(result) == "Result ready")
        let draft = Fx.item(5, changes: [Fx.change(.run, "done", detail: "draft_ready")], next: .reviewResult)
        #expect(ReturnSummaryCopy.detail(draft) == "Draft ready")
        let onlyAnswer = Fx.item(3, needsAnswer: true)
        #expect(ReturnSummaryCopy.detail(onlyAnswer) == "Needs your answer")
        #expect(ReturnSummaryCopy.detail(Fx.item(4)) == nil, "말할 것이 없는 줄은 제목만")
        for item in [both, result, draft, onlyAnswer] { #expect(!(ReturnSummaryCopy.detail(item) ?? "").contains("Next")) }
    }

    /// A → B → C → D → A의 최근 서로 다른 셋은 C · D · A다 (처음 등장 순이 아니라 실제 마지막 발생 순)
    @Test func theLatestThreeDistinctPhrasesFollowTheirLastOccurrence() {
        let a = "due_changed", b = "scope_changed", c = "owner_changed", d = "merged"
        func item(_ kinds: [String]) -> ReturnSummaryItem {
            Fx.item(1, changes: kinds.enumerated().map { Fx.change(.actionEvent, $1, at: Double($0)) })
        }
        #expect(ReturnSummaryCopy.detail(item([a, b, c, d, a])) == "Owner changed · Updated from source · Due date changed")
        #expect(ReturnSummaryCopy.detail(item([a, b, c, d])) == "Title changed · Owner changed · Updated from source")
        #expect(ReturnSummaryCopy.detail(item([a, b, a, b, a])) == "Title changed · Due date changed")
        #expect(ReturnSummaryCopy.detail(item([a, b, c])) == "Due date changed · Title changed · Owner changed")
        #expect(ReturnSummaryCopy.detail(item([d, c, b, a, d, c])) == "Due date changed · Updated from source · Owner changed")
    }

    /// 순서는 서버가 준 배열 순서가 아니라 `at`이다: 뒤섞여 와도 같은 결과. 같은 시각이면 배열 순서가 안정된 tie다 (뒤가 더 나중)
    @Test func theOrderComesFromTimeNotFromArrivalAndTiesAreStable() {
        func change(_ kind: String, _ at: Double) -> ReturnSummaryChange { Fx.change(.actionEvent, kind, at: at) }
        let shuffled = Fx.item(1, changes: [change("due_changed", 5), change("merged", 4), change("owner_changed", 3), change("scope_changed", 2), change("due_changed", 1)])
        // 시간 순: due(1) scope(2) owner(3) merged(4) due(5) → 마지막 발생: scope(2) owner(3) merged(4) due(5) → 최근 셋 = owner · merged · due
        #expect(ReturnSummaryCopy.detail(shuffled) == "Owner changed · Updated from source · Due date changed")
        // 같은 시각: 배열의 뒤가 더 나중
        let tie1 = Fx.item(1, changes: [change("due_changed", 1), change("scope_changed", 1)])
        let tie2 = Fx.item(1, changes: [change("scope_changed", 1), change("due_changed", 1)])
        #expect(ReturnSummaryCopy.detail(tie1) == "Due date changed · Title changed")
        #expect(ReturnSummaryCopy.detail(tie2) == "Title changed · Due date changed")
        // 같은 입력은 늘 같은 결과 (호출마다 달라지지 않는다)
        #expect(ReturnSummaryCopy.detail(tie1) == ReturnSummaryCopy.detail(tie1))
    }

    /// 두 토큰이 같은 문구로 합쳐지면 한 문구다 (마지막 발생은 둘 중 나중 것): needs_connection · needs_capability → `Needs a connection`, artifact_created · draft_ready → `Draft ready`
    @Test func tokensThatShareAPhraseMergeIntoOneAndKeepTheLaterOccurrence() {
        let item = Fx.item(1, changes: [
            Fx.change(.run, "done", detail: "needs_connection", at: 1), Fx.change(.actionEvent, "due_changed", at: 2), Fx.change(.run, "done", detail: "needs_capability", at: 3),
        ])
        #expect(ReturnSummaryCopy.detail(item) == "Due date changed · Needs a connection")
        let draft = Fx.item(2, changes: [
            Fx.change(.actionEvent, "artifact_created", at: 1), Fx.change(.actionEvent, "owner_changed", at: 2), Fx.change(.run, "done", detail: "draft_ready", at: 3),
        ])
        #expect(ReturnSummaryCopy.detail(draft) == "Owner changed · Draft ready")
        // 원문 상태가 다르면 다른 문구다 (같은 변화라도 지운 원문은 따로 말한다)
        let states = Fx.item(3, changes: [
            Fx.change(.actionEvent, "scope_changed", sourceState: .available, at: 1), Fx.change(.actionEvent, "scope_changed", sourceState: .deleted, at: 2),
        ])
        #expect(ReturnSummaryCopy.detail(states) == "Title changed · Title changed · Original text deleted")
    }

    /// 해석 못 한 변화는 말이 없다 (줄에는 제목만, 또는 해석된 변화만): 어떤 성공 문구로도 바꾸지 않는다
    @Test func uninterpretableChangesAddNoPhraseToTheRow() {
        let mixed = Fx.item(1, changes: [Fx.change(.actionEvent, "due_changed", at: 1), Fx.change(.actionEvent, "teleported", at: 2), Fx.change(.run, "done", detail: "mystery", at: 3)])
        #expect(ReturnSummaryCopy.detail(mixed) == "Due date changed")
        let only = Fx.item(2, changes: [Fx.change(.run, "done", detail: "mystery")])
        #expect(ReturnSummaryCopy.detail(only) == nil)
    }

    /// 숫자 없음 (디자인 D-12): 줄 글에 개수를 말하는 문구가 없다
    @Test func noCountsAnywhereInTheCopy() {
        let items = (1...12).map { Fx.item($0, title: "Work \($0)", needsAnswer: $0 % 2 == 0, changes: [Fx.change(), Fx.change(.run, "done", detail: "draft_ready")]) }
        let shown = content(Fx.response(items, complete: false, changes: .truncated))!
        let texts = shown.rows.compactMap(\.detail) + shown.notes.map(\.text) + [shown.title]
        for text in texts {
            #expect(text.rangeOfCharacter(from: .decimalDigits) == nil || text.hasPrefix("Since"), "\(text)")
            #expect(!text.localizedCaseInsensitiveContains("others") && !text.localizedCaseInsensitiveContains(" more "), "\(text)")
        }
    }

    // MARK: 무엇을 보이나 · 무엇을 보이지 않나

    @Test func nothingShowsBeforeTheFirstReadOrWhenTheFeatureIsOff() {
        #expect(content(nil) == nil)
    }

    @Test func aFailedFirstReadSaysSoInsteadOfBeingEmpty() {
        let failed = content(nil, readFailed: true)
        #expect(failed?.rows.isEmpty == true && failed?.notes == [.couldNotLoad] && failed?.showsCard == false)
        #expect(failed?.notes.first?.text == "Couldn't load changes" && failed?.notes.first?.offersRetry == true)
        #expect(failed?.canClear == false)
    }

    /// 완전한 빈 응답은 아무것도 그리지 않는다: "변화 없음" 같은 문구는 이 앱 어디에도 없다
    @Test func aCompleteEmptyResponseDrawsNothingAndNothingSaysAllCaughtUp() {
        let empty = Fx.response([])
        #expect(empty.isEmpty)
        #expect(content(empty) == nil)
    }

    @Test func anIncompleteEmptyLookingResponseIsNeverHiddenOrCalledEmpty() {
        let cases: [(ReturnSummaryResponse, [ReturnSummaryContent.Note])] = [
            (Fx.response([], complete: false, changes: .unavailable), [.couldNotLoad]),
            (Fx.response([], complete: false, decisions: .unavailable), [.couldNotLoadQuestions]),
            (Fx.response([], complete: false, changes: .unavailable, decisions: .unavailable), [.couldNotLoad, .couldNotLoadQuestions]),
            (Fx.response([], complete: false, changes: .truncated), [.moreAvailable]),
            (Fx.response([], complete: false, changes: .unknown), [.couldNotLoad]),
            (Fx.response([], complete: false, empty: true), [.couldNotLoad]),
            (Fx.response([], baseline: .unknown), [.couldNotLoad]),
        ]
        for (summary, notes) in cases {
            let shown = content(summary)
            #expect(shown?.notes == notes && shown?.rows.isEmpty == true && shown?.canClear == false, "\(notes)")
        }
    }

    // MARK: D-7 — 해석 못 한 변화 · 정상 잘림 · 결정 읽기 실패를 가른다

    /// 정상 잘림: 더 있다고만 말하고 Clear는 막지 않는다 (보인 작업만 읽음 처리 → 다음 조회가 남은 것을 보인다)
    @Test func normalTruncationSaysMoreAreAvailableAndStillAllowsClear() {
        let rows = [Fx.item(1, changes: [Fx.change()])]
        let truncated = content(Fx.response(rows, complete: false, changes: .truncated))
        #expect(truncated?.notes == [.moreAvailable] && truncated?.canClear == true && truncated?.rows.count == 1)
        #expect(truncated?.notes.first?.text == "More changes are available" && truncated?.notes.first?.offersRetry == false)
    }

    /// 해석 못 한 변화는 보이되(제목 줄은 남는다) Clear를 막는다: 사용자가 보지 못한 변화를 읽음 처리하지 않는다
    @Test func anUninterpretableChangeIsKeptOnScreenAndBlocksClear() {
        let cases: [(String, ReturnSummaryChange)] = [
            ("unknown source", Fx.change(.unknown, "done")),
            ("unknown action_event kind", Fx.change(.actionEvent, "teleported")),
            ("unknown run kind", Fx.change(.run, "exploded")),
            ("unknown run outcome (free string detail)", Fx.change(.run, "done", detail: "mystery")),
            ("unknown message kind", Fx.change(.message, "gossip")),
            ("unknown source_state", Fx.change(.actionEvent, "due_changed", sourceState: .unknown)),
        ]
        for (name, change) in cases {
            #expect(!change.isInterpretable, "\(name)")
            let summary = Fx.response([Fx.item(1, title: "Keep me", changes: [change])])
            #expect(summary.hasUninterpretableChange && !summary.isComplete && !summary.isEmpty, "\(name)")
            let shown = content(summary)
            #expect(shown?.rows.map(\.title) == ["Keep me"], "\(name): 줄은 남는다")
            #expect(shown?.notes == [.couldNotShow] && shown?.notes.first?.text == "Some changes couldn't be shown", "\(name)")
            #expect(shown?.canClear == false, "\(name): Clear 차단")
            #expect(ReturnSummaryPresentation.canClear(summary, isStale: false, cursorSpent: false) == false, "\(name)")
        }
        // 해석된 변화 옆에 해석 못 한 변화가 하나라도 있으면 (표시된 작업의 커서 범위에 든다) 차단
        let mixed = Fx.response([Fx.item(1, changes: [Fx.change()]), Fx.item(2, changes: [Fx.change(.run, "done", detail: "mystery")])])
        #expect(content(mixed)?.canClear == false && content(mixed)?.notes == [.couldNotShow])
    }

    @Test func truncationPlusAnUninterpretableChangeSaysBothAndStillBlocks() {
        let summary = Fx.response([Fx.item(1, changes: [Fx.change(.actionEvent, "teleported")])], complete: false, changes: .truncated)
        let shown = content(summary)
        #expect(shown?.notes == [.couldNotShow, .moreAvailable] && shown?.canClear == false)
    }

    /// 결정(질문) 읽기 실패 · 모르는 결정 종류만으로 안전한 변화의 Clear를 막지 않는다 (미결정과 변화의 상태를 분리)
    @Test func aDecisionProblemAloneNeverBlocksASafeChangeClear() {
        let safe = [Fx.item(1, changes: [Fx.change()])]
        let failed = content(Fx.response(safe, complete: false, decisions: .unavailable))
        #expect(failed?.notes == [.couldNotLoadQuestions] && failed?.canClear == true)
        #expect(failed?.notes.first?.text == "Couldn't load items needing your answer" && failed?.notes.first?.offersRetry == true)
        let unknownSource = content(Fx.response(safe, complete: false, decisions: .unknown))
        #expect(unknownSource?.notes == [.couldNotLoadQuestions] && unknownSource?.canClear == true)
        // 모르는 결정 종류: 줄은 서버의 needs_answer 그대로 보이고 Clear도 그대로
        let decision = ReturnSummaryDecision(id: "x:1", kind: .unknown, version: "d1", urgent: false)
        let item = ReturnSummaryItem(
            actionID: Fx.id(1), title: "Pricing page", needsAnswer: true, decisions: [decision], changes: [Fx.change()],
            next: ReturnSummaryNext(kind: .answer, decisionKinds: [.unknown]), version: "v1"
        )
        let unknownKind = Fx.response([item])
        #expect(unknownKind.isComplete && !unknownKind.hasUninterpretableChange)
        let shown = content(unknownKind)
        #expect(shown?.notes == [] && shown?.canClear == true && shown?.rows.first?.needsAnswer == true)
    }

    /// 줄의 표시용 상태(status · state · next)를 몰라도 변화의 해석과 상관없다: Clear를 막지 않고 완전성도 해치지 않는다 (마크만 없다)
    @Test func unknownRowMetadataIsNotAnUninterpretableChange() {
        let item = ReturnSummaryItem(
            actionID: Fx.id(1), title: "Pricing page", status: .unknown, state: .unknown, changes: [Fx.change()], next: ReturnSummaryNext(kind: .unknown), version: "v1"
        )
        let summary = Fx.response([item])
        #expect(summary.isComplete && !summary.hasUninterpretableChange)
        let shown = content(summary)
        #expect(shown?.rows[0].progress == nil && shown?.notes == [] && shown?.canClear == true)
    }

    /// 변화 원천의 상태를 모르거나(unknown) 응답 자체가 앞뒤가 맞지 않으면 읽지 못한 것으로 말하고 Clear를 막는다
    @Test func anUnknownChangeSourceStatusIsNotReadAndBlocksClear() {
        let rows = [Fx.item(1, changes: [Fx.change()])]
        let unknown = content(Fx.response(rows, complete: false, changes: .unknown))
        #expect(unknown?.notes == [.couldNotLoad] && unknown?.canClear == false)
        let unavailable = content(Fx.response(rows, complete: false, changes: .unavailable))
        #expect(unavailable?.notes == [.couldNotLoad] && unavailable?.canClear == false)
        let incoherent = content(Fx.response(rows, complete: false))
        #expect(incoherent?.notes == [.couldNotLoad], "원천은 ok인데 complete:false")
        let unknownBaseline = content(Fx.response(rows, baseline: .unknown))
        #expect(unknownBaseline?.notes == [.couldNotLoad] && unknownBaseline?.canClear == false)
    }

    @Test func aStaleListKeepsItsRowsButCannotBeClearedAndSaysItIsStale() {
        let summary = Fx.withChanges
        let fresh = content(summary)
        #expect(fresh?.canClear == true && fresh?.notes == [])
        let stale = content(summary, isStale: true)
        #expect(stale?.rows.count == 2 && stale?.canClear == false && stale?.notes == [.couldNotLoad])
    }

    // MARK: B — 질문만 남은 카드

    /// 읽음 처리할 변화 없이 질문만 있으면(Clear 뒤 또는 처음부터) 같은 카드가 `Needs your answer`가 되고 Clear는 없다
    @Test func whenOnlyQuestionsRemainTheSameCardIsTitledNeedsYourAnswer() {
        let asking = Fx.response([Fx.item(1, title: "Pricing page", needsAnswer: true), Fx.item(2, title: "Launch design", needsAnswer: true)])
        let shown = content(asking)
        #expect(shown?.title == "Needs your answer" && shown?.showsCard == true && shown?.rows.count == 2 && shown?.canClear == false && shown?.notes == [])
        // 기준(Since)이 있어도 · 없어도 · 기준점뿐이어도 같다
        for baseline in [ReturnSummaryBaseline.cleared, .neverCleared, .initialized] {
            #expect(content(Fx.response([Fx.item(1, needsAnswer: true)], since: baseline == .cleared ? -3_600 : nil, baseline: baseline))?.title == "Needs your answer", "\(baseline)")
        }
        // 변화가 하나라도 같이 있으면 지금처럼 Since / Changes + Clear
        let mixed = content(Fx.response([Fx.item(1, needsAnswer: true), Fx.item(2, changes: [Fx.change()])]))
        #expect(mixed?.title == "Since today 08:00" && mixed?.canClear == true)
        let mixedNever = content(Fx.response([Fx.item(1, needsAnswer: true), Fx.item(2, changes: [Fx.change()])], since: nil, baseline: .neverCleared))
        #expect(mixedNever?.title == "Changes")
    }

    @Test func questionsOnlyStaysHonestWhenTheReadIsPartialOrTruncated() {
        let asking = [Fx.item(1, needsAnswer: true)]
        #expect(content(Fx.response(asking, complete: false, changes: .truncated))?.notes == [.moreAvailable])
        #expect(content(Fx.response(asking, complete: false, changes: .truncated))?.title == "Needs your answer")
        #expect(content(Fx.response(asking, cursor: nil, complete: false, changes: .unavailable))?.notes == [.couldNotLoad])
        #expect(content(Fx.response(asking, cursor: nil, complete: false, changes: .unavailable))?.canClear == false)
        #expect(content(Fx.response(asking, complete: false, decisions: .unavailable))?.notes == [.couldNotLoadQuestions])
        // 해석 못 한 변화가 있는 줄은 질문만 남은 것이 아니다 (보이는 변화가 있다)
        let hidden = Fx.response([Fx.item(1, needsAnswer: true, changes: [Fx.change(.actionEvent, "teleported")])])
        #expect(content(hidden)?.title == "Since today 08:00" && content(hidden)?.notes == [.couldNotShow])
    }

    /// 카드는 완전한 빈 상태에서만 사라진다: 질문이 남아 있으면 남고, 읽지 못한 것은 빈 상태가 아니다
    @Test func theCardGoesAwayOnlyOnATrulyCompleteEmptyState() {
        #expect(content(Fx.response([], cursor: "c3.x")) == nil)
        #expect(content(Fx.response([Fx.item(1, needsAnswer: true)])) != nil)
        #expect(content(Fx.response([], complete: false, changes: .unavailable)) != nil)
        #expect(content(Fx.response([], complete: false, decisions: .unavailable)) != nil)
        #expect(content(nil, readFailed: true) != nil)
    }

    // MARK: Clear 가시성 (D-1 유지)

    @Test func clearNeedsAServerCursorAndSomethingToMarkRead() {
        func canClear(_ summary: ReturnSummaryResponse, stale: Bool = false, spent: Bool = false) -> Bool {
            ReturnSummaryPresentation.canClear(summary, isStale: stale, cursorSpent: spent)
        }
        let changed = [Fx.item(1, changes: [Fx.change()])]
        #expect(canClear(Fx.response(changed)))
        #expect(!canClear(Fx.response(changed, cursor: nil)), "커서가 없으면 보이지 않는다")
        #expect(!canClear(Fx.response(changed), stale: true), "다시 읽지 못했다")
        #expect(!canClear(Fx.response(changed), spent: true), "이미 쓴 커서는 다시 보내지 않는다")
        let onlyDecision = Fx.response([Fx.item(1, needsAnswer: true)])
        #expect(!canClear(onlyDecision))
        #expect(content(onlyDecision)?.rows.count == 1)
    }

    /// 서버가 잘린 쪽에도 커서를 주면(P2-C) Clear는 보인다. 잘림 자체로 보이고 숨기지 않는다
    @Test func truncationAloneNeverDecidesClear() {
        let changed = [Fx.item(1, changes: [Fx.change()])]
        let withCursor = Fx.response(changed, complete: false, changes: .truncated)
        let withoutCursor = Fx.response(changed, cursor: nil, complete: false, changes: .truncated)
        #expect(content(withCursor)?.canClear == true && content(withCursor)?.notes == [.moreAvailable])
        #expect(content(withoutCursor)?.canClear == false && content(withoutCursor)?.notes == [.moreAvailable])
    }

    // MARK: 줄

    @Test func rowsFollowTheServersOrderAndCarryOnlyStableFacts() {
        let summary = Fx.response([
            Fx.item(2, title: "B", needsAnswer: true), Fx.item(1, title: "A", state: .done, changes: [Fx.change()]),
            Fx.item(3, title: "C", state: nil, changes: [Fx.change(.actionEvent, "dropped")]),
        ])
        let rows = content(summary)!.rows
        #expect(rows.map(\.title) == ["B", "A", "C"], "순서는 서버가 정한다")
        #expect(rows.map(\.id) == [Fx.id(2), Fx.id(1), Fx.id(3)])
        #expect(rows.map(\.progress) == [.inProgress, .done, nil])
        #expect(rows[0].highlight == "Needs your answer" && rows[1].highlight == nil)
    }

    @Test func rowsThatHaveNowhereToGoAreNotOpenable() {
        let summary = Fx.response([Fx.item(1, changes: [Fx.change()]), Fx.item(2, changes: [Fx.change()])])
        let rows = content(summary, canOpen: { $0 == Fx.id(1) })!.rows
        #expect(rows.map(\.canOpen) == [true, false])
    }

    @Test func theMessageOnlyAccompaniesRows() {
        #expect(content(Fx.withChanges, message: "This changed somewhere else. It's been refreshed.")?.message == "This changed somewhere else. It's been refreshed.")
        let noRows = content(Fx.response([], complete: false, changes: .unavailable), message: "x")
        #expect(noRows?.message == nil)
    }

    /// 어떤 상태에서도 "다 봤다 · 변화 없음" 같은 문구를 만들지 않는다
    @Test func noStateEverProducesAnAllClearSentence() {
        let states: [ReturnSummaryContent?] = [
            content(nil), content(nil, readFailed: true), content(Fx.response([])), content(Fx.withChanges),
            content(Fx.response([], complete: false, changes: .unavailable)), content(Fx.response([], complete: false, changes: .truncated)),
            content(Fx.withChanges, isStale: true), content(Fx.withChanges, isClearing: true, message: "m"),
            content(Fx.response([Fx.item(1, needsAnswer: true)])), content(Fx.response([Fx.item(1, changes: [Fx.change(.actionEvent, "teleported")])])),
        ]
        let banned = ["caught up", "nothing changed", "no changes", "all handled", "all clear", "nothing new", "all done"]
        for state in states.compactMap({ $0 }) {
            let text = ([state.title] + state.rows.compactMap(\.detail) + state.notes.map(\.text) + [state.message ?? ""]).joined(separator: " ").lowercased()
            for phrase in banned { #expect(!text.contains(phrase), "\(phrase)") }
        }
    }
}
