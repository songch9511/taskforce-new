import AuthenticationServices
import Foundation
import Observation
import SwiftUI
import TaskforceKit

/// 연결 · 외부 AI 처리 동의 · 프로필. iPhone 계정 시트와 Mac 설정 창이 같은 것을 쓴다.
@MainActor
@Observable
final class AccountStore {
    private(set) var profile: Profile?
    private(set) var connections: [ConnectionRecord] = []
    private(set) var requested: Set<ConnectionProvider> = []
    /// 서버에 아직 없는 서비스 (연결 시작이 400 invalid_request)
    private(set) var comingSoon: Set<ConnectionProvider> = []
    private(set) var connecting: ConnectionProvider?
    private(set) var syncing = false
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
    /// `reset()`마다 오른다: 전 사용자의 늦은 응답을 버린다
    private var generation = 0

    let services: AppServices

    init(services: AppServices) {
        self.services = services
    }

    func state(for provider: ConnectionProvider) -> ConnectionState {
        ConnectionState.state(for: provider, in: connections)
    }

    var hasConnections: Bool {
        ConnectionProvider.stageOne.contains { state(for: $0).isConnected }
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
        let generation = generation
        async let profileValue = try? services.api.profile()
        async let connectionsValue = try? services.reads.connections()
        // 예전 서버에는 표가 없다
        async let requestsValue = try? services.reads.connectionRequests()
        let (profile, connections, requests) = await (profileValue, connectionsValue, requestsValue)
        guard generation == self.generation else { return }
        if let profile { self.profile = profile }
        if let connections { self.connections = connections }
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
        requested = []
        comingSoon = []
        loaded = false
        showsConsent = false
        pendingProvider = nil
        pendingHandoff = nil
    }

    func reloadConnections() async {
        if let value = try? await services.reads.connections() {
            connections = value
        }
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
            await finishConnection(status)
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
            await finishConnection(status)
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

    private func finishConnection(_ status: ConnectionCallback.Status) async {
        if let text = status.message { message = text }
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

    func sync() async {
        syncing = true
        defer { syncing = false }
        do {
            try await services.api.syncConnections()
        } catch let error as APIError {
            if case .server(_, .rateLimited, _) = error {
                message = "Synced a moment ago."
            } else {
                message = error.userMessage
            }
        } catch {
            message = error.userMessage
        }
        await reloadConnections()
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
