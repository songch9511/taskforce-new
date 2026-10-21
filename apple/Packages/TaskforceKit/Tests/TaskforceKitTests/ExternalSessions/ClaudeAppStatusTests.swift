#if os(macOS) && DEBUG
import Darwin
import Foundation
import Testing
@testable import TaskforceKit

extension ExternalSessionSuites {
    /// 데스크톱 세션의 상태 읽기 (PR-D1 Kit, 계약 21.1 DR-1 · DR-2): 등록 파일의 `status` · `waitingFor` · `statusUpdatedAt`와 `claude agents --json`의 같은 값.
    /// 모르는 값 · 없는 키 · 틀린 모양은 unknown이고 어떤 경우에도 죽지 않는다. 실제 `claude`는 띄우지 않는다 (가짜 셸 스크립트)
    struct ClaudeAppStatusTests {
        typealias F = ExternalSessionFixture
        typealias A = ClaudeAppFixture
        let id = F.uuid(0xD1)
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        private func withHome<T>(_ body: (ExternalHome) throws -> T) throws -> T {
            let home = try ExternalHome()
            defer { home.cleanup() }
            return try body(home)
        }

        private func readEntries(_ home: ExternalHome) -> [ExternalSessionRegistry.Entry] {
            if case .entries(let entries) = ExternalSessionRegistry.read(fileSystem: .live, sessionsDirectory: home.sessions, now: now) { return entries }
            return []
        }

        // MARK: 상태 값 (DR-1)

        @Test func theStatusKeyReadsAsBusyWaitingIdleAndAnythingElseIsUnknown() {
            let cases: [(String?, String?, ClaudeAppSessionState)] = [
                ("busy", nil, .busy), ("busy", "permission prompt", .busy), ("idle", nil, .idle), ("idle", "input needed", .idle),
                ("waiting", "permission prompt", .waiting(.approval)), ("waiting", "sandbox request", .waiting(.approval)),
                ("waiting", "input needed", .waiting(.answer)), ("waiting", "dialog open", .waiting(.answer)), ("waiting", "worker request", .waiting(.answer)),
                ("waiting", nil, .waiting(.answer)), ("waiting", "a value from a newer Claude Code", .waiting(.answer)), ("waiting", String(repeating: "x", count: 100), .waiting(.answer)),
                (nil, nil, .unknown), ("", nil, .unknown), ("starting", nil, .unknown), ("BUSY", nil, .unknown), ("busy ", nil, .unknown), (" idle", nil, .unknown),
                (String(repeating: "b", count: 100), nil, .unknown),
            ]
            for (status, waitingFor, expected) in cases {
                #expect(ClaudeAppSessionState.parse(status: status, waitingFor: waitingFor) == expected, "\(status ?? "nil") / \(waitingFor ?? "nil")")
            }
        }

        @Test func onlyBusyAndWaitingCountAsActive() {
            #expect(ClaudeAppSessionState.busy.isActive && ClaudeAppSessionState.waiting(.approval).isActive && ClaudeAppSessionState.waiting(.answer).isActive)
            #expect(!ClaudeAppSessionState.idle.isActive && !ClaudeAppSessionState.unknown.isActive)
        }

        // MARK: 등록 파일 (DR-2)

        @Test func theRegistryCarriesTheStatusTheWaitReasonAndWhenItChanged() throws {
            try withHome { home in
                try home.registry(pid: 100, json: A.registry(pid: 100, id: F.uuid(1), status: "busy"))
                try home.registry(pid: 101, json: A.registry(pid: 101, id: F.uuid(2), status: "waiting", waitingFor: "permission prompt", statusUpdatedAt: 1_799_999_000_000))
                try home.registry(pid: 102, json: A.registry(pid: 102, id: F.uuid(3), status: "waiting", waitingFor: "input needed"))
                try home.registry(pid: 103, json: A.registry(pid: 103, id: F.uuid(4), status: "idle"))
                let byPID = Dictionary(uniqueKeysWithValues: readEntries(home).map { ($0.pid, $0) })
                #expect(byPID[100]?.state == .busy)
                #expect(byPID[101]?.state == .waiting(.approval))
                #expect(byPID[101]?.statusUpdatedAt == Date(timeIntervalSince1970: 1_799_999_000))
                #expect(byPID[102]?.state == .waiting(.answer))
                #expect(byPID[103]?.state == .idle)
            }
        }

