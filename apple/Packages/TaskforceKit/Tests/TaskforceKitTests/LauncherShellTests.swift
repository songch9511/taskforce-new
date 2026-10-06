import Foundation
import Testing
@testable import TaskforceKit

/// Mac 런처 셸 (U1 PR4): 접기 · 범위 · 실패 원문 줄 · 저장본 목록 · 상태 문장 · 원문 열기
struct LauncherShellTests {
    /// Review · In Progress · To Do · Done Today: default All shows every listed item.
    let now = NowResponse(
        now: ListFixture.inProgress.map { RankedAction(action: $0, score: 1, reasons: [], daysUntilDue: nil) }
            + ListFixture.toDo.map { RankedAction(action: $0, score: 1, reasons: [], daysUntilDue: nil) },
        confirmations: ListFixture.reviews,
        weeklyCheck: nil,
        tracksChanges: true
    )

    func sections(_ mode: LauncherInput.Mode = .empty, layout: LauncherContent.Layout = .init(), now: NowResponse? = nil) -> [LauncherSection] {
        LauncherContent.sections(for: mode, now: now ?? self.now, doneToday: ListFixture.done, signedIn: true, layout: layout)
    }

    // MARK: 접기 (M1)

    /// 기본은 전체 항목이며, 설정이 직접 제한하지 않으면 Show More를 만들지 않는다.
    @Test func emptyListShowsAllSectionsByDefault() {
        let list = sections()
        #expect(list.map(\.title) == ["Review", "In Progress", "To Do", "Done Today"])
        #expect(list.map(\.count) == [4, 5, 14, 6])
        #expect(list[0].items.count == 4)
        #expect(list[1].items.count == 5)
        #expect(list[2].items.count == 14)
        #expect(list[3].items.count == 6)
        #expect(!list.flatMap(\.items).contains { if case .showMore = $0 { true } else { false } })
        #expect(!list.flatMap(\.items).contains { if case .command = $0 { true } else { false } })
    }

    /// 설정한 제한은 각 구역에 적용되고 펼치면 나머지를 보인다.
    @Test func explicitCapsShowMoreUntilExpanded() {
        var caps = SectionCaps(displayPreferences: SectionDisplayPreferences(toDo: .five, doneToday: .five))
        caps.expand(.toDo)
        let list = sections(layout: .init(caps: caps))
        #expect(list[0].items.count == 4)
        #expect(list[2].items.count == 14)
        #expect(list[3].items.last == .showMore(.doneToday, hidden: 1))
        #expect(list[3].count == 6)
    }

    @Test func expandingDoneTodayShowsRowsWithoutAnImplicitCollapsedHeader() {
        var caps = SectionCaps(displayPreferences: SectionDisplayPreferences(doneToday: .five))
        caps.expand(.doneToday)
        let list = sections(layout: .init(caps: caps))
        #expect(list[3].title == "Done Today")
        #expect(list[3].items.count == 6)
        #expect(list[3].items.allSatisfy { $0.group == .doneToday })
    }

    /// 서버 기준값(`section_limits`)을 따른다
    @Test func serverLimitsDecideTheFold() {
        let caps = SectionCaps(limits: SectionLimits(review: 1, inProgress: 2, toDo: 20))
        let list = sections(layout: .init(caps: caps))
        #expect(list[0].items.last == .showMore(.review, hidden: 3))
        #expect(list[1].items.last == .showMore(.inProgress, hidden: 3))
        #expect(list[2].items.count == 14)
    }

    /// 회귀 ⑤: 펼친 목록의 할 일 수(Review + In Progress + To Do) = `/now` 개수, 접힌 수 + 보이는 수도 같다
    @Test func expandedTotalEqualsNowCount() {
        let nowCount = now.now.count + now.confirmations.count
        let folded = sections().flatMap(\.items)
        let visible = folded.filter { $0.group != nil && $0.group != .doneToday }.count
        let hidden = folded.reduce(0) { sum, item in
            if case .showMore(_, let hidden) = item { return sum + hidden }
            return sum
        }
        #expect(visible + hidden == nowCount)
        var caps = SectionCaps()
        TaskGroup.allCases.forEach { caps.expand($0) }
        let expanded = sections(layout: .init(caps: caps)).flatMap(\.items)
        #expect(expanded.filter { $0.group != nil && $0.group != .doneToday }.count == nowCount)
    }

    /// 회귀 ⑤: 찾기는 접힌 행도 찾는다 (찾는 동안은 접지 않는다)
    @Test func searchFindsFoldedRows() {
        // 설정으로 To Do를 5개로 제한하면 마지막 행은 숨지만, 찾기 중에는 보인다.
        let capped = SectionCaps(displayPreferences: SectionDisplayPreferences(toDo: .five))
        #expect(!sections(layout: .init(caps: capped)).flatMap(\.items).contains { $0.action?.id == ListFixture.id(34) })
        let found = sections(.query("할 일 34")).flatMap(\.items)
        #expect(found.contains { $0.group == .toDo && $0.action?.id == ListFixture.id(34) })
        #expect(!found.contains { if case .showMore = $0 { true } else { false } })
    }

