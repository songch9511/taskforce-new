#if os(macOS)
import Foundation

// 이 Mac에서 비밀값 답을 내보내는 실제 길 (OA D4b-m-2, 계약 16장). 순서와 결과 표는 D4b-m-1의 `AgentQuestionSecretFlow`가 고정했다 (여기서 바꾸지 않는다):
//   heartbeat가 성공한 **뒤에만** → `LocalSecretAnswers.put`을 **먼저** → `POST /api/v1/bridge/answer-local`(digest만) → 결과에 따라 값을 두거나 지운다.
// 값은 이 Mac의 메모리(`LocalSecretAnswers`)에만 있다. 서버 요청 · 로그 · 디스크 · 덤프에 값이 나오지 않는다: 이 파일은 값을 읽지 않는다 (`put`에 건네는 것과 digest 계산뿐).
// 이 파일은 값을 꺼내지 않는다. 꺼내는 곳은 답 명령을 전달하는 `runAnswer`의 `take` 한 곳이고, 나머지 모든 길은 **버리기만** 한다.

extension BridgeRuntime {
    // MARK: 내보내기

    /// 비밀값 답 하나를 내보낸다. `accountStillMatches`는 "이 런타임의 계정 = 질문 저장소의 계정"인지 본다 (D4bm2-05): 시작 · `put` 앞 · `POST` 앞마다 부르고,
    /// 맞지 않으면 값을 지우고 보내지 않는다 (계정 전환 중에 다른 계정의 서버로 가지 않는다)
    public func submitLocalSecret(_ answer: LocalSecretAnswer, accountStillMatches: @escaping @Sendable () async -> Bool) async -> LocalSecretOutcome {
        // 마무리 모드 · 종료 중인 런타임은 받지 않는다: 값을 두지 않는다
        guard config.mode == .normal, !shuttingDown else { return .unavailable }
        let key = LocalSecretKey(taskID: answer.key.taskID.uuidString, requestID: answer.key.requestID)
        let trace = SecretSubmissionTrace()
        let ports = AgentQuestionSecretFlow.Ports(
            heartbeat: { await self.secretHeartbeat(accountStillMatches) },
            put: { answer in await self.secretPut(answer, key: key, accountStillMatches) },
            erase: { _ in await self.secrets.discard(key: key) },
            reconcile: { await self.secretReconcile() },
            post: { digest in await self.secretPost(digest: digest, key: key, trace: trace, accountStillMatches) },
            pause: { seconds in try? await self.clock.sleep(.seconds(seconds)) }
        )
        let outcome = await AgentQuestionSecretFlow.run(answer, ports: ports)
        // 어떤 결과든 이 길이 끝나면 값은 lease가 가져갈 것만 남는다: 실패 · 닫힘이면 flow가 이미 지웠다. 끝난 결과(`sent`)만 값을 둔다
        if outcome != .sent { await secrets.discard(key: key) }
        return outcome
    }

    /// 포트 ①: 마지막 heartbeat가 신선하면(90초 안) 그대로, 아니면 한 번 보내고 그 성공을 돌려준다 (D4bm2-04). 잠에서 깬 직후의 `not_live`를 막는다
    func secretHeartbeat(_ accountStillMatches: @Sendable () async -> Bool) async -> Bool {
        guard await accountStillMatches(), secretPathOpen, bridgeID != nil, secret != nil else { return false }
        if heartbeatFresh() { return true }
        await sendHeartbeat()
        return heartbeatFresh()
    }

    /// 포트 ②: 값을 **먼저** 둔다. 계정이 어긋났거나 종료 중이거나 **이 런타임의 원장이 그 (task, request)를 열린 비밀값 요청으로 모르면** 두지 않는다
    /// (그러면 `POST`도 가지 않는다: `secretPost`가 값이 있는지 본다). 원장 파티션은 계정마다 갈리므로 이 확인 하나가 계정 전환 틈 · 낡은 카드 · 질문 교체를 로컬에서 함께 닫는다
    func secretPut(_ answer: LocalSecretAnswer, key: LocalSecretKey, _ accountStillMatches: @Sendable () async -> Bool) async {
        guard await accountStillMatches(), secretPathOpen, await ledgerKnowsOpenSecret(key) else { return }
        await secrets.put(key: key, value: Self.wireValue(answer), at: clock.now())
    }