        @Test func aMissingOrUnknownStatusIsUnknownAndTheEntryIsStillRead() throws {
            try withHome { home in
                try home.registry(pid: 100, json: A.registry(pid: 100, id: F.uuid(1), status: nil, statusUpdatedAt: nil))
                try home.registry(pid: 101, json: A.registry(pid: 101, id: F.uuid(2), status: "dreaming"))
                // 틀린 모양: 숫자 · 배열 · 객체
                try home.registry(pid: 102, json: F.json(["pid": 102, "sessionId": F.uuid(3), "entrypoint": "claude-desktop", "status": 5, "waitingFor": ["x"], "statusUpdatedAt": ["a": 1]]))
                try home.registry(pid: 103, json: F.json(["pid": 103, "sessionId": F.uuid(4), "entrypoint": "claude-desktop", "status": ["busy"], "waitingFor": 7]))
                let entries = readEntries(home)
                #expect(entries.count == 4, "상태를 못 읽어도 줄은 남는다 (살아 있는지는 따로 본다)")
                #expect(entries.allSatisfy { $0.state == .unknown })
                #expect(entries.filter { $0.pid != 101 }.allSatisfy { $0.statusUpdatedAt == nil }, "없거나 틀린 모양의 시각은 nil (101은 시각이 멀쩡하다)")
                #expect(entries.first { $0.pid == 101 }?.statusUpdatedAt == Date(timeIntervalSince1970: 1_800_000_000))
            }
        }

        @Test func theUpdateTimeIsReadAsMillisecondsSecondsTextAndISOAndAnImplausibleOneIsDropped() throws {
            let expected = Date(timeIntervalSince1970: 1_799_999_000)
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime]
            let good: [Any] = [1_799_999_000_000, 1_799_999_000, "1799999000000", "1799999000", iso.string(from: expected)]
            let bad: [Any] = [0, -5, 1e20, "tomorrow", "9999-01-01T00:00:00Z", 4_000_000_000_000]
            try withHome { home in
                for (index, form) in good.enumerated() {
                    try home.registry(pid: 200 + index, json: A.registry(pid: 200 + index, id: F.uuid(10 + index), statusUpdatedAt: form))
                }
                for (index, form) in bad.enumerated() {
                    try home.registry(pid: 300 + index, json: A.registry(pid: 300 + index, id: F.uuid(30 + index), statusUpdatedAt: form))
                }
                let entries = readEntries(home)
                for entry in entries where entry.pid >= 200 && entry.pid < 300 { #expect(entry.statusUpdatedAt == expected, "\(entry.pid)") }
                for entry in entries where entry.pid >= 300 { #expect(entry.statusUpdatedAt == nil, "\(entry.pid)") }
                #expect(entries.count == good.count + bad.count)
            }
        }

        @Test func readingTheStatusDoesNotOpenAnythingNewAndKeepsNoNameOrFolderOutOfTheValue() throws {
            try withHome { home in
                try home.registry(pid: 4242, json: A.registry(pid: 4242, id: id, status: "busy"))
                try "SECRET".write(toFile: home.sessions + "/4242.abcdef.key", atomically: false, encoding: .utf8)
                let recording = RecordingFileSystem()
                _ = ExternalSessionRegistry.read(fileSystem: recording.fileSystem, sessionsDirectory: home.sessions)
                #expect(recording.reads.map(\.path) == [home.sessions + "/4242.json"], "읽는 파일은 그대로 등록 파일 하나")
                let live = ClaudeAppLiveSessions.read(
                    fileSystem: .live, sessionsDirectory: home.sessions, facts: A.facts(lookups: [4242: .present(start: now, uid: 501)]), ownPIDs: [], now: now
                )
                for session in live.sessions {
                    #expect(!String(describing: session).contains(A.cwdSentinel) && !String(reflecting: session).contains(A.nameSentinel), "화면 · 로그에 찍힐 글에 폴더 · 이름이 없다")
                    #expect(!String(describing: session).contains(session.id))
                }
                #expect(!live.sessions.isEmpty)
            }
        }

        // MARK: `claude agents --json` (DR-1)

        @Test func theAgentsListIsReadForTheIdThePidAndTheStatusOnly() {
            let data = A.agentsJSON([(100, id, "busy", nil), (101, F.uuid(0xD2), "waiting", "permission prompt"), (102, F.uuid(0xD3), "waiting", "input needed"), (103, F.uuid(0xD4), "idle", nil)])
            let items = ClaudeAgentsListing.parse(data)
            #expect(items == [
                ClaudeAgentsItem(pid: 100, sessionID: id, state: .busy), ClaudeAgentsItem(pid: 101, sessionID: F.uuid(0xD2), state: .waiting(.approval)),
                ClaudeAgentsItem(pid: 102, sessionID: F.uuid(0xD3), state: .waiting(.answer)), ClaudeAgentsItem(pid: 103, sessionID: F.uuid(0xD4), state: .idle),
            ])
            var dump = ""
            Swift.dump(items as Any, to: &dump)
            #expect(!dump.contains(A.cwdSentinel) && !dump.contains(A.nameSentinel) && !dump.contains("interactive"), "폴더 · 이름 · 종류는 값에 없다")
        }

