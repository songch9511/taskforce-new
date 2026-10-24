#if os(macOS)
import Foundation
import Testing
@testable import TaskforceKit

/// 기록의 `subagents/agent-<id>.meta.json` 해석과, 그 값이 일 목록에 들어가는 규칙 (T1, 검토 뒤 계약 5장).
/// 선언한 칸 다섯만 읽는다: `parentAgentId` · `spawnDepth` · `description` · `requestShape` · `toolUseId`. 모르는 칸은 무시하고, 깨진 파일은 그 파일만 버린다.
/// 메타는 **상태를 정하지 않는다**: 깊이 1 전경 에이전트의 상태는 메타의 `toolUseId`와 같은 id의 도구 호출 · 결과(본 기록)로 정하고(결과 전 Running, 결과 뒤 Done/Failed), 상태를 모르는 에이전트(깊이 2 이상 · 짝지을 수 없는 것)는
/// **부모가 목록에 있을 때만** 그 아래에 상태 낱말 없이 보인다. 부모가 없으면 줄을 만들지 않는다 (이미 아는 일의 부모 · 깊이 · 이름 채우기에만 쓴다)
struct SubagentMetaTests {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

    private func parse(_ json: String, id: String = "a1111111111111111") -> SubagentMeta? {
        SubagentMeta.parse(Data(json.utf8), id: id)
    }

    private func meta(_ id: String, parent: String? = nil, depth: Int? = 1, name: String? = "Check a note", tool: String? = nil) -> SubagentMeta {
        SubagentMeta(id: id, parentID: parent, depth: depth, name: name, requestShape: nil, toolUseID: tool)
    }

    private func task(_ list: BackgroundTaskList, _ id: String) -> BackgroundTask? { list.tasks.first { $0.id == id } }

    /// 본 기록이 시작 줄로 아는 백그라운드 에이전트 (Running)
    private func listWithBackgroundAgent(_ id: String = "bg1", depth: Int? = nil) -> BackgroundTaskList {
        var list = BackgroundTaskList()
        list.apply(.started(taskID: id, toolUseID: "tu-\(id)", kind: .agent, name: "Background agent", at: at(1), parentID: nil, depth: depth, foreground: false))
        return list
    }

    private func called(at seconds: TimeInterval? = 5, outcome: AgentCallRecord.Outcome? = nil) -> AgentCallRecord {
        AgentCallRecord(called: true, startedAt: seconds.map(at), outcome: outcome)
    }

    // MARK: 해석

    @Test func aMetaFileGivesTheFiveDeclaredFieldsAndIgnoresTheRest() {
        let json = """
        {"agentType":"general-purpose","description":"Check a nested note","model":"fixture-model","parentAgentId":"a2222222222222222","requestNonInteractive":false,
         "requestShape":"requested.unset","spawnDepth":2,"toolUseId":"toolu_fixture","finished":true,"worktreePath":"/not/read","effort":"high","unknownField":{"nested":[1,2,3]}}
        """
        let found = parse(json)
        #expect(found == SubagentMeta(id: "a1111111111111111", parentID: "a2222222222222222", depth: 2, name: "Check a nested note", requestShape: "requested.unset", toolUseID: "toolu_fixture"))
    }

