#if os(macOS) && DEBUG
import Darwin
import Foundation
import Testing
@testable import TaskforceKit

extension ExternalSessionSuites {
    /// 세션 폴더의 `subagents/`에서 하위 에이전트 메타 파일을 읽는 길 (T1, Opus 보안 검토 대상). 폴더 사슬 검사는 `BackgroundTaskTail`이 에이전트 꼬리를 읽을 때 쓰는 것과 **같은 함수**다:
    /// 모든 폴더가 이 uid의 진짜 폴더(기호 링크 아님 · `realpath` 같음 · 그룹/모두에게 쓰기 권한 없음)여야 하고, 이름은 `agent-<id>.meta.json`(id는 `[A-Za-z0-9_-]{1,64}`)만, 256개까지,
    /// 파일은 이 uid의 일반 파일 4 KiB까지 `ExternalSessionFileSystem.read`로 읽는다. 사용자의 실제 기록은 열지 않는다 (가짜 홈)
    struct SubagentMetaReadTests {
        typealias F = ExternalSessionFixture
        let session = F.uuid(0xE7)
        let cwd = "/Users/tester/proj"
        var directory: String { ExternalSessionRules.projectDirectoryName(forCwd: cwd) ?? "" }
        static let descriptionSentinel = "SENTINEL-SUBAGENT-DESCRIPTION"

        private func withHome<T>(_ body: (ExternalHome) throws -> T) throws -> T {
            let home = try ExternalHome()
            defer { home.cleanup() }
            return try body(home)
        }

        private func tail(_ home: ExternalHome, fileSystem: ExternalSessionFileSystem = .live) -> BackgroundTaskTail {
            BackgroundTaskTail(fileSystem: fileSystem, claudeDirectory: home.claude, temporaryRoot: home.root + "/tmp")
        }

        @discardableResult
        private func subagentsDirectory(_ home: ExternalHome) throws -> String {
            let path = "\(home.projects)/\(directory)/\(session)/subagents"
            try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
            return path
        }

        private func metaJSON(parent: String? = nil, depth: Int? = 1, description: String = SubagentMetaReadTests.descriptionSentinel) -> String {
            var object: [String: Any] = ["agentType": "general-purpose", "description": description, "requestNonInteractive": false, "requestShape": "requested.unset", "toolUseId": "toolu_fixture"]
            if let parent { object["parentAgentId"] = parent }
            if let depth { object["spawnDepth"] = depth }
            return F.json(object)
        }

        @discardableResult
        private func writeMeta(_ home: ExternalHome, _ id: String, json: String? = nil, parent: String? = nil, depth: Int? = 1, modified: Date? = nil) throws -> String {
            let path = try subagentsDirectory(home) + "/agent-\(id).meta.json"
            try (json ?? metaJSON(parent: parent, depth: depth)).write(toFile: path, atomically: false, encoding: .utf8)
            if let modified { try home.setModified(path, modified) }
            return path
        }

        private func metas(_ listing: SubagentListing) -> [SubagentMeta]? {
            if case .metas(let found, _) = listing { return found }
            return nil
        }

        private func list(_ reader: BackgroundTaskTail, session: String? = nil, cwd: String?? = nil, since: SubagentCursor? = nil) -> SubagentListing {
            reader.subagents(sessionID: session ?? self.session, cwd: cwd ?? self.cwd, since: since)
        }

        // MARK: 읽기

        @Test func theMetaFilesOfASessionGiveEachAgentsParentDepthAndName() throws {
            try withHome { home in
                try writeMeta(home, "a1111111111111111", depth: 1)
                try writeMeta(home, "a2222222222222222", depth: 1)
                try writeMeta(home, "a3333333333333333", parent: "a1111111111111111", depth: 2)
                let found = try #require(metas(list(tail(home))))
                #expect(Set(found.map(\.id)) == ["a1111111111111111", "a2222222222222222", "a3333333333333333"])
                let nested = found.first { $0.id == "a3333333333333333" }
                #expect(nested?.parentID == "a1111111111111111" && nested?.depth == 2 && nested?.name == Self.descriptionSentinel && nested?.requestShape == "requested.unset")
                #expect(nested?.toolUseID == "toolu_fixture", "다섯째 칸: 깊이 1 에이전트의 상태를 본 기록의 도구 결과와 짝지을 때 쓴다")
                #expect(found.first { $0.id == "a1111111111111111" }?.parentID == nil)
            }
        }

