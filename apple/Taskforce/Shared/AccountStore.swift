import AuthenticationServices
import Foundation
import Observation
import SwiftUI
import TaskforceKit

/// 연결 · 외부 AI 처리 동의 · 프로필 · 처리방침 변경 안내. iPhone 계정 시트와 Mac 설정 창이 같은 것을 쓴다.
@MainActor
@Observable
final class AccountStore {
    private(set) var profile: Profile?
    private(set) var connections: [ConnectionRecord] = []
    private(set) var requested: Set<ConnectionProvider> = []
    /// 서버에 아직 없는 서비스 (연결 시작이 400 invalid_request)
    private(set) var comingSoon: Set<ConnectionProvider> = []
    private(set) var connecting: ConnectionProvider?
    /// Sync Now 요청을 보내는 중 (서버는 끝날 때까지 답하지 않는다)
    private(set) var syncing = false
    /// 연결 직후 · Sync Now 직후 서버 잠금이 보이기 전까지 먼저 "Syncing…"을 보여 줄 서비스 (provider → 누른 때, `ConnectionSync`)
    private(set) var syncRequests: [String: Date] = [:]
    /// 연결을 마지막으로 읽은 때. 동기화 중인지는 이 시각으로 판단한다 (다시 읽을 때마다 화면이 새로 판단한다)
    private(set) var connectionsReadAt = Date()
    /// 동기화 중이던 연결이 끝날 때마다 오른다: 화면이 지금 할 일을 다시 불러온다
    private(set) var syncFinished = 0
    private(set) var loaded = false
    var message: String?
    /// 동의 화면을 띄울지 (연결 · 원문 보내기 · 물어보기 전에)
    var showsConsent = false
    /// 동의하면 이어서 연결할 서비스
    private(set) var pendingProvider: ConnectionProvider?
    /// 동의하면 이어서 마칠 연결 (`/complete`가 409로 동의를 요구한 handoff)
    private var pendingHandoff: (provider: ConnectionProvider, id: String)?
    /// 동의가 끝나 이어서 연결할 서비스. 연결 화면이 자기 브라우저 세션으로 시작한다 (동의 시트는 이미 닫혔다).
    var resumeProvider: ConnectionProvider?
    /// 처리방침 변경 안내 (이 계정이 아직 열거나 닫지 않은 판만). 못 읽으면 보이지 않는다: 안내는 곁가지라 오류를 띄우지 않는다
    private(set) var policyNotice: PolicyNotice?
    /// 안내를 읽은 계정 (열거나 닫으면 이 계정에 적는다)
    private var policyUserID: UUID?
    /// 계정마다 30분에 한 번만 읽는다
    private var policyRefresh = PolicyNoticeRefresh()
    /// `reset()`마다 오른다: 전 사용자의 늦은 응답을 버린다
    private var generation = 0

    let services: AppServices

    init(services: AppServices) {
        self.services = services
    }

    #if DEBUG
    /// 디자인 비교용 견본 (`SampleData`): 서버를 부르지 않는다
    private(set) var sampleMode = false

    /// 견본의 처리방침 안내는 닫아도 본 판을 기기에 적지 않는다 (`policyUserID` 없음)
    func useSampleData(connections: [ConnectionRecord], policyNotice: PolicyNotice? = nil) {
        sampleMode = true
        apply(connections)
        self.policyNotice = policyNotice
        loaded = true
    }
    #endif

    func state(for provider: ConnectionProvider) -> ConnectionState {
        ConnectionState.state(for: provider, in: connections)
    }

    var hasConnections: Bool {
        ConnectionProvider.stageOne.contains { state(for: $0).isConnected }
    }

    /// 이 서비스 줄에 "Syncing…"을 보여 줄지
    func isSyncing(_ provider: ConnectionProvider) -> Bool {
        guard let record = state(for: provider).record else { return false }
        return ConnectionSync.isSyncing(record, requestedAt: syncRequests[record.provider], at: connectionsReadAt)
    }

