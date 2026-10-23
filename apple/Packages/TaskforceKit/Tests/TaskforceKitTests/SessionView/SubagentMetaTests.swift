#if os(macOS)
import Foundation
import Testing
@testable import TaskforceKit

/// 기록의 `subagents/agent-<id>.meta.json` 해석과, 그 값이 일 목록에 들어가는 규칙 (T1).
/// 선언한 칸 넷만 읽는다: `parentAgentId` · `spawnDepth` · `description` · `requestShape`. 모르는 칸은 무시하고, 깨진 파일은 그 파일만 버린다.
/// 끝 여부는 메타가 아니라 본 기록의 끝 알림이 정한다 (메타의 `finished`는 읽지 않는다): 끝 알림이 없는 일은 끝을 확인하지 못한 일, 기존 낱말 Stopped다
struct SubagentMetaTests {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

    private func parse(_ json: String, id: String = "a1111111111111111") -> SubagentMeta? {
        SubagentMeta.parse(Data(json.utf8), id: id)
    }

    private func meta(_ id: String, parent: String? = nil, depth: Int? = nil, name: String? = "Check a note") -> SubagentMeta {
        SubagentMeta(id: id, parentID: parent, depth: depth, name: name, requestShape: nil)
    }

    private func task(_ list: BackgroundTaskList, _ id: String) -> BackgroundTask? { list.tasks.first { $0.id == id } }

    // MARK: 해석

    @Test func aMetaFileGivesTheFourDeclaredFieldsAndIgnoresTheRest() {
        let json = """
        {"agentType":"general-purpose","description":"Check a nested note","model":"fixture-model","parentAgentId":"a2222222222222222","requestNonInteractive":false,
         "requestShape":"requested.unset","spawnDepth":2,"toolUseId":"toolu_fixture","finished":true,"worktreePath":"/not/read","effort":"high","unknownField":{"nested":[1,2,3]}}
        """
        let found = parse(json)
        #expect(found == SubagentMeta(id: "a1111111111111111", parentID: "a2222222222222222", depth: 2, name: "Check a nested note", requestShape: "requested.unset"))
    }

    @Test func aTopLevelChildHasNoParentAndKeepsItsDepth() {
        let found = parse(#"{"description":"Check a note","spawnDepth":1}"#)
        #expect(found?.parentID == nil && found?.depth == 1 && found?.name == "Check a note" && found?.requestShape == nil)
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
        let found = meta("a1111111111111111", parent: "a2222222222222222", depth: 2, name: "A private name")
        let dump = String(reflecting: found) + String(describing: found)
        #expect(!dump.contains("private") && !dump.contains("a1111111111111111") && !dump.contains("a2222222222222222"))
    }

    // MARK: 일 목록에 넣기

    @Test func aMetaOnlyAgentIsKnownButItsEndIsUnconfirmedSoItIsStoppedWithNoEndTime() {
        let tasks = BackgroundTaskList().adding(subagents: [meta("a1", parent: "p1", depth: 2, name: "Check a note")])
        let found = task(tasks, "a1")
        #expect(found?.kind == .agent && found?.name == "Check a note" && found?.parentID == "p1" && found?.depth == 2)
        #expect(found?.status == .stopped && found?.endedAt == nil && found?.startedAt == nil && found?.foreground == false)
        #expect(found?.endUnconfirmed == true)
    }

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
        let tasks = BackgroundTaskList().adding(subagents: [meta("a1", name: dirty)])
        let name = task(tasks, "a1")?.name ?? ""
        #expect(name.hasPrefix("Check the note ") && !name.contains("\u{202E}") && !name.contains("\n") && name.utf16.count <= ExternalSessionRules.maxTitleUTF16)
        #expect(task(BackgroundTaskList().adding(subagents: [meta("a2", name: nil)]), "a2")?.title == "Agent", "이름이 없으면 도구 이름")
    }