        @Test func aSessionWithoutAnySubagentFolderOrSessionFolderIsMissingNotUnreadable() throws {
            try withHome { home in
                #expect(list(tail(home)) == .missing, "projects 아래에 아무것도 없다")
                try FileManager.default.createDirectory(atPath: "\(home.projects)/\(directory)/\(session)", withIntermediateDirectories: true)
                #expect(list(tail(home)) == .missing, "세션 폴더는 있는데 subagents가 없다")
                try subagentsDirectory(home)
                #expect(metas(list(tail(home))) == [], "빈 subagents 폴더는 에이전트가 없다")
            }
        }

        @Test func theWorkingFolderIsOnlyAGuessAndTheNamesAreScannedWhenItIsUnknownOrWrong() throws {
            try withHome { home in
                try writeMeta(home, "a1111111111111111")
                #expect(metas(list(tail(home), cwd: .some(nil)))?.count == 1)
                #expect(metas(list(tail(home), cwd: "/Users/other/where"))?.count == 1)
                #expect(metas(list(tail(home), cwd: "relative/../path"))?.count == 1)
            }
        }

        // MARK: 이름 규칙 · 256개 상한

        @Test func onlyAgentIdMetaJsonNamesAreEverOpened() throws {
            try withHome { home in
                let sub = try subagentsDirectory(home)
                try writeMeta(home, "a1111111111111111")
                try Data("{}".utf8).write(to: URL(fileURLWithPath: sub + "/agent-a1111111111111111.jsonl"))
                try Data("{}".utf8).write(to: URL(fileURLWithPath: sub + "/agent-a1111111111111111.prefix.json"))
                for name in ["agent-.meta.json", "agent-bad id.meta.json", "other.meta.json", "agent-a1.meta.json.bak", ".meta.json", "agent-a1.META.json", "agent-" + String(repeating: "z", count: 65) + ".meta.json", "agent-한글.meta.json"] {
                    try Data(metaJSON().utf8).write(to: URL(fileURLWithPath: sub + "/" + name))
                }
                try FileManager.default.createDirectory(atPath: sub + "/agent-adir.meta.json", withIntermediateDirectories: true)
                #expect(mkfifo(sub + "/agent-afifo.meta.json", 0o644) == 0)
                let recorder = RecordingFileSystem()
                let found = try #require(metas(list(tail(home, fileSystem: recorder.fileSystem))))
                #expect(found.map(\.id) == ["a1111111111111111"])
                #expect(recorder.reads.map(\.path) == [sub + "/agent-a1111111111111111.meta.json"], "규칙 밖의 이름 · 폴더 · FIFO는 열지도 않는다")
            }
        }

        @Test func theTwoHundredFiftySeventhMetaNameIsIgnored() throws {
            try withHome { home in
                let base = Date(timeIntervalSince1970: 1_800_000_000)
                for index in 0..<257 { try writeMeta(home, String(format: "a%016x", index), modified: base.addingTimeInterval(TimeInterval(index))) }
                let recorder = RecordingFileSystem()
                let found = try #require(metas(list(tail(home, fileSystem: recorder.fileSystem))))
                #expect(found.count == 256 && recorder.reads.count == 256, "256개만 읽는다")
                #expect(!found.contains { $0.id == String(format: "a%016x", 0) }, "가장 오래된 하나가 빠진다")
                #expect(found.contains { $0.id == String(format: "a%016x", 256) })
            }
        }

        @Test func aCrowdedFolderIsListedWithALimitAndNeverWithoutOne() throws {
            try withHome { home in
                let sub = try subagentsDirectory(home)
                for index in 0..<2300 { FileManager.default.createFile(atPath: sub + "/agent-a\(index).jsonl", contents: Data()) }
                try writeMeta(home, "a1111111111111111")
                let recorder = RecordingFileSystem()
                _ = list(tail(home, fileSystem: recorder.fileSystem))
                let subagentCalls = recorder.listCalls.filter { $0.path == sub }
                #expect(subagentCalls.count == 1 && subagentCalls.allSatisfy { $0.limit == SubagentMeta.maxScanned + 1 }, "넘쳤는지 알려고 하나 더 센다")
                #expect(recorder.reads.count <= SubagentMeta.maxMetas)
            }
        }