    /// 연결 중 하나라도 동기화 중인지 (빈 목록의 "Syncing…" · 다시 읽기)
    var anySyncing: Bool {
        ConnectionSync.anySyncing(connections, requested: syncRequests, at: connectionsReadAt)
    }

    /// 동의가 필요한지: 서버가 동의 필드를 알려 주는데 아직 없으면
    var needsConsent: Bool {
        !consentGiven && AIConsentRule.isMissing(profile)
    }

    /// 로그인 뒤 동의 화면을 띄울지: 동의 전인데 연결이 있으면 (목록 보기는 막지 않는다)
    var shouldPromptConsent: Bool {
        !consentGiven && AIConsentRule.shouldPrompt(profile: profile, hasConnections: hasConnections)
    }

    /// 방금 동의함 (프로필을 다시 읽지 못해도 동의 화면을 또 띄우지 않게)
    private var consentGiven = false

    /// 화면에 보일 동의 상태
    var hasConsent: Bool { consentGiven || profile?.hasAIConsent == true }

    func load() async {
        #if DEBUG
        if sampleMode { return }
        #endif
        let generation = generation
        async let profileValue = try? services.api.profile()
        async let connectionsValue = try? services.reads.connections()
        // 예전 서버에는 표가 없다
        async let requestsValue = try? services.reads.connectionRequests()
        let (profile, connections, requests) = await (profileValue, connectionsValue, requestsValue)
        guard generation == self.generation else { return }
        if let profile { self.profile = profile }
        if let connections { apply(connections) }
        if let requests { requested = requests }
        loaded = true
    }

    /// 로그아웃 · 계정 전환 뒤 (Mac은 이 저장소 하나를 계속 쓴다)
    func reset() {
        generation += 1
        consentGiven = false
        resumeProvider = nil
        profile = nil
        connections = []
        syncRequests = [:]
        requested = []
        comingSoon = []
        policyNotice = nil
        policyUserID = nil
        policyRefresh = PolicyNoticeRefresh()
        loaded = false
        showsConsent = false
        pendingProvider = nil
        pendingHandoff = nil
    }

    func reloadConnections() async {
        #if DEBUG
        if sampleMode { return }
        #endif
        let generation = generation
        guard let value = try? await services.reads.connections(), generation == self.generation else { return }
        apply(value)
    }

    /// 새로 읽은 연결: 서버 잠금이 보이거나 끝난 서비스의 앱 표시는 거두고, 동기화가 끝났으면 `syncFinished`
    private func apply(_ records: [ConnectionRecord]) {
        let wasSyncing = anySyncing
        let now = Date()
        connections = records
        connectionsReadAt = now
        syncRequests = ConnectionSync.pending(syncRequests, after: records, at: now)
        if wasSyncing, !anySyncing { syncFinished += 1 }
    }

    /// 동기화 중인 연결이 있는 동안 몇 초마다 연결을 다시 읽는다. 보이는 화면의 `.task`에서 부른다 (화면이 사라지면 멈춘다).
    func followSync() async {
        while anySyncing, !Task.isCancelled {
            try? await Task.sleep(for: ConnectionSync.pollInterval)
            guard !Task.isCancelled else { return }
            // 두 화면이 함께 보이면 (iPhone 홈 + 계정 시트) 한쪽만 읽는다
            if Date().timeIntervalSince(connectionsReadAt) >= 3 { await reloadConnections() }
        }
    }

    /// 서버가 동기화를 시작할 서비스: 잠금이 보일 때까지 먼저 "Syncing…"
    private func expectSync(_ providers: [String]) {
        let now = Date()
        for provider in providers { syncRequests[provider] = now }
    }

    // MARK: 처리방침 변경 안내

