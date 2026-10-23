#if os(macOS) && DEBUG
import Foundation
import Testing
@testable import TaskforceKit

extension ExternalSessionSuites {
    /// 서버에 저장할 행을 고르는 순수 함수 (PR-D3k, 계약 25.1 · 26장 · 위협 DT11 · DT15): **우리 중계가 보냈고 대상 기록에서 확인된 peer 줄 L의 글**과 **L 뒤 데스크톱 Claude의 답 글**(텍스트 블록만) + 답 앞의 도구 **이름**뿐이다.
    /// 데스크톱에서 친 말 · 다른 peer · 도구 입력 · 결과 · 경로 · 이메일은 어떤 행에도 없다. 교환의 끝은 ① 데스크톱에서 친 말 ② 다음 peer ③ 턴 끝 ④ 30분 ⑤ 64 KiB · 블록 40개 중 먼저 오는 것
    struct ClaudeAppExchangeCollectorTests {
        typealias A = ClaudeAppFixture
        let session = ExternalSessionFixture.uuid(0xD1)
        let relayPID: Int32 = 4242
        let sent = "Mention the new tests/db file in the description"
        let sentAt = Date(timeIntervalSince1970: 1_800_000_000)
        let desktopSentinel = "SENTINEL-DESKTOP-TYPED-TEXT"
        let foreignSentinel = "SENTINEL-OTHER-PEER-TEXT"
        let toolSentinel = "SENTINEL-TOOL-DESCRIPTION-AND-PATH /Users/tester/secret.txt"
        let emailSentinel = "sentinel.person@example-org.test"

        private func peer(_ id: String, _ text: String, plugin: String? = "tf-relay", pid: Int32? = 4242, messageID: String? = "msg-1", at seconds: TimeInterval = 1) -> ClaudeAppTurn {
            ClaudeAppTurn(id: id, kind: .peer(text, ClaudeAppPeer(plugin: plugin, verifiedPeerPID: pid, messageID: messageID)), timestamp: sentAt.addingTimeInterval(seconds))
        }

        private func assistant(_ id: String, _ text: String, at seconds: TimeInterval = 2, truncated: Bool = false) -> ClaudeAppTurn {
            ClaudeAppTurn(id: id, kind: .assistant(text), timestamp: sentAt.addingTimeInterval(seconds), truncated: truncated)
        }

        private func tool(_ id: String, _ name: String, description: String? = nil) -> ClaudeAppTurn {
            ClaudeAppTurn(id: id, kind: .tool(name: name, description: description), timestamp: sentAt.addingTimeInterval(3))
        }

        private func desktopUser(_ id: String, _ text: String) -> ClaudeAppTurn {
            ClaudeAppTurn(id: id, kind: .user(text), timestamp: sentAt.addingTimeInterval(10))
        }

        private func collect(
            _ turns: [ClaudeAppTurn], baseline: Set<String> = [], now: Date? = nil, ended: Bool = false, text: String? = nil, baselineUnknown: Bool = false
        ) -> ClaudeAppExchange {
            ClaudeAppExchangeCollector.collect(
                ClaudeAppExchangeInput(
                    sessionID: session, turns: turns, relayPID: relayPID, sentText: text ?? sent, sentAt: sentAt, now: now ?? sentAt.addingTimeInterval(20), turnEnded: ended, baseline: baseline,
                    baselineUnknown: baselineUnknown, ref: { "ref(\($0))" }
                )
            )
        }

        // MARK: 글 없는 경계 (OA PR-D3 검토 P2-1) · 안정된 ref 씨앗 (P3-11) · 모르는 baseline (P3-13)

        @Test func aBoundaryTurnEndsTheExchangeSoNothingAfterItIsKept() {
            let boundary = ClaudeAppTurn(id: "b1", kind: .boundary, timestamp: sentAt.addingTimeInterval(5))
            let result = collect([peer("p1", sent), assistant("a1", "answer before the boundary"), boundary, assistant("a2", "answer to something typed on the desktop")])
            #expect(result.rows.map(\.body) == [sent, "answer before the boundary"], "경계 뒤의 답은 우리가 보낸 말에 대한 답이 아니다")
            #expect(result.finished == .desktopUserLine)
            // 경계가 L 앞에 있는 것은 이 교환과 상관없다
            let before = collect([boundary, peer("p1", sent), assistant("a1", "answer")])
            #expect(before.rows.map(\.body) == [sent, "answer"] && before.finished == nil)
        }

