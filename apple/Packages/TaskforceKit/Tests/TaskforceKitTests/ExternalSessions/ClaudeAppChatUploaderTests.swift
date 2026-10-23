#if os(macOS) && DEBUG
import Foundation
import Testing
@testable import TaskforceKit

/// 올리기를 대신하는 가짜: 받은 요청을 기록하고, 정해 둔 결과를 차례로 낸다 (남은 것이 없으면 `saved`)
final class ClaudeAppPutScript: @unchecked Sendable {
    private let lock = NSLock()
    private var _requests: [ClaudeAppChatPutRequest] = []
    private var outcomes: [ClaudeAppChatUploader.PutOutcome] = []

    var requests: [ClaudeAppChatPutRequest] { lock.withLock { _requests } }
    func queue(_ outcome: ClaudeAppChatUploader.PutOutcome...) { lock.withLock { outcomes += outcome } }
    func queue(repeating outcome: ClaudeAppChatUploader.PutOutcome, count: Int) { lock.withLock { outcomes += Array(repeating: outcome, count: count) } }

    var put: ClaudeAppChatUploader.Put {
        { [self] request in
            lock.withLock {
                _requests.append(request)
                return outcomes.isEmpty ? .saved(chatID: UUID()) : outcomes.removeFirst()
            }
        }
    }

    var bodies: [String] { requests.map { String(decoding: (try? TaskforceJSON.encoder().encode($0)) ?? Data(), as: UTF8.self) } }
}

extension ExternalSessionSuites {
    /// 저장 올리기 (PR-D3k, 계약 25.4.5 · 26장 · 위협 DT11 · DT14 · DT15 · 서버 노트 5장): **메모리 큐만**(디스크 0), 2초마다 묶어 PUT, 실패하면 2 · 4 · 8 … 최대 60초로 물러나고 10분이 지나면 버린다.
    /// 로그아웃 때 비운다. `status`가 404면 업로더를 만들지 않는다 (서버로 글 0). 실제 서버 · 네트워크는 부르지 않는다 (가짜 PUT · 손으로 흘리는 시계)
    struct ClaudeAppChatUploaderTests {
        let bridge = UUID(uuidString: "11111111-2222-4333-8444-555555555555")!
        let sessionRef = String(repeating: "a", count: 64)
        let clock = ClaudeAppClock()

        private func context(title: String? = "Fix the thing") -> ClaudeAppChatContext { ClaudeAppChatContext(bridgeID: bridge, sessionRef: sessionRef, title: title) }

        private func ref(_ n: Int) -> String { String(format: "%064x", n) }

        private func user(_ n: Int = 1, body: String = "hello") -> ClaudeAppChatRow {
            ClaudeAppChatRow(macRef: ref(n), role: .user, replyToRef: nil, body: body, truncated: false, saidAt: Date(timeIntervalSince1970: 1_800_000_000), toolNames: [])
        }

        private func answer(_ n: Int, to user: Int = 1, body: String = "reply", tools: [String] = []) -> ClaudeAppChatRow {
            ClaudeAppChatRow(macRef: ref(n), role: .assistant, replyToRef: ref(user), body: body, truncated: false, saidAt: Date(timeIntervalSince1970: 1_800_000_005.25), toolNames: tools)
        }

        private func batch(_ rows: [ClaudeAppChatRow], exchange: String = "x1", title: String? = "Fix the thing") -> ClaudeAppChatBatch {
            ClaudeAppChatBatch(exchangeID: exchange, context: context(title: title), rows: rows)
        }

        private func uploader(
            _ script: ClaudeAppPutScript, configuration: ClaudeAppChatUploader.Configuration = .init(), sleeper: ClaudeAppManualSleeper = ClaudeAppManualSleeper(), log: RelayLog = RelayLog(),
            gaveUp: GaveUpLog = GaveUpLog(), disabled: ClaudeAppFlag = ClaudeAppFlag()
        ) -> ClaudeAppChatUploader {
            ClaudeAppChatUploader(
                configuration: configuration, put: script.put, now: { [clock] in clock.now }, sleep: { await sleeper.sleep($0) }, log: log, onGaveUp: { gaveUp.add($0) }, onDisabled: { _ in disabled.set() }
            )
        }