    // MARK: 범위 (M13)

    /// 범위는 그 구역만, 접지 않는다
    @Test func scopeNarrowsAndUnfolds() {
        let review = sections(layout: .init(scope: .review))
        #expect(review.map(\.title) == ["Review"])
        #expect(review[0].items.count == 4)
        let done = sections(layout: .init(scope: .doneToday))
        #expect(done.map(\.title) == ["Done Today"])
        #expect(done[0].items.count == 6)
        #expect(done[0].count == 6)
    }

    /// Changed Since Last Look: 바뀐 할 일만 서버 순서대로
    @Test func changedScopeKeepsOnlyChangedRows() {
        let list = sections(layout: .init(scope: .changed, changed: ListFixture.changed))
        #expect(list.flatMap(\.items).compactMap(\.action?.id) == [ListFixture.id(2), ListFixture.id(3), ListFixture.id(12), ListFixture.id(30)])
    }

    /// 찾기와 범위가 함께면 둘 다 거른다
    @Test func queryWithinScope() {
        let list = sections(.query("할 일 3"), layout: .init(scope: .review))
        let tasks = list.flatMap(\.items).filter { $0.group != nil }
        #expect(tasks.compactMap(\.action?.id) == [ListFixture.id(3)])
    }

    @Test func handoffQueryResultDoesNotOwnDuplicateInlineDetails() {
        let items = sections(.query("할 일")).flatMap(\.items)
        let handoff = items.first { if case .handoff = $0 { true } else { false } }
        let task = items.first { $0.action?.id == handoff?.action?.id && $0.group != nil }

        #expect(handoff?.inlineDetailActionID == nil)
        #expect(task?.inlineDetailActionID == handoff?.action?.id)
    }

    // MARK: 실패 원문 줄 (W4)

    @Test func failedSourcesLineOnTopOnlyWhenSomethingFailed() {
        let failed = FailedSources(count: 2, latestAt: nil, reason: .aiTimeout)
        let list = sections(layout: .init(failedSources: failed))
        #expect(list.first?.items == [.failedSources(failed)])
        #expect(sections(layout: .init(failedSources: .empty)).first?.title == "Review")
        // 예전 모양(layout 없음)에는 줄이 없다
        let legacy = LauncherContent.sections(for: .empty, now: now, signedIn: true)
        #expect(!legacy.flatMap(\.items).contains { if case .failedSources = $0 { true } else { false } })
    }

    // MARK: 저장본 목록 (M15 · M19)

    var saved: SavedNow {
        SavedNow(sections: ListFixture.sections, savedAt: Date(timeIntervalSince1970: 1_791_000_000))
    }

    /// 저장본도 같은 기본 전체 표시 규칙, 행은 읽기만 하는 저장본 줄
    @Test func savedListFoldsLikeTheLiveList() {
        let list = LauncherContent.savedSections(saved, for: .empty, layout: .init(), now: saved.savedAt)
        #expect(list.map(\.title) == ["Review", "In Progress", "To Do", "Done Today"])
        #expect(list.map(\.count) == [4, 5, 14, 6])
        guard case .saved(let first) = list[0].items[0] else {
            Issue.record("저장본 줄이어야 함")
            return
        }
        #expect(first.task.title == "할 일 1")
        #expect(list[3].items.count == 6)
        #expect(list.flatMap(\.items).allSatisfy { $0.action == nil && $0.group == nil })
    }

    /// 저장본 찾기는 저장된 제목으로만 거르고, 물어보기 · 추가는 없다 (서버가 필요). 맞는 명령은 찾는다
    @Test func savedSearchFiltersTitlesWithoutAskOrAdd() {
        let list = LauncherContent.savedSections(saved, for: .query("할 일 34"), layout: .init(), now: saved.savedAt)
        let items = list.flatMap(\.items)
        #expect(items.count == 1)
        guard case .saved(let row)? = items.first else {
            Issue.record("저장본 줄이어야 함")
            return
        }
        #expect(row.task.title == "할 일 34")
        let commands = LauncherContent.savedSections(saved, for: .query("Settings"), layout: .init(), now: saved.savedAt).flatMap(\.items)
        #expect(commands == [.command(.settings)])
    }

    /// 어제 저장한 Done Today는 보이지 않는다, 바뀜 범위는 비어 있다
    @Test func savedListDropsYesterdaysDoneAndChangedScope() {
        let nextDay = saved.savedAt.addingTimeInterval(86_400 * 2)
        let list = LauncherContent.savedSections(saved, for: .empty, layout: .init(), now: nextDay)
        #expect(list.map(\.title) == ["Review", "In Progress", "To Do"])
        #expect(LauncherContent.savedSections(saved, for: .empty, layout: .init(scope: .changed), now: saved.savedAt).isEmpty)
    }

    // MARK: 액션 바 상태 문장 (M15 · M19 · M20)