    /// 처리방침 변경 안내를 읽는다 (앱을 열거나 앞으로 돌아올 때, 계정마다 30분에 한 번 `PolicyNoticeRefresh`).
    /// 실패하면 지금 보이는 것을 그대로 둔다
    func loadPolicyNotice(userID: UUID) async {
        #if DEBUG
        if sampleMode { return }
        #endif
        guard policyRefresh.isDue(for: userID, at: Date()) else { return }
        let generation = generation
        guard let response = try? await services.api.legal(), generation == self.generation else { return }
        policyRefresh.loaded(for: userID, at: Date())
        policyUserID = userID
        policyNotice = PolicyNoticeSeen.pending(response.privacy.notice, for: userID)
    }

    /// View · 닫기: 이 판은 이 계정에 다시 보이지 않는다 (이 기기에만 적는다)
    func acknowledgePolicyNotice() {
        guard let notice = policyNotice else { return }
        if let policyUserID { PolicyNoticeSeen.mark(notice.version, for: policyUserID) }
        policyNotice = nil
    }

    // MARK: 연결

    /// 연결 시작 → 브라우저(ASWebAuthenticationSession) → `taskforce://connections/…`로 돌아옴
    func connect(_ provider: ConnectionProvider, using session: WebAuthenticationSession) async {
        guard connecting == nil else { return }
        if needsConsent {
            pendingProvider = provider
            showsConsent = true
            return
        }
        connecting = provider
        defer { connecting = nil }
        let url: URL
        do {
            url = try await services.api.startConnection(provider)
        } catch let error as APIError {
            switch ConnectionStartFailure.classify(error) {
            case .comingSoon: comingSoon.insert(provider)
            case .consentRequired:
                pendingProvider = provider
                showsConsent = true
            case .other: message = error.userMessage
            }
            return
        } catch {
            if !(error is CancellationError) { message = error.userMessage }
            return
        }
        do {
            let callbackURL = try await session.authenticate(
                using: url,
                callback: .customScheme(ConnectionCallback.scheme),
                preferredBrowserSession: nil,
                additionalHeaderFields: [:]
            )
            await handleCallback(callbackURL)
        } catch let error as ASWebAuthenticationSessionError where error.code == .canceledLogin {
            // 사용자가 닫음
        } catch {
            if !(error is CancellationError) { message = "Couldn't connect. Try again." }
        }
    }

    /// 브라우저가 돌려준 주소 (ASWebAuthenticationSession 또는 onOpenURL).
    /// 동의 성공이면 handoff id를 내 토큰으로 `/complete`에 보내야 연결이 생긴다 (연결을 시작한 사용자만 이을 수 있다).
    func handleCallback(_ url: URL) async {
        guard let callback = ConnectionCallback.parse(url) else { return }
        switch callback.outcome {
        case .status(let status):
            await finishConnection(status, provider: callback.provider)
        case .handoff(let id):
            guard let provider = callback.provider else {
                message = ConnectionCompleteFailure.retryMessage
                return
            }
            await complete(provider, handoff: id)
        }
    }

    private func complete(_ provider: ConnectionProvider, handoff: String) async {
        do {
            let status = try await services.api.completeConnection(provider, handoff: handoff)
            await finishConnection(status, provider: provider)
        } catch let error as APIError {
            switch ConnectionCompleteFailure.classify(error) {
            case .consentRequired:
                pendingHandoff = (provider, handoff)
                showsConsent = true
            case .failed(let text):
                message = text
            }
        } catch {
            if !(error is CancellationError) { message = ConnectionCompleteFailure.retryMessage }
        }
    }

    private func finishConnection(_ status: ConnectionCallback.Status, provider: ConnectionProvider?) async {
        if let text = status.message { message = text }
        // 서버가 연결하며 첫 동기화를 뒤에서 시작한다 (몇 분 걸린다): 잠금이 보이기 전에도 곧바로 "Syncing…"
        if status.isConnected, let provider { expectSync([provider.rawValue]) }
        await reloadConnections()
        if status.isConnected {
            // 서버가 연결하며 동기화를 시작하지만, 바로 한 번 더 부르면 첫 할 일이 빨리 채워진다 (막 동기화했으면 429라 조용히 넘긴다)
            Task { try? await services.api.syncConnections() }
        }
    }