        // MARK: 되살아나지 않는 업로더 (OA PR-D3 검토 P3-7) · bridge만 끄기 (P3-10) · 이미 센 글 (P3-12)

        @Test func aRetiredUploaderStaysOffEvenIfClearedAndNothingFromItEverGoesOut() async throws {
            let script = ClaudeAppPutScript()
            let uploader = uploader(script)
            await uploader.enqueue(batch([user(), answer(2)]))
            await uploader.retire()
            let enabledAfterRetire = await uploader.isEnabled
            let pendingAfterRetire = await uploader.pendingRows
            #expect(!enabledAfterRetire && pendingAfterRetire == 0)
            await uploader.clear()
            let enabledAfterClear = await uploader.isEnabled
            #expect(!enabledAfterClear, "버린 업로더는 `clear()`로 되살아나지 않는다")
            await uploader.enqueue(batch([user(), answer(2)], exchange: "x2"))
            clock.advance(100)
            await uploader.flush()
            let pending = await uploader.pendingRows
            #expect(script.requests.isEmpty && pending == 0)
        }

        @Test func aNotFoundThatNamesTheBridgeDropsOnlyThatBridgeWhileAGateOffNotFoundTurnsEverythingOff() async throws {
            let other = UUID(uuidString: "99999999-2222-4333-8444-555555555555")!
            let gone = ClaudeAppChatBatch(exchangeID: "gone", context: context(), rows: [user(), answer(2)])
            let alive = ClaudeAppChatBatch(exchangeID: "alive", context: ClaudeAppChatContext(bridgeID: other, sessionRef: sessionRef, title: nil), rows: [user(11), answer(12, to: 11)])
            let script = ClaudeAppPutScript()
            script.queue(.bridgeGone)
            let disabled = ClaudeAppFlag()
            let uploader = uploader(script, disabled: disabled)
            await uploader.enqueue(gone)
            await uploader.enqueue(alive)
            await uploader.flush()
            #expect(script.requests.count == 2, "그 bridge의 묶음은 버려지고 다른 bridge의 묶음은 간다")
            #expect(script.requests.last?.messages.map(\.body) == ["hello", "reply"] && script.requests.last?.bridgeID == other.uuidString.lowercased())
            let stillEnabled = await uploader.isEnabled
            #expect(stillEnabled && !disabled.isSet, "업로더 전체를 끄지 않는다")
            await uploader.enqueue(ClaudeAppChatBatch(exchangeID: "gone2", context: context(), rows: [user(21), answer(22, to: 21)]))
            clock.advance(10)
            await uploader.flush()
            #expect(script.requests.count == 2, "사라진 bridge의 새 묶음은 올리지 않는다")
            // gate가 꺼진 404(`not_found`)는 모든 것이 꺼진 것이다
            let all = ClaudeAppPutScript()
            all.queue(.disabled)
            let flag = ClaudeAppFlag()
            let off = self.uploader(all, disabled: flag)
            await off.enqueue(alive)
            await off.flush()
            let offEnabled = await off.isEnabled
            #expect(!offEnabled && flag.isSet)
        }

        @Test func theServersTwoNotFoundAnswersAreToldApartByTheirCode() {
            // `bridge_not_found`(`APIErrorCode.bridgeNotFound`)만 그 bridge가 사라진 것이다. 알려진 `not_found`(= gate가 꺼짐) · 모르는 코드의 404 · 앞단의 404는 모두 꺼진 것이다 (OA PR-D3 재검토)
            #expect(ClaudeAppChatUploader.outcome(for: APIError.server(status: 404, code: .notFound, message: "")) == .disabled)
            #expect(ClaudeAppChatUploader.outcome(for: APIError.server(status: 404, code: .bridgeNotFound, message: "이 Mac을 찾지 못했습니다.")) == .bridgeGone)
            #expect(ClaudeAppChatUploader.outcome(for: APIError.server(status: 404, code: .internalError, message: "모르는 코드")) == .disabled, "모르는 코드의 404는 모두 끈다: 닫힌 쪽이다")
            #expect(ClaudeAppChatUploader.outcome(for: APIError.unexpectedStatus(404)) == .disabled, "앞단이 낸 HTML 404는 꺼진 것이다")
            #expect(APIErrorCode(rawValue: "bridge_not_found") == .bridgeNotFound, "서버의 코드 이름 그대로")
            #expect(ClaudeAppChatUploader.outcome(for: APIError.server(status: 413, code: .internalError, message: "")) == .quota)
        }