        @Test func theAnswerRefSeedIsTheRecordUUIDAndBlockIndexWhenThereIsOneSoAMovedLineKeepsItsRef() {
            func answer(offset: Int, stable: String?) -> ClaudeAppTurn {
                ClaudeAppTurn(
                    id: "\(offset)-0", kind: .assistant("Same answer"), timestamp: sentAt.addingTimeInterval(2), truncated: false, lineOffset: Int64(offset), toolUseID: nil, stableID: stable
                )
            }
            let first = collect([peer("p1", sent), answer(offset: 100, stable: "uuid-aaa-0")])
            let moved = collect([peer("p1", sent), answer(offset: 9_999, stable: "uuid-aaa-0")])
            #expect(first.rows.count == 2 && moved.rows.count == 2)
            #expect(first.rows.last?.macRef == moved.rows.last?.macRef, "파일이 다시 쓰여 줄 위치가 달라져도 같은 줄은 같은 ref")
            #expect(first.rows.last?.macRef.contains("uuid-aaa-0") == true)
            let other = collect([peer("p1", sent), answer(offset: 100, stable: "uuid-bbb-0")])
            #expect(other.rows.last?.macRef != first.rows.last?.macRef, "다른 uuid는 다른 ref")
            // uuid가 없으면 줄 위치로 되돌아간다
            let fallback = collect([peer("p1", sent), answer(offset: 100, stable: nil)])
            #expect(fallback.rows.last?.macRef.contains("100-0") == true)
        }

        @Test func withoutAKnownBaselineOnlyALineWrittenAfterTheSendCanBeOurs() {
            // 보내기 전에 기록을 읽지 못했다: 같은 중계 pid가 앞서 보낸 같은 글(보낸 시각보다 먼저 쓰임)을 이번 것으로 보지 않는다
            let earlier = peer("p1", sent, at: -50)
            #expect(collect([earlier, assistant("a1", "old answer")], baselineUnknown: true).matchedTurnID == nil)
            #expect(collect([earlier, assistant("a1", "old answer")], baselineUnknown: false).matchedTurnID == "p1", "baseline을 알면 이 판정은 baseline이 한다")
            let newer = peer("p2", sent, messageID: "msg-2", at: 1)
            #expect(collect([earlier, newer, assistant("a1", "new answer")], baselineUnknown: true).matchedTurnID == "p2")
            let undated = ClaudeAppTurn(id: "p3", kind: .peer(sent, ClaudeAppPeer(plugin: "tf-relay", verifiedPeerPID: 4242, messageID: "m3")))
            #expect(collect([undated], baselineUnknown: true).matchedTurnID == nil, "시각을 모르면 새것이라 할 수 없다")
        }

        // MARK: 기본 모양

        @Test func theUserRowIsTheRelayLineAndEachAnswerTextBlockIsARowThatPointsAtIt() {
            let result = collect([peer("p1", sent), assistant("a1", "First answer"), assistant("a2", "Second answer")])
            #expect(result.matchedTurnID == "p1" && result.finished == nil)
            #expect(result.rows.map(\.role) == [.user, .assistant, .assistant])
            #expect(result.rows.map(\.body) == [sent, "First answer", "Second answer"])
            guard result.rows.count == 3 else {
                Issue.record("행이 셋이어야 한다")
                return
            }
            let user = result.rows[0]
            #expect(user.replyToRef == nil && user.toolNames.isEmpty)
            #expect(result.rows[1].replyToRef == user.macRef && result.rows[2].replyToRef == user.macRef)
            #expect(Set(result.rows.map(\.macRef)).count == 3, "행마다 다른 ref")
            #expect(result.rows.allSatisfy { !$0.truncated })
        }

        @Test func theUserBodyIsKeptByteForByte() {
            let text = "line one\n\n  indented  \nunicode 한글 😀\ttab"
            let result = collect([peer("p1", text), assistant("a1", "ok")], text: text)
            #expect(result.rows.first?.body == text)
        }

