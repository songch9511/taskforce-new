#if os(macOS)
import Foundation

// Settings › Your agents가 부르는 런타임 함수 (OA Settings › Your agents, 계약 SA-02 A):
// 연결 · 다시 연결 · 이 Mac 끊기 · 다른 Mac 지우기 · probe 읽기와 새로 고침 · 지금 실행의 시작 시각.
// **폐기 순서 · 자격 지우기 · 가리개 · 비밀값 정리는 런타임만 할 수 있다** (판단은 서버, 기록은 런타임): 앱이 `BridgeClient`를 직접 부르면 런타임이 모르는 폐기가 생긴다.
// 로그에는 코드 · 개수만 남긴다 (Mac 이름 · 경로 · id 원문 0).

/// 연결 · 끊기가 서버에 닿지 못한 이유를 화면 말로 가른다: 오프라인("You're offline. Try again.") 아니면 그 밖("Something went wrong. Try again in a moment.")
public enum AgentSettingsFailure: Equatable, Sendable {
    case offline, other
}

/// Connect · Reconnect가 어떻게 끝났나. 서버가 정한 상태 말은 대상 목록(`GET /api/v2/assistant/targets`)에서만 온다 — 이 값은 "이 클릭이 어디까지 갔나"만 말한다
public enum AgentConnectOutcome: Equatable, Sendable {
    /// 서버가 받았다 (대상 목록을 다시 읽으면 연결이 보인다)
    case connected
    /// 409: 이 계정의 Mac이 10대다 (런타임 상태 `tooManyBridges`)
    case tooManyMacs
    /// 403 · 401이 되풀이: 사용자가 Reconnect할 차례다 (런타임 상태 `revoked` · `credentialRejected`)
    case needsReconnect
    case failed(AgentSettingsFailure)
    /// 이 런타임이 할 수 없다 (adapter 없음 · 마무리 모드 · 멈춤 · 이미 끊은 런타임)
    case unavailable

    var logCode: String {
        switch self {
        case .connected: "connected"
        case .tooManyMacs: "too_many_macs"
        case .needsReconnect: "needs_reconnect"
        case .failed(.offline): "offline"
        case .failed(.other): "failed"
        case .unavailable: "unavailable"
        }
    }
}

/// 이 Mac 끊기(`disconnect()`)의 결과
public enum AgentDisconnectOutcome: Equatable, Sendable {
    /// 서버가 폐기를 받았고 이 Mac의 정리를 마쳤다. `unresolvedProcesses`: 끝내지 못했거나 끝을 증명하지 못한 프로세스 수 (0이 아니면 호스트가 런타임을 바로 바꾸지 않는다)
    case disconnected(unresolvedProcesses: Int)
    /// 서버가 폐기를 받지 못했다: **이 Mac에서 바뀐 것은 0이다**
    case failed(AgentSettingsFailure)
    /// 끊을 것이 없다 (등록 전 · 이미 폐기 · 마무리 모드 · 멈춤)
    case unavailable
}

/// 다른 Mac 지우기(`removeMac`)의 결과
public enum AgentRemoveMacOutcome: Equatable, Sendable {
    case removed
    case failed(AgentSettingsFailure)
    /// 이 Mac 자신이거나 bridge id 모양이 아니다: 서버를 부르지 않았다
    case refused
}

extension BridgeRuntime {
    /// `refreshAdapterReports` 사이의 최소 간격 (초)
    static let reportsRefreshInterval: TimeInterval = 10

    /// 이 런타임이 그 adapter를 가졌나 (adapter 목록은 만들 때 정해진다: 동기 읽기). Settings의 "이 빌드가 에이전트를 띄울 수 있나"의 한 조건이다
    public nonisolated func hasAdapter(_ id: String) -> Bool { adapters[id] != nil }

    // MARK: Connect · Reconnect (6.1 · 6.2)