        // MARK: 길 확인: 기호 링크 · 남의 것 · 쓰기 권한

        @Test func aMetaFileThatIsASymbolicLinkIsNeverFollowed() throws {
            try withHome { home in
                let secret = home.root + "/outside-secret.json"
                try Data(metaJSON(description: "SENTINEL-OUTSIDE-SECRET").utf8).write(to: URL(fileURLWithPath: secret))
                let sub = try subagentsDirectory(home)
                try home.link(sub + "/agent-a1111111111111111.meta.json", to: secret)
                try writeMeta(home, "a2222222222222222")
                let recorder = RecordingFileSystem()
                let found = try #require(metas(list(tail(home, fileSystem: recorder.fileSystem))))
                #expect(found.map(\.id) == ["a2222222222222222"])
                #expect(!recorder.reads.contains { $0.path.hasSuffix("a1111111111111111.meta.json") } && !recorder.reads.contains { $0.path == secret }, "기호 링크는 열어 보지도 않는다")
            }
        }

        @Test func aSymbolicLinkInAnyFolderOfThePathIsRefusedBeforeReading() throws {
            for level in ["projects", "project", "session", "subagents"] {
                try withHome { home in
                    let outside = home.root + "/outside"
                    try FileManager.default.createDirectory(atPath: outside + "/subagents", withIntermediateDirectories: true)
                    try Data(metaJSON().utf8).write(to: URL(fileURLWithPath: outside + "/subagents/agent-a1111111111111111.meta.json"))
                    switch level {
                    case "projects":
                        try FileManager.default.removeItem(atPath: home.projects)
                        try FileManager.default.createDirectory(atPath: outside + "/\(directory)/\(session)", withIntermediateDirectories: true)
                        try FileManager.default.moveItem(atPath: outside + "/subagents", toPath: outside + "/\(directory)/\(session)/subagents")
                        try home.link(home.projects, to: outside)
                    case "project":
                        try FileManager.default.createDirectory(atPath: outside + "/\(session)", withIntermediateDirectories: true)
                        try FileManager.default.moveItem(atPath: outside + "/subagents", toPath: outside + "/\(session)/subagents")
                        try home.link(home.projects + "/" + directory, to: outside)
                    case "session":
                        try FileManager.default.createDirectory(atPath: home.projects + "/" + directory, withIntermediateDirectories: true)
                        try home.link(home.projects + "/" + directory + "/" + session, to: outside)
                    default:
                        try FileManager.default.createDirectory(atPath: home.projects + "/" + directory + "/" + session, withIntermediateDirectories: true)
                        try home.link(home.projects + "/" + directory + "/" + session + "/subagents", to: outside + "/subagents")
                    }
                    let recorder = RecordingFileSystem()
                    #expect(list(tail(home, fileSystem: recorder.fileSystem)) == .unreadable, "\(level)이 기호 링크다")
                    #expect(recorder.reads.isEmpty)
                }
            }
        }

        @Test func aFolderOrFileThatIsNotOursIsRefusedOrSkipped() throws {
            try withHome { home in
                try writeMeta(home, "a1111111111111111")
                try writeMeta(home, "a2222222222222222")
                let base = ExternalSessionFileSystem.live
                for suffix in ["/subagents", "/\(session)", "/\(directory)", "/projects"] {
                    let strangers = ExternalSessionFileSystem(
                        userID: base.userID, realpath: base.realpath,
                        lstat: { path in
                            guard var entry = base.lstat(path) else { return nil }
                            if path.hasSuffix(suffix) { entry.owner = entry.owner &+ 1 }
                            return entry
                        },
                        list: base.list, read: base.read
                    )
                    #expect(list(tail(home, fileSystem: strangers)) == .unreadable, "남의 폴더: \(suffix)")
                }
                // 남의 파일 하나: 그 파일만 건너뛴다
                let oneForeign = ExternalSessionFileSystem(
                    userID: base.userID, realpath: base.realpath, lstat: base.lstat,
                    list: { path, limit in
                        guard case .entries(var entries) = base.list(path, limit) else { return base.list(path, limit) }
                        for index in entries.indices where entries[index].name.contains("a2222222222222222") { entries[index].owner = entries[index].owner &+ 1 }
                        return .entries(entries)
                    },
                    read: base.read
                )
                #expect(metas(list(tail(home, fileSystem: oneForeign)))?.map(\.id) == ["a1111111111111111"])
                // 읽기 쪽 검사: 열린 파일이 남의 것이면 nil이다 (실제 파일 시스템 읽기가 거른다): 그 파일들을 건너뛴다
                let foreignRead = ExternalSessionFileSystem(userID: base.userID, realpath: base.realpath, lstat: base.lstat, list: base.list, read: { _, _, _ in nil })
                #expect(metas(list(tail(home, fileSystem: foreignRead))) == [])
            }
        }

