#if os(macOS) && DEBUG
import Darwin
import Foundation
import Testing
@testable import TaskforceKit

extension ExternalSessionSuites {
    /// Taskforce 창이 보여 줄 데스크톱 세션의 대화 읽기 (PR-D1 Kit, 계약 21.4 · DR-7 · DR-14 · DT2 · DT8): 사용자가 연 그 세션 하나의 기록만, 대화 줄(`user` · `assistant` ·
    /// peer `queued_command`)만 해석하고, 한 줄 · 한 번 · 총량 상한, 꼬리부터 200개 + 이전 · 이어 읽기. 기록은 `Fixtures/claude-app-transcripts/`의 가짜 사본이다 (사용자의 실제 기록 0)
    struct ClaudeAppTranscriptReaderTests {
        typealias F = ExternalSessionFixture
        typealias A = ClaudeAppFixture
        typealias L = ClaudeAppLine
        let id = F.uuid(0xD1)
        let cwd = "/Users/tester/proj"
        var directory: String { ExternalSessionRules.projectDirectoryName(forCwd: cwd) ?? "" }

        private func withHome<T>(_ body: (ExternalHome) throws -> T) throws -> T {
            let home = try ExternalHome()
            defer { home.cleanup() }
            return try body(home)
        }

        private func fixtureURL(_ name: String, file: StaticString = #filePath) -> URL {
            URL(fileURLWithPath: "\(file)").deletingLastPathComponent().deletingLastPathComponent().appending(path: "Fixtures/claude-app-transcripts/\(name)")
        }

        /// 견본 기록을 가짜 홈의 `projects/<디렉터리>/<id>.jsonl`로 복사한다
        @discardableResult
        private func install(_ fixture: String, as sessionID: String? = nil, in home: ExternalHome, directory: String? = nil) throws -> String {
            let dir = try home.directory(directory ?? self.directory)
            let path = dir + "/" + (sessionID ?? id) + ".jsonl"
            try FileManager.default.copyItem(at: fixtureURL(fixture), to: URL(fileURLWithPath: path))
            return path
        }

        private func reader(
            _ home: ExternalHome, fileSystem: ExternalSessionFileSystem = .live, limits: ClaudeAppTranscriptReader.Limits = .standard, log: any BridgeLogSink = NoBridgeLog()
        ) -> ClaudeAppTranscriptReader {
            ClaudeAppTranscriptReader(fileSystem: fileSystem, claudeDirectory: home.claude, limits: limits, log: log)
        }

        private func page(_ load: ClaudeAppTranscriptLoad, sourceLocation: SourceLocation = #_sourceLocation) -> ClaudeAppTranscriptPage? {
            if case .page(let page) = load { return page }
            Issue.record("기록을 읽지 못했다", sourceLocation: sourceLocation)
            return nil
        }

        private func texts(_ turns: [ClaudeAppTurn]) -> [String] {
            turns.compactMap { turn in
                switch turn.kind {
                case .user(let text), .assistant(let text), .peer(let text, _): text
                case .tool, .boundary: nil
                }
            }
        }

        /// 정해 둔 줄만 주는 가짜 기록
        private final class FixedTurnsSource: ClaudeAppTranscriptSource, @unchecked Sendable {
            let turns: [ClaudeAppTurn]
            init(turns: [ClaudeAppTurn]) { self.turns = turns }
            func open(sessionID: String, cwd: String?) -> ClaudeAppTranscriptLoad {
                .page(ClaudeAppTranscriptPage(turns: turns, cursor: ClaudeAppTranscriptCursor(sessionID: sessionID), hasEarlier: false, skippedLines: 0))
            }
            func earlier(_ cursor: ClaudeAppTranscriptCursor) -> ClaudeAppTranscriptLoad { .unreadable }
            func newer(_ cursor: ClaudeAppTranscriptCursor) -> ClaudeAppTranscriptUpdate { .turns([], cursor: cursor, hasMore: false) }
        }

        private func kinds(_ turns: [ClaudeAppTurn]) -> [String] {
            turns.map { turn in
                switch turn.kind {
                case .user: "user"
                case .assistant: "assistant"
                case .peer: "peer"
                case .tool: "tool"
                case .boundary: "boundary"
                }
            }
        }

        // MARK: 글 없는 경계 (OA PR-D3 검토 P2-1, DT11) · 안정된 ref 씨앗 (P3-11)

        /// 실측(Claude Code 2.1.x, 일회용 세션): 턴이 도는 동안 보낸 글은 `queue-operation enqueue` 뒤에 `attachment`(`type: queued_command`, `prompt` = 친 글, `commandMode: "prompt"`, **`origin` 없음**)로 기록된다.
        /// 우리 글 L 뒤에 이런 줄이 끼면 그 뒤의 답은 L에 대한 답이 아니다 → 글 없는 경계 줄
        @Test func aPromptTypedOnTheDesktopMidTurnATaskNotificationAndAHookLineEachBecomeATextlessBoundary() throws {
            try withHome { home in
                let typed = "SENTINEL-DESKTOP-TYPED-MIDTURN"
                let hook = "SENTINEL-HOOK-LINE"
                let notice = "<task-notification><task-id>bgtask1</task-id><status>completed</status><summary>SENTINEL-NOTICE-SUMMARY</summary></task-notification>"
                let lines = [
                    peerUser(msg: "m1", body: "from relay"),
                    L.assistant(id: id, text: "answer one"),
                    F.json([
                        "type": "attachment", "sessionId": id, "uuid": UUID().uuidString.lowercased(), "timestamp": "2026-10-22T01:00:05.000Z",
                        "attachment": ["type": "queued_command", "prompt": typed, "source_uuid": UUID().uuidString.lowercased(), "commandMode": "prompt"],
                    ]),
                    L.assistant(id: id, text: "answer two"),
                    F.json(["type": "user", "sessionId": id, "message": ["role": "user", "content": hook], "origin": ["kind": "hook", "body": hook]]),
                    L.assistant(id: id, text: "answer three"),
                    F.json(["type": "attachment", "sessionId": id, "attachment": ["type": "queued_command", "prompt": notice, "commandMode": "task-notification"]]),
                    L.assistant(id: id, text: "answer four"),
                ]
                try home.transcript(directory: directory, id: id, lines: lines)
                guard let page = page(reader(home).open(sessionID: id, cwd: cwd)) else { return }
                #expect(kinds(page.turns) == ["peer", "assistant", "boundary", "assistant", "boundary", "assistant", "boundary", "assistant"])
                var dump = ""
                Swift.dump(page, to: &dump)
                let all = dump + String(reflecting: page.turns) + String(describing: page.cursor)
                for sentinel in [typed, hook, "SENTINEL-NOTICE-SUMMARY"] { #expect(!all.contains(sentinel), Comment(rawValue: "경계 줄에는 글이 없다: \(sentinel)")) }
            }
        }

        @MainActor
        @Test func aBoundaryNeverReachesTheConversationTheWindowShows() async throws {
            let turns = [
                ClaudeAppTurn(id: "1", kind: .user("hello")), ClaudeAppTurn(id: "2", kind: .boundary), ClaudeAppTurn(id: "3", kind: .assistant("hi")),
            ]
            let conversation = ClaudeAppConversation(sessionID: id, cwd: cwd, source: FixedTurnsSource(turns: turns))
            conversation.start()
            var waited = 0
            while conversation.phase != .ready, waited < 400 {
                try? await Task.sleep(for: .milliseconds(5))
                waited += 1
            }
            #expect(conversation.phase == .ready)
            #expect(kinds(conversation.turns) == ["user", "assistant"], "화면의 대화에는 글 없는 경계가 없다")
            conversation.stop()
        }

        @Test func everyConversationLineCarriesTheRecordUUIDAndItsBlockIndexAsAStableID() throws {
            try withHome { home in
                let uuid = "11111111-2222-4333-8444-555555555555"
                let record = F.json([
                    "type": "assistant", "sessionId": id, "uuid": uuid, "timestamp": "2026-10-22T01:00:02.000Z",
                    "message": ["role": "assistant", "content": [["type": "text", "text": "first block"], ["type": "tool_use", "id": "toolu_1", "name": "Read", "input": [:]], ["type": "text", "text": "last block"]]],
                ])
                let noUUID = F.json(["type": "assistant", "sessionId": id, "message": ["role": "assistant", "content": [["type": "text", "text": "no uuid here"]]]])
                try home.transcript(directory: directory, id: id, lines: [record, noUUID])
                guard let page = page(reader(home).open(sessionID: id, cwd: cwd)) else { return }
                #expect(page.turns.map(\.stableID) == ["\(uuid)-0", "\(uuid)-1", "\(uuid)-2", nil], "uuid가 있으면 uuid + 몇 번째 블록, 없으면 nil(줄 위치로 되돌아간다)")
            }
        }

        private func append(_ path: String, _ text: String) throws {
            let handle = try #require(FileHandle(forWritingAtPath: path))
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(text.utf8))
        }