    /// Connect (D2a Q7: 사용자 행동으로만). 그 adapter의 probe 보고가 있을 때만 `connect: [adapter]`로 등록한다
    public func connectAgent(_ adapterID: String) async -> AgentConnectOutcome {
        guard hasAdapter(adapterID), config.mode == .normal, statusValue != .stopped, !shuttingDown else {
            log.log("settings_agent_connect", ["result": .code(AgentConnectOutcome.unavailable.logCode)])
            return .unavailable
        }
        let registered = await connect(adapters: [adapterID])
        let outcome = connectOutcome(registered: registered)
        log.log("settings_agent_connect", ["result": .code(outcome.logCode)])
        return outcome
    }

    /// Reconnect: 폐기된 Mac(`revoked`) · 자격 거절(`credentialRejected`)을 `reactivate: true`로 되살리고 연결 행을 다시 만든다 (`connect`를 다시 싣는다 — 폐기 때 옛 연결 행은 `revoked`로 남는다).
    /// 이 Mac에서 끊은 런타임(`stopSpawning`이 켜짐)은 다시 쓰지 않는다: 호스트가 새 런타임을 만들어 거기서 부른다
    public func reconnectAgent(_ adapterID: String) async -> AgentConnectOutcome {
        guard hasAdapter(adapterID), config.mode == .normal, statusValue != .stopped, !shuttingDown else {
            log.log("settings_agent_reconnect", ["result": .code(AgentConnectOutcome.unavailable.logCode)])
            return .unavailable
        }
        let registered = await reconnect(adapters: [adapterID])
        let outcome = connectOutcome(registered: registered)
        log.log("settings_agent_reconnect", ["result": .code(outcome.logCode)])
        return outcome
    }

    /// `reactivate: true` + `connect` 등록 (6.2). `reactivate()`와 같은 루프 재시작을 한다. 활성 기기에 `reactivate: true`를 보내면 SQL은 `rotated`이고 10대 상한 검사도 타지 않는다
    public func reconnect(adapters ids: [String]) async -> Bool {
        guard config.mode == .normal, statusValue != .stopped, !shuttingDown else { return false }
        let connectable = Set(ids).filter { adapters[$0] != nil }
        guard !connectable.isEmpty else { return false }
        networkEnabled = true
        pendingConnect = connectable.sorted()
        var result = await register(reactivate: true, reason: "reactivate")
        // 진행 중이던 등록에 합쳐졌으면(그 요청에는 connect가 없다) 한 번 더 보낸다
        if result, !pendingConnect.isEmpty { result = await register(reactivate: true, reason: "reactivate") }
        pendingConnect = []
        if !result, statusValue == .revoked { networkEnabled = false }
        if result, statusValue != .stopped {
            if wasStarted, !loopsRunning {
                // 폐기(403)로 루프가 끝났다: 되살아난 Mac은 heartbeat · 목록을 다시 돈다
                firstPollDone = false
                start()
            } else {
                // 사용자 행동을 기다리며 쉬던 루프를 바로 깨운다 (30초를 기다리지 않는다)
                nudge(.startup)
            }
        }
        return result
    }

    private func connectOutcome(registered: Bool) -> AgentConnectOutcome {
        if registered { return .connected }
        switch statusValue {
        case .tooManyBridges: return .tooManyMacs
        case .revoked, .credentialRejected: return .needsReconnect
        case .stopped: return .unavailable
        default: return .failed(Self.failure(of: lastRegisterError))
        }
    }

    /// 서버에 닿지 못한 이유: 전송 오류 중 "인터넷에 연결되어 있지 않다"(-1009) · "연결이 끊겼다"(-1005)만 오프라인이다 (`AgentQuestionAnswerResult.of`와 같은 판단). 그 밖은 서버 문제로 말한다
    static func failure(of error: BridgeClientError?) -> AgentSettingsFailure {
        guard case .transport(let detail)? = error else { return .other }
        // `BridgeClient`는 `String(describing: URLError.code)`를 싣는다: "Code(rawValue: -1009)" (모양은 시험이 실제 URLError로 고정한다)
        return ["-1009", "-1005"].contains { detail.contains("rawValue: \($0))") } ? .offline : .other
    }

    // MARK: Disconnect this Mac (6.3)