    /// 2단계 "Want this"
    func request(_ provider: ConnectionProvider) async {
        requested.insert(provider)
        do {
            try await services.api.requestConnection(provider)
        } catch let error as APIError where ConnectionStartFailure.classify(error) == .comingSoon {
            // 예전 서버: 요청을 받을 곳이 없다. 표시는 그대로 두고 조용히 넘긴다
        } catch {
            requested.remove(provider)
            message = error.userMessage
        }
    }

    /// Sync Now: 서버는 붙은 연결을 모두 동기화하고 끝나면 답한다 (최대 4분). 그동안 줄마다 "Syncing…".
    /// 이미 동기화 중이거나 방금 끝났으면(429) 오류가 아니다: 다시 읽은 연결이 "Syncing…" · "Synced just now"를 보여 준다.
    func sync() async {
        guard !syncing else { return }
        syncing = true
        defer { syncing = false }
        expectSync(connections.filter { $0.status == .active || $0.status == .error }.map(\.provider))
        let failure: SyncNowFailure?
        do {
            try await services.api.syncConnections()
            failure = nil
        } catch is CancellationError {
            failure = nil
        } catch let error as APIError {
            failure = SyncNowFailure.classify(error)
        } catch {
            failure = .failed(error.userMessage)
        }
        // 서버가 답했으면 앱 표시는 거두고 서버 상태(잠금 · 마지막 동기화)를 따른다
        syncRequests = [:]
        let finished = syncFinished
        await reloadConnections()
        switch failure {
        case nil:
            if syncFinished == finished { syncFinished += 1 }
        case .alreadySyncing:
            break
        case .consentRequired:
            showsConsent = true
        case .failed(let text):
            // 연결이 끊겼어도 서버가 아직 동기화 중이면 오류 대신 진행 표시
            if !anySyncing { message = text }
        }
    }

    func disconnect(_ record: ConnectionRecord) async {
        do {
            try await services.api.disconnect(connectionID: record.id)
        } catch {
            message = error.userMessage
        }
        await reloadConnections()
    }

    // MARK: 동의

    /// 동의하고, 기다리던 연결이 있으면 `resumeProvider`로 넘긴다
    func giveConsent() async {
        do {
            try await services.api.giveAIConsent()
        } catch let error as APIError where ConnectionStartFailure.classify(error) == .comingSoon {
            // 예전 서버: 동의 없이도 처리한다
        } catch {
            message = error.userMessage
            return
        }
        consentGiven = true
        // 시트가 닫히며 declineConsent()가 불려도 이어서 할 일은 잃지 않게 먼저 꺼내 둔다
        let provider = pendingProvider
        let handoff = pendingHandoff
        pendingProvider = nil
        pendingHandoff = nil
        showsConsent = false
        if let value = try? await services.api.profile() { profile = value }
        if let handoff {
            // 브라우저는 이미 끝났다: 같은 handoff로 연결만 마친다
            await complete(handoff.provider, handoff: handoff.id)
        } else {
            resumeProvider = provider
        }
    }

    func declineConsent() {
        showsConsent = false
        pendingProvider = nil
        pendingHandoff = nil
    }

    func withdrawConsent() async {
        do {
            try await services.api.withdrawAIConsent()
        } catch {
            message = error.userMessage
            return
        }
        consentGiven = false
        if let value = try? await services.api.profile() { profile = value }
    }

    // MARK: 프로필

    /// 이름 · 별칭 저장. 성공하면 true.
    func saveProfile(name: String, aliases: [String]) async -> Bool {
        // PUT은 통째로 바꾸므로, 읽지 못한 프로필로 저장하면 이메일 목록이 지워진다
        guard let profile else {
            message = "Couldn't load your profile. Try again in a moment."
            return false
        }
        let edited = Profile.edited(name: name, aliases: aliases, keeping: profile)
        do {
            self.profile = try await services.api.saveProfile(edited)
            return true
        } catch {
            message = error.userMessage
            return false
        }
    }
}