    @Test func addingTheSameMetasAgainChangesNothingAndNoMoreThanTwoHundredFiftySixTasksExist() {
        let metas = (0..<(BackgroundTaskList.maxTasks + 40)).map { meta("a\($0)", name: "Note \($0)") }
        let once = BackgroundTaskList().adding(subagents: metas)
        #expect(once.tasks.count == BackgroundTaskList.maxTasks)
        #expect(once.adding(subagents: metas) == once)
    }

    @Test func metaOnlyAgentsWithNoTimesKeepTheNewestFirstOrderTheReaderGaveThem() {
        let tasks = BackgroundTaskList().adding(subagents: [meta("newest"), meta("middle"), meta("oldest")])
        #expect(SubagentTree.rows(for: tasks, expansion: SubagentTreeExpansion()).map(\.task.id) == ["newest", "middle", "oldest"])
    }

    @Test func aMetaOnlyAgentNeverEvictsATaskTheTranscriptOrTheStreamAlreadyHolds() {
        var full = BackgroundTaskList()
        for index in 0..<BackgroundTaskList.maxTasks { full.apply(.started(taskID: "t\(index)", toolUseID: nil, kind: .command, name: nil, at: at(Double(index)))) }
        #expect(full.adding(subagents: [meta("newcomer")]) == full)
    }

    @Test func aMetaNeverReopensOrUnstopsAnythingAndNeverTouchesAnotherTasksParent() {
        var tasks = BackgroundTaskList()
        tasks.apply(.started(taskID: "a1", toolUseID: nil, kind: .agent, name: "Known", at: at(1), parentID: "p-known", depth: 2, foreground: false))
        let merged = tasks.adding(subagents: [meta("a1", parent: "p-other", depth: 3)])
        #expect(task(merged, "a1")?.parentID == "p-known" && task(merged, "a1")?.depth == 2)
    }

    // MARK: 판(실시간)과 기록 합치기

    @Test func aLiveRunningTaskIsNotStoppedByARecordThatCouldNotConfirmItsEnd() {
        var board = BackgroundTaskList()
        board.apply(.started(taskID: "a1", toolUseID: nil, kind: .agent, name: "Live name", at: at(1), parentID: nil, depth: 1, foreground: true))
        let record = BackgroundTaskList().adding(subagents: [meta("a1", parent: "p-record", depth: 2, name: "Record name")])
        let merged = board.merged(with: record)
        #expect(task(merged, "a1")?.status == .running, "판이 이긴다: 기록의 끝 미확인은 도는 일을 멈추지 않는다")
        #expect(task(merged, "a1")?.name == "Live name" && task(merged, "a1")?.depth == 1 && task(merged, "a1")?.foreground == true)
        #expect(task(merged, "a1")?.parentID == "p-record", "판에 없는 부모는 기록이 채운다")
    }

    @Test func aTaskOnlyTheRecordKnowsStaysUnconfirmedAndKeepsNoEndTimeAfterMerging() {
        let record = BackgroundTaskList().adding(subagents: [meta("old", parent: "p", depth: 2)])
        let merged = BackgroundTaskList().merged(with: record)
        #expect(task(merged, "old")?.status == .stopped && task(merged, "old")?.endedAt == nil && task(merged, "old")?.parentID == "p")
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

    @Test func theRecordFillsAnEmptyParentButNeverReplacesTheBoardsParent() {
        var board = BackgroundTaskList()
        board.apply(.started(taskID: "child", toolUseID: nil, kind: .agent, name: "x", at: at(1), parentID: "board-parent", depth: 2, foreground: true))
        board.apply(.started(taskID: "plain", toolUseID: nil, kind: .agent, name: "x", at: at(2)))
        let record = BackgroundTaskList().adding(subagents: [meta("child", parent: "record-parent", depth: 3), meta("plain", parent: "record-parent", depth: 2)])
        let merged = board.merged(with: record)
        #expect(task(merged, "child")?.parentID == "board-parent" && task(merged, "child")?.depth == 2)
        #expect(task(merged, "plain")?.parentID == "record-parent" && task(merged, "plain")?.depth == 2)
    }
}
#endif