    /// 이 Mac의 에이전트 연결을 모두 끊는다. **순서가 계약이다:**
    /// 1. 서버가 폐기를 먼저 받는다 (`DELETE /api/v1/bridge/register`: 연결 · 세션을 닫고 task를 취소한다). 실패하면 **이 Mac에서 바뀌는 것이 0**이다
    /// 2. 성공 뒤에만 이 Mac에서: 살아 있는 실행 끝내기(`interruptLiveTurns`, 감독 밖까지) → 세션 잊기(가리개 · 열린 비밀 항목) → 비밀값 비우기 → 저장된 장치 secret 지우기(`device_id`는 둔다) → 상태 `revoked` · 네트워크 끔 · 알림
    /// 끝내기가 `stopSpawning`을 켠다: 이 런타임은 다시 띄우지 않으므로 호스트가 놓고 같은 파티션의 새 런타임을 만든다. 작업 폴더 등록부는 지우지 않는다.
    /// 세션마다 최대 16초가 걸릴 수 있다 (`interruptLiveTurns`). 겹친 호출은 같은 결과를 기다린다
    public func disconnect() async -> AgentDisconnectOutcome {
        if let running = disconnectTask { return await running.value }
        let task = Task { await self.performDisconnect() }
        disconnectTask = task
        let result = await task.value
        disconnectTask = nil
        return result
    }

    private func performDisconnect() async -> AgentDisconnectOutcome {
        guard config.mode == .normal, !shuttingDown, statusValue != .stopped, networkEnabled, let bridge = bridgeID else {
            log.log("settings_agent_disconnect", ["result": .code("unavailable")])
            return .unavailable
        }
        let gen = generation
        // 1. 서버가 먼저 정한다 (404: 서버에 이 bridge가 없다 — 끊을 연결도 없으니 이 Mac의 정리로 간다)
        do {
            _ = try await client.revoke(bridgeID: bridge)
        } catch {
            if (error as? BridgeClientError) != .notFound {
                let failure = Self.failure(of: error as? BridgeClientError)
                log.log("settings_agent_disconnect", ["result": .code(failure == .offline ? "offline" : "failed")])
                return .failed(failure)
            }
        }
        // 응답을 기다리는 사이 계정이 바뀌었다: 이 Mac에서 바꾸지 않는다 (옛 계정이 돌아오면 다음 heartbeat의 403이 같은 정리를 한다)
        guard isCurrent(gen) else {
            log.log("settings_agent_disconnect", ["result": .code("late")])
            return .failed(.other)
        }
        // 2. 이 Mac의 정리
        let unresolved = await interruptLiveTurns()
        await forgetSessions()
        await secrets.clear()
        do {
            try credentials.deleteSecret(partition: partitionID)
        } catch {
            // 서버가 이미 그 secret을 폐기했다: 남은 값은 쓸모가 없고 다음 등록이 덮어쓴다
            log.log("credential_store_failed", ["step": .code("secret_delete")])
        }
        secret = nil
        networkEnabled = false
        generation += 1
        loopsRunning = false
        loopTask?.cancel()
        loopTask = nil
        flushTask?.cancel()
        flushTask = nil
        wakeForwarder?.cancel()
        wakeForwarder = nil
        resumeWaiter(nil)
        await wake?.stop()
        setStatus(.revoked)
        await publish()
        log.log("settings_agent_disconnect", ["result": .code("disconnected"), "unresolved": .count(unresolved)])
        return .disconnected(unresolvedProcesses: unresolved)
    }

    // MARK: 다른 Mac 지우기 (6.4)