    /// 원장의 그 task가 이 런타임의 adapter 것이고, 그 요청이 지금 열려 있는 비밀값 요청이며 닫히지 않았다. 원장을 읽지 못하면 아니다
    func ledgerKnowsOpenSecret(_ key: LocalSecretKey) async -> Bool {
        guard let task = try? await ledger.task(key.taskID), adapters[task.adapter] != nil else { return false }
        return task.openRequestID == key.requestID && task.openRequestSecret && !task.closedRequestIDs.contains(key.requestID)
    }

    /// 포트 ⑤: 작업을 되살린다 (`not_live` 뒤 한 번): heartbeat · reconcile을 강제로 돌린다
    func secretReconcile() async {
        forceHeartbeat = true
        needsReconcile = true
        await tick(reason: .heartbeat)
    }

    /// 포트 ③: `POST /api/v1/bridge/answer-local`. 본문은 digest뿐이다. 계정이 어긋났거나 상태가 막혔으면 값을 지우고 보내지 않는다.
    /// 값이 메모리에 없으면(정산 · 전달 · 보관 정리가 가져갔다) 보내지 않고 원장으로 그 요청이 어떻게 됐는지 본다 (`secretGoneReply`)
    func secretPost(digest: String, key: LocalSecretKey, trace: SecretSubmissionTrace, _ accountStillMatches: @Sendable () async -> Bool) async -> AgentQuestionSecretFlow.Reply {
        guard await accountStillMatches(), secretPathOpen else {
            await secrets.discard(key: key)
            return .http(400)
        }
        guard await secrets.contains(key: key) else { return await secretGoneReply(key, afterPost: trace.posted) }
        guard let bridgeID else { return .network }
        trace.markPosted()
        let request = BridgeV1AnswerLocalRequest(bridgeID: bridgeID, agentTaskID: key.taskID, requestDigest: digest)
        let result: AnswerLocalResult
        do {
            // `authed`가 401 회복 · 403 폐기 · 429 멈춤 · 늦은 응답 버리기를 맡는다. 409 · 400은 `authed`가 하나(`badRequest`)로 합치고 5xx는 런타임 전체를 오프라인으로 돌리므로
            // 여기서 먼저 상태 그대로 구분한다 (결과 표가 다르다: 400은 지우고 끝, 409 · 5xx는 같은 요청을 다시).
            // 404는 이 route에서 도메인 결과다 (세션이 닫혔다 · 질문이나 bridge가 쓰는 도중 바뀌었다 · 이 사용자의 task가 아니다): "bridge 행이 없다"로 읽어 `clearBridge()`(다시 등록)하지 않는다 → `ackNotFound`
            result = try await authed(.answerLocal, ackNotFound: true) { [client] secret in
                do {
                    return .response(try await client.answerLocal(request, secret: secret))
                } catch BridgeClientError.conflict {
                    return .status(409)
                } catch BridgeClientError.badRequest {
                    return .status(400)
                } catch BridgeClientError.server(let status) {
                    return .status(status)
                }
            }
        } catch let failure as RouteFailure {
            return Self.reply(for: failure)
        } catch {
            return .network
        }
        let reply = Self.reply(for: result)
        log.log("secret_answer_post", ["result": .code(Self.code(of: reply))])
        return reply
    }

    /// 값이 없는데 POST 차례가 왔다. 원장의 그 요청: 닫혔다 → 질문이 닫혔다 · 이 제출이 이미 POST한 뒤인데 열린 요청이 없고(전달이 비운다) 닫히지도 않았다 = 서버가 만든 답 명령이 전달됐다 → 보냈다 ·
    /// 그 밖(원장이 모름 · 아직 열려 있는데 값만 없음 · 아직 POST 전)은 실패다. 전달된 값을 거짓 "Couldn't send"로 보이지 않게 한다
    func secretGoneReply(_ key: LocalSecretKey, afterPost: Bool) async -> AgentQuestionSecretFlow.Reply {
        guard let task = try? await ledger.task(key.taskID) else { return .http(400) }
        if task.closedRequestIDs.contains(key.requestID) { return .stale(.questionClosed) }
        // 전달은 열린 요청 표시를 비운다(`.delivered` 분기). 다른 질문 R2가 열렸다면(교체) 전달된 것이 아니다
        if afterPost, task.openRequestID == nil { return .duplicate }
        return .http(400)
    }

    // MARK: 값의 수명 (F2 notes 10장 6 · 7)

    /// 값을 둘 수 있는 상태인가: 네트워크가 켜져 있고, 종료 중이 아니고, 사용자 행동을 기다리는 상태(폐기 · 자격 거절 · Mac 10대)가 아니다
    var secretPathOpen: Bool {
        active && !shuttingDown && ![.revoked, .tooManyBridges, .credentialRejected].contains(statusValue)
    }