        @Test func aFolderWhoseRealPathIsNotItsOwnPathIsRefused() throws {
            try withHome { home in
                try writeMeta(home, "a1111111111111111")
                let base = ExternalSessionFileSystem.live
                #expect(metas(list(tail(home)))?.count == 1)
                for suffix in ["/subagents", "/\(session)", "/\(directory)", "/projects"] {
                    let rerouted = ExternalSessionFileSystem(
                        userID: base.userID, realpath: { path in path.hasSuffix(suffix) ? base.realpath(path).map { $0 + "-elsewhere" } : base.realpath(path) },
                        lstat: base.lstat, list: base.list, read: base.read
                    )
                    #expect(list(tail(home, fileSystem: rerouted)) == .unreadable, "다른 곳으로 이어진 길: \(suffix)")
                }
            }
        }

        @Test func aFolderOnThePathThatOthersCanWriteIsRefusedWithTheRealFileSystem() throws {
            try withHome { home in
                try writeMeta(home, "a1111111111111111")
                let sub = "\(home.projects)/\(directory)/\(session)/subagents"
                for folder in [sub, "\(home.projects)/\(directory)/\(session)", "\(home.projects)/\(directory)", home.projects] {
                    for mode in [0o775, 0o757, 0o777, 0o772] {
                        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: folder)
                        #expect(list(tail(home)) == .unreadable, "쓰기 가능한 폴더 \(mode)")
                    }
                    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder)
                    #expect(metas(list(tail(home)))?.count == 1, "내 것만 쓰는 폴더는 읽는다")
                }
            }
        }

        @Test func aSessionIdThatIsNotACanonicalUuidIsRefusedBeforeAnyAccess() throws {
            try withHome { home in
                try writeMeta(home, "a1111111111111111")
                let recorder = RecordingFileSystem()
                let reader = tail(home, fileSystem: recorder.fileSystem)
                for bad in ["", "../x", "5E5E5E5E-0000-4000-8000-0000000000E7", "not-a-uuid", session + "/../" + session] {
                    #expect(list(reader, session: bad) == .unreadable)
                }
                #expect(recorder.statted.isEmpty && recorder.reads.isEmpty && recorder.listed.isEmpty && recorder.resolved.isEmpty, "검사가 파일 시스템보다 먼저다")
            }
        }

        // MARK: 파일 크기 · 깨진 JSON

        @Test func aFileOverFourKilobytesIsSkippedWithoutBeingRead() throws {
            try withHome { home in
                try writeMeta(home, "a1111111111111111")
                let big = try writeMeta(home, "a2222222222222222", json: metaJSON() + String(repeating: " ", count: SubagentMeta.maxBytes))
                let recorder = RecordingFileSystem()
                let found = try #require(metas(list(tail(home, fileSystem: recorder.fileSystem))))
                #expect(found.map(\.id) == ["a1111111111111111"])
                #expect(!recorder.reads.contains { $0.path == big }, "목록의 크기로 거르고 열지 않는다")
                #expect(recorder.reads.allSatisfy { $0.length <= SubagentMeta.maxBytes }, "한 번에 4 KiB를 넘게 읽지 않는다")
            }
        }

        @Test func aFileOfExactlyFourKilobytesIsStillRead() throws {
            try withHome { home in
                let json = metaJSON()
                let padded = json.dropLast() + #","pad":""# + String(repeating: "x", count: SubagentMeta.maxBytes - json.utf8.count - 9) + #""}"#
                #expect(padded.utf8.count == SubagentMeta.maxBytes)
                try writeMeta(home, "a1111111111111111", json: String(padded))
                #expect(metas(list(tail(home)))?.map(\.id) == ["a1111111111111111"])
            }
        }

        @Test func aBrokenOrEmptyFileDropsOnlyThatFileAndTheRestAreStillRead() throws {
            try withHome { home in
                try writeMeta(home, "a1111111111111111")
                try writeMeta(home, "a2222222222222222", json: "{ this is not json")
                try writeMeta(home, "a3333333333333333", json: "")
                try writeMeta(home, "a4444444444444444", json: "[1,2,3]")
                try writeMeta(home, "a5555555555555555", parent: "a1111111111111111", depth: 2)
                let found = try #require(metas(list(tail(home))))
                #expect(Set(found.map(\.id)) == ["a1111111111111111", "a5555555555555555"])
            }
        }

        // MARK: 다시 훑기

        @Test func anUnchangedFolderIsNotListedOrReadAgain() throws {
            try withHome { home in
                try writeMeta(home, "a1111111111111111")
                let first = list(tail(home))
                guard case .metas(_, let cursor) = first else {
                    Issue.record("처음 훑기가 읽지 못했다")
                    return
                }
                let recorder = RecordingFileSystem()
                #expect(list(tail(home, fileSystem: recorder.fileSystem), since: cursor) == .unchanged)
                #expect(recorder.reads.isEmpty && recorder.listed.isEmpty, "폴더가 그대로면 이름도 훑지 않는다")
                #expect(recorder.statted.isEmpty == false, "길 확인은 늘 한다")
                // 새 파일이 생기면 폴더의 바뀐 시각이 달라져 다시 훑는다
                try writeMeta(home, "a2222222222222222")
                try home.setModified("\(home.projects)/\(directory)/\(session)/subagents", cursor.stamp.addingTimeInterval(5))
                #expect(metas(list(tail(home), since: cursor))?.count == 2)
            }
        }

        @Test func aFolderThatBecameUntrustedIsRefusedEvenWhenItsStampIsUnchanged() throws {
            try withHome { home in
                try writeMeta(home, "a1111111111111111")
                guard case .metas(_, let cursor) = list(tail(home)) else {
                    Issue.record("처음 훑기가 읽지 못했다")
                    return
                }
                try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: "\(home.projects)/\(directory)/\(session)/subagents")
                #expect(list(tail(home), since: cursor) == .unreadable)
            }
        }

        // MARK: 찾은 프로젝트 폴더를 기억한다 · 넘침

        @Test func theProjectFolderFoundOnTheFirstScanIsRememberedSoTheProjectsAreNotListedAgain() throws {
            try withHome { home in
                try writeMeta(home, "a1111111111111111")
                // 작업 폴더를 모르는 세션: 첫 훑기는 프로젝트 폴더들의 이름을 훑어 찾는다
                let first = RecordingFileSystem()
                guard case .metas(_, let cursor) = list(tail(home, fileSystem: first.fileSystem), cwd: .some(nil)) else {
                    Issue.record("처음 훑기가 읽지 못했다")
                    return
                }
                #expect(first.listed.contains(home.projects), "처음에는 projects를 나열한다")
                #expect(cursor.project == directory)
                // 새 파일이 생겨 다시 훑을 때: projects를 다시 나열하지 않고 그 프로젝트 아래의 길만 다시 본다
                try writeMeta(home, "a2222222222222222")
                try home.setModified("\(home.projects)/\(directory)/\(session)/subagents", cursor.stamp.addingTimeInterval(5))
                let second = RecordingFileSystem()
                #expect(metas(list(tail(home, fileSystem: second.fileSystem), cwd: .some(nil), since: cursor))?.count == 2)
                #expect(!second.listed.contains(home.projects), "찾은 프로젝트 폴더를 기억한다: \(second.listed.count)번 나열")
                // 폴더가 그대로인 틱도 projects를 나열하지 않는다
                guard case .metas(_, let next) = list(tail(home), cwd: .some(nil), since: cursor) else { return }
                let third = RecordingFileSystem()
                #expect(list(tail(home, fileSystem: third.fileSystem), cwd: .some(nil), since: next) == .unchanged)
                #expect(!third.listed.contains(home.projects) && third.reads.isEmpty)
            }
        }

        @Test func aRememberedProjectStillGoesThroughTheWholeFolderChainEveryTime() throws {
            try withHome { home in
                try writeMeta(home, "a1111111111111111")
                guard case .metas(_, let cursor) = list(tail(home), cwd: .some(nil)) else {
                    Issue.record("처음 훑기가 읽지 못했다")
                    return
                }
                let project = "\(home.projects)/\(directory)"
                // 기억한 프로젝트 폴더가 기호 링크로 바뀌었다
                let outside = home.root + "/outside"
                try FileManager.default.createDirectory(atPath: outside + "/\(session)/subagents", withIntermediateDirectories: true)
                try Data(metaJSON().utf8).write(to: URL(fileURLWithPath: outside + "/\(session)/subagents/agent-a9999999999999999.meta.json"))
                try FileManager.default.moveItem(atPath: project, toPath: home.root + "/moved")
                try home.link(project, to: outside)
                let recorder = RecordingFileSystem()
                #expect(list(tail(home, fileSystem: recorder.fileSystem), cwd: .some(nil), since: cursor) == .unreadable)
                #expect(recorder.reads.isEmpty)
            }
        }

        @Test func aRememberedProjectThatNoLongerHoldsTheSessionFallsBackToFindingItAgain() throws {
            try withHome { home in
                try writeMeta(home, "a1111111111111111")
                guard case .metas(_, let real) = list(tail(home), cwd: .some(nil)) else {
                    Issue.record("처음 훑기가 읽지 못했다")
                    return
                }
                // 엉뚱한 프로젝트 이름을 기억하고 있어도 (그 아래에 세션이 없다) 이름 훑기로 다시 찾는다
                let stale = SubagentCursor(project: "-Nowhere-at-all", stamp: real.stamp.addingTimeInterval(-60))
                #expect(metas(list(tail(home), cwd: .some(nil), since: stale))?.count == 1)
                // 이름 규칙 밖의 기억은 믿지 않는다 (경로가 끼어들 길이 없다)
                let hostile = SubagentCursor(project: "../../etc", stamp: real.stamp.addingTimeInterval(-60))
                #expect(metas(list(tail(home), cwd: .some(nil), since: hostile))?.count == 1)
            }
        }

        @Test func moreEntriesThanTheScanLimitAreRecordedAsAnOverflowAndExactlyTheLimitIsNot() throws {
            try withHome { home in
                let sub = try subagentsDirectory(home)
                try writeMeta(home, "a1111111111111111")
                for index in 0..<(SubagentMeta.maxScanned - 1) { FileManager.default.createFile(atPath: sub + "/agent-a\(index).jsonl", contents: Data()) }
                guard case .metas(_, let exact) = list(tail(home)) else {
                    Issue.record("읽지 못했다")
                    return
                }
                #expect(!exact.overflowed, "정확히 한도만큼이면 넘친 것이 아니다")
                FileManager.default.createFile(atPath: sub + "/agent-aextra1.jsonl", contents: Data())
                FileManager.default.createFile(atPath: sub + "/agent-aextra2.jsonl", contents: Data())
                guard case .metas(_, let over) = list(tail(home)) else {
                    Issue.record("읽지 못했다")
                    return
                }
                #expect(over.overflowed, "한도를 넘으면 그 사실이 자리에 남는다")
            }
        }

        // MARK: 글을 남기지 않는다

        @Test func theListingAndTheMetasNeverPrintTheirText() throws {
            try withHome { home in
                try writeMeta(home, "a1111111111111111", parent: nil, depth: 1)
                let listing = list(tail(home))
                #expect(!(String(reflecting: listing) + String(describing: listing)).contains(Self.descriptionSentinel))
                #expect(!String(describing: metas(listing) ?? []).contains(Self.descriptionSentinel) && !String(reflecting: metas(listing) ?? []).contains(Self.descriptionSentinel))
            }
        }

        @Test func theTranscriptReaderReadsThroughTheSameChecks() throws {
            try withHome { home in
                try writeMeta(home, "a1111111111111111")
                try writeMeta(home, "a2222222222222222", parent: "a1111111111111111", depth: 2)
                let reader = ClaudeAppTranscriptReader(claudeDirectory: home.claude)
                #expect(Set(metas(reader.subagents(sessionID: session, cwd: cwd, since: nil))?.map(\.id) ?? []) == ["a1111111111111111", "a2222222222222222"])
                try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: "\(home.projects)/\(directory)/\(session)/subagents")
                #expect(reader.subagents(sessionID: session, cwd: cwd, since: nil) == .unreadable, "기록 읽기 쪽도 같은 폴더 사슬 검사를 지난다")
            }
        }
    }
}
#endif