        @Test func aLongTextTheReaderCutAt32KiBIsStillOursAndTheUserRowKeepsTheWholeSentText() {
            let long = String((0..<15_000).compactMap { Unicode.Scalar(0xAC00 + $0 % 200).map(Character.init) })
            let cut = String(long.prefix(10_000))
            let truncatedLine = ClaudeAppTurn(id: "p1", kind: .peer(cut, ClaudeAppPeer(plugin: "tf-relay", verifiedPeerPID: 4242, messageID: "m")), timestamp: sentAt.addingTimeInterval(1), truncated: true)
            let result = collect([truncatedLine, assistant("a1", "ok")], text: long)
            #expect(result.matchedTurnID == "p1" && result.rows.first?.body == long, "보낸 글 그대로")
            // 자르지 않은 줄이 앞부분뿐이면 같은 글이 아니다
            let shortLine = ClaudeAppTurn(id: "p1", kind: .peer(cut, ClaudeAppPeer(plugin: "tf-relay", verifiedPeerPID: 4242, messageID: "m")), timestamp: sentAt, truncated: false)
            #expect(collect([shortLine], text: long).matchedTurnID == nil)
            // 잘린 줄이어도 보낸 글의 앞부분이 아니면 아니다
            let other = ClaudeAppTurn(id: "p1", kind: .peer("A" + cut, ClaudeAppPeer(plugin: "tf-relay", verifiedPeerPID: 4242, messageID: "m")), timestamp: sentAt, truncated: true)
            #expect(collect([other], text: long).matchedTurnID == nil)
        }

        @Test func nothingIsCollectedUntilTheRelayLineShowsUpInTheTranscript() {
            #expect(collect([desktopUser("u1", desktopSentinel), assistant("a1", "unrelated answer")]) == ClaudeAppExchange(rows: [], finished: nil, matchedTurnID: nil))
            #expect(collect([]).rows.isEmpty)
        }

        // MARK: L은 우리 중계가 보낸 그 글만 (DT11)

        @Test func onlyAPeerLineFromOurRelayProcessWithExactlyTheSentTextIsTheUserRow() {
            let others: [(String, ClaudeAppTurn)] = [
                ("글이 한 바이트 다르다", peer("p1", sent + " ")),
                ("다른 플러그인 이름", peer("p1", sent, plugin: "other-relay")),
                ("플러그인 이름 없음", peer("p1", sent, plugin: nil)),
                ("다른 프로세스가 tf-relay 이름으로 보냈다", peer("p1", sent, pid: 9999)),
                ("보낸 pid를 모른다", peer("p1", sent, pid: nil)),
                ("데스크톱에서 같은 글을 쳤다", ClaudeAppTurn(id: "p1", kind: .user(sent))),
            ]
            for (why, turn) in others {
                let result = collect([turn, assistant("a1", "answer that must not be saved")])
                #expect(result.rows.isEmpty && result.matchedTurnID == nil, "\(why)")
            }
        }

        @Test func aLineThatWasAlreadyInTheTranscriptBeforeTheSendIsNotTheOneWeSent() {
            // 같은 글을 두 번 보냈다: 첫 번째 줄(baseline)은 이번 보내기의 것이 아니다
            let old = peer("p1", sent, messageID: "msg-old")
            let new = peer("p2", sent, messageID: "msg-new", at: 30)
            let result = collect([old, assistant("a1", "old answer"), new, assistant("a2", "new answer")], baseline: ["p1", "a1"])
            #expect(result.matchedTurnID == "p2")
            #expect(result.rows.map(\.body) == [sent, "new answer"])
        }

        // MARK: 교환의 끝

        @Test func aLineTypedOnTheDesktopEndsTheExchangeAndNothingAfterItIsKept() {
            let result = collect([peer("p1", sent), assistant("a1", "answer to us"), desktopUser("u1", desktopSentinel), assistant("a2", "answer to the desktop line")])
            #expect(result.finished == .desktopUserLine)
            #expect(result.rows.map(\.body) == [sent, "answer to us"])
        }

        @Test func theNextPeerLineEndsItWhoeverSentIt() {
            let foreign = collect([peer("p1", sent), assistant("a1", "answer"), peer("p2", foreignSentinel, plugin: "someone", pid: 7), assistant("a2", "answer to the foreign line")])
            #expect(foreign.finished == .nextPeer)
            #expect(foreign.rows.map(\.body) == [sent, "answer"])
            // 우리 것이어도 새 교환이다: 이 교환은 거기서 끝난다
            let ours = collect([peer("p1", sent), assistant("a1", "answer"), peer("p2", "next message", messageID: "msg-2"), assistant("a2", "next answer")])
            #expect(ours.finished == .nextPeer && ours.rows.map(\.body) == [sent, "answer"])
        }

        @Test func theTurnEndingAfterTheLineEndsItOnlyWhenTheCallerSaysTheTranscriptWasReadToTheEnd() {
            let turns = [peer("p1", sent), assistant("a1", "answer")]
            #expect(collect(turns, ended: false).finished == nil)
            let done = collect(turns, ended: true)
            #expect(done.finished == .turnEnded && done.rows.count == 2)
        }

