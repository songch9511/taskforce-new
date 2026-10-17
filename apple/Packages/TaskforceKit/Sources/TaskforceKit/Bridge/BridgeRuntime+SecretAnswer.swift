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
        let ports = AgentQuestionSecretFlow.Ports(
            heartbeat: { await self.secretHeartbeat(accountStillMatches) },
            put: { answer in await self.secretPut(answer, key: key, accountStillMatches) },
            erase: { _ in await self.secrets.discard(key: key) },
            reconcile: { await self.secretReconcile() },
            post: { digest in await self.secretPost(digest: digest, key: key, accountStillMatches) },
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

    /// 포트 ②: 값을 **먼저** 둔다. 계정이 어긋났거나 종료 중이면 두지 않는다 (그러면 `POST`도 가지 않는다: `secretPost`가 값이 있는지 본다)
    func secretPut(_ answer: LocalSecretAnswer, key: LocalSecretKey, _ accountStillMatches: @Sendable () async -> Bool) async {
        guard await accountStillMatches(), secretPathOpen else { return }
        await secrets.put(key: key, value: Self.wireValue(answer), at: clock.now())
    }

    /// 포트 ⑤: 작업을 되살린다 (`not_live` 뒤 한 번): heartbeat · reconcile을 강제로 돌린다
    func secretReconcile() async {
        forceHeartbeat = true
        needsReconcile = true
        await tick(reason: .heartbeat)
    }

    /// 포트 ③: `POST /api/v1/bridge/answer-local`. 본문은 digest뿐이다. 값이 메모리에 없거나(버려졌다) 계정이 어긋났으면 보내지 않는다
    func secretPost(digest: String, key: LocalSecretKey, _ accountStillMatches: @Sendable () async -> Bool) async -> AgentQuestionSecretFlow.Reply {
        guard await accountStillMatches(), secretPathOpen, await secrets.contains(key: key) else {
            await secrets.discard(key: key)
            return .http(400)
        }
        guard let bridgeID else { return .network }
        let request = BridgeV1AnswerLocalRequest(bridgeID: bridgeID, agentTaskID: key.taskID, requestDigest: digest)
        let result: AnswerLocalResult
        do {
            // `authed`가 401 회복 · 403 폐기 · 429 멈춤 · 늦은 응답 버리기를 맡는다. 409 · 400은 `authed`가 하나(`badRequest`)로 합치고 5xx는 런타임 전체를 오프라인으로 돌리므로
            // 여기서 먼저 상태 그대로 구분한다 (결과 표가 다르다: 400은 지우고 끝, 409 · 5xx는 같은 요청을 다시)
            result = try await authed(.answerLocal) { [client] secret in
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
            if let task, task.openRequestID == key.requestID, !task.closedRequestIDs.contains(key.requestID) { continue }
            if await secrets.discard(key: key) { closed += 1 }
        }
        if expired + closed > 0 { log.log("secret_answers_dropped", ["expired": .count(expired), "closed": .count(closed)]) }
    }

    /// 정산 때 버린다: 요청 id를 아는 정산 (닫기 · 전달 끝)
    func settleSecret(taskID: String, requestID: String) async {
        await secrets.discard(key: LocalSecretKey(taskID: taskID, requestID: requestID))
    }

    /// 정산 때 버린다: 요청 id를 모르는 정산 (lease가 거둔 · 오래된 answer 명령은 payload가 오지 않는다). 그 task의 값을 모두 버린다 (한 task에는 열린 질문이 하나다)
    func settleSecrets(taskID: String) async {
        await secrets.discard(taskID: taskID)
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
#endif