    @Test func statusTextMatchesFigma() throws {
        let zone = try #require(TimeZone(identifier: "Asia/Seoul"))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        func at(_ hour: Int, _ minute: Int) -> Date {
            calendar.date(from: DateComponents(year: 2026, month: 10, day: 1, hour: hour, minute: minute))!
        }
        #expect(RefreshState.offlineEmpty(since: at(8, 1)).statusText(timeZone: zone) == "Offline since 8:01.")
        #expect(RefreshState.offlineSaved(since: at(10, 41), savedAt: at(10, 31)).statusText(timeZone: zone) == "Offline since 10:41. Showing saved tasks.")
        #expect(RefreshState.refreshFailed(at: at(10, 46), savedAt: at(10, 31)).statusText(timeZone: zone) == "Couldn’t refresh at 10:46. Showing 10:31.")
        #expect(RefreshState.refreshFailed(at: at(10, 46), savedAt: nil).statusText(timeZone: zone) == "Couldn’t refresh at 10:46.")
        #expect(RefreshState.live.statusText(timeZone: zone) == nil)
        #expect(RefreshState.loading.statusText(timeZone: zone) == nil)
    }

    // MARK: 원문 열기 (↩ `Open in <서비스>`)

    private func line(_ day: Int, url: String?, service: SourceService, quote: String = "구절") -> EvidenceLine {
        EvidenceLine(
            id: ListFixture.id(900 + day), quote: quote, sourceID: ListFixture.id(800 + day), sourceTitle: "원문",
            occurredAt: Date(timeIntervalSince1970: TimeInterval(day) * 86_400), externalURL: url.flatMap(URL.init(string:)), service: service
        )
    }

    /// 맨 앞 근거(가장 최근)에 링크가 있으면 그것, 없으면 링크가 있는 가장 최근 줄, 없으면 nil
    @Test func openLinkPrefersTheLeadThenTheLatestLinkedLine() {
        let notion = line(1, url: "https://www.notion.so/a", service: .notion)
        let slack = line(2, url: "https://acme.slack.com/b", service: .slack)
        let pasted = line(3, url: nil, service: .manual(.note))
        #expect(EvidenceDigest(lines: [notion, slack]).openLink == slack)
        #expect(EvidenceDigest(lines: [notion, slack, pasted]).openLink == slack)
        #expect(EvidenceDigest(lines: [pasted]).openLink == nil)
        #expect(EvidenceDigest(lines: []).openLink == nil)
    }

    @Test func openTitlesNameTheService() {
        #expect(SourceService.notion.openTitle == "Open in Notion")
        #expect(SourceService.slack.openTitle == "Open in Slack")
        #expect(SourceService.gmail.openTitle == "Open in Gmail")
        #expect(SourceService.googleMeet.openTitle == "Open in Google Docs")
        #expect(SourceService.manual(.doc).openTitle == "Open Link")
    }
}

/// 앱을 열 때의 저장본 정리: 지금 계정만 남긴다
struct SavedNowPruneTests {
    @Test func removeAllExceptKeepsOnlyTheCurrentAccount() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "SavedNowPrune-\(UUID().uuidString)", directoryHint: .isDirectory)
        let store = SavedNowStore(root: root)
        defer { try? store.removeAll() }
        let (alice, bob, carol) = (UUID(), UUID(), UUID())
        let copy = SavedNow(sections: ListFixture.sections, savedAt: Date(timeIntervalSince1970: 1_791_000_000))
        for account in [alice, bob, carol] { try store.save(copy, account: account) }
        try store.removeAll(except: bob)
        #expect(store.load(account: alice) == nil)
        #expect(store.load(account: carol) == nil)
        #expect(store.load(account: bob) == copy)
    }

    @Test func removeAllExceptWithoutAnySavedCopyIsFine() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "SavedNowPrune-\(UUID().uuidString)", directoryHint: .isDirectory)
        try SavedNowStore(root: root).removeAll(except: UUID())
    }

    /// 앱을 열 때 (Mac `LauncherModel` · iPhone `RootView`): 로그인해 있으면 그 계정만, 로그아웃이면 모두 지운다
    @Test func pruneKeepsTheSignedInAccountOrNothing() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "SavedNowPrune-\(UUID().uuidString)", directoryHint: .isDirectory)
        let store = SavedNowStore(root: root)
        defer { try? store.removeAll() }
        let (alice, bob) = (UUID(), UUID())
        let copy = SavedNow(sections: ListFixture.sections, savedAt: Date(timeIntervalSince1970: 1_791_000_000))
        for account in [alice, bob] { try store.save(copy, account: account) }
        try store.prune(keeping: bob)
        #expect(store.load(account: alice) == nil)
        #expect(store.load(account: bob) == copy)
        try store.prune(keeping: nil)
        #expect(store.load(account: bob) == nil)
        // 지울 것이 없어도 성공
        try store.prune(keeping: nil)
        try store.prune(keeping: alice)
    }
}