        @Test func thirtyMinutesAfterTheLineEndsIt() {
            let turns = [peer("p1", sent, at: 0), assistant("a1", "answer")]
            #expect(collect(turns, now: sentAt.addingTimeInterval(30 * 60 - 1)).finished == nil)
            #expect(collect(turns, now: sentAt.addingTimeInterval(30 * 60)).finished == .timeout)
        }

        @Test func theAnswerStopsAt64KiBAndTheLastRowIsCutOnACharacterBoundaryAndMarkedTruncated() {
            // 3바이트 글자(한)로 채운다: 65,536 = 21,845 × 3 + 1 → 자른 곳이 글자 한가운데가 아니다
            let big = String(repeating: "한", count: 30_000)
            let result = collect([peer("p1", sent), assistant("a1", big), assistant("a2", "never saved")])
            #expect(result.finished == .limit)
            let rows = result.rows.filter { $0.role == .assistant }
            guard rows.count == 1 else {
                Issue.record("답 행이 하나여야 한다")
                return
            }
            #expect(rows[0].truncated)
            #expect(rows[0].body.utf8.count <= 65_536 && rows[0].body.utf8.count > 65_536 - 3)
            #expect(rows[0].body.allSatisfy { $0 == "한" })
        }

        @Test func theBudgetIsSharedByTheWholeExchangeNotPerBlock() {
            let chunk = String(repeating: "a", count: 30_000)
            let result = collect([peer("p1", sent), assistant("a1", chunk), assistant("a2", chunk), assistant("a3", chunk)])
            let rows = result.rows.filter { $0.role == .assistant }
            #expect(rows.map(\.body.utf8.count) == [30_000, 30_000, 5_536])
            #expect(rows.map(\.truncated) == [false, false, true] && result.finished == .limit)
        }

        @Test func fortyAnswerBlocksEndItAndTheFortyFirstIsNotKept() {
            let turns = [peer("p1", sent)] + (0..<45).map { assistant("a\($0)", "block \($0)") }
            let result = collect(turns)
            let rows = result.rows.filter { $0.role == .assistant }
            #expect(rows.count == 40 && rows.last?.body == "block 39" && result.finished == .limit)
        }

        // MARK: 도구는 이름만

        @Test func toolStepsBeforeATextBlockBecomeThatRowsToolNamesInOrderAndNothingElse() {
            let result = collect([
                peer("p1", sent), tool("t1", "Read", description: toolSentinel), tool("t2", "Edit"), assistant("a1", "Done editing"), tool("t3", "Bash", description: toolSentinel), assistant("a2", "Ran the tests"),
            ])
            let rows = result.rows.filter { $0.role == .assistant }
            #expect(rows.map(\.toolNames) == [["Read", "Edit"], ["Bash"]])
            #expect(result.rows.first?.toolNames.isEmpty == true)
        }

        @Test func toolStepsWithNoTextAfterThemAreDropped() {
            let result = collect([peer("p1", sent), assistant("a1", "Working"), tool("t1", "Bash"), tool("t2", "Edit")])
            #expect(result.rows.filter { $0.role == .assistant }.map(\.toolNames) == [[]], "글 없는 마지막 도구 단계는 서버에 보낼 자리가 없다")
        }

        @Test func aToolNameThatIsNotTheServersShapeIsDroppedButTheTextAndTheOtherNamesStay() {
            let longName = String(repeating: "x", count: 129)
            let mcp = "mcp__0d8b6a52-1111-4222-8333-444444444444__search-docs"
            let result = collect([
                peer("p1", sent), tool("t1", "/etc/passwd"), tool("t2", "Bash(rm -rf /)"), tool("t3", ""), tool("t4", longName), tool("t5", "has space"), tool("t6", "한글"), tool("t7", mcp), tool("t8", "Grep"),
                assistant("a1", "Answer"),
            ])
            #expect(result.rows.last?.toolNames == [mcp, "Grep"], "경로 · 명령 · 괄호 · 공백 · 128자 초과 · 빈 이름은 이름 하나만 버린다")
            #expect(result.rows.last?.body == "Answer")
        }

        @Test func atMostFortyToolNamesPerRow() {
            let names = (0..<50).map { "Tool\($0)" }
            let result = collect([peer("p1", sent)] + names.enumerated().map { tool("t\($0.offset)", $0.element) } + [assistant("a1", "Answer")])
            #expect(result.rows.last?.toolNames == Array(names.prefix(40)))
        }

        // MARK: 개인 정보 (DT11)