        @Test func anItemWithoutAStatusKeyIsUnknownAndOneWithoutAnIDOrAPidIsSkipped() {
            let text = """
            [{"pid":100,"sessionId":"\(id)"},
             {"pid":101,"status":"busy"},
             {"sessionId":"\(F.uuid(0xD2))","status":"busy"},
             {"pid":"x","sessionId":"\(F.uuid(0xD3))","status":"busy"},
             {"pid":103,"sessionId":"not-a-uuid","status":"busy"},
             {"pid":104,"sessionId":"\(F.uuid(0xD5).uppercased())","status":"busy"},
             {"pid":-1,"sessionId":"\(F.uuid(0xD6))","status":"busy"},
             "a string", 7, null,
             {"pid":105,"sessionId":"\(F.uuid(0xD7))","status":7}]
            """
            let items = ClaudeAgentsListing.parse(Data(text.utf8))
            #expect(items == [ClaudeAgentsItem(pid: 100, sessionID: id, state: .unknown), ClaudeAgentsItem(pid: 105, sessionID: F.uuid(0xD7), state: .unknown)])
        }

        @Test func anAnswerThatIsNotAnArrayOfObjectsOrIsTooBigOrBrokenIsNothing() {
            #expect(ClaudeAgentsListing.parse(Data()) == nil)
            #expect(ClaudeAgentsListing.parse(Data("not json".utf8)) == nil)
            #expect(ClaudeAgentsListing.parse(Data("{\"sessions\":[]}".utf8)) == nil, "다른 모양은 읽지 않는다")
            #expect(ClaudeAgentsListing.parse(Data("[".utf8)) == nil)
            #expect(ClaudeAgentsListing.parse(Data("[]".utf8)) == [])
            let one = String(decoding: A.agentsJSON([(100, id, "busy", nil)]), as: UTF8.self)
            let padded = one.dropLast() + String(repeating: " ", count: ClaudeAgentsListing.maxBytes) + "]"
            #expect(ClaudeAgentsListing.parse(Data(padded.utf8)) == nil, "상한을 넘는 답은 읽지 않는다")
            #expect(ClaudeAgentsListing.parse(Data(one.utf8)) != nil)
        }

        @Test func anAnswerWithManyItemsKeepsAtMostTheLimit() {
            let many = (0..<(ClaudeAgentsListing.maxItems + 25)).map { (100 + $0, F.uuid(0x1000 + $0), "idle" as String?, nil as String?) }
            let items = ClaudeAgentsListing.parse(A.agentsJSON(many))
            #expect(items?.count == ClaudeAgentsListing.maxItems)
        }

        // MARK: 실행 (고정 찾기 · 인자 · 환경 · 기한)

        /// 임시 폴더의 가짜 `claude`: 인자 · cwd · 환경 이름을 적고 `payload`를 낸다
        private func rig(payload: String, exit code: Int = 0, extra: String = "") throws -> (home: ExternalHome, locator: ClaudeCodeLocator, record: String) {
            let home = try ExternalHome()
            let bin = home.root + "/bin"
            try FileManager.default.createDirectory(atPath: bin, withIntermediateDirectories: true)
            let record = home.root + "/record.txt"
            let script = """
            #!/bin/sh
            {
              printf 'argc=%s\\n' "$#"
              for a in "$@"; do printf 'arg=%s\\n' "$a"; done
              printf 'pwd=%s\\n' "$(pwd -P)"
              /usr/bin/env
            } > '\(record)'
            \(extra)
            cat <<'PAYLOAD'
            \(payload)
            PAYLOAD
            exit \(code)
            """
            try script.write(toFile: bin + "/claude", atomically: false, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: bin + "/claude")
            return (home, ClaudeCodeLocator(candidates: [bin + "/claude"], confinedTo: home.root), record)
        }