        /// `turn 0`, `turn 1`, …: 짝수는 사용자 · 홀수는 어시스턴트의 말
        private func conversation(_ count: Int, id: String? = nil, pad: Int = 0) -> [String] {
            let sid = id ?? self.id
            let filler = pad > 0 ? " " + String(repeating: "x", count: pad) : ""
            return (0..<count).map { n in n % 2 == 0 ? L.user(id: sid, text: "turn \(n)\(filler)") : L.assistant(id: sid, text: "turn \(n)\(filler)") }
        }

        private let relay = ClaudeAppPeer(plugin: "tf-relay", verifiedPeerPID: 4321, messageID: "00000000-0000-4000-8000-0000000000b1")

        // MARK: 대화 줄만 해석한다

        @Test func theBasicTranscriptReadsAsTheConversationInOrder() throws {
            try withHome { home in
                try install("desktop-basic.jsonl", in: home)
                guard let page = page(reader(home).open(sessionID: id, cwd: cwd)) else { return }
                #expect(page.turns.map(\.kind) == [
                    .user("Please list the files"), .assistant("I will look."), .tool(name: "Bash", description: "List files"), .assistant("Here are the files."),
                    .peer("Please also run the tests", relay), .assistant("Running the tests."),
                    .peer("And summarize", ClaudeAppPeer(plugin: "tf-relay", verifiedPeerPID: 4321, messageID: "00000000-0000-4000-8000-0000000000b2")),
                    .tool(name: "Read", description: nil), .boundary, .assistant("All done."),
                ], "peer가 아닌 `queued_command`는 글 없는 경계로만 남는다 (OA PR-D3 검토 P2-1)")
                #expect(!page.hasEarlier)
                #expect(page.skippedLines == 0)
                #expect(Set(page.turns.map(\.id)).count == page.turns.count, "줄 위치로 만든 id는 겹치지 않는다")
            }
        }

        @Test func theTurnsKeepTheirTimeAndAPeerFromTheTaskforceRelayIsRecognized() throws {
            try withHome { home in
                try install("desktop-basic.jsonl", in: home)
                guard let page = page(reader(home).open(sessionID: id, cwd: cwd)) else { return }
                let iso = ISO8601DateFormatter()
                iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                #expect(page.turns.first?.timestamp == iso.date(from: "2026-10-22T01:00:01.000Z"))
                guard case .peer(_, let peer) = page.turns[4].kind else {
                    Issue.record("peer 줄이 아니다")
                    return
                }
                // 중계 출처는 플러그인 이름만으로 믿지 않는다: 우리가 띄운 중계 프로세스의 pid(검증된 peer pid)까지 같아야 한다 (보안 검토 P2)
                #expect(peer.plugin == "tf-relay" && peer.verifiedPeerPID == 4321)
                #expect(peer.isTaskforceRelay(relayPID: 4321))
                #expect(!peer.isTaskforceRelay(relayPID: 9999), "이름만 tf-relay인 다른 프로세스의 메시지는 Taskforce가 보낸 것이 아니다")
                #expect(!ClaudeAppPeer(plugin: "tf-relay-probe", verifiedPeerPID: 1, messageID: nil).isTaskforceRelay(relayPID: 1))
                #expect(!ClaudeAppPeer(plugin: "tf-relay", verifiedPeerPID: nil, messageID: nil).isTaskforceRelay(relayPID: 4321))
                #expect(!ClaudeAppPeer(plugin: nil, verifiedPeerPID: 4321, messageID: nil).isTaskforceRelay(relayPID: 4321))
            }
        }

        @Test func nothingFromTheRecordsThatAreNeverOpenedOrFromNonConversationLinesReachesAnyOutput() throws {
            try withHome { home in
                try install("desktop-basic.jsonl", in: home)
                let reader = reader(home)
                guard let page = page(reader.open(sessionID: id, cwd: cwd)) else { return }
                var dump = ""
                Swift.dump(page, to: &dump)
                let text = dump + String(describing: page) + String(reflecting: page) + String(describing: page.cursor) + String(reflecting: page.turns)
                for sentinel in A.neverShown { #expect(!text.contains(sentinel), Comment(rawValue: "\(sentinel)은 어디에도 나오지 않는다")) }
                for body in A.toolBodies { #expect(!text.contains(body), Comment(rawValue: "접힌 줄에는 도구 본문이 없다: \(body)")) }
                // 이어 읽기 · 이전 쪽도 마찬가지다
                if case .turns(let more, let cursor, _) = reader.newer(page.cursor) { #expect(more.isEmpty); #expect(!String(reflecting: cursor).contains(A.emailSentinel)) }
                if let earlier = self.page(reader.earlier(page.cursor)) { #expect(earlier.turns.isEmpty) }
            }
        }

        @Test func aQueuedCommandWhoseOriginIsNotAPeerIsNeverShownEvenIfItNamesTheRelayPlugin() throws {
            try withHome { home in
                let notAPeer = "SENTINEL-NOT-A-PEER-BODY"
                let lines = [
                    L.user(id: id, text: "typed"),
                    F.json([
                        "type": "attachment", "sessionId": id, "timestamp": "2026-10-22T01:00:05.000Z",
                        "attachment": ["type": "queued_command", "commandMode": "prompt", "prompt": A.wrapperSentinel, "origin": ["kind": "task", "body": notAPeer, "plugin": "tf-relay", "verifiedPeerPid": 1]],
                    ]),
                    F.json(["type": "attachment", "sessionId": id, "attachment": ["type": "queued_command", "commandMode": "prompt", "prompt": A.wrapperSentinel, "origin": ["body": notAPeer]]]),
                    L.assistant(id: id, text: "ok"),
                ]
                try home.transcript(directory: directory, id: id, lines: lines)
                guard let page = page(reader(home).open(sessionID: id, cwd: cwd)) else { return }
                #expect(texts(page.turns) == ["typed", "ok"])
                var dump = ""
                Swift.dump(page.turns, to: &dump)
                #expect(!dump.contains(notAPeer) && !dump.contains(A.wrapperSentinel))
            }
        }

        // MARK: 대화가 아닌 줄 · 중복 · 글 정리 (코드 검토 P3)

        private func peerUser(msg: String, body: String, pid: Int = 4321) -> String {
            F.json([
                "type": "user", "isMeta": true, "sessionId": id, "message": ["role": "user", "content": A.wrapperSentinel],
                "origin": ["kind": "peer", "plugin": "tf-relay", "verifiedPeerPid": pid, "msg_id": msg, "body": body],
            ])
        }

        private func peerQueued(msg: String, body: String, pid: Int = 4321) -> String {
            F.json([
                "type": "attachment", "sessionId": id,
                "attachment": ["type": "queued_command", "prompt": A.wrapperSentinel, "origin": ["kind": "peer", "plugin": "tf-relay", "verifiedPeerPid": pid, "msg_id": msg, "body": body]],
            ])
        }

        @Test func aUserRecordWhoseOriginIsNotAPeerIsNotShown() throws {
            try withHome { home in
                let injected = F.json(["type": "user", "sessionId": id, "message": ["role": "user", "content": "SENTINEL-HOOK-INJECTED"], "origin": ["kind": "hook", "body": "SENTINEL-HOOK-INJECTED"]])
                let other = F.json(["type": "user", "sessionId": id, "message": ["role": "user", "content": "SENTINEL-TASK-INJECTED"], "origin": ["body": "x"]])
                try home.transcript(directory: directory, id: id, lines: [L.user(id: id, text: "typed"), injected, other, L.assistant(id: id, text: "ok")])
                guard let page = page(reader(home).open(sessionID: id, cwd: cwd)) else { return }
                #expect(texts(page.turns) == ["typed", "ok"], "origin이 있는데 peer가 아니면 사용자가 친 말이 아니다")
            }
        }

        @Test func claudeCodeSlashCommandAndLocalCommandMarkupIsNotConversation() throws {
            try withHome { home in
                let markup = [
                    "<command-name>/clear</command-name>\n<command-message>clear</command-message>\n<command-args></command-args>", "<local-command-stdout>SENTINEL-LOCAL-OUTPUT</local-command-stdout>",
                    "<local-command-caveat>Caveat: SENTINEL-CAVEAT</local-command-caveat>", "  <command-name>/model</command-name>",
                ].map { L.user(id: id, text: $0) }
                let mid = L.user(id: id, text: "please explain what <command-name> means in Claude Code")
                try home.transcript(directory: directory, id: id, lines: markup + [mid, L.assistant(id: id, text: "ok")])
                guard let page = page(reader(home).open(sessionID: id, cwd: cwd)) else { return }
                #expect(texts(page.turns) == ["please explain what <command-name> means in Claude Code", "ok"], "맨 앞의 표시 줄만 건너뛴다: 글 가운데의 같은 글자는 대화다")
            }
        }

        @Test func compactSummariesAndTranscriptOnlyRecordsAreNotConversation() throws {
            try withHome { home in
                let compact = F.json(["type": "user", "isCompactSummary": true, "sessionId": id, "message": ["role": "user", "content": "SENTINEL-COMPACT-SUMMARY"]])
                let transcriptOnly = F.json(["type": "assistant", "isVisibleInTranscriptOnly": true, "sessionId": id, "message": ["role": "assistant", "content": [["type": "text", "text": "SENTINEL-TRANSCRIPT-ONLY"]]]])
                try home.transcript(directory: directory, id: id, lines: [L.user(id: id, text: "typed"), compact, transcriptOnly, L.assistant(id: id, text: "ok")])
                guard let page = page(reader(home).open(sessionID: id, cwd: cwd)) else { return }
                #expect(texts(page.turns) == ["typed", "ok"])
            }
        }

        @Test func aPeerMessageRecordedAsBothShapesIsShownOnce() throws {
            try withHome { home in
                try home.transcript(directory: directory, id: id, lines: [L.user(id: id, text: "typed"), peerUser(msg: "m1", body: "hello"), peerQueued(msg: "m1", body: "hello"), peerQueued(msg: "m2", body: "second")])
                guard let first = page(reader(home).open(sessionID: id, cwd: cwd)) else { return }
                #expect(texts(first.turns) == ["typed", "hello", "second"], "같은 msg_id는 한 번만")
            }
        }

        /// 중복 판정의 열쇠는 (msg_id, 검증된 보낸 pid, 플러그인) 셋이다 (PR-D1 보안 검토 P3): 다른 프로세스가 남의 msg_id를 흉내 내 진짜 메시지를 가리지 못한다
        @Test func twoPeersThatShareAMessageIDButNotTheSenderOrPluginAreBothShown() throws {
            try withHome { home in
                let spoof = F.json([
                    "type": "user", "isMeta": true, "sessionId": id, "message": ["role": "user", "content": A.wrapperSentinel],
                    "origin": ["kind": "peer", "plugin": "tf-relay", "verifiedPeerPid": 9999, "msg_id": "m1", "body": "from another process"],
                ])
                let otherPlugin = F.json([
                    "type": "attachment", "sessionId": id,
                    "attachment": ["type": "queued_command", "prompt": A.wrapperSentinel, "origin": ["kind": "peer", "plugin": "other-mod", "verifiedPeerPid": 4321, "msg_id": "m1", "body": "from another mod"]],
                ])
                try home.transcript(directory: directory, id: id, lines: [peerUser(msg: "m1", body: "hello"), spoof, otherPlugin, peerQueued(msg: "m1", body: "hello")])
                guard let first = page(reader(home).open(sessionID: id, cwd: cwd)) else { return }
                #expect(texts(first.turns) == ["hello", "from another process", "from another mod"], "같은 msg_id라도 보낸 pid · 플러그인이 다르면 다른 메시지다 (같은 셋만 한 번)")
            }
        }

        /// 사용자가 친 줄에는 `origin`이 없다: `origin`이 있는데 peer가 아닌 줄은 사용자 말이 아니라 건너뛰고, 친 말(user)은 origin 없이 나온다
        @Test func aTypedUserTurnCarriesNoOriginAndOnlyPeerTurnsCarryAPeer() throws {
            try withHome { home in
                try home.transcript(directory: directory, id: id, lines: [L.user(id: id, text: "typed"), peerUser(msg: "m1", body: "hello"), L.assistant(id: id, text: "ok")])
                guard let page = page(reader(home).open(sessionID: id, cwd: cwd)) else { return }
                for turn in page.turns {
                    switch turn.kind {
                    case .user: #expect(texts([turn]) == ["typed"], "친 말은 `.user`로, 출처 값이 없다")
                    case .peer(_, let peer): #expect(peer.messageID == "m1")
                    default: break
                    }
                }
                #expect(page.turns.filter { if case .user = $0.kind { true } else { false } }.count == 1)
                #expect(page.turns.filter { if case .peer = $0.kind { true } else { false } }.count == 1)
            }
        }

        @Test func aPeerMessageAlreadyShownIsNotShownAgainByLiveUpdatesOrEarlierPages() throws {
            try withHome { home in
                let path = try home.transcript(directory: directory, id: id, lines: [L.user(id: id, text: "typed"), peerUser(msg: "m1", body: "hello"), peerQueued(msg: "m2", body: "second")])
                let reader = reader(home)
                guard let first = page(reader.open(sessionID: id, cwd: cwd)) else { return }
                #expect(texts(first.turns) == ["typed", "hello", "second"])
                // 라이브로 같은 msg_id가 다른 모양으로 또 온다
                try append(path, peerUser(msg: "m2", body: "second") + "\n" + peerQueued(msg: "m3", body: "third") + "\n")
                guard case .turns(let more, let cursor, _) = reader.newer(first.cursor) else { Issue.record("이어 읽기"); return }
                #expect(texts(more) == ["third"], "앞서 본 msg_id는 이어 읽기에서도 다시 오지 않는다")
                // 이어 읽기에서 처음 본 msg_id도 다음 이어 읽기에 기억이 이어진다
                try append(path, peerUser(msg: "m3", body: "third") + "\n" + peerQueued(msg: "m4", body: "fourth") + "\n")
                guard case .turns(let next, _, _) = reader.newer(cursor) else { Issue.record("두 번째 이어 읽기"); return }
                #expect(texts(next) == ["fourth"], "이어 읽기가 새로 본 msg_id를 커서에 남긴다")
            }
            try withHome { home in
                // 이전 쪽: 더 앞(오래된) 줄에 같은 msg_id가 있다
                let limits = ClaudeAppTranscriptReader.Limits(windowBytes: 1024, maxLineBytes: 512, maxTotalBytes: 1 << 20, pageTurns: 3, maxTextBytes: 4096, maxDetailBytes: 1024)
                try home.transcript(directory: directory, id: id, lines: [peerUser(msg: "m1", body: "old copy")] + conversation(8) + [peerQueued(msg: "m1", body: "new copy")])
                let reader = reader(home, limits: limits)
                guard case .page(var current) = reader.open(sessionID: id, cwd: cwd) else { return }
                var all = current.turns
                var rounds = 0
                while current.hasEarlier, rounds < 100, case .page(let next) = reader.earlier(current.cursor) {
                    all = next.turns + all
                    current = next
                    rounds += 1
                }
                #expect(texts(all).filter { $0 == "old copy" || $0 == "new copy" } == ["new copy"], "같은 msg_id는 이전 쪽에서도 한 번만 (보이는 쪽이 이긴다)")
            }
        }

        @Test func invisibleFormatCharactersAndLineSeparatorsAreStripped() throws {
            try withHome { home in
                let raw = "a\u{200B}b\u{00AD}c\u{2028}d\u{2029}e\u{E0067}f\u{2060}g\u{FEFF}h \u{FE0F}ok"
                try home.transcript(directory: directory, id: id, lines: [L.user(id: id, text: raw)])
                guard let page = page(reader(home).open(sessionID: id, cwd: cwd)) else { return }
                #expect(texts(page.turns) == ["abcdefgh \u{FE0F}ok"], "보이지 않는 서식 글자(폭 없는 공백 · 연한 하이픈 · 줄 구분 · 태그 · 단어 붙임)는 지운다 (변이 선택자는 둔다)")
            }
        }

        @Test func theJoinersThatBuildEmojiAndScriptsStay() throws {
            try withHome { home in
                let family = "👨\u{200D}👩\u{200D}👧"
                let persian = "می\u{200C}خواهم"
                try home.transcript(directory: directory, id: id, lines: [L.user(id: id, text: "\(family) \(persian)")])
                guard let page = page(reader(home).open(sessionID: id, cwd: cwd)) else { return }
                #expect(texts(page.turns) == ["\(family) \(persian)"], "이모지 · 문자를 잇는 ZWJ · ZWNJ는 둔다")
            }
        }

        /// 도구 줄은 있고 결과는 그 뒤 멀리 있다 (사이에 다른 줄이 많다). 열린 쪽 · 이전 쪽을 모두 모아 도구 줄을 찾는다
        private func farToolSetup(_ home: ExternalHome, limits: ClaudeAppTranscriptReader.Limits) throws -> (reader: ClaudeAppTranscriptReader, tool: ClaudeAppTurn, cursor: ClaudeAppTranscriptCursor)? {
            let lines = [L.tool(id: id, toolID: "toolu_far", name: "Bash", input: ["command": "ls", "description": "Far"])] + conversation(60, pad: 200) + [L.toolResult(id: id, toolID: "toolu_far", text: "FAR-RESULT")]
            try home.transcript(directory: directory, id: id, lines: lines)
            let reader = reader(home, limits: limits)
            guard case .page(let first) = reader.open(sessionID: id, cwd: cwd) else { Issue.record("열지 못했다"); return nil }
            var current = first
            var tools = first.turns.filter { $0.kind == .tool(name: "Bash", description: "Far") }
            var rounds = 0
            while current.hasEarlier, rounds < 200, case .page(let next) = reader.earlier(current.cursor) {
                tools += next.turns.filter { $0.kind == .tool(name: "Bash", description: "Far") }
                current = next
                rounds += 1
            }
            guard let tool = tools.first else { Issue.record("도구 줄을 찾지 못했다"); return nil }
            return (reader, tool, current.cursor)
        }

        @Test func aToolResultFarAfterItsToolLineIsFoundWithinTheTotalBudget() throws {
            try withHome { home in
                // 결과는 도구 줄 뒤 약 20 KiB: 창 하나(4 KiB)보다 멀지만 총량(64 KiB) 안
                let limits = ClaudeAppTranscriptReader.Limits(windowBytes: 4096, maxLineBytes: 2048, maxTotalBytes: 64 * 1024, pageTurns: 200, maxTextBytes: 4096, maxDetailBytes: 1024)
                guard let setup = try farToolSetup(home, limits: limits) else { return }
                #expect(setup.reader.detail(of: setup.tool, cursor: setup.cursor)?.result == "FAR-RESULT")
            }
        }

        @Test func aToolRowIsOnlyTheNameTheDescriptionAndAFileName() throws {
            try withHome { home in
                try install("desktop-basic.jsonl", in: home)
                guard let page = page(reader(home).open(sessionID: id, cwd: cwd)) else { return }
                let tools = page.turns.filter { if case .tool = $0.kind { true } else { false } }
                #expect(tools.count == 2)
                var dump = ""
                Swift.dump(tools, to: &dump)
                // 세션 보기 V1(DZ v2): 줄은 "이름 · 파일 이름"이다. 파일 이름(마지막 구성요소)만 남고 경로 · 명령 · 입력 칸 이름은 하나도 담지 않는다
                #expect(!dump.contains("ls -la") && !dump.contains("file_path") && !dump.contains("\"command\"") && !dump.contains("/Users/tester") && !dump.contains("proj/"), "경로 · 명령 · 입력 칸은 하나도 담지 않는다")
                #expect(tools.contains { $0.target == "README.md" }, "읽은 파일은 이름만")
                #expect(tools.filter { $0.target != nil }.count == 1, "명령 도구에는 파일 이름이 없다")
            }
        }

        @Test func userContentBlocksKeepOnlyTheTextAndAToolResultAloneIsNotATurn() throws {
            try withHome { home in
                let lines = [
                    F.json(["type": "user", "sessionId": id, "message": ["role": "user", "content": [["type": "text", "text": "part one"], ["type": "image", "source": ["type": "base64", "data": "AAAA"]], ["type": "tool_result", "tool_use_id": "t", "content": "hidden"], ["type": "text", "text": "part two"]]]]),
                    F.json(["type": "user", "sessionId": id, "message": ["role": "user", "content": [["type": "tool_result", "tool_use_id": "t", "content": "only a result"]]]]),
                    F.json(["type": "user", "sessionId": id, "message": ["role": "user", "content": "   \n\t  "]]),
                    F.json(["type": "assistant", "sessionId": id, "message": ["role": "assistant", "content": [["type": "text", "text": "  trimmed  "], ["type": "text", "text": ""]]]]),
                ]
                try home.transcript(directory: directory, id: id, lines: lines)
                guard let page = page(reader(home).open(sessionID: id, cwd: cwd)) else { return }
                #expect(page.turns.map(\.kind) == [.user("part one\npart two"), .assistant("trimmed")])
            }
        }

        // MARK: 줄이 깨졌을 때

        @Test func brokenLinesAreSkippedAndTheRestIsStillRead() throws {
            try withHome { home in
                try install("broken-lines.jsonl", as: F.uuid(0xD2), in: home)
                guard let page = page(reader(home).open(sessionID: F.uuid(0xD2), cwd: cwd)) else { return }
                #expect(texts(page.turns) == ["before", "wrong flag types are ignored", "after"])
                #expect(page.turns.map(\.kind).contains(.tool(name: "Edit", description: nil)), "입력이 객체가 아니어도 도구 이름은 남는다")
                #expect(page.turns[1].timestamp == nil, "읽을 수 없는 시각은 없는 것")
                #expect(page.skippedLines == 4, "깨진 줄 셋과 객체가 아닌 줄 하나")
            }
        }

        @Test func aBrokenLineThatCannotBeAConversationLineIsNotEvenLookedAtOrCounted() throws {
            try withHome { home in
                // 시스템 프롬프트 · 계정 줄이 끊겼다: `user` · `assistant` · `queued_command` 글자가 없으니 디코딩하지 않는다 (건너뛴 줄로도 세지 않는다)
                let lines = [
                    L.user(id: id, text: "before"),
                    "{\"type\":\"api-request-blob\",\"blob\":\"\(A.systemPromptSentinel) cut off here",
                    "{\"type\":\"attachment\",\"attachment\":{\"type\":\"session_context\",\"email\":\"\(A.emailSentinel)",
                    L.assistant(id: id, text: "after"),
                ]
                try home.transcript(directory: directory, id: id, lines: lines)
                guard let page = page(reader(home).open(sessionID: id, cwd: cwd)) else { return }
                #expect(texts(page.turns) == ["before", "after"])
                #expect(page.skippedLines == 0)
            }
        }

        @Test func aLineThatIsNotValidUTF8IsSkipped() throws {
            try withHome { home in
                let dir = try home.directory(directory)
                var data = Data((L.user(id: id, text: "first") + "\n").utf8)
                data.append(Data("{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":\"bad ".utf8))
                data.append(contentsOf: [0xFF, 0xFE, 0xC0])
                data.append(Data("\"}}\n".utf8))
                data.append(Data((L.assistant(id: id, text: "last") + "\n").utf8))
                try data.write(to: URL(fileURLWithPath: dir + "/" + id + ".jsonl"))
                guard let page = page(reader(home).open(sessionID: id, cwd: cwd)) else { return }
                #expect(texts(page.turns) == ["first", "last"])
                #expect(page.skippedLines == 1)
            }
        }

        @Test func textThatLooksLikeALinkOrCodeIsPlainTextAndBidiOrControlCharactersAreStripped() throws {
            try withHome { home in
                let raw = "open tf://open?x=1 and [click](https://evil.example/a) <script>alert(1)</script>\u{202E}gnp.exe\u{2066}x\u{2069} nul\u{0}bell\u{7}end\nsecond line\ttab"
                try home.transcript(directory: directory, id: id, lines: [L.user(id: id, text: raw), L.assistant(id: id, text: raw)])
                guard let page = page(reader(home).open(sessionID: id, cwd: cwd)) else { return }
                let expected = "open tf://open?x=1 and [click](https://evil.example/a) <script>alert(1)</script>gnp.exe" + "x nul" + "bell" + "end\nsecond line\ttab"
                #expect(texts(page.turns) == [expected, expected], "링크 · 태그는 글자 그대로, 방향 바꿈 · 제어 글자는 지운다")
                for turn in page.turns {
                    #expect(turn.description == turn.debugDescription)
                    #expect(!turn.description.contains("tf://"))
                }
            }
        }

        @Test func aMetaUserRecordThatIsNotAPeerIsNotShown() throws {
            try withHome { home in
                let meta = F.json(["type": "user", "isMeta": true, "sessionId": id, "message": ["role": "user", "content": A.metaSentinel]])
                try home.transcript(directory: directory, id: id, lines: [L.user(id: id, text: "visible"), meta, L.assistant(id: id, text: "answer")])
                guard let page = page(reader(home).open(sessionID: id, cwd: cwd)) else { return }
                #expect(texts(page.turns) == ["visible", "answer"])
            }
        }

        @Test func aSubagentRecordIsNotShown() throws {
            try withHome { home in
                let sidechain = F.json(["type": "assistant", "isSidechain": true, "sessionId": id, "message": ["role": "assistant", "content": [["type": "text", "text": A.sidechainSentinel]]]])
                let sideUser = F.json(["type": "user", "isSidechain": true, "sessionId": id, "message": ["role": "user", "content": A.sidechainSentinel]])
                try home.transcript(directory: directory, id: id, lines: [L.user(id: id, text: "visible"), sidechain, sideUser, L.assistant(id: id, text: "answer")])
                guard let page = page(reader(home).open(sessionID: id, cwd: cwd)) else { return }
                #expect(texts(page.turns) == ["visible", "answer"])
            }
        }

        @Test func recordsOfAnotherSessionAndWithoutASessionIDAreHandledByTheIDRule() throws {
            try withHome { home in
                let other = F.uuid(0xEE)
                let lines = [
                    L.user(id: other, text: "other session"),
                    F.json(["type": "user", "message": ["role": "user", "content": "no session id"]]),
                    L.user(id: id, text: "mine"),
                ]
                try home.transcript(directory: directory, id: id, lines: lines)
                guard let page = page(reader(home).open(sessionID: id, cwd: cwd)) else { return }
                #expect(texts(page.turns) == ["no session id", "mine"], "다른 id를 단 줄만 뺀다")
            }
        }

        // MARK: 어느 파일을 여는가

        @Test func onlyTheOpenedSessionsTranscriptIsReadAndNothingElseIsListedOrOpened() throws {
            try withHome { home in
                let path = try install("desktop-basic.jsonl", in: home)
                let other = F.uuid(0xD3)
                try home.transcript(directory: directory, id: other, lines: [L.user(id: other, text: "SENTINEL-OTHER-SESSION-FILE")])
                try home.registry(pid: 100, json: A.registry(pid: 100, id: id))
                for decoy in [".credentials.json", "settings.json"] { try "SECRET".write(toFile: home.claude + "/" + decoy, atomically: false, encoding: .utf8) }
                let recording = RecordingFileSystem()
                guard let page = page(reader(home, fileSystem: recording.fileSystem).open(sessionID: id, cwd: cwd)) else { return }
                #expect(!page.turns.isEmpty)
                #expect(Set(recording.reads.map(\.path)) == [path], "읽은 파일은 그 세션의 기록 하나")
                #expect(recording.listed.isEmpty, "폴더를 알면 나열하지 않는다")
                #expect(!recording.statted.contains { $0.hasSuffix(other + ".jsonl") || $0.contains("/sessions") || $0.contains(".credentials") })
            }
        }

        @Test func withoutAFolderItListsOnlyTheProjectDirectoriesAndReadsOnlyThatTranscript() throws {
            try withHome { home in
                let path = try install("desktop-basic.jsonl", in: home, directory: "-Users-tester-elsewhere")
                let other = F.uuid(0xD3)
                try home.transcript(directory: "-Users-tester-elsewhere", id: other, lines: [L.user(id: other, text: "other")])
                try home.transcript(directory: "-Users-tester-third", id: F.uuid(0xD4), lines: [L.user(id: F.uuid(0xD4), text: "third")])
                for startCwd in [nil, "/Users/tester/proj"] as [String?] {
                    let recording = RecordingFileSystem()
                    guard let page = page(reader(home, fileSystem: recording.fileSystem).open(sessionID: id, cwd: startCwd)) else { return }
                    #expect(page.turns.count == 10, "\(startCwd ?? "nil"): 대화 줄 9 + 글 없는 경계 1")
                    #expect(Set(recording.reads.map(\.path)) == [path])
                    #expect(Set(recording.listed).isSubset(of: [home.projects]), "나열은 projects 한 곳")
                }
            }
        }

        @Test func ifTheSameIDIsInTwoDirectoriesTheNewestIsRead() throws {
            try withHome { home in
                let old = try home.transcript(directory: "-Users-tester-old", id: id, lines: [L.user(id: id, text: "old copy")], modified: Date(timeIntervalSince1970: 1_700_000_000))
                let new = try home.transcript(directory: "-Users-tester-new", id: id, lines: [L.user(id: id, text: "new copy")], modified: Date(timeIntervalSince1970: 1_800_000_000))
                #expect(old != new)
                guard let page = page(reader(home).open(sessionID: id, cwd: nil)) else { return }
                #expect(texts(page.turns) == ["new copy"])
            }
        }

        /// 열 수 없다고 하면서 **읽기도 하지 않았다**: 읽기 쪽의 `O_NOFOLLOW` · 경로 확인에만 기대지 않고 찾는 쪽에서 먼저 막는다
        private func expectUnreadableWithoutReading(_ home: ExternalHome, cwd: String?, sourceLocation: SourceLocation = #_sourceLocation) {
            let recording = RecordingFileSystem()
            #expect(reader(home, fileSystem: recording.fileSystem).open(sessionID: id, cwd: cwd) == .unreadable, sourceLocation: sourceLocation)
            #expect(recording.reads.isEmpty, "읽기 전에 막는다", sourceLocation: sourceLocation)
        }

        @Test func aLinkedOrForeignOrNonRegularTranscriptIsUnreadable() throws {
            try withHome { home in
                // 기록 파일이 기호 링크
                let outside = home.root + "/outside.jsonl"
                try (L.user(id: id, text: "SENTINEL-OUTSIDE") + "\n").write(toFile: outside, atomically: false, encoding: .utf8)
                let dir = try home.directory(directory)
                try home.link(dir + "/" + id + ".jsonl", to: outside)
                expectUnreadableWithoutReading(home, cwd: cwd)
                expectUnreadableWithoutReading(home, cwd: nil)
            }
            try withHome { home in
                // 기록 파일 자리가 폴더
                try FileManager.default.createDirectory(atPath: try home.directory(directory) + "/" + id + ".jsonl", withIntermediateDirectories: true)
                expectUnreadableWithoutReading(home, cwd: cwd)
            }
            try withHome { home in
                // 프로젝트 디렉터리가 기호 링크 (밖의 폴더를 가리킨다)
                let real = home.root + "/real-dir"
                try FileManager.default.createDirectory(atPath: real, withIntermediateDirectories: true)
                try (L.user(id: id, text: "SENTINEL-LINKED-DIR") + "\n").write(toFile: real + "/" + id + ".jsonl", atomically: false, encoding: .utf8)
                try home.link(home.projects + "/" + directory, to: real)
                expectUnreadableWithoutReading(home, cwd: cwd)
                expectUnreadableWithoutReading(home, cwd: nil)
            }
            try withHome { home in
                // `projects`가 기호 링크
                let real = home.root + "/real-projects"
                try FileManager.default.createDirectory(atPath: real + "/" + directory, withIntermediateDirectories: true)
                try (L.user(id: id, text: "SENTINEL-LINKED-PROJECTS") + "\n").write(toFile: real + "/" + directory + "/" + id + ".jsonl", atomically: false, encoding: .utf8)
                try FileManager.default.removeItem(atPath: home.projects)
                try home.link(home.projects, to: real)
                expectUnreadableWithoutReading(home, cwd: cwd)
            }
        }

        @Test func aTranscriptOwnedBySomeoneElseIsUnreadable() throws {
            try withHome { home in
                try install("desktop-basic.jsonl", in: home)
                let base = ExternalSessionFileSystem.live
                let foreign = ExternalSessionFileSystem(
                    userID: base.userID, realpath: base.realpath,
                    lstat: { path in
                        var entry = base.lstat(path)
                        if path.hasSuffix(".jsonl") { entry?.owner = base.userID &+ 1 }
                        return entry
                    },
                    list: base.list, read: base.read
                )
                #expect(reader(home, fileSystem: foreign).open(sessionID: id, cwd: cwd) == .unreadable)
                #expect(page(reader(home).open(sessionID: id, cwd: cwd)) != nil, "대조: 내 파일이면 읽는다")
            }
        }

        @Test func aMissingTranscriptOrAMissingClaudeFolderIsUnreadable() throws {
            try withHome { home in
                #expect(reader(home).open(sessionID: id, cwd: cwd) == .unreadable)
                let none = ClaudeAppTranscriptReader(claudeDirectory: home.root + "/nope")
                #expect(none.open(sessionID: id, cwd: cwd) == .unreadable)
            }
        }

        @Test func anIDThatIsNotACanonicalLowercaseUUIDTouchesNothing() throws {
            try withHome { home in
                try install("desktop-basic.jsonl", in: home)
                for bad in ["", id.uppercased(), "../" + id, id + "\n", id + ".jsonl", "*", "5e5e5e5e00004000800000000000d1", String(id.dropLast()), "-r", "../../etc/passwd"] {
                    let recording = RecordingFileSystem()
                    #expect(reader(home, fileSystem: recording.fileSystem).open(sessionID: bad, cwd: cwd) == .unreadable, "\(bad)")
                    #expect(recording.statted.isEmpty && recording.listed.isEmpty && recording.reads.isEmpty && recording.resolved.isEmpty, "파일 시스템을 만지지 않는다: \(bad)")
                }
            }
        }

        // MARK: 상한 · 쪽

        @Test func theStandardLimitsAreTheContractNumbers() {
            let limits = ClaudeAppTranscriptReader.Limits.standard
            #expect(limits.windowBytes == 2 * 1024 * 1024, "처음 열 때 꼬리 2 MiB")
            #expect(limits.maxLineBytes == 1024 * 1024, "한 줄 1 MiB")
            #expect(limits.pageTurns == 200, "꼬리 200개")
            #expect(limits.maxTotalBytes == 16 * 1024 * 1024)
            #expect(limits.maxTextBytes == 32 * 1024)
            #expect(limits.maxDetailBytes == 16 * 1024)
        }

        /// 숫자만이 아니라 동작으로: 한 줄이 **정확히** 1 MiB면 읽고, 한 바이트 넘으면 통째로 건너뛴다 (표준 상한 그대로)
        @Test func theOneMiBLineCapIsExactlyAtTheBoundary() throws {
            try withHome { home in
                let overhead = L.assistant(id: id, text: "").utf8.count
                let exact = L.assistant(id: id, text: String(repeating: "a", count: (1 << 20) - overhead))
                let over = L.assistant(id: id, text: String(repeating: "a", count: (1 << 20) - overhead + 1))
                #expect(exact.utf8.count == 1 << 20 && over.utf8.count == (1 << 20) + 1)
                try home.transcript(directory: directory, id: id, lines: [L.user(id: id, text: "start"), exact])
                guard let atCap = page(reader(home).open(sessionID: id, cwd: cwd)) else { return }
                #expect(texts(atCap.turns).count == 2 && atCap.skippedLines == 0, "정확히 1 MiB는 읽는다")
                try FileManager.default.removeItem(atPath: home.projects + "/" + directory + "/" + id + ".jsonl")
                try home.transcript(directory: directory, id: id, lines: [L.user(id: id, text: "start"), over])
                guard let overCap = page(reader(home).open(sessionID: id, cwd: cwd)) else { return }
                #expect(texts(overCap.turns) == ["start"] && overCap.skippedLines == 1, "1 MiB + 1바이트는 건너뛴다")
            }
        }

        @Test func aLongConversationShowsTheLastTwoHundredAndEarlierPagesFillInTheRestWithoutGapsOrRepeats() throws {
            try withHome { home in
                try home.transcript(directory: directory, id: id, lines: conversation(450))
                let reader = reader(home)
                guard let first = page(reader.open(sessionID: id, cwd: cwd)) else { return }
                #expect(first.turns.count == 200)
                #expect(texts(first.turns).first == "turn 250" && texts(first.turns).last == "turn 449")
                #expect(first.hasEarlier)
                guard let second = page(reader.earlier(first.cursor)) else { return }
                #expect(texts(second.turns).first == "turn 50" && texts(second.turns).last == "turn 249" && second.turns.count == 200)
                #expect(second.hasEarlier)
                guard let third = page(reader.earlier(second.cursor)) else { return }
                #expect(texts(third.turns).first == "turn 0" && texts(third.turns).last == "turn 49" && third.turns.count == 50)
                #expect(!third.hasEarlier, "처음까지 읽었다")
                let all = third.turns + second.turns + first.turns
                #expect(texts(all) == (0..<450).map { "turn \($0)" })
                #expect(Set(all.map(\.id)).count == 450, "쪽을 넘어도 id가 같은 줄은 같은 id, 다른 줄은 다른 id")
                guard let done = page(reader.earlier(third.cursor)) else { return }
                #expect(done.turns.isEmpty && !done.hasEarlier)
            }
        }

        @Test func theFirstOpenReadsOnlyTheTailWindowOfALargeFile() throws {
            try withHome { home in
                // 약 5 MiB: 한 줄 약 330바이트
                try home.transcript(directory: directory, id: id, lines: conversation(16_000, pad: 220))
                let recording = RecordingFileSystem()
                guard let page = page(reader(home, fileSystem: recording.fileSystem).open(sessionID: id, cwd: cwd)) else { return }
                #expect(recording.reads.count == 1)
                #expect(recording.bytesRead <= 2 * 1024 * 1024, "꼬리 2 MiB까지만")
                #expect((recording.reads.first?.offset ?? 0) > 0, "파일 머리부터 읽지 않는다")
                #expect(page.turns.count == 200 && texts(page.turns).last?.hasPrefix("turn 15999") == true)
                #expect(page.hasEarlier)
            }
        }

        @Test func theTotalReadCapStopsShowEarlierEvenThoughMoreFileRemains() throws {
            try withHome { home in
                // 총량(200 KiB)이 창(64 KiB)의 배수가 아니다: 마지막 읽기는 남은 만큼만 읽어야 상한을 넘지 않는다
                let limits = ClaudeAppTranscriptReader.Limits(windowBytes: 64 * 1024, maxLineBytes: 16 * 1024, maxTotalBytes: 200 * 1024, pageTurns: 50, maxTextBytes: 4096, maxDetailBytes: 1024)
                try home.transcript(directory: directory, id: id, lines: conversation(3000, pad: 200))
                let recording = RecordingFileSystem()
                let reader = reader(home, fileSystem: recording.fileSystem, limits: limits)
                guard var current = page(reader.open(sessionID: id, cwd: cwd)) else { return }
                var pages = 1
                while current.hasEarlier, pages < 100 {
                    guard let next = page(reader.earlier(current.cursor)) else { return }
                    current = next
                    pages += 1
                    #expect(!(current.cursor.coveredBytes >= limits.maxTotalBytes && current.hasEarlier), "상한에 닿은 쪽은 \"Show earlier\"를 내지 않는다")
                }
                #expect(pages < 100, "끝이 난다")
                #expect(!current.hasEarlier)
                // 상한은 **얼마나 멀리 거슬러 갔나**로 센다 (같은 바이트를 다시 읽은 것은 세지 않는다): 한 번에 읽는 것은 창 하나까지
                let size = Int((try FileManager.default.attributesOfItem(atPath: current.cursor.path)[.size] as? NSNumber)?.int64Value ?? -1)
                #expect(current.cursor.coveredBytes == size - Int(current.cursor.earliestOffset), "거슬러 간 거리 = 파일 끝 − 가장 앞 줄의 시작")
                #expect(current.cursor.coveredBytes <= limits.maxTotalBytes, "마지막 읽기는 남은 만큼만 거슬러 상한을 넘지 않는다")
                #expect(recording.reads.allSatisfy { $0.returned <= limits.windowBytes }, "한 번의 읽기는 창 하나까지")
                #expect(current.cursor.earliestOffset > 0, "상한 때문에 멈췄지 파일 처음까지 읽은 것이 아니다")
            }
        }

        @Test func aPageThatReachesTheCapOrIsEmptyDoesNotMeanTheHistoryEnded() throws {
            try withHome { home in
                // 줄이 모두 건너뛰는 줄(너무 큼)이어도 이전 쪽은 빈 쪽을 줄 수 있다: 빈 쪽 + hasEarlier는 끝이 아니다
                let limits = ClaudeAppTranscriptReader.Limits(windowBytes: 4096, maxLineBytes: 512, maxTotalBytes: 1 << 20, pageTurns: 200, maxTextBytes: 4096, maxDetailBytes: 1024)
                try home.transcript(directory: directory, id: id, lines: conversation(2) + conversation(20, pad: 600) + conversation(2))
                let reader = reader(home, limits: limits)
                guard let first = page(reader.open(sessionID: id, cwd: cwd)) else { return }
                guard let second = page(reader.earlier(first.cursor)) else { return }
                #expect(second.turns.isEmpty && second.hasEarlier, "건너뛴 줄만 있는 창: 비었지만 앞이 더 있다")
                var current = second
                var rounds = 0
                var collected = first.turns
                while current.hasEarlier, rounds < 200, case .page(let next) = reader.earlier(current.cursor) {
                    collected = next.turns + collected
                    current = next
                    rounds += 1
                }
                #expect(texts(collected).first == "turn 0" && texts(collected).count == 4, "계속 누르면 앞의 읽을 수 있는 줄에 닿는다")
            }
        }

        @Test func aWindowSmallerThanALineStillEndsAndNeverLoopsOrCrashes() throws {
            try withHome { home in
                // 창(256바이트)이 한 줄(약 330바이트)보다 작다: 읽을 수 있는 줄은 없지만 이전 쪽을 계속 눌러도 끝이 난다
                let limits = ClaudeAppTranscriptReader.Limits(windowBytes: 256, maxLineBytes: 4096, maxTotalBytes: 1 << 20, pageTurns: 200, maxTextBytes: 4096, maxDetailBytes: 1024)
                try home.transcript(directory: directory, id: id, lines: conversation(40, pad: 60))
                let reader = reader(home, limits: limits)
                guard var current = page(reader.open(sessionID: id, cwd: cwd)) else { return }
                var calls = 0
                while current.hasEarlier, calls < 10_000 {
                    guard case .page(let next) = reader.earlier(current.cursor) else { Issue.record("이전 쪽을 읽지 못했다"); return }
                    #expect(next.cursor.earliestOffset <= current.cursor.earliestOffset, "뒤로만 간다")
                    current = next
                    calls += 1
                }
                #expect(calls < 10_000 && !current.hasEarlier)
                // 아주 작은 창(3바이트)도 마찬가지다
                let tiny = ClaudeAppTranscriptReader.Limits(windowBytes: 3, maxLineBytes: 4096, maxTotalBytes: 1 << 20, pageTurns: 200, maxTextBytes: 4096, maxDetailBytes: 1024)
                let small = self.reader(home, limits: tiny)
                guard var currentTiny = page(small.open(sessionID: id, cwd: cwd)) else { return }
                var tinyCalls = 0
                while currentTiny.hasEarlier, tinyCalls < 100_000 {
                    guard case .page(let next) = small.earlier(currentTiny.cursor) else { Issue.record("이전 쪽을 읽지 못했다"); return }
                    #expect(next.cursor.earliestOffset <= currentTiny.cursor.earliestOffset)
                    currentTiny = next
                    tinyCalls += 1
                }
                #expect(tinyCalls < 100_000 && !currentTiny.hasEarlier)
            }
        }

        @Test func aWindowThatStartsInTheMiddleOfALineNeverMakesATurnFromTheFragment() throws {
            try withHome { home in
                let limits = ClaudeAppTranscriptReader.Limits(windowBytes: 4096, maxLineBytes: 2048, maxTotalBytes: 1 << 20, pageTurns: 200, maxTextBytes: 4096, maxDetailBytes: 1024)
                let path = try home.transcript(directory: directory, id: id, lines: conversation(200, pad: 60))
                let reader = reader(home, limits: limits)
                guard let first = page(reader.open(sessionID: id, cwd: cwd)) else { return }
                var pages = [first]
                while let last = pages.last, last.hasEarlier, pages.count < 100, let next = page(reader.earlier(last.cursor)) { pages.append(next) }
                #expect(pages.allSatisfy { $0.skippedLines == 0 }, "조각은 건너뛴 줄로도 세지 않는다")
                let all = pages.reversed().flatMap(\.turns)
                #expect(texts(all).allSatisfy { $0.hasPrefix("turn ") && $0.hasSuffix(String(repeating: "x", count: 60)) }, "온전한 줄만")
                #expect(Set(all.map(\.id)).count == all.count)
                // 각 쪽이 시작하는 자리는 줄의 시작이다 (앞 바이트가 개행)
                let bytes = try Data(contentsOf: URL(fileURLWithPath: path))
                for page in pages where page.cursor.earliestOffset > 0 { #expect(bytes[Int(page.cursor.earliestOffset) - 1] == 0x0A) }
            }
        }

        @Test func aVeryLongLineIsParsedButItsTextIsCappedAndAnOversizedLineIsSkippedWholly() throws {
            try withHome { home in
                let big = String(repeating: "a", count: 332 * 1024)
                let huge = String(repeating: "b", count: 1_200_000)
                try home.transcript(directory: directory, id: id, lines: [L.user(id: id, text: "start"), L.assistant(id: id, text: big), L.assistant(id: id, text: huge), L.user(id: id, text: "end")])
                guard let page = page(reader(home).open(sessionID: id, cwd: cwd)) else { return }
                #expect(texts(page.turns).count == 3, "너무 큰 줄 하나만 빠진다")
                #expect(texts(page.turns).first == "start" && texts(page.turns).last == "end")
                let capped = page.turns[1]
                #expect(capped.truncated)
                if case .assistant(let text) = capped.kind { #expect(text.utf8.count == 32 * 1024 && text.allSatisfy { $0 == "a" }) } else { Issue.record("assistant가 아니다") }
                #expect(page.skippedLines == 1)
                #expect(!page.turns.first!.truncated)
            }
        }

        @Test func aCappedTextIsCutOnACharacterBoundary() throws {
            try withHome { home in
                let text = String(repeating: "한", count: 20_000) + "🙂🙂🙂"
                try home.transcript(directory: directory, id: id, lines: [L.assistant(id: id, text: text)])
                guard let page = page(reader(home).open(sessionID: id, cwd: cwd)), case .assistant(let kept)? = page.turns.first?.kind else { return }
                #expect(kept.utf8.count <= 32 * 1024 && kept.utf8.count > 32 * 1024 - 4)
                #expect(kept.allSatisfy { $0 == "한" } && !kept.contains("\u{FFFD}"))
                #expect(page.turns.first?.truncated == true)
            }
        }

        // MARK: 이어 읽기

        @Test func newerReturnsOnlyWhatWasAppendedAndAPartialLineWaitsForItsNewline() throws {
            try withHome { home in
                let path = try home.transcript(directory: directory, id: id, lines: conversation(3))
                let reader = reader(home)
                guard let first = page(reader.open(sessionID: id, cwd: cwd)) else { return }
                #expect(texts(first.turns) == ["turn 0", "turn 1", "turn 2"])
                guard case .turns(let none, let sameCursor, let more) = reader.newer(first.cursor) else { Issue.record("무변경은 turns"); return }
                #expect(none.isEmpty && !more && sameCursor.nextOffset == first.cursor.nextOffset)

                try append(path, L.user(id: id, text: "turn 3") + "\n")
                guard case .turns(let one, let cursor, _) = reader.newer(first.cursor) else { Issue.record("새 줄"); return }
                #expect(texts(one) == ["turn 3"])
                #expect(cursor.nextOffset == Int64((try FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.int64Value ?? -1))
                guard case .turns(let again, _, _) = reader.newer(cursor) else { Issue.record("무변경"); return }
                #expect(again.isEmpty, "같은 줄을 두 번 주지 않는다")

                // 쓰는 중인 줄: 개행이 오기 전에는 소비하지 않는다
                let half = L.assistant(id: id, text: "turn 4")
                try append(path, String(half.prefix(40)))
                guard case .turns(let partial, let waiting, _) = reader.newer(cursor) else { Issue.record("반쪽 줄"); return }
                #expect(partial.isEmpty && waiting.nextOffset == cursor.nextOffset)
                try append(path, String(half.dropFirst(40)) + "\n")
                guard case .turns(let done, _, _) = reader.newer(waiting) else { Issue.record("완성된 줄"); return }
                #expect(texts(done) == ["turn 4"])
            }
        }

        @Test func aLineThatIsTooLongToKeepIsDiscardedUpToItsNewlineEvenAcrossReads() throws {
            try withHome { home in
                let limits = ClaudeAppTranscriptReader.Limits(windowBytes: 4096, maxLineBytes: 1024, maxTotalBytes: 1 << 20, pageTurns: 200, maxTextBytes: 4096, maxDetailBytes: 1024)
                let path = try home.transcript(directory: directory, id: id, lines: conversation(2))
                let reader = reader(home, limits: limits)
                guard let first = page(reader.open(sessionID: id, cwd: cwd)) else { return }
                var cursor = first.cursor
                // 개행 없이 3 KiB가 먼저 쓰인다 (한 줄의 앞부분)
                try append(path, "{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":\"" + String(repeating: "z", count: 3000))
                guard case .turns(let a, let c1, _) = reader.newer(cursor) else { Issue.record("앞부분"); return }
                #expect(a.isEmpty); cursor = c1
                try append(path, String(repeating: "z", count: 3000))
                guard case .turns(let b, let c2, _) = reader.newer(cursor) else { Issue.record("가운데"); return }
                #expect(b.isEmpty); cursor = c2
                // 그 줄의 끝: 남은 조각이 우연히 온전한 기록처럼 생겼다 (줄이 상한을 넘었으니 그 줄의 어느 조각도 기록이 아니다). 그 다음 줄이 온다
                try append(path, L.assistant(id: id, text: "SENTINEL-FRAGMENT-OF-A-LONG-LINE") + "\n" + L.assistant(id: id, text: "after the long line") + "\n")
                var collected: [ClaudeAppTurn] = []
                for _ in 0..<10 {
                    guard case .turns(let t, let next, let more) = reader.newer(cursor) else { Issue.record("끝"); return }
                    collected += t; cursor = next
                    if !more { break }
                }
                #expect(texts(collected) == ["after the long line"], "긴 줄의 조각은 줄로 읽지 않는다")
            }
        }

        @Test func moreThanOneWindowOfNewLinesIsReturnedInPartsWithHasMore() throws {
            try withHome { home in
                let limits = ClaudeAppTranscriptReader.Limits(windowBytes: 4096, maxLineBytes: 2048, maxTotalBytes: 1 << 20, pageTurns: 200, maxTextBytes: 4096, maxDetailBytes: 1024)
                let path = try home.transcript(directory: directory, id: id, lines: conversation(2))
                let reader = reader(home, limits: limits)
                guard let first = page(reader.open(sessionID: id, cwd: cwd)) else { return }
                let more = conversation(100, pad: 60).enumerated().map { "\($0.element)\n" }.joined()
                try append(path, more)
                var cursor = first.cursor
                var collected: [ClaudeAppTurn] = []
                var calls = 0
                while calls < 100 {
                    guard case .turns(let t, let next, let hasMore) = reader.newer(cursor) else { Issue.record("이어 읽기"); return }
                    collected += t; cursor = next; calls += 1
                    if !hasMore { break }
                }
                #expect(calls > 1, "한 번에 창 하나만")
                #expect(collected.count == 100 && Set(collected.map(\.id)).count == 100)
                #expect(texts(collected).first?.hasPrefix("turn 0 ") == true && texts(collected).last?.hasPrefix("turn 99 ") == true)
            }
        }

        @Test func aShrunkOrReplacedFileIsAResetAndADeletedOneIsUnreadable() throws {
            try withHome { home in
                let path = try home.transcript(directory: directory, id: id, lines: conversation(10))
                let log = RecordingLog()
                let reader = reader(home, log: log)
                guard let first = page(reader.open(sessionID: id, cwd: cwd)) else { return }
                // 줄었다 (압축으로 다시 쓰임)
                try (conversation(2).joined(separator: "\n") + "\n").write(toFile: path, atomically: false, encoding: .utf8)
                #expect(reader.newer(first.cursor) == .reset)
                // 같은 자리에 새 파일 (더 커졌지만 만든 시각이 다르다)
                try FileManager.default.removeItem(atPath: path)
                try (conversation(40).joined(separator: "\n") + "\n").write(toFile: path, atomically: false, encoding: .utf8)
                try FileManager.default.setAttributes([.creationDate: Date(timeIntervalSinceNow: 3600)], ofItemAtPath: path)
                #expect(reader.newer(first.cursor) == .reset)
                try FileManager.default.removeItem(atPath: path)
                #expect(reader.newer(first.cursor) == .unreadable)
                #expect(log.events.map { $0.fields["result"] } == [.code("ok"), .code("reset"), .code("reset"), .code("unreadable")])
            }
        }

        // MARK: 펼칠 때만 도구 본문

        @Test func aToolsInputAndResultAreReadOnlyWhenAskedAndAreCapped() throws {
            try withHome { home in
                try install("desktop-basic.jsonl", in: home)
                let reader = reader(home)
                guard let page = page(reader.open(sessionID: id, cwd: cwd)) else { return }
                let bash = try #require(page.turns.first { $0.kind == .tool(name: "Bash", description: "List files") })
                let detail = try #require(reader.detail(of: bash, cursor: page.cursor))
                #expect(detail.input.contains(A.commandSentinel) && detail.input.contains("\"command\"") && detail.input.contains("List files"))
                #expect(detail.result?.contains(A.resultSentinel) == true && detail.result?.contains("file-a") == true)
                #expect(!detail.truncated)
                // 결과가 아직 없는 도구 줄: 입력만
                let read = try #require(page.turns.first { $0.kind == .tool(name: "Read", description: nil) })
                let noResult = try #require(reader.detail(of: read, cursor: page.cursor))
                #expect(noResult.input.contains("README.md") && noResult.result == nil)
                // 도구 줄이 아니면 없다
                #expect(reader.detail(of: page.turns[0], cursor: page.cursor) == nil)
            }
        }

        @Test func aHugeToolResultIsCappedAndATamperedOrStaleTurnGivesNothing() throws {
            try withHome { home in
                let limits = ClaudeAppTranscriptReader.Limits(windowBytes: 64 * 1024, maxLineBytes: 32 * 1024, maxTotalBytes: 1 << 20, pageTurns: 200, maxTextBytes: 4096, maxDetailBytes: 1024)
                let path = try home.transcript(
                    directory: directory, id: id,
                    lines: [L.tool(id: id, toolID: "toolu_big", name: "Bash", input: ["command": "cat big", "description": "Print"]), L.toolResult(id: id, toolID: "toolu_big", text: String(repeating: "r", count: 20_000)), L.user(id: id, text: "next")]
                )
                let reader = reader(home, limits: limits)
                guard let page = page(reader.open(sessionID: id, cwd: cwd)) else { return }
                let tool = try #require(page.turns.first)
                let detail = try #require(reader.detail(of: tool, cursor: page.cursor))
                #expect((detail.result?.utf8.count ?? 0) <= 1024 && detail.truncated)
                // 다른 줄을 가리키게 바꾼 줄(도구 줄이 아닌 자리) · 없는 도구 id
                var tampered = tool
                tampered.lineOffset = page.turns[1].lineOffset
                #expect(reader.detail(of: tampered, cursor: page.cursor) == nil)
                var unknownID = tool
                unknownID.toolUseID = "toolu_missing"
                #expect(reader.detail(of: unknownID, cursor: page.cursor) == nil)
                var beyond = tool
                beyond.lineOffset = 10_000_000
                #expect(reader.detail(of: beyond, cursor: page.cursor) == nil)
                // 파일이 바뀌면(만든 시각이 다르면) 옛 위치를 믿지 않는다
                // (같은 자리에 같은 도구 id의 줄이 있는 다른 파일이어도 — 다른 파일의 본문을 이 세션의 것으로 주지 않는다)
                try FileManager.default.removeItem(atPath: path)
                try (L.tool(id: id, toolID: "toolu_big", name: "Bash", input: ["command": "REPLACED-FILE-COMMAND", "description": "Print"]) + "\n").write(toFile: path, atomically: false, encoding: .utf8)
                try FileManager.default.setAttributes([.creationDate: Date(timeIntervalSinceNow: 3600)], ofItemAtPath: path)
                #expect(reader.detail(of: tool, cursor: page.cursor) == nil)
            }
        }

        // MARK: 관찰 · 값의 모양

        @Test func theLogCarriesOnlyAFixedResultCodeNeverAPathTextOrID() throws {
            try withHome { home in
                try install("desktop-basic.jsonl", in: home)
                let log = RecordingLog()
                let reader = reader(home, log: log)
                _ = reader.open(sessionID: id, cwd: cwd)
                _ = reader.open(sessionID: F.uuid(0xD9), cwd: cwd)
                _ = reader.open(sessionID: "not-an-id", cwd: cwd)
                #expect(log.events.map(\.event) == ["claude_app_transcript", "claude_app_transcript", "claude_app_transcript"])
                #expect(log.events.map { $0.fields["result"] } == [.code("ok"), .code("unreadable"), .code("unreadable")])
                for event in log.events {
                    #expect(Set(event.fields.keys) == ["result"])
                    let text = String(describing: event.fields)
                    #expect(!text.contains(id) && !text.contains(home.root) && !text.contains("Please list"))
                }
            }
        }

        /// 화면 · 로그에 찍힐 수 있는 모든 값(커튼 · 쪽 · 줄 · 출처 · 펼친 본문 · 갱신)이 글 · 경로 · id · pid · 도구 본문을 찍지 않는다
        @Test func everyValueThatCanBePrintedHidesTextPathIDAndToolBodies() throws {
            try withHome { home in
                try install("desktop-basic.jsonl", in: home)
                let reader = reader(home)
                guard let page = page(reader.open(sessionID: id, cwd: cwd)) else { return }
                guard let bash = page.turns.first(where: { $0.kind == .tool(name: "Bash", description: "List files") }), let detail = reader.detail(of: bash, cursor: page.cursor) else {
                    Issue.record("펼친 본문을 읽지 못했다")
                    return
                }
                guard case .peer(_, let peer) = page.turns[4].kind else { return }
                let update = ClaudeAppTranscriptUpdate.turns(page.turns, cursor: page.cursor, hasMore: false)
                var values: [Any] = [page.cursor, page, detail, peer, update, ClaudeAppTranscriptLoad.page(page)]
                values += page.turns
                for value in values {
                    for text in [String(describing: value), String(reflecting: value)] {
                        for secret in [home.root, id, "Please", "tf-relay", "List files", A.commandSentinel, A.resultSentinel, "toolu_", "4321", "00000000-0000-4000-8000-0000000000b1", "file-a", "Bash"] {
                            #expect(!text.contains(secret), Comment(rawValue: "\(type(of: value))이 \(secret)을 찍는다: \(text.prefix(120))"))
                        }
                    }
                }
            }
        }

        @Test func thePreviewInitializersBuildTheValuesTheViewsNeed() {
            let cursor = ClaudeAppTranscriptCursor(sessionID: id)
            let turns = [ClaudeAppTurn(id: "t1", kind: .user("hello")), ClaudeAppTurn(id: "t2", kind: .assistant("hi"), timestamp: Date(timeIntervalSince1970: 1), truncated: true), ClaudeAppTurn(id: "t3", kind: .tool(name: "Bash", description: nil))]
            let page = ClaudeAppTranscriptPage(turns: turns, cursor: cursor, hasEarlier: true, skippedLines: 2)
            let detail = ClaudeAppToolDetail(input: "{}", result: nil, truncated: false)
            #expect(page.turns.count == 3 && page.hasEarlier && page.skippedLines == 2 && cursor.sessionID == id)
            #expect(detail.input == "{}" && detail.result == nil)
            #expect(turns[1].truncated && turns[1].timestamp == Date(timeIntervalSince1970: 1) && !turns[0].truncated)
            let poll = ClaudeAppStatusPoller.Poll(sessions: [], doubled: [], source: .agents, mismatch: true, verified: false, registryUnavailable: false)
            #expect(poll.source == .agents && poll.mismatch)
            // 견본 커서는 아무 파일도 가리키지 않는다: 읽기는 못 읽음으로 끝난다
            let reader = ClaudeAppTranscriptReader(claudeDirectory: "/nonexistent-claude-dir")
            #expect(reader.newer(cursor) == .unreadable)
            #expect(reader.detail(of: turns[2], cursor: cursor) == nil)
        }

        @Test func twoDirectoriesWithTheSameTranscriptNameDoNotConfuseTheCursor() throws {
            try withHome { home in
                let path = try home.transcript(directory: directory, id: id, lines: conversation(3))
                let reader = reader(home)
                guard let page = page(reader.open(sessionID: id, cwd: cwd)) else { return }
                #expect(page.cursor.sessionID == id)
                // 같은 id의 더 새로운 파일이 다른 디렉터리에 생겨도 이 보기는 열었던 파일을 따라간다
                try home.transcript(directory: "-Users-tester-elsewhere", id: id, lines: [L.user(id: id, text: "elsewhere")], modified: Date(timeIntervalSinceNow: 100))
                try append(path, L.user(id: id, text: "turn 3") + "\n")
                guard case .turns(let more, _, _) = reader.newer(page.cursor) else { Issue.record("이어 읽기"); return }
                #expect(texts(more) == ["turn 3"])
            }
        }
    }
}
#endif
