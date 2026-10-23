#if os(macOS) && DEBUG
import Foundation
import Testing
@testable import TaskforceKit

extension ExternalSessionSuites {
    /// 보내는 글의 정리 (PR-D3k, 계약 25.4.1 · 위협 DT11): 우리가 보낸 글이 대상 기록에서 **같은 글**로 읽혀야 "Received"가 된다. 그래서 읽기(`ClaudeAppTranscriptReader`)가 지우는 글자를 보내기 전에 지우고 앞뒤 공백을 자른다
    /// (탐침: CLI가 인자 끝의 공백 · 줄바꿈을 자른다). 이 정리 뒤의 글이 읽기를 지나도 한 글자도 다르지 않은지 실제 읽기로 본다. 아울러 서버 저장용 ref와 기록의 권한 모드 읽기
    struct ClaudeAppSendTextTests {
        typealias F = ExternalSessionFixture
        let id = F.uuid(0xD7)
        let cwd = "/Users/tester/proj"

        // MARK: 정리

        @Test func surroundingWhitespaceControlsAndInvisibleFormatCharactersGoButInnerNewlinesTabsAndEmojiStay() {
            #expect(ClaudeAppSendText.normalize("  hello  \n\n") == "hello")
            #expect(ClaudeAppSendText.normalize("line one\n\n  indented  \nunicode 한글 😀\ttab") == "line one\n\n  indented  \nunicode 한글 😀\ttab", "안쪽 줄바꿈 · 공백 · 탭 · 한글 · 이모지는 그대로")
            #expect(ClaudeAppSendText.normalize("a\r\nb\rc") == "a\nb\nc", "CRLF · CR은 줄바꿈으로 합친다")
            #expect(ClaudeAppSendText.normalize("a\u{0}b\u{7}c\u{1B}d\u{7F}e") == "abcde", "NUL · 제어 글자")
            #expect(ClaudeAppSendText.normalize("a\u{202E}b\u{200B}c\u{00AD}d\u{FEFF}e\u{2028}f\u{2029}g") == "abcdefg", "방향 바꿈 · 폭 없는 공백 · 연한 하이픈 · BOM · 줄 구분")
            #expect(ClaudeAppSendText.normalize("👨‍👩‍👧 family") == "👨‍👩‍👧 family", "ZWJ로 이은 이모지는 그대로")
        }

        @Test func nothingLeftMeansNothingToSend() {
            for text in ["", "   ", "\n\n", "\t \n", "\u{0}\u{200B}", "\u{FEFF}\n"] {
                #expect(ClaudeAppSendText.normalize(text) == nil, "\(text.unicodeScalars.map(\.value))")
            }
        }

        @Test func normalizingTwiceChangesNothing() {
            for raw in ["  a\r\n\u{200B}b  ", "x\u{0}\ty", "한글\n\n😀 "] {
                let once = ClaudeAppSendText.normalize(raw)
                #expect(once.flatMap(ClaudeAppSendText.normalize) == once)
            }
        }

        @Test func theLimitIsSixteenThousandUTF16UnitsLikeTheModAndTheServer() {
            #expect(ClaudeAppSendText.isSendable(String(repeating: "x", count: 16_000)))
            #expect(!ClaudeAppSendText.isSendable(String(repeating: "x", count: 16_001)))
            #expect(!ClaudeAppSendText.isSendable(""))
            // 이모지는 UTF-16 두 칸: 8,000개가 16,000칸
            #expect(ClaudeAppSendText.isSendable(String(repeating: "😀", count: 8_000)) && !ClaudeAppSendText.isSendable(String(repeating: "😀", count: 8_001)))
            #expect(ClaudeAppSendText.maxLength == ClaudeAppRelay.maxTextLength)
        }

        // MARK: 실제 읽기를 지나도 같은 글이다

        private func peerLine(body: String) -> String {
            F.json([
                "type": "user", "sessionId": id, "uuid": UUID().uuidString.lowercased(), "timestamp": "2026-10-22T01:00:01.000Z", "isMeta": true, "isSidechain": false,
                "permissionMode": "default", "message": ["role": "user", "content": "<cross-session-message from-name=Taskforce>wrapped</cross-session-message>"],
                "origin": ["kind": "peer", "verifiedPeerPid": 4242, "msg_id": "msg-1", "plugin": "tf-relay", "name": "Taskforce", "body": body],
            ])
        }

        @Test func aNormalizedTextReadsBackFromTheTranscriptAsTheSameTextAndMatchesTheCollector() throws {
            let messy = "  Mention the new tests/db file\r\n\u{200B}and  keep\ttabs 한글 😀 \u{202E}\n\n"
            let sent = try #require(ClaudeAppSendText.normalize(messy))
            let home = try ExternalHome()
            defer { home.cleanup() }
            // 대상은 받은 글(origin.body)을 CLI가 다듬은 채로 기록한다: 탐침에서 끝 공백은 잘렸다. 여기서는 정리한 글 그대로 들어온다고 보고 읽기를 지나게 한다
            try home.transcript(directory: ExternalSessionRules.projectDirectoryName(forCwd: cwd) ?? "", id: id, lines: [peerLine(body: sent)])
            guard case .page(let page) = ClaudeAppTranscriptReader(claudeDirectory: home.claude).open(sessionID: id, cwd: cwd), case .peer(let read, let peer)? = page.turns.first?.kind else {
                Issue.record("peer 줄을 읽지 못했다")
                return
            }
            #expect(read == sent, "정리한 글은 읽기를 지나도 한 글자도 다르지 않다")
            let exchange = ClaudeAppExchangeCollector.collect(
                ClaudeAppExchangeInput(sessionID: id, turns: page.turns, relayPID: 4242, sentText: sent, sentAt: Date(), now: Date(), turnEnded: false, baseline: [], ref: { $0 })
            )
            #expect(peer.isTaskforceRelay(relayPID: 4242) && exchange.matchedTurnID == page.turns.first?.id)
        }