        private func lister(_ rig: (home: ExternalHome, locator: ClaudeCodeLocator, record: String), timeout: TimeInterval = 5, log: any BridgeLogSink = NoBridgeLog()) -> ClaudeAgentsLister {
            let environment = [
                "HOME": rig.home.home, "USER": "tester", "LANG": "en_US.UTF-8", "PATH": "/usr/bin:/bin", "ANTHROPIC_API_KEY": A.cwdSentinel, "OPENROUTER_API_KEY": A.cwdSentinel,
                "SUPABASE_SERVICE_ROLE_KEY": A.cwdSentinel, "DYLD_INSERT_LIBRARIES": "/tmp/evil.dylib", "CLAUDE_CODE_OAUTH_TOKEN": A.cwdSentinel,
            ]
            let work = rig.home.root
            return ClaudeAgentsLister(locator: rig.locator, runner: ClaudeCodeProbe.liveRunner(environment: environment, cwd: { work }), timeout: timeout, log: log)
        }

        private func recorded(_ rig: (home: ExternalHome, locator: ClaudeCodeLocator, record: String)) -> [String] {
            ((try? String(contentsOfFile: rig.record, encoding: .utf8)) ?? "").split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        }

        @Test func theLiveListerRunsExactlyAgentsJsonWithTheFourNameEnvironmentAndParsesTheAnswer() async throws {
            let payload = String(decoding: A.agentsJSON([(100, id, "waiting", "permission prompt")]), as: UTF8.self)
            let rig = try rig(payload: payload)
            defer { rig.home.cleanup() }
            let items = await lister(rig).list()
            #expect(items == [ClaudeAgentsItem(pid: 100, sessionID: id, state: .waiting(.approval))])
            let lines = recorded(rig)
            #expect(lines.filter { $0.hasPrefix("arg=") } == ["arg=agents", "arg=--json"], "인자는 정확히 둘, 이 순서")
            #expect(lines.contains("argc=2"))
            #expect(lines.contains("HOME=" + rig.home.home))
            let text = lines.joined(separator: "\n")
            for leaked in ["ANTHROPIC_API_KEY", "OPENROUTER_API_KEY", "SUPABASE", "DYLD_", "CLAUDE_CODE_OAUTH", A.cwdSentinel, "evil.dylib"] {
                #expect(!text.contains(leaked), Comment(rawValue: "자식 환경에 \(leaked)이 없다"))
            }
        }

        @Test func noClaudeOnThisMacOrAFailingOrNonJsonRunIsNothingNotACrash() async throws {
            let missing = try ExternalHome()
            defer { missing.cleanup() }
            let none = ClaudeAgentsLister(locator: ClaudeCodeLocator(candidates: [missing.root + "/bin/claude"], confinedTo: missing.root), runner: { _, _, _ in
                Issue.record("찾지 못했으면 아무것도 돌리지 않는다")
                return nil
            })
            #expect(await none.list() == nil)

            let failing = try rig(payload: "[]", exit: 1)
            defer { failing.home.cleanup() }
            #expect(await lister(failing).list() == nil, "0이 아닌 종료는 답이 아니다")

            let garbage = try rig(payload: "Error: not logged in")
            defer { garbage.home.cleanup() }
            #expect(await lister(garbage).list() == nil)
        }

        @Test func aListerThatNeverFinishesIsStoppedAtTheDeadline() async throws {
            let rig = try rig(payload: "[]", extra: "sleep 30")
            defer { rig.home.cleanup() }
            let started = Date()
            #expect(await lister(rig, timeout: 0.4).list() == nil)
            #expect(Date().timeIntervalSince(started) < 5, "기한에서 돌아온다")
        }

        @Test func theListerLogsOnlyAFixedResultCodeNeverTheAnswer() async throws {
            let payload = String(decoding: A.agentsJSON([(100, id, "busy", nil)]), as: UTF8.self)
            let ok = try rig(payload: payload)
            defer { ok.home.cleanup() }
            let log = RecordingLog()
            _ = await lister(ok, log: log).list()
            let bad = try rig(payload: "x", exit: 2)
            defer { bad.home.cleanup() }
            _ = await lister(bad, log: log).list()
            let events = log.events
            #expect(events.map(\.event) == ["claude_app_agents", "claude_app_agents"])
            #expect(events.map { $0.fields["result"] } == [.code("ok"), .code("unavailable")])
            for event in events {
                #expect(Set(event.fields.keys) == ["result"])
                #expect(!String(describing: event.fields).contains(A.cwdSentinel) && !String(describing: event.fields).contains(id))
            }
        }
    }
}
#endif