    /// 보관 정리 (housekeeping): TTL(`deliveryWindow` 24시간)이 지난 값과, 원장이 더는 열린 것으로 보지 않는 요청의 값을 버린다 (D4bm2-02)
    func dropStaleSecrets() async {
        let expired = await secrets.dropExpired(now: clock.now(), ttl: Self.deliveryWindow)
        var closed = 0
        for key in await secrets.keys {
            let task: BridgeTaskRecord?
            do { task = try await ledger.task(key.taskID) } catch { continue } // 원장을 읽지 못하면 판단하지 않는다 (TTL이 지킨다)
            // 취소된 task(`cancelled`: 서버도 끝)에는 값을 받아 갈 답 명령이 다시 오지 않는다: 열린 요청이 남아 있어도 버린다
            if let task, task.openRequestID == key.requestID, !task.closedRequestIDs.contains(key.requestID), !Self.terminalTaskStates.contains(task.lastState) { continue }
            if await secrets.discard(key: key) { closed += 1 }
        }
        if expired + closed > 0 { log.log("secret_answers_dropped", ["expired": .count(expired), "closed": .count(closed)]) }
    }

    /// 서버에서도 원장에서도 끝인 task 상태. `failed`는 넣지 않는다: 답 명령이 `not_received`로 정산되면 서버는 질문을 복원하는데 로컬 task만 `failed`로 남는다 (재검토 1)
    static let terminalTaskStates: Set<String> = ["cancelled"]

    /// 정산 때 버린다: 요청 id를 아는 정산 (닫기 · 전달 끝)
    func settleSecret(taskID: String, requestID: String) async {
        await secrets.discard(key: LocalSecretKey(taskID: taskID, requestID: requestID))
    }

    // MARK: 변환 · 결과 표

    private enum AnswerLocalResult: Sendable {
        case response(BridgeV1AnswerLocalResponse)
        /// `authed`가 구분하지 못하는 HTTP 상태 (409 · 400)
        case status(Int)
    }

    /// 입력한 답을 adapter가 받는 모양(`{질문 id: 값}`)으로 바꾼다. 바꾼 사본은 곧바로 `LocalSecretAnswers.put`의 상자로 들어간다
    static func wireValue(_ answer: LocalSecretAnswer) -> AgentAnswerValue {
        AgentAnswerValue(answers: answer.revealed().mapValues { value -> BridgeV1AnswerValue in
            switch value {
            case .text(let text): .one(text)
            case .choices(let choices): .many(choices)
            }
        })
    }

    private static func reply(for result: AnswerLocalResult) -> AgentQuestionSecretFlow.Reply {
        switch result {
        case .status(let status): return .http(status)
        case .response(let response):
            switch response {
            case .answered: return .answered
            case .duplicate: return .duplicate
            case .stale(let reason):
                switch reason {
                case .questionClosed: return .stale(.questionClosed)
                case .notLive: return .stale(.notLive)
                case .notSecret: return .stale(.notSecret)
                case .unknown: return .http(400) // 모르는 이유: 값을 지우고 "Couldn't send"
                }
            case .unknown: return .http(400)
            }
        }
    }

    private static func reply(for failure: RouteFailure) -> AgentQuestionSecretFlow.Reply {
        switch failure {
        case .blocked, .offline, .cancelled: .network
        case .rateLimited: .http(429)
        case .revoked: .http(403)
        case .credentialRejected: .http(401)
        case .bridgeGone, .notFound: .http(404)
        case .accountLeft, .accountMismatch, .badRequest: .http(400)
        }
    }

    /// 로그에 남기는 결과 이름 (고정 단어뿐)
    private static func code(of reply: AgentQuestionSecretFlow.Reply) -> String {
        switch reply {
        case .answered: "answered"
        case .duplicate: "duplicate"
        case .stale(.questionClosed): "stale_question_closed"
        case .stale(.notLive): "stale_not_live"
        case .stale(.notSecret): "stale_not_secret"
        case .http(let status): "http_\(status)"
        case .network: "network"
        }
    }
}

/// 한 번의 `submitLocalSecret`이 POST를 이미 보냈는지 (재시도 때 "값이 없다"가 전달된 것인지 가르는 데만 쓴다). 값은 담지 않는다
final class SecretSubmissionTrace: @unchecked Sendable {
    private let lock = NSLock()
    private var didPost = false

    var posted: Bool { lock.withLock { didPost } }
    func markPosted() { lock.withLock { didPost = true } }
}
#endif