        @Test func anExchangeWhoseUserRowWasAlreadySavedIsMarkedSoAGiveUpIsNotCountedTwice() async throws {
            let script = ClaudeAppPutScript()
            script.queue(.saved(chatID: UUID()))
            script.queue(repeating: .retry, count: 100)
            let gaveUp = GaveUpLog()
            let uploader = uploader(script, gaveUp: gaveUp)
            await uploader.enqueue(batch([user(), answer(2)], exchange: "x1"))
            await uploader.flush()
            let savedEarly = await uploader.userRowSaved("x1")
            #expect(savedEarly, "사용자 행이 올라갔다: 서버가 이미 `received`를 셌다")
            await uploader.enqueue(batch([user(), answer(2), answer(3)], exchange: "x1"))
            for _ in 0..<700 {
                clock.advance(1)
                await uploader.flush()
            }
            #expect(gaveUp.all == ["x1"], "답 행은 포기했다")
            let savedLater = await uploader.userRowSaved("x1")
            let neverSent = await uploader.userRowSaved("never-sent")
            #expect(savedLater && !neverSent)
        }

        // MARK: 요청 모양 (서버 strict 스키마)

        @Test func theRequestCarriesOnlyTheServersFieldsWithTheUserRowFirstAndNamesOnlyForTools() throws {
            let rows = [user(), answer(2, tools: ["Read", "Edit"]), answer(3)]
            let request = ClaudeAppChatPutRequest(context: context(), rows: rows)
            let object = try #require(try JSONSerialization.jsonObject(with: TaskforceJSON.encoder().encode(request)) as? [String: Any])
            #expect(Set(object.keys) == ["bridge_id", "session_ref", "title", "messages"])
            #expect(object["bridge_id"] as? String == "11111111-2222-4333-8444-555555555555" && object["session_ref"] as? String == sessionRef && object["title"] as? String == "Fix the thing")
            let messages = try #require(object["messages"] as? [[String: Any]])
            #expect(messages.map { $0["role"] as? String } == ["user", "assistant", "assistant"])
            #expect(Set(messages[0].keys) == ["mac_ref", "role", "body", "truncated", "said_at"], "사용자 행에는 reply_to_ref · tool_names가 없다")
            #expect(Set(messages[1].keys) == ["mac_ref", "role", "reply_to_ref", "body", "truncated", "said_at", "tool_names"])
            #expect(messages[1]["tool_names"] as? [String] == ["Read", "Edit"] && messages[1]["reply_to_ref"] as? String == ref(1))
            #expect(Set(messages[2].keys) == ["mac_ref", "role", "reply_to_ref", "body", "truncated", "said_at"], "도구가 없으면 칸을 뺀다")
            #expect(messages[0]["said_at"] as? String == "2027-01-15T08:00:00.000Z" && messages[1]["said_at"] as? String == "2027-01-15T08:00:05.250Z", "소수 초 · Z")
        }

        @Test func aMissingTitleLeavesTheFieldOutSoTheServerKeepsTheStoredOne() throws {
            let request = ClaudeAppChatPutRequest(context: context(title: nil), rows: [user()])
            let object = try #require(try JSONSerialization.jsonObject(with: TaskforceJSON.encoder().encode(request)) as? [String: Any])
            #expect(object["title"] == nil)
        }

        @Test func theDescriptionNeverPrintsTextRefsOrTheTitle() {
            let request = ClaudeAppChatPutRequest(context: context(), rows: [user(body: "SENTINEL-BODY")])
            for text in ["\(request)", String(reflecting: request), "\(context())", "\(user())"] {
                #expect(!text.contains("SENTINEL") && !text.contains("Fix the thing") && !text.contains(sessionRef))
            }
        }