    @Test func aTopLevelChildHasNoParentAndKeepsItsDepth() {
        let found = parse(#"{"description":"Check a note","spawnDepth":1}"#)
        #expect(found?.parentID == nil && found?.depth == 1 && found?.name == "Check a note" && found?.requestShape == nil && found?.toolUseID == nil)
    }

    @Test func theToolUseIdFollowsTheToolCallIdRuleOrIsDropped() {
        #expect(parse(#"{"toolUseId":"toolu_01AbC-xyz"}"#)?.toolUseID == "toolu_01AbC-xyz")
        #expect(parse(#"{"toolUseId":"\#(String(repeating: "t", count: 128))"}"#)?.toolUseID != nil)
        for value in ["\"\"", "\"\(String(repeating: "t", count: 129))\"", "7", "null", "true", "{}", "[\"a\"]"] {
            #expect(parse(#"{"toolUseId":\#(value),"spawnDepth":1}"#)?.toolUseID == nil, "\(value.prefix(20))")
        }
        #expect(parse(#"{"toolUseId":"toolu_x","spawnDepth":99}"#)?.toolUseID == "toolu_x", "다른 칸이 틀려도 이 칸은 남는다")
    }

    @Test func eachFieldIsCheckedOnItsOwnAndABadOneIsDroppedWithoutLosingTheOthers() {
        let found = parse(#"{"parentAgentId":"../x","spawnDepth":99,"description":"Still named","requestShape":"has space"}"#)
        #expect(found?.parentID == nil, "id 규칙(영숫자 · _ · - 64자)을 어긴 부모는 믿지 않는다")
        #expect(found?.depth == nil, "0–16 밖")
        #expect(found?.requestShape == nil)
        #expect(found?.name == "Still named")
        for depth in ["-1", "17", "1.5", "\"2\"", "true", "null", "[2]"] {
            #expect(parse(#"{"spawnDepth":\#(depth),"description":"x"}"#)?.depth == nil, "\(depth)")
        }
        #expect(parse(#"{"spawnDepth":0}"#)?.depth == 0 && parse(#"{"spawnDepth":16}"#)?.depth == 16)
        for parent in ["\"\"", "7", "null", "{}", "\"a b\"", "\"\(String(repeating: "z", count: 65))\""] {
            #expect(parse(#"{"parentAgentId":\#(parent),"spawnDepth":2}"#)?.parentID == nil, "\(parent)")
        }
        #expect(parse(#"{"description":7}"#)?.name == nil && parse(#"{"description":"   "}"#)?.name == nil)
    }

    @Test func aFileThatIsNotAJsonObjectIsDiscarded() {
        for text in ["", "not json", "[]", "[{\"spawnDepth\":1}]", "\"string\"", "42", "null", "{", #"{"spawnDepth":1"#, "\u{0}"] {
            #expect(parse(text) == nil, "\(text.debugDescription)")
        }
        #expect(SubagentMeta.parse(Data([0xFF, 0xFE, 0x7B, 0x7D]), id: "a1") == nil, "UTF-8이 아니다")
    }

    @Test func aFileOverFourKilobytesIsDiscardedWhateverItSays() {
        let padding = String(repeating: "x", count: SubagentMeta.maxBytes)
        #expect(parse(#"{"description":"big","spawnDepth":1,"pad":"\#(padding)"}"#) == nil)
        let fits = String(repeating: "x", count: SubagentMeta.maxBytes - 80)
        #expect(parse(#"{"description":"fits","spawnDepth":1,"pad":"\#(fits)"}"#)?.name == "fits")
    }

    @Test func theIdComesFromTheFileNameAndATextualIdInsideNeverReplacesIt() {
        let found = parse(#"{"agentId":"a9999999999999999","description":"x","spawnDepth":1}"#, id: "a1111111111111111")
        #expect(found?.id == "a1111111111111111")
        #expect(parse(#"{"description":"x"}"#, id: "../x") == nil, "id 규칙을 어긴 이름은 해석하지 않는다")
    }

    @Test func aLongDescriptionIsCappedAtFourHundredCharacters() {
        let found = parse(#"{"description":"\#(String(repeating: "d", count: 3000))"}"#)
        #expect((found?.name?.count ?? 0) <= 400)
    }

    @Test func requestShapeIsAShortTokenOrNothing() {
        #expect(parse(#"{"requestShape":"requested.unset"}"#)?.requestShape == "requested.unset")
        #expect(parse(#"{"requestShape":"\#(String(repeating: "r", count: 65))"}"#)?.requestShape == nil)
        #expect(parse(#"{"requestShape":"line\nbreak"}"#)?.requestShape == nil)
        #expect(parse(#"{"requestShape":{"a":1}}"#)?.requestShape == nil)
    }

    @Test func theValueNeverPrintsItsNameOrIds() {
        let found = meta("a1111111111111111", parent: "a2222222222222222", depth: 2, name: "A private name", tool: "toolu_private")
        let dump = String(reflecting: found) + String(describing: found)
        #expect(!dump.contains("private") && !dump.contains("a1111111111111111") && !dump.contains("a2222222222222222"))
    }

    // MARK: 메타만 있으면 줄도 띠도 없다

    @Test func aListOfMetasAloneMakesNoTaskAndSoNoStrip() {
        let metas = [meta("a1", tool: "tu1"), meta("a2", tool: "tu2"), meta("n1", parent: "a1", depth: 2), meta("n2", parent: "ghost", depth: 2), meta("x", tool: nil)]
        let tasks = BackgroundTaskList().adding(subagents: metas)
        #expect(tasks.tasks.isEmpty, "본 기록이 아무것도 모르면 메타만으로 줄을 만들지 않는다: 호출 · 결과도 없고 부모도 목록에 없다")
        #expect(tasks.stripStatus == nil && !BackgroundTaskVisibility.isVisible(tasks: tasks.tasks, openedAt: nil))
    }

    // MARK: 깊이 1 전경 에이전트: 본 기록의 짝으로

    @Test func aDepthOneAgentWhoseCallWasSeenRunsUntilItsResultArrives() throws {
        let tasks = BackgroundTaskList().adding(subagents: [meta("a1", depth: 1, name: "Review the copy", tool: "tu1")], calls: ["tu1": called(at: 5)])
        let found = try #require(task(tasks, "a1"))
        #expect(found.status == .running && found.startedAt == at(5) && found.endedAt == nil && found.kind == .agent && found.name == "Review the copy")
        #expect(found.parentID == nil && found.depth == 1 && found.foreground && !found.statusUnknown)
        #expect(tasks.stripStatus == .running && tasks.runningCount == 1)
        #expect(found.meta(now: at(35)) == "Agent · Running · 0:30", "도는 동안 시계가 간다")
    }

    @Test func aResultEndsItDoneOrFailedAtTheTimeOfTheResultLine() throws {
        let metas = [meta("a1", depth: 1, name: "Fine", tool: "tu1"), meta("a2", depth: 1, name: "Broken", tool: "tu2")]
        let calls = [
            "tu1": called(at: 5, outcome: .init(failed: false, at: at(40))),
            "tu2": called(at: 6, outcome: .init(failed: true, at: at(50))),
        ]
        let tasks = BackgroundTaskList().adding(subagents: metas, calls: calls)
        let done = try #require(task(tasks, "a1"))
        let failed = try #require(task(tasks, "a2"))
        #expect(done.status == .done && done.endedAt == at(40) && done.duration == 35 && done.exitCode == nil)
        #expect(failed.status == .failed && failed.endedAt == at(50) && failed.duration == 44)
        #expect(tasks.runningCount == 0)
    }

    @Test func aResultAloneStillEndsItWhenTheCallLineIsOutsideTheWindowThatWasRead() throws {
        let calls = ["tu1": AgentCallRecord(called: false, startedAt: nil, outcome: .init(failed: false, at: at(40)))]
        let found = try #require(task(BackgroundTaskList().adding(subagents: [meta("a1", tool: "tu1")], calls: calls), "a1"))
        #expect(found.status == .done && found.startedAt == nil && found.duration == nil, "시작 시각을 모르면 걸린 시간을 지어내지 않는다")
    }

    @Test func anAgentWhoseCallAndResultWereBothNotSeenIsUnknownSoItHasNoLine() {
        // 오래전에 끝난 에이전트: 읽은 창 밖이다. 도는 중이라고 하지 않는다
        #expect(BackgroundTaskList().adding(subagents: [meta("old", tool: "tu-old")], calls: ["other": called()]).tasks.isEmpty)
        #expect(BackgroundTaskList().adding(subagents: [meta("old", tool: "tu-old")], calls: [:]).tasks.isEmpty)
    }

    @Test func aMetaWithoutAToolUseIdCannotBePairedAndAnythingButDepthOneIsNotPaired() {
        let calls = ["tu1": called()]
        #expect(BackgroundTaskList().adding(subagents: [meta("a1", depth: 1, tool: nil)], calls: calls).tasks.isEmpty)
        // 깊이 2의 메타는 부모가 목록에 없으면 줄이 없다 (같은 id의 호출이 우연히 본 기록에 있어도 짝짓지 않는다)
        #expect(BackgroundTaskList().adding(subagents: [meta("n1", parent: "ghost", depth: 2, tool: "tu1")], calls: calls).tasks.isEmpty)
        // 부모가 있으면 상태 없이 보인다
        let under = listWithBackgroundAgent("bg1").adding(subagents: [meta("n1", parent: "bg1", depth: 2, tool: "tu1")], calls: calls)
        #expect(task(under, "n1")?.statusUnknown == true && task(under, "n1")?.foreground == false)
    }

    @Test func anAgentTheTranscriptAlreadyKnowsIsNeverPairedAgainAndKeepsItsStatus() {
        // 백그라운드 에이전트: 본 기록의 시작 줄이 아는 일. 호출 · 결과가 있어도 상태는 끝 알림이 정한다 (비동기 시작 결과는 끝이 아니다)
        var list = listWithBackgroundAgent("bg1", depth: 1)
        list.apply(.finished(taskID: "bg1", kind: .agent, status: .failed, exitCode: nil, at: at(30)))
        let merged = list.adding(subagents: [meta("bg1", depth: 1, name: "Other name", tool: "tu-bg1")], calls: ["tu-bg1": called(outcome: .init(failed: false, at: at(99)))])
        #expect(task(merged, "bg1")?.status == .failed && task(merged, "bg1")?.endedAt == at(30))
        #expect(merged.tasks.count == 1)
    }

    // MARK: 상태를 모르는 에이전트: 부모 아래에만, 상태 낱말 없이

    @Test func anAgentOfUnknownStatusShowsOnlyUnderAParentThatIsInTheListAndGrandchildrenFollowInAnyOrder() throws {
        // 손자(깊이 3)가 자식(깊이 2)보다 먼저 와도 부모 사슬이 이어지면 모두 보인다
        let metas = [meta("g1", parent: "c1", depth: 3, name: "Grandchild"), meta("c1", parent: "bg1", depth: 2, name: "Child"), meta("lost", parent: "ghost", depth: 2, name: "Lost")]
        let tasks = listWithBackgroundAgent("bg1").adding(subagents: metas)
        let child = try #require(task(tasks, "c1"))
        let grand = try #require(task(tasks, "g1"))
        #expect(child.parentID == "bg1" && child.depth == 2 && child.kind == .agent && child.name == "Child" && child.statusUnknown)
        #expect(grand.parentID == "c1" && grand.depth == 3 && grand.statusUnknown)
        #expect(task(tasks, "lost") == nil, "부모가 목록에 없으면 줄이 없다")
        #expect(SubagentTree.rows(for: tasks, expansion: SubagentTreeExpansion(visibleLevels: 100)).map(\.task.id) == ["bg1", "c1", "g1"])
    }

    @Test func aLineWithoutAStatusShowsNoStatusWordAndTheNameCarriesNoStatus() throws {
        let tasks = listWithBackgroundAgent("bg1").adding(subagents: [meta("c1", parent: "bg1", depth: 2, name: "Child")])
        let child = try #require(task(tasks, "c1"))
        #expect(child.meta(now: at(100)) == "Agent", "상태 낱말 · 시간이 없다: 빈칸이 곧 모름")
        #expect(child.accessibleName(now: at(100)) == "Agent, Child")
        for word in [SessionViewCopy.running, SessionViewCopy.done, SessionViewCopy.failed, SessionViewCopy.stopped] { #expect(!child.meta(now: at(100)).contains(word)) }
    }

    @Test func linesWithoutAStatusAreLeftOutOfTheStripStatusTheCountsAndTheVisibility() {
        var done = BackgroundTaskList()
        done.apply(.started(taskID: "p", toolUseID: nil, kind: .agent, name: "Parent", at: at(1)))
        done.apply(.finished(taskID: "p", kind: .agent, status: .done, exitCode: nil, at: at(10)))
        let withUnknown = done.adding(subagents: [meta("c1", parent: "p", depth: 2), meta("c2", parent: "p", depth: 2)])
        #expect(withUnknown.tasks.count == 3)
        #expect(withUnknown.stripStatus == .done, "상태 없는 줄이 Stopped로 세어지지 않는다")
        #expect(withUnknown.runningCount == 0 && withUnknown.accessibleName == done.accessibleName)
        // 보이기: 상태 없는 줄만으로는 보이지 않는다 (열어 본 시각이 없어도)
        let unknownOnly = withUnknown.tasks.filter(\.statusUnknown)
        #expect(unknownOnly.count == 2 && !BackgroundTaskVisibility.isVisible(tasks: unknownOnly, openedAt: nil) && !BackgroundTaskVisibility.isVisible(tasks: unknownOnly, openedAt: at(0)))
        // 막 끝난 부모가 있으면 지금처럼 보인다
        #expect(BackgroundTaskVisibility.isVisible(tasks: withUnknown.tasks, openedAt: at(5)) == BackgroundTaskVisibility.isVisible(tasks: done.tasks, openedAt: at(5)))
        // 도는 일이 있으면 Running
        let running = listWithBackgroundAgent("bg1").adding(subagents: [meta("c1", parent: "bg1", depth: 2)])
        #expect(running.stripStatus == .running && running.accessibleName == "Background tasks, 1 running")
    }

    @Test func aTaskThatReallyStoppedIsNeverTakenForOneWithoutAStatus() {
        var list = BackgroundTaskList()
        list.apply(.started(taskID: "a", toolUseID: nil, kind: .command, name: nil, at: at(1)))
        list.apply(.started(taskID: "b", toolUseID: nil, kind: .command, name: nil, at: at(2)))
        list.apply(.started(taskID: "c", toolUseID: nil, kind: .command, name: nil, at: at(3)))
        list.apply(.started(taskID: "d", toolUseID: nil, kind: .agent, name: nil, at: at(4), parentID: nil, depth: 1, foreground: true))
        list.apply(.snapshot(runningTaskIDs: ["b", "c", "d"]), now: at(10))
        list.apply(.finished(taskID: "b", kind: .command, status: .stopped, exitCode: nil, at: nil), now: at(11))
        list.stopRunning(["c"], now: at(12))
        list.apply(.finished(taskID: "z", kind: .agent, status: .stopped, exitCode: nil, at: nil), now: at(13))
        let closed = list.closed(at: at(20))
        for item in closed.tasks { #expect(item.status == .stopped && item.endedAt != nil && !item.statusUnknown, "\(item.id)") }
        #expect(closed.tasks.count == 5)
    }

    @Test func aLineWithoutAStatusTakesTheStatusOfARealEndEventWhenOneComes() throws {
        var tasks = listWithBackgroundAgent("bg1").adding(subagents: [meta("c1", parent: "bg1", depth: 2)])
        #expect(task(tasks, "c1")?.statusUnknown == true)
        tasks.apply(.finished(taskID: "c1", kind: .agent, status: .failed, exitCode: nil, at: at(50)), now: at(60))
        let ended = try #require(task(tasks, "c1"))
        #expect(!ended.statusUnknown && ended.status == .failed && ended.endedAt == at(50) && ended.parentID == "bg1")
        // 시작 줄이 늦게 와도 상태를 모르는 줄을 되살리지 않는다
        tasks.apply(.started(taskID: "c1", toolUseID: nil, kind: .agent, name: nil, at: at(5)))
        #expect(task(tasks, "c1")?.status == .failed && task(tasks, "c1")?.statusUnknown == false)
    }

    @Test func aStoppedTaskWithoutAnEndTimeThatSomeoneBuiltByHandIsStillJustStopped() {
        // 이전(V1)부터 있던 값: 끝 시각 없는 끝난 일은 "상태를 모름"이 아니다
        let stopped = BackgroundTask(id: "a", kind: .command, name: nil, status: .stopped)
        #expect(!stopped.statusUnknown && stopped.meta(now: at(5)) == "Command · Stopped")
    }

    @Test func linesWithoutAStatusKeepTheNewestFirstOrderTheReaderGaveThem() {
        let tasks = listWithBackgroundAgent("bg1").adding(subagents: [meta("c3", parent: "bg1", depth: 2), meta("c2", parent: "bg1", depth: 2), meta("c1", parent: "bg1", depth: 2)])
        #expect(SubagentTree.rows(for: tasks, expansion: SubagentTreeExpansion()).map(\.task.id) == ["bg1", "c3", "c2", "c1"])
    }

    @Test func aBranchSummaryNeverCountsLinesWithoutAStatus() {
        let tasks = listWithBackgroundAgent("bg1").adding(subagents: [meta("c1", parent: "bg1", depth: 2), meta("g1", parent: "c1", depth: 3)])
        var collapsed = SubagentTreeExpansion()
        collapsed.toggle(id: "bg1", level: 0)
        #expect(SubagentTree.rows(for: tasks, expansion: collapsed).first?.branchSummary == nil, "상태 없는 줄은 도는 일도 실패도 아니다")
    }

    // MARK: 이미 아는 일에는 채우기만

    @Test func anAgentTheTranscriptAlreadyKnowsKeepsItsStatusAndOnlyGainsWhatItLacked() {
        var tasks = BackgroundTaskList()
        tasks.apply(.started(taskID: "a1", toolUseID: "tu", kind: .agent, name: nil, at: at(5)))
        tasks.apply(.started(taskID: "a2", toolUseID: "tu2", kind: .agent, name: "Named by the transcript", at: at(6)))
        tasks.apply(.finished(taskID: "a2", kind: .agent, status: .done, exitCode: nil, at: at(30)))
        let merged = tasks.adding(subagents: [meta("a1", parent: "p1", depth: 2, name: "From the meta"), meta("a2", parent: "p2", depth: 3, name: "From the meta too")])
        #expect(task(merged, "a1")?.status == .running && task(merged, "a1")?.name == "From the meta" && task(merged, "a1")?.parentID == "p1" && task(merged, "a1")?.depth == 2)
        #expect(task(merged, "a2")?.status == .done && task(merged, "a2")?.endedAt == at(30), "끝 알림이 정한 상태는 메타가 바꾸지 않는다")
        #expect(task(merged, "a2")?.name == "Named by the transcript", "아는 이름은 지킨다")
        #expect(task(merged, "a2")?.parentID == "p2")
    }

    @Test func theMetaNameGoesThroughTheSameTitleRulesAsEveryOtherName() {
        let dirty = "  Check\u{202E} the \n\t note\u{200B} " + String(repeating: "d", count: 400)
        let tasks = listWithBackgroundAgent("bg1").adding(subagents: [meta("a1", parent: "bg1", depth: 2, name: dirty), meta("a2", parent: "bg1", depth: 2, name: nil)])
        let name = task(tasks, "a1")?.name ?? ""
        #expect(name.hasPrefix("Check the note ") && !name.contains("\u{202E}") && !name.contains("\n") && name.utf16.count <= ExternalSessionRules.maxTitleUTF16)
        #expect(task(tasks, "a2")?.title == "Agent", "이름이 없으면 도구 이름")
    }

    @Test func addingTheSameMetasAgainChangesNothingAndNoMoreThanTwoHundredFiftySixTasksExist() {
        let metas = (0..<(BackgroundTaskList.maxTasks + 40)).map { meta("a\($0)", name: "Note \($0)", tool: "tu\($0)") }
        let calls = Dictionary(uniqueKeysWithValues: (0..<(BackgroundTaskList.maxTasks + 40)).map { ("tu\($0)", called(at: TimeInterval($0))) })
        let once = BackgroundTaskList().adding(subagents: metas, calls: calls)
        #expect(once.tasks.count == BackgroundTaskList.maxTasks)
        #expect(once.adding(subagents: metas, calls: calls) == once)
    }

    @Test func aMetaOnlyAgentNeverEvictsATaskTheTranscriptOrTheStreamAlreadyHolds() {
        var full = BackgroundTaskList()
        for index in 0..<BackgroundTaskList.maxTasks { full.apply(.started(taskID: "t\(index)", toolUseID: nil, kind: .command, name: nil, at: at(Double(index)))) }
        #expect(full.adding(subagents: [meta("newcomer", tool: "tu")], calls: ["tu": called()]) == full)
        #expect(full.adding(subagents: [meta("child", parent: "t1", depth: 2)]) == full)
    }

    // MARK: 부모 채우기 규칙 (검토 지적 5)

    @Test func aParentIsNeverFilledOntoATaskTheStreamReportedAtDepthOneWithNoParent() {
        var board = BackgroundTaskList()
        board.apply(.started(taskID: "top", toolUseID: nil, kind: .agent, name: "Top", at: at(1), parentID: nil, depth: 1, foreground: false))
        // 스트림 쪽 늦은 시작 줄 · 메타 · 판과 기록 합치기, 어느 길로도 깊이 1의 일에 부모가 붙지 않는다
        board.apply(.started(taskID: "top", toolUseID: nil, kind: .agent, name: nil, at: at(2), parentID: "intruder", depth: nil, foreground: false))
        #expect(task(board, "top")?.parentID == nil && task(board, "top")?.depth == 1)
        let withMeta = board.adding(subagents: [meta("top", parent: "intruder", depth: 2)])
        #expect(task(withMeta, "top")?.parentID == nil && task(withMeta, "top")?.depth == 1)
        var other = BackgroundTaskList()
        other.apply(.started(taskID: "top", toolUseID: nil, kind: .agent, name: "Top", at: at(1), parentID: "intruder", depth: 2, foreground: false))
        #expect(task(board.merged(with: other), "top")?.parentID == nil, "합쳐도 같다")
    }

    @Test func aParentIsFilledWhenTheDepthIsUnknownOrTwoOrMoreAndNeverOverwritten() {
        var list = BackgroundTaskList()
        list.apply(.started(taskID: "snap", toolUseID: nil, kind: .agent, name: nil, at: at(1)))
        list.apply(.started(taskID: "two", toolUseID: nil, kind: .agent, name: nil, at: at(2), parentID: nil, depth: 2, foreground: false))
        list.apply(.started(taskID: "has", toolUseID: nil, kind: .agent, name: nil, at: at(3), parentID: "mine", depth: 2, foreground: false))
        let filled = list.adding(subagents: [meta("snap", parent: "p", depth: 2), meta("two", parent: "p", depth: 2), meta("has", parent: "other", depth: 2)])
        #expect(task(filled, "snap")?.parentID == "p" && task(filled, "snap")?.depth == 2, "깊이를 모르는 일은 부모와 깊이를 함께 채운다")
        #expect(task(filled, "two")?.parentID == "p")
        #expect(task(filled, "has")?.parentID == "mine")
        // 늦은 스트림 시작 줄도 같다
        var late = list
        late.apply(.started(taskID: "snap", toolUseID: nil, kind: .agent, name: nil, at: at(9), parentID: "q", depth: 2, foreground: false))
        #expect(task(late, "snap")?.parentID == "q")
    }

    // MARK: 판(실시간)과 기록 합치기

    @Test func aLiveRunningTaskIsNotStoppedByARecordThatCouldNotDecideItsStatus() {
        var board = BackgroundTaskList()
        board.apply(.started(taskID: "child", toolUseID: nil, kind: .agent, name: "Live name", at: at(1), parentID: nil, depth: nil, foreground: true))
        board.apply(.started(taskID: "bg1", toolUseID: nil, kind: .agent, name: "Parent", at: at(0), parentID: nil, depth: 1, foreground: false))
        let record = listWithBackgroundAgent("bg1").adding(subagents: [meta("child", parent: "bg1", depth: 2, name: "Record name")])
        let merged = board.merged(with: record)
        #expect(task(merged, "child")?.status == .running, "판이 이긴다: 기록의 상태 모름은 도는 일을 멈추지 못한다")
        #expect(task(merged, "child")?.name == "Live name" && task(merged, "child")?.foreground == true)
        #expect(task(merged, "child")?.parentID == "bg1" && task(merged, "child")?.depth == 2, "판에 없던 부모 · 깊이는 기록이 채운다")
    }

    @Test func aTaskOnlyTheRecordKnowsStaysWithoutAStatusAndKeepsNoEndTimeAfterMerging() {
        let record = listWithBackgroundAgent("bg1").adding(subagents: [meta("old", parent: "bg1", depth: 2)])
        let merged = BackgroundTaskList().merged(with: record)
        #expect(task(merged, "old")?.statusUnknown == true && task(merged, "old")?.parentID == "bg1")
        #expect(merged.merged(with: record) == merged, "두 번 합쳐도 같다")
    }

    @Test func aRealEndInTheRecordStillBeatsARunningLiveTask() {
        var board = BackgroundTaskList()
        board.apply(.started(taskID: "a1", toolUseID: nil, kind: .agent, name: "x", at: at(1)))
        var record = BackgroundTaskList()
        record.apply(.started(taskID: "a1", toolUseID: nil, kind: .agent, name: "x", at: at(1), parentID: "p", depth: 2, foreground: false))
        record.apply(.finished(taskID: "a1", kind: .agent, status: .done, exitCode: nil, at: at(20)))
        let merged = board.merged(with: record)
        #expect(task(merged, "a1")?.status == .done && task(merged, "a1")?.endedAt == at(20) && task(merged, "a1")?.parentID == "p")
    }

    @Test func aDepthOneForegroundAgentThatTheRecordDecidedAppearsInTheMergedList() {
        let record = BackgroundTaskList().adding(subagents: [meta("fg1", depth: 1, name: "Fine", tool: "tu1")], calls: ["tu1": called(at: 5, outcome: .init(failed: false, at: at(40)))])
        let merged = BackgroundTaskList().merged(with: record)
        #expect(task(merged, "fg1")?.status == .done && task(merged, "fg1")?.endedAt == at(40) && task(merged, "fg1")?.foreground == true)
    }

    @Test func theRecordFillsAnEmptyParentButNeverReplacesTheBoardsParent() {
        var board = BackgroundTaskList()
        board.apply(.started(taskID: "child", toolUseID: nil, kind: .agent, name: "x", at: at(1), parentID: "board-parent", depth: 2, foreground: true))
        board.apply(.started(taskID: "plain", toolUseID: nil, kind: .agent, name: "x", at: at(2)))
        var record = BackgroundTaskList()
        record.apply(.started(taskID: "child", toolUseID: nil, kind: .agent, name: "x", at: at(1), parentID: "record-parent", depth: 3, foreground: false))
        record.apply(.started(taskID: "plain", toolUseID: nil, kind: .agent, name: "x", at: at(2), parentID: "record-parent", depth: 2, foreground: false))
        let merged = board.merged(with: record)
        #expect(task(merged, "child")?.parentID == "board-parent" && task(merged, "child")?.depth == 2)
        #expect(task(merged, "plain")?.parentID == "record-parent" && task(merged, "plain")?.depth == 2)
    }
}
#endif
