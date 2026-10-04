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
    /// `reset()`마다 오른다: 전 사용자의 늦은 응답(프로필 · 동의 · 연결 · 오류 문구)을 버린다
    private var generation = 0
    /// `load()`를 겹쳐 부르면 (Mac: 로그인 직후 런처 + 설정 창) 한 번만 읽는다. 따로 읽으면 Google 로그인 이름을 채우지 않은 쪽이
    /// 먼저 빈 이름의 프로필을 두고, 설정 창 이름 칸이 그 빈 값으로 채워진 채 굳는다
    private let loads = SingleFlight()

    let services: AppServices
    /// Google 로그인 직후 이름 채우기에만 쓴다 (`namedFromAccount`)
    private let session: SessionStore?

    init(services: AppServices, session: SessionStore?) {
        self.services = services
        self.session = session
    }

    #if DEBUG
    /// 디자인 비교용 견본 (`SampleData`): 서버를 부르지 않는다
    private(set) var sampleMode = false

    /// 견본의 처리방침 안내는 닫아도 본 판을 기기에 적지 않는다 (`policyUserID` 없음)
    func useSampleData(connections: [ConnectionRecord], policyNotice: PolicyNotice? = nil) {
        sampleMode = true
        apply(connections)
        self.policyNotice = policyNotice
        // 동의한 계정 견본 (`-TFSampleConsent`): 설정 Privacy & AI Data의 스위치가 켜진 모습
        consentGiven = SampleData.hasConsent
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

    /// 프로필 · 연결 · 요청을 읽는다. 이미 읽는 중이면 그 끝을 기다린다 (`loads`)
    func load() async {
        #if DEBUG
        if sampleMode { return }
        #endif
        // 부른 때의 계정으로 읽는다: 읽기는 부른 화면이 사라져도 끝까지 돈다.
        // 그사이 계정이 바뀌면 결과를 버리고(`generation`) 다음 계정의 Google 이름을 가져가지 않는다(`userID`)
        let generation = generation
        let userID = signedInUserID
        await loads.run { await self.read(generation: generation, userID: userID) }
    }

    private func read(generation: Int, userID: UUID?) async {
        async let profileValue = try? services.api.profile()
        async let connectionsValue = try? services.reads.connections()
        // 예전 서버에는 표가 없다
        async let requestsValue = try? services.reads.connectionRequests()
        let (loadedProfile, connections, requests) = await (profileValue, connectionsValue, requestsValue)
        guard generation == self.generation else { return }
        if let connections { apply(connections) }
        if let requests { requested = requests }
        if let loadedProfile {
            // 이름을 채우면 채운 프로필을 한 번에 둔다 (Mac 프로필 칸은 처음 받은 프로필로 한 번만 채운다).
            // 저장이 실패해도 generation을 다시 본다: 그사이 로그아웃 · 계정 전환이면 전 사용자 값을 두지 않는다
            let named = await namedFromAccount(loadedProfile, readFor: userID)
            guard generation == self.generation else { return }
            profile = named ?? loadedProfile
        }
        loaded = true
    }

    /// 로그아웃 · 계정 전환 뒤 (Mac은 이 저장소 하나를 계속 쓴다)
    func reset() {
        generation += 1
        // 전 사용자의 읽기는 `generation`으로 버려진다: 다음 `load()`는 그것을 기다리지 않고 새로 읽는다
        loads.reset()
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
        message = nil
        // 전 계정의 연결 · Sync Now(최대 4분)가 다음 계정의 버튼을 막지 않게
        connecting = nil
        syncing = false
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
        let generation = generation
        defer { if generation == self.generation { connecting = nil } }
        let url: URL
        do {
            url = try await services.api.startConnection(provider)
        } catch let error as APIError {
            guard generation == self.generation else { return }
            switch ConnectionStartFailure.classify(error) {
            case .comingSoon: comingSoon.insert(provider)
            case .consentRequired:
                pendingProvider = provider
                showsConsent = true
            case .other: message = error.userMessage
            }
            return
        } catch {
            if !(error is CancellationError), generation == self.generation { message = error.userMessage }
            return
        }
        guard generation == self.generation else { return }
        do {
            let callbackURL = try await session.authenticate(
                using: url,
                callback: .customScheme(ConnectionCallback.scheme),
                preferredBrowserSession: nil,
                additionalHeaderFields: [:]
            )
            // 브라우저에 있는 사이 로그아웃 · 계정 전환했으면 다음 계정의 토큰으로 이 연결을 마치지 않는다
            guard generation == self.generation else { return }
            await handleCallback(callbackURL)
        } catch let error as ASWebAuthenticationSessionError where error.code == .canceledLogin {
            // 사용자가 닫음
        } catch {
            if !(error is CancellationError), generation == self.generation { message = "Couldn't connect. Try again." }
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
        let generation = generation
        do {
            let status = try await services.api.completeConnection(provider, handoff: handoff)
            guard generation == self.generation else { return }
            await finishConnection(status, provider: provider)
        } catch let error as APIError {
            guard generation == self.generation else { return }
            switch ConnectionCompleteFailure.classify(error) {
            case .consentRequired:
                pendingHandoff = (provider, handoff)
                showsConsent = true
            case .failed(let text):
                message = text
            }
        } catch {
            if !(error is CancellationError), generation == self.generation { message = ConnectionCompleteFailure.retryMessage }
        }
    }

    private func finishConnection(_ status: ConnectionCallback.Status, provider: ConnectionProvider?) async {
        if let text = status.message { message = text }
        // 서버가 연결하며 첫 동기화를 뒤에서 시작한다 (몇 분 걸린다): 잠금이 보이기 전에도 곧바로 "Syncing…"
        if status.isConnected, let provider { expectSync([provider.rawValue]) }
        let generation = generation
        await reloadConnections()
        if status.isConnected, generation == self.generation {
            // 서버가 연결하며 동기화를 시작하지만, 바로 한 번 더 부르면 첫 할 일이 빨리 채워진다 (막 동기화했으면 429라 조용히 넘긴다)
            Task { try? await services.api.syncConnections() }
        }
    }

    /// 2단계 "Want this"
    func request(_ provider: ConnectionProvider) async {
        requested.insert(provider)
        let generation = generation
        do {
            try await services.api.requestConnection(provider)
        } catch let error as APIError where ConnectionStartFailure.classify(error) == .comingSoon {
            // 예전 서버: 요청을 받을 곳이 없다. 표시는 그대로 두고 조용히 넘긴다
        } catch {
            guard generation == self.generation else { return }
            requested.remove(provider)
            message = error.userMessage
        }
    }

    /// Sync Now: 서버는 붙은 연결을 모두 동기화하고 끝나면 답한다 (최대 4분). 그동안 줄마다 "Syncing…".
    /// 이미 동기화 중이거나 방금 끝났으면(429) 오류가 아니다: 다시 읽은 연결이 "Syncing…" · "Synced just now"를 보여 준다.
    func sync() async {
        guard !syncing else { return }
        syncing = true
        let generation = generation
        defer { if generation == self.generation { syncing = false } }
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
        // 기다리는 사이(최대 4분) 로그아웃 · 계정 전환했으면 전 계정의 결과는 버린다
        guard generation == self.generation else { return }
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
        let generation = generation
        do {
            try await services.api.disconnect(connectionID: record.id)
        } catch {
            if generation == self.generation { message = error.userMessage }
        }
        await reloadConnections()
    }

    // MARK: 동의

    /// 동의하고, 기다리던 연결이 있으면 `resumeProvider`로 넘긴다
    func giveConsent() async {
        let generation = generation
        do {
            try await services.api.giveAIConsent()
        } catch let error as APIError where ConnectionStartFailure.classify(error) == .comingSoon {
            // 예전 서버: 동의 없이도 처리한다
        } catch {
            if generation == self.generation { message = error.userMessage }
            return
        }
        // 그사이 로그아웃 · 계정 전환했으면 다음 계정을 동의한 것으로 두지 않는다
        guard generation == self.generation else { return }
        consentGiven = true
        // 시트가 닫히며 declineConsent()가 불려도 이어서 할 일은 잃지 않게 먼저 꺼내 둔다
        let provider = pendingProvider
        let handoff = pendingHandoff
        pendingProvider = nil
        pendingHandoff = nil
        showsConsent = false
        if let value = try? await services.api.profile(), generation == self.generation { profile = value }
        guard generation == self.generation else { return }
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
        let generation = generation
        do {
            try await services.api.withdrawAIConsent()
        } catch {
            if generation == self.generation { message = error.userMessage }
            return
        }
        guard generation == self.generation else { return }
        consentGiven = false
        if let value = try? await services.api.profile(), generation == self.generation { profile = value }
    }

    // MARK: 프로필

    /// Google 로그인 직후 처음 읽은 프로필의 이름이 비어 있으면 그 로그인이 준 이름으로 채운다: 원문 속 "나"를 찾는 기본 이름.
    /// 로그인 직후 한 번만 (이름이 이미 있어도 기회를 쓴다), 그 로그인의 사용자를 읽었고 그 사용자가 지금 로그인한 사용자일 때만 저장한다
    /// (iPhone은 계정마다 저장소가 따로라 `reset()`이 없다: 로그아웃 전에 시작한 읽기가 다음 계정의 이름을 전 계정 프로필과 섞어 저장하지 않게).
    /// 채웠으면 저장된 프로필, 아니면 nil (저장이 실패하면 iPhone이 처음 한 번 이름을 묻는다).
    private func namedFromAccount(_ profile: Profile, readFor userID: UUID?) async -> Profile? {
        guard let session, let userID, let fill = session.takeAccountNameFill(for: userID) else { return nil }
        guard let edited = fill.profile(filling: profile, signedInUserID: signedInUserID) else { return nil }
        return try? await services.api.saveProfile(edited)
    }

    /// 지금 로그인한 사용자 (세션을 모르면 nil)
    private var signedInUserID: UUID? {
        guard let session, case .signedIn(let userID, _) = session.state else { return nil }
        return userID
    }

    /// 이름 · 별칭 저장. 성공하면 true.
    func saveProfile(name: String, aliases: [String]) async -> Bool {
        // PUT은 통째로 바꾸므로, 읽지 못한 프로필로 저장하면 이메일 목록이 지워진다
        guard let profile else {
            message = "Couldn't load your profile. Try again in a moment."
            return false
        }
        let edited = Profile.edited(name: name, aliases: aliases, keeping: profile)
        let generation = generation
        do {
            let saved = try await services.api.saveProfile(edited)
            // 저장하는 사이 계정이 바뀌었으면 전 계정의 프로필을 두지 않는다
            guard generation == self.generation else { return false }
            self.profile = saved
            return true
        } catch {
            if generation == self.generation { message = error.userMessage }
            return false
        }
    }
}