        @Test func theStatusAnswerIsClampedToWhatTheServerAccepts() throws {
            let decoder = TaskforceJSON.decoder()
            let normal = try decoder.decode(ClaudeAppChatsStatus.self, from: Data(#"{"save":true,"max_batch":20,"max_bytes":262144}"#.utf8))
            #expect(normal == ClaudeAppChatsStatus(save: true, maxBatch: 20, maxBytes: 262_144))
            let bare = try decoder.decode(ClaudeAppChatsStatus.self, from: Data(#"{"save":true}"#.utf8))
            #expect(bare.maxBatch == 20 && bare.maxBytes == 262_144, "max_bytes가 없으면 262144")
            let wild = try decoder.decode(ClaudeAppChatsStatus.self, from: Data(#"{"save":true,"max_batch":500,"max_bytes":1}"#.utf8))
            #expect(wild.maxBatch == 20 && wild.maxBytes == 4096, "서버 상한을 넘기지 않고 너무 작은 값은 올린다")
        }

        // MARK: 묶기

        @Test func rowsAreSentInBatchesOfTwentyWithTheUserRowInTheFirstOne() async throws {
            let script = ClaudeAppPutScript()
            let uploader = uploader(script)
            await uploader.enqueue(batch([user()] + (2...46).map { answer($0) }))
            await uploader.flush()
            #expect(script.requests.map(\.messages.count) == [20, 20, 6])
            #expect(script.requests[0].messages.first?.role == "user")
            #expect(await uploader.pendingRows == 0)
        }

        @Test func aBatchStaysUnderTheServersByteLimitEvenWithBigBodies() async throws {
            let script = ClaudeAppPutScript()
            let uploader = uploader(script, configuration: .init(maxBatch: 20, maxBytes: 30_000))
            let big = String(repeating: "한", count: 6_000)
            await uploader.enqueue(batch([user()] + (2...6).map { answer($0, body: big) }))
            await uploader.flush()
            #expect(script.requests.count >= 3)
            #expect(script.requests.allSatisfy { $0.encodedSize <= 30_000 })
            #expect(script.requests.flatMap(\.messages).count == 6, "행은 하나도 잃지 않는다")
        }

        @Test func aSingleRowThatCanNeverFitIsDroppedAndTheRestGo() async throws {
            let script = ClaudeAppPutScript()
            let log = RelayLog()
            let uploader = uploader(script, configuration: .init(maxBatch: 20, maxBytes: 10_000), log: log)
            await uploader.enqueue(batch([user(), answer(2, body: String(repeating: "x", count: 20_000)), answer(3)]))
            await uploader.flush()
            #expect(script.requests.flatMap(\.messages).map(\.macRef) == [ref(1), ref(3)])
            #expect(log.events("claude_app_chat_upload").contains { $0["result"] == .code("row_too_large") })
        }

        // MARK: 멱등 · 순서

        @Test func theSameRowQueuedTwiceIsUploadedOnce() async throws {
            let script = ClaudeAppPutScript()
            let uploader = uploader(script)
            await uploader.enqueue(batch([user(), answer(2)]))
            await uploader.enqueue(batch([user(), answer(2), answer(3)]))
            await uploader.flush()
            #expect(script.requests.flatMap(\.messages).map(\.macRef) == [ref(1), ref(2), ref(3)])
            await uploader.enqueue(batch([user(), answer(2), answer(3)]))
            await uploader.flush()
            #expect(script.requests.count == 1, "이미 올린 줄을 다시 올리지 않는다")
        }

        @Test func answersWaitUntilTheUserRowOfTheirExchangeIsSaved() async throws {
            let script = ClaudeAppPutScript()
            script.queue(.retry)
            let uploader = uploader(script)
            await uploader.enqueue(batch([user()]))
            await uploader.flush()
            await uploader.enqueue(batch([user(), answer(2)]))
            clock.advance(2)
            await uploader.flush()
            // 첫 시도는 실패, 그다음 묶음은 사용자 행을 먼저 담고 답이 뒤따른다 (사용자 행 없이 답만 가지 않는다)
            #expect(script.requests.count == 2)
            #expect(script.requests[1].messages.map(\.role) == ["user", "assistant"])
        }

        @Test func anAnswerRowNeverGoesAloneBeforeItsUserRowWasSaved() async throws {
            let script = ClaudeAppPutScript()
            script.queue(repeating: .retry, count: 3)
            let uploader = uploader(script)
            await uploader.enqueue(batch([user()]))
            await uploader.flush()
            #expect(script.requests.count == 1)
            // 사용자 행은 물러나는 중이다(2초): 그동안 들어온 답 행만으로는 보내지 않는다 (서버에서 orphan이 된다)
            await uploader.enqueue(batch([answer(2)], exchange: "x1"))
            clock.advance(1)
            await uploader.flush()
            #expect(script.requests.count == 1, "답 행만 따로 보내지 않는다")
            clock.advance(1)
            await uploader.flush()
            #expect(script.requests.count == 2 && script.requests[1].messages.map(\.role) == ["user", "assistant"], "사용자 행 때가 되면 함께 간다")
        }

        // MARK: 물러남 · 버림

        @Test func aFailureBacksOffTwoFourEightUpToSixtySecondsAndNothingGoesBeforeItsTime() async throws {
            let script = ClaudeAppPutScript()
            script.queue(repeating: .retry, count: 8)
            let uploader = uploader(script)
            await uploader.enqueue(batch([user()]))
            var attempts: [TimeInterval] = []
            var waited: TimeInterval = 0
            await uploader.flush()
            var count = script.requests.count
            attempts.append(0)
            // 1초씩 시계를 올려 가며 시도 시각을 잰다
            while attempts.count < 8, waited < 400 {
                clock.advance(1)
                waited += 1
                await uploader.flush()
                if script.requests.count > count {
                    count = script.requests.count
                    attempts.append(waited)
                }
            }
            let gaps = zip(attempts.dropFirst(), attempts).map { $0 - $1 }
            #expect(gaps == [2, 4, 8, 16, 32, 60, 60], "2 · 4 · 8 · 16 · 32 · 60 · 60")
        }

        @Test func aRowThatCouldNotBeUploadedForTenMinutesIsDroppedOnceAndTheGiveUpIsReported() async throws {
            let script = ClaudeAppPutScript()
            script.queue(repeating: .retry, count: 100)
            let gaveUp = GaveUpLog()
            let log = RelayLog()
            let uploader = uploader(script, log: log, gaveUp: gaveUp)
            await uploader.enqueue(batch([user(), answer(2)], exchange: "x7"))
            for _ in 0..<700 {
                clock.advance(1)
                await uploader.flush()
            }
            #expect(await uploader.pendingRows == 0, "10분 뒤 버렸다")
            #expect(gaveUp.all == ["x7"], "교환마다 한 번만 알린다")
            let sent = script.requests.count
            #expect(sent > 3 && sent < 30, "분 단위로 두드리지 않았다")
            #expect(log.events("claude_app_chat_upload").contains { $0["result"] == .code("gave_up") })
            clock.advance(100)
            await uploader.flush()
            #expect(script.requests.count == sent, "버린 뒤에는 다시 보내지 않는다")
        }

        @Test func aRateLimitOrLockOrServerErrorIsRetriedAndABadRequestIsDroppedWithoutRetry() async throws {
            let script = ClaudeAppPutScript()
            script.queue(.invalid)
            let uploader = uploader(script)
            await uploader.enqueue(batch([user()]))
            await uploader.flush()
            #expect(await uploader.pendingRows == 0, "400은 버그: 재시도하지 않는다")
            clock.advance(100)
            await uploader.flush()
            #expect(script.requests.count == 1)
        }

        // MARK: 한도 (413)

        @Test func theQuotaAnswerIsNotHammeredItWaitsFiveMinutesOnceAndIsDroppedWithTheRestAtTenMinutes() async throws {
            let script = ClaudeAppPutScript()
            script.queue(repeating: .quota, count: 10)
            let gaveUp = GaveUpLog()
            let uploader = uploader(script, gaveUp: gaveUp)
            await uploader.enqueue(batch([user()], exchange: "q1"))
            await uploader.flush()
            #expect(await uploader.quotaReached)
            for _ in 0..<299 {
                clock.advance(1)
                await uploader.flush()
            }
            #expect(script.requests.count == 1, "5분 안에는 다시 두드리지 않는다")
            clock.advance(1)
            await uploader.flush()
            #expect(script.requests.count == 2, "5분에 한 번")
            for _ in 0..<310 {
                clock.advance(2)
                await uploader.flush()
            }
            let leftover = await uploader.pendingRows
            #expect(script.requests.count == 2 && gaveUp.all == ["q1"] && leftover == 0, "10분 안에 더 두드리지 않고 버리며 포기를 알린다")
        }

        // MARK: 서버가 말한 것

        @Test func aNullChatMeansTheUserDeletedItSoThatExchangeStopsButANewOneStillUploads() async throws {
            let script = ClaudeAppPutScript()
            script.queue(.saved(chatID: nil))
            let uploader = uploader(script)
            await uploader.enqueue(batch([user(1), answer(2)], exchange: "gone"))
            await uploader.flush()
            await uploader.enqueue(batch([user(1), answer(2), answer(3)], exchange: "gone"))
            await uploader.flush()
            let leftover = await uploader.pendingRows
            #expect(script.requests.count == 1 && leftover == 0, "그 교환의 남은 행은 더 올리지 않는다")
            await uploader.enqueue(batch([user(10), answer(11, to: 10)], exchange: "new"))
            await uploader.flush()
            #expect(script.requests.count == 2 && script.requests[1].messages.first?.macRef == ref(10), "같은 세션의 새 글은 새 채팅을 만든다")
            #expect(await uploader.isEnabled)
        }

        @Test func aNotFoundAnswerTurnsTheUploaderOffClearsTheQueueAndTellsTheOwner() async throws {
            let script = ClaudeAppPutScript()
            script.queue(.disabled)
            let off = ClaudeAppFlag()
            let uploader = uploader(script, disabled: off)
            await uploader.enqueue(batch([user(), answer(2)]))
            await uploader.enqueue(batch([user(5)], exchange: "other"))
            await uploader.flush()
            let enabled = await uploader.isEnabled
            let leftover = await uploader.pendingRows
            #expect(off.isSet && !enabled && leftover == 0)
            await uploader.enqueue(batch([user(9)], exchange: "later"))
            clock.advance(10)
            await uploader.flush()
            #expect(script.requests.count == 1, "꺼진 업로더는 더 보내지 않는다")
        }

        // MARK: 로그아웃

        @Test func clearingOnLogoutDropsEverythingQueuedAndForgetsWhatWasSeen() async throws {
            let script = ClaudeAppPutScript()
            script.queue(.retry)
            let uploader = uploader(script)
            await uploader.enqueue(batch([user(), answer(2)]))
            await uploader.flush()
            await uploader.clear()
            #expect(await uploader.pendingRows == 0)
            clock.advance(100)
            await uploader.flush()
            #expect(script.requests.count == 1, "로그아웃 뒤에는 보내지 않는다")
            await uploader.enqueue(batch([user(), answer(2)]))
            await uploader.flush()
            #expect(script.requests.count == 2, "비운 뒤 다시 들어온 행은 새 계정의 것으로 올린다")
        }

        // MARK: 루프

        @Test func theLoopWakesEveryTwoSecondsAndStopsWhenAskedTo() async throws {
            let script = ClaudeAppPutScript()
            let sleeper = ClaudeAppManualSleeper()
            let uploader = uploader(script, sleeper: sleeper)
            await uploader.enqueue(batch([user()]))
            await uploader.start()
            #expect(await relayEventually { sleeper.pending == 1 })
            #expect(sleeper.requested == [2])
            sleeper.advance(2)
            #expect(await relayEventually { script.requests.count == 1 })
            await uploader.stop()
            #expect(await relayEventually { sleeper.pending == 0 })
        }

        // MARK: 오류 → 결과

        @Test func serverAnswersAreMappedToWhatTheUploaderDoes() {
            typealias U = ClaudeAppChatUploader
            func server(_ status: Int, _ code: APIErrorCode = .internalError) -> APIError { .server(status: status, code: code, message: "") }
            #expect(U.outcome(for: server(404, .notFound)) == .disabled && U.outcome(for: APIError.unexpectedStatus(404)) == .disabled, "저장 꺼짐 · bridge 없음 · route 없음")
            #expect(U.outcome(for: server(404, .bridgeNotFound)) == .bridgeGone, "`bridge_not_found`만 그 bridge가 사라진 것이다")
            #expect(U.outcome(for: server(404)) == .disabled, "그 밖의 404는 (모르는 코드도) 모두 끈다")
            #expect(U.outcome(for: server(413)) == .quota)
            #expect(U.outcome(for: server(400, .invalidRequest)) == .invalid)
            #expect(U.outcome(for: server(409, .busyRetry)) == .retry && U.outcome(for: server(429, .rateLimited)) == .retry && U.outcome(for: server(500)) == .retry && U.outcome(for: server(503)) == .retry)
            #expect(U.outcome(for: server(401, .unauthorized)) == .retry && U.outcome(for: APIError.transport("offline")) == .retry && U.outcome(for: APIError.notSignedIn) == .retry)
            #expect(U.outcome(for: APIError.decoding("x")) == .retry)
            #expect(U.outcome(for: CancellationError()) == .retry)
        }

        // MARK: 로그는 코드뿐

        @Test func theLogHoldsFixedCodesAndBucketsOnly() async throws {
            let script = ClaudeAppPutScript()
            script.queue(.retry, .invalid)
            let log = RelayLog()
            let uploader = uploader(script, log: log)
            await uploader.enqueue(batch([user(body: "SENTINEL-BODY"), answer(2, body: "SENTINEL-REPLY", tools: ["SentinelTool"])], title: "SENTINEL-TITLE"))
            await uploader.flush()
            clock.advance(2)
            await uploader.flush()
            let text = log.text
            #expect(!text.contains("SENTINEL") && !text.contains(sessionRef) && !text.contains(ref(1)) && !text.contains("11111111"))
            for entry in log.entries {
                #expect(entry.event == "claude_app_chat_upload")
                #expect(entry.fields.keys.allSatisfy { ["result", "rows_bucket"].contains($0) })
            }
        }

        // MARK: DT11 — PUT 본문에 교환 밖 글이 없다

        @Test func theUploadBodyOfAFixtureTranscriptHoldsNoTypedTextOtherPeerToolResultPathOrEmail() async throws {
            let relayPID: Int32 = 4242
            let sent = "Mention the new tests/db file"
            let peer = ClaudeAppPeer(plugin: "tf-relay", verifiedPeerPID: relayPID, messageID: "m1")
            let other = ClaudeAppPeer(plugin: "someone", verifiedPeerPID: 9, messageID: "m2")
            let turns: [ClaudeAppTurn] = [
                ClaudeAppTurn(id: "1", kind: .user("SENTINEL-DESKTOP-TYPED sentinel.person@example-org.test")),
                ClaudeAppTurn(id: "2", kind: .assistant("SENTINEL-DESKTOP-ANSWER")),
                ClaudeAppTurn(id: "3", kind: .peer("SENTINEL-OTHER-PEER", other)),
                ClaudeAppTurn(id: "4", kind: .peer(sent, peer), timestamp: clock.now),
                ClaudeAppTurn(id: "5", kind: .tool(name: "Bash", description: "SENTINEL-TOOL-DESCRIPTION /Users/tester/secret.txt")),
                ClaudeAppTurn(id: "6", kind: .assistant("Done: the answer"), timestamp: clock.now),
                ClaudeAppTurn(id: "7", kind: .user("SENTINEL-DESKTOP-TYPED-LATER")),
                ClaudeAppTurn(id: "8", kind: .assistant("SENTINEL-LATE-ANSWER")),
            ]
            let exchange = ClaudeAppExchangeCollector.collect(
                ClaudeAppExchangeInput(
                    sessionID: ExternalSessionFixture.uuid(1), turns: turns, relayPID: relayPID, sentText: sent, sentAt: clock.now, now: clock.now, turnEnded: false, baseline: [],
                    ref: { String(format: "%064x", $0.hashValue & 0xFFFF_FFFF) }
                )
            )
            let script = ClaudeAppPutScript()
            let uploader = uploader(script)
            await uploader.enqueue(batch(exchange.rows))
            await uploader.flush()
            let body = try #require(script.bodies.first)
            let object = try #require(try JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any])
            let messages = try #require(object["messages"] as? [[String: Any]])
            #expect(messages.map { $0["body"] as? String } == [sent, "Done: the answer"], "사용자 글과 답 글뿐")
            #expect(messages.last?["tool_names"] as? [String] == ["Bash"], "도구는 이름만: 답 앞에서 쓴 Bash의 이름 한 칸")
            for secret in ["SENTINEL", "example-org", "secret.txt", "/Users/tester", "description"] {
                #expect(!body.contains(secret), "\(secret)")
            }
        }
    }

    /// 포기한 교환 id를 모은다
    final class GaveUpLog: @unchecked Sendable {
        private let lock = NSLock()
        private var ids: [String] = []
        func add(_ id: String) { lock.withLock { ids.append(id) } }
        var all: [String] { lock.withLock { ids } }
    }
}
#endif