    /// 이 계정의 Mac이 10대일 때 다른 Mac을 폐기한다 (`DELETE /api/v1/bridge/register`는 사용자 토큰만 있으면 된다). 그 Mac의 연결 · 세션은 서버가 닫는다.
    /// **이 Mac 자신은 지우지 않는다** (그 길은 `disconnect()`): 같은 id면 서버를 부르지 않는다. 지우고 나면 `tooManyBridges`를 풀어 Connect를 다시 연다 (자동으로 연결하지 않는다)
    public func removeMac(bridgeID other: String) async -> AgentRemoveMacOutcome {
        let id = other.lowercased()
        guard UUID(uuidString: id) != nil else { return .refused }
        let own = [bridgeID, (try? await ledger.meta())?.bridgeID].compactMap { $0?.lowercased() }
        if own.contains(id) {
            log.log("settings_mac_remove", ["result": .code("refused")])
            return .refused
        }
        guard config.mode == .normal, networkEnabled, statusValue != .stopped else { return .failed(.other) }
        let gen = generation
        do {
            _ = try await client.revoke(bridgeID: id)
        } catch {
            if (error as? BridgeClientError) != .notFound {
                let failure = Self.failure(of: error as? BridgeClientError)
                log.log("settings_mac_remove", ["result": .code(failure == .offline ? "offline" : "failed")])
                return .failed(failure)
            }
        }
        guard isCurrent(gen) else { return .failed(.other) }
        if statusValue == .tooManyBridges {
            // 자리가 생겼다: Connect를 다시 연다. 서버를 다시 부르지 않고 사용자가 누른다 (D2a Q7)
            setStatus(.connecting)
            await publish()
        }
        log.log("settings_mac_remove", ["result": .code("removed")])
        return .removed
    }

    // MARK: probe (8장)

    /// 지금 이 Mac의 adapter 보고 (설치 · 버전 · 로그인 3값 · managed settings). 읽기만 한다: 서버 보고 시각 · 캐시를 건드리지 않는다.
    /// 자격 · 계정 이메일 · authMethod는 읽지도 보이지도 않는다 (I16)
    public func adapterReports() async -> [BridgeV1AdapterReport] {
        var reports: [BridgeV1AdapterReport] = []
        for id in adapterOrder {
            guard let adapter = adapters[id] else { continue }
            var report = await adapter.probe()
            report.version = OutgoingValues.adapterVersion(report.version)
            reports.append(report)
        }
        return reports
    }

    /// Terminal에서 로그인하고 돌아온 때 · Settings가 보일 때: 로그인 캐시를 비우고 → probe하고 → heartbeat로 서버 보고를 바꾼다 → 받은 보고를 돌려준다.
    /// **10초에 한 번까지**: 그 안의 호출은 마지막 보고를 그대로 준다 (서버 heartbeat 한도 · `claude auth status` 실행을 아낀다)
    public func refreshAdapterReports() async -> [BridgeV1AdapterReport] {
        let now = clock.now()
        if let last = lastReportsRefresh, now.timeIntervalSince(last) < Self.reportsRefreshInterval { return lastRefreshedReports }
        lastReportsRefresh = now
        for adapter in adapters.values { await adapter.refreshProbe() }
        let reports = await adapterReports()
        lastRefreshedReports = reports
        // 서버 보고: 다음 heartbeat가 probe를 다시 하고 달라진 것만 싣는다 (`reportsForHeartbeat`)
        lastProbeAt = nil
        if bridgeID != nil, secret != nil, active, ![.revoked, .tooManyBridges, .credentialRejected].contains(statusValue) {
            forceHeartbeat = true
            await sendHeartbeat()
        }
        return reports
    }

    /// 살아 있는 실행 중 가장 이른 시작 시각 (Status의 "Active since {h:mm}"). 없으면 nil
    public func liveSince() async -> Date? {
        let tasks = (try? await ledger.allTasks()) ?? []
        return tasks.filter(\.alive).map { $0.processStartedAt ?? $0.acceptedAt ?? $0.updatedAt }.min()
    }

    // MARK: 기기 이름 (OA F1m)

    /// 서버로 보낼 Mac 이름: bridge가 켜졌을 때만(마무리 모드 · 공급자 없음이면 nil) 정규화한 값. 비면 nil — 키를 빼서 보낸다
    func sendableDeviceName() -> String? {
        guard config.mode == .normal, let provider = config.deviceName else { return nil }
        return DeviceName.normalized(provider())
    }
}
#endif