        @Test func aRawTextThatWasNotNormalizedWouldNotMatchWhichIsWhyTheComposerNormalizes() throws {
            let raw = "hello  \n"
            let home = try ExternalHome()
            defer { home.cleanup() }
            try home.transcript(directory: ExternalSessionRules.projectDirectoryName(forCwd: cwd) ?? "", id: id, lines: [peerLine(body: raw)])
            guard case .page(let page) = ClaudeAppTranscriptReader(claudeDirectory: home.claude).open(sessionID: id, cwd: cwd) else { return }
            let exchange = ClaudeAppExchangeCollector.collect(
                ClaudeAppExchangeInput(sessionID: id, turns: page.turns, relayPID: 4242, sentText: raw, sentAt: Date(), now: Date(), turnEnded: false, baseline: [], ref: { $0 })
            )
            #expect(exchange.matchedTurnID == nil, "읽기가 끝 공백을 자르므로 정리하지 않은 글은 같은 글로 읽히지 않는다")
        }

        // MARK: 기록이 말하는 권한 모드

        private func userLine(mode: String?, text: String = "typed on the desktop") -> String {
            var object: [String: Any] = ["type": "user", "sessionId": id, "uuid": UUID().uuidString.lowercased(), "timestamp": "2026-10-22T01:00:00.000Z", "message": ["role": "user", "content": text], "isSidechain": false]
            if let mode { object["permissionMode"] = mode }
            return F.json(object)
        }

        @Test func theCursorCarriesTheLatestUserLinePermissionModeAndFollowsTheTail() throws {
            let home = try ExternalHome()
            defer { home.cleanup() }
            let path = try home.transcript(
                directory: ExternalSessionRules.projectDirectoryName(forCwd: cwd) ?? "", id: id, lines: [userLine(mode: "default"), userLine(mode: "bypassPermissions"), userLine(mode: nil)]
            )
            let reader = ClaudeAppTranscriptReader(claudeDirectory: home.claude)
            guard case .page(let page) = reader.open(sessionID: id, cwd: cwd) else { return }
            #expect(page.cursor.permissionMode == "bypassPermissions", "모드가 없는 줄은 앞의 값을 지우지 않는다")
            let handle = try #require(FileHandle(forWritingAtPath: path))
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: Data((userLine(mode: "acceptEdits") + "\n").utf8))
            guard case .turns(_, let next, _) = reader.newer(page.cursor) else {
                Issue.record("이어 읽지 못했다")
                return
            }
            #expect(next.permissionMode == "acceptEdits")
            guard case .turns(_, let quiet, _) = reader.newer(next) else { return }
            #expect(quiet.permissionMode == "acceptEdits", "읽을 것이 없는 번에도 값이 남는다")
        }

        @Test func aSidechainOrOversizedModeValueIsIgnoredAndTheModeNeverShowsInTheTurns() throws {
            let home = try ExternalHome()
            defer { home.cleanup() }
            let side = F.json([
                "type": "user", "sessionId": id, "isSidechain": true, "permissionMode": "bypassPermissions", "timestamp": "2026-10-22T01:00:00.000Z", "message": ["role": "user", "content": "side"],
            ])
            try home.transcript(
                directory: ExternalSessionRules.projectDirectoryName(forCwd: cwd) ?? "", id: id, lines: [userLine(mode: "default"), side, userLine(mode: String(repeating: "x", count: 100))]
            )
            guard case .page(let page) = ClaudeAppTranscriptReader(claudeDirectory: home.claude).open(sessionID: id, cwd: cwd) else { return }
            #expect(page.cursor.permissionMode == "default", "서브에이전트 줄 · 너무 긴 값은 읽지 않는다")
            #expect(!"\(page.turns)".contains("bypassPermissions"))
        }

        // MARK: 서버 저장용 ref

        @Test func theChatRefIsAKeyedHashSeparatedFromTheSessionRefAndStableForTheSameSeed() throws {
            let key = ExternalSessionKey(bytes: Data(repeating: 7, count: 32))
            let other = ExternalSessionKey(bytes: Data(repeating: 8, count: 32))
            let ref = key.chatRef("user\nsession\nmsg-1\n4242")
            #expect(ref.wholeMatch(of: /[0-9a-f]{64}/) != nil)
            #expect(ref == key.chatRef("user\nsession\nmsg-1\n4242"))
            #expect(ref != key.chatRef("user\nsession\nmsg-2\n4242") && ref != other.chatRef("user\nsession\nmsg-1\n4242"))
            #expect(key.chatRef("x") != key.ref(forSessionID: "x"), "다른 용도의 값이라 서로 겹치지 않는다")
            #expect(!ref.contains("msg-1") && !ref.contains("session"))
        }
    }
}
#endif