        @Test func noRowHoldsTheDesktopLineTheOtherPeerThePathTheToolDescriptionOrTheEmail() {
            let result = collect([
                desktopUser("u0", desktopSentinel), peer("p0", foreignSentinel, plugin: "someone", pid: 7, messageID: "other"), assistant("a0", "before the line \(emailSentinel)"),
                peer("p1", sent), tool("t1", "Bash", description: toolSentinel), assistant("a1", "the answer"),
                desktopUser("u1", desktopSentinel), assistant("a2", "after \(emailSentinel)"),
            ])
            let dump = result.rows.map { "\($0.macRef)|\($0.role)|\($0.body)|\($0.toolNames.joined(separator: ","))|\($0.replyToRef ?? "")" }.joined(separator: "\n")
            for secret in [desktopSentinel, foreignSentinel, toolSentinel, emailSentinel, "/Users/tester", "secret.txt", "SENTINEL"] {
                #expect(!dump.contains(secret), "\(secret)")
            }
            #expect(result.rows.map(\.body) == [sent, "the answer"])
        }

        @Test func theRefSeedsNameTheSessionAndTheLineButNeverTheText() {
            let seeds = SeedLog()
            _ = ClaudeAppExchangeCollector.collect(
                ClaudeAppExchangeInput(
                    sessionID: session, turns: [peer("p1", sent, messageID: "msg-77"), assistant("a1", "the answer text")], relayPID: relayPID, sentText: sent, sentAt: sentAt, now: sentAt.addingTimeInterval(5),
                    turnEnded: false, baseline: [], ref: { seeds.add($0) }
                )
            )
            let all = seeds.all
            guard all.count == 2 else {
                Issue.record("씨앗이 둘이어야 한다 (사용자 행 · 답 행)")
                return
            }
            #expect(all[0].contains(session) && all[0].contains("msg-77") && all[0].contains("\(relayPID)"))
            #expect(all[1].contains(session) && all[1].contains("a1"))
            #expect(all.allSatisfy { !$0.contains(sent) && !$0.contains("the answer text") })
        }

        // MARK: 안정성 (DT15) · 시각 · 청소

        @Test func theSameInputGivesTheSameRefsSoARepeatedUploadIsTheSameRow() {
            let turns = [peer("p1", sent), assistant("a1", "one"), assistant("a2", "two")]
            #expect(collect(turns).rows.map(\.macRef) == collect(turns).rows.map(\.macRef))
            // 더 읽어서 줄이 늘어도 앞 행의 ref는 그대로다
            let more = collect(turns + [assistant("a3", "three")])
            #expect(Array(more.rows.map(\.macRef).prefix(3)) == collect(turns).rows.map(\.macRef))
        }

        @Test func saidAtIsTheRecordsTimeAndFallsBackToTheSendTimeThenToTheLineBefore() {
            let noTime = ClaudeAppTurn(id: "a2", kind: .assistant("no clock"))
            let result = collect([peer("p1", sent, at: 4), assistant("a1", "timed", at: 6), noTime])
            #expect(result.rows.map(\.saidAt) == [sentAt.addingTimeInterval(4), sentAt.addingTimeInterval(6), sentAt.addingTimeInterval(6)])
            let bare = collect([ClaudeAppTurn(id: "p1", kind: .peer(sent, ClaudeAppPeer(plugin: "tf-relay", verifiedPeerPID: 4242, messageID: "m")))])
            #expect(bare.rows.first?.saidAt == sentAt, "L에 시각이 없으면 보낸 시각")
        }

        @Test func controlCharactersAreRemovedAndTextThatIsEmptyAfterwardIsSkipped() {
            let result = collect([peer("p1", sent), assistant("a1", "a\u{0}b\u{7}c\u{1B}d\nline\ttab"), assistant("a2", "\u{0}\u{1}"), assistant("a3", "   ")])
            #expect(result.rows.filter { $0.role == .assistant }.map(\.body) == ["abcd\nline\ttab"], "NUL · 제어 글자는 지우고 개행 · 탭은 둔다. 지운 뒤 비었거나 공백뿐이면 건너뛴다")
        }

        @Test func aTruncatedTurnKeepsItsTruncatedFlag() {
            let result = collect([peer("p1", sent), assistant("a1", "cut at the reader's limit", truncated: true)])
            #expect(result.rows.last?.truncated == true)
        }
    }

    /// 시험용: collector가 넘긴 ref 씨앗을 모은다
    final class SeedLog: @unchecked Sendable {
        private let lock = NSLock()
        private var seeds: [String] = []
        func add(_ seed: String) -> String {
            lock.withLock { seeds.append(seed) }
            return "ref"
        }
        var all: [String] { lock.withLock { seeds } }
    }
}
#endif
